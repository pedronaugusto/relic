//! Holds a lock file the way a running git holds one, so the suite can prove
//! that a lock this package meets is reported and not broken.
//!
//! Argument one is the path to create with `O_CREAT|O_EXCL`; argument two is
//! the path to wait for. The process creates the lock, writes nothing, prints
//! `held\n` and exits when the second path appears or after its own timeout.

const std = @import("std");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa);
    defer threaded.deinit();
    const io = threaded.io();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) return error.Usage;

    const cwd: std.Io.Dir = .cwd();
    const lock_path = args[1];
    const release_path = args[2];

    const file = try cwd.createFile(io, lock_path, .{ .exclusive = true });
    defer file.close(io);

    var out_buf: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try stdout.interface.writeAll("held\n");
    try stdout.interface.flush();

    var waited: usize = 0;
    while (waited < 200) : (waited += 1) {
        cwd.access(io, release_path, .{}) catch {
            try std.Io.Timeout.sleep(.{ .duration = .fromMilliseconds(50) }, io);
            continue;
        };
        break;
    }
}
