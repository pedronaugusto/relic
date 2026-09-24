//! Where the person's git reads its configuration from.
//!
//! A remote that works from a terminal works because of settings the person
//! never wrote into the repository: the credential helper their installer
//! put in the system file — `osxkeychain` from Homebrew, `manager` from git
//! for Windows — the `gh auth setup-git` lines in `~/.gitconfig`, an
//! `insteadOf` rewrite, a `core.sshCommand`. A library that reads only
//! `.git/config` asks the person to set up again what already works, and
//! this module is what spares them that.
//!
//! The library reads no environment of its own, so the caller hands in the
//! one to read, and the answer is git's: the system file is `GIT_CONFIG_SYSTEM`,
//! or none under `GIT_CONFIG_NOSYSTEM`, or wherever the person's own `git`
//! was built to look — which only that `git` knows, so it is asked, with
//! `git var GIT_CONFIG_SYSTEM`, when the caller grants `Programs`. The
//! global files are `GIT_CONFIG_GLOBAL`, or `$XDG_CONFIG_HOME/git/config`
//! (`~/.config/git/config`) and then `~/.gitconfig`, both read, the second
//! winning. And `GIT_CONFIG_COUNT` with its `GIT_CONFIG_KEY_<n>` and
//! `GIT_CONFIG_VALUE_<n>`, then `GIT_CONFIG_PARAMETERS` — where `git -c`
//! leaves its values for the programs it starts — are values above every
//! file, in that order.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const program = @import("program.zig");
const config_mod = @import("config.zig");

/// Errors from finding the configuration.
pub const Error = error{
    /// `GIT_CONFIG_COUNT` is not a number, or a `GIT_CONFIG_KEY_<n>` it
    /// promises is missing, or `GIT_CONFIG_PARAMETERS` is not quoted as git
    /// quotes it; git refuses all three.
    MalformedConfigEnvironment,
} || Allocator.Error || Io.Cancelable;

/// The files and values git would read, and in what order.
pub const Locations = struct {
    arena: std.heap.ArenaAllocator,
    /// The system file, when there is one to read. `null` under
    /// `GIT_CONFIG_NOSYSTEM`, and when no `git` could be asked and nothing
    /// in the environment names it — see `system_known`.
    system: ?[]const u8 = null,
    /// Whether `system` is git's answer rather than a guess left empty.
    system_known: bool = false,
    /// The global files in the order git reads them, only those that
    /// exist: the XDG one, then `~/.gitconfig`; or `GIT_CONFIG_GLOBAL`.
    global: []const []const u8 = &.{},
    /// The XDG one of them, when it is one: `config.Sources.xdg`.
    xdg: ?[]const u8 = null,
    /// The home directory, for `~/` in a value and an `includeIf`.
    home: ?[]const u8 = null,
    /// `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>`, then what
    /// `GIT_CONFIG_PARAMETERS` holds, for `Sources.pairs` and
    /// `Repository.OpenOptions.config_pairs`.
    pairs: []const config_mod.Sources.Pair = &.{},

    /// Release everything.
    pub fn deinit(l: *Locations) void {
        l.arena.deinit();
        l.* = undefined;
    }

    /// The global file that is not the XDG one — `~/.gitconfig`, or
    /// `GIT_CONFIG_GLOBAL` — for the `global` slot of `config.Sources` and
    /// `Repository.OpenOptions`.
    pub fn globalFile(l: *const Locations) ?[]const u8 {
        if (l.global.len == 0) return null;
        const last = l.global[l.global.len - 1];
        if (l.xdg) |x| if (x.ptr == last.ptr) return null;
        return last;
    }

    /// `config.Sources` for these files and values, without a repository's
    /// own; the paths are absolute and borrowed from `l`.
    pub fn sources(l: *const Locations) config_mod.Sources {
        const cwd = Io.Dir.cwd();
        return .{
            .system = if (l.system) |p| .{ .dir = cwd, .sub_path = p } else null,
            .xdg = if (l.xdg) |p| .{ .dir = cwd, .sub_path = p } else null,
            .global = if (l.globalFile()) |p| .{ .dir = cwd, .sub_path = p } else null,
            .pairs = l.pairs,
        };
    }
};

/// Where git would read configuration from for a person whose environment
/// is `environ`. With `programs`, their `git` is asked where its system
/// file is; without, only the environment can say.
pub fn locate(gpa: Allocator, io: Io, environ: *const Environ.Map, programs: ?program.Programs) Error!Locations {
    var l: Locations = .{ .arena = .init(gpa) };
    errdefer l.arena.deinit();
    const arena = l.arena.allocator();

    l.home = environ.get("HOME") orelse if (builtin.os.tag == .windows) environ.get("USERPROFILE") else null;
    if (l.home) |h| l.home = try arena.dupe(u8, h);

    // The system file.
    if (isTrue(environ.get("GIT_CONFIG_NOSYSTEM"))) {
        l.system_known = true;
    } else if (environ.get("GIT_CONFIG_SYSTEM")) |path| {
        l.system = try arena.dupe(u8, path);
        l.system_known = true;
    } else if (programs) |p| {
        if (try askGit(arena, io, p, "GIT_CONFIG_SYSTEM")) |answer| {
            var lines = std.mem.tokenizeAny(u8, answer, "\r\n");
            if (lines.next()) |path| l.system = path;
            l.system_known = true;
        }
    }
    if (l.system) |path| {
        if (!exists(io, path)) l.system = null;
    }

    // The global files.
    var global: std.ArrayList([]const u8) = .empty;
    if (environ.get("GIT_CONFIG_GLOBAL")) |path| {
        if (path.len != 0 and exists(io, path)) try global.append(arena, try arena.dupe(u8, path));
    } else {
        const xdg: ?[]const u8 = if (environ.get("XDG_CONFIG_HOME")) |base|
            if (base.len != 0) try std.fs.path.join(arena, &.{ base, "git", "config" }) else null
        else if (l.home) |home|
            try std.fs.path.join(arena, &.{ home, ".config", "git", "config" })
        else
            null;
        if (xdg) |path| if (exists(io, path)) {
            try global.append(arena, path);
            l.xdg = path;
        };
        if (l.home) |home| {
            const path = try std.fs.path.join(arena, &.{ home, ".gitconfig" });
            if (exists(io, path)) try global.append(arena, path);
        }
    }
    l.global = global.items;

    // Values above every file.
    var pairs: std.ArrayList(config_mod.Sources.Pair) = .empty;
    if (environ.get("GIT_CONFIG_COUNT")) |count_text| {
        const count = std.fmt.parseUnsigned(u32, std.mem.trim(u8, count_text, " "), 10) catch return error.MalformedConfigEnvironment;
        for (0..count) |i| {
            var key_buf: [32]u8 = undefined;
            var value_buf: [32]u8 = undefined;
            const key = environ.get(std.fmt.bufPrint(&key_buf, "GIT_CONFIG_KEY_{d}", .{i}) catch unreachable) orelse
                return error.MalformedConfigEnvironment;
            const value = environ.get(std.fmt.bufPrint(&value_buf, "GIT_CONFIG_VALUE_{d}", .{i}) catch unreachable) orelse
                return error.MalformedConfigEnvironment;
            try pairs.append(arena, .{ .name = try arena.dupe(u8, key), .value = try arena.dupe(u8, value) });
        }
    }
    if (environ.get("GIT_CONFIG_PARAMETERS")) |text| {
        try pairs.appendSlice(arena, try parseParameters(arena, text));
    }
    l.pairs = pairs.items;
    return l;
}

/// Read `GIT_CONFIG_PARAMETERS` as git's `parse_config_env_list` reads it:
/// single-quoted words apart by white space, each either `'name=value'`,
/// the old form, split at its first `=`, or `'name'='value'`, where the
/// name may hold `=`, or `'name'=`, a bare name. Inside quotes nothing is
/// special; `'\''` and `'\!'` put a quote or a `!` between two quoted
/// parts. Anything else is `MalformedConfigEnvironment`, as git says
/// "bogus format". The result is `arena`'s.
pub fn parseParameters(arena: Allocator, text: []const u8) Error![]const config_mod.Sources.Pair {
    var out: std.ArrayList(config_mod.Sources.Pair) = .empty;
    var cur: ?usize = 0;
    while (cur) |at| {
        if (at >= text.len) break;
        const key = try dequoteStep(arena, text, at) orelse return error.MalformedConfigEnvironment;
        var next = key.next;
        if (next == null or isSpace(text[next.?])) {
            // The old form, 'name=value'.
            const eq = std.mem.indexOfScalar(u8, key.text, '=');
            const name = key.text[0 .. eq orelse key.text.len];
            if (name.len == 0) return error.MalformedConfigEnvironment;
            try out.append(arena, .{ .name = name, .value = if (eq) |e| key.text[e + 1 ..] else null });
        } else if (text[next.?] == '=') {
            const after = next.? + 1;
            var value: ?[]const u8 = null;
            if (after < text.len and text[after] == '\'') {
                const v = try dequoteStep(arena, text, after) orelse return error.MalformedConfigEnvironment;
                if (v.next) |n| if (!isSpace(text[n])) return error.MalformedConfigEnvironment;
                value = v.text;
                next = v.next;
            } else if (after >= text.len or isSpace(text[after])) {
                next = after;
            } else return error.MalformedConfigEnvironment;
            try out.append(arena, .{ .name = key.text, .value = value });
        } else return error.MalformedConfigEnvironment;
        if (next) |n| {
            var k = n;
            while (k < text.len and isSpace(text[k])) k += 1;
            cur = k;
        } else cur = null;
    }
    return out.items;
}

const Step = struct {
    text: []const u8,
    /// Where the text goes on after the word; `null` at its end.
    next: ?usize,
};

/// git's `sq_dequote_step`: one single-quoted word at `start`, or `null`
/// when there is none or it does not end.
fn dequoteStep(arena: Allocator, text: []const u8, start: usize) Allocator.Error!?Step {
    if (start >= text.len or text[start] != '\'') return null;
    var out: std.ArrayList(u8) = .empty;
    var i = start;
    while (true) {
        i += 1;
        if (i >= text.len) return null;
        if (text[i] != '\'') {
            try out.append(arena, text[i]);
            continue;
        }
        // Out of the quotes.
        i += 1;
        if (i >= text.len) return .{ .text = out.items, .next = null };
        if (text[i] == '\\' and i + 2 < text.len and (text[i + 1] == '\'' or text[i + 1] == '!') and text[i + 2] == '\'') {
            try out.append(arena, text[i + 1]);
            i += 2;
            continue;
        }
        return .{ .text = out.items, .next = i };
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isTrue(value: ?[]const u8) bool {
    const v = value orelse return false;
    return config_mod.parseBool(v) catch false;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// `git var <name>`, run as the person runs git: the answer, or `null` when
/// git is not there, is older than the variable (2.42), or has no answer.
fn askGit(arena: Allocator, io: Io, programs: program.Programs, name: []const u8) Error!?[]const u8 {
    var outcome = program.run(programs, arena, io, .{
        .argv = &.{ "git", "var", name },
        .stderr = .ignore,
        .unset = &program.repository_variables,
    }, "", .{ .output = .limited(64 * 1024) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return null,
    };
    if (!outcome.succeeded()) return null;
    return outcome.stdout;
}

const testing = std.testing;
const testgit = @import("testgit.zig");

test "the files are the ones git names, found from the person's environment" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var home = testing.tmpDir(.{});
    defer home.cleanup();
    const home_path = try home.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home_path);
    try home.dir.createDirPath(io, ".config/git");
    try home.dir.writeFile(io, .{ .sub_path = ".config/git/config", .data = "[x]\n\ta = xdg\n" });
    try home.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = "[x]\n\ta = home\n" });
    try home.dir.writeFile(io, .{ .sub_path = "system", .data = "[credential]\n\thelper = osxkeychain\n" });
    const system = try std.fs.path.join(gpa, &.{ home_path, "system" });
    defer gpa.free(system);

    var env: Environ.Map = .init(gpa);
    defer env.deinit();
    const path = testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try env.put("PATH", path);
    try env.put("HOME", home_path);
    try env.put("GIT_CONFIG_SYSTEM", system);
    try env.put("GIT_CONFIG_COUNT", "1");
    try env.put("GIT_CONFIG_KEY_0", "core.sshCommand");
    try env.put("GIT_CONFIG_VALUE_0", "ssh -F none");

    var l = try locate(gpa, io, &env, .{ .environ = &env });
    defer l.deinit();
    try testing.expectEqualStrings(system, l.system.?);
    try testing.expectEqual(@as(usize, 2), l.global.len);
    try testing.expect(std.mem.endsWith(u8, l.global[0], ".config/git/config"));
    try testing.expect(std.mem.endsWith(u8, l.global[1], ".gitconfig"));
    try testing.expectEqualStrings("core.sshCommand", l.pairs[0].name);
    try testing.expectEqualStrings("ssh -F none", l.pairs[0].value.?);
    try testing.expectEqualStrings(l.global[0], l.xdg.?);
    try testing.expectEqualStrings(l.global[1], l.globalFile().?);

    // git itself names the same files, in the same order.
    var outcome = try program.run(.{ .environ = &env }, gpa, io, .{ .argv = &.{ "git", "var", "GIT_CONFIG_GLOBAL" } }, "", .{});
    defer outcome.deinit(gpa);
    if (outcome.succeeded()) {
        var lines = std.mem.tokenizeScalar(u8, outcome.stdout, '\n');
        for (l.global) |ours| try testing.expectEqualStrings(lines.next().?, ours);
    }

    // Without leave to run git, and with no GIT_CONFIG_SYSTEM, the system
    // file is not guessed at.
    _ = env.swapRemove("GIT_CONFIG_SYSTEM");
    var bare = try locate(gpa, io, &env, null);
    defer bare.deinit();
    try testing.expect(bare.system == null);
    try testing.expect(!bare.system_known);
    // Asked, git says where it was built to look; and with no system
    // file wanted, there is none.
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    var none = try locate(gpa, io, &env, .{ .environ = &env });
    defer none.deinit();
    try testing.expect(none.system == null);
    try testing.expect(none.system_known);
}

/// `git config --list` in `env`, the command-line values alone, one per
/// line; `null` when git refuses them.
fn gitCommandValues(gpa: Allocator, io: Io, dir: Io.Dir, env: *const Environ.Map) !?[]u8 {
    var outcome = try program.run(.{ .environ = env }, gpa, io, .{
        .argv = &.{ "git", "config", "--list", "--show-scope" },
        .cwd = .{ .dir = dir },
        .stderr = .ignore,
    }, "", .{});
    defer outcome.deinit(gpa);
    if (!outcome.succeeded()) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, outcome.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "command\t")) try out.print(gpa, "{s}\n", .{line["command\t".len..]});
    }
    return try out.toOwnedSlice(gpa);
}

/// The same list from relic's reading: the command-line entries as git
/// lists them.
fn relicCommandValues(gpa: Allocator, io: Io, pairs: []const config_mod.Sources.Pair) ![]u8 {
    var config = try config_mod.Config.open(gpa, io, .{ .pairs = pairs }, .{});
    defer config.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (config.entries.items) |e| {
        try out.print(gpa, "{s}", .{e.section});
        if (e.has_subsection) try out.print(gpa, ".{s}", .{e.subsection});
        try out.print(gpa, ".{s}", .{e.name});
        if (e.value) |v| try out.print(gpa, "={s}", .{v});
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "GIT_CONFIG_PARAMETERS and GIT_CONFIG_COUNT are read as git reads them, both quotings, and refused where git refuses them" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var home = testing.tmpDir(.{});
    defer home.cleanup();
    const home_path = try home.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home_path);
    var env: Environ.Map = .init(gpa);
    defer env.deinit();
    const path = testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try env.put("PATH", path);
    try env.put("HOME", home_path);
    try env.put("XDG_CONFIG_HOME", home_path);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");

    for ([_][]const u8{
        "'x.a=old' 'url.a=b.insteadof'='c' 'x.B'= 'x.q'='it'\\''s'",
        "'x.a'='1'   'x.b'='two words'\t'x.c=a=b'",
        "'x.e'\\!'x'='!'",
        "'x.bare'",
        "",
        "'x.a'=bad",
        "x.a=1",
        " 'x.a=1'",
        "'x.a",
        "'x.a'='1''x.b'='2'",
        "'=v'",
    }) |text| {
        try env.put("GIT_CONFIG_PARAMETERS", text);
        // A count's values come first, as git reads them.
        try env.put("GIT_CONFIG_COUNT", "1");
        try env.put("GIT_CONFIG_KEY_0", "x.a");
        try env.put("GIT_CONFIG_VALUE_0", "count");
        const theirs = try gitCommandValues(gpa, io, home.dir, &env);
        defer if (theirs) |t| gpa.free(t);
        var l = locate(gpa, io, &env, null) catch |err| {
            try testing.expectEqual(error.MalformedConfigEnvironment, err);
            try testing.expect(theirs == null);
            continue;
        };
        defer l.deinit();
        const ours = relicCommandValues(gpa, io, l.pairs) catch |err| {
            // A name git's own parse refuses as well.
            try testing.expectEqual(error.InvalidKey, err);
            try testing.expect(theirs == null);
            continue;
        };
        defer gpa.free(ours);
        testing.expect(theirs != null) catch |err| {
            std.debug.print("git refused {s}, relic read:\n{s}", .{ text, ours });
            return err;
        };
        try testing.expectEqualStrings(theirs.?, ours);
    }
}

test "the XDG file and ~/.gitconfig are both read, the second winning, as git reads them" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var home = testing.tmpDir(.{ .iterate = true });
    defer home.cleanup();
    const home_path = try home.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home_path);
    try home.dir.createDirPath(io, ".config/git");
    try home.dir.writeFile(io, .{ .sub_path = ".config/git/config", .data = "[x]\n\ta = xdg\n\tb = xdg only\n" });
    try home.dir.writeFile(io, .{ .sub_path = ".gitconfig", .data = "[x]\n\ta = home\n" });
    var env: Environ.Map = .init(gpa);
    defer env.deinit();
    const path = testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try env.put("PATH", path);
    try env.put("HOME", home_path);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");

    var l = try locate(gpa, io, &env, null);
    defer l.deinit();
    var config = try config_mod.Config.open(gpa, io, l.sources(), .{ .home = l.home });
    defer config.deinit();
    for ([_][]const u8{ "x.a", "x.b" }) |name| {
        var outcome = try program.run(.{ .environ = &env }, gpa, io, .{
            .argv = &.{ "git", "config", "--get-all", name },
            .cwd = .{ .dir = home.dir },
            .unset = &program.repository_variables,
        }, "", .{});
        defer outcome.deinit(gpa);
        const values = try config.all(name);
        defer gpa.free(values);
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        for (values) |v| try joined.print(gpa, "{s}\n", .{v});
        try testing.expectEqualStrings(outcome.stdout, joined.items);
    }
    try testing.expectEqualStrings("home", config.get("x.a").?);
}

test "fuzz: any GIT_CONFIG_PARAMETERS is read into pairs or refused by name" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const text = buf[0..smith.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const pairs = parseParameters(arena.allocator(), text) catch |err| switch (err) {
                error.MalformedConfigEnvironment => return,
                else => return err,
            };
            for (pairs) |p| try testing.expect(p.name.len <= text.len);
        }
    }.one, .{ .corpus = &.{ "'a.b'='c'", "'a.b=c' 'd.e'=", "'x'\\''y'" } });
}
