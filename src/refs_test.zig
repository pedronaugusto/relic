//! The ref store against git: the root refs and the special refs, refs
//! with bad names, and another worktree's refs, in both ref formats.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const refs = @import("refs.zig");
const names = refs.names;
const hash = @import("hash.zig");
const repo_mod = @import("repo.zig");
const revparse = @import("revwalk/revparse.zig");
const commit_mod = @import("commit.zig");
const testgit = @import("testing/git.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

const object = @import("object.zig");

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
