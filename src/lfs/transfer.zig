//! Moving LFS objects between this repository's store and a remote's, as
//! git-lfs moves them: the batch API and the basic transfer adapter.
//!
//! A transfer asks the server first. One `POST <endpoint>/objects/batch`
//! names up to `lfs.transfer.batchSize` objects — their SHA-256 and size —
//! and the operation, and the server answers each with the actions that
//! move it: a URL to `GET` for a download, a URL to `PUT` and perhaps one to
//! verify for an upload, each with headers of its own, or an error of the
//! object's own. An upload the server answers with no actions is one it
//! already has. The transfers then run `lfs.concurrenttransfers` at a time
//! on the caller's `Io`; a download is streamed into the store under its
//! SHA-256 and kept only when the name comes out right, and an upload is
//! streamed out of the store.
//!
//! Failure is git-lfs's. A request that cannot be made at all, and a
//! transfer the server refuses — any status but a success, save 422 on an
//! upload — are tried again, up to `lfs.transfer.maxretries` times per
//! object, each time with a fresh batch, after a wait that starts at a
//! quarter of a second and doubles up to `lfs.transfer.maxretrydelay`
//! seconds; a `Retry-After` the server sends is waited instead, unless it is
//! longer than `lfs.transfer.maxRetryTime`. A batch the server answers with
//! 429 is waited on the same way; any other failed batch fails its objects,
//! as git-lfs fails them. What failed is in the outcome, object by object;
//! the operation itself fails only when it cannot go on at all.
//!
//! A custom transfer adapter (`custom.zig`) moves the objects when the
//! batch answer names one the configuration has, the adapters being
//! offered in the request, or with no batch at all when
//! `lfs.<url>.standalonetransferagent` names one: its processes are
//! started before the transfers and handed them one at a time.
//!
//! A remote whose server speaks git-lfs's pure-ssh protocol gets the same
//! batches and transfers over it instead, one connection per worker, as
//! git-lfs's `ssh` adapter moves them (`lfsssh.zig`).
//!
//! A remote on this machine has no API. Its store is found through its own
//! configuration and objects are copied between the two stores directly,
//! which is what git-lfs's `lfs-standalone-file` adapter does for one.
//!
//! Above the transfers: `Fetcher`, which is what checkout calls for the
//! objects it found missing; `fetch`, which brings the objects the trees at
//! some refs — or their whole history — point at, as `git lfs fetch` does;
//! `pull`, which fetches and then puts the content in place of the pointers
//! in the working tree, as `git lfs pull` does; and `pushObjects`, which
//! uploads the objects the commits a push sends point at, as git-lfs's
//! pre-push hook does.

const ErrorNamespace = @This();
const transfer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;
const http = std.http;

const hash = @import("../hash/hash.zig");
const object_mod = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const repo_mod = @import("../repo/repo.zig");
const fs = @import("../fs/fs.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("api.zig");
const objectwalk = @import("../walk/objectwalk.zig");
const progress_mod = @import("../report/progress.zig");
const timetext = @import("timetext.zig");
const lfsssh = @import("ssh.zig");
const custom = @import("custom.zig");
const remote_mod = @import("../wire/remote.zig");
const revwalk = @import("../walk/walk.zig");
const diff_mod = @import("../diff/diff.zig");
const config_mod = @import("../config/config.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a transfer that could not go on. A transfer that went on
/// and failed for some objects is not one of these; the outcome says which.
pub const Error = error{
    /// The server's answer to a batch did not parse, or named a hash other
    /// than SHA-256.
    MalformedResponse,
    /// A batch the server refused: `Server.client.message` holds its
    /// status and reason.
    LfsBatchFailed,
    /// A remote on this machine whose repository does not open.
    LfsLocalRemoteUnreadable,
    /// The server chose a transfer adapter relic does not have: `tus`, or a
    /// name the configuration does not define for the direction.
    LfsTransferUnsupported,
} || custom.Error || lfsapi.Error || lfs.Store.InstallError || lfs.Store.OpenError || Io.ConcurrentError ||
    Io.File.ReadPositionalError || Io.File.WritePositionalError || Io.File.SetLengthError;

/// An object to move.
pub const Object = struct {
    oid: [64]u8,
    size: u64,
    /// A path the object is at, for a message. Borrowed.
    name: []const u8 = "",

    /// The object a pointer names.
    pub fn of(p: lfs.Pointer, name: []const u8) Object {
        return .{ .oid = p.oid, .size = p.size, .name = name };
    }

    fn asPointer(o: Object) lfs.Pointer {
        return .{ .oid = o.oid, .size = o.size };
    }
};

/// What happened to one object.
pub const Result = struct {
    oid: [64]u8,
    size: u64,
    name: []const u8,
    status: Status,
    /// Why it failed: the server's words, or the transfer's.
    message: ?[]const u8 = null,

    /// The object's fate.
    pub const Status = enum {
        /// Moved.
        transferred,
        /// Already where it was going: in the store, or on the server.
        present,
        /// The server answered for the object with an error of its own —
        /// it does not have it, or will not take it.
        refused,
        /// Every attempt failed.
        failed,
        /// An upload of an object the store does not have and the server
        /// lacks, which git-lfs refuses unless `lfs.allowincompletepush`.
        missing,
    };

    /// Whether the object did not get where it was going.
    pub fn isFailure(r: Result) bool {
        return switch (r.status) {
            .transferred, .present => false,
            else => true,
        };
    }
};

/// What a transfer did, object by object.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    results: []Result,
    /// The name of the error the sweep of `lfs/tmp` ended in, when it
    /// failed; the transfer itself did not, as git-lfs's does not.
    sweep_failed: ?[]const u8 = null,

    /// Release everything.
    pub fn deinit(o: *Outcome) void {
        o.arena.deinit();
        o.* = undefined;
    }

    /// How many objects did not get where they were going.
    pub fn failures(o: *const Outcome) usize {
        var n: usize = 0;
        for (o.results) |r| {
            if (r.isFailure()) n += 1;
        }
        return n;
    }

    /// The result for `oid`, or `null`.
    pub fn find(o: *const Outcome, oid: []const u8) ?*const Result {
        for (o.results) |*r| {
            if (std.mem.eql(u8, &r.oid, oid)) return r;
        }
        return null;
    }
};

/// How a transfer runs.
pub const Options = struct {
    /// The ref the objects are for, sent in the batch as git-lfs sends it —
    /// `refs/heads/main` — so a server that scopes access by branch can.
    /// A download with none names `Server.download_ref`, as git-lfs's
    /// downloads all name the current branch's.
    ref: ?[]const u8 = null,
    /// Where `lfs_objects` and `lfs_bytes` events go. They are sent from
    /// the calling task.
    progress: ?progress_mod.Progress = null,
    /// How many transfers run at once. `lfs.concurrenttransfers` when
    /// `null`, which is eight unless set.
    concurrency: ?u32 = null,
};

/// The batch API's settings, read as git-lfs reads them.
const Limits = struct {
    batch_size: usize,
    max_retries: u32,
    max_retry_delay_s: u32,
    max_retry_time_s: u32,
    max_verifies: u32,
    concurrency: u32,
    allow_incomplete_push: bool,
    /// The adapters the batch request offers beside `basic`.
    transfers: []const []const u8 = &.{},

    fn read(settings: *const lfsapi.Settings, options: Options) Limits {
        const retries = settings.getInt("lfs.transfer.maxretries", 8);
        const delay = settings.getInt("lfs.transfer.maxretrydelay", 10);
        const retry_time = settings.getInt("lfs.transfer.maxretrytime", 300);
        const verifies = settings.getInt("lfs.transfer.maxverifies", 3);
        const batch = settings.getInt("lfs.transfer.batchsize", 100);
        const concurrent = settings.getInt("lfs.concurrenttransfers", 8);
        return .{
            .batch_size = if (batch > 0) @intCast(batch) else 100,
            .max_retries = if (retries >= 1) @intCast(@min(retries, 1000)) else 8,
            .max_retry_delay_s = if (delay >= 0) @intCast(@min(delay, 3600)) else 10,
            .max_retry_time_s = if (retry_time >= 1) @intCast(@min(retry_time, 86400)) else 300,
            .max_verifies = @intCast(@max(3, @min(verifies, 100))),
            .concurrency = options.concurrency orelse (if (concurrent >= 1) @intCast(@min(concurrent, 256)) else 8),
            .allow_incomplete_push = settings.getBool("lfs.allowincompletepush", false),
        };
    }

    /// git-lfs's backoff: a quarter of a second, doubled each retry, up to
    /// the most it may wait.
    fn backoffMs(l: Limits, attempt: u32) u64 {
        const max_ms: u64 = @as(u64, l.max_retry_delay_s) * 1000;
        if (attempt == 0) return 0;
        const shift: u6 = @intCast(@min(attempt - 1, 40));
        const delay: u64 = @as(u64, 250) << shift;
        return @min(delay, max_ms);
    }
};

//=====================================================================
// The batch API's JSON
//=====================================================================

/// A batch answer, read.
pub const BatchResponse = struct {
    transfer: ?[]const u8 = null,
    objects: []const BatchObject = &.{},
    hash_algo: ?[]const u8 = null,
};

/// One object of a batch answer.
pub const BatchObject = struct {
    oid: []const u8 = "",
    size: u64 = 0,
    authenticated: bool = false,
    actions: ?Actions = null,
    /// What the API called `actions` before it was renamed; git-lfs still
    /// reads it.
    _links: ?Actions = null,
    @"error": ?ObjectError = null,

    /// The action named `rel`, from `actions` or else `_links`.
    pub fn action(o: *const BatchObject, rel: Rel) ?Action {
        inline for (.{ o.actions, o._links }) |set| {
            if (set) |s| {
                const found = switch (rel) {
                    .download => s.download,
                    .upload => s.upload,
                    .verify => s.verify,
                };
                if (found) |a| return a;
            }
        }
        return null;
    }
};

/// The actions an object may carry.
pub const Rel = enum { download, upload, verify };

/// An object's actions.
pub const Actions = struct {
    download: ?Action = null,
    upload: ?Action = null,
    verify: ?Action = null,
};

/// One action: where to go, and what to say when there.
pub const Action = struct {
    href: []const u8,
    header: ?std.json.ArrayHashMap([]const u8) = null,
    /// When the action stops working, as RFC 3339 text, or how many seconds
    /// after the answer. With `lfsapi.Options.now`, an action that expires
    /// within five seconds of it is not used, and the object gets a fresh
    /// batch, as git-lfs does; without it, a refused action gets one.
    expires_at: ?[]const u8 = null,
    expires_in: ?i64 = null,
    /// Over git-lfs's pure-ssh protocol: what the server named the object
    /// and the transfer by, handed back with each request for it.
    id: ?[]const u8 = null,
    token: ?[]const u8 = null,

    /// Whether the action, answered at `now`, expires within five seconds
    /// of it.
    pub fn expiredAt(a: Action, now: i64) bool {
        const at = if (a.expires_at) |t| timetext.parseRfc3339(t) else null;
        return lfsapi.expiresWithin(now, a.expires_in orelse 0, at, 5);
    }

    /// Errors from `headers`.
    pub const HeadersError = Allocator.Error || error{InvalidHttpHeader};

    /// The action's headers, checked.
    pub fn headers(a: Action, arena: Allocator) HeadersError![]const http.Header {
        var out: std.ArrayList(http.Header) = .empty;
        if (a.header) |map| {
            var it = map.map.iterator();
            while (it.next()) |kv| {
                try lfsapi.checkHeader(kv.key_ptr.*, kv.value_ptr.*);
                try out.append(arena, .{ .name = kv.key_ptr.*, .value = kv.value_ptr.* });
            }
        }
        return out.items;
    }
};

/// An object's own error in a batch answer.
pub const ObjectError = struct {
    code: i64 = 0,
    message: []const u8 = "",
};

/// Errors from `parseBatch`.
pub const ParseBatchError = Allocator.Error || error{MalformedResponse};

/// Read a batch answer. Every string is allocated in `arena`. An answer that
/// does not parse, whose objects are not named by a SHA-256, or that names
/// another hash algorithm, is `error.MalformedResponse`.
pub fn parseBatch(arena: Allocator, bytes: []const u8) ParseBatchError!BatchResponse {
    const parsed = std.json.parseFromSliceLeaky(BatchResponse, arena, bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedResponse,
    };
    if (parsed.hash_algo) |algo| {
        if (algo.len != 0 and !std.mem.eql(u8, algo, "sha256")) return error.MalformedResponse;
    }
    for (parsed.objects) |o| {
        if (!isOid(o.oid)) return error.MalformedResponse;
    }
    return parsed;
}

fn isOid(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// The body of a batch request, as git-lfs writes it: the operation, the
/// objects, the ref, and the hash algorithm; the transfer adapters are left
/// out, which means `basic`.
pub fn writeBatchRequest(w: *Io.Writer, operation: lfsapi.Operation, objects: []const Object, ref: ?[]const u8) Io.Writer.Error!void {
    return writeBatchRequestOffering(w, operation, objects, ref, &.{});
}

/// A batch request offering the custom adapters `transfers` beside
/// `basic`, as git-lfs offers the adapters it has; with none, as
/// `writeBatchRequest` writes it.
pub fn writeBatchRequestOffering(w: *Io.Writer, operation: lfsapi.Operation, objects: []const Object, ref: ?[]const u8, transfers: []const []const u8) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("operation");
    try s.write(@tagName(operation));
    try s.objectField("objects");
    try s.beginArray();
    for (objects) |o| {
        try s.beginObject();
        try s.objectField("oid");
        try s.write(&o.oid);
        try s.objectField("size");
        try s.write(o.size);
        try s.endObject();
    }
    try s.endArray();
    if (transfers.len != 0) {
        try s.objectField("transfers");
        try s.beginArray();
        try s.write("basic");
        for (transfers) |t| try s.write(t);
        try s.endArray();
    }
    try s.objectField("ref");
    try s.beginObject();
    if (ref) |name| {
        try s.objectField("name");
        try s.write(name);
    }
    try s.endObject();
    try s.objectField("hash_algo");
    try s.write("sha256");
    try s.endObject();
}

//=====================================================================
// Transfers
//=====================================================================

/// Download `objects` into the repository's store. An object already there
/// is not asked for.
pub fn download(io: Io, server: *lfsapi.Server, objects: []const Object, options: Options) transfer.Error!Outcome {
    return run(io, server, .download, objects, options);
}

/// Upload `objects` from the repository's store. An object the server
/// already has is not sent.
pub fn upload(io: Io, server: *lfsapi.Server, objects: []const Object, options: Options) transfer.Error!Outcome {
    return run(io, server, .upload, objects, options);
}

/// One object's transfer, for a worker.
const Job = struct {
    result: *Result,
    action: Action,
    verify: ?Action,
    authenticated: bool,
    /// Moved by the custom adapter's processes.
    custom: bool = false,
    /// With no action: a standalone agent's.
    standalone: bool = false,
};

/// What a worker says to the task that started it.
const Event = union(enum) {
    bytes: u64,
    /// Bytes of an attempt that failed, taken back off.
    unsent: u64,
    object: void,
    worker_done: void,
};

const Run = struct {
    operation_io: Io,
    server: *lfsapi.Server,
    operation: lfsapi.Operation,
    /// git-lfs's pure-ssh protocol, when the remote speaks it.
    ssh: ?*lfsssh.Transfer = null,
    /// A custom adapter's processes, one per worker.
    agents: []const *custom.Agent = &.{},
    /// The store's directory, absolute: where an upload's file is named.
    store_base: []const u8 = "",
    options: Options,
    limits: Limits,
    arena: Allocator,
    arena_mutex: Io.Mutex = .init,
    jobs: []Job,
    next: std.atomic.Value(usize) = .init(0),
    events: ?*Io.Queue(Event) = null,
    fatal: ?Error = null,
    fatal_mutex: Io.Mutex = .init,
    total_bytes: u64 = 0,
    done_bytes: u64 = 0,
    done_objects: u64 = 0,
    total_objects: u64 = 0,

    fn io(r: *const Run) Io {
        return r.operation_io;
    }

    fn setFatal(r: *Run, err: Error) void {
        r.fatal_mutex.lockUncancelable(r.io());
        defer r.fatal_mutex.unlock(r.io());
        if (r.fatal == null) r.fatal = err;
    }

    fn failure(r: *Run) ?Error {
        r.fatal_mutex.lockUncancelable(r.io());
        defer r.fatal_mutex.unlock(r.io());
        return r.fatal;
    }

    fn dupe(r: *Run, bytes: []const u8) Allocator.Error![]const u8 {
        r.arena_mutex.lockUncancelable(r.io());
        defer r.arena_mutex.unlock(r.io());
        return r.arena.dupe(u8, bytes);
    }

    /// Say something to the calling task: through the queue from a worker,
    /// or straight to the caller's `Progress` when this is the calling task.
    fn say(r: *Run, event: Event) void {
        if (r.events) |q| {
            // ziglint-ignore: Z026 a closed queue means the calling task has stopped listening; there is no one left to tell
            q.putOneUncancelable(r.io(), event) catch {};
            return;
        }
        r.hear(event);
    }

    fn hear(r: *Run, event: Event) void {
        switch (event) {
            .bytes => |n| {
                r.done_bytes += n;
                progress_mod.Progress.emit(r.options.progress, .{ .lfs_bytes = .{ .done = r.done_bytes, .total = r.total_bytes } });
            },
            .unsent => |n| {
                r.done_bytes -|= n;
                progress_mod.Progress.emit(r.options.progress, .{ .lfs_bytes = .{ .done = r.done_bytes, .total = r.total_bytes } });
            },
            .object => {
                r.done_objects += 1;
                progress_mod.Progress.emit(r.options.progress, .{ .lfs_objects = .{ .done = r.done_objects, .total = r.total_objects } });
            },
            .worker_done => {},
        }
    }
};

/// git-lfs's reference directories: the `lfs/objects` beside each object
/// directory `objects/info/alternates` names — what `git clone --reference`
/// and `--shared` leave — where one is there. A relative line is taken from
/// `objects`, as git takes it; a line in double quotes has its backslash
/// escapes undone, as git-lfs undoes them.
fn referenceDirs(arena: Allocator, io: Io, store: *const lfs.Store) Allocator.Error![]const []const u8 {
    const text = fs.readFileAlloc(arena, io, store.base, "objects/info/alternates", 1 << 20) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // An alternates file that cannot be read names no reference, as
        // git-lfs, which only notes it in its trace, takes it.
        else => return &.{},
    } orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '"') {
            const close = std.mem.findScalarLast(u8, line, '"').?;
            if (close == 0) continue;
            var unquoted: std.ArrayList(u8) = .empty;
            var i: usize = 1;
            while (i < close) : (i += 1) {
                if (line[i] == '\\' and i + 1 < close) i += 1;
                try unquoted.append(arena, line[i]);
            }
            line = unquoted.items;
        }
        line = std.mem.trimEnd(u8, line, "/");
        const parent = std.Io.Dir.path.dirname(line) orelse continue;
        const dir = if (std.Io.Dir.path.isAbsolute(parent))
            try arena.print("{s}/lfs/objects", .{parent})
        else
            try arena.print("objects/{s}/lfs/objects", .{parent});
        const stat = store.base.statFile(io, dir, .{}) catch continue;
        if (stat.kind == .directory) try out.append(arena, dir);
    }
    return out.items;
}

/// Put the object in the store from the first reference directory that
/// has it at its size — a hard link, or a copy where one cannot be made —
/// as git-lfs's `LinkOrCopyFromReference` does before it asks a server.
/// A copy is checked against its name on the way in. One that cannot be
/// linked or copied is left for the server, as git-lfs leaves it.
fn fromReference(io: Io, store: *const lfs.Store, references: []const []const u8, pointer: *const lfs.Pointer) Error!bool {
    if (references.len == 0) return false;
    var object_buf: [lfs.Store.max_path]u8 = undefined;
    const object_path = try store.objectPath(&object_buf, &pointer.oid);
    for (references) |dir| {
        var ref_buf: [lfs.Store.max_path]u8 = undefined;
        const ref_path = std.mem.print(&ref_buf, "{s}/{s}/{s}/{s}", .{ dir, pointer.oid[0..2], pointer.oid[2..4], &pointer.oid }) catch continue;
        const stat = store.base.statFile(io, ref_path, .{}) catch continue;
        if (stat.kind != .file or stat.size != pointer.size) continue;
        try store.base.createDirPath(io, std.Io.Dir.path.dirnamePosix(object_path).?);
        if (fs.hardLink(io, store.base, ref_path, object_path)) {
            return true;
        } else |_| {}
        const file = store.base.openFile(io, ref_path, .{}) catch continue;
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buf);
        _ = store.install(io, &reader.interface, pointer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        return true;
    }
    return false;
}

fn run(io: Io, server: *lfsapi.Server, operation: lfsapi.Operation, objects: []const Object, given: Options) Error!Outcome {
    var outcome = try runTransfers(io, server, operation, objects, given);
    // git-lfs sweeps its temporary files when a command ends.
    if (server.client.options.now) |now| {
        sweepTmp(server.gpa, io, server.store(), now) catch |err| {
            outcome.sweep_failed = @errorName(err);
        };
    }
    return outcome;
}

/// Errors from sweeping `lfs/tmp`.
pub const SweepError = Allocator.Error || Io.Dir.OpenError || Io.Dir.Iterator.Error || Io.Dir.StatFileError || Io.Dir.DeleteFileError || error{NameTooLong};

/// git-lfs's sweep of `lfs/tmp` at `now`, in seconds since the epoch: a
/// file named `<oid>-…` whose object the store has goes, and so does any
/// other file last changed more than an hour before, except in a
/// directory under it changed within the hour, whose files may be links
/// something is still using. Directories stay.
pub fn sweepTmp(gpa: Allocator, io: Io, store: *const lfs.Store, now: i64) transfer.SweepError!void {
    var path_buf: [lfs.Store.max_path]u8 = undefined;
    const tmp_path = std.mem.print(&path_buf, "{s}/tmp", .{store.root}) catch return error.NameTooLong;
    var tmp = store.base.openDir(io, tmp_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => |e| return e,
    };
    defer tmp.close(io);
    var walker = try tmp.walk(gpa);
    defer walker.deinit();
    const hour: i64 = 3600;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        const name = entry.basename;
        if (name.len > 65 and name[64] == '-') {
            var object_buf: [lfs.Store.max_path]u8 = undefined;
            if (store.objectPath(&object_buf, name[0..64])) |object_path| {
                if (store.base.statFile(io, object_path, .{})) |st| {
                    if (st.kind != .directory) {
                        try tmp.deleteFile(io, entry.path);
                        continue;
                    }
                } else |_| {}
            } else |_| {}
        }
        if (std.Io.Dir.path.dirname(entry.path)) |parent| {
            const dir_stat = tmp.statFile(io, parent, .{}) catch continue;
            if (now - epochSeconds(dir_stat.mtime) <= hour) continue;
        }
        const st = tmp.statFile(io, entry.path, .{}) catch continue;
        if (now - epochSeconds(st.mtime) > hour) try tmp.deleteFile(io, entry.path);
    }
}

fn epochSeconds(t: Io.Timestamp) i64 {
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s));
}

fn runTransfers(io: Io, server: *lfsapi.Server, operation: lfsapi.Operation, objects: []const Object, given: Options) Error!Outcome {
    const gpa = server.gpa;
    // A download names the ref git-lfs names, whatever it is for.
    var options = given;
    if (options.ref == null and operation == .download) options.ref = server.download_ref;
    var outcome: Outcome = .{ .arena = .init(gpa), .results = &.{} };
    errdefer outcome.arena.deinit();
    const arena = outcome.arena.allocator();

    // One result per object, the first name each is known by.
    var results: std.ArrayList(Result) = .empty;
    {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        for (objects) |*o| {
            const gop = try seen.getOrPut(gpa, &o.oid);
            if (gop.found_existing) continue;
            try results.append(arena, .{ .oid = o.oid, .size = o.size, .name = try arena.dupe(u8, o.name), .status = .failed });
        }
    }
    outcome.results = results.items;
    const store = server.store();

    // A download of what the store has, or a reference directory has, or
    // of a pointer to nothing, moves nothing.
    var pending: std.ArrayList(usize) = .empty;
    var missing_here: std.ArrayList(bool) = .empty;
    try missing_here.resize(arena, outcome.results.len);
    const references: []const []const u8 = if (operation == .download) try referenceDirs(arena, io, store) else &.{};
    for (outcome.results, 0..) |*r, i| {
        const pointer = Object.asPointer(.{ .oid = r.oid, .size = r.size });
        var here = try store.contains(io, &pointer);
        if (!here and r.size != 0) here = try fromReference(io, store, references, &pointer);
        missing_here.items[i] = !here;
        if (r.size == 0 or (operation == .download and here)) {
            r.status = .present;
            continue;
        }
        try pending.append(arena, i);
    }
    if (pending.items.len == 0) return outcome;

    var limits = Limits.read(&server.settings, options);
    const endpoint = try server.client.endpoint(io, operation);
    const adapters = try custom.configured(arena, server.settings.config);
    // A standalone agent moves everything with no API at all; git-lfs's own
    // for a remote on this machine is the store-to-store copy below.
    if (try standaloneAgent(arena, server, endpoint)) |name| {
        if (custom.find(adapters, name, operation)) |adapter| {
            try runStandalone(io, server, operation, adapter, &outcome, pending.items, missing_here.items, limits, options);
            return outcome;
        }
    }
    {
        var offered: std.ArrayList([]const u8) = .empty;
        for (adapters) |a| if (a.moves(operation)) try offered.append(arena, a.name);
        limits.transfers = offered.items;
    }
    if (endpoint.isLocal()) {
        try copyLocal(io, server, endpoint, operation, &outcome, pending.items, missing_here.items, limits, options);
        return outcome;
    }

    var state: Run = .{
        .operation_io = io,
        .server = server,
        .operation = operation,
        .ssh = try server.client.sshTransfer(io, operation),
        .options = options,
        .limits = limits,
        .arena = arena,
        .jobs = &.{},
    };
    var jobs: std.ArrayList(Job) = .empty;
    // The custom adapter the answers chose, if one did.
    var chosen: ?custom.Adapter = null;
    var start: usize = 0;
    while (start < pending.items.len) : (start += limits.batch_size) {
        const chunk = pending.items[start..@min(pending.items.len, start + limits.batch_size)];
        try batchChunk(&state, chunk, outcome.results, missing_here.items, adapters, &chosen, &jobs);
    }
    if (jobs.items.len == 0) return outcome;
    // Each job settles one pending object's result, once.
    assert(jobs.items.len <= pending.items.len);
    state.jobs = jobs.items;
    state.total_objects = jobs.items.len;
    for (jobs.items) |j| state.total_bytes += j.result.size;

    if (chosen) |adapter| try startAgents(&state, adapter);
    defer stopAgents(&state);
    try runJobs(&state);
    if (state.failure()) |err| return err;
    return outcome;
}

/// One batch request for the pending objects `chunk` names: what the
/// server answered becomes jobs, in the order of its answer, as git-lfs's
/// queue takes them; an object it left out, refused, or has no action for
/// is settled here. The custom adapter an answer chooses must be the one
/// any other answer chose.
fn batchChunk(
    state: *Run,
    chunk: []const usize,
    results: []Result,
    missing_here: []const bool,
    adapters: []const custom.Adapter,
    chosen: *?custom.Adapter,
    jobs: *std.ArrayList(Job),
) Error!void {
    const server = state.server;
    const operation = state.operation;
    const gpa = server.gpa;
    const arena = state.arena;
    var wanted: std.ArrayList(Object) = .empty;
    defer wanted.deinit(gpa);
    for (chunk) |i| {
        const r = results[i];
        try wanted.append(gpa, .{ .oid = r.oid, .size = r.size, .name = r.name });
    }
    const answer = batchRequest(state.io(), server, operation, wanted.items, state.options.ref, state.limits, arena) catch |err| switch (err) {
        error.LfsBatchFailed => {
            const why = try arena.dupe(u8, server.client.message());
            for (chunk) |i| {
                results[i].status = .failed;
                results[i].message = why;
            }
            return;
        },
        else => |e| return e,
    };
    var by_custom = false;
    if (answer.transfer) |t| {
        if (state.ssh == null and t.len != 0 and !std.mem.eql(u8, t, "basic")) {
            const adapter = custom.find(adapters, t, operation) orelse return error.LfsTransferUnsupported;
            if (chosen.*) |c| if (!std.mem.eql(u8, c.name, adapter.name)) return error.LfsTransferUnsupported;
            chosen.* = adapter;
            by_custom = true;
        }
    }
    // The transfers go in the order of the server's answer, as
    // git-lfs's queue takes them; an object it left out fails.
    var asked: std.StringHashMapUnmanaged(usize) = .empty;
    defer asked.deinit(gpa);
    for (chunk) |i| try asked.put(gpa, &results[i].oid, i);
    var order: std.ArrayList(struct { i: usize, o: ?*const BatchObject }) = .empty;
    defer order.deinit(gpa);
    for (answer.objects) |*o| {
        const kv = asked.fetchRemove(o.oid) orelse continue;
        try order.append(gpa, .{ .i = kv.value, .o = o });
    }
    for (chunk) |i| {
        if (asked.contains(&results[i].oid)) try order.append(gpa, .{ .i = i, .o = null });
    }
    for (order.items) |entry| {
        const i = entry.i;
        const r = &results[i];
        const o = entry.o orelse {
            r.status = .failed;
            r.message = "the server's answer left the object out";
            continue;
        };
        if (o.@"error") |e| {
            r.status = .refused;
            r.message = try arena.print("[{d}] {s}", .{ e.code, e.message });
            continue;
        }
        switch (operation) {
            .download => {
                const a = o.action(.download) orelse {
                    r.status = .refused;
                    r.message = "the server has no download for the object";
                    continue;
                };
                try jobs.append(arena, .{ .result = r, .action = a, .verify = null, .authenticated = o.authenticated, .custom = by_custom });
            },
            .upload => {
                const a = o.action(.upload) orelse {
                    r.status = .present;
                    continue;
                };
                if (missing_here[i]) {
                    r.status = if (state.limits.allow_incomplete_push) .present else .missing;
                    r.message = "the object is not in the store, and the server does not have it";
                    continue;
                }
                try jobs.append(arena, .{ .result = r, .action = a, .verify = o.action(.verify), .authenticated = o.authenticated, .custom = by_custom });
            },
        }
    }
}

/// The standalone agent `lfs.<url>.standalonetransferagent` names for the
/// endpoint, else git-lfs's own for a remote on this machine.
fn standaloneAgent(arena: Allocator, server: *lfsapi.Server, endpoint: lfsapi.Endpoint) Error!?[]const u8 {
    if (try server.settings.urlGet(arena, "lfs", endpoint.url, "standalonetransferagent")) |name| {
        if (name.len != 0) return name;
    }
    return if (endpoint.isLocal()) "lfs-standalone-file" else null;
}

/// Every object through a standalone agent, which asks no server: a
/// download of each the store lacks, an upload of each it has.
fn runStandalone(
    io: Io,
    server: *lfsapi.Server,
    operation: lfsapi.Operation,
    adapter: custom.Adapter,
    outcome: *Outcome,
    pending: []const usize,
    missing_here: []const bool,
    limits: Limits,
    options: Options,
) Error!void {
    const arena = outcome.arena.allocator();
    var state: Run = .{
        .operation_io = io,
        .server = server,
        .operation = operation,
        .options = options,
        .limits = limits,
        .arena = arena,
        .jobs = &.{},
    };
    var jobs: std.ArrayList(Job) = .empty;
    for (pending) |i| {
        const r = &outcome.results[i];
        if (operation == .upload and missing_here[i]) {
            r.status = if (limits.allow_incomplete_push) .present else .missing;
            r.message = "the object is not in the store";
            continue;
        }
        try jobs.append(arena, .{ .result = r, .action = .{ .href = "" }, .verify = null, .authenticated = false, .custom = true, .standalone = true });
    }
    if (jobs.items.len == 0) return;
    state.jobs = jobs.items;
    state.total_objects = jobs.items.len;
    for (jobs.items) |j| state.total_bytes += j.result.size;
    try startAgents(&state, adapter);
    defer stopAgents(&state);
    try runJobs(&state);
    if (state.failure()) |err| return err;
}

/// Start the adapter's processes, `lfs.concurrenttransfers` of them or
/// one, as git-lfs starts them, each told `init`.
fn startAgents(state: *Run, adapter: custom.Adapter) Error!void {
    const server = state.server;
    const programs = server.client.options.programs orelse return error.ProgramsNotGranted;
    const count: u32 = if (adapter.concurrent) state.limits.concurrency else 1;
    const agents = try state.arena.alloc(*custom.Agent, count);
    var started: usize = 0;
    errdefer for (agents[0..started]) |a| a.deinit(state.io());
    while (started < count) : (started += 1) {
        agents[started] = try custom.Agent.open(server.gpa, state.io(), programs, .{ .cwd = server.base_path, .adapter = adapter, .init = .{
            .operation = state.operation,
            .remote = server.remote,
            .concurrent = adapter.concurrent,
            .concurrent_transfers = state.limits.concurrency,
        } });
    }
    state.agents = agents;
    state.limits.concurrency = count;
    const base = try server.store().base.realPathFileAlloc(state.io(), ".", server.gpa);
    defer server.gpa.free(base);
    state.store_base = try state.arena.dupe(u8, base);
}

fn stopAgents(state: *Run) void {
    for (state.agents) |a| a.deinit(state.io());
    state.agents = &.{};
}

/// One transfer through the worker's own process.
fn attemptCustom(state: *Run, worker: usize, r: *Result, action: ?Action, verify: ?Action, authenticated: bool) Error!Attempt {
    const server = state.server;
    const io = state.io();
    const store = server.store();
    var scratch_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var path_buf: [lfs.Store.max_path]u8 = undefined;
    const upload_path: ?[]const u8 = if (state.operation == .upload)
        try std.Io.Dir.path.join(scratch, &.{ state.store_base, try store.objectPath(&path_buf, &r.oid) })
    else
        null;
    var request_action: ?custom.Action = null;
    if (action) |a| {
        var headers: std.ArrayList(custom.Action.Header) = .empty;
        if (a.header) |map| {
            var it = map.map.iterator();
            while (it.next()) |kv| try headers.append(scratch, .{ .name = kv.key_ptr.*, .value = kv.value_ptr.* });
        }
        request_action = .{ .href = a.href, .header = headers.items, .expires_at = a.expires_at, .expires_in = a.expires_in orelse 0 };
    }
    const Progress = struct {
        pub const Self = @This();

        state: *Run,
        pub fn bytes(p: Self, n: u64) void {
            p.state.say(.{ .bytes = n });
        }
    };
    const ended = try state.agents[worker].transfer(io, .{
        .operation = state.operation,
        .oid = &r.oid,
        .size = r.size,
        .path = upload_path,
        .action = request_action,
    }, Progress{ .state = state });
    switch (ended) {
        .failed => |f| return .{ .fail = try state.arena.print("[{d}] {s}", .{ f.code, f.message }) },
        .done => |path| {
            if (state.operation == .upload) {
                const v = verify orelse return .ok;
                return verifyUpload(state, r, v, authenticated);
            }
            // The agent's file, checked against the object's name on its
            // way into the store, then given up as git-lfs gives it up.
            const named = path orelse return .{ .fail = "the custom transfer named no file" };
            const full = if (std.Io.Dir.path.isAbsolute(named)) named else try std.Io.Dir.path.join(scratch, &.{ server.base_path, named });
            const file = Io.Dir.cwd().openFile(io, full, .{}) catch return .{ .fail = "the custom transfer's file cannot be read" };
            defer {
                file.close(io);
                Io.Dir.cwd().deleteFile(io, full) catch {};
            }
            var buf: [64 * 1024]u8 = undefined;
            var fr = file.reader(io, &buf);
            const pointer: lfs.Pointer = .{ .oid = r.oid, .size = r.size };
            _ = store.install(io, &fr.interface, &pointer) catch |err| switch (err) {
                error.LfsObjectMismatch => return .{ .fail = "the custom transfer's file is not the object" },
                error.ReadFailed => return fr.err.?,
                else => |e| return e,
            };
            return .ok;
        },
    }
}

/// Run the jobs `concurrency` at a time. Workers run on the caller's `Io`;
/// what they have to say comes back through a queue, so the caller's
/// `Progress` is only ever called from the caller's own task. An `Io`
/// without concurrency runs them one after another on the calling task.
fn runJobs(state: *Run) Error!void {
    const io = state.io();
    const workers = @min(state.limits.concurrency, state.jobs.len);
    if (workers <= 1) {
        work(state, 0);
        return;
    }
    var buffer: [256]Event = undefined;
    var queue: Io.Queue(Event) = .init(&buffer);
    state.events = &queue;
    var group: Io.Group = .init;
    var spawned: usize = 0;
    while (spawned < workers) : (spawned += 1) {
        group.concurrent(io, workerTask, .{ state, spawned }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => break,
        };
    }
    if (spawned == 0) {
        state.events = null;
        work(state, 0);
        return;
    }
    var finished: usize = 0;
    while (finished < spawned) {
        const event = queue.getOne(io) catch |err| {
            group.cancel(io);
            return switch (err) {
                error.Canceled => error.Canceled,
                // The queue is never closed.
                error.Closed => unreachable,
            };
        };
        switch (event) {
            .worker_done => finished += 1,
            else => state.hear(event),
        }
    }
    try group.await(io);
}

test "a transfer worker observes a fatal error under its publication lock" {
    const Controlled = struct {
        const Self = @This();
        run: *Run,
        waited: bool = false,

        fn wait(raw: ?*anyopaque, _: *const u32, _: u32) void {
            const state: *Self = @ptrCast(@alignCast(raw.?));
            state.waited = true;
            // Another worker already holds the lock, and publishes its
            // failure before handing it to this worker.
            state.run.fatal = error.OutOfMemory;
            state.run.fatal_mutex.state.store(.unlocked, .release);
        }

        fn wake(_: ?*anyopaque, _: *const u32, _: u32) void {}
    };
    var server: lfsapi.Server = undefined;
    var state: Run = .{
        .operation_io = std.testing.io,
        .server = &server,
        .operation = .download,
        .options = .{},
        .limits = undefined,
        .arena = std.testing.allocator,
        .jobs = &.{},
    };
    var control: Controlled = .{ .run = &state };
    var vtable = std.testing.io.vtable.*;
    vtable.futexWaitUncancelable = Controlled.wait;
    vtable.futexWake = Controlled.wake;
    state.operation_io = .{ .userdata = &control, .vtable = &vtable };
    state.fatal_mutex.state.store(.locked_once, .release);
    work(&state, 0);
    try std.testing.expect(control.waited);
    try std.testing.expectEqual(@as(usize, 0), state.next.load(.acquire));
    state.setFatal(error.Canceled);
    try std.testing.expectEqual(error.OutOfMemory, state.fatal.?);
}

fn workerTask(state: *Run, worker: usize) void {
    work(state, worker);
    state.say(.worker_done);
}

fn work(state: *Run, worker: usize) void {
    while (true) {
        if (state.failure() != null) return;
        const i = state.next.fetchAdd(1, .monotonic);
        if (i >= state.jobs.len) return;
        runJob(state, &state.jobs[i], worker) catch |err| state.setFatal(err);
        state.say(.object);
    }
}

/// Why one attempt at a transfer failed, and whether to try again.
const Attempt = union(enum) {
    ok,
    /// Try again, after the backoff or the server's `Retry-After`.
    retry: struct { message: []const u8, after_s: ?u64 = null },
    /// Give up.
    fail: []const u8,
};

fn runJob(state: *Run, job: *Job, worker: usize) Error!void {
    const r = job.result;
    var retries: u32 = 0;
    var action = job.action;
    var verify = job.verify;
    var authenticated = job.authenticated;
    while (true) {
        const expired: ?Rel = if (job.standalone) null else if (state.server.client.options.now) |now|
            (if (action.expiredAt(now)) (if (state.operation == .download) Rel.download else Rel.upload) else if (verify != null and verify.?.expiredAt(now)) Rel.verify else null)
        else
            null;
        const attempt: Attempt = if (expired) |rel|
            .{ .retry = .{ .message = switch (rel) {
                .download => "the download action has expired",
                .upload => "the upload action has expired",
                .verify => "the verify action has expired",
            } } }
        else if (job.custom)
            try attemptCustom(state, worker, r, if (job.standalone) null else action, verify, authenticated)
        else if (state.ssh) |t| switch (state.operation) {
            // One connection per worker, as git-lfs runs them.
            .download => try attemptDownloadSsh(state, t, worker, r, action),
            .upload => try attemptUploadSsh(state, t, worker, r, action),
        } else switch (state.operation) {
            .download => try attemptDownload(state, r, action, authenticated),
            .upload => try attemptUpload(state, r, action, verify, authenticated),
        };
        switch (attempt) {
            .ok => {
                r.status = .transferred;
                return;
            },
            .fail => |why| {
                r.status = .failed;
                r.message = why;
                return;
            },
            .retry => |why| {
                if (retries >= state.limits.max_retries) {
                    r.status = .failed;
                    r.message = why.message;
                    return;
                }
                retries += 1;
                var delay_ms = state.limits.backoffMs(retries);
                if (why.after_s) |seconds| {
                    if (seconds > state.limits.max_retry_time_s) {
                        r.status = .failed;
                        r.message = why.message;
                        return;
                    }
                    delay_ms = seconds * 1000;
                }
                if (delay_ms != 0) try state.io().sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
                // A fresh batch for the object, as git-lfs retries it: the
                // action may have expired, or pointed somewhere that failed.
                const again = batchRequest(state.io(), state.server, state.operation, &.{.{ .oid = r.oid, .size = r.size, .name = r.name }}, state.options.ref, state.limits, null) catch |err| switch (err) {
                    error.LfsBatchFailed => {
                        r.status = .failed;
                        r.message = try state.dupe(state.server.client.message());
                        return;
                    },
                    else => |e| return e,
                };
                defer again.arena.deinit();
                const o = if (again.response.objects.len == 1) &again.response.objects[0] else {
                    r.status = .failed;
                    r.message = "the server's answer left the object out";
                    return;
                };
                if (o.@"error") |e| {
                    r.status = .refused;
                    r.message = try state.dupe(e.message);
                    return;
                }
                const rel: Rel = if (state.operation == .download) .download else .upload;
                const fresh = o.action(rel) orelse {
                    // An upload the server now has, or a download it no
                    // longer offers.
                    r.status = if (state.operation == .upload) .transferred else .refused;
                    return;
                };
                action = try copyAction(state, fresh);
                verify = if (o.action(.verify)) |v| try copyAction(state, v) else null;
                authenticated = o.authenticated;
            },
        }
    }
}

fn copyAction(state: *Run, a: Action) Error!Action {
    state.arena_mutex.lockUncancelable(state.io());
    defer state.arena_mutex.unlock(state.io());
    var out: Action = .{
        .href = try state.arena.dupe(u8, a.href),
        .expires_at = if (a.expires_at) |t| try state.arena.dupe(u8, t) else null,
        .expires_in = a.expires_in,
        .id = if (a.id) |v| try state.arena.dupe(u8, v) else null,
        .token = if (a.token) |v| try state.arena.dupe(u8, v) else null,
    };
    if (a.header) |map| {
        var copy: std.json.ArrayHashMap([]const u8) = .{};
        var it = map.map.iterator();
        while (it.next()) |kv| try copy.map.put(state.arena, try state.arena.dupe(u8, kv.key_ptr.*), try state.arena.dupe(u8, kv.value_ptr.*));
        out.header = copy;
    }
    return out;
}

/// An action's URL, rewritten by `url.<base>.insteadOf` — or
/// `pushInsteadOf` for an upload — when `lfs.transfer.enablehrefrewrite`
/// asks, as git-lfs rewrites it.
fn rewriteHref(state: *Run, scratch: Allocator, href: []const u8) Error![]const u8 {
    if (!state.server.settings.getBool("lfs.transfer.enablehrefrewrite", false)) return href;
    const config = state.server.settings.config;
    const rewrite = remote_mod.rewrite;
    const pushed = if (state.operation == .upload) rewrite(scratch, config, href, .push) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedValue,
    } else null;
    if (pushed) |p| return p;
    return (rewrite(scratch, config, href, .fetch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedValue,
    }) orelse href;
}

/// The URL whose access mode a transfer uses, as git-lfs finds it: the
/// action's up to the object's name.
fn accessUrl(href: []const u8, oid: []const u8) []const u8 {
    const at = std.mem.find(u8, href, oid) orelse return href;
    return href[0..at];
}

fn attemptDownload(state: *Run, r: *Result, action: Action, authenticated: bool) Error!Attempt {
    const server = state.server;
    const io = state.io();
    const store = server.store();
    var scratch_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const href = try rewriteHref(state, scratch, action.href);
    const headers = action.headers(scratch) catch |err| switch (err) {
        error.InvalidHttpHeader => return .{ .fail = "the server's action has a header with a line break in it" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const accept = switch (try downloadAccept(state, scratch, action.href)) {
        .accept => |a| a,
        .fail => |why| return .{ .fail = why },
    };

    // The download goes into `<lfs>/incomplete`, as git-lfs's does, and a
    // download that breaks off leaves `<oid>.part` there for the next
    // attempt — this operation's or a later one's — to go on from.
    const incomplete = try scratch.print("{s}/incomplete", .{store.root});
    try store.base.createDirPath(io, incomplete);
    const part_path = try scratch.print("{s}/{s}.part", .{ incomplete, &r.oid });
    var name_buf: [64]u8 = undefined;
    const temp_path = try scratch.print("{s}/{s}", .{ incomplete, fs.tempName(io, &name_buf, "dl-") });
    var resumed = true;
    fs.renameWithRetry(io, store.base, part_path, temp_path) catch |err| switch (err) {
        error.FileNotFound => resumed = false,
        else => |e| return e,
    };
    var partial: Partial = .{ .file = if (resumed)
        try store.base.openFile(io, temp_path, .{ .mode = .read_write })
    else
        try store.base.createFile(io, temp_path, .{ .exclusive = true, .read = true }) };
    var installed = false;
    defer {
        partial.file.close(io);
        if (!installed) {
            if (partial.keep) {
                fs.renameWithRetry(io, store.base, temp_path, part_path) catch {};
            } else store.base.deleteFile(io, temp_path) catch {};
        }
    }
    if (resumed) try partial.hashResumed(io, r.size);
    const resumed_from = partial.from;

    const ex = switch (try requestFrom(state, scratch, &partial, .{
        .href = href,
        .action_href = action.href,
        .headers = headers,
        .accept = accept,
        .authenticated = authenticated,
        .oid = &r.oid,
        .size = r.size,
    })) {
        .exchange => |ex| ex,
        .done => |attempt| return attempt,
    };
    defer ex.deinit(io);
    if (try partial.receive(scratch, state, ex, r.size, action.href)) |attempt| return attempt;

    var digest: [32]u8 = undefined;
    partial.sha.final(&digest);
    var hex: [64]u8 = undefined;
    _ = std.mem.print(&hex, "{x}", .{&digest}) catch unreachable; // unreachable: a SHA-256 digest is 32 bytes, 64 hex digits
    if (!std.mem.eql(u8, &hex, &r.oid)) {
        // A partial file that was not the start of this object: it is
        // thrown away, and the next attempt starts from nothing.
        if (resumed_from > 0) return .{ .retry = .{ .message = "a partial download was not the object's beginning" } };
        return .{ .fail = "the bytes the server sent are not the object" };
    }

    var object_buf: [lfs.Store.max_path]u8 = undefined;
    const pointer: lfs.Pointer = .{ .oid = r.oid, .size = r.size };
    const object_path = try store.objectPath(&object_buf, &pointer.oid);
    if (try store.contains(io, &pointer)) return .ok;
    try store.base.createDirPath(io, std.Io.Dir.path.dirnamePosix(object_path).?);
    try fs.renameWithRetry(io, store.base, temp_path, object_path);
    installed = true;
    return .ok;
}

/// The encoding a download asks for, or why it cannot be asked.
const DownloadAccept = union(enum) { accept: lfsapi.Client.Accept, fail: []const u8 };

/// `lfs.transfer.<url>.httpDownloadEncoding`, which git-lfs reads for the
/// action's own URL: gzip unless it says zstd.
fn downloadAccept(state: *Run, scratch: Allocator, href: []const u8) Error!DownloadAccept {
    const encoding = try state.server.settings.urlGet(scratch, "lfs.transfer", href, "httpdownloadencoding");
    if (encoding == null or encoding.?.len == 0 or std.mem.eql(u8, encoding.?, "gzip")) return .{ .accept = .gzip };
    if (std.mem.eql(u8, encoding.?, "zstd")) return .{ .accept = .zstd };
    return .{ .fail = try state.dupe(try scratch.print("unsupported lfs.transfer.httpDownloadEncoding value \"{s}\": must be \"gzip\" or \"zstd\"", .{encoding.?})) };
}

/// A download's file in `<lfs>/incomplete`, and how far it has come.
const Partial = struct {
    file: Io.File,
    /// The hash of the file's first `from` bytes.
    sha: std.crypto.hash.sha2.Sha256 = .init(.{}),
    from: u64 = 0,
    /// Whether the file is kept as `<oid>.part` for the next attempt.
    keep: bool = false,

    /// What an earlier attempt left is hashed again, so the name is taken
    /// over the whole object whichever attempt brought each byte. More than
    /// a partial object can be starts again.
    fn hashResumed(p: *Partial, io: Io, size: u64) Error!void {
        assert(p.from == 0);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try p.file.readPositionalAll(io, &buf, p.from);
            if (n == 0) break;
            p.sha.update(buf[0..n]);
            p.from += n;
            if (n < buf.len) break;
        }
        if (p.from >= size) try p.restart(io);
    }

    /// Start again from nothing.
    fn restart(p: *Partial, io: Io) Error!void {
        try p.file.setLength(io, 0);
        p.from = 0;
        p.sha = .init(.{});
    }

    /// Read the body of the answer from `href` onto the file after what is
    /// there: `null` once the whole object has come, else why the attempt
    /// ends.
    fn receive(p: *Partial, scratch: Allocator, state: *Run, ex: *lfsapi.Exchange, size: u64, href: []const u8) Error!?Attempt {
        const io = state.io();
        const status = ex.status();
        if (status.class() != .success) {
            p.keep = p.from > 0;
            const why = try scratch.print("HTTP {d} from {s}", .{ @backingInt(status), lfsapi.stripQuery(href) });
            if (status == .too_many_requests) return .{ .retry = .{ .message = try state.dupe(why), .after_s = ex.retryAfter() } };
            return .{ .retry = .{ .message = try state.dupe(why) } };
        }
        if (p.from > 0) state.say(.{ .bytes = p.from });
        const body = ex.reader(io) catch |err| switch (err) {
            error.LfsZstdWindowTooLarge => return .{ .fail = "the server's zstd frame asks for a window wider than 512 MiB" },
            else => |e| return e,
        };
        var counting: Counting = .init(body, state);
        var buf: [64 * 1024]u8 = undefined;
        var at = p.from;
        while (true) {
            // Filled as far as the body goes, and what came before a break
            // is kept like the rest.
            var n: usize = 0;
            var broken = false;
            while (n < buf.len) {
                var w: Io.Writer = .fixed(buf[n..]);
                n += counting.interface.stream(&w, .limited(buf.len - n)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => {
                        broken = true;
                        break;
                    },
                    error.WriteFailed => unreachable, // unreachable: the limit is the room the writer has
                };
            }
            if (at + n > size) return .{ .fail = "the server sent more than the object's size" };
            p.sha.update(buf[0..n]);
            try p.file.writePositionalAll(io, buf[0..n], at);
            at += n;
            if (broken) {
                // Broken off: what came is kept for the next attempt.
                p.keep = at > 0;
                return .{ .retry = .{ .message = try state.dupe(ex.bodyError()) } };
            }
            if (n < buf.len) break;
        }
        counting.flush();
        if (at < size) {
            // The body ended early: what came is kept for the next attempt.
            p.keep = true;
            return .{ .retry = .{ .message = "the download broke off" } };
        }
        assert(at == size);
        return null;
    }
};

/// What `requestFrom` asks for.
const DownloadRequest = struct {
    /// The URL asked, after `lfs.transfer.enablehrefrewrite`.
    href: []const u8,
    /// The action's own URL, which settings and access are keyed by.
    action_href: []const u8,
    headers: []const http.Header,
    accept: lfsapi.Client.Accept,
    authenticated: bool,
    oid: []const u8,
    size: u64,
};

/// What asking for a download gave: the exchange to read, or the end of
/// the attempt.
const Requested = union(enum) { exchange: *lfsapi.Exchange, done: Attempt };

/// Ask for the object from where `partial` has come to, with a Range when
/// that is past the start: a server that will not go on from there, or
/// goes on from elsewhere, is asked again for the whole object, and one
/// that passed the Range over sends it whole.
fn requestFrom(state: *Run, scratch: Allocator, partial: *Partial, req: DownloadRequest) Error!Requested {
    const server = state.server;
    const io = state.io();
    var range_buf: [64]u8 = undefined;
    var attempt_range = partial.from > 0;
    while (true) {
        var all: std.ArrayList(http.Header) = .empty;
        try all.appendSlice(scratch, req.headers);
        // `hashResumed` starts again from a file as long as the object.
        if (attempt_range) assert(partial.from < req.size);
        if (attempt_range) try all.append(scratch, .{ .name = "Range", .value = try std.mem.print(&range_buf, "bytes={d}-{d}", .{ partial.from, req.size - 1 }) });
        const sent = server.client.send(io, .{
            .method = .GET,
            .url = req.href,
            .headers = all.items,
            .authenticated = req.authenticated,
            .access_url = accessUrl(req.action_href, req.oid),
            // git-lfs asks for no encoding with a Range, and its client
            // asks for gzip itself without one.
            .accept = if (attempt_range) .none else req.accept,
        }) catch |err| switch (err) {
            // Nothing answered: git-lfs tries a request again whenever no
            // response came, the TLS handshake and the proxy refusing it
            // as much as the connection failing.
            error.ConnectionFailed, error.AuthenticationFailed, error.TooManyRedirects, error.ClientCertificateRejected, error.ClientCertificateSchemeUnsupported, error.ProxyRefused, error.ProxyAuthenticationRequired, error.ProxyAuthMethodUnsupported, error.ProxyHostUnreachable, error.ProxyAddressUnsupported, error.ProxyProtocolError, error.MalformedResponse => {
                partial.keep = partial.from > 0;
                return .{ .done = .{ .retry = .{ .message = try state.dupe(server.client.message()) } } };
            },
            error.OutOfMemory, error.Canceled => |e| return e,
            else => |e| return .{ .done = .{ .fail = @errorName(e) } },
        };
        if (!attempt_range) return .{ .exchange = sent };
        const status = sent.status();
        if (status == .range_not_satisfiable) {
            // The server will not go on from there: from the start.
            sent.deinit(io);
            try partial.restart(io);
            attempt_range = false;
            continue;
        }
        if (status == .partial_content) {
            const content_range = sent.header("content-range") orelse "";
            var want_buf: [32]u8 = undefined;
            const want = std.mem.print(&want_buf, "bytes {d}-", .{partial.from}) catch unreachable; // unreachable: a u64 is at most 20 digits, 27 bytes with the words around it
            if (!std.mem.startsWith(u8, content_range, want)) {
                sent.deinit(io);
                try partial.restart(io);
                attempt_range = false;
                continue;
            }
        } else if (status == .ok) {
            // The Range was passed over and the whole object came.
            try partial.restart(io);
        }
        return .{ .exchange = sent };
    }
}

fn attemptUpload(state: *Run, r: *Result, action: Action, verify: ?Action, authenticated: bool) Error!Attempt {
    const server = state.server;
    var scratch_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const href = try rewriteHref(state, scratch, action.href);
    const headers = action.headers(scratch) catch |err| switch (err) {
        error.InvalidHttpHeader => return .{ .fail = "the server's action has a header with a line break in it" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var sent: u64 = 0;
    const ex = server.client.send(state.io(), .{
        .method = .PUT,
        .url = href,
        .headers = headers,
        .body = .{ .object = .{ .store = server.store(), .pointer = .{ .oid = r.oid, .size = r.size } } },
        .authenticated = authenticated,
        .access_url = accessUrl(action.href, &r.oid),
        .on_bytes = .{ .context = state, .add = addBytes },
        .sent = &sent,
    }) catch |err| switch (err) {
        // Nothing answered, as for a download.
        error.ConnectionFailed, error.AuthenticationFailed, error.TooManyRedirects, error.ClientCertificateRejected, error.ClientCertificateSchemeUnsupported, error.ProxyRefused, error.ProxyAuthenticationRequired, error.ProxyAuthMethodUnsupported, error.ProxyHostUnreachable, error.ProxyAddressUnsupported, error.ProxyProtocolError, error.MalformedResponse => {
            // What went out of an attempt that failed is taken back off the
            // count, as git-lfs rewinds its meter.
            state.say(.{ .unsent = sent });
            return .{ .retry = .{ .message = try state.dupe(server.client.message()) } };
        },
        error.OutOfMemory, error.Canceled => |e| return e,
        else => |e| return .{ .fail = @errorName(e) },
    };
    const status = ex.status();
    ex.deinit(state.io());
    if (status.class() != .success) {
        state.say(.{ .unsent = sent });
        const why = try state.dupe(try scratch.print("HTTP {d} from {s}", .{ @backingInt(status), lfsapi.stripQuery(action.href) }));
        return switch (status) {
            .unprocessable_entity => .{ .fail = why },
            .too_many_requests => .{ .retry = .{ .message = why, .after_s = null } },
            else => .{ .retry = .{ .message = why } },
        };
    }
    const v = verify orelse return .ok;
    return verifyUpload(state, r, v, authenticated);
}

fn verifyUpload(state: *Run, r: *Result, action: Action, authenticated: bool) Error!Attempt {
    const server = state.server;
    var scratch_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const href = try rewriteHref(state, scratch, action.href);
    const headers = action.headers(scratch) catch |err| switch (err) {
        error.InvalidHttpHeader => return .{ .fail = "the server's verify action has a header with a line break in it" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const body = try scratch.print("{{\"oid\":\"{s}\",\"size\":{d}}}", .{ &r.oid, r.size });
    var last: []const u8 = "";
    var attempt: u32 = 0;
    while (attempt < state.limits.max_verifies) : (attempt += 1) {
        const ex = server.client.send(state.io(), .{
            .method = .POST,
            .url = href,
            .headers = headers,
            .body = .{ .bytes = body },
            .api = true,
            .authenticated = authenticated,
            .access_url = href,
        }) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            else => {
                last = server.client.message();
                continue;
            },
        };
        const status = ex.status();
        ex.deinit(state.io());
        if (status.class() == .success) return .ok;
        last = try scratch.print("verify: HTTP {d}", .{@backingInt(status)});
    }
    return .{ .fail = try state.dupe(last) };
}

fn addBytes(context: *anyopaque, n: u64) void {
    const state: *Run = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Run
    state.say(.{ .bytes = n });
}

/// A reader that counts what passes through it, for a download's progress.
const Counting = struct {
    inner: *Io.Reader,
    state: *Run,
    pending: u64 = 0,
    interface: Io.Reader,

    fn init(inner: *Io.Reader, state: *Run) Counting {
        return .{
            .inner = inner,
            .state = state,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const c: *Counting = @alignCast(@fieldParentPtr("interface", r)); // safe: this function is installed only on a Counting's interface
        const n = c.inner.stream(w, limit) catch |err| {
            c.flush();
            return err;
        };
        c.pending += n;
        // A report per quarter megabyte, so a large object moves the bar
        // without a report per packet.
        if (c.pending >= 256 * 1024) c.flush();
        return n;
    }

    fn flush(c: *Counting) void {
        if (c.pending == 0) return;
        c.state.say(.{ .bytes = c.pending });
        c.pending = 0;
    }
};

/// A batch's answer and the arena it lives in.
const Answered = struct {
    arena: std.heap.ArenaAllocator,
    response: BatchResponse,
};

/// Send one batch, waiting out a 429 as git-lfs does, and read the answer.
/// With `into`, the answer is allocated there; without, in an arena of its
/// own the caller releases.
fn batchRequest(
    io: Io,
    server: *lfsapi.Server,
    operation: lfsapi.Operation,
    objects: []const Object,
    ref: ?[]const u8,
    limits: Limits,
    comptime_into: anytype,
) Error!if (@TypeOf(comptime_into) == @TypeOf(null)) Answered else BatchResponse {
    const own = @TypeOf(comptime_into) == @TypeOf(null);
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    errdefer arena_state.deinit();
    const a = if (own) arena_state.allocator() else comptime_into;
    if (!own) arena_state.deinit();

    if (try server.client.sshTransfer(io, operation)) |t| {
        const response = try sshBatch(a, io, server, t, objects, ref);
        if (own) return .{ .arena = arena_state, .response = response };
        return response;
    }

    var body: Io.Writer.Allocating = .init(server.gpa);
    defer body.deinit();
    writeBatchRequestOffering(&body.writer, operation, objects, ref, limits.transfers) catch return error.OutOfMemory;

    var retries: u32 = 0;
    while (true) {
        const ex = server.client.api(io, .{ .operation = operation, .method = .POST, .suffix = "objects/batch", .body = body.written(), .network_retries = limits.max_retries }) catch |err| switch (err) {
            error.ConnectionFailed, error.HttpStatus, error.AuthenticationFailed, error.TooManyRedirects, error.InsecureRedirect => return error.LfsBatchFailed,
            else => |e| return e,
        };
        defer ex.deinit(io);
        const status = ex.status();
        if (status == .too_many_requests and retries < limits.max_retries) {
            retries += 1;
            var delay_ms = limits.backoffMs(retries);
            if (ex.retryAfter()) |seconds| {
                if (seconds > limits.max_retry_time_s) {
                    server.client.noteStatus(io, ex, "batch");
                    return error.LfsBatchFailed;
                }
                delay_ms = seconds * 1000;
            }
            if (delay_ms != 0) try io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
            continue;
        }
        if (status != .ok) {
            server.client.noteStatus(io, ex, "batch");
            return error.LfsBatchFailed;
        }
        const bytes = try ex.readAll(io, 64 << 20);
        const response = try parseBatch(a, bytes);
        if (own) return .{ .arena = arena_state, .response = response };
        return response;
    }
}

//=====================================================================
// git-lfs's pure-ssh protocol
//=====================================================================

/// A batch over the pure-ssh protocol, on the first connection, as
/// git-lfs asks it: `transfer=ssh`, `hash-algo=sha256` and the ref, then
/// `<oid> <size>` lines; the answer's lines are `<oid> <size> <action>`
/// with the action's `id`, `token` and expiry, `noop` for an object with
/// nothing to do.
fn sshBatch(a: Allocator, io: Io, server: *lfsapi.Server, t: *lfsssh.Transfer, objects: []const Object, ref: ?[]const u8) Error!BatchResponse {
    const conn = t.connection(io, 0) catch |err| return sshBatchFailed(io, server, err, t.message.items);
    try conn.mutex.lock(io);
    defer conn.mutex.unlock(io);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "transfer=ssh", "hash-algo=sha256" });
    if (ref) |r| try args.append(a, try a.print("refname={s}", .{r}));
    var lines: std.ArrayList([]const u8) = .empty;
    for (objects) |o| try lines.append(a, try a.print("{s} {d}", .{ &o.oid, o.size }));
    conn.sendLines("batch", args.items, lines.items) catch |err| return sshBatchFailed(io, server, err, "");
    const status = conn.readStatus(a) catch |err| return sshBatchFailed(io, server, err, "");
    if (status.code != 200) {
        var buf: [512]u8 = undefined;
        server.client.setMessage(io, std.mem.print(&buf, "batch response: status {d} from server ({s})", .{
            status.code,
            if (status.lines.len != 0) status.lines[0] else "no message provided",
        }) catch "batch response");
        return error.LfsBatchFailed;
    }
    if (status.arg("hash-algo")) |algo| {
        if (!std.mem.eql(u8, algo, "sha256")) return error.MalformedResponse;
    }
    return parseSshBatch(a, status.lines);
}

/// Errors from `parseSshBatch`.
pub const ParseSshBatchError = Allocator.Error || error{MalformedResponse};

/// Read the lines of a batch answer over ssh, sorted as git-lfs sorts
/// them: `<oid> <size> <action>` with `id=`, `token=`, `expires-in=` and
/// `expires-at=`, the lines for one object together, `noop` for one with
/// nothing to do. A line that is not that is `error.MalformedResponse`.
pub fn parseSshBatch(a: Allocator, lines: []const []const u8) ParseSshBatchError!BatchResponse {
    const sorted = try a.dupe([]const u8, lines);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var out: std.ArrayList(BatchObject) = .empty;
    for (sorted) |line| {
        var fields: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, line, ' ');
        while (it.next()) |f| try fields.append(a, f);
        if (fields.items.len < 3) return error.MalformedResponse;
        const oid = fields.items[0];
        const size = std.fmt.parseInt(u64, fields.items[1], 10) catch return error.MalformedResponse;
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].oid, oid)) {
            try out.append(a, .{ .oid = oid, .size = size, .actions = .{} });
        }
        const obj = &out.items[out.items.len - 1];
        obj.size = size;
        const name = fields.items[2];
        if (std.mem.eql(u8, name, "noop")) continue;
        var action: Action = .{ .href = "" };
        for (fields.items[3..]) |kv| {
            if (std.mem.startsWith(u8, kv, "id=")) {
                action.id = kv[3..];
            } else if (std.mem.startsWith(u8, kv, "token=")) {
                action.token = kv[6..];
            } else if (std.mem.startsWith(u8, kv, "expires-in=")) {
                action.expires_in = std.fmt.parseInt(i64, kv[11..], 10) catch return error.MalformedResponse;
            } else if (std.mem.startsWith(u8, kv, "expires-at=")) {
                if (timetext.parseRfc3339(kv[11..]) == null) return error.MalformedResponse;
                action.expires_at = kv[11..];
            }
        }
        if (std.mem.eql(u8, name, "download")) {
            obj.actions.?.download = action;
        } else if (std.mem.eql(u8, name, "upload")) {
            obj.actions.?.upload = action;
        } else if (std.mem.eql(u8, name, "verify")) {
            obj.actions.?.verify = action;
        }
    }
    return .{ .transfer = "ssh", .objects = out.items, .hash_algo = "sha256" };
}

fn sshBatchFailed(io: Io, server: *lfsapi.Server, err: lfsssh.Error, said: []const u8) Error {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {},
    }
    var buf: [512]u8 = undefined;
    server.client.setMessage(io, std.mem.print(&buf, "batch request: {s}{s}{s}", .{ @errorName(err), if (said.len != 0) ": " else "", said }) catch "batch request");
    return error.LfsBatchFailed;
}

/// `size=`, then `id=` and `token=` when the server gave them: what every
/// request for an object carries.
fn sshObjectArgs(a: Allocator, r: *const Result, action: Action) Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, try a.print("size={d}", .{r.size}));
    if (action.id) |v| if (v.len != 0) try args.append(a, try a.print("id={s}", .{v}));
    if (action.token) |v| if (v.len != 0) try args.append(a, try a.print("token={s}", .{v}));
    return args.items;
}

/// An attempt whose connection failed: tried again, as git-lfs's
/// retriable errors are.
fn sshRetry(state: *Run, err: anyerror) Error!Attempt {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {},
    }
    return .{ .retry = .{ .message = try state.dupe(@errorName(err)) } };
}

fn attemptDownloadSsh(state: *Run, t: *lfsssh.Transfer, worker: usize, r: *Result, action: Action) Error!Attempt {
    const io = state.io();
    var scratch_state: std.heap.ArenaAllocator = .init(state.server.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const conn = t.connection(io, worker) catch |err| return sshRetry(state, err);
    try conn.mutex.lock(io);
    defer conn.mutex.unlock(io);
    const command = try scratch.print("get-object {s}", .{&r.oid});
    conn.send(command, try sshObjectArgs(scratch, r, action)) catch |err| return sshRetry(state, err);
    const head = conn.readStatusWithData(scratch) catch |err| return sshRetry(state, err);
    if (head.code < 200 or head.code > 299) {
        var said: std.ArrayList(u8) = .empty;
        while (conn.nextData() catch |err| return sshRetry(state, err)) |bytes| {
            if (said.items.len < 1024) try said.appendSlice(scratch, bytes[0..@min(bytes.len, 1024 - said.items.len)]);
        }
        return .{ .retry = .{ .message = try state.dupe(try scratch.print("got status {d} when fetching OID {s}: {s}", .{ head.code, &r.oid, said.items })) } };
    }
    const size_text = lfsssh.argValue(head.args, "size") orelse {
        conn.skipData() catch |err| return sshRetry(state, err);
        return .{ .fail = "the server's answer gave no size" };
    };
    _ = std.fmt.parseInt(u64, size_text, 10) catch {
        conn.skipData() catch |err| return sshRetry(state, err);
        return .{ .fail = "the server's answer gave a size that is not one" };
    };
    var data: SshData = .init(conn);
    var counting: Counting = .init(&data.interface, state);
    const pointer: lfs.Pointer = .{ .oid = r.oid, .size = r.size };
    const installed = state.server.store().install(io, &counting.interface, &pointer);
    counting.flush();
    if (data.failed) |err| return sshRetry(state, err);
    if (!data.done) conn.skipData() catch |err| return sshRetry(state, err);
    _ = installed catch |err| switch (err) {
        error.LfsObjectMismatch => return .{ .fail = "the bytes the server sent are not the object" },
        error.ReadFailed => return .{ .retry = .{ .message = "the download broke off" } },
        else => |e| return e,
    };
    return .ok;
}

fn attemptUploadSsh(state: *Run, t: *lfsssh.Transfer, worker: usize, r: *Result, action: Action) Error!Attempt {
    const io = state.io();
    var scratch_state: std.heap.ArenaAllocator = .init(state.server.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const store = state.server.store();
    const pointer: lfs.Pointer = .{ .oid = r.oid, .size = r.size };
    const file = (try store.open(io, &pointer)) orelse return .{ .fail = "the object is not in the store" };
    defer file.close(io);
    const conn = t.connection(io, worker) catch |err| return sshRetry(state, err);
    try conn.mutex.lock(io);
    defer conn.mutex.unlock(io);
    const args = try sshObjectArgs(scratch, r, action);
    var sent: u64 = 0;
    const put = try scratch.print("put-object {s}", .{&r.oid});
    {
        conn.beginData(put, args) catch |err| return sshRetry(state, err);
        var chunk: [32 * 1024]u8 = undefined;
        var fr = file.reader(io, &.{});
        var left = r.size;
        while (left > 0) {
            const want: usize = @intCast(@min(left, chunk.len));
            const n = fr.interface.readSliceShort(chunk[0..want]) catch return .{ .fail = "upload: reading the object" };
            if (n == 0) return .{ .fail = "upload: the object is shorter than its pointer" };
            conn.writeData(chunk[0..n]) catch |err| {
                state.say(.{ .unsent = sent });
                return sshRetry(state, err);
            };
            left -= n;
            sent += n;
            state.say(.{ .bytes = n });
        }
        conn.endData() catch |err| {
            state.say(.{ .unsent = sent });
            return sshRetry(state, err);
        };
    }
    const status = conn.readStatus(scratch) catch |err| {
        state.say(.{ .unsent = sent });
        return sshRetry(state, err);
    };
    if (!status.ok()) {
        state.say(.{ .unsent = sent });
        // A 403 is likely a token that expired, and a 429 a server that
        // asks for a pause: both are tried again, as git-lfs tries them.
        const why = try state.dupe(try scratch.print("got status {d} when uploading OID {s}{s}{s}", .{
            status.code,
            &r.oid,
            if (status.lines.len != 0) ": " else "",
            if (status.lines.len != 0) status.lines[0] else "",
        }));
        if (status.code == 403 or status.code == 429) return .{ .retry = .{ .message = why } };
        return .{ .fail = why };
    }
    // git-lfs verifies every upload over ssh, with the upload's own
    // arguments.
    const verify = try scratch.print("verify-object {s}", .{&r.oid});
    conn.send(verify, args) catch |err| return sshRetry(state, err);
    const verified = conn.readStatus(scratch) catch |err| return sshRetry(state, err);
    if (!verified.ok()) {
        return .{ .fail = try state.dupe(try scratch.print("got status {d} when verifying upload OID {s}{s}{s}", .{
            verified.code,
            &r.oid,
            if (verified.lines.len != 0) ": " else "",
            if (verified.lines.len != 0) verified.lines[0] else "",
        })) };
    }
    return .ok;
}

/// The data of a `get-object` answer, as a reader, to its flush.
const SshData = struct {
    conn: *lfsssh.Connection,
    pending: []const u8 = &.{},
    done: bool = false,
    failed: ?lfsssh.Error = null,
    interface: Io.Reader,

    fn init(conn: *lfsssh.Connection) SshData {
        return .{
            .conn = conn,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const d: *SshData = @alignCast(@fieldParentPtr("interface", r)); // safe: this function is installed only on a SshData's interface
        while (d.pending.len == 0) {
            if (d.done) return error.EndOfStream;
            const next = d.conn.nextData() catch |err| {
                d.failed = err;
                return error.ReadFailed;
            };
            if (next) |bytes| d.pending = bytes else {
                d.done = true;
                return error.EndOfStream;
            }
        }
        const n = try w.write(d.pending[0..limit.minInt(d.pending.len)]);
        d.pending = d.pending[n..];
        return n;
    }
};

//=====================================================================
// A remote on this machine
//=====================================================================

/// Copy objects between this store and the store of the repository a
/// `file://` endpoint names.
fn copyLocal(
    io: Io,
    server: *lfsapi.Server,
    endpoint: lfsapi.Endpoint,
    operation: lfsapi.Operation,
    outcome: *Outcome,
    pending: []const usize,
    missing_here: []const bool,
    limits: Limits,
    options: Options,
) Error!void {
    const gpa = server.gpa;
    const path = endpoint.localPath().?;
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return error.LfsLocalRemoteUnreadable;
    defer dir.close(io);
    var remote = Repository.open(gpa, io, dir, .{ .discover = false }) catch return error.LfsLocalRemoteUnreadable;
    defer remote.deinit(io);
    var remote_lfs = lfs.Lfs.load(gpa, io, remote.configuration(), .{
        .common_dir = remote.commonDirectory(),
        .work_dir = null,
    }) catch return error.LfsLocalRemoteUnreadable;
    defer remote_lfs.deinit();
    const here = server.store();
    const there = &remote_lfs.store;
    const from = if (operation == .download) there else here;
    const to = if (operation == .download) here else there;

    var total_bytes: u64 = 0;
    for (pending) |i| total_bytes += outcome.results[i].size;
    var done_bytes: u64 = 0;
    var done: u64 = 0;
    for (pending) |i| {
        const r = &outcome.results[i];
        const pointer: lfs.Pointer = .{ .oid = r.oid, .size = r.size };
        if (operation == .upload and try to.contains(io, &pointer)) {
            r.status = .present;
            continue;
        }
        if (operation == .upload and missing_here[i]) {
            r.status = if (limits.allow_incomplete_push) .present else .missing;
            r.message = "the object is not in the store, and the remote does not have it";
            continue;
        }
        const file = (try from.open(io, &pointer)) orelse {
            r.status = .refused;
            r.message = "the remote does not have the object";
            continue;
        };
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(io, &buf);
        _ = to.install(io, &fr.interface, &pointer) catch |err| switch (err) {
            error.LfsObjectMismatch => {
                r.status = .failed;
                r.message = "the remote's copy is not the object";
                continue;
            },
            error.ReadFailed => return fr.err.?,
            else => |e| return e,
        };
        r.status = .transferred;
        done += 1;
        done_bytes += r.size;
        progress_mod.Progress.emit(options.progress, .{ .lfs_bytes = .{ .done = done_bytes, .total = total_bytes } });
        progress_mod.Progress.emit(options.progress, .{ .lfs_objects = .{ .done = done, .total = pending.len } });
    }
}

//=====================================================================
// What checkout, fetch, pull and push call
//=====================================================================

/// What checkout hands its missing objects to: `lfs.Fetcher` over a server.
///
/// An object that does not come fails the checkout with
/// `error.LfsFetchFailed`, as git-lfs's smudge filter fails it, unless
/// download errors are skipped: then it is left as its pointer and the
/// checkout goes on.
pub const Fetcher = struct {
    pub const Error = ErrorNamespace.Error;

    server: *lfsapi.Server,
    options: Options = .{},
    /// Leave an object that did not come as its pointer. `null` asks
    /// `GIT_LFS_SKIP_DOWNLOAD_ERRORS` in the environment the server's
    /// programs run with, then `lfs.skipdownloaderrors`, as git-lfs does.
    skip_download_errors: ?bool = null,
    /// The last fetch's outcome, kept until the fetcher is deinitialised,
    /// so a caller can say which objects did not come and why.
    last: ?Outcome = null,

    /// The `lfs.Fetcher` checkout is handed.
    pub fn fetcher(f: *Fetcher) lfs.Fetcher {
        return .{ .context = f, .fetchFn = fetchFn };
    }

    /// Release the last outcome.
    pub fn deinit(f: *Fetcher) void {
        if (f.last) |*o| o.deinit();
        f.* = undefined;
    }

    fn fetchFn(io: Io, context: *anyopaque, store: *const lfs.Store, settings: *const lfs.Settings, wanted: []const lfs.Wanted) lfs.FetchError!void {
        _ = store;
        _ = settings;
        const f: *Fetcher = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Fetcher
        var objects: std.ArrayList(Object) = .empty;
        defer objects.deinit(f.server.gpa);
        for (wanted) |w| objects.append(f.server.gpa, .of(w.pointer, w.path)) catch return error.OutOfMemory;
        const outcome = download(io, f.server, objects.items, f.options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.LfsFetchFailed,
        };
        if (f.last) |*o| o.deinit();
        f.last = outcome;
        if (outcome.failures() != 0 and !f.skipDownloadErrors()) return error.LfsFetchFailed;
    }

    fn skipDownloadErrors(f: *const Fetcher) bool {
        if (f.skip_download_errors) |skip| return skip;
        if (f.server.client.options.programs) |programs| {
            if (lfsapi.gitLfsBool(programs.environ.get("GIT_LFS_SKIP_DOWNLOAD_ERRORS"), false)) return true;
        }
        var buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        // A value too long to be a boolean is not one.
        const value = f.server.settings.get(fba.allocator(), "lfs.skipdownloaderrors") catch return false;
        return lfsapi.gitLfsBool(value, false);
    }
};

/// How `fetch` chooses what to bring.
pub const FetchOptions = struct {
    /// The commits whose trees are read: ref names as git abbreviates
    /// them, `HEAD`, or object names.
    refs: []const []const u8 = &.{"HEAD"},
    /// Every commit reachable from `refs`, not only their tips: `git lfs
    /// fetch --all` for the refs given.
    history: bool = false,
    /// Commits the history walk stops at: with `history`, the objects of
    /// `exclude..refs`, a range.
    exclude: []const []const u8 = &.{},
    /// Leave `lfs.fetchinclude` and `lfs.fetchexclude` out of it, as
    /// `git lfs fetch --all` does.
    all_paths: bool = false,
    /// `git lfs fetch --recent`: also the tips of the refs with a commit in
    /// the last `lfs.fetchrecentrefsdays` days — the remote's branches too
    /// unless `lfs.fetchrecentremoterefs` is false — and the versions of
    /// files the commits of the `lfs.fetchrecentcommitsdays` days before
    /// each tip replaced. `null` takes `lfs.fetchrecentalways`.
    recent: ?bool = null,
    /// Now, in seconds since 1970, which the recent refs' days are counted
    /// back from. relic reads no clock, so a recent fetch that looks at
    /// refs needs the caller's.
    now: ?i64 = null,
    transfer: Options = .{},
};

/// Errors from `fetch` and `pull`.
pub const FetchError = Error || objectwalk.Error || repo_mod.Error || error{
    /// A name in `refs` or `exclude` that names nothing here.
    RefNotFound,
    /// A recent fetch counts `lfs.fetchrecentrefsdays` back from now, and
    /// `FetchOptions.now` was not given.
    LfsRecentNeedsTime,
    /// A tree nests deeper than `object.max_tree_depth`.
    TreeTooDeep,
} || revwalk.Error || diff_mod.Error || index_mod.ReadError || index_mod.WriteError || fs.AtomicWriteError || fs.StatError;

/// Bring the LFS objects the trees at `options.refs` point at into the
/// store, as `git lfs fetch <remote> <refs>` does. A path
/// `lfs.fetchinclude` leaves out, or `lfs.fetchexclude` names, is not
/// fetched unless `all_paths` says so.
pub fn fetch(io: Io, server: *lfsapi.Server, repo: *Repository, options: FetchOptions) transfer.FetchError!Outcome {
    const gpa = server.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tips: std.ArrayList(Oid) = .empty;
    var pointers: std.ArrayList(Object) = .empty;
    try pointers.appendSlice(arena, try scan(arena, io, repo, options, &tips));
    const recent = options.recent orelse server.settings.getBool("lfs.fetchrecentalways", false);
    if (recent and !options.history) {
        try pointers.appendSlice(arena, try recentPointers(arena, io, server, repo, tips.items, options.now orelse server.client.options.now));
    }
    var objects: std.ArrayList(Object) = .empty;
    for (pointers.items) |p| {
        if (!options.all_paths and !server.lfs.settings.fetchAllowed(p.name)) continue;
        try objects.append(arena, p);
    }
    return download(io, server, objects.items, options.transfer);
}

/// What `git lfs fetch --recent` adds: the tips of the recent refs, and the
/// versions the recent commits before each tip replaced.
fn recentPointers(arena: Allocator, io: Io, server: *lfsapi.Server, repo: *Repository, tips: []const Oid, now: ?i64) FetchError![]Object {
    const settings = &server.settings;
    const refs_days = settings.getInt("lfs.fetchrecentrefsdays", 7);
    const commits_days = settings.getInt("lfs.fetchrecentcommitsdays", 0);
    const remote_refs = settings.getBool("lfs.fetchrecentremoterefs", true);
    var out: std.ArrayList(Object) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var unique: std.ArrayList(Oid) = .empty;
    for (tips) |t| {
        if (!containsOid(unique.items, t)) try unique.append(arena, t);
    }

    if (refs_days > 0) {
        const since = (now orelse return error.LfsRecentNeedsTime) - refs_days * 86400;
        var listing = try repo.refStore().list(server.gpa, io, "refs/");
        defer listing.deinit();
        const remote_prefix = try arena.print("refs/remotes/{s}/", .{server.remote});
        for (listing.entries) |entry| {
            // git-lfs's pattern takes `refs/<kind>/<name>`: a branch, a
            // tag, a remote's branch.
            if (std.mem.count(u8, entry.name, "/") < 2) continue;
            if (std.mem.startsWith(u8, entry.name, "refs/remotes/")) {
                if (!remote_refs or !std.mem.startsWith(u8, entry.name, remote_prefix)) continue;
            }
            const resolved = (try repo.refStore().resolve(arena, io, entry.name)) orelse continue;
            const when = commitTime(arena, io, repo, resolved.oid) orelse continue;
            if (when < since) continue;
            if (containsOid(unique.items, resolved.oid)) continue;
            try unique.append(arena, resolved.oid);
            const found = try repo.objectDatabase().read(io, resolved.oid);
            defer repo.objectDatabase().allocator().free(found.bytes);
            var commit = try object_mod.Commit.parse(arena, repo.objectFormat(), found.bytes);
            defer commit.deinit();
            try scanTree(arena, io, repo, commit.tree, "", &out, &seen, 0);
        }
    }

    if (commits_days > 0) {
        for (unique.items) |tip| {
            const tip_time = commitTime(arena, io, repo, tip) orelse continue;
            const since = tip_time - commits_days * 86400;
            var walk = revwalk.Walk.init(server.gpa, repo.objectDatabase());
            defer walk.deinit();
            try walk.push(tip);
            while (try walk.next(io)) |c| {
                if (c.time < since) continue;
                // git log -p shows no diff for a merge, and a root commit
                // replaced nothing.
                if (c.parents.len != 1) continue;
                const old_tree = try treeOfCommit(arena, io, repo, c.parents[0]);
                const new_tree = try treeOfCommit(arena, io, repo, c.oid);
                var changes = try diff_mod.tree(server.gpa, io, repo.objectDatabase(), old_tree, new_tree, .{});
                defer changes.deinit();
                for (changes.items) |change| {
                    const old = change.old orelse continue;
                    if (old.mode != .file and old.mode != .exec) continue;
                    const header = try repo.objectDatabase().readHeader(io, old.oid);
                    try addPointer(arena, io, repo, old.oid, header.size, try arena.dupe(u8, old.path), &out, &seen);
                }
            }
        }
    }
    return out.items;
}

fn containsOid(list: []const Oid, oid: Oid) bool {
    for (list) |o| {
        if (o.eql(oid)) return true;
    }
    return false;
}

/// The committer time of `oid` when it is a commit.
fn commitTime(arena: Allocator, io: Io, repo: *Repository, oid: Oid) ?i64 {
    const found = repo.objectDatabase().read(io, oid) catch return null;
    defer repo.objectDatabase().allocator().free(found.bytes);
    if (found.type != .commit) return null;
    var commit = object_mod.Commit.parse(arena, repo.objectFormat(), found.bytes) catch return null;
    defer commit.deinit();
    return commit.committer.when_secs;
}

fn treeOfCommit(arena: Allocator, io: Io, repo: *Repository, oid: Oid) FetchError!Oid {
    const found = try repo.objectDatabase().read(io, oid);
    defer repo.objectDatabase().allocator().free(found.bytes);
    var commit = try object_mod.Commit.parse(arena, repo.objectFormat(), found.bytes);
    defer commit.deinit();
    return commit.tree;
}

/// The pointers in the trees `options` asks for, each with a path it is at.
fn scan(arena: Allocator, io: Io, repo: *Repository, options: FetchOptions, tips_out: *std.ArrayList(Oid)) FetchError![]Object {
    const tips = tips_out;
    for (options.refs) |name| {
        const found = try resolve(arena, io, repo, name);
        try tips.append(arena, try repo.peel(io, found.oid));
    }
    var out: std.ArrayList(Object) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    if (options.history) {
        var exclude: std.ArrayList(Oid) = .empty;
        for (options.exclude) |name| try exclude.append(arena, (try resolve(arena, io, repo, name)).oid);
        var collected = try objectwalk.missing(arena, io, repo.objectDatabase(), tips.items, .{ .exclude = exclude.items });
        defer collected.deinit();
        for (collected.entries) |e| {
            if (e.hint.len == 0) continue;
            const header = try repo.objectDatabase().readHeader(io, e.oid);
            if (header.type != .blob) continue;
            try addPointer(arena, io, repo, e.oid, header.size, e.hint, &out, &seen);
        }
        return out.items;
    }
    for (tips.items) |tip| {
        const found = try repo.objectDatabase().read(io, tip);
        defer repo.objectDatabase().allocator().free(found.bytes);
        const tree = switch (found.type) {
            .commit => blk: {
                var commit = try object_mod.Commit.parse(arena, repo.objectFormat(), found.bytes);
                defer commit.deinit();
                break :blk commit.tree;
            },
            .tree => tip,
            else => continue,
        };
        try scanTree(arena, io, repo, tree, "", &out, &seen, 0);
    }
    return out.items;
}

fn scanTree(arena: Allocator, io: Io, repo: *Repository, tree: Oid, prefix: []const u8, out: *std.ArrayList(Object), seen: *std.StringHashMapUnmanaged(void), depth: u32) FetchError!void {
    if (depth > object_mod.max_tree_depth) return error.TreeTooDeep;
    const found = try repo.objectDatabase().read(io, tree);
    defer repo.objectDatabase().allocator().free(found.bytes);
    var entries = object_mod.Tree.parse(repo.objectFormat(), found.bytes).iterate();
    while (try entries.next()) |entry| {
        const path = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try arena.print("{s}/{s}", .{ prefix, entry.name });
        switch (entry.mode) {
            .tree => try scanTree(arena, io, repo, entry.oid, path, out, seen, depth + 1),
            .file, .exec => {
                const header = try repo.objectDatabase().readHeader(io, entry.oid);
                try addPointer(arena, io, repo, entry.oid, header.size, path, out, seen);
            },
            else => {},
        }
    }
}

fn addPointer(arena: Allocator, io: Io, repo: *Repository, oid: Oid, size: u64, path: []const u8, out: *std.ArrayList(Object), seen: *std.StringHashMapUnmanaged(void)) FetchError!void {
    // git-lfs's scanners look at a blob only when it is short enough to be
    // a pointer.
    if (size >= lfs.pointer_size_cutoff or size == 0) return;
    const found = try repo.objectDatabase().read(io, oid);
    defer repo.objectDatabase().allocator().free(found.bytes);
    const pointer = lfs.Pointer.decode(found.bytes) catch return;
    if (pointer.size == 0 or pointer.extension_count != 0) return;
    const key = try arena.dupe(u8, &pointer.oid);
    const gop = try seen.getOrPut(arena, key);
    if (gop.found_existing) return;
    try out.append(arena, .of(pointer, path));
}

const Resolved = struct { oid: Oid, ref: ?[]const u8 };

/// A name as git's rev-parse reads a ref: `HEAD`, a full ref, a short one
/// by git's rules, or an object name.
fn resolve(arena: Allocator, io: Io, repo: *Repository, name: []const u8) FetchError!Resolved {
    const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
    inline for (rules) |rule| {
        const full = try arena.print(rule, .{name});
        if (try repo.refStore().resolve(arena, io, full)) |found| return .{ .oid = found.oid, .ref = found.name };
    }
    if (name.len == repo.objectFormat().hexLen()) {
        if (Oid.parse(repo.objectFormat(), name)) |oid| {
            if (try repo.objectDatabase().exists(io, oid)) return .{ .oid = oid, .ref = null };
        } else |_| {}
    }
    return error.RefNotFound;
}

/// What `pull` did.
pub const PullOutcome = struct {
    pub const Error = ErrorNamespace.Error;

    fetched: Outcome,
    /// Pointer files in the working tree replaced by their content.
    replaced: u32 = 0,
    /// Pointer files left as they are, because the object is still not in
    /// the store.
    left: u32 = 0,

    /// Release everything.
    pub fn deinit(p: *PullOutcome) void {
        p.fetched.deinit();
        p.* = undefined;
    }
};

/// `git lfs pull`: fetch the objects of `HEAD` — or of `options.refs` —
/// and put their content in place of every pointer in the working tree
/// whose object is now in the store. A file that is not its pointer any
/// more is somebody's work and is left alone.
pub fn pull(io: Io, server: *lfsapi.Server, repo: *Repository, options: FetchOptions) transfer.FetchError!PullOutcome {
    var fetched = try fetch(io, server, repo, options);
    errdefer fetched.deinit();
    var out: PullOutcome = .{ .fetched = fetched };
    const counts = try checkoutPointers(server.gpa, io, repo, server.store());
    out.replaced = counts.replaced;
    out.left = counts.left;
    return out;
}

/// `git lfs checkout`: every file in the working tree that is still the
/// pointer its index entry names is replaced by the object, when the store
/// has it, and its index entry is refreshed so git and relic both call it
/// clean.
pub fn checkoutPointers(gpa: Allocator, io: Io, repo: *Repository, store: *const lfs.Store) transfer.FetchError!struct { replaced: u32, left: u32 } {
    const wt = repo.workDirectory() orelse return .{ .replaced = 0, .left = 0 };
    var index = try repo.openIndex(io);
    defer index.deinit();
    var replaced: u32 = 0;
    var left: u32 = 0;
    for (index.entries.items) |*entry| {
        if (entry.stage != 0 or entry.skip_worktree) continue;
        if (entry.mode != .file and entry.mode != .exec) continue;
        const header = repo.objectDatabase().readHeader(io, entry.oid) catch continue;
        if (header.size >= lfs.pointer_size_cutoff or header.size == 0) continue;
        const found = try repo.objectDatabase().read(io, entry.oid);
        defer repo.objectDatabase().allocator().free(found.bytes);
        const pointer = lfs.Pointer.decode(found.bytes) catch continue;
        if (pointer.size == 0 or pointer.extension_count != 0) continue;
        // Only a file that is still exactly its pointer is replaced.
        const disk = (try fs.statAt(io, wt, entry.path)) orelse continue;
        if (disk.kind != .file or disk.stat.size >= lfs.pointer_size_cutoff) continue;
        // The index keeps a size modulo 2^32, so the read is bounded too.
        const on_disk = (fs.readFileAlloc(gpa, io, wt, entry.path, lfs.pointer_size_cutoff) catch |err| switch (err) {
            error.StreamTooLong => continue,
            else => |e| return e,
        }) orelse continue;
        defer gpa.free(on_disk);
        if (!std.mem.eql(u8, on_disk, found.bytes)) {
            var canonical_buf: [lfs.Pointer.max_encoded_len]u8 = undefined;
            if (!std.mem.eql(u8, on_disk, pointer.encodeBuf(&canonical_buf))) continue;
        }
        const file = (try store.open(io, &pointer)) orelse {
            left += 1;
            continue;
        };
        defer file.close(io);
        try replaceWith(io, wt, entry.path, file, entry.mode == .exec);
        if (try fs.statAt(io, wt, entry.path)) |after| entry.stat = after.stat;
        replaced += 1;
    }
    if (replaced != 0) try repo.writeIndex(io, &index);
    return .{ .replaced = replaced, .left = left };
}

fn replaceWith(io: Io, wt: Io.Dir, path: []const u8, source: Io.File, executable: bool) FetchError!void {
    var name_buf: [64]u8 = undefined;
    const temp_name = fs.tempName(io, &name_buf, ".relic-lfs-");
    const dir_path = std.Io.Dir.path.dirnamePosix(path);
    var temp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temp_path = if (dir_path) |d|
        std.mem.print(&temp_path_buf, "{s}/{s}", .{ d, temp_name }) catch return error.NameTooLong
    else
        temp_name;
    const out = try wt.createFile(io, temp_path, .{ .exclusive = true, .permissions = fs.permissionsFor(executable) });
    var done = false;
    defer if (!done) wt.deleteFile(io, temp_path) catch {};
    {
        defer out.close(io);
        var write_buf: [64 * 1024]u8 = undefined;
        var fw = out.writer(io, &write_buf);
        var read_buf: [64 * 1024]u8 = undefined;
        var fr = source.reader(io, &read_buf);
        _ = fr.interface.streamRemaining(&fw.interface) catch |err| switch (err) {
            error.ReadFailed => return fr.err.?,
            error.WriteFailed => return fw.err.?,
        };
        fw.interface.flush() catch return fw.err.?;
    }
    try fs.renameWithRetry(io, wt, temp_path, path);
    done = true;
}

/// Upload the LFS objects among `pushed` — the objects a push is about to
/// send, each with the path it was found at — that the server does not
/// have, as git-lfs's pre-push hook uploads them. A blob that is not a
/// pointer is not looked at twice.
pub fn pushObjects(io: Io, server: *lfsapi.Server, db: *odb_mod.Odb, pushed: []const odb_mod.PackEntry, options: Options) transfer.FetchError!Outcome {
    const gpa = server.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var objects: std.ArrayList(Object) = .empty;
    for (pushed) |e| {
        if (e.hint.len == 0) continue;
        const header = try db.readHeader(io, e.oid);
        if (header.type != .blob or header.size >= lfs.pointer_size_cutoff or header.size == 0) continue;
        const found = try db.read(io, e.oid);
        defer db.allocator().free(found.bytes);
        const pointer = lfs.Pointer.decode(found.bytes) catch continue;
        if (pointer.size == 0 or pointer.extension_count != 0) continue;
        try objects.append(arena, .of(pointer, e.hint));
    }
    return upload(io, server, objects.items, options);
}

const testing = std.testing;

test "a batch answer is read as git-lfs reads it, legacy links and errors included" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const oid = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03";
    const answer = try parseBatch(a, "{\"transfer\":\"basic\",\"objects\":[" ++
        "{\"oid\":\"" ++ oid ++ "\",\"size\":6,\"authenticated\":true,\"actions\":{\"download\":{\"href\":\"https://x/o\",\"header\":{\"A\":\"b\"},\"expires_in\":60}},\"extra\":1}," ++
        "{\"oid\":\"" ++ oid ++ "\",\"size\":6,\"_links\":{\"upload\":{\"href\":\"https://x/u\"},\"verify\":{\"href\":\"https://x/v\"}}}," ++
        "{\"oid\":\"" ++ oid ++ "\",\"size\":6,\"error\":{\"code\":404,\"message\":\"Object does not exist\"}}" ++
        "],\"hash_algo\":\"sha256\"}");
    try testing.expectEqual(@as(usize, 3), answer.objects.len);
    try testing.expect(answer.objects[0].authenticated);
    const d = answer.objects[0].action(.download).?;
    try testing.expectEqualStrings("https://x/o", d.href);
    try testing.expectEqualStrings("b", (try d.headers(a))[0].value);
    try testing.expectEqualStrings("https://x/u", answer.objects[1].action(.upload).?.href);
    try testing.expectEqualStrings("https://x/v", answer.objects[1].action(.verify).?.href);
    try testing.expectEqual(@as(i64, 404), answer.objects[2].@"error".?.code);

    try testing.expectError(error.MalformedResponse, parseBatch(a, "{\"objects\":[],\"hash_algo\":\"sha512\"}"));
    try testing.expectError(error.MalformedResponse, parseBatch(a, "{\"objects\":[{\"oid\":\"../../etc/passwd\",\"size\":1}]}"));
    try testing.expectError(error.MalformedResponse, parseBatch(a, "["));
}

test "a batch request is written as git-lfs writes one" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const oid = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03";
    try writeBatchRequest(&out.writer, .download, &.{.{ .oid = oid.*, .size = 6 }}, "refs/heads/main");
    try testing.expectEqualStrings("{\"operation\":\"download\",\"objects\":[{\"oid\":\"" ++ oid ++ "\",\"size\":6}],\"ref\":{\"name\":\"refs/heads/main\"},\"hash_algo\":\"sha256\"}", out.written());
}

test "the backoff is git-lfs's: a quarter second, doubling, capped" {
    const l: Limits = .{ .batch_size = 100, .max_retries = 8, .max_retry_delay_s = 10, .max_retry_time_s = 300, .max_verifies = 3, .concurrency = 8, .allow_incomplete_push = false };
    try testing.expectEqual(@as(u64, 250), l.backoffMs(1));
    try testing.expectEqual(@as(u64, 500), l.backoffMs(2));
    try testing.expectEqual(@as(u64, 8000), l.backoffMs(6));
    try testing.expectEqual(@as(u64, 10000), l.backoffMs(7));
    try testing.expectEqual(@as(u64, 10000), l.backoffMs(40));
}

test "fuzz: any batch answer is read or refused by name" {
    try testing.fuzz({}, fuzzBatch, .{});
}

fn fuzzBatch(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [1024]u8 = undefined;
    const n = smith.slice(&scratch);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const answer = parseBatch(a, scratch[0..n]) catch |err| switch (err) {
        error.MalformedResponse => return,
        else => return err,
    };
    for (answer.objects) |*o| {
        try testing.expect(isOid(o.oid));
        inline for (.{ Rel.download, Rel.upload, Rel.verify }) |rel| {
            if (o.action(rel)) |act| _ = act.headers(a) catch |err| switch (err) {
                error.InvalidHttpHeader => {},
                else => return err,
            };
        }
    }
}

test "fuzz: any lines of an ssh batch answer are read or refused by name" {
    try testing.fuzz({}, fuzzSshBatch, .{});
}

fn fuzzSshBatch(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [512]u8 = undefined;
    const len = smith.slice(&scratch);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, scratch[0..len], '\n');
    while (it.next()) |line| try lines.append(a, line);
    _ = parseSshBatch(a, lines.items) catch |err| switch (err) {
        error.MalformedResponse => return,
        else => return err,
    };
}

test "an ssh batch answer's lines become the objects and actions git-lfs reads from them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const b = &@as([64]u8, @splat('b'));
    const c = &@as([64]u8, @splat('c'));
    const got = try parseSshBatch(a, &.{
        c ++ " 3 noop",
        b ++ " 5 download id=x token=y expires-in=60",
        b ++ " 5 verify",
    });
    try testing.expectEqual(@as(usize, 2), got.objects.len);
    try testing.expectEqualStrings(b, got.objects[0].oid);
    const dl = got.objects[0].action(.download).?;
    try testing.expectEqualStrings("x", dl.id.?);
    try testing.expectEqualStrings("y", dl.token.?);
    try testing.expectEqual(@as(?i64, 60), dl.expires_in);
    try testing.expect(got.objects[0].action(.verify) != null);
    try testing.expect(got.objects[1].action(.download) == null);
    try testing.expectError(error.MalformedResponse, parseSshBatch(a, &.{"short line"}));
    try testing.expectError(error.MalformedResponse, parseSshBatch(a, &.{b ++ " x download"}));
    try testing.expectError(error.MalformedResponse, parseSshBatch(a, &.{b ++ " 1 download expires-at=soon"}));
}

test "LFS URL rewriting preserves allocation resource failures" {
    var config = try config_mod.Config.parseText(testing.allocator, "[lfs.transfer]\nenablehrefrewrite = true\n[url \"https://new/\"]\ninsteadOf = https://old/\npushInsteadOf = https://old/\n", .local);
    defer config.deinit();
    var server: lfsapi.Server = undefined;
    server.settings = .{ .gpa = testing.allocator, .config = &config };
    var state: Run = undefined;
    state.server = &server;
    inline for (.{ lfsapi.Operation.download, lfsapi.Operation.upload }) |op| {
        state.operation = op;
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(error.OutOfMemory, rewriteHref(&state, failing.allocator(), "https://old/object"));
    }
}
