//! A revision expression, read as git's `get_oid_with_context` reads it:
//! the name `git rev-parse <expr>` prints for it.
//!
//! - an object name, whole or abbreviated to four digits or more, or the
//!   `<tag>-<n>-g<hex>` that `git describe` writes;
//! - a ref, found by git's rules — as written, then under `refs/`,
//!   `refs/tags/`, `refs/heads/`, `refs/remotes/` and
//!   `refs/remotes/<name>/HEAD` — and `@` for `HEAD`;
//! - `<ref>@{<n>}`, the reflog's n-th entry back, `@{<n>}` the current
//!   branch's; `@{-<n>}`, the n-th branch checked out before;
//!   `<branch>@{upstream}` (`@{u}`) and `<branch>@{push}`;
//! - `<rev>^<n>`, `<rev>~<n>`, `<rev>^{<type>}`, `<rev>^{}` and
//!   `<rev>^{/<regex>}`, and `:/<regex>` from every ref, with `:/!-` to
//!   negate and `:/!!` for a literal `!`;
//! - `<rev>:<path>`, and `:<path>` or `:<n>:<path>` from the index.
//!
//! A reflog selected by a date, `@{yesterday}`, is refused by name: reading
//! git's approximate dates is its own undertaking. A path relative to a
//! working directory (`:./x`) is refused too; there is none here to be
//! relative to.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const repo_mod = @import("repo.zig");
const refs_mod = @import("refs.zig");
const revwalk = @import("revwalk.zig");
const remote_mod = @import("remote.zig");
const ere = @import("ere.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from reading an expression.
pub const Error = error{
    /// Not an expression git reads, or one that names nothing here.
    BadRevision,
    /// An abbreviation more than one object begins with.
    AmbiguousRevision,
    /// A reflog entry chosen by a date.
    RevisionDateUnsupported,
    /// A path relative to a working directory: `:./x`, `HEAD:../x`.
    RelativePathUnsupported,
} || ere.Error || Allocator.Error || Io.Cancelable;

/// What `expr` names in `repo`.
pub fn resolve(gpa: Allocator, io: Io, repo: *Repository, expr: []const u8) Error!Oid {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r: Resolver = .{ .gpa = gpa, .a = arena_state.allocator(), .io = io, .repo = repo };
    return r.withContext(expr);
}

const Resolver = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,

    fn withContext(r: *Resolver, name: []const u8) Error!Oid {
        if (name.len == 0) return error.BadRevision;
        if (name[0] == ':') {
            if (name.len >= 2 and name[1] == '/') return r.oneline(name[2..], null);
            // `:<n>:<path>` or `:<path>`: the index.
            var stage: u2 = 0;
            var path = name[1..];
            if (path.len >= 2 and path[1] == ':' and path[0] >= '0' and path[0] <= '3') {
                stage = @intCast(path[0] - '0');
                path = path[2..];
            }
            return r.fromIndex(stage, path);
        }
        // `<rev>:<path>`: the first colon outside braces.
        var depth: usize = 0;
        for (name, 0..) |c, i| {
            if (c == '{') depth += 1 else if (depth > 0 and c == '}') depth -= 1 else if (depth == 0 and c == ':') {
                const tree = try r.peelTo(try r.one(name[0..i]), .tree);
                return r.inTree(tree, name[i + 1 ..]);
            }
        }
        return r.one(name);
    }

    /// git's `get_oid_1`: suffixes from the end, then the name.
    fn one(r: *Resolver, name: []const u8) Error!Oid {
        if (name.len == 0) return error.BadRevision;
        // `^{...}`
        if (name[name.len - 1] == '}') {
            var sp = name.len - 1;
            while (sp > 0) : (sp -= 1) {
                if (name[sp] == '{' and name[sp - 1] == '^') {
                    return r.peelOnion(try r.one(name[0 .. sp - 1]), name[sp + 1 .. name.len - 1]);
                }
            }
        }
        // `^<n>` and `~<n>`.
        var cp = name.len;
        while (cp > 0 and std.ascii.isDigit(name[cp - 1])) cp -= 1;
        if (cp > 0 and (name[cp - 1] == '^' or name[cp - 1] == '~')) {
            const kind = name[cp - 1];
            const digits = name[cp..];
            const n: u32 = if (digits.len == 0) 1 else std.fmt.parseUnsigned(u32, digits, 10) catch return error.BadRevision;
            const base = try r.one(name[0 .. cp - 1]);
            return if (kind == '^') r.parent(base, n) else r.ancestor(base, n);
        }
        return r.basic(name);
    }

    /// A name with no suffix: `@{...}`, an object name, a ref, a `describe`
    /// name, an abbreviation.
    fn basic(r: *Resolver, name: []const u8) Error!Oid {
        const kind = r.repo.kind;
        if (name.len == kind.hexLen()) {
            if (Oid.parse(kind, name)) |oid| return oid else |_| {}
        }
        if (std.mem.lastIndexOf(u8, name, "@{")) |at| {
            if (name[name.len - 1] != '}') return error.BadRevision;
            return r.reflogSelect(name[0..at], name[at + 2 .. name.len - 1]);
        }
        if (std.mem.eql(u8, name, "@")) return r.ref("HEAD");
        if (try r.dwim(name)) |oid| return oid;
        // `git describe`'s `<tag>-<n>-g<hex>`.
        if (std.mem.lastIndexOf(u8, name, "-g")) |g| {
            const hex = name[g + 2 ..];
            if (hex.len >= 4 and allHex(hex)) return r.short(hex);
        }
        if (name.len >= 4 and allHex(name)) return r.short(name);
        return error.BadRevision;
    }

    fn allHex(text: []const u8) bool {
        for (text) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    fn short(r: *Resolver, hex: []const u8) Error!Oid {
        var lower: [hash.max_hex_len]u8 = undefined;
        if (hex.len > lower.len) return error.BadRevision;
        for (hex, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        return r.repo.odb.findPrefix(r.io, lower[0..hex.len]) catch |err| switch (err) {
            error.AmbiguousPrefix => error.AmbiguousRevision,
            error.ObjectNotFound => error.BadRevision,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.BadRevision,
        };
    }

    /// git's `ref_rev_parse_rules`, in order: the first that names a ref.
    fn dwim(r: *Resolver, name: []const u8) Error!?Oid {
        const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
        inline for (rules) |rule| {
            const full = try std.fmt.allocPrint(r.a, rule, .{name});
            if (try r.refMaybe(full)) |oid| return oid;
        }
        return null;
    }

    /// The full ref name `name` resolves to, by the same rules.
    fn dwimName(r: *Resolver, name: []const u8) Error!?[]const u8 {
        const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
        inline for (rules) |rule| {
            const full = try std.fmt.allocPrint(r.a, rule, .{name});
            if (try r.refMaybe(full) != null) return full;
        }
        return null;
    }

    fn refMaybe(r: *Resolver, full: []const u8) Error!?Oid {
        // Only names a ref can have: `HEAD` and its kind at the top, and
        // everything under `refs/`.
        if (!std.mem.startsWith(u8, full, "refs/")) {
            for (full) |c| if (!(std.ascii.isUpper(c) or c == '_')) return null;
        }
        const resolved = r.repo.refs.resolve(r.gpa, r.io, full) catch return null;
        const got = resolved orelse return null;
        r.gpa.free(got.name);
        return got.oid;
    }

    fn ref(r: *Resolver, full: []const u8) Error!Oid {
        return (try r.refMaybe(full)) orelse error.BadRevision;
    }

    /// `<ref>@{<what>}`.
    fn reflogSelect(r: *Resolver, base: []const u8, what: []const u8) Error!Oid {
        if (std.ascii.eqlIgnoreCase(what, "u") or std.ascii.eqlIgnoreCase(what, "upstream")) {
            return r.ref(try r.upstreamOf(try r.branchOf(base)));
        }
        if (std.ascii.eqlIgnoreCase(what, "push")) {
            return r.ref(try r.pushOf(try r.branchOf(base)));
        }
        if (what.len > 1 and what[0] == '-') {
            if (base.len != 0) return error.BadRevision;
            const n = std.fmt.parseUnsigned(u32, what[1..], 10) catch return error.BadRevision;
            return r.previousBranch(n);
        }
        const n = std.fmt.parseUnsigned(u32, what, 10) catch return error.RevisionDateUnsupported;
        // `@{<n>}` with nothing before it is the current branch's reflog.
        const full = if (base.len == 0)
            try r.currentBranchRef()
        else
            (try r.dwimName(base)) orelse return error.BadRevision;
        var log = r.repo.readLog(r.io, full) catch return error.BadRevision;
        defer log.deinit();
        if (log.entries.len == 0) return error.BadRevision;
        if (n == 0) return log.entries[log.entries.len - 1].new;
        if (n > log.entries.len) return error.BadRevision;
        const entry = log.entries[log.entries.len - n];
        return entry.old;
    }

    fn currentBranchRef(r: *Resolver) Error![]const u8 {
        const head = r.repo.refs.read(r.gpa, r.io, "HEAD") catch return error.BadRevision;
        const h = head orelse return error.BadRevision;
        return switch (h) {
            .symbolic => |target| {
                defer r.gpa.free(target);
                return r.a.dupe(u8, target);
            },
            .direct => error.BadRevision,
        };
    }

    /// The branch `base` names — the current one when it is empty — as a
    /// short name.
    fn branchOf(r: *Resolver, base: []const u8) Error![]const u8 {
        if (base.len == 0 or std.mem.eql(u8, base, "HEAD") or std.mem.eql(u8, base, "@")) {
            const full = try r.currentBranchRef();
            if (!std.mem.startsWith(u8, full, "refs/heads/")) return error.BadRevision;
            return full["refs/heads/".len..];
        }
        if (std.mem.startsWith(u8, base, "refs/heads/")) return base["refs/heads/".len..];
        return base;
    }

    /// `branch.<b>.merge` through `branch.<b>.remote`'s fetch refspecs: the
    /// ref that tracks it here.
    fn upstreamOf(r: *Resolver, branch: []const u8) Error![]const u8 {
        var b = remote_mod.Branch.get(r.gpa, &r.repo.config, branch) catch return error.BadRevision;
        defer b.deinit();
        const remote_name = b.remote orelse return error.BadRevision;
        if (b.merge.len == 0) return error.BadRevision;
        const merge = try r.a.dupe(u8, b.merge[0]);
        if (std.mem.eql(u8, remote_name, ".")) return merge;
        var remote = remote_mod.Remote.get(r.gpa, &r.repo.config, remote_name) catch return error.BadRevision;
        defer remote.deinit();
        for (remote.fetch) |spec| {
            if (try spec.mapSource(r.a, merge)) |tracking| return tracking;
        }
        return error.BadRevision;
    }

    /// Where `git push` would send `branch`, as the ref that tracks it:
    /// `push.default` read as git reads it.
    fn pushOf(r: *Resolver, branch: []const u8) Error![]const u8 {
        var b = remote_mod.Branch.get(r.gpa, &r.repo.config, branch) catch return error.BadRevision;
        defer b.deinit();
        const remote_name = b.push_remote orelse r.repo.config.get("remote.pushdefault") orelse b.remote orelse return error.BadRevision;
        const mode = r.repo.config.get("push.default") orelse "simple";
        if (std.mem.eql(u8, mode, "nothing")) return error.BadRevision;
        if (std.mem.eql(u8, mode, "upstream") or std.mem.eql(u8, mode, "tracking")) return r.upstreamOf(branch);
        if (std.mem.eql(u8, mode, "simple") and b.remote != null and std.mem.eql(u8, b.remote.?, remote_name)) {
            // To the upstream, which must have the branch's own name.
            const up = try r.upstreamOf(branch);
            var bb = remote_mod.Branch.get(r.gpa, &r.repo.config, branch) catch return error.BadRevision;
            defer bb.deinit();
            const merge = if (bb.merge.len != 0) bb.merge[0] else return error.BadRevision;
            if (!std.mem.eql(u8, merge["refs/heads/".len..], branch)) return error.BadRevision;
            return up;
        }
        // current, matching, and simple to another remote: the same name.
        var remote = remote_mod.Remote.get(r.gpa, &r.repo.config, remote_name) catch return error.BadRevision;
        defer remote.deinit();
        const dest = try std.fmt.allocPrint(r.a, "refs/heads/{s}", .{branch});
        for (remote.fetch) |spec| {
            if (try spec.mapSource(r.a, dest)) |tracking| return tracking;
        }
        return error.BadRevision;
    }

    /// `@{-<n>}`: the branch `HEAD`'s reflog says was left n checkouts ago.
    fn previousBranch(r: *Resolver, n: u32) Error!Oid {
        if (n == 0) return error.BadRevision;
        var log = r.repo.readLog(r.io, "HEAD") catch return error.BadRevision;
        defer log.deinit();
        var seen: u32 = 0;
        var i = log.entries.len;
        while (i > 0) {
            i -= 1;
            const message = log.entries[i].message;
            const prefix = "checkout: moving from ";
            if (!std.mem.startsWith(u8, message, prefix)) continue;
            const rest = message[prefix.len..];
            const to = std.mem.indexOf(u8, rest, " to ") orelse continue;
            seen += 1;
            if (seen != n) continue;
            const from = rest[0..to];
            if (try r.refMaybe(try std.fmt.allocPrint(r.a, "refs/heads/{s}", .{from}))) |oid| return oid;
            return r.one(from);
        }
        return error.BadRevision;
    }

    const Want = enum { commit, tree, blob, tag, any };

    fn typeOf(r: *Resolver, oid: Oid) Error!object.Type {
        const header = r.repo.odb.readHeader(r.io, oid) catch return error.BadRevision;
        return header.type;
    }

    /// Peel tags, and a commit to its tree when a tree is wanted.
    fn peelTo(r: *Resolver, start: Oid, want: Want) Error!Oid {
        var oid = start;
        var depth: u8 = 0;
        while (depth < 32) : (depth += 1) {
            const t = try r.typeOf(oid);
            switch (want) {
                .any => if (t != .tag) return oid,
                .tag => return if (t == .tag) oid else error.BadRevision,
                .commit => if (t == .commit) return oid,
                .tree => {
                    if (t == .tree) return oid;
                    if (t == .commit) return r.treeOf(oid);
                },
                .blob => if (t == .blob) return oid,
            }
            if (t != .tag) return error.BadRevision;
            oid = try r.tagTarget(oid);
        }
        return error.BadRevision;
    }

    fn tagTarget(r: *Resolver, oid: Oid) Error!Oid {
        const found = r.repo.odb.read(r.io, oid) catch return error.BadRevision;
        defer r.repo.odb.gpa.free(found.bytes);
        var tag = object.Tag.parse(r.gpa, r.repo.kind, found.bytes) catch return error.BadRevision;
        defer tag.deinit();
        return tag.target;
    }

    fn treeOf(r: *Resolver, commit: Oid) Error!Oid {
        const found = r.repo.odb.read(r.io, commit) catch return error.BadRevision;
        defer r.repo.odb.gpa.free(found.bytes);
        var c = object.Commit.parse(r.gpa, r.repo.kind, found.bytes) catch return error.BadRevision;
        defer c.deinit();
        return c.tree;
    }

    fn parents(r: *Resolver, commit: Oid) Error![]const Oid {
        const found = r.repo.odb.read(r.io, commit) catch return error.BadRevision;
        defer r.repo.odb.gpa.free(found.bytes);
        var c = object.Commit.parse(r.gpa, r.repo.kind, found.bytes) catch return error.BadRevision;
        defer c.deinit();
        return r.a.dupe(Oid, c.parents);
    }

    fn parent(r: *Resolver, base: Oid, n: u32) Error!Oid {
        const commit = try r.peelTo(base, .commit);
        if (n == 0) return commit;
        const list = try r.parents(commit);
        if (n > list.len) return error.BadRevision;
        return list[n - 1];
    }

    fn ancestor(r: *Resolver, base: Oid, n: u32) Error!Oid {
        var commit = try r.peelTo(base, .commit);
        for (0..n) |_| {
            const list = try r.parents(commit);
            if (list.len == 0) return error.BadRevision;
            commit = list[0];
        }
        return commit;
    }

    /// `^{<what>}`.
    fn peelOnion(r: *Resolver, base: Oid, what: []const u8) Error!Oid {
        if (what.len == 0) return r.peelTo(base, .any);
        if (what[0] == '/') {
            const commit = try r.peelTo(base, .commit);
            return r.oneline(what[1..], commit);
        }
        const want: Want = if (std.mem.eql(u8, what, "commit"))
            .commit
        else if (std.mem.eql(u8, what, "tree"))
            .tree
        else if (std.mem.eql(u8, what, "blob"))
            .blob
        else if (std.mem.eql(u8, what, "tag"))
            .tag
        else if (std.mem.eql(u8, what, "object"))
            return base
        else
            return error.BadRevision;
        return r.peelTo(base, want);
    }

    /// The youngest commit whose message the pattern matches: reached from
    /// `from`, or from every ref when it is `null`, as git's
    /// `get_oid_oneline` searches.
    fn oneline(r: *Resolver, raw: []const u8, from: ?Oid) Error!Oid {
        var pattern_text = raw;
        var negate = false;
        if (pattern_text.len != 0 and pattern_text[0] == '!') {
            if (pattern_text.len > 1 and pattern_text[1] == '-') {
                negate = true;
                pattern_text = pattern_text[2..];
            } else if (pattern_text.len > 1 and pattern_text[1] == '!') {
                pattern_text = pattern_text[1..];
            } else return error.BadRevision;
        }
        var pattern = try ere.Pattern.compile(r.gpa, pattern_text);
        defer pattern.deinit();
        var walk = revwalk.Walk.init(r.gpa, &r.repo.odb);
        defer walk.deinit();
        if (from) |oid| {
            try walk.push(oid);
        } else {
            var listing = r.repo.refs.list(r.gpa, r.io, "") catch return error.BadRevision;
            defer listing.deinit();
            for (listing.entries) |entry| {
                const oid = (try r.refMaybe(entry.name)) orelse continue;
                const commit = r.peelTo(oid, .commit) catch continue;
                try walk.push(commit);
            }
        }
        while (walk.next(r.io) catch return error.BadRevision) |c| {
            const found = r.repo.odb.read(r.io, c.oid) catch return error.BadRevision;
            defer r.repo.odb.gpa.free(found.bytes);
            var commit = object.Commit.parse(r.gpa, r.repo.kind, found.bytes) catch return error.BadRevision;
            defer commit.deinit();
            const hit = try pattern.search(r.gpa, commit.message);
            if (hit != negate) return c.oid;
        }
        return error.BadRevision;
    }

    fn inTree(r: *Resolver, tree: Oid, path: []const u8) Error!Oid {
        if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../") or std.mem.eql(u8, path, ".")) return error.RelativePathUnsupported;
        var current = tree;
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (parts.next()) |part| {
            const found = r.repo.odb.read(r.io, current) catch return error.BadRevision;
            defer r.repo.odb.gpa.free(found.bytes);
            if (found.type != .tree) return error.BadRevision;
            const entry = (object.Tree.parse(r.repo.kind, found.bytes).find(part) catch return error.BadRevision) orelse return error.BadRevision;
            current = entry.oid;
        }
        return current;
    }

    fn fromIndex(r: *Resolver, stage: u2, path: []const u8) Error!Oid {
        if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../")) return error.RelativePathUnsupported;
        var index = r.repo.openIndex(r.io) catch return error.BadRevision;
        defer index.deinit();
        for (index.entries.items) |entry| {
            if (entry.stage == stage and std.mem.eql(u8, entry.path, path)) return entry.oid;
        }
        return error.BadRevision;
    }
};

const testing = std.testing;
const testgit = @import("testgit.zig");

test "every expression reads as git rev-parse reads it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    // Each commit a minute after the last, so the date order has no ties.
    var clock: u64 = 1_700_000_000;
    for (0..4) |i| {
        clock += 60;
        var date: [32]u8 = undefined;
        try r.isolated.?.put("GIT_COMMITTER_DATE", try std.fmt.bufPrint(&date, "{d} +0000", .{clock}));
        var name: [16]u8 = undefined;
        const file = try std.fmt.bufPrint(&name, "f{d}", .{i});
        try r.writeFile(io, file, file);
        try r.writeFile(io, "dir/deep", file);
        try r.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try r.exec(io, &.{ "commit", "-q", "-m", try std.fmt.bufPrint(&msg, "change number {d}", .{i}) });
    }
    try r.exec(io, &.{ "tag", "light", "HEAD~2" });
    try r.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1", "HEAD~1" });
    clock += 60;
    var side_date: [32]u8 = undefined;
    try r.isolated.?.put("GIT_COMMITTER_DATE", try std.fmt.bufPrint(&side_date, "{d} +0000", .{clock}));
    try r.exec(io, &.{ "checkout", "-q", "-b", "side", "HEAD~2" });
    try r.writeFile(io, "side", "side");
    try r.exec(io, &.{ "add", "side" });
    try r.exec(io, &.{ "commit", "-q", "-m", "side work" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    clock += 60;
    var merge_date: [32]u8 = undefined;
    try r.isolated.?.put("GIT_COMMITTER_DATE", try std.fmt.bufPrint(&merge_date, "{d} +0000", .{clock}));
    try r.exec(io, &.{ "merge", "-q", "--no-edit", "side" });
    try r.exec(io, &.{ "checkout", "-q", "side" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    try r.exec(io, &.{ "remote", "add", "origin", "https://example.invalid/r.git" });
    try r.exec(io, &.{ "update-ref", "refs/remotes/origin/main", "HEAD~1" });
    try r.exec(io, &.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    try r.exec(io, &.{ "config", "branch.main.remote", "origin" });
    try r.exec(io, &.{ "config", "branch.main.merge", "refs/heads/main" });
    const short = try r.line(io, &.{ "rev-parse", "--short=7", "HEAD~2" });
    defer gpa.free(short);
    const described = try r.line(io, &.{ "describe", "--tags", "--long", "HEAD" });
    defer gpa.free(described);

    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{
        "HEAD",                "@",             "main",            "side",            "refs/heads/side",
        "light",               "v1",            "v1^{}",           "v1^{commit}",     "v1^{tree}",
        "v1^{tag}",            "HEAD^",         "HEAD^1",          "HEAD^2",          "HEAD^0",
        "HEAD~",               "HEAD~3",        "HEAD^2~1",        "HEAD^{tree}",     "HEAD:f0",
        "HEAD:dir",            "HEAD:dir/deep", "HEAD~1:dir/deep", "v1:f1",           ":f0",
        ":0:dir/deep",         "HEAD@{0}",      "HEAD@{1}",        "main@{1}",        "@{1}",
        "@{-1}",               "@{-2}",         "@{u}",            "main@{upstream}", "@{push}",
        "origin/main",         "origin",        ":/number 2",      ":/^side",         ":/!-number",
        "HEAD^{/number [01]}", short,           described,         "HEAD:",           "light~1",
    };
    for (cases) |expr| {
        const theirs = r.line(io, &.{ "rev-parse", "--verify", "--quiet", expr }) catch |err| {
            std.debug.print("git refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        defer gpa.free(theirs);
        const ours = resolve(gpa, io, &repo, expr) catch |err| {
            std.debug.print("relic refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        var hex: [hash.max_hex_len]u8 = undefined;
        testing.expectEqualStrings(theirs, ours.hex(&hex)) catch |err| {
            std.debug.print("for {s}\n", .{expr});
            return err;
        };
    }
    // What git refuses is refused.
    for ([_][]const u8{ "nowhere", "HEAD~99", "HEAD^3", "HEAD:missing", "v1^{blob}", ":/no such message" }) |expr| {
        _ = try arena.alloc(u8, 1);
        const refused = if (resolve(gpa, io, &repo, expr)) |_| false else |_| true;
        try testing.expect(refused);
    }
    try testing.expectError(error.RevisionDateUnsupported, resolve(gpa, io, &repo, "main@{yesterday}"));
}
