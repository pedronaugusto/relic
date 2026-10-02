const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    // ReleaseFast, always: this is a benchmark and a Debug build measures
    // the safety checks rather than the package.
    _ = b.standardOptimizeOption(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const relic = b.dependency("relic", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "relic_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/relic_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "relic", .module = relic.module("relic") }},
        }),
    });
    exe.root_module.addOptions("bench_options", options);
    b.installArtifact(exe);
    const measurements = b.addTest(.{
        .name = "relic-regression-measurements",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../bench_regressions.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"benchmark:"},
    });
    measurements.root_module.addOptions("bench_options", options);
    if (relic.module("relic").import_table.get("conduit")) |conduit| measurements.root_module.addImport("conduit", conduit);
    b.installArtifact(measurements);
    const compile_measurements = b.step("regressions-build", "Compile regression measurements without running them");
    compile_measurements.dependOn(&measurements.step);
    const run_measurements = b.addRunArtifact(measurements);
    const regressions = b.step("regressions", "Run regression measurements on a quiet machine");
    regressions.dependOn(&run_measurements.step);
}
