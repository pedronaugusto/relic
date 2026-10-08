//! Trailers against git's: `git interpret-trailers` under every option and
//! `trailer.*` rule, `%(trailers)` in `git log` and `git for-each-ref`,
//! `git shortlog --group=trailer` and `git commit --trailer`, on the same
//! messages and the same configuration.

const object = @import("object.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const trailer = @import("trailer.zig");
const message = @import("message.zig");
const commit_mod = @import("../commit/commit.zig");
const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const pretty = @import("../pretty/pretty.zig");
const refs_filter = @import("../pretty/refs.zig");
const shortlog = @import("../pretty/shortlog.zig");
const revwalk = @import("../walk/walk.zig");
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;
const Oid = hash.Oid;

/// The arguments `git interpret-trailers` takes, read as git reads them.
fn parseArgs(arena: Allocator, args: []const []const u8) !struct { options: trailer.Options, new: []const trailer.New } {
    var options: trailer.Options = .{};
    var new: std.ArrayList(trailer.New) = .empty;
    var where: ?trailer.Where = null;
    var if_exists: ?trailer.IfExists = null;
    var if_missing: ?trailer.IfMissing = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--trailer")) {
            i += 1;
            try new.append(arena, .{ .text = args[i], .where = where, .if_exists = if_exists, .if_missing = if_missing });
        } else if (std.mem.eql(u8, arg, "--where")) {
            i += 1;
            where = trailer.Where.parse(args[i]).?;
        } else if (std.mem.eql(u8, arg, "--no-where")) {
            where = null;
        } else if (std.mem.eql(u8, arg, "--if-exists")) {
            i += 1;
            if_exists = trailer.IfExists.parse(args[i]).?;
        } else if (std.mem.eql(u8, arg, "--no-if-exists")) {
            if_exists = null;
        } else if (std.mem.eql(u8, arg, "--if-missing")) {
            i += 1;
            if_missing = trailer.IfMissing.parse(args[i]).?;
        } else if (std.mem.eql(u8, arg, "--trim-empty")) {
            options.trim_empty = true;
        } else if (std.mem.eql(u8, arg, "--only-trailers")) {
            options.only_trailers = true;
        } else if (std.mem.eql(u8, arg, "--only-input")) {
            options.only_input = true;
        } else if (std.mem.eql(u8, arg, "--unfold")) {
            options.unfold = true;
        } else if (std.mem.eql(u8, arg, "--parse")) {
            options.only_trailers = true;
            options.only_input = true;
            options.unfold = true;
        } else if (std.mem.eql(u8, arg, "--no-divider")) {
            options.no_divider = true;
        } else unreachable;
    }
    return .{ .options = options, .new = new.items };
}

/// A shell command that prints its words, for `trailer.<name>.cmd` and
/// `.command`.
const echo_cmd = "printf '%s\\n' \"cmd-said:$1\"";

const Fixture = struct {
    git: testgit.Repo,
    environ: std.process.Environ.Map,

    /// git's trailers settled into today's shape with 2.47, which reads a
    /// message that ends in an incomplete line as the rest do; before it,
    /// 2.45 rewrote how they are written and 2.31 and 2.32 added options.
    fn init(gpa: Allocator, io: Io) !Fixture {
        try testgit.requireGitVersion(gpa, io, 2, 47);
        var git = try testgit.Repo.init(gpa, io, &.{});
        errdefer git.deinit();
        var environ = try testgit.programEnviron(gpa);
        errdefer environ.deinit();
        return .{ .git = git, .environ = environ };
    }

    fn deinit(f: *Fixture) void {
        f.environ.deinit();
        f.git.deinit();
        f.* = undefined;
    }

    /// The input through `git interpret-trailers <args>` and through
    /// `trailer.process` under the repository's configuration.
    fn compare(f: *Fixture, gpa: Allocator, io: Io, input: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "interpret-trailers");
        try argv.appendSlice(gpa, args);
        const theirs = try f.git.runInput(io, argv.items, input);
        defer gpa.free(theirs);

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var repo = try Repository.open(gpa, io, f.git.dir, .{});
        defer repo.deinit(io);
        const settings = try message.trailerSettings(arena, repo.configuration());
        const parsed = try parseArgs(arena, args);
        var completed: std.ArrayList(u8) = .empty;
        try completed.appendSlice(arena, input);
        if (input.len != 0 and input[input.len - 1] != '\n') try completed.append(arena, '\n');
        var ours: std.ArrayList(u8) = .empty;
        defer ours.deinit(gpa);
        try trailer.process(gpa, io, completed.items, &ours, .{ .settings = settings, .commands = .{ .programs = .{ .environ = &f.environ }, .cwd = .{ .dir = f.git.dir } }, .formatting = parsed.options, .new = parsed.new });
        std.testing.expectEqualStrings(theirs, ours.items) catch |err| {
            std.debug.print("interpret-trailers", .{});
            for (args) |arg| std.debug.print(" {s}", .{arg});
            std.debug.print(" on {f}\n", .{std.zig.fmtString(input)});
            return err;
        };
    }
};

const inputs = [_][]const u8{
    "",
    "subject\n",
    "subject",
    "subject\n\nbody\n",
    "subject\n\nbody\n\nAcked-by: Ann <ann@example.com>\nSigned-off-by: Bob <bob@example.com>\n",
    "subject\n\nbody\n\nKey: value\nOther-Key:   spaced  \n  continued\n   twice\nLast: one\n",
    "subject\n\nbody\n\nReviewed-by: Cy\n---\n a.c | 1 +\n",
    "subject\n\nbody\n\nAcked-by: Ann\n# a comment\n\n# ------------------------ >8 ------------------------\nbelow the cut\n",
    "subject\n\nsome text\n(cherry picked from commit 1234)\nmore text\nand more\n",
    "subject\n\nBug #42\nFixes: 12\n",
    "Fix: only a title\n",
    "subject\n\nbody\n\nAcked-by: Ann\nnot a trailer\nAcked-by: Ann\n",
    "subject\n\nsign: someone\nAck: x\n",
};

const argument_sets = [_][]const []const u8{
    &.{},
    &.{ "--trailer", "Acked-by: Dee <dee@example.com>" },
    &.{ "--trailer", "acked-by=Ann" },
    &.{ "--trailer", "Acked-by: Ann", "--trailer", "Acked-by: Ann" },
    &.{ "--trailer", "Key" },
    &.{ "--trim-empty", "--trailer", "Empty:" },
    &.{ "--where", "start", "--trailer", "First: 1" },
    &.{ "--where", "before", "--trailer", "Acked-by: Eve" },
    &.{ "--where", "after", "--trailer", "Acked-by: Eve" },
    &.{ "--if-exists", "add", "--trailer", "Acked-by: Ann" },
    &.{ "--if-exists", "addIfDifferent", "--trailer", "Acked-by: Ann", "--trailer", "acked-by: ann" },
    &.{ "--if-exists", "replace", "--trailer", "Acked-by: Fay" },
    &.{ "--if-exists", "replace", "--where", "start", "--trailer", "Acked-by: Fay" },
    &.{ "--if-exists", "doNothing", "--trailer", "Acked-by: Fay" },
    &.{ "--if-missing", "doNothing", "--trailer", "Missing: no" },
    &.{ "--if-exists", "add", "--no-if-exists", "--trailer", "Acked-by: Ann" },
    &.{ "--trailer", ": no key", "--trailer", "Good: yes" },
    &.{"--only-trailers"},
    &.{"--only-input"},
    &.{"--unfold"},
    &.{"--parse"},
    &.{"--no-divider"},
    &.{ "--only-trailers", "--trailer", "New: x" },
    &.{ "--trailer", "sign=Me <me@example.com>", "--trailer", "bug: 7", "--trailer", "Fix=9" },
};

test "interpret-trailers reads, adds and writes trailers as git's does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    for (inputs) |input| for (argument_sets) |args| try f.compare(gpa, io, input, args);
}

test "every trailer.* rule is applied as git applies it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    const configs = [_][]const [2][]const u8{
        &.{ .{ "trailer.sign.key", "Signed-off-by: " }, .{ "trailer.sign.where", "after" }, .{ "trailer.sign.ifExists", "addIfDifferent" } },
        &.{ .{ "trailer.separators", ":#" }, .{ "trailer.bug.key", "Bug #" }, .{ "trailer.bug.ifMissing", "doNothing" } },
        &.{ .{ "trailer.where", "start" }, .{ "trailer.ifexists", "replace" }, .{ "trailer.ifmissing", "add" }, .{ "trailer.ack.key", "Acked-by" } },
        &.{ .{ "trailer.where", "nowhere" }, .{ "trailer.Ack.key", "Acked-by:" }, .{ "trailer.ACK.where", "before" } },
        &.{ .{ "trailer.fix.cmd", echo_cmd }, .{ "trailer.fix.key", "Fixes" } },
        &.{ .{ "trailer.ref.command", "echo \"ref of $ARG\"" }, .{ "trailer.ref.ifExists", "replace" } },
        &.{ .{ "trailer.ifexists", "addIfDifferentNeighbor" }, .{ "trailer.separators", "=" } },
    };
    // the inputs and arguments a rule can change, so the run stays short
    // where starting git is slow
    const some_inputs = [_][]const u8{ inputs[1], inputs[4], inputs[5], inputs[7], inputs[8], inputs[9], inputs[12] };
    const some_arguments = [_][]const []const u8{ argument_sets[0], argument_sets[2], argument_sets[3], argument_sets[6], argument_sets[11], argument_sets[16], argument_sets[20], argument_sets[23] };
    for (configs) |config| {
        for (config) |pair| try f.git.exec(io, &.{ "config", pair[0], pair[1] });
        for (some_inputs) |input| for (some_arguments) |args| try f.compare(gpa, io, input, args);
        for (config) |pair| try f.git.exec(io, &.{ "config", "--unset-all", pair[0] });
    }
}

test "in-place editing replaces the file as git's does, and keeps it as it was otherwise" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    try f.git.writeFile(io, "msg-git", "subject\n\nbody");
    try f.git.writeFile(io, "msg-relic", "subject\n\nbody");
    try f.git.exec(io, &.{ "interpret-trailers", "--in-place", "--trailer", "Acked-by: Ann", "msg-git" });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try trailer.processFile(gpa, io, f.git.dir, "msg-relic", .{ .new = &.{.{ .text = "Acked-by: Ann" }}, .in_place = true, .out = &out });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    const theirs = try f.git.readFile(io, "msg-git");
    defer gpa.free(theirs);
    const ours = try f.git.readFile(io, "msg-relic");
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
    // a command needs the programs to run it
    try std.testing.expectError(error.TrailerCommandNeedsPrograms, trailer.process(gpa, io, "s\n", &out, .{ .settings = .{ .rules = &.{.{ .name = "x", .command = "true", .where = .end, .if_exists = .add, .if_missing = .add }} }, .commands = null, .formatting = .{}, .new = &.{} }));
}

/// A repository whose commits carry trailers of every shape.
fn trailerHistory(io: Io, git: *testgit.Repo) !void {
    for ([_][]const u8{
        "plain subject\n",
        "with trailers\n\nbody\n\nAcked-by: Ann <ann@example.com>\nSigned-off-by: Bob <bob@example.com>\nSigned-off-by: Cy <cy@example.com>\n",
        "folded\n\nKey: a value\n  carried on\nOther: x\n",
        "mixed\n\nsome text\n(cherry picked from commit 1234)\nmore text\nand more\n",
        "after a divider\n\nAcked-by: Ann <ann@example.com>\n---\nnot a divider in a commit\n",
    }) |msg| try git.exec(io, &.{ "commit", "-q", "--allow-empty", "--cleanup=verbatim", "-m", msg });
}

const trailer_formats = [_][]const u8{
    "%(trailers)",
    "%(trailers:only)",
    "%(trailers:only=no)",
    "%(trailers:unfold)",
    "%(trailers:only,unfold)",
    "%(trailers:key=Signed-off-by)",
    "%(trailers:key=signed-off-by:)",
    "%(trailers:key=Acked-by,key=Key)",
    "%(trailers:key=Signed-off-by,only=no)",
    "%(trailers:separator=%x2C )",
    "%(trailers:key=Signed-off-by,separator=%x2C,valueonly)",
    "%(trailers:keyonly)",
    "%(trailers:key_value_separator=%x3D,unfold)",
    "%(trailers:key=Key,unfold=yes,valueonly=true)",
    "%(trailers:nonsense)",
    "%(trailers",
};

test "%(trailers) in a log format writes what git log writes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    try trailerHistory(io, &f.git);
    var repo = try Repository.open(gpa, io, f.git.dir, .{});
    defer repo.deinit(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (0..5) |back| {
        var rev_buf: [16]u8 = undefined;
        const rev = try std.mem.print(&rev_buf, "HEAD~{d}", .{back});
        const text = try f.git.line(io, &.{ "rev-parse", rev });
        defer gpa.free(text);
        const oid = try Oid.parse(.sha1, text);
        for (trailer_formats) |format| {
            const arg = try gpa.print("--format=[{s}]", .{format});
            defer gpa.free(arg);
            const theirs = try f.git.run(io, &.{ "show", "-s", arg, rev });
            defer gpa.free(theirs);
            const a = arena_state.allocator();
            var ours: std.ArrayList(u8) = .empty;
            const wrapped = try a.print("[{s}]", .{format});
            try pretty.formatCommit(a, io, repo.objectDatabase(), oid, wrapped, .{ .trailers = try message.trailerSettings(a, repo.configuration()) }, &ours);
            try ours.append(a, '\n');
            std.testing.expectEqualStrings(theirs, ours.items) catch |err| {
                std.debug.print("{s} on {s}\n", .{ format, rev });
                return err;
            };
        }
    }
}

test "%(trailers) and %(contents:trailers) in a ref format write what git for-each-ref writes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    try trailerHistory(io, &f.git);
    for (0..5) |back| {
        var name_buf: [32]u8 = undefined;
        var rev_buf: [16]u8 = undefined;
        try f.git.exec(io, &.{ "branch", try std.mem.print(&name_buf, "b{d}", .{back}), try std.mem.print(&rev_buf, "HEAD~{d}", .{back}) });
    }
    try f.git.exec(io, &.{ "tag", "-a", "signed-tag", "-m", "tag subject\n\nAcked-by: Tag <t@example.com>\n-----BEGIN PGP SIGNATURE-----\nnot really\n-----END PGP SIGNATURE-----\n" });
    var repo = try Repository.open(gpa, io, f.git.dir, .{});
    defer repo.deinit(io);
    for (trailer_formats[0 .. trailer_formats.len - 2]) |format| {
        const full = try gpa.print("[{s}] [%(contents:{s})]", .{ format, format[2 .. format.len - 1] });
        defer gpa.free(full);
        const arg = try gpa.print("--format={s}", .{full});
        defer gpa.free(arg);
        const theirs = try f.git.run(io, &.{ "for-each-ref", arg });
        defer gpa.free(theirs);
        var ours: Io.Writer.Allocating = .init(gpa);
        defer ours.deinit();
        try refs_filter.listRefs(gpa, io, &repo, .{ .format = full }, &ours.writer);
        std.testing.expectEqualStrings(theirs, ours.written()) catch |err| {
            std.debug.print("{s}\n", .{full});
            return err;
        };
    }
    var l = refs_filter.Listing.init(gpa, io, &repo, .{});
    defer l.deinit();
    try std.testing.expectError(error.BadFieldArgument, l.parseFormat("%(trailers:nonsense)", .none));
}

test "a shortlog by trailer reads them as the repository's trailer rules say" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit();
    try trailerHistory(io, &f.git);
    try f.git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "configured\n\nsob: Dee <dee@example.com>\nHelped #Eve <eve@example.com>\n" });
    try f.git.exec(io, &.{ "config", "trailer.sob.key", "Signed-off-by" });
    try f.git.exec(io, &.{ "config", "trailer.separators", ":#" });
    for ([_][]const u8{ "signed-off-by", "helped", "acked-by" }) |key| {
        const group = try gpa.print("--group=trailer:{s}", .{key});
        defer gpa.free(group);
        const theirs = try f.git.run(io, &.{ "shortlog", "HEAD", group });
        defer gpa.free(theirs);
        var repo = try Repository.open(gpa, io, f.git.dir, .{});
        defer repo.deinit(io);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        var s = try shortlog.Shortlog.init(gpa, try shortlog.configured(arena_state.allocator(), repo.configuration(), .{ .groups = &.{.{ .trailer = key }} }));
        defer s.deinit();
        var walk: revwalk.Walk = .init(gpa, repo.objectDatabase());
        defer walk.deinit();
        const head = (try repo.head(io)).?;
        defer gpa.free(head.name);
        try walk.push(head.oid);
        while (try walk.next(io)) |c| try s.add(io, repo.objectDatabase(), c.oid);
        var ours: Io.Writer.Allocating = .init(gpa);
        defer ours.deinit();
        try s.write(&ours.writer);
        try std.testing.expectEqualStrings(theirs, ours.written());
    }
}

test "commit --trailer adds trailers as git commit does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var a = try Fixture.init(gpa, io);
    defer a.deinit();
    var b = try Fixture.init(gpa, io);
    defer b.deinit();
    for ([_]*Fixture{ &a, &b }) |f| {
        try f.git.exec(io, &.{ "config", "trailer.sign.key", "Signed-off-by: " });
        try f.git.exec(io, &.{ "config", "trailer.fix.cmd", echo_cmd });
        try f.git.writeFile(io, "a.txt", "a\n");
        try f.git.exec(io, &.{ "add", "a.txt" });
    }
    try a.git.exec(io, &.{ "commit", "-q", "-m", "subject\n\nbody\n", "--trailer", "sign: Ann <ann@example.com>", "--trailer", "fix=12", "--trailer", "Acked-by: Bob" });
    const theirs = try a.git.run(io, &.{ "log", "-1", "--format=%B" });
    defer gpa.free(theirs);

    var repo = try Repository.open(gpa, io, b.git.dir, .{});
    defer repo.deinit(io);
    const who: object.Signature = .{ .name = "Fixture", .email = "fixture@example.com", .when_secs = testgit.fixture_date, .offset_minutes = 0 };
    _ = try commit_mod.commit(io, &repo, .{ .author = who, .committer = who, .message = "subject\n\nbody\n" }, .{
        .trailers = &.{ "sign: Ann <ann@example.com>", "fix=12", "Acked-by: Bob" },
        .trailer_commands = .{ .programs = .{ .environ = &b.environ }, .cwd = .{ .dir = b.git.dir } },
    });
    const ours = try b.git.run(io, &.{ "log", "-1", "--format=%B" });
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
    try std.testing.expectError(error.InvalidTrailer, commit_mod.commit(io, &repo, .{ .author = who, .committer = who, .message = "x\n" }, .{ .allow_empty = true, .trailers = &.{":no key"} }));
}
