//! A file's text as its diff driver's `textconv` program writes it: what
//! `git diff`, `git log -p` and `git blame` show for a file whose `diff`
//! attribute names a driver with `diff.<driver>.textconv` -- a PDF as its
//! words, a binary as its strings.
//!
//! It is git 2.55's `fill_textconv`. The driver is the path's as git's
//! userdiff finds it (`default` for a path with no driver). The bytes are
//! written to a temporary file named as git names it, `<random>_<basename>`,
//! and the command is run through the shell with that file's path after it;
//! what it writes is the text, and a command that fails is
//! `error.TextconvFailed`, where git dies "unable to read files to diff".
//! With `diff.<driver>.cachetextconv` the text of a blob is kept in a cache
//! the caller provides -- `commit.notes`' `refs/notes/textconv/<driver>`,
//! as git keeps it -- and taken from there the next time.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const config_mod = @import("../config/config.zig");
const attributes = @import("../patterns.zig").attributes;
const program = @import("../process.zig").program;
const fs = @import("../fs/fs.zig");
const user_diff = @import("user_diff.zig");

const Oid = hash.Oid;

/// Errors from converting a file.
pub const Error = error{
    /// The command failed: git's "unable to read files to diff".
    TextconvFailed,
    /// `diff.<driver>.cachetextconv` is no boolean, which git dies on.
    InvalidDiffSetting,
} || program.Error || fs.TempFile.Error || attributes.Error || Allocator.Error;

/// Where converted text is kept between runs, keyed by the blob and the
/// command that made it: `commit.notes.TextconvCaches` gives git's.
pub const Cache = struct {
    context: *anyopaque,
    /// The text kept for `blob` under `driver`, while `command` is still
    /// the driver's; `null` when there is none.
    getFn: *const fn (context: *anyopaque, a: Allocator, io: Io, key: Key) Error!?[]const u8,
    /// Keep `text` for `blob`. A cache that cannot be written is passed
    /// over, as git passes over a read-only repository.
    putFn: *const fn (context: *anyopaque, io: Io, key: Key, text: []const u8) Error!void,

    pub const Key = struct { driver: []const u8, command: []const u8, blob: Oid };
};

/// What converts the files of one diff: the configuration the drivers
/// are read from, the attributes that name them, and the permission to
/// run their programs.
pub const Textconv = struct {
    programs: program.Programs,
    config: *const config_mod.Config,
    attrs: ?*attributes.Attrs = null,
    /// The working tree whose `.gitattributes` are read on the way down
    /// to a path; `null` reads only what `attrs` holds.
    work_dir: ?Io.Dir = null,
    cache: ?Cache = null,

    /// The driver whose `textconv` applies to `path`, with its command;
    /// `null` when none does.
    pub fn driverOf(t: *const Textconv, a: Allocator, io: Io, path: []const u8) Self.Error!?Driver {
        var state: ?attributes.State = null;
        if (t.attrs) |attrs| {
            if (t.work_dir) |wt| try attrs.enter(io, wt, path);
            state = (try attrs.lookup(a, path, .file)).get("diff");
        }
        const name = user_diff.Driver.of(t.config, state).name() orelse return null;
        const key = try a.print("diff.{s}.textconv", .{name});
        const command = t.config.get(key) orelse return null;
        const cache_key = try a.print("diff.{s}.cachetextconv", .{name});
        const cached = t.config.getBool(cache_key, false) catch return error.InvalidDiffSetting;
        return .{ .name = name, .command = command, .cached = cached };
    }

    /// `file`'s bytes as its driver's `textconv` writes them, or `null`
    /// when no driver converts it. The result is `a`'s.
    pub fn convert(t: *const Textconv, a: Allocator, io: Io, file: File) Self.Error!?[]const u8 {
        const path = file.path;
        const blob = file.blob;
        const bytes = file.bytes;
        const driver = (try t.driverOf(a, io, path)) orelse return null;
        const key: ?Cache.Key = if (driver.cached and blob != null and t.cache != null)
            .{ .driver = driver.name, .command = driver.command, .blob = blob.? }
        else
            null;
        if (key) |k| if (try t.cache.?.getFn(t.cache.?.context, a, io, k)) |text| return text;
        const text = try t.run(a, io, driver.command, path, bytes);
        if (key) |k| try t.cache.?.putFn(t.cache.?.context, io, k, text);
        return text;
    }

    /// git's `run_textconv`: the command through the shell with the
    /// temporary file's path after it.
    fn run(t: *const Textconv, a: Allocator, io: Io, command: []const u8, path: []const u8, bytes: []const u8) Self.Error![]const u8 {
        const base = std.Io.Dir.path.basenamePosix(path);
        var file = try fs.TempFile.create(a, io, t.programs.environ, .{ .suffix = try a.print("_{s}", .{base}) }, bytes);
        defer file.remove(io);
        var outcome = try program.run(a, io, t.programs, .{ .argv = &.{ command, file.path }, .shell = true }, .{});
        if (!outcome.succeeded()) return error.TextconvFailed;
        return outcome.stdout;
    }
};

/// A file to convert.
pub const File = struct {
    path: []const u8,
    /// The object the bytes are, which a cache keeps them by; `null` for
    /// bytes that are no object's, a working tree file's.
    blob: ?Oid = null,
    bytes: []const u8,
};

/// A driver with a `textconv`.
pub const Driver = struct {
    name: []const u8,
    command: []const u8,
    /// `diff.<driver>.cachetextconv`.
    cached: bool,
};
