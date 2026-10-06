//! Configuration quoting: a value written so that reading it back gives
//! another value -- a trailing carriage return left unquoted, which the
//! reader takes for the end of a CRLF line -- so that a submodule's path
//! read back is a different path, a link into `.git/modules/<name>/hooks`.
//! The owner is `config.zig`'s writer, one policy for every file it writes:
//! what is written reads back as itself.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const config_mod = @import("../../config.zig");
const clone_mod = @import("../../transport/clone.zig");
const submodule = @import("../../submodule.zig");
const object = @import("../../object.zig");
const hostile = @import("hostile.zig");
const testgit = @import("../git.zig");

test "CVE-2025-48384, t1300-config 'writing value with trailing CR not stripped on read': a value ending in a carriage return reads back with it, in relic and in git" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var config = try config_mod.Config.parseText(gpa, "[core]\n\tbare = false\n", .local);
    defer config.deinit();
    config.files.items[0].writable = true;
    for ([_][]const u8{ "bar\r", "sub\r", "a\rb", " lead", "trail ", "x\r\r" }) |value| {
        try config.set("core.foo", value);
        const text = try config.renderWritable();
        defer gpa.free(text);
        var again = try config_mod.Config.parseText(gpa, text, .local);
        defer again.deinit();
        try std.testing.expectEqualStrings(value, again.get("core.foo").?);

        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        try git.writeFile(io, "written", text);
        const theirs = try git.run(io, &.{ "config", "-f", "written", "core.foo" });
        defer gpa.free(theirs);
        try std.testing.expectEqualStrings(value, theirs[0 .. theirs.len - 1]);
    }
}

test "CVE-2025-48384, t7450-bad-git-dotfiles 'submodule must not checkout into different directory': a submodule at sub<CR> is checked out there, not through a link at sub" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sub = try testgit.Repo.init(gpa, io, &.{});
    defer sub.deinit();
    try sub.writeFile(io, "post-checkout", "#!/bin/sh\ntouch \"$PWD/foo\"\n");
    try sub.exec(io, &.{ "add", "post-checkout" });
    try sub.exec(io, &.{ "commit", "-q", "-m", "hook" });
    const sub_path = try sub.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(sub_path);

    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    try repo.exec(io, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub_path, "sub" });
    try repo.exec(io, &.{ "mv", "sub", "sub\r" });
    try repo.exec(io, &.{ "config", "-f", ".gitmodules", "--unset", "submodule.sub.path" });
    const modules = try repo.readFile(io, ".gitmodules");
    defer gpa.free(modules);
    const with_path = try std.fmt.allocPrint(gpa, "{s}\tpath = \"sub\r\"\n", .{modules});
    defer gpa.free(with_path);
    try repo.writeFile(io, ".gitmodules", with_path);
    try repo.exec(io, &.{ "config", "-f", ".git/modules/sub/config", "--unset", "core.worktree" });
    const module_config = try repo.readFile(io, ".git/modules/sub/config");
    defer gpa.free(module_config);
    const with_worktree = try std.fmt.allocPrint(gpa, "{s}[core]\n\tworktree = \"../../../sub\r\"\n", .{module_config});
    defer gpa.free(with_worktree);
    try repo.writeFile(io, ".git/modules/sub/config", with_worktree);
    try repo.dir.symLink(io, ".git/modules/sub/hooks", "sub", .{});
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "submodule" });
    const repo_path = try repo.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(repo_path);

    var owner = try testgit.Repo.init(gpa, io, &.{});
    defer owner.deinit();
    try owner.dir.createDirPath(io, "bad-clone");
    var target = try owner.dir.openDir(io, "bad-clone", .{ .iterate = true });
    defer target.close(io);
    const who: object.Signature = .{ .name = "S", .email = "s@example.com", .when_secs = 1, .offset_minutes = 0 };
    var clone = try clone_mod.clone(gpa, io, repo_path, target, .{ .who = who });
    defer clone.deinit(io);
    var cloned = owner;
    cloned.dir = target;
    var t: hostile.GitClone = .{ .git = &cloned };
    _ = submodule.update(gpa, io, &clone, .{ .init = true, .transport = t.seam(), .who = who }) catch |err| switch (err) {
        error.UnsafePath, error.SymlinkInPath => {},
        else => return err,
    };
    // Wherever the submodule went, its hook did not go into `hooks`.
    try std.testing.expectError(error.FileNotFound, target.access(io, ".git/modules/sub/hooks/post-checkout", .{}));
    try std.testing.expectError(error.FileNotFound, owner.dir.access(io, "foo", .{}));
    if (target.access(io, "sub\r/post-checkout", .{})) {} else |_| {
        // Refused outright is as good: nothing was written through the link.
        try std.testing.expectError(error.FileNotFound, target.access(io, "sub/post-checkout", .{}));
    }
    // The submodule's own configuration, where there is one, still says
    // where it is.
    target.access(io, ".git/modules/sub/config", .{}) catch return;
    var written = try config_mod.Config.openFile(gpa, io, .{ .dir = target, .sub_path = ".git/modules/sub/config" }, .local, .{});
    defer written.deinit();
    if (written.get("core.worktree")) |value| try std.testing.expect(std.mem.endsWith(u8, value, "sub\r"));
}
