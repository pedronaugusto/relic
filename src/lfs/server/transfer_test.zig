//! The pure-ssh transfer server against what the protocol answers: a whole
//! connection, and a cancel inside an object coming up.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("relic_core");
const repo_mod = core.repo;
const pkt_line = core.codec.pkt_line;
const server = @import("store.zig");
const transfer = @import("transfer.zig");
const serve = transfer.serve;
const Caller = transfer.Caller;
const Verdict = transfer.Verdict;
const testing_io = @import("../../testing/io.zig");

test "a connection is served whole: an object up, checked and down, a lock taken, listed and given back, as the protocol answers them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo.git");
    var repo_dir = try tmp.dir.openDir(io, "repo.git", .{});
    var made = try repo_mod.Repository.create(gpa, io, repo_dir, .{ .default_branch = "main", .bare = true });
    made.deinit(io);
    repo_dir.close(io);
    try tmp.dir.createDirPath(io, "objects");
    var objects = try tmp.dir.openDir(io, "objects", .{});
    defer objects.close(io);
    var directory: server.Directory = .{ .dir = objects };
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const content = "an object\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    var oid: [64]u8 = undefined;
    _ = std.mem.print(&oid, "{x}", .{&digest}) catch unreachable;

    // What a client asks, one request after another.
    var asked: Io.Writer.Allocating = .init(gpa);
    defer asked.deinit();
    const w = &asked.writer;
    try pkt_line.write(w, "version 1\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "batch\n");
    try pkt_line.delim(w);
    try pkt_line.print(w, "{s} {d}\n", .{ &oid, content.len });
    try pkt_line.flush(w);
    try pkt_line.print(w, "put-object {s}\n", .{&oid});
    try pkt_line.print(w, "size={d}\n", .{content.len});
    try pkt_line.delim(w);
    try pkt_line.write(w, content);
    try pkt_line.flush(w);
    try pkt_line.print(w, "verify-object {s}\n", .{&oid});
    try pkt_line.print(w, "size={d}\n", .{content.len});
    try pkt_line.flush(w);
    try pkt_line.print(w, "get-object {s}\n", .{&oid});
    try pkt_line.flush(w);
    try pkt_line.write(w, "lock\n");
    try pkt_line.write(w, "path=a.bin\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "lock\n");
    try pkt_line.write(w, "path=a.bin\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "list-lock\n");
    try pkt_line.flush(w);
    try pkt_line.write(w, "quit\n");
    try pkt_line.flush(w);

    const Who = struct {
        fn authorize(_: *Caller, _: []const u8, _: server.Access) Verdict {
            return .{ .allow = "ada" };
        }
        fn now(_: *Caller) i64 {
            return 1790244000;
        }
    };
    var caller: Caller = .{ .vtable = &.{ .authorize = Who.authorize, .now = Who.now } };
    var in: Io.Reader = .fixed(asked.written());
    var in_buffer: [pkt_line.max_line]u8 = undefined;
    var limited = in.limited(.unlimited, &in_buffer);
    var answered: Io.Writer.Allocating = .init(gpa);
    defer answered.deinit();
    try testing.expect(try serve(gpa, io, .{ .root = root, .path = "/repo.git", .operation = .upload, .in = &limited.interface, .out = &answered.writer }, .{
        .store = directory.store(),
        .caller = &caller,
    }));

    // Every answer, its status lines in order and what it carried.
    var out: Io.Reader = .fixed(answered.written());
    var out_buffer: [pkt_line.max_line]u8 = undefined;
    var out_limited = out.limited(.unlimited, &out_buffer);
    var said: std.ArrayList(u8) = .empty;
    defer said.deinit(gpa);
    while (true) {
        const packet = pkt_line.read(&out_limited.interface) catch break;
        switch (packet) {
            .data => |unparsed| {
                const d = unparsed.readForParse();
                try said.print(gpa, "{s}{s}", .{ d, if (d.len != 0 and d[d.len - 1] == '\n') "" else "\n" });
            },
            .delim => try said.appendSlice(gpa, "--\n"),
            .flush => try said.appendSlice(gpa, "==\n"),
            .response_end => break,
        }
    }
    const text = said.items;
    const expected_batch = try gpa.print("status 200\nhash-algo=sha256\n--\n{s} {d} upload\n==\n", .{ &oid, content.len });
    defer gpa.free(expected_batch);
    try testing.expect(std.mem.startsWith(u8, text, "version=1\nlocking\n==\nstatus 200\n==\n"));
    try testing.expect(std.mem.find(u8, text, expected_batch) != null);
    // The object went up, was found, and came down whole.
    try testing.expect(std.mem.find(u8, text, "status 200\nsize=10\n--\nan object\n==\n") != null);
    // A lock taken, refused twice, and listed as ours.
    try testing.expect(std.mem.find(u8, text, "status 201\n") != null);
    try testing.expect(std.mem.find(u8, text, "status 409\n") != null);
    try testing.expect(std.mem.find(u8, text, "path=a.bin\nlocked-at=2026-09-24T10:00:00Z\nownername=ada\n") != null);
    try testing.expect(std.mem.find(u8, text, " ours\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "status 200\n==\n"));
}

test "a cancel that stops a read of an object coming up is its reader's to say, not a protocol error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo.git");
    var repo_dir = try tmp.dir.openDir(io, "repo.git", .{});
    var made = try repo_mod.Repository.create(gpa, io, repo_dir, .{ .default_branch = "main", .bare = true });
    made.deinit(io);
    repo_dir.close(io);
    try tmp.dir.createDirPath(io, "objects");
    var objects = try tmp.dir.openDir(io, "objects", .{});
    defer objects.close(io);
    var directory: server.Directory = .{ .dir = objects };
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    // An object of several packets, so its data takes reads of its own.
    const content = try gpa.alloc(u8, 3 * pkt_line.max_data);
    defer gpa.free(content);
    @memset(content, 'o');
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    var oid: [64]u8 = undefined;
    _ = std.mem.print(&oid, "{x}", .{&digest}) catch unreachable;
    var asked: Io.Writer.Allocating = .init(gpa);
    defer asked.deinit();
    const w = &asked.writer;
    try pkt_line.write(w, "version 1\n");
    try pkt_line.flush(w);
    try pkt_line.print(w, "put-object {s}\n", .{&oid});
    try pkt_line.print(w, "size={d}\n", .{content.len});
    try pkt_line.delim(w);
    var rest: []const u8 = content;
    while (rest.len != 0) {
        const n = @min(rest.len, pkt_line.max_data);
        try pkt_line.write(w, rest[0..n]);
        rest = rest[n..];
    }
    try pkt_line.flush(w);
    try pkt_line.write(w, "quit\n");
    try pkt_line.flush(w);
    try tmp.dir.writeFile(io, .{ .sub_path = "asked", .data = asked.written() });

    const Up = struct {
        dir: Io.Dir,
        root: []const u8,
        store: server.Store,
        fn authorize(_: *Caller, _: []const u8, _: server.Access) Verdict {
            return .{ .allow = "ada" };
        }
        fn now(_: *Caller) i64 {
            return 1790244000;
        }
        // The caller owns the reader, and says why it failed.
        pub fn run(u: *const @This(), run_io: Io) !void {
            const file = try u.dir.openFile(run_io, "asked", .{});
            defer file.close(run_io);
            var in_buffer: [pkt_line.max_line]u8 = undefined;
            var in = file.readerStreaming(run_io, &in_buffer);
            var answered: Io.Writer.Allocating = .init(gpa);
            defer answered.deinit();
            var caller: Caller = .{ .vtable = &.{ .authorize = authorize, .now = now } };
            _ = serve(gpa, run_io, .{ .root = u.root, .path = "/repo.git", .operation = .upload, .in = &in.interface, .out = &answered.writer }, .{
                .store = u.store,
                .caller = &caller,
            }) catch |err| return if (err == error.ReadFailed) in.err.? else err;
        }
    };
    const up: Up = .{ .dir = tmp.dir, .root = root, .store = directory.store() };
    try testing_io.eachCallCanceled(gpa, io, &up, .file_read_streaming);
}
