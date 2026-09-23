//! HEAD as git's commands move it, and the files a command in progress
//! leaves beside it.
//!
//! When `HEAD` names a branch, a commit moves the branch and not `HEAD`, and
//! git writes the same line to both logs; when it is detached, `HEAD` itself
//! moves. Getting that wrong is quiet -- the commit is made, and `git reflog`
//! simply lacks it -- so every history-editing command here moves `HEAD`
//! through this one file. The pseudo-refs a command in progress writes
//! (`ORIG_HEAD`, `CHERRY_PICK_HEAD`, `REBASE_HEAD`, `AUTO_MERGE`) go through
//! a ref transaction without a log, as git's do; the state files (`MERGE_MSG`,
//! the sequencer's directory) are replaced whole, so a reader never sees half
//! of one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("reflog.zig");
const repo_mod = @import("repo.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from moving `HEAD` or writing a state file.
pub const Error = refs_mod.TransactionError || reflog.AppendError || fs.AtomicWriteError ||
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
    const raw = (try repo.refs.read(gpa, io, "HEAD")) orelse return .{ .branch = null, .oid = null };
    switch (raw) {
        .direct => |oid| return .{ .branch = null, .oid = oid },
        .symbolic => |target| {
            errdefer gpa.free(target);
            const resolved = try repo.refs.resolve(gpa, io, target);
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
pub fn advance(io: Io, repo: *Repository, from: Head, new: Oid, log: Log) Error!void {
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
pub fn detach(io: Io, repo: *Repository, old: ?Oid, new: Oid, log: Log) Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.change("HEAD", .{ .direct = new }, .any, .{ .no_deref = true });
    tx.commit(io, null) catch |err| return err;
    try appendHeadLog(io, repo, old, new, log);
}

/// Make `HEAD` name `branch` again, with a line in its log from `old` to
/// whatever the branch holds.
pub fn attach(io: Io, repo: *Repository, branch: []const u8, old: ?Oid, log: Log) Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update("HEAD", .{ .symbolic = branch }, .any);
    try tx.commit(io, null);
    const resolved = try repo.refs.resolve(repo.gpa, io, branch);
    const new = if (resolved) |r| blk: {
        repo.gpa.free(r.name);
        break :blk r.oid;
    } else Oid.zero(repo.kind);
    try appendHeadLog(io, repo, old, new, log);
}

/// Move a branch that `HEAD` does not name, with a line in its log.
pub fn moveBranch(io: Io, repo: *Repository, branch: []const u8, expected: refs_mod.Expected, new: Oid, log: Log) Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(branch, .{ .direct = new }, expected);
    try tx.commit(io, .{ .who = log.who, .message = log.message, .policy = repo.reflogPolicy() });
}

fn appendHeadLog(io: Io, repo: *Repository, old: ?Oid, new: Oid, log: Log) Error!void {
    const exists = try reflog.exists(io, repo.git_dir, repo.gpa, "HEAD");
    if (!reflog.shouldLog(repo.reflogPolicy(), "HEAD", exists)) return;
    try repo.refs.appendLog(repo.gpa, io, "HEAD", old orelse Oid.zero(repo.kind), new, log.who, log.message);
}

/// Point the pseudo-ref `name` at `oid`, with no log, as git writes
/// `ORIG_HEAD` and `CHERRY_PICK_HEAD`.
pub fn writeRef(io: Io, repo: *Repository, name: []const u8, oid: Oid) Error!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(name, .{ .direct = oid }, .any);
    try tx.commit(io, null);
}

/// What the pseudo-ref `name` points at, or `null`.
pub fn readRef(gpa: Allocator, io: Io, repo: *Repository, name: []const u8) refs_mod.ReadError!?Oid {
    const found = (try repo.refs.read(gpa, io, name)) orelse return null;
    switch (found) {
        .direct => |oid| return oid,
        .symbolic => |target| {
            gpa.free(target);
            return null;
        },
    }
}

/// Remove the pseudo-ref `name`, which need not exist.
pub fn deleteRef(io: Io, repo: *Repository, name: []const u8) Error!void {
    repo.refs.dirFor(name).deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

/// Replace the state file `sub_path` under `dir` with `bytes`, making the
/// directories above it.
pub fn writeState(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8) Error!void {
    if (std.fs.path.dirnamePosix(sub_path)) |parent| {
        dir.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    var dir_buf: [512]u8 = undefined;
    const prefix = if (std.fs.path.dirnamePosix(sub_path)) |parent|
        std.fmt.bufPrint(&dir_buf, "{s}/.relic-", .{parent}) catch ".relic-"
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
pub fn removeState(io: Io, dir: Io.Dir, sub_path: []const u8) Error!void {
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
