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

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

const hash = @import("hash.zig");
const object_mod = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const repo_mod = @import("repo.zig");
const fs = @import("fs.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("lfsapi.zig");
const objectwalk = @import("objectwalk.zig");
const progress_mod = @import("progress.zig");

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
    /// The server chose a transfer adapter other than `basic`, which is
    /// the only one relic offers.
    LfsTransferUnsupported,
} || lfsapi.Error || lfs.Store.InstallError || lfs.Store.OpenError || Io.ConcurrentError ||
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
    arena: std.heap.ArenaAllocator,
    results: []Result,

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
    /// When the action stops working, as RFC 3339 text. relic reads no
    /// clock; a refused action is retried with a fresh batch instead.
    expires_at: ?[]const u8 = null,
    expires_in: ?i64 = null,

    /// The action's headers, checked.
    pub fn headers(a: Action, arena: Allocator) (Allocator.Error || error{InvalidHttpHeader})![]const http.Header {
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

/// Read a batch answer. Every string is allocated in `arena`. An answer that
/// does not parse, whose objects are not named by a SHA-256, or that names
/// another hash algorithm, is `error.MalformedResponse`.
pub fn parseBatch(arena: Allocator, bytes: []const u8) (Allocator.Error || error{MalformedResponse})!BatchResponse {
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
pub fn download(server: *lfsapi.Server, objects: []const Object, options: Options) Error!Outcome {
    return run(server, .download, objects, options);
}

/// Upload `objects` from the repository's store. An object the server
/// already has is not sent.
pub fn upload(server: *lfsapi.Server, objects: []const Object, options: Options) Error!Outcome {
    return run(server, .upload, objects, options);
}

/// One object's transfer, for a worker.
const Job = struct {
    result: *Result,
    action: Action,
    verify: ?Action,
    authenticated: bool,
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
    server: *lfsapi.Server,
    operation: lfsapi.Operation,
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
        return r.server.io;
    }

    fn setFatal(r: *Run, err: Error) void {
        r.fatal_mutex.lockUncancelable(r.io());
        defer r.fatal_mutex.unlock(r.io());
        if (r.fatal == null) r.fatal = err;
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
            const close = std.mem.lastIndexOfScalar(u8, line, '"').?;
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
        const parent = std.fs.path.dirname(line) orelse continue;
        const dir = if (std.fs.path.isAbsolute(parent))
            try std.fmt.allocPrint(arena, "{s}/lfs/objects", .{parent})
        else
            try std.fmt.allocPrint(arena, "objects/{s}/lfs/objects", .{parent});
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
        const ref_path = std.fmt.bufPrint(&ref_buf, "{s}/{s}/{s}/{s}", .{ dir, pointer.oid[0..2], pointer.oid[2..4], &pointer.oid }) catch continue;
        const stat = store.base.statFile(io, ref_path, .{}) catch continue;
        if (stat.kind != .file or stat.size != pointer.size) continue;
        try store.base.createDirPath(io, std.fs.path.dirnamePosix(object_path).?);
        if (store.base.hardLink(ref_path, store.base, object_path, io, .{})) {
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

fn run(server: *lfsapi.Server, operation: lfsapi.Operation, objects: []const Object, options: Options) Error!Outcome {
    const gpa = server.gpa;
    const io = server.io;
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

    const limits = Limits.read(&server.settings, options);
    const endpoint = try server.client.endpoint(operation);
    if (endpoint.isLocal()) {
        try copyLocal(server, endpoint, operation, &outcome, pending.items, missing_here.items, limits, options);
        return outcome;
    }

    var state: Run = .{
        .server = server,
        .operation = operation,
        .options = options,
        .limits = limits,
        .arena = arena,
        .jobs = &.{},
    };
    var jobs: std.ArrayList(Job) = .empty;
    var start: usize = 0;
    while (start < pending.items.len) : (start += limits.batch_size) {
        const chunk = pending.items[start..@min(pending.items.len, start + limits.batch_size)];
        var wanted: std.ArrayList(Object) = .empty;
        defer wanted.deinit(gpa);
        for (chunk) |i| {
            const r = outcome.results[i];
            try wanted.append(gpa, .{ .oid = r.oid, .size = r.size, .name = r.name });
        }
        const answer = batchRequest(server, operation, wanted.items, options.ref, limits, arena) catch |err| switch (err) {
            error.LfsBatchFailed => {
                const why = try arena.dupe(u8, server.client.message());
                for (chunk) |i| {
                    outcome.results[i].status = .failed;
                    outcome.results[i].message = why;
                }
                continue;
            },
            else => |e| return e,
        };
        if (answer.transfer) |t| {
            if (t.len != 0 and !std.mem.eql(u8, t, "basic")) return error.LfsTransferUnsupported;
        }
        var answered: std.StringHashMapUnmanaged(*const BatchObject) = .empty;
        defer answered.deinit(gpa);
        for (answer.objects) |*o| try answered.put(gpa, o.oid, o);
        for (chunk) |i| {
            const r = &outcome.results[i];
            const o = answered.get(&r.oid) orelse {
                r.status = .failed;
                r.message = "the server's answer left the object out";
                continue;
            };
            if (o.@"error") |e| {
                r.status = .refused;
                r.message = try std.fmt.allocPrint(arena, "[{d}] {s}", .{ e.code, e.message });
                continue;
            }
            switch (operation) {
                .download => {
                    const a = o.action(.download) orelse {
                        r.status = .refused;
                        r.message = "the server has no download for the object";
                        continue;
                    };
                    try jobs.append(arena, .{ .result = r, .action = a, .verify = null, .authenticated = o.authenticated });
                },
                .upload => {
                    const a = o.action(.upload) orelse {
                        r.status = .present;
                        continue;
                    };
                    if (missing_here.items[i]) {
                        r.status = if (limits.allow_incomplete_push) .present else .missing;
                        r.message = "the object is not in the store, and the server does not have it";
                        continue;
                    }
                    try jobs.append(arena, .{ .result = r, .action = a, .verify = o.action(.verify), .authenticated = o.authenticated });
                },
            }
        }
    }
    if (jobs.items.len == 0) return outcome;
    state.jobs = jobs.items;
    state.total_objects = jobs.items.len;
    for (jobs.items) |j| state.total_bytes += j.result.size;

    try runJobs(&state);
    if (state.fatal) |err| return err;
    return outcome;
}

/// Run the jobs `concurrency` at a time. Workers run on the caller's `Io`;
/// what they have to say comes back through a queue, so the caller's
/// `Progress` is only ever called from the caller's own task. An `Io`
/// without concurrency runs them one after another on the calling task.
fn runJobs(state: *Run) Error!void {
    const io = state.io();
    const workers = @min(state.limits.concurrency, state.jobs.len);
    if (workers <= 1) {
        work(state);
        return;
    }
    var buffer: [256]Event = undefined;
    var queue: Io.Queue(Event) = .init(&buffer);
    state.events = &queue;
    var group: Io.Group = .init;
    var spawned: usize = 0;
    while (spawned < workers) : (spawned += 1) {
        group.concurrent(io, workerTask, .{state}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => break,
        };
    }
    if (spawned == 0) {
        state.events = null;
        work(state);
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

fn workerTask(state: *Run) void {
    work(state);
    state.say(.worker_done);
}

fn work(state: *Run) void {
    while (true) {
        if (state.fatal != null) return;
        const i = state.next.fetchAdd(1, .monotonic);
        if (i >= state.jobs.len) return;
        runJob(state, &state.jobs[i]) catch |err| state.setFatal(err);
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

fn runJob(state: *Run, job: *Job) Error!void {
    const r = job.result;
    var retries: u32 = 0;
    var action = job.action;
    var verify = job.verify;
    var authenticated = job.authenticated;
    while (true) {
        const attempt = switch (state.operation) {
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
                const again = batchRequest(state.server, state.operation, &.{.{ .oid = r.oid, .size = r.size, .name = r.name }}, state.options.ref, state.limits, null) catch |err| switch (err) {
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
    var out: Action = .{ .href = try state.arena.dupe(u8, a.href) };
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
    const rewrite = @import("remote.zig").rewrite;
    const pushed = if (state.operation == .upload) rewrite(scratch, config, href, .push) catch return error.MalformedValue else null;
    if (pushed) |p| return p;
    return (rewrite(scratch, config, href, .fetch) catch return error.MalformedValue) orelse href;
}

/// The URL whose access mode a transfer uses, as git-lfs finds it: the
/// action's up to the object's name.
fn accessUrl(href: []const u8, oid: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, href, oid) orelse return href;
    return href[0..at];
}

fn attemptDownload(state: *Run, r: *Result, action: Action, authenticated: bool) Error!Attempt {
    const server = state.server;
    const io = server.io;
    const store = server.store();
    var scratch_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const href = try rewriteHref(state, scratch, action.href);
    const headers = action.headers(scratch) catch |err| switch (err) {
        error.InvalidHttpHeader => return .{ .fail = "the server's action has a header with a line break in it" },
        error.OutOfMemory => return error.OutOfMemory,
    };

    // `lfs.transfer.<url>.httpDownloadEncoding`, which git-lfs reads for
    // the action's own URL: gzip unless it says zstd.
    const encoding = try server.settings.urlGet(scratch, "lfs.transfer", action.href, "httpdownloadencoding");
    const accept: lfsapi.Client.Accept = if (encoding == null or encoding.?.len == 0 or std.mem.eql(u8, encoding.?, "gzip"))
        .gzip
    else if (std.mem.eql(u8, encoding.?, "zstd"))
        .zstd
    else
        return .{ .fail = try state.dupe(try std.fmt.allocPrint(scratch, "unsupported lfs.transfer.httpDownloadEncoding value \"{s}\": must be \"gzip\" or \"zstd\"", .{encoding.?})) };

    // The download goes into `<lfs>/incomplete`, as git-lfs's does, and a
    // download that breaks off leaves `<oid>.part` there for the next
    // attempt — this operation's or a later one's — to go on from.
    const incomplete = try std.fmt.allocPrint(scratch, "{s}/incomplete", .{store.root});
    try store.base.createDirPath(io, incomplete);
    const part_path = try std.fmt.allocPrint(scratch, "{s}/{s}.part", .{ incomplete, &r.oid });
    var name_buf: [64]u8 = undefined;
    const temp_path = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ incomplete, fs.tempName(io, &name_buf, "dl-") });
    var resumed = true;
    fs.renameWithRetry(io, store.base, part_path, temp_path) catch |err| switch (err) {
        error.FileNotFound => resumed = false,
        else => |e| return e,
    };
    const file = if (resumed)
        try store.base.openFile(io, temp_path, .{ .mode = .read_write })
    else
        try store.base.createFile(io, temp_path, .{ .exclusive = true, .read = true });
    var keep_part = false;
    var installed = false;
    defer {
        file.close(io);
        if (!installed) {
            if (keep_part) {
                fs.renameWithRetry(io, store.base, temp_path, part_path) catch {};
            } else store.base.deleteFile(io, temp_path) catch {};
        }
    }

    // What is already there is hashed again, so the name is taken over the
    // whole object whichever attempt brought each byte.
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    var from: u64 = 0;
    if (resumed) {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try file.readPositionalAll(io, &buf, from);
            if (n == 0) break;
            sha.update(buf[0..n]);
            from += n;
            if (n < buf.len) break;
        }
        if (from >= r.size) {
            // More than a partial object can be: start again.
            try file.setLength(io, 0);
            from = 0;
            sha = .init(.{});
        }
    }
    const resumed_from = from;

    var range_buf: [64]u8 = undefined;
    var attempt_range = from > 0;
    const ex = while (true) {
        var all: std.ArrayList(http.Header) = .empty;
        try all.appendSlice(scratch, headers);
        if (attempt_range) try all.append(scratch, .{ .name = "Range", .value = try std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ from, r.size - 1 }) });
        const sent = server.client.send(.{
            .method = .GET,
            .url = href,
            .headers = all.items,
            .authenticated = authenticated,
            .access_url = accessUrl(action.href, &r.oid),
            // git-lfs asks for no encoding with a Range, and its client
            // asks for gzip itself without one.
            .accept = if (attempt_range) .none else accept,
        }) catch |err| switch (err) {
            error.ConnectionFailed, error.AuthenticationFailed, error.TooManyRedirects => {
                keep_part = from > 0;
                return .{ .retry = .{ .message = try state.dupe(server.client.message()) } };
            },
            error.OutOfMemory, error.Canceled => |e| return e,
            else => |e| return .{ .fail = @errorName(e) },
        };
        const status = sent.status();
        if (attempt_range and status == .range_not_satisfiable) {
            // The server will not go on from there: from the start.
            sent.close();
            try file.setLength(io, 0);
            from = 0;
            sha = .init(.{});
            attempt_range = false;
            continue;
        }
        if (attempt_range and status == .partial_content) {
            const content_range = sent.header("content-range") orelse "";
            var want_buf: [32]u8 = undefined;
            const want = std.fmt.bufPrint(&want_buf, "bytes {d}-", .{from}) catch unreachable;
            if (!std.mem.startsWith(u8, content_range, want)) {
                sent.close();
                try file.setLength(io, 0);
                from = 0;
                sha = .init(.{});
                attempt_range = false;
                continue;
            }
        } else if (attempt_range and status == .ok) {
            // The Range was passed over and the whole object came.
            try file.setLength(io, 0);
            from = 0;
            sha = .init(.{});
        }
        break sent;
    };
    defer ex.close();
    const status = ex.status();
    if (status.class() != .success) {
        keep_part = from > 0;
        const why = try std.fmt.allocPrint(scratch, "HTTP {d} from {s}", .{ @intFromEnum(status), lfsapi.stripQuery(action.href) });
        if (status == .too_many_requests) return .{ .retry = .{ .message = try state.dupe(why), .after_s = ex.retryAfter() } };
        return .{ .retry = .{ .message = try state.dupe(why) } };
    }

    if (from > 0) state.say(.{ .bytes = from });
    const body = try ex.reader();
    var counting: Counting = .init(body, state);
    var buf: [64 * 1024]u8 = undefined;
    var at = from;
    while (true) {
        const n = counting.interface.readSliceShort(&buf) catch {
            // Broken off: what came is kept for the next attempt.
            keep_part = at > 0;
            return .{ .retry = .{ .message = try state.dupe(ex.bodyError()) } };
        };
        if (n == 0) break;
        if (at + n > r.size) return .{ .fail = "the server sent more than the object's size" };
        sha.update(buf[0..n]);
        try file.writePositionalAll(io, buf[0..n], at);
        at += n;
        if (n < buf.len) break;
    }
    counting.flush();
    if (at < r.size) {
        // The body ended early: what came is kept for the next attempt.
        keep_part = true;
        return .{ .retry = .{ .message = "the download broke off" } };
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
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
    try store.base.createDirPath(io, std.fs.path.dirnamePosix(object_path).?);
    try fs.renameWithRetry(io, store.base, temp_path, object_path);
    installed = true;
    return .ok;
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
    const ex = server.client.send(.{
        .method = .PUT,
        .url = href,
        .headers = headers,
        .body = .{ .object = .{ .store = server.store(), .pointer = .{ .oid = r.oid, .size = r.size } } },
        .authenticated = authenticated,
        .access_url = accessUrl(action.href, &r.oid),
        .on_bytes = .{ .context = state, .add = addBytes },
        .sent = &sent,
    }) catch |err| switch (err) {
        error.ConnectionFailed, error.AuthenticationFailed, error.TooManyRedirects => {
            // What went out of an attempt that failed is taken back off the
            // count, as git-lfs rewinds its meter.
            state.say(.{ .unsent = sent });
            return .{ .retry = .{ .message = try state.dupe(server.client.message()) } };
        },
        error.OutOfMemory, error.Canceled => |e| return e,
        else => |e| return .{ .fail = @errorName(e) },
    };
    const status = ex.status();
    ex.close();
    if (status.class() != .success) {
        state.say(.{ .unsent = sent });
        const why = try state.dupe(try std.fmt.allocPrint(scratch, "HTTP {d} from {s}", .{ @intFromEnum(status), lfsapi.stripQuery(action.href) }));
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
    const body = try std.fmt.allocPrint(scratch, "{{\"oid\":\"{s}\",\"size\":{d}}}", .{ &r.oid, r.size });
    var last: []const u8 = "";
    var attempt: u32 = 0;
    while (attempt < state.limits.max_verifies) : (attempt += 1) {
        const ex = server.client.send(.{
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
        ex.close();
        if (status.class() == .success) return .ok;
        last = try std.fmt.allocPrint(scratch, "verify: HTTP {d}", .{@intFromEnum(status)});
    }
    return .{ .fail = try state.dupe(last) };
}

fn addBytes(context: *anyopaque, n: u64) void {
    const state: *Run = @ptrCast(@alignCast(context));
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
        const c: *Counting = @alignCast(@fieldParentPtr("interface", r));
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

    var body: Io.Writer.Allocating = .init(server.gpa);
    defer body.deinit();
    writeBatchRequest(&body.writer, operation, objects, ref) catch return error.OutOfMemory;

    var retries: u32 = 0;
    while (true) {
        const ex = server.client.api(operation, .POST, "objects/batch", body.written(), limits.max_retries) catch |err| switch (err) {
            error.ConnectionFailed, error.HttpStatus, error.AuthenticationFailed, error.TooManyRedirects, error.InsecureRedirect => return error.LfsBatchFailed,
            else => |e| return e,
        };
        defer ex.close();
        const status = ex.status();
        if (status == .too_many_requests and retries < limits.max_retries) {
            retries += 1;
            var delay_ms = limits.backoffMs(retries);
            if (ex.retryAfter()) |seconds| {
                if (seconds > limits.max_retry_time_s) {
                    server.client.noteStatus(ex, "batch");
                    return error.LfsBatchFailed;
                }
                delay_ms = seconds * 1000;
            }
            if (delay_ms != 0) try server.io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
            continue;
        }
        if (status != .ok) {
            server.client.noteStatus(ex, "batch");
            return error.LfsBatchFailed;
        }
        const bytes = try ex.readAll(64 << 20);
        const response = try parseBatch(a, bytes);
        if (own) return .{ .arena = arena_state, .response = response };
        return response;
    }
}

//=====================================================================
// A remote on this machine
//=====================================================================

/// Copy objects between this store and the store of the repository a
/// `file://` endpoint names.
fn copyLocal(
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
    const io = server.io;
    const path = endpoint.localPath().?;
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return error.LfsLocalRemoteUnreadable;
    defer dir.close(io);
    var remote = Repository.open(gpa, io, dir, .{ .discover = false }) catch return error.LfsLocalRemoteUnreadable;
    defer remote.deinit(io);
    var remote_lfs = lfs.Lfs.load(gpa, io, &remote.config, remote.common_dir, null, .{}) catch return error.LfsLocalRemoteUnreadable;
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
pub const Fetcher = struct {
    server: *lfsapi.Server,
    options: Options = .{},
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

    fn fetchFn(context: *anyopaque, io: Io, store: *const lfs.Store, settings: *const lfs.Settings, wanted: []const lfs.Wanted) lfs.FetchError!void {
        _ = io;
        _ = store;
        _ = settings;
        const f: *Fetcher = @ptrCast(@alignCast(context));
        var objects: std.ArrayList(Object) = .empty;
        defer objects.deinit(f.server.gpa);
        for (wanted) |w| objects.append(f.server.gpa, .of(w.pointer, w.path)) catch return error.OutOfMemory;
        const outcome = download(f.server, objects.items, f.options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.LfsFetchFailed,
        };
        if (f.last) |*o| o.deinit();
        f.last = outcome;
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
} || @import("revwalk.zig").Error || @import("diff.zig").Error || index_mod.ReadError || index_mod.WriteError || fs.AtomicWriteError || fs.StatError;

/// Bring the LFS objects the trees at `options.refs` point at into the
/// store, as `git lfs fetch <remote> <refs>` does. A path
/// `lfs.fetchinclude` leaves out, or `lfs.fetchexclude` names, is not
/// fetched unless `all_paths` says so.
pub fn fetch(server: *lfsapi.Server, repo: *Repository, options: FetchOptions) FetchError!Outcome {
    const gpa = server.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transfer = options.transfer;
    var tips: std.ArrayList(Oid) = .empty;
    var pointers: std.ArrayList(Object) = .empty;
    try pointers.appendSlice(arena, try scan(arena, server.io, repo, options, &transfer.ref, &tips));
    const recent = options.recent orelse server.settings.getBool("lfs.fetchrecentalways", false);
    if (recent and !options.history) {
        try pointers.appendSlice(arena, try recentPointers(arena, server, repo, tips.items, options.now));
    }
    var objects: std.ArrayList(Object) = .empty;
    for (pointers.items) |p| {
        if (!options.all_paths and !server.lfs.settings.fetchAllowed(p.name)) continue;
        try objects.append(arena, p);
    }
    return download(server, objects.items, transfer);
}

/// What `git lfs fetch --recent` adds: the tips of the recent refs, and the
/// versions the recent commits before each tip replaced.
fn recentPointers(arena: Allocator, server: *lfsapi.Server, repo: *Repository, tips: []const Oid, now: ?i64) FetchError![]Object {
    const io = server.io;
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
        var listing = try repo.refs.list(server.gpa, io, "refs/");
        defer listing.deinit();
        const remote_prefix = try std.fmt.allocPrint(arena, "refs/remotes/{s}/", .{server.remote});
        for (listing.entries) |entry| {
            // git-lfs's pattern takes `refs/<kind>/<name>`: a branch, a
            // tag, a remote's branch.
            if (std.mem.count(u8, entry.name, "/") < 2) continue;
            if (std.mem.startsWith(u8, entry.name, "refs/remotes/")) {
                if (!remote_refs or !std.mem.startsWith(u8, entry.name, remote_prefix)) continue;
            }
            const resolved = (try repo.refs.resolve(arena, io, entry.name)) orelse continue;
            const when = commitTime(arena, io, repo, resolved.oid) orelse continue;
            if (when < since) continue;
            if (containsOid(unique.items, resolved.oid)) continue;
            try unique.append(arena, resolved.oid);
            const found = try repo.odb.read(io, resolved.oid);
            defer repo.odb.gpa.free(found.bytes);
            var commit = try object_mod.Commit.parse(arena, repo.kind, found.bytes);
            defer commit.deinit();
            try scanTree(arena, io, repo, commit.tree, "", &out, &seen);
        }
    }

    if (commits_days > 0) {
        for (unique.items) |tip| {
            const tip_time = commitTime(arena, io, repo, tip) orelse continue;
            const since = tip_time - commits_days * 86400;
            var walk = @import("revwalk.zig").Walk.init(server.gpa, &repo.odb);
            defer walk.deinit();
            try walk.push(tip);
            while (try walk.next(io)) |c| {
                if (c.time < since) continue;
                // git log -p shows no diff for a merge, and a root commit
                // replaced nothing.
                if (c.parents.len != 1) continue;
                const old_tree = try treeOfCommit(arena, io, repo, c.parents[0]);
                const new_tree = try treeOfCommit(arena, io, repo, c.oid);
                var changes = try @import("diff.zig").tree(server.gpa, io, &repo.odb, old_tree, new_tree, .{});
                defer changes.deinit();
                for (changes.items) |change| {
                    const old = change.old orelse continue;
                    if (old.mode != .file and old.mode != .exec) continue;
                    const header = try repo.odb.readHeader(io, old.oid);
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
    const found = repo.odb.read(io, oid) catch return null;
    defer repo.odb.gpa.free(found.bytes);
    if (found.type != .commit) return null;
    var commit = object_mod.Commit.parse(arena, repo.kind, found.bytes) catch return null;
    defer commit.deinit();
    return commit.committer.when_secs;
}

fn treeOfCommit(arena: Allocator, io: Io, repo: *Repository, oid: Oid) FetchError!Oid {
    const found = try repo.odb.read(io, oid);
    defer repo.odb.gpa.free(found.bytes);
    var commit = try object_mod.Commit.parse(arena, repo.kind, found.bytes);
    defer commit.deinit();
    return commit.tree;
}

/// The pointers in the trees `options` asks for, each with a path it is at.
fn scan(arena: Allocator, io: Io, repo: *Repository, options: FetchOptions, ref_out: *?[]const u8, tips_out: *std.ArrayList(Oid)) FetchError![]Object {
    const tips = tips_out;
    for (options.refs) |name| {
        const found = try resolve(arena, io, repo, name);
        if (ref_out.* == null) {
            if (found.ref) |full| {
                if (std.mem.startsWith(u8, full, "refs/")) ref_out.* = full;
            }
        }
        try tips.append(arena, try repo.peel(io, found.oid));
    }
    var out: std.ArrayList(Object) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    if (options.history) {
        var exclude: std.ArrayList(Oid) = .empty;
        for (options.exclude) |name| try exclude.append(arena, (try resolve(arena, io, repo, name)).oid);
        var collected = try objectwalk.missing(arena, io, &repo.odb, tips.items, exclude.items);
        defer collected.deinit();
        for (collected.entries) |e| {
            if (e.hint.len == 0) continue;
            const header = try repo.odb.readHeader(io, e.oid);
            if (header.type != .blob) continue;
            try addPointer(arena, io, repo, e.oid, header.size, e.hint, &out, &seen);
        }
        return out.items;
    }
    for (tips.items) |tip| {
        const found = try repo.odb.read(io, tip);
        defer repo.odb.gpa.free(found.bytes);
        const tree = switch (found.type) {
            .commit => blk: {
                var commit = try object_mod.Commit.parse(arena, repo.kind, found.bytes);
                defer commit.deinit();
                break :blk commit.tree;
            },
            .tree => tip,
            else => continue,
        };
        try scanTree(arena, io, repo, tree, "", &out, &seen);
    }
    return out.items;
}

fn scanTree(arena: Allocator, io: Io, repo: *Repository, tree: Oid, prefix: []const u8, out: *std.ArrayList(Object), seen: *std.StringHashMapUnmanaged(void)) FetchError!void {
    const found = try repo.odb.read(io, tree);
    defer repo.odb.gpa.free(found.bytes);
    var entries = object_mod.Tree.parse(repo.kind, found.bytes).iterate();
    while (try entries.next()) |entry| {
        const path = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.mode) {
            .tree => try scanTree(arena, io, repo, entry.oid, path, out, seen),
            .file, .exec => {
                const header = try repo.odb.readHeader(io, entry.oid);
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
    const found = try repo.odb.read(io, oid);
    defer repo.odb.gpa.free(found.bytes);
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
        const full = try std.fmt.allocPrint(arena, rule, .{name});
        if (try repo.refs.resolve(arena, io, full)) |found| return .{ .oid = found.oid, .ref = found.name };
    }
    if (name.len == repo.kind.hexLen()) {
        if (Oid.parse(repo.kind, name)) |oid| {
            if (try repo.odb.exists(io, oid)) return .{ .oid = oid, .ref = null };
        } else |_| {}
    }
    return error.RefNotFound;
}

/// What `pull` did.
pub const PullOutcome = struct {
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
pub fn pull(server: *lfsapi.Server, repo: *Repository, options: FetchOptions) FetchError!PullOutcome {
    var fetched = try fetch(server, repo, options);
    errdefer fetched.deinit();
    var out: PullOutcome = .{ .fetched = fetched };
    const counts = try checkoutPointers(server.gpa, server.io, repo, server.store());
    out.replaced = counts.replaced;
    out.left = counts.left;
    return out;
}

/// `git lfs checkout`: every file in the working tree that is still the
/// pointer its index entry names is replaced by the object, when the store
/// has it, and its index entry is refreshed so git and relic both call it
/// clean.
pub fn checkoutPointers(gpa: Allocator, io: Io, repo: *Repository, store: *const lfs.Store) FetchError!struct { replaced: u32, left: u32 } {
    const wt = repo.work_dir orelse return .{ .replaced = 0, .left = 0 };
    var index = try repo.openIndex(io);
    defer index.deinit();
    var replaced: u32 = 0;
    var left: u32 = 0;
    for (index.entries.items) |*entry| {
        if (entry.stage != 0 or entry.skip_worktree) continue;
        if (entry.mode != .file and entry.mode != .exec) continue;
        const header = repo.odb.readHeader(io, entry.oid) catch continue;
        if (header.size >= lfs.pointer_size_cutoff or header.size == 0) continue;
        const found = try repo.odb.read(io, entry.oid);
        defer repo.odb.gpa.free(found.bytes);
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
    if (replaced != 0) try index.write(io, repo.git_dir, "index", .{});
    return .{ .replaced = replaced, .left = left };
}

fn replaceWith(io: Io, wt: Io.Dir, path: []const u8, source: Io.File, executable: bool) FetchError!void {
    var name_buf: [64]u8 = undefined;
    const temp_name = fs.tempName(io, &name_buf, ".relic-lfs-");
    const dir_path = std.fs.path.dirnamePosix(path);
    var temp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = if (dir_path) |d|
        std.fmt.bufPrint(&temp_path_buf, "{s}/{s}", .{ d, temp_name }) catch return error.NameTooLong
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
pub fn pushObjects(server: *lfsapi.Server, db: *odb_mod.Odb, pushed: []const odb_mod.PackEntry, options: Options) FetchError!Outcome {
    const gpa = server.gpa;
    const io = server.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var objects: std.ArrayList(Object) = .empty;
    for (pushed) |e| {
        if (e.hint.len == 0) continue;
        const header = try db.readHeader(io, e.oid);
        if (header.type != .blob or header.size >= lfs.pointer_size_cutoff or header.size == 0) continue;
        const found = try db.read(io, e.oid);
        defer db.gpa.free(found.bytes);
        const pointer = lfs.Pointer.decode(found.bytes) catch continue;
        if (pointer.size == 0 or pointer.extension_count != 0) continue;
        try objects.append(arena, .of(pointer, e.hint));
    }
    return upload(server, objects.items, options);
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
