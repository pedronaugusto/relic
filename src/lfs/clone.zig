//! The LFS objects a clone's checkout finds missing, fetched from the
//! remote's LFS server: what git-lfs's smudge does during `git clone`.
//!
//! The server is opened only when the checkout first asks, so a clone with
//! no LFS content, or one whose filters are not git-lfs's, never looks for
//! an LFS endpoint. What it finds and how it fetches are `lfsapi.Server` and
//! `lfstransfer.Fetcher`'s, the same as a fetch's.

const std = @import("std");
const transfer_test_mod = @import("transfer_test.zig");
const lfs_mod = @import("../testing/lfs.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const repo_mod = @import("../repo/repo.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("api.zig");
const clone_mod = @import("../transport/clone.zig");
const filter = @import("filter.zig");
const lfstransfer = @import("transfer.zig");

/// A fetcher for one clone's checkout.
const Fetcher = struct {
    gpa: Allocator,
    repo: *repo_mod.Repository,
    /// The remote the clone came from.
    remote: []const u8,
    options: lfsapi.Options,
    server: ?*lfsapi.Server = null,
    inner: ?lfstransfer.Fetcher = null,
    /// Why the server could not be opened, when it could not.
    open_error: ?lfsapi.Server.OpenError = null,

    /// The `lfs.Fetcher` a checkout is handed.
    pub fn fetcher(f: *Fetcher) lfs.Fetcher {
        return .{ .context = f, .fetchFn = fetchFn };
    }

    /// The last fetch's outcome, when there was one.
    pub fn last(f: *const Fetcher) ?*const lfstransfer.Outcome {
        const inner = &(f.inner orelse return null);
        return if (inner.last) |*o| o else null;
    }

    /// Close the server, when it was opened.
    pub fn deinit(f: *Fetcher, io: Io) void {
        if (f.inner) |*i| i.deinit();
        if (f.server) |s| s.deinit(io);
        f.* = undefined;
    }

    fn fetchFn(io: Io, context: *anyopaque, store: *const lfs.Store, settings: *const lfs.Settings, wanted: []const lfs.Wanted) lfs.FetchError!void {
        const f: *Fetcher = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Fetcher
        if (f.server == null) {
            f.server = lfsapi.Server.open(f.gpa, io, f.repo, f.remote, f.options) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => {
                    f.open_error = err;
                    return error.LfsFetchFailed;
                },
            };
            f.inner = .{ .server = f.server.? };
        }
        return f.inner.?.fetcher().fetch(io, store, settings, wanted);
    }
};

/// Clone with native LFS filtering and lazy batched downloads. A caller's
/// own filter loader takes precedence when supplied.
pub const Error = clone_mod.Error;
pub fn clone(gpa: Allocator, io: Io, url: []const u8, dir: Io.Dir, options: clone_mod.Options) Error!repo_mod.Repository {
    var with = options;
    if (with.native_filters == null) with.native_filters = .{ .load_fn = loadFilters };
    return clone_mod.clone(gpa, io, url, dir, with);
}
fn loadFilters(gpa: Allocator, io: Io, _: ?*const anyopaque, repository: *repo_mod.Repository, options: clone_mod.FilterOptions) repo_mod.Repository.LoadFiltersError!clone_mod.Filters {
    const fetch = try gpa.create(Fetcher);
    errdefer gpa.destroy(fetch);
    fetch.* = .{
        .gpa = gpa,
        .repo = repository,
        .remote = options.remote,
        .options = .{ .programs = options.programs, .prompt = options.prompt, .auth_failure = options.auth_failure },
    };
    const configured = repository.configuration().get("filter.lfs.process") != null or repository.configuration().get("filter.lfs.smudge") != null;
    return .{
        .drivers = try filter.load(gpa, io, repository, .{ .fetch = if (configured) fetch.fetcher() else null, .skip_smudge = options.skip_smudge }),
        .context = fetch,
        .release_fn = releaseFetcher,
    };
}
fn releaseFetcher(io: Io, context: *anyopaque) void {
    const fetch: *Fetcher = @ptrCast(@alignCast(context));
    const gpa = fetch.gpa;
    fetch.deinit(io);
    gpa.destroy(fetch);
}

test "phase2 native LFS clone fetches content and skip-smudge leaves pointers" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    const lt = transfer_test_mod;
    const fx = try lt.Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const helper = try lfs_mod.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(helper);
    var source = try fx.workRepo("seed", helper);
    defer source.close(io);
    try source.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.bin filter=lfs\n" });
    try source.writeFile(io, .{ .sub_path = "one.bin", .data = "native clone payload\n" });
    try fx.gitIn(source, &.{ "add", "-A" });
    try fx.gitIn(source, &.{ "commit", "-q", "-m", "seed" });
    try fx.gitIn(source, &.{ "push", "-q", "--no-verify", "origin", "main" });
    var uploaded = try lt.relicUploadHead(fx, source, .{ .ref = "refs/heads/main" });
    defer uploaded.deinit();
    try testing.expectEqual(@as(usize, 0), uploaded.failures());
    const url = try fx.url();
    defer gpa.free(url);
    for ([_]bool{ false, true }) |skip| {
        const name = if (skip) "skip" else "native";
        try fx.tmp.dir.createDir(io, name, .default_dir);
        var target = try fx.tmp.dir.openDir(io, name, .{ .iterate = true });
        defer target.close(io);
        var env = try fx.env.clone(gpa);
        defer env.deinit();
        if (skip) try env.put("GIT_LFS_SKIP_SMUDGE", "1");
        var repository = try clone(gpa, io, url, target, .{
            .who = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 },
            .programs = .{ .environ = &env },
            .user_config = .{ .command = &.{ "filter.lfs.clean=git-lfs clean -- %f", "filter.lfs.smudge=git-lfs smudge -- %f", "filter.lfs.process=git-lfs filter-process" } },
        });
        defer repository.deinit(io);
        const bytes = try target.readFileAlloc(io, "one.bin", gpa, .limited(4096));
        defer gpa.free(bytes);
        if (skip) {
            const pointer = try lfs.Pointer.decode(bytes);
            try testing.expectEqual(@as(u64, "native clone payload\n".len), pointer.size);
        } else try testing.expectEqualStrings("native clone payload\n", bytes);
    }
}
