//! Configuration injection: text a repository chose becoming configuration
//! that runs a command -- a `!command` update in `.gitmodules`, a long value
//! whose `[section]` text a section rename read as a header. The owners are
//! `submodule/gitmodules.zig` (the architecture's `config/`), which never
//! takes a command from `.gitmodules`, and `config.zig`'s writer, which
//! edits the lines it parsed rather than reading them again.

const std = @import("std");
const Io = std.Io;

const gitmodules = @import("../../submodule/gitmodules.zig");
const submodule = @import("../../submodule.zig");
const fsck = @import("../../object/fsck.zig");
const config_mod = @import("../../config.zig");
const repo_mod = @import("../../repo.zig");
const testgit = @import("../git.zig");

test "CVE-2019-19604, t7406-submodule-update 'submodule update - command in .gitmodules is rejected', 'fsck detects command in .gitmodules' and 'submodule init does not copy command into .git/config'" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const text = "[submodule \"sub\"]\n\tpath = sub\n\turl = ./sub\n\tupdate = !touch pwned\n";
    try std.testing.expectError(error.InvalidUpdate, gitmodules.Gitmodules.parse(gpa, text));
    const finding = (try fsck.checkBlob(gpa, &fsck.baseline, .zero(.sha1), .modules, text, null)).?;
    try std.testing.expectEqual(fsck.Problem.gitmodules_update, finding.problem.?);

    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    const head = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    const gitlink = try std.fmt.allocPrint(gpa, "160000,{s},sub", .{head});
    defer gpa.free(gitlink);
    try git.writeFile(io, ".gitmodules", text);
    try git.exec(io, &.{ "update-index", "--add", "--cacheinfo", gitlink });
    try git.exec(io, &.{ "add", ".gitmodules" });
    try git.exec(io, &.{ "commit", "-q", "-m", "sub" });
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var env = try testgit.programEnviron(gpa);
    defer env.deinit();
    try std.testing.expectError(error.InvalidUpdate, submodule.init(gpa, io, &repo, .{}));
    try std.testing.expectError(error.InvalidUpdate, submodule.update(gpa, io, &repo, .{ .init = true, .programs = .{ .environ = &env } }));
    const config = try git.readFile(io, ".git/config");
    defer gpa.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "[submodule") == null);
    try std.testing.expect(std.mem.indexOf(u8, config, "pwned") == null);
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, "pwned", .{}));
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, "sub/pwned", .{}));
}

test "CVE-2023-29007, t1300-config 'renaming a section with a long line' and 'renaming an embedded section with a long line': a value's [section] text never becomes a header" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const pad = " " ** 1024;
    for ([_][]const u8{
        "[b]\n  c = d " ++ pad ++ " [a] e = f\n[a] g = h\n",
        "[b]\n  c = d " ++ pad ++ " [a] [foo] e = f\n[a] g = h\n",
    }) |text| {
        try git.writeFile(io, "y", text);
        try git.exec(io, &.{ "config", "-f", "y", "--remove-section", "a" });
        const theirs = try git.readFile(io, "y");
        defer gpa.free(theirs);

        var config = try config_mod.Config.parseText(gpa, text, .local);
        defer config.deinit();
        config.files.items[0].writable = true;
        try std.testing.expect(try config.removeSectionIn(.local, "a", null));
        const ours = try config.renderWritable();
        defer gpa.free(ours);
        try std.testing.expectEqualStrings(theirs, ours);
        // Read again, the long value is still one value of `b`.
        var again = try config_mod.Config.parseText(gpa, ours, .local);
        defer again.deinit();
        try std.testing.expect(again.get("b.e") == null);
        try std.testing.expect(again.get("foo.e") == null);
        try std.testing.expect(std.mem.endsWith(u8, again.get("b.c").?, "e = f"));
    }
}
