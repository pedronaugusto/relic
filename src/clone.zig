//! `git clone`: a new repository with a remote, the remote's refs and
//! objects, and its default branch checked out.
//!
//! The steps are git's. The remote is asked first, because its answer
//! says which hash the new repository's objects are named with and which
//! branch its `HEAD` points at. The repository is then created with both,
//! its remote written to the configuration — the URL as given, a path made
//! absolute — and every branch and every tag fetched as one pack, checked
//! to be connected before any ref is written. The remote-tracking refs and
//! the tags go into `packed-refs`, as git writes them, with no logs; the
//! local branch, `HEAD` and `refs/remotes/<origin>/HEAD` are written with
//! `clone: from <url>`, and the branch gets its `remote` and `merge`
//! settings. Last, the branch's tree is checked out, with the attributes
//! the tree itself carries deciding line endings, and the index written.
//!
//! A shallow clone and a partial one are refused by name in this release.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const refs_mod = @import("refs.zig");
const repo_mod = @import("repo.zig");
const pack = @import("pack.zig");
const worktree = @import("worktree.zig");
const attributes = @import("attributes.zig");
const url_mod = @import("url.zig");
const program = @import("program.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const objectwalk = @import("objectwalk.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const progress_mod = @import("progress.zig");
const config_mod = @import("config.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a clone.
pub const Error = error{
    /// The destination holds something already. git refuses to clone into
    /// a directory that is not empty.
    DestinationNotEmpty,
    /// `Options.branch` names neither a branch nor a tag the remote has.
    RemoteBranchNotFound,
    /// A shallow clone, which is not in this release.
    ShallowUnsupported,
    /// A partial-clone filter, which is not in this release.
    PartialCloneUnsupported,
    /// An object below a fetched ref did not arrive.
    MissingObject,
    /// A remote name git would refuse.
    InvalidRemoteName,
} || transport.Error || repo_mod.Error || refs_mod.TransactionError || objectwalk.Error ||
    worktree.Error || config_mod.Config.SetError || Io.Dir.RealPathFileAllocError || Io.Dir.Iterator.Error;

/// How a clone runs.
pub const Options = struct {
    /// The remote's name in the new configuration: git's `--origin`.
    origin: []const u8 = "origin",
    /// The branch to check out, or a tag to check out detached, in place of
    /// the remote's `HEAD`: git's `--branch`.
    branch: ?[]const u8 = null,
    /// A repository with no working tree, whose branches are the remote's
    /// branches.
    bare: bool = false,
    /// Check the branch out.
    checkout: bool = true,
    /// Fetch the remote's tags, and let later fetches follow them.
    tags: bool = true,
    /// The branch `HEAD` names when the remote is empty and does not say
    /// which it would use.
    default_branch: []const u8 = "main",
    /// Who the reflog entries are written as, and when.
    who: object.Signature,
    /// `--depth`: refused by name in this release.
    depth: ?u32 = null,
    /// `--filter`: refused by name in this release.
    filter: ?[]const u8 = null,
    /// The permission to run programs, which an ssh remote and a
    /// credential helper need.
    programs: ?program.Programs = null,
    /// Settings that beat the new repository's own, as `git -c` gives them:
    /// `core.sshCommand`, `http.extraHeader` and the like, which the clone
    /// reads before the repository exists.
    config: ?*const config_mod.Config = null,
    prompt: ?credential.Prompt = null,
    /// Filled in, when the operation fails for want of a credential, with
    /// what a person needs to put it right: see `auth.Failure`.
    auth_failure: ?*auth.Failure = null,
    progress: ?progress_mod.Progress = null,
    /// Checks received objects the way git's `fsck` does.
    check_objects: bool = true,
    /// What the new repository's object database is opened with.
    odb: @import("odb.zig").Options = .{},
};

/// Clone `url` into `dir`, which must be empty, and return the new
/// repository, open.
pub fn clone(gpa: Allocator, io: Io, url: []const u8, dir: Io.Dir, options: Options) Error!Repository {
    if (options.depth != null) return error.ShallowUnsupported;
    if (options.filter != null) return error.PartialCloneUnsupported;
    if (!refspecNameOk(options.origin)) return error.InvalidRemoteName;
    {
        var it = dir.iterate();
        if (try it.next(io) != null) return error.DestinationNotEmpty;
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A path is recorded absolute, as git records it.
    const parsed = url_mod.Url.parse(url) catch |err| return err;
    const recorded = if (parsed.scheme == .local)
        try Io.Dir.cwd().realPathFileAlloc(io, url, arena)
    else
        url;

    var session = try transport.Session.open(gpa, io, url, .upload_pack, null, .{
        .programs = options.programs,
        .config = options.config,
        .progress = options.progress,
        .prompt = options.prompt,
        .auth_failure = options.auth_failure,
    });
    defer session.close(io);

    var remote_refs = try session.listRefs(gpa, io, &.{ "HEAD", "refs/heads/", "refs/tags/" });
    defer remote_refs.deinit();
    const remote_head = remote_refs.find("HEAD");

    // Which branch `HEAD` will name.
    var head_branch: ?[]const u8 = null;
    var detached: ?Oid = null;
    if (options.branch) |name| {
        const branch_ref = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{name});
        const tag_ref = try std.fmt.allocPrint(arena, "refs/tags/{s}", .{name});
        if (remote_refs.find(branch_ref) != null) {
            head_branch = branch_ref;
        } else if (remote_refs.find(tag_ref)) |tag| {
            detached = tag.peeled orelse tag.oid;
        } else return error.RemoteBranchNotFound;
    } else if (remote_head) |head| {
        if (head.symref_target) |target| {
            head_branch = try arena.dupe(u8, target);
        } else if (!head.unborn) {
            detached = head.oid;
        }
    }
    const initial = if (head_branch) |b|
        (if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else options.default_branch)
    else
        options.default_branch;

    var repo = try Repository.init(gpa, io, dir, .{
        .object_format = session.objectFormat(),
        .default_branch = initial,
        .bare = options.bare,
        .odb = options.odb,
    });
    errdefer repo.deinit(io);

    // The remote, in the new configuration.
    const origin = options.origin;
    try repo.config.set(try std.fmt.allocPrint(arena, "remote.{s}.url", .{origin}), recorded);
    if (!options.tags) try repo.config.set(try std.fmt.allocPrint(arena, "remote.{s}.tagopt", .{origin}), "--no-tags");
    if (!options.bare) {
        try repo.config.set(
            try std.fmt.allocPrint(arena, "remote.{s}.fetch", .{origin}),
            try std.fmt.allocPrint(arena, "+refs/heads/*:refs/remotes/{s}/*", .{origin}),
        );
    }

    // Every branch, and every tag unless asked not to.
    var wants: std.ArrayList(Oid) = .empty;
    var packed_entries: std.ArrayList(refs_mod.Store.PackedEntry) = .empty;
    for (remote_refs.refs) |ref| {
        if (ref.unborn) continue;
        const is_branch = std.mem.startsWith(u8, ref.name, "refs/heads/");
        const is_tag = std.mem.startsWith(u8, ref.name, "refs/tags/");
        if (!is_branch and !(is_tag and options.tags)) continue;
        if (std.mem.endsWith(u8, ref.name, "^{}")) continue;
        try addUnique(arena, &wants, ref.oid);
        const local_name = if (is_branch and !options.bare)
            try std.fmt.allocPrint(arena, "refs/remotes/{s}/{s}", .{ origin, ref.name["refs/heads/".len..] })
        else
            try arena.dupe(u8, ref.name);
        if (!@import("safepath.zig").isValidRefName(local_name)) continue;
        try packed_entries.append(arena, .{ .name = local_name, .oid = ref.oid, .peeled = ref.peeled });
    }
    if (detached) |oid| try addUnique(arena, &wants, oid);

    var pack_dir = try repo.common_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    const fetched = try session.fetch(gpa, io, &repo.odb, pack_dir, .{
        .wants = wants.items,
        .tips = &.{},
        .include_tag = options.tags,
    }, .{
        .progress = options.progress,
        .receive = .{ .check_objects = options.check_objects },
    });

    {
        var fresh: ?pack.Index = null;
        defer if (fresh) |*index| index.deinit();
        if (fetched.pack) |name| {
            var hex: [hash.max_hex_len]u8 = undefined;
            var idx_buf: [96]u8 = undefined;
            const idx_name = std.fmt.bufPrint(&idx_buf, "pack-{s}.idx", .{name.hex(&hex)}) catch unreachable;
            fresh = try pack.Index.open(gpa, io, pack_dir, idx_name, repo.kind, 1 << 30);
        }
        objectwalk.checkConnected(gpa, io, &repo.odb, wants.items, if (fresh) |*index| index else null, null) catch |err| switch (err) {
            error.MissingObject => return error.MissingObject,
            else => |e| return e,
        };
    }

    // The remote's refs, packed and with no logs, as git writes them.
    std.mem.sort(refs_mod.Store.PackedEntry, packed_entries.items, {}, struct {
        fn lessThan(_: void, a: refs_mod.Store.PackedEntry, b: refs_mod.Store.PackedEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    if (packed_entries.items.len != 0) try repo.refs.writePacked(io, packed_entries.items);

    const display = try url_mod.anonymize(arena, recorded);
    const message = try std.fmt.allocPrint(arena, "clone: from {s}", .{display});
    const log: refs_mod.LogMessage = .{ .who = options.who, .message = message, .policy = repo.reflogPolicy() };

    var head_commit: ?Oid = detached;
    if (head_branch) |branch| {
        if (remote_refs.find(branch)) |ref| {
            head_commit = ref.oid;
            var tx = repo.beginRefs();
            defer tx.deinit(io);
            if (!options.bare) try tx.update(branch, .{ .direct = ref.oid }, .any);
            try tx.update("HEAD", .{ .symbolic = branch }, .any);
            try tx.commit(io, log);
            if (!options.bare) {
                const short = branch["refs/heads/".len..];
                try repo.config.set(try std.fmt.allocPrint(arena, "branch.{s}.remote", .{short}), origin);
                try repo.config.set(try std.fmt.allocPrint(arena, "branch.{s}.merge", .{short}), branch);
            }
        }
    } else if (detached) |oid| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.change("HEAD", .{ .direct = oid }, .any, .{ .no_deref = true });
        try tx.commit(io, log);
    }
    // The remote's own `HEAD`, where it points at a branch, whatever was
    // checked out.
    if (!options.bare) {
        if (remote_head) |head| {
            if (head.symref_target) |target| {
                if (std.mem.startsWith(u8, target, "refs/heads/") and remote_refs.find(target) != null) {
                    var tx = repo.beginRefs();
                    defer tx.deinit(io);
                    const local_head = try std.fmt.allocPrint(arena, "refs/remotes/{s}/HEAD", .{origin});
                    const local_target = try std.fmt.allocPrint(arena, "refs/remotes/{s}/{s}", .{ origin, target["refs/heads/".len..] });
                    try tx.update(local_head, .{ .symbolic = local_target }, .must_not_exist);
                    try tx.commit(io, log);
                }
            }
        }
    }
    try repo.config.write(io, repo.common_dir, "config");

    if (!options.bare and options.checkout) {
        if (head_commit) |commit| try checkOut(gpa, io, &repo, commit);
    }
    return repo;
}

fn refspecNameOk(name: []const u8) bool {
    if (name.len == 0) return false;
    var buf: [512]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "refs/remotes/{s}/x", .{name}) catch return false;
    return @import("refspec.zig").checkRefFormat(probe, .{});
}

fn addUnique(arena: Allocator, list: *std.ArrayList(Oid), oid: Oid) Allocator.Error!void {
    for (list.items) |o| {
        if (o.eql(oid)) return;
    }
    try list.append(arena, oid);
}

/// Check out `commit`'s tree into the empty working tree, with the
/// attributes the tree carries, and write the index.
fn checkOut(gpa: Allocator, io: Io, repo: *Repository, commit: Oid) Error!void {
    const tree = try repo.commitTree(io, repo.peel(io, commit) catch commit);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    try loadTreeAttributes(gpa, io, repo, &attrs, tree);
    var rules = repo.worktreeRules();
    rules.attrs = &attrs;
    const required = try repo.requiredFilters(gpa);
    defer gpa.free(required);
    rules.required_filters = required;
    var index = try repo.openIndex(io);
    defer index.deinit();
    _ = try worktree.checkout(gpa, io, repo.work_dir.?, &index, &repo.odb, tree, .{ .rules = rules });
    try index.write(io, repo.git_dir, "index", .{});
}

/// Every `.gitattributes` the tree holds, at the depth it is found, which
/// is what git reads from the index when the working tree is still empty.
fn loadTreeAttributes(gpa: Allocator, io: Io, repo: *Repository, attrs: *attributes.Attrs, root: Oid) Error!void {
    const Item = struct { oid: Oid, path: []const u8, depth: u32 };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stack: std.ArrayList(Item) = .empty;
    try stack.append(arena, .{ .oid = root, .path = "", .depth = 0 });
    const keep = attrs.arena.allocator();
    while (stack.pop()) |item| {
        const found = try repo.odb.read(io, item.oid);
        defer repo.odb.gpa.free(found.bytes);
        var it = object.Tree.parse(repo.kind, found.bytes).iterate();
        while (try it.next()) |entry| {
            if (entry.mode == .tree) {
                const path = if (item.path.len == 0)
                    try arena.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ item.path, entry.name });
                try stack.append(arena, .{ .oid = entry.oid, .path = path, .depth = item.depth + 1 });
            } else if (entry.mode.isBlob() and std.mem.eql(u8, entry.name, ".gitattributes")) {
                const blob = try repo.odb.read(io, entry.oid);
                defer repo.odb.gpa.free(blob.bytes);
                const text = try keep.dupe(u8, blob.bytes);
                const base = try keep.dupe(u8, item.path);
                const source = try std.fmt.allocPrint(keep, "{s}{s}.gitattributes", .{ base, if (base.len == 0) "" else "/" });
                try attrs.addText(text, base, source, item.depth + 1);
            }
        }
    }
}

const builtin = @import("builtin");
const testing = std.testing;
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// Run git in `dir` with no configuration but the suite's.
fn git(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir, args: []const []const u8) ![]u8 {
    return testremote.gitInputEnv(gpa, io, dir, env, args, "", true);
}

/// The same, where failing is an answer — a ref that is not there — and
/// its output is then empty.
fn gitOrEmpty(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir, args: []const []const u8) ![]u8 {
    return testremote.gitInputEnv(gpa, io, dir, env, args, "", false) catch |err| switch (err) {
        error.GitFailed => gpa.dupe(u8, ""),
        else => err,
    };
}

/// Two clones, one by git and one by relic, leave the same refs, the same
/// remote and branch settings, the same reflog messages, the same index
/// and a clean working tree.
fn expectSameClone(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, a: Io.Dir, b: Io.Dir, bare: bool) !void {
    const Query = struct { args: []const []const u8 };
    const queries = [_]Query{
        .{ .args = &.{ "for-each-ref", "--format=%(refname) %(objectname) %(symref)" } },
        .{ .args = &.{ "symbolic-ref", "-q", "HEAD" } },
        .{ .args = &.{ "config", "--local", "--get-regexp", "^(remote|branch)\\." } },
    };
    for (queries) |q| {
        const theirs = try gitOrEmpty(gpa, io, env, a, q.args);
        defer gpa.free(theirs);
        const ours = try gitOrEmpty(gpa, io, env, b, q.args);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    if (!bare) {
        for ([_][]const []const u8{ &.{ "ls-files", "-s" }, &.{ "status", "--porcelain" } }) |args| {
            const theirs = try git(gpa, io, env, a, args);
            defer gpa.free(theirs);
            const ours = try git(gpa, io, env, b, args);
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
        for ([_][]const u8{ "HEAD", "refs/heads/main", "refs/remotes/origin/HEAD" }) |name| {
            const theirs = try gitOrEmpty(gpa, io, env, a, &.{ "reflog", "show", "--format=%gs", name });
            defer gpa.free(theirs);
            const ours = try gitOrEmpty(gpa, io, env, b, &.{ "reflog", "show", "--format=%gs", name });
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
    }
    const fsck = try git(gpa, io, env, b, &.{ "fsck", "--strict", "--no-dangling" });
    gpa.free(fsck);
}

const Twin = struct {
    tmp: testing.TmpDir,
    path: []u8,
    dir: Io.Dir,

    fn init(gpa: Allocator, io: Io) !Twin {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "clone");
        const dir = try tmp.dir.openDir(io, "clone", .{ .iterate = true });
        const base = try testremote.absolutePath(gpa, io, tmp.dir);
        defer gpa.free(base);
        return .{ .tmp = tmp, .path = try std.fmt.allocPrint(gpa, "{s}/clone", .{base}), .dir = dir };
    }

    fn deinit(t: *Twin, gpa: Allocator, io: Io) void {
        t.dir.close(io);
        gpa.free(t.path);
        t.tmp.cleanup();
    }
};

test "a clone from a local repository is the clone git makes, checked out, bare, and by branch or tag" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var source = try testremote.historyRepo(gpa, io, 4);
    defer source.deinit();
    // Attributes the tree carries decide what is checked out.
    try source.writeFile(io, ".gitattributes", "*.crlf text eol=crlf\n");
    try source.writeFile(io, "docs/x.crlf", "one\ntwo\n");
    try source.exec(io, &.{ "add", "-A" });
    try source.exec(io, &.{ "commit", "-q", "-m", "attributes" });
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);

    const Case = struct { git_args: []const []const u8, options: Options };
    const cases = [_]Case{
        .{ .git_args = &.{}, .options = .{ .who = test_who } },
        .{ .git_args = &.{"--bare"}, .options = .{ .who = test_who, .bare = true } },
        .{ .git_args = &.{ "--branch", "side" }, .options = .{ .who = test_who, .branch = "side" } },
        .{ .git_args = &.{ "--branch", "old" }, .options = .{ .who = test_who, .branch = "old" } },
        .{ .git_args = &.{ "--origin", "upstream", "--no-tags" }, .options = .{ .who = test_who, .origin = "upstream", .tags = false } },
    };
    for (cases) |case| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "clone", "-q" });
        try argv.appendSlice(gpa, case.git_args);
        try argv.appendSlice(gpa, &.{ source_path, by_git.path });
        const out = try git(gpa, io, &env, by_git.tmp.dir, argv.items);
        gpa.free(out);

        var repo = try clone(gpa, io, source_path, by_relic.dir, case.options);
        repo.deinit(io);
        try expectSameClone(gpa, io, &env, by_git.dir, by_relic.dir, case.options.bare);
        if (!case.options.bare and case.options.branch == null) {
            const theirs = try by_git.dir.readFileAlloc(io, "docs/x.crlf", gpa, .unlimited);
            defer gpa.free(theirs);
            const ours = try by_relic.dir.readFileAlloc(io, "docs/x.crlf", gpa, .unlimited);
            defer gpa.free(ours);
            try testing.expectEqualStrings("one\r\ntwo\r\n", ours);
            try testing.expectEqualStrings(theirs, ours);
        }
    }
}

test "a clone over ssh and over HTTP is the clone git makes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    {
        var source = try testremote.historyRepo(gpa, io, 3);
        defer source.deinit();
        const source_path = try testremote.absolutePath(gpa, io, source.dir);
        defer gpa.free(source_path);
        const root_path = try testremote.absolutePath(gpa, io, root.dir);
        defer gpa.free(root_path);
        const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
        defer gpa.free(bare);
        try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
    }
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const http_url = try server.url(gpa, "repo.git");
    defer gpa.free(http_url);
    const fake = try testremote.fakeSsh(gpa, io, root.dir);
    defer gpa.free(fake);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const ssh_url = try std.fmt.allocPrint(gpa, "ssh://example.invalid{s}/repo.git", .{root_path});
    defer gpa.free(ssh_url);

    var settings_text: std.ArrayList(u8) = .empty;
    defer settings_text.deinit(gpa);
    try settings_text.print(gpa, "[core]\nsshCommand = {s}\n", .{fake});
    var settings = try config_mod.Config.parseText(gpa, settings_text.items, .command);
    defer settings.deinit();
    const ssh_setting = try std.fmt.allocPrint(gpa, "core.sshCommand={s}", .{fake});
    defer gpa.free(ssh_setting);

    for ([_][]const u8{ http_url, ssh_url }) |url| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);
        const out = try git(gpa, io, &env, by_git.tmp.dir, &.{ "-c", ssh_setting, "clone", "-q", url, by_git.path });
        gpa.free(out);
        var repo = try clone(gpa, io, url, by_relic.dir, .{
            .who = test_who,
            .programs = .{ .environ = &env },
            .config = &settings,
        });
        repo.deinit(io);
        try expectSameClone(gpa, io, &env, by_git.dir, by_relic.dir, false);
    }
}

test "an empty remote clones to an unborn branch, as git's does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var empty = try testgit.Repo.init(gpa, io, &.{ "--bare", "--initial-branch=trunk" });
    defer empty.deinit();
    const empty_path = try testremote.absolutePath(gpa, io, empty.dir);
    defer gpa.free(empty_path);
    var by_git = try Twin.init(gpa, io);
    defer by_git.deinit(gpa, io);
    var by_relic = try Twin.init(gpa, io);
    defer by_relic.deinit(gpa, io);
    const out = git(gpa, io, &env, by_git.tmp.dir, &.{ "clone", "-q", empty_path, by_git.path }) catch |err| return err;
    gpa.free(out);
    var repo = try clone(gpa, io, empty_path, by_relic.dir, .{ .who = test_who });
    repo.deinit(io);
    const theirs = try git(gpa, io, &env, by_git.dir, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(theirs);
    const ours = try git(gpa, io, &env, by_relic.dir, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
}

test "a destination that is not empty, a shallow clone and a filtered one are refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "occupied", .data = "x" });
    try testing.expectError(error.DestinationNotEmpty, clone(gpa, io, "/nowhere", tmp.dir, .{ .who = test_who }));
    try testing.expectError(error.ShallowUnsupported, clone(gpa, io, "/nowhere", tmp.dir, .{ .who = test_who, .depth = 1 }));
    try testing.expectError(error.PartialCloneUnsupported, clone(gpa, io, "/nowhere", tmp.dir, .{ .who = test_who, .filter = "blob:none" }));
}
