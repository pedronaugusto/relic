//! Three-way merges of blob contents and trees.
//!
//! The blob merge is `blobmerge.zig`'s, xdiff's decision for decision. The
//! tree merge here is stage-only by default: every path both sides changed
//! differently is left at stages 1, 2 and 3, which is not what any git
//! command does, and is for a caller that wants to decide every path
//! itself. With `content_merge` it is git's merge, `ort.zig`'s: renames
//! followed, files merged, conflicts recorded as git records them.

const core = @import("merge_core.zig");
pub const blobmerge = @import("blobmerge.zig");
pub const ort = @import("ort.zig");
pub const strategy = @import("strategy.zig");
pub const subtreeshift = @import("subtreeshift.zig");
pub const threeway = @import("threeway.zig");
pub const rerere = @import("rerere.zig");
/// Errors from a merge.
pub const Error = core.Error;
/// A content merge refuses data git classifies as binary.
pub const BlobError = core.BlobError;
/// Which conflict body to write: `merge.conflictStyle`.
pub const ConflictStyle = core.ConflictStyle;
/// Which side a conflict resolves to without markers.
pub const Favor = core.Favor;
/// The words after the markers.
pub const Labels = core.Labels;
/// Options for a blob merge.
pub const BlobOptions = core.BlobOptions;
/// The owned bytes produced by a blob merge.
pub const BlobResult = core.BlobResult;
/// Merge `ours` and `theirs` against `ancestor`: `blobmerge.blobs`.
pub const blobs = core.blobs;
/// Where a refusal writes the path that caused it.
pub const Blocked = core.Blocked;
/// One side's view of a path.
pub const Side = core.Side;
/// A path both sides changed differently.
pub const Conflict = core.Conflict;
/// What a merge produced.
pub const Result = core.Result;
/// Options for a tree merge.
pub const TreeOptions = core.TreeOptions;
/// Stage `ours` and `theirs` against their common ancestor `base`, and
/// merge nothing.
///
/// A path only one side changed takes that side; a path both changed the
/// same way takes it once; every other path is left at stages 1, 2 and 3,
/// contents unread. That is not what any git command does -- git's merge
/// follows renames and merges files, and `content_merge` asks for that --
/// but a caller that wants to decide every changed path itself starts
/// here. `base` may be `null`, which is what an unrelated-histories merge
/// looks like: every path that is in both sides and differs is a conflict.
pub const trees = core.trees;
/// `trees`, or with `options.content_merge` git's own merge of the three
/// (`ort.mergeTrees`): renames followed, files merged, conflicts recorded
/// as git records them.
pub const treesWithOptions = core.treesWithOptions;
/// The index and conflicts of an `ort.Result`.
pub const fromOrt = core.fromOrt;
/// The tree a clean merge produces, written to the object database.
///
/// `error.MergeConflict` when the merge is not clean; the caller inspects
/// the `Result` for the conflicts instead.
pub const tree = core.tree;
/// The tree of what a merge leaves behind, conflicts and all: for a
/// content merge the tree it wrote, which is the one git records as
/// `AUTO_MERGE` and `git merge-tree --write-tree` prints; for a stage-only
/// one, every resolved path and our side of every conflicted one.
pub const conflictedTree = core.conflictedTree;
