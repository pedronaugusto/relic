//! git's dumb HTTP protocol: a repository served as plain files, as any
//! static host serves one (git 2.56's `remote-curl.c` `parse_info_refs` and
//! `fetch_dumb`, `http-walker.c`, `walker.c`).
//!
//! The refs are `info/refs`, a line per ref, and `HEAD`. A fetch walks from
//! what is wanted as git's walker does: a commit gives its tree and
//! parents, a tree its entries but gitlinks, a tag its target; an object
//! already here is read, not fetched, and what the local refs reach is
//! complete and stops the walk. Each missing object is asked for as a
//! loose file under `objects/`, inflated and named before it is kept; on a
//! 404 the server's alternates are read, once, and asked in turn; failing
//! that, the pack `objects/info/packs` names that holds it is downloaded
//! and indexed, at the repository and then at each alternate. Nothing is
//! pushed and no depth is taken, as git's dumb transport neither pushes
//! (git does over WebDAV) nor deepens.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const smart_http = @import("smart_http.zig");
const protocol = @import("protocol.zig");
const policy = @import("policy.zig");
const url_mod = @import("url.zig");
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const pack = @import("../odb/pack.zig");
const index_pack = @import("../odb/index_pack.zig");
const warning = @import("../report.zig").warning;
const warp = @import("warp");

const Oid = hash.Oid;
const RemoteRef = protocol.RemoteRef;

const ErrorNamespace = @This();

pub const Error = Own || smart_http.Error || odb_mod.Error || odb_mod.Odb.ReceiveError || pack.IndexError || object.Error;

const Own = error{
    /// `info/refs` is not git's listing: a line whose name is not that of
    /// the hash the first line's is, or a first line of no hash's length:
    /// git's "info/refs not valid".
    InvalidInfoRefs,
    /// A fetch asked for a depth, a date or an exclusion over dumb HTTP:
    /// git's "dumb http transport does not support shallow capabilities".
    DumbHttpShallow,
    /// An object the walk needs is under no URL the server names, loose or
    /// packed, at the repository or an alternate: git's "Unable to find
    /// <hex> under <url>". `Remote.missing` names it.
    ObjectMissing,
    /// The same, where a loose file the server sent for it did not inflate
    /// to it: git's "File <hex> corrupt" and "has bad hash" before that.
    CorruptObject,
};

/// A dumb server, its refs read.
pub const Remote = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    /// The repository's files.
    files: smart_http.Files,
    /// The repository's URL, as git names it in a message.
    url: []const u8,
    kind: hash.Kind,
    /// `HEAD` first when it resolves, then every line of `info/refs`.
    refs: []const RemoteRef,
    options: Options,
    /// The repository, then each alternate its files name, in order.
    bases: std.ArrayList(Base) = .empty,
    /// Whether the alternates were asked for: they are, once.
    alternates_read: bool = false,
    /// The object a fetch could not find.
    missing: ?Oid = null,

    /// What a remote reads besides its files: what an alternate may be.
    pub const Options = struct {
        pub const Error = ErrorNamespace.Error;

        /// The conversation's own, for an alternate's files.
        http: smart_http.Options = .{},
        /// What `protocol.<name>.allow` an alternate's scheme is checked
        /// against.
        policy: policy.Options = .{},
        warnings: ?*warning.Warnings = null,
    };

    const Base = struct {
        /// The base's URL, which its files' paths are under.
        url: []const u8,
        /// `null` for the repository's own, which `files` are.
        files: ?smart_http.Files,
        /// The packs `objects/info/packs` lists, each with its index, once
        /// read; a pack fetched is taken off.
        packs: ?std.ArrayList(Listed) = null,
    };

    const Listed = struct {
        name: []const u8,
        index: pack.Index,
    };

    /// The remote whose listing `files` holds. `HEAD` is asked for here,
    /// as git asks for it. Takes `files`.
    pub fn open(gpa: Allocator, io: Io, files: smart_http.Files, options: Options) Self.Error!*Remote {
        const r = gpa.create(Remote) catch |err| {
            var taken = files;
            taken.deinit(io);
            return err;
        };
        errdefer gpa.destroy(r);
        r.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .files = files,
            .url = undefined,
            .kind = undefined,
            .refs = &.{},
            .options = options,
        };
        errdefer r.arena.deinit();
        errdefer r.files.deinit(io);
        const a = r.arena.allocator();
        r.url = try files.baseUrl(a);
        const parsed = try parseRefs(a, files.listing);
        r.kind = parsed.kind;
        r.refs = parsed.refs;
        if (try r.head(io)) |head_ref| {
            const all = try a.alloc(RemoteRef, r.refs.len + 1);
            all[0] = head_ref;
            @memcpy(all[1..], r.refs);
            r.refs = all;
        }
        try r.bases.append(gpa, .{ .url = r.url, .files = null });
        return r;
    }

    const fetchObject = fetchObjectImpl;
    const loose = looseImpl;
    const fromPack = fromPackImpl;
    const readPacks = readPacksImpl;
    const readAlternates = readAlternatesImpl;
    const alternateAllowed = alternateAllowedImpl;
    const warn = warnImpl;
    const filesOf = filesOfImpl;

    pub fn deinit(r: *Remote, io: Io) void {
        const gpa = r.gpa;
        for (r.bases.items) |*base| {
            if (base.files) |*f| f.deinit(io);
            if (base.packs) |*list| {
                for (list.items) |*listed| listed.index.deinit();
                list.deinit(gpa);
            }
        }
        r.bases.deinit(gpa);
        r.files.deinit(io);
        r.arena.deinit();
        gpa.destroy(r);
    }

    /// git's `http_fetch_ref` of `HEAD`, resolved as `resolve_remote_symref`
    /// resolves it: `ref: <name>` against the listing, a bare name as it
    /// is. `null` when the request fails, or names what is not listed.
    fn head(r: *Remote, io: Io) Self.Error!?RemoteRef {
        _ = io;
        const a = r.arena.allocator();
        const body = (try r.files.get("/HEAD")) orelse return null;
        const raw = readWhole(a, body) catch |err| return switch (err) {
            error.ConnectionFailed => null,
            else => |e| e,
        };
        // git's `strbuf_rtrim`.
        const text = std.mem.trimEnd(u8, raw, " \t\n\r\x0b\x0c");
        if (text.len == r.kind.hexLen()) {
            const oid = Oid.parse(r.kind, text) catch return null;
            return .{ .name = "HEAD", .oid = oid };
        }
        if (std.mem.startsWith(u8, text, "ref: ")) {
            const target = text["ref: ".len..];
            for (r.refs) |ref| if (std.mem.eql(u8, ref.name, target)) {
                return .{ .name = "HEAD", .oid = ref.oid, .symref_target = target };
            };
        }
        return null;
    }

    /// The refs beginning with one of `prefixes`, or all when none are
    /// given. The list is the caller's.
    pub fn listRefs(r: *const Remote, gpa: Allocator, prefixes: []const []const u8) Allocator.Error!protocol.RefList {
        var list: protocol.RefList = .{ .arena = .init(gpa), .refs = &.{} };
        errdefer list.arena.deinit();
        const a = list.arena.allocator();
        var kept: std.ArrayList(RemoteRef) = .empty;
        for (r.refs) |ref| {
            if (prefixes.len != 0) {
                const wanted = for (prefixes) |prefix| {
                    if (std.mem.startsWith(u8, ref.name, prefix)) break true;
                } else false;
                if (!wanted) continue;
            }
            try kept.append(a, .{
                .name = try a.dupe(u8, ref.name),
                .oid = ref.oid,
                .symref_target = if (ref.symref_target) |t| try a.dupe(u8, t) else null,
            });
        }
        list.refs = try kept.toOwnedSlice(a);
        return list;
    }

    /// What a fetch brought.
    pub const Fetched = struct {
        pub const Error = ErrorNamespace.Error;

        /// Objects written loose.
        loose: u32 = 0,
        /// Packs downloaded and indexed.
        packs: u32 = 0,
    };

    /// Bring every object `wants` reaches that `db` lacks, short of what
    /// `tips` — the local refs — reach, as git's walker does.
    pub fn fetch(r: *Remote, io: Io, db: *odb_mod.Odb, wants: []const Oid, tips: []const Oid, receive: index_pack.Options) Self.Error!Fetched {
        var walk: Walk = .{ .r = r, .io = io, .db = db, .receive = receive };
        defer walk.deinit();
        for (tips) |tip| try walk.markComplete(tip);
        for (wants) |want| try walk.process(want);
        try walk.loop();
        return walk.fetched;
    }
};

/// The listing's refs and the hash they are written in, as git's
/// `parse_info_refs` reads them: the hash from the first line's length, no
/// refs a SHA-1 repository's, and every line `<hex>\t<name>\n`.
pub fn parseRefs(a: Allocator, listing: []const u8) (Allocator.Error || Own)!struct { kind: hash.Kind, refs: []const RemoteRef } {
    const kind: hash.Kind = if (std.mem.findScalar(u8, listing, '\t')) |tab| switch (tab) {
        40 => .sha1,
        64 => .sha256,
        else => return error.InvalidInfoRefs,
    } else .sha1;
    var refs: std.ArrayList(RemoteRef) = .empty;
    var start: usize = 0;
    // git keeps the last tab it saw, from this line or one before.
    var mid: ?usize = null;
    for (listing, 0..) |c, i| {
        if (c == '\t') mid = i;
        if (c != '\n') continue;
        const tab = mid orelse return error.InvalidInfoRefs;
        if (tab < start or tab - start != kind.hexLen()) return error.InvalidInfoRefs;
        // git reads the hex whatever it holds; a name that is not hex
        // cannot be fetched, which a fetch then says.
        const oid = Oid.parse(kind, listing[start..tab]) catch return error.InvalidInfoRefs;
        try refs.append(a, .{ .name = try a.dupe(u8, listing[tab + 1 .. i]), .oid = oid });
        start = i + 1;
    }
    return .{ .kind = kind, .refs = try refs.toOwnedSlice(a) };
}

/// git's walker over one fetch: the objects seen, the queue of those to
/// fetch or read, and the complete commits by date.
const Walk = struct {
    r: *Remote,
    io: Io,
    db: *odb_mod.Odb,
    receive: index_pack.Options,
    fetched: Remote.Fetched = .{},
    flags: std.HashMapUnmanaged(Oid, Flags, Oid.MapContext, std.hash_map.default_max_load_percentage) = .empty,
    queue: std.ArrayList(Oid) = .empty,
    head: usize = 0,
    /// The complete commits not yet popped, by committer date.
    complete: std.PriorityQueue(Dated, void, Dated.newerFirst) = .empty,

    const Flags = packed struct { seen: bool = false, complete: bool = false, scan: bool = false };

    const Dated = struct {
        oid: Oid,
        when: i64,

        fn newerFirst(_: void, a: Dated, b: Dated) std.math.Order {
            return std.math.order(b.when, a.when);
        }
    };

    fn deinit(w: *Walk) void {
        const gpa = w.r.gpa;
        w.flags.deinit(gpa);
        w.queue.deinit(gpa);
        w.complete.deinit(gpa);
    }

    fn flagsOf(w: *Walk, oid: Oid) Allocator.Error!*Flags {
        const got = try w.flags.getOrPut(w.r.gpa, oid);
        if (!got.found_existing) got.value_ptr.* = .{};
        return got.value_ptr;
    }

    /// git's `mark_complete`: a local ref's commit, a tag peeled to it.
    fn markComplete(w: *Walk, tip: Oid) Self.Error!void {
        var oid = tip;
        while (true) {
            const found = w.db.read(w.io, oid) catch |err| switch (err) {
                error.ObjectNotFound => return,
                else => |e| return e,
            };
            defer w.db.allocator().free(found.bytes);
            switch (found.type) {
                .tag => {
                    var tag = object.Tag.parse(w.r.gpa, w.r.kind, found.bytes) catch return;
                    defer tag.deinit();
                    oid = tag.target;
                },
                .commit => {
                    var commit = object.Commit.parse(w.r.gpa, w.r.kind, found.bytes) catch return;
                    defer commit.deinit();
                    const f = try w.flagsOf(oid);
                    if (f.complete) return;
                    f.complete = true;
                    try w.complete.push(w.r.gpa, .{ .oid = oid, .when = commit.committer.when_secs });
                    return;
                },
                else => return,
            }
        }
    }

    /// git's `process`: seen once; read when here, else fetched unless
    /// complete.
    fn process(w: *Walk, oid: Oid) Self.Error!void {
        const f = try w.flagsOf(oid);
        if (f.seen) return;
        f.seen = true;
        if (try w.db.exists(w.io, oid)) {
            f.scan = true;
        } else if (f.complete) return;
        try w.queue.append(w.r.gpa, oid);
    }

    fn loop(w: *Walk) Self.Error!void {
        while (w.head < w.queue.items.len) {
            const oid = w.queue.items[w.head];
            w.head += 1;
            const f = (try w.flagsOf(oid)).*;
            // git's `fetch_object` asks again: a pack fetched since may
            // have brought it.
            if (!f.scan and !try w.db.exists(w.io, oid)) try w.r.fetchObject(w.io, w.db, oid, w.receive, &w.fetched);
            try w.processObject(oid);
        }
    }

    fn processObject(w: *Walk, oid: Oid) Self.Error!void {
        const header = try w.db.readHeader(w.io, oid);
        if (header.type == .blob) return;
        const found = try w.db.read(w.io, oid);
        defer w.db.allocator().free(found.bytes);
        const gpa = w.r.gpa;
        switch (found.type) {
            .commit => {
                var commit = try object.Commit.parse(gpa, w.r.kind, found.bytes);
                defer commit.deinit();
                try w.popComplete(commit.committer.when_secs);
                if ((try w.flagsOf(oid)).complete) return;
                try w.process(commit.tree);
                for (commit.parents) |parent| try w.process(parent);
            },
            .tree => {
                var it = object.Tree.parse(w.r.kind, found.bytes).iterate();
                while (try it.next()) |entry| {
                    // A submodule's commit is not the superproject's.
                    if (entry.mode == .gitlink) continue;
                    try w.process(entry.oid);
                }
            },
            .tag => {
                var tag = try object.Tag.parse(gpa, w.r.kind, found.bytes);
                defer tag.deinit();
                try w.process(tag.target);
            },
            .blob => {},
        }
    }

    /// git's loop over `pop_most_recent_commit`: every complete commit as
    /// new as `when` is popped, its parents marked complete in its place.
    fn popComplete(w: *Walk, when: i64) Self.Error!void {
        while (w.complete.peek()) |top| {
            if (top.when < when) break;
            _ = w.complete.pop();
            const found = w.db.read(w.io, top.oid) catch |err| switch (err) {
                error.ObjectNotFound => continue,
                else => |e| return e,
            };
            defer w.db.allocator().free(found.bytes);
            var commit = object.Commit.parse(w.r.gpa, w.r.kind, found.bytes) catch continue;
            defer commit.deinit();
            for (commit.parents) |parent| {
                const pf = try w.flagsOf(parent);
                if (pf.complete) continue;
                const parent_found = w.db.read(w.io, parent) catch |err| switch (err) {
                    error.ObjectNotFound => continue,
                    else => |e| return e,
                };
                defer w.db.allocator().free(parent_found.bytes);
                var parent_commit = object.Commit.parse(w.r.gpa, w.r.kind, parent_found.bytes) catch continue;
                defer parent_commit.deinit();
                pf.complete = true;
                try w.complete.push(w.r.gpa, .{ .oid = parent, .when = parent_commit.committer.when_secs });
            }
        }
    }
};

const Self = ErrorNamespace;

/// A body read whole, as git reads these files; a body cut short is the
/// connection's failure.
fn readWhole(a: Allocator, body: *Io.Reader) Self.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    body.appendRemainingUnlimited(a, &list) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => error.ConnectionFailed,
    };
    return list.toOwnedSlice(a);
}

/// What a loose request came to.
const Loose = enum { written, missing, corrupt };

fn fetchObjectImpl(r: *Remote, io: Io, db: *odb_mod.Odb, oid: Oid, receive: index_pack.Options, fetched: *Remote.Fetched) Self.Error!void {
    // Loose, at the repository and on a 404 at each alternate in turn.
    var corrupt = false;
    var i: usize = 0;
    while (i < r.bases.items.len) : (i += 1) {
        switch (try r.loose(io, db, i, oid)) {
            .written => {
                fetched.loose += 1;
                return;
            },
            .missing => try r.readAlternates(io),
            .corrupt => {
                corrupt = true;
                break;
            },
        }
    }
    // Packed, at each base in turn, the alternates read after the first.
    i = 0;
    while (i < r.bases.items.len) : (i += 1) {
        if (try r.fromPack(io, db, i, oid, receive)) {
            fetched.packs += 1;
            return;
        }
        try r.readAlternates(io);
    }
    r.missing = oid;
    return if (corrupt) error.CorruptObject else error.ObjectMissing;
}

fn filesOfImpl(r: *Remote, i: usize) *smart_http.Files {
    const base = &r.bases.items[i];
    return if (base.files) |*f| f else &r.files;
}

/// `objects/xx/yyyy…` at base `i`, inflated and named as it is written
/// (git's `http_object_request`).
fn looseImpl(r: *Remote, io: Io, db: *odb_mod.Odb, i: usize, oid: Oid) Self.Error!Loose {
    var hex_buf: [hash.max_hex_len]u8 = undefined;
    const hex = oid.hex(&hex_buf);
    // `/objects/xx/yyyy…`.
    var path_buf: ["/objects/".len + 1 + hash.max_hex_len]u8 = undefined;
    @memcpy(path_buf[0.."/objects/".len], "/objects/");
    @memcpy(path_buf["/objects/".len..][0..2], hex[0..2]);
    path_buf["/objects/".len + 2] = '/';
    @memcpy(path_buf["/objects/".len + 3 ..][0 .. hex.len - 2], hex[2..]);
    const path = path_buf[0 .. "/objects/".len + 1 + hex.len];
    const body = (try r.filesOf(i).get(path)) orelse return .missing;
    var window: [(1 << 15) + 4096]u8 = undefined;
    var inflate: warp.Inflate.Reader = .init(body, &window, .{});
    const in = &inflate.interface;
    // The header: `<type> <size>\0`.
    var header_buf: [32]u8 = undefined;
    var header_len: usize = 0;
    for (&header_buf) |*slot| {
        const c = in.takeByte() catch return .corrupt;
        slot.* = c;
        header_len += 1;
        if (c == 0) break;
    } else return .corrupt;
    const parsed = object.parseHeader(header_buf[0..header_len]) catch return .corrupt;
    const t = parsed.header.type;
    const size = parsed.header.size;
    var stream: odb_mod.ObjectStream = undefined;
    try db.writeStream(io, t, size, &stream);
    stream.expected = oid;
    var finished = false;
    defer if (!finished) stream.abort(io) else stream.deinit(io);
    var remaining = size;
    while (remaining != 0) {
        try io.checkCancel();
        const chunk = in.peekGreedy(1) catch return .corrupt;
        const n: usize = @intCast(@min(chunk.len, remaining));
        try stream.write(chunk[0..n]);
        in.toss(n);
        remaining -= n;
    }
    // Nothing may follow the object in its stream.
    if (in.takeByte()) |_| return .corrupt else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return .corrupt,
    }
    _ = stream.finish(io) catch |err| switch (err) {
        error.ObjectNameMismatch => return .corrupt,
        else => |e| return e,
    };
    finished = true;
    return .written;
}

/// The pack at base `i` that holds `oid`, downloaded and indexed through
/// index-pack, as git's `http_fetch_pack`; `false` when no pack there
/// holds it.
fn fromPackImpl(r: *Remote, io: Io, db: *odb_mod.Odb, i: usize, oid: Oid, receive: index_pack.Options) Self.Error!bool {
    try r.readPacks(io, i);
    const list = &r.bases.items[i].packs.?;
    const at = for (list.items, 0..) |listed, n| {
        if (try listed.index.find(oid) != null) break n;
    } else return false;
    var listed = list.orderedRemove(at);
    defer listed.index.deinit();
    const path = try std.mem.concat(r.arena.allocator(), u8, &.{ "/objects/pack/", listed.name, ".pack" });
    const body = (try r.filesOf(i).get(path)) orelse return false;
    var received = try db.receivePack(io, body, receive);
    // git's `index-pack --stdin` keeps nothing.
    if (received.keep) |*token| token.deinit(io);
    // The walk asks for what the pack holds next: it is to be found.
    try db.refresh(io);
    return true;
}

/// `objects/info/packs` at base `i`, once, and the index of each pack it
/// names, verified (git's `fetch_indices`). A 404 lists none.
fn readPacksImpl(r: *Remote, io: Io, i: usize) Self.Error!void {
    _ = io;
    if (r.bases.items[i].packs != null) return;
    var list: std.ArrayList(Remote.Listed) = .empty;
    errdefer {
        for (list.items) |*listed| listed.index.deinit();
        list.deinit(r.gpa);
    }
    const a = r.arena.allocator();
    const files = r.filesOf(i);
    const text = if (try files.get("/objects/info/packs")) |body| try readWhole(a, body) else "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // git's `parse_info_packs`: `P pack-<hex>.pack`.
        if (!std.mem.startsWith(u8, line, "P pack-") or !std.mem.endsWith(u8, line, ".pack")) continue;
        const name = line["P ".len .. line.len - ".pack".len];
        if (name.len != "pack-".len + r.kind.hexLen()) continue;
        const path = try std.mem.concat(a, u8, &.{ "/objects/pack/", name, ".idx" });
        const body = (try files.get(path)) orelse continue;
        const bytes = try readWhole(r.gpa, body);
        const index = pack.Index.parse(r.gpa, r.kind, bytes) catch |err| {
            r.gpa.free(bytes);
            return err;
        };
        try list.append(r.gpa, .{ .name = try a.dupe(u8, name), .index = index });
    }
    r.bases.items[i].packs = list;
}

/// The alternates the repository names, once: `objects/info/http-alternates`,
/// else `objects/info/alternates`, as git's `fetch_alternates` reads them.
fn readAlternatesImpl(r: *Remote, io: Io) Self.Error!void {
    if (r.alternates_read) return;
    r.alternates_read = true;
    const a = r.arena.allocator();
    var http_specific = true;
    var text: []const u8 = "";
    // A request that fails, or an empty file, moves on to `alternates`.
    if (r.files.get("/objects/info/http-alternates")) |found| {
        if (found) |body| text = readWhole(a, body) catch |err| switch (err) {
            error.ConnectionFailed => "",
            else => |e| return e,
        };
    } else |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => {},
    }
    if (text.len == 0) {
        http_specific = false;
        const body = (try r.files.get("/objects/info/alternates")) orelse return;
        text = readWhole(a, body) catch |err| switch (err) {
            error.ConnectionFailed => return,
            else => |e| return e,
        };
    }
    const base = r.url;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_with_rest| {
        // git reads only lines that end in a newline.
        if (lines.index == null and !std.mem.endsWith(u8, text, "\n")) break;
        var line = line_with_rest;
        var server_len: usize = 0;
        var okay = false;
        if (std.mem.startsWith(u8, line, "/")) {
            // The same server, this path on it.
            if (std.mem.find(u8, base, "://")) |colon_ss| {
                server_len = std.mem.findScalarPos(u8, base, colon_ss + 3, '/') orelse base.len;
                okay = true;
            }
        } else if (std.mem.startsWith(u8, line, "../")) {
            // One more `../` than paths dropped from the base: borrowing
            // from a neighbour takes `../../`.
            line = line[3..];
            server_len = base.len;
            while (line.len > 2 and std.mem.startsWith(u8, line, "../")) {
                server_len -|= 1;
                while (server_len != 0 and base[server_len - 1] != '/') server_len -= 1;
                line = line[3..];
            }
            const colon = std.mem.findScalar(u8, base, ':') orelse 0;
            // If the server got removed, give up.
            okay = colon + 3 < server_len;
        } else if (http_specific) {
            const colon = std.mem.findScalar(u8, line, ':');
            const slash = std.mem.findScalar(u8, line, '/');
            okay = colon != null and slash != null and colon.? < slash.?;
        }
        if (!okay) continue;
        const target = try std.mem.concat(a, u8, &.{ base[0..server_len], line });
        if (!std.mem.endsWith(u8, target, "objects")) {
            try r.warn("ignoring alternate that does not end in 'objects': {s}", .{target});
            continue;
        }
        const alt = target[0 .. target.len - "objects".len];
        if (!try r.alternateAllowed(alt)) continue;
        try r.warn("adding alternate object store: {s}", .{alt});
        const parsed = url_mod.Url.parse(alt) catch continue;
        const files = try smart_http.Files.open(r.gpa, io, parsed, r.options.http);
        errdefer {
            var f = files;
            f.deinit(io);
        }
        try r.bases.append(r.gpa, .{ .url = std.mem.trimEnd(u8, alt, "/"), .files = files });
    }
}

/// git's `is_alternate_allowed`: only under `http.followRedirects=true`,
/// and only over a transport `protocol.allow` lets an alternate use. ftp
/// and ftps, which git reaches through curl, relic does not speak.
fn alternateAllowedImpl(r: *Remote, alt: []const u8) Self.Error!bool {
    if (r.files.h.follow_redirects != .always) {
        try r.warn("alternate disabled by http.followRedirects: {s}", .{alt});
        return false;
    }
    const scheme = for ([_][]const u8{ "http", "https", "ftp", "ftps" }) |name| {
        if (std.mem.startsWith(u8, alt, name) and std.mem.startsWith(u8, alt[name.len..], "://")) break name;
    } else {
        try r.warn("ignoring alternate with unknown protocol: {s}", .{alt});
        return false;
    };
    var from = r.options.policy;
    from.from_user = false;
    if (!policy.allowed(scheme, from)) {
        try r.warn("ignoring alternate with restricted protocol: {s}", .{alt});
        return false;
    }
    if (scheme[0] == 'f') {
        try r.warn("ignoring alternate over {s}, which relic does not speak: {s}", .{ scheme, alt });
        return false;
    }
    return true;
}

fn warnImpl(r: *Remote, comptime format: []const u8, args: anytype) Allocator.Error!void {
    const to = r.options.warnings orelse return;
    try warning.note(to, .{ .dumb_alternate = try r.arena.allocator().print(format, args) });
}
