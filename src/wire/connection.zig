//! A conversation with a remote git service: `git-upload-pack` for a fetch,
//! `git-receive-pack` for a push.
//!
//! Every transport comes down to three things: the first message the server
//! sends unprompted, a request the client writes, and the response the
//! server writes back. Over a pipe — `ssh`, or a service run on this machine
//! — the three are one stream in each direction and the server remembers
//! the conversation. Over HTTP each request is a separate `POST` and the
//! server remembers nothing, which is what `stateless` says, and the
//! protocol above writes each request whole for that reason. Nothing above
//! this interface knows which it is talking to.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const program = @import("../process/program.zig");
const warning = @import("../report/warning.zig");
const pktline = @import("../codec/pktline.zig");
const progress = @import("../report/progress.zig");

/// Which service is asked for.
pub const Service = enum {
    upload_pack,
    receive_pack,

    /// The program's name, which is also what the HTTP path and the
    /// `service` parameter carry.
    pub fn name(service: Service) []const u8 {
        return switch (service) {
            .upload_pack => "git-upload-pack",
            .receive_pack => "git-receive-pack",
        };
    }
};

/// Errors from a conversation with a remote service.
pub const Error = error{
    /// The server closed the conversation before the message was over.
    RemoteHungUp,
    /// The server wrote something that is not the protocol: a length that
    /// is not one, a line where a flush belongs.
    ProtocolError,
    /// The server's own words, `ERR <message>`, in place of an answer.
    /// `Connection.message` holds them.
    RemoteError,
    /// Reading or writing the conversation failed below the protocol: a
    /// broken pipe, a reset connection. `Connection.message` may say more.
    ConnectionFailed,
    /// The program that carries the conversation — `ssh`, or the service
    /// itself — exited with a failure. `Connection.message` holds what it
    /// said, when it was captured.
    TransportProgramFailed,
} || Allocator.Error || Io.Cancelable;

/// A conversation, open.
pub const Connection = struct {
    pub const Error = ErrorNamespace.Error;

    context: *anyopaque,
    vtable: *const VTable,
    /// Whether the server forgets everything between two requests.
    stateless: bool,
    /// The last thing the far side said about a failure, for a message:
    /// an `ERR` line's text, a side-band's last words, an HTTP status.
    message_buffer: [256]u8 = undefined,
    message_len: usize = 0,

    /// What each transport supplies.
    pub const VTable = struct {
        /// The server's first message. Called once, first.
        advertisement: *const fn (context: *anyopaque, connection: *Connection) ErrorNamespace.Error!*Io.Reader,
        /// Where the next request is written.
        request: *const fn (context: *anyopaque, connection: *Connection) ErrorNamespace.Error!*Io.Writer,
        /// Send the request written so far and hand back its response.
        response: *const fn (context: *anyopaque, connection: *Connection) ErrorNamespace.Error!*Io.Reader,
        /// Why the last read or write through this connection failed, when
        /// the reader or writer it handed out said only that it did.
        failure: *const fn (context: *anyopaque, connection: *Connection) ErrorNamespace.Error,
        /// End the conversation and release everything. After a failure it
        /// is still called, and still releases everything.
        close: *const fn (io: Io, context: *anyopaque) void,
    };

    /// What the far side last said about a failure.
    pub fn message(c: *const Connection) []const u8 {
        return c.message_buffer[0..c.message_len];
    }

    /// Keep `text` as the failure's message, cut to fit.
    pub fn setMessage(c: *Connection, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        // The other side's words, kept for a person to read: none of its
        // control characters is kept with them.
        c.message_len = progress.sanitize(trimmed, .none, &c.message_buffer).written;
    }

    /// The reader for the server's first message.
    pub fn advertisement(c: *Connection) Self.Error!*Io.Reader {
        return c.vtable.advertisement(c.context, c);
    }

    /// The writer for the next request.
    pub fn request(c: *Connection) Self.Error!*Io.Writer {
        return c.vtable.request(c.context, c);
    }

    /// Send the request and hand back the reader for its response.
    pub fn response(c: *Connection) Self.Error!*Io.Reader {
        return c.vtable.response(c.context, c);
    }

    /// The specific error behind a `ReadFailed` or `WriteFailed`.
    pub fn failure(c: *Connection) Self.Error {
        return c.vtable.failure(c.context, c);
    }

    /// End the conversation. The connection is released with it and is
    /// not used again.
    pub fn deinit(c: *Connection, io: Io) void {
        const context = c.context;
        const vtable = c.vtable;
        // Closing may free this connection's embedded storage.
        defer vtable.close(io, context);
        c.* = undefined;
    }

    /// Read one pkt-line, turning a transport failure into its own error
    /// and the end of the stream into `error.RemoteHungUp`.
    pub fn readPacket(c: *Connection, r: *Io.Reader) Self.Error!pktline.Packet {
        return pktline.read(r) catch |err| switch (err) {
            error.BadPacket => error.ProtocolError,
            error.EndOfStream => error.RemoteHungUp,
            error.ReadFailed => c.failure(),
        };
    }

    /// Map a writer's failure to the connection's own error.
    pub fn writeFailed(c: *Connection, err: anyerror) Self.Error {
        return switch (err) {
            error.PacketTooLong => error.ProtocolError,
            error.OutOfMemory => error.OutOfMemory,
            else => c.failure(),
        };
    }
};

/// The last four kilobytes a program wrote on its standard error, read by
/// a task beside the conversation.
const Tail = struct {
    buffer: [4096]u8 = undefined,
    len: usize = 0,
    task: ?Io.Future(void) = null,
    /// The read end, taken from the child, whose own clean-up would
    /// close it under the reading task.
    file: ?Io.File = null,

    /// Read the program's standard error to its end, keeping the last
    /// of it.
    fn drain(tail: *Tail, io: Io, file: Io.File) void {
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&chunk}) catch return;
            tail.keep(chunk[0..n]);
        }
    }

    /// Stop reading once the program has ended. All it wrote is in
    /// the pipe by then, but whatever it started may still hold the
    /// pipe open — an ssh ControlMaster, a credential daemon — and the
    /// reading task would wait for that to end too. So the task stops,
    /// and what it had not reached is read here, without waiting for
    /// more.
    fn finish(tail: *Tail, io: Io) void {
        if (tail.task) |*task| task.cancel(io);
        tail.task = null;
        const file = tail.file orelse return;
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = program.readAvailable(io, file, &chunk) catch return;
            if (n == 0) return;
            tail.keep(chunk[0..n]);
        }
    }

    fn keep(tail: *Tail, bytes: []const u8) void {
        if (bytes.len >= tail.buffer.len) {
            @memcpy(&tail.buffer, bytes[bytes.len - tail.buffer.len ..]);
            tail.len = tail.buffer.len;
            return;
        }
        const room = tail.buffer.len - tail.len;
        if (bytes.len > room) {
            const drop = bytes.len - room;
            @memmove(tail.buffer[0 .. tail.len - drop], tail.buffer[drop..tail.len]);
            tail.len -= drop;
        }
        @memcpy(tail.buffer[tail.len..][0..bytes.len], bytes);
        tail.len += bytes.len;
        assert(tail.len <= tail.buffer.len);
    }
};

/// A conversation over a program's standard input and output: `ssh`
/// running the service on another machine, or the service itself on this
/// one.
///
/// What the program says on its standard error — `Permission denied
/// (publickey).`, `ERROR: Repository not found.` — is, with
/// `Invocation.stderr = .capture`, read beside the conversation by a task
/// on the caller's `Io`, and its last four kilobytes kept for `diagnose`,
/// so a failure can say what the far side said rather than only that it
/// hung up. Where the caller's `Io` cannot run a second task, the program's
/// standard error is the caller's own instead, because an unread pipe is a
/// program that stops when it fills.
pub const Process = struct {
    gpa: Allocator,
    running: program.Running,
    read_buffer: []u8,
    write_buffer: []u8,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    connection: Connection,
    exited: bool = false,
    term: ?program.Term = null,
    /// A wait for the program was cancelled: the conversation is over
    /// for the caller, whatever the program is doing.
    wait_canceled: bool = false,
    /// The captured standard error, when it is captured.
    stderr: ?*Tail = null,
    /// Where what the program said goes when the conversation ends without
    /// `diagnose` having been asked: `warning.Warning.ssh_said`.
    said_to: ?*warning.Warnings = null,

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .close = close,
    };

    /// Errors from `start`.
    pub const StartError = Error || program.Error;

    /// Start `invocation` with its standard input and output as the
    /// conversation. The result is the caller's, released by closing its
    /// connection.
    pub fn start(
        gpa: Allocator,
        io: Io,
        programs: program.Programs,
        invocation: program.Invocation,
    ) StartError!*Connection {
        const p = try gpa.create(Process);
        errdefer gpa.destroy(p);
        const read_buffer = try gpa.alloc(u8, pktline.max_line + 4);
        errdefer gpa.free(read_buffer);
        const write_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(write_buffer);

        var effective = invocation;
        var tail: ?*Tail = null;
        errdefer if (tail) |t| gpa.destroy(t);
        if (invocation.stderr == .capture) {
            if (canRunBeside(io)) {
                tail = try gpa.create(Tail);
                tail.?.* = .{};
            } else effective.stderr = .inherit;
        }
        var running = try program.start(gpa, io, programs, effective);
        errdefer running.deinit(io);
        if (tail) |t| {
            const file = running.child.takeStderr().?;
            t.file = file;
            t.task = io.concurrent(Tail.drain, .{ t, io, file }) catch null;
            if (t.task == null) {
                // The probe said a task would run and none did: the pipe is
                // closed rather than left to fill.
                file.close(io);
                t.file = null;
            }
        }
        p.* = .{
            .gpa = gpa,
            .running = running,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .reader = running.child.stdoutFile().?.readerStreaming(io, read_buffer),
            .writer = running.child.stdinFile().?.writerStreaming(io, write_buffer),
            .connection = .{ .context = undefined, .vtable = &vtable, .stateless = false },
            .stderr = tail,
        };
        p.connection.context = p;
        return &p.connection;
    }

    /// Whether `io` runs a second task beside this one, asked by running an
    /// empty one.
    fn canRunBeside(io: Io) bool {
        var probe = io.concurrent(nothing, .{}) catch return false;
        probe.await(io);
        return true;
    }

    fn nothing() void {}

    fn advertisement(context: *anyopaque, _: *Connection) Error!*Io.Reader {
        const p: *Process = @ptrCast(@alignCast(context)); // safe: this vtable's context, a Process, from start
        return &p.reader.interface;
    }

    fn request(context: *anyopaque, _: *Connection) Error!*Io.Writer {
        const p: *Process = @ptrCast(@alignCast(context)); // safe: this vtable's context, a Process, from start
        return &p.writer.interface;
    }

    fn response(context: *anyopaque, c: *Connection) Error!*Io.Reader {
        const p: *Process = @ptrCast(@alignCast(context)); // safe: this vtable's context, a Process, from start
        p.writer.interface.flush() catch return failure(context, c);
        return &p.reader.interface;
    }

    /// Whether the conversation was cancelled: a read, a write or a wait
    /// of it answered `Canceled`.
    fn canceled(p: *const Process) bool {
        if (p.wait_canceled) return true;
        if (p.reader.err) |err| if (err == error.Canceled) return true;
        if (p.writer.err) |err| if (err == error.Canceled) return true;
        return false;
    }

    fn failure(context: *anyopaque, c: *Connection) Error {
        const p: *Process = @ptrCast(@alignCast(context)); // safe: this vtable's context, a Process, from start
        if (p.reader.err) |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
        if (p.writer.err) |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
        c.message_len = 0;
        return error.ConnectionFailed;
    }

    fn close(io: Io, context: *anyopaque) void {
        const p: *Process = @ptrCast(@alignCast(context)); // safe: this vtable's context, a Process, from start
        p.writer.io = io;
        if (!p.exited) {
            // The end of the conversation: the program's input ends, and so
            // does this side's interest in its output, so a program still
            // writing — after a refusal half way through a pack — stops at
            // a closed pipe rather than waiting on one nobody reads.
            // ziglint-ignore: Z026 a program that stopped reading has nothing more to hear; the pipe closes either way
            p.writer.interface.flush() catch {};
            if (p.running.child.takeStdout()) |stdout| stdout.close(io);
            p.exited = true;
            if (canceled(p)) {
                // cancelled: nobody is left for the program's answer, and
                // one that never ends — an ssh whose remote never answers —
                // would hold whoever cancelled until it did
                p.running.kill(io);
            } else {
                // ziglint-ignore: Z026 closing has no one to tell how the program ended; finish is where that is asked
                _ = p.running.wait(io) catch {};
            }
        }
        if (p.stderr) |tail| {
            tail.finish(io);
            if (tail.file) |file| file.close(io);
            if (p.said_to) |sink| {
                const said = std.mem.trim(u8, tail.buffer[0..tail.len], " \t\r\n");
                // ziglint-ignore: Z026 the program's words are a courtesy to the caller; losing them to a full allocator loses nothing else
                if (said.len != 0) sink.add(.{ .ssh_said = said }) catch {};
            }
            p.gpa.destroy(tail);
        }
        p.running.deinit(io);
        p.gpa.free(p.read_buffer);
        p.gpa.free(p.write_buffer);
        p.gpa.destroy(p);
    }

    /// The program behind `c`, or `null` when `c` is another transport's
    /// conversation: these three are public, and a connection is a
    /// `Process` only when it carries its vtable.
    fn of(c: *Connection) ?*Process {
        if (c.vtable != &vtable) return null;
        return @ptrCast(@alignCast(c.context)); // safe: the vtable is this type's, which only start installs, beside a Process
    }

    /// Borrow a native process's buffered streams for one exclusive operation.
    /// Buffer contents survive between operations, while reads and writes use
    /// this operation's Io. The caller serializes the entire borrow, including
    /// consumption of any returned bytes. A foreign transport is refused.
    pub fn streams(c: *Connection, io: Io) Self.Error!struct { reader: *Io.Reader, writer: *Io.Writer } {
        const p = of(c) orelse return error.ConnectionFailed;
        p.reader.io = io;
        p.writer.io = io;
        return .{ .reader = &p.reader.interface, .writer = &p.writer.interface };
    }

    /// Have what the program writes on its standard error handed to `sink`
    /// as `ssh_said` when the conversation ends well.
    pub fn sayTo(c: *Connection, sink: ?*warning.Warnings) void {
        const p = of(c) orelse return;
        p.said_to = sink;
    }

    /// Close the program's input and wait for it: whether it succeeded.
    /// The connection stays open for `close`.
    pub fn finish(c: *Connection, io: Io) Self.Error!void {
        const p = of(c) orelse return;
        if (p.exited) return;
        p.writer.io = io;
        // ziglint-ignore: Z026 a program that stopped reading has ended or will; its exit status, waited for next, is the answer
        p.writer.interface.flush() catch {};
        p.exited = true;
        const term = p.running.wait(io) catch |err| switch (err) {
            error.Canceled => {
                p.wait_canceled = true;
                return error.Canceled;
            },
            else => return error.TransportProgramFailed,
        };
        p.term = term;
        switch (term) {
            .exited => |code| if (code != 0) return error.TransportProgramFailed,
            else => return error.TransportProgramFailed,
        }
    }

    /// How a program that ended the conversation early ended: its exit
    /// code, `null` when it was killed or could not be waited for, and the
    /// last of what it wrote on its standard error, empty when that was not
    /// captured. The program's input is closed and it is waited for.
    pub fn diagnose(c: *Connection, io: Io) Io.Cancelable!struct { code: ?u32, stderr: []const u8 } {
        const p = of(c) orelse return .{ .code = null, .stderr = "" };
        // What it said is the failure's now, not a warning.
        p.said_to = null;
        if (!p.exited) {
            p.exited = true;
            if (canceled(p)) {
                // as `close`: a cancelled conversation's program is stopped
                p.running.kill(io);
                return error.Canceled;
            }
            p.term = p.running.wait(io) catch |err| switch (err) {
                error.Canceled => {
                    p.wait_canceled = true;
                    return error.Canceled;
                },
                else => null,
            };
        }
        var said: []const u8 = "";
        if (p.stderr) |tail| {
            tail.finish(io);
            said = tail.buffer[0..tail.len];
        }
        const code: ?u32 = if (p.term) |term| switch (term) {
            .exited => |value| value,
            else => null,
        } else null;
        return .{ .code = code, .stderr = said };
    }
};

test "the last of a program's standard error is what is kept" {
    var tail: Tail = .{};
    tail.keep("first line\n");
    try std.testing.expectEqualStrings("first line\n", tail.buffer[0..tail.len]);
    var big: [5000]u8 = undefined;
    @memset(&big, 'x');
    big[big.len - 1] = '!';
    tail.keep(&big);
    try std.testing.expectEqual(@as(usize, 4096), tail.len);
    try std.testing.expectEqual(@as(u8, '!'), tail.buffer[tail.len - 1]);
    tail.len = 4000;
    tail.keep("0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789");
    try std.testing.expectEqual(@as(usize, 4096), tail.len);
    try std.testing.expect(std.mem.endsWith(u8, tail.buffer[0..tail.len], "6789"));
}

test "a conversation that is not a program's is not read as one" {
    // Another transport's context, as large as a Process would be.
    var other: [@sizeOf(Process)]u8 align(@alignOf(Process)) = @splat(0xaa);
    const vtable: Connection.VTable = .{
        .advertisement = undefined,
        .request = undefined,
        .response = undefined,
        .failure = undefined,
        .close = undefined,
    };
    var c: Connection = .{ .context = &other, .vtable = &vtable, .stateless = false };
    try std.testing.expectError(error.ConnectionFailed, Process.streams(&c, std.testing.io));
    Process.sayTo(&c, null);
    for (other) |byte| try std.testing.expectEqual(0xaa, byte);
    try Process.finish(&c, std.testing.io);
    const ended = try Process.diagnose(&c, std.testing.io);
    try std.testing.expectEqual(null, ended.code);
    try std.testing.expectEqualStrings("", ended.stderr);
    for (other) |byte| try std.testing.expectEqual(0xaa, byte);
}
