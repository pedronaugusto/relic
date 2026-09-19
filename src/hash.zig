//! Object names.
//!
//! A repository has exactly one hash, named by `extensions.objectFormat` and
//! decided when the repository is opened. Every `Oid` carries the `Kind` it
//! was made with, so a name from one repository cannot be compared with a name
//! from another by accident, and nothing in this package assumes twenty bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A repository's hash function.
///
/// git's transition document states there is no interoperability between the
/// two: one repository uses one hash, for every object in it.
pub const Kind = enum {
    sha1,
    sha256,

    /// The width of a raw object name in bytes: 20, or 32.
    pub fn rawLen(kind: Kind) usize {
        return switch (kind) {
            .sha1 => 20,
            .sha256 => 32,
        };
    }

    /// The width of a hexadecimal object name in characters: 40, or 64.
    pub fn hexLen(kind: Kind) usize {
        return kind.rawLen() * 2;
    }

    /// The name `extensions.objectFormat` carries, and the one
    /// `git init --object-format` takes.
    pub fn name(kind: Kind) []const u8 {
        return switch (kind) {
            .sha1 => "sha1",
            .sha256 => "sha256",
        };
    }

    /// The `Kind` an `extensions.objectFormat` value names.
    ///
    /// Returns `error.UnknownObjectFormat` for anything else, rather than
    /// falling back to SHA-1 and reading every object name at the wrong width.
    pub fn parse(text: []const u8) error{UnknownObjectFormat}!Kind {
        if (std.mem.eql(u8, text, "sha1")) return .sha1;
        if (std.mem.eql(u8, text, "sha256")) return .sha256;
        return error.UnknownObjectFormat;
    }
};

/// The widest raw object name this package handles, which is SHA-256's.
pub const max_raw_len = 32;

/// The widest hexadecimal object name, which is SHA-256's.
pub const max_hex_len = max_raw_len * 2;

/// An object name: the raw digest bytes and the hash they came from.
///
/// `Oid` is a value. It owns nothing, copies freely and may be stored in a
/// hash map; only the first `kind.rawLen()` bytes of `bytes` are meaningful
/// and the rest are zero, so `std.mem.eql` over the whole array is a correct
/// comparison for names of the same kind.
pub const Oid = struct {
    kind: Kind,
    bytes: [max_raw_len]u8,

    /// Errors from reading an object name written as text.
    pub const ParseError = error{
        /// The text was not exactly `kind.hexLen()` characters.
        InvalidLength,
        /// The text held a character that is not a hexadecimal digit.
        InvalidCharacter,
    };

    /// The all-zeros name. A ref update uses it for "did not exist", and
    /// `packed-refs` never carries it.
    pub fn zero(kind: Kind) Oid {
        return .{ .kind = kind, .bytes = @splat(0) };
    }

    /// Whether this is the all-zeros name.
    pub fn isZero(oid: Oid) bool {
        return std.mem.allEqual(u8, oid.bytes[0..oid.kind.rawLen()], 0);
    }

    /// An object name from its hexadecimal text.
    ///
    /// The text must be exactly the width `kind` asks for; a short name is
    /// `error.InvalidLength` rather than a silent prefix match, because
    /// resolving an abbreviation needs the object database and this does not.
    pub fn parse(k: Kind, text: []const u8) ParseError!Oid {
        if (text.len != k.hexLen()) return error.InvalidLength;
        var oid: Oid = .zero(k);
        var i: usize = 0;
        while (i < k.rawLen()) : (i += 1) {
            const hi = try hexDigit(text[i * 2]);
            const lo = try hexDigit(text[i * 2 + 1]);
            oid.bytes[i] = (hi << 4) | lo;
        }
        return oid;
    }

    /// An object name from its raw digest bytes.
    ///
    /// `raw` must be exactly `kind.rawLen()` bytes.
    pub fn fromRaw(k: Kind, bytes: []const u8) error{InvalidLength}!Oid {
        if (bytes.len != k.rawLen()) return error.InvalidLength;
        var oid: Oid = .zero(k);
        @memcpy(oid.bytes[0..bytes.len], bytes);
        return oid;
    }

    /// The raw digest bytes, `kind.rawLen()` of them. Borrowed from `oid`.
    pub fn raw(oid: *const Oid) []const u8 {
        return oid.bytes[0..oid.kind.rawLen()];
    }

    /// Whether two names are the same name. Names of different kinds are
    /// never equal, whatever their bytes.
    pub fn eql(a: Oid, b: Oid) bool {
        if (a.kind != b.kind) return false;
        return std.mem.eql(u8, a.raw(), b.raw());
    }

    /// Byte order over the raw digest, which is the order a pack index, a
    /// tree's entries after their names, and `packed-refs` all use.
    pub fn order(a: Oid, b: Oid) std.math.Order {
        return std.mem.order(u8, a.raw(), b.raw());
    }

    /// Whether `prefix`, a hexadecimal abbreviation, names this object.
    ///
    /// Case-insensitive, and a prefix longer than the hash is never a match.
    pub fn startsWithHex(oid: Oid, prefix: []const u8) bool {
        if (prefix.len > oid.kind.hexLen()) return false;
        var buf: [max_hex_len]u8 = undefined;
        const text = oid.hex(&buf);
        for (text[0..prefix.len], prefix) |a, b| {
            const lowered = std.ascii.toLower(b);
            if (a != lowered) return false;
        }
        return true;
    }

    /// The hexadecimal name, written into `buf` and returned as a slice of
    /// it. `buf` must hold at least `kind.hexLen()` bytes; `max_hex_len` is
    /// always enough.
    pub fn hex(oid: *const Oid, buf: []u8) []const u8 {
        const n = oid.kind.rawLen();
        std.debug.assert(buf.len >= n * 2);
        for (oid.bytes[0..n], 0..) |byte, i| {
            buf[i * 2] = hex_digits[byte >> 4];
            buf[i * 2 + 1] = hex_digits[byte & 0xf];
        }
        return buf[0 .. n * 2];
    }

    /// The short form a diff header carries: the first `n` hexadecimal
    /// characters, written into `buf` and returned as a slice of it.
    ///
    /// `n` is clamped to the full width; asking for more than the hash has
    /// gives the whole name rather than an error.
    pub fn abbrev(oid: *const Oid, buf: []u8, n: usize) []const u8 {
        var full: [max_hex_len]u8 = undefined;
        const text = oid.hex(&full);
        const take = @min(n, text.len);
        std.debug.assert(buf.len >= take);
        @memcpy(buf[0..take], text[0..take]);
        return buf[0..take];
    }

    /// Formats as the hexadecimal name, which is what every git text format
    /// carries.
    pub fn format(oid: Oid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [max_hex_len]u8 = undefined;
        try w.writeAll(oid.hex(&buf));
    }

    /// A hash map context keyed on the raw digest. The kind takes part, so a
    /// map may hold names from two repositories without colliding.
    pub const MapContext = struct {
        pub fn hash(_: MapContext, oid: Oid) u64 {
            var h: std.hash.Wyhash = .init(@intFromEnum(oid.kind));
            h.update(oid.raw());
            return h.final();
        }
        pub fn eql(_: MapContext, a: Oid, b: Oid) bool {
            return a.eql(b);
        }
    };

    /// A hash map from object name to `V`, using `MapContext`.
    pub fn Map(comptime V: type) type {
        return std.HashMapUnmanaged(Oid, V, MapContext, std.hash_map.default_max_load_percentage);
    }

    /// A set of object names.
    pub const Set = Map(void);
};

const hex_digits = "0123456789abcdef";

fn hexDigit(c: u8) Oid.ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidCharacter,
    };
}

/// The object hash: `"<type> <size>\0"` and then the content.
///
/// An object's name is the hash of its *uncompressed* bytes with that header
/// in front, which is why a loose object's compressed form is free to differ
/// from git's and its name is not.
pub const Hasher = struct {
    state: State,

    const State = union(Kind) {
        sha1: std.crypto.hash.Sha1,
        sha256: std.crypto.hash.sha2.Sha256,
    };

    /// A hasher over `kind`, with nothing fed to it yet. Feed the header
    /// first if you are naming an object; `Hasher` itself makes no header,
    /// because it is also how a pack's trailing checksum is computed.
    pub fn init(k: Kind) Hasher {
        return .{ .state = switch (k) {
            .sha1 => .{ .sha1 = .init(.{}) },
            .sha256 => .{ .sha256 = .init(.{}) },
        } };
    }

    /// The hash this hasher computes.
    pub fn kind(h: *const Hasher) Kind {
        return std.meta.activeTag(h.state);
    }

    /// Feed bytes.
    pub fn update(h: *Hasher, bytes: []const u8) void {
        switch (h.state) {
            inline else => |*s| s.update(bytes),
        }
    }

    /// Feed the `"<type> <size>\0"` header an object name is taken over.
    pub fn updateHeader(h: *Hasher, type_name: []const u8, size: u64) void {
        var buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "{s} {d}\x00", .{ type_name, size }) catch unreachable;
        h.update(header);
    }

    /// The name. The hasher must not be used afterwards.
    pub fn final(h: *Hasher) Oid {
        var oid: Oid = .zero(std.meta.activeTag(h.state));
        switch (h.state) {
            inline else => |*s| s.final(oid.bytes[0..@TypeOf(s.*).digest_length]),
        }
        return oid;
    }

    /// The name of an object of `type_name` whose content is `content`, in
    /// one call.
    pub fn object(k: Kind, type_name: []const u8, content: []const u8) Oid {
        var h: Hasher = .init(k);
        h.updateHeader(type_name, content.len);
        h.update(content);
        return h.final();
    }
};

/// A `std.Io.Writer` that hashes everything written through it and passes it
/// on to another writer, so an object may be named while it streams.
pub const HashingWriter = struct {
    writer: std.Io.Writer,
    hasher: Hasher,
    out: *std.Io.Writer,

    /// Wrap `out`. `buffer` is this writer's own; a few kilobytes is plenty.
    pub fn init(out: *std.Io.Writer, k: Kind, buffer: []u8) HashingWriter {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
            .hasher = .init(k),
            .out = out,
        };
    }

    /// The name of everything written so far. Flush first.
    pub fn final(hw: *HashingWriter) Oid {
        return hw.hasher.final();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const hw: *HashingWriter = @fieldParentPtr("writer", w);
        const buffered = w.buffered();
        if (buffered.len != 0) {
            hw.hasher.update(buffered);
            try hw.out.writeAll(buffered);
            w.end = 0;
            return 0;
        }
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            hw.hasher.update(bytes);
            try hw.out.writeAll(bytes);
            written += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            hw.hasher.update(last);
            try hw.out.writeAll(last);
            written += last.len;
        }
        return written;
    }
};

test "oid parse and format round trip" {
    const hex = "0123456789abcdef0123456789abcdef01234567";
    const oid = try Oid.parse(.sha1, hex);
    var buf: [max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(hex, oid.hex(&buf));
    try std.testing.expect(!oid.isZero());
    try std.testing.expect(Oid.zero(.sha1).isZero());
    try std.testing.expectError(error.InvalidLength, Oid.parse(.sha256, hex));
    try std.testing.expectError(error.InvalidCharacter, Oid.parse(.sha1, "z" ** 40));
}

test "the empty blob has the name git gives it" {
    // git hash-object -t blob /dev/null
    const empty_blob_sha1 = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = Hasher.object(.sha1, "blob", "");
    var buf: [max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(empty_blob_sha1, oid.hex(&buf));

    // git hash-object -t blob --object-format=sha256 /dev/null
    const empty_blob_sha256 = "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813";
    const oid256 = Hasher.object(.sha256, "blob", "");
    try std.testing.expectEqualStrings(empty_blob_sha256, oid256.hex(&buf));
}

test "abbreviation is a prefix of the name" {
    const oid = try Oid.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    var buf: [max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings("0123456", oid.abbrev(&buf, 7));
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        oid.abbrev(&buf, 99),
    );
    try std.testing.expect(oid.startsWithHex("0123456"));
    try std.testing.expect(oid.startsWithHex("0123456789ABCDEF"));
    try std.testing.expect(!oid.startsWithHex("0123457"));
}

test "a name from one hash never equals a name from another" {
    var a: Oid = .zero(.sha1);
    var b: Oid = .zero(.sha256);
    a.bytes[0] = 1;
    b.bytes[0] = 1;
    try std.testing.expect(!a.eql(b));
}
