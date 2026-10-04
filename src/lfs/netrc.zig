//! `~/.netrc`: a login and password per host, which git-lfs reads before it
//! asks any credential helper.
//!
//! The file is a stream of words: `machine <host>` begins an entry and
//! `default` one that stands for any host, and `login`, `password` and
//! `account` fill the entry in. `macdef <name>` begins a macro that runs to
//! the first blank line, and is passed over. A `#` begins a comment to the
//! end of the line. A word may be in double quotes, with a backslash
//! escaping the character after it. An entry is found as git-lfs's reader
//! finds it: the first for the host whose login matches when a login is
//! asked for, else the last `default` entry.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One entry.
pub const Machine = struct {
    /// The host, or `null` for the `default` entry.
    name: ?[]const u8,
    login: []const u8 = "",
    password: []const u8 = "",
    account: []const u8 = "",
};

/// A parsed file. Every slice is owned by its arena.
pub const Netrc = struct {
    arena: std.heap.ArenaAllocator,
    machines: []const Machine,

    /// Read `text`, which is not kept. A file that is not what the format
    /// describes is `error.MalformedNetrc`, which git-lfs also refuses to
    /// use.
    pub fn parse(gpa: Allocator, text: []const u8) (Allocator.Error || error{MalformedNetrc})!Netrc {
        var n: Netrc = .{ .arena = .init(gpa), .machines = &.{} };
        errdefer n.arena.deinit();
        const a = n.arena.allocator();
        var machines: std.ArrayList(Machine) = .empty;
        var words: Words = .{ .text = text };
        while (try words.next(a)) |word| {
            if (std.mem.eql(u8, word, "machine")) {
                const name = (try words.next(a)) orelse return error.MalformedNetrc;
                try machines.append(a, .{ .name = name });
            } else if (std.mem.eql(u8, word, "default")) {
                try machines.append(a, .{ .name = null });
            } else if (std.mem.eql(u8, word, "login") or std.mem.eql(u8, word, "password") or std.mem.eql(u8, word, "account")) {
                const value = (try words.next(a)) orelse return error.MalformedNetrc;
                if (machines.items.len == 0) return error.MalformedNetrc;
                const m = &machines.items[machines.items.len - 1];
                switch (word[0]) {
                    'l' => m.login = value,
                    'p' => m.password = value,
                    else => m.account = value,
                }
            } else if (std.mem.eql(u8, word, "macdef")) {
                _ = (try words.next(a)) orelse return error.MalformedNetrc;
                words.skipMacro();
            } else return error.MalformedNetrc;
        }
        n.machines = machines.items;
        return n;
    }

    /// The entry for `host`, whose login is `login` when one is given, or
    /// the `default` entry.
    pub fn find(n: *const Netrc, host: []const u8, login: ?[]const u8) ?Machine {
        var fallback: ?Machine = null;
        for (n.machines) |m| {
            const name = m.name orelse {
                fallback = m;
                continue;
            };
            if (!std.mem.eql(u8, name, host)) continue;
            if (login) |l| {
                if (l.len != 0 and !std.mem.eql(u8, l, m.login)) continue;
            }
            return m;
        }
        return fallback;
    }

    /// Release everything.
    pub fn deinit(n: *Netrc) void {
        n.arena.deinit();
        n.* = undefined;
    }
};

const Words = struct {
    text: []const u8,
    at: usize = 0,

    fn skipSpace(w: *Words) void {
        while (w.at < w.text.len) {
            const c = w.text[w.at];
            if (c == '#') {
                while (w.at < w.text.len and w.text[w.at] != '\n') w.at += 1;
            } else if (std.ascii.isWhitespace(c)) {
                w.at += 1;
            } else return;
        }
    }

    fn next(w: *Words, a: Allocator) (Allocator.Error || error{MalformedNetrc})!?[]const u8 {
        w.skipSpace();
        if (w.at >= w.text.len) return null;
        if (w.text[w.at] != '"') {
            const start = w.at;
            while (w.at < w.text.len and !std.ascii.isWhitespace(w.text[w.at])) w.at += 1;
            return try a.dupe(u8, w.text[start..w.at]);
        }
        w.at += 1;
        var out: std.ArrayList(u8) = .empty;
        while (w.at < w.text.len) : (w.at += 1) {
            const c = w.text[w.at];
            if (c == '"') {
                w.at += 1;
                return out.items;
            }
            if (c == '\\') {
                w.at += 1;
                if (w.at >= w.text.len) return error.MalformedNetrc;
            }
            try out.append(a, w.text[w.at]);
        }
        return error.MalformedNetrc;
    }

    /// Pass over a macro's body: everything to the first blank line.
    fn skipMacro(w: *Words) void {
        while (w.at < w.text.len and w.text[w.at] != '\n') w.at += 1;
        while (w.at < w.text.len) {
            w.at += 1;
            const line_end = std.mem.indexOfScalarPos(u8, w.text, w.at, '\n') orelse w.text.len;
            if (std.mem.trim(u8, w.text[w.at..line_end], " \t\r").len == 0) {
                w.at = line_end;
                return;
            }
            w.at = line_end;
        }
    }
};

const testing = std.testing;

test "a netrc's entries are found by host and login, with the last default after them" {
    var n = try Netrc.parse(testing.allocator,
        \\# a comment
        \\machine git.example.com login ada password secret
        \\machine git.example.com
        \\    login bob
        \\    password "hunter 2"
        \\macdef init
        \\echo machine evil login x password y
        \\
        \\default login anonymous password "\"quoted\""
        \\
    );
    defer n.deinit();
    try testing.expectEqualStrings("secret", n.find("git.example.com", null).?.password);
    try testing.expectEqualStrings("hunter 2", n.find("git.example.com", "bob").?.password);
    try testing.expectEqualStrings("\"quoted\"", n.find("other.example.com", null).?.password);
    try testing.expect(n.find("evil", null).?.name == null);
    try testing.expectError(error.MalformedNetrc, Netrc.parse(testing.allocator, "login before machine"));
    try testing.expectError(error.MalformedNetrc, Netrc.parse(testing.allocator, "machine"));
}

test "fuzz: any netrc is read or refused by name" {
    try testing.fuzz({}, fuzzNetrc, .{});
}

fn fuzzNetrc(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [512]u8 = undefined;
    const len = smith.slice(&scratch);
    var n = Netrc.parse(testing.allocator, scratch[0..len]) catch |err| switch (err) {
        error.MalformedNetrc => return,
        else => return err,
    };
    defer n.deinit();
    for (n.machines) |m| {
        if (m.name) |name| _ = n.find(name, m.login);
    }
}
