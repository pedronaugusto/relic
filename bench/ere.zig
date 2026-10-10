//! Boolean and span adapters compile and search the same bounded ERE.
//! Every timed operation owns and releases its compiled pattern.
const std = @import("std");
const ere = @import("relic").regex;
const benchmark = @import("shakedown").bench;
const shared = @import("shared.zig");
const pattern = "(foo|bar){2,3}baz";
const text = "xfoobarfoobaz";
const Context = struct {
    gpa: std.mem.Allocator,
    checksum: u64 = 0,

    fn boolean(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var p = try ere.Pattern.compile(c.gpa, pattern);
            defer p.deinit();
            if (!try p.search(c.gpa, text)) return error.WrongAnswer;
            c.checksum +%= 1;
        }
    }

    fn span(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var p = try ere.Regex.compile(c.gpa, pattern, .{});
            defer p.deinit();
            const found = (try p.find(c.gpa, text, false)) orelse return error.WrongAnswer;
            if (found.start != 1 or found.end != text.len) return error.WrongAnswer;
            c.checksum +%= found.end;
        }
    }
};

const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.boolean)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Context.span)).@"fn".return_type.?).error_union.error_set;

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const run_options = try shared.options(init, args);
    var context: Context = .{ .gpa = gpa };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    const rows = [_]benchmark.Row(Context, WorkloadError){
        .{ .name = "ere_interval_boolean", .unit = "compile_search", .initial = 64, .run = Context.boolean },
        .{ .name = "ere_interval_span", .unit = "compile_search", .initial = 64, .run = Context.span },
    };
    try benchmark.run(WorkloadError, gpa, io, &output.interface, &context, &rows, .{ .commit = shared.commit }, run_options);
    try output.interface.flush();
    if (shared.selects(run_options.prefix, rows) and context.checksum == 0) return error.NoWork;
}
