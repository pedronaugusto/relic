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

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const program = @import("program.zig");
const pktline = @import("pktline.zig");

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
        advertisement: *const fn (context: *anyopaque, connection: *Connection) Error!*Io.Reader,
        /// Where the next request is written.
        request: *const fn (context: *anyopaque, connection: *Connection) Error!*Io.Writer,
        /// Send the request written so far and hand back its response.
        response: *const fn (context: *anyopaque, connection: *Connection) Error!*Io.Reader,
        /// Why the last read or write through this connection failed, when
        /// the reader or writer it handed out said only that it did.
        failure: *const fn (context: *anyopaque, connection: *Connection) Error,
        /// End the conversation and release everything. After a failure it
        /// is still called, and still releases everything.
        close: *const fn (context: *anyopaque, io: Io) void,
    };

    /// What the far side last said about a failure.
    pub fn message(c: *const Connection) []const u8 {
        return c.message_buffer[0..c.message_len];
    }

    /// Keep `text` as the failure's message, cut to fit.
    pub fn setMessage(c: *Connection, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        c.message_len = @min(trimmed.len, c.message_buffer.len);
        @memcpy(c.message_buffer[0..c.message_len], trimmed[0..c.message_len]);
    }

    /// The reader for the server's first message.
    pub fn advertisement(c: *Connection) Error!*Io.Reader {
        return c.vtable.advertisement(c.context, c);
    }

    /// The writer for the next request.
    pub fn request(c: *Connection) Error!*Io.Writer {
        return c.vtable.request(c.context, c);
    }

    /// Send the request and hand back the reader for its response.
    pub fn response(c: *Connection) Error!*Io.Reader {
        return c.vtable.response(c.context, c);
    }

    /// The specific error behind a `ReadFailed` or `WriteFailed`.
    pub fn failure(c: *Connection) Error {
        return c.vtable.failure(c.context, c);
    }

    /// End the conversation. The connection is released with it and is
    /// not used again.
    pub fn close(c: *Connection, io: Io) void {
        c.vtable.close(c.context, io);
    }

    /// Read one pkt-line, turning a transport failure into its own error
    /// and the end of the stream into `error.RemoteHungUp`.
    pub fn readPacket(c: *Connection, r: *Io.Reader) Error!pktline.Packet {
        return pktline.read(r) catch |err| switch (err) {
            error.BadPacket => error.ProtocolError,
            error.EndOfStream => error.RemoteHungUp,
            error.ReadFailed => c.failure(),
        };
    }

    /// Map a writer's failure to the connection's own error.
    pub fn writeFailed(c: *Connection, err: anyerror) Error {
        return switch (err) {
            error.PacketTooLong => error.ProtocolError,
            error.OutOfMemory => error.OutOfMemory,
            else => c.failure(),
        };
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
    io: Io,
    running: program.Running,
    read_buffer: []u8,
    write_buffer: []u8,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    connection: Connection,
    exited: bool = false,
    term: ?std.process.Child.Term = null,
    /// The captured standard error, when it is captured.
    stderr: ?*Tail = null,

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

        fn keep(tail: *Tail, bytes: []const u8) void {
            if (bytes.len >= tail.buffer.len) {
                @memcpy(&tail.buffer, bytes[bytes.len - tail.buffer.len ..]);
                tail.len = tail.buffer.len;
                return;
            }
            const room = tail.buffer.len - tail.len;
            if (bytes.len > room) {
                const drop = bytes.len - room;
                std.mem.copyForwards(u8, tail.buffer[0 .. tail.len - drop], tail.buffer[drop..tail.len]);
                tail.len -= drop;
            }
            @memcpy(tail.buffer[tail.len..][0..bytes.len], bytes);
            tail.len += bytes.len;
        }
    };

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .close = close,
    };

    /// Start `invocation` with its standard input and output as the
    /// conversation. The result is the caller's, released by closing its
    /// connection.
    pub fn start(
        gpa: Allocator,
        io: Io,
        programs: program.Programs,
        invocation: program.Invocation,
    ) (Error || program.Error)!*Connection {
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
        var running = try program.start(programs, gpa, io, effective);
        errdefer running.deinit(io);
        if (tail) |t| {
            const file = running.child.stderr.?;
            running.child.stderr = null;
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
            .io = io,
            .running = running,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .reader = running.child.stdout.?.readerStreaming(io, read_buffer),
            .writer = running.child.stdin.?.writerStreaming(io, write_buffer),
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
        const p: *Process = @ptrCast(@alignCast(context));
        return &p.reader.interface;
    }

    fn request(context: *anyopaque, _: *Connection) Error!*Io.Writer {
        const p: *Process = @ptrCast(@alignCast(context));
        return &p.writer.interface;
    }

    fn response(context: *anyopaque, c: *Connection) Error!*Io.Reader {
        const p: *Process = @ptrCast(@alignCast(context));
        p.writer.interface.flush() catch return failure(context, c);
        return &p.reader.interface;
    }

    fn failure(context: *anyopaque, c: *Connection) Error {
        const p: *Process = @ptrCast(@alignCast(context));
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

    fn close(context: *anyopaque, io: Io) void {
        const p: *Process = @ptrCast(@alignCast(context));
        if (!p.exited) {
            // The end of the conversation: the program's input ends, and so
            // does this side's interest in its output, so a program still
            // writing — after a refusal half way through a pack — stops at
            // a closed pipe rather than waiting on one nobody reads.
            p.writer.interface.flush() catch {};
            if (p.running.child.stdout) |stdout| {
                stdout.close(io);
                p.running.child.stdout = null;
            }
            p.exited = true;
            _ = p.running.wait(io) catch {};
        }
        if (p.stderr) |tail| {
            // Something the program started may still hold its standard
            // error open; the reading stops here either way.
            if (tail.task) |*task| task.cancel(io);
            if (tail.file) |file| file.close(io);
            p.gpa.destroy(tail);
        }
        p.running.deinit(io);
        p.gpa.free(p.read_buffer);
        p.gpa.free(p.write_buffer);
        p.gpa.destroy(p);
    }

    /// Close the program's input and wait for it: whether it succeeded.
    /// The connection stays open for `close`.
    pub fn finish(c: *Connection, io: Io) Error!void {
        const p: *Process = @ptrCast(@alignCast(c.context));
        if (p.exited) return;
        p.writer.interface.flush() catch {};
        p.exited = true;
        const term = p.running.wait(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
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
    pub fn diagnose(c: *Connection, io: Io) Io.Cancelable!struct { code: ?u8, stderr: []const u8 } {
        const p: *Process = @ptrCast(@alignCast(c.context));
        if (!p.exited) {
            p.exited = true;
            p.term = p.running.wait(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => null,
            };
        }
        var said: []const u8 = "";
        if (p.stderr) |tail| {
            // The program has ended, so its standard error is at its end
            // unless something it started still holds it.
            if (tail.task) |*task| task.await(io);
            said = tail.buffer[0..tail.len];
        }
        const code: ?u8 = if (p.term) |term| switch (term) {
            .exited => |value| value,
            else => null,
        } else null;
        return .{ .code = code, .stderr = said };
    }
};

test "the last of a program's standard error is what is kept" {
    var tail: Process.Tail = .{};
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
