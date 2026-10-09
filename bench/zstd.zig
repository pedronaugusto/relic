//! The same 128 KiB RLE frame decoded by the reader LFS uses.
const std = @import("std");
const zstd = @import("relic").zstd;
const benchmark = @import("shakedown").bench;
// Single-segment, declared size 128 KiB, one final RLE block containing 'L'.
const frame = "\x28\xb5\x2f\xfd\xa0\x00\x00\x02\x00\x03\x00\x10L";
const Context = struct {
    window: []u8,
    out: []u8,
    checksum: u64 = 0,
    fn decode(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var input: std.Io.Reader = .fixed(frame);
            var reader: zstd.Decompress.Reader = .init(&input, c.window, .{});
            try reader.interface.readSliceAll(c.out);
            var extra: [1]u8 = undefined;
            if (try reader.interface.readSliceShort(&extra) != 0) return error.WrongLength;
            if (!std.mem.allEqual(u8, c.out, 'L') or input.bufferedLen() != 0) return error.WrongAnswer;
            c.checksum +%= c.out.len;
        }
    }
};
const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.decode)).@"fn".return_type.?).error_union.error_set;

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const gpa = init.gpa;
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const window = try gpa.alloc(u8, (8 << 20) + (1 << 17) + 4096);
    defer gpa.free(window);
    const out = try gpa.alloc(u8, 1 << 17);
    defer gpa.free(out);
    var context: Context = .{ .window = window, .out = out };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const rows = [_]benchmark.Row(Context, WorkloadError){.{ .name = "lfs_zstd_reader_rle", .unit = "128KiB_frame", .initial = 1, .run = Context.decode }};
    try benchmark.run(WorkloadError, gpa, init.io, &output.interface, &context, &rows, .{ .commit = if (!smoke and args.len > 1) args[1] else "work-in-progress" }, .{ .smoke = smoke, .samples = 11, .minimum = .fromMilliseconds(5) });
    try output.interface.flush();
    if (context.checksum == 0) return error.NoWork;
}
