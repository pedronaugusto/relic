//! What a git server says first, and how its refs are asked for.
//!
//! A server speaks one of two dialects. Protocol v2 opens with
//! `version 2` and a list of capabilities, and nothing else until it is
//! asked; refs are a command, `ls-refs`, that can be narrowed to the
//! prefixes a fetch needs. Protocols v0 and v1 open by listing every ref at
//! once, the first line carrying the capabilities after a NUL, peeled tags
//! as `<name>^{}` lines and the symbolic refs as `symref=` capabilities.
//! relic asks for v2 and reads whichever it is given, which is how git falls
//! back to a server that predates v2 — and it is the only dialect
//! `git-receive-pack` has.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const pktline = @import("pktline.zig");
const connection = @import("connection.zig");

const Oid = hash.Oid;
const Connection = connection.Connection;

/// What relic calls itself in an `agent` capability.
pub const agent = "relic/0.3";

/// Which dialect the server opened in.
pub const Version = enum { v0, v1, v2 };

/// Errors from the opening message and from listing refs.
pub const Error = error{
    /// `version <n>` for an `n` this release does not speak.
    UnsupportedProtocolVersion,
    /// The server's objects are named with a hash this repository does not
    /// use. git refuses the same mismatch.
    ObjectFormatMismatch,
    /// An `object-format` this release has no hash for.
    UnknownObjectFormat,
} || connection.Error;

/// One ref the server has.
pub const RemoteRef = struct {
    name: []const u8,
    /// The object it names; zero for an unborn ref.
    oid: Oid,
    /// The ref it points at, for a symbolic ref such as `HEAD`.
    symref_target: ?[]const u8 = null,
    /// The object an annotated tag peels to.
    peeled: ?Oid = null,
    /// A symbolic ref whose target does not exist yet: `HEAD` in an empty
    /// repository.
    unborn: bool = false,
};

/// The server's opening message.
pub const Advertisement = struct {
    arena: std.heap.ArenaAllocator,
    version: Version,
    /// Each capability as advertised: `name` or `name=value`.
    capabilities: []const []const u8,
    /// Every ref, in the order advertised. Only v0 and v1 list them here;
    /// v2 lists them on request.
    refs: []const RemoteRef,
    /// The hash the server's object names are written with.
    kind: hash.Kind,

    /// Release everything.
    pub fn deinit(adv: *Advertisement) void {
        adv.arena.deinit();
        adv.* = undefined;
    }

    /// Whether the server advertised `name`, with or without a value.
    pub fn has(adv: *const Advertisement, name: []const u8) bool {
        return adv.value(name) != null;
    }

    /// The value of a `name=value` capability, empty for a bare `name`, or
    /// `null` when it is not advertised. The last one wins when a
    /// capability is advertised twice.
    pub fn value(adv: *const Advertisement, name: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (adv.capabilities) |cap| {
            if (std.mem.eql(u8, cap, name)) {
                found = "";
            } else if (cap.len > name.len and std.mem.startsWith(u8, cap, name) and cap[name.len] == '=') {
                found = cap[name.len + 1 ..];
            }
        }
        return found;
    }

    /// Whether a v2 command advertises `feature` among its values:
    /// `fetch=shallow wait-for-done` has `shallow`.
    pub fn commandHas(adv: *const Advertisement, command: []const u8, feature: []const u8) bool {
        const features = adv.value(command) orelse return false;
        var it = std.mem.tokenizeScalar(u8, features, ' ');
        while (it.next()) |f| {
            if (std.mem.eql(u8, f, feature)) return true;
        }
        return false;
    }

    /// Every `symref=<name>:<target>` a v0 server advertised, as pairs.
    fn symrefTarget(adv: *const Advertisement, name: []const u8) ?[]const u8 {
        for (adv.capabilities) |cap| {
            const rest = if (std.mem.startsWith(u8, cap, "symref=")) cap["symref=".len..] else continue;
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            if (std.mem.eql(u8, rest[0..colon], name)) return rest[colon + 1 ..];
        }
        return null;
    }
};

/// Read the server's opening message from `conn`.
///
/// `kind` is the hash of the repository on this side, or `null` for one
/// that does not exist yet — a clone takes whatever the server has.
pub fn readAdvertisement(gpa: Allocator, conn: *Connection, kind: ?hash.Kind) Error!Advertisement {
    var adv: Advertisement = .{
        .arena = .init(gpa),
        .version = .v0,
        .capabilities = &.{},
        .refs = &.{},
        .kind = .sha1,
    };
    errdefer adv.arena.deinit();
    const arena = adv.arena.allocator();
    const in = try conn.advertisement();

    var capabilities: std.ArrayList([]const u8) = .empty;
    var refs: std.ArrayList(RemoteRef) = .empty;
    var first = true;
    var saw_format = false;
    while (true) {
        const packet = try conn.readPacket(in);
        const data = switch (packet) {
            .flush => break,
            .delim, .response_end => return error.ProtocolError,
            .data => |d| std.mem.trimEnd(u8, d, "\n"),
        };
        if (std.mem.startsWith(u8, data, "ERR ")) {
            conn.setMessage(data[4..]);
            return error.RemoteError;
        }
        if (first and std.mem.startsWith(u8, data, "version ")) {
            first = false;
            const number = data["version ".len..];
            if (std.mem.eql(u8, number, "2")) {
                adv.version = .v2;
            } else if (std.mem.eql(u8, number, "1")) {
                adv.version = .v1;
            } else return error.UnsupportedProtocolVersion;
            continue;
        }
        if (adv.version == .v2) {
            try capabilities.append(arena, try arena.dupe(u8, data));
            continue;
        }
        // v0 and v1: `<oid> <name>`, the first with its capabilities after
        // a NUL.
        var line = data;
        if (first or (refs.items.len == 0 and capabilities.items.len == 0)) {
            if (std.mem.indexOfScalar(u8, line, 0)) |nul| {
                var it = std.mem.tokenizeScalar(u8, line[nul + 1 ..], ' ');
                while (it.next()) |cap| try capabilities.append(arena, try arena.dupe(u8, cap));
                line = line[0..nul];
                for (capabilities.items) |cap| {
                    if (std.mem.startsWith(u8, cap, "object-format=")) {
                        adv.kind = hash.Kind.parse(cap["object-format=".len..]) catch return error.UnknownObjectFormat;
                        saw_format = true;
                    }
                }
            }
        }
        first = false;
        if (std.mem.startsWith(u8, line, "shallow ")) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.ProtocolError;
        const oid = Oid.parse(adv.kind, line[0..space]) catch return error.ProtocolError;
        const name = line[space + 1 ..];
        if (std.mem.eql(u8, name, "capabilities^{}")) continue;
        if (std.mem.endsWith(u8, name, "^{}")) {
            if (refs.items.len == 0) return error.ProtocolError;
            const last = &refs.items[refs.items.len - 1];
            if (!std.mem.eql(u8, last.name, name[0 .. name.len - 3])) return error.ProtocolError;
            last.peeled = oid;
            continue;
        }
        try refs.append(arena, .{ .name = try arena.dupe(u8, name), .oid = oid });
    }
    adv.capabilities = capabilities.items;
    if (adv.version == .v2) {
        if (adv.value("object-format")) |format| {
            adv.kind = hash.Kind.parse(format) catch return error.UnknownObjectFormat;
            saw_format = true;
        }
    }
    // Without `object-format` the server is SHA-1, which is what it was
    // before the capability existed.
    if (!saw_format) adv.kind = .sha1;
    if (kind) |local| {
        if (local != adv.kind) return error.ObjectFormatMismatch;
    }
    for (refs.items) |*ref| {
        if (adv.symrefTarget(ref.name)) |target| ref.symref_target = target;
    }
    adv.refs = refs.items;
    return adv;
}

/// A server's refs, as `listRefs` returns them.
pub const RefList = struct {
    arena: std.heap.ArenaAllocator,
    refs: []const RemoteRef,

    /// Release everything.
    pub fn deinit(list: *RefList) void {
        list.arena.deinit();
        list.* = undefined;
    }

    /// The ref named exactly `name`, or `null`.
    pub fn find(list: *const RefList, name: []const u8) ?RemoteRef {
        for (list.refs) |ref| {
            if (std.mem.eql(u8, ref.name, name)) return ref;
        }
        return null;
    }
};

/// What `listRefs` asks for.
pub const ListOptions = struct {
    /// Only refs beginning with one of these; empty asks for every ref.
    prefixes: []const []const u8 = &.{},
};

/// The refs the server has, asking with `ls-refs` under v2 and taking them
/// from the advertisement under v0 and v1.
pub fn listRefs(gpa: Allocator, conn: *Connection, adv: *const Advertisement, options: ListOptions) Error!RefList {
    var list: RefList = .{ .arena = .init(gpa), .refs = &.{} };
    errdefer list.arena.deinit();
    const arena = list.arena.allocator();
    var refs: std.ArrayList(RemoteRef) = .empty;

    if (adv.version != .v2) {
        for (adv.refs) |ref| {
            if (!matchesPrefix(ref.name, options.prefixes)) continue;
            try refs.append(arena, .{
                .name = try arena.dupe(u8, ref.name),
                .oid = ref.oid,
                .symref_target = if (ref.symref_target) |t| try arena.dupe(u8, t) else null,
                .peeled = ref.peeled,
            });
        }
        // A v0 server lists no unborn `HEAD`, but says where it points.
        if (adv.symrefTarget("HEAD")) |target| {
            var listed = false;
            for (refs.items) |ref| {
                if (std.mem.eql(u8, ref.name, "HEAD")) listed = true;
            }
            if (!listed and matchesPrefix("HEAD", options.prefixes)) {
                try refs.append(arena, .{ .name = "HEAD", .oid = .zero(adv.kind), .symref_target = try arena.dupe(u8, target), .unborn = true });
            }
        }
        list.refs = refs.items;
        return list;
    }

    const w = try conn.request();
    writeCommand(w, adv, "ls-refs") catch |err| return conn.writeFailed(err);
    const unborn = adv.commandHas("ls-refs", "unborn");
    (struct {
        fn args(out: *Io.Writer, prefixes: []const []const u8, want_unborn: bool) !void {
            try pktline.write(out, "peel\n");
            try pktline.write(out, "symrefs\n");
            if (want_unborn) try pktline.write(out, "unborn\n");
            for (prefixes) |prefix| try pktline.print(out, "ref-prefix {s}\n", .{prefix});
            try pktline.flush(out);
        }
    }).args(w, options.prefixes, unborn) catch |err| return conn.writeFailed(err);

    const in = try conn.response();
    while (true) {
        const packet = try conn.readPacket(in);
        const data = switch (packet) {
            .flush, .response_end => break,
            .delim => return error.ProtocolError,
            .data => |d| std.mem.trimEnd(u8, d, "\n"),
        };
        if (std.mem.startsWith(u8, data, "ERR ")) {
            conn.setMessage(data[4..]);
            return error.RemoteError;
        }
        try refs.append(arena, try parseLsRefsLine(arena, adv.kind, data));
    }
    list.refs = refs.items;
    return list;
}

/// One line of an `ls-refs` response:
/// `<oid> <name>[ symref-target:<target>][ peeled:<oid>]`, or
/// `unborn <name>[ symref-target:<target>]`.
pub fn parseLsRefsLine(arena: Allocator, kind: hash.Kind, line: []const u8) (Allocator.Error || error{ProtocolError})!RemoteRef {
    var it = std.mem.splitScalar(u8, line, ' ');
    const first = it.next() orelse return error.ProtocolError;
    const name = it.next() orelse return error.ProtocolError;
    if (name.len == 0) return error.ProtocolError;
    var ref: RemoteRef = .{ .name = try arena.dupe(u8, name), .oid = .zero(kind) };
    if (std.mem.eql(u8, first, "unborn")) {
        ref.unborn = true;
    } else {
        ref.oid = Oid.parse(kind, first) catch return error.ProtocolError;
    }
    while (it.next()) |attribute| {
        if (std.mem.startsWith(u8, attribute, "symref-target:")) {
            ref.symref_target = try arena.dupe(u8, attribute["symref-target:".len..]);
        } else if (std.mem.startsWith(u8, attribute, "peeled:")) {
            ref.peeled = Oid.parse(kind, attribute["peeled:".len..]) catch return error.ProtocolError;
        }
    }
    return ref;
}

fn matchesPrefix(name: []const u8, prefixes: []const []const u8) bool {
    if (prefixes.len == 0) return true;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

/// The head of a v2 command: `command=<name>`, the capabilities this side
/// sends back, and the delimiter before the arguments.
pub fn writeCommand(w: *Io.Writer, adv: *const Advertisement, command: []const u8) pktline.WriteError!void {
    // As git writes them: `ls-refs` with a newline, `fetch` without (they
    // are two functions in git), the capabilities without, the arguments
    // with.
    if (std.mem.eql(u8, command, "ls-refs")) {
        try pktline.print(w, "command={s}\n", .{command});
    } else try pktline.print(w, "command={s}", .{command});
    if (adv.has("agent")) try pktline.print(w, "agent={s}", .{agent});
    if (adv.has("object-format")) try pktline.print(w, "object-format={s}", .{adv.kind.name()});
    try pktline.delim(w);
}

const testing = std.testing;

test "a v0 advertisement reads its refs, peels and symbolic refs" {
    const gpa = testing.allocator;
    var wire: Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    const a = "1111111111111111111111111111111111111111";
    const b = "2222222222222222222222222222222222222222";
    try pktline.print(&wire.writer, "{s} HEAD\x00multi_ack thin-pack side-band-64k symref=HEAD:refs/heads/main agent=git/2\n", .{a});
    try pktline.print(&wire.writer, "{s} refs/heads/main\n", .{a});
    try pktline.print(&wire.writer, "{s} refs/tags/v1\n", .{b});
    try pktline.print(&wire.writer, "{s} refs/tags/v1^{{}}\n", .{a});
    try pktline.flush(&wire.writer);

    var fake: Fake = .init(wire.written());
    var adv = try readAdvertisement(gpa, &fake.connection, .sha1);
    defer adv.deinit();
    try testing.expectEqual(Version.v0, adv.version);
    try testing.expect(adv.has("side-band-64k"));
    try testing.expectEqualStrings("git/2", adv.value("agent").?);
    try testing.expectEqual(@as(usize, 3), adv.refs.len);
    try testing.expectEqualStrings("refs/heads/main", adv.refs[0].symref_target orelse adv.refs[0].name);
    try testing.expect(adv.refs[2].peeled.?.eql(try Oid.parse(.sha1, a)));

    var list = try listRefs(gpa, &fake.connection, &adv, .{ .prefixes = &.{"refs/tags/"} });
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.refs.len);
}

test "an empty v0 repository advertises capabilities and no refs" {
    const gpa = testing.allocator;
    var wire: Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    try pktline.print(&wire.writer, "{s} capabilities^{{}}\x00report-status delete-refs object-format=sha1\n", .{"0" ** 40});
    try pktline.flush(&wire.writer);
    var fake: Fake = .init(wire.written());
    var adv = try readAdvertisement(gpa, &fake.connection, .sha1);
    defer adv.deinit();
    try testing.expectEqual(@as(usize, 0), adv.refs.len);
    try testing.expect(adv.has("delete-refs"));
}

test "a server's error and a mismatched hash are refused by name" {
    const gpa = testing.allocator;
    {
        var wire: Io.Writer.Allocating = .init(gpa);
        defer wire.deinit();
        try pktline.write(&wire.writer, "ERR access denied\n");
        var fake: Fake = .init(wire.written());
        try testing.expectError(error.RemoteError, readAdvertisement(gpa, &fake.connection, .sha1));
        try testing.expectEqualStrings("access denied", fake.connection.message());
    }
    {
        var wire: Io.Writer.Allocating = .init(gpa);
        defer wire.deinit();
        try pktline.write(&wire.writer, "version 2\n");
        try pktline.write(&wire.writer, "object-format=sha256\n");
        try pktline.flush(&wire.writer);
        var fake: Fake = .init(wire.written());
        try testing.expectError(error.ObjectFormatMismatch, readAdvertisement(gpa, &fake.connection, .sha1));
    }
}

test "an ls-refs line carries its symbolic target, its peel, or its unborn state" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "1111111111111111111111111111111111111111";
    const head = try parseLsRefsLine(arena, .sha1, a ++ " HEAD symref-target:refs/heads/main");
    try testing.expectEqualStrings("refs/heads/main", head.symref_target.?);
    const tag = try parseLsRefsLine(arena, .sha1, a ++ " refs/tags/v1 peeled:" ++ a);
    try testing.expect(tag.peeled != null);
    const unborn = try parseLsRefsLine(arena, .sha1, "unborn HEAD symref-target:refs/heads/main");
    try testing.expect(unborn.unborn);
    try testing.expectError(error.ProtocolError, parseLsRefsLine(arena, .sha1, "xyz refs/heads/a"));
}

test "fuzz: any advertisement is refs or a named error" {
    try testing.fuzz({}, fuzzAdvertisement, .{});
}

fn fuzzAdvertisement(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var fake: Fake = .init(input);
    var adv = readAdvertisement(testing.allocator, &fake.connection, null) catch return;
    defer adv.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| _ = parseLsRefsLine(arena_state.allocator(), adv.kind, line) catch {};
}

/// A connection whose server said `bytes` and hears nothing, for the tests
/// of what is read.
pub const Fake = struct {
    buffer: [pktline.max_line]u8 = undefined,
    fixed: Io.Reader,
    limited: Io.Reader.Limited = undefined,
    sink: Io.Writer.Discarding,
    connection: Connection,

    const vtable: Connection.VTable = .{
        .advertisement = advertisement,
        .request = request,
        .response = response,
        .failure = failure,
        .close = close,
    };

    /// A connection whose server says `bytes`.
    pub fn init(bytes: []const u8) Fake {
        return .{
            .fixed = .fixed(bytes),
            .sink = .init(&.{}),
            .connection = .{ .context = undefined, .vtable = &vtable, .stateless = false },
        };
    }

    fn self(context: *anyopaque, c: *Connection) *Fake {
        _ = context;
        return @alignCast(@fieldParentPtr("connection", c));
    }

    fn advertisement(context: *anyopaque, c: *Connection) connection.Error!*Io.Reader {
        const f = self(context, c);
        f.limited = f.fixed.limited(.unlimited, &f.buffer);
        return &f.limited.interface;
    }

    fn request(context: *anyopaque, c: *Connection) connection.Error!*Io.Writer {
        return &self(context, c).sink.writer;
    }

    fn response(context: *anyopaque, c: *Connection) connection.Error!*Io.Reader {
        return &self(context, c).limited.interface;
    }

    fn failure(_: *anyopaque, _: *Connection) connection.Error {
        return error.ConnectionFailed;
    }

    fn close(_: *anyopaque, _: Io) void {}
};
