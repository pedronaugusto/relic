//! Patches as git reads them: a patch read into values, and applied to
//! the working tree and the index (`git apply`).
const core = @import("patchparse.zig");
pub const apply = @import("apply.zig");
/// Errors from reading a patch.
pub const Error = core.Error;
/// How a patch is read.
pub const Options = core.Options;
/// Where a refusal to read a patch was found.
pub const Diagnostic = core.Diagnostic;
/// One file's change in a patch.
pub const FilePatch = core.FilePatch;
/// One `@@` hunk of it.
pub const Fragment = core.Fragment;
/// One side of a `GIT binary patch`.
pub const BinaryHunk = core.BinaryHunk;
/// Whether a patch creates or deletes: unknown, no or yes.
pub const Tri = core.Tri;
/// A read patch.
pub const Patch = core.Patch;
/// Read every file's patch in `text`: git patches and traditional unified
/// diffs, whatever surrounds them, as `git apply` reads them.
pub const parse = core.parse;
/// The most a patch may be.
pub const max_patch_bytes = core.max_patch_bytes;
