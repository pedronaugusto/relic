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
const airlock = @import("airlock");
const reactor = @import("reactor");

const Index = index_mod.Index;

pub const Error = error{
    /// `core.fsmonitorHookVersion` is neither 1 nor 2.
    InvalidFsmonitorHookVersion,
} || config_mod.PathSettingError || config_mod.ValueError || Io.Cancelable;

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
    /// The daemon's socket where it is not `fsmonitor--daemon.ipc` in
    /// `git_dir`, absolute: a git directory on another machine's volume has
    /// it in `fsmonitor.socketDir`, or in the home directory, named
    /// `.git-fsmonitor-` and the SHA-1 of the working tree's real path
    /// (git's `fsmonitor_ipc__get_path`). Never on Windows, where the pipe
    /// is named after the git directory.
    socket: ?[]const u8 = null,
};

/// The directories `configured` reads against.
pub const Dirs = struct {
    /// The repository's own git directory.
    git_dir: Io.Dir,
    /// The top of the working tree.
    work_tree: Io.Dir,
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
/// value is off, and anything else is a hook's path, a path setting
/// (`config.pathSetting`) found from the top of the working tree, where
/// the hook runs: an `:(optional)` hook that is not there is off. `dirs`
/// are the repository's own git directory, where the daemon listens, and
/// that top; the hook's path lives in `arena`.
pub fn configured(arena: Allocator, io: Io, config: *const config_mod.Config, dirs: Dirs, programs: program.Programs) Self.Error!?Source {
    const entry = config.find("core.fsmonitor") orelse return null;
    const value = entry.value orelse return daemonConfigured(arena, io, config, dirs);
    if (config_mod.parseBool(value)) |on| {
        return if (on) daemonConfigured(arena, io, config, dirs) else null;
    } else |_| {}
    const command = (try config_mod.pathSetting(arena, io, dirs.work_tree, config.context.home, value)) orelse return null;
    if (!try compatible(io, config, dirs)) return null;
    const version: ?u2 = if (config.get("core.fsmonitorhookversion")) |text| switch (config_mod.parseInteger(text) catch return error.InvalidFsmonitorHookVersion) {
        1 => 1,
        2 => 2,
        else => return error.InvalidFsmonitorHookVersion,
    } else null;
    return .{ .hook = .{ .command = command, .version = version, .programs = programs } };
}

/// Whether git makes its own checks of the volumes before it asks a monitor
/// (`HAVE_FSMONITOR_OS_SETTINGS`): where it has a daemon of its own.
const os_settings = builtin.os.tag == .linux or builtin.os.tag.isDarwin() or builtin.os.tag == .windows;

/// git's `check_for_incompatible` for a hook or the daemon: a working tree
/// on another machine's volume is no monitor unless `fsmonitor.allowRemote`
/// is true, nor one whose volume cannot be asked; on Windows neither is a
/// repository under VFS for Git (`core.virtualFilesystem` set at all).
fn compatible(io: Io, config: *const config_mod.Config, dirs: Dirs) Self.Error!bool {
    if (!os_settings) return true;
    const volume = airlock.Volume.of(io, dirs.work_tree) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    if (volume.remote and !try config.getBool("fsmonitor.allowremote", false)) return false;
    if (builtin.os.tag == .windows and config.find("core.virtualfilesystem") != null) return false;
    return true;
}

/// git's daemon, where the checks allow it (`fsm_settings__set_ipc`): the
/// working tree's (`compatible`), then on Linux and macOS the socket's
/// (`check_uds_volume`): its directory on another machine's volume, or on
/// a FAT or NTFS one (`msdos`, `ntfs`), which hold no Unix socket, is no
/// monitor, and so is a directory that cannot be asked.
fn daemonConfigured(arena: Allocator, io: Io, config: *const config_mod.Config, dirs: Dirs) Self.Error!?Source {
    if (!try compatible(io, config, dirs)) return null;
    if (!os_settings or builtin.os.tag == .windows) return .{ .daemon = .{ .git_dir = dirs.git_dir } };
    // `fsmonitor__is_fs_remote(gitdir) < 1`: a git directory that cannot be
    // asked keeps the socket where it is.
    const git_volume: ?airlock.Volume = airlock.Volume.of(io, dirs.git_dir) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => null,
    };
    const moved = if (git_volume) |v| v.remote else false;
    const socket: ?[]const u8 = if (moved) (try movedSocket(arena, io, config, dirs)) orelse return null else null;
    const socket_volume = if (socket) |path| try volumeOfPath(io, std.fs.path.dirname(path) orelse "/") else git_volume;
    if (!takesSockets(socket_volume)) return null;
    return .{ .daemon = .{ .git_dir = dirs.git_dir, .socket = socket } };
}

/// Whether a volume holds the daemon's Unix socket, as `check_uds_volume`
/// asks: one that could not be asked (`null`) does not.
fn takesSockets(volume: ?airlock.Volume) bool {
    const v = volume orelse return false;
    return !v.remote and !std.mem.eql(u8, v.name(), "msdos") and !std.mem.eql(u8, v.name(), "ntfs");
}

/// The volume of the directory at `path`, or `null` when it cannot be
/// opened or asked.
fn volumeOfPath(io: Io, path: []const u8) Io.Cancelable!?airlock.Volume {
    const dir = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer dir.close(io);
    return airlock.Volume.of(io, dir) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        else => null,
    };
}

/// git's socket for a git directory on another machine's volume:
/// `<fsmonitor.socketDir>/.git-fsmonitor-<hex>`, or `~/` in place of an
/// unset or empty directory, the hex the SHA-1 of the working tree's real
/// path, the whole `interpolate_path`'d. A relative directory is found
/// from the top of the working tree, where git runs. `null` when the
/// working tree has no real path.
fn movedSocket(arena: Allocator, io: Io, config: *const config_mod.Config, dirs: Dirs) Self.Error!?[]const u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const top_len = dirs.work_tree.realPath(io, &buffer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    const top = buffer[0..top_len];
    var hasher: hash.Hasher = .init(.sha1);
    hasher.update(top);
    const digest = hasher.final();
    var hex: [hash.max_hex_len]u8 = undefined;
    // A bare `fsmonitor.socketDir` is git's "missing value".
    const dir: []const u8 = if (config.find("fsmonitor.socketdir")) |e| e.value orelse return error.MissingPath else "";
    const written = try arena.print("{s}/.git-fsmonitor-{s}", .{ if (dir.len != 0) dir else "~", digest.hex(&hex) });
    const path = try config_mod.interpolatePath(arena, written, config.context.home);
    if (std.fs.path.isAbsolute(path)) return path;
    return try std.fs.path.join(arena, &.{ top, path });
}

test "a socket's volume takes it unless remote, FAT or NTFS, or unknown" {
    const named = struct {
        fn volume(remote: bool, name: []const u8) airlock.Volume {
            var v: airlock.Volume = .{ .remote = remote, .name_bytes = @splat(0), .name_len = @intCast(name.len) };
            @memcpy(v.name_bytes[0..name.len], name);
            return v;
        }
    }.volume;
    try std.testing.expect(takesSockets(named(false, "apfs")));
    try std.testing.expect(!takesSockets(named(true, "smbfs")));
    try std.testing.expect(!takesSockets(named(false, "msdos")));
    try std.testing.expect(!takesSockets(named(false, "ntfs")));
    // git compares the whole name
    try std.testing.expect(takesSockets(named(false, "ntfs3")));
    try std.testing.expect(!takesSockets(null));
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
    const out = (try converseWithDaemon(arena, io, daemon, since)) orelse return null;
    const end = std.mem.findScalar(u8, out, 0) orelse out.len;
    return .{ .token = out[0..end], .paths = try splitPaths(arena, if (end < out.len) out[end + 1 ..] else "") };
}

/// git's `fsmonitor_ipc__send_query` short of starting a daemon: connect,
/// send `since`, read the answer. `null` when there is no daemon to reach
/// or the conversation fails, as git takes either.
fn converseWithDaemon(arena: Allocator, io: Io, daemon: Daemon, since: []const u8) Error!?[]const u8 {
    const read_buffer = try arena.alloc(u8, pkt_line.max_line);
    var write_buffer: [4096]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const name = (try pipeName(arena, io, daemon.git_dir)) orelse return null;
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
    var stream = (try connectSocket(arena, io, daemon)) orelse return null;
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
            .data => |unparsed| {
                const data = unparsed.readForParse();
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
fn connectSocket(arena: Allocator, io: Io, daemon: Daemon) Error!?Io.net.Stream {
    const address: Io.net.UnixAddress = .{ .path = (try socketPath(arena, io, daemon)) orelse return null };
    var waited_ms: u32 = 0;
    while (true) {
        return reactor.net.connectUnix(io, &address) catch |err| switch (err) {
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
/// Linux through the git directory's handle; `null` when none fits. A
/// socket out of the git directory (`Daemon.socket`) is named absolutely
/// or from the working directory.
fn socketPath(arena: Allocator, io: Io, daemon: Daemon) Error!?[]const u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const absolute = daemon.socket orelse absolute: {
        const dir_len = daemon.git_dir.realPath(io, &buffer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return null,
        };
        break :absolute try std.fs.path.join(arena, &.{ buffer[0..dir_len], daemon_name });
    };
    if (absolute.len <= max_socket_path) return absolute;
    if (std.process.currentPath(io, &buffer)) |cwd_len| {
        const cwd = buffer[0..cwd_len];
        const relative = try std.fs.path.relativeAllocPosix(arena, cwd, cwd, absolute);
        if (relative.len <= max_socket_path) return relative;
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    }
    if (builtin.os.tag == .linux and daemon.socket == null) {
        const through_handle = try arena.print("/proc/self/fd/{d}/" ++ daemon_name, .{daemon.git_dir.handle});
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

test "a git directory on another machine's volume has its socket in fsmonitor.socketDir or the home directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const top = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(top, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const dirs: Dirs = .{ .git_dir = tmp.dir, .work_tree = tmp.dir };
    const cases = [_]struct { text: []const u8, want: []const u8 }{
        .{ .text = "[fsmonitor]\n\tsocketDir = /sockets\n", .want = "/sockets/.git-fsmonitor-" ++ hex },
        .{ .text = "", .want = "/home/me/.git-fsmonitor-" ++ hex },
        .{ .text = "[fsmonitor]\n\tsocketDir =\n", .want = "/home/me/.git-fsmonitor-" ++ hex },
        .{ .text = "[fsmonitor]\n\tsocketDir = ~/s\n", .want = "/home/me/s/.git-fsmonitor-" ++ hex },
        .{ .text = "[fsmonitor]\n\tsocketDir = run\n", .want = try std.fs.path.join(arena, &.{ top, "run/.git-fsmonitor-" ++ hex }) },
    };
    for (cases) |case| {
        var config = try config_mod.Config.parseText(gpa, case.text, .local);
        defer config.deinit();
        config.context.home = "/home/me";
        try std.testing.expectEqualStrings(case.want, (try movedSocket(arena, io, &config, dirs)).?);
    }
    var bare = try config_mod.Config.parseText(gpa, "[fsmonitor]\n\tsocketDir\n", .local);
    defer bare.deinit();
    try std.testing.expectError(error.MissingPath, movedSocket(arena, io, &bare, dirs));
}

test "a working tree whose volume cannot be asked has no monitor, and a local one has its socket in the git directory" {
    if (!os_settings) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const airlock_testing = @import("airlock.testing");
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dirs: Dirs = .{ .git_dir = tmp.dir, .work_tree = tmp.dir };
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const programs: program.Programs = .{ .environ = &env };
    for ([_][]const u8{ "[core]\n\tfsmonitor = true\n", "[core]\n\tfsmonitor = /bin/hook\n" }) |text| {
        var config = try config_mod.Config.parseText(gpa, text, .local);
        defer config.deinit();
        const h = try airlock_testing.Seam.create(gpa, std.testing.io, .{ .plan = &.{airlock_testing.always(.statfs, airlock_testing.io_error)} });
        defer h.destroy();
        try std.testing.expectEqual(null, try configured(arena, h.io(), &config, dirs, programs));
        const source = (try configured(arena, std.testing.io, &config, dirs, programs)).?;
        if (source == .daemon) try std.testing.expectEqual(null, source.daemon.socket);
    }
}
