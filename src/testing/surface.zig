//! Contracts for the namespaces users import.
const std = @import("std");
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

fn tableCount(text: []const u8, comptime path: []const u8) usize {
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
            try std.testing.expectEqual(@as(usize, 1), comptime tableCount(@embedFile("../relic.zig"), path));
            try std.testing.expectEqual(@as(usize, 1), tableCount(readme, path));
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

test "phase2 module tables equal the exported namespace tree" {
    @setEvalBranchQuota(500000);
    const readme = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "README.md", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(readme);
    const count = try checkTree(relic, "", 3, readme);
    try std.testing.expectEqual(count, comptime rows(@embedFile("../relic.zig")));
    const start = std.mem.find(u8, readme, "<!-- BEGIN PHASE2 MODULES -->").?;
    const end = std.mem.find(u8, readme, "<!-- END PHASE2 MODULES -->").?;
    try std.testing.expectEqual(count, rows(readme[start..end]));
}

fn covers(comptime facade: type, comptime implementation: type) !void {
    inline for (@typeInfo(implementation).@"struct".decl_names) |name| {
        try std.testing.expect(@hasDecl(facade, name));
        if (@hasDecl(facade, name))
            try std.testing.expect(@TypeOf(@field(facade, name)) == @TypeOf(@field(implementation, name)));
    }
}

test "phase2 publishing facades cover every implementation declaration" {
    try covers(relic.repo, @import("../repo/repo.zig"));
    try covers(relic.hash, @import("../hash/hash.zig"));
    try covers(relic.object, @import("../object/object.zig"));
    try covers(relic.odb, @import("../odb/odb.zig"));
    try covers(relic.refs, @import("../refs/refs.zig"));
    try covers(relic.config, @import("../config/config.zig"));
    try covers(relic.index, @import("../index/index.zig"));
    try covers(relic.worktree, @import("../checkout/checkout.zig"));
    try covers(relic.diff, @import("../diff/diff.zig"));
    try covers(relic.revwalk, @import("../walk/walk.zig"));
    try covers(relic.merge, @import("../merge/merge.zig"));
    try covers(relic.commit, @import("../commit/commit.zig"));
    try covers(relic.transport, @import("../transport/transport.zig"));
    try covers(relic.submodule, @import("../submodule/submodule.zig"));
    try covers(relic.lfs, @import("../lfs/lfs.zig"));
    try covers(relic.patch, @import("../patch/patch.zig"));
    try covers(relic.pretty, @import("../pretty/pretty.zig"));
    try covers(relic.maintenance, @import("../maintenance/maintenance.zig"));
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

test "phase2 every public namespace and owned type names its errors" {
    @setEvalBranchQuota(500000);
    try checkErrors(relic, 3);
}

const index = relic.index;
const objectwalk = relic.revwalk.objectwalk;
const notes = relic.commit.notes;
const trailer = relic.commit.trailer;

test "phase2 public options signatures stay within five positional inputs" {
    inline for (.{ index.Index.read, objectwalk.missing, objectwalk.checkConnected, objectwalk.checkReceived, notes.copy, trailer.process, trailer.amend }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
    try std.testing.expect(!@hasDecl(index.Index, "readWithResolution"));
    try std.testing.expect(!@hasDecl(objectwalk, "missingWith"));
    try std.testing.expect(!@hasDecl(objectwalk, "checkConnectedWith"));
}

test "phase2 tree and ancestry requests stay within five positional inputs" {
    inline for (.{ relic.merge.trees, relic.merge.ort.trees, relic.merge.ort.commits, relic.merge.octopus.commits, relic.revwalk.mergeBases, relic.revwalk.mergeBasesMany, relic.revwalk.isAncestor, relic.diff.tree }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "phase2 worktree merge and reset requests stay within five positional inputs" {
    inline for (.{ relic.merge.threeway.apply, relic.merge.threeway.applyCommits, relic.merge.threeway.applyOctopus, relic.commit.reset.toTree, relic.commit.sequencer.resetMerge }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "phase2 diff output and attribution requests stay within five positional inputs" {
    inline for (.{ relic.diff.unified, relic.diff.blame.file, relic.diff.patchid.ofTrees }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "phase2 pack storage requests stay within five positional inputs" {
    inline for (.{ relic.odb.pack.Index.open, relic.odb.pack.Pack.open, relic.odb.pack.Pack.inflateWith, relic.odb.pack.Pack.readAtInto, relic.odb.pack.Writer.open, relic.odb.pack.Writer.openStream, relic.odb.pack.writeIndexFile, relic.odb.revindex.write, relic.odb.indexpack.receive, relic.odb.bitmap.encode }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
    try std.testing.expect(!@hasDecl(relic.odb.pack.Writer, "init"));
    try std.testing.expect(!@hasDecl(relic.odb.pack.Writer, "initCounting"));
}

test "phase2 filesystem requests stay within five positional inputs" {
    inline for (.{ relic.repo.fs.LockFile.open, relic.repo.fs.atomicWrite, relic.repo.fs.readFileSized }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}
test "phase2 program invocation owns its working directory type" {
    try std.testing.expect(@FieldType(relic.repo.program.Invocation, "cwd") == relic.repo.program.Cwd);
    try std.testing.expect(@FieldType(relic.repo.program.Invocation, "cwd") != std.process.Child.Cwd);
    try std.testing.expect(@FieldType(relic.commit.trailer.Commands, "cwd") == relic.repo.program.Cwd);
}

test "phase2 transport and LFS requests stay within five positional inputs" {
    inline for (.{ relic.transport.Session.open, relic.transport.Session.fetch, relic.transport.fetchpack.fetch, relic.transport.sendpack.send, relic.transport.local.Remote.receivePush, relic.transport.bundle.receive, relic.transport.bundle.create, relic.lfs.api.sshInvocation, relic.lfs.push.beforePush }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "phase2 working tree requests stay within five positional inputs" {
    inline for (.{ relic.worktree.addAll, relic.worktree.status, relic.worktree.checkout, relic.worktree.writePaths, relic.worktree.verifyUpdates, relic.worktree.differsFromIndex, relic.worktree.applySparse }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}

test "phase2 ref log and table requests stay within five positional inputs" {
    inline for (.{ relic.refs.Store.appendLog, relic.refs.Store.expireLog, relic.refs.reftablestack.appendLog, relic.refs.reftablestack.compactIn, relic.refs.reftable.write, @import("../refs/reflog.zig").expire }) |operation| {
        try std.testing.expect(@typeInfo(@TypeOf(operation)).@"fn".param_types.len <= 5);
    }
}
