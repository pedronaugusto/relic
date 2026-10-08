//! A repository's refs as a stack of reftables: `reftable/tables.list`
//! names the tables oldest first, and a ref's value is the one the newest
//! table that mentions it gives -- a tombstone there meaning it is gone.
//!
//! A transaction adds one table. It takes `tables.list.lock` the way git
//! takes it, reads the stack under the lock, checks every expected value,
//! writes the new table beside the others under a name that says which
//! update indexes it covers, and replaces `tables.list` with one more line.
//! Readers never lock: they read `tables.list` and then the tables it
//! names, and a table a concurrent compaction has already removed sends
//! them back to read the list again, which by then names its replacement.
//!
//! After each addition the stack is compacted by git's geometric rule:
//! walking back from the newest table, any run where an older table is not
//! at least twice the size of what follows it is merged into one, so the
//! stack stays logarithmic in the number of transactions. A compaction that
//! reaches the oldest table drops the tombstones, since nothing older is
//! left for them to hide. The sizes the rule compares are this writer's;
//! a log block deflated here is not byte for byte zlib's, so on a stack
//! with logs the point at which a compaction happens can differ from git's
//! by a table, while what every ref and log says does not.
//!
//! `FETCH_HEAD` and `MERGE_HEAD` stay files in a reftable repository, as git
//! keeps them, and no transaction writes them (`Store.special`). Every
//! other root ref -- `ORIG_HEAD`,
//! `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `AUTO_MERGE` -- is a ref in the stack,
//! which is where git since 2.45 keeps them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const Kind = hash.Kind;
const object = @import("../object/object.zig");
const reflog = @import("reflog.zig");
const refs = @import("refs.zig");
const engine = @import("reftablestack/transaction.zig");
/// How the stack writes and compacts. The defaults are git's, and
/// `Repository` fills them in from `reftable.*` in the configuration.
pub const Options = @import("reftablestack/policy.zig").Options;
/// Errors from reading a stack.
pub const Error = @import("reftablestack/policy.zig").Error;
/// One stack, read: the list, and every table it names open.
///
/// A table is its footer and an open file; its blocks are read with
/// positional reads as a lookup reaches them, through the table's index
/// where it has one, so a lookup costs a few blocks and not the stack.
pub const Stack = @import("reftablestack/cache.zig").Stack;
/// The stacks a store has read, kept from one call to the next.
///
/// A daemon that holds a repository for days and reads its refs all the
/// time should not read `tables.list` and open every table for each read.
/// This keeps them, and on each read looks at `tables.list`'s stat: the same
/// file, size and time means nothing changed; otherwise the list is read,
/// and only when its text differs is the stack reloaded, keeping the tables
/// it still names open. That is how git's stack decides to reload. The
/// cache is behind a mutex, since a daemon reads from many tasks; a
/// transaction reads its own stacks under its lock and does not touch it.
pub const Cache = @import("reftablestack/cache.zig").Cache;
/// `Store.read` over reftable. The returned target of a symbolic ref is
/// the caller's.
pub fn read(gpa: Allocator, io: Io, store: *const refs.Store, name: []const u8) refs.ReadError!?refs.Ref {
    return engine.read(gpa, io, store, name);
}
/// `Store.list` over reftable.
pub fn list(gpa: Allocator, io: Io, store: *const refs.Store, prefix: []const u8) refs.ReadError!refs.Store.Listing {
    return engine.list(gpa, io, store, prefix);
}
/// Errors from `readLog`.
pub const ReadLogError = refs.ReadError || reflog.ReadError;

/// `Store.readLog` over reftable: the entries oldest first, as the files
/// backend's log is. An entry whose old and new names are both zero is the
/// marker git writes to say a log exists, and is not an entry.
pub fn readLog(gpa: Allocator, io: Io, store: *const refs.Store, name: []const u8) ReadLogError!reflog.Log {
    return engine.readLog(gpa, io, store, name);
}
/// Whether a log for `name` exists: any entry at all, the existence marker
/// included.
pub fn logExists(gpa: Allocator, io: Io, store: *const refs.Store, name: []const u8) refs.ReadError!bool {
    return engine.logExists(gpa, io, store, name);
}
/// git's zone number -- `+0130` read as 130 -- as minutes east of UTC.
pub fn minutesFromZone(zone: i16) i16 {
    return engine.minutesFromZone(zone);
}
/// Minutes east of UTC as git's zone number.
pub fn zoneFromMinutes(minutes: i16) i16 {
    return engine.zoneFromMinutes(minutes);
}
/// What a prepared transaction holds: the lock on each stack it writes, and
/// the stacks as they were read under it.
pub const Pending = engine.Pending;
/// `Transaction.prepare` over reftable: take `tables.list.lock` on every
/// stack the edits touch, read the stacks under it, and check every
/// expected value and every name against the refs already there.
pub fn prepare(io: Io, tx: *refs.Transaction) refs.TransactionError!void {
    return engine.prepare(io, tx);
}
/// `Transaction.commit` over reftable: one table per stack the edits touch,
/// installed by rewriting `tables.list` under the lock `prepare` took, then
/// the stack compacted if the geometric rule asks for it.
pub fn commit(io: Io, tx: *refs.Transaction, log: ?refs.LogMessage) refs.TransactionError!void {
    return engine.commit(io, tx, log);
}
/// `Store.appendLog` over reftable: one entry, written as a table of its
/// own under the stack's lock, which is how git writes a log that moves no
/// ref. The message is kept as a transaction's is.
pub fn appendLog(
    gpa: Allocator,
    io: Io,
    store: *const refs.Store,
    name: []const u8,
    old: Oid,
    new: Oid,
    who: object.Signature,
    message: []const u8,
) refs.TransactionError!void {
    return engine.appendLog(gpa, io, store, name, old, new, who, message);
}
/// Give up whatever `prepare` took.
pub fn releasePending(io: Io, tx: *refs.Transaction) void {
    return engine.releasePending(io, tx);
}
/// Which tables a compaction merges.
pub const Compaction = engine.Compaction;
/// Compact the stack in `parent`'s `reftable` directory.
///
/// The stack's lock is held throughout, and each table being merged is
/// locked as git locks it, by `<table>.lock`; a table another process has
/// locked -- a git compacting it already -- ends the run there, and only
/// the newer tables past it are merged, as git's best-effort rule does.
pub fn compactIn(gpa: Allocator, io: Io, parent: Io.Dir, kind: Kind, options: Options, which: Compaction) refs.TransactionError!void {
    return engine.compactIn(gpa, io, parent, kind, options, which);
}
