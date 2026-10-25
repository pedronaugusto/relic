//! What a stretch of superproject history does to its submodules, and which
//! of them a fetch goes into: git's `collect_changed_submodules`,
//! `calculate_changed_submodule_paths` and the choice `fetch_task_create`
//! makes, for `transport.fetch`'s recursion; and `submodule_has_commits`,
//! which a push asks too.
//!
//! A commit changes a submodule where its gitlink differs from the one in
//! every parent, as git's combined diff finds it, so a merge that took one
//! side's gitlink changes nothing and a root commit changes nothing. Each
//! submodule is named as the changing commit's `.gitmodules` names it, or,
//! when that names none, by its path while a repository is checked out
//! there; a path whose stand-in name `.gitmodules` gives to another
//! submodule is left out with git's warning.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const repo_mod = @import("../repo/repo.zig");
const config_mod = @import("../config/config.zig");
const gitmodules = @import("../config/gitmodules.zig");
const gitlink = @import("../discover.zig").gitlink;
const rev_walk = @import("../walk/walk.zig");
const warning = @import("../report.zig").warning;
const submodule = @import("submodule.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;
const Gitmodules = gitmodules.Gitmodules;

pub const Error = error{
    /// `fetch.recurseSubmodules` or a submodule's `fetchRecurseSubmodules`
    /// is neither a boolean nor `on-demand`: git's "bad
    /// fetch.recursesubmodules argument".
    InvalidFetchRecurse,
    /// `submodule.fetchJobs` is not a number, or is below zero.
    InvalidFetchJobs,
    /// A gitlink names an object the submodule holds that is not a commit:
    /// git's "submodule entry '<path>' (<oid>) is a <type>, not a commit".
    GitlinkNotACommit,
} || submodule.Error || rev_walk.Error;

/// How far a fetch goes into submodules: git's `--recurse-submodules`
/// values.
pub const Recurse = gitmodules.FetchRecurse;

/// What a stretch of history covers: the commits `tips` reach and `hidden`
/// do not, as `git rev-list <tips> --not <hidden>` lists them. A name that
/// is not a commit, peeled, is passed over.
pub const Range = struct {
    tips: []const Oid,
    hidden: []const Oid,
    /// Where a path left out for the name it stands in for goes.
    warnings: ?*warning.Warnings = null,
};

/// One submodule a stretch of history moves.
pub const Changed = struct {
    name: []const u8,
    /// Its path in `commit`, the first commit walked that moves it.
    path: []const u8,
    commit: Oid,
    /// Every commit the stretch records it at, each once.
    commits: []const Oid,
};

/// git's `collect_changed_submodules`: each submodule some commit of
/// `range` moves, in the order the walk first meets it. `arena`'s.
pub fn changedSubmodules(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, range: Range) Self.Error![]Changed {
    var walk: rev_walk.Walk = .init(gpa, repo.objectDatabase());
    defer walk.deinit();
    for (range.tips) |oid| if (try commitOf(io, repo, oid)) |commit| try walk.push(commit);
    for (range.hidden) |oid| if (try commitOf(io, repo, oid)) |commit| try walk.hide(commit);

    var found: std.ArrayList(Changed) = .empty;
    var commits: std.ArrayList(std.ArrayList(Oid)) = .empty;
    var links: std.ArrayList(Link) = .empty;
    while (try walk.next(io)) |commit| {
        if (commit.parents.len == 0) continue;
        links.clearRetainingCapacity();
        const parent_trees = try arena.alloc(?Oid, commit.parents.len);
        for (commit.parents, parent_trees) |parent, *tree| tree.* = try repo.commitTree(io, parent);
        try changedLinks(arena, io, repo, commit.tree, parent_trees, "", &links);
        if (links.items.len == 0) continue;
        var modules = try submodule.gitmodulesOfTree(gpa, io, repo, commit.tree);
        defer modules.deinit();
        for (links.items) |link| {
            const name = try nameAt(arena, gpa, io, repo, &modules, commit.oid, link.path, range.warnings) orelse continue;
            const at = for (found.items, 0..) |c, i| {
                if (std.mem.eql(u8, c.name, name)) break i;
            } else blk: {
                try found.append(arena, .{ .name = name, .path = link.path, .commit = commit.oid, .commits = &.{} });
                try commits.append(arena, .empty);
                break :blk found.items.len - 1;
            };
            if (!contains(commits.items[at].items, link.oid)) try commits.items[at].append(arena, link.oid);
        }
    }
    for (found.items, commits.items) |*c, *list| c.commits = try list.toOwnedSlice(arena);
    return found.toOwnedSlice(arena);
}

/// The name of the submodule at `path` in `commit`: its `.gitmodules`
/// section's, else the path while a repository is checked out there --
/// unless a section already has that name, which git warns of and skips.
fn nameAt(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, modules: *const Gitmodules, commit: Oid, path: []const u8, warnings: ?*warning.Warnings) Self.Error!?[]const u8 {
    if (modules.byPath(path)) |sub| return try arena.dupe(u8, sub.name);
    const name = try populatedPath(gpa, io, repo, path) orelse return null;
    if (modules.byName(name) != null) {
        var hex: [hash.max_hex_len]u8 = undefined;
        try warning.note(warnings, .{ .submodule_name_collides = .{ .commit = commit.hex(&hex), .path = path } });
        return null;
    }
    return name;
}

/// git's `default_name_or_path`: `path` while a repository is checked out
/// there, else `null`.
fn populatedPath(gpa: Allocator, io: Io, repo: *Repository, path: []const u8) Self.Error!?[]const u8 {
    const wt = (repo.workDirectory() orelse return null).get();
    return if (try gitlink.isRepository(gpa, io, wt, path)) path else null;
}

const Link = struct { path: []const u8, oid: Oid };

/// The gitlinks under `tree` that differ from the entry at the same path in
/// every parent tree: git's multi-tree scan for a combined diff, kept to
/// gitlinks. A subtree the same as one parent's holds nothing that does.
fn changedLinks(arena: Allocator, io: Io, repo: *Repository, tree: Oid, parents: []const ?Oid, prefix: []const u8, out: *std.ArrayList(Link)) Self.Error!void {
    const db = repo.objectDatabase();
    const found = try db.read(io, tree);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.UnexpectedObjectType;
    const parent_bytes = try arena.alloc(?[]const u8, parents.len);
    defer for (parent_bytes) |bytes| if (bytes) |b| db.allocator().free(b);
    for (parents, parent_bytes) |parent, *bytes| {
        bytes.* = null;
        const oid = parent orelse continue;
        const read = try db.read(io, oid);
        if (read.type != .tree) {
            db.allocator().free(read.bytes);
            continue;
        }
        bytes.* = read.bytes;
    }
    var it = object.Tree.parse(repo.objectFormat(), found.bytes).iterate();
    const below = try arena.alloc(?Oid, parents.len);
    entries: while (try it.next()) |entry| {
        const is_link = entry.mode == .gitlink;
        if (!is_link and !entry.mode.isTree()) continue;
        for (parent_bytes, below) |bytes, *sub| {
            sub.* = null;
            const theirs = (try object.Tree.parse(repo.objectFormat(), bytes orelse continue).find(entry.name)) orelse continue;
            if (theirs.mode == entry.mode and theirs.oid.eql(entry.oid)) continue :entries;
            if (theirs.mode.isTree()) sub.* = theirs.oid;
        }
        const path = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try arena.print("{s}/{s}", .{ prefix, entry.name });
        if (is_link) {
            try out.append(arena, .{ .path = path, .oid = entry.oid });
        } else {
            try changedLinks(arena, io, repo, entry.oid, try arena.dupe(?Oid, below), path, out);
        }
    }
}

/// `oid` peeled to a commit, or `null` when it names something else or
/// nothing this repository has.
fn commitOf(io: Io, repo: *Repository, oid: Oid) Self.Error!?Oid {
    const peeled = repo.peel(io, oid) catch |err| switch (err) {
        error.ObjectNotFound => return null,
        else => |e| return e,
    };
    const header = try repo.objectDatabase().readHeader(io, peeled);
    return if (header.type == .commit) peeled else null;
}

fn contains(list: []const Oid, oid: Oid) bool {
    for (list) |o| if (o.eql(oid)) return true;
    return false;
}

/// git's `submodule_has_commits`: whether `sub`, a submodule's repository,
/// holds every one of `commits` and some ref of its own reaches each.
pub fn hasCommits(gpa: Allocator, io: Io, sub: *Repository, commits: []const Oid) Self.Error!bool {
    for (commits) |oid| {
        const header = sub.objectDatabase().readHeader(io, oid) catch |err| switch (err) {
            error.ObjectNotFound => return false,
            else => |e| return e,
        };
        if (header.type != .commit) return error.GitlinkNotACommit;
    }
    // `git rev-list -n 1 <commits> --not --all` printing nothing.
    var walk: rev_walk.Walk = .init(gpa, sub.objectDatabase());
    defer walk.deinit();
    for (commits) |oid| try walk.push(oid);
    var refs = try sub.refStore().list(gpa, io, "refs/");
    defer refs.deinit();
    for (refs.entries) |ref| switch (ref.target) {
        .direct => |oid| if (try commitOf(io, sub, oid)) |commit| try walk.hide(commit),
        .symbolic => {},
    };
    if (try sub.refStore().head(gpa, io)) |head| {
        defer gpa.free(head.name);
        if (try commitOf(io, sub, head.oid)) |commit| try walk.hide(commit);
    }
    return try walk.next(io) == null;
}

//=========================================================================
// Which submodules a fetch goes into
//=========================================================================

/// How a fetch chooses: git's `fetch_submodules` arguments.
pub const FetchChoice = struct {
    /// The history the fetch brought: the values fetched against the refs
    /// before it.
    range: Range,
    /// `--recurse-submodules` or its settings, which beat each submodule's
    /// own: `fetch.recurseSubmodules`, `submodule.recurse`, then
    /// `.gitmodules`' `fetch.recurseSubmodules`. `null` leaves it to each.
    explicit: ?Recurse,
    /// What a submodule that says nothing does: git's
    /// `--recurse-submodules-default`, `on_demand` at the top.
    default: Recurse = .on_demand,
    /// git's `--jobs`; see `fetchJobs`.
    jobs: ?u32 = null,
};

/// One submodule a fetch goes into: git's `fetch_task`.
pub const FetchTask = struct {
    name: []const u8,
    path: []const u8,
    /// What the submodule's own fetch does with its submodules when they
    /// say nothing: `on` or `on_demand`.
    default: Recurse,
    /// The commit whose `.gitmodules` names it, for one only the fetched
    /// history has; `null` for one the index holds.
    commit: ?Oid,
    /// The commits the fetched history records it at, which a second fetch
    /// asks for by name when the first did not bring them.
    wanted: []const Oid,
};

/// What `planFetch` decided.
pub const FetchPlan = struct {
    /// `FetchChoice.explicit`, else `.gitmodules`' `fetch.recurseSubmodules`:
    /// what each submodule's own fetch is told, as git passes it on.
    explicit: ?Recurse,
    /// How many at once: `fetchJobs`.
    jobs: u32,
    tasks: []const FetchTask,
    /// Gitlinks of the index whose directory holds something but no
    /// repository: git's "Could not access submodule", which fails the
    /// fetch.
    inaccessible: []const []const u8,
    /// Submodules the fetched history moves whose repository is nowhere:
    /// git's "Could not access submodule '<path>' at commit <commit>",
    /// which does not.
    missing: []const Changed,
};

/// git's choice of submodules for `fetch_submodules`: every gitlink of the
/// index, then every submodule `choice.range` moves that is active at the commit
/// that moves it, each once, kept where its `fetchRecurseSubmodules` (or
/// `choice`) says to go in -- `on_demand` only for one whose new commits
/// it does not already hold. `arena`'s.
pub fn planFetch(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, choice: FetchChoice) Self.Error!FetchPlan {
    var tasks: std.ArrayList(FetchTask) = .empty;
    var inaccessible: std.ArrayList([]const u8) = .empty;
    var missing: std.ArrayList(Changed) = .empty;
    var plan: FetchPlan = .{ .explicit = choice.explicit, .jobs = 1, .tasks = &.{}, .inaccessible = &.{}, .missing = &.{} };
    const wt = (repo.workDirectory() orelse return plan).get();
    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try submodule.list(gpa, io, repo, &index, null);
    defer listing.deinit();
    if (plan.explicit == null) if (listing.gitmodules.fetch_recurse) |text| {
        plan.explicit = try parseRecurse(text);
    };
    if (plan.explicit == .off) return plan;
    plan.jobs = try fetchJobs(repo, &listing.gitmodules, choice.jobs);
    var chosen = choice;
    chosen.explicit = plan.explicit;
    const changed = try stillWanted(arena, gpa, io, repo, &listing.gitmodules, if (listing.gitmodules.submodules.len != 0 or try hasAbsorbed(io, repo))
        try changedSubmodules(arena, gpa, io, repo, choice.range)
    else
        &.{});

    var seen: std.ArrayList([]const u8) = .empty;
    for (listing.entries) |entry| {
        const name = if (entry.name()) |n| try arena.dupe(u8, n) else try populatedPath(arena, io, repo, entry.path) orelse continue;
        if (containsName(seen.items, name)) continue;
        const wanted = for (changed) |c| {
            if (std.mem.eql(u8, c.name, name)) break c.commits;
        } else null;
        const default = try taskDefault(arena, repo, entry.module, name, chosen, wanted != null) orelse continue;
        if (!try hasRepository(gpa, io, repo, entry.path, name)) {
            if (!try isEmptyDir(io, wt, entry.path)) try inaccessible.append(arena, try arena.dupe(u8, entry.path));
            continue;
        }
        try seen.append(arena, name);
        try tasks.append(arena, .{ .name = name, .path = try arena.dupe(u8, entry.path), .default = default, .commit = null, .wanted = wanted orelse &.{} });
    }
    for (changed) |c| {
        if (containsName(seen.items, c.name)) continue;
        var modules = try submodule.gitmodulesOfTree(gpa, io, repo, try repo.commitTree(io, c.commit));
        defer modules.deinit();
        const module = modules.byPath(c.path) orelse continue;
        if (!try submodule.isActive(arena, repo, module.name, c.path)) continue;
        const default = try taskDefault(arena, repo, module, module.name, chosen, true) orelse continue;
        if (!try hasRepository(gpa, io, repo, c.path, module.name)) {
            try missing.append(arena, c);
            continue;
        }
        try seen.append(arena, c.name);
        try tasks.append(arena, .{ .name = c.name, .path = c.path, .default = default, .commit = c.commit, .wanted = c.commits });
    }
    plan.tasks = try tasks.toOwnedSlice(arena);
    plan.inaccessible = try inaccessible.toOwnedSlice(arena);
    plan.missing = try missing.toOwnedSlice(arena);
    return plan;
}

/// git's `get_fetch_recurse_config` and the switch after it: what the
/// submodule's own fetch passes down, or `null` to leave it out.
fn taskDefault(arena: Allocator, repo: *Repository, module: ?*const gitmodules.Submodule, name: []const u8, choice: FetchChoice, changed: bool) Self.Error!?Recurse {
    const mode = choice.explicit orelse configured: {
        const key = try arena.print("submodule.{s}.fetchrecursesubmodules", .{name});
        if (repo.configuration().find(key)) |entry| break :configured try parseRecurse(entry.value);
        if (module) |m| if (m.fetch_recurse) |r| break :configured r;
        break :configured choice.default;
    };
    return switch (mode) {
        .on_demand => if (changed) .on_demand else null,
        .on => .on,
        .off => null,
    };
}

/// git's `parse_fetch_recurse_submodules_arg`.
pub fn parseRecurse(value: ?[]const u8) Self.Error!Recurse {
    return gitmodules.FetchRecurse.parse(value) catch error.InvalidFetchRecurse;
}

/// The changed submodules a fetch still needs: git drops each whose
/// repository, checked out at its path in the working tree's
/// `.gitmodules`, already has every new commit, reachable from its refs.
/// One not checked out there is kept, as git's `rev-list` in its
/// directory fails.
fn stillWanted(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, modules: *const Gitmodules, changed: []Changed) Self.Error![]const Changed {
    var kept: std.ArrayList(Changed) = .empty;
    for (changed) |c| {
        const path = if (modules.byName(c.name)) |m| m.path orelse c.name else try populatedPath(gpa, io, repo, c.name) orelse {
            try kept.append(arena, c);
            continue;
        };
        if (try populatedPath(gpa, io, repo, path) == null) {
            try kept.append(arena, c);
            continue;
        }
        var sub = (try submodule.openRepository(gpa, io, repo, .{ .path = path, .name = c.name }, .{})) orelse {
            try kept.append(arena, c);
            continue;
        };
        defer sub.deinit(io);
        if (!try hasCommits(gpa, io, &sub, c.commits)) try kept.append(arena, c);
    }
    return kept.items;
}

fn hasRepository(gpa: Allocator, io: Io, repo: *Repository, path: []const u8, name: []const u8) Self.Error!bool {
    var sub = (try submodule.openRepository(gpa, io, repo, .{ .path = path, .name = name }, .{})) orelse return false;
    sub.deinit(io);
    return true;
}

/// git's `repo_has_absorbed_submodules`: `modules/` holds something.
fn hasAbsorbed(io: Io, repo: *Repository) Self.Error!bool {
    var dir = repo.gitDirectory().get().openDir(io, "modules", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    return try it.next(io) != null;
}

fn isEmptyDir(io: Io, wt: Io.Dir, path: []const u8) Self.Error!bool {
    var dir = wt.openDir(io, path, .{ .iterate = true }) catch return true;
    defer dir.close(io);
    var it = dir.iterate();
    return try it.next(io) == null;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// How many submodules a fetch fetches at once: `explicit` (git's
/// `--jobs`), else `submodule.fetchJobs` from the configuration, then from
/// `.gitmodules`, else `fetch.parallel`; 0 is one per processor.
pub fn fetchJobs(repo: *Repository, modules: *const Gitmodules, explicit: ?u32) Self.Error!u32 {
    const config = repo.configuration();
    const jobs: i64 = if (explicit) |j| j else if (config.find("submodule.fetchjobs") != null)
        config.getInt("submodule.fetchjobs", 1) catch return error.InvalidFetchJobs
    else if (modules.fetch_jobs) |text|
        config_mod.parseInteger(text) catch return error.InvalidFetchJobs
    else
        config.getInt("fetch.parallel", 1) catch return error.InvalidFetchJobs;
    if (jobs < 0) return error.InvalidFetchJobs;
    if (jobs == 0) return @intCast(std.Thread.getCpuCount() catch 1);
    return @intCast(@min(jobs, std.math.maxInt(u32)));
}

//=========================================================================
// What a push would leave the remote without
//=========================================================================

/// A submodule whose commits a push records and no remote of its own has.
pub const Unpushed = struct { name: []const u8, path: []const u8 };

/// What a push sends: the new values, and the remote they go to.
pub const PushRange = struct { commits: []const Oid, remote: []const u8 };

/// git's `find_unpushed_submodules`: each submodule the commits pushed
/// move -- those `refs/remotes/<remote>/` does not reach -- that is checked
/// out at its path in the working tree's `.gitmodules`, holds every commit
/// recorded, has remote-tracking refs, and has a commit none of them
/// reaches. `arena`'s.
pub fn unpushedSubmodules(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, range: PushRange) Self.Error![]const Unpushed {
    var hidden: std.ArrayList(Oid) = .empty;
    var tracking = try repo.refStore().list(gpa, io, try arena.print("refs/remotes/{s}/", .{range.remote}));
    defer tracking.deinit();
    for (tracking.entries) |ref| switch (ref.target) {
        .direct => |oid| try hidden.append(arena, oid),
        .symbolic => {},
    };
    const changed = try changedSubmodules(arena, gpa, io, repo, .{ .tips = range.commits, .hidden = hidden.items });
    if (changed.len == 0) return &.{};
    var index = try repo.openIndex(io);
    defer index.deinit();
    var modules = try submodule.loadGitmodules(gpa, io, repo, &index);
    defer modules.deinit();
    var out: std.ArrayList(Unpushed) = .empty;
    for (changed) |c| {
        const path = if (modules.byName(c.name)) |m| try arena.dupe(u8, m.path orelse c.name) else try populatedPath(gpa, io, repo, c.name) orelse continue;
        if (try needsPushing(gpa, io, repo, .{ .path = path, .name = c.name }, c.commits)) try out.append(arena, .{ .name = c.name, .path = path });
    }
    return out.items;
}

/// git's `submodule_needs_pushing`: a submodule not checked out, or
/// without every commit, is taken not to need it, as git takes it.
fn needsPushing(gpa: Allocator, io: Io, repo: *Repository, module: submodule.PathName, commits: []const Oid) Self.Error!bool {
    if (try populatedPath(gpa, io, repo, module.path) == null) return false;
    var sub = (try submodule.openRepository(gpa, io, repo, module, .{})) orelse return false;
    defer sub.deinit(io);
    if (!try hasCommits(gpa, io, &sub, commits)) return false;
    var remotes = try sub.refStore().list(gpa, io, "refs/remotes/");
    defer remotes.deinit();
    if (remotes.entries.len == 0) return false;
    // `git rev-list <commits> --not --remotes -n 1` printing something.
    var walk: rev_walk.Walk = .init(gpa, sub.objectDatabase());
    defer walk.deinit();
    for (commits) |oid| try walk.push(oid);
    for (remotes.entries) |ref| switch (ref.target) {
        .direct => |oid| if (try commitOf(io, &sub, oid)) |commit| try walk.hide(commit),
        .symbolic => {},
    };
    return try walk.next(io) != null;
}
