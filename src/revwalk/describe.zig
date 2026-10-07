//! `git describe`: a commit named after the nearest tag behind it, as
//! `v1.2-3-gdeadbee`; and with `contains`, after the nearest tag ahead of
//! it, as `git name-rev` names it, `v1.3~2`.
//!
//! The search is git's, step for step, because which tag wins is decided by
//! it: commits are taken newest committer date first, ties in the order they
//! were met; each tag met is a candidate and marks what it reaches; the
//! search gives up once it holds `candidates` of them (ten by default) or
//! every name there is, or once the last path left is behind the best ones;
//! and the winner's depth -- the commits the described one reaches and it
//! does not -- is then finished over what is left. Only annotated tags are
//! names unless `tags` or `all` says otherwise; two annotated tags on one
//! commit go by the later tagger date. An annotated tag whose object names
//! itself differently from its ref is printed by the object's name, with a
//! warning, and always with the suffix, as git does.
//!
//! A blob is described as `<commit>:<path>`, the commit being the first, in
//! `git rev-list --reverse HEAD` order, whose tree holds it.
//!
//! `dirty` compares `HEAD` with the index and the working tree as `git
//! diff-index HEAD` does after a refresh; the index file itself is read and
//! not rewritten with fresher stat data, which git's refresh would do.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const index_mod = @import("../index.zig");

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb_mod = @import("../odb.zig");
const refs_mod = @import("../refs.zig");
const repo_mod = @import("../repo.zig");
const revparse = @import("revparse.zig");
const revwalk = @import("../revwalk.zig");
const abbrev_mod = @import("../odb/abbrev.zig");
const wildmatch = @import("../worktree/wildmatch.zig");
const worktree = @import("../worktree.zig");
const commitgraph = @import("../odb/commitgraph.zig");
const warning = @import("../repo/warning.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// git's `MAX_TAGS`: the object flags left for candidates.
pub const max_candidates: u32 = 27;

/// How to describe.
pub const Options = struct {
    /// `--all`: any ref under `refs/` is a name, not only tags.
    all: bool = false,
    /// `--tags`: a lightweight tag is a name too.
    tags: bool = false,
    /// `--long`: the suffix even on an exact match.
    long: bool = false,
    /// `--abbrev=<n>`: the digits after `-g`. `null` is `core.abbrev`, or
    /// git's automatic length; zero prints the tag alone. Below four is
    /// four, past the hash's length is the whole name.
    abbrev: ?u32 = null,
    /// `--candidates=<n>`: how many tags the search may hold. Zero is
    /// `--exact-match`; past `max_candidates` is `max_candidates`.
    candidates: u32 = 10,
    /// `--match`: names whose part after `refs/tags/` (and with `all`, after
    /// `refs/heads/` or `refs/remotes/`) matches one of these globs.
    match: []const []const u8 = &.{},
    /// `--exclude`: names matching any of these are not used.
    exclude: []const []const u8 = &.{},
    /// `--first-parent`: follow only first parents in the search.
    first_parent: bool = false,
    /// `--always`: the abbreviated name when nothing describes the commit.
    always: bool = false,
    /// `--contains`: the nearest tag that contains the commit, as `git
    /// name-rev --peel-tag --name-only --no-undefined` names it.
    contains: bool = false,
    /// `--dirty=<mark>`: appended to a description of `HEAD` when the
    /// working tree differs from it. Only `head` reads it.
    dirty: ?[]const u8 = null,
    /// `--broken=<mark>`: appended instead when the working tree cannot be
    /// compared at all. Only `head` reads it.
    broken: ?[]const u8 = null,
    /// Where git's warnings go: a tag whose object calls itself by another
    /// name.
    warnings: ?*warning.Warnings = null,
};

/// Errors from describing.
pub const Error = error{
    /// No ref the options allow: `No names found, cannot describe anything.`
    NoNames,
    /// A tree nests deeper than `object.max_tree_depth`.
    TreeTooDeep,
    /// `--exact-match` and no name is on the commit.
    NoExactMatch,
    /// Only lightweight tags reach the commit; `tags` would use them.
    NoAnnotatedTags,
    /// Nothing reaches the commit and `always` was not asked for.
    NoTags,
    /// The object is neither a commit nor a blob.
    NotCommitOrBlob,
    /// A blob no commit reachable from `HEAD` holds.
    BlobNotReachable,
    /// `HEAD` has no commit, and a blob is searched for from it.
    UnbornBranch,
    /// `long` and an `abbrev` of zero, which git refuses together.
    LongWithoutAbbrev,
    /// `contains` and no tag contains the commit.
    CannotDescribe,
    /// An annotated tag that cannot be read.
    TagUnavailable,
    /// A repository with no working tree has nothing to be dirty.
    BareRepository,
} || Allocator.Error || odb_mod.Error || object.ParseError || refs_mod.ReadError || repo_mod.Error ||
    revparse.Error || worktree.Error || error{ NotACommit, WalkTooLong, TagDepthExceeded } ||
    index_mod.ReadError || commitgraph.Error;

const prio_head: u2 = 0;
const prio_lightweight: u2 = 1;
const prio_annotated: u2 = 2;

const TagInfo = struct {
    /// The name the tag object gives itself.
    name: []const u8,
    /// The tagger's date, zero when there is no tagger.
    date: i64,
    /// What the tag points at, not peeled.
    target: Oid,
};

const Name = struct {
    peeled: Oid,
    /// The ref's own value: a tag object for an annotated tag.
    oid: Oid,
    prio: u2,
    /// The ref's name less `refs/`, or less `refs/tags/` without `all`.
    path: []const u8,
    tag: ?TagInfo = null,
    name_checked: bool = false,
    misnamed: bool = false,
};

const Node = struct {
    parents: []const Oid = &.{},
    time: i64 = 0,
    parsed: bool = false,
    flags: u32 = 0,
};

const seen_flag: u32 = 1;

/// Describes commits and blobs of one repository with one set of options,
/// reading its refs once.
pub const Describer = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    repo: *Repository,
    options: Options,
    abbrev: ?u32,
    names: Oid.Map(Name) = .empty,
    /// The names that are on commits, by commit: git's `commit_names`, made
    /// the first time a search needs it.
    on_commit: ?Oid.Map(*Name) = null,
    /// Every commit a search has read, for the next.
    parsed: Oid.Map(Parsed) = .empty,

    /// Read the refs the options allow.
    pub fn init(gpa: Allocator, io: Io, repo: *Repository, options_in: Options) Self.Error!Describer {
        var options = options_in;
        if (options.abbrev) |n| {
            if (n != 0 and n < abbrev_mod.minimum) options.abbrev = abbrev_mod.minimum;
            if (n > repo.objectFormat().hexLen()) options.abbrev = @intCast(repo.objectFormat().hexLen());
        }
        if (options.candidates > max_candidates) options.candidates = max_candidates;
        if (options.long and options.abbrev != null and options.abbrev.? == 0) return error.LongWithoutAbbrev;
        var d: Describer = .{ .gpa = gpa, .arena = .init(gpa), .repo = repo, .options = options, .abbrev = options.abbrev };
        errdefer d.deinit();
        if (!options.contains) {
            try d.loadNames(io);
            if (d.names.count() == 0 and !options.always) return error.NoNames;
        }
        return d;
    }

    /// Release everything.
    pub fn deinit(d: *Describer) void {
        if (d.on_commit) |*m| m.deinit(d.gpa);
        d.parsed.deinit(d.gpa);
        d.names.deinit(d.gpa);
        d.arena.deinit();
        d.* = undefined;
    }

    /// `get_name`, over every ref git's `for_each_ref` would hand it.
    fn loadNames(d: *Describer, io: Io) Error!void {
        const a = d.arena.allocator();
        const store = d.repo.refStore();
        var listing = try store.list(d.gpa, io, if (d.options.all) "refs/" else "refs/tags/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            const refname = entry.name;
            var path_to_match: ?[]const u8 = null;
            var is_tag = false;
            if (std.mem.startsWith(u8, refname, "refs/tags/")) {
                is_tag = true;
                path_to_match = refname["refs/tags/".len..];
            } else if (d.options.all) {
                if (d.options.exclude.len != 0 or d.options.match.len != 0) {
                    if (std.mem.startsWith(u8, refname, "refs/heads/")) {
                        path_to_match = refname["refs/heads/".len..];
                    } else if (std.mem.startsWith(u8, refname, "refs/remotes/")) {
                        path_to_match = refname["refs/remotes/".len..];
                    } else continue;
                }
            } else continue;

            if (path_to_match) |p| {
                if (try anyMatch(d.options.exclude, p)) continue;
                if (d.options.match.len != 0 and !try anyMatch(d.options.match, p)) continue;
            }

            const oid = switch (entry.target) {
                .direct => |o| o,
                .symbolic => blk: {
                    const resolved = (try store.resolve(d.gpa, io, refname)) orelse continue;
                    defer d.gpa.free(resolved.name);
                    break :blk resolved.oid;
                },
            };
            const peeled = entry.peeled orelse peelFully(io, d.repo, oid) catch oid;
            const annotated = !peeled.eql(oid);
            const prio: u2 = if (annotated) prio_annotated else if (is_tag) prio_lightweight else prio_head;
            const path = if (d.options.all) refname["refs/".len..] else refname["refs/tags/".len..];
            try d.addKnownName(a, io, path, peeled, prio, oid);
        }
    }

    /// `add_to_known_names` with `replace_name`.
    fn addKnownName(d: *Describer, a: Allocator, io: Io, path: []const u8, peeled: Oid, prio: u2, oid: Oid) Error!void {
        const slot = try d.names.getOrPut(d.gpa, peeled);
        var tag: ?TagInfo = null;
        if (slot.found_existing) {
            const e = slot.value_ptr;
            if (e.prio >= prio) {
                if (!(e.prio == prio_annotated and prio == prio_annotated)) return;
                // Two annotated tags on one commit: the later tagger date.
                if (e.tag == null) e.tag = readTag(a, io, d.repo, e.oid) catch null;
                if (e.tag != null) {
                    tag = readTag(a, io, d.repo, oid) catch return;
                    if (!(e.tag.?.date < tag.?.date)) return;
                }
            }
        }
        slot.value_ptr.* = .{
            .peeled = peeled,
            .oid = oid,
            .prio = prio,
            .path = try a.dupe(u8, path),
            .tag = tag,
        };
    }

    fn appendName(d: *Describer, io: Io, n: *Name, out: *std.ArrayList(u8)) Error!void {
        const a = d.arena.allocator();
        if (n.prio == prio_annotated and n.tag == null) {
            n.tag = readTag(a, io, d.repo, n.oid) catch return error.TagUnavailable;
        }
        if (n.tag) |t| {
            if (!n.name_checked) {
                const expect = if (d.options.all) n.path["tags/".len..] else n.path;
                if (!std.mem.eql(u8, t.name, expect)) {
                    n.misnamed = true;
                    if (d.options.warnings) |w| try w.add(.{ .tag_known_as = .{ .path = n.path, .name = t.name } });
                }
                n.name_checked = true;
            }
            if (d.options.all) try out.appendSlice(d.gpa, "tags/");
            try out.appendSlice(d.gpa, t.name);
        } else {
            try out.appendSlice(d.gpa, n.path);
        }
    }

    fn appendSuffix(d: *Describer, io: Io, depth: u32, oid: Oid, out: *std.ArrayList(u8)) Error!void {
        var buf: [hash.max_hex_len]u8 = undefined;
        const short = try d.shortName(io, oid, &buf);
        try out.print(d.gpa, "-{d}-g{s}", .{ depth, short });
    }

    /// `repo_find_unique_abbrev` at the length asked for: zero is the
    /// whole name.
    fn shortName(d: *Describer, io: Io, oid: Oid, buf: *[hash.max_hex_len]u8) Error![]const u8 {
        const len: usize = if (d.abbrev) |n| (if (n == 0) oid.kind.hexLen() else n) else abbrev_mod.defaultLength(d.repo.configuration(), &d.repo.odb);
        return abbrev_mod.unique(io, &d.repo.odb, oid, len, buf);
    }

    /// The description of the object `oid` names: a commit (or a tag of
    /// one), or a blob. The result is the caller's.
    pub fn describe(d: *Describer, io: Io, oid: Oid) Self.Error![]u8 {
        return d.describeWithSuffix(io, oid, null);
    }

    fn describeWithSuffix(d: *Describer, io: Io, oid: Oid, suffix: ?[]const u8) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(d.gpa);
        const commit = peelToCommit(io, d.repo, oid) catch |err| switch (err) {
            error.NotACommit => null,
            else => |e| return e,
        };
        if (d.options.contains) {
            const c = commit orelse return error.NotACommit;
            try d.nameRev(io, c, &out);
            return out.toOwnedSlice(d.gpa);
        }
        if (commit) |c| {
            try d.describeCommit(io, c, suffix, &out);
        } else {
            const header = try d.repo.odb.readHeader(io, oid);
            if (header.type != .blob) return error.NotCommitOrBlob;
            try d.describeBlob(io, oid, &out);
        }
        return out.toOwnedSlice(d.gpa);
    }

    /// `describe_commit`.
    fn describeCommit(d: *Describer, io: Io, cmit: Oid, suffix: ?[]const u8, out: *std.ArrayList(u8)) Error!void {
        if (d.names.getPtr(cmit)) |n| {
            if (d.options.tags or d.options.all or n.prio == prio_annotated) {
                try d.appendName(io, n, out);
                if (n.misnamed or d.options.long)
                    try d.appendSuffix(io, 0, if (n.tag) |t| t.target else cmit, out);
                if (suffix) |s| try out.appendSlice(d.gpa, s);
                return;
            }
        }
        if (d.options.candidates == 0) return error.NoExactMatch;

        var walk: Walk = .{ .gpa = d.gpa, .repo = d.repo, .parsed = &d.parsed, .arena = d.arena.allocator() };
        defer walk.deinit();
        if (d.on_commit == null) {
            var map: Oid.Map(*Name) = .empty;
            errdefer map.deinit(d.gpa);
            var it = d.names.valueIterator();
            while (it.next()) |n| {
                // `peeled` is past every tag already: only its type is asked.
                const header = d.repo.odb.readHeader(io, n.peeled) catch continue;
                if (header.type != .commit) continue;
                try map.put(d.gpa, n.peeled, n);
            }
            d.on_commit = map;
        }
        const on_commit = &d.on_commit.?;

        const Possible = struct { name: *Name, depth: u32, found_order: u32, flag_within: u32 };
        var matches: [max_candidates]Possible = undefined;
        var match_cnt: u32 = 0;
        var annotated_cnt: u32 = 0;
        var unannotated_cnt: u32 = 0;
        var seen_commits: u64 = 0;
        var gave_up_on: ?Oid = null;

        (try walk.node(io, cmit)).flags = seen_flag;
        try walk.put(io, cmit);
        while (walk.get()) |c| {
            seen_commits += 1;
            if (match_cnt == d.options.candidates or match_cnt == d.names.count()) {
                gave_up_on = c;
                break;
            }
            const cn = try walk.node(io, c);
            if (on_commit.get(c)) |n| {
                if (!d.options.tags and !d.options.all and n.prio < prio_annotated) {
                    unannotated_cnt += 1;
                } else if (match_cnt < d.options.candidates) {
                    match_cnt += 1;
                    const t = &matches[match_cnt - 1];
                    t.* = .{ .name = n, .depth = @intCast(seen_commits - 1), .flag_within = @as(u32, 1) << @intCast(match_cnt), .found_order = match_cnt };
                    cn.flags |= t.flag_within;
                    if (n.prio == prio_annotated) annotated_cnt += 1;
                }
            }
            for (matches[0..match_cnt]) |*t| {
                if (cn.flags & t.flag_within == 0) t.depth += 1;
            }
            if (annotated_cnt != 0 and walk.queue.items.len == 0) {
                var best_depth: u32 = std.math.maxInt(u32);
                var best_within: u32 = 0;
                for (matches[0..match_cnt]) |t| {
                    if (t.depth < best_depth) {
                        best_depth = t.depth;
                        best_within = t.flag_within;
                    } else if (t.depth == best_depth) {
                        best_within |= t.flag_within;
                    }
                }
                if (cn.flags & best_within == best_within) break;
            }
            const flags = cn.flags;
            for (cn.parents) |p| {
                const pn = try walk.node(io, p);
                if (pn.flags & seen_flag == 0) try walk.put(io, p);
                pn.flags |= flags;
                if (d.options.first_parent) break;
            }
        }

        if (match_cnt == 0) {
            if (d.options.always) {
                var buf: [hash.max_hex_len]u8 = undefined;
                try out.appendSlice(d.gpa, try d.shortName(io, cmit, &buf));
                if (suffix) |s| try out.appendSlice(d.gpa, s);
                return;
            }
            if (unannotated_cnt != 0) return error.NoAnnotatedTags;
            return error.NoTags;
        }

        std.sort.pdq(Possible, matches[0..match_cnt], {}, struct {
            fn lessThan(_: void, a: Possible, b: Possible) bool {
                if (a.depth != b.depth) return a.depth < b.depth;
                return a.found_order < b.found_order;
            }
        }.lessThan);

        if (gave_up_on) |g| try walk.put(io, g);
        try finishDepth(&walk, io, &matches[0].depth, matches[0].flag_within);

        try d.appendName(io, matches[0].name, out);
        if (matches[0].name.misnamed or d.abbrev == null or d.abbrev.? != 0)
            try d.appendSuffix(io, matches[0].depth, cmit, out);
        if (suffix) |s| try out.appendSlice(d.gpa, s);
    }

    /// `describe_blob`: the first commit, oldest first along `HEAD`'s
    /// history, whose tree holds the blob, and the path it is at there.
    fn describeBlob(d: *Describer, io: Io, blob: Oid, out: *std.ArrayList(u8)) Error!void {
        const tip = (try d.repo.head(io)) orelse return error.UnbornBranch;
        defer d.gpa.free(tip.name);
        var walk: revwalk.Walk = .init(d.gpa, &d.repo.odb);
        defer walk.deinit();
        walk.reverse = true;
        try walk.push(tip.oid);
        var seen: Oid.Set = .empty;
        defer seen.deinit(d.gpa);
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(d.gpa);
        while (try walk.next(io)) |c| {
            const tree = try d.repo.commitTree(io, c.oid);
            path.clearRetainingCapacity();
            if (try findInTree(d, io, tree, blob, &seen, &path, 0)) {
                try d.describeCommit(io, c.oid, null, out);
                try out.append(d.gpa, ':');
                try out.appendSlice(d.gpa, path.items);
                return;
            }
        }
        return error.BlobNotReachable;
    }

    /// git's `name_rev` over the tip table, then `get_rev_name` for `cmit`.
    fn nameRev(d: *Describer, io: Io, cmit: Oid, out: *std.ArrayList(u8)) Error!void {
        var nr: NameRev = .{ .gpa = d.gpa, .arena = .init(d.gpa), .repo = d.repo };
        defer nr.deinit();
        try nr.setCutoff(io, cmit);
        try nr.loadTips(io, d.options);
        try nr.nameTips(io);
        if (nr.names.get(cmit)) |n| {
            if (n.generation == 0) {
                try out.appendSlice(d.gpa, n.tip_name);
            } else {
                try out.print(d.gpa, "{s}~{d}", .{ stripPeelSuffix(n.tip_name), n.generation });
            }
            return;
        }
        if (d.options.always) {
            var buf: [hash.max_hex_len]u8 = undefined;
            const len = abbrev_mod.defaultLength(d.repo.configuration(), &d.repo.odb);
            try out.appendSlice(d.gpa, try abbrev_mod.unique(io, &d.repo.odb, cmit, len, &buf));
            return;
        }
        return error.CannotDescribe;
    }
};

/// The description of what `rev` names, as `git describe <rev>` prints it
/// without its newline. The result is the caller's.
pub fn describe(gpa: Allocator, io: Io, repo: *Repository, rev: []const u8, options: Options) Self.Error![]u8 {
    const oid = try revparse.resolve(gpa, io, repo, rev);
    var d = try Describer.init(gpa, io, repo, options);
    defer d.deinit();
    return d.describe(io, oid);
}

/// `git describe` with no revision: `HEAD`, with `dirty` or `broken`
/// appended as the working tree says. The result is the caller's.
pub fn head(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error![]u8 {
    var d = try Describer.init(gpa, io, repo, options);
    defer d.deinit();
    const resolved = (try repo.head(io)) orelse return error.BadRevision;
    gpa.free(resolved.name);
    if (options.contains) return d.describe(io, resolved.oid);
    var suffix: ?[]const u8 = null;
    if (options.broken) |broken| {
        const dirty_mark = options.dirty orelse "-dirty";
        suffix = if (isDirty(gpa, io, repo, resolved.oid)) |dirty| (if (dirty) dirty_mark else null) else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => broken,
        };
    } else if (options.dirty) |dirty_mark| {
        if (try isDirty(gpa, io, repo, resolved.oid)) suffix = dirty_mark;
    }
    return d.describeWithSuffix(io, resolved.oid, suffix);
}

/// Whether the index or the working tree differs from `HEAD`'s tree,
/// untracked files aside: `git diff-index --quiet HEAD`.
fn isDirty(gpa: Allocator, io: Io, repo: *Repository, head_oid: Oid) Error!bool {
    const wt = repo.work_dir orelse return error.BareRepository;
    var index = try repo.openIndex(io);
    defer index.deinit();
    var rules = try repo.worktreeRules();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    rules.attrs = &attrs;
    var status = try worktree.status(gpa, io, wt, &index, &repo.odb, .{
        .rules = rules,
        .head_tree = try repo.commitTree(io, head_oid),
        .untracked = .no,
    });
    defer status.deinit();
    return !status.isClean();
}

fn anyMatch(patterns: []const []const u8, text: []const u8) Error!bool {
    for (patterns) |p| {
        if (wildmatch.match(p, text, .{}) catch false) return true;
    }
    return false;
}

fn peelFully(io: Io, repo: *Repository, oid: Oid) Error!Oid {
    return repo.peel(io, oid) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.TagDepthExceeded,
    };
}

/// `lookup_commit_reference_gently`: the commit `oid` is, or peels to.
fn peelToCommit(io: Io, repo: *Repository, oid: Oid) Error!Oid {
    const peeled = try peelFully(io, repo, oid);
    const header = repo.odb.readHeader(io, peeled) catch |err| switch (err) {
        error.ObjectNotFound => return error.NotACommit,
        else => |e| return e,
    };
    if (header.type != .commit) return error.NotACommit;
    return peeled;
}

fn readTag(a: Allocator, io: Io, repo: *Repository, oid: Oid) Error!TagInfo {
    const found = try repo.odb.read(io, oid);
    defer repo.odb.allocator().free(found.bytes);
    if (found.type != .tag) return error.UnexpectedObjectType;
    var tag = try object.Tag.parse(repo.gpa, repo.objectFormat(), found.bytes);
    defer tag.deinit();
    return .{
        .name = try a.dupe(u8, tag.name),
        .date = if (tag.tagger) |t| t.when_secs else 0,
        .target = tag.target,
    };
}

/// git's commit-date priority queue over the commits of one search, each
/// with its flags.
/// A commit's parents and date, kept for every search a describer makes, as
/// git's parsed commits are.
const Parsed = struct { parents: []const Oid, time: i64 };

const Walk = struct {
    gpa: Allocator,
    repo: *Repository,
    /// Commits read by earlier searches, and where new ones' parents go.
    parsed: *Oid.Map(Parsed),
    arena: Allocator,
    nodes: Oid.Map(*Node) = .empty,
    queue: std.PriorityQueue(Queued, void, Queued.newerFirst) = .empty,
    counter: u64 = 0,

    const Queued = struct {
        oid: Oid,
        time: i64,
        ctr: u64,
        fn newerFirst(_: void, a: Queued, b: Queued) std.math.Order {
            if (a.time != b.time) return std.math.order(b.time, a.time);
            return std.math.order(a.ctr, b.ctr);
        }
    };

    fn deinit(w: *Walk) void {
        var it = w.nodes.valueIterator();
        while (it.next()) |n| w.gpa.destroy(n.*);
        w.nodes.deinit(w.gpa);
        w.queue.deinit(w.gpa);
        w.* = undefined;
    }

    fn node(w: *Walk, io: Io, oid: Oid) Error!*Node {
        const slot = try w.nodes.getOrPut(w.gpa, oid);
        if (!slot.found_existing) {
            errdefer _ = w.nodes.remove(oid);
            slot.value_ptr.* = try w.gpa.create(Node);
            slot.value_ptr.*.* = .{};
        }
        const n = slot.value_ptr.*;
        if (!n.parsed) {
            const known = try w.parsed.getOrPut(w.gpa, oid);
            if (!known.found_existing) {
                errdefer _ = w.parsed.remove(oid);
                const found = try w.repo.odb.read(io, oid);
                defer w.repo.odb.allocator().free(found.bytes);
                if (found.type != .commit) return error.NotACommit;
                var commit = try object.Commit.parse(w.gpa, w.repo.objectFormat(), found.bytes);
                defer commit.deinit();
                known.value_ptr.* = .{
                    .parents = try w.arena.dupe(Oid, revwalk.parentsOf(&w.repo.odb, oid, commit.parents)),
                    .time = commit.committer.when_secs,
                };
            }
            n.parents = known.value_ptr.parents;
            n.time = known.value_ptr.time;
            n.parsed = true;
        }
        return n;
    }

    fn put(w: *Walk, io: Io, oid: Oid) Error!void {
        const n = try w.node(io, oid);
        try w.queue.push(w.gpa, .{ .oid = oid, .time = n.time, .ctr = w.counter });
        w.counter += 1;
    }

    fn get(w: *Walk) ?Oid {
        const q = w.queue.pop() orelse return null;
        return q.oid;
    }
};

/// `finish_depth_computation`: walk on from where the search stopped,
/// counting the commits the best candidate does not reach, until every
/// commit left is one it does.
fn finishDepth(w: *Walk, io: Io, depth: *u32, within: u32) Error!void {
    var unflagged: Oid.Set = .empty;
    defer unflagged.deinit(w.gpa);
    for (w.queue.items) |q| {
        if ((try w.node(io, q.oid)).flags & within == 0) try unflagged.put(w.gpa, q.oid, {});
    }
    while (w.get()) |c| {
        const cn = try w.node(io, c);
        if (cn.flags & within != 0) {
            if (unflagged.count() == 0) break;
        } else {
            _ = unflagged.remove(c);
            depth.* += 1;
        }
        const flags = cn.flags;
        for (cn.parents) |p| {
            const pn = try w.node(io, p);
            const seen = pn.flags & seen_flag != 0;
            if (!seen) try w.put(io, p);
            const before = pn.flags & within != 0;
            pn.flags |= flags;
            const after = pn.flags & within != 0;
            if (!seen and !after) try unflagged.put(w.gpa, p, {});
            if (seen and !before and after) _ = unflagged.remove(p);
        }
    }
}

/// `traverse_commit_list`'s tree walk for one commit: entries in tree
/// order, a subtree as it is met, nothing seen in an earlier commit again.
fn findInTree(d: *Describer, io: Io, tree: Oid, blob: Oid, seen: *Oid.Set, path: *std.ArrayList(u8), depth: u32) Error!bool {
    if (depth > object.max_tree_depth) return error.TreeTooDeep;
    if ((try seen.getOrPut(d.gpa, tree)).found_existing) return false;
    const found = try d.repo.odb.read(io, tree);
    defer d.repo.odb.allocator().free(found.bytes);
    var it = object.Tree.parse(d.repo.objectFormat(), found.bytes).iterate();
    while (try it.next()) |entry| {
        const base = path.items.len;
        switch (entry.mode) {
            .tree => {
                try path.appendSlice(d.gpa, entry.name);
                try path.append(d.gpa, '/');
                if (try findInTree(d, io, entry.oid, blob, seen, path, depth + 1)) return true;
            },
            .gitlink => {},
            else => {
                if ((try seen.getOrPut(d.gpa, entry.oid)).found_existing) continue;
                if (entry.oid.eql(blob)) {
                    try path.appendSlice(d.gpa, entry.name);
                    return true;
                }
            },
        }
        path.shrinkRetainingCapacity(base);
    }
    return false;
}

fn stripPeelSuffix(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, "^0")) name[0 .. name.len - 2] else name;
}

/// `git name-rev`: every commit named after the best tip that reaches it.
const NameRev = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    repo: *Repository,
    names: Oid.Map(RevName) = .empty,
    commits: Oid.Map(Node) = .empty,
    tips: std.ArrayList(Tip) = .empty,
    /// The date below which commits are not named, a day before the
    /// commit asked about; or none, when a commit-graph holds that commit
    /// and git would cut off by generation, which never cuts a path to it.
    cutoff: ?i64 = null,

    const merge_traversal_weight: u32 = 65535;

    const RevName = struct {
        tip_name: []const u8,
        taggerdate: i64,
        generation: u32,
        distance: u32,
        from_tag: bool,
    };

    const Tip = struct {
        refname: []const u8,
        commit: ?Oid,
        taggerdate: i64,
        from_tag: bool,
        deref: bool,
    };

    fn deinit(nr: *NameRev) void {
        var it = nr.commits.valueIterator();
        while (it.next()) |n| nr.gpa.free(n.parents);
        nr.commits.deinit(nr.gpa);
        nr.names.deinit(nr.gpa);
        nr.tips.deinit(nr.gpa);
        nr.arena.deinit();
        nr.* = undefined;
    }

    fn commit(nr: *NameRev, io: Io, oid: Oid) Error!*Node {
        const slot = try nr.commits.getOrPut(nr.gpa, oid);
        if (!slot.found_existing) {
            errdefer _ = nr.commits.remove(oid);
            const found = try nr.repo.odb.read(io, oid);
            defer nr.repo.odb.allocator().free(found.bytes);
            if (found.type != .commit) return error.NotACommit;
            var c = try object.Commit.parse(nr.gpa, nr.repo.objectFormat(), found.bytes);
            defer c.deinit();
            slot.value_ptr.* = .{
                .parents = try nr.gpa.dupe(Oid, revwalk.parentsOf(&nr.repo.odb, oid, c.parents)),
                .time = c.committer.when_secs,
                .parsed = true,
            };
        }
        return slot.value_ptr;
    }

    fn setCutoff(nr: *NameRev, io: Io, cmit: Oid) Error!void {
        if (try nr.repo.configuration().getBool("core.commitgraph", true)) {
            const objects = try nr.repo.common_dir.openDir(io, "objects", .{});
            defer objects.close(io);
            if (try commitgraph.Graph.openUsable(nr.gpa, io, objects, nr.repo.objectFormat())) |graph_value| {
                var graph = graph_value;
                defer graph.deinit();
                if (graph.find(cmit) != null) return;
            }
        }
        const time = (try nr.commit(io, cmit)).time;
        nr.cutoff = time -| 86400;
    }

    fn beforeCutoff(nr: *NameRev, io: Io, oid: Oid) Error!bool {
        const cutoff = nr.cutoff orelse return false;
        return (try nr.commit(io, oid)).time < cutoff;
    }

    /// `name_ref` over every ref, as `describe --contains` calls name-rev.
    fn loadTips(nr: *NameRev, io: Io, options: Options) Error!void {
        const a = nr.arena.allocator();
        const tags_only = !options.all;
        var filters: std.ArrayList([]const u8) = .empty;
        var excludes: std.ArrayList([]const u8) = .empty;
        const prefixes: []const []const u8 = if (options.all) &.{ "refs/tags/", "refs/heads/", "refs/remotes/" } else &.{"refs/tags/"};
        for (prefixes) |prefix| {
            for (options.match) |m| try filters.append(a, try std.mem.concat(a, u8, &.{ prefix, m }));
            for (options.exclude) |m| try excludes.append(a, try std.mem.concat(a, u8, &.{ prefix, m }));
        }
        const store = nr.repo.refStore();
        var listing = try store.list(nr.gpa, io, "refs/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            const refname = entry.name;
            var can_abbreviate = tags_only; // and `--name-only`
            if (tags_only and !std.mem.startsWith(u8, refname, "refs/tags/")) continue;
            var excluded = false;
            for (excludes.items) |f| {
                if (subpathMatches(refname, f) != null) excluded = true;
            }
            if (excluded) continue;
            if (filters.items.len != 0) {
                var matched = false;
                for (filters.items) |f| {
                    if (subpathMatches(refname, f)) |at| {
                        matched = true;
                        if (at != 0) can_abbreviate = true;
                    }
                }
                if (!matched) continue;
            }
            const oid = switch (entry.target) {
                .direct => |o| o,
                .symbolic => blk: {
                    const resolved = (try store.resolve(nr.gpa, io, refname)) orelse continue;
                    defer nr.gpa.free(resolved.name);
                    break :blk resolved.oid;
                },
            };
            var current = oid;
            var deref = false;
            var taggerdate: ?i64 = null;
            var kind: ?object.Type = null;
            var depth: u8 = 0;
            while (depth < 16) : (depth += 1) {
                const header = nr.repo.odb.readHeader(io, current) catch break;
                kind = header.type;
                if (header.type != .tag) break;
                const tag = readTag(a, io, nr.repo, current) catch {
                    kind = null;
                    break;
                };
                current = tag.target;
                deref = true;
                taggerdate = tag.date;
            }
            var tip: Tip = .{ .refname = undefined, .commit = null, .taggerdate = taggerdate orelse std.math.maxInt(i64), .from_tag = false, .deref = deref };
            if (kind != null and kind.? == .commit) {
                tip.commit = current;
                tip.from_tag = std.mem.startsWith(u8, refname, "refs/tags/");
                if (taggerdate == null) tip.taggerdate = (try nr.commit(io, current)).time;
            }
            tip.refname = if (can_abbreviate)
                try shortenUnambiguous(a, io, store, refname)
            else if (std.mem.startsWith(u8, refname, "refs/heads/"))
                try a.dupe(u8, refname["refs/heads/".len..])
            else
                try a.dupe(u8, refname["refs/".len..]);
            try nr.tips.append(nr.gpa, tip);
        }
    }

    /// `name_tips`: the better tips first -- tags before other refs, then
    /// the older -- so worse names spread less.
    fn nameTips(nr: *NameRev, io: Io) Error!void {
        std.sort.block(Tip, nr.tips.items, {}, struct {
            fn lessThan(_: void, a: Tip, b: Tip) bool {
                if (a.from_tag != b.from_tag) return a.from_tag;
                return a.taggerdate < b.taggerdate;
            }
        }.lessThan);
        for (nr.tips.items) |tip| {
            const c = tip.commit orelse continue;
            try nr.nameRev(io, c, tip.refname, tip.taggerdate, tip.from_tag, tip.deref);
        }
    }

    fn effectiveDistance(distance: u32, generation: u32) u64 {
        return @as(u64, distance) + (if (generation > 0) merge_traversal_weight else 0);
    }

    fn isBetter(name: RevName, taggerdate: i64, generation: u32, distance: u32, from_tag: bool) bool {
        const name_distance = effectiveDistance(name.distance, name.generation);
        const new_distance = effectiveDistance(distance, generation);
        if (from_tag and name.from_tag) return name_distance > new_distance;
        if (name.from_tag != from_tag) return from_tag;
        if (name_distance != new_distance) return name_distance > new_distance;
        if (name.taggerdate != taggerdate) return name.taggerdate > taggerdate;
        return false;
    }

    /// `create_or_update_name`: the slot to give a name, or `null` when
    /// the one there is at least as good.
    fn createOrUpdate(nr: *NameRev, oid: Oid, taggerdate: i64, generation: u32, distance: u32, from_tag: bool) Error!?*RevName {
        const slot = try nr.names.getOrPut(nr.gpa, oid);
        if (slot.found_existing and !isBetter(slot.value_ptr.*, taggerdate, generation, distance, from_tag)) return null;
        const keep = if (slot.found_existing) slot.value_ptr.tip_name else "";
        slot.value_ptr.* = .{ .tip_name = keep, .taggerdate = taggerdate, .generation = generation, .distance = distance, .from_tag = from_tag };
        return slot.value_ptr;
    }

    /// `name_rev`: depth first from the tip, first parents first.
    fn nameRev(nr: *NameRev, io: Io, start: Oid, tip_name: []const u8, taggerdate: i64, from_tag: bool, deref: bool) Error!void {
        const a = nr.arena.allocator();
        if (try nr.beforeCutoff(io, start)) return;
        const start_name = (try nr.createOrUpdate(start, taggerdate, 0, 0, from_tag)) orelse return;
        start_name.tip_name = if (deref) try a.print("{s}^0", .{tip_name}) else tip_name;

        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(nr.gpa);
        var to_queue: std.ArrayList(Oid) = .empty;
        defer to_queue.deinit(nr.gpa);
        try stack.append(nr.gpa, start);
        while (stack.pop()) |c| {
            const name = nr.names.get(c).?;
            to_queue.clearRetainingCapacity();
            const parents = (try nr.commit(io, c)).parents;
            for (parents, 1..) |parent, number| {
                if (try nr.beforeCutoff(io, parent)) continue;
                var generation: u32 = undefined;
                var distance: u32 = undefined;
                if (number > 1) {
                    generation = 0;
                    distance = name.distance + merge_traversal_weight;
                } else {
                    generation = name.generation + 1;
                    distance = name.distance + 1;
                }
                const parent_name = (try nr.createOrUpdate(parent, taggerdate, generation, distance, from_tag)) orelse continue;
                if (number > 1) {
                    const base = stripPeelSuffix(name.tip_name);
                    parent_name.tip_name = if (name.generation > 0)
                        try a.print("{s}~{d}^{d}", .{ base, name.generation, number })
                    else
                        try a.print("{s}^{d}", .{ base, number });
                } else {
                    parent_name.tip_name = name.tip_name;
                }
                try to_queue.append(nr.gpa, parent);
            }
            // The first parent must come out of the stack first.
            while (to_queue.pop()) |p| try stack.append(nr.gpa, p);
        }
    }
};

/// `subpath_matches`: where in `path` -- at its start or after a `/` --
/// `filter` matches the rest, or `null`.
fn subpathMatches(path: []const u8, filter: []const u8) ?usize {
    var at: usize = 0;
    while (true) {
        if (wildmatch.match(filter, path[at..], .{}) catch false) return at;
        const slash = std.mem.findScalarPos(u8, path, at, '/') orelse return null;
        at = slash + 1;
    }
}

/// `refs_shorten_unambiguous_ref`, not strict: the shortest form of
/// `refname` that no rule before the one it matches resolves to another
/// ref.
fn shortenUnambiguous(a: Allocator, io: Io, store: *refs_mod.Store, refname: []const u8) Error![]const u8 {
    const rules = [_][2][]const u8{
        .{ "", "" },
        .{ "refs/", "" },
        .{ "refs/tags/", "" },
        .{ "refs/heads/", "" },
        .{ "refs/remotes/", "" },
        .{ "refs/remotes/", "/HEAD" },
    };
    var i: usize = rules.len - 1;
    while (i > 0) : (i -= 1) {
        const rule = rules[i];
        if (!std.mem.startsWith(u8, refname, rule[0]) or !std.mem.endsWith(u8, refname, rule[1])) continue;
        if (refname.len <= rule[0].len + rule[1].len) continue;
        const short = refname[rule[0].len .. refname.len - rule[1].len];
        var ambiguous = false;
        for (rules[0..i]) |other| {
            const candidate = try std.mem.concat(a, u8, &.{ other[0], short, other[1] });
            if (store.read(a, io, candidate) catch null) |_| {
                ambiguous = true;
                break;
            }
        }
        if (!ambiguous) return a.dupe(u8, short);
    }
    return a.dupe(u8, refname);
}

const testgit = @import("../testing/git.zig");

/// A history with merges, a clock skew, annotated and lightweight tags,
/// two annotated tags on one commit, a tag that calls itself by another
/// name, a tag of a tree and a branch of its own: what `describe` is asked
/// about below.
const Fixture = struct {
    env: std.process.Environ.Map,
    r: testgit.Repo,
    /// `label=<hex>` for every commit.
    commits: std.ArrayList([2][]const u8) = .empty,

    fn init(gpa: Allocator, io: Io, f: *Fixture) !void {
        f.env = try testgit.datedEnv(gpa, base);
        errdefer f.env.deinit();
        f.r = try testgit.Repo.init(gpa, io, &.{});
        f.r.environ = &f.env;
        f.commits = .empty;
        errdefer {
            for (f.commits.items) |c| {
                gpa.free(c[0]);
                gpa.free(c[1]);
            }
            f.commits.deinit(gpa);
            f.r.deinit();
        }
        try f.commit(io, "c1", 1000);
        try f.tagAt(io, &.{ "tag", "-a", "-m", "zero one", "v0.1" }, 1000);
        try f.commit(io, "c2", 2000);
        try f.r.exec(io, &.{ "checkout", "-q", "-b", "side" });
        try f.commit(io, "s1", 2500);
        try f.commit(io, "s2", 2600);
        try f.r.exec(io, &.{ "tag", "light-side" });
        try f.r.exec(io, &.{ "checkout", "-q", "main" });
        try f.commit(io, "c3", 3000);
        try f.tagAt(io, &.{ "tag", "-a", "-m", "zero two", "v0.2" }, 3000);
        try testgit.setDate(&f.env, base + 4000);
        try f.r.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "c4", "side" });
        try f.label(io, "c4");
        try f.commit(io, "c5", 5000);
        try f.r.exec(io, &.{ "tag", "lw5" });
        try f.commit(io, "c6", 6000);
        try f.tagAt(io, &.{ "tag", "-a", "-m", "rc", "v1.0-rc" }, 5900);
        try f.tagAt(io, &.{ "tag", "-a", "-m", "one", "v1.0" }, 6100);
        try f.commit(io, "c7", 7000);
        try f.tagAt(io, &.{ "tag", "-a", "-m", "real", "real", "HEAD~6" }, 7000);
        const real = try f.r.line(io, &.{ "rev-parse", "refs/tags/real" });
        defer gpa.free(real);
        try f.r.exec(io, &.{ "update-ref", "refs/tags/alias", real });
        try f.r.exec(io, &.{ "tag", "-d", "real" });
        try f.tagAt(io, &.{ "tag", "-a", "-m", "a tree", "treetag", "HEAD^{tree}" }, 7000);
        // A commit dated before its parent.
        try f.commit(io, "c8", 1500);
        try f.r.exec(io, &.{ "checkout", "-q", "-b", "topic", "HEAD~3" });
        try f.commit(io, "t1", 8000);
        try f.r.exec(io, &.{ "checkout", "-q", "main" });
    }

    const base: i64 = 1_700_000_000;

    fn deinit(f: *Fixture, gpa: Allocator) void {
        for (f.commits.items) |c| {
            gpa.free(c[0]);
            gpa.free(c[1]);
        }
        f.commits.deinit(gpa);
        f.r.deinit();
        f.env.deinit();
        f.* = undefined;
    }

    fn commit(f: *Fixture, io: Io, name: []const u8, when: i64) !void {
        try testgit.setDate(&f.env, base + when);
        try f.r.writeFile(io, name, name);
        try f.r.exec(io, &.{ "add", name });
        try f.r.exec(io, &.{ "commit", "-q", "-m", name });
        try f.label(io, name);
    }

    fn label(f: *Fixture, io: Io, name: []const u8) !void {
        const hex = try f.r.line(io, &.{ "rev-parse", "HEAD" });
        try f.commits.append(f.r.gpa, .{ try f.r.gpa.dupe(u8, name), hex });
    }

    fn tagAt(f: *Fixture, io: Io, args: []const []const u8, when: i64) !void {
        try testgit.setDate(&f.env, base + when);
        try f.r.exec(io, args);
    }
};

/// What git prints, or `<failed>`.
fn gitSays(gpa: Allocator, io: Io, r: *testgit.Repo, args: []const []const u8) ![]u8 {
    r.report_failures = false;
    defer r.report_failures = true;
    return r.run(io, args) catch |err| switch (err) {
        error.GitFailed => gpa.dupe(u8, "<failed>"),
        else => |e| e,
    };
}

fn relicSays(gpa: Allocator, io: Io, repo: *Repository, rev: []const u8, options: Options) ![]u8 {
    const text = describe(gpa, io, repo, rev, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return gpa.dupe(u8, "<failed>"),
    };
    defer gpa.free(text);
    return gpa.print("{s}\n", .{text});
}

test "describe names every commit as git describe does, under every option" {
    // git 2.48 stops the search earlier than older gits; this is its search.
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 48);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f: Fixture = undefined;
    try Fixture.init(gpa, io, &f);
    defer f.deinit(gpa);
    var repo = try Repository.open(gpa, io, f.r.dir, .{});
    defer repo.deinit(io);

    const Case = struct { args: []const []const u8, options: Options };
    const cases = [_]Case{
        .{ .args = &.{}, .options = .{} },
        .{ .args = &.{"--tags"}, .options = .{ .tags = true } },
        .{ .args = &.{"--all"}, .options = .{ .all = true } },
        .{ .args = &.{"--long"}, .options = .{ .long = true } },
        .{ .args = &.{"--abbrev=0"}, .options = .{ .abbrev = 0 } },
        .{ .args = &.{"--abbrev=12"}, .options = .{ .abbrev = 12 } },
        .{ .args = &.{"--abbrev=2"}, .options = .{ .abbrev = 2 } },
        .{ .args = &.{"--candidates=1"}, .options = .{ .candidates = 1 } },
        .{ .args = &.{ "--candidates=2", "--tags" }, .options = .{ .candidates = 2, .tags = true } },
        .{ .args = &.{"--exact-match"}, .options = .{ .candidates = 0 } },
        .{ .args = &.{ "--exact-match", "--tags" }, .options = .{ .candidates = 0, .tags = true } },
        .{ .args = &.{ "--match", "v0*" }, .options = .{ .match = &.{"v0*"} } },
        .{ .args = &.{ "--exclude", "v1*", "--tags" }, .options = .{ .exclude = &.{"v1*"}, .tags = true } },
        .{ .args = &.{ "--all", "--match", "s*" }, .options = .{ .all = true, .match = &.{"s*"} } },
        .{ .args = &.{"--first-parent"}, .options = .{ .first_parent = true } },
        .{ .args = &.{ "--first-parent", "--tags" }, .options = .{ .first_parent = true, .tags = true } },
        .{ .args = &.{ "--match", "none*", "--always" }, .options = .{ .match = &.{"none*"}, .always = true } },
        .{ .args = &.{ "--match", "none*" }, .options = .{ .match = &.{"none*"} } },
        .{ .args = &.{ "--long", "--abbrev=0" }, .options = .{ .long = true, .abbrev = 0 } },
        .{ .args = &.{"--contains"}, .options = .{ .contains = true } },
        .{ .args = &.{ "--contains", "--all" }, .options = .{ .contains = true, .all = true } },
        .{ .args = &.{ "--contains", "--match", "v0*" }, .options = .{ .contains = true, .match = &.{"v0*"} } },
        .{ .args = &.{ "--contains", "--always", "--exclude", "v*" }, .options = .{ .contains = true, .always = true, .exclude = &.{"v*"} } },
    };
    for (cases) |case| {
        for (f.commits.items) |c| {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.append(gpa, "describe");
            try args.appendSlice(gpa, case.args);
            try args.append(gpa, c[1]);
            const expected = try gitSays(gpa, io, &f.r, args.items);
            defer gpa.free(expected);
            const got = try relicSays(gpa, io, &repo, c[1], case.options);
            defer gpa.free(got);
            std.testing.expectEqualStrings(expected, got) catch |err| {
                std.debug.print("git describe {any} {s} differs\n", .{ case.args, c[0] });
                return err;
            };
        }
    }
}

test "describe names a blob after the first commit that holds it, and a dirty HEAD as git does" {
    // git 2.52 reworked describing a blob; this is its answer.
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 52);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f: Fixture = undefined;
    try Fixture.init(gpa, io, &f);
    defer f.deinit(gpa);
    var repo = try Repository.open(gpa, io, f.r.dir, .{});
    defer repo.deinit(io);
    for ([_][]const u8{ "HEAD:c3", "HEAD:s1", "topic:t1" }) |spec| {
        const blob = try f.r.line(io, &.{ "rev-parse", spec });
        defer gpa.free(blob);
        const expected = try gitSays(gpa, io, &f.r, &.{ "describe", blob });
        defer gpa.free(expected);
        const got = try relicSays(gpa, io, &repo, blob, .{});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }
    const tree = try f.r.line(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(tree);
    try std.testing.expectError(error.NotCommitOrBlob, describe(gpa, io, &repo, tree, .{}));

    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    const misnamed = try describe(gpa, io, &repo, f.commits.items[0][1], .{ .warnings = &warnings });
    defer gpa.free(misnamed);
    // `alias` names a tag object that calls itself `real`, on c1.
    try std.testing.expect(warnings.items.items.len == 1);

    const clean = try head(gpa, io, &repo, .{ .dirty = "-dirty" });
    defer gpa.free(clean);
    try f.r.writeFile(io, "c7", "changed");
    for ([_]Options{ .{ .dirty = "-dirty" }, .{ .dirty = ".mod" }, .{ .broken = "-broken" } }, [_][]const []const u8{
        &.{ "describe", "--dirty" }, &.{ "describe", "--dirty=.mod" }, &.{ "describe", "--broken" },
    }) |options, args| {
        const expected = try gitSays(gpa, io, &f.r, args);
        defer gpa.free(expected);
        const got = try head(gpa, io, &repo, options);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(expected[0 .. expected.len - 1], got);
        try std.testing.expect(std.mem.endsWith(u8, got, if (options.dirty) |m| m else "-dirty"));
    }
}
