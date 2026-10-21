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
    /// `http.version` names neither `HTTP/1.1` nor `HTTP/2`: the value.
    http_version_unknown: []const u8,
    /// `http.sslVersion` or `GIT_SSL_VERSION` names a version curl does
    /// not know, and the default is used: the value.
    ssl_version_unknown: []const u8,
    /// A clone's `bundle_uri` brought nothing in; the clone went on
    /// without it.
    bundle_uri_clone_failed: []const u8,
    /// `fetch.bundleURI` brought nothing in; the fetch went on without it.
    bundle_uri_fetch_failed: []const u8,
    /// The bundles a server listed for a clone under `transfer.bundleURI`
    /// brought nothing in; the clone went on without them.
    advertised_bundles_failed,
    /// What git says of one bundle URI on the way and goes on from: a
    /// download that failed, a file that is neither a bundle nor a list, a
    /// `creationToken` that does not parse, a server's list it could not
    /// read. The text.
    bundle_uri: []const u8,
    /// `http.cookieFile` is `-`, curl's standard input, which git does not
    /// read cookies from.
    cookie_file_stdin,
    /// `http.saveCookies` without a `http.cookieFile` to save to.
    save_cookies_without_file,
    /// One of `GIT_HTTP_LOW_SPEED_LIMIT`, `GIT_HTTP_LOW_SPEED_TIME`,
    /// `GIT_HTTP_RETRY_AFTER`, `GIT_HTTP_MAX_RETRIES` and
    /// `GIT_HTTP_MAX_RETRY_TIME` is not a number, and was left out: its name.
    http_env_unparsed: []const u8,
    /// A server answered 429, and the request goes again after this many
    /// seconds.
    rate_limited: u64,
    /// A remote URL carries a password, and `transfer.credentialsInUrl`
    /// is `warn`: the URL, its password replaced by `<redacted>`.
    credentials_in_url: []const u8,
    /// What git warns of in a remote helper's answers: the text.
    remote_helper: []const u8,
    /// What git warns of while reading which notes follow a rewritten
    /// commit: a `notes.rewriteRef` outside `refs/notes/`, or naming no
    /// ref. The text.
    notes: []const u8,
    /// A pull's fetch moved the branch checked out, and the working tree
    /// was brought along from the commit it was at: its name.
    pull_moved_head: []const u8,
    /// A pull that rebases was asked to verify signatures, which only a
    /// merge does.
    verify_signatures_ignored_for_rebase,

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
            .remote_helper => |text| text,
            .notes => |text| text,
            .pull_moved_head => |hex| arena.print("fetch updated the current branch head.\nfast-forwarding your working tree from\ncommit {s}.", .{hex}),
            .verify_signatures_ignored_for_rebase => "ignoring --verify-signatures for rebase",
            .http_version_unknown => |v| arena.print("unknown value given to http.version: '{s}'", .{v}),
            .ssl_version_unknown => |v| arena.print("unsupported ssl version {s}: using default", .{v}),
            .bundle_uri_clone_failed => |v| arena.print("failed to fetch objects from bundle URI '{s}'", .{v}),
            .bundle_uri_fetch_failed => |v| arena.print("failed to fetch bundles from '{s}'", .{v}),
            .advertised_bundles_failed => "failed to fetch advertised bundles",
            .bundle_uri => |text| text,
            .cookie_file_stdin => "refusing to read cookies from http.cookiefile '-'",
            .save_cookies_without_file => "ignoring http.savecookies for empty http.cookiefile",
            .http_env_unparsed => |name| arena.print("failed to parse {s}", .{name}),
            .rate_limited => |seconds| arena.print("rate limited, waiting {d} seconds before retry", .{seconds}),
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
            .remote_helper => |t| .{ .remote_helper = try a.dupe(u8, t) },
            .notes => |t| .{ .notes = try a.dupe(u8, t) },
            .pull_moved_head => |t| .{ .pull_moved_head = try a.dupe(u8, t) },
            .verify_signatures_ignored_for_rebase => .verify_signatures_ignored_for_rebase,
            .http_version_unknown => |t| .{ .http_version_unknown = try a.dupe(u8, t) },
            .ssl_version_unknown => |t| .{ .ssl_version_unknown = try a.dupe(u8, t) },
            .bundle_uri_clone_failed => |t| .{ .bundle_uri_clone_failed = try a.dupe(u8, t) },
            .bundle_uri_fetch_failed => |t| .{ .bundle_uri_fetch_failed = try a.dupe(u8, t) },
            .advertised_bundles_failed => .advertised_bundles_failed,
            .bundle_uri => |t| .{ .bundle_uri = try a.dupe(u8, t) },
            .cookie_file_stdin => .cookie_file_stdin,
            .save_cookies_without_file => .save_cookies_without_file,
            .http_env_unparsed => |t| .{ .http_env_unparsed = try a.dupe(u8, t) },
            .rate_limited => |n| .{ .rate_limited = n },
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
