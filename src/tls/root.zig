//! TLS for relic's connections: the standard library's client with client
//! certificates added, and the reading of the keys and certificates it
//! answers with. Nothing here imports anything but the standard library.

/// A TLS 1.2 and 1.3 client that answers a server's request for a
/// certificate.
pub const Client = @import("Client.zig");
/// A certificate chain and key, ready for handshakes.
pub const ClientAuth = @import("ClientAuth.zig");
/// Keys and certificates from PEM and DER files.
pub const key = @import("key.zig");

test "nothing here imports anything but the standard library and its own files" {
    const std = @import("std");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = std.Io.Dir.cwd().openDir(io, "src/tls", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);
    var it = dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        files += 1;
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "@import(\"")) |start| {
            const name_start = start + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse return error.TestUnexpectedResult;
            const name = text[name_start..end];
            at = end;
            if (std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "builtin")) continue;
            if (std.mem.indexOfScalar(u8, name, '/') == null and std.mem.endsWith(u8, name, ".zig")) {
                dir.access(io, name, .{}) catch return error.TestUnexpectedResult;
                continue;
            }
            std.debug.print("{s} imports {s}\n", .{ entry.name, name });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(files >= 6);
}

test {
    _ = Client;
    _ = ClientAuth;
    _ = key;
    _ = @import("der.zig");
    _ = @import("rsa.zig");
}
