//! `git merge-base --fork-point`: where a branch forked from a ref, found
//! through every value the ref's reflog says it held, so that a ref
//! rewritten since -- an upstream rebased under the branch -- still names
//! the commit the branch was made from.
//!
//! It is git's `get_fork_point`: the commits the log names, oldest first
//! (the first entry's old value, then each entry's new one, every commit
//! once; the ref's own value when there is no log), and their merge base
//! with the commit asked about. One base, and one of those commits, is the
//! fork point; anything else is none.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const rev_walk = @import("../walk/walk.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from finding a fork point.
pub const Error = rev_walk.Error || Repository.ReadLogError;

/// The ref, by its full name, and the commit that forked from it.
pub const Inputs = struct { ref: []const u8, commit: Oid };

/// Where `inputs.commit` forked from `inputs.ref`, or `null` when the ref
/// does not exist or its log names no one commit the history shares.
pub fn forkPoint(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs) Self.Error!?Oid {
    const resolved = (try repo.refStore().resolve(gpa, io, inputs.ref)) orelse return null;
    gpa.free(resolved.name);
    var log = try repo.readLog(io, inputs.ref);
    defer log.deinit();
    var seen: std.ArrayList(Oid) = .empty;
    defer seen.deinit(gpa);
    for (log.entries, 0..) |entry, i| {
        if (i == 0) try addCommit(gpa, io, repo, &seen, entry.old);
        try addCommit(gpa, io, repo, &seen, entry.new);
    }
    if (seen.items.len == 0) try addCommit(gpa, io, repo, &seen, resolved.oid);
    if (seen.items.len == 0) return null;
    const bases = try rev_walk.mergeBasesMany(gpa, io, repo.objectDatabase(), .{ .one = inputs.commit, .others = seen.items }, .{});
    defer gpa.free(bases);
    if (bases.len != 1) return null;
    for (seen.items) |oid| {
        if (oid.eql(bases[0])) return oid;
    }
    return null;
}

/// git's `add_one_commit`: a commit not yet listed, the null name and
/// whatever is not a commit left out.
fn addCommit(gpa: Allocator, io: Io, repo: *Repository, seen: *std.ArrayList(Oid), oid: Oid) Self.Error!void {
    if (oid.isZero()) return;
    for (seen.items) |known| {
        if (known.eql(oid)) return;
    }
    const header = repo.objectDatabase().readHeader(io, oid) catch return;
    if (header.type != .commit) return;
    try seen.append(gpa, oid);
}
