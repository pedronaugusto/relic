//! A remote, open: the one thing a fetch, a clone or a push talks to.
//!
//! A URL decides the transport. A path or a `file://` URL is another
//! repository on this machine, opened in process by `local.zig`; `ssh://`
//! and the scp-like form start the person's `ssh` through `ssh.zig`; and
//! `http://` and `https://` are git's smart HTTP protocol through
//! `smarthttp.zig`. The last two are conversations with the remote's own
//! `git-upload-pack` or `git-receive-pack`, and the protocol above them —
//! the refs, the negotiation, the pack — is the same for both. A `Session`
//! hides which of the three it is from the operations above.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");
const program = @import("program.zig");
const config_mod = @import("config.zig");
const url_mod = @import("url.zig");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const fetchpack = @import("fetchpack.zig");
const indexpack = @import("indexpack.zig");
const local = @import("local.zig");
const progress_mod = @import("progress.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;

pub const Service = connection.Service;

pub const Error = error{
    /// A transport relic does not have: `git://`, `rsync://`, a remote
    /// helper's `<helper>::<address>`.
    UnsupportedTransport,
    /// A URL that does not parse.
    MalformedUrl,
    /// The transport needs to run a program — `ssh`, a credential helper —
    /// and the caller handed in no `program.Programs`.
    ProgramsNotGranted,
} || local.Error || fetchpack.Error || protocol.Error || program.Error;

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
    /// answers in v0, which is read the same.
    protocol_v2: bool = true,
    progress: ?progress_mod.Progress = null,
};

/// An open remote.
pub const Session = struct {
    gpa: Allocator,
    service: Service,
    impl: union(enum) {
        local: *local.Remote,
        smart: struct {
            conn: *Connection,
            advertisement: protocol.Advertisement,
        },
    },

    /// Open the remote at `url` for `service`. `kind` is the local
    /// repository's hash, or `null` when there is no local repository yet.
    pub fn open(
        gpa: Allocator,
        io: Io,
        url: []const u8,
        service: Service,
        kind: ?hash.Kind,
        options: Options,
    ) Error!Session {
        const parsed = url_mod.Url.parse(url) catch |err| return err;
        _ = options;
        switch (parsed.scheme) {
            .local, .file => {
                const remote = try gpa.create(local.Remote);
                errdefer gpa.destroy(remote);
                remote.* = try local.Remote.open(gpa, io, url);
                errdefer remote.deinit(io);
                if (kind) |k| if (k != remote.repo.kind) return error.ObjectFormatMismatch;
                return .{ .gpa = gpa, .service = service, .impl = .{ .local = remote } };
            },
            .ssh, .http, .https => return error.UnsupportedTransport,
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
            .local => |remote| {
                remote.deinit(io);
                s.gpa.destroy(remote);
            },
            .smart => |*smart| {
                smart.advertisement.deinit();
                smart.conn.close(io);
            },
        }
        s.* = undefined;
    }

    /// The hash the remote's object names are written with.
    pub fn objectFormat(s: *const Session) hash.Kind {
        return switch (s.impl) {
            .local => |remote| remote.repo.kind,
            .smart => |smart| smart.advertisement.kind,
        };
    }

    /// The protocol the remote spoke, or `null` for a repository on this
    /// machine, which speaks none.
    pub fn protocolVersion(s: *const Session) ?protocol.Version {
        return switch (s.impl) {
            .local => null,
            .smart => |smart| smart.advertisement.version,
        };
    }

    /// The remote's refs, only those beginning with one of `prefixes` when
    /// any are given. The result is the caller's.
    pub fn listRefs(s: *Session, gpa: Allocator, io: Io, prefixes: []const []const u8) Error!protocol.RefList {
        return switch (s.impl) {
            .local => |remote| remote.listRefs(gpa, io, prefixes),
            .smart => |*smart| protocol.listRefs(gpa, smart.conn, &smart.advertisement, .{ .prefixes = prefixes }),
        };
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
            .local => |remote| {
                const report = try remote.copyObjects(io, db, pack_dir, request.wants, request.tips, request.include_tag, .{});
                const written = report orelse return .{ .pack = null, .objects = 0 };
                return .{ .pack = written.name, .objects = written.objects };
            },
            .smart => |*smart| {
                const result = try fetchpack.fetch(gpa, io, smart.conn, &smart.advertisement, db, pack_dir, request, options);
                return .{ .pack = result.name, .objects = result.objects };
            },
        }
    }
};
