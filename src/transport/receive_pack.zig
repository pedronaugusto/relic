//! The serving side of a push: git's `receive-pack`.
//!
//! A repository advertises its refs and what it can do, reads the client's
//! commands — `<old> <new> <ref>`, the capabilities after the first one's
//! NUL — its push options when both sides take them and its shallow
//! boundary, and then the pack, which is received into a quarantine
//! (`odb/quarantine.zig`) and checked there: indexed, every object by
//! `receive.fsckObjects`'s rules, every new tip connected. The hooks then
//! decide, as git's do: `pre-receive` sees every command with the
//! quarantine as its object directory and may refuse them all; the
//! objects are moved into the repository; each command is held to
//! `receive.denyCurrentBranch`, `denyDeletes`, `denyDeleteCurrent`,
//! `denyNonFastForwards` and its `update` hook, and the refs are written,
//! each alone or, for an atomic push, all together. A ref under
//! `receive.procReceiveRefs` is the `proc-receive` hook's instead: it is
//! handed the commands in a pkt-line conversation and answers for each,
//! with what it made of them in report-status-v2's options, which the
//! report and `post-receive` carry. Under `receive.certNonceSeed` a push
//! may come signed: a certificate holding the commands, checked and handed
//! to `pre-receive` and `post-receive` as git's `GIT_PUSH_CERT*`. The
//! report follows —
//! `report-status` or `report-status-v2`, on the side-band when the client
//! asked for one, the hooks' output beside it on channel two — and then
//! `post-receive` and `post-update`.
//!
//! receive-pack speaks v0, and v1 with its version line; a client asking
//! for v2 is answered in v0, as git's receive-pack answers it. Over a pipe
//! the conversation is the advertisement and one push (`serve`); over HTTP
//! each request stands alone (`serveRequest`, git's `--stateless-rpc`).
//! relic pushes to a repository on this machine through it in process
//! (`connect`), as git runs its own receive-pack for one.

const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const pack = @import("../odb/pack.zig");
const keep = @import("../odb/keep.zig");
const index_pack = @import("../odb/index_pack.zig");
const quarantine_mod = @import("../odb/quarantine.zig");
const rev_index = @import("../odb/rev_index.zig");
const fsck = @import("../object/fsck.zig");
const pkt_line = @import("../codec.zig").pkt_line;
const protocol = @import("../wire.zig").protocol;
const side_band = @import("../wire.zig").side_band;
const connection = @import("../wire.zig").connection;
const object_walk = @import("../walk/object/walk.zig");
const rev_walk = @import("../walk/walk.zig");
const ref_names = @import("../names.zig").ref;
const config_mod = @import("../config/config.zig");
const hooks = @import("../hooks/hooks.zig");
const program = @import("../process.zig").program;
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const decimal = @import("../text.zig").decimal;
const abbrev = @import("../odb/abbrev.zig");
const progress_mod = @import("../report.zig").progress;
const server_info = @import("../maintenance/server_info.zig");
const checkout = @import("../checkout/checkout.zig");
const three_way = @import("../merge/three_way.zig");
const signing = @import("../object/signing.zig");
const local = @import("local.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;
const Quarantine = quarantine_mod.Quarantine;

/// Errors from serving.
pub const Error = error{
    /// The client sent something that is not the protocol. The
    /// conversation ends there, as git's receive-pack dies.
    ProtocolError,
    /// The client named an object format this repository is not in.
    ObjectFormatMismatch,
    /// Writing to the client failed.
    WriteFailed,
} || Io.Reader.Error || local.Error || quarantine_mod.Error || hooks.Error || hooks.InitError || Allocator.Error || Io.Cancelable;

/// How the server runs.
pub const Options = struct {
    /// Every request stands alone, as over HTTP.
    stateless: bool = false,
    /// Who the ref updates are logged as, and when.
    who: object.Signature,
    /// Permission to run the repository's hooks. Without it a repository
    /// that has a hook a push runs refuses the push (`checkHooks`), as
    /// applying it without them would skip whatever they check.
    programs: ?program.Programs = null,
    /// `GIT_ALTERNATE_OBJECT_DIRECTORIES` as the server was started with
    /// it, which a hook reading the quarantine is handed after the
    /// repository's own.
    inherited_alternates: ?[]const u8 = null,
    /// The repository's path as the server was asked to serve it, git's
    /// `service_dir`, which a push certificate's nonce is made from: two
    /// servers of one repository over HTTP take each other's nonces only
    /// when they name it alike, and git's http-backend names it `.`.
    service_dir: []const u8 = ".",
};

/// How a `receive.deny*` setting answers.
const Deny = enum { unconfigured, ignore, warn, refuse, update_instead };

/// git's `parse_deny_action`.
fn denyAction(config: *const config_mod.Config, key: []const u8) Deny {
    const raw = config.get(key) orelse return .unconfigured;
    if (std.ascii.eqlIgnoreCase(raw, "ignore")) return .ignore;
    if (std.ascii.eqlIgnoreCase(raw, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(raw, "refuse")) return .refuse;
    if (std.ascii.eqlIgnoreCase(raw, "updateinstead")) return .update_instead;
    return if (config_mod.parseBool(raw) catch false) .refuse else .ignore;
}

/// The `receive.*` settings, read once.
const Settings = struct {
    deny_deletes: bool,
    deny_non_fast_forwards: bool,
    deny_current_branch: Deny,
    deny_delete_current: Deny,
    advertise_atomic: bool,
    advertise_push_options: bool,
    ofs_delta: bool,
    shallow_update: bool,
    max_input_size: ?aegis.units.Bytes(u64),
    /// `receive.certNonceSeed`: the secret a push certificate's nonce is
    /// made with; with none, no certificate is asked for.
    cert_nonce_seed: ?[]const u8,
    /// `receive.certNonceSlop`: how many seconds apart another server's
    /// nonce may be and still count as this one's.
    cert_nonce_slop: u64,
    /// `receive.keepAlive`: the seconds of quiet after which a keepalive
    /// is sent on the side band; zero or less sends none.
    keepalive_secs: i64,
    /// `receive.updateServerInfo`: the dumb HTTP files written again after
    /// every push.
    update_server_info: bool,
    /// `receive.unpackLimit`, else `transfer.unpackLimit`, else git's 100:
    /// a pack of fewer objects is stored loose.
    unpack_limit: u64,

    fn read(config: *const config_mod.Config) Settings {
        const max = config.getInt("receive.maxinputsize", 0) catch 0;
        return .{
            .deny_deletes = config.getBool("receive.denydeletes", false) catch false,
            .deny_non_fast_forwards = config.getBool("receive.denynonfastforwards", false) catch false,
            .deny_current_branch = denyAction(config, "receive.denycurrentbranch"),
            .deny_delete_current = denyAction(config, "receive.denydeletecurrent"),
            .advertise_atomic = config.getBool("receive.advertiseatomic", true) catch true,
            .advertise_push_options = config.getBool("receive.advertisepushoptions", false) catch false,
            .ofs_delta = config.getBool("repack.usedeltabaseoffset", true) catch true,
            .shallow_update = config.getBool("receive.shallowupdate", false) catch false,
            .max_input_size = if (max > 0) .fromRaw(@intCast(max)) else null,
            .cert_nonce_seed = config.get("receive.certnonceseed"),
            .cert_nonce_slop = @intCast(@max(0, config.getInt("receive.certnonceslop", 0) catch 0)),
            .keepalive_secs = config.getInt("receive.keepalive", 5) catch 5,
            .update_server_info = config.getBool("receive.updateserverinfo", false) catch false,
            .unpack_limit = limit: {
                for ([_][]const u8{ "receive.unpacklimit", "transfer.unpacklimit" }) |key| {
                    const value = config.getInt(key, -1) catch -1;
                    if (value >= 0) break :limit @intCast(value);
                }
                break :limit 100;
            },
        };
    }
};

/// One command, and what became of it.
const Command = struct {
    old: Oid,
    new: Oid,
    name: []const u8,
    /// Why it was refused: the `ng` reason. `null` while it stands.
    error_string: ?[]const u8 = null,
    /// A deletion of a ref that was not there.
    did_not_exist: bool = false,
    /// Under a `receive.procReceiveRefs` prefix: the `proc-receive` hook's
    /// to update, not the ref transaction's. A hook's `fall-through` hands
    /// it back.
    proc_receive: bool = false,
    /// The `proc-receive` hook reported on it: git's
    /// `RUN_PROC_RECEIVE_RETURNED`.
    returned: bool = false,
    /// What the `proc-receive` hook said its `ok` became, one for each
    /// `ok` it followed with options.
    reports: std.ArrayList(Report) = .empty,

    /// Left out of the ref updates and the `proc-receive` hook while it
    /// stands: a symbolic ref whose target another command updates,
    /// git's `skip_update`.
    skip_update: bool = false,

    fn standing(c: *const Command) bool {
        return c.error_string == null;
    }

    /// git's `should_process_cmd`.
    fn processed(c: *const Command) bool {
        return c.standing() and !c.skip_update;
    }
};

/// One update a `proc-receive` hook made for a command: report-status-v2's
/// `option refname`, `old-oid`, `new-oid` and `forced-update`, each `null`
/// where the command's own stands.
const Report = struct {
    name: ?[]const u8 = null,
    old: ?Oid = null,
    new: ?Oid = null,
    forced: bool = false,
};

/// The client's end of a push under way: what the push writes to, and
/// when the client last heard anything, which the keepalive measures.
const Channel = struct {
    out: ?*Io.Writer = null,
    band: side_band.Band = .none,
    /// When anything was last sent, on the awake clock.
    last: Io.Timestamp = .zero,
    /// Keepalives are due when nothing is sent for `receive.keepAlive`:
    /// from the pack's end on, as git's muxers send them once index-pack
    /// has read it.
    keepalive: bool = false,
};

/// The capabilities the client asked for.
const Asked = struct {
    report_status: bool = false,
    report_status_v2: bool = false,
    band: side_band.Band = .none,
    quiet: bool = false,
    atomic: bool = false,
    push_options: bool = false,
};

/// A repository, receiving.
pub const Server = struct {
    pub const Error = Self.Error;

    gpa: Allocator,
    io: Io,
    remote: *local.Remote,
    version: protocol.Version,
    options: Options,
    settings: Settings,
    /// The hooks, when the caller allows them to run.
    runner: ?hooks.Runner = null,
    /// What the client asked for, once it has.
    asked: Asked = .{},
    /// Where the report and the messages go, written by the push and by
    /// the tasks beside it one at a time.
    channel: aegis.BlockingGuarded(Channel) = .init(.{}),
    /// The boundary commits a shallow push brings, written once its refs
    /// are.
    new_shallow: Oid.Set = .empty,
    /// The nonce this server asks a push certificate to carry, made when it
    /// starts, as git's is.
    nonce: ?[]u8 = null,
    /// This push's certificate, in the request's arena.
    certificate: ?[]const u8 = null,
    /// What the receive hooks are told of it, made at the first hook that
    /// runs, as git makes it.
    certificate_vars: ?[]const program.Var = null,

    /// Serve `remote` in `version` — v2 is answered in v0, as git's is.
    /// The repository's refs are shown as `receive.hideRefs` leaves them.
    pub fn init(gpa: Allocator, io: Io, remote: *local.Remote, version: protocol.Version, options: Options) Self.Error!Server {
        try remote.serve(.receive_pack);
        var s: Server = .{
            .gpa = gpa,
            .io = io,
            .remote = remote,
            .version = if (version == .v2) .v0 else version,
            .options = options,
            .settings = .read(remote.repo.configuration()),
        };
        if (s.settings.cert_nonce_seed) |seed| s.nonce = try certNonce(gpa, s.kind(), options.service_dir, seed, options.who.when_secs);
        errdefer if (s.nonce) |n| gpa.free(n);
        if (options.programs) |programs| {
            // The receive hooks run in the git directory, bare or not, as
            // git runs them.
            s.runner = try hooks.Runner.init(gpa, io, .{
                .config = remote.repo.configuration(),
                .git_dir = remote.repo.gitDirectory(),
                .common_dir = remote.repo.commonDirectory(),
                .work_dir = null,
            }, programs, .{ .output = .capture });
        } else try checkHooks(io, &remote.repo);
        return s;
    }

    /// Release the hooks' runner.
    pub fn deinit(s: *Server) void {
        if (s.runner) |*r| r.deinit();
        s.new_shallow.deinit(s.gpa);
        if (s.nonce) |n| s.gpa.free(n);
        s.* = undefined;
    }

    fn db(s: *Server) *odb_mod.Odb {
        return s.remote.repo.objectDatabase();
    }

    fn kind(s: *Server) hash.Kind {
        return s.remote.repo.objectFormat();
    }

    /// The server's first message: `version 1` when the client asked for
    /// it, then every ref the client may see with the capabilities after
    /// the first, and the repository's shallow boundary.
    pub fn advertise(s: *Server, w: *Io.Writer) Self.Error!void {
        s.writeAdvertisement(w) catch |err| return writeError(err);
    }

    fn writeAdvertisement(s: *Server, w: *Io.Writer) (pkt_line.WriteError || Self.Error)!void {
        if (s.version == .v1) try pkt_line.write(w, "version 1\n");
        var caps: std.ArrayList(u8) = .empty;
        defer caps.deinit(s.gpa);
        try caps.appendSlice(s.gpa, "report-status report-status-v2 delete-refs side-band-64k quiet");
        if (s.settings.advertise_atomic) try caps.appendSlice(s.gpa, " atomic");
        if (s.settings.ofs_delta) try caps.appendSlice(s.gpa, " ofs-delta");
        if (s.nonce) |nonce| try caps.print(s.gpa, " push-cert={s}", .{nonce});
        if (s.settings.advertise_push_options) try caps.appendSlice(s.gpa, " push-options");
        try caps.print(s.gpa, " object-format={s} agent={s}", .{ s.kind().name(), protocol.agent });

        var listing = try s.remote.repo.refStore().list(s.gpa, s.io, "refs/");
        defer listing.deinit();
        var first = true;
        var seen: Oid.Set = .empty;
        defer seen.deinit(s.gpa);
        for (listing.entries) |entry| {
            if (s.remote.isHidden(entry.name)) continue;
            const oid = switch (entry.target) {
                .direct => |oid| oid,
                .symbolic => blk: {
                    // A dangling or circular one is left out, as git
                    // leaves a broken ref out.
                    const resolved = (s.remote.repo.refStore().resolve(s.gpa, s.io, entry.name) catch |err| switch (err) {
                        error.SymbolicRefLoop => continue,
                        else => |e| return e,
                    }) orelse continue;
                    defer s.gpa.free(resolved.name);
                    break :blk resolved.oid;
                },
            };
            try seen.put(s.gpa, oid, {});
            try s.showRef(w, &first, entry.name, oid, caps.items);
        }
        // What the alternates' refs name, for the client to leave out.
        var alternates = try s.alternateTips();
        defer alternates.deinit(s.gpa);
        for (alternates.items) |oid| {
            if ((try seen.getOrPut(s.gpa, oid)).found_existing) continue;
            try s.showRef(w, &first, ".have", oid, caps.items);
        }
        if (first) try s.showRef(w, &first, "capabilities^{}", .zero(s.kind()), caps.items);
        const boundary = try sortedShallow(s.gpa, s.db());
        defer s.gpa.free(boundary);
        for (boundary) |oid| try pkt_line.print("shallow {f}\n", .{oid}, w);
        try pkt_line.flush(w);
    }

    fn showRef(_: *Server, w: *Io.Writer, first: *bool, name: []const u8, oid: Oid, caps: []const u8) pkt_line.WriteError!void {
        if (first.*) {
            first.* = false;
            try pkt_line.print("{f} {s}\x00{s}\n", .{ oid, name, caps }, w);
        } else try pkt_line.print("{f} {s}\n", .{ oid, name }, w);
    }

    /// The tips of the repositories this one borrows objects from.
    fn alternateTips(s: *Server) Self.Error!std.ArrayList(Oid) {
        var out: std.ArrayList(Oid) = .empty;
        errdefer out.deinit(s.gpa);
        var alternates = try s.db().listAlternates(s.gpa, s.io);
        defer alternates.deinit();
        for (alternates.paths) |path| {
            // An alternate is `<repository>/objects`; its refs are beside.
            const repo_path = std.Io.Dir.path.dirname(path) orelse continue;
            var other = local.Remote.open(s.gpa, s.io, repo_path, .{}) catch continue;
            defer other.deinit(s.io);
            var refs = other.listRefs(s.gpa, s.io, &.{"refs/"}) catch continue;
            defer refs.deinit();
            for (refs.refs) |ref| try out.append(s.gpa, ref.oid);
        }
        return out;
    }

    /// A whole conversation over a pipe: the advertisement, then one push.
    pub fn serve(s: *Server, in: *Io.Reader, out: *Io.Writer) Self.Error!void {
        try s.advertise(out);
        out.flush() catch return error.WriteFailed;
        try s.serveRequest(in, out);
    }

    /// One push, its commands to its report and its last hooks.
    pub fn serveRequest(s: *Server, in: *Io.Reader, out: *Io.Writer) Self.Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        s.asked = .{};
        s.setChannel(.{ .out = out, .last = Io.Clock.awake.now(s.io) });
        defer s.setChannel(.{});
        s.certificate = null;
        s.certificate_vars = null;
        defer {
            s.certificate = null;
            s.certificate_vars = null;
        }

        var shallow: std.ArrayList(Oid) = .empty;
        const commands = try s.readCommands(arena, in, &shallow);
        if (commands.len == 0) {
            out.flush() catch return error.WriteFailed;
            return;
        }
        {
            var guard = s.channel.acquireUncancelable(s.io);
            defer guard.deinit(s.io);
            guard.value().band = s.asked.band;
        }
        // Keepalives beside the push, on the side band, where a second
        // task can run.
        var keeper: ?Io.Future(void) = null;
        defer if (keeper) |*task| task.cancel(s.io);
        if (s.asked.band != .none and s.settings.keepalive_secs > 0 and canRunBeside(s.io)) {
            keeper = s.io.concurrent(keepAlive, .{s}) catch null;
        }
        var push_options: std.ArrayList([]const u8) = .empty;
        if (s.asked.push_options) try readPushOptions(arena, in, &push_options);
        if (s.certificate) |cert| if (!certificateOptionsMatch(cert, push_options.items)) {
            for (commands) |*cmd| cmd.error_string = "inconsistent push options";
        };

        var unpack_status: ?[]const u8 = null;
        var q: ?Quarantine = null;
        defer if (q) |*held| held.deinit(s.io);
        var keeps: std.ArrayList(keep.Token) = .empty;
        defer {
            for (keeps.items) |*token| token.deinit(s.io);
            keeps.deinit(s.gpa);
        }
        var received: ?Received = null;
        defer if (received) |*r| r.deinit(s.io);
        if (!deleteOnly(commands)) unpacking: {
            const count = switch (packHeader(in)) {
                .count => |n| n,
                .refused => |why| {
                    unpack_status = why;
                    break :unpacking;
                },
            };
            // git's `unpack-objects` below the limit, its `index-pack`
            // at it and above.
            const loose = count < s.settings.unpack_limit;
            q = try Quarantine.begin(s.gpa, s.io, s.db());
            var diagnostic: index_pack.Diagnostic = .{};
            received = s.unpack(in, &q.?, &diagnostic, .{ .context = s, .report = endOfInput }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => blk: {
                    // What git's fsck found, as its unpacker says it.
                    if (diagnostic.problem) |problem| if (diagnostic.oid) |oid| {
                        const finding: fsck.Finding = .{ .oid = oid, .problem = problem, .level = .@"error" };
                        const text = try finding.message(arena);
                        try s.rpErrorPlain("object {f}: {s}", .{ oid, text });
                        try s.rpLine("fatal: fsck error in packed object", .{});
                    };
                    unpack_status = if (loose) "unpack-objects abnormal exit" else "index-pack abnormal exit";
                    break :blk null;
                },
            };
            if (received) |*r| r.loose = loose;
            if (received != null) try s.checkShallow(arena, commands, shallow.items, &received.?);
        }
        // Whatever came of the pack, the rest of the push is kept alive.
        s.startKeepalive();

        try s.execute(arena, commands, unpack_status, &q, &received, &keeps, push_options.items);
        if (received) |*r| try s.settleLoose(r, &keeps);
        try s.report(commands, unpack_status);
        _ = try s.runReceiveHook(arena, "post-receive", commands, true, push_options.items, null);
        try s.runPostUpdate(arena, commands);
        if (s.settings.update_server_info) {
            // As git's: what it comes to is not the push's to answer for.
            server_info.updateServerInfo(s.gpa, s.io, &s.remote.repo) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                // git ignores what update_server_info returns after a push
                else => {},
            };
        }
        if (keeper) |*task| {
            task.cancel(s.io);
            keeper = null;
        }
        if (s.asked.band != .none) try s.send(.raw, "0000");
        out.flush() catch return error.WriteFailed;
    }

    fn setChannel(s: *Server, channel: Channel) void {
        var guard = s.channel.acquireUncancelable(s.io);
        defer guard.deinit(s.io);
        guard.value().* = channel;
    }

    /// The indexer's last object read is the pack's end: keepalives are
    /// due from there, as git's index-pack tells its muxer with a NUL.
    fn endOfInput(context: ?*anyopaque, event: progress_mod.Event) void {
        const s: *Server = @ptrCast(@alignCast(context.?)); // safe: unpack hands this function the server itself
        switch (event) {
            .indexed => |count| if (count.done == count.total) s.startKeepalive(),
            else => {},
        }
    }

    fn startKeepalive(s: *Server) void {
        var guard = s.channel.acquireUncancelable(s.io);
        defer guard.deinit(s.io);
        guard.value().keepalive = true;
    }

    /// What a task beside the push does: a keepalive -- an empty packet on
    /// channel one, `0005\x01` -- whenever the client has heard nothing for
    /// `receive.keepAlive` seconds, as git's `copy_to_sideband` sends it.
    fn keepAlive(s: *Server) void {
        const period: Io.Duration = .fromSeconds(s.settings.keepalive_secs);
        var wait = period;
        while (true) {
            s.io.sleep(wait, .awake) catch return;
            var guard = s.channel.acquireUncancelable(s.io);
            defer guard.deinit(s.io);
            const channel = guard.value();
            const now = Io.Clock.awake.now(s.io);
            const quiet = channel.last.durationTo(now);
            if (!channel.keepalive or quiet.nanoseconds < period.nanoseconds) {
                wait = if (channel.keepalive) .{ .nanoseconds = period.nanoseconds - quiet.nanoseconds } else period;
                continue;
            }
            wait = period;
            // A packet is written whole, whatever asks this task to stop.
            const protection = s.io.swapCancelProtection(.blocked);
            defer _ = s.io.swapCancelProtection(protection);
            const out = channel.out orelse return;
            out.writeAll("0005\x01") catch return;
            out.flush() catch return;
            channel.last = now;
        }
    }

    /// What goes to the client: the report on channel one, a message on
    /// channel two, or packets as they are. Sent at once, and noted for
    /// the keepalive.
    const Sent = enum { report, message, raw };

    fn send(s: *Server, what: Sent, bytes: []const u8) Self.Error!void {
        var guard = s.channel.acquireUncancelable(s.io);
        defer guard.deinit(s.io);
        const channel = guard.value();
        const out = channel.out orelse return;
        switch (what) {
            .raw => out.writeAll(bytes) catch return error.WriteFailed,
            .report, .message => if (channel.band != .none) {
                side_band.send(out, channel.band, if (what == .report) 1 else 2, bytes) catch return error.WriteFailed;
            } else out.writeAll(bytes) catch return error.WriteFailed,
        }
        out.flush() catch return error.WriteFailed;
        channel.last = Io.Clock.awake.now(s.io);
    }

    /// git's `read_head_info`: shallow lines and commands to a flush, the
    /// capabilities after a NUL.
    fn readCommands(s: *Server, arena: Allocator, in: *Io.Reader, shallow: *std.ArrayList(Oid)) Self.Error![]Command {
        var commands: std.ArrayList(Command) = .empty;
        while (true) {
            const packet = pkt_line.read(in) catch |err| switch (err) {
                // A client that pushes nothing hangs up after the
                // advertisement, or sends a flush.
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
                else => return error.ProtocolError,
            };
            const raw = switch (packet) {
                .data => |d| d,
                else => break,
            };
            const chomped = if (raw.len != 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
            if (chomped.len > 8 and std.mem.startsWith(u8, chomped, "shallow ")) {
                const oid = Oid.parse(s.kind(), chomped["shallow ".len..]) catch return error.ProtocolError;
                try shallow.append(arena, oid);
                continue;
            }
            const nul = std.mem.findScalar(u8, chomped, 0);
            const line = chomped[0 .. nul orelse chomped.len];
            if (nul) |at| try s.takeCapabilities(chomped[at + 1 ..]);
            if (std.mem.eql(u8, line, "push-cert")) {
                // A signed push: the certificate's lines, newlines kept, to
                // `push-cert-end`, or to a flush that ends the commands too.
                var cert: std.ArrayList(u8) = .empty;
                if (s.certificate) |earlier| try cert.appendSlice(arena, earlier);
                const ended = while (true) {
                    const part = pkt_line.read(in) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        else => return error.ProtocolError,
                    };
                    const text = switch (part) {
                        .data => |d| d,
                        .flush => break true,
                        else => return error.ProtocolError,
                    };
                    if (std.mem.eql(u8, text, "push-cert-end\n")) break false;
                    // As git's `strbuf_addstr`, to a NUL.
                    try cert.appendSlice(arena, text[0 .. std.mem.findScalar(u8, text, 0) orelse text.len]);
                };
                s.certificate = cert.items;
                if (ended) break;
                continue;
            }
            try commands.append(arena, try s.parseCommand(arena, line));
        }
        // git's `queue_commands_from_cert`: the lines after the header's
        // blank line, up to the signature.
        if (s.certificate) |cert| if (cert.len != 0) {
            if (commands.items.len != 0) return error.ProtocolError;
            const body = (std.mem.find(u8, cert, "\n\n") orelse return error.ProtocolError) + 2;
            const end = signing.signedOffset(cert);
            var at = body;
            while (at < end) {
                const eol = std.mem.findScalarPos(u8, cert[0..end], at, '\n');
                try commands.append(arena, try s.parseCommand(arena, cert[at .. eol orelse end]));
                at = if (eol) |e| e + 1 else end;
            }
        };
        return commands.items;
    }

    fn takeCapabilities(s: *Server, list: []const u8) Self.Error!void {
        var format: []const u8 = "sha1";
        var it = std.mem.tokenizeScalar(u8, list, ' ');
        while (it.next()) |cap| {
            if (std.mem.eql(u8, cap, "report-status")) s.asked.report_status = true;
            if (std.mem.eql(u8, cap, "report-status-v2")) s.asked.report_status_v2 = true;
            if (std.mem.eql(u8, cap, "side-band-64k")) s.asked.band = .large;
            if (std.mem.eql(u8, cap, "quiet")) s.asked.quiet = true;
            if (std.mem.eql(u8, cap, "atomic") and s.settings.advertise_atomic) s.asked.atomic = true;
            if (std.mem.eql(u8, cap, "push-options") and s.settings.advertise_push_options) s.asked.push_options = true;
            if (std.mem.startsWith(u8, cap, "object-format=")) format = cap["object-format=".len..];
        }
        if (!std.mem.eql(u8, format, s.kind().name())) return error.ObjectFormatMismatch;
    }

    /// git's `queue_command`: `<old> SP <new> SP <ref>`.
    fn parseCommand(s: *Server, arena: Allocator, line: []const u8) Self.Error!Command {
        const hex = s.kind().hexLen();
        if (line.len < 2 * hex + 2 or line[hex] != ' ' or line[2 * hex + 1] != ' ') return error.ProtocolError;
        return .{
            .old = Oid.parse(s.kind(), line[0..hex]) catch return error.ProtocolError,
            .new = Oid.parse(s.kind(), line[hex + 1 .. 2 * hex + 1]) catch return error.ProtocolError,
            .name = try arena.dupe(u8, line[2 * hex + 2 ..]),
        };
    }

    // ------------------------------------------------------------------
    // The pack
    // ------------------------------------------------------------------

    const Received = struct {
        result: index_pack.Result,
        links: index_pack.Links,
        /// The pack's index, in the quarantine, while it is there.
        index: ?pack.Index = null,
        /// Fewer objects than `receive.unpackLimit`: they go in loose.
        loose: bool = false,
        /// The objects it brings that the repository lacked, when `loose`.
        fresh: std.ArrayList(Oid) = .empty,
        /// It was moved out of the quarantine into the repository.
        migrated: bool = false,
        gpa: Allocator,

        fn deinit(r: *Received, io: Io) void {
            r.fresh.deinit(r.gpa);
            if (r.index) |*i| i.deinit();
            r.links.deinit();
            r.result.deinit(io);
        }
    };

    /// git's `unpack`: the pack indexed into the quarantine and checked by
    /// `receive.fsckObjects`'s rules.
    fn unpack(s: *Server, in: *Io.Reader, q: *Quarantine, diagnostic: *index_pack.Diagnostic, progress: progress_mod.Progress) !Received {
        const config = s.remote.repo.configuration();
        var rules = try fsck.forTransfer(s.gpa, s.io, config, .{ .kind = s.kind(), .scope = .receive, .base = s.remote.repo.gitDirectory() }, .{});
        defer if (rules) |*r| r.deinit(s.gpa);
        var received: Received = .{ .result = undefined, .links = .init(s.gpa), .gpa = s.gpa };
        errdefer received.links.deinit();
        try q.db.objectsDirectory().createDirPath(s.io, "pack");
        var pack_dir = try q.db.objectsDirectory().openDir(s.io, "pack", .{ .iterate = true });
        defer pack_dir.close(s.io);
        received.result = try index_pack.receive(s.gpa, s.io, &q.db, .{ .pack_dir = pack_dir, .in = in }, .{
            .fsck = if (rules) |*r| r else null,
            .max_pack_bytes = s.settings.max_input_size,
            .reverse_index = rev_index.wanted(config),
            .links = &received.links,
            .threads = index_pack.configuredThreads(config),
            .diagnostic = diagnostic,
            .progress = progress,
        });
        errdefer received.result.deinit(s.io);
        if (received.result.name) |name| {
            var hex: [hash.max_hex_len]u8 = undefined;
            var idx_buf: [96]u8 = undefined;
            // unreachable: the longest hex name is 64 digits, 73 bytes with the words around it
            const idx_name = std.mem.print(&idx_buf, "pack-{s}.idx", .{name.hex(&hex)}) catch unreachable;
            received.index = try pack.Index.open(s.gpa, s.io, pack_dir, idx_name, .{ .kind = s.kind(), .max_bytes = 1 << 30 });
        }
        return received;
    }

    /// The received pack made ready to move out of the quarantine: its
    /// index let go, and below `receive.unpackLimit` the objects it brings
    /// that the repository lacks noted, to be written loose once the refs
    /// name them (`settleLoose`). A thin pack's bases, and anything else
    /// the repository holds already, are not written again, as git's
    /// `unpack-objects` does not write them.
    fn placeReceived(s: *Server, r: *Received) !void {
        var index = r.index orelse return;
        r.index = null;
        defer index.deinit();
        if (!r.loose) return;
        var it = index.iterate();
        while (try it.next()) |entry| {
            if (!try s.db().exists(s.io, entry.oid)) try r.fresh.append(s.gpa, entry.oid);
        }
    }

    /// Below `receive.unpackLimit`, the pack stored as git's
    /// `unpack-objects` stores it: its new objects loose, the pack gone.
    /// Done once the refs are written, so that until then the pack and its
    /// `.keep` hold the objects against a collection running beside the
    /// push, as for any pack received. A failure here leaves the pack as
    /// it is, every object still in it.
    fn settleLoose(s: *Server, r: *Received, keeps: *std.ArrayList(keep.Token)) Self.Error!void {
        if (!r.loose or !r.migrated) return;
        const name = r.result.name orelse return;
        settle: {
            for (r.fresh.items) |oid| {
                _ = s.db().loosen(s.io, oid, null) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                    // the pack still holds it, and every other one
                    else => break :settle,
                };
            }
            // Its `.keep` first, which would hold it.
            for (keeps.items) |*token| token.deinit(s.io);
            keeps.clearRetainingCapacity();
            var hex: [hash.max_hex_len]u8 = undefined;
            var name_buf: [96]u8 = undefined;
            // unreachable: the longest hex name is 64 digits, 69 bytes with `pack-`
            const base = std.mem.print(&name_buf, "pack-{s}", .{name.hex(&hex)}) catch unreachable;
            _ = s.db().removePacks(s.io, &.{base}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                // its objects are loose now as well; the pack stays beside them
                else => {},
            };
        }
    }

    /// A shallow client's boundary: a command whose new history reaches a
    /// commit the client has no parents of, where this repository has
    /// them, moves this repository's boundary, which only
    /// `receive.shallowUpdate` allows.
    fn checkShallow(s: *Server, arena: Allocator, commands: []Command, theirs: []const Oid, received: *Received) Self.Error!void {
        if (theirs.len == 0) return;
        var client: Oid.Set = .empty;
        for (theirs) |oid| if (!s.db().shallow.contains(oid)) try client.put(arena, oid, {});
        if (client.count() == 0) return;
        const index = if (received.index) |*i| i else return;
        for (commands) |*cmd| {
            if (!cmd.standing() or cmd.new.isZero()) continue;
            const roots = try shallowRoots(arena, s.io, index, &s.remote.repo, cmd.new, &client);
            if (roots.len == 0) continue;
            if (!s.settings.shallow_update) {
                cmd.error_string = "shallow update not allowed";
                continue;
            }
            for (roots) |root| try s.new_shallow.put(s.gpa, root, {});
        }
    }

    // ------------------------------------------------------------------
    // The commands
    // ------------------------------------------------------------------

    /// git's `execute_commands`.
    fn execute(
        s: *Server,
        arena: Allocator,
        commands: []Command,
        unpack_status: ?[]const u8,
        q: *?Quarantine,
        received: *?Received,
        keeps: *std.ArrayList(keep.Token),
        push_options: []const []const u8,
    ) Self.Error!void {
        if (unpack_status != null) {
            for (commands) |*cmd| cmd.error_string = "unpacker error";
            return;
        }
        if (received.*) |*r| try s.checkConnected(commands, &q.*.?, r);
        for (commands) |*cmd| {
            if (!cmd.standing() or !s.remote.isHidden(cmd.name)) continue;
            cmd.error_string = if (cmd.new.isZero()) "deny deleting a hidden ref" else "deny updating a hidden ref";
        }
        // `receive.procReceiveRefs` hands its refs to the `proc-receive`
        // hook once `pre-receive` has seen them.
        var any_proc_receive = false;
        for (commands) |*cmd| {
            if (cmd.standing() and s.procReceiveRef(cmd)) {
                cmd.proc_receive = true;
                any_proc_receive = true;
            }
        }
        if (!try s.runReceiveHook(arena, "pre-receive", commands, false, push_options, if (q.*) |*held| held else null)) {
            for (commands) |*cmd| {
                if (cmd.standing()) cmd.error_string = "pre-receive hook declined";
            }
            return;
        }
        for (commands) |cmd| {
            if (cmd.standing()) break;
        } else return;

        // The refs are about to name the objects: they go where every
        // reader finds them.
        if (q.*) |*held| {
            const placed = if (received.*) |*r| s.placeReceived(r) else {};
            placed catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => {
                    for (commands) |*cmd| {
                        if (cmd.standing()) cmd.error_string = "unable to migrate objects to permanent storage";
                    }
                    return;
                },
            };
            held.migrate(s.io, s.db(), keeps) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => {
                    for (commands) |*cmd| {
                        if (cmd.standing()) cmd.error_string = "unable to migrate objects to permanent storage";
                    }
                    return;
                },
            };
            if (received.*) |*r| r.migrated = true;
        }

        try s.checkAliasedUpdates(arena, commands);
        const head = try s.remote.repo.refStore().currentBranch(arena, s.io);
        const head_ref: ?[]const u8 = if (head) |h| try arena.print("refs/heads/{s}", .{h}) else null;
        if (any_proc_receive and !try s.runProcReceive(arena, commands, push_options)) {
            // An atomic push fails whole with it.
            for (commands) |*cmd| {
                if (cmd.standing() and !cmd.returned and (cmd.proc_receive or s.asked.atomic)) cmd.error_string = "fail to run proc-receive hook";
            }
        }
        if (s.asked.atomic) try s.executeAtomic(arena, commands, head_ref) else try s.executeEach(arena, commands, head_ref);

        if (s.new_shallow.count() != 0) {
            var it = s.new_shallow.keyIterator();
            while (it.next()) |root| try s.db().shallow.put(s.remote.repo.allocator(), root.*, {});
            s.remote.repo.writeShallow(s.io) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => {},
            };
            s.new_shallow.clearRetainingCapacity();
        }
    }

    /// Every new tip connected, as git's `check_connected` checks the
    /// whole push and, when that fails, each command alone.
    fn checkConnected(s: *Server, commands: []Command, q: *Quarantine, received: *Received) Self.Error!void {
        var tips: std.ArrayList(Oid) = .empty;
        defer tips.deinit(s.gpa);
        for (commands) |cmd| {
            if (cmd.standing() and !cmd.new.isZero()) try tips.append(s.gpa, cmd.new);
        }
        if (tips.items.len == 0) return;
        const whole = if (received.index) |*index|
            object_walk.checkReceived(s.gpa, s.io, &q.db, tips.items, .{ .fresh = index, .links = &received.links })
        else
            object_walk.checkConnected(s.gpa, s.io, &q.db, tips.items, .{});
        whole catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => for (commands) |*cmd| {
                if (!cmd.standing() or cmd.new.isZero()) continue;
                const fresh: ?*const pack.Index = if (received.index) |*index| index else null;
                object_walk.checkConnected(s.gpa, s.io, &q.db, &.{cmd.new}, .{ .fresh = fresh }) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                    else => cmd.error_string = "missing necessary objects",
                };
            },
        };
    }

    /// git's `execute_commands_non_atomic`: the deletions in one
    /// transaction, then the rest in another, each allowing failure. A
    /// ref refused for what it asks -- its old value gone, its name in
    /// conflict -- is refused alone, with git's words for why; a failure
    /// of the transaction's own refuses every command, as git's does.
    fn executeEach(s: *Server, arena: Allocator, commands: []Command, head_ref: ?[]const u8) Self.Error!void {
        // Deletions first, so a ref deleted and one created in its place
        // as a directory do not meet.
        for ([_]bool{ true, false }) |deletions| {
            var tx = s.remote.repo.beginRefs();
            defer tx.deinit(s.io);
            tx.allow_failure = true;
            if (s.runner) |*r| tx.hooks = r;
            var any = false;
            for (commands) |*cmd| {
                if (!cmd.processed() or cmd.proc_receive or cmd.new.isZero() != deletions) continue;
                any = true;
                cmd.error_string = try s.update(arena, cmd, &tx, head_ref);
            }
            if (!any) continue;
            const failed = if (s.commitRefs(&tx)) false else |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => true,
            };
            try s.sendHookOutput();
            if (failed) {
                for (commands) |*cmd| cmd.error_string = "failed to update refs";
                return;
            }
            for (tx.rejected.items) |r| try s.rpErrorPlain("{s}", .{r.detail});
            for (commands) |*cmd| {
                for (tx.rejected.items) |r| {
                    if (std.mem.eql(u8, r.name, cmd.name)) cmd.error_string = r.reason.message();
                }
            }
        }
    }

    /// git's `execute_commands_atomic`: every ref in one transaction, and
    /// the first refusal refuses them all.
    fn executeAtomic(s: *Server, arena: Allocator, commands: []Command, head_ref: ?[]const u8) Self.Error!void {
        var tx = s.remote.repo.beginRefs();
        defer tx.deinit(s.io);
        if (s.runner) |*r| tx.hooks = r;
        var reported: []const u8 = "atomic push failure";
        const failed = for (commands) |*cmd| {
            if (!cmd.processed() or cmd.proc_receive) continue;
            cmd.error_string = try s.update(arena, cmd, &tx, head_ref);
            if (!cmd.standing()) break true;
        } else blk: {
            s.commitRefs(&tx) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                reported = "atomic transaction failed";
                break :blk true;
            };
            break :blk false;
        };
        try s.sendHookOutput();
        if (!failed) return;
        for (commands) |*cmd| {
            if (cmd.standing()) cmd.error_string = reported;
        }
    }

    fn commitRefs(s: *Server, tx: *refs_mod.Transaction) refs_mod.TransactionError!void {
        try tx.commit(s.io, .{ .who = s.options.who, .message = "push", .policy = s.remote.repo.reflogPolicy() });
    }

    /// git's `update`: one command held to the rules and its hook, and
    /// staged in `tx`. The reason it was refused, or `null`.
    fn update(s: *Server, arena: Allocator, cmd: *Command, tx: *refs_mod.Transaction, head_ref: ?[]const u8) Self.Error!?[]const u8 {
        const name = cmd.name;
        const deletion = cmd.new.isZero();
        if (!std.mem.startsWith(u8, name, "refs/") or !ref_names.checkFormat(name["refs/".len..], .{ .allow_onelevel = deletion })) {
            try s.rpError("refusing to update funny ref '{s}' remotely", .{name});
            return "funny refname";
        }
        const checked_out = try s.checkedOut(arena, name);
        // `updateInstead` waits for every other check to pass first.
        var update_worktree: ?CheckedOut = null;
        if (checked_out) |wt| switch (s.settings.deny_current_branch) {
            .ignore => {},
            .warn => try s.rpWarning("updating the current branch", .{}),
            .update_instead => update_worktree = wt,
            .refuse, .unconfigured => {
                try s.rpError("refusing to update checked out branch: {s}", .{name});
                if (s.settings.deny_current_branch == .unconfigured) try s.rpError("{s}", .{refuse_unconfigured_deny});
                return "branch is currently checked out";
            },
        };
        if (!deletion and !try s.db().exists(s.io, cmd.new)) {
            try s.rpErrorPlain("unpack should have generated {f}, but I can't find it!", .{cmd.new});
            return "bad pack";
        }
        if (!cmd.old.isZero() and deletion) {
            if (s.settings.deny_deletes and std.mem.startsWith(u8, name, "refs/heads/")) {
                try s.rpError("denying ref deletion for {s}", .{name});
                return "deletion prohibited";
            }
            const is_head = if (head_ref) |h| std.mem.eql(u8, h, name) else false;
            if (checked_out != null or is_head) switch (s.settings.deny_delete_current) {
                .ignore => {},
                .warn => try s.rpWarning("deleting the current branch", .{}),
                .refuse, .unconfigured, .update_instead => {
                    // The explanation first here, as git has it.
                    if (s.settings.deny_delete_current == .unconfigured) try s.rpError("{s}", .{refuse_unconfigured_deny_delete_current});
                    try s.rpError("refusing to delete the current branch: {s}", .{name});
                    return "deletion of the current branch prohibited";
                },
            };
        }
        if (s.settings.deny_non_fast_forwards and !deletion and !cmd.old.isZero() and std.mem.startsWith(u8, name, "refs/heads/")) {
            if (!try s.isCommit(cmd.old) or !try s.isCommit(cmd.new)) {
                try s.rpErrorPlain("bad sha1 objects for {s}", .{name});
                return "bad ref";
            }
            const ok = rev_walk.isAncestor(s.gpa, s.io, s.db(), .{ .ancestor = cmd.old, .descendant = cmd.new }, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => false,
            };
            if (!ok) {
                try s.rpError("denying non-fast-forward {s} (you should pull first)", .{name});
                return "non-fast-forward";
            }
        }
        if (!try s.runUpdateHook(cmd)) {
            try s.rpError("hook declined to update {s}", .{name});
            return "hook declined";
        }
        if (update_worktree) |wt| if (try s.updateWorktree(cmd.new, wt)) |why| return why;
        if (deletion) {
            var expected: refs_mod.Expected = .{ .matches = cmd.old };
            if (cmd.old.isZero() or !try s.db().exists(s.io, cmd.old)) {
                expected = .any;
                if (try s.remote.repo.refStore().read(s.gpa, s.io, name)) |found| {
                    switch (found) {
                        .symbolic => |target| s.gpa.free(target),
                        .direct => {},
                    }
                    try s.rpWarning("allowing deletion of corrupt ref", .{});
                } else {
                    // Still staged, as git stages it: the transaction and
                    // its hook see it.
                    try s.rpWarning("deleting a non-existent ref", .{});
                    cmd.did_not_exist = true;
                }
            }
            tx.delete(name, expected) catch |err| return stageError(err);
        } else {
            const expected: refs_mod.Expected = if (cmd.old.isZero()) .must_not_exist else .{ .matches = cmd.old };
            tx.update(name, .{ .direct = cmd.new }, expected) catch |err| return stageError(err);
        }
        return null;
    }

    /// git's `run_proc_receive_hook`: the commands under
    /// `receive.procReceiveRefs` handed to the `proc-receive` hook, which
    /// updates what it will and answers for each in report-status-v2's
    /// words. What it writes on its standard error reaches the client as
    /// it is written, as git's muxer sends it. Whether it ran and answered
    /// without a fault.
    fn runProcReceive(s: *Server, arena: Allocator, commands: []Command, push_options: []const []const u8) Self.Error!bool {
        // Its standard error is read beside the conversation; where no
        // second task can run, it is this process's own.
        const beside = canRunBeside(s.io);
        const started = if (s.runner) |*r| r.start(s.io, "proc-receive", .{}, if (beside) .pipe else .inherit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            // A hook that cannot be started fails as git's does, saying
            // nothing more.
            else => return false,
        } else null;
        var running = started orelse {
            try s.rpError("cannot find hook 'proc-receive'", .{});
            return false;
        };
        defer running.deinit(s.io);
        var relay: ?Io.Future(void) = null;
        defer if (relay) |*task| task.cancel(s.io);
        if (running.child.takeStderr()) |file| {
            relay = s.io.concurrent(relayStderr, .{ s, file }) catch blk: {
                file.close(s.io);
                break :blk null;
            };
        }

        var errmsg: std.ArrayList(u8) = .empty;
        const in_buffer = try arena.alloc(u8, pkt_line.max_line);
        var out_buffer: [4096]u8 = undefined;
        var reader = running.child.stdoutFile().?.readerStreaming(s.io, in_buffer);
        var writer = running.child.stdinFile().?.writerStreaming(s.io, &out_buffer);
        var answered = try s.converse(arena, &reader.interface, &writer.interface, commands, push_options, &errmsg);
        if (reader.err) |err| if (err == error.Canceled) return error.Canceled;
        if (writer.err) |err| if (err == error.Canceled) return error.Canceled;

        // Its output is no longer heard, and its input ends.
        if (running.child.takeStdout()) |file| file.close(s.io);
        const term = running.wait(s.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => null,
        };
        if (term == null or !program.Child.succeeded(term.?)) answered = false;
        if (relay) |*task| {
            task.await(s.io);
            relay = null;
        }
        if (errmsg.items.len != 0) {
            const text = if (errmsg.items[errmsg.items.len - 1] == '\n') errmsg.items[0 .. errmsg.items.len - 1] else errmsg.items;
            try s.rpError("{s}", .{text});
        }
        return answered;
    }

    /// What a task beside the `proc-receive` conversation does: the hook's
    /// standard error to the client, to its end.
    fn relayStderr(s: *Server, file: Io.File) void {
        defer file.close(s.io);
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = file.readStreaming(s.io, &.{&chunk}) catch return;
            s.message(chunk[0..n]) catch return;
        }
    }

    /// The conversation with `proc-receive`: the version and what each
    /// side can do, the commands, the push options when the hook takes
    /// them, then its report. Whether every step went through; what went
    /// wrong is added to `errmsg` in git's words.
    fn converse(s: *Server, arena: Allocator, r: *Io.Reader, w: *Io.Writer, commands: []Command, push_options: []const []const u8, errmsg: *std.ArrayList(u8)) Self.Error!bool {
        var version: i128 = 0;
        var hook_push_options = false;
        const negotiated = negotiate: {
            const caps: []const u8 = if (s.asked.atomic and s.asked.push_options)
                "\x00atomic push-options"
            else if (s.asked.atomic)
                "\x00atomic"
            else if (s.asked.push_options)
                "\x00push-options"
            else
                "";
            pkt_line.print("version=1{s}\n", .{caps}, w) catch break :negotiate false;
            pkt_line.flush(w) catch break :negotiate false;
            w.flush() catch break :negotiate false;
            while (true) {
                const packet = pkt_line.read(r) catch break :negotiate false;
                const raw = switch (packet) {
                    .data => |d| d,
                    else => break :negotiate true,
                };
                const line = chompLine(raw);
                if (line.len <= "version=".len or !std.mem.startsWith(u8, line, "version=")) continue;
                const nul = std.mem.findScalar(u8, line, 0) orelse line.len;
                version = decimal.strtol(line["version=".len..nul], 10, 32).value;
                if (nul < line.len and hasFeature(line[nul + 1 ..], "push-options")) hook_push_options = true;
            }
        };
        if (!negotiated) {
            try errmsg.appendSlice(arena, "fail to negotiate version with proc-receive hook");
            return false;
        }
        if (version != 0 and version != 1) {
            try errmsg.print(arena, "proc-receive version '{d}' is not supported", .{version});
            return false;
        }

        const sent = send: {
            for (commands) |cmd| {
                if (!cmd.proc_receive or !cmd.processed()) continue;
                pkt_line.print("{f} {f} {s}", .{ cmd.old, cmd.new, cmd.name }, w) catch break :send false;
            }
            pkt_line.flush(w) catch break :send false;
            w.flush() catch break :send false;
            break :send true;
        };
        if (!sent) {
            try errmsg.appendSlice(arena, "fail to write commands to proc-receive hook");
            return false;
        }
        if (hook_push_options) {
            const sent_options = send: {
                for (push_options) |option| pkt_line.write(w, option) catch break :send false;
                pkt_line.flush(w) catch break :send false;
                w.flush() catch break :send false;
                break :send true;
            };
            if (!sent_options) {
                try errmsg.appendSlice(arena, "fail to write push-options to proc-receive hook");
                return false;
            }
        }
        return s.readProcReceiveReport(arena, r, commands, errmsg);
    }

    /// git's `read_proc_receive_report`: `ok <ref>` and its `option`
    /// lines, or `ng <ref> [<reason>]`, to a flush. A command the hook was
    /// handed and said nothing about fails.
    fn readProcReceiveReport(s: *Server, arena: Allocator, r: *Io.Reader, commands: []Command, errmsg: *std.ArrayList(u8)) Self.Error!bool {
        var ok = true;
        var hint: ?usize = null;
        // The report an `option` goes to: the hinted command's last, or a
        // new one at the first option after an `ok`.
        var last: ?usize = null;
        var new_report = false;
        var once = false;
        var responses: usize = 0;
        while (true) {
            const packet = pkt_line.read(r) catch {
                if (responses == 0) {
                    try errmsg.appendSlice(arena, "proc-receive exited abnormally");
                    return false;
                }
                break;
            };
            const line = switch (packet) {
                .data => |d| chompLine(d),
                else => break,
            };
            responses += 1;
            const space = std.mem.findScalar(u8, line, ' ') orelse {
                try errmsg.print(arena, "proc-receive reported incomplete status line: '{s}'\n", .{line});
                ok = false;
                continue;
            };
            const head = line[0..space];
            const rest = line[space + 1 ..];
            if (std.mem.eql(u8, head, "option")) {
                if (hint == null or (last == null and !new_report)) {
                    if (!once) try errmsg.appendSlice(arena, "proc-receive reported 'option' without a matching 'ok/ng' directive\n");
                    once = true;
                    ok = false;
                    continue;
                }
                const cmd = &commands[hint.?];
                if (new_report) {
                    try cmd.reports.append(arena, .{});
                    last = cmd.reports.items.len - 1;
                    new_report = false;
                }
                const into = &cmd.reports.items[last.?];
                const key_end = std.mem.findScalar(u8, rest, ' ');
                const key = rest[0 .. key_end orelse rest.len];
                const value: ?[]const u8 = if (key_end) |at| rest[at + 1 ..] else null;
                if (std.mem.eql(u8, key, "refname")) {
                    into.name = if (value) |v| try arena.dupe(u8, v) else null;
                } else if (std.mem.eql(u8, key, "old-oid")) {
                    if (s.oidPrefix(value)) |oid| into.old = oid;
                } else if (std.mem.eql(u8, key, "new-oid")) {
                    if (s.oidPrefix(value)) |oid| into.new = oid;
                } else if (std.mem.eql(u8, key, "forced-update")) {
                    into.forced = true;
                } else if (std.mem.eql(u8, key, "fall-through")) {
                    // receive-pack updates it after all.
                    cmd.proc_receive = false;
                    cmd.returned = false;
                }
                continue;
            }

            last = null;
            new_report = false;
            const name_end = std.mem.findScalar(u8, rest, ' ');
            const name = rest[0 .. name_end orelse rest.len];
            if (!std.mem.eql(u8, head, "ok") and !std.mem.eql(u8, head, "ng")) {
                try errmsg.print(arena, "proc-receive reported bad status '{s}' on ref '{s}'\n", .{ head, name });
                ok = false;
                continue;
            }
            // From the last command reported on, then from the first.
            if (hint) |from| hint = findCommand(commands, from, name);
            if (hint == null) hint = findCommand(commands, 0, name);
            const at = hint orelse {
                try errmsg.print(arena, "proc-receive reported status on unknown ref: {s}\n", .{name});
                ok = false;
                continue;
            };
            const cmd = &commands[at];
            if (!cmd.proc_receive) {
                try errmsg.print(arena, "proc-receive reported status on unexpected ref: {s}\n", .{name});
                ok = false;
                continue;
            }
            cmd.returned = true;
            if (std.mem.eql(u8, head, "ng")) {
                cmd.error_string = if (name_end) |at_reason| try arena.dupe(u8, rest[at_reason + 1 ..]) else "failed";
                ok = false;
                continue;
            }
            new_report = true;
        }
        for (commands) |*cmd| {
            if (cmd.proc_receive and cmd.standing() and !cmd.returned) {
                cmd.error_string = "proc-receive failed to report status";
                ok = false;
            }
        }
        return ok;
    }

    /// git's `parse_oid_hex`: an object name at the start of `text`.
    fn oidPrefix(s: *Server, text: ?[]const u8) ?Oid {
        const t = text orelse return null;
        const len = s.kind().hexLen();
        if (t.len < len) return null;
        return Oid.parse(s.kind(), t[0..len]) catch null;
    }

    /// git's `proc_receive_ref_matches`: whether a `receive.procReceiveRefs`
    /// value takes `cmd`. A value is a ref prefix, matched whole at a `/`,
    /// after optional `<modifiers>:` -- `a` creations, `d` deletions, `m`
    /// other updates, all three when none is named, and `!` taking every
    /// ref the prefix does not match.
    fn procReceiveRef(s: *Server, cmd: *const Command) bool {
        var it = s.remote.repo.configuration().iterate(&.{"receive.procreceiverefs"});
        while (it.next()) |entry| {
            const value = entry.value orelse continue;
            var add = true;
            var delete = true;
            var modify = true;
            var negative = false;
            var prefix = value;
            if (std.mem.findScalar(u8, value, ':')) |colon| {
                add = false;
                delete = false;
                modify = false;
                for (value[0..colon]) |c| switch (c) {
                    'a' => add = true,
                    'd' => delete = true,
                    'm' => modify = true,
                    '!' => negative = true,
                    else => {},
                };
                prefix = value[colon + 1 ..];
            }
            prefix = std.mem.trimEnd(u8, prefix, "/");
            if (!add and cmd.old.isZero()) continue;
            if (!delete and cmd.new.isZero()) continue;
            if (!modify and !cmd.old.isZero() and !cmd.new.isZero()) continue;
            const under = std.mem.startsWith(u8, cmd.name, prefix) and
                (cmd.name.len == prefix.len or cmd.name[prefix.len] == '/');
            if (under != negative) return true;
        }
        return false;
    }

    fn isCommit(s: *Server, oid: Oid) Self.Error!bool {
        if (!try s.db().exists(s.io, oid)) return false;
        return (try s.db().readHeader(s.io, oid)).type == .commit;
    }

    /// Whether `name` is the branch a working tree of this repository has
    /// checked out: git's `find_shared_symref` over its worktrees.
    /// git's `check_aliased_updates`: a command on a symbolic ref whose
    /// target another command updates is left to that one when the two
    /// agree, and both are refused when they do not; a symbolic ref that
    /// leads nowhere a ref can be is refused.
    fn checkAliasedUpdates(s: *Server, arena: Allocator, commands: []Command) Self.Error!void {
        for (commands) |*cmd| {
            if (!cmd.standing()) continue;
            const target = switch (try s.aliasOf(arena, cmd.name)) {
                .direct => continue,
                .broken => {
                    try s.rpError("refusing update to broken symref '{s}'", .{cmd.name});
                    cmd.skip_update = true;
                    cmd.error_string = "broken symref";
                    continue;
                },
                .target => |name| name,
            };
            const at = findCommand(commands, 0, target) orelse continue;
            const dst = &commands[at];
            cmd.skip_update = true;
            if (cmd.old.eql(dst.old) and cmd.new.eql(dst.new)) continue;
            dst.skip_update = true;
            const len = abbrev.defaultLength(s.remote.repo.configuration(), s.db());
            var bufs: [4][hash.max_hex_len]u8 = undefined;
            try s.rpError("refusing inconsistent update between symref '{s}' ({s}..{s}) and its target '{s}' ({s}..{s})", .{
                cmd.name,
                try abbrev.unique(s.io, s.db(), cmd.old, len, &bufs[0]),
                try abbrev.unique(s.io, s.db(), cmd.new, len, &bufs[1]),
                dst.name,
                try abbrev.unique(s.io, s.db(), dst.old, len, &bufs[2]),
                try abbrev.unique(s.io, s.db(), dst.new, len, &bufs[3]),
            });
            cmd.error_string = "inconsistent aliased update";
            dst.error_string = "inconsistent aliased update";
        }
    }

    const Alias = union(enum) { direct, broken, target: []const u8 };

    /// What `name` is as git's `refs_resolve_ref_unsafe` reads it without
    /// asking the ref to be there: not symbolic, the name at the end of its
    /// chain of symbolic refs (which need not exist), or broken -- deeper
    /// than git's five, or naming what no ref can be.
    fn aliasOf(s: *Server, arena: Allocator, name: []const u8) Self.Error!Alias {
        var current = name;
        for (0..5) |depth| {
            const found = try s.remote.repo.refStore().read(s.gpa, s.io, current) orelse
                return if (depth == 0) .direct else .{ .target = current };
            switch (found) {
                .direct => return if (depth == 0) .direct else .{ .target = current },
                .symbolic => |next| {
                    defer s.gpa.free(next);
                    if (!ref_names.checkFormat(next, .{ .allow_onelevel = true })) return .broken;
                    current = try arena.dupe(u8, next);
                },
            }
        }
        return .broken;
    }

    /// A working tree with a branch checked out: its path and its git
    /// directory, absolute, and whether it is a linked one.
    const CheckedOut = struct { path: []const u8, git_dir: []const u8, linked: bool };

    /// The working tree of this repository that has the branch `name`
    /// checked out: git's `find_shared_symref` over its worktrees, the
    /// main one first.
    fn checkedOut(s: *Server, arena: Allocator, name: []const u8) Self.Error!?CheckedOut {
        if (!std.mem.startsWith(u8, name, "refs/heads/")) return null;
        if (!s.remote.repo.isBare()) {
            if (try s.remote.repo.refStore().currentBranch(arena, s.io)) |branch| {
                if (std.mem.eql(u8, branch, name["refs/heads/".len..])) return .{
                    .path = try realPath(arena, s.io, s.remote.repo.topDirectory()),
                    .git_dir = try realPath(arena, s.io, s.remote.repo.gitDirectory()),
                    .linked = false,
                };
            }
        }
        var listing = s.remote.repo.listWorktrees(s.io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return null,
        };
        defer listing.deinit();
        for (listing.entries) |entry| {
            const branch = entry.branch orelse continue;
            if (std.mem.eql(u8, branch, name) or std.mem.eql(u8, branch, name["refs/heads/".len..])) {
                const common = try realPath(arena, s.io, s.remote.repo.commonDirectory());
                return .{
                    .path = try arena.dupe(u8, entry.path),
                    .git_dir = try Io.Dir.path.join(arena, &.{ common, "worktrees", entry.name }),
                    .linked = true,
                };
            }
        }
        return null;
    }

    /// git's `update_worktree`, for `receive.denyCurrentBranch=updateInstead`:
    /// the working tree that has the branch checked out brought to `new`
    /// before the branch moves, by the `push-to-checkout` hook when there is
    /// one (`GIT_DIR` and `GIT_WORK_TREE` set, the commit its argument),
    /// and otherwise as git's `push_to_deploy` brings it. The refusal, or
    /// `null`.
    fn updateWorktree(s: *Server, new: Oid, wt: CheckedOut) Self.Error!?[]const u8 {
        if (s.runner) |*runner| if (runner.exists(s.io, "push-to-checkout")) {
            var hex: [hash.max_hex_len]u8 = undefined;
            const set = [_]program.Var{ .{ .name = "GIT_DIR", .value = wt.git_dir }, .{ .name = "GIT_WORK_TREE", .value = wt.path } };
            const ran = try runner.run(s.io, "push-to-checkout", .{ .args = &.{new.hex(&hex)}, .set = &set });
            // Not on the side band: git runs this hook without it.
            defer runner.captured.clearRetainingCapacity();
            try s.diagnostics(runner.captured.items);
            return if (ran.succeeded()) null else "push-to-checkout hook declined";
        };
        return s.pushToDeploy(new, wt);
    }

    /// git's `push_to_deploy`: the working tree updated to `new` only when
    /// nothing in it differs from `HEAD`, untracked files and submodules
    /// aside, and nothing untracked is in the way; each step refused in
    /// git's words.
    fn pushToDeploy(s: *Server, new: Oid, wt: CheckedOut) Self.Error!?[]const u8 {
        var opened: ?repo_mod.Repository = null;
        defer if (opened) |*r| r.deinit(s.io);
        const repo: *repo_mod.Repository = if (wt.linked) blk: {
            var dir = Io.Dir.cwd().openDir(s.io, wt.path, .{}) catch return "Up-to-date check failed";
            defer dir.close(s.io);
            opened = repo_mod.Repository.open(s.gpa, s.io, dir, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return "Up-to-date check failed",
            };
            break :blk &opened.?;
        } else &s.remote.repo;

        // `update-index -q --refresh`: the index's lock, and no conflict.
        var locked = repo.lockIndex(s.io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return "Up-to-date check failed",
        };
        defer locked.deinit(s.io);
        const index = &locked.index;
        for (index.entries.items) |entry| {
            if (entry.stage != 0) return "Up-to-date check failed";
        }
        const head_tree = repo.headTree(s.io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return "Up-to-date check failed",
        };

        // `diff-files --quiet --ignore-submodules`, then
        // `diff-index --quiet --cached --ignore-submodules HEAD`.
        const changes = deploy: {
            const wt_dir = repo.workDirectory() orelse break :deploy error.BareRepository;
            var rules = try repo.worktreeRules();
            var attrs = try repo.loadAttrs(s.io);
            defer attrs.deinit();
            rules.attrs = &attrs;
            break :deploy checkout.status(s.gpa, s.io, wt_dir, .{ .index = index, .db = repo.objectDatabase() }, .{
                .rules = rules,
                .head_tree = head_tree,
                .untracked = .no,
            });
        };
        var status = changes catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return "Up-to-date check failed",
        };
        defer status.deinit();
        for (status.entries) |entry| {
            if (entry.submodule != null) continue;
            switch (entry.unstaged) {
                .unmodified, .untracked, .ignored => {},
                else => return "Working directory has unstaged changes",
            }
        }
        for (status.entries) |entry| {
            if (entry.submodule == null and entry.staged != .unmodified) return "Working directory has staged changes";
        }

        // `read-tree -u -m <new>`: what is checked out moved to `new`, an
        // untracked file in its way refusing it.
        const moved = move: {
            const new_tree = repo.commitTree(s.io, new) catch |err| break :move err;
            var outcome = three_way.fastForward(s.gpa, s.io, repo, .{ .index = index, .old = head_tree, .new = new_tree }, .{}) catch |err| break :move err;
            outcome.deinit();
            locked.commit(s.io) catch |err| break :move err;
        };
        moved catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return "Could not update working tree to new HEAD",
        };
        return null;
    }

    // ------------------------------------------------------------------
    // Hooks
    // ------------------------------------------------------------------

    /// `pre-receive` or `post-receive`: every command on standard input,
    /// `<old> SP <new> SP <ref>`, the push options in `GIT_PUSH_OPTION_*`,
    /// and the quarantine for `pre-receive`. With `skip_broken`, a refused
    /// command or a deletion of nothing is left out, and with none left
    /// the hook does not run. Whether it succeeded.
    fn runReceiveHook(s: *Server, request_arena: Allocator, event: []const u8, commands: []const Command, skip_broken: bool, push_options: []const []const u8, q: ?*const Quarantine) Self.Error!bool {
        const runner = if (s.runner) |*r| r else return true;
        if (!runner.exists(s.io, event)) return true;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var input: std.ArrayList(u8) = .empty;
        for (commands) |cmd| {
            if (skip_broken and (!cmd.standing() or cmd.did_not_exist)) continue;
            // A proc-receive hook's updates in place of the command's own.
            for (cmd.reports.items) |r| {
                try input.print(arena, "{f} {f} {s}\n", .{ r.old orelse cmd.old, r.new orelse cmd.new, r.name orelse cmd.name });
            }
            if (cmd.reports.items.len == 0) try input.print(arena, "{f} {f} {s}\n", .{ cmd.old, cmd.new, cmd.name });
        }
        if (input.items.len == 0) return true;
        var set: std.ArrayList(program.Var) = .empty;
        for (push_options, 0..) |option, i| try set.append(arena, .{ .name = try arena.print("GIT_PUSH_OPTION_{d}", .{i}), .value = option });
        try set.append(arena, .{ .name = "GIT_PUSH_OPTION_COUNT", .value = try arena.print("{d}", .{push_options.len}) });
        if (q) |held| {
            for (try held.environment(arena, s.options.inherited_alternates)) |v| try set.append(arena, .{ .name = v.name, .value = v.value });
        }
        try set.appendSlice(arena, try s.certificateVars(request_arena));
        const ran = try runner.run(s.io, event, .{ .input = input.items, .set = set.items });
        try s.sendHookOutput();
        return ran.succeeded();
    }

    /// git's `prepare_push_cert_sha1`: a signed push's certificate kept as a
    /// blob, its signature checked and its nonce held to the one asked
    /// for, told to the receive hooks as `GIT_PUSH_CERT` and the rest. Done
    /// once, at the first hook that runs; nothing without a certificate.
    fn certificateVars(s: *Server, arena: Allocator) Self.Error![]const program.Var {
        if (s.certificate_vars) |done| return done;
        const cert = s.certificate orelse return &.{};
        if (cert.len == 0) return &.{};
        var vars: std.ArrayList(program.Var) = .empty;
        // In the repository itself, quarantine or not, as git writes it.
        const oid: ?Oid = s.db().write(s.io, .blob, cert) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => null,
        };
        const at = signing.signedOffset(cert);
        const payload = cert[0..at];
        // git dies on a certificate whose signature it cannot name.
        if (signing.Format.of(cert[at..]) == null) return error.ProtocolError;
        var result: signing.Result = .none;
        var signer_name: []const u8 = "";
        var key: []const u8 = "";
        verify: {
            var signer = signing.Signer.init(s.gpa, s.io, s.remote.repo.configuration(), s.remote.repo.gitDirectory(), s.options.programs.?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => break :verify,
            };
            defer signer.deinit();
            var verdict = signer.verify(s.io, payload, cert[at..], null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => break :verify,
            };
            defer verdict.deinit();
            result = verdict.result;
            if (verdict.signer) |name| signer_name = try arena.dupe(u8, name);
            if (verdict.key) |k| key = try arena.dupe(u8, k);
        }
        const nonce = try s.checkNonce(arena, payload);
        if (oid) |o| {
            try vars.append(arena, .{ .name = "GIT_PUSH_CERT", .value = try arena.print("{f}", .{o}) });
            try vars.append(arena, .{ .name = "GIT_PUSH_CERT_SIGNER", .value = signer_name });
            try vars.append(arena, .{ .name = "GIT_PUSH_CERT_KEY", .value = key });
            try vars.append(arena, .{ .name = "GIT_PUSH_CERT_STATUS", .value = try arena.dupe(u8, &.{result.checkLetter()}) });
            if (s.nonce != null) {
                try vars.append(arena, .{ .name = "GIT_PUSH_CERT_NONCE", .value = nonce.reported });
                try vars.append(arena, .{ .name = "GIT_PUSH_CERT_NONCE_STATUS", .value = @tagName(nonce.status) });
                if (nonce.status == .SLOP) try vars.append(arena, .{ .name = "GIT_PUSH_CERT_NONCE_SLOP", .value = try arena.print("{d}", .{nonce.slop}) });
            }
        }
        s.certificate_vars = vars.items;
        return vars.items;
    }

    const NonceStatus = enum { MISSING, UNSOLICITED, OK, BAD, SLOP };
    const NonceCheck = struct {
        status: NonceStatus,
        /// The nonce the hooks are told was asked for: this server's, or
        /// another's it takes as its own within `receive.certNonceSlop`.
        reported: []const u8 = "",
        /// How many seconds older the certificate's nonce is than this
        /// server's.
        slop: i64 = 0,
    };

    /// git's `check_nonce`: the certificate's `nonce` header against the
    /// one this server asked for. Over HTTP, where each request is a
    /// server of its own, another's nonce for this repository and seed is
    /// recognised by its HMAC and judged by how far apart the two were
    /// made.
    fn checkNonce(s: *Server, arena: Allocator, payload: []const u8) Allocator.Error!NonceCheck {
        const ours = s.nonce orelse "";
        const span = object.findHeader(payload, 0, "nonce") orelse return .{ .status = .MISSING, .reported = ours };
        const theirs = payload[span.start..span.end];
        if (s.nonce == null) return .{ .status = .UNSOLICITED };
        if (std.mem.eql(u8, ours, theirs)) return .{ .status = .OK, .reported = ours };
        const bad: NonceCheck = .{ .status = .BAD, .reported = ours };
        if (!s.options.stateless) return bad;
        // `<seconds>-<hmac>`
        if (theirs.len == 0 or theirs[0] <= '0' or theirs[0] > '9') return bad;
        const stamp = decimal.strtoul(theirs, 10, 64);
        if (stamp.end == 0 or stamp.end >= theirs.len or theirs[stamp.end] != '-') return bad;
        if (stamp.value > std.math.maxInt(i64)) return bad;
        const expect = try certNonce(arena, s.kind(), s.options.service_dir, s.settings.cert_nonce_seed.?, @intCast(stamp.value));
        if (expect.len != theirs.len) return bad;
        var differ: u8 = 0;
        for (expect, theirs) |a, b| differ |= a ^ b;
        if (differ != 0) return bad;
        const issued = decimal.strtoul(ours, 10, 64).value;
        const slop: i64 = @as(i64, @intCast(issued)) - @as(i64, @intCast(stamp.value));
        const limit = s.settings.cert_nonce_slop;
        if (limit != 0 and @abs(slop) <= limit) return .{ .status = .OK, .reported = theirs, .slop = slop };
        return .{ .status = .SLOP, .reported = ours, .slop = slop };
    }

    /// `update <ref> <old> <new>`. Whether it let the command through.
    fn runUpdateHook(s: *Server, cmd: *const Command) Self.Error!bool {
        const runner = if (s.runner) |*r| r else return true;
        if (!runner.exists(s.io, "update")) return true;
        var old_hex: [hash.max_hex_len]u8 = undefined;
        var new_hex: [hash.max_hex_len]u8 = undefined;
        const ran = try runner.run(s.io, "update", .{ .args = &.{ cmd.name, cmd.old.hex(&old_hex), cmd.new.hex(&new_hex) } });
        try s.sendHookOutput();
        return ran.succeeded();
    }

    /// `post-update <ref>...`: every ref the push changed.
    fn runPostUpdate(s: *Server, arena: Allocator, commands: []const Command) Self.Error!void {
        const runner = if (s.runner) |*r| r else return;
        if (!runner.exists(s.io, "post-update")) return;
        var args: std.ArrayList([]const u8) = .empty;
        for (commands) |cmd| {
            if (!cmd.standing() or cmd.did_not_exist) continue;
            try args.append(arena, cmd.name);
        }
        if (args.items.len == 0) return;
        _ = try runner.run(s.io, "post-update", .{ .args = args.items });
        try s.sendHookOutput();
    }

    /// What the hooks printed, to the client on channel two, or to this
    /// process's standard error with no side-band, as git sends it.
    fn sendHookOutput(s: *Server) Self.Error!void {
        const runner = if (s.runner) |*r| r else return;
        defer runner.captured.clearRetainingCapacity();
        if (runner.captured.items.len == 0) return;
        try s.message(runner.captured.items);
    }

    fn message(s: *Server, text: []const u8) Self.Error!void {
        if (s.asked.band != .none) return s.send(.message, text);
        if (builtin.is_test) return;
        var buffer: [256]u8 = undefined;
        var stderr = Io.File.stderr().writerStreaming(s.io, &buffer);
        stderr.interface.writeAll(text) catch {}; // glint-ignore: Z026 -- a message to a closed standard error has nowhere else to go, as git's has not
        stderr.interface.flush() catch {}; // glint-ignore: Z026 -- as above
    }

    /// What git writes on its own standard error rather than the side band:
    /// this process's, as git's is.
    fn diagnostics(s: *Server, text: []const u8) Self.Error!void {
        if (text.len == 0 or builtin.is_test) return;
        var buffer: [256]u8 = undefined;
        var stderr = Io.File.stderr().writerStreaming(s.io, &buffer);
        stderr.interface.writeAll(text) catch {}; // glint-ignore: Z026 -- a message to a closed standard error has nowhere else to go, as git's has not
        stderr.interface.flush() catch {}; // glint-ignore: Z026 -- as above
    }

    fn rpError(s: *Server, comptime fmt: []const u8, args: anytype) Self.Error!void {
        try s.rpLine("error: " ++ fmt, args);
    }

    fn rpErrorPlain(s: *Server, comptime fmt: []const u8, args: anytype) Self.Error!void {
        try s.rpLine("error: " ++ fmt, args);
    }

    fn rpWarning(s: *Server, comptime fmt: []const u8, args: anytype) Self.Error!void {
        try s.rpLine("warning: " ++ fmt, args);
    }

    fn rpLine(s: *Server, comptime fmt: []const u8, args: anytype) Self.Error!void {
        var buffer: [1024]u8 = undefined;
        const text = std.mem.print(&buffer, fmt ++ "\n", args) catch return;
        try s.message(text);
    }

    // ------------------------------------------------------------------
    // The report
    // ------------------------------------------------------------------

    /// git's `report` and `report_v2`, on the side-band when there is one.
    fn report(s: *Server, commands: []const Command, unpack_status: ?[]const u8) Self.Error!void {
        if (!s.asked.report_status and !s.asked.report_status_v2) return;
        var buf: Io.Writer.Allocating = .init(s.gpa);
        defer buf.deinit();
        const w = &buf.writer;
        (write: {
            pkt_line.print("unpack {s}\n", .{unpack_status orelse "ok"}, w) catch |e| break :write e;
            for (commands) |cmd| {
                if (cmd.error_string) |why| {
                    pkt_line.print("ng {s} {s}\n", .{ cmd.name, why }, w) catch |e| break :write e;
                    continue;
                }
                pkt_line.print("ok {s}\n", .{cmd.name}, w) catch |e| break :write e;
                // What a proc-receive hook made of it, in v2 alone.
                if (!s.asked.report_status_v2) continue;
                for (cmd.reports.items, 0..) |r, i| {
                    if (i > 0) pkt_line.print("ok {s}\n", .{cmd.name}, w) catch |e| break :write e;
                    if (r.name) |name| pkt_line.print("option refname {s}\n", .{name}, w) catch |e| break :write e;
                    if (r.old) |oid| pkt_line.print("option old-oid {f}\n", .{oid}, w) catch |e| break :write e;
                    if (r.new) |oid| pkt_line.print("option new-oid {f}\n", .{oid}, w) catch |e| break :write e;
                    if (r.forced) pkt_line.write(w, "option forced-update\n") catch |e| break :write e;
                }
            }
            pkt_line.flush(w) catch |e| break :write e;
        }) catch return error.OutOfMemory;
        try s.send(.report, buf.written());
    }
};

/// The boundary commits `tip`'s history reaches among `client`, walking
/// only the commits the pushed pack holds.
fn shallowRoots(arena: Allocator, io: Io, index: *const pack.Index, repo: *repo_mod.Repository, tip: Oid, client: *const Oid.Set) Self.Error![]const Oid {
    var out: std.ArrayList(Oid) = .empty;
    var seen: Oid.Set = .empty;
    var stack: std.ArrayList(Oid) = .empty;
    try stack.append(arena, tip);
    while (stack.pop()) |oid| {
        if ((try seen.getOrPut(arena, oid)).found_existing) continue;
        if (client.contains(oid)) {
            try out.append(arena, oid);
            continue;
        }
        if ((index.find(oid) catch null) == null) continue;
        const found = repo.objectDatabase().read(io, oid) catch continue;
        defer repo.objectDatabase().allocator().free(found.bytes);
        if (found.type != .commit) continue;
        var commit = object.Commit.parse(arena, repo.objectFormat(), found.bytes) catch continue;
        defer commit.deinit();
        for (commit.parents) |p| try stack.append(arena, p);
    }
    return out.items;
}

/// git's `read_push_options`: lines to a flush.
fn readPushOptions(arena: Allocator, in: *Io.Reader, out: *std.ArrayList([]const u8)) Self.Error!void {
    while (true) {
        const packet = pkt_line.read(in) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => return error.ProtocolError,
        };
        const raw = switch (packet) {
            .data => |d| d,
            else => return,
        };
        const line = if (raw.len != 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        try out.append(arena, try arena.dupe(u8, line));
    }
}

/// The absolute path of `dir`, in `arena`.
fn realPath(arena: Allocator, io: Io, dir: Io.Dir) Self.Error![]const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const len = dir.realPath(io, &buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.ProtocolError,
    };
    return arena.dupe(u8, buf[0..len]);
}

/// git's `prepare_push_cert_nonce`: `<stamp>-<hmac>`, the HMAC in the
/// repository's hash keyed with `<dir>:<stamp>` over the seed, as git
/// keys it.
fn certNonce(gpa: Allocator, kind: hash.Kind, dir: []const u8, seed: []const u8, stamp: i64) Allocator.Error![]u8 {
    const key = try gpa.print("{s}:{d}", .{ dir, stamp });
    defer gpa.free(key);
    var mac: [32]u8 = undefined;
    const len: usize = switch (kind) {
        .sha1 => blk: {
            std.crypto.auth.hmac.HmacSha1.create(mac[0..20], seed, key);
            break :blk 20;
        },
        .sha256 => blk: {
            std.crypto.auth.hmac.sha2.HmacSha256.create(mac[0..32], seed, key);
            break :blk 32;
        },
    };
    return gpa.print("{d}-{x}", .{ stamp, mac[0..len] });
}

/// git's `check_cert_push_options`: the certificate's `push-option`
/// headers are the push options sent, in order.
fn certificateOptionsMatch(cert: []const u8, options: []const []const u8) bool {
    if (cert.len == 0) return true;
    var from: usize = 0;
    var seen: usize = 0;
    while (object.findHeader(cert, from, "push-option")) |span| {
        if (seen >= options.len or !std.mem.eql(u8, options[seen], cert[span.start..span.end])) return false;
        seen += 1;
        from = span.end + 1;
    }
    return seen == options.len;
}

/// git's `parse_pack_header`, looking at the pack without taking it: how
/// many objects it says it holds, or git's words for why it is no pack.
fn packHeader(in: *Io.Reader) union(enum) { count: u32, refused: []const u8 } {
    const head = in.peek(12) catch return .{ .refused = "eof before pack header was fully read" };
    if (!std.mem.eql(u8, head[0..4], "PACK")) return .{ .refused = "protocol error (pack signature mismatch detected)" };
    const version = std.mem.readInt(u32, head[4..8], .big);
    if (version != 2 and version != 3) return .{ .refused = "protocol error (pack version unsupported)" };
    return .{ .count = std.mem.readInt(u32, head[8..12], .big) };
}

/// A packet's text without its one trailing newline, as git's reader
/// chomps it.
fn chompLine(raw: []const u8) []const u8 {
    return if (raw.len != 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
}

/// git's `parse_feature_request`: whether `list`, words apart, names
/// `feature`, alone or with a value.
fn hasFeature(list: []const u8, feature: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |word| {
        const name = word[0 .. std.mem.findScalar(u8, word, '=') orelse word.len];
        if (std.mem.eql(u8, name, feature)) return true;
    }
    return false;
}

/// git's `find_command_by_refname`: the first command from `from` on
/// that names `name`.
fn findCommand(commands: []const Command, from: usize, name: []const u8) ?usize {
    for (commands[from..], from..) |cmd, i| {
        if (std.mem.eql(u8, cmd.name, name)) return i;
    }
    return null;
}

/// Whether `io` runs a second task beside this one, asked by running an
/// empty one.
fn canRunBeside(io: Io) bool {
    var probe = io.concurrent(nothing, .{}) catch return false;
    probe.await(io);
    return true;
}

fn nothing() void {}

fn deleteOnly(commands: []const Command) bool {
    for (commands) |cmd| if (!cmd.new.isZero()) return false;
    return true;
}

fn sortedShallow(gpa: Allocator, db: *odb_mod.Odb) Allocator.Error![]Oid {
    const boundary = try gpa.alloc(Oid, db.shallow.count());
    var it = db.shallow.keyIterator();
    var i: usize = 0;
    while (it.next()) |oid| : (i += 1) boundary[i] = oid.*;
    std.mem.sort(Oid, boundary, {}, struct {
        fn lessThan(_: void, a: Oid, b: Oid) bool {
            return a.order(b) == .lt;
        }
    }.lessThan);
    return boundary;
}

/// What git says when a push to the checked-out branch is refused with
/// `receive.denyCurrentBranch` unset.
const refuse_unconfigured_deny =
    \\By default, updating the current branch in a non-bare repository
    \\is denied, because it will make the index and work tree inconsistent
    \\with what you pushed, and will require 'git reset --hard' to match
    \\the work tree to HEAD.
    \\
    \\You can set the 'receive.denyCurrentBranch' configuration variable
    \\to 'ignore' or 'warn' in the remote repository to allow pushing into
    \\its current branch; however, this is not recommended unless you
    \\arranged to update its work tree to match what you pushed in some
    \\other way.
    \\
    \\To squelch this message and still keep the default behaviour, set
    \\'receive.denyCurrentBranch' configuration variable to 'refuse'.
;

/// What git says when a deletion of the current branch is refused with
/// `receive.denyDeleteCurrent` unset.
const refuse_unconfigured_deny_delete_current =
    \\By default, deleting the current branch is denied, because the next
    \\'git clone' won't result in any file checked out, causing confusion.
    \\
    \\You can set 'receive.denyDeleteCurrent' configuration variable to
    \\'warn' or 'ignore' in the remote repository to allow deleting the
    \\current branch, with or without a warning message.
    \\
    \\To squelch this message, you can set it to 'refuse'.
;

/// git's `update` when a ref cannot be staged at all.
fn stageError(err: refs_mod.TransactionError) Self.Error!?[]const u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => "failed to update ref",
    };
}

fn writeError(err: (pkt_line.WriteError || Self.Error)) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.PacketTooLong, error.WriteFailed => error.WriteFailed,
        else => |e| @errorCast(e),
    };
}

/// Refuse a repository that has a hook a push would run, when the caller
/// gave no permission to run it.
pub fn checkHooks(io: Io, repo: *repo_mod.Repository) local.Error!void {
    const hooks_path = repo.configuration().get("core.hookspath");
    var dir = (if (hooks_path) |path|
        Io.Dir.cwd().openDir(io, path, .{})
    else
        repo.commonDirectory().openDir(io, "hooks", .{})) catch return;
    defer dir.close(io);
    for ([_][]const u8{
        "pre-receive",  "update",           "post-receive",          "post-update",
        "proc-receive", "push-to-checkout", "reference-transaction",
    }) |name| {
        if (dir.statFile(io, name, .{})) |stat| {
            if (stat.kind == .file and (builtin.target.os.tag == .windows or stat.permissions.toMode() & 0o111 != 0))
                return error.RemoteHooksNotRun;
        } else |_| {}
        if (builtin.target.os.tag != .windows) continue;
        var name_buf: [64]u8 = undefined;
        // unreachable: the longest hook name above, reference-transaction, is 21 bytes, 25 with .exe
        const executable = std.mem.print(&name_buf, "{s}.exe", .{name}) catch unreachable;
        const stat = dir.statFile(io, executable, .{}) catch continue;
        if (stat.kind != .file) continue;
        return error.RemoteHooksNotRun;
    }
}

/// A push to `remote`'s own receive-pack, in this process: the request
/// answered whole as it is sent, as over HTTP. The result is the caller's;
/// closing it closes `remote` too.
pub fn connect(gpa: Allocator, io: Io, remote: *local.Remote, options: Options) Self.Error!*Connection {
    const c = try gpa.create(InProcess);
    errdefer gpa.destroy(c);
    var serving = options;
    serving.stateless = true;
    c.* = .{
        .gpa = gpa,
        .remote = remote,
        .server = try .init(gpa, io, remote, .v0, serving),
        .connection = .{ .context = c, .vtable = &InProcess.vtable, .stateless = true },
    };
    return &c.connection;
}

const InProcess = struct {
    gpa: Allocator,
    remote: *local.Remote,
    server: Server,
    connection: Connection,
    request_bytes: Io.Writer.Allocating = undefined,
    response_bytes: Io.Writer.Allocating = undefined,
    started: bool = false,
    fixed: Io.Reader = undefined,
    limited: Io.Reader.Limited = undefined,
    buffer: [pkt_line.max_line]u8 = undefined,
    request_fixed: Io.Reader = undefined,
    request_limited: Io.Reader.Limited = undefined,
    request_buffer: [pkt_line.max_line]u8 = undefined,

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .deinit = deinit,
    };

    fn self(context: *anyopaque) *InProcess {
        return @ptrCast(@alignCast(context)); // safe: the context handed out with this vtable is an InProcess
    }

    fn start(c: *InProcess) void {
        if (c.started) return;
        c.started = true;
        c.request_bytes = .init(c.gpa);
        c.response_bytes = .init(c.gpa);
    }

    fn answer(c: *InProcess) *Io.Reader {
        c.fixed = .fixed(c.response_bytes.written());
        c.limited = c.fixed.limited(.unlimited, &c.buffer);
        return &c.limited.interface;
    }

    fn advertisement(context: *anyopaque, conn: *Connection) connection.Error!*Io.Reader {
        const c = self(context);
        c.start();
        c.response_bytes.clearRetainingCapacity();
        c.server.advertise(&c.response_bytes.writer) catch |err| return fail(conn, err);
        return c.answer();
    }

    fn request(context: *anyopaque, _: *Connection) connection.Error!*Io.Writer {
        const c = self(context);
        c.start();
        c.request_bytes.clearRetainingCapacity();
        return &c.request_bytes.writer;
    }

    fn response(context: *anyopaque, conn: *Connection) connection.Error!*Io.Reader {
        const c = self(context);
        c.response_bytes.clearRetainingCapacity();
        c.request_fixed = .fixed(c.request_bytes.written());
        c.request_limited = c.request_fixed.limited(.unlimited, &c.request_buffer);
        c.server.serveRequest(&c.request_limited.interface, &c.response_bytes.writer) catch |err| return fail(conn, err);
        return c.answer();
    }

    fn fail(conn: *Connection, err: Error) connection.Error {
        conn.setMessage(@errorName(err));
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.ConnectionFailed,
        };
    }

    fn failure(_: *anyopaque, _: *Connection) connection.Error {
        return error.ConnectionFailed;
    }

    fn deinit(io: Io, context: *anyopaque) void {
        const c = self(context);
        if (c.started) {
            c.request_bytes.deinit();
            c.response_bytes.deinit();
        }
        c.server.deinit();
        c.remote.deinit(io);
        c.gpa.destroy(c.remote);
        c.gpa.destroy(c);
    }
};

const testremote = @import("../testing/remote.zig");

test "a certificate's nonce is judged as git's check_nonce judges it: by its HMAC and age over HTTP, by itself otherwise" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.create(gpa, io, tmp.dir, .{ .bare = true });
    repo.deinit(io);
    const config = try tmp.dir.readFileAlloc(io, "config", gpa, .unlimited);
    defer gpa.free(config);
    const with_seed = try std.mem.concat(gpa, u8, &.{ config, "[receive]\n\tcertNonceSeed = a seed\n\tcertNonceSlop = 10\n" });
    defer gpa.free(with_seed);
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = with_seed });
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var remote = try local.Remote.open(gpa, io, path, .{});
    defer remote.deinit(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const who: object.Signature = .{ .name = "t", .email = "t@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };
    for ([_]bool{ true, false }) |stateless| {
        var server: Server = try .init(gpa, io, &remote, .v0, .{ .stateless = stateless, .who = who });
        defer server.deinit();
        const ours = server.nonce.?;
        try std.testing.expect(std.mem.startsWith(u8, ours, "1700000000-"));
        const Case = struct { payload: []const u8, status: Server.NonceStatus, slop: i64 = 0, reported: []const u8 };
        const near = try certNonce(arena, .sha1, ".", "a seed", 1_699_999_995);
        const far = try certNonce(arena, .sha1, ".", "a seed", 1_699_999_000);
        const forged = try certNonce(arena, .sha1, ".", "another seed", 1_699_999_995);
        const cases = [_]Case{
            .{ .payload = try arena.print("pusher k 1 +0000\nnonce {s}\n\n", .{ours}), .status = .OK, .reported = ours },
            .{ .payload = "pusher k 1 +0000\n\nnonce 1-2\n", .status = .MISSING, .reported = ours },
            .{ .payload = try arena.print("nonce {s}\n\n", .{near}), .status = if (stateless) .OK else .BAD, .slop = if (stateless) 5 else 0, .reported = if (stateless) near else ours },
            .{ .payload = try arena.print("nonce {s}\n\n", .{far}), .status = if (stateless) .SLOP else .BAD, .slop = if (stateless) 1000 else 0, .reported = ours },
            .{ .payload = try arena.print("nonce {s}\n\n", .{forged}), .status = .BAD, .reported = ours },
            .{ .payload = "nonce 0170-abc\n\n", .status = .BAD, .reported = ours },
            .{ .payload = "nonce 99999999999999999999-abc\n\n", .status = .BAD, .reported = ours },
        };
        for (cases) |case| {
            const got = try server.checkNonce(arena, case.payload);
            try std.testing.expectEqual(case.status, got.status);
            try std.testing.expectEqual(case.slop, got.slop);
            try std.testing.expectEqualStrings(case.reported, got.reported);
        }
    }
    // The certificate's push options are the ones sent, in order; an empty
    // certificate says nothing of them.
    try std.testing.expect(certificateOptionsMatch("pusher k\npush-option x\npush-option y\n\npush-option z\n", &.{ "x", "y" }));
    try std.testing.expect(!certificateOptionsMatch("push-option x\n\n", &.{ "x", "y" }));
    try std.testing.expect(!certificateOptionsMatch("push-option y\npush-option x\n\n", &.{ "x", "y" }));
    try std.testing.expect(!certificateOptionsMatch("push-option x\n\n", &.{}));
    try std.testing.expect(certificateOptionsMatch("", &.{"x"}));
}

test "a push certificate's nonce is made as git 2.55's receive-pack makes it, in either object format" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "sha1", "sha256" }) |format| {
        var root = std.testing.tmpDir(.{});
        defer root.cleanup();
        var env = try testremote.environ(gpa);
        defer env.deinit();
        const format_arg = try gpa.print("--object-format={s}", .{format});
        defer gpa.free(format_arg);
        const out = try testremote.gitInputEnv(gpa, io, root.dir, &env, &.{ "init", "-q", "--bare", format_arg, "repo.git" }, "", true);
        gpa.free(out);
        var repo_dir = try root.dir.openDir(io, "repo.git", .{});
        defer repo_dir.close(io);
        const set = try testremote.gitInputEnv(gpa, io, repo_dir, &env, &.{ "config", "receive.certNonceSeed", "a seed" }, "", true);
        gpa.free(set);
        // git keys the nonce with the path it was started on.
        const advertised = try testremote.gitInputEnv(gpa, io, root.dir, &env, &.{ "receive-pack", "--advertise-refs", "repo.git" }, "", true);
        defer gpa.free(advertised);
        const start = (std.mem.find(u8, advertised, "push-cert=") orelse return error.TestUnexpectedResult) + "push-cert=".len;
        const end = std.mem.findAnyPos(u8, advertised, start, " \n").?;
        const theirs = advertised[start..end];
        const dash = std.mem.findScalar(u8, theirs, '-').?;
        const stamp: i64 = @intCast(decimal.strtol(theirs[0..dash], 10, 64).value);
        const ours = try certNonce(gpa, if (std.mem.eql(u8, format, "sha1")) .sha1 else .sha256, "repo.git", "a seed", stamp);
        defer gpa.free(ours);
        try std.testing.expectEqualStrings(theirs, ours);
    }
}

test "a pack's header is read as git's parse_pack_header reads it, and left for the indexer" {
    const Case = struct { bytes: []const u8, refused: ?[]const u8, count: u32 = 0 };
    const cases = [_]Case{
        .{ .bytes = "PACK\x00\x00\x00\x02\x00\x00\x01\x2cmore", .refused = null, .count = 300 },
        .{ .bytes = "PACK\x00\x00\x00\x03\x00\x00\x00\x01", .refused = null, .count = 1 },
        .{ .bytes = "PACK\x00\x00\x00", .refused = "eof before pack header was fully read" },
        .{ .bytes = "KCAP\x00\x00\x00\x02\x00\x00\x00\x01", .refused = "protocol error (pack signature mismatch detected)" },
        .{ .bytes = "PACK\x00\x00\x00\x04\x00\x00\x00\x01", .refused = "protocol error (pack version unsupported)" },
    };
    for (cases) |case| {
        var in: Io.Reader = .fixed(case.bytes);
        switch (packHeader(&in)) {
            .count => |n| {
                try std.testing.expect(case.refused == null);
                try std.testing.expectEqual(case.count, n);
                try std.testing.expectEqual(@as(usize, 0), in.seek);
            },
            .refused => |why| try std.testing.expectEqualStrings(case.refused.?, why),
        }
    }
}

test "fuzz: whatever a client sends is answered or refused" {
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
    var server: Server = try .init(std.testing.allocator, std.testing.io, remote, .v0, .{ .stateless = true, .who = .{ .name = "t", .email = "t@example.com", .when_secs = 0, .offset_minutes = 0 } });
    defer server.deinit();
    var fixed: Io.Reader = .fixed(input);
    var buffer: [pkt_line.max_line]u8 = undefined;
    var limited = fixed.limited(.unlimited, &buffer);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // glint-ignore: Z026 -- refusing a malformed request is the expected outcome; only a crash or a leak fails the fuzzer
    server.serveRequest(&limited.interface, &out.writer) catch {};
}
