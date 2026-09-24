//! A partial clone's filter, read as git reads `--filter=<spec>` and the
//! `filter` line a server is sent: `blob:none`, `blob:limit=<size>`,
//! `tree:<depth>`, `object:type=<type>`, `sparse:oid=<blob>`, and
//! `combine:<spec>+<spec>…`, each part percent-encoded where it holds a
//! character git reserves.
//!
//! The numbers are read as git's `git_parse_ulong` reads them: white space
//! and a `+` may come first, `0x` makes hexadecimal and a leading `0`
//! octal, and `k`, `m` or `g` in either case may follow; a `-` anywhere is
//! refused. A `combine:`'s empty parts are passed over, as git passes them;
//! one with no part at all is refused. `sparse:path=`, whose support git
//! dropped, is refused, as git refuses it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const object = @import("object.zig");

/// Errors from reading a filter.
pub const Error = error{
    /// Not a filter git reads: what git calls an invalid filter-spec.
    InvalidFilter,
} || Allocator.Error;

/// A filter, read.
pub const Spec = union(enum) {
    /// `blob:none`: no blob.
    blob_none,
    /// `blob:limit=<n>`: no blob larger than `n` bytes.
    blob_limit: u64,
    /// `tree:<depth>`: no tree or blob at `depth` or deeper.
    tree_depth: u64,
    /// `object:type=<type>`: only objects of the type.
    object_type: object.Type,
    /// `sparse:oid=<blob>`: every tree, and the blobs the sparse-checkout
    /// patterns in the named blob take in. The name is the server's to
    /// resolve, as written.
    sparse_oid: []const u8,
    /// `combine:`: what every part keeps.
    combine: []const Spec,
};

/// Read `text`. The result's slices are `arena`'s or `text`'s.
pub fn parse(arena: Allocator, text: []const u8) Error!Spec {
    if (std.mem.eql(u8, text, "blob:none")) return .blob_none;
    if (std.mem.startsWith(u8, text, "blob:limit=")) return .{ .blob_limit = try parseUlong(text["blob:limit=".len..]) };
    if (std.mem.startsWith(u8, text, "tree:")) return .{ .tree_depth = try parseUlong(text["tree:".len..]) };
    if (std.mem.startsWith(u8, text, "sparse:oid=")) return .{ .sparse_oid = text["sparse:oid=".len..] };
    if (std.mem.startsWith(u8, text, "object:type=")) {
        const name = text["object:type=".len..];
        for ([_]object.Type{ .blob, .tree, .commit, .tag }) |t| {
            if (std.mem.eql(u8, name, @tagName(t))) return .{ .object_type = t };
        }
        return error.InvalidFilter;
    }
    if (std.mem.startsWith(u8, text, "combine:")) {
        const rest = text["combine:".len..];
        if (rest.len == 0) return error.InvalidFilter;
        var parts: std.ArrayList(Spec) = .empty;
        var it = std.mem.splitScalar(u8, rest, '+');
        while (it.next()) |encoded| {
            if (encoded.len == 0) continue;
            // A character git reserves is written as `%XX`.
            for (encoded) |c| {
                if (std.mem.indexOfScalar(u8, reserved, c) != null or std.ascii.isWhitespace(c)) return error.InvalidFilter;
            }
            try parts.append(arena, try parse(arena, try percentDecode(arena, encoded)));
        }
        return .{ .combine = parts.items };
    }
    return error.InvalidFilter;
}

/// The filter as git sends it to a server and records it in
/// `remote.<name>.partialclonefilter`: a `blob:limit` on its own in bytes,
/// anything else as written, once it reads. The result is `arena`'s, or
/// `text` itself.
pub fn sendForm(arena: Allocator, text: []const u8) Error![]const u8 {
    const spec = try parse(arena, text);
    return switch (spec) {
        .blob_limit => |n| std.fmt.allocPrint(arena, "blob:limit={d}", .{n}),
        else => text,
    };
}

/// The characters a `combine:` part may not hold unencoded: git's
/// `RESERVED_NON_WS`.
const reserved = "~`!@#$^&*()[]{}\\;'\",<>?";

/// `git_parse_ulong`: `strtoumax` with base 0, then a unit.
fn parseUlong(text: []const u8) Error!u64 {
    if (std.mem.indexOfScalar(u8, text, '-') != null) return error.InvalidFilter;
    var i: usize = 0;
    while (i < text.len and isCSpace(text[i])) i += 1;
    if (i < text.len and text[i] == '+') i += 1;
    var base: u8 = 10;
    if (i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X') and
        i + 2 < text.len and std.ascii.isHex(text[i + 2]))
    {
        base = 16;
        i += 2;
    } else if (i < text.len and text[i] == '0') {
        base = 8;
    }
    const start = i;
    var value: u64 = 0;
    while (i < text.len) : (i += 1) {
        const digit = std.fmt.charToDigit(text[i], base) catch break;
        value = std.math.mul(u64, value, base) catch return error.InvalidFilter;
        value = std.math.add(u64, value, digit) catch return error.InvalidFilter;
    }
    if (i == start) return error.InvalidFilter;
    const unit = text[i..];
    const factor: u64 = if (unit.len == 0)
        1
    else if (unit.len == 1) switch (std.ascii.toLower(unit[0])) {
        'k' => 1024,
        'm' => 1024 * 1024,
        'g' => 1024 * 1024 * 1024,
        else => return error.InvalidFilter,
    } else return error.InvalidFilter;
    return std.math.mul(u64, value, factor) catch error.InvalidFilter;
}

fn isCSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

/// git's `url_percent_decode`: `%XX` is the byte, and a `%` not followed by
/// two hexadecimal digits is itself.
fn percentDecode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len and std.ascii.isHex(text[i + 1]) and std.ascii.isHex(text[i + 2])) {
            const high = std.fmt.charToDigit(text[i + 1], 16) catch unreachable;
            const low = std.fmt.charToDigit(text[i + 2], 16) catch unreachable;
            try out.append(arena, high * 16 + low);
            i += 2;
            continue;
        }
        try out.append(arena, text[i]);
    }
    return out.items;
}

const testing = std.testing;
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");

test "a filter is read, and refused, where git's own reading reads and refuses it" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testgit.requireGit(gpa, io);
    var repo = try testremote.historyRepo(gpa, io, 1);
    defer repo.deinit();
    try repo.writeFile(io, "sparse-spec", "/a\n");
    try repo.exec(io, &.{ "add", "sparse-spec" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "spec" });
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "blob:none",                       "blob:none ",                                      "blob:limit=1k",
        "blob:limit=1K",                   "blob:limit=+5",                                   "blob:limit=",
        "blob:limit=18446744073709551615", "blob:limit=17179869184g",                         "tree:0",
        "tree:1k",                         "tree:0x10",                                       "tree:010",
        "tree: 1",                         "tree:\t1",                                        "tree:+1",
        "tree:-1",                         "tree:1 ",                                         "tree:1kb",
        "tree:",                           "tree:99999999999999999999",                       "object:type=blob",
        "object:type=tag",                 "object:type=file",                                "object:type=",
        "sparse:oid=HEAD:sparse-spec",     "sparse:path=x",                                   "combine:",
        "combine:blob:none+tree:1",        "combine:blob:none",                               "combine:blob:none+",
        "combine:+blob:none",              "combine:blob:none++tree:1",                       "combine:combine:blob:none+tree:1",
        "combine:blob%3anone+tree%3A1",    "combine:blob:none+combine%3Atree:1%2Bblob:none",  "combine:blob:none+tree:1%",
        "combine:%zz",                     "combine:blob:none+sparse:oid=HEAD%3asparse-spec", "combine:blob:none+sparse:oid=HEAD~1",
        "combine:blob:none +tree:1",       "combine:tree:1%0",                                "nothing",
    }) |text| {
        const arg = try std.fmt.allocPrint(arena, "--filter={s}", .{text});
        // Quietly: most of these git refuses, as it should.
        const theirs = if (testremote.gitInputEnv(gpa, io, repo.dir, &env, &.{ "rev-list", "--objects", arg, "-n0", "HEAD" }, "", false)) |out| blk: {
            gpa.free(out);
            break :blk true;
        } else |_| false;
        const ours = if (parse(arena, text)) |_| true else |err| switch (err) {
            error.InvalidFilter => false,
            else => return err,
        };
        testing.expectEqual(theirs, ours) catch |err| {
            std.debug.print("{s}: git {s}, relic {s}\n", .{ text, if (theirs) "reads it" else "refuses it", if (ours) "reads it" else "refuses it" });
            return err;
        };
    }
    try testing.expectEqualStrings("blob:limit=1024", try sendForm(arena, "blob:limit=1k"));
    try testing.expectEqualStrings("combine:blob:limit=1k+tree:1", try sendForm(arena, "combine:blob:limit=1k+tree:1"));
    try testing.expectEqual(@as(u64, 16), (try parse(arena, "tree:0x10")).tree_depth);
    try testing.expectEqual(@as(u64, 8), (try parse(arena, "tree:010")).tree_depth);
}

test "fuzz: any filter is read or refused by name" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            const text = buf[0..smith.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            _ = sendForm(arena.allocator(), text) catch |err| switch (err) {
                error.InvalidFilter => return,
                else => return err,
            };
        }
    }.one, .{});
}
