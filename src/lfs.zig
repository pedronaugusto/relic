//! Git LFS, in process: the pointer a large file is stored as, the local
//! store its content lives in, and the clean and smudge that move between
//! the two.
//!
//! A repository keeps a large file out of its history by storing, in the
//! blob, a pointer of three short lines — a version, the SHA-256 of the
//! content, its size — and the content itself under `.git/lfs/objects`,
//! named by that SHA-256. A `filter=lfs` attribute is what says a path is
//! kept that way. The program that normally does the conversion is git-lfs,
//! run as a filter; this file does the same conversion without it, so a
//! repository that keeps its large files this way is read and written with
//! no program installed, and what it writes is byte for byte what git-lfs
//! writes: the same pointer, the same object at the same path.
//!
//! What a pointer is follows git-lfs's reader rather than the specification's
//! wording, because the question that matters is whether git-lfs would read
//! a blob as one. It looks at the first 1024 bytes, trims white space from
//! both ends, and asks for `version`, `oid` and `size` in that order; an
//! extension line may come before `size`; a carriage return before a line
//! feed is dropped; empty content is the pointer of an empty file. Anything
//! it would not read as a pointer is content, and is passed through.
//!
//! Checkout never fails for want of an object. A pointer whose object is not
//! in the store is written to the working tree as it stands and named in the
//! outcome, which is what git-lfs does when it is told to skip the download.
//! Fetching the object is a transfer over the network and belongs to whoever
//! holds the connection; `Fetcher` is where it plugs in.
//!
//! An LFS extension (`lfs.extension.<name>.clean`) is a program run around
//! the content, and a pointer that names one is refused by name rather than
//! smudged without it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const config_mod = @import("config.zig");
const fs = @import("fs.zig");
const wildmatch = @import("wildmatch.zig");

/// The version line every pointer written carries.
pub const spec_version = "https://git-lfs.github.com/spec/v1";

/// The versions a pointer may name and still be read: the public one and the
/// two it replaced.
pub const accepted_versions = [_][]const u8{
    "http://git-media.io/v/2",
    "https://hawser.github.com/spec/v1",
    spec_version,
};

/// How much of a blob is read when asking whether it is a pointer. A blob
/// this long or longer is never listed as one by git-lfs's scanners.
pub const pointer_size_cutoff = 1024;

/// The SHA-256 of nothing, which is the object an empty file would be.
pub const empty_oid: [64]u8 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".*;

/// A pointer: what an LFS-tracked file is stored as in the object database.
pub const Pointer = struct {
    /// The SHA-256 of the content, in lower-case hexadecimal.
    oid: [64]u8,
    /// The length of the content.
    size: u64,
    /// Extensions, lowest priority first. Their names borrow the bytes the
    /// pointer was decoded from.
    extensions: [max_extensions]Extension = undefined,
    extension_count: u8 = 0,

    /// One `ext-<priority>-<name> sha256:<oid>` line: a program applied to
    /// the content before it was stored.
    pub const Extension = struct {
        priority: u8,
        name: []const u8,
        oid: [64]u8,
    };

    /// Priorities are one digit, and no two may be the same.
    pub const max_extensions = 10;

    /// The longest encoding: the version line, ten extensions, the oid and a
    /// size.
    pub const max_encoded_len = 512 + max_extensions * (16 + 64 + 64);

    /// Why bytes are not a pointer. Either way git-lfs would not read them
    /// as one, and they are content.
    pub const DecodeError = error{
        /// No marker, a line with no space, a line after `size`, or no
        /// version.
        NotAPointer,
        /// Shaped like a pointer, with a value that is not valid: a version
        /// that is not one of the three, an oid that is not sixty-four
        /// lower-case hexadecimal digits, a size that is not a count, an
        /// unknown key, or two extensions at one priority.
        BadPointer,
    };

    /// The extensions, lowest priority first.
    pub fn exts(p: *const Pointer) []const Extension {
        return p.extensions[0..p.extension_count];
    }

    /// Read `bytes` as git-lfs reads them: the first 1024, trimmed.
    pub fn decode(bytes: []const u8) DecodeError!Pointer {
        const head = bytes[0..@min(bytes.len, pointer_size_cutoff)];
        if (head.len == 0) return .{ .oid = empty_oid, .size = 0 };
        const data = trimSpace(head);
        if (std.mem.indexOf(u8, data, "git-media") == null and
            std.mem.indexOf(u8, data, "hawser") == null and
            std.mem.indexOf(u8, data, "git-lfs") == null)
        {
            return error.NotAPointer;
        }

        const keys = [_][]const u8{ "version", "oid", "size" };
        var values: [3][]const u8 = .{ "", "", "" };
        var ext_keys: [max_extensions][]const u8 = undefined;
        var ext_values: [max_extensions][]const u8 = undefined;
        var ext_count: usize = 0;
        var line: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            // A carriage return before the line feed is not part of the
            // line, and an empty line is no line at all.
            const text = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            if (text.len == 0) continue;
            const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.NotAPointer;
            const key = text[0..space];
            const value = text[space + 1 ..];
            if (line >= keys.len) return error.NotAPointer;
            if (!std.mem.eql(u8, key, keys[line])) {
                if (!isExtensionKey(key)) return error.BadPointer;
                // The same key twice keeps the later value, and more distinct
                // keys than there are priorities cannot all be valid.
                for (ext_keys[0..ext_count], 0..) |seen, i| {
                    if (std.mem.eql(u8, seen, key)) {
                        ext_values[i] = value;
                        break;
                    }
                } else {
                    if (ext_count == max_extensions) return error.BadPointer;
                    ext_keys[ext_count] = key;
                    ext_values[ext_count] = value;
                    ext_count += 1;
                }
                continue;
            }
            values[line] = value;
            line += 1;
        }

        if (values[0].len == 0) return error.NotAPointer;
        for (accepted_versions) |version| {
            if (std.mem.eql(u8, values[0], version)) break;
        } else return error.BadPointer;
        if (line < 2) return error.BadPointer;
        var p: Pointer = .{ .oid = try parseOid(values[1]), .size = try parseSize(values[2]) };

        for (ext_keys[0..ext_count], ext_values[0..ext_count]) |key, value| {
            const priority = key["ext-".len] - '0';
            for (p.exts()) |existing| {
                if (existing.priority == priority) return error.BadPointer;
            }
            p.extensions[p.extension_count] = .{
                .priority = priority,
                .name = key["ext-0-".len..],
                .oid = try parseOid(value),
            };
            p.extension_count += 1;
        }
        std.mem.sort(Extension, p.extensions[0..p.extension_count], {}, lowerPriority);
        return p;
    }

    /// The canonical bytes: the version, the extensions by priority, the oid
    /// and the size, each on a line of its own. A pointer to nothing is no
    /// bytes at all, which is what git-lfs writes for an empty file.
    pub fn encode(p: *const Pointer, w: *Io.Writer) Io.Writer.Error!void {
        if (p.size == 0) return;
        try w.print("version {s}\n", .{spec_version});
        for (p.exts()) |ext| try w.print("ext-{d}-{s} sha256:{s}\n", .{ ext.priority, ext.name, &ext.oid });
        try w.print("oid sha256:{s}\nsize {d}\n", .{ &p.oid, p.size });
    }

    /// `encode` into a buffer of the caller's.
    pub fn encodeBuf(p: *const Pointer, buf: *[max_encoded_len]u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        p.encode(&w) catch unreachable;
        return w.buffered();
    }

    fn lowerPriority(_: void, a: Extension, b: Extension) bool {
        return a.priority < b.priority;
    }
};

/// `ext-`, one digit, `-`, then at least one word character; what follows
/// is part of the name.
fn isExtensionKey(key: []const u8) bool {
    if (key.len < "ext-0-a".len) return false;
    if (!std.mem.startsWith(u8, key, "ext-")) return false;
    if (!std.ascii.isDigit(key[4]) or key[5] != '-') return false;
    const c = key[6];
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn parseOid(value: []const u8) Pointer.DecodeError![64]u8 {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.BadPointer;
    if (!std.mem.eql(u8, value[0..colon], "sha256")) return error.BadPointer;
    const hex = value[colon + 1 ..];
    if (hex.len != 64) return error.BadPointer;
    for (hex) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return error.BadPointer,
    };
    return hex[0..64].*;
}

/// A signed decimal that fits in 63 bits and is not below zero, which is
/// what git-lfs's `strconv.ParseInt` accepts: `+6` and `-0` included.
fn parseSize(value: []const u8) Pointer.DecodeError!u64 {
    var digits = value;
    var negative = false;
    if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) {
        negative = digits[0] == '-';
        digits = digits[1..];
    }
    if (digits.len == 0) return error.BadPointer;
    var n: u64 = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return error.BadPointer;
        n = std.math.mul(u64, n, 10) catch return error.BadPointer;
        n = std.math.add(u64, n, c - '0') catch return error.BadPointer;
    }
    if (n > std.math.maxInt(i64)) return error.BadPointer;
    if (negative and n != 0) return error.BadPointer;
    return n;
}

/// Go's `bytes.TrimSpace`: ASCII white space, and the Unicode spaces encoded
/// as UTF-8, from both ends.
fn trimSpace(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len) {
        const n = spaceAt(bytes[start..]);
        if (n == 0) break;
        start += n;
    }
    var end = bytes.len;
    while (end > start) {
        const n = spaceEndingAt(bytes[start..end]);
        if (n == 0) break;
        end -= n;
    }
    return bytes[start..end];
}

/// The length of the white space at the front of `bytes`, or zero.
fn spaceAt(bytes: []const u8) usize {
    const c = bytes[0];
    if (c < 0x80) return if (isAsciiSpace(c)) 1 else 0;
    const len = std.unicode.utf8ByteSequenceLength(c) catch return 0;
    if (len > bytes.len) return 0;
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return 0;
    return if (isUnicodeSpace(cp)) len else 0;
}

/// The length of the white space at the end of `bytes`, or zero.
fn spaceEndingAt(bytes: []const u8) usize {
    const last = bytes[bytes.len - 1];
    if (last < 0x80) return if (isAsciiSpace(last)) 1 else 0;
    // A multi-byte space is two or three bytes long.
    var len: usize = 2;
    while (len <= 3 and len <= bytes.len) : (len += 1) {
        const seq = bytes[bytes.len - len ..];
        const want = std.unicode.utf8ByteSequenceLength(seq[0]) catch continue;
        if (want != len) continue;
        const cp = std.unicode.utf8Decode(seq) catch return 0;
        return if (isUnicodeSpace(cp)) len else 0;
    }
    return 0;
}

fn isAsciiSpace(c: u8) bool {
    return switch (c) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => true,
        else => false,
    };
}

fn isUnicodeSpace(cp: u21) bool {
    return switch (cp) {
        0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// The local store: `<git common dir>/lfs/objects/<aa>/<bb>/<oid>`, or
/// under `lfs.storage`.
pub const Store = struct {
    /// What a relative `root` is resolved from: the repository's common
    /// directory. Borrowed.
    base: Io.Dir,
    /// `lfs`, or `lfs.storage`, `/`-separated. An absolute path stands on
    /// its own.
    root: []const u8,

    /// The longest path `objectPath` writes.
    pub const max_path = std.fs.max_path_bytes;

    /// Where an object lives, written into `buf`.
    pub fn objectPath(store: *const Store, buf: *[max_path]u8, oid: *const [64]u8) error{NameTooLong}![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/objects/{s}/{s}/{s}", .{ store.root, oid[0..2], oid[2..4], oid }) catch
            error.NameTooLong;
    }

    /// The object, opened for reading, when the store holds it at the size
    /// the pointer says. An object of any other size is not that object, and
    /// is `null` as a missing one is. The file is the caller's to close.
    pub fn open(store: *const Store, io: Io, pointer: *const Pointer) OpenError!?Io.File {
        var buf: [max_path]u8 = undefined;
        const path = try store.objectPath(&buf, &pointer.oid);
        const file = store.base.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => |e| return e,
        };
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size != pointer.size) {
            file.close(io);
            return null;
        }
        return file;
    }

    /// Errors from opening an object.
    pub const OpenError = error{NameTooLong} || Io.File.OpenError || Io.File.StatError;

    /// Whether the store holds the object at the size the pointer says.
    pub fn contains(store: *const Store, io: Io, pointer: *const Pointer) OpenError!bool {
        const file = (try store.open(io, pointer)) orelse return false;
        file.close(io);
        return true;
    }

    /// Errors from putting an object in the store.
    pub const InstallError = error{
        NameTooLong,
        /// The bytes are not the object `expected` named: another SHA-256,
        /// or another length. Nothing was installed.
        LfsObjectMismatch,
    } || Io.Reader.ShortError || Io.File.Writer.Error || Io.File.OpenError ||
        Io.Dir.CreateDirPathError || Io.Dir.RenameError || Io.File.StatError;

    /// Copy `source` to its end into the store, naming it by the SHA-256
    /// taken on the way in, and return its pointer.
    ///
    /// The bytes go into `<root>/tmp` and are renamed into place, so a
    /// reader never sees part of an object. An object already there at the
    /// right size is kept and the copy dropped. With `expected`, bytes that
    /// are not that object are `error.LfsObjectMismatch` and are not
    /// installed, which is what a fetch hands in. A read that fails is
    /// `error.ReadFailed`, and the reason is on the reader.
    pub fn install(store: *const Store, io: Io, source: *Io.Reader, expected: ?*const Pointer) InstallError!Pointer {
        var tmp_dir_buf: [max_path]u8 = undefined;
        const tmp_dir = std.fmt.bufPrint(&tmp_dir_buf, "{s}/tmp", .{store.root}) catch return error.NameTooLong;
        try store.base.createDirPath(io, tmp_dir);
        var name_buf: [64]u8 = undefined;
        const name = fs.tempName(io, &name_buf, "relic-");
        var tmp_buf: [max_path]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}/{s}", .{ tmp_dir, name }) catch return error.NameTooLong;

        const file = try store.base.createFile(io, tmp_path, .{ .exclusive = true });
        var installed = false;
        defer if (!installed) store.base.deleteFile(io, tmp_path) catch {};

        var pointer: Pointer = undefined;
        {
            defer file.close(io);
            var out_buf: [64 * 1024]u8 = undefined;
            var fw = file.writer(io, &out_buf);
            pointer = copyHashing(source, &fw.interface) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return fw.err.?,
            };
            fw.interface.flush() catch return fw.err.?;
        }
        if (expected) |want| {
            if (!std.mem.eql(u8, &want.oid, &pointer.oid) or want.size != pointer.size) return error.LfsObjectMismatch;
        }

        var object_buf: [max_path]u8 = undefined;
        const object_path = try store.objectPath(&object_buf, &pointer.oid);
        if (try store.contains(io, &pointer)) return pointer;
        try store.base.createDirPath(io, std.fs.path.dirnamePosix(object_path).?);
        try fs.renameWithRetry(io, store.base, tmp_path, object_path);
        installed = true;
        return pointer;
    }
};

/// The pointer of everything `source` holds, without storing it.
pub fn hashOnly(source: *Io.Reader) Io.Reader.ShortError!Pointer {
    return copyHashing(source, null) catch |err| switch (err) {
        error.ReadFailed => error.ReadFailed,
        error.WriteFailed => unreachable,
    };
}

fn copyHashing(source: *Io.Reader, sink: ?*Io.Writer) (Io.Reader.ShortError || Io.Writer.Error)!Pointer {
    var sha: Sha256 = .init(.{});
    var size: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try source.readSliceShort(&buf);
        if (n == 0) break;
        sha.update(buf[0..n]);
        if (sink) |w| try w.writeAll(buf[0..n]);
        size += n;
        if (n < buf.len) break;
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    sha.final(&digest);
    var p: Pointer = .{ .oid = undefined, .size = size };
    _ = std.fmt.bufPrint(&p.oid, "{x}", .{&digest}) catch unreachable;
    return p;
}

/// What decides which objects a checkout asks to have fetched, and whether
/// it asks at all.
pub const Settings = struct {
    /// `lfs.fetchinclude`: when there are any, only a path one of them names
    /// is fetched.
    fetch_include: []const []const u8 = &.{},
    /// `lfs.fetchexclude`: a path one of these names is not fetched.
    fetch_exclude: []const []const u8 = &.{},
    /// Leave every pointer as it is on checkout, fetching nothing: what
    /// `GIT_LFS_SKIP_SMUDGE` and `git-lfs smudge --skip` ask for.
    skip_smudge: bool = false,
    /// `lfs.url`, for whoever fetches.
    url: ?[]const u8 = null,
    /// `core.ignoreCase`, which the patterns follow.
    case_fold: bool = false,

    /// Whether a checkout may ask for the object behind `path`. An object
    /// already in the store is used whatever this says; these settings only
    /// decide what is fetched.
    pub fn fetchAllowed(s: *const Settings, path: []const u8) bool {
        if (s.skip_smudge) return false;
        if (s.fetch_include.len > 0) {
            for (s.fetch_include) |pattern| {
                if (patternMatches(pattern, path, s.case_fold)) break;
            } else return false;
        }
        for (s.fetch_exclude) |pattern| {
            if (patternMatches(pattern, path, s.case_fold)) return false;
        }
        return true;
    }
};

/// One `lfs.fetchinclude` or `lfs.fetchexclude` pattern against a path, as
/// git-lfs reads it: a pattern names a path or a directory the path is under.
/// Without a slash it names any one component at any depth; with one, or
/// with a leading one, it is matched from the top. A trailing slash changes
/// nothing, and a backslash that escapes nothing is a slash.
pub fn patternMatches(raw_pattern: []const u8, path: []const u8, case_fold: bool) bool {
    var buf: [1024]u8 = undefined;
    if (raw_pattern.len > buf.len) return false;
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw_pattern.len) : (i += 1) {
        const c = raw_pattern[i];
        if (c == '\\') {
            if (i + 1 < raw_pattern.len and std.mem.indexOfScalar(u8, "\\[]*?#", raw_pattern[i + 1]) != null) {
                buf[len] = c;
                buf[len + 1] = raw_pattern[i + 1];
                len += 2;
                i += 1;
                continue;
            }
            buf[len] = '/';
        } else buf[len] = c;
        len += 1;
    }
    var pattern: []const u8 = buf[0..len];
    while (pattern.len > 1 and pattern[pattern.len - 1] == '/') pattern = pattern[0 .. pattern.len - 1];
    if (pattern.len == 0) return false;
    const options: wildmatch.Options = .{ .pathname = true, .case_fold = case_fold };

    const anchored = pattern[0] == '/' or std.mem.indexOfScalar(u8, pattern, '/') != null;
    if (!anchored) {
        var components = std.mem.splitScalar(u8, path, '/');
        while (components.next()) |component| {
            if (wildmatch.match(pattern, component, options) catch false) return true;
        }
        return false;
    }
    if (pattern[0] == '/') pattern = pattern[1..];
    var end: usize = 0;
    while (end <= path.len) : (end += 1) {
        if (end != path.len and path[end] != '/') continue;
        if (wildmatch.match(pattern, path[0..end], options) catch false) return true;
    }
    return false;
}

/// Split a comma-separated pattern list as git-lfs does: each part trimmed,
/// empty parts dropped. The slices borrow `value`.
fn splitPatterns(a: Allocator, value: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len != 0) try out.append(a, trimmed);
    }
    return out.toOwnedSlice(a);
}

/// One object a checkout found missing, for a fetcher to go and get.
pub const Wanted = struct {
    /// The path the pointer was checked out at.
    path: []const u8,
    pointer: Pointer,
};

/// Errors a fetcher may return. Any of them fails the checkout; an object a
/// fetcher could not get and said nothing about is left as a pointer.
pub const FetchError = error{LfsFetchFailed} || Allocator.Error || Io.Cancelable;

/// Where the network plugs in: a caller that can fetch objects hands one to
/// checkout, which calls it once with every object it found missing and then
/// looks in the store again. A fetcher puts what it gets with
/// `Store.install`, naming the pointer it expected.
pub const Fetcher = struct {
    context: *anyopaque,
    fetchFn: *const fn (
        context: *anyopaque,
        io: Io,
        store: *const Store,
        settings: *const Settings,
        wanted: []const Wanted,
    ) FetchError!void,

    /// Ask for `wanted`.
    pub fn fetch(f: Fetcher, io: Io, store: *const Store, settings: *const Settings, wanted: []const Wanted) FetchError!void {
        return f.fetchFn(f.context, io, store, settings, wanted);
    }
};

/// A repository's LFS: its store and its settings, from the configuration
/// and `.lfsconfig`.
pub const Lfs = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    store: Store,
    settings: Settings,

    /// Errors from loading.
    pub const LoadError = Allocator.Error || Io.Dir.ReadFileAllocError ||
        config_mod.ParseError || error{MalformedValue};

    /// How `load` behaves.
    pub const Options = struct {
        /// Leave every pointer as it is on checkout.
        skip_smudge: bool = false,
    };

    /// Read the settings: `lfs.storage` from the configuration, and
    /// `lfs.fetchinclude`, `lfs.fetchexclude` and `lfs.url` from the
    /// configuration or, where it does not set them, from `.lfsconfig` at
    /// the root of `work_dir`. git-lfs lets `.lfsconfig` set only a few keys
    /// and `lfs.storage` is not one of them. `common_dir` is borrowed for as
    /// long as the result lives.
    pub fn load(
        gpa: Allocator,
        io: Io,
        config: *const config_mod.Config,
        common_dir: Io.Dir,
        work_dir: ?Io.Dir,
        options: Options,
    ) LoadError!Lfs {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const a = arena_instance.allocator();

        var file_config: ?config_mod.Config = null;
        defer if (file_config) |*c| c.deinit();
        if (work_dir) |wd| {
            if (try fs.readFileAlloc(a, io, wd, ".lfsconfig", 1 << 20)) |text| {
                file_config = try config_mod.Config.parseText(gpa, text, .local);
            }
        }

        const root = (try config.getPath(a, "lfs.storage")) orelse "lfs";
        const case_fold = config.getBool("core.ignorecase", false) catch false;

        const include = try settingValue(a, config, if (file_config) |*c| c else null, "lfs.fetchinclude");
        const exclude = try settingValue(a, config, if (file_config) |*c| c else null, "lfs.fetchexclude");
        const url = try settingValue(a, config, if (file_config) |*c| c else null, "lfs.url");

        return .{
            .gpa = gpa,
            .arena = arena_instance.state,
            .store = .{ .base = common_dir, .root = root },
            .settings = .{
                .fetch_include = if (include) |v| try splitPatterns(a, v) else &.{},
                .fetch_exclude = if (exclude) |v| try splitPatterns(a, v) else &.{},
                .skip_smudge = options.skip_smudge,
                .url = url,
                .case_fold = case_fold,
            },
        };
    }

    /// Release the settings. The common directory is the caller's.
    pub fn deinit(l: *Lfs) void {
        var arena = l.arena.promote(l.gpa);
        arena.deinit();
        l.* = undefined;
    }
};

fn settingValue(
    a: Allocator,
    config: *const config_mod.Config,
    file_config: ?*const config_mod.Config,
    name: []const u8,
) (Allocator.Error || error{MalformedValue})!?[]const u8 {
    const raw = config.get(name) orelse
        (if (file_config) |c| c.get(name) else null) orelse
        return null;
    return config_mod.unquote(a, raw) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedValue,
    };
}

const testing = std.testing;

fn pointerText(comptime oid: []const u8, comptime size: []const u8) []const u8 {
    return "version https://git-lfs.github.com/spec/v1\noid sha256:" ++ oid ++ "\nsize " ++ size ++ "\n";
}

const hello_oid = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03";

test "a pointer decodes and encodes to the same bytes" {
    const text = pointerText(hello_oid, "6");
    const p = try Pointer.decode(text);
    try testing.expectEqualStrings(hello_oid, &p.oid);
    try testing.expectEqual(@as(u64, 6), p.size);
    var buf: [Pointer.max_encoded_len]u8 = undefined;
    try testing.expectEqualStrings(text, p.encodeBuf(&buf));
}

test "what git-lfs reads as a pointer is one here, spelled any way it accepts" {
    const oid = hello_oid;
    // Carriage returns, blank lines, white space around the whole, a sign
    // on the size, and an older version.
    const accepted = [_][]const u8{
        "version https://git-lfs.github.com/spec/v1\r\noid sha256:" ++ oid ++ "\r\nsize 6\r\n",
        "\n\n  version https://git-lfs.github.com/spec/v1\n\noid sha256:" ++ oid ++ "\nsize 6",
        "version https://git-lfs.github.com/spec/v1\noid sha256:" ++ oid ++ "\nsize +6\n",
        "version https://hawser.github.com/spec/v1\noid sha256:" ++ oid ++ "\nsize 6\n",
        comptime pointerText(oid, "6") ++ "\u{a0}\u{3000}",
    };
    for (accepted) |text| {
        const p = try Pointer.decode(text);
        try testing.expectEqualStrings(oid, &p.oid);
        try testing.expectEqual(@as(u64, 6), p.size);
    }
}

test "what git-lfs does not read as a pointer is content, and the reason is named" {
    const oid = hello_oid;
    const refused = [_]struct { []const u8, Pointer.DecodeError }{
        .{ "hello\n", error.NotAPointer },
        .{ "version https://git-lfs.github.com/spec/v2\noid sha256:" ++ oid ++ "\nsize 6\n", error.BadPointer },
        .{ "version https://git-lfs.github.com/spec/v1\noid sha256:" ++ oid[0..63] ++ "\nsize 6\n", error.BadPointer },
        .{ "version https://git-lfs.github.com/spec/v1\noid sha256:" ++ oid ++ "\nsize -1\n", error.BadPointer },
        .{ "version https://git-lfs.github.com/spec/v1\noid md5:" ++ oid ++ "\nsize 6\n", error.BadPointer },
        .{ "version https://git-lfs.github.com/spec/v1\nsize 6\noid sha256:" ++ oid ++ "\n", error.BadPointer },
        .{ comptime pointerText(oid, "6") ++ "extra line\n", error.NotAPointer },
        .{ "version https://git-lfs.github.com/spec/v1\noid sha256:" ++ oid ++ "\nsize 6 7\n", error.BadPointer },
        .{ "git-lfs\n", error.NotAPointer },
    };
    for (refused) |case| try testing.expectError(case[1], Pointer.decode(case[0]));
}

test "empty content is the pointer of an empty file, which encodes as nothing" {
    const p = try Pointer.decode("");
    try testing.expectEqual(@as(u64, 0), p.size);
    try testing.expectEqualStrings(&empty_oid, &p.oid);
    var buf: [Pointer.max_encoded_len]u8 = undefined;
    try testing.expectEqualStrings("", p.encodeBuf(&buf));
}

test "extensions are read in any order before the size and written by priority" {
    const oid = hello_oid;
    const other = "0000000000000000000000000000000000000000000000000000000000000001";
    const text = "version https://git-lfs.github.com/spec/v1\n" ++
        "ext-1-bar sha256:" ++ other ++ "\n" ++
        "ext-0-foo sha256:" ++ other ++ "\n" ++
        "oid sha256:" ++ oid ++ "\nsize 6\n";
    const p = try Pointer.decode(text);
    try testing.expectEqual(@as(usize, 2), p.exts().len);
    try testing.expectEqualStrings("foo", p.exts()[0].name);
    try testing.expectEqualStrings("bar", p.exts()[1].name);
    var buf: [Pointer.max_encoded_len]u8 = undefined;
    try testing.expectEqualStrings("version https://git-lfs.github.com/spec/v1\n" ++
        "ext-0-foo sha256:" ++ other ++ "\n" ++
        "ext-1-bar sha256:" ++ other ++ "\n" ++
        "oid sha256:" ++ oid ++ "\nsize 6\n", p.encodeBuf(&buf));

    const twice = "version https://git-lfs.github.com/spec/v1\n" ++
        "ext-0-foo sha256:" ++ other ++ "\n" ++
        "ext-0-bar sha256:" ++ other ++ "\n" ++
        "oid sha256:" ++ oid ++ "\nsize 6\n";
    try testing.expectError(error.BadPointer, Pointer.decode(twice));
}

test "only the first 1024 bytes are asked whether they are a pointer" {
    var long: [2048]u8 = @splat('\n');
    const text = pointerText(hello_oid, "6");
    @memcpy(long[0..text.len], text);
    _ = try Pointer.decode(&long);
    long[1500] = 'x';
    _ = try Pointer.decode(&long);
}

test "the store names an object by its SHA-256 and gives it back at the right size" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store: Store = .{ .base = tmp.dir, .root = "lfs" };

    var source: Io.Reader = .fixed("hello\n");
    const p = try store.install(io, &source, null);
    try testing.expectEqualStrings(hello_oid, &p.oid);
    try testing.expectEqual(@as(u64, 6), p.size);
    const stored = try tmp.dir.readFileAlloc(io, "lfs/objects/58/91/" ++ hello_oid, testing.allocator, .limited(64));
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings("hello\n", stored);
    try testing.expect(try store.contains(io, &p));

    // The same object again is kept, and a wrong expectation installs
    // nothing.
    var again: Io.Reader = .fixed("hello\n");
    _ = try store.install(io, &again, &p);
    var wrong: Io.Reader = .fixed("hellO\n");
    try testing.expectError(error.LfsObjectMismatch, store.install(io, &wrong, &p));
    var tmp_listing = try tmp.dir.openDir(io, "lfs/tmp", .{ .iterate = true });
    defer tmp_listing.close(io);
    var it = tmp_listing.iterate();
    try testing.expect(try it.next(io) == null);

    // A pointer whose size disagrees with the stored object is not that
    // object.
    var short = p;
    short.size = 5;
    try testing.expect(!try store.contains(io, &short));
}

test "fetch patterns name a path, a directory above it, or a component anywhere" {
    try testing.expect(patternMatches("images", "images/a.png", false));
    try testing.expect(patternMatches("images", "assets/images/a.png", false));
    try testing.expect(patternMatches("images/", "assets/images/a.png", false));
    try testing.expect(!patternMatches("/images", "assets/images/a.png", false));
    try testing.expect(patternMatches("/images", "images/a.png", false));
    try testing.expect(patternMatches("*.psd", "art/deep/x.psd", false));
    try testing.expect(!patternMatches("*.psd", "art/deep/x.png", false));
    try testing.expect(patternMatches("art/deep", "art/deep/x.png", false));
    try testing.expect(!patternMatches("deep/x.png", "art/deep/x.png", false));
    try testing.expect(patternMatches("art/**/x.png", "art/a/b/x.png", false));
    try testing.expect(patternMatches("art\\deep", "art/deep/x.png", false));
    try testing.expect(patternMatches("IMAGES", "images/a.png", true));

    const settings: Settings = .{ .fetch_include = &.{"images"}, .fetch_exclude = &.{"*.psd"} };
    try testing.expect(settings.fetchAllowed("images/a.png"));
    try testing.expect(!settings.fetchAllowed("images/a.psd"));
    try testing.expect(!settings.fetchAllowed("docs/a.png"));
}

test "settings come from the configuration first and .lfsconfig second" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = ".lfsconfig",
        .data = "[lfs]\n\tfetchinclude = a, b/c ,\n\tfetchexclude = x\n\tstorage = ignored\n\turl = https://lfs.example/\n",
    });
    var config = try config_mod.Config.parseText(gpa, "[lfs]\n\tfetchexclude = y,z\n\tstorage = /elsewhere/lfs\n", .local);
    defer config.deinit();
    var l = try Lfs.load(gpa, io, &config, tmp.dir, tmp.dir, .{});
    defer l.deinit();
    try testing.expectEqual(@as(usize, 2), l.settings.fetch_include.len);
    try testing.expectEqualStrings("b/c", l.settings.fetch_include[1]);
    try testing.expectEqual(@as(usize, 2), l.settings.fetch_exclude.len);
    try testing.expectEqualStrings("y", l.settings.fetch_exclude[0]);
    try testing.expectEqualStrings("/elsewhere/lfs", l.store.root);
    try testing.expectEqualStrings("https://lfs.example/", l.settings.url.?);
}

test "fuzz: any bytes are a pointer or a named error, and a pointer survives its encoding" {
    try testing.fuzz({}, fuzzPointer, .{});
}

fn fuzzPointer(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [1400]u8 = undefined;
    const n = smith.slice(&scratch);
    const p = Pointer.decode(scratch[0..n]) catch |err| switch (err) {
        error.NotAPointer, error.BadPointer => return,
    };
    var buf: [Pointer.max_encoded_len]u8 = undefined;
    const encoded = p.encodeBuf(&buf);
    // A pointer to nothing is the empty file whatever else it said.
    if (p.size == 0) return testing.expectEqualStrings("", encoded);
    // The oldest version string is shorter than the one written, so a
    // pointer at the limit can encode past it.
    if (encoded.len >= pointer_size_cutoff) return;
    const again = try Pointer.decode(encoded);
    try testing.expectEqualStrings(&p.oid, &again.oid);
    try testing.expectEqual(p.size, again.size);
    try testing.expectEqual(p.extension_count, again.extension_count);
}
