//! Credentials for an HTTP remote: git's credential helper protocol, and the
//! prompt git falls back to, as git's `credential.c` has them.
//!
//! relic stores nothing and caches nothing; the person's helpers do. A
//! credential is the parts git keeps — protocol, host, path, username,
//! password — read from the remote's URL as `credential_from_url` reads
//! them. When a server answers 401 it is filled the way `credential_fill`
//! fills it: a username and password the URL carries are used as they are;
//! otherwise each configured `credential.helper` is asked, in order, until
//! one has a credential; otherwise what is still missing is asked for — but
//! only through the caller's `Prompt`, which stands in for the terminal git
//! would use, and through the person's askpass program only when that
//! prompt says so. A library in a daemon or an editor must not put a
//! question in front of a person its caller did not ask for. A credential
//! that then works is handed to every helper to `store`; one that does not
//! is handed to every helper to `erase`.
//!
//! A helper is `!<command line>`, an absolute path, or a name, which is
//! `git credential-<name>` — `osxkeychain`, `manager`, `store`, `cache`,
//! `libsecret` — each run with the operation appended through a shell,
//! exactly as git runs one. It reads `key=value` lines and answers with
//! them. `store`, git's own, relic runs itself (`credential/store.zig`),
//! when its words are ones the shell would hand over as written, so no git
//! need be there for it. The `credential.*` settings are read once for a credential, when it
//! is first filled, stored or erased: every `credential.<url>.*` whose URL
//! matches by git's urlmatch, all of them in order, and for a pattern git
//! cannot normalize — `credential.github.com` — the parts it has compared
//! exactly; a `helper` set to nothing clears the list before it, which is
//! how `gh auth setup-git` puts itself first for one host.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const SecretBytes = aegis.SecretBytes;
const decimal = @import("../text.zig").decimal;
const date = @import("../text.zig").date;
const parts_mod = @import("credential/parts.zig");
const UrlParts = parts_mod.UrlParts;
const UrlError = parts_mod.UrlError;
const store_mod = @import("credential/store.zig");
/// git's `credential-cache` client; its daemon is `cache/daemon.zig`'s, which
/// the wire facade names.
pub const cache = @import("credential/cache.zig");
const urlmatch = @import("../text.zig").urlmatch;
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("../config/config.zig");
const program = @import("../process.zig").program;
const url_mod = @import("url.zig");
const auth = @import("auth.zig");

/// Errors from filling, storing or erasing a credential.
pub const Error = error{
    /// A helper answered `quit=1`, which ends the search.
    CredentialHelperQuit,
    /// No helper had the credential, and there was nothing to ask: the
    /// caller gave no `Prompt`, or `credential.interactive` says not to.
    CredentialsUnavailable,
    /// A helper, or an askpass program, is configured and the caller handed
    /// in no `program.Programs` to run it with.
    ProgramsNotGranted,
    /// A value that would be handed to a helper holds a newline — or a
    /// carriage return, unless `credential.protectProtocol` is false — which
    /// would let it write a line of its own: a `host=` that asks for another
    /// host's credential. git dies on it in `credential_write_item`, and
    /// refuses a URL whose user, password, host or path decodes to a
    /// newline.
    CredentialValueUnsafe,
    /// A `credential.*` setting git dies on: one with no value, or a
    /// `useHttpPath`, `sanitizePrompt` or `protectProtocol` that is not a
    /// boolean.
    InvalidCredentialSetting,
    /// A helper's answer git dies on: `quit`, `continue` or `ephemeral`
    /// that is not a boolean, or a `url` that has no scheme or decodes to
    /// a newline.
    InvalidCredentialAnswer,
} || program.Error;

/// What is asked for.
pub const Field = enum { username, password };

/// The caller's stand-in for a terminal prompt, and the only way relic ever
/// asks the person anything. Without one, a credential no helper has is
/// `error.CredentialsUnavailable`, and no window or question appears.
pub const Prompt = struct {
    context: ?*anyopaque = null,
    /// Run the person's askpass program first — `GIT_ASKPASS`, then
    /// `core.askPass`, then `SSH_ASKPASS` — as git does before it falls
    /// back to the terminal. Off, askpass is never run: an askpass is a
    /// window in front of the person, and only the caller knows whether
    /// one is welcome.
    askpass: bool = false,
    /// Answer `field` for the prompt text git would show —
    /// `Username for 'https://example.com': ` — by writing it to `answer`
    /// and returning true, or decline with false. `answer` keeps what it is
    /// given in storage that is wiped when it grows and when it is let go,
    /// so a password written straight to it is held nowhere else; it fails
    /// only for want of memory, as the caller may. `null` here asks nothing
    /// beyond askpass.
    ask: ?*const fn (context: ?*anyopaque, field: Field, prompt: []const u8, answer: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!bool = null,
};

/// What `fill` needs besides the URL.
pub const Options = struct {
    config: ?*const config_mod.Config = null,
    programs: ?program.Programs = null,
    prompt: ?Prompt = null,
    /// The time, in seconds since the epoch, by the caller's clock: a
    /// helper's password whose `password_expiry_utc` is before it is
    /// neither used nor stored, as git uses and stores neither. `null`
    /// checks nothing; relic reads no clock of its own.
    now: ?std.Io.Timestamp = null,
    /// How a daemon starts where the `cache` helper stores a credential
    /// and finds none listening. `null` starts git's, `git
    /// credential-cache--daemon`, through `programs`, as git does; a caller
    /// with no git hands relic's own (`credential_cache_daemon.InProcess`).
    cache_daemon: ?cache.Starter = null,
};

/// The parts of a credential a caller names itself, rather than through a
/// URL git reads: what git-lfs hands `git credential fill`.
pub const Parts = struct {
    protocol: []const u8,
    host: []const u8,
    path: ?[]const u8 = null,
    username: ?[]const u8 = null,
};

/// git's `TIME_MAX`: a password with no expiry.
const no_expiry: u64 = std.math.maxInt(u64);

/// The credential for one URL, over the life of one conversation.
///
/// It speaks git's helper protocol as git 2.55 speaks it, capabilities
/// included: a helper may answer with a username and password, or — having
/// said `capability[]=authtype` — with an `authtype` and a `credential`
/// that become the `Authorization` header as they are, which is how a
/// bearer token arrives, and with `continue=1` for a conversation of more
/// than one round; `state[]` values and the token's `oauth_refresh_token`
/// and `password_expiry_utc` are handed back to the helpers with the next
/// question, `store` and `erase`, as git hands them back.
pub const Session = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    /// The URL the credential is for. Its parts are read, at first use,
    /// from its text as git's `credential_from_url` reads them.
    url: url_mod.Url,
    /// Where the parts come from: the URL, the passphrase of a client
    /// certificate's key, or parts the caller named.
    origin: Origin = .url,

    // git's `struct credential`.
    protocol: ?[]u8 = null,
    host: ?[]u8 = null,
    path: ?[]u8 = null,
    username: ?[]u8 = null,
    /// The secrets, each in an owner that wipes its bytes when let go.
    password: ?SecretBytes = null,
    /// `authtype` and `credential`, from a helper that announced the
    /// `authtype` capability.
    authtype: ?[]u8 = null,
    credential: ?SecretBytes = null,
    oauth_refresh_token: ?SecretBytes = null,
    password_expiry_utc: u64 = no_expiry,
    ephemeral: bool = false,
    /// A helper answered `continue=1`: a refusal of this credential is the
    /// next round of its conversation, not the end of it.
    multistage: bool = false,
    quit: bool = false,
    /// Whether the username came from the URL or a helper, which
    /// `credential.username` does not override: git's
    /// `username_from_proto`.
    username_from_url: bool = false,
    approved: bool = false,
    capa_authtype: Capability = .{},
    capa_state: Capability = .{},
    /// `state[]` values the helpers answered with, handed back at the next
    /// fill, store or erase.
    state: std.ArrayList([]u8) = .empty,
    state_to_send: std.ArrayList([]u8) = .empty,
    /// The server's `WWW-Authenticate` values from its last refusal, which
    /// git hands every helper, and any a helper added.
    challenges: std.ArrayList([]u8) = .empty,
    /// The `credential.*` settings, read once: git's `configured`.
    settings: ?Settings = null,
    /// The `Authorization` header's value, made from the secrets.
    header: ?SecretBytes = null,
    initialised: bool = false,
    /// The URL's parts hold a newline: nothing is filled for it.
    unsafe_url: bool = false,
    /// Where the credential in hand came from.
    source: auth.Failure.Source = .none,
    /// Every helper asked, for a failure's description.
    asked: std.ArrayList(auth.Failure.Helper) = .empty,
    /// Whether the person was asked.
    prompted: bool = false,
    /// The username of the last credential refused, for a failure's
    /// description; `reject` forgets the rest.
    refused_username: ?[]u8 = null,
    /// Where the refused credential came from.
    refused_source: auth.Failure.Source = .none,

    /// Where a session's parts come from.
    pub const Origin = union(enum) {
        /// The URL's text, as git's `credential_from_url` reads it.
        url,
        /// The passphrase of the key of the certificate at this path, which
        /// git asks the helpers for as `protocol=cert`, an empty host and
        /// username, and the path, with no capabilities.
        certificate: []const u8,
        /// Parts the caller named, borrowed until the session first uses
        /// them.
        parts: Parts,
        /// None but what `readAnswer` reads: a request to a cache daemon.
        request,
    };

    /// Which side of a conversation announced a capability: git's
    /// `credential_capability`.
    const Capability = struct {
        /// The caller can take it: relic, over HTTP, always.
        initial: bool = false,
        /// The helper that answered announced it.
        helper: bool = false,
    };

    /// A session for the passphrase of the key of the certificate at
    /// `path`, as git's `has_cert_password` asks for it.
    pub fn forCertificate(gpa: Allocator, path: []const u8) Session {
        return .{ .gpa = gpa, .url = .{ .scheme = .https, .path = path, .raw = path }, .origin = .{ .certificate = path } };
    }

    /// A session for `url` whose parts the caller names, as git-lfs names
    /// them to `git credential fill`. `parts` is borrowed until the session
    /// is first used.
    pub fn forParts(gpa: Allocator, url: url_mod.Url, parts: Parts) Session {
        return .{ .gpa = gpa, .url = url, .origin = .{ .parts = parts } };
    }

    /// A credential with no URL, made of the lines `readAnswer` reads, as
    /// git's cache daemon reads a client's request.
    pub fn forRequest(gpa: Allocator) Session {
        return .{ .gpa = gpa, .url = .{ .scheme = .local, .path = "", .raw = "" }, .origin = .request };
    }

    /// Forget the credential, clearing its bytes, and release everything.
    pub fn deinit(s: *Session) void {
        s.clearAll();
        s.challenges.deinit(s.gpa);
        s.state.deinit(s.gpa);
        s.state_to_send.deinit(s.gpa);
        for (s.asked.items) |h| s.gpa.free(h.command);
        s.asked.deinit(s.gpa);
        if (s.refused_username) |u| s.gpa.free(u);
        s.* = undefined;
    }

    /// Let a secret go, wiping its bytes.
    fn wipe(slot: *?SecretBytes) void {
        if (slot.*) |*secret| secret.deinit();
        slot.* = null;
    }

    /// A secret's bytes, borrowed until it is let go or replaced.
    fn reveal(slot: *const ?SecretBytes) ?[]const u8 {
        return if (slot.*) |*secret| secret.expose() else null;
    }

    /// The password, for a caller that hands it on: a key's passphrase,
    /// git-lfs's `credential fill` answer.
    pub fn exposePassword(s: *const Session) ?[]const u8 {
        return reveal(&s.password);
    }

    fn freeList(gpa: Allocator, list: *std.ArrayList([]u8)) void {
        for (list.items) |v| gpa.free(v);
        list.clearRetainingCapacity();
    }

    /// git's `credential_clear_secrets`.
    fn clearSecrets(s: *Session) void {
        wipe(&s.password);
        wipe(&s.credential);
        wipe(&s.header);
    }

    /// git's `credential_clear`: every part, setting and capability, as
    /// a fresh credential has them.
    fn clearAll(s: *Session) void {
        s.clearSecrets();
        inline for (.{ "protocol", "host", "path", "username", "authtype" }) |name| {
            if (@field(s, name)) |v| s.gpa.free(v);
            @field(s, name) = null;
        }
        wipe(&s.oauth_refresh_token);
        if (s.settings) |*settings| settings.deinit(s.gpa);
        s.settings = null;
        freeList(s.gpa, &s.challenges);
        freeList(s.gpa, &s.state);
        freeList(s.gpa, &s.state_to_send);
        s.password_expiry_utc = no_expiry;
        s.ephemeral = false;
        s.multistage = false;
        s.quit = false;
        s.username_from_url = false;
        s.approved = false;
        s.capa_authtype = .{};
        s.capa_state = .{};
    }

    /// Keep the server's `WWW-Authenticate` values from a refusal, for
    /// the helpers; an answer with none clears them, as git clears them.
    pub fn setChallenges(s: *Session, values: []const []const u8) Allocator.Error!void {
        freeList(s.gpa, &s.challenges);
        for (values) |v| {
            const owned = try s.gpa.dupe(u8, v);
            errdefer s.gpa.free(owned);
            try s.challenges.append(s.gpa, owned);
        }
    }

    fn fromOrigin(s: *Session) Self.Error!void {
        if (s.initialised) return if (s.unsafe_url) error.CredentialValueUnsafe;
        s.initialised = true;
        s.readOrigin() catch |err| {
            if (err == error.CredentialValueUnsafe) s.unsafe_url = true;
            return err;
        };
    }

    fn readOrigin(s: *Session) Self.Error!void {
        switch (s.origin) {
            .url => s.takeParts(s.url.raw) catch |err| switch (err) {
                // A URL relic reaches always names its scheme.
                error.NoScheme => return error.CredentialValueUnsafe,
                else => |e| return e,
            },
            .certificate => |path| {
                // git's `cert_auth`: an empty host and username.
                s.protocol = try s.gpa.dupe(u8, "cert");
                s.host = try s.gpa.dupe(u8, "");
                s.username = try s.gpa.dupe(u8, "");
                s.path = try s.gpa.dupe(u8, path);
            },
            .parts => |parts| {
                // As `credential_read` takes them from git-lfs.
                s.protocol = try s.gpa.dupe(u8, parts.protocol);
                s.host = try s.gpa.dupe(u8, parts.host);
                if (parts.path) |p| s.path = try s.gpa.dupe(u8, p);
                if (parts.username) |u| {
                    s.username = try s.gpa.dupe(u8, u);
                    s.username_from_url = true;
                }
            },
            .request => {},
        }
        if (s.username != null and s.password != null) s.source = .url;
    }

    /// git's `credential_from_url`: the credential cleared and its parts
    /// read from `text`.
    fn takeUrl(s: *Session, text: []const u8) (UrlError || Allocator.Error)!void {
        s.clearAll();
        try s.takeParts(text);
    }

    fn takeParts(s: *Session, text: []const u8) (UrlError || Allocator.Error)!void {
        var parts = try UrlParts.read(s.gpa, text, false);
        errdefer parts.deinit(s.gpa);
        s.protocol = parts.protocol;
        s.host = parts.host;
        s.path = parts.path;
        s.username = parts.username;
        s.password = parts.password;
        s.username_from_url = parts.username_from_url;
    }

    fn hasCredential(s: *const Session) bool {
        return (s.username != null and s.password != null) or s.credential != null;
    }

    /// The `Authorization` header's value, when a credential is known:
    /// `<authtype> <credential>` from a helper that gave one, else
    /// `Basic` over the username and password.
    pub fn authorization(s: *Session) ?[]const u8 {
        s.fromOrigin() catch return null;
        if (reveal(&s.header)) |h| return h;
        if (s.authtype) |kind| if (reveal(&s.credential)) |value| {
            var header = SecretBytes.init(s.gpa, kind.len + 1 + value.len) catch return null;
            parts_mod.appendParts(&header, &.{ kind, " ", value }) catch {
                header.deinit();
                return null;
            };
            s.header = header;
            return reveal(&s.header);
        };
        const user = s.username orelse return null;
        const password = reveal(&s.password) orelse return null;
        const encoder = std.base64.standard.Encoder;
        const plain_len = user.len + 1 + password.len;
        var plain_secret = SecretBytes.init(s.gpa, plain_len) catch return null;
        defer plain_secret.deinit();
        // unreachable: the owner was made with exactly this capacity.
        plain_secret.resizeWithinCapacity(plain_len) catch unreachable;
        const plain = plain_secret.exposeMut();
        @memcpy(plain[0..user.len], user);
        plain[user.len] = ':';
        @memcpy(plain[user.len + 1 ..], password);
        const header_len = "Basic ".len + encoder.calcSize(plain_len);
        var header = SecretBytes.init(s.gpa, header_len) catch return null;
        // unreachable: the owner was made with exactly this capacity.
        header.resizeWithinCapacity(header_len) catch unreachable;
        const text = header.exposeMut();
        @memcpy(text[0.."Basic ".len], "Basic ");
        _ = encoder.encode(text["Basic ".len..], plain);
        s.header = header;
        return reveal(&s.header);
    }

    /// Whether a credential is in hand before any helper was asked: the
    /// one the URL carries.
    pub fn hasInitial(s: *Session) bool {
        s.fromOrigin() catch return false;
        return s.hasCredential();
    }

    /// git's `credential_next_state`: the state the helpers last answered
    /// with is what is handed to them next.
    fn nextState(s: *Session) void {
        freeList(s.gpa, &s.state_to_send);
        std.mem.swap(std.ArrayList([]u8), &s.state, &s.state_to_send);
    }

    /// Fill in what is missing, after the server asked for it, as git's
    /// `credential_fill` fills it. Returns whether a credential is now
    /// known; `false` means the person was asked and declined.
    pub fn fill(s: *Session, io: Io, opts: Options) Self.Error!bool {
        try s.fromOrigin();
        wipe(&s.header);
        if (s.hasCredential()) return true;
        s.nextState();
        s.multistage = false;
        try s.configure(opts.config);
        // Over HTTP git can take both; for a certificate's passphrase it
        // announces neither.
        if (s.origin != .certificate) {
            s.capa_authtype.initial = true;
            s.capa_state.initial = true;
        }

        var i: usize = 0;
        while (s.settings) |settings| : (i += 1) {
            // A helper's `url=` starts the credential over, with no
            // helpers left to ask.
            if (i >= settings.helpers.len) break;
            var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
            defer arena_state.deinit();
            // The answer may take the settings away with the list.
            const helper = try arena_state.allocator().dupe(u8, settings.helpers[i]);
            const programs = opts.programs orelse {
                try s.noteAsked(helper, .failed);
                return error.ProgramsNotGranted;
            };
            const outcome = try s.runHelper(arena_state.allocator(), io, programs, opts.cache_daemon, helper, .get);
            s.dropExpired(opts.now);
            const answer: auth.Failure.Answer = if (s.quit) .quit else if (s.hasCredential()) .credential else if (outcome.any) .partial else if (outcome.failed) .failed else .nothing;
            try s.noteAsked(helper, answer);
            if (s.hasCredential()) {
                freeList(s.gpa, &s.challenges);
                s.source = .helper;
                return true;
            }
            if (s.quit) return error.CredentialHelperQuit;
        }

        // Ask for what is still missing, as git's `credential_getpass`.
        if (!interactive(opts.config)) return error.CredentialsUnavailable;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (s.username == null) {
            const prompt = try s.promptText(arena, "Username");
            var said = try s.ask(io, opts, .username, prompt) orelse return false;
            defer said.deinit();
            s.username = try s.gpa.dupe(u8, said.expose());
        }
        if (s.password == null) {
            const prompt = try s.promptText(arena, "Password");
            s.password = try s.ask(io, opts, .password, prompt) orelse return false;
        }
        s.source = .prompt;
        return true;
    }

    fn noteAsked(s: *Session, helper: []const u8, answer: auth.Failure.Answer) Allocator.Error!void {
        const command = try s.gpa.dupe(u8, helper);
        errdefer s.gpa.free(command);
        try s.asked.append(s.gpa, .{ .command = command, .answer = answer });
    }

    fn expired(s: *const Session, now: ?Io.Timestamp) bool {
        const t = date.seconds(now orelse return false);
        // git compares its unsigned timestamp with `time(NULL)` as C does.
        return s.password_expiry_utc < @as(u64, @bitCast(@as(i64, t)));
    }

    /// The secrets of a credential past its `password_expiry_utc` are
    /// forgotten, as git's `credential_fill` forgets them after each
    /// helper.
    fn dropExpired(s: *Session, now: ?Io.Timestamp) void {
        if (!s.expired(now)) return;
        s.clearSecrets();
        s.password_expiry_utc = no_expiry;
    }

    /// The credential worked: every helper is told to `store` it — unless
    /// it has expired, which git does not store. Once.
    pub fn approve(s: *Session, io: Io, opts: Options) Self.Error!void {
        if (s.approved) return;
        if (!s.hasCredential() or s.expired(opts.now)) return;
        s.nextState();
        try s.configure(opts.config);
        try s.tellHelpers(io, opts, .store);
        s.approved = true;
    }

    /// The credential was refused: every helper is told to `erase` it, and
    /// its secrets and username are forgotten here, even when a helper
    /// could not be told.
    pub fn reject(s: *Session, io: Io, opts: Options) Self.Error!void {
        defer s.forget();
        s.nextState();
        try s.configure(opts.config);
        try s.tellHelpers(io, opts, .erase);
    }

    /// The server refused one round of a conversation a helper said goes
    /// on (`continue=1`): the secrets go, and the next fill asks again with
    /// the state and challenges, as git's `handle_curl_result` does.
    pub fn nextRound(s: *Session) void {
        s.clearSecrets();
    }

    fn tellHelpers(s: *Session, io: Io, opts: Options, operation: Operation) Self.Error!void {
        const settings = s.settings orelse return;
        if (settings.helpers.len == 0) return;
        const programs = opts.programs orelse return error.ProgramsNotGranted;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        for (settings.helpers) |helper| {
            _ = try s.runHelper(arena_state.allocator(), io, programs, opts.cache_daemon, helper, operation);
        }
    }

    /// git's `credential_reject`, after the helpers: the secrets, the
    /// username and the token's refresh and expiry forgotten, keeping
    /// whose it was for a failure's description.
    fn forget(s: *Session) void {
        if (s.refused_username) |u| s.gpa.free(u);
        // Only the description is lost when this cannot be kept.
        s.refused_username = if (s.username) |u| s.gpa.dupe(u8, u) catch null else null;
        s.refused_source = s.source;
        s.clearSecrets();
        if (s.username) |u| s.gpa.free(u);
        s.username = null;
        wipe(&s.oauth_refresh_token);
        s.password_expiry_utc = no_expiry;
        s.approved = false;
        s.source = .none;
    }

    /// Describe a refusal in `failure`: the helpers asked, the prompt, and
    /// whose credential it was. `failure` has been begun.
    pub fn describeFailure(s: *const Session, failure: *auth.Failure, prompt_available: bool) Allocator.Error!void {
        const a = failure.allocator();
        const helpers = try a.alloc(auth.Failure.Helper, s.asked.items.len);
        for (s.asked.items, helpers) |from, *to| to.* = .{ .command = try a.dupe(u8, from.command), .answer = from.answer };
        failure.helpers = helpers;
        failure.prompt_available = prompt_available;
        failure.prompted = s.prompted;
        failure.source = if (s.source != .none) s.source else s.refused_source;
        if (s.username orelse s.refused_username) |u| failure.username = try a.dupe(u8, u);
        const challenges = try a.alloc([]const u8, s.challenges.items.len);
        for (s.challenges.items, challenges) |from, *to| to.* = try a.dupe(u8, from);
        failure.challenges = challenges;
    }

    /// git's `credential_apply_config`: the `credential.*` settings that
    /// apply to this credential, read the first time and kept.
    fn configure(s: *Session, config: ?*const config_mod.Config) Self.Error!void {
        if (s.settings != null) return;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var settings: Settings = .{};
        errdefer settings.deinit(s.gpa);
        if (config) |c| {
            const formatted = try s.format(arena);
            const normalized: ?urlmatch.Info = urlmatch.normalize(arena, formatted, false) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            for (c.entries.items) |entry| {
                if (!std.ascii.eqlIgnoreCase(entry.section, "credential")) continue;
                if (entry.subsection.len != 0 and !try s.patternMatches(arena, entry.subsection, normalized)) continue;
                try settings.take(s, entry.name, entry.value);
            }
            const timeout = c.getInt("credentialstore.locktimeoutms", 1000) catch return error.InvalidCredentialSetting;
            settings.store_lock_timeout_ms = std.math.cast(u32, timeout) orelse 0;
        }
        s.settings = settings;
        if (!settings.use_http_path and s.protocol != null and isHttp(s.protocol.?)) {
            if (s.path) |p| s.gpa.free(p);
            s.path = null;
        }
    }

    /// Whether `credential.<pattern>.*` applies: git's `match_urls` against
    /// the normalized credential, or, for a pattern git cannot normalize,
    /// its `match_partial_url`.
    fn patternMatches(s: *const Session, arena: Allocator, pattern: []const u8, normalized: ?urlmatch.Info) Allocator.Error!bool {
        if (urlmatch.normalize(arena, pattern, true)) |info| {
            const have = normalized orelse return false;
            return urlmatch.match(have, info) != null;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
        // git warns of a pattern holding a newline and skips it.
        var want = UrlParts.read(arena, pattern, true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        // The arena frees unwiped; a password in a pattern is wiped first.
        defer if (want.password) |*secret| secret.deinit();
        return want.matches(s);
    }

    /// git's `credential_format`: the credential as a URL, every part
    /// percent-encoded, which is what `credential.<url>` is matched
    /// against and what a prompt names.
    fn format(s: *const Session, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const protocol = s.protocol orelse return "";
        try out.print(arena, "{s}://", .{protocol});
        if (s.username) |u| if (u.len != 0) {
            try appendEncoded(arena, &out, u, .user);
            try out.append(arena, '@');
        };
        if (s.host) |h| try appendEncoded(arena, &out, h, .host);
        if (s.path) |p| {
            try out.append(arena, '/');
            try appendEncoded(arena, &out, p, .path);
        }
        return out.items;
    }

    /// git's `credential_describe`: as `format`, nothing encoded.
    fn describe(s: *const Session, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const protocol = s.protocol orelse return "";
        try out.print(arena, "{s}://", .{protocol});
        if (s.username) |u| if (u.len != 0) try out.print(arena, "{s}@", .{u});
        if (s.host) |h| try out.appendSlice(arena, h);
        if (s.path) |p| try out.print(arena, "/{s}", .{p});
        return out.items;
    }

    /// git's `credential_ask_one`: `Username for '<url>': `, the URL
    /// percent-encoded unless `credential.sanitizePrompt` is false, so
    /// that a URL cannot make the prompt name a host it is not asking
    /// for.
    fn promptText(s: *const Session, arena: Allocator, what: []const u8) Allocator.Error![]const u8 {
        const sanitize = if (s.settings) |settings| settings.sanitize_prompt else true;
        const desc = if (sanitize) try s.format(arena) else try s.describe(arena);
        if (desc.len == 0) return arena.print("{s}: ", .{what});
        return arena.print("{s} for '{s}': ", .{ what, desc });
    }

    const Operation = enum { get, store, erase };

    /// Which of git's `credential_write`s: to a helper asked for a
    /// credential, or the credential as it stands after one answered.
    pub const Audience = enum { helper, response };

    fn hasCapability(capa: Capability, audience: Audience) bool {
        return switch (audience) {
            .helper => capa.initial,
            .response => capa.initial and capa.helper,
        };
    }

    /// git's `credential_write`: what a helper is handed, in git's order,
    /// or with `.response` the credential as `git credential fill` prints
    /// it.
    pub fn write(s: *Session, out: *std.Io.Writer, audience: Audience) (Self.Error || std.Io.Writer.Error)!void {
        try s.fromOrigin();
        const protect = if (s.settings) |settings| settings.protect_protocol else true;
        const w: ItemWriter = .{ .out = out, .protect_protocol = protect };
        const authtype = hasCapability(s.capa_authtype, audience);
        const state = hasCapability(s.capa_state, audience);
        if (authtype) try w.item("capability[]", "authtype");
        if (state) try w.item("capability[]", "state");
        if (authtype) {
            try w.optional("authtype", s.authtype);
            try w.optional("credential", reveal(&s.credential));
            if (s.ephemeral) try w.item("ephemeral", "1");
        }
        try w.item("protocol", s.protocol.?);
        try w.item("host", s.host.?);
        try w.optional("path", s.path);
        try w.optional("username", s.username);
        try w.optional("password", reveal(&s.password));
        try w.optional("oauth_refresh_token", reveal(&s.oauth_refresh_token));
        if (s.password_expiry_utc != no_expiry) {
            var buf: [24]u8 = undefined;
            // aegis: no-danger: a u64 is at most 20 digits.
            try w.item("password_expiry_utc", std.mem.print(&buf, "{d}", .{s.password_expiry_utc}) catch unreachable);
        }
        for (s.challenges.items) |c| try w.item("wwwauth[]", c);
        if (state) {
            if (s.multistage) try w.item("continue", "1");
            for (s.state_to_send.items) |v| try w.item("state[]", v);
        }
    }

    /// git's `credential_write_item`: `key=value` and a newline, refused
    /// when the value could end its line early.
    const ItemWriter = struct {
        out: *std.Io.Writer,
        protect_protocol: bool,

        fn item(w: ItemWriter, key: []const u8, value: []const u8) (Self.Error || std.Io.Writer.Error)!void {
            if (std.mem.findScalar(u8, value, '\n') != null) return error.CredentialValueUnsafe;
            if (w.protect_protocol and std.mem.findScalar(u8, value, '\r') != null) return error.CredentialValueUnsafe;
            try w.out.print("{s}={s}\n", .{ key, value });
        }

        fn optional(w: ItemWriter, key: []const u8, value: ?[]const u8) (Self.Error || std.Io.Writer.Error)!void {
            if (value) |v| try w.item(key, v);
        }
    };

    /// What a helper is handed (`write`), in secret memory: a
    /// `SecretBytes.Writer` wipes what it outgrows, so no copy of a password
    /// is left in memory a growing buffer freed.
    fn helperInput(s: *Session, audience: Audience) Self.Error!SecretBytes {
        var input = try SecretBytes.init(s.gpa, 0);
        errdefer input.deinit();
        var into = SecretBytes.Writer.init(&input);
        s.write(&into.interface, audience) catch |err| switch (err) {
            // The writer fails only for want of memory.
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        into.interface.flush() catch return error.OutOfMemory;
        return input;
    }

    const Outcome = struct {
        /// The helper could not be run, or ended in failure; what it wrote
        /// is still taken, as git takes it.
        failed: bool,
        /// It answered with a username, password, authtype or credential.
        any: bool,
    };

    fn runHelper(
        s: *Session,
        arena: Allocator,
        io: Io,
        programs: program.Programs,
        cache_daemon: ?cache.Starter,
        helper: []const u8,
        operation: Operation,
    ) ErrorNamespace.Error!Outcome {
        if (helper[0] != '!' and !std.Io.Dir.path.isAbsolute(helper)) {
            if (try nativeHelper(arena, helper, programs.environ)) |native| switch (native) {
                .cache => |c| return s.runCache(arena, io, programs, cache_daemon, c, operation),
                else => return s.runNative(io, native, operation),
            };
        }
        const command = if (helper[0] == '!')
            try arena.print("{s} {t}", .{ helper[1..], operation })
        else if (std.Io.Dir.path.isAbsolute(helper))
            try arena.print("{s} {t}", .{ helper, operation })
        else
            try arena.print("git credential-{s} {t}", .{ helper, operation });

        var input = try s.helperInput(if (operation == .get) .helper else .response);
        defer input.deinit();

        var answer = try runSecret(s.gpa, io, programs, .{
            .argv = &.{command},
            .shell = true,
            .stderr = .inherit,
        }, .{ .input = input.expose(), .output = .limited(64 * 1024) });
        defer answer.stdout.deinit();
        // Only `get` is listened to. A helper that fails, or that is not
        // there, is passed over, but what it wrote first is read, as git
        // reads it before it waits for the helper to end.
        if (operation != .get) return .{ .failed = !answer.succeeded(), .any = false };
        const any = try s.readAnswer(.init(answer.stdout.expose()));
        return .{ .failed = !answer.succeeded(), .any = any };
    }

    /// git's own `credential-store`, run here rather than as `git
    /// credential-store`: what it answers to `get` taken as a helper's
    /// answer; a failure, as a helper's, passed over.
    fn runNative(s: *Session, io: Io, native: Native, operation: Operation) ErrorNamespace.Error!Outcome {
        const files = switch (native) {
            .usage => return .{ .failed = true, .any = false },
            .store => |files| files,
            .cache => unreachable,
        };
        var settled = files;
        if (s.settings) |settings| settled.lock_timeout_ms = settings.store_lock_timeout_ms;
        const c: store_mod.Credential = .{
            .protocol = s.protocol,
            .host = s.host,
            .path = s.path,
            .username = s.username,
            .password = if (s.password) |*p| p.expose() else null,
        };
        const found: ?store_mod.Found = switch (operation) {
            .get => store_mod.get(s.gpa, io, settled, c) catch |err| return nativeFailed(err),
            .store => blk: {
                store_mod.store(s.gpa, io, settled, c) catch |err| return nativeFailed(err);
                break :blk null;
            },
            .erase => blk: {
                store_mod.erase(s.gpa, io, settled, c) catch |err| return nativeFailed(err);
                break :blk null;
            },
        };
        var entry = found orelse return .{ .failed = false, .any = false };
        defer {
            s.gpa.free(entry.username);
            entry.password.deinit();
        }
        // What git's `credential-store` prints, read as any helper's answer.
        var answer = try SecretBytes.init(s.gpa, 0);
        defer answer.deinit();
        try parts_mod.appendParts(&answer, &.{ "username=", entry.username, "\npassword=", entry.password.expose(), "\n" });
        return .{ .failed = false, .any = try s.readAnswer(.init(answer.expose())) };
    }

    /// git's own `credential-cache`, run here rather than as `git
    /// credential-cache`: the helper's input relayed to the daemon with the
    /// action and timeout, and what it answers to `get` taken as a
    /// helper's answer. A `store` that finds no daemon starts one through
    /// `cache_daemon`, else git's own, and asks again; one that does not
    /// start is a helper failing, as git's is.
    fn runCache(
        s: *Session,
        arena: Allocator,
        io: Io,
        programs: program.Programs,
        cache_daemon: ?cache.Starter,
        helper: CacheHelper,
        operation: Operation,
    ) ErrorNamespace.Error!Outcome {
        const environ = programs.environ;
        const failed: Outcome = .{ .failed = true, .any = false };
        // git's `do_cache` acts on the first word that is no option.
        const action = std.meta.stringToEnum(cache.Action, helper.action orelse @tagName(operation)) orelse return .{ .failed = false, .any = false };
        if (action == .exit) return .{ .failed = false, .any = false };
        // git's "unable to find a suitable socket path; use --socket".
        const socket = helper.socket orelse (try cache.defaultSocket(arena, io, environ)) orelse return failed;
        var input = try s.helperInput(if (operation == .get) .helper else .response);
        defer input.deinit();
        return s.askCache(io, programs, cache_daemon, .{ .socket = socket, .operation = operation, .request = .{ .action = action, .timeout = helper.timeout, .input = input.expose() } });
    }

    /// What `runCache` asks the daemon: at `socket`, `request` for `operation`.
    const CacheQuestion = struct { socket: []const u8, operation: Operation, request: cache.Request };

    /// `question` relayed to the daemon, started as `runCache` says when a
    /// `store` finds none.
    fn askCache(s: *Session, io: Io, programs: program.Programs, cache_daemon: ?cache.Starter, question: CacheQuestion) ErrorNamespace.Error!Outcome {
        const failed: Outcome = .{ .failed = true, .any = false };
        const socket = question.socket;
        const req = question.request;
        const action = req.action;
        const operation = question.operation;
        const answered = cache.request(s.gpa, io, socket, req) catch |err| return cacheFailed(err);
        var got = answered orelse retry: {
            if (action != .store) return .{ .failed = false, .any = false };
            if (cache_daemon) |starter| {
                starter.start(starter.context, io, socket) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.CacheDaemonNotStarted => return failed,
                };
            } else if (!try startGitDaemon(s.gpa, io, programs, socket)) return failed;
            break :retry (cache.request(s.gpa, io, socket, req) catch |err| return cacheFailed(err)) orelse return failed;
        };
        defer got.deinit();
        // What the daemon prints is the helper's; only `get` is listened to.
        if (operation != .get) return .{ .failed = false, .any = false };
        return .{ .failed = false, .any = try s.readAnswer(.init(got.expose())) };
    }

    /// git's `spawn_daemon`: `git credential-cache--daemon <socket>`
    /// started, and whether it said `ok` once it listened. The shell leaves
    /// it running on its own, as git leaves its daemon behind it. Its `PATH`
    /// is git's own (`setup_path`), the exec path ahead of the caller's, so
    /// the `git` that `git_cmd` names is git's: Git for Windows' `git` on
    /// `PATH` is a wrapper that waits on the git it starts, and so would hold
    /// the daemon's output open for as long as the daemon runs.
    fn startGitDaemon(gpa: Allocator, io: Io, programs: program.Programs, socket: []const u8) ErrorNamespace.Error!bool {
        var exec = program.run(gpa, io, programs, .{ .argv = &.{ "git", "--exec-path" } }, .{ .output = .limited(4096) }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return false,
        };
        defer exec.deinit(gpa);
        if (!exec.succeeded()) return false;
        const exec_path = std.mem.trimEnd(u8, exec.stdout, "\r\n");
        const search = if (programs.environ.get("PATH")) |path|
            try gpa.print("{s}{c}{s}", .{ exec_path, Io.Dir.path.delimiter, path })
        else
            try gpa.dupe(u8, exec_path);
        defer gpa.free(search);
        var outcome = program.run(gpa, io, programs, .{
            .argv = &.{ "sh", "-c", "git credential-cache--daemon \"$1\" </dev/null &", "sh", socket },
            .set = &.{.{ .name = "PATH", .value = search }},
            .stderr = .inherit,
        }, .{ .output = .limited(128) }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return false,
        };
        defer outcome.deinit(gpa);
        return std.mem.eql(u8, outcome.stdout, "ok\n");
    }

    fn cacheFailed(err: cache.Error) ErrorNamespace.Error!Outcome {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => .{ .failed = true, .any = false },
        };
    }

    /// A native helper's failure, as a helper's: passed over, but for
    /// memory and cancellation.
    fn nativeFailed(err: store_mod.Error) ErrorNamespace.Error!Outcome {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => .{ .failed = true, .any = false },
        };
    }

    /// Take a helper's answer to `get`, as git's `credential_read` does:
    /// a line at a time to the first empty one, or to the first with no
    /// `=`, which ends the answer keeping what came before it. Returns
    /// whether it named a username, password, authtype or credential.
    pub fn readAnswer(s: *Session, answer: aegis.input.Untrusted([]const u8)) ErrorNamespace.Error!bool {
        var any = false;
        var rest = answer.readForParse();
        while (rest.len != 0) {
            // git's `strbuf_getline`: a line ends at a newline, which goes
            // with one carriage return before it.
            var line = rest;
            if (std.mem.findScalar(u8, rest, '\n')) |nl| {
                line = rest[0..nl];
                rest = rest[nl + 1 ..];
                if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            } else rest = "";
            if (line.len == 0) break;
            // The key and the value are C strings: each ends at a NUL.
            const c_line = line[0 .. std.mem.findScalar(u8, line, 0) orelse line.len];
            const eq = std.mem.findScalar(u8, c_line, '=') orelse break;
            const key = c_line[0..eq];
            const value = c_line[eq + 1 ..];
            if (std.mem.eql(u8, key, "username")) {
                try replace(s.gpa, &s.username, value);
                s.username_from_url = true;
                any = true;
            } else if (std.mem.eql(u8, key, "password")) {
                try replaceSecret(s.gpa, &s.password, value);
                any = true;
            } else if (std.mem.eql(u8, key, "credential")) {
                try replaceSecret(s.gpa, &s.credential, value);
                any = true;
            } else if (std.mem.eql(u8, key, "protocol")) {
                try replace(s.gpa, &s.protocol, value);
            } else if (std.mem.eql(u8, key, "host")) {
                try replace(s.gpa, &s.host, value);
            } else if (std.mem.eql(u8, key, "path")) {
                try replace(s.gpa, &s.path, value);
            } else if (std.mem.eql(u8, key, "ephemeral")) {
                s.ephemeral = try answerBool(value);
            } else if (std.mem.eql(u8, key, "wwwauth[]")) {
                try appendOwned(s.gpa, &s.challenges, value);
            } else if (std.mem.eql(u8, key, "state[]")) {
                try appendOwned(s.gpa, &s.state, value);
            } else if (std.mem.eql(u8, key, "capability[]")) {
                if (std.mem.eql(u8, value, "authtype")) s.capa_authtype.helper = true;
                if (std.mem.eql(u8, value, "state")) s.capa_state.helper = true;
            } else if (std.mem.eql(u8, key, "continue")) {
                s.multistage = try answerBool(value);
            } else if (std.mem.eql(u8, key, "password_expiry_utc")) {
                // git's `parse_timestamp(value, NULL, 10)`: `strtoumax`, the
                // number the value starts with; zero, or one too large, is
                // no expiry.
                const read = decimal.strtoul(value, 10, 64);
                const expiry: u64 = @intCast(read.value);
                s.password_expiry_utc = if (read.overflow or expiry == 0) no_expiry else expiry;
            } else if (std.mem.eql(u8, key, "oauth_refresh_token")) {
                try replaceSecret(s.gpa, &s.oauth_refresh_token, value);
            } else if (std.mem.eql(u8, key, "authtype")) {
                try replace(s.gpa, &s.authtype, value);
            } else if (std.mem.eql(u8, key, "url")) {
                // git's `credential_from_url`: the credential starts over.
                s.takeUrl(value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NoScheme, error.CredentialValueUnsafe => return error.InvalidCredentialAnswer,
                };
                any = s.username != null or s.password != null;
            } else if (std.mem.eql(u8, key, "quit")) {
                s.quit = try answerBool(value);
            }
            // Other keys are passed over, as git passes them over.
        }
        return any;
    }

    /// Ask for one field. With the caller's leave, the person's askpass
    /// first — `GIT_ASKPASS`, then `core.askPass`, then `SSH_ASKPASS`, as
    /// git's `git_prompt` — and then the caller's own prompt.
    /// The answer is `s.gpa`'s, wiped when it is let go.
    fn ask(s: *Session, io: Io, opts: Options, field: Field, prompt: []const u8) ErrorNamespace.Error!?SecretBytes {
        const p = opts.prompt orelse return error.CredentialsUnavailable;
        if (p.askpass) {
            if (try s.askpass(io, opts, prompt)) |answer| return answer;
        }
        const ask_fn = p.ask orelse return error.CredentialsUnavailable;
        s.prompted = true;
        var answer = try SecretBytes.init(s.gpa, 0);
        errdefer answer.deinit();
        var into = SecretBytes.Writer.init(&answer);
        // The writer fails only for want of memory.
        const answered = ask_fn(p.context, field, prompt, &into.interface) catch return error.OutOfMemory;
        into.interface.flush() catch return error.OutOfMemory;
        if (!answered) {
            answer.deinit();
            return null;
        }
        return answer;
    }

    fn askpass(s: *Session, io: Io, opts: Options, prompt: []const u8) ErrorNamespace.Error!?SecretBytes {
        var command: ?[]const u8 = null;
        if (opts.programs) |programs| command = programs.environ.get("GIT_ASKPASS");
        var config_value: ?[]u8 = null;
        defer if (config_value) |v| s.gpa.free(v);
        if (command == null) {
            if (opts.config) |config| {
                if (config.get("core.askpass")) |raw| {
                    config_value = s.gpa.dupe(u8, raw) catch null;
                    if (config_value) |v| {
                        if (v.len != 0) command = v;
                    }
                }
            }
        }
        if (command == null) {
            if (opts.programs) |programs| command = programs.environ.get("SSH_ASKPASS");
        }
        const line = command orelse return null;
        if (line.len == 0) return null;
        const programs = opts.programs orelse return error.ProgramsNotGranted;
        s.prompted = true;
        var answer = try runSecret(s.gpa, io, programs, .{
            .argv = &.{ line, prompt },
            .stderr = .inherit,
        }, .{ .output = .limited(64 * 1024) });
        if (!answer.succeeded()) {
            answer.stdout.deinit();
            return null;
        }
        // Its first line, as git's `git_prompt` takes it.
        const said = answer.stdout.expose();
        const end = std.mem.findAny(u8, said, "\r\n") orelse said.len;
        // unreachable: a shorter live length is within any capacity.
        answer.stdout.resizeWithinCapacity(end) catch unreachable;
        return answer.stdout;
    }
};

fn replace(gpa: Allocator, slot: *?[]u8, value: []const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, value);
    if (slot.*) |old| gpa.free(old);
    slot.* = owned;
}

/// `replace` for a secret: the old one wiped as it goes.
fn replaceSecret(gpa: Allocator, slot: *?SecretBytes, value: []const u8) Allocator.Error!void {
    var fresh = try SecretBytes.init(gpa, value.len);
    // unreachable: a new allocation of the value's length, apart from it.
    fresh.replace(value) catch unreachable;
    if (slot.*) |*old| old.deinit();
    slot.* = fresh;
}

/// What a program printed, a secret from its first byte, and how it ended.
const Answer = struct {
    term: program.Term,
    stdout: SecretBytes,

    fn succeeded(answer: Answer) bool {
        return program.Child.succeeded(answer.term);
    }
};

/// `program.run` for a program whose standard output is a secret: read
/// straight into storage that is wiped as it grows and when it is let go, so
/// it is never held anywhere else. Its standard error is not captured.
fn runSecret(
    gpa: Allocator,
    io: Io,
    programs: program.Programs,
    invocation: program.Invocation,
    options: program.RunOptions,
) ErrorNamespace.Error!Answer {
    // Room for a usual answer, so it seldom grows.
    var stdout = try SecretBytes.init(gpa, 256);
    errdefer stdout.deinit();
    var writer = SecretBytes.Writer.init(&stdout);
    var stderr = std.Io.Writer.Discarding.init(&.{});
    const term = program.runInto(gpa, io, programs, invocation, .{
        .sinks = .{ .stdout = &writer.interface, .stderr = &stderr.writer },
        .run = options,
    }) catch |err| switch (err) {
        // The writer fails only for want of memory.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return .{ .term = term, .stdout = stdout };
}

fn appendOwned(gpa: Allocator, list: *std.ArrayList([]u8), value: []const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, value);
    errdefer gpa.free(owned);
    try list.append(gpa, owned);
}

/// git's `git_config_bool` on a helper's answer, which dies on anything
/// that is not one.
fn answerBool(value: []const u8) error{InvalidCredentialAnswer}!bool {
    return config_mod.parseBool(value) catch error.InvalidCredentialAnswer;
}

fn isHttp(protocol: []const u8) bool {
    return std.mem.eql(u8, protocol, "https") or std.mem.eql(u8, protocol, "http");
}

/// `credential.interactive`, as git's `credential_getpass` reads it: only
/// the plain key, false when it is a boolean that is false or the word
/// `never`.
fn interactive(config: ?*const config_mod.Config) bool {
    const c = config orelse return true;
    const entry = c.find("credential.interactive") orelse return true;
    const value = entry.value orelse return true;
    if (config_mod.parseBool(value)) |yes| return yes else |_| {}
    return !std.mem.eql(u8, value, "never");
}

/// The `credential.*` settings a credential has once it is configured.
const Settings = struct {
    helpers: [][]u8 = &.{},
    /// `credentialStore.lockTimeoutMS`: how long the native store waits
    /// for its file's lock.
    store_lock_timeout_ms: u32 = 1000,
    use_http_path: bool = false,
    /// `credential.protectProtocol`: a carriage return is refused too.
    protect_protocol: bool = true,
    /// `credential.sanitizePrompt`: a prompt names the URL percent-encoded.
    sanitize_prompt: bool = true,

    fn deinit(settings: *Settings, gpa: Allocator) void {
        for (settings.helpers) |h| gpa.free(h);
        gpa.free(settings.helpers);
        settings.* = .{};
    }

    /// git's `credential_config_callback` for one matching entry.
    fn take(settings: *Settings, s: *Session, name: []const u8, raw: ?[]const u8) ErrorNamespace.Error!void {
        const gpa = s.gpa;
        const value = raw orelse return error.InvalidCredentialSetting;
        if (std.ascii.eqlIgnoreCase(name, "helper")) {
            if (value.len == 0) {
                for (settings.helpers) |h| gpa.free(h);
                gpa.free(settings.helpers);
                settings.helpers = &.{};
                return;
            }
            const owned = try gpa.dupe(u8, value);
            errdefer gpa.free(owned);
            const grown = try gpa.realloc(settings.helpers, settings.helpers.len + 1);
            grown[grown.len - 1] = owned;
            settings.helpers = grown;
        } else if (std.ascii.eqlIgnoreCase(name, "username")) {
            if (!s.username_from_url) try replace(gpa, &s.username, value);
        } else if (std.ascii.eqlIgnoreCase(name, "usehttppath")) {
            settings.use_http_path = try settingBool(value);
        } else if (std.ascii.eqlIgnoreCase(name, "sanitizeprompt")) {
            settings.sanitize_prompt = try settingBool(value);
        } else if (std.ascii.eqlIgnoreCase(name, "protectprotocol")) {
            settings.protect_protocol = try settingBool(value);
        }
    }
};

/// A helper relic runs itself: git's `credential-store`, its arguments
/// read as `sh` would hand them over, or a command line git's would refuse.
const Native = union(enum) {
    store: store_mod.Files,
    cache: CacheHelper,
    /// An option `credential-store` does not take: it exits with its usage,
    /// which is a helper failing.
    usage,
};

/// `credential-cache`'s words: `--timeout`, `--socket`, and the first
/// word that is no option, which git takes for the action in place of the
/// one it was run for.
const CacheHelper = struct {
    timeout: i32 = cache.default_timeout,
    socket: ?[]const u8 = null,
    action: ?[]const u8 = null,
};

/// `helper` as relic runs it itself, or `null` to run it through the
/// shell as git does: a helper named `store` whose words are ones `sh`
/// hands over as written -- a quote around a word, a `~` or `~/` before
/// one -- and anything else, any word `sh` would expand or a name relic
/// does not run, through the shell.
fn nativeHelper(arena: Allocator, helper: []const u8, environ: *const std.process.Environ.Map) Allocator.Error!?Native {
    const words = (try shellWords(arena, helper, environ.get("HOME"))) orelse return null;
    if (words.len != 0 and std.mem.eql(u8, words[0], "cache")) return cacheHelper(words[1..]);
    if (words.len == 0 or !std.mem.eql(u8, words[0], "store")) return null;
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < words.len) : (i += 1) {
        const word = words[i];
        if (std.mem.startsWith(u8, word, "--file=")) {
            file = word["--file=".len..];
        } else if (std.mem.eql(u8, word, "--file") and i + 1 < words.len) {
            i += 1;
            file = words[i];
        } else return .usage;
    }
    if (file) |path| {
        const paths = try arena.alloc([]const u8, 1);
        paths[0] = path;
        return .{ .store = .{ .paths = paths } };
    }
    const paths = try store_mod.defaultFiles(arena, environ);
    // git's "unable to set up default path; use --file".
    if (paths.len == 0) return .usage;
    return .{ .store = .{ .paths = paths } };
}

/// `credential-cache`'s options as git's `parse_options` reads them:
/// `--timeout` an integer as `git_parse_int` reads one, `--socket` a path,
/// each `--name=value` or `--name value`, a name any unambiguous start of
/// one, `--no-timeout` zero and `--no-socket` the default; `--` ends them.
/// Anything else is its usage, which is a helper failing.
fn cacheHelper(words: []const []const u8) Native {
    var helper: CacheHelper = .{};
    const names = [_][]const u8{ "timeout", "socket", "no-timeout", "no-socket" };
    var i: usize = 0;
    var options = true;
    while (i < words.len) : (i += 1) {
        const word = words[i];
        if (!options or !std.mem.startsWith(u8, word, "-") or word.len == 1) {
            if (helper.action == null) helper.action = word;
            continue;
        }
        if (std.mem.eql(u8, word, "--")) {
            options = false;
            continue;
        }
        if (!std.mem.startsWith(u8, word, "--")) return .usage;
        const body = word[2..];
        const eq = std.mem.findScalar(u8, body, '=');
        const given = body[0 .. eq orelse body.len];
        var found: ?usize = null;
        for (names, 0..) |name, n| {
            if (std.mem.eql(u8, name, given)) {
                found = n;
                break;
            }
            if (given.len != 0 and std.mem.startsWith(u8, name, given)) {
                if (found != null) return .usage;
                found = n;
            }
        }
        const which = found orelse return .usage;
        if (which >= 2) {
            if (eq != null) return .usage;
            if (which == 2) helper.timeout = 0 else helper.socket = null;
            continue;
        }
        const value = if (eq) |e| body[e + 1 ..] else blk: {
            i += 1;
            if (i >= words.len) return .usage;
            break :blk words[i];
        };
        if (which == 0) {
            const n = config_mod.parseInteger(value) catch return .usage;
            helper.timeout = std.math.cast(i32, n) orelse return .usage;
        } else helper.socket = value;
    }
    return .{ .cache = helper };
}

/// The words `sh -c` would split `text` into, when it needs no more than
/// splitting at blanks, single and double quotes holding no `$`, `` ` ``
/// or `\`, and a `~` or `~/` starting a word (`home`'s); `null` for
/// anything else, which only a shell can read.
fn shellWords(arena: Allocator, text: []const u8, home: ?[]const u8) Allocator.Error!?[]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\n') {
            if (in_word) try words.append(arena, try word.toOwnedSlice(arena));
            in_word = false;
            continue;
        }
        if (!in_word and c == '~') {
            const next = if (i + 1 < text.len) text[i + 1] else ' ';
            if (next != '/' and next != ' ' and next != '\t' and next != '\n') return null;
            try word.appendSlice(arena, home orelse return null);
            in_word = true;
            continue;
        }
        in_word = true;
        if (c == '\'' or c == '"') {
            const end = std.mem.findScalarPos(u8, text, i + 1, c) orelse return null;
            const quoted = text[i + 1 .. end];
            if (c == '"' and std.mem.findAny(u8, quoted, "$`\\") != null) return null;
            try word.appendSlice(arena, quoted);
            i = end;
            continue;
        }
        if (std.mem.findScalar(u8, "$`\\|&;<>()*?[]{}!#", c) != null) return null;
        try word.append(arena, c);
    }
    if (in_word) try words.append(arena, try word.toOwnedSlice(arena));
    return words.items;
}

fn settingBool(value: []const u8) error{InvalidCredentialSetting}!bool {
    return config_mod.parseBool(value) catch error.InvalidCredentialSetting;
}

/// How a part of a URL is encoded by git's `strbuf_add_percentencode`: a
/// user (slashes too), a host and port, or a path.
const Part = enum { user, host, path };

fn appendEncoded(arena: Allocator, out: *std.ArrayList(u8), text: []const u8, part: Part) Allocator.Error!void {
    // git's `URL_UNSAFE_CHARS` in `strbuf.c`.
    const unsafe = " <>\"%{}|\\^`:?#[]@!$&'()*+,;=";
    for (text) |c| {
        const encode = c <= 0x1f or c >= 0x7f or switch (part) {
            .host => !std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "-.:[]", c) == null,
            .user => c == '/' or std.mem.findScalar(u8, unsafe, c) != null,
            .path => std.mem.findScalar(u8, unsafe, c) != null,
        };
        if (encode) try out.print(arena, "%{X:0>2}", .{c}) else try out.append(arena, c);
    }
}

const testing = std.testing;

fn configuredFor(text: []const u8, url: []const u8) !struct { config: config_mod.Config, session: Session } {
    var config = try config_mod.Config.parseText(testing.allocator, text, .local);
    errdefer config.deinit();
    var session: Session = .{ .gpa = testing.allocator, .url = try url_mod.Url.parse(url) };
    errdefer session.deinit();
    try session.fromOrigin();
    try session.configure(&config);
    return .{ .config = config, .session = session };
}

test "credential sections match as git's urlmatch and partial match have them" {
    const Case = struct { pattern: []const u8, url: []const u8, applies: bool };
    for ([_]Case{
        .{ .pattern = "https://git.example.com", .url = "https://ada@git.example.com/org/repo.git", .applies = true },
        .{ .pattern = "https://*.example.com", .url = "https://git.example.com/r", .applies = true },
        .{ .pattern = "https://git.example.com:443/org", .url = "https://git.example.com/org/repo.git", .applies = true },
        .{ .pattern = "https://ada@git.example.com/org/", .url = "https://ada@git.example.com/org/r", .applies = true },
        .{ .pattern = "https://bob@git.example.com", .url = "https://ada@git.example.com/r", .applies = false },
        .{ .pattern = "http://git.example.com", .url = "https://git.example.com/r", .applies = false },
        .{ .pattern = "https://git.example.com/org/rep", .url = "https://git.example.com/org/repo", .applies = false },
        // No scheme: git cannot normalize it, and compares the parts it has.
        .{ .pattern = "git.example.com", .url = "https://git.example.com/r", .applies = true },
        .{ .pattern = "git.example.com:8443", .url = "https://git.example.com:8443/r", .applies = true },
        .{ .pattern = "git.example.com/r", .url = "https://git.example.com/r/", .applies = true },
        .{ .pattern = "git.example.com/s", .url = "https://git.example.com/r", .applies = false },
        .{ .pattern = "https://", .url = "https://git.example.com/r", .applies = true },
    }) |case| {
        const text = try testing.allocator.print("[credential \"{s}\"]\n\thelper = h\n", .{case.pattern});
        defer testing.allocator.free(text);
        var both = try configuredFor(text, case.url);
        defer both.config.deinit();
        defer both.session.deinit();
        testing.expectEqual(case.applies, both.session.settings.?.helpers.len == 1) catch |err| {
            std.debug.print("pattern {s}, url {s}\n", .{ case.pattern, case.url });
            return err;
        };
    }
}

test "a helper list follows git's rule that an empty value clears it" {
    var both = try configuredFor(
        \\[credential]
        \\    helper = first
        \\    helper =
        \\    helper = !second --flag
        \\[credential "https://git.example.com"]
        \\    helper = third
        \\    username = ada
        \\    useHttpPath = true
        \\[credential "https://elsewhere.example.com"]
        \\    helper = never
        \\
    , "https://git.example.com/repo");
    defer both.config.deinit();
    defer both.session.deinit();
    const settings = both.session.settings.?;
    try testing.expectEqual(@as(usize, 2), settings.helpers.len);
    try testing.expectEqualStrings("!second --flag", settings.helpers[0]);
    try testing.expectEqualStrings("third", settings.helpers[1]);
    try testing.expectEqualStrings("ada", both.session.username.?);
    try testing.expect(settings.use_http_path);
    try testing.expectEqualStrings("repo", both.session.path.?);
}

test "a credential setting git dies on is refused" {
    for ([_][]const u8{
        "[credential]\n\thelper\n",
        "[credential]\n\tuseHttpPath = maybe\n",
        "[credential \"https://h\"]\n\tprotectProtocol = 2x\n",
        "[credential]\n\tinteractive\n",
    }) |text| {
        var config = try config_mod.Config.parseText(testing.allocator, text, .local);
        defer config.deinit();
        var session: Session = .{ .gpa = testing.allocator, .url = try url_mod.Url.parse("https://h/r") };
        defer session.deinit();
        try testing.expectError(error.InvalidCredentialSetting, session.fill(testing.io, .{ .config = &config }));
    }
}

test "a URL's parts are read as git's credential_from_url reads them" {
    const gpa = testing.allocator;
    var p = try UrlParts.read(gpa, "https://a%40b:p%3Aw@[::1]:8443//org/r%2Fx.git//?q", false);
    defer p.deinit(gpa);
    try testing.expectEqualStrings("https", p.protocol.?);
    try testing.expectEqualStrings("a@b", p.username.?);
    try testing.expectEqualStrings("p:w", p.password.?.expose());
    try testing.expectEqualStrings("[::1]:8443", p.host.?);
    try testing.expectEqualStrings("org/r/x.git//?q", p.path.?);
    var empty = try UrlParts.read(gpa, "https://@h%00x/", false);
    defer empty.deinit(gpa);
    try testing.expectEqualStrings("", empty.username.?);
    try testing.expect(!empty.username_from_url);
    try testing.expectEqualStrings("h%00x", empty.host.?);
    try testing.expect(empty.path == null);
    try testing.expectError(error.NoScheme, UrlParts.read(gpa, "h/r", false));
    try testing.expectError(error.CredentialValueUnsafe, UrlParts.read(gpa, "https://h/a%0a", false));
    var partial = try UrlParts.read(gpa, "u@/p", true);
    defer partial.deinit(gpa);
    try testing.expect(partial.host == null and partial.protocol == null);
    try testing.expectEqualStrings("u", partial.username.?);
}

test "a URL whose user decodes to a newline is refused before any helper is asked, as git refuses it" {
    var config = try config_mod.Config.parseText(testing.allocator, "[credential]\n\thelper = !cat >asked\n", .local);
    defer config.deinit();
    for ([_][]const u8{
        "https://u%0ahost=github.com@attacker.example/repo.git",
        "https://u:p%0Ahost=github.com@attacker.example/repo.git",
    }) |text| {
        var session: Session = .{ .gpa = testing.allocator, .url = try url_mod.Url.parse(text) };
        defer session.deinit();
        // No programs are granted: a helper reached would be
        // `ProgramsNotGranted`.
        try testing.expectError(error.CredentialValueUnsafe, session.fill(testing.io, .{ .config = &config }));
        try testing.expectError(error.CredentialValueUnsafe, session.fill(testing.io, .{ .config = &config }));
        try testing.expect(session.authorization() == null);
        try testing.expectEqual(@as(usize, 0), session.asked.items.len);
    }
}

test "a value with a newline is never written to a helper, nor one with a carriage return unless credential.protectProtocol is false" {
    var config = try config_mod.Config.parseText(testing.allocator, "[credential]\n\tprotectProtocol = false\n", .local);
    defer config.deinit();
    const Case = struct { path: []const u8 = "r.git", username: ?[]const u8 = null, cr: bool };
    for ([_]Case{
        .{ .path = "a\rhost=github.com", .cr = true },
        .{ .username = "u\rhost=github.com", .cr = true },
        .{ .username = "u\nhost=github.com", .cr = false },
    }) |case| {
        for ([_]?*const config_mod.Config{ null, &config }) |with| {
            var session: Session = .{ .gpa = testing.allocator, .url = try url_mod.Url.parse("https://example.com/r.git") };
            defer session.deinit();
            try session.fromOrigin();
            try session.configure(with);
            try replace(testing.allocator, &session.path, case.path);
            if (case.username) |u| try replace(testing.allocator, &session.username, u);
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            if (with != null and case.cr) {
                try session.write(&out.writer, .helper);
            } else {
                try testing.expectError(error.CredentialValueUnsafe, session.write(&out.writer, .helper));
            }
        }
    }
}

test "a refused credential is forgotten even when a helper cannot be told" {
    var config = try config_mod.Config.parseText(testing.allocator, "[credential]\n\thelper = store\n", .local);
    defer config.deinit();
    var session: Session = .{ .gpa = testing.allocator, .url = try url_mod.Url.parse("https://ada:secret@example.com/r.git") };
    defer session.deinit();
    try testing.expect(session.hasInitial());
    try testing.expectError(error.ProgramsNotGranted, session.reject(testing.io, .{ .config = &config }));
    try testing.expect(session.password == null);
    try testing.expect(session.username == null);
    try testing.expectEqualStrings("ada", session.refused_username.?);
}

test "a helper's answer is read a line at a time, to an empty line or one with no '='" {
    var session: Session = .{ .gpa = testing.allocator, .url = try url_mod.Url.parse("https://h/r") };
    defer session.deinit();
    try session.fromOrigin();
    try testing.expect(try session.readAnswer(.init("username=a\x00b\npassword=p\r\r\nbroken\nhost=other\n")));
    try testing.expectEqualStrings("a", session.username.?);
    try testing.expectEqualStrings("p\r", session.exposePassword().?);
    try testing.expectEqualStrings("h", session.host.?);
    try testing.expectError(error.InvalidCredentialAnswer, session.readAnswer(.init("quit=maybe\n")));
    _ = try session.readAnswer(.init("password_expiry_utc=-1\n"));
    try testing.expectEqual(no_expiry, session.password_expiry_utc);
    _ = try session.readAnswer(.init("password_expiry_utc= 12x\n"));
    try testing.expectEqual(@as(u64, 12), session.password_expiry_utc);
    _ = try session.readAnswer(.init("password_expiry_utc=99999999999999999999\n"));
    try testing.expectEqual(no_expiry, session.password_expiry_utc);
}

test "fuzz: a helper's answer is read or ignored, never trusted into a crash" {
    try shakedown.check(testing.allocator, {}, fuzzAnswer, .{});
}

fn fuzzAnswer(_: void, case: *shakedown.Case) anyerror!void {
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..shakedown.gen.intRange(case.source, usize, 0, scratch.len)];
    case.source.bytes(input);
    var session: Session = .{ .gpa = testing.allocator, .url = try url_mod.Url.parse("https://git.example.com/r.git") };
    defer session.deinit();
    try session.fromOrigin();
    _ = session.readAnswer(.init(input)) catch |err| switch (err) {
        error.InvalidCredentialAnswer => return,
        else => |e| return e,
    };
    // A `url=` may have left no host: git dies writing it, and so it is
    // not written.
    if (session.protocol == null or session.host == null) return;
    // Whatever was taken is handed back to a helper as git would.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    session.write(&out.writer, .response) catch |err| switch (err) {
        // A carriage return inside a value is refused, as git refuses it.
        error.CredentialValueUnsafe => {},
        else => |e| return e,
    };
    _ = session.authorization();
}
