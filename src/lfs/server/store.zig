//! Where an LFS server keeps its objects, and what a request may do to
//! them: what the HTTP backend (`../server.zig`) and git-lfs's pure-ssh
//! protocol (`server/transfer.zig`) serve alike. `lfs.server` names them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const aegis = @import("aegis");
const uplink = @import("uplink");
const decimal = @import("../../text.zig").decimal;
const date = @import("../../text.zig").date;
const fs = @import("../../fs/fs.zig");
const lfs = @import("../lfs.zig");
const lfsapi = @import("../api.zig");

/// What a request asks to do.
pub const Access = enum {
    /// Read objects, list locks.
    download,
    /// Write objects; take, verify and give back locks.
    upload,
    /// Give back a lock someone else holds. Asked after `upload`.
    force_unlock,
};

/// Where the objects are kept. The backend asks it whether it has an
/// object and at what size, and then either for a link the client follows
/// to the store itself (`link`), or to carry the object's bytes (`read`,
/// `write`); a store gives one or the other.
pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// Errors a store reports. One the backend cannot place is
    /// `LfsStoreFailed`; an upload that is not the object it named is
    /// `LfsObjectMismatch`.
    pub const Error = error{ LfsStoreFailed, LfsObjectMismatch } || Allocator.Error || Io.Cancelable;

    pub const VTable = struct {
        /// The size of the object `oid` in `repository`'s objects, or
        /// `null` when there is none.
        size: *const fn (context: *anyopaque, io: Io, repository: []const u8, oid: *const [64]u8) Store.Error!?u64,
        /// Where the client goes to move `pointer` for `operation`, in
        /// `arena`.
        link: ?*const fn (context: *anyopaque, io: Io, arena: Allocator, repository: []const u8, operation: lfsapi.Operation, pointer: *const lfs.Pointer) Store.Error!Link = null,
        /// Write the object, which the store holds at `pointer.size`, to
        /// `w`; `false` when it does not hold it.
        read: ?*const fn (context: *anyopaque, io: Io, repository: []const u8, pointer: *const lfs.Pointer, w: *Io.Writer) Store.Error!bool = null,
        /// Keep what `r` holds to its end as `pointer`'s object, when that
        /// is what it is.
        write: ?*const fn (context: *anyopaque, io: Io, repository: []const u8, pointer: *const lfs.Pointer, r: *Io.Reader) Store.Error!void = null,
    };

    pub fn size(s: Store, io: Io, repository: []const u8, oid: *const [64]u8) Store.Error!?u64 {
        return s.vtable.size(s.context, io, repository, oid);
    }
};

/// A store in a directory: each repository's objects under
/// `<directory>/<repository>/objects/<aa>/<bb>/<oid>`, as git-lfs lays out
/// its own, carried through the backend. An upload goes into `tmp` beside
/// them and is kept only when its SHA-256 and length are the ones it was
/// sent for.
pub const Directory = struct {
    /// Borrowed.
    dir: Io.Dir,
    /// The permissions the directories and objects are made with.
    shared: fs.Shared = .umask,

    pub fn store(d: *Directory) Store {
        return .{ .context = d, .vtable = &.{ .size = size, .read = read, .write = write } };
    }

    fn of(d: *const Directory, repository: []const u8) lfs.Store {
        return .{ .base = d.dir, .root = repository, .shared = d.shared };
    }

    fn size(context: *anyopaque, io: Io, repository: []const u8, oid: *const [64]u8) Store.Error!?u64 {
        const d: *Directory = @ptrCast(@alignCast(context)); // aegis: no-danger(A019): the context is the Directory `store` was made from
        var buf: [lfs.Store.max_path]u8 = undefined;
        const path = d.of(repository).objectPath(&buf, oid) catch return null;
        const stat = d.dir.statFile(io, path, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.FileNotFound, error.NotDir => return null,
            else => return error.LfsStoreFailed,
        };
        return if (stat.kind == .file) stat.size else null;
    }

    fn read(context: *anyopaque, io: Io, repository: []const u8, pointer: *const lfs.Pointer, w: *Io.Writer) Store.Error!bool {
        const d: *Directory = @ptrCast(@alignCast(context)); // aegis: no-danger(A019): the context is the Directory `store` was made from
        var owned = (d.of(repository).open(io, pointer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.LfsStoreFailed,
        }) orelse return false;
        defer owned.deinit(io);
        const file = owned.lend().get();
        var buf: [64 * 1024]u8 = undefined;
        var r = file.reader(io, &buf);
        _ = r.interface.streamRemaining(w) catch |err| switch (err) {
            error.ReadFailed => return if (r.err) |e| switch (e) {
                error.Canceled => error.Canceled,
                else => error.LfsStoreFailed,
            } else error.LfsStoreFailed,
            error.WriteFailed => return error.LfsStoreFailed,
        };
        return true;
    }

    fn write(context: *anyopaque, io: Io, repository: []const u8, pointer: *const lfs.Pointer, r: *Io.Reader) Store.Error!void {
        const d: *Directory = @ptrCast(@alignCast(context)); // aegis: no-danger(A019): the context is the Directory `store` was made from
        _ = d.of(repository).install(io, r, pointer) catch |err| switch (err) {
            error.LfsObjectMismatch => return error.LfsObjectMismatch,
            error.Canceled => return error.Canceled,
            else => return error.LfsStoreFailed,
        };
    }
};

/// A store in S3-compatible object storage: each repository's objects at
/// `<prefix><repository>/<aa>/<bb>/<oid>` in a bucket. The client moves
/// them straight to and from the storage, through URLs it signed (AWS
/// Signature Version 4, uplink's `wire.sigv4`) for `expires` seconds; the
/// backend asks the storage whether it has one with a signed `HEAD` through
/// the caller's uplink client. Links are signed at the time the system's
/// clock says, which the storage checks them against.
pub const S3 = struct {
    gpa: Allocator,
    /// Borrowed.
    client: *uplink.Client,
    /// Where the storage is: `https://s3.us-east-1.amazonaws.com`,
    /// `http://127.0.0.1:9000`.
    endpoint: []const u8,
    bucket: []const u8,
    /// Before every key, `/` included when it is wanted: `lfs/`.
    prefix: []const u8 = "",
    /// The bucket in the path, which every S3-compatible server takes, or
    /// in the host, as AWS names a bucket.
    addressing: Addressing = .path,
    signer: uplink.wire.sigv4.Signer,
    /// How long a link works.
    expires: aegis.units.Duration(.second, u32) = .fromRaw(3600),

    pub const Addressing = enum { path, virtual_host };

    pub fn store(s: *S3) Store {
        return .{ .context = s, .vtable = &.{ .size = size, .link = link } };
    }

    /// The object's URL, unsigned, in `arena`.
    pub fn objectUrl(s: *const S3, arena: Allocator, repository: []const u8, oid: *const [64]u8) Allocator.Error![]const u8 {
        var out: Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const endpoint = std.mem.trimEnd(u8, s.endpoint, "/");
        writeUrl(w, s, endpoint, repository, oid) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeUrl(w: *Io.Writer, s: *const S3, endpoint: []const u8, repository: []const u8, oid: *const [64]u8) Io.Writer.Error!void {
        switch (s.addressing) {
            .path => {
                try w.writeAll(endpoint);
                try w.writeByte('/');
                try encodeKey(w, s.bucket);
            },
            .virtual_host => {
                const authority = (std.mem.find(u8, endpoint, "://") orelse 0) + "://".len;
                try w.writeAll(endpoint[0..authority]);
                try w.print("{s}.{s}", .{ s.bucket, endpoint[authority..] });
            },
        }
        try w.writeByte('/');
        try encodeKey(w, s.prefix);
        try encodeKey(w, repository);
        try w.print("/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], oid });
    }

    fn now(io: Io) i64 {
        return date.seconds(Io.Clock.real.now(io));
    }

    fn size(context: *anyopaque, io: Io, repository: []const u8, oid: *const [64]u8) Store.Error!?u64 {
        const s: *S3 = @ptrCast(@alignCast(context)); // aegis: no-danger(A019): the context is the S3 `store` was made from
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const url = try s.objectUrl(arena_state.allocator(), repository, oid);
        const parsed = uplink.wire.url.parse(url) catch return error.LfsStoreFailed;
        var signed: uplink.wire.sigv4.Signed = undefined;
        s.signer.sign(.{ .method = "HEAD", .url = parsed, .payload = uplink.wire.sigv4.empty_payload }, now(io), &signed) catch
            return error.LfsStoreFailed;
        var fields_buffer: [4]std.http.Header = undefined;
        var response = s.client.send(io, .{ .method = .HEAD, .url = url, .headers = signed.headers(&fields_buffer) }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.LfsStoreFailed,
        };
        defer response.deinit(io);
        return switch (response.status) {
            .ok => decimal.digits(u64, response.headers.get("content-length") orelse return error.LfsStoreFailed) orelse error.LfsStoreFailed,
            .not_found => null,
            else => error.LfsStoreFailed,
        };
    }

    fn link(context: *anyopaque, io: Io, arena: Allocator, repository: []const u8, operation: lfsapi.Operation, pointer: *const lfs.Pointer) Store.Error!Link {
        const s: *S3 = @ptrCast(@alignCast(context)); // aegis: no-danger(A019): the context is the S3 `store` was made from
        const url = try s.objectUrl(arena, repository, &pointer.oid);
        const parsed = uplink.wire.url.parse(url) catch return error.LfsStoreFailed;
        var out: Io.Writer.Allocating = .init(arena);
        const method = switch (operation) {
            .download => "GET",
            .upload => "PUT",
        };
        s.signer.presign(&out.writer, url, .{ .method = method, .url = parsed }, now(io), s.expires.raw()) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return error.LfsStoreFailed,
        };
        return .{ .href = out.written(), .expires_in = s.expires.raw() };
    }
};

/// A key's bytes as a URL's path carries them: unreserved bytes and `/`
/// as they are, every other `%XX`, as S3 signs it.
fn encodeKey(w: *Io.Writer, key: []const u8) Io.Writer.Error!void {
    for (key) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try w.writeByte(byte),
        else => try w.print("%{X:0>2}", .{byte}),
    };
}

/// An action a store hands out: a URL, the headers to send with it, and
/// how many seconds it works for (0: no end said).
pub const Link = struct {
    href: []const u8,
    header: lfsapi.HeaderMap = .{ .items = &.{} },
    expires_in: i64 = 0,
};
