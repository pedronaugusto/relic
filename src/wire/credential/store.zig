//! git's `credential-store`, in process: credentials kept in plain text,
//! one URL a line, in `~/.git-credentials` and git's XDG `credentials`
//! file, or the one `--file` names.
//!
//! A line is a URL with the username and password in it, every part
//! percent-encoded as git encodes it; a line that is not one, or lacks
//! either, is left as it is. `get` answers with the first line, file by
//! file, whose parts include every part asked about; `store` puts the
//! credential first in the first file there is (the first named, made,
//! when none is), dropping each line it replaces; `erase` drops every line
//! that matches, password included, from every file. A file is rewritten
//! under its lock, waited for `credentialStore.lockTimeoutMS`, and made
//! readable by its owner alone, as git's `umask(077)` makes it.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("../../fs/fs.zig");
const parts_mod = @import("parts.zig");

pub const Error = error{
    /// A file could not be locked within the timeout: git's "unable to
    /// get credential storage lock in <n> ms".
    LockTimeout,
} || Allocator.Error || Io.Cancelable || fs.LockFile.OpenError || fs.CommitError || Io.Dir.ReadFileAllocError || Io.Writer.Error;

/// The parts of a credential the helper is handed, borrowed.
pub const Credential = struct {
    protocol: ?[]const u8 = null,
    host: ?[]const u8 = null,
    path: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// What `get` found, in the caller's allocator; the caller wipes the
/// password.
pub const Found = struct { username: []u8, password: []u8 };

/// Which files, and how long a lock is waited for.
pub const Files = struct {
    /// Absolute paths, in git's order.
    paths: []const []const u8,
    lock_timeout_ms: u32 = 1000,
};

/// git's files for `credential-store` with no `--file`:
/// `~/.git-credentials`, then `$XDG_CONFIG_HOME/git/credentials` (else
/// `~/.config/git/credentials`); either is left out when its directory
/// cannot be named. `arena`'s.
pub fn defaultFiles(arena: Allocator, environ: *const std.process.Environ.Map) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const home = environ.get("HOME");
    if (home) |h| try out.append(arena, try Io.Dir.path.join(arena, &.{ h, ".git-credentials" }));
    if (environ.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len != 0) {
        try out.append(arena, try Io.Dir.path.join(arena, &.{ xdg, "git", "credentials" }));
        return out.items;
    };
    if (home) |h| try out.append(arena, try Io.Dir.path.join(arena, &.{ h, ".config", "git", "credentials" }));
    return out.items;
}

/// The file's text, or `null` when it cannot be read for not being there
/// or for want of permission, which git passes over.
fn readFile(gpa: Allocator, io: Io, path: []const u8) Self.Error!?[]u8 {
    return fs.readWhole(Io.Dir.cwd(), io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied => null,
        else => |e| e,
    };
}

/// One line of a file: its text, and the credential in it when it holds
/// one with a username and a password.
fn entryOf(gpa: Allocator, line: []const u8) Allocator.Error!?parts_mod.UrlParts {
    var parts = parts_mod.UrlParts.read(gpa, line, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parts.username == null or parts.password == null) {
        parts.deinit(gpa);
        return null;
    }
    return parts;
}

/// git's `lookup_credential`: the first line, file by file, that holds
/// a credential with every part of `want`'s but its password.
pub fn get(gpa: Allocator, io: Io, files: Files, want: Credential) Self.Error!?Found {
    for (files.paths) |path| {
        const text = (try readFile(gpa, io, path)) orelse continue;
        defer {
            std.crypto.secureZero(u8, text);
            gpa.free(text);
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var entry = (try entryOf(gpa, line)) orelse continue;
            defer entry.deinit(gpa);
            if (!parts_mod.credentialMatch(want, &entry, false)) continue;
            const username = try gpa.dupe(u8, entry.username.?);
            errdefer gpa.free(username);
            return .{ .username = username, .password = try gpa.dupe(u8, entry.password.?.expose()) };
        }
    }
    return null;
}

/// git's `store_credential`: nothing for a credential without a protocol,
/// a host or a path, a username and a password; else its line first in
/// the first file that is there, or the first named.
pub fn store(gpa: Allocator, io: Io, files: Files, c: Credential) Self.Error!void {
    if (c.protocol == null or (c.host == null and c.path == null) or c.username == null or c.password == null) return;
    if (files.paths.len == 0) return;
    var line: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, line.items);
        line.deinit(gpa);
    }
    try line.print(gpa, "{s}://", .{c.protocol.?});
    try encode(gpa, &line, c.username.?, false);
    try line.append(gpa, ':');
    try encode(gpa, &line, c.password.?, false);
    try line.append(gpa, '@');
    if (c.host) |host| try encode(gpa, &line, host, false);
    if (c.path) |path| {
        try line.append(gpa, '/');
        try encode(gpa, &line, path, true);
    }
    const target = for (files.paths) |path| {
        if (exists(io, path)) break path;
    } else files.paths[0];
    try rewrite(gpa, io, target, files.lock_timeout_ms, .{ .first = line.items, .drop = c, .match_password = false });
}

/// git's `remove_credential`: nothing for a pattern with none of the
/// protocol, host, path and username; else every matching line, password
/// included, from every file that is there.
pub fn erase(gpa: Allocator, io: Io, files: Files, c: Credential) Self.Error!void {
    if (c.protocol == null and c.host == null and c.path == null and c.username == null) return;
    for (files.paths) |path| {
        if (!exists(io, path)) continue;
        try rewrite(gpa, io, path, files.lock_timeout_ms, .{ .first = null, .drop = c, .match_password = true });
    }
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const Rewrite = struct { first: ?[]const u8, drop: Credential, match_password: bool };

/// git's `rewrite_credential_file`: under the file's lock, `how.first`
/// and then every line but those matching `how.drop`.
fn rewrite(gpa: Allocator, io: Io, path: []const u8, timeout_ms: u32, how: Rewrite) Self.Error!void {
    const dir_name = Io.Dir.path.dirname(path) orelse ".";
    var dir = try Io.Dir.cwd().openDir(io, dir_name, .{});
    defer dir.close(io);
    var buffer: [4096]u8 = undefined;
    var lock = fs.LockFile.open(gpa, io, dir, .{ .sub_path = Io.Dir.path.basename(path), .buffer = &buffer }, .{
        .on_contention = .{ .wait = .fromMilliseconds(timeout_ms) },
        .sync = .none,
        .shared = .{ .mode = 0o600 },
    }) catch |err| return switch (err) {
        error.LockHeld => error.LockTimeout,
        else => |e| e,
    };
    defer lock.deinit(io);
    const w = &lock;
    if (how.first) |line| {
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    if (try readFile(gpa, io, path)) |text| {
        defer {
            std.crypto.secureZero(u8, text);
            gpa.free(text);
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            // The text after the last newline is no line: git's getline.
            if (lines.index == null and line.len == 0) break;
            if (try entryOf(gpa, line)) |entry_const| {
                var entry = entry_const;
                defer entry.deinit(gpa);
                if (parts_mod.credentialMatch(how.drop, &entry, how.match_password)) continue;
            }
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
    try lock.commit(io);
}

/// git's `strbuf_addstr_urlencode`: every byte but RFC 3986's unreserved
/// ones -- and, for a path, its reserved ones -- as `%xx`.
fn encode(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8, reserved_too: bool) Allocator.Error!void {
    for (text) |c| {
        const plain = std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "-._~", c) != null or
            (reserved_too and std.mem.findScalar(u8, "!*'();:@&=+$,/?#[]", c) != null);
        // In lower case, as git's `strbuf_addf("%%%02x")`.
        if (plain) try out.append(gpa, c) else try out.print(gpa, "%{x:0>2}", .{c});
    }
}
