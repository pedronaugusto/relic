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
    .{ .name = "revwalk", .patterns = &.{"src/revwalk/**"} },
    .{ .name = "pretty", .patterns = &.{"src/pretty/**"} },
    .{ .name = "commit", .patterns = &.{"src/commit/**"} },
    .{ .name = "patch", .patterns = &.{"src/patch/**"} },
    .{ .name = "fastimport", .patterns = &.{"src/fastimport.zig"} },
    .{ .name = "fastexport", .patterns = &.{"src/fastexport.zig"} },
    .{ .name = "transport", .patterns = &.{"src/transport/**"} },
    .{ .name = "submodule", .patterns = &.{"src/submodule/**"} },
    .{ .name = "archive", .patterns = &.{"src/archive.zig"} },
    .{ .name = "clean", .patterns = &.{"src/clean.zig"} },
    .{ .name = "grep", .patterns = &.{"src/grep.zig"} },
    .{ .name = "lfs", .patterns = &.{"src/lfs/**"} },
    .{ .name = "public", .patterns = &.{ "src/commit.zig", "src/config.zig", "src/diff.zig", "src/hash.zig", "src/index.zig", "src/lfs.zig", "src/merge.zig", "src/maintenance.zig", "src/object.zig", "src/odb.zig", "src/patch.zig", "src/pretty.zig", "src/refs.zig", "src/relic.zig", "src/repo.zig", "src/revwalk.zig", "src/submodule.zig", "src/transport.zig", "src/worktree.zig" } },
};

pub const required = [_][]const u8{ "src/relic.zig", "src/tests.zig", "src/archive_test.zig", "src/clean_test.zig", "src/commit.zig", "src/config.zig", "src/diff.zig", "src/fastexport_test.zig", "src/fastimport_test.zig", "src/grep_test.zig", "src/hash.zig", "src/index.zig", "src/lfs.zig", "src/merge.zig", "src/maintenance.zig", "src/object.zig", "src/odb.zig", "src/patch.zig", "src/pretty.zig", "src/refs.zig", "src/repo.zig", "src/revwalk.zig", "src/submodule.zig", "src/transport.zig", "src/worktree.zig" };
pub const entries: []const []const u8 = &.{};
pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "root", .path = "src/tests.zig", .from = "src/testing/concurrency.zig" },
    .{ .name = "relic", .path = "src/relic.zig", .from = "src/testing/**" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{ "build_options", "builtin", "conduit", "root", "std", "sweep", "parallax", "uplink", "cloak", "airlock", "airlock.testing", "warp", "shakedown" } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
    .{ .name = "facade imports", .target = "src/commit.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/config.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/diff.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/hash.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/index.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/lfs.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/merge.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/maintenance.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/object.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/odb.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/patch.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/pretty.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/refs.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/repo.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/revwalk.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/submodule.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/transport.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
    .{ .name = "facade imports", .target = "src/worktree.zig", .relative = true, .except_from = &.{ "src/relic.zig", "src/testing/**", "src/tests.zig", "src/**/*_test.zig" } },
};

const tests = [_][]const u8{ "src/testing/**", "src/**/*_test.zig" };

pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "process owner", .tokens = &.{ "waitpid", "wait4", "execve", "posix_spawn", "setsid", "CreateProcessW" } },
    // the ssh stand-in is another program, holding its handles as ssh does
    .{ .name = "windows declarations", .kind = .string, .tokens = &.{"kernel32"}, .owners = &.{ "src/fs/fs.zig", "src/testing/fake_ssh.zig" } },
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
    .{ .name = "configuration owner", .tokens = &.{"_config"}, .owners = &[_][]const u8{"src/repo/repo.zig"} ++ tests },
};

// The owner requires every production edge to count. No re-export exemptions.
pub const reexports = &.{};
