//! The index: `DIRC`, versions 2, 3 and 4.
//!
//! An extension whose signature begins with an upper-case letter is optional
//! and is kept byte for byte and written back; a lower-case one is mandatory
//! and is either understood or a named refusal, because quietly dissolving one
//! is data loss. `TREE`, `REUC`, `link` and `sdir` are understood.
//!
//! `sdir` marks a sparse index: a directory the sparse cone leaves out may
//! stand as one entry, its path ending in `/`, its mode `040000`, its name
//! the tree's, and `skip-worktree` set. Such an entry is read, kept and
//! written back as it is; `sparseindex` is what expands one into the files
//! under it and collapses them again.

const core = @import("index_core.zig");
pub const sparseindex = @import("sparseindex.zig");
/// The signature every index begins with.
pub const magic = core.magic;
/// Errors from reading an index.
pub const ReadError = core.ReadError;
/// Errors from writing an index.
pub const WriteError = core.WriteError;
/// One tracked path.
pub const Entry = core.Entry;
/// An extension this package does not interpret, kept exactly as it was read.
pub const RawExtension = core.RawExtension;
/// The `TREE` extension: a tree object name per directory, so `write-tree`
/// rebuilds only the directories that changed.
///
/// An invalidated node carries an entry count of -1 and no object name, which
/// is what an edit under it leaves behind.
pub const CacheTree = core.CacheTree;
/// The `REUC` extension: what a conflict replaced, so `checkout --merge` and
/// `rerere forget` can put it back. Read and written back; a stage is added
/// to it with `Index.recordResolveUndo`.
pub const ResolveUndo = core.ResolveUndo;
/// How an index is written.
pub const WriteOptions = core.WriteOptions;
/// The index.
pub const Index = core.Index;
