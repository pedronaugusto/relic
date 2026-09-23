//! What a long operation says while it runs.
//!
//! A fetch or a push can take minutes, and the caller — a terminal, a
//! daemon with a status line, an editor with a progress bar — decides what
//! to show. relic hands it events and prints nothing itself. A caller that
//! passes no `Progress` hears nothing and loses nothing.

const std = @import("std");

/// Something worth telling the caller.
pub const Event = union(enum) {
    /// A line of text the other side sent on the side-band's progress
    /// channel, as it arrived: `Counting objects: 100% (5/5), done.\r` and
    /// the like. It is the remote's text and may hold anything; a caller
    /// showing it to a person should treat it as untrusted.
    remote: []const u8,
    /// Bytes of a pack received so far.
    received: u64,
    /// Objects of a received pack read and named, of how many.
    indexed: Count,
    /// Delta objects resolved, of how many.
    resolved: Count,
    /// Objects written into a pack being sent, of how many.
    written: Count,
};

/// How far along: `done` of `total`.
pub const Count = struct {
    done: u64,
    total: u64,
};

/// Where events go.
pub const Progress = struct {
    context: ?*anyopaque = null,
    /// Called on the caller's own task, between two steps of the
    /// operation; whatever it does delays the operation by that much.
    report: *const fn (context: ?*anyopaque, event: Event) void,

    /// Hand `event` to the caller, when there is one to hand it to.
    pub fn emit(progress: ?Progress, event: Event) void {
        const p = progress orelse return;
        p.report(p.context, event);
    }
};

test "no progress is heard and nothing breaks" {
    Progress.emit(null, .{ .received = 1 });
    var seen: u64 = 0;
    const p: Progress = .{ .context = &seen, .report = struct {
        fn report(context: ?*anyopaque, event: Event) void {
            const count: *u64 = @ptrCast(@alignCast(context.?));
            count.* += event.received;
        }
    }.report };
    Progress.emit(p, .{ .received = 41 });
    Progress.emit(p, .{ .received = 1 });
    try std.testing.expectEqual(@as(u64, 42), seen);
}
