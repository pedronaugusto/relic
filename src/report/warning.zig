//! What git would have printed as `warning:` and went on after.
//!
//! git tells the person, on its standard error, when it did something other
//! than what was asked and carried on — a `--depth` a local clone ignores, a
//! filter a server does not know, certificate checks turned off — and passes
//! along what `ssh` says. relic prints nothing, so an operation handed a
//! `Warnings` adds each one there instead, as a value a caller can show,
//! count or act on; one handed none says nothing and loses nothing.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One warning.
pub const Warning = union(enum) {
    /// An option a clone or fetch from a path on this machine does not
    /// apply: `--depth`, `--shallow-since`, `--shallow-exclude`, `--filter`.
    /// git ignores them there too; `file://` is how to have them.
    ignored_for_local: []const u8,
    /// The server does not filter, and everything was fetched.
    filter_not_supported,
    /// The server's certificate was not checked, because the named setting
    /// said not to.
    ssl_verify_disabled: []const u8,
    /// What `ssh` wrote on its standard error, a line to a line, on a
    /// conversation that went on to succeed.
    ssh_said: []const u8,
    /// A ref from a shallow remote left alone, because taking it would move
    /// this repository's boundary and the fetch did not say to: the local
    /// ref's name.
    shallow_update_rejected: []const u8,
    /// `http.proxyAuthMethod` names a method git does not know, and anyauth
    /// is used: the name.
    proxy_auth_method_unknown: []const u8,
    /// An annotated tag whose object gives itself another name than its
    /// ref: `git describe` prints the object's.
    tag_known_as: struct { path: []const u8, name: []const u8 },

    /// A successful fetch could not update its optional commit-graph.
    commit_graph_write_failed: []const u8,
    /// What git's fsck found and the rules make a warning: the object's
    /// name and git's message, `<msg-id>: <text>`.
    fsck: struct { object: []const u8, message: []const u8 },
    /// A `fetch.fsck.<msg-id>` or `receive.fsck.<msg-id>` naming no
    /// message git has, which is left out: the name.
    fsck_unknown_message: []const u8,
    /// What git warns of while reading or answering a server's
    /// `promisor-remote`: the text.
    promisor: []const u8,
    /// A field a server advertised for a promisor remote, stored as
    /// `promisor.storeFields` asks: `filter` or `token`, the remote, the
    /// value before and after.
    promisor_stored: struct { field: []const u8, remote: []const u8, old: []const u8, new: []const u8 },
    /// A remote URL carries a password, and `transfer.credentialsInUrl`
    /// is `warn`: the URL, its password replaced by `<redacted>`.
    credentials_in_url: []const u8,

    /// The text git prints after `warning: ` for it, where git prints one.
    /// The result is `arena`'s.
    pub fn message(w: Warning, arena: Allocator) Allocator.Error![]const u8 {
        return switch (w) {
            .ignored_for_local => |option| arena.print("{s} is ignored in local clones; use file:// instead.", .{option}),
            .filter_not_supported => "filtering not recognized by server, ignoring",
            .ssl_verify_disabled => |setting| arena.print("the server's certificate is not checked ({s})", .{setting}),
            .ssh_said => |text| text,
            .shallow_update_rejected => |name| arena.print("rejected {s} because shallow roots are not allowed to be updated", .{name}),
            .proxy_auth_method_unknown => |name| arena.print("unsupported proxy authentication method {s}: using anyauth", .{name}),
            .commit_graph_write_failed => |err| arena.print("commit-graph write failed: {s}", .{err}),
            .tag_known_as => |t| arena.print("tag '{s}' is externally known as '{s}'", .{ t.path, t.name }),
            .fsck => |f| arena.print("object {s}: {s}", .{ f.object, f.message }),
            .fsck_unknown_message => |name| arena.print("Skipping unknown msg id '{s}'", .{name}),
            .promisor => |text| text,
            .promisor_stored => |s| arena.print("Storing new {s} from server for remote '{s}'.\n    '{s}' -> '{s}'", .{ s.field, s.remote, s.old, s.new }),
            .credentials_in_url => |redacted| arena.print("URL '{s}' uses plaintext credentials", .{redacted}),
        };
    }
};

/// Warnings gathered over one operation.
pub const Warnings = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Warning) = .empty,

    /// An empty list.
    pub fn init(gpa: Allocator) Warnings {
        return .{ .arena = .init(gpa) };
    }

    /// Release every warning.
    pub fn deinit(w: *Warnings) void {
        w.arena.deinit();
        w.* = undefined;
    }

    /// Keep `warning`, with its text copied.
    pub fn add(w: *Warnings, warning: Warning) Allocator.Error!void {
        const a = w.arena.allocator();
        const owned: Warning = switch (warning) {
            .ignored_for_local => |t| .{ .ignored_for_local = try a.dupe(u8, t) },
            .filter_not_supported => .filter_not_supported,
            .ssl_verify_disabled => |t| .{ .ssl_verify_disabled = try a.dupe(u8, t) },
            .ssh_said => |t| .{ .ssh_said = try a.dupe(u8, t) },
            .shallow_update_rejected => |t| .{ .shallow_update_rejected = try a.dupe(u8, t) },
            .proxy_auth_method_unknown => |t| .{ .proxy_auth_method_unknown = try a.dupe(u8, t) },
            .commit_graph_write_failed => |err| .{ .commit_graph_write_failed = try a.dupe(u8, err) },
            .tag_known_as => |t| .{ .tag_known_as = .{ .path = try a.dupe(u8, t.path), .name = try a.dupe(u8, t.name) } },
            .fsck => |f| .{ .fsck = .{ .object = try a.dupe(u8, f.object), .message = try a.dupe(u8, f.message) } },
            .fsck_unknown_message => |t| .{ .fsck_unknown_message = try a.dupe(u8, t) },
            .promisor => |t| .{ .promisor = try a.dupe(u8, t) },
            .promisor_stored => |s| .{ .promisor_stored = .{ .field = try a.dupe(u8, s.field), .remote = try a.dupe(u8, s.remote), .old = try a.dupe(u8, s.old), .new = try a.dupe(u8, s.new) } },
            .credentials_in_url => |t| .{ .credentials_in_url = try a.dupe(u8, t) },
        };
        try w.items.append(a, owned);
    }
};

/// Keep `warning` in `to`, when there is somewhere to keep it.
pub fn note(to: ?*Warnings, warning: Warning) Allocator.Error!void {
    const w = to orelse return;
    try w.add(warning);
}

test "a warning is kept as a value and read as git words it" {
    var w: Warnings = .init(std.testing.allocator);
    defer w.deinit();
    var option = [_]u8{ '-', '-', 'd', 'e', 'p', 't', 'h' };
    try note(&w, .{ .ignored_for_local = &option });
    option[2] = 'x';
    try note(null, .filter_not_supported);
    try std.testing.expectEqual(@as(usize, 1), w.items.items.len);
    const text = try w.items.items[0].message(w.arena.allocator());
    try std.testing.expectEqualStrings("--depth is ignored in local clones; use file:// instead.", text);
}

/// All errors reported by this namespace.
pub const Error = Allocator.Error;
