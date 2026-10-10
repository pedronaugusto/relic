//! Ignore rules, includeIf conditions, attribute files and the CRC kernel,
//! timed through shakedown.bench. Every operation keeps its result observable.
const std = @import("std");
const relic = @import("relic").api;
const crc = @import("relic").crc;
const benchmark = @import("shakedown").bench;
const shared = @import("shared.zig");
const Allocator = std.mem.Allocator;

const patterns = "*.log\n!keep.log\nbuild/\n/src/*.tmp\ncache/**\n*.o\n*.a\n*.so\n*.dylib\n*.exe\n*.obj\n*.pdb\n*.class\n*.pyc\n*.zip\n*.tar\n*.gz\n*.bak\n*.swp\n*.swo\n*.orig\n*.rej\n*.cache\n*.generated\n*.lock\n*.pid\n*.tmp\n*.temp\n*.trace\n*.out\n*.err\n!keep.tmp\n";
const paths = [_][]const u8{ "src/main.zig", "d/keep.log", "d/a.log", "src/a.tmp", "lib/a.o", "src/a.zig", "cache/a", "d/keep.tmp" };

const Context = struct {
    gpa: Allocator,
    rules: *const relic.worktree.ignore.Rules,
    config: *const relic.config.Config,
    bytes: []u8,
    checksum: u64 = 0,

    fn ignoreLoad(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var rules = try relic.worktree.ignore.Rules.init(c.gpa, .{ .case_fold = false });
            defer rules.deinit();
            try rules.addText(patterns, "", ".gitignore", 1);
            c.checksum +%= @intFromBool(rules.match("d/a.log", false).excluded);
        }
    }

    fn ignoreMatch(c: *Context, units: u64) !void {
        for (0..units) |i| c.checksum +%= @intFromBool(c.rules.matchPath(paths[i % paths.len], false).excluded);
    }

    fn includeIf(c: *Context, units: u64) !void {
        for (0..units) |_| c.checksum +%= @intFromBool(try c.config.conditionHolds("gitdir:/tmp/project/"));
    }

    fn attributesLoadMatch(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var attrs = try relic.worktree.attributes.Attrs.init(c.gpa, .{ .case_fold = false });
            defer attrs.deinit();
            try attrs.addText("*.zig diff=zig\n*.bin -diff\n*.txt text\n", "", ".gitattributes", 1);
            var arena: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena.deinit();
            const found = try attrs.lookup(arena.allocator(), "src/main.zig", false);
            c.checksum +%= @intFromBool(found.value("diff") != null);
        }
    }

    fn crcHash(c: *Context, units: u64) !void {
        for (0..units) |i| {
            c.bytes[0] = @truncate(i);
            c.checksum +%= crc.hash(c.bytes);
        }
    }
};

const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.ignoreLoad)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Context.includeIf)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Context.attributesLoadMatch)).@"fn".return_type.?).error_union.error_set;

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const gpa = init.gpa;
    const run_options = try shared.options(init, args);
    var rules = try relic.worktree.ignore.Rules.init(gpa, .{ .case_fold = false });
    defer rules.deinit();
    try rules.addText(patterns, "", ".gitignore", 1);
    var config = try relic.config.Config.open(gpa, init.io, .{}, .{ .git_dir = "/tmp/project/.git" });
    defer config.deinit();
    const bytes = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 2654435761 >> 7);
    var context: Context = .{ .gpa = gpa, .rules = &rules, .config = &config, .bytes = bytes };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const rows = [_]benchmark.Row(Context, WorkloadError){
        .{ .name = "ignore_load_32", .unit = "load", .initial = 16, .run = Context.ignoreLoad },
        .{ .name = "ignore_match_32", .unit = "match", .initial = 1024, .run = Context.ignoreMatch },
        .{ .name = "includeif_short", .unit = "condition", .initial = 1024, .run = Context.includeIf },
        .{ .name = "attributes_load_match", .unit = "load_lookup", .initial = 16, .run = Context.attributesLoadMatch },
        .{ .name = "crc_hash_1m", .unit = "1MiB_hash", .initial = 1, .run = Context.crcHash },
    };
    try benchmark.run(WorkloadError, gpa, init.io, &output.interface, &context, &rows, .{ .commit = shared.commit }, run_options);
    try output.interface.flush();
    if (shared.selects(run_options.prefix, rows) and context.checksum == 0) return error.NoWork;
}
