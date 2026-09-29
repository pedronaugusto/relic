//! relic's decoder against zlib's own output: every level, every strategy
//! and window size zlib compresses with, over text, noise and runs, made by
//! `python3`'s `zlib` — the library git writes its objects and packs with.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const program = @import("program.zig");
const inflate = @import("inflate.zig");
const testremote = @import("testremote.zig");

const script =
    \\import random, struct, sys, zlib
    \\rng = random.Random(1950)
    \\words = b"tree blob commit parent author committer the of and to in a is that".split()
    \\def text(n):
    \\    out = bytearray()
    \\    while len(out) < n: out += rng.choice(words) + b" "
    \\    return bytes(out[:n])
    \\def noise(n): return bytes(rng.getrandbits(8) for _ in range(n))
    \\def runs(n):
    \\    out = bytearray()
    \\    while len(out) < n: out += bytes([rng.getrandbits(8)]) * rng.randint(1, 300)
    \\    return bytes(out[:n])
    \\strategies = [zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED, zlib.Z_HUFFMAN_ONLY, zlib.Z_RLE, zlib.Z_FIXED]
    \\out = sys.stdout.buffer
    \\for n in [0, 1, 300, 20000, 150000]:
    \\    for make in [text, noise, runs]:
    \\        data = make(n)
    \\        cases = [(level, s, 15, 8) for level in [0, 1, 6, 9] for s in strategies]
    \\        cases += [(6, zlib.Z_DEFAULT_STRATEGY, 9, 1), (9, zlib.Z_DEFAULT_STRATEGY, 12, 9)]
    \\        for level, strategy, wbits, mem in cases:
    \\            c = zlib.compressobj(level, zlib.DEFLATED, wbits, mem, strategy)
    \\            z = c.compress(data) + c.flush()
    \\            out.write(struct.pack(">II", len(data), len(z)) + data + z)
    \\
;

test "every stream zlib makes, at every level, strategy and window, decodes to what it was" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var made = program.run(.{ .environ = &env }, gpa, io, .{ .argv = &.{ "python3", "-c", script } }, "", .{}) catch return error.SkipZigTest;
    defer made.deinit(gpa);
    if (!made.succeeded()) return error.SkipZigTest;

    const d = try gpa.create(inflate.Decoder);
    defer gpa.destroy(d);
    d.* = .{};
    var rest = made.stdout;
    var cases: usize = 0;
    while (rest.len != 0) {
        const n = std.mem.readInt(u32, rest[0..4], .big);
        const z_len = std.mem.readInt(u32, rest[4..8], .big);
        const data = rest[8..][0..n];
        const z = rest[8 + n ..][0..z_len];
        rest = rest[8 + n + z_len ..];
        const out = try gpa.alloc(u8, n);
        defer gpa.free(out);
        var r: std.Io.Reader = .fixed(z);
        const got = try d.zlib(&r, out);
        try testing.expectEqual(n, got);
        try testing.expectEqualSlices(u8, data, out);
        try testing.expectEqual(@as(usize, 0), r.bufferedLen());
        cases += 1;
    }
    try testing.expectEqual(@as(usize, 5 * 3 * 22), cases);
}
