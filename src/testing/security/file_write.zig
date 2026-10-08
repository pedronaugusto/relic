//! File writes a stream chooses: fast-import's in-stream `feature
//! export-marks=` and `import-marks=`, which let whoever wrote the stream
//! write or read any path the importer can. The owner is `fastimport.zig`:
//! a stream names a marks file only when the caller says
//! `allow_unsafe_features`, as git's `--allow-unsafe-features` says, which
//! the remote helper's own import does as git's transport helper does.

const std = @import("std");
const Io = std.Io;

const fastimport = @import("../../fastimport.zig");
const repo_mod = @import("../../repo/repo.zig");
const object = @import("../../object/object.zig");
const testgit = @import("../git.zig");

const who: object.Signature = .{ .name = "F", .email = "f@example.com", .when_secs = 1, .offset_minutes = 0 };

fn import(gpa: std.mem.Allocator, io: Io, repo: *repo_mod.Repository, stream: []const u8, cwd: Io.Dir, unsafe: bool) !void {
    var in: Io.Reader = .fixed(stream);
    var report = try fastimport.import(gpa, io, repo, &in, .{ .who = who, .cwd = cwd, .allow_unsafe_features = unsafe });
    report.deinit();
}

test "CVE-2019-1348, t9300-fast-import 'R: export-marks feature forbidden by default' and 'R: import-marks features forbidden by default': a stream names no file unless the caller allows it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var elsewhere = std.testing.tmpDir(.{});
    defer elsewhere.cleanup();
    try elsewhere.dir.writeFile(io, .{ .sub_path = "secret", .data = ":1 0000000000000000000000000000000000000000\n" });

    const blob = "blob\nmark :1\ndata 4\nabc\n\n";
    for ([_][]const u8{
        "feature export-marks=written\n" ++ blob,
        "feature import-marks=secret\n" ++ blob,
        "feature import-marks-if-exists=secret\n" ++ blob,
    }) |stream| {
        try std.testing.expectError(error.UnsafeFeature, import(gpa, io, &repo, stream, elsewhere.dir, false));
    }
    try std.testing.expectError(error.FileNotFound, elsewhere.dir.access(io, "written", .{}));

    // The same stream, allowed: the marks are written where it says.
    try import(gpa, io, &repo, "feature export-marks=written\n" ++ blob, elsewhere.dir, true);
    try elsewhere.dir.access(io, "written", .{});
}
