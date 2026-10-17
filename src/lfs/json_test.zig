//! The LFS answers relic reads, held to what git-lfs's Go makes of them.
//!
//! `testing/lfs/go_json.tsv` holds 600 random answers, a hundred of each
//! kind (batch, lock, lock list, verify list, ssh authentication, custom
//! adapter), each with Go 1.27's reading of it into git-lfs 3.8.0's own types
//! (`tq.BatchResponse`, `locking.lockResponse`, `lockList`,
//! `lockVerifiableList`, `lfshttp.sshAuthResponse`,
//! `tq.customAdapterResponseMessage`), decoded as git-lfs decodes each (a
//! `json.Decoder` for an HTTP body, `json.Unmarshal` for a program's line),
//! and the checks relic makes on top: a nil object or action, which git-lfs
//! would dereference, an object name that is not a SHA-256, a lock with no
//! id, and an ssh answer's header that cannot be sent (an empty name, a line
//! break in a name or a value) are refused. A line is the kind, the input in hex, and the answer, or
//! `ERR`; strings in hex, times as Unix seconds, nanoseconds and offset, map
//! entries sorted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const lfsapi = @import("api.zig");
const transfer = @import("transfer.zig");
const locks = @import("locks.zig");
const custom = @import("custom.zig");
const time_text = @import("time_text.zig");

const corpus = @embedFile("../testing/lfs/go_json.tsv");

test "LFS answers are read as git-lfs's Go reads them" {
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next().?;
        const input_hex = fields.next().?;
        const want = fields.next().?;
        var state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer state.deinit();
        const a = state.allocator();
        const input = try a.alloc(u8, input_hex.len / 2);
        _ = try std.fmt.hexToBytes(input, input_hex);
        var out: Io.Writer.Allocating = .init(a);
        dump(a, &out.writer, kind, input) catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => return err,
            else => {
                out.clearRetainingCapacity();
                try out.writer.writeAll("ERR");
            },
        };
        testing.expectEqualStrings(want, out.written()) catch |err| {
            std.debug.print("{s} answer: {s}\n", .{ kind, input });
            return err;
        };
        cases += 1;
    }
    try testing.expectEqual(@as(usize, 600), cases);
}

fn dump(a: Allocator, w: *Io.Writer, kind: []const u8, input: []const u8) !void {
    if (std.mem.eql(u8, kind, "batch")) {
        const r = try transfer.parseBatch(a, input);
        try w.writeAll("B(");
        try hex(w, r.transfer);
        try w.writeByte(';');
        try hex(w, r.hash_algo);
        try w.writeByte(';');
        for (r.objects) |o| {
            try w.writeAll("T(");
            try hex(w, o.oid);
            try w.print(";{d};{};", .{ o.size, o.authenticated });
            try actions(a, w, o.actions);
            try w.writeByte(';');
            try actions(a, w, o._links);
            try w.writeByte(';');
            if (o.@"error") |e| try objectError(w, e.code, e.message) else try w.writeAll("nil");
            try w.writeAll("),");
        }
        return w.writeByte(')');
    }
    if (std.mem.eql(u8, kind, "lock")) {
        const r = try locks.parseLockAnswer(a, input);
        try w.writeAll("R(");
        if (r.lock) |l| try lock(w, l) else try w.writeAll("nil");
        try w.writeByte(';');
        try hex(w, r.message orelse "");
        return w.writeByte(')');
    }
    if (std.mem.eql(u8, kind, "list")) {
        const r = try locks.parseListPage(a, input);
        try w.writeAll("P(");
        for (r.locks) |l| {
            try lock(w, l);
            try w.writeByte(',');
        }
        try w.writeByte(';');
        try hex(w, r.next_cursor orelse "");
        try w.writeByte(';');
        try hex(w, r.message orelse "");
        return w.writeByte(')');
    }
    if (std.mem.eql(u8, kind, "verify")) {
        const r = try locks.parseVerifyPage(a, input);
        try w.writeAll("V(");
        for ([_][]const locks.Lock{ r.ours, r.theirs }) |set| {
            for (set) |l| {
                try lock(w, l);
                try w.writeByte(',');
            }
            try w.writeByte(';');
        }
        try hex(w, r.next_cursor orelse "");
        try w.writeByte(';');
        try hex(w, r.message orelse "");
        return w.writeByte(')');
    }
    if (std.mem.eql(u8, kind, "auth")) {
        const r = try lfsapi.parseAuthenticate(a, input);
        try w.writeAll("S(");
        try hex(w, r.href orelse "");
        try w.writeByte(';');
        const named = try a.alloc(Named, r.headers.len);
        for (r.headers, named) |h, *n| n.* = .{ .name = h.name, .value = h.value };
        try sorted(w, named);
        try w.writeByte(';');
        try time(w, r.expires_at);
        return w.print(";{d})", .{r.expires_in});
    }
    if (std.mem.eql(u8, kind, "adapter")) {
        const r = try custom.parseAnswer(a, input);
        try w.writeAll("C(");
        try hex(w, r.event);
        try w.writeByte(';');
        if (r.@"error") |e| try objectError(w, e.code, e.message) else try w.writeAll("nil");
        try w.writeByte(';');
        try hex(w, r.oid);
        try w.writeByte(';');
        try hex(w, r.path);
        return w.print(";{d};{d})", .{ r.bytesSoFar, r.bytesSinceLast });
    }
    unreachable;
}

const Named = struct { name: []const u8, value: []const u8 };

fn hex(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    for (bytes) |b| try w.print("{x:0>2}", .{b});
}

fn time(w: *Io.Writer, t: time_text.GoTime) Io.Writer.Error!void {
    try w.print("{d}.{d}{s}{d}", .{ t.unix, t.nanos, if (t.offset >= 0) "+" else "", t.offset });
}

fn objectError(w: *Io.Writer, code: i64, message: []const u8) Io.Writer.Error!void {
    try w.print("E({d};", .{code});
    try hex(w, message);
    try w.writeByte(')');
}

/// Entries by name, as Go's sorted keys.
fn sorted(w: *Io.Writer, entries: []Named) Io.Writer.Error!void {
    std.mem.sort(Named, entries, {}, struct {
        fn less(_: void, x: Named, y: Named) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    for (entries) |e| {
        try hex(w, e.name);
        try w.writeByte('=');
        try hex(w, e.value);
        try w.writeByte(',');
    }
}

fn actions(a: Allocator, w: *Io.Writer, set: transfer.ActionSet) !void {
    const named = try a.alloc(Named, set.items.len);
    for (set.items, named) |kv, *n| n.* = .{ .name = kv.key, .value = "" };
    std.mem.sort(Named, named, {}, struct {
        fn less(_: void, x: Named, y: Named) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    for (named) |n| {
        const act = for (set.items) |kv| {
            if (std.mem.eql(u8, kv.key, n.name)) break kv.value.?;
        } else unreachable;
        try hex(w, n.name);
        try w.writeAll("=A(");
        try hex(w, act.href);
        try w.writeByte(';');
        const headers = try a.alloc(Named, act.header.items.len);
        for (act.header.items, headers) |kv, *h| h.* = .{ .name = kv.key, .value = kv.value };
        try sorted(w, headers);
        try w.writeByte(';');
        try time(w, act.expires_at);
        try w.print(";{d}),", .{act.expires_in});
    }
}

fn lock(w: *Io.Writer, l: locks.Lock) Io.Writer.Error!void {
    try w.writeAll("L(");
    try hex(w, l.id);
    try w.writeByte(';');
    try hex(w, l.path);
    try w.writeByte(';');
    if (l.owner) |o| try hex(w, o) else try w.writeAll("nil");
    try w.writeByte(';');
    try time(w, l.locked_at);
    try w.writeByte(')');
}
