//! The chunk directory shared by git's repository accelerators.
const std = @import("std");
const hash = @import("hash.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{CorruptAccelerator} || Allocator.Error;

/// An owned byte buffer used by the format writers.
pub const Buffer = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(b: *Buffer) void {
        b.bytes.deinit(b.gpa);
    }
    pub fn add(b: *Buffer, bytes: []const u8) Allocator.Error!void {
        try b.bytes.appendSlice(b.gpa, bytes);
    }
    pub fn int(b: *Buffer, comptime T: type, value: T) Allocator.Error!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        try b.add(&bytes);
    }
    pub fn finish(b: *Buffer) Allocator.Error![]u8 {
        return b.bytes.toOwnedSlice(b.gpa);
    }
};

/// A chunk's four-byte name and its contents, in file order.
pub const Chunk = struct { id: *const [4]u8, bytes: []const u8 };

/// Encode a header, chunk table and trailer. `header` already names the chunk count.
pub fn encode(gpa: Allocator, kind: hash.Kind, header: []const u8, chunks: []const Chunk) Allocator.Error![]u8 {
    var out: Buffer = .{ .gpa = gpa };
    defer out.deinit();
    try out.add(header);
    var offset: u64 = header.len + (chunks.len + 1) * 12;
    for (chunks) |chunk| {
        try out.add(chunk.id);
        try out.int(u64, offset);
        offset += chunk.bytes.len;
    }
    try out.int(u32, 0);
    try out.int(u64, offset);
    for (chunks) |chunk| try out.add(chunk.bytes);
    var hasher = hash.Hasher.init(kind);
    hasher.update(out.bytes.items);
    const checksum = hasher.final();
    try out.add(checksum.raw());
    return out.finish();
}

/// Validate chunk boundaries, unique names and the trailing checksum.
pub fn validate(kind: hash.Kind, bytes: []const u8, header_len: usize, count: u8) Error!void {
    const table_end = header_len + (@as(usize, count) + 1) * 12;
    if (bytes.len < table_end + kind.rawLen()) return error.CorruptAccelerator;
    const data_end = bytes.len - kind.rawLen();
    var previous: u64 = table_end;
    for (0..@as(usize, count) + 1) |i| {
        const row = bytes[header_len + i * 12 ..][0..12];
        const offset = std.mem.readInt(u64, row[4..12], .big);
        if (offset < previous or offset > data_end or (i == 0 and offset != table_end)) return error.CorruptAccelerator;
        if (i == count) {
            if (!std.mem.eql(u8, row[0..4], &.{ 0, 0, 0, 0 }) or offset != data_end) return error.CorruptAccelerator;
        } else {
            if (std.mem.eql(u8, row[0..4], &.{ 0, 0, 0, 0 })) return error.CorruptAccelerator;
            for (0..i) |j| if (std.mem.eql(u8, row[0..4], bytes[header_len + j * 12 ..][0..4])) return error.CorruptAccelerator;
        }
        previous = offset;
    }
    var hasher = hash.Hasher.init(kind);
    hasher.update(bytes[0..data_end]);
    const checksum = hasher.final();
    if (!std.mem.eql(u8, checksum.raw(), bytes[data_end..])) return error.CorruptAccelerator;
}

/// Find a chunk after `validate` has accepted its table.
pub fn get(bytes: []const u8, header_len: usize, count: u8, id: *const [4]u8) ?[]const u8 {
    for (0..count) |i| {
        const row = bytes[header_len + i * 12 ..][0..12];
        if (!std.mem.eql(u8, row[0..4], id)) continue;
        const start: usize = @intCast(std.mem.readInt(u64, row[4..12], .big));
        const end: usize = @intCast(std.mem.readInt(u64, bytes[header_len + (i + 1) * 12 + 4 ..][0..8], .big));
        return bytes[start..end];
    }
    return null;
}
