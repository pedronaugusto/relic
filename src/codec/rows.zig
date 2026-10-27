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

    /// How many rows the table holds.
    pub fn count(rows: Rows) usize {
        return rows.bytes.len / rows.width;
    }

    /// Row `i`, or `null` past the last.
    pub fn at(rows: Rows, i: usize) ?[]const u8 {
        if (i >= rows.count()) return null;
        const start = std.math.mul(usize, i, rows.width) catch return null;
        if (start > rows.bytes.len or rows.bytes.len - start < rows.width) return null;
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
