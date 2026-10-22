//! Asking a server for a pack: the `fetch` command of protocol v2, and the
//! `want`/`have` exchange of v0 and v1 when that is all the server speaks.
//!
//! The client names the objects it wants and then, round by round, commits
//! it has, newest first, until the server has seen enough of them to know
//! what it can leave out. The haves come from a walk of this repository's
//! own history in date order — git's default negotiator: a commit the
//! server acknowledges is common, and so is everything below it, which is
//! then never offered. Each round offers twice as many as the one before,
//! and once the server has acknowledged something, 256 offers in a row that
//! it does not acknowledge end the negotiation, as in git. Every v2 request
//! is stateless and repeats the wants and every common commit so far,
//! whatever carries it.
//!
//! The pack comes back on the side-band and goes straight to
//! `index_pack.receive`; the server's progress goes to the caller's
//! `Progress`. A v0 server is asked in one round — wants, haves, `done` —
//! with no multi-ack, which every server of that dialect understands.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const pkt_line = @import("../codec.zig").pkt_line;
const connection = @import("connection.zig");
const warning = @import("../report.zig").warning;
const protocol = @import("protocol.zig");
const side_band = @import("side_band.zig");
const index_pack = @import("../odb/index_pack.zig");
const progress_mod = @import("../report.zig").progress;
const rev_walk = @import("../walk/walk.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;
const Odb = odb_mod.Odb;

/// Errors from asking for a pack and receiving it.
pub const Error = error{
    /// The server's side-band carried an error. `Connection.message` holds
    /// its text.
    RemoteError,
    /// A section or a line the protocol does not have where it came.
    ProtocolError,
    /// The server wants to hand part of the pack over as a URI, which
    /// relic does not fetch.
    PackfileUrisUnsupported,
    /// A shallow fetch, or a fetch into a shallow repository, from a server
    /// that does not speak of shallow history — or does not have the kind of
    /// deepening asked for.
    ShallowUnsupportedByServer,
    /// A negotiation alone asked of a server below protocol v2: git's
    /// "--negotiate-only requires protocol v2".
    NegotiateOnlyNeedsV2,
    /// A negotiation alone asked of a server whose `fetch` does not take
    /// `wait-for-done`: git's "server does not support wait-for-done".
    WaitForDoneUnsupported,
    /// The server's history is shallow and `ShallowInfo.reject` refuses
    /// one: git's "source repository is shallow, reject to clone."
    ShallowSourceRefused,
} || protocol.Error || index_pack.Error || odb_mod.Error || object.ParseError;

/// What to ask for.
pub const Request = struct {
    /// The objects wanted. None of them should be ones this repository
    /// already has.
    wants: []const Oid,
    /// The ref each want was listed as, by position, for a remote helper,
    /// which is asked by name. Empty takes the names from its list.
    want_names: []const []const u8 = &.{},
    /// This repository's ref tips, which is where the offer of haves starts.
    tips: []const Oid,
    /// Tips the server is known to have too — refs it advertised with a
    /// value this repository holds. They are offered first and nothing below
    /// them is offered.
    common_tips: []const Oid = &.{},
    /// Ask for the annotated tags that point into the pack.
    include_tag: bool = true,
    /// Make the history shallow, or deeper, or whole.
    deepen: ?Deepen = null,
    /// This repository's shallow boundary, which the server is told so it
    /// sends nothing from below it.
    shallow: []const Oid = &.{},
    /// A partial clone's filter, as `partial.normalize` spells it:
    /// `blob:none`, `blob:limit=1024`, `tree:0`.
    filter: ?[]const u8 = null,
    /// `session-id=`, for a server that takes one: `transfer.advertiseSID`.
    session_id: ?[]const u8 = null,
    /// `server-option=` lines, which only a v2 server takes.
    server_options: []const []const u8 = &.{},
    /// How the haves are chosen: `fetch.negotiationAlgorithm`.
    negotiation: Negotiation = .consecutive,
    /// Commits offered whatever the negotiator chooses, as git's
    /// `--negotiation-include` offers them: once before the others in v0,
    /// in every round in v2.
    include_haves: []const Oid = &.{},
};

/// git's `fetch.negotiationAlgorithm`: how a fetch chooses the commits it
/// offers as haves.
pub const Negotiation = enum {
    /// git's default: every commit from the tips back, newest first, less
    /// what the server is known to have.
    consecutive,
    /// git's `skipping`: newest first, but ever longer leaps back through
    /// a run the server has not acknowledged, so a history that shares
    /// little with the server's is found in fewer rounds.
    skipping,
    /// No haves at all: the server sends everything the wants reach.
    noop,
};

/// How deep the history is to be: git's `--depth`, `--deepen`,
/// `--shallow-since`, `--shallow-exclude` and `--unshallow`.
pub const Deepen = struct {
    /// Commits from each wanted tip; with `relative`, beyond the current
    /// boundary. `--unshallow` is git's infinite depth, 2147483647.
    depth: ?u32 = null,
    relative: bool = false,
    /// Commits newer than this time, in seconds since the epoch.
    since: ?i64 = null,
    /// Commits not reachable from these refs, as the server names them.
    not: []const []const u8 = &.{},
};

/// What the server said of the boundary: the commits now at it, and those
/// no longer at it because their parents came.
pub const ShallowInfo = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    shallow: std.ArrayList(Oid) = .empty,
    unshallow: std.ArrayList(Oid) = .empty,
    /// git's `--reject-shallow`, for a request that does not deepen: a
    /// server that says its own history is shallow is
    /// `error.ShallowSourceRefused`, before its pack is read.
    reject: bool = false,

    /// Release both lists.
    pub fn deinit(info: *ShallowInfo) void {
        info.shallow.deinit(info.gpa);
        info.unshallow.deinit(info.gpa);
        info.* = undefined;
    }

    /// Take a `shallow <oid>` or `unshallow <oid>` line; whether it was
    /// one.
    fn take(info: *ShallowInfo, kind: hash.Kind, line: []const u8) (Allocator.Error || error{ProtocolError})!bool {
        if (std.mem.startsWith(u8, line, "shallow ")) {
            try info.shallow.append(info.gpa, Oid.parse(kind, line["shallow ".len..]) catch return error.ProtocolError);
            return true;
        }
        if (std.mem.startsWith(u8, line, "unshallow ")) {
            try info.unshallow.append(info.gpa, Oid.parse(kind, line["unshallow ".len..]) catch return error.ProtocolError);
            return true;
        }
        return false;
    }
};

/// How the pack is received.
pub const Options = struct {
    progress: ?progress_mod.Progress = null,
    /// Handed to `index_pack.receive`; its `progress` is set from the one
    /// above.
    receive: index_pack.Options = .{},
    /// Where the server's word on the shallow boundary goes. A request that
    /// deepens, or names a boundary, needs one.
    shallow_info: ?*ShallowInfo = null,
    /// Where a filter the server does not know is noted, as git warns of
    /// it: the fetch goes on without the filter and takes everything.
    warnings: ?*warning.Warnings = null,
};

pub const Inputs = struct { advertisement: *const protocol.Advertisement, db: *Odb, request: Request };

/// git's `negotiate_using_fetch` (`git fetch --negotiate-only`): the
/// haves from `inputs.request.tips` and its `include_haves` offered to a v2
/// server under `wait-for-done`, round after round, until every tip reaches
/// a commit known to be common or nothing is left to offer; no pack. The
/// commits the server acknowledged, in the order it did, the caller's.
pub fn negotiateOnly(gpa: Allocator, io: Io, conn: *Connection, inputs: Inputs) Self.Error![]Oid {
    const adv = inputs.advertisement;
    const request = inputs.request;
    if (adv.version != .v2) return error.NegotiateOnlyNeedsV2;
    if (!adv.commandHas("fetch", "wait-for-done")) return error.WaitForDoneUnsupported;
    try protocol.checkServerOptions(adv, request.server_options);
    var negotiator: Negotiator = .{ .gpa = gpa, .io = io, .db = inputs.db, .arena = .init(gpa), .algorithm = request.negotiation };
    defer negotiator.deinit();
    for (request.tips) |tip| try negotiator.addTip(tip);
    var acked: std.ArrayList(Oid) = .empty;
    errdefer acked.deinit(gpa);
    var haves_to_send: usize = 16;
    var in_vain: usize = 0;
    var seen_ack = false;
    var last = false;
    while (!last) {
        const w = try conn.request();
        (write: {
            protocol.writeCommand(w, adv, "fetch", .{ .session_id = request.session_id, .server_options = request.server_options }) catch |e| break :write e;
            pkt_line.write(w, "wait-for-done") catch |e| break :write e;
            for (request.include_haves) |oid| {
                if (!try negotiator.haveSent(oid)) continue;
                pkt_line.print(w, "have {f}\n", .{oid}) catch |e| break :write e;
            }
            var added: usize = 0;
            while (added < haves_to_send) {
                const oid = (try negotiator.next()) orelse break;
                pkt_line.print(w, "have {f}\n", .{oid}) catch |e| break :write e;
                added += 1;
            }
            haves_to_send = nextFlush(haves_to_send);
            in_vain += added;
            if (added == 0 or (seen_ack and in_vain >= max_in_vain)) last = true;
            pkt_line.flush(w) catch |e| break :write e;
        }) catch |err| return conn.writeFailed(err);
        const in = try conn.response();
        try expectSection(conn, in, "acknowledgments");
        while (true) {
            const packet = try conn.readPacket(in);
            const raw = switch (packet) {
                .flush => break,
                .data => |unparsed| unparsed.readForParse(),
                else => return error.ProtocolError,
            };
            const line = std.mem.trimEnd(u8, raw, "\n");
            if (std.mem.eql(u8, line, "NAK")) continue;
            // A pack is never asked for here: git's "unexpected 'ready'".
            if (!std.mem.startsWith(u8, line, "ACK ")) return error.ProtocolError;
            const oid = Oid.parse(adv.kind, line[4..]) catch return error.ProtocolError;
            _ = try negotiator.ack(oid);
            in_vain = 0;
            seen_ack = true;
            var known = false;
            for (acked.items) |c| known = known or c.eql(oid);
            if (!known) try acked.append(gpa, oid);
        }
        if (try negotiator.everyTipCommon(request.tips)) last = true;
    }
    return acked.toOwnedSlice(gpa);
}

/// Fetch a pack for `inputs.request` over `conn`, which opened with `adv`, into
/// `pack_dir`, which is `db`'s `objects/pack`.
pub fn fetch(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    inputs: Inputs,
    options: Options,
) Self.Error!index_pack.Result {
    const adv = inputs.advertisement;
    const db = inputs.db;
    const request = inputs.request;
    try protocol.checkServerOptions(adv, request.server_options);
    // A v0 server says where its history ends in its advertisement.
    if (options.shallow_info) |info| if (info.reject and adv.shallow.len != 0) return error.ShallowSourceRefused;
    var negotiator: Negotiator = .{ .gpa = gpa, .io = io, .db = db, .arena = .init(gpa), .algorithm = request.negotiation };
    defer negotiator.deinit();
    for (request.common_tips) |tip| try negotiator.knownCommon(tip);
    for (request.tips) |tip| try negotiator.addTip(tip);

    var receive_options = options.receive;
    receive_options.progress = options.progress;
    // A server that does not filter is asked for everything, as git asks
    // it: "filtering not recognized by server, ignoring".
    var asked = request;
    if (asked.filter != null) {
        const filters = switch (adv.version) {
            .v2 => adv.commandHas("fetch", "filter"),
            else => adv.has("filter"),
        };
        if (!filters) {
            try warning.note(options.warnings, .filter_not_supported);
            asked.filter = null;
        }
    }
    return switch (adv.version) {
        .v2 => fetchV2(gpa, io, conn, adv, db, asked, &negotiator, options.progress, receive_options, options.shallow_info),
        .v0, .v1 => fetchV0(gpa, io, conn, adv, db, asked, &negotiator, options.progress, receive_options, options.shallow_info),
    };
}

/// git's `MAX_IN_VAIN`.
const max_in_vain = 256;

fn nextFlush(count: usize) usize {
    // git's `next_flush` for a stateless conversation, which v2 always is.
    if (count < 16384) return count * 2;
    return count * 11 / 10;
}

fn fetchV2(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    adv: *const protocol.Advertisement,
    db: *Odb,
    request: Request,
    negotiator: *Negotiator,
    progress: ?progress_mod.Progress,
    receive_options: index_pack.Options,
    shallow_info: ?*ShallowInfo,
) Error!index_pack.Result {
    if (request.deepen != null or request.shallow.len != 0) {
        if (!adv.commandHas("fetch", "shallow")) return error.ShallowUnsupportedByServer;
    }
    var common: std.ArrayList(Oid) = .empty;
    defer common.deinit(gpa);
    var haves_to_send: usize = 16;
    var in_vain: usize = 0;
    var seen_ack = false;

    while (true) {
        const w = try conn.request();
        var done = false;
        writeFetchV2(w, adv, request, common.items, negotiator, haves_to_send, &in_vain, seen_ack, progress == null, &done) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed, error.PacketTooLong => return conn.writeFailed(err),
            else => |e| return e,
        };
        const in = try conn.response();

        if (!done) {
            try expectSection(conn, in, "acknowledgments");
            var ready = false;
            var acked = false;
            while (true) {
                const packet = try conn.readPacket(in);
                switch (packet) {
                    .flush, .response_end => break,
                    .delim => {
                        if (!ready) return error.ProtocolError;
                        break;
                    },
                    .data => |unparsed| {
                        const raw = unparsed.readForParse();
                        const line = std.mem.trimEnd(u8, raw, "\n");
                        if (std.mem.eql(u8, line, "NAK")) continue;
                        if (std.mem.eql(u8, line, "ready")) {
                            ready = true;
                            continue;
                        }
                        if (std.mem.startsWith(u8, line, "ACK ")) {
                            const oid = Oid.parse(adv.kind, line[4..]) catch return error.ProtocolError;
                            _ = try negotiator.ack(oid);
                            var known = false;
                            for (common.items) |c| {
                                if (c.eql(oid)) known = true;
                            }
                            if (!known) try common.append(gpa, oid);
                            acked = true;
                            continue;
                        }
                        if (std.mem.startsWith(u8, line, "ERR ")) {
                            conn.setMessage(line[4..]);
                            return error.RemoteError;
                        }
                        return error.ProtocolError;
                    },
                }
            }
            if (acked) {
                in_vain = 0;
                seen_ack = true;
            }
            if (!ready) {
                haves_to_send = nextFlush(haves_to_send);
                continue;
            }
        }
        return receivePackfileV2(io, conn, in, db, progress, receive_options, adv.kind, shallow_info);
    }
}

fn writeFetchV2(
    w: *Io.Writer,
    adv: *const protocol.Advertisement,
    request: Request,
    common: []const Oid,
    negotiator: *Negotiator,
    haves_to_send: usize,
    in_vain: *usize,
    seen_ack: bool,
    no_progress: bool,
    done: *bool,
) (pkt_line.WriteError || Negotiator.NegotiateError)!void {
    try protocol.writeCommand(w, adv, "fetch", .{ .session_id = request.session_id, .server_options = request.server_options });
    // Newlines where git's fetch-pack writes them, and none where not.
    try pkt_line.write(w, "thin-pack");
    if (no_progress) try pkt_line.write(w, "no-progress");
    if (request.include_tag) try pkt_line.write(w, "include-tag");
    try pkt_line.write(w, "ofs-delta");
    try writeShallowRequest(w, request, true);
    if (request.filter) |spec| try pkt_line.print(w, "filter {s}", .{spec});
    for (request.wants) |oid| try pkt_line.print(w, "want {f}\n", .{oid});
    for (common) |oid| try pkt_line.print(w, "have {f}\n", .{oid});
    // git's `add_haves`: the included ones every round, not counted.
    for (request.include_haves) |oid| {
        if (!try negotiator.haveSent(oid)) continue;
        try pkt_line.print(w, "have {f}\n", .{oid});
    }
    var added: usize = 0;
    while (added < haves_to_send) {
        const oid = (try negotiator.next()) orelse break;
        try pkt_line.print(w, "have {f}\n", .{oid});
        added += 1;
    }
    in_vain.* += added;
    if (added == 0 or (seen_ack and in_vain.* >= max_in_vain)) {
        try pkt_line.write(w, "done\n");
        done.* = true;
    }
    try pkt_line.flush(w);
}

/// git's `add_shallow_requests`: the boundary, then how to move it.
/// In v0 `deepen-relative` is a capability rather than a line.
fn writeShallowRequest(w: *Io.Writer, request: Request, v2: bool) pkt_line.WriteError!void {
    for (request.shallow) |oid| try pkt_line.print(w, "shallow {f}\n", .{oid});
    const deepen = request.deepen orelse return;
    if (deepen.depth) |depth| try pkt_line.print(w, "deepen {d}", .{depth});
    if (deepen.since) |since| try pkt_line.print(w, "deepen-since {d}", .{since});
    for (deepen.not) |name| try pkt_line.print(w, "deepen-not {s}", .{name});
    if (v2 and deepen.relative) try pkt_line.write(w, "deepen-relative\n");
}

fn expectSection(conn: *Connection, in: *Io.Reader, name: []const u8) Error!void {
    const packet = try conn.readPacket(in);
    const line = switch (packet) {
        .data => |raw| std.mem.trimEnd(u8, raw.readForParse(), "\n"),
        else => return error.ProtocolError,
    };
    if (std.mem.startsWith(u8, line, "ERR ")) {
        conn.setMessage(line[4..]);
        return error.RemoteError;
    }
    if (!std.mem.eql(u8, line, name)) return error.ProtocolError;
}

/// Read the sections of a v2 response up to `packfile` and receive the
/// pack it carries.
fn receivePackfileV2(
    io: Io,
    conn: *Connection,
    in: *Io.Reader,
    db: *Odb,
    progress: ?progress_mod.Progress,
    receive_options: index_pack.Options,
    kind: hash.Kind,
    shallow_info: ?*ShallowInfo,
) Error!index_pack.Result {
    while (true) {
        const packet = try conn.readPacket(in);
        const header = switch (packet) {
            .data => |raw| std.mem.trimEnd(u8, raw.readForParse(), "\n"),
            else => return error.ProtocolError,
        };
        if (std.mem.startsWith(u8, header, "ERR ")) {
            conn.setMessage(header[4..]);
            return error.RemoteError;
        }
        if (std.mem.eql(u8, header, "packfile")) break;
        if (std.mem.eql(u8, header, "packfile-uris")) return error.PackfileUrisUnsupported;
        // `shallow-info` moves the boundary; `wanted-refs` answers a
        // question this client does not ask. Each runs to the delimiter.
        const is_shallow = std.mem.eql(u8, header, "shallow-info");
        while (true) {
            switch (try conn.readPacket(in)) {
                .delim => break,
                .data => |raw| if (is_shallow) {
                    const info = shallow_info orelse return error.ProtocolError;
                    if (!try info.take(kind, std.mem.trimEnd(u8, raw.readForParse(), "\n"))) return error.ProtocolError;
                },
                else => return error.ProtocolError,
            }
        }
        if (is_shallow) if (shallow_info) |info| if (info.reject and info.shallow.items.len != 0) return error.ShallowSourceRefused;
    }
    return receiveSideband(io, conn, in, db, progress, receive_options);
}

fn receiveSideband(
    io: Io,
    conn: *Connection,
    in: *Io.Reader,
    db: *Odb,
    progress: ?progress_mod.Progress,
    receive_options: index_pack.Options,
) Error!index_pack.Result {
    var demux: side_band.Demux = .init(in, &.{}, progress);
    return db.receivePack(io, &demux.interface, receive_options) catch |err| switch (err) {
        error.ReadFailed => {
            const why = demux.err orelse return conn.failure();
            return switch (why) {
                error.RemoteError => {
                    conn.setMessage(demux.message());
                    return error.RemoteError;
                },
                error.BadSideband => error.ProtocolError,
                error.RemoteHungUp => error.RemoteHungUp,
                error.ReadFailed => conn.failure(),
            };
        },
        else => |e| return e,
    };
}

/// What a v0 server says to a round of haves: git's `get_ack`.
const Ack = enum { nak, ack, common, ready, @"continue" };

fn readAck(conn: *Connection, in: *Io.Reader, kind: hash.Kind, oid_out: *Oid) Error!Ack {
    const packet = try conn.readPacket(in);
    const line = switch (packet) {
        .data => |raw| std.mem.trimEnd(u8, raw.readForParse(), "\n"),
        else => return error.ProtocolError,
    };
    if (std.mem.eql(u8, line, "NAK")) return .nak;
    if (std.mem.startsWith(u8, line, "ERR ")) {
        conn.setMessage(line[4..]);
        return error.RemoteError;
    }
    if (!std.mem.startsWith(u8, line, "ACK ")) return error.ProtocolError;
    const rest = line[4..];
    const hex_len = kind.hexLen();
    if (rest.len < hex_len) return error.ProtocolError;
    oid_out.* = Oid.parse(kind, rest[0..hex_len]) catch return error.ProtocolError;
    const suffix = rest[hex_len..];
    if (suffix.len == 0) return .ack;
    if (std.mem.eql(u8, suffix, " continue")) return .@"continue";
    if (std.mem.eql(u8, suffix, " common")) return .common;
    if (std.mem.eql(u8, suffix, " ready")) return .ready;
    return error.ProtocolError;
}

/// The `shallow` and `unshallow` lines a server sends after a request that
/// deepens, up to their flush. Kept the first time; a stateless server
/// repeats them with every answer.
fn readShallowList(conn: *Connection, in: *Io.Reader, kind: hash.Kind, shallow_info: ?*ShallowInfo, keep: bool) Error!void {
    while (true) {
        switch (try conn.readPacket(in)) {
            .flush => return,
            .data => |unparsed| {
                const raw = unparsed.readForParse();
                const line = std.mem.trimEnd(u8, raw, "\n");
                if (!keep) continue;
                const info = shallow_info orelse return error.ProtocolError;
                if (!try info.take(kind, line)) return error.ProtocolError;
            },
            else => return error.ProtocolError,
        }
    }
}

/// git's `next_flush`: how many haves the next round ends at.
fn nextFlushV0(stateless: bool, count: usize) usize {
    if (stateless) return if (count < 16384) count * 2 else count * 11 / 10;
    return if (count < 32) count * 2 else count + 32;
}

/// git's `find_common`, and the pack after it: the wants, then haves in
/// rounds of sixteen, thirty-two, sixty-four…, each answered with what the
/// server has in common (`multi_ack_detailed`), until the server is ready,
/// the haves run out, or 256 in a row were not acknowledged. Over a pipe
/// one round is kept in flight ahead of the answers, as git keeps it; over
/// HTTP every round is a request of its own carrying the wants and every
/// common commit again.
fn fetchV0(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    adv: *const protocol.Advertisement,
    db: *Odb,
    request: Request,
    negotiator: *Negotiator,
    progress: ?progress_mod.Progress,
    receive_options: index_pack.Options,
    shallow_info: ?*ShallowInfo,
) Error!index_pack.Result {
    const deepen = request.deepen != null;
    const caps = try capabilitiesV0(conn, adv, request);
    const band = caps.band;
    const stateless = conn.stateless;
    var multi_ack = caps.multi_ack;
    const no_done = caps.no_done;

    // What every stateless request begins with: the wants and how deep.
    var state: Io.Writer.Allocating = .init(gpa);
    defer state.deinit();
    writeWantsV0(&state.writer, adv, request, band != .none, progress == null, multi_ack, no_done) catch return error.OutOfMemory;
    var round: Io.Writer.Allocating = .init(gpa);
    defer round.deinit();
    var in: *Io.Reader = undefined;
    var shallow_kept = false;

    if (!stateless) {
        in = try exchange(conn, state.written());
        if (deepen) {
            try readShallowList(conn, in, adv.kind, shallow_info, true);
            shallow_kept = true;
        }
        state.clearRetainingCapacity();
    }
    round.writer.writeAll(state.written()) catch return error.OutOfMemory;

    var count: usize = 0;
    var flushes: usize = 0;
    var in_vain: usize = 0;
    var flush_at: usize = 16;
    var got_continue = false;
    var got_ready = false;
    var acked_any = false;
    var acked: Oid = undefined;
    count += try offerIncluded(&round.writer, request, negotiator);
    negotiate: while (try negotiator.next()) |oid| {
        pkt_line.print(&round.writer, "have {f}\n", .{oid}) catch return error.OutOfMemory;
        in_vain += 1;
        count += 1;
        if (count < flush_at) continue;
        pkt_line.flush(&round.writer) catch return error.OutOfMemory;
        in = try exchange(conn, round.written());
        round.clearRetainingCapacity();
        round.writer.writeAll(state.written()) catch return error.OutOfMemory;
        flushes += 1;
        flush_at = nextFlushV0(stateless, count);
        // One round ahead of the answers, over a pipe.
        if (!stateless and count == 16) continue;
        if (stateless and deepen) {
            try readShallowList(conn, in, adv.kind, shallow_info, !shallow_kept);
            shallow_kept = true;
        }
        while (true) {
            const ack = try readAck(conn, in, adv.kind, &acked);
            switch (ack) {
                .nak => break,
                .ack => {
                    flushes = 0;
                    multi_ack = 0;
                    acked_any = true;
                    break :negotiate;
                },
                .common, .ready, .@"continue" => {
                    const was_common = try negotiator.ack(acked);
                    if (stateless and ack == .common and !was_common) {
                        // Replayed in every request after, so the server
                        // keeps knowing it.
                        pkt_line.print(&state.writer, "have {f}\n", .{acked}) catch return error.OutOfMemory;
                        pkt_line.print(&round.writer, "have {f}\n", .{acked}) catch return error.OutOfMemory;
                        in_vain = 0;
                    } else if (!stateless or ack != .common) in_vain = 0;
                    acked_any = true;
                    got_continue = true;
                    if (ack == .ready) got_ready = true;
                },
            }
        }
        // This round's flush added one before its answers were read.
        assert(flushes > 0);
        flushes -= 1;
        if (got_continue and in_vain > max_in_vain) break;
        if (got_ready) break;
    }

    if (!got_ready or !no_done) {
        pkt_line.write(&round.writer, "done\n") catch return error.OutOfMemory;
        in = try exchange(conn, round.written());
    }
    if (!acked_any) {
        multi_ack = 0;
        flushes += 1;
    }
    if ((!got_ready or !no_done) and stateless and deepen) {
        try readShallowList(conn, in, adv.kind, shallow_info, !shallow_kept);
    }
    try drainAcksV0(conn, in, adv.kind, flushes, multi_ack, &acked);

    var receive = receive_options;
    receive.progress = progress;
    return receivePackV0(io, conn, in, db, band, receive);
}

/// git's `find_common`'s haves from `--negotiation-include`: offered first
/// whatever each is, only a commit told to the negotiator, counted toward
/// the flush but not as offered in vain. How many.
fn offerIncluded(w: *Io.Writer, request: Request, negotiator: *Negotiator) Error!usize {
    for (request.include_haves) |oid| {
        pkt_line.print(w, "have {f}\n", .{oid}) catch return error.OutOfMemory;
        _ = try negotiator.haveSent(oid);
    }
    return request.include_haves.len;
}

/// A v0 server's pack, on its own or on the side band.
fn receivePackV0(io: Io, conn: *Connection, in: *Io.Reader, db: *Odb, band: Band, receive: index_pack.Options) Error!index_pack.Result {
    if (band == .none) {
        return db.receivePack(io, in, receive) catch |err| switch (err) {
            error.ReadFailed => conn.failure(),
            else => |e| e,
        };
    }
    return receiveSideband(io, conn, in, db, receive.progress, receive);
}

/// Send `bytes` as the next request and take the response to read.
fn exchange(conn: *Connection, bytes: []const u8) Error!*Io.Reader {
    const w = try conn.request();
    w.writeAll(bytes) catch |err| return conn.writeFailed(err);
    const in = try conn.response();
    return in;
}

/// How a v0 server sends the pack: on its own, or in side-band packets
/// of 999 or 65519 bytes.
const Band = enum { none, small, large };

/// What a v0 server's capabilities make of a fetch.
const CapabilitiesV0 = struct {
    band: Band,
    /// 0 for none, 1 for `multi_ack`, 2 for `multi_ack_detailed`.
    multi_ack: u2,
    /// Whether the client may leave out `done` once the server is ready.
    no_done: bool,
};

/// The server's capabilities for `request`: `error.ShallowUnsupportedByServer`
/// for a deepening it cannot do, `error.ProtocolError` for a stateless
/// server without `multi_ack_detailed`, which stateless negotiation needs.
fn capabilitiesV0(conn: *Connection, adv: *const protocol.Advertisement, request: Request) Error!CapabilitiesV0 {
    if (request.deepen != null or request.shallow.len != 0) {
        if (!adv.has("shallow")) return error.ShallowUnsupportedByServer;
        if (request.deepen) |d| {
            if (d.since != null and !adv.has("deepen-since")) return error.ShallowUnsupportedByServer;
            if (d.not.len != 0 and !adv.has("deepen-not")) return error.ShallowUnsupportedByServer;
            if (d.relative and !adv.has("deepen-relative")) return error.ShallowUnsupportedByServer;
        }
    }
    const band: Band = if (adv.has("side-band-64k"))
        .large
    else if (adv.has("side-band"))
        .small
    else
        .none;
    const multi_ack: u2 = if (adv.has("multi_ack_detailed")) 2 else if (adv.has("multi_ack")) 1 else 0;
    if (conn.stateless and multi_ack != 2) {
        conn.setMessage("a stateless server must speak multi_ack_detailed");
        return error.ProtocolError;
    }
    return .{ .band = band, .multi_ack = multi_ack, .no_done = conn.stateless and multi_ack == 2 and adv.has("no-done") };
}

/// Read the answers still due after `done`, as git's `find_common` does:
/// a NAK for each flush not yet answered, and, under multi_ack, the ACKs
/// up to the final one.
fn drainAcksV0(conn: *Connection, in: *Io.Reader, kind: hash.Kind, flushes: usize, multi_ack: u2, acked: *Oid) Error!void {
    var pending = flushes;
    var multi = multi_ack;
    while (pending > 0 or multi != 0) {
        const ack = try readAck(conn, in, kind, acked);
        if (ack != .nak) {
            if (ack == .ack) break;
            multi = 1;
            continue;
        }
        if (pending == 0) {
            conn.setMessage("the server said NAK to a flush that was not sent");
            return error.ProtocolError;
        }
        pending -= 1;
    }
}

/// The wants of a v0 request, the first with the capabilities git asks
/// for in git's order, then the boundary and how to move it, and a flush.
fn writeWantsV0(
    w: *Io.Writer,
    adv: *const protocol.Advertisement,
    request: Request,
    band: bool,
    no_progress: bool,
    multi_ack: u2,
    no_done: bool,
) (pkt_line.WriteError || Allocator.Error)!void {
    for (request.wants, 0..) |oid, i| {
        if (i != 0) {
            try pkt_line.print(w, "want {f}\n", .{oid});
            continue;
        }
        var caps_buffer: [512]u8 = undefined;
        var caps: Io.Writer = .fixed(&caps_buffer);
        const c = &caps;
        if (multi_ack == 2) try c.writeAll(" multi_ack_detailed") else if (multi_ack == 1) try c.writeAll(" multi_ack");
        if (no_done) try c.writeAll(" no-done");
        if (adv.has("side-band-64k")) {
            try c.writeAll(" side-band-64k");
        } else if (band) try c.writeAll(" side-band");
        if (request.deepen != null and request.deepen.?.relative) try c.writeAll(" deepen-relative");
        if (adv.has("thin-pack")) try c.writeAll(" thin-pack");
        if (no_progress and adv.has("no-progress")) try c.writeAll(" no-progress");
        if (request.include_tag and adv.has("include-tag")) try c.writeAll(" include-tag");
        if (adv.has("ofs-delta")) try c.writeAll(" ofs-delta");
        if (adv.has("deepen-since")) try c.writeAll(" deepen-since");
        if (adv.has("deepen-not")) try c.writeAll(" deepen-not");
        if (adv.has("agent")) try c.print(" agent={s}", .{protocol.agent});
        if (request.session_id) |sid| if (adv.has("session-id")) try c.print(" session-id={s}", .{sid});
        if (request.filter != null) try c.writeAll(" filter");
        // git names the hash only when it is not SHA-1.
        if (adv.has("object-format") and adv.kind != .sha1) try c.print(" object-format={s}", .{adv.kind.name()});
        try pkt_line.print(w, "want {f}{s}\n", .{ oid, caps.buffered() });
    }
    try writeShallowRequest(w, request, false);
    if (request.filter) |spec| try pkt_line.print(w, "filter {s}", .{spec});
    try pkt_line.flush(w);
}

/// git's negotiators: this repository's commits, newest first, less
/// whatever is known to be common -- every one of them (`consecutive`),
/// some of them in ever longer leaps (`skipping`), or none (`noop`).
const Negotiator = struct {
    gpa: Allocator,
    io: Io,
    db: *Odb,
    arena: std.heap.ArenaAllocator,
    algorithm: Negotiation = .consecutive,
    nodes: Oid.Map(Node) = .empty,
    queue: std.PriorityQueue(Queued, void, Queued.newerFirst) = .empty,
    /// The order commits are queued in, which breaks a tie between equal
    /// dates as git's priority queue breaks it.
    queued: u64 = 0,
    /// Commits queued and not yet taken that are not known to be common,
    /// counted as git counts them: `skipping` can take it below what is
    /// queued, and stops only at zero.
    non_common: i64 = 0,

    const Node = struct {
        seen: bool = false,
        popped: bool = false,
        common: bool = false,
        /// A tip the server is known to have: offered, but nothing below it.
        common_ref: bool = false,
        loaded: bool = false,
        time: i64 = 0,
        parents: []const Oid = &.{},
        /// `skipping`'s: how many commits below this one go unoffered, and
        /// what that was when it was set.
        ttl: u16 = 0,
        original_ttl: u16 = 0,
    };

    const Queued = struct {
        time: i64,
        order: u64,
        oid: Oid,

        fn newerFirst(_: void, a: Queued, b: Queued) std.math.Order {
            if (a.time != b.time) return std.math.order(b.time, a.time);
            return std.math.order(a.order, b.order);
        }
    };

    const NegotiateError = odb_mod.Error || object.ParseError || Allocator.Error;

    fn deinit(n: *Negotiator) void {
        n.arena.deinit();
        n.nodes.deinit(n.gpa);
        n.queue.deinit(n.gpa);
        n.* = undefined;
    }

    /// The node for `oid`, its commit read, or `null` when `oid` is not a
    /// commit this repository has (a tag is followed to its commit first).
    fn load(n: *Negotiator, start: Oid) NegotiateError!?struct { oid: Oid, node: *Node } {
        var oid = start;
        var depth: u8 = 0;
        while (true) : (depth += 1) {
            if (depth > 16) return null;
            if (n.nodes.getPtr(oid)) |node| {
                if (node.loaded) return .{ .oid = oid, .node = node };
            }
            if (!try n.db.exists(n.io, oid)) return null;
            const found = try n.db.read(n.io, oid);
            defer n.db.allocator().free(found.bytes);
            switch (found.type) {
                .tag => {
                    var tag = try object.Tag.parse(n.gpa, n.db.objectFormat(), found.bytes);
                    defer tag.deinit();
                    oid = tag.target;
                    continue;
                },
                .commit => {},
                else => return null,
            }
            var commit = try object.Commit.parse(n.gpa, n.db.objectFormat(), found.bytes);
            defer commit.deinit();
            const parents = try n.arena.allocator().dupe(Oid, rev_walk.parentsOf(n.db, oid, commit.parents));
            const gop = try n.nodes.getOrPut(n.gpa, oid);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.time = commit.committer.when_secs;
            gop.value_ptr.parents = parents;
            gop.value_ptr.loaded = true;
            return .{ .oid = oid, .node = gop.value_ptr };
        }
    }

    fn enqueue(n: *Negotiator, oid: Oid, node: *const Node) NegotiateError!void {
        try n.queue.push(n.gpa, .{ .time = node.time, .order = n.queued, .oid = oid });
        n.queued += 1;
    }

    /// The node for `oid`, its commit not read unless it was already.
    fn nodeFor(n: *Negotiator, oid: Oid) NegotiateError!*Node {
        const gop = try n.nodes.getOrPut(n.gpa, oid);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// Start the walk from a tip of this repository.
    fn addTip(n: *Negotiator, tip: Oid) NegotiateError!void {
        const found = (try n.load(tip)) orelse return;
        switch (n.algorithm) {
            .noop => {},
            .consecutive => try n.revListPush(found.oid, .{ .seen = true }),
            .skipping => if (!found.node.seen) {
                found.node.seen = true;
                n.non_common += 1;
                try n.enqueue(found.oid, found.node);
            },
        }
    }

    /// A tip the server has too: offered first, and nothing below it.
    fn knownCommon(n: *Negotiator, tip: Oid) NegotiateError!void {
        const found = (try n.load(tip)) orelse return;
        if (found.node.seen) return;
        switch (n.algorithm) {
            .noop => {},
            .consecutive => {
                try n.revListPush(found.oid, .{ .common_ref = true, .seen = true });
                try n.markCommon(found.oid, .{ .ancestors_only = true, .dont_parse = true });
            },
            .skipping => {
                found.node.common_ref = true;
                found.node.seen = true;
                n.non_common += 1;
                try n.enqueue(found.oid, found.node);
            },
        }
    }

    /// The next commit to offer, or `null` when nothing is left that the
    /// server might not have.
    fn next(n: *Negotiator) NegotiateError!?Oid {
        return switch (n.algorithm) {
            .consecutive => n.nextConsecutive(),
            .skipping => n.nextSkipping(),
            .noop => null,
        };
    }

    /// The flags `revListPush` and `markCommon` set: git's `COMMON`,
    /// `COMMON_REF` and `SEEN`.
    const Marks = struct { common: bool = false, common_ref: bool = false, seen: bool = false };

    /// git's default negotiator's `rev_list_push`: `oid` marked and, its
    /// commit read, queued, unless it bears any of the marks already.
    fn revListPush(n: *Negotiator, oid: Oid, mark: Marks) NegotiateError!void {
        const node = try n.nodeFor(oid);
        if ((mark.common and node.common) or (mark.common_ref and node.common_ref) or (mark.seen and node.seen)) return;
        if (mark.common) node.common = true;
        if (mark.common_ref) node.common_ref = true;
        if (mark.seen) node.seen = true;
        const found = (try n.load(oid)) orelse return;
        try n.enqueue(found.oid, found.node);
        if (!found.node.common) n.non_common += 1;
    }

    /// git's default negotiator's `mark_common`: `oid` (unless only its
    /// ancestors are asked for) and its ancestors common; one not reached
    /// yet queued as reached, and the ancestors of one whose commit is not
    /// read left unmarked when `dont_parse` says not to read it.
    fn markCommon(n: *Negotiator, start: Oid, how: struct { ancestors_only: bool, dont_parse: bool }) NegotiateError!void {
        {
            const node = try n.nodeFor(start);
            if (node.common) return;
            if (!how.ancestors_only) {
                node.common = true;
                if (node.seen and !node.popped) n.non_common -= 1;
            }
        }
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(n.gpa);
        try stack.append(n.gpa, start);
        while (stack.pop()) |oid| {
            const node = try n.nodeFor(oid);
            if (!node.seen) {
                try n.revListPush(oid, .{ .seen = true });
                continue;
            }
            if (!node.loaded and !how.dont_parse) _ = try n.load(oid);
            const parents = (n.nodes.getPtr(oid).?).parents;
            for (parents) |parent| {
                const p = try n.nodeFor(parent);
                if (p.common) continue;
                p.common = true;
                if (p.seen and !p.popped) n.non_common -= 1;
                try stack.append(n.gpa, parent);
            }
        }
    }

    /// git's default negotiator's `get_rev`.
    fn nextConsecutive(n: *Negotiator) NegotiateError!?Oid {
        while (true) {
            if (n.queue.count() == 0 or n.non_common == 0) return null;
            const item = n.queue.pop().?;
            _ = try n.load(item.oid);
            const node = n.nodes.getPtr(item.oid).?;
            node.popped = true;
            if (!node.common) n.non_common -= 1;
            const entry = node.*;
            const mark: Marks = if (entry.common or entry.common_ref) .{ .common = true, .seen = true } else .{ .seen = true };
            for (entry.parents) |parent| {
                if (!(try n.nodeFor(parent)).seen) try n.revListPush(parent, mark);
                if (mark.common) try n.markCommon(parent, .{ .ancestors_only = true, .dont_parse = false });
            }
            if (entry.common) continue;
            return item.oid;
        }
    }

    /// git's `skipping` negotiator's `get_rev`: a commit is offered when
    /// its leap runs out, or when nothing below it is left to walk.
    fn nextSkipping(n: *Negotiator) NegotiateError!?Oid {
        while (true) {
            if (n.queue.count() == 0 or n.non_common == 0) return null;
            const item = n.queue.pop().?;
            const node = n.nodes.getPtr(item.oid).?;
            node.popped = true;
            if (!node.common) n.non_common -= 1;
            const entry = node.*;
            var send = !entry.common and entry.ttl == 0;
            var parent_pushed = false;
            for (entry.parents) |parent| {
                const found = (try n.load(parent)) orelse continue;
                if (try n.pushParent(entry, found.oid, found.node)) parent_pushed = true;
            }
            if (!entry.common and !parent_pushed) send = true;
            if (send) return item.oid;
        }
    }

    /// git's `push_parent`: `parent` queued below `entry`, and marked
    /// common below a common one or given the next leap below another.
    /// `false` for a parent already taken, which clock skew put first.
    fn pushParent(n: *Negotiator, entry: Node, oid: Oid, parent: *Node) NegotiateError!bool {
        if (parent.seen) {
            if (parent.popped) return false;
        } else {
            parent.seen = true;
            // As git's `rev_list_push` with no mark: counted whatever it is.
            n.non_common += 1;
            try n.enqueue(oid, parent);
        }
        if (entry.common or entry.common_ref) {
            try n.markCommonSkipping(oid);
            return true;
        }
        const original: u16 = if (entry.ttl != 0) entry.original_ttl else entry.original_ttl * 3 / 2 + 1;
        const ttl: u16 = if (entry.ttl != 0) entry.ttl - 1 else original;
        // `enqueue` and `markCommonSkipping` may have moved the node.
        const now = n.nodes.getPtr(oid).?;
        if (now.original_ttl < original) {
            now.original_ttl = original;
            now.ttl = ttl;
        }
        return true;
    }

    /// git's `skipping` negotiator's `mark_common`: `oid` and what the
    /// walk has reached below it, common; each counted off as git counts
    /// it, taken or not.
    fn markCommonSkipping(n: *Negotiator, oid: Oid) NegotiateError!void {
        const start = n.nodes.getPtr(oid) orelse return;
        if (start.common) return;
        start.common = true;
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(n.gpa);
        try stack.append(n.gpa, oid);
        while (stack.pop()) |current| {
            const node = n.nodes.getPtr(current).?;
            if (!node.popped) n.non_common -= 1;
            if (!node.loaded) continue;
            for (node.parents) |parent| {
                const p = n.nodes.getPtr(parent) orelse continue;
                if (!p.seen or p.common) continue;
                p.common = true;
                try stack.append(n.gpa, parent);
            }
        }
    }

    /// The server has `oid`. Returns whether it was already known to be
    /// common.
    fn ack(n: *Negotiator, oid: Oid) NegotiateError!bool {
        if (n.algorithm == .noop) return false;
        const found = (try n.load(oid)) orelse return false;
        const known = found.node.common;
        switch (n.algorithm) {
            .noop => {},
            .skipping => try n.markCommonSkipping(found.oid),
            .consecutive => try n.markCommon(found.oid, .{ .ancestors_only = false, .dont_parse = true }),
        }
        return known;
    }

    /// git's `can_all_from_reach_with_flag` with `COMMON`: whether each of
    /// `tips` reaches a commit the negotiation holds common.
    fn everyTipCommon(n: *Negotiator, tips: []const Oid) NegotiateError!bool {
        for (tips) |tip| {
            const start = (try n.load(tip)) orelse return false;
            var seen: Oid.Set = .empty;
            defer seen.deinit(n.gpa);
            var stack: std.ArrayList(Oid) = .empty;
            defer stack.deinit(n.gpa);
            try stack.append(n.gpa, start.oid);
            const reached = while (stack.pop()) |oid| {
                if ((try seen.getOrPut(n.gpa, oid)).found_existing) continue;
                const found = (try n.load(oid)) orelse continue;
                if (found.node.common) break true;
                for (found.node.parents) |parent| try stack.append(n.gpa, parent);
            } else false;
            if (!reached) return false;
        }
        return true;
    }

    /// git's `have_sent`: `oid`, offered whatever the negotiator chose,
    /// is taken as common, and what is below it with it. Whether it is a
    /// commit, which is all a v2 request offers.
    fn haveSent(n: *Negotiator, oid: Oid) NegotiateError!bool {
        const found = (try n.load(oid)) orelse return false;
        switch (n.algorithm) {
            .noop => {},
            .skipping => try n.markCommonSkipping(found.oid),
            .consecutive => try n.markCommon(found.oid, .{ .ancestors_only = false, .dont_parse = false }),
        }
        return true;
    }
};

const testing = std.testing;
test "fuzz: a shallow-info line is a boundary commit or a named failure" {
    try shakedown.check(testing.allocator, {}, fuzzShallowInfo, .{});
}

fn fuzzShallowInfo(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [256]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    var info: ShallowInfo = .{ .gpa = testing.allocator };
    defer info.deinit();
    _ = info.take(.sha1, input) catch |err| switch (err) {
        error.ProtocolError => return,
        else => |e| return e,
    };
}

test "fuzz: a v0 server's answer to haves is an acknowledgment or a named failure" {
    try shakedown.check(testing.allocator, {}, fuzzAck, .{});
}

fn fuzzAck(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [512]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    var fake: protocol.Fake = .init(input);
    const in = try fake.connection.advertisement();
    var oid: Oid = undefined;
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        _ = readAck(&fake.connection, in, .sha1, &oid) catch return;
    }
}
