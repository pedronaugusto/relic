//! Answering a proxy's challenge: `Proxy-Authenticate`, read, and the
//! `Proxy-Authorization` that answers it, as curl answers for git.
//!
//! A challenge names a scheme and its parameters — `Digest realm="proxy",
//! nonce="…", qop="auth", algorithm=SHA-256` — and one header may carry
//! several. Basic answers with the user and password as they are. Digest
//! (RFC 7616) answers with a hash of them, the nonce the proxy gave, the
//! request's method and target, and a count and a nonce of the client's
//! own, with MD5, SHA-256 and SHA-512-256 and their `-sess` forms, `qop=auth`
//! or none, and a hashed user name when the proxy asks for one. `auth-int`,
//! which hashes the body too, is not offered by curl for a proxy either.
//! Negotiate and NTLM need a security library of the system's and are not
//! spoken: `pick` names them unsupported.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A scheme a challenge names.
pub const Scheme = enum { basic, digest, other };

/// One challenge: its scheme, and its parameters as written, quoted strings
/// unescaped.
pub const Challenge = struct {
    scheme: Scheme,
    /// The scheme's name as the proxy wrote it.
    name: []const u8,
    params: []const Param,

    /// The value of the parameter `key`, compared without case.
    pub fn param(c: Challenge, key: []const u8) ?[]const u8 {
        for (c.params) |p| {
            if (std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
        }
        return null;
    }
};

/// A parameter of a challenge.
pub const Param = struct { key: []const u8, value: []const u8 };

/// Errors from reading a challenge.
pub const Error = error{
    /// A header that is not a list of challenges.
    MalformedChallenge,
} || Allocator.Error;

/// Every challenge in one `Proxy-Authenticate` value, into `arena`.
pub fn parse(arena: Allocator, value: []const u8) Error![]const Challenge {
    var out: std.ArrayList(Challenge) = .empty;
    var params: std.ArrayList(Param) = .empty;
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (true) {
        i = skip(value, i, " \t,");
        if (i >= value.len) break;
        const start = i;
        while (i < value.len and isTokenChar(value[i])) i += 1;
        if (i == start) return error.MalformedChallenge;
        const token = value[start..i];
        const after = skip(value, i, " \t");
        if (after < value.len and value[after] == '=' and name != null) {
            // A parameter of the scheme before it.
            i = skip(value, after + 1, " \t");
            var val: []const u8 = undefined;
            if (i < value.len and value[i] == '"') {
                var text: std.ArrayList(u8) = .empty;
                i += 1;
                while (true) {
                    if (i >= value.len) return error.MalformedChallenge;
                    const c = value[i];
                    i += 1;
                    if (c == '"') break;
                    if (c == '\\') {
                        if (i >= value.len) return error.MalformedChallenge;
                        try text.append(arena, value[i]);
                        i += 1;
                    } else try text.append(arena, c);
                }
                val = text.items;
            } else {
                const vstart = i;
                while (i < value.len and value[i] != ',' and value[i] != ' ' and value[i] != '\t') i += 1;
                val = value[vstart..i];
            }
            try params.append(arena, .{ .key = token, .value = val });
        } else {
            // A new scheme. A token68 after it — `Negotiate abc==` — in
            // place of parameters is kept as one with no name.
            if (name) |n| try out.append(arena, try finish(arena, n, &params));
            name = token;
            if (after < value.len and value[after] != ',') {
                var j = after;
                while (j < value.len and value[j] != ',') j += 1;
                const rest = std.mem.trim(u8, value[after..j], " \t");
                if (rest.len != 0 and !looksLikeParam(rest)) {
                    try params.append(arena, .{ .key = "", .value = rest });
                    i = j;
                }
            }
        }
    }
    if (name) |n| try out.append(arena, try finish(arena, n, &params));
    return out.items;
}

fn looksLikeParam(text: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    if (eq == 0) return false;
    for (text[0..eq]) |c| if (!isTokenChar(c)) return false;
    return eq + 1 < text.len and text[eq + 1] != '=';
}

fn finish(arena: Allocator, name: []const u8, params: *std.ArrayList(Param)) Allocator.Error!Challenge {
    const scheme: Scheme = if (std.ascii.eqlIgnoreCase(name, "basic"))
        .basic
    else if (std.ascii.eqlIgnoreCase(name, "digest"))
        .digest
    else
        .other;
    const owned = try arena.dupe(Param, params.items);
    params.clearRetainingCapacity();
    return .{ .scheme = scheme, .name = name, .params = owned };
}

fn skip(text: []const u8, from: usize, set: []const u8) usize {
    var i = from;
    while (i < text.len and std.mem.indexOfScalar(u8, set, text[i]) != null) i += 1;
    return i;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// Which schemes may answer: `any` answers the strongest the proxy offers
/// that relic speaks, Digest before Basic, as curl's anyauth picks; the
/// others answer only their own.
pub const Method = enum { any, basic, digest };

/// What `pick` chose, or why nothing was.
pub const Pick = union(enum) {
    digest: Challenge,
    basic,
    /// The proxy offers only schemes relic does not speak, or none the
    /// method allows: their names, `, `-joined.
    unsupported: []const u8,
};

/// The challenge to answer out of `challenges`, as curl picks it.
pub fn pick(arena: Allocator, challenges: []const Challenge, method: Method) Allocator.Error!Pick {
    if (method != .basic) {
        for (challenges) |c| {
            if (c.scheme == .digest and Digest.speaks(c)) return .{ .digest = c };
        }
    }
    if (method != .digest) {
        for (challenges) |c| if (c.scheme == .basic) return .basic;
    }
    var names: std.ArrayList(u8) = .empty;
    for (challenges, 0..) |c, n| {
        if (n != 0) try names.appendSlice(arena, ", ");
        try names.appendSlice(arena, c.name);
    }
    return .{ .unsupported = names.items };
}

/// `Basic <base64 of user:password>`, into `gpa`.
pub fn basic(gpa: Allocator, user: []const u8, password: []const u8) Allocator.Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    const plain = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ user, password });
    defer gpa.free(plain);
    const out = try gpa.alloc(u8, "Basic ".len + encoder.calcSize(plain.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = encoder.encode(out["Basic ".len..], plain);
    return out;
}

/// A Digest answer's state, across the requests that use one nonce.
pub const Digest = struct {
    algorithm: Algorithm,
    /// Whether the proxy named the algorithm, which the answer then names.
    algorithm_named: bool,
    session: bool,
    realm: []const u8,
    nonce: []const u8,
    opaque_value: ?[]const u8,
    qop_auth: bool,
    userhash: bool,
    /// How many requests have used the nonce.
    nc: u32 = 0,
    cnonce: []const u8,

    /// The hash a Digest challenge names.
    pub const Algorithm = enum {
        md5,
        sha256,
        sha512_256,

        fn name(a: Algorithm) []const u8 {
            return switch (a) {
                .md5 => "MD5",
                .sha256 => "SHA-256",
                .sha512_256 => "SHA-512-256",
            };
        }
    };

    /// Whether `c` is a Digest challenge relic can answer: a known
    /// algorithm, and `auth` among its qop values when it gives any.
    pub fn speaks(c: Challenge) bool {
        if (c.param("nonce") == null) return false;
        _ = algorithmOf(c) orelse return false;
        if (c.param("qop")) |qop| return qopHasAuth(qop);
        return true;
    }

    fn algorithmOf(c: Challenge) ?struct { alg: Algorithm, sess: bool } {
        const text = c.param("algorithm") orelse return .{ .alg = .md5, .sess = false };
        const table = [_]struct { []const u8, Algorithm, bool }{
            .{ "MD5", .md5, false },                .{ "MD5-sess", .md5, true },
            .{ "SHA-256", .sha256, false },         .{ "SHA-256-sess", .sha256, true },
            .{ "SHA-512-256", .sha512_256, false }, .{ "SHA-512-256-sess", .sha512_256, true },
        };
        for (table) |t| if (std.ascii.eqlIgnoreCase(text, t[0])) return .{ .alg = t[1], .sess = t[2] };
        return null;
    }

    fn qopHasAuth(qop: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, qop, ", \t");
        while (it.next()) |q| if (std.ascii.eqlIgnoreCase(q, "auth")) return true;
        return false;
    }

    /// The state for answering `c`, with `cnonce` the client's own nonce.
    /// Everything is copied into `gpa`; `deinit` frees it.
    pub fn init(gpa: Allocator, c: Challenge, cnonce: []const u8) Allocator.Error!Digest {
        const alg = algorithmOf(c).?;
        const realm = try gpa.dupe(u8, c.param("realm") orelse "");
        errdefer gpa.free(realm);
        const nonce = try gpa.dupe(u8, c.param("nonce").?);
        errdefer gpa.free(nonce);
        const opaque_value = if (c.param("opaque")) |o| try gpa.dupe(u8, o) else null;
        errdefer if (opaque_value) |o| gpa.free(o);
        const own = try gpa.dupe(u8, cnonce);
        return .{
            .algorithm = alg.alg,
            .algorithm_named = c.param("algorithm") != null,
            .session = alg.sess,
            .realm = realm,
            .nonce = nonce,
            .opaque_value = opaque_value,
            .qop_auth = if (c.param("qop")) |q| qopHasAuth(q) else false,
            .userhash = if (c.param("userhash")) |u| std.ascii.eqlIgnoreCase(u, "true") else false,
            .cnonce = own,
        };
    }

    /// Release the copies.
    pub fn deinit(d: *Digest, gpa: Allocator) void {
        gpa.free(d.realm);
        gpa.free(d.nonce);
        if (d.opaque_value) |o| gpa.free(o);
        gpa.free(d.cnonce);
        d.* = undefined;
    }

    /// The `Proxy-Authorization` value for one request, `method` to `uri`
    /// — the request target, `host:port` for a `CONNECT` — counting it.
    /// Into `gpa`.
    pub fn answer(d: *Digest, gpa: Allocator, user: []const u8, password: []const u8, method: []const u8, uri: []const u8) Allocator.Error![]u8 {
        d.nc += 1;
        var nc_buf: [8]u8 = undefined;
        const nc = std.fmt.bufPrint(&nc_buf, "{x:0>8}", .{d.nc}) catch unreachable;

        var ha1 = try d.hash(gpa, &.{ user, ":", d.realm, ":", password });
        if (d.session) {
            const outer = try d.hash(gpa, &.{ ha1, ":", d.nonce, ":", d.cnonce });
            gpa.free(ha1);
            ha1 = outer;
        }
        defer gpa.free(ha1);
        const ha2 = try d.hash(gpa, &.{ method, ":", uri });
        defer gpa.free(ha2);
        const response = if (d.qop_auth)
            try d.hash(gpa, &.{ ha1, ":", d.nonce, ":", nc, ":", d.cnonce, ":", "auth", ":", ha2 })
        else
            try d.hash(gpa, &.{ ha1, ":", d.nonce, ":", ha2 });
        defer gpa.free(response);
        const shown_user = if (d.userhash) try d.hash(gpa, &.{ user, ":", d.realm }) else try gpa.dupe(u8, user);
        defer gpa.free(shown_user);

        // curl's order.
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        (write: {
            w.writeAll("Digest username=\"") catch |e| break :write e;
            writeQuoted(w, shown_user) catch |e| break :write e;
            w.writeAll("\", realm=\"") catch |e| break :write e;
            writeQuoted(w, d.realm) catch |e| break :write e;
            w.print("\", nonce=\"{s}\", uri=\"{s}\"", .{ d.nonce, uri }) catch |e| break :write e;
            if (d.qop_auth) w.print(", cnonce=\"{s}\", nc={s}, qop=auth", .{ d.cnonce, nc }) catch |e| break :write e;
            w.print(", response=\"{s}\"", .{response}) catch |e| break :write e;
            if (d.opaque_value) |o| w.print(", opaque=\"{s}\"", .{o}) catch |e| break :write e;
            if (d.algorithm_named) w.print(", algorithm={s}{s}", .{ d.algorithm.name(), if (d.session) "-sess" else "" }) catch |e| break :write e;
            if (d.userhash) w.writeAll(", userhash=true") catch |e| break :write e;
        }) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeQuoted(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
        for (text) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
    }

    /// The lower-case hex of the algorithm's hash of `parts` joined.
    fn hash(d: *const Digest, gpa: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
        return switch (d.algorithm) {
            .md5 => hexOf(std.crypto.hash.Md5, gpa, parts),
            .sha256 => hexOf(std.crypto.hash.sha2.Sha256, gpa, parts),
            .sha512_256 => hexOf(std.crypto.hash.sha2.Sha512_256, gpa, parts),
        };
    }

    fn hexOf(comptime H: type, gpa: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
        var h = H.init(.{});
        for (parts) |p| h.update(p);
        var digest: [H.digest_length]u8 = undefined;
        h.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        return gpa.dupe(u8, &hex);
    }
};

const testing = std.testing;

test "challenges are read as a proxy writes them, several to a header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parse(a, "Digest realm=\"a \\\"b\\\"\", nonce=\"n1\", qop=\"auth,auth-int\", algorithm=SHA-256, stale=false, Basic realm=\"proxy\"");
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(Scheme.digest, list[0].scheme);
    try testing.expectEqualStrings("a \"b\"", list[0].param("realm").?);
    try testing.expectEqualStrings("SHA-256", list[0].param("ALGORITHM").?);
    try testing.expectEqual(Scheme.basic, list[1].scheme);
    try testing.expectEqualStrings("proxy", list[1].param("realm").?);
    const neg = try parse(a, "Negotiate, NTLM");
    try testing.expectEqual(@as(usize, 2), neg.len);
    try testing.expectEqualStrings("unsupported", @tagName(try pick(a, neg, .any)));
    try testing.expectEqualStrings("Negotiate, NTLM", (try pick(a, neg, .any)).unsupported);
    try testing.expect((try pick(a, list, .any)) == .digest);
    try testing.expect((try pick(a, list, .basic)) == .basic);
    try testing.expectError(error.MalformedChallenge, parse(a, "Digest realm=\"open"));
}

test "a Digest answer is RFC 7616's, for its worked examples" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // RFC 7616, section 3.9.1: Mufasa, both algorithms.
    for ([_]struct { alg: []const u8, response: []const u8 }{
        .{ .alg = "MD5", .response = "8ca523f5e9506fed4657c9700eebdbec" },
        .{ .alg = "SHA-256", .response = "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1" },
    }) |case| {
        const header = try std.fmt.allocPrint(arena.allocator(), "Digest realm=\"http-auth@example.org\", qop=\"auth, auth-int\", algorithm={s}, nonce=\"7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v\", opaque=\"FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS\"", .{case.alg});
        const list = try parse(arena.allocator(), header);
        var d: Digest = try .init(gpa, list[0], "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ");
        defer d.deinit(gpa);
        const value = try d.answer(gpa, "Mufasa", "Circle of Life", "GET", "/dir/index.html");
        defer gpa.free(value);
        const want = try std.fmt.allocPrint(arena.allocator(), "response=\"{s}\"", .{case.response});
        testing.expect(std.mem.indexOf(u8, value, want) != null) catch |err| {
            std.debug.print("{s}\n", .{value});
            return err;
        };
        try testing.expect(std.mem.indexOf(u8, value, "nc=00000001, qop=auth") != null);
    }
}

test "fuzz: any Proxy-Authenticate value is read or refused by name" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const text = buf[0..smith.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const list = parse(arena.allocator(), text) catch |err| switch (err) {
                error.MalformedChallenge => return,
                else => return err,
            };
            _ = try pick(arena.allocator(), list, .any);
        }
    }.one, .{ .corpus = &.{ "Digest realm=\"r\", nonce=\"n\"", "Basic realm=\"p\"", "Negotiate abc==" } });
}
