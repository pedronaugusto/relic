//! What the filter tests do with relic, shared by the working tree's and
//! LFS's: stage, check out and take the status of a working tree through the
//! filters its configuration names, and two repositories, git's and relic's,
//! set up alike. It reaches relic's core through `relic_core`, so the LFS
//! tests, built over the core module, share it.

const std = @import("std");
const Io = std.Io;

const testgit = @import("git.zig");
const core = @import("relic_core");
const hash = core.hash;
const repo_mod = core.repo;
const worktree = core.checkout.engine;
const filter = core.checkout.filter;
const native = core.checkout.native;
const program = core.process.program;
const index_mod = core.index;

const Oid = hash.Oid;
const testing = std.testing;

/// The test process's environment with nothing of the person's in it,
/// which is what a filter program is started from.
pub fn environ(gpa: std.mem.Allocator) !std.process.Environ.Map {
    return testgit.isolatedEnviron(gpa, testgit.no_home);
}

/// What relic is handed for one operation.
pub const Run = struct {
    programs: ?program.Programs = null,
    report: ?*filter.Report = null,
    /// A native provider for `filter=<driver>` (relic_lfs's, for one): with
    /// none, only the configured programs.
    native_provider: ?*const native.Provider = null,
};

/// Stage the working tree with relic, as `git add -A` does, write the index
/// and return the tree.
pub fn relicAdd(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, run: Run) !Oid {
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var drivers = try repo.loadFilters(io, .{ .native_provider = run.native_provider });
    defer drivers.deinit(io);
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = try repo.openIndex(io);
    defer index.deinit();
    _ = try worktree.addAll(gpa, io, dir, .{ .index = &index, .db = repo.objectDatabase() }, .{
        .rules = rules,
        .programs = run.programs,
        .filter_report = run.report,
    });
    const tree = try worktree.writeTree(gpa, io, &index, repo.objectDatabase());
    try index.write(io, repo.gitDirectory(), "index", .{});
    return tree;
}

/// Check `tree` out with relic into a working tree emptied of everything
/// but `.git`, from an empty index.
pub fn relicCheckout(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, tree: Oid, run: Run) !worktree.CheckoutOutcome {
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var drivers = try repo.loadFilters(io, .{ .native_provider = run.native_provider });
    defer drivers.deinit(io);
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = index_mod.Index.initEmpty(gpa, repo.objectFormat());
    defer index.deinit();
    const outcome = try worktree.checkout(gpa, io, dir, .{ .index = &index, .db = repo.objectDatabase(), .tree = tree }, .{
        .rules = rules,
        .programs = run.programs,
        .filter_report = run.report,
    });
    try index.write(io, repo.gitDirectory(), "index", .{});
    return outcome;
}

/// relic's status of the working tree against the index and `HEAD`.
pub fn relicStatus(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, run: Run) !worktree.Status {
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var drivers = try repo.loadFilters(io, .{ .native_provider = run.native_provider });
    defer drivers.deinit(io);
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = try repo.openIndex(io);
    defer index.deinit();
    return worktree.status(gpa, io, dir, .{ .index = &index, .db = repo.objectDatabase() }, .{
        .rules = rules,
        .head_tree = try repo.headTree(io),
        .untracked = .no,
        .programs = run.programs,
        .filter_report = run.report,
    });
}

/// Remove everything in the working tree but `.git`.
pub fn emptyWorktree(io: Io, dir: Io.Dir) !void {
    var it = dir.iterate();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        try names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
    }
    for (names.items) |name| try dir.deleteTree(io, name);
}

pub fn treeOf(gpa: std.mem.Allocator, io: Io, repo: *testgit.Repo) !Oid {
    const text = try repo.line(io, &.{"write-tree"});
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

pub fn expectSameFile(gpa: std.mem.Allocator, io: Io, ours: *testgit.Repo, theirs: *testgit.Repo, path: []const u8) !void {
    const a = try ours.readFile(io, path);
    defer gpa.free(a);
    const b = try theirs.readFile(io, path);
    defer gpa.free(b);
    testing.expectEqualStrings(b, a) catch |err| {
        std.debug.print("{s} differs from git's\n", .{path});
        return err;
    };
}

/// Two repositories with one configuration and one set of files.
pub const Twin = struct {
    ours: testgit.Repo,
    theirs: testgit.Repo,

    pub fn init(gpa: std.mem.Allocator, io: Io, config: []const [2][]const u8, files: []const [2][]const u8) !Twin {
        var ours = try testgit.Repo.init(gpa, io, &.{});
        errdefer ours.deinit();
        var theirs = try testgit.Repo.init(gpa, io, &.{});
        errdefer theirs.deinit();
        for ([_]*testgit.Repo{ &ours, &theirs }) |r| {
            for (config) |pair| try r.exec(io, &.{ "config", pair[0], pair[1] });
            for (files) |pair| try r.writeFile(io, pair[0], pair[1]);
        }
        return .{ .ours = ours, .theirs = theirs };
    }

    pub fn deinit(t: *Twin) void {
        t.ours.deinit();
        t.theirs.deinit();
        t.* = undefined;
    }
};
