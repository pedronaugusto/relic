const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Oid = @import("../hash.zig").Oid;
const Kind = @import("../hash.zig").Kind;
const access = @import("reftablestack/transaction.zig").test_access;
const hash = @import("reftablestack/cache.zig").internal.hash;
const object = @import("../object.zig");
const fs = @import("reftablestack/cache.zig").internal.fs;
const reftable = @import("reftablestack/cache.zig").internal.reftable;
const refs = @import("../refs.zig");
const reflog = @import("reflog.zig");
const Options = @import("reftablestack.zig").Options;
const Error = @import("reftablestack.zig").Error;
const max_reload_attempts = @import("reftablestack/cache.zig").internal.max_reload_attempts;
const Stack = @import("reftablestack.zig").Stack;
const mergedRefs = @import("reftablestack/cache.zig").internal.mergedRefs;
const allLogs = @import("reftablestack/cache.zig").internal.allLogs;
const copyLog = @import("reftablestack/cache.zig").internal.copyLog;
const lessThanRef = @import("reftablestack/cache.zig").internal.lessThanRef;
const newerFirst = @import("reftablestack/cache.zig").internal.newerFirst;
const logOrder = @import("reftablestack/cache.zig").internal.logOrder;
const isTableName = @import("reftablestack/cache.zig").internal.isTableName;
const tableName = @import("reftablestack/cache.zig").internal.tableName;
const Cache = @import("reftablestack.zig").Cache;
const Validity = @import("reftablestack/cache.zig").internal.Validity;
const View = access.View;
const Stacks = @import("reftablestack/cache.zig").internal.Stacks;
const loadIn = @import("reftablestack/cache.zig").internal.loadIn;
const reloadIn = @import("reftablestack/cache.zig").internal.reloadIn;
const isLinked = @import("reftablestack/cache.zig").internal.isLinked;
const isPerWorktree = @import("reftablestack/cache.zig").internal.isPerWorktree;
const read = @import("reftablestack.zig").read;
const readIn = access.readIn;
const resolveIn = access.resolveIn;
const list = @import("reftablestack.zig").list;
const lessThanNamed = access.lessThanNamed;
const readLog = @import("reftablestack.zig").readLog;
const put = access.put;
const logExists = @import("reftablestack.zig").logExists;
const minutesFromZone = @import("reftablestack.zig").minutesFromZone;
const zoneFromMinutes = @import("reftablestack.zig").zoneFromMinutes;
const Pending = @import("reftablestack.zig").Pending;
const lockStack = access.lockStack;
const prepare = @import("reftablestack.zig").prepare;
const checkNames = access.checkNames;
const deletedHere = access.deletedHere;
const commit = @import("reftablestack.zig").commit;
const appendLog = @import("reftablestack.zig").appendLog;
const install = access.install;
const releasePending = @import("reftablestack.zig").releasePending;
const addTable = access.addTable;
const logMessage = access.logMessage;
const writeTable = access.writeTable;
const Compaction = @import("reftablestack.zig").Compaction;
const compactIn = @import("reftablestack.zig").compactIn;
const Segment = access.Segment;
const suggestSegment = access.suggestSegment;
const suggest = access.suggest;
const testgit = @import("../testing/git.zig");
const repo_mod = @import("../repo.zig");
const state_mod = @import("state.zig");
const config_mod = @import("../config.zig");

test "the geometric rule merges what git's merges" {
    // git's own examples from its source.
    try std.testing.expect(suggest(&.{ 64, 32, 16, 8, 4, 2, 1 }, 2) == null);
    // The segment ends before the newest table, and gathering back from
    // there each older table is smaller than twice what came after it, so
    // it reaches the oldest.
    const tail = suggest(&.{ 64, 32, 16, 8, 4, 3, 1 }, 2).?;
    try std.testing.expectEqual(@as(usize, 0), tail.start);
    try std.testing.expectEqual(@as(usize, 6), tail.end);
    const deep = suggest(&.{ 128, 32, 16, 8, 4, 3, 1 }, 2).?;
    try std.testing.expectEqual(@as(usize, 1), deep.start);
    try std.testing.expectEqual(@as(usize, 6), deep.end);
    try std.testing.expect(suggest(&.{5}, 2) == null);
    const pair = suggest(&.{ 10, 10 }, 2).?;
    try std.testing.expectEqual(@as(usize, 0), pair.start);
    try std.testing.expectEqual(@as(usize, 2), pair.end);
}

test "a zone is git's hhmm number both ways" {
    try std.testing.expectEqual(@as(i16, 130), zoneFromMinutes(90));
    try std.testing.expectEqual(@as(i16, -500), zoneFromMinutes(-300));
    try std.testing.expectEqual(@as(i16, 90), minutesFromZone(130));
    try std.testing.expectEqual(@as(i16, -300), minutesFromZone(-500));
    try std.testing.expectEqual(@as(i16, 0), minutesFromZone(0));
}

fn requireReftableGit(gpa: Allocator, io: Io) !void {
    // `--ref-format=reftable` arrived in 2.45.
    try testgit.requireGitVersion(gpa, io, 2, 45);
}

fn fixtureWho(when: i64) object.Signature {
    return .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = when, .offset_minutes = 90 };
}

/// `git for-each-ref` as text, from a listing.
fn forEachRef(gpa: Allocator, listing: *const refs.Store.Listing) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var hex: [hash.max_hex_len]u8 = undefined;
    for (listing.entries) |entry| {
        switch (entry.target) {
            .direct => |oid| try out.print(gpa, "{s} {s}\n", .{ entry.name, oid.hex(&hex) }),
            .symbolic => |target| try out.print(gpa, "{s} -> {s}\n", .{ entry.name, target }),
        }
    }
    return out.toOwnedSlice(gpa);
}

fn gitForEachRef(io: Io, repo: *testgit.Repo) ![]u8 {
    return repo.run(io, &.{ "for-each-ref", "--format=%(refname)%(if)%(symref)%(then) -> %(symref)%(else) %(objectname)%(end)" });
}

/// `git log -g` as text, from a log: newest first, the new name and the
/// message.
fn reflogText(gpa: Allocator, log: *const reflog.Log) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var hex: [hash.max_hex_len]u8 = undefined;
    var i = log.entries.len;
    while (i > 0) {
        i -= 1;
        const e = log.entries[i];
        try out.print(gpa, "{s}\t{s}\n", .{ e.new.hex(&hex), e.message });
    }
    return out.toOwnedSlice(gpa);
}

fn gitReflog(io: Io, repo: *testgit.Repo, name: []const u8) ![]u8 {
    return repo.run(io, &.{ "log", "-g", "--format=%H%x09%gs", name, "--" });
}

test "a reftable repository git made is read through the refs API" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.exec(io, &.{ "branch", "topic" });
    try git.writeFile(io, "a.txt", "b\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "two" });
    try git.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1" });
    try git.exec(io, &.{ "tag", "light" });
    try git.exec(io, &.{ "branch", "gone" });
    try git.exec(io, &.{ "branch", "-D", "gone" });
    try git.exec(io, &.{ "symbolic-ref", "refs/heads/alias", "refs/heads/main" });
    try git.exec(io, &.{ "checkout", "-q", "topic" });

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try std.testing.expectEqual(refs.Format.reftable, repo.refStore().refFormat());

    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    try std.testing.expectEqualStrings("refs/heads/topic", head.name);
    const branch = (try repo.refStore().currentBranch(gpa, io)).?;
    defer gpa.free(branch);
    try std.testing.expectEqualStrings("topic", branch);
    try std.testing.expect(try repo.refStore().read(gpa, io, "refs/heads/gone") == null);

    var listing = try repo.refStore().list(gpa, io, "refs/");
    defer listing.deinit();
    const ours = try forEachRef(gpa, &listing);
    defer gpa.free(ours);
    const theirs = try gitForEachRef(io, &git);
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours);
    // git records the annotated tag's target beside it.
    try std.testing.expect(listing.find("refs/tags/v1").?.peeled != null);

    for ([_][]const u8{ "HEAD", "refs/heads/main", "refs/heads/topic" }) |name| {
        var log = try repo.readLog(io, name);
        defer log.deinit();
        const text = try reflogText(gpa, &log);
        defer gpa.free(text);
        const expected = try gitReflog(io, &git, name);
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, text);
        try std.testing.expect(log.entries.len > 0);
    }
}

test "what this writes into a reftable repository git reads, logs and all" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .default_branch = "main", .ref_format = .reftable });
    defer repo.deinit(io);

    const tree = try repo.odb.write(io, .tree, "");
    var commits: [12]Oid = undefined;
    var parent: ?Oid = null;
    for (&commits, 0..) |*c, i| {
        c.* = try repo.writeCommit(io, .{
            .tree = tree,
            .parents = if (parent) |p| &.{p} else &.{},
            .author = fixtureWho(1_700_000_000 + @as(i64, @intCast(i))),
            .committer = fixtureWho(1_700_000_000 + @as(i64, @intCast(i))),
            .message = "a commit\n",
        }, null);
        parent = c.*;
    }
    const tag = try repo.writeTag(io, .{
        .target = commits[3],
        .target_type = .commit,
        .name = "v1",
        .tagger = fixtureWho(1_700_000_100),
        .message = "a tag\n",
    }, null);

    // One transaction per commit, each moving main and HEAD's log with it,
    // and the geometric rule compacting as they pile up.
    for (commits, 0..) |c, i| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.update("refs/heads/main", .{ .direct = c }, if (i == 0) .must_not_exist else .{ .matches = commits[i - 1] });
        try tx.update("HEAD", .{ .symbolic = "refs/heads/main" }, .any);
        try tx.commit(io, .{ .who = fixtureWho(1_700_000_000 + @as(i64, @intCast(i))), .message = "commit: a commit" });
    }
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/tags/v1", .{ .direct = tag });
        try tx.create("refs/heads/topic", .{ .direct = commits[5] });
        try tx.create("refs/heads/doomed", .{ .direct = commits[6] });
        try tx.create("refs/heads/link", .{ .symbolic = "refs/heads/topic" });
        try tx.commit(io, .{ .who = fixtureWho(1_700_000_200), .message = "branch: made" });
    }
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.delete("refs/heads/doomed", .must_exist);
        try tx.commit(io, .{ .who = fixtureWho(1_700_000_300), .message = "branch: deleted" });
    }

    // Compaction kept the stack short.
    {
        var dir = try repo.git_dir.openDir(io, "reftable", .{});
        defer dir.close(io);
        var stack = try Stack.load(gpa, io, dir, .sha1);
        defer stack.deinit();
        try std.testing.expect(stack.tables.len < 6);
        for (stack.tables) |*t| try t.verify(gpa);
    }

    var git: testgit.Repo = .{ .gpa = gpa, .tmp = undefined, .dir = tmp.dir };
    try git.exec(io, &.{ "fsck", "--no-progress" });
    try refsVerify(io, &git, &.{});
    const shown = try git.run(io, &.{ "show-ref", "--head", "-d" });
    defer gpa.free(shown);
    var hex: [hash.max_hex_len]u8 = undefined;
    var tag_hex: [hash.max_hex_len]u8 = undefined;
    var peel_hex: [hash.max_hex_len]u8 = undefined;
    var topic_hex: [hash.max_hex_len]u8 = undefined;
    const want = try gpa.print("{s} HEAD\n{s} refs/heads/link\n{s} refs/heads/main\n{s} refs/heads/topic\n{s} refs/tags/v1\n{s} refs/tags/v1^{{}}\n", .{
        commits[11].hex(&hex),
        commits[5].hex(&topic_hex),
        commits[11].hex(&hex),
        commits[5].hex(&topic_hex),
        tag.hex(&tag_hex),
        commits[3].hex(&peel_hex),
    });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, shown);

    var log = try repo.readLog(io, "refs/heads/main");
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 12), log.entries.len);
    const ours = try reflogText(gpa, &log);
    defer gpa.free(ours);
    const theirs = try gitReflog(io, &git, "refs/heads/main");
    defer gpa.free(theirs);
    try std.testing.expectEqualStrings(theirs, ours);
    const head_log = try gitReflog(io, &git, "HEAD");
    defer gpa.free(head_log);
    try std.testing.expectEqual(@as(usize, 12), std.mem.count(u8, head_log, "\n"));
    // The deleted branch's log went with it.
    var doomed = try repo.readLog(io, "refs/heads/doomed");
    defer doomed.deinit();
    try std.testing.expectEqual(@as(usize, 0), doomed.entries.len);

    // And git's own next write lands on the stack this left.
    try git.exec(io, &.{ "branch", "after", "main" });
    try git.exec(io, &.{"pack-refs"});
    const after = (try repo.refStore().read(gpa, io, "refs/heads/after")).?;
    try std.testing.expect(after.direct.eql(commits[11]));
}

test "a table written for a transaction is the table git writes for it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // `update-ref --stdin`'s symref-create is git 2.46's.
    try testgit.requireGitVersion(gpa, io, 2, 46);
    var twins: [2]testgit.Repo = undefined;
    var made: usize = 0;
    defer for (twins[0..made]) |*t| t.deinit();
    var blob_text: []u8 = &.{};
    defer gpa.free(blob_text);
    var tag_text: []u8 = &.{};
    defer gpa.free(tag_text);
    for (&twins) |*t| {
        t.* = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
        made += 1;
        // Objects written the same way in both, so both have the same names:
        // a blob, and an annotated tag of it with a fixed date.
        try t.writeFile(io, "blob.txt", "the same blob\n");
        gpa.free(blob_text);
        blob_text = try t.line(io, &.{ "hash-object", "-w", "blob.txt" });
        const tag_body = try gpa.print("object {s}\ntype blob\ntag v1\ntagger Fixture <fixture@example.com> 1700000000 +0000\n\nannotated\n", .{blob_text});
        defer gpa.free(tag_body);
        try t.writeFile(io, "tag.txt", tag_body);
        gpa.free(tag_text);
        tag_text = try t.line(io, &.{ "hash-object", "-t", "tag", "-w", "tag.txt" });

        // A large base, written and compacted by git in both, so that the
        // table under test is small beside it and nothing compacts it away.
        var base: std.ArrayList(u8) = .empty;
        defer base.deinit(gpa);
        for (0..1500) |i| try base.print(gpa, "create refs/base/b{d:0>4} {s}\n", .{ i, blob_text });
        try runWithInput(io, t, &.{ "update-ref", "--stdin" }, base.items);
    }

    // git: tags in one transaction, some of them the annotated one, and a
    // symbolic ref. Tags get no log under the default policy.
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    for (0..120) |i| try script.print(gpa, "create refs/tags/t{d:0>3} {s}\n", .{ i, if (i % 7 == 0) tag_text else blob_text });
    try script.print(gpa, "symref-create refs/tags/zz-link refs/heads/main\n", .{});
    try runWithInput(io, &twins[0], &.{ "update-ref", "--stdin" }, script.items);

    var repo = try repo_mod.Repository.open(gpa, io, twins[1].dir, .{});
    defer repo.deinit(io);
    {
        const blob_oid = try Oid.parse(.sha1, blob_text);
        const tag_oid = try Oid.parse(.sha1, tag_text);
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        var names: [120][16]u8 = undefined;
        for (0..120) |i| {
            const name = try std.mem.print(&names[i], "refs/tags/t{d:0>3}", .{i});
            try tx.create(name, .{ .direct = if (i % 7 == 0) tag_oid else blob_oid });
        }
        try tx.create("refs/tags/zz-link", .{ .symbolic = "refs/heads/main" });
        try tx.commit(io, .{ .who = fixtureWho(1_700_000_000), .message = "bulk" });
    }

    var lists: [2][]u8 = undefined;
    var newest: [2][]u8 = undefined;
    for (&twins, 0..) |*t, i| {
        lists[i] = try t.readFile(io, ".git/reftable/tables.list");
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, lists[i], "\n"), '\n');
        var last: []const u8 = "";
        while (lines.next()) |line| last = line;
        var path_buf: [128]u8 = undefined;
        newest[i] = try t.readFile(io, try std.mem.print(&path_buf, ".git/reftable/{s}", .{last}));
    }
    defer for (lists) |bytes| gpa.free(bytes);
    defer for (newest) |bytes| gpa.free(bytes);
    // The same stack shape on both sides: nothing compacted the new table.
    try std.testing.expectEqual(std.mem.count(u8, lists[0], "\n"), std.mem.count(u8, lists[1], "\n"));
    try std.testing.expect(std.mem.count(u8, lists[1], "\n") >= 2);
    try std.testing.expectEqualSlices(u8, newest[0], newest[1]);

    const a = try gitForEachRef(io, &twins[0]);
    defer gpa.free(a);
    const b = try gitForEachRef(io, &twins[1]);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "a held tables.list.lock refuses the transaction and changes nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable });
    defer repo.deinit(io);
    const before = try tmp.dir.readFileAlloc(io, ".git/reftable/tables.list", gpa, .limited(4096));
    defer gpa.free(before);

    const blocker = try tmp.dir.createFile(io, ".git/reftable/tables.list.lock", .{ .exclusive = true });
    blocker.close(io);
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/main", .{ .direct = Oid.zero(.sha1) });
        try std.testing.expectError(error.LockHeld, tx.commit(io, null));
    }
    try tmp.dir.access(io, ".git/reftable/tables.list.lock", .{});
    const after = try tmp.dir.readFileAlloc(io, ".git/reftable/tables.list", gpa, .limited(4096));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(try repo.refStore().read(gpa, io, "refs/heads/main") == null);
}

test "a name and a directory of names conflict with what is already there" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable });
    defer repo.deinit(io);
    const one = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/a", .{ .direct = one });
        try tx.commit(io, null);
    }
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/a/b", .{ .direct = one });
        try std.testing.expectError(error.RefNameConflict, tx.commit(io, null));
    }
    {
        // Deleting the one in the way in the same transaction is allowed.
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.delete("refs/heads/a", .must_exist);
        try tx.create("refs/heads/a-b", .{ .direct = one });
        try tx.commit(io, null);
    }
    try std.testing.expect(try repo.refStore().read(gpa, io, "refs/heads/a") == null);
}

test "FETCH_HEAD and MERGE_HEAD are files no transaction writes, and the other pseudorefs are in the stack, as git keeps them" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const tip_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(tip_text);
    const tip = try Oid.parse(.sha1, tip_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var line_buf: [64]u8 = undefined;
    const want_line = try std.mem.print(&line_buf, "{s}\n", .{tip_text});
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        // git's "refusing to update pseudoref": fetch and merge write these
        // files themselves.
        for ([_][]const u8{ "FETCH_HEAD", "MERGE_HEAD" }) |name| {
            try std.testing.expectError(error.InvalidRefName, tx.create(name, .{ .direct = tip }));
            const path = try gpa.print(".git/{s}", .{name});
            defer gpa.free(path);
            try git.writeFile(io, path, want_line);
        }
        for ([_][]const u8{ "ORIG_HEAD", "CHERRY_PICK_HEAD" }) |name| {
            try tx.create(name, .{ .direct = tip });
        }
        try tx.commit(io, .{ .who = fixtureWho(1_700_000_000), .message = "pseudorefs" });
    }
    for ([_][]const u8{ ".git/FETCH_HEAD", ".git/MERGE_HEAD" }) |path| {
        const text = try git.readFile(io, path);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(want_line, text);
    }
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, ".git/ORIG_HEAD", .{}));
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, ".git/CHERRY_PICK_HEAD", .{}));
    for ([_][]const u8{ "FETCH_HEAD", "MERGE_HEAD", "ORIG_HEAD", "CHERRY_PICK_HEAD" }) |name| {
        const seen = try git.line(io, &.{ "rev-parse", "--verify", "-q", name });
        defer gpa.free(seen);
        try std.testing.expectEqualStrings(tip_text, seen);
        const ours = (try repo.refStore().read(gpa, io, name)).?;
        try std.testing.expect(ours.direct.eql(tip));
    }
    // The special ones get no log.
    var fetch_log = try repo.readLog(io, "FETCH_HEAD");
    defer fetch_log.deinit();
    try std.testing.expectEqual(@as(usize, 0), fetch_log.entries.len);

    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try std.testing.expectError(error.InvalidRefName, tx.delete("MERGE_HEAD", .{ .matches = tip }));
        try tx.delete("CHERRY_PICK_HEAD", .must_exist);
        try tx.commit(io, null);
    }
    try git.dir.access(io, ".git/MERGE_HEAD", .{});
    git.report_failures = false;
    try std.testing.expectError(error.GitFailed, git.exec(io, &.{ "rev-parse", "--verify", "-q", "CHERRY_PICK_HEAD" }));
    git.report_failures = true;
    try refsVerify(io, &git, &.{});
}

test "git waits on the lock a prepared transaction holds, and reads the result" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const tip_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(tip_text);
    const tip = try Oid.parse(.sha1, tip_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.create("refs/heads/ours", .{ .direct = tip });
    try tx.prepare(io);

    // git gives up on `tables.list.lock` after its timeout rather than
    // break it, and writes nothing.
    git.report_failures = false;
    try std.testing.expectError(error.GitFailed, git.exec(io, &.{ "-c", "reftable.lockTimeout=0", "branch", "theirs" }));
    git.report_failures = true;

    try tx.commit(io, .{ .who = fixtureWho(1_700_000_000), .message = "branch: Created" });
    try git.exec(io, &.{ "branch", "theirs" });
    const ours = try git.line(io, &.{ "rev-parse", "refs/heads/ours" });
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(tip_text, ours);
    try std.testing.expect(try repo.refStore().read(gpa, io, "refs/heads/theirs") != null);
}

test "a repository's stack is kept between reads and read again only when it changes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const cache = state_mod.get(repo.refStore()._state).cache.?;
    for (0..50) |_| {
        const head = (try repo.head(io)).?;
        gpa.free(head.name);
    }
    try std.testing.expectEqual(@as(u64, 0), cache.reloads);

    // git adds a table, then compacts the stack away under the reader: the
    // next read sees both.
    try git.exec(io, &.{ "branch", "later" });
    try std.testing.expect(try repo.refStore().read(gpa, io, "refs/heads/later") != null);
    try std.testing.expectEqual(@as(u64, 1), cache.reloads);
    try git.exec(io, &.{ "branch", "-D", "later" });
    try git.exec(io, &.{"pack-refs"});
    try std.testing.expect(try repo.refStore().read(gpa, io, "refs/heads/later") == null);
    const main = (try repo.refStore().read(gpa, io, "refs/heads/main")).?;
    try std.testing.expect(main == .direct);
    try std.testing.expect(cache.reloads >= 2);
    const settled = cache.reloads;
    var listing = try repo.refStore().list(gpa, io, "refs/");
    defer listing.deinit();
    try std.testing.expectEqual(settled, cache.reloads);
}

test "a log entry goes into the stack, and the files path refuses to write where git will not look" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    const tip_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(tip_text);
    const tip = try Oid.parse(.sha1, tip_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try std.testing.expectError(
        error.ReftableRepository,
        reflog.append(gpa, io, repo.git_dir, "refs/heads/main", tip, tip, fixtureWho(1), "direct"),
    );
    try std.testing.expectError(error.ReftableRepository, reflog.read(gpa, io, repo.git_dir, "HEAD", .sha1));
    try std.testing.expectError(error.FileNotFound, git.dir.access(io, ".git/logs/refs/heads/main", .{}));

    try repo.refStore().appendLog(gpa, io, "refs/heads/main", tip, tip, fixtureWho(1_700_000_000), "reset: moving to HEAD");
    const shown = try gitReflog(io, &git, "refs/heads/main");
    defer gpa.free(shown);
    try std.testing.expect(std.mem.startsWith(u8, shown, tip_text));
    try std.testing.expect(std.mem.find(u8, shown, "\treset: moving to HEAD\n") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, shown, "\n"));
    var log = try repo.readLog(io, "refs/heads/main");
    defer log.deinit();
    try std.testing.expectEqualStrings("reset: moving to HEAD", log.entries[log.entries.len - 1].message);
}

fn createMain(io: Io, repo: *repo_mod.Repository) refs.TransactionError!void {
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.create("refs/heads/main", .{ .direct = Oid.zero(.sha1) });
    try tx.commit(io, null);
}

fn openWithTimeout(gpa: Allocator, io: Io, dir: Io.Dir, text: []const u8) !repo_mod.Repository {
    const config = try dir.readFileAlloc(io, ".git/config", gpa, .limited(1 << 16));
    defer gpa.free(config);
    const with = try gpa.print("{s}[reftable]\n\tlockTimeout = {s}\n", .{ config, text });
    defer gpa.free(with);
    try dir.writeFile(io, .{ .sub_path = ".git/config", .data = with });
    return repo_mod.Repository.open(gpa, io, dir, .{});
}

test "a writer waits for tables.list.lock as long as reftable.lockTimeout says" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var made = try repo_mod.Repository.init(gpa, io, tmp.dir, .{ .ref_format = .reftable });
        made.deinit(io);
    }
    {
        var repo = try openWithTimeout(gpa, io, tmp.dir, "0");
        defer repo.deinit(io);
        try std.testing.expect(repo.refStore().reftableOptions().lock == .fail);
    }
    var repo = try openWithTimeout(gpa, io, tmp.dir, "10000");
    defer repo.deinit(io);
    try std.testing.expectEqual(@as(u32, 10000), repo.refStore().reftableOptions().lock.wait_ms);

    // Held, then let go while the writer is waiting on it: the writer gets
    // the lock and commits rather than giving up.
    const blocker = try tmp.dir.createFile(io, ".git/reftable/tables.list.lock", .{ .exclusive = true });
    blocker.close(io);
    var pending = io.concurrent(createMain, .{ io, &repo }) catch {
        try tmp.dir.deleteFile(io, ".git/reftable/tables.list.lock");
        return error.SkipZigTest;
    };
    try io.sleep(.fromMilliseconds(150), .awake);
    try tmp.dir.deleteFile(io, ".git/reftable/tables.list.lock");
    try pending.await(io);
    try std.testing.expect(try repo.refStore().read(gpa, io, "refs/heads/main") != null);
}

/// `git refs verify`, where the git has it: 2.47 and later.
fn refsVerify(io: Io, repo: *testgit.Repo, prefix: []const []const u8) !void {
    testgit.requireGitVersion(repo.gpa, io, 2, 47) catch |err| switch (err) {
        error.SkipZigTest => return,
        else => |e| return e,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(repo.gpa);
    try argv.appendSlice(repo.gpa, prefix);
    try argv.appendSlice(repo.gpa, &.{ "refs", "verify" });
    try repo.exec(io, argv.items);
}

test "an update goes through HEAD, a deletion takes its log, and the hook hears what git's does, in a reftable" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // What the reference-transaction hook hears is git 2.54's: a
    // "preparing" state, and a symbolic ref's updates among the others.
    try testgit.requireGitVersion(gpa, io, 2, 54);
    const hooks = @import("../repo/hooks.zig");
    var environ = try testgit.programEnviron(gpa);
    defer environ.deinit();
    try environ.put("GIT_AUTHOR_DATE", "@1700000000 +0000");
    try environ.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
    var twins: [2]testgit.Repo = undefined;
    var made: usize = 0;
    defer for (twins[0..made]) |*t| t.deinit();
    for (&twins) |*r| {
        r.* = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
        made += 1;
        r.environ = &environ;
        defer r.environ = null;
        try r.writeFile(io, "a.txt", "a\n");
        try r.exec(io, &.{ "add", "a.txt" });
        try r.exec(io, &.{ "commit", "-q", "-m", "one" });
        try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "two" });
        try testgit.fixtureHook(gpa, io, r.dir, ".git/hooks/reference-transaction", "record_stdin", ".git/rt.log\n");
    }
    const first_text = try twins[0].line(io, &.{ "rev-parse", "HEAD~1" });
    defer gpa.free(first_text);
    const second_text = try twins[0].line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(second_text);
    const first = try Oid.parse(.sha1, first_text);
    const second = try Oid.parse(.sha1, second_text);

    const git_steps = [_][]const []const u8{
        &.{ "update-ref", "-m", "through HEAD", "HEAD", first_text, second_text },
        &.{ "update-ref", "-m", "the branch by name", "refs/heads/main", second_text },
        &.{ "update-ref", "--no-deref", "-m", "detached", "HEAD", first_text },
        &.{ "update-ref", "--no-deref", "-m", "attached", "HEAD", second_text },
        &.{ "symbolic-ref", "HEAD", "refs/heads/main" },
        &.{ "update-ref", "-m", "a topic", "refs/heads/topic", first_text },
        &.{ "update-ref", "-d", "-m", "gone", "refs/heads/topic" },
    };
    twins[0].environ = &environ;
    for (git_steps) |args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "-c", "core.hooksPath=.git/hooks" });
        try argv.appendSlice(gpa, args);
        try twins[0].exec(io, argv.items);
    }
    twins[0].environ = null;

    var repo = try repo_mod.Repository.open(gpa, io, twins[1].dir, .{});
    defer repo.deinit(io);
    var config = try config_mod.Config.parseText(gpa, "", .local);
    defer config.deinit();
    var runner = try hooks.Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = repo.git_dir,
        .common_dir = repo.common_dir,
        .work_dir = twins[1].dir,
    }, .{ .environ = &environ }, .{ .output = .ignore });
    defer runner.deinit();
    const Step = struct { name: []const u8, new: ?refs.Ref, expected: refs.Expected, no_deref: bool = false, message: ?[]const u8 };
    const steps = [_]Step{
        .{ .name = "HEAD", .new = .{ .direct = first }, .expected = .{ .matches = second }, .message = "through HEAD" },
        .{ .name = "refs/heads/main", .new = .{ .direct = second }, .expected = .any, .message = "the branch by name" },
        .{ .name = "HEAD", .new = .{ .direct = first }, .expected = .any, .no_deref = true, .message = "detached" },
        .{ .name = "HEAD", .new = .{ .direct = second }, .expected = .any, .no_deref = true, .message = "  attached \n" },
        .{ .name = "HEAD", .new = .{ .symbolic = "refs/heads/main" }, .expected = .any, .message = "" },
        .{ .name = "refs/heads/topic", .new = .{ .direct = first }, .expected = .any, .message = "a topic" },
        .{ .name = "refs/heads/topic", .new = null, .expected = .any, .message = "gone" },
    };
    const fixed: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };
    for (steps) |step| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        tx.hooks = &runner;
        try tx.change(step.name, step.new, step.expected, .{ .no_deref = step.no_deref });
        try tx.commit(io, if (step.message) |m| .{ .who = fixed, .message = m } else null);
    }

    const a = try twins[0].readFile(io, ".git/rt.log");
    defer gpa.free(a);
    const b = try twins[1].readFile(io, ".git/rt.log");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
    for ([_][]const u8{ "HEAD", "refs/heads/main", "refs/heads/topic" }) |name| {
        twins[0].report_failures = false;
        twins[1].report_failures = false;
        const x = gitReflog(io, &twins[0], name) catch "";
        defer if (x.len != 0) gpa.free(x);
        const y = gitReflog(io, &twins[1], name) catch "";
        defer if (y.len != 0) gpa.free(y);
        try std.testing.expectEqualStrings(x, y);
    }
    const x = try gitForEachRef(io, &twins[0]);
    defer gpa.free(x);
    const y = try gitForEachRef(io, &twins[1]);
    defer gpa.free(y);
    try std.testing.expectEqualStrings(x, y);
    const head_a = try twins[0].line(io, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(head_a);
    const head_b = try twins[1].line(io, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(head_b);
    try std.testing.expectEqualStrings(head_a, head_b);
}

/// Run git with `input` on its standard input.
fn runWithInput(io: Io, repo: *testgit.Repo, args: []const []const u8, input: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(repo.gpa);
    try argv.append(repo.gpa, testgit.program());
    try argv.appendSlice(repo.gpa, repo.defaults);
    try argv.appendSlice(repo.gpa, args);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = repo.dir },
        .environ_map = repo.environMap(),
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    {
        var buf: [4096]u8 = undefined;
        var w = child.stdin.?.writer(io, &buf);
        try w.interface.writeAll(input);
        try w.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

test "a linked worktree keeps its own HEAD in its own stack, both ways" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireReftableGit(gpa, io);
    const worktrees = @import("../worktree/worktrees.zig");
    var git = try testgit.Repo.init(gpa, io, &.{"--ref-format=reftable"});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "a\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "one" });
    try git.exec(io, &.{ "worktree", "add", "-q", "-b", "theirs", "trees/theirs" });
    const commit_text = try git.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(commit_text);
    const tip = try Oid.parse(.sha1, commit_text);

    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/heads/ours", .{ .direct = tip });
        try tx.commit(io, .{ .who = fixtureWho(1_700_000_000), .message = "branch: Created from main" });
    }
    try git.dir.createDirPath(io, "trees/ours");
    var dest = try git.dir.openDir(io, "trees/ours", .{ .iterate = true });
    defer dest.close(io);
    var added = try worktrees.add(gpa, io, repo.refStore(), "ours", dest, .{ .branch = "ours" });
    defer added.admin_dir.close(io);
    defer gpa.free(added.name);
    defer added.work_dir.close(io);

    // git reads the worktree this made, and this reads the one git made.
    const listed = try git.run(io, &.{ "worktree", "list", "--porcelain" });
    defer gpa.free(listed);
    try std.testing.expect(std.mem.find(u8, listed, "branch refs/heads/ours") != null);
    try std.testing.expect(std.mem.find(u8, listed, "branch refs/heads/theirs") != null);
    var ours = try repo.listWorktrees(io);
    defer ours.deinit();
    try std.testing.expectEqualStrings("ours", ours.find("ours").?.branch.?);
    try std.testing.expectEqualStrings("theirs", ours.find("theirs").?.branch.?);

    // Inside it, HEAD comes from its stack and the branch from the shared
    // one; a per-worktree ref written there stays there.
    var linked = try repo_mod.Repository.open(gpa, io, added.work_dir, .{ .discover = false });
    defer linked.deinit(io);
    const head = (try linked.head(io)).?;
    defer gpa.free(head.name);
    try std.testing.expectEqualStrings("refs/heads/ours", head.name);
    try std.testing.expect(head.oid.eql(tip));
    {
        var tx = linked.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/bisect/good", .{ .direct = tip });
        try tx.change("HEAD", .{ .direct = tip }, .any, .{ .no_deref = true });
        try tx.commit(io, .{ .who = fixtureWho(1_700_000_100), .message = "checkout: moving to detached" });
    }
    const detached = try git.line(io, &.{ "-C", "trees/ours", "rev-parse", "--symbolic-full-name", "HEAD" });
    defer gpa.free(detached);
    try std.testing.expectEqualStrings("HEAD", detached);
    const bisect = try git.line(io, &.{ "-C", "trees/ours", "rev-parse", "refs/bisect/good" });
    defer gpa.free(bisect);
    try std.testing.expectEqualStrings(commit_text, bisect);
    // The main worktree's HEAD did not move, and does not see the other's
    // per-worktree ref.
    const main_head = try git.line(io, &.{ "symbolic-ref", "HEAD" });
    defer gpa.free(main_head);
    try std.testing.expectEqualStrings("refs/heads/main", main_head);
    var shared = try repo.refStore().list(gpa, io, "refs/");
    defer shared.deinit();
    try std.testing.expect(shared.find("refs/bisect/good") == null);
    var own = try linked.refStore().list(gpa, io, "refs/");
    defer own.deinit();
    try std.testing.expect(own.find("refs/bisect/good") != null);
    try std.testing.expect(own.find("refs/heads/ours") != null);
    try refsVerify(io, &git, &.{ "-C", "trees/ours" });
}
