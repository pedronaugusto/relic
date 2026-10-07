const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Expected = @import("../refs.zig").Expected;
const Format = @import("../refs.zig").Format;
const LogEntry = @import("../refs.zig").LogEntry;
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
const reftable = @import("../refs.zig").reftable;
const reftablestack = @import("../refs.zig").reftablestack;
const testgit = @import("git.zig");
const hash = @import("../hash.zig");
const repo_mod = @import("../repo.zig");
const head = @import("../commit/head.zig");
const object = @import("../object.zig");
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

const fixture_who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// The ref formats a test runs in: files always, reftable where the git on
/// the path makes one (2.45).
fn formats(gpa: Allocator, io: Io) ![]const []const []const u8 {
    if (try testgit.gitAtLeast(gpa, io, 2, 45)) return &.{ &.{}, &.{"--ref-format=reftable"} };
    return &.{&.{}};
}

/// A repository with one commit, `HEAD` on `main`, made by git.
fn committed(gpa: Allocator, io: Io, args: []const []const u8) !testgit.Repo {
    var r = try testgit.Repo.init(gpa, io, args);
    errdefer r.deinit();
    try r.writeFile(io, "f", "f\n");
    try r.exec(io, &.{ "add", "f" });
    try r.exec(io, &.{ "commit", "-q", "-m", "one" });
    return r;
}

/// Whether git finds a log for `name`.
fn gitHasLog(io: Io, r: *testgit.Repo, name: []const u8) !bool {
    var captured = try r.capture(io, &.{ "reflog", "exists", name });
    defer captured.deinit(r.gpa);
    return captured.code == 0;
}

test "a deleted ref's log goes with it when the transaction logs nothing, in files and reftable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for (try formats(gpa, io)) |args| {
        var r = try committed(gpa, io, args);
        defer r.deinit();
        try r.exec(io, &.{ "branch", "topic" });
        try std.testing.expect(try gitHasLog(io, &r, "refs/heads/topic"));
        var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
        defer repo.deinit(io);
        {
            var tx = repo.beginRefs();
            defer tx.deinit(io);
            try tx.delete("refs/heads/topic", .any);
            try tx.commit(io, null);
        }
        try std.testing.expect(!try gitHasLog(io, &r, "refs/heads/topic"));
        // A branch of the same name starts a log of its own, with nothing of the old one's.
        try r.exec(io, &.{ "branch", "topic" });
        const said = try r.run(io, &.{ "reflog", "show", "--format=%gs", "refs/heads/topic" });
        defer gpa.free(said);
        try std.testing.expectEqualStrings("branch: Created from main\n", said);
    }
}

test "HEAD's log gains a detach where it exists already and core.logAllRefUpdates says only there, in files and reftable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for (try formats(gpa, io)) |args| {
        var r = try committed(gpa, io, args);
        defer r.deinit();
        try r.exec(io, &.{ "config", "core.logAllRefUpdates", "false" });
        const tip_text = try r.line(io, &.{ "rev-parse", "HEAD" });
        defer gpa.free(tip_text);
        var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
        defer repo.deinit(io);
        const tip = try Oid.parse(repo.objectFormat(), tip_text);
        try head.detach(io, &repo, tip, tip, .{ .who = fixture_who, .message = "checkout: moving from main to HEAD" });
        const said = try r.run(io, &.{ "reflog", "show", "--format=%gs", "HEAD" });
        defer gpa.free(said);
        try std.testing.expectEqualStrings("checkout: moving from main to HEAD\ncommit (initial): one\n", said);
    }
}

/// Keeps every entry but the one `nth` back.
const DropOne = struct {
    nth: usize,

    pub fn keep(d: *const DropOne, entry: LogEntry, nth: usize) bool {
        _ = entry;
        return nth != d.nth;
    }
};

test "a log is started, expired and deleted through the store as git's reflog reads it, the ref left alone, in files and reftable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for (try formats(gpa, io)) |args| {
        var r = try committed(gpa, io, args);
        defer r.deinit();
        // A ref with no log: `core.logAllRefUpdates` does not log tags.
        try r.exec(io, &.{ "tag", "v1" });
        try std.testing.expect(!try gitHasLog(io, &r, "refs/tags/v1"));
        for ([_][]const u8{ "two", "three" }) |message| {
            try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", message });
        }
        var repo = try repo_mod.Repository.open(gpa, io, r.dir, .{});
        defer repo.deinit(io);
        const store = repo.refStore();

        try store.createLog(gpa, io, "refs/tags/v1");
        try std.testing.expect(try gitHasLog(io, &r, "refs/tags/v1"));
        const empty = try r.run(io, &.{ "reflog", "show", "refs/tags/v1" });
        defer gpa.free(empty);
        try std.testing.expectEqualStrings("", empty);
        // Started again, a log with entries keeps them.
        try store.createLog(gpa, io, "refs/heads/main");
        const before = try r.run(io, &.{ "reflog", "show", "--format=%gs", "refs/heads/main" });
        defer gpa.free(before);
        try std.testing.expectEqualStrings("commit: three\ncommit: two\ncommit (initial): one\n", before);

        // The middle entry goes; the ref stays where it is.
        const tip = try r.line(io, &.{ "rev-parse", "main" });
        defer gpa.free(tip);
        var drop: DropOne = .{ .nth = 1 };
        try store.expireLog(gpa, io, "refs/heads/main", .{}, &drop);
        const after = try r.run(io, &.{ "reflog", "show", "--format=%gs", "refs/heads/main" });
        defer gpa.free(after);
        try std.testing.expectEqualStrings("commit: three\ncommit (initial): one\n", after);
        const still = try r.line(io, &.{ "rev-parse", "main" });
        defer gpa.free(still);
        try std.testing.expectEqualStrings(tip, still);

        try store.deleteLog(gpa, io, "refs/heads/main");
        try std.testing.expect(!try gitHasLog(io, &r, "refs/heads/main"));
        const kept = try r.line(io, &.{ "rev-parse", "main" });
        defer gpa.free(kept);
        try std.testing.expectEqualStrings(tip, kept);
        // A log that is not there is no error.
        try store.deleteLog(gpa, io, "refs/heads/main");
    }
}
