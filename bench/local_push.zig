//! Local three-object pack push, including receiver ref publication.
//! Fixture construction and teardown stay outside the measured operation.
const std = @import("std");
const Io = std.Io;
const api = @import("relic").api;
const scratchgit = @import("scratchgit.zig");
const benchmark = @import("shakedown").bench;

const Context = struct {
    gpa: std.mem.Allocator,
    io: Io,
    remote: *api.transport.local.Remote,
    from: *api.odb.Odb,
    entries: []const api.odb.PackEntry,
    command: api.transport.sendpack.Command,
    checksum: u64 = 0,

    fn run(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var report = try c.remote.receivePush(c.gpa, c.io, c.from, &.{c.command}, c.entries, .{
                .who = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 },
                .atomic = true,
            });
            defer report.deinit();
            if (report.refs.len != 1 or !report.refs[0].ok) return error.PushRefused;
            c.command.old = c.command.new;
            c.checksum +%= report.refs.len;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    scratchgit.environment = init.minimal.environ;
    var source = try scratchgit.Repo.init(gpa, io);
    defer source.deinit();
    try source.writeFile(io, "a", "push benchmark\n");
    try source.exec(io, &.{ "add", "a" });
    try source.exec(io, &.{ "commit", "-qm", "benchmark" });
    var from = try api.repo.Repository.open(gpa, io, source.dir, .{ .odb = .{ .probe_timestamp_resolution = false } });
    defer from.deinit(io);
    const oid = (try from.refStore().readOid(gpa, io, "refs/heads/main")).?;
    var objects = try from.objectDatabase().collectReachable(io, &.{oid}, .{});
    defer objects.deinit();
    if (objects.entries.len != 3) return error.WrongFixture;
    var target = try scratchgit.Repo.init(gpa, io);
    defer target.deinit();
    const path = try target.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var remote = try api.transport.local.Remote.open(gpa, io, path, .{});
    defer remote.deinit(io);
    var context: Context = .{ .gpa = gpa, .io = io, .remote = &remote, .from = from.objectDatabase(), .entries = objects.entries, .command = .{ .name = "refs/heads/arrived", .old = api.hash.Oid.zero(.sha1), .new = oid } };
    var out_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &out_buffer);
    const rows = [_]benchmark.Row(Context){.{ .name = "local_push_three_objects", .unit = "push", .initial = 1, .run = Context.run }};
    try benchmark.run(gpa, io, &output.interface, &context, &rows, .{ .commit = if (!smoke and args.len > 1) args[1] else "work-in-progress" }, .{ .smoke = smoke, .samples = 11, .minimum = .fromMilliseconds(5) });
    try output.interface.flush();
    if (context.checksum == 0) return error.NoWork;
    const received = try remote.repo.refStore().readOid(gpa, io, "refs/heads/arrived");
    if (received == null or !received.?.eql(oid)) return error.WrongRef;
}
