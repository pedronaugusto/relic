//! What git-lfs's pre-push hook does, done in process by a push: other
//! people's locks checked, and the LFS objects the pushed commits point at
//! uploaded, before any ref is sent.
//!
//! The objects are the ones the push itself is about to send: every blob it
//! found missing on the remote that reads as a pointer, which is the set
//! git-lfs finds with `rev-list` over the same range. Those the server
//! already has are not sent again; one the store does not have and the
//! server lacks fails the push, unless `lfs.allowincompletepush`.
//!
//! The lock check is git-lfs's, with its three states, read from
//! `lfs.<url>.locksverify` for the upload endpoint. Set true, a path the push
//! changes that someone else holds a lock on refuses the push, and so does a
//! server that cannot say. Set false, nothing is asked. Not set, the server
//! is asked and its answer only reported: a server without a locking API is
//! noted in `learned`, under the key git-lfs writes, so it is not asked
//! again once that is kept. `github.com` is taken as set true, as git-lfs
//! takes it.
//!
//! A repository that has never used LFS — nothing to upload, no
//! `filter.lfs` setting, no LFS directory — is not asked about at all, so a
//! push to a plain git host costs nothing more than it did.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const odb_mod = @import("../odb/odb.zig");
const repo_mod = @import("../repo/repo.zig");
const program = @import("../process/program.zig");
const credential = @import("../wire/credential.zig");
const progress_mod = @import("../report/progress.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("api.zig");
const lfstransfer = @import("transfer.zig");
const lfslocks = @import("locks.zig");
const auth = @import("../wire/auth.zig");
const push_mod = @import("../transport/push.zig");
const config_mod = @import("../config/config.zig");

const Repository = repo_mod.Repository;

/// Errors from the LFS half of a push.
pub const Error = error{
    /// A path the push changes is locked by someone else, and
    /// `lfs.<url>.locksverify` is true. `Report.locked_by_others` says
    /// which and by whom.
    LfsLockedByOthers,
    /// The server could not say whose locks are whose, and
    /// `lfs.<url>.locksverify` is true. `Report.message` holds why.
    LfsLockCheckFailed,
    /// An LFS object did not reach the server. `Report.uploads` says which.
    LfsUploadFailed,
} || lfsapi.Server.OpenError || lfstransfer.FetchError || lfslocks.Error;

/// Whether a push does git-lfs's part.
pub const Mode = enum {
    /// When the repository uses LFS: something to upload, a `filter.lfs`
    /// setting, or an LFS directory.
    auto,
    on,
    /// Never, as `GIT_LFS_SKIP_PUSH` asks of git-lfs.
    off,
};

/// How the LFS half of a push runs.
pub const Options = struct {
    mode: Mode = .auto,
    /// Where what happened is said. The push's own outcome says only
    /// whether it went.
    report: ?*Report = null,
    /// Write what the server taught to the repository's configuration, as
    /// git-lfs writes it: basic access for its URL, no locking API.
    remember: bool = true,
    /// The time of the push, in seconds since the epoch: `lfsapi.Options.now`.
    now: ?i64 = null,
};

/// What the lock check came to.
pub const LockCheck = enum {
    /// Not asked: `lfs.<url>.locksverify` is false, or nothing was pushed.
    skipped,
    /// The server said whose locks are whose.
    verified,
    /// The server has no locking API.
    unsupported,
    /// The server could not say, and the push went on, as git-lfs's does
    /// when the setting is not made. `Report.message` holds why.
    failed,
};

/// What the LFS half of a push did.
pub const Report = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    /// Whether anything was done at all.
    ran: bool = false,
    locks: LockCheck = .skipped,
    /// Paths the push changes that someone else holds, with who.
    locked_by_others: []const lfslocks.Lock = &.{},
    /// Paths the push changes that the person holds: git-lfs suggests
    /// giving these back.
    own_locks_touched: []const lfslocks.Lock = &.{},
    /// One result per LFS object the push points at.
    uploads: []const lfstransfer.Result = &.{},
    message: ?[]const u8 = null,

    /// An empty report.
    pub fn init(gpa: Allocator) Report {
        return .{ .arena = .init(gpa) };
    }

    /// Release everything.
    pub fn deinit(r: *Report) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

/// How the LFS server is reached: the push's own permissions.
pub const Reach = struct {
    programs: ?program.Programs = null,
    prompt: ?credential.Prompt = null,
    progress: ?progress_mod.Progress = null,
    /// Filled in when the LFS server refuses for want of a credential: see
    /// `auth.Failure`.
    auth_failure: ?*auth.Failure = null,
};

pub const Inputs = struct { remote: []const u8, remote_refs: []const []const u8, pushed: []const odb_mod.PackEntry, reach: Reach };

/// git-lfs's pre-push hook for one push URL: check locks for `remote_refs`
/// and upload the LFS objects among `pushed`. `remote` is the remote's name,
/// or its URL.
pub fn beforePush(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    inputs: Inputs,
    options: Options,
) Self.Error!void {
    const remote = inputs.remote;
    const remote_refs = inputs.remote_refs;
    const pushed = inputs.pushed;
    const reach = inputs.reach;
    if (options.mode == .off) return;
    var scratch: Report = .init(gpa);
    defer scratch.deinit();
    const report = options.report orelse &scratch;
    const a = report.arena.allocator();

    const pointers = try pointersIn(a, io, repo.objectDatabase(), pushed);
    if (options.mode == .auto and pointers.len == 0 and !usesLfs(io, repo)) return;
    report.ran = true;

    const server = try lfsapi.Server.open(gpa, io, repo, remote, .{ .programs = reach.programs, .prompt = reach.prompt, .auth_failure = reach.auth_failure, .now = options.now });
    defer server.deinit(io);
    defer if (options.remember) server.client.remember(io, repo) catch {};

    // Other people's locks first: a push refused for one uploads nothing.
    const endpoint = try server.client.endpoint(io, .upload);
    const state = try verifyState(a, &server.settings, endpoint.url);
    if (state != .disabled and remote_refs.len != 0) {
        var ours: std.StringHashMapUnmanaged(lfslocks.Lock) = .empty;
        var theirs: std.StringHashMapUnmanaged(lfslocks.Lock) = .empty;
        report.locks = .verified;
        for (remote_refs) |ref| {
            var split = lfslocks.verify(io, server, repo, .{ .ref = ref }) catch |err| switch (err) {
                error.LockingUnsupported => {
                    report.locks = .unsupported;
                    try server.client.learnLocksVerify(io, endpoint.url, false);
                    break;
                },
                error.OutOfMemory, error.Canceled => |e| return e,
                else => {
                    report.locks = .failed;
                    report.message = try a.dupe(u8, if (server.client.message().len != 0) server.client.message() else @errorName(err));
                    if (state == .enabled) return error.LfsLockCheckFailed;
                    break;
                },
            };
            defer split.deinit();
            for (split.ours) |l| try ours.put(a, try a.dupe(u8, l.path), try copyLock(a, l));
            for (split.theirs) |l| try theirs.put(a, try a.dupe(u8, l.path), try copyLock(a, l));
        }
        var others: std.ArrayList(lfslocks.Lock) = .empty;
        var own: std.ArrayList(lfslocks.Lock) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (pushed) |e| {
            if (e.hint.len == 0) continue;
            const gop = try seen.getOrPut(a, e.hint);
            if (gop.found_existing) continue;
            if (theirs.get(e.hint)) |l| try others.append(a, l);
            if (ours.get(e.hint)) |l| try own.append(a, l);
        }
        report.locked_by_others = others.items;
        report.own_locks_touched = own.items;
        if (others.items.len != 0 and state == .enabled) return error.LfsLockedByOthers;
    }

    if (pointers.len == 0) return;
    var outcome = try lfstransfer.upload(io, server, pointers, .{
        .ref = if (remote_refs.len != 0) remote_refs[0] else null,
        .progress = reach.progress,
    });
    defer outcome.deinit();
    const results = try a.alloc(lfstransfer.Result, outcome.results.len);
    for (outcome.results, results) |r, *out| {
        out.* = r;
        out.name = try a.dupe(u8, r.name);
        if (r.message) |m| out.message = try a.dupe(u8, m);
    }
    report.uploads = results;
    if (outcome.failures() != 0) return error.LfsUploadFailed;
}

fn copyLock(a: Allocator, l: lfslocks.Lock) Allocator.Error!lfslocks.Lock {
    return .{
        .id = try a.dupe(u8, l.id),
        .path = try a.dupe(u8, l.path),
        .owner = if (l.owner) |o| try a.dupe(u8, o) else null,
        .locked_at = if (l.locked_at) |t| try a.dupe(u8, t) else null,
    };
}

/// The LFS objects among `pushed`: blobs short enough to be pointers that
/// read as one, each with the path it was found at.
fn pointersIn(a: Allocator, io: Io, db: *odb_mod.Odb, pushed: []const odb_mod.PackEntry) (odb_mod.Error || Allocator.Error)![]const lfstransfer.Object {
    var out: std.ArrayList(lfstransfer.Object) = .empty;
    for (pushed) |e| {
        if (e.hint.len == 0) continue;
        const header = try db.readHeader(io, e.oid);
        if (header.type != .blob or header.size >= lfs.pointer_size_cutoff or header.size == 0) continue;
        const found = try db.read(io, e.oid);
        defer db.allocator().free(found.bytes);
        const pointer = lfs.Pointer.decode(found.bytes) catch continue;
        if (pointer.size == 0 or pointer.extension_count != 0) continue;
        try out.append(a, .of(pointer, try a.dupe(u8, e.hint)));
    }
    return out.items;
}

/// Whether the repository has anything to do with LFS: a `filter.lfs`
/// setting, or an LFS directory.
fn usesLfs(io: Io, repo: *Repository) bool {
    for (repo.configuration().entries.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.section, "filter") and std.mem.eql(u8, entry.subsection, "lfs")) return true;
    }
    repo.commonDirectory().access(io, "lfs", .{}) catch return false;
    return true;
}

const VerifyState = enum { unknown, enabled, disabled };

/// `lfs.<url>.locksverify`, as git-lfs reads it.
fn verifyState(a: Allocator, settings: *const lfsapi.Settings, url: []const u8) lfsapi.Error!VerifyState {
    const value = (try settings.urlGet(a, "lfs", url, "locksverify")) orelse {
        const parts = lfsapi.UrlParts.parse(url) orelse return .unknown;
        const known = (std.mem.eql(u8, parts.scheme, "https") or std.mem.eql(u8, parts.scheme, "ssh")) and
            std.ascii.eqlIgnoreCase(parts.host, "github.com");
        return if (known) .enabled else .unknown;
    };
    const enabled = config_mod.parseBool(value) catch false;
    return if (enabled) .enabled else .disabled;
}

/// Push with native LFS lock verification and uploads before sending refs.
/// Other content preparation, when supplied, runs before the LFS step.
pub const PushError = Error || push_mod.Error;
pub const PushOptions = struct { transport: push_mod.Options, lfs: Options = .{} };
pub fn push(gpa: Allocator, io: Io, repository: *Repository, remote: []const u8, options: PushOptions) PushError!push_mod.Outcome {
    var context: PushContext = .{
        .reach = .{ .programs = options.transport.programs, .prompt = options.transport.prompt, .progress = options.transport.progress, .auth_failure = options.transport.auth_failure },
        .options = options.lfs,
        .previous = options.transport.before_send,
    };
    var with = options.transport;
    with.before_send = .{ .context = &context, .run = PushContext.run };
    return push_mod.push(gpa, io, repository, remote, with) catch |err| {
        if (context.failure) |failure| return failure;
        return err;
    };
}
const PushContext = struct {
    reach: Reach,
    options: Options,
    previous: ?push_mod.BeforeSend,
    failure: ?Error = null,
    fn run(context: *anyopaque, gpa: Allocator, io: Io, repository: *Repository, input: push_mod.BeforeSendInput) push_mod.BeforeSendError!void {
        const c: *PushContext = @ptrCast(@alignCast(context));
        if (c.previous) |previous| try previous.run(previous.context, gpa, io, repository, input);
        beforePush(gpa, io, repository, .{ .remote = input.remote, .remote_refs = input.refs, .pushed = input.objects, .reach = c.reach }, c.options) catch |err| {
            c.failure = err;
            return error.BeforeSendFailed;
        };
    }
};
