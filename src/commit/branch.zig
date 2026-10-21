//! `git branch <name> <start>` and `git branch --set-upstream-to`: a
//! branch made where a revision points, and the branch it tracks.
//!
//! It is git 2.55's `branch.c`. The start is any revision, and when it
//! names a branch -- a local one, or a remote-tracking one some remote's
//! fetch refspec maps to -- the new branch may be set up to track it, as
//! `branch.autoSetupMerge` says: `true` (git's default) for a
//! remote-tracking start, `always` for any branch, `inherit` to copy the
//! start branch's own upstream, `simple` for a remote-tracking start of
//! the same name, `false` for none. Tracking writes `branch.<name>.remote`
//! (`.` for a local start) and `branch.<name>.merge`, and
//! `branch.<name>.rebase` where `branch.autoSetupRebase` asks for it. The
//! ref is written with git's `branch: Created from <start>` reflog line,
//! or `branch: Reset to <start>` when an existing branch is forced.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const head_mod = @import("../repo/head.zig");
const refs_mod = @import("../refs/refs.zig");
const config_mod = @import("../config/config.zig");
const ref_names = @import("../names.zig").ref;
const remote_mod = @import("../wire.zig").remote;
const rev_parse = @import("../rev_walk/rev_parse.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from making a branch or setting its upstream.
pub const Error = error{
    /// "'<name>' is not a valid branch name".
    InvalidBranchName,
    /// "a branch named '<name>' already exists", without `force`.
    BranchExists,
    /// "cannot force update the branch '<name>' used by worktree at
    /// '<path>'".
    BranchCheckedOut,
    /// The start names no object: "not a valid object name".
    NotAValidObjectName,
    /// The start names more than one ref: "ambiguous object name".
    AmbiguousObjectName,
    /// The start is no commit: "not a valid branch point".
    NotAValidBranchPoint,
    /// Tracking asked for by name and the start is not a branch:
    /// "cannot set up tracking information; starting point '<start>' is
    /// not a branch".
    UpstreamNotBranch,
    /// More than one remote's fetch refspecs map to the start: "not
    /// tracking: ambiguous information for ref".
    AmbiguousUpstream,
    /// `branch.autoSetupMerge` or `branch.autoSetupRebase` holds a value
    /// git dies on.
    InvalidBranchSetting,
    /// The branch to set an upstream for does not exist.
    NoSuchBranch,
} || rev_parse.Error || head_mod.CheckedOutError || remote_mod.Error || Repository.WriteConfigError || refs_mod.TransactionError;

/// How a new branch takes an upstream: git's `branch_track`.
pub const Track = enum {
    /// None.
    never,
    /// When the start is a remote-tracking branch: `branch.autoSetupMerge`
    /// `true`, git's default.
    remote,
    /// When the start is any branch: `always`.
    always,
    /// The start branch's own upstream: `inherit`.
    inherit,
    /// When the start is a remote-tracking branch of the same name:
    /// `simple`.
    simple,
    /// `--track`: the start must be a branch.
    explicit,
};

/// How the branch is made.
pub const Options = struct {
    /// Who the reflog line is by.
    who: object.Signature,
    /// `-f`: a branch that exists is moved to the start, unless a worktree
    /// has it checked out.
    force: bool = false,
    /// `--track[=inherit]` or `--no-track`; `null` takes
    /// `branch.autoSetupMerge`.
    track: ?Track = null,
    /// `--dry-run`: everything checked as it would be, and nothing
    /// written.
    dry_run: bool = false,
};

/// The upstream a branch was set to track.
pub const Upstream = struct {
    /// `branch.<name>.remote`: a remote, or `.` for this repository.
    remote: []const u8,
    /// `branch.<name>.merge`, each a ref on that remote.
    merge: []const []const u8,
    /// Whether `branch.<name>.rebase` was set to `true`.
    rebase: bool,
};

/// What `create` made.
pub const Created = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator.State,
    gpa: Allocator,
    oid: Oid,
    /// The upstream set up, or `null` for none.
    upstream: ?Upstream,

    pub fn deinit(c: *Created) void {
        var arena = c.arena.promote(c.gpa);
        arena.deinit();
        c.* = undefined;
    }
};

/// The branch to make, and where.
pub const Inputs = struct {
    /// The new branch's short name.
    name: []const u8,
    /// Any revision; a branch's name, to track it.
    start: []const u8,
};

/// git's `create_branch`: the branch `inputs.name` made at `inputs.start`,
/// and its upstream set up as `options.track` or `branch.autoSetupMerge`
/// says.
pub fn create(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!Created {
    const name = inputs.name;
    const start = inputs.start;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    const how = options.track orelse try configuredTrack(repo.configuration());
    const autorebase = try configuredRebase(repo.configuration());

    const ref = try branchRef(a, name);
    const exists = (try repo.refStore().resolve(a, io, ref)) != null;
    if (exists) {
        if (!options.force) return error.BranchExists;
        const busy = try head_mod.checkedOutBranches(a, io, repo);
        if (busy.get(ref) != null) return error.BranchCheckedOut;
    }
    const at = try resolveStart(a, io, repo, start, how == .explicit);
    if (options.dry_run) return .{ .arena = arena_state.state, .gpa = gpa, .oid = at.oid, .upstream = null };

    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update(ref, .{ .direct = at.oid }, if (exists) .any else .must_not_exist);
    const message = try a.print("branch: {s} {s}", .{ if (exists) "Reset to" else "Created from", start });
    try tx.commit(io, .{ .who = options.who, .message = message, .policy = repo.reflogPolicy() });

    var upstream: ?Upstream = null;
    if (at.ref) |orig| if (how != .never) {
        upstream = try setupTracking(a, io, repo, name, orig, how, autorebase);
    };
    return .{ .arena = arena_state.state, .gpa = gpa, .oid = at.oid, .upstream = upstream };
}

/// git's `dwim_and_setup_tracking` for `--set-upstream-to`: the existing
/// branch `name` set to track `upstream`, which must be a branch. The
/// result is `arena`'s.
pub fn setUpstream(arena: Allocator, io: Io, repo: *Repository, name: []const u8, upstream: []const u8) Self.Error!?Upstream {
    const ref = try branchRef(arena, name);
    if ((try repo.refStore().resolve(arena, io, ref)) == null) return error.NoSuchBranch;
    const autorebase = try configuredRebase(repo.configuration());
    const at = try resolveStart(arena, io, repo, upstream, true);
    return setupTracking(arena, io, repo, name, at.ref.?, .explicit, autorebase);
}

/// A branch to set an upstream for: `name`, to track the ref `orig` as
/// `how` says.
pub const Tracking = struct { name: []const u8, orig: []const u8, how: Track };

/// git's `setup_tracking`: the existing branch set up to track as
/// `tracking` says, `branch.autoSetupRebase` read. `null` where `how` sets
/// up none. The result is `arena`'s.
pub fn setTracking(arena: Allocator, io: Io, repo: *Repository, tracking: Tracking) Self.Error!?Upstream {
    if (tracking.how == .never) return null;
    return setupTracking(arena, io, repo, tracking.name, tracking.orig, tracking.how, try configuredRebase(repo.configuration()));
}

/// `strbuf_check_branch_ref`: `refs/heads/<name>`, where that is a ref
/// name and the name neither starts with `-` nor is `HEAD`.
fn branchRef(a: Allocator, name: []const u8) Self.Error![]const u8 {
    if (name.len == 0 or name[0] == '-' or std.mem.eql(u8, name, "HEAD")) return error.InvalidBranchName;
    const ref = try a.print("refs/heads/{s}", .{name});
    if (!ref_names.checkFormat(ref, .{})) return error.InvalidBranchName;
    return ref;
}

/// `branch.autoSetupMerge`: a boolean, `always`, `inherit` or `simple`.
pub fn configuredTrack(config: *const config_mod.Config) Self.Error!Track {
    const entry = config.find("branch.autosetupmerge") orelse return .remote;
    const value = entry.value orelse return .remote;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "inherit")) return .inherit;
    if (std.mem.eql(u8, value, "simple")) return .simple;
    return if (config_mod.parseBool(value) catch return error.InvalidBranchSetting) .remote else .never;
}

/// When `branch.autoSetupRebase` sets `branch.<name>.rebase`.
const AutoRebase = enum { never, local, remote, always };

fn configuredRebase(config: *const config_mod.Config) Self.Error!AutoRebase {
    const entry = config.find("branch.autosetuprebase") orelse return .never;
    const value = entry.value orelse return error.InvalidBranchSetting;
    return std.meta.stringToEnum(AutoRebase, value) orelse error.InvalidBranchSetting;
}

/// Where a branch starts, and the branch it starts from when it starts
/// from one that can be tracked.
pub const Start = struct { oid: Oid, ref: ?[]const u8 };

/// git's `dwim_branch_start`: the commit `start` names, and the branch it
/// is when it is one a branch can track; `explicit`, as `--track`, it must
/// be one. The ref is `a`'s.
pub fn resolveStart(a: Allocator, io: Io, repo: *Repository, start: []const u8, explicit: bool) Self.Error!Start {
    _ = rev_parse.resolve(a, io, repo, start) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return if (explicit) error.UpstreamNotBranch else error.NotAValidObjectName,
    };
    var real_ref: ?[]const u8 = null;
    if (try rev_parse.dwimRef(a, io, repo, start)) |found| {
        if (found.count > 1) return error.AmbiguousObjectName;
        real_ref = found.ref;
        // A ref that is neither a branch nor a remote's tracking ref.
        if (!std.mem.startsWith(u8, found.ref, "refs/heads/") and !try isRemoteTracking(a, repo, found.ref)) {
            if (explicit) return error.UpstreamNotBranch;
            real_ref = null;
        }
    } else if (explicit) return error.UpstreamNotBranch;
    const commit = rev_parse.resolve(a, io, repo, try a.print("{s}^{{commit}}", .{start})) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.NotAValidBranchPoint,
    };
    return .{ .oid = commit, .ref = real_ref };
}

/// Whether some remote's fetch refspecs map to `ref`: git's
/// `validate_remote_tracking_branch`.
fn isRemoteTracking(a: Allocator, repo: *Repository, ref: []const u8) Self.Error!bool {
    for (try remote_mod.names(a, repo.configuration())) |name| {
        var remote = try remote_mod.Remote.get(a, repo.configuration(), repo.objectFormat(), name);
        defer remote.deinit();
        if (try remote.sourceOf(a, ref)) |_| return true;
    }
    return false;
}

/// git's `setup_tracking` and `install_branch_config_multiple_remotes`.
fn setupTracking(a: Allocator, io: Io, repo: *Repository, name: []const u8, orig: []const u8, track: Track, autorebase: AutoRebase) Self.Error!?Upstream {
    const config = repo.configuration();
    var remote_name: ?[]const u8 = null;
    var sources: std.ArrayList([]const u8) = .empty;
    var matches: usize = 0;
    if (track != .inherit) {
        // `find_tracked_branch`, each remote in turn.
        for (try remote_mod.names(a, config)) |each| {
            var remote = try remote_mod.Remote.get(a, config, repo.objectFormat(), each);
            defer remote.deinit();
            const source = (try remote.sourceOf(a, orig)) orelse continue;
            matches += 1;
            if (matches == 1) {
                remote_name = try a.dupe(u8, each);
                try sources.append(a, source);
            }
        }
    } else {
        // `inherit_tracking`: the start branch's own settings; none is no
        // tracking, with git's warning.
        const short = if (std.mem.startsWith(u8, orig, "refs/heads/")) orig["refs/heads/".len..] else orig;
        var from = try remote_mod.Branch.get(a, config, short);
        defer from.deinit();
        const remote = from.remote orelse return null;
        if (from.merge.len == 0 or from.merge[0].len == 0) return null;
        remote_name = try a.dupe(u8, remote);
        for (from.merge) |m| try sources.append(a, try a.dupe(u8, m));
    }
    if (matches == 0) switch (track) {
        .always, .explicit, .inherit => {},
        else => return null,
    };
    if (matches > 1) return error.AmbiguousUpstream;
    if (track == .simple) {
        const tracked = if (std.mem.startsWith(u8, sources.items[0], "refs/heads/")) sources.items[0]["refs/heads/".len..] else return null;
        if (!std.mem.eql(u8, tracked, name)) return null;
    }
    if (sources.items.len == 0) try sources.append(a, orig);

    // A branch is not set up to track itself.
    if (sources.items.len == 1 and remote_name == null and std.mem.startsWith(u8, sources.items[0], "refs/heads/") and
        std.mem.eql(u8, sources.items[0]["refs/heads/".len..], name)) return null;
    const rebase = switch (autorebase) {
        .never => false,
        .local => remote_name == null,
        .remote => remote_name != null,
        .always => true,
    };
    var edits: std.ArrayList(Repository.ConfigEdit) = .empty;
    try edits.append(a, .{ .set = .{ .name = try a.print("branch.{s}.remote", .{name}), .value = remote_name orelse "." } });
    const merge_key = try a.print("branch.{s}.merge", .{name});
    try edits.append(a, .{ .unset = .{ .name = merge_key } });
    for (sources.items) |source| try edits.append(a, .{ .add = .{ .name = merge_key, .value = source } });
    if (rebase) try edits.append(a, .{ .set = .{ .name = try a.print("branch.{s}.rebase", .{name}), .value = "true" } });
    _ = try repo.writeConfig(io, .local, edits.items, .{});
    return .{ .remote = remote_name orelse ".", .merge = sources.items, .rebase = rebase };
}

/// What `guessRemote` found.
pub const Guess = struct {
    /// The remote-tracking ref the new branch starts from and tracks, in
    /// the caller's allocator; `null` when there is none to choose.
    tracking: ?[]const u8 = null,
    /// What `tracking` points at.
    oid: ?Oid = null,
    /// How many remotes have one: more than one, with none chosen, is
    /// git's "matched multiple remote tracking branches".
    matches: usize = 0,
};

/// git's `unique_tracking_name`, which `git checkout <name>`, `git switch
/// <name>` and `git worktree add` (under `worktree.guessRemote`) second
/// guess a branch no local ref has by: each remote, in the configuration's
/// order, whose fetch refspecs map `refs/heads/<name>` to a ref that is
/// here. One is the answer; of several, the one `checkout.defaultRemote`
/// names; else none, `matches` saying how many there were.
pub fn guessRemote(gpa: Allocator, io: Io, repo: *Repository, name: []const u8) Self.Error!Guess {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const a = arena_instance.allocator();
    const config = repo.configuration();
    const default_remote = config.get("checkout.defaultremote");
    const source = try std.mem.concat(a, u8, &.{ "refs/heads/", name });
    const Found = struct { ref: []const u8, oid: Oid };
    var first: ?Found = null;
    var chosen: ?Found = null;
    var matches: usize = 0;
    for (try remote_mod.names(a, config)) |each| {
        var remote = try remote_mod.Remote.get(a, config, repo.objectFormat(), each);
        defer remote.deinit();
        const tracking = (try remote.trackingRef(a, source)) orelse continue;
        const resolved = (try repo.refStore().resolve(a, io, tracking)) orelse continue;
        matches += 1;
        if (default_remote) |wanted| if (std.mem.eql(u8, each, wanted)) {
            chosen = .{ .ref = tracking, .oid = resolved.oid };
        };
        if (first == null) first = .{ .ref = tracking, .oid = resolved.oid };
    }
    const found = if (matches == 1) first else chosen;
    const pick = found orelse return .{ .matches = matches };
    return .{ .tracking = try gpa.dupe(u8, pick.ref), .oid = pick.oid, .matches = matches };
}

/// Whether a branch no local ref has is second guessed from the remotes:
/// `checkout.guess` for `checkout` and `switch` (on unless set), and
/// `worktree.guessRemote` for `worktree add` (off unless set).
pub const Guessing = struct { checkout: bool, worktree: bool };

/// `Guessing` as the configuration says.
pub fn guessing(config: *const config_mod.Config) config_mod.ValueError!Guessing {
    return .{
        .checkout = try config.getBool("checkout.guess", true),
        .worktree = try config.getBool("worktree.guessremote", false),
    };
}
