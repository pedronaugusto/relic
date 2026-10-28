//! A table of fixed-width rows inside a file a parser has read: a pack
//! index's names and offsets, a multi-pack index's objects, a commit graph's
//! commit data. The parser cuts the table to the rows the format declares,
//! and a row is read by its position, checked against the table, so a
//! position a corrupt file gives past the end is refused, not read past.

const std = @import("std");

pub const Rows = struct {
    /// The table: every row, end to end.
    bytes: []const u8,
    /// How far one row is from the next.
    width: usize,

    /// A table of no rows.
    pub const empty: Rows = .{ .bytes = &.{}, .width = 1 };

    /// `rows` rows of `width` bytes from `start` in `file`, or `null` where
    /// the file is shorter than that. `width` is not 0.
    pub fn cut(file: []const u8, start: usize, rows: usize, width: usize) ?Rows {
        std.debug.assert(width != 0);
        const len = std.math.mul(usize, rows, width) catch return null;
        if (start > file.len or file.len - start < len) return null;
        return .{ .bytes = file[start..][0..len], .width = width };
    }

    /// `rows` rows of `width` bytes at the end of `file`, and the bytes
    /// before them, or `null` where the file is shorter than that: a table a
    /// format puts after records of their own lengths.
    pub fn last(file: []const u8, rows: usize, width: usize) ?struct { rows: Rows, before: []const u8 } {
        std.debug.assert(width != 0);
        const len = std.math.mul(usize, rows, width) catch return null;
        const start = std.math.sub(usize, file.len, len) catch return null;
        return .{ .rows = .{ .bytes = file[start..], .width = width }, .before = file[0..start] };
    }

    /// `bytes` as exactly `rows` rows of `width` bytes, or `null` where it
    /// is any other length: a chunk whose rows the format counts elsewhere.
    pub fn exactly(bytes: []const u8, rows: usize, width: usize) ?Rows {
        const table = cut(bytes, 0, rows, width) orelse return null;
        return if (table.bytes.len == bytes.len) table else null;
    }

    /// The whole rows of `width` bytes in `bytes`, any bytes after the last
    /// left out: a chunk git reads as its length over the row's width.
    pub fn whole(bytes: []const u8, width: usize) Rows {
        std.debug.assert(width != 0);
        return .{ .bytes = bytes[0 .. bytes.len - bytes.len % width], .width = width };
    }

    /// How many rows the table holds.
    pub fn count(rows: Rows) usize {
        return rows.bytes.len / rows.width;
    }

    /// Row `i`, or `null` past the last.
    pub fn at(rows: Rows, i: usize) ?[]const u8 {
        if (i >= rows.count()) return null;
        const start = std.math.mul(usize, i, rows.width) catch return null;
        const left = std.math.sub(usize, rows.bytes.len, start) catch return null;
        if (left < rows.width) return null;
        return rows.bytes[start..][0..rows.width];
    }
};

test "a table is cut to the rows it declares and read only within them" {
    const file = "headAAAABBBBCCCCtail";
    const rows = Rows.cut(file, 4, 3, 4).?;
    try std.testing.expectEqual(@as(usize, 3), rows.count());
    try std.testing.expectEqualStrings("BBBB", rows.at(1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), rows.at(3));
    try std.testing.expectEqual(@as(?Rows, null), Rows.cut(file, 4, 5, 4));
    try std.testing.expectEqual(@as(?Rows, null), Rows.cut(file, 30, 0, 4));
    try std.testing.expectEqual(@as(?Rows, null), Rows.cut(file, 0, std.math.maxInt(usize), 4));
    try std.testing.expectEqual(@as(usize, 0), Rows.empty.count());
}

test "a table at the end of a file is cut from what comes before it" {
    const cut = Rows.last("headAAAABBBB", 2, 4).?;
    try std.testing.expectEqualStrings("head", cut.before);
    try std.testing.expectEqualStrings("BBBB", cut.rows.at(1).?);
    try std.testing.expectEqual(@as(usize, 0), Rows.last("head", 0, 4).?.rows.count());
    try std.testing.expect(Rows.last("headAAA", 2, 4) == null);
    try std.testing.expect(Rows.last("head", std.math.maxInt(usize), 4) == null);
}

test "a chunk is a table of exactly its rows, or of its whole rows" {
    try std.testing.expectEqual(@as(usize, 2), Rows.exactly("AAAABBBB", 2, 4).?.count());
    try std.testing.expectEqual(@as(?Rows, null), Rows.exactly("AAAABBBBC", 2, 4));
    try std.testing.expectEqual(@as(?Rows, null), Rows.exactly("AAAA", 2, 4));
    const rows = Rows.whole("AAAABBBBCC", 4);
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqual(@as(?[]const u8, null), rows.at(2));
}
