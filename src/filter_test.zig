//! Filters against the real git: the same filters configured in two
//! repositories, git staging one and relic the other, and the trees, the
//! checked-out files and the status compared.
//!
//! The command-line filters need `sh`, so these tests stand aside on
//! Windows; the long-running one is `relic-filter-helper`, which the build
//! compiles and hands in through `build_options`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const testgit = @import("testgit.zig");
const hash = @import("hash.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const filter = @import("filter.zig");
const program = @import("program.zig");
const index_mod = @import("index.zig");
const lfs = @import("lfs.zig");

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
    drivers: filter.Drivers.Options = .{},
    fetch: ?lfs.Fetcher = null,
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
    var drivers = try repo.loadFilters(io, run.drivers);
    defer drivers.deinit();
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = try repo.openIndex(io);
    defer index.deinit();
    _ = try worktree.addAll(gpa, io, dir, &index, &repo.odb, .{
        .rules = rules,
        .programs = run.programs,
        .filter_report = run.report,
    });
    const tree = try worktree.writeTree(gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});
    return tree;
}

/// Check `tree` out with relic into a working tree emptied of everything
/// but `.git`, from an empty index.
pub fn relicCheckout(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, tree: Oid, run: Run) !worktree.CheckoutOutcome {
    var repo = try repo_mod.Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var drivers = try repo.loadFilters(io, run.drivers);
    defer drivers.deinit();
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = index_mod.Index.initEmpty(gpa, repo.objectFormat());
    defer index.deinit();
    const outcome = try worktree.checkout(gpa, io, dir, &index, &repo.odb, tree, .{
        .rules = rules,
        .programs = run.programs,
        .filter_report = run.report,
        .lfs_fetch = run.fetch,
    });
    try index.write(io, repo.git_dir, "index", .{});
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
    var drivers = try repo.loadFilters(io, run.drivers);
    defer drivers.deinit();
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = try repo.openIndex(io);
    defer index.deinit();
    return worktree.status(gpa, io, dir, &index, &repo.odb, .{
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
    }
};

test "command-line filters store what git stores and check out what git checks out" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try environ(gpa);
    defer env.deinit();

    const fixture = build_options.process_fixture_path;
    const up = try testgit.fixtureCommand(gpa, fixture, "upper");
    defer gpa.free(up);
    const down = try testgit.fixtureCommand(gpa, fixture, "lower");
    defer gpa.free(down);
    const tag = try testgit.fixtureCommand(gpa, fixture, "tag %f");
    defer gpa.free(tag);
    const drop = try testgit.fixtureCommand(gpa, fixture, "drop-first-line");
    defer gpa.free(drop);
    const crlf_command = try testgit.fixtureCommand(gpa, fixture, "crlf");
    defer gpa.free(crlf_command);
    const copy = try testgit.fixtureCommand(gpa, fixture, "copy");
    defer gpa.free(copy);
    const fail = try testgit.fixtureCommand(gpa, fixture, "fail");
    defer gpa.free(fail);

    var twin = try Twin.init(gpa, io, &.{
        .{ "filter.up.clean", up },
        .{ "filter.up.smudge", down },
        // `%f` is the path, quoted so a space and a quote stay one argument.
        .{ "filter.tag.clean", tag },
        .{ "filter.tag.smudge", drop },
        // Carriage returns out of the clean filter are normalised after it,
        // and put back before the smudge.
        .{ "filter.crlf.clean", crlf_command },
        .{ "filter.crlf.smudge", copy },
        .{ "filter.broken.clean", fail },
        .{ "filter.broken.smudge", fail },
    }, &.{
        .{ ".gitattributes", "*.up filter=up\n*.tag filter=tag\n*.crlf filter=crlf text eol=crlf\n*.txt ident\n*.broken filter=broken\n*.none filter=undefined\n" },
        .{ "a.up", "hello, world\n" },
        .{ "dir/it's a file.tag", "tagged\ncontent\n" },
        .{ "x.crlf", "one\ntwo\n" },
        .{ "id.txt", "$Id$\nbody\n" },
        .{ "b.broken", "raw\n" },
        .{ "c.none", "untouched\n" },
    });
    defer twin.deinit();

    try twin.theirs.exec(io, &.{ "add", "-A" });
    const theirs_tree = try treeOf(gpa, io, &twin.theirs);
    var report: filter.Report = .init(gpa);
    defer report.deinit();
    const ours_tree = try relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env }, .report = &report });
    try testing.expect(ours_tree.eql(theirs_tree));
    // The broken filter was passed over, and said so.
    try testing.expectEqual(@as(u32, 1), report.passed_over);
    try testing.expectEqualStrings("b.broken", report.failure.?.path);
    try testing.expectEqual(filter.Reason.exited, report.failure.?.reason);

    const blob = try twin.theirs.run(io, &.{ "cat-file", "blob", ":dir/it's a file.tag" });
    defer gpa.free(blob);
    try testing.expectEqualStrings("path=dir/it's a file.tag\ntagged\ncontent\n", blob);

    // Out again: git from its index, relic from the tree into an empty
    // working tree.
    try emptyWorktree(io, twin.theirs.dir);
    try twin.theirs.exec(io, &.{ "checkout", "--", "." });
    try emptyWorktree(io, twin.ours.dir);
    var out_report: filter.Report = .init(gpa);
    defer out_report.deinit();
    const written = try relicCheckout(gpa, io, twin.ours.dir, ours_tree, .{ .programs = .{ .environ = &env }, .report = &out_report });
    try testing.expectEqual(@as(u32, 7), written.written);
    for ([_][]const u8{ "a.up", "dir/it's a file.tag", "x.crlf", "id.txt", "b.broken", "c.none", ".gitattributes" }) |path| {
        try expectSameFile(gpa, io, &twin.ours, &twin.theirs, path);
    }
    const crlf = try twin.ours.readFile(io, "x.crlf");
    defer gpa.free(crlf);
    try testing.expectEqualStrings("one\r\ntwo\r\n", crlf);
    try testing.expectEqual(@as(u32, 1), out_report.passed_over);

    // And git finds nothing to stage between relic's index and relic's
    // working tree, which it asks through the same filters.
    const diff = try twin.ours.run(io, &.{ "diff", "--stat" });
    defer gpa.free(diff);
    try testing.expectEqualStrings("", diff);
}

test "the conversion order is the order git runs, not the one its manual gives" {
    const gpa = testing.allocator;
    const io = testing.io;
    // On the way in the line endings are decided before `ident` removes a
    // lone carriage return; on the way out `$Id$` names the blob as stored.
    var twin = try Twin.init(gpa, io, &.{}, &.{
        .{ ".gitattributes", "*.in text=auto ident\n*.out text eol=crlf ident\n" },
        .{ "f.in", "$Id: a\rb $\r\nline\r\n" },
        .{ "g.out", "$Id$\nx\n" },
    });
    defer twin.deinit();
    try twin.theirs.exec(io, &.{ "add", "-A" });
    const theirs_tree = try treeOf(gpa, io, &twin.theirs);
    const ours_tree = try relicAdd(gpa, io, twin.ours.dir, .{});
    try testing.expect(ours_tree.eql(theirs_tree));
    const stored = try twin.theirs.run(io, &.{ "cat-file", "blob", ":f.in" });
    defer gpa.free(stored);
    try testing.expectEqualStrings("$Id$\r\nline\r\n", stored);

    try emptyWorktree(io, twin.theirs.dir);
    try twin.theirs.exec(io, &.{ "checkout", "--", "." });
    try emptyWorktree(io, twin.ours.dir);
    _ = try relicCheckout(gpa, io, twin.ours.dir, ours_tree, .{});
    try expectSameFile(gpa, io, &twin.ours, &twin.theirs, "f.in");
    try expectSameFile(gpa, io, &twin.ours, &twin.theirs, "g.out");
    const g = try twin.ours.readFile(io, "g.out");
    defer gpa.free(g);
    try testing.expectEqualStrings("$Id: 093cd7cf40884a9ffe9014d667e7edf3593ec7fb $\r\nx\r\n", g);
}

/// The helper as a `filter.<driver>.process` command line.
fn helperCommand(gpa: std.mem.Allocator, args: []const u8) ![]u8 {
    return testgit.fixtureCommand(gpa, build_options.filter_helper_path, args);
}

/// Give each caller its own process logs, independent of later git commands.
fn loggedHelperCommand(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) ![]u8 {
    const path = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    if (@import("builtin").os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');
    const arg = try std.fmt.allocPrint(gpa, "--log={s}", .{path});
    defer gpa.free(arg);
    return helperCommand(gpa, arg);
}

/// The requests each helper process that ran was sent, one string per
/// process.
fn helperLogs(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !std.ArrayList([]u8) {
    var logs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (logs.items) |l| gpa.free(l);
        logs.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try logs.append(gpa, try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)));
    }
    return logs;
}

fn freeLogs(gpa: std.mem.Allocator, logs: *std.ArrayList([]u8)) void {
    for (logs.items) |l| gpa.free(l);
    logs.deinit(gpa);
}

test "a process filter stores what git stores, one process for the whole add" {
    try processFilterAdd(false);
}

test "a process filter's add log excludes write-tree's racy-index recheck" {
    try processFilterAdd(true);
}

fn processFilterAdd(racy: bool) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try environ(gpa);
    defer env.deinit();
    var git_logs_tmp = testing.tmpDir(.{ .iterate = true });
    defer git_logs_tmp.cleanup();
    var relic_logs_tmp = testing.tmpDir(.{ .iterate = true });
    defer relic_logs_tmp.cleanup();
    const command = try loggedHelperCommand(gpa, io, git_logs_tmp.dir);
    defer gpa.free(command);
    const relic_command = try loggedHelperCommand(gpa, io, relic_logs_tmp.dir);
    defer gpa.free(relic_command);
    const fail = try testgit.fixtureCommand(gpa, build_options.process_fixture_path, "fail");
    defer gpa.free(fail);

    var twin = try Twin.init(gpa, io, &.{
        .{ "filter.rot.process", command },
        // The process is used where both are configured.
        .{ "filter.rot.clean", fail },
        .{ "filter.rot.required", "true" },
    }, &.{
        .{ ".gitattributes", "*.r filter=rot\n" },
        .{ "a.r", "Hello\n" },
        .{ "sub/b.r", "second file\n" },
        .{ "c.r", "" },
    });
    defer twin.deinit();
    try twin.ours.exec(io, &.{ "config", "filter.rot.process", relic_command });

    if (racy) {
        // Only a.r is newer than the index, so write-tree rechecks just it
        // through a fresh filter process when it saves its cache-tree.
        for ([_][]const u8{ ".gitattributes", "sub/b.r", "c.r" }) |path| {
            try @import("fs.zig").setTimestamps(io, twin.theirs.dir, path, .{
                .modify_timestamp = .{ .new = .{ .nanoseconds = 1_000_000_000 * std.time.ns_per_s } },
            });
        }
        const later: i96 = (Io.Clock.real.now(io).toSeconds() + 60) * std.time.ns_per_s;
        try @import("fs.zig").setTimestamps(io, twin.theirs.dir, "a.r", .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = later } },
        });
    }

    try twin.theirs.exec(io, &.{ "add", "-A" });
    // Snapshot only the add's requests. write-tree can start another
    // process to check racily clean entries before it writes the index.
    var git_logs = try helperLogs(gpa, io, git_logs_tmp.dir);
    defer freeLogs(gpa, &git_logs);
    try testing.expectEqual(@as(usize, 1), git_logs.items.len);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, git_logs.items[0], "clean "));
    const theirs_tree = try treeOf(gpa, io, &twin.theirs);
    const blob = try twin.theirs.run(io, &.{ "cat-file", "blob", ":a.r" });
    defer gpa.free(blob);
    try testing.expectEqualStrings("Uryyb\n", blob);

    if (racy) {
        var after = try helperLogs(gpa, io, git_logs_tmp.dir);
        defer freeLogs(gpa, &after);
        try testing.expectEqual(@as(usize, 2), after.items.len);
        var requests: usize = 0;
        for (after.items) |l| requests += std.mem.count(u8, l, "clean ");
        try testing.expectEqual(@as(usize, 4), requests);
    }

    const ours_tree = try relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env } });
    try testing.expect(ours_tree.eql(theirs_tree));

    var logs = try helperLogs(gpa, io, relic_logs_tmp.dir);
    defer freeLogs(gpa, &logs);
    try testing.expectEqual(@as(usize, 1), logs.items.len);
    for (logs.items) |l| try testing.expectEqual(@as(usize, 3), std.mem.count(u8, l, "clean "));
}

test "a delayed smudge is written after the rest, as git writes it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try environ(gpa);
    defer env.deinit();
    var log_tmp = testing.tmpDir(.{ .iterate = true });
    defer log_tmp.cleanup();
    const log_path = try log_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(log_path);
    if (@import("builtin").os.tag == .windows) std.mem.replaceScalar(u8, log_path, '\\', '/');
    const args = try std.fmt.allocPrint(gpa, "--delay --log={s}", .{log_path});
    defer gpa.free(args);
    const command = try helperCommand(gpa, args);
    defer gpa.free(command);

    var twin = try Twin.init(gpa, io, &.{
        .{ "filter.rot.process", command },
    }, &.{
        .{ ".gitattributes", "*.r filter=rot\n" },
        .{ "a.r", "Hello\n" },
        .{ "sub/b.r", "second file\n" },
        .{ "c.r", "third\n" },
        .{ "plain.txt", "not filtered\n" },
    });
    defer twin.deinit();

    try twin.theirs.exec(io, &.{ "add", "-A" });
    try emptyWorktree(io, twin.theirs.dir);
    try twin.theirs.exec(io, &.{ "checkout", "--", "." });

    const ours_tree = try relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env } });
    try emptyWorktree(io, twin.ours.dir);
    var existing = try helperLogs(gpa, io, log_tmp.dir);
    const processes_before = existing.items.len;
    freeLogs(gpa, &existing);

    const outcome = try relicCheckout(gpa, io, twin.ours.dir, ours_tree, .{ .programs = .{ .environ = &env } });
    try testing.expectEqual(@as(u32, 5), outcome.written);
    for ([_][]const u8{ "a.r", "sub/b.r", "c.r", "plain.txt" }) |path| {
        try expectSameFile(gpa, io, &twin.ours, &twin.theirs, path);
    }
    const a = try twin.ours.readFile(io, "a.r");
    defer gpa.free(a);
    try testing.expectEqualStrings("Hello\n", a);

    // Each file was delayed, then asked for one at a time.
    var logs = try helperLogs(gpa, io, log_tmp.dir);
    defer freeLogs(gpa, &logs);
    try testing.expectEqual(processes_before + 1, logs.items.len);
    // Two checkouts ran the filter, git's and relic's, and each asked the
    // same way.
    var checkouts: usize = 0;
    for (logs.items) |l| {
        if (std.mem.count(u8, l, "smudge a.r can-delay") != 1) continue;
        if (std.mem.indexOf(u8, l, "clean ") != null) continue;
        checkouts += 1;
        try testing.expect(std.mem.count(u8, l, "list_available_blobs") >= 4);
        try testing.expectEqual(@as(usize, 3), std.mem.count(u8, l, " can-delay"));
    }
    try testing.expectEqual(@as(usize, 2), checkouts);

    // The index relic wrote describes files git calls unmodified.
    const status = try twin.ours.run(io, &.{ "diff", "--stat" });
    defer gpa.free(status);
    try testing.expectEqualStrings("", status);
}

test "a failing required filter stops the add by name, as it stops git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try environ(gpa);
    defer env.deinit();
    const reject = try testgit.fixtureCommand(gpa, build_options.process_fixture_path, "reject-filter");
    defer gpa.free(reject);
    const copy = try testgit.fixtureCommand(gpa, build_options.process_fixture_path, "copy");
    defer gpa.free(copy);
    var twin = try Twin.init(gpa, io, &.{
        .{ "filter.must.clean", reject },
        .{ "filter.must.required", "true" },
    }, &.{
        .{ ".gitattributes", "*.m filter=must\n" },
        .{ "a.m", "content\n" },
    });
    defer twin.deinit();

    twin.theirs.report_failures = false;
    try testing.expectError(error.GitFailed, twin.theirs.exec(io, &.{ "add", "-A" }));

    var report: filter.Report = .init(gpa);
    defer report.deinit();
    try testing.expectError(error.FilterFailed, relicAdd(gpa, io, twin.ours.dir, .{
        .programs = .{ .environ = &env },
        .report = &report,
    }));
    const failure = report.failure.?;
    try testing.expectEqualStrings("a.m", failure.path);
    try testing.expectEqualStrings("must", failure.driver);
    try testing.expectEqual(filter.Reason.exited, failure.reason);
    try testing.expectEqualStrings("nope\n", failure.detail);

    // A required driver with nothing to run for the direction fails too.
    try twin.ours.exec(io, &.{ "config", "--unset", "filter.must.clean" });
    try twin.ours.exec(io, &.{ "config", "filter.must.smudge", copy });
    try testing.expectError(error.FilterFailed, relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env } }));
}

test "without programs a required filter is refused by name and any other is passed over" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twin = try Twin.init(gpa, io, &.{
        .{ "filter.must.clean", "tr a-z A-Z" },
        .{ "filter.must.required", "true" },
        .{ "filter.may.clean", "tr a-z A-Z" },
    }, &.{
        .{ ".gitattributes", "*.may filter=may\n" },
        .{ "a.may", "content\n" },
    });
    defer twin.deinit();

    var report: filter.Report = .init(gpa);
    defer report.deinit();
    const tree = try relicAdd(gpa, io, twin.ours.dir, .{ .report = &report });
    try testing.expectEqual(@as(u32, 1), report.passed_over);
    try testing.expectEqual(filter.Reason.needs_program, report.failure.?.reason);
    // Stored as it is on the disk, the filter not run.
    try twin.theirs.exec(io, &.{ "-c", "filter.may.clean=", "add", "-A" });
    try testing.expect(tree.eql(try treeOf(gpa, io, &twin.theirs)));

    try twin.ours.writeFile(io, ".gitattributes", "*.may filter=must\n");
    try twin.ours.writeFile(io, "a.may", "changed content\n");
    try testing.expectError(error.UnsupportedAttribute, relicAdd(gpa, io, twin.ours.dir, .{ .report = &report }));
    try testing.expectEqualStrings("must", report.failure.?.driver);
}

test "a process filter's error passes one file over and its abort stops the command, as in git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try environ(gpa);
    defer env.deinit();

    const erring = try helperCommand(gpa, "--error=b.r");
    defer gpa.free(erring);
    var twin = try Twin.init(gpa, io, &.{.{ "filter.rot.process", erring }}, &.{
        .{ ".gitattributes", "*.r filter=rot\n" },
        .{ "a.r", "Hello\n" },
        .{ "b.r", "World\n" },
    });
    defer twin.deinit();
    try twin.theirs.exec(io, &.{ "add", "-A" });
    var report: filter.Report = .init(gpa);
    defer report.deinit();
    try testing.expect((try relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env }, .report = &report }))
        .eql(try treeOf(gpa, io, &twin.theirs)));
    try testing.expectEqual(filter.Reason.status_error, report.failure.?.reason);
    try testing.expectEqualStrings("b.r", report.failure.?.path);

    const aborting = try helperCommand(gpa, "--abort");
    defer gpa.free(aborting);
    for ([_]*testgit.Repo{ &twin.ours, &twin.theirs }) |r| {
        try r.exec(io, &.{ "config", "filter.rot.process", aborting });
        try r.writeFile(io, "a.r", "changed\n");
        try r.writeFile(io, "b.r", "changed too\n");
    }
    try twin.theirs.exec(io, &.{ "add", "-A" });
    try testing.expect((try relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env } }))
        .eql(try treeOf(gpa, io, &twin.theirs)));
}

test "a process filter that does not speak pkt-line is a named error, as it is fatal to git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try environ(gpa);
    defer env.deinit();
    const garbage = try helperCommand(gpa, "--garbage");
    defer gpa.free(garbage);
    var twin = try Twin.init(gpa, io, &.{.{ "filter.rot.process", garbage }}, &.{
        .{ ".gitattributes", "*.r filter=rot\n" },
        .{ "a.r", "Hello\n" },
    });
    defer twin.deinit();
    twin.theirs.report_failures = false;
    try testing.expectError(error.GitFailed, twin.theirs.exec(io, &.{ "add", "-A" }));
    try testing.expectError(error.FilterReply, relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env } }));

    // A filter that will not start is passed over, which is what git does
    // when the greeting never comes.
    const silent = try testgit.fixtureCommand(gpa, build_options.process_fixture_path, "silent");
    defer gpa.free(silent);
    try twin.ours.exec(io, &.{ "config", "filter.rot.process", silent });
    var report: filter.Report = .init(gpa);
    defer report.deinit();
    _ = try relicAdd(gpa, io, twin.ours.dir, .{ .programs = .{ .environ = &env }, .report = &report });
    try testing.expectEqual(filter.Reason.not_started, report.failure.?.reason);
}

test "status compares a filtered file through what it would be stored as" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try environ(gpa);
    defer env.deinit();
    const command = try helperCommand(gpa, "");
    defer gpa.free(command);
    var twin = try Twin.init(gpa, io, &.{.{ "filter.rot.process", command }}, &.{
        .{ ".gitattributes", "*.r filter=rot\n" },
        .{ "same.r", "Hello\n" },
        .{ "changed.r", "before\n" },
    });
    defer twin.deinit();
    const r = &twin.ours;
    _ = try relicAdd(gpa, io, r.dir, .{ .programs = .{ .environ = &env } });
    try r.exec(io, &.{ "commit", "-q", "-m", "one" });

    // Rewritten with the same bytes, so the stat no longer matches and the
    // content has to be asked; and changed.
    try r.dir.deleteFile(io, "same.r");
    try r.writeFile(io, "same.r", "Hello\n");
    try r.writeFile(io, "changed.r", "after\n");

    var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var drivers = try repo.loadFilters(io, .{});
    defer drivers.deinit();
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    rules.filters = &drivers;
    var index = try repo.openIndex(io);
    defer index.deinit();
    var result = try worktree.status(gpa, io, r.dir, &index, &repo.odb, .{
        .rules = rules,
        .head_tree = try repo.headTree(io),
        .programs = .{ .environ = &env },
    });
    defer result.deinit();
    try testing.expect(result.find("same.r") == null);
    try testing.expectEqual(worktree.Change.modified, result.find("changed.r").?.unstaged);

    const porcelain = try r.run(io, &.{ "status", "--porcelain" });
    defer gpa.free(porcelain);
    try testing.expectEqualStrings(" M changed.r\n", porcelain);
}
