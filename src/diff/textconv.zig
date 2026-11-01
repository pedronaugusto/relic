//! A file's text as its diff driver's `textconv` program writes it: what
//! `git diff`, `git log -p` and `git blame` show for a file whose driver
//! has `diff.<driver>.textconv` -- a PDF as its words, a binary as its
//! strings.
//!
//! It is git 2.55's `fill_textconv`, given the driver's conversion
//! (`driver.Driver.conversion`, the driver as `driver.Drivers` finds it).
//! The bytes are written to a temporary file named as git names it,
//! `<random>_<basename>`, and the command is run through the shell with
//! that file's path after it; what it writes is the text, and a command
//! that fails is `error.TextconvFailed`, where git dies "unable to read
//! files to diff". With `diff.<driver>.cachetextconv` the text of a blob
//! is kept in a cache the caller provides -- `commit.notes`'
//! `refs/notes/textconv/<driver>`, as git keeps it -- and taken from there
//! the next time.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const program = @import("../process.zig").program;
const fs = @import("../fs/fs.zig");
const driver_mod = @import("driver.zig");

const Oid = hash.Oid;

/// Errors from converting a file.
pub const Error = error{
    /// The command failed: git's "unable to read files to diff".
    TextconvFailed,
} || program.Error || fs.TempFile.Error || Allocator.Error;

/// Where converted text is kept between runs, keyed by the blob and the
/// command that made it: `commit.notes.TextconvCaches` gives git's. An
/// interface its implementation holds, as `std.Io.Writer` is one.
pub const Cache = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (cache: *Cache, a: Allocator, io: Io, key: Key) Error!?[]const u8,
        put: *const fn (cache: *Cache, io: Io, key: Key, text: []const u8) Error!void,
    };

    pub const Key = struct { driver: []const u8, command: []const u8, blob: Oid };

    /// The text kept for `blob` under `driver`, while `command` is still
    /// the driver's; `null` when there is none.
    pub fn get(cache: *Cache, a: Allocator, io: Io, key: Key) Error!?[]const u8 {
        return cache.vtable.get(cache, a, io, key);
    }

    /// Keep `text` for `blob`. A cache that cannot be written is passed
    /// over, as git passes over a read-only repository.
    pub fn put(cache: *Cache, io: Io, key: Key, text: []const u8) Error!void {
        return cache.vtable.put(cache, io, key, text);
    }
};

/// What converts the files of one diff: the permission to run the
/// drivers' programs, and where their texts are kept.
pub const Textconv = struct {
    programs: program.Programs,
    cache: ?*Cache = null,

    /// `file`'s bytes as its driver's `textconv` writes them. The result
    /// is `a`'s.
    pub fn convert(t: *const Textconv, a: Allocator, io: Io, file: File) Self.Error![]const u8 {
        const conversion = file.conversion;
        const key: ?Cache.Key = if (conversion.cached and file.blob != null and t.cache != null)
            .{ .driver = conversion.driver, .command = conversion.command, .blob = file.blob.? }
        else
            null;
        if (key) |k| if (try t.cache.?.get(a, io, k)) |text| return text;
        const text = try t.run(a, io, conversion.command, file);
        if (key) |k| try t.cache.?.put(io, k, text);
        return text;
    }

    /// git's `run_textconv`: the command through the shell with the
    /// temporary file's path after it.
    fn run(t: *const Textconv, a: Allocator, io: Io, command: []const u8, file: File) Self.Error![]const u8 {
        const base = std.Io.Dir.path.basenamePosix(file.path);
        var temp = try fs.TempFile.create(a, io, t.programs.environ, .{ .suffix = try a.print("_{s}", .{base}) }, file.bytes);
        defer temp.remove(io);
        var outcome = try program.run(a, io, t.programs, .{ .argv = &.{ command, temp.path }, .shell = true }, .{});
        if (!outcome.succeeded()) return error.TextconvFailed;
        return outcome.stdout;
    }
};

/// A file to convert.
pub const File = struct {
    /// The driver's `textconv`.
    conversion: driver_mod.Conversion,
    path: []const u8,
    /// The object the bytes are, which a cache keeps them by; `null` for
    /// bytes that are no object's, a working tree file's.
    blob: ?Oid = null,
    bytes: []const u8,
};
