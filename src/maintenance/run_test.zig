//! `maintenance run` held to git 2.55's: the same repository maintained by
//! each, the tasks each ran compared (git's by its trace2 `maintenance`
//! regions) and what each then holds, as `repack`'s and `gc`'s tests read
//! it.

const std = @import("std");
const Io = std.Io;
const testgit = @import("../testing/git.zig");
const shared = @import("repack_test.zig");
const collect_test = @import("collect_test.zig");
const run_mod = @import("run.zig");
const repo_mod = @import("../repo/repo.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;
const day = shared.day;

const Case = struct {
    args: []const []const u8,
    options: run_mod.RunOptions,
    config: []const [2][]const u8 = &.{},
};

/// The tasks git ran, by the trace2 regions `maybe_run_task` enters, in
/// its order, each once.
fn gitTasks(trace: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "\"event\":\"region_enter\"") == null) continue;
        // `maintenance foreground` for the foreground phase, which comes
        // first.
        if (std.mem.find(u8, line, "\"category\":\"maintenance") == null) continue;
        const key = "\"label\":\"";
        const at = (std.mem.find(u8, line, key) orelse continue) + key.len;
        const end = std.mem.findScalarPos(u8, line, at, '"') orelse continue;
        const label = line[at..end];
        if (std.mem.eql(u8, label, "detach")) continue;
        var already = std.mem.splitScalar(u8, out.items, '\n');
        const seen = while (already.next()) |l| {
            if (std.mem.eql(u8, l, label)) break true;
        } else false;
        if (!seen) try out.print(gpa, "{s}\n", .{label});
    }
    return out.toOwnedSlice(gpa);
}

fn ourTasks(report: *const run_mod.RunReport) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // The foreground tasks first, as they run.
    for ([_]bool{ true, false }) |foreground| for (report.selection.slice()) |task| {
        const has_foreground = task == .gc or task == .pack_refs or task == .reflog_expire;
        if (has_foreground != foreground or report.outcomes.get(task) != .ran) continue;
        try out.print(gpa, "{s}\n", .{task.name()});
    };
    return out.toOwnedSlice(gpa);
}

fn compare(format: testgit.RefFormat, cases: []const Case) !void {
    const now = Io.Clock.real.now(io).toSeconds();
    for (cases, 0..) |case, n| {
        var theirs = try shared.fixture(format, now);
        defer theirs.deinit();
        var ours = try shared.fixture(format, now);
        defer ours.deinit();
        for ([_]*testgit.Repo{ &theirs, &ours }) |r| {
            var expire: [32]u8 = undefined;
            try r.exec(io, &.{ "config", "gc.pruneExpire", try std.mem.print(&expire, "@{d}", .{now - 14 * day}) });
            try r.exec(io, &.{ "config", "gc.autoDetach", "false" });
            for (case.config) |kv| try r.exec(io, &.{ "config", kv[0], kv[1] });
        }
        var trace_name: [64]u8 = undefined;
        const trace_path = try std.mem.print(&trace_name, "trace-{d}.json", .{n});
        var trace_abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const trace_abs = trace_abs_buf[0..try theirs.tmp.dir.realPath(io, &trace_abs_buf)];
        const trace_file = try std.Io.Dir.path.join(gpa, &.{ trace_abs, trace_path });
        defer gpa.free(trace_file);
        try theirs.isolated.?.put("GIT_TRACE2_EVENT", trace_file);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "maintenance", "run", "--quiet" });
        try args.appendSlice(gpa, case.args);
        theirs.defaults = &collect_test.gc_settings;
        try theirs.exec(io, args.items);
        theirs.defaults = &testgit.default_settings;
        _ = theirs.isolated.?.swapRemove("GIT_TRACE2_EVENT");

        var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
        defer native.deinit(io);
        var options = case.options;
        options.clock = .{ .now = Io.Clock.real.now(io) };
        options.programs = .{ .environ = &ours.isolated.? };
        options.pack.threads = 1;
        const report = try run_mod.run(gpa, io, &native, options);
        try std.testing.expect(report.succeeded());

        const trace = try theirs.tmp.dir.readFileAlloc(io, trace_path, gpa, .limited(1 << 24));
        defer gpa.free(trace);
        const expected_tasks = try gitTasks(trace);
        defer gpa.free(expected_tasks);
        const actual_tasks = try ourTasks(&report);
        defer gpa.free(actual_tasks);
        std.testing.expectEqualStrings(expected_tasks, actual_tasks) catch |err| {
            std.debug.print("maintenance case {d}: the tasks run\n", .{n});
            return err;
        };
        inline for (.{ shared.state, collect_test.housekeeping }) |describe| {
            const expected = try describe(&theirs);
            defer gpa.free(expected);
            const actual = try describe(&ours);
            defer gpa.free(actual);
            std.testing.expectEqualStrings(expected, actual) catch |err| {
                std.debug.print("maintenance case {d}\n", .{n});
                return err;
            };
        }
        try ours.exec(io, &.{ "fsck", "--no-progress", "--no-dangling" });
    }
}

fn runsInFormat(format: testgit.RefFormat) !void {
    const c: @import("../text.zig").date.Context = .{ .now = Io.Clock.real.now(io) };
    try compare(format, &.{
        // The geometric strategy, git 2.55's default for a manual run.
        .{ .args = &.{}, .options = .{ .clock = c } },
        .{ .args = &.{}, .options = .{ .clock = c }, .config = &.{.{ "maintenance.strategy", "gc" }} },
        .{ .args = &.{}, .options = .{ .clock = c }, .config = &.{.{ "maintenance.strategy", "incremental" }} },
        .{ .args = &.{}, .options = .{ .clock = c }, .config = &.{ .{ "maintenance.commit-graph.enabled", "false" }, .{ "maintenance.loose-objects.enabled", "true" } } },
        .{ .args = &.{"--task=loose-objects"}, .options = .{ .clock = c, .tasks = &.{.loose_objects} } },
        .{ .args = &.{"--task=incremental-repack"}, .options = .{ .clock = c, .tasks = &.{.incremental_repack} } },
        .{ .args = &.{ "--task=pack-refs", "--task=gc" }, .options = .{ .clock = c, .tasks = &.{ .pack_refs, .gc } } },
        .{ .args = &.{"--task=geometric-repack"}, .options = .{ .clock = c, .tasks = &.{.geometric_repack} }, .config = &.{.{ "maintenance.geometric-repack.splitFactor", "3" }} },
        .{ .args = &.{"--schedule=daily"}, .options = .{ .clock = c, .schedule = .daily }, .config = &.{ .{ "maintenance.strategy", "incremental" }, .{ "maintenance.prefetch.enabled", "false" } } },
        .{ .args = &.{"--schedule=weekly"}, .options = .{ .clock = c, .schedule = .weekly }, .config = &.{ .{ "maintenance.strategy", "incremental" }, .{ "maintenance.prefetch.enabled", "false" } } },
        .{ .args = &.{"--schedule=hourly"}, .options = .{ .clock = c, .schedule = .hourly } },
    });
}

test "maintenance run runs the tasks git's does and leaves what git's leaves, in both ref formats" {
    try testgit.eachRefFormat(runsInFormat);
}

fn autoInFormat(format: testgit.RefFormat) !void {
    const c: @import("../text.zig").date.Context = .{ .now = Io.Clock.real.now(io) };
    try compare(format, &.{
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true } },
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ .{ "maintenance.geometric-repack.auto", "-1" }, .{ "maintenance.commit-graph.auto", "1" }, .{ "maintenance.reflog-expire.auto", "1" } } },
        .{ .args = &.{"--auto"}, .options = .{ .clock = c, .auto = true }, .config = &.{ .{ "maintenance.strategy", "gc" }, .{ "gc.autoPackLimit", "1" } } },
        .{ .args = &.{ "--auto", "--task=loose-objects", "--task=incremental-repack" }, .options = .{ .clock = c, .auto = true, .tasks = &.{ .loose_objects, .incremental_repack } }, .config = &.{ .{ "maintenance.loose-objects.auto", "5" }, .{ "maintenance.incremental-repack.auto", "2" } } },
        .{ .args = &.{ "--auto", "--task=worktree-prune", "--task=rerere-gc" }, .options = .{ .clock = c, .auto = true, .tasks = &.{ .worktree_prune, .rerere_gc } } },
    });
}

test "maintenance run --auto runs the tasks whose conditions git's would, in both ref formats" {
    try testgit.eachRefFormat(autoInFormat);
}

test "the tasks a run takes, as git's initialize_task_config chooses them" {
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var native = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer native.deinit(io);
    const Expect = struct { config: ?[2][]const u8, schedule: ?run_mod.Schedule, tasks: []const run_mod.Task };
    const cases = [_]Expect{
        .{ .config = null, .schedule = null, .tasks = &.{ .geometric_repack, .commit_graph, .pack_refs, .reflog_expire, .worktree_prune, .rerere_gc } },
        .{ .config = null, .schedule = .daily, .tasks = &.{} },
        .{ .config = .{ "maintenance.strategy", "incremental" }, .schedule = null, .tasks = &.{.gc} },
        .{ .config = .{ "maintenance.strategy", "Incremental" }, .schedule = .hourly, .tasks = &.{ .prefetch, .commit_graph } },
        .{ .config = .{ "maintenance.strategy", "incremental" }, .schedule = .weekly, .tasks = &.{ .prefetch, .loose_objects, .incremental_repack, .commit_graph, .pack_refs } },
        .{ .config = .{ "maintenance.strategy", "geometric" }, .schedule = .daily, .tasks = &.{ .geometric_repack, .commit_graph, .pack_refs } },
    };
    for (cases) |case| {
        var unset = try git.capture(io, &.{ "config", "--unset-all", "maintenance.strategy" });
        unset.deinit(gpa);
        if (case.config) |kv| try git.exec(io, &.{ "config", kv[0], kv[1] });
        _ = try native.refreshConfig(io, .{});
        const selection = try run_mod.selectTasks(&native, &.{}, case.schedule);
        try std.testing.expectEqualSlices(run_mod.Task, case.tasks, selection.slice());
    }
    try git.exec(io, &.{ "config", "maintenance.strategy", "nightly" });
    _ = try native.refreshConfig(io, .{});
    try std.testing.expectError(error.UnknownMaintenanceStrategy, run_mod.selectTasks(&native, &.{}, null));
    try std.testing.expectError(error.TaskSelectedTwice, run_mod.selectTasks(&native, &.{ .gc, .gc }, null));
    try std.testing.expectError(error.IncompatibleOptions, run_mod.selectTasks(&native, &.{.gc}, .daily));
    try std.testing.expectEqual(run_mod.Task.loose_objects, run_mod.Task.parse("Loose-Objects").?);
}

const schedule = @import("schedule.zig");

/// The files git's `maintenance start` writes for `scheduler`, its
/// scheduler a no-op as git's tests have it, compared with relic's.
fn startWrites(scheduler: schedule.Scheduler, flag: []const u8, mock: []const u8) !void {
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try shared.commitAt(&git, testgit.fixture_date, "one");
    var home_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    try git.tmp.dir.createDirPath(io, "home");
    const home_dir = try git.tmp.dir.openDir(io, "home", .{});
    defer home_dir.close(io);
    const home = home_buf[0..try home_dir.realPath(io, &home_buf)];
    const xdg = try std.Io.Dir.path.join(gpa, &.{ home, ".config" });
    defer gpa.free(xdg);
    try git.isolated.?.put("HOME", home);
    try git.isolated.?.put("XDG_CONFIG_HOME", xdg);
    try git.isolated.?.put("GIT_TEST_MAINT_SCHEDULER", mock);
    try git.exec(io, &.{ "maintenance", "start", flag });
    const exec_path = try git.line(io, &.{"--exec-path"});
    defer gpa.free(exec_path);
    var reg = try schedule.registration(gpa, scheduler, .{ .exec_path = exec_path, .minute = 13 });
    defer reg.deinit();
    const base = switch (reg.base) {
        .home => "home",
        .xdg_config_home => "home/.config",
        .none => unreachable,
    };
    for (reg.entries) |entry| {
        const path = try std.Io.Dir.path.join(gpa, &.{ base, entry.path });
        defer gpa.free(path);
        const written = try git.tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(written);
        std.testing.expectEqualStrings(written, entry.contents) catch |err| {
            std.debug.print("{t}: {s}\n", .{ scheduler, entry.path });
            return err;
        };
    }
}

test "maintenance start's launchd plists and systemd units are git's, byte for byte" {
    try startWrites(.launchctl, "--scheduler=launchctl", "launchctl:true");
    try startWrites(.systemd_timer, "--scheduler=systemd-timer", "systemctl:true");
}

test "the crontab region and the schtasks tasks are git's" {
    const inputs: schedule.Inputs = .{ .exec_path = "/usr/libexec/git-core", .minute = 7 };
    const existing = "0 * * * * other job\n# BEGIN GIT MAINTENANCE SCHEDULE\nold line\n# END GIT MAINTENANCE SCHEDULE\nlast job";
    const added = try schedule.crontab(gpa, existing, inputs);
    defer gpa.free(added);
    try std.testing.expectEqualStrings(
        \\0 * * * * other job
        \\last job
        \\# BEGIN GIT MAINTENANCE SCHEDULE
        \\# The following schedule was created by Git
        \\# Any edits made in this region might be
        \\# replaced in the future by a Git command.
        \\
        \\7 1-23 * * * "/usr/libexec/git-core/git" --exec-path="/usr/libexec/git-core" -c credential.interactive=false -c core.askPass=true  for-each-repo --keep-going --config=maintenance.repo maintenance run --schedule=hourly
        \\7 0 * * 1-6 "/usr/libexec/git-core/git" --exec-path="/usr/libexec/git-core" -c credential.interactive=false -c core.askPass=true  for-each-repo --keep-going --config=maintenance.repo maintenance run --schedule=daily
        \\7 0 * * 0 "/usr/libexec/git-core/git" --exec-path="/usr/libexec/git-core" -c credential.interactive=false -c core.askPass=true  for-each-repo --keep-going --config=maintenance.repo maintenance run --schedule=weekly
        \\
        \\# END GIT MAINTENANCE SCHEDULE
        \\
    , added);
    const removed = try schedule.crontab(gpa, added, null);
    defer gpa.free(removed);
    try std.testing.expectEqualStrings("0 * * * * other job\nlast job\n", removed);

    var reg = try schedule.registration(gpa, .schtasks, .{ .exec_path = "C:/Program Files/Git/mingw64/libexec/git-core", .minute = 7 });
    defer reg.deinit();
    try std.testing.expectEqualStrings("Git Maintenance (weekly)", reg.entries[2].path);
    try std.testing.expect(std.mem.find(u8, reg.entries[2].contents, "<StartBoundary>2020-01-01T00:07:00</StartBoundary>\n<Enabled>true</Enabled>\n<ScheduleByWeek>\n<DaysOfWeek>\n<Sunday />") != null);
    try std.testing.expect(std.mem.find(u8, reg.entries[0].contents, "<Command>\"C:/Program Files/Git/mingw64/libexec/git-core\\headless-git.exe\"</Command>\n<Arguments>--exec-path=\"C:/Program Files/Git/mingw64/libexec/git-core\" -c credential.interactive=false -c core.askPass=true  for-each-repo --keep-going --config=maintenance.repo maintenance run --schedule=hourly</Arguments>") != null);
    try std.testing.expectError(error.NotFiles, schedule.registration(gpa, .cron, .{ .exec_path = "", .minute = 0 }));
    try std.testing.expectEqual(schedule.Scheduler.systemd_timer, schedule.Scheduler.parse("Systemd").?);
}

test "maintenance register and unregister write what git's write" {
    var theirs = try testgit.Repo.init(gpa, io, &.{});
    defer theirs.deinit();
    var ours = try testgit.Repo.init(gpa, io, &.{});
    defer ours.deinit();
    try theirs.writeFile(io, "global", "[user]\n\tname = x\n");
    try ours.writeFile(io, "global", "[user]\n\tname = x\n");
    var their_global_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const their_global = their_global_buf[0..try theirs.dir.realPath(io, &their_global_buf)];
    const global_path = try std.Io.Dir.path.join(gpa, &.{ their_global, "global" });
    defer gpa.free(global_path);
    try theirs.exec(io, &.{ "maintenance", "register", "--config-file", global_path });
    try theirs.exec(io, &.{ "maintenance", "register", "--config-file", global_path });
    var native = try repo_mod.Repository.open(gpa, io, ours.dir, .{});
    defer native.deinit(io);
    try run_mod.register(gpa, io, &native, .{ .dir = ours.dir, .sub_path = "global" });
    // A file outside the configuration is not read for the check, so git
    // lists the repository again.
    try run_mod.register(gpa, io, &native, .{ .dir = ours.dir, .sub_path = "global" });
    for ([_][]const u8{ "maintenance.auto", "maintenance.strategy" }) |key| {
        const expected = try theirs.line(io, &.{ "config", "--local", key });
        defer gpa.free(expected);
        const actual = try ours.line(io, &.{ "config", "--local", key });
        defer gpa.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    // Each file lists its own repository once, in the same place.
    var our_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const our_path = our_buf[0..try ours.dir.realPath(io, &our_buf)];
    const theirs_file = try theirs.readFile(io, "global");
    defer gpa.free(theirs_file);
    const ours_file = try ours.readFile(io, "global");
    defer gpa.free(ours_file);
    const expected = try std.mem.replaceOwned(u8, gpa, theirs_file, their_global, our_path);
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, ours_file);

    try theirs.exec(io, &.{ "maintenance", "unregister", "--config-file", global_path });
    try run_mod.unregister(gpa, io, &native, .{ .dir = ours.dir, .sub_path = "global" });
    const theirs_after = try theirs.readFile(io, "global");
    defer gpa.free(theirs_after);
    const ours_after = try ours.readFile(io, "global");
    defer gpa.free(ours_after);
    try std.testing.expectEqualStrings(theirs_after, ours_after);
    try std.testing.expectError(error.NotRegistered, run_mod.unregister(gpa, io, &native, .{ .dir = ours.dir, .sub_path = "global" }));
    try run_mod.unregister(gpa, io, &native, .{ .dir = ours.dir, .sub_path = "global", .force = true });
}

test "the prefetch task fetches each remote into refs/prefetch/ as git's" {
    const fetch = @import("../transport/fetch.zig");
    var source = try testgit.Repo.init(gpa, io, &.{});
    defer source.deinit();
    try shared.commitAt(&source, testgit.fixture_date, "one");
    try source.exec(io, &.{ "tag", "v1" });
    var source_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = source_buf[0..try source.dir.realPath(io, &source_buf)];
    var repos: [2]testgit.Repo = undefined;
    for (&repos) |*r| {
        r.* = try testgit.Repo.init(gpa, io, &.{});
        try r.exec(io, &.{ "remote", "add", "origin", source_path });
        try r.exec(io, &.{ "remote", "add", "skipped", source_path });
        try r.exec(io, &.{ "config", "remote.skipped.skipDefaultUpdate", "true" });
        try r.exec(io, &.{ "fetch", "-q", "origin" });
    }
    defer for (&repos) |*r| r.deinit();
    try shared.commitAt(&source, testgit.fixture_date + 60, "two");
    try source.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try shared.commitAt(&source, testgit.fixture_date + 120, "three");
    try source.exec(io, &.{ "tag", "v2" });
    try repos[0].exec(io, &.{ "maintenance", "run", "--quiet", "--task=prefetch" });

    var native = try repo_mod.Repository.open(gpa, io, repos[1].dir, .{});
    defer native.deinit(io);
    var prefetcher: fetch.Prefetcher = .{ .gpa = gpa, .options = .{ .who = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 }, .programs = .{ .environ = &repos[1].isolated.? } } };
    const report = try run_mod.run(gpa, io, &native, .{ .clock = .{ .now = Io.Clock.real.now(io) }, .tasks = &.{.prefetch}, .prefetch = prefetcher.maintenance() });
    try std.testing.expect(report.succeeded());
    const expected = try repos[0].run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(expected);
    const actual = try repos[1].run(io, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(std.mem.find(u8, actual, "refs/prefetch/remotes/origin/side") != null);
    // `--no-write-fetch-head`: each `FETCH_HEAD` is the first fetch's.
    const their_head = try repos[0].readFile(io, ".git/FETCH_HEAD");
    defer gpa.free(their_head);
    const our_head = try repos[1].readFile(io, ".git/FETCH_HEAD");
    defer gpa.free(our_head);
    try std.testing.expectEqualStrings(their_head, our_head);
}
