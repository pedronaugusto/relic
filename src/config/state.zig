//! Repository configuration ownership and detached edit copies.
//! Package plumbing, reached by no public name.
const std = @import("std");
const config = @import("../config.zig");
const Allocator = std.mem.Allocator;
const fs = @import("../repo/fs.zig");

pub const State = opaque {};

pub fn get(state: *State) *config.Config {
    return @ptrCast(@alignCast(state)); // safe: create allocates each State as aligned Config.
}

/// Takes the configuration on success and failure.
pub fn create(value: config.Config) Allocator.Error!*State {
    const owned = value.gpa.create(config.Config) catch |err| {
        var refused = value;
        refused.deinit();
        return err;
    };
    owned.* = value;
    return @ptrCast(owned); // safe: the opaque owner retains the allocated Config pointer.
}

pub fn destroy(state: *State) void {
    const owned = get(state);
    const gpa = owned.gpa;
    owned.deinit();
    gpa.destroy(owned);
}

/// Learned LFS settings cannot change repository format, source selection
/// or ref policy. This owner applies them with remember's existing errors.
pub fn rememberLfs(state: *State, key: []const u8, value: []const u8) config.Config.SetError!void {
    if (!std.mem.startsWith(u8, key, "lfs.")) return error.InvalidKey;
    try get(state).setIn(.local, key, value);
}

/// A repository's shared edits select the same local source as setIn.
/// A later worktree source must never supply the bytes for this path.
pub fn writeLocal(state: *State, io: std.Io) config.Config.SetError!void {
    const owned = get(state);
    const path = owned.sources.local orelse return error.NoWritableSource;
    for (owned.files.items) |*file| {
        if (file.writable and file.level == .local) return writeFile(file, io, path.dir, path.sub_path);
    }
    return error.NoWritableSource;
}

pub const writeFile = @import("write.zig").writeFile;

pub fn copy(gpa: Allocator, source: *const config.Config) config.ParseError!config.Config {
    // open copies context and command sources without filesystem access.
    var out = try config.Config.open(gpa, std.Io.failing, .{
        .command = source.sources.command,
        .pairs = source.sources.pairs,
    }, source.context);
    errdefer out.deinit();
    for (out.files.items) |*file| file.deinit();
    out.files.clearRetainingCapacity();
    out.entries.clearRetainingCapacity();
    inline for (.{ "system", "xdg", "global", "local", "worktree" }) |field| {
        if (@field(source.sources, field)) |path| {
            const sub_path = try gpa.dupe(u8, path.sub_path);
            @field(out.sources, field) = .{ .dir = path.dir, .sub_path = sub_path };
        }
    }
    for (source.files.items) |file| {
        const text = try file.render();
        defer source.gpa.free(text);
        var parsed = try config.Config.parseText(gpa, text, file.level);
        defer parsed.deinit();
        const path = try gpa.dupe(u8, file.path);
        gpa.free(parsed.files.items[0].path);
        parsed.files.items[0].path = path;
        parsed.files.items[0].writable = file.writable;
        const at: u32 = @intCast(out.files.items.len);
        try out.files.append(gpa, parsed.files.items[0]);
        parsed.files.items.len = 0; // out owns the file even if indexing fails.
        for (parsed.entries.items) |entry| {
            var kept = entry;
            kept.file_index = at;
            try out.entries.append(gpa, kept);
        }
    }
    for (source.read.items) |read| {
        const path = try gpa.dupe(u8, read.sub_path);
        errdefer gpa.free(path);
        const bytes = if (read.bytes) |b| try gpa.dupe(u8, b) else null;
        errdefer if (bytes) |b| gpa.free(b);
        try out.read.append(gpa, .{ .dir = read.dir, .sub_path = path, .bytes = bytes });
    }
    return out;
}

test "detached configuration copies preserve sources origins and refresh metadata" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "system", "xdg", "global", "local", "worktree" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "[fixture]\n value = copied\n" });
    }
    var source = try config.Config.open(testing.allocator, io, .{
        .system = .{ .dir = tmp.dir, .sub_path = "system" },
        .xdg = .{ .dir = tmp.dir, .sub_path = "xdg" },
        .global = .{ .dir = tmp.dir, .sub_path = "global" },
        .local = .{ .dir = tmp.dir, .sub_path = "local" },
        .worktree = .{ .dir = tmp.dir, .sub_path = "worktree" },
        .command = &.{"fixture.command=command"},
        .pairs = &.{.{ .name = "fixture.pair", .value = "pair" }},
    }, .{ .git_dir = "owned/git", .branch = "main", .home = "owned/home" });
    defer source.deinit();
    try source.setIn(.local, "fixture.edited", "kept");
    const Check = struct {
        fn run(gpa: Allocator, original: *const config.Config) !void {
            var duplicate = try copy(gpa, original);
            defer duplicate.deinit();
            try std.testing.expectEqualStrings("kept", duplicate.get("fixture.edited").?);
            try std.testing.expectEqualStrings("pair", duplicate.get("fixture.pair").?);
            try std.testing.expectEqualStrings("command", duplicate.get("fixture.command").?);
            try std.testing.expectEqual(config.Level.worktree, duplicate.origin("fixture.value").?.level);
            try std.testing.expectEqual(config.Level.local, duplicate.origin("fixture.edited").?.level);
            try std.testing.expectEqualStrings("main", duplicate.context.branch.?);
            try std.testing.expect(!try duplicate.isStale(std.testing.io));
            try duplicate.setIn(.local, "fixture.edited", "independent");
            try std.testing.expectEqualStrings("kept", original.get("fixture.edited").?);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{&source});
}
