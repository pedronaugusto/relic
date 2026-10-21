//! Delta islands, read from the configuration as git's
//! `load_delta_islands` reads them: each `pack.island` a regular
//! expression over ref names (anchored at the start), the island a ref is
//! in named by what the last matching expression's groups took, joined by
//! `-`; every object an island's refs reach is in it.
//!
//! `pack.islandCore` names the island git lays out first in a pack, which
//! changes where objects sit and never what a pack holds; relic writes its
//! packs in its own order and reads it for nothing else.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const repo_mod = @import("../repo/repo.zig");
const ere = @import("../text.zig").ere;
const islands_mod = @import("../odb/islands.zig");
const object_walk = @import("../walk/object.zig").walk;
const Repository = repo_mod.Repository;

/// Failures of `load`.
pub const Error = repo_mod.Error || ere.Error || object_walk.Error || error{
    /// A `pack.island` set with no value: git's "missing value".
    MissingValue,
};

/// The islands the configuration describes, or `null` when it names none.
pub fn load(gpa: Allocator, io: Io, repo: *Repository) Self.Error!?islands_mod.Islands {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var patterns: std.ArrayList(ere.Regex) = .empty;
    defer {
        for (patterns.items) |*p| p.deinit();
        patterns.deinit(gpa);
    }
    var it = repo.configuration().iterate(&.{"pack.island"});
    while (it.next()) |entry| {
        const value = entry.value orelse return error.MissingValue;
        // `island_config_callback`: anchored at the start.
        const text = if (std.mem.startsWith(u8, value, "^")) value else try arena.print("^{s}", .{value});
        try patterns.append(gpa, try ere.Regex.compile(gpa, text, .{ .syntax = .extended, .newline = false }));
    }
    if (patterns.items.len == 0) return null;

    // `find_island_for_ref`: each ref's island, the last expression that
    // matches it deciding.
    var islands: std.array_hash_map.String(std.ArrayList(Oid)) = .empty;
    var listed = try repo.refStore().list(gpa, io, "refs/");
    defer listed.deinit();
    for (listed.entries) |ref| {
        const oid = switch (ref.target) {
            .direct => |oid| oid,
            .symbolic => continue,
        };
        var groups: [ere.Regex.max_groups]?ere.Match = undefined;
        var i = patterns.items.len;
        const matched = while (i > 0) {
            i -= 1;
            if ((try patterns.items[i].findGroups(ref.name, &groups)) != null) break true;
        } else false;
        if (!matched) continue;
        var name: std.ArrayList(u8) = .empty;
        // git has room for fourteen groups; the fifteenth is where it
        // sees too many.
        for (groups[1 .. ere.Regex.max_groups - 1]) |group| {
            const g = group orelse continue;
            if (name.items.len != 0) try name.append(arena, '-');
            try name.appendSlice(arena, ref.name[g.start..g.end]);
        }
        const slot = try islands.getOrPut(arena, name.items);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(arena, oid);
    }

    var result: islands_mod.Islands = .init(gpa, islands.count());
    errdefer result.deinit();
    for (islands.values(), 0..) |tips, island| {
        var reached = try object_walk.missing(gpa, io, repo.objectDatabase(), tips.items, .{ .ignore_missing_links = true });
        defer reached.deinit();
        for (reached.entries) |entry| try result.mark(entry.oid, island);
    }
    return result;
}
