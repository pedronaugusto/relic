//! `git archive`: a tree or a commit written as a tar or zip file, the bytes
//! git writes for the same tree and options.
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
//! Attributes come from the tree being archived, as git reads them, or the
//! working tree's with `worktree_attributes`: `export-ignore` leaves a path
//! out, `export-subst` expands `$Format:...$` (`pretty.zig`), and line
//! endings, `ident` and filters apply as a checkout applies them.

const Self = @This();

const std = @import("std");
const warp = @import("warp");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("hash/hash.zig");
const object = @import("object/object.zig");
const odb_mod = @import("odb/odb.zig");
const repo_mod = @import("repo/repo.zig");
const worktree = @import("checkout/checkout.zig");
const attributes = @import("patterns.zig").attributes;
const convert = @import("checkout/convert.zig");
const pathspec_mod = @import("patterns.zig").pathspec;
const pretty = @import("pretty/pretty.zig");
const message = @import("object/message.zig");
const abbrev = @import("odb/abbrev.zig");
const mailfmt = @import("mail/format.zig");
const program = @import("process.zig").program;
const fs = @import("fs/fs.zig");
const mailmap_mod = @import("revwalk/mailmap.zig");
const signing = @import("object/signing.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from archiving.
pub const Error = error{
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
    /// it, as git's does.
    TimestampTooLarge,
} || pretty.Error || pretty.Decorations.LoadError || mailmap_mod.LoadError || pathspec_mod.Error || worktree.Error || convert.Error || attributes.Error ||
    repo_mod.Error || Io.Writer.Error || object.TreeParseError;

/// The archive kinds.
pub const Format = enum { tar, zip };

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
    mtime: ?i64 = null,
    /// The time now, for a tree archived without `mtime`.
    now: i64 = 0,
    /// `--worktree-attributes`: the working tree's `.gitattributes`
    /// rather than the tree's.
    worktree_attributes: bool = false,
    /// The zip's compression level, `-0` to `-9`: zero stores. `null` is
    /// zlib's default.
    level: ?u4 = null,
    /// Minutes east of UTC that the zip's DOS times are written in: git
    /// writes the machine's local time.
    zip_offset_minutes: i32 = 0,
    /// The programs filters run through, and the signature programs
    /// `%G?` in an `export-subst` file asks of a signed commit.
    programs: ?program.Programs = null,
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
    assert(v == 0);
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

fn tarEntry(t: *Tar, a: Allocator, oid: Oid, path: []const u8, mode_in: u32, content: []const u8) Error!void {
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
    var size_in_header: u64 = content.len;
    if (kind == 0o100000 and content.len > ustar_max_size) {
        size_in_header = 0;
        try appendExtHeader(a, &ext, "size", try a.print("{d}", .{content.len}));
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
    if (kind == 0o100000 and content.len > 0) try t.writeBlocked(content);
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
    var compress = try warp.Compressor.init(gpa, .{ .level = level orelse 6, .max_input = data.len });
    defer compress.deinit();
    const frame: warp.Compressor.Frame = .{ .container = .raw };
    const out = try gpa.alloc(u8, warp.Compressor.bound(data.len, frame));
    errdefer gpa.free(out);
    const n = compress.compress(data, out, frame) catch unreachable; // unreachable: bound reserves the complete stream
    return gpa.realloc(out, n);
}

fn zipEntry(z: *Zip, path: []const u8, mode: u32, content: []const u8, is_binary: bool) Error!void {
    const a = z.a;
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
        crc = warp.Crc32.hash(content);
        text = !is_binary;
        out = content;
        compressed_size = content.len;
        if (kind == 0o100000 and (z.level == null or z.level.? != 0) and content.len > 0) {
            method = 8;
            deflated = try deflateRaw(z.gpa, content, z.level);
            if (deflated.?.len >= content.len) {
                method = 0;
            } else {
                out = deflated.?;
                compressed_size = deflated.?.len;
            }
        }
    }
    if (creator_version > z.max_creator_version) z.max_creator_version = creator_version;
    const offset = z.offset;
    const size: u64 = content.len;
    var extra: [9]u8 = undefined;
    std.mem.writeInt(u16, extra[0..2], 0x5455, .little);
    std.mem.writeInt(u16, extra[2..4], 5, .little);
    extra[4] = 1;
    std.mem.writeInt(u32, extra[5..9], @truncate(z.time), .little);
    // Past four gigabytes the sizes go in a zip64 extra field, as git's
    // `write_zip_entry` puts them, and the header says 0xffffffff.
    const zip64 = size > 0xffffffff or compressed_size > 0xffffffff;
    var header: std.ArrayList(u8) = .empty;
    try z.le(&header, 4, 0x04034b50);
    try z.le(&header, 2, if (zip64) 45 else 10);
    try z.le(&header, 2, flags);
    try z.le(&header, 2, method);
    try z.le(&header, 2, z.dos_time);
    try z.le(&header, 2, z.dos_date);
    try z.le(&header, 4, crc);
    try z.le(&header, 4, if (zip64) 0xffffffff else compressed_size);
    try z.le(&header, 4, if (zip64) 0xffffffff else size);
    try z.le(&header, 2, path.len);
    try z.le(&header, 2, extra.len + if (zip64) @as(usize, 20) else 0);
    // The local header is fixed at thirty bytes before its name and extra.
    assert(header.items.len == 30);
    if (zip64) {
        try z.le(&header, 2, 0x0001);
        try z.le(&header, 2, 16);
        try z.le(&header, 8, size);
        try z.le(&header, 8, compressed_size);
    }
    try z.write(header.items[0..30]);
    try z.write(path);
    try z.write(&extra);
    try z.write(header.items[30..]);
    if (compressed_size > 0) try z.write(out);

    // The directory holds each of the three that does not fit in four
    // bytes as 0xffffffff, and its value in a zip64 extra field.
    var zip64_payload: u16 = 0;
    if (compressed_size > 0xffffffff or size > 0xffffffff or offset > 0xffffffff) {
        if (compressed_size >= 0xffffffff) zip64_payload += 8;
        if (size >= 0xffffffff) zip64_payload += 8;
        if (offset >= 0xffffffff) zip64_payload += 8;
    }
    const dir_extra_len = extra.len + if (zip64_payload != 0) 4 + @as(usize, zip64_payload) else 0;
    const dir_start = z.dir.items.len;
    try z.le(&z.dir, 4, 0x02014b50);
    try z.le(&z.dir, 2, creator_version);
    try z.le(&z.dir, 2, 10);
    try z.le(&z.dir, 2, flags);
    try z.le(&z.dir, 2, method);
    try z.le(&z.dir, 2, z.dos_time);
    try z.le(&z.dir, 2, z.dos_date);
    try z.le(&z.dir, 4, crc);
    try z.le(&z.dir, 4, @min(compressed_size, 0xffffffff));
    try z.le(&z.dir, 4, @min(size, 0xffffffff));
    try z.le(&z.dir, 2, path.len);
    try z.le(&z.dir, 2, dir_extra_len);
    try z.le(&z.dir, 2, 0);
    try z.le(&z.dir, 2, 0);
    try z.le(&z.dir, 2, @intFromBool(text));
    try z.le(&z.dir, 4, attr2);
    try z.le(&z.dir, 4, @min(offset, 0xffffffff));
    try z.dir.appendSlice(a, path);
    try z.dir.appendSlice(a, &extra);
    if (zip64_payload != 0) {
        try z.le(&z.dir, 2, 0x0001);
        try z.le(&z.dir, 2, zip64_payload);
        if (size >= 0xffffffff) try z.le(&z.dir, 8, size);
        if (compressed_size >= 0xffffffff) try z.le(&z.dir, 8, compressed_size);
        if (offset >= 0xffffffff) try z.le(&z.dir, 8, offset);
    }
    // A central directory record is forty-six bytes, then the name and the
    // extra fields; the trailer counts the directory by these.
    assert(z.dir.items.len - dir_start == 46 + path.len + dir_extra_len);
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
            wk.decorations = try pretty.Decorations.load(wk.gpa, wk.io, wk.repo);
        if (wk.signer == null and hasPlaceholder(format, "", "G")) if (wk.options.programs) |programs| {
            wk.signer = try signing.Signer.init(wk.gpa, wk.repo.configuration(), programs);
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
            if (wk.repo.workDirectory()) |wt| try wk.attrs.enter(wk.io, wt, path);
        }
        return wk.attrs.lookup(wk.a, path, is_dir);
    }

    fn emit(wk: *Walk, oid: Oid, path: []const u8, mode: u32, content: []const u8, is_binary: bool) Error!void {
        if (wk.tar) |t| try tarEntry(t, wk.a, oid, path, mode, content) else try zipEntry(wk.zip.?, path, mode, content, is_binary);
    }

    fn writeQueued(wk: *Walk) Error!void {
        while (wk.written_dirs < wk.queued.items.len) : (wk.written_dirs += 1) {
            const d = wk.queued.items[wk.written_dirs];
            try wk.emit(d.oid, d.path, d.mode, "", false);
        }
    }

    fn walk(wk: *Walk, tree_oid: Oid, base: []const u8) Error!void {
        // The directories queued are the ones this walk is inside.
        if (wk.queued.items.len > object.max_tree_depth) return error.TreeTooDeep;
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
                if (applied.isSet("export-ignore")) continue;
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
            if (applied.isSet("export-ignore")) continue;
            const out_path = if (entry.mode == .gitlink)
                try std.mem.concat(wk.a, u8, &.{ wk.options.prefix, path, "/" })
            else
                try std.mem.concat(wk.a, u8, &.{ wk.options.prefix, path });
            if (entry.mode == .gitlink) {
                try wk.emit(entry.oid, out_path, mode, "", false);
                continue;
            }
            const blob = try db.read(wk.io, entry.oid);
            defer db.allocator().free(blob.bytes);
            var content: []const u8 = blob.bytes;
            if (entry.mode != .symlink) {
                const smudged = try wk.conv.toWorktree(wk.a, .{ .path = path, .blob = content, .applied = applied }, .{ .blob = entry.oid, .treeish = wk.commit });
                content = switch (smudged) {
                    .bytes => |b| b,
                    else => return error.UnsupportedAttribute,
                };
                if (wk.commit) |c| {
                    if (applied.isSet("export-subst")) content = try formatSubst(wk, c, content);
                }
            }
            var is_binary = false;
            if (wk.format == .zip and entry.mode != .symlink) {
                is_binary = if (applied.get("diff")) |state| switch (state) {
                    .unset => true,
                    .set => false,
                    else => isBinary(content),
                } else isBinary(content);
            } else if (wk.format == .zip) is_binary = isBinary(content);
            try wk.emit(entry.oid, out_path, mode, content, is_binary);
        }
    }
};

fn isBinary(bytes: []const u8) bool {
    const n = @min(bytes.len, 8000);
    return std.mem.findScalar(u8, bytes[0..n], 0) != null;
}

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

fn anyMatch(a: Allocator, io: Io, db: *odb_mod.Odb, tree_oid: Oid, base: []const u8, spec: *const pathspec_mod.Pathspec, depth: u32) Error!bool {
    if (depth > object.max_tree_depth) return error.TreeTooDeep;
    const found = try db.read(io, tree_oid);
    defer db.allocator().free(found.bytes);
    const tree = object.Tree.parse(db.objectFormat(), found.bytes);
    var it = tree.iterate();
    while (try it.next()) |entry| {
        const path = try std.mem.concat(a, u8, &.{ base, entry.name });
        if (entry.mode == .tree) {
            if (spec.matchesDir(path)) return true;
            if (spec.couldMatchUnder(path) and try anyMatch(a, io, db, entry.oid, try std.mem.concat(a, u8, &.{ path, "/" }), spec, depth + 1)) return true;
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
    const value = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        std.fmt.parseInt(u32, text[2..], 16)
    else if (text.len > 1 and text[0] == '0')
        std.fmt.parseInt(u32, text[1..], 8)
    else
        std.fmt.parseInt(u32, text, 10);
    return (value catch return error.InvalidTarUmask) & 0o7777;
}

/// `git archive <tree-ish> [<path>...]`: write the archive to `w`.
pub const Inputs = struct { repo: *Repository, treeish: Oid };

pub fn archive(gpa: Allocator, io: Io, inputs: Inputs, w: *Io.Writer, options: Options) Self.Error!void {
    const repo = inputs.repo;
    const treeish = inputs.treeish;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();
    const db = repo.objectDatabase();

    // the tree, and the commit it came from
    var commit: ?Oid = null;
    var tree = treeish;
    var time: i64 = options.now;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const header = try db.readHeader(io, tree);
        switch (header.type) {
            .tree => break,
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
    } else return error.NotATree;
    if (options.mtime) |m| time = m;

    // each pathspec must name something, as git checks
    for (options.pathspecs) |p| {
        if (p.len == 0) continue;
        var one = try pathspec_mod.parse(gpa, &.{p});
        defer one.deinit();
        if (!try anyMatch(a, io, db, tree, "", &one, 0)) return error.PathspecNoMatch;
    }
    var spec = try pathspec_mod.parse(gpa, options.pathspecs);
    defer spec.deinit();

    // the attributes: the tree's own files, or the working tree's
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    defer attrs.leave();
    if (!options.worktree_attributes) {
        const flat = try worktree.flatten(a, io, db, tree);
        try worktree.addTreeAttributes(a, io, db, &attrs, &flat);
    }
    const rules = try repo.worktreeRules();
    var conv: convert.Session = .open(gpa, io, .{
        .wt = repo.workDirectory() orelse repo.gitDirectory(),
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
        .format = options.format,
    };
    defer wk.deinit();
    var tar: Tar = undefined;
    var zip: Zip = undefined;
    switch (options.format) {
        .tar => {
            tar = .{ .w = w, .umask = try tarUmask(repo, options.user_umask), .time = @bitCast(time) };
            try tarGlobalHeader(&tar, a, commit);
            wk.tar = &tar;
        },
        .zip => {
            // git holds a time unsigned, so one before 1970 is past any
            // date a zip can carry, and git's archive stops there.
            if (time < 0) return error.TimestampTooLarge;
            const c = mailfmt.civil(time + @as(i64, options.zip_offset_minutes) * 60);
            const year: i64 = c.year - 1980;
            zip = .{
                .w = w,
                .a = a,
                .gpa = gpa,
                .dos_date = @truncate(@as(u64, @bitCast(@as(i64, c.day) + @as(i64, c.month) * 32 + year * 512))),
                .dos_time = @intCast(@as(u32, c.second) / 2 + @as(u32, c.minute) * 32 + @as(u32, c.hour) * 2048),
                .time = @intCast(time),
                .level = options.level,
            };
            wk.zip = &zip;
        },
    }
    // a prefix that is a directory is an entry of its own
    if (options.prefix.len > 0 and options.prefix[options.prefix.len - 1] == '/') {
        var len = options.prefix.len;
        while (len > 1 and options.prefix[len - 2] == '/') len -= 1;
        try wk.emit(tree, options.prefix[0..len], 0o040777, "", false);
    }
    try wk.walk(tree, "");
    switch (options.format) {
        .tar => try tar.trailer(),
        .zip => try zipTrailer(&zip, commit),
    }
}

test "a tar header's checksum and octal fields are git's" {
    var h: Header = std.mem.zeroes(Header);
    @memcpy(h.name[0..5], "a.txt");
    h.typeflag[0] = '0';
    prepareHeader(&h, 0o100664, 5, 1700000000);
    try std.testing.expectEqualStrings("0000664\x00", &h.mode);
    try std.testing.expectEqualStrings("00000000005\x00", &h.size);
}
