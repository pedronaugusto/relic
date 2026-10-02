const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    // ReleaseFast, always: a Debug build measures the safety checks.
    _ = b.standardOptimizeOption(.{});
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
    const inflate = b.addExecutable(.{
        .name = "inflate-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inflate_bench.zig"), .target = target, .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "inflate", .module = b.createModule(.{ .root_source_file = b.path("../../src/inflate.zig"), .target = target, .optimize = optimize }) }},
        }),
    });
    inflate.root_module.addOptions("bench_options", options);
    inflate.root_module.linkSystemLibrary("z", .{});
    b.installArtifact(inflate);
}
