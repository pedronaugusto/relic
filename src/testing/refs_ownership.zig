const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Expected = @import("../refs.zig").Expected;
const Format = @import("../refs.zig").Format;
const LogMessage = @import("../refs.zig").LogMessage;
const Named = @import("../refs.zig").Named;
const Peeler = @import("../refs.zig").Peeler;
const ReadError = @import("../refs.zig").ReadError;
const Ref = @import("../refs.zig").Ref;
const Resolved = @import("../refs.zig").Resolved;
const Store = @import("../refs.zig").Store;
const Transaction = @import("../refs.zig").Transaction;
const TransactionError = @import("../refs.zig").TransactionError;
const max_symbolic_depth = @import("../refs.zig").max_symbolic_depth;
const packed_header = @import("../refs.zig").packed_header;
const reflog = @import("../refs.zig").reflog;
const reftable = @import("../refs.zig").reftable;
const reftablestack = @import("../refs.zig").reftablestack;
const testgit = @import("git.zig");
const hash = @import("../hash.zig");
const repo_mod = @import("../repo.zig");
const Oid = hash.Oid;
const Kind = hash.Kind;
test "one transaction logs each ref in its own words when its edits say so, as git's atomic fetch does, in files and reftable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const []const u8{ &.{}, &.{"--ref-format=reftable"} }) |args| {
        // A reftable repository is git 2.45's to make.
        if (args.len != 0 and !try testgit.gitAtLeast(gpa, io, 2, 45)) continue;
        var r = try testgit.Repo.init(gpa, io, args);
        defer r.deinit();
        try r.writeFile(io, "f", "f\n");
        try r.exec(io, &.{ "add", "f" });
        try r.exec(io, &.{ "commit", "-q", "-m", "one" });
        const head_text = try r.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(head_text);
        var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
        defer repo.deinit(io);
        const oid = try Oid.parse(repo.objectFormat(), head_text);
        {
            var tx = repo.beginRefs();
            defer tx.deinit(io);
            try tx.change("refs/remotes/origin/a", .{ .direct = oid }, .must_not_exist, .{ .message = "fetch: storing head" });
            try tx.change("refs/remotes/origin/b", .{ .direct = oid }, .must_not_exist, .{ .message = "  fetch:\tsecond  one " });
            try tx.change("refs/remotes/origin/c", .{ .direct = oid }, .must_not_exist, .{});
            try tx.commit(io, .{
                .who = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 },
                .message = "the transaction's",
                .policy = .always,
            });
        }
        for ([_][2][]const u8{
            .{ "refs/remotes/origin/a", "fetch: storing head\n" },
            .{ "refs/remotes/origin/b", "fetch: second one\n" },
            .{ "refs/remotes/origin/c", "the transaction's\n" },
        }) |case| {
            const said = try r.run(io, &.{ "reflog", "show", "--format=%gs", case[0] });
            defer gpa.free(said);
            try std.testing.expectEqualStrings(case[1], said);
        }
    }
}
