//! URL matching held to git: `git config --get-urlmatch` over a file of
//! `http.<pattern>.k` entries says which entry a URL takes, or why the URL
//! does not normalize. relic's `normalize`, `match` and `Match.order`,
//! applied to the same entries in the same order, must pick the same one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const testgit = @import("../testing/git.zig");
const urlmatch = @import("urlmatch.zig");

const schemes = [_][]const u8{ "https://", "https://", "https://", "http://", "HTTPS://", "file://", "ftp://" };
const users = [_][]const u8{ "", "", "", "", "ada@", "bob@", "ada:pw@", "@", "a%40b@" };
const hosts = [_][]const u8{ "git.example.com", "x.example.com", "Example.COM", "example.com", "[::1]", "h", "git.example.com.", "" };
const pattern_hosts = [_][]const u8{ "git.example.com", "*.example.com", "*.*.com", "example.com", "[::1]", "h", "*", "EXAMPLE.com" };
const ports = [_][]const u8{ "", "", "", "", "", ":", ":80", ":443", ":0443", ":8080", ":08080", ":0", ":x", ":65536" };
const segments = [_][]const u8{ "a", "b", ".", "..", "%61", "%2F", "x%20y", "c%7e", "repo.git", "" };
const tails = [_][]const u8{ "", "", "?q=1", "#f", "?a/b" };

fn randomUrl(random: std.Random, buf: []u8, pattern: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const pick = struct {
        fn one(r: std.Random, list: []const []const u8) []const u8 {
            return list[r.uintLessThan(usize, list.len)];
        }
    }.one;
    w.writeAll(pick(random, &schemes)) catch unreachable; // unreachable: the buffer holds the longest
    w.writeAll(pick(random, &users)) catch unreachable; // unreachable: as above
    w.writeAll(pick(random, if (pattern) &pattern_hosts else &hosts)) catch unreachable; // unreachable: as above
    w.writeAll(pick(random, &ports)) catch unreachable; // unreachable: as above
    for (0..random.uintLessThan(usize, 4)) |_| {
        w.writeByte('/') catch unreachable; // unreachable: as above
        w.writeAll(pick(random, &segments)) catch unreachable; // unreachable: as above
    }
    w.writeAll(pick(random, &tails)) catch unreachable; // unreachable: as above
    return w.buffered();
}

/// git's fatal message for each refusal.
fn reasonOf(err: urlmatch.NormalizeError) []const u8 {
    return switch (err) {
        error.InvalidUrlScheme => "invalid URL scheme name or missing '://' suffix",
        error.InvalidEscape => "invalid %XX escape sequence",
        error.MissingHost => "missing host and scheme is not 'file:'",
        error.FileUrlPort => "a 'file:' URL may not have a port number",
        error.InvalidHostName => "invalid characters in host name",
        error.InvalidPort => "invalid port number",
        error.InvalidDotSegment => "invalid '..' path segment",
    };
}

test "random URLs take the http.<pattern> entry git's urlmatch picks" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    fixture.report_failures = false;
    var prng: std.Random.DefaultPrng = .init(0x0412_a7c4);
    const random = prng.random();

    for (0..testgit.corpusCases(12)) |_| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Patterns, and the entries a config file holds for them in order.
        var file: std.ArrayList(u8) = .empty;
        try file.appendSlice(arena, "[http]\n\tk = base\n");
        var patterns: std.ArrayList(?urlmatch.Info) = .empty;
        for (0..20) |n| {
            var buf: [160]u8 = undefined;
            const text = try arena.dupe(u8, randomUrl(random, &buf, true));
            // A pattern the config file cannot quote is left out.
            if (std.mem.findAny(u8, text, "\"\\") != null) continue;
            try file.print(arena, "[http \"{s}\"]\n\tk = p{d}\n", .{ text, n });
            try patterns.append(arena, urlmatch.normalize(arena, text, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            });
        }
        try fixture.writeFile(io, "urlmatch.cfg", file.items);

        for (0..25) |_| {
            var buf: [160]u8 = undefined;
            const text = randomUrl(random, &buf, false);
            var answer = try fixture.capture(io, &.{ "config", "-f", "urlmatch.cfg", "--get-urlmatch", "http.k", text });
            defer answer.deinit(gpa);
            errdefer std.debug.print("url: {s}\ngit: {s}{s}\nconfig:\n{s}\n", .{ text, answer.stdout, answer.stderr, file.items });
            const url = urlmatch.normalize(arena, text, false) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| {
                    const fatal = std.mem.trimEnd(u8, answer.stderr, "\r\n");
                    try testing.expectEqualStrings(try arena.print("fatal: {s}", .{reasonOf(e)}), fatal);
                    continue;
                },
            };
            var best: urlmatch.Match = .any;
            var chosen: []const u8 = "base";
            var index: usize = 0;
            var lines = std.mem.splitScalar(u8, file.items, '\n');
            while (lines.next()) |line| {
                const value = std.mem.trimStart(u8, line, "\t");
                if (!std.mem.startsWith(u8, value, "k = p")) continue;
                defer index += 1;
                const pattern = patterns.items[index] orelse continue;
                const matched = urlmatch.match(url, pattern) orelse continue;
                if (matched.order(best) == .lt) continue;
                best = matched;
                chosen = value["k = ".len..];
            }
            try testing.expectEqualStrings(std.mem.trimEnd(u8, answer.stdout, "\r\n"), chosen);
        }
    }
}
