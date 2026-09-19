const std = @import("std");
const relic = @import("relic");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    _ = io;
    const oid = relic.hash.Hasher.object(.sha1, "blob", "");
    var buf: [relic.hash.max_hex_len]u8 = undefined;
    std.debug.assert(std.mem.eql(u8, oid.hex(&buf), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
    _ = gpa;
}
