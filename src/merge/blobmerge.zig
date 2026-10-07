//! The merge of one file's contents as git's `ll_merge` text driver makes
//! it: two sides that agree, or a side that left the file alone, are taken
//! whole; data git classifies as binary is refused; anything else is
//! parallax's three-way line merge, the bytes `git merge-file` writes.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const parallax = @import("../dependencies.zig").parallax;
const attributes = @import("../worktree/attributes.zig");

/// A content merge refuses data git classifies as binary.
pub const BlobError = error{BinaryBlob} || Allocator.Error;

/// Which conflict body to write, which is what `merge.conflictStyle` names.
pub const ConflictStyle = parallax.merge.Style;

/// The style a `merge.conflictStyle` value names, or `null` for one git
/// does not know.
pub fn parseConflictStyle(text: []const u8) ?ConflictStyle {
    return std.meta.stringToEnum(ConflictStyle, text);
}

/// What a conflict becomes: markers, or a side without them, as `-X ours`
/// and `-X theirs` ask, or both sides, as `merge=union` does.
pub const Resolve = parallax.merge.Resolve;

/// The words after the markers.
pub const Labels = parallax.merge.Labels;

/// How far a conflict is narrowed: git's merge machinery merges at
/// `.zealous`, `git merge-file` at `.zealous_alnum`.
pub const Level = parallax.merge.Level;

/// Options for a blob merge.
pub const BlobOptions = struct {
    conflict_style: ConflictStyle = .merge,
    labels: Labels = .{},
    /// How many characters each marker is: git's `conflict-marker-size`
    /// attribute, which is an `int` there and as wide here.
    marker_size: u32 = 7,
    resolve: Resolve = .markers,
    /// The line diff the two sides are taken with. `git merge-file`
    /// uses Myers; the merge machinery behind `merge`, `cherry-pick`,
    /// `revert` and `rebase` uses histogram.
    algorithm: parallax.Algorithm = .myers,
    /// Prove the Myers diffs minimal, the ones patience and histogram fall
    /// back to included: git's `diff-algorithm=minimal`.
    minimal: bool = false,
    /// The whitespace differences the merge overlooks, as the strategy
    /// options `ignore-all-space`, `ignore-space-change`,
    /// `ignore-space-at-eol` and `ignore-cr-at-eol` ask. A region the two
    /// sides differ in only by such whitespace is no change: an unchanged
    /// region keeps our side's lines, and a side whose every change is
    /// whitespace leaves the file to the other side.
    whitespace: parallax.Whitespace = .{},
    level: Level = .zealous,
};

/// The owned bytes produced by a blob merge.
pub const BlobResult = struct {
    gpa: Allocator,
    bytes: []u8,
    status: Status,

    pub const Status = enum { clean, conflicted };

    pub fn isClean(result: *const BlobResult) bool {
        return result.status == .clean;
    }

    pub fn deinit(result: *BlobResult) void {
        result.gpa.free(result.bytes);
        result.* = undefined;
    }
};

/// The largest side git merges as text, `MAX_XDIFF_SIZE`: a larger one is
/// merged as binary data is.
pub const max_text_size: usize = 1023 * 1024 * 1024;

/// Whether `ll_merge`'s text driver takes `bytes`: no larger than
/// `max_text_size`, and not binary by git's rule. Allocates nothing.
pub fn mergesAsText(bytes: []const u8) bool {
    return bytes.len <= max_text_size and !attributes.isBinaryForDiff(bytes);
}

/// Merge `ours` and `theirs` against `ancestor`, as git's `ll_merge` does
/// with its text driver. An unchanged side takes the other side byte for
/// byte, binary or not; otherwise a side that is binary, or larger than
/// `max_text_size`, is refused with `error.BinaryBlob`.
pub fn blobs(
    gpa: Allocator,
    ancestor: []const u8,
    ours: []const u8,
    theirs: []const u8,
    options: BlobOptions,
) Self.BlobError!BlobResult {
    if (std.mem.eql(u8, ours, theirs)) return ownedBlob(gpa, ours, .clean);
    if (std.mem.eql(u8, ours, ancestor)) return ownedBlob(gpa, theirs, .clean);
    if (std.mem.eql(u8, theirs, ancestor)) return ownedBlob(gpa, ours, .clean);
    for ([_][]const u8{ ancestor, ours, theirs }) |side| {
        if (!mergesAsText(side)) return error.BinaryBlob;
    }
    const merged = parallax.merge.mergeAlloc(gpa, ancestor, ours, theirs, .{
        .algorithm = options.algorithm,
        .minimal = options.minimal,
        .compare = .{ .whitespace = options.whitespace },
        .style = options.conflict_style,
        .level = options.level,
    }, .{
        .labels = options.labels,
        .marker_size = options.marker_size,
        .resolve = options.resolve,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // unreachable: every side is at most max_text_size, which a u32 indexes
        error.InputTooLarge => unreachable,
    };
    return .{ .gpa = gpa, .bytes = merged.bytes, .status = if (merged.conflicts == 0) .clean else .conflicted };
}

fn ownedBlob(gpa: Allocator, bytes: []const u8, status: BlobResult.Status) Allocator.Error!BlobResult {
    return .{ .gpa = gpa, .bytes = try gpa.dupe(u8, bytes), .status = status };
}
