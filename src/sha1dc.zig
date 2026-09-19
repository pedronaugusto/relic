//! SHA-1 that notices it is being attacked.
//!
//! A SHA-1 collision is public and buildable, which means two different
//! objects can be made to carry one name. The counter-measure is not a
//! different hash — the repository's format decides that — but a check run
//! while hashing: the identical-prefix attacks all follow one of a known set
//! of disturbance vectors, and a block that could have come from such a pair
//! can be recognised from the block alone.
//!
//! Per block: the expanded message is tested against the unavoidable bit
//! conditions of thirty-two vectors, which is a few dozen masked comparisons
//! and rejects nearly everything. For a vector that survives, the sibling
//! message is reconstructed, the compression function is re-run from the step
//! the vector is anchored at, and a match means the block is one half of a
//! near-collision. Anything a repository actually holds fails the first test.
//!
//! This is off by default, costs what the `Speed` section of the README
//! measures, and reports rather than repairs: a caller that turns it on gets
//! a named error and not a quietly different name. It also cannot use the
//! processor's SHA-1 instructions, because the method needs the expanded
//! message and the intermediate states that those instructions do not hand
//! back.
//!
//! The disturbance-vector table and the bit conditions below are transcribed
//! from the reference implementation of
//! *Counter-cryptanalysis* (Marc Stevens, CRYPTO 2013) and
//! *The first collision for full SHA-1* (Stevens, Bursztein, Karpman,
//! Albertini, Markov, CRYPTO 2017):
//!
//!   Copyright 2017 Marc Stevens <marc@marc-stevens.nl>,
//!   Dan Shumow <danshu@microsoft.com>. Distributed under the MIT Software
//!   License, https://opensource.org/licenses/MIT
//!
//! The transcription is checked two ways: the published colliding pair is
//! detected, and no object any of the fixture repositories holds is.

const std = @import("std");

/// SHA-1, with the collision check run on every block.
///
/// The digest is SHA-1's digest — the check does not change a single byte of
/// it — and `foundCollision` says whether any block looked like half of a
/// near-collision pair. A caller that asked for the check is expected to read
/// that and refuse, which is what `odb` does.
pub const Sha1Dc = struct {
    /// The compression function's input width, in bytes.
    pub const block_length = 64;
    /// The digest's width, in bytes, which is SHA-1's.
    pub const digest_length = 20;
    /// No parameters, for the same reason `sha1.Sha1` has none.
    pub const Options = struct {};

    ihv: [5]u32,
    buf: [block_length]u8,
    buf_len: u8,
    total_len: u64,
    found: bool,

    /// A hasher with nothing fed to it yet, and nothing found.
    pub fn init(options: Options) Sha1Dc {
        _ = options;
        return .{
            .ihv = .{ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
            .found = false,
        };
    }

    /// Feed bytes.
    pub fn update(d: *Sha1Dc, bytes: []const u8) void {
        var rest = bytes;
        d.total_len +%= bytes.len;

        if (d.buf_len != 0) {
            const take = @min(block_length - d.buf_len, rest.len);
            @memcpy(d.buf[d.buf_len..][0..take], rest[0..take]);
            d.buf_len += @intCast(take);
            rest = rest[take..];
            if (d.buf_len < block_length) return;
            d.process(&d.buf);
            d.buf_len = 0;
        }

        while (rest.len >= block_length) {
            d.process(rest[0..block_length]);
            rest = rest[block_length..];
        }

        if (rest.len != 0) {
            @memcpy(d.buf[0..rest.len], rest);
            d.buf_len = @intCast(rest.len);
        }
    }

    /// The digest. The hasher must not be used afterwards; `foundCollision`
    /// may still be read.
    pub fn final(d: *Sha1Dc, out: *[digest_length]u8) void {
        const bit_len = d.total_len *% 8;
        d.buf[d.buf_len] = 0x80;
        d.buf_len += 1;
        if (d.buf_len > block_length - 8) {
            @memset(d.buf[d.buf_len..], 0);
            d.process(&d.buf);
            d.buf_len = 0;
        }
        @memset(d.buf[d.buf_len .. block_length - 8], 0);
        std.mem.writeInt(u64, d.buf[block_length - 8 ..][0..8], bit_len, .big);
        d.process(&d.buf);
        for (d.ihv, 0..) |word, i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .big);
        }
    }

    /// Whether any block fed to this hasher was half of a near-collision
    /// pair. Meaningful at any point, and final once `final` has run.
    pub fn foundCollision(d: *const Sha1Dc) bool {
        return d.found;
    }

    /// The digest of `bytes` in one call, and whether it was attacked.
    pub fn hash(bytes: []const u8, out: *[digest_length]u8, options: Options) bool {
        var d: Sha1Dc = .init(options);
        d.update(bytes);
        d.final(out);
        return d.found;
    }

    /// One block: the compression function, and then the check.
    fn process(d: *Sha1Dc, block: *const [block_length]u8) void {
        var w: [80]u32 = undefined;
        var states: [2][5]u32 = undefined;
        compressionStates(&d.ihv, block, &w, &states);

        const mask = ubcCheck(&w);
        if (mask == 0) return;

        for (dvs) |dv| {
            if (mask & (@as(u32, 1) << dv.mask_bit) == 0) continue;

            var m2: [80]u32 = undefined;
            for (&m2, w, dv.dm) |*out, word, difference| out.* = word ^ difference;

            var ihvin: [5]u32 = undefined;
            var ihvout: [5]u32 = undefined;
            const state = &states[if (dv.test_t == 58) @as(usize, 0) else 1];
            recompress(dv.test_t, &ihvin, &ihvout, &m2, state);

            // The sibling message recompresses to the chaining value this
            // block just produced, which no unrelated message does.
            if (std.mem.eql(u32, &ihvout, &d.ihv)) {
                d.found = true;
                return;
            }
        }
    }
};

/// The rounds, keeping the expanded message and the two intermediate states
/// the recompression is anchored at.
///
/// The two steps are 58 and 65, which is where the published vectors are
/// anchored; a table entry naming any other step would be a state this does
/// not keep, and the assertion below says so rather than reading past the end.
fn compressionStates(
    ihv: *[5]u32,
    block: *const [64]u8,
    w: *[80]u32,
    states: *[2][5]u32,
) void {
    for (0..16) |i| w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .big);
    for (16..80) |i| {
        w[i] = std.math.rotl(u32, w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    var v: [5]u32 = ihv.*;
    // Unrolled, so that the word each step names and the round constant it
    // uses are settled at compile time rather than computed eighty times a
    // block. This is the loop every byte of every object goes through when
    // the check is on.
    inline for (0..80) |t| {
        if (t == 58) states[0] = v;
        if (t == 65) states[1] = v;
        step(&v, t, w[t]);
    }
    for (ihv, v) |*word, done| word.* +%= done;
}

/// The chaining value the sibling message must have started from, and the one
/// it ends at.
///
/// Backwards from `t` to the start gives the input; forwards from `t` to the
/// end gives the output, and the two are added the way the compression
/// function adds them.
fn recompress(
    t: u8,
    ihvin: *[5]u32,
    ihvout: *[5]u32,
    me2: *const [80]u32,
    state: *const [5]u32,
) void {
    var v: [5]u32 = state.*;
    var i: usize = t;
    while (i > 0) {
        i -= 1;
        stepBack(&v, i, me2[i]);
    }
    ihvin.* = v;

    v = state.*;
    i = t;
    while (i < 80) : (i += 1) step(&v, i, me2[i]);
    for (ihvout, ihvin, v) |*out, in, done| out.* = in +% done;
}

/// Where `a` sits in the five words at step `t`.
///
/// The rounds are written without moving the five words about, so each step
/// names them one place further round the cycle than the last.
inline fn slot(t: usize, offset: usize) usize {
    return ((5 - t % 5) + offset) % 5;
}

inline fn roundConstant(t: usize) u32 {
    return switch (t / 20) {
        0 => 0x5A827999,
        1 => 0x6ED9EBA1,
        2 => 0x8F1BBCDC,
        else => 0xCA62C1D6,
    };
}

inline fn roundFunction(t: usize, b: u32, c: u32, d: u32) u32 {
    return switch (t / 20) {
        0 => d ^ (b & (c ^ d)),
        1 => b ^ c ^ d,
        2 => (b & c) +% (d & (b ^ c)),
        else => b ^ c ^ d,
    };
}

inline fn step(v: *[5]u32, t: usize, wt: u32) void {
    const ai = slot(t, 0);
    const bi = slot(t, 1);
    const ci = slot(t, 2);
    const di = slot(t, 3);
    const ei = slot(t, 4);
    v[ei] = v[ei] +% std.math.rotl(u32, v[ai], 5) +%
        roundFunction(t, v[bi], v[ci], v[di]) +% roundConstant(t) +% wt;
    v[bi] = std.math.rotl(u32, v[bi], 30);
}

inline fn stepBack(v: *[5]u32, t: usize, wt: u32) void {
    const ai = slot(t, 0);
    const bi = slot(t, 1);
    const ci = slot(t, 2);
    const di = slot(t, 3);
    const ei = slot(t, 4);
    v[bi] = std.math.rotr(u32, v[bi], 30);
    v[ei] = v[ei] -% (std.math.rotl(u32, v[ai], 5) +%
        roundFunction(t, v[bi], v[ci], v[di]) +% roundConstant(t) +% wt);
}

/// One bit per disturbance vector, named as the published table names it
/// so that a line here can be read against the line it came from.
const DV_I_43_0_bit: u32 = 1 << 0;
const DV_I_44_0_bit: u32 = 1 << 1;
const DV_I_45_0_bit: u32 = 1 << 2;
const DV_I_46_0_bit: u32 = 1 << 3;
const DV_I_46_2_bit: u32 = 1 << 4;
const DV_I_47_0_bit: u32 = 1 << 5;
const DV_I_47_2_bit: u32 = 1 << 6;
const DV_I_48_0_bit: u32 = 1 << 7;
const DV_I_48_2_bit: u32 = 1 << 8;
const DV_I_49_0_bit: u32 = 1 << 9;
const DV_I_49_2_bit: u32 = 1 << 10;
const DV_I_50_0_bit: u32 = 1 << 11;
const DV_I_50_2_bit: u32 = 1 << 12;
const DV_I_51_0_bit: u32 = 1 << 13;
const DV_I_51_2_bit: u32 = 1 << 14;
const DV_I_52_0_bit: u32 = 1 << 15;
const DV_II_45_0_bit: u32 = 1 << 16;
const DV_II_46_0_bit: u32 = 1 << 17;
const DV_II_46_2_bit: u32 = 1 << 18;
const DV_II_47_0_bit: u32 = 1 << 19;
const DV_II_48_0_bit: u32 = 1 << 20;
const DV_II_49_0_bit: u32 = 1 << 21;
const DV_II_49_2_bit: u32 = 1 << 22;
const DV_II_50_0_bit: u32 = 1 << 23;
const DV_II_50_2_bit: u32 = 1 << 24;
const DV_II_51_0_bit: u32 = 1 << 25;
const DV_II_51_2_bit: u32 = 1 << 26;
const DV_II_52_0_bit: u32 = 1 << 27;
const DV_II_53_0_bit: u32 = 1 << 28;
const DV_II_54_0_bit: u32 = 1 << 29;
const DV_II_55_0_bit: u32 = 1 << 30;
const DV_II_56_0_bit: u32 = 1 << 31;

/// Which disturbance vectors this expanded message block meets every
/// unavoidable bit condition for.
///
/// A set bit means the recompression check below has to be run for that
/// vector; a clear bit means no message pair following that vector can have
/// produced this block, so the check would be wasted. The conditions
/// themselves are the published ones, transcribed.
fn ubcCheck(W: *const [80]u32) u32 {
    var mask: u32 = ~@as(u32, 0);
    mask &= (((((W[44] ^ W[45]) >> 29) & 1) -% 1) | ~(DV_I_48_0_bit | DV_I_51_0_bit | DV_I_52_0_bit | DV_II_45_0_bit | DV_II_46_0_bit | DV_II_50_0_bit | DV_II_51_0_bit));
    mask &= (((((W[49] ^ W[50]) >> 29) & 1) -% 1) | ~(DV_I_46_0_bit | DV_II_45_0_bit | DV_II_50_0_bit | DV_II_51_0_bit | DV_II_55_0_bit | DV_II_56_0_bit));
    mask &= (((((W[48] ^ W[49]) >> 29) & 1) -% 1) | ~(DV_I_45_0_bit | DV_I_52_0_bit | DV_II_49_0_bit | DV_II_50_0_bit | DV_II_54_0_bit | DV_II_55_0_bit));
    mask &= ((((W[47] ^ (W[50] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_47_0_bit | DV_I_49_0_bit | DV_I_51_0_bit | DV_II_45_0_bit | DV_II_51_0_bit | DV_II_56_0_bit));
    mask &= (((((W[47] ^ W[48]) >> 29) & 1) -% 1) | ~(DV_I_44_0_bit | DV_I_51_0_bit | DV_II_48_0_bit | DV_II_49_0_bit | DV_II_53_0_bit | DV_II_54_0_bit));
    mask &= (((((W[46] >> 4) ^ (W[49] >> 29)) & 1) -% 1) | ~(DV_I_46_0_bit | DV_I_48_0_bit | DV_I_50_0_bit | DV_I_52_0_bit | DV_II_50_0_bit | DV_II_55_0_bit));
    mask &= (((((W[46] ^ W[47]) >> 29) & 1) -% 1) | ~(DV_I_43_0_bit | DV_I_50_0_bit | DV_II_47_0_bit | DV_II_48_0_bit | DV_II_52_0_bit | DV_II_53_0_bit));
    mask &= (((((W[45] >> 4) ^ (W[48] >> 29)) & 1) -% 1) | ~(DV_I_45_0_bit | DV_I_47_0_bit | DV_I_49_0_bit | DV_I_51_0_bit | DV_II_49_0_bit | DV_II_54_0_bit));
    mask &= (((((W[45] ^ W[46]) >> 29) & 1) -% 1) | ~(DV_I_49_0_bit | DV_I_52_0_bit | DV_II_46_0_bit | DV_II_47_0_bit | DV_II_51_0_bit | DV_II_52_0_bit));
    mask &= (((((W[44] >> 4) ^ (W[47] >> 29)) & 1) -% 1) | ~(DV_I_44_0_bit | DV_I_46_0_bit | DV_I_48_0_bit | DV_I_50_0_bit | DV_II_48_0_bit | DV_II_53_0_bit));
    mask &= (((((W[43] >> 4) ^ (W[46] >> 29)) & 1) -% 1) | ~(DV_I_43_0_bit | DV_I_45_0_bit | DV_I_47_0_bit | DV_I_49_0_bit | DV_II_47_0_bit | DV_II_52_0_bit));
    mask &= (((((W[43] ^ W[44]) >> 29) & 1) -% 1) | ~(DV_I_47_0_bit | DV_I_50_0_bit | DV_I_51_0_bit | DV_II_45_0_bit | DV_II_49_0_bit | DV_II_50_0_bit));
    mask &= (((((W[42] >> 4) ^ (W[45] >> 29)) & 1) -% 1) | ~(DV_I_44_0_bit | DV_I_46_0_bit | DV_I_48_0_bit | DV_I_52_0_bit | DV_II_46_0_bit | DV_II_51_0_bit));
    mask &= (((((W[41] >> 4) ^ (W[44] >> 29)) & 1) -% 1) | ~(DV_I_43_0_bit | DV_I_45_0_bit | DV_I_47_0_bit | DV_I_51_0_bit | DV_II_45_0_bit | DV_II_50_0_bit));
    mask &= (((((W[40] ^ W[41]) >> 29) & 1) -% 1) | ~(DV_I_44_0_bit | DV_I_47_0_bit | DV_I_48_0_bit | DV_II_46_0_bit | DV_II_47_0_bit | DV_II_56_0_bit));
    mask &= (((((W[54] ^ W[55]) >> 29) & 1) -% 1) | ~(DV_I_51_0_bit | DV_II_47_0_bit | DV_II_50_0_bit | DV_II_55_0_bit | DV_II_56_0_bit));
    mask &= (((((W[53] ^ W[54]) >> 29) & 1) -% 1) | ~(DV_I_50_0_bit | DV_II_46_0_bit | DV_II_49_0_bit | DV_II_54_0_bit | DV_II_55_0_bit));
    mask &= (((((W[52] ^ W[53]) >> 29) & 1) -% 1) | ~(DV_I_49_0_bit | DV_II_45_0_bit | DV_II_48_0_bit | DV_II_53_0_bit | DV_II_54_0_bit));
    mask &= ((((W[50] ^ (W[53] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_50_0_bit | DV_I_52_0_bit | DV_II_46_0_bit | DV_II_48_0_bit | DV_II_54_0_bit));
    mask &= (((((W[50] ^ W[51]) >> 29) & 1) -% 1) | ~(DV_I_47_0_bit | DV_II_46_0_bit | DV_II_51_0_bit | DV_II_52_0_bit | DV_II_56_0_bit));
    mask &= ((((W[49] ^ (W[52] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_49_0_bit | DV_I_51_0_bit | DV_II_45_0_bit | DV_II_47_0_bit | DV_II_53_0_bit));
    mask &= ((((W[48] ^ (W[51] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_48_0_bit | DV_I_50_0_bit | DV_I_52_0_bit | DV_II_46_0_bit | DV_II_52_0_bit));
    mask &= (((((W[42] ^ W[43]) >> 29) & 1) -% 1) | ~(DV_I_46_0_bit | DV_I_49_0_bit | DV_I_50_0_bit | DV_II_48_0_bit | DV_II_49_0_bit));
    mask &= (((((W[41] ^ W[42]) >> 29) & 1) -% 1) | ~(DV_I_45_0_bit | DV_I_48_0_bit | DV_I_49_0_bit | DV_II_47_0_bit | DV_II_48_0_bit));
    mask &= (((((W[40] >> 4) ^ (W[43] >> 29)) & 1) -% 1) | ~(DV_I_44_0_bit | DV_I_46_0_bit | DV_I_50_0_bit | DV_II_49_0_bit | DV_II_56_0_bit));
    mask &= (((((W[39] >> 4) ^ (W[42] >> 29)) & 1) -% 1) | ~(DV_I_43_0_bit | DV_I_45_0_bit | DV_I_49_0_bit | DV_II_48_0_bit | DV_II_55_0_bit));
    if ((mask & (DV_I_44_0_bit | DV_I_48_0_bit | DV_II_47_0_bit | DV_II_54_0_bit | DV_II_56_0_bit)) != 0) mask &= (((((W[38] >> 4) ^ (W[41] >> 29)) & 1) -% 1) | ~(DV_I_44_0_bit | DV_I_48_0_bit | DV_II_47_0_bit | DV_II_54_0_bit | DV_II_56_0_bit));
    mask &= (((((W[37] >> 4) ^ (W[40] >> 29)) & 1) -% 1) | ~(DV_I_43_0_bit | DV_I_47_0_bit | DV_II_46_0_bit | DV_II_53_0_bit | DV_II_55_0_bit));
    if ((mask & (DV_I_52_0_bit | DV_II_48_0_bit | DV_II_51_0_bit | DV_II_56_0_bit)) != 0) mask &= (((((W[55] ^ W[56]) >> 29) & 1) -% 1) | ~(DV_I_52_0_bit | DV_II_48_0_bit | DV_II_51_0_bit | DV_II_56_0_bit));
    if ((mask & (DV_I_52_0_bit | DV_II_48_0_bit | DV_II_50_0_bit | DV_II_56_0_bit)) != 0) mask &= ((((W[52] ^ (W[55] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_52_0_bit | DV_II_48_0_bit | DV_II_50_0_bit | DV_II_56_0_bit));
    if ((mask & (DV_I_51_0_bit | DV_II_47_0_bit | DV_II_49_0_bit | DV_II_55_0_bit)) != 0) mask &= ((((W[51] ^ (W[54] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_51_0_bit | DV_II_47_0_bit | DV_II_49_0_bit | DV_II_55_0_bit));
    if ((mask & (DV_I_48_0_bit | DV_II_47_0_bit | DV_II_52_0_bit | DV_II_53_0_bit)) != 0) mask &= (((((W[51] ^ W[52]) >> 29) & 1) -% 1) | ~(DV_I_48_0_bit | DV_II_47_0_bit | DV_II_52_0_bit | DV_II_53_0_bit));
    if ((mask & (DV_I_46_0_bit | DV_I_49_0_bit | DV_II_45_0_bit | DV_II_48_0_bit)) != 0) mask &= (((((W[36] >> 4) ^ (W[40] >> 29)) & 1) -% 1) | ~(DV_I_46_0_bit | DV_I_49_0_bit | DV_II_45_0_bit | DV_II_48_0_bit));
    if ((mask & (DV_I_52_0_bit | DV_II_48_0_bit | DV_II_49_0_bit)) != 0) mask &= ((0 -% (((W[53] ^ W[56]) >> 29) & 1)) | ~(DV_I_52_0_bit | DV_II_48_0_bit | DV_II_49_0_bit));
    if ((mask & (DV_I_50_0_bit | DV_II_46_0_bit | DV_II_47_0_bit)) != 0) mask &= ((0 -% (((W[51] ^ W[54]) >> 29) & 1)) | ~(DV_I_50_0_bit | DV_II_46_0_bit | DV_II_47_0_bit));
    if ((mask & (DV_I_49_0_bit | DV_I_51_0_bit | DV_II_45_0_bit)) != 0) mask &= ((0 -% (((W[50] ^ W[52]) >> 29) & 1)) | ~(DV_I_49_0_bit | DV_I_51_0_bit | DV_II_45_0_bit));
    if ((mask & (DV_I_48_0_bit | DV_I_50_0_bit | DV_I_52_0_bit)) != 0) mask &= ((0 -% (((W[49] ^ W[51]) >> 29) & 1)) | ~(DV_I_48_0_bit | DV_I_50_0_bit | DV_I_52_0_bit));
    if ((mask & (DV_I_47_0_bit | DV_I_49_0_bit | DV_I_51_0_bit)) != 0) mask &= ((0 -% (((W[48] ^ W[50]) >> 29) & 1)) | ~(DV_I_47_0_bit | DV_I_49_0_bit | DV_I_51_0_bit));
    if ((mask & (DV_I_46_0_bit | DV_I_48_0_bit | DV_I_50_0_bit)) != 0) mask &= ((0 -% (((W[47] ^ W[49]) >> 29) & 1)) | ~(DV_I_46_0_bit | DV_I_48_0_bit | DV_I_50_0_bit));
    if ((mask & (DV_I_45_0_bit | DV_I_47_0_bit | DV_I_49_0_bit)) != 0) mask &= ((0 -% (((W[46] ^ W[48]) >> 29) & 1)) | ~(DV_I_45_0_bit | DV_I_47_0_bit | DV_I_49_0_bit));
    mask &= ((((W[45] ^ W[47]) & (1 << 6)) -% (1 << 6)) | ~(DV_I_47_2_bit | DV_I_49_2_bit | DV_I_51_2_bit));
    if ((mask & (DV_I_44_0_bit | DV_I_46_0_bit | DV_I_48_0_bit)) != 0) mask &= ((0 -% (((W[45] ^ W[47]) >> 29) & 1)) | ~(DV_I_44_0_bit | DV_I_46_0_bit | DV_I_48_0_bit));
    mask &= (((((W[44] ^ W[46]) >> 6) & 1) -% 1) | ~(DV_I_46_2_bit | DV_I_48_2_bit | DV_I_50_2_bit));
    if ((mask & (DV_I_43_0_bit | DV_I_45_0_bit | DV_I_47_0_bit)) != 0) mask &= ((0 -% (((W[44] ^ W[46]) >> 29) & 1)) | ~(DV_I_43_0_bit | DV_I_45_0_bit | DV_I_47_0_bit));
    mask &= ((0 -% ((W[41] ^ (W[42] >> 5)) & (1 << 1))) | ~(DV_I_48_2_bit | DV_II_46_2_bit | DV_II_51_2_bit));
    mask &= ((0 -% ((W[40] ^ (W[41] >> 5)) & (1 << 1))) | ~(DV_I_47_2_bit | DV_I_51_2_bit | DV_II_50_2_bit));
    if ((mask & (DV_I_44_0_bit | DV_I_46_0_bit | DV_II_56_0_bit)) != 0) mask &= ((0 -% (((W[40] ^ W[42]) >> 4) & 1)) | ~(DV_I_44_0_bit | DV_I_46_0_bit | DV_II_56_0_bit));
    mask &= ((0 -% ((W[39] ^ (W[40] >> 5)) & (1 << 1))) | ~(DV_I_46_2_bit | DV_I_50_2_bit | DV_II_49_2_bit));
    if ((mask & (DV_I_43_0_bit | DV_I_45_0_bit | DV_II_55_0_bit)) != 0) mask &= ((0 -% (((W[39] ^ W[41]) >> 4) & 1)) | ~(DV_I_43_0_bit | DV_I_45_0_bit | DV_II_55_0_bit));
    if ((mask & (DV_I_44_0_bit | DV_II_54_0_bit | DV_II_56_0_bit)) != 0) mask &= ((0 -% (((W[38] ^ W[40]) >> 4) & 1)) | ~(DV_I_44_0_bit | DV_II_54_0_bit | DV_II_56_0_bit));
    if ((mask & (DV_I_43_0_bit | DV_II_53_0_bit | DV_II_55_0_bit)) != 0) mask &= ((0 -% (((W[37] ^ W[39]) >> 4) & 1)) | ~(DV_I_43_0_bit | DV_II_53_0_bit | DV_II_55_0_bit));
    mask &= ((0 -% ((W[36] ^ (W[37] >> 5)) & (1 << 1))) | ~(DV_I_47_2_bit | DV_I_50_2_bit | DV_II_46_2_bit));
    if ((mask & (DV_I_45_0_bit | DV_I_48_0_bit | DV_II_47_0_bit)) != 0) mask &= (((((W[35] >> 4) ^ (W[39] >> 29)) & 1) -% 1) | ~(DV_I_45_0_bit | DV_I_48_0_bit | DV_II_47_0_bit));
    if ((mask & (DV_I_48_0_bit | DV_II_48_0_bit)) != 0) mask &= ((0 -% ((W[63] ^ (W[64] >> 5)) & (1 << 0))) | ~(DV_I_48_0_bit | DV_II_48_0_bit));
    if ((mask & (DV_I_45_0_bit | DV_II_45_0_bit)) != 0) mask &= ((0 -% ((W[63] ^ (W[64] >> 5)) & (1 << 1))) | ~(DV_I_45_0_bit | DV_II_45_0_bit));
    if ((mask & (DV_I_47_0_bit | DV_II_47_0_bit)) != 0) mask &= ((0 -% ((W[62] ^ (W[63] >> 5)) & (1 << 0))) | ~(DV_I_47_0_bit | DV_II_47_0_bit));
    if ((mask & (DV_I_46_0_bit | DV_II_46_0_bit)) != 0) mask &= ((0 -% ((W[61] ^ (W[62] >> 5)) & (1 << 0))) | ~(DV_I_46_0_bit | DV_II_46_0_bit));
    mask &= ((0 -% ((W[61] ^ (W[62] >> 5)) & (1 << 2))) | ~(DV_I_46_2_bit | DV_II_46_2_bit));
    if ((mask & (DV_I_45_0_bit | DV_II_45_0_bit)) != 0) mask &= ((0 -% ((W[60] ^ (W[61] >> 5)) & (1 << 0))) | ~(DV_I_45_0_bit | DV_II_45_0_bit));
    if ((mask & (DV_II_51_0_bit | DV_II_54_0_bit)) != 0) mask &= (((((W[58] ^ W[59]) >> 29) & 1) -% 1) | ~(DV_II_51_0_bit | DV_II_54_0_bit));
    if ((mask & (DV_II_50_0_bit | DV_II_53_0_bit)) != 0) mask &= (((((W[57] ^ W[58]) >> 29) & 1) -% 1) | ~(DV_II_50_0_bit | DV_II_53_0_bit));
    if ((mask & (DV_II_52_0_bit | DV_II_54_0_bit)) != 0) mask &= ((((W[56] ^ (W[59] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_II_52_0_bit | DV_II_54_0_bit));
    if ((mask & (DV_II_51_0_bit | DV_II_52_0_bit)) != 0) mask &= ((0 -% (((W[56] ^ W[59]) >> 29) & 1)) | ~(DV_II_51_0_bit | DV_II_52_0_bit));
    if ((mask & (DV_II_49_0_bit | DV_II_52_0_bit)) != 0) mask &= (((((W[56] ^ W[57]) >> 29) & 1) -% 1) | ~(DV_II_49_0_bit | DV_II_52_0_bit));
    if ((mask & (DV_II_51_0_bit | DV_II_53_0_bit)) != 0) mask &= ((((W[55] ^ (W[58] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_II_51_0_bit | DV_II_53_0_bit));
    if ((mask & (DV_II_50_0_bit | DV_II_52_0_bit)) != 0) mask &= ((((W[54] ^ (W[57] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_II_50_0_bit | DV_II_52_0_bit));
    if ((mask & (DV_II_49_0_bit | DV_II_51_0_bit)) != 0) mask &= ((((W[53] ^ (W[56] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_II_49_0_bit | DV_II_51_0_bit));
    mask &= ((((W[51] ^ (W[50] >> 5)) & (1 << 1)) -% (1 << 1)) | ~(DV_I_50_2_bit | DV_II_46_2_bit));
    mask &= ((((W[48] ^ W[50]) & (1 << 6)) -% (1 << 6)) | ~(DV_I_50_2_bit | DV_II_46_2_bit));
    if ((mask & (DV_I_51_0_bit | DV_I_52_0_bit)) != 0) mask &= ((0 -% (((W[48] ^ W[55]) >> 29) & 1)) | ~(DV_I_51_0_bit | DV_I_52_0_bit));
    mask &= ((((W[47] ^ W[49]) & (1 << 6)) -% (1 << 6)) | ~(DV_I_49_2_bit | DV_I_51_2_bit));
    mask &= ((((W[48] ^ (W[47] >> 5)) & (1 << 1)) -% (1 << 1)) | ~(DV_I_47_2_bit | DV_II_51_2_bit));
    mask &= ((((W[46] ^ W[48]) & (1 << 6)) -% (1 << 6)) | ~(DV_I_48_2_bit | DV_I_50_2_bit));
    mask &= ((((W[47] ^ (W[46] >> 5)) & (1 << 1)) -% (1 << 1)) | ~(DV_I_46_2_bit | DV_II_50_2_bit));
    mask &= ((0 -% ((W[44] ^ (W[45] >> 5)) & (1 << 1))) | ~(DV_I_51_2_bit | DV_II_49_2_bit));
    mask &= ((((W[43] ^ W[45]) & (1 << 6)) -% (1 << 6)) | ~(DV_I_47_2_bit | DV_I_49_2_bit));
    mask &= (((((W[42] ^ W[44]) >> 6) & 1) -% 1) | ~(DV_I_46_2_bit | DV_I_48_2_bit));
    mask &= ((((W[43] ^ (W[42] >> 5)) & (1 << 1)) -% (1 << 1)) | ~(DV_II_46_2_bit | DV_II_51_2_bit));
    mask &= ((((W[42] ^ (W[41] >> 5)) & (1 << 1)) -% (1 << 1)) | ~(DV_I_51_2_bit | DV_II_50_2_bit));
    mask &= ((((W[41] ^ (W[40] >> 5)) & (1 << 1)) -% (1 << 1)) | ~(DV_I_50_2_bit | DV_II_49_2_bit));
    if ((mask & (DV_I_52_0_bit | DV_II_51_0_bit)) != 0) mask &= ((((W[39] ^ (W[43] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_52_0_bit | DV_II_51_0_bit));
    if ((mask & (DV_I_51_0_bit | DV_II_50_0_bit)) != 0) mask &= ((((W[38] ^ (W[42] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_51_0_bit | DV_II_50_0_bit));
    if ((mask & (DV_I_48_2_bit | DV_I_51_2_bit)) != 0) mask &= ((0 -% ((W[37] ^ (W[38] >> 5)) & (1 << 1))) | ~(DV_I_48_2_bit | DV_I_51_2_bit));
    if ((mask & (DV_I_50_0_bit | DV_II_49_0_bit)) != 0) mask &= ((((W[37] ^ (W[41] >> 25)) & (1 << 4)) -% (1 << 4)) | ~(DV_I_50_0_bit | DV_II_49_0_bit));
    if ((mask & (DV_II_52_0_bit | DV_II_54_0_bit)) != 0) mask &= ((0 -% ((W[36] ^ W[38]) & (1 << 4))) | ~(DV_II_52_0_bit | DV_II_54_0_bit));
    mask &= ((0 -% ((W[35] ^ (W[36] >> 5)) & (1 << 1))) | ~(DV_I_46_2_bit | DV_I_49_2_bit));
    if ((mask & (DV_I_51_0_bit | DV_II_47_0_bit)) != 0) mask &= ((((W[35] ^ (W[39] >> 25)) & (1 << 3)) -% (1 << 3)) | ~(DV_I_51_0_bit | DV_II_47_0_bit));
    if (mask != 0) {
        if ((mask & DV_I_43_0_bit) != 0) {
            if ((((W[61] ^ (W[62] >> 5)) & (1 << 1)) == 0) or (((W[59] ^ (W[63] >> 25)) & (1 << 5)) != 0) or (((W[58] ^ (W[63] >> 30)) & (1 << 0)) == 0)) mask &= ~DV_I_43_0_bit;
        }
        if ((mask & DV_I_44_0_bit) != 0) {
            if ((((W[62] ^ (W[63] >> 5)) & (1 << 1)) == 0) or (((W[60] ^ (W[64] >> 25)) & (1 << 5)) != 0) or (((W[59] ^ (W[64] >> 30)) & (1 << 0)) == 0)) mask &= ~DV_I_44_0_bit;
        }
        if ((mask & DV_I_46_2_bit) != 0) mask &= ((~((W[40] ^ W[42]) >> 2)) | ~DV_I_46_2_bit);
        if ((mask & DV_I_47_2_bit) != 0) {
            if ((((W[62] ^ (W[63] >> 5)) & (1 << 2)) == 0) or (((W[41] ^ W[43]) & (1 << 6)) != 0)) mask &= ~DV_I_47_2_bit;
        }
        if ((mask & DV_I_48_2_bit) != 0) {
            if ((((W[63] ^ (W[64] >> 5)) & (1 << 2)) == 0) or (((W[48] ^ (W[49] << 5)) & (1 << 6)) != 0)) mask &= ~DV_I_48_2_bit;
        }
        if ((mask & DV_I_49_2_bit) != 0) {
            if ((((W[49] ^ (W[50] << 5)) & (1 << 6)) != 0) or (((W[42] ^ W[50]) & (1 << 1)) == 0) or (((W[39] ^ (W[40] << 5)) & (1 << 6)) != 0) or (((W[38] ^ W[40]) & (1 << 1)) == 0)) mask &= ~DV_I_49_2_bit;
        }
        if ((mask & DV_I_50_0_bit) != 0) mask &= ((((W[36] ^ W[37]) << 7)) | ~DV_I_50_0_bit);
        if ((mask & DV_I_50_2_bit) != 0) mask &= ((((W[43] ^ W[51]) << 11)) | ~DV_I_50_2_bit);
        if ((mask & DV_I_51_0_bit) != 0) mask &= ((((W[37] ^ W[38]) << 9)) | ~DV_I_51_0_bit);
        if ((mask & DV_I_51_2_bit) != 0) {
            if ((((W[51] ^ (W[52] << 5)) & (1 << 6)) != 0) or (((W[49] ^ W[51]) & (1 << 6)) != 0) or (((W[37] ^ (W[37] >> 5)) & (1 << 1)) != 0) or (((W[35] ^ (W[39] >> 25)) & (1 << 5)) != 0)) mask &= ~DV_I_51_2_bit;
        }
        if ((mask & DV_I_52_0_bit) != 0) mask &= ((((W[38] ^ W[39]) << 11)) | ~DV_I_52_0_bit);
        if ((mask & DV_II_46_2_bit) != 0) mask &= ((((W[47] ^ W[51]) << 17)) | ~DV_II_46_2_bit);
        if ((mask & DV_II_48_0_bit) != 0) {
            if ((((W[36] ^ (W[40] >> 25)) & (1 << 3)) != 0) or (((W[35] ^ (W[40] << 2)) & (1 << 30)) == 0)) mask &= ~DV_II_48_0_bit;
        }
        if ((mask & DV_II_49_0_bit) != 0) {
            if ((((W[37] ^ (W[41] >> 25)) & (1 << 3)) != 0) or (((W[36] ^ (W[41] << 2)) & (1 << 30)) == 0)) mask &= ~DV_II_49_0_bit;
        }
        if ((mask & DV_II_49_2_bit) != 0) {
            if ((((W[53] ^ (W[54] << 5)) & (1 << 6)) != 0) or (((W[51] ^ W[53]) & (1 << 6)) != 0) or (((W[50] ^ W[54]) & (1 << 1)) == 0) or (((W[45] ^ (W[46] << 5)) & (1 << 6)) != 0) or (((W[37] ^ (W[41] >> 25)) & (1 << 5)) != 0) or (((W[36] ^ (W[41] >> 30)) & (1 << 0)) == 0)) mask &= ~DV_II_49_2_bit;
        }
        if ((mask & DV_II_50_0_bit) != 0) {
            if ((((W[55] ^ W[58]) & (1 << 29)) == 0) or (((W[38] ^ (W[42] >> 25)) & (1 << 3)) != 0) or (((W[37] ^ (W[42] << 2)) & (1 << 30)) == 0)) mask &= ~DV_II_50_0_bit;
        }
        if ((mask & DV_II_50_2_bit) != 0) {
            if ((((W[54] ^ (W[55] << 5)) & (1 << 6)) != 0) or (((W[52] ^ W[54]) & (1 << 6)) != 0) or (((W[51] ^ W[55]) & (1 << 1)) == 0) or (((W[45] ^ W[47]) & (1 << 1)) == 0) or (((W[38] ^ (W[42] >> 25)) & (1 << 5)) != 0) or (((W[37] ^ (W[42] >> 30)) & (1 << 0)) == 0)) mask &= ~DV_II_50_2_bit;
        }
        if ((mask & DV_II_51_0_bit) != 0) {
            if ((((W[39] ^ (W[43] >> 25)) & (1 << 3)) != 0) or (((W[38] ^ (W[43] << 2)) & (1 << 30)) == 0)) mask &= ~DV_II_51_0_bit;
        }
        if ((mask & DV_II_51_2_bit) != 0) {
            if ((((W[55] ^ (W[56] << 5)) & (1 << 6)) != 0) or (((W[53] ^ W[55]) & (1 << 6)) != 0) or (((W[52] ^ W[56]) & (1 << 1)) == 0) or (((W[46] ^ W[48]) & (1 << 1)) == 0) or (((W[39] ^ (W[43] >> 25)) & (1 << 5)) != 0) or (((W[38] ^ (W[43] >> 30)) & (1 << 0)) == 0)) mask &= ~DV_II_51_2_bit;
        }
        if ((mask & DV_II_52_0_bit) != 0) {
            if ((((W[59] ^ W[60]) & (1 << 29)) != 0) or (((W[40] ^ (W[44] >> 25)) & (1 << 3)) != 0) or (((W[40] ^ (W[44] >> 25)) & (1 << 4)) != 0) or (((W[39] ^ (W[44] << 2)) & (1 << 30)) == 0)) mask &= ~DV_II_52_0_bit;
        }
        if ((mask & DV_II_53_0_bit) != 0) {
            if ((((W[58] ^ W[61]) & (1 << 29)) == 0) or (((W[57] ^ (W[61] >> 25)) & (1 << 4)) != 0) or (((W[41] ^ (W[45] >> 25)) & (1 << 3)) != 0) or (((W[41] ^ (W[45] >> 25)) & (1 << 4)) != 0)) mask &= ~DV_II_53_0_bit;
        }
        if ((mask & DV_II_54_0_bit) != 0) {
            if ((((W[58] ^ (W[62] >> 25)) & (1 << 4)) != 0) or (((W[42] ^ (W[46] >> 25)) & (1 << 3)) != 0) or (((W[42] ^ (W[46] >> 25)) & (1 << 4)) != 0)) mask &= ~DV_II_54_0_bit;
        }
        if ((mask & DV_II_55_0_bit) != 0) {
            if ((((W[59] ^ (W[63] >> 25)) & (1 << 4)) != 0) or (((W[57] ^ (W[59] >> 25)) & (1 << 4)) != 0) or (((W[43] ^ (W[47] >> 25)) & (1 << 3)) != 0) or (((W[43] ^ (W[47] >> 25)) & (1 << 4)) != 0)) mask &= ~DV_II_55_0_bit;
        }
        if ((mask & DV_II_56_0_bit) != 0) {
            if ((((W[60] ^ (W[64] >> 25)) & (1 << 4)) != 0) or (((W[44] ^ (W[48] >> 25)) & (1 << 3)) != 0) or (((W[44] ^ (W[48] >> 25)) & (1 << 4)) != 0)) mask &= ~DV_II_56_0_bit;
        }
    }
    return mask;
}

/// A disturbance vector: which one it is, the step to recompress from, the
/// bit `ubcCheck` reports it in, and the message-block difference it defines.
const Dv = struct {
    dv_type: u8,
    k: u8,
    b: u8,
    test_t: u8,
    mask_bit: u5,
    dm: [80]u32,
};

/// The thirty-two disturbance vectors, transcribed from the published table.
const dvs = [_]Dv{
    .{ .dv_type = 1, .k = 43, .b = 0, .test_t = 58, .mask_bit = 0, .dm = .{
        0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008,
        0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000, 0x08000018,
        0x60000000, 0x90000010, 0xf0000010, 0x90000008, 0xc0000000, 0x90000010, 0xf0000010, 0xb0000008,
        0x40000000, 0x90000000, 0xf0000010, 0x90000018, 0x60000000, 0x90000010, 0x90000010, 0x90000000,
        0x80000000, 0x00000010, 0xa0000000, 0x20000000, 0xa0000000, 0x20000010, 0x00000000, 0x20000010,
        0x20000000, 0x00000010, 0x20000000, 0x00000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000040, 0x40000002,
        0x80000004, 0x80000080, 0x80000006, 0x00000049, 0x00000103, 0x80000009, 0x80000012, 0x80000202,
        0x00000018, 0x00000164, 0x00000408, 0x800000e6, 0x8000004c, 0x00000803, 0x80000161, 0x80000599,
    } },
    .{ .dv_type = 1, .k = 44, .b = 0, .test_t = 58, .mask_bit = 1, .dm = .{
        0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000,
        0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000,
        0x08000018, 0x60000000, 0x90000010, 0xf0000010, 0x90000008, 0xc0000000, 0x90000010, 0xf0000010,
        0xb0000008, 0x40000000, 0x90000000, 0xf0000010, 0x90000018, 0x60000000, 0x90000010, 0x90000010,
        0x90000000, 0x80000000, 0x00000010, 0xa0000000, 0x20000000, 0xa0000000, 0x20000010, 0x00000000,
        0x20000010, 0x20000000, 0x00000010, 0x20000000, 0x00000010, 0xa0000000, 0x00000000, 0x20000000,
        0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000040,
        0x40000002, 0x80000004, 0x80000080, 0x80000006, 0x00000049, 0x00000103, 0x80000009, 0x80000012,
        0x80000202, 0x00000018, 0x00000164, 0x00000408, 0x800000e6, 0x8000004c, 0x00000803, 0x80000161,
    } },
    .{ .dv_type = 1, .k = 45, .b = 0, .test_t = 58, .mask_bit = 2, .dm = .{
        0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000,
        0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010,
        0x48000000, 0x08000018, 0x60000000, 0x90000010, 0xf0000010, 0x90000008, 0xc0000000, 0x90000010,
        0xf0000010, 0xb0000008, 0x40000000, 0x90000000, 0xf0000010, 0x90000018, 0x60000000, 0x90000010,
        0x90000010, 0x90000000, 0x80000000, 0x00000010, 0xa0000000, 0x20000000, 0xa0000000, 0x20000010,
        0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x20000000, 0x00000010, 0xa0000000, 0x00000000,
        0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002,
        0x40000040, 0x40000002, 0x80000004, 0x80000080, 0x80000006, 0x00000049, 0x00000103, 0x80000009,
        0x80000012, 0x80000202, 0x00000018, 0x00000164, 0x00000408, 0x800000e6, 0x8000004c, 0x00000803,
    } },
    .{ .dv_type = 1, .k = 46, .b = 0, .test_t = 58, .mask_bit = 3, .dm = .{
        0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010,
        0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000,
        0x20000010, 0x48000000, 0x08000018, 0x60000000, 0x90000010, 0xf0000010, 0x90000008, 0xc0000000,
        0x90000010, 0xf0000010, 0xb0000008, 0x40000000, 0x90000000, 0xf0000010, 0x90000018, 0x60000000,
        0x90000010, 0x90000010, 0x90000000, 0x80000000, 0x00000010, 0xa0000000, 0x20000000, 0xa0000000,
        0x20000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x20000000, 0x00000010, 0xa0000000,
        0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001,
        0x40000002, 0x40000040, 0x40000002, 0x80000004, 0x80000080, 0x80000006, 0x00000049, 0x00000103,
        0x80000009, 0x80000012, 0x80000202, 0x00000018, 0x00000164, 0x00000408, 0x800000e6, 0x8000004c,
    } },
    .{ .dv_type = 1, .k = 46, .b = 2, .test_t = 58, .mask_bit = 4, .dm = .{
        0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032, 0x60000043, 0x20000040, 0xe0000042,
        0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052, 0x40000040, 0xe0000052, 0xa0000000,
        0x80000040, 0x20000001, 0x20000060, 0x80000001, 0x40000042, 0xc0000043, 0x40000022, 0x00000003,
        0x40000042, 0xc0000043, 0xc0000022, 0x00000001, 0x40000002, 0xc0000043, 0x40000062, 0x80000001,
        0x40000042, 0x40000042, 0x40000002, 0x00000002, 0x00000040, 0x80000002, 0x80000000, 0x80000002,
        0x80000040, 0x00000000, 0x80000040, 0x80000000, 0x00000040, 0x80000000, 0x00000040, 0x80000002,
        0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000004, 0x00000080, 0x00000004,
        0x00000009, 0x00000101, 0x00000009, 0x00000012, 0x00000202, 0x0000001a, 0x00000124, 0x0000040c,
        0x00000026, 0x0000004a, 0x0000080a, 0x00000060, 0x00000590, 0x00001020, 0x0000039a, 0x00000132,
    } },
    .{ .dv_type = 1, .k = 47, .b = 0, .test_t = 58, .mask_bit = 5, .dm = .{
        0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010,
        0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014,
        0x28000000, 0x20000010, 0x48000000, 0x08000018, 0x60000000, 0x90000010, 0xf0000010, 0x90000008,
        0xc0000000, 0x90000010, 0xf0000010, 0xb0000008, 0x40000000, 0x90000000, 0xf0000010, 0x90000018,
        0x60000000, 0x90000010, 0x90000010, 0x90000000, 0x80000000, 0x00000010, 0xa0000000, 0x20000000,
        0xa0000000, 0x20000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x20000000, 0x00000010,
        0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020,
        0x00000001, 0x40000002, 0x40000040, 0x40000002, 0x80000004, 0x80000080, 0x80000006, 0x00000049,
        0x00000103, 0x80000009, 0x80000012, 0x80000202, 0x00000018, 0x00000164, 0x00000408, 0x800000e6,
    } },
    .{ .dv_type = 1, .k = 47, .b = 2, .test_t = 58, .mask_bit = 6, .dm = .{
        0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032, 0x60000043, 0x20000040,
        0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052, 0x40000040, 0xe0000052,
        0xa0000000, 0x80000040, 0x20000001, 0x20000060, 0x80000001, 0x40000042, 0xc0000043, 0x40000022,
        0x00000003, 0x40000042, 0xc0000043, 0xc0000022, 0x00000001, 0x40000002, 0xc0000043, 0x40000062,
        0x80000001, 0x40000042, 0x40000042, 0x40000002, 0x00000002, 0x00000040, 0x80000002, 0x80000000,
        0x80000002, 0x80000040, 0x00000000, 0x80000040, 0x80000000, 0x00000040, 0x80000000, 0x00000040,
        0x80000002, 0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000004, 0x00000080,
        0x00000004, 0x00000009, 0x00000101, 0x00000009, 0x00000012, 0x00000202, 0x0000001a, 0x00000124,
        0x0000040c, 0x00000026, 0x0000004a, 0x0000080a, 0x00000060, 0x00000590, 0x00001020, 0x0000039a,
    } },
    .{ .dv_type = 1, .k = 48, .b = 0, .test_t = 58, .mask_bit = 7, .dm = .{
        0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c, 0xd8000010,
        0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014, 0x10000010,
        0xb8000014, 0x28000000, 0x20000010, 0x48000000, 0x08000018, 0x60000000, 0x90000010, 0xf0000010,
        0x90000008, 0xc0000000, 0x90000010, 0xf0000010, 0xb0000008, 0x40000000, 0x90000000, 0xf0000010,
        0x90000018, 0x60000000, 0x90000010, 0x90000010, 0x90000000, 0x80000000, 0x00000010, 0xa0000000,
        0x20000000, 0xa0000000, 0x20000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x20000000,
        0x00000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001,
        0x00000020, 0x00000001, 0x40000002, 0x40000040, 0x40000002, 0x80000004, 0x80000080, 0x80000006,
        0x00000049, 0x00000103, 0x80000009, 0x80000012, 0x80000202, 0x00000018, 0x00000164, 0x00000408,
    } },
    .{ .dv_type = 1, .k = 48, .b = 2, .test_t = 58, .mask_bit = 8, .dm = .{
        0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032, 0x60000043,
        0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052, 0x40000040,
        0xe0000052, 0xa0000000, 0x80000040, 0x20000001, 0x20000060, 0x80000001, 0x40000042, 0xc0000043,
        0x40000022, 0x00000003, 0x40000042, 0xc0000043, 0xc0000022, 0x00000001, 0x40000002, 0xc0000043,
        0x40000062, 0x80000001, 0x40000042, 0x40000042, 0x40000002, 0x00000002, 0x00000040, 0x80000002,
        0x80000000, 0x80000002, 0x80000040, 0x00000000, 0x80000040, 0x80000000, 0x00000040, 0x80000000,
        0x00000040, 0x80000002, 0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000004,
        0x00000080, 0x00000004, 0x00000009, 0x00000101, 0x00000009, 0x00000012, 0x00000202, 0x0000001a,
        0x00000124, 0x0000040c, 0x00000026, 0x0000004a, 0x0000080a, 0x00000060, 0x00000590, 0x00001020,
    } },
    .{ .dv_type = 1, .k = 49, .b = 0, .test_t = 58, .mask_bit = 9, .dm = .{
        0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000, 0x9800000c,
        0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000, 0x90000014,
        0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000, 0x08000018, 0x60000000, 0x90000010,
        0xf0000010, 0x90000008, 0xc0000000, 0x90000010, 0xf0000010, 0xb0000008, 0x40000000, 0x90000000,
        0xf0000010, 0x90000018, 0x60000000, 0x90000010, 0x90000010, 0x90000000, 0x80000000, 0x00000010,
        0xa0000000, 0x20000000, 0xa0000000, 0x20000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010,
        0x20000000, 0x00000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000040, 0x40000002, 0x80000004, 0x80000080,
        0x80000006, 0x00000049, 0x00000103, 0x80000009, 0x80000012, 0x80000202, 0x00000018, 0x00000164,
    } },
    .{ .dv_type = 1, .k = 49, .b = 2, .test_t = 58, .mask_bit = 10, .dm = .{
        0x60000000, 0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000, 0x60000032,
        0x60000043, 0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003, 0x40000052,
        0x40000040, 0xe0000052, 0xa0000000, 0x80000040, 0x20000001, 0x20000060, 0x80000001, 0x40000042,
        0xc0000043, 0x40000022, 0x00000003, 0x40000042, 0xc0000043, 0xc0000022, 0x00000001, 0x40000002,
        0xc0000043, 0x40000062, 0x80000001, 0x40000042, 0x40000042, 0x40000002, 0x00000002, 0x00000040,
        0x80000002, 0x80000000, 0x80000002, 0x80000040, 0x00000000, 0x80000040, 0x80000000, 0x00000040,
        0x80000000, 0x00000040, 0x80000002, 0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000004, 0x00000080, 0x00000004, 0x00000009, 0x00000101, 0x00000009, 0x00000012, 0x00000202,
        0x0000001a, 0x00000124, 0x0000040c, 0x00000026, 0x0000004a, 0x0000080a, 0x00000060, 0x00000590,
    } },
    .{ .dv_type = 1, .k = 50, .b = 0, .test_t = 65, .mask_bit = 11, .dm = .{
        0x0800000c, 0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008, 0x08000000,
        0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008, 0xc0000000,
        0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000, 0x08000018, 0x60000000,
        0x90000010, 0xf0000010, 0x90000008, 0xc0000000, 0x90000010, 0xf0000010, 0xb0000008, 0x40000000,
        0x90000000, 0xf0000010, 0x90000018, 0x60000000, 0x90000010, 0x90000010, 0x90000000, 0x80000000,
        0x00000010, 0xa0000000, 0x20000000, 0xa0000000, 0x20000010, 0x00000000, 0x20000010, 0x20000000,
        0x00000010, 0x20000000, 0x00000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000040, 0x40000002, 0x80000004,
        0x80000080, 0x80000006, 0x00000049, 0x00000103, 0x80000009, 0x80000012, 0x80000202, 0x00000018,
    } },
    .{ .dv_type = 1, .k = 50, .b = 2, .test_t = 65, .mask_bit = 12, .dm = .{
        0x20000030, 0x60000000, 0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022, 0x20000000,
        0x60000032, 0x60000043, 0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020, 0x00000003,
        0x40000052, 0x40000040, 0xe0000052, 0xa0000000, 0x80000040, 0x20000001, 0x20000060, 0x80000001,
        0x40000042, 0xc0000043, 0x40000022, 0x00000003, 0x40000042, 0xc0000043, 0xc0000022, 0x00000001,
        0x40000002, 0xc0000043, 0x40000062, 0x80000001, 0x40000042, 0x40000042, 0x40000002, 0x00000002,
        0x00000040, 0x80000002, 0x80000000, 0x80000002, 0x80000040, 0x00000000, 0x80000040, 0x80000000,
        0x00000040, 0x80000000, 0x00000040, 0x80000002, 0x00000000, 0x80000000, 0x80000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000004, 0x00000080, 0x00000004, 0x00000009, 0x00000101, 0x00000009, 0x00000012,
        0x00000202, 0x0000001a, 0x00000124, 0x0000040c, 0x00000026, 0x0000004a, 0x0000080a, 0x00000060,
    } },
    .{ .dv_type = 1, .k = 51, .b = 0, .test_t = 65, .mask_bit = 13, .dm = .{
        0xe8000000, 0x0800000c, 0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014, 0xb4000008,
        0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000, 0x00000008,
        0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000, 0x08000018,
        0x60000000, 0x90000010, 0xf0000010, 0x90000008, 0xc0000000, 0x90000010, 0xf0000010, 0xb0000008,
        0x40000000, 0x90000000, 0xf0000010, 0x90000018, 0x60000000, 0x90000010, 0x90000010, 0x90000000,
        0x80000000, 0x00000010, 0xa0000000, 0x20000000, 0xa0000000, 0x20000010, 0x00000000, 0x20000010,
        0x20000000, 0x00000010, 0x20000000, 0x00000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000040, 0x40000002,
        0x80000004, 0x80000080, 0x80000006, 0x00000049, 0x00000103, 0x80000009, 0x80000012, 0x80000202,
    } },
    .{ .dv_type = 1, .k = 51, .b = 2, .test_t = 65, .mask_bit = 14, .dm = .{
        0xa0000003, 0x20000030, 0x60000000, 0xe000002a, 0x20000043, 0xb0000040, 0xd0000053, 0xd0000022,
        0x20000000, 0x60000032, 0x60000043, 0x20000040, 0xe0000042, 0x60000002, 0x80000001, 0x00000020,
        0x00000003, 0x40000052, 0x40000040, 0xe0000052, 0xa0000000, 0x80000040, 0x20000001, 0x20000060,
        0x80000001, 0x40000042, 0xc0000043, 0x40000022, 0x00000003, 0x40000042, 0xc0000043, 0xc0000022,
        0x00000001, 0x40000002, 0xc0000043, 0x40000062, 0x80000001, 0x40000042, 0x40000042, 0x40000002,
        0x00000002, 0x00000040, 0x80000002, 0x80000000, 0x80000002, 0x80000040, 0x00000000, 0x80000040,
        0x80000000, 0x00000040, 0x80000000, 0x00000040, 0x80000002, 0x00000000, 0x80000000, 0x80000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000004, 0x00000080, 0x00000004, 0x00000009, 0x00000101, 0x00000009,
        0x00000012, 0x00000202, 0x0000001a, 0x00000124, 0x0000040c, 0x00000026, 0x0000004a, 0x0000080a,
    } },
    .{ .dv_type = 1, .k = 52, .b = 0, .test_t = 65, .mask_bit = 15, .dm = .{
        0x04000010, 0xe8000000, 0x0800000c, 0x18000000, 0xb800000a, 0xc8000010, 0x2c000010, 0xf4000014,
        0xb4000008, 0x08000000, 0x9800000c, 0xd8000010, 0x08000010, 0xb8000010, 0x98000000, 0x60000000,
        0x00000008, 0xc0000000, 0x90000014, 0x10000010, 0xb8000014, 0x28000000, 0x20000010, 0x48000000,
        0x08000018, 0x60000000, 0x90000010, 0xf0000010, 0x90000008, 0xc0000000, 0x90000010, 0xf0000010,
        0xb0000008, 0x40000000, 0x90000000, 0xf0000010, 0x90000018, 0x60000000, 0x90000010, 0x90000010,
        0x90000000, 0x80000000, 0x00000010, 0xa0000000, 0x20000000, 0xa0000000, 0x20000010, 0x00000000,
        0x20000010, 0x20000000, 0x00000010, 0x20000000, 0x00000010, 0xa0000000, 0x00000000, 0x20000000,
        0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000040,
        0x40000002, 0x80000004, 0x80000080, 0x80000006, 0x00000049, 0x00000103, 0x80000009, 0x80000012,
    } },
    .{ .dv_type = 2, .k = 45, .b = 0, .test_t = 58, .mask_bit = 16, .dm = .{
        0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c,
        0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000, 0xb0000004,
        0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010, 0x98000010, 0xa0000000, 0x00000000,
        0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010,
        0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010, 0xb0000000, 0x20000000, 0x20000000,
        0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000, 0x20000000, 0x80000000, 0x00000010,
        0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002,
        0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046, 0x4000004b, 0x80000107, 0x00000089,
        0x00000014, 0x8000024b, 0x0000011b, 0x8000016d, 0x8000041a, 0x000002e4, 0x80000054, 0x00000967,
    } },
    .{ .dv_type = 2, .k = 46, .b = 0, .test_t = 58, .mask_bit = 17, .dm = .{
        0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010,
        0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000,
        0xb0000004, 0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010, 0x98000010, 0xa0000000,
        0x00000000, 0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0x20000000,
        0x00000010, 0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010, 0xb0000000, 0x20000000,
        0x20000000, 0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000, 0x20000000, 0x80000000,
        0x00000010, 0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001,
        0x40000002, 0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046, 0x4000004b, 0x80000107,
        0x00000089, 0x00000014, 0x8000024b, 0x0000011b, 0x8000016d, 0x8000041a, 0x000002e4, 0x80000054,
    } },
    .{ .dv_type = 2, .k = 46, .b = 2, .test_t = 58, .mask_bit = 18, .dm = .{
        0x90000070, 0xb0000053, 0x30000008, 0x00000043, 0xd0000072, 0xb0000010, 0xf0000062, 0xc0000042,
        0x00000030, 0xe0000042, 0x20000060, 0xe0000041, 0x20000050, 0xc0000041, 0xe0000072, 0xa0000003,
        0xc0000012, 0x60000041, 0xc0000032, 0x20000001, 0xc0000002, 0xe0000042, 0x60000042, 0x80000002,
        0x00000000, 0x00000000, 0x80000000, 0x00000002, 0x00000040, 0x00000000, 0x80000040, 0x80000000,
        0x00000040, 0x80000001, 0x00000060, 0x80000003, 0x40000002, 0xc0000040, 0xc0000002, 0x80000000,
        0x80000000, 0x80000002, 0x00000040, 0x00000002, 0x80000000, 0x80000000, 0x80000000, 0x00000002,
        0x00000040, 0x00000000, 0x80000040, 0x80000002, 0x00000000, 0x80000000, 0x80000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000004, 0x00000080, 0x00000004,
        0x00000009, 0x00000105, 0x00000089, 0x00000016, 0x0000020b, 0x0000011b, 0x0000012d, 0x0000041e,
        0x00000224, 0x00000050, 0x0000092e, 0x0000046c, 0x000005b6, 0x0000106a, 0x00000b90, 0x00000152,
    } },
    .{ .dv_type = 2, .k = 47, .b = 0, .test_t = 58, .mask_bit = 19, .dm = .{
        0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018,
        0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c,
        0xe8000000, 0xb0000004, 0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010, 0x98000010,
        0xa0000000, 0x00000000, 0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010,
        0x20000000, 0x00000010, 0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010, 0xb0000000,
        0x20000000, 0x20000000, 0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000, 0x20000000,
        0x80000000, 0x00000010, 0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020,
        0x00000001, 0x40000002, 0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046, 0x4000004b,
        0x80000107, 0x00000089, 0x00000014, 0x8000024b, 0x0000011b, 0x8000016d, 0x8000041a, 0x000002e4,
    } },
    .{ .dv_type = 2, .k = 48, .b = 0, .test_t = 58, .mask_bit = 20, .dm = .{
        0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004,
        0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010,
        0xb800001c, 0xe8000000, 0xb0000004, 0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010,
        0x98000010, 0xa0000000, 0x00000000, 0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000,
        0x20000010, 0x20000000, 0x00000010, 0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010,
        0xb0000000, 0x20000000, 0x20000000, 0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000,
        0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000,
        0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001,
        0x00000020, 0x00000001, 0x40000002, 0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046,
        0x4000004b, 0x80000107, 0x00000089, 0x00000014, 0x8000024b, 0x0000011b, 0x8000016d, 0x8000041a,
    } },
    .{ .dv_type = 2, .k = 49, .b = 0, .test_t = 58, .mask_bit = 21, .dm = .{
        0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c,
        0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014,
        0x70000010, 0xb800001c, 0xe8000000, 0xb0000004, 0x58000010, 0xb000000c, 0x48000000, 0xb0000000,
        0xb8000010, 0x98000010, 0xa0000000, 0x00000000, 0x00000000, 0x20000000, 0x80000000, 0x00000010,
        0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x60000000, 0x00000018, 0xe0000000, 0x90000000,
        0x30000010, 0xb0000000, 0x20000000, 0x20000000, 0xa0000000, 0x00000010, 0x80000000, 0x20000000,
        0x20000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0xa0000000, 0x00000000,
        0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000041, 0x40000022, 0x80000005, 0xc0000082,
        0xc0000046, 0x4000004b, 0x80000107, 0x00000089, 0x00000014, 0x8000024b, 0x0000011b, 0x8000016d,
    } },
    .{ .dv_type = 2, .k = 49, .b = 2, .test_t = 58, .mask_bit = 22, .dm = .{
        0xf0000010, 0xf000006a, 0x80000040, 0x90000070, 0xb0000053, 0x30000008, 0x00000043, 0xd0000072,
        0xb0000010, 0xf0000062, 0xc0000042, 0x00000030, 0xe0000042, 0x20000060, 0xe0000041, 0x20000050,
        0xc0000041, 0xe0000072, 0xa0000003, 0xc0000012, 0x60000041, 0xc0000032, 0x20000001, 0xc0000002,
        0xe0000042, 0x60000042, 0x80000002, 0x00000000, 0x00000000, 0x80000000, 0x00000002, 0x00000040,
        0x00000000, 0x80000040, 0x80000000, 0x00000040, 0x80000001, 0x00000060, 0x80000003, 0x40000002,
        0xc0000040, 0xc0000002, 0x80000000, 0x80000000, 0x80000002, 0x00000040, 0x00000002, 0x80000000,
        0x80000000, 0x80000000, 0x00000002, 0x00000040, 0x00000000, 0x80000040, 0x80000002, 0x00000000,
        0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000004, 0x00000080, 0x00000004, 0x00000009, 0x00000105, 0x00000089, 0x00000016, 0x0000020b,
        0x0000011b, 0x0000012d, 0x0000041e, 0x00000224, 0x00000050, 0x0000092e, 0x0000046c, 0x000005b6,
    } },
    .{ .dv_type = 2, .k = 50, .b = 0, .test_t = 65, .mask_bit = 23, .dm = .{
        0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010,
        0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010,
        0x08000014, 0x70000010, 0xb800001c, 0xe8000000, 0xb0000004, 0x58000010, 0xb000000c, 0x48000000,
        0xb0000000, 0xb8000010, 0x98000010, 0xa0000000, 0x00000000, 0x00000000, 0x20000000, 0x80000000,
        0x00000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x60000000, 0x00000018, 0xe0000000,
        0x90000000, 0x30000010, 0xb0000000, 0x20000000, 0x20000000, 0xa0000000, 0x00000010, 0x80000000,
        0x20000000, 0x20000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0xa0000000,
        0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000041, 0x40000022, 0x80000005,
        0xc0000082, 0xc0000046, 0x4000004b, 0x80000107, 0x00000089, 0x00000014, 0x8000024b, 0x0000011b,
    } },
    .{ .dv_type = 2, .k = 50, .b = 2, .test_t = 65, .mask_bit = 24, .dm = .{
        0xd0000072, 0xf0000010, 0xf000006a, 0x80000040, 0x90000070, 0xb0000053, 0x30000008, 0x00000043,
        0xd0000072, 0xb0000010, 0xf0000062, 0xc0000042, 0x00000030, 0xe0000042, 0x20000060, 0xe0000041,
        0x20000050, 0xc0000041, 0xe0000072, 0xa0000003, 0xc0000012, 0x60000041, 0xc0000032, 0x20000001,
        0xc0000002, 0xe0000042, 0x60000042, 0x80000002, 0x00000000, 0x00000000, 0x80000000, 0x00000002,
        0x00000040, 0x00000000, 0x80000040, 0x80000000, 0x00000040, 0x80000001, 0x00000060, 0x80000003,
        0x40000002, 0xc0000040, 0xc0000002, 0x80000000, 0x80000000, 0x80000002, 0x00000040, 0x00000002,
        0x80000000, 0x80000000, 0x80000000, 0x00000002, 0x00000040, 0x00000000, 0x80000040, 0x80000002,
        0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000004, 0x00000080, 0x00000004, 0x00000009, 0x00000105, 0x00000089, 0x00000016,
        0x0000020b, 0x0000011b, 0x0000012d, 0x0000041e, 0x00000224, 0x00000050, 0x0000092e, 0x0000046c,
    } },
    .{ .dv_type = 2, .k = 51, .b = 0, .test_t = 65, .mask_bit = 25, .dm = .{
        0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002,
        0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018,
        0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000, 0xb0000004, 0x58000010, 0xb000000c,
        0x48000000, 0xb0000000, 0xb8000010, 0x98000010, 0xa0000000, 0x00000000, 0x00000000, 0x20000000,
        0x80000000, 0x00000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x60000000, 0x00000018,
        0xe0000000, 0x90000000, 0x30000010, 0xb0000000, 0x20000000, 0x20000000, 0xa0000000, 0x00000010,
        0x80000000, 0x20000000, 0x20000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010,
        0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000041, 0x40000022,
        0x80000005, 0xc0000082, 0xc0000046, 0x4000004b, 0x80000107, 0x00000089, 0x00000014, 0x8000024b,
    } },
    .{ .dv_type = 2, .k = 51, .b = 2, .test_t = 65, .mask_bit = 26, .dm = .{
        0x00000043, 0xd0000072, 0xf0000010, 0xf000006a, 0x80000040, 0x90000070, 0xb0000053, 0x30000008,
        0x00000043, 0xd0000072, 0xb0000010, 0xf0000062, 0xc0000042, 0x00000030, 0xe0000042, 0x20000060,
        0xe0000041, 0x20000050, 0xc0000041, 0xe0000072, 0xa0000003, 0xc0000012, 0x60000041, 0xc0000032,
        0x20000001, 0xc0000002, 0xe0000042, 0x60000042, 0x80000002, 0x00000000, 0x00000000, 0x80000000,
        0x00000002, 0x00000040, 0x00000000, 0x80000040, 0x80000000, 0x00000040, 0x80000001, 0x00000060,
        0x80000003, 0x40000002, 0xc0000040, 0xc0000002, 0x80000000, 0x80000000, 0x80000002, 0x00000040,
        0x00000002, 0x80000000, 0x80000000, 0x80000000, 0x00000002, 0x00000040, 0x00000000, 0x80000040,
        0x80000002, 0x00000000, 0x80000000, 0x80000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000004, 0x00000080, 0x00000004, 0x00000009, 0x00000105, 0x00000089,
        0x00000016, 0x0000020b, 0x0000011b, 0x0000012d, 0x0000041e, 0x00000224, 0x00000050, 0x0000092e,
    } },
    .{ .dv_type = 2, .k = 52, .b = 0, .test_t = 65, .mask_bit = 27, .dm = .{
        0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c, 0xec000014,
        0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010,
        0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000, 0xb0000004, 0x58000010,
        0xb000000c, 0x48000000, 0xb0000000, 0xb8000010, 0x98000010, 0xa0000000, 0x00000000, 0x00000000,
        0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010, 0x60000000,
        0x00000018, 0xe0000000, 0x90000000, 0x30000010, 0xb0000000, 0x20000000, 0x20000000, 0xa0000000,
        0x00000010, 0x80000000, 0x20000000, 0x20000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000,
        0x20000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002, 0x40000041,
        0x40000022, 0x80000005, 0xc0000082, 0xc0000046, 0x4000004b, 0x80000107, 0x00000089, 0x00000014,
    } },
    .{ .dv_type = 2, .k = 53, .b = 0, .test_t = 65, .mask_bit = 28, .dm = .{
        0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010, 0x2400001c,
        0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010, 0x0000000c,
        0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000, 0xb0000004,
        0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010, 0x98000010, 0xa0000000, 0x00000000,
        0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0x20000000, 0x00000010,
        0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010, 0xb0000000, 0x20000000, 0x20000000,
        0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000, 0x20000000, 0x80000000, 0x00000010,
        0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001, 0x40000002,
        0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046, 0x4000004b, 0x80000107, 0x00000089,
    } },
    .{ .dv_type = 2, .k = 54, .b = 0, .test_t = 65, .mask_bit = 29, .dm = .{
        0x0400001c, 0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a, 0x20000010,
        0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018, 0xb0000010,
        0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c, 0xe8000000,
        0xb0000004, 0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010, 0x98000010, 0xa0000000,
        0x00000000, 0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0x20000000,
        0x00000010, 0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010, 0xb0000000, 0x20000000,
        0x20000000, 0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000, 0x20000000, 0x80000000,
        0x00000010, 0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020, 0x00000001,
        0x40000002, 0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046, 0x4000004b, 0x80000107,
    } },
    .{ .dv_type = 2, .k = 55, .b = 0, .test_t = 65, .mask_bit = 30, .dm = .{
        0x00000010, 0x0400001c, 0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004, 0xbc00001a,
        0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004, 0xbc000018,
        0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010, 0xb800001c,
        0xe8000000, 0xb0000004, 0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010, 0x98000010,
        0xa0000000, 0x00000000, 0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010,
        0x20000000, 0x00000010, 0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010, 0xb0000000,
        0x20000000, 0x20000000, 0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000, 0x20000000,
        0x80000000, 0x00000010, 0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000, 0x20000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000020,
        0x00000001, 0x40000002, 0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046, 0x4000004b,
    } },
    .{ .dv_type = 2, .k = 56, .b = 0, .test_t = 65, .mask_bit = 31, .dm = .{
        0x2600001a, 0x00000010, 0x0400001c, 0xcc000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x3c000004,
        0xbc00001a, 0x20000010, 0x2400001c, 0xec000014, 0x0c000002, 0xc0000010, 0xb400001c, 0x2c000004,
        0xbc000018, 0xb0000010, 0x0000000c, 0xb8000010, 0x08000018, 0x78000010, 0x08000014, 0x70000010,
        0xb800001c, 0xe8000000, 0xb0000004, 0x58000010, 0xb000000c, 0x48000000, 0xb0000000, 0xb8000010,
        0x98000010, 0xa0000000, 0x00000000, 0x00000000, 0x20000000, 0x80000000, 0x00000010, 0x00000000,
        0x20000010, 0x20000000, 0x00000010, 0x60000000, 0x00000018, 0xe0000000, 0x90000000, 0x30000010,
        0xb0000000, 0x20000000, 0x20000000, 0xa0000000, 0x00000010, 0x80000000, 0x20000000, 0x20000000,
        0x20000000, 0x80000000, 0x00000010, 0x00000000, 0x20000010, 0xa0000000, 0x00000000, 0x20000000,
        0x20000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000001,
        0x00000020, 0x00000001, 0x40000002, 0x40000041, 0x40000022, 0x80000005, 0xc0000082, 0xc0000046,
    } },
};

//=========================================================================
// Tests
//=========================================================================

const testing = std.testing;

/// The first 320 bytes of each of the two published colliding documents.
///
/// The two differ only in the two blocks at offset 192, which is the
/// near-collision pair itself, and these prefixes already have the same
/// SHA-1: `f92d74e3874587aaf443d1db961d4e26dde13e9c`. Three hundred and
/// twenty bytes is the whole of what a detector has to see, so the suite
/// carries that and not two four-hundred-kilobyte files.
/// The first published colliding pair, for a caller's own test: two
/// different byte strings with one SHA-1, each of which this detects.
pub const collision_test_vector_a = collision_a;
/// The other half of `collision_test_vector_a`.
pub const collision_test_vector_b = collision_b;

const collision_a = &hexBytes("255044462d312e330a25e2e3cfd30a0a0a312030206f626a0a3c3c2f57696474" ++
    "682032203020522f4865696768742033203020522f547970652034203020522f" ++
    "537562747970652035203020522f46696c7465722036203020522f436f6c6f72" ++
    "53706163652037203020522f4c656e6774682038203020522f42697473506572" ++
    "436f6d706f6e656e7420383e3e0a73747265616d0affd8fffe00245348412d31" ++
    "20697320646561642121212121852fec092339759c39b1a1c63c4c97e1fffe01" ++
    "7346dc9166b67e118f029ab621b2560ff9ca67cca8c7f85ba84c79030c2b3de2" ++
    "18f86db3a90901d5df45c14f26fedfb3dc38e96ac22fe7bd728f0e45bce046d2" ++
    "3c570feb141398bb552ef5a0a82be331fea48037b8b5d71f0e332edf93ac3500" ++
    "eb4ddc0decc1a864790c782c76215660dd309791d06bd0af3f98cda4bc4629b1");

const collision_b = &hexBytes("255044462d312e330a25e2e3cfd30a0a0a312030206f626a0a3c3c2f57696474" ++
    "682032203020522f4865696768742033203020522f547970652034203020522f" ++
    "537562747970652035203020522f46696c7465722036203020522f436f6c6f72" ++
    "53706163652037203020522f4c656e6774682038203020522f42697473506572" ++
    "436f6d706f6e656e7420383e3e0a73747265616d0affd8fffe00245348412d31" ++
    "20697320646561642121212121852fec092339759c39b1a1c63c4c97e1fffe01" ++
    "7f46dc93a6b67e013b029aaa1db2560b45ca67d688c7f84b8c4c791fe02b3df6" ++
    "14f86db1690901c56b45c1530afedfb76038e972722fe7ad728f0e4904e046c2" ++
    "30570fe9d41398abe12ef5bc942be33542a4802d98b5d70f2a332ec37fac3514" ++
    "e74ddc0f2cc1a874cd0c78305a21566461309789606bd0bf3f98cda8044629a1");

fn hexBytes(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "the published colliding pair is detected, and has one name" {
    var a: [20]u8 = undefined;
    var b: [20]u8 = undefined;
    const a_attacked = Sha1Dc.hash(collision_a, &a, .{});
    const b_attacked = Sha1Dc.hash(collision_b, &b, .{});

    // Two different messages, one SHA-1.
    try testing.expect(!std.mem.eql(u8, collision_a, collision_b));
    try testing.expectEqualSlices(u8, &a, &b);

    // The digest is SHA-1's digest; the check does not alter it.
    var reference: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(collision_a, &reference, .{});
    try testing.expectEqualSlices(u8, &reference, &a);

    // And both halves are recognised.
    try testing.expect(a_attacked);
    try testing.expect(b_attacked);
}

test "a collision found in one call is found across split feeds too" {
    // The pair straddles a block boundary either way; the cut sizes below
    // put the near-collision blocks across two calls.
    for ([_]usize{ 1, 63, 64, 100, 192, 193, 255, 319 }) |cut| {
        var d: Sha1Dc = .init(.{});
        d.update(collision_a[0..cut]);
        d.update(collision_a[cut..]);
        var out: [20]u8 = undefined;
        d.final(&out);
        try testing.expect(d.foundCollision());
    }
}

test "every length to four kilobytes agrees with SHA-1 and is not flagged" {
    var prng: std.Random.DefaultPrng = .init(0xc0_11_1d_e);
    var buf: [4096]u8 = undefined;
    prng.random().bytes(&buf);

    for (0..buf.len + 1) |len| {
        var mine: [20]u8 = undefined;
        const attacked = Sha1Dc.hash(buf[0..len], &mine, .{});
        var theirs: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(buf[0..len], &theirs, .{});
        try testing.expectEqualSlices(u8, &theirs, &mine);
        try testing.expect(!attacked);
    }
}

test "the FIPS 180 vectors, unchanged by the check" {
    var out: [20]u8 = undefined;
    try testing.expect(!Sha1Dc.hash("abc", &out, .{}));
    var text: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&text, "{x}", .{&out});
    try testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", &text);

    try testing.expect(!Sha1Dc.hash("", &out, .{}));
    _ = try std.fmt.bufPrint(&text, "{x}", .{&out});
    try testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", &text);
}

test "fuzz: the check never changes the name, and never fires by accident" {
    try std.testing.fuzz({}, fuzzSha1Dc, .{});
}

fn fuzzSha1Dc(_: void, smith: *std.testing.Smith) anyerror!void {
    var scratch: [4096]u8 = undefined;
    const n = smith.slice(&scratch);
    const input = scratch[0..n];

    var mine: [20]u8 = undefined;
    const attacked = Sha1Dc.hash(input, &mine, .{});
    var theirs: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input, &theirs, .{});

    // Whatever the check decides, the name is SHA-1's name.
    try testing.expectEqualSlices(u8, &theirs, &mine);
    // And nothing reached by chance is half of a near-collision pair.
    try testing.expect(!attacked);
}
