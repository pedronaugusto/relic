//! git's `prune`: the loose objects nothing reaches go, with what
//! `reachable.c` counts as reached -- every ref, every worktree's `HEAD`,
//! index and rebase state, every reflog entry -- and the recent objects
//! that are spared with what they reach.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const odb_mod = @import("../odb/odb.zig");
const repo_mod = @import("../repo/repo.zig");
const reach = @import("reach.zig");
const gc = @import("gc.zig");
const date = @import("../text.zig").date;
const program = @import("../process/program.zig");
const Repository = repo_mod.Repository;

/// Failures of `prune`.
pub const Error = gc.Error || reach.Error || Repository.WriteShallowError || error{
    /// `extensions.preciousObjects` is set: git refuses to prune.
    PreciousObjects,
};

/// How `prune` runs: git's `prune` options.
pub const PruneOptions = struct {
    /// `--expire`: an unreachable loose object, or a temporary file, whose
    /// time is not after this goes, and unreachable objects newer than it
    /// are spared with what they reach. git's default takes every one;
    /// `gc` passes `gc.pruneExpire` (`pruneExpiry`).
    expire: date.Expiry = date.expire_all,
    /// `<head>...`: objects kept as if a ref named them.
    heads: []const Oid = &.{},
    /// `-n`: report and remove nothing.
    dry_run: bool = false,
    /// What runs `gc.recentObjectsHook`: `reach.ReachOptions.programs`.
    programs: ?program.Programs = null,
};

/// What `prune` removed, or with `dry_run` would have.
pub const Report = struct {
    objects: odb_mod.Odb.PruneReport,
    /// Commits taken out of `.git/shallow`, which nothing reaches now.
    shallow_removed: u32 = 0,
};

/// git's `prune`: every loose object of this repository's own directory
/// that `reachableObjects` does not keep and whose time is not after
/// `expire` goes, then those a pack also holds, then stale temporary files;
/// in a shallow repository the boundary commits nothing reaches leave
/// `.git/shallow`.
pub fn prune(gpa: Allocator, io: Io, repo: *Repository, options: PruneOptions) Self.Error!Report {
    if (try repo.configuration().getBool("extensions.preciousobjects", false)) return error.PreciousObjects;
    var keep = try reach.reachableObjects(gpa, io, repo, .{ .heads = options.heads, .recent = options.expire, .programs = options.programs });
    defer keep.deinit(gpa);
    var report: Report = .{ .objects = try repo.objectDatabase().prune(io, .{ .keep = &keep, .expire = options.expire, .dry_run = options.dry_run }) };
    const db = repo.objectDatabase();
    if (db.shallow.count() != 0) {
        var gone: std.ArrayList(Oid) = .empty;
        defer gone.deinit(gpa);
        var it = db.shallow.keyIterator();
        while (it.next()) |oid| if (!keep.contains(oid.*)) try gone.append(gpa, oid.*);
        report.shallow_removed = @intCast(gone.items.len);
        if (!options.dry_run) {
            for (gone.items) |oid| _ = db.shallow.remove(oid);
            try repo.writeShallow(io);
        }
    }
    return report;
}

/// `gc.pruneExpire` as git's `gc` reads it: `2.weeks.ago` when unset,
/// `null` for `never`, which runs no prune.
pub fn pruneExpiry(repo: *Repository, clock: date.Context) Self.Error!?date.Expiry {
    const value = repo.configuration().get("gc.pruneexpire") orelse "2.weeks.ago";
    const expiry = date.parseExpiry(value, clock) orelse return error.InvalidExpiryDate;
    return if (expiry == 0) null else expiry;
}
