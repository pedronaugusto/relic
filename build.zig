const std = @import("std");
/// airlock's build, for its test seam and the aegis it is built on.
const airlock_build = @import("airlock");

/// What a project that depends on relic builds: the `relic` module, on aegis,
/// conduit, reactor, sweep, parallax, airlock, warp, xenoglyph and ladar;
/// `relic_lfs`, Git LFS, over strand; and `relic_net`, the network relic
/// reaches remotes over, over uplink and cloak. All three are always
/// there, and strand, uplink and cloak are lazy dependencies: what a
/// program reaches is chosen where it calls relic, never by a build option.
/// An operation that reaches a remote takes a `transport.Means`, whose
/// `network` is `&relic_net.network` or `null`; a program that never names
/// relic_net compiles neither uplink nor cloak. The tests, examples,
/// benchmarks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The modules. aegis owns its secrets; conduit runs programs and carries
    // its platform linkage; command preparation and the permission to run
    // remain here. sweep matches git's globs, parallax diffs and merges
    // lines, warp compresses, airlock makes writes durable and xenoglyph
    // composes the names macOS hands back decomposed.
    //
    // HTTP and HTTPS, and a git daemon over TCP, take two more: uplink
    // speaks HTTP and dials, and cloak holds the certificates, keys and
    // trust TLS uses. Their engines are relic_net's `network`, the one name
    // that reaches them: relic's core calls the network only through the
    // `Means` an operation is given. Git LFS takes strand, which reads the
    // JSON its servers and custom transfer agents send, within limits.
    //=====================================================================

    // One core under all three: what `relic_lfs` and `relic_net` hand out
    // is `relic`'s own type.
    const core = coreModule(b, target, optimize, .{});
    // Each module said in the literal form, its root a path, so what the
    // package exports is read from this text (preflight's changelog check).
    _ = b.addModule("relic", .{
        .root_source_file = b.path("src/relic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = rootImports(b, target, optimize, core, &.{}),
    });
    const lfs = b.addModule("relic_lfs", .{
        .root_source_file = b.path("src/lfs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = rootImports(b, target, optimize, core, &lfs_packages),
    });
    const net = b.addModule("relic_net", .{
        .root_source_file = b.path("src/net.zig"),
        .target = target,
        .optimize = optimize,
        .imports = rootImports(b, target, optimize, core, &.{}),
    });
    net.addImport("relic_lfs", lfs);
}

/// relic's core, from `p`, relic's own build, for `target` and `optimize`:
/// every file but the public roots and LFS's, rooted at `src/core.zig`,
/// made with `createModule` so that no consumer can name it. It imports
/// aegis, conduit, reactor, sweep, parallax, airlock, warp, xenoglyph and
/// ladar, and uplink and cloak once the build has fetched them, or what
/// `poison` puts in their place (`dev`'s proof that only relic_net reaches
/// them).
fn coreModule(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, poison: Poison) Core {
    return .{
        .module = p.createModule(.{
            .root_source_file = p.path("src/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = moduleImports(p, target, optimize, poison, &.{}),
        }),
        .poison = poison,
        .readme = p.createModule(.{ .root_source_file = p.path("README.md") }),
    };
}

/// The core, and the modules the roots over it share with it: a file
/// belongs to one module in a compilation.
const Core = struct {
    module: *std.Build.Module,
    /// What stands for uplink and cloak, where `dev` proves nothing
    /// reaches them.
    poison: Poison,
    /// `README.md`, whose module tables the public roots check.
    readme: *std.Build.Module,
};

/// The `relic` module over `core`, as `build` adds it, for the benchmarks
/// and the network proof: `src/relic.zig`, which reaches every namespace
/// through the core and checks the README's module table against the API
/// as it compiles.
fn relicModule(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, core: Core) std.Build.Module.CreateOptions {
    return .{
        .root_source_file = p.path("src/relic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = rootImports(p, target, optimize, core, &.{}),
    };
}

/// The `relic_lfs` module over `core` and strand, as `build` adds it, for
/// the benchmarks and the network proof: rooted at `src/lfs.zig`.
fn lfsModule(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, core: Core) std.Build.Module.CreateOptions {
    return .{
        .root_source_file = p.path("src/lfs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = rootImports(p, target, optimize, core, &lfs_packages),
    };
}

/// What a public root imports: the core's own imports and `extra`, the core
/// itself as `relic_core`, and `README.md`, whose module table it checks
/// against its API as it compiles.
fn rootImports(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, core: Core, extra: []const []const u8) []const std.Build.Module.Import {
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.appendSlice(p.allocator, moduleImports(p, target, optimize, core.poison, extra)) catch @panic("out of memory");
    imports.append(p.allocator, .{ .name = "relic_core", .module = core.module }) catch @panic("out of memory");
    imports.append(p.allocator, .{ .name = "README.md", .module = core.readme }) catch @panic("out of memory");
    return imports.items;
}

/// What the core imports, from `p`, relic's own build, for `target`
/// and `optimize`: aegis, conduit, reactor, sweep, parallax, airlock, warp,
/// xenoglyph and ladar; uplink and cloak, or `poison`'s in their place; and
/// `extra`, each lazy package once the build has fetched it. A public root
/// takes the same.
fn moduleImports(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, poison: Poison, extra: []const []const u8) []const std.Build.Module.Import {
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    for ([_][]const u8{ "aegis", "conduit", "reactor", "sweep", "parallax", "airlock", "warp", "xenoglyph", "ladar" }) |name| {
        imports.append(p.allocator, .{ .name = name, .module = p.dependency(name, .{ .target = target, .optimize = optimize }).module(name) }) catch @panic("out of memory");
    }
    for ([_]struct { []const u8, ?*std.Build.Module }{ .{ "uplink", poison.uplink }, .{ "cloak", poison.cloak } }) |net| {
        if (net[1] orelse lazyModule(p, net[0], target, optimize)) |m| imports.append(p.allocator, .{ .name = net[0], .module = m }) catch @panic("out of memory");
    }
    for (extra) |name| if (lazyModule(p, name, target, optimize)) |m| {
        imports.append(p.allocator, .{ .name = name, .module = m }) catch @panic("out of memory");
    };
    return imports.items;
}

/// relic's development: its tests, helpers, examples and benchmarks, under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const preflight = tools.preflight;
    const package = relicPackage(b, target, optimize);
    const p = package.builder;
    const module = package.module("relic");
    const airlock_dependency = p.dependency("airlock", .{ .target = target, .optimize = optimize });
    const conduit = p.dependency("conduit", .{ .target = target, .optimize = optimize }).module("conduit");

    //=====================================================================
    // Tests. The suite lives beside the code it tests, so the root module's
    // imports are what pull every file in. Fixtures are generated by the
    // `git` on the machine at test time, into a temporary directory; a
    // machine with no `git` skips those tests rather than failing them.
    //=====================================================================

    // A second process is the only honest way to prove that a lock a
    // running git holds is refused rather than broken, so the suite spawns
    // one. Its path is compiled into the test binary rather than passed in
    // the environment, because nothing in this package reads one.
    const lock_helper = b.addExecutable(.{
        .name = "relic-lock-helper",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/lock.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // A long-running filter process has to be a program for the same
    // reason: relic and git are each handed it as `filter.<driver>.process`
    // and what they store is compared.
    const filter_helper = b.addExecutable(.{
        .name = "relic-filter-helper",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/filter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // git-lfs does not ship a `git-lfs-transfer` server, so the suite
    // brings one: relic and git-lfs are each pointed at it over the same
    // stand-in ssh and what it was asked is compared: relic_lfs's server.
    const lfs_transfer_helper = b.addExecutable(.{
        .name = "relic-lfs-transfer-helper",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/lfs/transfer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // relic's own upload-pack, as a program real git can be pointed at with
    // `--upload-pack`, so what git makes of relic's server is compared with
    // what it makes of its own.
    const upload_pack_helper = b.addExecutable(.{
        .name = "relic-upload-pack",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/upload_pack.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // relic's own upload-archive, as a program real git can be pointed at
    // with `git archive --exec`, so the archive git receives from relic's
    // server is compared with the one it receives from its own.
    const upload_archive_helper = b.addExecutable(.{
        .name = "relic-upload-archive",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/upload_archive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // relic's own receive-pack, as a program real git can be pointed at
    // with `--receive-pack`, so what a push git makes to relic's server
    // does is compared with what it does to git's own.
    const receive_pack_helper = b.addExecutable(.{
        .name = "relic-receive-pack",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/receive_pack.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Hook fixtures use a native program on every target. Each copy reads
    // its own sidecar description, so git and relic run the same behaviour.
    const hook_fixture = b.addExecutable(.{
        .name = "relic-hook-fixture",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const fake_ssh = b.addExecutable(.{
        .name = "relic-fake-ssh",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/fake_ssh.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const lfs_tool = b.addExecutable(.{
        .name = "relic-lfs-test-tool",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/lfs/tool.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // A remote helper, for git and relic to be pointed at alike: git's
    // own `git-remote-testgit`, and one with `fetch` and `push`.
    const remote_helper = b.addExecutable(.{
        .name = "relic-remote-helper",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/remote_helper.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // A custom LFS transfer agent, handed to git-lfs and to relic alike.
    const lfs_agent = b.addExecutable(.{
        .name = "relic-lfs-agent",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/lfs/agent.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const process_fixture = b.addExecutable(.{
        .name = "relic-process-fixture",
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/process.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const build_options = b.addOptions();
    // gpg-agent makes its sockets in its home, and a socket path holds at
    // most 104 bytes on macOS and 108 on Linux: under a checkout's own
    // `.zig-cache` a home is past that from a deep enough checkout. `/tmp`
    // keeps it short from any checkout. Windows' GnuPG has no such socket.
    const gnupg_fixture_root = b.option(
        []const u8,
        "gnupg-fixture-root",
        "A short directory for private GnuPG test homes (defaults to /tmp, .zig-cache/gpg on Windows)",
    ) orelse if (target.result.os.tag == .windows) ".zig-cache/gpg" else "/tmp";
    build_options.addOptionPathUntracked("gnupg_fixture_root", if (std.Io.Dir.path.isAbsolute(gnupg_fixture_root))
        b.graph.cwdRelativePath(gnupg_fixture_root)
    else
        p.path(gnupg_fixture_root));
    build_options.addOptionPath("lock_helper_path", lock_helper.getEmittedBin());
    build_options.addOptionPath("filter_helper_path", filter_helper.getEmittedBin());
    build_options.addOptionPath("lfs_transfer_helper_path", lfs_transfer_helper.getEmittedBin());
    // A real `git-lfs-transfer` server — Scutiger's is the one git-lfs's
    // own suite uses — for the tests that prove relic's client against one
    // rather than against the suite's own; they skip without it.
    build_options.addOption([]const u8, "lfs_transfer_server", b.option(
        []const u8,
        "lfs-transfer-server",
        "A git-lfs-transfer server program to prove the pure-ssh client against",
    ) orelse "");
    // The test of a blob past 4 GiB (designs/relic.md §10) takes minutes
    // and gigabytes of disk: the nightly's own job runs it, nothing else.
    const large_objects = b.option(
        bool,
        "large-objects",
        "Run the test of a blob past 4 GiB, which takes minutes and gigabytes of disk",
    ) orelse false;
    build_options.addOption(bool, "large_objects", large_objects);
    // Where a test leaves what a hosted job uploads with preflight's
    // timings (.zig-cache/preflight-timings, the job's artifact).
    build_options.addOptionPathUntracked("repo_root", p.path("."));
    build_options.addOptionPath("upload_pack_helper_path", upload_pack_helper.getEmittedBin());
    build_options.addOptionPath("receive_pack_helper_path", receive_pack_helper.getEmittedBin());
    build_options.addOptionPath("upload_archive_helper_path", upload_archive_helper.getEmittedBin());
    build_options.addOptionPath("hook_fixture_path", hook_fixture.getEmittedBin());
    build_options.addOptionPath("fake_ssh_helper_path", fake_ssh.getEmittedBin());
    build_options.addOptionPath("lfs_test_tool_path", lfs_tool.getEmittedBin());
    build_options.addOptionPath("process_fixture_path", process_fixture.getEmittedBin());
    build_options.addOptionPath("remote_helper_path", remote_helper.getEmittedBin());
    build_options.addOptionPath("lfs_agent_path", lfs_agent.getEmittedBin());
    // The tests: `src/tests.zig`, which holds the core's files and names
    // their tests, with relic's public root compiled among them, and
    // relic_lfs's root, files and tests (`src/lfs_tests.zig`). It has
    // every name of `src/core.zig` and is its own `relic_core`, so the
    // files that reach the core through it reach these; its comptime check
    // holds its list to the core's. One module on purpose, where a
    // consumer's build is three: Zig tracks a file's `@import`s of files
    // eagerly, test blocks' included, and a file belongs to one module; the
    // core's production files import test helpers by path for their in-file
    // tests, and LFS's tests share those helpers, so a separate LFS test
    // module over the core module holds them twice and does not compile.
    const test_module = p.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        // The imports of the modules a consumer gets.
        .imports = moduleImports(p, target, optimize, .{}, &lfs_packages),
    });
    test_module.addImport("relic_core", test_module);
    test_module.addImport("README.md", p.createModule(.{ .root_source_file = p.path("README.md") }));
    // shakedown, and airlock's seam built on it.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    test_module.addImport("airlock.testing", airlock_build.testing(airlock_dependency, shakedown.module("shakedown")));
    test_module.addImport("shakedown", shakedown.module("shakedown"));
    // The fixtures the tests read, outside src/ and the paths a project fetches.
    test_module.addImport("testdata", p.createModule(.{ .root_source_file = p.path("testdata/root.zig") }));
    // Git for Windows' iconv as recorded, which the tables were written
    // from, and the record a Windows run holds that DLL to it with
    // (designs/relic.md §14).
    test_module.addImport("git-for-windows-iconv.txt", p.createModule(.{ .root_source_file = p.path("tools/git-for-windows-iconv.txt") }));
    test_module.addImport("iconv_record", p.createModule(.{ .root_source_file = p.path("tools/iconv_record.zig"), .target = target, .optimize = optimize }));
    filter_helper.root_module.addImport("relic", module);
    lfs_transfer_helper.root_module.addImport("relic", module);
    lfs_transfer_helper.root_module.addImport("relic_lfs", package.module("relic_lfs"));
    hook_fixture.root_module.addImport("relic", module);
    upload_pack_helper.root_module.addImport("relic", module);
    receive_pack_helper.root_module.addImport("relic", module);
    upload_archive_helper.root_module.addImport("relic", module);
    upload_pack_helper.root_module.addImport("conduit", conduit);
    hook_fixture.root_module.addImport("conduit", conduit);
    test_module.addOptions("build_options", build_options);

    const tests = b.addTest(.{
        .name = "relic-tests",
        .root_module = test_module,
        .filters = b.option([]const []const u8, "test-filter", "Select tests by name; repeat for multiple families") orelse &.{},
    });

    const run_tests = b.addRunArtifact(tests);
    // The git the comparisons are held to, asked once before the tests run,
    // where they run.
    const held_git = b.addExecutable(.{ .name = "relic-held-git", .root_module = b.createModule(.{
        .root_source_file = p.path("src/testing/held_git.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const ask_git = b.addRunArtifact(held_git);
    ask_git.has_side_effects = true;
    run_tests.step.dependOn(&ask_git.step);

    const test_step = b.step("test", "Run the relic tests");
    test_step.dependOn(&run_tests.step);

    // Compiling without running: the step a cross-compilation check uses,
    // and the one an editor can keep warm. It covers the tests too, which
    // the default install step does not.
    const check_step = b.step("check", "Compile everything without running it");
    check_step.dependOn(&tests.step);
    check_step.dependOn(&held_git.step);
    check_step.dependOn(&lock_helper.step);
    check_step.dependOn(&filter_helper.step);
    check_step.dependOn(&lfs_transfer_helper.step);
    check_step.dependOn(&upload_pack_helper.step);
    check_step.dependOn(&receive_pack_helper.step);
    check_step.dependOn(&upload_archive_helper.step);
    check_step.dependOn(&hook_fixture.step);
    check_step.dependOn(&fake_ssh.step);
    check_step.dependOn(&lfs_tool.step);
    check_step.dependOn(&process_fixture.step);
    check_step.dependOn(&remote_helper.step);
    check_step.dependOn(&lfs_agent.step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the bytes are still the bytes. examples/usage.zig is also where
    // README.md's Usage block comes from -- see bay docs -- usage -- so the
    // snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = p.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "relic", .module = module }},
            }),
        });
        b.installArtifact(example);
        check_step.dependOn(&example.step);
        const run = b.addRunArtifact(example);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(p.path("zig-out"));
        examples_step.dependOn(&run.step);

        // The examples' own tests take shakedown, as the suite's do; the
        // examples themselves use relic alone.
        example.root_module.addImport("shakedown", shakedown.module("shakedown"));
        const example_tests = b.addTest(.{ .root_module = example.root_module });
        const run_example_tests = b.addRunArtifact(example_tests);
        if (target.result.os.tag == .windows) {
            // Zig inherits all inheritable Windows pipe handles at
            // spawn. Concurrent runners can keep each other's pipes open.
            run_example_tests.step.dependOn(&run_tests.step);
            run.step.dependOn(&run_example_tests.step);
        }
        examples_step.dependOn(&run_example_tests.step);
        check_step.dependOn(&example_tests.step);
    }
    test_step.dependOn(examples_step);

    const setup = b.addExecutable(.{ .name = "ci-setup", .root_module = b.createModule(.{ .root_source_file = p.path("ci/setup.zig"), .target = b.graph.host, .optimize = .safe }) });
    // The release the comparisons are held to, which setup installs.
    setup.root_module.addImport("git_release", b.createModule(.{ .root_source_file = p.path("src/testing/git_release.zig"), .target = b.graph.host, .optimize = .safe }));
    const prepare = b.addRunArtifact(setup);
    prepare.addPassthruArgs();
    b.step("ci-setup", "Install cached Git and LFS tools").dependOn(&prepare.step);
    // The installer runs only on a hosted runner; its version reading and
    // its path file are proved everywhere, and with the tests, so on each
    // host's own file system: the source checks job, which runs
    // check-ci-setup, is Linux's alone, and Windows refused a path file
    // opened only to write (push run 44588375043). A test joins the tests
    // before addCi reads them below, so ci runs it under preflight's runner
    // (push run 44616529348 refused it, joined after: TestOutsideRunner).
    const setup_tests = b.addRunArtifact(b.addTest(.{ .root_module = setup.root_module }));
    b.step("check-ci-setup", "Test the hosted tool installer").dependOn(&setup_tests.step);
    test_step.dependOn(&setup_tests.step);
    // The record of an iconv the encodings' generator cannot run where it
    // writes the tables (Git for Windows', tools/iconv_record.zig): written
    // and read back on every host, with the tests for the same reason.
    const iconv_record_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = p.path("tools/iconv_record.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    test_step.dependOn(&iconv_record_tests.step);

    //=====================================================================
    // Benchmarks
    //
    // relic's own measurements of its own work, in bench/: `bay bench
    // -Doptimize=ReleaseFast` installs them under zig-out/bench, and `bay
    // bench` compiles them, so they keep up with the API. They run on a
    // quiet machine, never in CI; bench/README.md says how.
    //=====================================================================

    preflight.addCi(b, p, .{
        .tests = test_step,
        // The delta search runs its candidates on the caller's executor when
        // `PackOptions.threads` asks for more than one, and the suite writes
        // the same repository from two processes and two tasks at once.
        // Whether that is free of races is a claim a race detector can check
        // and a reader cannot: preflight's ThreadSanitizer build of the
        // tests, `bay test -Dci-tsan=true`, each test's bound scaled for it.
        .hardened = .{},
        // The comparisons with git run on the riscv64 machine too, with
        // preflight's held git (ci/workflow.json `git`), already on the
        // machine; Alpine's git-lfs is the LFS comparisons' (the git it
        // pulls in stays behind the held one on the path).
        .vm_packages = &.{"git-lfs"},
        .test_timeout = if (large_objects) .{ .bound = .{
            .limit = .fromSeconds(40 * 60),
            .reason = "the blob past 4 GiB goes through relic and git several times over: tens of minutes, within the nightly job's 45",
        } } else .default,
        .bench = .{
            .programs = &.{ .{ .name = "relic-regressions", .source = "bench/regressions.zig" }, .{ .name = "relic-rows", .source = "bench/rows.zig" } },
            .imports = &BenchImports(preflight.Bench.Imports).hook,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on relic as a fetch gives it: the three
    // modules, over every package relic takes. Its program names the
    // entry points that reach a remote, relic_lfs's, and relic_net's
    // network put in a `Means`.
    const conduit_dependency = p.dependency("conduit", .{ .target = target, .optimize = optimize });
    preflight.addConsumerCheck(b, p, .{
        .package = "relic",
        .program = p.path("ci/consumer.zig"),
        .modules = &.{ "relic", "relic_lfs", "relic_net" },
        .packages = &.{
            conduit_dependency,
            p.dependency("aegis", .{}),
            p.dependency("reactor", .{}),
            p.dependency("sweep", .{}),
            p.dependency("parallax", .{}),
            airlock_dependency,
            p.dependency("warp", .{}),
            p.dependency("xenoglyph", .{}),
            p.dependency("ladar", .{}),
            p.dependency("strand", .{}),
            p.dependency("uplink", .{}),
            p.dependency("cloak", .{}),
        },
    });
    // Only relic_net reaches the network's engines. A program over `relic`
    // alone, every public declaration referenced, compiles with uplink and
    // cloak replaced by a module that stops any compilation reaching it;
    // one over `relic_lfs` too, with relic's cloak replaced: its server's
    // signatures name uplink's server, but its HTTP client, which needs
    // cloak, is reached only through relic_net. Part of `check`.
    //
    // Each proof is a static library, not an object. uplink's server holds
    // a cloak TLS session (src/server/Socket.zig), so the `relic_lfs` proof
    // takes cloak, and with it cloak's assembly, beside its Zig. An object
    // must link those into one, and Zig 0.17's COFF linker cannot, so a
    // Windows target could not build it; an archive keeps them apart.
    const poison = p.createModule(.{ .root_source_file = p.path("src/testing/poison.zig") });
    const offline_step = b.step("check-offline", "Prove a program that names no relic_net compiles none of the network's engines");
    for ([_]struct { []const u8, Poison, bool }{
        .{ "src/testing/offline.zig", .{ .uplink = poison, .cloak = poison }, false },
        .{ "src/testing/offline_lfs.zig", .{ .cloak = poison }, true },
    }) |proof| {
        const offline_core = coreModule(p, target, optimize, proof[1]);
        const offline = p.createModule(.{ .root_source_file = p.path(proof[0]), .target = target, .optimize = optimize });
        offline.addImport("relic", p.createModule(relicModule(p, target, optimize, offline_core)));
        if (proof[2]) offline.addImport("relic_lfs", p.createModule(lfsModule(p, target, optimize, offline_core)));
        const offline_check = b.addLibrary(.{ .linkage = .static, .name = std.Io.Dir.path.stem(proof[0]), .root_module = offline });
        offline_step.dependOn(&offline_check.step);
        check_step.dependOn(&offline_check.step);
    }

    // The encodings' deltas (designs/relic.md §14): the generator runs
    // Apple's libiconv, so on macOS, reads glibc's from its source, and
    // Git for Windows' from a record of it made on Windows.
    const encodings = encodingsTool(b, p, b.graph.host);
    if (b.graph.host.result.os.tag == .macos) {
        encodings.root_module.linkSystemLibrary("iconv", .{});
        check_step.dependOn(&encodings.step);
    }
    const measure = b.addRunArtifact(encodings);
    measure.setCwd(p.path("."));
    if (b.option([]const u8, "glibc-source", "glibc's source, for the encodings step")) |source| measure.addArg(source);
    measure.addArg(b.option([]const u8, "windows-iconv", "Git for Windows' iconv, recorded by encodings-record, for the encodings step") orelse "tools/git-for-windows-iconv.txt");
    measure.addArg("src/text/legacy/tables.zig");
    measure.addArg("src/testing/legacy_disputes.zig");
    measure.has_side_effects = true;
    b.step("encodings", "Write src/text/legacy/tables.zig and the tests' src/testing/legacy_disputes.zig from Apple's libiconv, glibc's source (-Dglibc-source) and Git for Windows' record (-Dwindows-iconv)").dependOn(&measure.step);
    // Apple's iconv recorded as the Windows test records Git for Windows'
    // (`-- apple <record file>`, on macOS): the record's own check.
    const record_iconv = b.addRunArtifact(encodings);
    record_iconv.setCwd(p.path("."));
    record_iconv.addArg("record");
    record_iconv.addPassthruArgs();
    record_iconv.has_side_effects = true;
    b.step("encodings-record", "Record Apple's libiconv as Git for Windows' is recorded, the record's own check (-- apple <record file>, on macOS)").dependOn(&record_iconv.step);
}

/// What stands for relic_net's packages, uplink (HTTP and TCP) and cloak
/// (TLS's certificates, keys and trust), in a build that proves nothing
/// reaches them: `null` for the package itself.
const Poison = struct { uplink: ?*std.Build.Module = null, cloak: ?*std.Build.Module = null };
/// What Git LFS's JSON is read with.
const lfs_packages = [_][]const u8{"strand"};

/// `name`'s module of the same name, or `null` until the build has fetched
/// the package, when it asks again.
/// tools/encodings.zig built for `target`.
fn encodingsTool(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const xenoglyph = p.dependency("xenoglyph", .{ .target = target, .optimize = .safe }).module("xenoglyph");
    return b.addExecutable(.{ .name = "encodings", .root_module = b.createModule(.{
        .root_source_file = p.path("tools/encodings.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
        .imports = &.{
            .{ .name = "xenoglyph", .module = xenoglyph },
            .{ .name = "iconv_record", .module = b.createModule(.{ .root_source_file = p.path("tools/iconv_record.zig"), .target = target, .optimize = .safe }) },
            .{ .name = "legacy", .module = b.createModule(.{
                .root_source_file = p.path("src/text/legacy.zig"),
                .target = target,
                .optimize = .safe,
                .imports = &.{.{ .name = "xenoglyph", .module = xenoglyph }},
            }) },
        },
    }) });
}

fn lazyModule(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) ?*std.Build.Module {
    const dep = b.dependencyLazy(name, .{ .target = target, .optimize = optimize }) catch |err| switch (err) {
        error.LazyDependencyNeeded => return null,
    };
    return dep.module(name);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};

/// relic as the development build has it: the package.
fn relicPackage(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Dependency {
    return b.dependency("relic", .{ .target = target, .optimize = optimize });
}

/// preflight's hook for the benchmarks' modules (`Imports` is its
/// `Bench.Imports`): preflight makes the modules for each mode it builds
/// them in, after `dev` has returned.
fn BenchImports(comptime Imports: type) type {
    return struct {
        const hook: Imports = .{ .make = make };

        fn make(_: *const Imports, b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
            return benchImports(b, target, optimize);
        }
    };
}

/// The benchmarks' relic: `src/benchmark.zig`, in the mode the benchmark
/// builds in, over the `relic`, `relic_lfs` and `relic_net` modules and the
/// core beneath them, as a consumer gets them, and shakedown.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = relicPackage(b, target, optimize).builder;
    const core = coreModule(p, target, optimize, .{});
    const module = b.createModule(.{ .root_source_file = p.path("src/benchmark.zig"), .target = target, .optimize = optimize, .imports = moduleImports(p, target, optimize, .{}, &.{}) });
    module.addImport("relic_core", core.module);
    module.addImport("relic", p.createModule(relicModule(p, target, optimize, core)));
    const lfs = p.createModule(lfsModule(p, target, optimize, core));
    module.addImport("relic_lfs", lfs);
    const net = p.createModule(.{
        .root_source_file = p.path("src/net.zig"),
        .target = target,
        .optimize = optimize,
        .imports = rootImports(p, target, optimize, core, &.{}),
    });
    net.addImport("relic_lfs", lfs);
    module.addImport("relic_net", net);
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "relic", .module = module }}) catch @panic("out of memory");
}
