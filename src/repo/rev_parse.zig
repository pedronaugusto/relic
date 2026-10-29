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
const aegis = @import("aegis");
const decimal = @import("../text.zig").decimal;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const ref_names = @import("../names.zig").ref;
const object = @import("../object/object.zig");
const config_mod = @import("../config/config.zig");
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const commit_cache = @import("cache.zig");
const refs_mod = @import("../refs/refs.zig");
const rev_walk = @import("../walk/walk.zig");
const remote_mod = @import("../wire.zig").remote;
const refspec_mod = @import("../wire.zig").refspec;
const ere = @import("../text.zig").ere;
const gitdate = @import("../text.zig").date;

const Oid = hash.Oid;

/// A repository's stores, which an expression is read against, as git's
/// `get_oid_with_context` reads a repository's: `Repository.revisionSource`.
pub const Source = struct {
    /// The repository's allocator, which its commit cache and reflogs are
    /// kept with.
    gpa: Allocator,
    config: *const config_mod.Config,
    odb: *odb_mod.Odb,
    refs: *refs_mod.Store,
    commits: *commit_cache.Cache,
    /// How the repository's index is read, for `:<path>`.
    index: index_mod.ReadOptions,

    fn commitTree(s: Source, io: Io, commit: Oid) commit_cache.Error!Oid {
        return (try s.commits.get(s.gpa, io, s.odb, commit, .{})).tree;
    }
};

// Failures to obtain the bytes are distinct from an expression naming
// nothing. These are the resource errors the readers below can return.
const ResourceError = Allocator.Error || Io.Dir.OpenError || aegis.own.ReadFileError ||
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

/// What `expr` names in `source`.
pub fn resolve(gpa: Allocator, io: Io, source: Source, expr: []const u8) Self.Error!Oid {
    return resolveWith(gpa, io, source, expr, null);
}

/// The time a reflog's `@{<date>}` is read against.
pub const Clock = struct {
    /// The time now.
    now: Io.Timestamp,
    /// Minutes east of UTC that a date naming no zone is taken in: git's
    /// local time.
    local_offset_minutes: i32 = 0,
};

/// What `expr` names in `source`, with `@{<date>}` read against `clock`.
pub fn resolveAt(gpa: Allocator, io: Io, source: Source, expr: []const u8, clock: Clock) Self.Error!Oid {
    return resolveWith(gpa, io, source, expr, clock);
}

/// A short name taken as git takes it for a ref: `repo_dwim_ref`.
pub const Dwim = struct {
    /// How many of git's rules name a ref: all of them are tried, unless
    /// `core.warnAmbiguousRefs` is off, when the first that names one
    /// stops the search.
    count: usize,
    /// The first such ref, through any symbolic ref to the one it ends at.
    ref: []const u8,
    oid: Oid,
};

/// git's `repo_dwim_ref`: `name` with `@`, `@{-<n>}`, `<branch>@{upstream}`
/// and `<branch>@{push}` put in place (`substitute_branch_name`), then
/// looked up by `ref_rev_parse_rules`; `null` when no rule names a ref.
/// What it returns is in `arena`.
pub fn dwimRef(arena: Allocator, io: Io, source: Source, name: []const u8) Self.Error!?Dwim {
    var r: Resolver = .{ .gpa = arena, .a = arena, .io = io, .src = source, .clock = null };
    const full = try r.substituteBranch(name);
    const warn = source.config.getBool("core.warnambiguousrefs", true) catch true;
    var found: ?Dwim = null;
    const rules = ref_names.rev_parse_rules;
    inline for (rules) |rule| {
        if (try r.resolvedRef(try arena.print(rule, .{full}))) |got| {
            if (found) |*f| f.count += 1 else found = .{ .count = 1, .ref = got.name, .oid = got.oid };
            if (!warn) return found;
        }
    }
    return found;
}

fn resolveWith(gpa: Allocator, io: Io, source: Source, expr: []const u8, clock: ?Clock) Error!Oid {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var r: Resolver = .{ .gpa = gpa, .a = arena_state.allocator(), .io = io, .src = source, .clock = clock };
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
    src: Source,
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
            const n: u32 = if (digits.len == 0) 1 else decimal.digits(u32, digits) orelse return error.BadRevision;
            const base = try r.one(name[0 .. cp - 1]);
            return if (kind == '^') r.parent(base, n) else r.ancestor(base, n);
        }
        return r.basic(name);
    }

    /// A name with no suffix: `@{...}`, an object name, a ref, a `describe`
    /// name, an abbreviation.
    fn basic(r: *Resolver, name: []const u8) Error!Oid {
        const kind = r.src.refs.objectFormat();
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
        return r.src.odb.findPrefix(r.io, lower[0..hex.len]) catch |err| switch (err) {
            error.AmbiguousPrefix => error.AmbiguousRevision,
            error.ObjectNotFound => error.BadRevision,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => |e| revisionError(e),
        };
    }

    /// git's `ref_rev_parse_rules`, in order: the first that names a ref.
    fn dwim(r: *Resolver, name: []const u8) Error!?Oid {
        const rules = ref_names.rev_parse_rules;
        inline for (rules) |rule| {
            const full = try r.a.print(rule, .{name});
            if (try r.refMaybe(full)) |oid| return oid;
        }
        return null;
    }

    /// The full ref name `name` resolves to, by the same rules.
    fn dwimName(r: *Resolver, name: []const u8) Error!?[]const u8 {
        const rules = ref_names.rev_parse_rules;
        inline for (rules) |rule| {
            const full = try r.a.print(rule, .{name});
            if (try r.refMaybe(full) != null) return full;
        }
        return null;
    }

    fn refMaybe(r: *Resolver, full: []const u8) Error!?Oid {
        const got = (try r.resolvedRef(full)) orelse return null;
        r.gpa.free(got.name);
        return got.oid;
    }

    /// The ref `full` ends at and its value, or `null` for none. The name
    /// is `r.gpa`'s.
    fn resolvedRef(r: *Resolver, full: []const u8) Error!?struct { name: []const u8, oid: Oid } {
        // Only names a ref can have: `HEAD` and its kind at the top,
        // everything under `refs/`, and another worktree's,
        // `main-worktree/HEAD` and `worktrees/<id>/HEAD`.
        if (!std.mem.startsWith(u8, full, "refs/") and ref_names.parseWorktreeRef(full).owner == .shared) return null;
        const resolved = r.src.refs.resolve(r.gpa, r.io, full) catch |err| {
            const mapped = revisionError(err);
            if (mapped == error.BadRevision) return null;
            return mapped;
        };
        const got = resolved orelse return null;
        return .{ .name = got.name, .oid = got.oid };
    }

    /// git's `substitute_branch_name`: `@` is `HEAD`, `@{-<n>}` the branch
    /// left n checkouts ago, `<branch>@{upstream}` and `<branch>@{push}` the
    /// refs that track them; anything else, or a `@{-<n>}` naming no
    /// checkout, as it is.
    fn substituteBranch(r: *Resolver, name: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, name, "@")) return "HEAD";
        if (name.len == 0 or name[name.len - 1] != '}') return name;
        const at = std.mem.findLast(u8, name, "@{") orelse return name;
        const base = name[0..at];
        const what = name[at + 2 .. name.len - 1];
        if (std.ascii.eqlIgnoreCase(what, "u") or std.ascii.eqlIgnoreCase(what, "upstream")) return r.upstreamOf(try r.branchOf(base));
        if (std.ascii.eqlIgnoreCase(what, "push")) return r.pushOf(try r.branchOf(base));
        if (at != 0 or what.len < 2 or what[0] != '-') return name;
        const read = decimal.strtol(what[1..], 10, 64);
        if (read.end != what.len - 1 or read.value <= 0) return name;
        return (try r.previousName(std.math.cast(u32, read.value) orelse std.math.maxInt(u32))) orelse name;
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
            // git's `interpret_nth_prior_checkout` reads the count with
            // `strtol` (spaces and a sign before it, leading zeros), which
            // must end at the brace and be above zero.
            const read = decimal.strtol(what[1..], 10, 64);
            if (read.end != what.len - 1 or read.value <= 0) return error.BadRevision;
            return r.previousBranch(std.math.cast(u32, read.value) orelse std.math.maxInt(u32));
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
            @intCast(@min(n, std.math.maxInt(i64))) // clamped to i64's range
        else
            null;
        // `@{<n>}` with nothing before it is the current branch's reflog.
        const full = if (base.len == 0)
            try r.currentBranchRef()
        else
            (try r.dwimName(base)) orelse return error.BadRevision;
        var log = r.src.refs.readLog(r.src.gpa, r.io, full) catch |err| return revisionError(err);
        defer log.deinit();
        if (log.entries.len == 0) return error.BadRevision;
        if (at_time) |time| return r.reflogAt(full, log.entries, time);
        if (n == 0) return log.entries[log.entries.len - 1].new;
        if (n > log.entries.len) return error.BadRevision;
        const entry = log.entries[log.entries.len - n];
        return entry.old;
    }

    fn approximate(r: *Resolver, text: []const u8) ?i64 {
        const clock = r.clock orelse Clock{ .now = Io.Clock.real.now(r.io) };
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
        const head = r.src.refs.read(r.gpa, r.io, "HEAD") catch |err| return revisionError(err);
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
        var b = remote_mod.Branch.get(r.gpa, r.src.config, branch) catch |err| return revisionError(err);
        defer b.deinit();
        const remote_name = b.remote orelse return error.BadRevision;
        if (b.merge.len == 0) return error.BadRevision;
        const merge = try r.a.dupe(u8, b.merge[0]);
        if (std.mem.eql(u8, remote_name, ".")) return merge;
        var remote = remote_mod.Remote.get(r.gpa, r.src.config, r.src.refs.objectFormat(), remote_name) catch |err| return revisionError(err);
        defer remote.deinit();
        return (try refspec_mod.map(r.a, remote.fetch, merge)) orelse error.BadRevision;
    }

    /// Where `git push` would send `branch`, as the ref that tracks it:
    /// git's `branch_get_push`. The remote is the branch's push remote,
    /// `remote.pushDefault`, its remote, else `origin`; its push refspecs
    /// name the destination when it has some, a mirror the branch itself,
    /// else `push.default` does (`simple` only where that is the upstream).
    fn pushOf(r: *Resolver, branch: []const u8) Error![]const u8 {
        const config = r.src.config;
        var b = remote_mod.Branch.get(r.gpa, config, branch) catch |err| return revisionError(err);
        defer b.deinit();
        const remote_name = b.push_remote orelse config.get("remote.pushdefault") orelse b.remote orelse "origin";
        var remote = remote_mod.Remote.get(r.gpa, config, r.src.refs.objectFormat(), remote_name) catch |err| return revisionError(err);
        defer remote.deinit();
        const refname = try r.a.print("refs/heads/{s}", .{branch});
        if (remote.push.len != 0) {
            const dst = (try refspec_mod.map(r.a, remote.push, refname)) orelse return error.BadRevision;
            return r.pushTracking(&remote, dst);
        }
        if (remote.mirror) return r.pushTracking(&remote, refname);
        const mode = config.get("push.default") orelse "simple";
        if (std.mem.eql(u8, mode, "matching") or std.mem.eql(u8, mode, "current")) return r.pushTracking(&remote, refname);
        if (std.mem.eql(u8, mode, "upstream") or std.mem.eql(u8, mode, "tracking")) return r.upstreamOf(branch);
        if (std.mem.eql(u8, mode, "simple")) {
            const up = try r.upstreamOf(branch);
            const current = try r.pushTracking(&remote, refname);
            // git's "cannot resolve 'simple' push to a single destination".
            if (!std.mem.eql(u8, up, current)) return error.BadRevision;
            return current;
        }
        // `nothing`, or a value git dies on.
        return error.BadRevision;
    }

    /// git's `tracking_for_push_dest`: the ref `dst` on `remote` is tracked
    /// by, through the fetch refspecs of the remote that tracks a push
    /// there (`Remote.forPushTracking`, for a remote given as a URL).
    fn pushTracking(r: *Resolver, remote: *const remote_mod.Remote, dst: []const u8) Error![]const u8 {
        var for_tracking = remote.forPushTracking(r.gpa, r.src.config, r.src.refs.objectFormat()) catch |err| return revisionError(err);
        defer if (for_tracking) |*t| t.deinit();
        const tracking = if (for_tracking) |*t| t else remote;
        return (try refspec_mod.map(r.a, tracking.fetch, dst)) orelse error.BadRevision;
    }

    /// `@{-<n>}`: the branch `HEAD`'s reflog says was left n checkouts ago.
    fn previousBranch(r: *Resolver, n: u32) Error!Oid {
        const from = (try r.previousName(n)) orelse return error.BadRevision;
        // The name a checkout left, which is an object name when it
        // left a detached HEAD, or a ref, and is never read as a
        // revision: a log line naming `@{-1}` would otherwise name
        // itself without end. git's `get_oid_basic` reads it so.
        if (from.len == r.src.refs.objectFormat().hexLen()) {
            if (Oid.parse(r.src.refs.objectFormat(), from)) |oid| return oid else |_| {}
        }
        if (try r.refMaybe(try r.a.print("refs/heads/{s}", .{from}))) |oid| return oid;
        return (try r.dwim(from)) orelse error.BadRevision;
    }

    /// git's `interpret_nth_prior_checkout`: the name the n-th checkout
    /// back moved from, as `HEAD`'s reflog says it, or `null`.
    fn previousName(r: *Resolver, n: u32) Error!?[]const u8 {
        if (n == 0) return null;
        var log = r.src.refs.readLog(r.src.gpa, r.io, "HEAD") catch |err| return revisionError(err);
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
            if (seen == n) return try r.a.dupe(u8, rest[0..to]);
        }
        return null;
    }

    const Want = enum { commit, tree, blob, tag, any };

    fn typeOf(r: *Resolver, oid: Oid) Error!object.Type {
        const header = r.src.odb.readHeader(r.io, oid) catch |err| return revisionError(err);
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
        const found = r.src.odb.read(r.io, oid) catch |err| return revisionError(err);
        defer r.src.odb.allocator().free(found.bytes);
        var tag = object.Tag.parse(r.gpa, r.src.refs.objectFormat(), found.bytes) catch |err| return revisionError(err);
        defer tag.deinit();
        return tag.target;
    }

    fn treeOf(r: *Resolver, commit: Oid) Error!Oid {
        return r.src.commitTree(r.io, commit) catch |err| revisionError(err);
    }

    fn parents(r: *Resolver, commit: Oid) Error![]const Oid {
        const info = r.src.commits.get(r.src.gpa, r.io, r.src.odb, commit, .{ .out = r.a }) catch |err| return revisionError(err);
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
        var walk = rev_walk.Walk.init(r.gpa, r.src.odb);
        defer walk.deinit();
        if (from) |oid| {
            try walk.push(oid);
        } else {
            var listing = r.src.refs.list(r.gpa, r.io, "") catch |err| return revisionError(err);
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
            const found = r.src.odb.read(r.io, c.oid) catch |err| return revisionError(err);
            defer r.src.odb.allocator().free(found.bytes);
            var commit = object.Commit.parse(r.gpa, r.src.refs.objectFormat(), found.bytes) catch |err| return revisionError(err);
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
            const found = r.src.odb.read(r.io, current) catch |err| return revisionError(err);
            defer r.src.odb.allocator().free(found.bytes);
            if (found.type != .tree) return error.BadRevision;
            const entry = (object.Tree.parse(r.src.refs.objectFormat(), found.bytes).find(part) catch return error.BadRevision) orelse return error.BadRevision;
            current = entry.oid;
        }
        return current;
    }

    fn fromIndex(r: *Resolver, stage: u2, path: []const u8) Error!Oid {
        if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../")) return error.RelativePathUnsupported;
        var index = index_mod.Index.read(r.gpa, r.io, r.src.index.git_dir.?, "index", r.src.index) catch |err| return revisionError(err);
        defer index.deinit();
        for (index.entries.items) |entry| {
            if (entry.stage == stage and std.mem.eql(u8, entry.path, path)) return entry.oid;
        }
        return error.BadRevision;
    }
};
