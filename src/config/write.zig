//! Writing one configuration file, as git's
//! `repo_config_set_multivar_in_file_gently` writes it: take `<file>.lock`,
//! read the file again under it, apply only the edits asked for to its
//! lossless form, keep its mode, and put the result in its place. What
//! another process wrote since this one read the file stays.
//!
//! Reached only from `config` and `repo`: `Repository.writeConfig` is the
//! one public way to write a repository's configuration, and it checks the
//! file a write would leave before the write lands.

const ErrorNamespace = @This();
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config = @import("config.zig");
const fs = @import("../fs/fs.zig");

/// One change to a configuration file.
pub const Edit = union(enum) {
    /// `git config <name> <value>`: the last setting of `name` rewritten in
    /// place, or a new one at the end of its section.
    set: struct { name: []const u8, value: []const u8 },
    /// `git config --add <name> <value>`: a new setting beside the others.
    add: struct { name: []const u8, value: []const u8 },
    /// `git config --unset-all <name>`; with `value`, git's
    /// `--fixed-value`, only the settings that hold it.
    unset: struct { name: []const u8, value: ?[]const u8 = null },
    /// `git config --remove-section`, the header matched as spelled.
    remove_section: struct { section: []const u8, subsection: ?[]const u8 = null },
    /// git's `repo_config_rename_section`, as `git branch -m` renames a
    /// branch's: every header of `old`, a full name, written as `new`'s.
    rename_section: struct { old: []const u8, new: []const u8 },
    /// git's `repo_config_copy_section`, as `git branch -c` copies a
    /// branch's: each section `old` followed by a copy of it as `new`.
    copy_section: struct { old: []const u8, new: []const u8 },
};

/// Errors from writing a configuration file.
pub const Error = errors: {
    break :errors config.Config.SectionError || fs.LockError || fs.CommitError ||
        aegis.own.ReadFileError;
};

/// What a write did beside setting values.
pub const Outcome = struct {
    /// How many sections the `remove_section` edits found and removed.
    sections_removed: usize = 0,
};

/// A write prepared and not yet in place: the file's lock held, and what
/// the file will hold.
pub const Pending = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    dir: Io.Dir,
    sub_path: []const u8,
    lock: fs.LockFile,
    /// The lock's write buffer, which must not move while the lock lives.
    buffer: []u8,
    /// The file as it will be. Owned.
    bytes: []u8,
    outcome: Outcome,

    /// What the file will hold once `commit` puts it in place.
    pub fn contents(p: *const Pending) []const u8 {
        return p.bytes;
    }

    /// Errors from `commit`.
    pub const CommitError = fs.CommitError || error{WriteFailed};

    /// Put the new file in place, with the mode the old one had, as git
    /// gives it.
    pub fn commit(p: *Pending, io: Io) CommitError!void {
        if (std.Io.File.Permissions.has_executable_bit) {
            if (p.dir.statFile(io, p.sub_path, .{})) |st| {
                p.dir.setFilePermissions(io, p.lock.lock_name, st.permissions, .{}) catch |err| {
                    std.log.warn("cannot preserve configuration permissions: {s}", .{@errorName(err)});
                };
            } else |_| {}
        }
        p.lock.writer().writeAll(p.bytes) catch return error.WriteFailed;
        try p.lock.commit(io);
    }

    /// Release the write, giving the lock up and leaving the file as it was
    /// when it was not committed.
    pub fn deinit(p: *Pending, io: Io) void {
        p.lock.deinit(io);
        p.gpa.free(p.buffer);
        p.gpa.free(p.bytes);
        p.* = undefined;
    }
};

/// Steps one to four of a write: check every key, take `<sub_path>.lock`
/// in `dir` (made with the permissions `shared` asks for), read the file
/// again under it -- a file that is not there is an empty one -- and apply
/// `edits` to it. Nothing is written until `Pending.commit`.
pub fn prepare(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    level: config.Level,
    lock_options: LockOptions,
    edits: []const Edit,
) Error!Pending {
    for (edits) |edit| switch (edit) {
        .set => |e| _ = try config.checkKey(e.name),
        .unset => |e| _ = try config.checkKey(e.name),
        .add => |e| _ = try config.checkKey(e.name),
        .remove_section, .rename_section, .copy_section => {},
    };
    const buffer = try gpa.alloc(u8, 16 * 1024);
    errdefer gpa.free(buffer);
    var lock = try fs.LockFile.open(gpa, io, dir, .{ .sub_path = sub_path, .buffer = buffer }, .{ .shared = lock_options.shared, .sync = .none, .write_pid = lock_options.pid_file, .on_contention = lock_options.on_contention });
    errdefer lock.deinit(io);

    const text = (try fs.readFileAlloc(gpa, io, dir, sub_path, config.max_file_bytes)) orelse try gpa.alloc(u8, 0);
    defer gpa.free(text);
    var file = try config.Config.parseText(gpa, text, level);
    defer file.deinit();
    // The one file read is the one written.
    file.files.items[0].writable = true;
    var outcome: Outcome = .{};
    for (edits) |edit| switch (edit) {
        .set => |e| try file.setIn(level, e.name, e.value),
        .unset => |e| if (e.value) |v| try file.unsetValueIn(level, e.name, v) else try file.unsetIn(level, e.name),
        .add => |e| try file.addIn(level, e.name, e.value),
        .remove_section => |e| if (try file.removeSectionIn(level, e.section, e.subsection)) {
            outcome.sections_removed += 1;
        },
        .rename_section => |e| _ = try file.renameSectionIn(level, e.old, e.new),
        .copy_section => |e| _ = try file.copySectionIn(level, e.old, e.new),
    };
    const bytes = try file.renderWritable();
    return .{ .gpa = gpa, .dir = dir, .sub_path = sub_path, .lock = lock, .buffer = buffer, .bytes = bytes, .outcome = outcome };
}

/// How a configuration file's lock is taken: with the permissions
/// `core.sharedRepository` asks for, and naming its holder in a
/// `~pid.lock` beside it under `core.lockfilePid`, waiting for a holder as
/// `core.configLockTimeout` says: git's default, a second, wherever no
/// repository says otherwise.
pub const LockOptions = struct {
    shared: fs.Shared = .umask,
    pid_file: bool = false,
    on_contention: fs.OnContention = .{ .wait = .fromMilliseconds(1000) },
};

/// A whole write of one file: `prepare`, then put it in place.
pub fn editFile(
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    level: config.Level,
    lock_options: LockOptions,
    edits: []const Edit,
) Error!Outcome {
    var pending = try prepare(gpa, io, dir, sub_path, level, lock_options, edits);
    defer pending.deinit(io);
    pending.commit(io) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => |e| return e,
    };
    return pending.outcome;
}

test "an edit lands in the file as it is under the lock, every other line kept" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "# kept\n[core]\n\tbare = false\n[gone \"x\"]\n\ta = 1\n" });
    const outcome = try editFile(gpa, io, tmp.dir, "config", .local, .{}, &.{
        .{ .set = .{ .name = "core.bare", .value = "true" } },
        .{ .set = .{ .name = "remote.origin.url", .value = "/a b" } },
        .{ .remove_section = .{ .section = "gone", .subsection = "x" } },
        .{ .unset = .{ .name = "missing.value" } },
        .{ .remove_section = .{ .section = "gone", .subsection = "y" } },
    });
    try std.testing.expectEqual(@as(usize, 1), outcome.sections_removed);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "# kept\n[core]\n\tbare = true\n[remote \"origin\"]\n\turl = /a b\n",
        try tmp.dir.readFile(io, "config", &buf),
    );
    // A file that is not there starts empty.
    _ = try editFile(gpa, io, tmp.dir, "config.worktree", .worktree, .{}, &.{.{ .set = .{ .name = "core.sparseCheckout", .value = "true" } }});
    try std.testing.expectEqualStrings("[core]\n\tsparseCheckout = true\n", try tmp.dir.readFile(io, "config.worktree", &buf));
    // A key git refuses is refused before the lock is taken.
    try std.testing.expectError(error.InvalidKey, editFile(gpa, io, tmp.dir, "config", .local, .{}, &.{.{ .set = .{ .name = "nodot", .value = "x" } }}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "config.lock", .{}));
}
