//! Relic's process handle. Native state stays opaque; Term is conduit's
//! portable exit result, shared throughout the family.
const std = @import("std");
const conduit = @import("conduit");
const Native = conduit.Child;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Child = struct {
    _state: *anyopaque,

    pub const Term = conduit.Term;
    pub const SpawnOptions = Native.SpawnOptions;
    pub const SpawnError = Native.SpawnError;
    pub const WaitError = Native.WaitError;
    pub const KillWaitError = Native.KillWaitError;
    pub const OutputError = Native.OutputError;
    pub const ExchangeError = Native.ExchangeError;
    pub const Error = SpawnError || WaitError || KillWaitError || OutputError || ExchangeError;

    fn native(child: Child) Native {
        return .{ .state = @ptrCast(@alignCast(child._state)) };
    }

    pub fn spawn(gpa: Allocator, io: Io, options: SpawnOptions) SpawnError!Child {
        const child = try Native.spawn(gpa, io, options);
        return .{ ._state = child.state };
    }

    pub fn deinit(child: *Child, io: Io) void {
        var n = child.native();
        n.deinit(io);
        child.* = undefined;
    }

    pub fn closeStdin(child: *Child, io: Io) void {
        var n = child.native();
        n.closeStdin(io);
    }

    pub fn wait(child: *Child, io: Io) WaitError!Term {
        var n = child.native();
        return n.wait(io);
    }

    pub fn killWait(child: *Child, io: Io, grace: Io.Duration) KillWaitError!Term {
        var n = child.native();
        return n.killWait(io, grace);
    }

    pub fn processId(child: *const Child) ?Native.Id {
        var n = child.native();
        return n.processId();
    }

    pub fn stdinFile(child: Child) ?Io.File {
        return child.native().stdinFile();
    }

    pub fn stdoutFile(child: Child) ?Io.File {
        return child.native().stdoutFile();
    }

    pub fn stderrFile(child: Child) ?Io.File {
        return child.native().stderrFile();
    }

    pub fn takeStdout(child: *Child) ?Io.File {
        var n = child.native();
        return n.takeStdout();
    }

    pub fn takeStderr(child: *Child) ?Io.File {
        var n = child.native();
        return n.takeStderr();
    }

    pub fn exchange(child: *Child, gpa: Allocator, io: Io, input: []const u8, options: Native.ExchangeOptions) ExchangeError!Native.Output {
        var n = child.native();
        return n.exchange(gpa, io, input, options);
    }
};
