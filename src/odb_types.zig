const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("hash.zig");
const Kind = hash.Kind;
const Oid = hash.Oid;
const object = @import("object_core.zig");
const pack = @import("pack.zig");
const fs = @import("fs.zig");
/// How the object database behaves. The only caches in this package are
/// named here.
pub const Options = struct {
    /// How many bytes of resolved delta bases to keep. Zero disables the
    /// cache, which makes a walk over a packed repository quadratic in its
    /// chain length and is almost never what you want.
    delta_cache_bytes: usize = 16 * 1024 * 1024,
    /// Whether packs are reached through a memory map where the platform has
    /// one. Off by default: a map is faster on a cold cache, and it turns an
    /// IO error into a signal nobody can catch and holds the file open
    /// against a `git gc` that wants to replace it. Both of those are the
    /// property this package exists to keep.
    map_packs: bool = false,
    /// How hard a loose object is pushed towards the disk. git's own default
    /// syncs neither loose objects nor the index; `batch` gives real
    /// durability for one barrier per batch rather than one per object, and
    /// `Odb.syncBatch` is that barrier.
    sync: fs.Sync = .none,
    /// Whether to make a directory entry durable after a rename. git does
    /// not; the guarantee it adds is one git does not make.
    sync_directories: bool = fs.sync_directories_default,
    /// The buffer size a streaming read uses.
    read_buffer_size: usize = 64 * 1024,
    /// How deep a delta chain may be before it is refused.
    max_delta_depth: u32 = pack.default_max_depth,
    /// How many levels of `objects/info/alternates` to follow.
    max_alternate_depth: u8 = 5,
    /// The largest inflated loose object, including its header, this will
    /// read into memory. Exceeding it is `error.StreamTooLong`.
    max_object_bytes: usize = 1 << 31,
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
    /// Off. It costs about five times the hash, and what it guards is git's
    /// object format rather than a file on the disk: the published colliding
    /// documents are not colliding objects, because `"blob <size>\0"` goes
    /// in front of the content and moves every block of the message. A
    /// SHA-256 repository ignores it.
    detect_sha1_collisions: bool = false,
};

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
    /// `objects/info/alternates` pointed at itself, or the chain was deeper
    /// than `Options.max_alternate_depth`.
    AlternatesTooDeep,
    /// A path cannot be represented as one alternates-file line.
    InvalidAlternatePath,
    /// Adding a path would pass the supported alternates-file size.
    AlternatesTooLarge,
} || pack.Error || pack.WriteError || object.HeaderParseError ||
    object.ParseError || object.TreeParseError || Allocator.Error ||
    Io.Dir.OpenError || Io.File.OpenError || Io.Writer.Error ||
    Io.File.Reader.Error || Io.Reader.Error || Io.File.SyncError || Io.Dir.RenameError || Io.Dir.DeleteFileError ||
    Io.Dir.CreateDirPathError || Io.Dir.ReadFileAllocError || Io.Dir.Iterator.Error;

/// Counters saying how lookups resolved and what writing cost. Nothing
/// depends on them; they are how a caller, or a test, sees that an
/// accelerator is being used and that a batch of writes stayed cheap.
pub const Stats = struct {
    /// Lookups a multi-pack index narrowed to one pack.
    midx_hits: u64 = 0,
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
