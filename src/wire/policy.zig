//! Which transports a remote may be reached through, as git's
//! `is_transport_allowed` decides it.
//!
//! Every way of reaching a remote has a name: `file` for a repository or a
//! bundle on this machine, `ssh`, `git`, `http`, `https`, and a remote
//! helper's own name (`ext`, `testgit`). `GIT_ALLOW_PROTOCOL`, a list of
//! names split by `:`, is the whole answer when it is set. Otherwise
//! `protocol.<name>.allow`, then `protocol.allow`, then git's defaults say
//! `always`, `never` or `user`: `http`, `https`, `git` and `ssh` always,
//! `ext` never, and anything else — `file` among them — only when the
//! person asked for it. What a submodule's `.gitmodules` names was not
//! asked for by the person, which git says with `GIT_PROTOCOL_FROM_USER=0`
//! and a caller says with `from_user`.

const std = @import("std");
const Environ = std.process.Environ;

const config_mod = @import("../config/config.zig");
const url_mod = @import("url.zig");

/// The name git checks for a URL relic reaches itself: `file` for a path
/// or a `file://` URL, else its scheme.
pub fn nameOf(scheme: url_mod.Scheme) []const u8 {
    return switch (scheme) {
        .local, .file => "file",
        .ssh => "ssh",
        .git => "git",
        .http => "http",
        .https => "https",
    };
}

/// Whether the transport `name` may be used. `from_user` is whether the
/// person named the remote themselves; `null` takes
/// `GIT_PROTOCOL_FROM_USER` from `environ`, true when it is not set, as git
/// takes it.
pub const Options = struct {
    config: ?*const config_mod.Config = null,
    environ: ?*const Environ.Map = null,
    from_user: ?bool = null,
};

pub fn allowed(name: []const u8, options: Options) bool {
    const config = options.config;
    const environ = options.environ;
    const from_user = options.from_user;
    if (environ) |env| if (env.get("GIT_ALLOW_PROTOCOL")) |list| {
        var names = std.mem.splitScalar(u8, list, ':');
        while (names.next()) |allowed_name| if (std.mem.eql(u8, allowed_name, name)) return true;
        return false;
    };
    var key_buf: [128]u8 = undefined;
    const key = std.mem.print(&key_buf, "protocol.{s}.allow", .{name}) catch return false;
    const configured = if (config) |c| c.get(key) orelse c.get("protocol.allow") else null;
    const policy = configured orelse builtIn(name);
    if (std.ascii.eqlIgnoreCase(policy, "always")) return true;
    if (std.ascii.eqlIgnoreCase(policy, "never")) return false;
    // git dies on any other value; refusing is the safe reading of it.
    if (!std.ascii.eqlIgnoreCase(policy, "user")) return false;
    if (from_user) |asked| return asked;
    const env = environ orelse return true;
    const text = env.get("GIT_PROTOCOL_FROM_USER") orelse return true;
    return config_mod.parseBool(text) catch true;
}

/// git's defaults: the transports known to be safe always, `ext` never,
/// the rest only when the person asked.
fn builtIn(name: []const u8) []const u8 {
    for ([_][]const u8{ "http", "https", "git", "ssh" }) |safe| {
        if (std.mem.eql(u8, name, safe)) return "always";
    }
    if (std.mem.eql(u8, name, "ext")) return "never";
    return "user";
}

const testing = std.testing;

test "a transport is allowed as git's is_transport_allowed allows it" {
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    // The defaults.
    for ([_][]const u8{ "http", "https", "git", "ssh", "file", "testgit" }) |name| {
        try testing.expect(allowed(name, .{ .config = null, .environ = &env, .from_user = null }));
    }
    try testing.expect(!allowed("ext", .{ .config = null, .environ = &env, .from_user = null }));
    try testing.expect(!allowed("file", .{ .config = null, .environ = &env, .from_user = false }));
    try testing.expect(!allowed("testgit", .{ .config = null, .environ = &env, .from_user = false }));
    try testing.expect(allowed("https", .{ .config = null, .environ = &env, .from_user = false }));
    try env.put("GIT_PROTOCOL_FROM_USER", "0");
    try testing.expect(!allowed("file", .{ .config = null, .environ = &env, .from_user = null }));
    try testing.expect(allowed("file", .{ .config = null, .environ = &env, .from_user = true }));
    try testing.expect(allowed("ssh", .{ .config = null, .environ = &env, .from_user = null }));

    // protocol.<name>.allow, then protocol.allow.
    var config = try config_mod.Config.parseText(testing.allocator, "[protocol \"ext\"]\nallow = always\n[protocol \"file\"]\nallow = always\n[protocol]\nallow = never\n", .local);
    defer config.deinit();
    try testing.expect(allowed("ext", .{ .config = &config, .environ = &env, .from_user = null }));
    try testing.expect(allowed("file", .{ .config = &config, .environ = &env, .from_user = false }));
    try testing.expect(!allowed("testgit", .{ .config = &config, .environ = &env, .from_user = null }));
    try testing.expect(!allowed("https", .{ .config = &config, .environ = &env, .from_user = null }));

    // GIT_ALLOW_PROTOCOL over everything.
    try env.put("GIT_ALLOW_PROTOCOL", "https:ssh");
    try testing.expect(allowed("https", .{ .config = &config, .environ = &env, .from_user = null }));
    try testing.expect(allowed("ssh", .{ .config = &config, .environ = &env, .from_user = false }));
    try testing.expect(!allowed("ext", .{ .config = &config, .environ = &env, .from_user = null }));
    try testing.expect(!allowed("file", .{ .config = &config, .environ = &env, .from_user = true }));
}

/// All errors reported by this namespace.
pub const Error = error{};
