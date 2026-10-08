//! The per-ref log git writes beside every ref it moves, as the files
//! backend keeps it: `logs/<ref>` under the ref's directory.
//!
//! A commit that writes no reflog leaves a repository whose users will find
//! `git reflog` empty and whose `git gc` cannot see the objects a reset left
//! behind. The line is
//! `old SP new SP Name <email> SP secs SP ±hhmm [TAB msg] LF`.
//!
//! Private to `refs`: everything else reads and writes a log through
//! `refs.Store`, which knows whether the refs are files or a reftable stack,
//! so no caller can read the files of a repository whose logs are in its
//! tables.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");

const Oid = hash.Oid;

/// Errors from appending to a log.
pub const AppendError = errors: {
    break :errors Io.File.OpenError || Io.Writer.Error ||
        Io.File.WritePositionalError || Io.File.StatError ||
        Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Allocator.Error ||
        error{InvalidSignature};
};

/// Errors from reading a log.
pub const ReadError = error{
    /// A line that is not `old new ident` with the right shapes.
    MalformedReflogEntry,
} || Allocator.Error || Io.Dir.ReadFileAllocError || object.Signature.ParseError;

/// One line of a log.
pub const Entry = struct {
    old: Oid,
    new: Oid,
    who: object.Signature,
    /// Everything after the tab, without the newline. Empty when there was
    /// no tab. Borrowed from the log's bytes.
    message: []const u8,
};

/// When a ref update writes a log entry.
///
/// `core.logAllRefUpdates` decides, and the three values mean different
/// things: `false` appends only where a log file already exists, `true`
/// creates one under `refs/heads`, `refs/remotes`, `refs/notes` and for
/// `HEAD`, and `always` creates one for anything under `refs/`.
pub const Policy = enum {
    never,
    existing_only,
    standard,
    always,

    /// The policy a `core.logAllRefUpdates` value names. A missing setting is
    /// `standard` in a repository with a working tree and `existing_only` in
    /// a bare one, which the caller decides.
    pub fn parse(text: []const u8) Policy {
        if (std.ascii.eqlIgnoreCase(text, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes") or
            std.ascii.eqlIgnoreCase(text, "on") or std.mem.eql(u8, text, "1")) return .standard;
        return .existing_only;
    }
};

/// Whether a log should be written for `ref` under `policy`, given whether a
/// log file is already there.
pub fn shouldLog(policy: Policy, ref: []const u8, log_exists: bool) bool {
    return switch (policy) {
        .never => false,
        .existing_only => log_exists,
        .always => log_exists or std.mem.startsWith(u8, ref, "refs/") or std.mem.eql(u8, ref, "HEAD"),
        .standard => log_exists or
            std.mem.eql(u8, ref, "HEAD") or
            std.mem.startsWith(u8, ref, "refs/heads/") or
            std.mem.startsWith(u8, ref, "refs/remotes/") or
            std.mem.startsWith(u8, ref, "refs/notes/"),
    };
}

/// A log message as git writes one: every run of whitespace, newlines
/// included, becomes one space, and none is left at either end. The result
/// is the caller's.
pub fn normalizeMessage(gpa: Allocator, message: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var was_space = true;
    for (message) |c| {
        // C's `isspace`, which is what git asks.
        const space = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
        if (was_space and space) continue;
        was_space = space;
        try out.append(gpa, if (space) ' ' else c);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

/// The path of a ref's log under the git directory: `logs/<ref>`.
/// The result is the caller's.
pub fn pathFor(gpa: Allocator, ref: []const u8) Allocator.Error![]u8 {
    return gpa.print("logs/{s}", .{ref});
}

/// Whether a log already exists for `ref`.
pub fn exists(gpa: Allocator, io: Io, git_dir: Io.Dir, ref: []const u8) Allocator.Error!bool {
    const path = try pathFor(gpa, ref);
    defer gpa.free(path);
    git_dir.access(io, path, .{}) catch return false;
    return true;
}

/// Append one line to `logs/<ref>`, making the directories it needs, which
/// with a log it starts are given the permissions `core.sharedRepository`
/// asks for, as git gives them.
///
/// The log is opened for appending rather than replaced: several processes
/// appending a line each interleave lines, never halves of one, because a
/// line is written in a single call.
pub const AppendOptions = struct { ref: []const u8, old: Oid, new: Oid, who: object.Signature, message: []const u8 = "", shared: fs.Shared = .umask };
pub fn append(gpa: Allocator, io: Io, git_dir: Io.Dir, options: AppendOptions) AppendError!void {
    const ref = options.ref;
    const old = options.old;
    const new = options.new;
    const who = options.who;
    const message = options.message;
    const shared = options.shared;
    const path = try pathFor(gpa, ref);
    defer gpa.free(path);
    if (std.Io.Dir.path.dirnamePosix(path)) |parent| {
        fs.makeDirs(io, git_dir, parent, shared) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }

    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    const w = &line.writer;
    var hex: [hash.max_hex_len]u8 = undefined;
    w.writeAll(old.hex(&hex)) catch return error.OutOfMemory;
    w.writeByte(' ') catch return error.OutOfMemory;
    w.writeAll(new.hex(&hex)) catch return error.OutOfMemory;
    w.writeByte(' ') catch return error.OutOfMemory;
    try who.write(w);
    if (message.len != 0) {
        w.writeByte('\t') catch return error.OutOfMemory;
        // A message is one line: a newline inside it would make one entry
        // read as two.
        for (message) |c| {
            if (c == '\n' or c == '\r') {
                w.writeByte(' ') catch return error.OutOfMemory;
            } else {
                w.writeByte(c) catch return error.OutOfMemory;
            }
        }
    }
    w.writeByte('\n') catch return error.OutOfMemory;

    // Hold the file's exclusive advisory lock across the length query and
    // the single positional write. Every relic appender therefore observes
    // the prior line before choosing its offset instead of overwriting it.
    // Opened for reading too because Windows does not let a write-only handle
    // query the length.
    const file = git_dir.openFile(io, path, .{ .mode = .read_write, .lock = .exclusive }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const created = try git_dir.createFile(io, path, .{ .truncate = false, .read = true, .lock = .exclusive });
            fs.adjustShared(io, git_dir, path, shared);
            break :blk created;
        },
        else => |e| return e,
    };
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, line.written(), end);
}

/// Every entry in `logs/<ref>`, oldest first.
///
/// The returned entries borrow `bytes`, which is the caller's and must
/// outlive them.
pub const Log = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    bytes: []u8,
    entries: []Entry,

    /// Release the log.
    pub fn deinit(log: *Log) void {
        log.gpa.free(log.entries);
        log.gpa.free(log.bytes);
        log.* = undefined;
    }

    /// The entry `HEAD@{n}` names: `n` steps back from the tip, so `0` is
    /// the newest entry's *new* value and `n` is the *old* value of the
    /// entry `n - 1` steps back.
    ///
    /// Returns `null` when the log does not go back that far, which is what
    /// git reports rather than guessing.
    pub fn at(log: *const Log, n: usize) ?Oid {
        if (log.entries.len == 0) return null;
        if (n == 0) return log.entries[log.entries.len - 1].new;
        if (n > log.entries.len) return null;
        return log.entries[log.entries.len - n].old;
    }
};

/// Read `logs/<ref>`. An absent log is an empty one. A line that is not an
/// entry is left out, as git's `show_one_reflog_ent` leaves it out, so one
/// damaged line does not take the rest of the log with it.
pub fn read(gpa: Allocator, io: Io, git_dir: Io.Dir, ref: []const u8, kind: hash.Kind) Self.ReadError!Log {
    const path = try pathFor(gpa, ref);
    defer gpa.free(path);
    const bytes = (try fs.readFileAlloc(gpa, io, git_dir, path, 1 << 28)) orelse
        return .{ .gpa = gpa, .bytes = try gpa.alloc(u8, 0), .entries = try gpa.alloc(Entry, 0) };
    errdefer gpa.free(bytes);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // ziglint-ignore: Z026 a line git cannot parse is one it skips, and the log's other entries stand
        const entry = parseLine(line, kind) catch continue;
        try entries.append(gpa, entry);
    }
    return .{ .gpa = gpa, .bytes = bytes, .entries = try entries.toOwnedSlice(gpa) };
}

/// Errors from expiring a log.
pub const ExpireError = errors: {
    break :errors ReadError || fs.LockError || fs.CommitError;
};

/// git's `files_reflog_expire` over `logs/<ref>`: keep the entries
/// `keeper.keep(entry, nth)` says to, through `logs/<ref>.lock`, `nth`
/// being how far back the entry is, `0` the newest, which is what
/// `<ref>@{n}` counts.
/// With `rewrite` each kept entry's old value becomes the new value of the
/// one kept before it, the null name for the first, so the log still reads
/// as a chain. A line that is not an entry goes, as git's rewrite drops it,
/// and a log every entry of which goes is left empty, as git leaves it.
///
/// Returns the newest kept entry's new value, or `null` when none was kept
/// or there is no log, which is left as it is. The caller holds the ref's
/// own lock, as git holds it, so the log and the ref move together.
pub fn expire(
    gpa: Allocator,
    io: Io,
    git_dir: Io.Dir,
    ref: []const u8,
    kind: hash.Kind,
    shared: fs.Shared,
    rewrite: bool,
    keeper: anytype,
) ExpireError!?Oid {
    const path = try pathFor(gpa, ref);
    defer gpa.free(path);
    if (!try exists(gpa, io, git_dir, ref)) return null;
    var buffer: [4096]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, git_dir, .{ .sub_path = path, .buffer = &buffer }, .{ .shared = shared });
    defer lock.deinit(io);
    // Read under the lock: an append that took it first is in the file.
    const bytes = (try fs.readFileAlloc(gpa, io, git_dir, path, 1 << 28)) orelse try gpa.alloc(u8, 0);
    defer gpa.free(bytes);

    var count: usize = 0;
    var counting = std.mem.splitScalar(u8, bytes, '\n');
    while (counting.next()) |line| {
        if (line.len == 0) continue;
        // ziglint-ignore: Z026 a line git cannot parse is no entry and is not counted
        _ = parseLine(line, kind) catch continue;
        count += 1;
    }

    const hex_len = kind.hexLen();
    var hex: [hash.max_hex_len]u8 = undefined;
    var last_kept: ?Oid = null;
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // ziglint-ignore: Z026 a line git cannot parse is one its rewrite drops
        const entry = parseLine(line, kind) catch continue;
        seen += 1;
        if (!keeper.keep(entry, count - seen)) continue;
        const w = lock.writer();
        if (rewrite) {
            const old = last_kept orelse Oid.zero(kind);
            w.writeAll(old.hex(&hex)) catch return error.WriteFailed;
            w.writeAll(line[hex_len..]) catch return error.WriteFailed;
        } else {
            w.writeAll(line) catch return error.WriteFailed;
        }
        w.writeByte('\n') catch return error.WriteFailed;
        last_kept = entry.new;
    }
    try lock.commit(io);
    return last_kept;
}

/// Errors from `create`.
pub const CreateError = Allocator.Error || Io.File.OpenError || Io.Dir.CreateDirError || Io.Dir.CreateDirPathError;

/// Make an empty `logs/<ref>` where there is none, as git's
/// `files_create_reflog` does: the directories it needs, and the file,
/// given the permissions `core.sharedRepository` asks for.
pub fn create(gpa: Allocator, io: Io, git_dir: Io.Dir, ref: []const u8, shared: fs.Shared) CreateError!void {
    const path = try pathFor(gpa, ref);
    defer gpa.free(path);
    if (std.Io.Dir.path.dirnamePosix(path)) |parent| {
        fs.makeDirs(io, git_dir, parent, shared) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    const file = git_dir.createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => |e| return e,
    };
    file.close(io);
    fs.adjustShared(io, git_dir, path, shared);
}

/// Errors from `delete`.
pub const DeleteError = Allocator.Error || Io.Dir.DeleteFileError;

/// Remove `logs/<ref>`, as git's `files_delete_reflog` does. A log that is
/// not there is no error.
pub fn delete(gpa: Allocator, io: Io, git_dir: Io.Dir, ref: []const u8) DeleteError!void {
    const path = try pathFor(gpa, ref);
    defer gpa.free(path);
    git_dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |e| return e,
    };
}

fn parseLine(line: []const u8, kind: hash.Kind) ReadError!Entry {
    const hex_len = kind.hexLen();
    if (line.len < hex_len * 2 + 2) return error.MalformedReflogEntry;
    const old = Oid.parse(kind, line[0..hex_len]) catch return error.MalformedReflogEntry;
    if (line[hex_len] != ' ') return error.MalformedReflogEntry;
    const new = Oid.parse(kind, line[hex_len + 1 ..][0..hex_len]) catch return error.MalformedReflogEntry;
    if (line[hex_len * 2 + 1] != ' ') return error.MalformedReflogEntry;
    const rest = line[hex_len * 2 + 2 ..];
    const tab = std.mem.findScalar(u8, rest, '\t');
    const ident = if (tab) |at| rest[0..at] else rest;
    const message = if (tab) |at| rest[at + 1 ..] else "";
    return .{
        .old = old,
        .new = new,
        .who = try object.Signature.parse(ident),
        .message = message,
    };
}

test "an appended entry reads back" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const zero: Oid = .zero(.sha1);
    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const two = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));
    const who: object.Signature = .{
        .name = "Ada",
        .email = "ada@example.com",
        .when_secs = 1_700_000_000,
        .offset_minutes = 0,
    };
    try append(gpa, io, tmp.dir, .{ .ref = "refs/heads/main", .old = zero, .new = one, .who = who, .message = "commit (initial): first", .shared = .umask });
    try append(gpa, io, tmp.dir, .{ .ref = "refs/heads/main", .old = one, .new = two, .who = who, .message = "commit: second", .shared = .umask });

    var raw: [512]u8 = undefined;
    const text = try tmp.dir.readFile(io, "logs/refs/heads/main", &raw);
    try std.testing.expect(std.mem.startsWith(u8, text, "0000000000000000000000000000000000000000 1111"));
    try std.testing.expect(std.mem.find(u8, text, "Ada <ada@example.com> 1700000000 +0000\tcommit (initial): first\n") != null);

    var log = try read(gpa, io, tmp.dir, "refs/heads/main", .sha1);
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 2), log.entries.len);
    try std.testing.expect(log.entries[1].new.eql(two));
    try std.testing.expectEqualStrings("commit: second", log.entries[1].message);

    // HEAD@{0} is the tip; HEAD@{1} is where it was before the last move.
    try std.testing.expect(log.at(0).?.eql(two));
    try std.testing.expect(log.at(1).?.eql(one));
    try std.testing.expect(log.at(2).?.eql(zero));
    try std.testing.expect(log.at(3) == null);
}

test "a malformed line leaves the other entries readable, as git skips it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "logs/refs/heads");
    const zero = &@as([40]u8, @splat('0'));
    const one = &@as([40]u8, @splat('1'));
    const two = &@as([40]u8, @splat('2'));
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/refs/heads/main", .data = zero ++ " " ++ one ++ " A <a@b> 1 +0000\tfirst\n" ++
        "not an entry\n" ++
        one ++ " " ++ two ++ " A <a@b> 2 +0000\tsecond\n" });
    var log = try read(gpa, io, tmp.dir, "refs/heads/main", .sha1);
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 2), log.entries.len);
    try std.testing.expectEqualStrings("second", log.entries[1].message);
}

test "the policy decides which refs get a log" {
    try std.testing.expect(shouldLog(.standard, "refs/heads/main", false));
    try std.testing.expect(!shouldLog(.standard, "refs/tags/v1", false));
    try std.testing.expect(shouldLog(.standard, "refs/tags/v1", true));
    try std.testing.expect(shouldLog(.always, "refs/tags/v1", false));
    try std.testing.expect(!shouldLog(.existing_only, "refs/heads/main", false));
    try std.testing.expect(shouldLog(.existing_only, "refs/heads/main", true));
    try std.testing.expect(!shouldLog(.never, "HEAD", true));
}

test "fuzz: any bytes are entries or a named error" {
    try std.testing.fuzz({}, fuzzLog, .{});
}

fn fuzzLog(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [1024]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = parseLine(line, .sha1) catch continue;
    }
    _ = gpa;
}

test "a log message is collapsed the way git collapses it" {
    const gpa = std.testing.allocator;
    const out = try normalizeMessage(gpa, "  commit:  first\tline\n\nmore  \n");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("commit: first line more", out);
}

/// All errors reported by this namespace.
pub const Error = AppendError || ReadError || ExpireError || CreateError || DeleteError || Allocator.Error || Self.ReadError;
