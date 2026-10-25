//! The state files an operation keeps in the git directory while it is
//! under way (`MERGE_MSG`, `rebase-merge/`, `sequencer/`, `BISECT_LOG`, …):
//! one owner for writing, reading and removing them.

const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("../fs/fs.zig");
const quote = @import("../text.zig").quote;
const shakedown = @import("shakedown");
const hash = @import("../hash/hash.zig");

/// All errors reported by this namespace.
pub const Error = fs.AtomicWriteError || Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError;

/// Replace the state file `sub_path` under `dir` with `bytes`, making the
/// directories above it. State files are written unsynced, as git writes
/// them.
pub fn write(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8) Self.Error!void {
    if (std.Io.Dir.path.dirnamePosix(sub_path)) |parent| {
        dir.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    try fs.atomicWrite(io, dir, sub_path, bytes, .{ .prefix = ".relic-", .sync = .none });
}

/// The state file `sub_path` under `dir`, or `null`. The bytes are the
/// caller's.
pub fn read(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) aegis.own.ReadFileError!?[]u8 {
    return fs.readFileAlloc(gpa, io, dir, sub_path, 64 << 20);
}

/// Remove the state file `sub_path` under `dir`, which need not exist.
pub fn remove(io: Io, dir: Io.Dir, sub_path: []const u8) Self.Error!void {
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |e| return e,
    };
}

/// Whether the state file or directory `sub_path` under `dir` is there.
pub fn exists(io: Io, dir: Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

/// A one-line state file's value as git's `read_oneliner` takes it: one
/// `\n` off the end, and then one `\r`.
pub fn oneliner(bytes: []const u8) []const u8 {
    var v = bytes;
    if (v.len > 0 and v[v.len - 1] == '\n') {
        v = v[0 .. v.len - 1];
        if (v.len > 0 and v[v.len - 1] == '\r') v = v[0 .. v.len - 1];
    }
    return v;
}

/// An object name at the start of a state file's value, as git's
/// `get_oid_hex` reads it: the format's hex digits and whatever follows
/// them left unread. `null` where they are not all there.
pub fn oidHex(format: hash.Kind, text: []const u8) ?hash.Oid {
    const n = format.hexLen();
    if (text.len < n) return null;
    return hash.Oid.parse(format, text[0..n]) catch null;
}

/// The author an operation stopped with, as `rebase-merge/author-script` and
/// `rebase-apply/author-script` keep it: `GIT_AUTHOR_NAME`,
/// `GIT_AUTHOR_EMAIL` and `GIT_AUTHOR_DATE`, each single-quoted on its own
/// line. The date is as written: `@<seconds> <zone>` where rebase wrote it,
/// the mail's own date where `am` did, for git's `parse_date` to read.
pub const AuthorScript = struct {
    name: []const u8,
    email: []const u8,
    date: []const u8,

    /// The file is not one git reads: `read_author_script` refuses it.
    pub const ParseError = error{MalformedState} || Allocator.Error;

    /// git's `read_author_script` over `parse_key_value_squoted`, as strict
    /// as git is: the text as a C string, each `KEY=` up to the first `=`
    /// left in it (a blank line folds into the next key, which is then
    /// unknown), the value to the line's end one single-quoted word, each
    /// of the three exactly once and nothing else. What it returns is
    /// `arena`'s.
    pub fn parse(arena: Allocator, text_in: []const u8) ParseError!AuthorScript {
        var buf = text_in[0 .. std.mem.findScalar(u8, text_in, 0) orelse text_in.len];
        var found: [3]?[]const u8 = .{ null, null, null };
        const keys = [_][]const u8{ "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE" };
        while (buf.len > 0) {
            const eq = std.mem.findScalar(u8, buf, '=') orelse return error.MalformedState;
            const nl = std.mem.findScalarPos(u8, buf, eq, '\n') orelse buf.len;
            const key = buf[0..eq];
            const value = (try quote.sqDequote(arena, buf[eq + 1 .. nl])) orelse return error.MalformedState;
            buf = buf[@min(nl + 1, buf.len)..];
            const slot = for (keys, 0..) |k, i| {
                if (std.mem.eql(u8, key, k)) break i;
            } else return error.MalformedState;
            if (found[slot] != null) return error.MalformedState;
            found[slot] = value;
        }
        return .{
            .name = found[0] orelse return error.MalformedState,
            .email = found[1] orelse return error.MalformedState,
            .date = found[2] orelse return error.MalformedState,
        };
    }
};

test "an author script reads as git's read_author_script reads it, and is refused where git refuses it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = try AuthorScript.parse(a, "GIT_AUTHOR_NAME='A O'\\''Neil'\nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_DATE='@1700000000 +0100'\n");
    try std.testing.expectEqualStrings("A O'Neil", ok.name);
    try std.testing.expectEqualStrings("a@b", ok.email);
    try std.testing.expectEqualStrings("@1700000000 +0100", ok.date);
    // any order; no newline at the end
    const reordered = try AuthorScript.parse(a, "GIT_AUTHOR_DATE='Mon, 1 Jan 2024 10:00:00 +0000'\nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_NAME='A'");
    try std.testing.expectEqualStrings("Mon, 1 Jan 2024 10:00:00 +0000", reordered.date);
    for ([_][]const u8{
        "GIT_AUTHOR_NAME='A'\nGIT_AUTHOR_EMAIL='a@b'\n",
        "GIT_AUTHOR_NAME='A'\nGIT_AUTHOR_NAME='B'\nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_DATE='@1 +0000'\n",
        "GIT_AUTHOR_NAME='A'\nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_DATE='@1 +0000'\nGIT_COMMITTER_NAME='C'\n",
        "GIT_AUTHOR_NAME='A'\n\nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_DATE='@1 +0000'\n",
        "GIT_AUTHOR_NAME='A'\nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_DATE='@1 +0000'\n\n",
        "GIT_AUTHOR_NAME=A\nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_DATE='@1 +0000'\n",
        "GIT_AUTHOR_NAME='A' \nGIT_AUTHOR_EMAIL='a@b'\nGIT_AUTHOR_DATE='@1 +0000'\n",
    }) |bad| try std.testing.expectError(error.MalformedState, AuthorScript.parse(a, bad));
}

test "fuzz: any bytes are an author script or a named error" {
    try shakedown.check(std.testing.allocator, {}, fuzzAuthorScript, .{});
}

fn fuzzAuthorScript(_: void, case: *shakedown.Case) anyerror!void {
    var input: [256]u8 = undefined;
    const text = input[0..shakedown.gen.intRange(case.source, usize, 0, input.len)];
    case.source.bytes(text);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = AuthorScript.parse(arena.allocator(), text) catch |err| switch (err) {
        error.MalformedState => return,
        error.OutOfMemory => return err,
    };
}

test "a one-line state file reads as read_oneliner and get_oid_hex read it" {
    try std.testing.expectEqualStrings("a", oneliner("a\r\n"));
    try std.testing.expectEqualStrings("a\n", oneliner("a\n\n"));
    try std.testing.expectEqualStrings("a\r", oneliner("a\r"));
    try std.testing.expectEqualStrings(" a ", oneliner(" a \n"));
    const hex = "1234567890123456789012345678901234567890";
    try std.testing.expect(oidHex(.sha1, hex ++ " trailing") != null);
    try std.testing.expect(oidHex(.sha1, hex[0..39]) == null);
    try std.testing.expect(oidHex(.sha1, " " ++ hex) == null);
}
