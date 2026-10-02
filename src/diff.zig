//! Differences: tree against tree, blob against blob, and the unified text
//! git prints.
//!
//! The algorithms are in `textdiff`; this is what turns them into the shapes
//! a caller wants — a name-status list, added and removed line counts, and a
//! patch with git's own headers.

const core = @import("diff_core.zig");
pub const textdiff = @import("textdiff.zig");
pub const rename = @import("rename.zig");
pub const similarity = @import("similarity.zig");
pub const patchid = @import("patchid.zig");
/// Which algorithm produces the edit script.
pub const Algorithm = core.Algorithm;
/// Errors from a diff.
pub const Error = core.Error;
/// What happened to a path.
pub const Status = core.Status;
/// One side of a change.
pub const Entry = core.Entry;
/// One path's change.
pub const Change = core.Change;
/// The result of a tree comparison.
pub const Changes = core.Changes;
/// How rename and copy detection behaves: git's `-M`, `-C` and
/// `--find-copies-harder`, by git's own pairing (`rename.zig`).
///
/// Off by default, which is what `git diff-tree --name-status -r` does
/// without `-M`. It is a heuristic with a threshold and a limit, and
/// turning it on changes what a diff means, so it is the caller's decision.
pub const RenameOptions = core.RenameOptions;
/// How a tree comparison behaves.
pub const TreeOptions = core.TreeOptions;
/// Compare two trees, path by path.
///
/// Either side may be `null`, which compares against the empty tree — what
/// the first commit's diff is.
pub const tree = core.tree;
/// Added and removed line counts for one change.
pub const NumStat = core.NumStat;
/// How a content diff behaves.
pub const Options = core.Options;
/// Errors from reading the diff settings out of a configuration.
pub const ConfigError = core.ConfigError;
/// `options` with the algorithm `diff.algorithm` names, which is the one
/// `git diff`, `git log -p` and `git show` use when none is asked for.
///
/// The value is read without regard to case, as git reads it. `minimal` is
/// Myers made to prove its script minimal, and `default` is Myers. With the
/// setting absent `options` comes back as it was given.
pub const configured = core.configured;
/// git's diff binary rule: a NUL in the first 8000 bytes.
///
/// This is not the rule that decides whether a file is normalised on
/// check-in; that one is `attributes.isBinaryForCheckIn`, and using this one
/// there writes a different blob.
pub const isBinary = core.isBinary;
/// The added and removed line counts between two blobs.
pub const blobNumStat = core.blobNumStat;
/// The counts for every change in a tree comparison, in the same order.
///
/// The result is the caller's.
pub const numstat = core.numstat;
/// Append a unified diff for one change to `w`, with git's headers.
pub const unified = core.unified;
/// Append the `@@` hunks for two blobs, with no `diff --git` header.
///
/// This is what a caller that wants only the body asks for, and what
/// `unified` uses.
pub const unifiedBody = core.unifiedBody;
/// How much of the enclosing line git puts on the `@@` line.
pub const function_context_max = core.function_context_max;
