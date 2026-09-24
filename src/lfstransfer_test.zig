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
    var logs: [2][]u8 = .{ &.{}, &.{} };
    defer for (logs) |l| gpa.free(l);
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

test "an action's URL is rewritten by insteadOf when git-lfs's setting asks, and an adapter relic lacks is refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .href_base = "http://objects.invalid" });
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const content = try noise(gpa, 8 * 1024, 9);
    defer gpa.free(content);
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    var ours = try committed(fx, "ours", nobody, &.{.{ "a.bin", content }});
    defer ours.close(io);
    try emptyStore(fx, ours);
    const real = try fx.server.url(gpa, "");
    defer gpa.free(real);
    const key = try std.fmt.allocPrint(gpa, "url.{s}.insteadOf", .{real[0 .. real.len - 1]});
    defer gpa.free(key);
    try fx.gitIn(ours, &.{ "config", key, "http://objects.invalid" });
    try fx.gitIn(ours, &.{ "config", "lfs.transfer.maxretries", "1" });

    for ([_]bool{ false, true }) |rewrite| {
        try fx.gitIn(ours, &.{ "config", "lfs.transfer.enablehrefrewrite", if (rewrite) "true" else "false" });
        var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
        defer repo.deinit(io);
        const server = try openServer(fx, &repo);
        defer server.close();
        var fetched = try lfstransfer.fetch(server, &repo, .{});
        defer fetched.deinit();
        try testing.expectEqual(@as(usize, if (rewrite) 0 else 1), fetched.failures());
    }

    fx.server.options.transfer = "tus";
    try emptyStore(fx, ours);
    var repo = try repo_mod.Repository.open(gpa, io, ours, .{});
    defer repo.deinit(io);
    const server = try openServer(fx, &repo);
    defer server.close();
    try testing.expectError(error.LfsTransferUnsupported, lfstransfer.fetch(server, &repo, .{}));
}

test "an .lfsconfig missing from the working tree is read from the index, then from HEAD, as git-lfs reads it, by the server and by checkout" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    var d = try fx.dir("r");
    defer d.close(io);
    try fx.gitIn(d, &.{ "init", "-q", "-b", "main" });
    try fx.gitIn(d, &.{ "config", "remote.origin.url", "https://git.example.com/r.git" });
    try d.writeFile(io, .{ .sub_path = ".lfsconfig", .data = "[lfs]\n\turl = https://from-head.example.com/lfs\n" });
    try fx.gitIn(d, &.{ "add", ".lfsconfig" });
    try fx.gitIn(d, &.{ "commit", "-q", "-m", "lfsconfig" });
    try d.writeFile(io, .{ .sub_path = ".lfsconfig", .data = "[lfs]\n\turl = https://from-index.example.com/lfs\n" });
    try fx.gitIn(d, &.{ "add", ".lfsconfig" });
    try d.writeFile(io, .{ .sub_path = ".lfsconfig", .data = "[lfs]\n\turl = https://from-tree.example.com/lfs\n" });

    const stages = [_]struct { step: ?[]const []const u8, want: []const u8 }{
        .{ .step = null, .want = "https://from-tree.example.com/lfs" },
        .{ .step = &.{"rm-file"}, .want = "https://from-index.example.com/lfs" },
        .{ .step = &.{ "rm", "-q", "--cached", ".lfsconfig" }, .want = "https://from-head.example.com/lfs" },
    };
    for (stages) |stage| {
        if (stage.step) |args| {
            if (args.len == 1) try d.deleteFile(io, ".lfsconfig") else try fx.gitIn(d, args);
        }
        const env = try fx.gitOut(d, &.{ "lfs", "env" });
        defer gpa.free(env);
        var want_buf: [128]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "\nEndpoint={s} (auth=none)\n", .{stage.want});
        try testing.expect(std.mem.indexOf(u8, env, want) != null);
        var repo = try repo_mod.Repository.open(gpa, io, d, .{});
        defer repo.deinit(io);
        const server = try openServer(fx, &repo);
        defer server.close();
        try testing.expectEqualStrings(stage.want, (try server.client.endpoint(.download)).url);
        // Checkout's own LFS, which smudges with `lfs.fetchinclude` and
        // `lfs.fetchexclude` from there, finds the same file.
        var drivers = try repo.loadFilters(io, .{});
        defer drivers.deinit();
        try testing.expectEqualStrings(stage.want, drivers.lfs.?.settings.url.?);
    }
}

test "with no remote named, the remote and the endpoint are the ones git-lfs picks, FETCH_HEAD included" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    var seed = try committed(fx, "seed", nobody, &.{.{ "a.bin", "a\n" }});
    defer seed.close(io);
    try fx.gitIn(seed, &.{ "lfs", "push", "origin", "main" });
    try fx.gitIn(seed, &.{ "push", "-q", "--no-verify", "origin", "main" });
    const served = try fx.url();
    defer gpa.free(served);
    const served_lfs = try std.fmt.allocPrint(gpa, "{s}/info/lfs", .{served});
    defer gpa.free(served_lfs);
    const dead = "http://127.0.0.1:1/dead.git";
    const oid = testlfs.sha256Hex("a\n");
    var object_buf: [128]u8 = undefined;
    const object_path = try std.fmt.bufPrint(&object_buf, ".git/lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });

    // The remote git-lfs picks is the one it fetches from: every other one
    // is a port nothing listens on.
    const Case = struct { name: []const u8, picked: []const u8, setup: []const []const []const u8 };
    const cases = [_]Case{
        .{ .name = "tracking", .picked = "other", .setup = &.{
            &.{ "remote", "add", "origin", dead },
            &.{ "remote", "add", "other", served },
            &.{ "config", "branch.main.remote", "other" },
        } },
        .{ .name = "lfsdefault", .picked = "second", .setup = &.{
            &.{ "remote", "add", "origin", dead },
            &.{ "remote", "add", "second", served },
            &.{ "config", "remote.lfsdefault", "second" },
        } },
        .{ .name = "single", .picked = "upstream", .setup = &.{
            &.{ "remote", "add", "upstream", served },
        } },
    };
    for (cases) |case| {
        var d = try fx.dir(case.name);
        defer d.close(io);
        try fx.gitIn(d, &.{ "init", "-q", "-b", "main" });
        for (case.setup) |args| try fx.gitIn(d, args);
        try fx.gitIn(d, &.{ "fetch", "-q", case.picked });
        var ref_buf: [64]u8 = undefined;
        try fx.gitIn(d, &.{ "reset", "-q", "--hard", try std.fmt.bufPrint(&ref_buf, "{s}/main", .{case.picked}) });
        try fx.gitIn(d, &.{ "lfs", "fetch" });
        try d.access(io, object_path, .{});

        var repo = try repo_mod.Repository.open(gpa, io, d, .{});
        defer repo.deinit(io);
        const server = try lfsapi.Server.open(gpa, io, &repo, null, .{ .programs = fx.programs() });
        defer server.close();
        try testing.expectEqualStrings(case.picked, server.remote);
        try testing.expectEqualStrings(served_lfs, (try server.client.endpoint(.download)).url);
    }

    // With no branch yet, and with no remote at all but a FETCH_HEAD, the
    // endpoint is the one git lfs env names for origin.
    const EnvCase = struct { name: []const u8, setup: []const []const []const u8 };
    const env_cases = [_]EnvCase{
        .{ .name = "tracking-unborn", .setup = &.{
            &.{ "remote", "add", "origin", "https://origin.example.com/r.git" },
            &.{ "remote", "add", "other", "https://other.example.com/r.git" },
            &.{ "config", "branch.main.remote", "other" },
        } },
        .{ .name = "fetch-head", .setup = &.{
            &.{ "fetch", "-q", served, "main" },
        } },
    };
    for (env_cases) |case| {
        var d = try fx.dir(case.name);
        defer d.close(io);
        try fx.gitIn(d, &.{ "init", "-q", "-b", "main" });
        for (case.setup) |args| try fx.gitIn(d, args);
        const env = try fx.gitOut(d, &.{ "lfs", "env" });
        defer gpa.free(env);
        const line_start = (std.mem.indexOf(u8, env, "\nEndpoint=") orelse return error.TestUnexpectedResult) + "\nEndpoint=".len;
        const line = env[line_start .. std.mem.indexOfScalarPos(u8, env, line_start, ' ') orelse env.len];
        var repo = try repo_mod.Repository.open(gpa, io, d, .{});
        defer repo.deinit(io);
        const server = try lfsapi.Server.open(gpa, io, &repo, null, .{ .programs = fx.programs() });
        defer server.close();
        try testing.expectEqualStrings(line, (try server.client.endpoint(.download)).url);
    }
}

test "a .netrc in the home directory is used before any helper, as git-lfs uses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .users = &.{.{ .name = "ada", .password = "secret" }} });
    defer fx.deinit();
    const content = try noise(gpa, 12 * 1024, 13);
    defer gpa.free(content);
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    var files: [2]Io.Dir = undefined;
    for ([_][]const u8{ "by-git", "by-relic" }, &files) |name, *d| {
        var helper_name: [32]u8 = undefined;
        const helper = try testlfs.credentialHelper(gpa, io, fx.tools, try std.fmt.bufPrint(&helper_name, "{s}-helper", .{name}), "ada", "wrong");
        defer gpa.free(helper);
        d.* = try committed(fx, name, helper, &.{.{ "a.bin", content }});
        try emptyStore(fx, d.*);
    }
    defer for (files) |d| d.close(io);
    var home = try fx.tmp.dir.openDir(io, "home", .{});
    defer home.close(io);
    try home.writeFile(io, .{ .sub_path = ".netrc", .data = "machine 127.0.0.1\n  login ada\n  password secret\n" });

    try fx.gitIn(files[0], &.{ "lfs", "fetch" });
    var repo = try repo_mod.Repository.open(gpa, io, files[1], .{});
    defer repo.deinit(io);
    const server = try openServer(fx, &repo);
    defer server.close();
    var fetched = try lfstransfer.fetch(server, &repo, .{});
    defer fetched.deinit();
    try expectNoFailures(&fetched);
    // Neither asked its helper, whose password is wrong.
    for ([_][]const u8{ "by-git-helper.log", "by-relic-helper.log" }) |log| {
        try testing.expectError(error.FileNotFound, fx.tools.access(io, log, .{}));
    }

    // A .netrc the server refuses is passed over for the helpers, by both.
    try home.writeFile(io, .{ .sub_path = ".netrc", .data = "machine 127.0.0.1 login ada password stale\n" });
    for ([_][]const u8{ "by-git", "by-relic" }) |name| {
        var helper_name: [32]u8 = undefined;
        const helper = try testlfs.credentialHelper(gpa, io, fx.tools, try std.fmt.bufPrint(&helper_name, "{s}-helper", .{name}), "ada", "secret");
        gpa.free(helper);
    }
    for (files) |d| try emptyStore(fx, d);
    try fx.gitIn(files[0], &.{ "lfs", "fetch" });
    const server2 = try openServer(fx, &repo);
    defer server2.close();
    var again = try lfstransfer.fetch(server2, &repo, .{});
    defer again.deinit();
    try expectNoFailures(&again);
    const theirs = try fx.tools.readFileAlloc(io, "by-git-helper.log", gpa, .unlimited);
    defer gpa.free(theirs);
    const ours = try fx.tools.readFileAlloc(io, "by-relic-helper.log", gpa, .unlimited);
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
}

test "a download that breaks off goes on from where it stopped, as git-lfs's does, and the name is checked over the whole" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const content = try noise(gpa, 300 * 1024, 14);
    defer gpa.free(content);
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    var dirs: [2]Io.Dir = undefined;
    for ([_][]const u8{ "by-git", "by-relic" }, &dirs) |name, *d| {
        d.* = try committed(fx, name, nobody, &.{.{ "a.bin", content }});
        try emptyStore(fx, d.*);
    }
    defer for (dirs) |d| d.close(io);

    // Each download breaks off half way once, and the retry asks for the
    // rest with the same Range.
    var logs: [2][]u8 = .{ &.{}, &.{} };
    defer for (logs) |l| gpa.free(l);
    for (dirs, 0..) |d, i| {
        fx.server.clearLog();
        try fx.server.fail(.{ .route = .download, .cut = true });
        if (i == 0) {
            try fx.gitIn(d, &.{ "lfs", "fetch" });
        } else {
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try openServer(fx, &repo);
            defer server.close();
            var fetched = try lfstransfer.fetch(server, &repo, .{});
            defer fetched.deinit();
            try expectNoFailures(&fetched);
        }
        const oid = testlfs.sha256Hex(content);
        var path_buf: [128]u8 = undefined;
        try expectFile(fx, d, try std.fmt.bufPrint(&path_buf, ".git/lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid }), content);
        const seen = try fx.server.requests(gpa);
        defer gpa.free(seen);
        const at = std.mem.indexOf(u8, seen, "range=") orelse return error.TestUnexpectedResult;
        logs[i] = try gpa.dupe(u8, seen[at..std.mem.indexOfScalarPos(u8, seen, at, '\n').?]);
    }
    try testing.expectEqualStrings(logs[0], logs[1]);
    try testing.expectEqualStrings("range=bytes=153600-307199", logs[1]);

    // A partial left by an earlier run is gone on from; one that is not
    // the object's beginning is thrown away and the object fetched whole.
    const oid = testlfs.sha256Hex(content);
    var part_buf: [160]u8 = undefined;
    const part = try std.fmt.bufPrint(&part_buf, ".git/lfs/incomplete/{s}.part", .{&oid});
    for ([_][]const u8{ content[0 .. 100 * 1024], "not the beginning of it" }) |partial| {
        try emptyStore(fx, dirs[1]);
        try dirs[1].createDirPath(io, ".git/lfs/incomplete");
        try dirs[1].writeFile(io, .{ .sub_path = part, .data = partial });
        var repo = try repo_mod.Repository.open(gpa, io, dirs[1], .{});
        defer repo.deinit(io);
        const server = try openServer(fx, &repo);
        defer server.close();
        var fetched = try lfstransfer.fetch(server, &repo, .{});
        defer fetched.deinit();
        try expectNoFailures(&fetched);
        try testing.expectError(error.FileNotFound, dirs[1].access(io, part, .{}));
    }
}

/// The object names in the store of the repository at `d`, sorted, one per
/// line. The caller's.
fn storeListing(fx: *Fixture, d: Io.Dir) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| fx.gpa.free(n);
        names.deinit(fx.gpa);
    }
    var objects = d.openDir(fx.io, ".git/lfs/objects", .{ .iterate = true }) catch return fx.gpa.dupe(u8, "");
    defer objects.close(fx.io);
    var walker = try objects.walk(fx.gpa);
    defer walker.deinit();
    while (try walker.next(fx.io)) |e| {
        if (e.kind == .file) try names.append(fx.gpa, try fx.gpa.dupe(u8, e.basename));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (names.items) |n| {
        try out.appendSlice(fx.gpa, n);
        try out.append(fx.gpa, '\n');
    }
    return out.toOwnedSlice(fx.gpa);
}

test "a recent fetch brings what git lfs fetch --recent brings, counted from the time the caller gives" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    // The suite reads the clock; the library is handed it.
    const now: i64 = @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const day = 86400;

    var seed = try fx.workRepo("seed", nobody);
    defer seed.close(io);
    try seed.writeFile(io, .{ .sub_path = ".gitattributes", .data = attributes });
    const Step = struct { days_ago: i64, path: []const u8, content: []const u8, branch: ?[]const []const u8 = null };
    const steps = [_]Step{
        .{ .days_ago = 20, .path = "big.bin", .content = "version one\n" },
        .{ .days_ago = 30, .path = "o.bin", .content = "an old branch's\n", .branch = &.{ "checkout", "-q", "-b", "old" } },
        .{ .days_ago = 10, .path = "big.bin", .content = "version two\n", .branch = &.{ "checkout", "-q", "main" } },
        .{ .days_ago = 3, .path = "big.bin", .content = "version three\n" },
        .{ .days_ago = 1, .path = "big.bin", .content = "version four\n" },
        .{ .days_ago = 2, .path = "r.bin", .content = "a recent branch's\n", .branch = &.{ "checkout", "-q", "-b", "recent" } },
    };
    for (steps) |step| {
        if (step.branch) |args| try fx.gitIn(seed, args);
        try seed.writeFile(io, .{ .sub_path = step.path, .data = step.content });
        try fx.gitIn(seed, &.{ "add", "-A" });
        var date_buf: [32]u8 = undefined;
        const date = try std.fmt.bufPrint(&date_buf, "@{d} +0000", .{now - step.days_ago * day});
        try fx.gitWith(seed, &.{ .{ "GIT_AUTHOR_DATE", date }, .{ "GIT_COMMITTER_DATE", date } }, &.{ "commit", "-q", "-m", step.path });
    }
    try fx.gitIn(seed, &.{ "checkout", "-q", "main" });
    try fx.gitIn(seed, &.{ "lfs", "push", "--all", "origin" });
    try fx.gitIn(seed, &.{ "push", "-q", "--no-verify", "--all", "origin" });

    var listings: [2][]u8 = .{ &.{}, &.{} };
    defer for (listings) |l| gpa.free(l);
    for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
        var d = try fx.cloneRepo(name, nobody);
        defer d.close(io);
        try fx.gitIn(d, &.{ "config", "lfs.fetchrecentcommitsdays", "5" });
        if (i == 0) {
            try fx.gitIn(d, &.{ "lfs", "fetch", "--recent" });
        } else {
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try openServer(fx, &repo);
            defer server.close();
            try testing.expectError(error.LfsRecentNeedsTime, lfstransfer.fetch(server, &repo, .{ .recent = true }));
            var fetched = try lfstransfer.fetch(server, &repo, .{ .recent = true, .now = now });
            defer fetched.deinit();
            try expectNoFailures(&fetched);
        }
        listings[i] = try storeListing(fx, d);
    }
    try testing.expectEqualStrings(listings[0], listings[1]);
    // The tips of main and of the recent branch, and the two versions the
    // last five days' commits replaced; nothing older.
    for ([_][]const u8{ "version four\n", "a recent branch's\n", "version three\n", "version two\n" }) |c| {
        try testing.expect(std.mem.indexOf(u8, listings[1], &testlfs.sha256Hex(c)) != null);
    }
    for ([_][]const u8{ "version one\n", "an old branch's\n" }) |c| {
        try testing.expect(std.mem.indexOf(u8, listings[1], &testlfs.sha256Hex(c)) == null);
    }
}

test "a clone made with --shared takes its objects from the other repository's store, linked, as git-lfs takes them" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    // The objects are only in the first repository's store: the server
    // has none, so an object asked of it fails.
    var seed = try committed(fx, "seed", nobody, &.{ .{ "a.bin", "shared once\n" }, .{ "b.bin", "shared twice\n" } });
    defer seed.close(io);
    const seed_path = try fx.path("seed");
    defer gpa.free(seed_path);
    const u = try fx.url();
    defer gpa.free(u);
    const oid = testlfs.sha256Hex("shared once\n");
    var path_buf: [128]u8 = undefined;
    const object_path = try std.fmt.bufPrint(&path_buf, ".git/lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });
    const seed_stat = try seed.statFile(io, object_path, .{});

    var listings: [2][]u8 = .{ &.{}, &.{} };
    defer for (listings) |l| gpa.free(l);
    for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
        const dest = try fx.path(name);
        defer gpa.free(dest);
        try fx.gitWith(fx.tmp.dir, &.{.{ "GIT_LFS_SKIP_SMUDGE", "1" }}, &.{ "clone", "-q", "--shared", seed_path, dest });
        var d = try fx.tmp.dir.openDir(io, name, .{ .iterate = true });
        defer d.close(io);
        try fx.lfsFilters(d);
        try fx.gitIn(d, &.{ "remote", "set-url", "origin", u });
        try fx.gitIn(d, &.{ "config", "credential.helper", nobody });
        fx.server.clearLog();
        if (i == 0) {
            try fx.gitIn(d, &.{ "lfs", "fetch" });
        } else {
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try openServer(fx, &repo);
            defer server.close();
            var fetched = try lfstransfer.fetch(server, &repo, .{});
            defer fetched.deinit();
            try expectNoFailures(&fetched);
        }
        const seen = try fx.server.requests(gpa);
        defer gpa.free(seen);
        try testing.expectEqualStrings("", seen);
        listings[i] = try storeListing(fx, d);
        // The same file, not a copy of it.
        try testing.expectEqual(seed_stat.inode, (try d.statFile(io, object_path, .{})).inode);
    }
    try testing.expectEqualStrings(listings[0], listings[1]);
    try testing.expect(std.mem.indexOf(u8, listings[1], &oid) != null);
    try testing.expect(std.mem.indexOf(u8, listings[1], &testlfs.sha256Hex("shared twice\n")) != null);
}

test "an upload is sent as the type its first bytes name, as git-lfs sends it, unless lfs.contenttype is false" {
    const gpa = testing.allocator;
    const io = testing.io;
    const binary = try noise(gpa, 2048, 21);
    defer gpa.free(binary);
    const files = [_][2][]const u8{
        .{ "image.bin", "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" },
        .{ "doc.bin", "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n" },
        .{ "page.bin", "\n  <html><body>hello</body></html>\n" },
        .{ "archive.bin", "PK\x03\x04\x14\x00\x00\x00" },
        .{ "words.bin", "just some words\n" },
        .{ "noise.bin", binary },
    };
    for ([_]?[]const u8{ null, "false" }) |setting| {
        var logs: [2][]u8 = .{ &.{}, &.{} };
        defer for (logs) |l| gpa.free(l);
        for (0..2) |i| {
            const fx = try Fixture.init(gpa, io, .{});
            defer fx.deinit();
            const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
            defer gpa.free(nobody);
            var d = try committed(fx, "work", nobody, &files);
            defer d.close(io);
            if (setting) |v| try fx.gitIn(d, &.{ "config", "lfs.contenttype", v });
            if (i == 0) {
                try fx.gitIn(d, &.{ "lfs", "push", "origin", "main" });
            } else {
                var outcome = try relicUploadHead(fx, d, .{});
                defer outcome.deinit();
                try expectNoFailures(&outcome);
            }
            logs[i] = try fx.server.objectHeaders(gpa);
        }
        try testing.expectEqualStrings(logs[0], logs[1]);
        const want: []const []const u8 = if (setting == null)
            &.{ "image/png", "application/pdf", "text/html; charset=utf-8", "application/zip", "text/plain; charset=utf-8", "application/octet-stream" }
        else
            &.{"application/octet-stream"};
        for (want) |t| {
            var buf: [64]u8 = undefined;
            try testing.expect(std.mem.indexOf(u8, logs[1], try std.fmt.bufPrint(&buf, "content-type={s}\n", .{t})) != null);
        }
    }
}

test "a download asks for gzip, or for zstd when lfs.transfer.httpDownloadEncoding says, as git-lfs's does, and comes out whole" {
    const gpa = testing.allocator;
    const io = testing.io;
    const content = try noise(gpa, 300 * 1024, 22);
    defer gpa.free(content);
    const oid = testlfs.sha256Hex(content);
    var path_buf: [128]u8 = undefined;
    const object_path = try std.fmt.bufPrint(&path_buf, ".git/lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });
    for ([_]?[]const u8{ null, "zstd", "brotli" }) |setting| {
        const fx = try Fixture.init(gpa, io, .{ .encode = true });
        defer fx.deinit();
        const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
        defer gpa.free(nobody);
        try fx.server.putObject(&oid, content);
        var logs: [2][]u8 = .{ &.{}, &.{} };
        defer for (logs) |l| gpa.free(l);
        for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
            var d = try committed(fx, name, nobody, &.{.{ "a.bin", content }});
            defer d.close(io);
            try emptyStore(fx, d);
            if (setting) |v| try fx.gitIn(d, &.{ "config", "lfs.transfer.httpDownloadEncoding", v });
            fx.server.clearLog();
            const refused = setting != null and std.mem.eql(u8, setting.?, "brotli");
            if (i == 0) {
                if (refused) {
                    try testing.expectError(error.GitFailed, testlfs.git(gpa, io, d, &fx.env, &.{ "lfs", "fetch" }, false));
                } else try fx.gitIn(d, &.{ "lfs", "fetch" });
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try openServer(fx, &repo);
                defer server.close();
                var fetched = try lfstransfer.fetch(server, &repo, .{});
                defer fetched.deinit();
                if (refused) {
                    try testing.expectEqual(@as(usize, 1), fetched.failures());
                    try testing.expectEqualStrings("unsupported lfs.transfer.httpDownloadEncoding value \"brotli\": must be \"gzip\" or \"zstd\"", fetched.results[0].message.?);
                } else try expectNoFailures(&fetched);
            }
            if (!refused) try expectFile(fx, d, object_path, content);
            logs[i] = try fx.server.objectHeaders(gpa);
        }
        try testing.expectEqualStrings(logs[0], logs[1]);
        if (setting == null) try testing.expect(std.mem.indexOf(u8, logs[1], "accept-encoding=gzip\n") != null);
        if (setting != null and std.mem.eql(u8, setting.?, "zstd")) try testing.expect(std.mem.indexOf(u8, logs[1], "accept-encoding=zstd\n") != null);
    }
}

test "an object checkout cannot get fails it, as git-lfs's smudge does, unless download errors are skipped" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    // The server has the first object and not the second.
    const here = "on the server\n";
    const gone = "nowhere at all\n";
    try fx.server.putObject(&testlfs.sha256Hex(here), here);
    var pointer_buf: [lfs.Pointer.max_encoded_len]u8 = undefined;
    const gone_pointer: lfs.Pointer = .{ .oid = testlfs.sha256Hex(gone), .size = gone.len };
    const gone_text = gone_pointer.encodeBuf(&pointer_buf);

    for ([_]bool{ false, true }) |skip| {
        for ([_][]const u8{ "by-git", "by-relic" }, 0..) |base, i| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}-{}", .{ base, skip });
            var d = try committed(fx, name, nobody, &.{ .{ "a.bin", here }, .{ "b.bin", gone } });
            defer d.close(io);
            try emptyStore(fx, d);
            try d.deleteFile(io, "a.bin");
            try d.deleteFile(io, "b.bin");
            if (skip) try fx.gitIn(d, &.{ "config", "lfs.skipdownloaderrors", "true" });
            if (i == 0) {
                const run = testlfs.git(gpa, io, d, &fx.env, &.{ "checkout", "--", "." }, false);
                if (skip) gpa.free(try run) else try testing.expectError(error.GitFailed, run);
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try openServer(fx, &repo);
                defer server.close();
                var fetcher: lfstransfer.Fetcher = .{ .server = server };
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
                const done = worktree.checkout(gpa, io, d, &index, &repo.odb, tree, .{ .rules = rules, .lfs_fetch = fetcher.fetcher() });
                if (skip) {
                    try testing.expectEqual(@as(u32, 1), (try done).lfs_pointers);
                } else {
                    try testing.expectError(error.LfsFetchFailed, done);
                }
                try testing.expectEqual(@as(usize, 1), fetcher.last.?.failures());
            }
            if (skip) {
                try expectFile(fx, d, "a.bin", here);
                try expectFile(fx, d, "b.bin", gone_text);
            }
        }
    }
}

test "every download's batch names the current branch's ref, as git-lfs's do, whatever is fetched" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const content = "named by a ref\n";
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    const Stage = struct { step: []const []const u8, refs: []const []const u8, want: []const u8 };
    const stages = [_]Stage{
        .{ .step = &.{ "branch", "other" }, .refs = &.{}, .want = "download \"refs/heads/main\"\n" },
        .{ .step = &.{ "config", "branch.main.merge", "refs/heads/trunk" }, .refs = &.{}, .want = "download \"refs/heads/trunk\"\n" },
        .{ .step = &.{ "config", "branch.main.merge", "refs/heads/trunk" }, .refs = &.{"other"}, .want = "download \"refs/heads/trunk\"\n" },
        .{ .step = &.{ "checkout", "-q", "--detach" }, .refs = &.{}, .want = "download \"HEAD\"\n" },
    };
    var dirs: [2]Io.Dir = undefined;
    for ([_][]const u8{ "by-git", "by-relic" }, &dirs) |name, *d| d.* = try committed(fx, name, nobody, &.{.{ "a.bin", content }});
    defer for (dirs) |d| d.close(io);
    for (stages) |stage| {
        var logs: [2][]u8 = .{ &.{}, &.{} };
        defer for (logs) |l| gpa.free(l);
        for (dirs, 0..) |d, i| {
            try fx.gitIn(d, stage.step);
            try emptyStore(fx, d);
            fx.server.clearLog();
            if (i == 0) {
                var args: std.ArrayList([]const u8) = .empty;
                defer args.deinit(gpa);
                try args.appendSlice(gpa, &.{ "lfs", "fetch" });
                if (stage.refs.len != 0) try args.append(gpa, "origin");
                try args.appendSlice(gpa, stage.refs);
                try fx.gitIn(d, args.items);
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try openServer(fx, &repo);
                defer server.close();
                var fetched = try lfstransfer.fetch(server, &repo, if (stage.refs.len != 0) .{ .refs = stage.refs } else .{});
                defer fetched.deinit();
                try expectNoFailures(&fetched);
            }
            logs[i] = try fx.server.batchRefs(gpa);
        }
        try testing.expectEqualStrings(logs[0], logs[1]);
        try testing.expectEqualStrings(stage.want, logs[1]);
    }
}

test "an upload whose action asks for chunks is sent in chunks, as git-lfs sends it" {
    const gpa = testing.allocator;
    const io = testing.io;
    const content = try noise(gpa, 200 * 1024, 23);
    defer gpa.free(content);
    var logs: [2][]u8 = .{ &.{}, &.{} };
    defer for (logs) |l| gpa.free(l);
    for (0..2) |i| {
        const fx = try Fixture.init(gpa, io, .{ .chunked_uploads = true });
        defer fx.deinit();
        const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
        defer gpa.free(nobody);
        var d = try committed(fx, "work", nobody, &.{.{ "a.bin", content }});
        defer d.close(io);
        if (i == 0) {
            try fx.gitIn(d, &.{ "lfs", "push", "origin", "main" });
        } else {
            var outcome = try relicUploadHead(fx, d, .{});
            defer outcome.deinit();
            try expectNoFailures(&outcome);
        }
        const stored = (try fx.server.object(gpa, &testlfs.sha256Hex(content))).?;
        defer gpa.free(stored);
        try testing.expectEqualSlices(u8, content, stored);
        logs[i] = try fx.server.objectHeaders(gpa);
    }
    try testing.expectEqualStrings(logs[0], logs[1]);
    try testing.expect(std.mem.indexOf(u8, logs[1], "transfer-encoding=chunked\n") != null);
    try testing.expect(std.mem.indexOf(u8, logs[1], "content-length=-\n") != null);
}

test "a proxy is chosen by git-lfs's rules, HTTP_PROXY included, and never for a loopback address" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const content = "fetched through a proxy\n";
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    // The API is on a host that only the proxy — the test server — can
    // reach; the actions it hands out are on 127.0.0.1, which goes direct.
    var proxy_buf: [64]u8 = undefined;
    const proxy = try std.fmt.bufPrint(&proxy_buf, "http://127.0.0.1:{d}", .{fx.server.port});
    var logs: [2][]u8 = .{ &.{}, &.{} };
    defer for (logs) |l| gpa.free(l);
    for ([_][]const u8{ "by-git", "by-relic" }, 0..) |name, i| {
        var d = try committed(fx, name, nobody, &.{.{ "a.bin", content }});
        defer d.close(io);
        try emptyStore(fx, d);
        try fx.gitIn(d, &.{ "config", "lfs.url", "http://lfs.example.invalid/repo.git/info/lfs" });
        fx.server.clearLog();
        if (i == 0) {
            try fx.gitWith(d, &.{.{ "HTTP_PROXY", proxy }}, &.{ "lfs", "fetch" });
        } else {
            var env = try fx.env.clone(gpa);
            defer env.deinit();
            try env.put("HTTP_PROXY", proxy);
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = .{ .environ = &env } });
            defer server.close();
            var fetched = try lfstransfer.fetch(server, &repo, .{});
            defer fetched.deinit();
            try expectNoFailures(&fetched);
        }
        logs[i] = try fx.server.requests(gpa);
    }
    try testing.expectEqualStrings(logs[0], logs[1]);
    try testing.expect(std.mem.indexOf(u8, logs[1], "POST /objects/batch anonymous proxied-for=lfs.example.invalid\n") != null);
    try testing.expect(std.mem.indexOf(u8, logs[1], "proxied-for=127.0.0.1") == null);
}

test "an https URL relic's client cannot reach as asked is refused by name before anything is sent" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    var d = try committed(fx, "r", nobody, &.{.{ "a.bin", "never sent\n" }});
    defer d.close(io);
    try emptyStore(fx, d);
    try fx.gitIn(d, &.{ "config", "lfs.url", "https://lfs.example.invalid/repo.git/info/lfs" });
    const Case = struct { config: ?[2][]const u8 = null, env: ?[2][]const u8 = null, want: anyerror };
    for ([_]Case{
        .{ .config = .{ "http.https://lfs.example.invalid.sslVerify", "false" }, .want = error.SslVerifyUnsupported },
        .{ .env = .{ "GIT_SSL_NO_VERIFY", "1" }, .want = error.SslVerifyUnsupported },
        .{ .config = .{ "http.sslCert", "/nowhere/cert.pem" }, .want = error.SslClientCertificateUnsupported },
        .{ .config = .{ "http.sslCAInfo", "/nowhere/ca.pem" }, .want = error.SslCertificateUnreadable },
        .{ .env = .{ "HTTPS_PROXY", "http://127.0.0.1:9" }, .want = error.HttpsProxyUnsupported },
        .{ .config = .{ "http.proxy", "socks5://127.0.0.1:9" }, .want = error.HttpsProxyUnsupported },
    }) |case| {
        if (case.config) |kv| try fx.gitIn(d, &.{ "config", kv[0], kv[1] });
        defer if (case.config) |kv| fx.gitIn(d, &.{ "config", "--unset", kv[0] }) catch {};
        var env = try fx.env.clone(gpa);
        defer env.deinit();
        if (case.env) |kv| try env.put(kv[0], kv[1]);
        var repo = try repo_mod.Repository.open(gpa, io, d, .{});
        defer repo.deinit(io);
        const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = .{ .environ = &env } });
        defer server.close();
        try testing.expectError(case.want, lfstransfer.fetch(server, &repo, .{}));
    }
    // A plain http URL through a proxy that is not an HTTP one.
    try fx.gitIn(d, &.{ "config", "lfs.url", "http://lfs.example.invalid/repo.git/info/lfs" });
    try fx.gitIn(d, &.{ "config", "http.proxy", "socks5://127.0.0.1:9" });
    var repo = try repo_mod.Repository.open(gpa, io, d, .{});
    defer repo.deinit(io);
    const server = try openServer(fx, &repo);
    defer server.close();
    try testing.expectError(error.InvalidProxy, lfstransfer.fetch(server, &repo, .{}));
}

test "a refused credential is described as git-lfs's helpers hear it, with the server's challenge" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .users = &.{.{ .name = "ada", .password = "secret" }} });
    defer fx.deinit();
    const content = "behind a password\n";
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    var logs: [2][]u8 = .{ &.{}, &.{} };
    defer for (logs) |l| gpa.free(l);
    for ([_][]const u8{ "git-helper", "relic-helper" }, 0..) |helper_name, i| {
        const helper = try testlfs.credentialHelperVerbatim(gpa, io, fx.tools, helper_name, "ada", "wrong");
        defer gpa.free(helper);
        var d = try committed(fx, helper_name, helper, &.{.{ "a.bin", content }});
        defer d.close(io);
        try emptyStore(fx, d);
        if (i == 0) {
            try testing.expectError(error.GitFailed, testlfs.git(gpa, io, d, &fx.env, &.{ "lfs", "fetch" }, false));
        } else {
            var failure: @import("auth.zig").Failure = .{};
            defer failure.deinit();
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = fx.programs(), .auth_failure = &failure });
            defer server.close();
            var fetched = try lfstransfer.fetch(server, &repo, .{});
            defer fetched.deinit();
            try testing.expectEqual(@as(usize, 1), fetched.failures());
            try testing.expectEqual(.refused, failure.reason);
            try testing.expectEqual(@as(?u16, 401), failure.status);
            try testing.expectEqualStrings("ada", failure.username.?);
            try testing.expectEqualStrings("Credentials needed", failure.server_message);
            try testing.expectEqual(@as(usize, 1), failure.challenges.len);
            try testing.expectEqualStrings("Basic realm=\"relic-lfs\"", failure.challenges[0]);
            try testing.expect(failure.helpers.len != 0);
            try testing.expectEqual(.credential, failure.helpers[0].answer);
        }
        var log_name: [64]u8 = undefined;
        const log = try fx.tools.readFileAlloc(io, try std.fmt.bufPrint(&log_name, "{s}.log", .{helper_name}), gpa, .unlimited);
        defer gpa.free(log);
        // What each `get` was told: the lines of every `get`, in order.
        var gets: std.ArrayList(u8) = .empty;
        errdefer gets.deinit(gpa);
        var blocks = std.mem.splitSequence(u8, log, "== ");
        while (blocks.next()) |block| {
            if (!std.mem.startsWith(u8, block, "get\n")) continue;
            try gets.appendSlice(gpa, "== ");
            try gets.appendSlice(gpa, block);
        }
        logs[i] = try gets.toOwnedSlice(gpa);
    }
    try testing.expectEqualStrings(logs[0], logs[1]);
    try testing.expect(std.mem.indexOf(u8, logs[1], "wwwauth[]=Basic realm=\"relic-lfs\"\n") != null);
}

test "a zstd body is decoded with the window its frame asks for, up to git-lfs's limit, as git-lfs decodes it" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .encode = true });
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    // Ten MiB in one segment is a ten MiB window; 128 MiB is declared by a
    // window descriptor; 1 GiB is past git-lfs's limit.
    const big = try noise(gpa, 10 << 20, 31);
    defer gpa.free(big);
    const Case = struct { content: []const u8, window_log: ?u6, ok: bool };
    for ([_]Case{
        .{ .content = big, .window_log = null, .ok = true },
        .{ .content = "declared wide\n", .window_log = 27, .ok = true },
        .{ .content = "declared too wide\n", .window_log = 30, .ok = false },
    }, 0..) |case, n| {
        fx.server.setZstdWindowLog(case.window_log);
        const oid = testlfs.sha256Hex(case.content);
        try fx.server.putObject(&oid, case.content);
        var path_buf: [128]u8 = undefined;
        const object_path = try std.fmt.bufPrint(&path_buf, ".git/lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], &oid });
        for ([_][]const u8{ "by-git", "by-relic" }, 0..) |base, i| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}-{d}", .{ base, n });
            var d = try committed(fx, name, nobody, &.{.{ "a.bin", case.content }});
            defer d.close(io);
            try emptyStore(fx, d);
            try fx.gitIn(d, &.{ "config", "lfs.transfer.httpDownloadEncoding", "zstd" });
            try fx.gitIn(d, &.{ "config", "lfs.transfer.maxretries", "1" });
            if (i == 0) {
                const run = testlfs.git(gpa, io, d, &fx.env, &.{ "lfs", "fetch" }, false);
                if (case.ok) gpa.free(try run) else try testing.expectError(error.GitFailed, run);
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try openServer(fx, &repo);
                defer server.close();
                var fetched = try lfstransfer.fetch(server, &repo, .{});
                defer fetched.deinit();
                if (case.ok) try expectNoFailures(&fetched) else {
                    try testing.expectEqual(@as(usize, 1), fetched.failures());
                    try testing.expectEqualStrings("the server's zstd frame asks for a window wider than 512 MiB", fetched.results[0].message.?);
                }
            }
            if (case.ok) try expectFile(fx, d, object_path, case.content) else try testing.expectError(error.FileNotFound, d.access(io, object_path, .{}));
        }
    }
}

fn nowSeconds(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

test "an action that expires within five seconds of the time given is not used, as git-lfs does not use it" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const content = "handed out expiring\n";
    try fx.server.putObject(&testlfs.sha256Hex(content), content);
    for ([_]testlfs.Server.Expiring{ .in, .at }, 0..) |kind, k| {
        var logs: [3][]u8 = .{ &.{}, &.{}, &.{} };
        defer for (logs) |l| gpa.free(l);
        for ([_][]const u8{ "by-git", "by-relic", "by-relic-untimed" }, 0..) |base, i| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}-{d}", .{ base, k });
            var d = try committed(fx, name, nobody, &.{.{ "a.bin", content }});
            defer d.close(io);
            try emptyStore(fx, d);
            fx.server.setExpiring(1, kind);
            fx.server.clearLog();
            if (i == 0) {
                try fx.gitIn(d, &.{ "lfs", "fetch" });
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = fx.programs(), .now = if (i == 1) nowSeconds(io) else null });
                defer server.close();
                var fetched = try lfstransfer.fetch(server, &repo, .{});
                defer fetched.deinit();
                try expectNoFailures(&fetched);
            }
            logs[i] = try fx.server.requests(gpa);
        }
        // git-lfs and relic with the time ask again for a fresh action;
        // relic without it uses the one it was given.
        try testing.expectEqualStrings(logs[0], logs[1]);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, logs[1], "POST /objects/batch"));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, logs[2], "POST /objects/batch"));
    }
}

test "a git-lfs-authenticate token is asked for again when it expires, lfs.defaulttokenttl included, as git-lfs asks" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{ .tokens = &.{.{ .token = "t0k3n", .user = "ada" }} });
    defer fx.deinit();
    const fake_ssh = try testremote.fakeSsh(gpa, io, fx.tools);
    defer gpa.free(fake_ssh);
    const href = try fx.server.url(gpa, "repo.git/info/lfs");
    defer gpa.free(href);
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const files = [_][2][]const u8{ .{ "a.bin", "first\n" }, .{ "b.bin", "second\n" }, .{ "c.bin", "third\n" } };
    for (files) |f| try fx.server.putObject(&testlfs.sha256Hex(f[1]), f[1]);
    const Case = struct { expiry: []const u8, ttl: ?[]const u8 = null, calls: usize };
    for ([_]Case{
        .{ .expiry = ",\"expires_in\":1", .calls = 3 },
        .{ .expiry = ",\"expires_at\":\"2000-01-01T00:00:00Z\"", .calls = 3 },
        .{ .expiry = "", .ttl = "1", .calls = 3 },
        .{ .expiry = "", .calls = 1 },
    }, 0..) |case, n| {
        const script = try testlfs.authenticateScriptExpiring(gpa, io, fx.tools, href, "t0k3n", case.expiry);
        gpa.free(script);
        var logs: [2][]u8 = .{ &.{}, &.{} };
        defer for (logs) |l| gpa.free(l);
        for ([_][]const u8{ "by-git", "by-relic" }, 0..) |base, i| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}-{d}", .{ base, n });
            var d = try committed(fx, name, nobody, &files);
            defer d.close(io);
            try emptyStore(fx, d);
            try fx.gitIn(d, &.{ "remote", "set-url", "origin", "ssh://git@example.invalid:2222/org/repo.git" });
            try fx.gitIn(d, &.{ "config", "core.sshCommand", fake_ssh });
            try fx.gitIn(d, &.{ "config", "lfs.sshtransfer", "never" });
            try fx.gitIn(d, &.{ "config", "lfs.transfer.batchSize", "1" });
            try fx.gitIn(d, &.{ "config", "lfs.concurrenttransfers", "1" });
            if (case.ttl) |ttl| try fx.gitIn(d, &.{ "config", "lfs.defaulttokenttl", ttl });
            fx.tools.deleteFile(io, "git-lfs-authenticate.log") catch {};
            if (i == 0) {
                try fx.gitIn(d, &.{ "lfs", "fetch" });
            } else {
                var repo = try repo_mod.Repository.open(gpa, io, d, .{});
                defer repo.deinit(io);
                const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = fx.programs(), .now = nowSeconds(io) });
                defer server.close();
                var fetched = try lfstransfer.fetch(server, &repo, .{});
                defer fetched.deinit();
                try expectNoFailures(&fetched);
            }
            logs[i] = try fx.tools.readFileAlloc(io, "git-lfs-authenticate.log", gpa, .unlimited);
        }
        try testing.expectEqualStrings(logs[0], logs[1]);
        try testing.expectEqual(case.calls, std.mem.count(u8, logs[1], "/org/repo.git download\n"));
    }
}

test "lfs/tmp is swept of what git-lfs sweeps from it, counted from the time given" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    const nobody = try testlfs.credentialHelper(gpa, io, fx.tools, "nobody", "no", "no");
    defer gpa.free(nobody);
    const present = testlfs.sha256Hex("in the store\n");
    const absent = testlfs.sha256Hex("not in the store\n");
    var listings: [3][]u8 = .{ &.{}, &.{}, &.{} };
    defer for (listings) |l| gpa.free(l);
    for ([_][]const u8{ "by-git", "by-relic", "by-relic-untimed" }, 0..) |name, i| {
        var d = try committed(fx, name, nobody, &.{.{ "a.bin", "in the store\n" }});
        defer d.close(io);
        const now = nowSeconds(io);
        const Entry = struct { path: []const u8, age_s: i64 };
        var present_name: [80]u8 = undefined;
        var absent_name: [80]u8 = undefined;
        const entries = [_]Entry{
            .{ .path = "old.tmp", .age_s = 7200 },
            .{ .path = "young.tmp", .age_s = 600 },
            .{ .path = try std.fmt.bufPrint(&present_name, "{s}-partial", .{&present}), .age_s = 600 },
            .{ .path = try std.fmt.bufPrint(&absent_name, "{s}-partial", .{&absent}), .age_s = 600 },
            .{ .path = "young-dir/old.tmp", .age_s = 7200 },
            .{ .path = "old-dir/old.tmp", .age_s = 7200 },
        };
        var tmp = try d.createDirPathOpen(io, ".git/lfs/tmp", .{});
        defer tmp.close(io);
        for (entries) |e| {
            if (std.fs.path.dirnamePosix(e.path)) |parent| try tmp.createDirPath(io, parent);
            try tmp.writeFile(io, .{ .sub_path = e.path, .data = "x" });
            try tmp.setTimestamps(io, e.path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, now - e.age_s) * std.time.ns_per_s } } });
        }
        try tmp.setTimestamps(io, "young-dir", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, now - 600) * std.time.ns_per_s } } });
        try tmp.setTimestamps(io, "old-dir", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, now - 7200) * std.time.ns_per_s } } });
        if (i == 0) {
            try fx.gitIn(d, &.{ "lfs", "fetch" });
        } else {
            var repo = try repo_mod.Repository.open(gpa, io, d, .{});
            defer repo.deinit(io);
            const server = try lfsapi.Server.open(gpa, io, &repo, "origin", .{ .programs = fx.programs(), .now = if (i == 1) now else null });
            defer server.close();
            var fetched = try lfstransfer.fetch(server, &repo, .{});
            defer fetched.deinit();
            try expectNoFailures(&fetched);
            try testing.expect(fetched.sweep_failed == null);
        }
        var names: std.ArrayList(u8) = .empty;
        errdefer names.deinit(gpa);
        var walker = try tmp.walk(gpa);
        defer walker.deinit();
        var found: std.ArrayList([]const u8) = .empty;
        defer {
            for (found.items) |f| gpa.free(f);
            found.deinit(gpa);
        }
        while (try walker.next(io)) |e| try found.append(gpa, try gpa.dupe(u8, e.path));
        std.mem.sort([]const u8, found.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (found.items) |f| {
            try names.appendSlice(gpa, f);
            try names.append(gpa, '\n');
        }
        listings[i] = try names.toOwnedSlice(gpa);
    }
    try testing.expectEqualStrings(listings[0], listings[1]);
    var want_buf: [256]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{s}-partial\nold-dir\nyoung-dir\nyoung-dir/old.tmp\nyoung.tmp\n", .{&absent});
    try testing.expectEqualStrings(want, listings[1]);
    // Without the time nothing is swept.
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, listings[2], "\n"));
}

test "a repeated .lfsconfig lookup is answered from what it was found from, and a change to any of that is seen" {
    const gpa = testing.allocator;
    const io = testing.io;
    const fx = try Fixture.init(gpa, io, .{});
    defer fx.deinit();
    var d = try fx.dir("r");
    defer d.close(io);
    try fx.gitIn(d, &.{ "init", "-q", "-b", "main" });
    var repo = try repo_mod.Repository.open(gpa, io, d, .{});
    defer repo.deinit(io);
    const Step = struct { run: ?[]const []const u8 = null, write: ?[]const u8 = null, remove: bool = false, want: ?[]const u8 };
    const steps = [_]Step{
        .{ .want = null },
        .{ .write = "[lfs]\n\turl = https://one/\n", .want = "[lfs]\n\turl = https://one/\n" },
        // The same size, written again: its times change.
        .{ .write = "[lfs]\n\turl = https://two/\n", .want = "[lfs]\n\turl = https://two/\n" },
        .{ .run = &.{ "add", ".lfsconfig" }, .want = "[lfs]\n\turl = https://two/\n" },
        .{ .remove = true, .want = "[lfs]\n\turl = https://two/\n" },
        .{ .run = &.{ "commit", "-q", "-m", "lfsconfig" }, .want = "[lfs]\n\turl = https://two/\n" },
        .{ .run = &.{ "rm", "-q", "--cached", ".lfsconfig" }, .want = "[lfs]\n\turl = https://two/\n" },
        .{ .run = &.{ "commit", "-q", "-m", "gone" }, .want = null },
    };
    for (steps) |step| {
        if (step.write) |text| try d.writeFile(io, .{ .sub_path = ".lfsconfig", .data = text });
        if (step.remove) try d.deleteFile(io, ".lfsconfig");
        if (step.run) |args| try fx.gitIn(d, args);
        // Twice: found, then handed out again.
        for (0..2) |_| {
            const text = try repo.lfsconfigText(io);
            defer if (text) |t| gpa.free(t);
            if (step.want) |w| try testing.expectEqualStrings(w, text.?) else try testing.expect(text == null);
        }
    }
    // A change the index alone shows: a new version staged over the file's.
    try d.writeFile(io, .{ .sub_path = ".lfsconfig", .data = "[lfs]\n\turl = https://staged/\n" });
    try fx.gitIn(d, &.{ "add", ".lfsconfig" });
    try d.deleteFile(io, ".lfsconfig");
    const staged = (try repo.lfsconfigText(io)).?;
    defer gpa.free(staged);
    try testing.expectEqualStrings("[lfs]\n\turl = https://staged/\n", staged);
}
