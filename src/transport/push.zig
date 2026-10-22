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

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const gitdate = @import("../text.zig").date;
const httpsettings_mod = @import("../wire.zig").http_settings;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const rev_walk = @import("../walk/walk.zig");
const refspec_mod = @import("../wire.zig").refspec;
const ref_names = @import("../names.zig").ref;
const remote_mod = @import("../wire.zig").remote;
const branch_mod = @import("../commit/branch.zig");
const program = @import("../process.zig").program;
const protocol = @import("../wire.zig").protocol;
const transport = @import("transport.zig");
const send_pack = @import("../wire.zig").send_pack;
const odb_mod = @import("../odb/odb.zig");
const object_walk = @import("../walk/object/walk.zig");
const credential = @import("../wire.zig").credential;
const auth = @import("../wire.zig").auth;
const warning = @import("../report.zig").warning;
const config_mod = @import("../config/config.zig");
const signing = @import("../object/signing.zig");
const url_mod = @import("../wire.zig").url;
const progress_mod = @import("../report.zig").progress;

const builtin = @import("builtin");

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
    /// on one.
    NoPushDestination,
    /// `push.default` asks for the current branch's upstream, and it has
    /// none: git's "The current branch has no upstream branch".
    NoUpstreamBranch,
    /// `push.default=simple`, to the branch's own remote, and its upstream
    /// has another name: git's "The upstream branch of your current branch
    /// does not match the name of your current branch".
    UpstreamNameDiffers,
    /// The current branch has more than one upstream branch.
    MultipleUpstreams,
    /// `push.default=upstream` to a remote that is not the branch's own.
    NotUpstreamRemote,
    /// The `pre-push` hook refused the push.
    PrePushRefused,
    /// The push is to be signed and the server takes no push
    /// certificate: git's "the receiving end does not support --signed
    /// push".
    SignedPushUnsupported,
    /// The server asked for a certificate over a nonce git refuses to
    /// sign: longer than 255 bytes, or holding other than letters, digits
    /// and `-._/+=`.
    InvalidPushCertNonce,
    /// `push.gpgSign` is neither a boolean nor `if-asked`.
    InvalidPushGpgSign,
    /// `push.recurseSubmodules` is not `check`, `on-demand`, `only` or a
    /// false boolean: git's "bad push.recursesubmodules argument".
    InvalidPushRecurse,
    /// Submodules hold commits the push records that no remote of theirs
    /// has: git's "The following submodule paths contain changes that can
    /// not be found on any remote" and "Aborting.". Each is a warning.
    UnpushedSubmodules,
    /// A submodule's push failed: git's "failed to push all needed
    /// submodules". Each is a warning.
    SubmodulePushFailed,
    /// The remote is not configured in a submodule that needs pushing:
    /// git's "remote '<name>' not configured".
    SubmoduleRemoteNotConfigured,
    /// A refspec's `HEAD` names, in a submodule, a branch other than the
    /// superproject's, or none: git's "HEAD does not match the named
    /// branch in the superproject".
    SubmoduleHeadMismatch,
    /// A refspec's source names no single ref in a submodule: git's "src
    /// refspec '<src>' must name a ref".
    SubmoduleRefspecUnmatched,
    /// `atomic` across several remotes: git's "--atomic can only be used
    /// when pushing to one remote".
    AtomicAcrossRemotes,
} || sub_changes.Error || signing.Error || config_mod.ValueError || BeforeSendError || transport.Error || remote_mod.Error || refs_mod.TransactionError || object_walk.Error || rev_walk.Error || branch_mod.Error || refs_mod.Store.ReadLogError;

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

pub const BeforeSendError = Allocator.Error || Io.Cancelable || error{BeforeSendFailed};
pub const BeforeSend = struct {
    context: *anyopaque,
    run: *const fn (Allocator, Io, *anyopaque, *Repository, BeforeSendInput) BeforeSendError!void,
};
pub const BeforeSendInput = struct {
    remote: []const u8,
    refs: []const []const u8,
    objects: []const odb_mod.PackEntry,
};

/// A branch set to track the branch it was pushed to.
pub const Tracked = struct {
    branch: []const u8,
    upstream: branch_mod.Upstream,
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
    /// `--push-option` values for the remote's hooks; `null` takes
    /// `push.pushOption`, an empty value clearing those before it.
    push_options: ?[]const []const u8 = null,
    /// `--follow-tags`: the annotated tags the remote lacks, on commits it
    /// will have, pushed too; `null` takes `push.followTags`.
    follow_tags: ?bool = null,
    /// `--force-if-includes`: a lease that expects the remote-tracking
    /// ref's value also asks that the remote's value be in the local ref's
    /// log, or reachable from what it names; `null` takes
    /// `push.useForceIfIncludes`. Without a lease it does nothing.
    force_if_includes: ?bool = null,
    /// `--set-upstream`: each branch pushed to a branch tracks it after.
    /// `push.autoSetupRemote` sets it for a default push of a branch with
    /// no upstream.
    set_upstream: bool = false,
    /// Work everything out and send nothing.
    dry_run: bool = false,
    /// `--recurse-submodules`: whether the submodules' commits the push
    /// records must be on a remote of theirs (`check`), are pushed first
    /// (`on_demand`), or are pushed alone (`only`), as git's
    /// `transport_push` has it. `null` takes `push.recurseSubmodules` or
    /// `submodule.recurse` (`on_demand` when true), the later set.
    recurse_submodules: ?Recurse = null,
    /// git's `--recurse-submodules=only-is-on-demand`, what a
    /// superproject's push asks of a submodule's: `only` from the
    /// configuration is taken as `on_demand`, with git's warning, since
    /// the superproject needs the submodule's own refs pushed too.
    in_superproject: bool = false,
    /// Sign the push with a certificate the server keeps: `--signed`.
    /// `null` takes `push.gpgSign`. Signing runs `signing`'s programs,
    /// which needs `programs`.
    signed: ?send_pack.PushCert = null,
    /// Who the remote-tracking refs' log entries are written as, and when.
    who: object.Signature,
    pre_push: ?PrePush = null,
    /// Content preparation by an operation owner, before any ref is sent.
    before_send: ?BeforeSend = null,
    programs: ?program.Programs = null,
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
    /// Whether the person named this remote themselves:
    /// `transport.Options.from_user`.
    /// A submodule's clone and fetch pass false, so a `.gitmodules` cannot
    /// reach a repository on this machine unless `protocol.file.allow` says
    /// it may.
    from_user: ?bool = null,
};

/// git's `--recurse-submodules` values for a push.
pub const Recurse = enum { no, check, on_demand, only };

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
    /// The remote's reason, for `rejected_by_remote`, or what it added to
    /// an update it took.
    message: ?[]const u8 = null,
    /// What the remote said each update it took became, when it said more
    /// than the ref: a `proc-receive` hook's or a remote helper's `option`
    /// lines, each a line of its own in git's report.
    updates: []const send_pack.RefReport.Update = &.{},

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
        /// Not sent: the remote's ref moved since it was last fetched, and
        /// the push asked for it to include what it holds (a remote
        /// helper's `remote ref updated since checkout`).
        rejected_remote_updated,
        /// Sent, and the remote did not say what became of it: git's
        /// "remote failed to report status".
        unreported,
        /// A remote helper had nothing to match it to: git's `[no match]`,
        /// which is no failure.
        no_match,
        /// Not applied: the push was atomic and another ref was refused.
        atomic_failed,
        /// Worked out and not sent, for a dry run.
        not_sent,
    };

    /// Whether this ref was refused.
    pub fn rejected(r: RefResult) bool {
        return switch (r.status) {
            .ok, .up_to_date, .not_sent, .no_match => false,
            else => true,
        };
    }
};

/// What a push did.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    refs: []const RefResult,
    /// The branches `set_upstream` set to track what they were pushed to.
    upstreams: []const Tracked = &.{},
    /// Whether the remote took the pack.
    unpack_ok: bool = true,
    /// Why it did not.
    unpack_message: ?[]const u8 = null,
    /// A remote's report had an `option` line with no `ok` before it, which
    /// git reports and fails the push for, keeping what the rest said
    /// (`send_pack.Report.stray_option`).
    stray_option: bool = false,

    /// Release everything.
    pub fn deinit(outcome: *Outcome) void {
        outcome.arena.deinit();
        outcome.* = undefined;
    }

    /// Whether any ref was refused — git's exit status of 1.
    pub fn anyRejected(outcome: *const Outcome) bool {
        if (!outcome.unpack_ok or outcome.stray_option) return true;
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
pub fn push(gpa: Allocator, io: Io, repo: *Repository, remote_name: []const u8, options: Options) Self.Error!Outcome {
    var outcome: Outcome = .{ .arena = .init(gpa), .refs = &.{} };
    errdefer outcome.arena.deinit();
    const arena = outcome.arena.allocator();

    var remote = try remote_mod.Remote.get(gpa, repo.configuration(), repo.objectFormat(), remote_name);
    defer remote.deinit();

    var specs: std.ArrayList(Refspec) = .empty;
    for (options.refspecs) |text| {
        try specs.append(arena, Refspec.parse(try arena.dupe(u8, text), .push, repo.objectFormat()) catch return error.InvalidRefspec);
    }
    if (specs.items.len == 0) {
        for (remote.push) |spec| try specs.append(arena, spec);
    }
    var settled = options;
    if (specs.items.len == 0) {
        if (try defaultRefspecs(arena, gpa, io, repo, &remote, remote_name, &specs)) settled.set_upstream = true;
    }
    settled.push_options = options.push_options orelse try remote_mod.resetList(arena, repo.configuration(), "push.pushoption");
    settled.follow_tags = options.follow_tags orelse try repo.configuration().getBool("push.followtags", false);
    settled.force_if_includes = options.force_if_includes orelse try repo.configuration().getBool("push.useforceifincludes", false);
    settled.recurse_submodules = try recursion(repo.configuration(), options);

    var results: std.ArrayList(RefResult) = .empty;
    for (remote.push_urls) |url| {
        try pushTo(arena, gpa, io, repo, &remote, try arena.dupe(u8, url), specs.items, settled, &results, &outcome);
    }
    outcome.refs = results.items;
    return outcome;
}

/// git 2.55's remotes for `git push <name>`: those `remotes.<name>`
/// lists, split at blanks, in order and as often as listed; else the
/// name itself, a remote or a URL. `arena`'s.
pub fn remotesToPush(arena: Allocator, config: *const config_mod.Config, name: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = config.iterate(&.{try arena.print("remotes.{s}", .{name})});
    while (it.next()) |entry| {
        var words = std.mem.tokenizeAny(u8, entry.value orelse "", " \t\n");
        while (words.next()) |word| try out.append(arena, word);
    }
    if (out.items.len == 0) try out.append(arena, name);
    return out.items;
}

/// One remote's part of `pushMany`: what came of it, or why not.
pub const Pushed = union(enum) {
    pushed: Outcome,
    failed: Self.Error,
};

/// What `pushMany` did, remote by remote, in the order given.
pub const Many = struct {
    pub const Error = Self.Error;

    names: []const []const u8,
    results: []Pushed,
    gpa: Allocator,

    pub fn deinit(m: *Many) void {
        for (m.results) |*r| switch (r.*) {
            .pushed => |*outcome| outcome.deinit(),
            .failed => {},
        };
        m.gpa.free(m.results);
        m.* = undefined;
    }

    /// Whether a remote's push failed or refused a ref: git's "could not
    /// push to <name>" and its exit status.
    pub fn anyFailed(m: *const Many) bool {
        for (m.results) |r| switch (r) {
            .pushed => |outcome| if (outcome.anyRejected()) return true,
            .failed => return true,
        };
        return false;
    }
};

/// git 2.55's `push_multiple`: each of `names` pushed in turn as `push`
/// pushes it, a failure noted and the rest still pushed; `atomic` across
/// more than one is `error.AtomicAcrossRemotes`.
pub fn pushMany(gpa: Allocator, io: Io, repo: *Repository, names: []const []const u8, options: Options) Self.Error!Many {
    if (options.atomic and names.len > 1) return error.AtomicAcrossRemotes;
    const results = try gpa.alloc(Pushed, names.len);
    errdefer gpa.free(results);
    for (names, 0..) |name, i| {
        results[i] = if (push(gpa, io, repo, name, options)) |outcome| .{ .pushed = outcome } else |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| {
                for (results[0..i]) |*done| switch (done.*) {
                    .pushed => |*o| o.deinit(),
                    .failed => {},
                };
                return e;
            },
            else => .{ .failed = err },
        };
    }
    return .{ .names = names, .results = results, .gpa = gpa };
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
    var session = try openSession(gpa, io, repo, remote, url, options);
    defer session.deinit(io);
    var remote_refs = try session.listRefs(gpa, io, &.{});
    defer remote_refs.deinit();

    var local_refs = try repo.refStore().list(gpa, io, "refs/");
    defer local_refs.deinit();

    const updates = try matchRefs(arena, gpa, io, repo, &local_refs, &remote_refs, specs, options.follow_tags.?);

    // Judge each before anything is sent.
    const results = try judgeAll(arena, gpa, io, repo, remote, url, updates, &remote_refs, options);
    assert(results.len == updates.len);

    var commands: std.ArrayList(send_pack.Command) = .empty;
    // What a remote helper is told beside: the local ref and the `+`.
    var sources: std.ArrayList(?[]const u8) = .empty;
    var forced: std.ArrayList(bool) = .empty;
    for (try sendOrder(arena, results, &remote_refs)) |i| {
        const r = results[i];
        const u = updates[i];
        if (r.status != .ok) continue;
        try commands.append(arena, .{ .name = r.remote_ref, .old = r.old, .new = r.new });
        try sources.append(arena, r.local_ref);
        try forced.append(arena, u.force or options.force);
    }

    if (options.pre_push) |hook| try runPrePush(arena, hook, remote.name orelse url, url, results);
    const recurse = options.recurse_submodules.?;
    if (recurse != .no and repo.workDirectory() != null) try checkSubmodules(arena, gpa, io, repo, .{ .remote = remote.name orelse url, .specs = specs, .results = results }, options);
    // `only` sends nothing of its own, and moves no remote-tracking ref.
    if (recurse == .only) {
        for (results) |*r| if (r.status == .ok) {
            r.status = .not_sent;
        };
        if (options.set_upstream) try setUpstreams(arena, gpa, io, repo, remote.name orelse url, results, outcome);
        try all_results.appendSlice(arena, results);
        return;
    }

    // Whether the server takes a signed push is asked before anything is
    // sent, a dry run's included, as git's send-pack asks it.
    var certificate_nonce: ?[]const u8 = null;
    var helper_cert: send_pack.PushCert = .never;
    const signed = options.signed orelse try pushCertSetting(repo.configuration());
    if (signed != .never) switch (session.certOffer()) {
        .helper => helper_cert = signed,
        .nonce => |offered| if (offered) |nonce| {
            if (!validNonce(nonce)) return error.InvalidPushCertNonce;
            certificate_nonce = nonce;
        } else switch (signed) {
            .always => return error.SignedPushUnsupported,
            .if_asked => if (options.warnings) |sink| try sink.add(.push_cert_not_asked),
            .never => unreachable,
        },
    };

    if (options.dry_run) {
        for (results) |*r| {
            if (r.status == .ok) r.status = .not_sent;
        }
        try all_results.appendSlice(arena, results);
        return;
    }

    if (commands.items.len != 0) {
        const certificate = if (certificate_nonce) |nonce|
            try pushCertificate(arena, gpa, io, repo, url, nonce, commands.items, options)
        else
            null;
        const commons = if (try repo.configuration().getBool("push.negotiate", false)) try negotiatedCommons(arena, gpa, io, repo, remote, url, commands.items, options) else &.{};
        try send(arena, gpa, io, repo, &session, remote.name orelse url, remote_refs.refs, commons, .{
            .commands = commands.items,
            .objects = &.{},
            .atomic = options.atomic,
            .push_options = options.push_options.?,
            .who = options.who,
            .progress = options.progress,
            .sources = sources.items,
            .force = forced.items,
            .certificate = certificate,
            .push_cert = helper_cert,
        }, options, results, outcome);
    }

    // What the remote took moves its remote-tracking ref, as git moves it.
    if (remote.name != null) {
        for (results) |r| {
            if (r.status != .ok and r.status != .up_to_date) continue;
            try updateTracking(gpa, io, repo, remote, r, options.who);
        }
    }
    if (options.set_upstream) try setUpstreams(arena, gpa, io, repo, remote.name orelse url, results, outcome);
    try all_results.appendSlice(arena, results);
}

/// `recurse_submodules`, else the later of `push.recurseSubmodules` and
/// `submodule.recurse`; `only` in a submodule's push taken as `on_demand`.
fn recursion(config: *const config_mod.Config, options: Options) Error!Recurse {
    var found: Recurse = .no;
    if (options.recurse_submodules) |r| {
        found = r;
    } else {
        var it = config.iterate(&.{ "push.recursesubmodules", "submodule.recurse" });
        while (it.next()) |entry| {
            const text = entry.value orelse "true";
            if (std.ascii.eqlIgnoreCase(entry.section, "submodule")) {
                found = if (config_mod.parseBool(text) catch return error.MalformedValue) .on_demand else .no;
                continue;
            }
            found = if (config_mod.parseBool(text)) |on| (if (on) return error.InvalidPushRecurse else .no) else |_| if (std.mem.eql(u8, text, "on-demand"))
                .on_demand
            else if (std.mem.eql(u8, text, "check"))
                .check
            else if (std.mem.eql(u8, text, "only"))
                .only
            else
                return error.InvalidPushRecurse;
        }
    }
    if (options.in_superproject and found == .only) {
        try warning.note(options.warnings, .push_recurse_only_on_demand);
        found = .on_demand;
    }
    return found;
}

/// What `checkSubmodules` measures the push by.
const Pushing = struct { remote: []const u8, specs: []const Refspec, results: []const RefResult };

/// git's `transport_push` for the submodules: under `on_demand` and
/// `only`, each that needs it pushed first, after git's push-check in it
/// when the remote is configured; then, under `check`, or those two when
/// something is sent, every submodule's recorded commits on a remote of
/// its own, or `error.UnpushedSubmodules`.
fn checkSubmodules(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, p: Pushing, options: Options) Error!void {
    const recurse = options.recurse_submodules.?;
    var commits: std.ArrayList(Oid) = .empty;
    for (p.results) |r| if (!r.new.isZero()) try commits.append(arena, r.new);
    const range: sub_changes.PushRange = .{ .commits = commits.items, .remote = p.remote };
    if (recurse == .on_demand or recurse == .only) {
        const needs = try sub_changes.unpushedSubmodules(arena, gpa, io, repo, range);
        if (needs.len != 0) try pushSubmodules(arena, gpa, io, repo, needs, p, options);
    }
    if (recurse == .check or !options.dry_run) {
        const left = try sub_changes.unpushedSubmodules(arena, gpa, io, repo, range);
        for (left) |u| try warning.note(options.warnings, .{ .submodule_unpushed = u.path });
        if (left.len != 0) return error.UnpushedSubmodules;
    }
}

/// git's `push_unpushed_submodules`: with a configured remote, the
/// push-check in each first, then each pushed to that remote with the
/// push's refspecs -- else to its own default, as a plain `git push` --
/// with the push's options and `in_superproject`.
fn pushSubmodules(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, needs: []const sub_changes.Unpushed, p: Pushing, options: Options) Error!void {
    const configured = remote_mod.isConfigured(repo.configuration(), p.remote);
    var raw: std.ArrayList([]const u8) = .empty;
    for (p.specs) |spec| try raw.append(arena, try refspecText(arena, spec));
    if (configured) {
        const head = try headName(gpa, io, repo);
        defer gpa.free(head);
        for (needs) |u| {
            var sub = (try submodule.openRepository(gpa, io, repo, .{ .path = u.path, .name = u.name }, .{})) orelse continue;
            defer sub.deinit(io);
            try pushCheck(gpa, io, &sub, .{ .head = head, .remote = p.remote, .specs = p.specs });
        }
    }
    var failed = false;
    for (needs) |u| {
        var sub = (try submodule.openRepository(gpa, io, repo, .{ .path = u.path, .name = u.name }, .{})) orelse continue;
        defer sub.deinit(io);
        var tracking = try sub.refStore().list(gpa, io, "refs/remotes/");
        const has_remote = tracking.entries.len != 0;
        tracking.deinit();
        if (!has_remote) continue;
        const target = if (configured) p.remote else try defaultPushRemote(arena, gpa, io, &sub);
        var pushed = push(gpa, io, &sub, target, .{
            .refspecs = if (configured) raw.items else &.{},
            .push_options = options.push_options,
            .dry_run = options.dry_run,
            .in_superproject = true,
            .who = options.who,
            .programs = options.programs,
            .proxy = options.proxy,
            .prompt = options.prompt,
            .auth_failure = options.auth_failure,
            .warnings = options.warnings,
            .progress = options.progress,
            .from_user = options.from_user,
        }) catch {
            try warning.note(options.warnings, .{ .submodule_push_failed = u.path });
            failed = true;
            continue;
        };
        defer pushed.deinit();
        if (pushed.anyRejected()) {
            try warning.note(options.warnings, .{ .submodule_push_failed = u.path });
            failed = true;
        }
    }
    if (failed) return error.SubmodulePushFailed;
}

/// What `HEAD` names, in full, or `HEAD` itself when it is detached.
fn headName(gpa: Allocator, io: Io, repo: *Repository) Error![]u8 {
    if (try repo.refStore().currentBranch(gpa, io)) |short| {
        defer gpa.free(short);
        return gpa.print("refs/heads/{s}", .{short});
    }
    return gpa.dupe(u8, "HEAD");
}

/// The remote a plain `git push` in `repo` goes to: its branch's push
/// remote, else the fallback.
fn defaultPushRemote(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository) Error![]const u8 {
    const config = repo.configuration();
    const current = (try repo.refStore().currentBranch(gpa, io)) orelse return arena.dupe(u8, remote_mod.fallback(config));
    defer gpa.free(current);
    var branch = try remote_mod.Branch.get(gpa, config, current);
    defer branch.deinit();
    return arena.dupe(u8, branch.pushRemote(config));
}

/// The text a refspec was written as.
fn refspecText(arena: Allocator, spec: Refspec) Allocator.Error![]const u8 {
    if (spec.matching) return if (spec.force) "+:" else ":";
    return arena.print("{s}{s}{s}{s}{s}", .{
        if (spec.force) "+" else "",
        if (spec.negative) "^" else "",
        spec.src,
        if (spec.dst != null) ":" else "",
        spec.dst orelse "",
    });
}

/// What a superproject's push asks a submodule to check.
const PushCheck = struct { head: []const u8, remote: []const u8, specs: []const Refspec };

/// git's `submodule--helper push-check`, in `sub`: the remote configured
/// there, and each refspec's source, but a pattern or `:`, one ref of its
/// own -- or `HEAD` on the branch the superproject's `HEAD` is on.
fn pushCheck(gpa: Allocator, io: Io, sub: *Repository, c: PushCheck) Error!void {
    if (!remote_mod.isConfigured(sub.configuration(), c.remote)) return error.SubmoduleRemoteNotConfigured;
    var refs = try sub.refStore().list(gpa, io, "refs/");
    defer refs.deinit();
    for (c.specs) |spec| {
        if (spec.pattern or spec.matching) continue;
        var strong: usize = 0;
        var weak: usize = 0;
        for (refs.entries) |ref| {
            if (refnameMatch(spec.src, ref.name) == 0) continue;
            // git's `count_refspec_match`: a match outside heads and tags,
            // named neither in full nor from below `refs/`, is weak.
            const full = ref.name.len == spec.src.len or spec.src.len + 5 == ref.name.len;
            if (!full and !std.mem.startsWith(u8, ref.name, "refs/heads/") and !std.mem.startsWith(u8, ref.name, "refs/tags/")) weak += 1 else strong += 1;
        }
        const count = if (strong != 0) strong else weak;
        if (count == 1) continue;
        if (count == 0 and std.mem.eql(u8, spec.src, "HEAD")) {
            const head = try headName(gpa, io, sub);
            defer gpa.free(head);
            if (!std.mem.eql(u8, head, "HEAD") and std.mem.eql(u8, head, c.head)) continue;
            return error.SubmoduleHeadMismatch;
        }
        return error.SubmoduleRefspecUnmatched;
    }
}

/// git's `get_commons_through_negotiation` (`push.negotiate`): what a
/// fetch's negotiation with `url` finds the remote has of the history
/// being pushed -- from `remote.<name>.negotiationRestrict`, else from each
/// new value, with `negotiationInclude` -- left out of the pack. Useful and
/// not needed: a negotiation that fails leaves nothing out.
fn negotiatedCommons(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, url: []const u8, commands: []const send_pack.Command, options: Options) Error![]const Oid {
    var restrict: std.ArrayList([]const u8) = .empty;
    if (remote.negotiation_restrict.len != 0) {
        try restrict.appendSlice(arena, remote.negotiation_restrict);
    } else for (commands) |c| {
        if (!c.new.isZero()) try restrict.append(arena, try arena.print("{f}", .{c.new}));
    }
    if (restrict.items.len == 0 and remote.negotiation_include.len == 0) return &.{};
    const acked = fetch_mod.negotiateOnly(gpa, io, repo, url, .{
        .who = options.who,
        .programs = options.programs,
        .proxy = options.proxy,
        .prompt = options.prompt,
        .warnings = options.warnings,
        .from_user = options.from_user,
        .negotiation_restrict = restrict.items,
        .negotiation_include = remote.negotiation_include,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return &.{},
    };
    defer gpa.free(acked);
    return arena.dupe(Oid, acked);
}

/// git's `set_upstreams`: each branch the remote took or had already, to a
/// branch, tracks it -- `HEAD` as the branch it names.
fn setUpstreams(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, remote_name: []const u8, results: []const RefResult, outcome: *Outcome) Error!void {
    var tracked: std.ArrayList(Tracked) = .empty;
    try tracked.appendSlice(arena, outcome.upstreams);
    for (results) |r| {
        if (r.status != .ok and r.status != .up_to_date) continue;
        if (r.new.isZero()) continue;
        var local = r.local_ref orelse continue;
        if (try repo.refStore().read(gpa, io, local)) |value| switch (value) {
            .symbolic => |target| {
                defer gpa.free(target);
                if (std.mem.startsWith(u8, target, "refs/heads/")) local = try arena.dupe(u8, target);
            },
            .direct => {},
        };
        if (!std.mem.startsWith(u8, local, "refs/heads/") or !std.mem.startsWith(u8, r.remote_ref, "refs/heads/")) continue;
        const name = local["refs/heads/".len..];
        const upstream = (try branch_mod.installBranchConfig(arena, io, repo, name, .{ .remote = remote_name, .merge = try arena.dupe([]const u8, &.{r.remote_ref}) })) orelse continue;
        try tracked.append(arena, .{ .branch = name, .upstream = upstream });
    }
    outcome.upstreams = tracked.items;
}

/// `push.gpgSign`, every value read as git's callback reads it: a
/// boolean, or `if-asked`.
fn pushCertSetting(config: *const config_mod.Config) Error!send_pack.PushCert {
    var mode: send_pack.PushCert = .never;
    var it = config.iterate(&.{"push.gpgsign"});
    while (it.next()) |entry| {
        const raw = entry.value orelse {
            mode = .always;
            continue;
        };
        if (config_mod.parseBool(raw)) |on| {
            mode = if (on) .always else .never;
        } else |_| {
            if (!std.ascii.eqlIgnoreCase(raw, "if-asked")) return error.InvalidPushGpgSign;
            mode = .if_asked;
        }
    }
    return mode;
}

/// git's `reject_invalid_nonce`: what a server may ask to have signed.
fn validNonce(nonce: []const u8) bool {
    if (nonce.len >= 256) return false;
    for (nonce) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.findScalar(u8, "-./+=_", c) == null) return false;
    }
    return true;
}

/// git's `generate_push_cert`: who pushes, where, the server's nonce and
/// the push options, then the commands, signed as `signing` signs.
fn pushCertificate(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    url: []const u8,
    nonce: []const u8,
    commands: []const send_pack.Command,
    options: Options,
) Error![]const u8 {
    const programs = options.programs orelse return error.SigningRequiresPrograms;
    var signer = try signing.Signer.init(gpa, io, repo.configuration(), repo.topDirectory(), programs);
    defer signer.deinit();
    const key_id = try signer.keyId(io, options.who);
    defer gpa.free(key_id);
    var cert: std.ArrayList(u8) = .empty;
    const offset = options.who.offset_minutes;
    const magnitude: u32 = @abs(offset);
    try cert.print(arena, "certificate version 0.1\npusher {s} {d} {c}{d:0>2}{d:0>2}\n", .{
        key_id, options.who.when_secs, @as(u8, if (offset < 0) '-' else '+'), magnitude / 60, magnitude % 60,
    });
    if (url.len != 0) {
        // Over HTTP the URL git's send-pack is handed ends in `/`, which
        // remote-curl adds.
        const scheme = if (url_mod.Url.parse(url)) |parsed| parsed.scheme else |_| .local;
        const slash = (scheme == .http or scheme == .https) and !std.mem.endsWith(u8, url, "/");
        const anonymous = try url_mod.anonymize(gpa, url);
        defer gpa.free(anonymous);
        try cert.print(arena, "pushee {s}{s}\n", .{ anonymous, if (slash) "/" else "" });
    }
    if (nonce.len != 0) try cert.print(arena, "nonce {s}\n", .{nonce});
    for (options.push_options orelse &.{}) |option| try cert.print(arena, "push-option {s}\n", .{option});
    try cert.append(arena, '\n');
    for (commands) |c| try cert.print(arena, "{f} {f} {s}\n", .{ c.old, c.new, c.name });
    const signature = try signer.sign(io, cert.items, null, options.who);
    defer gpa.free(signature);
    try cert.appendSlice(arena, signature);
    return cert.items;
}

/// The session a push to `remote` at `url` talks over.
fn openSession(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, url: []const u8, options: Options) Error!transport.Session {
    const session = try transport.Session.open(gpa, io, url, .{ .service = .receive_pack, .kind = repo.objectFormat() }, .{
        .programs = options.programs,
        .config = repo.configuration(),
        .remote_name = remote.name,
        .service_program = remote.receive_pack,
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
    });
    return session;
}

/// What becomes of each update before anything is sent, as git judges it;
/// under `--atomic`, one refusal refuses them all.
fn judgeAll(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    url: []const u8,
    updates: []const Update,
    remote_refs: *const protocol.RefList,
    options: Options,
) Error![]RefResult {
    const results = try arena.alloc(RefResult, updates.len);
    var any_refused = false;
    for (updates, results) |u, *result| {
        const old = if (remote_refs.find(u.remote_ref)) |r| r.oid else Oid.zero(repo.objectFormat());
        result.* = .{
            .url = url,
            .local_ref = u.local_ref,
            .remote_ref = u.remote_ref,
            .old = old,
            .new = u.new,
            .status = .ok,
        };
        try judge(gpa, io, repo, remote, result, .{ .force = u.force or options.force, .leases = options.leases, .if_includes = options.force_if_includes.? });
        if (result.rejected()) any_refused = true;
    }
    if (options.atomic and any_refused) {
        for (results) |*r| {
            if (r.status == .ok) r.status = .atomic_failed;
        }
    }
    return results;
}

/// Show the pre-push hook point what git's pre-push hook is shown: every
/// update not already refused or up to date. `error.PrePushRefused` when
/// it says no.
fn runPrePush(arena: Allocator, hook: PrePush, remote_name: []const u8, url: []const u8, results: []const RefResult) Error!void {
    var lines: std.ArrayList(PrePushUpdate) = .empty;
    for (results) |r| {
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
    if (lines.items.len != 0 and !hook.run(hook.context, remote_name, url, lines.items)) {
        return error.PrePushRefused;
    }
}

/// Send `request`'s commands with the objects the remote lacks, LFS
/// objects first, and mark each result with what the remote said.
fn send(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    session: *transport.Session,
    remote_name: []const u8,
    remote_refs: []const protocol.RemoteRef,
    commons: []const Oid,
    request: transport.Session.PushRequest,
    options: Options,
    results: []RefResult,
    outcome: *Outcome,
) Error!void {
    assert(request.commands.len != 0);
    // A helper is told each command's source and `+` by position.
    assert(request.sources.len == request.commands.len);
    assert(request.force.len == request.commands.len);
    var include: std.ArrayList(Oid) = .empty;
    for (request.commands) |c| {
        if (!c.new.isZero()) try include.append(arena, c.new);
    }
    var exclude: std.ArrayList(Oid) = .empty;
    for (remote_refs) |r| {
        if (r.unborn) continue;
        if (try repo.objectDatabase().exists(io, r.oid)) try exclude.append(arena, r.oid);
    }
    try exclude.appendSlice(arena, commons);
    var objects = try object_walk.missing(gpa, io, repo.objectDatabase(), include.items, .{ .exclude = exclude.items });
    defer objects.deinit();

    var remote_refs_pushed: std.ArrayList([]const u8) = .empty;
    for (request.commands) |c| {
        if (!c.new.isZero()) try remote_refs_pushed.append(arena, c.name);
    }
    if (options.before_send) |prepare| try prepare.run(gpa, io, prepare.context, repo, .{
        .remote = remote_name,
        .refs = remote_refs_pushed.items,
        .objects = objects.entries,
    });

    var with_objects = request;
    with_objects.objects = objects.entries;
    var report = try session.push(gpa, io, repo.objectDatabase(), with_objects);
    defer report.deinit();
    if (!report.unpack_ok) {
        outcome.unpack_ok = false;
        if (report.unpack_message) |m| outcome.unpack_message = try arena.dupe(u8, m);
    }
    if (report.stray_option) outcome.stray_option = true;
    for (results) |*r| {
        if (r.status != .ok) continue;
        if (!report.unpack_ok) {
            r.status = .rejected_by_remote;
            r.message = outcome.unpack_message;
            continue;
        }
        // A ref the remote says nothing of failed, as git's send-pack
        // has it; a remote helper reports such a ref itself, as `no match`.
        const said = report.find(r.remote_ref) orelse {
            r.status = .unreported;
            continue;
        };
        if (said.message) |m| r.message = try arena.dupe(u8, m);
        if (said.forced) r.forced = true;
        if (said.updates.len != 0) {
            const updates = try arena.alloc(send_pack.RefReport.Update, said.updates.len);
            for (said.updates, updates) |from, *to| {
                to.* = from;
                if (from.refname) |n| to.refname = try arena.dupe(u8, n);
            }
            r.updates = updates;
        }
        r.status = switch (said.status) {
            .ok => .ok,
            .rejected => .rejected_by_remote,
            .up_to_date => .up_to_date,
            .no_match => .no_match,
            .rejected_non_fast_forward => .rejected_non_fast_forward,
            .rejected_already_exists => .rejected_already_exists,
            .rejected_fetch_first => .rejected_fetch_first,
            .rejected_needs_force => .rejected_needs_force,
            .rejected_stale => .rejected_stale,
            .rejected_remote_updated => .rejected_remote_updated,
            .expecting_report => .unreported,
        };
    }
}

/// The refspecs `push.default` asks for when none are named, as git's
/// `setup_default_push_refspecs` decides them; whether
/// `push.autoSetupRemote` asks for the branch's upstream to be set.
fn defaultRefspecs(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    remote_name: []const u8,
    specs: *std.ArrayList(Refspec),
) Error!bool {
    const config = repo.configuration();
    const mode_text = config.get("push.default") orelse "simple";
    if (std.ascii.eqlIgnoreCase(mode_text, "nothing")) return error.NoPushDestination;
    if (std.ascii.eqlIgnoreCase(mode_text, "matching")) {
        try specs.append(arena, try Refspec.parse(":", .push, repo.objectFormat()));
        return false;
    }
    const current = (try repo.refStore().currentBranch(gpa, io)) orelse return error.NoPushDestination;
    defer gpa.free(current);
    const branch_ref = try arena.print("refs/heads/{s}", .{current});
    var branch = try remote_mod.Branch.get(gpa, config, current);
    defer branch.deinit();
    const auto = try config.getBool("push.autosetupremote", false);
    const same_remote = std.mem.eql(u8, remote.name orelse remote_name, branch.fetchRemote(config));
    var dst = branch_ref;
    if (std.ascii.eqlIgnoreCase(mode_text, "upstream") or std.ascii.eqlIgnoreCase(mode_text, "tracking")) {
        if (!same_remote) return error.NotUpstreamRemote;
        dst = try arena.dupe(u8, try upstreamRef(&branch, branch_ref, auto));
    } else if (!std.ascii.eqlIgnoreCase(mode_text, "current")) {
        // `simple`, and whatever git does not know, which it takes as it.
        if (same_remote and !std.mem.eql(u8, branch_ref, try upstreamRef(&branch, branch_ref, auto))) return error.UpstreamNameDiffers;
    }
    try specs.append(arena, try Refspec.parse(try arena.print("{s}:{s}", .{ branch_ref, dst }), .push, repo.objectFormat()));
    // A default push of a branch with no upstream under
    // `push.autoSetupRemote` sets the one it pushes to.
    return auto and branch.merge.len == 0;
}

/// git's `get_upstream_ref`: the branch's one upstream, or under
/// `push.autoSetupRemote` its own name when it has none.
fn upstreamRef(branch: *const remote_mod.Branch, branch_ref: []const u8, auto: bool) Error![]const u8 {
    if (branch.merge.len == 0 and auto) return branch_ref;
    if (branch.merge.len == 0 or branch.remote == null) return error.NoUpstreamBranch;
    if (branch.merge.len != 1) return error.MultipleUpstreams;
    return branch.merge[0];
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
        const head = (try repo.refStore().read(gpa, io, "HEAD")) orelse return error.SourceNotFound;
        switch (head) {
            .symbolic => |target| {
                defer gpa.free(target);
                const resolved = (try repo.refStore().resolve(gpa, io, target)) orelse return error.SourceNotFound;
                defer gpa.free(resolved.name);
                return .{ .name = try arena.dupe(u8, target), .oid = resolved.oid };
            },
            .direct => |oid| return .{ .name = null, .oid = oid },
        }
    }
    if (try bestMatch(text, local_names)) |name| {
        const resolved = (try repo.refStore().resolve(gpa, io, name)) orelse return error.SourceNotFound;
        defer gpa.free(resolved.name);
        return .{ .name = name, .oid = resolved.oid };
    }
    if (text.len == repo.objectFormat().hexLen()) {
        const oid = Oid.parse(repo.objectFormat(), text) catch return error.SourceNotFound;
        if (try repo.objectDatabase().exists(io, oid)) return .{ .name = null, .oid = oid };
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
    follow_tags: bool,
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
            try out.append(arena, .{ .local_ref = null, .new = .zero(repo.objectFormat()), .remote_ref = try arena.dupe(u8, name), .force = spec.force });
            continue;
        }
        const src = try resolveSource(arena, gpa, io, repo, local_names.items, spec.src);
        const dst: []const u8 = blk: {
            const dst_text = spec.dst orelse break :blk src.name orelse return error.DestinationNotFullRefname;
            if (std.mem.startsWith(u8, dst_text, "refs/")) break :blk try arena.dupe(u8, dst_text);
            if (try bestMatch(dst_text, remote_names.items)) |found| break :blk found;
            // Guessed from the source, as git guesses it.
            if (src.name) |name| {
                if (std.mem.startsWith(u8, name, "refs/heads/")) break :blk try arena.print("refs/heads/{s}", .{dst_text});
                if (std.mem.startsWith(u8, name, "refs/tags/")) break :blk try arena.print("refs/tags/{s}", .{dst_text});
            }
            const header = try repo.objectDatabase().readHeader(io, src.oid);
            switch (header.type) {
                .commit => break :blk try arena.print("refs/heads/{s}", .{dst_text}),
                .tag => break :blk try arena.print("refs/tags/{s}", .{dst_text}),
                else => return error.DestinationNotFullRefname,
            }
        };
        if (!ref_names.checkFormat(dst, .{})) return error.DestinationNotFullRefname;
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
    if (follow_tags) try addMissingTags(arena, gpa, io, repo, local_refs, remote_refs, &kept);
    return kept.items;
}

/// git's `add_missing_tags` (`--follow-tags`): each annotated tag here
/// the remote does not have, on a commit any ref the remote will have
/// after the push reaches, pushed to the same name.
fn addMissingTags(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    local_refs: *const refs_mod.Store.Listing,
    remote_refs: *const protocol.RefList,
    updates: *std.ArrayList(Update),
) Error!void {
    // What the remote will have, and the tags it has.
    var tips: std.ArrayList(Oid) = .empty;
    var tip_set: Oid.Set = .empty;
    var their_tags: std.StringHashMapUnmanaged(void) = .empty;
    const Tips = struct {
        fn add(a: Allocator, i: Io, r: *Repository, list: *std.ArrayList(Oid), set: *Oid.Set, oid: Oid) Error!void {
            if (oid.isZero()) return;
            const commit = commitOf(i, r, oid) orelse return;
            if ((try set.getOrPut(a, commit)).found_existing) return;
            try list.append(a, commit);
        }
    };
    for (remote_refs.refs) |ref| {
        var value = ref.oid;
        for (updates.items) |u| if (std.mem.eql(u8, u.remote_ref, ref.name) and !u.new.isZero()) {
            value = u.new;
        };
        try Tips.add(arena, io, repo, &tips, &tip_set, value);
        if (std.mem.startsWith(u8, ref.name, "refs/tags/")) try their_tags.put(arena, ref.name, {});
    }
    for (updates.items) |u| if (remote_refs.find(u.remote_ref) == null) {
        try Tips.add(arena, io, repo, &tips, &tip_set, u.new);
        if (std.mem.startsWith(u8, u.remote_ref, "refs/tags/")) try their_tags.put(arena, u.remote_ref, {});
    };
    if (tips.items.len == 0) return;
    // The annotated tags here they lack, and the commits they are on.
    var names: std.ArrayList([]const u8) = .empty;
    var tags: std.ArrayList(Oid) = .empty;
    var commits: std.ArrayList(Oid) = .empty;
    for (local_refs.entries) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "refs/tags/") or their_tags.contains(entry.name)) continue;
        const oid = switch (entry.target) {
            .direct => |oid| oid,
            .symbolic => continue,
        };
        if ((try repo.objectDatabase().readHeader(io, oid)).type != .tag) continue;
        const commit = commitOf(io, repo, oid) orelse continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
        try tags.append(arena, oid);
        try commits.append(arena, commit);
    }
    const reached = try rev_walk.reachableSubset(gpa, io, repo.objectDatabase(), .{ .from = tips.items, .to = commits.items }, .{});
    defer gpa.free(reached);
    for (names.items, tags.items, reached) |name, tag, yes| {
        if (!yes) continue;
        try updates.append(arena, .{ .local_ref = name, .new = tag, .remote_ref = name, .force = false });
    }
}

/// The order git sends `results`' commands in, as positions: the remote's
/// refs as it listed them, then those it lacks as they were matched, since
/// git's `match_push_refs` adds a new ref at the end of the remote's list.
fn sendOrder(arena: Allocator, results: []const RefResult, remote_refs: *const protocol.RefList) Allocator.Error![]const usize {
    var at: std.StringHashMapUnmanaged(usize) = .empty;
    for (results, 0..) |r, i| try at.put(arena, r.remote_ref, i);
    var order: std.ArrayList(usize) = .empty;
    try order.ensureTotalCapacity(arena, results.len);
    for (remote_refs.refs) |r| {
        if (at.fetchRemove(r.name)) |entry| order.appendAssumeCapacity(entry.value);
    }
    for (results, 0..) |r, i| {
        if (at.contains(r.remote_ref)) order.appendAssumeCapacity(i);
    }
    return order.items;
}

/// git's `set_ref_status_for_push` for one update.
fn judge(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    remote: *const remote_mod.Remote,
    result: *RefResult,
    how: struct { force: bool, leases: []const Lease, if_includes: bool },
) Error!void {
    const deletion = result.new.isZero();
    if (!deletion and result.old.eql(result.new)) {
        result.status = .up_to_date;
        return;
    }
    var forced = how.force;
    var reject: ?RefResult.Status = null;
    for (how.leases) |lease| {
        if (!std.mem.eql(u8, lease.ref, result.remote_ref)) continue;
        const tracking = if (lease.expect == null) try trackingValue(gpa, io, repo, remote, result.remote_ref) else null;
        const expected = lease.expect orelse tracking orelse Oid.zero(repo.objectFormat());
        if (!result.old.eql(expected)) {
            reject = .rejected_stale;
        } else if (how.if_includes and tracking != null and !try includesRemote(gpa, io, repo, remote, result)) {
            reject = .rejected_remote_updated;
        } else forced = true;
    }
    if (reject == null and !deletion and !result.old.isZero()) {
        if (std.mem.startsWith(u8, result.remote_ref, "refs/tags/")) {
            reject = .rejected_already_exists;
        } else if (!try repo.objectDatabase().exists(io, result.old)) {
            reject = .rejected_fetch_first;
        } else {
            const old_commit = commitOf(io, repo, result.old);
            const new_commit = commitOf(io, repo, result.new);
            if (old_commit == null or new_commit == null) {
                reject = .rejected_needs_force;
            } else if (!try rev_walk.isAncestor(gpa, io, repo.objectDatabase(), .{ .ancestor = old_commit.?, .descendant = new_commit.? }, .{})) {
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
    const header = repo.objectDatabase().readHeader(io, peeled) catch return null;
    return if (header.type == .commit) peeled else null;
}

/// git's `check_if_includes_upstream` and `is_reachable_in_reflog`:
/// whether the remote's value of `result`'s ref is in the log of the
/// local ref of that name, or reachable from a commit an entry of it
/// names, going back no further than the remote-tracking ref's newest
/// entry. Without such a local ref, nothing is asked.
fn includesRemote(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, result: *const RefResult) Error!bool {
    const store = repo.refStore();
    if ((try store.readOid(gpa, io, result.remote_ref)) == null) return true;
    const theirs = commitOf(io, repo, result.old) orelse return false;
    const tracking = (try remote.trackingRef(gpa, result.remote_ref)) orelse return false;
    defer gpa.free(tracking);
    var tracking_log = try store.readLog(gpa, io, tracking);
    defer tracking_log.deinit();
    const since: i64 = if (tracking_log.entries.len == 0) 0 else tracking_log.entries[tracking_log.entries.len - 1].who.when_secs;
    var local_log = try store.readLog(gpa, io, result.remote_ref);
    defer local_log.deinit();
    var seen: std.ArrayList(Oid) = .empty;
    defer seen.deinit(gpa);
    var i = local_log.entries.len;
    while (i > 0) {
        i -= 1;
        const entry = local_log.entries[i];
        if (entry.new.eql(theirs)) return true;
        if (commitOf(io, repo, entry.new)) |commit| try seen.append(gpa, commit);
        if (entry.who.when_secs < since) break;
    }
    for (seen.items) |commit| {
        if (try rev_walk.isAncestor(gpa, io, repo.objectDatabase(), .{ .ancestor = theirs, .descendant = commit }, .{})) return true;
    }
    return false;
}

fn trackingValue(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, remote_ref: []const u8) Error!?Oid {
    const name = (try remote.trackingRef(gpa, remote_ref)) orelse return null;
    defer gpa.free(name);
    const resolved = (try repo.refStore().resolve(gpa, io, name)) orelse return null;
    defer gpa.free(resolved.name);
    return resolved.oid;
}

/// git's `transport_update_tracking_ref`: the remote-tracking ref of the
/// ref pushed, or of each update the remote said it became, to the value
/// it said (a zero one deletes it).
fn updateTracking(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, result: RefResult, who: object.Signature) Error!void {
    if (result.updates.len == 0) return updateOneTracking(gpa, io, repo, remote, .{ .remote_ref = result.remote_ref, .new = result.new }, who);
    for (result.updates) |u| {
        try updateOneTracking(gpa, io, repo, remote, .{ .remote_ref = u.refname orelse result.remote_ref, .new = u.new orelse result.new }, who);
    }
}

/// A remote ref and the value it now has.
const Moved = struct { remote_ref: []const u8, new: Oid };

fn updateOneTracking(gpa: Allocator, io: Io, repo: *Repository, remote: *const remote_mod.Remote, result: Moved, who: object.Signature) Error!void {
    const name = (try remote.trackingRef(gpa, result.remote_ref)) orelse return;
    defer gpa.free(name);
    const current = try repo.refStore().resolve(gpa, io, name);
    defer if (current) |c| gpa.free(c.name);
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    if (result.new.isZero()) {
        if (current == null) return;
        try tx.delete(name, .any);
        // Deleting the ref deletes its log, in either format.
        try tx.commit(io, null);
        return;
    }
    if (current) |c| {
        if (c.oid.eql(result.new)) return;
    }
    try tx.update(name, .{ .direct = result.new }, .any);
    try tx.commit(io, .{ .who = who, .message = "update by push", .policy = repo.reflogPolicy() });
}

const testing = std.testing;
const testgit = @import("../testing/git.zig");
const fetch_mod = @import("fetch.zig");
const submodule = @import("../submodule/submodule.zig");
const sub_changes = @import("../submodule/changes.zig");
const testremote = @import("../testing/remote.zig");

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
            const bare = try gpa.print("{s}/remote-{s}.git", .{ root_path, who });
            defer gpa.free(bare);
            const work = try gpa.print("{s}/work-{s}", .{ root_path, who });
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
        const work_git_path = try gpa.print("{s}/work-git", .{root_path});
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
        t.* = undefined;
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

/// Both working repositories' `branch.*` settings, the same.
fn expectSameBranchConfig(twins: *PushTwins) !void {
    const io = testing.io;
    var config: [2][]u8 = undefined;
    for ([_][]const u8{ "work-git", "work-relic" }, 0..) |name, i| {
        var dir = try twins.root.dir.openDir(io, name, .{});
        defer dir.close(io);
        config[i] = try twins.gitOut(dir, &.{ "config", "--get-regexp", "^branch\\." });
    }
    defer for (config) |text| twins.gpa.free(text);
    try testing.expectEqualStrings(config[0], config[1]);
}

/// The same git command in both working repositories.
fn inBothWorks(twins: *PushTwins, args: []const []const u8) !void {
    for ([_][]const u8{ "work-git", "work-relic" }) |name| {
        var dir = try twins.root.dir.openDir(testing.io, name, .{});
        defer dir.close(testing.io);
        try twins.git(dir, args);
    }
}

test "push.followTags, --set-upstream and push.autoSetupRemote as git's, and a branch with no upstream refused as git refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    // An annotated tag on a commit the remote has, one on the new work,
    // and a lightweight one, which is not followed.
    try inBothWorks(&twins, &.{ "tag", "-a", "reached", "-m", "reached", "HEAD~1" });
    try inBothWorks(&twins, &.{ "tag", "lightweight" });
    try inBothWorks(&twins, &.{ "config", "push.followTags", "true" });
    var followed = try twins.pushBoth(&.{ "origin", "main" }, .{ .who = test_who, .refspecs = &.{"main"} });
    defer followed.deinit();
    try testing.expectEqual(@as(usize, 3), followed.refs.len);

    // `--set-upstream`.
    try inBothWorks(&twins, &.{ "branch", "topic" });
    var upstream = try twins.pushBoth(&.{ "--set-upstream", "origin", "topic" }, .{ .who = test_who, .refspecs = &.{"topic"}, .set_upstream = true });
    defer upstream.deinit();
    try testing.expectEqual(@as(usize, 1), upstream.upstreams.len);
    try expectSameBranchConfig(&twins);

    // A branch of its own, with no upstream: refused under `simple`.
    try inBothWorks(&twins, &.{ "switch", "-q", "-c", "lone" });
    {
        var work_git = try twins.root.dir.openDir(io, "work-git", .{});
        defer work_git.close(io);
        const said = try twins.gitOut(work_git, &.{ "push", "-q", "origin" });
        defer gpa.free(said);
        try testing.expectEqualStrings("failed", said);
        var work_relic = try twins.root.dir.openDir(io, "work-relic", .{});
        defer work_relic.close(io);
        var repo = try Repository.open(gpa, io, work_relic, .{});
        defer repo.deinit(io);
        try testing.expectError(error.NoUpstreamBranch, push(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env } }));
    }
    // `push.autoSetupRemote`: pushed to its own name, and set to track it.
    try inBothWorks(&twins, &.{ "config", "push.autoSetupRemote", "true" });
    var auto = try twins.pushBoth(&.{"origin"}, .{ .who = test_who });
    defer auto.deinit();
    try testing.expectEqualStrings("refs/heads/lone", auto.refs[0].remote_ref);
    try expectSameBranchConfig(&twins);
}

test "push.pushOption gives the push options when none are named, an empty one clearing those before it, as git's push reads it" {
    const gpa = testing.allocator;
    const io = testing.io;
    if (builtin.target.os.tag == .windows) return error.SkipZigTest; // the hook is a shell script
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    const hook =
        \\#!/bin/sh
        \\echo "count $GIT_PUSH_OPTION_COUNT" >>hook.log
        \\i=0
        \\while test $i -lt "${GIT_PUSH_OPTION_COUNT:-0}"; do eval "echo \"\$GIT_PUSH_OPTION_$i\"" >>hook.log; i=$((i + 1)); done
        \\
    ;
    try twins.inBothRemotes(&.{ "config", "receive.advertisePushOptions", "true" });
    for ([_][]const u8{ "remote-git.git", "remote-relic.git" }) |name| {
        var dir = try twins.root.dir.openDir(io, name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "hooks/pre-receive", .data = hook });
        const file = try dir.openFile(io, "hooks/pre-receive", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o755));
    }
    for ([_][]const u8{ "dropped", "", "first", "second" }) |value| try inBothWorks(&twins, &.{ "config", "--add", "push.pushOption", value });
    var pushed = try twins.pushBoth(&.{ "origin", "main" }, .{ .who = test_who, .refspecs = &.{"main"} });
    defer pushed.deinit();
    try expectSameHookLogs(&twins, io);
    // Named ones take their place.
    var named = try twins.pushBoth(&.{ "--push-option", "named", "origin", "main:refs/heads/again" }, .{ .who = test_who, .refspecs = &.{"main:refs/heads/again"}, .push_options = &.{"named"} });
    defer named.deinit();
    try expectSameHookLogs(&twins, io);
}

test "--force-if-includes and push.useForceIfIncludes refuse a lease the local ref's log never saw, as git's push refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    // Someone else moves the remote's main, and both fetch it without
    // taking it in.
    for ([_][]const u8{ "remote-git.git", "remote-relic.git" }) |name| {
        var dir = try twins.root.dir.openDir(io, name, .{});
        defer dir.close(io);
        const made = try twins.gitOut(dir, &.{ "commit-tree", "main^{tree}", "-p", "main", "-m", "elsewhere" });
        defer gpa.free(made);
        try twins.git(dir, &.{ "update-ref", "refs/heads/main", std.mem.trimEnd(u8, made, "\n") });
    }
    try inBothWorks(&twins, &.{ "fetch", "-q", "origin" });
    const lease: []const Lease = &.{.{ .ref = "refs/heads/main" }};
    var refused = try twins.pushBoth(&.{ "--force-with-lease", "--force-if-includes", "origin", "main" }, .{ .who = test_who, .refspecs = &.{"main"}, .leases = lease, .force_if_includes = true });
    defer refused.deinit();
    try testing.expectEqual(RefResult.Status.rejected_remote_updated, refused.refs[0].status);
    // Without it the lease alone holds, and the push goes.
    try inBothWorks(&twins, &.{ "config", "push.useForceIfIncludes", "true" });
    var by_setting = try twins.pushBoth(&.{ "--force-with-lease", "origin", "main" }, .{ .who = test_who, .refspecs = &.{"main"}, .leases = lease });
    defer by_setting.deinit();
    try testing.expectEqual(RefResult.Status.rejected_remote_updated, by_setting.refs[0].status);
    // Once the local ref has been at the remote's value, a rewrite on top
    // of it goes.
    try inBothWorks(&twins, &.{ "reset", "-q", "--hard", "origin/main" });
    try inBothWorks(&twins, &.{ "commit", "-q", "--amend", "--allow-empty", "-m", "rewritten" });
    var forced = try twins.pushBoth(&.{ "--force-with-lease", "origin", "main" }, .{ .who = test_who, .refspecs = &.{"main"}, .leases = lease });
    defer forced.deinit();
    try testing.expectEqual(RefResult.Status.ok, forced.refs[0].status);
}

test "push.negotiate leaves out what a negotiation finds the remote has, asking git's upload-pack as git's push asks it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    const fake = try testremote.fakeSsh(gpa, io, twins.root.dir);
    defer gpa.free(fake);
    for ([_][2][]const u8{ .{ "work-git", "remote-git.git" }, .{ "work-relic", "remote-relic.git" } }) |pair| {
        var dir = try twins.root.dir.openDir(io, pair[0], .{});
        defer dir.close(io);
        const url = try gpa.print("example.invalid:{s}/{s}", .{ twins.root_path, pair[1] });
        defer gpa.free(url);
        try twins.git(dir, &.{ "remote", "set-url", "origin", url });
        try twins.git(dir, &.{ "config", "core.sshCommand", fake });
        try twins.git(dir, &.{ "config", "push.negotiate", "true" });
    }
    var heard: [2][]u8 = undefined;
    for ([_][]const u8{ "work-git", "work-relic" }, 0..) |name, i| {
        const trace = try gpa.print("{s}/negotiate-{d}", .{ twins.root_path, i });
        defer gpa.free(trace);
        try twins.env.put("GIT_TRACE_PACKET", trace);
        defer _ = twins.env.swapRemove("GIT_TRACE_PACKET");
        var dir = try twins.root.dir.openDir(io, name, .{});
        defer dir.close(io);
        if (i == 0) {
            try twins.git(dir, &.{ "push", "-q", "origin", "main" });
        } else {
            var repo = try Repository.open(gpa, io, dir, .{});
            defer repo.deinit(io);
            var outcome = try push(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env }, .refspecs = &.{"main"} });
            defer outcome.deinit();
            try testing.expect(!outcome.anyRejected());
        }
        const traced = try Io.Dir.cwd().readFileAlloc(io, trace, gpa, .unlimited);
        defer gpa.free(traced);
        var said: std.ArrayList(u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, traced, '\n');
        while (lines.next()) |line| {
            const at = std.mem.find(u8, line, "upload-pack< ") orelse continue;
            const text = std.mem.trimEnd(u8, line[at + "upload-pack< ".len ..], " ");
            if (std.mem.startsWith(u8, text, "have ") or std.mem.eql(u8, text, "wait-for-done") or std.mem.eql(u8, text, "0000")) try said.print(gpa, "{s}\n", .{text});
        }
        heard[i] = try said.toOwnedSlice(gpa);
    }
    defer for (heard) |text| gpa.free(text);
    try testing.expect(std.mem.find(u8, heard[0], "wait-for-done") != null);
    try testing.expectEqualStrings(heard[0], heard[1]);
    try twins.expectSame();
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
    const full = try gpa.print("refs/tags/{s}", .{name});
    defer gpa.free(full);
    const resolved = (try repo.refStore().resolve(gpa, io, full)).?;
    defer gpa.free(resolved.name);
    return repo.peel(io, resolved.oid);
}

const PrePushSeen = struct {
    text: std.ArrayList(u8) = .empty,
    allow: bool = true,
    fn run(context: ?*anyopaque, remote: []const u8, url: []const u8, updates: []const PrePushUpdate) bool {
        _ = url;
        const self: *PrePushSeen = @ptrCast(@alignCast(context.?)); // safe: the context handed out with this function is a PrePushSeen
        self.text.print(testing.allocator, "{s}\n", .{remote}) catch return false;
        for (updates) |u| {
            self.text.print(testing.allocator, "{s} {f} {s} {f}\n", .{ u.local_ref, u.local_oid, u.remote_ref, u.remote_oid }) catch return false;
        }
        return self.allow;
    }
};

test "the pre-push hook point is shown what git's pre-push hook is shown, and can stop the push" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();

    // git's own hook, noting its arguments and its input.
    var work_git = try twins.root.dir.openDir(io, "work-git", .{});
    defer work_git.close(io);
    const hook_log = try gpa.print("{s}/pre-push.log", .{twins.root_path});
    defer gpa.free(hook_log);
    const hook_data = try gpa.print("{s}\n", .{hook_log});
    defer gpa.free(hook_data);
    try testgit.fixtureHook(gpa, io, work_git, ".git/hooks/pre-push", "record_stdin", hook_data);
    twins.git_settings = &.{ "-c", "core.hooksPath=.git/hooks" };

    var seen: PrePushSeen = .{};
    defer seen.text.deinit(gpa);
    var outcome = try twins.pushBoth(&.{ "origin", "main", "feature" }, .{
        .who = test_who,
        .refspecs = &.{ "main", "feature" },
        .pre_push = .{ .context = &seen, .run = PrePushSeen.run },
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
        .pre_push = .{ .context = &seen, .run = PrePushSeen.run },
    }));
    var remote = try twins.root.dir.openDir(io, "remote-relic.git", .{});
    defer remote.close(io);
    const tags = try twins.gitOut(remote, &.{ "tag", "-l", "v2" });
    defer gpa.free(tags);
    try testing.expectEqualStrings("", tags);
}

test "a push over ssh and over HTTP leaves the remote as git push leaves it" {
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
        const ssh_path = try gpa.dupe(u8, twins.root_path);
        defer gpa.free(ssh_path);
        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
        for ([_][2][]const u8{ .{ "work-git", "remote-git.git" }, .{ "work-relic", "remote-relic.git" } }) |pair| {
            var work = try twins.root.dir.openDir(io, pair[0], .{});
            defer work.close(io);
            var remote_dir = try twins.root.dir.openDir(io, pair[1], .{});
            defer remote_dir.close(io);
            try twins.git(remote_dir, &.{ "config", "http.receivepack", "true" });
            const url = if (server) |s|
                try s.url(gpa, pair[1])
            else
                try gpa.print("ssh://example.invalid{s}{s}/{s}", .{ if (builtin.target.os.tag == .windows) "/" else "", ssh_path, pair[1] });
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

test "a proc-receive hook's report-status-v2 options move the remote-tracking refs they name, as git's push moves them" {
    const gpa = testing.allocator;
    const io = testing.io;
    const reports = [_][]const u8{
        // One update, renamed and given its value.
        "ok refs/for/main\noption refname refs/heads/topic\noption new-oid {new}\noption forced-update\n",
        // Two updates of one command, the second to the old value: zero, a
        // deletion of what tracks it.
        "ok refs/for/main\noption refname refs/heads/main\noption old-oid {old}\noption new-oid {new}\nok refs/for/main\noption refname refs/heads/feature\noption new-oid {old}\n",
        // An `ok` with no options is the ref itself.
        "ok refs/for/main\n",
        "ng refs/for/main not today\n",
    };
    for (reports) |answer| {
        var twins = try PushTwins.init(gpa, io);
        defer twins.deinit();
        const fake = try testremote.fakeSsh(gpa, io, twins.root.dir);
        defer gpa.free(fake);
        const ssh_path = try gpa.dupe(u8, twins.root_path);
        defer gpa.free(ssh_path);
        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
        for ([_][2][]const u8{ .{ "work-git", "remote-git.git" }, .{ "work-relic", "remote-relic.git" } }) |pair| {
            var work = try twins.root.dir.openDir(io, pair[0], .{});
            defer work.close(io);
            var remote_dir = try twins.root.dir.openDir(io, pair[1], .{});
            defer remote_dir.close(io);
            try twins.git(remote_dir, &.{ "config", "receive.procReceiveRefs", "refs/for" });
            try testgit.fixtureHook(gpa, io, remote_dir, "hooks/proc-receive", "proc_receive", answer);
            const url = try gpa.print("ssh://example.invalid{s}{s}/{s}", .{ if (builtin.target.os.tag == .windows) "/" else "", ssh_path, pair[1] });
            defer gpa.free(url);
            try twins.git(work, &.{ "remote", "set-url", "origin", url });
            try twins.git(work, &.{ "config", "core.sshCommand", fake });
        }
        errdefer std.debug.print("{s}\n", .{answer});
        var outcome = try twins.pushBoth(&.{ "origin", "main:refs/for/main" }, .{ .who = test_who, .refspecs = &.{"main:refs/for/main"} });
        defer outcome.deinit();
    }
}

/// What a remote's `pre-receive` hook says of a push certificate, to
/// `hook.log`: its status, signer, key and nonce status, and its text with
/// the time, the nonce and the remote's own name left out.
const cert_hook =
    \\#!/bin/sh
    \\cat >/dev/null
    \\if test -z "$GIT_PUSH_CERT"; then echo "no certificate" >>hook.log; exit 0; fi
    \\echo "$GIT_PUSH_CERT_STATUS $GIT_PUSH_CERT_SIGNER $GIT_PUSH_CERT_KEY ${GIT_PUSH_CERT_NONCE:+nonce} $GIT_PUSH_CERT_NONCE_STATUS" >>hook.log
    \\git cat-file blob "$GIT_PUSH_CERT" | sed -e '/^-----BEGIN/,$d' -e 's/^\(pusher [^ ]*\) .*/\1/' -e 's/remote-[a-z]*\.git/remote.git/' -e 's/^nonce .*/nonce/' >>hook.log
    \\
;

/// Both remotes reached as `url_of` names them, through the fake `ssh`,
/// asking for a certificate when `seed`, which an SSH key made beside
/// them signs and they know. `false` when `ssh-keygen` is not installed.
fn signedTwins(twins: *PushTwins, io: Io, server: ?*testremote.HttpServer, seed: bool) !bool {
    const gpa = twins.gpa;
    const fake = try testremote.fakeSsh(gpa, io, twins.root.dir);
    defer gpa.free(fake);
    const key = try gpa.print("{s}/signer", .{twins.root_path});
    defer gpa.free(key);
    var made = program.run(gpa, io, .{ .environ = &twins.env }, .{ .argv = &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "signer", "-f", key } }, .{}) catch return false;
    made.deinit(gpa);
    const public_path = try gpa.print("{s}.pub", .{key});
    defer gpa.free(public_path);
    const public = try Io.Dir.cwd().readFileAlloc(io, public_path, gpa, .limited(4096));
    defer gpa.free(public);
    const allowed = try gpa.print("signer@example.com namespaces=\"git\" {s}", .{public});
    defer gpa.free(allowed);
    try twins.root.dir.writeFile(io, .{ .sub_path = "allowed", .data = allowed });
    const allowed_path = try gpa.print("{s}/allowed", .{twins.root_path});
    defer gpa.free(allowed_path);
    const ssh_path = try gpa.dupe(u8, twins.root_path);
    defer gpa.free(ssh_path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
    for ([_][2][]const u8{ .{ "work-git", "remote-git.git" }, .{ "work-relic", "remote-relic.git" } }) |pair| {
        var work = try twins.root.dir.openDir(io, pair[0], .{});
        defer work.close(io);
        var remote_dir = try twins.root.dir.openDir(io, pair[1], .{});
        defer remote_dir.close(io);
        if (seed) {
            try twins.git(remote_dir, &.{ "config", "receive.certNonceSeed", "a seed" });
            // Over HTTP each request is a receive-pack of its own, a second
            // apart at most.
            try twins.git(remote_dir, &.{ "config", "receive.certNonceSlop", "60" });
        }
        try twins.git(remote_dir, &.{ "config", "receive.advertisePushOptions", "true" });
        try twins.git(remote_dir, &.{ "config", "http.receivepack", "true" });
        try twins.git(remote_dir, &.{ "config", "gpg.ssh.allowedSignersFile", allowed_path });
        try remote_dir.writeFile(io, .{ .sub_path = "hooks/pre-receive", .data = cert_hook });
        if (builtin.target.os.tag != .windows) {
            const hook = try remote_dir.openFile(io, "hooks/pre-receive", .{});
            defer hook.close(io);
            try hook.setPermissions(io, .fromMode(0o755));
        }
        const url = if (server) |s|
            try s.url(gpa, pair[1])
        else
            try gpa.print("ssh://example.invalid{s}{s}/{s}", .{ if (builtin.target.os.tag == .windows) "/" else "", ssh_path, pair[1] });
        defer gpa.free(url);
        try twins.git(work, &.{ "remote", "set-url", "origin", url });
        try twins.git(work, &.{ "config", "core.sshCommand", fake });
        try twins.git(work, &.{ "config", "gpg.format", "ssh" });
        try twins.git(work, &.{ "config", "user.signingKey", key });
    }
    return true;
}

/// The two remotes' `hook.log`s, alike.
fn expectSameHookLogs(twins: *PushTwins, io: Io) !void {
    var logs: [2][]u8 = undefined;
    for ([_][]const u8{ "remote-git.git", "remote-relic.git" }, 0..) |name, i| {
        var dir = try twins.root.dir.openDir(io, name, .{});
        defer dir.close(io);
        logs[i] = try dir.readFileAlloc(io, "hook.log", twins.gpa, .unlimited);
    }
    defer for (logs) |l| twins.gpa.free(l);
    try testing.expectEqualStrings(logs[0], logs[1]);
}

test "a signed push carries a certificate git's receive-pack checks, as git's push signs it, over ssh and HTTP" {
    const gpa = testing.allocator;
    const io = testing.io;
    if (builtin.target.os.tag == .windows) return error.SkipZigTest; // the hook is a shell script
    for ([_]bool{ false, true }) |over_http| {
        var twins = try PushTwins.init(gpa, io);
        defer twins.deinit();
        var server: ?*testremote.HttpServer = null;
        defer if (server) |s| s.stop();
        if (over_http) server = try testremote.HttpServer.start(gpa, io, twins.root.dir, .{});
        if (!try signedTwins(&twins, io, server, true)) return error.SkipZigTest;
        var outcome = try twins.pushBoth(&.{ "--signed", "-o", "an option", "origin", "main", "feature", ":refs/heads/side" }, .{
            .refspecs = &.{ "main", "feature", ":refs/heads/side" },
            .push_options = &.{"an option"},
            .signed = .always,
            .who = test_who,
        });
        defer outcome.deinit();
        try expectSameHookLogs(&twins, io);
        const log = try twins.root.dir.readFileAlloc(io, "remote-relic.git/hook.log", gpa, .unlimited);
        defer gpa.free(log);
        try testing.expect(std.mem.startsWith(u8, log, "G signer@example.com SHA256:"));
        try testing.expect(std.mem.find(u8, log, " nonce OK\n") != null);
    }
}

test "push.gpgSign signs a push, and a server asking for no certificate takes one only if asked, as git's push decides" {
    const gpa = testing.allocator;
    const io = testing.io;
    if (builtin.target.os.tag == .windows) return error.SkipZigTest; // the hook is a shell script
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    if (!try signedTwins(&twins, io, null, false)) return error.SkipZigTest;
    // Asked only if the server asks: sent unsigned, with git's warning.
    {
        var warnings: warning.Warnings = .init(gpa);
        defer warnings.deinit();
        twins.git_settings = &.{ "-c", "push.gpgSign=if-asked" };
        var outcome = try twins.pushBoth(&.{ "origin", "main" }, .{ .refspecs = &.{"main"}, .signed = .if_asked, .warnings = &warnings, .who = test_who });
        defer outcome.deinit();
        try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
        try testing.expectEqual(warning.Warning.push_cert_not_asked, warnings.items.items[0]);
        try expectSameHookLogs(&twins, io);
    }
    var work = try twins.root.dir.openDir(io, "work-relic", .{});
    defer work.close(io);
    var repo = try Repository.open(gpa, io, work, .{});
    defer repo.deinit(io);
    // Signed always: git's push refuses, and so does this, from the
    // setting as from the option.
    var work_git = try twins.root.dir.openDir(io, "work-git", .{});
    defer work_git.close(io);
    const refused = try twins.gitOut(work_git, &.{ "push", "--signed", "origin", "feature" });
    defer gpa.free(refused);
    try testing.expectEqualStrings("failed", refused);
    try testing.expectError(error.SignedPushUnsupported, push(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env }, .refspecs = &.{"feature"}, .signed = .always }));
    for ([_][2][]const u8{ .{ "true", "SignedPushUnsupported" }, .{ "sometimes", "InvalidPushGpgSign" } }) |case| {
        try twins.git(work, &.{ "config", "push.gpgSign", case[0] });
        var configured = try Repository.open(gpa, io, work, .{});
        defer configured.deinit(io);
        const got = push(gpa, io, &configured, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env }, .refspecs = &.{"feature"} });
        if (got) |pushed| {
            var outcome = pushed;
            outcome.deinit();
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqualStrings(case[1], @errorName(err));
    }
}

test "under transfer.advertiseSID a push and a fetch name their session to a server that takes one, as git's do" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    const fake = try testremote.fakeSsh(gpa, io, twins.root.dir);
    defer gpa.free(fake);
    // git's servers write what they were told to their trace2 log.
    const events = try gpa.print("{s}/events", .{twins.root_path});
    defer gpa.free(events);
    try twins.env.put("GIT_TRACE2_EVENT", events);
    var remote_dir = try twins.root.dir.openDir(io, "remote-relic.git", .{});
    defer remote_dir.close(io);
    try twins.git(remote_dir, &.{ "config", "transfer.advertiseSID", "true" });
    var work = try twins.root.dir.openDir(io, "work-relic", .{});
    defer work.close(io);
    const ssh_path = try gpa.dupe(u8, twins.root_path);
    defer gpa.free(ssh_path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, ssh_path, '\\', '/');
    const url = try gpa.print("ssh://example.invalid{s}{s}/remote-relic.git", .{ if (builtin.target.os.tag == .windows) "/" else "", ssh_path });
    defer gpa.free(url);
    try twins.git(work, &.{ "remote", "set-url", "origin", url });
    try twins.git(work, &.{ "config", "core.sshCommand", fake });
    try twins.git(work, &.{ "config", "transfer.advertiseSID", "true" });
    var repo = try Repository.open(gpa, io, work, .{});
    defer repo.deinit(io);
    var pushed = try push(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env }, .refspecs = &.{"main:refs/heads/sid"} });
    defer pushed.deinit();
    for ([_][]const u8{ "2", "0" }) |version| {
        try twins.git(work, &.{ "config", "protocol.version", version });
        // Something new there, for the fetch to ask for.
        const made = try twins.gitOut(remote_dir, &.{ "commit-tree", "main^{tree}", "-p", "main", "-m", version });
        defer gpa.free(made);
        try twins.git(remote_dir, &.{ "update-ref", "refs/heads/main", std.mem.trimEnd(u8, made, "\n") });
        var reopened = try Repository.open(gpa, io, work, .{});
        defer reopened.deinit(io);
        var fetched = try fetch_mod.fetch(gpa, io, &reopened, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env }, .refspecs = &.{"refs/heads/main:refs/heads/fetched"} });
        fetched.deinit();
    }
    const log = try Io.Dir.cwd().readFileAlloc(io, events, gpa, .unlimited);
    defer gpa.free(log);
    // receive-pack's, and upload-pack's in v0 and v2: relic's id each time.
    var told: usize = 0;
    var it = std.mem.splitSequence(u8, log, "\"key\":\"client-sid\",\"value\":\"");
    _ = it.next();
    while (it.next()) |rest| {
        const end = std.mem.findScalar(u8, rest, '"') orelse continue;
        try testing.expect(std.mem.find(u8, rest[0..end], "Z-R") != null);
        told += 1;
    }
    try testing.expectEqual(@as(usize, 3), told);
}

test "a push goes through the proxy it is given, and past the configured one when given none" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    const server = try testremote.HttpServer.start(gpa, io, twins.root.dir, .{});
    defer server.stop();
    const proxy = try testremote.Proxy.start(gpa, io, null);
    defer proxy.stop();
    const proxy_url = try proxy.url(gpa);
    defer gpa.free(proxy_url);
    var remote_dir = try twins.root.dir.openDir(io, "remote-relic.git", .{});
    defer remote_dir.close(io);
    try twins.git(remote_dir, &.{ "config", "http.receivepack", "true" });
    var work = try twins.root.dir.openDir(io, "work-relic", .{});
    defer work.close(io);
    const url = try server.url(gpa, "remote-relic.git");
    defer gpa.free(url);
    try twins.git(work, &.{ "remote", "set-url", "origin", url });
    try twins.git(work, &.{ "config", "http.proxy", "http://127.0.0.1:9/" });
    var repo = try Repository.open(gpa, io, work, .{});
    defer repo.deinit(io);
    {
        var outcome = try push(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env }, .refspecs = &.{"main"}, .proxy = .{ .url = proxy_url } });
        defer outcome.deinit();
        for (outcome.refs) |r| try testing.expectEqual(RefResult.Status.ok, r.status);
        const seen = try proxy.take(gpa);
        defer gpa.free(seen);
        try testing.expect(seen.len != 0);
    }
    {
        var outcome = try push(gpa, io, &repo, "origin", .{ .who = test_who, .programs = .{ .environ = &twins.env }, .refspecs = &.{"feature"}, .proxy = .none });
        defer outcome.deinit();
        for (outcome.refs) |r| try testing.expectEqual(RefResult.Status.ok, r.status);
        const seen = try proxy.take(gpa);
        defer gpa.free(seen);
        try testing.expectEqual(@as(usize, 0), seen.len);
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

    try testgit.fixtureHook(gpa, io, target.dir, ".git/hooks/pre-receive", "status", "0");
    try testing.expectError(error.RemoteHooksNotRun, push(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{"main:refs/heads/third"} }));
}

test "a repository on this machine refuses a ref of one level under refs/ as receive-pack does" {
    const gpa = testing.allocator;
    const io = testing.io;
    var target = try testremote.historyRepo(gpa, io, 2);
    defer target.deinit();
    try target.exec(io, &.{ "config", "receive.denyCurrentBranch", "ignore" });
    const target_path = try testremote.absolutePath(gpa, io, target.dir);
    defer gpa.free(target_path);

    var here = try testgit.Repo.init(gpa, io, &.{});
    defer here.deinit();
    try here.exec(io, &.{ "remote", "add", "origin", target_path });
    try here.exec(io, &.{ "fetch", "-q", "origin" });
    try here.exec(io, &.{ "checkout", "-q", "-b", "main", "origin/main" });

    var repo = try Repository.open(gpa, io, here.dir, .{});
    defer repo.deinit(io);
    var outcome = try push(gpa, io, &repo, "origin", .{ .who = test_who, .refspecs = &.{ "main:refs/funny", "main:refs/heads/fine" } });
    defer outcome.deinit();
    // receive-pack checks the name after `refs/` as a full ref name, which
    // `funny` alone is not.
    try testing.expectEqual(RefResult.Status.rejected_by_remote, outcome.refs[0].status);
    try testing.expectEqualStrings("funny refname", outcome.refs[0].message.?);
    try testing.expectEqual(RefResult.Status.ok, outcome.refs[1].status);
    target.report_failures = false;
    try testing.expectError(error.GitFailed, target.exec(io, &.{ "rev-parse", "--verify", "-q", "refs/funny" }));
    // git refuses the same.
    here.report_failures = false;
    try testing.expectError(error.GitFailed, here.exec(io, &.{ "push", "-q", "origin", "main:refs/funny2" }));
}

test "a remote with two push URLs is pushed to both, as git pushes to both" {
    const gpa = testing.allocator;
    const io = testing.io;
    var twins = try PushTwins.init(gpa, io);
    defer twins.deinit();
    for ([_][]const u8{ "git", "relic" }) |who| {
        const first = try gpa.print("{s}/remote-{s}.git", .{ twins.root_path, who });
        defer gpa.free(first);
        const second = try gpa.print("{s}/extra-{s}.git", .{ twins.root_path, who });
        defer gpa.free(second);
        try twins.git(twins.root.dir, &.{ "clone", "-q", "--bare", first, second });
        const work_name = try gpa.print("work-{s}", .{who});
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
