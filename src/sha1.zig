//! SHA-1, over the instructions the processor has for it.
//!
//! A repository's object names are the hash of every byte it stores, so the
//! hash is the floor under `addAll`, `writeTree` and `verify`. Both
//! architectures this package runs on carry SHA-1 in hardware — aarch64 as
//! `sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0` and `sha1su1`, x86-64 as
//! `sha1rnds4`, `sha1nexte`, `sha1msg1` and `sha1msg2` — and the difference
//! is a factor of four on the compression function.
//!
//! Which arm runs is decided by asking the processor, once, and not by what
//! the compiler was told about it: a binary built for a baseline target still
//! uses the instructions on a machine that has them, and the same binary
//! falls back to the software rounds on a machine that does not. Both hardware
//! arms assemble on a baseline target — aarch64 through `.arch_extension
//! crypto`, x86-64 because its assembler does not gate these — so the target
//! never takes the choice away. One thing does: the self-hosted x86-64 code
//! generator has no encoding for these instructions, so a build that uses it
//! takes the software rounds.
//!
//! The interface is the one `std.crypto.hash` uses, so this is a drop-in for
//! `std.crypto.hash.Sha1`, and the suite checks it against that implementation
//! on every length from zero to a little over four kilobytes.

const std = @import("std");
const builtin = @import("builtin");

/// SHA-1 as FIPS 180-4 defines it.
pub const Sha1 = struct {
    /// The compression function's input width, in bytes.
    pub const block_length = 64;
    /// The digest's width, in bytes.
    pub const digest_length = 20;
    /// SHA-1 takes no parameters; the field is here because
    /// `std.crypto.hash` hashers have one and this is a drop-in for them.
    pub const Options = struct {};

    /// The five chaining words, `H0` to `H4`.
    s: [5]u32,
    /// Bytes of a block that have arrived but not yet been compressed.
    buf: [block_length]u8,
    buf_len: u8,
    /// Total bytes fed, which becomes the length field of the padding.
    total_len: u64,

    const initial: [5]u32 = .{
        0x67452301,
        0xEFCDAB89,
        0x98BADCFE,
        0x10325476,
        0xC3D2E1F0,
    };

    /// A hasher with nothing fed to it yet.
    pub fn init(options: Options) Sha1 {
        _ = options;
        return .{
            .s = initial,
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    /// Feed bytes. Any number of calls of any sizes give the same digest as
    /// one call with the concatenation.
    pub fn update(d: *Sha1, bytes: []const u8) void {
        var rest = bytes;
        d.total_len +%= bytes.len;

        // Fill a partial block first, and only compress it once it is whole:
        // a short update must not leave the buffer holding a full block, or
        // `final` would pad on top of unread bytes.
        if (d.buf_len != 0) {
            const want = block_length - d.buf_len;
            const take = @min(want, rest.len);
            @memcpy(d.buf[d.buf_len..][0..take], rest[0..take]);
            d.buf_len += @intCast(take);
            rest = rest[take..];
            if (d.buf_len < block_length) return;
            compress(&d.s, &d.buf);
            d.buf_len = 0;
        }

        // Whole blocks straight from the caller's bytes, in one call, so the
        // hardware arm pays its setup once rather than once per block.
        const whole = rest.len - (rest.len % block_length);
        if (whole != 0) {
            compressBlocks(&d.s, rest[0..whole]);
            rest = rest[whole..];
        }

        if (rest.len != 0) {
            @memcpy(d.buf[0..rest.len], rest);
            d.buf_len = @intCast(rest.len);
        }
    }

    /// The digest. The hasher must not be used afterwards.
    pub fn final(d: *Sha1, out: *[digest_length]u8) void {
        const bit_len = d.total_len *% 8;

        d.buf[d.buf_len] = 0x80;
        d.buf_len += 1;
        // The length occupies the last eight bytes; if it does not fit, the
        // block is filled with zeros, compressed, and the length goes into
        // the next one.
        if (d.buf_len > block_length - 8) {
            @memset(d.buf[d.buf_len..], 0);
            compress(&d.s, &d.buf);
            d.buf_len = 0;
        }
        @memset(d.buf[d.buf_len .. block_length - 8], 0);
        std.mem.writeInt(u64, d.buf[block_length - 8 ..][0..8], bit_len, .big);
        compress(&d.s, &d.buf);

        for (d.s, 0..) |word, i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .big);
        }
    }

    /// The digest of `bytes`, in one call.
    pub fn hash(bytes: []const u8, out: *[digest_length]u8, options: Options) void {
        var d: Sha1 = .init(options);
        d.update(bytes);
        d.final(out);
    }
};

/// Which set of instructions the compression function is running on.
///
/// Public because a caller measuring a machine wants to know which arm it
/// measured; nothing in this package branches on it.
pub const Backend = enum {
    /// The eighty rounds written out, which every target has.
    software,
    /// aarch64's `sha1c` / `sha1p` / `sha1m` / `sha1h` / `sha1su0` / `sha1su1`.
    aarch64_crypto,
    /// x86-64's `sha1rnds4` / `sha1nexte` / `sha1msg1` / `sha1msg2`.
    x86_sha_ni,
};

/// What the processor turned out to have.
///
/// The answer is a property of the machine, so it is computed on the first
/// call and kept. That one cached word is the only thing in this package that
/// outlives a call without a caller holding it.
pub fn backend() Backend {
    const cached = detected.load(.monotonic);
    if (cached != unknown) return @enumFromInt(cached);
    const found = detect();
    detected.store(@intFromEnum(found), .monotonic);
    return found;
}

const unknown: u8 = 0xff;
var detected: std.atomic.Value(u8) = .init(unknown);

/// Whether the hardware arms exist in this build at all.
///
/// They are written as assembly, and the self-hosted x86-64 code generator has
/// no encoding for `sha1rnds4` and its neighbours, so a build that uses it
/// would not compile rather than run slower. The condition is the code
/// generator and not the target, which in practice means a Debug x86-64 build
/// takes the software rounds and an optimised one takes the instructions.
const hardware_arms_compile = builtin.zig_backend == .stage2_llvm;

fn detect() Backend {
    if (!hardware_arms_compile) return .software;
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => {
            if (hasAarch64Sha1()) return .aarch64_crypto;
            return .software;
        },
        .x86_64 => {
            if (hasX86Sha()) return .x86_sha_ni;
            return .software;
        },
        else => return .software,
    }
}

/// Whether this aarch64 processor implements `FEAT_SHA1`.
///
/// Darwin answers through `sysctlbyname`, Linux through the auxiliary vector's
/// hardware capability word. Anywhere else the question is only what the
/// compiler was told, which is a floor rather than an answer, so a target
/// built without the feature takes the software rounds.
fn hasAarch64Sha1() bool {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            var value: u32 = 0;
            var len: usize = @sizeOf(u32);
            const rc = std.c.sysctlbyname("hw.optional.arm.FEAT_SHA1", &value, &len, null, 0);
            if (rc != 0) return builtin.cpu.has(.aarch64, .sha2);
            return value != 0;
        },
        .linux => {
            const hwcap = std.os.linux.getauxval(std.elf.AT_HWCAP);
            // HWCAP_SHA1 is bit 5 of AT_HWCAP on aarch64.
            return hwcap & (1 << 5) != 0;
        },
        else => return builtin.cpu.has(.aarch64, .sha2),
    }
}

/// Whether this x86-64 processor implements the SHA extensions, and the
/// `pshufb` the byte-swap needs.
fn hasX86Sha() bool {
    const max_leaf = cpuid(0, 0)[0];
    if (max_leaf < 7) return false;
    // Leaf 1, ECX bit 9: SSSE3.
    if (cpuid(1, 0)[2] & (1 << 9) == 0) return false;
    // Leaf 7 subleaf 0, EBX bit 29: SHA.
    return cpuid(7, 0)[1] & (1 << 29) != 0;
}

fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ eax, ebx, ecx, edx };
}

/// One block.
fn compress(s: *[5]u32, block: *const [Sha1.block_length]u8) void {
    compressBlocks(s, block);
}

/// Whole blocks, which is where the hardware arms earn their keep.
fn compressBlocks(s: *[5]u32, blocks: []const u8) void {
    std.debug.assert(blocks.len % Sha1.block_length == 0);
    if (blocks.len == 0) return;
    switch (backend()) {
        .software => compressSoftware(s, blocks),
        .aarch64_crypto => if (hardware_arms_compile and
            (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be))
        {
            compressAarch64(s, blocks);
        } else unreachable,
        .x86_sha_ni => if (hardware_arms_compile and builtin.cpu.arch == .x86_64) {
            compressX86(s, blocks);
        } else unreachable,
    }
}

/// The eighty rounds, with the sixteen-word circular message schedule.
fn compressSoftware(s: *[5]u32, blocks: []const u8) void {
    var offset: usize = 0;
    while (offset < blocks.len) : (offset += Sha1.block_length) {
        const block = blocks[offset..][0..Sha1.block_length];
        var w: [16]u32 = undefined;
        inline for (0..16) |i| {
            w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .big);
        }

        var a = s[0];
        var b = s[1];
        var c = s[2];
        var d = s[3];
        var e = s[4];

        inline for (0..80) |t| {
            if (t >= 16) {
                const mixed = w[(t + 13) & 15] ^ w[(t + 8) & 15] ^ w[(t + 2) & 15] ^ w[t & 15];
                w[t & 15] = std.math.rotl(u32, mixed, 1);
            }
            const f: u32, const k: u32 = switch (t / 20) {
                0 => .{ (b & c) | (~b & d), 0x5A827999 },
                1 => .{ b ^ c ^ d, 0x6ED9EBA1 },
                2 => .{ (b & c) | (b & d) | (c & d), 0x8F1BBCDC },
                else => .{ b ^ c ^ d, 0xCA62C1D6 },
            };
            const next = std.math.rotl(u32, a, 5) +% f +% e +% k +% w[t & 15];
            e = d;
            d = c;
            c = std.math.rotl(u32, b, 30);
            b = a;
            a = next;
        }

        s[0] +%= a;
        s[1] +%= b;
        s[2] +%= c;
        s[3] +%= d;
        s[4] +%= e;
    }
}

/// The round constants, broadcast into the four lanes by the arms below.
const round_constants: [4]u32 align(16) = .{
    0x5A827999,
    0x6ED9EBA1,
    0x8F1BBCDC,
    0xCA62C1D6,
};

/// aarch64's SHA-1 instructions.
///
/// `sha1h` takes the rotate of `a` by thirty into the other `e`, `sha1c`,
/// `sha1p` and `sha1m` do four rounds of one of the three round functions,
/// and `sha1su0` with `sha1su1` together expand the next four message words.
/// The state is four lanes of `ABCD` plus a scalar `E`, so the message
/// schedule and the rounds run a group apart and the two `E` registers
/// alternate.
fn compressAarch64(s: *[5]u32, blocks: []const u8) void {
    var p = blocks.ptr;
    var left = blocks.len / Sha1.block_length;
    asm volatile (
        \\ .arch_extension crypto
        \\ ld1     {v20.4s}, [%[k]]
        \\ dup     v24.4s, v20.s[0]
        \\ dup     v25.4s, v20.s[1]
        \\ dup     v26.4s, v20.s[2]
        \\ dup     v27.4s, v20.s[3]
        \\ ld1     {v0.4s}, [%[st]]
        \\ ldr     s1, [%[st], #16]
        \\1:
        \\ ld1     {v4.4s, v5.4s, v6.4s, v7.4s}, [%[p]], #64
        \\ rev32   v4.16b, v4.16b
        \\ rev32   v5.16b, v5.16b
        \\ rev32   v6.16b, v6.16b
        \\ rev32   v7.16b, v7.16b
        \\ mov     v3.16b, v0.16b
        \\ mov     v28.16b, v1.16b
        \\ add     v16.4s, v4.4s, v24.4s
        \\ add     v17.4s, v5.4s, v24.4s
        \\ sha1h   s2, s0
        \\ sha1c   q0, s1, v16.4s
        \\ add     v16.4s, v6.4s, v24.4s
        \\ sha1su0 v4.4s, v5.4s, v6.4s
        \\ sha1h   s1, s0
        \\ sha1c   q0, s2, v17.4s
        \\ add     v17.4s, v7.4s, v24.4s
        \\ sha1su1 v4.4s, v7.4s
        \\ sha1su0 v5.4s, v6.4s, v7.4s
        \\ sha1h   s2, s0
        \\ sha1c   q0, s1, v16.4s
        \\ add     v16.4s, v4.4s, v24.4s
        \\ sha1su1 v5.4s, v4.4s
        \\ sha1su0 v6.4s, v7.4s, v4.4s
        \\ sha1h   s1, s0
        \\ sha1c   q0, s2, v17.4s
        \\ add     v17.4s, v5.4s, v25.4s
        \\ sha1su1 v6.4s, v5.4s
        \\ sha1su0 v7.4s, v4.4s, v5.4s
        \\ sha1h   s2, s0
        \\ sha1c   q0, s1, v16.4s
        \\ add     v16.4s, v6.4s, v25.4s
        \\ sha1su1 v7.4s, v6.4s
        \\ sha1su0 v4.4s, v5.4s, v6.4s
        \\ sha1h   s1, s0
        \\ sha1p   q0, s2, v17.4s
        \\ add     v17.4s, v7.4s, v25.4s
        \\ sha1su1 v4.4s, v7.4s
        \\ sha1su0 v5.4s, v6.4s, v7.4s
        \\ sha1h   s2, s0
        \\ sha1p   q0, s1, v16.4s
        \\ add     v16.4s, v4.4s, v25.4s
        \\ sha1su1 v5.4s, v4.4s
        \\ sha1su0 v6.4s, v7.4s, v4.4s
        \\ sha1h   s1, s0
        \\ sha1p   q0, s2, v17.4s
        \\ add     v17.4s, v5.4s, v25.4s
        \\ sha1su1 v6.4s, v5.4s
        \\ sha1su0 v7.4s, v4.4s, v5.4s
        \\ sha1h   s2, s0
        \\ sha1p   q0, s1, v16.4s
        \\ add     v16.4s, v6.4s, v26.4s
        \\ sha1su1 v7.4s, v6.4s
        \\ sha1su0 v4.4s, v5.4s, v6.4s
        \\ sha1h   s1, s0
        \\ sha1p   q0, s2, v17.4s
        \\ add     v17.4s, v7.4s, v26.4s
        \\ sha1su1 v4.4s, v7.4s
        \\ sha1su0 v5.4s, v6.4s, v7.4s
        \\ sha1h   s2, s0
        \\ sha1m   q0, s1, v16.4s
        \\ add     v16.4s, v4.4s, v26.4s
        \\ sha1su1 v5.4s, v4.4s
        \\ sha1su0 v6.4s, v7.4s, v4.4s
        \\ sha1h   s1, s0
        \\ sha1m   q0, s2, v17.4s
        \\ add     v17.4s, v5.4s, v26.4s
        \\ sha1su1 v6.4s, v5.4s
        \\ sha1su0 v7.4s, v4.4s, v5.4s
        \\ sha1h   s2, s0
        \\ sha1m   q0, s1, v16.4s
        \\ add     v16.4s, v6.4s, v26.4s
        \\ sha1su1 v7.4s, v6.4s
        \\ sha1su0 v4.4s, v5.4s, v6.4s
        \\ sha1h   s1, s0
        \\ sha1m   q0, s2, v17.4s
        \\ add     v17.4s, v7.4s, v27.4s
        \\ sha1su1 v4.4s, v7.4s
        \\ sha1su0 v5.4s, v6.4s, v7.4s
        \\ sha1h   s2, s0
        \\ sha1m   q0, s1, v16.4s
        \\ add     v16.4s, v4.4s, v27.4s
        \\ sha1su1 v5.4s, v4.4s
        \\ sha1su0 v6.4s, v7.4s, v4.4s
        \\ sha1h   s1, s0
        \\ sha1p   q0, s2, v17.4s
        \\ add     v17.4s, v5.4s, v27.4s
        \\ sha1su1 v6.4s, v5.4s
        \\ sha1su0 v7.4s, v4.4s, v5.4s
        \\ sha1h   s2, s0
        \\ sha1p   q0, s1, v16.4s
        \\ add     v16.4s, v6.4s, v27.4s
        \\ sha1su1 v7.4s, v6.4s
        \\ sha1h   s1, s0
        \\ sha1p   q0, s2, v17.4s
        \\ add     v17.4s, v7.4s, v27.4s
        \\ sha1h   s2, s0
        \\ sha1p   q0, s1, v16.4s
        \\ sha1h   s1, s0
        \\ sha1p   q0, s2, v17.4s
        \\ add     v1.4s, v1.4s, v28.4s
        \\ add     v0.4s, v0.4s, v3.4s
        \\ sub     %[left], %[left], #1
        \\ cbnz    %[left], 1b
        \\ st1     {v0.4s}, [%[st]]
        \\ str     s1, [%[st], #16]
        : [p] "+r" (p),
          [left] "+r" (left),
        : [st] "r" (s),
          [k] "r" (&round_constants),
        : .{
          .memory = true,
          .v0 = true,
          .v1 = true,
          .v2 = true,
          .v3 = true,
          .v4 = true,
          .v5 = true,
          .v6 = true,
          .v7 = true,
          .v16 = true,
          .v17 = true,
          .v20 = true,
          .v24 = true,
          .v25 = true,
          .v26 = true,
          .v27 = true,
          .v28 = true,
        });
}

/// The sixteen-byte reversal `pshufb` applies to each loaded quadword, which
/// puts the four message words in the order the round instruction reads them:
/// `W0` in the high lane.
const x86_byte_swap: [16]u8 align(16) = .{
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
};

/// x86-64's SHA extensions.
///
/// `sha1rnds4` does four rounds with the round function chosen by its
/// immediate, `sha1nexte` folds the rotated `A` into the next four message
/// words, and `sha1msg1` with `sha1msg2` expand the schedule. `ABCD` is held
/// reversed, `A` in the high lane, which is where both instructions read it.
fn compressX86(s: *[5]u32, blocks: []const u8) void {
    var p = blocks.ptr;
    var left = blocks.len / Sha1.block_length;
    // `E` travels in the high lane of a vector. Rather than reach for the
    // SSE4.1 insert and extract, it is carried through a sixteen-byte slot.
    var e_slot: [4]u32 align(16) = .{ 0, 0, 0, s[4] };
    asm volatile (
        \\ movdqu  (%[st]), %%xmm0
        \\ pshufd  $0x1b, %%xmm0, %%xmm0
        \\ movdqu  (%[e]), %%xmm1
        \\ movdqu  (%[mask]), %%xmm9
        \\1:
        \\ movdqa  %%xmm0, %%xmm7
        \\ movdqa  %%xmm1, %%xmm8
        \\ movdqu  0(%[p]), %%xmm3
        \\ pshufb  %%xmm9, %%xmm3
        \\ paddd   %%xmm3, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1rnds4 $0, %%xmm1, %%xmm0
        \\ movdqu  16(%[p]), %%xmm4
        \\ pshufb  %%xmm9, %%xmm4
        \\ sha1nexte %%xmm4, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1rnds4 $0, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm4, %%xmm3
        \\ movdqu  32(%[p]), %%xmm5
        \\ pshufb  %%xmm9, %%xmm5
        \\ sha1nexte %%xmm5, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1rnds4 $0, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm5, %%xmm4
        \\ pxor    %%xmm5, %%xmm3
        \\ movdqu  48(%[p]), %%xmm6
        \\ pshufb  %%xmm9, %%xmm6
        \\ sha1nexte %%xmm6, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm6, %%xmm3
        \\ sha1rnds4 $0, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm6, %%xmm5
        \\ pxor    %%xmm6, %%xmm4
        \\ sha1nexte %%xmm3, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm3, %%xmm4
        \\ sha1rnds4 $0, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm3, %%xmm6
        \\ pxor    %%xmm3, %%xmm5
        \\ sha1nexte %%xmm4, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm4, %%xmm5
        \\ sha1rnds4 $1, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm4, %%xmm3
        \\ pxor    %%xmm4, %%xmm6
        \\ sha1nexte %%xmm5, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm5, %%xmm6
        \\ sha1rnds4 $1, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm5, %%xmm4
        \\ pxor    %%xmm5, %%xmm3
        \\ sha1nexte %%xmm6, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm6, %%xmm3
        \\ sha1rnds4 $1, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm6, %%xmm5
        \\ pxor    %%xmm6, %%xmm4
        \\ sha1nexte %%xmm3, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm3, %%xmm4
        \\ sha1rnds4 $1, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm3, %%xmm6
        \\ pxor    %%xmm3, %%xmm5
        \\ sha1nexte %%xmm4, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm4, %%xmm5
        \\ sha1rnds4 $1, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm4, %%xmm3
        \\ pxor    %%xmm4, %%xmm6
        \\ sha1nexte %%xmm5, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm5, %%xmm6
        \\ sha1rnds4 $2, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm5, %%xmm4
        \\ pxor    %%xmm5, %%xmm3
        \\ sha1nexte %%xmm6, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm6, %%xmm3
        \\ sha1rnds4 $2, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm6, %%xmm5
        \\ pxor    %%xmm6, %%xmm4
        \\ sha1nexte %%xmm3, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm3, %%xmm4
        \\ sha1rnds4 $2, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm3, %%xmm6
        \\ pxor    %%xmm3, %%xmm5
        \\ sha1nexte %%xmm4, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm4, %%xmm5
        \\ sha1rnds4 $2, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm4, %%xmm3
        \\ pxor    %%xmm4, %%xmm6
        \\ sha1nexte %%xmm5, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm5, %%xmm6
        \\ sha1rnds4 $2, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm5, %%xmm4
        \\ pxor    %%xmm5, %%xmm3
        \\ sha1nexte %%xmm6, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm6, %%xmm3
        \\ sha1rnds4 $3, %%xmm2, %%xmm0
        \\ sha1msg1 %%xmm6, %%xmm5
        \\ pxor    %%xmm6, %%xmm4
        \\ sha1nexte %%xmm3, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm3, %%xmm4
        \\ sha1rnds4 $3, %%xmm1, %%xmm0
        \\ sha1msg1 %%xmm3, %%xmm6
        \\ pxor    %%xmm3, %%xmm5
        \\ sha1nexte %%xmm4, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1msg2 %%xmm4, %%xmm5
        \\ sha1rnds4 $3, %%xmm2, %%xmm0
        \\ pxor    %%xmm4, %%xmm6
        \\ sha1nexte %%xmm5, %%xmm1
        \\ movdqa  %%xmm0, %%xmm2
        \\ sha1msg2 %%xmm5, %%xmm6
        \\ sha1rnds4 $3, %%xmm1, %%xmm0
        \\ sha1nexte %%xmm6, %%xmm2
        \\ movdqa  %%xmm0, %%xmm1
        \\ sha1rnds4 $3, %%xmm2, %%xmm0
        \\ sha1nexte %%xmm8, %%xmm1
        \\ paddd   %%xmm7, %%xmm0
        \\ addq    $64, %[p]
        \\ decq    %[left]
        \\ jnz     1b
        \\ pshufd  $0x1b, %%xmm0, %%xmm0
        \\ movdqu  %%xmm0, (%[st])
        \\ movdqu  %%xmm1, (%[e])
        : [p] "+r" (p),
          [left] "+r" (left),
        : [st] "r" (s),
          [e] "r" (&e_slot),
          [mask] "r" (&x86_byte_swap),
        : .{
          .memory = true,
          .cc = true,
          .xmm0 = true,
          .xmm1 = true,
          .xmm2 = true,
          .xmm3 = true,
          .xmm4 = true,
          .xmm5 = true,
          .xmm6 = true,
          .xmm7 = true,
          .xmm8 = true,
          .xmm9 = true,
        });
    s[4] = e_slot[3];
}

//=========================================================================
// Tests
//=========================================================================

const testing = std.testing;

fn hexDigest(bytes: []const u8) [40]u8 {
    var out: [20]u8 = undefined;
    Sha1.hash(bytes, &out, .{});
    var text: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x}", .{&out}) catch unreachable;
    return text;
}

test "FIPS 180 test vectors" {
    // The three vectors of FIPS 180-4's appendix, and the millionth-'a' one.
    try testing.expectEqualStrings(
        "a9993e364706816aba3e25717850c26c9cd0d89d",
        &hexDigest("abc"),
    );
    try testing.expectEqualStrings(
        "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
        &hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    );
    try testing.expectEqualStrings(
        "a49b2446a02c645bf419f995b67091253a04a259",
        &hexDigest("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" ++
            "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
    );
    try testing.expectEqualStrings(
        "da39a3ee5e6b4b0d3255bfef95601890afd80709",
        &hexDigest(""),
    );

    var d: Sha1 = .init(.{});
    var chunk: [1000]u8 = @splat('a');
    for (0..1000) |_| d.update(&chunk);
    var out: [20]u8 = undefined;
    d.final(&out);
    var text: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&text, "{x}", .{&out});
    try testing.expectEqualStrings("34aa973cd4c4daa4f61eeb2bdbad27316534016f", &text);
}

test "every length from nothing to four kilobytes agrees with the standard library" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_51a1);
    const random = prng.random();
    var buf: [4096]u8 = undefined;
    random.bytes(&buf);

    for (0..buf.len + 1) |len| {
        var mine: [20]u8 = undefined;
        Sha1.hash(buf[0..len], &mine, .{});
        var theirs: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(buf[0..len], &theirs, .{});
        try testing.expectEqualSlices(u8, &theirs, &mine);
    }
}

test "a split feed gives the same digest as one call" {
    var prng: std.Random.DefaultPrng = .init(0x5911_7);
    const random = prng.random();
    var buf: [9001]u8 = undefined;
    random.bytes(&buf);

    var whole: [20]u8 = undefined;
    Sha1.hash(&buf, &whole, .{});

    // Splits that land inside a block, on a block edge, and past several.
    for ([_]usize{ 0, 1, 7, 55, 63, 64, 65, 127, 128, 1000, 4096, 9000, 9001 }) |cut| {
        var d: Sha1 = .init(.{});
        d.update(buf[0..cut]);
        d.update(buf[cut..]);
        var got: [20]u8 = undefined;
        d.final(&got);
        try testing.expectEqualSlices(u8, &whole, &got);
    }

    // And one byte at a time, which exercises the partial-block path on
    // every single call.
    var byte_at_a_time: Sha1 = .init(.{});
    for (buf) |byte| byte_at_a_time.update(&[_]u8{byte});
    var got: [20]u8 = undefined;
    byte_at_a_time.final(&got);
    try testing.expectEqualSlices(u8, &whole, &got);
}

test "large inputs agree with the standard library" {
    const gpa = testing.allocator;
    for ([_]usize{ 65_536, 1_000_003, 4 * 1024 * 1024 }) |len| {
        const buf = try gpa.alloc(u8, len);
        defer gpa.free(buf);
        var prng: std.Random.DefaultPrng = .init(len);
        prng.random().bytes(buf);

        var mine: [20]u8 = undefined;
        Sha1.hash(buf, &mine, .{});
        var theirs: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(buf, &theirs, .{});
        try testing.expectEqualSlices(u8, &theirs, &mine);
    }
}

test "the software rounds and the hardware arm agree" {
    // Whichever arm `backend` chose above, this runs the software one
    // explicitly, so a machine with the instructions checks both.
    var prng: std.Random.DefaultPrng = .init(0x50f7);
    const random = prng.random();
    var buf: [1024]u8 = undefined;
    random.bytes(&buf);

    var blocks: usize = 0;
    while (blocks <= 16) : (blocks += 1) {
        var soft: [5]u32 = Sha1.initial;
        compressSoftware(&soft, buf[0 .. blocks * 64]);
        var fast: [5]u32 = Sha1.initial;
        if (blocks != 0) compressBlocks(&fast, buf[0 .. blocks * 64]);
        try testing.expectEqualSlices(u32, &soft, &fast);
    }
}
