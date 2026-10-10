//! Local three-object pack push, including receiver ref publication.
//! Fixture construction and teardown stay outside the measured operation.
const std = @import("std");
const Io = std.Io;
const api = @import("relic").api;
const scratchgit = @import("scratchgit.zig");
const benchmark = @import("shakedown").bench;
const shared = @import("shared.zig");

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
            var report = try c.remote.receivePush(c.gpa, c.io, .{ .from = c.from, .commands = &.{c.command}, .objects = c.entries }, .{
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

const WorkloadError = @typeInfo(@typeInfo(@TypeOf(Context.run)).@"fn".return_type.?).error_union.error_set;

pub fn run(init: std.process.Init, args: []const [:0]const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const run_options = try shared.options(init, args);
    if (!shared.wants(run_options.prefix, "local_push_three_objects")) return;
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
    const rows = [_]benchmark.Row(Context, WorkloadError){.{ .name = "local_push_three_objects", .unit = "push", .initial = 1, .run = Context.run }};
    try benchmark.run(WorkloadError, gpa, io, &output.interface, &context, &rows, .{ .commit = shared.commit }, run_options);
    try output.interface.flush();
    if (shared.selects(run_options.prefix, rows) and context.checksum == 0) return error.NoWork;
    const received = try remote.repo.refStore().readOid(gpa, io, "refs/heads/arrived");
    if (received == null or !received.?.eql(oid)) return error.WrongRef;
}
