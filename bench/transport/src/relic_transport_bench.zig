//! relic's side of the transport bench: one clone or one fetch, timed in
//! process from the call to its return, printed in milliseconds.
//!
//!   relic_transport_bench clone <url> <dir> [check]
//!   relic_transport_bench fetch <dir> [check]
//!
//! The environment is the process's own, handed to relic as its Programs:
//! GIT_SSH_COMMAND names the stand-in ssh. Objects are checked as git's
//! transfer.fsckObjects would check them only with `check`, which git does
//! not do by default.
const std = @import("std");
const relic = @import("relic");

const who: relic.object.Signature = .{ .name = "Bench", .email = "bench\x40example.invalid", .when_secs = 1_700_000_000, .offset_minutes = 0 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const env = init.environ_map;
    const cwd = std.Io.Dir.cwd();
    const check = args.len > 0 and std.mem.eql(u8, args[args.len - 1], "check");
    const start = benchmarkNow(io);
    if (std.mem.eql(u8, args[1], "clone")) {
        // RELIC_BENCH_REPEAT runs the clone that many times in one process,
        // each into a fresh directory, for a sampling profiler to attach to.
        const repeat = if (env.get("RELIC_BENCH_REPEAT")) |t| std.fmt.parseUnsigned(u32, t, 10) catch 1 else 1;
        for (0..repeat) |_| {
            cwd.deleteTree(io, args[3]) catch {};
            try cwd.createDirPath(io, args[3]);
            var dir = try cwd.openDir(io, args[3], .{ .iterate = true });
            defer dir.close(io);
            var repo = try relic.transport.clone.clone(gpa, io, args[2], dir, .{
                .who = who,
                .bare = true,
                .programs = .{ .environ = env },
                .check_objects = check,
            });
            repo.deinit(io);
        }
    } else if (std.mem.eql(u8, args[1], "fetch")) {
        var dir = try cwd.openDir(io, args[2], .{ .iterate = true });
        defer dir.close(io);
        var repo = try relic.repo.Repository.open(gpa, io, dir, .{});
        defer repo.deinit(io);
        var outcome = try relic.transport.fetch.fetch(gpa, io, &repo, "origin", .{
            .who = who,
            .programs = .{ .environ = env },
            .check_objects = check,
        });
        outcome.deinit();
    } else return error.UnknownCommand;
    const elapsed = start.durationTo(benchmarkNow(io));
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{d:.1}\n", .{@as(f64, @floatFromInt(elapsed.nanoseconds)) / 1e6});
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
