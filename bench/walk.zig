//! The long loops that ask for cancellation once per step (design §11): the
//! revision walk by date and topologically, a merge base's paint, the object
//! walk, and a pack's delta search alone and on tasks. One history, written
//! through the object database outside the clock: two lines of 5,000
//! commits from one root, each commit changing one of `files` files a
//! little, so the blobs delta against each other.
const std = @import("std");
const Io = std.Io;
const api = @import("relic").api;
const scratchgit = @import("scratchgit.zig");
const benchmark = @import("shakedown").bench;
const shared = @import("shared.zig");

const Oid = api.hash.Oid;
const files = 20;

const Context = struct {
    gpa: std.mem.Allocator,
    io: Io,
    db: *api.odb.Odb,
    main: Oid,
    side: Oid,
    pack_dir: Io.Dir,
    pack_entries: []const api.odb.PackEntry,
    /// Each line's commits past the root.
    line_length: usize,
    checksum: u64 = 0,

    fn walk(c: *Context, units: u64, sort: api.rev_walk.Sort) !void {
        for (0..units) |_| {
            var w: api.rev_walk.Walk = .init(c.gpa, c.db);
            defer w.deinit();
            w.sort = sort;
            try w.push(c.main);
            var n: u64 = 0;
            while (try w.next(c.io)) |_| n += 1;
            if (n != c.line_length + 1) return error.WrongAnswer;
            c.checksum +%= n;
        }
    }
    fn walkDate(c: *Context, units: u64) !void {
        try c.walk(units, .date);
    }
    fn walkTopological(c: *Context, units: u64) !void {
        try c.walk(units, .topological);
    }
    fn mergeBase(c: *Context, units: u64) !void {
        for (0..units) |_| {
            const found = try api.rev_walk.mergeBasesMany(c.gpa, c.io, c.db, .{ .one = c.main, .others = &.{c.side} }, .{});
            defer c.gpa.free(found);
            if (found.len != 1) return error.WrongAnswer;
            c.checksum +%= found.len;
        }
    }
    fn objectWalk(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var collected = try api.rev_walk.object.walk.missing(c.gpa, c.io, c.db, &.{c.main}, .{ .use_bitmaps = false });
            defer collected.deinit();
            // Each commit, its tree and its blob, and the root's other files.
            if (collected.entries.len != 3 * (c.line_length + 1) + files - 1) return error.WrongAnswer;
            c.checksum +%= collected.entries.len;
        }
    }
    fn pack(c: *Context, units: u64, threads: u16) !void {
        for (0..units) |_| {
            const report = try c.db.writePack(c.io, c.pack_dir, c.pack_entries, .{ .threads = threads });
            if (report.deltas == 0) return error.WrongAnswer;
            c.checksum +%= report.deltas;
        }
    }
    fn packAlone(c: *Context, units: u64) !void {
        try c.pack(units, 1);
    }
    fn packOnTasks(c: *Context, units: u64) !void {
        try c.pack(units, 0);
    }
};

const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.walkDate)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Context.mergeBase)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Context.objectWalk)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Context.packAlone)).@"fn".return_type.?).error_union.error_set;

/// A blob of file `f` as commit `i` leaves it: forty lines, one of them
/// naming the commit.
fn blobText(buffer: *std.ArrayList(u8), gpa: std.mem.Allocator, f: usize, i: usize) !void {
    buffer.clearRetainingCapacity();
    for (0..40) |n| {
        if (n == i % 40) {
            try buffer.print(gpa, "file {d} line {d}, changed by commit {d}\n", .{ f, n, i });
        } else try buffer.print(gpa, "file {d} line {d} of a file that is long enough to delta well\n", .{ f, n });
    }
}

/// A tree of `files` entries `f00`… naming `blobs`.
fn treeOf(db: *api.odb.Odb, io: Io, buffer: *std.ArrayList(u8), gpa: std.mem.Allocator, blobs: []const Oid) !Oid {
    buffer.clearRetainingCapacity();
    for (blobs, 0..) |blob, f| {
        try buffer.print(gpa, "100644 f{d:0>2}\x00", .{f});
        try buffer.appendSlice(gpa, blob.raw());
    }
    return db.write(io, .tree, buffer.items);
}

fn commitOf(db: *api.odb.Odb, io: Io, buffer: *std.ArrayList(u8), gpa: std.mem.Allocator, tree: Oid, parent: ?Oid, when: usize) !Oid {
    buffer.clearRetainingCapacity();
    var hex: [api.hash.max_hex_len]u8 = undefined;
    try buffer.print(gpa, "tree {s}\n", .{tree.hex(&hex)});
    if (parent) |p| try buffer.print(gpa, "parent {s}\n", .{p.hex(&hex)});
    try buffer.print(gpa, "author A <a@example.com> {d} +0000\ncommitter C <c@example.com> {d} +0000\n\ncommit {d}\n", .{ 1_000_000 + when, 1_000_000 + when, when });
    return db.write(io, .commit, buffer.items);
}

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const run_options = try shared.options(init, args);
    const names = [_][]const u8{ "walk_date", "walk_topological", "merge_base", "object_walk", "pack_delta_alone", "pack_delta_tasks" };
    for (names) |name| {
        if (shared.wants(run_options.prefix, name)) break;
    } else return;
    scratchgit.environment = init.minimal.environ;
    var scratch = try scratchgit.Repo.init(gpa, io);
    defer scratch.deinit();
    var repo = try api.repo.Repository.open(gpa, io, scratch.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer repo.deinit(io);
    const db = repo.objectDatabase();
    // A smoke run, which only checks that each row works, writes a short
    // history.
    const line_length: usize = if (run_options.smoke) 50 else 5000;
    // The commits the pack rows write, newest first from the tip of `main`.
    const pack_commits: usize = if (run_options.smoke) 20 else 300;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var object_buffer: std.ArrayList(u8) = .empty;
    defer object_buffer.deinit(gpa);
    var blobs: [files]Oid = undefined;
    for (&blobs, 0..) |*blob, f| {
        try blobText(&text, gpa, f, 0);
        blob.* = try db.write(io, .blob, text.items);
    }
    const root = try commitOf(db, io, &object_buffer, gpa, try treeOf(db, io, &object_buffer, gpa, &blobs), null, 0);
    const root_blobs = blobs;
    var tips: [2]Oid = undefined;
    var pack_tail: Oid = root;
    for (&tips, 0..) |*tip, line| {
        blobs = root_blobs;
        var parent = root;
        for (1..line_length + 1) |i| {
            const when = line * line_length + i;
            const f = when % files;
            try blobText(&text, gpa, f, when);
            blobs[f] = try db.write(io, .blob, text.items);
            parent = try commitOf(db, io, &object_buffer, gpa, try treeOf(db, io, &object_buffer, gpa, &blobs), parent, when);
            if (line == 0 and i == line_length - pack_commits) pack_tail = parent;
        }
        tip.* = parent;
    }
    var collected = try api.rev_walk.object.walk.missing(gpa, io, db, &.{tips[0]}, .{ .exclude = &.{pack_tail}, .use_bitmaps = false });
    defer collected.deinit();
    const git_dir = try scratch.gitDir(io);
    defer git_dir.close(io);
    var pack_dir = try git_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);

    var context: Context = .{ .gpa = gpa, .io = io, .db = db, .main = tips[0], .side = tips[1], .pack_dir = pack_dir, .pack_entries = collected.entries, .line_length = line_length };
    var out_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &out_buffer);
    const rows = [_]benchmark.Row(Context, WorkloadError){
        .{ .name = names[0], .unit = "5001_commits", .initial = 1, .run = Context.walkDate },
        .{ .name = names[1], .unit = "5001_commits", .initial = 1, .run = Context.walkTopological },
        .{ .name = names[2], .unit = "two_5000_commit_lines", .initial = 1, .run = Context.mergeBase },
        .{ .name = names[3], .unit = "15020_objects", .initial = 1, .run = Context.objectWalk },
        .{ .name = names[4], .unit = "900_object_pack", .initial = 1, .run = Context.packAlone },
        .{ .name = names[5], .unit = "900_object_pack", .initial = 1, .run = Context.packOnTasks },
    };
    try benchmark.run(WorkloadError, gpa, io, &output.interface, &context, &rows, .{ .commit = shared.commit }, run_options);
    try output.interface.flush();
    if (shared.selects(run_options.prefix, rows) and context.checksum == 0) return error.NoWork;
}
