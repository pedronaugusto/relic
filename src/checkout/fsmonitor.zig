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
//! git's own daemon, `core.fsmonitor=true`, is asked the same question
//! over the connection it listens on in the git directory,
//! `fsmonitor--daemon.ipc`: a Unix socket, or on Windows the named pipe
//! named after that path. The question is the token in pkt-lines and a
//! flush, the answer the version 2 answer in pkt-lines up to a flush. With
//! no daemon listening every file is looked at and the token kept is
//! `builtin:fake`, as git keeps it when its daemon does not answer; git
//! starts its daemon first, and this package, which runs no git, does not.
//!
//! A program can also answer for itself: a `ChangeSource` is asked the same
//! question and answers the same way, with no hook and no watcher behind it
//! that this package knows of.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const index_mod = @import("../index/index.zig");
const hash = @import("../hash/hash.zig");
const program = @import("../process.zig").program;
const config_mod = @import("../config/config.zig");
const pkt_line = @import("../codec.zig").pkt_line;

const Index = index_mod.Index;

pub const Error = error{
    /// `core.fsmonitorHookVersion` is neither 1 nor 2.
    InvalidFsmonitorHookVersion,
} || config_mod.PathError || Io.Cancelable;

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

/// git's built-in daemon, `git fsmonitor--daemon`.
pub const Daemon = struct {
    /// The repository's own git directory -- a linked worktree's, not the
    /// common one -- in which the daemon listens.
    git_dir: Io.Dir,
};

/// Where the changes come from.
pub const Source = union(enum) {
    hook: Hook,
    daemon: Daemon,
    changes: ChangeSource,
};

/// The monitor the configuration names, or `null` when there is none, as
/// git reads `core.fsmonitor`: a boolean (git's spellings, a bare name and
/// any integer included) turns git's daemon on or everything off, an empty
/// value is off, and anything else is a hook's path, `~` expanded against
/// the configuration's home. `git_dir` is the repository's own git
/// directory, where the daemon listens; the hook's path lives in `arena`
/// or borrows the configuration.
pub fn configured(arena: Allocator, config: *const config_mod.Config, git_dir: Io.Dir, programs: program.Programs) Self.Error!?Source {
    const entry = config.find("core.fsmonitor") orelse return null;
    const value = entry.value orelse return .{ .daemon = .{ .git_dir = git_dir } };
    if (config_mod.parseBool(value)) |on| {
        return if (on) .{ .daemon = .{ .git_dir = git_dir } } else null;
    } else |_| {}
    const command = try config_mod.interpolatePath(arena, value, config.context.home);
    const version: ?u2 = if (config.get("core.fsmonitorhookversion")) |text| switch (config_mod.parseInteger(text) catch return error.InvalidFsmonitorHookVersion) {
        1 => 1,
        2 => 2,
        else => return error.InvalidFsmonitorHookVersion,
    } else null;
    return .{ .hook = .{ .command = command, .version = version, .programs = programs } };
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
        .daemon => |d| try askDaemon(arena, io, d, since),
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
        // version 2 was asked for and failed, nothing at all; a daemon that
        // does not answer leaves git's `builtin:fake`.
        switch (source) {
            .hook => |h| if (h.version == 2) {
                token = "";
            },
            .daemon => token = "builtin:fake",
            .changes => {},
        }
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
    var outcome = program.run(arena, io, hook.programs, .{
        .argv = &.{ hook.command, version, since },
        .shell = true,
        .cwd = .{ .dir = wt },
        .stderr = .inherit,
    }, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A hook that cannot be run is a hook that failed.
        else => return null,
    };
    if (!outcome.succeeded()) return null;
    return outcome.stdout;
}

/// The name of the daemon's connection in the git directory.
const daemon_name = "fsmonitor--daemon.ipc";

/// git's IPC branch of `refresh_fsmonitor`: the token, then the version 2
/// answer. `null` when no daemon answers.
fn askDaemon(arena: Allocator, io: Io, daemon: Daemon, since: []const u8) Error!?Changes {
    const out = (try converseWithDaemon(arena, io, daemon.git_dir, since)) orelse return null;
    const end = std.mem.findScalar(u8, out, 0) orelse out.len;
    return .{ .token = out[0..end], .paths = try splitPaths(arena, if (end < out.len) out[end + 1 ..] else "") };
}

/// git's `fsmonitor_ipc__send_query` short of starting a daemon: connect,
/// send `since`, read the answer. `null` when there is no daemon to reach
/// or the conversation fails, as git takes either.
fn converseWithDaemon(arena: Allocator, io: Io, git_dir: Io.Dir, since: []const u8) Error!?[]const u8 {
    const read_buffer = try arena.alloc(u8, pkt_line.max_line);
    var write_buffer: [4096]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const name = (try pipeName(arena, io, git_dir)) orelse return null;
        const pipe = Io.Dir.openFileAbsolute(io, name, .{ .mode = .read_write }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return null,
        };
        defer pipe.close(io);
        var writer = pipe.writerStreaming(io, &write_buffer);
        var reader = pipe.readerStreaming(io, read_buffer);
        return exchange(arena, &writer.interface, &reader.interface, since);
    }
    if (!Io.net.has_unix_sockets) return null;
    var stream = (try connectSocket(arena, io, git_dir)) orelse return null;
    defer stream.close(io);
    var writer = stream.writer(io, &write_buffer);
    var reader = stream.reader(io, read_buffer);
    return exchange(arena, &writer.interface, &reader.interface, since);
}

/// git's `ipc_client_send_command_to_connection`: the message in lines of
/// at most `pkt_line.max_data` and a flush; the answer the data of every
/// line up to a flush, a delim, a response end or a line with no data,
/// whichever comes first. A broken line or the end of the stream before
/// one of those is no answer.
fn exchange(arena: Allocator, w: *Io.Writer, r: *Io.Reader, message: []const u8) Allocator.Error!?[]const u8 {
    var rest = message;
    while (rest.len != 0) {
        const n = @min(rest.len, pkt_line.max_data);
        pkt_line.write(w, rest[0..n]) catch return null;
        rest = rest[n..];
    }
    pkt_line.flush(w) catch return null;
    w.flush() catch return null;
    var answer: std.ArrayList(u8) = .empty;
    while (true) {
        const packet = pkt_line.read(r) catch return null;
        switch (packet) {
            .flush, .delim, .response_end => break,
            .data => |data| {
                if (data.len == 0) break;
                try answer.appendSlice(arena, data);
            },
        }
    }
    return answer.items;
}

/// The longest socket path `connect` takes, its NUL not counted.
const max_socket_path = if (builtin.os.tag == .windows or !Io.net.has_unix_sockets)
    0
else
    @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len - 1;

/// git's `connect_to_server`: a refused connection is a daemon too busy to
/// take it, tried again every 50 ms for a second; anything else, a socket
/// that is not there among them, is no daemon.
fn connectSocket(arena: Allocator, io: Io, git_dir: Io.Dir) Error!?Io.net.Stream {
    const address: Io.net.UnixAddress = .{ .path = (try socketPath(arena, io, git_dir)) orelse return null };
    var waited_ms: u32 = 0;
    while (true) {
        return address.connect(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionRefused, error.WouldBlock => {
                if (waited_ms >= 1000) return null;
                try io.sleep(.fromMilliseconds(50), .awake);
                waited_ms += 50;
                continue;
            },
            else => return null,
        };
    }
}

/// The name the daemon's socket is reached by. git names it from its
/// working directory, `.git/fsmonitor--daemon.ipc` at the top of a working
/// tree, so a deep repository's socket is reached where its absolute name
/// is past what a socket address holds. This package names it absolutely
/// where that fits, else from the process's working directory, else on
/// Linux through the git directory's handle; `null` when none fits.
fn socketPath(arena: Allocator, io: Io, git_dir: Io.Dir) Error!?[]const u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = git_dir.realPath(io, &buffer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    const absolute = try std.fs.path.join(arena, &.{ buffer[0..dir_len], daemon_name });
    if (absolute.len <= max_socket_path) return absolute;
    if (std.process.currentPath(io, &buffer)) |cwd_len| {
        const cwd = buffer[0..cwd_len];
        const relative = try std.fs.path.relativeAllocPosix(arena, cwd, cwd, absolute);
        if (relative.len <= max_socket_path) return relative;
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    }
    if (builtin.os.tag == .linux) {
        const through_handle = try arena.print("/proc/self/fd/{d}/" ++ daemon_name, .{git_dir.handle});
        if (through_handle.len <= max_socket_path) return through_handle;
    }
    return null;
}

/// git for Windows' pipe name for the daemon: `\\.\pipe\` and the
/// connection's real path, the drive's `:` as `_` and every `/` a `\`.
/// `null` when the git directory has no real path or the name is past
/// `MAX_PATH`, where git gives up too.
fn pipeName(arena: Allocator, io: Io, git_dir: Io.Dir) Error!?[]const u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = git_dir.realPath(io, &buffer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    const name = try std.mem.concat(arena, u8, &.{ "\\\\.\\pipe\\", buffer[0..dir_len], "\\", daemon_name });
    const path = name["\\\\.\\pipe\\".len..];
    if (path.len >= 2 and path[1] == ':') path[1] = '_';
    std.mem.replaceScalar(u8, name, '/', '\\');
    const wide = std.unicode.calcWtf16LeLen(name) catch return null;
    if (wide >= 260) return null;
    return name;
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
