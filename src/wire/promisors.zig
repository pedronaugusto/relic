//! The promisor remotes a server tells a client about: git's
//! `promisor-remote` capability of protocol v2.
//!
//! A server with `promisor.advertise` names the promisor remotes it
//! borrows objects from — each one's name and URL, and the
//! `partialCloneFilter` and `token` `promisor.sendFields` lists — and a
//! client with `promisor.acceptFromServer` decides which it takes: none,
//! those it knows by name, those it knows by name and URL, or all, each
//! also passing `promisor.checkFields`. The client answers with the names
//! it took, stores what `promisor.storeFields` asks for in the remotes it
//! already has, and asks those remotes first for what it lacks. git 2.56's
//! `promisor.acceptFromServerUrl` takes, whatever `acceptFromServer` says,
//! an advertised remote whose URL a pattern allows: one it does not know is
//! configured as `promisor-auto-<host-and-path>` (or the pattern's name),
//! with `remote.<name>.advertisedAs` naming it as the server did. A server
//! told a remote was taken may leave out of its pack what that remote
//! promises. A clone or fetch with the filter `auto` takes its filter from
//! the remotes taken.
//!
//! Every value is percent-encoded on the wire, `,`, `;` and `%` among the
//! characters encoded, as git encodes them.

const std = @import("std");
const percent = @import("../text.zig").percent;
const Allocator = std.mem.Allocator;

const config_mod = @import("../config/config.zig");
const filter_spec = @import("filter_spec.zig");
const remote_mod = @import("remote.zig");
const urlmatch = @import("../text.zig").urlmatch;
const glob = @import("../text.zig").glob;
const warning = @import("../report.zig").warning;

/// A field beyond the name and URL.
pub const Field = enum {
    partial_clone_filter,
    token,

    /// The field's name on the wire and in `remote.<name>.<field>`.
    pub fn name(f: Field) []const u8 {
        return switch (f) {
            .partial_clone_filter => "partialCloneFilter",
            .token => "token",
        };
    }

    fn parse(text: []const u8) ?Field {
        for (std.enums.values(Field)) |f| {
            if (std.ascii.eqlIgnoreCase(text, f.name())) return f;
        }
        return null;
    }
};

/// Which fields a setting lists.
pub const Fields = struct {
    partial_clone_filter: bool = false,
    token: bool = false,

    /// The fields `key` lists, comma-separated; a name git does not know
    /// is left out and said in `warnings`.
    pub fn read(config: *const config_mod.Config, key: []const u8, warnings: ?*warning.Warnings) Allocator.Error!Fields {
        var out: Fields = .{};
        const raw = config.get(key) orelse return out;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const text = std.mem.trim(u8, part, " \t\n\r\x0b\x0c");
            if (text.len == 0) continue;
            const f = Field.parse(text) orelse {
                if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("unsupported field '{s}' in '{s}' config", .{ text, key }) });
                continue;
            };
            switch (f) {
                .partial_clone_filter => out.partial_clone_filter = true,
                .token => out.token = true,
            }
        }
        return out;
    }

    fn has(fs: Fields, f: Field) bool {
        return switch (f) {
            .partial_clone_filter => fs.partial_clone_filter,
            .token => fs.token,
        };
    }

    fn isEmpty(fs: Fields) bool {
        return !fs.partial_clone_filter and !fs.token;
    }
};

/// One promisor remote, as advertised or as configured.
pub const Info = struct {
    name: []const u8,
    url: []const u8,
    filter: ?[]const u8 = null,
    token: ?[]const u8 = null,
    /// The name of the client's remote for an advertised one, where it
    /// differs from the server's: one `promisor.acceptFromServerUrl`
    /// configured.
    local_name: ?[]const u8 = null,

    /// The name of the client's remote for it: git's
    /// `promisor_info_local_name`.
    pub fn localName(i: Info) []const u8 {
        return i.local_name orelse i.name;
    }

    fn field(i: Info, f: Field) ?[]const u8 {
        return switch (f) {
            .partial_clone_filter => i.filter,
            .token => i.token,
        };
    }
};

/// Every promisor remote of a repository configured with `config`, in the
/// order git asks them: each remote with `remote.<name>.promisor` true or
/// a `remote.<name>.partialclonefilter`, as the configuration first names
/// it, and the one `extensions.partialClone` names last. The names borrow
/// `config`; the list is `arena`'s.
pub fn remotes(arena: Allocator, config: *const config_mod.Config) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "remote") or !entry.has_subsection) continue;
        const promises = if (std.ascii.eqlIgnoreCase(entry.name, "promisor"))
            entry.value == null or (config_mod.parseBool(entry.value.?) catch false)
        else
            std.ascii.eqlIgnoreCase(entry.name, "partialclonefilter");
        if (!promises) continue;
        for (out.items) |n| {
            if (std.mem.eql(u8, n, entry.subsection)) break;
        } else try out.append(arena, entry.subsection);
    }
    if (config.get("extensions.partialclone")) |named| {
        for (out.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, named)) {
                _ = out.orderedRemove(i);
                break;
            }
        }
        try out.append(arena, named);
    }
    return out.items;
}

/// The value of `remote.<remote>.<key>`, unquoted, when set and not
/// empty. The result is `arena`'s.
fn remoteValue(arena: Allocator, config: *const config_mod.Config, remote: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
    const full = try arena.print("remote.{s}.{s}", .{ remote, key });
    const raw = config.get(full) orelse return null;
    const value = try arena.dupe(u8, raw);
    return if (value.len == 0) null else value;
}

/// The promisor remotes with a URL, each with the `fields` it has set:
/// git's `promisor_config_info_list`. The result is `arena`'s.
pub fn configured(arena: Allocator, config: *const config_mod.Config, fields: Fields) Allocator.Error![]Info {
    var out: std.ArrayList(Info) = .empty;
    for (try remotes(arena, config)) |name| {
        const url = try remoteValue(arena, config, name, "url") orelse continue;
        var info: Info = .{ .name = name, .url = url };
        if (fields.partial_clone_filter) info.filter = try remoteValue(arena, config, name, Field.partial_clone_filter.name());
        if (fields.token) info.token = try remoteValue(arena, config, name, Field.token.name());
        try out.append(arena, info);
    }
    return out.items;
}

fn allowUnencoded(c: u8) bool {
    return c != ',' and c != ';' and c != '%' and c > 32 and c < 127;
}

fn appendEncoded(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| {
        if (allowUnencoded(c)) {
            try out.append(arena, c);
        } else try out.print(arena, "%{x:0>2}", .{c});
    }
}

/// git's `url_percent_decode`: each `%` and two hex digits a byte, a `%`
/// that is not one kept as it stands.
pub fn decode(arena: Allocator, text: []const u8) Allocator.Error![]u8 {
    return percent.decode(arena, text, .decode);
}

/// What a server with `config` advertises as `promisor-remote=`, or
/// `null` when `promisor.advertise` is off or it has no promisor remote
/// with a URL; a malformed `promisor.advertise` is refused, as git's
/// `repo_config_get_bool` dies on it. The result is `arena`'s.
pub fn advertisement(arena: Allocator, config: *const config_mod.Config, warnings: ?*warning.Warnings) config_mod.ValueError!?[]const u8 {
    const on = try config.getBool("promisor.advertise", false);
    if (!on) return null;
    const infos = try configured(arena, config, try Fields.read(config, "promisor.sendFields", warnings));
    if (infos.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    for (infos, 0..) |info, i| {
        if (i != 0) try out.append(arena, ';');
        try out.appendSlice(arena, "name=");
        try appendEncoded(arena, &out, info.name);
        try out.appendSlice(arena, ",url=");
        try appendEncoded(arena, &out, info.url);
        if (info.filter) |f| {
            try out.appendSlice(arena, ",partialCloneFilter=");
            try appendEncoded(arena, &out, f);
        }
        if (info.token) |t| {
            try out.appendSlice(arena, ",token=");
            try appendEncoded(arena, &out, t);
        }
    }
    return out.items;
}

/// The promisor remotes of `config` a client's `promisor-remote=` reply
/// names, decoded; a name the server has no promisor remote by is said in
/// `warnings`, as git warns. The result is `arena`'s.
pub fn acceptedByClient(arena: Allocator, config: *const config_mod.Config, reply_text: []const u8, warnings: ?*warning.Warnings) Allocator.Error![]const []const u8 {
    const known = try remotes(arena, config);
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, reply_text, ';');
    while (it.next()) |part| {
        const name = try decode(arena, part);
        for (known) |k| {
            if (std.mem.eql(u8, k, name)) {
                try out.append(arena, k);
                break;
            }
        } else if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("accepted promisor remote '{s}' not found", .{name}) });
    }
    return out.items;
}

/// Which advertised remotes a client takes: `promisor.acceptFromServer`.
pub const Accept = enum {
    none,
    known_url,
    known_name,
    all,

    /// The setting in `config`; a value git does not know is `none`, and
    /// said in `warnings`.
    pub fn read(config: *const config_mod.Config, warnings: ?*warning.Warnings) Allocator.Error!Accept {
        const raw = config.get("promisor.acceptfromserver") orelse return .none;
        if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "None")) return .none;
        if (std.ascii.eqlIgnoreCase(raw, "KnownUrl")) return .known_url;
        if (std.ascii.eqlIgnoreCase(raw, "KnownName")) return .known_name;
        if (std.ascii.eqlIgnoreCase(raw, "All")) return .all;
        if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("unknown '{s}' value for '{s}' config option", .{ raw, "promisor.acceptfromserver" }) });
        return .none;
    }
};

/// A value the client stores in `remote.<remote>.<field>`.
pub const Store = struct {
    remote: []const u8,
    field: Field,
    /// What was there before, empty for nothing.
    old: []const u8,
    new: []const u8,

    /// `remote.<remote>.<field>`. The result is `arena`'s.
    pub fn key(s: Store, arena: Allocator) Allocator.Error![]const u8 {
        return arena.print("remote.{s}.{s}", .{ s.remote, s.field.name() });
    }
};

/// A remote `promisor.acceptFromServerUrl` has the client configure.
pub const Create = struct {
    name: []const u8,
    url: []const u8,
    /// The name the server gave it: `remote.<name>.advertisedAs`.
    advertised_as: []const u8,
    /// A remote of that name and URL was there: it is made a promisor
    /// remote, its URL left as it is.
    reuse: bool,
};

/// What a client makes of a server's `promisor-remote=`.
pub const Reply = struct {
    /// The advertised remotes taken, decoded, in the order advertised.
    accepted: []const Info = &.{},
    /// The remotes to configure before `stores` are written, in order.
    creates: []const Create = &.{},
    /// What the client answers, `promisor-remote=` and this; `null` when
    /// it took none and says nothing.
    text: ?[]const u8 = null,
    /// What `promisor.storeFields` writes into the client's configuration.
    stores: []const Store = &.{},
};

/// The client's answer to `advertised`, with `config`: git's
/// `promisor_remote_reply`. The result is `arena`'s.
pub fn reply(arena: Allocator, config: *const config_mod.Config, advertised: []const u8, warnings: ?*warning.Warnings) Allocator.Error!Reply {
    const accept = try Accept.read(config, warnings);
    const allowed = try allowedUrls(arena, config, warnings);
    if (accept == .none and allowed.len == 0) return .{};
    var accepted: std.ArrayList(Info) = .empty;
    var creates: std.ArrayList(Create) = .empty;
    var stores: std.ArrayList(Store) = .empty;
    var checked: ?[]Info = null;
    var check_fields: ?Fields = null;
    var stored: ?[]Info = null;
    var store_fields: Fields = .{};
    var it = std.mem.splitScalar(u8, advertised, ';');
    while (it.next()) |part| {
        const info = try parseOne(arena, part, warnings) orelse continue;
        if (checked == null) {
            check_fields = try Fields.read(config, "promisor.checkFields", warnings);
            checked = try configured(arena, config, check_fields.?);
        }
        var taken = info;
        if (find(checked.?, info.name) == null) {
            // Unknown here: a pattern may have it configured.
            if (try allowedNew(arena, config, allowed, creates.items, info, warnings)) |create| {
                try creates.append(arena, create);
                taken.local_name = create.name;
            } else if (accept != .all or !allFieldsMatch(info, checked.?, check_fields.?, null)) continue;
        } else if (!try shouldAccept(arena, accept, info, checked.?, check_fields.?, allowed, warnings)) continue;
        if (stored == null) {
            // git reads them at the first remote taken, with the remotes
            // configured so far.
            store_fields = try Fields.read(config, "promisor.storeFields", warnings);
            var known: std.ArrayList(Info) = .fromOwnedSlice(try configured(arena, config, store_fields));
            for (creates.items) |c| if (find(known.items, c.name) == null) try known.append(arena, .{ .name = c.name, .url = c.url });
            stored = known.items;
        }
        try storeFields(arena, taken, stored.?, store_fields, &stores, warnings);
        try accepted.append(arena, taken);
    }
    var text: ?[]const u8 = null;
    if (accepted.items.len != 0) {
        var out: std.ArrayList(u8) = .empty;
        for (accepted.items, 0..) |info, i| {
            if (i != 0) try out.append(arena, ';');
            try appendEncoded(arena, &out, info.name);
        }
        text = out.items;
    }
    return .{ .accepted = accepted.items, .creates = creates.items, .text = text, .stores = stores.items };
}

/// One `promisor.acceptFromServerUrl`: the name to give a remote it
/// allows, when the value names one before `=`, and the URL pattern,
/// normalized.
const Allowed = struct {
    remote_name: ?[]const u8,
    pattern: urlmatch.Info,
};

/// Every `promisor.acceptFromServerUrl` that holds: git's
/// `load_accept_from_server_url`, an invalid name or pattern passed over
/// with its warning.
fn allowedUrls(arena: Allocator, config: *const config_mod.Config, warnings: ?*warning.Warnings) Allocator.Error![]const Allowed {
    var out: std.ArrayList(Allowed) = .empty;
    for (config.entries.items) |e| {
        if (e.has_subsection or !std.mem.eql(u8, e.section, "promisor") or !std.mem.eql(u8, e.name, "acceptfromserverurl")) continue;
        const value = e.value orelse continue;
        var name: ?[]const u8 = null;
        var pattern = value;
        if (std.mem.findScalar(u8, value, '=')) |eq| {
            name = value[0..eq];
            pattern = value[eq + 1 ..];
            if (!remote_mod.validName(name.?)) {
                if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("invalid remote name '{s}' before '=' sign in '{s}' from promisor.acceptFromServerUrl config", .{ name.?, value }) });
                continue;
            }
        }
        const has_control = for (pattern) |c| {
            if (std.ascii.isControl(c)) break true;
        } else false;
        const normalized: ?urlmatch.Info = if (has_control) null else urlmatch.normalize(arena, pattern, true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        try out.append(arena, .{ .remote_name = name, .pattern = normalized orelse {
            if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("invalid url pattern '{s}' in '{s}' from promisor.acceptFromServerUrl config", .{ pattern, value }) });
            continue;
        } });
    }
    return out.items;
}

/// The pattern of `allowed` that `url` matches, normalized, if any: the
/// same scheme and port, and the host and the path each matching its
/// glob, a `*` free to match a `/` within one but never across the two.
fn allowedFor(arena: Allocator, allowed: []const Allowed, url: []const u8) Allocator.Error!?Allowed {
    const info = urlmatch.normalize(arena, url, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    for (allowed) |a| {
        const p = a.pattern;
        if (p.scheme_len != info.scheme_len or !std.mem.eql(u8, p.url[0..p.scheme_len], info.url[0..info.scheme_len])) continue;
        if (!std.mem.eql(u8, p.port.of(p), info.port.of(info))) continue;
        if (!try glob.matches(arena, p.host.of(p), info.host.of(info), .{ .pathname = false })) continue;
        if (!try glob.matches(arena, p.url[p.path_off..][0..p.path_len], info.url[info.path_off..][0..info.path_len], .{ .pathname = false })) continue;
        return a;
    }
    return null;
}

/// The remote a pattern has the client configure for `advertised`, an
/// unknown remote whose URL it allows: git's `handle_matching_allowed_url`.
/// The pattern's name, else one made from the URL; where a remote of that
/// name has another URL, `-1` to `-19` after it, and where one has this
/// URL, that one again. `null` where no pattern allows it, or no name
/// could be had (said in `warnings`).
fn allowedNew(arena: Allocator, config: *const config_mod.Config, allowed: []const Allowed, made: []const Create, advertised: Info, warnings: ?*warning.Warnings) Allocator.Error!?Create {
    const found: Allowed = (try allowedFor(arena, allowed, advertised.url)) orelse return null;
    const made_name: ?[]const u8 = if (found.remote_name == null) try nameFromUrl(arena, advertised.url, warnings) else null;
    const basename: []const u8 = found.remote_name orelse made_name orelse return null;
    const max_similar = 20;
    var name: []const u8 = basename;
    var i: usize = 0;
    var reuse = false;
    while (i < max_similar) {
        const existing = urlOf(config, made, name) orelse break;
        if (std.mem.eql(u8, existing, advertised.url)) {
            reuse = true;
            break;
        }
        i += 1;
        name = try arena.print("{s}-{d}", .{ basename, i });
    }
    if (i == max_similar) {
        if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("too many remotes accepted with name like '{s}-X', ignoring this remote", .{basename}) });
        return null;
    }
    return .{ .name = name, .url = advertised.url, .advertised_as = advertised.name, .reuse = reuse };
}

/// `remote.<name>.url`, its last value, among those configured and made.
fn urlOf(config: *const config_mod.Config, made: []const Create, name: []const u8) ?[]const u8 {
    var i = made.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, made[i].name, name)) return made[i].url;
    }
    var found: ?[]const u8 = null;
    for (config.entries.items) |e| {
        if (e.matches("remote", name, "url")) if (e.value) |v| {
            found = v;
        };
    }
    return found;
}

/// git's `promisor_remote_name_from_url`: `promisor-auto-` and the
/// normalized URL's host, port and path, its trailing `/` and `.git` gone,
/// each run of other than letters and digits one `-`, none at either end.
/// `null` where that leaves nothing or no valid name, said in `warnings`.
fn nameFromUrl(arena: Allocator, url: []const u8, warnings: ?*warning.Warnings) Allocator.Error!?[]const u8 {
    const info = urlmatch.normalize(arena, url, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("couldn't normalize advertised url '{s}', ignoring this remote", .{url}) });
            return null;
        },
    };
    var raw: std.ArrayList(u8) = .empty;
    if (info.host.len != 0) try raw.print(arena, "{s}-", .{info.host.of(info)});
    if (info.port.len != 0) try raw.print(arena, "{s}-", .{info.port.of(info)});
    if (info.path_len != 0) {
        var path = std.mem.trimEnd(u8, info.url[info.path_off..][0..info.path_len], "/");
        if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
        try raw.appendSlice(arena, path);
    }
    var name: std.ArrayList(u8) = .empty;
    try name.appendSlice(arena, "promisor-auto-");
    var prev: u8 = '-';
    for (raw.items) |c| {
        const kept: u8 = if (std.ascii.isAlphanumeric(c)) c else '-';
        if (prev == '-' and kept == '-') continue;
        try name.append(arena, kept);
        prev = kept;
    }
    if (name.items.len != 0 and name.items[name.items.len - 1] == '-') name.items.len -= 1;
    if (name.items.len == "promisor-auto-".len) {
        if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("couldn't generate a valid remote name from advertised url '{s}', ignoring this remote", .{url}) });
        return null;
    }
    if (!remote_mod.validName(name.items)) {
        if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("generated remote name '{s}' from advertised url '{s}' is invalid, ignoring this remote", .{ name.items, url }) });
        return null;
    }
    return name.items;
}

fn parseOne(arena: Allocator, text: []const u8, warnings: ?*warning.Warnings) Allocator.Error!?Info {
    var name: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var token: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |elem| {
        const eq = std.mem.findScalar(u8, elem, '=') orelse {
            if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("invalid element '{s}' from remote info", .{elem}) });
            continue;
        };
        const key = elem[0..eq];
        const value = try decode(arena, elem[eq + 1 ..]);
        if (std.mem.eql(u8, key, "name")) {
            name = value;
        } else if (std.mem.eql(u8, key, "url")) {
            url = value;
        } else if (std.mem.eql(u8, key, "partialCloneFilter")) {
            filter = value;
        } else if (std.mem.eql(u8, key, "token")) token = value;
    }
    if (name == null or name.?.len == 0 or url == null or url.?.len == 0) {
        if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("server advertised a promisor remote without a name or URL: '{s}', ignoring this remote", .{text}) });
        return null;
    }
    return .{ .name = name.?, .url = url.?, .filter = filter, .token = token };
}

fn findLocal(infos: []const Info, name: []const u8) ?Info {
    for (infos) |i| {
        if (std.mem.eql(u8, i.localName(), name)) return i;
    }
    return null;
}

fn find(infos: []const Info, name: []const u8) ?Info {
    for (infos) |i| {
        if (std.mem.eql(u8, i.name, name)) return i;
    }
    return null;
}

/// git's `all_fields_match`: every checked field advertised, and equal to
/// `entry`'s, or to any configured remote's when there is no entry.
fn allFieldsMatch(advertised: Info, configured_infos: []const Info, fields: Fields, entry: ?Info) bool {
    for (std.enums.values(Field)) |f| {
        if (!fields.has(f)) continue;
        const value = advertised.field(f) orelse return false;
        const matched = if (entry) |e|
            if (e.field(f)) |mine| std.mem.eql(u8, mine, value) else false
        else for (configured_infos) |c| {
            if (c.field(f)) |mine| if (std.mem.eql(u8, mine, value)) break true;
        } else false;
        if (!matched) return false;
    }
    return true;
}

/// git's `should_accept_remote` for a remote the client knows by the
/// advertised name.
fn shouldAccept(arena: Allocator, accept: Accept, advertised: Info, configured_infos: []const Info, fields: Fields, allowed: []const Allowed, warnings: ?*warning.Warnings) Allocator.Error!bool {
    const mine = find(configured_infos, advertised.name).?;
    // Known by name and URL, and the URL allowed: taken whatever
    // `acceptFromServer` says.
    if (std.mem.eql(u8, mine.url, advertised.url) and try allowedFor(arena, allowed, advertised.url) != null) {
        return allFieldsMatch(advertised, configured_infos, fields, mine);
    }
    if (accept == .all) return allFieldsMatch(advertised, configured_infos, fields, null);
    if (accept == .known_name) return allFieldsMatch(advertised, configured_infos, fields, mine);
    if (accept == .none) return false;
    if (!std.mem.eql(u8, mine.url, advertised.url)) {
        if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("known remote named '{s}' but with URL '{s}' instead of '{s}', ignoring this remote", .{ advertised.name, mine.url, advertised.url }) });
        return false;
    }
    return allFieldsMatch(advertised, configured_infos, fields, mine);
}

fn storeFields(arena: Allocator, advertised: Info, stored: []const Info, fields: Fields, out: *std.ArrayList(Store), warnings: ?*warning.Warnings) Allocator.Error!void {
    if (fields.isEmpty()) return;
    const mine = find(stored, advertised.localName()) orelse return;
    if (fields.partial_clone_filter) if (advertised.filter) |f| {
        if (filter_spec.sendForm(arena, f)) |_| {
            try storeOne(arena, advertised.localName(), .partial_clone_filter, f, mine.filter, out);
        } else |err| if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("invalid filter '{s}' for remote '{s}' will not be stored: {s}", .{ f, advertised.localName(), @errorName(err) }) });
    };
    if (fields.token) if (advertised.token) |t| {
        const has_control = for (t) |c| {
            if (std.ascii.isControl(c)) break true;
        } else false;
        if (has_control) {
            if (warnings) |w| try w.add(.{ .promisor = try w.arena.allocator().print("invalid token '{s}' for remote '{s}' will not be stored", .{ t, advertised.localName() }) });
        } else try storeOne(arena, advertised.localName(), .token, t, mine.token, out);
    };
}

fn storeOne(arena: Allocator, remote: []const u8, field: Field, new: []const u8, current: ?[]const u8, out: *std.ArrayList(Store)) Allocator.Error!void {
    if (current) |c| if (std.mem.eql(u8, c, new)) return;
    try out.append(arena, .{ .remote = remote, .field = field, .old = current orelse "", .new = new });
}

/// Errors from `autoFilter`.
pub const AutoFilterError = Allocator.Error || filter_spec.Error;

/// The filter `auto` stands for: the first of the client's promisor
/// remotes, in their order, that the reply took with an advertised
/// filter, in the form a server is sent; `null` for none. git reads one
/// such filter and stops at a second. The result is `arena`'s.
pub fn autoFilter(arena: Allocator, config: *const config_mod.Config, taken: []const Info) AutoFilterError!?[]const u8 {
    for (try remotes(arena, config)) |name| {
        const info = findLocal(taken, name) orelse continue;
        const f = info.filter orelse continue;
        const value = try filter_spec.sendForm(arena, f);
        return value;
    }
    // A remote configured for the reply after `config` was read.
    for (taken) |info| {
        if (info.local_name == null) continue;
        const f = info.filter orelse continue;
        const value = try filter_spec.sendForm(arena, f);
        return value;
    }
    return null;
}

const testing = std.testing;

test "a server advertises its promisor remotes and the fields it sends" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var config = try config_mod.Config.parseText(testing.allocator,
        \\[promisor]
        \\    advertise = true
        \\    sendFields = partialCloneFilter, token, colour
        \\[remote "lop"]
        \\    url = "https://example.com/a,b;c"
        \\    promisor = true
        \\    partialCloneFilter = blob:none
        \\    token = s3cret
        \\[remote "plain"]
        \\    url = https://example.com/plain
        \\
    , .local);
    defer config.deinit();
    var warnings: warning.Warnings = .init(testing.allocator);
    defer warnings.deinit();
    const text = (try advertisement(arena, &config, &warnings)).?;
    try testing.expectEqualStrings("name=lop,url=https://example.com/a%2cb%3bc,partialCloneFilter=blob:none,token=s3cret", text);
    try testing.expectEqual(@as(usize, 1), warnings.items.items.len);
    try testing.expectEqualStrings("lop", (try acceptedByClient(arena, &config, "lop;nobody", &warnings))[0]);
}

test "a malformed promisor.advertise is refused, as git dies on it, where it advertised nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var config = try config_mod.Config.parseText(testing.allocator, "[promisor]\n\tadvertise = maybe\n[remote \"lop\"]\n\turl = https://example.com/lop\n\tpromisor = true\n", .local);
    defer config.deinit();
    try testing.expectError(error.NotABoolean, advertisement(arena_state.allocator(), &config, null));
}

test "a client takes what promisor.acceptFromServer and checkFields allow, and stores what storeFields asks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const advertised = "name=lop,url=https://example.com/lop,partialCloneFilter=blob:limit%3d1k,token=t2;name=other,url=https://example.com/other;url=x";
    const Case = struct { text: []const u8, accepted: []const []const u8 };
    const cases = [_]Case{
        .{ .text = "", .accepted = &.{} },
        .{ .text = "[promisor]\n\tacceptFromServer = All\n", .accepted = &.{ "lop", "other" } },
        .{ .text = "[promisor]\n\tacceptFromServer = KnownName\n[remote \"lop\"]\n\tpromisor = true\n\turl = https://elsewhere\n", .accepted = &.{"lop"} },
        .{ .text = "[promisor]\n\tacceptFromServer = KnownUrl\n[remote \"lop\"]\n\tpromisor = true\n\turl = https://elsewhere\n", .accepted = &.{} },
        .{ .text = "[promisor]\n\tacceptFromServer = knownurl\n\tcheckFields = token\n[remote \"lop\"]\n\tpromisor = true\n\turl = https://example.com/lop\n\ttoken = t1\n", .accepted = &.{} },
        .{ .text = "[promisor]\n\tacceptFromServer = knownurl\n\tcheckFields = token\n[remote \"lop\"]\n\tpromisor = true\n\turl = https://example.com/lop\n\ttoken = t2\n", .accepted = &.{"lop"} },
    };
    for (cases) |case| {
        var config = try config_mod.Config.parseText(testing.allocator, case.text, .local);
        defer config.deinit();
        const r = try reply(arena, &config, advertised, null);
        try testing.expectEqual(case.accepted.len, r.accepted.len);
        for (case.accepted, r.accepted) |want, got| try testing.expectEqualStrings(want, got.name);
    }

    var config = try config_mod.Config.parseText(testing.allocator,
        \\[promisor]
        \\    acceptFromServer = KnownName
        \\    storeFields = partialCloneFilter,token
        \\[remote "lop"]
        \\    promisor = true
        \\    url = https://example.com/lop
        \\    token = t2
        \\
    , .local);
    defer config.deinit();
    const r = try reply(arena, &config, advertised, null);
    try testing.expectEqualStrings("lop", r.text.?);
    try testing.expectEqual(@as(usize, 1), r.stores.len);
    try testing.expectEqual(Field.partial_clone_filter, r.stores[0].field);
    try testing.expectEqualStrings("blob:limit=1k", r.stores[0].new);
    try testing.expectEqualStrings("blob:limit=1024", (try autoFilter(arena, &config, r.accepted)).?);
}

/// All errors reported by this namespace.
pub const Error = AutoFilterError || Allocator.Error;
