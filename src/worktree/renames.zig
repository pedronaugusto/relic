//! `git status`'s renames: the staged changes, HEAD against the index, and
//! the working tree's, the index against the files, each put through diff's
//! rename detection (`diff.findRenames`, the one engine) as git's
//! `wt_status_collect_changes_index` and `wt_status_collect_changes_worktree`
//! put them, and what `status.renames` and `status.renameLimit` ask for.
//!
//! Status itself is the checkout layer's, below diff; the pass is here,
//! above both. In the working tree a deletion pairs with a file the index
//! holds as an intent to add, whose bytes the status kept
//! (`StatusOptions.added_content`) and the engine reads from memory.

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

/// Which of a status entry's two changes a pass pairs.
const Side = enum { staged, unstaged };

/// Pair `status`'s deletions with its additions, and with copies its
/// modifications as sources too, as git's status pairs them, the staged
/// side and the working tree's each on its own: a rename's destination
/// becomes `renamed` with its `source` and `score`, its source's deletion
/// goes (and the entry with it when nothing else is said of the path), a
/// copy's destination becomes `copied`. A conflicted path takes no part. In
/// the working tree the additions are the files the index holds as an
/// intent to add; a status made without `StatusOptions.added_content` has
/// not kept their bytes, and its working tree's side is not paired.
pub fn find(io: Io, status: *checkout.Status, inputs: Inputs, options: diff.RenameOptions) Error!void {
    var arena_state = status.arena.promote(status.gpa);
    defer status.arena = arena_state.state;
    const arena = arena_state.allocator();
    // git collects the working tree's changes first; the two sides share no
    // pair, so the order decides nothing.
    try pass(arena, io, status, inputs, options, .unstaged);
    try pass(arena, io, status, inputs, options, .staged);
}

fn changeOf(e: *const checkout.StatusEntry, side: Side) checkout.Change {
    return switch (side) {
        .staged => e.staged,
        .unstaged => e.unstaged,
    };
}

fn pass(arena: Allocator, io: Io, status: *checkout.Status, inputs: Inputs, options: diff.RenameOptions, side: Side) Error!void {
    var deleted: usize = 0;
    var added: usize = 0;
    for (status.entries) |*e| {
        if (e.conflicted) continue;
        switch (changeOf(e, side)) {
            .deleted => deleted += 1,
            .added => if (side == .staged or e.added != null) {
                added += 1;
            },
            else => {},
        }
    }
    if (added == 0 or (deleted == 0 and !options.detect_copies)) return;

    const head: std.StringHashMapUnmanaged(checkout.TreeEntry) = if (side == .unstaged)
        .empty
    else if (inputs.head_tree) |tree|
        try checkout.flatten(arena, io, inputs.db, tree)
    else
        .empty;
    var contents: std.AutoHashMapUnmanaged(hash.Oid, []const u8) = .empty;
    var changes: std.ArrayList(diff.Change) = .empty;
    for (status.entries) |*e| {
        if (e.conflicted) continue;
        const status_of: diff.Status = switch (changeOf(e, side)) {
            .deleted => .deleted,
            .added => .added,
            .modified, .type_changed => if (options.detect_copies) .modified else continue,
            else => continue,
        };
        // Before: HEAD's file on the staged side, the index's in the
        // working tree. After: the index's file, or the working tree's.
        const indexed: ?diff.Entry = if (inputs.index.find(e.path)) |i| .{ .path = e.path, .mode = i.mode, .oid = i.oid } else null;
        const old: ?diff.Entry = if (status_of == .added) null else switch (side) {
            .staged => if (head.get(e.path)) |h| .{ .path = e.path, .mode = h.mode, .oid = h.oid } else continue,
            .unstaged => indexed orelse continue,
        };
        const new: ?diff.Entry = if (status_of == .deleted) null else switch (side) {
            .staged => indexed orelse continue,
            .unstaged => if (status_of == .modified) indexed.? else if (e.added) |file| blk: {
                try contents.put(arena, file.oid, file.bytes);
                break :blk .{ .path = e.path, .mode = file.mode, .oid = file.oid };
            } else continue,
        };
        try changes.append(arena, .{ .status = status_of, .old = old, .new = new });
    }
    try diff.findRenames(arena, io, .{ .db = inputs.db, .contents = &contents }, &changes, options);

    var gone: std.StringHashMapUnmanaged(void) = .empty;
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    for (status.entries, 0..) |e, i| try by_path.put(arena, e.path, i);
    for (changes.items) |c| {
        if (c.status != .renamed and c.status != .copied) continue;
        const at = by_path.get(c.new.?.path) orelse continue;
        const entry = &status.entries[at];
        const found: checkout.Change = if (c.status == .renamed) .renamed else .copied;
        switch (side) {
            .staged => entry.staged = found,
            .unstaged => entry.unstaged = found,
        }
        entry.source = c.old.?.path;
        entry.score = c.similarity;
        if (c.status == .renamed) try gone.put(arena, c.old.?.path, {});
    }
    if (gone.count() == 0 and !options.detect_copies) return;
    var kept: std.ArrayList(checkout.StatusEntry) = .empty;
    for (status.entries) |e| {
        var entry = e;
        if (gone.contains(e.path) and changeOf(&e, side) == .deleted) {
            switch (side) {
                .staged => entry.staged = .unmodified,
                .unstaged => entry.unstaged = .unmodified,
            }
            if (entry.staged == .unmodified and entry.unstaged == .unmodified and entry.submodule == null) continue;
        }
        try kept.append(arena, entry);
    }
    status.entries = try kept.toOwnedSlice(arena);
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
