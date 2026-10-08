//! The ref store against git: the root refs and the special refs, refs
//! with bad names, and another worktree's refs, in both ref formats.

const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const refs = @import("refs.zig");
const names = @import("../names/ref.zig");
const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const revparse = @import("../revwalk/revparse.zig");
const commit_mod = @import("../commit/commit.zig");
const testgit = @import("../testing/git.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

const object = @import("../object/object.zig");

const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = 1_700_000_000, .offset_minutes = 0 };

/// A repository of two commits on `main`, and a branch `side` at the
/// first, its refs kept in `format`.
fn twoCommits(gpa: Allocator, io: Io, format: testgit.RefFormat) !testgit.Repo {
    var r = try testgit.Repo.init(gpa, io, format.initArgs());
    errdefer r.deinit();
    try r.writeFile(io, "f", "one\n");
    try r.exec(io, &.{ "add", "f" });
    try r.exec(io, &.{ "commit", "-q", "-m", "one" });
    try r.exec(io, &.{ "branch", "side" });
    try r.writeFile(io, "f", "two\n");
    try r.exec(io, &.{ "commit", "-q", "-am", "two" });
    return r;
}

fn oidOf(gpa: Allocator, io: Io, r: *testgit.Repo, rev: []const u8) !Oid {
    const text = try r.line(io, &.{ "rev-parse", "--verify", "-q", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

/// Whether git finds `name`.
fn gitHas(io: Io, r: *testgit.Repo, name: []const u8) !bool {
    r.report_failures = false;
    defer r.report_failures = true;
    r.exec(io, &.{ "rev-parse", "--verify", "-q", name }) catch |err| switch (err) {
        error.GitFailed => return false,
        else => |e| return e,
    };
    return true;
}

test "a root ref is written, read and removed as itself, never through what it names, as git's are" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var r = try twoCommits(gpa, io, format);
            defer r.deinit();
            const tip = try oidOf(gpa, io, &r, "main");
            const side = try oidOf(gpa, io, &r, "side");
            var repo = try Repository.open(gpa, io, r.dir, .{});
            defer repo.deinit(io);
            const roots = repo.refStore().root();
            const orig = names.Root.orig_head.name();

            try std.testing.expect(!roots.exists(gpa, io, .orig_head));
            try std.testing.expectEqual(null, try roots.read(gpa, io, .orig_head));
            try roots.write(gpa, io, .orig_head, tip);
            try std.testing.expect(roots.exists(gpa, io, .orig_head));
            try std.testing.expect((try roots.read(gpa, io, .orig_head)).?.eql(tip));
            try std.testing.expect((try oidOf(gpa, io, &r, orig)).eql(tip));

            // One that names a branch is replaced, and the branch stays
            // where it was: git's `REF_NO_DEREF`.
            try r.exec(io, &.{ "symbolic-ref", orig, "refs/heads/side" });
            try roots.write(gpa, io, .orig_head, tip);
            try std.testing.expect((try oidOf(gpa, io, &r, "side")).eql(side));
            try std.testing.expect((try oidOf(gpa, io, &r, orig)).eql(tip));
            r.report_failures = false;
            try std.testing.expectError(error.GitFailed, r.exec(io, &.{ "symbolic-ref", "-q", orig }));
            r.report_failures = true;
            try r.exec(io, &.{ "symbolic-ref", orig, "refs/heads/side" });
            try roots.delete(gpa, io, .orig_head);
            try std.testing.expect((try oidOf(gpa, io, &r, "side")).eql(side));
            try std.testing.expect(!try gitHas(io, &r, orig));

            try roots.delete(gpa, io, .orig_head);
            try std.testing.expect(!roots.exists(gpa, io, .orig_head));

            // `HEAD` and the root refs, as git's `--include-root-refs`
            // lists them.
            try roots.write(gpa, io, .auto_merge, side);
            try roots.write(gpa, io, .cherry_pick_head, tip);
            var listing = try roots.list(gpa, io);
            defer listing.deinit();
            var seen: std.ArrayList(u8) = .empty;
            defer seen.deinit(gpa);
            for (listing.entries) |entry| try seen.print(gpa, "{s}\n", .{entry.name});
            try std.testing.expectEqualStrings("AUTO_MERGE\nCHERRY_PICK_HEAD\nHEAD\n", seen.items);
            if (try testgit.gitAtLeast(gpa, io, 2, 46)) {
                const theirs = try r.run(io, &.{ "for-each-ref", "--include-root-refs", "--format=%(refname)", "--exclude=refs/" });
                defer gpa.free(theirs);
                var kept: std.ArrayList(u8) = .empty;
                defer kept.deinit(gpa);
                var lines = std.mem.tokenizeScalar(u8, theirs, '\n');
                while (lines.next()) |line| if (std.mem.findScalar(u8, line, '/') == null) try kept.print(gpa, "{s}\n", .{line});
                try std.testing.expectEqualStrings(kept.items, seen.items);
            }
        }
    }.inFormat);
}

test "the special refs are files the store reads and replaces whole, and no transaction writes" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var r = try twoCommits(gpa, io, format);
            defer r.deinit();
            const tip = try oidOf(gpa, io, &r, "main");
            const side = try oidOf(gpa, io, &r, "side");
            var repo = try Repository.open(gpa, io, r.dir, .{});
            defer repo.deinit(io);
            const specials = repo.refStore().special();

            var hex: [2][hash.max_hex_len]u8 = undefined;
            const bytes = try std.mem.concat(gpa, u8, &.{ side.hex(&hex[0]), "\n", tip.hex(&hex[1]), "\n" });
            defer gpa.free(bytes);
            try std.testing.expect(!specials.exists(io, .merge_head));
            try specials.write(gpa, io, .merge_head, bytes);
            try std.testing.expect(specials.exists(io, .merge_head));
            const back = (try specials.readAll(gpa, io, .merge_head)).?;
            defer gpa.free(back);
            try std.testing.expectEqualStrings(bytes, back);
            try std.testing.expect((try specials.read(gpa, io, .merge_head)).?.eql(side));
            // A file in the git directory in either format, which git reads
            // as its first object name.
            const file = try r.readFile(io, ".git/MERGE_HEAD");
            defer gpa.free(file);
            try std.testing.expectEqualStrings(bytes, file);
            try std.testing.expect((try oidOf(gpa, io, &r, names.Special.merge_head.name())).eql(side));

            {
                var tx = repo.beginRefs();
                defer tx.deinit(io);
                inline for (comptime std.enums.values(names.Special)) |special| {
                    try std.testing.expectError(error.InvalidRefName, tx.update(special.name(), .{ .direct = tip }, .any));
                    try std.testing.expectError(error.InvalidRefName, tx.delete(special.name(), .any));
                }
            }
            // Appended to under its lock, as `git fetch --append` adds lines.
            try specials.write(gpa, io, .fetch_head, "first\n");
            try specials.append(gpa, io, .fetch_head, "second\n");
            const appended = (try specials.readAll(gpa, io, .fetch_head)).?;
            defer gpa.free(appended);
            try std.testing.expectEqualStrings("first\nsecond\n", appended);
            try specials.delete(io, .fetch_head);
            try specials.append(gpa, io, .fetch_head, "only\n");
            const fresh = (try specials.readAll(gpa, io, .fetch_head)).?;
            defer gpa.free(fresh);
            try std.testing.expectEqualStrings("only\n", fresh);

            try specials.delete(io, .merge_head);
            try specials.delete(io, .merge_head);
            try std.testing.expect(!specials.exists(io, .merge_head));
            try std.testing.expectEqual(null, try specials.read(gpa, io, .merge_head));
        }
    }.inFormat);
}

test "a ref with a bad name is deleted by that name, as git deletes it, and an unsafe name deletes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try twoCommits(gpa, io, .files);
    defer r.deinit();
    const tip = try oidOf(gpa, io, &r, "main");
    var hex: [hash.max_hex_len]u8 = undefined;
    const line = try std.mem.concat(gpa, u8, &.{ tip.hex(&hex), "\n" });
    defer gpa.free(line);
    // Names no ref may be given, which a stray file under `refs/` has.
    try r.writeFile(io, ".git/refs/heads/a..b", line);
    try r.writeFile(io, ".git/refs/heads/x.lock/y", line);
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    const store = repo.refStore();
    try std.testing.expectError(error.InvalidRefName, store.read(gpa, io, "refs/heads/a..b"));

    // A name that leaves `refs/` refuses the whole deletion.
    try std.testing.expectError(error.InvalidRefName, store.deleteRefs(gpa, io, &.{ "refs/heads/a..b", "refs/../config" }, null));
    try r.dir.access(io, ".git/refs/heads/a..b", .{});
    try r.dir.access(io, ".git/config", .{});

    try store.deleteRefs(gpa, io, &.{ "refs/heads/a..b", "refs/heads/x.lock/y", "refs/heads/never" }, null);
    try std.testing.expectError(error.FileNotFound, r.dir.access(io, ".git/refs/heads/a..b", .{}));
    try std.testing.expectError(error.FileNotFound, r.dir.access(io, ".git/refs/heads/x.lock/y", .{}));
    // git finds nothing wrong left behind.
    var captured = try r.capture(io, &.{"for-each-ref"});
    defer captured.deinit(gpa);
    try std.testing.expectEqualStrings("", captured.stderr);
}

test "another worktree's HEAD and logs are read as git reads them, and a transaction does not write them" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var r = try twoCommits(gpa, io, format);
            defer r.deinit();
            try r.exec(io, &.{ "worktree", "add", "-q", "-b", "wt", "linked", "side" });
            var linked = try r.dir.openDir(io, "linked", .{ .iterate = true });
            defer linked.close(io);
            var in_linked: testgit.Repo = .{ .gpa = gpa, .tmp = undefined, .dir = linked };
            try in_linked.writeFile(io, "g", "g\n");
            try in_linked.exec(io, &.{ "add", "g" });
            try in_linked.exec(io, &.{ "commit", "-q", "-m", "in the linked worktree" });
            try in_linked.exec(io, &.{ "bisect", "start", "HEAD", "HEAD~1" });

            var main_repo = try Repository.open(gpa, io, r.dir, .{});
            defer main_repo.deinit(io);
            var linked_repo = try Repository.open(gpa, io, linked, .{});
            defer linked_repo.deinit(io);

            const cases = [_]struct { repo: *Repository, git: *testgit.Repo, name: []const u8 }{
                .{ .repo = &main_repo, .git = &r, .name = "worktrees/linked/HEAD" },
                .{ .repo = &main_repo, .git = &r, .name = "worktrees/linked/refs/bisect/bad" },
                .{ .repo = &main_repo, .git = &r, .name = "main-worktree/HEAD" },
                .{ .repo = &linked_repo, .git = &in_linked, .name = "main-worktree/HEAD" },
                .{ .repo = &linked_repo, .git = &in_linked, .name = "worktrees/linked/HEAD" },
                .{ .repo = &linked_repo, .git = &in_linked, .name = "HEAD" },
            };
            for (cases) |case| {
                const theirs = try oidOf(gpa, io, case.git, case.name);
                const ours = try revparse.resolve(gpa, io, case.repo, case.name);
                std.testing.expect(ours.eql(theirs)) catch |err| {
                    std.debug.print("{s} differs\n", .{case.name});
                    return err;
                };
                if (std.mem.endsWith(u8, case.name, "HEAD")) {
                    const count_text = try case.git.run(io, &.{ "rev-list", "--count", "--walk-reflogs", case.name });
                    defer gpa.free(count_text);
                    var log = try case.repo.readLog(io, case.name);
                    defer log.deinit();
                    try std.testing.expectEqual(try std.fmt.parseInt(usize, std.mem.trimEnd(u8, count_text, "\n"), 10), log.entries.len);
                    try std.testing.expect(try case.repo.refStore().logExists(gpa, io, case.name));
                }
            }
            const target = (try main_repo.refStore().read(gpa, io, "worktrees/linked/HEAD")).?;
            defer gpa.free(target.symbolic);
            try std.testing.expectEqualStrings("refs/heads/wt", target.symbolic);
            try std.testing.expectEqual(null, try main_repo.refStore().read(gpa, io, "worktrees/gone/HEAD"));
            try std.testing.expect(!try main_repo.refStore().logExists(gpa, io, "worktrees/gone/HEAD"));

            var tx = main_repo.beginRefs();
            defer tx.deinit(io);
            const tip = try oidOf(gpa, io, &r, "main");
            try std.testing.expectError(error.OtherWorktreeRef, tx.update("main-worktree/HEAD", .{ .direct = tip }, .any));
            try std.testing.expectError(error.OtherWorktreeRef, tx.update("worktrees/linked/refs/bisect/bad", .{ .direct = tip }, .any));
            // A deletion names a ref inside `refs/` or a root ref, as git's
            // `refname_is_safe` asks.
            try std.testing.expectError(error.InvalidRefName, tx.delete("worktrees/linked/refs/bisect/bad", .any));
            // A prefix in front of a name no worktree keeps for itself is
            // part of a shared ref's name.
            try tx.update("worktrees/linked/refs/heads/x", .{ .direct = tip }, .any);
        }
    }.inFormat);
}

/// Keeps every entry of a log `expireLog` walks.
const KeepAll = struct {
    pub fn keep(_: *const KeepAll, _: refs.LogEntry, _: usize) bool {
        return true;
    }
};

/// How many entries git reads in `name`'s log.
fn gitLogCount(gpa: Allocator, io: Io, r: *testgit.Repo, name: []const u8) !usize {
    const text = try r.run(io, &.{ "rev-list", "--count", "--walk-reflogs", name });
    defer gpa.free(text);
    return std.fmt.parseInt(usize, std.mem.trimEnd(u8, text, "\n"), 10);
}

test "another worktree's log is not written from here, as its refs are not" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var r = try twoCommits(gpa, io, format);
            defer r.deinit();
            try r.exec(io, &.{ "worktree", "add", "-q", "-b", "wt", "linked", "side" });
            var repo = try Repository.open(gpa, io, r.dir, .{});
            defer repo.deinit(io);
            const store = repo.refStore();
            const tip = try oidOf(gpa, io, &r, "main");
            const keep_all: KeepAll = .{};
            for ([_][]const u8{ "main-worktree/HEAD", "worktrees/linked/HEAD" }) |name| {
                const before = try gitLogCount(gpa, io, &r, name);
                try std.testing.expectError(error.OtherWorktreeRef, store.appendLog(gpa, io, name, tip, tip, .{ .who = who, .message = "from elsewhere" }));
                try std.testing.expectError(error.OtherWorktreeRef, store.createLog(gpa, io, name));
                try std.testing.expectError(error.OtherWorktreeRef, store.expireLog(gpa, io, name, .{ .rewrite = true }, &keep_all));
                try std.testing.expectError(error.OtherWorktreeRef, store.deleteLog(gpa, io, name));
                try std.testing.expectEqual(before, try gitLogCount(gpa, io, &r, name));
            }
            // Nothing was written under the prefix as a shared ref's log.
            try std.testing.expectError(error.FileNotFound, r.dir.access(io, ".git/logs/main-worktree", .{}));
            try std.testing.expectError(error.FileNotFound, r.dir.access(io, ".git/logs/worktrees", .{}));
        }
    }.inFormat);
}

test "a symbolic ref that comes back to itself is refused, in either ref format" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var r = try twoCommits(gpa, io, format);
            defer r.deinit();
            try r.exec(io, &.{ "symbolic-ref", "refs/heads/a", "refs/heads/b" });
            try r.exec(io, &.{ "symbolic-ref", "refs/heads/b", "refs/heads/a" });
            var repo = try Repository.open(gpa, io, r.dir, .{});
            defer repo.deinit(io);
            try std.testing.expectError(error.SymbolicRefLoop, repo.refStore().resolve(gpa, io, "refs/heads/a"));
            try std.testing.expectError(error.SymbolicRefLoop, repo.refStore().readOid(gpa, io, "refs/heads/b"));
        }
    }.inFormat);
}

test "a commit is refused while a pick is stopped, in either ref format" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var r = try twoCommits(gpa, io, format);
            defer r.deinit();
            try r.exec(io, &.{ "checkout", "-q", "side" });
            try r.writeFile(io, "f", "three\n");
            try r.exec(io, &.{ "commit", "-q", "-am", "three" });
            r.report_failures = false;
            try std.testing.expectError(error.GitFailed, r.exec(io, &.{ "cherry-pick", "main" }));
            r.report_failures = true;
            try r.writeFile(io, "f", "resolved\n");
            try r.exec(io, &.{ "add", "f" });
            try std.testing.expect(try gitHas(io, &r, names.Root.cherry_pick_head.name()));

            var repo = try Repository.open(gpa, io, r.dir, .{});
            defer repo.deinit(io);
            try std.testing.expectError(error.OperationInProgress, commit_mod.commit(io, &repo, .{ .author = who, .committer = who, .message = "mine" }, .{}));
        }
    }.inFormat);
}

test "a listing keeps what is no ref apart, as git's marks it broken, and shadows a packed ref with it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try twoCommits(gpa, io, .files);
    defer r.deinit();
    const tip = try oidOf(gpa, io, &r, "main");
    const side = try oidOf(gpa, io, &r, "side");
    var hex: [2][hash.max_hex_len]u8 = undefined;
    const tip_hex = tip.hex(&hex[0]);
    const side_hex = side.hex(&hex[1]);
    const packed_text = try std.mem.concat(gpa, u8, &.{
        refs.packed_header,
        side_hex,
        " refs/heads/garbage\n",
        side_hex,
        " refs/heads/packed\n",
        side_hex,
        " refs/heads/p..q\n",
    });
    defer gpa.free(packed_text);
    try r.writeFile(io, ".git/packed-refs", packed_text);
    const line = try std.mem.concat(gpa, u8, &.{ tip_hex, "\n" });
    defer gpa.free(line);
    try r.writeFile(io, ".git/refs/heads/a..b", line);
    try r.writeFile(io, ".git/refs/heads/garbage", "not a ref\n");
    try r.writeFile(io, ".git/refs/heads/zero", "0000000000000000000000000000000000000000\n");

    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var listing = try repo.refStore().list(gpa, io, "refs/");
    defer listing.deinit();

    var ours: std.ArrayList(u8) = .empty;
    defer ours.deinit(gpa);
    for (listing.entries) |entry| try ours.print(gpa, "{s}\n", .{entry.name});
    var captured = try r.capture(io, &.{ "for-each-ref", "--format=%(refname)" });
    defer captured.deinit(gpa);
    try std.testing.expectEqualStrings(captured.stdout, ours.items);

    const expected = [_]struct { name: []const u8, why: refs.Broken.Why }{
        .{ .name = "refs/heads/a..b", .why = .bad_name },
        .{ .name = "refs/heads/garbage", .why = .bad_content },
        .{ .name = "refs/heads/p..q", .why = .bad_name },
        .{ .name = "refs/heads/zero", .why = .bad_content },
    };
    try std.testing.expectEqual(expected.len, listing.broken.len);
    for (expected, listing.broken) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqual(want.why, got.why);
        // git warns of each by name.
        try std.testing.expect(std.mem.find(u8, captured.stderr, want.name) != null);
    }
    // One whose file holds no ref is refused, as git refuses it ("reference
    // broken"); each of the others is deleted by its name, a packed one
    // with its line.
    try std.testing.expectError(error.MalformedRef, repo.refStore().deleteRefs(gpa, io, &.{"refs/heads/garbage"}, null));
    try repo.refStore().deleteRefs(gpa, io, &.{ "refs/heads/a..b", "refs/heads/p..q", "refs/heads/zero" }, null);
    var after = try r.capture(io, &.{ "for-each-ref", "--format=%(refname)" });
    defer after.deinit(gpa);
    try std.testing.expectEqualStrings("refs/heads/main\nrefs/heads/packed\nrefs/heads/side\n", after.stdout);
    for ([_][]const u8{ "a..b", "p..q", "zero" }) |gone| try std.testing.expect(std.mem.find(u8, after.stderr, gone) == null);
    try std.testing.expect(std.mem.find(u8, after.stderr, "refs/heads/garbage") != null);
}

test "an edit to a symbolic value releases its target when the transaction cannot take it" {
    const Check = struct {
        fn run(gpa: Allocator) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var store: refs.Store = try .init(gpa, .sha1, tmp.dir, tmp.dir, .{});
            defer store.deinit();
            var tx = store.begin(gpa);
            defer tx.deinit(std.testing.io);
            try tx.update("HEAD", .{ .symbolic = "refs/heads/main" }, .any);
        }
    };
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{});
    }
}
