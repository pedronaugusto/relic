//! `formatCommit` in colour against `git log --format`: the same
//! repository, the same colour settings, the same bytes.

const std = @import("std");
const Io = std.Io;

const pretty = @import("pretty.zig");
const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const color = @import("../config/color.zig");
const testgit = @import("../testing/git.zig");

/// Branches, tags light and annotated, a remote branch, a stash and
/// `HEAD` on a branch: every decoration `git log` shows by default, each in
/// its colour.
fn setup(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "a", "one\n");
    try git.exec(io, &.{ "add", "a" });
    try git.exec(io, &.{ "commit", "-q", "-m", "first" });
    try git.exec(io, &.{ "tag", "light" });
    try git.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1" });
    try git.exec(io, &.{ "update-ref", "refs/remotes/origin/main", "HEAD" });
    try git.writeFile(io, "a", "two\n");
    try git.exec(io, &.{ "commit", "-q", "-a", "-m", "second" });
    try git.exec(io, &.{ "branch", "side" });
    try git.exec(io, &.{ "update-ref", "refs/stash", "HEAD" });
    try git.writeFile(io, "a", "three\n");
    try git.exec(io, &.{ "commit", "-q", "-a", "-m", "third" });
}

test "a log format in colour is git log --format's: %C(...), %C(auto), the names and decorations it paints, color.decorate.* and color.diff.commit" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setup(io, &git);
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var decorations = try pretty.Decorations.load(gpa, io, &repo);
    defer decorations.deinit();

    const listed = try git.run(io, &.{ "rev-list", "--all" });
    defer gpa.free(listed);

    const formats = [_][]const u8{
        "%C(auto)%h%d %s",
        "%C(auto)%H %D%Creset",
        "%Cred%h%Creset %C(blue bold)%s%C(reset) %C(always,green)x%C(auto,yellow)y%Cgreen%Cblue",
        "%C(auto)%(decorate:prefix=[,suffix=],separator=%x3b,pointer=>,tag=T:)",
        "%C(auto)%(decorate:prefix=,suffix=,tag=)|%h",
        "%C(red)x%C(auto)%d%C(green)%h",
        "%Cfoo %C(auto)%h %C(nope %h",
        "%+C(red)%-C(auto)%h",
    };
    const settings = [_][]const []const u8{
        &.{},
        &.{ "color.decorate.branch=blue", "color.decorate.HEAD=red ul", "color.diff.commit=magenta", "color.decorate.tag=normal", "color.decorate.remoteBranch=#ff0000", "color.decorate.stash=dim", "color.decorate.grafted=green" },
        &.{ "diff.color.commit=cyan", "color.decorate.unknown=red" },
    };
    for (settings) |set| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (set) |s| {
            const eq = std.mem.findScalar(u8, s, '=').?;
            const last_dot = std.mem.findScalarLast(u8, s[0..eq], '.').?;
            const first_dot = std.mem.findScalar(u8, s, '.').?;
            if (first_dot == last_dot) {
                try text.print(gpa, "[{s}]\n\t{s} = \"{s}\"\n", .{ s[0..first_dot], s[first_dot + 1 .. eq], s[eq + 1 ..] });
            } else try text.print(gpa, "[{s} \"{s}\"]\n\t{s} = \"{s}\"\n", .{ s[0..first_dot], s[first_dot + 1 .. last_dot], s[last_dot + 1 .. eq], s[eq + 1 ..] });
        }
        var config = try config_mod.Config.parseText(gpa, text.items, .local);
        defer config.deinit();
        for ([_]color.Output{ .always, .plain }) |output| {
            const colors = try pretty.Colors.configured(&config, output);
            for (formats) |format| {
                var args: std.ArrayList([]const u8) = .empty;
                defer args.deinit(gpa);
                for (set) |s| try args.appendSlice(gpa, &.{ "-c", s });
                const format_arg = try std.mem.concat(gpa, u8, &.{ "--format=", format });
                defer gpa.free(format_arg);
                try args.appendSlice(gpa, &.{ "log", "--all", format_arg, if (output.asked.? == .always) "--color=always" else "--no-color" });
                const theirs = try git.run(io, args.items);
                defer gpa.free(theirs);

                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                var ours: std.ArrayList(u8) = .empty;
                var lines = std.mem.tokenizeScalar(u8, listed, '\n');
                while (lines.next()) |hex| {
                    // each commit into a buffer of its own, as git's log
                    // formats it: `%-` and `%C(auto)` look at what is before
                    var one: std.ArrayList(u8) = .empty;
                    try pretty.formatCommit(arena.allocator(), io, .{ .db = repo.objectDatabase(), .oid = try hash.Oid.parse(.sha1, hex), .format = format }, &one, .{
                        .decorations = &decorations,
                        .colors = if (colors) |*c| c else null,
                    });
                    try ours.appendSlice(arena.allocator(), one.items);
                    try ours.append(arena.allocator(), '\n');
                }
                std.testing.expectEqualStrings(theirs, ours.items) catch |err| {
                    std.debug.print("format {s}, colour {}, settings {d}\n", .{ format, output.asked.?, set.len });
                    return err;
                };
            }
        }
    }
}

test "a colour that does not parse is refused where git dies, and passed over where git writes none" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setup(io, &git);
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head_hex = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_hex);
    const head = try hash.Oid.parse(.sha1, head_hex);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const colors: pretty.Colors = .{};
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expectError(error.InvalidColor, pretty.formatCommit(arena.allocator(), io, .{ .db = repo.objectDatabase(), .oid = head, .format = "%C(bogus)x" }, &out, .{ .colors = &colors }));
    try std.testing.expectError(error.InvalidColor, pretty.formatCommit(arena.allocator(), io, .{ .db = repo.objectDatabase(), .oid = head, .format = "%C(always,bogus)x" }, &out, .{}));
    git.report_failures = false;
    try std.testing.expectError(error.GitFailed, git.run(io, &.{ "log", "-1", "--color=always", "--format=%C(bogus)x" }));
    try std.testing.expectError(error.GitFailed, git.run(io, &.{ "log", "-1", "--no-color", "--format=%C(always,bogus)x" }));
    git.report_failures = true;

    out.clearRetainingCapacity();
    try pretty.formatCommit(arena.allocator(), io, .{ .db = repo.objectDatabase(), .oid = head, .format = "%C(bogus)x%C(auto,bogus)y" }, &out, .{});
    const theirs = try git.run(io, &.{ "log", "-1", "--no-color", "--format=%C(bogus)x%C(auto,bogus)y" });
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, try std.mem.concat(arena.allocator(), u8, &.{ out.items, "\n" }));
}
