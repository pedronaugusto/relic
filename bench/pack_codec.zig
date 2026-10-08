//! Reused pack compression: text and noise, at each supported pack level.
const std = @import("std");
const pack = @import("relic").api.odb.pack;
const benchmark = @import("shakedown").bench;
const Context = struct {
    deflater: *pack.Deflater,
    text: []const u8,
    noise: []const u8,
    out: []u8,
    checksum: u64 = 0,

    fn compress(c: *Context, units: u64, level: pack.Compression, noise: bool) !void {
        for (0..units) |_| {
            var out: std.Io.Writer = .fixed(c.out);
            try c.deflater.deflate(&out, if (noise) c.noise else c.text, level);
            if (out.end < 6 or out.buffer[0] != 0x78) return error.WrongAnswer;
            c.checksum +%= out.end;
        }
    }
    fn fastText(c: *Context, units: u64) !void {
        try c.compress(units, .fast, false);
    }
    fn defaultText(c: *Context, units: u64) !void {
        try c.compress(units, .default, false);
    }
    fn bestText(c: *Context, units: u64) !void {
        try c.compress(units, .best, false);
    }
    fn fastNoise(c: *Context, units: u64) !void {
        try c.compress(units, .fast, true);
    }
    fn defaultNoise(c: *Context, units: u64) !void {
        try c.compress(units, .default, true);
    }
    fn bestNoise(c: *Context, units: u64) !void {
        try c.compress(units, .best, true);
    }
};
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const text = try gpa.alloc(u8, 32 << 10);
    defer gpa.free(text);
    const phrase = "tree commit object refs source history merge file\n";
    for (text, 0..) |*byte, i| byte.* = phrase[i % phrase.len];
    const noise = try gpa.alloc(u8, text.len);
    defer gpa.free(noise);
    var random: std.Random.DefaultPrng = .init(0xcedec);
    random.random().bytes(noise);
    const out = try gpa.alloc(u8, pack.Deflater.room(text.len));
    defer gpa.free(out);
    var deflater = try pack.Deflater.init(gpa);
    defer deflater.deinit(gpa);
    var context: Context = .{ .deflater = &deflater, .text = text, .noise = noise, .out = out };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const rows = [_]benchmark.Row(Context){
        .{ .name = "pack_fast_text", .unit = "32KiB_stream", .initial = 1, .run = Context.fastText },
        .{ .name = "pack_default_text", .unit = "32KiB_stream", .initial = 1, .run = Context.defaultText },
        .{ .name = "pack_best_text", .unit = "32KiB_stream", .initial = 1, .run = Context.bestText },
        .{ .name = "pack_fast_noise", .unit = "32KiB_stream", .initial = 1, .run = Context.fastNoise },
        .{ .name = "pack_default_noise", .unit = "32KiB_stream", .initial = 1, .run = Context.defaultNoise },
        .{ .name = "pack_best_noise", .unit = "32KiB_stream", .initial = 1, .run = Context.bestNoise },
    };
    try benchmark.run(gpa, init.io, &output.interface, &context, &rows, .{ .commit = if (!smoke and args.len > 1) args[1] else "work-in-progress" }, .{ .smoke = smoke, .samples = 11, .minimum = .fromMilliseconds(5) });
    try output.interface.flush();
    if (context.checksum == 0) return error.NoWork;
}
