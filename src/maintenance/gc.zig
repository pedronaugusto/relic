//! The housekeeping `git gc` runs over refs and their logs: `pack-refs`
//! and `reflog expire`, each read from the repository's configuration as
//! git reads it.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const object = @import("../object/object.zig");
const refs_mod = @import("../refs/refs.zig");
const ref_names = @import("../names.zig").ref;
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const text = @import("../text.zig");
const date = text.date;
const glob = text.glob;
const Repository = repo_mod.Repository;

/// Failures of the ref housekeeping.
pub const Error = repo_mod.Error || refs_mod.Store.ExpireLogError || refs_mod.Store.ReadLogError || error{
    /// A `gc.*reflogExpire*` value, or an expiry the caller gave, that is
    /// no date git reads: git dies on it.
    InvalidExpiryDate,
};

/// Which refs `packRefs` packs: git's `pack-refs` options.
pub const PackRefsOptions = struct {
    /// `--include`; `refs/tags/*` when none is given, `*` for `--all`.
    include: []const []const u8 = &.{"refs/tags/*"},
    /// `--exclude`.
    exclude: []const []const u8 = &.{},
    /// `--prune`, git's default: the packed refs' loose files go.
    prune: bool = true,
    /// `--auto`: only when git's heuristics say the refs need it.
    auto: bool = false,
};

/// git's `pack-refs` over the repository's refs, in either format:
/// `refs.Store.pack` with this repository's objects to peel tags and to
/// leave loose a ref whose object is missing.
pub fn packRefs(io: Io, repo: *Repository, options: PackRefsOptions) Self.Error!void {
    try repo.refStore().pack(repo.objectDatabase().allocator(), io, .{
        .include = options.include,
        .exclude = options.exclude,
        .prune = options.prune,
        .auto = options.auto,
        .objects = repo.refObjects(),
    });
}

/// An expiry: an entry dated before it goes. `never` is 0, which nothing
/// is before; `now` and `all` are the greatest time.
pub const Expiry = i64;

/// The greatest expiry, which every entry is before: `now`, `all`.
pub const expire_all: Expiry = std.math.maxInt(i64);

/// git's `parse_expiry_date`: `never` and `false` are 0, `all` and `now`
/// the greatest time, and anything else a date as `approxidate_careful`
/// reads it against `clock`; `null` where git reports an error.
pub fn parseExpiry(value: []const u8, clock: date.Context) ?Expiry {
    if (std.mem.eql(u8, value, "never") or std.mem.eql(u8, value, "false")) return 0;
    if (std.mem.eql(u8, value, "all") or std.mem.eql(u8, value, "now")) return expire_all;
    return date.approximate(value, clock);
}

/// How `expireReflogs` treats each log: git's `reflog expire` options.
pub const ReflogExpireOptions = struct {
    /// The time now, which relative dates are read against and the
    /// defaults count back from; relic reads no clock.
    clock: date.Context,
    /// The logs to expire, full ref names; `null` for every log of this
    /// worktree's store, git's `--all --single-worktree`.
    refs: ?[]const []const u8 = null,
    /// `--expire`: entries older than this go. `null` takes
    /// `gc.<pattern>.reflogExpire` for the first pattern the ref matches,
    /// else `gc.reflogExpire`, else 90 days before `clock`.
    expire: ?Expiry = null,
    /// `--expire-unreachable`: entries older than this go when their old
    /// or new value is a commit the ref's tip does not reach. `null` takes
    /// `gc.<pattern>.reflogExpireUnreachable`, `gc.reflogExpireUnreachable`,
    /// else 30 days before `clock`.
    expire_unreachable: ?Expiry = null,
    /// `--rewrite`.
    rewrite: bool = false,
    /// `--updateref`.
    update_ref: bool = false,
};

/// The two expiries of one log.
const Policy = struct { total: Expiry, unreached: Expiry };

/// One `gc.<pattern>.*` section's expiries; a slot the section does not
/// set is 0, never, as git's zeroed entry leaves it.
const PatternPolicy = struct { pattern: []const u8, policy: Policy };

/// The `gc.*reflogExpire*` settings, read in git's order: the defaults
/// the last value of each, the patterns in the order they first appear.
const Settings = struct {
    defaults: Policy,
    patterns: []PatternPolicy,

    fn read(arena: Allocator, config: *const config_mod.Config, clock: date.Context) Self.Error!Settings {
        const now = clock.now.toSeconds();
        // The documented defaults: git 2.55's REFLOG_EXPIRE_OPTIONS_INIT
        // gives the two the other way round.
        var settings: Settings = .{ .defaults = .{ .total = now - 90 * std.time.s_per_day, .unreached = now - 30 * std.time.s_per_day }, .patterns = &.{} };
        var patterns: std.ArrayList(PatternPolicy) = .empty;
        for (config.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.section, "gc")) continue;
            const unreachable_slot = if (std.mem.eql(u8, entry.name, "reflogexpireunreachable"))
                true
            else if (std.mem.eql(u8, entry.name, "reflogexpire")) false else continue;
            const value = entry.value orelse return error.InvalidExpiryDate;
            const expiry = parseExpiry(value, clock) orelse return error.InvalidExpiryDate;
            const policy: *Policy = if (!entry.has_subsection) &settings.defaults else blk: {
                for (patterns.items) |*p| if (std.mem.eql(u8, p.pattern, entry.subsection)) break :blk &p.policy;
                try patterns.append(arena, .{ .pattern = entry.subsection, .policy = .{ .total = 0, .unreached = 0 } });
                break :blk &patterns.items[patterns.items.len - 1].policy;
            };
            if (unreachable_slot) policy.unreached = expiry else policy.total = expiry;
        }
        settings.patterns = patterns.items;
        return settings;
    }

    /// git's `reflog_expire_options_set_refname`: what the caller gave,
    /// then the first pattern `ref` matches, then `refs/stash`, which
    /// never expires unless configured, then the defaults.
    fn forRef(settings: *const Settings, arena: Allocator, ref: []const u8, options: ReflogExpireOptions) Allocator.Error!Policy {
        var found = settings.defaults;
        for (settings.patterns) |p| {
            if (try glob.matches(arena, p.pattern, ref, .{ .pathname = false })) {
                found = p.policy;
                break;
            }
        } else if (std.mem.eql(u8, ref, ref_names.stash)) found = .{ .total = 0, .unreached = 0 };
        return .{ .total = options.expire orelse found.total, .unreached = options.expire_unreachable orelse found.unreached };
    }
};

/// git's `reflog expire` over this repository's logs, each under the
/// ref's lock (files) or the stack's (reftable), as `refs.Store.expireLog`
/// takes it: an entry goes when it is older than the log's expiry, or
/// older than its unreachable expiry while its old or new value is a
/// commit its ref does not reach -- `HEAD`'s by any ref, and with the
/// unreachable expiry `never` any ref's -- or when it is past the
/// unreachable expiry of a ref that names no commit. A value that is not
/// a commit, or that cannot be read, keeps its entry.
pub fn expireReflogs(gpa: Allocator, io: Io, repo: *Repository, options: ReflogExpireOptions) Self.Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const settings = try Settings.read(arena, repo.configuration(), options.clock);
    const names = options.refs orelse try repo.refStore().logNames(gpa, arena, io);
    for (names) |name| {
        var keeper: Keeper = .{ .gpa = gpa, .io = io, .repo = repo, .ref = name, .policy = try settings.forRef(arena, name, options) };
        defer keeper.deinit();
        try repo.refStore().expireLog(gpa, io, &keeper, .{ .name = name, .rewrite = options.rewrite, .update_ref = options.update_ref });
        if (keeper.failure) |err| return err;
    }
}

/// git's `should_expire_reflog_ent` over one log, prepared on its first
/// entry, which the store hands over with the ref's lock held, as git's
/// `reflog_expiry_prepare` runs under it.
const Keeper = struct {
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    ref: []const u8,
    policy: Policy,
    /// git's `unreachable_expire_kind`, once prepared.
    kind: ?Kind = null,
    /// The commits the tips reach, walked the first time an entry asks.
    reached: ?Oid.Set = null,
    tips: std.ArrayList(Oid) = .empty,
    /// What went wrong reading the objects: every entry from there on is
    /// kept, and `expireReflogs` reports it.
    failure: ?Self.Error = null,

    const Kind = enum {
        /// Every entry past the unreachable expiry goes.
        always,
        /// Reachability from the ref's own tip.
        normal,
        /// Reachability from every ref's tip.
        head,
    };

    fn deinit(k: *Keeper) void {
        if (k.reached) |*set| set.deinit(k.gpa);
        k.tips.deinit(k.gpa);
    }

    pub fn keep(k: *Keeper, entry: refs_mod.LogEntry, nth: usize) bool {
        _ = nth;
        if (k.failure != null) return true;
        const when = entry.who.when_secs;
        if (when < k.policy.total) return false;
        if (when >= k.policy.unreached) return true;
        const kind = k.kind orelse k.prepare() catch |err| return k.fail(err);
        k.kind = kind;
        if (kind == .always) return false;
        const old_gone = k.isUnreachable(entry.old) catch |err| return k.fail(err);
        const new_gone = k.isUnreachable(entry.new) catch |err| return k.fail(err);
        return !(old_gone or new_gone);
    }

    fn fail(k: *Keeper, err: Self.Error) bool {
        k.failure = err;
        return true;
    }

    /// git's `reflog_expiry_prepare`.
    fn prepare(k: *Keeper) Self.Error!Kind {
        if (k.policy.unreached <= k.policy.total) return .always;
        const stripped = ref_names.parseWorktreeRef(k.ref).bare;
        if (k.policy.unreached == 0 or std.mem.eql(u8, stripped, "HEAD")) {
            var listed = try k.repo.refStore().list(k.gpa, k.io, "refs/");
            defer listed.deinit();
            for (listed.entries) |named| switch (named.target) {
                .direct => |oid| if (try k.commitOf(oid)) |c| try k.tips.append(k.gpa, c),
                .symbolic => {},
            };
            return .head;
        }
        const tip = (try k.repo.refStore().readOid(k.gpa, k.io, k.ref)) orelse return .always;
        const commit = (try k.commitOf(tip)) orelse return .always;
        try k.tips.append(k.gpa, commit);
        return .normal;
    }

    /// git's `lookup_commit_reference_gently`: the commit `oid` names or
    /// a tag of it peels to, or `null` for anything else, a missing
    /// object included.
    fn commitOf(k: *Keeper, oid: Oid) Self.Error!?Oid {
        if (oid.isZero()) return null;
        const db = k.repo.objectDatabase();
        if (!try db.exists(k.io, oid)) return null;
        const peeled = k.repo.peel(k.io, oid) catch |err| switch (err) {
            error.ObjectNotFound => return null,
            else => |e| return e,
        };
        if (!try db.exists(k.io, peeled)) return null;
        return if ((try db.readHeader(k.io, peeled)).type == .commit) peeled else null;
    }

    /// git's `is_unreachable`: whether `oid` names a commit the tips do
    /// not reach. The null name, and anything not a commit, is reached.
    fn isUnreachable(k: *Keeper, oid: Oid) Self.Error!bool {
        const commit = (try k.commitOf(oid)) orelse return false;
        if (k.reached == null) k.reached = try k.walk();
        return !k.reached.?.contains(commit);
    }

    /// Every commit the tips reach; a commit that cannot be read reaches
    /// nothing further, as git's walk skips it.
    fn walk(k: *Keeper) Self.Error!Oid.Set {
        var reached: Oid.Set = .empty;
        errdefer reached.deinit(k.gpa);
        var pending: std.ArrayList(Oid) = .empty;
        defer pending.deinit(k.gpa);
        try pending.appendSlice(k.gpa, k.tips.items);
        const db = k.repo.objectDatabase();
        while (pending.pop()) |oid| {
            if ((try reached.getOrPut(k.gpa, oid)).found_existing) continue;
            if (!try db.exists(k.io, oid)) continue;
            const found = try db.read(k.io, oid);
            defer db.allocator().free(found.bytes);
            if (found.type != .commit) continue;
            var commit = try object.Commit.parse(k.gpa, k.repo.objectFormat(), found.bytes);
            defer commit.deinit();
            try pending.appendSlice(k.gpa, commit.parents);
        }
        return reached;
    }
};
