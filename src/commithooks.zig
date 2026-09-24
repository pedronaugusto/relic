//! The hooks git's history commands run around the commits they make:
//! `git merge`, `git cherry-pick`, `git revert` and `git rebase`, and the
//! `git commit` each of them hands a resolved stop to.
//!
//! Which hooks run, with which arguments, is not the same in each. A merge
//! that commits runs `pre-merge-commit`, `prepare-commit-msg` on
//! `MERGE_MSG` with `merge`, `commit-msg` and, once the branch has moved,
//! `post-merge`. A pick the sequencer commits itself runs
//! `prepare-commit-msg` on `COMMIT_EDITMSG` with `message`, and only when
//! that hook is there, then `post-commit`. A stop concluded by `git commit`
//! runs that command's four. The callers say which; this file holds what
//! they share: where the files are, as git names them to a hook -- relative
//! to the top of the working tree, `.git/MERGE_MSG`, when the git directory
//! is the `.git` there -- and the one sequence `git commit` runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const object = @import("object.zig");
const hooks = @import("hooks.zig");
const repo_mod = @import("repo.zig");
const fs = @import("fs.zig");

const Repository = repo_mod.Repository;

/// Errors from running the hooks.
pub const Error = hooks.Error || Allocator.Error || Io.Dir.RealPathError ||
    Io.Dir.ReadFileAllocError || fs.AtomicWriteError || error{NameTooLong};

/// A command's hooks: the runner, or `null` to run none, and whether the
/// ones `--no-verify` skips run.
pub const Hooks = struct {
    runner: ?*hooks.Runner,
    verify: bool,
    /// How git names the git directory to a hook: `.git`, or its whole path
    /// in a linked worktree or anywhere else.
    git_dir: []const u8,

    /// The hooks of `repo`, with paths named as git names them.
    pub fn init(arena: Allocator, io: Io, repo: *Repository, runner: ?*hooks.Runner, verify: bool) Error!Hooks {
        var h: Hooks = .{ .runner = runner, .verify = verify, .git_dir = ".git" };
        if (runner == null) return h;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const git_path = try arena.dupe(u8, buf[0..try repo.git_dir.realPath(io, &buf)]);
        if (repo.work_dir) |wt| {
            const top = buf[0..try wt.realPath(io, &buf)];
            const expected = try std.fs.path.join(arena, &.{ top, ".git" });
            if (std.mem.eql(u8, expected, git_path)) return h;
        }
        h.git_dir = git_path;
        return h;
    }

    /// `git_path(name)`: a file of the git directory as a hook is handed it.
    pub fn path(h: *const Hooks, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
        return std.fs.path.join(arena, &.{ h.git_dir, name });
    }

    /// What the commit hooks are told: `GIT_INDEX_FILE`, and the author git
    /// exports while `git commit` runs, when it does.
    pub fn env(h: *const Hooks, arena: Allocator, author: ?object.Signature) Allocator.Error!hooks.Runner.CommitEnv {
        return .{ .index_path = try h.path(arena, "index"), .author = author };
    }

    /// Whether a hook would run for `event`.
    pub fn exists(h: *const Hooks, io: Io, event: []const u8) bool {
        const runner = h.runner orelse return false;
        return runner.exists(io, event);
    }

    /// `git commit`'s hooks up to the commit, for a stop a command hands to
    /// it: `pre-commit` when verifying, `text` into `COMMIT_EDITMSG`,
    /// `prepare-commit-msg` with `source`, then `commit-msg` when
    /// verifying. The message is what the file holds afterwards; without
    /// hooks it is `text` and no file is written.
    pub fn beforeCommit(
        h: *const Hooks,
        arena: Allocator,
        io: Io,
        repo: *Repository,
        text: []const u8,
        source: hooks.Runner.MessageSource,
        author: ?object.Signature,
    ) Error![]const u8 {
        const runner = h.runner orelse return text;
        const e = try h.env(arena, author);
        if (h.verify) _ = try runner.preCommit(io, e);
        try fs.atomicWrite(io, repo.git_dir, "COMMIT_EDITMSG", text, ".relic-msg-", .none);
        const message_path = try h.path(arena, "COMMIT_EDITMSG");
        _ = try runner.prepareCommitMsg(io, e, message_path, source, null);
        if (h.verify) _ = try runner.commitMsg(io, e, message_path);
        return repo.git_dir.readFileAlloc(io, "COMMIT_EDITMSG", arena, .limited(1 << 30));
    }

    /// `post-commit`, once the branch has moved. It cannot undo anything.
    pub fn postCommit(h: *const Hooks, arena: Allocator, io: Io, author: ?object.Signature) Error!void {
        const runner = h.runner orelse return;
        _ = try runner.postCommit(io, try h.env(arena, author));
    }
};
