//! `http.pinnedPubkey` as curl reads it for git (`Curl_pin_peer_pubkey`):
//! the keys a server's own certificate may hold, each as the SHA-256 of a
//! SubjectPublicKeyInfo, which is how uplink's TLS checks a pin.
//!
//! The value is either `sha256//<base64>` hashes with `;sha256//` between
//! them, or a file holding one key. curl compares each hash as text with
//! the base64 of the server key's hash, so an entry that is not exactly
//! one (`;` with something else after it, a short or unpadded one) never
//! matches. A file curl compares as the key's DER when it is the key's
//! length, and as a `PUBLIC KEY` PEM block otherwise; a file it cannot read
//! or longer than a mebibyte matches nothing. The hash of the file's bytes
//! and of the PEM block's key, both kept, match the same keys.

const std = @import("std");
const fs = @import("../fs/fs.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64 = std.base64.standard;

/// Errors from reading the pins.
pub const Error = Allocator.Error || Io.Cancelable;

/// curl's `MAX_PINNED_PUBKEY_SIZE`: a longer file matches nothing.
const max_file = 1 << 20;
const prefix = "sha256//";

/// The pins `value` names, in `arena`: empty when none can match, which
/// curl fails every handshake on.
pub fn read(arena: Allocator, io: Io, value: []const u8) Error![]const [32]u8 {
    if (std.mem.startsWith(u8, value, prefix)) return hashes(arena, value);
    const bytes = fs.readWhole(Io.Dir.cwd(), io, value, arena, .limited(max_file)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var pins: std.ArrayList([32]u8) = .empty;
    try pins.append(arena, digest(bytes));
    if (try pemKey(arena, bytes)) |der| try pins.append(arena, digest(der));
    return pins.items;
}

/// The `sha256//` entries that are a hash's base64 as curl writes it.
fn hashes(arena: Allocator, value: []const u8) Allocator.Error![]const [32]u8 {
    var pins: std.ArrayList([32]u8) = .empty;
    var entries = std.mem.splitSequence(u8, value[prefix.len..], ";" ++ prefix);
    while (entries.next()) |entry| {
        var pin: [32]u8 = undefined;
        if (entry.len != base64.Encoder.calcSize(pin.len)) continue;
        base64.Decoder.decode(&pin, entry) catch continue;
        // Compared as text: only the one spelling of the hash matches.
        var spelled: [base64.Encoder.calcSize(32)]u8 = undefined;
        if (!std.mem.eql(u8, base64.Encoder.encode(&spelled, &pin), entry)) continue;
        try pins.append(arena, pin);
    }
    return pins.items;
}

/// curl's `pubkey_pem_to_der`: the block from a `-----BEGIN PUBLIC KEY-----`
/// at the start of a line to the next `\n-----END PUBLIC KEY-----`, its
/// line breaks dropped and the rest decoded; null where that fails.
fn pemKey(arena: Allocator, file: []const u8) Allocator.Error!?[]const u8 {
    // curl reads the file as a C string.
    const text = file[0 .. std.mem.findScalar(u8, file, 0) orelse file.len];
    const begin = "-----BEGIN PUBLIC KEY-----";
    const start = std.mem.find(u8, text, begin) orelse return null;
    if (start != 0 and text[start - 1] != '\n') return null;
    const body = text[start + begin.len ..];
    const end = std.mem.find(u8, body, "\n-----END PUBLIC KEY-----") orelse return null;
    var encoded: std.ArrayList(u8) = .empty;
    for (body[0..end]) |c| if (c != '\n' and c != '\r') try encoded.append(arena, c);
    const len = base64.Decoder.calcSizeForSlice(encoded.items) catch return null;
    if (len == 0) return null;
    const der = try arena.alloc(u8, len);
    base64.Decoder.decode(der, encoded.items) catch return null;
    return der;
}

fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

const testing = std.testing;

test "sha256// hashes match as curl compares them: each whole entry, the one spelling" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const key = digest("key");
    var spelled: [44]u8 = undefined;
    const one = base64.Encoder.encode(&spelled, &key);
    const Case = struct { []const u8, usize };
    for ([_]Case{
        .{ try std.mem.concat(arena, u8, &.{ prefix, one }), 1 },
        .{ try std.mem.concat(arena, u8, &.{ prefix, "x;", prefix, one }), 1 },
        .{ try std.mem.concat(arena, u8, &.{ prefix, one, ";", prefix, one }), 2 },
        // `;` and anything but `sha256//` stays in the entry.
        .{ try std.mem.concat(arena, u8, &.{ prefix, one, ";x" }), 0 },
        // Unpadded.
        .{ try std.mem.concat(arena, u8, &.{ prefix, one[0..43] }), 0 },
        .{ prefix ++ "AAAA", 0 },
    }) |case| {
        const pins = try read(arena, testing.io, case[0]);
        try testing.expectEqual(case[1], pins.len);
        for (pins) |pin| try testing.expectEqualSlices(u8, &key, &pin);
    }
}

test "a key file is its DER, or the PEM block in it, and an unreadable one matches nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const der = "\x30\x03\x02\x01\x07";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "key.der", .data = der });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "key.pem", .data = "comment\n-----BEGIN PUBLIC KEY-----\nMAMC\r\nAQc=\n-----END PUBLIC KEY-----\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "inline.pem", .data = "x-----BEGIN PUBLIC KEY-----\nMAMCAQc=\n-----END PUBLIC KEY-----\n" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const der_pins = try read(arena, testing.io, try std.Io.Dir.path.join(arena, &.{ base, "key.der" }));
    try testing.expectEqual(@as(usize, 1), der_pins.len);
    try testing.expectEqualSlices(u8, &digest(der), &der_pins[0]);
    const pem_pins = try read(arena, testing.io, try std.Io.Dir.path.join(arena, &.{ base, "key.pem" }));
    try testing.expectEqual(@as(usize, 2), pem_pins.len);
    try testing.expectEqualSlices(u8, &digest(der), &pem_pins[1]);
    // A block not at the start of a line is no PEM key to curl.
    try testing.expectEqual(@as(usize, 1), (try read(arena, testing.io, try std.Io.Dir.path.join(arena, &.{ base, "inline.pem" }))).len);
    try testing.expectEqual(@as(usize, 0), (try read(arena, testing.io, try std.Io.Dir.path.join(arena, &.{ base, "missing" }))).len);
}
