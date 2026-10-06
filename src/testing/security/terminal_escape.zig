//! Terminal escapes: text a remote or a URL chose, shown to a person with
//! its control characters intact, so that it moves the cursor, retitles
//! the window or hides the line that names the real host. The owner is
//! `transport/progress.zig` (the architecture's `report/`): its `sanitize`
//! is what the side-band and every remote message go through; a credential
//! prompt is percent-encoded by `transport/credential.zig`.

const std = @import("std");
const Io = std.Io;

const credential = @import("../../transport/credential.zig");
const url_mod = @import("../../transport/url.zig");
const config_mod = @import("../../config.zig");
const sideband = @import("../../transport/sideband.zig");
const pktline = @import("../../transport/pktline.zig");
const progress = @import("../../transport/progress.zig");

/// The prompts a fill showed, one after another.
const Prompts = struct {
    text: std.ArrayList(u8) = .empty,

    fn ask(gpa: std.mem.Allocator, context: ?*anyopaque, field: credential.Field, prompt: []const u8) std.mem.Allocator.Error!?[]u8 {
        const p: *Prompts = @ptrCast(@alignCast(context.?)); // safe: the context handed out with this function is a Prompts
        try p.text.appendSlice(std.testing.allocator, prompt);
        try p.text.append(std.testing.allocator, '\n');
        const answer = try gpa.dupe(u8, if (field == .password) "askpass-password" else "user");
        return answer;
    }
};

fn prompted(gpa: std.mem.Allocator, io: Io, config_text: []const u8) ![]u8 {
    var config = try config_mod.Config.parseText(gpa, config_text, .local);
    defer config.deinit();
    var prompts: Prompts = .{};
    errdefer prompts.text.deinit(std.testing.allocator);
    var session: credential.Session = .{ .gpa = gpa, .url = try url_mod.Url.parse("https://%07latrix%20Lestrange@example.org/r.git") };
    defer session.deinit();
    try std.testing.expect(try session.fill(io, .{ .config = &config, .prompt = .{ .context = &prompts, .ask = Prompts.ask } }));
    return prompts.text.toOwnedSlice(std.testing.allocator);
}

test "CVE-2024-50349, t0300-credentials 'interactive prompt is sanitized': a prompt names the URL with its control characters encoded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const shown = try prompted(gpa, io, "");
    defer gpa.free(shown);
    try std.testing.expectEqualStrings("Password for 'https://%07latrix%20Lestrange@example.org': \n", shown);
    // credential.sanitizePrompt=false is git's way back to the raw name.
    const raw = try prompted(gpa, io, "[credential]\n\tsanitizePrompt = false\n");
    defer gpa.free(raw);
    try std.testing.expectEqualStrings("Password for 'https://\x07latrix Lestrange@example.org': \n", raw);
}

/// What a side-band of `messages` on channel 2, then `fatal` on channel 3,
/// shows the caller, and what the error kept.
fn heard(gpa: std.mem.Allocator, control: progress.Control, messages: []const []const u8, fatal: []const u8) !struct { progress: []u8, message: []u8 } {
    var wire: Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    for (messages) |text| {
        var line: [256]u8 = undefined;
        line[0] = 2;
        @memcpy(line[1..][0..text.len], text);
        try pktline.write(&wire.writer, line[0 .. text.len + 1]);
    }
    var line: [256]u8 = undefined;
    line[0] = 3;
    @memcpy(line[1..][0..fatal.len], fatal);
    try pktline.write(&wire.writer, line[0 .. fatal.len + 1]);

    const Sink = struct {
        fn report(context: ?*anyopaque, event: progress.Event) void {
            const list: *std.ArrayList(u8) = @ptrCast(@alignCast(context.?)); // safe: the context handed out with this function is a list
            list.appendSlice(std.testing.allocator, event.remote) catch @panic("out of memory");
        }
    };
    var shown: std.ArrayList(u8) = .empty;
    errdefer shown.deinit(gpa);
    var buffer: [pktline.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(wire.written());
    var in = fixed.limited(.unlimited, &buffer);
    var demux: sideband.Demux = .init(&in.interface, &.{}, .{ .context = &shown, .report = Sink.report, .remote_control = control });
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, demux.interface.readSliceShort(&out));
    return .{ .progress = try shown.toOwnedSlice(gpa), .message = try gpa.dupe(u8, demux.message()) };
}

test "CVE-2024-52005, t5409-colorize-remote-messages 'disallow (color) control sequences in sideband': a remote's control sequences are shown, not obeyed" {
    const gpa = std.testing.allocator;
    const messages = [_][]const u8{ "\x1b[31mred\x1b[m\n", "\x1b]0;evil title\x07\x1b[2Jhidden\r", "\x1b[1Aup\n" };
    const fatal = "\x1b[31merror:\x1b[m \x1b[2Kgone\n";

    // git 2.55's default keeps colour and shows the rest.
    const by_default = try heard(gpa, .color, &messages, fatal);
    defer gpa.free(by_default.progress);
    defer gpa.free(by_default.message);
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[m\n^[]0;evil title^G^[[2Jhidden\r^[[1Aup\n", by_default.progress);
    try std.testing.expectEqualStrings("\x1b[31merror:\x1b[m ^[[2Kgone", by_default.message);

    // `sideband.allowControlCharacters=false`: no colour either.
    const none = try heard(gpa, .none, &messages, fatal);
    defer gpa.free(none.progress);
    defer gpa.free(none.message);
    try std.testing.expectEqualStrings("^[[31mred^[[m\n^[]0;evil title^G^[[2Jhidden\r^[[1Aup\n", none.progress);

    // 'allow all control sequences for a specific URL': as the remote sent them.
    const all = try heard(gpa, .all, &messages, fatal);
    defer gpa.free(all.progress);
    defer gpa.free(all.message);
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[m\n\x1b]0;evil title\x07\x1b[2Jhidden\r\x1b[1Aup\n", all.progress);
}
