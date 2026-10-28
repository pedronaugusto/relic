//! `format` against `git format-patch`: the same commits, the same options,
//! the same bytes.

const std = @import("std");
const repeat = @import("shakedown").corpus.repeat;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const formatpatch = @import("format.zig");
const apply_mod = @import("apply.zig");
const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const testgit = @import("../testing/git.zig");
const object = @import("../object/object.zig");

const Repository = repo_mod.Repository;
const Oid = hash.Oid;

/// The committer the suite's git commits as, at the epoch: message ids
/// carry the time, which `compare` reads past.
const fixture: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !Oid {
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer gpa.free(text);
    return Oid.parse(.sha1, text);
}

/// A history with most of what a patch can carry: text edits, a creation,
/// a deletion, a rename, a mode change, an empty commit, a long subject, a
/// body with trailing whitespace, and an author whose name is not ASCII.
fn buildHistory(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "a.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n");
    try git.writeFile(io, "dir/b.txt", "bee\n");
    try git.writeFile(io, "old name.txt", "this file is renamed later\nwith enough lines\nto be found\nas a rename\n");
    try git.writeFile(io, "run.sh", "#!/bin/sh\necho run\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });
    try git.exec(io, &.{ "tag", "base" });

    try git.writeFile(io, "a.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "Change a\n\nThe body says why.   \nWith a second line.\n\n\n" });

    try git.writeFile(io, "new.txt", "created\n");
    try git.dir.deleteFile(io, "dir/b.txt");
    try git.exec(io, &.{ "mv", "old name.txt", "new name.txt" });
    try git.exec(io, &.{ "update-index", "--chmod=+x", "run.sh" });
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "A subject long enough that git has to fold it when it writes the Subject header of the mail" });

    try git.exec(io, &.{ "-c", "user.name=J\xc3\xb6rg M\xc3\xbcller", "-c", "user.email=jm@example.com", "commit", "-q", "--allow-empty", "-m", "Empty, from someone else\n\nWith a body that says caf\xc3\xa9.\n" });

    try git.writeFile(io, "a.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "No newline at the end\n\nSigned-off-by: Fixture <fixture@example.com>\n" });
}

/// `error.SkipZigTest` on a git older than the mail this writes: git
/// writes a mail for an empty commit and spells `Message-ID` so since 2.41,
/// counts a quoted name's width in columns rather than bytes and puts
/// `--rfc` before the subject prefix rather than in its place since 2.43.
fn requireTodaysMail(gpa: Allocator, io: Io) !void {
    try testgit.requireGitVersion(gpa, io, 2, 43);
}

/// `git format-patch --stdout <args> <range>` and `format` with
/// `options`, compared byte for byte; message ids' times are git's
/// clock, so they are compared as a placeholder.
fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, repo: *Repository, args: []const []const u8, range_text: []const u8, range: formatpatch.Range, options: formatpatch.Options) !void {
    try requireTodaysMail(gpa, io);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "format-patch", "--stdout" });
    try argv.appendSlice(gpa, args);
    try argv.append(gpa, range_text);
    const theirs_raw = try git.run(io, argv.items);
    defer gpa.free(theirs_raw);
    var series = try formatpatch.format(gpa, io, repo, range, options);
    defer series.deinit();
    var ours_w: Io.Writer.Allocating = .init(gpa);
    defer ours_w.deinit();
    try series.writeMbox(&ours_w.writer);
    const theirs = try normalizeTimes(gpa, theirs_raw);
    defer gpa.free(theirs);
    const ours = try normalizeTimes(gpa, ours_w.written());
    defer gpa.free(ours);
    if (!std.mem.eql(u8, theirs, ours)) std.debug.print("format-patch {any} {s}\n", .{ args, range_text });
    try std.testing.expectEqualStrings(theirs, ours);
}

fn normalizeTimes(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1])) {
            var j = i + 1;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            if (std.mem.startsWith(u8, text[j..], ".git.")) {
                try out.appendSlice(gpa, ".T");
                i = j;
                continue;
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "a series of commits is written as the mails git format-patch writes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const range: formatpatch.Range = .{ .upstream = base, .tip = head };

    try compare(gpa, io, &git, &repo, &.{"--no-signature"}, "base..HEAD", range, .{});
    try compare(gpa, io, &git, &repo, &.{ "--signature=relic test", "-p" }, "base..HEAD", range, .{ .signature = .{ .on = "relic test" }, .stat = false });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "-N", "--subject-prefix=PATCH foo", "--rfc", "-v3" }, "base..HEAD", range, .{ .numbered = false, .subject_prefix = "PATCH foo", .rfc = "RFC", .reroll_count = "3" });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "-k" }, "base..HEAD", range, .{ .keep_subject = true });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--start-number=7", "-n" }, "HEAD~1..HEAD", .{ .upstream = try oidOf(gpa, io, &git, "HEAD~1"), .tip = head }, .{ .start_number = 7, .numbered = true });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "-s", "--zero-commit" }, "base..HEAD", range, .{ .signoff = true, .who = fixture, .zero_commit = true });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--from=Sender Person <sender@example.com>", "--to=a@example.com", "--to=b@example.com", "--cc=c@example.com", "--add-header=X-Extra: yes" }, "base..HEAD", range, .{
        .from = .{ .on = .{ .name = "Sender Person", .email = "sender@example.com" } },
        .to = .{ .given = &.{ "a@example.com", "b@example.com" } },
        .cc = .{ .given = &.{"c@example.com"} },
        .headers = .{ .given = &.{"X-Extra: yes"} },
    });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--no-encode-email-headers" }, "base..HEAD", range, .{ .encode_email_headers = false });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--thread=deep", "--in-reply-to=<start@example.com>" }, "base..HEAD", range, .{ .thread = .deep, .who = fixture, .in_reply_to = "<start@example.com>" });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--thread" }, "base..HEAD", range, .{ .thread = .shallow, .who = fixture });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--attach=BOUNDARY" }, "base..HEAD", range, .{ .attach = .{ .on = .{ .boundary = "BOUNDARY" } } });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--inline=BOUNDARY" }, "base..HEAD", range, .{ .attach = .{ .on = .{ .boundary = "BOUNDARY", .@"inline" = true } } });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "-2" }, "HEAD", .{ .tip = head, .max_count = 2 }, .{});
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--root" }, "HEAD", .{ .tip = head }, .{});
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--base=base" }, "base..HEAD", range, .{ .base = .{ .commit = base } });
}

test "a cover letter is written as git writes one, with its shortlog, its diffstat and the base" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const range: formatpatch.Range = .{ .upstream = base, .tip = head };
    const sender: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--cover-letter" }, "base..HEAD", range, .{ .cover_letter = .on, .cover = .{ .sender = sender } });
    try compare(gpa, io, &git, &repo, &.{ "--signature=sig", "--cover-letter", "--base=base", "--thread" }, "base..HEAD", range, .{
        .cover_letter = .on,
        .cover = .{ .sender = sender },
        .base = .{ .commit = base },
        .signature = .{ .on = "sig" },
        .thread = .shallow,
        .who = fixture,
    });
    // `--commit-list-format` came in 2.54
    if (try testgit.gitAtLeast(gpa, io, 2, 54))
        try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--cover-letter", "--commit-list-format=modern" }, "base..HEAD", range, .{ .cover_letter = .on, .cover = .{ .sender = sender, .format = .modern } });
    try git.exec(io, &.{ "config", "branch.main.description", "The series subject\n\nAnd what it is for." });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--cover-letter", "--cover-from-description=subject", "main" }, "^base", range, .{ .cover_letter = .on, .cover = .{ .sender = sender, .description = "The series subject\n\nAnd what it is for.", .from_description = .subject } });
}

/// `compare` with `settings` in the repository's configuration, each
/// added as `git config --add` adds it and taken out after.
fn compareSet(gpa: Allocator, io: Io, git: *testgit.Repo, settings: []const [2][]const u8, args: []const []const u8, range_text: []const u8, range: formatpatch.Range, options: formatpatch.Options) !void {
    for (settings) |kv| try git.exec(io, &.{ "config", "--add", kv[0], kv[1] });
    defer for (settings) |kv| git.exec(io, &.{ "config", "--unset-all", kv[0] }) catch {}; // glint-ignore: Z026 -- the next case sets what it needs; a key already gone is fine
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    try compare(gpa, io, git, &repo, args, range_text, range, options);
}

test "format-patch takes its format.* settings where the caller leaves them, as git's git_format_config reads them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const range: formatpatch.Range = .{ .upstream = base, .tip = head };
    const one: formatpatch.Range = .{ .upstream = try oidOf(gpa, io, &git, "HEAD~1"), .tip = head };
    const w: formatpatch.Options = .{ .who = fixture };

    try compareSet(gpa, io, &git, &.{ .{ "format.subjectPrefix", "FOO" }, .{ "format.numbered", "true" }, .{ "format.signature", "from the settings" } }, &.{}, "HEAD~1..HEAD", one, w);
    try compareSet(gpa, io, &git, &.{ .{ "format.numbered", "false" }, .{ "format.signature", "sig" } }, &.{"--subject-prefix=BAR"}, "base..HEAD", range, .{ .who = fixture, .subject_prefix = "BAR" });
    // a setting's number is dropped under -k, and its prefix too
    try compareSet(gpa, io, &git, &.{ .{ "format.numbered", "true" }, .{ "format.subjectPrefix", "FOO" } }, &.{ "--no-signature", "-k" }, "base..HEAD", range, .{ .who = fixture, .keep_subject = true, .signature = .off });
    try compareSet(gpa, io, &git, &.{
        .{ "format.to", "a@example.com" },          .{ "format.to", "b@example.com" },
        .{ "format.cc", "c@example.com" },          .{ "format.headers", "X-One: 1\n" },
        .{ "format.headers", "Cc: d@example.com" }, .{ "format.headers", "to: e@example.com" },
    }, &.{ "--no-signature", "--to=f@example.com" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .to = .{ .given = &.{"f@example.com"} } });
    try compareSet(gpa, io, &git, &.{ .{ "format.to", "a@example.com" }, .{ "format.cc", "c@example.com" }, .{ "format.headers", "X-One: 1" } }, &.{ "--no-signature", "--no-to", "--cc=g@example.com" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .to = .{ .settings = false }, .cc = .{ .given = &.{"g@example.com"} } });
    try compareSet(gpa, io, &git, &.{ .{ "format.to", "a@example.com" }, .{ "format.headers", "X-One: 1" } }, &.{ "--no-signature", "--no-add-header" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .headers = .{ .settings = false } });
    try compareSet(gpa, io, &git, &.{ .{ "format.encodeEmailHeaders", "false" }, .{ "format.signOff", "true" }, .{ "format.thread", "deep" }, .{ "format.signature", "" } }, &.{}, "base..HEAD", range, w);
    try compareSet(gpa, io, &git, &.{ .{ "format.thread", "true" }, .{ "format.from", "Sender Person <sender@example.com>" }, .{ "format.forceInBodyFrom", "true" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    // git takes the committer's identity when it reads `format.from`, so
    // the identity is set before it: the harness's `-c` comes too late.
    try compareSet(gpa, io, &git, &.{ .{ "user.name", "Fixture" }, .{ "user.email", "fixture@example.com" }, .{ "format.from", "true" }, .{ "format.thread", "shallow" }, .{ "format.thread", "false" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{ .{ "format.attach", "BOUNDARY" }, .{ "format.mboxrd", "true" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{.{ "format.attach", "BOUNDARY" }}, &.{ "--no-signature", "--no-attach" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .attach = .off });
    try compareSet(gpa, io, &git, &.{ .{ "diff.statGraphWidth", "5" }, .{ "diff.statNameWidth", "8" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    // format-patch takes `format.noPrefix` and not `diff.noPrefix`
    try compareSet(gpa, io, &git, &.{.{ "format.noprefix", "true" }}, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{.{ "diff.noprefix", "true" }}, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{ .{ "format.noprefix", "true" }, .{ "diff.srcPrefix", "x/" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });

    // the cover letter: on, or only for more than one patch, as listed
    try compareSet(gpa, io, &git, &.{ .{ "format.coverLetter", "auto" }, .{ "format.commitListFormat", "modern" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{.{ "format.coverLetter", "auto" }}, &.{"--no-signature"}, "HEAD~1..HEAD", one, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{ .{ "format.coverLetter", "true" }, .{ "format.commitListFormat", "log:[%(count)/%(total)] %s (%an)" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{ .{ "format.coverLetter", "true" }, .{ "format.commitListFormat", "%w(30,2,4)%(count). %s%w(0,0,0) <%h>" } }, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{.{ "format.coverLetter", "true" }}, &.{ "--no-signature", "--no-cover-letter" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .cover_letter = .off });
}

test "format.signatureFile, format.useAutoBase and format.outputDirectory are read as git reads them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const range: formatpatch.Range = .{ .upstream = base, .tip = head };

    try git.writeFile(io, "sig.txt", "a signature\nfrom a file\n");
    const sig_path = try git.dir.realPathFileAlloc(io, "sig.txt", gpa);
    defer gpa.free(sig_path);
    try compareSet(gpa, io, &git, &.{.{ "format.signatureFile", sig_path }}, &.{}, "base..HEAD", range, .{ .who = fixture });
    // format.signature wins over the file, whatever their order
    try compareSet(gpa, io, &git, &.{ .{ "format.signature", "inline" }, .{ "format.signatureFile", sig_path } }, &.{}, "base..HEAD", range, .{ .who = fixture });

    // whenAble with no upstream: no base; with one: the merge base
    try compareSet(gpa, io, &git, &.{.{ "format.useAutoBase", "whenAble" }}, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try git.exec(io, &.{ "branch", "upstream", "base" });
    try git.exec(io, &.{ "branch", "--set-upstream-to=upstream" });
    try compareSet(gpa, io, &git, &.{.{ "format.useAutoBase", "true" }}, &.{"--no-signature"}, "base..HEAD", range, .{ .who = fixture, .signature = .off });
    try compareSet(gpa, io, &git, &.{.{ "format.useAutoBase", "true" }}, &.{ "--no-signature", "--no-base" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .base = .off });

    try git.exec(io, &.{ "config", "format.outputDirectory", "patches" });
    defer git.exec(io, &.{ "config", "--unset", "format.outputDirectory" }) catch {}; // glint-ignore: Z026 -- the next case sets what it needs; a key already gone is fine
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var series = try formatpatch.format(gpa, io, &repo, range, .{ .who = fixture });
    defer series.deinit();
    try std.testing.expectEqualStrings("patches", series.directory);
    var given = try formatpatch.format(gpa, io, &repo, range, .{ .who = fixture, .output_directory = "elsewhere" });
    defer given.deinit();
    try std.testing.expectEqualStrings("elsewhere", given.directory);
    // what git writes there, the names relic gives
    const names = try git.run(io, &.{ "format-patch", "--no-signature", "base..HEAD" });
    defer gpa.free(names);
    var ours: std.ArrayList(u8) = .empty;
    defer ours.deinit(gpa);
    for (series.mails) |m| try ours.print(gpa, "{s}/{s}\n", .{ series.directory, m.name });
    try std.testing.expectEqualStrings(names, ours.items);
}

test "a setting that needs the committer asks for one, and bad format.* values are refused where git dies" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    const range: formatpatch.Range = .{ .upstream = try oidOf(gpa, io, &git, "base"), .tip = try oidOf(gpa, io, &git, "HEAD") };
    for ([_][2][]const u8{
        .{ "format.signOff", "true" }, .{ "format.thread", "true" }, .{ "format.coverLetter", "true" }, .{ "format.from", "yes" },
    }) |kv| {
        try git.exec(io, &.{ "config", kv[0], kv[1] });
        defer git.exec(io, &.{ "config", "--unset", kv[0] }) catch {}; // glint-ignore: Z026 -- the next case sets what it needs; a key already gone is fine
        var repo = try Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        try std.testing.expectError(error.NoIdentity, formatpatch.format(gpa, io, &repo, range, .{}));
    }
    for ([_][2][]const u8{
        .{ "format.numbered", "maybe" },         .{ "format.thread", "sideways" },
        .{ "format.filenameMaxLength", "long" }, .{ "format.coverFromDescription", "all" },
        .{ "format.from", "Nobody" },            .{ "format.useAutoBase", "sometimes" },
    }) |kv| {
        try git.exec(io, &.{ "config", kv[0], kv[1] });
        defer git.exec(io, &.{ "config", "--unset", kv[0] }) catch {}; // glint-ignore: Z026 -- the next case sets what it needs; a key already gone is fine
        // git dies on each
        git.report_failures = false;
        try std.testing.expectError(error.GitFailed, git.exec(io, &.{ "format-patch", "--stdout", "base..HEAD" }));
        git.report_failures = true;
        var repo = try Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        try std.testing.expectError(error.InvalidFormatSetting, formatpatch.format(gpa, io, &repo, range, .{ .who = fixture }));
    }
}

test "the files format-patch -o writes are named as git names them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try requireTodaysMail(gpa, io);
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const names = try git.run(io, &.{ "format-patch", "-o", "out", "--no-signature", "--cover-letter", "-v2", "--filename-max-length=30", "base..HEAD" });
    defer gpa.free(names);
    const sender: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };
    var series = try formatpatch.format(gpa, io, &repo, .{ .upstream = base, .tip = head }, .{ .cover_letter = .on, .cover = .{ .sender = sender }, .reroll_count = "2", .filename_max_length = 30 });
    defer series.deinit();
    var ours: std.ArrayList(u8) = .empty;
    defer ours.deinit(gpa);
    for (series.mails) |m| {
        try ours.print(gpa, "out/{s}\n", .{m.name});
        // each file holds exactly the mail
        const path = try gpa.print("out/{s}", .{m.name});
        defer gpa.free(path);
        const file = try git.readFile(io, path);
        defer gpa.free(file);
        try std.testing.expectEqualStrings(file, m.text);
    }
    try std.testing.expectEqualStrings(names, ours.items);
}

fn binaryBase(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "blob.bin", repeat("\x00\x01\x02 binary data ", 64));
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });
}

test "a binary change goes out as a GIT binary patch git applies to the same file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try binaryBase(io, &git);
    try git.writeFile(io, "blob.bin", repeat("\x00\x01\x02 binary data ", 60) ++ "\x00 changed tail");
    try git.writeFile(io, "fresh.bin", "\x00new");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "binary" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const head = try oidOf(gpa, io, &git, "HEAD");
    var series = try formatpatch.format(gpa, io, &repo, .{ .upstream = try oidOf(gpa, io, &git, "HEAD~1"), .tip = head }, .{});
    defer series.deinit();
    const want = try git.run(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(want);
    const text = series.mails[0].text;
    try std.testing.expect(std.mem.find(u8, text, "GIT binary patch\n") != null);

    // a repository without the new blobs: git must decode the hunks
    var theirs = try testgit.Repo.init(gpa, io, &.{});
    defer theirs.deinit();
    try binaryBase(io, &theirs);
    const out = try theirs.runInput(io, &.{ "apply", "--index", "-" }, text);
    gpa.free(out);
    const got = try theirs.run(io, &.{"write-tree"});
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);

    // and relic decodes the same text, both ways
    var ours_git = try testgit.Repo.init(gpa, io, &.{});
    defer ours_git.deinit();
    try binaryBase(io, &ours_git);
    const base_tree = try ours_git.run(io, &.{ "rev-parse", "HEAD^{tree}" });
    defer gpa.free(base_tree);
    var ours = try Repository.open(gpa, io, ours_git.dir, .{});
    defer ours.deinit(io);
    var outcome = try apply_mod.apply(gpa, io, &ours, text, .{ .target = .index });
    defer outcome.deinit();
    const tree = try ours_git.run(io, &.{"write-tree"});
    defer gpa.free(tree);
    try std.testing.expectEqualStrings(want, tree);
    var back = try apply_mod.apply(gpa, io, &ours, text, .{ .target = .index, .reverse = true });
    defer back.deinit();
    const restored = try ours_git.run(io, &.{"write-tree"});
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(base_tree, restored);
}

test "odd paths, binary files, type changes, wide diffstats and odd authors come out as git writes them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "plain.txt", "1\n2\n3\n");
    try git.writeFile(io, "kind", "a file that becomes a link\n");
    try git.writeFile(io, "pic.bin", repeat("\x00\x01image", 10));
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });
    try git.exec(io, &.{ "tag", "base" });

    // a tab, a non-ASCII byte and a very long path; a binary edit; many
    // lines in one file, so the graph is scaled
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..200) |i| try big.print(gpa, "line {d}\n", .{i});
    // Windows takes no tab in a file name
    const odd_name = if (builtin.target.os.tag == .windows) "odd name caf\xc3\xa9.txt" else "odd\tname caf\xc3\xa9.txt";
    try git.writeFile(io, odd_name, "odd\n");
    try git.writeFile(io, "中文e\u{0301}.txt", "wide and combining\n");
    try git.writeFile(io, "wide/" ++ repeat("目录", 40) ++ "e\u{0301}.txt", "a shortened wide name\n");
    try git.writeFile(io, "a/very/long/directory/path/that/needs/to/be/shortened/in/the/diffstat/file.txt", "deep\n");
    try git.writeFile(io, "plain.txt", big.items);
    try git.writeFile(io, "pic.bin", repeat("\x00\x01image", 9) ++ "\x00changed");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "-c", "user.name=Doe, John (the \"tester\")", "-c", "user.email=doe@example.com", "commit", "-q", "-m", "Odd things =?with?= an encoded-word lookalike\n\nFrom here on, a line mboxrd quotes\n>From one already quoted\n" });
    if (builtin.target.os.tag != .windows) {
        try git.dir.deleteFile(io, "kind");
        try git.dir.symLink(io, "plain.txt", "kind", .{});
        try git.exec(io, &.{ "add", "-A" });
        try git.exec(io, &.{ "-c", "user.name=An Author Whose Name Is Long Enough That The From Header Of The Mail Must Wrap It", "-c", "user.email=long@example.com", "commit", "-q", "-m", "A file becomes a link" });
    }
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const range: formatpatch.Range = .{ .upstream = base, .tip = head };
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--no-binary" }, "base..HEAD", range, .{ .binary = false });
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--no-binary", "--pretty=mboxrd" }, "base..HEAD", range, .{ .binary = false, .mboxrd = true });
    try git.exec(io, &.{ "config", "core.quotePath", "false" });
    try git.exec(io, &.{ "config", "diff.context", "1" });
    try git.exec(io, &.{ "config", "diff.algorithm", "histogram" });
    var again = try Repository.open(gpa, io, git.dir, .{});
    defer again.deinit(io);
    try compare(gpa, io, &git, &again, &.{ "--no-signature", "--no-binary" }, "base..HEAD", range, .{ .binary = false });
}

test "a commit already upstream is left out, and copies are found when diff.renames asks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "a.txt", "shared\nlines\nfor\na\ncopy\nto\nbe\nfound\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "base" });
    try git.exec(io, &.{ "branch", "upstream" });
    try git.writeFile(io, "b.txt", "picked\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "picked upstream too" });
    try git.writeFile(io, "copy.txt", "shared\nlines\nfor\na\ncopy\nto\nbe\nfound\nand more\n");
    try git.writeFile(io, "a.txt", "shared\nlines\nfor\na\ncopy\nto\nbe\nfound\nchanged\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "copy" });
    try git.exec(io, &.{ "checkout", "-q", "upstream" });
    try git.exec(io, &.{ "cherry-pick", "main~1" });
    try git.exec(io, &.{ "checkout", "-q", "main" });
    try git.exec(io, &.{ "config", "diff.renames", "copies" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const range: formatpatch.Range = .{ .upstream = try oidOf(gpa, io, &git, "upstream"), .tip = try oidOf(gpa, io, &git, "main") };
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--ignore-if-in-upstream" }, "upstream..main", range, .{ .ignore_if_in_upstream = true });
    try compare(gpa, io, &git, &repo, &.{"--no-signature"}, "upstream..main", range, .{});
}

test "format-patch takes an order file and --relative, given or from diff.orderFile and diff.relative, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const diff = @import("../diff/diff.zig");
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    try git.writeFile(io, "dir/more.txt", "more\n");
    try git.writeFile(io, "dir/b.txt", "bee again\n");
    try git.writeFile(io, "run.sh", "#!/bin/sh\necho again\n");
    try git.exec(io, &.{ "add", "-A" });
    try git.exec(io, &.{ "commit", "-q", "-m", "Under dir and beside it" });
    try git.writeFile(io, "order", "*.sh\nnew*\n# a.txt\n\ndir\n");
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const range: formatpatch.Range = .{ .upstream = base, .tip = head };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const order = try diff.Order.parse(arena.allocator(), "*.sh\nnew*\n# a.txt\n\ndir\n");
    {
        var repo = try Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        try compare(gpa, io, &git, &repo, &.{ "--no-signature", "-Oorder" }, "base..HEAD", range, .{ .order = order });
        try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--relative=dir/" }, "base..HEAD", range, .{ .directory = "dir/", .relative = true });
    }
    try git.exec(io, &.{ "config", "diff.orderFile", "order" });
    try git.exec(io, &.{ "config", "diff.relative", "true" });
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    // git's `--relative=dir/` from the top is `diff.relative` from `dir`.
    try compare(gpa, io, &git, &repo, &.{ "--no-signature", "--relative=dir/" }, "base..HEAD", range, .{ .directory = "dir/" });
    try compare(gpa, io, &git, &repo, &.{"--no-signature"}, "base..HEAD", range, .{});
}

test "format-patch takes diff.srcPrefix, diff.dstPrefix and diff.mnemonicPrefix, and passes diff.noPrefix over, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Setting = struct { key: []const u8, value: []const u8 };
    const variants = [_][]const Setting{
        &.{.{ .key = "diff.noPrefix", .value = "true" }},
        &.{ .{ .key = "diff.srcPrefix", .value = "from/" }, .{ .key = "diff.dstPrefix", .value = "to/" } },
        &.{ .{ .key = "diff.mnemonicPrefix", .value = "true" }, .{ .key = "diff.srcPrefix", .value = "from/" } },
    };
    for (variants) |settings| {
        var git = try testgit.Repo.init(gpa, io, &.{});
        defer git.deinit();
        try buildHistory(io, &git);
        for (settings) |s| try git.exec(io, &.{ "config", s.key, s.value });
        var repo = try Repository.open(gpa, io, git.dir, .{});
        defer repo.deinit(io);
        const range: formatpatch.Range = .{ .upstream = try oidOf(gpa, io, &git, "base"), .tip = try oidOf(gpa, io, &git, "HEAD") };
        try compare(gpa, io, &git, &repo, &.{"--no-signature"}, "base..HEAD", range, .{});
    }
}

test "format.notes and --notes put the notes below the message as git's format-patch does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try buildHistory(io, &git);
    const base = try oidOf(gpa, io, &git, "base");
    const head = try oidOf(gpa, io, &git, "HEAD");
    const range: formatpatch.Range = .{ .upstream = base, .tip = head };
    try git.exec(io, &.{ "notes", "add", "-m", "a default note", "HEAD" });
    try git.exec(io, &.{ "notes", "--ref=review", "add", "-m", "reviewed\nby someone", "HEAD~1" });
    try git.exec(io, &.{ "notes", "--ref=review", "add", "-m", "also reviewed", "HEAD" });
    const off: formatpatch.Options = .{ .who = fixture, .signature = .off };

    try compareSet(gpa, io, &git, &.{}, &.{ "--no-signature", "--notes" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .notes = &.{.standard} });
    try compareSet(gpa, io, &git, &.{}, &.{ "--no-signature", "--notes=review", "-p" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .notes = &.{.{ .ref = "review" }}, .stat = false });
    try compareSet(gpa, io, &git, &.{.{ "format.notes", "true" }}, &.{"--no-signature"}, "base..HEAD", range, off);
    try compareSet(gpa, io, &git, &.{ .{ "format.notes", "true" }, .{ "format.notes", "review" } }, &.{"--no-signature"}, "base..HEAD", range, off);
    try compareSet(gpa, io, &git, &.{ .{ "format.notes", "review" }, .{ "format.notes", "false" } }, &.{"--no-signature"}, "base..HEAD", range, off);
    try compareSet(gpa, io, &git, &.{.{ "format.notes", "review" }}, &.{ "--no-signature", "--notes" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .notes = &.{.standard} });
    try compareSet(gpa, io, &git, &.{.{ "format.notes", "true" }}, &.{ "--no-signature", "--no-notes" }, "base..HEAD", range, .{ .who = fixture, .signature = .off, .notes = &.{.off} });
    try compareSet(gpa, io, &git, &.{ .{ "format.notes", "true" }, .{ "format.signOff", "true" } }, &.{"--no-signature"}, "base..HEAD", range, off);
}

test "a mail's Date: is git's DATE_RFC2822, in the author's own zone" {
    const gitdate = @import("../text.zig").date;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try gitdate.show(&w, 1700000000, gitdate.tzInt(60), .{ .kind = .rfc2822 }, .{});
    try std.testing.expectEqualStrings("Tue, 14 Nov 2023 23:13:20 +0100", w.buffered());
    w = .fixed(&buf);
    try gitdate.show(&w, 0, gitdate.tzInt(-330), .{ .kind = .rfc2822 }, .{});
    try std.testing.expectEqualStrings("Wed, 31 Dec 1969 18:30:00 -0530", w.buffered());
}

test "a wrap's columns cannot overflow, whatever the indent" {
    const mailfmt = @import("../mail/format.zig");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // The most negative first indent: its column count saturates, past
    // any width, so the text starts on a new line at the second indent.
    try mailfmt.writeWrapped(&out.writer, "a b c", std.math.minInt(i32), 1, 78);
    try std.testing.expectEqualStrings("\n a b c", out.written());
}
