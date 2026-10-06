//! SHA-1 collisions: two different objects with one name, which SHAttered
//! showed can be made, so that a received object quietly stands in for one
//! already held. The owners are `hash/sha1dc.zig` (the detecting SHA-1, on
//! for every name a database takes) and `odb/indexpack.zig`, which compares
//! a received object with the one of its name already in the database.

const std = @import("std");
const Io = std.Io;

const hash = @import("../../hash.zig");
const sha1dc = @import("../../hash/sha1dc.zig");
const odb_mod = @import("../../odb.zig");
const indexpack = @import("../../odb/indexpack.zig");
const testgit = @import("../git.zig");

test "git 2.13.0 SHAttered, t0013-sha1dc 'test-sha1 detects shattered pdf': the colliding blocks are detected and named as SHA-1 names them" {
    for ([_][]const u8{ sha1dc.collision_test_vector_a, sha1dc.collision_test_vector_b }) |bytes| {
        var detecting = hash.Hasher.initOptions(.sha1, .{ .detect_collisions = true });
        detecting.update(bytes);
        const named = detecting.final();
        try std.testing.expect(detecting.collisionAttack());
        var plain = hash.Hasher.init(.sha1);
        plain.update(bytes);
        try std.testing.expect(named.eql(plain.final()));
    }
    var innocent = hash.Hasher.initOptions(.sha1, .{ .detect_collisions = true });
    innocent.update("an ordinary file\n");
    _ = innocent.final();
    try std.testing.expect(!innocent.collisionAttack());
}

test "git 2.13.0 SHAttered, t5300-pack-object 'make sure index-pack detects the SHA1 collision': a received object unlike the one of its name is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var corrupt = try testgit.Repo.init(gpa, io, &.{});
    defer corrupt.deinit();
    try corrupt.writeFile(io, "a", "the first file\n");
    try corrupt.writeFile(io, "b", "the second file\n");
    const a = try corrupt.line(io, &.{ "hash-object", "-w", "a" });
    defer gpa.free(a);
    const b = try corrupt.line(io, &.{ "hash-object", "b" });
    defer gpa.free(b);
    // `b`'s name now holds `a`'s bytes: what a collision looks like from
    // here, made as git's test makes it.
    var objects = try corrupt.dir.openDir(io, ".git/objects", .{});
    defer objects.close(io);
    const a_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ a[0..2], a[2..] });
    defer gpa.free(a_path);
    const b_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ b[0..2], b[2..] });
    defer gpa.free(b_path);
    try objects.createDirPath(io, b[0..2]);
    try objects.copyFile(a_path, objects, b_path, io, .{});

    // A pack holding the real `b`, from elsewhere.
    var other = try testgit.Repo.init(gpa, io, &.{});
    defer other.deinit();
    try other.writeFile(io, "b", "the second file\n");
    const again = try other.line(io, &.{ "hash-object", "-w", "b" });
    defer gpa.free(again);
    const input = try std.fmt.allocPrint(gpa, "{s}\n", .{again});
    defer gpa.free(input);
    const pack = try other.runInput(io, &.{ "pack-objects", "--stdout" }, input);
    defer gpa.free(pack);

    var git_dir = try corrupt.gitDir(io);
    defer git_dir.close(io);
    var db = try odb_mod.Odb.open(gpa, io, git_dir, .sha1, .{});
    defer db.deinit(io);
    var pack_dir = try git_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var in: Io.Reader = .fixed(pack);
    var diagnostic: indexpack.Diagnostic = .{};
    try std.testing.expectError(error.HashCollision, indexpack.receive(gpa, io, &db, pack_dir, &in, .{ .diagnostic = &diagnostic }));
    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(b, diagnostic.oid.?.hex(&hex));
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack") or std.mem.endsWith(u8, entry.name, ".idx")) return error.TestUnexpectedResult;
    }
}
