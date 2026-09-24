//! git-lfs's pure-ssh protocol: `ssh <host> git-lfs-transfer <path>
//! <operation>`, and the objects and locks it moves without HTTP.
//!
//! The server speaks first, with its capabilities in pkt-lines ended by a
//! flush; `version=1` has to be among them, and the client answers
//! `version 1` and reads `status 200`. From then on every request is a
//! command line, its `key=value` arguments, and for some a delimiter and
//! lines or data, ended by a flush; every answer is a `status <code>` line,
//! arguments, and for some a delimiter and lines or data, ended by a flush.
//! `quit` ends the conversation. Text lines end in a newline, which is
//! taken off; data is sent as it is.
//!
//! git-lfs runs one connection per transfer worker, each started when its
//! worker first needs it, the batch requests and locks on the first. With
//! OpenSSH it asks the first to be a control master
//! (`-oControlMaster=yes -oControlPath=<dir>/lfs.sock`) and the rest to
//! share it (`-oControlMaster=no`), so one ssh session carries them all;
//! `Transfer` does the same with the two invocations `lfsapi` hands it, and
//! removes the directory the socket was in when it closes, which git-lfs
//! leaves behind.
//!
//! What ssh says on its standard error is kept beside the conversation, as
//! `connection.Process` keeps it, for the message when a connection does
//! not start.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const program = @import("program.zig");
const pktline = @import("pktline.zig");
const connection = @import("connection.zig");

/// Errors from the protocol.
pub const Error = error{
    /// The server wrote something that is not this protocol: no status
    /// line where one belongs, a status that is not a number, a delimiter
    /// twice.
    LfsSshProtocolError,
    /// The server does not offer `version=1`, or refused it.
    LfsSshVersionRefused,
} || connection.Error || program.Error;

/// One answer: its status, its arguments, and its lines.
pub const Status = struct {
    code: u16,
    args: []const []const u8,
    lines: []const []const u8,

    /// The value of the argument `key`, or `null`.
    pub fn arg(s: Status, key: []const u8) ?[]const u8 {
        return argValue(s.args, key);
    }

    /// Whether the status is a success.
    pub fn ok(s: Status) bool {
        return s.code >= 200 and s.code <= 299;
    }
};

/// The value of `key` among `key=value` arguments, or `null`.
pub fn argValue(args: []const []const u8, key: []const u8) ?[]const u8 {
    for (args) |a| {
        if (a.len > key.len and std.mem.startsWith(u8, a, key) and a[key.len] == '=') return a[key.len + 1 ..];
    }
    return null;
}

/// One conversation with `git-lfs-transfer`. It is used by one task at a
/// time: `mutex` is held for a request and its answer.
pub const Connection = struct {
    gpa: Allocator,
    io: Io,
    conn: *connection.Connection,
    reader: *Io.Reader,
    writer: *Io.Writer,
    mutex: Io.Mutex = .init,
    ended: bool = false,

    /// Start `invocation` and agree on version 1. A server that does not
    /// start, or does not speak it, is an error, and `message` holds what
    /// ssh said.
    pub fn start(gpa: Allocator, io: Io, programs: program.Programs, invocation: program.Invocation, message: *std.ArrayList(u8)) Error!*Connection {
        // `message` belongs to `gpa`.
        const conn = try connection.Process.start(gpa, io, programs, invocation);
        errdefer conn.close(io);
        const c = try gpa.create(Connection);
        errdefer gpa.destroy(c);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .conn = conn,
            .reader = try conn.advertisement(),
            .writer = try conn.request(),
        };
        c.negotiate() catch |err| {
            const said = connection.Process.diagnose(conn, io) catch |e| return e;
            message.clearRetainingCapacity();
            try message.appendSlice(gpa, std.mem.trim(u8, said.stderr, " \t\r\n"));
            return err;
        };
        return c;
    }

    fn negotiate(c: *Connection) Error!void {
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        var version = false;
        while (true) {
            switch (try c.conn.readPacket(c.reader)) {
                .flush => break,
                .data => |d| {
                    if (std.mem.eql(u8, text(d), "version=1")) version = true;
                },
                else => return error.LfsSshProtocolError,
            }
        }
        if (!version) return error.LfsSshVersionRefused;
        try c.send("version 1", &.{});
        const status = try c.readStatus(scratch.allocator());
        if (status.code != 200) return error.LfsSshVersionRefused;
    }

    /// Send `command` and its arguments.
    pub fn send(c: *Connection, command: []const u8, args: []const []const u8) Error!void {
        try c.writeHead(command, args);
        pktline.flush(c.writer) catch |err| return c.conn.writeFailed(err);
    }

    /// Send `command`, its arguments, a delimiter, and `lines`.
    pub fn sendLines(c: *Connection, command: []const u8, args: []const []const u8, lines: []const []const u8) Error!void {
        try c.writeHead(command, args);
        pktline.delim(c.writer) catch |err| return c.conn.writeFailed(err);
        for (lines) |line| pktline.print(c.writer, "{s}\n", .{line}) catch |err| return c.conn.writeFailed(err);
        pktline.flush(c.writer) catch |err| return c.conn.writeFailed(err);
    }

    /// Start `command` with its arguments and a delimiter; the data follows
    /// through `writeData` and ends with `endData`.
    pub fn beginData(c: *Connection, command: []const u8, args: []const []const u8) Error!void {
        try c.writeHead(command, args);
        pktline.delim(c.writer) catch |err| return c.conn.writeFailed(err);
    }

    /// A piece of data, in lines of at most `pktline.max_data` bytes.
    pub fn writeData(c: *Connection, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len != 0) {
            const n = @min(rest.len, pktline.max_data);
            pktline.write(c.writer, rest[0..n]) catch |err| return c.conn.writeFailed(err);
            rest = rest[n..];
        }
    }

    /// The end of the data.
    pub fn endData(c: *Connection) Error!void {
        pktline.flush(c.writer) catch |err| return c.conn.writeFailed(err);
    }

    fn writeHead(c: *Connection, command: []const u8, args: []const []const u8) Error!void {
        pktline.print(c.writer, "{s}\n", .{command}) catch |err| return c.conn.writeFailed(err);
        for (args) |a| pktline.print(c.writer, "{s}\n", .{a}) catch |err| return c.conn.writeFailed(err);
    }

    fn flushOut(c: *Connection) Error!void {
        _ = try c.conn.response();
    }

    /// Read an answer made of a status, arguments, and lines after a
    /// delimiter, to its flush. Everything is copied into `arena`.
    pub fn readStatus(c: *Connection, arena: Allocator) Error!Status {
        try c.flushOut();
        var args: std.ArrayList([]const u8) = .empty;
        var lines: std.ArrayList([]const u8) = .empty;
        var code: ?u16 = null;
        var delimited = false;
        while (true) {
            switch (try c.conn.readPacket(c.reader)) {
                .flush => return .{ .code = code orelse return error.LfsSshProtocolError, .args = args.items, .lines = lines.items },
                .delim => {
                    if (code == null or delimited) return error.LfsSshProtocolError;
                    delimited = true;
                },
                .response_end => return error.LfsSshProtocolError,
                .data => |d| {
                    const line = text(d);
                    if (code == null) {
                        code = parseStatus(line) orelse return error.LfsSshProtocolError;
                    } else if (delimited) {
                        try lines.append(arena, try arena.dupe(u8, line));
                    } else try args.append(arena, try arena.dupe(u8, line));
                },
            }
        }
    }

    /// Read the status and arguments of an answer that carries data after
    /// its delimiter; the data is then read with `nextData`.
    pub fn readStatusWithData(c: *Connection, arena: Allocator) Error!struct { code: u16, args: []const []const u8 } {
        try c.flushOut();
        var args: std.ArrayList([]const u8) = .empty;
        var code: ?u16 = null;
        while (true) {
            switch (try c.conn.readPacket(c.reader)) {
                .flush, .response_end => return error.LfsSshProtocolError,
                .delim => {
                    if (code == null) return error.LfsSshProtocolError;
                    return .{ .code = code.?, .args = args.items };
                },
                .data => |d| {
                    const line = text(d);
                    if (code == null) {
                        code = parseStatus(line) orelse return error.LfsSshProtocolError;
                    } else try args.append(arena, try arena.dupe(u8, line));
                },
            }
        }
    }

    /// The next piece of an answer's data, valid until the next read, or
    /// `null` at its end.
    pub fn nextData(c: *Connection) Error!?[]const u8 {
        return switch (try c.conn.readPacket(c.reader)) {
            .flush => null,
            .data => |d| d,
            else => error.LfsSshProtocolError,
        };
    }

    /// Read the rest of an answer's data and let it go.
    pub fn skipData(c: *Connection) Error!void {
        while (try c.nextData()) |_| {}
    }

    /// Say `quit`, read its answer, and close the connection. A connection
    /// that already failed is only closed.
    pub fn end(c: *Connection) void {
        if (!c.ended) {
            c.ended = true;
            var scratch: std.heap.ArenaAllocator = .init(c.gpa);
            defer scratch.deinit();
            if (c.send("quit", &.{})) {
                _ = c.readStatus(scratch.allocator()) catch {};
            } else |_| {}
        }
        c.conn.close(c.io);
        c.gpa.destroy(c);
    }
};

fn text(data: []const u8) []const u8 {
    return if (data.len != 0 and data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
}

fn parseStatus(line: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, line, "status ")) return null;
    return std.fmt.parseInt(u16, line["status ".len..], 10) catch null;
}

/// The connections of one operation to one remote.
pub const Transfer = struct {
    gpa: Allocator,
    io: Io,
    programs: program.Programs,
    /// How the first connection is started, and how every later one is.
    first: program.Invocation,
    rest: program.Invocation,
    /// The directory the control socket is in, removed on `close`.
    control_dir: ?[]const u8,
    arena: std.heap.ArenaAllocator,
    connections: std.ArrayList(?*Connection) = .empty,
    mutex: Io.Mutex = .init,
    /// What ssh said when a connection would not start.
    message: std.ArrayList(u8) = .empty,

    /// Start the first connection. `first`, `rest` and `control_dir` are
    /// copied. When it does not start, `failure` holds what ssh said.
    pub fn open(gpa: Allocator, io: Io, programs: program.Programs, first: program.Invocation, rest: program.Invocation, control_dir: ?[]const u8, failure: *std.ArrayList(u8)) Error!*Transfer {
        const t = try gpa.create(Transfer);
        errdefer gpa.destroy(t);
        t.* = .{
            .gpa = gpa,
            .io = io,
            .programs = programs,
            .first = undefined,
            .rest = undefined,
            .control_dir = null,
            .arena = .init(gpa),
        };
        errdefer t.arena.deinit();
        errdefer t.message.deinit(gpa);
        const a = t.arena.allocator();
        t.first = try copyInvocation(a, first);
        t.rest = try copyInvocation(a, rest);
        if (control_dir) |d| t.control_dir = try a.dupe(u8, d);
        errdefer t.removeControlDir();
        const c0 = try Connection.start(gpa, io, programs, t.first, failure);
        errdefer c0.end();
        try t.connections.append(gpa, c0);
        return t;
    }

    fn copyInvocation(a: Allocator, inv: program.Invocation) Allocator.Error!program.Invocation {
        var out = inv;
        const argv = try a.alloc([]const u8, inv.argv.len);
        for (inv.argv, argv) |from, *to| to.* = try a.dupe(u8, from);
        out.argv = argv;
        return out;
    }

    /// Connection `n`, started the first time it is asked for.
    pub fn connection(t: *Transfer, n: usize) Error!*Connection {
        try t.mutex.lock(t.io);
        defer t.mutex.unlock(t.io);
        while (t.connections.items.len <= n) try t.connections.append(t.gpa, null);
        if (t.connections.items[n]) |c| return c;
        const c = try Connection.start(t.gpa, t.io, t.programs, if (n == 0) t.first else t.rest, &t.message);
        t.connections.items[n] = c;
        return c;
    }

    /// Say `quit` on every connection, close them, and release everything.
    pub fn close(t: *Transfer) void {
        for (t.connections.items) |maybe| if (maybe) |c| c.end();
        t.connections.deinit(t.gpa);
        t.removeControlDir();
        t.message.deinit(t.gpa);
        t.arena.deinit();
        t.gpa.destroy(t);
    }

    fn removeControlDir(t: *Transfer) void {
        const dir = t.control_dir orelse return;
        Io.Dir.cwd().deleteTree(t.io, dir) catch {};
        t.control_dir = null;
    }
};

const testing = std.testing;

test "an answer's arguments are found by key" {
    const args = [_][]const u8{ "size=12", "id=", "token=a=b" };
    try testing.expectEqualStrings("12", argValue(&args, "size").?);
    try testing.expectEqualStrings("", argValue(&args, "id").?);
    try testing.expectEqualStrings("a=b", argValue(&args, "token").?);
    try testing.expect(argValue(&args, "siz") == null);
    try testing.expectEqual(@as(?u16, 404), parseStatus("status 404"));
    try testing.expect(parseStatus("status x") == null);
}
