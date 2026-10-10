//! `refs.filter` against `git for-each-ref`, `git branch --list` and `git
//! tag --list`: the same repository, the same arguments, the same bytes.

const repeat = @import("shakedown").corpus.repeat;
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const filter = @import("refs.zig");
const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const gitdate = @import("../text.zig").date;
const testgit = @import("../testing/git.zig");

const Repository = repo_mod.Repository;
const Oid = hash.Oid;

/// The time the fixture's relative dates are measured from.
const now: i64 = testgit.fixture_date + 400 * 86400;

const Utc = struct {
    fn at(_: *anyopaque, _: i64) gitdate.LocalTime {
        return .{ .offset_minutes = 0, .name = "UTC" };
    }
};
var utc_context: u8 = 0;
const clock: gitdate.Clock = .{ .now = gitdate.timestamp(now), .local = .{ .context = &utc_context, .at = Utc.at } };

fn oidOf(gpa: Allocator, io: Io, git: *testgit.Repo, rev: []const u8) !Oid {
    _ = gpa;
    const text = try git.line(io, &.{ "rev-parse", rev });
    defer git.gpa.free(text);
    return Oid.parse(.sha1, text);
}

/// Options parsed from `args` as the command would parse them; slices
/// are `arena`'s.
const Parsed = struct {
    format: ?[]const u8 = null,
    quote: filter.Quote = .none,
    sort: std.ArrayList(filter.SortKey) = .empty,
    no_sort: bool = false,
    patterns: std.ArrayList([]const u8) = .empty,
    exclude: std.ArrayList([]const u8) = .empty,
    points_at: std.ArrayList(Oid) = .empty,
    contains: std.ArrayList(Oid) = .empty,
    no_contains: std.ArrayList(Oid) = .empty,
    merged: std.ArrayList(Oid) = .empty,
    no_merged: std.ArrayList(Oid) = .empty,
    count: usize = 0,
    ignore_case: bool = false,
    omit_empty: bool = false,
    root_refs: bool = false,
    start_after: ?[]const u8 = null,
    which: filter.Branches = .local,
    verbose: u2 = 0,
    abbrev: ?u32 = null,
    lines: u32 = 0,
};

fn parseArgs(arena: Allocator, io: Io, git: *testgit.Repo, args: []const []const u8) !Parsed {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = struct {
            fn of(a: []const u8, prefix: []const u8) ?[]const u8 {
                return if (std.mem.startsWith(u8, a, prefix)) a[prefix.len..] else null;
            }
        }.of;
        if (value(arg, "--format=")) |v| {
            p.format = v;
        } else if (value(arg, "--sort=")) |v| {
            try p.sort.append(arena, .parse(v));
        } else if (std.mem.eql(u8, arg, "--no-sort")) {
            p.no_sort = true;
        } else if (value(arg, "--count=")) |v| {
            p.count = try std.fmt.parseUnsigned(usize, v, 10);
        } else if (value(arg, "--exclude=")) |v| {
            try p.exclude.append(arena, v);
        } else if (value(arg, "--points-at=")) |v| {
            try p.points_at.append(arena, try oidOf(arena, io, git, v));
        } else if (value(arg, "--contains=")) |v| {
            try p.contains.append(arena, try oidOf(arena, io, git, v));
        } else if (value(arg, "--no-contains=")) |v| {
            try p.no_contains.append(arena, try oidOf(arena, io, git, v));
        } else if (value(arg, "--merged=")) |v| {
            try p.merged.append(arena, try oidOf(arena, io, git, v));
        } else if (value(arg, "--no-merged=")) |v| {
            try p.no_merged.append(arena, try oidOf(arena, io, git, v));
        } else if (value(arg, "--start-after=")) |v| {
            p.start_after = v;
        } else if (value(arg, "--abbrev=")) |v| {
            p.abbrev = try std.fmt.parseUnsigned(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--no-abbrev")) {
            p.abbrev = 0;
        } else if (std.mem.eql(u8, arg, "--ignore-case") or std.mem.eql(u8, arg, "-i")) {
            p.ignore_case = true;
        } else if (std.mem.eql(u8, arg, "--omit-empty")) {
            p.omit_empty = true;
        } else if (std.mem.eql(u8, arg, "--include-root-refs")) {
            p.root_refs = true;
        } else if (std.mem.eql(u8, arg, "--shell")) {
            p.quote = .shell;
        } else if (std.mem.eql(u8, arg, "--perl")) {
            p.quote = .perl;
        } else if (std.mem.eql(u8, arg, "--python")) {
            p.quote = .python;
        } else if (std.mem.eql(u8, arg, "--tcl")) {
            p.quote = .tcl;
        } else if (std.mem.eql(u8, arg, "-r")) {
            p.which = .remote;
        } else if (std.mem.eql(u8, arg, "-a")) {
            p.which = .all;
        } else if (std.mem.eql(u8, arg, "-v")) {
            p.verbose += 1;
        } else if (std.mem.eql(u8, arg, "-vv")) {
            p.verbose = 2;
        } else if (value(arg, "-n")) |v| {
            p.lines = if (v.len == 0) 1 else try std.fmt.parseUnsigned(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            // listing is what is compared
        } else {
            try p.patterns.append(arena, arg);
        }
    }
    return p;
}

const Command = enum { for_each_ref, branch, tag };

/// The first line that differs, git's and ours, with what led up to it.
fn reportFirstDifference(theirs: []const u8, ours: []const u8) void {
    var a = std.mem.splitScalar(u8, theirs, '\n');
    var b = std.mem.splitScalar(u8, ours, '\n');
    var n: usize = 1;
    while (true) : (n += 1) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return;
        if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) {
            std.debug.print("line {d}\n  git:   {?s}\n  relic: {?s}\n", .{ n, x, y });
            if (x != null and y != null) {
                var i: usize = 0;
                while (i < x.?.len and i < y.?.len and x.?[i] == y.?[i]) i += 1;
                std.debug.print("  from byte {d}: git {s} | relic {s}\n", .{ i, x.?[i..@min(x.?.len, i + 60)], y.?[i..@min(y.?.len, i + 60)] });
            }
            return;
        }
    }
}

/// `compare` with one more argument after `args`.
fn compareWith(gpa: Allocator, io: Io, git: *testgit.Repo, command: Command, args: []const []const u8, last: []const u8) !void {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, args);
    try all.append(gpa, last);
    return compare(gpa, io, git, command, all.items);
}

/// `git <command> <args>` and the library's listing, byte for byte.
fn compare(gpa: Allocator, io: Io, git: *testgit.Repo, command: Command, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, switch (command) {
        .for_each_ref => "for-each-ref",
        .branch => "branch",
        .tag => "tag",
    });
    if (command != .for_each_ref) try argv.append(gpa, "--list");
    try argv.appendSlice(gpa, args);
    const theirs = try git.run(io, argv.items);
    defer gpa.free(theirs);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try parseArgs(arena, io, git, args);
    var repo = try Repository.open(gpa, io, git.dir, .{});
    defer repo.deinit(io);
    var ours: Io.Writer.Allocating = .init(gpa);
    defer ours.deinit();
    var context: filter.Context = .{ .clock = clock };
    context.clock.locale_date_full_year = try localeDateFullYear(gpa, io, git);
    switch (command) {
        .for_each_ref => {
            var keys: std.ArrayList(filter.SortKey) = .empty;
            if (!p.no_sort) {
                try keys.append(arena, .{ .atom = "refname" });
                try keys.appendSlice(arena, p.sort.items);
            }
            try filter.listRefs(gpa, io, &repo, .{
                .filter = .{
                    .kinds = if (p.root_refs) .{ .branches = true, .remotes = true, .tags = true, .others = true, .detached_head = true, .root_refs = true } else .regular,
                    .patterns = p.patterns.items,
                    .ignore_case = p.ignore_case,
                    .exclude = p.exclude.items,
                    .points_at = p.points_at.items,
                    .contains = p.contains.items,
                    .no_contains = p.no_contains.items,
                    .merged = p.merged.items,
                    .no_merged = p.no_merged.items,
                    .start_after = p.start_after,
                },
                .sort = keys.items,
                .sort_options = .{ .ignore_case = p.ignore_case },
                .format = p.format,
                .quote = p.quote,
                .count = p.count,
                .omit_empty = p.omit_empty,
                .context = context,
            }, &ours.writer);
        },
        .branch => try filter.listBranches(gpa, io, &repo, .{
            .which = p.which,
            .patterns = p.patterns.items,
            .verbose = p.verbose,
            .abbrev = p.abbrev,
            .sort = p.sort.items,
            .no_sort = p.no_sort,
            .ignore_case = p.ignore_case,
            .contains = p.contains.items,
            .no_contains = p.no_contains.items,
            .merged = p.merged.items,
            .no_merged = p.no_merged.items,
            .points_at = p.points_at.items,
            .format = p.format,
            .omit_empty = p.omit_empty,
            .context = context,
        }, &ours.writer),
        .tag => try filter.listTags(gpa, io, &repo, .{
            .patterns = p.patterns.items,
            .lines = p.lines,
            .sort = p.sort.items,
            .no_sort = p.no_sort,
            .ignore_case = p.ignore_case,
            .contains = p.contains.items,
            .no_contains = p.no_contains.items,
            .merged = p.merged.items,
            .no_merged = p.no_merged.items,
            .points_at = p.points_at.items,
            .format = p.format,
            .omit_empty = p.omit_empty,
            .context = context,
        }, &ours.writer),
    }
    if (!std.mem.eql(u8, theirs, ours.written())) {
        std.debug.print("git {s}", .{argv.items[0]});
        for (args) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print(": the listings differ\n", .{});
        reportFirstDifference(theirs, ours.written());
        return error.TestExpectedEqual;
    }
}

/// Git uses the host C library for `%x`; macOS releases disagree on its
/// year width. Supply that locale property separately from the ref dates.
fn localeDateFullYear(gpa: Allocator, io: Io, git: *testgit.Repo) !bool {
    if (builtin.target.os.tag == .windows) return false;
    const date = try git.line(io, &.{ "log", "-1", "--format=%cd", "--date=format:%x" });
    defer gpa.free(date);
    const slash = std.mem.findScalarLast(u8, date, '/') orelse return error.TestUnexpectedResult;
    return date.len - slash - 1 == 4;
}

/// A repository with every kind of ref the atoms tell apart: branches
/// ahead, behind and gone from their upstreams, one following a local
/// branch, nested and non-ASCII names, annotated, lightweight and nested
/// tags, tags on a tree and a blob, a symbolic remote `HEAD`, notes, packed
/// and loose refs, a mailmapped author and a second worktree.
fn buildFixture(gpa: Allocator, io: Io, git: *testgit.Repo, env: *std.process.Environ.Map) !void {
    git.environ = env;
    var date: i64 = testgit.fixture_date;
    const step = struct {
        fn next(e: *std.process.Environ.Map, d: *i64, by: i64) !void {
            d.* += by;
            try testgit.setDate(e, d.*);
        }
    }.next;
    try git.writeFile(io, "a.txt", "one\n");
    try git.exec(io, &.{ "add", "a.txt" });
    try git.exec(io, &.{ "commit", "-q", "-m", "First commit\n\nWith a body\nof two lines.\n" });
    try git.exec(io, &.{ "branch", "old" });
    try step(env, &date, 3600);
    try git.writeFile(io, "a.txt", "two\n");
    try git.exec(io, &.{ "-c", "user.name=Other Person", "-c", "user.email=other@example.com", "commit", "-q", "-am", "Second: a subject\nthat runs on\n\nand a body" });
    try git.writeFile(io, ".mailmap", "Proper Name <proper@example.com> <other@example.com>\n");
    try step(env, &date, 86400 * 3);
    try git.exec(io, &.{ "tag", "-a", "v1.0", "-m", "Release 1.0\n\nNotes for it.\n-----BEGIN PGP SIGNATURE-----\nnot really\n-----END PGP SIGNATURE-----\n" });
    try git.exec(io, &.{ "tag", "v1.0-rc1", "HEAD~1" });
    try git.exec(io, &.{ "tag", "-a", "v1.0-rc2", "-m", "rc2", "HEAD~1" });
    try git.exec(io, &.{ "tag", "v1.2" });
    try git.exec(io, &.{ "tag", "v1.10" });
    // git peels a tag of a tag all the way for `*` atoms and `--points-at`
    // from 2.44 on, and one step before
    if (try testgit.gitAtLeast(gpa, io, 2, 44)) try git.exec(io, &.{ "tag", "-a", "v2.0", "-m", "A tag of a tag", "v1.0" });
    try git.exec(io, &.{ "tag", "tree-tag", "HEAD^{tree}" });
    try git.exec(io, &.{ "tag", "-a", "blob-tag", "-m", "A tag of a blob", "HEAD:a.txt" });
    try git.exec(io, &.{ "tag", "Upper" });
    try git.exec(io, &.{ "checkout", "-q", "-b", "feature" });
    try step(env, &date, 7200);
    try git.writeFile(io, "b.txt", "feature\n");
    try git.exec(io, &.{ "add", "b.txt" });
    try git.exec(io, &.{ "commit", "-q", "-m", "Feature work" });
    try step(env, &date, 600);
    try git.writeFile(io, "b.txt", "feature, more\n");
    try git.exec(io, &.{ "commit", "-q", "-am", "More feature work" });
    try git.exec(io, &.{ "branch", "fix/one", "HEAD~1" });
    try git.exec(io, &.{ "branch", "caf\xc3\xa9", "HEAD~1" });
    try git.exec(io, &.{ "branch", "local" });
    try git.exec(io, &.{ "checkout", "-q", "main" });
    try step(env, &date, 86400 * 30);
    try git.writeFile(io, "c.txt", "main\n");
    try git.exec(io, &.{ "add", "c.txt" });
    try git.exec(io, &.{ "commit", "-q", "-m", "Main moves on" });
    try git.exec(io, &.{ "notes", "add", "-m", "a note", "HEAD" });

    try git.exec(io, &.{ "config", "remote.origin.url", "https://example.com/repo.git" });
    try git.exec(io, &.{ "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" });
    try git.exec(io, &.{ "update-ref", "refs/remotes/origin/main", "HEAD~1" });
    try git.exec(io, &.{ "update-ref", "refs/remotes/origin/feature", "feature~1" });
    try git.exec(io, &.{ "update-ref", "refs/remotes/origin/old", "feature" });
    // before 2.40, git shortened refs/remotes/<name>/HEAD to <name>/HEAD
    if (try testgit.gitAtLeast(gpa, io, 2, 40)) try git.exec(io, &.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    for ([_][2][]const u8{
        .{ "branch.main.remote", "origin" },            .{ "branch.main.merge", "refs/heads/main" },
        .{ "branch.feature.remote", "origin" },         .{ "branch.feature.merge", "refs/heads/feature" },
        .{ "branch.old.remote", "origin" },             .{ "branch.old.merge", "refs/heads/old" },
        .{ "branch.fix/one.remote", "origin" },         .{ "branch.fix/one.merge", "refs/heads/gone" },
        .{ "branch.local.remote", "." },                .{ "branch.local.merge", "refs/heads/main" },
        .{ "branch.caf\xc3\xa9.pushRemote", "origin" },
    }) |pair| try git.exec(io, &.{ "config", pair[0], pair[1] });
    try git.exec(io, &.{ "pack-refs", "--all" });
    // a loose ref over a packed one, and one only loose
    try step(env, &date, 60);
    try git.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "Loose again" });
    try git.exec(io, &.{ "update-ref", "refs/other/thing", "HEAD~2" });
    try git.exec(io, &.{ "worktree", "add", "-q", "-b", "wt", "elsewhere", "old" });
}

fn fixture(gpa: Allocator, io: Io) !struct { git: testgit.Repo, env: *std.process.Environ.Map } {
    var git = try testgit.Repo.init(gpa, io, &.{});
    errdefer git.deinit();
    const env = try gpa.create(std.process.Environ.Map);
    errdefer gpa.destroy(env);
    env.* = try git.isolated.?.clone(gpa);
    errdefer env.deinit();
    var now_buf: [32]u8 = undefined;
    try env.put("GIT_TEST_DATE_NOW", try std.mem.print(&now_buf, "{d}", .{now}));
    try env.put("TZ", "UTC");
    try buildFixture(gpa, io, &git, env);
    return .{ .git = git, .env = env };
}

fn release(gpa: Allocator, f: anytype) void {
    f.git.deinit();
    f.env.deinit();
    gpa.destroy(f.env);
}

const every_ref_atom =
    "%(refname)|%(refname:short)|%(refname:lstrip=1)|%(refname:lstrip=-1)|%(refname:strip=2)|%(refname:rstrip=1)|%(refname:rstrip=-2)|%(refname:lstrip=9)" ++
    "|%(objecttype)|%(objectsize)|%(objectname)|%(objectname:short)|%(objectname:short=10)|%(objectname:short=2)" ++
    "|%(tree)|%(tree:short)|%(parent)|%(parent:short)|%(numparent)|%(object)|%(type)|%(tag)" ++
    "|%(author)|%(authorname)|%(authoremail)|%(authordate)|%(committer)|%(committername)|%(committeremail)|%(committerdate)" ++
    "|%(tagger)|%(taggername)|%(taggeremail)|%(taggerdate)|%(creator)|%(creatordate)" ++
    "|%(subject)|%(body)|%(contents)|%(contents:subject)|%(contents:body)|%(contents:signature)|%(contents:lines=1)|%(contents:lines=3)" ++
    "|%(upstream)|%(upstream:short)|%(upstream:track)|%(upstream:trackshort)|%(upstream:track,nobracket)|%(upstream:lstrip=2)" ++
    "|%(push)|%(push:short)|%(push:track)|%(push:trackshort)|%(push:remotename)" ++
    "|%(symref)|%(symref:short)|%(symref:rstrip=1)|%(flag)|%(HEAD)|%(color:red)%(color:reset)|%(worktreepath)" ++
    "|%(*objectname)|%(*objecttype)|%(*objectsize)|%(*objectname:short)|%(*subject)|%(*authorname)|%(*committerdate)|%(*creatordate)|%(*tagger)|%(*refname)|%(*body)" ++
    "|%%|%(refname)%%(refname)|%41|%x|%(upstream:remotename)";

test "every atom git offers for refs comes out as git's for-each-ref writes it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try fixture(gpa, io);
    defer release(gpa, &f);
    const git = &f.git;
    try compare(gpa, io, git, .for_each_ref, &.{});
    try compare(gpa, io, git, .for_each_ref, &.{"--format=" ++ every_ref_atom});
    // dates in every mode git can show without a terminal or a locale
    inline for (.{ "", ":default", ":iso", ":iso8601", ":rfc", ":short", ":raw", ":unix", ":relative", ":local", ":iso-local", ":raw-local", ":format:%Y-%m-%d %H:%M:%S %z %j %a %b %A %B %%", ":format-local:%Y%m%d %s", ":auto:iso" }) |mode| {
        try compare(gpa, io, git, .for_each_ref, &.{"--format=%(authordate" ++ mode ++ ")|%(committerdate" ++ mode ++ ")|%(taggerdate" ++ mode ++ ")|%(creatordate" ++ mode ++ ")"});
    }
    // the C99 and POSIX conversions, where the C library has them
    if (builtin.target.os.tag != .windows) {
        try compare(gpa, io, git, .for_each_ref, &.{"--format=%(creatordate:format:%F %T %D %e %R %r %u %V %G %g %C %y %U %W %w %I %p %n %t)|%(creatordate:format-local:%c %x %X %h %k %l)"});
    }
    // a time in UTC is written with `Z` from 2.45 on
    if (try testgit.gitAtLeast(gpa, io, 2, 45)) {
        try compare(gpa, io, git, .for_each_ref, &.{"--format=%(authordate:iso-strict)|%(taggerdate:iso8601-strict)|%(creatordate:iso-strict-local)"});
    }
    try compare(gpa, io, git, .for_each_ref, &.{"--format=%(contents:size)|%(objectsize:disk)|%(deltabase)|%(upstream:remoteref)|%(push:remoteref)"});
    try compare(gpa, io, git, .for_each_ref, &.{"--format=%(subject:sanitize)|%(authoremail:trim)|%(authoremail:localpart)|%(*authoremail:trim)|%(raw:size)|%(authordate:human)"});
    try compare(gpa, io, git, .for_each_ref, &.{ "--perl", "--format=%(raw)" });
    if (try testgit.gitAtLeast(gpa, io, 2, 42)) {
        try compare(gpa, io, git, .for_each_ref, &.{"--format=%(describe)|%(describe:tags)|%(describe:abbrev=4)|%(describe:match=v1*,exclude=*rc*)|%(describe:tags=no,abbrev=0)|%(*describe)"});
        try compare(gpa, io, git, .for_each_ref, &.{"--format=%(signature)|%(signature:grade)|%(signature:signer)|%(signature:key)|%(signature:fingerprint)|%(signature:primarykeyfingerprint)|%(signature:trustlevel)"});
    }
    if (try testgit.gitAtLeast(gpa, io, 2, 43)) {
        try compare(gpa, io, git, .for_each_ref, &.{"--format=%(authorname:mailmap)|%(authoremail:mailmap)|%(authoremail:mailmap,trim)|%(authoremail:localpart,mailmap)|%(committername:mailmap)|%(*authorname:mailmap)"});
    }
    // git pack-objects makes a delta and the sizes on disk change
    try git.exec(io, &.{ "repack", "-adq" });
    try compare(gpa, io, git, .for_each_ref, &.{"--format=%(objectsize:disk)|%(deltabase)|%(*objectsize:disk)|%(*deltabase)"});
}

test "blocks, quoting and literals are written as git writes them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try fixture(gpa, io);
    defer release(gpa, &f);
    const git = &f.git;
    const blocks = "%(align:30)%(refname:short)%(end)|%(align:30,right)%(refname:short)%(end)|%(align:width=31,position=middle)%(refname:short)%(end)|%(align:5)%(refname)%(end)" ++
        "|%(if)%(upstream)%(then)tracks %(upstream:short)%(else)tracks nothing%(end)" ++
        "|%(if:equals=commit)%(objecttype)%(then)a commit%(end)" ++
        "|%(if:notequals=refs/heads)%(refname:rstrip=-2)%(then)not a branch%(else)a branch%(end)" ++
        "|%(if)%(*objectname)%(then)peels to %(*objecttype)%(end)" ++
        "|%(align:20,right)%(if)%(HEAD)%(then)[%(refname:short)]%(else)%(refname:short)%(end)%(end)" ++
        "|%(if)%(symref)%(then)%(if)%(HEAD)%(then)nested%(else)no%(end)%(end)";
    try compare(gpa, io, git, .for_each_ref, &.{"--format=" ++ blocks});
    inline for (.{ "--shell", "--perl", "--python", "--tcl" }) |quote| {
        try compare(gpa, io, git, .for_each_ref, &.{ quote, "--format=ref=%(refname) subject=%(subject) body=%(contents) " ++ blocks });
    }
    try compare(gpa, io, git, .for_each_ref, &.{ "--shell", "--format=%(refname)!%(contents:body)'" });
    if (try testgit.gitAtLeast(gpa, io, 2, 41)) {
        try compare(gpa, io, git, .for_each_ref, &.{ "--omit-empty", "--format=%(if)%(upstream)%(then)%(refname)%(end)" });
    }
    try compare(gpa, io, git, .for_each_ref, &.{ "--count=3", "--format=%(refname)" });
}

test "sort keys, version sort and versionsort.suffix order refs as git orders them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try fixture(gpa, io);
    defer release(gpa, &f);
    const git = &f.git;
    const format = "--format=%(refname) %(objectname:short) %(creatordate:unix)";
    inline for (.{
        &.{"--sort=refname"},
        &.{"--sort=-refname"},
        &.{"--sort=objectsize"},
        &.{"--sort=-objectsize"},
        &.{"--sort=creatordate"},
        &.{"--sort=-creatordate"},
        &.{ "--sort=objecttype", "--sort=-creatordate" },
        &.{ "--sort=-creatordate", "--sort=objecttype" },
        &.{"--sort=version:refname"},
        &.{"--sort=-v:refname"},
        &.{"--sort=authorname"},
        &.{"--sort=upstream"},
        &.{"--sort=*objectname"},
        &.{"--sort=numparent"},
        &.{"--sort=HEAD"},
        &.{ "--sort=refname", "--ignore-case" },
    }) |args| try compareWith(gpa, io, git, .for_each_ref, args, format);
    if (try testgit.gitAtLeast(gpa, io, 2, 43)) {
        try compare(gpa, io, git, .for_each_ref, &.{ "--sort=contents:size", format });
    }
    if (try testgit.gitAtLeast(gpa, io, 2, 44)) try compare(gpa, io, git, .for_each_ref, &.{ "--no-sort", format });
    try git.exec(io, &.{ "config", "versionsort.suffix", "-rc" });
    try compare(gpa, io, git, .tag, &.{"--sort=version:refname"});
    try compare(gpa, io, git, .tag, &.{"--sort=-version:refname"});
    try git.exec(io, &.{ "config", "--unset", "versionsort.suffix" });
    try git.exec(io, &.{ "config", "versionsort.prereleaseSuffix", "-rc2" });
    try git.exec(io, &.{ "config", "--add", "versionsort.prereleaseSuffix", "-rc1" });
    try compare(gpa, io, git, .tag, &.{"--sort=v:refname"});
    try git.exec(io, &.{ "config", "tag.sort", "-version:refname" });
    try compare(gpa, io, git, .tag, &.{});
    try compare(gpa, io, git, .tag, &.{"--sort=refname"});
    try git.exec(io, &.{ "config", "branch.sort", "-committerdate" });
    try compare(gpa, io, git, .branch, &.{"-a"});
}

test "patterns, exclusions and reachability choose refs as git chooses them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try fixture(gpa, io);
    defer release(gpa, &f);
    const git = &f.git;
    const format = "--format=%(refname)";
    inline for (.{
        &.{"refs/heads"},
        &.{"refs/heads/"},
        &.{"refs/heads/f"},
        &.{"refs/heads/f*"},
        &.{"refs/heads/fix"},
        &.{ "refs/tags/v1*", "refs/remotes" },
        &.{"refs/*/main"},
        // git's wildmatch: a `**` that is not a whole component is a `*`,
        // and a pattern too long for one call on the stack is compiled.
        &.{"refs/remo**/main"},
        &.{"refs/heads/[f]*"},
        &.{"refs/*/f?x*"},
        &.{"refs/heads/" ++ repeat("*", 1100)},
        &.{ "--ignore-case", "refs/tags/[U]pper" },
        &.{ "--ignore-case", "refs/tags/upper" },
        &.{"--points-at=main"},
        &.{"--points-at=v1.0"},
        &.{"--points-at=main~2"},
        &.{"--contains=main~2"},
        &.{"--contains=feature"},
        &.{ "--contains=main", "--contains=feature" },
        &.{"--no-contains=feature~1"},
        &.{"--merged=main"},
        &.{"--merged=feature"},
        &.{ "--merged=main", "--merged=feature" },
        &.{"--no-merged=main"},
        &.{ "--merged=feature", "--no-merged=main~2" },
    }) |args| try compareWith(gpa, io, git, .for_each_ref, args, format);
    if (try testgit.gitAtLeast(gpa, io, 2, 42)) {
        try compare(gpa, io, git, .for_each_ref, &.{ "--exclude=refs/tags", "--exclude=refs/remotes/origin/old", format });
    }
    if (try testgit.gitAtLeast(gpa, io, 2, 45)) {
        try git.exec(io, &.{ "update-ref", "ORIG_HEAD", "main~1" });
        try compare(gpa, io, git, .for_each_ref, &.{ "--include-root-refs", format ++ " %(objectname)" });
    }
    if (try testgit.gitAtLeast(gpa, io, 2, 51)) {
        try compare(gpa, io, git, .for_each_ref, &.{ "--start-after=refs/heads/main", format });
        try compare(gpa, io, git, .for_each_ref, &.{ "--start-after=refs/heads/f", format });
    }
}

test "branch and tag listings read as git branch and git tag print them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try fixture(gpa, io);
    defer release(gpa, &f);
    const git = &f.git;
    inline for (.{
        &.{},
        &.{"-a"},
        &.{"-r"},
        &.{"-v"},
        &.{"-vv"},
        &.{ "-a", "-v" },
        &.{ "-a", "-vv" },
        &.{ "-r", "-v" },
        &.{ "-v", "--abbrev=10" },
        &.{ "-v", "--no-abbrev" },
        &.{"f*"},
        &.{ "-a", "*main" },
        &.{ "-i", "CAF*" },
        &.{"--contains=feature~1"},
        &.{"--merged=main"},
        &.{"--no-merged=main"},
        &.{"--points-at=main"},
        &.{"--sort=-committerdate"},
        &.{ "--format=%(refname:short) %(upstream:track)", "-a" },
    }) |args| try compare(gpa, io, git, .branch, args);
    inline for (.{
        &.{},
        &.{"v1*"},
        &.{ "-i", "upper" },
        &.{"-n"},
        &.{"-n3"},
        &.{"--sort=-taggerdate"},
        &.{"--contains=main~2"},
        &.{"--no-contains=main~3"},
        &.{"--merged=main~2"},
        &.{"--points-at=main~2"},
        &.{"--format=%(refname:strip=2) %(objecttype) %(*objecttype)"},
    }) |args| try compare(gpa, io, git, .tag, args);

    // a detached HEAD, from a checkout git records in the reflog
    try git.exec(io, &.{ "checkout", "-q", "v1.0" });
    try compare(gpa, io, git, .branch, &.{});
    try compare(gpa, io, git, .branch, &.{"-v"});
    try git.exec(io, &.{ "checkout", "-q", "HEAD~1" });
    try compare(gpa, io, git, .branch, &.{"-a"});
    try git.exec(io, &.{ "checkout", "-q", "main" });
    try git.exec(io, &.{ "checkout", "-q", "--detach" });
    try compare(gpa, io, git, .branch, &.{});
}

test "ahead-behind and is-base answer as git's do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!try testgit.gitAtLeast(gpa, io, 2, 41)) return error.SkipZigTest;
    var f = try fixture(gpa, io);
    defer release(gpa, &f);
    const git = &f.git;
    try compare(gpa, io, git, .for_each_ref, &.{"--format=%(refname) %(ahead-behind:main) %(ahead-behind:feature) %(ahead-behind:old)"});
    try compare(gpa, io, git, .for_each_ref, &.{ "--sort=-ahead-behind:main", "--format=%(refname) %(ahead-behind:main)" });
    if (try testgit.gitAtLeast(gpa, io, 2, 47)) {
        try compare(gpa, io, git, .for_each_ref, &.{ "refs/heads", "--format=%(refname)%(is-base:feature)%(is-base:main) %(is-base:old)" });
    }
}

test "a format git refuses is refused by name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try fixture(gpa, io);
    defer release(gpa, &f);
    var repo = try Repository.open(gpa, io, f.git.dir, .{});
    defer repo.deinit(io);
    var l = filter.Listing.init(gpa, io, &repo, .{});
    defer l.deinit();
    try std.testing.expectError(error.UnknownField, l.parseFormat("%(nothing)", .none));
    try std.testing.expectError(error.MalformedFormat, l.parseFormat("%(refname", .none));
    try std.testing.expectError(error.BadFieldArgument, l.parseFormat("%(refname:long)", .none));
    try std.testing.expectError(error.BadFieldArgument, l.parseFormat("%(objecttype:x)", .none));
    try std.testing.expectError(error.BadFieldArgument, l.parseFormat("%(align)", .none));
    try std.testing.expectError(error.BadFieldArgument, l.parseFormat("%(color:nonsense)", .none));
    try std.testing.expectError(error.RawNeedsBinarySafeQuote, l.parseFormat("%(raw)", .shell));
    try std.testing.expectError(error.RejectedField, l.parseFormat("%(rest)", .none));
    try std.testing.expectError(error.UnknownDateFormat, l.parseFormat("%(authordate:sometime)", .none));
    try std.testing.expectError(error.UnknownCommit, l.parseFormat("%(ahead-behind:nowhere)", .none));
    try l.collect(.{});
    const unbalanced = try l.parseFormat("%(if)%(refname)", .none);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(error.UnbalancedBlock, l.formatItem(gpa, 0, unbalanced, &out));
    const stray = try l.parseFormat("%(end)", .none);
    try std.testing.expectError(error.UnbalancedBlock, l.formatItem(gpa, 0, stray, &out));
}

test "for-each-ref from a linked worktree lists what git's lists, in both ref formats" {
    try testgit.eachRefFormat(struct {
        fn inFormat(format: testgit.RefFormat) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var main = try testgit.Repo.init(gpa, io, format.initArgs());
            defer main.deinit();
            try main.writeFile(io, "f", "1\n");
            try main.exec(io, &.{ "add", "f" });
            try main.exec(io, &.{ "commit", "-q", "-m", "one" });
            try main.writeFile(io, "f", "2\n");
            try main.exec(io, &.{ "commit", "-q", "-am", "two" });
            try main.exec(io, &.{ "tag", "-a", "-m", "the tag", "v1" });
            try main.exec(io, &.{ "worktree", "add", "-q", "-b", "wt", "linked", "HEAD~1" });
            // Each worktree's own refs: the main worktree's bisection and a
            // ref of the linked worktree's, which neither lists for the
            // other.
            try main.exec(io, &.{ "bisect", "start", "HEAD", "HEAD~1" });
            var linked_dir = try main.dir.openDir(io, "linked", .{ .iterate = true });
            defer linked_dir.close(io);
            var linked: testgit.Repo = .{ .gpa = gpa, .tmp = undefined, .dir = linked_dir };
            try linked.exec(io, &.{ "update-ref", "refs/worktree/mine", "HEAD" });
            try linked.exec(io, &.{ "update-ref", "refs/bisect/theirs", "HEAD" });

            for ([_]*testgit.Repo{ &linked, &main }) |r| {
                try compare(gpa, io, r, .for_each_ref, &.{});
                try compare(gpa, io, r, .for_each_ref, &.{"--format=%(refname) %(objectname) %(HEAD) %(worktreepath) %(*objectname)"});
                try compare(gpa, io, r, .for_each_ref, &.{ "--format=%(refname)", "refs/bisect/", "refs/worktree/" });
                if (try testgit.gitAtLeast(gpa, io, 2, 46)) {
                    try compare(gpa, io, r, .for_each_ref, &.{ "--include-root-refs", "--format=%(refname) %(objectname) %(symref)" });
                }
            }
        }
    }.inFormat);
}
