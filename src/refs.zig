//! Loose refs and `packed-refs`, with transactions.
//!
//! A transaction takes every `<ref>.lock` in its prepare step and rolls back
//! completely if any one of them is held. Once `commit` starts, loose refs
//! are installed with separate renames and reflogs with separate appends, as
//! they are in git: an I/O error can leave a committed prefix and the caller
//! must reread the refs before deciding what happened.
//!
//! A repository whose refs are a reftable stack is read and written through
//! the same `Store` and `Transaction`; `format` says which, and
//! `reftablestack` is the other side. There a transaction is one table added
//! under one lock, so its commit is all or nothing.

const core = @import("refs_core.zig");
pub const reflog = core.reflog;
pub const reftable = core.reftable;
pub const reftablestack = @import("reftablestack.zig");
/// The header `packed-refs` carries, with the space before the newline that
/// is in git's source and in no document.
pub const packed_header = core.packed_header;
/// How deep a chain of symbolic refs may go. git's own cap.
pub const max_symbolic_depth = core.max_symbolic_depth;
/// Errors from reading refs.
pub const ReadError = core.ReadError;
/// Errors from a transaction.
pub const TransactionError = core.TransactionError;
/// Where a repository's refs are kept.
pub const Format = core.Format;
/// Peels an object name for a ref about to be written, so that a reftable
/// can record what an annotated tag points at beside it, as git's does.
/// `Repository.beginRefs` supplies one.
pub const Peeler = core.Peeler;
/// What a ref points at.
pub const Ref = core.Ref;
/// A ref with its name, as `list` hands them back.
pub const Named = core.Named;
/// A fully resolved ref: the name it ended at and the object it points to.
pub const Resolved = core.Resolved;
/// What an edit requires the ref's current value to be.
pub const Expected = core.Expected;
/// One folder `Store.watchScopes` names: where a ref change lands.
pub const WatchScope = core.WatchScope;
/// The folders `Store.watchScopes` names.
pub const WatchScopes = core.WatchScopes;
/// Loose refs and `packed-refs` behind one reader.
///
/// `git_dir` is the per-worktree directory and `common_dir` the shared one;
/// they are the same in a repository with no linked worktrees. `HEAD`,
/// `refs/bisect`, `refs/worktree` and `refs/rewritten` are per-worktree and
/// everything else is shared, which is the fixed list git uses.
pub const Store = core.Store;
/// What a log entry a transaction writes says.
pub const LogMessage = core.LogMessage;
/// A set of ref updates applied together.
///
/// `prepare` takes every lock; if any is held the whole thing rolls back and
/// nothing on the disk has changed. `commit` then installs each new value and
/// appends each log line. Those renames and appends are separate filesystem
/// operations, so a commit-time error is indeterminate and may have installed
/// a prefix; reread the affected refs before retrying.
///
/// An update or a deletion goes through a symbolic ref to the ref at the end
/// of it, as git's does unless told `--no-deref`: moving `HEAD` while it
/// names `refs/heads/main` moves `refs/heads/main`, and both logs record it.
/// Moving the branch `HEAD` names, by its own name, records it in `HEAD`'s
/// log as well, because that is also what `HEAD` did. `EditOptions.no_deref`
/// changes the named ref itself, which is how `HEAD` is detached. A symbolic
/// new value always changes the named ref, as `git symbolic-ref` does.
///
/// With `hooks` set, `reference-transaction` is told about the transaction
/// the way git tells it about every one: `preparing` before any lock is
/// taken, `prepared` once every lock is held and checked, then `committed`
/// or `aborted`. A hook that fails in either of the first two refuses the
/// transaction, which then rolls back as it would for a held lock.
pub const Transaction = core.Transaction;
