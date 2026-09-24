//! `git fetch`: bring a remote's refs and the objects under them, and keep
//! them where the refspecs say.
//!
//! The refs to take are decided the way git's `get_ref_map` decides them.
//! Refspecs the caller names are taken as given and all of them are for
//! merging; with none, the remote's configured refspecs are, and the refs
//! the current branch's `branch.<name>.merge` names are the ones marked for
//! merging; a remote with neither gives its `HEAD`. Tags follow: a remote
//! tag is taken when this repository does not have it and it points at
//! something the fetch brings or already has, which is checked again once
//! the pack is in. `--tags`, as `TagMode.all`, takes every tag.
//!
//! Each ref is then updated under its own lock, with git's rules and git's
//! reflog message: a new ref is stored, a descendant fast-forwards, a
//! rewritten history needs `+` or `force`, and a tag that already exists
//! with another value is left alone unless forced. A branch checked out in
//! a working tree is never fetched into. `FETCH_HEAD` is written in git's
//! exact format, the refs for merging first. With `prune`, remote-tracking
//! refs whose source is gone are deleted first, with their logs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const fs = @import("fs.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("reflog.zig");
const repo_mod = @import("repo.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");
const revwalk = @import("revwalk.zig");
const fetchpack = @import("fetchpack.zig");
const shallow_mod = @import("shallow.zig");
const partial = @import("partial.zig");
const config_mod = @import("config.zig");
const refspec_mod = @import("refspec.zig");
const remote_mod = @import("remote.zig");
const url_mod = @import("url.zig");
const program = @import("program.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const objectwalk = @import("objectwalk.zig");
const indexpack = @import("indexpack.zig");
const progress_mod = @import("progress.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const warning = @import("warning.zig");

const Oid = hash.Oid;
const Refspec = refspec_mod.Refspec;
const Repository = repo_mod.Repository;

/// Errors from a fetch.
pub const Error = error{
    /// A refspec the caller named that git would refuse.
    InvalidRefspec,
    /// A refspec names a ref the remote does not have.
    RemoteRefNotFound,
    /// Two remote refs would be kept in the same local ref.
    ConflictingRefspecs,
    /// A ref to be updated is the branch a working tree has checked out.
    /// git refuses this too, because the working tree would no longer match
    /// its branch. `Options.update_head_ok` allows it.
    WouldUpdateCheckedOutBranch,
    /// `unshallow` asked of a repository that is not shallow, which git
    /// refuses as making no sense.
    NotShallow,
    /// A filter asked of a remote that is not the repository's promisor:
    /// the objects it would leave out would be missing, not promised.
    NotAPromisorRemote,
    /// An object below a fetched ref is not in the repository after the
    /// pack arrived. `Outcome` is not returned; `Options.missing` names it.
    MissingObject,
} || partial.FilterError || transport.Error || remote_mod.Error || refs_mod.TransactionError || objectwalk.Error ||
    revwalk.Error || fs.AtomicWriteError || Io.Dir.OpenError || shallow_mod.Error;

/// How a fetch runs.
pub const Options = struct {
    /// Refspecs, as on git's command line. Empty takes the remote's
    /// configured ones.
    refspecs: []const []const u8 = &.{},
    /// What happens to tags: `null` takes the remote's `tagOpt`.
    tags: ?remote_mod.TagMode = null,
    /// Delete remote-tracking refs whose source is gone: `null` takes
    /// `remote.<name>.prune`, then `fetch.prune`.
    prune: ?bool = null,
    /// Prune tags too, fetching every tag to know which are gone.
    prune_tags: ?bool = null,
    /// Update refs even where the new value does not descend from the old,
    /// and tags that already exist.
    force: bool = false,
    /// Allow updating a branch a working tree has checked out.
    update_head_ok: bool = false,
    /// Write `FETCH_HEAD`.
    write_fetch_head: bool = true,
    /// Add to `FETCH_HEAD` rather than replace it.
    append: bool = false,
    /// Update every ref or none: one transaction instead of one per ref.
    atomic: bool = false,
    /// Who the reflog entries are written as, and when. relic reads no
    /// clock and no identity.
    who: object.Signature,
    /// The text before `: <what happened>` in each reflog entry. `null`
    /// writes `fetch <remote>` followed by the refspecs, which is what
    /// `git fetch <remote> <refspecs>` writes.
    reflog_action: ?[]const u8 = null,
    /// `--depth`: the history from each fetched tip cut to this many
    /// commits, the boundary written to `.git/shallow`.
    depth: ?u32 = null,
    /// `--deepen`: the boundary moved this many commits further back.
    deepen: ?u32 = null,
    /// `--shallow-since`: the history cut at commits older than this, in
    /// seconds since the epoch.
    shallow_since: ?i64 = null,
    /// `--shallow-exclude`: the history cut where these refs of the
    /// remote's reach.
    shallow_exclude: []const []const u8 = &.{},
    /// `--unshallow`: the whole history, and no boundary.
    unshallow: bool = false,
    /// `--update-shallow`: from a shallow remote, take the refs whose
    /// history ends at its boundary, and that boundary into
    /// `.git/shallow`. Without it those refs are left, and each is a
    /// warning, as git leaves and warns.
    update_shallow: bool = false,
    /// `--filter`, for a partial clone's promisor remote; `null` takes
    /// `remote.<name>.partialclonefilter`, as git does.
    filter: ?[]const u8 = null,
    /// The permission to run programs, which an ssh remote and a
    /// credential helper need.
    programs: ?program.Programs = null,
    /// What stands in for a terminal when an HTTP server asks for a
    /// credential no helper has. Without one nothing is asked, and
    /// askpass runs only when it says so.
    prompt: ?credential.Prompt = null,
    /// Filled in, when the operation fails for want of a credential, with
    /// what a person needs to put it right: see `auth.Failure`.
    auth_failure: ?*auth.Failure = null,
    /// Where what git would print as a warning goes, as values: see
    /// `warning.Warnings`.
    warnings: ?*warning.Warnings = null,
    progress: ?progress_mod.Progress = null,
    /// Checks received objects the way git's `fsck` does.
    check_objects: bool = true,
    /// Where the object behind `error.MissingObject` is written.
    missing: ?*Oid = null,
};

/// One ref a fetch looked at.
pub const Update = struct {
    /// The ref on the remote.
    remote_ref: []const u8,
    /// Where it is kept here.
    local_ref: []const u8,
    old: ?Oid,
    new: Oid,
    result: Result,

    /// What happened to the ref.
    pub const Result = enum {
        /// The ref did not exist and now does.
        created,
        /// The new value descends from the old one.
        fast_forward,
        /// It did not, and the update was forced.
        forced,
        /// A tag that already existed was moved, forced.
        tag_updated,
        /// Nothing to do.
        up_to_date,
        /// The new value does not descend from the old, and nothing forced
        /// it. git leaves the ref and fails the fetch.
        rejected_non_fast_forward,
        /// A tag that already exists here with another value.
        rejected_would_clobber_tag,
        /// Its history ends at the remote's shallow boundary, and the
        /// fetch did not ask to take that boundary on. git leaves the ref,
        /// warns, and does not fail the fetch.
        rejected_shallow,
    };

    /// Whether the ref was left alone because updating it was refused.
    pub fn rejected(u: Update) bool {
        return u.result == .rejected_non_fast_forward or u.result == .rejected_would_clobber_tag;
    }
};

/// One line of `FETCH_HEAD`.
pub const FetchHeadEntry = struct {
    oid: Oid,
    for_merge: bool,
    /// `branch 'main' of <url>` and the like: everything after the second
    /// tab.
    description: []const u8,
};

/// What a fetch did.
pub const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    updates: []const Update,
    /// Remote-tracking refs deleted because their source is gone.
    pruned: []const []const u8,
    fetch_head: []const FetchHeadEntry,
    /// The pack that came, or `null` when nothing new was needed.
    pack: ?Oid,
    objects: u32,

    /// Release everything.
    pub fn deinit(outcome: *Outcome) void {
        outcome.arena.deinit();
        outcome.* = undefined;
    }

    /// Whether any update was refused — git's exit status of 1.
    pub fn anyRejected(outcome: *const Outcome) bool {
        for (outcome.updates) |u| {
            if (u.rejected()) return true;
        }
        return false;
    }
};

const HeadStatus = enum { merge, not_for_merge, ignore };

/// One entry of the ref map: a remote ref, and where it goes.
const MapEntry = struct {
    name: []const u8,
    oid: Oid,
    /// The local ref it is kept in, when it is kept.
    dst: ?[]const u8,
    force: bool,
    status: HeadStatus,
    /// Its history ends at the remote's boundary, which was not taken.
    rejected_shallow: bool = false,
};

/// Fetch from `remote_name`, a configured remote or a URL, into `repo`.
pub fn fetch(gpa: Allocator, io: Io, repo: *Repository, remote_name: []const u8, options: Options) Error!Outcome {
    const deepen = try deepenRequest(repo, options);

    var outcome: Outcome = .{
        .arena = .init(gpa),
        .updates = &.{},
        .pruned = &.{},
        .fetch_head = &.{},
        .pack = null,
        .objects = 0,
    };
    errdefer outcome.arena.deinit();
    const arena = outcome.arena.allocator();

    var remote = try remote_mod.Remote.get(gpa, &repo.config, remote_name);
    defer remote.deinit();

    const rla = options.reflog_action orelse blk: {
        var text: std.ArrayList(u8) = .empty;
        try text.print(arena, "fetch {s}", .{remote_name});
        for (options.refspecs) |spec| try text.print(arena, " {s}", .{spec});
        break :blk text.items;
    };

    var cli_specs: std.ArrayList(Refspec) = .empty;
    for (options.refspecs) |text| {
        try cli_specs.append(arena, Refspec.parse(try arena.dupe(u8, text), .fetch) catch return error.InvalidRefspec);
    }
    const tags = options.tags orelse remote.tags;
    const prune = options.prune orelse remote.prune orelse false;
    const prune_tags = options.prune_tags orelse remote.prune_tags orelse false;

    // `pruneTags` is a refspec: fetching every tag is how it knows which
    // are gone.
    var configured: std.ArrayList(Refspec) = .empty;
    try configured.appendSlice(arena, remote.fetch);
    if (prune and prune_tags and remote.name != null) {
        try configured.append(arena, try Refspec.parse("refs/tags/*:refs/tags/*", .fetch));
    }
    const specs: []const Refspec = if (cli_specs.items.len != 0) cli_specs.items else configured.items;

    // The current branch's merge settings, when it follows this remote.
    var branch_merge: []const []const u8 = &.{};
    const current = try repo.refs.currentBranch(gpa, io);
    defer if (current) |c| gpa.free(c);
    var branch_config: ?remote_mod.Branch = null;
    defer if (branch_config) |*b| b.deinit();
    if (current) |name| {
        branch_config = try remote_mod.Branch.get(gpa, &repo.config, name);
        const b = &branch_config.?;
        if (b.merge.len != 0 and b.remote != null and remote.name != null and std.mem.eql(u8, b.remote.?, remote.name.?)) {
            branch_merge = b.merge;
        }
    }

    const follow_head = cli_specs.items.len == 0 and remote.name != null and followRemoteHead(&repo.config, remote.name.?);

    // A promisor remote's packs are filtered as the clone was, and what
    // they leave out is promised rather than missing.
    const promisor = remote.name != null and partial.isPromisor(&repo.config, remote.name.?);
    const filter_spec: ?[]const u8 = blk: {
        const spec = options.filter orelse if (promisor) configured: {
            const key = try std.fmt.allocPrint(arena, "remote.{s}.partialclonefilter", .{remote.name.?});
            const raw = repo.config.get(key) orelse break :configured null;
            break :configured try config_mod.unquote(arena, raw);
        } else null;
        const text = spec orelse break :blk null;
        if (!promisor) return error.NotAPromisorRemote;
        break :blk try partial.normalize(arena, text);
    };

    const url = remote.urls[0];
    var session = try transport.Session.open(gpa, io, url, .upload_pack, repo.kind, .{
        .programs = options.programs,
        .config = &repo.config,
        .service_program = remote.upload_pack,
        .progress = options.progress,
        .prompt = options.prompt,
        .auth_failure = options.auth_failure,
        .warnings = options.warnings,
    });
    defer session.close(io);

    // Ask for the refs the refspecs can name, as git does.
    var prefixes: std.ArrayList([]const u8) = .empty;
    for (specs) |spec| try addPrefixes(arena, &prefixes, spec);
    if (cli_specs.items.len == 0) {
        for (branch_merge) |merge| try expandPrefix(arena, &prefixes, merge);
        if (specs.len == 0) try prefixes.append(arena, "HEAD");
    }
    if (prefixes.items.len != 0 and tags != .none) try prefixes.append(arena, "refs/tags/");
    if (prefixes.items.len != 0 and follow_head) try prefixes.append(arena, "HEAD");
    var remote_refs = try session.listRefs(gpa, io, prefixes.items);
    defer remote_refs.deinit();

    // The local refs, by name.
    var local_refs = try repo.refs.list(gpa, io, "refs/");
    defer local_refs.deinit();
    var local = try LocalIndex.init(gpa, &local_refs);
    defer local.deinit(gpa);

    var map: std.ArrayList(MapEntry) = .empty;
    var autotags = false;
    if (cli_specs.items.len != 0) {
        for (cli_specs.items) |spec| {
            try fetchMap(arena, &map, remote_refs.refs, spec, false, .merge);
            if (spec.dst) |dst| {
                if (dst.len != 0) autotags = true;
            }
        }
    } else if (configured.items.len != 0 or branch_merge.len != 0) {
        for (configured.items, 0..) |spec, i| {
            const before = map.items.len;
            try fetchMap(arena, &map, remote_refs.refs, spec, false, .not_for_merge);
            if (spec.dst) |dst| {
                if (dst.len != 0) autotags = true;
            }
            if (i == 0 and branch_merge.len == 0 and map.items.len > before and !spec.pattern) {
                map.items[before].status = .merge;
            }
        }
        for (branch_merge) |merge| {
            var found = false;
            for (map.items) |*entry| {
                if (refnameMatch(merge, entry.name) != 0) {
                    entry.status = .merge;
                    found = true;
                    break;
                }
            }
            if (found) continue;
            const spec: Refspec = .{ .src = merge, .dst = null };
            try fetchMap(arena, &map, remote_refs.refs, spec, true, .merge);
        }
    } else {
        const head = remote_refs.find("HEAD") orelse return error.RemoteRefNotFound;
        if (head.unborn) return error.RemoteRefNotFound;
        try map.append(arena, .{ .name = "HEAD", .oid = head.oid, .dst = null, .force = false, .status = .merge });
    }

    if (tags == .all) {
        try fetchMap(arena, &map, remote_refs.refs, try Refspec.parse("refs/tags/*:refs/tags/*", .fetch), false, .not_for_merge);
    } else if (tags == .auto and autotags) {
        try findNonLocalTags(arena, gpa, io, repo, remote_refs.refs, &local, &map, null);
    }

    // Refs the command line fetched are also kept where the configured
    // refspecs would keep them, without a line in `FETCH_HEAD`.
    if (cli_specs.items.len != 0 and remote.name != null) {
        const named = map.items.len;
        for (remote.fetch) |spec| {
            if (spec.negative) continue;
            for (0..named) |i| {
                // The map grows as it is walked; each entry is taken by
                // value before anything is appended.
                const entry = map.items[i];
                const dst = (try spec.mapSource(arena, entry.name)) orelse continue;
                try map.append(arena, .{ .name = entry.name, .oid = entry.oid, .dst = dst, .force = spec.force, .status = .ignore });
            }
        }
    }

    try applyNegative(arena, &map, specs);
    try removeDuplicates(&map);

    // A working tree's branch is never fetched into.
    if (!options.update_head_ok) {
        const checked_out = try checkedOutBranches(arena, gpa, io, repo);
        for (map.items) |entry| {
            const dst = entry.dst orelse continue;
            for (checked_out) |branch| {
                if (!std.mem.eql(u8, branch, dst)) continue;
                if (local.names.contains(dst)) return error.WouldUpdateCheckedOutBranch;
            }
        }
    }

    // Prune first, as git does, so a ref that moved to a name nested
    // under a pruned one can be created.
    var pruned: std.ArrayList([]const u8) = .empty;
    if (prune) {
        var fetched_names: std.StringHashMapUnmanaged(void) = .empty;
        defer fetched_names.deinit(gpa);
        for (map.items) |m| try fetched_names.put(gpa, m.name, {});
        for (local_refs.entries) |entry| {
            if (entry.target == .symbolic) continue;
            var matched = false;
            var stale = true;
            for (specs) |spec| {
                if (spec.negative) continue;
                const source = (try spec.mapDestination(arena, entry.name)) orelse continue;
                matched = true;
                if (fetched_names.contains(source)) stale = false;
            }
            if (!matched or !stale) continue;
            var tx = repo.beginRefs();
            defer tx.deinit(io);
            try tx.delete(entry.name, .{ .matches = entry.target.direct });
            try tx.commit(io, null);
            try deleteLog(gpa, io, repo, entry.name);
            try pruned.append(arena, try arena.dupe(u8, entry.name));
        }
    }

    // The objects: everything the map names that is not here yet.
    // Deepening asks again for what is here: its history is what is
    // wanted.
    const wants = try wantsInOrder(arena, io, repo, remote_refs.refs, map.items, deepen != null);
    var tips: std.ArrayList(Oid) = .empty;
    var common_tips: std.ArrayList(Oid) = .empty;
    for (local_refs.entries) |entry| switch (entry.target) {
        .direct => |oid| try tips.append(arena, oid),
        .symbolic => {},
    };
    if (try repo.refs.read(gpa, io, "HEAD")) |head| switch (head) {
        .direct => |oid| try tips.append(arena, oid),
        .symbolic => |target| gpa.free(target),
    };
    {
        var tip_set: Oid.Set = .empty;
        defer tip_set.deinit(gpa);
        for (tips.items) |tip| try tip_set.put(gpa, tip, {});
        for (remote_refs.refs) |ref| {
            if (tip_set.contains(ref.oid)) try common_tips.append(arena, ref.oid);
        }
    }

    var pack_dir = try repo.common_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    const boundary = try shallowList(arena, &repo.odb.shallow);
    var shallow_info: fetchpack.ShallowInfo = .{ .gpa = gpa };
    defer shallow_info.deinit();
    const fetched = try session.fetch(gpa, io, &repo.odb, pack_dir, .{
        .wants = wants,
        .tips = tips.items,
        .common_tips = common_tips.items,
        .include_tag = tags != .none,
        .deepen = deepen,
        .shallow = boundary,
        .filter = filter_spec,
    }, .{
        .progress = options.progress,
        .receive = .{ .check_objects = options.check_objects },
        .shallow_info = &shallow_info,
    });
    outcome.pack = fetched.pack;
    outcome.objects = fetched.objects;
    // A fetch's promisor pack names no refs; git's names none either.
    if (promisor) if (fetched.pack) |name| try partial.writePromisor(io, pack_dir, name, &.{});

    // The boundary the server drew. Walks from here on stop at it; it is
    // written once everything below the refs is known to be here.
    var old_boundary = repo.odb.shallow;
    var boundary_moved = false;
    defer if (boundary_moved) old_boundary.deinit(gpa);
    errdefer if (boundary_moved) {
        repo.odb.shallow.deinit(gpa);
        repo.odb.shallow = old_boundary;
        boundary_moved = false;
    };
    // A shallow remote's boundary, on a fetch that did not ask for one:
    // walked with for the check below, and kept only as `update_shallow`
    // says.
    var remote_roots: std.ArrayList(Oid) = .empty;
    if (deepen == null) try shallow_info.shallow.appendSlice(gpa, session.advertisedShallow());
    if (shallow_info.shallow.items.len != 0 or shallow_info.unshallow.items.len != 0) {
        if (deepen == null) {
            for (shallow_info.shallow.items) |oid| {
                if (!old_boundary.contains(oid)) try remote_roots.append(arena, oid);
            }
        }
        repo.odb.shallow = try shallow_mod.apply(gpa, &old_boundary, shallow_info.shallow.items, shallow_info.unshallow.items);
        boundary_moved = true;
    }

    // Tags that point at what the fetch brought.
    var backfill: std.ArrayList(MapEntry) = .empty;
    if (tags == .auto and autotags) {
        try findNonLocalTags(arena, gpa, io, repo, remote_refs.refs, &local, &backfill, map.items);
        const missing_tags = try wantsInOrder(arena, io, repo, remote_refs.refs, backfill.items, false);
        if (missing_tags.len != 0) {
            _ = try session.fetch(gpa, io, &repo.odb, pack_dir, .{
                .wants = missing_tags,
                .tips = tips.items,
                .common_tips = common_tips.items,
                .include_tag = false,
            }, .{ .progress = options.progress, .receive = .{ .check_objects = options.check_objects } });
        }
    }

    // Everything below the fetched refs is here: what came in the pack is
    // walked into, what was here before is taken to be whole.
    {
        var all_tips: std.ArrayList(Oid) = .empty;
        for (map.items) |entry| try all_tips.append(arena, entry.oid);
        for (backfill.items) |entry| try all_tips.append(arena, entry.oid);
        var fresh: ?pack.Index = null;
        defer if (fresh) |*index| index.deinit();
        if (outcome.pack) |name| {
            var hex: [hash.max_hex_len]u8 = undefined;
            var idx_buf: [96]u8 = undefined;
            const idx_name = std.fmt.bufPrint(&idx_buf, "pack-{s}.idx", .{name.hex(&hex)}) catch unreachable;
            fresh = try pack.Index.open(gpa, io, pack_dir, idx_name, repo.kind, 1 << 30);
        }
        objectwalk.checkConnectedWith(gpa, io, &repo.odb, all_tips.items, if (fresh) |*index| index else null, options.missing, .{ .promisor = promisor }) catch |err| switch (err) {
            error.MissingObject => return error.MissingObject,
            else => |e| return e,
        };
        if (remote_roots.items.len != 0) {
            // Which refs need which of the remote's roots: git's
            // `assign_shallow_commits_to_refs`, walking what came in the
            // pack — what was here before is whole below it.
            var needed: Oid.Set = .empty;
            var roots: Oid.Set = .empty;
            for (remote_roots.items) |oid| {
                const arrived = if (fresh) |*index| (try index.find(oid)) != null else false;
                if (arrived) try roots.put(arena, oid, {});
            }
            for ([_][]MapEntry{ map.items, backfill.items }) |entries| for (entries) |*entry| {
                const reached = try rootsReached(arena, io, repo, entry.oid, &roots, if (fresh) |*index| index else null, &old_boundary);
                if (reached.len == 0) continue;
                if (options.update_shallow) {
                    for (reached) |r| try needed.put(arena, r, {});
                } else entry.rejected_shallow = true;
            };
            repo.odb.shallow.deinit(gpa);
            repo.odb.shallow = try old_boundary.clone(gpa);
            var it = needed.keyIterator();
            while (it.next()) |r| try repo.odb.shallow.put(gpa, r.*, {});
        }
    }

    if (boundary_moved) try shallow_mod.write(gpa, io, repo.common_dir, &repo.odb.shallow);

    // The refs, in git's order: those for merging first.
    const display_url = try url_mod.anonymize(arena, url);
    var fetch_head: std.ArrayList(FetchHeadEntry) = .empty;
    var updates: std.ArrayList(Update) = .empty;
    var pending: std.ArrayList(Pending) = .empty;

    const passes = [_][]MapEntry{ map.items, backfill.items };
    for (passes) |entries| {
        for ([_]HeadStatus{ .merge, .not_for_merge, .ignore }) |want_status| {
            for (entries) |*entry| {
                // Only a commit can be merged.
                if (entry.status == .merge and !try isCommitish(io, repo, entry.oid)) entry.status = .not_for_merge;
                if (entry.status != want_status) continue;
                if (entry.rejected_shallow) {
                    // Left out of FETCH_HEAD and not written, as git leaves
                    // it.
                    const name = entry.dst orelse entry.name;
                    try warning.note(options.warnings, .{ .shallow_update_rejected = name });
                    if (entry.dst) |dst| try updates.append(arena, .{
                        .remote_ref = entry.name,
                        .local_ref = dst,
                        .old = if (local.names.get(dst)) |v| v else null,
                        .new = entry.oid,
                        .result = .rejected_shallow,
                    });
                    continue;
                }
                if (entry.status != .ignore) {
                    try fetch_head.append(arena, .{
                        .oid = entry.oid,
                        .for_merge = entry.status == .merge,
                        .description = try describe(arena, entry.name, display_url),
                    });
                }
                const dst = entry.dst orelse continue;
                const decision = try decide(gpa, io, repo, entry.*, dst, options.force, &local);
                try updates.append(arena, .{
                    .remote_ref = entry.name,
                    .local_ref = dst,
                    .old = decision.old,
                    .new = entry.oid,
                    .result = decision.result,
                });
                const message = decision.message orelse continue;
                try pending.append(arena, .{
                    .name = dst,
                    .old = decision.old,
                    .new = entry.oid,
                    .message = try std.fmt.allocPrint(arena, "{s}: {s}", .{ rla, message }),
                });
            }
        }
    }
    try writeRefs(gpa, io, repo, pending.items, options, updates.items);

    if (follow_head) try createRemoteHead(gpa, io, repo, remote.name.?, remote_refs.refs, configured.items, options.who);

    if (options.write_fetch_head) try writeFetchHead(gpa, io, repo, fetch_head.items, options.append);

    outcome.updates = updates.items;
    outcome.pruned = pruned.items;
    outcome.fetch_head = fetch_head.items;
    return outcome;
}

/// A ref to be written, and the reflog line it gets.
const Pending = struct {
    name: []const u8,
    old: ?Oid,
    new: Oid,
    message: []const u8,
};

/// Write the updates: each under its own lock, as git's fetch does, or all
/// under one when `atomic` asks — in which case a refused update anywhere
/// leaves every ref as it was, as git's `--atomic` does.
fn writeRefs(gpa: Allocator, io: Io, repo: *Repository, pending: []const Pending, options: Options, updates: []const Update) Error!void {
    if (!options.atomic) {
        for (pending) |p| {
            var tx = repo.beginRefs();
            defer tx.deinit(io);
            try tx.update(p.name, .{ .direct = p.new }, expectation(p.old));
            try tx.commit(io, .{ .who = options.who, .message = p.message, .policy = repo.reflogPolicy() });
        }
        return;
    }
    for (updates) |u| {
        if (u.rejected()) return;
    }
    if (pending.len == 0) return;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    for (pending) |p| try tx.update(p.name, .{ .direct = p.new }, expectation(p.old));
    // A transaction writes one message for all its refs, and each ref here
    // has its own; the logs are appended once every ref is in place.
    try tx.commit(io, null);
    const policy = repo.reflogPolicy();
    for (pending) |p| {
        // Through the store, so a reftable repository's log is where git
        // reads it.
        const exists = try repo.refs.logExists(gpa, io, p.name);
        if (!reflog.shouldLog(policy, p.name, exists)) continue;
        try repo.refs.appendLog(gpa, io, p.name, p.old orelse .zero(repo.kind), p.new, options.who, p.message);
    }
}

fn expectation(old: ?Oid) refs_mod.Expected {
    return if (old) |oid| .{ .matches = oid } else .must_not_exist;
}

/// Whether `remote.<name>.followRemoteHEAD` asks for `refs/remotes/<name>/HEAD`
/// to be created when it is missing, which is its default.
fn followRemoteHead(config: *const @import("config.zig").Config, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "remote.{s}.followremotehead", .{name}) catch return false;
    const value = config.get(key) orelse return true;
    return !std.ascii.eqlIgnoreCase(value, "never");
}

/// git's `ref_rev_parse_rules`, in order.
const rev_parse_rules = [_][]const u8{
    "{s}",
    "refs/{s}",
    "refs/tags/{s}",
    "refs/heads/{s}",
    "refs/remotes/{s}",
    "refs/remotes/{s}/HEAD",
};

/// git's `refname_match`: how well `abbrev` names `full`, as the number of
/// rules from the end of the list; zero when it does not.
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

fn expandPrefix(arena: Allocator, prefixes: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    for (rev_parse_rules) |rule| {
        const star = std.mem.indexOf(u8, rule, "{s}").?;
        try prefixes.append(arena, try std.mem.concat(arena, u8, &.{ rule[0..star], name, rule[star + 3 ..] }));
    }
}

/// git's `refspec_ref_prefixes` for one refspec.
fn addPrefixes(arena: Allocator, prefixes: *std.ArrayList([]const u8), spec: Refspec) Allocator.Error!void {
    if (spec.exact_oid or spec.negative) return;
    const src = if (spec.src.len == 0) "HEAD" else spec.src;
    if (spec.pattern) {
        const star = std.mem.indexOfScalar(u8, src, '*').?;
        try prefixes.append(arena, src[0..star]);
    } else try expandPrefix(arena, prefixes, src);
}

/// git's `get_fetch_map`: the remote refs one refspec takes.
fn fetchMap(
    arena: Allocator,
    map: *std.ArrayList(MapEntry),
    remote_refs: []const protocol.RemoteRef,
    spec: Refspec,
    missing_ok: bool,
    status: HeadStatus,
) Error!void {
    if (spec.negative) return;
    if (spec.pattern) {
        for (remote_refs) |ref| {
            if (ref.unborn) continue;
            if (std.mem.indexOfScalar(u8, ref.name, '^') != null) continue;
            const dst = (try spec.mapSource(arena, ref.name)) orelse continue;
            if (!validLocal(dst)) continue;
            try map.append(arena, .{ .name = try arena.dupe(u8, ref.name), .oid = ref.oid, .dst = dst, .force = spec.force, .status = status });
        }
        return;
    }
    const name = if (spec.src.len == 0) "HEAD" else spec.src;
    var entry: MapEntry = undefined;
    if (spec.exact_oid) {
        entry = .{ .name = try arena.dupe(u8, name), .oid = Oid.parse(if (name.len == 64) .sha256 else .sha1, name) catch return error.InvalidRefspec, .dst = null, .force = spec.force, .status = status };
    } else {
        var best: ?protocol.RemoteRef = null;
        var best_score: usize = 0;
        for (remote_refs) |ref| {
            if (ref.unborn) continue;
            const score = refnameMatch(name, ref.name);
            if (score > best_score) {
                best = ref;
                best_score = score;
            }
        }
        const found = best orelse {
            if (missing_ok) return;
            return error.RemoteRefNotFound;
        };
        entry = .{ .name = try arena.dupe(u8, found.name), .oid = found.oid, .dst = null, .force = spec.force, .status = status };
    }
    if (spec.dst) |dst| {
        if (dst.len != 0) {
            const local = try localRef(arena, try arena.dupe(u8, dst));
            if (validLocal(local)) entry.dst = local;
        }
    }
    try map.append(arena, entry);
}

/// git's `get_local_ref`: where a short destination is kept.
fn localRef(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, name, "refs/")) return name;
    if (std.mem.startsWith(u8, name, "heads/") or std.mem.startsWith(u8, name, "tags/") or std.mem.startsWith(u8, name, "remotes/")) {
        return std.mem.concat(arena, u8, &.{ "refs/", name });
    }
    return std.mem.concat(arena, u8, &.{ "refs/heads/", name });
}

fn validLocal(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "refs/") and refspec_mod.checkRefFormat(name, .{});
}

/// git's `find_non_local_tags`: remote tags this repository does not have
/// by name, whose object, or what it peels to, is here or is being fetched.
/// With `fetched` set, what is being fetched has already arrived and the
/// tags the map already holds are left out.
fn findNonLocalTags(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote_refs: []const protocol.RemoteRef,
    local: *const LocalIndex,
    out: *std.ArrayList(MapEntry),
    fetched: ?[]const MapEntry,
) Error!void {
    const start = out.items.len;
    // What the map already asks for, as sets, so each remote tag costs a
    // lookup and not a walk.
    var queued: std.StringHashMapUnmanaged(void) = .empty;
    defer queued.deinit(gpa);
    var wanted: Oid.Set = .empty;
    defer wanted.deinit(gpa);
    if (fetched) |entries| {
        for (entries) |entry| {
            if (entry.dst) |dst| try queued.put(gpa, dst, {});
        }
    } else {
        for (out.items[0..start]) |entry| try wanted.put(gpa, entry.oid, {});
    }
    var added: std.StringHashMapUnmanaged(void) = .empty;
    defer added.deinit(gpa);

    for (remote_refs) |ref| {
        if (!std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;
        if (ref.unborn) continue;
        if (local.names.contains(ref.name)) continue;
        // After the pack, a tag already queued to be written is not taken
        // twice; before it, git takes a tag the command line named without
        // a place to keep it as well, and so does this.
        if (queued.contains(ref.name) or added.contains(ref.name)) continue;
        var reachable = try repo.odb.exists(io, ref.oid);
        if (!reachable) {
            if (ref.peeled) |peeled| reachable = try repo.odb.exists(io, peeled);
        }
        if (!reachable and fetched == null) {
            reachable = wanted.contains(ref.oid) or (if (ref.peeled) |peeled| wanted.contains(peeled) else false);
        }
        if (!reachable) continue;
        const name = try arena.dupe(u8, ref.name);
        try added.put(gpa, name, {});
        try out.append(arena, .{ .name = name, .oid = ref.oid, .dst = name, .force = false, .status = .not_for_merge });
    }
}

/// The local refs by name, each with its value where it is not symbolic.
const LocalIndex = struct {
    names: std.StringHashMapUnmanaged(?Oid) = .empty,

    fn init(gpa: Allocator, listing: *const refs_mod.Store.Listing) Allocator.Error!LocalIndex {
        var index: LocalIndex = .{};
        errdefer index.names.deinit(gpa);
        try index.names.ensureTotalCapacity(gpa, @intCast(listing.entries.len));
        for (listing.entries) |entry| {
            index.names.putAssumeCapacity(entry.name, switch (entry.target) {
                .direct => |oid| oid,
                .symbolic => null,
            });
        }
        return index;
    }

    fn deinit(index: *LocalIndex, gpa: Allocator) void {
        index.names.deinit(gpa);
    }
};

fn applyNegative(arena: Allocator, map: *std.ArrayList(MapEntry), specs: []const Refspec) Allocator.Error!void {
    _ = arena;
    var kept: usize = 0;
    for (map.items) |entry| {
        if (refspec_mod.excluded(specs, entry.name)) continue;
        map.items[kept] = entry;
        kept += 1;
    }
    map.shrinkRetainingCapacity(kept);
}

/// git's `ref_remove_duplicates`: two entries keeping the same local ref
/// are one entry when they come from the same remote ref, and a refusal
/// when they do not.
fn removeDuplicates(map: *std.ArrayList(MapEntry)) Error!void {
    var kept: usize = 0;
    outer: for (map.items) |entry| {
        if (entry.dst) |dst| {
            for (map.items[0..kept]) |earlier| {
                const earlier_dst = earlier.dst orelse continue;
                if (!std.mem.eql(u8, earlier_dst, dst)) continue;
                if (!std.mem.eql(u8, earlier.name, entry.name) and earlier.status != .ignore and entry.status != .ignore) {
                    return error.ConflictingRefspecs;
                }
                continue :outer;
            }
        }
        map.items[kept] = entry;
        kept += 1;
    }
    map.shrinkRetainingCapacity(kept);
}

/// The remote's boundary commits `tip`'s new history reaches: walked
/// through the commits the pack brought, stopping at what was here before
/// and at this repository's own boundary.
fn rootsReached(arena: Allocator, io: Io, repo: *Repository, tip: Oid, roots: *const Oid.Set, fresh: ?*const pack.Index, boundary: *const Oid.Set) Error![]const Oid {
    var out: std.ArrayList(Oid) = .empty;
    const index = fresh orelse return out.items;
    var seen: Oid.Set = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    const start = repo.peel(io, tip) catch return out.items;
    try stack.append(arena, start);
    while (stack.pop()) |oid| {
        if ((try seen.getOrPut(arena, oid)).found_existing) continue;
        if (roots.contains(oid)) {
            try out.append(arena, oid);
            continue;
        }
        if (boundary.contains(oid) or (try index.find(oid)) == null) continue;
        const found = repo.odb.read(io, oid) catch continue;
        defer repo.odb.gpa.free(found.bytes);
        if (found.type != .commit) continue;
        var commit = try object.Commit.parse(arena, repo.kind, found.bytes);
        defer commit.deinit();
        for (commit.parents) |p| try stack.append(arena, p);
    }
    return out.items;
}

/// What the options ask of the boundary, as the protocol asks it.
fn deepenRequest(repo: *Repository, options: Options) Error!?fetchpack.Deepen {
    if (options.unshallow) {
        if (repo.odb.shallow.count() == 0) return error.NotShallow;
        return .{ .depth = 0x7fff_ffff };
    }
    if (options.depth == null and options.deepen == null and options.shallow_since == null and options.shallow_exclude.len == 0) return null;
    return .{
        .depth = options.depth orelse options.deepen,
        .relative = options.deepen != null,
        .since = options.shallow_since,
        .not = options.shallow_exclude,
    };
}

/// The boundary as a list, for the server.
fn shallowList(arena: Allocator, set: *const Oid.Set) Allocator.Error![]const Oid {
    const list = try arena.alloc(Oid, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |oid| : (i += 1) list[i] = oid.*;
    return list;
}

/// The objects to ask for, as git's fetch-pack asks: each advertised ref
/// the map fetches, in the order the server advertised them, whose object
/// is not here — one line per ref, so two refs at one commit ask twice.
fn wantsInOrder(arena: Allocator, io: Io, repo: *Repository, advertised: []const protocol.RemoteRef, entries: []const MapEntry, all: bool) Error![]const Oid {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (entries) |entry| try names.put(arena, entry.name, {});
    var wants: std.ArrayList(Oid) = .empty;
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    for (advertised) |ref| {
        if (ref.unborn or !names.contains(ref.name)) continue;
        if ((try listed.getOrPut(arena, ref.name)).found_existing) continue;
        if (!all and try repo.odb.exists(io, ref.oid)) continue;
        try wants.append(arena, ref.oid);
    }
    // A name no ref advertised — an object named on the command line — is
    // asked for after them.
    for (entries) |entry| {
        if (listed.contains(entry.name)) continue;
        if ((try listed.getOrPut(arena, entry.name)).found_existing) continue;
        if (!all and try repo.odb.exists(io, entry.oid)) continue;
        try wants.append(arena, entry.oid);
    }
    return wants.items;
}

/// The branches every working tree has checked out, as full ref names.
/// The names are `arena`'s.
fn checkedOutBranches(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // The main working tree's `HEAD` is the shared directory's, whichever
    // worktree this repository was opened from.
    if (!repo.isBare() or repo.common_is_separate) {
        var main_store: refs_mod.Store = .init(gpa, repo.kind, repo.common_dir, repo.common_dir);
        const bare = repo.config.getBool("core.bare", false) catch false;
        if (!bare) {
            if (try main_store.read(gpa, io, "HEAD")) |head| switch (head) {
                .symbolic => |target| {
                    defer gpa.free(target);
                    try out.append(arena, try arena.dupe(u8, target));
                },
                .direct => {},
            };
        }
    }
    var listing = try repo.listWorktrees(io);
    defer listing.deinit();
    for (listing.entries) |entry| {
        const branch = entry.branch orelse continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "refs/heads/{s}", .{branch}));
    }
    return out.items;
}

fn isCommitish(io: Io, repo: *Repository, oid: Oid) Error!bool {
    if (!try repo.odb.exists(io, oid)) return false;
    const peeled = repo.peel(io, oid) catch return false;
    const header = try repo.odb.readHeader(io, peeled);
    return header.type == .commit;
}

const Decision = struct {
    old: ?Oid,
    result: Update.Result,
    /// The reflog's `<what happened>`, or `null` when the ref is not
    /// written.
    message: ?[]const u8,
};

/// git's `update_local_ref`: what happens to `dst`.
fn decide(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    entry: MapEntry,
    dst: []const u8,
    force: bool,
    local: *const LocalIndex,
) Error!Decision {
    var old: ?Oid = null;
    if (local.names.get(dst)) |value| {
        if (value) |oid| {
            old = oid;
        } else if (try repo.refs.resolve(gpa, io, dst)) |resolved| {
            gpa.free(resolved.name);
            old = resolved.oid;
        }
    }
    const current = old orelse {
        const message = if (std.mem.startsWith(u8, entry.name, "refs/tags/"))
            "storing tag"
        else if (std.mem.startsWith(u8, entry.name, "refs/heads/"))
            "storing head"
        else
            "storing ref";
        return .{ .old = null, .result = .created, .message = message };
    };
    if (current.eql(entry.oid)) return .{ .old = old, .result = .up_to_date, .message = null };
    if (std.mem.startsWith(u8, dst, "refs/tags/")) {
        if (force or entry.force) return .{ .old = old, .result = .tag_updated, .message = "updating tag" };
        return .{ .old = old, .result = .rejected_would_clobber_tag, .message = null };
    }
    const old_commit = commitOf(io, repo, current);
    const new_commit = commitOf(io, repo, entry.oid);
    if (old_commit == null or new_commit == null) {
        const message = if (std.mem.startsWith(u8, entry.name, "refs/tags/"))
            "storing tag"
        else if (std.mem.startsWith(u8, entry.name, "refs/heads/"))
            "storing head"
        else
            "storing ref";
        return .{ .old = old, .result = .created, .message = message };
    }
    if (try revwalk.isAncestor(gpa, io, &repo.odb, old_commit.?, new_commit.?)) {
        return .{ .old = old, .result = .fast_forward, .message = "fast-forward" };
    }
    if (force or entry.force) return .{ .old = old, .result = .forced, .message = "forced-update" };
    return .{ .old = old, .result = .rejected_non_fast_forward, .message = null };
}

fn commitOf(io: Io, repo: *Repository, oid: Oid) ?Oid {
    const peeled = repo.peel(io, oid) catch return null;
    const header = repo.odb.readHeader(io, peeled) catch return null;
    return if (header.type == .commit) peeled else null;
}

/// `branch 'main' of <url>`, `tag 'v1' of <url>`, or just the URL for
/// `HEAD`, with the URL's trailing slashes and `.git` taken off, as git's
/// `store_updated_refs` writes it.
fn describe(arena: Allocator, name: []const u8, url: []const u8) Allocator.Error![]const u8 {
    var kind: []const u8 = "";
    var what: []const u8 = name;
    if (std.mem.eql(u8, name, "HEAD")) {
        what = "";
    } else if (std.mem.startsWith(u8, name, "refs/heads/")) {
        kind = "branch";
        what = name["refs/heads/".len..];
    } else if (std.mem.startsWith(u8, name, "refs/tags/")) {
        kind = "tag";
        what = name["refs/tags/".len..];
    } else if (std.mem.startsWith(u8, name, "refs/remotes/")) {
        kind = "remote-tracking branch";
        what = name["refs/remotes/".len..];
    }
    // git's own arithmetic, including its off-by-one: a `.git` is taken
    // off only when more than four bytes are left before the last one.
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    const last = @as(isize, @intCast(end)) - 1;
    if (last > 4 and std.mem.eql(u8, url[end - 4 .. end], ".git")) end -= 4;

    var out: std.ArrayList(u8) = .empty;
    if (what.len != 0) {
        if (kind.len != 0) try out.print(arena, "{s} ", .{kind});
        try out.print(arena, "'{s}' of ", .{what});
    }
    for (url[0..end]) |c| {
        if (c == '\n') try out.appendSlice(arena, "\\n") else try out.append(arena, c);
    }
    return out.items;
}

fn writeFetchHead(gpa: Allocator, io: Io, repo: *Repository, entries: []const FetchHeadEntry, append: bool) Error!void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    if (append) {
        if (try fs.readFileAlloc(gpa, io, repo.git_dir, "FETCH_HEAD", 1 << 26)) |existing| {
            defer gpa.free(existing);
            text.writer.writeAll(existing) catch return error.OutOfMemory;
        }
    }
    for (entries) |entry| {
        text.writer.print("{f}\t{s}\t{s}\n", .{
            entry.oid,
            if (entry.for_merge) "" else "not-for-merge",
            entry.description,
        }) catch return error.OutOfMemory;
    }
    try fs.atomicWrite(io, repo.git_dir, "FETCH_HEAD", text.written(), "FETCH_HEAD.tmp_", .none);
}

/// Remove a deleted ref's log, as git does when it deletes a ref.
fn deleteLog(gpa: Allocator, io: Io, repo: *Repository, name: []const u8) Error!void {
    const path = try reflog.pathFor(gpa, name);
    defer gpa.free(path);
    repo.refs.dirFor(name).deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

/// `refs/remotes/<name>/HEAD`, when it is missing and the remote says
/// where its `HEAD` points: git's `followRemoteHEAD = create`.
fn createRemoteHead(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    name: []const u8,
    remote_refs: []const protocol.RemoteRef,
    specs: []const Refspec,
    who: object.Signature,
) Error!void {
    var head_buf: [512]u8 = undefined;
    const local_head = std.fmt.bufPrint(&head_buf, "refs/remotes/{s}/HEAD", .{name}) catch return;
    if (try repo.refs.read(gpa, io, local_head)) |existing| {
        switch (existing) {
            .symbolic => |target| gpa.free(target),
            .direct => {},
        }
        return;
    }
    var target: ?[]const u8 = null;
    for (remote_refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) target = ref.symref_target;
    }
    const remote_target = target orelse return;
    if (!std.mem.startsWith(u8, remote_target, "refs/heads/")) return;
    var local_target_buf: [512]u8 = undefined;
    const local_target = std.fmt.bufPrint(&local_target_buf, "refs/remotes/{s}/{s}", .{ name, remote_target["refs/heads/".len..] }) catch return;
    // Only where the configured refspecs keep that branch.
    var kept = false;
    for (specs) |spec| {
        const mapped = (try spec.mapSource(gpa, remote_target)) orelse continue;
        defer gpa.free(mapped);
        if (std.mem.eql(u8, mapped, local_target)) kept = true;
    }
    if (!kept) return;
    if (try repo.refs.resolve(gpa, io, local_target)) |resolved| {
        gpa.free(resolved.name);
    } else return;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(local_head, .{ .symbolic = local_target }, .must_not_exist);
    try tx.commit(io, .{ .who = who, .message = "fetch", .policy = repo.reflogPolicy() });
}

const testing = std.testing;
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

/// The identity a test's reflog entries are written as.
const test_who: object.Signature = .{
    .name = "Fixture",
    .email = "fixture@example.com",
    .when_secs = 1_700_000_000,
    .offset_minutes = 0,
};

/// Two repositories set up alike, one fetched into by git and one by relic,
/// so that what each leaves can be compared.
const Twins = struct {
    source: testgit.Repo,
    source_path: []u8,
    by_git: testgit.Repo,
    by_relic: testgit.Repo,

    fn init(gpa: Allocator, io: Io, commits: usize) !Twins {
        var source = try testremote.historyRepo(gpa, io, commits);
        errdefer source.deinit();
        const source_path = try testremote.absolutePath(gpa, io, source.dir);
        errdefer gpa.free(source_path);
        var by_git = try testgit.Repo.init(gpa, io, &.{});
        errdefer by_git.deinit();
        var by_relic = try testgit.Repo.init(gpa, io, &.{});
        errdefer by_relic.deinit();
        for ([_]*testgit.Repo{ &by_git, &by_relic }) |twin| {
            try twin.exec(io, &.{ "remote", "add", "origin", source_path });
            try twin.exec(io, &.{ "config", "branch.main.remote", "origin" });
            try twin.exec(io, &.{ "config", "branch.main.merge", "refs/heads/main" });
        }
        return .{ .source = source, .source_path = source_path, .by_git = by_git, .by_relic = by_relic };
    }

    fn deinit(t: *Twins, gpa: Allocator) void {
        t.source.deinit();
        gpa.free(t.source_path);
        t.by_git.deinit();
        t.by_relic.deinit();
    }

    /// Run `git fetch <args>` in the one twin and `fetch` with `options` in
    /// the other, and check they left the same refs, the same reflog
    /// messages and the same `FETCH_HEAD`.
    fn fetchBoth(t: *Twins, gpa: Allocator, io: Io, git_args: []const []const u8, options: Options) !Outcome {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "fetch");
        try argv.appendSlice(gpa, git_args);
        t.by_git.report_failures = false;
        const git_failed = if (t.by_git.exec(io, argv.items)) false else |_| true;

        var repo = try Repository.open(gpa, io, t.by_relic.dir, .{});
        defer repo.deinit(io);
        var opts = options;
        opts.who = test_who;
        var outcome = try fetch(gpa, io, &repo, "origin", opts);
        errdefer outcome.deinit();
        try testing.expectEqual(git_failed, outcome.anyRejected());

        try expectSameRefs(gpa, io, &t.by_git, &t.by_relic);
        const theirs = t.by_git.readFile(io, ".git/FETCH_HEAD") catch try gpa.dupe(u8, "");
        defer gpa.free(theirs);
        const ours = t.by_relic.readFile(io, ".git/FETCH_HEAD") catch try gpa.dupe(u8, "");
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
        try t.by_relic.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
        return outcome;
    }
};

/// Every ref the two repositories hold, with its value and its target, and
/// every reflog's messages, the same.
fn expectSameRefs(gpa: Allocator, io: Io, a: *testgit.Repo, b: *testgit.Repo) !void {
    const format = "--format=%(refname) %(objectname) %(symref)";
    const refs_a = try a.run(io, &.{ "for-each-ref", format });
    defer gpa.free(refs_a);
    const refs_b = try b.run(io, &.{ "for-each-ref", format });
    defer gpa.free(refs_b);
    try testing.expectEqualStrings(refs_a, refs_b);

    var lines = std.mem.tokenizeScalar(u8, refs_a, '\n');
    while (lines.next()) |line| {
        const name = line[0..std.mem.indexOfScalar(u8, line, ' ').?];
        const log_path = try std.fmt.allocPrint(gpa, ".git/logs/{s}", .{name});
        defer gpa.free(log_path);
        const log_a = a.readFile(io, log_path) catch try gpa.dupe(u8, "");
        defer gpa.free(log_a);
        const log_b = b.readFile(io, log_path) catch try gpa.dupe(u8, "");
        defer gpa.free(log_b);
        // Who and when differ — relic writes the caller's clock — and the
        // rest of each line is the same.
        var entries_a = std.mem.tokenizeScalar(u8, log_a, '\n');
        var entries_b = std.mem.tokenizeScalar(u8, log_b, '\n');
        while (true) {
            const ea = entries_a.next();
            const eb = entries_b.next();
            if (ea == null and eb == null) break;
            if (ea == null or eb == null) {
                std.debug.print("reflog of {s} differs:\n{s}\n---\n{s}\n", .{ name, log_a, log_b });
                return error.TestUnexpectedResult;
            }
            try testing.expectEqualStrings(ea.?[0..81], eb.?[0..81]);
            const tab_a = std.mem.indexOfScalar(u8, ea.?, '\t') orelse ea.?.len;
            const tab_b = std.mem.indexOfScalar(u8, eb.?, '\t') orelse eb.?.len;
            try testing.expectEqualStrings(ea.?[tab_a..], eb.?[tab_b..]);
        }
    }
}

test "a fetch from a local repository leaves what git fetch leaves: refs, logs and FETCH_HEAD" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try Twins.init(gpa, io, 4);
    defer twins.deinit(gpa);

    var first = try twins.fetchBoth(gpa, io, &.{"origin"}, .{ .who = test_who });
    defer first.deinit();
    try testing.expect(first.pack != null);

    // More history, a branch rewritten, a new tag below a tip: the second
    // fetch fast-forwards one ref, forces another, and follows the tag.
    try testremote.addCommits(gpa, io, &twins.source, 10, 3);
    try twins.source.exec(io, &.{ "tag", "-a", "later", "-m", "later", "HEAD~1" });
    try twins.source.exec(io, &.{ "checkout", "-q", "side" });
    try twins.source.exec(io, &.{ "commit", "-q", "--amend", "-m", "rewritten" });
    try twins.source.exec(io, &.{ "checkout", "-q", "main" });
    var second = try twins.fetchBoth(gpa, io, &.{"origin"}, .{ .who = test_who });
    defer second.deinit();
    var saw_forced = false;
    var saw_fast_forward = false;
    for (second.updates) |u| {
        if (u.result == .forced) saw_forced = true;
        if (u.result == .fast_forward) saw_fast_forward = true;
    }
    try testing.expect(saw_forced and saw_fast_forward);

    // Nothing new: nothing fetched, and FETCH_HEAD still written.
    var third = try twins.fetchBoth(gpa, io, &.{"origin"}, .{ .who = test_who });
    defer third.deinit();
    try testing.expect(third.pack == null);
}

test "named refspecs, pruning and every tag are what git makes of them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try Twins.init(gpa, io, 3);
    defer twins.deinit(gpa);

    var named = try twins.fetchBoth(gpa, io, &.{ "origin", "main:refs/heads/copy", "side", "refs/tags/old" }, .{
        .who = test_who,
        .refspecs = &.{ "main:refs/heads/copy", "side", "refs/tags/old" },
        .reflog_action = "fetch origin main:refs/heads/copy side refs/tags/old",
    });
    defer named.deinit();

    try twins.source.exec(io, &.{ "branch", "gone" });
    var with_gone = try twins.fetchBoth(gpa, io, &.{"origin"}, .{ .who = test_who });
    defer with_gone.deinit();
    try twins.source.exec(io, &.{ "branch", "-D", "gone" });
    try twins.source.exec(io, &.{ "tag", "extra", "HEAD~2" });
    var pruned = try twins.fetchBoth(gpa, io, &.{ "--prune", "--tags", "origin" }, .{
        .who = test_who,
        .prune = true,
        .tags = .all,
        .reflog_action = "fetch --prune --tags origin",
    });
    defer pruned.deinit();
    try testing.expectEqual(@as(usize, 1), pruned.pruned.len);
    try testing.expectEqualStrings("refs/remotes/origin/gone", pruned.pruned[0]);

    // All or none, each ref with its own log line.
    try testremote.addCommits(gpa, io, &twins.source, 20, 1);
    try twins.source.exec(io, &.{ "branch", "-f", "side", "HEAD" });
    var atomic = try twins.fetchBoth(gpa, io, &.{ "--atomic", "origin" }, .{
        .who = test_who,
        .atomic = true,
        .reflog_action = "fetch --atomic origin",
    });
    defer atomic.deinit();
}

test "a non-fast-forward and a moved tag are refused as git refuses them, and forced as git forces them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try Twins.init(gpa, io, 3);
    defer twins.deinit(gpa);
    for ([_]*testgit.Repo{ &twins.by_git, &twins.by_relic }) |twin| {
        try twin.exec(io, &.{ "config", "remote.origin.fetch", "refs/heads/*:refs/remotes/origin/*" });
    }
    var first = try twins.fetchBoth(gpa, io, &.{"origin"}, .{ .who = test_who });
    defer first.deinit();

    try twins.source.exec(io, &.{ "checkout", "-q", "side" });
    try twins.source.exec(io, &.{ "commit", "-q", "--amend", "-m", "rewritten" });
    try twins.source.exec(io, &.{ "checkout", "-q", "main" });
    try twins.source.exec(io, &.{ "tag", "-f", "-a", "v1", "-m", "moved", "HEAD~1" });
    var refused = try twins.fetchBoth(gpa, io, &.{ "--tags", "origin" }, .{
        .who = test_who,
        .tags = .all,
        .reflog_action = "fetch --tags origin",
    });
    defer refused.deinit();
    var non_ff = false;
    var clobber = false;
    for (refused.updates) |u| {
        if (u.result == .rejected_non_fast_forward) non_ff = true;
        if (u.result == .rejected_would_clobber_tag) clobber = true;
    }
    try testing.expect(non_ff and clobber);

    var forced = try twins.fetchBoth(gpa, io, &.{ "--tags", "--force", "origin" }, .{
        .who = test_who,
        .tags = .all,
        .force = true,
        .reflog_action = "fetch --tags --force origin",
    });
    defer forced.deinit();
    try testing.expect(!forced.anyRejected());
}

test "the branch a working tree has checked out is not fetched into" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try Twins.init(gpa, io, 2);
    defer twins.deinit(gpa);
    try twins.by_relic.writeFile(io, "local.txt", "local\n");
    try twins.by_relic.exec(io, &.{ "add", "-A" });
    try twins.by_relic.exec(io, &.{ "commit", "-q", "-m", "local" });
    var repo = try Repository.open(gpa, io, twins.by_relic.dir, .{});
    defer repo.deinit(io);
    try testing.expectError(error.WouldUpdateCheckedOutBranch, fetch(gpa, io, &repo, "origin", .{
        .who = test_who,
        .refspecs = &.{"+main:main"},
    }));
    // git refuses the same.
    twins.by_relic.report_failures = false;
    try testing.expectError(error.GitFailed, twins.by_relic.exec(io, &.{ "fetch", "origin", "+main:main" }));
}

test "unshallowing a whole repository and a filtered fetch are refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try Repository.init(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    try testing.expectError(error.NotShallow, fetch(gpa, io, &repo, "origin", .{ .who = test_who, .unshallow = true }));
    try testing.expectError(error.NotAPromisorRemote, fetch(gpa, io, &repo, "origin", .{ .who = test_who, .filter = "blob:none" }));
}
