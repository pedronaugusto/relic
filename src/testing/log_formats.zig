//! `pretty.log` against git 2.55's `git log --pretty=<format>`: every
//! built-in format, a merge, a message with tabs, trailing space and
//! paragraphs, a commit in another encoding, the mailmap, decorations,
//! colour, notes, `--abbrev-commit` and `log.abbrevCommit`, `log.date`,
//! and the format chosen by `format.pretty`, by a prefix of a name and by
//! a `pretty.<name>` alias.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const testgit = @import("git.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const hash = @import("../hash/hash.zig");
const pretty = @import("../pretty/pretty.zig");
const log = @import("../pretty/log.zig");
const mailmap_mod = @import("../rev_walk/mailmap.zig");
const notes_mod = @import("../commit/notes.zig");

fn setup(io: Io, git: *testgit.Repo) !void {
    try git.writeFile(io, "a", "one\n");
    try git.exec(io, &.{ "add", "a" });
    try git.exec(io, &.{ "commit", "-q", "-m", "first line\nof the subject\n\nbody\twith a tab\n  ab\tc\tde\t\tf   \n\n\n\nafter blank lines\n" });
    try git.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1" });
    try git.exec(io, &.{ "checkout", "-q", "-b", "side" });
    try git.writeFile(io, "b", "side\n");
    try git.exec(io, &.{ "add", "b" });
    try git.writeFile(io, "msg", "caf\xe9 latin\n\nd\xe9j\xe0 vu\n");
    try git.exec(io, &.{ "-c", "i18n.commitEncoding=ISO-8859-1", "commit", "-q", "-F", "msg" });
    try git.exec(io, &.{ "checkout", "-q", "main" });
    try git.writeFile(io, "a", "two\n");
    try git.exec(io, &.{ "-c", "user.name=Other Person", "-c", "user.email=other@example.com", "commit", "-q", "-a", "-m", "second\n\n\tindented\n" });
    try git.exec(io, &.{ "merge", "-q", "--no-ff", "-m", "Merge side\n\nwith a body", "side" });
    try git.exec(io, &.{ "notes", "add", "-m", "a note\n\nof two paragraphs", "HEAD~1" });
    try git.writeFile(io, ".mailmap", "Mapped Name <mapped@example.com> <other@example.com>\n");
}

const Case = struct {
    pretty: []const u8,
    config: []const u8 = "",
    args: []const []const u8 = &.{},
    decorate: bool = false,
    color: bool = false,
    notes: bool = false,
    abbrev_commit: bool = false,
};

test "a log in each built-in format is git log --pretty's" {
    try testgit.requireGitVersion(std.testing.allocator, std.testing.io, 2, 55);
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try setup(io, &git);
    var repo = try repo_mod.Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    const listed = try git.run(io, &.{ "rev-list", "main" });
    defer gpa.free(listed);

    const cases = [_]Case{
        .{ .pretty = "raw" },
        .{ .pretty = "medium" },
        .{ .pretty = "short" },
        .{ .pretty = "full" },
        .{ .pretty = "fuller" },
        .{ .pretty = "oneline" },
        .{ .pretty = "med" },
        .{ .pretty = "f" },
        .{ .pretty = "medium", .args = &.{"--abbrev-commit"}, .abbrev_commit = true },
        .{ .pretty = "oneline", .config = "[log]\n\tabbrevCommit = true\n", .abbrev_commit = true },
        .{ .pretty = "fuller", .config = "[log]\n\tdate = iso\n" },
        .{ .pretty = "medium", .args = &.{"--decorate"}, .decorate = true },
        .{ .pretty = "oneline", .args = &.{"--decorate"}, .decorate = true },
        .{ .pretty = "medium", .args = &.{ "--decorate", "--color=always" }, .decorate = true, .color = true },
        .{ .pretty = "medium", .args = &.{"--notes"}, .notes = true },
        .{ .pretty = "oneline", .args = &.{"--notes"}, .notes = true },
        .{ .pretty = "point", .config = "[pretty]\n\tmine = fuller\n\tpointer = mine\n" },
    };
    for (cases) |case| {
        var config = try config_mod.Config.parseText(gpa, case.config, .local);
        defer config.deinit();
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var settings = std.mem.tokenizeScalar(u8, case.config, '\n');
        var section: []const u8 = "";
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |s| gpa.free(s);
            owned.deinit(gpa);
        }
        while (settings.next()) |line| {
            if (line[0] == '[') {
                section = line[1 .. line.len - 1];
                continue;
            }
            const eq = std.mem.findScalar(u8, line, '=').?;
            const setting = try gpa.print("{s}.{s}={s}", .{ section, std.mem.trim(u8, line[0..eq], " \t"), std.mem.trim(u8, line[eq + 1 ..], " \t") });
            try owned.append(gpa, setting);
            try argv.appendSlice(gpa, &.{ "-c", setting });
        }
        const pretty_arg = try gpa.print("--pretty={s}", .{case.pretty});
        defer gpa.free(pretty_arg);
        try argv.appendSlice(gpa, &.{ "log", pretty_arg });
        if (!case.decorate) try argv.append(gpa, "--no-decorate");
        if (!case.notes) try argv.append(gpa, "--no-notes");
        if (!case.color) try argv.append(gpa, "--no-color");
        try argv.appendSlice(gpa, case.args);
        try argv.append(gpa, "main");
        const theirs = try git.run(io, argv.items);
        defer gpa.free(theirs);

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const choice = try log.parse(a, &config, case.pretty);
        var mailmap = try mailmap_mod.Mailmap.load(gpa, io, &repo);
        defer mailmap.deinit();
        var decorations = try pretty.Decorations.load(gpa, io, &repo, .{});
        defer decorations.deinit();
        var display = try notes_mod.DisplayNotes.load(gpa, io, &repo, .{});
        defer display.deinit();
        const colors: pretty.Colors = .{};
        var ours: std.ArrayList(u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        var first = true;
        while (lines.next()) |hex| {
            const oid = try hash.Oid.parse(.sha1, hex);
            var note_text: Io.Writer.Allocating = .init(a);
            if (case.notes) try display.format(io, oid, &note_text.writer, .{});
            try log.writeEntry(a, io, .{ .db = repo.objectDatabase(), .oid = oid }, &ours, .{
                .mailmap = &mailmap,
                .decorations = if (case.decorate) &decorations else null,
                .colors = if (case.color) &colors else null,
                .notes = if (case.notes) note_text.written() else null,
                .date_mode = try pretty.configuredDateMode(&config),
            }, .{
                .format = choice.format.builtin,
                .abbrev_commit = case.abbrev_commit or try log.configuredAbbrevCommit(&config),
                .expand_tabs = choice.expand_tabs,
                .terminator = choice.terminator,
                .after_another = !first,
            });
            first = false;
        }
        std.testing.expectEqualStrings(theirs, ours.items) catch |err| {
            std.debug.print("--pretty={s} {s}\n", .{ case.pretty, case.config });
            return err;
        };
    }
}

test "a log's format is read as git's get_commit_format reads --pretty and format.pretty" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var config = try config_mod.Config.parseText(gpa,
        \\[pretty]
        \\    short = %s
        \\    tiny = %h
        \\    tin = tformat:%H
        \\    sep = format:%an
        \\    loop = round
        \\    round = loop
        \\    upper = ONELINE
        \\    bad = nothing
        \\[format]
        \\    pretty = tiny
        \\
    , .local);
    defer config.deinit();
    const Expect = struct { arg: ?[]const u8, choice: log.Choice };
    const expected = [_]Expect{
        .{ .arg = null, .choice = .{ .format = .{ .builtin = .medium }, .expand_tabs = 8 } },
        .{ .arg = "short", .choice = .{ .format = .{ .builtin = .short } } },
        .{ .arg = "o", .choice = .{ .format = .{ .builtin = .oneline }, .terminator = true } },
        .{ .arg = "FULL", .choice = .{ .format = .{ .builtin = .full }, .expand_tabs = 8 } },
        .{ .arg = "tin", .choice = .{ .format = .{ .user = "%H" }, .terminator = true } },
        .{ .arg = "ti", .choice = .{ .format = .{ .user = "%H" }, .terminator = true } },
        .{ .arg = "sep", .choice = .{ .format = .{ .user = "%an" } } },
        .{ .arg = "upper", .choice = .{ .format = .{ .builtin = .oneline }, .terminator = true } },
        .{ .arg = "ref", .choice = .{ .format = .{ .user = "%C(auto)%h (%s, %ad)" }, .terminator = true, .date_mode = .{ .kind = .short } } },
        .{ .arg = "format:%s", .choice = .{ .format = .{ .user = "%s" } } },
        .{ .arg = "tformat:%s", .choice = .{ .format = .{ .user = "%s" }, .terminator = true } },
        .{ .arg = "%s and more", .choice = .{ .format = .{ .user = "%s and more" }, .terminator = true } },
        .{ .arg = "", .choice = .{ .format = .{ .user = "" }, .terminator = true } },
    };
    for (expected) |e| {
        const got = try log.parse(a, &config, e.arg);
        std.testing.expectEqualDeep(e.choice, got) catch |err| {
            std.debug.print("--pretty={?s}\n", .{e.arg});
            return err;
        };
    }
    try std.testing.expectError(error.AliasLoop, log.parse(a, &config, "loop"));
    try std.testing.expectError(error.UnknownFormat, log.parse(a, &config, "bad"));
    try std.testing.expectError(error.UnknownFormat, log.parse(a, &config, "nonesuch"));
    try std.testing.expectError(error.MailFormat, log.parse(a, &config, "email"));
    try std.testing.expectEqualDeep(log.Choice{ .format = .{ .user = "%h" }, .terminator = true }, try log.configured(a, &config));
}
