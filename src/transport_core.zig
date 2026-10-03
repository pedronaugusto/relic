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
//! listed, its pack indexed whole. A `Session` hides which it is from the
//! operations above.

// The modules relic's API puts under this one, as `relic.transport.<name>`.

const url = @import("url.zig");

const fetchpack = @import("fetchpack.zig");

const sendpack = @import("sendpack.zig");
const local = @import("local.zig");
const ssh = @import("ssh.zig");
const smarthttp = @import("smarthttp.zig");

const credential = @import("credential.zig");
const auth = @import("auth.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const pktline = @import("pktline.zig");

const uploadpack = @import("uploadpack.zig");
const bundle = @import("bundle.zig");

const progress = @import("progress.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const odb_mod = @import("odb_core.zig");
const pack = @import("pack.zig");
const program = @import("program.zig");
const config_mod = @import("config_core.zig");
const warning = @import("warning.zig");
const object = @import("object_core.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;

/// Which service a session talks to.
pub const Service = connection.Service;

/// Errors from opening and using a remote.
pub const Error = error{
    /// A transport relic does not have: `git://`, `rsync://`, a remote
    /// helper's `<helper>::<address>`.
    UnsupportedTransport,
    /// A URL that does not parse.
    MalformedUrl,
    /// The transport needs to run a program — `ssh`, a credential helper —
    /// and the caller handed in no `program.Programs`.
    ProgramsNotGranted,
} || local.Error || fetchpack.Error || protocol.Error || program.Error || ssh.Error || smarthttp.Error || sendpack.Error || bundle.Error;

/// How a remote is reached.
pub const Options = struct {
    /// The permission to run programs: `ssh` for an ssh URL. Without it an
    /// ssh URL is `error.ProgramsNotGranted`.
    programs: ?program.Programs = null,
    /// The repository's configuration, for `core.sshCommand`, `ssh.variant`
    /// and the `http.*` settings.
    config: ?*const config_mod.Config = null,
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
};

/// Whether `config` leaves protocol v2 on: `protocol.version` unset or 2.
pub fn wantsV2(config: ?*const config_mod.Config) bool {
    const c = config orelse return true;
    const text = c.get("protocol.version") orelse return true;
    return !(std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "1"));
}

/// An open remote.
pub const Session = struct {
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
        },
    },

    /// Open the remote at `remote_url` for `service`. `kind` is the local
    /// repository's hash, or `null` when there is no local repository yet.
    pub fn open(
        gpa: Allocator,
        io: Io,
        remote_url: []const u8,
        service: Service,
        kind: ?hash.Kind,
        options: Options,
    ) Error!Session {
        const parsed = url.Url.parse(remote_url) catch |err| return err;
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
                f.close(gpa, io);
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
                here.* = try local.Remote.open(gpa, io, remote_url);
                errdefer if (owned) here.deinit(io);
                if (kind) |k| if (k != here.repo.objectFormat()) return error.ObjectFormatMismatch;
                const v2 = options.protocol_v2 orelse wantsV2(options.config);
                const conn = try uploadpack.connect(gpa, io, here, if (v2) .v2 else .v0, .{});
                owned = false;
                errdefer conn.close(io);
                return fromConnection(gpa, conn, service, kind);
            } else {
                const here = try gpa.create(local.Remote);
                errdefer gpa.destroy(here);
                here.* = try local.Remote.open(gpa, io, remote_url);
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
                errdefer conn.close(io);
                return fromConnection(gpa, conn, service, kind) catch |err| switch (err) {
                    error.RemoteHungUp, error.ConnectionFailed, error.ProtocolError => return ssh.explain(gpa, conn, io, err, identity.url, options.auth_failure),
                    else => |e| return e,
                };
            },
            .http, .https => {
                const conn = try smarthttp.connect(gpa, io, parsed, service, .{
                    .config = options.config,
                    .programs = options.programs,
                    .protocol_v2 = options.protocol_v2 orelse wantsV2(options.config),
                    .prompt = options.prompt,
                    .auth_failure = options.auth_failure,
                    .warnings = options.warnings,
                    .now = options.now,
                });
                errdefer conn.close(io);
                return fromConnection(gpa, conn, service, kind);
            },
            .git => return error.UnsupportedTransport,
        }
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
    pub fn close(s: *Session, io: Io) void {
        switch (s.impl) {
            .local => |here| {
                here.deinit(io);
                s.gpa.destroy(here);
            },
            .bundle => |f| f.close(s.gpa, io),
            .smart => |*smart| {
                // A conversation over a pipe that the server still waits on
                // ends with a flush, which it reads as nothing more wanted,
                // as git's disconnect writes it.
                if (!smart.conn.stateless and !smart.done) {
                    if (smart.conn.request()) |w| {
                        @import("pktline.zig").flush(w) catch {};
                        w.flush() catch {};
                    } else |_| {}
                }
                smart.advertisement.deinit();
                smart.conn.close(io);
            },
        }
        s.* = undefined;
    }

    /// The hash the remote's object names are written with.
    pub fn objectFormat(s: *const Session) hash.Kind {
        return switch (s.impl) {
            .local => |here| here.repo.objectFormat(),
            .bundle => |f| f.header.object_format,
            .smart => |smart| smart.advertisement.kind,
        };
    }

    /// A shallow v0 server's boundary, as its advertisement gave it: what a
    /// fetch that asks for no depth takes the server's shallow lines to be.
    pub fn advertisedShallow(s: *const Session) []const Oid {
        return switch (s.impl) {
            .local, .bundle => &.{},
            .smart => |smart| smart.advertisement.shallow,
        };
    }

    /// Whether git's fetch-pack names the refs in a promisor pack's
    /// `.promisor` over this conversation. Over HTTP in protocol v0 it does
    /// not: there its index-pack writes the file, empty.
    pub fn promisorNamesRefs(s: *const Session) bool {
        return switch (s.impl) {
            .local, .bundle => true,
            .smart => |smart| !(smart.conn.stateless and smart.advertisement.version != .v2),
        };
    }

    /// The protocol the remote spoke, or `null` for a repository on this
    /// machine, which speaks none.
    pub fn protocolVersion(s: *const Session) ?protocol.Version {
        return switch (s.impl) {
            .local, .bundle => null,
            .smart => |smart| smart.advertisement.version,
        };
    }

    /// The remote's refs, only those beginning with one of `prefixes` when
    /// any are given. The result is the caller's.
    pub fn listRefs(s: *Session, gpa: Allocator, io: Io, prefixes: []const []const u8) Error!protocol.RefList {
        return switch (s.impl) {
            .local => |here| here.listRefs(gpa, io, prefixes),
            .bundle => |f| bundleRefs(gpa, f),
            .smart => |*smart| protocol.listRefs(gpa, smart.conn, &smart.advertisement, .{ .prefixes = prefixes }),
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
    };

    /// Send a push, reading the objects from `db`, and return the remote's
    /// report of each command.
    pub fn push(s: *Session, gpa: Allocator, io: Io, db: *odb_mod.Odb, request: PushRequest) Error!sendpack.Report {
        std.debug.assert(s.service == .receive_pack);
        switch (s.impl) {
            .local => |here| {
                // A repository on this machine runs no hooks for relic, and
                // push options are for hooks.
                if (request.push_options.len != 0) return error.PushOptionsUnsupported;
                return here.receivePush(gpa, io, db, request.commands, request.objects, .{
                    .who = request.who,
                    .atomic = request.atomic,
                });
            },
            // A bundle is only ever fetched from.
            .bundle => return error.UnsupportedTransport,
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
                return sendpack.send(gpa, io, smart.conn, &smart.advertisement, db, .{
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
        /// The new pack's name, or `null` when nothing new came.
        pack: ?Oid,
        objects: u32,
    };

    /// Bring every object reachable from `request.wants` into `db`, whose
    /// `objects/pack` is `pack_dir`, as one new pack.
    pub fn fetch(
        s: *Session,
        gpa: Allocator,
        io: Io,
        db: *odb_mod.Odb,
        pack_dir: Io.Dir,
        request: FetchRequest,
        options: fetchpack.Options,
    ) Error!Fetched {
        std.debug.assert(s.service == .upload_pack);
        if (request.wants.len == 0) return .{ .pack = null, .objects = 0 };
        switch (s.impl) {
            .local => |here| {
                // A local copy writes the pack the receive would index, so
                // `pack.threads` sizes it, as git's pack-objects reads it.
                const report = try here.copyObjects(io, db, pack_dir, request.wants, request.tips, request.include_tag, .{
                    .reverse_index = options.receive.reverse_index,
                    .threads = std.math.lossyCast(u16, options.receive.threads),
                });
                const written = report orelse return .{ .pack = null, .objects = 0 };
                return .{ .pack = written.name, .objects = written.objects };
            },
            .bundle => |f| {
                // git's bundle transport has no depth and no filter; it
                // indexes the bundle's whole pack whatever is wanted.
                if (request.deepen != null or request.filter != null) return error.UnsupportedTransport;
                const result = try bundle.receive(gpa, io, db, pack_dir, f, options.receive);
                return .{ .pack = result.name, .objects = result.objects };
            },
            .smart => |*smart| {
                // A v0 server sends its pack and is done; a v2 server
                // waits for the next command.
                // Done with either way: git ends a v2 conversation after
                // its fetch by closing it, with no flush.
                smart.done = true;
                const result = try fetchpack.fetch(gpa, io, smart.conn, &smart.advertisement, db, pack_dir, request, options);
                return .{ .pack = result.name, .objects = result.objects };
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
