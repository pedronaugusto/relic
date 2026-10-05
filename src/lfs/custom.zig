//! Custom transfer adapters: `lfs.customtransfer.<name>`, the programs
//! git-lfs hands its transfers to, one line of JSON each way.
//!
//! An adapter is a `path` run through the shell with its `args`, as git-lfs
//! runs it; `concurrent` (true unless set) starts `lfs.concurrenttransfers`
//! of them, all at once, and false one; `direction` says whether it
//! downloads, uploads or both. Each process is told `init` — the
//! operation, the remote, `concurrent` and `concurrenttransfers` — and
//! answers `{}` or an error; then it is handed transfers one at a time,
//! each an `upload` with the object's path in the store or a `download`,
//! with the batch API's action, or `null` for a standalone agent; it
//! answers `progress` lines and one `complete`, which for a download names
//! the file it wrote, checked here against the object's name before it is
//! taken into the store. `terminate` ends it. The messages are written as
//! git-lfs's Go writes them, field for field.
//!
//! An adapter is used when the batch API's answer names it, the adapters
//! being offered in the batch request, or with no API at all when
//! `lfs.<url>.standalonetransferagent` (or `lfs.standalonetransferagent`)
//! names it.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("../config.zig");
const program = @import("../repo/program.zig");
const connection = @import("../transport/connection.zig");
const lfsapi = @import("api.zig");

/// Errors from an adapter's process.
pub const Error = error{
    /// The process ended, or said something that is not the protocol: a
    /// line that is not JSON, an event it may not send there, another
    /// object's name.
    LfsAdapterProtocolError,
    /// The process answered `init` with an error: git-lfs's "error
    /// initializing custom adapter". `Agent.message` holds it.
    LfsAdapterInitFailed,
} || connection.Error || program.Error;

/// Which way an adapter moves objects.
pub const Direction = enum {
    both,
    download,
    upload,
    /// A `direction` git-lfs does not know: the adapter moves nothing.
    neither,

    fn parse(text: []const u8) Direction {
        if (text.len == 0 or std.ascii.eqlIgnoreCase(text, "both")) return .both;
        if (std.ascii.eqlIgnoreCase(text, "download")) return .download;
        if (std.ascii.eqlIgnoreCase(text, "upload")) return .upload;
        return .neither;
    }
};

/// A configured adapter.
pub const Adapter = struct {
    name: []const u8,
    path: []const u8,
    args: []const u8 = "",
    concurrent: bool = true,
    direction: Direction = .both,

    /// Whether it moves objects in `operation`'s direction.
    pub fn moves(a: Adapter, operation: lfsapi.Operation) bool {
        return switch (a.direction) {
            .both => true,
            .neither => false,
            .download => operation == .download,
            .upload => operation == .upload,
        };
    }
};

/// The adapters `config` names with an `lfs.customtransfer.<name>.path`,
/// in the order they are first named. Every string is `arena`'s.
pub fn configured(arena: Allocator, config: *const config_mod.Config) (Allocator.Error || error{MalformedValue})![]const Adapter {
    var out: std.ArrayList(Adapter) = .empty;
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "lfs")) continue;
        if (!std.ascii.eqlIgnoreCase(entry.name, "path")) continue;
        if (entry.subsection.len <= "customtransfer.".len) continue;
        if (!std.ascii.eqlIgnoreCase(entry.subsection[0.."customtransfer.".len], "customtransfer.")) continue;
        const name = entry.subsection["customtransfer.".len..];
        if (std.mem.findScalar(u8, name, '.') != null) continue;
        const seen = for (out.items) |a| {
            if (std.mem.eql(u8, a.name, name)) break true;
        } else false;
        if (seen) continue;
        var key_buf: [512]u8 = undefined;
        const value = struct {
            fn get(a: Allocator, c: *const config_mod.Config, buf: []u8, adapter: []const u8, field: []const u8) (Allocator.Error || error{MalformedValue})!?[]const u8 {
                const key = std.fmt.bufPrint(buf, "lfs.customtransfer.{s}.{s}", .{ adapter, field }) catch return null;
                const raw = c.get(key) orelse return null;
                return config_mod.unquote(a, raw) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.MalformedValue,
                };
            }
        }.get;
        const path = try value(arena, config, &key_buf, name, "path") orelse continue;
        const concurrent_key = std.fmt.bufPrint(&key_buf, "lfs.customtransfer.{s}.concurrent", .{name}) catch continue;
        const concurrent = config.getBool(concurrent_key, true) catch true;
        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .path = path,
            .args = try value(arena, config, &key_buf, name, "args") orelse "",
            .concurrent = concurrent,
            .direction = Direction.parse(try value(arena, config, &key_buf, name, "direction") orelse ""),
        });
    }
    return out.items;
}

/// The adapter named `name` that moves objects in `operation`'s direction.
pub fn find(adapters: []const Adapter, name: []const u8, operation: lfsapi.Operation) ?Adapter {
    for (adapters) |a| {
        if (std.mem.eql(u8, a.name, name) and a.moves(operation)) return a;
    }
    return null;
}

/// What a process is told first.
pub const Init = struct {
    operation: lfsapi.Operation,
    /// The remote's name, or the URL.
    remote: []const u8,
    concurrent: bool,
    concurrent_transfers: u32,
};

/// One transfer.
pub const Request = struct {
    operation: lfsapi.Operation,
    oid: []const u8,
    size: u64,
    /// An upload's file: the object in the store.
    path: ?[]const u8 = null,
    /// The batch API's action, or `null` for a standalone agent.
    action: ?Action = null,
};

/// An action, as the agent is handed it.
pub const Action = struct {
    href: []const u8,
    /// Sorted by name when written, as Go writes a map.
    header: []const Header = &.{},
    /// As the server gave it; Go writes its zero time when there was none.
    expires_at: ?[]const u8 = null,
    expires_in: i64 = 0,

    pub const Header = struct { name: []const u8, value: []const u8 };
};

/// How a transfer ended.
pub const Completion = union(enum) {
    /// An upload took, or a download is in the file named, which is the
    /// caller's now.
    done: ?[]const u8,
    /// The agent's error: its code and message.
    failed: struct { code: i64, message: []const u8 },
};

/// One adapter process.
pub const Agent = struct {
    gpa: Allocator,
    io: Io,
    conn: *connection.Connection,
    line: Io.Writer.Allocating,
    arena_state: std.heap.ArenaAllocator,

    /// Start `adapter` in `cwd` and tell it `init`.
    pub fn start(gpa: Allocator, io: Io, programs: program.Programs, cwd: ?[]const u8, adapter: Adapter, init: Init) Self.Error!*Agent {
        // git-lfs's `FormatForShell(ShellQuoteSingle(path), args)`.
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(gpa);
        try command.append(gpa, '\'');
        for (adapter.path) |c| {
            if (c == '\'') try command.appendSlice(gpa, "'\\''") else try command.append(gpa, c);
        }
        try command.append(gpa, '\'');
        if (adapter.args.len != 0) {
            try command.append(gpa, ' ');
            try command.appendSlice(gpa, adapter.args);
        }
        const conn = try connection.Process.start(gpa, io, programs, .{
            .argv = &.{command.items},
            .shell = true,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .stderr = .capture,
        });
        const a = gpa.create(Agent) catch |err| {
            conn.close(io);
            return err;
        };
        a.* = .{ .gpa = gpa, .io = io, .conn = conn, .line = .init(gpa), .arena_state = .init(gpa) };
        errdefer a.abort();
        var msg: Io.Writer.Allocating = .init(gpa);
        defer msg.deinit();
        const w = &msg.writer;
        w.writeAll("{\"event\":\"init\",\"operation\":") catch return error.OutOfMemory;
        writeString(w, @tagName(init.operation)) catch return error.OutOfMemory;
        w.writeAll(",\"remote\":") catch return error.OutOfMemory;
        writeString(w, init.remote) catch return error.OutOfMemory;
        w.print(",\"concurrent\":{},\"concurrenttransfers\":{d}}}\n", .{ init.concurrent, init.concurrent_transfers }) catch return error.OutOfMemory;
        try a.send(msg.written());
        const answer = try a.receive();
        if (answer.@"error") |e| {
            a.conn.setMessage(e.message);
            return error.LfsAdapterInitFailed;
        }
        return a;
    }

    /// What the agent said last about a failure.
    pub fn message(a: *const Agent) []const u8 {
        return a.conn.message();
    }

    /// Hand the agent one transfer and wait for it to end. `progress` hears
    /// each `bytesSinceLast`.
    pub fn transfer(a: *Agent, request: Request, progress: anytype) Self.Error!Completion {
        var msg: Io.Writer.Allocating = .init(a.gpa);
        defer msg.deinit();
        writeRequest(&msg.writer, request) catch return error.OutOfMemory;
        try a.send(msg.written());
        while (true) {
            const answer = try a.receive();
            if (!std.mem.eql(u8, answer.oid, request.oid)) return error.LfsAdapterProtocolError;
            if (std.mem.eql(u8, answer.event, "progress")) {
                if (answer.bytesSinceLast > 0) progress.bytes(@intCast(answer.bytesSinceLast)); // safe: positive, checked just above
                continue;
            }
            if (!std.mem.eql(u8, answer.event, "complete")) return error.LfsAdapterProtocolError;
            if (answer.@"error") |e| return .{ .failed = .{ .code = e.code, .message = try a.arena_state.allocator().dupe(u8, e.message) } };
            return .{ .done = if (answer.path.len == 0) null else try a.arena_state.allocator().dupe(u8, answer.path) };
        }
    }

    /// `terminate`, and the process waited for.
    pub fn stop(a: *Agent) void {
        // ziglint-ignore: Z026 terminate is a courtesy; abort, next, ends the agent whether or not it heard it
        a.send("{\"event\":\"terminate\"}\n") catch {};
        a.abort();
    }

    fn abort(a: *Agent) void {
        a.conn.close(a.io);
        a.line.deinit();
        a.arena_state.deinit();
        a.gpa.destroy(a);
    }

    fn send(a: *Agent, text: []const u8) Error!void {
        const w = try a.conn.request();
        w.writeAll(text) catch return a.conn.failure();
        w.flush() catch return a.conn.failure();
    }

    const Answer = struct {
        event: []const u8 = "",
        @"error": ?struct { code: i64 = 0, message: []const u8 = "" } = null,
        oid: []const u8 = "",
        path: []const u8 = "",
        bytesSoFar: i64 = 0,
        bytesSinceLast: i64 = 0,
    };

    fn receive(a: *Agent) Error!Answer {
        const r = try a.conn.advertisement();
        a.line.clearRetainingCapacity();
        _ = r.streamDelimiterEnding(&a.line.writer, '\n') catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return a.conn.failure(),
        };
        if (r.bufferedLen() == 0) {
            const ended = connection.Process.diagnose(a.conn, a.io) catch return error.Canceled;
            const said = std.mem.trim(u8, ended.stderr, " \t\r\n");
            if (said.len != 0) a.conn.setMessage(said);
            return error.LfsAdapterProtocolError;
        }
        r.toss(1);
        return std.json.parseFromSliceLeaky(Answer, a.arena_state.allocator(), a.line.written(), .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LfsAdapterProtocolError,
        };
    }
};

/// A transfer request as git-lfs's `customAdapterTransferRequest` is
/// marshalled: `event`, `oid`, `size`, `path` when there is one, `action`.
pub fn writeRequest(w: *Io.Writer, request: Request) Io.Writer.Error!void {
    try w.writeAll("{\"event\":");
    try writeString(w, @tagName(request.operation));
    try w.writeAll(",\"oid\":");
    try writeString(w, request.oid);
    try w.print(",\"size\":{d}", .{request.size});
    if (request.path) |p| if (p.len != 0) {
        try w.writeAll(",\"path\":");
        try writeString(w, p);
    };
    try w.writeAll(",\"action\":");
    if (request.action) |a| {
        try w.writeAll("{\"href\":");
        try writeString(w, a.href);
        if (a.header.len != 0) {
            try w.writeAll(",\"header\":{");
            // Go writes a map's keys in order.
            var order: [64]usize = undefined;
            const n = @min(a.header.len, order.len);
            for (0..n) |i| order[i] = i;
            std.mem.sort(usize, order[0..n], a.header, struct {
                fn lessThan(headers: []const Action.Header, x: usize, y: usize) bool {
                    return std.mem.order(u8, headers[x].name, headers[y].name) == .lt;
                }
            }.lessThan);
            for (order[0..n], 0..) |i, k| {
                if (k != 0) try w.writeByte(',');
                try writeString(w, a.header[i].name);
                try w.writeByte(':');
                try writeString(w, a.header[i].value);
            }
            try w.writeByte('}');
        }
        try w.writeAll(",\"expires_at\":");
        try writeString(w, a.expires_at orelse "0001-01-01T00:00:00Z");
        if (a.expires_in != 0) try w.print(",\"expires_in\":{d}", .{a.expires_in});
        try w.writeByte('}');
    } else try w.writeAll("null");
    try w.writeAll("}\n");
}

/// A string as Go's `encoding/json` writes it: `<`, `>` and `&` escaped
/// for HTML, `\b`, `\f`, `\n`, `\r`, `\t` by name and other control bytes
/// as `\u00XX`, U+2028 and U+2029 escaped, and a byte that is not UTF-8 as
/// U+FFFD.
pub fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                '<', '>', '&' => try w.print("\\u00{x:0>2}", .{c}),
                else => if (c < 0x20) try w.print("\\u00{x:0>2}", .{c}) else try w.writeByte(c),
            }
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            try w.writeAll("\\ufffd");
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            try w.writeAll("\\ufffd");
            i += 1;
            continue;
        }
        const view = std.unicode.Utf8View.init(s[i .. i + len]) catch {
            try w.writeAll("\\ufffd");
            i += 1;
            continue;
        };
        var it = view.iterator();
        const cp = it.nextCodepoint().?; // the view holds one whole sequence
        if (cp == 0x2028 or cp == 0x2029) try w.print("\\u{x}", .{cp}) else try w.writeAll(s[i .. i + len]);
        i += len;
    }
    try w.writeByte('"');
}

test "messages are written as git-lfs's Go writes them" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRequest(&out.writer, .{ .operation = .upload, .oid = "ab", .size = 3, .path = "/s/o", .action = .{
        .href = "https://x/a?b=1&c=<d>",
        .header = &.{ .{ .name = "Z", .value = "1" }, .{ .name = "A", .value = "2" } },
        .expires_in = 60,
    } });
    try std.testing.expectEqualStrings(
        "{\"event\":\"upload\",\"oid\":\"ab\",\"size\":3,\"path\":\"/s/o\",\"action\":{\"href\":\"https://x/a?b=1\\u0026c=\\u003cd\\u003e\",\"header\":{\"A\":\"2\",\"Z\":\"1\"},\"expires_at\":\"0001-01-01T00:00:00Z\",\"expires_in\":60}}\n",
        out.written(),
    );
    out.clearRetainingCapacity();
    try writeRequest(&out.writer, .{ .operation = .download, .oid = "cd", .size = 0 });
    try std.testing.expectEqualStrings("{\"event\":\"download\",\"oid\":\"cd\",\"size\":0,\"action\":null}\n", out.written());
    out.clearRetainingCapacity();
    try writeString(&out.writer, "a\x01\x08\xff\u{2028}é");
    try std.testing.expectEqualStrings("\"a\\u0001\\b\\ufffd\\u2028é\"", out.written());
}

test "adapters are read from lfs.customtransfer, their direction and concurrency as git-lfs reads them" {
    var config = try config_mod.Config.parseText(std.testing.allocator,
        \\[lfs "customtransfer.nfs"]
        \\    path = /bin/nfs-agent
        \\    args = --fast
        \\    concurrent = false
        \\    direction = Download
        \\[lfs "customtransfer.odd"]
        \\    path = odd
        \\    direction = sideways
        \\[lfs "customtransfer.a.b"]
        \\    path = ignored
    , .local);
    defer config.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const adapters = try configured(arena.allocator(), &config);
    try std.testing.expectEqual(@as(usize, 2), adapters.len);
    try std.testing.expectEqualStrings("nfs", adapters[0].name);
    try std.testing.expectEqualStrings("--fast", adapters[0].args);
    try std.testing.expect(!adapters[0].concurrent);
    try std.testing.expect(find(adapters, "nfs", .download) != null);
    try std.testing.expect(find(adapters, "nfs", .upload) == null);
    try std.testing.expect(find(adapters, "odd", .download) == null);
}
