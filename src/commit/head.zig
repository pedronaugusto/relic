//! HEAD as git's commands move it, and the files a command in progress
//! leaves beside it.
//!
//! When `HEAD` names a branch, a commit moves the branch and not `HEAD`, and
//! git writes the same line to both logs; when it is detached, `HEAD` itself
//! moves. Getting that wrong is quiet -- the commit is made, and `git reflog`
//! simply lacks it -- so every history-editing command here moves `HEAD`
//! through this one file. The root refs a command in progress writes
//! (`ORIG_HEAD`, `CHERRY_PICK_HEAD`, `REBASE_HEAD`, `AUTO_MERGE`) are the ref
//! store's (`refs.Store.root`); the state files (`MERGE_MSG`, the
//! sequencer's directory) are replaced whole, so a reader never sees half of
//! one.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const refs_mod = @import("../refs.zig");
const repo_mod = @import("../repo.zig");
const fs = @import("../repo/fs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from moving `HEAD` or writing a state file.
pub const Error = refs_mod.TransactionError || fs.AtomicWriteError ||
    Io.Dir.CreateDirPathError || Io.Dir.DeleteTreeError || Io.Dir.ReadFileAllocError;

/// Where `HEAD` is.
pub const Head = struct {
    /// The ref `HEAD` names, such as `refs/heads/main`, or `null` when it is
    /// detached. Owned by the caller of `read`.
    branch: ?[]const u8,
    /// What `HEAD` resolves to, or `null` on an unborn branch.
    oid: ?Oid,

    /// Release the branch name.
    pub fn deinit(h: *Head, gpa: Allocator) void {
        if (h.branch) |b| gpa.free(b);
        h.* = undefined;
    }

    /// The branch's name without `refs/heads/`, or the whole ref when it is
    /// somewhere else. `null` when detached.
    pub fn shortName(h: *const Head) ?[]const u8 {
        const branch = h.branch orelse return null;
        if (std.mem.startsWith(u8, branch, "refs/heads/")) return branch["refs/heads/".len..];
        return branch;
    }
};

/// Read where `HEAD` is.
pub fn read(gpa: Allocator, io: Io, repo: *Repository) refs_mod.ReadError!Head {
    const raw = (try repo.refStore().read(gpa, io, "HEAD")) orelse return .{ .branch = null, .oid = null };
    switch (raw) {
        .direct => |oid| return .{ .branch = null, .oid = oid },
        .symbolic => |target| {
            errdefer gpa.free(target);
            const resolved = try repo.refStore().resolve(gpa, io, target);
            if (resolved) |r| gpa.free(r.name);
            return .{ .branch = target, .oid = if (resolved) |r| r.oid else null };
        },
    }
}

/// What a moved ref's log line says.
pub const Log = struct {
    who: object.Signature,
    message: []const u8,
};

/// Move `HEAD` from where `from` says it is to `new`: the branch it names,
/// or `HEAD` itself when it is detached, with the same line in both logs.
/// A move to where it already is writes `HEAD`'s log alone, and only when
/// `HEAD` names a branch, as git does.
/// The ref must still hold `from.oid`, which is what stops a move racing a
/// second writer from losing that writer's commit.
pub fn advance(io: Io, repo: *Repository, from: Head, new: Oid, log: Log) Self.Error!void {
    // A move to where it already is changes no ref. git still writes the
    // line to `HEAD`'s log when `HEAD` names a branch, because its update of
    // `HEAD` through the branch is logged on its own; a detached `HEAD` that
    // stays put logs nothing.
    if (from.oid) |old| {
        if (old.eql(new)) {
            if (from.branch != null) try appendHeadLog(io, repo, old, new, log);
            return;
        }
    }
    const policy = repo.reflogPolicy();
    const expected: refs_mod.Expected = if (from.oid) |oid| .{ .matches = oid } else .must_not_exist;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    // The branch `HEAD` names is moved through `HEAD`, and the transaction
    // writes the line to both logs.
    try tx.update("HEAD", .{ .direct = new }, expected);
    try tx.commit(io, .{ .who = log.who, .message = log.message, .policy = policy });
}

/// Point `HEAD` straight at `new`, detaching it, with a line in its log.
pub fn detach(io: Io, repo: *Repository, old: ?Oid, new: Oid, log: Log) Self.Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.change("HEAD", .{ .direct = new }, .any, .{ .no_deref = true });
    try tx.commit(io, null);
    try appendHeadLog(io, repo, old, new, log);
}

/// Make `HEAD` name `branch` again, with a line in its log from `old` to
/// whatever the branch holds.
pub fn attach(io: Io, repo: *Repository, branch: []const u8, old: ?Oid, log: Log) Self.Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update("HEAD", .{ .symbolic = branch }, .any);
    try tx.commit(io, null);
    const resolved = try repo.refStore().resolve(repo.gpa, io, branch);
    const new = if (resolved) |r| blk: {
        repo.gpa.free(r.name);
        break :blk r.oid;
    } else Oid.zero(repo.objectFormat());
    try appendHeadLog(io, repo, old, new, log);
}

/// Move a branch that `HEAD` does not name, with a line in its log.
pub fn moveBranch(io: Io, repo: *Repository, branch: []const u8, expected: refs_mod.Expected, new: Oid, log: Log) Self.Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(branch, .{ .direct = new }, expected);
    try tx.commit(io, .{ .who = log.who, .message = log.message, .policy = repo.reflogPolicy() });
}

fn appendHeadLog(io: Io, repo: *Repository, old: ?Oid, new: Oid, log: Log) Error!void {
    try repo.refStore().appendLog(repo.gpa, io, "HEAD", old orelse Oid.zero(repo.objectFormat()), new, .{
        .who = log.who,
        .message = log.message,
        .policy = repo.reflogPolicy(),
    });
}

/// Replace the state file `sub_path` under `dir` with `bytes`, making the
/// directories above it.
pub fn writeState(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8) Self.Error!void {
    if (std.Io.Dir.path.dirnamePosix(sub_path)) |parent| {
        dir.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    var dir_buf: [512]u8 = undefined;
    const prefix = if (std.Io.Dir.path.dirnamePosix(sub_path)) |parent|
        std.mem.print(&dir_buf, "{s}/.relic-", .{parent}) catch ".relic-"
    else
        ".relic-";
    try fs.atomicWrite(io, dir, sub_path, bytes, prefix, .none);
}

/// The state file `sub_path` under `dir`, or `null`. The bytes are the
/// caller's.
pub fn readState(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) Io.Dir.ReadFileAllocError!?[]u8 {
    return fs.readFileAlloc(gpa, io, dir, sub_path, 64 << 20);
}

/// Remove the state file `sub_path` under `dir`, which need not exist.
pub fn removeState(io: Io, dir: Io.Dir, sub_path: []const u8) Self.Error!void {
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |e| return e,
    };
}

/// Whether the state file or directory `sub_path` under `dir` is there.
pub fn stateExists(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}
