//! DEFLATE (RFC 1951) in zlib's wrapper (RFC 1950), decoded into a buffer
//! that holds the whole result — as every pack entry is decoded, its size
//! stated in its header. With the output in one piece a match is copied
//! from what was decoded before it and no window is kept; the inner loop
//! takes its bits from a 64-bit buffer refilled eight bytes at a time and
//! copies matches eight bytes at a time, as zlib's `inflate_fast` and
//! libdeflate decode, and falls back to a careful loop near either end.
//! The input is any `std.Io.Reader`, read straight from its buffer; what the
//! stream did not use is left in it.
//!
//! The rules are zlib's, which git's packs are written and read with: a
//! Huffman code may be incomplete only when it is a single code of one bit,
//! a distance may not reach before the output's start, the header must say
//! DEFLATE with a window of at most 32 KiB and no preset dictionary, and the
//! Adler-32 at the end must be the output's.

const std = @import("std");
const Io = std.Io;

/// Errors from decoding.
pub const Error = error{
    /// Not a zlib stream, or not DEFLATE: a header, a block type, a Huffman
    /// code or a distance that is not one, or a checksum that does not
    /// match.
    CorruptStream,
    /// The stream decodes to more bytes than the output holds.
    OutputTooLong,
    /// The input ended before the stream did.
    EndOfStream,
    /// The reader failed; its own error says why.
    ReadFailed,
};

const litlen_table_bits = 9;
const dist_table_bits = 7;
const precode_table_bits = 7;

// Room for the main table and every subtable a code can need: each symbol
// longer than the main table's bits can add at most one subtable of
// 2^(15 - bits) entries.
const litlen_enough = (1 << litlen_table_bits) + 288 * (1 << (15 - litlen_table_bits));
const dist_enough = (1 << dist_table_bits) + 32 * (1 << (15 - dist_table_bits));
const precode_enough = 1 << precode_table_bits;

/// What a table entry decodes to.
const Kind = enum(u3) { literal, length, end, subtable, invalid };

/// A table entry: bits 0-3 the bits its code takes, 4-7 the extra bits after
/// it (or a subtable's bits), 8-10 its kind, 16-31 its value: a literal, a
/// length's or distance's base, a subtable's start.
const Entry = u32;

inline fn entry(kind: Kind, bits: u32, extra: u32, value: u32) Entry {
    return bits | (extra << 4) | (@as(u32, @intFromEnum(kind)) << 8) | (value << 16);
}
inline fn entryBits(e: Entry) u6 {
    return @intCast(e & 15);
}
inline fn entryExtra(e: Entry) u6 {
    return @intCast((e >> 4) & 15);
}
inline fn entryKind(e: Entry) Kind {
    return @enumFromInt((e >> 8) & 7);
}
inline fn entryValue(e: Entry) u32 {
    return e >> 16;
}

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const Alphabet = enum { precode, litlen, dist };

fn symbolEntry(comptime alphabet: Alphabet, sym: usize, bits: u32) Entry {
    return switch (alphabet) {
        .precode => entry(.literal, bits, 0, @intCast(sym)),
        .litlen => if (sym < 256)
            entry(.literal, bits, 0, @intCast(sym))
        else if (sym == 256)
            entry(.end, bits, 0, 0)
        else if (sym < 286)
            entry(.length, bits, length_extra[sym - 257], length_base[sym - 257])
        else
            entry(.invalid, bits, 0, 0),
        .dist => if (sym < 30)
            entry(.literal, bits, dist_extra[sym], dist_base[sym])
        else
            entry(.invalid, bits, 0, 0),
    };
}

/// Build the decoding table for the code with lengths `lens`, as zlib's
/// `inflate_table` accepts it. A code longer than the main table's bits
/// continues in a subtable of `sub_bits` bits for its first bits: the
/// codes are taken in canonical order, shortest first, in which those that
/// share their first bits come together, so each subtable is made whole
/// when its first code arrives.
fn build(comptime alphabet: Alphabet, table: []Entry, lens: []const u8, comptime table_bits: u6) Error!void {
    const sub_bits = 15 - table_bits;
    var count = [_]u16{0} ** 16;
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var max: usize = 0;
    for (1..16) |l| {
        if (count[l] != 0) max = l;
    }
    const main_len = @as(usize, 1) << table_bits;
    if (max == 0) {
        // No codes at all: anything read is an error.
        @memset(table[0..main_len], entry(.invalid, 1, 0, 0));
        return;
    }
    var left: i32 = 1;
    for (1..16) |l| {
        left <<= 1;
        left -= count[l];
        if (left < 0) return error.CorruptStream;
    }
    if (left > 0) {
        // Incomplete: only a single one-bit code, and never the precode.
        if (alphabet == .precode or max != 1) return error.CorruptStream;
        @memset(table[0..main_len], entry(.invalid, 1, 0, 0));
    }

    // The symbols by length, then by value: canonical order.
    var offset: [16]u16 = undefined;
    offset[1] = 0;
    for (2..16) |l| offset[l] = offset[l - 1] + count[l - 1];
    var sorted: [288]u16 = undefined;
    for (lens, 0..) |l, sym| {
        if (l == 0) continue;
        sorted[offset[l]] = @intCast(sym);
        offset[l] += 1;
    }
    const total = offset[15];

    var code: u32 = 0;
    var len: usize = 1;
    var remaining: u16 = count[1];
    var sub_prefix: usize = std.math.maxInt(usize);
    var sub_start: usize = main_len;
    var next_sub: usize = main_len;
    for (sorted[0..total]) |sym| {
        while (remaining == 0) {
            code <<= 1;
            len += 1;
            remaining = count[len];
        }
        remaining -= 1;
        const rev = reverse(@intCast(code), len);
        code += 1;
        if (len <= table_bits) {
            const e = symbolEntry(alphabet, sym, @intCast(len));
            var i: usize = rev;
            while (i < main_len) : (i += @as(usize, 1) << @intCast(len)) table[i] = e;
        } else {
            const prefix = rev & (main_len - 1);
            if (prefix != sub_prefix) {
                sub_prefix = prefix;
                sub_start = next_sub;
                next_sub += 1 << sub_bits;
                table[prefix] = entry(.subtable, table_bits, sub_bits, @intCast(sub_start));
            }
            const rest: u6 = @intCast(len - table_bits);
            const e = symbolEntry(alphabet, sym, rest);
            var i: usize = rev >> table_bits;
            while (i < (1 << sub_bits)) : (i += @as(usize, 1) << rest) table[sub_start + i] = e;
        }
    }
}

fn reverse(code: u16, len: usize) usize {
    return @as(usize, @bitReverse(code)) >> @intCast(16 - len);
}

/// Decoding tables, kept between streams: about 60 KiB.
pub const Decoder = struct {
    litlen: [litlen_enough]Entry = undefined,
    dist: [dist_enough]Entry = undefined,
    precode: [precode_enough]Entry = undefined,
    fixed_litlen: [litlen_enough]Entry = undefined,
    fixed_dist: [dist_enough]Entry = undefined,
    fixed_built: bool = false,

    /// Decode the zlib stream at `r`'s position into `out`: how many bytes
    /// it decoded to, all at the front of `out`. `r` is left just past the
    /// stream's checksum.
    pub fn zlib(d: *Decoder, r: *Io.Reader, out: []u8) Error!usize {
        var s: State = .init(r, out);
        defer s.giveBack();
        try s.need(16);
        const cmf: u8 = @truncate(s.bitbuf);
        const flg: u8 = @truncate(s.bitbuf >> 8);
        s.consume(16);
        if (cmf & 0x0f != 8 or cmf >> 4 > 7 or flg & 0x20 != 0 or ((@as(u16, cmf) << 8) | flg) % 31 != 0) return error.CorruptStream;
        try d.blocks(&s);
        s.giveBack();
        const want = r.takeInt(u32, .big) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => error.ReadFailed,
        };
        s.in = r.buffered();
        if (adler32(out[0..s.op]) != want) return error.CorruptStream;
        return s.op;
    }

    /// Decode raw DEFLATE, with no wrapper, likewise.
    pub fn raw(d: *Decoder, r: *Io.Reader, out: []u8) Error!usize {
        var s: State = .init(r, out);
        defer s.giveBack();
        try d.blocks(&s);
        return s.op;
    }

    fn blocks(d: *Decoder, s: *State) Error!void {
        while (true) {
            try s.need(3);
            const final = s.bitbuf & 1 != 0;
            const kind: u2 = @truncate(s.bitbuf >> 1);
            s.consume(3);
            switch (kind) {
                0 => try s.stored(),
                1 => {
                    if (!d.fixed_built) d.buildFixed();
                    try s.huffman(&d.fixed_litlen, &d.fixed_dist);
                },
                2 => {
                    try d.dynamicHeader(s);
                    try s.huffman(&d.litlen, &d.dist);
                },
                3 => return error.CorruptStream,
            }
            if (final) return;
        }
    }

    fn buildFixed(d: *Decoder) void {
        var lens: [288]u8 = undefined;
        @memset(lens[0..144], 8);
        @memset(lens[144..256], 9);
        @memset(lens[256..280], 7);
        @memset(lens[280..288], 8);
        build(.litlen, &d.fixed_litlen, &lens, litlen_table_bits) catch unreachable;
        var dlens = [_]u8{5} ** 32;
        build(.dist, &d.fixed_dist, &dlens, dist_table_bits) catch unreachable;
        d.fixed_built = true;
    }

    fn dynamicHeader(d: *Decoder, s: *State) Error!void {
        try s.need(14);
        const hlit: usize = @as(usize, @truncate(s.bitbuf & 31)) + 257;
        const hdist: usize = @as(usize, @truncate((s.bitbuf >> 5) & 31)) + 1;
        const hclen: usize = @as(usize, @truncate((s.bitbuf >> 10) & 15)) + 4;
        s.consume(14);
        // zlib refuses more than 286 and 30 before reading on.
        if (hlit > 286 or hdist > 30) return error.CorruptStream;
        const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
        var pre = [_]u8{0} ** 19;
        for (order[0..hclen]) |at| {
            try s.need(3);
            pre[at] = @truncate(s.bitbuf & 7);
            s.consume(3);
        }
        try build(.precode, &d.precode, &pre, precode_table_bits);

        var lens: [286 + 30]u8 = undefined;
        const total = hlit + hdist;
        var i: usize = 0;
        while (i < total) {
            try s.fillSome(7 + 7);
            const e = d.precode[s.bitbuf & (precode_enough - 1)];
            const bits = entryBits(e);
            if (entryKind(e) == .invalid or bits > s.bitsleft) return if (entryKind(e) == .invalid) error.CorruptStream else error.EndOfStream;
            s.consume(bits);
            const sym = entryValue(e);
            if (sym < 16) {
                lens[i] = @intCast(sym);
                i += 1;
                continue;
            }
            var repeat: usize = undefined;
            var value: u8 = 0;
            switch (sym) {
                16 => {
                    if (i == 0) return error.CorruptStream;
                    try s.need(2);
                    repeat = 3 + @as(usize, @truncate(s.bitbuf & 3));
                    s.consume(2);
                    value = lens[i - 1];
                },
                17 => {
                    try s.need(3);
                    repeat = 3 + @as(usize, @truncate(s.bitbuf & 7));
                    s.consume(3);
                },
                18 => {
                    try s.need(7);
                    repeat = 11 + @as(usize, @truncate(s.bitbuf & 127));
                    s.consume(7);
                },
                else => unreachable,
            }
            if (i + repeat > total) return error.CorruptStream;
            @memset(lens[i..][0..repeat], value);
            i += repeat;
        }
        if (lens[256] == 0) return error.CorruptStream;
        try build(.litlen, &d.litlen, lens[0..hlit], litlen_table_bits);
        try build(.dist, &d.dist, lens[hlit..total], dist_table_bits);
    }
};

/// Where decoding is: the bits in hand, the input's buffer and how far
/// into it, the output and how far into it.
const State = struct {
    r: *Io.Reader,
    in: []const u8,
    ip: usize = 0,
    bitbuf: u64 = 0,
    /// How many of `bitbuf`'s low bits are the stream's. Bits above may be
    /// the next input byte's, loaded ahead and not yet counted.
    bitsleft: u6 = 0,
    out: []u8,
    op: usize = 0,

    fn init(r: *Io.Reader, out: []u8) State {
        return .{ .r = r, .in = r.buffered(), .out = out };
    }

    inline fn consume(s: *State, n: u6) void {
        s.bitbuf >>= n;
        s.bitsleft -= n;
    }

    /// Hand the reader back the input not used: the whole bytes still in
    /// `bitbuf`, and what was never loaded.
    fn giveBack(s: *State) void {
        s.r.toss(s.ip);
        const back: usize = s.bitsleft >> 3;
        s.r.seek -= back;
        s.bitsleft &= 7;
        s.bitbuf &= (@as(u64, 1) << s.bitsleft) - 1;
        s.ip = 0;
        s.in = s.r.buffered();
    }

    /// More input in the buffer; `false` at the end of the stream.
    fn more(s: *State) Error!bool {
        s.giveBack();
        const before = s.in.len;
        while (true) {
            s.r.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    s.in = s.r.buffered();
                    return s.in.len > before;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            s.in = s.r.buffered();
            if (s.in.len > before) return true;
        }
    }

    /// Load bytes one at a time until `n` bits are in hand, or the input
    /// ends.
    fn fillSome(s: *State, n: u6) Error!void {
        if (s.bitsleft < n and s.ip + 8 <= s.in.len) {
            s.bitbuf |= std.mem.readInt(u64, s.in[s.ip..][0..8], .little) << s.bitsleft;
            const add = (63 - @as(u32, s.bitsleft)) >> 3;
            s.ip += add;
            s.bitsleft += @intCast(add << 3);
            return;
        }
        while (s.bitsleft < n) {
            if (s.ip == s.in.len) {
                if (!try s.more()) return;
                continue;
            }
            s.bitbuf |= @as(u64, s.in[s.ip]) << s.bitsleft;
            s.ip += 1;
            s.bitsleft += 8;
        }
    }

    /// At least `n` bits in hand.
    fn need(s: *State, n: u6) Error!void {
        try s.fillSome(n);
        if (s.bitsleft < n) return error.EndOfStream;
    }

    fn stored(s: *State) Error!void {
        s.consume(s.bitsleft & 7);
        s.giveBack();
        const header = s.r.takeInt(u32, .little) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => error.ReadFailed,
        };
        const len: u16 = @truncate(header);
        const nlen: u16 = @truncate(header >> 16);
        if (len != ~nlen) return error.CorruptStream;
        if (s.op + len > s.out.len) return error.OutputTooLong;
        s.r.readSliceAll(s.out[s.op..][0..len]) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => error.ReadFailed,
        };
        s.op += len;
        s.in = s.r.buffered();
    }

    /// One Huffman-coded block.
    fn huffman(s: *State, litlen: []const Entry, dist: []const Entry) Error!void {
        const lmask: u64 = (1 << litlen_table_bits) - 1;
        const dmask: u64 = (1 << dist_table_bits) - 1;
        const out = s.out;
        while (true) {
            // The fast loop: eight input bytes to load and room for the
            // longest match and an eight-byte copy past it.
            var ip = s.ip;
            var op = s.op;
            var bitbuf = s.bitbuf;
            var bitsleft: u32 = s.bitsleft;
            const in = s.in;
            // Sixteen input bytes for two refills, and room for four
            // literals or the longest match and an eight-byte copy past it.
            fast: while (ip + 16 <= in.len and op + 258 + 8 <= out.len) {
                bitbuf |= std.mem.readInt(u64, in[ip..][0..8], .little) << @intCast(bitsleft);
                var add = (63 - bitsleft) >> 3;
                ip += add;
                bitsleft += add << 3;

                // Up to four literals from one refill.
                var e = litlen[@intCast(bitbuf & lmask)];
                var literals: u32 = 0;
                while (entryKind(e) == .literal) {
                    bitbuf >>= entryBits(e);
                    bitsleft -= entryBits(e);
                    out[op] = @intCast(entryValue(e));
                    op += 1;
                    literals += 1;
                    if (literals == 4 or bitsleft < 15) continue :fast;
                    e = litlen[@intCast(bitbuf & lmask)];
                }
                // A match takes up to 48 bits. More bits do not change the
                // ones the entry was looked up with.
                if (bitsleft < 48) {
                    bitbuf |= std.mem.readInt(u64, in[ip..][0..8], .little) << @intCast(bitsleft);
                    add = (63 - bitsleft) >> 3;
                    ip += add;
                    bitsleft += add << 3;
                }
                if (entryKind(e) == .subtable) {
                    bitbuf >>= litlen_table_bits;
                    bitsleft -= litlen_table_bits;
                    e = litlen[entryValue(e) + @as(usize, @intCast(bitbuf & ((@as(u64, 1) << entryExtra(e)) - 1)))];
                    if (entryKind(e) == .literal) {
                        bitbuf >>= entryBits(e);
                        bitsleft -= entryBits(e);
                        out[op] = @intCast(entryValue(e));
                        op += 1;
                        continue :fast;
                    }
                }
                bitbuf >>= entryBits(e);
                bitsleft -= entryBits(e);
                switch (entryKind(e)) {
                    .length => {
                        const extra = entryExtra(e);
                        const len = entryValue(e) + @as(u32, @intCast(bitbuf & ((@as(u64, 1) << extra) - 1)));
                        bitbuf >>= extra;
                        bitsleft -= extra;
                        var de = dist[@intCast(bitbuf & dmask)];
                        if (entryKind(de) == .subtable) {
                            bitbuf >>= dist_table_bits;
                            bitsleft -= dist_table_bits;
                            de = dist[entryValue(de) + @as(usize, @intCast(bitbuf & ((@as(u64, 1) << entryExtra(de)) - 1)))];
                        }
                        if (entryKind(de) != .literal) return error.CorruptStream;
                        bitbuf >>= entryBits(de);
                        bitsleft -= entryBits(de);
                        const dextra = entryExtra(de);
                        const distance = entryValue(de) + @as(u32, @intCast(bitbuf & ((@as(u64, 1) << dextra) - 1)));
                        bitbuf >>= dextra;
                        bitsleft -= dextra;
                        if (distance > op) return error.CorruptStream;
                        copyFast(out, op, distance, len);
                        op += len;
                    },
                    .end => {
                        s.ip = ip;
                        s.op = op;
                        s.bitbuf = bitbuf;
                        s.bitsleft = @intCast(bitsleft);
                        return;
                    },
                    .literal, .invalid, .subtable => return error.CorruptStream,
                }
            }
            s.ip = ip;
            s.op = op;
            s.bitbuf = bitbuf;
            s.bitsleft = @intCast(bitsleft);

            // The careful loop, one symbol, every bound checked.
            if (try s.slowSymbol(litlen, dist)) return;
        }
    }

    /// Decode one symbol near an end of the input or the output. Whether
    /// it ended the block.
    fn slowSymbol(s: *State, litlen: []const Entry, dist: []const Entry) Error!bool {
        const e = try s.decode(litlen, litlen_table_bits);
        switch (entryKind(e)) {
            .literal => {
                if (s.op >= s.out.len) return error.OutputTooLong;
                s.out[s.op] = @intCast(entryValue(e));
                s.op += 1;
                return false;
            },
            .end => return true,
            .length => {
                const extra = entryExtra(e);
                try s.need(extra);
                const len = entryValue(e) + @as(u32, @intCast(s.bitbuf & ((@as(u64, 1) << extra) - 1)));
                s.consume(extra);
                const de = try s.decode(dist, dist_table_bits);
                if (entryKind(de) != .literal) return error.CorruptStream;
                const dextra = entryExtra(de);
                try s.need(dextra);
                const distance = entryValue(de) + @as(u32, @intCast(s.bitbuf & ((@as(u64, 1) << dextra) - 1)));
                s.consume(dextra);
                if (distance > s.op) return error.CorruptStream;
                if (s.op + len > s.out.len) return error.OutputTooLong;
                var i: usize = 0;
                while (i < len) : (i += 1) s.out[s.op + i] = s.out[s.op + i - distance];
                s.op += len;
                return false;
            },
            .invalid, .subtable => return error.CorruptStream,
        }
    }

    /// The table entry for the next code, its bits consumed.
    fn decode(s: *State, table: []const Entry, comptime table_bits: u6) Error!Entry {
        try s.fillSome(15);
        var e = table[@intCast(s.bitbuf & ((1 << table_bits) - 1))];
        if (entryKind(e) == .subtable) {
            if (s.bitsleft < table_bits) return error.EndOfStream;
            const sub = e;
            e = table[entryValue(sub) + @as(usize, @intCast((s.bitbuf >> table_bits) & ((@as(u64, 1) << entryExtra(sub)) - 1)))];
            if (entryKind(e) == .invalid) return error.CorruptStream;
            if (table_bits + @as(u32, entryBits(e)) > s.bitsleft) return error.EndOfStream;
            s.consume(table_bits);
        }
        if (entryKind(e) == .invalid) return error.CorruptStream;
        if (entryBits(e) > s.bitsleft) return error.EndOfStream;
        s.consume(entryBits(e));
        return e;
    }
};

/// Copy a match of `len` from `distance` back, eight bytes at a time; up to
/// seven bytes past its end are written, which the caller leaves room for.
inline fn copyFast(out: []u8, op: usize, distance: usize, len: usize) void {
    const end = op + len;
    var dst = op;
    var src = op - distance;
    if (distance >= 8) {
        while (dst < end) {
            out[dst..][0..8].* = out[src..][0..8].*;
            dst += 8;
            src += 8;
        }
    } else if (distance == 1) {
        @memset(out[dst..end], out[src]);
    } else {
        while (dst < end) {
            out[dst] = out[src];
            dst += 1;
            src += 1;
        }
    }
}

/// Adler-32 (RFC 1950), thirty-two bytes at a time.
pub fn adler32(data: []const u8) u32 {
    const base = 65521;
    const nmax = 5552;
    var s1: u32 = 1;
    var s2: u32 = 0;
    var rest = data;
    const weights: @Vector(32, u32) = comptime blk: {
        var w: [32]u32 = undefined;
        for (&w, 0..) |*x, i| x.* = 32 - i;
        break :blk w;
    };
    while (rest.len >= 32) {
        const run = @min(rest.len, nmax) & ~@as(usize, 31);
        var i: usize = 0;
        while (i < run) : (i += 32) {
            const v: @Vector(32, u32) = @as(@Vector(32, u8), rest[i..][0..32].*);
            s2 += 32 * s1 + @reduce(.Add, v * weights);
            s1 += @reduce(.Add, v);
        }
        s1 %= base;
        s2 %= base;
        rest = rest[run..];
    }
    for (rest) |b| {
        s1 += b;
        s2 += s1;
    }
    s1 %= base;
    s2 %= base;
    return (s2 << 16) | s1;
}

const testing = std.testing;

/// Compress with the standard library, at `level`, in zlib's wrapper.
fn stdCompress(gpa: std.mem.Allocator, data: []const u8, level: std.compress.flate.Compress.Options) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&out.writer, window, .zlib, level);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

fn expectRoundTrip(gpa: std.mem.Allocator, data: []const u8, compressed: []const u8) !void {
    const d = try gpa.create(Decoder);
    defer gpa.destroy(d);
    d.* = .{};
    const out = try gpa.alloc(u8, data.len);
    defer gpa.free(out);
    // What follows the stream is left in the reader.
    const followed = try std.mem.concat(gpa, u8, &.{ compressed, "next" });
    defer gpa.free(followed);
    var r: Io.Reader = .fixed(followed);
    const n = try d.zlib(&r, out);
    try testing.expectEqual(data.len, n);
    try testing.expectEqualSlices(u8, data, out);
    try testing.expectEqualStrings("next", r.buffered());
}

test "what the standard library compresses, at every level, decodes to what it was, and the reader is left just past it" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    const text = try gpa.alloc(u8, 200_000);
    defer gpa.free(text);
    // Text that repeats at every distance, and noise.
    for (text, 0..) |*b, i| b.* = if (i % 5000 < 4000) "the quick brown fox jumps over "[i % 31] ^ @as(u8, @intCast((i / 997) % 3)) else random.int(u8);
    for ([_][]const u8{ "", "a", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", text[0..1000], text }) |data| {
        for ([_]std.compress.flate.Compress.Options{ .level_1, .level_4, .level_6, .level_9, .fastest, .best }) |level| {
            const compressed = try stdCompress(gpa, data, level);
            defer gpa.free(compressed);
            try expectRoundTrip(gpa, data, compressed);
        }
    }
}

test "a stream that decodes to more than the output holds, a wrong checksum and a cut stream are refused by name" {
    const gpa = testing.allocator;
    const data = "hello, hello, hello, hello\n";
    const compressed = try stdCompress(gpa, data, .level_6);
    defer gpa.free(compressed);
    const d = try gpa.create(Decoder);
    defer gpa.destroy(d);
    d.* = .{};
    var out: [64]u8 = undefined;
    var short: Io.Reader = .fixed(compressed);
    try testing.expectError(error.OutputTooLong, d.zlib(&short, out[0 .. data.len - 1]));
    const bad = try gpa.dupe(u8, compressed);
    defer gpa.free(bad);
    bad[bad.len - 1] ^= 1;
    var wrong: Io.Reader = .fixed(bad);
    try testing.expectError(error.CorruptStream, d.zlib(&wrong, &out));
    for (0..compressed.len) |cut| {
        var r: Io.Reader = .fixed(compressed[0..cut]);
        try testing.expectError(error.EndOfStream, d.zlib(&r, &out));
    }
    var header: Io.Reader = .fixed(&.{ 0x78, 0x9d, 0x01 });
    try testing.expectError(error.CorruptStream, d.zlib(&header, &out));
}

test "Adler-32 is zlib's, at every length" {
    var buf: [3000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i * 31 + 7);
    for ([_]usize{ 0, 1, 31, 32, 33, 100, 2999, 3000 }) |n| {
        try testing.expectEqual(std.hash.Adler32.hash(buf[0..n]), adler32(buf[0..n]));
    }
    const ones = [_]u8{0xff} ** 20000;
    try testing.expectEqual(std.hash.Adler32.hash(&ones), adler32(&ones));
}

test "fuzz: any input decodes as the standard library decodes it, or both refuse it" {
    try testing.fuzz({}, fuzzAgainstStd, .{ .corpus = &.{
        &.{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 },
        &.{ 0x78, 0x9c, 0x4b, 0x4c, 0x04, 0x02, 0x00, 0x02, 0x87, 0x01, 0x07 },
    } });
}

fn fuzzAgainstStd(_: void, smith: *testing.Smith) anyerror!void {
    var input_buf: [512]u8 = undefined;
    const input = input_buf[0..smith.slice(&input_buf)];
    const gpa = testing.allocator;
    var theirs: [4096]u8 = undefined;
    var ours: [4096]u8 = undefined;
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var r1: Io.Reader = .fixed(input);
    var sd: std.compress.flate.Decompress = .init(&r1, .raw, window);
    const their_n: ?usize = if (sd.reader.readSliceShort(&theirs)) |n| n else |_| null;
    const d = try gpa.create(Decoder);
    defer gpa.destroy(d);
    d.* = .{};
    var r2: Io.Reader = .fixed(input);
    const our_n: ?usize = d.raw(&r2, &ours) catch null;
    // Where the standard library decodes a whole stream that fits, so does
    // this, to the same bytes; and nothing it refuses is taken.
    if (their_n) |n| {
        if (n < theirs.len) {
            const m = our_n orelse return error.TestUnexpectedResult;
            try testing.expectEqualSlices(u8, theirs[0..n], ours[0..m]);
        }
    }
    if (our_n) |m| {
        const n = their_n orelse return error.TestUnexpectedResult;
        try testing.expectEqualSlices(u8, theirs[0..n], ours[0..m]);
    }
}

test "fuzz: whatever the standard library compresses, at any level, comes back whole" {
    try testing.fuzz({}, fuzzRoundTrip, .{ .corpus = &.{ "", "abcabcabcabcabc", "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" } });
}

fn fuzzRoundTrip(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const data = buf[0..smith.slice(&buf)];
    const levels = [_]std.compress.flate.Compress.Options{ .level_1, .level_4, .level_6, .level_9 };
    const compressed = try stdCompress(testing.allocator, data, levels[data.len % levels.len]);
    defer testing.allocator.free(compressed);
    try expectRoundTrip(testing.allocator, data, compressed);
}
