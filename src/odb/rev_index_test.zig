const std = @import("std");
const hash = @import("../hash/hash.zig");
const testing = std.testing;
const testremote = @import("../testing/remote.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const rev_index = @import("rev_index.zig");

test "a pack relic writes has the reverse index git's index-pack writes for it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testremote.historyRepo(gpa, io, 6);
    defer source.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, source.dir, .{});
    defer repo.deinit(io);
    var collected = try repo.objectDatabase().collectAll(io, .{});
    defer collected.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const report = try repo.objectDatabase().writePack(io, tmp.dir, collected.entries, .{ .reverse_index = true });
    var hex: [hash.max_hex_len]u8 = undefined;
    const base = try gpa.print("pack-{s}", .{report.name.hex(&hex)});
    defer gpa.free(base);
    const pack_name = try gpa.print("{s}.pack", .{base});
    defer gpa.free(pack_name);
    const rev_name = try gpa.print("{s}.rev", .{base});
    defer gpa.free(rev_name);
    // Outside any repository: index-pack reads the pack it is given.
    var env = try testremote.environ(gpa);
    defer env.deinit();
    const out = try testremote.gitInputEnv(gpa, io, tmp.dir, &env, &.{ "index-pack", "--rev-index", "-o", "check.idx", pack_name }, "", true);
    gpa.free(out);
    const ours = try tmp.dir.readFileAlloc(io, rev_name, gpa, .unlimited);
    defer gpa.free(ours);
    const theirs = try tmp.dir.readFileAlloc(io, "check.rev", gpa, .unlimited);
    defer gpa.free(theirs);
    try testing.expectEqualSlices(u8, theirs, ours);
}

test "pack.writeReverseIndex that is no boolean is refused, as git dies on it" {
    var config = try config_mod.Config.parseText(testing.allocator,
        \\[pack]
        \\    writeReverseIndex = sometimes
    , .local);
    defer config.deinit();
    try testing.expectError(error.NotABoolean, rev_index.wanted(&config));
    try testing.expect(try rev_index.wanted(null));
}
