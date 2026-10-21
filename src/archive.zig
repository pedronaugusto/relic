//! Archives of a tree, as `git archive` writes them (`archive/archive.zig`),
//! and of another repository's, as `upload-archive` and `git archive
//! --remote` exchange them (`archive/remote.zig`).

const archive_mod = @import("archive/archive.zig");

pub const Error = archive_mod.Error;
pub const Format = archive_mod.Format;
pub const Named = archive_mod.Named;
pub const formats = archive_mod.formats;
pub const formatNamed = archive_mod.formatNamed;
pub const Options = archive_mod.Options;
pub const Inputs = archive_mod.Inputs;
pub const archive = archive_mod.archive;
/// git's `upload-archive` and `git archive --remote`.
pub const remote = @import("archive/remote.zig");
