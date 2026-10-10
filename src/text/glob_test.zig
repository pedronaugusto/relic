//! git's wildmatch through sweep, at every length git takes a pattern.

const std = @import("std");
const glob = @import("glob.zig");
const repeat = @import("shakedown").corpus.repeat;

const expect = std.testing.expect;

/// Both ways of asking: once, and compiled.
fn agree(pattern: []const u8, subject: []const u8, options: glob.Options) !bool {
    const gpa = std.testing.allocator;
    const once = try glob.matches(gpa, pattern, subject, options);
    var compiled: glob.Glob = try .compile(gpa, pattern, options);
    defer compiled.deinit();
    try std.testing.expectEqual(once, compiled.matches(subject));
    return once;
}

test "git's flags: pathname, case folding with its quirks, and the basename rule" {
    try expect(try agree("a/**/b", "a/x/y/b", .{}));
    try expect(try agree("a/**/b", "a/b", .{}));
    try expect(!try agree("*.c", "sub/foo.c", .{}));
    try expect(try agree("*.c", "sub/foo.c", .{ .pathname = false }));
    try expect(try agree("*.TXT", "readme.txt", .{ .case_fold = true }));
    // WM_CASEFOLD compares an escaped letter and a bracket member unfolded.
    try expect(!try agree("\\A", "a", .{ .case_fold = true }));
    try expect(!try agree("[A]", "a", .{ .case_fold = true }));
    try expect(try agree("[A-Z]", "q", .{ .case_fold = true }));
    try expect(try agree("*.o", "build/x/y.o", .{ .anywhere = true }));
    try expect(!try agree("b/*.o", "a/b/y.o", .{ .anywhere = true }));
}

test "a malformed pattern matches nothing, as git's matcher answers" {
    try expect(!try agree("a[bc", "a[bc", .{}));
    try expect(!try agree("[[:spaces:]]", " ", .{}));
    try expect(!try agree("a\\", "a\\", .{}));
    try expect(!glob.Glob.never.matches(""));
}

test "a pattern too long to match at once is compiled, and answers as a short one" {
    // Each `**/*a/` was a frame of the old matcher's recursion, and it
    // refused a pattern this deep; git's own backtracking takes minutes
    // on it. The language is regular, and sweep answers in one pass.
    const unit = "**/*a/";
    const pattern = repeat(unit, 600) ++ "z";
    const subject = repeat("a/", 600) ++ "z";
    try expect(pattern.len > 1024);
    try expect(try agree(pattern, subject, .{}));
    try expect(!try agree(pattern, subject[0 .. subject.len - 1] ++ "y", .{}));
    // More brackets than one call holds on the stack.
    const brackets = repeat("[ab]", 100);
    try expect(try agree(brackets, repeat("a", 100), .{}));
    try expect(!try agree(brackets, repeat("a", 99) ++ "c", .{}));
}

test "a pattern too long for a compiled one is a set of one, and still exact" {
    // A run of stars is one wildcard, so this is `*x/end` written long.
    const long = repeat("*", 9000) ++ "x/end";
    try expect(long.len > 8192);
    try expect(try agree(long, "abx/end", .{}));
    try expect(!try agree(long, "abx/ends", .{}));
    try expect(!try agree(long, "a/bx/end", .{}));
    try expect(!try agree(long ++ "[", "abx/end[", .{}));
    const name = repeat("d", 9000);
    try expect(try agree(name, name, .{}));
    try expect(!try agree(name, name[1..], .{}));

    var compiled: glob.Glob = try .compile(std.testing.allocator, long, .{});
    defer compiled.deinit();
    try std.testing.expectEqual(@as(?usize, 7), compiled.ancestor("abx/end/below/it"));
    try std.testing.expectEqual(@as(?usize, null), compiled.ancestor("abx/en/d"));
}

test "one long glob answers several threads at once" {
    var compiled: glob.Glob = try .compile(std.testing.allocator, repeat("*", 9000) ++ "x/end", .{});
    defer compiled.deinit();
    const Ask = struct {
        fn run(g: *const glob.Glob, wrong: *std.atomic.Value(u32)) void {
            for (0..2000) |_| {
                if (!g.matches("abx/end")) _ = wrong.fetchAdd(1, .monotonic);
                if (g.matches("abx/ends")) _ = wrong.fetchAdd(1, .monotonic);
            }
        }
    };
    var wrong: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Ask.run, .{ &compiled, &wrong });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
}

test "the prefix a pattern matches, in one pass" {
    var dir: glob.Glob = try .compile(std.testing.allocator, "art/deep", .{});
    defer dir.deinit();
    try std.testing.expectEqual(@as(?usize, 8), dir.ancestor("art/deep/x.png"));
    try std.testing.expectEqual(@as(?usize, null), dir.ancestor("art/deeper/x.png"));
    var name: glob.Glob = try .compile(std.testing.allocator, "images", .{ .anywhere = true });
    defer name.deinit();
    try std.testing.expectEqual(@as(?usize, 13), name.ancestor("assets/images/a.png"));
}

test "the shapes that made backtracking matchers slow answer at once" {
    const text = repeat("a", 400);
    try expect(!try agree("*a*a*a*a*a*a*a*a*b", text, .{}));
    try expect(!try agree("*a*a*a*a*a*a*a*a*b", text, .{ .pathname = false }));
    try expect(try agree("*a*a*a*a*a*a*a*a*a", text, .{}));
    const pattern = repeat("**/x*/", 12) ++ "y";
    const subject = repeat("x/", 40);
    try expect(!try agree(pattern, subject ++ "z", .{}));
    try expect(try agree(pattern, subject ++ "y", .{}));
}

test "git's special bytes and the literal prefix" {
    for ("*?[\\") |byte| try expect(glob.isSpecial(byte));
    for ("]{}!/a") |byte| try expect(!glob.isSpecial(byte));
    try std.testing.expectEqual(@as(usize, 4), glob.literalPrefix("src/*.c"));
    try std.testing.expectEqual(@as(usize, 3), glob.literalPrefix("abc"));
    try std.testing.expectEqual(@as(usize, 1), glob.literalPrefix("a\\*"));
}
