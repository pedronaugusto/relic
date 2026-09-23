//! Submodules against the real git.
//!
//! Every fixture is three repositories `git submodule add` put together: a
//! superproject with `vendor/lib`, which has `deep/inner` of its own, both
//! recorded with a url relative to the superproject's. What this does to one
//! clone is compared with what git does to a twin cloned from the same
//! place, through `git submodule status`, `git status --porcelain=v2`, the
//! configuration files byte for byte, and `git fsck`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const index_mod = @import("index.zig");
const submodule = @import("submodule.zig");
const program = @import("program.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;
const testing = std.testing;

const who: object.Signature = .{
    .name = "Fixture",
    .email = "fixture@example.com",
    .when_secs = 1_700_000_000,
    .offset_minutes = 0,
};

/// The name of a temporary repository's directory, which is a sibling of
/// every other one, so `../<name>` is a url from one to another.
fn dirName(r: *const testgit.Repo) []const u8 {
    return &r.tmp.sub_path;
}

fn absolute(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    var buf: [4096]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    const out = try gpa.dupe(u8, buf[0..len]);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// `inner`, `lib` holding it at `deep/inner`, and `super` holding `lib` at
/// `vendor/lib`, populated all the way down.
const Fixture = struct {
    inner: testgit.Repo,
    lib: testgit.Repo,
    super: testgit.Repo,

    fn init(gpa: Allocator, io: Io) !Fixture {
        var inner = try testgit.Repo.init(gpa, io, &.{});
        errdefer inner.deinit();
        try inner.writeFile(io, "i.txt", "inner\n");
        try inner.exec(io, &.{ "add", "-A" });
        try inner.exec(io, &.{ "commit", "-q", "-m", "inner" });

        var lib = try testgit.Repo.init(gpa, io, &.{});
        errdefer lib.deinit();
        try lib.writeFile(io, "l.txt", "lib\n");
        try lib.exec(io, &.{ "add", "-A" });
        const inner_url = try std.fmt.allocPrint(gpa, "../{s}", .{dirName(&inner)});
        defer gpa.free(inner_url);
        try lib.exec(io, &.{ "submodule", "add", "-q", inner_url, "deep/inner" });
        try lib.exec(io, &.{ "commit", "-q", "-m", "lib" });

        var super = try testgit.Repo.init(gpa, io, &.{});
        errdefer super.deinit();
        try super.writeFile(io, "s.txt", "super\n");
        try super.exec(io, &.{ "add", "-A" });
        try super.exec(io, &.{ "commit", "-q", "-m", "super" });
        const lib_url = try std.fmt.allocPrint(gpa, "../{s}", .{dirName(&lib)});
        defer gpa.free(lib_url);
        try super.exec(io, &.{ "submodule", "add", "-q", lib_url, "vendor/lib" });
        try super.exec(io, &.{ "commit", "-q", "-m", "add lib" });
        try super.exec(io, &.{ "submodule", "update", "-q", "--init", "--recursive" });
        return .{ .inner = inner, .lib = lib, .super = super };
    }

    fn deinit(f: *Fixture) void {
        f.super.deinit();
        f.lib.deinit();
        f.inner.deinit();
    }
};

/// A clone of a repository, in a directory of its own beside the others.
const Clone = struct {
    owner: testgit.Repo,
    git: testgit.Repo,

    fn init(gpa: Allocator, io: Io, from: *testgit.Repo, recursive: bool) !Clone {
        var owner = try testgit.Repo.init(gpa, io, &.{});
        errdefer owner.deinit();
        const url = try absolute(gpa, io, from.dir);
        defer gpa.free(url);
        if (recursive) {
            try owner.exec(io, &.{ "clone", "-q", "--recurse-submodules", url, "c" });
        } else {
            try owner.exec(io, &.{ "clone", "-q", url, "c" });
        }
        var git = owner;
        git.dir = try owner.dir.openDir(io, "c", .{ .iterate = true });
        return .{ .owner = owner, .git = git };
    }

    fn deinit(c: *Clone, io: Io) void {
        c.git.dir.close(io);
        c.owner.deinit();
    }

    fn open(c: *Clone, gpa: Allocator, io: Io) !Repository {
        return Repository.open(gpa, io, c.git.dir, .{ .discover = false });
    }
};

/// `git submodule status --recursive`, with the describe name git adds in
/// parentheses taken off each line.
fn gitSubmoduleStatus(gpa: Allocator, io: Io, git: *testgit.Repo) ![]u8 {
    const out = try git.run(io, &.{ "submodule", "status", "--recursive" });
    defer gpa.free(out);
    var kept: std.ArrayList(u8) = .empty;
    errdefer kept.deinit(gpa);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const end = std.mem.indexOf(u8, line, " (") orelse line.len;
        try kept.appendSlice(gpa, line[0..end]);
        try kept.append(gpa, '\n');
    }
    return kept.toOwnedSlice(gpa);
}

/// This package's `submodule.status`, printed the way git prints it.
fn relicSubmoduleStatus(gpa: Allocator, io: Io, repo: *Repository) ![]u8 {
    var result = try submodule.status(gpa, io, repo, .{ .recursive = true });
    defer result.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (result.entries) |entry| {
        var hex: [hash.max_hex_len]u8 = undefined;
        const line = try std.fmt.allocPrint(gpa, "{c}{s} {s}\n", .{ @intFromEnum(entry.state), entry.oid.hex(&hex), entry.path });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

fn expectSubmoduleStatusAgrees(gpa: Allocator, io: Io, git: *testgit.Repo, repo: *Repository) !void {
    const theirs = try gitSubmoduleStatus(gpa, io, git);
    defer gpa.free(theirs);
    const ours = try relicSubmoduleStatus(gpa, io, repo);
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
}

fn changeLetter(change: worktree.Change) u8 {
    return switch (change) {
        .unmodified, .untracked, .ignored => '.',
        .added => 'A',
        .modified => 'M',
        .deleted => 'D',
        .type_changed => 'T',
    };
}

/// `git status --porcelain=v2 --untracked-files=all`, reduced to what a
/// status entry here carries: `XY <sub> path` for a changed path and
/// `? path` for an untracked one, sorted.
fn gitPorcelainV2(gpa: Allocator, io: Io, git: *testgit.Repo) ![]u8 {
    const out = try git.run(io, &.{ "status", "--porcelain=v2", "--untracked-files=all" });
    defer gpa.free(out);
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '?') {
            try lines.append(gpa, try gpa.dupe(u8, line));
            continue;
        }
        if (line[0] != '1') continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next();
        const xy = fields.next().?;
        const sub = fields.next().?;
        for (0..5) |_| _ = fields.next();
        const path = fields.rest();
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ xy, sub, path }));
    }
    return joinSorted(gpa, lines.items);
}

/// `worktree.status` in `repo`, with the probe `submodule.StatusProbe`
/// gives it, reduced the same way.
fn relicPorcelainV2(gpa: Allocator, io: Io, repo: *Repository, options: submodule.StatusProbe.ProbeOptions) ![]u8 {
    var index = try repo.openIndex(io);
    defer index.deinit();
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var rules = repo.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    var probe = try submodule.StatusProbe.init(gpa, io, repo, &index, options);
    defer probe.deinit();
    var result = try worktree.status(gpa, io, repo.work_dir.?, &index, &repo.odb, .{
        .rules = rules,
        .head_tree = try repo.headTree(io),
        .untracked = .all,
        .submodules = probe.probe(),
    });
    defer result.deinit();

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (result.entries) |entry| {
        if (entry.unstaged == .untracked) {
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "? {s}", .{entry.path}));
            continue;
        }
        var sub: [4]u8 = "N...".*;
        if (entry.submodule) |state| {
            sub = .{
                'S',
                if (state.new_commits) 'C' else '.',
                if (state.modified_content) 'M' else '.',
                if (state.untracked_content) 'U' else '.',
            };
        }
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "{c}{c} {s} {s}", .{
            changeLetter(entry.staged), changeLetter(entry.unstaged), &sub, entry.path,
        }));
    }
    return joinSorted(gpa, lines.items);
}

fn joinSorted(gpa: Allocator, lines: [][]const u8) ![]u8 {
    std.mem.sort([]const u8, lines, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines) |line| {
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn expectPorcelainV2Agrees(gpa: Allocator, io: Io, git: *testgit.Repo, options: submodule.StatusProbe.ProbeOptions) !void {
    var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
    defer repo.deinit(io);
    const theirs = try gitPorcelainV2(gpa, io, git);
    defer gpa.free(theirs);
    const ours = try relicPorcelainV2(gpa, io, &repo, options);
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
}

fn readAt(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
}

fn expectSameFile(gpa: Allocator, io: Io, a: Io.Dir, b: Io.Dir, path: []const u8) !void {
    const left = try readAt(gpa, io, a, path);
    defer gpa.free(left);
    const right = try readAt(gpa, io, b, path);
    defer gpa.free(right);
    testing.expectEqualStrings(left, right) catch |err| {
        std.debug.print("{s} differs\n", .{path});
        return err;
    };
}

/// Open the repository again, for a test that changed its configuration
/// through git: a `Repository` holds what it read at open.
fn reopen(repo: *Repository, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    repo.deinit(io);
    repo.* = try Repository.open(gpa, io, dir, .{ .discover = false });
}

fn fsck(git: *testgit.Repo, io: Io) !void {
    try git.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
}

//=========================================================================
// .gitmodules and the layout
//=========================================================================

test "the fixture's layout is git's: a .git file, core.worktree, and modules nested in modules" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();

    const dot_git = try readAt(gpa, io, f.super.dir, "vendor/lib/.git");
    defer gpa.free(dot_git);
    try testing.expectEqualStrings("gitdir: ../../.git/modules/vendor/lib\n", dot_git);
    const nested = try readAt(gpa, io, f.super.dir, "vendor/lib/deep/inner/.git");
    defer gpa.free(nested);
    try testing.expectEqualStrings("gitdir: ../../../../.git/modules/vendor/lib/modules/deep/inner\n", nested);

    // A submodule's repository opens through its `.git` file.
    var repo = try Repository.open(gpa, io, f.super.dir, .{ .discover = false });
    defer repo.deinit(io);
    var lib_dir = try f.super.dir.openDir(io, "vendor/lib", .{});
    defer lib_dir.close(io);
    var lib = try Repository.open(gpa, io, lib_dir, .{ .discover = false });
    defer lib.deinit(io);
    const lib_head = (try lib.head(io)).?;
    gpa.free(lib_head.name);

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try submodule.list(gpa, io, &repo, &index, null);
    defer listing.deinit();
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
    try testing.expectEqualStrings("vendor/lib", listing.entries[0].path);
    try testing.expectEqualStrings("vendor/lib", listing.entries[0].name().?);
    const recorded = try f.super.line(io, &.{ "rev-parse", "HEAD:vendor/lib" });
    defer gpa.free(recorded);
    try testing.expect(listing.entries[0].recorded.?.eql(try Oid.parse(.sha1, recorded)));
}

test ".gitmodules is read from the index, then from HEAD, when the working tree has none" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var repo = try Repository.open(gpa, io, f.super.dir, .{ .discover = false });
    defer repo.deinit(io);

    try f.super.dir.deleteFile(io, ".gitmodules");
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        var modules = try submodule.loadGitmodules(gpa, io, &repo, &index);
        defer modules.deinit();
        try testing.expect(modules.byPath("vendor/lib") != null);
    }
    try f.super.exec(io, &.{ "rm", "-q", "--cached", ".gitmodules" });
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        var modules = try submodule.loadGitmodules(gpa, io, &repo, &index);
        defer modules.deinit();
        try testing.expect(modules.byPath("vendor/lib") != null);
    }
    try f.super.exec(io, &.{ "commit", "-q", "-m", "no gitmodules" });
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        var modules = try submodule.loadGitmodules(gpa, io, &repo, &index);
        defer modules.deinit();
        try testing.expectEqual(@as(usize, 0), modules.submodules.len);
        // And a gitlink nothing names is refused by name, as git refuses it.
        var refusal: submodule.Refusal = .{};
        try testing.expectError(error.NoSubmoduleMapping, submodule.status(gpa, io, &repo, .{ .refusal = &refusal }));
        try testing.expectEqualStrings("vendor/lib", refusal.path());
    }
}

//=========================================================================
// Gitlinks in the working tree
//=========================================================================

test "a moved submodule is staged as git add -A stages it, and the tree is git's" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var repo = try Repository.open(gpa, io, f.super.dir, .{ .discover = false });
    defer repo.deinit(io);

    var lib = f.super;
    lib.dir = try f.super.dir.openDir(io, "vendor/lib", .{});
    defer lib.dir.close(io);
    try lib.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "moved" });
    // Something in the directory that is not the submodule's business.
    try f.super.writeFile(io, "vendor/lib/untracked.txt", "x\n");

    var index = try repo.openIndex(io);
    defer index.deinit();
    const outcome = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = repo.worktreeRules() });
    try testing.expectEqual(@as(u32, 1), outcome.gitlinks_moved);
    try testing.expect(index.find("vendor/lib/untracked.txt") == null);
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);

    try f.super.exec(io, &.{ "add", "-A" });
    const theirs = try f.super.line(io, &.{"write-tree"});
    defer gpa.free(theirs);
    var hex: [hash.max_hex_len]u8 = undefined;
    try testing.expectEqualStrings(theirs, tree.hex(&hex));
}

test "an unpopulated submodule stays recorded, and a removed one is staged as removed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var c = try Clone.init(gpa, io, &f.super, false);
    defer c.deinit(io);
    var repo = try c.open(gpa, io);
    defer repo.deinit(io);

    // Unpopulated, with a file git does not look at in the empty directory.
    try c.git.writeFile(io, "vendor/lib/junk", "junk\n");
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        _ = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = repo.worktreeRules() });
        try testing.expect(index.find("vendor/lib").?.mode == .gitlink);
        try testing.expect(index.find("vendor/lib/junk") == null);
        const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
        try testing.expect(tree.eql((try repo.headTree(io)).?));

        var listing = try worktree.list(gpa, io, repo.work_dir.?, &index, repo.worktreeRules());
        defer listing.deinit();
        const others = try c.git.run(io, &.{ "ls-files", "-o" });
        defer gpa.free(others);
        try testing.expectEqual(@as(usize, 0), listing.untracked().len);
        try testing.expectEqualStrings("", others);
    }
    try expectPorcelainV2Agrees(gpa, io, &c.git, .{});

    // Gone altogether: git stages the gitlink's removal.
    try c.git.dir.deleteTree(io, "vendor/lib");
    try expectPorcelainV2Agrees(gpa, io, &c.git, .{});
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        _ = try worktree.addAll(gpa, io, repo.work_dir.?, &index, &repo.odb, .{ .rules = repo.worktreeRules() });
        try testing.expect(index.find("vendor/lib") == null);
        const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
        try c.git.exec(io, &.{ "add", "-A" });
        const theirs = try c.git.line(io, &.{"write-tree"});
        defer gpa.free(theirs);
        var hex: [hash.max_hex_len]u8 = undefined;
        try testing.expectEqualStrings(theirs, tree.hex(&hex));
    }
}

test "checkout makes an empty directory for a gitlink and takes an empty one away" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var c = try Clone.init(gpa, io, &f.super, false);
    defer c.deinit(io);
    var repo = try c.open(gpa, io);
    defer repo.deinit(io);

    const before_text = try c.git.line(io, &.{ "rev-parse", "HEAD~1^{tree}" });
    defer gpa.free(before_text);
    const before = try Oid.parse(.sha1, before_text);
    const with_lib = (try repo.headTree(io)).?;

    var index = try repo.openIndex(io);
    defer index.deinit();
    _ = try worktree.checkout(gpa, io, repo.work_dir.?, &index, &repo.odb, before, .{ .rules = repo.worktreeRules() });
    try testing.expect((try @import("fs.zig").statAt(io, repo.work_dir.?, "vendor/lib")) == null);
    const outcome = try worktree.checkout(gpa, io, repo.work_dir.?, &index, &repo.odb, with_lib, .{ .rules = repo.worktreeRules() });
    try testing.expectEqual(@as(u32, 1), outcome.gitlinks);
    const found = (try @import("fs.zig").statAt(io, repo.work_dir.?, "vendor/lib")).?;
    try testing.expectEqual(Io.File.Kind.directory, found.kind);
    try index.write(io, repo.git_dir, "index", .{});
    try expectPorcelainV2Agrees(gpa, io, &c.git, .{});
}

//=========================================================================
// Status
//=========================================================================

test "the superproject's status reports each submodule state as git status --porcelain=v2 does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var lib = f.super;
    lib.dir = try f.super.dir.openDir(io, "vendor/lib", .{});
    defer lib.dir.close(io);
    var inner = f.super;
    inner.dir = try f.super.dir.openDir(io, "vendor/lib/deep/inner", .{});
    defer inner.dir.close(io);

    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});

    // Untracked content.
    try lib.writeFile(io, "u.txt", "u\n");
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    // Modified content too.
    try lib.writeFile(io, "l.txt", "changed\n");
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    try lib.exec(io, &.{ "checkout", "-q", "l.txt" });
    try lib.dir.deleteFile(io, "u.txt");

    // Only a submodule of the submodule has an untracked file: untracked
    // content above, not modified.
    try inner.writeFile(io, "x.txt", "x\n");
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    try inner.dir.deleteFile(io, "x.txt");
    // Modified two levels down is modified at the top.
    try inner.writeFile(io, "i.txt", "changed\n");
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    try inner.exec(io, &.{ "checkout", "-q", "i.txt" });

    // New commits, and each ignore setting over all three kinds of change.
    try lib.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "moved" });
    try lib.writeFile(io, "u.txt", "u\n");
    try lib.writeFile(io, "l.txt", "changed\n");
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    for ([_][]const u8{ "all", "dirty", "untracked", "none" }) |value| {
        try f.super.exec(io, &.{ "config", "submodule.vendor/lib.ignore", value });
        try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    }
    try f.super.exec(io, &.{ "config", "--unset", "submodule.vendor/lib.ignore" });
    // From .gitmodules, and from diff.ignoreSubmodules, which the file beats.
    try f.super.exec(io, &.{ "config", "diff.ignoreSubmodules", "dirty" });
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    try f.super.exec(io, &.{ "config", "-f", ".gitmodules", "submodule.vendor/lib.ignore", "untracked" });
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    try f.super.exec(io, &.{ "config", "--unset", "diff.ignoreSubmodules" });
    try f.super.exec(io, &.{ "checkout", "-q", ".gitmodules" });

    // A staged gitlink change shows whatever the setting says.
    try f.super.exec(io, &.{ "add", "vendor/lib" });
    try f.super.exec(io, &.{ "config", "submodule.vendor/lib.ignore", "all" });
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});
    try f.super.exec(io, &.{ "config", "--unset", "submodule.vendor/lib.ignore" });
    try expectPorcelainV2Agrees(gpa, io, &f.super, .{});

    // `--ignore-submodules=all` beats everything, the staged change too.
    const theirs = try f.super.run(io, &.{ "status", "--porcelain=v2", "--untracked-files=all", "--ignore-submodules=all" });
    defer gpa.free(theirs);
    var repo = try Repository.open(gpa, io, f.super.dir, .{ .discover = false });
    defer repo.deinit(io);
    const ours = try relicPorcelainV2(gpa, io, &repo, .{ .ignore = .all });
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
}

test "git submodule status and this agree in every state" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();

    var c = try Clone.init(gpa, io, &f.super, false);
    defer c.deinit(io);
    var repo = try c.open(gpa, io);
    defer repo.deinit(io);
    // Not initialised.
    try expectSubmoduleStatusAgrees(gpa, io, &c.git, &repo);
    // Initialised, not populated.
    try c.git.exec(io, &.{ "submodule", "init" });
    repo.deinit(io);
    repo = try c.open(gpa, io);
    try expectSubmoduleStatusAgrees(gpa, io, &c.git, &repo);
    // Populated, recursively: the nested one is listed under its parent.
    try c.git.exec(io, &.{ "submodule", "update", "-q", "--init", "--recursive" });
    try expectSubmoduleStatusAgrees(gpa, io, &c.git, &repo);
    // Moved, at both depths.
    var lib = c.git;
    lib.dir = try c.git.dir.openDir(io, "vendor/lib", .{});
    defer lib.dir.close(io);
    try lib.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "moved" });
    var inner = c.git;
    inner.dir = try c.git.dir.openDir(io, "vendor/lib/deep/inner", .{});
    defer inner.dir.close(io);
    try inner.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "moved too" });
    try expectSubmoduleStatusAgrees(gpa, io, &c.git, &repo);

    // Unmerged in the superproject: two sides moving it to two commits
    // neither of which descends from the other.
    const recorded = try c.git.line(io, &.{ "rev-parse", "HEAD:vendor/lib" });
    defer gpa.free(recorded);
    try c.git.exec(io, &.{ "checkout", "-q", "-b", "other" });
    try c.git.exec(io, &.{ "add", "vendor/lib" });
    try c.git.exec(io, &.{ "commit", "-q", "-m", "one side" });
    try c.git.exec(io, &.{ "checkout", "-q", "main" });
    try lib.exec(io, &.{ "checkout", "-q", "--detach", recorded });
    try lib.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "the other side" });
    try c.git.exec(io, &.{ "add", "vendor/lib" });
    try c.git.exec(io, &.{ "commit", "-q", "-m", "other side" });
    c.git.report_failures = false;
    c.git.exec(io, &.{ "merge", "-q", "other" }) catch {};
    c.git.report_failures = true;
    const unmerged = try c.git.run(io, &.{ "ls-files", "-u" });
    defer gpa.free(unmerged);
    try testing.expect(unmerged.len > 0);
    const theirs = try c.git.run(io, &.{ "submodule", "status" });
    defer gpa.free(theirs);
    var result = try submodule.status(gpa, io, &repo, .{});
    defer result.deinit();
    try testing.expectEqual(submodule.State.conflict, result.entries[0].state);
    try testing.expect(std.mem.startsWith(u8, theirs, "U0000000000000000000000000000000000000000 vendor/lib"));
}

//=========================================================================
// init, sync, deinit, absorbgitdirs
//=========================================================================

test "init writes .git/config byte for byte as git submodule init writes it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    try f.super.exec(io, &.{ "config", "-f", ".gitmodules", "submodule.vendor/lib.update", "rebase" });
    try f.super.exec(io, &.{ "commit", "-q", "-am", "rebase it" });

    var ours = try Clone.init(gpa, io, &f.super, false);
    defer ours.deinit(io);
    var theirs = try Clone.init(gpa, io, &f.super, false);
    defer theirs.deinit(io);
    var repo = try ours.open(gpa, io);
    defer repo.deinit(io);

    const outcome = try submodule.init(gpa, io, &repo, .{});
    try testing.expectEqual(@as(u32, 1), outcome.registered);
    try testing.expectEqual(@as(u32, 1), outcome.activated);
    try theirs.git.exec(io, &.{ "submodule", "init" });
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");
    // What was written is what the repository now reads.
    try testing.expect(repo.config.get("submodule.vendor/lib.url") != null);
    try expectSubmoduleStatusAgrees(gpa, io, &ours.git, &repo);

    // A second run changes nothing.
    const again = try submodule.init(gpa, io, &repo, .{});
    try testing.expectEqual(@as(u32, 0), again.registered + again.activated);
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");
}

test "a name holding a quote and a backslash is registered, synced and removed as git does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    try f.super.exec(io, &.{ "config", "-f", ".gitmodules", "--rename-section", "submodule.vendor/lib", "submodule.we\"ird\\name" });
    try f.super.exec(io, &.{ "commit", "-q", "-am", "rename it" });

    var ours = try Clone.init(gpa, io, &f.super, false);
    defer ours.deinit(io);
    var theirs = try Clone.init(gpa, io, &f.super, false);
    defer theirs.deinit(io);
    var repo = try ours.open(gpa, io);
    defer repo.deinit(io);

    const outcome = try submodule.init(gpa, io, &repo, .{});
    try testing.expectEqual(@as(u32, 1), outcome.registered);
    try theirs.git.exec(io, &.{ "submodule", "init" });
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");
    try testing.expect(repo.config.get("submodule.we\"ird\\name.url") != null);

    for ([_]*testgit.Repo{ &ours.git, &theirs.git }) |g| {
        try g.exec(io, &.{ "config", "-f", ".gitmodules", "submodule.we\"ird\\name.url", "../elsewhere/lib" });
    }
    _ = try submodule.sync(gpa, io, &repo, .{});
    try theirs.git.exec(io, &.{ "submodule", "sync", "-q" });
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");

    const removed = try submodule.deinitialize(gpa, io, &repo, .{ .force = true });
    try testing.expectEqual(@as(u32, 1), removed.unregistered);
    try theirs.git.exec(io, &.{ "submodule", "deinit", "-q", "-f", "--all" });
    // git finds the section to remove with `--get-regexp` over the name,
    // where `\n` is not a backslash and an `n`, so it leaves this one
    // behind; the section `git config --remove-section` names is the one
    // taken here.
    try theirs.git.exec(io, &.{ "config", "--remove-section", "submodule.we\"ird\\name" });
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");
    try testing.expect(repo.config.get("submodule.we\"ird\\name.url") == null);
}

test "a relative url resolves against the default remote, or against the superproject itself" {
    const gpa = testing.allocator;
    const io = testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "update-index", "--add", "--cacheinfo", "160000," ++ "1" ** 40 ++ ",a" });
    try git.writeFile(io, ".gitmodules", "[submodule \"a\"]\n\tpath = a\n\turl = ../x/y\n");
    try git.exec(io, &.{ "add", ".gitmodules" });
    try git.exec(io, &.{ "commit", "-q", "-m", "a" });

    const Case = struct { setup: []const []const []const u8 };
    const cases = [_]Case{
        // No remote at all: the superproject's own path.
        .{ .setup = &.{} },
        // One remote, whatever its name.
        .{ .setup = &.{&.{ "remote", "add", "upstream", "https://h/p/q.git" }} },
        // Two, and no origin: the path again.
        .{ .setup = &.{&.{ "remote", "add", "other", "user@host:r/s" }} },
        // The branch's own remote.
        .{ .setup = &.{&.{ "config", "branch.main.remote", "other" }} },
        // Detached, with two: origin, which is not there.
        .{ .setup = &.{&.{ "checkout", "-q", "--detach" }} },
    };
    for (cases) |case| {
        for (case.setup) |args| try git.exec(io, args);
        var repo = try Repository.open(gpa, io, git.dir, .{ .discover = false });
        defer repo.deinit(io);
        _ = try submodule.init(gpa, io, &repo, .{});
        const ours = try git.line(io, &.{ "config", "submodule.a.url" });
        defer gpa.free(ours);
        try git.exec(io, &.{ "config", "--remove-section", "submodule.a" });
        try git.exec(io, &.{ "submodule", "init", "-q" });
        const theirs = try git.line(io, &.{ "config", "submodule.a.url" });
        defer gpa.free(theirs);
        try testing.expectEqualStrings(theirs, ours);
        try git.exec(io, &.{ "config", "--remove-section", "submodule.a" });
    }
}

test "sync rewrites both urls as git submodule sync --recursive does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var ours = try Clone.init(gpa, io, &f.super, true);
    defer ours.deinit(io);
    var theirs = try Clone.init(gpa, io, &f.super, true);
    defer theirs.deinit(io);

    // The superproject's .gitmodules points somewhere else now, and the
    // submodule's own does too.
    for ([_]*testgit.Repo{ &ours.git, &theirs.git }) |g| {
        try g.exec(io, &.{ "config", "-f", ".gitmodules", "submodule.vendor/lib.url", "../elsewhere/lib" });
        try g.exec(io, &.{ "config", "-f", "vendor/lib/.gitmodules", "submodule.deep/inner.url", "../../moved/inner" });
    }
    var repo = try ours.open(gpa, io);
    defer repo.deinit(io);
    const outcome = try submodule.sync(gpa, io, &repo, .{ .recursive = true });
    try testing.expectEqual(@as(u32, 2), outcome.synced);
    try testing.expectEqual(@as(u32, 2), outcome.remotes);
    try theirs.git.exec(io, &.{ "submodule", "sync", "-q", "--recursive" });

    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/config");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/modules/deep/inner/config");
}

test "deinit leaves what git submodule deinit leaves, and refuses local changes without force" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var ours = try Clone.init(gpa, io, &f.super, true);
    defer ours.deinit(io);
    var theirs = try Clone.init(gpa, io, &f.super, true);
    defer theirs.deinit(io);
    var repo = try ours.open(gpa, io);
    defer repo.deinit(io);

    // An untracked file is a local change to git, and to this.
    try ours.git.writeFile(io, "vendor/lib/u.txt", "u\n");
    try theirs.git.writeFile(io, "vendor/lib/u.txt", "u\n");
    var refusal: submodule.Refusal = .{};
    try testing.expectError(error.LocalModifications, submodule.deinitialize(gpa, io, &repo, .{ .refusal = &refusal }));
    try testing.expectEqualStrings("vendor/lib", refusal.path());
    theirs.git.report_failures = false;
    try testing.expectError(error.GitFailed, theirs.git.exec(io, &.{ "submodule", "deinit", "-q", "--all" }));
    theirs.git.report_failures = true;

    const outcome = try submodule.deinitialize(gpa, io, &repo, .{ .force = true });
    try testing.expectEqual(@as(u32, 1), outcome.cleared);
    try testing.expectEqual(@as(u32, 1), outcome.unregistered);
    try theirs.git.exec(io, &.{ "submodule", "deinit", "-q", "-f", "--all" });

    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/config");
    var empty = try ours.git.dir.openDir(io, "vendor/lib", .{ .iterate = true });
    defer empty.close(io);
    var it = empty.iterate();
    try testing.expect(try it.next(io) == null);
    try expectSubmoduleStatusAgrees(gpa, io, &ours.git, &repo);
    const status_ours = try ours.git.run(io, &.{ "status", "--porcelain=v2" });
    defer gpa.free(status_ours);
    const status_theirs = try theirs.git.run(io, &.{ "status", "--porcelain=v2" });
    defer gpa.free(status_theirs);
    try testing.expectEqualStrings(status_theirs, status_ours);
    try fsck(&ours.git, io);
}

test "absorbgitdirs moves nested .git directories where git moves them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var ours = try Clone.init(gpa, io, &f.super, false);
    defer ours.deinit(io);
    var theirs = try Clone.init(gpa, io, &f.super, false);
    defer theirs.deinit(io);

    // The layout from before absorbing existed: each submodule a clone
    // made in place, its `.git` a directory in its working tree.
    const lib_url = try absolute(gpa, io, f.lib.dir);
    defer gpa.free(lib_url);
    const inner_url = try absolute(gpa, io, f.inner.dir);
    defer gpa.free(inner_url);
    const recorded = try ours.git.line(io, &.{ "rev-parse", "HEAD:vendor/lib" });
    defer gpa.free(recorded);
    for ([_]*testgit.Repo{ &ours.git, &theirs.git }) |g| {
        try g.dir.deleteDir(io, "vendor/lib");
        try g.exec(io, &.{ "clone", "-q", lib_url, "vendor/lib" });
        var lib = g.*;
        lib.dir = try g.dir.openDir(io, "vendor/lib", .{});
        defer lib.dir.close(io);
        try lib.exec(io, &.{ "checkout", "-q", "--detach", recorded });
        try lib.dir.deleteDir(io, "deep/inner");
        try lib.exec(io, &.{ "clone", "-q", inner_url, "deep/inner" });
        try g.exec(io, &.{ "submodule", "init", "-q" });
    }

    var repo = try ours.open(gpa, io);
    defer repo.deinit(io);
    const outcome = try submodule.absorbGitDirs(gpa, io, &repo, .{});
    try testing.expectEqual(@as(u32, 2), outcome.moved);
    try theirs.git.exec(io, &.{ "submodule", "absorbgitdirs" });

    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, "vendor/lib/.git");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, "vendor/lib/deep/inner/.git");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/config");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/modules/deep/inner/config");
    try expectSubmoduleStatusAgrees(gpa, io, &ours.git, &repo);
    try expectPorcelainV2Agrees(gpa, io, &ours.git, .{});

    // Absorbing twice moves nothing.
    const again = try submodule.absorbGitDirs(gpa, io, &repo, .{});
    try testing.expectEqual(@as(u32, 0), again.moved + again.reconnected);
}

//=========================================================================
// update
//=========================================================================

test "update brings a deinitialised submodule back without a fetch, as git does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var ours = try Clone.init(gpa, io, &f.super, true);
    defer ours.deinit(io);
    var theirs = try Clone.init(gpa, io, &f.super, true);
    defer theirs.deinit(io);
    for ([_]*testgit.Repo{ &ours.git, &theirs.git }) |g| {
        try g.exec(io, &.{ "submodule", "deinit", "-q", "--all" });
    }

    var repo = try ours.open(gpa, io);
    defer repo.deinit(io);

    const outcome = try submodule.update(gpa, io, &repo, .{ .init = true, .recursive = true, .who = who });
    // Both levels come back from `modules/`, the nested one from inside
    // its parent's repository.
    try testing.expectEqual(@as(u32, 2), outcome.reconnected);
    try testing.expectEqual(@as(u32, 2), outcome.updated);
    try theirs.git.exec(io, &.{ "submodule", "update", "-q", "--init", "--recursive" });

    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/config");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, "vendor/lib/.git");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/config");
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/HEAD");
    try expectSubmoduleStatusAgrees(gpa, io, &ours.git, &repo);
    try expectPorcelainV2Agrees(gpa, io, &ours.git, .{});
    const status_theirs = try theirs.git.run(io, &.{ "status", "--porcelain=v2" });
    defer gpa.free(status_theirs);
    const status_ours = try ours.git.run(io, &.{ "status", "--porcelain=v2" });
    defer gpa.free(status_ours);
    try testing.expectEqualStrings(status_theirs, status_ours);
    var lib = ours.git;
    lib.dir = try ours.git.dir.openDir(io, "vendor/lib", .{});
    defer lib.dir.close(io);
    try fsck(&lib, io);
    const lib_status = try lib.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(lib_status);
    try testing.expectEqualStrings("", lib_status);
    const reflog = try lib.run(io, &.{ "reflog", "-1", "--format=%gs" });
    defer gpa.free(reflog);
    try testing.expect(std.mem.startsWith(u8, reflog, "checkout: moving from "));
}

test "update checks out the recorded commit, and refuses what it will not do by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var c = try Clone.init(gpa, io, &f.super, true);
    defer c.deinit(io);
    var repo = try c.open(gpa, io);
    defer repo.deinit(io);
    var lib = c.git;
    lib.dir = try c.git.dir.openDir(io, "vendor/lib", .{});
    defer lib.dir.close(io);

    // HEAD moved on: update puts it back, detached at the recorded commit.
    try lib.exec(io, &.{ "checkout", "-q", "-b", "moved" });
    try lib.writeFile(io, "l.txt", "moved on\n");
    try lib.exec(io, &.{ "commit", "-q", "-am", "moved on" });
    const recorded = try c.git.line(io, &.{ "rev-parse", "HEAD:vendor/lib" });
    defer gpa.free(recorded);
    const outcome = try submodule.update(gpa, io, &repo, .{ .who = who });
    try testing.expectEqual(@as(u32, 1), outcome.updated);
    const head = try lib.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try testing.expectEqualStrings(recorded, head);
    const l = try readAt(gpa, io, lib.dir, "l.txt");
    defer gpa.free(l);
    try testing.expectEqualStrings("lib\n", l);
    try expectPorcelainV2Agrees(gpa, io, &c.git, .{});
    try testing.expectEqual(@as(u32, 1), (try submodule.update(gpa, io, &repo, .{})).unchanged);

    // A local change in the way is refused without force, and gone with it.
    try lib.exec(io, &.{ "checkout", "-q", "moved" });
    try lib.writeFile(io, "l.txt", "local\n");
    var refusal: submodule.Refusal = .{};
    try testing.expectError(error.LocalModifications, submodule.update(gpa, io, &repo, .{ .refusal = &refusal }));
    try testing.expectEqualStrings("vendor/lib", refusal.path());
    _ = try submodule.update(gpa, io, &repo, .{ .force = true });
    const lib_status = try lib.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(lib_status);
    try testing.expectEqualStrings("", lib_status);

    // merge and rebase are named, not run.
    try c.git.exec(io, &.{ "config", "submodule.vendor/lib.update", "rebase" });
    try reopen(&repo, gpa, io, c.git.dir);
    try lib.exec(io, &.{ "checkout", "-q", "moved" });
    try testing.expectError(error.UnsupportedUpdate, submodule.update(gpa, io, &repo, .{ .refusal = &refusal }));
    try testing.expectEqualStrings("rebase", refusal.setting());
    // none skips it.
    try c.git.exec(io, &.{ "config", "submodule.vendor/lib.update", "none" });
    try reopen(&repo, gpa, io, c.git.dir);
    try testing.expectEqual(@as(u32, 1), (try submodule.update(gpa, io, &repo, .{})).skipped);

    // A commit the submodule does not have needs a fetch.
    try c.git.exec(io, &.{ "config", "--unset", "submodule.vendor/lib.update" });
    try reopen(&repo, gpa, io, c.git.dir);
    try c.git.exec(io, &.{ "update-index", "--cacheinfo", "160000," ++ "1" ** 40 ++ ",vendor/lib" });
    try testing.expectError(error.CommitMissing, submodule.update(gpa, io, &repo, .{ .refusal = &refusal }));
    try testing.expectEqualStrings("1" ** 40, refusal.setting());
}

test "a !command update runs only with the permission to run programs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var c = try Clone.init(gpa, io, &f.super, true);
    defer c.deinit(io);
    var repo = try c.open(gpa, io);
    defer repo.deinit(io);
    var lib = c.git;
    lib.dir = try c.git.dir.openDir(io, "vendor/lib", .{});
    defer lib.dir.close(io);
    try lib.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "moved on" });

    try c.git.exec(io, &.{ "config", "submodule.vendor/lib.update", "!touch ran-" });
    try reopen(&repo, gpa, io, c.git.dir);
    // Without the permission, a named refusal carrying the setting.
    var refusal: submodule.Refusal = .{};
    try testing.expectError(error.UpdateCommandRefused, submodule.update(gpa, io, &repo, .{ .refusal = &refusal }));
    try testing.expectEqualStrings("submodule.vendor/lib.update", refusal.setting());

    // With it, the command runs in the submodule with the commit as its
    // argument, as git runs it: `touch ran- <commit>`.
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const path = testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
    defer gpa.free(path);
    try environ.put("PATH", path);
    _ = try submodule.update(gpa, io, &repo, .{ .programs = .{ .environ = &environ } });
    const recorded = try c.git.line(io, &.{ "rev-parse", "HEAD:vendor/lib" });
    defer gpa.free(recorded);
    try lib.dir.access(io, recorded, .{});
    try lib.dir.access(io, "ran-", .{});
}

/// A transport for the test: `git clone --bare` into the directory, turned
/// into the non-bare repository a separate git directory is.
const GitTransport = struct {
    git: *testgit.Repo,
    clones: u32 = 0,

    fn transport(t: *GitTransport) submodule.Transport {
        return .{ .context = t, .cloneFn = clone, .fetchFn = fetch };
    }

    fn clone(context: *anyopaque, gpa: Allocator, io: Io, url: []const u8, git_dir: Io.Dir) submodule.TransportError!void {
        const t: *GitTransport = @ptrCast(@alignCast(context));
        const target = absolute(gpa, io, git_dir) catch return error.TransportFailed;
        defer gpa.free(target);
        t.git.exec(io, &.{ "clone", "-q", "--bare", url, target }) catch return error.TransportFailed;
        t.git.exec(io, &.{ "--git-dir", target, "config", "core.bare", "false" }) catch return error.TransportFailed;
        t.clones += 1;
    }

    fn fetch(context: *anyopaque, gpa: Allocator, io: Io, repo: *Repository, remote: []const u8, want: Oid) submodule.TransportError!void {
        _ = context;
        _ = gpa;
        _ = io;
        _ = repo;
        _ = remote;
        _ = want;
        return error.TransportFailed;
    }
};

test "a submodule with no repository needs a clone, and a transport is where one comes from" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var c = try Clone.init(gpa, io, &f.super, false);
    defer c.deinit(io);
    var repo = try c.open(gpa, io);
    defer repo.deinit(io);

    var refusal: submodule.Refusal = .{};
    try testing.expectError(error.NotCloned, submodule.update(gpa, io, &repo, .{ .init = true, .refusal = &refusal }));
    try testing.expectEqualStrings("vendor/lib", refusal.path());

    var t: GitTransport = .{ .git = &c.git };
    const outcome = try submodule.update(gpa, io, &repo, .{ .init = true, .recursive = true, .transport = t.transport() });
    try testing.expectEqual(@as(u32, 2), t.clones);
    try testing.expectEqual(@as(u32, 2), outcome.cloned);
    try expectSubmoduleStatusAgrees(gpa, io, &c.git, &repo);
    try expectPorcelainV2Agrees(gpa, io, &c.git, .{});
    const dot_git = try readAt(gpa, io, c.git.dir, "vendor/lib/deep/inner/.git");
    defer gpa.free(dot_git);
    try testing.expectEqualStrings("gitdir: ../../../../.git/modules/vendor/lib/modules/deep/inner\n", dot_git);
}

test "a linked worktree of the superproject clones its submodules into its own git directory, as git does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var ours = try Clone.init(gpa, io, &f.super, true);
    defer ours.deinit(io);
    var theirs = try Clone.init(gpa, io, &f.super, true);
    defer theirs.deinit(io);
    for ([_]*testgit.Repo{ &ours.git, &theirs.git }) |g| {
        try g.exec(io, &.{ "worktree", "add", "-q", "--detach", "../linked" });
    }
    var ours_linked = ours.owner;
    ours_linked.dir = try ours.owner.dir.openDir(io, "linked", .{ .iterate = true });
    defer ours_linked.dir.close(io);
    var theirs_linked = theirs.owner;
    theirs_linked.dir = try theirs.owner.dir.openDir(io, "linked", .{ .iterate = true });
    defer theirs_linked.dir.close(io);

    var repo = try Repository.open(gpa, io, ours_linked.dir, .{ .discover = false });
    defer repo.deinit(io);
    try expectSubmoduleStatusAgrees(gpa, io, &ours_linked, &repo);

    // The main worktree's repository for the submodule is not this
    // worktree's: a clone is needed, and the transport makes it.
    try testing.expectError(error.NotCloned, submodule.update(gpa, io, &repo, .{}));
    var t: GitTransport = .{ .git = &ours.git };
    _ = try submodule.update(gpa, io, &repo, .{ .init = true, .recursive = true, .who = who, .transport = t.transport() });
    try testing.expectEqual(@as(u32, 2), t.clones);
    try theirs_linked.exec(io, &.{ "submodule", "update", "-q", "--init", "--recursive" });
    try expectSubmoduleStatusAgrees(gpa, io, &ours_linked, &repo);
    try expectSameFile(gpa, io, ours_linked.dir, theirs_linked.dir, "vendor/lib/.git");
    try expectSameFile(gpa, io, ours_linked.dir, theirs_linked.dir, "vendor/lib/deep/inner/.git");
    for ([_][]const u8{ "worktrees/linked/modules/vendor/lib", "worktrees/linked/modules/vendor/lib/modules/deep/inner" }) |module| {
        const path = try std.fmt.allocPrint(gpa, ".git/{s}/config", .{module});
        defer gpa.free(path);
        const ours_value = try ours.git.line(io, &.{ "config", "-f", path, "core.worktree" });
        defer gpa.free(ours_value);
        const theirs_value = try theirs.git.line(io, &.{ "config", "-f", path, "core.worktree" });
        defer gpa.free(theirs_value);
        try testing.expectEqualStrings(theirs_value, ours_value);
    }
    // And the main worktree's own is as it was.
    try expectSameFile(gpa, io, ours.git.dir, theirs.git.dir, ".git/modules/vendor/lib/config");
    try expectPorcelainV2Agrees(gpa, io, &ours_linked, .{});
    try expectPorcelainV2Agrees(gpa, io, &ours.git, .{});
}

//=========================================================================
// foreach
//=========================================================================

test "the walk visits what git submodule foreach --recursive visits, in its order" {
    const gpa = testing.allocator;
    const io = testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    var repo = try Repository.open(gpa, io, f.super.dir, .{ .discover = false });
    defer repo.deinit(io);

    const theirs = try f.super.run(io, &.{ "submodule", "foreach", "--quiet", "--recursive", "echo $displaypath $sm_path $name $sha1" });
    defer gpa.free(theirs);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = try submodule.walk(gpa, io, &repo, .{ .recursive = true });
    defer w.deinit();
    var visits: usize = 0;
    while (try w.next()) |visit| {
        visits += 1;
        var hex: [hash.max_hex_len]u8 = undefined;
        const line = try std.fmt.allocPrint(gpa, "{s} {s} {s} {s}\n", .{ visit.path, visit.local_path, visit.name, visit.recorded.?.hex(&hex) });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
        // The repository handed over is the submodule's.
        const head = (try visit.repo.head(io)).?;
        defer gpa.free(head.name);
        try testing.expect(head.oid.eql(visit.recorded.?));
    }
    try testing.expectEqual(@as(usize, 2), visits);
    try testing.expectEqualStrings(theirs, out.items);
}
