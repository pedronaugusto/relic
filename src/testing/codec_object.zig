const std = @import("std");
const relic = @import("../relic.zig");

test "phase2 a loose object's Adler checksum is verified before returning content" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for ([_]relic.hash.Kind{ .sha1, .sha256 }) |kind| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "objects/pack");
        const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
        defer objects.close(io);
        var db = try relic.odb.Odb.openAt(gpa, io, objects, kind, .{ .probe_timestamp_resolution = false });
        defer db.deinit(io);
        const oid = try db.write(io, .blob, "checksum contract\n");
        var hex: [relic.hash.max_hex_len]u8 = undefined;
        const text = oid.hex(&hex);
        const path = try gpa.print("{s}/{s}", .{ text[0..2], text[2..] });
        defer gpa.free(path);
        const stored = try objects.readFileAlloc(io, path, gpa, .limited(1024));
        defer gpa.free(stored);
        stored[stored.len - 1] ^= 1;
        try objects.deleteFile(io, path);
        try objects.writeFile(io, .{ .sub_path = path, .data = stored });
        var refused = false;
        if (db.read(io, oid)) |found| {
            gpa.free(found.bytes);
        } else |err| {
            try std.testing.expectEqual(error.CorruptLooseObject, err);
            refused = true;
        }
        try std.testing.expect(refused);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try std.testing.expectError(error.CorruptLooseObject, db.readInto(io, oid, &out));
    }
}
