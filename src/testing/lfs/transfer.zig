//! A `git-lfs-transfer` server, for the suite: relic's own
//! (`lfs.server.Transfer`), so the same stand-in ssh can run it for
//! git-lfs and for relic and what each asked be compared.
//!
//! It is started as `<helper> --root=<dir> --log=<dir> [--user=<name>]
//! [--no-version] [--lock-cursors=<a,b,...>] <path> <operation>`. The
//! repository is `<root>/<path>`, made bare when there is none; its objects
//! are kept in `<root>/lfs-objects`, a `lfs.server.Directory`, and its
//! locks where the server keeps them. Every connection is `--user`, and
//! takes locks at 2026-09-24T10:00:00Z. Batch answers name each object's
//! action with an `id`, a `token` and an `expires-in`, and `get-object`,
//! `put-object` and `verify-object` are refused unless both come back.
//!
//! What a client must be held to and no server does is the helper's own:
//! `--no-version` offers no `version=1`, which a client has to refuse, and
//! `--lock-cursors` answers each page of `list-lock` with the next of the
//! cursors given, `null` for none, whatever the locks are.
//!
//! Every request is written to a file in the `--log` directory on the way
//! out, one file per connection: the command, its arguments sorted, and its
//! lines sorted or the size of its data -- sorted because git-lfs writes
//! some of them from a map, in no order.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const relic = @import("relic");
const pkt_line = relic.transport.pkt_line;
const server = relic.lfs.server;
const Transfer = server.Transfer;

const locked_at_unix = 1790244000; // 2026-09-24T10:00:00Z

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const options = try Options.parse(gpa, args);
    const relative = std.mem.trim(u8, options.path, "/");
    var root = try Io.Dir.cwd().createDirPathOpen(io, options.root, .{});
    defer root.close(io);
    // A repository to keep the locks in, as a server's would be there.
    {
        var dir = try root.createDirPathOpen(io, relative, .{});
        defer dir.close(io);
        if (relic.repo.Repository.create(gpa, io, dir, .{ .default_branch = "main", .bare = true })) |made| {
            var repo = made;
            repo.deinit(io);
        } else |err| switch (err) {
            error.RepositoryExists => {},
            else => |e| return e,
        }
    }
    var objects = try root.createDirPathOpen(io, "lfs-objects", .{});
    defer objects.close(io);
    var directory: server.Directory = .{ .dir = objects };

    const in_buffer = try gpa.alloc(u8, pkt_line.max_line);
    var in = Io.File.stdin().readerStreaming(io, in_buffer);
    const out_buffer = try gpa.alloc(u8, pkt_line.max_line);
    var out = Io.File.stdout().writerStreaming(io, out_buffer);

    var log: std.ArrayList(u8) = .empty;
    defer if (options.log_dir) |dir| writeLog(io, dir, log.items);
    try log.print(gpa, "== {s} {s}\n", .{ options.path, options.operation });

    const root_path = try root.realPathFileAlloc(io, ".", gpa);
    const location = try std.Io.Dir.path.join(gpa, &.{ root_path, relative });
    var remote = try relic.transport.local.Remote.open(gpa, io, location, .{});
    defer remote.deinit(io);
    var who: Who = .{ .user = options.user };
    var session: Transfer.Session = .{
        .gpa = gpa,
        .io = io,
        .remote = &remote,
        .repository = relative,
        .operation = Transfer.Operation.named(options.operation) orelse return error.Usage,
        .options = .{
            .store = directory.store(),
            .caller = .{ .context = &who, .authorize = Who.authorize, .now = Who.now },
            .tokens = .{ .issue = issue, .check = check },
        },
        .in = &in.interface,
        .out = &out.interface,
    };
    if (options.offer_version) {
        try session.greet();
    } else {
        try pkt_line.write(&out.interface, "locking\n");
        try pkt_line.flush(&out.interface);
        try out.interface.flush();
    }
    var lock_page: usize = 0;
    while (true) {
        const req = (try session.next(gpa)) orelse return;
        try note(gpa, &log, req);
        if (options.lock_cursors) |script| if (std.mem.eql(u8, req.command, "list-lock")) {
            // The page's locks as the server lists them, its cursor the
            // script's.
            var cursors = std.mem.splitScalar(u8, script, ',');
            for (0..lock_page) |_| _ = cursors.next();
            lock_page += 1;
            const value = cursors.next() orelse {
                try session.status(400, &.{}, null);
                continue;
            };
            try scriptedPage(gpa, &session, req, value);
            continue;
        };
        if (!try session.answer(gpa, req)) return;
    }
}

/// The connection's user, allowed everything.
const Who = struct {
    user: []const u8,

    fn authorize(context: ?*anyopaque, _: []const u8, _: server.Access) Transfer.Verdict {
        const w: *Who = @ptrCast(@alignCast(context.?)); // safe: main hands its Who
        return .{ .allow = w.user };
    }

    fn now(_: ?*anyopaque) i64 {
        return locked_at_unix;
    }
};

/// `id` the oid's first eight digits, `token` `tok-` and the same.
fn issue(_: ?*anyopaque, arena: Allocator, oid: []const u8) Allocator.Error!Transfer.Token {
    const short = oid[0..@min(oid.len, 8)];
    return .{ .id = try arena.dupe(u8, short), .token = try arena.print("tok-{s}", .{short}), .expires_in = 3600 };
}

fn check(_: ?*anyopaque, oid: []const u8, id: ?[]const u8, token: ?[]const u8) bool {
    const short = oid[0..@min(oid.len, 8)];
    const i = id orelse return false;
    const t = token orelse return false;
    return std.mem.eql(u8, i, short) and std.mem.startsWith(u8, t, "tok-") and std.mem.eql(u8, t["tok-".len..], short);
}

/// A `list-lock` page whose cursor is the script's `value`: the server's
/// answer, its `next-cursor` replaced.
fn scriptedPage(gpa: Allocator, session: *Transfer.Session, req: Transfer.Request, value: []const u8) !void {
    var captured: Io.Writer.Allocating = .init(gpa);
    const real_out = session.out;
    session.out = &captured.writer;
    _ = try session.answer(gpa, req);
    session.out = real_out;
    // Read the answer back and write it again with the cursor in place.
    var reader: Io.Reader = .fixed(captured.written());
    var buffer: [pkt_line.max_line]u8 = undefined;
    var limited = reader.limited(.unlimited, &buffer);
    const r = &limited.interface;
    var args: std.ArrayList([]const u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var code: u16 = 200;
    var in_lines = false;
    while (true) {
        switch (try pkt_line.read(r)) {
            .flush => break,
            .delim => in_lines = true,
            .data => |unparsed| {
                const d = unparsed.readForParse();
                const text = try gpa.dupe(u8, std.mem.trimEnd(u8, d, "\n"));
                if (std.mem.startsWith(u8, text, "status ")) {
                    code = std.fmt.parseInt(u16, text["status ".len..], 10) catch 500;
                } else if (in_lines) {
                    try lines.append(gpa, text);
                } else if (!std.mem.startsWith(u8, text, "next-cursor=")) try args.append(gpa, text);
            },
            else => return error.UnexpectedPacket,
        }
    }
    if (!std.mem.eql(u8, value, "null")) try args.append(gpa, try gpa.print("next-cursor={s}", .{value}));
    try session.status(code, args.items, lines.items);
}

/// What the helper was started with: `--root=`, `--log=`, `--user=`,
/// `--lock-cursors=` and `--no-version`, then the repository's path and
/// the operation.
const Options = struct {
    root: []const u8 = ".",
    log_dir: ?[]const u8 = null,
    user: []const u8 = "ada",
    offer_version: bool = true,
    lock_cursors: ?[]const u8 = null,
    path: []const u8 = "",
    operation: []const u8 = "",

    fn parse(gpa: Allocator, args: []const []const u8) !Options {
        var options: Options = .{};
        var rest: std.ArrayList([]const u8) = .empty;
        for (args[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--root=")) {
                options.root = arg["--root=".len..];
            } else if (std.mem.startsWith(u8, arg, "--log=")) {
                options.log_dir = arg["--log=".len..];
            } else if (std.mem.startsWith(u8, arg, "--user=")) {
                options.user = arg["--user=".len..];
            } else if (std.mem.startsWith(u8, arg, "--lock-cursors=")) {
                options.lock_cursors = arg["--lock-cursors=".len..];
            } else if (std.mem.eql(u8, arg, "--no-version")) {
                options.offer_version = false;
            } else try rest.append(gpa, arg);
        }
        if (rest.items.len != 2) return error.Usage;
        options.path = rest.items[0];
        options.operation = rest.items[1];
        return options;
    }
};

fn note(gpa: Allocator, log: *std.ArrayList(u8), req: Transfer.Request) !void {
    // A lock's id is the server's own, a random one each run.
    if (std.mem.startsWith(u8, req.command, "unlock ")) {
        try log.appendSlice(gpa, "> unlock <id>\n");
    } else try log.print(gpa, "> {s}\n", .{req.command});
    const args = try gpa.dupe([]const u8, req.args);
    sortStrings(args);
    for (args) |a| try log.print(gpa, "  {s}\n", .{a});
    if (req.data) try log.print(gpa, "  -- {s} bytes\n", .{req.arg("size") orelse "?"});
    const lines = try gpa.dupe([]const u8, req.lines);
    sortStrings(lines);
    for (lines) |l| try log.print(gpa, "  -- {s}\n", .{l});
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
}

fn writeLog(io: Io, dir_path: []const u8, text: []const u8) void {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    var name_buf: [64]u8 = undefined;
    const name = std.mem.print(&name_buf, "{x}.log", .{&raw}) catch return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    // glint-ignore: Z026 -- a helper exits with its own status; a test that reads this log fails on its absence
    dir.writeFile(io, .{ .sub_path = name, .data = text }) catch {};
}
