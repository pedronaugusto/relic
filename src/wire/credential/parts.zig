//! A URL's credential parts, as git's `credential_from_url_1` reads them:
//! what a remote's URL gives a credential, what a `credential.<url>`
//! pattern names, and what each line of `credential-store`'s file holds.

const std = @import("std");
const aegis = @import("aegis");
const SecretBytes = aegis.SecretBytes;
const percent = @import("../../text.zig").percent;
const Allocator = std.mem.Allocator;

pub const UrlError = error{
    /// Not a URL with a scheme, where the whole of one is wanted.
    NoScheme,
    CredentialValueUnsafe,
};

/// What git's `credential_from_url_1` reads from a URL: every part decoded,
/// the host with its port and brackets as written, the path without the
/// slashes at either end. Read in part, as a `credential.<url>` pattern is,
/// a part the text does not have is left out.
pub const UrlParts = struct {
    protocol: ?[]u8 = null,
    host: ?[]u8 = null,
    path: ?[]u8 = null,
    username: ?[]u8 = null,
    /// Decoded straight into its owner, so no copy of it is freed unwiped.
    password: ?SecretBytes = null,
    /// A username that is not empty: git's `username_from_proto`.
    username_from_url: bool = false,

    pub fn deinit(p: *UrlParts, gpa: Allocator) void {
        inline for (.{ "protocol", "host", "path", "username" }) |name| {
            if (@field(p, name)) |v| gpa.free(v);
        }
        if (p.password) |*secret| secret.deinit();
        p.* = undefined;
    }

    pub fn read(gpa: Allocator, url: []const u8, partial: bool) (UrlError || Allocator.Error)!UrlParts {
        // The text is a C string to git: it ends at a NUL.
        const text = url[0 .. std.mem.findScalar(u8, url, 0) orelse url.len];
        const proto_end = std.mem.find(u8, text, "://");
        if (!partial and (proto_end == null or proto_end.? == 0)) return error.NoScheme;
        var p: UrlParts = .{};
        errdefer p.deinit(gpa);
        const cp = if (proto_end) |e| e + 3 else 0;
        const after = text[cp..];
        const slash = cp + (std.mem.findAny(u8, after, "/?#") orelse after.len);
        const at = std.mem.findScalar(u8, after, '@');
        const colon = std.mem.findScalar(u8, after, ':');
        var host_start = cp;
        if (at) |a_rel| {
            const a = cp + a_rel;
            if (a < slash) {
                const user_end = if (colon) |c_rel| (if (cp + c_rel < a) cp + c_rel else a) else a;
                p.username = try percent.decode(gpa, text[cp..user_end], .literal);
                p.username_from_url = p.username.?.len != 0;
                if (user_end != a) p.password = try decodeSecret(gpa, text[user_end + 1 .. a]);
                host_start = a + 1;
            }
        }
        if (proto_end) |e| if (e > 0) {
            p.protocol = try gpa.dupe(u8, text[0..e]);
        };
        if (!partial or slash > host_start) p.host = try percent.decode(gpa, text[host_start..slash], .literal);
        var path_start = slash;
        while (path_start < text.len and text[path_start] == '/') path_start += 1;
        if (path_start < text.len) {
            const decoded = try percent.decode(gpa, text[path_start..], .literal);
            var end = decoded.len;
            while (end > 1 and decoded[end - 1] == '/') end -= 1;
            p.path = try gpa.realloc(decoded, end);
        }
        inline for (.{ "username", "protocol", "host", "path" }) |name| {
            if (@field(p, name)) |v| if (std.mem.findScalar(u8, v, '\n') != null) return error.CredentialValueUnsafe;
        }
        if (p.password) |*secret| if (std.mem.findScalar(u8, secret.expose(), '\n') != null) return error.CredentialValueUnsafe;
        return p;
    }

    /// `percent.decode` into a secret's owner: `decode` shrinks its
    /// allocation afterwards, which may move it and free the first copy as
    /// it was.
    fn decodeSecret(gpa: Allocator, text: []const u8) Allocator.Error!SecretBytes {
        var secret = try SecretBytes.init(gpa, text.len);
        errdefer secret.deinit();
        // unreachable: the owner was made with the text's length.
        secret.resizeWithinCapacity(text.len) catch unreachable;
        const len = percent.decodeInto(secret.exposeMut(), text, .literal);
        // unreachable: a decoded text is no longer than the text.
        secret.resizeWithinCapacity(len) catch unreachable;
        return secret;
    }

    /// git's `credential_match` without the password: every part the
    /// pattern has is the credential's. `have` is anything with the same
    /// optional parts.
    pub fn matches(want: *const UrlParts, have: anytype) bool {
        return credentialMatch(want, have, false);
    }
};

/// `parts` after `text`'s live bytes, in order: a credential's text built a
/// piece at a time, held nowhere but in wiped storage.
pub fn appendParts(text: *SecretBytes, parts: []const []const u8) Allocator.Error!void {
    for (parts) |piece| text.appendSlice(piece) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overlap => unreachable,
    };
}

/// git's `credential_match`: every part `want` has -- protocol, host,
/// path, username and, with `match_password`, password and credential --
/// `have` has the same. Either is anything with those parts it has as
/// optional bytes or secrets; a part one of them lacks is one it does not
/// have.
pub fn credentialMatch(want: anytype, have: anytype, match_password: bool) bool {
    inline for (.{ "protocol", "host", "path", "username", "password", "credential" }) |name| {
        const secret = comptime std.mem.eql(u8, name, "password") or std.mem.eql(u8, name, "credential");
        if (!secret or match_password) {
            if (part(want, name)) |w| {
                const h = part(have, name) orelse return false;
                if (!std.mem.eql(u8, w, h)) return false;
            }
        }
    }
    return true;
}

/// The part `name` of `c`, a secret's bytes exposed, or `null`.
fn part(c: anytype, comptime name: []const u8) ?[]const u8 {
    const T = switch (@typeInfo(@TypeOf(c))) {
        .pointer => |ptr| ptr.child,
        else => @TypeOf(c),
    };
    if (!@hasField(T, name)) return null;
    const value = @field(c, name) orelse return null;
    return if (@TypeOf(value) == SecretBytes) value.expose() else value;
}
