//! The encodings git converts through iconv past UTF-8, ASCII and
//! ISO-8859-1 (designs/relic.md §14): where git behaves the same on every
//! platform, relic matches git; where the platforms' gits differ, the
//! standard decides. Each is an encoding of the WHATWG standard's
//! (xenoglyph's) and, where the iconvs agree on a meaning other than the
//! standard's, a delta. `tools/encodings.zig` measures the delta and writes it into
//! `legacy/tables.zig`.
const std = @import("std");
const xenoglyph = @import("xenoglyph");

/// An encoding as relic reads it: the standard's, and a delta.
pub const Legacy = struct {
    /// The standard's encoding the meaning starts from.
    encoding: xenoglyph.encoding.Encoding,
    /// Sequences read otherwise than the standard reads them, ordered by
    /// length and then by first sequence.
    decode: []const Decode = &.{},
    /// Characters written otherwise, ordered by first character.
    encode: []const Encode = &.{},
    /// Two characters written as one sequence, ordered by the first and then
    /// the second.
    pairs: []const Pair = &.{},
    /// The longest sequence `decode` names.
    longest: u8 = 1,
};

/// The sequences `first` to `last` of `len` bytes each, read as big-endian
/// numbers: refused, or for one sequence, the characters it reads as.
pub const Decode = struct {
    len: u8,
    first: u32,
    last: u32,
    /// How many of `to` the sequence reads as; none for a refusal.
    count: u8 = 0,
    to: [2]u21 = .{ 0, 0 },
};

/// The characters `first` to `last`: refused, or for one character, the
/// bytes it is written as.
pub const Encode = struct {
    first: u21,
    last: u21,
    /// How many of `bytes` the character is written as; none for a refusal.
    len: u8 = 0,
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
};

/// `first` followed by `second`, written as one sequence, or refused.
pub const Pair = struct {
    first: u21,
    second: u21,
    len: u8 = 0,
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
};

/// The characters the sequence at `src[i.*..]` reads as, into `out`, and
/// how many; `i` moves past the sequence. `null` for bytes that begin no
/// sequence the encoding has.
pub fn decodeAt(l: *const Legacy, src: []const u8, i: *usize, out: *[2]u21) ?u8 {
    const rest = src[i.*..];
    var n: usize = @min(l.longest, rest.len);
    while (n > 0) : (n -= 1) {
        const d = findDecode(l.decode, n, std.mem.readVarInt(u32, rest[0..n], .big)) orelse continue;
        if (d.count == 0) return null;
        out.* = d.to;
        i.* += n;
        return d.count;
    }
    return standardAt(l.encoding, rest, i, out);
}

/// The bytes `cps[i.*]` is written as, or it and the character after it
/// where the two are one sequence, into `out`, and how many; `i` moves past
/// the characters. `null` for a character the encoding does not have.
pub fn encodeAt(l: *const Legacy, cps: []const u21, i: *usize, out: *[4]u8) ?u8 {
    const cp = cps[i.*];
    if (i.* + 1 < cps.len) if (findPair(l.pairs, cp, cps[i.* + 1])) |p| {
        if (p.len == 0) return null;
        out.* = p.bytes;
        i.* += 2;
        return p.len;
    };
    if (findEncode(l.encode, cp)) |e| {
        if (e.len == 0) return null;
        out.* = e.bytes;
        i.* += 1;
        return e.len;
    }
    // The standard's bytes, where they read back as the character: a
    // character the standard writes as bytes relic reads otherwise is one
    // it does not write so.
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &utf8) catch return null;
    var w: std.Io.Writer = .fixed(out);
    xenoglyph.encoding.encode(l.encoding, utf8[0..n], &w, .{ .mode = .fatal }) catch return null;
    const bytes = w.buffered();
    var at: usize = 0;
    var back: [2]u21 = undefined;
    const count = decodeAt(l, bytes, &at, &back) orelse return null;
    if (count != 1 or back[0] != cp or at != bytes.len) return null;
    i.* += 1;
    return @intCast(bytes.len); // the writer is `out`, four bytes
}

/// The standard's reading of the sequence `rest` begins with: its decoder
/// is given a byte at a time until it writes the sequence's characters.
fn standardAt(e: xenoglyph.encoding.Encoding, rest: []const u8, i: *usize, out: *[2]u21) ?u8 {
    var d: xenoglyph.encoding.Decoder = .init(e, .{ .mode = .fatal, .bom = .none });
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (0..rest.len) |k| {
        d.decode(rest[k .. k + 1], false, &w) catch return null;
        const written = w.buffered();
        if (written.len == 0) continue;
        var count: u8 = 0;
        var view = std.unicode.Utf8View.init(written) catch return null;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (count == out.len) return null;
            out[count] = cp;
            count += 1;
        }
        i.* += k + 1;
        return count;
    }
    return null;
}

fn findDecode(entries: []const Decode, len: usize, key: u32) ?*const Decode {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const d = &entries[mid];
        if (d.len < len or (d.len == len and d.last < key)) {
            lo = mid + 1;
        } else if (d.len > len or d.first > key) {
            hi = mid;
        } else return d;
    }
    return null;
}

fn findEncode(entries: []const Encode, cp: u21) ?*const Encode {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = &entries[mid];
        if (e.last < cp) {
            lo = mid + 1;
        } else if (e.first > cp) {
            hi = mid;
        } else return e;
    }
    return null;
}

fn findPair(entries: []const Pair, first: u21, second: u21) ?*const Pair {
    for (entries) |*p| if (p.first == first and p.second == second) return p;
    return null;
}
