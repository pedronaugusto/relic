//! Where a submodule's repository and its missing commits come from: relic's
//! own clone and fetch, behind the seam `submodule.update` leaves for them.
//!
//! What git's `submodule update` runs, this does in process. A submodule
//! with no repository is cloned into `modules/<name>` as `git clone
//! --no-checkout --separate-git-dir` clones it — its remote `origin` with
//! its remote-tracking branches, `HEAD` on the remote's branch, refs
//! logged, nothing checked out — and `update` connects the working tree
//! and checks the recorded commit out. A recorded commit the repository
//! lacks is fetched the way git fetches it: a plain fetch of the default
//! remote first, and when the commit is still not there, the commit asked
//! for by name. A relative URL has been resolved against the
//! superproject's remote by the time it arrives here.
//!
//! `submodule.Transport` says only that it failed; the error behind it is
//! kept in `failure`, and a refused credential is described in
//! `auth_failure`, for the caller's message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const program = @import("program.zig");
const config_mod = @import("config.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const progress_mod = @import("progress.zig");
const submodule = @import("submodule.zig");
const clone_mod = @import("clone.zig");
const fetch_mod = @import("fetch.zig");
const repo_mod = @import("repo.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// What every clone and fetch is made with.
pub const Options = struct {
    /// Who the reflog entries are written as, and when.
    who: object.Signature,
    /// The permission to run `ssh` and credential helpers.
    programs: ?program.Programs = null,
    /// The person's configuration, for `core.sshCommand`, `http.*` and the
    /// credential helpers, which a new submodule repository does not yet
    /// have: see `userconfig.locate`.
    config: ?*const config_mod.Config = null,
    prompt: ?credential.Prompt = null,
    progress: ?progress_mod.Progress = null,
    /// Check received objects the way git's `fsck` does.
    check_objects: bool = true,
};

/// A `submodule.Transport` over relic's clone and fetch.
pub const Transport = struct {
    options: Options,
    /// The error behind the last `error.TransportFailed`.
    failure: ?anyerror = null,
    /// The last refusal of a credential, described.
    auth_failure: auth.Failure = .{},
    /// How many repositories were cloned and how many fetches made.
    clones: u32 = 0,
    fetches: u32 = 0,

    /// A transport making every clone and fetch with `options`.
    pub fn init(options: Options) Transport {
        return .{ .options = options };
    }

    /// Release the failure's description.
    pub fn deinit(t: *Transport) void {
        t.auth_failure.deinit();
    }

    /// The seam `submodule.UpdateOptions.transport` takes. `t` must
    /// outlive the update.
    pub fn transport(t: *Transport) submodule.Transport {
        return .{ .context = t, .cloneFn = cloneFn, .fetchFn = fetchFn };
    }

    fn failed(t: *Transport, err: anyerror) submodule.TransportError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => {
                t.failure = err;
                return error.TransportFailed;
            },
        };
    }

    fn cloneFn(context: *anyopaque, gpa: Allocator, io: Io, url: []const u8, git_dir: Io.Dir) submodule.TransportError!void {
        const t: *Transport = @ptrCast(@alignCast(context));
        const o = t.options;
        var repo = clone_mod.clone(gpa, io, url, git_dir, .{
            .separate_git_dir = true,
            .who = o.who,
            .programs = o.programs,
            .config = o.config,
            .prompt = o.prompt,
            .auth_failure = &t.auth_failure,
            .progress = o.progress,
            .check_objects = o.check_objects,
        }) catch |err| return t.failed(err);
        repo.deinit(io);
        t.clones += 1;
    }

    fn fetchFn(context: *anyopaque, gpa: Allocator, io: Io, repo: *Repository, remote: []const u8, want: Oid) submodule.TransportError!void {
        const t: *Transport = @ptrCast(@alignCast(context));
        t.fetchOnce(gpa, io, repo, remote, &.{}) catch |err| return t.failed(err);
        repo.odb.refresh(io) catch |err| return t.failed(err);
        if (repo.odb.exists(io, want) catch |err| return t.failed(err)) return;
        // Not on any branch the remote advertises: asked for by name, as
        // git's `fetch <remote> <commit>` asks.
        var hex: [hash.max_hex_len]u8 = undefined;
        t.fetchOnce(gpa, io, repo, remote, &.{want.hex(&hex)}) catch |err| return t.failed(err);
    }

    fn fetchOnce(t: *Transport, gpa: Allocator, io: Io, repo: *Repository, remote: []const u8, refspecs: []const []const u8) !void {
        const o = t.options;
        var outcome = try fetch_mod.fetch(gpa, io, repo, remote, .{
            .refspecs = refspecs,
            .who = o.who,
            .programs = o.programs,
            .prompt = o.prompt,
            .auth_failure = &t.auth_failure,
            .progress = o.progress,
            .check_objects = o.check_objects,
        });
        outcome.deinit();
        t.fetches += 1;
    }
};

const testing = std.testing;
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// Run git in `dir` with the suite's settings, `protocol.file.allow`
/// among them.
fn gitIn(gpa: Allocator, io: Io, dir: Io.Dir, args: []const []const u8) !void {
    const out = try testremote.gitInput(gpa, io, dir, args, "");
    gpa.free(out);
}

/// What git and relic are compared on: each submodule repository's refs,
/// remote and working-tree setting, and the superproject's view of them.
fn expectSameSubmodules(gpa: Allocator, io: Io, by_git: Io.Dir, by_relic: Io.Dir) !void {
    for ([_][]const u8{ ".git/modules/lib", ".git/modules/lib/modules/inner" }) |git_dir| {
        for ([_][]const []const u8{
            &.{ "--git-dir", git_dir, "for-each-ref", "--format=%(refname) %(objectname) %(symref)" },
            &.{ "--git-dir", git_dir, "rev-parse", "HEAD" },
            &.{ "--git-dir", git_dir, "config", "--get-regexp", "^(remote|core\\.(bare|worktree)|branch)" },
        }) |args| {
            const theirs = testremote.gitInput(gpa, io, by_git, args, "") catch try gpa.dupe(u8, "(failed)");
            defer gpa.free(theirs);
            const ours = testremote.gitInput(gpa, io, by_relic, args, "") catch try gpa.dupe(u8, "(failed)");
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
    }
    const theirs = try testremote.gitInput(gpa, io, by_git, &.{ "submodule", "status", "--recursive" }, "");
    defer gpa.free(theirs);
    const ours = try testremote.gitInput(gpa, io, by_relic, &.{ "submodule", "status", "--recursive" }, "");
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
    const status = try testremote.gitInput(gpa, io, by_relic, &.{ "status", "--porcelain" }, "");
    defer gpa.free(status);
    try testing.expectEqualStrings("", status);
    for ([_][]const u8{ "lib", "lib/inner" }) |path| {
        var sub = try by_relic.openDir(io, path, .{});
        defer sub.close(io);
        try gitIn(gpa, io, sub, &.{ "fsck", "--strict", "--no-dangling" });
    }
}

test "submodules cloned and fetched from a remote are what git submodule update --init --recursive makes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    // Three repositories, each made in `work/<name>` and pushed to the bare
    // one the server serves: `inner`; `lib`, holding `inner`; `super`,
    // holding `lib`. The submodule URLs are relative, as a forge's are.
    var work = try testgit.Repo.init(gpa, io, &.{});
    defer work.deinit();
    const names = [_][]const u8{ "inner", "lib", "super" };
    for (names, 0..) |name, i| {
        const bare = try std.fmt.allocPrint(gpa, "{s}/{s}.git", .{ root_path, name });
        defer gpa.free(bare);
        try gitIn(gpa, io, work.dir, &.{ "init", "-q", "--bare", "-b", "main", bare });
        try gitIn(gpa, io, work.dir, &.{ "--git-dir", bare, "config", "uploadpack.allowAnySHA1InWant", "true" });
        try gitIn(gpa, io, work.dir, &.{ "init", "-q", "-b", "main", name });
        var dir = try work.dir.openDir(io, name, .{});
        defer dir.close(io);
        const file = try std.fmt.allocPrint(gpa, "{s}.git", .{name});
        defer gpa.free(file);
        const url = try server.url(gpa, file);
        defer gpa.free(url);
        try gitIn(gpa, io, dir, &.{ "remote", "add", "origin", url });
        try dir.writeFile(io, .{ .sub_path = "README", .data = name });
        try gitIn(gpa, io, dir, &.{ "add", "README" });
        if (i > 0) {
            const relative = try std.fmt.allocPrint(gpa, "../{s}.git", .{names[i - 1]});
            defer gpa.free(relative);
            try gitIn(gpa, io, dir, &.{ "submodule", "add", "-q", relative, names[i - 1] });
        }
        try gitIn(gpa, io, dir, &.{ "commit", "-q", "-m", name });
        try gitIn(gpa, io, dir, &.{ "push", "-q", bare, "main" });
    }
    const super_url = try server.url(gpa, "super.git");
    defer gpa.free(super_url);
    try gitIn(gpa, io, work.dir, &.{ "clone", "-q", super_url, "by-git" });
    try gitIn(gpa, io, work.dir, &.{ "clone", "-q", super_url, "by-relic" });
    var by_git = try work.dir.openDir(io, "by-git", .{});
    defer by_git.close(io);
    var by_relic = try work.dir.openDir(io, "by-relic", .{});
    defer by_relic.close(io);

    var t: Transport = .init(.{ .who = test_who, .programs = .{ .environ = &env } });
    defer t.deinit();
    try gitIn(gpa, io, by_git, &.{ "submodule", "update", "-q", "--init", "--recursive" });
    {
        var repo = try Repository.open(gpa, io, by_relic, .{});
        defer repo.deinit(io);
        _ = try submodule.update(gpa, io, &repo, .{ .init = true, .recursive = true, .transport = t.transport(), .who = test_who });
    }
    try testing.expectEqual(@as(u32, 2), t.clones);
    try expectSameSubmodules(gpa, io, by_git, by_relic);

    // New commits below: `inner` moves on, once on its branch and once to a
    // commit only a ref outside refs/heads reaches, and each level records
    // the one below. An update then has commits to fetch.
    {
        var inner = try work.dir.openDir(io, "inner", .{});
        defer inner.close(io);
        try inner.writeFile(io, .{ .sub_path = "README", .data = "inner, again" });
        const bare = try std.fmt.allocPrint(gpa, "{s}/inner.git", .{root_path});
        defer gpa.free(bare);
        try gitIn(gpa, io, inner, &.{ "commit", "-q", "-am", "again" });
        try gitIn(gpa, io, inner, &.{ "push", "-q", bare, "main" });
        try inner.writeFile(io, .{ .sub_path = "README", .data = "inner, aside" });
        try gitIn(gpa, io, inner, &.{ "commit", "-q", "-am", "aside" });
        try gitIn(gpa, io, inner, &.{ "push", "-q", bare, "HEAD:refs/keep/aside" });
    }
    for ([_][]const u8{ "lib", "super" }, [_][]const u8{ "inner", "lib" }) |name, below| {
        var dir = try work.dir.openDir(io, name, .{});
        defer dir.close(io);
        var sub = try dir.openDir(io, below, .{});
        defer sub.close(io);
        if (std.mem.eql(u8, below, "inner")) {
            try gitIn(gpa, io, sub, &.{ "fetch", "-q", "origin", "refs/keep/aside" });
            try gitIn(gpa, io, sub, &.{ "checkout", "-q", "FETCH_HEAD" });
        } else {
            try gitIn(gpa, io, sub, &.{ "pull", "-q", "origin", "main" });
        }
        try gitIn(gpa, io, dir, &.{ "commit", "-q", "-am", "move" });
        const bare = try std.fmt.allocPrint(gpa, "{s}/{s}.git", .{ root_path, name });
        defer gpa.free(bare);
        try gitIn(gpa, io, dir, &.{ "push", "-q", bare, "main" });
    }
    for ([_]Io.Dir{ by_git, by_relic }) |dir| try gitIn(gpa, io, dir, &.{ "pull", "-q", "--no-recurse-submodules", "origin", "main" });
    try gitIn(gpa, io, by_git, &.{ "submodule", "update", "-q", "--recursive" });
    {
        var repo = try Repository.open(gpa, io, by_relic, .{});
        defer repo.deinit(io);
        _ = try submodule.update(gpa, io, &repo, .{ .recursive = true, .transport = t.transport(), .who = test_who });
    }
    try testing.expect(t.fetches >= 3);
    try expectSameSubmodules(gpa, io, by_git, by_relic);
}
