const std = @import("std");
pub fn build(b: *std.Build) void {
    const executable = b.addExecutable(.{ .name = "ci-bootstrap", .root_module = b.createModule(.{ .root_source_file = b.path("setup.zig"), .target = b.graph.host, .optimize = .safe }) });
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("setup", "Bootstrap the oldest Git container without package dependencies").dependOn(&run.step);
}
