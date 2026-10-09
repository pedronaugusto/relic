//! Credential injection: a URL whose parts decode to a line break, or say
//! too little, so that git's credential protocol carries a line of the
//! attacker's and a helper hands over another host's secret. The owner is
//! `transport/credential.zig` (the architecture's `wire/credential`): every
//! value goes to a helper through its one item writer, and a URL is read
//! into a request in one place.

const std = @import("std");
const suite = @import("../helpers.zig");
const builtin = @import("builtin");

const credential = @import("../../wire.zig").credential;
const url_mod = @import("../../wire.zig").url;
const config_mod = @import("../../config/config.zig");
const testgit = @import("../git.zig");

/// What a fill sent its one helper, and how it ended.
const Asked = struct {
    gpa: std.mem.Allocator,
    result: anyerror!bool,
    /// The helper's standard input, or `null` when no helper ran.
    sent: ?[]u8,

    fn deinit(a: *Asked) void {
        if (a.sent) |s| a.gpa.free(s);
        a.* = undefined;
    }

    fn lines(a: *const Asked, prefix: []const u8) usize {
        const sent = a.sent orelse return 0;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, sent, '\n');
        while (it.next()) |line| count += @intFromBool(std.mem.startsWith(u8, line, prefix));
        return count;
    }
};

/// Fill a credential for `url_text` with one helper, which keeps what it
/// is asked and answers nothing, and `extra` configuration.
fn fill(gpa: std.mem.Allocator, io: std.Io, url_text: []const u8, extra: []const u8) !Asked {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const record = try gpa.print("{s}/sent", .{dir});
    defer gpa.free(record);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, record, '\\', '/');
    const args = try gpa.print("record '{s}'", .{record});
    defer gpa.free(args);
    const helper = try testgit.fixtureCommand(gpa, suite.path(.process_fixture), args);
    defer gpa.free(helper);
    const text = try gpa.print("[credential]\n\thelper = !{s}\n{s}", .{ helper, extra });
    defer gpa.free(text);
    var config = try config_mod.Config.parseText(gpa, text, .local);
    defer config.deinit();
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();

    var session: credential.Session = .{ .gpa = gpa, .url = try url_mod.Url.parse(url_text) };
    defer session.deinit();
    const result = session.fill(io, .{ .config = &config, .programs = .{ .environ = &env } });
    const sent = tmp.dir.readFileAlloc(io, "sent", gpa, .limited(1 << 16)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    return .{ .gpa = gpa, .result = result, .sent = sent };
}

test "CVE-2020-5260, t0300-credentials 'url parser rejects embedded newlines': no line a URL decodes to reaches a helper" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // The user and the password are decoded, as git decodes them, and
    // refused before any helper hears of them.
    for ([_][]const u8{
        "https://u%0ahost=github.com@attacker.example/r.git",
        "https://u:p%0Ahost=github.com@attacker.example/r.git",
    }) |text| {
        var asked = try fill(gpa, io, text, "");
        defer asked.deinit();
        try std.testing.expectError(error.CredentialValueUnsafe, asked.result);
        try std.testing.expectEqual(null, asked.sent);
    }
    // git's own vector puts the line break after a `?` in the host part,
    // which relic keeps encoded: the helper is asked for that one host, on
    // one line, and for no other.
    var asked = try fill(gpa, io, "https://one.example.com?%0ahost=two.example.com/", "");
    defer asked.deinit();
    try std.testing.expect(asked.sent != null);
    try std.testing.expectEqual(@as(usize, 1), asked.lines("host="));
    try std.testing.expectEqual(@as(usize, 0), asked.lines("host=two.example.com"));
}

test "CVE-2020-11008, t0300-credentials 'credential system refuses to work with missing host': a URL with no host or no scheme describes no credential" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Each of these asked a helper, in git before the fix, for a
    // credential with no host, which a helper matched to any host.
    for ([_][]const u8{ "https:///repo.git", "https://@/repo.git", "https://:443/repo.git", "http://", "https://u:p@/repo.git" }) |text| {
        if (url_mod.Url.parse(text)) |_| {
            std.debug.print("{s} parsed as a URL with a host\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // A request always names the protocol and the host.
    var asked = try fill(gpa, io, "https://example.com/repo.git", "");
    defer asked.deinit();
    try std.testing.expectEqual(@as(usize, 1), asked.lines("protocol=https"));
    try std.testing.expectEqual(@as(usize, 1), asked.lines("host=example.com"));
}

test "CVE-2024-52006, t0300-credentials 'url parser rejects embedded carriage returns': a carriage return reaches a helper only under credential.protectProtocol=false" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var refused = try fill(gpa, io, "https://u%0d@example.com/r.git", "");
    defer refused.deinit();
    try std.testing.expectError(error.CredentialValueUnsafe, refused.result);
    try std.testing.expectEqual(null, refused.sent);

    var allowed = try fill(gpa, io, "https://u%0d@example.com/r.git", "\tprotectProtocol = false\n");
    defer allowed.deinit();
    try std.testing.expect(allowed.sent != null);
    try std.testing.expect(std.mem.find(u8, allowed.sent.?, "username=u\r\n") != null);

    // A host is never decoded into a request, so git's vector there
    // reaches a helper with no carriage return in it at all.
    var host = try fill(gpa, io, "https://example%0d.com/r.git", "");
    defer host.deinit();
    try std.testing.expect(host.sent != null);
    try std.testing.expect(std.mem.findScalar(u8, host.sent.?, '\r') == null);
}
