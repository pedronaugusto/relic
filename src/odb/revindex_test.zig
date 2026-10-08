const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Oid = @import("../hash/hash.zig").Oid;
const Kind = @import("../hash/hash.zig").Kind;
const hash = @import("../hash/hash.zig");
const pack = @import("pack/entry.zig");
const fs = @import("../fs/fs.zig");
const Error = @import("revindex.zig").Error;
const wanted = @import("revindex.zig").wanted;
const write = @import("revindex.zig").write;
const testing = std.testing;
const testremote = @import("../testing/remote.zig");
const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo/repo.zig");

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
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tmp_path);
    try testgit.noRepositoryAbove(&env, tmp_path);
    const out = try testremote.gitInputEnv(gpa, io, tmp.dir, &env, &.{ "index-pack", "--rev-index", "-o", "check.idx", pack_name }, "", true);
    gpa.free(out);
    const ours = try tmp.dir.readFileAlloc(io, rev_name, gpa, .unlimited);
    defer gpa.free(ours);
    const theirs = try tmp.dir.readFileAlloc(io, "check.rev", gpa, .unlimited);
    defer gpa.free(theirs);
    try testing.expectEqualSlices(u8, theirs, ours);
}
