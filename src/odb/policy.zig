const std = @import("std");
const aegis = @import("aegis");
const Bytes = aegis.units.Bytes(usize);
const Io = std.Io;
const Allocator = std.mem.Allocator;
const object = @import("../object/object.zig");
const pack = @import("pack.zig");
const fs = @import("../fs/fs.zig");
const config_mod = @import("../config/config.zig");
/// How the object database behaves. The only caches in this package are
/// named here.
pub const Options = struct {
    /// `pack_read_cache_bytes`'s default.
    pub const default_pack_read_cache_bytes = pack.default_read_cache_bytes;

    /// How many bytes of resolved delta bases to keep. Zero disables the
    /// cache, which makes a walk over a packed repository quadratic in its
    /// chain length and is almost never what you want.
    /// Consult reachability bitmaps for object sets and counts.
    use_bitmaps: bool = true,
    delta_cache_bytes: Bytes = .literal("16MiB"),
    /// Whether packs are reached through a memory map where the platform has
    /// one. Off by default: a map is faster on a cold cache, and it turns an
    /// IO error into a signal nobody can catch and holds the file open
    /// against a `git gc` that wants to replace it. Both of those are the
    /// property this package exists to keep.
    map_packs: bool = false,
    /// `core.fsync` and `core.fsyncMethod`: which of the objects, packs,
    /// their indexes and the commit-graph are synced, and how. Under
    /// `batch`, each loose object's bytes are ordered before its name and
    /// `Odb.syncBatch` makes the objects and the directories that received
    /// them durable at once, for one flush per directory rather than one
    /// per object.
    fsync: fs.Fsync = .default,
    /// The buffer size a streaming read uses.
    read_buffer_size: Bytes = .literal("64KiB"),
    /// How many bytes of each pack positional reads keep, in aligned blocks
    /// of `pack.read_block_bytes`: `pack.Pack.open`'s `read_cache_bytes`,
    /// for every pack this database opens. A block is allocated when it is
    /// first read, and a pack never holds more than its own size, so the
    /// database holds at most this much, or the pack's size if smaller, per
    /// pack it reads. Not used for a mapped pack.
    pack_read_cache_bytes: Bytes = .fromRaw(default_pack_read_cache_bytes),
    /// How deep a delta chain may be before it is refused.
    max_delta_depth: u32 = pack.default_max_depth,
    /// The deepest `objects/info/alternates` read, the database's own being
    /// 0: git's 5, which reaches six levels of alternates. A deeper file is
    /// not read, as git only logs it.
    max_alternate_depth: u8 = 5,
    /// The longest object read whole (`Odb.read`, `Odb.readInto`), and the
    /// longest delta `Odb.stream` makes whole: past it is
    /// `error.ObjectTooLarge`. A loose object or a pack's whole entry of any
    /// length is read through `Odb.stream`.
    max_object_bytes: Bytes = .fromRaw(1 << 31),
    /// Whether to measure, at open, how fine a modification time the
    /// filesystem under `objects` records.
    ///
    /// On, because the answer decides whether a stat shortcut may believe an
    /// entry's nanoseconds, and neither answer is safe to assume. It costs
    /// one file created, written to three times and removed. Off for a
    /// caller that will not have anything written into that directory.
    probe_timestamp_resolution: bool = true,
    /// Whether every SHA-1 name this database takes is additionally checked
    /// for the signature of a collision attack, which is
    /// `error.CollisionAttack`.
    ///
    /// On, as git always builds SHA-1 with this detector: a chosen-prefix
    /// collision can be computed with the object header inside the prefix,
    /// so two objects of one name are within an attacker's reach, and a
    /// pack received from anyone is where they would arrive. It costs
    /// several times the plain hash on every name taken -- objects written,
    /// received and verified. A SHA-256 repository ignores it.
    detect_sha1_collisions: bool = true,
    /// What `core.sharedRepository` asks of the permissions of what is
    /// written: the objects, the packs and their directories.
    shared: fs.Shared = .umask,
    /// `core.lockfilePid`: each lock this database takes -- its
    /// multi-pack index, its commit graph -- names its holder in a
    /// `~pid.lock` beside it.
    pid_file: bool = false,
    /// `core.createObject`: how a new loose object takes its name -- a
    /// hard link, git's default, falling back to a rename where the
    /// filesystem makes none, or a rename. Either way an object already
    /// there is kept and compared, never replaced.
    create_object: CreateObject = .link,
    /// What the configuration says packs and loose objects are written
    /// with, and whether a multi-pack index is read.
    packing: Packing = .{},
};

/// The settings git's pack-objects and object writer read: `pack.window`,
/// `pack.depth`, `pack.windowMemory`, `pack.compression` (else
/// `core.compression`), `pack.indexVersion`, `core.looseCompression` (else
/// `core.compression`), `core.multiPackIndex` and `core.bigFileThreshold`.
pub const Packing = struct {
    window: u32 = 10,
    /// At most 4095, as git forces it.
    depth: u32 = 50,
    /// `pack.windowMemory`; unset, relic's own bound, and 0 none.
    window_bytes: Bytes = .fromRaw(32 << 20),
    compression: pack.Compression = .default,
    index_version: u2 = 2,
    /// git's default for a loose object is level 1.
    loose_compression: pack.Compression = .fast,
    /// `core.multiPackIndex`: off, no multi-pack index is read.
    multi_pack_index: bool = true,
    /// `core.bigFileThreshold`: a blob larger than this is never a delta's
    /// target or base when a pack is written (`bigFileThreshold`).
    big_file_bytes: u64 = default_big_file_bytes,
};

/// git's default `core.bigFileThreshold`: 512 MiB.
pub const default_big_file_bytes: u64 = 512 << 20;

/// `core.bigFileThreshold` as git's `repo_settings_get_big_file_threshold`
/// reads it: the last value, an unsigned number with a `k`, `m` or `g`
/// suffix (`git_config_ulong`), 512 MiB where it is not set, and a value
/// git dies on -- none at all, a sign, anything else after the digits --
/// refused. Larger than it, a blob is not deltified in a pack, is binary
/// to a diff, and is streamed as git streams it: into a pack of its own
/// when it is added, and through an archive unconverted.
pub fn bigFileThreshold(config: *const config_mod.Config) config_mod.ValueError!u64 {
    const entry = config.find("core.bigfilethreshold") orelse return default_big_file_bytes;
    return config_mod.parseNonNegative(entry.value orelse return error.NotAnInteger, std.math.maxInt(u64));
}

/// `core.createObject`'s two ways.
pub const CreateObject = enum { link, rename };

/// Errors from the object database.
pub const Error = error{
    /// No loose object and no pack holds it, after one pack refresh — and,
    /// in a partial clone with a `Lazy` installed, after asking the
    /// promisor remote.
    ObjectNotFound,
    /// A partial clone's promisor remote was asked for a missing object and
    /// could not give it. The `Lazy` that asked keeps why.
    PromisorFetchFailed,
    /// A loose object whose inflated bytes do not match its own header.
    CorruptLooseObject,
    /// An object read whole that is longer than `Options.max_object_bytes`
    /// (or the address space); `Odb.stream` reads it.
    ObjectTooLarge,
    /// An object replaced, its replacement replaced, and so on five times
    /// over: git's "replace depth too high", past its `MAXREPLACEDEPTH`.
    ReplaceDepthTooHigh,
    /// The replace refs could not be listed: the ref store could not be
    /// read.
    ReplaceRefsUnreadable,
    /// Two replace refs name the same object, as `refs/replace/<oid>` and
    /// `refs/replace/<dir>/<oid>` can: git's "duplicate replace ref".
    DuplicateReplaceRef,
    /// A loose object whose content does not hash to its own name.
    ObjectNameMismatch,
    /// Bytes carrying the signature of a SHA-1 collision attack, from a
    /// database opened with `Options.detect_sha1_collisions`. The object is
    /// not written.
    CollisionAttack,
    /// An object read back as a type the caller did not ask for.
    UnexpectedObjectType,
    /// An object name uses a different hash format from this database.
    ObjectFormatMismatch,
    /// A path cannot be represented as one alternates-file line.
    InvalidAlternatePath,
    /// Adding a path would pass the supported alternates-file size.
    AlternatesTooLarge,
    /// A loose object already there whose file is not the one just written
    /// for the same name: git's "files differ in contents", the check
    /// that keeps a colliding object from replacing the one a name had.
    LooseObjectDiffers,
    /// The object already there kept vanishing while it was compared: git's
    /// "unable to write repeatedly vanishing file".
    LooseObjectVanishing,
} || pack.Error || pack.WriteError || object.HeaderParseError ||
    object.ParseError || object.TreeParseError || Allocator.Error ||
    Io.Dir.OpenError || Io.File.OpenError || Io.Writer.Error ||
    Io.File.Reader.Error || Io.Reader.Error || fs.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError ||
    Io.Dir.CreateDirPathError || aegis.own.ReadFileError || Io.Dir.Iterator.Error || Io.Dir.SetTimestampsError || Io.Dir.AccessError || @import("mtimes.zig").ReadError;

/// Counters saying how lookups resolved and what writing cost. Nothing
/// depends on them; they are how a caller, or a test, sees that an
/// accelerator is being used and that a batch of writes stayed cheap.
pub const Stats = struct {
    /// Lookups a multi-pack index narrowed to one pack.
    midx_hits: u64 = 0,
    /// Object-set requests answered by a reachability bitmap.
    bitmap_hits: u64 = 0,
    /// Lookups that asked every pack in turn, because there was no
    /// multi-pack index, or it did not name the object.
    pack_scans: u64 = 0,
    /// Objects written to the disk: a temporary created, deflated, closed
    /// and renamed.
    loose_written: u64 = 0,
    /// Writes that found the object already there and did nothing.
    loose_present: u64 = 0,
    /// Fan-out directories made. At most two hundred and fifty-six of them
    /// exist, so a batch of any size makes at most that many, however many
    /// objects it writes.
    fan_out_created: u64 = 0,
    /// Objects written into a pack rather than as loose files.
    packed_written: u64 = 0,
};
