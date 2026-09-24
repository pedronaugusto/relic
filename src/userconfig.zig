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
//! `GIT_CONFIG_VALUE_<n>` are values above every file.

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
    /// promises is missing; git refuses both.
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
    /// The home directory, for `~/` in a value and an `includeIf`.
    home: ?[]const u8 = null,
    /// `GIT_CONFIG_KEY_<n>=GIT_CONFIG_VALUE_<n>`, for `Sources.command` and
    /// `Repository.OpenOptions.config_overrides`.
    command: []const []const u8 = &.{},

    /// Release everything.
    pub fn deinit(l: *Locations) void {
        l.arena.deinit();
        l.* = undefined;
    }

    /// The file for a single global slot — `Repository.OpenOptions` and
    /// `config.Sources` have one: the last of `global`, which is the one
    /// whose values win. `unread` names an earlier one it leaves out.
    pub fn globalFile(l: *const Locations) ?[]const u8 {
        if (l.global.len == 0) return null;
        return l.global[l.global.len - 1];
    }

    /// The global file `globalFile` leaves out, when both exist: its
    /// values are not read through a single slot.
    pub fn unread(l: *const Locations) ?[]const u8 {
        if (l.global.len < 2) return null;
        return l.global[0];
    }

    /// `config.Sources` for these files, without a repository's own; the
    /// paths are absolute and borrowed from `l`.
    pub fn sources(l: *const Locations) config_mod.Sources {
        const cwd = Io.Dir.cwd();
        return .{
            .system = if (l.system) |p| .{ .dir = cwd, .sub_path = p } else null,
            .global = if (l.globalFile()) |p| .{ .dir = cwd, .sub_path = p } else null,
            .command = l.command,
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
        if (xdg) |path| if (exists(io, path)) try global.append(arena, path);
        if (l.home) |home| {
            const path = try std.fs.path.join(arena, &.{ home, ".gitconfig" });
            if (exists(io, path)) try global.append(arena, path);
        }
    }
    l.global = global.items;

    // Values above every file.
    if (environ.get("GIT_CONFIG_COUNT")) |count_text| {
        const count = std.fmt.parseUnsigned(u32, std.mem.trim(u8, count_text, " "), 10) catch return error.MalformedConfigEnvironment;
        var pairs: std.ArrayList([]const u8) = .empty;
        for (0..count) |i| {
            var key_buf: [32]u8 = undefined;
            var value_buf: [32]u8 = undefined;
            const key = environ.get(std.fmt.bufPrint(&key_buf, "GIT_CONFIG_KEY_{d}", .{i}) catch unreachable) orelse
                return error.MalformedConfigEnvironment;
            const value = environ.get(std.fmt.bufPrint(&value_buf, "GIT_CONFIG_VALUE_{d}", .{i}) catch unreachable) orelse
                return error.MalformedConfigEnvironment;
            try pairs.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ key, value }));
        }
        l.command = pairs.items;
    }
    return l;
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
    try testing.expectEqualStrings("core.sshCommand=ssh -F none", l.command[0]);

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
