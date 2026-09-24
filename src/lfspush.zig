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

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const odb_mod = @import("odb.zig");
const repo_mod = @import("repo.zig");
const program = @import("program.zig");
const credential = @import("credential.zig");
const progress_mod = @import("progress.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("lfsapi.zig");
const lfstransfer = @import("lfstransfer.zig");
const lfslocks = @import("lfslocks.zig");

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
};

/// git-lfs's pre-push hook for one push URL: check locks for `remote_refs`
/// and upload the LFS objects among `pushed`. `remote` is the remote's name,
/// or its URL.
pub fn beforePush(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: []const u8,
    remote_refs: []const []const u8,
    pushed: []const odb_mod.PackEntry,
    reach: Reach,
    options: Options,
) Error!void {
    if (options.mode == .off) return;
    var scratch: Report = .init(gpa);
    defer scratch.deinit();
    const report = options.report orelse &scratch;
    const a = report.arena.allocator();

    const pointers = try pointersIn(a, io, &repo.odb, pushed);
    if (options.mode == .auto and pointers.len == 0 and !usesLfs(io, repo)) return;
    report.ran = true;

    const server = try lfsapi.Server.open(gpa, io, repo, remote, .{ .programs = reach.programs, .prompt = reach.prompt });
    defer server.close();
    defer if (options.remember) server.client.remember(io, repo) catch {};

    // Other people's locks first: a push refused for one uploads nothing.
    const endpoint = try server.client.endpoint(.upload);
    const state = try verifyState(a, &server.settings, endpoint.url);
    if (state != .disabled and remote_refs.len != 0) {
        var ours: std.StringHashMapUnmanaged(lfslocks.Lock) = .empty;
        var theirs: std.StringHashMapUnmanaged(lfslocks.Lock) = .empty;
        report.locks = .verified;
        for (remote_refs) |ref| {
            var split = lfslocks.verify(server, repo, .{ .ref = ref }) catch |err| switch (err) {
                error.LockingUnsupported => {
                    report.locks = .unsupported;
                    try server.client.learnLocksVerify(endpoint.url, false);
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
    var outcome = try lfstransfer.upload(server, pointers, .{
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
        defer db.gpa.free(found.bytes);
        const pointer = lfs.Pointer.decode(found.bytes) catch continue;
        if (pointer.size == 0 or pointer.extension_count != 0) continue;
        try out.append(a, .of(pointer, try a.dupe(u8, e.hint)));
    }
    return out.items;
}

/// Whether the repository has anything to do with LFS: a `filter.lfs`
/// setting, or an LFS directory.
fn usesLfs(io: Io, repo: *Repository) bool {
    for (repo.config.entries.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.section, "filter") and std.mem.eql(u8, entry.subsection, "lfs")) return true;
    }
    repo.common_dir.access(io, "lfs", .{}) catch return false;
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
    const enabled = @import("config.zig").parseBool(value) catch false;
    return if (enabled) .enabled else .disabled;
}
