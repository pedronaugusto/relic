const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Oid = @import("hash.zig").Oid;
const Kind = @import("hash.zig").Kind;
const access = @import("revindex.zig").test_access;
const hash = access.hash;
const pack = access.pack;
const fs = access.fs;
const config_mod = access.config_mod;
const Error = @import("revindex.zig").Error;
const wanted = @import("revindex.zig").wanted;
const write = @import("revindex.zig").write;
const testing = access.testing;
const testremote = access.testremote;
const testgit = @import("testgit.zig");
const repo_mod = @import("repo_core.zig");

test "a pack relic writes has the reverse index git's index-pack writes for it" {
    const gpa = testing.allocator;
    const io = testing.io;
    // `index-pack --rev-index` is git 2.31's.
    try testgit.requireGitVersion(gpa, io, 2, 31);
    var source = try testremote.historyRepo(gpa, io, 6);
    defer source.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, source.dir, .{});
    defer repo.deinit(io);
    var collected = try repo.odb.collectAll(io, .{});
    defer collected.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const report = try repo.odb.writePack(io, tmp.dir, collected.entries, .{ .reverse_index = true });
    var hex: [hash.max_hex_len]u8 = undefined;
    const base = try std.fmt.allocPrint(gpa, "pack-{s}", .{report.name.hex(&hex)});
    defer gpa.free(base);
    const pack_name = try std.fmt.allocPrint(gpa, "{s}.pack", .{base});
    defer gpa.free(pack_name);
    const rev_name = try std.fmt.allocPrint(gpa, "{s}.rev", .{base});
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
