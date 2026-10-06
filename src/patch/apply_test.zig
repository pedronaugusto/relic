//! `apply` against `git apply`: the same patch, the same repository, and
//! the same working tree, index and `.rej` files afterwards, or the same
//! refusal with nothing changed.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const apply_mod = @import("apply.zig");
const repo_mod = @import("../repo.zig");
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;

/// Two repositories built by the same git commands: git applies to one and
/// relic to the other.
const Pair = struct {
    gpa: Allocator,
    git: testgit.Repo,
    ours: testgit.Repo,

    fn init(gpa: Allocator, io: Io) !Pair {
        var git = try testgit.Repo.init(gpa, io, &.{});
        errdefer git.deinit();
        const ours = try testgit.Repo.init(gpa, io, &.{});
        return .{ .gpa = gpa, .git = git, .ours = ours };
    }

    fn deinit(p: *Pair) void {
        p.git.deinit();
        p.ours.deinit();
        p.* = undefined;
    }

    fn both(p: *Pair, io: Io, args: []const []const u8) !void {
        try p.git.exec(io, args);
        try p.ours.exec(io, args);
    }

    fn write(p: *Pair, io: Io, path: []const u8, bytes: []const u8) !void {
        try p.git.writeFile(io, path, bytes);
        try p.ours.writeFile(io, path, bytes);
    }

    fn remove(p: *Pair, io: Io, path: []const u8) !void {
        try p.git.dir.deleteFile(io, path);
        try p.ours.dir.deleteFile(io, path);
    }
};

/// What a repository holds: every file the index or the working tree has,
/// with its type, executable bit and bytes, and the index's entries.
fn snapshot(gpa: Allocator, io: Io, r: *testgit.Repo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const staged = try r.run(io, &.{ "ls-files", "-s" });
    defer gpa.free(staged);
    try out.appendSlice(gpa, "index:\n");
    try out.appendSlice(gpa, staged);
    const listed = try r.run(io, &.{ "ls-files", "-z", "--cached", "--others" });
    defer gpa.free(listed);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = std.mem.splitScalar(u8, listed, 0);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (names.items.len > 0 and std.mem.eql(u8, names.items[names.items.len - 1], name)) continue;
        try names.append(gpa, name);
    }
    try out.appendSlice(gpa, "files:\n");
    for (names.items) |name| {
        const stat = r.dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                try out.print(gpa, "{s} missing\n", .{name});
                continue;
            },
            else => return err,
        };
        switch (stat.kind) {
            .sym_link => {
                var buf: [1024]u8 = undefined;
                const n = try r.dir.readLink(io, name, &buf);
                try out.print(gpa, "{s} link {s}\n", .{ name, buf[0..n] });
            },
            .file => {
                const bytes = try r.dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
                defer gpa.free(bytes);
                const exec = builtin.os.tag != .windows and stat.permissions.toMode() & 0o100 != 0;
                try out.print(gpa, "{s} {s} {d}\n", .{ name, if (exec) "exec" else "file", bytes.len });
                try out.appendSlice(gpa, bytes);
                try out.append(gpa, '\n');
            },
            else => try out.print(gpa, "{s} {s}\n", .{ name, @tagName(stat.kind) }),
        }
    }
    return out.toOwnedSlice(gpa);
}

const Verdict = enum { clean, unclean, refused };

/// Apply `patch` with `git apply <args>` on one side and `apply` with
/// `options` on the other, and require the same verdict and the same
/// repositories afterwards.
fn compare(p: *Pair, io: Io, patch: []const u8, args: []const []const u8, options: apply_mod.Options) !void {
    const gpa = p.gpa;
    // This follows today's git. `--3way` tries the merge first since 2.32
    // and passes it by in git's corner cases since 2.35, `--allow-empty`
    // came in 2.35, `--ours`, `--theirs` and `--union` with `--3way` came
    // in 2.47; `-N` keeps the rest of the index since 2.51, where an
    // older git wrote the index with the new files alone. An older git
    // answers something else, or nothing.
    const since: [2]u32 = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--ours") or std.mem.eql(u8, arg, "--theirs") or std.mem.eql(u8, arg, "--union")) break .{ 2, 47 };
    } else if (options.intent_to_add) .{ 2, 51 } else if (options.three_way or options.allow_empty) .{ 2, 35 } else .{ 0, 0 };
    if (!try testgit.gitAtLeast(gpa, io, since[0], since[1])) return;
    var git_dir = try p.git.gitDir(io);
    defer git_dir.close(io);
    try git_dir.writeFile(io, .{ .sub_path = "relic-test.patch", .data = patch });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "apply");
    try argv.appendSlice(gpa, args);
    try argv.append(gpa, ".git/relic-test.patch");
    var captured = try p.git.capture(io, argv.items);
    defer captured.deinit(gpa);
    const git_verdict: Verdict = switch (captured.code) {
        0 => .clean,
        1 => .unclean,
        else => .refused,
    };

    var repo = try Repository.open(gpa, io, p.ours.dir, .{});
    defer repo.deinit(io);
    var ours_verdict: Verdict = undefined;
    if (apply_mod.apply(gpa, io, &repo, patch, options)) |outcome_const| {
        var outcome = outcome_const;
        defer outcome.deinit();
        ours_verdict = if (outcome.clean()) .clean else .unclean;
    } else |err| switch (err) {
        error.PatchDoesNotApply => ours_verdict = .unclean,
        error.OutOfMemory => return err,
        else => ours_verdict = .refused,
    }
    // git apply exits 1 for a patch that does not apply and 128 for one it
    // cannot read or will not take; relic names both
    if (git_verdict != ours_verdict) {
        std.debug.print("git apply {s}: exit {d}\n{s}\nrelic: {s}\npatch:\n{s}\n", .{ if (args.len > 0) args[0] else "", captured.code, captured.stderr, @tagName(ours_verdict), patch });
        return error.TestExpectedEqual;
    }
    try git_dir.deleteFile(io, "relic-test.patch");
    const theirs = try snapshot(gpa, io, &p.git);
    defer gpa.free(theirs);
    const ours = try snapshot(gpa, io, &p.ours);
    defer gpa.free(ours);
    if (!std.mem.eql(u8, theirs, ours)) {
        std.debug.print("git apply {any}: exit {d}\n{s}\npatch:\n{s}\n", .{ args, captured.code, captured.stderr, patch });
    }
    try std.testing.expectEqualStrings(theirs, ours);
}

/// Put both repositories back at `base`, clean.
fn reset(p: *Pair, io: Io) !void {
    try p.both(io, &.{ "reset", "-q", "--hard", "base" });
    try p.both(io, &.{ "clean", "-q", "-f", "-d", "-x" });
}

const lines_a = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\nlambda\nmu\nnu\nxi\nomicron\npi\nrho\nsigma\ntau\nupsilon\n";

fn setupBase(p: *Pair, io: Io) !void {
    try p.write(io, "a.txt", lines_a);
    try p.write(io, "b.txt", "one\ntwo\nthree\n");
    try p.write(io, "dir/c.txt", "c1\nc2\nc3\nc4\nc5\nc6\n");
    try p.write(io, "run.sh", "#!/bin/sh\necho hi\n");
    try p.write(io, "bin.dat", "\x00\x01\x02binary\x00" ** 30);
    try p.both(io, &.{ "add", "-A" });
    try p.both(io, &.{ "commit", "-q", "-m", "base" });
    try p.both(io, &.{ "tag", "base" });
}

/// A patch git makes from the base to what `change` leaves, with `args`
/// for its `diff`; both sides are put back at the base afterwards.
fn makePatch(p: *Pair, io: Io, diff_args: []const []const u8, change: *const fn (*Pair, Io) anyerror!void) ![]u8 {
    try change(p, io);
    try p.git.exec(io, &.{ "add", "-A" });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(p.gpa);
    try argv.appendSlice(p.gpa, &.{ "diff", "--cached" });
    try argv.appendSlice(p.gpa, diff_args);
    try argv.append(p.gpa, "base");
    const patch = try p.git.run(io, argv.items);
    try reset(p, io);
    return patch;
}

fn changeMany(p: *Pair, io: Io) !void {
    const r = &p.git;
    try r.writeFile(io, "a.txt", "ALPHA\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\nIOTA\nkappa\nlambda\nmu\nnu\nxi\nomicron\npi\nrho\nsigma\ntau\nupsilon\nphi\n");
    try r.writeFile(io, "new/file.txt", "created\n");
    try r.dir.deleteFile(io, "b.txt");
    try r.exec(io, &.{ "mv", "dir/c.txt", "dir/moved.txt" });
    try r.writeFile(io, "dir/moved.txt", "c1\nc2\nc3\nC4\nc5\nc6\n");
    try r.exec(io, &.{ "update-index", "--chmod=+x", "run.sh" });
    try r.writeFile(io, "bin.dat", "\x00\x01\x02binary\x00" ** 29 ++ "\x00changed!");
}

test "a patch with every kind of change applies as git applies it, to the working tree, the index or the index alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try setupBase(&p, io);
    const patch = try makePatch(&p, io, &.{ "-M", "--binary" }, changeMany);
    defer gpa.free(patch);
    try compare(&p, io, patch, &.{}, .{});
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--index"}, .{ .target = .index });
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--cached"}, .{ .target = .cached });
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--check"}, .{ .check = true });
    // applied, then taken back out with -R
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--index"}, .{ .target = .index });
    try compare(&p, io, patch, &.{ "-R", "--index" }, .{ .target = .index, .reverse = true });
}

fn shiftA(p: *Pair, io: Io) !void {
    const shifted = "added 1\nadded 2\nadded 3\n" ++ lines_a;
    try p.write(io, "a.txt", shifted);
}

fn changeA(p: *Pair, io: Io) !void {
    try p.git.writeFile(io, "a.txt", "alpha\nbeta\ngamma\nDELTA\nepsilon\nzeta\neta\ntheta\niota\nkappa\nlambda\nmu\nNU\nxi\nomicron\npi\nrho\nsigma\ntau\nupsilon\n");
}

test "a hunk that moved is found at its offset, and one whose context changed is rejected into a .rej as git rejects it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try setupBase(&p, io);
    const patch = try makePatch(&p, io, &.{}, changeA);
    defer gpa.free(patch);

    try shiftA(&p, io);
    try compare(&p, io, patch, &.{}, .{});

    // the second hunk's context is gone: refused whole, or rejected alone
    try reset(&p, io);
    const broken = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\nLAMBDA\nMU\nnu\nXI\nomicron\npi\nrho\nsigma\ntau\nupsilon\n";
    try p.write(io, "a.txt", broken);
    try compare(&p, io, patch, &.{}, .{});
    try compare(&p, io, patch, &.{"--reject"}, .{ .reject = true });

    // with one line of context required, a reduced context still fits
    try reset(&p, io);
    const near = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\nlambda\nmu\nnu\nxi\nomicron\nPI\nrho\nsigma\ntau\nupsilon\n";
    try p.write(io, "a.txt", near);
    try compare(&p, io, patch, &.{"-C1"}, .{ .min_context = 1 });
    try reset(&p, io);
    try p.write(io, "a.txt", near);
    try compare(&p, io, patch, &.{"-C3"}, .{ .min_context = 3 });
}

test "a patch that does not apply falls back to a three-way merge with git's stages and markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try setupBase(&p, io);
    const patch = try makePatch(&p, io, &.{}, changeA);
    defer gpa.free(patch);
    // ours changed the same line: a conflict
    try p.write(io, "a.txt", "alpha\nbeta\ngamma\nDelta-ours\nepsilon\nzeta\neta\ntheta\niota\nkappa\nlambda\nmu\nnu\nxi\nomicron\npi\nrho\nsigma\ntau\nupsilon\n");
    try p.both(io, &.{ "add", "a.txt" });
    try compare(&p, io, patch, &.{"--3way"}, .{ .three_way = true });
    // ours changed a line the patch's context needs: merged cleanly
    try reset(&p, io);
    try p.write(io, "a.txt", "alpha\nbeta\nGAMMA\ndelta\nepsilon\nZETA\neta\ntheta\niota\nkappa\nlambda\nmu\nnu\nxi\nomicron\npi\nrho\nsigma\ntau\nupsilon\n");
    try p.both(io, &.{ "add", "a.txt" });
    try compare(&p, io, patch, &.{"--3way"}, .{ .three_way = true });
    try reset(&p, io);
    try p.write(io, "a.txt", "alpha\nbeta\ngamma\nDelta-ours\nepsilon\nzeta\neta\ntheta\niota\nkappa\nlambda\nmu\nnu\nxi\nomicron\npi\nrho\nsigma\ntau\nupsilon\n");
    try p.both(io, &.{ "add", "a.txt" });
    try compare(&p, io, patch, &.{ "--3way", "--theirs" }, .{ .three_way = true, .favor = .theirs });
}

test "whitespace errors are warned of, refused or fixed, and changed whitespace in the context is overlooked when asked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try setupBase(&p, io);
    const patch = "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,3 +1,5 @@\n one\n+trailing   \n+ \tspace before tab\n two\n three\n";
    try compare(&p, io, patch, &.{}, .{});
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--whitespace=fix"}, .{ .whitespace = .fix });
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--whitespace=error"}, .{ .whitespace = .@"error" });
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--whitespace=nowarn"}, .{ .whitespace = .nowarn });
    // the file's context has different spacing from the patch's
    try reset(&p, io);
    try p.write(io, "b.txt", "one  \ntwo\nthree\n");
    try compare(&p, io, patch, &.{}, .{});
    try compare(&p, io, patch, &.{"--ignore-space-change"}, .{ .ignore_space_change = true });
}

test "traditional patches, strip counts, directories, limits and an empty input are read as git reads them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try setupBase(&p, io);
    const traditional = "--- b.txt.orig\t2024-01-01 00:00:00.000000000 +0000\n+++ b.txt\t2024-01-01 00:00:01.000000000 +0000\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n";
    try compare(&p, io, traditional, &.{}, .{});
    try reset(&p, io);
    const deep = "--- x/y/dir/c.txt\n+++ x/y/dir/c.txt\n@@ -1,2 +1,2 @@\n-c1\n+C1\n c2\n";
    try compare(&p, io, deep, &.{"-p3"}, .{ .strip = 3 });
    try reset(&p, io);
    const plain = "diff --git a/c.txt b/c.txt\n--- a/c.txt\n+++ b/c.txt\n@@ -1,2 +1,2 @@\n-c1\n+C1\n c2\n";
    try compare(&p, io, plain, &.{"--directory=dir"}, .{ .directory = "dir" });
    try reset(&p, io);
    try compare(&p, io, plain, &.{ "--directory=dir", "--exclude=dir/*" }, .{ .directory = "dir", .limits = &.{.{ .pattern = "dir/*", .include = false }} });
    try reset(&p, io);
    try compare(&p, io, "nothing here\n", &.{}, .{});
    try compare(&p, io, "nothing here\n", &.{"--allow-empty"}, .{ .allow_empty = true });
    try reset(&p, io);
    const zero = "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -2,0 +3 @@ two\n+inserted\n";
    try compare(&p, io, zero, &.{"--unidiff-zero"}, .{ .unidiff_zero = true });
    try reset(&p, io);
    const miscounted = "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,9 +1,9 @@\n one\n-two\n+TWO\n three\n";
    try compare(&p, io, miscounted, &.{"--recount"}, .{ .recount = true });
}

test "a corrupt patch is refused by name and changes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try setupBase(&p, io);
    try compare(&p, io, "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n", &.{}, .{});
    try compare(&p, io, "@@ -1 +1 @@\n-one\n+ONE\n", &.{}, .{});
    try compare(&p, io, "diff --git a/b.txt b/b.txt\nindex 1111111..2222222 100644\n", &.{}, .{});
}

/// A random edit of `lines`: lines changed, removed and added.
fn randomEdit(gpa: Allocator, random: std.Random, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines) |line| {
        const roll = random.uintLessThan(u8, 10);
        switch (roll) {
            0 => {}, // removed
            1 => try out.print(gpa, "{s} changed\n", .{line}),
            2 => {
                try out.print(gpa, "{s}\n", .{line});
                try out.print(gpa, "inserted {d}\n", .{random.int(u16)});
            },
            else => try out.print(gpa, "{s}\n", .{line}),
        }
    }
    return out.toOwnedSlice(gpa);
}

fn randomFile(gpa: Allocator, random: std.Random, words: []const []const u8) ![][]const u8 {
    const n = 4 + random.uintLessThan(usize, 30);
    const lines = try gpa.alloc([]const u8, n);
    for (lines) |*l| l.* = words[random.uintLessThan(usize, words.len)];
    return lines;
}

fn joinLines(gpa: Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| try out.print(gpa, "{s}\n", .{l});
    return out.toOwnedSlice(gpa);
}

test "git apply and relic leave the same tree, index and rejects over generated patches and drifted targets, first batch" {
    try corpus(0, 5);
}

test "git apply and relic leave the same tree, index and rejects over generated patches and drifted targets, second batch" {
    try corpus(5, 10);
}

test "git apply and relic leave the same tree, index and rejects over generated patches and drifted targets, third batch" {
    try corpus(10, 15);
}

fn corpus(first: u64, end: u64) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const words = [_][]const u8{ "{", "}", "", "return x;", "int a = 1;", "if (y) {", "  z();", "\tz();", "/* note */", "end", "begin", "trailing  ", " \tmixed", "        eight" };
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    var seed: u64 = first;
    while (seed < end) : (seed += 1) {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // a fresh base each seed, on top of the last
        const names = [_][]const u8{ "f0.c", "f1.c", "sub/f2.c" };
        var bases: [names.len][][]const u8 = undefined;
        for (names, 0..) |name, i| {
            bases[i] = try randomFile(a, random, &words);
            try p.write(io, name, try joinLines(a, bases[i]));
        }
        try p.both(io, &.{ "add", "-A" });
        try p.both(io, &.{ "commit", "-q", "--allow-empty", "-m", "seed" });
        try p.both(io, &.{ "tag", "-f", "base" });
        // the change the patch carries
        for (names, 0..) |name, i| try p.git.writeFile(io, name, try randomEdit(a, random, bases[i]));
        try p.git.exec(io, &.{ "add", "-A" });
        const contexts = [_][]const u8{ "-U0", "-U1", "-U3" };
        const context = contexts[random.uintLessThan(usize, 3)];
        const patch = try p.git.run(io, &.{ "diff", "--cached", context, "base" });
        defer gpa.free(patch);
        try reset(&p, io);
        const variants = [_]struct { args: []const []const u8, options: apply_mod.Options, drift: bool }{
            .{ .args = &.{}, .options = .{}, .drift = false },
            .{ .args = &.{}, .options = .{}, .drift = true },
            .{ .args = &.{"--reject"}, .options = .{ .reject = true }, .drift = true },
            .{ .args = &.{"--index"}, .options = .{ .target = .index }, .drift = false },
            .{ .args = &.{"-C1"}, .options = .{ .min_context = 1 }, .drift = true },
            .{ .args = &.{"--3way"}, .options = .{ .three_way = true }, .drift = true },
            .{ .args = &.{"--whitespace=fix"}, .options = .{ .whitespace = .fix }, .drift = true },
            .{ .args = &.{"--ignore-whitespace"}, .options = .{ .ignore_space_change = true }, .drift = true },
            .{ .args = &.{ "-R", "--reject" }, .options = .{ .reverse = true, .reject = true }, .drift = true },
            .{ .args = &.{"--cached"}, .options = .{ .target = .cached }, .drift = true },
        };
        for (variants) |v| {
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(a, v.args);
            var options = v.options;
            if (std.mem.eql(u8, context, "-U0")) {
                try args.append(a, "--unidiff-zero");
                options.unidiff_zero = true;
            }
            if (v.drift) {
                // the target moved on: lines added at the top, one line
                // somewhere changed
                for (names, 0..) |name, i| {
                    var drifted: std.ArrayList(u8) = .empty;
                    const extra = random.uintLessThan(usize, 4);
                    for (0..extra) |k| try drifted.print(a, "drift {d}\n", .{k});
                    const touch = random.uintLessThan(usize, bases[i].len + 4);
                    for (bases[i], 0..) |l, k| {
                        if (k == touch) {
                            try drifted.print(a, "{s} drifted\n", .{l});
                        } else if (k == touch + 1 and random.boolean()) {
                            // the same line with its spacing changed
                            try drifted.print(a, " {s}\t\n", .{l});
                        } else try drifted.print(a, "{s}\n", .{l});
                    }
                    try p.write(io, name, drifted.items);
                }
                if (v.options.three_way or v.options.target == .cached) try p.both(io, &.{ "add", "-A" });
            }
            compare(&p, io, patch, args.items, options) catch |err| {
                std.debug.print("seed {d}, variant {any}\n", .{ seed, v.args });
                return err;
            };
            try reset(&p, io);
        }
    }
}

fn changeModesAndLinks(p: *Pair, io: Io) !void {
    const r = &p.git;
    try r.exec(io, &.{ "update-index", "--chmod=+x", "b.txt" });
    try r.dir.symLink(io, "a.txt", "link", .{});
    try r.exec(io, &.{ "add", "link" });
    try r.writeFile(io, "copy.txt", lines_a ++ "copied tail\n");
}

test "mode changes, symlinks and copies apply as git applies them" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try setupBase(&p, io);
    const patch = try makePatch(&p, io, &.{ "-C", "--find-copies-harder" }, changeModesAndLinks);
    defer gpa.free(patch);
    try std.testing.expect(std.mem.find(u8, patch, "copy from a.txt") != null);
    try compare(&p, io, patch, &.{}, .{});
    try reset(&p, io);
    try compare(&p, io, patch, &.{"--index"}, .{ .target = .index });
    try compare(&p, io, patch, &.{ "-R", "--index" }, .{ .target = .index, .reverse = true });
}

/// Apply `patch` on both sides and require both to refuse it, both
/// repositories to be left alike, and what lies past the link untouched.
fn expectBothRefuse(p: *Pair, io: Io, patch: []const u8) !void {
    const gpa = p.gpa;
    var git_dir = try p.git.gitDir(io);
    defer git_dir.close(io);
    try git_dir.writeFile(io, .{ .sub_path = "relic-test.patch", .data = patch });
    var captured = try p.git.capture(io, &.{ "apply", ".git/relic-test.patch" });
    defer captured.deinit(gpa);
    try git_dir.deleteFile(io, "relic-test.patch");
    if (captured.code == 0) {
        std.debug.print("git applied a patch it should refuse:\n{s}\n", .{patch});
        return error.TestUnexpectedResult;
    }
    var repo = try Repository.open(gpa, io, p.ours.dir, .{});
    defer repo.deinit(io);
    if (apply_mod.apply(gpa, io, &repo, patch, .{})) |outcome_const| {
        var outcome = outcome_const;
        outcome.deinit();
        std.debug.print("relic applied a patch git refuses ({s}):\n{s}\n", .{ captured.stderr, patch });
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }
    const theirs = try snapshot(gpa, io, &p.git);
    defer gpa.free(theirs);
    const ours = try snapshot(gpa, io, &p.ours);
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
    for ([_]*testgit.Repo{ &p.git, &p.ours }) |r| {
        const secret = try r.readFile(io, ".git/outside/secret");
        defer gpa.free(secret);
        try std.testing.expectEqualStrings("secret\n", secret);
    }
}

test "a patch that reads, removes or writes past a symbolic link, or names an invalid path, is refused as git refuses it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    // The link points out of the working tree, at a directory git does not
    // track: what a hostile history would point at `..` or `/`.
    for ([_]*testgit.Repo{ &p.git, &p.ours }) |r| {
        try r.writeFile(io, ".git/outside/secret", "secret\n");
        try r.dir.symLink(io, ".git/outside", "link", .{});
    }
    try p.write(io, "b.txt", "one\n");
    try p.both(io, &.{ "add", "-A" });
    try p.both(io, &.{ "commit", "-q", "-m", "base" });
    try p.both(io, &.{ "tag", "base" });

    const patches = [_][]const u8{
        // Read through the link into a tracked file.
        "diff --git a/link/secret b/stolen\nsimilarity index 100%\ncopy from link/secret\ncopy to stolen\n",
        "diff --git a/link/secret b/stolen\nsimilarity index 100%\nrename from link/secret\nrename to stolen\n",
        // Remove what the link points at.
        "diff --git a/link/secret b/link/secret\ndeleted file mode 100644\n--- a/link/secret\n+++ /dev/null\n@@ -1 +0,0 @@\n-secret\n",
        // Write through it.
        "diff --git a/link/secret b/link/secret\n--- a/link/secret\n+++ b/link/secret\n@@ -1 +1 @@\n-secret\n+changed\n",
        // A link the patch makes, then a file written through it.
        "diff --git a/l2 b/l2\nnew file mode 120000\n--- /dev/null\n+++ b/l2\n@@ -0,0 +1 @@\n+.git/outside\n\\ No newline at end of file\n" ++
            "diff --git a/l2/secret b/l2/secret\n--- a/l2/secret\n+++ b/l2/secret\n@@ -1 +1 @@\n-secret\n+changed\n",
        // Names no working tree may hold.
        "diff --git a/../escape b/../escape\nnew file mode 100644\n--- /dev/null\n+++ b/../escape\n@@ -0,0 +1 @@\n+x\n",
        "diff --git a/.git/config b/.git/config\nnew file mode 100644\n--- /dev/null\n+++ b/.git/config\n@@ -0,0 +1 @@\n+x\n",
        // A `.gitmodules` that is a link, in two spellings.
        "diff --git a/.gitmodules b/.gitmodules\nnew file mode 120000\n--- /dev/null\n+++ b/.gitmodules\n@@ -0,0 +1 @@\n+/etc/passwd\n\\ No newline at end of file\n",
        "diff --git a/sub/.GITMODULES b/sub/.GITMODULES\nnew file mode 120000\n--- /dev/null\n+++ b/sub/.GITMODULES\n@@ -0,0 +1 @@\n+/etc/passwd\n\\ No newline at end of file\n",
    };
    for (patches) |patch| {
        try expectBothRefuse(&p, io, patch);
        try reset(&p, io);
    }
    // A `.gitmodules` that is a file is anyone's to add.
    try compare(&p, io, "diff --git a/.gitmodules b/.gitmodules\nnew file mode 100644\n--- /dev/null\n+++ b/.gitmodules\n@@ -0,0 +1 @@\n+x\n", &.{}, .{});
}

test "line endings, the whitespace attribute, intent to add, no-add and include are honoured as git honours them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var p = try Pair.init(gpa, io);
    defer p.deinit();
    try p.write(io, ".gitattributes", "*.crlf text eol=crlf\n*.loose whitespace=-trailing-space\n");
    try p.write(io, "w.crlf", "one\r\ntwo\r\nthree\r\n");
    try p.write(io, "x.loose", "a\nb\n");
    try p.write(io, "b.txt", "one\ntwo\nthree\n");
    try p.both(io, &.{ "add", "-A" });
    try p.both(io, &.{ "commit", "-q", "-m", "base" });
    try p.both(io, &.{ "tag", "base" });
    try p.both(io, &.{ "checkout", "-q", "--", "." });
    const crlf = "diff --git a/w.crlf b/w.crlf\n--- a/w.crlf\n+++ b/w.crlf\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n";
    try compare(&p, io, crlf, &.{}, .{});
    try reset(&p, io);
    try compare(&p, io, crlf, &.{"--index"}, .{ .target = .index });
    try reset(&p, io);
    const loose = "diff --git a/x.loose b/x.loose\n--- a/x.loose\n+++ b/x.loose\n@@ -1,2 +1,3 @@\n a\n+trail   \n b\n";
    try compare(&p, io, loose, &.{"--whitespace=error"}, .{ .whitespace = .@"error" });
    try reset(&p, io);
    const create = "diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+new\n";
    try compare(&p, io, create, &.{"-N"}, .{ .intent_to_add = true });
    try reset(&p, io);
    const mixed = "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n" ++ create;
    try compare(&p, io, mixed, &.{"--no-add"}, .{ .no_add = true });
    try reset(&p, io);
    try compare(&p, io, mixed, &.{"--include=n.*"}, .{ .limits = &.{.{ .pattern = "n.*", .include = true }} });
    try reset(&p, io);
    const no_eol = "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,3 +1,3 @@\n one\n two\n-three\n+three\n\\ No newline at end of file\n";
    try compare(&p, io, no_eol, &.{}, .{});
    try compare(&p, io, no_eol, &.{"-R"}, .{ .reverse = true });
    try reset(&p, io);
    try compare(&p, io, no_eol, &.{"--inaccurate-eof"}, .{ .inaccurate_eof = true });
}
