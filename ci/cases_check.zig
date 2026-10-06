//! Each source test and each comparison has exactly one Windows owner.
const std = @import("std");
const cases = @import("test_cases.zig");
const core = @import("core_cases.zig");

fn owner(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, name, "random corpus of three-way merges") != null) return "merge-file";
    if (std.mem.indexOf(u8, name, "diffs land on the lines") != null) return "diff-algorithms";
    const at = (std.mem.indexOf(u8, name, ": seed ") orelse return error.UnknownComparison) + 7;
    const tail = name[at..];
    const seed = try std.fmt.parseInt(usize, tail[0 .. std.mem.indexOfScalar(u8, tail, ',') orelse tail.len], 10);
    if (std.mem.startsWith(u8, name, "random histories")) return std.fmt.allocPrint(a, "history-{d}", .{seed % 8});
    if (std.mem.startsWith(u8, name, "criss-cross histories")) return std.fmt.allocPrint(a, "recursive-{d}", .{seed % 3});
    if (std.mem.startsWith(u8, name, "diff -M")) return std.fmt.allocPrint(a, "rename-{d}", .{seed % 6});
    if (std.mem.startsWith(u8, name, "a walk comes out")) return "revwalk";
    return error.UnknownComparison;
}

fn named(values: std.json.Value, wanted: []const u8) usize {
    if (values != .array) return 0;
    var count: usize = 0;
    for (values.array.items) |value| {
        if (value != .object) continue;
        const name = value.object.get("name") orelse continue;
        if (name == .string and std.mem.eql(u8, name.string, wanted)) count += 1;
    }
    return count;
}

fn report(comptime format: []const u8, io: std.Io, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var comparisons = std.StringHashMap(void).init(a);
    var modules = std.StringHashMap(void).init(a);
    var owners = std.StringHashMap(void).init(a);
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const text = try dir.readFileAlloc(io, entry.path, a, .limited(8 * 1024 * 1024));
        var tree = try std.zig.Ast.parse(a, try a.dupeZ(u8, text), .zig);
        defer tree.deinit(a);
        const module = try a.dupe(u8, entry.path[0 .. entry.path.len - 4]);
        std.mem.replaceScalar(u8, module, '/', '.');
        std.mem.replaceScalar(u8, module, '\\', '.');
        for (tree.nodes.items(.tag), 0..) |tag, index| {
            if (tag != .test_decl) continue;
            try modules.put(try a.dupe(u8, module), {});
            const node: std.zig.Ast.Node.Index = @enumFromInt(index);
            const token = tree.nodeMainToken(node) + 1;
            if (tree.tokenTag(token) != .string_literal) continue;
            const name = try std.zig.string_literal.parseAlloc(a, tree.tokenSlice(token));

            const qualified = try std.fmt.allocPrint(a, "{s}.test.{s}", .{ module, name });
            var matches: usize = 0;
            for (core.families) |family| {
                for (family.filters) |filter| if (std.mem.indexOf(u8, qualified, filter) != null) {
                    matches += 1;
                    break;
                };
            }
            if (matches != 1) {
                try report("Windows family: {s} has {d} owners\n", io, .{ qualified, matches });
                return error.InvalidFamilyCoverage;
            }
            count += 1;
            if (std.mem.indexOf(u8, name, ": seed ") == null and std.mem.indexOf(u8, name, "random corpus") == null) continue;
            const previous = try comparisons.getOrPut(name);
            if (previous.found_existing) return error.DuplicateComparison;
            try owners.put(try owner(a, name), {});
            const selection = try std.fmt.allocPrint(a, "selected({s})", .{tree.tokenSlice(token)});
            if (std.mem.indexOf(u8, text, selection) == null) return error.MissingExactSelection;
        }
    }
    if (count != 1409 or comparisons.count() != 180) {
        try report("Windows coverage: {d} source tests, {d} comparisons; expected 1409 and 180\n", io, .{ count, comparisons.count() });
        return error.ChangedTestCount;
    }
    var filters = std.StringHashMap(void).init(a);
    for (core.families) |family| for (family.filters) |filter| {
        const module = filter[0 .. filter.len - ".test".len];
        if (!modules.contains(module)) {
            try report("Windows family: stale module {s}\n", io, .{module});
            return error.StaleCoreModule;
        }
        if ((try filters.getOrPut(module)).found_existing) return error.DuplicateCoreModule;
    };
    if (filters.count() != modules.count() or core.families.len != 5) return error.MissingCoreModule;
    const selection = try dir.readFileAlloc(io, "testing/case.zig", a, .limited(1024 * 1024));
    if (std.mem.indexOf(u8, selection, "std.mem.eql(u8, name, chosen)") == null) return error.NonExactSelection;
    const json = try std.Io.Dir.cwd().readFileAlloc(io, "ci/workflow.json", a, .limited(1024 * 1024));
    const config = (try std.json.parseFromSlice(std.json.Value, a, json, .{})).value;
    const full = config.object.get("windows_shards") orelse return error.MissingWindowsShards;
    const fast = config.object.get("fast_windows_shards") orelse return error.MissingFastShards;
    const linux = config.object.get("fast_linux_shards") orelse return error.MissingLinuxFastShards;
    if (linux != .array or linux.array.items.len != full.array.items.len) return error.WrongLinuxFastShardCount;
    for (cases.cases[1..]) |name| if (named(linux, name) != 1) return error.MissingOrDuplicateLinuxFastShard;
    for (linux.array.items) |shard| {
        const measurement = shard.object.get("measurement") orelse return error.MissingLinuxFastMeasurement;
        const seconds = shard.object.get("seconds") orelse return error.MissingLinuxFastWeight;
        if (measurement != .string or measurement.string.len == 0) return error.MissingLinuxFastMeasurement;
        if (!((seconds == .float and seconds.float > 0) or (seconds == .integer and seconds.integer > 0))) return error.InvalidLinuxFastWeight;
    }
    if (full.array.items.len + 1 != cases.cases.len or fast.array.items.len != core.families.len) return error.WrongShardCount;
    for (cases.cases[1..]) |name| if (named(full, name) != 1) return error.MissingOrDuplicateShard;
    for (core.families) |family| {
        if (named(fast, family.name) != 1) return error.MissingFastFamily;
        for (full.array.items) |shard| {
            const name = shard.object.get("name") orelse continue;
            if (name != .string or !std.mem.eql(u8, name.string, family.name)) continue;
            const priority = shard.object.get("priority") orelse return error.CoreMustStartFirst;
            if (priority != .integer or priority.integer != 1) return error.CoreMustStartFirst;
        }
    }
    var iterator = owners.keyIterator();
    while (iterator.next()) |name| if (named(full, name.*) != 1) return error.MissingComparisonOwner;
    const timeout = config.object.get("test_timeout") orelse return error.MissingTimeout;
    if (timeout != .string or !std.mem.eql(u8, timeout.string, "--test-timeout 60s")) return error.ChangedTestBudget;
    try report("Windows cases: 1409 source tests and 180 comparisons each have one owner\n", io, .{});
}

test "comparison assignment uses complete seeds rather than substring matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("history-1", try owner(a, "random histories merge to git's trees, stages and messages: seed 1, sparse"));
    try std.testing.expectEqualStrings("history-2", try owner(a, "random histories merge to git's trees, stages and messages: seed 10, crowded"));
    try std.testing.expectEqualStrings("recursive-2", try owner(a, "criss-cross histories merge their bases first: seed 29"));
    try std.testing.expectEqualStrings("rename-5", try owner(a, "diff -M pairs what git's do: seed 59"));
    try std.testing.expectError(error.UnknownComparison, owner(a, "new unassigned comparison"));
}
