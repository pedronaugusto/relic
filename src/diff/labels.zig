//! How a patch's headers name what they compare: objects by their short
//! names, paths quoted, a gitlink by the line git diffs it as. Shared by
//! the two-sided patch and the combined diff of a merge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const abbrev = @import("../odb/abbrev.zig");
const c_quote = @import("../text.zig").c_quote;

const Oid = hash.Oid;

/// An object's name on the `index` line, as git's `diff_abbrev_oid` writes
/// it: in full, or the shortest prefix of at least `len` the object
/// database holds no other object under; the null name cut at `len`.
pub fn abbreviated(io: Io, db: *odb_mod.Odb, oid: Oid, len: usize, full: bool, buf: *[hash.max_hex_len]u8) odb_mod.Error![]const u8 {
    if (full) return oid.hex(buf);
    if (oid.isZero()) return oid.abbrev(buf, len);
    return abbrev.unique(io, db, oid, len, buf);
}

/// `prefix` and `path` as a patch's headers write them: C-quoted
/// together as git's `quote_two_c_style` quotes them, where either needs
/// it. The text is `gpa`'s.
pub fn quoteTwo(gpa: Allocator, prefix: []const u8, path: []const u8, fully: bool) Allocator.Error![]u8 {
    if (!c_quote.needsQuote(prefix, fully) and !c_quote.needsQuote(path, fully)) return std.mem.concat(gpa, u8, &.{ prefix, path });
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('"') catch return error.OutOfMemory;
    c_quote.writeBody(&out.writer, prefix, fully) catch return error.OutOfMemory;
    c_quote.writeBody(&out.writer, path, fully) catch return error.OutOfMemory;
    out.writer.writeByte('"') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The longest line `gitlinkText` writes: the words, the widest name, the newline.
pub const gitlink_text_max = "Subproject commit \n".len + hash.max_hex_len;

/// A gitlink as git diffs it: the commit it names, as a line of text.
pub fn gitlinkText(buf: *[gitlink_text_max]u8, oid: Oid) []const u8 {
    var hex: [hash.max_hex_len]u8 = undefined;
    // unreachable: the buffer holds the words and the widest name
    return std.mem.print(buf, "Subproject commit {s}\n", .{oid.hex(&hex)}) catch unreachable;
}
