//! Credentials for an HTTP remote: git's credential helper protocol, and the
//! prompt git falls back to.
//!
//! relic stores nothing and caches nothing; the person's helpers do. When a
//! server answers 401 the credential is filled the way git's
//! `credential_fill` fills it: a username and password the URL carries are
//! used as they are; otherwise each configured `credential.helper` is asked,
//! in order, until one has both; otherwise what is still missing is asked
//! for — through `GIT_ASKPASS`, `core.askPass` or `SSH_ASKPASS`, as git asks
//! for it, or through the caller's own `Prompt`, which is what stands in for
//! the terminal git would otherwise use. A credential that then works is
//! handed to every helper to `store`; one that does not is handed to every
//! helper to `erase`.
//!
//! A helper is `!<command line>`, an absolute path, or a name, which is
//! `git credential-<name>`, each run with the operation appended through a
//! shell, exactly as git runs one. It reads `key=value` lines and answers
//! with them. `credential.<url>.*` settings apply to the URLs they match,
//! by scheme, host — a `*` standing for one label — port, user and leading
//! path, and a `helper` set to nothing clears the list before it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("config.zig");
const program = @import("program.zig");
const url_mod = @import("url.zig");

pub const Error = error{
    /// A helper answered `quit=1`, which ends the search.
    CredentialHelperQuit,
    /// No helper had the credential, and there was nothing to ask.
    CredentialsUnavailable,
    /// A helper, or an askpass program, is configured and the caller handed
    /// in no `program.Programs` to run it with.
    ProgramsNotGranted,
} || program.Error;

/// What is asked for.
pub const Field = enum { username, password };

/// The caller's stand-in for a terminal prompt.
pub const Prompt = struct {
    context: ?*anyopaque = null,
    /// Answer `field` for the prompt text git would show —
    /// `Username for 'https://example.com': ` — with an answer the
    /// caller's allocator owns, or `null` to decline.
    ask: *const fn (context: ?*anyopaque, gpa: Allocator, field: Field, prompt: []const u8) Allocator.Error!?[]u8,
};

/// What `fill` needs besides the URL.
pub const Options = struct {
    config: ?*const config_mod.Config = null,
    programs: ?program.Programs = null,
    prompt: ?Prompt = null,
};

/// The credential for one URL, over the life of one conversation.
pub const Session = struct {
    gpa: Allocator,
    url: url_mod.Url,
    username: ?[]u8 = null,
    password: ?[]u8 = null,
    header: ?[]u8 = null,
    /// Whether the username came from the URL, which configuration does not
    /// override.
    username_from_url: bool = false,
    initialised: bool = false,

    pub fn deinit(s: *Session) void {
        s.clear();
        s.* = undefined;
    }

    fn clear(s: *Session) void {
        if (s.username) |u| s.gpa.free(u);
        if (s.password) |p| {
            std.crypto.secureZero(u8, p);
            s.gpa.free(p);
        }
        if (s.header) |h| {
            std.crypto.secureZero(u8, h);
            s.gpa.free(h);
        }
        s.username = null;
        s.password = null;
        s.header = null;
    }

    fn fromUrl(s: *Session) Allocator.Error!void {
        if (s.initialised) return;
        s.initialised = true;
        if (s.url.user) |user| {
            s.username = try percentDecode(s.gpa, user);
            s.username_from_url = true;
        }
        if (s.url.password) |password| s.password = try percentDecode(s.gpa, password);
    }

    /// The `Authorization` header's value, when both a username and a
    /// password are known.
    pub fn authorization(s: *Session) ?[]const u8 {
        s.fromUrl() catch return null;
        if (s.header) |h| return h;
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

    /// Fill in what is missing, after the server asked for it. Returns
    /// whether a username and password are now known.
    pub fn fill(s: *Session, io: Io, opts: Options) Error!bool {
        try s.fromUrl();
        if (s.header) |h| {
            std.crypto.secureZero(u8, h);
            s.gpa.free(h);
            s.header = null;
        }
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
        if (s.username != null and s.password != null) return true;

        for (settings.helpers) |helper| {
            const programs = opts.programs orelse return error.ProgramsNotGranted;
            var answer = try s.runHelper(io, programs, arena, helper, "get", settings.use_http_path);
            defer answer.deinit(s.gpa);
            if (answer.username) |name| {
                if (s.username) |u| s.gpa.free(u);
                s.username = try s.gpa.dupe(u8, name);
            }
            if (answer.password) |password| {
                if (s.password) |p| s.gpa.free(p);
                s.password = try s.gpa.dupe(u8, password);
            }
            if (s.username != null and s.password != null) return true;
            if (answer.quit) return error.CredentialHelperQuit;
        }

        // Ask for what is still missing, as git's `credential_getpass`.
        if (s.username == null) {
            const prompt = try std.fmt.allocPrint(arena, "Username for '{s}': ", .{try s.describe(arena, false)});
            s.username = try s.ask(io, opts, .username, prompt) orelse return false;
        }
        if (s.password == null) {
            const prompt = try std.fmt.allocPrint(arena, "Password for '{s}': ", .{try s.describe(arena, true)});
            s.password = try s.ask(io, opts, .password, prompt) orelse return false;
        }
        return true;
    }

    /// The credential worked: every helper is told to `store` it.
    pub fn approve(s: *Session, io: Io, opts: Options) Error!void {
        if (s.username == null or s.password == null) return;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const settings = try applyConfig(arena_state.allocator(), opts.config, s.url);
        if (settings.helpers.len == 0) return;
        const programs = opts.programs orelse return error.ProgramsNotGranted;
        for (settings.helpers) |helper| {
            var answer = try s.runHelper(io, programs, arena_state.allocator(), helper, "store", settings.use_http_path);
            answer.deinit(s.gpa);
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
                var answer = try s.runHelper(io, programs, arena_state.allocator(), helper, "erase", settings.use_http_path);
                answer.deinit(s.gpa);
            }
        }
        s.clear();
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

    const Answer = struct {
        username: ?[]u8 = null,
        password: ?[]u8 = null,
        quit: bool = false,

        fn deinit(a: *Answer, gpa: Allocator) void {
            if (a.username) |u| gpa.free(u);
            if (a.password) |p| {
                std.crypto.secureZero(u8, p);
                gpa.free(p);
            }
        }
    };

    fn runHelper(
        s: *Session,
        io: Io,
        programs: program.Programs,
        arena: Allocator,
        helper: []const u8,
        operation: []const u8,
        use_http_path: bool,
    ) Error!Answer {
        const command = if (helper[0] == '!')
            try std.fmt.allocPrint(arena, "{s} {s}", .{ helper[1..], operation })
        else if (std.fs.path.isAbsolute(helper))
            try std.fmt.allocPrint(arena, "{s} {s}", .{ helper, operation })
        else
            try std.fmt.allocPrint(arena, "git credential-{s} {s}", .{ helper, operation });

        var input: std.ArrayList(u8) = .empty;
        defer {
            std.crypto.secureZero(u8, input.items);
            input.deinit(s.gpa);
        }
        try input.print(s.gpa, "protocol={s}\nhost={s}\n", .{ @tagName(s.url.scheme), try s.hostField(arena) });
        if (use_http_path) {
            const path = std.mem.trimStart(u8, s.url.path, "/");
            if (path.len != 0) try input.print(s.gpa, "path={s}\n", .{path});
        }
        if (s.username) |u| try input.print(s.gpa, "username={s}\n", .{u});
        if (!std.mem.eql(u8, operation, "get")) {
            if (s.password) |p| try input.print(s.gpa, "password={s}\n", .{p});
        }

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
        // skips it.
        if (!outcome.succeeded() or !std.mem.eql(u8, operation, "get")) return .{};
        var answer: Answer = .{};
        errdefer answer.deinit(s.gpa);
        var lines = std.mem.splitScalar(u8, outcome.stdout, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) break;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            if (std.mem.eql(u8, key, "username")) {
                if (answer.username) |u| s.gpa.free(u);
                answer.username = try s.gpa.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "password")) {
                if (answer.password) |p| s.gpa.free(p);
                answer.password = try s.gpa.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "quit")) {
                answer.quit = config_mod.parseBool(value) catch false;
            }
        }
        return answer;
    }

    /// Ask for one field: `GIT_ASKPASS`, then `core.askPass`, then
    /// `SSH_ASKPASS`, as git's `git_prompt`, and the caller's prompt when
    /// none is set.
    fn ask(s: *Session, io: Io, opts: Options, field: Field, prompt: []const u8) Error!?[]u8 {
        var askpass: ?[]const u8 = null;
        if (opts.programs) |programs| askpass = programs.environ.get("GIT_ASKPASS");
        var config_value: ?[]u8 = null;
        defer if (config_value) |v| s.gpa.free(v);
        if (askpass == null) {
            if (opts.config) |config| {
                if (config.get("core.askpass")) |raw| {
                    config_value = config_mod.unquote(s.gpa, raw) catch null;
                    if (config_value) |v| {
                        if (v.len != 0) askpass = v;
                    }
                }
            }
        }
        if (askpass == null) {
            if (opts.programs) |programs| askpass = programs.environ.get("SSH_ASKPASS");
        }
        if (askpass) |command| {
            if (command.len != 0) {
                const programs = opts.programs orelse return error.ProgramsNotGranted;
                var outcome = try program.run(programs, s.gpa, io, .{
                    .argv = &.{ command, prompt },
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
        }
        const p = opts.prompt orelse return error.CredentialsUnavailable;
        const answer = try p.ask(p.context, s.gpa, field, prompt);
        const owned = answer orelse return null;
        defer s.gpa.free(owned);
        return try s.gpa.dupe(u8, owned);
    }
};

const Settings = struct {
    helpers: []const []const u8,
    username: ?[]const u8,
    use_http_path: bool,
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
        }
    }
    settings.helpers = helpers.items;
    return settings;
}

/// Whether a `credential.<pattern>` subsection applies to `url`: git's
/// `urlmatch`.
pub fn urlMatches(pattern: []const u8, url: url_mod.Url) bool {
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
