//! git's `update-server-info` (`server-info.c`): the files a dumb HTTP
//! client reads to fetch without a git on the other side -- `info/refs`,
//! every ref with its peeled tag, and `objects/info/packs`, every pack of
//! the repository's own. `repack` writes them unless told not to, as
//! `receive-pack` does under `receive.updateServerInfo`.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");
const odb_mod = @import("../odb/odb.zig");
const repo_mod = @import("../repo/repo.zig");
const Repository = repo_mod.Repository;

/// Failures of `updateServerInfo`.
pub const Error = repo_mod.Error || Io.File.OpenError || Io.Dir.CreateDirPathError || Io.Dir.RenameError || Io.Dir.DeleteFileError || Io.Dir.ReadFileAllocError || Io.Writer.Error;

/// git's `update_server_info` without `--force`: `info/refs` and
/// `objects/info/packs` written again when what they would hold differs
/// from what they hold, through a temporary renamed into place, and
/// `info/rev-cache`, which older gits left, removed.
pub fn updateServerInfo(gpa: Allocator, io: Io, repo: *Repository) Self.Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const shared = repo.sharedPermissions();

    var refs: std.Io.Writer.Allocating = .init(arena);
    try infoRefs(gpa, io, repo, &refs.writer);
    try update(arena, io, repo.commonDirectory(), "info", "refs", refs.written(), shared);

    const db = repo.objectDatabase();
    var packs: std.Io.Writer.Allocating = .init(arena);
    try infoPacks(arena, io, db, &packs.writer);
    try update(arena, io, db.objectsDirectory(), "info", "packs", packs.written(), shared);

    repo.commonDirectory().deleteFile(io, "info/rev-cache") catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => |e| return e,
    };
}

/// `generate_info_refs`: every ref under `refs/` in name order, a symbolic
/// one by what it resolves to, as `<name>\t<ref>`, and below a tag what it
/// peels to as `<name>\t<ref>^{}` when that is there.
fn infoRefs(gpa: Allocator, io: Io, repo: *Repository, out: *Io.Writer) Self.Error!void {
    const store = repo.refStore();
    const db = repo.objectDatabase();
    var listed = try store.list(gpa, io, "refs/");
    defer listed.deinit();
    var hex: [hash.max_hex_len]u8 = undefined;
    for (listed.entries) |entry| {
        const oid = switch (entry.target) {
            .direct => |oid| oid,
            .symbolic => blk: {
                const resolved = (try store.resolve(gpa, io, entry.name)) orelse continue;
                defer gpa.free(resolved.name);
                break :blk resolved.oid;
            },
        };
        try out.print("{s}\t{s}\n", .{ oid.hex(&hex), entry.name });
        // git's `deref_tag`: down every tag to what is not one; a target
        // that is not there writes no line.
        var current = oid;
        var peeled = false;
        while (true) {
            const header = db.readHeader(io, current) catch |err| switch (err) {
                error.ObjectNotFound => break,
                else => |e| return e,
            };
            if (header.type != .tag) {
                if (peeled) try out.print("{s}\t{s}^{{}}\n", .{ current.hex(&hex), entry.name });
                break;
            }
            const found = try db.read(io, current);
            defer gpa.free(found.bytes);
            var tag = try object.Tag.parse(gpa, repo.objectFormat(), found.bytes);
            defer tag.deinit();
            current = tag.target;
            peeled = true;
        }
    }
}

/// `write_pack_info_file`: `P <pack>` for every pack of the database's own
/// directory, then an empty line. The packs the file already lists keep
/// their places when it lists only packs that are there, as git's
/// `init_pack_info` keeps them; the others follow.
fn infoPacks(arena: Allocator, io: Io, db: *odb_mod.Odb, out: *Io.Writer) Self.Error!void {
    const pack_dir = db.objectsDirectory().openDir(io, "pack", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.writeAll("\n"),
        else => |e| return e,
    };
    defer pack_dir.close(io);
    var present: std.ArrayList([]const u8) = .empty;
    var it = pack_dir.iterate();
    while (try it.next(io)) |entry| {
        // Every local pack, as `repo_for_each_pack` gives them, whatever it is
        // named: `maintenance`'s loose-objects task writes `loose-<name>`.
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const pack_name = try arena.print("{s}.pack", .{entry.name[0 .. entry.name.len - 4]});
        pack_dir.access(io, pack_name, .{}) catch continue;
        try present.append(arena, pack_name);
    }
    std.mem.sort([]const u8, present.items, {}, lessString);

    var ordered: std.ArrayList([]const u8) = .empty;
    const old: []const u8 = db.objectsDirectory().readFileAlloc(io, "info/packs", arena, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => "",
        else => |e| return e,
    };
    var lines = std.mem.splitScalar(u8, old, '\n');
    var stale = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "P ")) {
            const name = line[2..];
            for (present.items) |p| {
                if (std.mem.eql(u8, p, name)) break;
            } else {
                stale = true;
                break;
            }
            for (ordered.items) |o| {
                if (std.mem.eql(u8, o, name)) break;
            } else try ordered.append(arena, name);
        } else if (line[0] == 'D' or line[0] == 'T') {
            stale = true;
            break;
        }
    }
    if (stale) ordered.clearRetainingCapacity();
    for (present.items) |p| {
        for (ordered.items) |o| {
            if (std.mem.eql(u8, o, p)) break;
        } else try ordered.append(arena, p);
    }
    for (ordered.items) |name| try out.print("P {s}\n", .{name});
    try out.writeAll("\n");
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `update_info_file`: `<sub_dir>/<name>` in `dir` holds `bytes`, written
/// to a temporary beside it and renamed over it only when it held
/// something else.
fn update(arena: Allocator, io: Io, dir: Io.Dir, sub_dir: []const u8, name: []const u8, bytes: []const u8, shared: fs.Shared) Self.Error!void {
    var path_buf: [64]u8 = undefined;
    // unreachable: both names are this file's own, a few bytes each
    const path = std.mem.print(&path_buf, "{s}/{s}", .{ sub_dir, name }) catch unreachable;
    if (dir.readFileAlloc(io, path, arena, .limited(bytes.len + 1))) |old| {
        if (std.mem.eql(u8, old, bytes)) return;
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.StreamTooLong => {},
        else => |e| return e,
    }
    try dir.createDirPath(io, sub_dir);
    var temp_buf: [96]u8 = undefined;
    var prefix_buf: [64]u8 = undefined;
    // unreachable: as above
    const prefix = std.mem.print(&prefix_buf, "{s}/{s}_", .{ sub_dir, name }) catch unreachable;
    const temp = fs.tempName(io, &temp_buf, prefix);
    {
        const file = try dir.createFile(io, temp, .{ .exclusive = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        writer.interface.writeAll(bytes) catch |err| {
            // glint-ignore: Z026 -- the write's error is the one to report; a temporary left behind holds nothing anyone reads
            dir.deleteFile(io, temp) catch {};
            return err;
        };
        try writer.interface.flush();
    }
    fs.adjustShared(io, dir, temp, shared);
    fs.rename(io, dir, temp, path) catch |err| {
        // glint-ignore: Z026 -- the rename's error is the one to report; a temporary left behind holds nothing anyone reads
        dir.deleteFile(io, temp) catch {};
        return err;
    };
}
