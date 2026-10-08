//! Memory a client spends on a server: a fetch that says the same `have`
//! again and again, which upload-pack kept once per line until git 2.51.1.
//! The owner is `transport/uploadpack.zig`, where relic serves fetches:
//! each object a client has is kept once, whatever its type.

const std = @import("std");
const Io = std.Io;

const local = @import("../../transport/local.zig");
const uploadpack = @import("../../transport/uploadpack.zig");
const pktline = @import("../../codec/pktline.zig");
const protocol = @import("../../wire/protocol.zig");
const testgit = @import("../git.zig");

/// How many `ACK <tree>` lines relic's upload-pack answers a request that
/// wants the commit and says it has its tree `repeat` times.
fn acks(gpa: std.mem.Allocator, io: Io, version: protocol.Version, repeat: usize) !usize {
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "f", "x\n");
    try git.exec(io, &.{ "add", "f" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const commit = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(commit);
    const tree = try git.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree);
    const path = try git.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);

    var request: Io.Writer.Allocating = .init(gpa);
    defer request.deinit();
    const w = &request.writer;
    if (version == .v2) {
        try pktline.write(w, "command=fetch\n");
        try pktline.write(w, "object-format=sha1\n");
        try pktline.delim(w);
    }
    try pktline.print("want {s}\n", .{commit}, w);
    if (version != .v2) try pktline.flush(w);
    for (0..repeat) |_| try pktline.print("have {s}\n", .{tree}, w);
    try pktline.flush(w);

    var remote = try local.Remote.open(gpa, io, path, .{});
    defer remote.deinit(io);
    var server = uploadpack.Server.init(gpa, io, &remote, version, .{ .stateless = true });
    var in_buffer: [pktline.max_line]u8 = undefined;
    var request_reader: Io.Reader = .fixed(request.written());
    var in = request_reader.limited(.unlimited, &in_buffer);
    var answer: Io.Writer.Allocating = .init(gpa);
    defer answer.deinit();
    try server.serveRequest(&in.interface, &answer.writer);

    var count: usize = 0;
    var buffer: [pktline.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(answer.written());
    var reader = fixed.limited(.unlimited, &buffer);
    while (pktline.read(&reader.interface)) |packet| switch (packet) {
        .data => |line| {
            if (std.mem.startsWith(u8, line, "ACK ") and std.mem.find(u8, line, tree) != null) count += 1;
        },
        else => {},
    } else |_| {}
    return count;
}

test "git 2.51.1, t5530-upload-pack-error 'upload-pack ACKs repeated non-commit objects repeatedly (protocol v0)': a repeated have is kept once and acknowledged each time" {
    try std.testing.expectEqual(@as(usize, 2), try acks(std.testing.allocator, std.testing.io, .v0, 2));
    try std.testing.expectEqual(@as(usize, 500), try acks(std.testing.allocator, std.testing.io, .v0, 500));
}

test "git 2.51.1, t5530-upload-pack-error 'upload-pack ACKs repeated non-commit objects once only (protocol v2)': a repeated have is kept and acknowledged once" {
    try std.testing.expectEqual(@as(usize, 1), try acks(std.testing.allocator, std.testing.io, .v2, 2));
    try std.testing.expectEqual(@as(usize, 1), try acks(std.testing.allocator, std.testing.io, .v2, 500));
}
