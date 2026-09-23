//! A long-running filter process, for the suite: the server side of git's
//! filter protocol, version 2, so the same program can be configured as
//! `filter.<driver>.process` for relic and for git and the two compared.
//!
//! Clean and smudge are both ROT13, which is its own inverse, so what goes
//! in comes back out and a blob is plainly not the file it came from. The
//! arguments change what it does:
//!
//! - `--delay`: every smudge that may be delayed is, and the files are
//!   handed over one per `list_available_blobs`, so a caller has to ask
//!   more than once.
//! - `--error=<path>`: answer `status=error` for that path.
//! - `--abort`: answer `status=abort` to every clean.
//! - `--garbage`: answer the first request with bytes that are not a
//!   pkt-line.
//! - `--no-smudge`: claim only the clean capability.
//! - `--log=<dir>`: write one file into the directory on the way out, named
//!   at random, holding a line per request, so a test can count how many
//!   processes ran and what each was asked.
//!
//! `zig build test` builds this and hands the test binary its path through
//! `build_options`.

const std = @import("std");
const Io = std.Io;
const pktline = @import("pktline.zig");

const Mode = struct {
    delay: bool = false,
    error_path: ?[]const u8 = null,
    abort: bool = false,
    garbage: bool = false,
    smudge: bool = true,
    log_dir: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    var mode: Mode = .{};
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--delay")) mode.delay = true;
        if (std.mem.eql(u8, arg, "--abort")) mode.abort = true;
        if (std.mem.eql(u8, arg, "--garbage")) mode.garbage = true;
        if (std.mem.eql(u8, arg, "--no-smudge")) mode.smudge = false;
        if (std.mem.startsWith(u8, arg, "--error=")) mode.error_path = arg["--error=".len..];
        if (std.mem.startsWith(u8, arg, "--log=")) mode.log_dir = arg["--log=".len..];
    }

    const in_buffer = try gpa.alloc(u8, pktline.max_line);
    var in = Io.File.stdin().readerStreaming(io, in_buffer);
    const out_buffer = try gpa.alloc(u8, pktline.max_line);
    var out = Io.File.stdout().writerStreaming(io, out_buffer);
    const r = &in.interface;
    const w = &out.interface;

    var log: std.ArrayList(u8) = .empty;
    defer if (mode.log_dir) |dir| writeLog(io, dir, log.items);

    // The welcome and the version, then the capabilities offered.
    try expectLine(r, "git-filter-client");
    try expectLine(r, "version=2");
    try expectEnd(r);
    try pktline.write(w, "git-filter-server\n");
    try pktline.write(w, "version=2\n");
    try pktline.flush(w);
    try w.flush();
    while (try readLine(r)) |_| {}
    try pktline.write(w, "capability=clean\n");
    if (mode.smudge) try pktline.write(w, "capability=smudge\n");
    if (mode.delay) try pktline.write(w, "capability=delay\n");
    try pktline.flush(w);
    try w.flush();

    var delayed: std.StringArrayHashMapUnmanaged([]u8) = .empty;
    var ready: std.ArrayList([]const u8) = .empty;
    var first = true;
    while (true) {
        var command: []const u8 = "";
        var path: []const u8 = "";
        var can_delay = false;
        var any = false;
        while (true) {
            const maybe = readLine(r) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            const text = maybe orelse break;
            any = true;
            if (std.mem.startsWith(u8, text, "command=")) command = try gpa.dupe(u8, text["command=".len..]);
            if (std.mem.startsWith(u8, text, "pathname=")) path = try gpa.dupe(u8, text["pathname=".len..]);
            if (std.mem.eql(u8, text, "can-delay=1")) can_delay = true;
        }
        if (!any) continue;
        try log.print(gpa, "{s} {s}{s}\n", .{ command, path, if (can_delay) " can-delay" else "" });

        if (std.mem.eql(u8, command, "list_available_blobs")) {
            // One at a time, so the caller asks again.
            if (ready.items.len == 0) {
                for (delayed.keys()) |key| try ready.append(gpa, key);
            }
            if (ready.pop()) |next| try pktline.print(w, "pathname={s}\n", .{next});
            try pktline.flush(w);
            try pktline.write(w, "status=success\n");
            try pktline.flush(w);
            try w.flush();
            continue;
        }

        var content: std.ArrayList(u8) = .empty;
        while (try readPacket(r)) |data| try content.appendSlice(gpa, data);

        if (mode.garbage and first) {
            try w.writeAll("this is not a packet");
            try w.flush();
            return;
        }
        first = false;
        if (mode.error_path) |bad| if (std.mem.eql(u8, bad, path)) {
            try status(w, "error");
            continue;
        };
        if (mode.abort and std.mem.eql(u8, command, "clean")) {
            try status(w, "abort");
            continue;
        }

        var result = content.items;
        if (std.mem.eql(u8, command, "smudge")) {
            if (delayed.fetchSwapRemove(path)) |kept| {
                result = kept.value;
            } else {
                rot13(result);
                if (mode.delay and can_delay) {
                    try delayed.put(gpa, path, result);
                    try status(w, "delayed");
                    continue;
                }
            }
        } else rot13(result);

        try pktline.write(w, "status=success\n");
        try pktline.flush(w);
        var rest = result;
        while (rest.len > 0) {
            const n = @min(rest.len, pktline.max_data);
            try pktline.write(w, rest[0..n]);
            rest = rest[n..];
        }
        try pktline.flush(w);
        // An empty list: the status before the content stands.
        try pktline.flush(w);
        try w.flush();
    }
}

fn status(w: *Io.Writer, value: []const u8) !void {
    try pktline.print(w, "status={s}\n", .{value});
    try pktline.flush(w);
    try w.flush();
}

fn rot13(bytes: []u8) void {
    for (bytes) |*c| {
        c.* = switch (c.*) {
            'a'...'m', 'A'...'M' => c.* + 13,
            'n'...'z', 'N'...'Z' => c.* - 13,
            else => c.*,
        };
    }
}

fn readPacket(r: *Io.Reader) !?[]const u8 {
    return switch (try pktline.read(r)) {
        .data => |data| if (data.len == 0) null else data,
        else => null,
    };
}

fn readLine(r: *Io.Reader) !?[]const u8 {
    const data = (try readPacket(r)) orelse return null;
    return std.mem.trimEnd(u8, data, "\n");
}

fn expectLine(r: *Io.Reader, want: []const u8) !void {
    const got = (try readLine(r)) orelse return error.UnexpectedFlush;
    if (!std.mem.eql(u8, got, want)) return error.UnexpectedLine;
}

fn expectEnd(r: *Io.Reader) !void {
    if (try readLine(r) != null) return error.ExpectedFlush;
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
