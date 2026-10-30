//! A remote, open: the one thing a fetch, a clone or a push talks to.
//!
//! A URL decides the transport. A path or a `file://` URL is another
//! repository on this machine, opened in process by `local.zig`; `ssh://`
//! and the scp-like form start the person's `ssh` through `ssh.zig`; and
//! `http://` and `https://` are git's smart HTTP protocol through
//! `smart_http.zig`. The last two are conversations with the remote's own
//! `git-upload-pack` or `git-receive-pack`, and the protocol above them —
//! the refs, the negotiation, the pack — is the same for both. A path to a
//! bundle file is fetched from as git's bundle transport fetches: its refs
//! listed, its pack indexed whole. A URL that names a remote helper —
//! `<helper>::<address>`, a scheme relic does not speak, `remote.<name>.vcs`
//! — runs `git-remote-<helper>` (`remote_helper.zig`): one that can
//! `connect` becomes a conversation like the others, and one that fetches,
//! imports, pushes or exports is spoken to in its own commands. A `Session`
//! hides which it is from the operations above.

const ErrorNamespace = @This();
const Self = @This();

const http_settings = @import("../wire.zig").http_settings;
const promisors = @import("../wire.zig").promisors;
/// Which proxy an HTTP remote is reached through.
const Proxy = http_settings.Proxy;
// The modules relic's API puts under this one, as `relic.transport.<name>`.

const url = @import("../wire.zig").url;
const urlmatch = @import("../text.zig").urlmatch;
const fs = @import("../fs/fs.zig");

const fetch_pack = @import("../wire.zig").fetch_pack;
const index_pack = @import("../odb/index_pack.zig");

const send_pack = @import("../wire.zig").send_pack;
const local = @import("local.zig");
const ssh = @import("../wire.zig").ssh;
const daemon = @import("../wire.zig").daemon;
const smart_http = @import("../wire.zig").smart_http;
const dumb_http = @import("../wire/dumb_http.zig");

const credential = @import("../wire.zig").credential;
const auth = @import("../wire.zig").auth;
const protocol = @import("../wire.zig").protocol;
const remote_mod = @import("../wire.zig").remote;
const connection = @import("../wire.zig").connection;
const pkt_line = @import("../codec.zig").pkt_line;

const upload_pack = @import("upload_pack.zig");
const receive_pack = @import("receive_pack.zig");
const bundle = @import("bundle.zig");

const progress = @import("../report.zig").progress;
const remote_helper = @import("remote_helper.zig");
const policy = @import("../wire.zig").policy;

const std = @import("std");
const keep_mod = @import("../odb/keep.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const hash = @import("../hash/hash.zig");
const odb_mod = @import("../odb/odb.zig");
const program = @import("../process.zig").program;
const config_mod = @import("../config/config.zig");
const warning = @import("../report.zig").warning;
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;

/// Which service a session talks to.
const Service = connection.Service;

/// Errors from opening and using a remote.
pub const Error = error{
    /// A transport relic does not have: `rsync://`, a remote helper's
    /// `<helper>::<address>`, or `git://` straight to its host where relic
    /// was built without `http`, so without a TCP dialer.
    UnsupportedTransport,
    /// `object-info` asked of a bundle file, a remote helper or a
    /// repository read directly: git's "remote does not support
    /// object-info".
    ObjectInfoUnsupported,
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
    /// A pack the server named by URI does not have the checksum it named:
    /// git's "pack downloaded from <uri> does not match expected hash".
    PackfileUriMismatch,
} || local.Error || receive_pack.Error || fetch_pack.Error || protocol.Error || program.Error || ssh.Error || daemon.Error || smart_http.Error || dumb_http.Error || send_pack.Error || bundle.Error ||
    remote_helper.Error;

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
    now: ?std.Io.Timestamp = null,
    /// Read a repository on this machine directly, as git's local clone
    /// copies one, rather than through upload-pack. Only a fetch reads it.
    local_copy: bool = false,
    /// Where what git would print as a warning goes, as values: see
    /// `warning.Warnings`.
    warnings: ?*warning.Warnings = null,
    /// The local repository: a remote helper's `GIT_DIR`, and where its
    /// `fetch`, `import`, `push` and `export` read and write.
    repository: ?*repo_mod.Repository = null,
    /// Who the refs a remote helper's import writes are logged as, and the
    /// refs a push to a repository on this machine writes there.
    who: ?object.Signature = null,
    /// The repository is a clone's, new: a remote helper is told so.
    cloning: bool = false,
    /// `--server-option`s for every v2 request of the session, `ls-refs`
    /// and `fetch`, as git's transport sends them; a v0 or v1 server is
    /// refused them. `null` takes `remote.<remote_name>.serverOption` from
    /// `config`, as git's handshake does. Borrowed for the session's life.
    server_options: ?[]const []const u8 = null,
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
///
/// A password is what git's `url_normalize` finds in the URL, of any
/// scheme, and the URL named in the warning is the normalized one, as git
/// names it; a URL that does not normalize carries none.
fn checkCredentialsInUrl(gpa: Allocator, text: []const u8, options: Options) Error!void {
    const config = options.config orelse return;
    const value = config.get("transfer.credentialsinurl") orelse return;
    if (std.mem.eql(u8, value, "allow")) return;
    const warn = std.mem.eql(u8, value, "warn");
    // git dies on any other value, whatever the URL.
    if (!warn and !std.mem.eql(u8, value, "die")) return error.CredentialsInUrl;
    var info = urlmatch.normalize(gpa, text, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer info.deinit(gpa);
    const password = info.password orelse return;
    if (!warn) return error.CredentialsInUrl;
    const redacted = try gpa.print("{s}<redacted>{s}", .{ info.url[0..password.off], info.url[password.off + password.len ..] });
    defer gpa.free(redacted);
    try warning.note(options.warnings, .{ .credentials_in_url = redacted });
}

/// Who a push to this machine is logged as when the caller names no one.
const unknown_pusher: object.Signature = .{ .name = "", .email = "", .when_secs = 0, .offset_minutes = 0 };

/// Whether `config` leaves protocol v2 on: `protocol.version` unset or 2.
pub fn wantsV2(config: ?*const config_mod.Config) bool {
    const c = config orelse return true;
    const text = c.get("protocol.version") orelse return true;
    return !(std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "1"));
}

/// An open remote.
/// `remote_url`'s body written to `w` with the transfer settings `options`
/// hold: one `GET` over http or https (`smart_http.download`), what a
/// bundle URI is fetched with. Any other scheme is `UnsupportedTransport`.
pub fn download(gpa: Allocator, io: Io, w: *Io.Writer, remote_url: []const u8, options: Options) (Error || Io.Writer.Error)!void {
    const parsed = try url.Url.parse(remote_url);
    if (parsed.scheme != .http and parsed.scheme != .https) return error.UnsupportedTransport;
    return smart_http.download(gpa, io, w, parsed, Session.httpOptions(options));
}

pub const Session = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    service: Service,
    /// `transfer.advertiseSID`: the id this side names itself by to a
    /// server that takes one, its length in `session_id_buf`; zero for
    /// none.
    session_id_buf: [protocol.session_id_len]u8 = undefined,
    session_id_len: usize = 0,
    /// `Options.server_options`, or the remote's, owned in
    /// `owned_server_options`.
    server_options: []const []const u8 = &.{},
    owned_server_options: [][]u8 = &.{},
    /// What the session was opened with, borrowed for its life as
    /// `server_options` is: a pack the server names by URI is downloaded
    /// with its `http.*` settings and credentials.
    transfer: Options = .{},
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
            creates: []const promisors.Create = &.{},
            stores: []const promisors.Store = &.{},
        },
        /// A server that speaks git's dumb HTTP protocol: its files.
        dumb: *dumb_http.Remote,
        /// A remote helper spoken to in its own commands.
        helper: struct {
            h: *remote_helper.Helper,
            repository: ?*repo_mod.Repository,
            who: ?object.Signature,
            cloning: bool,
        },
    },

    /// git's `--negotiate-only`: the haves from `request.tips` and its
    /// `include_haves` offered to a v2 server until it has said what it
    /// holds of them; no pack. The commits it acknowledged, the caller's.
    /// Only a smart server speaks it.
    pub fn negotiateOnly(s: *Session, gpa: Allocator, io: Io, db: *odb_mod.Odb, request: FetchRequest) Self.Error![]Oid {
        return switch (s.impl) {
            .local, .bundle, .dumb, .helper => error.NegotiateOnlyNeedsV2,
            .smart => |*smart| {
                // The server is told nothing more after it.
                smart.done = true;
                var with_id = request;
                with_id.session_id = s.sessionId();
                if (with_id.server_options.len == 0) with_id.server_options = s.server_options;
                return fetch_pack.negotiateOnly(gpa, io, smart.conn, .{ .advertisement = &smart.advertisement, .db = db, .request = with_id });
            },
        };
    }

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
        session.transfer = options;
        try session.answerPromisors(options);
        if (options.server_options) |given| {
            session.server_options = given;
        } else if (options.config) |config| if (options.remote_name) |name| {
            session.owned_server_options = try remote_mod.serverOptions(gpa, config, name);
            session.server_options = session.owned_server_options;
        };
        if (options.config) |config| if (try config.getBool("transfer.advertisesid", false)) {
            session.session_id_len = protocol.sessionId(io, &session.session_id_buf).len;
        };
        return session;
    }

    fn sessionId(s: *const Session) ?[]const u8 {
        return if (s.session_id_len == 0) null else s.session_id_buf[0..s.session_id_len];
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
        smart.creates = answer.creates;
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

    /// The remotes `promisor.acceptFromServerUrl` configures from the
    /// server's `promisor-remote`: `partial.storeAdvertised` writes them.
    pub fn promisorCreates(s: *const Session) []const promisors.Create {
        return switch (s.impl) {
            .smart => |smart| smart.creates,
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
        try checkCredentialsInUrl(gpa, remote_url, options);
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
                const conn = try upload_pack.connect(gpa, io, here, if (v2) .v2 else .v0, .{ .programs = options.programs });
                owned = false;
                errdefer conn.deinit(io);
                return fromConnection(gpa, conn, service, kind);
            } else if (service == .receive_pack) {
                // A push to this machine goes through receive-pack, as
                // git's does — relic's own, in this process, which runs the
                // repository's hooks with the caller's permission.
                const here = try gpa.create(local.Remote);
                var owned = true;
                errdefer if (owned) gpa.destroy(here);
                here.* = try local.Remote.open(gpa, io, remote_url, .{});
                errdefer if (owned) here.deinit(io);
                if (kind) |k| if (k != here.repo.objectFormat()) return error.ObjectFormatMismatch;
                const conn = try receive_pack.connect(gpa, io, here, .{
                    .who = options.who orelse unknown_pusher,
                    .programs = options.programs,
                    // The path git's receive-pack would be started on.
                    .service_dir = parsed.path,
                });
                owned = false;
                errdefer conn.deinit(io);
                return fromConnection(gpa, conn, service, kind);
            } else {
                const here = try gpa.create(local.Remote);
                errdefer gpa.destroy(here);
                here.* = try local.Remote.open(gpa, io, remote_url, .{});
                errdefer here.deinit(io);
                if (kind) |k| if (k != here.repo.objectFormat()) return error.ObjectFormatMismatch;
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
                // `error.HttpUnavailable` where relic was built without HTTP.
                switch (try smart_http.connect(gpa, io, parsed, service, httpOptions(options))) {
                    .smart => |conn| {
                        errdefer conn.deinit(io);
                        return fromConnection(gpa, conn, service, kind);
                    },
                    .dumb => |files| {
                        const environ = if (options.programs) |p| p.environ else null;
                        const remote = try dumb_http.Remote.open(gpa, io, files, .{
                            .http = httpOptions(options),
                            .policy = .{ .config = options.config, .environ = environ, .from_user = options.from_user },
                            .warnings = options.warnings,
                        });
                        errdefer remote.deinit(io);
                        if (kind) |k| if (k != remote.kind) return error.ObjectFormatMismatch;
                        return .{ .gpa = gpa, .service = service, .impl = .{ .dumb = remote } };
                    },
                }
            },
            .git => {
                var identity = try url.Identity.parse(gpa, remote_url);
                defer identity.deinit();
                const conn = try daemon.connect(gpa, io, identity.url, service, .{
                    .programs = options.programs,
                    .config = options.config,
                    .service_program = options.service_program,
                    .protocol_v2 = options.protocol_v2 orelse wantsV2(options.config),
                });
                errdefer conn.deinit(io);
                return fromConnection(gpa, conn, service, kind);
            },
        }
    }

    /// What a conversation over HTTP is made with.
    fn httpOptions(options: Options) smart_http.Options {
        return .{
            .config = options.config,
            .remote_name = options.remote_name,
            .base = if (options.repository) |r| r.topDirectory().get() else null,
            .proxy = options.proxy,
            .programs = options.programs,
            .protocol_v2 = options.protocol_v2 orelse wantsV2(options.config),
            .prompt = options.prompt,
            .auth_failure = options.auth_failure,
            .warnings = options.warnings,
            .now = options.now,
            .from_user = options.from_user,
        };
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
        const spec = remote_helper.Spec.of(remote_url, options.remote_name, vcs) orelse return null;
        try checkAllowed(options, spec.name);
        const programs = options.programs orelse return error.ProgramsNotGranted;
        const git_dir: ?[:0]u8 = if (options.repository) |r| try fs.realPathAlloc(gpa, io, r.gitDirectory().get(), ".") else null;
        defer if (git_dir) |d| gpa.free(d);
        const h = try remote_helper.Helper.open(gpa, io, spec, .{
            .programs = programs,
            .git_dir = git_dir,
            .progress = options.progress != null,
            .object_format = kind orelse .sha1,
            .warnings = options.warnings,
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
            // An archive goes over a helper's `connect` alone, as git's.
            .upload_archive => return error.UnsupportedTransport,
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
            .dumb => |remote| remote.deinit(io),
            .helper => |helper| helper.h.deinit(io),
            .smart => |*smart| {
                // A conversation over a pipe that the server still waits on
                // ends with a flush, which it reads as nothing more wanted,
                // as git's disconnect writes it.
                if (!smart.conn.stateless and !smart.done) {
                    // The farewell is a courtesy: the session closes either
                    // way, and a server that has gone cannot read it. A
                    // cancel is put back for the caller.
                    sayGoodbye(smart.conn) catch |err| switch (err) {
                        error.WriteFailed => if (smart.conn.failure() == error.Canceled) io.recancel(),
                        else => {},
                    };
                }
                smart.advertisement.deinit();
                smart.conn.deinit(io);
            },
        }
        remote_mod.freeList(s.gpa, s.owned_server_options);
        s.* = undefined;
    }

    fn sayGoodbye(conn: *Connection) !void {
        const w = try conn.request();
        try pkt_line.flush(w);
        try w.flush();
    }

    /// The hash the remote's object names are written with.
    pub fn objectFormat(s: *const Session) hash.Kind {
        return switch (s.impl) {
            .local => |here| here.repo.objectFormat(),
            .bundle => |f| f.header.object_format,
            .smart => |smart| smart.advertisement.kind,
            .dumb => |remote| remote.kind,
            .helper => |helper| helper.h.kind,
        };
    }

    /// A shallow v0 server's boundary, as its advertisement gave it: what a
    /// fetch that asks for no depth takes the server's shallow lines to be.
    pub fn advertisedShallow(s: *const Session) []const Oid {
        return switch (s.impl) {
            .local, .bundle, .dumb, .helper => &.{},
            .smart => |smart| smart.advertisement.shallow,
        };
    }

    /// Whether git's fetch-pack names the refs in a promisor pack's
    /// `.promisor` over this conversation. Over HTTP in protocol v0 it does
    /// not: there its index-pack writes the file, empty.
    pub fn promisorNamesRefs(s: *const Session) bool {
        return switch (s.impl) {
            .local, .bundle, .dumb, .helper => true,
            .smart => |smart| !(smart.conn.stateless and smart.advertisement.version != .v2),
        };
    }

    /// The protocol the remote spoke, or `null` for a repository on this
    /// machine, which speaks none.
    pub fn protocolVersion(s: *const Session) ?protocol.Version {
        return switch (s.impl) {
            .local, .bundle, .dumb, .helper => null,
            .smart => |smart| smart.advertisement.version,
        };
    }

    /// The remote's refs, only those beginning with one of `prefixes` when
    /// any are given. The result is the caller's.
    pub fn listRefs(s: *Session, gpa: Allocator, io: Io, prefixes: []const []const u8) Self.Error!protocol.RefList {
        return switch (s.impl) {
            .local => |here| here.listRefs(gpa, io, prefixes),
            .bundle => |f| bundleRefs(gpa, f),
            .dumb => |remote| remote.listRefs(gpa, prefixes),
            .smart => |*smart| protocol.listRefs(gpa, smart.conn, &smart.advertisement, .{ .prefixes = prefixes, .server_options = s.server_options }),
            .helper => |helper| helper.h.list(gpa, helper.repository, .{ .for_push = s.service == .receive_pack }),
        };
    }

    /// What the remote's `bundle-uri` command lists, as `key=value` lines:
    /// a v2 server's answer, or for a repository read directly what its
    /// upload-pack would answer. None where the server does not advertise
    /// the command. `null` for a bundle file and a remote helper, which
    /// git's transports for them cannot ask. What the upload-pack of a
    /// repository read directly says goes to `warnings`. The lines are
    /// `arena`'s.
    pub fn bundleUri(s: *Session, arena: Allocator, warnings: ?*warning.Warnings) Self.Error!?[]const []const u8 {
        return switch (s.impl) {
            .local => |here| if (upload_pack.advertisesBundleUris(here.repo.configuration())) try upload_pack.bundleSettings(arena, here.repo.configuration(), warnings) else &.{},
            .bundle, .dumb, .helper => null,
            .smart => |*smart| try protocol.bundleUri(arena, smart.conn, &smart.advertisement),
        };
    }

    /// What the remote's `object-info` says of `request.oids`: git 2.56's
    /// `transport_fetch_object_info`, which cat-file's `remote-object-info`
    /// asks. Only a server speaking protocol v2 answers it, over ssh, HTTP
    /// or a repository on this machine through upload-pack; the session's
    /// id and server options go with it. The lists are `arena`'s.
    pub fn objectInfo(s: *Session, arena: Allocator, request: protocol.ObjectInfoRequest) Self.Error!protocol.ObjectInfo {
        return switch (s.impl) {
            .local, .bundle, .dumb, .helper => error.ObjectInfoUnsupported,
            .smart => |*smart| {
                var with_id = request;
                with_id.extras.session_id = s.sessionId();
                if (with_id.extras.server_options.len == 0) with_id.extras.server_options = s.server_options;
                return protocol.objectInfo(arena, smart.conn, &smart.advertisement, with_id);
            },
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
        commands: []const send_pack.Command,
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
        /// For a smart server: the signed certificate sent in place of the
        /// commands (`certificateNonce`).
        certificate: ?[]const u8 = null,
        /// For a remote helper, which signs for itself: whether it is to.
        push_cert: send_pack.PushCert = .never,
    };

    /// What the remote says of a signed push, before one is made: a helper
    /// is told the caller's word and signs for itself; a smart server
    /// issues the nonce its certificate carries — `push-cert=<nonce>` —
    /// or takes none (`null`).
    pub const CertOffer = union(enum) { helper, nonce: ?[]const u8 };

    pub fn certOffer(s: *const Session) CertOffer {
        return switch (s.impl) {
            .smart => |*smart| .{ .nonce = smart.advertisement.value("push-cert") },
            .helper => .helper,
            .local, .bundle, .dumb => .{ .nonce = null },
        };
    }

    /// Send a push, reading the objects from `db`, and return the remote's
    /// report of each command.
    pub fn push(s: *Session, gpa: Allocator, io: Io, db: *odb_mod.Odb, request: PushRequest) Self.Error!send_pack.Report {
        assert(s.service == .receive_pack);
        // A helper's sources and `+`s go with the commands by position.
        assert(request.sources.len == 0 or request.sources.len == request.commands.len);
        assert(request.force.len == 0 or request.force.len == request.commands.len);
        switch (s.impl) {
            // A repository on this machine is pushed to through its
            // receive-pack, and a bundle is only ever fetched from.
            .local, .bundle => return error.UnsupportedTransport,
            // git pushes to a dumb server over WebDAV.
            .dumb => return error.DumbHttpPushUnsupported,
            .helper => |helper| {
                const commands = try gpa.alloc(remote_helper.PushCommand, request.commands.len);
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
                    .push_cert = request.push_cert,
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
                return send_pack.send(gpa, io, smart.conn, .{ .advertisement = &smart.advertisement, .db = db }, .{
                    .shallow = shallow,
                    .commands = request.commands,
                    .objects = request.objects,
                    .atomic = request.atomic,
                    .push_options = request.push_options,
                    .progress = request.progress,
                    .certificate = request.certificate,
                    .session_id = s.sessionId(),
                });
            },
        }
    }

    /// What a fetch asks for.
    pub const FetchRequest = fetch_pack.Request;

    /// What a fetch brought.
    pub const Fetched = struct {
        pub const Error = ErrorNamespace.Error;

        keep: ?keep_mod.Token = null,
        /// The new pack's name, or `null` when nothing new came.
        pack: ?Oid,
        objects: u32,
        /// The packs the server named by URI (`packfile-uris`), downloaded
        /// and indexed beside `pack` as git's `http-fetch --packfile` does,
        /// in the order it named them; `uri_gpa`'s.
        uri_packs: []UriPack = &.{},
        uri_gpa: ?Allocator = null,

        pub fn deinit(f: *Fetched, io: Io) void {
            if (f.keep) |*token| token.deinit(io);
            for (f.uri_packs) |*p| if (p.keep) |*token| token.deinit(io);
            if (f.uri_gpa) |g| g.free(f.uri_packs);
            f.* = undefined;
        }
    };

    /// A pack a server named by URI, as it was indexed.
    pub const UriPack = struct {
        pub const Error = ErrorNamespace.Error;

        name: Oid,
        objects: u32,
        keep: ?keep_mod.Token = null,
    };

    pub const FetchInputs = struct { db: *odb_mod.Odb, pack_dir: Io.Dir, request: FetchRequest };

    /// Bring every object reachable from `inputs.request.wants` into `inputs.db`, whose
    /// `objects/pack` is `pack_dir`, as one new pack.
    pub fn fetch(
        s: *Session,
        gpa: Allocator,
        io: Io,
        inputs: FetchInputs,
        options: fetch_pack.Options,
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
                var wants: std.ArrayList(remote_helper.Want) = .empty;
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
            .dumb => |remote| {
                // git's `fetch_dumb`: no depth and no date, and a filter
                // is never read, so everything comes. An exclusion git
                // drops without a word (remote-curl.c:1175), and a caller
                // who asked for a shallow clone is told, not handed a
                // whole one. A pack is indexed as git's `index-pack
                // --stdin` indexes it, kept by nothing.
                if (request.deepen) |d| if (d.depth != null or d.since != null or d.not.len != 0) return error.DumbHttpShallow;
                var receive = options.receive;
                receive.keep = false;
                const got = try remote.fetch(io, db, request.wants, request.tips, receive);
                return .{ .pack = null, .objects = got.loose };
            },
            .bundle => |f| {
                // git's bundle transport has no depth and no filter; it
                // indexes the bundle's whole pack whatever is wanted.
                if (request.deepen != null or request.filter != null) return error.UnsupportedTransport;
                const result = try bundle.receive(gpa, io, db, .{ .bundle = f, .refs = request.tips }, options.receive);
                return .{ .pack = result.name, .objects = result.objects, .keep = result.keep };
            },
            .smart => |*smart| {
                // A v0 server sends its pack and is done; a v2 server
                // waits for the next command.
                // Done with either way: git ends a v2 conversation after
                // its fetch by closing it, with no flush.
                smart.done = true;
                var with_id = request;
                with_id.session_id = s.sessionId();
                if (with_id.server_options.len == 0) with_id.server_options = s.server_options;
                var protocols: [][]const u8 = &.{};
                defer gpa.free(protocols);
                if (with_id.uri_protocols.len == 0) if (s.transfer.config) |config| if (config.get("fetch.uriprotocols")) |text| {
                    // git's `string_list_split` at commas, nothing trimmed.
                    protocols = try gpa.alloc([]const u8, std.mem.countScalar(u8, text, ',') + 1);
                    var it = std.mem.splitScalar(u8, text, ',');
                    for (protocols) |*p| p.* = it.next().?;
                    with_id.uri_protocols = protocols;
                };
                var result = try fetch_pack.fetch(gpa, io, smart.conn, .{ .advertisement = &smart.advertisement, .db = db, .request = with_id }, options);
                defer result.deinitUris(gpa);
                errdefer result.pack.deinit(io);
                const uri_packs = try s.receiveUriPacks(gpa, io, db, pack_dir, result.uris, options.receive);
                errdefer {
                    for (uri_packs) |*p| if (p.keep) |*token| token.deinit(io);
                    gpa.free(uri_packs);
                }
                // git's `fsck_finish`, once every pack is in.
                if (result.found) |*found| try index_pack.checkFound(gpa, io, db, found, .{
                    .rules = options.receive.fsck.?,
                    .promised = options.receive.promised,
                    .warnings = options.receive.warnings,
                    .diagnostic = options.receive.diagnostic,
                    .max_object_bytes = options.receive.max_object_bytes,
                });
                return .{ .pack = result.pack.name, .objects = result.pack.objects, .keep = result.pack.keep, .uri_packs = uri_packs, .uri_gpa = gpa };
            },
        }
    }

    /// Each of `uris` downloaded into `pack_dir` and indexed with
    /// `receive`, as git's fetch-pack runs `http-fetch --packfile` for it
    /// with the main pack's index-pack arguments, and refused unless the
    /// pack has the checksum the server named. The caller's, on `gpa`.
    fn receiveUriPacks(
        s: *Session,
        gpa: Allocator,
        io: Io,
        db: *odb_mod.Odb,
        pack_dir: Io.Dir,
        uris: []const fetch_pack.PackfileUri,
        receive: index_pack.Options,
    ) Self.Error![]UriPack {
        var packs: std.ArrayList(UriPack) = .empty;
        errdefer {
            for (packs.items) |*p| if (p.keep) |*token| token.deinit(io);
            packs.deinit(gpa);
        }
        for (uris) |named| {
            try packs.ensureUnusedCapacity(gpa, 1);
            var result = try s.receiveUriPack(gpa, io, db, pack_dir, named.uri, receive);
            errdefer result.deinit(io);
            const name = result.name orelse return error.PackfileUriMismatch;
            if (!name.eql(named.hash)) return error.PackfileUriMismatch;
            packs.appendAssumeCapacity(.{ .name = name, .objects = result.objects, .keep = result.keep });
        }
        return packs.toOwnedSlice(gpa);
    }

    /// One pack at `uri`, downloaded to a temporary file in `pack_dir`
    /// and indexed from it, the file removed after.
    fn receiveUriPack(s: *Session, gpa: Allocator, io: Io, db: *odb_mod.Odb, pack_dir: Io.Dir, uri: []const u8, receive: index_pack.Options) Self.Error!index_pack.Result {
        const parsed = try url.Url.parse(uri);
        if (parsed.scheme != .http and parsed.scheme != .https) return error.UnsupportedTransport;
        try checkAllowed(s.transfer, @tagName(parsed.scheme));
        var name_buf: [64]u8 = undefined;
        const temp = fs.tempName(io, &name_buf, "tmp_uri_pack_");
        const file = try pack_dir.createFile(io, temp, .{ .read = true, .exclusive = true });
        defer {
            file.close(io);
            // The download is indexed into a pack of its own; a temporary
            // file left behind holds nothing the repository uses.
            fs.removeLeftover(io, pack_dir, temp);
        }
        var buf: [64 * 1024]u8 = undefined;
        var w = file.writer(io, &buf);
        smart_http.download(gpa, io, &w.interface, parsed, httpOptions(s.transfer)) catch |err| return switch (err) {
            error.WriteFailed => w.err orelse error.WriteFailed,
            else => |e| e,
        };
        w.interface.flush() catch return w.err orelse error.WriteFailed;
        var r = file.reader(io, &buf);
        return db.receivePack(io, &r.interface, receive) catch |err| switch (err) {
            error.ReadFailed => r.err orelse error.ReadFailed,
            else => |e| e,
        };
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
