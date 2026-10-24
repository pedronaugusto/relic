//! Cancellation proved per loop (design §11): a computation runs as a task
//! through `io.concurrent`, is canceled at one of its own cancellation
//! points, and must hand `error.Canceled` back.
//!
//! The task's `Io` is wrapped so that every `checkCancel` is counted. The
//! `at`-th one stops there, in a wait that only the cancel ends, and the
//! test cancels the task once it is stopped. That point then returns
//! `error.Canceled`, as Zig's cancel makes the task's next point do, and the
//! loop must return it rather than run on. No sleep and no input sized to
//! take seconds: the count is the progress, and where the cancel lands is a
//! step of the loop under test, so a loop with no point in it never gets
//! there and fails. `counted` runs the same computation without a cancel, so
//! a test can check that the answer is unchanged and the points are one per
//! step.
//!
//! One wrapper at a time, as in `io.zig`: the counts are this file's, and a
//! test awaits its task before arming another.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const reactor = @import("reactor");

var base: Io = undefined;
var vtable: Io.VTable = undefined;
/// The point to stop at, counted from 1; 0 never stops.
var stop_at: u64 = 0;
var points_seen: std.atomic.Value(u64) = .init(0);
var after_stop: std.atomic.Value(u64) = .init(0);
/// Set when the task reaches `stop_at` or returns, whichever is first.
var reached: Io.Event = .unset;
var finished: std.atomic.Value(bool) = .init(false);
/// Never changed: the stopped point waits on it until the cancel wakes it.
var parked: u32 = 0;

fn wrap(io: Io, at: u64) Io {
    base = io;
    stop_at = at;
    points_seen.store(0, .monotonic);
    after_stop.store(0, .monotonic);
    reached.reset();
    finished.store(false, .monotonic);
    vtable = io.vtable.*;
    vtable.checkCancel = checkCancel;
    return .{ .userdata = io.userdata, .vtable = &vtable };
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const n = points_seen.fetchAdd(1, .monotonic) + 1;
    if (stop_at != 0 and n > stop_at) _ = after_stop.fetchAdd(1, .monotonic);
    if (n != stop_at) return base.vtable.checkCancel(userdata);
    reached.set(base);
    // A futex wait is a cancellation point: it returns `error.Canceled`
    // once the test cancels, and before that only on a spurious wake.
    while (true) try base.futexWait(u32, &parked, 0);
}

/// `io` wrapped to count the cancellation points the computation asks,
/// without ever stopping; `points` reads the count.
pub fn counted(io: Io) Io {
    return wrap(io, 0);
}

/// How many cancellation points the computation run under `counted` or
/// `expectCanceled` asked.
pub fn points() u64 {
    return points_seen.load(.monotonic);
}

/// Run `function(io, args...)` as a task on `io`, cancel it at its `at`-th
/// cancellation point, and expect `error.Canceled` back. It fails if the
/// computation ends before reaching that point, and if it asked more than
/// `after` points past it on its way out.
pub fn expectCanceled(io: Io, at: u64, after: u64, function: anytype, args: anytype) !void {
    std.debug.assert(at != 0);
    const Fn = @TypeOf(function);
    const Result = @typeInfo(Fn).@"fn".return_type.?;
    const Task = struct {
        fn run(task_io: Io, task_args: @TypeOf(args)) Result {
            defer {
                finished.store(true, .monotonic);
                reached.set(base);
            }
            return @call(.auto, function, .{task_io} ++ task_args);
        }
    };
    const wrapped = wrap(io, at);
    var future = try io.concurrent(Task.run, .{ wrapped, args });
    reached.waitUncancelable(io);
    if (finished.load(.monotonic)) {
        _ = future.await(io) catch {}; // glint-ignore: Z026 -- what it returned does not matter: ending at all is the failure
        std.debug.print("the computation ended after {d} cancellation points, before point {d}\n", .{ points(), at });
        return error.TestUnexpectedResult;
    }
    const result = future.cancel(io);
    if (result) |_| {
        std.debug.print("the computation stopped at point {d} was canceled and finished all the same\n", .{at});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.Canceled, err);
    try testing.expect(after_stop.load(.monotonic) <= after);
}

/// Run `body(context, io)` on each backend the host has: `std.Io.Threaded`,
/// then an evented one, reactor's runtime (kqueue on macOS, io_uring or
/// epoll on Linux), where it has one. Zig 0.17's own evented backends
/// (`std.Io.Evented`) do not build.
pub fn eachBackend(context: anytype, comptime body: fn (@TypeOf(context), Io) anyerror!void) !void {
    const gpa = testing.allocator;
    {
        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        try body(context, threaded.io());
    }
    const runtime = try gpa.create(reactor.Runtime);
    defer gpa.destroy(runtime);
    // Stacks as deep as a thread's, for the computations under test.
    runtime.init(gpa, .{ .workers = 2, .max_tasks = 64, .stack_size = .fromRaw(16 << 20), .report_after = null }) catch |err| switch (err) {
        error.BackendUnavailable => return,
        else => |e| return e,
    };
    defer runtime.deinit();
    try runtime.start();
    try body(context, runtime.io());
}

fn spin(io: Io, steps: u64) Io.Cancelable!u64 {
    var i: u64 = 0;
    while (i < steps) : (i += 1) try io.checkCancel();
    return i;
}

fn spinNoPoints(io: Io, steps: u64) Io.Cancelable!u64 {
    _ = io;
    var i: u64 = 0;
    while (i < steps) : (i += 1) std.mem.doNotOptimizeAway(i);
    return i;
}

fn selfTest(_: void, io: Io) !void {
    try testing.expectEqual(@as(u64, 1000), try spin(counted(io), 1000));
    try testing.expectEqual(@as(u64, 1000), points());
    try expectCanceled(io, 500, 0, spin, .{1000});
    // A loop that ends before the point asked for, and one with none.
    try testing.expectError(error.TestUnexpectedResult, expectCanceled(io, 2000, 0, spin, .{1000}));
    try testing.expectError(error.TestUnexpectedResult, expectCanceled(io, 1, 0, spinNoPoints, .{1000}));
}

test "a loop with a point per step is canceled at the step asked for, and one that ends first or has no point fails, on each backend" {
    try eachBackend({}, selfTest);
}
