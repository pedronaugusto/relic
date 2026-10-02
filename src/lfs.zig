//! Git LFS, in process: the pointer a large file is stored as, the local
//! store its content lives in, and the clean and smudge that move between
//! the two.
//!
//! A repository keeps a large file out of its history by storing, in the
//! blob, a pointer of three short lines — a version, the SHA-256 of the
//! content, its size — and the content itself under `.git/lfs/objects`,
//! named by that SHA-256. A `filter=lfs` attribute is what says a path is
//! kept that way. The program that normally does the conversion is git-lfs,
//! run as a filter; this file does the same conversion without it, so a
//! repository that keeps its large files this way is read and written with
//! no program installed, and what it writes is byte for byte what git-lfs
//! writes: the same pointer, the same object at the same path.
//!
//! What a pointer is follows git-lfs's reader rather than the specification's
//! wording, because the question that matters is whether git-lfs would read
//! a blob as one. It looks at the first 1024 bytes, trims white space from
//! both ends, and asks for `version`, `oid` and `size` in that order; an
//! extension line may come before `size`; a carriage return before a line
//! feed is dropped; empty content is the pointer of an empty file. Anything
//! it would not read as a pointer is content, and is passed through.
//!
//! Checkout never fails for want of an object. A pointer whose object is not
//! in the store is written to the working tree as it stands and named in the
//! outcome, which is what git-lfs does when it is told to skip the download.
//! Fetching the object is a transfer over the network and belongs to whoever
//! holds the connection; `Fetcher` is where it plugs in.
//!
//! An LFS extension (`lfs.extension.<name>.clean`) is a program run around
//! the content, and a pointer that names one is refused by name rather than
//! smudged without it.

const core = @import("lfs_core.zig");
pub const lfsapi = @import("lfsapi.zig");
pub const lfstransfer = @import("lfstransfer.zig");
pub const lfslocks = @import("lfslocks.zig");
pub const lfspush = @import("lfspush.zig");
pub const lfshooks = @import("lfshooks.zig");
pub const lfsssh = @import("lfsssh.zig");
pub const netrc = @import("netrc.zig");
/// The version line every pointer written carries.
pub const spec_version = core.spec_version;
/// The versions a pointer may name and still be read: the public one and the
/// two it replaced.
pub const accepted_versions = core.accepted_versions;
/// How much of a blob is read when asking whether it is a pointer. A blob
/// this long or longer is never listed as one by git-lfs's scanners.
pub const pointer_size_cutoff = core.pointer_size_cutoff;
/// The SHA-256 of nothing, which is the object an empty file would be.
pub const empty_oid = core.empty_oid;
/// A pointer: what an LFS-tracked file is stored as in the object database.
pub const Pointer = core.Pointer;
/// The local store: `<git common dir>/lfs/objects/<aa>/<bb>/<oid>`, or
/// under `lfs.storage`.
pub const Store = core.Store;
/// The pointer of everything `source` holds, without storing it.
pub const hashOnly = core.hashOnly;
/// What decides which objects a checkout asks to have fetched, and whether
/// it asks at all.
pub const Settings = core.Settings;
/// One `lfs.fetchinclude` or `lfs.fetchexclude` pattern against a path, as
/// git-lfs reads it: a pattern names a path or a directory the path is under.
/// Without a slash it names any one component at any depth; with one, or
/// with a leading one, it is matched from the top. A trailing slash changes
/// nothing, and a backslash that escapes nothing is a slash.
pub const patternMatches = core.patternMatches;
/// One object a checkout found missing, for a fetcher to go and get.
pub const Wanted = core.Wanted;
/// Errors a fetcher may return. Any of them fails the checkout; an object a
/// fetcher could not get and said nothing about is left as a pointer.
pub const FetchError = core.FetchError;
/// Where the network plugs in: a caller that can fetch objects hands one to
/// checkout, which calls it once with every object it found missing and then
/// looks in the store again. A fetcher puts what it gets with
/// `Store.install`, naming the pointer it expected.
pub const Fetcher = core.Fetcher;
/// A repository's LFS: its store and its settings, from the configuration
/// and `.lfsconfig`.
pub const Lfs = core.Lfs;
