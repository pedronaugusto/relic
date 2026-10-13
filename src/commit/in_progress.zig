//! Which operations a worktree is in the middle of, as `git status` says:
//! git's `wt_status_get_state` over the state files and refs they keep.

const std = @import("std");
const Io = std.Io;

const repo_mod = @import("../repo/repo.zig");
const state = @import("../repo/state.zig");
const sequencer = @import("sequencer.zig");

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
pub fn read(io: Io, repo: *Repository) InProgress {
    const dir = repo.gitDirectory();
    var p: InProgress = .{};
    if (repo.refStore().special().exists(io, .merge_head)) {
        p.merge = true;
    } else if (state.exists(io, dir, "rebase-apply")) {
        if (state.exists(io, dir, "rebase-apply/applying")) p.am = true else p.rebase = true;
    } else if (state.exists(io, dir, "rebase-merge")) {
        p.rebase_merge = true;
        p.interactive = state.exists(io, dir, "rebase-merge/interactive");
    }
    const root = repo.refStore().root();
    if (root.exists(repo.allocator(), io, .cherry_pick_head)) p.cherry_pick = true;
    if (state.exists(io, dir, "BISECT_START")) p.bisect = true;
    if (root.exists(repo.allocator(), io, .revert_head)) p.revert = true;
    if (sequencer.lastCommand(repo.allocator(), io, repo)) |last| switch (last) {
        .pick => p.cherry_pick = true,
        .revert => p.revert = true,
    };
    return p;
}
