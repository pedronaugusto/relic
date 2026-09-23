//! Sending to `git-receive-pack`: commands, a pack, and the report.
//!
//! A push is one request. Each ref to change is a command,
//! `<old> <new> <name>`, the first carrying the capabilities this side
//! wants after a NUL; `<old>` is what the pusher saw, so the server refuses
//! the update if the ref moved since, and a zero `<new>` deletes. Then,
//! when the server takes them, the push options, and then the pack of every
//! object the server lacks — streamed as it is written, never held whole.
//! The answer is the report: `unpack ok` or why not, and `ok <name>` or
//! `ng <name> <reason>` for each ref, carried on the side-band when there
//! is one, so the server's progress and its hooks' output come back beside
//! it. receive-pack speaks v0 and nothing else, whatever was asked for.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const pktline = @import("pktline.zig");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const sideband = @import("sideband.zig");
const progress_mod = @import("progress.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;

/// Errors from sending a push.
pub const Error = error{
    /// An atomic push to a server that cannot apply one.
    AtomicPushUnsupported,
    /// Push options for a server that does not take them.
    PushOptionsUnsupported,
    /// A deletion for a server that does not take them.
    DeleteRefsUnsupported,
    /// The report was not the report: a line that is neither `ok` nor `ng`,
    /// or the server's side-band error. `Connection.message` has its words
    /// when it gave any.
    ProtocolError,
    RemoteError,
} || protocol.Error || odb_mod.Error;

/// One ref to change.
pub const Command = struct {
    /// The ref on the remote.
    name: []const u8,
    /// Its value as advertised, or zero where it does not exist.
    old: Oid,
    /// Its new value, or zero to delete it.
    new: Oid,
};

/// What a push sends.
pub const Request = struct {
    commands: []const Command,
    /// The objects to send, already chosen: everything the new values
    /// reach that the remote does not have.
    objects: []const odb_mod.PackEntry,
    /// Apply every command or none.
    atomic: bool = false,
    /// `--push-option` values, for the server's hooks.
    push_options: []const []const u8 = &.{},
    progress: ?progress_mod.Progress = null,
};

/// What the server said about one ref.
pub const RefReport = struct {
    name: []const u8,
    ok: bool,
    /// The reason an `ng` gave.
    message: ?[]const u8 = null,
};

/// The server's answer.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    /// Whether the pack was taken: `unpack ok`.
    unpack_ok: bool,
    /// The reason when it was not.
    unpack_message: ?[]const u8,
    refs: []const RefReport,

    /// Release everything.
    pub fn deinit(report: *Report) void {
        report.arena.deinit();
        report.* = undefined;
    }

    /// The report for `name`, or `null` when the server said nothing of it.
    pub fn find(report: *const Report, name: []const u8) ?RefReport {
        for (report.refs) |ref| {
            if (std.mem.eql(u8, ref.name, name)) return ref;
        }
        return null;
    }
};

/// Send `request` over `conn`, whose advertisement is `adv`, with the
/// objects read from `db`.
pub fn send(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    adv: *const protocol.Advertisement,
    db: *odb_mod.Odb,
    request: Request,
) Error!Report {
    if (request.atomic and !adv.has("atomic")) return error.AtomicPushUnsupported;
    if (request.push_options.len != 0 and !adv.has("push-options")) return error.PushOptionsUnsupported;
    var needs_pack = false;
    for (request.commands) |command| {
        if (command.new.isZero()) {
            if (!adv.has("delete-refs")) return error.DeleteRefsUnsupported;
        } else needs_pack = true;
    }
    const band = adv.has("side-band-64k");
    const status_v2 = adv.has("report-status-v2");
    const status = status_v2 or adv.has("report-status");

    const w = try conn.request();
    writeCommands(w, adv, request, band, status_v2, status) catch |err| return conn.writeFailed(err);
    if (needs_pack) {
        _ = db.writePackTo(io, w, request.objects, .{
            .delta = if (adv.has("ofs-delta")) .offset else .reference,
        }) catch |err| switch (err) {
            error.WriteFailed => return conn.failure(),
            else => |e| return e,
        };
    }
    const in = try conn.response();

    var report: Report = .{ .arena = .init(gpa), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
    errdefer report.arena.deinit();
    // An old server with no report says nothing, and its silence is the
    // only answer there is.
    if (!status) return report;

    if (band) {
        const buffer = try gpa.alloc(u8, pktline.max_line + 4);
        defer gpa.free(buffer);
        var demux: sideband.Demux = .init(in, buffer, request.progress);
        readReport(gpa, &report, &demux.interface) catch |err| return mapBand(conn, &demux, err);
        // Whatever follows on the side-band — progress — runs to its flush.
        _ = demux.interface.discardRemaining() catch |err| return mapBand(conn, &demux, err);
    } else {
        readReport(gpa, &report, in) catch |err| switch (err) {
            error.ReadFailed => return conn.failure(),
            error.EndOfStream => return error.RemoteHungUp,
            else => |e| return e,
        };
    }
    return report;
}

fn writeCommands(
    w: *Io.Writer,
    adv: *const protocol.Advertisement,
    request: Request,
    band: bool,
    status_v2: bool,
    status: bool,
) pktline.WriteError!void {
    for (request.commands, 0..) |command, i| {
        if (i != 0) {
            try pktline.print(w, "{f} {f} {s}\n", .{ command.old, command.new, command.name });
            continue;
        }
        var caps_buffer: [256]u8 = undefined;
        var caps: Io.Writer = .fixed(&caps_buffer);
        if (status_v2) {
            try caps.writeAll(" report-status-v2");
        } else if (status) try caps.writeAll(" report-status");
        if (band) try caps.writeAll(" side-band-64k");
        if (request.atomic) try caps.writeAll(" atomic");
        if (request.push_options.len != 0) try caps.writeAll(" push-options");
        if (adv.has("object-format")) try caps.print(" object-format={s}", .{adv.kind.name()});
        if (adv.has("agent")) try caps.print(" agent={s}", .{protocol.agent});
        const list = std.mem.trimStart(u8, caps.buffered(), " ");
        try pktline.print(w, "{f} {f} {s}\x00{s}\n", .{ command.old, command.new, command.name, list });
    }
    try pktline.flush(w);
    if (request.push_options.len != 0) {
        for (request.push_options) |option| try pktline.print(w, "{s}\n", .{option});
        try pktline.flush(w);
    }
}

const ReportError = error{ ProtocolError, ReadFailed, EndOfStream } || Allocator.Error;

fn readReport(gpa: Allocator, report: *Report, r: *Io.Reader) ReportError!void {
    _ = gpa;
    const arena = report.arena.allocator();
    var refs: std.ArrayList(RefReport) = .empty;
    var first = true;
    while (true) {
        const packet = pktline.read(r) catch |err| switch (err) {
            error.BadPacket => return error.ProtocolError,
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return error.EndOfStream,
        };
        const line = switch (packet) {
            .flush => break,
            .data => |d| std.mem.trimEnd(u8, d, "\n"),
            else => return error.ProtocolError,
        };
        if (first) {
            first = false;
            if (!std.mem.startsWith(u8, line, "unpack ")) return error.ProtocolError;
            const what = line["unpack ".len..];
            if (!std.mem.eql(u8, what, "ok")) {
                report.unpack_ok = false;
                report.unpack_message = try arena.dupe(u8, what);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "ok ")) {
            try refs.append(arena, .{ .name = try arena.dupe(u8, line[3..]), .ok = true });
        } else if (std.mem.startsWith(u8, line, "ng ")) {
            const rest = line[3..];
            const space = std.mem.indexOfScalar(u8, rest, ' ');
            try refs.append(arena, .{
                .name = try arena.dupe(u8, rest[0 .. space orelse rest.len]),
                .ok = false,
                .message = if (space) |s| try arena.dupe(u8, rest[s + 1 ..]) else null,
            });
        } else if (std.mem.startsWith(u8, line, "option ")) {
            // report-status-v2 says more about the ref before it — what a
            // `proc-receive` hook made of it — which this side does not use.
        } else return error.ProtocolError;
    }
    if (first) return error.ProtocolError;
    report.refs = refs.items;
}

fn mapBand(conn: *Connection, demux: *sideband.Demux, err: ReportError) Error {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProtocolError => return error.ProtocolError,
        else => {},
    }
    const why = demux.err orelse return if (err == error.EndOfStream) error.RemoteHungUp else conn.failure();
    return switch (why) {
        error.RemoteError => {
            conn.setMessage(demux.message());
            return error.RemoteError;
        },
        error.BadSideband => error.ProtocolError,
        error.RemoteHungUp => error.RemoteHungUp,
        error.ReadFailed => conn.failure(),
    };
}

const testing = std.testing;

test "a report reads its refs, their reasons and a failed unpack" {
    const gpa = testing.allocator;
    var wire: Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    try pktline.write(&wire.writer, "unpack ok\n");
    try pktline.write(&wire.writer, "ok refs/heads/main\n");
    try pktline.write(&wire.writer, "ng refs/heads/side non-fast-forward\n");
    try pktline.write(&wire.writer, "option refname refs/heads/side\n");
    try pktline.flush(&wire.writer);
    var buffer: [pktline.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(wire.written());
    var in = fixed.limited(.unlimited, &buffer);
    var report: Report = .{ .arena = .init(gpa), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
    defer report.deinit();
    try readReport(gpa, &report, &in.interface);
    try testing.expect(report.find("refs/heads/main").?.ok);
    try testing.expectEqualStrings("non-fast-forward", report.find("refs/heads/side").?.message.?);
}

test "fuzz: any report is a report or a named error" {
    try testing.fuzz({}, fuzzReport, .{});
}

fn fuzzReport(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var buffer: [pktline.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(input);
    var in = fixed.limited(.unlimited, &buffer);
    var report: Report = .{ .arena = .init(testing.allocator), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
    defer report.deinit();
    readReport(testing.allocator, &report, &in.interface) catch return;
}
