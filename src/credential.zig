//! Credentials for an HTTP remote: git's credential helper protocol, and the
//! prompt git falls back to.
//!
//! relic stores nothing and caches nothing; the person's helpers do. When a
//! server answers 401 the credential is filled the way git's
//! `credential_fill` fills it: a username and password the URL carries are
//! used as they are; otherwise each configured `credential.helper` is asked,
//! in order, until one has a credential; otherwise what is still missing is
//! asked for — but only through the caller's `Prompt`, which stands in for
//! the terminal git would use, and through the person's askpass program
//! only when that prompt says so. A library in a daemon or an editor must
//! not put a question in front of a person its caller did not ask for. A
//! credential that then works is handed to every helper to `store`; one
//! that does not is handed to every helper to `erase`.
//!
//! A helper is `!<command line>`, an absolute path, or a name, which is
//! `git credential-<name>` — `osxkeychain`, `manager`, `store`, `cache`,
//! `libsecret` — each run with the operation appended through a shell,
//! exactly as git runs one. It reads `key=value` lines and answers with
//! them. `credential.<url>.*` settings apply to the URLs they match, by
//! scheme, host — a `*` standing for one label — port, user and leading
//! path, or, for a pattern with no scheme, by host and path alone, as git's
//! partial match reads it; and a `helper` set to nothing clears the list
//! before it, which is how `gh auth setup-git` puts itself first for one
//! host.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("config.zig");
const program = @import("program.zig");
const url_mod = @import("url.zig");
const auth = @import("auth.zig");

/// Errors from filling, storing or erasing a credential.
pub const Error = error{
    /// A helper answered `quit=1`, which ends the search.
    CredentialHelperQuit,
    /// No helper had the credential, and there was nothing to ask: the
    /// caller gave no `Prompt`.
    CredentialsUnavailable,
    /// A helper asked for a conversation of more than one round
    /// (`continue=1`), which the schemes that need it — NTLM, Negotiate —
    /// use and relic does not speak.
    CredentialMultistageUnsupported,
    /// A helper, or an askpass program, is configured and the caller handed
    /// in no `program.Programs` to run it with.
    ProgramsNotGranted,
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
    /// `Username for 'https://example.com': ` — with an answer the
    /// caller's allocator owns, or `null` to decline. `null` here asks
    /// nothing beyond askpass.
    ask: ?*const fn (context: ?*anyopaque, gpa: Allocator, field: Field, prompt: []const u8) Allocator.Error!?[]u8 = null,
};

/// What `fill` needs besides the URL.
pub const Options = struct {
    config: ?*const config_mod.Config = null,
    programs: ?program.Programs = null,
    prompt: ?Prompt = null,
};

/// The credential for one URL, over the life of one conversation.
///
/// It speaks git's helper protocol as git 2.55 speaks it, capabilities
/// included: a helper may answer with a username and password, or — having
/// said `capability[]=authtype` — with an `authtype` and a `credential`
/// that become the `Authorization` header as they are, which is how a
/// bearer token arrives; `state[]` values and the token's
/// `oauth_refresh_token` and `password_expiry_utc` are handed back to the
/// helpers with `store` and `erase`, as git hands them back.
pub const Session = struct {
    gpa: Allocator,
    url: url_mod.Url,
    username: ?[]u8 = null,
    password: ?[]u8 = null,
    /// `authtype` and `credential`, from a helper that announced the
    /// `authtype` capability.
    authtype: ?[]u8 = null,
    credential: ?[]u8 = null,
    ephemeral: bool = false,
    oauth_refresh_token: ?[]u8 = null,
    password_expiry_utc: ?u64 = null,
    state: std.ArrayList([]u8) = .empty,
    /// The capabilities the answering helper announced.
    capa_authtype: bool = false,
    capa_state: bool = false,
    /// The server's `WWW-Authenticate` values from its last refusal, which
    /// git hands every helper.
    challenges: std.ArrayList([]u8) = .empty,
    header: ?[]u8 = null,
    /// Whether the username came from the URL, which configuration does not
    /// override.
    username_from_url: bool = false,
    initialised: bool = false,
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

    /// Forget the credential, clearing its bytes, and release everything.
    pub fn deinit(s: *Session) void {
        s.clear();
        s.clearChallenges();
        s.challenges.deinit(s.gpa);
        s.state.deinit(s.gpa);
        for (s.asked.items) |h| s.gpa.free(h.command);
        s.asked.deinit(s.gpa);
        if (s.refused_username) |u| s.gpa.free(u);
        s.* = undefined;
    }

    fn secretFree(gpa: Allocator, bytes: ?[]u8) void {
        if (bytes) |b| {
            std.crypto.secureZero(u8, b);
            gpa.free(b);
        }
    }

    fn clear(s: *Session) void {
        if (s.username) |u| s.gpa.free(u);
        secretFree(s.gpa, s.password);
        secretFree(s.gpa, s.credential);
        secretFree(s.gpa, s.oauth_refresh_token);
        secretFree(s.gpa, s.header);
        if (s.authtype) |a| s.gpa.free(a);
        for (s.state.items) |v| s.gpa.free(v);
        s.state.clearRetainingCapacity();
        s.username = null;
        s.password = null;
        s.credential = null;
        s.authtype = null;
        s.oauth_refresh_token = null;
        s.password_expiry_utc = null;
        s.header = null;
        s.ephemeral = false;
        s.capa_authtype = false;
        s.capa_state = false;
        s.source = .none;
    }

    fn clearChallenges(s: *Session) void {
        for (s.challenges.items) |c| s.gpa.free(c);
        s.challenges.clearRetainingCapacity();
    }

    /// Keep the server's `WWW-Authenticate` values from a refusal, for
    /// the helpers; an answer with none clears them, as git clears them.
    pub fn setChallenges(s: *Session, values: []const []const u8) Allocator.Error!void {
        s.clearChallenges();
        for (values) |v| {
            const owned = try s.gpa.dupe(u8, v);
            errdefer s.gpa.free(owned);
            try s.challenges.append(s.gpa, owned);
        }
    }

    fn fromUrl(s: *Session) Allocator.Error!void {
        if (s.initialised) return;
        s.initialised = true;
        if (s.url.user) |user| {
            s.username = try percentDecode(s.gpa, user);
            s.username_from_url = true;
        }
        if (s.url.password) |password| {
            s.password = try percentDecode(s.gpa, password);
            if (s.username != null) s.source = .url;
        }
    }

    fn hasCredential(s: *const Session) bool {
        return (s.capa_authtype and s.authtype != null and s.credential != null) or
            (s.username != null and s.password != null);
    }

    /// The `Authorization` header's value, when a credential is known:
    /// `<authtype> <credential>` from a helper that gave one, else
    /// `Basic` over the username and password.
    pub fn authorization(s: *Session) ?[]const u8 {
        s.fromUrl() catch return null;
        if (s.header) |h| return h;
        if (s.capa_authtype) {
            if (s.authtype) |kind| if (s.credential) |value| {
                s.header = std.fmt.allocPrint(s.gpa, "{s} {s}", .{ kind, value }) catch return null;
                return s.header;
            };
        }
        const user = s.username orelse return null;
        const password = s.password orelse return null;
        const encoder = std.base64.standard.Encoder;
        const plain_len = user.len + 1 + password.len;
        const plain = s.gpa.alloc(u8, plain_len) catch return null;
        defer {
            std.crypto.secureZero(u8, plain);
            s.gpa.free(plain);
        }
        @memcpy(plain[0..user.len], user);
        plain[user.len] = ':';
        @memcpy(plain[user.len + 1 ..], password);
        const header = s.gpa.alloc(u8, "Basic ".len + encoder.calcSize(plain_len)) catch return null;
        @memcpy(header[0.."Basic ".len], "Basic ");
        _ = encoder.encode(header["Basic ".len..], plain);
        s.header = header;
        return header;
    }

    /// Whether a credential is in hand before any helper was asked: the
    /// one the URL carries.
    pub fn hasInitial(s: *Session) bool {
        s.fromUrl() catch return false;
        return s.hasCredential();
    }

    /// Fill in what is missing, after the server asked for it, as git's
    /// `credential_fill` fills it. Returns whether a credential is now
    /// known; `false` means the person was asked and declined.
    pub fn fill(s: *Session, io: Io, opts: Options) Error!bool {
        try s.fromUrl();
        secretFree(s.gpa, s.header);
        s.header = null;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const settings = try applyConfig(arena, opts.config, s.url);
        if (!s.username_from_url) {
            if (settings.username) |name| {
                if (s.username) |u| s.gpa.free(u);
                s.username = try s.gpa.dupe(u8, name);
            }
        }
        if (s.hasCredential()) return true;

        for (settings.helpers) |helper| {
            const programs = opts.programs orelse {
                try s.noteAsked(helper, .failed);
                return error.ProgramsNotGranted;
            };
            const outcome = try s.runHelper(io, programs, arena, helper, .get, settings.use_http_path);
            const answer: auth.Failure.Answer = switch (outcome) {
                .failed => .failed,
                .answered => |a| if (a.quit) .quit else if (s.hasCredential()) .credential else if (a.any) .partial else .nothing,
            };
            try s.noteAsked(helper, answer);
            if (s.hasCredential()) {
                s.source = .helper;
                return true;
            }
            if (answer == .quit) return error.CredentialHelperQuit;
        }

        // Ask for what is still missing, as git's `credential_getpass`.
        if (!settings.interactive) return error.CredentialsUnavailable;
        if (s.username == null) {
            const prompt = try std.fmt.allocPrint(arena, "Username for '{s}': ", .{try s.describe(arena, false)});
            s.username = try s.ask(io, opts, .username, prompt) orelse return false;
        }
        if (s.password == null) {
            const prompt = try std.fmt.allocPrint(arena, "Password for '{s}': ", .{try s.describe(arena, true)});
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

    /// The credential worked: every helper is told to `store` it.
    pub fn approve(s: *Session, io: Io, opts: Options) Error!void {
        if (!s.hasCredential()) return;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const settings = try applyConfig(arena_state.allocator(), opts.config, s.url);
        if (settings.helpers.len == 0) return;
        const programs = opts.programs orelse return error.ProgramsNotGranted;
        for (settings.helpers) |helper| {
            _ = try s.runHelper(io, programs, arena_state.allocator(), helper, .store, settings.use_http_path);
        }
    }

    /// The credential was refused: every helper is told to `erase` it, and
    /// it is forgotten here.
    pub fn reject(s: *Session, io: Io, opts: Options) Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const settings = try applyConfig(arena_state.allocator(), opts.config, s.url);
        if (settings.helpers.len != 0) {
            const programs = opts.programs orelse return error.ProgramsNotGranted;
            for (settings.helpers) |helper| {
                _ = try s.runHelper(io, programs, arena_state.allocator(), helper, .erase, settings.use_http_path);
            }
        }
        if (s.refused_username) |u| s.gpa.free(u);
        s.refused_username = if (s.username) |u| try s.gpa.dupe(u8, u) else null;
        s.refused_source = s.source;
        s.clear();
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

    /// `protocol://[username@]host[/path]`, as git's `credential_describe`
    /// writes it in a prompt.
    fn describe(s: *Session, arena: Allocator, with_user: bool) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{s}://", .{@tagName(s.url.scheme)});
        if (with_user) {
            if (s.username) |u| try out.print(arena, "{s}@", .{u});
        }
        try out.appendSlice(arena, try s.hostField(arena));
        return out.items;
    }

    fn hostField(s: *Session, arena: Allocator) Allocator.Error![]const u8 {
        if (s.url.port) |port| return std.fmt.allocPrint(arena, "{s}:{d}", .{ s.url.host, port });
        return s.url.host;
    }

    const Operation = enum { get, store, erase };

    const Outcome = union(enum) {
        failed,
        answered: struct { any: bool, quit: bool },
    };

    /// What git's `credential_write` writes for `operation`, in its order.
    fn writeInput(s: *Session, arena: Allocator, out: *std.ArrayList(u8), operation: Operation, use_http_path: bool) Allocator.Error!void {
        // git announces what it can take when it asks, and repeats back only
        // what the helper that answered announced.
        const authtype = operation == .get or s.capa_authtype;
        const state = operation == .get or s.capa_state;
        if (authtype) try out.appendSlice(s.gpa, "capability[]=authtype\n");
        if (state) try out.appendSlice(s.gpa, "capability[]=state\n");
        if (authtype) {
            if (s.authtype) |v| try out.print(s.gpa, "authtype={s}\n", .{v});
            if (s.credential) |v| try out.print(s.gpa, "credential={s}\n", .{v});
            if (s.ephemeral) try out.appendSlice(s.gpa, "ephemeral=1\n");
        }
        try out.print(s.gpa, "protocol={s}\nhost={s}\n", .{ @tagName(s.url.scheme), try s.hostField(arena) });
        if (use_http_path) {
            const path = std.mem.trimStart(u8, s.url.path, "/");
            if (path.len != 0) try out.print(s.gpa, "path={s}\n", .{path});
        }
        if (s.username) |u| try out.print(s.gpa, "username={s}\n", .{u});
        if (operation != .get) {
            if (s.password) |p| try out.print(s.gpa, "password={s}\n", .{p});
        }
        if (s.oauth_refresh_token) |t| try out.print(s.gpa, "oauth_refresh_token={s}\n", .{t});
        if (s.password_expiry_utc) |t| try out.print(s.gpa, "password_expiry_utc={d}\n", .{t});
        for (s.challenges.items) |c| try out.print(s.gpa, "wwwauth[]={s}\n", .{c});
        if (state) {
            for (s.state.items) |v| try out.print(s.gpa, "state[]={s}\n", .{v});
        }
    }

    fn runHelper(
        s: *Session,
        io: Io,
        programs: program.Programs,
        arena: Allocator,
        helper: []const u8,
        operation: Operation,
        use_http_path: bool,
    ) Error!Outcome {
        const command = if (helper[0] == '!')
            try std.fmt.allocPrint(arena, "{s} {t}", .{ helper[1..], operation })
        else if (std.fs.path.isAbsolute(helper))
            try std.fmt.allocPrint(arena, "{s} {t}", .{ helper, operation })
        else
            try std.fmt.allocPrint(arena, "git credential-{s} {t}", .{ helper, operation });

        var input: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, input.items);
            input.deinit(s.gpa);
        }
        try s.writeInput(arena, &input, operation, use_http_path);

        var outcome = try program.run(programs, s.gpa, io, .{
            .argv = &.{command},
            .shell = true,
            .stderr = .inherit,
        }, input.items, .{ .output = .limited(64 * 1024) });
        defer {
            std.crypto.secureZero(u8, outcome.stdout);
            outcome.deinit(s.gpa);
        }
        // A helper that fails, or that is not there, is skipped, as git
        // skips it. Only `get` is listened to.
        if (!outcome.succeeded()) return .failed;
        if (operation != .get) return .{ .answered = .{ .any = false, .quit = false } };
        return s.readAnswer(outcome.stdout);
    }

    /// Take a helper's answer to `get`, as git's `credential_read` does.
    fn readAnswer(s: *Session, text: []const u8) Error!Outcome {
        var any = false;
        var quit = false;
        var multistage = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) break;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            if (std.mem.eql(u8, key, "username")) {
                if (s.username) |u| s.gpa.free(u);
                s.username = try s.gpa.dupe(u8, value);
                any = true;
            } else if (std.mem.eql(u8, key, "password")) {
                secretFree(s.gpa, s.password);
                s.password = try s.gpa.dupe(u8, value);
                any = true;
            } else if (std.mem.eql(u8, key, "authtype")) {
                if (s.authtype) |a| s.gpa.free(a);
                s.authtype = try s.gpa.dupe(u8, value);
                any = true;
            } else if (std.mem.eql(u8, key, "credential")) {
                secretFree(s.gpa, s.credential);
                s.credential = try s.gpa.dupe(u8, value);
                any = true;
            } else if (std.mem.eql(u8, key, "ephemeral")) {
                s.ephemeral = config_mod.parseBool(value) catch false;
            } else if (std.mem.eql(u8, key, "oauth_refresh_token")) {
                secretFree(s.gpa, s.oauth_refresh_token);
                s.oauth_refresh_token = try s.gpa.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "password_expiry_utc")) {
                s.password_expiry_utc = std.fmt.parseUnsigned(u64, value, 10) catch null;
            } else if (std.mem.eql(u8, key, "state[]")) {
                const owned = try s.gpa.dupe(u8, value);
                errdefer s.gpa.free(owned);
                try s.state.append(s.gpa, owned);
            } else if (std.mem.eql(u8, key, "capability[]")) {
                if (std.mem.eql(u8, value, "authtype")) s.capa_authtype = true;
                if (std.mem.eql(u8, value, "state")) s.capa_state = true;
            } else if (std.mem.eql(u8, key, "continue")) {
                multistage = config_mod.parseBool(value) catch false;
            } else if (std.mem.eql(u8, key, "quit")) {
                quit = config_mod.parseBool(value) catch false;
            }
        }
        if (multistage and s.capa_state) return error.CredentialMultistageUnsupported;
        return .{ .answered = .{ .any = any, .quit = quit } };
    }

    /// Ask for one field. With the caller's leave, the person's askpass
    /// first — `GIT_ASKPASS`, then `core.askPass`, then `SSH_ASKPASS`, as
    /// git's `git_prompt` — and then the caller's own prompt.
    fn ask(s: *Session, io: Io, opts: Options, field: Field, prompt: []const u8) Error!?[]u8 {
        const p = opts.prompt orelse return error.CredentialsUnavailable;
        if (p.askpass) {
            if (try s.askpass(io, opts, prompt)) |answer| return answer;
        }
        const ask_fn = p.ask orelse return error.CredentialsUnavailable;
        s.prompted = true;
        const answer = try ask_fn(p.context, s.gpa, field, prompt);
        const owned = answer orelse return null;
        defer s.gpa.free(owned);
        return try s.gpa.dupe(u8, owned);
    }

    fn askpass(s: *Session, io: Io, opts: Options, prompt: []const u8) Error!?[]u8 {
        var command: ?[]const u8 = null;
        if (opts.programs) |programs| command = programs.environ.get("GIT_ASKPASS");
        var config_value: ?[]u8 = null;
        defer if (config_value) |v| s.gpa.free(v);
        if (command == null) {
            if (opts.config) |config| {
                if (config.get("core.askpass")) |raw| {
                    config_value = config_mod.unquote(s.gpa, raw) catch null;
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
        var outcome = try program.run(programs, s.gpa, io, .{
            .argv = &.{ line, prompt },
            .stderr = .inherit,
        }, "", .{ .output = .limited(64 * 1024) });
        defer {
            std.crypto.secureZero(u8, outcome.stdout);
            outcome.deinit(s.gpa);
        }
        if (!outcome.succeeded()) return null;
        const end = std.mem.indexOfAny(u8, outcome.stdout, "\r\n") orelse outcome.stdout.len;
        return try s.gpa.dupe(u8, outcome.stdout[0..end]);
    }
};

const Settings = struct {
    helpers: []const []const u8,
    username: ?[]const u8,
    use_http_path: bool,
    interactive: bool = true,
};

/// The `credential.*` settings that apply to `url`, in configuration
/// order: every helper, the last username, whether the path is sent.
fn applyConfig(arena: Allocator, config: ?*const config_mod.Config, url: url_mod.Url) Allocator.Error!Settings {
    var helpers: std.ArrayList([]const u8) = .empty;
    var settings: Settings = .{ .helpers = &.{}, .username = null, .use_http_path = false };
    const c = config orelse return settings;
    for (c.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "credential")) continue;
        if (entry.subsection.len != 0 and !urlMatches(entry.subsection, url)) continue;
        const raw = entry.value orelse "";
        const value = config_mod.unquote(arena, raw) catch continue;
        if (std.ascii.eqlIgnoreCase(entry.name, "helper")) {
            if (value.len == 0) {
                helpers.clearRetainingCapacity();
            } else try helpers.append(arena, value);
        } else if (std.ascii.eqlIgnoreCase(entry.name, "username")) {
            settings.username = value;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "usehttppath")) {
            settings.use_http_path = if (entry.value == null) true else config_mod.parseBool(value) catch false;
        } else if (std.ascii.eqlIgnoreCase(entry.name, "interactive")) {
            settings.interactive = if (entry.value == null) true else config_mod.parseBool(value) catch true;
        }
    }
    settings.helpers = helpers.items;
    return settings;
}

/// Whether a `credential.<pattern>` subsection applies to `url`: git's
/// `urlmatch`, or for a pattern with no scheme — `credential.github.com` —
/// git's partial match, which compares the parts the pattern has and no
/// others.
pub fn urlMatches(pattern: []const u8, url: url_mod.Url) bool {
    if (std.mem.indexOf(u8, pattern, "://") == null) return partialMatches(pattern, url);
    const parsed = url_mod.Url.parse(pattern) catch return false;
    if (parsed.scheme != url.scheme) return false;
    if (parsed.user) |user| {
        const theirs = url.user orelse return false;
        if (!std.mem.eql(u8, user, theirs)) return false;
    }
    if (!hostMatches(parsed.host, url.host)) return false;
    const default_port: u16 = if (url.scheme == .https) 443 else 80;
    if ((parsed.port orelse default_port) != (url.port orelse default_port)) return false;
    const want = std.mem.trimEnd(u8, parsed.path, "/");
    const have = url.path;
    if (want.len == 0) return true;
    if (!std.mem.startsWith(u8, have, want)) return false;
    return have.len == want.len or have[want.len] == '/';
}

/// git's `match_partial_url`: `[user@]host[:port][/path]`, each part that
/// is there compared exactly.
fn partialMatches(pattern: []const u8, url: url_mod.Url) bool {
    var rest = pattern;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        const user = rest[0..at];
        const theirs = url.user orelse return false;
        if (!std.mem.eql(u8, user, theirs)) return false;
        rest = rest[at + 1 ..];
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const host = rest[0 .. slash orelse rest.len];
    if (host.len != 0) {
        var buf: [300]u8 = undefined;
        const have = if (url.port) |port|
            std.fmt.bufPrint(&buf, "{s}:{d}", .{ url.host, port }) catch return false
        else
            url.host;
        if (!std.mem.eql(u8, host, have)) return false;
    }
    if (slash) |at| {
        const want = rest[at + 1 ..];
        if (want.len != 0 and !std.mem.eql(u8, want, std.mem.trimStart(u8, url.path, "/"))) return false;
    }
    return true;
}

/// A host pattern: labels compared without case, `*` standing for any one
/// label.
fn hostMatches(pattern: []const u8, host: []const u8) bool {
    var p = std.mem.splitScalar(u8, pattern, '.');
    var h = std.mem.splitScalar(u8, host, '.');
    while (true) {
        const a = p.next();
        const b = h.next();
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        if (std.mem.eql(u8, a.?, "*")) continue;
        if (!std.ascii.eqlIgnoreCase(a.?, b.?)) return false;
    }
}

fn percentDecode(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(gpa, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, text[i]);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "credential sections match URLs as git's urlmatch matches them" {
    const url = try url_mod.Url.parse("https://ada@git.example.com/org/repo.git");
    try testing.expect(urlMatches("https://git.example.com", url));
    try testing.expect(urlMatches("https://*.example.com", url));
    try testing.expect(urlMatches("https://git.example.com:443/org", url));
    try testing.expect(urlMatches("https://ada@git.example.com/org/", url));
    try testing.expect(!urlMatches("https://bob@git.example.com", url));
    try testing.expect(!urlMatches("http://git.example.com", url));
    try testing.expect(!urlMatches("https://example.com", url));
    try testing.expect(!urlMatches("https://git.example.com/org/rep", url));
    try testing.expect(!urlMatches("https://git.example.com:8443", url));
}

test "a helper list follows git's rule that an empty value clears it" {
    var config = try config_mod.Config.parseText(testing.allocator,
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
    , .local);
    defer config.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const settings = try applyConfig(arena_state.allocator(), &config, try url_mod.Url.parse("https://git.example.com/repo"));
    try testing.expectEqual(@as(usize, 2), settings.helpers.len);
    try testing.expectEqualStrings("!second --flag", settings.helpers[0]);
    try testing.expectEqualStrings("third", settings.helpers[1]);
    try testing.expectEqualStrings("ada", settings.username.?);
    try testing.expect(settings.use_http_path);
}
