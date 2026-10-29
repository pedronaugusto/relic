//! Count submissions through the caller's Io, regardless of where the
//! executor runs them: a layer whose state is the counts, so each test
//! holds its own. Await every submitted task before reading them.
const std = @import("std");
const Io = std.Io;
const shakedown = @import("shakedown");

pub const Counts = struct {
    /// Resolve nonblocking group work inline too: a single-threaded executor
    /// ordinarily refuses concurrent submissions. Forward them as async work
    /// so all requested tasks run, with the same group lifetime and awaits.
    inline_groups: bool = false,
    async_count: std.atomic.Value(usize) = .init(0),
    concurrent_count: std.atomic.Value(usize) = .init(0),
    group_async: std.atomic.Value(usize) = .init(0),
    group_concurrent: std.atomic.Value(usize) = .init(0),

    pub fn expect(c: *const Counts, async_groups: usize, concurrent_groups: usize) !void {
        try std.testing.expectEqual(@as(usize, 0), c.async_count.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 0), c.concurrent_count.load(.monotonic));
        try std.testing.expectEqual(async_groups, c.group_async.load(.monotonic));
        try std.testing.expectEqual(concurrent_groups, c.group_concurrent.load(.monotonic));
    }
};

pub const Tasks = shakedown.Layer(Counts, .{
    .async = async,
    .concurrent = concurrent,
    .groupAsync = groupAsync,
    .groupConcurrent = groupConcurrent,
});

fn async(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
    const l = Tasks.of(userdata);
    _ = l.state.async_count.fetchAdd(1, .monotonic);
    return l.base.vtable.async(l.base.userdata, result, result_alignment, context, context_alignment, start);
}

fn concurrent(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    const l = Tasks.of(userdata);
    _ = l.state.concurrent_count.fetchAdd(1, .monotonic);
    return l.base.vtable.concurrent(l.base.userdata, result_len, result_alignment, context, context_alignment, start);
}

fn groupAsync(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) void {
    const l = Tasks.of(userdata);
    _ = l.state.group_async.fetchAdd(1, .monotonic);
    l.base.vtable.groupAsync(l.base.userdata, group, context, context_alignment, start);
}

fn groupConcurrent(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
    const l = Tasks.of(userdata);
    _ = l.state.group_concurrent.fetchAdd(1, .monotonic);
    if (l.state.inline_groups) return l.base.vtable.groupAsync(l.base.userdata, group, context, context_alignment, start);
    return l.base.vtable.groupConcurrent(l.base.userdata, group, context, context_alignment, start);
}

/// The bytes the calls named `call` moved, by `faults`' trace, which must
/// keep every record.
pub fn moved(faults: *shakedown.FaultIo, call: shakedown.IoCall) u64 {
    var bytes: u64 = 0;
    for (faults.trace().records()) |record| if (record.event.call == call) switch (record.event.outcome) {
        .ok => |n| bytes += n,
        .err => {},
    };
    return bytes;
}

/// `shakedown.everyFault` with a cancel at each cancelation point of the
/// operation `ctx` describes, and no other fault: each run's `check` can
/// hand its result to `cancelKept`.
pub fn everyCancel(gpa: std.mem.Allocator, io: Io, ctx: anytype) !void {
    var failed: shakedown.EveryFaultReport = .{};
    defer failed.deinit();
    var report = shakedown.everyFault(gpa, io, ctx, .{ .errors = &.{}, .short = false, .alloc = false, .trace = .all, .diagnostics = &failed }) catch |err| {
        if (failed.failure) |f| std.debug.print("{t} at {?any} (first difference {?d}):\n{s}\n", .{ f.err, f.injected, f.difference, f.trace });
        return err;
    };
    report.deinit();
}

/// For `everyFault`'s `check`: a cancel that landed comes back as
/// `error.Canceled`, or, where the operation went on to an outcome of its
/// own, waits at the task's next cancelation point. It is never lost.
pub fn cancelKept(io: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
    const at = injected orelse return result;
    if (at.fault != .cancel) return;
    if (result) |_| {
        io.checkCancel() catch return;
    } else |err| if (err == error.Canceled) return;
    std.debug.print("a cancel at step {d} ({t}) was lost\n", .{ at.step, at.call });
    return error.CancelLost;
}
