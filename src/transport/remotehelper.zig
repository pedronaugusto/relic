//! Remote helpers: `git-remote-<name>`, found on `PATH` and run as git runs
//! one, for a remote relic does not reach itself.
//!
//! A URL names a helper as git's `transport_get` decides it — a
//! `<helper>::<address>`, a `<scheme>://` URL whose scheme relic does not
//! speak, or `remote.<name>.vcs` — and `protocol.<name>.allow` says whether
//! it may run (`ext` never does by default). The helper is started with the
//! remote and the address, `GIT_DIR` set to the repository's, and asked its
//! capabilities; its options are set as git sets them. Then:
//!
//! - `connect` hands the helper's standard input and output to the git
//!   protocol, and from there it is a conversation like an ssh one;
//! - `list` (or `list for-push`) gives the refs, `@<target>` for a symbolic
//!   one, `?` for a value the helper cannot know, `:object-format`;
//! - `fetch` has the helper write the objects into the repository itself,
//!   and `import` has it write a fast-import stream, read here as git's
//!   `fast-import` reads it (`fastimport`), with `bidi-import` answered on
//!   its input; what the refs came to is read from the helper's private
//!   refs, by its `refspec` capability;
//! - `push` sends `push <src>:<dst>` lines, and `export` writes a
//!   fast-export stream (`fastexport`) with the helper's marks; the helper's
//!   `ok` and `error` lines are the report, and the private refs follow
//!   what was pushed unless `no-private-update` says not to.
//!
//! `stateless-connect` and `get` are not used: a helper offering nothing
//! else cannot fetch here, `error.HelperCannotFetch`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const repo_mod = @import("../repo.zig");
const program = @import("../repo/program.zig");
const config_mod = @import("../config.zig");
const cquote = @import("../cquote.zig");
const fastimport = @import("../fastimport.zig");
const fastexport = @import("../fastexport.zig");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const refspec_mod = @import("refspec.zig");
const sendpack = @import("sendpack.zig");
const fetchpack = @import("fetchpack.zig");
const url_mod = @import("url.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;
const Connection = connection.Connection;
const Refspec = refspec_mod.Refspec;

/// Errors from a conversation with a remote helper.
pub const Error = error{
    /// No `git-remote-<name>` on `PATH`: git's "unable to find remote
    /// helper".
    HelperNotFound,
    /// `protocol.<name>.allow` (or `protocol.allow`, or git's default for
    /// the name) does not let this helper run.
    TransportNotAllowed,
    /// The helper ended the conversation before its answer was over: git's
    /// "remote helper aborted session". `Connection.message` holds the last
    /// of what it wrote on its standard error.
    HelperAborted,
    /// A line the protocol does not allow where it came: a ref list line
    /// with no name, a push answer that is neither `ok` nor `error`, a
    /// `connect` answer that is neither empty nor `fallback`.
    HelperProtocolError,
    /// A capability marked `*`, mandatory, that this does not know.
    UnknownMandatoryCapability,
    /// The helper has no way to fetch: no `connect`, `fetch` or `import`.
    HelperCannotFetch,
    /// The helper has no way to push: no `connect`, `push` or `export`.
    HelperCannotPush,
    /// An `export` helper with no `refspec` capability: git's "remote-helper
    /// doesn't support push; refspec needed".
    RefspecNeeded,
    /// An option the operation cannot go without, refused by the helper:
    /// `atomic`, `push-option`, a depth or a filter.
    HelperOptionUnsupported,
    /// `:object-format` names a hash this does not have.
    UnsupportedObjectFormat,
    /// A ref an import should have written is not there: git's "could not
    /// read ref".
    ImportedRefMissing,
    /// The import left a ref as it was, as git's fast-import does when the
    /// new value would lose commits: git's "error while running
    /// fast-import".
    ImportRejected,
    /// `fetch`, `import`, `push` and `export` work on a repository, and
    /// none was given.
    RepositoryNeeded,
} || connection.Error || program.Error || fastimport.Error || fastexport.Error;

/// Which helper a remote is reached through, and what it is handed.
pub const Spec = struct {
    /// `git-remote-<name>` is the program.
    name: []const u8,
    /// The first argument: the configured remote's name, or the URL as
    /// given.
    remote: []const u8,
    /// The second argument: the address.
    address: ?[]const u8,

    /// The helper git runs for `url`: `remote.<name>.vcs` when `vcs` is
    /// given, else the one the URL names; `null` for a URL relic reaches
    /// itself.
    pub fn of(url: []const u8, remote_name: ?[]const u8, vcs: ?[]const u8) ?Spec {
        if (vcs) |name| return .{ .name = name, .remote = remote_name orelse url, .address = if (url.len == 0) null else url };
        const named = url_mod.helperOf(url) orelse return null;
        return .{ .name = named.name, .remote = remote_name orelse url, .address = named.address };
    }
};

/// Whether `name` may be run, as git's `is_transport_allowed` decides:
/// `protocol.<name>.allow`, then `protocol.allow`, then git's default —
/// `ext` never, any other helper only when the user asked for it, which
/// `GIT_PROTOCOL_FROM_USER=0` in the environment says they did not.
pub fn allowed(config: ?*const config_mod.Config, environ: *const Environ.Map, name: []const u8) bool {
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "protocol.{s}.allow", .{name}) catch return false;
    const policy = if (config) |c| c.get(key) orelse c.get("protocol.allow") else null;
    const text = policy orelse if (std.mem.eql(u8, name, "ext")) "never" else "user";
    if (std.ascii.eqlIgnoreCase(text, "always")) return true;
    if (std.ascii.eqlIgnoreCase(text, "never")) return false;
    if (!std.ascii.eqlIgnoreCase(text, "user")) return false;
    const from_user = environ.get("GIT_PROTOCOL_FROM_USER") orelse return true;
    return !(std.mem.eql(u8, from_user, "0") or std.ascii.eqlIgnoreCase(from_user, "false"));
}

/// What a helper said it can do.
pub const Capabilities = struct {
    fetch: bool = false,
    import: bool = false,
    bidi_import: bool = false,
    @"export": bool = false,
    option: bool = false,
    push: bool = false,
    connect: bool = false,
    stateless_connect: bool = false,
    signed_tags: bool = false,
    check_connectivity: bool = false,
    no_private_update: bool = false,
    object_format: bool = false,
};

/// How a helper is started.
pub const StartOptions = struct {
    programs: program.Programs,
    /// The repository's git directory, the helper's `GIT_DIR`.
    git_dir: ?[]const u8 = null,
    /// `option progress`.
    progress: bool = false,
    /// `option verbosity`: git's `-v` count and one.
    verbosity: u8 = 1,
};

/// One ref to fetch, by the name the helper listed it under.
pub const Want = struct {
    name: []const u8,
    oid: Oid,
};

/// How a fetch through a helper runs.
pub const FetchOptions = struct {
    repo: ?*Repository = null,
    /// Who the import's ref logs name.
    who: ?object.Signature = null,
    /// `option cloning`: the repository is new.
    cloning: bool = false,
    /// `option followtags`.
    follow_tags: bool = false,
    deepen: ?fetchpack.Deepen = null,
    /// `option filter`.
    filter: ?[]const u8 = null,
};

/// One ref to push.
pub const PushCommand = struct {
    /// The local ref pushed, or `null` for an object name or a deletion.
    src: ?[]const u8,
    /// The remote ref.
    dst: []const u8,
    /// Its value on the remote before, zero where it had none.
    old: Oid,
    /// The value pushed, zero to delete it.
    new: Oid,
    /// `+`: update it whether or not the new value descends from the old.
    force: bool = false,
};

/// How a push through a helper runs.
pub const PushOptions = struct {
    repo: ?*Repository = null,
    who: ?object.Signature = null,
    atomic: bool = false,
    push_options: []const []const u8 = &.{},
};

/// A helper, running.
pub const Helper = struct {
    gpa: Allocator,
    io: Io,
    arena_state: std.heap.ArenaAllocator,
    name: []const u8,
    /// The helper's standard input and output, and its process; `null`
    /// once a `connect` has handed them on.
    conn: ?*Connection,
    caps: Capabilities = .{},
    refspecs: std.ArrayList(Refspec) = .empty,
    import_marks: ?[]const u8 = null,
    export_marks: ?[]const u8 = null,
    /// The hash the helper's object names are written with.
    kind: hash.Kind = .sha1,
    /// The refs `list` gave last, the helper's own copy.
    listed: []const protocol.RemoteRef = &.{},
    /// Refs `list` marked `unchanged`, which are not fetched again.
    unchanged: std.StringHashMapUnmanaged(void) = .empty,
    /// What an import brought each ref to.
    fetched: std.StringHashMapUnmanaged(Oid) = .empty,
    /// The `.keep` files a `fetch` named, removed at the end.
    locks: std.ArrayList([]const u8) = .empty,
    line: Io.Writer.Allocating,

    /// Start the helper `spec` names and read its capabilities.
    pub fn start(gpa: Allocator, io: Io, spec: Spec, options: StartOptions) Error!*Helper {
        const h = try gpa.create(Helper);
        errdefer gpa.destroy(h);
        h.* = .{ .gpa = gpa, .io = io, .arena_state = .init(gpa), .name = "", .conn = null, .line = .init(gpa) };
        errdefer {
            h.line.deinit();
            h.arena_state.deinit();
        }
        const arena = h.arena_state.allocator();
        h.name = try arena.dupe(u8, spec.name);
        const program_name = try std.fmt.allocPrint(arena, "git-remote-{s}", .{spec.name});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ program_name, spec.remote });
        if (spec.address) |a| try argv.append(arena, a);
        var set: std.ArrayList(program.Var) = .empty;
        if (options.git_dir) |dir| try set.append(arena, .{ .name = "GIT_DIR", .value = dir });
        h.conn = connection.Process.start(gpa, io, options.programs, .{
            .argv = argv.items,
            .set = set.items,
            .stderr = .capture,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.HelperNotFound,
            else => |e| return e,
        };
        errdefer h.conn.?.close(io);
        try h.capabilities();
        if (h.caps.option) {
            _ = try h.option("progress", if (options.progress) "true" else "false", .raw);
            var buf: [4]u8 = undefined;
            // unreachable: a u8 is at most three digits
            _ = try h.option("verbosity", std.fmt.bufPrint(&buf, "{d}", .{options.verbosity}) catch unreachable, .raw);
        }
        return h;
    }

    fn sayGoodbye(conn: *connection.Connection) !void {
        const w = try conn.request();
        try w.writeByte('\n');
        try w.flush();
    }

    /// End the conversation: a blank line, as git's disconnect writes it,
    /// and the helper waited for.
    pub fn close(h: *Helper) void {
        const io = h.io;
        if (h.conn) |conn| {
            // ziglint-ignore: Z026 the blank line is a courtesy; the helper is waited for whether or not it heard it
            sayGoodbye(conn) catch {};
            conn.close(io);
        }
        // ziglint-ignore: Z026 a lock file that cannot be removed is stale, and the next run that needs it says so
        for (h.locks.items) |path| Io.Dir.cwd().deleteFile(io, path) catch {};
        h.locks.deinit(h.gpa);
        h.unchanged.deinit(h.gpa);
        h.fetched.deinit(h.gpa);
        h.refspecs.deinit(h.gpa);
        h.line.deinit();
        h.arena_state.deinit();
        h.gpa.destroy(h);
    }

    /// Give the conversation to whoever speaks the git protocol over it
    /// after a `connect`, and release the rest.
    pub fn takeOver(h: *Helper) *Connection {
        const conn = h.conn.?;
        h.conn = null;
        h.close();
        return conn;
    }

    //=================================================================
    // Lines
    //=================================================================

    fn send(h: *Helper, text: []const u8) Error!void {
        const conn = h.conn.?;
        const w = try conn.request();
        w.writeAll(text) catch return conn.failure();
        w.flush() catch return conn.failure();
    }

    /// The helper's next line, without its line ending. At the end of its
    /// output, `error.HelperAborted`, with what it said as the message.
    fn readLine(h: *Helper) Error![]const u8 {
        const conn = h.conn.?;
        const r = try conn.advertisement();
        h.line.clearRetainingCapacity();
        _ = r.streamDelimiterEnding(&h.line.writer, '\n') catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return conn.failure(),
        };
        if (r.bufferedLen() == 0) return h.aborted();
        r.toss(1);
        return std.mem.trimEnd(u8, h.line.written(), "\r");
    }

    fn aborted(h: *Helper) Error {
        const conn = h.conn.?;
        const ended = connection.Process.diagnose(conn, h.io) catch return error.Canceled;
        const said = std.mem.trim(u8, ended.stderr, " \t\r\n");
        if (said.len != 0) conn.setMessage(said[if (std.mem.findScalarLast(u8, said, '\n')) |nl| nl + 1 else 0..]);
        return error.HelperAborted;
    }

    fn capabilities(h: *Helper) Error!void {
        const arena = h.arena_state.allocator();
        try h.send("capabilities\n");
        while (true) {
            const line = try h.readLine();
            if (line.len == 0) break;
            const mandatory = line[0] == '*';
            const cap = if (mandatory) line[1..] else line;
            if (std.mem.eql(u8, cap, "fetch")) {
                h.caps.fetch = true;
            } else if (std.mem.eql(u8, cap, "option")) {
                h.caps.option = true;
            } else if (std.mem.eql(u8, cap, "push")) {
                h.caps.push = true;
            } else if (std.mem.eql(u8, cap, "import")) {
                h.caps.import = true;
            } else if (std.mem.eql(u8, cap, "bidi-import")) {
                h.caps.bidi_import = true;
            } else if (std.mem.eql(u8, cap, "export")) {
                h.caps.@"export" = true;
            } else if (std.mem.eql(u8, cap, "check-connectivity")) {
                h.caps.check_connectivity = true;
            } else if (std.mem.startsWith(u8, cap, "refspec ")) {
                const text = try arena.dupe(u8, cap["refspec ".len..]);
                try h.refspecs.append(h.gpa, Refspec.parse(text, .fetch) catch return error.HelperProtocolError);
            } else if (std.mem.eql(u8, cap, "connect")) {
                h.caps.connect = true;
            } else if (std.mem.eql(u8, cap, "stateless-connect")) {
                h.caps.stateless_connect = true;
            } else if (std.mem.eql(u8, cap, "signed-tags")) {
                h.caps.signed_tags = true;
            } else if (std.mem.startsWith(u8, cap, "export-marks ")) {
                h.export_marks = try arena.dupe(u8, cap["export-marks ".len..]);
            } else if (std.mem.startsWith(u8, cap, "import-marks ")) {
                h.import_marks = try arena.dupe(u8, cap["import-marks ".len..]);
            } else if (std.mem.startsWith(u8, cap, "no-private-update")) {
                h.caps.no_private_update = true;
            } else if (std.mem.startsWith(u8, cap, "object-format")) {
                h.caps.object_format = true;
            } else if (mandatory) return error.UnknownMandatoryCapability;
        }
    }

    /// How `option` writes its value: as given, or as a C-quoted string.
    pub const OptionValue = enum { raw, quoted };
    /// What the helper said to an `option`.
    pub const Answer = enum { ok, unsupported, refused };

    /// `option <name> <value>`, and the helper's answer. A helper without
    /// the `option` capability is not asked.
    pub fn option(h: *Helper, name: []const u8, value: []const u8, form: OptionValue) Error!Answer {
        if (!h.caps.option) return .unsupported;
        var buf: Io.Writer.Allocating = .init(h.gpa);
        defer buf.deinit();
        buf.writer.print("option {s} ", .{name}) catch return error.OutOfMemory;
        switch (form) {
            .raw => buf.writer.writeAll(value) catch return error.OutOfMemory,
            .quoted => cquote.write(&buf.writer, value, true) catch return error.OutOfMemory,
        }
        buf.writer.writeByte('\n') catch return error.OutOfMemory;
        try h.send(buf.written());
        const answer = try h.readLine();
        if (std.mem.eql(u8, answer, "ok")) return .ok;
        if (std.mem.startsWith(u8, answer, "error")) return .refused;
        return .unsupported;
    }

    fn requireOption(h: *Helper, name: []const u8, value: []const u8, form: OptionValue) Error!void {
        if (try h.option(name, value, form) != .ok) return error.HelperOptionUnsupported;
    }

    //=================================================================
    // The commands
    //=================================================================

    /// `connect git-upload-pack` or `git-receive-pack`, when the helper
    /// can: whether the conversation is now the service's. `servpath`
    /// carries a service program other than git's.
    pub fn connect(h: *Helper, service: connection.Service, service_program: ?[]const u8) Error!bool {
        if (!h.caps.connect) return false;
        if (service_program) |p| if (!std.mem.eql(u8, p, service.name())) {
            _ = try h.option("servpath", p, .quoted);
        };
        var buf: [64]u8 = undefined;
        // unreachable: the longer service name, git-receive-pack, makes 25 bytes
        try h.send(std.fmt.bufPrint(&buf, "connect {s}\n", .{service.name()}) catch unreachable);
        const answer = try h.readLine();
        if (answer.len == 0) return true;
        if (std.mem.eql(u8, answer, "fallback")) return false;
        return error.HelperProtocolError;
    }

    /// `list`, or `list for-push` for a push to a helper that pushes: the
    /// refs, a symbolic one given its target's value. `repo` is read for
    /// a ref the helper says is `unchanged`. The list is the caller's.
    pub fn list(h: *Helper, gpa: Allocator, repo: ?*Repository, for_push: bool) Error!protocol.RefList {
        if (h.caps.object_format) _ = try h.option("object-format", "true", .raw);
        try h.send(if (h.caps.push and for_push) "list for-push\n" else "list\n");
        var out: protocol.RefList = .{ .arena = .init(gpa), .refs = &.{} };
        errdefer out.arena.deinit();
        const a = out.arena.allocator();
        var refs: std.ArrayList(protocol.RemoteRef) = .empty;
        h.unchanged.clearRetainingCapacity();
        while (true) {
            const line = try h.readLine();
            if (line.len == 0) break;
            if (line[0] == ':') {
                if (std.mem.startsWith(u8, line, ":object-format ")) {
                    h.kind = hash.Kind.parse(line[":object-format ".len..]) catch return error.UnsupportedObjectFormat;
                }
                continue;
            }
            const eov = std.mem.findScalar(u8, line, ' ') orelse return error.HelperProtocolError;
            const rest = line[eov + 1 ..];
            const eon = std.mem.findScalar(u8, rest, ' ');
            const name = try a.dupe(u8, rest[0 .. eon orelse rest.len]);
            const value = line[0..eov];
            var ref: protocol.RemoteRef = .{ .name = name, .oid = Oid.zero(h.kind) };
            if (value.len > 0 and value[0] == '@') {
                ref.symref_target = try a.dupe(u8, value[1..]);
            } else if (!std.mem.eql(u8, value, "?")) {
                ref.oid = Oid.parse(h.kind, value) catch return error.HelperProtocolError;
            }
            if (eon) |e| if (hasAttribute(rest[e + 1 ..], "unchanged")) {
                try h.unchanged.put(h.gpa, try h.arena_state.allocator().dupe(u8, name), {});
                if (repo) |r| if (try r.refStore().resolve(gpa, h.io, name)) |resolved| {
                    gpa.free(resolved.name);
                    ref.oid = resolved.oid;
                };
            };
            try refs.append(a, ref);
        }
        // A symbolic ref has its target's value.
        for (refs.items) |*ref| {
            const target = ref.symref_target orelse continue;
            for (refs.items) |other| if (std.mem.eql(u8, other.name, target)) {
                ref.oid = other.oid;
                break;
            };
        }
        out.refs = refs.items;
        const kept = try h.arena_state.allocator().alloc(protocol.RemoteRef, refs.items.len);
        for (refs.items, kept) |ref, *k| {
            k.* = ref;
            k.name = try h.arena_state.allocator().dupe(u8, ref.name);
            if (ref.symref_target) |t| k.symref_target = try h.arena_state.allocator().dupe(u8, t);
        }
        h.listed = kept;
        return out;
    }

    /// Bring `wants` into the repository, through the helper's `fetch` or,
    /// failing that, its `import`.
    pub fn fetch(h: *Helper, wants_in: []const Want, options: FetchOptions) Error!void {
        // A symbolic ref is asked for as its target, once, as git asks.
        var wants: std.ArrayList(Want) = .empty;
        defer wants.deinit(h.gpa);
        var aliases: std.ArrayList([2][]const u8) = .empty;
        defer aliases.deinit(h.gpa);
        for (wants_in) |w| {
            if (h.unchanged.contains(w.name)) continue;
            var name = w.name;
            for (h.listed) |ref| if (std.mem.eql(u8, ref.name, w.name)) {
                if (ref.symref_target) |target| name = target;
                break;
            };
            if (name.ptr != w.name.ptr) try aliases.append(h.gpa, .{ w.name, name });
            const seen = for (wants.items) |o| {
                if (std.mem.eql(u8, o.name, name)) break true;
            } else false;
            if (!seen) try wants.append(h.gpa, .{ .name = name, .oid = w.oid });
        }
        defer for (aliases.items) |pair| if (h.fetched.get(pair[1])) |oid| {
            const key = h.arena_state.allocator().dupe(u8, pair[0]) catch continue;
            h.fetched.put(h.gpa, key, oid) catch {};
        };
        if (wants.items.len == 0) return;
        if (!h.caps.fetch and !h.caps.import) return error.HelperCannotFetch;
        if (options.cloning) _ = try h.option("cloning", "true", .raw);
        if (options.follow_tags) _ = try h.option("followtags", "true", .raw);
        if (options.filter) |spec| try h.requireOption("filter", spec, .quoted);
        if (options.deepen) |d| {
            var buf: [24]u8 = undefined;
            // unreachable: a u32 depth is at most ten digits and an i64 time at most 20 with its sign
            if (d.depth) |depth| try h.requireOption("depth", std.fmt.bufPrint(&buf, "{d}", .{depth}) catch unreachable, .quoted);
            if (d.since) |since| try h.requireOption("deepen-since", std.fmt.bufPrint(&buf, "{d}", .{since}) catch unreachable, .quoted); // unreachable: as above
            for (d.not) |n| try h.requireOption("deepen-not", n, .quoted);
            if (d.relative) try h.requireOption("deepen-relative", "true", .raw);
        }
        const repo = options.repo orelse return error.RepositoryNeeded;
        if (h.caps.fetch) return h.fetchWithFetch(repo, wants.items);
        return h.fetchWithImport(repo, wants.items, options.who orelse return error.RepositoryNeeded);
    }

    fn fetchWithFetch(h: *Helper, repo: *Repository, wants: []const Want) Error!void {
        var buf: Io.Writer.Allocating = .init(h.gpa);
        defer buf.deinit();
        for (wants) |w| buf.writer.print("fetch {f} {s}\n", .{ w.oid, w.name }) catch return error.OutOfMemory;
        buf.writer.writeByte('\n') catch return error.OutOfMemory;
        try h.send(buf.written());
        while (true) {
            const line = try h.readLine();
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "lock ")) {
                try h.locks.append(h.gpa, try h.arena_state.allocator().dupe(u8, line["lock ".len..]));
            }
            // `connectivity-ok`, and anything else, is a word for git's
            // own checks; this repository's are its own.
        }
        try repo.odb.refresh(h.io);
    }

    fn fetchWithImport(h: *Helper, repo: *Repository, wants: []const Want, who: object.Signature) Error!void {
        const conn = h.conn.?;
        var buf: Io.Writer.Allocating = .init(h.gpa);
        defer buf.deinit();
        for (wants) |w| buf.writer.print("import {s}\n", .{w.name}) catch return error.OutOfMemory;
        buf.writer.writeByte('\n') catch return error.OutOfMemory;
        try h.send(buf.written());
        var report = fastimport.import(h.gpa, h.io, repo, try conn.advertisement(), .{
            .who = who,
            .allow_unsafe_features = true,
            .responses = if (h.caps.bidi_import) try conn.request() else null,
        }) catch |err| switch (err) {
            error.ReadFailed => return conn.failure(),
            else => |e| return e,
        };
        defer report.deinit();
        if (report.rejected.len != 0) return error.ImportRejected;
        // What each ref came to is in the helper's private namespace.
        for (wants) |w| {
            const private = try h.privateName(w.name) orelse continue;
            defer h.gpa.free(private);
            const resolved = try repo.refStore().resolve(h.gpa, h.io, private) orelse return error.ImportedRefMissing;
            h.gpa.free(resolved.name);
            try h.fetched.put(h.gpa, try h.arena_state.allocator().dupe(u8, w.name), resolved.oid);
        }
    }

    /// The private ref the helper's refspecs keep `name` in; with none,
    /// `name` itself, as git's implied `*:*`. The name is the caller's.
    fn privateName(h: *Helper, name: []const u8) Allocator.Error!?[]u8 {
        if (h.refspecs.items.len == 0) {
            const copy = try h.gpa.dupe(u8, name);
            return copy;
        }
        for (h.refspecs.items) |spec| {
            if (try spec.mapSource(h.gpa, name)) |mapped| return mapped;
        }
        return null;
    }

    /// Push `commands` through the helper's `push` or, failing that, its
    /// `export`, and its report.
    pub fn push(h: *Helper, gpa: Allocator, commands: []const PushCommand, options: PushOptions) Error!sendpack.Report {
        if (!h.caps.push and !h.caps.@"export") return error.HelperCannotPush;
        const repo = options.repo orelse return error.RepositoryNeeded;
        var report = if (h.caps.push)
            try h.pushWithPush(gpa, commands, options)
        else
            try h.pushWithExport(gpa, repo, commands, options);
        errdefer report.deinit();
        try h.updatePrivate(repo, commands, &report, options.who);
        return report;
    }

    fn commonPushOptions(h: *Helper, options: PushOptions) Error!void {
        if (options.atomic) try h.requireOption("atomic", "true", .raw);
        for (options.push_options) |o| try h.requireOption("push-option", o, .quoted);
    }

    fn pushWithPush(h: *Helper, gpa: Allocator, commands: []const PushCommand, options: PushOptions) Error!sendpack.Report {
        var buf: Io.Writer.Allocating = .init(h.gpa);
        defer buf.deinit();
        const w = &buf.writer;
        for (commands) |c| {
            w.writeAll("push ") catch return error.OutOfMemory;
            if (!c.new.isZero()) {
                if (c.force) w.writeByte('+') catch return error.OutOfMemory;
                if (c.src) |src| w.writeAll(src) catch return error.OutOfMemory else w.print("{f}", .{c.new}) catch return error.OutOfMemory;
            }
            w.print(":{s}\n", .{c.dst}) catch return error.OutOfMemory;
        }
        if (buf.written().len == 0) return .{ .arena = .init(gpa), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
        try h.commonPushOptions(options);
        w.writeByte('\n') catch return error.OutOfMemory;
        try h.send(buf.written());
        return h.readStatus(gpa);
    }

    fn pushWithExport(h: *Helper, gpa: Allocator, repo: *Repository, commands: []const PushCommand, options: PushOptions) Error!sendpack.Report {
        if (h.refspecs.items.len == 0) return error.RefspecNeeded;
        try h.commonPushOptions(options);
        for (commands) |c| if (c.force) {
            _ = try h.option("force", "true", .raw);
            break;
        };
        try h.send("export\n");

        const arena = h.arena_state.allocator();
        // What the helper has is what its private refs hold: those, for
        // every ref it listed and every ref pushed, are left out.
        var exclude: std.ArrayList(Oid) = .empty;
        defer exclude.deinit(h.gpa);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(h.gpa);
        for (h.listed) |r| try names.append(h.gpa, r.name);
        for (commands) |c| try names.append(h.gpa, c.dst);
        for (names.items) |name| {
            const private = try h.privateName(name) orelse continue;
            defer h.gpa.free(private);
            const resolved = try repo.refStore().resolve(h.gpa, h.io, private) orelse continue;
            h.gpa.free(resolved.name);
            try exclude.append(h.gpa, resolved.oid);
        }
        var tips: std.ArrayList(fastexport.Tip) = .empty;
        defer tips.deinit(h.gpa);
        var deletions: std.ArrayList([]const u8) = .empty;
        defer deletions.deinit(h.gpa);
        for (commands) |c| {
            if (c.new.isZero()) {
                try deletions.append(h.gpa, try std.fmt.allocPrint(arena, ":{s}", .{c.dst}));
            } else try tips.append(h.gpa, .{ .name = c.dst, .oid = c.new });
        }
        const conn = h.conn.?;
        const w = try conn.request();
        const export_tmp = if (h.export_marks) |m| try std.fmt.allocPrint(arena, "{s}.tmp", .{m}) else null;
        fastexport.write(h.gpa, h.io, repo, w, .{
            .tips = tips.items,
            .exclude = exclude.items,
            .use_done_feature = true,
            .signed_tags = if (h.caps.signed_tags) .verbatim else .strip,
            .refspecs = deletions.items,
            .import_marks = h.import_marks,
            .export_marks = export_tmp,
        }) catch |err| switch (err) {
            error.WriteFailed => return conn.failure(),
            else => |e| return e,
        };
        w.flush() catch return conn.failure();
        var report = try h.readStatus(gpa);
        errdefer report.deinit();
        // ziglint-ignore: Z026 the marks are an optimisation for the next push, as git's are: kept when they can be, and the push stands either way
        if (export_tmp) |tmp| Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), h.export_marks.?, h.io) catch {};
        return report;
    }

    /// The `ok <ref>` and `error <ref> <why>` lines up to a blank one:
    /// git's `push_update_refs_status`.
    fn readStatus(h: *Helper, gpa: Allocator) Error!sendpack.Report {
        var report: sendpack.Report = .{ .arena = .init(gpa), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
        errdefer report.arena.deinit();
        const a = report.arena.allocator();
        var refs: std.ArrayList(sendpack.RefReport) = .empty;
        while (true) {
            const line = try h.readLine();
            if (line.len == 0) break;
            // `option` lines say more of the ref before them; the report
            // has no place for it.
            if (std.mem.startsWith(u8, line, "option ")) continue;
            var ok: bool = undefined;
            var rest: []const u8 = undefined;
            if (std.mem.startsWith(u8, line, "ok ")) {
                ok = true;
                rest = line["ok ".len..];
            } else if (std.mem.startsWith(u8, line, "error ")) {
                ok = false;
                rest = line["error ".len..];
            } else return error.HelperProtocolError;
            const space = std.mem.findScalar(u8, rest, ' ');
            const name = try a.dupe(u8, rest[0 .. space orelse rest.len]);
            var message: ?[]const u8 = null;
            if (space) |s| {
                const why = rest[s + 1 ..];
                message = if (try cquote.unquote(a, why)) |u| u.name else try a.dupe(u8, why);
            }
            // The words git takes as a state rather than a reason.
            if (message) |m| {
                if (std.mem.eql(u8, m, "up to date") or std.mem.eql(u8, m, "forced update")) {
                    ok = true;
                    message = null;
                }
            }
            try refs.append(a, .{ .name = name, .ok = ok, .message = message });
        }
        report.refs = refs.items;
        return report;
    }

    /// What the helper took moves its private ref, as git moves it.
    fn updatePrivate(h: *Helper, repo: *Repository, commands: []const PushCommand, report: *const sendpack.Report, who: ?object.Signature) Error!void {
        if (h.refspecs.items.len == 0 or h.caps.no_private_update) return;
        for (commands) |c| {
            const said = report.find(c.dst) orelse continue;
            if (!said.ok) continue;
            const private = try h.privateName(c.dst) orelse continue;
            defer h.gpa.free(private);
            var tx = repo.beginRefs();
            defer tx.deinit(h.io);
            if (c.new.isZero()) {
                const there = try repo.refStore().resolve(h.gpa, h.io, private) orelse continue;
                h.gpa.free(there.name);
                try tx.delete(private, .any);
            } else try tx.update(private, .{ .direct = c.new }, .any);
            try tx.commit(h.io, if (who) |sig| .{ .who = sig, .message = "update by helper", .policy = repo.reflogPolicy() } else null);
        }
    }
};

/// Whether the space-separated `attrs` hold `attr`.
fn hasAttribute(attrs: []const u8, attr: []const u8) bool {
    var it = std.mem.splitScalar(u8, attrs, ' ');
    while (it.next()) |a| if (std.mem.eql(u8, a, attr)) return true;
    return false;
}

test "a helper may run as protocol.allow says, ext never by default" {
    var env: Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(allowed(null, &env, "testgit"));
    try std.testing.expect(!allowed(null, &env, "ext"));
    try env.put("GIT_PROTOCOL_FROM_USER", "0");
    try std.testing.expect(!allowed(null, &env, "testgit"));
    var config = try config_mod.Config.parseText(std.testing.allocator, "[protocol \"ext\"]\nallow = always\n[protocol]\nallow = never\n", .local);
    defer config.deinit();
    try std.testing.expect(allowed(&config, &env, "ext"));
    try std.testing.expect(!allowed(&config, &env, "testgit"));
}

test "a helper is named by remote.<name>.vcs, by <helper>::, or by a scheme" {
    const vcs = Spec.of("https://example.com/r", "origin", "hg").?;
    try std.testing.expectEqualStrings("hg", vcs.name);
    try std.testing.expectEqualStrings("origin", vcs.remote);
    const ext = Spec.of("ext::git %s /srv/r", null, null).?;
    try std.testing.expectEqualStrings("ext", ext.name);
    try std.testing.expectEqualStrings("ext::git %s /srv/r", ext.remote);
    try std.testing.expectEqualStrings("git %s /srv/r", ext.address.?);
    try std.testing.expect(Spec.of("/srv/r", null, null) == null);
}
