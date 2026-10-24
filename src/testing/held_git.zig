//! The git release the comparisons are held to, asked once before the tests
//! run: the build runs this where they run (on the riscv64 machine under
//! `-Dci-vm`), and it fails, naming both releases, when the git the tests
//! would find is another. Asked in the tests, each test process would end at
//! its first git and Zig would start another for the next test, so a run
//! against another git failed every comparison one process at a time. A job
//! that runs the oldest supported git or git's development branch on purpose
//! (`RELIC_GIT`) is not held to the release; neither is a machine with no git,
//! whose comparisons skip.
const std = @import("std");
const git_release = @import("git_release.zig");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const environ = init.minimal.environ;
    if (git_release.hosted(a, environ)) |which| if (which != .release) return 0;
    const program = git_release.program(a, init.io, environ);
    const result = std.process.run(a, init.io, .{ .argv = &.{ program, "--version" } }) catch return 0;
    switch (result.term) {
        .exited => |code| if (code != 0) return 0,
        else => return 0,
    }
    const found = git_release.parse(result.stdout) orelse git_release.Version{ .major = 0, .minor = 0, .patch = 0 };
    if (found.eql(git_release.held)) return 0;
    var buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buffer);
    try stderr.interface.print(
        "relic's comparisons are held to git {f} (src/testing/git_release.zig), and the git the tests would run ({s}) is git {f}: run them with git {f}, or move the held release with the comparisons it changes\n",
        .{ git_release.held, program, found, git_release.held },
    );
    try stderr.interface.flush();
    return 1;
}
