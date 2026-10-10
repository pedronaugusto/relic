//! Contracts for the namespaces users import.
const std = @import("std");
const repo_mod = @import("../repo/repo.zig");
const hash_mod = @import("../hash/hash.zig");
const object_mod = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const refs_mod = @import("../refs/refs.zig");
const config_mod = @import("../config/config.zig");
const index_mod = @import("../index/index.zig");
const checkout_mod = @import("../checkout/checkout.zig");
const diff_mod = @import("../diff/diff.zig");
const walk_mod = @import("../walk/walk.zig");
const merge_mod = @import("../merge/merge.zig");
const commit_mod = @import("../commit/commit.zig");
const transport_mod = @import("../transport/transport.zig");
const submodule_mod = @import("../submodule/submodule.zig");
const lfs_mod = @import("../lfs/lfs.zig");
const patch_mod = @import("../patch/patch.zig");
const pretty_mod = @import("../pretty/pretty.zig");
const maintenance_mod = @import("../maintenance/maintenance.zig");
const reflog_mod = @import("../refs/reflog.zig");
const relic = @import("../relic.zig");

fn isNamespace(comptime ns: type, comptime name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    const value = @field(ns, name);
    if (@TypeOf(value) != type) return false;
    return switch (@typeInfo(value)) {
        .@"struct" => |s| s.field_names.len == 0 and !s.is_tuple,
        else => false,
    };
}

fn tableCount(comptime path: []const u8, text: []const u8) usize {
    const needle = "| `" ++ path ++ "` |";
    var count: usize = 0;
    var rest = text;
    while (std.mem.find(u8, rest, needle)) |at| {
        count += 1;
        rest = rest[at + needle.len ..];
    }
    return count;
}

fn checkTree(comptime ns: type, comptime prefix: []const u8, comptime depth: usize, readme: []const u8) !usize {
    var count: usize = 0;
    inline for (@typeInfo(ns).@"struct".decl_names) |name| {
        if (comptime isNamespace(ns, name)) {
            const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
            try std.testing.expectEqual(@as(usize, 1), comptime tableCount(path, @embedFile("../relic.zig")));
            try std.testing.expectEqual(@as(usize, 1), tableCount(path, readme));
            try std.testing.expect(!@hasDecl(@field(ns, name), "test_access"));
            inline for (@typeInfo(ns).@"struct".decl_names) |other| {
                if (comptime isNamespace(ns, other) and !std.mem.eql(u8, name, other))
                    try std.testing.expect(@field(ns, name) != @field(ns, other));
            }
            count += 1;
            if (depth > 1) count += try checkTree(@field(ns, name), path, depth - 1, readme);
        }
    }
    return count;
}

fn rows(text: []const u8) usize {
    return std.mem.count(u8, text, "\n| `") + std.mem.count(u8, text, "\n//! | `");
}

test "module tables equal the exported namespace tree" {
    @setEvalBranchQuota(500000);
    const readme = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "README.md", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(readme);
    const count = try checkTree(relic, "", 3, readme);
    try std.testing.expectEqual(count, comptime rows(@embedFile("../relic.zig")));
    const start = std.mem.find(u8, readme, "<!-- BEGIN MODULES -->").?;
    const end = std.mem.find(u8, readme, "<!-- END MODULES -->").?;
    try std.testing.expectEqual(count, rows(readme[start..end]));
}

fn covers(comptime facade: type, comptime implementation: type) !void {
    inline for (@typeInfo(implementation).@"struct".decl_names) |name| {
        try std.testing.expect(@hasDecl(facade, name));
        if (@hasDecl(facade, name))
            try std.testing.expect(@TypeOf(@field(facade, name)) == @TypeOf(@field(implementation, name)));
    }
}

test "publishing facades cover every implementation declaration" {
    try covers(relic.repo, repo_mod);
    try covers(relic.hash, hash_mod);
    try covers(relic.object, object_mod);
    try covers(relic.odb, odb_mod);
    try covers(relic.refs, refs_mod);
    try covers(relic.config, config_mod);
    try covers(relic.index, index_mod);
    try covers(relic.worktree, checkout_mod);
    try covers(relic.diff, diff_mod);
    try covers(relic.revwalk, walk_mod);
    try covers(relic.merge, merge_mod);
    try covers(relic.commit, commit_mod);
    try covers(relic.transport, transport_mod);
    try covers(relic.submodule, submodule_mod);
    try covers(relic.lfs, lfs_mod);
    try covers(relic.patch, patch_mod);
    try covers(relic.pretty, pretty_mod);
    try covers(relic.maintenance, maintenance_mod);
}

fn checkErrors(comptime ns: type, comptime depth: usize) !void {
    inline for (@typeInfo(ns).@"struct".decl_names) |name| {
        const value = @field(ns, name);
        if (@TypeOf(value) == type) switch (@typeInfo(value)) {
            .@"struct" => {
                if (comptime isNamespace(ns, name) or @hasDecl(value, "deinit")) {
                    if (comptime @hasDecl(value, "Error")) {
                        try std.testing.expect(@typeInfo(value.Error) == .error_set);
                        try std.testing.expect(@typeInfo(value.Error).error_set.error_names != null);
                    } else {
                        std.debug.print("missing public Error: {s}\n", .{@typeName(value)});
                        return error.TestExpectedError;
                    }
                }
                if (comptime isNamespace(ns, name) and depth > 1) try checkErrors(value, depth - 1);
            },
            else => {},
        };
    }
}

test "every public namespace and owned type names its errors" {
    @setEvalBranchQuota(500000);
    try checkErrors(relic, 3);
}

const index = relic.index;
const objectwalk = relic.revwalk.objectwalk;
const notes = relic.commit.notes;
const trailer = relic.commit.trailer;

test "public options signatures stay within five positional inputs" {
    inline for (.{ index.Index.read, objectwalk.missing, objectwalk.checkConnected, objectwalk.checkReceived, notes.copy, trailer.process, trailer.amend }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
    try std.testing.expect(!@hasDecl(index.Index, "readWithResolution"));
    try std.testing.expect(!@hasDecl(objectwalk, "missingWith"));
    try std.testing.expect(!@hasDecl(objectwalk, "checkConnectedWith"));
}

test "tree and ancestry requests stay within five positional inputs" {
    inline for (.{ relic.merge.trees, relic.merge.ort.trees, relic.merge.ort.commits, relic.merge.octopus.commits, relic.revwalk.mergeBases, relic.revwalk.mergeBasesMany, relic.revwalk.isAncestor, relic.diff.tree }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "worktree merge and reset requests stay within five positional inputs" {
    inline for (.{ relic.merge.threeway.apply, relic.merge.threeway.applyCommits, relic.merge.threeway.applyOctopus, relic.commit.reset.toTree, relic.commit.sequencer.resetMerge }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "diff output and attribution requests stay within five positional inputs" {
    inline for (.{ relic.diff.unified, relic.diff.blame.file, relic.diff.patchid.ofTrees }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "pack storage requests stay within five positional inputs" {
    inline for (.{ relic.odb.pack.Index.open, relic.odb.pack.Pack.open, relic.odb.pack.Pack.inflateWith, relic.odb.pack.Pack.readAtInto, relic.odb.pack.Writer.open, relic.odb.pack.Writer.openStream, relic.odb.pack.writeIndexFile, relic.odb.revindex.write, relic.odb.indexpack.receive, relic.odb.bitmap.encode }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
    try std.testing.expect(!@hasDecl(relic.odb.pack.Writer, "init"));
    try std.testing.expect(!@hasDecl(relic.odb.pack.Writer, "initCounting"));
}

test "filesystem requests stay within five positional inputs" {
    inline for (.{ relic.repo.fs.LockFile.open, relic.repo.fs.atomicWrite, relic.repo.fs.readFileSized }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}
test "program invocation owns its working directory type" {
    try std.testing.expect(@FieldType(relic.repo.program.Invocation, "cwd") == relic.repo.program.Cwd);
    try std.testing.expect(@FieldType(relic.repo.program.Invocation, "cwd") != std.process.Child.Cwd);
    try std.testing.expect(@FieldType(relic.commit.trailer.Commands, "cwd") == relic.repo.program.Cwd);
}

test "how a program ended is conduit's Term, where it is shown" {
    const program = relic.repo.program;
    const conduit = @import("conduit");
    try std.testing.expect(program.Term == conduit.Term);
    try std.testing.expect(program.Term != std.process.Child.Term);
    try std.testing.expect(@FieldType(program.Outcome, "term") == conduit.Term);
    try std.testing.expect(program.Child.Term == conduit.Term);
    try std.testing.expect(@typeInfo(@typeInfo(@TypeOf(program.Running.wait)).@"fn".return_type.?).error_union.payload == conduit.Term);
    try std.testing.expect(@typeInfo(@typeInfo(@TypeOf(program.Child.wait)).@"fn".return_type.?).error_union.payload == conduit.Term);
    try std.testing.expect(@FieldType(relic.repo.hooks.Failure, "term") == ?conduit.Term);
    try std.testing.expect(@FieldType(relic.transport.connection.Process, "term") == ?conduit.Term);
}

test "transport and LFS requests stay within five positional inputs" {
    inline for (.{ relic.transport.Session.open, relic.transport.Session.fetch, relic.transport.fetchpack.fetch, relic.transport.sendpack.send, relic.transport.local.Remote.receivePush, relic.transport.bundle.receive, relic.transport.bundle.create, relic.lfs.api.sshInvocation, relic.lfs.push.beforePush }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "working tree requests stay within five positional inputs" {
    inline for (.{ relic.worktree.addAll, relic.worktree.status, relic.worktree.checkout, relic.worktree.writePaths, relic.worktree.verifyUpdates, relic.worktree.differsFromIndex, relic.worktree.applySparse }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "ref log and table requests stay within five positional inputs" {
    inline for (.{ relic.refs.Store.appendLog, relic.refs.Store.expireLog, relic.refs.reftablestack.appendLog, relic.refs.reftablestack.compactIn, relic.refs.reftable.write, reflog_mod.expire }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "history archive and maintenance requests stay within five positional inputs" {
    inline for (.{ relic.archive.archive, relic.patch.rangediff.compute, relic.patch.rangediff.write, relic.worktree.linked.add, relic.worktree.linked.move, relic.revwalk.bisect.mark, relic.maintenance.writePackBitmap, relic.maintenance.writeMidxBitmap, relic.merge.subtreeshift.shift }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}
