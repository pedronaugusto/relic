//! Merging commits into the current branch: `git merge`.
//!
//! What it leaves is git's in every file git reads back. A fast-forward
//! moves the branch and logs `merge <name>: Fast-forward`; a clean merge
//! commits with the message `git fmt-merge-msg` would write and logs `merge
//! <name>: Merge made by the 'ort' strategy.`; a conflicted one stops with
//! `MERGE_HEAD`, `MERGE_MSG` (with its `# Conflicts:` list), `MERGE_MODE`,
//! `ORIG_HEAD` and `AUTO_MERGE` written, so `git commit` or `git merge
//! --continue` finishes it and `git merge --abort` undoes it -- and the same
//! is true the other way round. Several merge bases are merged into one
//! first, as git does, nested conflict markers and all. Two or more heads
//! make an octopus, merged as git's `merge-octopus` merges them.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const state_file = @import("../repo/state.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const ref_names = @import("../names.zig").ref;
const object = @import("../object/object.zig");
const merge = @import("../merge/merge.zig");
const diff = @import("../diff/diff.zig");
const rev_walk = @import("../walk/walk.zig");
const three_way = @import("../merge/three_way.zig");
const refspec = @import("../wire.zig").refspec;
const signing_mod = @import("../object/signing.zig");
const hooks_mod = @import("../hooks/hooks.zig");
const commit_hooks = @import("commit_hooks.zig");
const program = @import("../process.zig").program;
const filter = @import("../checkout/filter.zig");
const ort = @import("../merge/ort.zig");
const rerere = @import("../merge/rerere.zig");
const rev_parse = @import("../repo/rev_parse.zig");
const reset = @import("reset.zig");
const head_mod = @import("../repo/head.zig");
const quote = @import("../text.zig").quote;
const message = @import("../object/message.zig");
const glob_mod = @import("../text.zig").glob;
const worktree = @import("../checkout/checkout.zig");
const repo_mod = @import("../repo/repo.zig");
const refs_mod = @import("../refs/refs.zig");
const diagnostic = @import("../report.zig").diagnostic;
const config = @import("../config/config.zig");
const ctype = @import("../text.zig").ctype;
const pretty = @import("../pretty/pretty.zig");
const stash = @import("stash.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a merge.
pub const Error = error{
    /// `merge.log` or `merge.summary` is a negative count or neither a
    /// boolean nor a count, which git dies on.
    InvalidMergeLog,
    /// `merge.conflictStyle` is bare or names a style git does not know,
    /// which git dies on.
    InvalidConflictStyle,
    /// `core.commentChar` or `core.commentString` is one git dies on: no
    /// value, empty, or holding a line break.
    InvalidCommentString,
    /// `core.commentChar` is `auto` and every candidate begins a line of
    /// the message.
    NoCommentCharacter,
    /// `commit.cleanup` is bare or, where git dies on it, names no mode git
    /// knows.
    InvalidCleanupMode,
    /// `MERGE_HEAD` is there: a merge is already waiting to be concluded.
    MergeInProgress,
    /// `CHERRY_PICK_HEAD` or `REVERT_HEAD` is there: a cherry-pick or a
    /// revert is waiting to be concluded.
    SequencerInProgress,
    /// There is no merge to conclude or abort.
    NoMergeInProgress,
    /// `HEAD` names a branch with no commit yet.
    UnbornBranch,
    /// The two commits share no history and the caller did not allow it.
    UnrelatedHistories,
    /// `--ff-only` was asked for and the merge is not a fast-forward.
    NotFastForward,
    /// The name given does not name a commit, or a line of `FETCH_HEAD`
    /// marked for merging does not.
    NotACommit,
    /// There is no `FETCH_HEAD` to merge.
    NoFetchHead,
    /// A commit to merge has no signature, or one that is not good:
    /// `--verify-signatures`. `Options.unverified` names it.
    MissingSignature,
    /// A commit to merge has a bad signature. `Options.unverified` names it.
    BadSignature,
    /// A commit to merge has a good signature from a key not trusted
    /// enough: below marginal, or below `gpg.minTrustLevel` when that is
    /// set. `Options.unverified` names it.
    UntrustedSignature,
    /// The name given is an annotated tag. git merges its commit and quotes
    /// the tag's message in the merge commit's; this release does not.
    AnnotatedTag,
    /// `merge.branchdesc` is neither true nor false, `merge.suppressDest`
    /// has no value, or a `diff.renames` or `diff.renameLimit` is one
    /// `git merge`'s diff settings die on (three_way's other cases).
    InvalidMergeSetting,
    /// `branch.<name>.mergeOptions` is not a line git reads as `git merge`
    /// options: an open quote, a word it does not know, or an option
    /// without its value.
    InvalidMergeOptions,
    /// `branch.<name>.mergeOptions` asks for what this merge does not do:
    /// `--squash`, `--log`, `-F`, `--into-name`, a strategy other than
    /// `ort`, `--no-overwrite-ignore`, or an action.
    UnsupportedMergeOption,
    /// `merge.branchdesc` lists a merged branch whose
    /// `branch.<name>.description` has no value, which git dies on.
    InvalidBranchDescription,
    /// No commit was named and `merge.defaultToUpstream` is off.
    NoMergeTarget,
    /// No commit was named and the current branch has no upstream:
    /// `branch.<name>.remote` and `branch.<name>.merge`.
    NoDefaultUpstream,
    /// The upstream's remote-tracking ref is not there: nothing has been
    /// fetched for it.
    UpstreamNotFetched,
    /// The index still has conflicts; they are resolved before a merge is
    /// concluded.
    UnresolvedConflicts,
    /// The message left after cleanup is empty.
    EmptyMessage,
} || three_way.Error || head_mod.Error || rev_walk.Error || pretty.Error || refs_mod.ReadError || repo_mod.WriteError || rerere.Error || commit_hooks.Error ||
    stash.Error;

/// When a merge may be a fast-forward: `merge.ff` and `--ff`, `--no-ff`,
/// `--ff-only`.
pub const FastForward = enum { allow, never, only };

/// What the merged commit is, which decides the words the message uses.
pub const Kind = enum {
    branch,
    remote_branch,
    tag,
    commit,
    /// A remote's `HEAD`, which the message names by the remote alone.
    remote_head,
    /// Another ref of a remote, which the message lists among commits.
    remote_ref,
};

/// A commit to merge and the name it was asked for by.
pub const Target = struct {
    oid: Oid,
    /// As the person typed it: `topic`, `origin/main`, a hex name. The
    /// message quotes it, the reflog names it and its side of a conflict
    /// is labelled with it. Borrowed.
    name: []const u8,
    kind: Kind,
    /// Where it came from, as `FETCH_HEAD` says: `.` for this repository,
    /// or the URL of the remote it was fetched from. Borrowed.
    source: []const u8 = ".",
    /// The words the message names it with, as `FETCH_HEAD` has them --
    /// `'main'` of `branch 'main' of <url>` -- when they are not `name`
    /// quoted. Borrowed.
    what: ?[]const u8 = null,
};

/// What `fetchHead` reads into.
pub const FetchHeadOptions = struct { arena: Allocator };

/// What `git merge FETCH_HEAD` merges, git's `handle_fetch_head`: every
/// line of `FETCH_HEAD` marked for merging, in order, each named by its
/// object's full name and described as the line describes it. A line that
/// is not one, or names no commit, is `error.NotACommit`; no `FETCH_HEAD`
/// is `error.NoFetchHead`. Everything lives in `options.arena`.
pub fn fetchHead(io: Io, repo: *Repository, options: FetchHeadOptions) Self.Error![]const Target {
    const arena = options.arena;
    const text = (try repo.refStore().special().readAll(arena, io, .fetch_head)) orelse return error.NoFetchHead;
    const hex_len = repo.objectFormat().hexLen();
    var out: std.ArrayList(Target) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break;
        if (line.len < hex_len + 2) return error.NotACommit;
        const oid = Oid.parse(repo.objectFormat(), line[0..hex_len]) catch return error.NotACommit;
        if (!std.mem.eql(u8, line[hex_len .. hex_len + 2], "\t\t")) continue;
        var target = try describedTarget(line[hex_len + 2 ..]);
        target.name = line[0..hex_len];
        try out.append(arena, try targetOf(io, repo, oid, target));
    }
    return out.items;
}

/// A `FETCH_HEAD` description read as `fmt-merge-msg`'s `handle_line`
/// reads it: `<kind> <what> of <source>`, or a remote's `HEAD` named by
/// the source alone.
fn describedTarget(description: []const u8) Error!Target {
    var target: Target = .{ .oid = undefined, .name = undefined, .kind = .remote_head, .source = description };
    const at = std.mem.find(u8, description, " of ") orelse return target;
    const item = description[0..at];
    target.source = description[at + 4 ..];
    const kinds = [_]struct { prefix: []const u8, kind: Kind }{
        .{ .prefix = "branch ", .kind = .branch },
        .{ .prefix = "tag ", .kind = .tag },
        .{ .prefix = "remote-tracking branch ", .kind = .remote_branch },
    };
    for (kinds) |k| {
        if (std.mem.startsWith(u8, item, k.prefix)) {
            target.kind = k.kind;
            target.what = item[k.prefix.len..];
            return target;
        }
    }
    target.kind = .remote_ref;
    target.what = item;
    return target;
}

/// Find what `name` means the way `git merge <name>` does: a full ref, then
/// `refs/<name>`, `refs/tags/<name>`, `refs/heads/<name>`,
/// `refs/remotes/<name>` and `refs/remotes/<name>/HEAD`, and otherwise an
/// object name or a unique prefix of one. `name` is borrowed by the result.
pub fn resolve(gpa: Allocator, io: Io, repo: *Repository, name: []const u8) Self.Error!Target {
    const rules = ref_names.rev_parse_rules;
    inline for (rules) |rule| {
        const full = try gpa.print(rule, .{name});
        defer gpa.free(full);
        if (std.mem.startsWith(u8, full, "refs/") or std.mem.eql(u8, rule, "{s}")) {
            if (repo.refStore().resolve(gpa, io, full) catch null) |resolved| {
                defer gpa.free(resolved.name);
                const kind: Kind = if (std.mem.startsWith(u8, resolved.name, "refs/heads/"))
                    .branch
                else if (std.mem.startsWith(u8, resolved.name, "refs/tags/"))
                    .tag
                else if (std.mem.startsWith(u8, resolved.name, "refs/remotes/"))
                    .remote_branch
                else
                    .commit;
                return targetOf(io, repo, resolved.oid, .{ .oid = undefined, .name = name, .kind = kind });
            }
        }
    }
    const oid = repo.objectDatabase().findPrefix(io, name) catch return error.NotACommit;
    return targetOf(io, repo, oid, .{ .oid = undefined, .name = name, .kind = .commit });
}

/// What `git merge` with no commit merges: the upstreams of the current
/// branch, each `branch.<name>.merge` as the remote-tracking ref the
/// remote's fetch refspecs map it to -- or the ref itself for a remote of
/// `.` -- named by its full name, as git names it in the message. More than
/// one is an octopus, `startHeads`. The names live in `arena`.
pub const UpstreamOptions = struct { arena: Allocator };

pub fn upstreams(gpa: Allocator, io: Io, repo: *Repository, options: UpstreamOptions) Self.Error![]const Target {
    const arena = options.arena;
    if (!(repo.configuration().getBool("merge.defaulttoupstream", true) catch true)) return error.NoMergeTarget;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const branch = head.shortName() orelse return error.NoDefaultUpstream;
    const remote = repo.configuration().get(try arena.print("branch.{s}.remote", .{branch})) orelse
        return error.NoDefaultUpstream;
    const merges = try repo.configuration().all(try arena.print("branch.{s}.merge", .{branch}));
    defer repo.configuration().gpa.free(merges);
    if (merges.len == 0) return error.NoDefaultUpstream;
    const specs = try repo.configuration().all(try arena.print("remote.{s}.fetch", .{remote}));
    defer repo.configuration().gpa.free(specs);
    const out = try arena.alloc(Target, merges.len);
    for (merges, out) |merge_name, *target| {
        var name: []const u8 = try arena.dupe(u8, merge_name);
        if (!std.mem.eql(u8, remote, ".")) {
            const tracking: ?[]const u8 = for (specs) |text| {
                const spec = refspec.Refspec.parse(text, .fetch, repo.objectFormat()) catch continue;
                if (try spec.mapSource(arena, name)) |mapped| break mapped;
            } else null;
            name = tracking orelse return error.UpstreamNotFetched;
        }
        const resolved = (try repo.refStore().resolve(gpa, io, name)) orelse return error.UpstreamNotFetched;
        defer gpa.free(resolved.name);
        const kind: Kind = if (std.mem.startsWith(u8, name, "refs/heads/"))
            .branch
        else if (std.mem.startsWith(u8, name, "refs/tags/"))
            .tag
        else if (std.mem.startsWith(u8, name, "refs/remotes/"))
            .remote_branch
        else
            .commit;
        target.* = try targetOf(io, repo, resolved.oid, .{ .oid = undefined, .name = name, .kind = kind });
    }
    return out;
}

fn targetOf(io: Io, repo: *Repository, oid: Oid, described: Target) Error!Target {
    const header = try repo.objectDatabase().readHeader(io, oid);
    var target = described;
    target.oid = oid;
    switch (header.type) {
        .commit => return target,
        .tag => return error.AnnotatedTag,
        else => return error.NotACommit,
    }
}

/// How a merge is made.
pub const Options = struct {
    /// Who commits, and when; also who the reflog lines are by.
    who: object.Signature,
    /// Who the merge commit is by. The committer when `null`.
    author: ?object.Signature = null,
    /// `null` asks `branch.<name>.mergeOptions`, then `merge.ff`.
    fast_forward: ?FastForward = null,
    /// `false` stops before committing even a clean merge: `--no-commit`.
    /// `null` asks `branch.<name>.mergeOptions`, and commits.
    commit: ?bool = null,
    /// The merge commit's message, in place of the title git would write:
    /// `-m`. `merge.log`'s list still follows it, as it follows git's.
    message: ?[]const u8 = null,
    /// `--signoff`; `null` asks `branch.<name>.mergeOptions`.
    signoff: ?bool = null,
    /// How the message is cleaned: `--cleanup`. `null` asks
    /// `commit.cleanup`, whose default, with no editor, is `whitespace`.
    cleanup: ?message.Cleanup = null,
    /// `--allow-unrelated-histories`; `null` asks
    /// `branch.<name>.mergeOptions`.
    allow_unrelated_histories: ?bool = null,
    /// `null` asks `merge.conflictStyle`.
    conflict_style: ?merge.ConflictStyle = null,
    /// `-X`: the strategy options, in the order given, as
    /// `strategy.Settings.apply` reads them.
    strategy_options: []const []const u8 = &.{},
    /// The filter drivers and relic's own LFS the merged files go through,
    /// as `Repository.loadFilters` gives them: `three_way.Options.filters`.
    filters: ?*const filter.Drivers = null,
    /// The permission to run the filters' programs.
    programs: ?program.Programs = null,
    /// The hooks to run, or `null` for none: `pre-merge-commit`,
    /// `prepare-commit-msg`, `commit-msg` and `post-merge`, as `git merge`
    /// runs them.
    hooks: ?*hooks_mod.Runner = null,
    /// `false` skips `pre-merge-commit` and `commit-msg`: `--no-verify`.
    /// `null` asks `branch.<name>.mergeOptions`, and runs them.
    verify: ?bool = null,
    /// Whether and how the commits are signed: `-S`, `-S<key>`,
    /// `--no-gpg-sign`, or `commit.gpgSign` by default, with the programs
    /// that sign.
    signing: signing_mod.Request = .{},
    /// Caller-owned output for a refused write or failed signing program.
    diagnostic: ?*repo_mod.Diagnostic = null,
    /// Where a refusal writes the path that caused it.
    blocked: ?*three_way.Blocked = null,
    /// Stage what a recorded resolution resolves: `--rerere-autoupdate`,
    /// `--no-rerere-autoupdate`, or `rerere.autoUpdate` when `null`.
    rerere_autoupdate: ?bool = null,
    /// Keep the inner merges' messages in `Outcome.messages`, as git does at
    /// `GIT_MERGE_VERBOSITY=5`.
    inner_messages: bool = false,
    /// `--autostash`, `--no-autostash`, or `merge.autoStash` when `null`:
    /// the changes in the index and the working tree are put aside before
    /// the merge and brought back at its end, or, when it stops, once it is
    /// concluded or aborted. `Outcome.autostash` and `Outcome.restored`.
    autostash: ?bool = null,
    /// `--verify-signatures`, `--no-verify-signatures`, or
    /// `merge.verifySignatures` when `null`: every commit merged must carry
    /// a good signature from a trusted key, checked with `signing`'s
    /// programs, or the merge is refused before anything is written.
    /// `Outcome.signatures`.
    verify_signatures: ?bool = null,
    /// Where a refused signature check writes the commit and who its
    /// signature claims to be by.
    unverified: ?*Unverified = null,
    /// The text before `: <what happened>` in the reflog: git's
    /// `GIT_REFLOG_ACTION`, which `git pull` sets. `null` writes `merge`
    /// and the names merged.
    reflog_action: ?[]const u8 = null,
};

/// A commit whose signature a merge refused, and who the signature claims
/// to be by.
pub const Unverified = struct {
    commit: ?Oid = null,
    buffer: [256]u8 = undefined,
    len: usize = 0,

    /// Who the signature claims to be by, or empty.
    pub fn signer(u: *const Unverified) []const u8 {
        return u.buffer[0..u.len];
    }

    fn set(u: *Unverified, commit: Oid, text: []const u8) void {
        u.commit = commit;
        u.len = @min(text.len, u.buffer.len);
        @memcpy(u.buffer[0..u.len], text[0..u.len]);
    }
};

/// A commit merged with a good signature: git's "Commit <name> has a good
/// GPG signature by <signer>".
pub const Verified = struct {
    commit: Oid,
    signer: []const u8,
};

/// What a merge did.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    result: Result,
    /// The commit `HEAD` now names: the fast-forward's target or the merge
    /// commit. `null` when nothing was committed.
    commit: ?Oid = null,
    /// The paths left conflicted, sorted.
    conflicts: []const three_way.Conflict = &.{},
    /// What git's merge says about the paths it merged, grouped by path.
    messages: []const ort.Message = &.{},
    /// Conflicted paths a resolution rerere recorded before resolved: in
    /// the working tree, and staged when `rerere_autoupdate` says so.
    reused: []const []const u8 = &.{},
    /// The stash the merge made of the changes in its way: git's "Created
    /// autostash". While the merge is stopped it waits in `MERGE_AUTOSTASH`.
    autostash: ?Oid = null,
    /// What became of `MERGE_AUTOSTASH` when the merge finished.
    restored: ?stash.Restored = null,
    /// The commits merged whose signatures were verified, in order.
    signatures: []const Verified = &.{},

    pub const Result = enum {
        /// The commit was already part of the branch; nothing changed.
        up_to_date,
        /// The branch moved forward to the commit.
        fast_forward,
        /// A merge commit was made.
        merged,
        /// The merge was clean and left staged, as `--no-commit` asks.
        staged,
        /// The merge stopped with conflicts.
        conflicted,
    };

    /// Release the outcome.
    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

/// Whether a merge is waiting to be concluded: `MERGE_HEAD` is there.
pub fn inProgress(io: Io, repo: *Repository) Io.Cancelable!bool {
    return (try repo.refStore().special().exists(io, .merge_head));
}

/// Merge `target` into the current branch.
pub fn start(gpa: Allocator, io: Io, repo: *Repository, target: Target, options: Options) Self.Error!Outcome {
    return startHeads(gpa, io, repo, &.{target}, options);
}

/// Merge `targets` into the current branch, as `git merge` with them all
/// does. A target `HEAD` or another target already reaches is dropped
/// first. One left is merged by ort; two or more by git's octopus,
/// `three_way.applyOctopus`, whose commit leaves `HEAD` out of its parents
/// `options` under the branch's `branch.<name>.mergeOptions`: what that
/// setting says fills what the caller left `null`, and its `-X` words come
/// before the caller's, as git parses it before the command line.
fn withBranchMergeOptions(arena: Allocator, io: Io, repo: *Repository, given: Options) Error!Options {
    var head = try head_mod.read(arena, io, repo);
    defer head.deinit(arena);
    const branch = head.branch orelse return given;
    if (!std.mem.startsWith(u8, branch, "refs/heads/")) return given;
    const key = try arena.print("branch.{s}.mergeoptions", .{branch["refs/heads/".len..]});
    const text = repo.configuration().get(key) orelse return given;
    var set: Options = .{ .who = given.who };
    try parseMergeOptions(arena, text, &set);
    var out = given;
    inline for (.{ "fast_forward", "commit", "message", "signoff", "cleanup", "allow_unrelated_histories", "verify", "rerere_autoupdate", "autostash", "verify_signatures" }) |field| {
        if (@field(out, field) == null) @field(out, field) = @field(set, field);
    }
    if (out.signing.sign == .config) {
        out.signing.sign = set.signing.sign;
        out.signing.key = set.signing.key;
    }
    out.strategy_options = try std.mem.concat(arena, []const u8, &.{ set.strategy_options, given.strategy_options });
    return out;
}

/// `git merge`'s options, as `parse_options` reads `builtin_merge_options`
/// from a `branch.<name>.mergeOptions` split as `split_cmdline` splits it:
/// long options by any unique beginning, `--no-` for those that take it,
/// short ones bundled, and words that are no option passed over. What only
/// a command line shows is read and left (`--stat`, `-q`, `--edit`,
/// `--progress`); what this merge does not do -- `--squash`, `--log`, a
/// strategy other than `ort` -- is `UnsupportedMergeOption`, and a word
/// git does not know `InvalidMergeOptions`.
fn parseMergeOptions(arena: Allocator, text: []const u8, set: *Options) Error!void {
    const words = (try quote.splitCmdline(arena, text)) orelse return error.InvalidMergeOptions;
    var messages: std.ArrayList([]const u8) = .empty;
    var xopts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const word = words[i];
        if (std.mem.eql(u8, word, "--")) break;
        if (std.mem.startsWith(u8, word, "--")) {
            var name = word[2..];
            var value: ?[]const u8 = null;
            if (std.mem.findScalar(u8, name, '=')) |eq| {
                value = name[eq + 1 ..];
                name = name[0..eq];
            }
            const negated = std.mem.startsWith(u8, name, "no-");
            const option = findLong(if (negated) name[3..] else name, negated) orelse return error.InvalidMergeOptions;
            if (negated and !option.negatable) return error.InvalidMergeOptions;
            if (option.takes == .none and value != null) return error.InvalidMergeOptions;
            if (option.takes == .required and value == null and !negated) {
                i += 1;
                if (i == words.len) return error.InvalidMergeOptions;
                value = words[i];
            }
            try applyMergeOption(arena, set, &messages, &xopts, option.which, !negated, value);
            continue;
        }
        if (word.len < 2 or word[0] != '-') continue;
        var at: usize = 1;
        while (at < word.len) : (at += 1) {
            const option = findShort(word[at]) orelse return error.InvalidMergeOptions;
            var value: ?[]const u8 = null;
            if (option.takes != .none) {
                if (at + 1 < word.len) {
                    value = word[at + 1 ..];
                } else if (option.takes == .required) {
                    i += 1;
                    if (i == words.len) return error.InvalidMergeOptions;
                    value = words[i];
                }
                try applyMergeOption(arena, set, &messages, &xopts, option.which, true, value);
                break;
            }
            try applyMergeOption(arena, set, &messages, &xopts, option.which, true, null);
        }
    }
    if (messages.items.len != 0) set.message = try std.mem.join(arena, "\n\n", messages.items);
    set.strategy_options = xopts.items;
}

const MergeOption = enum {
    stat,
    no_stat_short,
    compact_summary,
    log,
    squash,
    commit,
    edit,
    cleanup,
    ff,
    ff_only,
    rerere_autoupdate,
    verify_signatures,
    strategy,
    strategy_option,
    message,
    file,
    into_name,
    quiet,
    verbose,
    abort,
    quit,
    @"continue",
    allow_unrelated_histories,
    progress,
    gpg_sign,
    autostash,
    overwrite_ignore,
    signoff,
    verify,
};

const OptionSpec = struct {
    long: ?[]const u8,
    short: ?u8 = null,
    which: MergeOption,
    takes: enum { none, required, optional } = .none,
    negatable: bool = true,
};

/// git 2.55's `builtin_merge_options`, in its order.
const merge_options = [_]OptionSpec{
    .{ .long = null, .short = 'n', .which = .no_stat_short, .negatable = false },
    .{ .long = "stat", .which = .stat },
    .{ .long = "summary", .which = .stat },
    .{ .long = "compact-summary", .which = .compact_summary },
    .{ .long = "log", .which = .log, .takes = .optional },
    .{ .long = "squash", .which = .squash },
    .{ .long = "commit", .which = .commit },
    .{ .long = "edit", .short = 'e', .which = .edit },
    .{ .long = "cleanup", .which = .cleanup, .takes = .required },
    .{ .long = "ff", .which = .ff },
    .{ .long = "ff-only", .which = .ff_only, .negatable = false },
    .{ .long = "rerere-autoupdate", .which = .rerere_autoupdate },
    .{ .long = "verify-signatures", .which = .verify_signatures },
    .{ .long = "strategy", .short = 's', .which = .strategy, .takes = .required },
    .{ .long = "strategy-option", .short = 'X', .which = .strategy_option, .takes = .required },
    .{ .long = "message", .short = 'm', .which = .message, .takes = .required },
    .{ .long = "file", .short = 'F', .which = .file, .takes = .required, .negatable = false },
    .{ .long = "into-name", .which = .into_name, .takes = .required },
    .{ .long = "quiet", .short = 'q', .which = .quiet },
    .{ .long = "verbose", .short = 'v', .which = .verbose },
    .{ .long = "abort", .which = .abort },
    .{ .long = "quit", .which = .quit },
    .{ .long = "continue", .which = .@"continue" },
    .{ .long = "allow-unrelated-histories", .which = .allow_unrelated_histories },
    .{ .long = "progress", .which = .progress },
    .{ .long = "gpg-sign", .short = 'S', .which = .gpg_sign, .takes = .optional },
    .{ .long = "autostash", .which = .autostash },
    .{ .long = "overwrite-ignore", .which = .overwrite_ignore },
    .{ .long = "signoff", .which = .signoff },
    .{ .long = "verify", .which = .verify },
};

/// The option a long name names, exactly or by a beginning only it has.
fn findLong(name: []const u8, negated: bool) ?OptionSpec {
    var found: ?OptionSpec = null;
    var count: usize = 0;
    for (merge_options) |o| {
        const long = o.long orelse continue;
        if (negated and !o.negatable) continue;
        if (std.mem.eql(u8, long, name)) return o;
        if (name.len != 0 and std.mem.startsWith(u8, long, name)) {
            found = o;
            count += 1;
        }
    }
    return if (count == 1) found else null;
}

fn findShort(c: u8) ?OptionSpec {
    for (merge_options) |o| if (o.short == c) return o;
    return null;
}

fn applyMergeOption(arena: Allocator, set: *Options, messages: *std.ArrayList([]const u8), xopts: *std.ArrayList([]const u8), which: MergeOption, on: bool, value: ?[]const u8) Error!void {
    switch (which) {
        // What only a command line shows, or an editor would.
        .stat, .no_stat_short, .compact_summary, .edit, .quiet, .verbose, .progress => {},
        .overwrite_ignore => if (!on) return error.UnsupportedMergeOption,
        .commit => set.commit = on,
        .ff => set.fast_forward = if (on) .allow else .never,
        .ff_only => set.fast_forward = .only,
        .rerere_autoupdate => set.rerere_autoupdate = on,
        .verify_signatures => set.verify_signatures = on,
        .allow_unrelated_histories => set.allow_unrelated_histories = on,
        .autostash => set.autostash = on,
        .signoff => set.signoff = on,
        .verify => set.verify = on,
        .cleanup => set.cleanup = if (on) message.Cleanup.parse(value.?) orelse return error.InvalidMergeOptions else null,
        .message => if (on) try messages.append(arena, value.?) else messages.clearRetainingCapacity(),
        .strategy_option => if (on) try xopts.append(arena, value.?) else xopts.clearRetainingCapacity(),
        .strategy => if (on) {
            const name = value.?;
            if (!std.mem.eql(u8, name, "ort") and !std.mem.eql(u8, name, "recursive")) return error.UnsupportedMergeOption;
        },
        .gpg_sign => {
            set.signing.sign = if (on) .always else .never;
            set.signing.key = if (on and value != null and value.?.len != 0) value else null;
        },
        .squash, .log, .file, .into_name, .abort, .quit, .@"continue" => if (on or which == .log) return error.UnsupportedMergeOption,
    }
}

/// when a target already contains it and a fast-forward is allowed.
pub fn startHeads(gpa: Allocator, io: Io, repo: *Repository, targets: []const Target, given: Options) Self.Error!Outcome {
    diagnostic.reset(given.diagnostic);
    // git's `cmd_merge` reads `commit.cleanup` before it merges anything,
    // and dies there on a mode it does not know.
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // `branch.<name>.mergeOptions`, under what the caller gives.
    var options = try withBranchMergeOptions(arena, io, repo, given);
    const asked_cleanup = options.cleanup;
    const cleanup_setting = try message.cleanupSetting(repo.configuration());
    options.cleanup = asked_cleanup orelse try message.cleanupMode(cleanup_setting, false);
    // The conflicts list is written as for an editor, whether one runs or
    // not, as git's `suggest_conflicts` writes it.
    const hint_cleanup = asked_cleanup orelse try message.cleanupMode(cleanup_setting, true);

    if (targets.len == 0) return error.NoMergeTarget;
    if ((try inProgress(io, repo))) return error.MergeInProgress;
    if ((try repo.refStore().root().exists(repo.allocator(), io, .cherry_pick_head)) or
        (try repo.refStore().root().exists(repo.allocator(), io, .revert_head))) return error.SequencerInProgress;
    // `git merge` reads `fmt_merge_msg_config`'s settings at its start too,
    // and the diff's (`git_diff_ui_config`): every `diff.renames` and
    // `diff.renameLimit` value, where the merge itself reads the last.
    const settings = try MessageSettings.read(arena, repo.configuration());
    _ = diff.RenameSettings.read(repo.configuration()) catch return error.InvalidMergeSetting;
    // `git_merge_config` reads `merge.autoStash` with `git_config_bool`,
    // which dies on a value that is no boolean, asked for or not.
    const configured_autostash = try repo.configuration().getBool("merge.autostash", false);
    options.autostash = given.autostash orelse configured_autostash;
    const configured_verify = try repo.configuration().getBool("merge.verifysignatures", false);
    options.verify_signatures = given.verify_signatures orelse configured_verify;

    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const ours = head.oid orelse return error.UnbornBranch;
    const fast_forward = options.fast_forward orelse configuredFastForward(repo);

    // The index is locked only once the work in the way is put aside,
    // which takes the lock itself.
    {
        var index = try repo.openIndex(io);
        defer index.deinit();
        for (index.entries.items) |entry| {
            if (entry.stage != 0) {
                if (options.blocked) |b| b.set(entry.path);
                return error.UnmergedIndex;
            }
        }
    }

    // One target needs no reducing: the merge bases below say whether
    // `HEAD` reaches it or it reaches `HEAD`.
    const reduced: Reduced = if (targets.len == 1) .{ .heads = targets, .head_subsumed = false } else try reduceParents(gpa, arena, io, repo, ours, targets);
    // The reflog names the targets left.
    var action: std.ArrayList(u8) = .empty;
    try action.appendSlice(arena, "merge");
    for (reduced.heads) |target| {
        try action.append(arena, ' ');
        try action.appendSlice(arena, target.name);
    }
    const reflog_action = options.reflog_action orelse action.items;
    // git makes the message with the targets it merges, before anything
    // else: a list `merge.log` asks for is read now, and fails now. A single
    // target `HEAD` already has is no target, as git's `reduce_parents`
    // leaves it.
    const already_merged = settings.log != 0 and targets.len == 1 and
        try rev_walk.isAncestor(gpa, io, repo.objectDatabase(), .{ .ancestor = reduced.heads[0].oid, .descendant = ours }, .{});
    const merge_message = if (reduced.heads.len == 0 or already_merged) "" else try mergeMessage(arena, io, repo, .{ .targets = reduced.heads, .head = head, .given = options.message, .settings = settings });
    if (reduced.heads.len > 1) {
        const signatures = try verifySignatures(gpa, arena, io, repo, reduced.heads, options);
        var out = try octopus(gpa, io, repo, &arena_instance, .{ .head = head, .reduced = reduced, .reflog_action = reflog_action, .fast_forward = fast_forward, .message = merge_message, .hint_cleanup = hint_cleanup }, options);
        out.signatures = signatures;
        return out;
    }

    try repo.refStore().root().write(repo.allocator(), io, .orig_head, ours);
    if (reduced.heads.len == 0) return .{ .gpa = gpa, .arena = arena_instance.state, .result = .up_to_date };
    const target = reduced.heads[0];
    const bases = try rev_walk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = ours, .b = target.oid }, .{});
    defer gpa.free(bases);

    if (bases.len == 1 and bases[0].eql(target.oid)) {
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .up_to_date };
    }
    // A target `HEAD` has is no target, as git's `reduce_parents` leaves
    // it, and its signature is not asked about.
    const signatures = try verifySignatures(gpa, arena, io, repo, reduced.heads, options);
    if (bases.len == 0 and !(options.allow_unrelated_histories orelse false)) return error.UnrelatedHistories;

    const forward = fast_forward != .never and bases.len == 1 and bases[0].eql(ours);
    if (!forward and fast_forward == .only) return error.NotFastForward;
    const stashed = try putAside(io, repo, options);
    var out = mergeOne(gpa, io, repo, &arena_instance, .{
        .head = head,
        .target = target,
        .bases = bases,
        .forward = forward,
        .message = merge_message,
        .hint_cleanup = hint_cleanup,
        .reflog_action = reflog_action,
        .fast_forward = fast_forward,
    }, options) catch |err| {
        try giveBack(io, repo, stashed, options);
        return err;
    };
    out.autostash = stashed;
    out.signatures = signatures;
    return out;
}

/// `verifySignatures` for a caller that merges by other means, as `git
/// pull` checks the commit an unborn branch takes: each of `heads` refused
/// as a merge would refuse it, when `options.verify_signatures` is `true`.
/// `merge.verifySignatures` is not read.
pub fn verify(gpa: Allocator, io: Io, repo: *Repository, heads: []const Target, options: Options) Self.Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    _ = try verifySignatures(gpa, arena_instance.allocator(), io, repo, heads, options);
}

/// git's `verify_merge_signature` for each commit to merge, when
/// `options.verify_signatures` asks: a
/// good signature from a trusted key, or the merge is refused. The trust is
/// git's own check, marginal at least, only when `gpg.minTrustLevel` is not
/// set; when it is, the signature's check against it decides. What was
/// verified lives in `arena`.
fn verifySignatures(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, heads: []const Target, options: Options) Error![]const Verified {
    if (!(options.verify_signatures orelse false)) return &.{};
    const programs = options.signing.programs orelse return error.SigningRequiresPrograms;
    var signer = try signing_mod.Signer.init(gpa, io, repo.configuration(), repo.topDirectory(), programs);
    defer signer.deinit();
    const check_trust = !repo.configuration().has("gpg.mintrustlevel");
    const verified = try arena.alloc(Verified, heads.len);
    for (heads, verified) |target, *out| {
        const found = try repo.objectDatabase().read(io, target.oid);
        defer repo.objectDatabase().allocator().free(found.bytes);
        var verdict = try signing_mod.verifyCommit(io, &signer, repo.objectFormat(), found.bytes);
        defer verdict.deinit();
        const by = verdict.signer orelse "";
        const refused: ?Error = switch (verdict.result) {
            .good => if (!verdict.verified(signer.min_trust) or
                (check_trust and @backingInt(verdict.trust) < @backingInt(signing_mod.Trust.marginal))) error.UntrustedSignature else null,
            .bad => error.BadSignature,
            else => error.MissingSignature,
        };
        if (refused) |err| {
            if (options.unverified) |u| u.set(target.oid, by);
            return err;
        }
        out.* = .{ .commit = target.oid, .signer = try arena.dupe(u8, by) };
    }
    return verified;
}

/// git's `create_autostash_ref`: when asked, the changes in the merge's way
/// put aside under `MERGE_AUTOSTASH`, before the merge locks the index.
fn putAside(io: Io, repo: *Repository, options: Options) Error!?Oid {
    if (!options.autostash.?) return null;
    return stash.createAutostash(io, repo, autostash_place, .{ .who = options.who, .filters = options.filters, .programs = options.programs });
}

/// A merge that failed after putting the work in its way aside gives it
/// back, as git's does.
fn giveBack(io: Io, repo: *Repository, stashed: ?Oid, options: Options) Error!void {
    if (stashed == null) return;
    _ = try stash.restoreAutostash(io, repo, autostash_place, restoreOptions(options));
}

/// How `MERGE_AUTOSTASH` is brought back for a merge made with `options`.
fn restoreOptions(options: Options) stash.RestoreOptions {
    return .{ .who = options.who, .hooks = options.hooks, .filters = options.filters, .programs = options.programs };
}

/// Where a merge keeps its autostash.
const autostash_place: stash.Autostash = .{ .ref = .merge_autostash };

/// One target, decided on: what `mergeOne` merges.
const One = struct {
    head: head_mod.Head,
    target: Target,
    bases: []const Oid,
    /// A fast-forward, rather than a merge.
    forward: bool,
    message: []const u8,
    hint_cleanup: message.Cleanup,
    reflog_action: []const u8,
    fast_forward: FastForward,
};

/// Fast-forward to one target or merge it, under the index's lock.
fn mergeOne(gpa: Allocator, io: Io, repo: *Repository, arena_instance: *std.heap.ArenaAllocator, one: One, options: Options) Error!Outcome {
    const arena = arena_instance.allocator();
    const head = one.head;
    const ours = head.oid.?;
    const target = one.target;
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    const our_tree = try repo.commitTree(io, ours);
    const their_tree = try repo.commitTree(io, target.oid);

    if (one.forward) {
        var outcome = try three_way.fastForward(gpa, io, repo, .{ .index = index, .old = our_tree, .new = their_tree }, .{ .blocked = options.blocked });
        defer outcome.deinit();
        try locked_index.commit(io);
        const log_message = try arena.print("{s}: Fast-forward", .{one.reflog_action});
        try head_mod.advance(io, repo, head, target.oid, .{ .who = options.who, .message = log_message });
        if (options.hooks) |runner| _ = try runner.postMerge(io, .{ .squash = false });
        const restored = try stash.restoreAutostash(io, repo, autostash_place, restoreOptions(options));
        try removeMergeState(io, repo, options.who);
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .fast_forward, .commit = target.oid, .restored = restored };
    }

    // The bases oldest first, as git hands them to its recursive merge.
    const reversed = try arena.alloc(Oid, one.bases.len);
    for (one.bases, 0..) |base, i| reversed[one.bases.len - 1 - i] = base;
    const style = options.conflict_style orelse try merge.configuredStyle(repo.configuration());
    var outcome = try three_way.applyCommits(gpa, io, repo, .{ .index = index, .ours = ours, .theirs = target.oid, .bases = reversed }, .{
        .blob = .{
            .conflict_style = style,
            .labels = .{ .ours = "HEAD", .theirs = target.name },
            .algorithm = .histogram,
        },
        .strategy_options = options.strategy_options,
        .filters = options.filters,
        .programs = options.programs,
        .blocked = options.blocked,
        .inner_messages = options.inner_messages,
    });
    defer outcome.deinit();
    try locked_index.commit(io);
    try repo.refStore().root().write(repo.allocator(), io, .auto_merge, outcome.auto_merge);
    return commitOrStop(gpa, io, repo, arena_instance, &outcome, .{
        .head = head,
        .parents = &.{ ours, target.oid },
        .merged = &.{target.oid},
        .message = one.message,
        .hint_cleanup = one.hint_cleanup,
        .reflog_action = one.reflog_action,
        .strategy = "ort",
        .fast_forward = one.fast_forward,
    }, options);
}

/// The targets left once every one `HEAD` or another target reaches is
/// dropped, in the order given, the first of any repeated kept: git's
/// `reduce_parents`. `head_subsumed` says a target reaches `HEAD`.
const Reduced = struct {
    heads: []const Target,
    head_subsumed: bool,
};

fn reduceParents(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, ours: Oid, targets: []const Target) Error!Reduced {
    var oids: std.ArrayList(Oid) = .empty;
    try oids.append(arena, ours);
    for (targets) |target| try oids.append(arena, target.oid);
    const kept_oids = try reduceHeads(gpa, arena, io, repo, oids.items);
    var kept: std.ArrayList(Target) = .empty;
    var head_subsumed = true;
    for (kept_oids) |oid| {
        if (oid.eql(ours)) {
            head_subsumed = false;
            continue;
        }
        for (targets) |target| {
            if (target.oid.eql(oid)) break try kept.append(arena, target);
        }
    }
    return .{ .heads = kept.items, .head_subsumed = head_subsumed };
}

/// git's `reduce_heads`: `oids` in order, each only once, without any one
/// another reaches. The result lives in `arena`.
fn reduceHeads(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, oids: []const Oid) Error![]const Oid {
    var unique: std.ArrayList(Oid) = .empty;
    for (oids) |oid| {
        for (unique.items) |seen| {
            if (seen.eql(oid)) break;
        } else try unique.append(arena, oid);
    }
    var kept: std.ArrayList(Oid) = .empty;
    for (unique.items, 0..) |one, i| {
        const redundant = for (unique.items, 0..) |other, j| {
            if (i != j and try rev_walk.isAncestor(gpa, io, repo.objectDatabase(), .{ .ancestor = one, .descendant = other }, .{})) break true;
        } else false;
        if (!redundant) try kept.append(arena, one);
    }
    return kept.items;
}

/// What `octopus` merges, and how.
const Octopus = struct {
    head: head_mod.Head,
    reduced: Reduced,
    reflog_action: []const u8,
    fast_forward: FastForward,
    message: []const u8,
    hint_cleanup: message.Cleanup,
};

/// `git merge` with two or more commits left to merge: the octopus.
fn octopus(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    arena_instance: *std.heap.ArenaAllocator,
    asked: Octopus,
    options: Options,
) Error!Outcome {
    const head = asked.head;
    const reduced = asked.reduced;
    const fast_forward = asked.fast_forward;
    const arena = arena_instance.allocator();
    const ours = head.oid.?;
    const heads = try arena.alloc(Oid, reduced.heads.len);
    for (reduced.heads, heads) |target, *oid| oid.* = target.oid;
    try repo.refStore().root().write(repo.allocator(), io, .orig_head, ours);
    if (!(options.allow_unrelated_histories orelse false) and !try shareHistory(gpa, arena, io, repo, ours, heads)) return error.UnrelatedHistories;
    // Up to date when `HEAD` reaches every head.
    for (heads) |one| {
        const bases = try rev_walk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = ours, .b = one }, .{});
        defer gpa.free(bases);
        if (bases.len == 0 or !bases[0].eql(one)) break;
    } else return .{ .gpa = gpa, .arena = arena_instance.state, .result = .up_to_date };
    if (fast_forward == .only) return error.NotFastForward;

    const stashed = try putAside(io, repo, options);
    var out = octopusHeads(gpa, io, repo, arena_instance, asked, heads, options) catch |err| {
        try giveBack(io, repo, stashed, options);
        return err;
    };
    out.autostash = stashed;
    return out;
}

/// Merge the octopus's heads, under the index's lock.
fn octopusHeads(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    arena_instance: *std.heap.ArenaAllocator,
    asked: Octopus,
    heads: []const Oid,
    options: Options,
) Error!Outcome {
    const head = asked.head;
    const fast_forward = asked.fast_forward;
    const arena = arena_instance.allocator();
    const ours = head.oid.?;
    var locked = try repo.lockIndex(io);
    defer locked.deinit(io);
    const index = &locked.index;
    var outcome = try three_way.applyOctopus(gpa, io, repo, .{ .index = index, .head = ours, .heads = heads }, .{
        .blob = .{ .conflict_style = options.conflict_style orelse try merge.configuredStyle(repo.configuration()) },
        .filters = options.filters,
        .programs = options.programs,
        .blocked = options.blocked,
    });
    defer outcome.deinit();
    try locked.commit(io);
    var parents: std.ArrayList(Oid) = .empty;
    if (!asked.reduced.head_subsumed or fast_forward == .never) try parents.append(arena, ours);
    try parents.appendSlice(arena, heads);
    return commitOrStop(gpa, io, repo, arena_instance, &outcome, .{
        .head = head,
        .parents = parents.items,
        .merged = heads,
        .message = asked.message,
        .hint_cleanup = asked.hint_cleanup,
        .reflog_action = asked.reflog_action,
        .strategy = "octopus",
        .fast_forward = fast_forward,
    }, options);
}

/// Whether the commits have any merge base at all, folded as git's
/// `get_octopus_merge_bases` folds them.
fn shareHistory(gpa: Allocator, arena: Allocator, io: Io, repo: *Repository, ours: Oid, heads: []const Oid) Error!bool {
    var bases: std.ArrayList(Oid) = .empty;
    try bases.append(arena, ours);
    for (heads) |one| {
        var next: std.ArrayList(Oid) = .empty;
        for (bases.items) |base| {
            const found = try rev_walk.mergeBases(gpa, io, repo.objectDatabase(), .{ .a = one, .b = base }, .{});
            defer gpa.free(found);
            try next.appendSlice(arena, found);
        }
        bases = next;
    }
    return bases.items.len != 0;
}

/// How a merge was made and what it merged, for its end.
const Made = struct {
    head: head_mod.Head,
    parents: []const Oid,
    /// What `MERGE_HEAD` lists.
    merged: []const Oid,
    /// The message `git merge` makes: `-m`'s, or `fmt-merge-msg`'s title,
    /// with `merge.log`'s list after either.
    message: []const u8,
    /// The cleanup the conflicts list is written for: `scissors` puts it
    /// under the scissors line.
    hint_cleanup: message.Cleanup,
    reflog_action: []const u8,
    /// The strategy the reflog names.
    strategy: []const u8,
    fast_forward: FastForward,
};

/// Commit a clean merge the index now holds, or stop with `MERGE_HEAD`,
/// `MERGE_MSG` and `MERGE_MODE` written for a person to finish it.
fn commitOrStop(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    arena_instance: *std.heap.ArenaAllocator,
    outcome: *const three_way.Outcome,
    made: Made,
    options: Options,
) Error!Outcome {
    const arena = arena_instance.allocator();
    const comment = (try message.Comment.read(repo.configuration())).text();
    var msg: std.ArrayList(u8) = .empty;
    // The message as made, byte for byte: no newline at its end.
    try msg.appendSlice(arena, made.message);
    const conflicts = try arena.dupe(three_way.Conflict, outcome.conflicts);
    for (conflicts) |*c| c.path = try arena.dupe(u8, c.path);
    const messages = try ort.dupeMessages(arena, outcome.messages);
    var merge_heads: std.ArrayList(u8) = .empty;
    for (made.merged) |oid| {
        var hex: [hash.max_hex_len]u8 = undefined;
        try merge_heads.appendSlice(arena, oid.hex(&hex));
        try merge_heads.append(arena, '\n');
    }

    if (outcome.isClean() and (options.commit orelse true)) {
        // `prepare_to_commit`: `pre-merge-commit` first, then the message,
        // signed off, into `MERGE_MSG` beside `MERGE_HEAD` for the message
        // hooks, and back out of it.
        const h = try commit_hooks.Hooks.init(arena, io, repo, .{ .runner = options.hooks, .verify = options.verify orelse true });
        if (options.signoff orelse false) try message.appendSignoff(arena, &msg, options.who, try message.trailerSettings(arena, repo.configuration()));
        var text: []const u8 = msg.items;
        if (h.runner) |runner| {
            const e = try h.env(arena, null);
            if (h.verify) _ = try runner.block(io, "pre-merge-commit", .{ .set = &.{
                .{ .name = "GIT_INDEX_FILE", .value = e.index_path },
                .{ .name = "GIT_EDITOR", .value = ":" },
            } });
            try repo.refStore().special().write(repo.allocator(), io, .merge_head, merge_heads.items);
            try state_file.write(io, repo.gitDirectory(), "MERGE_MSG", text);
            const message_path = try h.path(arena, "MERGE_MSG");
            _ = try runner.prepareCommitMsg(io, e, message_path, .{ .source = .merge, .commit = null });
            if (h.verify) _ = try runner.commitMsg(io, e, message_path);
            text = (try state_file.read(arena, io, repo.gitDirectory(), "MERGE_MSG")) orelse "";
        }
        const cleaned = try message.cleanup(arena, text, options.cleanup.?, comment);
        if (cleaned.len == 0) return error.EmptyMessage;
        const commit = try repo.writeCommit(io, .{
            .tree = outcome.tree.?,
            .parents = made.parents,
            .author = options.author orelse options.who,
            .committer = options.who,
            .message = cleaned,
            .signing = options.signing,
        }, .{ .diagnostic = options.diagnostic });
        const log_message = try arena.print("{s}: Merge made by the '{s}' strategy.", .{ made.reflog_action, made.strategy });
        try head_mod.advance(io, repo, made.head, commit, .{ .who = options.who, .message = log_message });
        // `post-merge` runs before the merge's files go, as in git.
        if (options.hooks) |runner| _ = try runner.postMerge(io, .{ .squash = false });
        const restored = try stash.restoreAutostash(io, repo, autostash_place, restoreOptions(options));
        try removeMergeState(io, repo, options.who);
        return .{ .gpa = gpa, .arena = arena_instance.state, .result = .merged, .commit = commit, .messages = messages, .restored = restored };
    }

    // Stopped: with conflicts, or before committing as asked.
    try repo.refStore().special().write(repo.allocator(), io, .merge_head, merge_heads.items);
    // `MERGE_MSG` ends the message with a newline whatever it ended with.
    try msg.append(arena, '\n');
    if (!outcome.isClean()) {
        const paths = try arena.alloc([]const u8, conflicts.len);
        for (conflicts, paths) |conflict, *path| path.* = conflict.path;
        try message.appendConflictsHint(arena, &msg, paths, comment, made.hint_cleanup);
    }
    try state_file.write(io, repo.gitDirectory(), "MERGE_MSG", msg.items);
    try state_file.write(io, repo.gitDirectory(), "MERGE_MODE", if (made.fast_forward == .never) "no-ff" else "");
    var reused: []const []const u8 = &.{};
    if (!outcome.isClean()) reused = try rerere.afterStop(gpa, io, repo, .{ .arena = arena, .autoupdate = options.rerere_autoupdate });
    return .{
        .gpa = gpa,
        .arena = arena_instance.state,
        .result = if (outcome.isClean()) .staged else .conflicted,
        .conflicts = conflicts,
        .messages = messages,
        .reused = reused,
    };
}

/// How a merge waiting in the working tree is concluded.
pub const ConcludeOptions = struct {
    who: object.Signature,
    author: ?object.Signature = null,
    /// The message, in place of `MERGE_MSG`.
    message: ?[]const u8 = null,
    /// How the message is cleaned: `--cleanup`. `null` is what `git commit`
    /// does when a person has seen the message in an editor, `commit.cleanup`
    /// read for one: `strip` by default, which drops the `# Conflicts:` list,
    /// or `scissors`, which cuts it off. `git commit --no-edit` keeps
    /// comments and cleans only whitespace.
    cleanup: ?message.Cleanup = null,
    /// The hooks to run, or `null` for none: `git commit`'s `pre-commit`,
    /// `prepare-commit-msg` with `merge`, `commit-msg` and `post-commit`.
    hooks: ?*hooks_mod.Runner = null,
    /// `false` skips `pre-commit` and `commit-msg`: `--no-verify`.
    verify: bool = true,
    /// Whether and how the commits are signed: `-S`, `-S<key>`,
    /// `--no-gpg-sign`, or `commit.gpgSign` by default, with the programs
    /// that sign.
    signing: signing_mod.Request = .{},
    /// Caller-owned output for a refused write or failed signing program.
    diagnostic: ?*repo_mod.Diagnostic = null,
    /// The filter drivers and the permission to run their programs, for
    /// bringing back `MERGE_AUTOSTASH`.
    filters: ?*const filter.Drivers = null,
    programs: ?program.Programs = null,
};

/// What concluding a merge did.
pub const Concluded = struct {
    /// The merge commit.
    commit: Oid,
    /// What became of `MERGE_AUTOSTASH`, when the merge had one.
    restored: ?stash.Restored = null,
};

/// Commit the merge `MERGE_HEAD` describes, from the index as it stands:
/// what `git commit` and `git merge --continue` do once the conflicts are
/// resolved. Then `MERGE_AUTOSTASH` is brought back, as `git commit`
/// brings it back.
pub fn conclude(gpa: Allocator, io: Io, repo: *Repository, options: ConcludeOptions) Self.Error!Concluded {
    diagnostic.reset(options.diagnostic);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const heads_text = (try repo.refStore().special().readAll(arena, io, .merge_head)) orelse return error.NoMergeInProgress;
    var parents: std.ArrayList(Oid) = .empty;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    try parents.append(arena, head.oid orelse return error.UnbornBranch);
    // git's `get_merge_parent` of each line as `strbuf_getline_lf` cuts
    // it: whatever revision it names, peeled to its commit, and a line
    // that names none a corrupt `MERGE_HEAD`.
    var lines = std.mem.splitScalar(u8, heads_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        const peeled = try arena.print("{s}^{{commit}}", .{line});
        const parent = rev_parse.resolve(arena, io, repo.revisionSource(), peeled) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.MalformedRef,
        };
        try parents.append(arena, parent);
    }
    // `git commit` drops a parent another reaches unless the merge was
    // asked not to fast-forward: an octopus that went past `HEAD`.
    const mode = (try state_file.read(arena, io, repo.gitDirectory(), "MERGE_MODE")) orelse "";
    const kept: []const Oid = if (std.mem.eql(u8, mode, "no-ff")) parents.items else try reduceHeads(gpa, arena, io, repo, parents.items);

    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    for (index.entries.items) |entry| {
        if (entry.stage != 0) return error.UnresolvedConflicts;
    }
    const tree = try worktree.writeTree(gpa, io, index, repo.objectDatabase());
    try locked_index.commit(io);

    const h = try commit_hooks.Hooks.init(arena, io, repo, .{ .runner = options.hooks, .verify = options.verify });
    const author = options.author orelse options.who;
    const given = options.message orelse ((try state_file.read(arena, io, repo.gitDirectory(), "MERGE_MSG")) orelse "");
    // `git commit`'s `prepare_to_commit`: an `auto` comment character is
    // chosen against the message as given, whitespace cleaned, before the
    // hook sees it.
    const cleanup_mode = options.cleanup orelse try message.cleanupMode(try message.cleanupSetting(repo.configuration()), true);
    const comment = try (try message.Comment.read(repo.configuration())).forMessage(if (cleanup_mode == .verbatim) given else try message.stripSpace(arena, given, null));
    const raw = try h.beforeCommit(arena, io, repo, .{ .text = given, .source = .merge, .author = author });
    const cleaned = try message.cleanup(arena, raw, cleanup_mode, comment);
    if (cleaned.len == 0) return error.EmptyMessage;
    const commit = try repo.writeCommit(io, .{
        .tree = tree,
        .parents = kept,
        .author = options.author orelse options.who,
        .committer = options.who,
        .message = cleaned,
        .signing = options.signing,
    }, .{ .diagnostic = options.diagnostic });
    const log_message = try arena.print("commit (merge): {s}", .{message.subjectLine(cleaned)});
    try head_mod.advance(io, repo, head, commit, .{ .who = options.who, .message = log_message });
    try rerere.afterCommit(gpa, io, repo);
    try h.postCommit(arena, io, author);
    const restored = try stash.restoreAutostash(io, repo, autostash_place, .{
        .who = options.who,
        .hooks = options.hooks,
        .filters = options.filters,
        .programs = options.programs,
    });
    return .{ .commit = commit, .restored = restored };
}

/// How a merge is aborted.
pub const AbortOptions = struct {
    /// Who the reflog line is by, and the stash list's if the autostash
    /// goes there.
    who: object.Signature,
    /// Where a refusal writes the path that caused it.
    blocked: ?*three_way.Blocked = null,
    /// Told about the update to `refs/stash`, or `null`.
    hooks: ?*hooks_mod.Runner = null,
    /// The filter drivers and the permission to run their programs, for
    /// bringing back `MERGE_AUTOSTASH`.
    filters: ?*const filter.Drivers = null,
    programs: ?program.Programs = null,
};

/// Undo a merge that stopped: `git merge --abort`, which is `git reset
/// --merge`. Changes a person made before the merge, to paths the merge did
/// not touch, survive it. `MERGE_AUTOSTASH` is then brought back: what
/// became of it, or `null` when there was none.
pub fn abort(gpa: Allocator, io: Io, repo: *Repository, options: AbortOptions) Self.Error!?stash.Restored {
    const who = options.who;
    const blocked = options.blocked;
    if (!(try inProgress(io, repo))) return error.NoMergeInProgress;
    var head = try head_mod.read(gpa, io, repo);
    defer head.deinit(gpa);
    const current = head.oid orelse return error.UnbornBranch;
    var locked_index = try repo.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    try reset.toTree(gpa, io, repo, .{ .index = index, .tree = try repo.commitTree(io, current), .mode = .merge, .blocked = blocked });
    try locked_index.commit(io);
    // git takes `MERGE_AUTOSTASH` out of the way of the `git reset --merge`
    // its `--abort` runs, which would put it on the list, and applies it
    // once the reset is done.
    const stashed = try repo.refStore().root().read(gpa, io, .merge_autostash);
    if (stashed != null) try repo.refStore().root().delete(gpa, io, .merge_autostash);
    try removeMergeState(io, repo, who);
    // `git reset` records where it moved from and logs the move, even to
    // where it already was.
    try repo.refStore().root().write(repo.allocator(), io, .orig_head, current);
    try head_mod.advance(io, repo, head, current, .{ .who = who, .message = "reset: moving to HEAD" });
    const commit = stashed orelse return null;
    return try stash.restoreStash(io, repo, commit, .{
        .who = who,
        .hooks = options.hooks,
        .filters = options.filters,
        .programs = options.programs,
    });
}

/// Remove what a merge in progress leaves: `MERGE_HEAD`, `MERGE_MSG`,
/// `MERGE_MODE`, `MERGE_RR` and `AUTO_MERGE`, and put `MERGE_AUTOSTASH`
/// on the stash list without applying it, by `who`, as git's
/// `remove_merge_branch_state` saves it.
pub fn removeMergeState(io: Io, repo: *Repository, who: object.Signature) Self.Error!void {
    try repo.refStore().special().delete(io, .merge_head);
    for ([_][]const u8{ "MERGE_RR", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG" }) |name| {
        try state_file.remove(io, repo.gitDirectory(), name);
    }
    try repo.refStore().root().delete(repo.allocator(), io, .auto_merge);
    _ = try stash.restoreAutostash(io, repo, autostash_place, .{ .who = who, .apply = false });
}

fn configuredFastForward(repo: *Repository) FastForward {
    const text = repo.configuration().get("merge.ff") orelse return .allow;
    if (std.ascii.eqlIgnoreCase(text, "only")) return .only;
    const on = config.parseBool(text) catch return .allow;
    return if (on) .allow else .never;
}

/// What `fmt_merge_msg_config` reads, every value in order, as `git merge`
/// reads it at its start: a value git dies on is refused wherever it stands.
pub const MessageSettings = struct {
    /// How many commits of each merged branch `merge.log` (or its old name
    /// `merge.summary`, whichever was set last) lists: true is 20, false or
    /// unset none, a count itself.
    log: u31 = 0,
    /// `merge.branchDesc`: a merged local branch's description goes into the
    /// list, so only with `log`.
    branch_description: bool = false,
    /// `merge.suppressDest`'s patterns, an empty value clearing those before
    /// it; `null` when none was set, which is `main` and `master`.
    suppress_dest: ?[]const []const u8 = null,

    /// `settings` read; the patterns are borrowed from it and their list
    /// lives in `arena`.
    pub fn read(arena: Allocator, settings: *const config.Config) Error!MessageSettings {
        var out: MessageSettings = .{};
        var patterns: std.ArrayList([]const u8) = .empty;
        var suppress_seen = false;
        var it = settings.iterate(&.{ "merge.log", "merge.summary", "merge.branchdesc", "merge.suppressdest" });
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "branchdesc")) {
                out.branch_description = if (entry.value) |text| config.parseBool(text) catch return error.InvalidMergeSetting else true;
            } else if (std.ascii.eqlIgnoreCase(entry.name, "suppressdest")) {
                const pattern = entry.value orelse return error.InvalidMergeSetting;
                if (pattern.len == 0) patterns.clearRetainingCapacity() else try patterns.append(arena, pattern);
                suppress_seen = true;
            } else out.log = switch (config.parseBoolOrInt(entry.value) catch return error.InvalidMergeLog) {
                .boolean => |on| if (on) 20 else 0,
                .integer => |n| std.math.cast(u31, n) orelse return error.InvalidMergeLog,
            };
        }
        if (suppress_seen) out.suppress_dest = patterns.items;
        return out;
    }
};

/// What `mergeMessage` writes about.
const MessageInputs = struct {
    /// What is merged, in order, as `reduceParents` left them.
    targets: []const Target,
    head: head_mod.Head,
    /// `-m`'s message, which takes the title's place.
    given: ?[]const u8,
    settings: MessageSettings,
};

/// The message `git merge` commits with when no editor is opened:
/// `fmt-merge-msg`'s title, or the message given, and with `merge.log` a
/// list of each target's commits `HEAD` lacks (`shortlog`), without the
/// newline at the end. Lives in `arena`.
fn mergeMessage(arena: Allocator, io: Io, repo: *Repository, inputs: MessageInputs) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (inputs.given) |given| {
        // Without a list, `-m`'s message is taken as it is.
        if (inputs.settings.log == 0) return given;
        try out.appendSlice(arena, given);
    } else {
        try title(arena, &out, inputs.targets, inputs.head, inputs.settings);
        try out.append(arena, '\n');
    }
    if (inputs.settings.log != 0) {
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
        for (inputs.targets) |target| try shortlog(arena, io, repo, &out, target, inputs);
    }
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
    // `prepare_merge_message` drops the last byte, the newline.
    return out.items[0 .. out.items.len - 1];
}

/// `fmt-merge-msg`'s `shortlog` for one merged commit, with no editor and
/// so no `credit_people` lines: `* <name>:` (with the count when there are
/// more than `log`), a local branch's description under `merge.branchDesc`,
/// and the subjects of the commits it has that `HEAD` lacks in the order
/// `git log` gives them, merges left out, `log` of them and `...` for the
/// rest.
fn shortlog(arena: Allocator, io: Io, repo: *Repository, out: *std.ArrayList(u8), target: Target, inputs: MessageInputs) Error!void {
    const limit = inputs.settings.log;
    const name = try originName(arena, target);
    var walk: rev_walk.Walk = .init(repo.allocator(), repo.objectDatabase());
    defer walk.deinit();
    try walk.push(target.oid);
    try walk.hide(inputs.head.oid.?);
    var subjects: std.ArrayList([]const u8) = .empty;
    var count: usize = 0;
    while (try walk.next(io)) |commit| {
        if (commit.parents.len > 1) continue;
        count += 1;
        if (subjects.items.len > limit) continue;
        var subject: std.ArrayList(u8) = .empty;
        try pretty.formatCommit(arena, io, .{ .db = repo.objectDatabase(), .oid = commit.oid, .format = "%s" }, &subject, .{});
        const trimmed = std.mem.trimStart(u8, subject.items, ctype.space);
        var hex: [hash.max_hex_len]u8 = undefined;
        try subjects.append(arena, if (trimmed.len == 0) try arena.dupe(u8, commit.oid.hex(&hex)) else trimmed);
    }
    if (count > limit)
        try out.print(arena, "\n* {s}: ({d} commits)\n", .{ name, count })
    else
        try out.print(arena, "\n* {s}:\n", .{name});
    if (target.kind == .branch and std.mem.eql(u8, target.source, ".") and inputs.settings.branch_description) try branchDescription(arena, repo, out, target.name);
    for (subjects.items, 0..) |subject, i| {
        if (i >= limit) try out.appendSlice(arena, "  ...\n") else try out.print(arena, "  {s}\n", .{subject});
    }
}

/// `add_branch_desc`: each line of `branch.<name>.description` after
/// `  : `, the last ended with a newline.
fn branchDescription(arena: Allocator, repo: *Repository, out: *std.ArrayList(u8), name: []const u8) Error!void {
    var last: ?config.Entry = null;
    var it = repo.configuration().iterate(&.{try arena.print("branch.{s}.description", .{name})});
    while (it.next()) |entry| last = entry;
    const entry = last orelse return;
    const text = entry.value orelse return error.InvalidBranchDescription;
    var at: usize = 0;
    while (at < text.len) {
        const end = if (std.mem.findScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        try out.print(arena, "  : {s}", .{text[at..end]});
        at = end;
    }
    if (out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
}

/// The name `fmt-merge-msg`'s `handle_line` gives what a target came
/// from, which heads its list: a local branch by its name, a tag and a
/// commit as the title says them, and anything fetched with ` of <url>`
/// after it -- a remote's `HEAD` and its other refs by the URL alone.
fn originName(arena: Allocator, target: Target) Error![]const u8 {
    const item = try itemText(arena, target);
    const origin = switch (target.kind) {
        .remote_head, .remote_ref => return unquoted(target.source),
        .commit => return arena.print("commit {s}", .{item}),
        .branch, .remote_branch => item,
        .tag => try arena.print("tag {s}", .{item}),
    };
    if (std.mem.eql(u8, target.source, ".")) return unquoted(origin);
    return arena.print("{s} of {s}", .{ origin, target.source });
}

/// The words a target is listed by: `FETCH_HEAD`'s, or its name quoted.
fn itemText(arena: Allocator, target: Target) Error![]const u8 {
    return target.what orelse try arena.print("'{s}'", .{target.name});
}

/// `text` without the quotes around it, when it has them.
fn unquoted(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') return text[1 .. text.len - 1];
    return text;
}

/// One place merged targets came from, and what of it the title lists:
/// `fmt-merge-msg`'s `src_data`.
const Source = struct {
    /// `.`, a remote's URL, or a local commit's `commit '<name>'`.
    key: []const u8,
    /// A remote's `HEAD`, or a local commit, is among them.
    head: bool = false,
    branches: std.ArrayList([]const u8) = .empty,
    remote_branches: std.ArrayList([]const u8) = .empty,
    tags: std.ArrayList([]const u8) = .empty,
    others: std.ArrayList([]const u8) = .empty,

    fn listed(s: *const Source) bool {
        return s.branches.items.len + s.remote_branches.items.len + s.tags.items.len + s.others.items.len != 0;
    }
};

/// git's `fmt-merge-msg` title, `fmt_merge_msg_title`: the targets grouped
/// by where they came from, each source in the order it first comes and
/// apart from the next by `; `. Within one, a remote's `HEAD`, then its
/// branches, remote-tracking branches, tags and other refs (listed as
/// commits), and ` of <url>` for a remote; a source with only its `HEAD`
/// is its URL, and a local commit is a source of its own, `commit
/// 'abc1234'`. ` into <branch>` follows unless the branch is one
/// `merge.suppressDest` names -- `main` and `master` when it names none:
/// `Merge branches 'a' and 'b', tag 'v1'; commit 'abc1234'`.
fn title(arena: Allocator, out: *std.ArrayList(u8), targets: []const Target, head: head_mod.Head, settings: MessageSettings) Error!void {
    const current = head.shortName() orelse "HEAD";
    var suppressed = false;
    const default_patterns: []const []const u8 = &.{ "main", "master" };
    const patterns = settings.suppress_dest orelse default_patterns;
    for (patterns) |pattern| {
        if (try glob_mod.matches(arena, pattern, current, .{})) suppressed = true;
    }
    const sources = try groupSources(arena, targets);
    try out.appendSlice(arena, "Merge ");
    for (sources, 0..) |*source, i| {
        if (i != 0) try out.appendSlice(arena, "; ");
        if (!source.listed()) {
            try out.appendSlice(arena, source.key);
            continue;
        }
        var separator: []const u8 = "";
        if (source.head) {
            try out.appendSlice(arena, "HEAD");
            separator = ", ";
        }
        const groups = [_]struct { names: []const []const u8, one: []const u8, many: []const u8 }{
            .{ .names = source.branches.items, .one = "branch ", .many = "branches " },
            .{ .names = source.remote_branches.items, .one = "remote-tracking branch ", .many = "remote-tracking branches " },
            .{ .names = source.tags.items, .one = "tag ", .many = "tags " },
            .{ .names = source.others.items, .one = "commit ", .many = "commits " },
        };
        for (groups) |group| {
            if (group.names.len == 0) continue;
            try out.appendSlice(arena, separator);
            separator = ", ";
            try out.appendSlice(arena, if (group.names.len == 1) group.one else group.many);
            for (group.names, 0..) |name, n| {
                if (n == group.names.len - 1 and n != 0) try out.appendSlice(arena, " and ") else if (n != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, name);
            }
        }
        if (!std.mem.eql(u8, source.key, ".")) try out.print(arena, " of {s}", .{source.key});
    }
    if (!suppressed) try out.print(arena, " into {s}", .{current});
}

/// The targets by where they came from, in the order each source first
/// comes: `handle_line`'s `srcs`.
fn groupSources(arena: Allocator, targets: []const Target) Error![]Source {
    var sources: std.ArrayList(Source) = .empty;
    for (targets) |target| {
        const item = try itemText(arena, target);
        const key = if (target.kind == .commit) try arena.print("commit {s}", .{item}) else target.source;
        const source = for (sources.items) |*s| {
            if (std.mem.eql(u8, s.key, key)) break s;
        } else blk: {
            try sources.append(arena, .{ .key = key });
            break :blk &sources.items[sources.items.len - 1];
        };
        switch (target.kind) {
            .commit, .remote_head => source.head = true,
            .branch => try source.branches.append(arena, item),
            .remote_branch => try source.remote_branches.append(arena, item),
            .tag => try source.tags.append(arena, item),
            .remote_ref => try source.others.append(arena, item),
        }
    }
    return sources.items;
}
