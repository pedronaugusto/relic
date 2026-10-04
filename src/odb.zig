//! The object database: loose objects, the packs, and `objects/info/alternates`.
//!
//! Reading takes an allocator and gives the caller the bytes. Writing goes
//! through a uniquely-named temporary and a rename, so two writers of the same
//! object never meet and a reader never sees half of one.

const core = @import("odb_core.zig");
pub const pack = @import("pack.zig");
pub const delta = @import("delta.zig");
pub const inflate = @import("inflate.zig");
pub const indexpack = @import("indexpack.zig");
pub const revindex = @import("revindex.zig");
pub const commitgraph = @import("commitgraph.zig");
pub const accelerators = @import("accelerators.zig");
pub const midx = @import("midx.zig");
pub const abbrev = @import("abbrev.zig");
/// How the object database behaves. The only caches in this package are
/// named here.
pub const Options = core.Options;
/// Errors from the object database.
pub const Error = core.Error;
/// Paths named directly by one `objects/info/alternates` file. `paths` hold
/// decoded names, and `text` holds the original file; release both with
/// `deinit` when finished.
pub const Alternates = core.Alternates;
/// Counters saying how lookups resolved and what writing cost. Nothing
/// depends on them; they are how a caller, or a test, sees that an
/// accelerator is being used and that a batch of writes stayed cheap.
pub const Stats = core.Stats;
/// The object database.
pub const Odb = core.Odb;
/// One object to put in a pack.
pub const PackEntry = core.PackEntry;
/// Which delta encoding a pack is written with.
pub const DeltaEncoding = core.DeltaEncoding;
/// How a pack is built out of a set of objects.
pub const PackOptions = core.PackOptions;
