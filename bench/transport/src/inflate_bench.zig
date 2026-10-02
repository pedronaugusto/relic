//! Inflate every entry of a pack, with std.compress.flate and with zlib, and
//! say how long each took. Private: the book's, not relic's.
//!   zig build-exe -OReleaseFast -lz -lc inflate_bench.zig && ./inflate_bench <pack>
const std = @import("std");
const c = @cImport(@cInclude("zlib.h"));
const inflate = @import("inflate");
const smoke = @import("bench_options").smoke;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(bytes);
    const count = std.mem.readInt(u32, bytes[8..12], .big);
    // Entry offsets and sizes, found by inflating once with zlib.
    var offsets: std.ArrayList(struct { data: usize, size: usize, checksum: u64 }) = .empty;
    defer offsets.deinit(gpa);
    const out = try gpa.alloc(u8, 64 << 20);
    defer gpa.free(out);
    var at: usize = 12;
    var total_in: usize = 0;
    var total_out: usize = 0;
    for (0..count) |_| {
        var b = bytes[at];
        at += 1;
        const t = (b >> 4) & 7;
        var size: usize = b & 15;
        var shift: u6 = 4;
        while (b & 0x80 != 0) : (shift += 7) {
            b = bytes[at];
            at += 1;
            size |= @as(usize, b & 0x7f) << shift;
        }
        if (t == 6) {
            b = bytes[at];
            at += 1;
            while (b & 0x80 != 0) {
                b = bytes[at];
                at += 1;
            }
        } else if (t == 7) at += 20;
        var z: c.z_stream = std.mem.zeroes(c.z_stream);
        _ = c.inflateInit_(&z, c.ZLIB_VERSION, @sizeOf(c.z_stream));
        z.next_in = bytes[at..].ptr;
        z.avail_in = @intCast(bytes.len - at);
        z.next_out = out.ptr;
        z.avail_out = @intCast(out.len);
        const rc = c.inflate(&z, c.Z_FINISH);
        if (rc != c.Z_STREAM_END) return error.Zlib;
        const used = bytes.len - at - z.avail_in;
        try offsets.append(gpa, .{ .data = at, .size = size, .checksum = std.hash.Wyhash.hash(0, out[0..size]) });
        total_in += used;
        total_out += size;
        _ = c.inflateEnd(&z);
        at += used;
    }
    std.debug.print("{d} entries, {d} bytes in, {d} out\n", .{ count, total_in, total_out });

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const decoder = try gpa.create(inflate.Decoder);
    defer gpa.destroy(decoder);
    decoder.* = .{};
    // Untimed correctness pass: all decoders must reproduce zlib's bytes.
    for (offsets.items) |e| {
        var input: std.Io.Reader = .fixed(bytes[e.data..]);
        var std_decoder: std.compress.flate.Decompress = .init(&input, .zlib, window);
        try std_decoder.reader.readSliceAll(out[0..e.size]);
        if (std.hash.Wyhash.hash(0, out[0..e.size]) != e.checksum) return error.StandardBytesDiffer;
        var chunk_input: std.Io.Reader = .fixed(bytes[e.data..]);
        var chunk_decoder: std.compress.flate.Decompress = .init(&chunk_input, .zlib, window);
        var digest = std.hash.Wyhash.init(0);
        var chunk_buffer: [16 * 1024]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try chunk_decoder.reader.readSliceShort(&chunk_buffer);
            digest.update(chunk_buffer[0..n]);
            total += n;
            if (n < chunk_buffer.len) break;
        }
        if (total != e.size or digest.final() != e.checksum) return error.ChunkedBytesDiffer;
        var ours_input: std.Io.Reader = .fixed(bytes[e.data..]);
        const decoded = try decoder.zlib(&ours_input, out[0..e.size]);
        if (decoded != e.size or std.hash.Wyhash.hash(0, out[0..e.size]) != e.checksum) return error.RelicBytesDiffer;
    }
    if (smoke) return;
    var best = [_]i96{std.math.maxInt(i96)} ** 4;
    defer std.debug.print("best: zlib {d} ms  std {d} ms  std-chunked {d} ms  relic {d} ms\n", .{ @divTrunc(best[0], 1_000_000), @divTrunc(best[1], 1_000_000), @divTrunc(best[2], 1_000_000), @divTrunc(best[3], 1_000_000) });
    const passes = if (args.len > 2) try std.fmt.parseUnsigned(usize, args[2], 10) else 3;
    if (args.len > 3) {
        // Only relic's, for a profiler.
        for (0..passes) |_| for (offsets.items) |e| {
            var in: std.Io.Reader = .fixed(bytes[e.data..]);
            _ = try decoder.zlib(&in, out[0..e.size]);
        };
        return;
    }
    for (0..passes) |_| {
        var t0 = std.Io.Clock.awake.now(io).nanoseconds;
        for (offsets.items) |e| {
            var z: c.z_stream = std.mem.zeroes(c.z_stream);
            _ = c.inflateInit_(&z, c.ZLIB_VERSION, @sizeOf(c.z_stream));
            z.next_in = bytes[e.data..].ptr;
            z.avail_in = @intCast(bytes.len - e.data);
            z.next_out = out.ptr;
            z.avail_out = @intCast(out.len);
            _ = c.inflate(&z, c.Z_FINISH);
            _ = c.inflateEnd(&z);
        }
        const zlib_ns = std.Io.Clock.awake.now(io).nanoseconds - t0;
        t0 = std.Io.Clock.awake.now(io).nanoseconds;
        for (offsets.items) |e| {
            var in: std.Io.Reader = .fixed(bytes[e.data..]);
            var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
            try d.reader.readSliceAll(out[0..e.size]);
        }
        const std_ns = std.Io.Clock.awake.now(io).nanoseconds - t0;
        t0 = std.Io.Clock.awake.now(io).nanoseconds;
        var chunk: [16 * 1024]u8 = undefined;
        for (offsets.items) |e| {
            var in: std.Io.Reader = .fixed(bytes[e.data..]);
            var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
            var left = e.size + 1;
            while (left > 0) {
                const n = try d.reader.readSliceShort(chunk[0..@min(chunk.len, left)]);
                if (n == 0) break;
                left -= n;
                if (n < chunk.len) break;
            }
        }
        const chunk_ns = std.Io.Clock.awake.now(io).nanoseconds - t0;
        t0 = std.Io.Clock.awake.now(io).nanoseconds;
        for (offsets.items) |e| {
            var in: std.Io.Reader = .fixed(bytes[e.data..]);
            const n = try decoder.zlib(&in, out[0..e.size]);
            if (n != e.size) return error.Size;
        }
        const ours_ns = std.Io.Clock.awake.now(io).nanoseconds - t0;
        for (&best, [_]i96{ zlib_ns, std_ns, chunk_ns, ours_ns }) |*b, t| b.* = @min(b.*, t);
    }
}
