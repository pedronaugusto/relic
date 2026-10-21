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
//! each alone or, for an atomic push, all together. The report follows —
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
    max_input_size: ?u64,

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
            .max_input_size = if (max > 0) @intCast(max) else null,
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
    /// to update, not the ref transaction's.
    proc_receive: bool = false,

    fn standing(c: *const Command) bool {
        return c.error_string == null;
    }
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
    /// Where the conversation's messages go: the client's side-band.
    out: ?*Io.Writer = null,
    /// The boundary commits a shallow push brings, written once its refs
    /// are.
    new_shallow: Oid.Set = .empty,

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
                    const resolved = (try s.remote.repo.refStore().resolve(s.gpa, s.io, entry.name)) orelse continue;
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
        s.out = out;
        defer s.out = null;

        var shallow: std.ArrayList(Oid) = .empty;
        const commands = try s.readCommands(arena, in, &shallow);
        if (commands.len == 0) {
            out.flush() catch return error.WriteFailed;
            return;
        }
        var push_options: std.ArrayList([]const u8) = .empty;
        if (s.asked.push_options) try readPushOptions(arena, in, &push_options);

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
        if (!deleteOnly(commands)) {
            q = try Quarantine.begin(s.gpa, s.io, s.db());
            var diagnostic: index_pack.Diagnostic = .{};
            received = s.unpack(in, &q.?, &diagnostic) catch |err| switch (err) {
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
                    unpack_status = "index-pack abnormal exit";
                    break :blk null;
                },
            };
            if (received != null) try s.checkShallow(arena, commands, shallow.items, &received.?);
        }

        try s.execute(arena, commands, unpack_status, &q, &received, &keeps, push_options.items);
        try s.report(commands, unpack_status);
        _ = try s.runReceiveHook("post-receive", commands, true, push_options.items, null);
        try s.runPostUpdate(arena, commands);
        if (s.asked.band != .none) pkt_line.flush(out) catch return error.WriteFailed;
        out.flush() catch return error.WriteFailed;
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
            try commands.append(arena, try s.parseCommand(arena, line));
        }
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

        fn deinit(r: *Received, io: Io) void {
            if (r.index) |*i| i.deinit();
            r.links.deinit();
            r.result.deinit(io);
        }
    };

    /// git's `unpack`: the pack indexed into the quarantine and checked by
    /// `receive.fsckObjects`'s rules.
    fn unpack(s: *Server, in: *Io.Reader, q: *Quarantine, diagnostic: *index_pack.Diagnostic) !Received {
        const config = s.remote.repo.configuration();
        var rules = try fsck.forTransfer(s.gpa, s.io, config, .{ .kind = s.kind(), .scope = .receive, .base = s.remote.repo.gitDirectory() }, .{});
        defer if (rules) |*r| r.deinit(s.gpa);
        var received: Received = .{ .result = undefined, .links = .init(s.gpa) };
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
            if (cmd.standing() and s.procReceiveRef(cmd.name)) {
                cmd.proc_receive = true;
                any_proc_receive = true;
            }
        }
        if (!try s.runReceiveHook("pre-receive", commands, false, push_options, if (q.*) |*held| held else null)) {
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
            if (received.*) |*r| if (r.index) |*i| {
                i.deinit();
                r.index = null;
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
        }

        const head = try s.remote.repo.refStore().currentBranch(arena, s.io);
        const head_ref: ?[]const u8 = if (head) |h| try arena.print("refs/heads/{s}", .{h}) else null;
        if (any_proc_receive and !try s.runProcReceive()) {
            // An atomic push fails whole with it.
            for (commands) |*cmd| {
                if (cmd.standing() and (cmd.proc_receive or s.asked.atomic)) cmd.error_string = "fail to run proc-receive hook";
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
                if (!cmd.standing() or cmd.proc_receive or cmd.new.isZero() != deletions) continue;
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
            if (!cmd.standing()) continue;
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
        if (checked_out) switch (s.settings.deny_current_branch) {
            .ignore => {},
            .warn => try s.rpWarning("updating the current branch", .{}),
            // Updating the working tree in its place is not done; the push
            // is refused as with no setting.
            .refuse, .unconfigured, .update_instead => {
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
            if (checked_out or is_head) switch (s.settings.deny_delete_current) {
                .ignore => {},
                .warn => try s.rpWarning("deleting the current branch", .{}),
                .refuse, .unconfigured, .update_instead => {
                    try s.rpError("refusing to delete the current branch: {s}", .{name});
                    if (s.settings.deny_delete_current == .unconfigured) try s.rpError("{s}", .{refuse_unconfigured_deny_delete_current});
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

    /// git's `run_proc_receive_hook`: whether the hook ran and answered.
    fn runProcReceive(s: *Server) Self.Error!bool {
        const runner = if (s.runner) |*r| r else return false;
        if (!runner.exists(s.io, "proc-receive")) {
            try s.rpError("cannot find hook 'proc-receive'", .{});
            return false;
        }
        return false;
    }

    /// Whether `name` is under a `receive.procReceiveRefs` prefix, its
    /// `<modifiers>:` passed over.
    fn procReceiveRef(s: *Server, name: []const u8) bool {
        var it = s.remote.repo.configuration().iterate(&.{"receive.procreceiverefs"});
        while (it.next()) |entry| {
            const value = entry.value orelse continue;
            const prefix = if (std.mem.findScalar(u8, value, ':')) |colon| value[colon + 1 ..] else value;
            if (prefix.len != 0 and std.mem.startsWith(u8, name, prefix)) return true;
        }
        return false;
    }

    fn isCommit(s: *Server, oid: Oid) Self.Error!bool {
        if (!try s.db().exists(s.io, oid)) return false;
        return (try s.db().readHeader(s.io, oid)).type == .commit;
    }

    /// Whether `name` is the branch a working tree of this repository has
    /// checked out: git's `find_shared_symref` over its worktrees.
    fn checkedOut(s: *Server, arena: Allocator, name: []const u8) Self.Error!bool {
        if (!std.mem.startsWith(u8, name, "refs/heads/")) return false;
        if (!s.remote.repo.isBare()) {
            if (try s.remote.repo.refStore().currentBranch(arena, s.io)) |branch| {
                if (std.mem.eql(u8, branch, name["refs/heads/".len..])) return true;
            }
        }
        var listing = s.remote.repo.listWorktrees(s.io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return false,
        };
        defer listing.deinit();
        for (listing.entries) |entry| {
            const branch = entry.branch orelse continue;
            if (std.mem.eql(u8, branch, name) or std.mem.eql(u8, branch, name["refs/heads/".len..])) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Hooks
    // ------------------------------------------------------------------

    /// `pre-receive` or `post-receive`: every command on standard input,
    /// `<old> SP <new> SP <ref>`, the push options in `GIT_PUSH_OPTION_*`,
    /// and the quarantine for `pre-receive`. With `skip_broken`, a refused
    /// command or a deletion of nothing is left out, and with none left
    /// the hook does not run. Whether it succeeded.
    fn runReceiveHook(s: *Server, event: []const u8, commands: []const Command, skip_broken: bool, push_options: []const []const u8, q: ?*const Quarantine) Self.Error!bool {
        const runner = if (s.runner) |*r| r else return true;
        if (!runner.exists(s.io, event)) return true;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var input: std.ArrayList(u8) = .empty;
        for (commands) |cmd| {
            if (skip_broken and (!cmd.standing() or cmd.did_not_exist)) continue;
            try input.print(arena, "{f} {f} {s}\n", .{ cmd.old, cmd.new, cmd.name });
        }
        if (input.items.len == 0) return true;
        var set: std.ArrayList(program.Var) = .empty;
        for (push_options, 0..) |option, i| try set.append(arena, .{ .name = try arena.print("GIT_PUSH_OPTION_{d}", .{i}), .value = option });
        try set.append(arena, .{ .name = "GIT_PUSH_OPTION_COUNT", .value = try arena.print("{d}", .{push_options.len}) });
        if (q) |held| {
            for (try held.environment(arena, s.options.inherited_alternates)) |v| try set.append(arena, .{ .name = v.name, .value = v.value });
        }
        const ran = try runner.run(s.io, event, .{ .input = input.items, .set = set.items });
        try s.sendHookOutput();
        return ran.succeeded();
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
        const out = s.out orelse return;
        if (s.asked.band != .none) {
            side_band.send(out, s.asked.band, 2, text) catch return error.WriteFailed;
            return;
        }
        if (builtin.is_test) return;
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
                } else pkt_line.print("ok {s}\n", .{cmd.name}, w) catch |e| break :write e;
            }
            pkt_line.flush(w) catch |e| break :write e;
        }) catch return error.OutOfMemory;
        const out = s.out.?;
        if (s.asked.band != .none) {
            side_band.send(out, s.asked.band, 1, buf.written()) catch return error.WriteFailed;
        } else out.writeAll(buf.written()) catch return error.WriteFailed;
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
