//! Why a remote would not let this client in, in the terms a person needs
//! to put it right.
//!
//! git answers a refused credential with one line — `Authentication failed
//! for '<url>'` — and leaves the person to work out whether the token
//! expired, the helper had nothing, the key was not offered, or the server
//! explained itself in a line they scrolled past. A program with a screen
//! of its own can do better, if it is told what happened as values rather
//! than as a sentence: which URL, over which transport, which helpers were
//! asked and what each said, whether there was any way to ask the person,
//! and what the server itself said. A `Failure` is that, filled in when an
//! operation handed one fails for want of a credential, and empty
//! otherwise.
//!
//! It never holds a password or a token: only a username, which is what a
//! person needs to recognise which account was refused.

const std = @import("std");
const Allocator = std.mem.Allocator;

const url_mod = @import("url.zig");

/// A refused or impossible authentication, described.
pub const Failure = struct {
    arena: ?std.heap.ArenaAllocator = null,
    /// What went wrong. `.none` while nothing has.
    reason: Reason = .none,
    /// The remote, with any credential the URL carried taken out.
    url: []const u8 = "",
    /// How the remote was reached.
    scheme: url_mod.Scheme = .local,
    /// Every credential helper asked, in the order asked.
    helpers: []const Helper = &.{},
    /// Whether the caller gave a way to ask the person — a `Prompt` —
    /// when no helper had the answer.
    prompt_available: bool = false,
    /// Whether the person was asked, through askpass or the caller's
    /// prompt.
    prompted: bool = false,
    /// Where the credential that was refused came from.
    source: Source = .none,
    /// The username that was refused, when there was one.
    username: ?[]const u8 = null,
    /// The HTTP status of the refusal: 401 or 403.
    status: ?u16 = null,
    /// What the server said, a line to a line: a forge's `text/plain`
    /// explanation of a 401 or a 403, or the lines `ssh` wrote. It is the
    /// remote's text; a caller showing it should treat it as untrusted.
    server_message: []const u8 = "",
    /// The schemes the server offered, from its `WWW-Authenticate`
    /// headers: `Basic realm="…"`, `Bearer`.
    challenges: []const []const u8 = &.{},

    /// Why the operation could not authenticate.
    pub const Reason = enum {
        none,
        /// The server refused the credential it was given (HTTP 401 with a
        /// credential, or `ssh` reporting `Permission denied`).
        refused,
        /// The server accepted who it was and refused the operation: HTTP
        /// 403, a token without the permission.
        forbidden,
        /// No helper had a credential and there was no way to ask the
        /// person: no `Prompt` was given.
        no_credential,
        /// The person was asked and declined.
        declined,
        /// A helper answered `quit=1`, which ends the search.
        helper_quit,
        /// A helper is configured and the caller gave no `Programs` to run
        /// it with.
        programs_not_granted,
        /// `ssh` did not know the server's host key, or it had changed.
        host_key,
    };

    /// Where a credential came from.
    pub const Source = enum { none, url, helper, prompt };

    /// One helper asked for a credential.
    pub const Helper = struct {
        /// The helper as configured: `osxkeychain`, `!gh auth
        /// git-credential`, `/usr/local/bin/helper`.
        command: []const u8,
        answer: Answer,
    };

    /// What a helper answered to `get`.
    pub const Answer = enum {
        /// A whole credential.
        credential,
        /// Part of one — a username — and the search went on.
        partial,
        /// Nothing it knew.
        nothing,
        /// `quit=1`.
        quit,
        /// It could not be run, or exited with a failure.
        failed,
    };

    /// Release what the failure holds. A failure that was never filled
    /// holds nothing.
    pub fn deinit(f: *Failure) void {
        if (f.arena) |*a| a.deinit();
        f.* = .{};
    }

    /// Start describing a failure: what was there before is released.
    /// `url` is anonymized here.
    pub fn begin(f: *Failure, gpa: Allocator, reason: Reason, scheme: url_mod.Scheme, url: []const u8) Allocator.Error!void {
        f.deinit();
        f.arena = .init(gpa);
        f.reason = reason;
        f.scheme = scheme;
        f.url = try url_mod.anonymize(f.allocator(), url);
    }

    /// The failure's own allocator, for the values `begin` did not set.
    /// Valid after `begin`.
    pub fn allocator(f: *Failure) Allocator {
        return f.arena.?.allocator();
    }

    /// Keep `text` as the server's message, cut at 4 KiB.
    pub fn setServerMessage(f: *Failure, text: []const u8) Allocator.Error!void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        f.server_message = try f.allocator().dupe(u8, trimmed[0..@min(trimmed.len, 4096)]);
    }
};

test "a failure keeps no credential in its URL and releases what it holds" {
    var f: Failure = .{};
    defer f.deinit();
    try f.begin(std.testing.allocator, .refused, .https, "https://ada:hunter2@git.example.com/repo.git");
    try std.testing.expectEqualStrings("https://git.example.com/repo.git", f.url);
    try f.setServerMessage("  Invalid username or token.\n");
    try std.testing.expectEqualStrings("Invalid username or token.", f.server_message);
    // Beginning again starts from nothing.
    try f.begin(std.testing.allocator, .host_key, .ssh, "git@example.com:repo.git");
    try std.testing.expectEqualStrings("", f.server_message);
    try std.testing.expectEqualStrings("example.com:repo.git", f.url);
}
