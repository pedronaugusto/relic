//! The objects a filtered pack holds, chosen as git's `list-objects` walk
//! and its filters (`list-objects-filter.c`) choose them, so that a server
//! sends what git's sends, object for object.
//!
//! Commits come first, in the walk's order, each asked of the filter and its
//! tree set aside; then the objects asked for by name that are not commits;
//! then the commits' trees in turn, each walked depth first in tree order.
//! An object the client has is never met; one the walk has marked seen is
//! not met again. Each filter answers, for every object at every place it is
//! met, whether to send it, whether to mark it seen, and for a tree whether
//! to skip what is in it: `blob:none` and `blob:limit` mark everything they
//! answer seen, `tree:<depth>` remembers the shallowest depth a tree was
//! met at, `sparse:oid=` keeps no tree seen that had a blob left out below
//! it, and `combine:` asks each part with a seen set of the part's own — so
//! an object one part answered seen, where another left it out, is not
//! asked of that part again, and not sent, as git does not send it. An
//! object asked for by name is sent whatever the filter says.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const ignore = @import("ignore.zig");
const objectwalk = @import("objectwalk.zig");

const Oid = hash.Oid;
const Odb = odb_mod.Odb;

/// Where an object is met.
const Situation = enum { commit, begin_tree, end_tree, blob };

/// What a filter answers.
const Verdict = struct {
    show: bool = false,
    seen: bool = false,
    skip: bool = false,

    const zero: Verdict = .{};
    const shown: Verdict = .{ .show = true, .seen = true };
    const hidden: Verdict = .{ .seen = true };
};

/// A filter with the state its answers keep.
const State = union(enum) {
    none,
    blob_none,
    blob_limit: u64,
    object_type: object.Type,
    tree_depth: TreeDepth,
    sparse: Sparse,
    combine: []Part,

    const TreeDepth = struct {
        max: u64,
        current: u64 = 0,
        /// The shallowest depth each tree was met at.
        seen_at: Oid.Map(u64) = .empty,
    };

    const Sparse = struct {
        rules: *const ignore.Rules,
        frames: std.ArrayList(Frame) = .empty,

        const Frame = struct { matched: bool, omitted_below: bool = false };
    };

    const Part = struct {
        state: *State,
        seen: Oid.Set = .empty,
        /// A tree whose contents the part skips, until its end.
        skipping: ?Oid = null,
    };

    fn of(a: Allocator, filter: objectwalk.Filter) Allocator.Error!State {
        return switch (filter) {
            .none => .none,
            .blob_none => .blob_none,
            .blob_limit => |n| .{ .blob_limit = n },
            .object_type => |t| .{ .object_type = t },
            .tree_depth => |max| .{ .tree_depth = .{ .max = max } },
            .sparse => |rules| blk: {
                var s: Sparse = .{ .rules = rules };
                // The walk's root is outside every pattern.
                try s.frames.append(a, .{ .matched = false });
                break :blk .{ .sparse = s };
            },
            .combine => |all| blk: {
                const parts = try a.alloc(Part, all.len);
                for (all, parts) |f, *part| {
                    const state = try a.create(State);
                    state.* = try of(a, f);
                    part.* = .{ .state = state };
                }
                break :blk .{ .combine = parts };
            },
        };
    }
};

/// The objects to send: `commits` in the walk's order, `pending` the
/// objects asked for by name that are not commits, in the order asked,
/// `named` every object asked for by name, `had` what the client has.
pub fn collect(
    gpa: Allocator,
    io: Io,
    db: *Odb,
    filter: objectwalk.Filter,
    commits: []const struct { oid: Oid, tree: Oid },
    pending: []const Oid,
    named: *const Oid.Set,
    had: *const Oid.Set,
    out: *std.ArrayList(odb_mod.PackEntry),
    out_arena: Allocator,
) objectwalk.Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var t: Traversal = .{
        .gpa = gpa,
        .a = arena_state.allocator(),
        .io = io,
        .db = db,
        .state = try State.of(arena_state.allocator(), filter),
        .named = named,
        .had = had,
        .out = out,
        .out_arena = out_arena,
    };
    defer t.seen.deinit(gpa);
    defer t.added.deinit(gpa);
    for (commits) |c| {
        const v = if (named.contains(c.oid)) Verdict.shown else try t.verdict(&t.state, .commit, c.oid, "");
        if (v.show) try t.emit(c.oid, "");
    }
    for (pending) |oid| {
        const header = try db.readHeader(io, oid);
        switch (header.type) {
            .tree => try t.tree(oid, "", true),
            .blob => try t.blob(oid, "", true),
            else => {},
        }
    }
    for (commits) |c| try t.tree(c.tree, "", false);
}

const Traversal = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    db: *Odb,
    state: State,
    named: *const Oid.Set,
    had: *const Oid.Set,
    out: *std.ArrayList(odb_mod.PackEntry),
    out_arena: Allocator,
    /// git's SEEN flag.
    seen: Oid.Set = .empty,
    /// What is in the pack already, which a second showing does not add.
    added: Oid.Set = .empty,

    fn emit(t: *Traversal, oid: Oid, path: []const u8) objectwalk.Error!void {
        if ((try t.added.getOrPut(t.gpa, oid)).found_existing) return;
        try t.out.append(t.gpa, .{ .oid = oid, .hint = try t.out_arena.dupe(u8, path) });
    }

    fn tree(t: *Traversal, oid: Oid, path: []const u8, user_given: bool) objectwalk.Error!void {
        if (t.had.contains(oid) or t.seen.contains(oid)) return;
        const begin = if (user_given) Verdict.shown else try t.verdict(&t.state, .begin_tree, oid, path);
        if (begin.seen) try t.seen.put(t.gpa, oid, {});
        if (begin.show) try t.emit(oid, path);
        if (!begin.skip) {
            const found = try t.db.read(t.io, oid);
            defer t.db.gpa.free(found.bytes);
            if (found.type != .tree) return error.UnexpectedObjectType;
            var entries = object.Tree.parse(t.db.kind, found.bytes).iterate();
            while (try entries.next()) |entry| {
                const child = if (path.len == 0)
                    try t.a.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(t.a, "{s}/{s}", .{ path, entry.name });
                switch (entry.mode) {
                    .tree => try t.tree(entry.oid, child, false),
                    .gitlink => {},
                    else => try t.blob(entry.oid, child, false),
                }
            }
        }
        const end = if (user_given) Verdict.zero else try t.verdict(&t.state, .end_tree, oid, path);
        if (end.seen) try t.seen.put(t.gpa, oid, {});
        if (end.show) try t.emit(oid, path);
    }

    fn blob(t: *Traversal, oid: Oid, path: []const u8, user_given: bool) objectwalk.Error!void {
        if (t.had.contains(oid) or t.seen.contains(oid)) return;
        const v = if (user_given) Verdict.shown else try t.verdict(&t.state, .blob, oid, path);
        if (v.seen) try t.seen.put(t.gpa, oid, {});
        if (v.show) try t.emit(oid, path);
    }

    /// One filter's answer, as `list-objects-filter.c` gives it.
    fn verdict(t: *Traversal, state: *State, sit: Situation, oid: Oid, path: []const u8) objectwalk.Error!Verdict {
        switch (state.*) {
            .none => return if (sit == .end_tree) Verdict.zero else Verdict.shown,
            .blob_none => return switch (sit) {
                .commit, .begin_tree => Verdict.shown,
                .end_tree => Verdict.zero,
                .blob => Verdict.hidden,
            },
            .blob_limit => |limit| return switch (sit) {
                .commit, .begin_tree => Verdict.shown,
                .end_tree => Verdict.zero,
                .blob => blk: {
                    const header = t.db.readHeader(t.io, oid) catch break :blk Verdict.shown;
                    // Strictly smaller than the limit, as git keeps it.
                    break :blk if (header.size < limit) Verdict.shown else Verdict.hidden;
                },
            },
            .object_type => |want| return switch (sit) {
                .commit => if (want == .commit) Verdict.shown else Verdict.hidden,
                // Nothing below a tree is a commit or a tag.
                .begin_tree => if (want == .commit or want == .tag) Verdict{ .skip = true } else if (want == .tree) Verdict.shown else Verdict.hidden,
                .end_tree => Verdict.zero,
                .blob => if (want == .blob) Verdict.shown else Verdict.hidden,
            },
            .tree_depth => |*d| switch (sit) {
                .commit => return Verdict.shown,
                .end_tree => {
                    d.current -= 1;
                    return Verdict.zero;
                },
                .blob => return if (d.current < d.max) Verdict.shown else Verdict.zero,
                .begin_tree => {
                    defer d.current += 1;
                    const got = try d.seen_at.getOrPut(t.a, oid);
                    if (got.found_existing and d.current >= got.value_ptr.*) return .{ .skip = true };
                    got.value_ptr.* = d.current;
                    return if (d.current < d.max) .{ .show = true } else .{ .skip = true };
                },
            },
            .sparse => |*s| switch (sit) {
                .commit => return Verdict.shown,
                .begin_tree => {
                    const inherited = s.frames.items[s.frames.items.len - 1].matched;
                    try s.frames.append(t.a, .{ .matched = match(s.rules, path, true, inherited) });
                    // Met again at another path, a tree's blobs may be
                    // answered otherwise: never marked seen here.
                    return .{ .show = true };
                },
                .end_tree => {
                    const frame = s.frames.pop().?;
                    s.frames.items[s.frames.items.len - 1].omitted_below = s.frames.items[s.frames.items.len - 1].omitted_below or frame.omitted_below;
                    return if (frame.omitted_below) Verdict.zero else Verdict.hidden;
                },
                .blob => {
                    const top = &s.frames.items[s.frames.items.len - 1];
                    if (match(s.rules, path, false, top.matched)) return Verdict.shown;
                    // Left out here, provisionally: met elsewhere, it may
                    // be taken.
                    top.omitted_below = true;
                    return Verdict.zero;
                },
            },
            .combine => |parts| {
                var result: Verdict = .{ .show = true, .seen = true, .skip = true };
                for (parts) |*p| {
                    const v = try t.askPart(p, sit, oid, path);
                    if (!v.show) result.show = false;
                    if (!v.seen) result.seen = false;
                    if (!v.skip) result.skip = false;
                }
                return result;
            },
        }
    }

    /// One part of a `combine:`, with its own seen set and skipping.
    fn askPart(t: *Traversal, p: *State.Part, sit: Situation, oid: Oid, path: []const u8) objectwalk.Error!Verdict {
        if (p.skipping) |skipped| {
            if (sit == .end_tree and skipped.eql(oid)) {
                p.skipping = null;
            } else return Verdict.zero;
        }
        if (p.seen.contains(oid)) return Verdict.zero;
        const v = try t.verdict(p.state, sit, oid, path);
        if (v.seen) try p.seen.put(t.a, oid, {});
        if (v.skip) p.skipping = oid;
        return v;
    }

    /// The sparse patterns' answer for `path`: theirs when one decides,
    /// the directory's when none does.
    fn match(rules: *const ignore.Rules, path: []const u8, is_dir: bool, inherited: bool) bool {
        if (path.len == 0) return inherited;
        const m = rules.match(path, is_dir);
        return if (m.by != null) m.excluded else inherited;
    }
};
