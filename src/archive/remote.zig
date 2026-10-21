//! An archive asked of another repository: git's `upload-archive`, the
//! server, and `git archive --remote`, the client.
//!
//! The client sends its arguments, each as `argument <arg>`, then a flush;
//! the server says `ACK` (or `NACK <reason>`) and a flush, then sends the
//! archive on side-band channel one, what the archiver says on channel
//! two, and when it fails git's "archiver died with error" on channel
//! three. The arguments are those of `git archive` less the ones only a
//! local one takes, read as git's remote archiver reads them: `--format`,
//! `--prefix`, `--mtime`, `--worktree-attributes`, `-0` to `-9`, `--list`,
//! the tree-ish and the paths. A tree-ish must start with a ref's name
//! unless `uploadarchive.allowUnreachable` says otherwise, so a client
//! cannot name an object no ref reaches.
//!
//! The client reaches a repository on this machine through this server, in
//! this process, and one over ssh through its `git-upload-archive`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pkt_line = @import("../codec.zig").pkt_line;
const side_band = @import("../wire.zig").side_band;
const connection = @import("../wire.zig").connection;
const url_mod = @import("../wire.zig").url;
const ssh = @import("../wire.zig").ssh;
const program = @import("../process.zig").program;
const config_mod = @import("../config/config.zig");
const date = @import("../text.zig").date;
const repo_mod = @import("../repo/repo.zig");
const rev_parse = @import("../rev_walk/rev_parse.zig");
const local = @import("../transport/local.zig");
const in_process = @import("../transport/in_process.zig");
const progress_mod = @import("../report.zig").progress;
const archive = @import("archive.zig");

const Connection = connection.Connection;

/// git's `deadchild`: what the server says on channel three when the
/// archive could not be made.
pub const died = "git upload-archive: archiver died with error";

/// What git's archiver prints for arguments it cannot read, as git 2.55
/// prints it, a blank line after it.
const usage =
    \\usage: git archive [<options>] <tree-ish> [<path>...]
    \\   or: git archive --list
    \\   or: git archive --remote <repo> [--exec <cmd>] [<options>] <tree-ish> [<path>...]
    \\   or: git archive --remote <repo> [--exec <cmd>] --list
    \\
    \\    --[no-]format <fmt>   archive format
    \\    --[no-]prefix <prefix>
    \\                          prepend prefix to each pathname in the archive
    \\    --[no-]add-file <file>
    \\                          add untracked file to archive
    \\    --[no-]add-virtual-file <path:content>
    \\                          add untracked file to archive
    \\    -o, --[no-]output <file>
    \\                          write the archive to this file
    \\    --[no-]worktree-attributes
    \\                          read .gitattributes in working directory
    \\    -v, --[no-]verbose    report archived files on stderr
    \\    --mtime <time>        set modification time of archive entries
    \\    -NUM                  set compression level
    \\
    \\    -l, --[no-]list       list supported archive formats
    \\
    \\    --[no-]remote <repo>  retrieve the archive from remote repository <repo>
    \\    --[no-]exec <command> path to the remote git-upload-archive command
    \\
    \\
;

/// The most arguments a client may send, as git's `MAX_ARGS` allows.
const max_args = 64;

/// How the server serves.
pub const ServeOptions = struct {
    /// For the filters and `export-subst` the archive runs.
    programs: ?program.Programs = null,
    /// The time now, for a tree archived without a commit's time.
    now: Io.Timestamp,
};

/// Errors from serving: the conversation's own. What the archiver refuses
/// is told to the client, and is no error here.
pub const ServeError = error{
    /// The client hung up, or writing to it failed.
    WriteFailed,
} || Io.Reader.Error || Allocator.Error || Io.Cancelable;

/// How a request ended.
pub const Served = enum {
    /// The archive, or the list of formats, was sent.
    archived,
    /// The client was told why not, and `died` after it: git's own server
    /// then says "sent error to the client: <died>" and exits with 128.
    refused,
};

/// git's `upload-archive`, over `in` and `out`, for `repo`.
pub fn serve(gpa: Allocator, io: Io, repo: *repo_mod.Repository, in: *Io.Reader, out: *Io.Writer, options: ServeOptions) ServeError!Served {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // As git's: the answer comes before the arguments are read, which its
    // writer reads, and what they come to goes on the side band.
    write(pkt_line.write(out, "ACK\n")) catch return error.WriteFailed;
    write(pkt_line.flush(out)) catch return error.WriteFailed;
    out.flush() catch return error.WriteFailed;

    var args: std.ArrayList([]const u8) = .empty;
    while (true) {
        const packet = pkt_line.read(in) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => return refuse(out, "'argument' token or flush expected", .{}),
        };
        const line = switch (packet) {
            .data => |d| std.mem.trimEnd(u8, d, "\n"),
            else => break,
        };
        if (args.items.len + 1 > max_args) return refuse(out, "Too many options (>{d})", .{max_args - 1});
        if (!std.mem.startsWith(u8, line, "argument ")) return refuse(out, "'argument' token or flush expected", .{});
        try args.append(arena, try arena.dupe(u8, line["argument ".len..]));
    }

    // What a client may ask for: `tar.<name>.remote` says for a filter.
    const known = archive.formats(arena, repo.configuration()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(out, "bad boolean config value for 'tar.*.remote'", .{}),
    };
    var offered: std.ArrayList(archive.Named) = .empty;
    for (known) |f| if (f.remote) try offered.append(arena, f);

    var why: []const u8 = "";
    var parsed = parse(arena, args.items, offered.items, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return refuseText(out, why),
    };
    var mux: side_band.Mux = .init(out, .large);
    const band = mux.writer();
    if (parsed.list) {
        for (offered.items) |f| band.print("{s}\n", .{f.name}) catch return error.WriteFailed;
        return end(&mux, out);
    }
    const treeish = parsed.treeish orelse return refuseText(out, usage);
    const allow_unreachable = repo.configuration().getBool("uploadarchive.allowunreachable", false) catch false;
    if (!allow_unreachable) {
        const name = treeish[0 .. std.mem.findScalar(u8, treeish, ':') orelse treeish.len];
        const found = rev_parse.dwimRef(arena, io, repo, name) catch null;
        if (found == null) return refuse(out, "no such ref: {s}", .{name});
    }
    const oid = rev_parse.resolve(gpa, io, repo, treeish) catch return refuse(out, "not a valid object name: {s}", .{treeish});
    if (parsed.mtime) |text| {
        const secs = date.approximate(text, .{ .now = options.now }) orelse return refuse(out, "invalid date format: {s}", .{text});
        parsed.options.mtime = .fromNanoseconds(@as(i96, secs) * std.time.ns_per_s);
    }
    parsed.options.now = options.now;
    parsed.options.programs = options.programs;
    archive.archive(gpa, io, .{ .repo = repo, .treeish = oid }, band, parsed.options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.PathspecNoMatch => return refuse(out, "pathspec '{s}' did not match any files", .{firstPath(parsed.options.pathspecs)}),
        else => return refuse(out, "{s}", .{@errorName(err)}),
    };
    return end(&mux, out);
}

fn firstPath(paths: []const []const u8) []const u8 {
    return if (paths.len != 0) paths[0] else "";
}

fn write(wrote: anyerror!void) error{WriteFailed}!void {
    wrote catch return error.WriteFailed;
}

/// The archive's last bytes and the flush that ends it.
fn end(mux: *side_band.Mux, out: *Io.Writer) ServeError!Served {
    mux.end() catch return error.WriteFailed;
    out.flush() catch return error.WriteFailed;
    return .archived;
}

/// What git's writer does when it dies: its message on channel two, as it
/// prints it, and git's `deadchild` on channel three, after which nothing
/// more is sent.
fn refuse(out: *Io.Writer, comptime fmt: []const u8, args: anytype) ServeError!Served {
    var buf: [1024]u8 = undefined;
    const text = std.mem.print(&buf, "fatal: " ++ fmt ++ "\n", args) catch "fatal: the archive cannot be made\n";
    return refuseText(out, text);
}

/// `refuse` with the message whole, as the archiver printed it.
fn refuseText(out: *Io.Writer, text: []const u8) ServeError!Served {
    side_band.send(out, .large, 2, text) catch return error.WriteFailed;
    side_band.send(out, .large, 3, died) catch return error.WriteFailed;
    out.flush() catch return error.WriteFailed;
    return .refused;
}

/// The arguments, as git's `parse_archive_args` takes a remote's.
const Parsed = struct {
    options: archive.Options = .{},
    treeish: ?[]const u8 = null,
    mtime: ?[]const u8 = null,
    list: bool = false,
};

/// The arguments read against the formats a client may ask for, or
/// `error.Refused` with what git's archiver prints in `why`.
fn parse(arena: Allocator, args: []const []const u8, offered: []const archive.Named, why: *[]const u8) error{ Refused, OutOfMemory }!Parsed {
    var p: Parsed = .{};
    var format: []const u8 = "tar";
    var level: ?u8 = null;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var options_done = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options_done or arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            if (p.treeish == null) p.treeish = arg else try paths.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            options_done = true;
            continue;
        }
        if (value(args, &i, "--format")) |v| {
            format = v;
        } else if (value(args, &i, "--prefix")) |v| {
            p.options.prefix = v;
        } else if (value(args, &i, "--mtime")) |v| {
            p.mtime = v;
        } else if (std.mem.eql(u8, arg, "--worktree-attributes")) {
            p.options.worktree_attributes = true;
        } else if (std.mem.eql(u8, arg, "--no-worktree-attributes")) {
            p.options.worktree_attributes = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            // What each file is named as it goes is the local archiver's.
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            p.list = true;
        } else if (arg.len == 2 and arg[1] >= '0' and arg[1] <= '9') {
            level = arg[1] - '0';
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.startsWith(u8, arg, "--output")) {
            return refused(why, "Unexpected option --output");
        } else if (std.mem.startsWith(u8, arg, "--remote")) {
            return refused(why, "Unexpected option --remote");
        } else if (std.mem.startsWith(u8, arg, "--exec")) {
            return refused(why, "the option '--exec' requires '--remote'");
        } else if (std.mem.startsWith(u8, arg, "--add-file") or std.mem.startsWith(u8, arg, "--add-virtual-file")) {
            return refused(why, "options '--add-file' and '--remote' cannot be used together");
        } else {
            const name = std.mem.trimStart(u8, arg, "-");
            why.* = try arena.print("error: unknown option `{s}'\n" ++ usage, .{name[0 .. std.mem.findScalar(u8, name, '=') orelse name.len]});
            return error.Refused;
        }
    }
    if (p.list) return p;
    p.options.format = for (offered) |f| {
        if (std.mem.eql(u8, f.name, format)) break f.format;
    } else {
        why.* = try arena.print("fatal: Unknown archive format '{s}'\n", .{format});
        return error.Refused;
    };
    if (level) |l| {
        if (p.options.format == .tar) {
            why.* = try arena.print("fatal: Argument not supported for format '{s}': -{d}\n", .{ format, l });
            return error.Refused;
        }
        p.options.level = @intCast(l);
    }
    p.options.pathspecs = paths.items;
    return p;
}

fn refused(why: *[]const u8, comptime text: []const u8) error{Refused} {
    why.* = "fatal: " ++ text ++ "\n";
    return error.Refused;
}

/// `--name=value`, or `--name value` taking the next argument.
fn value(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') return arg[name.len + 1 ..];
    if (std.mem.eql(u8, arg, name) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

// ----------------------------------------------------------------------
// The client
// ----------------------------------------------------------------------

/// How the client asks.
pub const FetchOptions = struct {
    /// `--exec`: the program asked for on the other side, in place of
    /// `git-upload-archive`.
    exec: ?[]const u8 = null,
    /// For ssh, and for the server's filters in this process.
    programs: ?program.Programs = null,
    config: ?*const config_mod.Config = null,
    /// What the server says on channel two.
    progress: ?progress_mod.Progress = null,
    /// The time now, for a repository on this machine archived here.
    now: Io.Timestamp = .zero,
    /// Where what the server said about a refusal or a failure is kept.
    said: ?*Said = null,
};

/// The server's words about why it refused or failed, cut to fit.
pub const Said = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(s: *const Said) []const u8 {
        return s.buffer[0..s.len];
    }

    fn keep(s: *Said, words: []const u8) void {
        s.len = @min(words.len, s.buffer.len);
        @memcpy(s.buffer[0..s.len], words[0..s.len]);
    }
};

/// Errors from asking for an archive.
pub const FetchError = error{
    /// The server answered `NACK`: `FetchOptions.said` keeps why.
    ArchiveRefused,
    /// The server could not make the archive: `FetchOptions.said` keeps
    /// what it said.
    ArchiveFailed,
    /// The server spoke something other than the protocol.
    ProtocolError,
    /// A URL relic has no way to ask an archive of.
    UnsupportedTransport,
} || connection.Error || ssh.Error || url_mod.ParseError || local.Error || Allocator.Error || Io.Cancelable;

/// git's `git archive --remote=<url> [<args>]`: `args` sent as git's
/// client sends them, and the archive written to `out`.
pub fn fetch(gpa: Allocator, io: Io, url: []const u8, args: []const []const u8, out: *Io.Writer, options: FetchOptions) FetchError!void {
    const parsed = try url_mod.Url.parse(url);
    const conn: *Connection = switch (parsed.scheme) {
        .local, .file => blk: {
            const here = try gpa.create(local.Remote);
            errdefer gpa.destroy(here);
            here.* = try local.Remote.open(gpa, io, url, .{});
            errdefer here.deinit(io);
            break :blk try in_process.InProcess(Server, toldNothing).create(gpa, io, here, .{
                .gpa = gpa,
                .io = io,
                .repo = &here.repo,
                .options = .{ .programs = options.programs, .now = options.now },
            });
        },
        .ssh => blk: {
            var identity = try url_mod.Identity.parse(gpa, url);
            defer identity.deinit();
            break :blk try ssh.connect(gpa, io, identity.url, .upload_archive, .{
                .programs = options.programs,
                .config = options.config,
                .service_program = options.exec,
                .protocol_v2 = false,
            });
        },
        else => return error.UnsupportedTransport,
    };
    defer conn.deinit(io);
    errdefer if (options.said) |said| said.keep(conn.message());

    const w = try conn.request();
    for (args) |arg| pkt_line.print("argument {s}\n", .{arg}, w) catch |err| return conn.writeFailed(err);
    pkt_line.flush(w) catch |err| return conn.writeFailed(err);
    const in = try conn.response();
    const first = pkt_line.read(in) catch return error.ProtocolError;
    const line = switch (first) {
        .data => |d| std.mem.trimEnd(u8, d, "\n"),
        else => return error.ProtocolError,
    };
    if (!std.mem.eql(u8, line, "ACK")) {
        if (std.mem.startsWith(u8, line, "NACK ")) {
            conn.setMessage(line["NACK ".len..]);
            return error.ArchiveRefused;
        }
        return error.ProtocolError;
    }
    switch (pkt_line.read(in) catch return error.ProtocolError) {
        .flush => {},
        else => return error.ProtocolError,
    }
    const buffer = try gpa.alloc(u8, pkt_line.max_line + 4);
    defer gpa.free(buffer);
    var demux: side_band.Demux = .init(in, buffer, options.progress);
    _ = demux.interface.streamRemaining(out) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.ReadFailed => {
            if (demux.err) |e| if (e == error.RemoteError) {
                conn.setMessage(demux.message());
                return error.ArchiveFailed;
            };
            return error.ProtocolError;
        },
    };
}

/// `upload-archive` served in this process, as the in-process connection
/// drives it.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    repo: *repo_mod.Repository,
    options: ServeOptions,

    pub fn advertise(_: *Server, _: *Io.Writer) ServeError!void {}

    pub fn serveRequest(s: *Server, in: *Io.Reader, out: *Io.Writer) ServeError!void {
        _ = try serve(s.gpa, s.io, s.repo, in, out, s.options);
    }
};

fn toldNothing(_: ServeError) bool {
    return false;
}
