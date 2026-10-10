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
//! `<ref>@{<date>}` and `@{<date>}` pick the reflog entry in force at a
//! date, read as git's `approxidate` reads it: `yesterday`, `3.days.ago`,
//! `2023-11-14 22:15`, or seconds since the epoch. `resolve` reads the
//! time now from the `Io`'s clock and takes a date naming no zone in UTC;
//! `resolveAt` takes both from the caller. A path relative to a working
//! directory (`:./x`) is refused; there is none here to be relative to.

const Self = @This();

const std = @import("std");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const ref_names = @import("../names.zig").ref;
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const refs_mod = @import("../refs/refs.zig");
const revwalk = @import("../walk/walk.zig");
const remote_mod = @import("../wire.zig").remote;
const ere = @import("../text.zig").ere;
const gitdate = @import("../text.zig").date;

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

// Failures to obtain the bytes are distinct from an expression naming
// nothing. These are the resource errors the readers below can return.
const ResourceError = Allocator.Error || Io.Dir.OpenError || Io.Dir.ReadFileAllocError ||
    Io.Dir.Iterator.Error || Io.File.Reader.Error || Io.File.Reader.SeekError;

/// Errors from reading an expression.
pub const Error = error{
    /// Not an expression git reads, or one that names nothing here.
    BadRevision,
    /// An abbreviation more than one object begins with.
    AmbiguousRevision,
    /// A path relative to a working directory: `:./x`, `HEAD:../x`.
    RelativePathUnsupported,
} || ere.Error || ResourceError;

/// What `expr` names in `repo`.
pub fn resolve(gpa: Allocator, io: Io, repo: *Repository, expr: []const u8) Self.Error!Oid {
    return resolveWith(gpa, io, repo, expr, null);
}

/// The time a reflog's `@{<date>}` is read against.
pub const Clock = struct {
    /// The time now, in seconds since the epoch.
    now: i64,
    /// Minutes east of UTC that a date naming no zone is taken in: git's
    /// local time.
    local_offset_minutes: i32 = 0,
};

/// What `expr` names in `repo`, with `@{<date>}` read against `clock`.
pub fn resolveAt(gpa: Allocator, io: Io, repo: *Repository, expr: []const u8, clock: Clock) Self.Error!Oid {
    return resolveWith(gpa, io, repo, expr, clock);
}

fn resolveWith(gpa: Allocator, io: Io, repo: *Repository, expr: []const u8, clock: ?Clock) Error!Oid {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r: Resolver = .{ .gpa = gpa, .a = arena_state.allocator(), .io = io, .repo = repo, .clock = clock };
    return r.withContext(expr);
}

fn revisionError(err: anyerror) Error {
    inline for (@typeInfo(ResourceError).error_set.error_names.?) |name| {
        const resource = @field(ResourceError, name);
        if (err == resource) return resource;
    }
    return error.BadRevision;
}

const Resolver = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    repo: *Repository,
    /// `null` reads the `Io`'s clock when a date needs it, in UTC.
    clock: ?Clock,

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
        const kind = r.repo.objectFormat();
        if (name.len == kind.hexLen()) {
            if (Oid.parse(kind, name)) |oid| return oid else |_| {}
        }
        if (std.mem.findLast(u8, name, "@{")) |at| {
            if (name[name.len - 1] != '}') return error.BadRevision;
            return r.reflogSelect(name[0..at], name[at + 2 .. name.len - 1]);
        }
        if (std.mem.eql(u8, name, "@")) return r.ref("HEAD");
        if (try r.dwim(name)) |oid| return oid;
        // `git describe`'s `<tag>-<n>-g<hex>`.
        if (std.mem.findLast(u8, name, "-g")) |g| {
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
        return r.repo.objectDatabase().findPrefix(r.io, lower[0..hex.len]) catch |err| switch (err) {
            error.AmbiguousPrefix => error.AmbiguousRevision,
            error.ObjectNotFound => error.BadRevision,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => |e| revisionError(e),
        };
    }

    /// git's `ref_rev_parse_rules`, in order: the first that names a ref.
    fn dwim(r: *Resolver, name: []const u8) Error!?Oid {
        const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
        inline for (rules) |rule| {
            const full = try r.a.print(rule, .{name});
            if (try r.refMaybe(full)) |oid| return oid;
        }
        return null;
    }

    /// The full ref name `name` resolves to, by the same rules.
    fn dwimName(r: *Resolver, name: []const u8) Error!?[]const u8 {
        const rules = [_][]const u8{ "{s}", "refs/{s}", "refs/tags/{s}", "refs/heads/{s}", "refs/remotes/{s}", "refs/remotes/{s}/HEAD" };
        inline for (rules) |rule| {
            const full = try r.a.print(rule, .{name});
            if (try r.refMaybe(full) != null) return full;
        }
        return null;
    }

    fn refMaybe(r: *Resolver, full: []const u8) Error!?Oid {
        // Only names a ref can have: `HEAD` and its kind at the top,
        // everything under `refs/`, and another worktree's,
        // `main-worktree/HEAD` and `worktrees/<id>/HEAD`.
        if (!std.mem.startsWith(u8, full, "refs/") and ref_names.parseWorktreeRef(full).owner == .shared) return null;
        const resolved = r.repo.refStore().resolve(r.gpa, r.io, full) catch |err| {
            const mapped = revisionError(err);
            if (mapped == error.BadRevision) return null;
            return mapped;
        };
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
        // All digits is an entry's place, or seconds since the epoch from
        // 100000000 on, as git reads it; anything else is a date.
        var n: u64 = 0;
        const digits = what.len != 0 and for (what) |c| {
            if (!std.ascii.isDigit(c)) break false;
            n = n *| 10 +| (c - '0');
        } else true;
        const at_time: ?i64 = if (!digits)
            (r.approximate(what) orelse return error.BadRevision)
        else if (n >= 100_000_000)
            @intCast(@min(n, std.math.maxInt(i64))) // safe: clamped to i64's range
        else
            null;
        // `@{<n>}` with nothing before it is the current branch's reflog.
        const full = if (base.len == 0)
            try r.currentBranchRef()
        else
            (try r.dwimName(base)) orelse return error.BadRevision;
        var log = r.repo.readLog(r.io, full) catch |err| return revisionError(err);
        defer log.deinit();
        if (log.entries.len == 0) return error.BadRevision;
        if (at_time) |time| return r.reflogAt(full, log.entries, time);
        if (n == 0) return log.entries[log.entries.len - 1].new;
        if (n > log.entries.len) return error.BadRevision;
        const entry = log.entries[log.entries.len - n];
        return entry.old;
    }

    fn approximate(r: *Resolver, text: []const u8) ?i64 {
        const clock = r.clock orelse Clock{ .now = Io.Clock.real.now(r.io).toSeconds() };
        return gitdate.approximate(text, .{ .now = clock.now, .local_offset_minutes = clock.local_offset_minutes });
    }

    /// git's `read_ref_at` by date: the newest entry made at or before
    /// `time` says what the ref held then. Where that is the newest entry
    /// of all and not made at `time` exactly, it is what the ref holds now;
    /// where every entry is later, it is what the oldest one replaced, or
    /// what it made where it created the ref.
    fn reflogAt(r: *Resolver, full: []const u8, entries: []const refs_mod.LogEntry, time: i64) Error!Oid {
        var newer_old: ?Oid = null;
        var i = entries.len;
        while (i > 0) {
            i -= 1;
            const entry = entries[i];
            if (entry.who.when_secs <= time) {
                if (newer_old) |old| {
                    if (!old.isZero()) return entry.new;
                }
                if (entry.who.when_secs == time) return entry.new;
                return (try r.refMaybe(full)) orelse entry.new;
            }
            newer_old = entry.old;
        }
        const oldest = entries[0];
        return if (oldest.old.isZero()) oldest.new else oldest.old;
    }

    fn currentBranchRef(r: *Resolver) Error![]const u8 {
        const head = r.repo.refStore().read(r.gpa, r.io, "HEAD") catch |err| return revisionError(err);
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
        var b = remote_mod.Branch.get(r.gpa, r.repo.configuration(), branch) catch |err| return revisionError(err);
        defer b.deinit();
        const remote_name = b.remote orelse return error.BadRevision;
        if (b.merge.len == 0) return error.BadRevision;
        const merge = try r.a.dupe(u8, b.merge[0]);
        if (std.mem.eql(u8, remote_name, ".")) return merge;
        var remote = remote_mod.Remote.get(r.gpa, r.repo.configuration(), remote_name) catch |err| return revisionError(err);
        defer remote.deinit();
        for (remote.fetch) |spec| {
            if (try spec.mapSource(r.a, merge)) |tracking| return tracking;
        }
        return error.BadRevision;
    }

    /// Where `git push` would send `branch`, as the ref that tracks it:
    /// `push.default` read as git reads it.
    fn pushOf(r: *Resolver, branch: []const u8) Error![]const u8 {
        var b = remote_mod.Branch.get(r.gpa, r.repo.configuration(), branch) catch |err| return revisionError(err);
        defer b.deinit();
        const remote_name = b.push_remote orelse r.repo.configuration().get("remote.pushdefault") orelse b.remote orelse return error.BadRevision;
        const mode = r.repo.configuration().get("push.default") orelse "simple";
        if (std.mem.eql(u8, mode, "nothing")) return error.BadRevision;
        if (std.mem.eql(u8, mode, "upstream") or std.mem.eql(u8, mode, "tracking")) return r.upstreamOf(branch);
        if (std.mem.eql(u8, mode, "simple") and b.remote != null and std.mem.eql(u8, b.remote.?, remote_name)) {
            // To the upstream, which must have the branch's own name.
            const up = try r.upstreamOf(branch);
            var bb = remote_mod.Branch.get(r.gpa, r.repo.configuration(), branch) catch |err| return revisionError(err);
            defer bb.deinit();
            const merge = if (bb.merge.len != 0) bb.merge[0] else return error.BadRevision;
            if (!std.mem.eql(u8, merge["refs/heads/".len..], branch)) return error.BadRevision;
            return up;
        }
        // current, matching, and simple to another remote: the same name.
        var remote = remote_mod.Remote.get(r.gpa, r.repo.configuration(), remote_name) catch |err| return revisionError(err);
        defer remote.deinit();
        const dest = try r.a.print("refs/heads/{s}", .{branch});
        for (remote.fetch) |spec| {
            if (try spec.mapSource(r.a, dest)) |tracking| return tracking;
        }
        return error.BadRevision;
    }

    /// `@{-<n>}`: the branch `HEAD`'s reflog says was left n checkouts ago.
    fn previousBranch(r: *Resolver, n: u32) Error!Oid {
        if (n == 0) return error.BadRevision;
        var log = r.repo.readLog(r.io, "HEAD") catch |err| return revisionError(err);
        defer log.deinit();
        var seen: u32 = 0;
        var i = log.entries.len;
        while (i > 0) {
            i -= 1;
            const message = log.entries[i].message;
            const prefix = "checkout: moving from ";
            if (!std.mem.startsWith(u8, message, prefix)) continue;
            const rest = message[prefix.len..];
            const to = std.mem.find(u8, rest, " to ") orelse continue;
            seen += 1;
            if (seen != n) continue;
            const from = rest[0..to];
            // The name a checkout left, which is an object name when it
            // left a detached HEAD, or a ref, and is never read as a
            // revision: a log line naming `@{-1}` would otherwise name
            // itself without end. git's `get_oid_basic` reads it so.
            if (from.len == r.repo.objectFormat().hexLen()) {
                if (Oid.parse(r.repo.objectFormat(), from)) |oid| return oid else |_| {}
            }
            if (try r.refMaybe(try r.a.print("refs/heads/{s}", .{from}))) |oid| return oid;
            return (try r.dwim(from)) orelse error.BadRevision;
        }
        return error.BadRevision;
    }

    const Want = enum { commit, tree, blob, tag, any };

    fn typeOf(r: *Resolver, oid: Oid) Error!object.Type {
        const header = r.repo.objectDatabase().readHeader(r.io, oid) catch |err| return revisionError(err);
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
        const found = r.repo.objectDatabase().read(r.io, oid) catch |err| return revisionError(err);
        defer r.repo.objectDatabase().allocator().free(found.bytes);
        var tag = object.Tag.parse(r.gpa, r.repo.objectFormat(), found.bytes) catch |err| return revisionError(err);
        defer tag.deinit();
        return tag.target;
    }

    fn treeOf(r: *Resolver, commit: Oid) Error!Oid {
        return r.repo.commitTree(r.io, commit) catch |err| revisionError(err);
    }

    fn parents(r: *Resolver, commit: Oid) Error![]const Oid {
        const info = r.repo.commitInfo(r.io, commit, r.a) catch |err| return revisionError(err);
        return info.parents;
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
        var walk = revwalk.Walk.init(r.gpa, r.repo.objectDatabase());
        defer walk.deinit();
        if (from) |oid| {
            try walk.push(oid);
        } else {
            var listing = r.repo.refStore().list(r.gpa, r.io, "") catch |err| return revisionError(err);
            defer listing.deinit();
            for (listing.entries) |entry| {
                const oid = (try r.refMaybe(entry.name)) orelse continue;
                const commit = r.peelTo(oid, .commit) catch |err| {
                    if (err == error.BadRevision) continue;
                    return err;
                };
                try walk.push(commit);
            }
        }
        while (walk.next(r.io) catch |err| return revisionError(err)) |c| {
            const found = r.repo.objectDatabase().read(r.io, c.oid) catch |err| return revisionError(err);
            defer r.repo.objectDatabase().allocator().free(found.bytes);
            var commit = object.Commit.parse(r.gpa, r.repo.objectFormat(), found.bytes) catch |err| return revisionError(err);
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
            const found = r.repo.objectDatabase().read(r.io, current) catch |err| return revisionError(err);
            defer r.repo.objectDatabase().allocator().free(found.bytes);
            if (found.type != .tree) return error.BadRevision;
            const entry = (object.Tree.parse(r.repo.objectFormat(), found.bytes).find(part) catch return error.BadRevision) orelse return error.BadRevision;
            current = entry.oid;
        }
        return current;
    }

    fn fromIndex(r: *Resolver, stage: u2, path: []const u8) Error!Oid {
        if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../")) return error.RelativePathUnsupported;
        var index = r.repo.openIndex(r.io) catch |err| return revisionError(err);
        defer index.deinit();
        for (index.entries.items) |entry| {
            if (entry.stage == stage and std.mem.eql(u8, entry.path, path)) return entry.oid;
        }
        return error.BadRevision;
    }
};

const testing = std.testing;
const testgit = @import("../testing/git.zig");

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
        try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&date, "{d} +0000", .{clock}));
        var name: [16]u8 = undefined;
        const file = try std.mem.print(&name, "f{d}", .{i});
        try r.writeFile(io, file, file);
        try r.writeFile(io, "dir/deep", file);
        try r.exec(io, &.{ "add", "-A" });
        var msg: [32]u8 = undefined;
        try r.exec(io, &.{ "commit", "-q", "-m", try std.mem.print(&msg, "change number {d}", .{i}) });
    }
    try r.exec(io, &.{ "tag", "light", "HEAD~2" });
    try r.exec(io, &.{ "tag", "-a", "-m", "annotated", "v1", "HEAD~1" });
    clock += 60;
    var side_date: [32]u8 = undefined;
    try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&side_date, "{d} +0000", .{clock}));
    try r.exec(io, &.{ "checkout", "-q", "-b", "side", "HEAD~2" });
    try r.writeFile(io, "side", "side");
    try r.exec(io, &.{ "add", "side" });
    try r.exec(io, &.{ "commit", "-q", "-m", "side work" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    clock += 60;
    var merge_date: [32]u8 = undefined;
    try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&merge_date, "{d} +0000", .{clock}));
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
}

test "@{-N} reads the branch a checkout left as a name or an object name, never as an expression" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "one" });
    try r.exec(io, &.{ "branch", "other" });
    // Left detached, then left a branch: git names an object, then a ref.
    try r.exec(io, &.{ "checkout", "-q", "--detach" });
    try r.exec(io, &.{ "checkout", "-q", "other" });
    try r.exec(io, &.{ "checkout", "-q", "main" });
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    for ([_][]const u8{ "@{-1}", "@{-2}", "@{-3}" }) |expr| {
        const theirs = try r.line(io, &.{ "rev-parse", expr });
        defer gpa.free(theirs);
        var hex: [hash.max_hex_len]u8 = undefined;
        try testing.expectEqualStrings(theirs, (try resolve(gpa, io, &repo, expr)).hex(&hex));
    }

    // A log line naming `@{-1}` as where it came from is no name at all.
    const head_text = try r.line(io, &.{ "rev-parse", "HEAD" });
    defer gpa.free(head_text);
    const line = try gpa.print("{s} {s} A <a@b> 1 +0000\tcheckout: moving from @{{-1}} to main\n", .{ head_text, head_text });
    defer gpa.free(line);
    const log = try r.readFile(io, ".git/logs/HEAD");
    defer gpa.free(log);
    const looped = try std.mem.concat(gpa, u8, &.{ log, line });
    defer gpa.free(looped);
    try r.writeFile(io, ".git/logs/HEAD", looped);
    r.report_failures = false;
    try testing.expectError(error.GitFailed, r.run(io, &.{ "rev-parse", "--verify", "-q", "@{-1}" }));
    try testing.expectError(error.BadRevision, resolve(gpa, io, &repo, "@{-1}"));
}

test "a reflog entry chosen by a date is the one git rev-parse chooses" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    // Two days of history an hour apart, read on the third day at 12:00.
    const start: i64 = 1_700_000_000;
    const now = start + 2 * 24 * 60 * 60;
    var now_text: [32]u8 = undefined;
    try r.isolated.?.put("GIT_TEST_DATE_NOW", try std.mem.print(&now_text, "{d}", .{now}));
    try r.isolated.?.put("TZ", "UTC");
    for (0..6) |i| {
        var date: [32]u8 = undefined;
        try r.isolated.?.put("GIT_COMMITTER_DATE", try std.mem.print(&date, "{d} +0000", .{start + @as(i64, @intCast(i)) * 3 * 60 * 60})); // safe: below 6
        var name: [16]u8 = undefined;
        const file = try std.mem.print(&name, "f{d}", .{i});
        try r.writeFile(io, file, file);
        try r.exec(io, &.{ "add", "-A" });
        try r.exec(io, &.{ "commit", "-q", "-m", file });
        if (i == 2) try r.exec(io, &.{ "branch", "side" });
    }

    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var exact: [48]u8 = undefined;
    var stamp: [48]u8 = undefined;
    var iso: [48]u8 = undefined;
    const cases = [_][]const u8{
        "main@{now}",
        "main@{yesterday}",
        "@{2.days.ago}",
        "HEAD@{1.day.ago}",
        "main@{40 hours ago}",
        "main@{1.year.ago}",
        "side@{1.week.ago}",
        "side@{now}",
        try std.mem.print(&exact, "main@{{{d}}}", .{start + 3 * 60 * 60}),
        try std.mem.print(&stamp, "main@{{{d}}}", .{start + 4 * 60 * 60}),
        try std.mem.print(&iso, "main@{{2023-11-14 23:30:00 +0000}}", .{}),
        "main@{last tuesday}",
    };
    for (cases) |expr| {
        const theirs = r.line(io, &.{ "rev-parse", "--verify", "--quiet", expr }) catch |err| {
            std.debug.print("git refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        defer gpa.free(theirs);
        const ours = resolveAt(gpa, io, &repo, expr, .{ .now = now }) catch |err| {
            std.debug.print("relic refuses {s}: {}\n", .{ expr, err });
            return err;
        };
        var hex: [hash.max_hex_len]u8 = undefined;
        testing.expectEqualStrings(theirs, ours.hex(&hex)) catch |err| {
            std.debug.print("for {s}\n", .{expr});
            return err;
        };
    }
    // Words that mean nothing are no date, for git and here.
    r.report_failures = false;
    try testing.expectError(error.GitFailed, r.run(io, &.{ "rev-parse", "--verify", "--quiet", "main@{whenever}" }));
    try testing.expectError(error.BadRevision, resolveAt(gpa, io, &repo, "main@{whenever}", .{ .now = now }));
    // Without a clock the `Io`'s is read.
    _ = try resolve(gpa, io, &repo, "main@{yesterday}");
}

test "revision parsing preserves allocation resource failures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try Repository.create(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    const commit = try repo.objectDatabase().write(io, .commit, "tree " ++ @as([40]u8, @splat('0')) ++ "\nparent " ++ @as([40]u8, @splat('1')) ++ "\nauthor A <a@b> 0 +0000\ncommitter A <a@b> 0 +0000\n\nsubject\n");
    var hex: [hash.max_hex_len]u8 = undefined;
    const text = commit.hex(&hex);
    try repo.gitDirectory().writeFile(io, .{ .sub_path = "refs/heads/main", .data = text });
    const Check = struct {
        fn run(allocator: Allocator, repository: *Repository, expr: []const u8, expected: Oid) !void {
            const got = try resolve(allocator, std.testing.io, repository, expr);
            try std.testing.expect(got.eql(expected));
        }
    };
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{ &repo, "HEAD", commit });
    }
    const parent_expr = try gpa.print("{s}^", .{text});
    defer gpa.free(parent_expr);
    {
        var no_resize = shakedown.alloc.NoResize.init(std.testing.allocator);
        try std.testing.checkAllAllocationFailures(no_resize.allocator(), Check.run, .{ &repo, parent_expr, try Oid.parse(.sha1, &@as([40]u8, @splat('1'))) });
    }
}

test "revision parsing preserves I/O and cancellation resource failures" {
    const Fault = struct {
        threadlocal var failure: Io.File.ReadPositionalError = error.InputOutput;
        fn read(_: ?*anyopaque, _: Io.File, _: []const []u8, _: u64) Io.File.ReadPositionalError!usize {
            return failure;
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try Repository.create(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Fault.read;
    const failing_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]Io.File.ReadPositionalError{ error.InputOutput, error.Canceled }) |failure| {
        Fault.failure = failure;
        try std.testing.expectError(failure, resolve(gpa, failing_io, &repo, "HEAD"));
        try std.testing.expectError(failure, resolve(gpa, failing_io, &repo, "@{0}"));
    }
}

test "a walk back from a commit reads each commit once per repository handle" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    for (0..30) |i| {
        var name: [16]u8 = undefined;
        try r.writeFile(io, "f", try std.mem.print(&name, "{d}\n", .{i}));
        try r.exec(io, &.{ "commit", "-q", "-am", "c", "--allow-empty" });
        if (i == 0) try r.exec(io, &.{ "add", "f" });
    }
    try r.exec(io, &.{ "repack", "-adq" });
    const expected = try r.line(io, &.{ "rev-parse", "main~25" });
    defer gpa.free(expected);
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var hex: [hash.max_hex_len]u8 = undefined;
    try testing.expectEqualStrings(expected, (try resolve(gpa, io, &repo, "main~25")).hex(&hex));
    // Every object here is in the one pack, and every read of one asks it.
    const before = repo.objectDatabase().stats.pack_scans;
    try testing.expectEqualStrings(expected, (try resolve(gpa, io, &repo, "main~25")).hex(&hex));
    try testing.expectEqualStrings(expected, (try resolve(gpa, io, &repo, "main~24^")).hex(&hex));
    // Each expression asks the object it starts from, and `^` the one it
    // starts from, for its type; no commit is read again.
    try testing.expect(repo.objectDatabase().stats.pack_scans - before <= 3);
}
