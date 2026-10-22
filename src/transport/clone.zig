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

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const gitdate = @import("../text.zig").date;
const httpsettings_mod = @import("../wire.zig").http_settings;
const io_mod = @import("../testing/io.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;
const builtin = @import("builtin");

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const pack = @import("../odb/pack.zig");
const fetch_pack = @import("../wire.zig").fetch_pack;
const shallow_mod = @import("../walk/shallow.zig");
const index_pack = @import("../odb/index_pack.zig");
const rev_index = @import("../odb/rev_index.zig");
const partial = @import("partial.zig");
const worktree = @import("../checkout/checkout.zig");
const filter = @import("../checkout/filter.zig");
const url_mod = @import("../wire.zig").url;
const program = @import("../process.zig").program;
const transport = @import("transport.zig");
const object_walk = @import("../walk/object/walk.zig");
const protocol = @import("../wire.zig").protocol;
const credential = @import("../wire.zig").credential;
const auth = @import("../wire.zig").auth;
const remote_mod = @import("../wire.zig").remote;
const warning = @import("../report.zig").warning;
const bundle = @import("bundle.zig");
const bundle_uri = @import("bundle/uri.zig");

const progress_mod = @import("../report.zig").progress;
const config_mod = @import("../config/config.zig");
const fsck = @import("../object/fsck.zig");
const promisors = @import("../wire.zig").promisors;
const odb_mod = @import("../odb/odb.zig");
const ref_names = @import("../names.zig").ref;
const fetch_mod = @import("fetch.zig");
const reference = @import("clone/reference.zig");
const alternate_refs = @import("alternate_refs.zig");
const submodule = @import("../submodule/submodule.zig");

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
    /// `bundle_uri` with `depth`, `shallow_since` or `shallow_exclude`,
    /// which git refuses together.
    BundleUriShallow,
    /// `filter_submodules` asked without `filter`, or without
    /// `recurse_submodules`: git's "the option '--also-filter-submodules'
    /// requires '--filter'" and "... requires '--recurse-submodules'".
    FilterSubmodulesAlone,
    /// `recurse_submodules` with both a `reference` and a `reference` that
    /// is `if_able`: git's "clone --recursive is not compatible with both
    /// --reference and --reference-if-able".
    MixedReferencesRecursive,
} || submodule.Error || fetch_mod.Error || partial.Error || reference.Error || alternate_refs.Error || transport.Error || shallow_mod.Error || partial.FilterError || repo_mod.Error || refs_mod.TransactionError || object_walk.Error ||
    worktree.Error || Repository.WriteConfigError || Io.Dir.RealPathFileAllocError || Io.Dir.Iterator.Error ||
    filter.Drivers.LoadError || fsck.LoadError;

/// Filter resources for a clone checkout. Drivers are released before the
/// optional operation resource, so fetch contexts remain alive throughout.
pub const Filters = struct {
    pub const Error = ErrorNamespace.Error;

    drivers: filter.Drivers,
    context: ?*anyopaque = null,
    release_fn: ?*const fn (Io, *anyopaque) void = null,
    pub fn deinit(f: *Filters, io: Io) void {
        f.drivers.deinit(io);
        if (f.release_fn) |release| release(io, f.context.?);
        f.* = undefined;
    }
};
pub const FilterOptions = struct {
    remote: []const u8,
    programs: ?program.Programs,
    prompt: ?credential.Prompt,
    auth_failure: ?*auth.Failure,
    skip_smudge: bool,
};
pub const FilterLoader = struct {
    context: ?*const anyopaque = null,
    load_fn: *const fn (Allocator, Io, ?*const anyopaque, *Repository, FilterOptions) Repository.LoadFiltersError!Filters,
};

/// A `--reference` or `--reference-if-able`: see `clone/reference.zig`.
pub const Reference = reference.Reference;

/// How a clone runs.
pub const Options = struct {
    /// `--reference` and `--reference-if-able`: repositories on this
    /// machine whose objects the new one borrows, named in its
    /// `objects/info/alternates`, so the remote sends only what they lack.
    reference: []const Reference = &.{},
    /// `--dissociate`: once the objects are in, what was borrowed is
    /// copied in and the lenders forgotten, as git's `repack -a -d` and the
    /// alternates file removed.
    dissociate: bool = false,
    /// `--recurse-submodules[=<pathspec>]`: `submodule.active` set to these
    /// pathspecs (none is `.`), and once the branch is checked out each
    /// active submodule cloned and checked out, and theirs, as git's
    /// `submodule update --init --recursive` after its clone, through a
    /// `SubmoduleTransport` made with this clone's settings. With
    /// `reference`, the submodules borrow from the lenders' own
    /// (`submodule.alternateLocation`). `null` leaves them be.
    recurse_submodules: ?[]const []const u8 = null,
    /// `--shallow-submodules`: each submodule cloned one commit deep.
    shallow_submodules: bool = false,
    /// `--[no-]also-filter-submodules`: the submodules cloned with `filter`
    /// too; `null` takes `clone.filterSubmodules`.
    filter_submodules: ?bool = null,
    /// Optional native filters supplied by the operation owner.
    native_filters: ?FilterLoader = null,
    /// The remote's name in the new configuration: git's `--origin`.
    /// `null` takes `clone.defaultRemoteName`, else `origin`.
    origin: ?[]const u8 = null,
    /// git's `--reject-shallow`: a remote whose own history is shallow is
    /// `error.ShallowSourceRefused`, unless the clone is a shallow one
    /// itself. `null` takes `clone.rejectShallow`.
    reject_shallow: ?bool = null,
    /// The branch to check out, or a tag to check out detached, in place of
    /// the remote's `HEAD`: git's `--branch`.
    branch: ?[]const u8 = null,
    /// A repository with no working tree, whose branches are the remote's
    /// branches.
    bare: bool = false,
    /// Where the new repository keeps its refs: git's `--ref-format`.
    /// `null` takes `init.defaultRefFormat` from `user_config`, as
    /// `Repository.CreateOptions.ref_format` does.
    ref_format: ?refs_mod.Format = null,
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
    /// which it would use. `null` takes `init.defaultBranch` from
    /// `user_config`, else git's `master`, as
    /// `Repository.CreateOptions.default_branch` does.
    default_branch: ?[]const u8 = null,
    /// Who the reflog entries are written as, and when.
    who: object.Signature,
    /// `--depth`: the history cut to this many commits from each fetched
    /// tip, the boundary written to `.git/shallow`.
    depth: ?u32 = null,
    /// `--bundle-uri`: a bundle or a bundle list whose objects are taken
    /// before the server is asked for the rest (`bundle_uri.zig`). One
    /// that fails is warned of and the clone goes on; a list under a
    /// heuristic is kept in `fetch.bundleURI` for the fetches after.
    bundle_uri: ?[]const u8 = null,
    /// `--shallow-since`: the history cut at commits older than this.
    shallow_since: ?Io.Timestamp = null,
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
    /// `user_config.Locations.sources` gives them; `local` and `worktree`
    /// are not read. git reads them all during a clone, so the fetch's
    /// settings — a credential helper, `core.sshCommand` — come from them when
    /// `config` is `null`, the checkout's filters do — `filter.lfs.*` from
    /// `~/.gitconfig` — and the repository returned is opened with them.
    user_config: config_mod.Sources = .{},
    /// The home directory, for `~/` in `user_config` and its
    /// `includeIf` conditions.
    home: ?[]const u8 = null,
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
    /// or `transfer.fsckObjects`, from the caller's configuration. Neither
    /// set, they are still checked, with git's levels and a path naming
    /// `.git` refused (`fsck.baseline`); `false` checks nothing.
    check_objects: ?bool = null,
    /// What the new repository's object database is opened with.
    odb: odb_mod.Options = .{},
    /// `--server-option`s, sent with every protocol v2 request; `null`
    /// takes `remote.<name>.serverOption`, as git does.
    server_options: ?[]const []const u8 = null,
    /// Whether the person named this remote themselves:
    /// `transport.Options.from_user`.
    /// A submodule's clone and fetch pass false, so a `.gitmodules` cannot
    /// reach a repository on this machine unless `protocol.file.allow` says
    /// it may.
    from_user: ?bool = null,
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

/// `asked` with what it leaves to the configuration taken from it:
/// `--origin` beats `clone.defaultRemoteName`, as git applies it after
/// reading the configuration, and `--[no-]reject-shallow` beats
/// `clone.rejectShallow`.
fn withSettings(settings: ?*const config_mod.Config, asked: Options) Error!Options {
    var options = asked;
    options.origin = asked.origin orelse try settingString(settings, "clone.defaultremotename") orelse "origin";
    options.reject_shallow = asked.reject_shallow orelse try settingBool(settings, "clone.rejectshallow");
    options.filter_submodules = asked.filter_submodules orelse try settingBool(settings, "clone.filtersubmodules");
    // Only what the caller asked for is refused: the setting is set and
    // forgotten, as git's.
    if (asked.filter_submodules == true and (asked.filter == null or asked.recurse_submodules == null)) return error.FilterSubmodulesAlone;
    return options;
}

/// What `--recurse-submodules` writes before the remote, as git writes
/// its `--config` values: `submodule.active`, `submodule.recurse` under
/// `submodule.stickyRecursiveClone`, and with lenders
/// `submodule.alternateLocation` and its error strategy.
fn configureSubmodules(arena: Allocator, io: Io, repo: *Repository, settings: ?*const config_mod.Config, options: Options) Error!void {
    const specs = options.recurse_submodules orelse return;
    var edits: std.ArrayList(Repository.ConfigEdit) = .empty;
    if (specs.len == 0) try edits.append(arena, .{ .add = .{ .name = "submodule.active", .value = "." } });
    for (specs) |spec| try edits.append(arena, .{ .add = .{ .name = "submodule.active", .value = spec } });
    if (try settingBool(settings, "submodule.stickyrecursiveclone")) try edits.append(arena, .{ .add = .{ .name = "submodule.recurse", .value = "true" } });
    var required = false;
    var if_able = false;
    for (options.reference) |r| {
        if (r.if_able) if_able = true else required = true;
    }
    if (required and if_able) return error.MixedReferencesRecursive;
    if (required or if_able) {
        try edits.append(arena, .{ .add = .{ .name = "submodule.alternateLocation", .value = "superproject" } });
        try edits.append(arena, .{ .add = .{ .name = "submodule.alternateErrorStrategy", .value = if (required) "die" else "info" } });
    }
    _ = try repo.writeConfig(io, .local, edits.items, .{});
}

/// git's `submodule update --require-init --recursive` after its clone:
/// each active submodule cloned as this clone was, one commit deep under
/// `shallow_submodules`, with the filter under `filter_submodules`, with
/// `ref_format` as given, and one branch or every one as this clone
/// decided for itself -- git hands its own `--[no-]single-branch` on, so a
/// shallow submodule of a whole clone still takes every branch.
fn updateSubmodules(gpa: Allocator, io: Io, repo: *Repository, settings: ?*const config_mod.Config, how: struct { filter: ?[]const u8, single_branch: bool }, options: Options) Error!void {
    var t: SubmoduleTransport = .init(.{
        .who = options.who,
        .programs = options.programs,
        .config = settings,
        .prompt = options.prompt,
        .progress = options.progress,
        .check_objects = options.check_objects,
        .warnings = options.warnings,
        .depth = if (options.shallow_submodules) 1 else null,
        .filter = if (options.filter_submodules.?) how.filter else null,
        .single_branch = how.single_branch,
        .ref_format = options.ref_format,
    });
    defer t.deinit();
    _ = submodule.update(gpa, io, repo, .{ .init = true, .recursive = true, .who = options.who, .transport = t.transport(), .programs = options.programs }) catch |err| switch (err) {
        error.TransportFailed => return t.failure orelse err,
        else => |e| return e,
    };
}

/// A `clone.*` string, which git refuses with no value.
fn settingString(settings: ?*const config_mod.Config, name: []const u8) Error!?[]const u8 {
    const config = settings orelse return null;
    const entry = config.find(name) orelse return null;
    return entry.value orelse error.MalformedValue;
}

fn settingBool(settings: ?*const config_mod.Config, name: []const u8) Error!bool {
    const config = settings orelse return false;
    return config.getBool(name, false) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedValue,
    };
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

/// Whether `dir` holds nothing. It is opened again to be read, so any handle
/// will do, the current directory's included.
fn isEmpty(io: Io, dir: Io.Dir) Self.Error!bool {
    var listed = try dir.openDir(io, ".", .{ .iterate = true });
    defer listed.close(io);
    var it = listed.iterate();
    return try it.next(io) == null;
}

/// Clone `url` into `dir`, which must be empty, and return the new
/// repository, open.
pub fn clone(gpa: Allocator, io: Io, url: []const u8, dir: Io.Dir, asked: Options) Self.Error!Repository {
    // Before the repository exists, the caller's own configuration is what
    // git reads.
    var user_settings = try userConfiguration(gpa, io, asked);
    defer if (user_settings) |*c| c.deinit();
    const settings: ?*const config_mod.Config = asked.config orelse if (user_settings) |*c| c else null;
    const options = try withSettings(settings, asked);

    if (options.bundle_uri != null and (options.depth != null or options.shallow_since != null or options.shallow_exclude.len != 0)) return error.BundleUriShallow;
    var deepen: ?fetch_pack.Deepen = if (options.depth != null or options.shallow_since != null or options.shallow_exclude.len != 0)
        .{ .depth = options.depth, .since = if (options.shallow_since) |t| t.toSeconds() else null, .not = options.shallow_exclude }
    else
        null;
    const single_branch = options.single_branch orelse (deepen != null);
    if (!refspecNameOk(options.origin.?)) return error.InvalidRemoteName;
    if (!try isEmpty(io, dir)) return error.DestinationNotEmpty;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `auto` is recorded as it is, and sent as the filter of the promisor
    // remotes taken from the server's advertisement, as git's is.
    const auto_filter = if (options.filter) |spec| std.mem.eql(u8, spec, "auto") else false;
    const filter_spec: ?[]const u8 = if (options.filter) |spec| (if (auto_filter) "auto" else try partial.normalize(arena, spec)) else null;

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
    defer session.deinit(io);

    var remote_refs = try session.listRefs(gpa, io, &.{ "HEAD", "refs/heads/", "refs/tags/" });
    defer remote_refs.deinit();
    const head = try chooseHead(arena, &remote_refs, options.branch);
    const initial = if (head.branch) |b|
        (if (std.mem.startsWith(u8, b, "refs/heads/")) b["refs/heads/".len..] else options.default_branch)
    else
        options.default_branch;

    if (repo_made) {
        try moveHelperHead(arena, gpa, io, &repo, session.objectFormat(), initial);
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
    const single_tag = try singleTagRef(arena, head, single_branch, options);
    try configureSubmodules(arena, io, &repo, settings, options);
    try configureRemote(arena, io, &repo, target.recorded, filter_spec, single_branch, head.branch, single_tag, options);
    try reference.borrow(arena, io, &repo, options.reference, options.warnings);

    const tips = try takeBundles(arena, gpa, io, &repo, &session, reached, settings, options);

    var chosen = try chooseRefs(arena, remote_refs.refs, head, single_branch, single_tag, options);
    var received = try receiveObjects(arena, gpa, io, &repo, &session, &chosen, .{
        .tips = tips,
        .settings = settings,
        .remote_refs = remote_refs.refs,
        .deepen = deepen,
        .filter = send_filter,
        .single_branch = single_branch,
        .single_tag = single_tag,
        .detached = head.detached,
    }, options);

    defer received.fetched.deinit(io);
    const head_commit = try recordRefs(arena, gpa, io, &repo, &session, .{
        .remote_refs = &remote_refs,
        .chosen = &chosen,
        .head = head,
        .detached = received.detached,
        .single_branch = single_branch,
        .recorded = target.recorded,
    }, options);
    if (options.dissociate) try reference.dissociate(gpa, io, &repo);
    // The caller's configuration joins the repository's, as git reads
    // every level: the checkout's filters come from there.
    if (hasUserConfig(options) or options.home != null) {
        const reopened = try reopenWithUserConfig(gpa, io, dir, options);
        repo.deinit(io);
        repo = reopened;
    }

    if (!options.bare and !options.separate_git_dir and options.checkout) if (head_commit) |commit| {
        try checkOutCloned(arena, gpa, io, &repo, &session, commit, send_filter != null, options);
        if (options.recurse_submodules != null) try updateSubmodules(gpa, io, &repo, settings, .{ .filter = filter_spec, .single_branch = single_branch }, options);
    };
    return repo;
}

/// What `recordRefs` writes the refs from.
const Recording = struct {
    remote_refs: *const protocol.RefList,
    chosen: *const Chosen,
    head: Head,
    detached: ?Oid,
    single_branch: bool,
    recorded: []const u8,
};

/// The remote's refs, in one step and with no logs, as git's initial
/// transaction writes them -- packed, or one table -- then `HEAD` and its
/// branch with `clone: from <url>`, and the remote's own `HEAD` where it
/// points at a branch, whatever was checked out. The commit to check out.
fn recordRefs(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, session: *const transport.Session, r: Recording, options: Options) Error!?Oid {
    try repo.refStore().writeInitial(gpa, io, r.chosen.first_refs.items);
    const display = try url_mod.anonymize(arena, r.recorded);
    const message = try arena.print("clone: from {s}", .{display});
    const log: refs_mod.LogMessage = .{ .who = options.who, .message = message, .policy = repo.reflogPolicy() };
    const head_commit = try pointHead(arena, io, repo, session, r.remote_refs, r.head.branch, r.detached, log, options);
    if (!options.bare) if (r.remote_refs.find("HEAD")) |remote_head| {
        try followRemoteHead(arena, io, repo, r.remote_refs, remote_head, r.head.branch, r.single_branch, log, options.origin.?);
    };
    return head_commit;
}

/// The tag a single-branch clone fetches when the branch asked for turned
/// out to be a tag.
fn singleTagRef(arena: Allocator, head: Head, single_branch: bool, options: Options) Allocator.Error!?[]const u8 {
    if (!single_branch or head.branch != null or head.detached == null) return null;
    const name = options.branch orelse return null;
    const tag: []const u8 = try arena.print("refs/tags/{s}", .{name});
    return tag;
}

/// A remote helper's repository, made before the helper said where
/// `HEAD` is: its hash must be the remote's, and `HEAD` is moved to
/// `initial` when that is a branch other than the one it was made on.
fn moveHelperHead(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, remote_format: hash.Kind, initial: ?[]const u8) Error!void {
    if (remote_format != repo.objectFormat()) return error.ObjectFormatMismatch;
    const branch = initial orelse return;
    const current = try repo.refStore().currentBranch(gpa, io);
    defer if (current) |name| gpa.free(name);
    if (current != null and std.mem.eql(u8, current.?, branch)) return;
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update("HEAD", .{ .symbolic = try arena.print("refs/heads/{s}", .{branch}) }, .any);
    try tx.commit(io, null);
}

/// What `receiveObjects` asks for, beside the chosen refs.
const Receiving = struct {
    settings: ?*const config_mod.Config,
    remote_refs: []const protocol.RemoteRef,
    deepen: ?fetch_pack.Deepen,
    /// The refs a bundle URI left, where the offer of haves starts.
    tips: []const Oid = &.{},
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
) Error!struct { detached: ?Oid, fetched: transport.Session.Fetched } {
    var detached = ask.detached;
    var pack_dir = try repo.objectDatabase().openPackDirectory(io);
    defer pack_dir.close(io);
    var shallow_info: fetch_pack.ShallowInfo = .{ .gpa = gpa, .reject = options.reject_shallow.? and ask.deepen == null };
    defer shallow_info.deinit();
    // What the pack's objects name, collected as it is indexed, so that
    // whether it is connected is asked without reading it again.
    var links: index_pack.Links = .init(gpa);
    defer links.deinit();
    var to_warnings: fsck.ToWarnings = .{ .warnings = options.warnings };
    var rules = try fsck.forTransfer(gpa, io, ask.settings, .{ .kind = repo.objectFormat(), .scope = .fetch, .base = repo.topDirectory() }, .{ .explicit = options.check_objects, .sink = to_warnings.sink() });
    defer if (rules) |*r| r.deinit(gpa);
    // What the lenders' refs name is offered too, as git's fetch-pack
    // offers an alternate's.
    var tips: std.ArrayList(Oid) = .empty;
    try tips.appendSlice(arena, ask.tips);
    const lent = try alternate_refs.read(gpa, io, repo, options.programs, options.warnings);
    defer gpa.free(lent);
    for (lent) |oid| if (try repo.objectDatabase().exists(io, oid)) try tips.append(arena, oid);
    // What a lender or a bundle holds already is not asked for, as git's
    // fetch-pack leaves out a want it has; with nothing left, nothing is.
    var wants: std.ArrayList(Oid) = .empty;
    var want_names: std.ArrayList([]const u8) = .empty;
    for (chosen.wants.items, chosen.want_names.items) |oid, name| {
        if (try repo.objectDatabase().exists(io, oid)) continue;
        try wants.append(arena, oid);
        try want_names.append(arena, name);
    }
    var fetched = try session.fetch(gpa, io, .{ .db = repo.objectDatabase(), .pack_dir = pack_dir, .request = .{
        .wants = wants.items,
        .want_names = want_names.items,
        .tips = tips.items,
        .include_tag = options.tags,
        .deepen = ask.deepen,
        .filter = ask.filter,
    } }, .{
        .progress = options.progress,
        .receive = .{ .keep = true, .fsck = if (rules) |*r| r else null, .promised = ask.filter != null, .warnings = options.warnings, .reverse_index = rev_index.wanted(ask.settings), .links = &links, .threads = index_pack.configuredThreads(ask.settings) },
        .shallow_info = &shallow_info,
        .warnings = options.warnings,
    });
    errdefer fetched.deinit(io);
    // A remote helper's import learns the values as it goes.
    chosen.takeFetchedValues(session);
    if (detached) |oid| if (oid.isZero()) if (session.fetchedValue("HEAD")) |value| {
        detached = value;
    };
    // A partial clone's pack is a promisor pack, and says for which refs —
    // also when the server did not filter it, as git marks it.
    if (ask.filter != null) if (fetched.pack) |name| {
        try partial.writePromisor(gpa, io, repo.objectDatabase(), name, try promisorRefs(arena, session, ask.remote_refs, chosen.wants.items));
    };
    if (ask.deepen == null) try shallow_info.shallow.appendSlice(gpa, session.advertisedShallow());
    if (shallow_info.shallow.items.len != 0) {
        var empty: Oid.Set = .empty;
        repo.objectDatabase().shallow.deinit(gpa);
        repo.objectDatabase().shallow = try shallow_mod.apply(gpa, &empty, shallow_info.shallow.items, shallow_info.unshallow.items);
        try repo.writeShallow(io);
    }
    // A single branch's tags are those the pack brought, which is what
    // git's clone keeps of them.
    if (ask.single_branch and options.tags) try chosen.keepFetchedTags(arena, io, repo, ask.remote_refs, ask.single_tag);

    try checkCloned(gpa, io, repo, pack_dir, fetched.pack, chosen.wants.items, &links, ask.filter != null);
    return .{ .detached = detached, .fetched = fetched };
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
    const shallow_source = parsed.scheme == .local and try isShallowSource(io, parsed.path);
    if (shallow_source and options.reject_shallow.?) return error.ShallowSourceRefused;
    target.local_copy = parsed.scheme == .local and !shallow_source;
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
    return transport.Session.open(gpa, io, reached, .{ .service = .upload_pack, .kind = null }, transferOptions(local_copy, settings, repo, options));
}

/// The transfer settings a clone reaches the remote, and a bundle URI, with.
fn transferOptions(local_copy: bool, settings: ?*const config_mod.Config, repo: ?*Repository, options: Options) transport.Options {
    return .{
        .local_copy = local_copy,
        .programs = options.programs,
        .config = settings,
        .remote_name = options.origin.?,
        .proxy = options.proxy,
        .progress = options.progress,
        .prompt = options.prompt,
        .auth_failure = options.auth_failure,
        .warnings = options.warnings,
        // A credential's expiry is checked against the caller's time.
        .now = gitdate.timestamp(options.who.when_secs),
        .repository = repo,
        .who = options.who,
        .cloning = true,
        .from_user = options.from_user,
        .server_options = options.server_options,
    };
}

/// git's clone takes a bundle URI's objects once it knows the object
/// format and before it fetches: `bundle_uri`'s, else under
/// `transfer.bundleURI` those of the list the server's `bundle-uri`
/// command gives, its relative URIs against the remote's URL. The refs
/// they leave under `refs/bundles/` are returned, the fetch's haves.
fn takeBundles(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    session: *transport.Session,
    reached: []const u8,
    settings: ?*const config_mod.Config,
    options: Options,
) Error![]const Oid {
    const fetching: bundle_uri.Options = .{ .transport = transferOptions(false, settings, repo, options), .who = options.who };
    if (options.bundle_uri) |uri| {
        const got = try bundle_uri.fetch(gpa, io, repo, uri, fetching);
        if (!got.ok) {
            try warning.note(options.warnings, .{ .bundle_uri_clone_failed = uri });
        } else if (got.heuristic) {
            _ = try repo.writeConfig(io, .local, &.{.{ .set = .{ .name = "fetch.bundleuri", .value = uri } }}, .{});
        }
        return bundle.repositoryTips(arena, io, repo);
    }
    const config = settings orelse return &.{};
    if (!try config.getBool("transfer.bundleuri", false)) return &.{};
    const lines = try session.bundleUri(arena) orelse {
        try warning.note(options.warnings, .{ .bundle_uri = "bundle-uri operation not supported by protocol" });
        return &.{};
    };
    var list: bundle_uri.List = .{ .arena = arena, .base_uri = reached, .warnings = options.warnings };
    for (lines, 2..) |line, number| list.parseLine(line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // git keeps what it read before the line, and says so.
        error.InvalidBundleList => {
            try warning.note(options.warnings, .{ .bundle_uri = try arena.print("error on bundle-uri response line {d}: {s}", .{ number, line }) });
            try warning.note(options.warnings, .{ .bundle_uri = "could not retrieve server-advertised bundle-uri list" });
            break;
        },
    };
    if (list.bundles.items.len == 0) return &.{};
    if (!try bundle_uri.fetchList(gpa, io, repo, &list, fetching)) try warning.note(options.warnings, .advertised_bundles_failed);
    return bundle.repositoryTips(arena, io, repo);
}

/// Which branch `HEAD` will name, or the commit it is detached at.
const Head = struct { branch: ?[]const u8 = null, detached: ?Oid = null };

/// The branch or tag `branch` names, else what the remote's `HEAD` is.
fn chooseHead(arena: Allocator, remote_refs: *const protocol.RefList, branch: ?[]const u8) Error!Head {
    if (branch) |name| {
        const branch_ref = try arena.print("refs/heads/{s}", .{name});
        const tag_ref = try arena.print("refs/tags/{s}", .{name});
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
    io: Io,
    repo: *Repository,
    recorded: []const u8,
    filter_spec: ?[]const u8,
    single_branch: bool,
    head_branch: ?[]const u8,
    single_tag: ?[]const u8,
    options: Options,
) Error!void {
    const origin = options.origin.?;
    var edits: std.ArrayList(Repository.ConfigEdit) = .empty;
    try edits.append(arena, .{ .set = .{ .name = try arena.print("remote.{s}.url", .{origin}), .value = recorded } });
    if (!options.tags) try edits.append(arena, .{ .set = .{ .name = try arena.print("remote.{s}.tagopt", .{origin}), .value = "--no-tags" } });
    if (!options.bare) {
        const spec = if (single_branch and head_branch != null)
            try arena.print("+{s}:refs/remotes/{s}/{s}", .{ head_branch.?, origin, head_branch.?["refs/heads/".len..] })
        else if (single_tag) |tag|
            try arena.print("+{s}:{s}", .{ tag, tag })
        else
            try remote_mod.defaultFetchRefspec(arena, origin);
        try edits.append(arena, .{ .set = .{ .name = try arena.print("remote.{s}.fetch", .{origin}), .value = spec } });
    }
    if (filter_spec) |spec| {
        try edits.append(arena, .{ .set = .{ .name = "core.repositoryformatversion", .value = "1" } });
        try edits.append(arena, .{ .set = .{ .name = try arena.print("remote.{s}.promisor", .{origin}), .value = "true" } });
        try edits.append(arena, .{ .set = .{ .name = try arena.print("remote.{s}.partialclonefilter", .{origin}), .value = spec } });
    }
    _ = try repo.writeConfig(io, .local, edits.items, .{});
}

/// What a clone asks for and the refs it writes, all in the arena.
const Chosen = struct {
    wants: std.ArrayList(Oid) = .empty,
    want_names: std.ArrayList([]const u8) = .empty,
    first_refs: std.ArrayList(refs_mod.Store.Initial) = .empty,
    /// The remote ref each of `first_refs` is, for a value a helper learns.
    first_sources: std.ArrayList([]const u8) = .empty,

    /// Take the values a remote helper's import learned.
    fn takeFetchedValues(c: *Chosen, session: *const transport.Session) void {
        assert(c.wants.items.len == c.want_names.items.len);
        assert(c.first_refs.items.len == c.first_sources.items.len);
        for (c.want_names.items, c.wants.items) |name, *oid| if (session.fetchedValue(name)) |value| {
            oid.* = value;
        };
        for (c.first_sources.items, c.first_refs.items) |name, *entry| if (session.fetchedValue(name)) |value| {
            entry.oid = value;
        };
    }

    /// Keep the remote's tags whose objects the pack brought.
    fn keepFetchedTags(c: *Chosen, arena: Allocator, io: Io, repo: *Repository, remote_refs: []const protocol.RemoteRef, single_tag: ?[]const u8) Error!void {
        for (remote_refs) |ref| {
            if (!std.mem.startsWith(u8, ref.name, "refs/tags/") or std.mem.endsWith(u8, ref.name, "^{}")) continue;
            if (single_tag != null and std.mem.eql(u8, ref.name, single_tag.?)) continue;
            if (!try repo.objectDatabase().exists(io, ref.oid)) continue;
            if (!ref_names.checkFormat(ref.name, .{})) continue;
            try c.first_refs.append(arena, .{ .name = try arena.dupe(u8, ref.name), .oid = ref.oid, .peeled = ref.peeled });
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
            try arena.print("refs/remotes/{s}/{s}", .{ options.origin.?, ref.name["refs/heads/".len..] })
        else
            try arena.dupe(u8, ref.name);
        if (!ref_names.checkFormat(local_name, .{})) continue;
        try c.first_refs.append(arena, .{ .name = local_name, .oid = ref.oid, .peeled = ref.peeled });
        try c.first_sources.append(arena, ref.name);
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
fn checkCloned(gpa: Allocator, io: Io, repo: *Repository, pack_dir: Io.Dir, pack_name: ?Oid, wants: []const Oid, links: *const index_pack.Links, promisor: bool) Error!void {
    var fresh: ?pack.Index = null;
    defer if (fresh) |*index| index.deinit();
    if (pack_name) |name| {
        var hex: [hash.max_hex_len]u8 = undefined;
        var idx_buf: [96]u8 = undefined;
        const idx_name = std.mem.print(&idx_buf, "pack-{s}.idx", .{name.hex(&hex)}) catch unreachable; // unreachable: the longest hex name is 64 digits, 73 bytes with the words around it
        fresh = try pack.Index.open(gpa, io, pack_dir, idx_name, .{ .kind = repo.objectFormat(), .max_bytes = 1 << 30 });
    }
    const connected = if (fresh) |*index|
        object_walk.checkReceived(gpa, io, repo.objectDatabase(), wants, .{ .fresh = index, .links = links, .missing_out = null, .promisor = promisor })
    else
        object_walk.checkConnected(gpa, io, repo.objectDatabase(), wants, .{ .fresh = null, .missing_out = null, .promisor = promisor });
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
        // An unborn branch, which `HEAD` names already.
        const ref = remote_refs.find(branch) orelse return trackUnborn(arena, io, repo, detached, options);
        const value = session.fetchedValue(branch) orelse ref.oid;
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        if (!options.bare) try tx.update(branch, .{ .direct = value }, .any);
        try tx.update("HEAD", .{ .symbolic = branch }, .any);
        try tx.commit(io, log);
        if (!options.bare) try track(arena, io, repo, branch, options);
        return value;
    }
    if (detached) |oid| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.change("HEAD", .{ .direct = oid }, .any, .{ .no_deref = true });
        try tx.commit(io, log);
        return detached;
    }
    // An empty remote that names no branch: `HEAD` is on the default one.
    return trackUnborn(arena, io, repo, null, options);
}

/// The branch `HEAD` is on, unborn, set to follow the same branch of the
/// remote, as git's `update_head` sets it.
fn trackUnborn(arena: Allocator, io: Io, repo: *Repository, detached: ?Oid, options: Options) Error!?Oid {
    if (options.bare) return detached;
    const short = try repo.refStore().currentBranch(arena, io) orelse return detached;
    try track(arena, io, repo, try arena.print("refs/heads/{s}", .{short}), options);
    return detached;
}

/// `branch.<name>.remote` and `branch.<name>.merge` for `branch`.
fn track(arena: Allocator, io: Io, repo: *Repository, branch: []const u8, options: Options) Error!void {
    const short = branch["refs/heads/".len..];
    _ = try repo.writeConfig(io, .local, &.{
        .{ .set = .{ .name = try arena.print("branch.{s}.remote", .{short}), .value = options.origin.? } },
        .{ .set = .{ .name = try arena.print("branch.{s}.merge", .{short}), .value = branch } },
    }, .{});
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
    const local_head = try arena.print("refs/remotes/{s}/HEAD", .{origin});
    const local_target = try arena.print("refs/remotes/{s}/{s}", .{ origin, target["refs/heads/".len..] });
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
    const probe = std.mem.print(&buf, "refs/remotes/{s}/x", .{name}) catch return false;
    return ref_names.checkFormat(probe, .{});
}

fn containsOid(list: []const Oid, oid: Oid) bool {
    for (list) |o| {
        if (o.eql(oid)) return true;
    }
    return false;
}

/// The new repository, as the clone makes it: `object_format` the
/// remote's, or the default when it is not known yet.
fn initRepository(gpa: Allocator, io: Io, dir: Io.Dir, options: Options, object_format: ?hash.Kind, initial: ?[]const u8) Error!Repository {
    // What is not given is the caller's levels' to say, as git's
    // `init_db` reads them for a clone.
    const user = options.user_config;
    var repo = try Repository.create(gpa, io, dir, .{
        .object_format = object_format,
        .ref_format = options.ref_format,
        .default_branch = initial,
        .bare = options.bare or options.separate_git_dir,
        .odb = options.odb,
        .system_config = user.system,
        .xdg_config = user.xdg,
        .global_config = user.global,
        .config_overrides = user.command,
        .config_pairs = user.pairs,
        .home = options.home,
    });
    errdefer repo.deinit(io);
    // A git directory with its working tree elsewhere is not bare, and
    // logs its refs as `git init` sets a repository with a working tree to.
    if (options.separate_git_dir) {
        _ = try repo.writeConfig(io, .local, &.{
            .{ .set = .{ .name = "core.bare", .value = "false" } },
            .{ .set = .{ .name = "core.logallrefupdates", .value = "true" } },
        }, .{});
    }
    return repo;
}

/// Check out the commit using its attributes and configured filter programs.
/// The operation owner supplies native formats through `native_filters`.
fn checkOut(gpa: Allocator, io: Io, repo: *Repository, commit: Oid, options: Options) Error!void {
    const programs = options.programs;
    const tree = try repo.commitTree(io, repo.peel(io, commit) catch commit);
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    const skip_smudge = if (programs) |p|
        (if (p.environ.get("GIT_LFS_SKIP_SMUDGE")) |v| config_mod.parseBool(v) catch false else false)
    else
        false;
    var filters = if (options.native_filters) |loader|
        try loader.load_fn(gpa, io, loader.context, repo, .{
            .remote = options.origin.?,
            .programs = programs,
            .prompt = options.prompt,
            .auth_failure = options.auth_failure,
            .skip_smudge = skip_smudge,
        })
    else
        Filters{ .drivers = try repo.loadFilters(io, .{}) };
    defer filters.deinit(io);
    var rules = try repo.worktreeRules();
    rules.attrs = &attrs;
    rules.filters = &filters.drivers;
    const required = try repo.requiredFilters(gpa);
    defer gpa.free(required);
    rules.required_filters = required;
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    // A new clone's working tree has nothing in it to lose, as git's
    // clone takes it.
    _ = try worktree.checkout(gpa, io, repo.workDirectory().?, .{ .index = index, .db = repo.objectDatabase(), .tree = tree }, .{
        .rules = rules,
        .programs = programs,
        .force = true,
    });
    try locked_index.commit(io);
}

/// A local path as git's clone records it, through `absolute_pathdup`: an
/// absolute path as it was given, links and separators and all, and any
/// other after the working directory and a slash. git's working directory
/// on Windows is written with forward slashes.
fn absolutePathAsGit(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(path)) return path;
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, cwd, '\\', '/');
    const sep: []const u8 = if (cwd.len != 0 and (cwd[cwd.len - 1] == '/' or cwd[cwd.len - 1] == '\\')) "" else "/";
    return std.mem.concat(arena, u8, &.{ cwd, sep, path });
}

/// What every clone and fetch a `SubmoduleTransport` makes is made with.
pub const SubmoduleOptions = struct {
    /// Who the reflog entries are written as, and when.
    who: object.Signature,
    /// The permission to run `ssh` and credential helpers.
    programs: ?program.Programs = null,
    /// The person's configuration, for `core.sshCommand`, `http.*` and the
    /// credential helpers, which a new submodule repository does not yet
    /// have: see `user_config.locate`.
    config: ?*const config_mod.Config = null,
    prompt: ?credential.Prompt = null,
    progress: ?progress_mod.Progress = null,
    /// Whether received objects are checked as git's `index-pack --strict`
    /// checks them: `null` takes `fetch.fsckObjects` or
    /// `transfer.fsckObjects`; see `fetch.Options.check_objects`.
    check_objects: ?bool = null,
    warnings: ?*warning.Warnings = null,
    /// git's `submodule update --depth`: each clone and fetch this deep.
    depth: ?u32 = null,
    /// `--filter`: each submodule cloned partial, as `Options.filter`.
    filter: ?[]const u8 = null,
    /// `--[no-]single-branch`, as `Options.single_branch`.
    single_branch: ?bool = null,
    /// `--ref-format`, as `Options.ref_format`.
    ref_format: ?refs_mod.Format = null,
};

/// Where a submodule's repository and its missing commits come from: relic's
/// own clone and fetch, behind the seam `submodule.update` leaves for them.
///
/// What git's `submodule update` runs, this does in process. A submodule
/// with no repository is cloned into `modules/<name>` as `git clone
/// --no-checkout --separate-git-dir` clones it — its remote `origin` with
/// its remote-tracking branches, `HEAD` on the remote's branch, refs
/// logged, nothing checked out — and `update` connects the working tree
/// and checks the recorded commit out. A recorded commit the repository
/// lacks is fetched the way git fetches it: a plain fetch of the default
/// remote first, and when the commit is still not there, the commit asked
/// for by name. A relative URL has been resolved against the
/// superproject's remote by the time it arrives here.
///
/// `submodule.Transport` says only that it failed; the error behind it is
/// kept in `failure`, and a refused credential is described in
/// `auth_failure`, for the caller's message.
pub const SubmoduleTransport = struct {
    pub const Error = ErrorNamespace.Error || fetch_mod.Error || odb_mod.Error || partial.Error;
    options: SubmoduleOptions,
    /// The error behind the last `error.TransportFailed`.
    failure: ?SubmoduleTransport.Error = null,
    /// The last refusal of a credential, described.
    auth_failure: auth.Failure = .{},
    /// How many repositories were cloned and how many fetches made.
    clones: u32 = 0,
    fetches: u32 = 0,

    /// A transport making every clone and fetch with `options`.
    pub fn init(options: SubmoduleOptions) SubmoduleTransport {
        return .{ .options = options };
    }

    /// Release the failure's description.
    pub fn deinit(t: *SubmoduleTransport) void {
        t.auth_failure.deinit();
        t.* = undefined;
    }

    /// The seam `submodule.UpdateOptions.transport` takes. `t` must
    /// outlive the update.
    pub fn transport(t: *SubmoduleTransport) submodule.Transport {
        return .{ .context = t, .cloneFn = cloneFn, .fetchFn = fetchFn, .fetchPromisedFn = fetchPromisedFn };
    }

    fn failed(t: *SubmoduleTransport, err: SubmoduleTransport.Error) submodule.TransportError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => {
                t.failure = err;
                return error.TransportFailed;
            },
        };
    }

    fn cloneFn(gpa: Allocator, io: Io, context: *anyopaque, request: submodule.CloneRequest) submodule.TransportError!void {
        const t: *SubmoduleTransport = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a SubmoduleTransport
        t.cloneInto(gpa, io, request) catch |err| return t.failed(err);
        t.clones += 1;
    }

    /// git's `clone_submodule`: the lenders `submodule.alternateLocation`
    /// gives (`reference.forSubmodule`) borrowed from, and that setting
    /// and `submodule.alternateErrorStrategy` written into the new
    /// repository, so its own submodules borrow the same way.
    fn cloneInto(t: *SubmoduleTransport, gpa: Allocator, io: Io, request: submodule.CloneRequest) SubmoduleTransport.Error!void {
        const o = t.options;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const lenders = if (request.within) |w| try reference.forSubmodule(arena, io, w.superproject, w.name, o.warnings) else &.{};
        var repo = try clone(gpa, io, request.url, request.git_dir, .{
            .separate_git_dir = true,
            .who = o.who,
            .programs = o.programs,
            .config = o.config,
            .prompt = o.prompt,
            .auth_failure = &t.auth_failure,
            .progress = o.progress,
            .warnings = o.warnings,
            .check_objects = o.check_objects,
            .reference = lenders,
            .depth = o.depth,
            .filter = o.filter,
            .single_branch = o.single_branch,
            .ref_format = o.ref_format,
            // A `.gitmodules` names this URL, not the person, as git's
            // `GIT_PROTOCOL_FROM_USER=0` says for a submodule.
            .from_user = false,
        });
        defer repo.deinit(io);
        const w = request.within orelse return;
        var edits: std.ArrayList(Repository.ConfigEdit) = .empty;
        for ([_][]const u8{ "submodule.alternateLocation", "submodule.alternateErrorStrategy" }) |name| {
            const value = w.superproject.configuration().get(name) orelse continue;
            try edits.append(arena, .{ .set = .{ .name = name, .value = value } });
        }
        if (edits.items.len != 0) _ = try repo.writeConfig(io, .local, edits.items, .{});
    }

    fn fetchFn(gpa: Allocator, io: Io, context: *anyopaque, repo: *Repository, remote: []const u8, want: Oid) submodule.TransportError!void {
        const t: *SubmoduleTransport = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a SubmoduleTransport
        t.fetchOnce(gpa, io, repo, remote, &.{}) catch |err| return t.failed(err);
        repo.objectDatabase().refresh(io) catch |err| return t.failed(err);
        if (repo.objectDatabase().exists(io, want) catch |err| return t.failed(err)) return;
        // Not on any branch the remote advertises: asked for by name, as
        // git's `fetch <remote> <commit>` asks.
        var hex: [hash.max_hex_len]u8 = undefined;
        t.fetchOnce(gpa, io, repo, remote, &.{want.hex(&hex)}) catch |err| return t.failed(err);
    }

    fn fetchPromisedFn(gpa: Allocator, io: Io, context: *anyopaque, repo: *Repository, oids: []const Oid) submodule.TransportError!void {
        const t: *SubmoduleTransport = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a SubmoduleTransport
        const o = t.options;
        var lazy: partial.Lazy = .init(gpa, repo, .{ .programs = o.programs, .prompt = o.prompt, .check_objects = o.check_objects });
        defer lazy.deinit();
        lazy.fetch(io, oids) catch |err| return t.failed(err);
    }

    fn fetchOnce(t: *SubmoduleTransport, gpa: Allocator, io: Io, repo: *Repository, remote: []const u8, refspecs: []const []const u8) SubmoduleTransport.Error!void {
        const o = t.options;
        var outcome = try fetch_mod.fetch(gpa, io, repo, remote, .{
            .refspecs = refspecs,
            .who = o.who,
            .programs = o.programs,
            .prompt = o.prompt,
            .auth_failure = &t.auth_failure,
            .progress = o.progress,
            .check_objects = o.check_objects,
            .warnings = o.warnings,
            .depth = o.depth,
            .from_user = false,
        });
        outcome.deinit();
        t.fetches += 1;
    }
};

const testing = std.testing;
const testgit = @import("../testing/git.zig");
const decimal = @import("../text.zig").decimal;
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
        .{ .args = &.{ "for-each-ref", "--format=%(refname) %(objectname) %(*objectname) %(symref)" } },
        .{ .args = &.{ "rev-parse", "--show-ref-format" } },
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
        return .{ .tmp = tmp, .path = try gpa.print("{s}/clone", .{base}), .dir = dir };
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
        .{ .git_args = &.{"--ref-format=reftable"}, .options = .{ .who = test_who, .ref_format = .reftable } },
        .{ .git_args = &.{ "--ref-format=reftable", "--bare" }, .options = .{ .who = test_who, .ref_format = .reftable, .bare = true } },
    };
    for (cases) |case| {
        // A reftable repository is git 2.45's to make.
        if (case.options.ref_format == .reftable and !try testgit.gitAtLeast(gpa, io, 2, 45)) continue;
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
    const tasks = io_mod;
    const io = testing.io;
    var single: Io.Threaded = .init_single_threaded;

    // One batch with enough objects for every requested task.
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    for (0..32) |i| {
        var name_buf: [32]u8 = undefined;
        var body_buf: [32]u8 = undefined;
        try source.writeFile(io, try std.mem.print(&name_buf, "many/{d}.txt", .{i}), try std.mem.print(&body_buf, "file {d}\n", .{i}));
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
    var serial = try clone(gpa, tasks.wrap(io), source_path, serial_target.dir, .{ .who = test_who, .checkout = false, .user_config = .{ .pairs = &.{.{ .name = "pack.threads", .value = "1" }} } });
    defer serial.deinit(io);
    try tasks.expect(0, 0);
    var serial_packs = try serial.gitDirectory().openDir(io, "objects/pack", .{ .iterate = true });
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
            var repo = try clone(gpa, tasks.wrap(each_io), source_path, target.dir, .{ .who = test_who, .checkout = false, .user_config = .{ .pairs = case.pairs } });
            defer repo.deinit(io);
            // Headers and bodies on at most six tasks, one search group,
            // then deflation on all tasks, each including the caller.
            const readers: usize = @min(case.workers, 6);
            const spawned = if (case.workers == 1) 0 else 2 * (readers - 1) + case.workers - 1;
            try tasks.expect(spawned, 0);
            var packs = try repo.gitDirectory().openDir(io, "objects/pack", .{ .iterate = true });
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
        const bare = try gpa.print("{s}/repo.git", .{root_path});
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
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
    const ssh_url = try gpa.print("ssh://example.invalid{s}{s}/repo.git", .{ if (builtin.target.os.tag == .windows) "/" else "", ssh_path });
    defer gpa.free(ssh_url);

    var settings_text: std.ArrayList(u8) = .empty;
    defer settings_text.deinit(gpa);
    try settings_text.print(gpa, "[core]\nsshCommand = {s}\n", .{fake});
    var settings = try config_mod.Config.parseText(gpa, settings_text.items, .command);
    defer settings.deinit();
    const ssh_setting = try gpa.print("core.sshCommand={s}", .{fake});
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
    try testing.expectEqualStrings(theirs, ours);
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

test "clone.defaultRemoteName names the remote unless the clone does, and clone.rejectShallow refuses a shallow source, as git's clone reads them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    {
        var source = try testremote.historyRepo(gpa, io, 3);
        defer source.deinit();
        const source_path = try testremote.absolutePath(gpa, io, source.dir);
        defer gpa.free(source_path);
        const bare = try gpa.print("{s}/repo.git", .{root_path});
        defer gpa.free(bare);
        try source.exec(io, &.{ "clone", "-q", "--bare", source_path, bare });
        const from = try gpa.print("file://{s}", .{bare});
        defer gpa.free(from);
        const shallow = try gpa.print("{s}/shallow.git", .{root_path});
        defer gpa.free(shallow);
        try source.exec(io, &.{ "clone", "-q", "--bare", "--depth", "1", from, shallow });
    }
    const fake = try testremote.fakeSsh(gpa, io, root.dir);
    defer gpa.free(fake);
    const ssh_setting = try gpa.print("core.sshCommand={s}", .{fake});
    defer gpa.free(ssh_setting);
    const ssh_path = try gpa.dupe(u8, root_path);
    defer gpa.free(ssh_path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
    const slash = if (builtin.target.os.tag == .windows) "/" else "";

    // The configured name, and `--origin` over it.
    const repo_path = try gpa.print("{s}/repo.git", .{root_path});
    defer gpa.free(repo_path);
    for ([_]?[]const u8{ null, "mine" }) |origin| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);
        const out = if (origin) |name|
            try git(gpa, io, &env, by_git.tmp.dir, &.{ "-c", "clone.defaultRemoteName=upstream", "clone", "-q", "--origin", name, repo_path, by_git.path })
        else
            try git(gpa, io, &env, by_git.tmp.dir, &.{ "-c", "clone.defaultRemoteName=upstream", "clone", "-q", repo_path, by_git.path });
        gpa.free(out);
        var settings = try config_mod.Config.parseText(gpa, "[clone]\ndefaultRemoteName = upstream\n", .command);
        defer settings.deinit();
        var repo = try clone(gpa, io, repo_path, by_relic.dir, .{ .who = test_who, .origin = origin, .config = &settings });
        repo.deinit(io);
        try expectSameClone(gpa, io, &env, by_git.dir, by_relic.dir, false);
        const remotes = try git(gpa, io, &env, by_relic.dir, &.{"remote"});
        defer gpa.free(remotes);
        try testing.expectEqualStrings(if (origin == null) "upstream\n" else "mine\n", remotes);
    }

    // A shallow source, refused by path, by upload-pack over both
    // protocols, and kept when the clone is shallow itself or says so.
    const shallow_path = try gpa.print("{s}/shallow.git", .{root_path});
    defer gpa.free(shallow_path);
    const ssh_url = try gpa.print("ssh://example.invalid{s}{s}/shallow.git", .{ slash, ssh_path });
    defer gpa.free(ssh_url);
    const Case = struct { url: []const u8, version: []const u8, depth: ?u32 = null, reject: ?bool = null, refused: bool };
    const cases = [_]Case{
        .{ .url = shallow_path, .version = "2", .refused = true },
        .{ .url = ssh_url, .version = "2", .refused = true },
        .{ .url = ssh_url, .version = "0", .refused = true },
        .{ .url = ssh_url, .version = "2", .depth = 1, .refused = false },
        .{ .url = ssh_url, .version = "0", .reject = false, .refused = false },
        .{ .url = shallow_path, .version = "2", .reject = false, .refused = false },
    };
    for (cases) |case| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);
        const version = try gpa.print("protocol.version={s}", .{case.version});
        defer gpa.free(version);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "-c", ssh_setting, "-c", version, "-c", "clone.rejectShallow=true", "clone", "-q" });
        if (case.depth != null) try argv.append(gpa, "--depth=1");
        if (case.reject != null) try argv.append(gpa, "--no-reject-shallow");
        try argv.appendSlice(gpa, &.{ case.url, by_git.path });
        const by_git_ok = if (testremote.gitInputEnv(gpa, io, by_git.tmp.dir, &env, argv.items, "", false)) |out| ok: {
            gpa.free(out);
            break :ok true;
        } else |err| switch (err) {
            error.GitFailed => false,
            else => return err,
        };
        try testing.expectEqual(!case.refused, by_git_ok);

        const text = try gpa.print("[core]\nsshCommand = {s}\n[protocol]\nversion = {s}\n[clone]\nrejectShallow = true\n", .{ fake, case.version });
        defer gpa.free(text);
        var settings = try config_mod.Config.parseText(gpa, text, .command);
        defer settings.deinit();
        const made = clone(gpa, io, case.url, by_relic.dir, .{
            .who = test_who,
            .programs = .{ .environ = &env },
            .config = &settings,
            .depth = case.depth,
            .reject_shallow = case.reject,
        });
        if (case.refused) {
            try testing.expectError(error.ShallowSourceRefused, made);
            continue;
        }
        var repo = try made;
        repo.deinit(io);
        try expectSameClone(gpa, io, &env, by_git.dir, by_relic.dir, false);
    }
}

test "a clone takes init.defaultBranch for an empty remote that names no branch, and init.defaultRefFormat, from the caller's levels as git's does" {
    const gpa = testing.allocator;
    const io = testing.io;
    // A reftable repository is git 2.45's to make.
    if (!try testgit.gitAtLeast(gpa, io, 2, 45)) return error.SkipZigTest;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    const empty_path = try gpa.print("{s}/empty.git", .{root_path});
    defer gpa.free(empty_path);
    const made = try git(gpa, io, &env, root.dir, &.{ "init", "-q", "--bare", "--initial-branch=trunk", empty_path });
    gpa.free(made);
    const fake = try testremote.fakeSsh(gpa, io, root.dir);
    defer gpa.free(fake);
    const ssh_setting = try gpa.print("core.sshCommand={s}", .{fake});
    defer gpa.free(ssh_setting);
    const ssh_path = try gpa.dupe(u8, root_path);
    defer gpa.free(ssh_path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
    const ssh_url = try gpa.print("ssh://example.invalid{s}{s}/empty.git", .{ if (builtin.target.os.tag == .windows) "/" else "", ssh_path });
    defer gpa.free(ssh_url);

    // Over protocol v0 an empty remote names no branch; v2 names its
    // unborn one, which beats the setting.
    for ([_][]const u8{ "0", "2" }) |version| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);
        const version_setting = try gpa.print("protocol.version={s}", .{version});
        defer gpa.free(version_setting);
        const out = try git(gpa, io, &env, by_git.tmp.dir, &.{ "-c", ssh_setting, "-c", version_setting, "-c", "init.defaultBranch=stem", "-c", "init.defaultRefFormat=" ++ @tagName(refs_mod.Format.reftable), "clone", "-q", ssh_url, by_git.path });
        gpa.free(out);
        const pairs = [_]config_mod.Sources.Pair{
            .{ .name = "core.sshCommand", .value = fake },
            .{ .name = "protocol.version", .value = version },
            .{ .name = "init.defaultBranch", .value = "stem" },
            .{ .name = "init.defaultRefFormat", .value = @tagName(refs_mod.Format.reftable) },
        };
        var repo = try clone(gpa, io, ssh_url, by_relic.dir, .{ .who = test_who, .programs = .{ .environ = &env }, .user_config = .{ .pairs = &pairs } });
        repo.deinit(io);
        for ([_][]const []const u8{ &.{ "symbolic-ref", "HEAD" }, &.{ "rev-parse", "--show-ref-format" }, &.{ "config", "--local", "--get-regexp", "^(remote|branch)\\." } }) |args| {
            const theirs = try git(gpa, io, &env, by_git.dir, args);
            defer gpa.free(theirs);
            const ours = try git(gpa, io, &env, by_relic.dir, args);
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
        const head = try git(gpa, io, &env, by_relic.dir, &.{ "symbolic-ref", "HEAD" });
        defer gpa.free(head);
        try testing.expectEqualStrings(if (version[0] == '0') "refs/heads/stem\n" else "refs/heads/trunk\n", head);
    }
}

/// Run git in `dir` with the suite's settings, `protocol.file.allow`
/// among them.
fn gitIn(gpa: Allocator, io: Io, dir: Io.Dir, args: []const []const u8) !void {
    const out = try testremote.gitInput(gpa, io, dir, args, "");
    gpa.free(out);
}

/// What git and relic are compared on: each submodule repository's refs,
/// remote and working-tree setting, and the superproject's view of them.
fn expectSameSubmodules(gpa: Allocator, io: Io, by_git: Io.Dir, by_relic: Io.Dir) !void {
    for ([_][]const u8{ ".git/modules/lib", ".git/modules/lib/modules/inner" }) |git_dir| {
        for ([_][]const []const u8{
            &.{ "--git-dir", git_dir, "for-each-ref", "--format=%(refname) %(objectname) %(symref)" },
            &.{ "--git-dir", git_dir, "rev-parse", "HEAD" },
            &.{ "--git-dir", git_dir, "config", "--get-regexp", "^(remote|core\\.(bare|worktree)|branch)" },
        }) |args| {
            const theirs = testremote.gitInput(gpa, io, by_git, args, "") catch try gpa.dupe(u8, "(failed)");
            defer gpa.free(theirs);
            const ours = testremote.gitInput(gpa, io, by_relic, args, "") catch try gpa.dupe(u8, "(failed)");
            defer gpa.free(ours);
            try testing.expectEqualStrings(theirs, ours);
        }
    }
    const theirs = try testremote.gitInput(gpa, io, by_git, &.{ "submodule", "status", "--recursive" }, "");
    defer gpa.free(theirs);
    const ours = try testremote.gitInput(gpa, io, by_relic, &.{ "submodule", "status", "--recursive" }, "");
    defer gpa.free(ours);
    try testing.expectEqualStrings(theirs, ours);
    const status = try testremote.gitInput(gpa, io, by_relic, &.{ "status", "--porcelain" }, "");
    defer gpa.free(status);
    try testing.expectEqualStrings("", status);
    for ([_][]const u8{ "lib", "lib/inner" }) |path| {
        var sub = try by_relic.openDir(io, path, .{});
        defer sub.close(io);
        try gitIn(gpa, io, sub, &.{ "fsck", "--strict", "--no-dangling" });
    }
}

test "submodules cloned and fetched from a remote are what git submodule update --init --recursive makes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const server = try testremote.HttpServer.start(gpa, io, root.dir, .{});
    defer server.stop();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    var env = try testremote.environ(gpa);
    defer env.deinit();

    // Three repositories, each made in `work/<name>` and pushed to the bare
    // one the server serves: `inner`; `lib`, holding `inner`; `super`,
    // holding `lib`. The submodule URLs are relative, as a forge's are.
    var work = try testgit.Repo.init(gpa, io, &.{});
    defer work.deinit();
    const names = [_][]const u8{ "inner", "lib", "super" };
    for (names, 0..) |name, i| {
        const bare = try gpa.print("{s}/{s}.git", .{ root_path, name });
        defer gpa.free(bare);
        try gitIn(gpa, io, work.dir, &.{ "init", "-q", "--bare", "-b", "main", bare });
        try gitIn(gpa, io, work.dir, &.{ "--git-dir", bare, "config", "uploadpack.allowAnySHA1InWant", "true" });
        try gitIn(gpa, io, work.dir, &.{ "init", "-q", "-b", "main", name });
        var dir = try work.dir.openDir(io, name, .{});
        defer dir.close(io);
        const file = try gpa.print("{s}.git", .{name});
        defer gpa.free(file);
        const url = try server.url(gpa, file);
        defer gpa.free(url);
        try gitIn(gpa, io, dir, &.{ "remote", "add", "origin", url });
        try dir.writeFile(io, .{ .sub_path = "README", .data = name });
        try gitIn(gpa, io, dir, &.{ "add", "README" });
        if (i > 0) {
            const relative = try gpa.print("../{s}.git", .{names[i - 1]});
            defer gpa.free(relative);
            try gitIn(gpa, io, dir, &.{ "submodule", "add", "-q", relative, names[i - 1] });
        }
        try gitIn(gpa, io, dir, &.{ "commit", "-q", "-m", name });
        try gitIn(gpa, io, dir, &.{ "push", "-q", bare, "main" });
    }
    const super_url = try server.url(gpa, "super.git");
    defer gpa.free(super_url);
    try gitIn(gpa, io, work.dir, &.{ "clone", "-q", super_url, "by-git" });
    try gitIn(gpa, io, work.dir, &.{ "clone", "-q", super_url, "by-relic" });
    var by_git = try work.dir.openDir(io, "by-git", .{});
    defer by_git.close(io);
    var by_relic = try work.dir.openDir(io, "by-relic", .{});
    defer by_relic.close(io);

    var t: SubmoduleTransport = .init(.{ .who = test_who, .programs = .{ .environ = &env } });
    defer t.deinit();
    try gitIn(gpa, io, by_git, &.{ "submodule", "update", "-q", "--init", "--recursive" });
    {
        var repo = try Repository.open(gpa, io, by_relic, .{});
        defer repo.deinit(io);
        _ = try submodule.update(gpa, io, &repo, .{ .init = true, .recursive = true, .transport = t.transport(), .who = test_who });
    }
    try testing.expectEqual(@as(u32, 2), t.clones);
    try expectSameSubmodules(gpa, io, by_git, by_relic);

    // New commits below: `inner` moves on, once on its branch and once to a
    // commit only a ref outside refs/heads reaches, and each level records
    // the one below. An update then has commits to fetch.
    {
        var inner = try work.dir.openDir(io, "inner", .{});
        defer inner.close(io);
        try inner.writeFile(io, .{ .sub_path = "README", .data = "inner, again" });
        const bare = try gpa.print("{s}/inner.git", .{root_path});
        defer gpa.free(bare);
        try gitIn(gpa, io, inner, &.{ "commit", "-q", "-am", "again" });
        try gitIn(gpa, io, inner, &.{ "push", "-q", bare, "main" });
        try inner.writeFile(io, .{ .sub_path = "README", .data = "inner, aside" });
        try gitIn(gpa, io, inner, &.{ "commit", "-q", "-am", "aside" });
        try gitIn(gpa, io, inner, &.{ "push", "-q", bare, "HEAD:refs/keep/aside" });
    }
    for ([_][]const u8{ "lib", "super" }, [_][]const u8{ "inner", "lib" }) |name, below| {
        var dir = try work.dir.openDir(io, name, .{});
        defer dir.close(io);
        var sub = try dir.openDir(io, below, .{});
        defer sub.close(io);
        if (std.mem.eql(u8, below, "inner")) {
            try gitIn(gpa, io, sub, &.{ "fetch", "-q", "origin", "refs/keep/aside" });
            try gitIn(gpa, io, sub, &.{ "checkout", "-q", ref_names.Special.fetch_head.name() });
        } else {
            try gitIn(gpa, io, sub, &.{ "pull", "-q", "origin", "main" });
        }
        try gitIn(gpa, io, dir, &.{ "commit", "-q", "-am", "move" });
        const bare = try gpa.print("{s}/{s}.git", .{ root_path, name });
        defer gpa.free(bare);
        try gitIn(gpa, io, dir, &.{ "push", "-q", bare, "main" });
    }
    for ([_]Io.Dir{ by_git, by_relic }) |dir| try gitIn(gpa, io, dir, &.{ "pull", "-q", "--no-recurse-submodules", "origin", "main" });
    try gitIn(gpa, io, by_git, &.{ "submodule", "update", "-q", "--recursive" });
    {
        var repo = try Repository.open(gpa, io, by_relic, .{});
        defer repo.deinit(io);
        _ = try submodule.update(gpa, io, &repo, .{ .recursive = true, .transport = t.transport(), .who = test_who });
    }
    // `lib`'s fetch goes on into `inner` itself, on demand, as git's
    // `fetch` inside a submodule does.
    try testing.expect(t.fetches >= 1);
    try expectSameSubmodules(gpa, io, by_git, by_relic);
}

test "a submodule URL naming a repository on this machine is refused unless protocol.file.allow says otherwise, as git refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source = try testremote.historyRepo(gpa, io, 1);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    var scratch = testing.tmpDir(.{ .iterate = true });
    defer scratch.cleanup();

    // git, told the URL is not the person's, as `git submodule` tells it.
    var env = try testremote.environ(gpa);
    defer env.deinit();
    try env.put("GIT_PROTOCOL_FROM_USER", "0");
    try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, scratch.dir, &env, &.{ "-c", "protocol.file.allow=user", "clone", "-q", source_path, "by-git" }, "", false));

    try scratch.dir.createDirPath(io, "refused");
    var refused_dir = try scratch.dir.openDir(io, "refused", .{ .iterate = true });
    defer refused_dir.close(io);
    var refused: SubmoduleTransport = .init(.{ .who = test_who });
    defer refused.deinit();
    try testing.expectError(error.TransportFailed, SubmoduleTransport.cloneFn(gpa, io, &refused, .{ .url = source_path, .git_dir = refused_dir }));
    try testing.expectEqual(@as(?SubmoduleTransport.Error, error.TransportNotAllowed), refused.failure);
    try testing.expectEqual(@as(u32, 0), refused.clones);

    var config = try config_mod.Config.parseText(gpa, "[protocol \"file\"]\n\tallow = always\n", .global);
    defer config.deinit();
    try scratch.dir.createDirPath(io, "allowed");
    var allowed_dir = try scratch.dir.openDir(io, "allowed", .{ .iterate = true });
    defer allowed_dir.close(io);
    var allowed: SubmoduleTransport = .init(.{ .who = test_who, .config = &config });
    defer allowed.deinit();
    try SubmoduleTransport.cloneFn(gpa, io, &allowed, .{ .url = source_path, .git_dir = allowed_dir });
    try testing.expectEqual(@as(u32, 1), allowed.clones);
}

test "a clone borrows from --reference and --reference-if-able as git's does, and --dissociate copies the borrowed objects in" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var root = testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    const root_path = try testremote.absolutePath(gpa, io, root.dir);
    defer gpa.free(root_path);
    // The remote has four commits; the lender, a clone of it, every one
    // through its tags; the older lender, with no tags, the first three;
    // and a shallow one only the last.
    var source = try testremote.historyRepo(gpa, io, 4);
    defer source.deinit();
    const source_path = try testremote.absolutePath(gpa, io, source.dir);
    defer gpa.free(source_path);
    const lender = try gpa.print("{s}/lender", .{root_path});
    defer gpa.free(lender);
    try source.exec(io, &.{ "clone", "-q", "--no-checkout", source_path, lender });
    const lender_git = try gpa.print("{s}/.git", .{lender});
    defer gpa.free(lender_git);
    try source.exec(io, &.{ "--git-dir", lender_git, "update-ref", "refs/remotes/origin/main", "HEAD~1" });
    try source.exec(io, &.{ "--git-dir", lender_git, "update-ref", "refs/heads/main", "HEAD~1" });
    try source.exec(io, &.{ "--git-dir", lender_git, "reflog", "expire", "--expire=now", "--all" });
    try source.exec(io, &.{ "--git-dir", lender_git, "gc", "-q", "--prune=now" });
    const older = try gpa.print("{s}/older", .{root_path});
    defer gpa.free(older);
    try source.exec(io, &.{ "clone", "-q", "--bare", "--no-tags", source_path, older });
    try source.exec(io, &.{ "--git-dir", older, "update-ref", "refs/heads/main", "main~1" });
    try source.exec(io, &.{ "--git-dir", older, "reflog", "expire", "--expire=now", "--all" });
    try source.exec(io, &.{ "--git-dir", older, "gc", "-q", "--prune=now" });
    const shallow = try gpa.print("{s}/shallow", .{root_path});
    defer gpa.free(shallow);
    const from = try gpa.print("file://{s}", .{source_path});
    defer gpa.free(from);
    try source.exec(io, &.{ "clone", "-q", "--depth", "1", from, shallow });
    const missing = try gpa.print("{s}/nowhere", .{root_path});
    defer gpa.free(missing);
    // git's own upload-pack serves both, behind the stand-in ssh, so the
    // packs they are sent are the same.
    const fake = try testremote.fakeSsh(gpa, io, root.dir);
    defer gpa.free(fake);
    const ssh_setting = try gpa.print("core.sshCommand={s}", .{fake});
    defer gpa.free(ssh_setting);
    const ssh_path = try gpa.dupe(u8, source_path);
    defer gpa.free(ssh_path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
    const served = try gpa.print("ssh://example.invalid{s}{s}", .{ if (builtin.target.os.tag == .windows) "/" else "", ssh_path });
    defer gpa.free(served);
    const settings_text = try gpa.print("[core]\nsshCommand = {s}\n", .{fake});
    defer gpa.free(settings_text);
    var settings = try config_mod.Config.parseText(gpa, settings_text, .command);
    defer settings.deinit();

    const Case = struct { git_args: []const []const u8, references: []const Reference, dissociate: bool = false, refused: ?anyerror = null };
    const cases = [_]Case{
        .{ .git_args = &.{ "--reference", lender }, .references = &.{.{ .path = lender }} },
        .{ .git_args = &.{ "--reference", older }, .references = &.{.{ .path = older }} },
        .{ .git_args = &.{ "--reference", lender_git, "--dissociate" }, .references = &.{.{ .path = lender_git }}, .dissociate = true },
        .{ .git_args = &.{ "--reference-if-able", missing, "--reference", lender }, .references = &.{ .{ .path = missing, .if_able = true }, .{ .path = lender } } },
        .{ .git_args = &.{ "--reference", missing }, .references = &.{.{ .path = missing }}, .refused = error.ReferenceNotFound },
        .{ .git_args = &.{ "--reference", shallow }, .references = &.{.{ .path = shallow }}, .refused = error.ReferenceShallow },
        .{ .git_args = &.{ "--reference", root_path }, .references = &.{.{ .path = root_path }}, .refused = error.ReferenceNotARepository },
    };
    for (cases, 0..) |case, number| {
        var by_git = try Twin.init(gpa, io);
        defer by_git.deinit(gpa, io);
        var by_relic = try Twin.init(gpa, io);
        defer by_relic.deinit(gpa, io);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "-c", ssh_setting, "clone", "-q" });
        try argv.appendSlice(gpa, case.git_args);
        try argv.appendSlice(gpa, &.{ served, by_git.path });
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        const made = clone(gpa, io, served, by_relic.dir, .{ .who = test_who, .programs = .{ .environ = &env }, .config = &settings, .reference = case.references, .dissociate = case.dissociate, .warnings = &warnings });
        if (case.refused) |err| {
            try testing.expectError(error.GitFailed, testremote.gitInputEnv(gpa, io, by_git.tmp.dir, &env, argv.items, "", false));
            try testing.expectError(err, made);
            continue;
        }
        const out = try git(gpa, io, &env, by_git.tmp.dir, argv.items);
        gpa.free(out);
        var repo = try made;
        repo.deinit(io);
        try expectSameClone(gpa, io, &env, by_git.dir, by_relic.dir, false);
        // The same lenders, and as few objects of its own.
        const alternates_theirs = by_git.dir.readFileAlloc(io, ".git/objects/info/alternates", gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => try gpa.dupe(u8, "(none)"),
            else => return e,
        };
        defer gpa.free(alternates_theirs);
        const alternates_ours = by_relic.dir.readFileAlloc(io, ".git/objects/info/alternates", gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => try gpa.dupe(u8, "(none)"),
            else => return e,
        };
        defer gpa.free(alternates_ours);
        try testing.expectEqualStrings(alternates_theirs, alternates_ours);
        const theirs = try objectsHeld(gpa, io, &env, by_git.dir);
        const ours = try objectsHeld(gpa, io, &env, by_relic.dir);
        try testing.expectEqual(.{ number, theirs }, .{ number, ours });
        if (case.references.len > 1) try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
    }
}

/// How many objects a repository holds itself, in packs and loose.
fn objectsHeld(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir) !u64 {
    const out = try git(gpa, io, env, dir, &.{ "count-objects", "-v" });
    defer gpa.free(out);
    var total: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        for ([_][]const u8{ "count: ", "in-pack: " }) |key| if (std.mem.startsWith(u8, line, key)) {
            total += decimal.digits(u64, line[key.len..]) orelse return error.TestUnexpectedResult;
        };
    }
    return total;
}
