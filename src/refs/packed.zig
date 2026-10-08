//! `packed-refs`, parsed, and kept from one read to the next.
//!
//! A repository with a thousand tags holds them in `packed-refs`, and a
//! lookup that misses the loose files would otherwise read and parse every
//! line of it. git's files backend keeps a snapshot of the file instead and
//! checks it on every lookup with `stat_validity_check`; this does the same.
//! The stat recorded is the one of the file the bytes were read through, so
//! a replacement between a stat and the read cannot pass for the file it
//! replaced. Every writer, git's and relic's, replaces `packed-refs` by
//! renaming a lock over it, which gives the file a new identity; its size
//! and times are compared as well, as git compares them.
//!
//! The entries are kept sorted by name, which is the order git writes and
//! its `sorted` trait promises; a file without that order is sorted when
//! it is read, as git sorts it, so a lookup is a bisection either way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const names = @import("../names/ref.zig");
const ReadError = @import("value.zig").ReadError;

const Oid = hash.Oid;
const Kind = hash.Kind;

/// The largest `packed-refs` read.
const max_bytes = 1 << 28;

/// One line of `packed-refs`.
pub const Entry = struct {
    name: []const u8,
    oid: Oid,
    /// The object an annotated tag points at, from a `^` line.
    peeled: ?Oid,
    /// A name no ref may have (`names.checkFormat` refuses it), decided
    /// once as the file is read: a listing reports it broken.
    broken: bool = false,
};

/// Everything `packed-refs` holds, sorted by name.
pub const Listing = struct {
    gpa: Allocator,
    bytes: []u8,
    entries: []Entry,
    /// Whether the header claimed every tag is peeled.
    fully_peeled: bool,

    /// Release the listing.
    pub fn deinit(listing: *Listing) void {
        listing.gpa.free(listing.entries);
        listing.gpa.free(listing.bytes);
        listing.* = undefined;
    }

    /// The entry named `name`, or `null`. When a file names a ref twice,
    /// the first line wins.
    pub fn find(listing: *const Listing, name: []const u8) ?Entry {
        const at = std.sort.lowerBound(Entry, listing.entries, name, orderName);
        if (at < listing.entries.len and std.mem.eql(u8, listing.entries[at].name, name)) return listing.entries[at];
        return null;
    }

    fn empty(gpa: Allocator) Allocator.Error!Listing {
        const bytes = try gpa.alloc(u8, 0);
        errdefer gpa.free(bytes);
        return .{ .gpa = gpa, .bytes = bytes, .entries = try gpa.alloc(Entry, 0), .fully_peeled = false };
    }
};

fn orderName(name: []const u8, entry: Entry) std.math.Order {
    return std.mem.order(u8, name, entry.name);
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Parse `packed-refs` bytes this takes ownership of, including on error.
pub fn parse(gpa: Allocator, kind: Kind, bytes: []u8) ReadError!Listing {
    errdefer gpa.free(bytes);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var fully_peeled = false;

    const hex_len = kind.hexLen();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    var sorted = true;
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (first and std.mem.find(u8, line, "fully-peeled") != null) fully_peeled = true;
            first = false;
            continue;
        }
        first = false;
        if (line[0] == '^') {
            if (entries.items.len == 0) return error.MalformedPackedRefs;
            const oid = Oid.parse(kind, std.mem.trim(u8, line[1..], " \t")) catch return error.MalformedPackedRefs;
            entries.items[entries.items.len - 1].peeled = oid;
            continue;
        }
        if (line.len < hex_len + 2) return error.MalformedPackedRefs;
        const oid = Oid.parse(kind, line[0..hex_len]) catch return error.MalformedPackedRefs;
        if (line[hex_len] != ' ') return error.MalformedPackedRefs;
        // A name no ref may have stays in the listing, as git's snapshot
        // keeps it broken: a lookup by a ref's name never finds it, a
        // listing reports it, a deletion by its name removes it, and a
        // rewrite of the file keeps it.
        const name = line[hex_len + 1 ..];
        if (entries.items.len != 0 and std.mem.order(u8, entries.items[entries.items.len - 1].name, name) != .lt) sorted = false;
        try entries.append(gpa, .{ .name = name, .oid = oid, .peeled = null, .broken = !names.checkFormat(name, .{ .allow_onelevel = true }) });
    }
    // A stable sort, so that of two lines naming one ref the first stays
    // first, which is the one a lookup finds.
    if (!sorted) std.mem.sort(Entry, entries.items, {}, lessThan);
    return .{
        .gpa = gpa,
        .bytes = bytes,
        .entries = try entries.toOwnedSlice(gpa),
        .fully_peeled = fully_peeled,
    };
}

/// Read `packed-refs` in `dir` now. An absent file is an empty listing.
pub fn read(gpa: Allocator, io: Io, dir: Io.Dir, kind: Kind) ReadError!Listing {
    var seen: Validity = undefined;
    return readSeen(gpa, io, dir, kind, &seen);
}

/// Read `packed-refs`, and what a stat of the file the bytes came through
/// says about it.
fn readSeen(gpa: Allocator, io: Io, dir: Io.Dir, kind: Kind, seen: *Validity) ReadError!Listing {
    var file = dir.openFile(io, "packed-refs", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            seen.* = .{ .present = false };
            return Listing.empty(gpa);
        },
        else => |e| return e,
    };
    defer file.close(io);
    seen.* = Validity.from(file.stat(io) catch |err| return statError(err));
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
    return parse(gpa, kind, bytes);
}

fn statError(err: Io.File.StatError) ReadError {
    return switch (err) {
        error.Streaming => error.Unexpected,
        else => |e| e,
    };
}

/// What a stat of `packed-refs` says: enough to tell that it was replaced.
const Validity = struct {
    present: bool,
    inode: Io.File.INode = 0,
    size: u64 = 0,
    mtime: i96 = 0,
    ctime: i96 = 0,

    fn from(st: Io.File.Stat) Validity {
        return .{ .present = true, .inode = st.inode, .size = st.size, .mtime = st.mtime.nanoseconds, .ctime = st.ctime.nanoseconds };
    }

    fn of(io: Io, dir: Io.Dir) ReadError!Validity {
        const st = dir.statFile(io, "packed-refs", .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .{ .present = false },
            error.Streaming => return error.Unexpected,
            else => |e| return e,
        };
        return from(st);
    }

    fn eql(a: Validity, b: Validity) bool {
        if (a.present != b.present) return false;
        if (!a.present) return true;
        return a.inode == b.inode and a.size == b.size and a.mtime == b.mtime and a.ctime == b.ctime;
    }
};

/// The listing a store last read, and the stat it was read under.
///
/// Behind a mutex, since a daemon reads refs from many tasks. A lookup
/// holds it from the stat to the end of the bisection; a listing copies
/// what it needs while it holds it.
pub const Cache = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    current: ?Listing = null,
    seen: Validity = .{ .present = false },
    /// How many times the file was read, for a test that wants to see the
    /// cache working.
    loads: u64 = 0,

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        if (c.current) |*l| l.deinit();
        c.* = undefined;
    }

    /// The listing as the disk has it now. The caller holds `mutex`, and
    /// the listing is valid until it gives the mutex up.
    pub fn refresh(c: *Cache, io: Io, dir: Io.Dir, kind: Kind) ReadError!*const Listing {
        const now = try Validity.of(io, dir);
        if (c.current) |*l| {
            if (now.eql(c.seen)) return l;
        }
        var seen: Validity = undefined;
        const fresh = try readSeen(c.gpa, io, dir, kind, &seen);
        if (c.current) |*old| old.deinit();
        c.current = fresh;
        c.seen = seen;
        c.loads += 1;
        return &c.current.?;
    }

    /// Forget the listing, so that the next lookup reads the file.
    pub fn forget(c: *Cache, io: Io) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (c.current) |*l| l.deinit();
        c.current = null;
    }
};

test "a listing finds the first of two lines naming one ref, sorted or not" {
    const gpa = std.testing.allocator;
    const text = "2222222222222222222222222222222222222222 refs/tags/b\n" ++
        "1111111111111111111111111111111111111111 refs/heads/a\n" ++
        "3333333333333333333333333333333333333333 refs/tags/b\n";
    var listing = try parse(gpa, .sha1, try gpa.dupe(u8, text));
    defer listing.deinit();
    try std.testing.expectEqualStrings("refs/heads/a", listing.entries[0].name);
    try std.testing.expect(listing.find("refs/tags/b").?.oid.eql(try Oid.parse(.sha1, &@as([40]u8, @splat('2')))));
    try std.testing.expect(listing.find("refs/tags/a") == null);
    try std.testing.expect(listing.find("refs/tags/c") == null);
}
