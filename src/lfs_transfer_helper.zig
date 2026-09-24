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
const pktline = @import("pktline.zig");

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
    var root: []const u8 = ".";
    var log_dir: ?[]const u8 = null;
    var user: []const u8 = "ada";
    var offer_version = true;
    var rest: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--root=")) {
            root = arg["--root=".len..];
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            log_dir = arg["--log=".len..];
        } else if (std.mem.startsWith(u8, arg, "--user=")) {
            user = arg["--user=".len..];
        } else if (std.mem.eql(u8, arg, "--no-version")) {
            offer_version = false;
        } else try rest.append(gpa, arg);
    }
    if (rest.items.len != 2) return error.Usage;
    const operation = rest.items[1];
    const repo_path = try std.fs.path.join(gpa, &.{ root, std.mem.trimStart(u8, rest.items[0], "/") });
    var repo = try Io.Dir.cwd().createDirPathOpen(io, repo_path, .{});
    defer repo.close(io);

    const in_buffer = try gpa.alloc(u8, pktline.max_line);
    var in = Io.File.stdin().readerStreaming(io, in_buffer);
    const out_buffer = try gpa.alloc(u8, pktline.max_line);
    var out = Io.File.stdout().writerStreaming(io, out_buffer);
    const r = &in.interface;
    const w = &out.interface;

    var log: std.ArrayList(u8) = .empty;
    defer if (log_dir) |dir| writeLog(io, dir, log.items);
    try log.print(gpa, "== {s} {s}\n", .{ rest.items[0], operation });

    if (offer_version) try pktline.write(w, "version=1\n");
    try pktline.write(w, "locking\n");
    try pktline.flush(w);
    try w.flush();

    while (true) {
        const req = (try readRequest(gpa, r, operation)) orelse return;
        try note(gpa, &log, req);
        const cmd = req.command;
        if (std.mem.eql(u8, cmd, "version 1")) {
            try status(w, 200, &.{}, null);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            try status(w, 200, &.{}, null);
            return;
        } else if (std.mem.eql(u8, cmd, "batch")) {
            var lines: std.ArrayList([]const u8) = .empty;
            for (req.lines) |line| {
                var it = std.mem.splitScalar(u8, line, ' ');
                const oid = it.next() orelse continue;
                const size = it.next() orelse continue;
                const have = try hasObject(gpa, io, repo, oid);
                const action: []const u8 = if (std.mem.eql(u8, operation, "upload"))
                    (if (have) "noop" else "upload")
                else
                    (if (have) "download" else "noop");
                if (std.mem.eql(u8, action, "noop")) {
                    try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} noop", .{ oid, size }));
                } else {
                    try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} {s} id={s} token=tok-{s} expires-in=3600", .{ oid, size, action, oid[0..@min(oid.len, 8)], oid[0..@min(oid.len, 8)] }));
                }
            }
            try status(w, 200, &.{"hash-algo=sha256"}, lines.items);
        } else if (std.mem.startsWith(u8, cmd, "get-object ")) {
            const oid = cmd["get-object ".len..];
            if (!try authorised(req, oid)) {
                try status(w, 403, &.{}, &.{"missing id or token"});
                continue;
            }
            const bytes = readObject(gpa, io, repo, oid) orelse {
                try status(w, 404, &.{}, &.{"not found"});
                continue;
            };
            try pktline.write(w, "status 200\n");
            try pktline.print(w, "size={d}\n", .{bytes.len});
            try pktline.delim(w);
            var left = bytes;
            while (left.len != 0) {
                const n = @min(left.len, pktline.max_data);
                try pktline.write(w, left[0..n]);
                left = left[n..];
            }
            try pktline.flush(w);
            try w.flush();
        } else if (std.mem.startsWith(u8, cmd, "put-object ")) {
            const oid = cmd["put-object ".len..];
            if (!try authorised(req, oid)) {
                try status(w, 403, &.{}, &.{"missing id or token"});
                continue;
            }
            const bytes = req.body orelse "";
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            var hex: [64]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
            if (!std.mem.eql(u8, &hex, oid)) {
                try status(w, 400, &.{}, &.{"the data is not the object"});
                continue;
            }
            const path = try objectPath(gpa, oid);
            try repo.createDirPath(io, std.fs.path.dirname(path).?);
            try repo.writeFile(io, .{ .sub_path = path, .data = bytes });
            try status(w, 200, &.{}, null);
        } else if (std.mem.startsWith(u8, cmd, "verify-object ")) {
            const oid = cmd["verify-object ".len..];
            if (!try authorised(req, oid)) {
                try status(w, 403, &.{}, &.{"missing id or token"});
                continue;
            }
            if (try hasObject(gpa, io, repo, oid)) try status(w, 200, &.{}, null) else try status(w, 404, &.{}, &.{"not found"});
        } else if (std.mem.eql(u8, cmd, "lock")) {
            const path = argValue(req.args, "path") orelse {
                try status(w, 400, &.{}, &.{"no path"});
                continue;
            };
            var locks = try readLocks(gpa, io, repo);
            for (locks.items) |l| {
                if (std.mem.eql(u8, l.path, path)) {
                    try status(w, 409, try lockArgs(gpa, l), &.{"already locked"});
                    break;
                }
            } else {
                const l: Lock = .{ .id = try std.fmt.allocPrint(gpa, "{d}", .{nextId(locks.items)}), .path = path, .owner = user };
                try locks.append(gpa, l);
                try writeLocks(gpa, io, repo, locks.items);
                try status(w, 201, try lockArgs(gpa, l), null);
            }
        } else if (std.mem.eql(u8, cmd, "list-lock")) {
            const locks = try readLocks(gpa, io, repo);
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
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "owner {s} {s}", .{ l.id, if (std.mem.eql(u8, l.owner, user)) "ours" else "theirs" }));
            }
            var out_args: std.ArrayList([]const u8) = .empty;
            if (next) |n| try out_args.append(gpa, try std.fmt.allocPrint(gpa, "next-cursor={d}", .{n}));
            try status(w, 200, out_args.items, lines.items);
        } else if (std.mem.startsWith(u8, cmd, "unlock ")) {
            const id = cmd["unlock ".len..];
            var locks = try readLocks(gpa, io, repo);
            for (locks.items, 0..) |l, i| {
                if (!std.mem.eql(u8, l.id, id)) continue;
                const force = if (argValue(req.args, "force")) |f| std.mem.eql(u8, f, "true") else false;
                if (!std.mem.eql(u8, l.owner, user) and !force) {
                    try status(w, 403, &.{}, &.{"the lock is someone else's"});
                    break;
                }
                _ = locks.orderedRemove(i);
                try writeLocks(gpa, io, repo, locks.items);
                try status(w, 200, try lockArgs(gpa, l), null);
                break;
            } else try status(w, 404, &.{}, &.{"no such lock"});
        } else {
            try status(w, 400, &.{}, &.{"unknown command"});
        }
    }
}

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
    try pktline.print(w, "status {d}\n", .{code});
    for (args) |a| try pktline.print(w, "{s}\n", .{a});
    if (lines) |ls| {
        try pktline.delim(w);
        for (ls) |l| try pktline.print(w, "{s}\n", .{l});
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
    return std.fmt.allocPrint(gpa, "lfs/objects/{s}/{s}/{s}", .{ oid[0..2], oid[2..4], oid });
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
    dir.writeFile(io, .{ .sub_path = name, .data = text }) catch {};
}
