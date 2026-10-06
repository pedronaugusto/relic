//! A `git-lfs-transfer` server, for the suite: the server side of
//! git-lfs's pure-ssh protocol, version 1, so the same stand-in ssh can run
//! it for git-lfs and for relic and what each asked be compared.
//!
//! It is started as `<helper> --root=<dir> --log=<dir> [--user=<name>]
//! [--no-version] <path> <operation>`. The repository is `<root>/<path>`;
//! objects are kept in its `lfs/objects`, as a server's store would keep
//! them, and locks in a file beside them. Batch answers name each object's
//! action with an `id`, a `token` and an `expires-in`, and `get-object`,
//! `put-object` and `verify-object` are refused unless both come back.
//! `--no-version` offers no `version=1`, which a client has to refuse.
//!
//! Every request is written to a file in the `--log` directory on the way
//! out, one file per connection: the command, its arguments sorted, and its
//! lines sorted or the size of its data — sorted because git-lfs writes
//! some of them from a map, in no order.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pktline = @import("relic").transport.pktline;

const locked_at = "2026-09-24T10:00:00Z";

const Request = struct {
    command: []const u8,
    args: []const []const u8,
    /// After a delimiter: text lines, or data.
    body: ?[]const u8 = null,
    lines: []const []const u8 = &.{},
};

const Lock = struct { id: []const u8, path: []const u8, owner: []const u8 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const options = try Options.parse(gpa, args);
    const repo_path = try std.fs.path.join(gpa, &.{ options.root, std.mem.trimStart(u8, options.path, "/") });
    var repo = try Io.Dir.cwd().createDirPathOpen(io, repo_path, .{});
    defer repo.close(io);

    const in_buffer = try gpa.alloc(u8, pktline.max_line);
    var in = Io.File.stdin().readerStreaming(io, in_buffer);
    const out_buffer = try gpa.alloc(u8, pktline.max_line);
    var out = Io.File.stdout().writerStreaming(io, out_buffer);
    const r = &in.interface;
    const w = &out.interface;

    var log: std.ArrayList(u8) = .empty;
    defer if (options.log_dir) |dir| writeLog(io, dir, log.items);
    try log.print(gpa, "== {s} {s}\n", .{ options.path, options.operation });

    if (options.offer_version) try pktline.write(w, "version=1\n");
    try pktline.write(w, "locking\n");
    try pktline.flush(w);
    try w.flush();

    const session: Session = .{ .gpa = gpa, .io = io, .repo = repo, .operation = options.operation, .user = options.user, .w = w };
    while (true) {
        const req = (try readRequest(gpa, r, options.operation)) orelse return;
        try note(gpa, &log, req);
        if (!try session.answer(req)) return;
    }
}

/// What the helper was started with: `--root=`, `--log=`, `--user=` and
/// `--no-version`, then the repository's path and the operation.
const Options = struct {
    root: []const u8 = ".",
    log_dir: ?[]const u8 = null,
    user: []const u8 = "ada",
    offer_version: bool = true,
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

/// One connection's server: the repository it keeps objects and locks in,
/// the operation and user it serves, and where its answers go.
const Session = struct {
    gpa: Allocator,
    io: Io,
    repo: Io.Dir,
    operation: []const u8,
    user: []const u8,
    w: *Io.Writer,

    /// Answer one request; false once the client has said `quit`.
    fn answer(s: *const Session, req: Request) !bool {
        const cmd = req.command;
        if (std.mem.eql(u8, cmd, "version 1")) {
            try status(s.w, 200, &.{}, null);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            try status(s.w, 200, &.{}, null);
            return false;
        } else if (std.mem.eql(u8, cmd, "batch")) {
            try s.batch(req);
        } else if (std.mem.startsWith(u8, cmd, "get-object ")) {
            try s.getObject(req, cmd["get-object ".len..]);
        } else if (std.mem.startsWith(u8, cmd, "put-object ")) {
            try s.putObject(req, cmd["put-object ".len..]);
        } else if (std.mem.startsWith(u8, cmd, "verify-object ")) {
            const oid = cmd["verify-object ".len..];
            if (!try authorised(req, oid)) {
                try status(s.w, 403, &.{}, &.{"missing id or token"});
            } else if (try hasObject(s.gpa, s.io, s.repo, oid)) try status(s.w, 200, &.{}, null) else try status(s.w, 404, &.{}, &.{"not found"});
        } else if (std.mem.eql(u8, cmd, "lock")) {
            try s.lock(req);
        } else if (std.mem.eql(u8, cmd, "list-lock")) {
            try s.listLocks(req);
        } else if (std.mem.startsWith(u8, cmd, "unlock ")) {
            try s.unlock(req, cmd["unlock ".len..]);
        } else {
            try status(s.w, 400, &.{}, &.{"unknown command"});
        }
        return true;
    }

    /// Each object's action for this operation: an upload of what the
    /// server lacks, a download of what it has, a noop otherwise.
    fn batch(s: *const Session, req: Request) !void {
        const gpa = s.gpa;
        var lines: std.ArrayList([]const u8) = .empty;
        for (req.lines) |line| {
            var it = std.mem.splitScalar(u8, line, ' ');
            const oid = it.next() orelse continue;
            const size = it.next() orelse continue;
            const have = try hasObject(gpa, s.io, s.repo, oid);
            const action: []const u8 = if (std.mem.eql(u8, s.operation, "upload"))
                (if (have) "noop" else "upload")
            else
                (if (have) "download" else "noop");
            if (std.mem.eql(u8, action, "noop")) {
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} noop", .{ oid, size }));
            } else {
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} {s} id={s} token=tok-{s} expires-in=3600", .{ oid, size, action, oid[0..@min(oid.len, 8)], oid[0..@min(oid.len, 8)] }));
            }
        }
        try status(s.w, 200, &.{"hash-algo=sha256"}, lines.items);
    }

    /// Send the object's size and bytes.
    fn getObject(s: *const Session, req: Request, oid: []const u8) !void {
        if (!try authorised(req, oid)) return status(s.w, 403, &.{}, &.{"missing id or token"});
        const bytes = readObject(s.gpa, s.io, s.repo, oid) orelse return status(s.w, 404, &.{}, &.{"not found"});
        try pktline.write(s.w, "status 200\n");
        try pktline.print("size={d}\n", .{bytes.len}, s.w);
        try pktline.delim(s.w);
        var left = bytes;
        while (left.len != 0) {
            const n = @min(left.len, pktline.max_data);
            try pktline.write(s.w, left[0..n]);
            left = left[n..];
        }
        try pktline.flush(s.w);
        try s.w.flush();
    }

    /// Keep the request's data as the object, when its digest is the name.
    fn putObject(s: *const Session, req: Request, oid: []const u8) !void {
        if (!try authorised(req, oid)) return status(s.w, 403, &.{}, &.{"missing id or token"});
        const bytes = req.body orelse "";
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
        comptime std.debug.assert(std.crypto.hash.sha2.Sha256.digest_length * 2 == 64);
        if (!std.mem.eql(u8, &hex, oid)) return status(s.w, 400, &.{}, &.{"the data is not the object"});
        const path = try objectPath(s.gpa, oid);
        try s.repo.createDirPath(s.io, std.fs.path.dirname(path).?);
        try s.repo.writeFile(s.io, .{ .sub_path = path, .data = bytes });
        try status(s.w, 200, &.{}, null);
    }

    /// Lock a path for this user, unless someone holds it already.
    fn lock(s: *const Session, req: Request) !void {
        const gpa = s.gpa;
        const path = argValue(req.args, "path") orelse return status(s.w, 400, &.{}, &.{"no path"});
        var locks = try readLocks(gpa, s.io, s.repo);
        for (locks.items) |l| {
            if (std.mem.eql(u8, l.path, path)) return status(s.w, 409, try lockArgs(gpa, l), &.{"already locked"});
        }
        const l: Lock = .{ .id = try std.fmt.allocPrint(gpa, "{d}", .{nextId(locks.items)}), .path = path, .owner = s.user };
        for (locks.items) |held| std.debug.assert(!std.mem.eql(u8, held.id, l.id));
        try locks.append(gpa, l);
        try writeLocks(gpa, s.io, s.repo, locks.items);
        try status(s.w, 201, try lockArgs(gpa, l), null);
    }

    /// The locks matching the path and id asked for, a page at a time from
    /// the cursor, with the next page's cursor when there is one.
    fn listLocks(s: *const Session, req: Request) !void {
        const gpa = s.gpa;
        const locks = try readLocks(gpa, s.io, s.repo);
        const want_path = argValue(req.args, "path");
        const want_id = argValue(req.args, "id");
        const limit = if (argValue(req.args, "limit")) |t| std.fmt.parseInt(usize, t, 10) catch 100 else 100;
        const start = if (argValue(req.args, "cursor")) |t| std.fmt.parseInt(usize, t, 10) catch 0 else 0;
        var lines: std.ArrayList([]const u8) = .empty;
        var shown: usize = 0;
        var next: ?usize = null;
        for (locks.items, 0..) |l, i| {
            if (i < start) continue;
            if (want_path) |p| if (!std.mem.eql(u8, p, l.path)) continue;
            if (want_id) |id| if (!std.mem.eql(u8, id, l.id)) continue;
            if (shown == limit) {
                next = i;
                break;
            }
            shown += 1;
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "lock {s}", .{l.id}));
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "path {s} {s}", .{ l.id, l.path }));
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "locked-at {s} {s}", .{ l.id, locked_at }));
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "ownername {s} {s}", .{ l.id, l.owner }));
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "owner {s} {s}", .{ l.id, if (std.mem.eql(u8, l.owner, s.user)) "ours" else "theirs" }));
        }
        var out_args: std.ArrayList([]const u8) = .empty;
        if (next) |n| try out_args.append(gpa, try std.fmt.allocPrint(gpa, "next-cursor={d}", .{n}));
        try status(s.w, 200, out_args.items, lines.items);
    }

    /// Release the lock `id`: this user's own, or anyone's with `force`.
    fn unlock(s: *const Session, req: Request, id: []const u8) !void {
        var locks = try readLocks(s.gpa, s.io, s.repo);
        for (locks.items, 0..) |l, i| {
            if (!std.mem.eql(u8, l.id, id)) continue;
            const force = if (argValue(req.args, "force")) |f| std.mem.eql(u8, f, "true") else false;
            if (!std.mem.eql(u8, l.owner, s.user) and !force) return status(s.w, 403, &.{}, &.{"the lock is someone else's"});
            _ = locks.orderedRemove(i);
            try writeLocks(s.gpa, s.io, s.repo, locks.items);
            return status(s.w, 200, try lockArgs(s.gpa, l), null);
        }
        try status(s.w, 404, &.{}, &.{"no such lock"});
    }
};

/// One request: its command line, arguments, and what follows a
/// delimiter; `null` at the end of the input.
fn readRequest(gpa: Allocator, r: *Io.Reader, operation: []const u8) !?Request {
    _ = operation;
    const first = pktline.read(r) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    const command = switch (first) {
        .data => |d| try gpa.dupe(u8, trimNewline(d)),
        else => return error.ExpectedCommand,
    };
    var args: std.ArrayList([]const u8) = .empty;
    while (true) {
        switch (try pktline.read(r)) {
            .flush => return .{ .command = command, .args = args.items },
            .delim => break,
            .data => |d| try args.append(gpa, try gpa.dupe(u8, trimNewline(d))),
            else => return error.UnexpectedPacket,
        }
    }
    var body: std.ArrayList(u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    const binary = std.mem.startsWith(u8, command, "put-object ");
    while (true) {
        switch (try pktline.read(r)) {
            .flush => break,
            .data => |d| if (binary) try body.appendSlice(gpa, d) else try lines.append(gpa, try gpa.dupe(u8, trimNewline(d))),
            else => return error.UnexpectedPacket,
        }
    }
    return .{ .command = command, .args = args.items, .body = if (binary) body.items else null, .lines = lines.items };
}

fn trimNewline(d: []const u8) []const u8 {
    return if (d.len != 0 and d[d.len - 1] == '\n') d[0 .. d.len - 1] else d;
}

fn note(gpa: Allocator, log: *std.ArrayList(u8), req: Request) !void {
    try log.print(gpa, "> {s}\n", .{req.command});
    const args = try gpa.dupe([]const u8, req.args);
    sortStrings(args);
    for (args) |a| try log.print(gpa, "  {s}\n", .{a});
    if (req.body) |b| try log.print(gpa, "  -- {d} bytes\n", .{b.len});
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

fn status(w: *Io.Writer, code: u16, args: []const []const u8, lines: ?[]const []const u8) !void {
    try pktline.print("status {d}\n", .{code}, w);
    for (args) |a| try pktline.print("{s}\n", .{a}, w);
    if (lines) |ls| {
        try pktline.delim(w);
        for (ls) |l| try pktline.print("{s}\n", .{l}, w);
    }
    try pktline.flush(w);
    try w.flush();
}

fn argValue(args: []const []const u8, key: []const u8) ?[]const u8 {
    for (args) |a| {
        if (a.len > key.len and std.mem.startsWith(u8, a, key) and a[key.len] == '=') return a[key.len + 1 ..];
    }
    return null;
}

fn authorised(req: Request, oid: []const u8) !bool {
    const short = oid[0..@min(oid.len, 8)];
    const id = argValue(req.args, "id") orelse return false;
    const token = argValue(req.args, "token") orelse return false;
    if (argValue(req.args, "size") == null) return false;
    return std.mem.eql(u8, id, short) and std.mem.startsWith(u8, token, "tok-") and std.mem.eql(u8, token["tok-".len..], short);
}

fn objectPath(gpa: Allocator, oid: []const u8) ![]const u8 {
    if (oid.len != 64) return error.BadOid;
    const path = try std.fmt.allocPrint(gpa, "lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], oid });
    std.debug.assert(path.len == "lfs/objects/".len + "xx/xx/".len + oid.len);
    return path;
}

fn hasObject(gpa: Allocator, io: Io, repo: Io.Dir, oid: []const u8) !bool {
    const path = objectPath(gpa, oid) catch return false;
    repo.access(io, path, .{}) catch return false;
    return true;
}

fn readObject(gpa: Allocator, io: Io, repo: Io.Dir, oid: []const u8) ?[]const u8 {
    const path = objectPath(gpa, oid) catch return null;
    return repo.readFileAlloc(io, path, gpa, .limited(1 << 30)) catch null;
}

fn readLocks(gpa: Allocator, io: Io, repo: Io.Dir) !std.ArrayList(Lock) {
    var out: std.ArrayList(Lock) = .empty;
    const text = repo.readFileAlloc(io, "transfer-locks", gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => |e| return e,
    };
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse continue;
        const path = fields.next() orelse continue;
        const owner = fields.next() orelse continue;
        try out.append(gpa, .{ .id = id, .path = path, .owner = owner });
    }
    return out;
}

fn writeLocks(gpa: Allocator, io: Io, repo: Io.Dir, locks: []const Lock) !void {
    var text: std.ArrayList(u8) = .empty;
    for (locks) |l| {
        // One line a lock, its fields split by tabs, as readLocks reads them.
        for ([_][]const u8{ l.id, l.path, l.owner }) |field| std.debug.assert(std.mem.findAny(u8, field, "\t\n") == null);
        std.debug.assert(l.id.len != 0);
    }
    for (locks) |l| try text.print(gpa, "{s}\t{s}\t{s}\n", .{ l.id, l.path, l.owner });
    try repo.writeFile(io, .{ .sub_path = "transfer-locks", .data = text.items });
}

fn nextId(locks: []const Lock) usize {
    var max: usize = 0;
    for (locks) |l| max = @max(max, std.fmt.parseInt(usize, l.id, 10) catch 0);
    return max + 1;
}

fn lockArgs(gpa: Allocator, l: Lock) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, 4);
    out[0] = try std.fmt.allocPrint(gpa, "id={s}", .{l.id});
    out[1] = try std.fmt.allocPrint(gpa, "path={s}", .{l.path});
    out[2] = "locked-at=" ++ locked_at;
    out[3] = try std.fmt.allocPrint(gpa, "ownername={s}", .{l.owner});
    return out;
}

fn writeLog(io: Io, dir_path: []const u8, text: []const u8) void {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{x}.log", .{&raw}) catch return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    // ziglint-ignore: Z026 a helper exits with its own status; a test that reads this log fails on its absence
    dir.writeFile(io, .{ .sub_path = name, .data = text }) catch {};
}
