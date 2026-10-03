//! Making a commit the way `git commit` does: its hooks in git's order, the
//! message cleaned as git cleans it, the tree from the index, and the branch
//! moved with its log.
//!
//! `Repository.writeCommit` is `git commit-tree`: it writes an object and
//! nothing else, and git runs no hook for it. This is the porcelain on top.
//! The order is git's own. `pre-commit` runs first, before anything is
//! written, and may change the index, so the index is read again after it.
//! The message goes into `COMMIT_EDITMSG`, where `prepare-commit-msg` and
//! then `commit-msg` may rewrite it, and what is in the file afterwards is
//! the message. Then the tree and the commit are written, `HEAD` moves —
//! the branch it names, under its lock, with a log line there and on
//! `HEAD` — and
//! `post-commit` runs last, when nothing it does can undo the commit.
//!
//! No editor is ever started: the caller supplies the message, which is
//! what `git commit -m` does, and the hooks are told so with
//! `GIT_EDITOR=:`. A merge, a cherry-pick or a revert in progress is a named
//! refusal rather than a commit that quietly drops the other parent.

const core = @import("commit_core.zig");
pub const message = @import("message.zig");
pub const head = @import("head.zig");
pub const reset = @import("reset.zig");
pub const stash = @import("stash.zig");
pub const signing = @import("signing.zig");
pub const commithooks = @import("commithooks.zig");
pub const merging = @import("merging.zig");
pub const sequencer = @import("sequencer.zig");
pub const rebase = @import("rebase.zig");
pub const todo = @import("todo.zig");
/// Notes on objects, kept on `refs/notes/*` as `git notes` keeps them.
pub const notes = @import("notes.zig");
/// Errors from committing.
pub const Error = core.Error;
/// How a message is cleaned, from `commit.cleanup` or the caller.
pub const Cleanup = core.Cleanup;
/// How a commit is made.
pub const Options = core.Options;
/// Who, when, and what to say. The times are the caller's, because nothing
/// in this package reads a clock.
pub const Request = core.Request;
/// What a commit made.
pub const Outcome = core.Outcome;
/// `git commit -m <message>`: run the hooks, write the tree the index
/// describes and a commit of it, and move the branch `HEAD` is on.
pub const commit = core.commit;
/// git's `stripspace`: trailing whitespace off every line, runs of blank
/// lines made one, blank lines off both ends, and a newline after the last
/// line. With `comment`, every line beginning with it goes too. The result
/// is the caller's.
pub const stripspace = core.stripspace;
