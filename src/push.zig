//! `git push`: update a remote's refs from this repository's, with the
//! objects they need.
//!
//! Which refs go where comes from the refspecs the caller names, else the
//! remote's `push` refspecs, else `push.default`: `simple` — the current
//! branch to the branch of the same name, which must be its upstream when
//! pushing to its own remote — `current`, `upstream`, `matching` or
//! `nothing`. A source is a ref this repository has, named in full or as
//! git abbreviates it, or an object name; a destination not named in full
//! is found among the remote's refs or guessed from the source, as git
//! guesses it.
//!
//! Each update is then judged the way git's `set_ref_status_for_push`
//! judges it, before anything is sent: a ref already at the value is up to
//! date; a tag that exists is not moved; a remote value this repository
//! does not have is "fetch first"; one the new value does not descend from
//! is a non-fast-forward; `+` or `force` overrides all of these; and a
//! lease — `--force-with-lease` — refuses an update whose remote value is
//! no longer the one expected, and forces one whose value is. What is left
//! goes to the `pre-push` hook, when the caller has one to run, and then
//! over the wire with every object the remote lacks. After the remote's
//! report, the remote-tracking refs of what was pushed are moved, logged
//! as git logs them, `update by push`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const refs_mod = @import("refs.zig");
const repo_mod = @import("repo.zig");
const revwalk = @import("revwalk.zig");
const refspec_mod = @import("refspec.zig");
const remote_mod = @import("remote.zig");
const program = @import("program.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const sendpack = @import("sendpack.zig");
const objectwalk = @import("objectwalk.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const progress_mod = @import("progress.zig");
const lfspush = @import("lfspush.zig");

const Oid = hash.Oid;
const Refspec = refspec_mod.Refspec;
const Repository = repo_mod.Repository;

/// Errors from a push.
pub const Error = error{
    /// A refspec the caller named that git would refuse.
    InvalidRefspec,
    /// A source that names nothing here: git's "src refspec does not match
    /// any".
    SourceNotFound,
    /// A source or destination that names more than one ref.
    AmbiguousRefspec,
    /// An object name pushed with no destination, or a destination that is
    /// not a full ref name and cannot be guessed.
    DestinationNotFullRefname,
    /// A deletion of a ref the remote does not have.
    RemoteRefNotFound,
    /// Two updates of one remote ref.
    ConflictingRefspecs,
    /// `push.default` is `nothing`, or asks for a branch and `HEAD` is not
    /// on one, or `simple` or `upstream` finds no upstream to push to.
    NoPushDestination,
    /// The `pre-push` hook refused the push.
    PrePushRefused,
} || lfspush.Error || transport.Error || remote_mod.Error || refs_mod.TransactionError || objectwalk.Error || revwalk.Error;

/// What a `pre-push` hook is shown: one line of its input.
pub const PrePushUpdate = struct {
    /// The local ref, or `(delete)` for a deletion.
    local_ref: []const u8,
    /// Its value, zero for a deletion.
    local_oid: Oid,
    remote_ref: []const u8,
    /// The remote's value, zero where it has none.
    remote_oid: Oid,
};

/// The point where a `pre-push` hook runs. relic runs no hook itself; a
/// caller that does — through its own hooks support — plugs it in here.
pub const PrePush = struct {
    context: ?*anyopaque = null,
    /// Called with the remote's name — its URL when it has none — the URL,
    /// and every update about to be sent. Returning false stops the push
    /// before anything is sent.
    run: *const fn (context: ?*anyopaque, remote: []const u8, url: []const u8, updates: []const PrePushUpdate) bool,
};

/// `--force-with-lease=<ref>[:<expect>]`.
pub const Lease = struct {
    /// The remote ref, named in full.
    ref: []const u8,
    /// The value it must have. `null` takes the remote-tracking ref's value,
    /// which is what the bare `--force-with-lease` means; a remote-tracking
    /// ref that does not exist expects the ref not to exist.
    expect: ?Oid = null,
};

/// How a push runs.
pub const Options = struct {
    /// Refspecs, as on git's command line. Empty takes the remote's `push`
    /// refspecs, then `push.default`.
    refspecs: []const []const u8 = &.{},
    /// Update even where the new value does not descend from the old one.
    force: bool = false,
    leases: []const Lease = &.{},
    /// Update every ref or none.
    atomic: bool = false,
    /// `--push-option` values for the remote's hooks.
    push_options: []const []const u8 = &.{},
    /// Work everything out and send nothing.
    dry_run: bool = false,
    /// Who the remote-tracking refs' log entries are written as, and when.
    who: object.Signature,
    pre_push: ?PrePush = null,
    /// What git-lfs's pre-push hook does, done here: other people's locks
    /// checked and the LFS objects the pushed commits point at uploaded,
    /// before any ref is sent. A dry run does neither.
    lfs: lfspush.Options = .{},
    programs: ?program.Programs = null,
    prompt: ?credential.Prompt = null,
    /// Filled in, when the operation fails for want of a credential, with
    /// what a person needs to put it right: see `auth.Failure`.
    auth_failure: ?*auth.Failure = null,
    progress: ?progress_mod.Progress = null,
};

/// What happened to one ref.
pub const RefResult = struct {
    /// The push URL this result is for.
    url: []const u8,
    /// The local ref pushed, or `null` for a deletion or an object name.
    local_ref: ?[]const u8,
    remote_ref: []const u8,
    /// The remote's value before, zero where it had none.
    old: Oid,
    /// The value pushed, zero for a deletion.
    new: Oid,
    status: Status,
    /// Whether an update that would otherwise be refused was forced.
    forced: bool = false,
    /// The remote's reason, for `rejected_by_remote`.
    message: ?[]const u8 = null,

    /// What became of the update.
    pub const Status = enum {
        /// Updated.
        ok,
        /// Already at that value.
        up_to_date,
        /// Not sent: the new value does not descend from the old.
        rejected_non_fast_forward,
        /// Not sent: the remote's value is not here, so whether this
        /// descends from it is unknown.
        rejected_fetch_first,
        /// Not sent: a tag that already exists on the remote.
        rejected_already_exists,
        /// Not sent: the old or the new value is not a commit.
        rejected_needs_force,
        /// Not sent: the remote's value is not what the lease expected.
        rejected_stale,
        /// Sent and refused by the remote; `message` says why.
        rejected_by_remote,
        /// Not applied: the push was atomic and another ref was refused.
        atomic_failed,
        /// Worked out and not sent, for a dry run.
        not_sent,
    };

    /// Whether this ref was refused.
    pub fn rejected(r: RefResult) bool {
        return switch (r.status) {
            .ok, .up_to_date, .not_sent => false,
            else => true,
        };
    }
};

/// What a push did.
pub const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    refs: []const RefResult,
    /// Whether the remote took the pack.
    unpack_ok: bool = true,
    /// Why it did not.
    unpack_message: ?[]const u8 = null,

    /// Release everything.
    pub fn deinit(outcome: *Outcome) void {
        outcome.arena.deinit();
        outcome.* = undefined;
    }

    /// Whether any ref was refused — git's exit status of 1.
    pub fn anyRejected(outcome: *const Outcome) bool {
        if (!outcome.unpack_ok) return true;
        for (outcome.refs) |r| {
            if (r.rejected()) return true;
        }
        return false;
    }
};

/// An update worked out from a refspec.
const Update = struct {
    local_ref: ?[]const u8,
    new: Oid,
    remote_ref: []const u8,
    force: bool,
};

/// Push from `repo` to `remote_name`, a configured remote or a URL. A
/// remote with several push URLs is pushed to each in turn, as git pushes
/// to each, and every URL's results are in the outcome.
pub fn push(gpa: Allocator, io: Io, repo: *Repository, remote_name: []const u8, options: Options) Error!Outcome {
    var outcome: Outcome = .{ .arena = .init(gpa), .refs = &.{} };
    errdefer outcome.arena.deinit();
    const arena = outcome.arena.allocator();

    var remote = try remote_mod.Remote.get(gpa, &repo.config, remote_name);
    defer remote.deinit();

    var specs: std.ArrayList(Refspec) = .empty;
    for (options.refspecs) |text| {
        try specs.append(arena, Refspec.parse(try arena.dupe(u8, text), .push) catch return error.InvalidRefspec);
    }
    if (specs.items.len == 0) {
        for (remote.push) |spec| try specs.append(arena, spec);
    }
    if (specs.items.len == 0) try defaultRefspecs(arena, gpa, io, repo, &remote, remote_name, &specs);

    var results: std.ArrayList(RefResult) = .empty;
    for (remote.push_urls) |url| {
        try pushTo(arena, gpa, io, repo, &remote, try arena.dupe(u8, url), specs.items, options, &results, &outcome);
    }
    outcome.refs = results.items;
    return outcome;
}

/// One push URL's part of a push.
fn pushTo(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    url: []const u8,
    specs: []const Refspec,
    options: Options,
    all_results: *std.ArrayList(RefResult),
    outcome: *Outcome,
) Error!void {
    var session = try transport.Session.open(gpa, io, url, .receive_pack, repo.kind, .{
        .programs = options.programs,
        .config = &repo.config,
        .service_program = remote.receive_pack,
        .progress = options.progress,
        .prompt = options.prompt,
        .auth_failure = options.auth_failure,
    });
    defer session.close(io);
    var remote_refs = try session.listRefs(gpa, io, &.{});
    defer remote_refs.deinit();

    var local_refs = try repo.refs.list(gpa, io, "refs/");
    defer local_refs.deinit();

    const updates = try matchRefs(arena, gpa, io, repo, &local_refs, &remote_refs, specs);

    // Judge each before anything is sent.
    var results: std.ArrayList(RefResult) = .empty;
    for (updates) |u| {
        const old = if (remote_refs.find(u.remote_ref)) |r| r.oid else Oid.zero(repo.kind);
        var result: RefResult = .{
            .url = url,
            .local_ref = u.local_ref,
            .remote_ref = u.remote_ref,
            .old = old,
            .new = u.new,
            .status = .ok,
        };
        try judge(gpa, io, repo, remote, &result, u.force or options.force, options.leases);
        try results.append(arena, result);
    }

    var any_refused = false;
    for (results.items) |r| {
        if (r.rejected()) any_refused = true;
    }
    if (options.atomic and any_refused) {
        for (results.items) |*r| {
            if (r.status == .ok) r.status = .atomic_failed;
        }
    }

    var commands: std.ArrayList(sendpack.Command) = .empty;
    for (results.items) |r| {
        if (r.status != .ok) continue;
        try commands.append(arena, .{ .name = r.remote_ref, .old = r.old, .new = r.new });
    }

    if (options.pre_push) |hook| {
        var lines: std.ArrayList(PrePushUpdate) = .empty;
        for (results.items) |r| {
            switch (r.status) {
                .rejected_non_fast_forward, .rejected_stale, .up_to_date => continue,
                else => {},
            }
            try lines.append(arena, .{
                .local_ref = if (r.new.isZero()) "(delete)" else (r.local_ref orelse r.remote_ref),
                .local_oid = r.new,
                .remote_ref = r.remote_ref,
                .remote_oid = r.old,
            });
        }
        if (lines.items.len != 0 and !hook.run(hook.context, remote.name orelse url, url, lines.items)) {
            return error.PrePushRefused;
        }
    }

    if (options.dry_run) {
        for (results.items) |*r| {
            if (r.status == .ok) r.status = .not_sent;
        }
        try all_results.appendSlice(arena, results.items);
        return;
    }

    if (commands.items.len != 0) {
        var include: std.ArrayList(Oid) = .empty;
        for (commands.items) |c| {
            if (!c.new.isZero()) try include.append(arena, c.new);
        }
        var exclude: std.ArrayList(Oid) = .empty;
        for (remote_refs.refs) |r| {
            if (r.unborn) continue;
            if (try repo.odb.exists(io, r.oid)) try exclude.append(arena, r.oid);
        }
        var objects = try objectwalk.missing(gpa, io, &repo.odb, include.items, exclude.items);
        defer objects.deinit();

        var remote_refs_pushed: std.ArrayList([]const u8) = .empty;
        for (commands.items) |c| {
            if (!c.new.isZero()) try remote_refs_pushed.append(arena, c.name);
        }
        try lfspush.beforePush(gpa, io, repo, remote.name orelse url, remote_refs_pushed.items, objects.entries, .{
            .programs = options.programs,
            .prompt = options.prompt,
            .progress = options.progress,
        }, options.lfs);

        var report = try session.push(gpa, io, &repo.odb, .{
            .commands = commands.items,
            .objects = objects.entries,
            .atomic = options.atomic,
            .push_options = options.push_options,
            .who = options.who,
            .progress = options.progress,
        });
        defer report.deinit();
        if (!report.unpack_ok) {
            outcome.unpack_ok = false;
            if (report.unpack_message) |m| outcome.unpack_message = try arena.dupe(u8, m);
        }
        for (results.items) |*r| {
            if (r.status != .ok) continue;
            if (!report.unpack_ok) {
                r.status = .rejected_by_remote;
                r.message = outcome.unpack_message;
                continue;
            }
            if (report.find(r.remote_ref)) |said| {
                if (!said.ok) {
                    r.status = .rejected_by_remote;
                    if (said.message) |m| r.message = try arena.dupe(u8, m);
                }
            }
        }
    }

    // What the remote took moves its remote-tracking ref, as git moves it.
    if (remote.name != null) {
        for (results.items) |r| {
            if (r.status != .ok and r.status != .up_to_date) continue;
            try updateTracking(gpa, io, repo, remote, r, options.who);
        }
    }
    try all_results.appendSlice(arena, results.items);
}

/// The refspecs `push.default` asks for when none are named.
fn defaultRefspecs(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    remote_name: []const u8,
    specs: *std.ArrayList(Refspec),
) Error!void {
    const mode_text = repo.config.get("push.default") orelse "simple";
    if (std.ascii.eqlIgnoreCase(mode_text, "nothing")) return error.NoPushDestination;
    if (std.ascii.eqlIgnoreCase(mode_text, "matching")) {
        try specs.append(arena, try Refspec.parse(":", .push));
        return;
    }
    const current = (try repo.refs.currentBranch(gpa, io)) orelse return error.NoPushDestination;
    defer gpa.free(current);
    const branch_ref = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{current});
    if (std.ascii.eqlIgnoreCase(mode_text, "current")) {
        try specs.append(arena, try Refspec.parse(try std.fmt.allocPrint(arena, "{s}:{s}", .{ branch_ref, branch_ref }), .push));
        return;
    }
    var branch = try remote_mod.Branch.get(gpa, &repo.config, current);
    defer branch.deinit();
    const same_remote = if (branch.remote) |r| std.mem.eql(u8, r, remote.name orelse remote_name) else false;
    const upstream_mode = std.ascii.eqlIgnoreCase(mode_text, "upstream") or std.ascii.eqlIgnoreCase(mode_text, "tracking");
    if (!upstream_mode and !same_remote) {
        // `simple` to a remote that is not the branch's own: the branch of
        // the same name.
        try specs.append(arena, try Refspec.parse(try std.fmt.allocPrint(arena, "{s}:{s}", .{ branch_ref, branch_ref }), .push));
        return;
    }
    if (!same_remote or branch.merge.len != 1) return error.NoPushDestination;
    const upstream = branch.merge[0];
    // `simple` pushes to the upstream only when it has the branch's name.
    if (!upstream_mode and !std.mem.eql(u8, upstream, branch_ref)) return error.NoPushDestination;
    try specs.append(arena, try Refspec.parse(try std.fmt.allocPrint(arena, "{s}:{s}", .{ branch_ref, try arena.dupe(u8, upstream) }), .push));
}

/// git's `ref_rev_parse_rules`, used to find what a short name names.
const rev_parse_rules = [_][]const u8{
    "{s}",
    "refs/{s}",
    "refs/tags/{s}",
    "refs/heads/{s}",
    "refs/remotes/{s}",
    "refs/remotes/{s}/HEAD",
};

fn refnameMatch(abbrev: []const u8, full: []const u8) usize {
    for (rev_parse_rules, 0..) |rule, i| {
        const star = std.mem.indexOf(u8, rule, "{s}").?;
        const before = rule[0..star];
        const after = rule[star + 3 ..];
        if (full.len != before.len + abbrev.len + after.len) continue;
        if (!std.mem.startsWith(u8, full, before)) continue;
        if (!std.mem.endsWith(u8, full, after)) continue;
        if (!std.mem.eql(u8, full[before.len .. before.len + abbrev.len], abbrev)) continue;
        return rev_parse_rules.len - i;
    }
    return 0;
}

/// The one name among `names` that `abbrev` names best, or `null`.
fn bestMatch(abbrev: []const u8, names: []const []const u8) Error!?[]const u8 {
    var best: ?[]const u8 = null;
    var best_score: usize = 0;
    var tied = false;
    for (names) |name| {
        const score = refnameMatch(abbrev, name);
        if (score == 0) continue;
        if (score > best_score) {
            best = name;
            best_score = score;
            tied = false;
        } else if (score == best_score) tied = true;
    }
    if (tied) return error.AmbiguousRefspec;
    return best;
}

const Source = struct { name: ?[]const u8, oid: Oid };

/// What a push source names here: `HEAD`, a ref as git abbreviates it, or
/// an object name.
fn resolveSource(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, local_names: []const []const u8, text: []const u8) Error!Source {
    if (std.mem.eql(u8, text, "HEAD")) {
        const head = (try repo.refs.read(gpa, io, "HEAD")) orelse return error.SourceNotFound;
        switch (head) {
            .symbolic => |target| {
                defer gpa.free(target);
                const resolved = (try repo.refs.resolve(gpa, io, target)) orelse return error.SourceNotFound;
                defer gpa.free(resolved.name);
                return .{ .name = try arena.dupe(u8, target), .oid = resolved.oid };
            },
            .direct => |oid| return .{ .name = null, .oid = oid },
        }
    }
    if (try bestMatch(text, local_names)) |name| {
        const resolved = (try repo.refs.resolve(gpa, io, name)) orelse return error.SourceNotFound;
        defer gpa.free(resolved.name);
        return .{ .name = name, .oid = resolved.oid };
    }
    if (text.len == repo.kind.hexLen()) {
        const oid = Oid.parse(repo.kind, text) catch return error.SourceNotFound;
        if (try repo.odb.exists(io, oid)) return .{ .name = null, .oid = oid };
    }
    return error.SourceNotFound;
}

/// git's `match_push_refs`: every update the refspecs ask for.
fn matchRefs(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    local_refs: *const refs_mod.Store.Listing,
    remote_refs: *const protocol.RefList,
    specs: []const Refspec,
) Error![]const Update {
    var local_names: std.ArrayList([]const u8) = .empty;
    for (local_refs.entries) |e| try local_names.append(arena, try arena.dupe(u8, e.name));
    var remote_names: std.ArrayList([]const u8) = .empty;
    for (remote_refs.refs) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) continue;
        try remote_names.append(arena, try arena.dupe(u8, r.name));
    }

    var out: std.ArrayList(Update) = .empty;
    for (specs) |spec| {
        if (spec.negative) continue;
        if (spec.matching) {
            for (local_names.items) |name| {
                if (!std.mem.startsWith(u8, name, "refs/heads/")) continue;
                if (remote_refs.find(name) == null) continue;
                const src = try resolveSource(arena, gpa, io, repo, local_names.items, name);
                try out.append(arena, .{ .local_ref = name, .new = src.oid, .remote_ref = name, .force = spec.force });
            }
            continue;
        }
        if (spec.pattern) {
            for (local_names.items) |name| {
                const dst = (try spec.mapSource(arena, name)) orelse continue;
                const src = try resolveSource(arena, gpa, io, repo, local_names.items, name);
                try out.append(arena, .{ .local_ref = name, .new = src.oid, .remote_ref = dst, .force = spec.force });
            }
            continue;
        }
        if (spec.src.len == 0) {
            // `:dst`: a deletion of what the remote has.
            const dst_text = spec.dst.?;
            const dst = if (std.mem.startsWith(u8, dst_text, "refs/"))
                (if (remote_refs.find(dst_text) != null) dst_text else null)
            else
                try bestMatch(dst_text, remote_names.items);
            const name = dst orelse return error.RemoteRefNotFound;
            try out.append(arena, .{ .local_ref = null, .new = .zero(repo.kind), .remote_ref = try arena.dupe(u8, name), .force = spec.force });
            continue;
        }
        const src = try resolveSource(arena, gpa, io, repo, local_names.items, spec.src);
        const dst: []const u8 = blk: {
            const dst_text = spec.dst orelse break :blk src.name orelse return error.DestinationNotFullRefname;
            if (std.mem.startsWith(u8, dst_text, "refs/")) break :blk try arena.dupe(u8, dst_text);
            if (try bestMatch(dst_text, remote_names.items)) |found| break :blk found;
            // Guessed from the source, as git guesses it.
            if (src.name) |name| {
                if (std.mem.startsWith(u8, name, "refs/heads/")) break :blk try std.fmt.allocPrint(arena, "refs/heads/{s}", .{dst_text});
                if (std.mem.startsWith(u8, name, "refs/tags/")) break :blk try std.fmt.allocPrint(arena, "refs/tags/{s}", .{dst_text});
            }
            const header = try repo.odb.readHeader(io, src.oid);
            switch (header.type) {
                .commit => break :blk try std.fmt.allocPrint(arena, "refs/heads/{s}", .{dst_text}),
                .tag => break :blk try std.fmt.allocPrint(arena, "refs/tags/{s}", .{dst_text}),
                else => return error.DestinationNotFullRefname,
            }
        };
        if (!refspec_mod.checkRefFormat(dst, .{})) return error.DestinationNotFullRefname;
        try out.append(arena, .{ .local_ref = src.name, .new = src.oid, .remote_ref = dst, .force = spec.force });
    }

    // Negative refspecs take away what they match, by source.
    var kept: std.ArrayList(Update) = .empty;
    for (out.items) |u| {
        if (u.local_ref) |name| {
            if (refspec_mod.excluded(specs, name)) continue;
        }
        for (kept.items) |k| {
            if (std.mem.eql(u8, k.remote_ref, u.remote_ref)) return error.ConflictingRefspecs;
        }
        try kept.append(arena, u);
    }
    return kept.items;
}

/// git's `set_ref_status_for_push` for one update.
fn judge(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    result: *RefResult,
    force: bool,
    leases: []const Lease,
) Error!void {
    const deletion = result.new.isZero();
    if (!deletion and result.old.eql(result.new)) {
        result.status = .up_to_date;
        return;
    }
    var forced = force;
    var reject: ?RefResult.Status = null;
    for (leases) |lease| {
        if (!std.mem.eql(u8, lease.ref, result.remote_ref)) continue;
        const expected = lease.expect orelse (try trackingValue(gpa, io, repo, remote, result.remote_ref)) orelse Oid.zero(repo.kind);
        if (!result.old.eql(expected)) {
            reject = .rejected_stale;
        } else forced = true;
    }
    if (reject == null and !deletion and !result.old.isZero()) {
        if (std.mem.startsWith(u8, result.remote_ref, "refs/tags/")) {
            reject = .rejected_already_exists;
        } else if (!try repo.odb.exists(io, result.old)) {
            reject = .rejected_fetch_first;
        } else {
            const old_commit = commitOf(io, repo, result.old);
            const new_commit = commitOf(io, repo, result.new);
            if (old_commit == null or new_commit == null) {
                reject = .rejected_needs_force;
            } else if (!try revwalk.isAncestor(gpa, io, &repo.odb, old_commit.?, new_commit.?)) {
                reject = .rejected_non_fast_forward;
            }
        }
    }
    // Forcing beats every refusal above — a stale lease too, when the
    // force came from `+` or `force` rather than from the lease — as in git.
    if (reject) |status| {
        if (forced) result.forced = true else result.status = status;
    }
}

fn commitOf(io: Io, repo: *Repository, oid: Oid) ?Oid {
    const peeled = repo.peel(io, oid) catch return null;
    const header = repo.odb.readHeader(io, peeled) catch return null;
    return if (header.type == .commit) peeled else null;
}

/// The remote-tracking ref for `remote_ref`, by the remote's fetch
/// refspecs: git's `remote_find_tracking`.
fn trackingName(gpa: Allocator, remote: *const remote_mod.Remote, remote_ref: []const u8) Allocator.Error!?[]u8 {
    if (refspec_mod.excluded(remote.fetch, remote_ref)) return null;
    for (remote.fetch) |spec| {
        if (spec.negative) continue;
        if (try spec.mapSource(gpa, remote_ref)) |dst| return dst;
    }
    return null;
}

fn trackingValue(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, remote_ref: []const u8) Error!?Oid {
    const name = (try trackingName(gpa, remote, remote_ref)) orelse return null;
    defer gpa.free(name);
    const resolved = (try repo.refs.resolve(gpa, io, name)) orelse return null;
    defer gpa.free(resolved.name);
    return resolved.oid;
}

fn updateTracking(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, result: RefResult, who: object.Signature) Error!void {
    const name = (try trackingName(gpa, remote, result.remote_ref)) orelse return;
    defer gpa.free(name);
    const current = try repo.refs.resolve(gpa, io, name);
    defer if (current) |c| gpa.free(c.name);
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    if (result.new.isZero()) {
        if (current == null) return;
        try tx.delete(name, .any);
        try tx.commit(io, null);
        const path = try @import("reflog.zig").pathFor(gpa, name);
        defer gpa.free(path);
        repo.refs.dirFor(name).deleteFile(io, path) catch {};
        return;
    }
    if (current) |c| {
        if (c.oid.eql(result.new)) return;
    }
    try tx.update(name, .{ .direct = result.new }, .any);
    try tx.commit(io, .{ .who = who, .message = "update by push", .policy = repo.reflogPolicy() });
}

const builtin = @import("builtin");
const testing = std.testing;
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// Two bare remotes with the same history, and two working repositories
/// with the same history and the same new work, each cloned from one of
/// them: git pushes one pair and relic the other.
const PushTwins = struct {
    gpa: Allocator,
    root: testing.TmpDir,
    root_path: []u8,
    env: std.process.Environ.Map,
    /// Settings git's push is run with, in front of the subcommand.
    git_settings: []const []const u8 = &.{},

    fn init(gpa: Allocator, io: Io) !PushTwins {
        var root = testing.tmpDir(.{ .iterate = true });
        errdefer root.cleanup();
        const root_path = try testremote.absolutePath(gpa, io, root.dir);
        errdefer gpa.free(root_path);
        var env = try testremote.environ(gpa);
        errdefer env.deinit();
        // Commits made in two places come out with the same names.
        try env.put("GIT_AUTHOR_DATE", "1700000000 +0000");
        try env.put("GIT_COMMITTER_DATE", "1700000000 +0000");
        var t: PushTwins = .{ .gpa = gpa, .root = root, .root_path = root_path, .env = env };

        var source = try testremote.historyRepo(gpa, io, 3);
        defer source.deinit();
        const source_path = try testremote.absolutePath(gpa, io, source.dir);
        defer gpa.free(source_path);
        for ([_][]const u8{ "git", "relic" }) |who| {
            const bare = try std.fmt.allocPrint(gpa, "{s}/remote-{s}.git", .{ root_path, who });
            defer gpa.free(bare);
            const work = try std.fmt.allocPrint(gpa, "{s}/work-{s}", .{ root_path, who });
            defer gpa.free(work);
            try t.git(root.dir, &.{ "clone", "-q", "--bare", source_path, bare });
            try t.git(root.dir, &.{ "clone", "-q", bare, work });
        }
        // New work in the one, brought into the other whole, so both hold
        // the same objects under the same names.
        var work_git = try root.dir.openDir(io, "work-git", .{});
        defer work_git.close(io);
        try work_git.writeFile(io, .{ .sub_path = "new.txt", .data = "new work\n" });
        // Bytes that do not compress, so the pack is larger than a small
        // `http.postBuffer` and is sent in chunks.
        var noise: [16 * 1024]u8 = undefined;
        var state: u64 = 0x9e3779b97f4a7c15;
        for (&noise) |*b| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            b.* = @truncate(state);
        }
        try work_git.writeFile(io, .{ .sub_path = "noise.bin", .data = &noise });
        try t.git(work_git, &.{ "add", "-A" });
        try t.git(work_git, &.{ "commit", "-q", "-m", "new work" });
        try t.git(work_git, &.{ "branch", "feature" });
        try t.git(work_git, &.{ "tag", "-a", "v2", "-m", "two" });
        const work_git_path = try std.fmt.allocPrint(gpa, "{s}/work-git", .{root_path});
        defer gpa.free(work_git_path);
        var work_relic = try root.dir.openDir(io, "work-relic", .{});
        defer work_relic.close(io);
        try t.git(work_relic, &.{ "fetch", "-q", "--update-head-ok", work_git_path, "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*" });
        try t.git(work_relic, &.{ "reset", "-q", "--hard" });
        return t;
    }

    fn deinit(t: *PushTwins) void {
        t.env.deinit();
        t.gpa.free(t.root_path);
        t.root.cleanup();
    }

    fn git(t: *PushTwins, dir: Io.Dir, args: []const []const u8) !void {
        const out = try testremote.gitInputEnv(t.gpa, testing.io, dir, &t.env, args, "", true);
        t.gpa.free(out);
    }

    fn gitOut(t: *PushTwins, dir: Io.Dir, args: []const []const u8) ![]u8 {
        return testremote.gitInputEnv(t.gpa, testing.io, dir, &t.env, args, "", false) catch |err| switch (err) {
            error.GitFailed => t.gpa.dupe(u8, "failed"),
            else => err,
        };
    }

    /// Run the same thing in both remotes: a history moved on by someone
    /// else.
    fn inBothRemotes(t: *PushTwins, args: []const []const u8) !void {
        for ([_][]const u8{ "remote-git.git", "remote-relic.git" }) |name| {
            var dir = try t.root.dir.openDir(testing.io, name, .{});
            defer dir.close(testing.io);
            try t.git(dir, args);
        }
    }

    /// `git push <args>` in the one, `push` with `options` in the other;
    /// the remotes and the remote-tracking refs come out the same.
    fn pushBoth(t: *PushTwins, git_args: []const []const u8, options: Options) !Outcome {
        const io = testing.io;
        var work_git = try t.root.dir.openDir(io, "work-git", .{});
        defer work_git.close(io);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(t.gpa);
        try argv.appendSlice(t.gpa, t.git_settings);
        try argv.appendSlice(t.gpa, &.{ "push", "-q", "--porcelain" });
        try argv.appendSlice(t.gpa, git_args);
        const git_failed = if (testremote.gitInputEnv(t.gpa, io, work_git, &t.env, argv.items, "", false)) |out| blk: {
            t.gpa.free(out);
            break :blk false;
        } else |_| true;

        var work_relic = try t.root.dir.openDir(io, "work-relic", .{ .iterate = true });
        defer work_relic.close(io);
        var repo = try Repository.open(t.gpa, io, work_relic, .{});
        defer repo.deinit(io);
        var opts = options;
        opts.who = test_who;
        opts.programs = .{ .environ = &t.env };
        var outcome = try push(t.gpa, io, &repo, "origin", opts);
        errdefer outcome.deinit();
        try testing.expectEqual(git_failed, outcome.anyRejected());
        try t.expectSame();
        return outcome;
    }

    fn expectSame(t: *PushTwins) !void {
        const io = testing.io;
        const format = "--format=%(refname) %(objectname) %(symref)";
        for ([_][2][]const u8{ .{ "remote-git.git", "remote-relic.git" }, .{ "work-git", "work-relic" } }) |pair| {
            var a = try t.root.dir.openDir(io, pair[0], .{});
            defer a.close(io);
            var b = try t.root.dir.openDir(io, pair[1], .{});
            defer b.close(io);
            const theirs = try t.gitOut(a, &.{ "for-each-ref", format });
            defer t.gpa.free(theirs);
            const ours = try t.gitOut(b, &.{ "for-each-ref", format });
            defer t.gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
        var remote = try t.root.dir.openDir(io, "remote-relic.git", .{});
        defer remote.close(io);
        try t.git(remote, &.{ "fsck", "--strict", "--no-dangling" });
    }
};

test "a push leaves the remote and the remote-tracking refs as git push leaves them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();

    var first = try twins.pushBoth(&.{ "origin", "main", "feature", "v2" }, .{ .who = test_who, .refspecs = &.{ "main", "feature", "v2" } });
    defer first.deinit();
    for (first.refs) |r| try testing.expectEqual(RefResult.Status.ok, r.status);

    // Up to date, and a deletion.
    var second = try twins.pushBoth(&.{ "origin", "main", ":refs/heads/feature" }, .{ .who = test_who, .refspecs = &.{ "main", ":refs/heads/feature" } });
    defer second.deinit();
    try testing.expectEqual(RefResult.Status.up_to_date, second.refs[0].status);
    try testing.expectEqual(RefResult.Status.ok, second.refs[1].status);

    // `push.default` of `simple`: the current branch, to its upstream.
    var simple = try twins.pushBoth(&.{}, .{ .who = test_who });
    defer simple.deinit();
    try testing.expectEqual(@as(usize, 1), simple.refs.len);
    try testing.expectEqualStrings("refs/heads/main", simple.refs[0].remote_ref);
}

test "refusals are git's: non-fast-forward, fetch first, an existing tag, a stale lease, and atomic all or none" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();

    // Someone else moved main on both remotes, and this side has not seen
    // it: fetch first. The tag v1 is there already.
    try twins.inBothRemotes(&.{ "update-ref", "refs/heads/elsewhere", "refs/heads/main" });
    try twins.inBothRemotes(&.{ "tag", "-f", "v2", "main" });
    var refused = try twins.pushBoth(&.{ "origin", "main", "v2" }, .{ .who = test_who, .refspecs = &.{ "main", "v2" } });
    defer refused.deinit();
    try testing.expectEqual(RefResult.Status.ok, refused.refs[0].status);
    try testing.expectEqual(RefResult.Status.rejected_already_exists, refused.refs[1].status);

    // Someone else moved main on past this side's history: fetch first.
    for ([_][]const u8{ "remote-git.git", "remote-relic.git" }) |name| {
        var dir = try twins.root.dir.openDir(io, name, .{});
        defer dir.close(io);
        const made = try twins.gitOut(dir, &.{ "commit-tree", "main^{tree}", "-p", "main", "-m", "elsewhere" });
        defer gpa.free(made);
        try twins.git(dir, &.{ "update-ref", "refs/heads/main", std.mem.trimEnd(u8, made, "\n") });
    }
    var fetch_first = try twins.pushBoth(&.{ "origin", "feature:main" }, .{ .who = test_who, .refspecs = &.{"feature:main"} });
    defer fetch_first.deinit();
    try testing.expectEqual(RefResult.Status.rejected_fetch_first, fetch_first.refs[0].status);
    try twins.inBothRemotes(&.{ "update-ref", "refs/heads/main", "refs/heads/main~1" });

    // A history rewritten here: non-fast-forward, then forced.
    var work_relic = try twins.root.dir.openDir(io, "work-relic", .{});
    defer work_relic.close(io);
    var work_git = try twins.root.dir.openDir(io, "work-git", .{});
    defer work_git.close(io);
    for ([_]Io.Dir{ work_git, work_relic }) |dir| try twins.git(dir, &.{ "reset", "-q", "--hard", "main~2" });
    var non_ff = try twins.pushBoth(&.{ "origin", "main" }, .{ .who = test_who, .refspecs = &.{"main"} });
    defer non_ff.deinit();
    try testing.expectEqual(RefResult.Status.rejected_non_fast_forward, non_ff.refs[0].status);

    // A lease on a value the remote no longer has is stale; on the value it
    // has, the update is forced.
    var stale = try twins.pushBoth(&.{ "origin", "--force-with-lease=refs/heads/main:refs/tags/v1", "main" }, .{
        .who = test_who,
        .refspecs = &.{"main"},
        .leases = &.{.{ .ref = "refs/heads/main", .expect = try tagTarget(gpa, io, work_relic, "v1") }},
    });
    defer stale.deinit();
    try testing.expectEqual(RefResult.Status.rejected_stale, stale.refs[0].status);
    var leased = try twins.pushBoth(&.{ "origin", "--force-with-lease=refs/heads/main", "main" }, .{
        .who = test_who,
        .refspecs = &.{"main"},
        .leases = &.{.{ .ref = "refs/heads/main" }},
    });
    defer leased.deinit();
    try testing.expectEqual(RefResult.Status.ok, leased.refs[0].status);
    try testing.expect(leased.refs[0].forced);

    // Atomic: one refused, none applied.
    var atomic = try twins.pushBoth(&.{ "origin", "--atomic", "feature", "v2" }, .{ .who = test_who, .refspecs = &.{ "feature", "v2" }, .atomic = true });
    defer atomic.deinit();
    try testing.expectEqual(RefResult.Status.atomic_failed, atomic.refs[0].status);
}

fn tagTarget(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) !Oid {
    var repo = try Repository.open(gpa, io, dir, .{});
    defer repo.deinit(io);
    const full = try std.fmt.allocPrint(gpa, "refs/tags/{s}", .{name});
    defer gpa.free(full);
    const resolved = (try repo.refs.resolve(gpa, io, full)).?;
    defer gpa.free(resolved.name);
    return repo.peel(io, resolved.oid);
}

test "the pre-push hook point is shown what git's pre-push hook is shown, and can stop the push" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();

    // git's own hook, noting its arguments and its input.
    var work_git = try twins.root.dir.openDir(io, "work-git", .{});
    defer work_git.close(io);
    const hook_log = try std.fmt.allocPrint(gpa, "{s}/pre-push.log", .{twins.root_path});
    defer gpa.free(hook_log);
    const hook = try std.fmt.allocPrint(gpa, "#!/bin/sh\necho \"$1\" >> {s}\ncat >> {s}\nexit 0\n", .{ hook_log, hook_log });
    defer gpa.free(hook);
    try work_git.writeFile(io, .{ .sub_path = ".git/hooks/pre-push", .data = hook });
    {
        const file = try work_git.openFile(io, ".git/hooks/pre-push", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
    twins.git_settings = &.{ "-c", "core.hooksPath=.git/hooks" };

    const Seen = struct {
        text: std.ArrayList(u8) = .empty,
        allow: bool = true,
        fn run(context: ?*anyopaque, remote: []const u8, url: []const u8, updates: []const PrePushUpdate) bool {
            _ = url;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.text.print(testing.allocator, "{s}\n", .{remote}) catch return false;
            for (updates) |u| {
                self.text.print(testing.allocator, "{s} {f} {s} {f}\n", .{ u.local_ref, u.local_oid, u.remote_ref, u.remote_oid }) catch return false;
            }
            return self.allow;
        }
    };
    var seen: Seen = .{};
    defer seen.text.deinit(gpa);
    var outcome = try twins.pushBoth(&.{ "origin", "main", "feature" }, .{
        .who = test_who,
        .refspecs = &.{ "main", "feature" },
        .pre_push = .{ .context = &seen, .run = Seen.run },
    });
    outcome.deinit();
    const theirs = try twins.root.dir.readFileAlloc(io, "pre-push.log", gpa, .unlimited);
    defer gpa.free(theirs);
    try testing.expectEqualStrings(theirs, seen.text.items);

    // Refused by the hook point, nothing is sent.
    seen.allow = false;
    var work_relic = try twins.root.dir.openDir(io, "work-relic", .{ .iterate = true });
    defer work_relic.close(io);
    var repo = try Repository.open(gpa, io, work_relic, .{});
    defer repo.deinit(io);
    try testing.expectError(error.PrePushRefused, push(gpa, io, &repo, "origin", .{
        .who = test_who,
        .refspecs = &.{"v2"},
        .pre_push = .{ .context = &seen, .run = Seen.run },
    }));
    var remote = try twins.root.dir.openDir(io, "remote-relic.git", .{});
    defer remote.close(io);
    const tags = try twins.gitOut(remote, &.{ "tag", "-l", "v2" });
    defer gpa.free(tags);
    try testing.expectEqualStrings("", tags);
}

test "a push over ssh and over HTTP leaves the remote as git push leaves it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_]bool{ false, true }) |over_http| {
        var twins = try PushTwins.init(gpa, io);
        defer twins.deinit();
        const fake = try testremote.fakeSsh(gpa, io, twins.root.dir);
        defer gpa.free(fake);
        var server: ?*testremote.HttpServer = null;
        defer if (server) |s| s.stop();
        if (over_http) server = try testremote.HttpServer.start(gpa, io, twins.root.dir, .{});
        for ([_][2][]const u8{ .{ "work-git", "remote-git.git" }, .{ "work-relic", "remote-relic.git" } }) |pair| {
            var work = try twins.root.dir.openDir(io, pair[0], .{});
            defer work.close(io);
            var remote_dir = try twins.root.dir.openDir(io, pair[1], .{});
            defer remote_dir.close(io);
            try twins.git(remote_dir, &.{ "config", "http.receivepack", "true" });
            const url = if (server) |s|
                try s.url(gpa, pair[1])
            else
                try std.fmt.allocPrint(gpa, "ssh://example.invalid{s}/{s}", .{ twins.root_path, pair[1] });
            defer gpa.free(url);
            try twins.git(work, &.{ "remote", "set-url", "origin", url });
            try twins.git(work, &.{ "config", "core.sshCommand", fake });
            // Small enough that the push is sent in chunks as it is written.
            try twins.git(work, &.{ "config", "http.postBuffer", "1024" });
        }
        var outcome = try twins.pushBoth(&.{ "origin", "main", "feature", "v2", ":refs/heads/side" }, .{
            .who = test_who,
            .refspecs = &.{ "main", "feature", "v2", ":refs/heads/side" },
        });
        defer outcome.deinit();
        for (outcome.refs) |r| try testing.expectEqual(RefResult.Status.ok, r.status);
    }
}

test "a repository on this machine refuses its checked-out branch as receive-pack does, and one with hooks is refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var target = try testremote.historyRepo(gpa, io, 2);
    defer target.deinit();
    const target_path = try testremote.absolutePath(gpa, io, target.dir);
    defer gpa.free(target_path);

    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();
    try here.exec(io, &.{ "remote", "add", "origin", target_path });
    try here.exec(io, &.{ "fetch", "-q", "origin" });
    try here.exec(io, &.{ "checkout", "-q", "-b", "main", "origin/main" });
    try here.writeFile(io, "mine.txt", "mine\n");
    try here.exec(io, &.{ "add", "-A" });
    try here.exec(io, &.{ "commit", "-q", "-m", "mine" });

    var repo = try Repository.open(gpa, io, here.dir, .{});
    defer repo.deinit(io);
    var outcome = try push(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{ "main", "main:refs/heads/other" } });
    defer outcome.deinit();
    try testing.expectEqual(RefResult.Status.rejected_by_remote, outcome.refs[0].status);
    try testing.expectEqualStrings("branch is currently checked out", outcome.refs[0].message.?);
    try testing.expectEqual(RefResult.Status.ok, outcome.refs[1].status);
    // git refuses the same.
    here.report_failures = false;
    try testing.expectError(error.GitFailed, here.exec(io, &.{ "push", "-q", "origin", "main" }));

    // A hook is a file with its executable bit set, which Windows does not
    // keep.
    if (builtin.os.tag == .windows) return;
    try target.writeFile(io, ".git/hooks/pre-receive", "#!/bin/sh\nexit 0\n");
    {
        const file = try target.dir.openFile(io, ".git/hooks/pre-receive", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
    try testing.expectError(error.RemoteHooksNotRun, push(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{"main:refs/heads/third"} }));
}

test "a remote with two push URLs is pushed to both, as git pushes to both" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    for ([_][]const u8{ "git", "relic" }) |who| {
        const first = try std.fmt.allocPrint(gpa, "{s}/remote-{s}.git", .{ twins.root_path, who });
        defer gpa.free(first);
        const second = try std.fmt.allocPrint(gpa, "{s}/extra-{s}.git", .{ twins.root_path, who });
        defer gpa.free(second);
        try twins.git(twins.root.dir, &.{ "clone", "-q", "--bare", first, second });
        const work_name = try std.fmt.allocPrint(gpa, "work-{s}", .{who});
        defer gpa.free(work_name);
        var work = try twins.root.dir.openDir(io, work_name, .{});
        defer work.close(io);
        try twins.git(work, &.{ "config", "--add", "remote.origin.pushurl", first });
        try twins.git(work, &.{ "config", "--add", "remote.origin.pushurl", second });
    }
    var outcome = try twins.pushBoth(&.{ "origin", "main" }, .{ .who = test_who, .refspecs = &.{"main"} });
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 2), outcome.refs.len);
    try testing.expect(!std.mem.eql(u8, outcome.refs[0].url, outcome.refs[1].url));
    var extra_git = try twins.root.dir.openDir(io, "extra-git.git", .{});
    defer extra_git.close(io);
    var extra_relic = try twins.root.dir.openDir(io, "extra-relic.git", .{});
    defer extra_relic.close(io);
    const theirs = try twins.gitOut(extra_git, &.{ "rev-parse", "main" });
    defer gpa.free(theirs);
    const ours = try twins.gitOut(extra_relic, &.{ "rev-parse", "main" });
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
}
