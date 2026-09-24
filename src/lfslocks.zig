//! Locks on paths, held on a remote's LFS server: git-lfs's locking API, the
//! read-only working files it keeps for paths marked `lockable`, and the check
//! a push makes against other people's locks.
//!
//! A lock is the server's: `POST <endpoint>/locks` takes one, `GET /locks`
//! lists them, `POST /locks/verify` lists them split into the person's own and
//! everyone else's — which is how the server says who the person is — and
//! `POST /locks/<id>/unlock` gives one back, or breaks someone else's when
//! forced. Each request names the ref the lock is for, as git-lfs names it:
//! the branch the current one pushes to.
//!
//! What the server last said is kept where git-lfs keeps it, so either can
//! show it offline: the listing at `<lfs>/cache/locks/<ref>/remote` and the
//! split at `<lfs>/cache/locks/<ref>/verifiable`, under the repository's LFS
//! directory, in git-lfs's own JSON. A lock taken or given back here updates
//! both. `Table` is the view a program shows a person: a path, who holds it,
//! since when, and whether it is the person themselves.
//!
//! A path with the `lockable` attribute is kept read-only in the working tree
//! unless the person holds its lock, which is how git-lfs reminds someone to
//! take a lock before editing a file nobody can merge. `fixWriteFlags` sets
//! the bits as git-lfs's post-checkout hook sets them, from the cached split,
//! and `lock` and `unlock` set them for the path they touch.
//! `lfs.setlockablereadonly` false turns all of it off, as in git-lfs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const repo_mod = @import("repo.zig");
const attributes = @import("attributes.zig");
const fs = @import("fs.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("lfsapi.zig");

const Repository = repo_mod.Repository;

/// Errors from the locking API and the files it keeps.
pub const Error = error{
    /// The server has no locking API: it answered 404 or 501.
    LockingUnsupported,
    /// No lock is held on that path, or none has that id.
    LockNotFound,
    /// More than one lock matched the path, which a server should never
    /// allow.
    LockAmbiguous,
    /// The lock is someone else's, and the unlock was not forced.
    LockOwnedByOther,
    /// The server would not take or give back a lock, for a reason of its
    /// own: `Server.client.message` holds it.
    LockRefused,
    /// A path that is not inside the working tree, or is a directory.
    InvalidLockPath,
} || attributes.Error || lfsapi.Error || fs.AtomicWriteError || Io.Dir.CreateDirPathError || Io.Dir.StatFileError ||
    Io.Dir.SetFilePermissionsError || repo_mod.Error || @import("index.zig").ReadError ||
    lfsapi.Settings.LoadError || lfs.Lfs.LoadError;

/// A lock, as the server reports it. Every slice is owned by whatever
/// returned it.
pub const Lock = struct {
    id: []const u8,
    /// `/`-separated, from the top of the working tree.
    path: []const u8,
    /// Who holds it, as the server names them.
    owner: ?[]const u8 = null,
    /// When it was taken, as the server wrote the time.
    locked_at: ?[]const u8 = null,
};

//=====================================================================
// The API's JSON
//=====================================================================

const LockJson = struct {
    id: []const u8 = "",
    path: []const u8 = "",
    owner: ?struct { name: []const u8 = "" } = null,
    locked_at: ?[]const u8 = null,

    fn toLock(j: LockJson) Lock {
        return .{ .id = j.id, .path = j.path, .owner = if (j.owner) |o| o.name else null, .locked_at = j.locked_at };
    }
};

/// An answer to taking or giving back a lock.
pub const LockAnswer = struct {
    lock: ?Lock = null,
    message: ?[]const u8 = null,
};

/// One page of a listing.
pub const ListPage = struct {
    locks: []const Lock = &.{},
    next_cursor: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// One page of a verify answer.
pub const VerifyPage = struct {
    ours: []const Lock = &.{},
    theirs: []const Lock = &.{},
    next_cursor: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

fn parseJson(comptime T: type, arena: Allocator, bytes: []const u8) (Allocator.Error || error{MalformedResponse})!T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedResponse,
    };
}

fn toLocks(arena: Allocator, raw: []const LockJson) (Allocator.Error || error{MalformedResponse})![]const Lock {
    const out = try arena.alloc(Lock, raw.len);
    for (raw, out) |j, *l| {
        if (j.id.len == 0) return error.MalformedResponse;
        l.* = j.toLock();
    }
    return out;
}

/// Read an answer to `POST /locks` or `POST /locks/<id>/unlock`.
pub fn parseLockAnswer(arena: Allocator, bytes: []const u8) (Allocator.Error || error{MalformedResponse})!LockAnswer {
    const Raw = struct { lock: ?LockJson = null, message: ?[]const u8 = null };
    const raw = try parseJson(Raw, arena, bytes);
    if (raw.lock) |l| {
        if (l.id.len == 0) return error.MalformedResponse;
        return .{ .lock = l.toLock(), .message = raw.message };
    }
    return .{ .message = raw.message };
}

/// Read a page of `GET /locks`, or the `remote` cache git-lfs writes, which
/// is a bare array of locks.
pub fn parseListPage(arena: Allocator, bytes: []const u8) (Allocator.Error || error{MalformedResponse})!ListPage {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len != 0 and trimmed[0] == '[') {
        return .{ .locks = try toLocks(arena, try parseJson([]const LockJson, arena, trimmed)) };
    }
    const Raw = struct { locks: ?[]const LockJson = null, next_cursor: ?[]const u8 = null, message: ?[]const u8 = null };
    const raw = try parseJson(Raw, arena, bytes);
    return .{ .locks = try toLocks(arena, raw.locks orelse &.{}), .next_cursor = raw.next_cursor, .message = raw.message };
}

/// Read a page of `POST /locks/verify`, or the `verifiable` cache.
pub fn parseVerifyPage(arena: Allocator, bytes: []const u8) (Allocator.Error || error{MalformedResponse})!VerifyPage {
    const Raw = struct { ours: ?[]const LockJson = null, theirs: ?[]const LockJson = null, next_cursor: ?[]const u8 = null, message: ?[]const u8 = null };
    const raw = try parseJson(Raw, arena, bytes);
    return .{
        .ours = try toLocks(arena, raw.ours orelse &.{}),
        .theirs = try toLocks(arena, raw.theirs orelse &.{}),
        .next_cursor = raw.next_cursor,
        .message = raw.message,
    };
}

fn writeLock(s: *std.json.Stringify, l: Lock) Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(l.id);
    try s.objectField("path");
    try s.write(l.path);
    if (l.owner) |o| {
        try s.objectField("owner");
        try s.beginObject();
        try s.objectField("name");
        try s.write(o);
        try s.endObject();
    }
    try s.objectField("locked_at");
    try s.write(l.locked_at orelse "0001-01-01T00:00:00Z");
    try s.endObject();
}

fn writeLockArray(s: *std.json.Stringify, locks: []const Lock) Io.Writer.Error!void {
    try s.beginArray();
    for (locks) |l| try writeLock(s, l);
    try s.endArray();
}

//=====================================================================
// Operations
//=====================================================================

/// How a lock operation runs.
pub const Options = struct {
    /// The ref the lock is for, as git-lfs names it: `refs/heads/main`.
    /// `null` takes the branch `HEAD` is on, or none when it is on none.
    ref: ?[]const u8 = null,
};

/// What taking a lock came to.
pub const Acquired = union(enum) {
    /// The lock is the person's now.
    locked: Lock,
    /// Someone holds it already: the server's answer says who.
    held: Lock,
};

/// The locks, split by the server into the person's and everyone else's.
pub const Verified = struct {
    arena: std.heap.ArenaAllocator,
    ours: []const Lock,
    theirs: []const Lock,

    /// Release everything.
    pub fn deinit(v: *Verified) void {
        v.arena.deinit();
        v.* = undefined;
    }
};

/// A listing of locks.
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    locks: []const Lock,

    /// Release everything.
    pub fn deinit(l: *Listing) void {
        l.arena.deinit();
        l.* = undefined;
    }
};

/// The ref a lock request names: the caller's, else the branch `HEAD` is
/// on, which is where git-lfs's `git lfs lock` takes it from when the
/// branch pushes to a branch of its own name.
fn refFor(arena: Allocator, io: Io, repo: *Repository, options: Options) Error!?[]const u8 {
    if (options.ref) |r| return r;
    const branch = (try repo.refs.currentBranch(arena, io)) orelse return null;
    return try std.fmt.allocPrint(arena, "refs/heads/{s}", .{branch});
}

fn writeRef(s: *std.json.Stringify, ref: ?[]const u8) Io.Writer.Error!void {
    const name = ref orelse return;
    try s.objectField("ref");
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.endObject();
}

/// Take the lock on `path`, as `git lfs lock <path>` takes it. On success the
/// file, when it is there, is made writable, and the caches say the lock is
/// the person's.
pub fn lock(server: *lfsapi.Server, repo: *Repository, path: []const u8, arena: Allocator, options: Options) Error!Acquired {
    try checkPath(path);
    const ref = try refFor(arena, server.io, repo, options);
    var body: Io.Writer.Allocating = .init(arena);
    {
        var s: std.json.Stringify = .{ .writer = &body.writer };
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("path") catch return error.OutOfMemory;
        s.write(path) catch return error.OutOfMemory;
        writeRef(&s, ref) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
    }
    const ex = try server.client.api(.upload, .POST, "locks", body.written(), 0);
    defer ex.close();
    const status = ex.status();
    if (status == .not_found or status == .not_implemented) {
        server.client.noteStatus(ex, "lock");
        return error.LockingUnsupported;
    }
    if (status == .unauthorized or status == .forbidden) return server.client.failStatus(ex, "lock");
    const answer = try parseLockAnswer(arena, try ex.readAll(1 << 20));
    if (status == .conflict) {
        if (answer.lock) |held| return .{ .held = held };
        return error.LockRefused;
    }
    const taken = answer.lock orelse {
        server.client.noteStatus(ex, answer.message orelse "lock");
        return error.LockRefused;
    };
    if (status.class() != .success) return error.LockRefused;
    var cache = try Cache.load(arena, server, ref);
    cache.addOurs(arena, taken) catch return error.OutOfMemory;
    try cache.save(arena, server, ref);
    if (repo.work_dir) |wt| _ = try setWritable(server.io, wt, taken.path, true);
    return .{ .locked = taken };
}

/// Give back the lock with `id`, or break someone else's with `force`, as
/// `git lfs unlock --id` does. The file is made read-only again when it is
/// lockable, and the caches forget the lock.
pub fn unlock(server: *lfsapi.Server, repo: *Repository, id: []const u8, force: bool, arena: Allocator, options: Options) Error!Lock {
    const ref = try refFor(arena, server.io, repo, options);
    var body: Io.Writer.Allocating = .init(arena);
    {
        var s: std.json.Stringify = .{ .writer = &body.writer };
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("force") catch return error.OutOfMemory;
        s.write(force) catch return error.OutOfMemory;
        writeRef(&s, ref) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
    }
    const suffix = try std.fmt.allocPrint(arena, "locks/{s}/unlock", .{id});
    const ex = try server.client.api(.upload, .POST, suffix, body.written(), 0);
    defer ex.close();
    const status = ex.status();
    switch (status) {
        .not_implemented => {
            server.client.noteStatus(ex, "unlock");
            return error.LockingUnsupported;
        },
        .not_found => {
            server.client.noteStatus(ex, "unlock");
            return error.LockNotFound;
        },
        .forbidden => {
            server.client.noteStatus(ex, "unlock");
            return error.LockOwnedByOther;
        },
        .unauthorized => return server.client.failStatus(ex, "unlock"),
        else => {},
    }
    const answer = try parseLockAnswer(arena, try ex.readAll(1 << 20));
    if (answer.message) |m| {
        if (answer.lock == null or status.class() != .success) {
            server.client.noteStatus(ex, m);
            return error.LockRefused;
        }
    }
    const released = answer.lock orelse return error.LockRefused;
    var cache = try Cache.load(arena, server, ref);
    try cache.remove(arena, id);
    try cache.save(arena, server, ref);
    if (repo.work_dir) |wt| {
        if (readOnlyWanted(&server.settings)) {
            var lockables = try Lockables.load(server.io, repo);
            defer lockables.deinit();
            if (try lockables.isLockable(arena, released.path)) _ = try setWritable(server.io, wt, released.path, false);
        }
    }
    return released;
}

/// Give back the lock on `path`: its id is asked for first, as `git lfs
/// unlock <path>` asks.
pub fn unlockPath(server: *lfsapi.Server, repo: *Repository, path: []const u8, force: bool, arena: Allocator, options: Options) Error!Lock {
    try checkPath(path);
    var found = try list(server, repo, .{ .path = path }, options);
    defer found.deinit();
    switch (found.locks.len) {
        0 => return error.LockNotFound,
        1 => {},
        else => return error.LockAmbiguous,
    }
    const id = try arena.dupe(u8, found.locks[0].id);
    return unlock(server, repo, id, force, arena, options);
}

/// What a listing asks for.
pub const Filter = struct {
    path: ?[]const u8 = null,
    id: ?[]const u8 = null,
    /// The most locks returned; zero for all.
    limit: usize = 0,
};

/// List the locks on the server, following its pages, as `git lfs locks`
/// does. A full listing — no filter, no limit — is kept as the `remote`
/// cache.
pub fn list(server: *lfsapi.Server, repo: *Repository, filter: Filter, options: Options) Error!Listing {
    var out: Listing = .{ .arena = .init(server.gpa), .locks = &.{} };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();
    const ref = try refFor(arena, server.io, repo, options);
    var locks: std.ArrayList(Lock) = .empty;
    var cursor: ?[]const u8 = null;
    while (true) {
        var query: std.ArrayList(u8) = .empty;
        try query.appendSlice(arena, "locks");
        var sep: u8 = '?';
        const params = [_]struct { []const u8, ?[]const u8 }{
            .{ "path", filter.path },
            .{ "id", filter.id },
            .{ "cursor", cursor },
            .{ "limit", if (filter.limit != 0) try std.fmt.allocPrint(arena, "{d}", .{filter.limit}) else null },
            .{ "refspec", ref },
        };
        for (params) |p| {
            const value = p[1] orelse continue;
            try query.print(arena, "{c}{s}=", .{ sep, p[0] });
            try percentEncode(arena, &query, value);
            sep = '&';
        }
        const ex = try server.client.api(.download, .GET, query.items, null, 0);
        defer ex.close();
        const status = ex.status();
        if (status == .not_found or status == .not_implemented) {
            server.client.noteStatus(ex, "locks");
            return error.LockingUnsupported;
        }
        if (status != .ok) return server.client.failStatus(ex, "locks");
        const page = try parseListPage(arena, try ex.readAll(64 << 20));
        if (page.message) |m| {
            server.client.noteStatus(ex, m);
            return error.LockRefused;
        }
        for (page.locks) |l| {
            try locks.append(arena, l);
            if (filter.limit != 0 and locks.items.len >= filter.limit) break;
        }
        if (filter.limit != 0 and locks.items.len >= filter.limit) break;
        cursor = page.next_cursor orelse break;
    }
    out.locks = locks.items;
    if (filter.path == null and filter.id == null and filter.limit == 0) {
        var cache = try Cache.load(arena, server, ref);
        cache.remote = out.locks;
        cache.have_remote = true;
        try cache.save(arena, server, ref);
    }
    return out;
}

/// Ask the server which locks are the person's and which are not, following
/// its pages, as `git lfs locks --verify` and the pre-push check ask. The
/// answer is kept as the `verifiable` cache.
pub fn verify(server: *lfsapi.Server, repo: *Repository, options: Options) Error!Verified {
    var out: Verified = .{ .arena = .init(server.gpa), .ours = &.{}, .theirs = &.{} };
    errdefer out.arena.deinit();
    const arena = out.arena.allocator();
    const ref = try refFor(arena, server.io, repo, options);
    var ours: std.ArrayList(Lock) = .empty;
    var theirs: std.ArrayList(Lock) = .empty;
    var cursor: ?[]const u8 = null;
    while (true) {
        var body: Io.Writer.Allocating = .init(arena);
        {
            var s: std.json.Stringify = .{ .writer = &body.writer };
            s.beginObject() catch return error.OutOfMemory;
            writeRef(&s, ref) catch return error.OutOfMemory;
            if (cursor) |c| {
                s.objectField("cursor") catch return error.OutOfMemory;
                s.write(c) catch return error.OutOfMemory;
            }
            s.endObject() catch return error.OutOfMemory;
        }
        const ex = try server.client.api(.upload, .POST, "locks/verify", body.written(), 0);
        defer ex.close();
        const status = ex.status();
        if (status == .not_found or status == .not_implemented) {
            server.client.noteStatus(ex, "locks/verify");
            return error.LockingUnsupported;
        }
        if (status != .ok) return server.client.failStatus(ex, "locks/verify");
        const page = try parseVerifyPage(arena, try ex.readAll(64 << 20));
        if (page.message) |m| {
            server.client.noteStatus(ex, m);
            return error.LockRefused;
        }
        try ours.appendSlice(arena, page.ours);
        try theirs.appendSlice(arena, page.theirs);
        cursor = page.next_cursor orelse break;
    }
    out.ours = ours.items;
    out.theirs = theirs.items;
    var cache = try Cache.load(arena, server, ref);
    cache.ours = out.ours;
    cache.theirs = out.theirs;
    cache.have_verifiable = true;
    try cache.save(arena, server, ref);
    return out;
}

fn percentEncode(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/') {
            try out.append(a, c);
        } else try out.print(a, "%{X:0>2}", .{c});
    }
}

/// A lock path must be a relative, `/`-separated path inside the tree.
fn checkPath(path: []const u8) Error!void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidLockPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidLockPath;
    }
}

//=====================================================================
// The cache git-lfs keeps
//=====================================================================

/// The last listing and the last split, as git-lfs keeps them.
pub const Cache = struct {
    remote: []const Lock = &.{},
    ours: []const Lock = &.{},
    theirs: []const Lock = &.{},
    have_remote: bool = false,
    have_verifiable: bool = false,

    /// Where the cache for `ref` lives, under the store's root:
    /// `<lfs>/cache/locks/<ref>`, or `<lfs>/cache/locks` with no ref.
    pub fn dirPath(a: Allocator, store: *const lfs.Store, ref: ?[]const u8) Allocator.Error![]const u8 {
        if (ref) |r| return std.fmt.allocPrint(a, "{s}/cache/locks/{s}", .{ store.root, r });
        return std.fmt.allocPrint(a, "{s}/cache/locks", .{store.root});
    }

    /// Read what is cached for `ref`, which is nothing when there is no
    /// cache or it does not parse.
    pub fn read(a: Allocator, io: Io, store: *const lfs.Store, ref: ?[]const u8) Error!Cache {
        var c: Cache = .{};
        const dir = try dirPath(a, store, ref);
        const remote_path = try std.fmt.allocPrint(a, "{s}/remote", .{dir});
        if (try fs.readFileAlloc(a, io, store.base, remote_path, 64 << 20)) |bytes| {
            if (parseListPage(a, bytes)) |page| {
                c.remote = page.locks;
                c.have_remote = true;
            } else |_| {}
        }
        const verifiable_path = try std.fmt.allocPrint(a, "{s}/verifiable", .{dir});
        if (try fs.readFileAlloc(a, io, store.base, verifiable_path, 64 << 20)) |bytes| {
            if (parseVerifyPage(a, bytes)) |page| {
                c.ours = page.ours;
                c.theirs = page.theirs;
                c.have_verifiable = true;
            } else |_| {}
        }
        return c;
    }

    fn load(a: Allocator, server: *lfsapi.Server, ref: ?[]const u8) Error!Cache {
        return read(a, server.io, server.store(), ref);
    }

    fn addOurs(c: *Cache, a: Allocator, l: Lock) Allocator.Error!void {
        try c.remove(a, l.id);
        c.ours = try std.mem.concat(a, Lock, &.{ c.ours, &.{l} });
        c.remote = try std.mem.concat(a, Lock, &.{ c.remote, &.{l} });
        c.have_verifiable = true;
        c.have_remote = true;
    }

    fn remove(c: *Cache, a: Allocator, id: []const u8) Allocator.Error!void {
        c.ours = try without(a, c.ours, id);
        c.theirs = try without(a, c.theirs, id);
        c.remote = try without(a, c.remote, id);
    }

    fn without(a: Allocator, locks: []const Lock, id: []const u8) Allocator.Error![]const Lock {
        var out: std.ArrayList(Lock) = .empty;
        for (locks) |l| {
            if (!std.mem.eql(u8, l.id, id)) try out.append(a, l);
        }
        return out.items;
    }

    fn save(c: *const Cache, a: Allocator, server: *lfsapi.Server, ref: ?[]const u8) Error!void {
        const store = server.store();
        const io = server.io;
        const dir_path = try dirPath(a, store, ref);
        try store.base.createDirPath(io, dir_path);
        var dir = try store.base.openDir(io, dir_path, .{});
        defer dir.close(io);
        if (c.have_remote) {
            var out: Io.Writer.Allocating = .init(a);
            var s: std.json.Stringify = .{ .writer = &out.writer };
            writeLockArray(&s, c.remote) catch return error.OutOfMemory;
            out.writer.writeByte('\n') catch return error.OutOfMemory;
            try fs.atomicWrite(io, dir, "remote", out.written(), ".relic-locks-", .none);
        }
        if (c.have_verifiable) {
            var out: Io.Writer.Allocating = .init(a);
            var s: std.json.Stringify = .{ .writer = &out.writer };
            s.beginObject() catch return error.OutOfMemory;
            s.objectField("ours") catch return error.OutOfMemory;
            writeLockArray(&s, c.ours) catch return error.OutOfMemory;
            s.objectField("theirs") catch return error.OutOfMemory;
            writeLockArray(&s, c.theirs) catch return error.OutOfMemory;
            s.endObject() catch return error.OutOfMemory;
            out.writer.writeByte('\n') catch return error.OutOfMemory;
            try fs.atomicWrite(io, dir, "verifiable", out.written(), ".relic-locks-", .none);
        }
    }
};

/// Who holds what, for a program to show: a path, who holds its lock and
/// since when, and whether that is the person.
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    /// One locked path.
    pub const Entry = struct {
        id: []const u8,
        owner: ?[]const u8,
        locked_at: ?[]const u8,
        /// Whether the server said the lock is the person's; `null` when
        /// the table came from a listing that does not say.
        ours: ?bool,
    };

    /// A table of `ours` and `theirs`, the server's split.
    pub fn fromVerified(gpa: Allocator, ours: []const Lock, theirs: []const Lock) Allocator.Error!Table {
        var t: Table = .{ .arena = .init(gpa) };
        errdefer t.arena.deinit();
        for (ours) |l| try t.put(l, true);
        for (theirs) |l| try t.put(l, false);
        return t;
    }

    /// A table of a listing, which does not say whose a lock is.
    pub fn fromListing(gpa: Allocator, locks: []const Lock) Allocator.Error!Table {
        var t: Table = .{ .arena = .init(gpa) };
        errdefer t.arena.deinit();
        for (locks) |l| try t.put(l, null);
        return t;
    }

    /// The table from what is cached for `ref`, with no network: the split
    /// when there is one, else the listing. What a program shows offline.
    pub fn cached(gpa: Allocator, io: Io, store: *const lfs.Store, ref: ?[]const u8) Error!Table {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const c = try Cache.read(scratch.allocator(), io, store, ref);
        if (c.have_verifiable) return try fromVerified(gpa, c.ours, c.theirs);
        return try fromListing(gpa, c.remote);
    }

    fn put(t: *Table, l: Lock, ours: ?bool) Allocator.Error!void {
        const a = t.arena.allocator();
        try t.entries.put(a, try a.dupe(u8, l.path), .{
            .id = try a.dupe(u8, l.id),
            .owner = if (l.owner) |o| try a.dupe(u8, o) else null,
            .locked_at = if (l.locked_at) |at| try a.dupe(u8, at) else null,
            .ours = ours,
        });
    }

    /// Who holds `path`, or `null` when nobody does.
    pub fn find(t: *const Table, path: []const u8) ?Entry {
        return t.entries.get(path);
    }

    /// Release everything.
    pub fn deinit(t: *Table) void {
        t.arena.deinit();
        t.* = undefined;
    }
};

//=====================================================================
// Lockable files
//=====================================================================

/// The attributes that say which paths are `lockable`: the repository's
/// own, and the `.gitattributes` of every directory down to a path, read as
/// the path is asked about.
pub const Lockables = struct {
    attrs: attributes.Attrs,
    io: Io,
    work_dir: ?Io.Dir,

    /// Load them for `repo`.
    pub fn load(io: Io, repo: *Repository) Error!Lockables {
        return .{ .attrs = try repo.loadAttrs(io), .io = io, .work_dir = repo.work_dir };
    }

    /// Whether `path` has the `lockable` attribute.
    pub fn isLockable(l: *Lockables, scratch: Allocator, path: []const u8) Error!bool {
        if (l.work_dir) |wt| try l.attrs.enter(l.io, wt, path);
        const found = try l.attrs.lookup(scratch, path, false);
        return found.isSet("lockable");
    }

    /// Release everything.
    pub fn deinit(l: *Lockables) void {
        l.attrs.leave();
        l.attrs.deinit();
        l.* = undefined;
    }
};

/// Whether lockable files are kept read-only: `lfs.setlockablereadonly`,
/// true unless set false.
fn readOnlyWanted(settings: *const lfsapi.Settings) bool {
    return settings.getBool("lfs.setlockablereadonly", true);
}

/// What `fixWriteFlags` did.
pub const Fixed = struct {
    /// Lockable files made read-only, or left so.
    read_only: u32 = 0,
    /// Lockable files the person holds the lock on, made writable.
    writable: u32 = 0,
};

/// Make every lockable file in the working tree — or only `paths` — read-only
/// unless the person holds its lock, and writable if they do, as git-lfs's
/// post-checkout hook does after a checkout. Whose a lock is comes from the
/// cached split for `options.ref`; nothing is sent. Nothing is done when
/// `lfs.setlockablereadonly` is false.
pub fn fixWriteFlags(gpa: Allocator, io: Io, repo: *Repository, paths: ?[]const []const u8, options: Options) Error!Fixed {
    var fixed: Fixed = .{};
    const wt = repo.work_dir orelse return fixed;
    var settings = try lfsapi.Settings.load(gpa, io, &repo.config, repo.work_dir);
    defer settings.deinit();
    if (!readOnlyWanted(&settings)) return fixed;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store_settings = try lfs.Lfs.load(gpa, io, &repo.config, repo.common_dir, repo.work_dir, .{});
    defer store_settings.deinit();
    const ref = try refFor(arena, io, repo, options);
    const cache = try Cache.read(arena, io, &store_settings.store, ref);
    var ours: std.StringHashMapUnmanaged(void) = .empty;
    for (cache.ours) |l| try ours.put(arena, l.path, {});

    var lockables = try Lockables.load(io, repo);
    defer lockables.deinit();
    var index = try repo.openIndex(io);
    defer index.deinit();
    const candidates: []const []const u8 = paths orelse blk: {
        const all = try arena.alloc([]const u8, index.entries.items.len);
        for (index.entries.items, all) |e, *p| p.* = try arena.dupe(u8, e.path);
        break :blk all;
    };
    for (candidates) |path| {
        if (!try lockables.isLockable(arena, path)) continue;
        const writable = ours.contains(path);
        if (try setWritable(io, wt, path, writable)) {
            if (writable) fixed.writable += 1 else fixed.read_only += 1;
        }
    }
    return fixed;
}

/// Give the file at `path` its owner's write bit, or take every write bit
/// away, as git-lfs does; a file that is not there is left alone. Returns
/// whether a file was there.
fn setWritable(io: Io, wt: Io.Dir, path: []const u8, writable: bool) Error!bool {
    const st = wt.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => |e| return e,
    };
    if (st.kind != .file) return false;
    const now = st.permissions;
    const wanted = fs.withReadOnly(now, !writable);
    if (wanted != now) try wt.setFilePermissions(io, path, wanted, .{});
    return true;
}

const testing = std.testing;

test "the locking API's answers and git-lfs's cache files are read" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const created = try parseLockAnswer(a, "{\"lock\":{\"id\":\"7\",\"path\":\"a.bin\",\"owner\":{\"name\":\"Ada\"},\"locked_at\":\"2016-05-17T15:49:06+00:00\"}}");
    try testing.expectEqualStrings("Ada", created.lock.?.owner.?);
    const refused = try parseLockAnswer(a, "{\"message\":\"no\"}");
    try testing.expect(refused.lock == null);
    const page = try parseListPage(a, "{\"locks\":[{\"id\":\"1\",\"path\":\"x\"}],\"next_cursor\":\"2\"}");
    try testing.expectEqualStrings("2", page.next_cursor.?);
    const cached = try parseListPage(a, "[{\"id\":\"1\",\"path\":\"x\",\"owner\":{\"name\":\"b\"},\"locked_at\":\"2026-09-24T10:01:00Z\"}]\n");
    try testing.expectEqualStrings("b", cached.locks[0].owner.?);
    const split = try parseVerifyPage(a, "{\"ours\":[{\"id\":\"1\",\"path\":\"x\"}],\"theirs\":[]}");
    try testing.expectEqual(@as(usize, 1), split.ours.len);
    try testing.expectError(error.MalformedResponse, parseListPage(a, "{\"locks\":[{\"path\":\"x\"}]}"));
    try testing.expectError(error.MalformedResponse, parseVerifyPage(a, "{"));
}

test "a lock is written to the cache as git-lfs writes it" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try writeLockArray(&s, &.{.{ .id = "1", .path = "x.bin", .owner = "ada", .locked_at = "2026-09-24T10:01:00Z" }});
    try testing.expectEqualStrings("[{\"id\":\"1\",\"path\":\"x.bin\",\"owner\":{\"name\":\"ada\"},\"locked_at\":\"2026-09-24T10:01:00Z\"}]", out.written());
}

test "a lock path is inside the tree" {
    try checkPath("a/b.bin");
    for ([_][]const u8{ "", "/abs", "a/../b", "./a", "a//b", "a\\b" }) |p| try testing.expectError(error.InvalidLockPath, checkPath(p));
}

test "fuzz: any locking answer is read or refused by name" {
    try testing.fuzz({}, fuzzLocks, .{});
}

fn fuzzLocks(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [768]u8 = undefined;
    const n = smith.slice(&scratch);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = scratch[0..n];
    if (parseLockAnswer(a, bytes)) |answer| {
        if (answer.lock) |l| try testing.expect(l.id.len != 0);
    } else |err| if (err != error.MalformedResponse) return err;
    if (parseListPage(a, bytes)) |page| {
        for (page.locks) |l| try testing.expect(l.id.len != 0);
        var t = try Table.fromListing(testing.allocator, page.locks);
        t.deinit();
    } else |err| if (err != error.MalformedResponse) return err;
    if (parseVerifyPage(a, bytes)) |page| {
        var t = try Table.fromVerified(testing.allocator, page.ours, page.theirs);
        t.deinit();
    } else |err| if (err != error.MalformedResponse) return err;
}
