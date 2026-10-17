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

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const pkt_line = @import("../codec.zig").pkt_line;
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const side_band = @import("side_band.zig");
const progress_mod = @import("../report.zig").progress;

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
    /// This repository's shallow boundary, which the server is told before
    /// the commands, as git's send-pack tells it.
    shallow: []const Oid = &.{},
};

/// What the server said about one ref.
pub const RefReport = struct {
    name: []const u8,
    status: Status,
    /// The reason an `ng` or a remote helper's `error` gave, or what its
    /// `ok` added, when it is none of the words git reads as a status.
    message: ?[]const u8 = null,
    /// A remote helper's `forced update`.
    forced: bool = false,
    /// What a remote helper's `option` lines after its `ok` said each
    /// update was, in order: what moved its private ref.
    updates: []const Update = &.{},

    /// What became of the ref.
    pub const Status = enum {
        /// `ok`.
        ok,
        /// `ng`, or a remote helper's `error`: `message` says why.
        rejected,
        // A remote helper's reason, which git reads as the state it names.
        up_to_date,
        no_match,
        rejected_non_fast_forward,
        rejected_already_exists,
        rejected_fetch_first,
        rejected_needs_force,
        rejected_stale,
        rejected_remote_updated,
        expecting_report,
    };

    /// One update an `ok` stood for: report-status-v2's `option refname`,
    /// `old-oid`, `new-oid` and `forced-update`.
    pub const Update = struct {
        refname: ?[]const u8 = null,
        old: ?Oid = null,
        new: ?Oid = null,
        forced: bool = false,

        /// Take one `option <key> [<value>]` line's `<key> [<value>]`, as
        /// git's `receive_status` and the remote helper's reader take it:
        /// an object name is the first hex digits at `kind`'s length, what
        /// follows them passed over, and one that is not there leaves the
        /// field as it was; an unknown key is passed over. The name lives
        /// in `a`.
        pub fn take(update: *Update, a: Allocator, text: []const u8, kind: hash.Kind) Allocator.Error!void {
            const space = std.mem.findScalar(u8, text, ' ');
            const key = text[0 .. space orelse text.len];
            const value: ?[]const u8 = if (space) |sp| text[sp + 1 ..] else null;
            if (std.mem.eql(u8, key, "refname")) {
                update.refname = if (value) |v| try a.dupe(u8, v) else null;
            } else if (std.mem.eql(u8, key, "old-oid")) {
                if (oidAtStart(kind, value)) |oid| update.old = oid;
            } else if (std.mem.eql(u8, key, "new-oid")) {
                if (oidAtStart(kind, value)) |oid| update.new = oid;
            } else if (std.mem.eql(u8, key, "forced-update")) update.forced = true;
        }

        /// git's `parse_oid_hex_algop`: the object name the first hex
        /// digits spell, in either case, whatever follows.
        fn oidAtStart(kind: hash.Kind, text: ?[]const u8) ?Oid {
            const t = text orelse return null;
            if (t.len < kind.hexLen()) return null;
            return Oid.parse(kind, t[0..kind.hexLen()]) catch null;
        }
    };

    /// Whether the ref was taken.
    pub fn ok(r: RefReport) bool {
        return r.status == .ok;
    }
};

/// The server's answer.
pub const Report = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    /// Whether the pack was taken: `unpack ok`.
    unpack_ok: bool,
    /// The reason when it was not.
    unpack_message: ?[]const u8,
    refs: []const RefReport,
    /// The report had an `option` line with no `ok` before it, which git
    /// reports ("'option' without a matching 'ok/ng' directive") and reads
    /// on past: what the rest said is kept, and the push fails as git's
    /// does.
    stray_option: bool = false,

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

pub const Inputs = struct { advertisement: *const protocol.Advertisement, db: *odb_mod.Odb };

/// Send `request` over `conn`, whose advertisement is `inputs.advertisement`, with the
/// objects read from `db`.
pub fn send(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    inputs: Inputs,
    request: Request,
) Self.Error!Report {
    const adv = inputs.advertisement;
    const db = inputs.db;
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
    for (request.shallow) |oid| pkt_line.print("shallow {f}\n", .{oid}, w) catch |err| return conn.writeFailed(err);
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
        const buffer = try gpa.alloc(u8, pkt_line.max_line + 4);
        defer gpa.free(buffer);
        var demux: side_band.Demux = .init(in, buffer, request.progress);
        readReport(gpa, &report, &demux.interface, .{ .commands = request.commands, .kind = adv.kind }) catch |err| return mapBand(conn, &demux, err);
        // Whatever follows on the side-band — progress — runs to its flush.
        _ = demux.interface.discardRemaining() catch |err| return mapBand(conn, &demux, err);
    } else {
        readReport(gpa, &report, in, .{ .commands = request.commands, .kind = adv.kind }) catch |err| switch (err) {
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
) pkt_line.WriteError!void {
    // As git's send-pack writes them: no newline after a command, and the
    // capabilities after the NUL each with the space before it.
    for (request.commands, 0..) |command, i| {
        if (i != 0) {
            try pkt_line.print("{f} {f} {s}", .{ command.old, command.new, command.name }, w);
            continue;
        }
        var caps_buffer: [256]u8 = undefined;
        var caps: Io.Writer = .fixed(&caps_buffer);
        if (status_v2) {
            try caps.writeAll(" report-status-v2");
        } else if (status) try caps.writeAll(" report-status");
        if (band) try caps.writeAll(" side-band-64k");
        if (request.progress == null and adv.has("quiet")) try caps.writeAll(" quiet");
        if (request.atomic) try caps.writeAll(" atomic");
        if (request.push_options.len != 0) try caps.writeAll(" push-options");
        if (adv.has("object-format")) try caps.print(" object-format={s}", .{adv.kind.name()});
        if (adv.has("agent")) try caps.print(" agent={s}", .{protocol.agent});
        try pkt_line.print("{f} {f} {s}\x00{s}", .{ command.old, command.new, command.name, caps.buffered() }, w);
    }
    try pkt_line.flush(w);
    if (request.push_options.len != 0) {
        for (request.push_options) |option| try pkt_line.print("{s}", .{option}, w);
        try pkt_line.flush(w);
    }
}

const ReportError = error{ ProtocolError, ReadFailed, EndOfStream } || Allocator.Error;

/// What a report is read against: the commands sent, whose refs alone it
/// may speak of, and the object format its names are in.
const Against = struct { commands: []const Command, kind: hash.Kind };

/// git's `receive_status`: `unpack`, then an `ok` or `ng` per ref, each
/// line about a ref sent (another is passed over, as git warns of it), a
/// ref said twice keeping the last word; and after an `ok`, report-status-v2's
/// `option` lines, each run of them one update of that ref.
fn readReport(gpa: Allocator, report: *Report, r: *Io.Reader, against: Against) ReportError!void {
    _ = gpa;
    const arena = report.arena.allocator();
    var refs: std.ArrayList(RefReport) = .empty;
    var updates: std.ArrayList(std.ArrayList(RefReport.Update)) = .empty;
    // git's `hint`, `new_report` and `report`: the ref the last status was
    // about, whether its `ok` opens an update, and whether one is open.
    var hint: ?usize = null;
    var new_update = false;
    var update_open = false;
    var first = true;
    while (true) {
        const packet = pkt_line.read(r) catch |err| switch (err) {
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
        const space = std.mem.findScalar(u8, line, ' ') orelse return error.ProtocolError;
        const head = line[0..space];
        const rest = line[space + 1 ..];
        if (std.mem.eql(u8, head, "option")) {
            const at = hint orelse {
                report.stray_option = true;
                continue;
            };
            if (!new_update and !update_open) {
                report.stray_option = true;
                continue;
            }
            if (new_update) {
                try updates.items[at].append(arena, .{});
                new_update = false;
                update_open = true;
            }
            try updates.items[at].items[updates.items[at].items.len - 1].take(arena, rest, against.kind);
            continue;
        }
        new_update = false;
        update_open = false;
        const ok = std.mem.eql(u8, head, "ok");
        if (!ok and !std.mem.eql(u8, head, "ng")) return error.ProtocolError;
        const name_end = std.mem.findScalar(u8, rest, ' ');
        const name = rest[0 .. name_end orelse rest.len];
        const said: ?[]const u8 = if (name_end) |e| rest[e + 1 ..] else null;
        hint = for (refs.items, 0..) |ref, i| {
            if (std.mem.eql(u8, ref.name, name)) break i;
        } else for (against.commands) |command| {
            if (!std.mem.eql(u8, command.name, name)) continue;
            try refs.append(arena, .{ .name = try arena.dupe(u8, name), .status = .expecting_report });
            try updates.append(arena, .empty);
            break refs.items.len - 1;
        } else null;
        const ref = &refs.items[hint orelse continue];
        ref.status = if (ok) .ok else .rejected;
        // An `ng` with no reason is git's `failed`.
        ref.message = if (said) |text| try arena.dupe(u8, text) else if (ok) null else "failed";
        new_update = ok;
    }
    if (first) return error.ProtocolError;
    for (refs.items, updates.items) |*ref, made| ref.updates = made.items;
    report.refs = refs.items;
}

fn mapBand(conn: *Connection, demux: *side_band.Demux, err: ReportError) Error {
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
    try pkt_line.write(&wire.writer, "unpack ok\n");
    try pkt_line.write(&wire.writer, "ok refs/heads/main\n");
    try pkt_line.write(&wire.writer, "ng refs/heads/side non-fast-forward\n");
    try pkt_line.write(&wire.writer, "option refname refs/heads/side\n");
    try pkt_line.flush(&wire.writer);
    var buffer: [pkt_line.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(wire.written());
    var in = fixed.limited(.unlimited, &buffer);
    var report: Report = .{ .arena = .init(gpa), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
    defer report.deinit();
    const commands = [_]Command{
        .{ .name = "refs/heads/main", .old = .zero(.sha1), .new = .zero(.sha1) },
        .{ .name = "refs/heads/side", .old = .zero(.sha1), .new = .zero(.sha1) },
    };
    try readReport(gpa, &report, &in.interface, .{ .commands = &commands, .kind = .sha1 });
    try testing.expect(report.stray_option);
    try testing.expect(report.find("refs/heads/main").?.ok());
    try testing.expectEqualStrings("non-fast-forward", report.find("refs/heads/side").?.message.?);
}

test "fuzz: any report is a report or a named error" {
    try shakedown.check(testing.allocator, {}, fuzzReport, .{});
}

fn fuzzReport(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    var buffer: [pkt_line.max_line]u8 = undefined;
    var fixed: Io.Reader = .fixed(input);
    var in = fixed.limited(.unlimited, &buffer);
    var report: Report = .{ .arena = .init(testing.allocator), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
    defer report.deinit();
    const commands = [_]Command{.{ .name = "refs/heads/main", .old = .zero(.sha1), .new = .zero(.sha1) }};
    readReport(testing.allocator, &report, &in.interface, .{ .commands = &commands, .kind = .sha1 }) catch return;
}
