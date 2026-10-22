//! git's `maintenance run` (`builtin/gc.c`, `maintenance_run`): the tasks
//! a strategy, `maintenance.<task>.enabled` and `.schedule` select, each
//! with `--auto` only when its condition says so, under
//! `objects/maintenance.lock`, the foreground ones first.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const config_write = @import("../config/write.zig");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");
const odb_mod = @import("../odb/odb.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const rerere = @import("../merge/rerere.zig");
const program = @import("../process/program.zig");
const date = @import("../text.zig").date;
const gc = @import("gc.zig");
const collect = @import("collect.zig");
const repack_mod = @import("repack.zig");
const ops = @import("maintenance.zig");
const rev_index = @import("../odb/rev_index.zig");
const Repository = repo_mod.Repository;

/// git's maintenance tasks, in the order it runs them.
pub const Task = enum {
    prefetch,
    loose_objects,
    incremental_repack,
    geometric_repack,
    gc,
    commit_graph,
    pack_refs,
    reflog_expire,
    worktree_prune,
    rerere_gc,

    /// The name git gives it, `--task=<name>` and `maintenance.<name>.*`.
    pub fn name(task: Task) []const u8 {
        return switch (task) {
            .prefetch => "prefetch",
            .loose_objects => "loose-objects",
            .incremental_repack => "incremental-repack",
            .geometric_repack => "geometric-repack",
            .gc => "gc",
            .commit_graph => "commit-graph",
            .pack_refs => "pack-refs",
            .reflog_expire => "reflog-expire",
            .worktree_prune => "worktree-prune",
            .rerere_gc => "rerere-gc",
        };
    }

    /// The task `text` names, any case, as `task_option_parse` takes it.
    pub fn parse(text: []const u8) ?Task {
        for (std.enums.values(Task)) |task| {
            if (std.ascii.eqlIgnoreCase(text, task.name())) return task;
        }
        return null;
    }
};

/// How often a scheduled run comes: `--schedule=<frequency>`, ordered as
/// git's `schedule_priority`.
pub const Schedule = enum(u2) {
    weekly = 1,
    daily = 2,
    hourly = 3,

    /// `parse_schedule`: any case; `null` for anything else.
    pub fn parse(text: []const u8) ?Schedule {
        for (std.enums.values(Schedule)) |s| {
            if (std.ascii.eqlIgnoreCase(text, @tagName(s))) return s;
        }
        return null;
    }
};

/// `maintenance.strategy`.
pub const Strategy = enum {
    gc,
    incremental,
    geometric,

    /// `parse_maintenance_strategy`: any case.
    pub fn parse(text: []const u8) ?Strategy {
        for (std.enums.values(Strategy)) |s| {
            if (std.ascii.eqlIgnoreCase(text, @tagName(s))) return s;
        }
        return null;
    }
};

/// One task's place in a strategy: whether a manual run and a scheduled
/// one take it, and how often a scheduled one does.
const Entry = struct {
    manual: bool = false,
    scheduled: bool = false,
    schedule: ?Schedule = null,
};

/// git's `gc_strategy`, `incremental_strategy` and `geometric_strategy`;
/// `null` is `none_strategy`, a scheduled run's when nothing is set.
fn strategyTable(strategy: ?Strategy) std.EnumArray(Task, Entry) {
    var table: std.EnumArray(Task, Entry) = .initFill(.{});
    switch (strategy orelse return table) {
        .gc => table.set(.gc, .{ .manual = true, .scheduled = true, .schedule = .daily }),
        .incremental => {
            table.set(.commit_graph, .{ .scheduled = true, .schedule = .hourly });
            table.set(.prefetch, .{ .scheduled = true, .schedule = .hourly });
            table.set(.incremental_repack, .{ .scheduled = true, .schedule = .daily });
            table.set(.loose_objects, .{ .scheduled = true, .schedule = .daily });
            table.set(.pack_refs, .{ .scheduled = true, .schedule = .weekly });
            // A manual run under `incremental` is git's gc, as before
            // the strategy covered manual runs.
            table.set(.gc, .{ .manual = true });
        },
        .geometric => {
            table.set(.commit_graph, .{ .manual = true, .scheduled = true, .schedule = .hourly });
            table.set(.geometric_repack, .{ .manual = true, .scheduled = true, .schedule = .daily });
            table.set(.pack_refs, .{ .manual = true, .scheduled = true, .schedule = .daily });
            table.set(.rerere_gc, .{ .manual = true, .scheduled = true, .schedule = .weekly });
            table.set(.reflog_expire, .{ .manual = true, .scheduled = true, .schedule = .weekly });
            table.set(.worktree_prune, .{ .manual = true, .scheduled = true, .schedule = .weekly });
        },
    }
    return table;
}

/// The tasks a run takes, in the order it runs them.
pub const Selection = struct {
    tasks: [std.enums.values(Task).len]Task = undefined,
    len: usize = 0,

    pub fn slice(s: *const Selection) []const Task {
        return s.tasks[0..s.len];
    }

    fn add(s: *Selection, task: Task) void {
        s.tasks[s.len] = task;
        s.len += 1;
    }
};

/// Failures of choosing the tasks.
pub const SelectError = config_mod.ValueError || error{
    /// `maintenance.strategy` names none of git's: git dies.
    UnknownMaintenanceStrategy,
    /// A task given twice, git's "cannot be selected multiple times".
    TaskSelectedTwice,
    /// Tasks given with a schedule: git refuses `--task` with
    /// `--schedule`.
    IncompatibleOptions,
};

/// `initialize_task_config`: the tasks given, in their order; else those
/// the strategy and `maintenance.<task>.enabled` give a manual run (the
/// `geometric` strategy unless `maintenance.strategy` names one), or with
/// `schedule` those they give a scheduled run at least as often
/// (`maintenance.<task>.schedule`; nothing unless a strategy is named).
pub fn selectTasks(repo: *Repository, given: []const Task, schedule: ?Schedule) Self.SelectError!Selection {
    var selection: Selection = .{};
    if (given.len != 0) {
        if (schedule != null) return error.IncompatibleOptions;
        for (given, 0..) |task, i| {
            for (given[0..i]) |earlier| if (earlier == task) return error.TaskSelectedTwice;
            selection.add(task);
        }
        return selection;
    }
    const config = repo.configuration();
    var table = strategyTable(if (schedule == null) .geometric else null);
    if (config.get("maintenance.strategy")) |value| table = strategyTable(Strategy.parse(value) orelse return error.UnknownMaintenanceStrategy);
    for (std.enums.values(Task)) |task| {
        var entry = table.get(task);
        var name_buf: [64]u8 = undefined;
        // unreachable: the longest task name and the words around it fit
        const enabled_name = std.mem.print(&name_buf, "maintenance.{s}.enabled", .{task.name()}) catch unreachable;
        if (config.has(enabled_name)) {
            const on = try config.getBool(enabled_name, false);
            entry.manual = on and schedule == null;
            entry.scheduled = on and schedule != null;
        }
        if (schedule) |wanted| {
            if (!entry.scheduled) continue;
            // unreachable: as above
            const schedule_name = std.mem.print(&name_buf, "maintenance.{s}.schedule", .{task.name()}) catch unreachable;
            if (config.get(schedule_name)) |value| entry.schedule = Schedule.parse(value);
            const every = entry.schedule orelse continue;
            if (@backingInt(every) < @backingInt(wanted)) continue;
        } else if (!entry.manual) continue;
        selection.add(task);
    }
    return selection;
}

/// Fetching the remotes for the prefetch task, which maintenance, below
/// the transport, cannot do itself: git's `fetch <remote> --prefetch
/// --prune --no-tags --no-write-fetch-head --recurse-submodules=no` for
/// each remote not `skipDefaultUpdate`. `transport.prefetch` is one.
pub const Prefetch = struct {
    context: *anyopaque,
    fetch: *const fn (context: *anyopaque, io: Io, repo: *Repository) error{PrefetchFailed}!void,
};

/// What `run` is asked: git's `maintenance run` options.
pub const RunOptions = struct {
    /// The time now, which the expiries count back from.
    clock: date.Context,
    /// `--auto`: a task runs only when its condition says so; a task
    /// with none, the prefetch, never.
    auto: bool = false,
    /// `--schedule=<frequency>`.
    schedule: ?Schedule = null,
    /// `--task=<task>`, each once.
    tasks: []const Task = &.{},
    prefetch: ?Prefetch = null,
    /// The `pre-auto-gc` hook's runner, for the gc task.
    hooks: ?*hooks_mod.Runner = null,
    /// What runs `gc.recentObjectsHook`.
    programs: ?program.Programs = null,
    /// `null` takes the repository's settings, `Odb.packOptions`.
    pack: ?odb_mod.PackOptions = null,
};

/// How one task went.
pub const Outcome = union(enum) {
    /// Not selected.
    none,
    /// `--auto`, and its condition said no.
    skipped,
    ran,
    /// git's "task '<name>' failed": the others still run.
    failed: Self.Error,
};

/// What `run` did.
pub const RunReport = struct {
    /// Another run holds `objects/maintenance.lock`: nothing ran, as
    /// git's "lock file exists, skipping maintenance".
    locked: bool = false,
    selection: Selection = .{},
    outcomes: std.EnumArray(Task, Outcome) = .initFill(.none),

    /// Whether no task failed: git's exit status.
    pub fn succeeded(report: *const RunReport) bool {
        for (std.enums.values(Task)) |task| if (report.outcomes.get(task) == .failed) return false;
        return true;
    }
};

/// Failures of `run`.
pub const Error = SelectError || collect.Error || ops.MidxError || error{
    /// The prefetch task with no `Prefetch` to fetch through, or one that
    /// failed.
    PrefetchFailed,
};

/// git's `maintenance run`: the selected tasks under
/// `objects/maintenance.lock`, the foreground ones (gc's `pack-refs` and
/// `reflog expire`, the pack-refs and reflog-expire tasks) first, then the
/// rest; a task that fails leaves the others to run.
pub fn run(gpa: Allocator, io: Io, repo: *Repository, options: RunOptions) Self.Error!RunReport {
    if (options.auto and options.schedule != null) return error.IncompatibleOptions;
    var report: RunReport = .{ .selection = try selectTasks(repo, options.tasks, options.schedule) };
    var buffer: [64]u8 = undefined;
    var lock = fs.LockFile.open(gpa, io, repo.objectDatabase().objectsDirectory(), .{ .sub_path = "maintenance", .buffer = &buffer }, .{ .sync = .none, .write_pid = repo.lockfilePid() }) catch |err| switch (err) {
        error.LockHeld => return .{ .locked = true, .selection = report.selection },
        else => |e| return e,
    };
    // Never committed: the lock is only held, as git rolls it back.
    defer lock.deinit(io);
    for ([_]Phase{ .foreground, .background }) |phase| {
        for (report.selection.slice()) |task| {
            if (!hasPhase(task, phase) or report.outcomes.get(task) == .failed) continue;
            if (options.auto) {
                const wanted = condition(gpa, io, repo, task, options) catch |err| {
                    report.outcomes.set(task, .{ .failed = err });
                    continue;
                };
                if (!wanted) {
                    if (report.outcomes.get(task) == .none) report.outcomes.set(task, .skipped);
                    continue;
                }
            }
            runTask(gpa, io, repo, task, phase, options) catch |err| {
                report.outcomes.set(task, .{ .failed = err });
                continue;
            };
            report.outcomes.set(task, .ran);
        }
    }
    return report;
}

/// git's `maintenance is-needed`: with `auto`, whether any selected
/// task's condition asks for it; without, always.
pub fn isNeeded(gpa: Allocator, io: Io, repo: *Repository, options: RunOptions) Self.Error!bool {
    const selection = try selectTasks(repo, options.tasks, options.schedule);
    if (!options.auto) return true;
    for (selection.slice()) |task| if (try condition(gpa, io, repo, task, options)) return true;
    return false;
}

/// Whether a command that runs maintenance after itself (commit, fetch,
/// merge, am, rebase, receive-pack's `receive.autogc`) runs
/// `maintenance run --auto`, and detached or not: git's
/// `prepare_auto_maintenance`, `maintenance.auto` (else `gc.auto` above
/// zero) and `maintenance.autoDetach` (else `gc.autoDetach`, true).
pub const Auto = struct { detach: bool };

pub fn autoMaintenance(repo: *Repository) config_mod.ValueError!?Auto {
    const config = repo.configuration();
    const enabled = if (config.has("maintenance.auto"))
        try config.getBool("maintenance.auto", true)
    else
        try config.getInt("gc.auto", 6700) > 0;
    if (!enabled) return null;
    const detach = if (config.has("maintenance.autodetach"))
        try config.getBool("maintenance.autodetach", true)
    else
        try config.getBool("gc.autodetach", true);
    return .{ .detach = detach };
}

const Phase = enum { foreground, background };

/// Which of git's task functions a task has.
fn hasPhase(task: Task, phase: Phase) bool {
    return switch (task) {
        .gc => true,
        .pack_refs, .reflog_expire => phase == .foreground,
        else => phase == .background,
    };
}

/// A `maintenance.<task>.<key>` integer.
fn taskInt(repo: *Repository, task: Task, key: []const u8, default: i64) config_mod.ValueError!i64 {
    var name_buf: [96]u8 = undefined;
    // unreachable: the longest task name and key fit
    const name = std.mem.print(&name_buf, "maintenance.{s}.{s}", .{ task.name(), key }) catch unreachable;
    return repo.configuration().getInt(name, default);
}

/// Each task's `auto_condition`; the prefetch has none, so never runs
/// under `--auto`.
fn condition(gpa: Allocator, io: Io, repo: *Repository, task: Task, options: RunOptions) Self.Error!bool {
    const config = repo.configuration();
    const db = repo.objectDatabase();
    switch (task) {
        .prefetch => return false,
        .gc => return collect.autoNeeded(gpa, io, repo, gcOptions(options)),
        .loose_objects => {
            const limit = try taskInt(repo, task, "auto", 100);
            if (limit <= 0) return limit < 0;
            return try db.countLoose(io, @intCast(limit)) >= limit;
        },
        .incremental_repack => {
            if (!try config.getBool("core.multipackindex", true)) return false;
            const limit = try taskInt(repo, task, "auto", 10);
            if (limit <= 0) return limit < 0;
            var arena_instance: std.heap.ArenaAllocator = .init(gpa);
            defer arena_instance.deinit();
            var count: i64 = 0;
            for (try db.listPacks(arena_instance.allocator(), io, .all)) |p| count += @intFromBool(!p.in_midx);
            return count >= limit;
        },
        .geometric_repack => {
            // git 2.56's default, `gc --auto`'s loose-object threshold, where
            // git 2.55's was 100.
            const limit = try taskInt(repo, task, "auto", 6700);
            if (limit <= 0) return limit < 0;
            var arena_instance: std.heap.ArenaAllocator = .init(gpa);
            defer arena_instance.deinit();
            const factor = try taskInt(repo, task, "splitfactor", 2);
            const plan = try repack_mod.planGeometry(arena_instance.allocator(), io, db, .{ .factor = std.math.cast(u32, factor) orelse 2, .local = true });
            if (plan.split != 0) return true;
            return collect.tooManyLoose(io, repo, limit);
        },
        .commit_graph => {
            const limit = try taskInt(repo, task, "auto", 100);
            if (limit <= 0) return limit < 0;
            return try notInGraph(gpa, io, repo, @intCast(limit)) >= limit;
        },
        .pack_refs => return repo.refStore().packRequired(gpa, io, .{ .include = &.{"*"}, .auto = true, .objects = repo.refObjects() }),
        .reflog_expire => {
            const limit = try taskInt(repo, task, "auto", 100);
            if (limit <= 0) return limit < 0;
            return try gc.countExpiring(gpa, io, repo, .{ .ref = "HEAD", .clock = options.clock, .limit = @intCast(limit) }) >= limit;
        },
        .worktree_prune => {
            const limit = try taskInt(repo, task, "auto", 1);
            if (limit <= 0) return limit < 0;
            var judged = try repo.pruneWorktrees(io, .{ .expire = try collect.worktreeExpiry(repo, options.clock), .dry_run = true });
            defer judged.deinit();
            var count: i64 = 0;
            for (judged.pruned) |p| count += @intFromBool(p.reason != .duplicate);
            return count >= limit;
        },
        .rerere_gc => {
            // git 2.56's: the stale records `rerere gc` would prune, where
            // git 2.55 ran it for any record at all.
            const limit = try taskInt(repo, task, "auto", 512);
            if (limit <= 0) return limit < 0;
            return rerere.gcNeeded(gpa, io, repo, options.clock.now, @intCast(limit));
        },
    }
}

/// `dfs_on_ref`: the commits the refs reach that the commit graph does
/// not hold, counted up to `limit`, the walk stopping at each commit it
/// holds.
fn notInGraph(gpa: Allocator, io: Io, repo: *Repository, limit: usize) Self.Error!usize {
    const db = repo.objectDatabase();
    var graph = try db.commitGraph(io);
    defer if (graph) |*g| g.deinit();
    const tips = try ops.repositoryTips(gpa, io, repo);
    defer gpa.free(tips);
    var seen: hash.Oid.Set = .empty;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(hash.Oid) = .empty;
    defer stack.deinit(gpa);
    var count: usize = 0;
    for (tips) |tip| {
        if ((try seen.getOrPut(gpa, tip)).found_existing) continue;
        if (graph) |*g| if (g.find(tip) != null) continue;
        count += 1;
        if (count >= limit) return count;
        try stack.append(gpa, tip);
        while (stack.pop()) |oid| {
            const found = try db.read(io, oid);
            defer db.allocator().free(found.bytes);
            var commit = try object.Commit.parse(gpa, repo.objectFormat(), found.bytes);
            defer commit.deinit();
            for (commit.parents) |parent| {
                if (graph) |*g| if (g.find(parent) != null) continue;
                if ((try seen.getOrPut(gpa, parent)).found_existing) continue;
                count += 1;
                if (count >= limit) return count;
                try stack.append(gpa, parent);
            }
        }
    }
    return count;
}

fn gcOptions(options: RunOptions) collect.Options {
    return .{ .clock = options.clock, .auto = options.auto, .detach = false, .skip_foreground_tasks = true, .hooks = options.hooks, .programs = options.programs, .pack = options.pack };
}

/// Each task's work in `phase`.
fn runTask(gpa: Allocator, io: Io, repo: *Repository, task: Task, phase: Phase, options: RunOptions) Self.Error!void {
    const db = repo.objectDatabase();
    switch (task) {
        .prefetch => {
            const prefetch = options.prefetch orelse return error.PrefetchFailed;
            try prefetch.fetch(prefetch.context, io, repo);
        },
        .gc => switch (phase) {
            .foreground => try collect.foreground(gpa, io, repo, options.clock, options.auto),
            .background => _ = try collect.collect(gpa, io, repo, gcOptions(options)),
        },
        .pack_refs => try gc.packRefs(io, repo, .{ .include = &.{"*"}, .prune = true, .auto = options.auto }),
        .reflog_expire => try gc.expireReflogs(gpa, io, repo, .{ .clock = options.clock }),
        .loose_objects => try packLoose(io, repo, options),
        .incremental_repack => {
            if (!try repo.configuration().getBool("core.multipackindex", true)) return;
            _ = try ops.writeMidx(gpa, io, db, .{});
            _ = try ops.expireMidx(gpa, io, db, null);
            _ = try ops.repackMidx(gpa, io, db, .{ .batch_size = try autoBatchSize(gpa, io, repo), .pack = packOptions(repo, options) });
        },
        .geometric_repack => try geometricRepack(gpa, io, repo, options),
        .commit_graph => _ = try ops.writeConfiguredCommitGraph(gpa, io, repo, .maintenance),
        .worktree_prune => {
            var pruned = try repo.pruneWorktrees(io, .{ .expire = try collect.worktreeExpiry(repo, options.clock) });
            pruned.deinit();
        },
        .rerere_gc => try rerere.gc(gpa, io, repo, options.clock.now),
    }
}

/// The loose-objects task: `prune-packed`, then up to
/// `maintenance.loose-objects.batchSize` (50000; 0 is no limit) loose
/// objects into a pack named `loose-<name>`.
fn packLoose(io: Io, repo: *Repository, options: RunOptions) Self.Error!void {
    const db = repo.objectDatabase();
    _ = try db.prunePacked(io, false);
    var loose = try db.collectLoose(io, .{});
    defer loose.deinit();
    if (loose.entries.len == 0) return;
    const batch = try taskInt(repo, .loose_objects, "batchsize", 50000);
    const take = if (batch <= 0) loose.entries.len else @min(loose.entries.len, @as(usize, @intCast(batch)));
    var pack_options = packOptions(repo, options);
    pack_options.prefix = "loose";
    const dir = try db.openPackDirectory(io);
    defer dir.close(io);
    _ = try db.writePack(io, dir, loose.entries[0..take], pack_options);
    try db.refresh(io);
}

/// The packs a task writes as the pack-objects git runs for it builds
/// them: `pack.writeReverseIndex` read.
fn packOptions(repo: *Repository, options: RunOptions) odb_mod.PackOptions {
    var pack_options = options.pack orelse repo.objectDatabase().packOptions();
    pack_options.reverse_index = pack_options.reverse_index or rev_index.wanted(repo.configuration());
    return pack_options;
}

/// `get_auto_pack_size`: one more than the second largest pack, at most
/// two gigabytes.
fn autoBatchSize(gpa: Allocator, io: Io, repo: *Repository) Self.Error!u64 {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    var largest: u64 = 0;
    var second: u64 = 0;
    for (try repo.objectDatabase().listPacks(arena_instance.allocator(), io, .all)) |p| {
        if (p.size > largest) {
            second = largest;
            largest = p.size;
        } else if (p.size > second) second = p.size;
    }
    return @min(second + 1, std.math.maxInt(i32));
}

/// The geometric-repack task: `repack -d -l --geometric=<factor>` while
/// a pack stays above the split, else every pack as `gc`'s
/// `add_repack_all_option` sets it; `--write-midx` under
/// `core.multiPackIndex`.
fn geometricRepack(gpa: Allocator, io: Io, repo: *Repository, options: RunOptions) Self.Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const factor = std.math.cast(u32, try taskInt(repo, .geometric_repack, "splitfactor", 2)) orelse 2;
    const plan = try repack_mod.planGeometry(arena_instance.allocator(), io, repo.objectDatabase(), .{ .factor = factor, .local = true });
    var repack_options: repack_mod.Options = .{ .delete = true, .local = true, .programs = options.programs, .pack = options.pack };
    if (plan.split < plan.packs.len) {
        repack_options.geometric = factor;
    } else try collect.repackAll(repo, options.clock, &repack_options);
    repack_options.write_midx = try repo.configuration().getBool("core.multipackindex", true);
    _ = try repack_mod.repack(gpa, io, repo, repack_options);
}

/// The file `register` and `unregister` write `maintenance.repo` in: git's
/// global file (`user_config.Locations.globalFile`), or `--config-file`.
pub const RegisterOptions = struct {
    dir: Io.Dir,
    sub_path: []const u8,
    /// `unregister --force`: a repository that is not registered is no
    /// failure.
    force: bool = false,
};

/// Failures of `register` and `unregister`.
pub const RegisterError = Repository.WriteConfigError || config_write.Error || Repository.Error || config_mod.ParseError || Io.Dir.ReadFileAllocError || error{
    /// `unregister` of a repository `maintenance.repo` does not list:
    /// git's "repository '<path>' is not registered".
    NotRegistered,
};

/// git's `maintenance register`: `maintenance.auto` off and
/// `maintenance.strategy` `incremental` unless set, in the repository's
/// own configuration; then its path (`get_maintpath`, the working tree's
/// or the git directory's, resolved) added to `maintenance.repo` in the
/// file `options` names, unless the configuration lists it already.
pub fn register(gpa: Allocator, io: Io, repo: *Repository, options: RegisterOptions) Self.RegisterError!void {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try maintenancePath(io, repo, &path_buf);
    var edits: std.ArrayList(Repository.ConfigEdit) = .empty;
    defer edits.deinit(gpa);
    try edits.append(gpa, .{ .set = .{ .name = "maintenance.auto", .value = "false" } });
    if (!repo.configuration().has("maintenance.strategy")) try edits.append(gpa, .{ .set = .{ .name = "maintenance.strategy", .value = "incremental" } });
    _ = try repo.writeConfig(io, .local, edits.items, .{});
    if (listed(repo.configuration(), path)) return;
    _ = try config_write.editFile(gpa, io, options.dir, options.sub_path, .global, .{}, &.{.{ .add = .{ .name = "maintenance.repo", .value = path } }});
    _ = try repo.refreshConfig(io, .{});
}

/// git's `maintenance unregister`: the repository's path out of
/// `maintenance.repo` in the file `options` names, as that file lists it
/// (git reads `--config-file` alone for the check).
pub fn unregister(gpa: Allocator, io: Io, repo: *Repository, options: RegisterOptions) Self.RegisterError!void {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try maintenancePath(io, repo, &path_buf);
    const text = (try fs.readFileAlloc(gpa, io, options.dir, options.sub_path, 1 << 24)) orelse "";
    defer if (text.len != 0) gpa.free(text);
    var file = try config_mod.Config.parseText(gpa, text, .global);
    defer file.deinit();
    if (!listed(&file, path)) {
        if (options.force) return;
        return error.NotRegistered;
    }
    _ = try config_write.editFile(gpa, io, options.dir, options.sub_path, .global, .{}, &.{.{ .unset = .{ .name = "maintenance.repo", .value = path } }});
    _ = try repo.refreshConfig(io, .{});
}

/// Whether `maintenance.repo` lists `path`.
fn listed(config: *const config_mod.Config, path: []const u8) bool {
    var it = config.iterate(&.{"maintenance.repo"});
    while (it.next()) |entry| if (entry.value) |v| if (std.mem.eql(u8, v, path)) return true;
    return false;
}

/// `get_maintpath`: the working tree, or the git directory of a bare
/// repository, resolved, with forward slashes as git writes it.
fn maintenancePath(io: Io, repo: *Repository, buf: *[Io.Dir.max_path_bytes]u8) Io.Dir.RealPathError![]const u8 {
    const dir = repo.workDirectory() orelse repo.gitDirectory();
    const path = buf[0..try dir.realPath(io, buf)];
    if (@import("builtin").target.os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');
    return path;
}
