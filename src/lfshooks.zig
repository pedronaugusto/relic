//! The work of the hooks `git lfs install` writes, done in process, so a
//! repository set up by git-lfs works on a machine that has no git-lfs.
//!
//! git-lfs installs four hooks, each `git lfs <event> "$@"` behind a check
//! that stops with "git-lfs was not found" when the program is missing.
//! `hooks.Runner` recognises them by their exact text, from every release
//! that wrote them, and with `Native` as its `Options.lfs` calls this in
//! their place:
//!
//! - `post-checkout` makes the lockable files a checkout changed read-only
//!   unless the person holds their locks — every lockable file when a path
//!   was checked out rather than a branch — as `git lfs post-checkout` does;
//! - `post-commit` does the same for the files the new commit changed;
//! - `post-merge` for every lockable file;
//! - `pre-push` does nothing here, because `push` itself uploads the
//!   objects and checks the locks, as `lfspush` describes. A caller that
//!   turns that off with `push.Options.lfs.mode = .off` should not hand
//!   `Native` to the runner it runs `pre-push` with.
//!
//! Whose a lock is comes from the cache `lfslocks` keeps, so none of these
//! asks the server, as none of git-lfs's does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const diff = @import("diff.zig");
const hooks = @import("hooks.zig");
const lfslocks = @import("lfslocks.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// relic's own work for git-lfs's hooks, in one repository.
pub const Native = struct {
    gpa: Allocator,
    repo: *Repository,
    /// What the last call did, for a caller that shows it; `null` when it
    /// did nothing or failed.
    fixed: ?lfslocks.Fixed = null,
    /// The name of the error the last call ended in, when it failed.
    failure: ?[]const u8 = null,

    /// What `hooks.Options.lfs` is set to.
    pub fn lfsHooks(n: *Native) hooks.LfsHooks {
        return .{ .context = n, .run = run };
    }

    fn run(context: ?*anyopaque, io: Io, event: []const u8, args: []const []const u8, input: []const u8) bool {
        _ = input;
        const n: *Native = @ptrCast(@alignCast(context.?));
        n.fixed = null;
        n.failure = null;
        n.handle(io, event, args) catch |err| {
            n.failure = @errorName(err);
            // git-lfs's post-checkout and post-merge warn and go on; its
            // post-commit fails.
            return !std.mem.eql(u8, event, "post-commit");
        };
        return true;
    }

    fn handle(n: *Native, io: Io, event: []const u8, args: []const []const u8) !void {
        if (std.mem.eql(u8, event, "pre-push")) return;
        var arena_state: std.heap.ArenaAllocator = .init(n.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var paths: ?[]const []const u8 = null;
        if (std.mem.eql(u8, event, "post-checkout")) {
            // `<old> <new> 1` for a branch checked out from somewhere;
            // anything else checks every lockable file.
            if (args.len == 3 and std.mem.eql(u8, args[2], "1")) {
                const old = Oid.parse(n.repo.kind, args[0]) catch null;
                const new = Oid.parse(n.repo.kind, args[1]) catch null;
                if (old != null and new != null and !old.?.isZero()) {
                    paths = try n.changed(arena, io, old.?, new.?);
                }
            }
        } else if (std.mem.eql(u8, event, "post-commit")) {
            const head = (try n.repo.head(io)) orelse return;
            defer n.gpa.free(head.name);
            const found = try n.repo.odb.read(io, head.oid);
            defer n.repo.odb.gpa.free(found.bytes);
            var commit = try object.Commit.parse(arena, n.repo.kind, found.bytes);
            defer commit.deinit();
            // git's diff-tree of a root commit lists nothing.
            if (commit.parents.len == 0) return;
            paths = try n.changed(arena, io, commit.parents[0], head.oid);
        } else if (!std.mem.eql(u8, event, "post-merge")) return;
        n.fixed = try lfslocks.fixWriteFlags(n.gpa, io, n.repo, paths, .{});
    }

    /// The paths that differ between two commits' trees.
    fn changed(n: *Native, arena: Allocator, io: Io, old: Oid, new: Oid) ![]const []const u8 {
        const old_tree = try treeOf(arena, io, n.repo, old);
        const new_tree = try treeOf(arena, io, n.repo, new);
        var changes = try diff.tree(n.gpa, io, &n.repo.odb, old_tree, new_tree, .{});
        defer changes.deinit();
        const out = try arena.alloc([]const u8, changes.items.len);
        for (changes.items, out) |c, *p| p.* = try arena.dupe(u8, c.path());
        return out;
    }
};

fn treeOf(arena: Allocator, io: Io, repo: *Repository, commit_oid: Oid) !Oid {
    const peeled = try repo.peel(io, commit_oid);
    const found = try repo.odb.read(io, peeled);
    defer repo.odb.gpa.free(found.bytes);
    if (found.type == .tree) return peeled;
    var commit = try object.Commit.parse(arena, repo.kind, found.bytes);
    defer commit.deinit();
    return commit.tree;
}
