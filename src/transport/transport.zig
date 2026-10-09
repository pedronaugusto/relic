//! A remote, open: the one thing a fetch, a clone or a push talks to.
//!
//! A URL decides the transport. A path or a `file://` URL is another
//! repository on this machine, opened in process by `local.zig`; `ssh://`
//! and the scp-like form start the person's `ssh` through `ssh.zig`; and
//! `http://` and `https://` are git's smart HTTP protocol through
//! `smarthttp.zig`. The last two are conversations with the remote's own
//! `git-upload-pack` or `git-receive-pack`, and the protocol above them —
//! the refs, the negotiation, the pack — is the same for both. A path to a
//! bundle file is fetched from as git's bundle transport fetches: its refs
//! listed, its pack indexed whole. A URL that names a remote helper —
//! `<helper>::<address>`, a scheme relic does not speak, `remote.<name>.vcs`
//! — runs `git-remote-<helper>` (`remotehelper.zig`): one that can
//! `connect` becomes a conversation like the others, and one that fetches,
//! imports, pushes or exports is spoken to in its own commands. A `Session`
//! hides which it is from the operations above.

const ErrorNamespace = @This();
const Self = @This();

const httpsettings = @import("../wire/httpsettings.zig");
const promisors = @import("../wire/promisors.zig");
/// Which proxy an HTTP remote is reached through.
const Proxy = httpsettings.Proxy;
// The modules relic's API puts under this one, as `relic.transport.<name>`.

const url = @import("../wire/url.zig");

const fetchpack = @import("../wire/fetchpack.zig");

const sendpack = @import("../wire/sendpack.zig");
const local = @import("local.zig");
const ssh = @import("../wire/ssh.zig");
const smarthttp = @import("../wire/smarthttp.zig");

const credential = @import("../wire/credential.zig");
const auth = @import("../wire/auth.zig");
const protocol = @import("../wire/protocol.zig");
const connection = @import("../wire/connection.zig");
const pktline = @import("../codec/pktline.zig");

const uploadpack = @import("uploadpack.zig");
const bundle = @import("bundle.zig");

const progress = @import("../report/progress.zig");
const remotehelper = @import("remotehelper.zig");
const policy = @import("../wire/policy.zig");

const std = @import("std");
const keep_mod = @import("../odb/keep.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const program = @import("../process/program.zig");
const config_mod = @import("../config/config.zig");
const warning = @import("../report/warning.zig");
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;

/// Which service a session talks to.
const Service = connection.Service;

/// Errors from opening and using a remote.
pub const Error = error{
    /// A transport relic does not have: `git://`, `rsync://`, a remote
    /// helper's `<helper>::<address>`.
    UnsupportedTransport,
    /// A URL that does not parse.
    MalformedUrl,
    /// `GIT_ALLOW_PROTOCOL`, `protocol.<name>.allow`, `protocol.allow` or
    /// git's default for the transport does not let it be used: see
    /// `policy`.
    TransportNotAllowed,
    /// The transport needs to run a program — `ssh`, a credential helper —
    /// and the caller handed in no `program.Programs`.
    ProgramsNotGranted,
    /// The URL carries a password and `transfer.credentialsInUrl` is `die`.
    CredentialsInUrl,
} || local.Error || fetchpack.Error || protocol.Error || program.Error || ssh.Error || smarthttp.Error || sendpack.Error || bundle.Error ||
    remotehelper.Error;

/// How a remote is reached.
pub const Options = struct {
    /// The permission to run programs: `ssh` for an ssh URL. Without it an
    /// ssh URL is `error.ProgramsNotGranted`.
    programs: ?program.Programs = null,
    /// The repository's configuration, for `core.sshCommand`, `ssh.variant`
    /// and the `http.*` settings.
    config: ?*const config_mod.Config = null,
    /// The configured remote, for `remote.<name>.proxy`.
    remote_name: ?[]const u8 = null,
    /// The proxy for an HTTP remote, over the one the configuration and
    /// the environment choose.
    proxy: Proxy = .auto,
    /// The program to ask the other side to run in place of
    /// `git-upload-pack` or `git-receive-pack`: `remote.<name>.uploadpack`.
    service_program: ?[]const u8 = null,
    /// Ask an upload-pack for protocol v2. A server that does not speak it
    /// answers in v0, which is read the same. `null` takes
    /// `protocol.version` from `config`, as git does: 2 unless it says 0
    /// or 1.
    protocol_v2: ?bool = null,
    progress: ?progress.Progress = null,
    /// What stands in for a terminal when an HTTP server asks for a
    /// credential no helper has. Without one nothing is asked, and
    /// askpass runs only when it says so.
    prompt: ?credential.Prompt = null,
    /// Filled in, when the operation fails for want of a credential, with
    /// what a person needs to put it right: see `auth.Failure`.
    auth_failure: ?*auth.Failure = null,
    /// The caller's time, for a credential's expiry: `credential.Options.now`.
    now: ?i64 = null,
    /// Read a repository on this machine directly, as git's local clone
    /// copies one, rather than through upload-pack. Only a fetch reads it.
    local_copy: bool = false,
    /// Where what git would print as a warning goes, as values: see
    /// `warning.Warnings`.
    warnings: ?*warning.Warnings = null,
    /// The local repository: a remote helper's `GIT_DIR`, and where its
    /// `fetch`, `import`, `push` and `export` read and write.
    repository: ?*repo_mod.Repository = null,
    /// Who the refs a remote helper's import writes are logged as.
    who: ?object.Signature = null,
    /// The repository is a clone's, new: a remote helper is told so.
    cloning: bool = false,
    /// Whether the person named this remote themselves, which a transport
    /// git allows only for the person — `file`, a remote helper — needs.
    /// A submodule's URL was not named by the person: false. `null` takes
    /// `GIT_PROTOCOL_FROM_USER` from `programs`' environment, as git does.
    from_user: ?bool = null,
};

/// git's `transfer.credentialsInUrl`: a URL that carries a password,
/// which ends up in configuration files and process listings, is let
/// through (`allow`, the default), warned of (`warn`) or refused (`die`,
/// and any value git would die on).
fn checkCredentialsInUrl(gpa: Allocator, text: []const u8, parsed: url.Url, options: Options) Error!void {
    const password = parsed.password orelse return;
    const config = options.config orelse return;
    const value = config.get("transfer.credentialsinurl") orelse return;
    if (std.mem.eql(u8, value, "allow")) return;
    if (!std.mem.eql(u8, value, "warn")) return error.CredentialsInUrl;
    const at = @intFromPtr(password.ptr) - @intFromPtr(text.ptr); // safe: `Url.parse` sliced `password` out of `text`
    const redacted = try gpa.print("{s}<redacted>{s}", .{ text[0..at], text[at + password.len ..] });
    defer gpa.free(redacted);
    try warning.note(options.warnings, .{ .credentials_in_url = redacted });
}

/// Whether `config` leaves protocol v2 on: `protocol.version` unset or 2.
pub fn wantsV2(config: ?*const config_mod.Config) bool {
    const c = config orelse return true;
    const text = c.get("protocol.version") orelse return true;
    return !(std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "1"));
}

/// An open remote.
pub const Session = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    service: Service,
    impl: union(enum) {
        local: *local.Remote,
        /// A bundle file named by a path, as git's bundle transport reads
        /// one.
        bundle: *bundle.File,
        smart: struct {
            conn: *Connection,
            advertisement: protocol.Advertisement,
            /// Whether the server has finished with the conversation — a
            /// v0 upload-pack after its pack — rather than waiting for a
            /// command.
            done: bool = false,
            /// The promisor remotes taken from the server's
            /// `promisor-remote`, and what is to be stored from it; the
            /// advertisement's.
            taken: []const promisors.Info = &.{},
            stores: []const promisors.Store = &.{},
        },
        /// A remote helper spoken to in its own commands.
        helper: struct {
            h: *remotehelper.Helper,
            repository: ?*repo_mod.Repository,
            who: ?object.Signature,
            cloning: bool,
        },
    },

    pub const OpenInputs = struct { service: Service, kind: ?hash.Kind = null };

    /// Open the remote at `remote_url` for `inputs.service`. `kind` is the local
    /// repository's hash, or `null` when there is no local repository yet.
    /// A v2 server's `promisor-remote` is answered as `options.config`
    /// says (`promisorsTaken`, `promisorStores`).
    pub fn open(
        gpa: Allocator,
        io: Io,
        remote_url: []const u8,
        inputs: OpenInputs,
        options: Options,
    ) Self.Error!Session {
        const service = inputs.service;
        const kind = inputs.kind;
        var session = try openUnanswered(gpa, io, remote_url, service, kind, options);
        errdefer session.deinit(io);
        try session.answerPromisors(options);
        return session;
    }

    /// Answer a v2 server's `promisor-remote` with the remotes
    /// `promisor.acceptFromServer` takes: sent with every command after.
    fn answerPromisors(s: *Session, options: Options) Allocator.Error!void {
        const smart = switch (s.impl) {
            .smart => |*smart| smart,
            else => return,
        };
        if (smart.advertisement.version != .v2) return;
        const advertised = smart.advertisement.value("promisor-remote") orelse return;
        const config = options.config orelse return;
        const answer = try promisors.reply(smart.advertisement.arena.allocator(), config, advertised, options.warnings);
        smart.advertisement.promisor_reply = answer.text;
        smart.taken = answer.accepted;
        smart.stores = answer.stores;
    }

    /// The promisor remotes this side took from the server's
    /// `promisor-remote`, as advertised.
    pub fn promisorsTaken(s: *const Session) []const promisors.Info {
        return switch (s.impl) {
            .smart => |smart| smart.taken,
            else => &.{},
        };
    }

    /// What `promisor.storeFields` asks to be written from the server's
    /// `promisor-remote`: `partial.storeAdvertised` writes it.
    pub fn promisorStores(s: *const Session) []const promisors.Store {
        return switch (s.impl) {
            .smart => |smart| smart.stores,
            else => &.{},
        };
    }

    fn openUnanswered(
        gpa: Allocator,
        io: Io,
        remote_url: []const u8,
        service: Service,
        kind: ?hash.Kind,
        options: Options,
    ) ErrorNamespace.Error!Session {
        if (try openHelper(gpa, io, remote_url, service, kind, options)) |session| return session;
        const parsed = try url.Url.parse(remote_url);
        // Every transport is checked, as git's `transport_get` checks it,
        // a bundle on this machine as `file`.
        try checkAllowed(options, policy.nameOf(parsed.scheme));
        try checkCredentialsInUrl(gpa, remote_url, parsed, options);
        if (parsed.scheme == .local and service == .upload_pack) bundled: {
            // `url_is_local_not_ssh && is_file && is_bundle`: a path to a
            // bundle is fetched from as one; a `file://` URL never is.
            var identity = url.Identity.parse(gpa, remote_url) catch break :bundled;
            defer identity.deinit();
            const f = bundle.File.open(gpa, io, Io.Dir.cwd(), identity.url.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :bundled,
            };
            if (kind) |k| if (k != f.header.object_format) {
                f.deinit(io);
                return error.ObjectFormatMismatch;
            };
            return .{ .gpa = gpa, .service = service, .impl = .{ .bundle = f } };
        }
        switch (parsed.scheme) {
            .local, .file => if (service == .upload_pack and !options.local_copy) {
                // A fetch from this machine goes through upload-pack, as
                // git's does — relic's own, in this process.
                const here = try gpa.create(local.Remote);
                // The connection owns the repository once it is made.
                var owned = true;
                errdefer if (owned) gpa.destroy(here);
                here.* = try local.Remote.open(gpa, io, remote_url, .{});
                errdefer if (owned) here.deinit(io);
                if (kind) |k| if (k != here.repo.objectFormat()) return error.ObjectFormatMismatch;
                const v2 = options.protocol_v2 orelse wantsV2(options.config);
                const conn = try uploadpack.connect(gpa, io, here, if (v2) .v2 else .v0, .{});
                owned = false;
                errdefer conn.deinit(io);
                return fromConnection(gpa, conn, service, kind);
            } else {
                const here = try gpa.create(local.Remote);
                errdefer gpa.destroy(here);
                here.* = try local.Remote.open(gpa, io, remote_url, .{});
                errdefer here.deinit(io);
                if (kind) |k| if (k != here.repo.objectFormat()) return error.ObjectFormatMismatch;
                if (service == .receive_pack) try here.serve(.receive_pack);
                return .{ .gpa = gpa, .service = service, .impl = .{ .local = here } };
            },
            .ssh => {
                var identity = try url.Identity.parse(gpa, remote_url);
                defer identity.deinit();
                const conn = try ssh.connect(gpa, io, identity.url, service, .{
                    .programs = options.programs,
                    .config = options.config,
                    .service_program = options.service_program,
                    .protocol_v2 = options.protocol_v2 orelse wantsV2(options.config),
                    .warnings = options.warnings,
                });
                errdefer conn.deinit(io);
                return fromConnection(gpa, conn, service, kind) catch |err| switch (err) {
                    error.RemoteHungUp, error.ConnectionFailed, error.ProtocolError => return ssh.explain(gpa, io, conn, err, .{ .url = identity.url, .failure = options.auth_failure }),
                    else => |e| return e,
                };
            },
            .http, .https => {
                const conn = try smarthttp.connect(gpa, io, parsed, service, .{
                    .config = options.config,
                    .remote_name = options.remote_name,
                    .proxy = options.proxy,
                    .programs = options.programs,
                    .protocol_v2 = options.protocol_v2 orelse wantsV2(options.config),
                    .prompt = options.prompt,
                    .auth_failure = options.auth_failure,
                    .warnings = options.warnings,
                    .now = options.now,
                    .from_user = options.from_user,
                });
                errdefer conn.deinit(io);
                return fromConnection(gpa, conn, service, kind);
            },
            .git => return error.UnsupportedTransport,
        }
    }

    fn checkAllowed(options: Options, name: []const u8) ErrorNamespace.Error!void {
        const environ = if (options.programs) |p| p.environ else null;
        if (!policy.allowed(name, .{ .config = options.config, .environ = environ, .from_user = options.from_user })) return error.TransportNotAllowed;
    }

    /// A session through the remote helper `remote_url` names, or `null`
    /// when it names none.
    fn openHelper(
        gpa: Allocator,
        io: Io,
        remote_url: []const u8,
        service: Service,
        kind: ?hash.Kind,
        options: Options,
    ) ErrorNamespace.Error!?Session {
        const vcs: ?[]const u8 = if (options.remote_name) |name| if (options.config) |c| blk: {
            var key_buf: [256]u8 = undefined;
            const key = std.mem.print(&key_buf, "remote.{s}.vcs", .{name}) catch break :blk null;
            break :blk c.get(key);
        } else null else null;
        const spec = remotehelper.Spec.of(remote_url, options.remote_name, vcs) orelse return null;
        try checkAllowed(options, spec.name);
        const programs = options.programs orelse return error.ProgramsNotGranted;
        const git_dir: ?[:0]u8 = if (options.repository) |r| try r.gitDirectory().realPathFileAlloc(io, ".", gpa) else null;
        defer if (git_dir) |d| gpa.free(d);
        const h = try remotehelper.Helper.open(gpa, io, spec, .{
            .programs = programs,
            .git_dir = git_dir,
            .progress = options.progress != null,
        });
        errdefer h.deinit(io);
        if (try h.connect(service, options.service_program)) {
            const conn = h.takeOver(io);
            errdefer conn.deinit(io);
            const session = try fromConnection(gpa, conn, service, kind);
            return session;
        }
        switch (service) {
            .upload_pack => if (!h.caps.fetch and !h.caps.import) return error.HelperCannotFetch,
            .receive_pack => if (!h.caps.push and !h.caps.@"export") return error.HelperCannotPush,
        }
        return .{ .gpa = gpa, .service = service, .impl = .{ .helper = .{
            .h = h,
            .repository = options.repository,
            .who = options.who,
            .cloning = options.cloning,
        } } };
    }

    /// A session over a connection already made, which it takes. The
    /// server's advertisement is read here.
    pub fn fromConnection(gpa: Allocator, conn: *Connection, service: Service, kind: ?hash.Kind) protocol.Error!Session {
        const adv = protocol.readAdvertisement(gpa, conn, kind) catch |err| {
            return err;
        };
        return .{ .gpa = gpa, .service = service, .impl = .{ .smart = .{ .conn = conn, .advertisement = adv } } };
    }

    /// End the session and release everything.
    pub fn deinit(s: *Session, io: Io) void {
        switch (s.impl) {
            .local => |here| {
                here.deinit(io);
                s.gpa.destroy(here);
            },
            .bundle => |f| f.deinit(io),
            .helper => |helper| helper.h.deinit(io),
            .smart => |*smart| {
                // A conversation over a pipe that the server still waits on
                // ends with a flush, which it reads as nothing more wanted,
                // as git's disconnect writes it.
                if (!smart.conn.stateless and !smart.done) {
                    // ziglint-ignore: Z026 the farewell is a courtesy; the session closes either way, and a server that has gone cannot read it
                    sayGoodbye(smart.conn) catch {};
                }
                smart.advertisement.deinit();
                smart.conn.deinit(io);
            },
        }
        s.* = undefined;
    }

    fn sayGoodbye(conn: *Connection) !void {
        const w = try conn.request();
        try pktline.flush(w);
        try w.flush();
    }

    /// The hash the remote's object names are written with.
    pub fn objectFormat(s: *const Session) hash.Kind {
        return switch (s.impl) {
            .local => |here| here.repo.objectFormat(),
            .bundle => |f| f.header.object_format,
            .smart => |smart| smart.advertisement.kind,
            .helper => |helper| helper.h.kind,
        };
    }

    /// A shallow v0 server's boundary, as its advertisement gave it: what a
    /// fetch that asks for no depth takes the server's shallow lines to be.
    pub fn advertisedShallow(s: *const Session) []const Oid {
        return switch (s.impl) {
            .local, .bundle, .helper => &.{},
            .smart => |smart| smart.advertisement.shallow,
        };
    }

    /// Whether git's fetch-pack names the refs in a promisor pack's
    /// `.promisor` over this conversation. Over HTTP in protocol v0 it does
    /// not: there its index-pack writes the file, empty.
    pub fn promisorNamesRefs(s: *const Session) bool {
        return switch (s.impl) {
            .local, .bundle, .helper => true,
            .smart => |smart| !(smart.conn.stateless and smart.advertisement.version != .v2),
        };
    }

    /// The protocol the remote spoke, or `null` for a repository on this
    /// machine, which speaks none.
    pub fn protocolVersion(s: *const Session) ?protocol.Version {
        return switch (s.impl) {
            .local, .bundle, .helper => null,
            .smart => |smart| smart.advertisement.version,
        };
    }

    /// The remote's refs, only those beginning with one of `prefixes` when
    /// any are given. The result is the caller's.
    pub fn listRefs(s: *Session, gpa: Allocator, io: Io, prefixes: []const []const u8) Self.Error!protocol.RefList {
        return switch (s.impl) {
            .local => |here| here.listRefs(gpa, io, prefixes),
            .bundle => |f| bundleRefs(gpa, f),
            .smart => |*smart| protocol.listRefs(gpa, smart.conn, &smart.advertisement, .{ .prefixes = prefixes }),
            .helper => |helper| helper.h.list(gpa, helper.repository, .{ .for_push = s.service == .receive_pack }),
        };
    }

    /// What a remote helper's import brought the ref `name` to, which its
    /// `list` could not say; `null` for every other transport and ref.
    pub fn fetchedValue(s: *const Session, name: []const u8) ?Oid {
        return switch (s.impl) {
            .helper => |helper| helper.h.fetched.get(name),
            else => null,
        };
    }

    /// What a push sends.
    pub const PushRequest = struct {
        commands: []const sendpack.Command,
        /// Everything the new values reach that the remote lacks.
        objects: []const odb_mod.PackEntry,
        atomic: bool = false,
        push_options: []const []const u8 = &.{},
        /// Who a repository on this machine logs the update as.
        who: object.Signature,
        progress: ?progress.Progress = null,
        /// For a remote helper's `push` and `export`: the local ref each
        /// command pushes, by position, `null` where it is an object name.
        sources: []const ?[]const u8 = &.{},
        /// For a remote helper: each command's `+`, by position.
        force: []const bool = &.{},
    };

    /// Send a push, reading the objects from `db`, and return the remote's
    /// report of each command.
    pub fn push(s: *Session, gpa: Allocator, io: Io, db: *odb_mod.Odb, request: PushRequest) Self.Error!sendpack.Report {
        assert(s.service == .receive_pack);
        // A helper's sources and `+`s go with the commands by position.
        assert(request.sources.len == 0 or request.sources.len == request.commands.len);
        assert(request.force.len == 0 or request.force.len == request.commands.len);
        switch (s.impl) {
            .local => |here| {
                // A repository on this machine runs no hooks for relic, and
                // push options are for hooks.
                if (request.push_options.len != 0) return error.PushOptionsUnsupported;
                return here.receivePush(gpa, io, .{ .from = db, .commands = request.commands, .objects = request.objects }, .{
                    .who = request.who,
                    .atomic = request.atomic,
                });
            },
            // A bundle is only ever fetched from.
            .bundle => return error.UnsupportedTransport,
            .helper => |helper| {
                const commands = try gpa.alloc(remotehelper.PushCommand, request.commands.len);
                defer gpa.free(commands);
                for (request.commands, commands, 0..) |c, *out, i| out.* = .{
                    .src = if (i < request.sources.len) request.sources[i] else null,
                    .dst = c.name,
                    .old = c.old,
                    .new = c.new,
                    .force = i < request.force.len and request.force[i],
                };
                return helper.h.push(gpa, commands, .{
                    .repo = helper.repository,
                    .who = request.who,
                    .atomic = request.atomic,
                    .push_options = request.push_options,
                });
            },
            .smart => |*smart| {
                smart.done = true;
                // The boundary, sorted as git's list of grafts is.
                const shallow = try gpa.alloc(Oid, db.shallow.count());
                defer gpa.free(shallow);
                var it = db.shallow.keyIterator();
                var i: usize = 0;
                while (it.next()) |oid| : (i += 1) shallow[i] = oid.*;
                std.mem.sort(Oid, shallow, {}, struct {
                    fn lessThan(_: void, a: Oid, b: Oid) bool {
                        return a.order(b) == .lt;
                    }
                }.lessThan);
                return sendpack.send(gpa, io, smart.conn, .{ .advertisement = &smart.advertisement, .db = db }, .{
                    .shallow = shallow,
                    .commands = request.commands,
                    .objects = request.objects,
                    .atomic = request.atomic,
                    .push_options = request.push_options,
                    .progress = request.progress,
                });
            },
        }
    }

    /// What a fetch asks for.
    pub const FetchRequest = fetchpack.Request;

    /// What a fetch brought.
    pub const Fetched = struct {
        pub const Error = ErrorNamespace.Error;

        keep: ?keep_mod.Token = null,
        /// The new pack's name, or `null` when nothing new came.
        pack: ?Oid,
        objects: u32,

        pub fn deinit(f: *Fetched, io: Io) void {
            if (f.keep) |*token| token.deinit(io);
            f.keep = null;
        }
    };

    pub const FetchInputs = struct { db: *odb_mod.Odb, pack_dir: Io.Dir, request: FetchRequest };

    /// Bring every object reachable from `inputs.request.wants` into `inputs.db`, whose
    /// `objects/pack` is `pack_dir`, as one new pack.
    pub fn fetch(
        s: *Session,
        gpa: Allocator,
        io: Io,
        inputs: FetchInputs,
        options: fetchpack.Options,
    ) Self.Error!Fetched {
        const db = inputs.db;
        const pack_dir = inputs.pack_dir;
        const request = inputs.request;
        assert(s.service == .upload_pack);
        // The names go with the wants by position, or are not given.
        assert(request.want_names.len == 0 or request.want_names.len == request.wants.len);
        if (request.wants.len == 0) return .{ .pack = null, .objects = 0 };
        switch (s.impl) {
            .local => |here| {
                // A local copy writes the pack the receive would index, so
                // `pack.threads` sizes it, as git's pack-objects reads it.
                const report = try here.copyObjects(io, db, request.wants, .{ .pack_dir = pack_dir, .haves = request.tips, .include_tags = request.include_tag, .pack = .{
                    .keep = true,
                    .reverse_index = options.receive.reverse_index,
                    .threads = std.math.lossyCast(u16, options.receive.threads),
                } });
                const written = report orelse return .{ .pack = null, .objects = 0 };
                return .{ .pack = written.name, .objects = written.objects, .keep = written.keep };
            },
            .helper => |helper| {
                // A helper is asked by name: the names the caller gives, or
                // those the list gave each object.
                var wants: std.ArrayList(remotehelper.Want) = .empty;
                defer wants.deinit(gpa);
                for (request.wants, 0..) |oid, i| {
                    if (i < request.want_names.len) {
                        try wants.append(gpa, .{ .name = request.want_names[i], .oid = oid });
                        continue;
                    }
                    for (helper.h.listed) |ref| if (ref.oid.eql(oid)) {
                        try wants.append(gpa, .{ .name = ref.name, .oid = oid });
                        break;
                    };
                }
                try helper.h.fetch(wants.items, .{
                    .repo = helper.repository,
                    .who = helper.who,
                    .cloning = helper.cloning,
                    .follow_tags = request.include_tag,
                    .deepen = request.deepen,
                    .filter = request.filter,
                });
                return .{ .pack = null, .objects = 0 };
            },
            .bundle => |f| {
                // git's bundle transport has no depth and no filter; it
                // indexes the bundle's whole pack whatever is wanted.
                if (request.deepen != null or request.filter != null) return error.UnsupportedTransport;
                const result = try bundle.receive(gpa, io, db, .{ .pack_dir = pack_dir, .bundle = f, .refs = request.tips }, options.receive);
                return .{ .pack = result.name, .objects = result.objects, .keep = result.keep };
            },
            .smart => |*smart| {
                // A v0 server sends its pack and is done; a v2 server
                // waits for the next command.
                // Done with either way: git ends a v2 conversation after
                // its fetch by closing it, with no flush.
                smart.done = true;
                const result = try fetchpack.fetch(gpa, io, smart.conn, .{ .advertisement = &smart.advertisement, .db = db, .request = request }, options);
                return .{ .pack = result.name, .objects = result.objects, .keep = result.keep };
            },
        }
    }
};

/// A bundle's refs, as git's bundle transport lists them: last in the
/// header first, since it puts each at the front of its list, and whatever
/// prefixes were asked for.
fn bundleRefs(gpa: Allocator, f: *bundle.File) Error!protocol.RefList {
    var list: protocol.RefList = .{ .arena = .init(gpa), .refs = &.{} };
    errdefer list.arena.deinit();
    const a = list.arena.allocator();
    const refs = try a.alloc(protocol.RemoteRef, f.header.references.len);
    for (f.header.references, 0..) |ref, i| refs[refs.len - 1 - i] = .{ .name = try a.dupe(u8, ref.name), .oid = ref.oid };
    list.refs = refs;
    return list;
}
