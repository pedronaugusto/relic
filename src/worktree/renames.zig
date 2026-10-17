//! `git status`'s renames: the staged changes, HEAD against the index, put
//! through diff's rename detection (`diff.findRenames`, the one engine) as
//! git's `wt_status_collect_changes_index` puts them, and what
//! `status.renames` and `status.renameLimit` ask for.
//!
//! Status itself is the checkout layer's, below diff; the pass is here,
//! above both. Only the staged side is paired: git also pairs a deletion in
//! the working tree with an intent-to-add file there, which needs the
//! working tree's bytes in the pairing, and relic's engine pairs objects.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const checkout = @import("../checkout/checkout.zig");
const diff = @import("../diff/diff.zig");
const config_mod = @import("../config/config.zig");
const hash = @import("../hash/hash.zig");
const index_mod = @import("../index/index.zig");
const odb_mod = @import("../odb/odb.zig");

/// Errors from `find`.
pub const Error = diff.Error || checkout.Error;

/// What `find` reads besides the status: the index and object
/// database it was made from, and the tree it compared the index with,
/// `null` for none (an unborn branch).
pub const Inputs = struct { index: *const index_mod.Index, db: *odb_mod.Odb, head_tree: ?hash.Oid };

/// Pair `status`'s staged deletions with its staged additions, and with
/// copies its staged modifications as sources too, as git's status pairs
/// them: a rename's destination becomes `renamed` with its `source` and
/// `score`, its source's staged deletion goes (and the entry with it when
/// nothing else is said of the path), a copy's destination becomes
/// `copied`. A conflicted path takes no part.
pub fn find(io: Io, status: *checkout.Status, inputs: Inputs, options: diff.RenameOptions) Error!void {
    var deleted: usize = 0;
    var added: usize = 0;
    for (status.entries) |e| {
        if (e.conflicted) continue;
        if (e.staged == .deleted) deleted += 1;
        if (e.staged == .added) added += 1;
    }
    if (added == 0 or (deleted == 0 and !options.detect_copies)) return;

    var arena_state = status.arena.promote(status.gpa);
    defer status.arena = arena_state.state;
    const arena = arena_state.allocator();

    const head: std.StringHashMapUnmanaged(checkout.TreeEntry) = if (inputs.head_tree) |tree|
        try checkout.flatten(arena, io, inputs.db, tree)
    else
        .empty;
    var changes: std.ArrayList(diff.Change) = .empty;
    for (status.entries) |e| {
        if (e.conflicted) continue;
        const status_of: diff.Status = switch (e.staged) {
            .deleted => .deleted,
            .added => .added,
            .modified, .type_changed => if (options.detect_copies) .modified else continue,
            else => continue,
        };
        const old: ?diff.Entry = if (status_of == .added) null else if (head.get(e.path)) |h| .{ .path = e.path, .mode = h.mode, .oid = h.oid } else continue;
        const new: ?diff.Entry = if (status_of == .deleted) null else if (inputs.index.find(e.path)) |i| .{ .path = e.path, .mode = i.mode, .oid = i.oid } else continue;
        try changes.append(arena, .{ .status = status_of, .old = old, .new = new });
    }
    try diff.findRenames(arena, io, inputs.db, &changes, options);

    var gone: std.StringHashMapUnmanaged(void) = .empty;
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    for (status.entries, 0..) |e, i| try by_path.put(arena, e.path, i);
    for (changes.items) |c| {
        if (c.status != .renamed and c.status != .copied) continue;
        const at = by_path.get(c.new.?.path) orelse continue;
        const entry = &status.entries[at];
        entry.staged = if (c.status == .renamed) .renamed else .copied;
        entry.source = c.old.?.path;
        entry.score = c.similarity;
        if (c.status == .renamed) try gone.put(arena, c.old.?.path, {});
    }
    if (gone.count() == 0 and !options.detect_copies) return;
    var kept: std.ArrayList(checkout.StatusEntry) = .empty;
    for (status.entries) |e| {
        var entry = e;
        if (gone.contains(e.path) and e.staged == .deleted) {
            entry.staged = .unmodified;
            if (entry.unstaged == .unmodified and entry.submodule == null) continue;
        }
        try kept.append(arena, entry);
    }
    status.entries = kept.items;
}

/// The renames git's status looks for, as its configuration reads:
/// `status.renames` (git's `git_config_rename`: a boolean, `copies`, a
/// bare name renames) and `status.renameLimit`, every value in order, over
/// `diff.renames` and `diff.renameLimit` (`diff.RenameSettings`), which
/// git's status reads too; on, with a limit of 1000, when none says.
/// `null` for none.
pub fn configured(config: *const config_mod.Config) diff.ConfigError!?diff.RenameOptions {
    var settings = try diff.RenameSettings.read(config);
    var it = config.iterate(&.{ "status.renames", "status.renamelimit" });
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "renames")) {
            settings.detection = try diff.parseRenameSetting(entry.value);
        } else settings.limit = try diff.parseRenameLimit(entry.value);
    }
    return settings.options();
}
