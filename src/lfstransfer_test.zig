//! LFS transfers against the in-test server, relic beside git-lfs: what one
//! uploads the other downloads, the credential helpers are asked what git-lfs
//! asks them, ssh is started as git-lfs starts it, and the endpoint is the one
//! `git lfs env` names.
//!
//! Every program these tests run starts from `testlfs.environ`, with a home
//! directory of the test's own and no system configuration, so nothing of
//! the person's — helpers, keychain, agents — is reached. The tests want
//! git-lfs as well as git, and stand aside without it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const repo_mod = @import("repo.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("lfsapi.zig");
const lfstransfer = @import("lfstransfer.zig");
const objectwalk = @import("objectwalk.zig");
const progress_mod = @import("progress.zig");
const testlfs = @import("testlfs.zig");
const testremote = @import("testremote.zig");

/// A server, a home, and a place for tools and repositories.
pub const Fixture = struct {
    gpa: Allocator,
    io: Io,
    tmp: testing.TmpDir,
    root: []u8,
    env: std.process.Environ.Map,
    tools: Io.Dir,
    served: Io.Dir,
    server: *testlfs.Server,

    pub fn init(gpa: Allocator, io: Io, options: testlfs.Server.Options) !*Fixture {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const fx = try gpa.create(Fixture);
        errdefer gpa.destroy(fx);
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try testremote.absolutePath(gpa, io, tmp.dir);
        errdefer gpa.free(root);
        for ([_][]const u8{ "home", "tools", "served" }) |name| try tmp.dir.createDirPath(io, name);
        const home = try std.fmt.allocPrint(gpa, "{s}/home", .{root});
        defer gpa.free(home);
        var env = try testlfs.environ(gpa, home);
        errdefer env.deinit();
        try testlfs.requireGitLfs(gpa, io, &env);
        // The stand-ins go first on the path: git-lfs-authenticate for the
        // stand-in ssh to find.
        const tools_path = try std.fmt.allocPrint(gpa, "{s}/tools:{s}", .{ root, env.get("PATH").? });
        defer gpa.free(tools_path);
        try env.put("PATH", tools_path);
        var tools = try tmp.dir.openDir(io, "tools", .{});
        errdefer tools.close(io);
        var served = try tmp.dir.openDir(io, "served", .{});
        errdefer served.close(io);
        var opts = options;
        opts.git_root = served;
        const server = try testlfs.Server.start(gpa, io, opts);
        errdefer server.stop();
        fx.* = .{ .gpa = gpa, .io = io, .tmp = tmp, .root = root, .env = env, .tools = tools, .served = served, .server = server };
        try fx.gitIn(served, &.{ "init", "-q", "--bare", "-b", "main", "repo.git" });
        return fx;
    }

    pub fn deinit(fx: *Fixture) void {
        const gpa = fx.gpa;
        fx.server.stop();
        fx.tools.close(fx.io);
        fx.served.close(fx.io);
        fx.env.deinit();
        gpa.free(fx.root);
        fx.tmp.cleanup();
        gpa.destroy(fx);
    }

    /// `http://127.0.0.1:<port>/repo.git`. The caller's.
    pub fn url(fx: *Fixture) ![]u8 {
        return fx.server.url(fx.gpa, "repo.git");
    }

    /// A directory under the fixture, made if it is not there.
    pub fn dir(fx: *Fixture, name: []const u8) !Io.Dir {
        try fx.tmp.dir.createDirPath(fx.io, name);
        return fx.tmp.dir.openDir(fx.io, name, .{ .iterate = true });
    }

    pub fn path(fx: *Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(fx.gpa, "{s}/{s}", .{ fx.root, name });
    }

    pub fn gitIn(fx: *Fixture, d: Io.Dir, args: []const []const u8) !void {
        const out = try testlfs.git(fx.gpa, fx.io, d, &fx.env, args, true);
        fx.gpa.free(out);
    }

    pub fn gitOut(fx: *Fixture, d: Io.Dir, args: []const []const u8) ![]u8 {
        return testlfs.git(fx.gpa, fx.io, d, &fx.env, args, true);
    }

    /// Run git with `name=value` set on top of the fixture's environment.
    pub fn gitWith(fx: *Fixture, d: Io.Dir, set: []const [2][]const u8, args: []const []const u8) !void {
        var env = try fx.env.clone(fx.gpa);
        defer env.deinit();
        for (set) |pair| try env.put(pair[0], pair[1]);
        const out = try testlfs.git(fx.gpa, fx.io, d, &env, args, true);
        fx.gpa.free(out);
    }

    /// A working repository with git-lfs's filters, `origin` at the server
    /// and `helper` as its only credential helper.
    pub fn workRepo(fx: *Fixture, name: []const u8, helper: []const u8) !Io.Dir {
        const d = try fx.dir(name);
        const u = try fx.url();
        defer fx.gpa.free(u);
        try fx.gitIn(d, &.{ "init", "-q", "-b", "main" });
        try fx.lfsFilters(d);
        try fx.gitIn(d, &.{ "remote", "add", "origin", u });
        try fx.gitIn(d, &.{ "config", "credential.helper", helper });
        try fx.gitIn(d, &.{ "config", "lfs.transfer.maxretrydelay", "0" });
        return d;
    }

    /// A clone of the served repository, pointers left as they are.
    pub fn cloneRepo(fx: *Fixture, name: []const u8, helper: []const u8) !Io.Dir {
        const u = try fx.url();
        defer fx.gpa.free(u);
        const dest = try fx.path(name);
        defer fx.gpa.free(dest);
        try fx.gitWith(fx.tmp.dir, &.{.{ "GIT_LFS_SKIP_SMUDGE", "1" }}, &.{ "clone", "-q", u, dest });
        const d = try fx.tmp.dir.openDir(fx.io, name, .{ .iterate = true });
        try fx.lfsFilters(d);
        try fx.gitIn(d, &.{ "config", "credential.helper", helper });
        try fx.gitIn(d, &.{ "config", "lfs.transfer.maxretrydelay", "0" });
        return d;
    }

    /// The filters `git lfs install` writes, in the repository's own
    /// configuration.
    pub fn lfsFilters(fx: *Fixture, d: Io.Dir) !void {
        try fx.gitIn(d, &.{ "config", "filter.lfs.clean", "git-lfs clean -- %f" });
        try fx.gitIn(d, &.{ "config", "filter.lfs.smudge", "git-lfs smudge -- %f" });
        try fx.gitIn(d, &.{ "config", "filter.lfs.process", "git-lfs filter-process" });
        try fx.gitIn(d, &.{ "config", "filter.lfs.required", "true" });
    }

    pub fn programs(fx: *Fixture) @import("program.zig").Programs {
        return .{ .environ = &fx.env };
    }
};

/// Bytes that do not compress, seeded so a test's objects are the same in
/// every run.
pub fn noise(gpa: Allocator, len: usize, seed: u64) ![]u8 {
    const bytes = try gpa.alloc(u8, len);
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(bytes);
    return bytes;
}

pub const attributes = "*.bin filter=lfs diff=lfs merge=lfs -text\n";

/// Every object relic would push from `HEAD` of the repository at `d`,
/// uploaded as a push uploads them.
fn relicUploadHead(fx: *Fixture, d: Io.Dir, options: lfstransfer.Options) !lfstransfer.Outcome {
    var repo = try repo_mod.Repository.open(fx.gpa, fx.io, d, .{});
    defer repo.deinit(fx.io);
    const head = (try repo.head(fx.io)).?;
    defer fx.gpa.free(head.name);
    var collected = try objectwalk.missing(fx.gpa, fx.io, &repo.odb, &.{head.oid}, &.{});
    defer collected.deinit();
    const server = try lfsapi.Server.open(fx.gpa, fx.io, &repo, "origin", .{ .programs = fx.programs() });
    defer server.close();
    return lfstransfer.pushObjects(server, &repo.odb, collected.entries, options);
}

/// Fail with every failure's message printed.
fn expectNoFailures(outcome: *const lfstransfer.Outcome) !void {
    if (outcome.failures() == 0) return;
    for (outcome.results) |r| {
        if (r.isFailure()) std.debug.print("{s} {s}: {s}\n", .{ r.name, @tagName(r.status), r.message orelse "" });
    }
    return error.TestUnexpectedResult;
}

fn expectFile(fx: *Fixture, d: Io.Dir, name: []const u8, want: []const u8) !void {
    const have = try d.readFileAlloc(fx.io, name, fx.gpa, .limited(64 << 20));
    defer fx.gpa.free(have);
    try testing.expectEqualSlices(u8, want, have);
}

test "what relic uploads git lfs pull downloads, what git-lfs pushes relic pulls, and the helpers hear the same" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .users = &.{
        .{ .name = "ada", .password = "secret" },
        .{ .name = "bob", .password = "hunter2" },
    } });
    defer fx.deinit();
    const ours_helper = try testlfs.credentialHelper(gpa, io, fx.tools, "ours-helper", "ada", "secret");
    defer gpa.free(ours_helper);
    const theirs_helper = try testlfs.credentialHelper(gpa, io, fx.tools, "theirs-helper", "bob", "hunter2");
    defer gpa.free(theirs_helper);

    var ours = try fx.workRepo("ours", ours_helper);
    defer ours.close(io);
    const big = try noise(gpa, 300 * 1024, 1);
    defer gpa.free(big);
    try ours.writeFile(io, .{ .sub_path = ".gitattributes", .data = attributes });
    try ours.writeFile(io, .{ .sub_path = "big.bin", .data = big });
    try ours.createDirPath(io, "art");
    try ours.writeFile(io, .{ .sub_path = "art/small.bin", .data = "small but tracked\n" });
    try fx.gitIn(ours, &.{ "add", "-A" });
    try fx.gitIn(ours, &.{ "commit", "-q", "-m", "one" });
    try fx.gitIn(ours, &.{ "push", "-q", "--no-verify", "origin", "main" });

    {
        var outcome = try relicUploadHead(fx, ours, .{ .ref = "refs/heads/main" });
        defer outcome.deinit();
        try testing.expectEqual(@as(usize, 2), outcome.results.len);
        try expectNoFailures(&outcome);
        for (outcome.results) |r| try testing.expectEqual(lfstransfer.Result.Status.transferred, r.status);
    }
    try testing.expectEqual(@as(usize, 2), fx.server.objectCount());

    // git-lfs downloads what relic uploaded.
    var theirs = try fx.cloneRepo("theirs", theirs_helper);
    defer theirs.close(io);
    try fx.gitIn(theirs, &.{ "lfs", "pull" });
    try expectFile(fx, theirs, "big.bin", big);
    try expectFile(fx, theirs, "art/small.bin", "small but tracked\n");

    // Each asked its own helper the same things: get, then store once the
    // credential worked.
    {
        const a = try fx.tools.readFileAlloc(io, "ours-helper.log", gpa, .unlimited);
        defer gpa.free(a);
        const b = try fx.tools.readFileAlloc(io, "theirs-helper.log", gpa, .unlimited);
        defer gpa.free(b);
        const b_as_ada = try std.mem.replaceOwned(u8, gpa, b, "username=bob\npassword=hunter2", "username=ada\npassword=secret");
        defer gpa.free(b_as_ada);
        try testing.expectEqualStrings(b_as_ada, a);
        try testing.expect(std.mem.startsWith(u8, a, "== get\nprotocol=http\nhost=127.0.0.1:"));
    }

    // git-lfs pushes a new object, and relic pulls it into place.
    const newer = try noise(gpa, 120 * 1024, 2);
    defer gpa.free(newer);
    try theirs.writeFile(io, .{ .sub_path = "newer.bin", .data = newer });
    try fx.gitIn(theirs, &.{ "add", "-A" });
    try fx.gitIn(theirs, &.{ "commit", "-q", "-m", "two" });
    try fx.gitIn(theirs, &.{ "lfs", "push", "origin", "main" });
    try fx.gitIn(theirs, &.{ "push", "-q", "--no-verify", "origin", "main" });
    try testing.expectEqual(@as(usize, 3), fx.server.objectCount());

    try fx.gitWith(ours, &.{.{ "GIT_LFS_SKIP_SMUDGE", "1" }}, &.{ "pull", "-q", "--no-rebase", "origin", "main" });
    {
        var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
        defer repo.deinit(io);
        const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = fx.programs() });
        defer server.close();
        var pulled = try lfstransfer.pull(server, &repo, .{});
        defer pulled.deinit();
        try testing.expectEqual(@as(usize, 0), pulled.fetched.failures());
        try testing.expectEqual(@as(u32, 1), pulled.replaced);
    }
    try expectFile(fx, ours, "newer.bin", newer);
    const status = try fx.gitOut(ours, &.{ "status", "--porcelain" });
    defer gpa.free(status);
    try testing.expectEqualStrings("", status);
}

/// Commit `files` in a fresh work repository `name`, with git-lfs's clean.
fn committed(fx: *Fixture, name: []const u8, helper: []const u8, files: []const [2][]const u8) !Io.Dir {
    var d = try fx.workRepo(name, helper);
    errdefer d.close(fx.io);
    try d.writeFile(fx.io, .{ .sub_path = ".gitattributes", .data = attributes });
    for (files) |f| {
        if (std.fs.path.dirnamePosix(f[0])) |parent| try d.createDirPath(fx.io, parent);
        try d.writeFile(fx.io, .{ .sub_path = f[0], .data = f[1] });
    }
    try fx.gitIn(d, &.{ "add", "-A" });
    try fx.gitIn(d, &.{ "commit", "-q", "-m", "files" });
    return d;
}

/// Delete the LFS store of the repository at `d`, so every object has to
/// come from somewhere else.
fn emptyStore(fx: *Fixture, d: Io.Dir) !void {
    d.deleteTree(fx.io, ".git/lfs") catch {};
}

fn openServer(fx: *Fixture, repo: *repo_mod.Repository) !*lfsapi.Server {
    return lfsapi.Server.open(fx.gpa, fx.io, repo, "origin", .{ .programs = fx.programs() });
}

test "ssh is started for git-lfs-authenticate as git-lfs starts it, and its token is what the server takes" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .tokens = &.{.{ .token = "t0k3n", .user = "ada" }} });
    defer fx.deinit();
    const fake_ssh = try testremote.fakeSsh(gpa, io, fx.tools);
    defer gpa.free(fake_ssh);
    const href = try fx.server.url(gpa, "repo.git/info/lfs");
    defer gpa.free(href);
    const auth_script = try testlfs.authenticateScript(gpa, io, fx.tools, href, "t0k3n");
    defer gpa.free(auth_script);
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);

    const content = try noise(gpa, 64 * 1024, 3);
    defer gpa.free(content);
    var ours = try committed(fx, "ours", nobody, &.{.{ "a.bin", content }});
    defer ours.close(io);
    const ssh_url = "ssh://git@example.invalid:2222/org/repo.git";
    try fx.gitIn(ours, &.{ "remote", "set-url", "origin", ssh_url });
    try fx.gitIn(ours, &.{ "config", "core.sshCommand", fake_ssh });
    try fx.gitIn(ours, &.{ "config", "lfs.sshtransfer", "never" });

    {
        var outcome = try relicUploadHead(fx, ours, .{});
        defer outcome.deinit();
        try expectNoFailures(&outcome);
    }
    try testing.expectEqual(@as(usize, 1), fx.server.objectCount());

    // Two clones fetch it back, one with git-lfs and one with relic; ssh is
    // handed the same arguments by each.
    const ours_path = try fx.path("ours");
    defer gpa.free(ours_path);
    var logs: [2][]u8 = undefined;
    for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
        const dest = try fx.path(name);
        defer gpa.free(dest);
        try fx.gitWith(fx.tmp.dir, &.{.{ "GIT_LFS_SKIP_SMUDGE", "1" }}, &.{ "clone", "-q", ours_path, dest });
        var d = try fx.tmp.dir.openDir(io, name, .{});
        defer d.close(io);
        try fx.lfsFilters(d);
        try fx.gitIn(d, &.{ "remote", "set-url", "origin", ssh_url });
        try fx.gitIn(d, &.{ "config", "core.sshCommand", fake_ssh });
        try fx.gitIn(d, &.{ "config", "lfs.sshtransfer", "never" });
        fx.tools.deleteFile(io, "fake-ssh.log") catch {};
        if (i == 0) {
            try fx.gitIn(d, &.{ "lfs", "pull" });
        } else {
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try openServer(fx, &repo);
            defer server.close();
            var pulled = try lfstransfer.pull(server, &repo, .{});
            defer pulled.deinit();
            try testing.expectEqual(@as(usize, 0), pulled.fetched.failures());
        }
        try expectFile(fx, d, "a.bin", content);
        logs[i] = try fx.tools.readFileAlloc(io, "fake-ssh.log", gpa, .unlimited);
    }
    defer for (logs) |l| gpa.free(l);
    try testing.expectEqualStrings(logs[0], logs[1]);
    try testing.expect(std.mem.indexOf(u8, logs[1], "[git-lfs-authenticate /org/repo.git download]") != null);
    // No request went out without the token.
    const seen = try fx.server.requests(gpa);
    defer gpa.free(seen);
    try testing.expect(std.mem.indexOf(u8, seen, " ?\n") == null);
}

test "a failed transfer is retried with a fresh batch, a 429 is waited out, and one that keeps failing is named" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const one = try noise(gpa, 40 * 1024, 4);
    defer gpa.free(one);
    const two = try noise(gpa, 50 * 1024, 5);
    defer gpa.free(two);
    var ours = try committed(fx, "ours", nobody, &.{ .{ "one.bin", one }, .{ "two.bin", two } });
    defer ours.close(io);
    try fx.gitIn(ours, &.{ "config", "lfs.transfer.maxretries", "2" });

    try fx.server.fail(.{ .route = .batch, .status = 429, .retry_after = "0" });
    try fx.server.fail(.{ .route = .upload, .status = 500 });
    try fx.server.fail(.{ .route = .upload, .status = 503 });
    {
        var outcome = try relicUploadHead(fx, ours, .{});
        defer outcome.deinit();
        try expectNoFailures(&outcome);
    }
    try testing.expectEqual(@as(usize, 2), fx.server.objectCount());
    {
        const seen = try fx.server.requests(gpa);
        defer gpa.free(seen);
        // The 429, the first batch, and one batch per retried object.
        try testing.expectEqual(@as(usize, 4), std.mem.count(u8, seen, "POST /objects/batch"));
        try testing.expectEqual(@as(usize, 4), std.mem.count(u8, seen, "PUT /objects/"));
    }

    try emptyStore(fx, ours);
    for (0..3) |_| try fx.server.fail(.{ .route = .download, .status = 500 });
    var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
    defer repo.deinit(io);
    const server = try openServer(fx, &repo);
    defer server.close();
    var fetched = try lfstransfer.fetch(server, &repo, .{ .transfer = .{ .concurrency = 1 } });
    defer fetched.deinit();
    try testing.expectEqual(@as(usize, 1), fetched.failures());
    var failed: ?lfstransfer.Result = null;
    for (fetched.results) |r| if (r.isFailure()) {
        failed = r;
    };
    try testing.expectEqual(lfstransfer.Result.Status.failed, failed.?.status);
    try testing.expect(std.mem.indexOf(u8, failed.?.message.?, "HTTP 500") != null);

    // An object the server does not have is refused by the server's words.
    try fx.server.putObject(&testlfs.sha256Hex("x"), "y");
    var missing = try lfstransfer.download(server, &.{.{ .oid = testlfs.sha256Hex("absent"), .size = 6, .name = "absent.bin" }}, .{});
    defer missing.deinit();
    try testing.expectEqual(lfstransfer.Result.Status.refused, missing.results[0].status);
    try testing.expectEqualStrings("[404] Object does not exist", missing.results[0].message.?);
}

test "a remote on this machine has its objects copied store to store, and git-lfs reads what relic put there" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const content = try noise(gpa, 90 * 1024, 6);
    defer gpa.free(content);
    var ours = try committed(fx, "ours", nobody, &.{.{ "art/a.bin", content }});
    defer ours.close(io);
    const bare = try fx.path("served/local.git");
    defer gpa.free(bare);
    try fx.gitIn(fx.served, &.{ "init", "-q", "--bare", "-b", "main", "local.git" });
    try fx.gitIn(ours, &.{ "remote", "set-url", "origin", bare });
    try fx.gitIn(ours, &.{ "push", "-q", "--no-verify", "origin", "main" });
    {
        var outcome = try relicUploadHead(fx, ours, .{});
        defer outcome.deinit();
        try expectNoFailures(&outcome);
        try testing.expectEqual(lfstransfer.Result.Status.transferred, outcome.results[0].status);
    }
    const oid = testlfs.sha256Hex(content);
    var path_buf: [256]u8 = undefined;
    const stored = try std.fmt.bufPrint(&path_buf, "served/local.git/lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });
    try expectFile(fx, fx.tmp.dir, stored, content);

    // git-lfs pulls it from there.
    const dest = try fx.path("theirs");
    defer gpa.free(dest);
    try fx.gitWith(fx.tmp.dir, &.{.{ "GIT_LFS_SKIP_SMUDGE", "1" }}, &.{ "clone", "-q", bare, dest });
    var theirs = try fx.tmp.dir.openDir(io, "theirs", .{});
    defer theirs.close(io);
    try fx.lfsFilters(theirs);
    try fx.gitIn(theirs, &.{ "lfs", "pull" });
    try expectFile(fx, theirs, "art/a.bin", content);

    // And relic pulls what git-lfs pushed there.
    const more = try noise(gpa, 30 * 1024, 7);
    defer gpa.free(more);
    try theirs.writeFile(io, .{ .sub_path = "more.bin", .data = more });
    try fx.gitIn(theirs, &.{ "add", "-A" });
    try fx.gitIn(theirs, &.{ "commit", "-q", "-m", "more" });
    try fx.gitIn(theirs, &.{ "lfs", "push", "origin", "main" });
    try fx.gitIn(theirs, &.{ "push", "-q", "--no-verify", "origin", "main" });
    try fx.gitWith(ours, &.{.{ "GIT_LFS_SKIP_SMUDGE", "1" }}, &.{ "pull", "-q", "--no-rebase", "origin", "main" });
    var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
    defer repo.deinit(io);
    const server = try openServer(fx, &repo);
    defer server.close();
    var pulled = try lfstransfer.pull(server, &repo, .{});
    defer pulled.deinit();
    try testing.expectEqual(@as(usize, 0), pulled.fetched.failures());
    try expectFile(fx, ours, "more.bin", more);
}

test "checkout fetches what the store lacks through the server, many at once, and says so on the calling task" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    var files: [12][2][]const u8 = undefined;
    var names: [12][16]u8 = undefined;
    var total: u64 = 0;
    for (&files, 0..) |*f, i| {
        f[0] = try std.fmt.bufPrint(&names[i], "f{d:0>2}.bin", .{i});
        f[1] = try noise(gpa, 10 * 1024 + i * 1000, 100 + i);
        total += f[1].len;
    }
    defer for (files) |f| gpa.free(f[1]);
    var ours = try committed(fx, "ours", nobody, &files);
    defer ours.close(io);
    {
        var outcome = try relicUploadHead(fx, ours, .{});
        defer outcome.deinit();
        try expectNoFailures(&outcome);
    }
    try emptyStore(fx, ours);
    for (files) |f| try ours.deleteFile(io, f[0]);

    var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
    defer repo.deinit(io);
    const server = try openServer(fx, &repo);
    defer server.close();
    const Heard = struct {
        objects: u64 = 0,
        bytes: u64 = 0,
        total: u64 = 0,
        calls: usize = 0,
        thread: std.Thread.Id,
        wrong_thread: bool = false,
        fn report(context: ?*anyopaque, event: progress_mod.Event) void {
            const h: *@This() = @ptrCast(@alignCast(context.?));
            h.calls += 1;
            if (std.Thread.getCurrentId() != h.thread) h.wrong_thread = true;
            switch (event) {
                .lfs_objects => |c| h.objects = c.done,
                .lfs_bytes => |c| {
                    h.bytes = c.done;
                    h.total = c.total;
                },
                else => {},
            }
        }
    };
    var heard: Heard = .{ .thread = std.Thread.getCurrentId() };
    var fetcher: lfstransfer.Fetcher = .{ .server = server, .options = .{
        .concurrency = 4,
        .progress = .{ .context = &heard, .report = Heard.report },
    } };
    defer fetcher.deinit();

    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var drivers = try repo.loadFilters(io, .{});
    defer drivers.deinit();
    var rules = repo.worktreeRules();
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = try repo.openIndex(io);
    defer index.deinit();
    const tree = (try repo.headTree(io)).?;
    const worktree = @import("worktree.zig");
    const outcome = try worktree.checkout(gpa, io, ours, &index, &repo.odb, tree, .{ .rules = rules, .lfs_fetch = fetcher.fetcher() });
    try testing.expectEqual(@as(u32, 0), outcome.lfs_pointers);
    for (files) |f| try expectFile(fx, ours, f[0], f[1]);
    try testing.expectEqual(@as(u64, files.len), heard.objects);
    try testing.expectEqual(total, heard.bytes);
    try testing.expectEqual(total, heard.total);
    try testing.expect(!heard.wrong_thread);
    try testing.expectEqual(@as(usize, 0), fetcher.last.?.failures());
}

test "the endpoint and its access are the ones git lfs env names" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const Case = struct { config: []const []const u8, lfsconfig: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .config = &.{ "remote.origin.url", "https://git.example.com/org/repo.git" } },
        .{ .config = &.{ "remote.origin.url", "https://git.example.com/org/repo" } },
        .{ .config = &.{ "remote.origin.url", "git@git.example.com:org/repo.git" } },
        .{ .config = &.{ "remote.origin.url", "ssh://ada@git.example.com:2222/org/repo" } },
        .{ .config = &.{ "remote.origin.url", "https://git.example.com/r.git", "remote.origin.lfsurl", "https://lfs.example.com/r" } },
        .{ .config = &.{ "remote.origin.url", "https://git.example.com/r.git", "lfs.url", "https://lfs.example.com/all", "lfs.https://lfs.example.com/.access", "basic" } },
        .{ .config = &.{ "remote.origin.url", "gh:org/r", "url.https://mirror.example.com/.insteadOf", "gh:" } },
        .{ .config = &.{ "remote.origin.url", "https://git.example.com/r.git" }, .lfsconfig = "[lfs]\n\turl = https://from-file.example.com/lfs\n" },
    };
    for (cases, 0..) |case, n| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "env{d}", .{n});
        var d = try fx.dir(name);
        defer d.close(io);
        try fx.gitIn(d, &.{ "init", "-q", "-b", "main" });
        var i: usize = 0;
        while (i < case.config.len) : (i += 2) try fx.gitIn(d, &.{ "config", case.config[i], case.config[i + 1] });
        if (case.lfsconfig) |text| try d.writeFile(io, .{ .sub_path = ".lfsconfig", .data = text });
        const env = try fx.gitOut(d, &.{ "lfs", "env" });
        defer gpa.free(env);
        const line_start = (std.mem.indexOf(u8, env, "\nEndpoint=") orelse return error.TestUnexpectedResult) + 1;
        const line = env[line_start .. std.mem.indexOfScalarPos(u8, env, line_start, '\n') orelse env.len];

        var repo = try repo_mod.Repository.open(gpa, io, d, .{});
        defer repo.deinit(io);
        const server = try openServer(fx, &repo);
        defer server.close();
        const e = try server.client.endpoint(.download);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const access = try server.settings.urlGet(arena_state.allocator(), "lfs", e.url, "access");
        const ours = try std.fmt.allocPrint(gpa, "Endpoint={s} (auth={s})", .{ e.url, access orelse "none" });
        defer gpa.free(ours);
        testing.expectEqualStrings(line, ours) catch |err| {
            std.debug.print("case {d}\n", .{n});
            return err;
        };
        if (e.ssh) |ssh| {
            const ssh_line = try std.fmt.allocPrint(gpa, "\n  SSH={s}:{s}\n", .{ ssh.user_and_host, ssh.path });
            defer gpa.free(ssh_line);
            try testing.expect(std.mem.indexOf(u8, env, ssh_line) != null);
        }
    }
}

test "a refused credential is erased, as git-lfs erases it, and the transfer says so" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .users = &.{.{ .name = "ada", .password = "secret" }} });
    defer fx.deinit();
    const wrong_git = try testlfs.credentialHelper(gpa, io, fx.tools, "wrong-git", "ada", "wrong");
    defer gpa.free(wrong_git);
    const wrong_relic = try testlfs.credentialHelper(gpa, io, fx.tools, "wrong-relic", "ada", "wrong");
    defer gpa.free(wrong_relic);
    const content = try noise(gpa, 20 * 1024, 8);
    defer gpa.free(content);
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    var ours = try committed(fx, "ours", wrong_relic, &.{.{ "a.bin", content }});
    defer ours.close(io);
    try fx.gitIn(ours, &.{ "push", "-q", "--no-verify", "origin", "main" });
    try emptyStore(fx, ours);

    var theirs = try fx.cloneRepo("theirs", wrong_git);
    defer theirs.close(io);
    const out = testlfs.git(gpa, io, theirs, &fx.env, &.{ "lfs", "fetch" }, false);
    if (out) |o| {
        gpa.free(o);
        return error.TestUnexpectedResult;
    } else |_| {}

    var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
    defer repo.deinit(io);
    const server = try openServer(fx, &repo);
    defer server.close();
    var fetched = try lfstransfer.fetch(server, &repo, .{});
    defer fetched.deinit();
    try testing.expectEqual(@as(usize, 1), fetched.failures());

    const theirs_log = try fx.tools.readFileAlloc(io, "wrong-git.log", gpa, .unlimited);
    defer gpa.free(theirs_log);
    const ours_log = try fx.tools.readFileAlloc(io, "wrong-relic.log", gpa, .unlimited);
    defer gpa.free(ours_log);
    try testing.expectEqualStrings(theirs_log, ours_log);
}
