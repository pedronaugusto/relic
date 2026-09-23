//! Short object names, as git prints them.
//!
//! A short name is not decoration where history is edited: the sequencer's
//! `todo` names commits by them, a conflict marker is labelled with one, and
//! git reads both back. So the length is git's: `core.abbrev`, or, when that
//! is `auto` or unset, one hexadecimal digit for every two bits of the packed
//! object count, never fewer than seven -- and then longer until the prefix
//! names nothing else.

const std = @import("std");
const Io = std.Io;

const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const config_mod = @import("config.zig");

const Oid = hash.Oid;

/// The shortest length git ever starts from.
pub const minimum = 4;
/// What git starts from in a repository too small for the count to matter.
pub const fallback = 7;

/// The length `core.abbrev` asks for, or git's automatic one when it says
/// `auto` or nothing. `false` asks for whole names.
pub fn defaultLength(config: *const config_mod.Config, db: *const odb_mod.Odb) usize {
    const hex_len = db.kind.hexLen();
    if (config.get("core.abbrev")) |text| {
        if (!std.ascii.eqlIgnoreCase(text, "auto")) {
            if (config_mod.parseInt(text)) |n| {
                if (n < minimum) return minimum;
                return @min(@as(usize, @intCast(n)), hex_len);
            } else |_| {}
            if (config_mod.parseBool(text)) |on| {
                if (!on) return hex_len;
            } else |_| {}
        }
    }
    return automaticLength(db);
}

/// git's automatic length: the packed objects are counted -- loose ones are
/// not, as in git -- and a name needs half as many digits as the count has
/// bits, rounded up, and never fewer than seven.
pub fn automaticLength(db: *const odb_mod.Odb) usize {
    var count: u64 = 0;
    for (db.sources.items) |*source| {
        for (source.packs.items) |*p| count += p.index.count;
    }
    // The most significant bit's place, plus one; zero objects is one bit,
    // as in git.
    const bits: usize = if (count == 0) 1 else 64 - @clz(count);
    return @max(fallback, (bits + 1) / 2);
}

/// The shortest prefix of `oid`, at least `min_len` digits, that names no
/// other object in the database. Written into `buf`.
pub fn unique(io: Io, db: *odb_mod.Odb, oid: Oid, min_len: usize, buf: *[hash.max_hex_len]u8) odb_mod.Error![]const u8 {
    const full = oid.hex(buf);
    var len = @min(@max(min_len, minimum), full.len);
    while (len < full.len) : (len += 1) {
        _ = db.findPrefix(io, full[0..len]) catch |err| switch (err) {
            error.AmbiguousPrefix => continue,
            // An object the database does not hold is named by any prefix;
            // git prints the shortest.
            error.ObjectNotFound => break,
            else => |e| return e,
        };
        break;
    }
    return full[0..len];
}

test "a short name grows until it names one object" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects/pack");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var db = try odb_mod.Odb.openAt(gpa, io, objects, .sha1, .{});
    defer db.deinit(io);

    // Write blobs until two share their first five digits.
    var seen: std.StringHashMapUnmanaged(Oid) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        seen.deinit(gpa);
    }
    var pair: ?[2]Oid = null;
    var n: u32 = 0;
    while (pair == null) : (n += 1) {
        var text: [32]u8 = undefined;
        const oid = try db.write(io, .blob, try std.fmt.bufPrint(&text, "{d}\n", .{n}));
        var hex_buf: [hash.max_hex_len]u8 = undefined;
        const prefix = oid.hex(&hex_buf)[0..5];
        if (seen.get(prefix)) |other| {
            pair = .{ other, oid };
        } else try seen.put(gpa, try gpa.dupe(u8, prefix), oid);
    }
    var buf: [hash.max_hex_len]u8 = undefined;
    const short = try unique(io, &db, pair.?[0], 4, &buf);
    try std.testing.expect(short.len >= 6);
    try std.testing.expectEqual(pair.?[0], try db.findPrefix(io, short));
}
