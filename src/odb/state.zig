//! The object format, sources and storage machinery have one owner.
//! Package plumbing, reached by no public name.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash.zig");
const Kind = hash.Kind;
const Oid = hash.Oid;
const pack = @import("pack.zig");
const midx = @import("midx.zig");
const flate = std.compress.flate;
const odb = @import("policy.zig");
const reachability = @import("bitmap/reachability.zig");
const Error = odb.Error;
const Stats = odb.Stats;

pub const State = opaque {};
pub const Data = struct {
    gpa: Allocator,
    kind: Kind,
    options: odb.Options,
    sources: std.ArrayList(Source) = .empty,
    cache: pack.Cache,
    generation: u32 = 0,
    bitmap_checked: bool = false,
    bitmap: ?reachability.Store = null,
    deflate_window: []u8,
    deflate_state: ?DeflateState = null,
};

pub fn get(state: *State) *Data {
    return @ptrCast(@alignCast(state)); // safe: create allocates each State as aligned Data.
}

pub fn create(gpa: Allocator, kind: Kind, options: odb.Options) Allocator.Error!*State {
    const data = try gpa.create(Data);
    errdefer gpa.destroy(data);
    var cache = try pack.Cache.init(gpa, options.delta_cache_bytes);
    errdefer cache.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    data.* = .{ .gpa = gpa, .kind = kind, .options = options, .cache = cache, .deflate_window = window };
    return @ptrCast(data); // safe: the opaque owner retains the allocated Data pointer.
}

/// The pack and the name it was opened under have one owner. Registration
/// transfers both together, never a pack without its name or the reverse.
pub const NamedPack = struct {
    pack: pack.Pack,
    name: []u8,

    pub fn deinit(named: *NamedPack, gpa: Allocator, io: Io) void {
        named.pack.deinit(io);
        gpa.free(named.name);
        named.* = undefined;
    }
};

/// One `objects` directory: the repository's own, or an alternate.
pub const Source = struct {
    dir: Io.Dir,
    pack_dir: ?Io.Dir,
    packs: std.ArrayList(NamedPack),
    /// Whether objects may be written here. Only the first source is.
    writable: bool,
    /// `pack/multi-pack-index`, when there is one.
    midx: ?midx.Index,
    /// For each pack the multi-pack index names, its position in `packs`, or
    /// `null` when that pack is not open here. The index names packs by file
    /// name and this database holds them in directory order, so the two have
    /// to be matched up once rather than on every lookup.
    midx_packs: std.ArrayList(?u32),

    /// Which pack holds `oid`, asking the multi-pack index first.
    ///
    /// The index narrows the search to one pack; that pack's own index is
    /// still what gives the offset. Doing it the other way round would make
    /// a stale or wrong index a read at a wrong offset rather than a miss,
    /// and the answer is the same either way, which is the property the whole
    /// accelerator is allowed to have.
    pub fn findPack(source: *Source, oid: Oid, stats: *Stats) Error!?struct { at: usize, offset: u64 } {
        if (source.midx) |*index| {
            // A multi-pack index that misanswers is a miss and not an error:
            // it is an accelerator, and the scan below is the same answer.
            if (index.find(oid) catch null) |located| {
                if (located.pack < source.midx_packs.items.len) {
                    if (source.midx_packs.items[located.pack]) |position| {
                        const p = &source.packs.items[position].pack;
                        if (try p.index.find(oid)) |found| {
                            stats.midx_hits += 1;
                            return .{ .at = position, .offset = found.offset };
                        }
                    }
                }
            }
        }
        stats.pack_scans += 1;
        for (source.packs.items, 0..) |*named, position| {
            const p = &named.pack;
            if (try p.index.find(oid)) |found| return .{ .at = position, .offset = found.offset };
        }
        return null;
    }
};

/// The deflate state a writing database keeps. `flate.Compress` is two
/// hundred and twenty-four kilobytes, which is why it is here and not on the
/// stack of every `write`.
pub const DeflateState = struct {
    compress: *flate.Compress,
    buffer: []u8,
};
