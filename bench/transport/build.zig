const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    // ReleaseFast, always: a Debug build measures the safety checks.
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const relic = b.dependency("relic", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "relic_transport_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/relic_transport_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "relic", .module = relic.module("relic") }},
        }),
    });
    exe.root_module.addOptions("bench_options", options);
    b.installArtifact(exe);
}
