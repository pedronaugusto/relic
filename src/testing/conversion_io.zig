const std = @import("std");
const relic = @import("../relic.zig");
const shakedown = @import("shakedown");
const Io = std.Io;
const Process = relic.worktree.filter.Process;
const Protocol = relic.worktree.filter.Protocol;

fn request(p: *Process, io: Io, path: []const u8) relic.worktree.filter.ProtocolError!Protocol.Reply {
    const input: Protocol.Request = .{ .command = .clean, .path = path, .content = "input" };
    if (@hasDecl(Process, "request")) return p.request(std.testing.allocator, io, input);
    return p.protocol.request(std.testing.allocator, input);
}

test "phase2 buffered process requests use the current Io and retain unread replies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Two complete replies arrive in the same read. The second request must
    // retain that input while switching its outgoing writes to the new Io.
    const replies = "0013status=success\n00000007ONE00000000" ++
        "0013status=success\n00000007TWO00000000";
    try tmp.dir.writeFile(io, .{ .sub_path = "replies", .data = replies });
    const input = try tmp.dir.openFile(io, "replies", .{});
    defer input.close(io);
    const output = try tmp.dir.createFile(io, "requests", .{});
    defer output.close(io);
    var in_buffer: [1024]u8 = undefined;
    var out_buffer: [1024]u8 = undefined;
    // Only the protocol's borrowed file streams participate in this fixture;
    // there is no child process or Process resource owner to release.
    var p: Process = undefined;
    p.reader = input.readerStreaming(io, &in_buffer);
    p.writer = output.writerStreaming(io, &out_buffer);
    p.protocol = .{ .in = &p.reader.interface, .out = &p.writer.interface };
    const first = try request(&p, io, "one");
    defer std.testing.allocator.free(first.content);
    try std.testing.expectEqualStrings("ONE", first.content);
    try std.testing.expect(p.reader.interface.buffered().len > 0);
    const faults = try shakedown.FaultIo.init(std.testing.allocator, io, .{});
    defer faults.deinit();
    const second = try request(&p, faults.io(), "two");
    defer std.testing.allocator.free(second.content);
    try std.testing.expectEqualStrings("TWO", second.content);
    try std.testing.expect(faults.count(.file_write_streaming) > 0);
    try std.testing.expectEqual(@as(usize, 0), faults.count(.file_read_streaming));
    const plan = [_]shakedown.FaultIo.IoPlan.Entry{.{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } }, .fault = .{ .fail = error.Canceled } }};
    const canceled = try shakedown.FaultIo.init(std.testing.allocator, io, .{ .plan = &plan });
    defer canceled.deinit();
    try std.testing.expectError(error.FilterGone, request(&p, canceled.io(), "three"));
    try std.testing.expect(canceled.count(.file_write_streaming) > 0);
    try std.testing.expect(p.canceled());
}
