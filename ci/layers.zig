//! Production concerns, lowest first. Public facades have no cycle exemptions.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "text", .patterns = &.{ "src/text/**", "src/text.zig" } },
    .{ .name = "codec", .patterns = &.{ "src/codec/**", "src/codec.zig" } },
    .{ .name = "hash", .patterns = &.{"src/hash/**"} },
    .{ .name = "report", .patterns = &.{ "src/report/**", "src/report.zig" } },
    .{ .name = "mail", .patterns = &.{ "src/mail/**", "src/mail.zig" } },
    .{ .name = "process", .patterns = &.{ "src/process/**", "src/process.zig" } },
    .{ .name = "fs", .patterns = &.{ "src/fs/**", "src/fs.zig" } },
    .{ .name = "names", .patterns = &.{ "src/names/**", "src/names.zig" } },
    .{ .name = "config", .patterns = &.{"src/config/**"} },
    .{ .name = "patterns", .patterns = &.{ "src/patterns/**", "src/patterns.zig" } },
    .{ .name = "object", .patterns = &.{"src/object/**"} },
    .{ .name = "hooks", .patterns = &.{"src/hooks/**"} },
    .{ .name = "odb", .patterns = &.{"src/odb/**"} },
    .{ .name = "refs", .patterns = &.{"src/refs/**"} },
    .{ .name = "index", .patterns = &.{"src/index/**"} },
    .{ .name = "discover", .patterns = &.{ "src/discover/**", "src/discover.zig" } },
    .{ .name = "checkout", .patterns = &.{ "src/checkout/**", "src/checkout.zig" } },
    .{ .name = "walk", .patterns = &.{ "src/walk/**", "src/walk.zig" } },
    .{ .name = "diff", .patterns = &.{"src/diff/**"} },
    .{ .name = "wire", .patterns = &.{ "src/wire/**", "src/wire.zig" } },
    .{ .name = "repo", .patterns = &.{"src/repo/**"} },
    .{ .name = "merge", .patterns = &.{"src/merge/**"} },
    .{ .name = "maintenance", .patterns = &.{"src/maintenance/**"} },
    .{ .name = "worktree", .patterns = &.{"src/worktree/**"} },
    .{ .name = "rev_walk", .patterns = &.{"src/rev_walk/**"} },
    .{ .name = "pretty", .patterns = &.{"src/pretty/**"} },
    .{ .name = "commit", .patterns = &.{"src/commit/**"} },
    .{ .name = "patch", .patterns = &.{"src/patch/**"} },
    .{ .name = "rebase", .patterns = &.{"src/rebase/**"} },
    .{ .name = "fast", .patterns = &.{ "src/fast.zig", "src/fast/**" } },
    .{ .name = "submodule", .patterns = &.{"src/submodule/**"} },
    .{ .name = "transport", .patterns = &.{"src/transport/**"} },
    .{ .name = "stage", .patterns = &.{ "src/stage/**", "src/stage.zig" } },
    .{ .name = "archive", .patterns = &.{ "src/archive.zig", "src/archive/**" } },
    .{ .name = "clean", .patterns = &.{"src/clean.zig"} },
    .{ .name = "grep", .patterns = &.{"src/grep.zig"} },
    .{ .name = "facades", .patterns = &.{ "src/commit.zig", "src/config.zig", "src/diff.zig", "src/hash.zig", "src/index.zig", "src/merge.zig", "src/maintenance.zig", "src/object.zig", "src/odb.zig", "src/patch.zig", "src/pretty.zig", "src/refs.zig", "src/repo.zig", "src/rev_walk.zig", "src/submodule.zig", "src/transport.zig", "src/worktree.zig" } },
    // The core module's root and the contract the public roots keep: the
    // core is everything up to here, and imports nothing above.
    .{ .name = "core", .patterns = &.{ "src/core.zig", "src/contract.zig" } },
    // relic_lfs, over the core.
    .{ .name = "lfs", .patterns = &.{ "src/lfs/**", "src/lfs.zig" } },
    .{ .name = "public", .patterns = &.{"src/relic.zig"} },
};

pub const required = [_][]const u8{ "src/relic.zig", "src/core.zig", "src/contract.zig", "src/lfs_tests.zig", "src/tests.zig", "src/clean_test.zig", "src/commit.zig", "src/config.zig", "src/diff.zig", "src/grep_test.zig", "src/hash.zig", "src/index.zig", "src/lfs.zig", "src/merge.zig", "src/maintenance.zig", "src/object.zig", "src/odb.zig", "src/patch.zig", "src/pretty.zig", "src/refs.zig", "src/repo.zig", "src/rev_walk.zig", "src/submodule.zig", "src/transport.zig", "src/worktree.zig" };
pub const entries: []const []const u8 = &.{};
pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "root", .path = "src/tests.zig", .from = "src/testing/concurrency.zig" },
    .{ .name = "relic", .path = "src/relic.zig", .from = "src/testing/**" },
    // The core, as its roots and the helpers the LFS tests share name it.
    .{ .name = "relic_core", .path = "src/core.zig" },
    .{ .name = "relic_lfs", .path = "src/lfs.zig", .from = "src/testing/**" },
    .{ .name = "relic", .path = "src/relic.zig", .from = "src/benchmark.zig" },
    .{ .name = "relic_lfs", .path = "src/lfs.zig", .from = "src/benchmark.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{ "aegis", "build_options", "builtin", "conduit", "reactor", "root", "std", "sweep", "parallax", "relic_options", "uplink", "cloak", "strand", "airlock", "airlock.testing", "warp", "xenoglyph", "shakedown" } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "facade imports", .target = "src/commit.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/config.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/diff.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/hash.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/index.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/merge.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/maintenance.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/object.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/odb.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/patch.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/pretty.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/refs.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/repo.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/rev_walk.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/submodule.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/transport.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/worktree.zig", .relative = true, .except_from = &.{ "src/core.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    // The three modules' layering (designs: relic's core, `relic` and
    // `relic_lfs`): the core imports neither public root nor LFS; LFS
    // reaches the core through `relic_core`, never by path and never the
    // public root; the public root reaches the core through `relic_core`
    // alone. The tests are one module and reach across.
    .{ .name = "the core imports no public root", .target = "src/relic.zig", .except_from = &(test_files ++ .{"src/relic.zig"}) },
    .{ .name = "the core imports no LFS", .target = "src/lfs/**", .except_from = &(test_files ++ lfs_files) },
    .{ .name = "the core imports no LFS", .target = "src/lfs.zig", .except_from = &(test_files ++ lfs_files) },
    .{ .name = "LFS reaches the core by relic_core", .from = "src/lfs/**", .relative = true, .suffix = ".zig", .except_targets = &.{"src/lfs/**"}, .except_from = &.{"src/lfs/**/*_test.zig"} },
    .{ .name = "LFS reaches the core by relic_core", .from = "src/lfs.zig", .relative = true, .suffix = ".zig", .except_targets = &.{ "src/lfs/**", "src/lfs.zig" } },
    .{ .name = "the public root reaches the core by relic_core", .from = "src/relic.zig", .relative = true, .suffix = ".zig", .except_targets = &.{"src/relic.zig"} },
};

/// Files of the one test module, which holds the core's files and LFS's.
const test_files = .{ "src/testing/**", "src/tests.zig", "src/lfs_tests.zig", "src/**/*_test.zig", "src/benchmark.zig" };
/// relic_lfs's own files.
const lfs_files = .{ "src/lfs/**", "src/lfs.zig" };

const tests = [_][]const u8{ "src/testing/**", "src/**/*_test.zig" };

pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "process owner", .tokens = &.{ "waitpid", "wait4", "execve", "posix_spawn", "setsid", "CreateProcessW" } },
    // the ssh stand-in is another program, holding its handles as ssh does;
    // the stand-in for git's file monitor daemon serves a named pipe as
    // git for Windows' daemon does
    .{ .name = "windows declarations", .kind = .string, .tokens = &.{"kernel32"}, .owners = &.{ "src/fs/fs.zig", "src/testing/fake_ssh.zig", "src/checkout/fsmonitor_daemon_test.zig" } },
    // what a ref may be named is decided once, in `names/ref.zig`
    .{ .name = "one ref-name rule", .tokens = &.{ "checkRefFormat", "checkRefName", "isValidRefName", "isPseudoRef" } },
    // the root and special refs are spelled once, and reached through the
    // ref store as `names.Root` and `names.Special`; tests ask git for them
    .{
        .name = "root and special ref names",
        .kind = .string,
        .tokens = &.{ "ORIG_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "AUTO_MERGE", "BISECT_HEAD", "BISECT_EXPECTED_REV", "NOTES_MERGE_PARTIAL", "NOTES_MERGE_REF", "FETCH_HEAD", "MERGE_HEAD" },
        .owners = &[_][]const u8{"src/names/ref.zig"} ++ tests,
    },
    // where a ref store keeps its refs and their logs is the store's to name
    .{ .name = "ref storage names", .kind = .string, .tokens = &.{ "reftable", "tables.list", "packed-refs" }, .owners = &[_][]const u8{ "src/refs/refs.zig", "src/refs/**" } ++ tests },
    .{ .name = "reflog files owner", .kind = .string, .tokens = &.{ "logs", "logs/*" }, .owners = &[_][]const u8{ "src/refs/refs.zig", "src/refs/**" } ++ tests },
    .{ .name = "stash ref owner", .kind = .string, .tokens = &.{"refs/stash"}, .owners = &[_][]const u8{"src/names/ref.zig"} ++ tests },
    // the published configuration is the repository's to replace
    .{ .name = "gitfile owner", .kind = .string, .tokens = &.{ "gitdir: ", "gitdir:" }, .owners = &[_][]const u8{ "src/discover/gitfile.zig", "src/config/config.zig" } ++ tests },
    .{ .name = "configuration owner", .tokens = &.{"config_state"}, .owners = &[_][]const u8{"src/repo/repo.zig"} ++ tests },
    // a number in git's data is read by one of git's grammars, never by
    // Zig's, which takes `+` and `_`
    // a space is git's (`text.ctype`): C's and Zig's take a vertical tab
    // and a form feed too; git-lfs's netrc reads Go's
    .{ .name = "space class", .tokens = &.{"isWhitespace"}, .owners = &[_][]const u8{ "src/text/**", "src/lfs/netrc.zig" } ++ tests },
    .{ .name = "number grammars", .tokens = &.{ "parseInt", "parseUnsigned" }, .owners = &[_][]const u8{ "src/text/**", "src/config/config.zig" } ++ tests },
    .{ .name = "one character set conversion", .kind = .string, .tokens = &.{ "ISO-8859-1", "iso-8859-1", "latin1", "LATIN1", "US-ASCII", "us-ascii" }, .owners = &[_][]const u8{"src/text/**"} ++ tests },
    // a test's children run in an environment the test made, never the
    // test process's own, which holds the person's git, gpg and ssh
    // settings: only `testing/git.zig` reads that environment, and only it
    // starts a child, refusing one left to inherit it; the stand-in
    // programs run in the environment git, relic or the build gave them
    .{ .name = "a test's environment", .sequences = &.{&.{ "testing", ".", "environ" }}, .owners = &.{"src/testing/git.zig"} },
    .{
        .name = "a test's children",
        .sequences = &.{ &.{ "process", ".", "spawn" }, &.{ "process", ".", "run" } },
        .owners = &.{ "src/testing/git.zig", "src/testing/held_git.zig", "src/testing/fake_ssh.zig", "src/testing/hook.zig", "src/testing/remote_helper.zig", "src/testing/lfs/tool.zig" },
    },
};

// The owner requires every production edge to count. No re-export exemptions.
pub const reexports = &.{};
