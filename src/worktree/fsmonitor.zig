//! The file monitor: what changed in the working tree since the index was
//! last written, so that `status` looks at those files and takes the rest
//! as the index has them.
//!
//! git asks a hook, `core.fsmonitor`, run through the shell in the working
//! tree with the protocol version and the token of the last answer. Version 2
//! answers with a new token, a NUL, and the changed paths, each ended by a
//! NUL; version 1 answers with the paths alone and its token is the time of
//! the question. A directory ends in `/`. A lone `/` says the monitor knows
//! nothing, and so does a hook that fails: then every file is looked at.
//! The token and the files the monitor vouches for are kept in the index,
//! in `FSMN`, which is `Index.fsmonitor_token` and `Entry.fsmonitor_valid`.
//!
//! A program can also answer for itself: a `ChangeSource` is asked the same
//! question and answers the same way, with no hook and no watcher behind it
//! that this package knows of. git's own daemon, `core.fsmonitor=true`, is
//! not spoken to: `error.FsmonitorDaemonUnsupported`.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const index_mod = @import("../index.zig");
const hash = @import("../hash.zig");
const program = @import("../repo/program.zig");
const config_mod = @import("../config.zig");

const Index = index_mod.Index;

pub const Error = error{
    /// `core.fsmonitor` is true, which asks for git's built-in daemon.
    FsmonitorDaemonUnsupported,
    /// `core.fsmonitorHookVersion` is neither 1 nor 2.
    InvalidFsmonitorHookVersion,
} || Allocator.Error;

/// An answer: the token to ask with next time, and what changed.
pub const Changes = struct {
    token: []const u8,
    /// The paths that changed, relative to the top of the working tree, a
    /// directory ending in `/`; `null` for "anything may have": every file
    /// is looked at.
    paths: ?[]const []const u8,
};

/// A caller's own monitor, asked as git asks its hook.
pub const ChangeSource = struct {
    context: *anyopaque,
    /// What changed since `token`, or `null` for no answer, which makes
    /// every file be looked at. The answer may live in `arena`.
    queryFn: *const fn (arena: Allocator, context: *anyopaque, token: []const u8) Allocator.Error!?Changes,
};

/// git's hook: `core.fsmonitor` and `core.fsmonitorHookVersion`.
pub const Hook = struct {
    /// The command, run through the shell as git runs it.
    command: []const u8,
    /// 1 or 2; `null` tries 2 and falls back to 1, as git does.
    version: ?u2 = null,
    /// The permission to run it.
    programs: program.Programs,
};

/// Where the changes come from.
pub const Source = union(enum) {
    hook: Hook,
    changes: ChangeSource,
};

/// The hook the configuration names, or `null` when there is none:
/// `core.fsmonitor` unset or false.
pub fn configured(config: *const config_mod.Config, programs: program.Programs) Self.Error!?Source {
    const value = config.get("core.fsmonitor") orelse return null;
    if (config_mod.parseBool(value)) |on| {
        if (on) return error.FsmonitorDaemonUnsupported;
        return null;
    } else |_| {}
    if (value.len == 0) return null;
    const version: ?u2 = if (config.get("core.fsmonitorhookversion")) |text| switch (std.fmt.parseInt(i64, text, 10) catch return error.InvalidFsmonitorHookVersion) {
        1 => 1,
        2 => 2,
        else => return error.InvalidFsmonitorHookVersion,
    } else null;
    return .{ .hook = .{ .command = value, .version = version, .programs = programs } };
}

/// Ask the monitor what changed since the index's token and take every path
/// it names out of what it vouches for, as git's `refresh_fsmonitor` does,
/// then keep its new token. An index that has no token yet gets one, with
/// nothing vouched for. Asked once per index read: a second call does
/// nothing. `wt` is the top of the working tree, where the hook runs.
pub fn refresh(gpa: Allocator, io: Io, wt: Io.Dir, index: *Index, source: Source) Self.Error!void {
    if (index.fsmonitor_refreshed) return;
    index.fsmonitor_refreshed = true;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // `add_fsmonitor`: a first token, the time now, and nothing vouched for.
    const now = try nanoseconds(arena, io);
    if (index.fsmonitor_token == null) {
        index.fsmonitor_token = try gpa.dupe(u8, now);
        index.fsmonitor_changed = true;
        for (index.entries.items) |*entry| entry.fsmonitor_valid = false;
    }
    const since = index.fsmonitor_token.?;

    const answer: ?Changes = switch (source) {
        .changes => |c| try c.queryFn(arena, c.context, since),
        .hook => |h| try askHook(arena, io, wt, h, since, now),
    };
    var token: []const u8 = now;
    if (answer) |a| {
        token = a.token;
        if (a.paths) |paths| {
            for (paths) |path| invalidate(index, path);
            // git's `fsmonitor_force_update_threshold`.
            if (paths.len > 100) index.fsmonitor_changed = true;
        } else invalidateAll(index);
    } else {
        // A failed hook leaves git's question time as the token -- or, where
        // version 2 was asked for and failed, nothing at all.
        if (source == .hook and source.hook.version == 2) token = "";
        invalidateAll(index);
    }
    const kept = try gpa.dupe(u8, token);
    gpa.free(index.fsmonitor_token.?);
    index.fsmonitor_token = kept;
}

/// git's `query_fsmonitor_hook`, version 2 first unless version 1 is asked
/// for, the answer parsed. `null` when the hook gives none.
fn askHook(arena: Allocator, io: Io, wt: Io.Dir, hook: Hook, since: []const u8, now: []const u8) Error!?Changes {
    if (hook.version != 1) {
        if (try runHook(arena, io, wt, hook, "2", since)) |out| {
            const end = std.mem.findScalar(u8, out, 0) orelse out.len;
            // An empty token is no answer, as git warns, and is what git
            // keeps.
            if (end == 0) return .{ .token = "", .paths = null };
            return .{ .token = out[0..end], .paths = try splitPaths(arena, if (end < out.len) out[end + 1 ..] else "") };
        }
        if (hook.version == 2) return null;
    }
    const out = (try runHook(arena, io, wt, hook, "1", since)) orelse return null;
    return .{ .token = now, .paths = try splitPaths(arena, out) };
}

fn runHook(arena: Allocator, io: Io, wt: Io.Dir, hook: Hook, version: []const u8, since: []const u8) Allocator.Error!?[]const u8 {
    var outcome = program.run(hook.programs, arena, io, .{
        .argv = &.{ hook.command, version, since },
        .shell = true,
        .cwd = .{ .dir = wt },
        .stderr = .inherit,
    }, "", .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A hook that cannot be run is a hook that failed.
        else => return null,
    };
    if (!outcome.succeeded()) return null;
    return outcome.stdout;
}

/// The paths of an answer, NUL-separated; `null` for git's trivial answer,
/// a `/` first.
fn splitPaths(arena: Allocator, bytes: []const u8) Allocator.Error!?[]const []const u8 {
    if (bytes.len != 0 and bytes[0] == '/') return null;
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, bytes, 0);
    while (parts.next()) |part| {
        // The NUL that ends the last path leaves nothing after it.
        if (part.len == 0 and parts.index == null) break;
        try out.append(arena, part);
    }
    return out.items;
}

/// `fsmonitor_refresh_callback`: a path the monitor names is no longer
/// vouched for, and neither is anything under it -- a directory may come
/// with its `/` or without.
fn invalidate(index: *Index, path: []const u8) void {
    const dir = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    const items = index.entries.items;
    // The entries for `dir` and those under `dir/` are together in order.
    var at = lowerBound(items, dir);
    while (at < items.len) : (at += 1) {
        const name = items[at].path;
        if (!std.mem.startsWith(u8, name, dir)) break;
        const rest = name[dir.len..];
        if (rest.len == 0 or rest[0] == '/') {
            items[at].fsmonitor_valid = false;
        } else if (rest[0] > '/') break;
    }
}

fn invalidateAll(index: *Index) void {
    for (index.entries.items) |*entry| {
        if (entry.fsmonitor_valid) index.fsmonitor_changed = true;
        entry.fsmonitor_valid = false;
    }
}

fn lowerBound(items: []const index_mod.Entry, path: []const u8) usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.mem.order(u8, items[mid].path, path) == .lt) low = mid + 1 else high = mid;
    }
    return low;
}

/// git's `getnanotime`, as text.
fn nanoseconds(arena: Allocator, io: Io) Allocator.Error![]const u8 {
    const now = Io.Clock.real.now(io);
    return arena.print("{d}", .{@max(now.nanoseconds, 0)});
}

test "an answer's paths and a directory's entries are taken out of what is vouched for" {
    const gpa = std.testing.allocator;
    var index: Index = .initEmpty(gpa, .sha1);
    defer index.deinit();
    const z: hash.Oid = .zero(.sha1);
    try index.addMany(&.{
        .{ .path = "a", .oid = z, .mode = .file, .fsmonitor_valid = true },
        .{ .path = "d.txt", .oid = z, .mode = .file, .fsmonitor_valid = true },
        .{ .path = "d/x", .oid = z, .mode = .file, .fsmonitor_valid = true },
        .{ .path = "d/y/z", .oid = z, .mode = .file, .fsmonitor_valid = true },
        .{ .path = "e", .oid = z, .mode = .file, .fsmonitor_valid = true },
    });
    invalidate(&index, "d");
    invalidate(&index, "a");
    // In index order: a, d.txt, d/x, d/y/z, e.
    var got: [5]bool = undefined;
    for (index.entries.items, &got) |e, *g| g.* = e.fsmonitor_valid;
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, false, true }, &got);
    try std.testing.expect((try splitPaths(gpa, "/")) == null);
}
