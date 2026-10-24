//! Which operations a worktree is in the middle of, as `git status` says:
//! git's `wt_status_get_state` over the state files and refs they keep.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const repo_mod = @import("repo.zig");
const state = @import("state.zig");

const Repository = repo_mod.Repository;

/// All errors reported by this namespace: none, as in git, where a state
/// file that cannot be read says nothing is in progress.
pub const Error = error{};

/// Which operations a worktree is in the middle of, as `git status` says:
/// git's `wt_status_get_state`. More than one can be: a cherry-pick stopped
/// inside a rebase, a bisect under either.
pub const InProgress = struct {
    /// `MERGE_HEAD`: a merge waits to be committed.
    merge: bool = false,
    /// `rebase-apply/applying`: `git am` stopped.
    am: bool = false,
    /// `rebase-apply/` without `applying`: a rebase by patches stopped.
    rebase: bool = false,
    /// `rebase-merge/`: a merge-based rebase stopped; `interactive` says
    /// whether it was started with `-i`.
    rebase_merge: bool = false,
    interactive: bool = false,
    /// `CHERRY_PICK_HEAD`, or a sequence whose last command was a pick.
    cherry_pick: bool = false,
    /// `REVERT_HEAD`, or a sequence whose last command was a revert.
    revert: bool = false,
    /// `BISECT_START`: a bisect is under way.
    bisect: bool = false,

    /// Whether nothing is in progress.
    pub fn none(p: InProgress) bool {
        return !(p.merge or p.am or p.rebase or p.rebase_merge or p.cherry_pick or p.revert or p.bisect);
    }
};

/// What `repo`'s worktree is in the middle of, in git's order of looking,
/// so a merge hides a rebase as it does there.
pub fn read(io: Io, repo: *Repository) Io.Cancelable!InProgress {
    const dir = repo.gitDirectory();
    var p: InProgress = .{};
    if ((try repo.refStore().special().exists(io, .merge_head))) {
        p.merge = true;
    } else if (try state.exists(io, dir, "rebase-apply")) {
        if (try state.exists(io, dir, "rebase-apply/applying")) p.am = true else p.rebase = true;
    } else if (try state.exists(io, dir, "rebase-merge")) {
        p.rebase_merge = true;
        p.interactive = try state.exists(io, dir, "rebase-merge/interactive");
    }
    const root = repo.refStore().root();
    if ((try root.exists(repo.allocator(), io, .cherry_pick_head))) p.cherry_pick = true;
    if (try state.exists(io, dir, "BISECT_START")) p.bisect = true;
    if ((try root.exists(repo.allocator(), io, .revert_head))) p.revert = true;
    if (lastSequenced(repo.allocator(), io, repo)) |last| switch (last) {
        .pick => p.cherry_pick = true,
        .revert => p.revert = true,
    };
    return p;
}

/// What a stopped sequence of picks or reverts runs.
pub const Sequenced = enum { pick, revert };

/// The command the first line of `.git/sequencer/todo` names, `pick` (or
/// `p`) or `revert`, then a space or tab: what a stopped sequence last
/// ran, as git's `sequencer_get_last_command` reads it. `null` with no
/// such line.
pub fn lastSequenced(gpa: Allocator, io: Io, repo: *Repository) ?Sequenced {
    const text = (state.read(gpa, io, repo.gitDirectory(), "sequencer/todo") catch return null) orelse return null;
    defer gpa.free(text);
    const rest = std.mem.trimStart(u8, text, " \t\r\n");
    const words = [_]struct { Sequenced, []const u8, ?u8 }{ .{ .pick, "pick", 'p' }, .{ .revert, "revert", null } };
    for (words) |w| {
        const after = if (std.mem.startsWith(u8, rest, w[1]))
            rest[w[1].len..]
        else if (w[2] != null and rest.len != 0 and rest[0] == w[2].?)
            rest[1..]
        else
            continue;
        if (after.len != 0 and (after[0] == ' ' or after[0] == '\t')) return w[0];
    }
    return null;
}
