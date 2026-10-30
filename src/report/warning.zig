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
const aegis = @import("aegis");
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
    /// What git says of an alternate a dumb HTTP server names, which it
    /// borrows from or passes over: the text.
    dumb_alternate: []const u8,
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
    /// A server answered 429, and the request goes again after this long.
    rate_limited: aegis.units.Duration(.second, u64),
    /// A remote URL carries a password, and `transfer.credentialsInUrl`
    /// is `warn`: the URL, its password replaced by `<redacted>`.
    credentials_in_url: []const u8,
    /// What git warns of in a remote helper's answers: the text.
    remote_helper: []const u8,
    /// A push asked to be signed only if the server asks, and it did not:
    /// sent unsigned.
    push_cert_not_asked,
    /// `core.alternateRefsCommand` printed a line that is not an object's
    /// name, and what it printed after was not read: the line.
    alternate_refs_line: []const u8,
    /// A negotiation tip's pattern matched no ref, and was ignored: the
    /// setting or option it came from, and the pattern.
    negotiation_tip_unmatched: struct { from: []const u8, pattern: []const u8 },
    /// A gitlink a fetched commit changes, at a path `.gitmodules` does not
    /// name but whose stand-in name, the path, it gives another submodule:
    /// left out of the fetch's recursion. The commit and the path.
    submodule_name_collides: struct { commit: []const u8, path: []const u8 },
    /// A submodule the fetched history moves, active at the commit that
    /// moves it, with no repository anywhere: git's "Could not access
    /// submodule", which does not fail the fetch. The path and the commit.
    submodule_not_accessible: struct { path: []const u8, commit: []const u8 },
    /// A `--reference-if-able` that cannot lend, left out: the path and
    /// why, in git's words.
    alternate_not_added: struct { path: []const u8, reason: []const u8 },
    /// A superproject's lender whose `modules/<name>` cannot lend, left
    /// out under `submodule.alternateErrorStrategy=info`: the submodule's
    /// name and why.
    submodule_alternate_not_added: struct { name: []const u8, reason: []const u8 },
    /// A submodule path whose recorded commits no remote of its own has,
    /// which stops a push.
    submodule_unpushed: []const u8,
    /// A submodule whose clone failed, tried once more after the others,
    /// as git's `update_clone` retries it: its path in the index.
    submodule_clone_retried: []const u8,
    /// A submodule path whose push, made for the superproject's, failed.
    submodule_push_failed: []const u8,
    /// `push.recurseSubmodules=only` in a submodule pushed for its
    /// superproject, taken as `on-demand`.
    push_recurse_only_on_demand,
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
    /// `followRemoteHEAD = warn`: the remote's `HEAD` names the branch
    /// `head`, and `refs/remotes/<remote>/HEAD` another, `local`.
    remote_head_differs: struct { remote: []const u8, head: []const u8, local: []const u8 },
    /// `followRemoteHEAD = warn`: the remote's `HEAD` names the branch
    /// `head`, and `refs/remotes/<remote>/HEAD` is no symbolic ref but the
    /// object `oid` (hex).
    remote_head_detached: struct { remote: []const u8, head: []const u8, oid: []const u8 },
    /// `promisor.acceptFromServerUrl` configured a remote the server
    /// advertised.
    promisor_auto_created: struct { name: []const u8, url: []const u8 },
    /// `remote.<name>.followRemoteHEAD` names no setting git knows, and is
    /// passed over: the value.
    follow_remote_head_unknown: []const u8,
    /// `fetch.followRemoteHEAD` names no setting git knows, and is passed
    /// over: the value.
    fetch_follow_remote_head_unknown: []const u8,

    /// The text git prints after `warning: ` for it, where git prints one.
    /// The result is `arena`'s.
    pub fn message(w: Warning, arena: Allocator) Allocator.Error![]const u8 {
        return switch (w) {
            .ignored_for_local => |option| arena.print("{s} is ignored in local clones; use file:// instead.", .{option}),
            .filter_not_supported => "filtering not recognized by server, ignoring",
            .ssl_verify_disabled => |setting| arena.print("the server's certificate is not checked ({s})", .{setting}),
            .ssh_said => |text| text,
            .dumb_alternate => |text| text,
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
            .remote_head_differs => |h| arena.print("'HEAD' at '{s}' is '{s}', but we have '{s}' locally.", .{ h.remote, h.head, h.local }),
            .remote_head_detached => |h| arena.print("'HEAD' at '{s}' is '{s}', but we have a detached HEAD pointing to '{s}' locally.", .{ h.remote, h.head, h.oid }),
            .promisor_auto_created => |c| arena.print("Auto-creating promisor remote '{s}' for URL '{s}'", .{ c.name, c.url }),
            .follow_remote_head_unknown => |v| arena.print("unrecognized followRemoteHEAD value '{s}' ignored", .{v}),
            .fetch_follow_remote_head_unknown => |v| arena.print("unrecognized fetch.followRemoteHEAD value '{s}' ignored", .{v}),
            .push_cert_not_asked => "not sending a push certificate since the receiving end does not support --signed push",
            .alternate_refs_line => |text| arena.print("invalid line while parsing alternate refs: {s}", .{text}),
            .negotiation_tip_unmatched => |t| arena.print("ignoring {s}={s} because it does not match any refs", .{ t.from, t.pattern }),
            .submodule_name_collides => |t| arena.print("Submodule in commit {s} at path: '{s}' collides with a submodule named the same. Skipping it.", .{ t.commit, t.path }),
            .submodule_not_accessible => |t| arena.print("Could not access submodule '{s}' at commit {s}", .{ t.path, t.commit }),
            .alternate_not_added => |t| arena.print("info: Could not add alternate for '{s}': {s}", .{ t.path, t.reason }),
            .submodule_alternate_not_added => |t| arena.print("submodule '{s}' cannot add alternate: {s}", .{ t.name, t.reason }),
            .submodule_clone_retried => |t| arena.print("Failed to clone '{s}'. Retry scheduled", .{t}),
            .submodule_unpushed => |t| arena.print("submodule path '{s}' contains changes that can not be found on any remote", .{t}),
            .submodule_push_failed => |t| arena.print("Unable to push submodule '{s}'", .{t}),
            .push_recurse_only_on_demand => "recursing into submodule with push.recurseSubmodules=only; using on-demand instead",
            .http_version_unknown => |v| arena.print("unknown value given to http.version: '{s}'", .{v}),
            .ssl_version_unknown => |v| arena.print("unsupported ssl version {s}: using default", .{v}),
            .bundle_uri_clone_failed => |v| arena.print("failed to fetch objects from bundle URI '{s}'", .{v}),
            .bundle_uri_fetch_failed => |v| arena.print("failed to fetch bundles from '{s}'", .{v}),
            .advertised_bundles_failed => "failed to fetch advertised bundles",
            .bundle_uri => |text| text,
            .cookie_file_stdin => "refusing to read cookies from http.cookiefile '-'",
            .save_cookies_without_file => "ignoring http.savecookies for empty http.cookiefile",
            .http_env_unparsed => |name| arena.print("failed to parse {s}", .{name}),
            .rate_limited => |wait| arena.print("rate limited, waiting {d} seconds before retry", .{wait.raw()}),
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
            .dumb_alternate => |t| .{ .dumb_alternate = try a.dupe(u8, t) },
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
            .remote_head_differs => |h| .{ .remote_head_differs = .{ .remote = try a.dupe(u8, h.remote), .head = try a.dupe(u8, h.head), .local = try a.dupe(u8, h.local) } },
            .remote_head_detached => |h| .{ .remote_head_detached = .{ .remote = try a.dupe(u8, h.remote), .head = try a.dupe(u8, h.head), .oid = try a.dupe(u8, h.oid) } },
            .promisor_auto_created => |c| .{ .promisor_auto_created = .{ .name = try a.dupe(u8, c.name), .url = try a.dupe(u8, c.url) } },
            .follow_remote_head_unknown => |t| .{ .follow_remote_head_unknown = try a.dupe(u8, t) },
            .fetch_follow_remote_head_unknown => |t| .{ .fetch_follow_remote_head_unknown = try a.dupe(u8, t) },
            .push_cert_not_asked => .push_cert_not_asked,
            .alternate_refs_line => |t| .{ .alternate_refs_line = try a.dupe(u8, t) },
            .negotiation_tip_unmatched => |t| .{ .negotiation_tip_unmatched = .{ .from = try a.dupe(u8, t.from), .pattern = try a.dupe(u8, t.pattern) } },
            .submodule_name_collides => |t| .{ .submodule_name_collides = .{ .commit = try a.dupe(u8, t.commit), .path = try a.dupe(u8, t.path) } },
            .submodule_not_accessible => |t| .{ .submodule_not_accessible = .{ .path = try a.dupe(u8, t.path), .commit = try a.dupe(u8, t.commit) } },
            .alternate_not_added => |t| .{ .alternate_not_added = .{ .path = try a.dupe(u8, t.path), .reason = try a.dupe(u8, t.reason) } },
            .submodule_alternate_not_added => |t| .{ .submodule_alternate_not_added = .{ .name = try a.dupe(u8, t.name), .reason = try a.dupe(u8, t.reason) } },
            .submodule_clone_retried => |t| .{ .submodule_clone_retried = try a.dupe(u8, t) },
            .submodule_unpushed => |t| .{ .submodule_unpushed = try a.dupe(u8, t) },
            .submodule_push_failed => |t| .{ .submodule_push_failed = try a.dupe(u8, t) },
            .push_recurse_only_on_demand => .push_recurse_only_on_demand,
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
