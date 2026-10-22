//! A server in this process at the far end of a connection: the
//! receive-pack or upload-pack that a push or a fetch to a repository on
//! this machine talks to, as git runs its own for one.
//!
//! Each request is served on a task beside the client, the request and the
//! answer passing through bounded pipes, so a pack crosses as it is written
//! and is never held whole on either side. A server that stops reading
//! before the request ends has the rest of it taken and dropped, so the
//! client finishes writing and reads what the server answered, as it would
//! over a pipe to git. Where the caller's `Io` runs no second task, the
//! request is held whole and answered after it, which is the one way such
//! an `Io` can serve it.
//!
//! The advertisement is answered whole: it is read before anything is
//! written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pkt_line = @import("../codec.zig").pkt_line;
const connection = @import("../wire.zig").connection;
const local = @import("local.zig");

const Connection = connection.Connection;

/// How many bytes a pipe holds before its writer waits for its reader.
const pipe_bytes = 64 * 1024;

/// One direction of a request: what one side writes and the other reads.
const Pipe = struct {
    io: Io,
    queue: Io.Queue(u8),
    storage: [pipe_bytes]u8 = undefined,
    reader: Io.Reader,
    reader_buffer: [pkt_line.max_line]u8 = undefined,
    writer: Io.Writer,
    writer_buffer: [16 * 1024]u8 = undefined,
    /// The writing side failed: the reader ends with `ReadFailed`, not
    /// with the end of the stream, so a reader asks the connection why.
    failed: bool = false,
    /// A read or a write of it was canceled: the side that was is done
    /// with the request, and the other is stopped rather than waited for.
    canceled: bool = false,

    fn init(p: *Pipe, io: Io) void {
        p.* = .{
            .io = io,
            .queue = undefined,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &p.reader_buffer, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &p.writer_buffer },
        };
        p.queue = .init(&p.storage);
    }

    fn close(p: *Pipe) void {
        p.queue.close(p.io);
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const p: *Pipe = @alignCast(@fieldParentPtr("writer", w)); // safe: this function is installed only on a Pipe's writer
        try p.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try p.put(bytes);
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try p.put(last);
            n += last.len;
        }
        return n;
    }

    fn put(p: *Pipe, bytes: []const u8) Io.Writer.Error!void {
        p.queue.putAll(p.io, bytes) catch |err| switch (err) {
            error.Closed => return error.WriteFailed,
            error.Canceled => {
                p.canceled = true;
                return error.WriteFailed;
            },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const p: *Pipe = @alignCast(@fieldParentPtr("reader", r)); // safe: this function is installed only on a Pipe's reader
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = p.queue.get(p.io, dest, 1) catch |err| switch (err) {
            error.Closed => return if (p.failed) error.ReadFailed else error.EndOfStream,
            error.Canceled => {
                p.canceled = true;
                return error.ReadFailed;
            },
        };
        w.advance(n);
        return n;
    }

    /// Take what is written to the end and drop it.
    fn discard(p: *Pipe) void {
        var sink: [4096]u8 = undefined;
        while (true) {
            _ = p.queue.get(p.io, &sink, 1) catch return;
        }
    }
};

/// A connection to `Server` -- a receive-pack's or an upload-pack's
/// `Server` -- in this process. `told` names the errors the server has
/// already answered the client with, whose answer the client reads as it
/// is; any other error of the server's fails the connection, named in its
/// message.
pub fn InProcess(comptime Server: type, comptime told: fn (ServerError(Server)) bool) type {
    return struct {
        const Self = @This();
        const Failure = ServerError(Server);

        gpa: Allocator,
        io: Io,
        remote: *local.Remote,
        server: Server,
        connection: Connection,
        /// The advertisement, answered whole.
        advertised: Io.Writer.Allocating,
        fixed: Io.Reader = undefined,
        limited: Io.Reader.Limited = undefined,
        buffer: [pkt_line.max_line]u8 = undefined,
        /// The request under way, while there is one.
        exchange: ?*Exchange = null,

        const Exchange = struct {
            request: Pipe,
            response: Pipe,
            task: ?Io.Future(Failure!void) = null,
            /// What the server's task ended with, once it is awaited.
            outcome: ?(Failure!void) = null,
            /// Where no second task runs: the request held whole.
            whole: ?Whole = null,
        };

        const Whole = struct {
            request: Io.Writer.Allocating,
            response: Io.Writer.Allocating,
            request_fixed: Io.Reader = undefined,
            request_limited: Io.Reader.Limited = undefined,
            request_buffer: [pkt_line.max_line]u8 = undefined,
            response_fixed: Io.Reader = undefined,
            response_limited: Io.Reader.Limited = undefined,
            response_buffer: [pkt_line.max_line]u8 = undefined,
        };

        const vtable: Connection.VTable = .{
            .advertisement = advertisement,
            .request = request,
            .response = response,
            .failure = failure,
            .deinit = deinit,
        };

        /// A connection to `server`, serving `remote`, both of which it
        /// owns from here: `remote` is the caller's allocation, freed with
        /// the connection.
        pub fn create(gpa: Allocator, io: Io, remote: *local.Remote, server: Server) Allocator.Error!*Connection {
            const c = try gpa.create(Self);
            c.* = .{
                .gpa = gpa,
                .io = io,
                .remote = remote,
                .server = server,
                .advertised = .init(gpa),
                .connection = .{ .context = c, .vtable = &vtable, .stateless = true },
            };
            return &c.connection;
        }

        fn self(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context)); // safe: the context handed out with this vtable is this type
        }

        fn advertisement(context: *anyopaque, conn: *Connection) connection.Error!*Io.Reader {
            const c = self(context);
            c.advertised.clearRetainingCapacity();
            c.server.advertise(&c.advertised.writer) catch |err| return fail(conn, err);
            c.fixed = .fixed(c.advertised.written());
            c.limited = c.fixed.limited(.unlimited, &c.buffer);
            return &c.limited.interface;
        }

        fn request(context: *anyopaque, conn: *Connection) connection.Error!*Io.Writer {
            const c = self(context);
            try c.finish(conn);
            const x = try c.gpa.create(Exchange);
            x.* = .{ .request = undefined, .response = undefined };
            c.exchange = x;
            x.request.init(c.io);
            x.response.init(c.io);
            if (canRunBeside(c.io)) {
                if (c.io.concurrent(serve, .{ c, x })) |task| {
                    x.task = task;
                    return &x.request.writer;
                } else |_| {}
            }
            x.whole = .{ .request = .init(c.gpa), .response = .init(c.gpa) };
            return &x.whole.?.request.writer;
        }

        /// What the server's task does: the request served, its answer
        /// ended, and whatever is left of the request taken.
        fn serve(c: *Self, x: *Exchange) Failure!void {
            const served = c.server.serveRequest(&x.response.writer, &x.request.reader);
            if (served) |_| {
                x.response.writer.flush() catch {}; // glint-ignore: Z026 -- a client that stopped reading has its answer as far as it read; the request's own outcome is the one returned
            } else |err| if (!told(err)) {
                x.response.failed = true;
            } else {
                x.response.writer.flush() catch {}; // glint-ignore: Z026 -- as above
            }
            x.response.close();
            x.request.discard();
            return served;
        }

        fn response(context: *anyopaque, conn: *Connection) connection.Error!*Io.Reader {
            const c = self(context);
            const x = c.exchange orelse return error.ConnectionFailed;
            if (x.whole) |*whole| {
                whole.request_fixed = .fixed(whole.request.written());
                whole.request_limited = whole.request_fixed.limited(.unlimited, &whole.request_buffer);
                c.server.serveRequest(&whole.response.writer, &whole.request_limited.interface) catch |err| {
                    if (!told(err)) return fail(conn, err);
                };
                whole.response_fixed = .fixed(whole.response.written());
                whole.response_limited = whole.response_fixed.limited(.unlimited, &whole.response_buffer);
                return &whole.response_limited.interface;
            }
            // The request ends here; the server reads it to its end.
            x.request.writer.flush() catch return failure(c, conn);
            x.request.close();
            return &x.response.reader;
        }

        /// The request under way waited for to its end: the server's
        /// outcome, its failure in the connection's words.
        fn finish(c: *Self, conn: *Connection) connection.Error!void {
            const x = c.exchange orelse return;
            defer {
                c.release(x);
                c.exchange = null;
            }
            const outcome = c.awaitTask(x) orelse return;
            outcome catch |err| if (!told(err)) return fail(conn, err);
        }

        fn awaitTask(c: *Self, x: *Exchange) ?(Failure!void) {
            if (x.task) |*task| {
                // The client may stop before the end; the server is not
                // left waiting for a request that will not come.
                x.request.close();
                x.outcome = task.await(c.io);
                x.task = null;
            }
            return x.outcome;
        }

        fn release(c: *Self, x: *Exchange) void {
            if (x.task) |*task| {
                x.request.close();
                x.response.close();
                // glint-ignore: Z026 -- a connection let go does not answer for the request it abandoned
                task.cancel(c.io) catch {};
            }
            if (x.whole) |*whole| {
                whole.request.deinit();
                whole.response.deinit();
            }
            c.gpa.destroy(x);
        }

        fn fail(conn: *Connection, err: Failure) connection.Error {
            conn.setMessage(@errorName(err));
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => error.ConnectionFailed,
            };
        }

        /// Why the conversation stopped: the server's own failure, when
        /// that is what ended it.
        fn failure(context: *anyopaque, conn: *Connection) connection.Error {
            const c = self(context);
            const x = c.exchange orelse return error.ConnectionFailed;
            if (x.request.canceled or x.response.canceled) {
                // The client was canceled: so is the server's task.
                c.release(x);
                c.exchange = null;
                return error.Canceled;
            }
            const outcome = c.awaitTask(x) orelse return error.ConnectionFailed;
            outcome catch |err| if (!told(err)) return fail(conn, err);
            return error.ConnectionFailed;
        }

        fn deinit(io: Io, context: *anyopaque) void {
            const c = self(context);
            if (c.exchange) |x| c.release(x);
            c.advertised.deinit();
            if (@hasDecl(Server, "deinit")) c.server.deinit();
            c.remote.deinit(io);
            c.gpa.destroy(c.remote);
            c.gpa.destroy(c);
        }
    };
}

/// What `Server.serveRequest` fails with.
fn ServerError(comptime Server: type) type {
    const returned = @typeInfo(@TypeOf(Server.serveRequest)).@"fn".return_type.?;
    return @typeInfo(returned).error_union.error_set;
}

/// Whether `io` runs a second task beside this one, asked by running an
/// empty one.
fn canRunBeside(io: Io) bool {
    var probe = io.concurrent(nothing, .{}) catch return false;
    probe.await(io);
    return true;
}

fn nothing() void {}
