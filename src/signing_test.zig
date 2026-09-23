//! Signatures against git's, in both directions, with real keys.
//!
//! The keys are made for each test in its own temporary directory: an SSH
//! key by `ssh-keygen`, and an OpenPGP key by `gpg` in a `GNUPGHOME` of its
//! own. The environment every program runs in is built from nothing but
//! `PATH` and that directory, so neither the person's `~/.gnupg` nor
//! `~/.ssh` nor any agent they run is reached. A machine without the
//! program skips the test.
//!
//! What is proven: git's `verify-commit` and `verify-tag`, and its `%G?`,
//! accept what is signed here; and the verdicts read here from git's
//! signatures, and from a tampered object and an unknown key, are the
//! letters git prints for them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const testgit = @import("testgit.zig");
const signing = @import("signing.zig");
const object = @import("object.zig");
const hash = @import("hash.zig");
const repo_mod = @import("repo.zig");
const commit_mod = @import("commit.zig");
const Repository = repo_mod.Repository;
const Oid = hash.Oid;

const who: object.Signature = .{
    .name = "Fixture",
    .email = "fixture@example.com",
    .when_secs = 1_700_000_000,
    .offset_minutes = 0,
};

/// A repository with a key, and the environment its programs run in.
const Keyed = struct {
    gpa: Allocator,
    repo: testgit.Repo,
    environ: std.process.Environ.Map,
    /// The absolute path of the directory the keys are in.
    home: []const u8,
    format: signing.Format,

    fn init(gpa: Allocator, io: Io, format: signing.Format, init_args: []const []const u8) !*Keyed {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const k = try gpa.create(Keyed);
        errdefer gpa.destroy(k);
        k.gpa = gpa;
        k.format = format;
        k.repo = try testgit.Repo.init(gpa, io, init_args);
        errdefer k.repo.deinit();
        try k.repo.dir.createDir(io, "keys", .default_dir);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const top = buf[0..try k.repo.dir.realPath(io, &buf)];
        k.home = try std.fs.path.join(gpa, &.{ top, "keys" });
        errdefer gpa.free(k.home);

        // Nothing from this process's environment but `PATH`: no agent, no
        // home, no `GNUPGHOME` of the person's.
        k.environ = .init(gpa);
        errdefer k.environ.deinit();
        const path = testing.environ.getAlloc(gpa, "PATH") catch return error.SkipZigTest;
        defer gpa.free(path);
        try k.environ.put("PATH", path);
        try k.environ.put("HOME", k.home);
        try k.environ.put("TMPDIR", k.home);
        const gnupg_home = try std.fs.path.join(gpa, &.{ k.home, "g" });
        defer gpa.free(gnupg_home);
        try k.environ.put("GNUPGHOME", gnupg_home);
        try k.environ.put("GIT_AUTHOR_DATE", "@1700000000 +0000");
        try k.environ.put("GIT_COMMITTER_DATE", "@1700000000 +0000");
        k.repo.environ = &k.environ;
        return k;
    }

    fn deinit(k: *Keyed, io: Io) void {
        if (k.format != .ssh) {
            // The agent gpg started for this home goes with it.
            _ = k.run(io, &.{ "gpgconf", "--kill", "gpg-agent" }) catch {};
        }
        k.repo.deinit();
        k.environ.deinit();
        k.gpa.free(k.home);
        k.gpa.destroy(k);
    }

    /// Run a program in the keyed environment; `error.SkipZigTest` when it
    /// is not installed.
    fn run(k: *Keyed, io: Io, argv: []const []const u8) ![]u8 {
        const result = std.process.run(k.gpa, io, .{
            .argv = argv,
            .cwd = .{ .dir = k.repo.dir },
            .environ_map = &k.environ,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => |e| return e,
        };
        defer k.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        std.debug.print("{s} failed:\n{s}\n", .{ argv[0], result.stderr });
        k.gpa.free(result.stdout);
        return error.ProgramFailed;
    }

    fn config(k: *Keyed, io: Io, name: []const u8, value: []const u8) !void {
        try k.repo.exec(io, &.{ "config", name, value });
    }

    /// Make a key and point the repository at it.
    fn makeKey(k: *Keyed, io: Io) !void {
        switch (k.format) {
            .ssh => {
                const key = try std.fs.path.join(k.gpa, &.{ k.home, "id" });
                defer k.gpa.free(key);
                k.gpa.free(try k.run(io, &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", key }));
                const public = try k.repo.readFile(io, "keys/id.pub");
                defer k.gpa.free(public);
                const allowed = try std.fmt.allocPrint(k.gpa, "fixture@example.com namespaces=\"git\" {s}", .{public});
                defer k.gpa.free(allowed);
                try k.repo.writeFile(io, "keys/allowed", allowed);
                const allowed_path = try std.fs.path.join(k.gpa, &.{ k.home, "allowed" });
                defer k.gpa.free(allowed_path);
                try k.config(io, "gpg.format", "ssh");
                try k.config(io, "user.signingKey", key);
                try k.config(io, "gpg.ssh.allowedSignersFile", allowed_path);
            },
            .openpgp => {
                const home = k.environ.get("GNUPGHOME").?;
                try Io.Dir.createDirAbsolute(io, home, .fromMode(0o700));
                k.gpa.free(try k.run(io, &.{
                    "gpg",                  "--batch",                       "--quiet", "--passphrase", "",
                    "--quick-generate-key", "Fixture <fixture@example.com>", "ed25519", "sign",         "never",
                }));
            },
            .x509 => unreachable,
        }
        try k.config(io, "commit.gpgSign", "true");
        try k.config(io, "tag.gpgSign", "true");
    }

    fn open(k: *Keyed, io: Io) !Repository {
        return Repository.open(k.gpa, io, k.repo.dir, .{});
    }

    fn programs(k: *Keyed) @import("program.zig").Programs {
        return .{ .environ = &k.environ };
    }

    fn letter(k: *Keyed, io: Io, rev: []const u8) !u8 {
        const out = try k.repo.line(io, &.{ "log", "-1", "--format=%G?", rev });
        defer k.gpa.free(out);
        return out[0];
    }
};

fn relicCommit(k: *Keyed, io: Io, tree_from: []const u8) !Oid {
    var repo = try k.open(io);
    defer repo.deinit(io);
    const tree_text = try k.repo.line(io, &.{ "rev-parse", tree_from });
    defer k.gpa.free(tree_text);
    return repo.writeCommit(io, .{
        .tree = try Oid.parse(repo.kind, tree_text),
        .author = who,
        .committer = who,
        .message = "signed here\n",
        .signing = .{ .programs = k.programs() },
    });
}

fn verifyHere(k: *Keyed, io: Io, rev: []const u8, tag: bool) !signing.Verdict {
    var repo = try k.open(io);
    defer repo.deinit(io);
    const text = try k.repo.line(io, &.{ "rev-parse", rev });
    defer k.gpa.free(text);
    const found = try repo.odb.read(io, try Oid.parse(repo.kind, text));
    defer k.gpa.free(found.bytes);
    var signer = try signing.Signer.init(k.gpa, &repo.config, k.programs());
    defer signer.deinit();
    return if (tag)
        signing.verifyTag(&signer, io, repo.kind, found.bytes)
    else
        signing.verifyCommit(&signer, io, repo.kind, found.bytes);
}

fn bothWays(format: signing.Format, init_args: []const []const u8) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var k = try Keyed.init(gpa, io, format, init_args);
    defer k.deinit(io);
    try k.makeKey(io);

    try k.repo.writeFile(io, "a.txt", "a\n");
    try k.repo.exec(io, &.{ "add", "a.txt" });
    // The fixture settings turn signing off for git; these turn it on.
    try k.repo.exec(io, &.{ "-c", "commit.gpgSign=true", "commit", "-q", "-m", "signed by git" });

    // git accepts what is signed here.
    const mine = try relicCommit(k, io, "HEAD^{tree}");
    var hex: [hash.max_hex_len]u8 = undefined;
    const mine_hex = mine.hex(&hex);
    try k.repo.exec(io, &.{ "verify-commit", mine_hex });
    try testing.expectEqual(@as(u8, 'G'), try k.letter(io, mine_hex));
    const raw = try k.repo.run(io, &.{ "cat-file", "commit", mine_hex });
    defer gpa.free(raw);

    // And this accepts what git signed, with git's letter.
    var theirs = try verifyHere(k, io, "HEAD", false);
    defer theirs.deinit();
    try testing.expectEqual(try k.letter(io, "HEAD"), theirs.letter());
    try testing.expect(theirs.verified(.undefined));
    var own = try verifyHere(k, io, mine_hex, false);
    defer own.deinit();
    try testing.expectEqual(@as(u8, 'G'), own.letter());

    // Tags, both ways.
    {
        var repo = try k.open(io);
        defer repo.deinit(io);
        const tag = try repo.writeTagWith(io, .{
            .target = mine,
            .target_type = .commit,
            .name = "v-relic",
            .tagger = who,
            .message = "tagged here\n",
        }, .{ .programs = k.programs() });
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        try tx.create("refs/tags/v-relic", .{ .direct = tag });
        try tx.commit(io, null);
    }
    try k.repo.exec(io, &.{ "verify-tag", "v-relic" });
    try k.repo.exec(io, &.{ "-c", "tag.gpgSign=true", "tag", "-m", "tagged by git", "v-git" });
    var tagged = try verifyHere(k, io, "v-git", true);
    defer tagged.deinit();
    try testing.expectEqual(@as(u8, 'G'), tagged.letter());
    try testing.expect(tagged.verified(.undefined));

    // A tampered commit is bad to both.
    const tampered_bytes = try std.mem.replaceOwned(u8, gpa, raw, "signed here", "signed HERE");
    defer gpa.free(tampered_bytes);
    try k.repo.writeFile(io, "keys/tampered", tampered_bytes);
    const tampered = try k.repo.line(io, &.{ "hash-object", "-w", "-t", "commit", "--literally", "keys/tampered" });
    defer gpa.free(tampered);
    var bad = try verifyHere(k, io, tampered, false);
    defer bad.deinit();
    try testing.expectEqual(try k.letter(io, tampered), bad.letter());
    try testing.expectEqual(@as(u8, 'B'), bad.letter());
    try testing.expect(!bad.verified(.undefined));
}

test "ssh signatures made here verify in git, and git's verify here" {
    try bothWays(.ssh, &.{});
}

test "ssh signatures in a SHA-256 repository ride in gpgsig-sha256" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var k = try Keyed.init(gpa, io, .ssh, &.{"--object-format=sha256"});
    defer k.deinit(io);
    try k.makeKey(io);
    try k.repo.writeFile(io, "a.txt", "a\n");
    try k.repo.exec(io, &.{ "add", "a.txt" });
    const tree = try k.repo.line(io, &.{"write-tree"});
    defer gpa.free(tree);
    const mine = try relicCommit(k, io, tree);
    var hex: [hash.max_hex_len]u8 = undefined;
    try k.repo.exec(io, &.{ "verify-commit", mine.hex(&hex) });
    const raw = try k.repo.run(io, &.{ "cat-file", "commit", mine.hex(&hex) });
    defer gpa.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\ngpgsig-sha256 -----BEGIN SSH SIGNATURE-----\n") != null);
}

test "openpgp signatures made here verify in git, and git's verify here" {
    try bothWays(.openpgp, &.{});
}

test "a key no allowed signer names is untrusted to both, and not verified" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var k = try Keyed.init(gpa, io, .ssh, &.{});
    defer k.deinit(io);
    try k.makeKey(io);
    try k.repo.writeFile(io, "a.txt", "a\n");
    try k.repo.exec(io, &.{ "add", "a.txt" });
    try k.repo.exec(io, &.{ "-c", "commit.gpgSign=true", "commit", "-q", "-m", "signed" });
    // Only someone else's key is allowed now.
    const other = try std.fs.path.join(gpa, &.{ k.home, "other" });
    defer gpa.free(other);
    gpa.free(try k.run(io, &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "other", "-f", other }));
    const public = try k.repo.readFile(io, "keys/other.pub");
    defer gpa.free(public);
    const allowed = try std.fmt.allocPrint(gpa, "someone@example.com {s}", .{public});
    defer gpa.free(allowed);
    try k.repo.writeFile(io, "keys/allowed", allowed);
    var verdict = try verifyHere(k, io, "HEAD", false);
    defer verdict.deinit();
    try testing.expectEqual(try k.letter(io, "HEAD"), verdict.letter());
    try testing.expectEqual(@as(u8, 'U'), verdict.letter());
    try testing.expect(!verdict.verified(.undefined));
    k.repo.report_failures = false;
    try testing.expectError(error.GitFailed, k.repo.exec(io, &.{ "verify-commit", "HEAD" }));
}

test "signing configured with no programs is refused by name, never written unsigned" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fixture = try testgit.Repo.init(gpa, io, &.{});
    defer fixture.deinit();
    try fixture.exec(io, &.{ "config", "commit.gpgSign", "true" });
    try fixture.exec(io, &.{ "config", "tag.forceSignAnnotated", "true" });
    var repo = try Repository.open(gpa, io, fixture.dir, .{});
    defer repo.deinit(io);
    const empty = hash.Hasher.object(.sha1, "tree", "");
    try testing.expectError(error.SigningRequiresPrograms, repo.writeCommit(io, .{
        .tree = empty,
        .author = who,
        .committer = who,
        .message = "m\n",
    }));
    try testing.expectEqualStrings("commit.gpgSign", repo.unsupportedSetting());
    try testing.expectError(error.SigningRequiresPrograms, repo.writeTag(io, .{
        .target = empty,
        .target_type = .tree,
        .name = "t",
        .tagger = who,
        .message = "m\n",
    }));
    // Asked not to sign, it writes what it was asked to.
    _ = try repo.writeCommit(io, .{
        .tree = empty,
        .author = who,
        .committer = who,
        .message = "m\n",
        .signing = .{ .sign = .never },
    });
}

test "the commit porcelain signs as commit.gpgSign says" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var k = try Keyed.init(gpa, io, .ssh, &.{});
    defer k.deinit(io);
    try k.makeKey(io);
    try k.repo.writeFile(io, "a.txt", "a\n");
    try k.repo.exec(io, &.{ "add", "a.txt" });
    var repo = try k.open(io);
    defer repo.deinit(io);
    try testing.expectError(error.SigningRequiresPrograms, commit_mod.commit(&repo, io, .{ .author = who, .committer = who, .message = "m" }, .{}));
    _ = try commit_mod.commit(&repo, io, .{ .author = who, .committer = who, .message = "m" }, .{ .signing = .{ .programs = k.programs() } });
    try k.repo.exec(io, &.{ "verify-commit", "HEAD" });
}

test "a signing program is one path, spaces and all, as git runs it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var k = try Keyed.init(gpa, io, .ssh, &.{});
    defer k.deinit(io);
    try k.makeKey(io);
    // A wrapper in a directory whose name a shell would split in two.
    try k.repo.writeFile(io, "keys/my tools/keygen", "#!/bin/sh\necho used >> \"$(dirname \"$0\")/log\"\nexec ssh-keygen \"$@\"\n");
    const wrapper_file = try k.repo.dir.openFile(io, "keys/my tools/keygen", .{});
    try wrapper_file.setPermissions(io, .fromMode(0o755));
    wrapper_file.close(io);
    const wrapper = try std.fs.path.join(gpa, &.{ k.home, "my tools", "keygen" });
    defer gpa.free(wrapper);
    try k.config(io, "gpg.ssh.program", wrapper);

    try k.repo.writeFile(io, "a.txt", "a\n");
    try k.repo.exec(io, &.{ "add", "a.txt" });
    try k.repo.exec(io, &.{ "-c", "commit.gpgSign=true", "commit", "-q", "-m", "signed by git" });
    const mine = try relicCommit(k, io, "HEAD^{tree}");
    var hex: [hash.max_hex_len]u8 = undefined;
    try k.repo.exec(io, &.{ "verify-commit", mine.hex(&hex) });
    var theirs = try verifyHere(k, io, "HEAD", false);
    defer theirs.deinit();
    try testing.expectEqual(@as(u8, 'G'), theirs.letter());

    // git signed, git verified, relic signed and relic verified, each through
    // the wrapper.
    const log = try k.repo.readFile(io, "keys/my tools/log");
    defer gpa.free(log);
    try testing.expect(std.mem.count(u8, log, "used\n") >= 4);
}
