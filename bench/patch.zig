//! Reading a patch, and checking one against a working tree: a git patch of 64
//! files with 8 hunks each. Every operation keeps its result observable.
const std = @import("std");
const relic = @import("relic").api;
const benchmark = @import("shakedown").bench;
const shared = @import("shared.zig");
const scratchgit = @import("scratchgit.zig");

const files = 64;
const hunks_per_file = 8;
const lines_per_hunk = 12;

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
    repo: *relic.repo.Repository,
    applying: []const u8,
    checksum: u64 = 0,

    fn check(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var outcome = try relic.patch.apply.apply(c.gpa, c.io, c.repo, c.applying, .{ .check = true });
            defer outcome.deinit();
            if (outcome.files.len != files or !outcome.clean()) return error.WrongAnswer;
            c.checksum +%= outcome.files.len;
        }
    }

    fn parse(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var patch = try relic.patch.parse(c.gpa, c.text, .{});
            defer patch.deinit();
            if (patch.files.len != files) return error.WrongAnswer;
            c.checksum +%= patch.files[files - 1].lines_added;
        }
    }
};

const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.parse)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Context.check)).@"fn".return_type.?).error_union.error_set;

const file_lines = hunks_per_file * 100 + lines_per_hunk;

fn fileText(gpa: std.mem.Allocator, f: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..file_lines) |i| try out.print(gpa, "file {d} line {d}\n", .{ f, i });
    return out.toOwnedSlice(gpa);
}

/// A patch that applies to the files `fileText` makes: each hunk keeps two
/// lines of context either side of four removed lines and four added.
fn applyingPatch(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..files) |f| {
        try out.print(gpa, "diff --git a/f{d}.txt b/f{d}.txt\n--- a/f{d}.txt\n+++ b/f{d}.txt\n", .{ f, f, f, f });
        for (0..hunks_per_file) |h| {
            const at = h * 100;
            try out.print(gpa, "@@ -{d},8 +{d},8 @@\n", .{ at + 1, at + 1 });
            for (at..at + 2) |i| try out.print(gpa, " file {d} line {d}\n", .{ f, i });
            for (at + 2..at + 6) |i| try out.print(gpa, "-file {d} line {d}\n", .{ f, i });
            for (at + 2..at + 6) |i| try out.print(gpa, "+file {d} changed {d}\n", .{ f, i });
            for (at + 6..at + 8) |i| try out.print(gpa, " file {d} line {d}\n", .{ f, i });
        }
    }
    return out.toOwnedSlice(gpa);
}

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
    const io = init.io;
    const run_options = try shared.options(init, args);
    const text = try build(gpa);
    defer gpa.free(text);
    const applying = try applyingPatch(gpa);
    defer gpa.free(applying);
    scratchgit.environment = init.minimal.environ;
    var source = try scratchgit.Repo.init(gpa, io);
    defer source.deinit();
    for (0..files) |f| {
        var name_buf: [32]u8 = undefined;
        const name = try std.mem.print(&name_buf, "f{d}.txt", .{f});
        const body = try fileText(gpa, f);
        defer gpa.free(body);
        try source.writeFile(io, name, body);
    }
    var repo = try relic.repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer repo.deinit(io);
    var context: Context = .{ .gpa = gpa, .io = io, .text = text, .repo = &repo, .applying = applying };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    const rows = [_]benchmark.Row(Context, WorkloadError){
        .{ .name = "patch_parse_64_files", .unit = "parse", .initial = 16, .run = Context.parse },
        .{ .name = "patch_check_64_files", .unit = "check", .initial = 1, .run = Context.check },
    };
    try benchmark.run(WorkloadError, gpa, io, &output.interface, &context, &rows, .{ .commit = shared.commit }, run_options);
    try output.interface.flush();
    if (shared.selects(run_options.prefix, rows) and context.checksum == 0) return error.NoWork;
}
