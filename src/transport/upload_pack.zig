//! The serving side of a fetch: git's `upload-pack`.
//!
//! A repository answers the protocol a fetching client speaks: its refs
//! advertised, the client's `want`s checked against them, its `have`s
//! acknowledged the way `multi_ack_detailed` acknowledges them until the
//! server is ready, a shallow boundary drawn by depth, by date or by ref
//! when one is asked for, and a pack of what the client lacks, filtered as
//! a partial clone asks, sent on the side-band. Protocol v2's `ls-refs`,
//! `fetch` and, under `uploadpack.advertiseBundleURIs`, `bundle-uri` are
//! answered, and v0's single conversation, over a pipe where the server
//! remembers the conversation (`serve`) and over HTTP where every request
//! carries all of it again (`serveRequest`, git's `--stateless-rpc`).
//!
//! relic uses it in process for a `file://` remote, as git runs its own
//! `upload-pack` for one — which is how a shallow or partial clone of a
//! repository on the same machine is had — and a program of one's own can
//! serve a repository with it over whatever carries bytes.

const Self = @This();

const std = @import("std");
const decimal = @import("../text.zig").decimal;
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const pkt_line = @import("../codec.zig").pkt_line;
const protocol = @import("../wire.zig").protocol;
const object_walk = @import("../walk/object/walk.zig");
const rev_parse = @import("../rev_walk/rev_parse.zig");
const filter_spec = @import("../wire.zig").filter_spec;
const ignore = @import("../patterns.zig").ignore;
const rev_walk = @import("../walk/walk.zig");
const local = @import("local.zig");
const in_process = @import("in_process.zig");
const connection = @import("../wire.zig").connection;
const promisors = @import("../wire.zig").promisors;
const side_band = @import("../wire.zig").side_band;
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;

/// Errors from serving.
pub const Error = error{
    /// The client asked for something malformed, or out of order.
    ProtocolError,
    /// The client wanted an object this server does not offer. The client
    /// was told with an `ERR` line.
    NotOurRef,
    /// A filter this server does not apply, or filtering while it is not
    /// allowed. The client was told.
    FilterRefused,
    /// Writing to the client failed.
    WriteFailed,
} || Io.Reader.Error || odb_mod.Error || object_walk.Error || local.Error || Allocator.Error || Io.Cancelable;

/// What the server allows, as git's `upload_pack.*` settings say; `null`
/// takes the served repository's own setting.
pub const Options = struct {
    stateless: bool = false,
    /// `uploadpack.allowFilter`.
    allow_filter: ?bool = null,
    /// `uploadpack.allowTipSHA1InWant`: any ref's tip, advertised or not.
    allow_tip: ?bool = null,
    /// `uploadpack.allowReachableSHA1InWant`: anything a ref reaches.
    allow_reachable: ?bool = null,
    /// `uploadpack.allowAnySHA1InWant`: anything at all.
    allow_any: ?bool = null,
    /// `uploadpack.advertiseBundleURIs`: protocol v2's `bundle-uri`
    /// command, answered with every `bundle.*` setting.
    advertise_bundle_uris: ?bool = null,
};

/// A repository, serving.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    remote: *local.Remote,
    version: protocol.Version,
    stateless: bool,
    allow_filter: bool,
    allow_tip: bool,
    allow_reachable: bool,
    allow_any: bool,
    advertise_bundle_uris: bool,
    /// A client answered `promisor-remote` taking one of this repository's
    /// promisor remotes, so what that remote promises and this repository
    /// lacks is left out of a pack: git's `--missing=allow-promisor`.
    promisor_taken: bool = false,

    /// Serve `remote` in `version`; `stateless` for HTTP, where every
    /// request stands alone.
    pub fn init(gpa: Allocator, io: Io, remote: *local.Remote, version: protocol.Version, options: Options) Server {
        const config = remote.repo.configuration();
        const any = options.allow_any orelse (config.getBool("uploadpack.allowanysha1inwant", false) catch false);
        return .{
            .gpa = gpa,
            .io = io,
            .remote = remote,
            .version = version,
            .stateless = options.stateless,
            .allow_filter = options.allow_filter orelse (config.getBool("uploadpack.allowfilter", false) catch false),
            .allow_tip = any or (options.allow_tip orelse (config.getBool("uploadpack.allowtipsha1inwant", false) catch false)),
            .allow_reachable = any or (options.allow_reachable orelse (config.getBool("uploadpack.allowreachablesha1inwant", false) catch false)),
            .allow_any = any,
            .advertise_bundle_uris = options.advertise_bundle_uris orelse advertisesBundleUris(config),
        };
    }

    fn db(s: *Server) *odb_mod.Odb {
        return s.remote.repo.objectDatabase();
    }

    fn kind(s: *Server) hash.Kind {
        return s.remote.repo.objectFormat();
    }

    /// The server's first message: its refs and capabilities in v0, its
    /// capabilities in v2.
    pub fn advertise(s: *Server, w: *Io.Writer) Self.Error!void {
        (switch (s.version) {
            .v2 => s.advertiseV2(w),
            .v0, .v1 => s.advertiseV0(w),
        }) catch |err| switch (err) {
            error.PacketTooLong => return error.WriteFailed,
            else => |e| return e,
        };
    }

    fn advertiseV2(s: *Server, w: *Io.Writer) (pkt_line.WriteError || Allocator.Error)!void {
        try pkt_line.write(w, "version 2\n");
        try pkt_line.print("agent={s}\n", .{protocol.agent}, w);
        try pkt_line.write(w, "ls-refs=unborn\n");
        try pkt_line.write(w, if (s.allow_filter) "fetch=shallow wait-for-done filter\n" else "fetch=shallow wait-for-done\n");
        try pkt_line.write(w, "server-option\n");
        try pkt_line.print("object-format={s}\n", .{s.kind().name()}, w);
        if (s.advertise_bundle_uris) try pkt_line.write(w, "bundle-uri\n");
        // `promisor.advertise`: the promisor remotes this one borrows from.
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        if (try promisors.advertisement(arena_state.allocator(), s.remote.repo.configuration(), null)) |info| {
            try pkt_line.print("promisor-remote={s}\n", .{info}, w);
        }
        try pkt_line.flush(w);
    }

    fn capabilitiesV0(s: *Server, out: *std.ArrayList(u8), head_target: ?[]const u8) Allocator.Error!void {
        const gpa = s.gpa;
        try out.appendSlice(gpa, "multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed");
        if (s.allow_tip) try out.appendSlice(gpa, " allow-tip-sha1-in-want");
        if (s.allow_reachable) try out.appendSlice(gpa, " allow-reachable-sha1-in-want");
        if (s.stateless) try out.appendSlice(gpa, " no-done");
        if (head_target) |t| try out.print(gpa, " symref=HEAD:{s}", .{t});
        if (s.allow_filter) try out.appendSlice(gpa, " filter");
        try out.print(gpa, " object-format={s} agent={s}", .{ s.kind().name(), protocol.agent });
    }

    fn advertiseV0(s: *Server, w: *Io.Writer) (pkt_line.WriteError || Error)!void {
        var refs = try s.remote.listRefs(s.gpa, s.io, &.{});
        defer refs.deinit();
        var caps: std.ArrayList(u8) = .empty;
        defer caps.deinit(s.gpa);
        var head_target: ?[]const u8 = null;
        for (refs.refs) |ref| {
            if (std.mem.eql(u8, ref.name, "HEAD")) head_target = ref.symref_target;
        }
        try s.capabilitiesV0(&caps, head_target);
        var first = true;
        for (refs.refs) |ref| {
            if (ref.unborn) continue;
            if (first) {
                try pkt_line.print("{f} {s}\x00{s}\n", .{ ref.oid, ref.name, caps.items }, w);
                first = false;
            } else try pkt_line.print("{f} {s}\n", .{ ref.oid, ref.name }, w);
            if (ref.peeled) |p| try pkt_line.print("{f} {s}^{{}}\n", .{ p, ref.name }, w);
        }
        if (first) try pkt_line.print("{f} capabilities^{{}}\x00{s}\n", .{ Oid.zero(s.kind()), caps.items }, w);
        // A shallow server says where its history ends, as git's does.
        const boundary = try s.gpa.alloc(Oid, s.db().shallow.count());
        defer s.gpa.free(boundary);
        var it = s.db().shallow.keyIterator();
        var i: usize = 0;
        while (it.next()) |oid| : (i += 1) boundary[i] = oid.*;
        std.mem.sort(Oid, boundary, {}, struct {
            fn lessThan(_: void, a: Oid, b: Oid) bool {
                return a.order(b) == .lt;
            }
        }.lessThan);
        for (boundary) |oid| try pkt_line.print("shallow {f}\n", .{oid}, w);
        try pkt_line.flush(w);
    }

    /// A whole conversation over a pipe: the advertisement, then every
    /// request until the client ends it.
    pub fn serve(s: *Server, in: *Io.Reader, out: *Io.Writer) Self.Error!void {
        try s.advertise(out);
        out.flush() catch return error.WriteFailed;
        switch (s.version) {
            .v2 => while (try s.commandV2(in, out)) {},
            .v0, .v1 => try s.conversationV0(in, out),
        }
        out.flush() catch return error.WriteFailed;
    }

    /// One request of a stateless conversation: a v2 command, or a v0
    /// round of wants and haves.
    pub fn serveRequest(s: *Server, in: *Io.Reader, out: *Io.Writer) Self.Error!void {
        switch (s.version) {
            .v2 => _ = try s.commandV2(in, out),
            .v0, .v1 => try s.conversationV0(in, out),
        }
        out.flush() catch return error.WriteFailed;
    }

    // ------------------------------------------------------------------
    // Protocol v2
    // ------------------------------------------------------------------

    /// Read and answer one command. `false` at the end of the input.
    fn commandV2(s: *Server, in: *Io.Reader, out: *Io.Writer) Error!bool {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var command: ?[]const u8 = null;
        // The command and its capabilities, to the delimiter.
        while (true) {
            const packet = pkt_line.read(in) catch |err| switch (err) {
                error.EndOfStream => return false,
                error.ReadFailed => return error.ReadFailed,
                else => return error.ProtocolError,
            };
            switch (packet) {
                .flush => if (command == null) continue else return error.ProtocolError,
                .delim => break,
                .response_end => return false,
                .data => |raw| {
                    const line = std.mem.trimEnd(u8, raw, "\n");
                    if (std.mem.startsWith(u8, line, "command=")) command = try arena.dupe(u8, line["command=".len..]);
                    if (std.mem.startsWith(u8, line, "promisor-remote=")) {
                        const taken = try promisors.acceptedByClient(arena, s.remote.repo.configuration(), line["promisor-remote=".len..], null);
                        if (taken.len != 0) s.promisor_taken = true;
                    }
                },
            }
        }
        var args: std.ArrayList([]const u8) = .empty;
        while (true) {
            const packet = pkt_line.read(in) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                else => return error.ProtocolError,
            };
            switch (packet) {
                .flush => break,
                .data => |raw| try args.append(arena, try arena.dupe(u8, std.mem.trimEnd(u8, raw, "\n"))),
                else => return error.ProtocolError,
            }
        }
        const name = command orelse return error.ProtocolError;
        if (std.mem.eql(u8, name, "ls-refs")) {
            try s.lsRefs(args.items, out);
        } else if (std.mem.eql(u8, name, "fetch")) {
            try s.fetchV2(arena, args.items, out);
        } else if (std.mem.eql(u8, name, "bundle-uri") and s.advertise_bundle_uris) {
            try s.bundleUri(arena, args.items, out);
        } else {
            try s.sendError(out, "unknown command");
            return error.ProtocolError;
        }
        out.flush() catch return error.WriteFailed;
        return true;
    }

    fn lsRefs(s: *Server, args: []const []const u8, out: *Io.Writer) Error!void {
        var peel = false;
        var symrefs = false;
        var unborn = false;
        var prefixes: std.ArrayList([]const u8) = .empty;
        defer prefixes.deinit(s.gpa);
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "peel")) peel = true;
            if (std.mem.eql(u8, arg, "symrefs")) symrefs = true;
            if (std.mem.eql(u8, arg, "unborn")) unborn = true;
            if (std.mem.startsWith(u8, arg, "ref-prefix ")) try prefixes.append(s.gpa, arg["ref-prefix ".len..]);
        }
        var refs = try s.remote.listRefs(s.gpa, s.io, prefixes.items);
        defer refs.deinit();
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(s.gpa);
        for (refs.refs) |ref| {
            line.clearRetainingCapacity();
            if (ref.unborn) {
                if (!unborn) continue;
                try line.print(s.gpa, "unborn {s}", .{ref.name});
            } else try line.print(s.gpa, "{f} {s}", .{ ref.oid, ref.name });
            if (symrefs) if (ref.symref_target) |t| try line.print(s.gpa, " symref-target:{s}", .{t});
            if (peel) if (ref.peeled) |p| try line.print(s.gpa, " peeled:{f}", .{p});
            try line.append(s.gpa, '\n');
            pkt_line.write(out, line.items) catch |err| return writeError(err);
        }
        pkt_line.flush(out) catch |err| return writeError(err);
    }

    /// git's `bundle_uri_command`: no arguments, and the served
    /// repository's `bundle.*` settings as `key=value` lines.
    fn bundleUri(s: *Server, arena: Allocator, args: []const []const u8, out: *Io.Writer) Error!void {
        if (args.len != 0) return s.refuse(out, try arena.print("bundle-uri: unexpected argument: '{s}'", .{args[0]}));
        for (try bundleSettings(arena, s.remote.repo.configuration())) |line| pkt_line.write(out, line) catch |err| return writeError(err);
        pkt_line.flush(out) catch |err| return writeError(err);
    }

    fn fetchV2(s: *Server, arena: Allocator, args: []const []const u8, out: *Io.Writer) Error!void {
        var n: Negotiation = .{ .server = s, .arena = arena };
        var seen_haves = false;
        var haves: std.ArrayList(Oid) = .empty;
        var done = false;
        var wait_for_done = false;
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "want ")) {
                const oid = s.parseOid(arg["want ".len..]) orelse return s.refuse(out, "protocol error: bad want");
                if (!try s.db().exists(s.io, oid)) return s.notOurRef(out, oid);
                if (!n.wanted.contains(oid)) {
                    try n.wanted.put(arena, oid, {});
                    try n.wants.append(arena, oid);
                }
            } else if (std.mem.startsWith(u8, arg, "have ")) {
                const oid = s.parseOid(arg["have ".len..]) orelse return s.refuse(out, "protocol error: bad have");
                try haves.append(arena, oid);
                seen_haves = true;
            } else if (std.mem.eql(u8, arg, "done")) {
                done = true;
            } else if (std.mem.eql(u8, arg, "wait-for-done")) {
                wait_for_done = true;
            } else if (std.mem.eql(u8, arg, "ofs-delta")) {
                n.ofs_delta = true;
            } else if (std.mem.eql(u8, arg, "include-tag")) {
                n.include_tag = true;
            } else if (std.mem.eql(u8, arg, "thin-pack") or std.mem.eql(u8, arg, "no-progress") or std.mem.eql(u8, arg, "sideband-all")) {
                // A full pack is always sent, and no progress.
            } else if (try n.takeShallowArg(arg)) {
                // Recorded.
            } else if (std.mem.startsWith(u8, arg, "filter ")) {
                if (!s.allow_filter) return s.refuse(out, "unexpected line: 'filter'");
                n.filter = try n.readFilter(out, arg["filter ".len..]);
            } else if (std.mem.startsWith(u8, arg, "packfile-uris ") or std.mem.startsWith(u8, arg, "want-ref ")) {
                return s.refuse(out, "unexpected line");
            }
        }
        if (n.wants.items.len == 0 and !wait_for_done) return;

        var send_pack = !seen_haves;
        if (seen_haves) {
            for (haves.items) |oid| {
                if (!try s.db().exists(s.io, oid)) continue;
                _ = try n.gotHave(oid);
            }
            if (done) {
                send_pack = true;
            } else {
                (write: {
                    pkt_line.write(out, "acknowledgments\n") catch |e| break :write e;
                    if (n.have_obj.items.len == 0) pkt_line.write(out, "NAK\n") catch |e| break :write e;
                    for (n.have_obj.items) |oid| pkt_line.print("ACK {f}\n", .{oid}, out) catch |e| break :write e;
                }) catch |err| return writeError(err);
                if (!wait_for_done and try n.okToGiveUp()) {
                    pkt_line.write(out, "ready\n") catch |err| return writeError(err);
                    pkt_line.delim(out) catch |err| return writeError(err);
                    send_pack = true;
                } else {
                    pkt_line.flush(out) catch |err| return writeError(err);
                }
            }
        }
        if (!send_pack) return;

        if (n.depth != 0 or n.deepen_since != null or n.deepen_not.items.len != 0 or n.client_shallows.items.len != 0 or s.db().shallow.count() != 0) {
            pkt_line.write(out, "shallow-info\n") catch |err| return writeError(err);
            if (!try n.sendShallowList(out) and s.db().shallow.count() != 0) try n.deepen(out, infinite_depth);
            pkt_line.delim(out) catch |err| return writeError(err);
        }
        pkt_line.write(out, "packfile\n") catch |err| return writeError(err);
        try n.sendPack(out, .large);
    }

    fn conversationV0(s: *Server, in: *Io.Reader, out: *Io.Writer) Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var n: Negotiation = .{ .server = s, .arena = arena };

        // The client's needs, to a flush.
        var caps: []const u8 = "";
        var advertised: ?protocol.RefList = null;
        defer if (advertised) |*r| r.deinit();
        var any = false;
        while (true) {
            const packet = pkt_line.read(in) catch |err| switch (err) {
                // Asked nothing: `ls-remote`, or a client that has all of it.
                error.EndOfStream => if (!any) return else return error.ProtocolError,
                error.ReadFailed => return error.ReadFailed,
                else => return error.ProtocolError,
            };
            any = true;
            const raw = switch (packet) {
                .flush => break,
                .data => |d| d,
                else => return error.ProtocolError,
            };
            const line = std.mem.trimEnd(u8, raw, "\n");
            if (std.mem.startsWith(u8, line, "want ")) {
                const rest = line["want ".len..];
                const hex_len = s.kind().hexLen();
                if (rest.len < hex_len) return s.refuse(out, "protocol error: bad want");
                const oid = s.parseOid(rest[0..hex_len]) orelse return s.refuse(out, "protocol error: bad want");
                if (n.wants.items.len == 0 and rest.len > hex_len) caps = try arena.dupe(u8, rest[hex_len..]);
                if (!try s.wantAllowed(oid, &advertised)) return s.notOurRef(out, oid);
                if (!n.wanted.contains(oid)) {
                    try n.wanted.put(arena, oid, {});
                    try n.wants.append(arena, oid);
                }
            } else if (try n.takeShallowArg(line)) {
                // Recorded.
            } else if (std.mem.startsWith(u8, line, "filter ")) {
                if (!s.allow_filter) return s.refuse(out, "filtering not allowed");
                n.filter = try n.readFilter(out, line["filter ".len..]);
            } else return s.refuse(out, "protocol error: unexpected line");
        }
        if (n.wants.items.len == 0) return;

        var multi_ack: u2 = 0;
        var no_done = false;
        var band: Band = .none;
        var it = std.mem.tokenizeScalar(u8, caps, ' ');
        while (it.next()) |cap| {
            if (std.mem.eql(u8, cap, "multi_ack_detailed")) multi_ack = 2;
            if (std.mem.eql(u8, cap, "multi_ack") and multi_ack == 0) multi_ack = 1;
            if (std.mem.eql(u8, cap, "no-done")) no_done = true;
            if (std.mem.eql(u8, cap, "side-band-64k")) band = .large;
            if (std.mem.eql(u8, cap, "side-band") and band == .none) band = .small;
            if (std.mem.eql(u8, cap, "ofs-delta")) n.ofs_delta = true;
            if (std.mem.eql(u8, cap, "include-tag")) n.include_tag = true;
            if (std.mem.eql(u8, cap, "deepen-relative")) n.deepen_relative = true;
        }

        if (n.depth != 0 or n.deepen_since != null or n.deepen_not.items.len != 0 or n.client_shallows.items.len != 0) {
            if (try n.sendShallowList(out)) pkt_line.flush(out) catch |err| return writeError(err);
        }
        out.flush() catch return error.WriteFailed;

        if (!try n.commonCommits(in, out, multi_ack, no_done)) return;
        try n.sendPack(out, band);
    }

    /// Whether a v0 client may want `oid`: an advertised ref's tip, or more
    /// where `uploadpack.allow*SHA1InWant` says so — a hidden ref's tip
    /// for either of tip and reachable, as git's `is_our_ref` allows it.
    fn wantAllowed(s: *Server, oid: Oid, advertised: *?protocol.RefList) Error!bool {
        if (s.allow_any) return s.db().exists(s.io, oid);
        const with_hidden = s.allow_tip or s.allow_reachable;
        if (advertised.* == null) advertised.* = if (with_hidden)
            try s.remote.listAllRefs(s.gpa, s.io, &.{})
        else
            try s.remote.listRefs(s.gpa, s.io, &.{});
        const refs = advertised.*.?.refs;
        for (refs) |ref| {
            if (ref.unborn) continue;
            if (ref.oid.eql(oid)) return true;
            if (ref.peeled) |p| if (p.eql(oid)) return true;
        }
        if (s.allow_reachable) {
            if (!try s.db().exists(s.io, oid)) return false;
            const header = try s.db().readHeader(s.io, oid);
            if (header.type != .commit) return false;
            for (refs) |ref| {
                if (ref.unborn) continue;
                const tip = ref.peeled orelse ref.oid;
                if ((try s.db().readHeader(s.io, tip)).type != .commit) continue;
                if (rev_walk.isAncestor(s.gpa, s.io, s.db(), .{ .ancestor = oid, .descendant = tip }, .{}) catch false) return true;
            }
        }
        return false;
    }

    fn parseOid(s: *Server, text: []const u8) ?Oid {
        return Oid.parse(s.kind(), std.mem.trim(u8, text, " ")) catch null;
    }

    fn sendError(_: *Server, out: *Io.Writer, text: []const u8) Error!void {
        pkt_line.print("ERR upload-pack: {s}\n", .{text}, out) catch return error.WriteFailed;
        out.flush() catch return error.WriteFailed;
    }

    fn refuse(s: *Server, out: *Io.Writer, text: []const u8) Error {
        try s.sendError(out, text);
        return if (std.mem.find(u8, text, "filter") != null) error.FilterRefused else error.ProtocolError;
    }

    fn notOurRef(s: *Server, out: *Io.Writer, oid: Oid) Error {
        var buf: [128]u8 = undefined;
        try s.sendError(out, std.mem.print(&buf, "not our ref {f}", .{oid}) catch "not our ref");
        return error.NotOurRef;
    }
};

/// git's `INFINITE_DEPTH`: `--unshallow`.
const infinite_depth: u32 = 0x7fff_ffff;

const Band = side_band.Band;

/// One fetch's state on the server: what is wanted, what the client has,
/// and where its history is cut.
const Negotiation = struct {
    server: *Server,
    arena: Allocator,
    wants: std.ArrayList(Oid) = .empty,
    wanted: Oid.Set = .empty,
    /// Commits the client has, and their parents: git's `THEY_HAVE`.
    they_have: Oid.Set = .empty,
    /// The client's objects this server has too, in the order met, each
    /// once: what v2 acknowledges.
    have_obj: std.ArrayList(Oid) = .empty,
    oldest_have: i64 = 0,
    ofs_delta: bool = false,
    include_tag: bool = false,
    filter: object_walk.Filter = .none,
    // The boundary.
    client_shallows: std.ArrayList(Oid) = .empty,
    client_shallow_set: Oid.Set = .empty,
    depth: u32 = 0,
    deepen_relative: bool = false,
    deepen_since: ?i64 = null,
    deepen_not: std.ArrayList([]const u8) = .empty,
    /// Commits within the depth asked for: git's `NOT_SHALLOW`.
    not_shallow: Oid.Set = .empty,
    /// The boundary the pack is walked with.
    boundary: Oid.Set = .empty,
    /// Commits the client turns out to have whole now: sent as
    /// `unshallow`, and walked as had.
    edges: std.ArrayList(Oid) = .empty,
    /// Parents of those, wanted.
    extra_wants: std.ArrayList(Oid) = .empty,

    fn io(n: *Negotiation) Io {
        return n.server.io;
    }

    fn db(n: *Negotiation) *odb_mod.Odb {
        return n.server.db();
    }

    /// `shallow`, `deepen`, `deepen-since`, `deepen-not`, `deepen-relative`.
    fn takeShallowArg(n: *Negotiation, line: []const u8) Error!bool {
        const s = n.server;
        if (std.mem.startsWith(u8, line, "shallow ")) {
            const oid = s.parseOid(line["shallow ".len..]) orelse return error.ProtocolError;
            // One this server does not have is not a boundary it can move.
            if (try n.db().exists(n.io(), oid) and (try n.db().readHeader(n.io(), oid)).type == .commit) {
                if (!n.client_shallow_set.contains(oid)) {
                    try n.client_shallow_set.put(n.arena, oid, {});
                    try n.client_shallows.append(n.arena, oid);
                }
            }
            return true;
        }
        if (std.mem.startsWith(u8, line, "deepen-since ")) {
            // git's `parse_timestamp(arg, &end, 0)`, the whole argument.
            const since = decimal.whole(u64, line["deepen-since ".len..], 0) orelse return error.ProtocolError;
            n.deepen_since = std.math.cast(i64, since) orelse return error.ProtocolError;
            return true;
        }
        if (std.mem.startsWith(u8, line, "deepen-not ")) {
            try n.deepen_not.append(n.arena, try n.arena.dupe(u8, line["deepen-not ".len..]));
            return true;
        }
        if (std.mem.eql(u8, line, "deepen-relative")) {
            n.deepen_relative = true;
            return true;
        }
        if (std.mem.startsWith(u8, line, "deepen ")) {
            // git's `strtol(arg, &end, 0)`, the whole argument, above zero.
            const depth = decimal.whole(i64, line["deepen ".len..], 0) orelse return error.ProtocolError;
            n.depth = std.math.cast(u32, depth) orelse return error.ProtocolError;
            if (n.depth == 0) return error.ProtocolError;
            return true;
        }
        return false;
    }

    fn commit(n: *Negotiation, oid: Oid) Error!?object.Commit {
        if (!try n.db().exists(n.io(), oid)) return null;
        const found = try n.db().read(n.io(), oid);
        defer n.db().allocator().free(found.bytes);
        if (found.type != .commit) return null;
        const parsed = try object.Commit.parse(n.arena, n.db().objectFormat(), found.bytes);
        return parsed;
    }

    fn peelToCommit(n: *Negotiation, start: Oid) Error!?Oid {
        var oid = start;
        var depth: u8 = 0;
        while (depth < 16) : (depth += 1) {
            if (!try n.db().exists(n.io(), oid)) return null;
            const found = try n.db().read(n.io(), oid);
            defer n.db().allocator().free(found.bytes);
            switch (found.type) {
                .commit => return oid,
                .tag => {
                    var tag = try object.Tag.parse(n.arena, n.db().objectFormat(), found.bytes);
                    oid = tag.target;
                    tag.deinit();
                },
                else => return null,
            }
        }
        return null;
    }

    /// A have this server has: git's `do_got_oid`. Whether it was new. An
    /// object said twice, of any type, is kept once, so a client repeating
    /// one cannot grow the request without end.
    fn gotHave(n: *Negotiation, oid: Oid) Error!bool {
        if (try n.commit(oid)) |c| {
            const date = c.committer.when_secs;
            if (n.oldest_have == 0 or date < n.oldest_have) n.oldest_have = date;
            for (c.parents) |p| try n.they_have.put(n.arena, p, {});
        }
        const seen = try n.they_have.getOrPut(n.arena, oid);
        if (seen.found_existing) return false;
        try n.have_obj.append(n.arena, oid);
        return true;
    }

    /// git's `ok_to_give_up`: every want reaches something the client has,
    /// looking no further back than its oldest have.
    fn okToGiveUp(n: *Negotiation) Error!bool {
        if (n.have_obj.items.len == 0) return false;
        for (n.wants.items) |want| {
            const start = (try n.peelToCommit(want)) orelse continue;
            var seen: Oid.Set = .empty;
            var stack: std.ArrayList(Oid) = .empty;
            try stack.append(n.arena, start);
            var found = false;
            while (stack.pop()) |oid| {
                if ((try seen.getOrPut(n.arena, oid)).found_existing) continue;
                if (n.they_have.contains(oid)) {
                    found = true;
                    break;
                }
                const c = (try n.commit(oid)) orelse continue;
                if (c.committer.when_secs < n.oldest_have) continue;
                for (c.parents) |p| try stack.append(n.arena, p);
            }
            if (!found) return false;
        }
        return true;
    }

    /// git's `get_common_commits`, for v0. Whether a pack is to follow.
    fn commonCommits(n: *Negotiation, in: *Io.Reader, out: *Io.Writer, multi_ack_in: u2, no_done: bool) Error!bool {
        const s = n.server;
        var multi_ack = multi_ack_in;
        _ = &multi_ack;
        var last: ?Oid = null;
        var got_common = false;
        var got_other = false;
        var sent_ready = false;
        while (true) {
            const packet = pkt_line.read(in) catch |err| switch (err) {
                error.EndOfStream => return false,
                error.ReadFailed => return error.ReadFailed,
                else => return error.ProtocolError,
            };
            const raw = switch (packet) {
                .data => |d| d,
                .flush => {
                    (write: {
                        if (multi_ack == 2 and got_common and !got_other and try n.okToGiveUp()) {
                            sent_ready = true;
                            pkt_line.print("ACK {f} ready\n", .{last.?}, out) catch |e| break :write e;
                        }
                        if (n.have_obj.items.len == 0 or multi_ack != 0) pkt_line.write(out, "NAK\n") catch |e| break :write e;
                        if (no_done and sent_ready) {
                            pkt_line.print("ACK {f}\n", .{last.?}, out) catch |e| break :write e;
                            out.flush() catch |e| break :write e;
                            return true;
                        }
                        out.flush() catch |e| break :write e;
                    }) catch |err| return writeError(err);
                    if (s.stateless) return false;
                    got_common = false;
                    got_other = false;
                    continue;
                },
                else => return error.ProtocolError,
            };
            const line = std.mem.trimEnd(u8, raw, "\n");
            if (std.mem.startsWith(u8, line, "have ")) {
                const oid = s.parseOid(line["have ".len..]) orelse return s.refuse(out, "protocol error: expected SHA1 list");
                if (!try n.db().exists(n.io(), oid)) {
                    got_other = true;
                    if (multi_ack != 0 and try n.okToGiveUp()) {
                        if (multi_ack == 2) {
                            sent_ready = true;
                            pkt_line.print("ACK {f} ready\n", .{oid}, out) catch |err| return writeError(err);
                        } else pkt_line.print("ACK {f} continue\n", .{oid}, out) catch |err| return writeError(err);
                    }
                    continue;
                }
                _ = try n.gotHave(oid);
                got_common = true;
                last = oid;
                (if (multi_ack == 2)
                    pkt_line.print("ACK {f} common\n", .{oid}, out)
                else if (multi_ack == 1)
                    pkt_line.print("ACK {f} continue\n", .{oid}, out)
                else if (n.have_obj.items.len == 1)
                    pkt_line.print("ACK {f}\n", .{oid}, out)
                else {}) catch |err| return writeError(err);
                continue;
            }
            if (std.mem.eql(u8, line, "done")) {
                (write: {
                    if (n.have_obj.items.len > 0) {
                        if (multi_ack != 0) pkt_line.print("ACK {f}\n", .{last.?}, out) catch |e| break :write e;
                    } else pkt_line.write(out, "NAK\n") catch |e| break :write e;
                }) catch |err| return writeError(err);
                return true;
            }
            return s.refuse(out, "protocol error: expected SHA1 list");
        }
    }

    // --------------------------------------------------------------
    // The boundary
    // --------------------------------------------------------------

    /// git's `send_shallow_list`: the boundary moved as asked, the lines
    /// that say so written. Whether anything was asked.
    fn sendShallowList(n: *Negotiation, out: *Io.Writer) Error!bool {
        if (n.depth != 0 and (n.deepen_since != null or n.deepen_not.items.len != 0)) return n.server.refuse(out, "--depth and --shallow-since (or --shallow-exclude) cannot be used together");
        if (n.depth != 0) {
            try n.deepen(out, n.depth);
            return true;
        }
        if (n.deepen_since != null or n.deepen_not.items.len != 0) {
            try n.deepenByRevList(out);
            return true;
        }
        for (n.client_shallows.items) |oid| try n.boundary.put(n.arena, oid, {});
        return false;
    }

    fn deepen(n: *Negotiation, out: *Io.Writer, depth: u32) Error!void {
        if (depth == infinite_depth and n.db().shallow.count() == 0) {
            for (n.client_shallows.items) |oid| try n.not_shallow.put(n.arena, oid, {});
        } else if (n.deepen_relative) {
            const result = try n.shallowByDepth(n.client_shallows.items, depth + 1);
            try n.sendShallow(out, result);
        } else {
            const result = try n.shallowByDepth(n.wants.items, depth);
            try n.sendShallow(out, result);
        }
        try n.sendUnshallow(out);
    }

    /// git's `get_shallow_commits`: the commits `depth` from `heads`.
    fn shallowByDepth(n: *Negotiation, heads: []const Oid, depth: u32) Error![]const Oid {
        var result: std.ArrayList(Oid) = .empty;
        var depths: Oid.Map(u32) = .empty;
        const Item = struct { oid: Oid, depth: u32 };
        var stack: std.ArrayList(Item) = .empty;
        for (heads) |head| {
            const start = (try n.peelToCommit(head)) orelse continue;
            try depths.put(n.arena, start, 0);
            try stack.append(n.arena, .{ .oid = start, .depth = 0 });
            while (stack.pop()) |item| {
                const cur = item.depth + 1;
                // The server's own boundary is one for the client too.
                if ((depth != infinite_depth and cur >= depth) or n.db().shallow.contains(item.oid)) {
                    try result.append(n.arena, item.oid);
                    continue;
                }
                try n.not_shallow.put(n.arena, item.oid, {});
                const c = (try n.commit(item.oid)) orelse continue;
                // git follows the first parent at once and the others later.
                var i = c.parents.len;
                while (i > 0) {
                    i -= 1;
                    const p = c.parents[i];
                    const gop = try depths.getOrPut(n.arena, p);
                    if (gop.found_existing and cur >= gop.value_ptr.*) continue;
                    gop.value_ptr.* = cur;
                    try stack.append(n.arena, .{ .oid = p, .depth = cur });
                }
            }
        }
        return result.items;
    }

    /// git's `get_shallow_commits_by_rev_list`: the commits reachable from
    /// the wants, newer than `deepen-since` and not reachable from the
    /// `deepen-not` refs; those with a parent outside them are the boundary.
    fn deepenByRevList(n: *Negotiation, out: *Io.Writer) Error!void {
        var excluded: Oid.Set = .empty;
        for (n.deepen_not.items) |name| {
            const tip = (try n.resolveRef(name)) orelse return n.server.refuse(out, "git upload-pack: ambiguous deepen-not");
            const start = (try n.peelToCommit(tip)) orelse continue;
            var stack: std.ArrayList(Oid) = .empty;
            try stack.append(n.arena, start);
            while (stack.pop()) |oid| {
                if ((try excluded.getOrPut(n.arena, oid)).found_existing) continue;
                const c = (try n.commit(oid)) orelse continue;
                for (rev_walk.parentsOf(n.db(), oid, c.parents)) |p| try stack.append(n.arena, p);
            }
        }
        var in_range: Oid.Set = .empty;
        var order: std.ArrayList(Oid) = .empty;
        var stack: std.ArrayList(Oid) = .empty;
        for (n.wants.items) |want| if (try n.peelToCommit(want)) |c| try stack.append(n.arena, c);
        while (stack.pop()) |oid| {
            if (in_range.contains(oid) or excluded.contains(oid)) continue;
            const c = (try n.commit(oid)) orelse continue;
            if (n.deepen_since) |since| if (c.committer.when_secs < since) continue;
            try in_range.put(n.arena, oid, {});
            try order.append(n.arena, oid);
            for (rev_walk.parentsOf(n.db(), oid, c.parents)) |p| try stack.append(n.arena, p);
        }
        var result: std.ArrayList(Oid) = .empty;
        for (order.items) |oid| {
            try n.not_shallow.put(n.arena, oid, {});
            const c = (try n.commit(oid)).?;
            for (rev_walk.parentsOf(n.db(), oid, c.parents)) |p| {
                if (!in_range.contains(p)) {
                    try result.append(n.arena, oid);
                    break;
                }
            }
        }
        // A commit on the boundary is not one within it.
        for (result.items) |oid| _ = n.not_shallow.remove(oid);
        try n.sendShallow(out, result.items);
        try n.sendUnshallow(out);
    }

    fn resolveRef(n: *Negotiation, name: []const u8) Error!?Oid {
        const store = n.server.remote.repo.refStore();
        for ([_][]const u8{ "", "refs/", "refs/tags/", "refs/heads/", "refs/remotes/" }) |prefix| {
            const full = try n.arena.print("{s}{s}", .{ prefix, name });
            if (try store.resolve(n.arena, n.io(), full)) |r| return r.oid;
        }
        return null;
    }

    /// git's `send_shallow`: each new boundary commit, once.
    fn sendShallow(n: *Negotiation, out: *Io.Writer, result: []const Oid) Error!void {
        var i = result.len;
        while (i > 0) {
            i -= 1;
            const oid = result[i];
            if (n.client_shallow_set.contains(oid) or n.not_shallow.contains(oid)) continue;
            if (n.boundary.contains(oid)) continue;
            pkt_line.print("shallow {f}\n", .{oid}, out) catch |err| return writeError(err);
            try n.boundary.put(n.arena, oid, {});
        }
    }

    /// git's `send_unshallow`: a client boundary commit now within the
    /// history sent is no longer one; its parents are wanted.
    fn sendUnshallow(n: *Negotiation, out: *Io.Writer) Error!void {
        for (n.client_shallows.items) |oid| {
            if (n.not_shallow.contains(oid)) {
                pkt_line.print("unshallow {f}\n", .{oid}, out) catch |err| return writeError(err);
                const c = (try n.commit(oid)) orelse continue;
                for (c.parents) |p| try n.extra_wants.append(n.arena, p);
                try n.edges.append(n.arena, oid);
            }
            try n.boundary.put(n.arena, oid, {});
        }
    }

    // --------------------------------------------------------------
    // The pack
    // --------------------------------------------------------------

    /// The filter a client asked for, read as git reads it
    /// (`filter_spec.zig`), or the request refused as git's upload-pack
    /// refuses it.
    fn readFilter(n: *Negotiation, out: *Io.Writer, text: []const u8) Error!object_walk.Filter {
        const spec = filter_spec.parse(n.arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFilter => return n.server.refuse(out, "invalid filter-spec"),
        };
        var sparse_seen = false;
        return n.walkFilter(out, spec, text, &sparse_seen);
    }

    fn walkFilter(n: *Negotiation, out: *Io.Writer, spec: filter_spec.Spec, text: []const u8, sparse_seen: *bool) Error!object_walk.Filter {
        return switch (spec) {
            .blob_none => .blob_none,
            .blob_limit => |v| .{ .blob_limit = v },
            .tree_depth => |v| .{ .tree_depth = v },
            .object_type => |v| .{ .object_type = v },
            .sparse_oid => |name| {
                // One set of patterns to a walk.
                if (sparse_seen.*) return n.server.refuse(out, "invalid filter-spec");
                sparse_seen.* = true;
                const rules = try n.sparseRules(name) orelse {
                    var buf: [512]u8 = undefined;
                    return n.server.refuse(out, std.mem.print(&buf, "unable to access sparse blob in '{s}'", .{name}) catch "unable to access sparse blob");
                };
                return .{ .sparse = rules };
            },
            .combine => |parts| {
                const walked = try n.arena.alloc(object_walk.Filter, parts.len);
                for (parts, walked) |part, *w| w.* = try n.walkFilter(out, part, text, sparse_seen);
                return .{ .combine = walked };
            },
        };
    }

    /// The patterns in the blob `name` names, or `null` when there is no
    /// such blob.
    fn sparseRules(n: *Negotiation, name: []const u8) Error!?*const ignore.Rules {
        const s = n.server;
        const repo = &s.remote.repo;
        const oid = (try n.resolveBlob(name)) orelse return null;
        const found = repo.objectDatabase().read(s.io, oid) catch |err| switch (err) {
            error.ObjectNotFound => return null,
            else => |e| return e,
        };
        defer repo.objectDatabase().allocator().free(found.bytes);
        if (found.type != .blob) return null;
        const rules = try n.arena.create(ignore.Rules);
        rules.* = try .init(n.arena, .{});
        // The rules keep slices of the text.
        try rules.addText(try n.arena.dupe(u8, found.bytes), "", "sparse:oid", 0);
        return rules;
    }

    /// What a `sparse:oid=` names: any revision expression git's server
    /// resolves there (`rev_parse.zig`).
    fn resolveBlob(n: *Negotiation, name: []const u8) Error!?Oid {
        const s = n.server;
        return rev_parse.resolve(s.gpa, s.io, &s.remote.repo, name) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => null,
        };
    }

    fn sendPack(n: *Negotiation, out: *Io.Writer, band: Band) Error!void {
        const s = n.server;
        var include: std.ArrayList(Oid) = .empty;
        try include.appendSlice(n.arena, n.wants.items);
        try include.appendSlice(n.arena, n.extra_wants.items);
        var exclude: std.ArrayList(Oid) = .empty;
        try exclude.appendSlice(n.arena, n.have_obj.items);
        try exclude.appendSlice(n.arena, n.edges.items);
        var collected = try object_walk.missing(s.gpa, s.io, n.db(), include.items, .{ .exclude = exclude.items, .boundary = &n.boundary, .filter = n.filter });
        defer collected.deinit();
        var entries: std.ArrayList(odb_mod.PackEntry) = .empty;
        try entries.appendSlice(n.arena, collected.entries);
        if (s.promisor_taken) {
            // What a promisor remote the client took holds and this
            // repository does not is left to that remote.
            var kept: usize = 0;
            for (entries.items) |entry| {
                if (!try n.db().exists(s.io, entry.oid)) continue;
                entries.items[kept] = entry;
                kept += 1;
            }
            entries.shrinkRetainingCapacity(kept);
        }
        if (n.include_tag) try n.addTags(&entries);

        var framed: side_band.Mux = .init(out, band);
        _ = n.db().writePackTo(s.io, framed.writer(), entries.items, .{
            .delta = if (n.ofs_delta) .offset else .reference,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.WriteFailed,
        };
        framed.end() catch return error.WriteFailed;
        out.flush() catch return error.WriteFailed;
    }

    /// `include-tag`: an annotated tag whose object the pack carries comes
    /// with it.
    fn addTags(n: *Negotiation, entries: *std.ArrayList(odb_mod.PackEntry)) Error!void {
        var in_pack: Oid.Set = .empty;
        for (entries.items) |e| try in_pack.put(n.arena, e.oid, {});
        var listing = try n.server.remote.repo.refStore().list(n.server.gpa, n.io(), "refs/tags/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            const tip = switch (entry.target) {
                .direct => |oid| oid,
                .symbolic => continue,
            };
            if (in_pack.contains(tip)) continue;
            // The chain of tags down to what is not a tag.
            var chain: std.ArrayList(Oid) = .empty;
            var current = tip;
            var depth: u8 = 0;
            while (depth < 16) : (depth += 1) {
                const header = n.db().readHeader(n.io(), current) catch break;
                if (header.type != .tag) break;
                try chain.append(n.arena, current);
                const found = try n.db().read(n.io(), current);
                defer n.db().allocator().free(found.bytes);
                var tag = try object.Tag.parse(n.arena, n.db().objectFormat(), found.bytes);
                current = tag.target;
                tag.deinit();
            }
            if (chain.items.len == 0 or !in_pack.contains(current)) continue;
            for (chain.items) |t| {
                if ((try in_pack.getOrPut(n.arena, t)).found_existing) continue;
                try entries.append(n.arena, .{ .oid = t });
            }
        }
    }
};

/// A packet that could not be written, to the client: `WriteFailed`.
/// git's `bundle_uri_advertise`: `uploadpack.advertiseBundleURIs`. A value
/// that is no boolean advertises the command too, as git's maybe-bool getter
/// leaves -1 there and its caller takes that for true.
pub fn advertisesBundleUris(config: *const config_mod.Config) bool {
    return config.getBool("uploadpack.advertisebundleuris", false) catch true;
}

/// What `bundle-uri` answers, as git's `config_to_packet_line` writes it:
/// every `bundle.*` setting of `config` in its order, `<key>=<value>`, the
/// section and the variable in lower case and the subsection as written.
/// A name with no value at all is left out, where git hands its NULL to
/// printf. The lines are `arena`'s.
pub fn bundleSettings(arena: Allocator, config: *const config_mod.Config) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (config.entries.items) |e| {
        if (!std.mem.eql(u8, e.section, "bundle")) continue;
        const value = e.value orelse continue;
        try lines.append(arena, if (e.has_subsection)
            try arena.print("bundle.{s}.{s}={s}", .{ e.subsection, e.name, value })
        else
            try arena.print("bundle.{s}={s}", .{ e.name, value }));
    }
    return lines.items;
}

fn writeError(err: pkt_line.WriteError) Error {
    return switch (err) {
        error.PacketTooLong, error.WriteFailed => error.WriteFailed,
    };
}

/// A conversation with `remote`'s own upload-pack, in this process: each
/// request answered whole as it is sent, as over HTTP. The result is the
/// caller's; closing it closes `remote` too.
pub fn connect(gpa: Allocator, io: Io, remote: *local.Remote, version: protocol.Version, options: Options) Allocator.Error!*Connection {
    var serving = options;
    serving.stateless = true;
    return in_process.InProcess(Server, told).create(gpa, io, remote, .init(gpa, io, remote, version, serving));
}

/// The refusals upload-pack answers the client with, which it reads.
fn told(err: Error) bool {
    return switch (err) {
        error.NotOurRef, error.FilterRefused, error.ProtocolError => true,
        else => false,
    };
}

test "fuzz: whatever a client sends is answered or refused, in v2 and v0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.create(gpa, io, tmp.dir, .{ .bare = true });
    repo.deinit(io);
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var remote = try local.Remote.open(gpa, io, path, .{});
    defer remote.deinit(io);
    try shakedown.check(std.testing.allocator, &remote, fuzzServe, .{});
}

fn fuzzServe(remote: *local.Remote, case: *shakedown.Case) anyerror!void {
    var scratch: [1024]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    for ([_]protocol.Version{ .v2, .v0 }) |version| {
        var server: Server = .init(std.testing.allocator, std.testing.io, remote, version, .{ .stateless = true, .allow_filter = true });
        var fixed: Io.Reader = .fixed(input);
        var buffer: [pkt_line.max_line]u8 = undefined;
        var limited = fixed.limited(.unlimited, &buffer);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        // glint-ignore: Z026 -- refusing a malformed request is the expected outcome; only a crash or a leak fails the fuzzer
        server.serveRequest(&limited.interface, &out.writer) catch {};
    }
}

test "upload-pack reads preserve transport resource failures" {
    const Broken = struct {
        fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var server: Server = undefined;
    server.gpa = std.testing.allocator;
    var writer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    // Fail in the command, and then in the arguments after its delimiter.
    for ([_][]const u8{ "", "0014command=ls-refs\n0001" }) |buffered| {
        var buf: [pkt_line.max_line]u8 = undefined;
        @memcpy(buf[0..buffered.len], buffered);
        var reader: Io.Reader = .{ .vtable = &.{ .stream = Broken.stream }, .buffer = &buf, .seek = 0, .end = buffered.len };
        try std.testing.expectError(error.ReadFailed, server.commandV2(&reader, &writer.writer));
    }
}
