//! Reaching a remote over ssh: the person's own `ssh`, started the way git
//! starts it.
//!
//! Which program runs is git's choice made the same way: `GIT_SSH_COMMAND`
//! from the caller's environment, then `core.sshCommand`, each a command
//! line a shell reads; else `GIT_SSH`, a program run directly; else `ssh`.
//! Which options it understands is its variant, from `GIT_SSH_VARIANT` or
//! `ssh.variant`, else from the program's name — `ssh`, `plink`,
//! `tortoiseplink` — and for any other name git asks the program itself:
//! one that accepts OpenSSH's `-G` is OpenSSH, and one that does not is
//! `simple`, which takes nothing but a host and a command. OpenSSH is asked
//! to pass `GIT_PROTOCOL` along, which is how protocol v2 is requested over
//! ssh; a port is `-p` to OpenSSH and `-P` to the PuTTY family, and a
//! `simple` ssh given one is refused by name, as git refuses it.
//!
//! The remote command is `git-upload-pack '<path>'` or
//! `git-receive-pack '<path>'`, the path quoted as git's `sq_quote` quotes
//! it. A host or a path beginning with `-` is refused, as git refuses it,
//! because `ssh` would read it as an option.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const program = @import("program.zig");
const config_mod = @import("config.zig");
const url_mod = @import("url.zig");
const connection = @import("connection.zig");
const auth = @import("auth.zig");
const warning = @import("warning.zig");

const Connection = connection.Connection;

/// Errors from starting a conversation over ssh.
pub const Error = error{
    /// The caller handed in no `program.Programs`, and ssh is a program.
    ProgramsNotGranted,
    /// The `simple` variant has no way to be given a port; git refuses the
    /// same.
    SshVariantRefusesPort,
    /// A host beginning with `-`, which `ssh` would read as an option.
    SuspiciousHostname,
    /// A path beginning with `-`, which the remote command would read as an
    /// option.
    SuspiciousPathname,
    /// `ssh` was refused: `Permission denied (publickey)` and its kin. The
    /// key the person's agent or config offers is not one the server
    /// takes.
    AuthenticationFailed,
    /// `ssh` does not know the server's host key, or it has changed, and
    /// will not go on without the person's word.
    HostKeyVerificationFailed,
} || connection.Error || program.Error;

/// The option dialect of the ssh program.
pub const Variant = enum {
    /// Unknown: ask the program with `-G`.
    auto,
    /// A host and a command, nothing else.
    simple,
    /// OpenSSH.
    ssh,
    plink,
    putty,
    tortoiseplink,

    /// The variant a `GIT_SSH_VARIANT` or `ssh.variant` value names. Any
    /// word git does not know is OpenSSH, as in git.
    pub fn parse(text: []const u8) Variant {
        if (std.mem.eql(u8, text, "auto")) return .auto;
        if (std.mem.eql(u8, text, "plink")) return .plink;
        if (std.mem.eql(u8, text, "putty")) return .putty;
        if (std.mem.eql(u8, text, "tortoiseplink")) return .tortoiseplink;
        if (std.mem.eql(u8, text, "simple")) return .simple;
        return .ssh;
    }
};

/// How the conversation is started.
pub const Options = struct {
    programs: ?program.Programs = null,
    config: ?*const config_mod.Config = null,
    /// The program asked for on the remote side, in place of
    /// `git-upload-pack` or `git-receive-pack`.
    service_program: ?[]const u8 = null,
    /// Ask an upload-pack for protocol v2.
    protocol_v2: bool = true,
    /// Where ssh's own messages go. Captured, the last of them is kept so
    /// that a refusal can say what ssh said (`explain`); a passphrase
    /// prompt or a host-key question is not among them, because ssh asks
    /// those on the terminal itself.
    stderr: enum { capture, inherit, ignore } = .capture,
    /// Where what ssh said goes, when the conversation goes on to succeed:
    /// a host key it added, a banner. git passes those to the person.
    warnings: ?*warning.Warnings = null,
};

/// The variables git clears before it runs a program for another
/// repository: they describe this one.
pub const local_repo_env = [_][]const u8{
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG",             "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",                 "GIT_OBJECT_DIRECTORY",   "GIT_DIR",
    "GIT_WORK_TREE",                    "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",                   "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",                       "GIT_SHALLOW_FILE",       "GIT_COMMON_DIR",
};

/// Start ssh to `url`'s host running `service` on `url`'s path.
pub fn connect(
    gpa: Allocator,
    io: Io,
    url: url_mod.Url,
    service: connection.Service,
    options: Options,
) Error!*Connection {
    const programs = options.programs orelse return error.ProgramsNotGranted;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (url.host.len != 0 and url.host[0] == '-') return error.SuspiciousHostname;
    if (url.user) |user| {
        if (user.len != 0 and user[0] == '-') return error.SuspiciousHostname;
    }
    if (url.path.len != 0 and url.path[0] == '-') return error.SuspiciousPathname;
    const host = if (url.user) |user| try std.fmt.allocPrint(arena, "{s}@{s}", .{ user, url.host }) else url.host;
    var port_buf: [8]u8 = undefined;
    const port: ?[]const u8 = if (url.port) |p| std.fmt.bufPrint(&port_buf, "{d}", .{p}) catch unreachable else null;

    // The program, and whether it is a command line.
    var command: []const u8 = "ssh";
    var shell = false;
    if (programs.environ.get("GIT_SSH_COMMAND")) |line| {
        command = line;
        shell = true;
    } else if (configValue(arena, options.config, "core.sshcommand")) |line| {
        command = line;
        shell = true;
    } else if (programs.environ.get("GIT_SSH")) |path| {
        command = path;
    }

    var variant = variantOf(arena, programs, options.config, command, shell);
    const v2 = options.protocol_v2 and service == .upload_pack;

    if (variant == .auto) {
        // Ask it: OpenSSH answers `-G` with its configuration and exit 0.
        var probe: std.ArrayList([]const u8) = .empty;
        try probe.appendSlice(arena, &.{ command, "-G" });
        try pushOptions(arena, &probe, .ssh, port, v2);
        try probe.append(arena, host);
        const probed = program.run(programs, gpa, io, .{
            .argv = probe.items,
            .shell = shell,
            .stderr = .ignore,
        }, "", .{ .output = .limited(1 << 20) });
        if (probed) |outcome_value| {
            var outcome = outcome_value;
            defer outcome.deinit(gpa);
            variant = if (outcome.succeeded()) .ssh else .simple;
        } else |err| switch (err) {
            error.OutputTooLong => variant = .simple,
            else => |e| return e,
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, command);
    try pushOptions(arena, &argv, variant, port, v2);
    try argv.append(arena, host);
    try argv.append(arena, try remoteCommand(arena, options.service_program orelse service.name(), url.path));

    const set: []const program.Var = if (v2 and variant == .ssh)
        &.{.{ .name = "GIT_PROTOCOL", .value = "version=2" }}
    else
        &.{};
    const conn = try connection.Process.start(gpa, io, programs, .{
        .argv = argv.items,
        .shell = shell,
        .set = set,
        .unset = &local_repo_env,
        .stderr = switch (options.stderr) {
            .capture => .capture,
            .inherit => .inherit,
            .ignore => .ignore,
        },
    });
    connection.Process.sayTo(conn, options.warnings);
    return conn;
}

/// Why a conversation over ssh ended before the remote said anything, as
/// the error a person can act on: ssh's own refusal of the key
/// (`AuthenticationFailed`), of the host (`HostKeyVerificationFailed`), or
/// the remote's last words — `ERROR: Repository not found.` — as the
/// connection's message on `TransportProgramFailed`. `err` is what the
/// protocol met, returned when ssh said nothing more telling. With
/// `failure`, a refusal is described there.
pub fn explain(gpa: Allocator, conn: *Connection, io: Io, err: anyerror, url: url_mod.Url, failure: ?*auth.Failure) Error {
    const ended = connection.Process.diagnose(conn, io) catch return error.Canceled;
    const said = std.mem.trim(u8, ended.stderr, " \t\r\n");
    const refusal: ?struct { e: Error, reason: auth.Failure.Reason } =
        if (std.mem.indexOf(u8, said, "Host key verification failed") != null or
        std.mem.indexOf(u8, said, "REMOTE HOST IDENTIFICATION HAS CHANGED") != null)
            .{ .e = error.HostKeyVerificationFailed, .reason = .host_key }
        else if (std.mem.indexOf(u8, said, "Permission denied") != null)
            .{ .e = error.AuthenticationFailed, .reason = .refused }
        else
            null;
    if (said.len != 0) conn.setMessage(said[if (std.mem.lastIndexOfScalar(u8, said, '\n')) |nl| nl + 1 else 0..]);
    if (refusal) |r| {
        if (failure) |f| describe: {
            f.begin(gpa, r.reason, url.scheme, url.raw) catch break :describe;
            f.setServerMessage(said) catch {};
            if (url.user) |user| f.username = f.allocator().dupe(u8, user) catch null;
        }
        return r.e;
    }
    if (said.len != 0 and (ended.code == null or ended.code.? != 0)) return error.TransportProgramFailed;
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.RemoteHungUp => error.RemoteHungUp,
        error.ProtocolError => error.ProtocolError,
        error.RemoteError => error.RemoteError,
        error.TransportProgramFailed => error.TransportProgramFailed,
        else => error.ConnectionFailed,
    };
}

fn configValue(arena: Allocator, config: ?*const config_mod.Config, key: []const u8) ?[]const u8 {
    const c = config orelse return null;
    const raw = c.get(key) orelse return null;
    return config_mod.unquote(arena, raw) catch null;
}

/// git's `determine_ssh_variant`.
fn variantOf(arena: Allocator, programs: program.Programs, config: ?*const config_mod.Config, command: []const u8, shell: bool) Variant {
    if (programs.environ.get("GIT_SSH_VARIANT")) |text| return Variant.parse(text);
    if (configValue(arena, config, "ssh.variant")) |text| return Variant.parse(text);
    // For a command line, the variant is its first word's.
    var first = command;
    if (shell) {
        const trimmed = std.mem.trim(u8, command, " \t");
        const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        first = std.mem.trim(u8, trimmed[0..end], "'\"");
    }
    const base_start = if (std.mem.lastIndexOfAny(u8, first, "/\\")) |slash| slash + 1 else 0;
    const base = first[base_start..];
    if (std.ascii.eqlIgnoreCase(base, "ssh") or std.ascii.eqlIgnoreCase(base, "ssh.exe")) return .ssh;
    if (std.ascii.eqlIgnoreCase(base, "plink") or std.ascii.eqlIgnoreCase(base, "plink.exe")) return .plink;
    if (std.ascii.eqlIgnoreCase(base, "tortoiseplink") or std.ascii.eqlIgnoreCase(base, "tortoiseplink.exe")) return .tortoiseplink;
    return .auto;
}

/// git's `push_ssh_options`.
fn pushOptions(arena: Allocator, argv: *std.ArrayList([]const u8), variant: Variant, port: ?[]const u8, v2: bool) Error!void {
    if (variant == .ssh and v2) try argv.appendSlice(arena, &.{ "-o", "SendEnv=GIT_PROTOCOL" });
    if (variant == .tortoiseplink) try argv.append(arena, "-batch");
    if (port) |p| {
        switch (variant) {
            .auto => unreachable,
            .simple => return error.SshVariantRefusesPort,
            .ssh => try argv.append(arena, "-p"),
            .plink, .putty, .tortoiseplink => try argv.append(arena, "-P"),
        }
        try argv.append(arena, p);
    }
}

/// `<program> '<path>'`, with the path quoted as git's `sq_quote` quotes
/// it: in single quotes, each `'` and `!` closed out, escaped and reopened.
pub fn remoteCommand(arena: Allocator, service_program: []const u8, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, service_program);
    try out.appendSlice(arena, " '");
    for (path) |c| {
        if (c == '\'' or c == '!') {
            try out.appendSlice(arena, "'\\");
            try out.append(arena, c);
            try out.append(arena, '\'');
        } else try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.items;
}

const testing = std.testing;

test "a path is quoted as git's sq_quote quotes it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("git-upload-pack '/srv/it'\\''s'\\!''", try remoteCommand(arena, "git-upload-pack", "/srv/it's!"));
}

const builtin = @import("builtin");
const testremote = @import("testremote.zig");

test "ssh without the permission to run it, or a port a simple ssh cannot take, is refused by name" {
    const gpa = testing.allocator;
    const io = testing.io;
    const url = try url_mod.Url.parse("ssh://example.invalid:2222/srv/repo");
    try testing.expectError(error.ProgramsNotGranted, connect(gpa, io, url, .upload_pack, .{}));
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = try testremote.environ(gpa);
    defer env.deinit();
    var config = try @import("config.zig").Config.parseText(gpa, "[ssh]\nvariant = simple\n", .local);
    defer config.deinit();
    try testing.expectError(error.SshVariantRefusesPort, connect(gpa, io, url, .upload_pack, .{
        .programs = .{ .environ = &env },
        .config = &config,
    }));
    const dashed = try url_mod.Url.parse("-oProxyCommand=evil:repo");
    try testing.expectError(error.SuspiciousHostname, connect(gpa, io, dashed, .upload_pack, .{ .programs = .{ .environ = &env } }));
}
