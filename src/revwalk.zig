//! Walking history.
//!
//! Push the commits to start from, hide the ones whose ancestors are not
//! wanted, and take commits out one at a time. Nothing here needs a
//! commit-graph; a caller that has one hands it in and the answers do not
//! change, which is what an accelerator must mean.
//!
//! Neither a hidden commit nor an ancestry question walks the whole of
//! history. A walk with hidden commits takes the pushed and the hidden
//! together, newest first, as git's `limit_list` does, and stops once
//! nothing left can still be wanted; `isAncestor` paints down from both
//! commits as git's `paint_down_to_common` does, and with a commit-graph's
//! generation numbers stops below the ancestor's generation. A shallow
//! repository's boundary commits have no parents here, and its commit-graph,
//! which knows parents the repository lacks, is not read.

const core = @import("revwalk_core.zig");
pub const revparse = @import("revparse.zig");
pub const shallow = @import("shallow.zig");
/// Who a commit's people are, as `.mailmap` says.
pub const mailmap = @import("mailmap.zig");
/// `git shortlog`: commits grouped by who made them.
pub const shortlog = @import("shortlog.zig");
/// `git describe`, and with `contains`, `git name-rev`'s naming.
pub const describe = @import("describe.zig");
/// `git bisect`, its state files and its choice of commit included.
pub const bisect = @import("bisect.zig");
/// Errors from a walk.
pub const Error = core.Error;
/// The order commits come out in.
pub const Sort = core.Sort;
/// One commit, with what the walk needed from it.
pub const Commit = core.Commit;
/// A history walk: `git rev-list`'s own, from the commits pushed, less
/// everything the hidden ones reach.
///
/// The walk is git's `revision.c`: a queue by committer date, ties taken
/// first in first out; with hidden commits the queue carries them too,
/// marking what they reach as it goes, and stops once nothing it still
/// holds can be wanted -- five commits past the point where every commit
/// left is hidden, as git's `limit_list` stops, which is also what makes a
/// commit with a skewed date come out where git's comes out. The
/// topological order is git's `sort_in_topological_order` in graph order
/// over what that walk found.
pub const Walk = core.Walk;
/// A commit's parents as a walk sees them: none for a commit at a shallow
/// repository's boundary, whose parents are not in it.
pub const parentsOf = core.parentsOf;
/// Every merge base of `a` and `b`: the common ancestors none of whose
/// descendants is also a common ancestor, newest committer date first.
///
/// This is git's walk and git's order, which matters beyond speed: when there
/// is more than one base, the order is the order a merge folds them in. Both
/// commits' ancestries are painted down together, newest date first, until
/// only commits already known to be behind a common ancestor are left; the
/// common ones found are then checked against each other and any one another
/// can reach is dropped.
///
/// The result is the caller's. An empty result means the two commits share
/// no history, which is what an unrelated-histories merge looks like.
pub const mergeBases = core.mergeBases;
/// What else a merge-base computation may read from.
pub const BaseOptions = core.BaseOptions;
/// A commit that exists only for the length of a computation: a recursive
/// merge's merged base, whose parents are the two bases it merged and whose
/// date is git's zero.
pub const Virtual = core.Virtual;
/// `mergeBases`, reading commits as `options` says.
pub const mergeBasesWith = core.mergeBasesWith;
/// git's `get_merge_bases_many`: the merge bases of one commit and several
/// others at once, newest first.
pub const mergeBasesMany = core.mergeBasesMany;
/// `mergeBasesMany`, reading commits as `options` says.
pub const mergeBasesManyWith = core.mergeBasesManyWith;
/// The first merge base of `a` and `b`, or `null` when they share no
/// history.
pub const mergeBase = core.mergeBase;
/// Whether `ancestor` is reachable from `descendant`: git's
/// `repo_in_merge_bases`, which paints both down by date and stops as soon
/// as nothing left to walk can decide it.
pub const isAncestor = core.isAncestor;
/// `isAncestor`, reading commits as `options` says.
pub const isAncestorWith = core.isAncestorWith;

/// Git's rev-list --count, accelerated by reachability bitmaps.
pub const count = @import("objectwalk.zig").countCommits;
/// Reachable object counts by type, as rev-list --objects --count.
pub const countObjects = @import("objectwalk.zig").countObjects;
