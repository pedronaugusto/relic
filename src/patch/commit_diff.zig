//! A commit's diff as `git log -p` and `git show` write it under the
//! commit's header: git's `log_tree_diff`.
//!
//! A commit with one parent is its diff against that parent, a root
//! commit's against nothing where the log shows one. A merge's depends on
//! the format `--diff-merges` names, or for `-m` and `--diff-merges=on`
//! the one `log.diffMerges` names (`configured`): none; the first parent's;
//! one against each parent in turn, which git's log heads each with the
//! parent it is against; the combined diff (`diff.combined`), dense or
//! not; or the remerge diff, the parents merged again in memory and that
//! merge, conflict markers and all, against the merge's own tree, each
//! conflict the merge met carried among its path's headers. `git show`
//! takes `dense_combined` for a merge where nothing else is asked.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const config_mod = @import("../config/config.zig");
const abbrev = @import("../odb/abbrev.zig");
const quarantine = @import("../odb/quarantine.zig");
const repo_mod = @import("../repo/repo.zig");
const diff = @import("../diff/diff.zig");
const combined = @import("../diff/combined.zig");
const driver = @import("../diff/driver.zig");
const textconv_mod = @import("../diff/textconv.zig");
const three_way = @import("../merge/three_way.zig");
const blob_merge = @import("../merge/blob_merge.zig");
const ort = @import("../merge/ort.zig");
const pretty = @import("../pretty/pretty.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from writing a commit's diff.
pub const Error = error{
    /// A `log.diffMerges` git does not know, or with no value, which git
    /// dies on.
    InvalidDiffMergesSetting,
    NotACommit,
    /// A remerge diff asked of a commit that is not a merge of two
    /// parents, which `parts` never asks.
    NotATwoParentMerge,
} || diff.UnifiedError || combined.Error || three_way.Error || quarantine.Error || pretty.Error || error{InvalidConflictStyle};

/// How a merge's diff is shown: git's `--diff-merges` formats.
pub const Merges = enum {
    /// None at all: `off`, `none`, `--no-diff-merges`.
    off,
    /// Against the first parent alone: `first-parent`, `1`, `--dd`.
    first_parent,
    /// Against each parent in turn: `separate`, git's default for `-m`.
    separate,
    /// The combined diff: `combined`, `c`, `-c`.
    combined,
    /// The dense combined diff: `dense-combined`, `cc`, `--cc`.
    dense_combined,
    /// The remerge diff: `remerge`, `r`, `--remerge-diff`.
    remerge,

    /// A format as git's `--diff-merges` and `log.diffMerges` spell it,
    /// case and all; `on` and `m` are `default`. `null` for any other
    /// word, which git dies on.
    pub fn parse(text: []const u8, default: Merges) ?Merges {
        const names = [_]struct { []const u8, Merges }{
            .{ "off", .off },                       .{ "none", .off },
            .{ "1", .first_parent },                .{ "first-parent", .first_parent },
            .{ "separate", .separate },             .{ "c", .combined },
            .{ "combined", .combined },             .{ "cc", .dense_combined },
            .{ "dense-combined", .dense_combined }, .{ "r", .remerge },
            .{ "remerge", .remerge },               .{ "m", default },
            .{ "on", default },
        };
        for (names) |entry| {
            if (std.mem.eql(u8, text, entry[0])) return entry[1];
        }
        return null;
    }
};

/// What `-m` and `--diff-merges=on` show: `log.diffMerges`, each value
/// read in turn as git's `diff_merges_config` reads it -- `on` keeping the
/// one before -- and `separate` where it is not set.
pub fn configured(config: *const config_mod.Config) error{InvalidDiffMergesSetting}!Merges {
    var merges: Merges = .separate;
    var it = config.iterate(&.{"log.diffmerges"});
    while (it.next()) |entry| {
        const text = entry.value orelse return error.InvalidDiffMergesSetting;
        merges = Merges.parse(text, merges) orelse return error.InvalidDiffMergesSetting;
    }
    return merges;
}

/// One diff of a commit, in the order git's log writes them.
pub const Part = union(enum) {
    /// Against one parent, or for a root commit against nothing (`null`).
    /// Under `separate` git's log writes the commit's header again before
    /// each, naming the parent (`(from <parent>)`).
    parent: ?Oid,
    /// The combined diff against every parent, dense or not.
    combined: struct { dense: bool },
    /// The parents merged again, against the merge.
    remerge,
    /// An octopus under `remerge`, which git does not merge again: it
    /// writes `diff: warning: Skipping remerge-diff for octopus merges.`
    octopus_skipped,
};

/// The diffs git's log writes for a commit with `parents` (its first
/// parent first), as its `log_tree_diff` chooses them: `show_root` for a
/// root commit's (`log.showRoot`, `--root`), `merges` for a merge's. The
/// list is `a`'s.
pub fn parts(a: Allocator, parents: []const Oid, merges: Merges, show_root: bool) Allocator.Error![]const Part {
    if (parents.len == 0) return if (show_root) a.dupe(Part, &.{.{ .parent = null }}) else &.{};
    if (parents.len == 1) return a.dupe(Part, &.{.{ .parent = parents[0] }});
    return switch (merges) {
        .off => &.{},
        .first_parent => a.dupe(Part, &.{.{ .parent = parents[0] }}),
        .separate => blk: {
            const out = try a.alloc(Part, parents.len);
            for (parents, out) |p, *part| part.* = .{ .parent = p };
            break :blk out;
        },
        .combined => a.dupe(Part, &.{.{ .combined = .{ .dense = false } }}),
        .dense_combined => a.dupe(Part, &.{.{ .combined = .{ .dense = true } }}),
        .remerge => a.dupe(Part, &.{if (parents.len > 2) .octopus_skipped else .remerge}),
    };
}

/// The commit, the part of its diff written, and what reads and converts
/// its files.
pub const Inputs = struct {
    repo: *Repository,
    commit: Oid,
    part: Part,
    /// The drivers the files take, as `diff.UnifiedInputs.drivers`.
    drivers: driver.Drivers = .{},
    /// `--textconv`, which `git log -p` and `git show` have by default.
    textconv: ?*const textconv_mod.Textconv = null,
};

/// How the diffs are made and written.
pub const Options = struct {
    /// The patch: its context, algorithm, prefixes, colours and the rest.
    diff: diff.Options = .{},
    /// Which paths and how they pair: renames, the order file, a
    /// pathspec, as `git log` takes them.
    tree: diff.TreeOptions = .{},
    /// `--combined-all-paths`, for a combined diff.
    combined_all_paths: bool = false,
};

/// Append the part `inputs.part` of the commit's diff to `w`, as git's
/// log writes it after the commit's header.
pub fn write(gpa: Allocator, io: Io, w: *Io.Writer, inputs: Inputs, options: Options) Self.Error!void {
    const repo = inputs.repo;
    const db = repo.objectDatabase();
    const tree = try repo.commitTree(io, inputs.commit);
    switch (inputs.part) {
        .parent => |parent| {
            const old: ?Oid = if (parent) |p| try repo.commitTree(io, p) else null;
            var changes = try diff.tree(gpa, io, db, .{ .old = old, .new = tree }, options.tree);
            defer changes.deinit();
            try diff.unified(gpa, io, w, .{ .db = db, .changes = changes.items, .drivers = inputs.drivers, .textconv = inputs.textconv }, options.diff);
        },
        .combined => |c| {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const parents = try parentsOf(arena.allocator(), io, repo, inputs.commit);
            const trees = try arena.allocator().alloc(Oid, parents.len);
            for (parents, trees) |p, *t| t.* = try repo.commitTree(io, p);
            var found = try combined.paths(gpa, io, db, .{ .result = tree, .parents = trees }, options.tree);
            defer found.deinit();
            try combined.write(gpa, io, w, .{ .db = db, .paths = found.items, .drivers = inputs.drivers, .textconv = inputs.textconv }, .{
                .diff = options.diff,
                .dense = c.dense,
                .all_paths = options.combined_all_paths,
            });
        },
        .remerge => try writeRemerge(gpa, io, w, inputs, options),
        .octopus_skipped => try w.writeAll("diff: warning: Skipping remerge-diff for octopus merges.\n"),
    }
}

/// The commit's parents, `a`'s.
fn parentsOf(a: Allocator, io: Io, repo: *Repository, oid: Oid) Self.Error![]const Oid {
    const db = repo.objectDatabase();
    const found = try db.read(io, oid);
    defer db.allocator().free(found.bytes);
    if (found.type != .commit) return error.NotACommit;
    const commit = try object.Commit.parse(a, db.objectFormat(), try a.dupe(u8, found.bytes));
    return commit.parents;
}

/// git's `do_remerge_diff`: the two parents merged again in memory, as
/// `git merge` would, each side labelled by its short name and subject,
/// the objects held in a quarantine thrown away after; then that tree
/// against the merge's, each conflict the merge met a `remerge` line among
/// its path's headers.
fn writeRemerge(gpa: Allocator, io: Io, w: *Io.Writer, inputs: Inputs, options: Options) Self.Error!void {
    const repo = inputs.repo;
    const config = repo.configuration();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const parents = try parentsOf(arena, io, repo, inputs.commit);
    if (parents.len != 2) return error.NotATwoParentMerge;
    const ctx: pretty.Context = .{ .abbrev_len = abbrev.defaultLength(config, repo.objectDatabase()) };
    var labels: [2][]const u8 = undefined;
    for (parents[0..2], &labels) |p, *label| {
        var text: std.ArrayList(u8) = .empty;
        try pretty.formatCommit(arena, io, .{ .db = repo.objectDatabase(), .oid = p, .format = "%h (%s)" }, &text, ctx);
        label.* = text.items;
    }

    var held = try quarantine.Quarantine.begin(gpa, io, repo.objectDatabase(), .remerge_diff);
    defer held.deinit(io);
    var merged = try three_way.inCoreCommits(gpa, io, repo, .{ .ours = parents[0], .theirs = parents[1], .db = &held.db }, .{ .blob = .{
        .algorithm = .histogram,
        .labels = .{ .ours = labels[0], .theirs = labels[1] },
        .conflict_style = try blob_merge.configuredStyle(config),
    } });
    defer merged.deinit();

    const headers = try conflictHeaders(arena, merged.messages, options.tree);
    const tree = try repo.commitTree(io, inputs.commit);
    var changes = try diff.tree(gpa, io, &held.db, .{ .old = merged.tree, .new = tree }, options.tree);
    defer changes.deinit();
    try diff.unified(gpa, io, w, .{
        .db = &held.db,
        .changes = changes.items,
        .drivers = inputs.drivers,
        .textconv = inputs.textconv,
        .headers = headers,
    }, options.diff);
}

/// The merge's messages as git records them for headers
/// (`record_conflict_msgs_as_headers`): only conflicts, the hints a merge
/// prints passed over, each `remerge ` and its text, every line after the
/// first indented a space. Under a pathspec only the paths it takes, and
/// none at all (`null`) where it takes none, as git's
/// `setup_additional_headers` leaves them.
fn conflictHeaders(arena: Allocator, messages: []const ort.Message, tree: diff.TreeOptions) Allocator.Error!?[]const diff.PathHeader {
    var out: std.ArrayList(diff.PathHeader) = .empty;
    for (messages) |msg| {
        if (omittable(msg.kind)) continue;
        const path = msg.paths[0];
        if (tree.paths) |paths| if (!paths.matches(path)) continue;
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, "remerge ");
        for (msg.text) |ch| {
            try text.append(arena, ch);
            if (ch == '\n') try text.append(arena, ' ');
        }
        try out.append(arena, .{ .path = path, .text = text.items });
    }
    if (tree.paths != null and out.items.len == 0) return null;
    return out.items;
}

/// git's hints, which a remerge diff leaves out: what is not a conflict,
/// and the suggestion of a directory rename.
fn omittable(kind: ort.MessageKind) bool {
    return switch (kind) {
        .auto_merging, .dir_rename_applied, .dir_rename_skipped, .submodule_fast_forwarding, .dir_rename_suggested => true,
        else => false,
    };
}
