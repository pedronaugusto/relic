//! Paired phase-2 measurements. The same source runs against the pre-change
//! clone and this branch; every timed row keeps a result observable.
const std = @import("std");
const relic = @import("relic").api;
const ere = @import("relic").regex;
const crc = @import("relic").crc;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const patterns = "*.log\n!keep.log\nbuild/\n/src/*.tmp\ncache/**\n*.o\n*.a\n*.so\n*.dylib\n*.exe\n*.obj\n*.pdb\n*.class\n*.pyc\n*.zip\n*.tar\n*.gz\n*.bak\n*.swp\n*.swo\n*.orig\n*.rej\n*.cache\n*.generated\n*.lock\n*.pid\n*.tmp\n*.temp\n*.trace\n*.out\n*.err\n!keep.tmp\n";
const paths = [_][]const u8{ "src/main.zig", "d/keep.log", "d/a.log", "src/a.tmp", "lib/a.o", "src/a.zig", "cache/a", "d/keep.tmp" };

fn time(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

fn row(w: *Io.Writer, name: []const u8, io: Io, from: Io.Timestamp, operations: usize, result: usize) !void {
    const ns: f64 = @floatFromInt(from.durationTo(time(io)).toNanoseconds());
    try w.print("{s},{d},{d:.3},{d}\n", .{ name, operations, ns / @as(f64, @floatFromInt(operations)), result });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const smoke = if (args.next()) |arg| std.mem.eql(u8, arg, "--smoke") else false;
    const loads: usize = if (smoke) 1 else 1000;
    const matches: usize = if (smoke) 1 else 100000;
    var buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &buffer);
    const w = &output.interface;
    try w.writeAll("row,operations,ns_per_operation,result\n");
    var result: usize = 0;
    var from = time(io);
    for (0..loads) |_| {
        var rules = try relic.worktree.ignore.Rules.init(gpa, false);
        defer rules.deinit();
        try rules.addText(patterns, "", ".gitignore", 1);
        result += @intFromBool(rules.match("d/a.log", false).excluded);
    }
    try row(w, "ignore_load_32", io, from, loads, result);
    var rules = try relic.worktree.ignore.Rules.init(gpa, false);
    defer rules.deinit();
    try rules.addText(patterns, "", ".gitignore", 1);
    result = 0;
    from = time(io);
    for (0..matches) |i| result += @intFromBool(rules.matchPath(paths[i % paths.len], false).excluded);
    try row(w, "ignore_match_32", io, from, matches, result);
    var config = try relic.config.Config.open(gpa, io, .{}, .{ .git_dir = "/tmp/project/.git" });
    defer config.deinit();
    result = 0;
    from = time(io);
    for (0..matches) |_| result += @intFromBool(try config.conditionHolds("gitdir:/tmp/project/"));
    try row(w, "includeif_short", io, from, matches, result);
    result = 0;
    from = time(io);
    for (0..loads) |_| {
        var p = try ere.Pattern.compile(gpa, "(foo|bar)+baz");
        defer p.deinit();
        result += @intFromBool(try p.search(gpa, "prefix foobarfoobarbaz suffix"));
    }
    try row(w, "ere_compile_search", io, from, loads, result);
    result = 0;
    from = time(io);
    for (0..loads) |_| {
        var attrs = try relic.worktree.attributes.Attrs.init(gpa, false);
        defer attrs.deinit();
        try attrs.addText("*.zig diff=zig\n*.bin -diff\n*.txt text\n", "", ".gitattributes", 1);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const found = try attrs.lookup(arena.allocator(), "src/main.zig", false);
        result += @intFromBool(found.value("diff") != null);
    }
    try row(w, "attributes_load_match", io, from, loads, result);
    const bytes = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 2654435761 >> 7);
    result = 0;
    from = time(io);
    for (0..loads) |i| {
        bytes[0] = @truncate(i);
        result +%= crc.hash(bytes);
    }
    try row(w, "crc_hash_1m", io, from, loads, result);
    try w.flush();
}
