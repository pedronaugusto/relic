//! Reading a patch: a git patch of 64 files with 8 hunks each, parsed whole.
//! Every operation keeps its result observable.
const std = @import("std");
const relic = @import("relic").api;
const benchmark = @import("shakedown").bench;
const shared = @import("shared.zig");

const files = 64;
const hunks_per_file = 8;
const lines_per_hunk = 12;

const Context = struct {
    gpa: std.mem.Allocator,
    text: []const u8,
    checksum: u64 = 0,

    fn parse(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var patch = try relic.patch.parse(c.gpa, c.text, .{});
            defer patch.deinit();
            if (patch.files.len != files) return error.WrongAnswer;
            c.checksum +%= patch.files[files - 1].lines_added;
        }
    }
};

const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.parse)).@"fn".return_type.?).error_union.error_set;

/// The patch the row reads: every hunk keeps two lines of context either side
/// of `lines_per_hunk - 4` changed lines, half removed and half added.
fn build(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..files) |f| {
        try out.print(gpa, "diff --git a/f{d}.txt b/f{d}.txt\nindex 1111111..2222222 100644\n--- a/f{d}.txt\n+++ b/f{d}.txt\n", .{ f, f, f, f });
        for (0..hunks_per_file) |h| {
            const changes = lines_per_hunk - 4;
            const length = changes / 2 + 4;
            try out.print(gpa, "@@ -{d},{d} +{d},{d} @@ fn f{d}\n a context\n b context\n", .{ h * 100 + 1, length, h * 100 + 1, length, h });
            for (0..changes / 2) |i| try out.print(gpa, "-old line {d} {d}\n+new line {d} {d}\n", .{ f, i, f, i });
            try out.appendSlice(gpa, " c context\n d context\n");
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const gpa = init.gpa;
    const run_options = try shared.options(init, args);
    const text = try build(gpa);
    defer gpa.free(text);
    var context: Context = .{ .gpa = gpa, .text = text };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const rows = [_]benchmark.Row(Context, WorkloadError){
        .{ .name = "patch_parse_64_files", .unit = "parse", .initial = 16, .run = Context.parse },
    };
    try benchmark.run(WorkloadError, gpa, init.io, &output.interface, &context, &rows, .{ .commit = shared.commit }, run_options);
    try output.interface.flush();
    if (shared.selects(run_options.prefix, rows) and context.checksum == 0) return error.NoWork;
}
