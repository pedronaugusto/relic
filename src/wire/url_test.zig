//! What a remote's URL names, held to git itself.
//!
//! Each address is given to git twice. `git ls-remote` under
//! `protocol.allow=never` stops at the transport it chose, naming it
//! (`transport 'ssh' not allowed`, the helper's name for a helper), or at
//! its refusal of the address (`no path specified`, `git-over-rsync`).
//! `git fetch-pack --diag-url` prints how an ssh or file address splits:
//! the target ssh is given, the port and the path. relic's `helperOf`,
//! `Url.parse` and `Identity.parse` must say the same, for a list of
//! addresses from git's own tests and for random ones over the characters
//! that matter to the grammar. Nothing is dialled: git stops before any
//! connection, and relic only parses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const testgit = @import("../testing/git.zig");
const url_mod = @import("url.zig");
const policy = @import("policy.zig");
const decimal = @import("../text.zig").decimal;

/// Addresses from git's t5500 (`--diag-url`), t5601 and t5813, with the
/// edges of each rule: scheme case, helper names, `rsync:`, ports by
/// `strtol`, brackets, `~` paths, escapes and missing paths.
const listed = [_][]const u8{
    "ssh://host/repo",              "ssh://user@host:2222/srv/repo.git", "git+ssh://host/~user/repo",
    "ssh+git://host/repo",          "SSH://host/repo",                   "Ssh+git://host/repo",
    "HTTPS://host/repo",            "https://host/repo",                 "http://user:pw@host:8080/r",
    "git://host/~user/repo",        "git://host",                        "ssh://host",
    "ssh://host:22",                "ssh://host:/repo",                  "ssh://host:+22/repo",
    "ssh://host: 22/repo",          "ssh://host:-0/repo",                "ssh://host:00022/repo",
    "ssh://host:65535/repo",        "ssh://host:65536/repo",             "ssh://host:0x16/repo",
    "ssh://host:abc/repo",          "ssh://u:p@host:22/repo",            "ssh://user@domain@host:2222/r@w.git",
    "ssh://[::1]:22/repo",          "ssh://::1/repo",                    "ssh://[user@::1]:22/~repo",
    "ssh://user@[::1]:/home/repo",  "ssh://[host:1]/repo",               "ssh://u@[h]x:22/repo",
    "ssh://[u@h]/repo",             "ssh://host?x/repo",                 "ssh://host/repo#frag",
    "ssh://ho%73t/r%20e%2Fpo",      "ssh://h/%7Euser/repo",              "[::1]:owner/repo.git",
    "user@[::1]:rep/home/project",  "[user@::1]:123",                    "[::1]:/~repo",
    "host:/~repo",                  "[myhost:123]:src",                  "user@[myhost:123]:src",
    "[u:p@h:22]:r",                 "host:abc:r",                        "h:22:r",
    "host:a~b",                     "host:~x",                           "host:",
    "host:a::b",                    "c:temp",                            "1foo://host/repo",
    "1foo::addr",                   "a.b::x",                            "+a::x",
    "ext::ssh -i key host %S repo", "rsync://host/repo",                 "rsync:host",
    "rsync::addr",                  "foo/bar:baz",                       "[foo]bar/baz:qux",
    "[foo/bar]:baz",                "./ext::repo",                       "./folder/ssh://host/repo",
    "file:///srv/repo.git",         "file://host/srv/repo",              "file://host",
    "file:///a%20b/%25",            "/srv/a:b",                          "../other/repo",
    "file://[h]/x",                 "http:foo",                          "ssh:/x",
};

test "every listed address names the transport and the target git names" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    fixture.report_failures = false;
    for (listed) |text| try expectAsGit(gpa, io, &fixture, text);
}

test "random addresses over the grammar's characters name what git names" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    fixture.report_failures = false;
    var prng: std.Random.DefaultPrng = .init(0x7e1c_0b5e);
    const random = prng.random();
    const starts = [_][]const u8{ "ssh://", "git+ssh://", "file://", "git://", "https://", "x::", "", "", "u@", "[" };
    const alphabet = "ah1:/@[]~%2+.-?#3";
    var buf: [48]u8 = undefined;
    for (0..testgit.corpusCases(300)) |_| {
        const start = starts[random.uintLessThan(usize, starts.len)];
        @memcpy(buf[0..start.len], start);
        const len = start.len + 1 + random.uintLessThan(usize, 14);
        for (buf[start.len..len]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        // A leading `-` would be an option to git, not an address.
        if (buf[0] == '-') buf[0] = 'a';
        try expectAsGit(gpa, io, &fixture, buf[0..len]);
    }
}

/// What git decided about an address.
const GitChoice = union(enum) {
    /// The transport, or the helper's name.
    transport: []const u8,
    /// `fatal: git-over-rsync is no longer supported`.
    rsync,
    /// `fatal: no path specified`.
    no_path,
    /// `fatal: protocol '...' is not supported`: a `://` after something
    /// that is no scheme git connects to.
    unsupported,
    /// `fatal: strange pathname '-...' blocked`, said before the transport
    /// is checked; relic's ssh refuses it as `SuspiciousPathname`.
    strange_path,
};

fn expectAsGit(gpa: Allocator, io: Io, fixture: *testgit.Repo, text: []const u8) !void {
    var listing = try fixture.capture(io, &.{ "-c", "protocol.allow=never", "-c", "protocol.file.allow=never", "ls-remote", text });
    defer listing.deinit(gpa);
    const choice = readChoice(listing.stderr) orelse {
        std.debug.print("git said of {s}: {s}\n", .{ text, listing.stderr });
        return error.UnreadableGitAnswer;
    };
    errdefer std.debug.print("address: {s}\ngit: {s}", .{ text, listing.stderr });

    if (url_mod.helperOf(text)) |helper| {
        try testing.expectEqualStrings(choice.transport, helper.name);
        return;
    }
    const parsed = url_mod.Url.parse(text) catch |err| switch (err) {
        error.UnsupportedTransport => {
            try testing.expect(choice == .rsync or choice == .unsupported);
            return;
        },
        error.MalformedUrl => switch (choice) {
            .no_path => return,
            // An ssh target with no host, which ssh refuses where relic
            // refuses it here; or `user@[other@host]`, which git joins as
            // `user@other@host`, a target no slice of the address spells.
            .transport => |name| if (std.mem.eql(u8, name, "ssh")) {
                const diag = try fixture.run(io, &.{ "fetch-pack", "--diag-url", text });
                defer gpa.free(diag);
                const target = diagField(diag, "userandhost").?;
                const host = if (std.mem.findScalarLast(u8, target, '@')) |at| target[at + 1 ..] else target;
                if (host.len == 0) return;
                try testing.expect(std.mem.find(u8, text, "@[") != null);
                try testing.expect(std.mem.count(u8, target, "@") >= 2);
                return;
            } else if (std.mem.eql(u8, name, "git")) {
                // `git://`, which relic refuses by name when it connects.
                return;
            } else {
                // An http address git hands to curl, which judges its host and
                // port later; relic judges them here.
                try testing.expect(std.mem.startsWith(u8, text, "http"));
                try testing.expect(std.mem.eql(u8, name, "http") or std.mem.eql(u8, name, "https"));
                return;
            },
            // Refused by both: git for the path, relic for the empty host.
            .strange_path => return,
            .rsync, .unsupported => return error.TestUnexpectedResult,
        },
    };
    if (choice == .strange_path) {
        var identity = try url_mod.Identity.parse(gpa, text);
        defer identity.deinit();
        try testing.expectEqual(url_mod.Scheme.ssh, identity.url.scheme);
        try testing.expect(identity.url.path[0] == '-');
        return;
    }
    try testing.expectEqualStrings(choice.transport, policy.nameOf(parsed.scheme));
    switch (parsed.scheme) {
        .ssh, .file, .local => try expectSplitAsGit(gpa, io, fixture, text),
        .git, .http, .https => {},
    }
}

fn readChoice(stderr: []const u8) ?GitChoice {
    const fatal = "fatal: ";
    const at = std.mem.find(u8, stderr, fatal) orelse return null;
    const said = stderr[at + fatal.len ..];
    if (std.mem.startsWith(u8, said, "transport '")) {
        const name = said["transport '".len..];
        const end = std.mem.find(u8, name, "' not allowed") orelse return null;
        return .{ .transport = name[0..end] };
    }
    if (std.mem.startsWith(u8, said, "git-over-rsync")) return .rsync;
    if (std.mem.startsWith(u8, said, "no path specified")) return .no_path;
    if (std.mem.startsWith(u8, said, "strange pathname '-")) return .strange_path;
    if (std.mem.startsWith(u8, said, "protocol '") and std.mem.find(u8, said, "' is not supported") != null) return .unsupported;
    return null;
}

fn expectSplitAsGit(gpa: Allocator, io: Io, fixture: *testgit.Repo, text: []const u8) !void {
    const diag = try fixture.run(io, &.{ "fetch-pack", "--diag-url", text });
    defer gpa.free(diag);
    var identity = try url_mod.Identity.parse(gpa, text);
    defer identity.deinit();
    const url = identity.url;
    const protocol = diagField(diag, "protocol").?;
    if (url.scheme == .ssh) {
        try testing.expectEqualStrings("ssh", protocol);
        var target_buf: [128]u8 = undefined;
        const target = if (url.user) |user| try std.mem.print(&target_buf, "{s}@{s}", .{ user, url.host }) else url.host;
        try testing.expectEqualStrings(diagField(diag, "userandhost").?, target);
        const port_text = diagField(diag, "port").?;
        const port: ?u16 = if (std.mem.eql(u8, port_text, "NONE")) null else @intCast(decimal.strtol(port_text, 10, 64).value);
        try testing.expectEqual(port, url.port);
    } else try testing.expectEqualStrings("file", protocol);
    const path = diagField(diag, "path").?;
    if (url.scheme == .local and !std.mem.eql(u8, path, url.path)) {
        // git's `git_connect` starts a local path at `host_end`, past a
        // leading `[...`, so `git fetch '[a]b'` asks for `]b` while
        // `git clone '[a]b'` reaches the directory named. relic reaches
        // the directory named, for both.
        const start = if (std.mem.find(u8, text, "@[")) |at| at + 1 else 0;
        try testing.expect(text[start] == '[');
        const close = std.mem.findScalarPos(u8, text, start + 1, ']').?;
        try testing.expectEqualStrings(text[close..], path);
        return;
    }
    try testing.expectEqualStrings(path, url.path);
}

fn diagField(diag: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, diag, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const prefix = "Diag: ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        if (std.mem.startsWith(u8, rest, name) and rest.len > name.len and rest[name.len] == '=') return rest[name.len + 1 ..];
    }
    return null;
}
