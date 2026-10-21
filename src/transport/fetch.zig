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

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const gitdate = @import("../text.zig").date;
const httpsettings_mod = @import("../wire.zig").http_settings;
const keep_mod = @import("../odb/keep.zig");
const odb_mod = @import("../odb/odb.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const pack = @import("../odb/pack.zig");
const rev_walk = @import("../walk/walk.zig");
const fetch_pack = @import("../wire.zig").fetch_pack;
const glob = @import("../text.zig").glob;
const rev_parse = @import("../rev_walk/rev_parse.zig");
const shallow_mod = @import("../walk/shallow.zig");
const rev_index = @import("../odb/rev_index.zig");
const partial = @import("partial.zig");
const config_mod = @import("../config/config.zig");
const refspec_mod = @import("../wire.zig").refspec;
const ref_names = @import("../names.zig").ref;
const remote_mod = @import("../wire.zig").remote;
const url_mod = @import("../wire.zig").url;
const program = @import("../process.zig").program;
const protocol = @import("../wire.zig").protocol;
const transport = @import("transport.zig");
const bundle_uri = @import("bundle/uri.zig");
const object_walk = @import("../walk/object/walk.zig");
const index_pack = @import("../odb/index_pack.zig");
const progress_mod = @import("../report.zig").progress;
const credential = @import("../wire.zig").credential;
const auth = @import("../wire.zig").auth;
const warning = @import("../report.zig").warning;
const fsck = @import("../object/fsck.zig");
const promisors = @import("../wire.zig").promisors;
const accelerators = @import("../maintenance/maintenance.zig");
const maintenance_mod = @import("../maintenance/run.zig");
const alternate_refs = @import("alternate_refs.zig");

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
    /// A negotiation tip names an object this repository does not have:
    /// git's "the object <name> does not exist".
    NegotiationTipMissing,
    /// `fetch.negotiationAlgorithm` names none git knows: git's "unknown
    /// fetch negotiation algorithm".
    UnknownNegotiationAlgorithm,
    /// `all` with remotes named: git's "fetch --all does not take a
    /// repository argument".
    AllTakesNoRemote,
    /// Of several names, one is neither a remote nor a group: git's "no
    /// such remote or remote group".
    NoSuchRemoteOrGroup,
    /// A negotiation alone asked with no tips to restrict it to: git's
    /// "--negotiate-only needs one or more --negotiation-restrict=*".
    NegotiationRestrictNeeded,
} || alternate_refs.Error || partial.FilterError || transport.Error || remote_mod.Error || refs_mod.TransactionError || object_walk.Error || fsck.LoadError || config_mod.Config.SetError ||
    rev_walk.Error || fs.AtomicWriteError || Io.Dir.OpenError || shallow_mod.Error;

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
    /// `--prefetch`: every refspec's destination moved under
    /// `refs/prefetch/` and forced, one without a destination or fetching
    /// a tag left out, and the remote's `HEAD` not fetched in place of
    /// none: git's `filter_prefetch_refspec`, for `maintenance`.
    prefetch: bool = false,
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
    /// `--shallow-since`: the history cut at commits older than this.
    shallow_since: ?Io.Timestamp = null,
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
    /// `--negotiation-restrict`: the only refs (a name, or a pattern
    /// over every ref) whose history a fetch offers as haves; `null` takes
    /// `remote.<name>.negotiationRestrict`, and none of either offers
    /// every ref's.
    negotiation_restrict: ?[]const []const u8 = null,
    /// `--negotiation-include`: refs whose objects are offered whatever
    /// the negotiator chooses; `null` takes
    /// `remote.<name>.negotiationInclude`.
    negotiation_include: ?[]const []const u8 = null,
    /// `--server-option`s, sent with every protocol v2 request; `null`
    /// takes `remote.<name>.serverOption`, as git does.
    server_options: ?[]const []const u8 = null,
    /// Whether the commit graph is written after the fetch; `null` takes
    /// `fetch.writeCommitGraph`.
    write_commit_graph: ?bool = null,
    /// `--keep`: what came is kept as a pack, however few its objects;
    /// otherwise a pack of fewer than `fetch.unpackLimit` objects
    /// (`transfer.unpackLimit`, git's 100) is stored loose, as git's
    /// `unpack-objects` stores it.
    keep: bool = false,
    /// `--filter`, for a partial clone's promisor remote; `null` takes
    /// `remote.<name>.partialclonefilter`, as git does.
    filter: ?[]const u8 = null,
    /// The permission to run programs, which an ssh remote and a
    /// credential helper need.
    programs: ?program.Programs = null,
    /// What stands in for a terminal when an HTTP server asks for a
    /// credential no helper has. Without one nothing is asked, and
    /// askpass runs only when it says so.
    /// The proxy for an HTTP remote, over the one the configuration and
    /// the environment choose.
    proxy: httpsettings_mod.Proxy = .auto,
    prompt: ?credential.Prompt = null,
    /// Filled in, when the operation fails for want of a credential, with
    /// what a person needs to put it right: see `auth.Failure`.
    auth_failure: ?*auth.Failure = null,
    /// Where what git would print as a warning goes, as values: see
    /// `warning.Warnings`.
    warnings: ?*warning.Warnings = null,
    progress: ?progress_mod.Progress = null,
    /// Whether received objects are checked as git's `index-pack --strict`
    /// checks them, with `fetch.fsck.*`: `null` takes `fetch.fsckObjects`,
    /// or `transfer.fsckObjects`. Neither set, they are still checked,
    /// with git's levels and a path naming `.git` refused (`fsck.baseline`);
    /// `false` checks nothing, as git does not.
    check_objects: ?bool = null,
    /// Where the object behind `error.MissingObject` is written.
    missing: ?*Oid = null,
    /// Whether the person named this remote themselves:
    /// `transport.Options.from_user`.
    /// A submodule's clone and fetch pass false, so a `.gitmodules` cannot
    /// reach a repository on this machine unless `protocol.file.allow` says
    /// it may.
    from_user: ?bool = null,
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
pub const HeadEntry = struct {
    oid: Oid,
    for_merge: bool,
    /// `branch 'main' of <url>` and the like: everything after the second
    /// tab.
    description: []const u8,
};

/// What a fetch did.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    updates: []const Update,
    /// Remote-tracking refs deleted because their source is gone.
    pruned: []const []const u8,
    fetch_head: []const HeadEntry,
    /// The pack that came and is kept, or `null` when nothing new was
    /// needed or what came was stored loose; `objects` counts it either way.
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

fn reflogAction(arena: Allocator, remote_name: []const u8, options: Options) Allocator.Error![]const u8 {
    return options.reflog_action orelse blk: {
        var text: std.ArrayList(u8) = .empty;
        try text.print(arena, "fetch {s}", .{remote_name});
        for (options.refspecs) |spec| try text.print(arena, " {s}", .{spec});
        break :blk text.items;
    };
}

const FilterSelection = struct { auto: bool, spec: ?[]const u8 };

fn selectFilter(arena: Allocator, config: *const config_mod.Config, explicit: ?[]const u8, promisor: bool, remote_name: ?[]const u8) Error!FilterSelection {
    var auto_filter = false;
    const filter_spec: ?[]const u8 = blk: {
        const spec = explicit orelse if (promisor) configured: {
            const key = try arena.print("remote.{s}.partialclonefilter", .{remote_name.?});
            const raw = config.get(key) orelse break :configured null;
            break :configured try arena.dupe(u8, raw);
        } else null;
        const text = spec orelse break :blk null;
        if (!promisor) return error.NotAPromisorRemote;
        if (std.mem.eql(u8, text, "auto")) {
            auto_filter = true;
            break :blk null;
        }
        break :blk try partial.normalize(arena, text);
    };
    return .{ .auto = auto_filter, .spec = filter_spec };
}

/// Fetch from `remote_name`, a configured remote or a URL, into `repo`.
pub fn fetch(gpa: Allocator, io: Io, repo: *Repository, remote_name: []const u8, options: Options) Self.Error!Outcome {
    const deepen = try deepenRequest(repo, options);
    // git's fetch takes `fetch.bundleURI`'s bundles first, whatever it
    // fetches after, and warns when they fail.
    if (repo.configuration().get("fetch.bundleuri")) |uri| {
        const got = try bundle_uri.fetch(gpa, io, repo, uri, .{ .who = options.who, .transport = .{
            .programs = options.programs,
            .config = repo.configuration(),
            .proxy = options.proxy,
            .prompt = options.prompt,
            .auth_failure = options.auth_failure,
            .warnings = options.warnings,
            .now = gitdate.timestamp(options.who.when_secs),
            .repository = repo,
            .who = options.who,
            .from_user = options.from_user,
        } });
        if (!got.ok) try warning.note(options.warnings, .{ .bundle_uri_fetch_failed = uri });
    }

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

    var remote = try remote_mod.Remote.get(gpa, repo.configuration(), repo.objectFormat(), remote_name);
    defer remote.deinit();

    var to_warnings: fsck.ToWarnings = .{ .warnings = options.warnings };
    var rules = try fsck.forTransfer(gpa, io, repo.configuration(), .{ .kind = repo.objectFormat(), .scope = .fetch, .base = repo.topDirectory() }, .{ .explicit = options.check_objects, .sink = to_warnings.sink() });
    defer if (rules) |*r| r.deinit(gpa);
    const checks: ?*const fsck.Rules = if (rules) |*r| r else null;

    const rla = try reflogAction(arena, remote_name, options);
    const tags = options.tags orelse remote.tags;
    const prune = options.prune orelse remote.prune orelse false;
    const prune_tags = options.prune_tags orelse remote.prune_tags orelse false;
    var branch_config: ?remote_mod.Branch = null;
    defer if (branch_config) |*b| b.deinit();
    var asked = try askedRefspecs(arena, gpa, io, repo, &remote, options.refspecs, prune and prune_tags, &branch_config);
    if (options.prefetch) asked = try asked.prefetched(arena);

    const follow_head = asked.cli.len == 0 and remote.name != null and followRemoteHead(repo.configuration(), remote.name.?);

    // A promisor remote's packs are filtered as the clone was, and what
    // they leave out is promised rather than missing.
    const promisor = remote.name != null and partial.isPromisor(repo.configuration(), remote.name.?);
    // `auto` is the filter of the promisor remotes taken from the server's
    // advertisement, known once the session is open.
    const selection = try selectFilter(arena, repo.configuration(), options.filter, promisor, remote.name);
    var filter_spec = selection.spec;

    const url = remote.urls[0];
    var session = try openSession(gpa, io, repo, &remote, url, options);
    defer session.deinit(io);
    try partial.storeAdvertised(io, repo, session.promisorStores(), options.warnings);
    if (selection.auto) filter_spec = try promisors.autoFilter(arena, repo.configuration(), session.promisorsTaken());

    // Ask for the refs the refspecs can name, as git does.
    var remote_refs = try session.listRefs(gpa, io, try refPrefixes(arena, asked, tags != .none, follow_head));
    defer remote_refs.deinit();

    // The local refs, by name.
    var local_refs = try repo.refStore().list(gpa, io, "refs/");
    defer local_refs.deinit();
    var local = try LocalIndex.init(gpa, &local_refs);
    defer local.deinit(gpa);

    const planned = try refMap(arena, gpa, io, repo, &remote, &remote_refs, asked, tags, &local);
    const map = planned.map;
    const autotags = planned.autotags;

    // A working tree's branch is never fetched into.
    if (!options.update_head_ok) try refuseCheckedOut(arena, gpa, io, repo, map.items, &local);

    // Prune first, as git does, so a ref that moved to a name nested
    // under a pruned one can be created.
    const pruned: []const []const u8 = if (prune) try pruneStale(arena, gpa, io, repo, local_refs.entries, map.items, asked.specs) else &.{};

    var boundary_change: BoundaryChange = .{ .old = repo.objectDatabase().shallow };
    defer boundary_change.release(gpa);
    errdefer boundary_change.restore(gpa, repo);
    var brought = try bringObjects(arena, gpa, io, repo, &session, &boundary_change, .{
        .map = map.items,
        .remote_refs = remote_refs.refs,
        .local = &local,
        .local_refs = local_refs.entries,
        .deepen = deepen,
        .tags = tags,
        .autotags = autotags,
        .filter = filter_spec,
        .checks = checks,
        .promisor = promisor,
        .options = options,
        .remote = &remote,
    });
    defer brought.deinit(io);
    const backfill = brought.backfill;

    // The refs, in git's order: those for merging first.
    const plan = try planUpdates(arena, gpa, io, repo, .{ map.items, backfill }, try url_mod.anonymize(arena, url), rla, options, &local);
    try writeRefs(io, repo, plan.pending, options, plan.updates);

    if (follow_head) try createRemoteHead(gpa, io, repo, remote.name.?, remote_refs.refs, asked.configured, options.who);

    if (options.write_fetch_head) try writeFetchHead(gpa, io, repo, plan.fetch_head, options.append);
    try brought.settle(io, repo, &outcome, options.keep or promisor or (checks != null and checks.?.strict));

    if (options.write_commit_graph orelse try repo.configuration().getBool("fetch.writecommitgraph", false)) try writeCommitGraph(gpa, io, repo, options.warnings);
    outcome.updates = plan.updates;
    outcome.pruned = pruned;
    outcome.fetch_head = plan.fetch_head;
    return outcome;
}

/// What `bringObjects` brings, and what it knows to ask.
const Bringing = struct {
    map: []MapEntry,
    remote_refs: []const protocol.RemoteRef,
    local: *const LocalIndex,
    local_refs: []const refs_mod.Named,
    deepen: ?fetch_pack.Deepen,
    tags: remote_mod.TagMode,
    /// Whether a refspec that keeps refs asked for tags to follow.
    autotags: bool,
    filter: ?[]const u8,
    checks: ?*const fsck.Rules,
    promisor: bool,
    options: Options,
    remote: *const remote_mod.Remote,
};

/// One pack a fetch brought: its name, if one came, how many objects, and
/// the `.keep` that holds it until the refs name them.
const Came = struct {
    name: ?Oid = null,
    objects: u32 = 0,
    keep: ?keep_mod.Token = null,
};

/// What came: the pack, if one did, and the tags that followed in a pack
/// of their own.
const Brought = struct {
    packs: [2]Came,
    backfill: []MapEntry,

    fn deinit(b: *Brought, io: Io) void {
        for (&b.packs) |*came| if (came.keep) |*t| t.deinit(io);
        b.* = undefined;
    }

    /// What came, into `outcome`, stored as git's `get_pack` decides:
    /// `unpack-objects` below the unpack limit unless `kept` -- `--keep`, a
    /// promisor pack, or objects checked one by one, which `index-pack`
    /// keeps. Here once the refs name what came, as for a push received.
    fn settle(b: *Brought, io: Io, repo: *Repository, outcome: *Outcome, kept: bool) Error!void {
        outcome.pack = b.packs[0].name;
        outcome.objects = b.packs[0].objects;
        if (kept) return;
        if (try b.unpackSmall(io, repo, unpackLimit(repo.configuration()))) outcome.pack = null;
    }

    /// Each pack of fewer than `limit` objects stored loose
    /// (`Odb.unpackPack`), every one when `limit` is zero, as git's
    /// fetch-pack reads no count then. Whether the first one was. A pack
    /// that cannot be is left as it came.
    fn unpackSmall(b: *Brought, io: Io, repo: *Repository, limit: u64) Error!bool {
        var first = false;
        for (&b.packs, 0..) |*came, i| {
            const name = came.name orelse continue;
            if (limit != 0 and came.objects >= limit) continue;
            if (came.keep) |*t| t.deinit(io);
            came.keep = null;
            var hex: [hash.max_hex_len]u8 = undefined;
            var name_buf: [96]u8 = undefined;
            // unreachable: the longest hex name is 64 digits, 69 bytes with `pack-`
            const base = std.mem.print(&name_buf, "pack-{s}", .{name.hex(&hex)}) catch unreachable;
            repo.objectDatabase().unpackPack(io, base) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                // the pack still holds every object
                else => continue,
            };
            if (i == 0) first = true;
        }
        return first;
    }
};

/// git's `fetch.unpackLimit`, else `transfer.unpackLimit`, else 100.
fn unpackLimit(config: *const config_mod.Config) u64 {
    for ([_][]const u8{ "fetch.unpacklimit", "transfer.unpacklimit" }) |key| {
        const value = config.getInt(key, -1) catch -1;
        if (value >= 0) return @intCast(value);
    }
    return 100;
}

/// Bring the objects the map names that are not here yet into one new
/// pack, take the boundary the server drew in `boundary_change`, follow
/// tags, and check that everything below the fetched refs is here before
/// the new boundary is written.
fn bringObjects(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    session: *transport.Session,
    boundary_change: *BoundaryChange,
    b: Bringing,
) Error!Brought {
    // The objects: everything the map names that is not here yet.
    // Deepening asks again for what is here: its history is what is
    // wanted.
    const wants = try wantsInOrder(arena, io, repo, b.remote_refs, b.map, b.deepen != null);
    const restrict = try resolveTips(arena, gpa, io, repo, b.options.negotiation_restrict orelse b.remote.negotiation_restrict, "--negotiation-restrict", b.options.warnings);
    // git's v0 takes what is common from every ref the server advertised,
    // v2 from those `ls-refs` listed.
    var advertised: ?protocol.RefList = if (session.protocolVersion()) |v| switch (v) {
        .v0, .v1 => try session.listRefs(gpa, io, &.{}),
        .v2 => null,
    } else null;
    defer if (advertised) |*list| list.deinit();
    const tips = try negotiationTips(arena, gpa, io, repo, b.local_refs, if (advertised) |list| list.refs else b.remote_refs, b.options, .{ .restrict = restrict, .deepen = b.deepen != null });
    const include = try resolveTips(arena, gpa, io, repo, b.options.negotiation_include orelse b.remote.negotiation_include, "--negotiation-include", b.options.warnings);

    var pack_dir = try repo.objectDatabase().openPackDirectory(io);
    defer pack_dir.close(io);
    const boundary = try shallowList(arena, &repo.objectDatabase().shallow);
    var shallow_info: fetch_pack.ShallowInfo = .{ .gpa = gpa };
    defer shallow_info.deinit();
    // What the pack's objects name, collected as it is indexed, so that
    // whether it is connected is asked without reading it again.
    var links: index_pack.Links = .init(gpa);
    defer links.deinit();
    var fetched = try session.fetch(gpa, io, .{ .db = repo.objectDatabase(), .pack_dir = pack_dir, .request = .{
        .wants = wants.oids,
        .want_names = wants.names,
        .tips = tips.ours,
        .common_tips = tips.common,
        .include_tag = b.tags != .none,
        .deepen = b.deepen,
        .shallow = boundary,
        .filter = b.filter,
        .negotiation = try negotiationAlgorithm(repo.configuration()),
        .include_haves = include orelse &.{},
    } }, .{
        .warnings = b.options.warnings,
        .progress = b.options.progress,
        .receive = receiveOptions(repo, b.checks, b.promisor, b.options.warnings, &links),
        .shallow_info = &shallow_info,
    });
    errdefer fetched.deinit(io);
    // A remote helper's import learns the values as it goes.
    takeFetchedValues(session, b.map);
    // A fetch's promisor pack names no refs; git's names none either.
    if (b.promisor) if (fetched.pack) |name| try partial.writePromisor(gpa, io, repo.objectDatabase(), name, &.{});

    try boundary_change.take(arena, gpa, repo, &shallow_info, session.advertisedShallow(), b.deepen != null);

    // Tags that point at what the fetch brought.
    var tag_pack: Came = .{};
    errdefer if (tag_pack.keep) |*t| t.deinit(io);
    const backfill: []MapEntry = if (b.tags == .auto and b.autotags)
        try followTags(arena, gpa, io, repo, session, pack_dir, .{
            .remote_refs = b.remote_refs,
            .local = b.local,
            .map = b.map,
            .tips = tips,
            .progress = b.options.progress,
            .receive = receiveOptions(repo, b.checks, b.promisor, b.options.warnings, null),
            .came = &tag_pack,
        })
    else
        &.{};

    // Everything below the fetched refs is here: what came in the pack is
    // walked into, what was here before is taken to be whole.
    try checkConnected(arena, gpa, io, repo, .{
        .pack_dir = pack_dir,
        .pack = fetched.pack,
        .links = &links,
        .passes = .{ b.map, backfill },
        .remote_roots = boundary_change.remote_roots,
        .old_boundary = &boundary_change.old,
        .promisor = b.promisor,
        .update_shallow = b.options.update_shallow,
        .missing = b.options.missing,
    });

    if (boundary_change.moved) try repo.writeShallow(io);
    return .{ .packs = .{ .{ .name = fetched.pack, .objects = fetched.objects, .keep = fetched.keep }, tag_pack }, .backfill = backfill };
}

/// Which remotes a fetch of several asks for.
pub const Selection = struct {
    /// Remotes, or groups of them under `remotes.<group>`.
    names: []const []const u8 = &.{},
    /// `--all`, `--no-all`; `null` takes `fetch.all` when no name is given.
    all: ?bool = null,
};

/// git's choice of remotes for `git fetch`: with `all` (else, given no
/// name, `fetch.all`) every remote but those `remote.<name>.skipFetchAll`
/// leaves out; else each name, a group's (`remotes.<group>`, its names
/// split at blanks) standing for its remotes; one name that is neither is
/// itself, a URL, and of several such a name is refused. Each once, in
/// git's order. `arena`'s.
pub fn remotesToFetch(arena: Allocator, config: *const config_mod.Config, selection: Selection) Self.Error![]const []const u8 {
    const all = selection.all orelse if (selection.names.len == 0) try config.getBool("fetch.all", false) else false;
    var out: std.ArrayList([]const u8) = .empty;
    if (all) {
        if (selection.names.len != 0) return error.AllTakesNoRemote;
        for (try remote_mod.names(arena, config)) |name| {
            var remote = try remote_mod.Remote.get(arena, config, .sha1, name);
            defer remote.deinit();
            if (!remote.skip_default_update) try out.append(arena, name);
        }
        return out.items;
    }
    for (selection.names) |name| {
        const before = out.items.len;
        var it = config.iterate(&.{try arena.print("remotes.{s}", .{name})});
        while (it.next()) |entry| {
            var words = std.mem.tokenizeAny(u8, entry.value orelse "", " \t\n");
            while (words.next()) |word| try appendOnce(arena, &out, word);
        }
        if (out.items.len != before) continue;
        if (selection.names.len > 1 and !remote_mod.isConfigured(config, name)) return error.NoSuchRemoteOrGroup;
        try appendOnce(arena, &out, name);
    }
    return out.items;
}

fn appendOnce(arena: Allocator, list: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    for (list.items) |have| if (std.mem.eql(u8, have, name)) return;
    try list.append(arena, name);
}

/// One remote's part of `fetchMany`: what came, or why not.
pub const Fetched = union(enum) {
    fetched: Outcome,
    failed: Self.Error,
};

/// What `fetchMany` did, remote by remote, in the order asked.
pub const Many = struct {
    names: []const []const u8,
    results: []Fetched,
    gpa: Allocator,

    pub fn deinit(m: *Many) void {
        for (m.results) |*r| switch (r.*) {
            .fetched => |*outcome| outcome.deinit(),
            .failed => {},
        };
        m.gpa.free(m.results);
        m.* = undefined;
    }

    /// Whether any remote failed: git's exit status.
    pub fn anyFailed(m: *const Many) bool {
        for (m.results) |r| if (r == .failed) return true;
        return false;
    }
};

/// git's `fetch_multiple`: each of `names` fetched as `fetch` fetches it,
/// `FETCH_HEAD` emptied first unless `options.append` and each remote's
/// lines added to it, the commit graph written once after them all as
/// `fetch.writeCommitGraph` says; one remote failing is noted and the rest
/// still fetched. `jobs` at once (`null` takes `fetch.parallel`, 0 is one
/// per processor) when the `Io` runs tasks beside each other, each on its
/// own handle on the repository (`Repository.openAgain`).
pub fn fetchMany(gpa: Allocator, io: Io, repo: *Repository, names: []const []const u8, options: Options, jobs: ?u32) Self.Error!Many {
    const results = try gpa.alloc(Fetched, names.len);
    errdefer gpa.free(results);
    for (results) |*r| r.* = .{ .failed = error.Canceled };
    if (!options.append and options.write_fetch_head) try writeFetchHead(gpa, io, repo, &.{}, false);
    var each = options;
    each.append = true;
    each.write_commit_graph = false;
    const configured = try repo.configuration().getInt("fetch.parallel", 1);
    var limit: usize = jobs orelse @intCast(@max(configured, 0));
    if (limit == 0) limit = std.Thread.getCpuCount() catch 1;
    if (limit > 1 and names.len > 1) {
        var group: Io.Group = .init;
        defer group.cancel(io);
        var next: usize = 0;
        while (next < names.len) {
            const batch_end = @min(names.len, next + limit);
            for (next..batch_end) |i| group.concurrent(io, fetchOneAgain, .{ gpa, io, repo, names[i], each, &results[i] }) catch {
                fetchOne(gpa, io, repo, names[i], each, &results[i]);
            };
            try group.await(io);
            next = batch_end;
        }
    } else for (names, results) |name, *result| fetchOne(gpa, io, repo, name, each, result);
    if (options.write_commit_graph orelse try repo.configuration().getBool("fetch.writecommitgraph", false)) try writeCommitGraph(gpa, io, repo, options.warnings);
    return .{ .names = names, .results = results, .gpa = gpa };
}

fn fetchOne(gpa: Allocator, io: Io, repo: *Repository, name: []const u8, options: Options, result: *Fetched) void {
    result.* = if (fetch(gpa, io, repo, name, options)) |outcome| .{ .fetched = outcome } else |err| .{ .failed = err };
}

/// `fetchOne` beside the others, on a handle of its own.
fn fetchOneAgain(gpa: Allocator, io: Io, repo: *Repository, name: []const u8, options: Options, result: *Fetched) void {
    var again = repo.openAgain(io) catch |err| {
        result.* = .{ .failed = err };
        return;
    };
    defer again.deinit(io);
    fetchOne(gpa, io, &again, name, options, result);
}

/// git's `git fetch --negotiate-only`: the history from
/// `options.negotiation_restrict` (else `remote.<name>.negotiationRestrict`),
/// with `negotiation_include`, offered to the remote under protocol v2
/// until it has said which of it it has; nothing is fetched and nothing
/// here changes. The commits it acknowledged, the caller's, as `git push`
/// asks for them under `push.negotiate`.
pub fn negotiateOnly(gpa: Allocator, io: Io, repo: *Repository, remote_name: []const u8, options: Options) Self.Error![]Oid {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var remote = try remote_mod.Remote.get(gpa, repo.configuration(), repo.objectFormat(), remote_name);
    defer remote.deinit();
    const restrict_names = options.negotiation_restrict orelse remote.negotiation_restrict;
    if (restrict_names.len == 0) return error.NegotiationRestrictNeeded;
    const restrict = try resolveTips(arena, gpa, io, repo, restrict_names, "--negotiation-restrict", options.warnings);
    const include = try resolveTips(arena, gpa, io, repo, options.negotiation_include orelse remote.negotiation_include, "--negotiation-include", options.warnings);
    var session = try openSession(gpa, io, repo, &remote, remote.urls[0], options);
    defer session.deinit(io);
    return session.negotiateOnly(gpa, io, repo.objectDatabase(), .{
        .wants = &.{},
        .tips = restrict orelse &.{},
        .include_haves = include orelse &.{},
        .negotiation = try negotiationAlgorithm(repo.configuration()),
    });
}

/// The shallow boundary across a fetch: the one before it, put back if
/// the fetch fails, and the remote's roots the fetch did not ask for.
const BoundaryChange = struct {
    old: Oid.Set,
    /// Whether `repo.objectDatabase().shallow` is a new set, `old` kept beside it.
    moved: bool = false,
    /// A shallow remote's boundary, on a fetch that did not ask for one:
    /// walked with for the connectivity check, and kept only as
    /// `update_shallow` says.
    remote_roots: []const Oid = &.{},

    /// Take the boundary the server drew. Walks from here on stop at it;
    /// it is written once everything below the refs is known to be here.
    fn take(
        b: *BoundaryChange,
        arena: Allocator,
        gpa: Allocator,
        repo: *Repository,
        info: *fetch_pack.ShallowInfo,
        advertised: []const Oid,
        deepened: bool,
    ) Error!void {
        assert(!b.moved);
        if (!deepened) try info.shallow.appendSlice(gpa, advertised);
        if (info.shallow.items.len == 0 and info.unshallow.items.len == 0) return;
        if (!deepened) {
            var roots: std.ArrayList(Oid) = .empty;
            for (info.shallow.items) |oid| {
                if (!b.old.contains(oid)) try roots.append(arena, oid);
            }
            b.remote_roots = roots.items;
        }
        repo.objectDatabase().shallow = try shallow_mod.apply(gpa, &b.old, info.shallow.items, info.unshallow.items);
        b.moved = true;
    }

    /// Put the old boundary back, after a failure.
    fn restore(b: *BoundaryChange, gpa: Allocator, repo: *Repository) void {
        if (!b.moved) return;
        repo.objectDatabase().shallow.deinit(gpa);
        repo.objectDatabase().shallow = b.old;
        b.moved = false;
    }

    /// Release the old boundary, once a new one replaced it for good.
    fn release(b: *BoundaryChange, gpa: Allocator) void {
        if (b.moved) b.old.deinit(gpa);
    }
};

/// What `followTags` asks about.
const Following = struct {
    remote_refs: []const protocol.RemoteRef,
    local: *const LocalIndex,
    map: []const MapEntry,
    tips: Tips,
    progress: ?progress_mod.Progress,
    receive: index_pack.Options,
    came: *Came,
};

/// git's automatic tag following: the remote tags that point at what the
/// fetch brought, with the objects of those not here yet fetched too.
fn followTags(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, session: *transport.Session, pack_dir: Io.Dir, f: Following) Error![]MapEntry {
    var backfill: std.ArrayList(MapEntry) = .empty;
    try findNonLocalTags(arena, gpa, io, repo, f.remote_refs, f.local, &backfill, f.map);
    const missing_tags = try wantsInOrder(arena, io, repo, f.remote_refs, backfill.items, false);
    if (missing_tags.oids.len == 0) return backfill.items;
    const fetched = try session.fetch(gpa, io, .{ .db = repo.objectDatabase(), .pack_dir = pack_dir, .request = .{
        .wants = missing_tags.oids,
        .want_names = missing_tags.names,
        .tips = f.tips.ours,
        .common_tips = f.tips.common,
        .include_tag = false,
    } }, .{ .progress = f.progress, .receive = f.receive });
    f.came.* = .{ .name = fetched.pack, .objects = fetched.objects, .keep = fetched.keep };
    takeFetchedValues(session, backfill.items);
    return backfill.items;
}

/// Write the commit-graph `fetch.writeCommitGraph` asks for. A failure is
/// a warning, as git's is: the fetch itself is done.
fn writeCommitGraph(gpa: Allocator, io: Io, repo: *Repository, warnings: ?*warning.Warnings) Error!void {
    _ = accelerators.writeConfiguredCommitGraph(gpa, io, repo, .fetch) catch |err| {
        try warning.note(warnings, .{ .commit_graph_write_failed = @errorName(err) });
    };
}

/// The refspecs a fetch follows.
const Asked = struct {
    /// The command line's.
    cli: []const Refspec,
    /// The remote's, with `refs/tags/*:refs/tags/*` for `pruneTags`.
    configured: []const Refspec,
    /// The current branch's `merge` settings, when it follows this remote.
    branch_merge: []const []const u8,
    /// `cli` when it names any, else `configured`: what negative refspecs
    /// and pruning go by.
    specs: []const Refspec,
    /// The remote's own, which refs the command line fetched also go to.
    remote_fetch: []const Refspec,
    /// `--prefetch`: no `HEAD` when nothing is asked.
    prefetch: bool = false,

    /// `filter_prefetch_refspec` over every list.
    fn prefetched(asked: Asked, arena: Allocator) Allocator.Error!Asked {
        var out = asked;
        out.cli = try filterPrefetch(arena, asked.cli);
        out.configured = try filterPrefetch(arena, asked.configured);
        out.remote_fetch = try filterPrefetch(arena, asked.remote_fetch);
        out.specs = if (out.cli.len != 0) out.cli else out.configured;
        out.prefetch = true;
        return out;
    }
};

/// git's `filter_prefetch_refspec`: a negative refspec kept; one with no
/// destination, or a source under `refs/tags/`, left out; each other's
/// destination under `refs/prefetch/` (in place of `refs/`), forced.
fn filterPrefetch(arena: Allocator, specs: []const Refspec) Allocator.Error![]const Refspec {
    var out: std.ArrayList(Refspec) = .empty;
    for (specs) |spec| {
        if (spec.negative) {
            try out.append(arena, spec);
            continue;
        }
        const dst = spec.dst orelse continue;
        if (std.mem.startsWith(u8, spec.src, "refs/tags/")) continue;
        var moved = spec;
        moved.dst = try arena.print("refs/prefetch/{s}", .{if (std.mem.startsWith(u8, dst, "refs/")) dst["refs/".len..] else dst});
        moved.force = true;
        try out.append(arena, moved);
    }
    return out.items;
}

/// The refspecs `refspecs` and `remote` ask for, `tags_refspec` adding
/// the tags `pruneTags` prunes by. The current branch's settings are kept
/// in `branch_config`, which the merge names point into.
fn askedRefspecs(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    refspecs: []const []const u8,
    tags_refspec: bool,
    branch_config: *?remote_mod.Branch,
) Error!Asked {
    var cli: std.ArrayList(Refspec) = .empty;
    for (refspecs) |text| {
        try cli.append(arena, Refspec.parse(try arena.dupe(u8, text), .fetch, repo.objectFormat()) catch return error.InvalidRefspec);
    }

    // `pruneTags` is a refspec: fetching every tag is how it knows which
    // are gone.
    var configured: std.ArrayList(Refspec) = .empty;
    try configured.appendSlice(arena, remote.fetch);
    if (tags_refspec and remote.name != null) {
        try configured.append(arena, try Refspec.parse("refs/tags/*:refs/tags/*", .fetch, repo.objectFormat()));
    }

    var branch_merge: []const []const u8 = &.{};
    const current = try repo.refStore().currentBranch(gpa, io);
    defer if (current) |c| gpa.free(c);
    if (current) |name| {
        branch_config.* = try remote_mod.Branch.get(gpa, repo.configuration(), name);
        const b = &branch_config.*.?;
        if (b.merge.len != 0 and b.remote != null and remote.name != null and std.mem.eql(u8, b.remote.?, remote.name.?)) {
            branch_merge = b.merge;
        }
    }
    return .{
        .cli = cli.items,
        .configured = configured.items,
        .branch_merge = branch_merge,
        .specs = if (cli.items.len != 0) cli.items else configured.items,
        .remote_fetch = remote.fetch,
    };
}

/// The session a fetch from `remote` at `url` talks over.
fn openSession(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, url: []const u8, options: Options) Error!transport.Session {
    const session = try transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = repo.objectFormat() }, .{
        .programs = options.programs,
        .config = repo.configuration(),
        .remote_name = remote.name,
        .service_program = remote.upload_pack,
        .proxy = options.proxy,
        .progress = options.progress,
        .prompt = options.prompt,
        .auth_failure = options.auth_failure,
        .warnings = options.warnings,
        // A credential's expiry is checked against the caller's time.
        .now = gitdate.timestamp(options.who.when_secs),
        .repository = repo,
        .who = options.who,
        .from_user = options.from_user,
        .server_options = options.server_options,
    });
    return session;
}

/// The ref prefixes to ask the server for: those the refspecs can name,
/// as git asks.
fn refPrefixes(arena: Allocator, asked: Asked, tags: bool, follow_head: bool) Error![]const []const u8 {
    var prefixes: std.ArrayList([]const u8) = .empty;
    for (asked.specs) |spec| try addPrefixes(arena, &prefixes, spec);
    if (asked.cli.len == 0) {
        for (asked.branch_merge) |merge| try expandPrefix(arena, &prefixes, merge);
        if (asked.specs.len == 0) try prefixes.append(arena, "HEAD");
    }
    if (prefixes.items.len != 0 and tags) try prefixes.append(arena, "refs/tags/");
    if (prefixes.items.len != 0 and follow_head) try prefixes.append(arena, "HEAD");
    return prefixes.items;
}

/// The ref map, and whether a refspec that keeps refs asked for tags to
/// follow.
const RefMap = struct { map: std.ArrayList(MapEntry), autotags: bool };

/// git's `get_ref_map`: what the command line names, else the configured
/// refspecs and the branch's merge settings, else the remote's `HEAD`,
/// with the tags `tags` asks for, negative refspecs applied and duplicates
/// dropped.
fn refMap(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    remote_refs: *const protocol.RefList,
    asked: Asked,
    tags: remote_mod.TagMode,
    local: *const LocalIndex,
) Error!RefMap {
    var map: std.ArrayList(MapEntry) = .empty;
    var autotags = false;
    if (asked.cli.len != 0) {
        for (asked.cli) |spec| {
            try fetchMap(arena, &map, remote_refs.refs, spec, false, .merge);
            if (spec.dst) |dst| {
                if (dst.len != 0) autotags = true;
            }
        }
    } else if (asked.configured.len != 0 or asked.branch_merge.len != 0) {
        for (asked.configured, 0..) |spec, i| {
            const before = map.items.len;
            try fetchMap(arena, &map, remote_refs.refs, spec, false, .not_for_merge);
            if (spec.dst) |dst| {
                if (dst.len != 0) autotags = true;
            }
            if (i == 0 and asked.branch_merge.len == 0 and map.items.len > before and !spec.pattern) {
                map.items[before].status = .merge;
            }
        }
        for (asked.branch_merge) |merge| {
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
    } else if (!asked.prefetch) {
        const head = remote_refs.find("HEAD") orelse return error.RemoteRefNotFound;
        if (head.unborn) return error.RemoteRefNotFound;
        try map.append(arena, .{ .name = "HEAD", .oid = head.oid, .dst = null, .force = false, .status = .merge });
    }

    if (tags == .all) {
        try fetchMap(arena, &map, remote_refs.refs, try Refspec.parse("refs/tags/*:refs/tags/*", .fetch, repo.objectFormat()), false, .not_for_merge);
    } else if (tags == .auto and autotags) {
        try findNonLocalTags(arena, gpa, io, repo, remote_refs.refs, local, &map, null);
    }

    // Refs the command line fetched are also kept where the configured
    // refspecs would keep them, without a line in `FETCH_HEAD`.
    if (asked.cli.len != 0 and remote.name != null) {
        const named = map.items.len;
        for (asked.remote_fetch) |spec| {
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

    try applyNegative(arena, &map, asked.specs);
    try removeDuplicates(&map);
    return .{ .map = map, .autotags = autotags };
}

/// `error.WouldUpdateCheckedOutBranch` when the map would write a branch a
/// working tree has checked out.
fn refuseCheckedOut(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, map: []const MapEntry, local: *const LocalIndex) Error!void {
    const checked_out = try checkedOutBranches(arena, gpa, io, repo);
    for (map) |entry| {
        const dst = entry.dst orelse continue;
        for (checked_out) |branch| {
            if (!std.mem.eql(u8, branch, dst)) continue;
            if (local.names.contains(dst)) return error.WouldUpdateCheckedOutBranch;
        }
    }
}

/// Delete the local refs `specs` keep whose remote ref the map no longer
/// fetches, with their logs: git's `prune_refs`. The names deleted, in
/// `arena`.
fn pruneStale(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    local_refs: []const refs_mod.Named,
    map: []const MapEntry,
    specs: []const Refspec,
) Error![]const []const u8 {
    var pruned: std.ArrayList([]const u8) = .empty;
    var fetched_names: std.StringHashMapUnmanaged(void) = .empty;
    defer fetched_names.deinit(gpa);
    for (map) |m| try fetched_names.put(gpa, m.name, {});
    for (local_refs) |entry| {
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
        // Deleting the ref deletes its log, in either format.
        try tx.commit(io, null);
        try pruned.append(arena, try arena.dupe(u8, entry.name));
    }
    return pruned.items;
}

/// What negotiation starts from: every local ref's object and `HEAD`'s,
/// what the alternates' refs name (git's `insert_one_alternate_object`),
/// and those of them the server also advertised.
const Tips = struct { ours: []const Oid, common: []const Oid };

/// git's `fetch.negotiationAlgorithm`, `feature.experimental` making
/// `skipping` the default, as `prepare_repo_settings` reads them.
fn negotiationAlgorithm(config: *const config_mod.Config) Error!fetch_pack.Negotiation {
    const experimental = config.getBool("feature.experimental", false) catch false;
    const default: fetch_pack.Negotiation = if (experimental) .skipping else .consecutive;
    const text = config.get("fetch.negotiationalgorithm") orelse return default;
    for ([_]fetch_pack.Negotiation{ .skipping, .noop, .consecutive }) |algorithm| {
        if (std.ascii.eqlIgnoreCase(text, @tagName(algorithm))) return algorithm;
    }
    if (std.ascii.eqlIgnoreCase(text, "default")) return default;
    return error.UnknownNegotiationAlgorithm;
}

/// git's `add_negotiation_tips`: each name's object (a name that names
/// nothing passed over), or every ref a pattern matches -- under `refs/`
/// unless it starts there, `*` crossing `/` -- with git's warning for a
/// pattern that matches none. `null` for no names.
fn resolveTips(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, names: []const []const u8, from: []const u8, warnings: ?*warning.Warnings) Error!?[]const Oid {
    if (names.len == 0) return null;
    var oids: std.ArrayList(Oid) = .empty;
    var listing: ?refs_mod.Store.Listing = null;
    defer if (listing) |*l| l.deinit();
    for (names) |name| {
        const glob_like = for (name) |c| {
            if (glob.isSpecial(c)) break true;
        } else false;
        if (!glob_like) {
            const oid = rev_parse.resolve(gpa, io, repo, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => continue,
            };
            if (!try repo.objectDatabase().exists(io, oid)) return error.NegotiationTipMissing;
            try oids.append(arena, oid);
            continue;
        }
        if (listing == null) listing = try repo.refStore().list(gpa, io, "refs/");
        const pattern = if (std.mem.startsWith(u8, name, "refs/")) name else try arena.print("refs/{s}", .{name});
        const before = oids.items.len;
        for (listing.?.entries) |entry| {
            if (!try glob.matches(gpa, pattern, entry.name, .{ .pathname = false })) continue;
            const oid = switch (entry.target) {
                .direct => |oid| oid,
                .symbolic => (try repo.refStore().readOid(arena, io, entry.name)) orelse continue,
            };
            try oids.append(arena, oid);
        }
        if (oids.items.len == before) try warning.note(warnings, .{ .negotiation_tip_unmatched = .{ .from = from, .pattern = name } });
    }
    return oids.items;
}

/// Where the haves start: every ref's tip and `HEAD`, or the
/// `restrict`ed tips alone, and the alternates' refs either way; and the
/// remote's refs this repository has, offered first.
fn negotiationTips(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, local_refs: []const refs_mod.Named, remote_refs: []const protocol.RemoteRef, options: Options, how: struct { restrict: ?[]const Oid, deepen: bool }) Error!Tips {
    var tips: std.ArrayList(Oid) = .empty;
    for (local_refs) |entry| switch (entry.target) {
        .direct => |oid| try tips.append(arena, oid),
        .symbolic => {},
    };
    const refs_end = tips.items.len;
    if (try repo.refStore().read(gpa, io, "HEAD")) |head| switch (head) {
        .direct => |oid| try tips.append(arena, oid),
        .symbolic => |target| gpa.free(target),
    };
    const borrowed = try alternate_refs.read(gpa, io, repo, options.programs, options.warnings);
    defer gpa.free(borrowed);
    var alternates: usize = 0;
    for (borrowed) |oid| {
        // Only what is here to be had: an object an alternate's ref names
        // and no longer has is passed over, as git parses it first.
        if (!try repo.objectDatabase().exists(io, oid)) continue;
        try tips.append(arena, oid);
        alternates += 1;
    }
    // What is complete here: the refs' history, and the alternates'.
    var complete_from: std.ArrayList(Oid) = .empty;
    try complete_from.appendSlice(arena, tips.items[0..refs_end]);
    try complete_from.appendSlice(arena, tips.items[tips.items.len - alternates ..]);
    const common = if (how.deepen) &.{} else try knownCommon(arena, gpa, io, repo, complete_from.items, remote_refs);
    // git's `mark_tips`: the restricted tips in place of the refs, the
    // alternates' as before.
    if (how.restrict) |only| {
        var ours: std.ArrayList(Oid) = .empty;
        try ours.appendSlice(arena, only);
        try ours.appendSlice(arena, tips.items[tips.items.len - alternates ..]);
        return .{ .ours = ours.items, .common = common };
    }
    return .{ .ours = tips.items, .common = common };
}

/// git's `mark_complete_and_common_ref`: the commits complete here -- the
/// refs' and the alternates' tips, and their history back to the newest
/// date among the remote's refs this repository has -- and of the remote's
/// refs, in its order, those whose commit is one of them: what the
/// negotiation takes the server to have.
fn knownCommon(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, from: []const Oid, remote_refs: []const protocol.RemoteRef) Error![]const Oid {
    const db = repo.objectDatabase();
    var cutoff: ?i64 = null;
    for (remote_refs) |ref| {
        if (!try db.exists(io, ref.oid)) continue;
        if ((try db.readHeader(io, ref.oid)).type != .commit) continue;
        const when = (try readCommit(arena, gpa, io, db, ref.oid)).time;
        if (cutoff == null or cutoff.? < when) cutoff = when;
    }
    const Item = struct {
        time: i64,
        order: u64,
        oid: Oid,
        fn newerFirst(_: void, a: @This(), b: @This()) std.math.Order {
            if (a.time != b.time) return std.math.order(b.time, a.time);
            return std.math.order(a.order, b.order);
        }
    };
    var queue: std.PriorityQueue(Item, void, Item.newerFirst) = .empty;
    defer queue.deinit(gpa);
    var complete: Oid.Map([]const Oid) = .empty;
    defer complete.deinit(gpa);
    var order: u64 = 0;
    for (from) |tip| {
        const oid = commitOf(io, repo, tip) orelse continue;
        if (complete.contains(oid)) continue;
        const c = try readCommit(arena, gpa, io, db, oid);
        try complete.put(gpa, oid, c.parents);
        try queue.push(gpa, .{ .time = c.time, .order = order, .oid = oid });
        order += 1;
    }
    // `mark_recent_complete_commits`: the most recent first, to the cutoff.
    if (cutoff) |cut| if (cut != 0) while (queue.peek()) |item| {
        if (item.time < cut) break;
        _ = queue.pop();
        for (complete.get(item.oid).?) |parent| {
            if (complete.contains(parent) or !try db.exists(io, parent)) continue;
            const c = try readCommit(arena, gpa, io, db, parent);
            try complete.put(gpa, parent, c.parents);
            try queue.push(gpa, .{ .time = c.time, .order = order, .oid = parent });
            order += 1;
        }
    };
    var common: std.ArrayList(Oid) = .empty;
    for (remote_refs) |ref| {
        const oid = commitOf(io, repo, ref.oid) orelse continue;
        if (complete.contains(oid)) try common.append(arena, oid);
    }
    return common.items;
}

/// A commit's date and parents (as the shallow boundary and grafts give
/// them), the parents `arena`'s.
fn readCommit(arena: Allocator, gpa: Allocator, io: Io, db: *odb_mod.Odb, oid: Oid) Error!struct { time: i64, parents: []const Oid } {
    const found = try db.read(io, oid);
    defer db.allocator().free(found.bytes);
    var commit = try object.Commit.parse(gpa, db.objectFormat(), found.bytes);
    defer commit.deinit();
    return .{ .time = commit.committer.when_secs, .parents = try arena.dupe(Oid, rev_walk.parentsOf(db, oid, commit.parents)) };
}

/// How a fetched pack is received: checked by `checks`, its missing
/// objects promised when `promisor`, its links kept in `links` when set.
fn receiveOptions(repo: *Repository, checks: ?*const fsck.Rules, promisor: bool, warnings: ?*warning.Warnings, links: ?*index_pack.Links) index_pack.Options {
    return .{
        .keep = true,
        .fsck = checks,
        .promised = promisor,
        .warnings = warnings,
        .reverse_index = rev_index.wanted(repo.configuration()),
        .links = links,
        .threads = index_pack.configuredThreads(repo.configuration()),
    };
}

/// Take the values a remote helper's import learned for `entries`.
fn takeFetchedValues(session: *const transport.Session, entries: []MapEntry) void {
    for (entries) |*entry| if (session.fetchedValue(entry.name)) |oid| {
        entry.oid = oid;
    };
}

/// What `checkConnected` walks.
const Received = struct {
    pack_dir: Io.Dir,
    /// The pack that came, if one did.
    pack: ?Oid,
    links: *const index_pack.Links,
    /// The map, then the tags fetched after it.
    passes: [2][]MapEntry,
    /// A shallow remote's roots this fetch did not ask for.
    remote_roots: []const Oid,
    /// The boundary before the fetch.
    old_boundary: *const Oid.Set,
    promisor: bool,
    update_shallow: bool,
    missing: ?*Oid,
};

/// Everything below the fetched refs is here: what came in the pack is
/// walked into, what was here before is taken to be whole. A shallow
/// remote's roots are taken, as `update_shallow` says, only where a ref
/// needs them; a ref that needs one not taken is marked rejected.
fn checkConnected(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, r: Received) Error!void {
    var all_tips: std.ArrayList(Oid) = .empty;
    for (r.passes) |entries| for (entries) |entry| try all_tips.append(arena, entry.oid);
    var fresh: ?pack.Index = null;
    defer if (fresh) |*index| index.deinit();
    if (r.pack) |name| {
        var hex: [hash.max_hex_len]u8 = undefined;
        var idx_buf: [96]u8 = undefined;
        const idx_name = std.mem.print(&idx_buf, "pack-{s}.idx", .{name.hex(&hex)}) catch unreachable; // unreachable: the longest hex name is 64 digits, 73 bytes with the words around it
        fresh = try pack.Index.open(gpa, io, r.pack_dir, idx_name, .{ .kind = repo.objectFormat(), .max_bytes = 1 << 30 });
    }
    if (fresh) |*index| {
        object_walk.checkReceived(gpa, io, repo.objectDatabase(), all_tips.items, .{ .fresh = index, .links = r.links, .missing_out = r.missing, .promisor = r.promisor }) catch |err| switch (err) {
            error.MissingObject => return error.MissingObject,
            else => |e| return e,
        };
    } else {
        // No pack came: every tip was here already, and what was here is
        // whole below it. Only that each is here is checked, where git's
        // `--not --all` walk has nothing to walk.
        for (all_tips.items) |tip| {
            if (try repo.objectDatabase().exists(io, tip)) continue;
            if (r.missing) |out| out.* = tip;
            return error.MissingObject;
        }
    }
    if (r.remote_roots.len == 0) return;
    // Which refs need which of the remote's roots: git's
    // `assign_shallow_commits_to_refs`, walking what came in the
    // pack — what was here before is whole below it.
    var needed: Oid.Set = .empty;
    var roots: Oid.Set = .empty;
    for (r.remote_roots) |oid| {
        const arrived = if (fresh) |*index| (try index.find(oid)) != null else false;
        if (arrived) try roots.put(arena, oid, {});
    }
    for (r.passes) |entries| for (entries) |*entry| {
        const reached = try rootsReached(arena, io, repo, entry.oid, &roots, if (fresh) |*index| index else null, r.old_boundary);
        if (reached.len == 0) continue;
        if (r.update_shallow) {
            for (reached) |root| try needed.put(arena, root, {});
        } else entry.rejected_shallow = true;
    };
    repo.objectDatabase().shallow.deinit(gpa);
    repo.objectDatabase().shallow = try r.old_boundary.clone(gpa);
    var it = needed.keyIterator();
    while (it.next()) |root| try repo.objectDatabase().shallow.put(gpa, root.*, {});
}

/// The lines of `FETCH_HEAD`, the updates reported, and the ref writes,
/// all in `arena`.
const Plan = struct { fetch_head: []const HeadEntry, updates: []const Update, pending: []const Pending };

/// git's `store_updated_refs`: each pass's refs, those for merging first,
/// into `FETCH_HEAD` and the refs they are kept in, each decided by
/// `update_local_ref`'s rules.
fn planUpdates(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    passes: [2][]MapEntry,
    display_url: []const u8,
    rla: []const u8,
    options: Options,
    local: *const LocalIndex,
) Error!Plan {
    var fetch_head: std.ArrayList(HeadEntry) = .empty;
    var updates: std.ArrayList(Update) = .empty;
    var pending: std.ArrayList(Pending) = .empty;
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
                // `fetchMap` keeps only destinations under `refs/` with a
                // well-formed name.
                assert(validLocal(dst));
                const decision = try decide(gpa, io, repo, entry.*, dst, options.force, local);
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
                    .message = try arena.print("{s}: {s}", .{ rla, message }),
                });
            }
        }
    }
    return .{ .fetch_head = fetch_head.items, .updates = updates.items, .pending = pending.items };
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
fn writeRefs(io: Io, repo: *Repository, pending: []const Pending, options: Options, updates: []const Update) Error!void {
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
    // One transaction, each ref's log line in its own words.
    for (pending) |p| try tx.change(p.name, .{ .direct = p.new }, expectation(p.old), .{ .message = p.message });
    try tx.commit(io, .{ .who = options.who, .policy = repo.reflogPolicy() });
}

fn expectation(old: ?Oid) refs_mod.Expected {
    return if (old) |oid| .{ .matches = oid } else .must_not_exist;
}

/// Whether `remote.<name>.followRemoteHEAD` asks for `refs/remotes/<name>/HEAD`
/// to be created when it is missing, which is its default.
fn followRemoteHead(config: *const config_mod.Config, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const key = std.mem.print(&buf, "remote.{s}.followremotehead", .{name}) catch return false;
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
        const star = std.mem.find(u8, rule, "{s}").?;
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
        const star = std.mem.find(u8, rule, "{s}").?;
        try prefixes.append(arena, try std.mem.concat(arena, u8, &.{ rule[0..star], name, rule[star + 3 ..] }));
    }
}

/// git's `refspec_ref_prefixes` for one refspec.
fn addPrefixes(arena: Allocator, prefixes: *std.ArrayList([]const u8), spec: Refspec) Allocator.Error!void {
    if (spec.exact_oid or spec.negative) return;
    const src = if (spec.src.len == 0) "HEAD" else spec.src;
    if (spec.pattern) {
        const star = std.mem.findScalar(u8, src, '*').?;
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
            if (std.mem.findScalar(u8, ref.name, '^') != null) continue;
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
    return std.mem.startsWith(u8, name, "refs/") and ref_names.checkFormat(name, .{});
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
        var reachable = try repo.objectDatabase().exists(io, ref.oid);
        if (!reachable) {
            if (ref.peeled) |peeled| reachable = try repo.objectDatabase().exists(io, peeled);
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
        index.* = undefined;
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
        const found = repo.objectDatabase().read(io, oid) catch continue;
        defer repo.objectDatabase().allocator().free(found.bytes);
        if (found.type != .commit) continue;
        var commit = try object.Commit.parse(arena, repo.objectFormat(), found.bytes);
        defer commit.deinit();
        for (commit.parents) |p| try stack.append(arena, p);
    }
    return out.items;
}

/// What the options ask of the boundary, as the protocol asks it.
fn deepenRequest(repo: *Repository, options: Options) Error!?fetch_pack.Deepen {
    if (options.unshallow) {
        if (repo.objectDatabase().shallow.count() == 0) return error.NotShallow;
        return .{ .depth = 0x7fff_ffff };
    }
    if (options.depth == null and options.deepen == null and options.shallow_since == null and options.shallow_exclude.len == 0) return null;
    return .{
        .depth = options.depth orelse options.deepen,
        .relative = options.deepen != null,
        .since = if (options.shallow_since) |t| t.toSeconds() else null,
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

/// The objects a fetch asks for, and the ref each was advertised as.
const Wants = struct { oids: []const Oid, names: []const []const u8 };

/// The objects to ask for, as git's fetch-pack asks: each advertised ref
/// the map fetches, in the order the server advertised them, whose object
/// is not here — one line per ref, so two refs at one commit ask twice.
fn wantsInOrder(arena: Allocator, io: Io, repo: *Repository, advertised: []const protocol.RemoteRef, entries: []const MapEntry, all: bool) Error!Wants {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (entries) |entry| try names.put(arena, entry.name, {});
    var wants: std.ArrayList(Oid) = .empty;
    var want_names: std.ArrayList([]const u8) = .empty;
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    for (advertised) |ref| {
        if (ref.unborn or !names.contains(ref.name)) continue;
        if ((try listed.getOrPut(arena, ref.name)).found_existing) continue;
        if (!all and try repo.objectDatabase().exists(io, ref.oid)) continue;
        try wants.append(arena, ref.oid);
        try want_names.append(arena, ref.name);
    }
    // A name no ref advertised — an object named on the command line — is
    // asked for after them.
    for (entries) |entry| {
        if (listed.contains(entry.name)) continue;
        if ((try listed.getOrPut(arena, entry.name)).found_existing) continue;
        if (!all and try repo.objectDatabase().exists(io, entry.oid)) continue;
        try wants.append(arena, entry.oid);
        try want_names.append(arena, entry.name);
    }
    assert(wants.items.len == want_names.items.len);
    return .{ .oids = wants.items, .names = want_names.items };
}

/// The branches every working tree has checked out, as full ref names.
/// The names are `arena`'s.
fn checkedOutBranches(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // The main working tree's `HEAD`, whichever worktree this repository
    // was opened from.
    if (!repo.isBare() or repo.isLinkedWorktree()) {
        const bare = repo.configuration().getBool("core.bare", false) catch false;
        if (!bare) {
            if (try repo.refStore().read(gpa, io, "main-worktree/HEAD")) |head| switch (head) {
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
        try out.append(arena, try arena.print("refs/heads/{s}", .{branch}));
    }
    return out.items;
}

fn isCommitish(io: Io, repo: *Repository, oid: Oid) Error!bool {
    if (!try repo.objectDatabase().exists(io, oid)) return false;
    const peeled = repo.peel(io, oid) catch return false;
    const header = try repo.objectDatabase().readHeader(io, peeled);
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
        } else if (try repo.refStore().resolve(gpa, io, dst)) |resolved| {
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
    if (try rev_walk.isAncestor(gpa, io, repo.objectDatabase(), .{ .ancestor = old_commit.?, .descendant = new_commit.? }, .{})) {
        return .{ .old = old, .result = .fast_forward, .message = "fast-forward" };
    }
    if (force or entry.force) return .{ .old = old, .result = .forced, .message = "forced-update" };
    return .{ .old = old, .result = .rejected_non_fast_forward, .message = null };
}

fn commitOf(io: Io, repo: *Repository, oid: Oid) ?Oid {
    const peeled = repo.peel(io, oid) catch return null;
    const header = repo.objectDatabase().readHeader(io, peeled) catch return null;
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

fn writeFetchHead(gpa: Allocator, io: Io, repo: *Repository, entries: []const HeadEntry, append: bool) Error!void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (entries) |entry| {
        text.writer.print("{f}\t{s}\t{s}\n", .{
            entry.oid,
            if (entry.for_merge) "" else "not-for-merge",
            entry.description,
        }) catch return error.OutOfMemory;
    }
    const fetch_head = repo.refStore().special();
    if (append) return fetch_head.append(gpa, io, .fetch_head, text.written());
    try fetch_head.write(gpa, io, .fetch_head, text.written());
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
    const local_head = std.mem.print(&head_buf, "refs/remotes/{s}/HEAD", .{name}) catch return;
    if (try repo.refStore().read(gpa, io, local_head)) |existing| {
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
    const local_target = std.mem.print(&local_target_buf, "refs/remotes/{s}/{s}", .{ name, remote_target["refs/heads/".len..] }) catch return;
    // Only where the configured refspecs keep that branch.
    var kept = false;
    for (specs) |spec| {
        const mapped = (try spec.mapSource(gpa, remote_target)) orelse continue;
        defer gpa.free(mapped);
        if (std.mem.eql(u8, mapped, local_target)) kept = true;
    }
    if (!kept) return;
    if (try repo.refStore().resolve(gpa, io, local_target)) |resolved| {
        gpa.free(resolved.name);
    } else return;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(local_head, .{ .symbolic = local_target }, .must_not_exist);
    try tx.commit(io, .{ .who = who, .message = "fetch", .policy = repo.reflogPolicy() });
}

const testing = std.testing;
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");

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
        t.* = undefined;
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
        const name = line[0..std.mem.findScalar(u8, line, ' ').?];
        const log_path = try gpa.print(".git/logs/{s}", .{name});
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
                // One log is longer: the two shown whole are the failure.
                try testing.expectEqualStrings(log_a, log_b);
                return error.TestUnexpectedResult;
            }
            try testing.expectEqualStrings(ea.?[0..81], eb.?[0..81]);
            const tab_a = std.mem.findScalar(u8, ea.?, '\t') orelse ea.?.len;
            const tab_b = std.mem.findScalar(u8, eb.?, '\t') orelse eb.?.len;
            try testing.expectEqualStrings(ea.?[tab_a..], eb.?[tab_b..]);
        }
    }
}

test "a fetch from a local repository leaves what git fetch leaves: refs, logs and FETCH_HEAD" {
    const gpa = testing.allocator;
    const io = testing.io;
    // git fetch sets refs/remotes/<remote>/HEAD, when it is missing, from 2.48 on.
    try testgit.requireGitVersion(gpa, io, 2, 48);
    var twins = try Twins.init(gpa, io, 4);
    defer twins.deinit(gpa);

    var first = try twins.fetchBoth(gpa, io, &.{"origin"}, .{ .who = test_who });
    defer first.deinit();
    try testing.expect(first.objects > 0);

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
    try testing.expectEqual(@as(u32, 0), third.objects);
}

test "named refspecs, pruning and every tag are what git makes of them" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Which fetches set refs/remotes/<remote>/HEAD is git 2.50's: 2.48 and
    // 2.49 set it on a fetch this one does not.
    try testgit.requireGitVersion(gpa, io, 2, 50);
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
    // git fetch sets refs/remotes/<remote>/HEAD, when it is missing, from 2.48 on.
    try testgit.requireGitVersion(gpa, io, 2, 48);
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

test "fetch.fsckObjects and fetch.fsck.* refuse and allow what they do for git fetch" {
    const gpa = testing.allocator;
    const io = testing.io;
    // git fetch sets refs/remotes/<remote>/HEAD, when it is missing, from 2.48 on.
    try testgit.requireGitVersion(gpa, io, 2, 48);
    var twins = try Twins.init(gpa, io, 2);
    defer twins.deinit(gpa);
    // A url git's fsck refuses, which an older git would have handed to
    // a submodule clone as an option.
    try twins.source.writeFile(io, ".gitmodules", "[submodule \"a\"]\n\tpath = a\n\turl = -u/x\n");
    try twins.source.exec(io, &.{ "add", ".gitmodules" });
    try twins.source.exec(io, &.{ "commit", "-q", "-m", "modules" });
    for ([_]*testgit.Repo{ &twins.by_git, &twins.by_relic }) |twin| try twin.exec(io, &.{ "config", "fetch.fsckObjects", "true" });

    twins.by_git.report_failures = false;
    try testing.expectError(error.GitFailed, twins.by_git.exec(io, &.{ "fetch", "origin" }));
    {
        var repo = try Repository.open(gpa, io, twins.by_relic.dir, .{});
        defer repo.deinit(io);
        try testing.expectError(error.MalformedBlob, fetch(gpa, io, &repo, "origin", .{ .who = test_who }));
    }

    // Lowered to a warning, it comes in for both, and is said.
    for ([_]*testgit.Repo{ &twins.by_git, &twins.by_relic }) |twin| try twin.exec(io, &.{ "config", "fetch.fsck.gitmodulesUrl", "warn" });
    // (`git fsck` reads `fsck.*`, not `fetch.fsck.*`, so the twins are
    // compared by their refs alone.)
    try twins.by_git.exec(io, &.{ "fetch", "origin" });
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    {
        var repo = try Repository.open(gpa, io, twins.by_relic.dir, .{});
        defer repo.deinit(io);
        var outcome = try fetch(gpa, io, &repo, "origin", .{ .who = test_who, .warnings = &warnings });
        outcome.deinit();
    }
    try expectSameRefs(gpa, io, &twins.by_git, &twins.by_relic);
    var said = false;
    for (warnings.items.items) |w| switch (w) {
        .fsck => |f| said = said or std.mem.startsWith(u8, f.message, "gitmodulesUrl: disallowed submodule url: -u/x"),
        else => {},
    };
    try testing.expect(said);
}

test "unshallowing a whole repository and a filtered fetch are refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try Repository.create(gpa, io, tmp.dir, .{ .default_branch = "main" });
    defer repo.deinit(io);
    try testing.expectError(error.NotShallow, fetch(gpa, io, &repo, "origin", .{ .who = test_who, .unshallow = true }));
    try testing.expectError(error.NotAPromisorRemote, fetch(gpa, io, &repo, "origin", .{ .who = test_who, .filter = "blob:none" }));
}

test "a linked reftable fetch sees the main worktree branch through its backend" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGitVersion(gpa, io, 2, 45);
    var main = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer main.deinit();
    try main.exec(io, &.{ "commit", "--allow-empty", "-qm", "base" });
    var linked = testing.tmpDir(.{ .iterate = true });
    defer linked.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try linked.dir.realPath(io, &path_buf)];
    try main.exec(io, &.{ "worktree", "add", "-qb", "linked", path });
    var repo = try Repository.open(gpa, io, linked.dir, .{});
    defer repo.deinit(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const branches = try checkedOutBranches(arena.allocator(), gpa, io, &repo);
    var main_found = false;
    for (branches) |branch| main_found = main_found or std.mem.eql(u8, branch, "refs/heads/main");
    try testing.expect(main_found);
}

/// `maintenance`'s prefetch task (`maintenance_task_prefetch`): each
/// configured remote but those with `remote.<name>.skipDefaultUpdate`
/// fetched as `git fetch <remote> --prefetch --prune --no-tags
/// --no-write-fetch-head`, `template` giving the rest. The first failure
/// is returned once every remote is tried, as git's loop runs on.
pub fn prefetchAll(gpa: Allocator, io: Io, repo: *Repository, template: Options) Self.Error!void {
    const names = try remote_mod.names(gpa, repo.configuration());
    defer gpa.free(names);
    var first: ?Self.Error = null;
    for (names) |name| {
        var remote = try remote_mod.Remote.get(gpa, repo.configuration(), repo.objectFormat(), name);
        defer remote.deinit();
        if (remote.skip_default_update) continue;
        var options = template;
        options.refspecs = &.{};
        options.prefetch = true;
        options.prune = true;
        options.tags = .none;
        options.write_fetch_head = false;
        var outcome = fetch(gpa, io, repo, name, options) catch |err| {
            if (first == null) first = err;
            continue;
        };
        outcome.deinit();
    }
    if (first) |err| return err;
}

/// `prefetchAll` as `maintenance.run` asks for it: `maintenance()` is the
/// `maintenance.Prefetch` to hand it; a failure is kept in `failure`.
pub const Prefetcher = struct {
    gpa: Allocator,
    options: Options,
    failure: ?Self.Error = null,

    pub fn maintenance(p: *Prefetcher) maintenance_mod.Prefetch {
        return .{ .context = p, .fetch = run };
    }

    fn run(context: *anyopaque, io: Io, repo: *Repository) error{PrefetchFailed}!void {
        const p: *Prefetcher = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Prefetcher
        prefetchAll(p.gpa, io, repo, p.options) catch |err| {
            p.failure = err;
            return error.PrefetchFailed;
        };
    }
};
