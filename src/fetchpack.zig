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
//! `indexpack.receive`; the server's progress goes to the caller's
//! `Progress`. A v0 server is asked in one round — wants, haves, `done` —
//! with no multi-ack, which every server of that dialect understands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const pktline = @import("pktline.zig");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const sideband = @import("sideband.zig");
const indexpack = @import("indexpack.zig");
const progress_mod = @import("progress.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;
const Odb = odb_mod.Odb;

pub const Error = error{
    /// The server's side-band carried an error. `Connection.message` holds
    /// its text.
    RemoteError,
    /// A section or a line the protocol does not have where it came.
    ProtocolError,
    /// The server wants to hand part of the pack over as a URI, which
    /// relic does not fetch.
    PackfileUrisUnsupported,
} || protocol.Error || indexpack.Error || odb_mod.Error || object.ParseError;

/// What to ask for.
pub const Request = struct {
    /// The objects wanted. None of them should be ones this repository
    /// already has.
    wants: []const Oid,
    /// This repository's ref tips, which is where the offer of haves starts.
    tips: []const Oid,
    /// Tips the server is known to have too — refs it advertised with a
    /// value this repository holds. They are offered first and nothing below
    /// them is offered.
    common_tips: []const Oid = &.{},
    /// Ask for the annotated tags that point into the pack.
    include_tag: bool = true,
};

/// How the pack is received.
pub const Options = struct {
    progress: ?progress_mod.Progress = null,
    /// Handed to `indexpack.receive`; its `progress` is set from the one
    /// above.
    receive: indexpack.Options = .{},
};

/// Fetch a pack for `request` over `conn`, which opened with `adv`, into
/// `pack_dir`, which is `db`'s `objects/pack`.
pub fn fetch(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    adv: *const protocol.Advertisement,
    db: *Odb,
    pack_dir: Io.Dir,
    request: Request,
    options: Options,
) Error!indexpack.Result {
    var negotiator: Negotiator = .{ .gpa = gpa, .io = io, .db = db, .arena = .init(gpa) };
    defer negotiator.deinit();
    for (request.common_tips) |tip| try negotiator.knownCommon(tip);
    for (request.tips) |tip| try negotiator.addTip(tip);

    var receive_options = options.receive;
    receive_options.progress = options.progress;
    return switch (adv.version) {
        .v2 => fetchV2(gpa, io, conn, adv, db, pack_dir, request, &negotiator, options.progress, receive_options),
        .v0, .v1 => fetchV0(gpa, io, conn, adv, db, pack_dir, request, &negotiator, options.progress, receive_options),
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
    pack_dir: Io.Dir,
    request: Request,
    negotiator: *Negotiator,
    progress: ?progress_mod.Progress,
    receive_options: indexpack.Options,
) Error!indexpack.Result {
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
                    .data => |raw| {
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
        return receivePackfileV2(gpa, io, conn, in, db, pack_dir, progress, receive_options);
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
) (pktline.WriteError || Negotiator.NegotiateError)!void {
    try protocol.writeCommand(w, adv, "fetch");
    try pktline.write(w, "thin-pack\n");
    if (no_progress) try pktline.write(w, "no-progress\n");
    if (request.include_tag) try pktline.write(w, "include-tag\n");
    try pktline.write(w, "ofs-delta\n");
    for (request.wants) |oid| try pktline.print(w, "want {f}\n", .{oid});
    for (common) |oid| try pktline.print(w, "have {f}\n", .{oid});
    var added: usize = 0;
    while (added < haves_to_send) {
        const oid = (try negotiator.next()) orelse break;
        try pktline.print(w, "have {f}\n", .{oid});
        added += 1;
    }
    in_vain.* += added;
    if (added == 0 or (seen_ack and in_vain.* >= max_in_vain)) {
        try pktline.write(w, "done\n");
        done.* = true;
    }
    try pktline.flush(w);
}

fn expectSection(conn: *Connection, in: *Io.Reader, name: []const u8) Error!void {
    const packet = try conn.readPacket(in);
    const line = switch (packet) {
        .data => |raw| std.mem.trimEnd(u8, raw, "\n"),
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
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    in: *Io.Reader,
    db: *Odb,
    pack_dir: Io.Dir,
    progress: ?progress_mod.Progress,
    receive_options: indexpack.Options,
) Error!indexpack.Result {
    while (true) {
        const packet = try conn.readPacket(in);
        const header = switch (packet) {
            .data => |raw| std.mem.trimEnd(u8, raw, "\n"),
            else => return error.ProtocolError,
        };
        if (std.mem.startsWith(u8, header, "ERR ")) {
            conn.setMessage(header[4..]);
            return error.RemoteError;
        }
        if (std.mem.eql(u8, header, "packfile")) break;
        if (std.mem.eql(u8, header, "packfile-uris")) return error.PackfileUrisUnsupported;
        // `shallow-info` and `wanted-refs` answer questions this client did
        // not ask; their lines run to the delimiter.
        while (true) {
            switch (try conn.readPacket(in)) {
                .delim => break,
                .data => {},
                else => return error.ProtocolError,
            }
        }
    }
    return receiveSideband(gpa, io, conn, in, db, pack_dir, progress, receive_options);
}

fn receiveSideband(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    in: *Io.Reader,
    db: *Odb,
    pack_dir: Io.Dir,
    progress: ?progress_mod.Progress,
    receive_options: indexpack.Options,
) Error!indexpack.Result {
    var demux: sideband.Demux = .init(in, &.{}, progress);
    return indexpack.receive(gpa, io, db, pack_dir, &demux.interface, receive_options) catch |err| switch (err) {
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

/// The most haves a v0 request carries, which is its one round.
const v0_haves = 256;

fn fetchV0(
    gpa: Allocator,
    io: Io,
    conn: *Connection,
    adv: *const protocol.Advertisement,
    db: *Odb,
    pack_dir: Io.Dir,
    request: Request,
    negotiator: *Negotiator,
    progress: ?progress_mod.Progress,
    receive_options: indexpack.Options,
) Error!indexpack.Result {
    const band: enum { none, small, large } = if (adv.has("side-band-64k"))
        .large
    else if (adv.has("side-band"))
        .small
    else
        .none;
    const w = try conn.request();
    writeFetchV0(w, adv, request, negotiator, band != .none, progress == null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed, error.PacketTooLong => return conn.writeFailed(err),
        else => |e| return e,
    };
    const in = try conn.response();

    // `NAK`, or an `ACK` for each common commit the server chose to
    // acknowledge, and then the pack. Which is which is only known by
    // looking: a line of the negotiation begins with its word, a side-band
    // line with its channel, and a bare pack with `PACK`.
    var answered = false;
    while (true) {
        const head = in.peekArray(4) catch |err| switch (err) {
            error.EndOfStream => return error.RemoteHungUp,
            error.ReadFailed => return conn.failure(),
        };
        if (answered and std.mem.eql(u8, head, "PACK")) break;
        const len = pktline.parseLength(head) orelse return error.ProtocolError;
        if (len < 4) return error.ProtocolError;
        const whole = in.peek(len) catch |err| switch (err) {
            error.EndOfStream => return error.RemoteHungUp,
            error.ReadFailed => return conn.failure(),
        };
        const line = std.mem.trimEnd(u8, whole[4..], "\n");
        if (std.mem.startsWith(u8, line, "ERR ")) {
            conn.setMessage(line[4..]);
            return error.RemoteError;
        }
        const negotiation = std.mem.eql(u8, line, "NAK") or std.mem.startsWith(u8, line, "ACK ") or
            std.mem.startsWith(u8, line, "shallow ") or std.mem.startsWith(u8, line, "unshallow ");
        if (!negotiation) {
            if (!answered) return error.ProtocolError;
            break;
        }
        in.toss(len);
        answered = true;
    }
    var receive = receive_options;
    receive.progress = progress;
    if (band == .none) {
        return indexpack.receive(gpa, io, db, pack_dir, in, receive) catch |err| switch (err) {
            error.ReadFailed => conn.failure(),
            else => |e| e,
        };
    }
    return receiveSideband(gpa, io, conn, in, db, pack_dir, progress, receive);
}

fn writeFetchV0(
    w: *Io.Writer,
    adv: *const protocol.Advertisement,
    request: Request,
    negotiator: *Negotiator,
    band: bool,
    no_progress: bool,
) (pktline.WriteError || Negotiator.NegotiateError)!void {
    for (request.wants, 0..) |oid, i| {
        if (i != 0) {
            try pktline.print(w, "want {f}\n", .{oid});
            continue;
        }
        var caps_buffer: [512]u8 = undefined;
        var caps: Io.Writer = .fixed(&caps_buffer);
        const c = &caps;
        if (adv.has("side-band-64k")) {
            try c.writeAll(" side-band-64k");
        } else if (band) try c.writeAll(" side-band");
        if (adv.has("thin-pack")) try c.writeAll(" thin-pack");
        if (no_progress and adv.has("no-progress")) try c.writeAll(" no-progress");
        if (request.include_tag and adv.has("include-tag")) try c.writeAll(" include-tag");
        if (adv.has("ofs-delta")) try c.writeAll(" ofs-delta");
        if (adv.has("agent")) try c.print(" agent={s}", .{protocol.agent});
        if (adv.has("object-format")) try c.print(" object-format={s}", .{adv.kind.name()});
        try pktline.print(w, "want {f}{s}\n", .{ oid, caps.buffered() });
    }
    try pktline.flush(w);
    var sent: usize = 0;
    while (sent < v0_haves) : (sent += 1) {
        const oid = (try negotiator.next()) orelse break;
        try pktline.print(w, "have {f}\n", .{oid});
    }
    try pktline.write(w, "done\n");
}

/// git's default negotiator: this repository's commits, newest first, less
/// whatever is known to be common.
const Negotiator = struct {
    gpa: Allocator,
    io: Io,
    db: *Odb,
    arena: std.heap.ArenaAllocator,
    nodes: Oid.Map(Node) = .empty,
    queue: std.PriorityQueue(Queued, void, Queued.newerFirst) = .empty,
    /// Commits queued and not yet taken that are not known to be common.
    non_common: usize = 0,

    const Node = struct {
        seen: bool = false,
        popped: bool = false,
        common: bool = false,
        /// A tip the server is known to have: offered, but nothing below it.
        common_ref: bool = false,
        loaded: bool = false,
        time: i64 = 0,
        parents: []const Oid = &.{},
    };

    const Queued = struct {
        time: i64,
        oid: Oid,

        fn newerFirst(_: void, a: Queued, b: Queued) std.math.Order {
            if (a.time != b.time) return std.math.order(b.time, a.time);
            return a.oid.order(b.oid);
        }
    };

    const NegotiateError = odb_mod.Error || object.ParseError || Allocator.Error;

    fn deinit(n: *Negotiator) void {
        n.arena.deinit();
        n.nodes.deinit(n.gpa);
        n.queue.deinit(n.gpa);
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
            defer n.db.gpa.free(found.bytes);
            switch (found.type) {
                .tag => {
                    var tag = try object.Tag.parse(n.gpa, n.db.kind, found.bytes);
                    defer tag.deinit();
                    oid = tag.target;
                    continue;
                },
                .commit => {},
                else => return null,
            }
            var commit = try object.Commit.parse(n.gpa, n.db.kind, found.bytes);
            defer commit.deinit();
            const parents = try n.arena.allocator().dupe(Oid, commit.parents);
            const gop = try n.nodes.getOrPut(n.gpa, oid);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.time = commit.committer.when_secs;
            gop.value_ptr.parents = parents;
            gop.value_ptr.loaded = true;
            return .{ .oid = oid, .node = gop.value_ptr };
        }
    }

    fn push(n: *Negotiator, oid: Oid, node: *Node) NegotiateError!void {
        if (node.seen) return;
        node.seen = true;
        if (!node.common) n.non_common += 1;
        try n.queue.push(n.gpa, .{ .time = node.time, .oid = oid });
    }

    fn setCommon(n: *Negotiator, node: *Node) void {
        if (node.common) return;
        node.common = true;
        if (node.seen and !node.popped) n.non_common -= 1;
    }

    /// Start the walk from a tip of this repository.
    fn addTip(n: *Negotiator, tip: Oid) NegotiateError!void {
        const found = (try n.load(tip)) orelse return;
        try n.push(found.oid, found.node);
    }

    /// A tip the server has too: offered first, and nothing below it.
    fn knownCommon(n: *Negotiator, tip: Oid) NegotiateError!void {
        const found = (try n.load(tip)) orelse return;
        if (found.node.seen) return;
        found.node.common_ref = true;
        try n.push(found.oid, found.node);
    }

    /// The next commit to offer, or `null` when nothing is left that the
    /// server might not have.
    fn next(n: *Negotiator) NegotiateError!?Oid {
        while (true) {
            if (n.non_common == 0) return null;
            const item = n.queue.pop() orelse return null;
            var node = n.nodes.getPtr(item.oid).?;
            node.popped = true;
            const common = node.common;
            if (!common) n.non_common -= 1;
            const below_common = common or node.common_ref;
            const parents = node.parents;
            for (parents) |parent| {
                const found = (try n.load(parent)) orelse continue;
                if (below_common) n.setCommon(found.node);
                try n.push(found.oid, found.node);
            }
            // `load` may have moved the node.
            node = n.nodes.getPtr(item.oid).?;
            if (common) continue;
            return item.oid;
        }
    }

    /// The server has `oid`. Returns whether it was already known to be
    /// common.
    fn ack(n: *Negotiator, oid: Oid) NegotiateError!bool {
        const found = (try n.load(oid)) orelse return false;
        const known = found.node.common;
        n.setCommon(found.node);
        // Everything below it the walk has already reached is common too;
        // what it has not reached yet is marked as it is taken.
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(n.gpa);
        try stack.append(n.gpa, found.oid);
        while (stack.pop()) |current| {
            const node = n.nodes.getPtr(current) orelse continue;
            if (!node.seen) continue;
            for (node.parents) |parent| {
                const parent_node = n.nodes.getPtr(parent) orelse continue;
                if (parent_node.common) continue;
                n.setCommon(parent_node);
                try stack.append(n.gpa, parent);
            }
        }
        return known;
    }
};

const testing = std.testing;
const testgit = @import("testgit.zig");
const testremote = @import("testremote.zig");
const repo_mod = @import("repo.zig");
const objectwalk = @import("objectwalk.zig");
const pack_mod = @import("pack.zig");

/// A conversation with `git upload-pack` run on this machine, in `dir`.
fn uploadPack(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, dir: Io.Dir, v2: bool) !*Connection {
    return connection.Process.start(gpa, io, .{ .environ = env }, .{
        .argv = &.{ "git", "upload-pack", "." },
        .cwd = .{ .dir = dir },
        .set = if (v2) &.{.{ .name = "GIT_PROTOCOL", .value = "version=2" }} else &.{},
    });
}

test "a fetch from git upload-pack negotiates, in v2 and in v0, and brings only what is missing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();

    for ([_]bool{ true, false }) |v2| {
        var source = try testremote.historyRepo(gpa, io, 6);
        defer source.deinit();
        // A v0 server gives only what a ref names.
        try source.exec(io, &.{ "branch", "older", "HEAD~2" });
        const old = try source.line(io, &.{ "rev-parse", "older" });
        defer gpa.free(old);
        const head = try source.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(head);

        var target_git = try testgit.Repo.init(gpa, io, &.{"--bare"});
        defer target_git.deinit();
        var repo = try repo_mod.Repository.open(gpa, io, target_git.dir, .{});
        defer repo.deinit(io);
        var pack_dir = try target_git.dir.openDir(io, "objects/pack", .{ .iterate = true });
        defer pack_dir.close(io);

        // First everything up to `old`, from nothing.
        {
            const conn = try uploadPack(gpa, io, &env, source.dir, v2);
            defer conn.close(io);
            var adv = try protocol.readAdvertisement(gpa, conn, repo.kind);
            defer adv.deinit();
            try testing.expectEqual(if (v2) protocol.Version.v2 else protocol.Version.v0, adv.version);
            const want = try Oid.parse(.sha1, old);
            const result = try fetch(gpa, io, conn, &adv, &repo.odb, pack_dir, .{ .wants = &.{want}, .tips = &.{} }, .{});
            try testing.expect(result.objects > 0);
            try objectwalk.checkConnected(gpa, io, &repo.odb, &.{want}, null, null);
            try target_git.exec(io, &.{ "update-ref", "refs/heads/main", old });
        }
        // Then the rest, offering what is here: only what is new comes.
        {
            const conn = try uploadPack(gpa, io, &env, source.dir, v2);
            defer conn.close(io);
            var adv = try protocol.readAdvertisement(gpa, conn, repo.kind);
            defer adv.deinit();
            var list = try protocol.listRefs(gpa, conn, &adv, .{ .prefixes = &.{ "refs/heads/", "refs/tags/" } });
            defer list.deinit();
            try testing.expect(list.find("refs/heads/main").?.oid.eql(try Oid.parse(.sha1, head)));
            try testing.expect(list.find("refs/tags/v1").?.peeled != null);
            const want = try Oid.parse(.sha1, head);
            const result = try fetch(gpa, io, conn, &adv, &repo.odb, pack_dir, .{
                .wants = &.{want},
                .tips = &.{try Oid.parse(.sha1, old)},
            }, .{});
            // Two commits, each with a root tree, three subtrees... far
            // fewer than the whole history; and the tag pointing at the
            // head came with them.
            const whole = try source.line(io, &.{ "rev-list", "--objects", "--count", "--all" });
            defer gpa.free(whole);
            try testing.expect(result.objects < try std.fmt.parseInt(u32, whole, 10) / 2);
            const tag_hex = try source.line(io, &.{ "rev-parse", "v1" });
            defer gpa.free(tag_hex);
            try testing.expect(try repo.odb.exists(io, try Oid.parse(.sha1, tag_hex)));
            try objectwalk.checkConnected(gpa, io, &repo.odb, &.{want}, null, null);
        }
        try target_git.exec(io, &.{ "update-ref", "refs/heads/main", head });
        try target_git.exec(io, &.{ "fsck", "--strict", "--no-dangling" });
    }
}

test "the server's refusal comes back by name, with its words" {
    const gpa = testing.allocator;
    const io = testing.io;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var source = try testremote.historyRepo(gpa, io, 2);
    defer source.deinit();
    var target_git = try testgit.Repo.init(gpa, io, &.{"--bare"});
    defer target_git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, target_git.dir, .{});
    defer repo.deinit(io);
    var pack_dir = try target_git.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    const conn = try uploadPack(gpa, io, &env, source.dir, true);
    defer conn.close(io);
    var adv = try protocol.readAdvertisement(gpa, conn, repo.kind);
    defer adv.deinit();
    // An object the server does not have.
    const nowhere = hash.Hasher.object(.sha1, "blob", "not on the server");
    try testing.expectError(error.RemoteError, fetch(gpa, io, conn, &adv, &repo.odb, pack_dir, .{ .wants = &.{nowhere}, .tips = &.{} }, .{}));
    try testing.expect(std.mem.indexOf(u8, conn.message(), "not our ref") != null);
}
