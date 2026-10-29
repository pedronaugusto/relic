//! git's `gc` (`builtin/gc.c`, `cmd_gc`): with `--auto` only when git's
//! thresholds ask for it, under the `gc.pid` lock, `pack-refs` and
//! `reflog expire`, then `repack` as `add_repack_all_option` sets it,
//! `prune`, `worktree prune`, `rerere gc`, the pack directory's garbage
//! and the commit graph, each read from the repository's configuration as
//! git reads it.
//!
//! relic runs it on the caller's task. `detach` is git's daemonized run as
//! the repository sees it: a failure the last one recorded in `gc.log`
//! stops it, and its own failure, or the warning that too many loose
//! objects are left, is recorded there.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const fs = @import("../fs/fs.zig");
const odb_mod = @import("../odb/odb.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const rerere = @import("../merge/rerere.zig");
const worktrees = @import("../checkout/worktrees.zig");
const program = @import("../process/program.zig");
const date = @import("../text.zig").date;
const decimal = @import("../text.zig").decimal;
const gc = @import("gc.zig");
const prune_mod = @import("prune.zig");
const repack_mod = @import("repack.zig");
const ops = @import("maintenance.zig");
const object_walk = @import("../walk/object.zig").walk;
const filter_spec = @import("../wire.zig").filter_spec;
const ignore = @import("../patterns.zig").ignore;
const Repository = repo_mod.Repository;

/// What `gc` prunes: `--prune=<date>`, `--no-prune`.
pub const Prune = union(enum) {
    /// `--no-prune`: nothing goes; unreachable objects stay in a cruft
    /// pack or loose.
    never,
    /// `now`, as git spells it: `repack -a`, then every unreachable loose
    /// object goes.
    now,
    /// Any other date: unreachable objects no newer than it go.
    at: date.Expiry,
};

/// git's `gc` options. Those left `null` are read from the repository's
/// configuration as git reads them.
pub const Options = struct {
    /// The time now, which the expiries count back from.
    clock: date.Context,
    /// `--auto`: only when there are more loose objects than `gc.auto`
    /// (6700) or more packs than `gc.autoPackLimit` (50), and the
    /// `pre-auto-gc` hook agrees.
    auto: bool = false,
    /// `--aggressive`: deltas found again, with `gc.aggressiveWindow` (250)
    /// and `gc.aggressiveDepth` (50).
    aggressive: bool = false,
    /// `--force`: run whatever `gc.pid` says.
    force: bool = false,
    /// `null` takes `gc.pruneExpire`, two weeks.
    prune: ?Prune = null,
    /// `--cruft`, `--no-cruft`; `null` takes `gc.cruftPacks`, true.
    cruft: ?bool = null,
    /// `--max-cruft-size`; `null` takes `gc.maxCruftSize`.
    max_cruft_bytes: ?u64 = null,
    /// The filter of the repack of every pack, `repack --filter`'s; `null`
    /// takes `gc.repackFilter` (a `sparse:oid=` in it by its full object
    /// name), into `gc.repackFilterTo` when that is set.
    filter: ?object_walk.Filter = null,
    /// `--expire-to`: `repack`'s, with cruft packs.
    expire_to: @FieldType(repack_mod.Options, "expire_to") = null,
    /// `--keep-largest-pack`; `null` keeps the packs at least
    /// `gc.bigPackThreshold` large, when it is set.
    keep_largest_pack: ?bool = null,
    /// `--detach`; `null` takes `gc.autoDetach` (true) with `auto`.
    detach: ?bool = null,
    /// `--skip-foreground-tasks`: no `pack-refs` and no `reflog expire`.
    skip_foreground_tasks: bool = false,
    /// The `pre-auto-gc` hook's runner; `null` runs none.
    hooks: ?*hooks_mod.Runner = null,
    /// What runs `gc.recentObjectsHook`.
    programs: ?program.Programs = null,
    /// How each pack is built.
    /// `null` takes the repository's settings, `Odb.packOptions`.
    pack: ?odb_mod.PackOptions = null,
};

/// Whether `gc` ran, or why not.
pub const Outcome = enum {
    ran,
    /// `--auto`, and nothing asked for it.
    not_needed,
    /// `--auto`, and the `pre-auto-gc` hook failed.
    hook_declined,
    /// `detach`, and `gc.log` holds the failure of a run newer than
    /// `gc.logExpiry` (a day): git's "The last gc run reported the
    /// following", which it leaves to be put right first.
    last_failed,
    /// `--auto`, and another gc holds `gc.pid`: `holder` says which.
    running,
};

/// Which gc holds `gc.pid`.
pub const Holder = struct {
    pid: u64,
    host_buf: [fs.max_host_name]u8 = undefined,
    host_len: usize = 0,

    pub fn host(h: *const Holder) []const u8 {
        return h.host_buf[0..h.host_len];
    }
};

/// What `gc` did.
pub const Report = struct {
    outcome: Outcome,
    holder: ?Holder = null,
    repack: ?repack_mod.Report = null,
    prune: ?prune_mod.Report = null,
    /// Administrative directories `worktree prune` took away.
    worktrees_pruned: u32 = 0,
    /// Files of packs with an index and no pack, taken away.
    pack_garbage: u32 = 0,
    /// The commit graph written, by its checksum.
    commit_graph: ?Oid = null,
    /// `--auto` left more loose objects than `gc.auto`: git's "There are
    /// too many unreachable loose objects".
    too_many_loose: bool = false,
};

/// Failures of `gc`.
pub const Error = repack_mod.Error || prune_mod.Error || filter_spec.Error || filter_spec.WalkError || ignore.Error || worktrees.Error || rerere.Error || hooks_mod.Error ||
    ops.MaintenanceError || fs.LockError || fs.CommitError || fs.HostNameError || Io.Writer.Error ||
    Io.Dir.StatFileError || Io.Dir.ReadFileError || Io.Dir.DeleteFileError || error{
    /// Another gc holds `gc.pid`, and neither `auto` nor `force` was
    /// given: git's "gc is already running".
    GcRunning,
};

/// git's `gc_config`, the parts relic acts on.
const Settings = struct {
    pack_refs: bool,
    prune_reflogs: bool,
    aggressive_window: i64,
    aggressive_depth: i64,
    auto_threshold: i64,
    auto_pack_limit: i64,
    detach_auto: bool,
    cruft: bool,
    max_cruft: u64,
    prune: Prune,
    worktree_expire: date.Expiry,
    log_expire: date.Expiry,
    big_pack: u64,

    fn read(repo: *Repository, clock: date.Context) Self.Error!Settings {
        const config = repo.configuration();
        const pack_refs = if (config.get("gc.packrefs")) |v|
            (if (std.mem.eql(u8, v, "notbare")) !repo.isBare() else try config_mod.parseBool(v))
        else
            true;
        return .{
            .pack_refs = pack_refs,
            .prune_reflogs = !(try isNever(config, "gc.reflogexpire", clock) and try isNever(config, "gc.reflogexpireunreachable", clock)),
            .aggressive_window = try config.getInt(c_int, "gc.aggressivewindow", 250),
            .aggressive_depth = try config.getInt(c_int, "gc.aggressivedepth", 50),
            .auto_threshold = try config.getInt(c_int, "gc.auto", 6700),
            .auto_pack_limit = try config.getInt(c_int, "gc.autopacklimit", 50),
            .detach_auto = try config.getBool("gc.autodetach", true),
            .cruft = try config.getBool("gc.cruftpacks", true),
            .max_cruft = @intCast(@max(try config.getInt(c_ulong, "gc.maxcruftsize", 0), 0)),
            .prune = try parsePrune(config.get("gc.pruneexpire") orelse "2.weeks.ago", clock),
            .worktree_expire = try parseDate(config.get("gc.worktreepruneexpire") orelse "3.months.ago", clock),
            .log_expire = try parseDate(config.get("gc.logexpiry") orelse "1.day.ago", clock),
            .big_pack = @intCast(@max(try config.getInt(c_ulong, "gc.bigpackthreshold", 0), 0)),
        };
    }
};

/// `gc_config_is_timestamp_never`.
fn isNever(config: *const config_mod.Config, name: []const u8, clock: date.Context) Self.Error!bool {
    const value = config.get(name) orelse return false;
    return (try parseDate(value, clock)).eql(.fromRaw(0));
}

fn parseDate(value: []const u8, clock: date.Context) Self.Error!date.Expiry {
    return date.parseExpiry(value, clock) orelse error.InvalidExpiryDate;
}

/// A prune date as `cmd_gc` keeps it: `now` by its spelling.
pub fn parsePrune(value: []const u8, clock: date.Context) Self.Error!Prune {
    if (std.mem.eql(u8, value, "now")) return .now;
    return .{ .at = try parseDate(value, clock) };
}

/// git's `gc`, as `options` asks.
pub fn collect(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Report {
    var s = try Settings.read(repo, options.clock);
    if (options.prune) |p| s.prune = p;
    if (options.cruft) |c| s.cruft = c;
    if (options.max_cruft_bytes) |m| s.max_cruft = m;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var plan: repack_mod.Options = .{ .delete = true, .local = true, .expire_to = options.expire_to, .programs = options.programs, .pack = options.pack orelse repo.objectDatabase().packOptions() };
    if (options.aggressive) {
        plan.pack.?.reuse_packed = false;
        if (s.aggressive_depth > 0) plan.pack.?.depth = std.math.cast(u32, s.aggressive_depth) orelse std.math.maxInt(u32);
        if (s.aggressive_window > 0) plan.pack.?.window = std.math.cast(u32, s.aggressive_window) orelse std.math.maxInt(u32);
    }
    try repackFilter(arena, io, repo, options, &plan);
    defer if (options.filter == null) if (plan.filter_to) |to| to.dir.close(io);
    const detach = options.detach orelse (options.auto and s.detach_auto);
    if (options.auto) {
        if (!try needToGc(arena, io, repo, &s, &plan)) return .{ .outcome = .not_needed };
        if (options.hooks) |runner| {
            if (!(try runner.run(io, "pre-auto-gc", .{})).succeeded()) return .{ .outcome = .hook_declined };
        }
    } else {
        const keep = if (options.keep_largest_pack) |largest|
            (if (largest) try basePacks(arena, io, repo, 0) else &.{})
        else if (s.big_pack != 0)
            try basePacks(arena, io, repo, s.big_pack)
        else
            &.{};
        allPacked(&plan, &s, keep);
    }
    if (detach and try lastFailed(io, repo, s.log_expire)) return .{ .outcome = .last_failed };

    if (try lockGc(gpa, io, repo, options)) |holder| {
        if (options.auto) return .{ .outcome = .running, .holder = holder };
        return error.GcRunning;
    }
    // Git's pid file is a tempfile its exit removes; one already gone is no failure of the gc.
    defer fs.removeLeftover(io, repo.commonDirectory().get(), "gc.pid");

    var report: Report = .{ .outcome = .ran };
    if (!options.skip_foreground_tasks) try foreground(gpa, io, repo, options.clock, options.auto);
    background(gpa, io, repo, options, &s, plan, &report) catch |err| {
        if (detach) try writeLog(gpa, io, repo, "error: gc failed: {s}\n", .{@errorName(err)});
        return err;
    };
    if (detach and report.too_many_loose) {
        try writeLog(gpa, io, repo, "warning: There are too many unreachable loose objects; run 'git prune' to remove them.\n", .{});
    } else {
        try deleteIfThere(io, repo.gitDirectory().get(), "gc.log");
    }
    return report;
}

/// `gc_condition`: whether `gc --auto` would run, the `pre-auto-gc` hook
/// asked as `need_to_gc` asks it.
pub fn autoNeeded(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!bool {
    var s = try Settings.read(repo, options.clock);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    var plan: repack_mod.Options = .{};
    if (!try needToGc(arena_instance.allocator(), io, repo, &s, &plan)) return false;
    if (options.hooks) |runner| return (try runner.run(io, "pre-auto-gc", .{})).succeeded();
    return true;
}

/// `add_repack_all_option` as `maintenance`'s geometric repack takes it,
/// over `plan`, with the repository's `gc.*` settings.
pub fn repackAll(repo: *Repository, clock: date.Context, plan: *repack_mod.Options) Self.Error!void {
    const s = try Settings.read(repo, clock);
    allPacked(plan, &s, &.{});
}

/// `gc.worktreePruneExpire`, three months unless set.
pub fn worktreeExpiry(repo: *Repository, clock: date.Context) Self.Error!date.Expiry {
    return (try Settings.read(repo, clock)).worktree_expire;
}

/// The foreground tasks `gc` runs before it would detach, as `maintenance`
/// runs them for its gc task: `pack-refs` and `reflog expire`, as the
/// settings say.
pub fn foreground(gpa: Allocator, io: Io, repo: *Repository, clock: date.Context, auto: bool) Self.Error!void {
    const s = try Settings.read(repo, clock);
    if (s.pack_refs) try gc.packRefs(io, repo, .{ .include = &.{"*"}, .prune = true, .auto = auto });
    if (s.prune_reflogs) try gc.expireReflogs(gpa, io, repo, .{ .clock = clock });
}

/// `gc.repackFilter` and `gc.repackFilterTo` on `plan`, as
/// `add_repack_all_option` passes them, unless the caller gave a filter.
fn repackFilter(arena: Allocator, io: Io, repo: *Repository, options: Options, plan: *repack_mod.Options) Self.Error!void {
    if (options.filter) |f| {
        plan.filter = f;
        return;
    }
    const config = repo.configuration();
    const text = config.get("gc.repackfilter") orelse return;
    if (text.len == 0) return;
    const spec = try filter_spec.parse(arena, text);
    var lookup: NamedBlob = .{ .arena = arena, .io = io, .repo = repo };
    plan.filter = try filter_spec.toWalk(arena, spec, &lookup);
    const to = config.get("gc.repackfilterto") orelse return;
    if (to.len == 0) return;
    // A path and the start of the packs' names, as pack-objects takes it.
    const dir_name = std.Io.Dir.path.dirname(to) orelse ".";
    plan.filter_to = .{ .dir = try Io.Dir.cwd().openDir(io, dir_name, .{}), .prefix = std.Io.Dir.path.basename(to) };
}

/// A `sparse:oid=` blob by its full object name: what maintenance, below
/// the revision parser, can look up.
const NamedBlob = struct {
    pub const Error = Self.Error;

    arena: Allocator,
    io: Io,
    repo: *Repository,

    pub fn rules(l: *NamedBlob, name: []const u8) Self.Error!?*const ignore.Rules {
        const oid = hash.Oid.parse(l.repo.objectFormat(), name) catch return null;
        const db = l.repo.objectDatabase();
        if (!try db.exists(l.io, oid)) return null;
        const found = try db.read(l.io, oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .blob) return null;
        const r = try l.arena.create(ignore.Rules);
        r.* = try .init(l.arena, .{});
        try r.addText(try l.arena.dupe(u8, found.bytes), "", "sparse:oid", 0);
        return r;
    }
};

/// What git's daemonized gc does after the foreground tasks.
fn background(gpa: Allocator, io: Io, repo: *Repository, options: Options, s: *const Settings, plan: repack_mod.Options, report: *Report) Self.Error!void {
    if (!try repo.configuration().getBool("extensions.preciousobjects", false)) {
        report.repack = try repack_mod.repack(gpa, io, repo, plan);
        switch (s.prune) {
            .never => {},
            .now => report.prune = try prune_mod.prune(gpa, io, repo, .{ .expire = date.expire_all, .programs = options.programs }),
            .at => |at| report.prune = try prune_mod.prune(gpa, io, repo, .{ .expire = at, .programs = options.programs }),
        }
    }
    var pruned = try repo.pruneWorktrees(io, .{ .expire = s.worktree_expire });
    report.worktrees_pruned = @intCast(pruned.pruned.len);
    pruned.deinit();
    try rerere.gc(gpa, io, repo, options.clock.now);
    try repo.objectDatabase().refresh(io);
    report.pack_garbage = try repo.objectDatabase().removePackGarbage(io);
    report.commit_graph = try ops.writeConfiguredCommitGraph(gpa, io, repo, .gc);
    if (options.auto) report.too_many_loose = try tooManyLoose(io, repo, s.auto_threshold);
}

/// `need_to_gc`: with too many packs, every pack into one as
/// `add_repack_all_option` says, the packs at least `gc.bigPackThreshold`
/// large kept (only the largest when they are too many themselves); with
/// too many loose objects, `repack -d -l` without bitmaps.
fn needToGc(arena: Allocator, io: Io, repo: *Repository, s: *Settings, plan: *repack_mod.Options) Self.Error!bool {
    if (s.auto_threshold <= 0) return false;
    if (try tooManyPacks(arena, io, repo, s.auto_pack_limit)) {
        var keep: []const []const u8 = &.{};
        if (s.big_pack != 0) {
            keep = try basePacks(arena, io, repo, s.big_pack);
            if (@as(i64, @intCast(keep.len)) >= s.auto_pack_limit) keep = try basePacks(arena, io, repo, 0);
        }
        allPacked(plan, s, keep);
        return true;
    }
    if (try tooManyLoose(io, repo, s.auto_threshold)) {
        plan.mode = .loose;
        plan.write_bitmaps = false;
        // `add_repack_incremental_option` passes no filter.
        plan.filter = .none;
        return true;
    }
    return false;
}

/// `too_many_packs`: more local packs without a `.keep` than the limit.
fn tooManyPacks(arena: Allocator, io: Io, repo: *Repository, limit: i64) Self.Error!bool {
    if (limit <= 0) return false;
    const listed = try repo.objectDatabase().listPacks(arena, io, .own);
    var count: i64 = 0;
    for (listed) |p| count += @intFromBool(!p.kept);
    return count > limit;
}

/// `too_many_loose_objects`: the loose objects in `objects/17`, times 256,
/// above `limit` rounded up to a multiple of 256.
pub fn tooManyLoose(io: Io, repo: *Repository, limit: i64) Self.Error!bool {
    const threshold = @divFloor(limit + 255, 256) * 256;
    const hex_len = repo.objectFormat().hexLen() - 2;
    var dir = repo.objectDatabase().objectsDirectory().get().openDir(io, "17", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer dir.close(io);
    var count: i64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len != hex_len) continue;
        for (entry.name) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => break,
        } else count += 1;
    }
    return count * 256 > threshold;
}

/// `find_base_packs`: the local packs that are not cruft at least `limit`
/// large, or with no limit the largest, as `--keep-pack` names them.
fn basePacks(arena: Allocator, io: Io, repo: *Repository, limit: u64) Self.Error![]const []const u8 {
    const listed = try repo.objectDatabase().listPacks(arena, io, .own);
    var names: std.ArrayList([]const u8) = .empty;
    var largest: ?odb_mod.Odb.PackListing = null;
    for (listed) |p| {
        if (p.cruft) continue;
        if (limit != 0) {
            if (p.size >= limit) try names.append(arena, try arena.print("{s}.pack", .{p.name}));
        } else if (largest == null or largest.?.size < p.size) largest = p;
    }
    if (largest) |p| try names.append(arena, try arena.print("{s}.pack", .{p.name}));
    return names.items;
}

/// `add_repack_all_option`.
fn allPacked(plan: *repack_mod.Options, s: *const Settings, keep: []const []const u8) void {
    plan.keep_packs = keep;
    if (s.prune == .now and !(s.cruft and plan.expire_to != null)) {
        plan.mode = .all;
    } else if (s.cruft) {
        plan.mode = .cruft;
        plan.cruft_expiration = switch (s.prune) {
            .never => null,
            .now => date.expire_all,
            .at => |at| at,
        };
        if (s.max_cruft != 0) plan.max_cruft_bytes = s.max_cruft;
    } else {
        plan.mode = .all_loosen;
        plan.unpack_unreachable = if (s.prune == .at) s.prune.at else null;
    }
}

/// `report_last_gc_error`: `gc.log` newer than the expiry, and not empty.
fn lastFailed(io: Io, repo: *Repository, expire: date.Expiry) Self.Error!bool {
    const dir = repo.gitDirectory().get();
    const stat = dir.statFile(io, "gc.log", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    if (date.instant(stat.mtime).compare(expire) == .lt) return false;
    return stat.size != 0;
}

/// The gc `gc.pid` names, when it holds it as `lock_repo_for_gc` judges:
/// written within twelve hours, `<pid> <host>`, and on another host or
/// a process still there.
fn holderOf(io: Io, repo: *Repository, clock: date.Context) Self.Error!?Holder {
    const dir = repo.commonDirectory().get();
    const stat = dir.statFile(io, "gc.pid", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    if (date.instant(stat.mtime).saturatingDurationTo(date.instant(clock.now)).compare(date.spanHours(12)) == .gt) return null;
    var buf: [fs.max_host_name + 32]u8 = undefined;
    const text = dir.readFile(io, "gc.pid", &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    // `fscanf("%" SCNuMAX " %s")`: a number, blanks, a word.
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const pid = decimal.digits(u64, words.next() orelse return null) orelse return null;
    const host = words.next() orelse return null;
    var holder: Holder = .{ .pid = pid };
    holder.host_len = @min(host.len, holder.host_buf.len);
    @memcpy(holder.host_buf[0..holder.host_len], host[0..holder.host_len]);
    var mine: [fs.max_host_name]u8 = undefined;
    if (!std.mem.eql(u8, holder.host(), try fs.hostName(&mine))) return holder;
    // `kill(pid, 0)`; a platform that cannot say counts it there.
    const alive = if (std.math.cast(u32, pid)) |id| fs.processAlive(id) orelse true else false;
    return if (alive) holder else null;
}

/// `lock_repo_for_gc`: under `gc.pid`'s lock, the gc that holds it
/// unless `force`; else `gc.pid` written as `<pid> <host>`.
fn lockGc(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!?Holder {
    var buffer: [256]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, repo.commonDirectory().get(), .{ .sub_path = "gc.pid", .buffer = &buffer }, .{ .sync = .none, .write_pid = repo.lockfilePid() });
    defer lock.deinit(io);
    if (!options.force) if (try holderOf(io, repo, options.clock)) |holder| return holder;
    var host_buf: [fs.max_host_name]u8 = undefined;
    try lock.writer().print("{d} {s}", .{ fs.currentPid(), try fs.hostName(&host_buf) });
    try lock.commit(io);
    return null;
}

/// `gc.log` replaced, through its lock, by what a detached gc printed.
fn writeLog(gpa: Allocator, io: Io, repo: *Repository, comptime format: []const u8, args: anytype) Self.Error!void {
    var buffer: [256]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, repo.gitDirectory().get(), .{ .sub_path = "gc.log", .buffer = &buffer }, .{ .sync = .none, .write_pid = repo.lockfilePid() });
    defer lock.deinit(io);
    try lock.writer().print(format, args);
    try lock.commit(io);
}

fn deleteIfThere(io: Io, dir: Io.Dir, name: []const u8) Io.Dir.DeleteFileError!void {
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}
