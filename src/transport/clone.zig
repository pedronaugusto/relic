//! `git clone`: a new repository with a remote, the remote's refs and
//! objects, and its default branch checked out.
//!
//! The steps are git's. The remote is asked first, because its answer
//! says which hash the new repository's objects are named with and which
//! branch its `HEAD` points at. The repository is then created with both,
//! its remote written to the configuration — the URL as given, a path made
//! absolute — and every branch and every tag fetched as one pack, checked
//! to be connected before any ref is written. The remote-tracking refs and
//! the tags go into `packed-refs`, as git writes them, with no logs; the
//! local branch, `HEAD` and `refs/remotes/<origin>/HEAD` are written with
//! `clone: from <url>`, and the branch gets its `remote` and `merge`
//! settings. Last, the branch's tree is checked out, with the attributes
//! the tree itself carries deciding line endings and filters, and the
//! index written.
//!
//! A shallow clone — `depth`, `shallow_since`, `shallow_exclude` — fetches
//! one branch unless asked for all, as git's does, keeps the tags the pack
//! brought, and writes the boundary the server drew to `.git/shallow`. A
//! partial one is refused by name in this release.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;
const builtin = @import("builtin");

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const refs_mod = @import("../refs.zig");
const repo_mod = @import("../repo.zig");
const pack = @import("../odb/pack.zig");
const fetchpack = @import("fetchpack.zig");
const shallow_mod = @import("../revwalk/shallow.zig");
const indexpack = @import("../odb/indexpack.zig");
const revindex = @import("../odb/revindex.zig");
const partial = @import("partial.zig");
const worktree = @import("../worktree.zig");
const filter = @import("../worktree/filter.zig");
const url_mod = @import("url.zig");
const program = @import("../repo/program.zig");
const transport = @import("../transport.zig");
const objectwalk = @import("objectwalk.zig");
const protocol = @import("protocol.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const remote_mod = @import("remote.zig");
const warning = @import("../repo/warning.zig");
const clonelfs = @import("clone/lfs.zig");
const progress_mod = @import("progress.zig");
const config_mod = @import("../config.zig");
const fsck = @import("../object/fsck.zig");
const promisors = @import("promisors.zig");
const odb_mod = @import("../odb.zig");
const safepath = @import("../worktree/safepath.zig");
const config_state = @import("../config/state.zig");
const refspec = @import("refspec.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a clone.
pub const Error = error{
    /// The destination holds something already. git refuses to clone into
    /// a directory that is not empty.
    DestinationNotEmpty,
    /// `Options.branch` names neither a branch nor a tag the remote has.
    RemoteBranchNotFound,
    /// An object below a fetched ref did not arrive.
    MissingObject,
    /// A remote name git would refuse.
    InvalidRemoteName,
} || transport.Error || shallow_mod.Error || partial.FilterError || repo_mod.Error || refs_mod.TransactionError || objectwalk.Error ||
    worktree.Error || config_mod.Config.SetError || Io.Dir.RealPathFileAllocError || Io.Dir.Iterator.Error ||
    filter.Drivers.LoadError || fsck.LoadError;

/// How a clone runs.
pub const Options = struct {
    /// The remote's name in the new configuration: git's `--origin`.
    origin: []const u8 = "origin",
    /// The branch to check out, or a tag to check out detached, in place of
    /// the remote's `HEAD`: git's `--branch`.
    branch: ?[]const u8 = null,
    /// A repository with no working tree, whose branches are the remote's
    /// branches.
    bare: bool = false,
    /// Check the branch out.
    checkout: bool = true,
    /// Clone into `dir` as the git directory of a working tree that is
    /// somewhere else, and check nothing out: what `git clone --no-checkout
    /// --separate-git-dir <dir>` puts in `<dir>`, and what a submodule's
    /// `modules/<name>` holds. The caller connects the working tree.
    separate_git_dir: bool = false,
    /// Fetch the remote's tags, and let later fetches follow them.
    tags: bool = true,
    /// The branch `HEAD` names when the remote is empty and does not say
    /// which it would use.
    default_branch: []const u8 = "main",
    /// Who the reflog entries are written as, and when.
    who: object.Signature,
    /// `--depth`: the history cut to this many commits from each fetched
    /// tip, the boundary written to `.git/shallow`.
    depth: ?u32 = null,
    /// `--shallow-since`: the history cut at commits older than this, in
    /// seconds since the epoch.
    shallow_since: ?i64 = null,
    /// `--shallow-exclude`: the history cut where these refs of the
    /// remote's reach.
    shallow_exclude: []const []const u8 = &.{},
    /// `--single-branch`: fetch only the branch checked out (or the tag
    /// named by `branch`) and the tags pointing into it. `null` is git's
    /// default: on for a shallow clone, off otherwise.
    single_branch: ?bool = null,
    /// `--filter`: a partial clone, whose server leaves out what the filter
    /// names — `blob:none`, `blob:limit=<size>`, `tree:<depth>` — and is
    /// asked for it when it is read. The checkout's own files are fetched
    /// before it, in one request, with `programs`.
    filter: ?[]const u8 = null,
    /// The permission to run programs, which an ssh remote and a
    /// credential helper need.
    programs: ?program.Programs = null,
    /// Settings that beat the new repository's own, as `git -c` gives them:
    /// `core.sshCommand`, `http.extraHeader` and the like, which the clone
    /// reads before the repository exists. When it is `null`, the clone
    /// reads `user_config` for them.
    config: ?*const config_mod.Config = null,
    /// The caller's configuration beyond the new repository's: the
    /// system, XDG and global files and the environment's values, as
    /// `userconfig.Locations.sources` gives them; `local` and `worktree`
    /// are not read. git reads them all during a clone, so the fetch's
    /// settings — a credential helper, `core.sshCommand` — come from them when
    /// `config` is `null`, the checkout's filters do — `filter.lfs.*` from
    /// `~/.gitconfig` — and the repository returned is opened with them.
    user_config: config_mod.Sources = .{},
    /// The home directory, for `~/` in `user_config` and its
    /// `includeIf` conditions.
    home: ?[]const u8 = null,
    /// The proxy for an HTTP remote, over the one the configuration and
    /// the environment choose, as libgit2's proxy options set it.
    proxy: transport.Proxy = .auto,
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
    /// or `transfer.fsckObjects`, from the caller's configuration. Neither
    /// set, they are still checked, with git's levels and a path naming
    /// `.git` refused (`fsck.baseline`); `false` checks nothing.
    check_objects: ?bool = null,
    /// What the new repository's object database is opened with.
    odb: odb_mod.Options = .{},
};

fn hasUserConfig(options: Options) bool {
    const user = options.user_config;
    return user.system != null or user.xdg != null or user.global != null or user.command.len != 0 or user.pairs.len != 0;
}

fn rewriteUrl(arena: Allocator, settings: ?*const config_mod.Config, url: []const u8) Error!?[]const u8 {
    return if (settings) |c| remote_mod.rewrite(arena, c, url, .fetch) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedValue,
    } else null;
}

fn userConfiguration(gpa: Allocator, io: Io, options: Options) Error!?config_mod.Config {
    const user = options.user_config;
    const has_user_config = user.system != null or user.xdg != null or user.global != null or user.command.len != 0 or user.pairs.len != 0;
    var user_settings: ?config_mod.Config = null;
    if (options.config == null and has_user_config) {
        user_settings = try config_mod.Config.open(gpa, io, .{
            .system = user.system,
            .xdg = user.xdg,
            .global = user.global,
            .command = user.command,
            .pairs = user.pairs,
        }, .{ .home = options.home });
    }
    return user_settings;
}

/// Clone `url` into `dir`, which must be empty, and return the new
/// repository, open.
pub fn clone(gpa: Allocator, io: Io, url: []const u8, dir: Io.Dir, options: Options) Error!Repository {
    var deepen: ?fetchpack.Deepen = if (options.depth != null or options.shallow_since != null or options.shallow_exclude.len != 0)
        .{ .depth = options.depth, .since = options.shallow_since, .not = options.shallow_exclude }
    else
        null;
    const single_branch = options.single_branch orelse (deepen != null);
    if (!refspecNameOk(options.origin)) return error.InvalidRemoteName;
    {
        var it = dir.iterate();
        if (try it.next(io) != null) return error.DestinationNotEmpty;
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `auto` is recorded as it is, and sent as the filter of the promisor
    // remotes taken from the server's advertisement, as git's is.
    const auto_filter = if (options.filter) |spec| std.mem.eql(u8, spec, "auto") else false;
    const filter_spec: ?[]const u8 = if (options.filter) |spec| (if (auto_filter) "auto" else try partial.normalize(arena, spec)) else null;

    // Before the repository exists, the caller's own configuration is what
    // git reads.
    var user_settings = try userConfiguration(gpa, io, options);
    defer if (user_settings) |*c| c.deinit();
    const settings: ?*const config_mod.Config = options.config orelse if (user_settings) |*c| c else null;

    // What `url.<base>.insteadOf` makes of the URL is where the clone goes;
    // the URL as given is what the new configuration records, as git's
    // does.
    const reached = (try rewriteUrl(arena, settings, url)) orelse url;

    // A remote helper runs with the new repository's `GIT_DIR`, so the
    // repository is made first for one, as git makes it: with the default
    // hash, and `HEAD` moved once the helper says where.
    var repo: Repository = undefined;
    var repo_made = false;
    errdefer if (repo_made) repo.deinit(io);
    var send_filter = filter_spec;
    var target: Target = .{ .recorded = url };
    if (url_mod.helperOf(reached) != null) {
        repo = try initRepository(gpa, io, dir, options, null, options.default_branch);
        repo_made = true;
    } else {
        target = try localTarget(arena, io, url, reached, filter_spec != null, options);
        if (target.local_copy) {
            deepen = null;
            send_filter = null;
        }
    }

    var session = try openSession(gpa, io, reached, target.local_copy, settings, if (repo_made) &repo else null, options);
    defer session.close(io);

    var remote_refs = try session.listRefs(gpa, io, &.{ "HEAD", "refs/heads/", "refs/tags/" });
    defer remote_refs.deinit();
    const head = try chooseHead(arena, &remote_refs, options.branch);
    const initial = if (head.branch) |b|
        (if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else options.default_branch)
    else
        options.default_branch;

    if (repo_made) {
        try moveHelperHead(arena, io, &repo, session.objectFormat(), initial, options.default_branch);
    } else {
        repo = try initRepository(gpa, io, dir, options, session.objectFormat(), initial);
        repo_made = true;
    }
    try partial.storeAdvertised(io, &repo, session.promisorStores(), options.warnings);
    if (auto_filter and send_filter != null) {
        var empty: config_mod.Config = .initEmpty(gpa);
        defer empty.deinit();
        send_filter = try promisors.autoFilter(arena, settings orelse &empty, session.promisorsTaken());
    }

    // One branch, or one tag, when that is all that is fetched.
    const single_tag: ?[]const u8 = if (single_branch and head.branch == null and head.detached != null and options.branch != null)
        try std.fmt.allocPrint(arena, "refs/tags/{s}", .{options.branch.?})
    else
        null;
    try configureRemote(arena, &repo, target.recorded, filter_spec, single_branch, head.branch, single_tag, options);

    var chosen = try chooseRefs(arena, remote_refs.refs, head, single_branch, single_tag, options);
    const detached = try receiveObjects(arena, gpa, io, &repo, &session, &chosen, .{
        .settings = settings,
        .remote_refs = remote_refs.refs,
        .deepen = deepen,
        .filter = send_filter,
        .single_branch = single_branch,
        .single_tag = single_tag,
        .detached = head.detached,
    }, options);

    // The remote's refs, packed and with no logs, as git writes them.
    try writeRemoteRefs(io, &repo, chosen.packed_entries.items);

    const display = try url_mod.anonymize(arena, target.recorded);
    const message = try std.fmt.allocPrint(arena, "clone: from {s}", .{display});
    const log: refs_mod.LogMessage = .{ .who = options.who, .message = message, .policy = repo.reflogPolicy() };
    const head_commit = try pointHead(arena, io, &repo, &session, &remote_refs, head.branch, detached, log, options);
    // The remote's own `HEAD`, where it points at a branch, whatever was
    // checked out.
    if (!options.bare) if (remote_refs.find("HEAD")) |remote_head| {
        try followRemoteHead(arena, io, &repo, &remote_refs, remote_head, head.branch, single_branch, log, options.origin);
    };
    try config_state.writeLocal(repo._config, io);

    // The caller's configuration joins the repository's, as git reads
    // every level: the checkout's filters come from there.
    if (hasUserConfig(options) or options.home != null) {
        const reopened = try reopenWithUserConfig(gpa, io, dir, options);
        repo.deinit(io);
        repo = reopened;
    }

    if (!options.bare and !options.separate_git_dir and options.checkout) {
        if (head_commit) |commit| try checkOutCloned(arena, gpa, io, &repo, &session, commit, send_filter != null, options);
    }
    return repo;
}

/// A remote helper's repository, made before the helper said where
/// `HEAD` is: its hash must be the remote's, and `HEAD` is moved to
/// `initial`.
fn moveHelperHead(arena: Allocator, io: Io, repo: *Repository, remote_format: hash.Kind, initial: []const u8, default_branch: []const u8) Error!void {
    if (remote_format != repo.objectFormat()) return error.ObjectFormatMismatch;
    if (std.mem.eql(u8, initial, default_branch)) return;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update("HEAD", .{ .symbolic = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{initial}) }, .any);
    try tx.commit(io, null);
}

/// Write `entries`, sorted by name, as the packed refs.
fn writeRemoteRefs(io: Io, repo: *Repository, entries: []refs_mod.Store.PackedEntry) Error!void {
    std.mem.sort(refs_mod.Store.PackedEntry, entries, {}, struct {
        fn lessThan(_: void, a: refs_mod.Store.PackedEntry, b: refs_mod.Store.PackedEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    if (entries.len != 0) try repo.refStore().writePacked(io, entries);
}

/// What `receiveObjects` asks for, beside the chosen refs.
const Receiving = struct {
    settings: ?*const config_mod.Config,
    remote_refs: []const protocol.RemoteRef,
    deepen: ?fetchpack.Deepen,
    /// The filter sent, which makes the pack a promisor pack.
    filter: ?[]const u8,
    single_branch: bool,
    single_tag: ?[]const u8,
    detached: ?Oid,
};

/// Bring what `chosen` asks for into one new pack, take the values a
/// helper learned and the boundary the server drew, keep a single
/// branch's tags, and check that everything below the wants is here. The
/// commit `HEAD` is detached at, as the helper may have learned it.
fn receiveObjects(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    session: *transport.Session,
    chosen: *Chosen,
    ask: Receiving,
    options: Options,
) Error!?Oid {
    var detached = ask.detached;
    var pack_dir = try repo.common_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    var shallow_info: fetchpack.ShallowInfo = .{ .gpa = gpa };
    defer shallow_info.deinit();
    // What the pack's objects name, collected as it is indexed, so that
    // whether it is connected is asked without reading it again.
    var links: indexpack.Links = .init(gpa);
    defer links.deinit();
    var to_warnings: fsck.ToWarnings = .{ .warnings = options.warnings };
    var rules = try fsck.forTransfer(gpa, io, ask.settings, repo.objectFormat(), .fetch, options.check_objects, to_warnings.sink());
    defer if (rules) |*r| r.deinit(gpa);
    const fetched = try session.fetch(gpa, io, &repo.odb, pack_dir, .{
        .wants = chosen.wants.items,
        .want_names = chosen.want_names.items,
        .tips = &.{},
        .include_tag = options.tags,
        .deepen = ask.deepen,
        .filter = ask.filter,
    }, .{
        .progress = options.progress,
        .receive = .{ .fsck = if (rules) |*r| r else null, .promised = ask.filter != null, .warnings = options.warnings, .reverse_index = revindex.wanted(ask.settings), .links = &links, .threads = indexpack.configuredThreads(ask.settings) },
        .shallow_info = &shallow_info,
        .warnings = options.warnings,
    });
    // A remote helper's import learns the values as it goes.
    chosen.takeFetchedValues(session);
    if (detached) |oid| if (oid.isZero()) if (session.fetchedValue("HEAD")) |value| {
        detached = value;
    };
    // A partial clone's pack is a promisor pack, and says for which refs —
    // also when the server did not filter it, as git marks it.
    if (ask.filter != null) if (fetched.pack) |name| {
        try partial.writePromisor(io, pack_dir, name, try promisorRefs(arena, session, ask.remote_refs, chosen.wants.items));
    };
    if (ask.deepen == null) try shallow_info.shallow.appendSlice(gpa, session.advertisedShallow());
    if (shallow_info.shallow.items.len != 0) {
        var empty: Oid.Set = .empty;
        repo.odb.shallow.deinit(gpa);
        repo.odb.shallow = try shallow_mod.apply(gpa, &empty, shallow_info.shallow.items, shallow_info.unshallow.items);
        try shallow_mod.write(gpa, io, repo.common_dir, &repo.odb.shallow);
    }
    // A single branch's tags are those the pack brought, which is what
    // git's clone keeps of them.
    if (ask.single_branch and options.tags) try chosen.keepFetchedTags(arena, io, repo, ask.remote_refs, ask.single_tag);

    try checkCloned(gpa, io, repo, pack_dir, fetched.pack, chosen.wants.items, &links, ask.filter != null);
    return detached;
}

/// Where a clone that is not a remote helper's goes, and what it records.
const Target = struct {
    /// The URL the configuration records: as given, a path made absolute.
    recorded: []const u8,
    /// A path is a local clone, copied as it is.
    local_copy: bool = false,
};

/// What `url`, rewritten to `reached`, is: a path is a local clone, copied
/// as it is, where git ignores a depth and a filter, says so, and keeps
/// what they decided besides — one branch, the promisor settings.
/// `file://` goes through upload-pack. A path is recorded absolute, as git
/// records it (`absolutePathAsGit`).
fn localTarget(arena: Allocator, io: Io, url: []const u8, reached: []const u8, filtered: bool, options: Options) Error!Target {
    const parsed = try url_mod.Url.parse(reached);
    var target: Target = .{ .recorded = url };
    target.local_copy = parsed.scheme == .local and !try isShallowSource(io, parsed.path);
    if (target.local_copy) {
        if (options.depth != null) try warning.note(options.warnings, .{ .ignored_for_local = "--depth" });
        if (options.shallow_since != null) try warning.note(options.warnings, .{ .ignored_for_local = "--shallow-since" });
        if (options.shallow_exclude.len != 0) try warning.note(options.warnings, .{ .ignored_for_local = "--shallow-exclude" });
        if (filtered) try warning.note(options.warnings, .{ .ignored_for_local = "--filter" });
    }
    if (reached.ptr == url.ptr and parsed.scheme == .local) target.recorded = try absolutePathAsGit(arena, io, url);
    return target;
}

/// The session a clone from `reached` talks over.
fn openSession(
    gpa: Allocator,
    io: Io,
    reached: []const u8,
    local_copy: bool,
    settings: ?*const config_mod.Config,
    repo: ?*Repository,
    options: Options,
) Error!transport.Session {
    const session = try transport.Session.open(gpa, io, reached, .upload_pack, null, .{
        .local_copy = local_copy,
        .programs = options.programs,
        .config = settings,
        .remote_name = options.origin,
        .proxy = options.proxy,
        .progress = options.progress,
        .prompt = options.prompt,
        .auth_failure = options.auth_failure,
        .warnings = options.warnings,
        // A credential's expiry is checked against the caller's time.
        .now = options.who.when_secs,
        .repository = repo,
        .who = options.who,
        .cloning = true,
    });
    return session;
}

/// Which branch `HEAD` will name, or the commit it is detached at.
const Head = struct { branch: ?[]const u8 = null, detached: ?Oid = null };

/// The branch or tag `branch` names, else what the remote's `HEAD` is.
fn chooseHead(arena: Allocator, remote_refs: *const protocol.RefList, branch: ?[]const u8) Error!Head {
    if (branch) |name| {
        const branch_ref = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{name});
        const tag_ref = try std.fmt.allocPrint(arena, "refs/tags/{s}", .{name});
        if (remote_refs.find(branch_ref) != null) return .{ .branch = branch_ref };
        if (remote_refs.find(tag_ref)) |tag| return .{ .detached = tag.peeled orelse tag.oid };
        return error.RemoteBranchNotFound;
    }
    const head = remote_refs.find("HEAD") orelse return .{};
    if (head.symref_target) |target| return .{ .branch = try arena.dupe(u8, target) };
    if (!head.unborn) return .{ .detached = head.oid };
    return .{};
}

/// The remote, in the new configuration: its URL, its tags, the refspec
/// for what is fetched, and a partial clone's promisor settings.
fn configureRemote(
    arena: Allocator,
    repo: *Repository,
    recorded: []const u8,
    filter_spec: ?[]const u8,
    single_branch: bool,
    head_branch: ?[]const u8,
    single_tag: ?[]const u8,
    options: Options,
) Error!void {
    const origin = options.origin;
    try repo.editConfig(&.{.{ .set = .{ .name = try std.fmt.allocPrint(arena, "remote.{s}.url", .{origin}), .value = recorded } }}, null);
    if (!options.tags) try repo.editConfig(&.{.{ .set = .{ .name = try std.fmt.allocPrint(arena, "remote.{s}.tagopt", .{origin}), .value = "--no-tags" } }}, null);
    if (!options.bare) {
        const spec = if (single_branch and head_branch != null)
            try std.fmt.allocPrint(arena, "+{s}:refs/remotes/{s}/{s}", .{ head_branch.?, origin, head_branch.?["refs/heads/".len..] })
        else if (single_tag) |tag|
            try std.fmt.allocPrint(arena, "+{s}:{s}", .{ tag, tag })
        else
            try remote_mod.defaultFetchRefspec(arena, origin);
        try repo.editConfig(&.{.{ .set = .{ .name = try std.fmt.allocPrint(arena, "remote.{s}.fetch", .{origin}), .value = spec } }}, null);
    }
    if (filter_spec) |spec| {
        try repo.editConfig(&.{.{ .set = .{ .name = "core.repositoryformatversion", .value = "1" } }}, null);
        try repo.editConfig(&.{.{ .set = .{ .name = try std.fmt.allocPrint(arena, "remote.{s}.promisor", .{origin}), .value = "true" } }}, null);
        try repo.editConfig(&.{.{ .set = .{ .name = try std.fmt.allocPrint(arena, "remote.{s}.partialclonefilter", .{origin}), .value = spec } }}, null);
    }
}

/// What a clone asks for and the refs it writes, all in the arena.
const Chosen = struct {
    wants: std.ArrayList(Oid) = .empty,
    want_names: std.ArrayList([]const u8) = .empty,
    packed_entries: std.ArrayList(refs_mod.Store.PackedEntry) = .empty,
    /// The remote ref each packed entry is, for a value a helper learns.
    packed_sources: std.ArrayList([]const u8) = .empty,

    /// Take the values a remote helper's import learned.
    fn takeFetchedValues(c: *Chosen, session: *const transport.Session) void {
        assert(c.wants.items.len == c.want_names.items.len);
        assert(c.packed_entries.items.len == c.packed_sources.items.len);
        for (c.want_names.items, c.wants.items) |name, *oid| if (session.fetchedValue(name)) |value| {
            oid.* = value;
        };
        for (c.packed_sources.items, c.packed_entries.items) |name, *entry| if (session.fetchedValue(name)) |value| {
            entry.oid = value;
        };
    }

    /// Keep the remote's tags whose objects the pack brought.
    fn keepFetchedTags(c: *Chosen, arena: Allocator, io: Io, repo: *Repository, remote_refs: []const protocol.RemoteRef, single_tag: ?[]const u8) Error!void {
        for (remote_refs) |ref| {
            if (!std.mem.startsWith(u8, ref.name, "refs/tags/") or std.mem.endsWith(u8, ref.name, "^{}")) continue;
            if (single_tag != null and std.mem.eql(u8, ref.name, single_tag.?)) continue;
            if (!try repo.odb.exists(io, ref.oid)) continue;
            if (!safepath.isValidRefName(ref.name)) continue;
            try c.packed_entries.append(arena, .{ .name = try arena.dupe(u8, ref.name), .oid = ref.oid, .peeled = ref.peeled });
        }
    }
};

/// Every branch, and every tag unless asked not to; or, for a single
/// branch, that branch, with the tags pointing into it found after.
fn chooseRefs(arena: Allocator, remote_refs: []const protocol.RemoteRef, head: Head, single_branch: bool, single_tag: ?[]const u8, options: Options) Error!Chosen {
    var c: Chosen = .{};
    for (remote_refs) |ref| {
        if (ref.unborn) continue;
        const is_branch = std.mem.startsWith(u8, ref.name, "refs/heads/");
        const is_tag = std.mem.startsWith(u8, ref.name, "refs/tags/");
        if (!is_branch and !(is_tag and options.tags)) continue;
        if (std.mem.endsWith(u8, ref.name, "^{}")) continue;
        if (single_branch) {
            const chosen = if (head.branch) |b| std.mem.eql(u8, ref.name, b) else if (single_tag) |t| std.mem.eql(u8, ref.name, t) else false;
            if (!chosen) continue;
        }
        // One want per ref, as git's fetch-pack asks, two refs at one
        // commit asking twice.
        try c.wants.append(arena, ref.oid);
        try c.want_names.append(arena, ref.name);
        const local_name = if (is_branch and !options.bare)
            try std.fmt.allocPrint(arena, "refs/remotes/{s}/{s}", .{ options.origin, ref.name["refs/heads/".len..] })
        else
            try arena.dupe(u8, ref.name);
        if (!safepath.isValidRefName(local_name)) continue;
        try c.packed_entries.append(arena, .{ .name = local_name, .oid = ref.oid, .peeled = ref.peeled });
        try c.packed_sources.append(arena, ref.name);
    }
    if (head.detached) |oid| if (!containsOid(c.wants.items, oid)) {
        try c.wants.append(arena, oid);
        try c.want_names.append(arena, "HEAD");
    };
    return c;
}

/// The refs a partial clone's promisor pack names: `HEAD` and the branches
/// and tags at what was asked for, when the session names refs at all.
fn promisorRefs(arena: Allocator, session: *const transport.Session, remote_refs: []const protocol.RemoteRef, wants: []const Oid) Error![]const partial.PromisorRef {
    var sought: std.ArrayList(partial.PromisorRef) = .empty;
    if (!session.promisorNamesRefs()) return sought.items;
    for (remote_refs) |ref| {
        if (ref.unborn or std.mem.endsWith(u8, ref.name, "^{}")) continue;
        const listed = if (std.mem.eql(u8, ref.name, "HEAD"))
            true
        else for (wants) |want| {
            if (want.eql(ref.oid)) break (std.mem.startsWith(u8, ref.name, "refs/heads/") or std.mem.startsWith(u8, ref.name, "refs/tags/"));
        } else false;
        if (listed) try sought.append(arena, .{ .oid = ref.oid, .name = ref.name });
    }
    return sought.items;
}

/// Everything below what was asked for is here: what came in the pack is
/// walked into; with no pack, what is here is.
fn checkCloned(gpa: Allocator, io: Io, repo: *Repository, pack_dir: Io.Dir, pack_name: ?Oid, wants: []const Oid, links: *const indexpack.Links, promisor: bool) Error!void {
    var fresh: ?pack.Index = null;
    defer if (fresh) |*index| index.deinit();
    if (pack_name) |name| {
        var hex: [hash.max_hex_len]u8 = undefined;
        var idx_buf: [96]u8 = undefined;
        const idx_name = std.fmt.bufPrint(&idx_buf, "pack-{s}.idx", .{name.hex(&hex)}) catch unreachable; // unreachable: the longest hex name is 64 digits, 73 bytes with the words around it
        fresh = try pack.Index.open(gpa, io, pack_dir, idx_name, repo.objectFormat(), 1 << 30);
    }
    const connected = if (fresh) |*index|
        objectwalk.checkReceived(gpa, io, &repo.odb, wants, index, links, null, .{ .promisor = promisor })
    else
        objectwalk.checkConnectedWith(gpa, io, &repo.odb, wants, null, null, .{ .promisor = promisor });
    connected catch |err| switch (err) {
        error.MissingObject => return error.MissingObject,
        else => |e| return e,
    };
}

/// Point `HEAD` at the chosen branch, written with its upstream settings,
/// or detach it: the commit it names, if any.
fn pointHead(
    arena: Allocator,
    io: Io,
    repo: *Repository,
    session: *const transport.Session,
    remote_refs: *const protocol.RefList,
    head_branch: ?[]const u8,
    detached: ?Oid,
    log: refs_mod.LogMessage,
    options: Options,
) Error!?Oid {
    if (head_branch) |branch| {
        const ref = remote_refs.find(branch) orelse return detached;
        const value = session.fetchedValue(branch) orelse ref.oid;
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        if (!options.bare) try tx.update(branch, .{ .direct = value }, .any);
        try tx.update("HEAD", .{ .symbolic = branch }, .any);
        try tx.commit(io, log);
        if (!options.bare) {
            const short = branch["refs/heads/".len..];
            try repo.editConfig(&.{.{ .set = .{ .name = try std.fmt.allocPrint(arena, "branch.{s}.remote", .{short}), .value = options.origin } }}, null);
            try repo.editConfig(&.{.{ .set = .{ .name = try std.fmt.allocPrint(arena, "branch.{s}.merge", .{short}), .value = branch } }}, null);
        }
        return value;
    }
    if (detached) |oid| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.change("HEAD", .{ .direct = oid }, .any, .{ .no_deref = true });
        try tx.commit(io, log);
    }
    return detached;
}

/// `refs/remotes/<origin>/HEAD` at the branch the remote's `HEAD` names,
/// when that branch was fetched: a single branch's clone has only that
/// branch to point at.
fn followRemoteHead(
    arena: Allocator,
    io: Io,
    repo: *Repository,
    remote_refs: *const protocol.RefList,
    remote_head: protocol.RemoteRef,
    head_branch: ?[]const u8,
    single_branch: bool,
    log: refs_mod.LogMessage,
    origin: []const u8,
) Error!void {
    const target = remote_head.symref_target orelse return;
    const fetched_target = !single_branch or (head_branch != null and std.mem.eql(u8, target, head_branch.?));
    if (!std.mem.startsWith(u8, target, "refs/heads/") or remote_refs.find(target) == null or !fetched_target) return;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    const local_head = try std.fmt.allocPrint(arena, "refs/remotes/{s}/HEAD", .{origin});
    const local_target = try std.fmt.allocPrint(arena, "refs/remotes/{s}/{s}", .{ origin, target["refs/heads/".len..] });
    try tx.update(local_head, .{ .symbolic = local_target }, .must_not_exist);
    try tx.commit(io, log);
}

/// The new repository, opened again with every level of the caller's
/// configuration.
fn reopenWithUserConfig(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) Error!Repository {
    const reopened = try Repository.open(gpa, io, dir, .{
        .discover = false,
        .odb = options.odb,
        .system_config = options.user_config.system,
        .xdg_config = options.user_config.xdg,
        .global_config = options.user_config.global,
        .home = options.home,
        .config_overrides = options.user_config.command,
        .config_pairs = options.user_config.pairs,
    });
    return reopened;
}

/// Check out `commit`. A partial clone's checkout reads what the filter
/// left out: fetched first, in one request, as git does.
fn checkOutCloned(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, session: *const transport.Session, commit: Oid, partial_clone: bool, options: Options) Error!void {
    var taken: std.ArrayList([]const u8) = .empty;
    for (session.promisorsTaken()) |info| try taken.append(arena, info.name);
    var lazy: partial.Lazy = .init(gpa, repo, .{ .programs = options.programs, .prompt = options.prompt, .check_objects = options.check_objects, .accepted = taken.items });
    defer lazy.deinit();
    if (partial_clone) {
        lazy.install();
        lazy.prefetchTree(io, try repo.commitTree(io, repo.peel(io, commit) catch commit)) catch |err| return lazyFailed(err);
    }
    try checkOut(gpa, io, repo, commit, options);
}

/// Whether the repository at `path` is shallow, which git clones through
/// upload-pack even from a path.
fn isShallowSource(io: Io, path: []const u8) Io.Cancelable!bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer dir.close(io);
    for ([_][]const u8{ "shallow", ".git/shallow" }) |name| {
        if (dir.access(io, name, .{})) |_| return true else |_| {}
    }
    return false;
}

fn lazyFailed(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.PromisorFetchFailed,
    };
}

fn refspecNameOk(name: []const u8) bool {
    if (name.len == 0) return false;
    var buf: [512]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "refs/remotes/{s}/x", .{name}) catch return false;
    return refspec.checkRefFormat(probe, .{});
}

fn containsOid(list: []const Oid, oid: Oid) bool {
    for (list) |o| {
        if (o.eql(oid)) return true;
    }
    return false;
}

/// The new repository, as the clone makes it: `object_format` the
/// remote's, or the default when it is not known yet.
fn initRepository(gpa: Allocator, io: Io, dir: Io.Dir, options: Options, object_format: ?hash.Kind, initial: []const u8) Error!Repository {
    var repo = try Repository.init(gpa, io, dir, .{
        .object_format = object_format orelse .sha1,
        .default_branch = initial,
        .bare = options.bare or options.separate_git_dir,
        .odb = options.odb,
    });
    errdefer repo.deinit(io);
    // A git directory with its working tree elsewhere is not bare, and
    // logs its refs as `git init` sets a repository with a working tree to.
    if (options.separate_git_dir) {
        try repo.editConfig(&.{.{ .set = .{ .name = "core.bare", .value = "false" } }}, null);
        try repo.editConfig(&.{.{ .set = .{ .name = "core.logallrefupdates", .value = "true" } }}, null);
    }
    return repo;
}

/// Check out `commit`'s tree into the empty working tree and write the
/// index. The attributes the tree carries apply, as they do for git, and
/// its filters run with the caller's `programs`. When the configuration
/// names the `lfs` filter — `git lfs install` wrote it, here or in the
/// person's own files — an LFS object the checkout finds missing is fetched
/// from the remote's LFS server, as git-lfs's smudge fetches it, unless
/// `GIT_LFS_SKIP_SMUDGE` says to leave pointers. With no such filter the
/// pointers stay, as git without git-lfs leaves them.
fn checkOut(gpa: Allocator, io: Io, repo: *Repository, commit: Oid, options: Options) Error!void {
    const programs = options.programs;
    const tree = try repo.commitTree(io, repo.peel(io, commit) catch commit);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    const skip_smudge = if (programs) |p|
        (if (p.environ.get("GIT_LFS_SKIP_SMUDGE")) |v| config_mod.parseBool(v) catch false else false)
    else
        false;
    var drivers = try repo.loadFilters(io, .{ .lfs_skip_smudge = skip_smudge });
    defer drivers.deinit();
    var lfs_fetch: clonelfs.Fetcher = .{
        .gpa = gpa,
        .io = io,
        .repo = repo,
        .remote = options.origin,
        .options = .{ .programs = programs, .prompt = options.prompt, .auth_failure = options.auth_failure },
    };
    defer lfs_fetch.deinit();
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    rules.filters = &drivers;
    const required = try repo.requiredFilters(gpa);
    defer gpa.free(required);
    rules.required_filters = required;
    var index = try repo.openIndex(io);
    defer index.deinit();
    const lfs_configured = repo.configuration().get("filter.lfs.process") != null or repo.configuration().get("filter.lfs.smudge") != null;
    // A new clone's working tree has nothing in it to lose, as git's
    // clone takes it.
    _ = try worktree.checkout(gpa, io, repo.work_dir.?, &index, &repo.odb, tree, .{
        .rules = rules,
        .programs = programs,
        .lfs_fetch = if (lfs_configured) lfs_fetch.fetcher() else null,
        .force = true,
    });
    try repo.writeIndex(io, &index);
}

/// A local path as git's clone records it, through `absolute_pathdup`: an
/// absolute path as it was given, links and separators and all, and any
/// other after the working directory and a slash. git's working directory
/// on Windows is written with forward slashes.
fn absolutePathAsGit(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, cwd, '\\', '/');
    const sep: []const u8 = if (cwd.len != 0 and (cwd[cwd.len - 1] == '/' or cwd[cwd.len - 1] == '\\')) "" else "/";
    return std.mem.concat(arena, u8, &.{ cwd, sep, path });
}

const testing = std.testing;
const testgit = @import("../testing/git.zig");
const testremote = @import("../testing/remote.zig");

const test_who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

/// Run git in `dir` with no configuration but the suite's.
fn git(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir, args: []const []const u8) ![]u8 {
    return testremote.gitInputEnv(gpa, io, dir, env, args, "", true);
}

/// The same, where failing is an answer — a ref that is not there — and
/// its output is then empty.
fn gitOrEmpty(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir, args: []const []const u8) ![]u8 {
    return testremote.gitInputEnv(gpa, io, dir, env, args, "", false) catch |err| switch (err) {
        error.GitFailed => gpa.dupe(u8, ""),
        else => err,
    };
}

/// Two clones, one by git and one by relic, leave the same refs, the same
/// remote and branch settings, the same reflog messages, the same index
/// and a clean working tree.
fn expectSameClone(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, a: Io.Dir, b: Io.Dir, bare: bool) !void {
    const Query = struct { args: []const []const u8 };
    const queries = [_]Query{
        .{ .args = &.{ "for-each-ref", "--format=%(refname) %(objectname) %(symref)" } },
        .{ .args = &.{ "symbolic-ref", "-q", "HEAD" } },
        .{ .args = &.{ "config", "--local", "--get-regexp", "^(remote|branch)\\." } },
    };
    for (queries) |q| {
        const theirs = try gitOrEmpty(gpa, io, env, a, q.args);
        defer gpa.free(theirs);
        const ours = try gitOrEmpty(gpa, io, env, b, q.args);
        defer gpa.free(ours);
        try testing.expectEqualStrings(theirs, ours);
    }
    if (!bare) {
        for ([_][]const []const u8{ &.{ "ls-files", "-s" }, &.{ "status", "--porcelain" } }) |args| {
            const theirs = try git(gpa, io, env, a, args);
            defer gpa.free(theirs);
            const ours = try git(gpa, io, env, b, args);
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
        for ([_][]const u8{ "HEAD", "refs/heads/main", "refs/remotes/origin/HEAD" }) |name| {
            const theirs = try gitOrEmpty(gpa, io, env, a, &.{ "reflog", "show", "--format=%gs", name });
            defer gpa.free(theirs);
            const ours = try gitOrEmpty(gpa, io, env, b, &.{ "reflog", "show", "--format=%gs", name });
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
    }
    const checked = try git(gpa, io, env, b, &.{ "fsck", "--strict", "--no-dangling" });
    gpa.free(checked);
}

const Twin = struct {
    tmp: testing.TmpDir,
    path: []u8,
    dir: Io.Dir,

    fn init(gpa: Allocator, io: Io) !Twin {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "clone");
        const dir = try tmp.dir.openDir(io, "clone", .{ .iterate = true });
        const base = try testremote.absolutePath(gpa, io, tmp.dir);
        defer gpa.free(base);
        return .{ .tmp = tmp, .path = try std.fmt.allocPrint(gpa, "{s}/clone", .{base}), .dir = dir };
    }

    fn deinit(t: *Twin, gpa: Allocator, io: Io) void {
        t.dir.close(io);
        gpa.free(t.path);
        t.tmp.cleanup();
        t.* = undefined;
    }
};

test "a clone from a local repository is the clone git makes, checked out, bare, and by branch or tag" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var source = try testremote.historyRepo(gpa, io, 4);
    defer source.deinit();
    // Attributes the tree carries decide what is checked out.
    try source.writeFile(io, ".gitattributes", "*.crlf text eol=crlf\n");
    try source.writeFile(io, "docs/x.crlf", "one\ntwo\n");
    try source.exec(io, &.{ "add", "-A" });
    try source.exec(io, &.{ "commit", "-q", "-m", "attributes" });
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);

    const Case = struct { git_args: []const []const u8, options: Options };
    const cases = [_]Case{
        .{ .git_args = &.{}, .options = .{ .who = test_who } },
        .{ .git_args = &.{"--bare"}, .options = .{ .who = test_who, .bare = true } },
        .{ .git_args = &.{ "--branch", "side" }, .options = .{ .who = test_who, .branch = "side" } },
        .{ .git_args = &.{ "--branch", "old" }, .options = .{ .who = test_who, .branch = "old" } },
        .{ .git_args = &.{ "--origin", "upstream", "--no-tags" }, .options = .{ .who = test_who, .origin = "upstream", .tags = false } },
    };
    for (cases) |case| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "clone", "-q" });
        try argv.appendSlice(gpa, case.git_args);
        try argv.appendSlice(gpa, &.{ source_path, by_git.path });
        const out = try git(gpa, io, &env, by_git.tmp.dir, argv.items);
        gpa.free(out);

        var repo = try clone(gpa, io, source_path, by_relic.dir, case.options);
        repo.deinit(io);
        try expectSameClone(gpa, io, &env, by_git.dir, by_relic.dir, case.options.bare);
        if (!case.options.bare and case.options.branch == null) {
            const theirs = try by_git.dir.readFileAlloc(io, "docs/x.crlf", gpa, .unlimited);
            defer gpa.free(theirs);
            const ours = try by_relic.dir.readFileAlloc(io, "docs/x.crlf", gpa, .unlimited);
            defer gpa.free(ours);
            try testing.expectEqualStrings("one\r\ntwo\r\n", ours);
            try testing.expectEqualStrings(theirs, ours);
        }
    }
}

test "a local clone writes its pack on the tasks pack.threads asks for, as git's pack-objects does" {
    const gpa = testing.allocator;
    const Tasks = @import("../testing/io.zig");
    const io = testing.io;
    var single: Io.Threaded = .init_single_threaded;

    // One batch with enough objects for every requested task.
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    for (0..32) |i| {
        var name_buf: [32]u8 = undefined;
        var body_buf: [32]u8 = undefined;
        try source.writeFile(io, try std.fmt.bufPrint(&name_buf, "many/{d}.txt", .{i}), try std.fmt.bufPrint(&body_buf, "file {d}\n", .{i}));
    }
    try source.exec(io, &.{ "add", "-A" });
    try source.exec(io, &.{ "commit", "-q", "-m", "many" });
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);

    const PackFile = struct {
        fn only(g: Allocator, task_io: Io, dir: Io.Dir) ![]u8 {
            var found: ?[]u8 = null;
            errdefer if (found) |name| g.free(name);
            var it = dir.iterate();
            while (try it.next(task_io)) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
                if (found != null) return error.TestUnexpectedResult;
                found = try g.dupe(u8, entry.name);
            }
            return found orelse error.TestUnexpectedResult;
        }
    };
    var serial_target = try Twin.init(gpa, io);
    defer serial_target.deinit(gpa, io);
    var serial = try clone(gpa, Tasks.wrap(io), source_path, serial_target.dir, .{ .who = test_who, .checkout = false, .user_config = .{ .pairs = &.{.{ .name = "pack.threads", .value = "1" }} } });
    defer serial.deinit(io);
    try Tasks.expect(0, 0);
    var serial_packs = try serial.git_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer serial_packs.close(io);
    const serial_name = try PackFile.only(gpa, io, serial_packs);
    defer gpa.free(serial_name);
    const serial_bytes = try serial_packs.readFileAlloc(io, serial_name, gpa, .unlimited);
    defer gpa.free(serial_bytes);

    const Case = struct { pairs: []const config_mod.Sources.Pair, workers: usize };
    const cpus = std.Thread.getCpuCount() catch 1;
    // An unset count reaches the pack writer as zero: its CPU default.
    const objects = std.mem.readInt(u32, serial_bytes[8..12], .big);
    try testing.expect(objects <= odb_mod.search_group_objects);
    const default_workers = @min(cpus, objects);
    const cases = [_]Case{
        .{ .pairs = &.{}, .workers = default_workers },
        .{ .pairs = &.{.{ .name = "pack.threads", .value = "1" }}, .workers = 1 },
        .{ .pairs = &.{.{ .name = "pack.threads", .value = "4" }}, .workers = 4 },
    };
    for ([_]Io{ io, single.io() }) |each_io| {
        for (cases) |case| {
            var target = try Twin.init(gpa, io);
            defer target.deinit(gpa, io);
            var repo = try clone(gpa, Tasks.wrap(each_io), source_path, target.dir, .{ .who = test_who, .checkout = false, .user_config = .{ .pairs = case.pairs } });
            defer repo.deinit(io);
            // Headers and bodies on at most six tasks, one search group,
            // then deflation on all tasks, each including the caller.
            const readers: usize = @min(case.workers, 6);
            const spawned = if (case.workers == 1) 0 else 2 * (readers - 1) + case.workers - 1;
            try Tasks.expect(spawned, 0);
            var packs = try repo.git_dir.openDir(io, "objects/pack", .{ .iterate = true });
            defer packs.close(io);
            const name = try PackFile.only(gpa, io, packs);
            defer gpa.free(name);
            try testing.expectEqualStrings(serial_name, name);
            const bytes = try packs.readFileAlloc(io, name, gpa, .unlimited);
            defer gpa.free(bytes);
            try testing.expectEqualSlices(u8, serial_bytes, bytes);
        }
    }
}

test "a clone over ssh and over HTTP is the clone git makes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    {
        var source = try testremote.historyRepo(gpa, io, 3);
        defer source.deinit();
        const source_path = try testremote.absolutePath(gpa, io, source.dir);
        defer gpa.free(source_path);
        const root_path = try testremote.absolutePath(gpa, io, root.dir);
        defer gpa.free(root_path);
        const bare = try std.fmt.allocPrint(gpa, "{s}/repo.git", .{root_path});
        defer gpa.free(bare);
        try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
    }
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const http_url = try server.url(gpa, "repo.git");
    defer gpa.free(http_url);
    const fake = try testremote.fakeSsh(gpa, io, root.dir);
    defer gpa.free(fake);
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const ssh_path = try gpa.dupe(u8, root_path);
    defer gpa.free(ssh_path);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
    const ssh_url = try std.fmt.allocPrint(gpa, "ssh://example.invalid{s}{s}/repo.git", .{ if (builtin.os.tag == .windows) "/" else "", ssh_path });
    defer gpa.free(ssh_url);

    var settings_text: std.ArrayList(u8) = .empty;
    defer settings_text.deinit(gpa);
    try settings_text.print(gpa, "[core]\nsshCommand = {s}\n", .{fake});
    var settings = try config_mod.Config.parseText(gpa, settings_text.items, .command);
    defer settings.deinit();
    const ssh_setting = try std.fmt.allocPrint(gpa, "core.sshCommand={s}", .{fake});
    defer gpa.free(ssh_setting);

    for ([_][]const u8{ http_url, ssh_url }) |url| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);
        const out = try git(gpa, io, &env, by_git.tmp.dir, &.{ "-c", ssh_setting, "clone", "-q", url, by_git.path });
        gpa.free(out);
        var repo = try clone(gpa, io, url, by_relic.dir, .{
            .who = test_who,
            .programs = .{ .environ = &env },
            .config = &settings,
        });
        repo.deinit(io);
        try expectSameClone(gpa, io, &env, by_git.dir, by_relic.dir, false);
    }
}

test "an empty remote clones to an unborn branch, as git's does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var empty = try testgit.Repo.init(gpa, io, &.{ "--bare", "--initial-branch=trunk" });
    defer empty.deinit();
    const empty_path = try testremote.absolutePath(gpa, io, empty.dir);
    defer gpa.free(empty_path);
    var by_git = try Twin.init(gpa, io);
    defer by_git.deinit(gpa, io);
    var by_relic = try Twin.init(gpa, io);
    defer by_relic.deinit(gpa, io);
    const out = try git(gpa, io, &env, by_git.tmp.dir, &.{ "clone", "-q", empty_path, by_git.path });
    gpa.free(out);
    var repo = try clone(gpa, io, empty_path, by_relic.dir, .{ .who = test_who });
    repo.deinit(io);
    const theirs = try git(gpa, io, &env, by_git.dir, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(theirs);
    const ours = try git(gpa, io, &env, by_relic.dir, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(ours);
    try testing.expect(std.mem.startsWith(u8, ours, "refs/heads/trunk"));
    // git learns an empty remote's unborn branch from 2.31 on; an older
    // one names its own default.
    if (try testgit.gitAtLeast(gpa, io, 2, 31)) try testing.expectEqualStrings(theirs, ours);
}

test "a destination that is not empty and a filter git does not have are refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "occupied", .data = "x" });
    try testing.expectError(error.DestinationNotEmpty, clone(gpa, io, "/nowhere", tmp.dir, .{ .who = test_who }));
    var empty = testing.tmpDir(.{ .iterate = true });
    defer empty.cleanup();
    try testing.expectError(error.InvalidFilter, clone(gpa, io, "/nowhere", empty.dir, .{ .who = test_who, .filter = "blob:some" }));
}
