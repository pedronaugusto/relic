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

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const refs_mod = @import("../refs/refs.zig");
const config_mod = @import("../config/config.zig");
const repo_mod = @import("repo.zig");
const fs = @import("../fs/fs.zig");
const state_file = @import("state.zig");
const worktrees = @import("../checkout/worktrees.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from moving `HEAD` or writing a state file.
pub const Error = refs_mod.TransactionError || fs.AtomicWriteError ||
    Io.Dir.CreateDirPathError || Io.Dir.DeleteTreeError || aegis.own.ReadFileError;

/// Where `HEAD` is.
pub const Head = struct {
    pub const Error = ErrorNamespace.Error;

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
    const resolved = try repo.refStore().resolve(repo.allocator(), io, branch);
    const new = if (resolved) |r| blk: {
        repo.allocator().free(r.name);
        break :blk r.oid;
    } else Oid.zero(repo.objectFormat());
    try appendHeadLog(io, repo, old, new, log);
}

/// The expected current value and replacement object.
pub const MoveInputs = struct { expected: refs_mod.Expected, new: Oid };

/// Move a branch that `HEAD` does not name, with a line in its log.
pub fn moveBranch(io: Io, repo: *Repository, branch: []const u8, inputs: MoveInputs, log: Log) Self.Error!void {
    const expected = inputs.expected;
    const new = inputs.new;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(branch, .{ .direct = new }, expected);
    try tx.commit(io, .{ .who = log.who, .message = log.message, .policy = repo.reflogPolicy() });
}

fn appendHeadLog(io: Io, repo: *Repository, old: ?Oid, new: Oid, log: Log) Error!void {
    try repo.refStore().appendLog(repo.allocator(), io, .{ .name = "HEAD", .old = old orelse Oid.zero(repo.objectFormat()), .new = new }, .{
        .who = log.who,
        .message = log.message,
        .policy = repo.reflogPolicy(),
    });
}

/// The branches some worktree holds, each with where that worktree is, as
/// git's `prepare_checked_out_branches` finds them for `branch_checked_out`:
/// each worktree's `HEAD`, the branch a rebase there is rebasing, the
/// branch a bisection there started from, and the refs a rebase there
/// will move. The main worktree is one, unless the repository is bare. The
/// map and its strings are `arena`'s.
pub fn checkedOutBranches(arena: Allocator, io: Io, repo: *Repository) CheckedOutError!std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const bare = try repo.configuration().getBool("core.bare", false);
    if (!bare) main: {
        var buf: [4096]u8 = undefined;
        const common = fs.realPath(io, repo.commonDirectory().get(), &buf) catch break :main;
        const main_path = if (std.mem.endsWith(u8, common, "/.git")) common[0 .. common.len - "/.git".len] else common;
        try addWorktreeBranches(arena, io, repo, &map, repo.commonDirectory().get(), "main-worktree/HEAD", try arena.dupe(u8, main_path));
    }
    const listing = try worktrees.list(arena, io, repo.refStore());
    for (listing.entries) |entry| {
        const sub = try arena.print("worktrees/{s}", .{entry.name});
        var admin = repo.commonDirectory().get().openDir(io, sub, .{}) catch continue;
        defer admin.close(io);
        try addWorktreeBranches(arena, io, repo, &map, admin, try arena.print("{s}/HEAD", .{sub}), try arena.dupe(u8, entry.path));
    }
    return map;
}

/// Errors from `checkedOutBranches`.
pub const CheckedOutError = refs_mod.ReadError || worktrees.Error || aegis.own.ReadFileError || config_mod.ValueError;

/// Where the worktree is whose bisection started from `ref`, a branch's
/// full name, or `null` when none did: git's `branch_bisecting`, which
/// `git branch -d` reports apart from a branch held otherwise. The path is
/// `arena`'s.
pub fn bisectingBranch(arena: Allocator, io: Io, repo: *Repository, ref: []const u8) CheckedOutError!?[]const u8 {
    const bare = try repo.configuration().getBool("core.bare", false);
    if (!bare) main: {
        const from = (try bisectedFrom(arena, io, repo, repo.commonDirectory().get())) orelse break :main;
        if (!std.mem.eql(u8, from, ref)) break :main;
        var buf: [4096]u8 = undefined;
        const common = fs.realPath(io, repo.commonDirectory().get(), &buf) catch break :main;
        return try arena.dupe(u8, if (std.mem.endsWith(u8, common, "/.git")) common[0 .. common.len - "/.git".len] else common);
    }
    const listing = try worktrees.list(arena, io, repo.refStore());
    for (listing.entries) |entry| {
        var admin = repo.commonDirectory().get().openDir(io, try arena.print("worktrees/{s}", .{entry.name}), .{}) catch continue;
        defer admin.close(io);
        const from = (try bisectedFrom(arena, io, repo, admin)) orelse continue;
        if (std.mem.eql(u8, from, ref)) return try arena.dupe(u8, entry.path);
    }
    return null;
}

/// What an operation in progress in a worktree is on, as git's
/// `is_worktree_being_rebased` and `is_worktree_being_bisected` read it
/// for `git branch -m`: full branch names, `arena`'s.
pub const Busy = struct {
    /// The branch a rebase there is rebasing: `rebase-merge`'s, or
    /// `rebase-apply`'s when that is no `am`.
    rebasing: ?[]const u8 = null,
    /// The branch a bisection there started from.
    bisecting: ?[]const u8 = null,
};

/// `Busy` for the worktree whose administrative directory is `dir`: the
/// common directory for the main worktree, `worktrees/<id>` for another.
pub fn busyIn(arena: Allocator, io: Io, repo: *Repository, dir: Io.Dir) CheckedOutError!Busy {
    var busy: Busy = .{ .bisecting = try bisectedFrom(arena, io, repo, dir) };
    // `wt_status_check_rebase`: `rebase-apply` with `applying` in it is an
    // `am`; `rebase-merge` is always a rebase.
    const not_am = (try state_file.read(arena, io, dir, "rebase-apply/applying")) == null;
    for ([_][]const u8{ "rebase-apply/head-name", "rebase-merge/head-name" }, [_]bool{ not_am, true }) |sub, counts| {
        const text = (try state_file.read(arena, io, dir, sub)) orelse continue;
        if (!counts) break;
        const name = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
        if (std.mem.startsWith(u8, name, "refs/heads/")) busy.rebasing = name;
        break;
    }
    return busy;
}

/// The branch a bisection in `dir` started from, its full name, or `null`
/// when none is running (no `BISECT_LOG`) or it started from a detached `HEAD`, whose
/// `BISECT_START` names a commit.
fn bisectedFrom(arena: Allocator, io: Io, repo: *Repository, dir: Io.Dir) CheckedOutError!?[]const u8 {
    // `wt_status_check_bisect`: a bisection is running while its log is there.
    _ = dir.statFile(io, "BISECT_LOG", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
    const text = (try state_file.read(arena, io, dir, "BISECT_START")) orelse return null;
    const name = std.mem.trim(u8, text, " \t\r\n");
    if (name.len == 0) return null;
    if (Oid.parse(repo.objectFormat(), name)) |_| return null else |_| {}
    return try arena.print("refs/heads/{s}", .{name});
}

/// The branches the worktree whose `HEAD` is `head` holds: that `HEAD`,
/// read through the ref store, which a reftable repository keeps in its
/// tables, and what the operation in progress in `dir` is on.
fn addWorktreeBranches(arena: Allocator, io: Io, repo: *Repository, map: *std.StringHashMapUnmanaged([]const u8), dir: Io.Dir, head: []const u8, where: []const u8) CheckedOutError!void {
    const head_value = repo.refStore().read(arena, io, head) catch |err| switch (err) {
        // git's `get_worktrees` reads a `HEAD` it cannot take as nothing.
        error.MalformedRef => null,
        else => |e| return e,
    };
    if (head_value) |value| switch (value) {
        .symbolic => |target| try map.put(arena, target, where),
        .direct => {},
    };
    for ([_][]const u8{ "rebase-apply/head-name", "rebase-merge/head-name" }) |sub| {
        const text = (try state_file.read(arena, io, dir, sub)) orelse continue;
        // `get_branch`: one newline off the end.
        const name = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
        if (std.mem.startsWith(u8, name, "refs/heads/")) try map.put(arena, name, where);
        break;
    }
    if (try bisectedFrom(arena, io, repo, dir)) |ref| try map.put(arena, ref, where);
    // `sequencer_get_update_refs_state`: a ref, its value before, its
    // value after, to each record; a record that does not read ends it.
    if (try state_file.read(arena, io, dir, "rebase-merge/update-refs")) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |ref| {
            if (ref.len == 0) break;
            const before = lines.next() orelse break;
            const after = lines.next() orelse break;
            _ = Oid.parse(repo.objectFormat(), before) catch break;
            _ = Oid.parse(repo.objectFormat(), after) catch break;
            try map.put(arena, ref, where);
        }
    }
}
