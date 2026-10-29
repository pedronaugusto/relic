//! `git archive`: a tree or a commit written as a tar or zip file, the bytes
//! git writes for the same tree and options, or as a tar through one of
//! git's tar filters.
//!
//! The tar is git's: a `pax_global_header` carrying the commit's name as
//! its `comment`, ustar headers with git's modes (`tar.umask`, 002 by
//! default), owner `root`, every entry's time the commit's, paths too long
//! for a header split at a `/` or carried in a pax header, and the 10240
//! byte blocks git writes. A directory is written only when something in it
//! is. The zip is git's too — DOS times, the extended-time field, the
//! executable and symlink bits, the text flag, the commit's name as the
//! archive comment — and is byte for byte git's when stored (`level = 0`);
//! a deflated entry uses Warp's deflate, which decodes to the same
//! file while its compressed bytes are not zlib's.
//!
//! A tar filter is git's `tar.<name>.command`, run through the shell with
//! the tar on its input and `-<level>` after it when a level is given;
//! `tgz` and `tar.gz` are gzip, made here as git makes it in its own
//! process -- a gzip header with no name and no time, written for Unix --
//! unless the configuration names a command for them. Its deflated bytes
//! are Warp's, as a zip's are.
//!
//! Attributes come from the tree being archived, as git reads them, or the
//! working tree's with `worktree_attributes`: `export-ignore` leaves a path
//! out, `export-subst` expands `$Format:...$` (`pretty.zig`), and line
//! endings, `ident` and filters apply as a checkout applies them.

const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const warp = @import("warp");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const date = @import("../text.zig").date;
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const worktree = @import("../checkout/checkout.zig");
const attributes = @import("../patterns.zig").attributes;
const driver_mod = @import("../diff/driver.zig");
const convert = @import("../checkout/convert.zig");
const pathspec_mod = @import("../patterns.zig").pathspec;
const pretty = @import("../pretty/pretty.zig");
const message = @import("../object/message.zig");
const abbrev = @import("../odb/abbrev.zig");
const odb_policy = @import("../odb/policy.zig");
const program = @import("../process.zig").program;
const fs = @import("../fs/fs.zig");
const mailmap_mod = @import("../rev_walk/mailmap.zig");
const signing = @import("../object/signing.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from archiving.
pub const Error = error{
    /// A `diff.<name>.binary` that is neither a boolean nor `auto`, which
    /// git dies on.
    InvalidDriverBinary,
    /// `core.commentChar` or `core.commentString` is one git dies on: no
    /// value, empty, or holding a line break.
    InvalidCommentString,
    /// The object is not a commit, a tree, or a tag of one.
    NotATree,
    /// A pathspec names nothing in the tree: git's "did not match any
    /// files".
    PathspecNoMatch,
    /// A path longer than a zip can hold.
    PathTooLong,
    /// `tar.umask` is not a number.
    InvalidTarUmask,
    /// A zip asked of a commit dated before 1970: git's "timestamp too
    /// large for this system", for git holds a time unsigned. A tar carries
    /// it, as git's does. So is one whose time, in the zip's zone, is past
    /// what a timestamp holds, or in a year past what C's `int` holds.
    TimestampTooLarge,
    /// A tar filter no `tar.<name>.command` names.
    UnknownFormat,
    /// A compression level past 9 for a zip or for gzip made here: git's
    /// "Argument not supported for format".
    LevelNotSupported,
    /// A tar filter's command is to run and no `Options.programs` was
    /// given to run it with.
    FilterNotRun,
    /// The filter's command failed: git's "'<command>' filter reported
    /// error".
    FilterFailed,
} || program.Error || config_mod.ValueError || pretty.Error || pretty.Decorations.LoadError || mailmap_mod.LoadError || pathspec_mod.Error || worktree.Error || convert.Error || attributes.Error ||
    repo_mod.Error || Io.Writer.Error || object.TreeParseError;

/// The archive kinds.
pub const Format = union(enum) {
    tar,
    zip,
    /// A tar through the filter git knows by this name: `tgz`, `tar.gz`,
    /// or any `tar.<name>.command`.
    filtered: []const u8,
};

/// A format git knows by name.
pub const Named = struct {
    name: []const u8,
    format: Format,
    /// Whether `upload-archive` makes it for a client: always for `tar`
    /// and `zip`, and for a tar filter as `tar.<name>.remote` says, by
    /// default only for the built-in `tgz` and `tar.gz`.
    remote: bool,
};

/// The command git gives `tgz` and `tar.gz`: gzip in its own process.
const internal_gzip = "git archive gzip";
const builtin_filters = [_][]const u8{ "tgz", "tar.gz" };

/// Every format `config` makes known, in git's order -- `tar`, the tar
/// filters, `zip` -- as `git archive --list` prints them. The slice is the
/// caller's, freed with `gpa`; the names borrow `config`.
pub fn formats(gpa: Allocator, config: *const config_mod.Config) (Allocator.Error || config_mod.ValueError)![]Named {
    var out: std.ArrayList(Named) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, .{ .name = "tar", .format = .tar, .remote = true });
    for (builtin_filters) |name| try appendFilter(gpa, config, name, &out);
    const named = try config.subsections(gpa, "tar");
    defer gpa.free(named);
    for (named) |name| {
        if (isBuiltinFilter(name)) continue;
        try appendFilter(gpa, config, name, &out);
    }
    try out.append(gpa, .{ .name = "zip", .format = .zip, .remote = true });
    return out.toOwnedSlice(gpa);
}

/// The format git knows as `name`, or `null` for none.
pub fn formatNamed(gpa: Allocator, config: *const config_mod.Config, name: []const u8) (Allocator.Error || config_mod.ValueError)!?Named {
    const all = try formats(gpa, config);
    defer gpa.free(all);
    for (all) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

fn isBuiltinFilter(name: []const u8) bool {
    for (builtin_filters) |b| if (std.mem.eql(u8, b, name)) return true;
    return false;
}

/// A filter git registers: one with a command, configured or built in.
fn appendFilter(gpa: Allocator, config: *const config_mod.Config, name: []const u8, out: *std.ArrayList(Named)) (Allocator.Error || config_mod.ValueError)!void {
    if (filterCommand(config, name) == null) return;
    var key_buf: [256]u8 = undefined;
    const key = std.mem.print(&key_buf, "tar.{s}.remote", .{name}) catch return;
    try out.append(gpa, .{ .name = name, .format = .{ .filtered = name }, .remote = try config.getBool(key, isBuiltinFilter(name)) });
}

/// `tar.<name>.command`, or git's own gzip (`git archive gzip`) for `tgz`
/// and `tar.gz`; `null` for a name with neither.
pub fn filterCommand(config: *const config_mod.Config, name: []const u8) ?[]const u8 {
    var key_buf: [256]u8 = undefined;
    const key = std.mem.print(&key_buf, "tar.{s}.command", .{name}) catch return null;
    if (config.get(key)) |line| return line;
    return if (isBuiltinFilter(name)) internal_gzip else null;
}

/// zlib's extra flags for a gzip header, which git's gzip writes: 2 for
/// level 9, 4 below 2.
fn zlibXfl(level: u4) u8 {
    return if (level == 9) 2 else if (level < 2) 4 else 0;
}

/// How an archive is written.
pub const Options = struct {
    format: Format = .tar,
    /// `--prefix`: put before every path; one ending in `/` is a directory
    /// of its own in the archive.
    prefix: []const u8 = "",
    /// Paths to archive; empty is all.
    pathspecs: []const []const u8 = &.{},
    /// `--mtime`: the entries' time. By default a commit's committer time;
    /// a tree has none, and takes `now`.
    mtime: ?std.Io.Timestamp = null,
    /// The time now, for a tree archived without `mtime`.
    now: std.Io.Timestamp = .zero,
    /// `--worktree-attributes`: the working tree's `.gitattributes`
    /// rather than the tree's.
    worktree_attributes: bool = false,
    /// The compression level, `-0` to `-9`: a zip's, where zero stores,
    /// or a tar filter's, handed to its command. `null` is zlib's default,
    /// and no level for a command. A plain tar has none.
    level: ?u4 = null,
    /// Minutes east of UTC that the zip's DOS times are written in: git
    /// writes the machine's local time.
    zip_offset_minutes: i32 = 0,
    /// The programs filters run through, and the signature programs
    /// `%G?` in an `export-subst` file asks of a signed commit.
    programs: ?program.Programs = null,
    /// Where a tar filter's own diagnostics go; `null` is this process's
    /// standard error, as git's filter writes to git's.
    filter_messages: ?*Io.Writer = null,
    /// The process's umask, for `tar.umask=user`. `null` reads it as git
    /// does, setting it to zero and back, which a caller creating files on
    /// other threads at that moment passes here instead.
    user_umask: ?u32 = null,
};

const record_size = 512;
const block_size = record_size * 20;

const Tar = struct {
    w: *Io.Writer,
    block: [block_size]u8 = undefined,
    offset: usize = 0,
    umask: u32,
    /// The entries' time as git holds one, unsigned: a commit dated before
    /// 1970 is a time past the ustar field, written to a pax header.
    time: u64,

    fn writeIfNeeded(t: *Tar) Io.Writer.Error!void {
        if (t.offset == block_size) {
            try t.w.writeAll(&t.block);
            t.offset = 0;
        }
    }

    fn doWriteBlocked(t: *Tar, data_in: []const u8) Io.Writer.Error!void {
        var data = data_in;
        if (t.offset != 0) {
            const chunk = @min(block_size - t.offset, data.len);
            @memcpy(t.block[t.offset..][0..chunk], data[0..chunk]);
            t.offset += chunk;
            data = data[chunk..];
            try t.writeIfNeeded();
        }
        while (data.len >= block_size) {
            try t.w.writeAll(data[0..block_size]);
            data = data[block_size..];
        }
        if (data.len > 0) {
            @memcpy(t.block[t.offset..][0..data.len], data);
            t.offset += data.len;
        }
    }

    fn finishRecord(t: *Tar) Io.Writer.Error!void {
        const tail = t.offset % record_size;
        if (tail != 0) {
            @memset(t.block[t.offset..][0 .. record_size - tail], 0);
            t.offset += record_size - tail;
        }
        assert(t.offset % record_size == 0);
        assert(t.offset <= block_size);
        try t.writeIfNeeded();
    }

    /// A piece of an entry's content, the record finished after the last.
    fn writePiece(t: *Tar, data: []const u8) Error!void {
        try t.doWriteBlocked(data);
    }

    fn writeBlocked(t: *Tar, data: []const u8) Io.Writer.Error!void {
        try t.doWriteBlocked(data);
        try t.finishRecord();
    }

    fn trailer(t: *Tar) Io.Writer.Error!void {
        const tail = block_size - t.offset;
        @memset(t.block[t.offset..], 0);
        try t.w.writeAll(&t.block);
        if (tail < 2 * record_size) {
            @memset(&t.block, 0);
            try t.w.writeAll(&t.block);
        }
    }
};

const Header = extern struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    chksum: [8]u8,
    typeflag: [1]u8,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
};

comptime {
    assert(@sizeOf(Header) == 500);
    // A header is one record, padded; records fill a block exactly, so a
    // block written whole ends on a record.
    assert(@sizeOf(Header) <= record_size);
    assert(block_size % record_size == 0);
    // `prepareHeader` sums the checksum field as spaces by these offsets.
    assert(@offsetOf(Header, "chksum") == 148);
    assert(@sizeOf(@FieldType(Header, "chksum")) == 8);
}

fn octal(field: []u8, value: u64) void {
    // "%0<n>o" with its NUL, as xsnprintf writes it
    const digits = field.len - 1;
    var v = value;
    var i = digits;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    // Every value written fits its field: sizes and times past the ustar
    // limit go to a pax header instead.
    aegis.assert.invariant(v == 0, "v == 0");
    field[digits] = 0;
}

fn prepareHeader(h: *Header, mode: u32, size: u64, time: u64) void {
    octal(&h.mode, mode & 0o7777);
    octal(&h.size, if (mode & 0o170000 == 0o100000) size else 0);
    octal(&h.mtime, time);
    octal(&h.uid, 0);
    octal(&h.gid, 0);
    @memcpy(h.uname[0..4], "root");
    @memcpy(h.gname[0..4], "root");
    octal(&h.devmajor, 0);
    octal(&h.devminor, 0);
    @memcpy(&h.magic, "ustar\x00");
    @memcpy(&h.version, "00");
    const bytes = std.mem.asBytes(h);
    var sum: u32 = 0;
    for (bytes, 0..) |b, i| {
        if (i >= 148 and i < 156) sum += ' ' else sum += b;
    }
    octal(&h.chksum, sum);
}

fn appendExtHeader(a: Allocator, out: *std.ArrayList(u8), keyword: []const u8, value: []const u8) Allocator.Error!void {
    var len: usize = 1 + 1 + keyword.len + 1 + value.len + 1;
    var tmp: usize = 1;
    while (len / 10 >= tmp) : (tmp *= 10) len += 1;
    try out.print(a, "{d} {s}=", .{ len, keyword });
    try out.appendSlice(a, value);
    try out.append(a, '\n');
}

fn getPathPrefix(path: []const u8, maxlen: usize) usize {
    var i = path.len;
    if (i > 1 and path[i - 1] == '/') i -= 1;
    if (i > maxlen) i = maxlen;
    while (true) {
        i -= 1;
        if (i == 0 or path[i] == '/') break;
    }
    return i;
}

const ustar_max_size: u64 = 0o77777777777;

fn tarEntry(t: *Tar, a: Allocator, oid: Oid, path: []const u8, mode_in: u32, body: Body) Error!void {
    const content = body.content;
    const size = body.size();
    var h: Header = std.mem.zeroes(Header);
    var ext: std.ArrayList(u8) = .empty;
    var mode = mode_in;
    const kind = mode & 0o170000;
    if (kind == 0o040000 or kind == 0o160000) {
        h.typeflag[0] = '5';
        mode = (mode | 0o777) & ~t.umask;
    } else if (kind == 0o120000) {
        h.typeflag[0] = '2';
        mode |= 0o777;
    } else {
        h.typeflag[0] = '0';
        mode = (mode | (if (mode & 0o100 != 0) @as(u32, 0o777) else 0o666)) & ~t.umask;
    }
    var hex: [hash.max_hex_len]u8 = undefined;
    const oid_hex = oid.hex(&hex);
    if (path.len > h.name.len) {
        const plen = getPathPrefix(path, h.prefix.len);
        const rest = path.len - plen - 1;
        if (plen > 0 and rest <= h.name.len) {
            @memcpy(h.prefix[0..plen], path[0..plen]);
            @memcpy(h.name[0..rest], path[plen + 1 ..]);
        } else {
            const name = try a.print("{s}.data", .{oid_hex});
            @memcpy(h.name[0..@min(name.len, h.name.len - 1)], name[0..@min(name.len, h.name.len - 1)]);
            try appendExtHeader(a, &ext, "path", path);
        }
    } else @memcpy(h.name[0..path.len], path);
    if (kind == 0o120000) {
        if (content.len > h.linkname.len) {
            const name = try a.print("see {s}.paxheader", .{oid_hex});
            @memcpy(h.linkname[0..@min(name.len, h.linkname.len - 1)], name[0..@min(name.len, h.linkname.len - 1)]);
            try appendExtHeader(a, &ext, "linkpath", content);
        } else @memcpy(h.linkname[0..content.len], content);
    }
    var size_in_header: u64 = size;
    if (kind == 0o100000 and size > ustar_max_size) {
        size_in_header = 0;
        try appendExtHeader(a, &ext, "size", try a.print("{d}", .{size}));
    }
    prepareHeader(&h, mode, size_in_header, t.time);
    if (ext.items.len > 0) {
        var eh: Header = std.mem.zeroes(Header);
        eh.typeflag[0] = 'x';
        const name = try a.print("{s}.paxheader", .{oid_hex});
        @memcpy(eh.name[0..@min(name.len, eh.name.len - 1)], name[0..@min(name.len, eh.name.len - 1)]);
        prepareHeader(&eh, 0o100666, ext.items.len, t.time);
        try t.writeBlocked(std.mem.asBytes(&eh));
        try t.writeBlocked(ext.items);
    }
    try t.writeBlocked(std.mem.asBytes(&h));
    if (kind == 0o100000 and size > 0) {
        try body.pump(t, Tar.writePiece);
        try t.finishRecord();
    }
}

fn tarGlobalHeader(t: *Tar, a: Allocator, commit: ?Oid) Error!void {
    var ext: std.ArrayList(u8) = .empty;
    var hex: [hash.max_hex_len]u8 = undefined;
    if (commit) |c| try appendExtHeader(a, &ext, "comment", c.hex(&hex));
    if (t.time > ustar_max_size) {
        try appendExtHeader(a, &ext, "mtime", try a.print("{d}", .{t.time}));
        t.time = ustar_max_size;
    }
    if (ext.items.len == 0) return;
    var h: Header = std.mem.zeroes(Header);
    h.typeflag[0] = 'g';
    @memcpy(h.name[0.."pax_global_header".len], "pax_global_header");
    prepareHeader(&h, 0o100666, ext.items.len, t.time);
    try t.writeBlocked(std.mem.asBytes(&h));
    try t.writeBlocked(ext.items);
}

//=========================================================================
// zip
//=========================================================================

const Zip = struct {
    w: *Io.Writer,
    a: Allocator,
    gpa: Allocator,
    dir: std.ArrayList(u8) = .empty,
    offset: u64 = 0,
    entries: u64 = 0,
    max_creator_version: u16 = 0,
    dos_date: u16,
    dos_time: u16,
    time: u64,
    level: ?u4,

    fn le(z: *Zip, out: *std.ArrayList(u8), size: usize, value: u64) Allocator.Error!void {
        var v = value;
        for (0..size) |_| {
            try out.append(z.a, @truncate(v));
            v >>= 8;
        }
    }

    fn write(z: *Zip, bytes: []const u8) Io.Writer.Error!void {
        try z.w.writeAll(bytes);
        z.offset += bytes.len;
    }
};

fn deflateRaw(gpa: Allocator, data: []const u8, level: ?u4) Allocator.Error![]u8 {
    var compress = try warp.Compressor.init(gpa, .{ .level = level orelse 6, .max_input = .fromRaw(data.len) });
    defer compress.deinit();
    const frame: warp.Compressor.Frame = .{ .container = .raw };
    const out = try gpa.alloc(u8, warp.Compressor.bound(data.len, frame));
    errdefer gpa.free(out);
    const n = compress.compress(data, out, frame) catch unreachable; // unreachable: bound reserves the complete stream
    return gpa.realloc(out, n);
}

/// What git's `write_zip_entry` reads of a stream at a time
/// (`STREAM_BUFFER_SIZE`), the first of which says whether it is binary.
const zip_stream_piece = 16 * 1024;

/// An entry's content, as the formats write it.
const Body = struct {
    content: []const u8 = "",
    /// The content read from the object database as it is written, in
    /// place of `content`.
    stream: ?*odb_mod.Odb.Stream = null,
    /// For a zip's text flag: whether the content is binary.
    is_binary: bool = false,
    /// A file git streams (`core.bigFileThreshold`): a zip writes it as
    /// git's `write_zip_entry` writes a stream, its sizes and checksum in
    /// a data descriptor after it, deflated whatever the deflating gives.
    streamed: bool = false,

    fn size(b: Body) u64 {
        return if (b.stream) |s| s.size else b.content.len;
    }

    /// Each next piece of the content, to `each`, whose error is the
    /// write's.
    fn pump(b: Body, context: anytype, comptime each: fn (@TypeOf(context), []const u8) Error!void) Error!void {
        const stream = b.stream orelse return each(context, b.content);
        const r = stream.reader();
        while (true) {
            const chunk = r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return stream.err().?,
            };
            try each(context, chunk);
            r.toss(chunk.len);
        }
    }
};

fn zipEntry(z: *Zip, path: []const u8, mode: u32, body: Body) Error!void {
    const content = body.content;
    const size = body.size();
    const is_binary = body.is_binary;
    var flags: u16 = 0;
    for (path) |c| {
        if (c >= 0x80) {
            if (std.unicode.utf8ValidateSlice(path)) flags |= 1 << 11;
            break;
        }
    }
    if (path.len > 0xffff) return error.PathTooLong;
    const kind = mode & 0o170000;
    var method: u16 = 0;
    var attr2: u32 = 0;
    var creator_version: u16 = 0;
    var out: []const u8 = "";
    var compressed_size: u64 = 0;
    var crc: u32 = 0;
    var text = false;
    var deflated: ?[]u8 = null;
    defer if (deflated) |d| z.gpa.free(d);
    if (kind == 0o040000 or kind == 0o160000) {
        attr2 = 16;
    } else {
        attr2 = if (kind == 0o120000) (mode | 0o777) << 16 else if (mode & 0o111 != 0) mode << 16 else 0;
        if (kind == 0o120000 or mode & 0o111 != 0) creator_version = 0x0317;
        text = !is_binary;
        if (body.stream != null) {
            // Read as it is written: its checksum and deflated size are
            // known after it.
            method = if (z.level == null or z.level.? != 0) 8 else 0;
            compressed_size = if (method == 8) 0 else size;
        } else {
            crc = warp.Crc32.hash(content);
            out = content;
            compressed_size = content.len;
        }
        if (body.stream == null and kind == 0o100000 and (z.level == null or z.level.? != 0) and content.len > 0) {
            method = 8;
            deflated = try deflateRaw(z.gpa, content, z.level);
            // A stream is written deflated, larger or not.
            if (deflated.?.len >= content.len and !body.streamed) {
                method = 0;
            } else {
                out = deflated.?;
                compressed_size = deflated.?.len;
            }
        }
    }
    if (body.streamed) flags |= 1 << 3;
    if (creator_version > z.max_creator_version) z.max_creator_version = creator_version;
    const offset = z.offset;
    // What the local header knows before the content: a stream's checksum
    // and deflated size only come after it, in its data descriptor.
    const header_crc: u32 = if (body.streamed) 0 else crc;
    const header_compressed: u64 = if (body.streamed and method == 8) 0 else compressed_size;
    var extra: [9]u8 = undefined;
    std.mem.writeInt(u16, extra[0..2], 0x5455, .little);
    std.mem.writeInt(u16, extra[2..4], 5, .little);
    extra[4] = 1;
    std.mem.writeInt(u32, extra[5..9], @truncate(z.time), .little);
    // Past four gigabytes the sizes go in a zip64 extra field, as git's
    // `write_zip_entry` puts them, and the header says 0xffffffff; a
    // stream past two gigabytes takes one too.
    const zip64 = size > 0xffffffff or header_compressed > 0xffffffff or (body.streamed and size > 0x7fffffff);
    const version_needed: u16 = if (zip64) 45 else 10;
    var header: std.ArrayList(u8) = .empty;
    try z.le(&header, 4, 0x04034b50);
    try z.le(&header, 2, version_needed);
    try z.le(&header, 2, flags);
    try z.le(&header, 2, method);
    try z.le(&header, 2, z.dos_time);
    try z.le(&header, 2, z.dos_date);
    try z.le(&header, 4, header_crc);
    try z.le(&header, 4, if (zip64) 0xffffffff else header_compressed);
    try z.le(&header, 4, if (zip64) 0xffffffff else size);
    try z.le(&header, 2, path.len);
    try z.le(&header, 2, extra.len + if (zip64) @as(usize, 20) else 0);
    // The local header is fixed at thirty bytes before its name and extra.
    assert(header.items.len == 30);
    if (zip64) {
        try z.le(&header, 2, 0x0001);
        try z.le(&header, 2, 16);
        try z.le(&header, 8, size);
        try z.le(&header, 8, header_compressed);
    }
    try z.write(header.items[0..30]);
    try z.write(path);
    try z.write(&extra);
    try z.write(header.items[30..]);
    if (body.stream != null) {
        const data = try zipStreamData(z, body, method == 8);
        crc = data.crc;
        compressed_size = data.written;
    } else if (compressed_size > 0) try z.write(out);
    if (body.streamed) try zipDataDescriptor(z, crc, compressed_size, size);

    try zipDirectoryEntry(z, .{
        .path = path,
        .extra = &extra,
        .creator_version = creator_version,
        .version_needed = version_needed,
        .flags = flags,
        .method = method,
        .crc = crc,
        .compressed_size = compressed_size,
        .size = size,
        .offset = offset,
        .text = text,
        .attr2 = attr2,
    });
}

/// git's `write_zip_data_desc`: a streamed entry's checksum and sizes,
/// after it.
fn zipDataDescriptor(z: *Zip, crc: u32, compressed_size: u64, size: u64) Error!void {
    var desc: std.ArrayList(u8) = .empty;
    try z.le(&desc, 4, 0x08074b50);
    try z.le(&desc, 4, crc);
    const wide = size >= 0xffffffff or compressed_size >= 0xffffffff;
    try z.le(&desc, if (wide) 8 else 4, compressed_size);
    try z.le(&desc, if (wide) 8 else 4, size);
    try z.write(desc.items);
}

/// A streamed entry's content, written as it is read: stored, or deflated
/// raw as git's `write_zip_entry` deflates a stream. Its checksum, and the
/// bytes written.
fn zipStreamData(z: *Zip, body: Body, deflate: bool) Error!struct { crc: u32, written: u64 } {
    var crc: warp.Crc32 = .init;
    if (!deflate) {
        const Store = struct {
            z: *Zip,
            crc: *warp.Crc32,
            fn each(c: @This(), piece: []const u8) Error!void {
                c.crc.update(piece);
                try c.z.write(piece);
            }
        };
        try body.pump(Store{ .z = z, .crc = &crc }, Store.each);
        return .{ .crc = crc.final(), .written = body.size() };
    }
    var state = try warp.Deflate.init(z.gpa, .{ .level = z.level orelse 6, .container = .raw });
    defer state.deinit();
    var sink_buffer: [16 * 1024]u8 = undefined;
    var sink: ZipSink = .{ .z = z, .writer = .{ .buffer = &sink_buffer, .vtable = &.{ .drain = ZipSink.drain } } };
    var in_buffer: [16 * 1024]u8 = undefined;
    var deflating: warp.Deflate.Writer = .init(&state, &sink.writer, &in_buffer);
    const before = z.offset;
    const Deflate = struct {
        w: *Io.Writer,
        crc: *warp.Crc32,
        fn each(c: @This(), piece: []const u8) Error!void {
            c.crc.update(piece);
            try c.w.writeAll(piece);
        }
    };
    try body.pump(Deflate{ .w = &deflating.interface, .crc = &crc }, Deflate.each);
    try deflating.finish();
    try sink.writer.flush();
    return .{ .crc = crc.final(), .written = z.offset - before };
}

/// The archive's writer through `Zip.write`, which counts its offset: what a
/// stream is deflated into.
const ZipSink = struct {
    z: *Zip,
    writer: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const sink: *ZipSink = @alignCast(@fieldParentPtr("writer", w)); // aegis: boundary: std.Io.Writer's vtable hands drain the writer it was installed on, only a ZipSink's
        try sink.z.write(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |piece| {
            try sink.z.write(piece);
            n += piece.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try sink.z.write(pattern);
        return n + splat * pattern.len;
    }
};

/// A zip entry's record in the central directory, and what it says.
const DirEntry = struct {
    path: []const u8,
    extra: []const u8,
    creator_version: u16,
    version_needed: u16,
    flags: u16,
    method: u16,
    crc: u32,
    compressed_size: u64,
    size: u64,
    offset: u64,
    text: bool,
    attr2: u32,
};

fn zipDirectoryEntry(z: *Zip, e: DirEntry) Error!void {
    const a = z.a;
    // The directory holds each of the three that does not fit in four
    // bytes as 0xffffffff, and its value in a zip64 extra field.
    var zip64_payload: u16 = 0;
    if (e.compressed_size > 0xffffffff or e.size > 0xffffffff or e.offset > 0xffffffff) {
        if (e.compressed_size >= 0xffffffff) zip64_payload += 8;
        if (e.size >= 0xffffffff) zip64_payload += 8;
        if (e.offset >= 0xffffffff) zip64_payload += 8;
    }
    const dir_extra_len = e.extra.len + if (zip64_payload != 0) 4 + @as(usize, zip64_payload) else 0;
    const dir_start = z.dir.items.len;
    try z.le(&z.dir, 4, 0x02014b50);
    try z.le(&z.dir, 2, e.creator_version);
    try z.le(&z.dir, 2, e.version_needed);
    try z.le(&z.dir, 2, e.flags);
    try z.le(&z.dir, 2, e.method);
    try z.le(&z.dir, 2, z.dos_time);
    try z.le(&z.dir, 2, z.dos_date);
    try z.le(&z.dir, 4, e.crc);
    try z.le(&z.dir, 4, @min(e.compressed_size, 0xffffffff));
    try z.le(&z.dir, 4, @min(e.size, 0xffffffff));
    try z.le(&z.dir, 2, e.path.len);
    try z.le(&z.dir, 2, dir_extra_len);
    try z.le(&z.dir, 2, 0);
    try z.le(&z.dir, 2, 0);
    try z.le(&z.dir, 2, @intFromBool(e.text));
    try z.le(&z.dir, 4, e.attr2);
    try z.le(&z.dir, 4, @min(e.offset, 0xffffffff));
    try z.dir.appendSlice(a, e.path);
    try z.dir.appendSlice(a, e.extra);
    if (zip64_payload != 0) {
        try z.le(&z.dir, 2, 0x0001);
        try z.le(&z.dir, 2, zip64_payload);
        if (e.size >= 0xffffffff) try z.le(&z.dir, 8, e.size);
        if (e.compressed_size >= 0xffffffff) try z.le(&z.dir, 8, e.compressed_size);
        if (e.offset >= 0xffffffff) try z.le(&z.dir, 8, e.offset);
    }
    // A central directory record is forty-six bytes, then the name and the
    // extra fields; the trailer counts the directory by these.
    assert(z.dir.items.len - dir_start == 46 + e.path.len + dir_extra_len);
    z.entries += 1;
}

fn zipTrailer(z: *Zip, commit: ?Oid) Error!void {
    var t: std.ArrayList(u8) = .empty;
    try z.le(&t, 4, 0x06054b50);
    try z.le(&t, 2, 0);
    try z.le(&t, 2, 0);
    try z.le(&t, 2, @min(z.entries, 0xffff));
    try z.le(&t, 2, @min(z.entries, 0xffff));
    try z.le(&t, 4, z.dir.items.len);
    try z.le(&t, 4, @min(z.offset, 0xffffffff));
    var hex: [hash.max_hex_len]u8 = undefined;
    const comment: []const u8 = if (commit) |c| c.hex(&hex) else "";
    try z.le(&t, 2, comment.len);
    // The end record is twenty-two bytes, the comment after it.
    assert(t.items.len == 22);
    try z.w.writeAll(z.dir.items);
    // A count or an offset the end record cannot hold: git's
    // `write_zip64_trailer`, the zip64 end record and its locator before it.
    if (z.entries > 0xffff or z.offset > 0xffffffff) {
        var t64: std.ArrayList(u8) = .empty;
        try z.le(&t64, 4, 0x06064b50);
        try z.le(&t64, 8, 44);
        try z.le(&t64, 2, z.max_creator_version);
        try z.le(&t64, 2, 45);
        try z.le(&t64, 4, 0);
        try z.le(&t64, 4, 0);
        try z.le(&t64, 8, z.entries);
        try z.le(&t64, 8, z.entries);
        try z.le(&t64, 8, z.dir.items.len);
        try z.le(&t64, 8, z.offset);
        try z.le(&t64, 4, 0x07064b50);
        try z.le(&t64, 4, 0);
        try z.le(&t64, 8, z.offset + z.dir.items.len);
        try z.le(&t64, 4, 1);
        // Fifty-six bytes of record, twenty of locator.
        assert(t64.items.len == 76);
        try z.w.writeAll(t64.items);
    }
    try z.w.writeAll(t.items);
    try z.w.writeAll(comment);
}

//=========================================================================
// The walk
//=========================================================================

const Entry = struct { oid: Oid, path: []const u8, mode: u32 };

const Walk = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,
    options: Options,
    attrs: *attributes.Attrs,
    conv: *convert.Session,
    spec: *const pathspec_mod.Pathspec,
    commit: ?Oid,
    abbrev_len: usize,
    format: Format,
    /// `core.bigFileThreshold`: a regular file larger than this is
    /// streamed as git streams it, its blob as stored.
    big_file_bytes: u64,
    tar: ?*Tar = null,
    zip: ?*Zip = null,
    /// Directories queued, written only when something under them is.
    queued: std.ArrayList(Entry) = .empty,
    written_dirs: usize = 0,
    /// What `export-subst` formats read, loaded the first time one asks.
    mailmap: ?mailmap_mod.Mailmap = null,
    decorations: ?pretty.Decorations = null,
    signer: ?signing.Signer = null,

    fn deinit(wk: *Walk) void {
        if (wk.mailmap) |*m| m.deinit();
        if (wk.decorations) |*d| d.deinit();
        if (wk.signer) |*s| s.deinit();
        wk.* = undefined;
    }

    /// What a format needs besides the commit: the mailmap, the refs and a
    /// signer, each loaded the first time a placeholder asks for it, as
    /// git loads them.
    fn formatContext(wk: *Walk, format: []const u8) Error!pretty.Context {
        if (wk.mailmap == null and hasPlaceholder(format, "ac", "NEL")) wk.mailmap = try mailmap_mod.Mailmap.load(wk.gpa, wk.io, wk.repo);
        if (wk.decorations == null and (hasPlaceholder(format, "", "dD") or std.mem.find(u8, format, "%(decorate") != null))
            wk.decorations = try pretty.Decorations.load(wk.gpa, wk.io, wk.repo, .{});
        if (wk.signer == null and hasPlaceholder(format, "", "G")) if (wk.options.programs) |programs| {
            wk.signer = try signing.Signer.init(wk.gpa, wk.io, wk.repo.configuration(), wk.repo.topDirectory().get(), programs);
        };
        return .{
            .abbrev_len = wk.abbrev_len,
            .mailmap = if (wk.mailmap) |*m| m else null,
            .decorations = if (wk.decorations) |*d| d else null,
            .signer = if (wk.signer) |*s| s else null,
            .trailers = try message.trailerSettings(wk.a, wk.repo.configuration()),
        };
    }

    fn lookup(wk: *Walk, path: []const u8, is_dir: bool) Error!attributes.Attributes {
        if (wk.options.worktree_attributes) {
            if (wk.repo.workDirectory()) |wt| try wk.attrs.enter(wk.io, wt.get(), path);
        }
        return wk.attrs.lookup(wk.a, path, if (is_dir) .dir else .file);
    }

    /// A zip's text flag for a stream, as git's `write_zip_entry` asks
    /// `entry_is_binary` of the first piece it reads.
    fn headIsBinary(wk: *Walk, stream: *odb_mod.Odb.Stream, applied: attributes.Attributes) Error!bool {
        if (wk.format != .zip) return false;
        const config = wk.repo.configuration();
        const head = stream.reader().peek(@intCast(@min(stream.size, zip_stream_piece))) catch |err| switch (err) {
            error.ReadFailed => return stream.err().?,
            // aegis: internal: an Odb.Stream's reader gives exactly its size's bytes, a short or corrupt object failing as ReadFailed, and this peeks at most that
            error.EndOfStream => unreachable,
        };
        return driver_mod.Driver.of(config, applied.get("diff")).isBinary(config, head);
    }

    fn emit(wk: *Walk, oid: Oid, path: []const u8, mode: u32, body: Body) Error!void {
        if (wk.tar) |t| try tarEntry(t, wk.a, oid, path, mode, body) else try zipEntry(wk.zip.?, path, mode, body);
    }

    fn writeQueued(wk: *Walk) Error!void {
        while (wk.written_dirs < wk.queued.items.len) : (wk.written_dirs += 1) {
            const d = wk.queued.items[wk.written_dirs];
            try wk.emit(d.oid, d.path, d.mode, .{});
        }
    }

    fn walk(wk: *Walk, tree_oid: Oid, base: []const u8) Error!void {
        // The directories queued are the ones this walk is inside.
        if (wk.queued.items.len > wk.repo.settings().max_tree_depth) return error.TreeTooDeep;
        const db = wk.repo.objectDatabase();
        const found = try db.read(wk.io, tree_oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .tree) return error.NotATree;
        const tree = object.Tree.parse(db.objectFormat(), found.bytes);
        var it = tree.iterate();
        while (try it.next()) |entry| {
            const path = try std.mem.concat(wk.a, u8, &.{ base, entry.name });
            const mode: u32 = @backingInt(entry.mode);
            if (entry.mode == .tree) {
                if (!wk.spec.couldMatchUnder(path) and !wk.spec.matchesDir(path)) continue;
                const dir_path = try std.mem.concat(wk.a, u8, &.{ path, "/" });
                const applied = try wk.lookup(path, true);
                if (applied.isTrue("export-ignore")) continue;
                const depth = wk.queued.items.len;
                const written = wk.written_dirs;
                try wk.queued.append(wk.a, .{ .oid = entry.oid, .path = try std.mem.concat(wk.a, u8, &.{ wk.options.prefix, dir_path }), .mode = mode });
                try wk.walk(entry.oid, dir_path);
                // leave the directory: it is no longer queued
                wk.queued.shrinkRetainingCapacity(depth);
                if (wk.written_dirs > depth) wk.written_dirs = depth else wk.written_dirs = written;
                continue;
            }
            if (!wk.spec.matches(path)) continue;
            // the directories above go out before the entry's own
            // attributes are asked, as git's queue writes them
            try wk.writeQueued();
            const applied = try wk.lookup(path, false);
            if (applied.isTrue("export-ignore")) continue;
            const out_path = if (entry.mode == .gitlink)
                try std.mem.concat(wk.a, u8, &.{ wk.options.prefix, path, "/" })
            else
                try std.mem.concat(wk.a, u8, &.{ wk.options.prefix, path });
            if (entry.mode == .gitlink) {
                try wk.emit(entry.oid, out_path, mode, .{});
                continue;
            }
            // git streams a regular file past `core.bigFileThreshold` that
            // `export-subst` does not ask to format, as its blob: unconverted,
            // from the object database's stream where it is stored whole.
            const may_stream = entry.mode != .symlink and !applied.isTrue("export-subst");
            const opened = try db.readOrStream(wk.io, entry.oid, if (may_stream) wk.big_file_bytes else std.math.maxInt(u64));
            const blob = switch (opened) {
                .whole => |whole| whole,
                .stream => |stream| {
                    defer stream.close(wk.io);
                    try wk.emit(entry.oid, out_path, mode, .{ .stream = stream, .is_binary = try wk.headIsBinary(stream, applied), .streamed = true });
                    continue;
                },
            };
            defer db.allocator().free(blob.bytes);
            var content: []const u8 = blob.bytes;
            const streamed = may_stream and blob.bytes.len > wk.big_file_bytes;
            if (entry.mode != .symlink and !streamed) {
                const smudged = try wk.conv.toWorktree(wk.a, .{ .path = path, .blob = content, .applied = applied }, .{ .blob = entry.oid, .treeish = wk.commit });
                content = switch (smudged) {
                    .bytes => |b| b,
                    else => return error.UnsupportedAttribute,
                };
                if (wk.commit) |c| {
                    if (applied.isTrue("export-subst")) content = try formatSubst(wk, c, content);
                }
            }
            // `entry_is_binary`: the `diff` driver, a link's too, then the bytes
            var is_binary = false;
            if (wk.format == .zip) {
                const config = wk.repo.configuration();
                is_binary = try driver_mod.Driver.of(config, applied.get("diff")).isBinary(config, content);
            }
            try wk.emit(entry.oid, out_path, mode, .{ .content = content, .is_binary = is_binary, .streamed = streamed });
        }
    }
};

/// Whether `format` has a placeholder `%<lead><letter>`, after any `+`,
/// `-` or ` ` modifier, with `lead` one of `leads` or nothing when empty.
fn hasPlaceholder(format: []const u8, leads: []const u8, letters: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, format, i, '%')) |pct| {
        var j = pct + 1;
        i = j + 1;
        if (j < format.len and format[j] == '%') continue;
        if (j < format.len and (format[j] == '+' or format[j] == '-' or format[j] == ' ')) j += 1;
        if (leads.len > 0) {
            if (j >= format.len or std.mem.findScalar(u8, leads, format[j]) == null) continue;
            j += 1;
        }
        if (j < format.len and std.mem.findScalar(u8, letters, format[j]) != null) return true;
    }
    return false;
}

fn formatSubst(wk: *Walk, commit: Oid, src: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = src;
    while (true) {
        const b = std.mem.find(u8, rest, "$Format:") orelse break;
        const c = std.mem.findScalarPos(u8, rest, b + 8, '$') orelse break;
        try out.appendSlice(wk.a, rest[0..b]);
        try pretty.formatCommit(wk.a, wk.io, .{ .db = wk.repo.objectDatabase(), .oid = commit, .format = rest[b + 8 .. c] }, &out, try wk.formatContext(rest[b + 8 .. c]));
        rest = rest[c + 1 ..];
    }
    try out.appendSlice(wk.a, rest);
    return out.items;
}

fn anyMatch(a: Allocator, io: Io, db: *odb_mod.Odb, tree_oid: Oid, base: []const u8, spec: *const pathspec_mod.Pathspec, depth: u32, max_depth: u32) Error!bool {
    if (depth > max_depth) return error.TreeTooDeep;
    const found = try db.read(io, tree_oid);
    defer db.allocator().free(found.bytes);
    const tree = object.Tree.parse(db.objectFormat(), found.bytes);
    var it = tree.iterate();
    while (try it.next()) |entry| {
        const path = try std.mem.concat(a, u8, &.{ base, entry.name });
        if (entry.mode == .tree) {
            if (spec.matchesDir(path)) return true;
            if (spec.couldMatchUnder(path) and try anyMatch(a, io, db, entry.oid, try std.mem.concat(a, u8, &.{ path, "/" }), spec, depth + 1, max_depth)) return true;
        } else if (spec.matches(path)) return true;
    }
    return false;
}

/// `tar.umask`, read as git reads an integer: `0x` for hexadecimal, a
/// leading `0` for octal; `user` is the process's own umask.
fn tarUmask(repo: *Repository, user: ?u32) Error!u32 {
    const raw = repo.configuration().get("tar.umask") orelse return 0o002;
    const text = std.mem.trim(u8, raw, " \t");
    if (std.mem.eql(u8, text, "user")) return user orelse fs.processUmask();
    // git's `git_config_int`: base 0 and a size suffix, as every integer
    // setting is read.
    const value = config_mod.parseInteger(c_int, text) catch return error.InvalidTarUmask;
    return @intCast(value & 0o7777);
}

/// The tree a tree-ish names, the commit it came from, and that commit's
/// time, or `now` for a tree that came from none.
fn peel(gpa: Allocator, io: Io, db: *odb_mod.Odb, treeish: Oid, now: i64) Error!struct { tree: Oid, commit: ?Oid, time: i64 } {
    var commit: ?Oid = null;
    var tree = treeish;
    var time = now;
    for (0..64) |_| {
        const header = try db.readHeader(io, tree);
        switch (header.type) {
            .tree => return .{ .tree = tree, .commit = commit, .time = time },
            .commit => {
                const found = try db.read(io, tree);
                defer db.allocator().free(found.bytes);
                var c = try object.Commit.parse(gpa, db.objectFormat(), found.bytes);
                defer c.deinit();
                commit = tree;
                time = c.committer.when_secs;
                tree = c.tree;
            },
            .tag => {
                const found = try db.read(io, tree);
                defer db.allocator().free(found.bytes);
                var t = object.Tag.parse(gpa, db.objectFormat(), found.bytes) catch return error.NotATree;
                defer t.deinit();
                tree = t.target;
            },
            else => return error.NotATree,
        }
    }
    return error.NotATree;
}

/// `git archive <tree-ish> [<path>...]`: write the archive to `w`.
pub const Inputs = struct { repo: *Repository, treeish: Oid };

pub fn archive(gpa: Allocator, io: Io, w: *Io.Writer, inputs: Inputs, options: Options) Self.Error!void {
    const repo = inputs.repo;
    const treeish = inputs.treeish;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();
    const db = repo.objectDatabase();

    const peeled = try peel(gpa, io, db, treeish, date.seconds(options.now));
    const commit = peeled.commit;
    const tree = peeled.tree;
    const time = if (options.mtime) |m| date.seconds(m) else peeled.time;

    // each pathspec must name something, as git checks
    for (options.pathspecs) |p| {
        if (p.len == 0) continue;
        var one = try pathspec_mod.parse(gpa, &.{p});
        defer one.deinit();
        if (!try anyMatch(a, io, db, tree, "", &one, 0, inputs.repo.settings().max_tree_depth)) return error.PathspecNoMatch;
    }
    var spec = try pathspec_mod.parse(gpa, options.pathspecs);
    defer spec.deinit();

    // the attributes: the tree's own files, or the working tree's
    // git reads the archived tree's in its index direction, where
    // `attr.tree` has no say, and the working tree's as a checkin does.
    var attrs = if (options.worktree_attributes) try repo.loadAttrs(io) else try repo.loadGlobalAttrs(io);
    defer attrs.deinit();
    defer attrs.leave();
    if (!options.worktree_attributes) {
        const flat = try worktree.flatten(a, io, db, tree);
        try worktree.addTreeAttributes(a, io, db, &attrs, &flat);
    }
    const rules = try repo.worktreeRules();
    var conv: convert.Session = .open(gpa, io, .{
        .wt = repo.topDirectory().get(),
        .kind = db.objectFormat(),
        .core = rules.core,
        .required_filters = try repo.requiredFilters(a),
        .programs = options.programs,
    });
    defer conv.deinit(io);

    var wk: Walk = .{
        .gpa = gpa,
        .a = a,
        .io = io,
        .repo = repo,
        .options = options,
        .attrs = &attrs,
        .conv = &conv,
        .spec = &spec,
        .commit = commit,
        .abbrev_len = abbrev.defaultLength(repo.configuration(), db),
        .big_file_bytes = try odb_policy.bigFileThreshold(repo.configuration()),
        .format = options.format,
    };
    defer wk.deinit();
    var tar: Tar = undefined;
    var zip: Zip = undefined;
    var filter: Filter = .{ .piped = .init(gpa) };
    defer filter.deinit();
    switch (options.format) {
        .tar, .filtered => {
            tar = .{ .w = try filter.open(gpa, repo.configuration(), options, w), .umask = try tarUmask(repo, options.user_umask), .time = @bitCast(time) };
            try tarGlobalHeader(&tar, a, commit);
            wk.tar = &tar;
        },
        .zip => {
            if (options.level) |level| if (level > 9) return error.LevelNotSupported;
            // git holds a time unsigned, so one before 1970 is past any
            // date a zip can carry, and git's archive stops there.
            const unsigned = std.math.cast(u64, time) orelse return error.TimestampTooLarge;
            // git's `dos_time`: the calendar in the zip's zone, and a time
            // the zone moves past what a timestamp holds is past it too.
            const c = date.calendarIn(time, date.tzInt(options.zip_offset_minutes)) orelse return error.TimestampTooLarge;
            const year: i64 = c.year - 1980;
            zip = .{
                .w = w,
                .a = a,
                .gpa = gpa,
                // A year's bits past seven are cut off, as git's `put_le16` cuts them.
                .dos_date = @truncate(@as(u64, @bitCast(@as(i64, c.day) + (@as(i64, c.month) + 1) * 32 + year * 512))),
                // Each field held to its bits: 31 + 63 * 32 + 31 * 2048 is the
                // most a u16 holds.
                .dos_time = @as(u16, c.second) / 2 + @as(u16, c.minute) * 32 + @as(u16, c.hour) * 2048,
                .time = unsigned,
                .level = options.level,
            };
            wk.zip = &zip;
        },
    }
    // a prefix that is a directory is an entry of its own
    if (options.prefix.len > 0 and options.prefix[options.prefix.len - 1] == '/') {
        var len = options.prefix.len;
        while (len > 1 and options.prefix[len - 2] == '/') len -= 1;
        try wk.emit(tree, options.prefix[0..len], 0o040777, .{});
    }
    try wk.walk(tree, "");
    switch (options.format) {
        .tar, .filtered => {
            try tar.trailer();
            try filter.finish(gpa, io, options, w);
        },
        .zip => try zipTrailer(&zip, commit),
    }
}

/// Where a tar goes: to the archive's writer as it is, through gzip made
/// here, or gathered for its filter's command.
const Filter = struct {
    gzip: ?warp.Deflate = null,
    gzip_writer: warp.Deflate.Writer = undefined,
    gzip_buffer: [16384]u8 = undefined,
    piped: Io.Writer.Allocating,
    command: ?[]const u8 = null,

    /// Where the tar is written.
    fn open(f: *Filter, gpa: Allocator, config: *const config_mod.Config, options: Options, w: *Io.Writer) Error!*Io.Writer {
        const name = switch (options.format) {
            .filtered => |name| name,
            else => return w,
        };
        const line = filterCommand(config, name) orelse return error.UnknownFormat;
        if (!std.mem.eql(u8, line, internal_gzip)) {
            f.command = line;
            return &f.piped.writer;
        }
        const level = options.level orelse 6;
        if (level > 9) return error.LevelNotSupported;
        f.gzip = try warp.Deflate.init(gpa, .{ .level = level, .container = .gzip, .gzip = .{ .os = 3, .xfl = zlibXfl(level) } });
        f.gzip_writer = .init(&f.gzip.?, w, &f.gzip_buffer);
        return &f.gzip_writer.interface;
    }

    /// The archive's end: gzip's, or `<command> [-<level>]` run through
    /// the shell with the tar on its input and its output the archive.
    fn finish(f: *Filter, gpa: Allocator, io: Io, options: Options, w: *Io.Writer) Error!void {
        if (f.gzip != null) return f.gzip_writer.finish();
        const line = f.command orelse return;
        const programs = options.programs orelse return error.FilterNotRun;
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(gpa);
        try command.appendSlice(gpa, line);
        if (options.level) |l| try command.print(gpa, " -{d}", .{l});
        var outcome = try program.run(gpa, io, programs, .{
            .argv = &.{command.items},
            .shell = true,
            .stderr = if (options.filter_messages != null) .capture else .inherit,
        }, .{ .input = f.piped.written() });
        defer outcome.deinit(gpa);
        if (options.filter_messages) |messages| try messages.writeAll(outcome.stderr);
        if (!outcome.succeeded()) return error.FilterFailed;
        try w.writeAll(outcome.stdout);
    }

    fn deinit(f: *Filter) void {
        if (f.gzip) |*d| d.deinit();
        f.piped.deinit();
    }
};

test "a tar header's checksum and octal fields are git's" {
    var h: Header = std.mem.zeroes(Header);
    @memcpy(h.name[0..5], "a.txt");
    h.typeflag[0] = '0';
    prepareHeader(&h, 0o100664, 5, 1700000000);
    try std.testing.expectEqualStrings("0000664\x00", &h.mode);
    try std.testing.expectEqualStrings("00000000005\x00", &h.size);
}
