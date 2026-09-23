//! Putting work aside and bringing it back, in git's own shape.
//!
//! A stash is three or four commits, and git's commands read nothing but
//! their shape, so the shape is the format. `W`, the one `refs/stash` names,
//! records the working tree. Its first parent is the commit `HEAD` was on;
//! its second is `I`, which records the index and has that commit as its
//! only parent; a third, `U`, with no parent at all, records the untracked
//! files when they were asked for. The messages are git's, byte for byte —
//! `WIP on main: 1234567 subject`, `index on …`, `untracked files on …` — and
//! the list of stashes is the log of `refs/stash`, newest first, so
//! `git stash list` reads what is written here and this reads what git
//! wrote. The commits are never signed, because git never signs them.
//!
//! Bringing one back is a three-way merge through `merge.zig`: from the
//! commit the stash was made on, to the index as it is now on one side and
//! the stashed working tree on the other. Nothing is written until every
//! path the merge would change has been checked. A file there with changes
//! of its own, or an untracked file in the way, is a named refusal with
//! nothing touched, where git's merge refuses too. A conflict is not an
//! error: it is recorded the way git records one — the stages in the index
//! and the marked-up file in the working tree — and `pop` then keeps the
//! stash, as git does. What git does not do is refuse an ignored file in
//! the way; it overwrites it, and here that is a refusal as well.
//!
//! Merging does not look for renames, so a path the stash renamed and the
//! branch changed meets as a deletion and a change rather than as one file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("reflog.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const merge = @import("merge.zig");
const diff = @import("diff.zig");
const hooks = @import("hooks.zig");
const fs = @import("fs.zig");
const ignore = @import("ignore.zig");
const attributes = @import("attributes.zig");
const wildmatch = @import("wildmatch.zig");
const odb_mod = @import("odb.zig");
const textdiff = @import("textdiff.zig");
const convert = @import("convert.zig");
const filter = @import("filter.zig");
const program = @import("program.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;
const Index = index_mod.Index;

/// The ref every stash hangs from.
pub const ref_name = "refs/stash";

/// Errors from stashing.
pub const Error = error{
    /// A repository with no working tree has nothing to put aside.
    BareRepository,
    /// `HEAD` has no commit yet, and a stash is made on one.
    NoInitialCommit,
    /// The index holds a conflict, which no tree can record and which a
    /// stash cannot be applied on top of.
    UnmergedIndex,
    /// A path given to `push` matches nothing the index tracks.
    /// `Refusal` names it.
    PathspecMatchesNothing,
    /// There is no `stash@{n}`.
    NoSuchStash,
    /// The commit is not shaped like a stash: it needs at least two parents.
    NotAStash,
    /// A file the merge would change has changes of its own. `Refusal`
    /// names it.
    LocalChangesWouldBeOverwritten,
    /// An untracked or ignored file, or a directory with something in it,
    /// is where the stash would put a file. `Refusal` names it.
    UntrackedWouldBeOverwritten,
    /// The stash's index changes do not merge onto the index as it is,
    /// which is what git means by "conflicts in index. Try without
    /// --index."
    IndexConflict,
    /// A path the stash has as a file and the index has as a directory, or
    /// the other way round. `Refusal` names it.
    DirectoryFileConflict,
    /// An untracked directory holding a repository of its own, which a stash
    /// would record as a submodule. `Refusal` names it.
    NestedRepository,
} || repo_mod.Error || refs_mod.TransactionError || worktree.Error || merge.Error ||
    diff.Error || hooks.Error || reflog.ReadError || fs.LockError || fs.CommitError ||
    ignore.Error || attributes.Error || convert.Error || error{NameTooLong};

/// Where a refusal writes the path it is about.
pub const Refusal = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    /// The path, or empty when nothing was refused.
    pub fn path(r: *const Refusal) []const u8 {
        return r.buffer[0..r.len];
    }

    fn set(r: *Refusal, text: []const u8) void {
        r.len = @min(text.len, r.buffer.len);
        @memcpy(r.buffer[0..r.len], text[0..r.len]);
    }
};

/// Which untracked files a stash takes.
pub const Untracked = enum {
    /// None: `git stash`.
    none,
    /// Those no ignore rule excludes: `--include-untracked`.
    include,
    /// Every one, ignored or not: `--all`.
    all,
};

/// How `push` stashes.
pub const PushOptions = struct {
    /// The author and committer of the stash's commits, whose time is the
    /// caller's.
    who: object.Signature,
    /// `-m`: the stash is then `On <branch>: <message>`.
    message: ?[]const u8 = null,
    /// `--keep-index`: what is staged stays, in the index and in the working
    /// tree.
    keep_index: bool = false,
    untracked: Untracked = .none,
    /// Only these paths: each names a file, a directory, or a glob in which
    /// `*` crosses `/`, as a pathspec does. Empty is everything.
    paths: []const []const u8 = &.{},
    /// Told about the update to `refs/stash`, or `null`.
    hooks: ?*hooks.Runner = null,
    refusal: ?*Refusal = null,
    /// The clean and smudge filters to run, as `Repository.loadFilters`
    /// gives them, and the permission to run them. Without them a path a
    /// required filter names is refused, as it is everywhere.
    filters: ?*const filter.Drivers = null,
    programs: ?program.Programs = null,
};

/// How `apply` and `pop` restore.
pub const ApplyOptions = struct {
    /// `--index`: restore the index as it was stashed, not only the working
    /// tree. `null` asks `stash.index`, which is off unless set.
    index: ?bool = null,
    /// Told about any update to `refs/stash`, or `null`.
    hooks: ?*hooks.Runner = null,
    refusal: ?*Refusal = null,
    /// As for `push`.
    filters: ?*const filter.Drivers = null,
    programs: ?program.Programs = null,
};

/// One stash, with the commits and trees that make it.
pub const Stash = struct {
    /// `W`, the working tree.
    commit: Oid,
    tree: Oid,
    /// The commit `HEAD` was on.
    base: Oid,
    base_tree: Oid,
    /// `I`, the index.
    index_commit: Oid,
    index_tree: Oid,
    /// `U`, the untracked files, when there are any.
    untracked_commit: ?Oid,
    untracked_tree: ?Oid,
};

/// One line of the list.
pub const Entry = struct {
    commit: Oid,
    /// What `git stash list` prints after `stash@{n}: `. Borrowed from the
    /// list.
    message: []const u8,
};

/// Every stash, newest first: `stash@{0}` is `entries[0]`.
pub const List = struct {
    gpa: Allocator,
    log: reflog.Log,
    entries: []Entry,

    /// Release the list.
    pub fn deinit(l: *List) void {
        l.gpa.free(l.entries);
        l.log.deinit();
        l.* = undefined;
    }
};

/// What bringing a stash back did.
pub const Applied = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// The paths left in conflict, sorted. Each has its stages in the index
    /// and its marked-up content in the working tree.
    conflicts: []const []const u8,
    /// Whether the index was put back as it was stashed, which `--index`
    /// asks for and which is only needed when the stash's index differed.
    index_restored: bool = false,
    /// Whether `pop` dropped the stash, which it does only when nothing
    /// conflicted.
    dropped: bool = false,

    /// Whether every path merged.
    pub fn isClean(a: *const Applied) bool {
        return a.conflicts.len == 0;
    }

    /// Release the result.
    pub fn deinit(a: *Applied) void {
        var arena = a.arena.promote(a.gpa);
        arena.deinit();
        a.* = undefined;
    }
};

/// Every stash, newest first.
pub fn list(repo: *Repository, io: Io) Error!List {
    const gpa = repo.gpa;
    var log = try reflog.read(gpa, io, repo.common_dir, ref_name, repo.kind);
    errdefer log.deinit();
    const entries = try gpa.alloc(Entry, log.entries.len);
    for (entries, 0..) |*e, i| {
        const line = log.entries[log.entries.len - 1 - i];
        e.* = .{ .commit = line.new, .message = line.message };
    }
    return .{ .gpa = gpa, .log = log, .entries = entries };
}

/// `stash@{n}`, taken apart.
pub fn get(repo: *Repository, io: Io, n: usize) Error!Stash {
    var l = try list(repo, io);
    defer l.deinit();
    if (n >= l.entries.len) return error.NoSuchStash;
    return inspect(repo, io, l.entries[n].commit);
}

/// A commit shaped like a stash, taken apart.
pub fn inspect(repo: *Repository, io: Io, commit: Oid) Error!Stash {
    const gpa = repo.gpa;
    const found = try repo.odb.read(io, commit);
    defer gpa.free(found.bytes);
    if (found.type != .commit) return error.NotAStash;
    var parsed = try object.Commit.parse(gpa, repo.kind, found.bytes);
    defer parsed.deinit();
    if (parsed.parents.len < 2) return error.NotAStash;
    const untracked: ?Oid = if (parsed.parents.len > 2) parsed.parents[2] else null;
    return .{
        .commit = commit,
        .tree = parsed.tree,
        .base = parsed.parents[0],
        .base_tree = try repo.commitTree(io, parsed.parents[0]),
        .index_commit = parsed.parents[1],
        .index_tree = try repo.commitTree(io, parsed.parents[1]),
        .untracked_commit = untracked,
        .untracked_tree = if (untracked) |u| try repo.commitTree(io, u) else null,
    };
}

/// What `stash@{n}` changed, from the commit it was made on to the working
/// tree it recorded: `git stash show`.
pub fn show(repo: *Repository, io: Io, n: usize, options: diff.TreeOptions) Error!diff.Changes {
    const stash = try get(repo, io, n);
    return diff.tree(repo.gpa, io, &repo.odb, stash.base_tree, stash.tree, options);
}

/// Everything a stash operation carries around: the rules the working tree
/// is read with, and the index.
const Ctx = struct {
    repo: *Repository,
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    wt: Io.Dir,
    ignore_rules: ignore.Rules,
    attrs: attributes.Attrs,
    rules: worktree.Rules,
    index: Index,
    programs: ?program.Programs,
    /// What a file in the working tree is stored as: line endings, clean
    /// filters and LFS, as `addAll` stores it.
    conv: convert.Session,

    fn init(
        ctx: *Ctx,
        repo: *Repository,
        io: Io,
        arena: Allocator,
        filters: ?*const filter.Drivers,
        programs: ?program.Programs,
    ) Error!void {
        const wt = repo.work_dir orelse return error.BareRepository;
        ctx.* = .{
            .repo = repo,
            .io = io,
            .gpa = repo.gpa,
            .arena = arena,
            .wt = wt,
            .ignore_rules = try repo.loadIgnore(io),
            .attrs = undefined,
            .rules = repo.worktreeRules(),
            .index = undefined,
            .programs = programs,
            .conv = undefined,
        };
        errdefer ctx.ignore_rules.deinit();
        ctx.attrs = try repo.loadAttrs(io);
        errdefer ctx.attrs.deinit();
        ctx.rules.ignore = &ctx.ignore_rules;
        ctx.rules.attrs = &ctx.attrs;
        const required = try repo.requiredFilters(repo.gpa);
        defer repo.gpa.free(required);
        ctx.rules.required_filters = try arena.dupe([]const u8, required);
        ctx.rules.filters = filters;
        ctx.index = try repo.openIndex(io);
        ctx.conv = .init(repo.gpa, io, .{
            .wt = wt,
            .kind = repo.kind,
            .core = ctx.rules.core,
            .required_filters = ctx.rules.required_filters,
            .drivers = filters,
            .programs = programs,
            .index = &ctx.index,
            .db = &repo.odb,
        });
    }

    /// How the working tree is written: as a checkout writes it.
    fn checkoutOptions(ctx: *const Ctx) worktree.CheckoutOptions {
        return .{ .rules = ctx.rules, .programs = ctx.programs };
    }

    fn deinit(ctx: *Ctx) void {
        ctx.conv.deinit();
        ctx.index.deinit();
        ctx.attrs.deinit();
        ctx.ignore_rules.deinit();
    }

    fn unmerged(ctx: *Ctx) bool {
        for (ctx.index.entries.items) |e| {
            if (e.stage != 0) return true;
        }
        return false;
    }

    /// The path in the working tree as a tree entry would have it, or
    /// `null` when nothing but a directory, or nothing at all, is there. An
    /// entry whose recorded stat still matches is taken from the index
    /// without reading the file, which is what git's refreshed index lets it
    /// do. With `write`, the blob is stored.
    fn side(ctx: *Ctx, path: []const u8, entry: ?*const index_mod.Entry, write: bool) Error!?merge.Side {
        const found = (try fs.statAt(ctx.io, ctx.wt, path)) orelse return null;
        if (found.kind == .directory) return null;
        const indexed_mode: ?object.Mode = if (entry) |e| e.mode else null;
        const mode: object.Mode = if (found.kind == .sym_link)
            .symlink
        else if (!ctx.rules.symlinks and indexed_mode == .symlink)
            .symlink
        else if (ctx.rules.file_mode)
            (if (found.executable) .exec else .file)
        else if (indexed_mode == .exec) .exec else .file;

        if (entry) |e| {
            if (e.mode == mode and !ctx.index.isRacy(e.*) and
                e.stat.matches(found.stat, ctx.rules.check_stat, ctx.rules.timestamp_resolution))
            {
                return .{ .mode = mode, .oid = e.oid };
            }
        }
        var scratch: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const raw = if (found.kind == .sym_link) blk: {
            var buf: [4096]u8 = undefined;
            const len = try ctx.wt.readLink(ctx.io, path, &buf);
            break :blk try a.dupe(u8, buf[0..len]);
        } else try fs.readFileSized(a, ctx.io, ctx.wt, path, found.stat.size, 1 << 31);
        var content: []const u8 = raw;
        if (mode != .symlink) {
            // The working tree's own `.gitattributes` at the top, which a
            // walk loads on its way in and takes out again on its way back.
            const has_top = for (ctx.attrs.levels.items) |level| {
                if (level.base.len == 0 and level.precedence == 1) break true;
            } else false;
            if (!has_top) try ctx.attrs.addDirectory(ctx.io, ctx.wt, "", 0);
            const applied = try ctx.attrs.lookup(a, path, false);
            content = (try ctx.conv.toGit(a, path, raw, applied, if (write) .store else .hash_only)).bytes;
        }
        const oid = if (write)
            try ctx.repo.odb.write(ctx.io, .blob, content)
        else
            hash.Hasher.object(ctx.repo.kind, "blob", content);
        return .{ .mode = mode, .oid = oid };
    }

    fn stage0(ctx: *Ctx, path: []const u8) ?*index_mod.Entry {
        return ctx.index.findStage(path, 0);
    }
};

fn sameSide(a: ?merge.Side, b: ?merge.Side) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.mode == b.?.mode and a.?.oid.eql(b.?.oid);
}

fn entrySide(entry: ?*const index_mod.Entry) ?merge.Side {
    const e = entry orelse return null;
    return .{ .mode = e.mode, .oid = e.oid };
}

fn mapSide(map: *const std.StringHashMapUnmanaged(TreeEntry), path: []const u8) ?merge.Side {
    const e = map.get(path) orelse return null;
    return .{ .mode = e.mode, .oid = e.oid };
}

const TreeEntry = worktree.TreeEntry;

/// Whether a pathspec matches `path`: the path itself, a directory above
/// it, or a glob over the whole path in which `*` crosses `/`.
fn matchesAny(specs: []const []const u8, path: []const u8) bool {
    if (specs.len == 0) return true;
    for (specs) |raw| {
        const spec = std.mem.trimEnd(u8, raw, "/");
        if (spec.len == 0 or std.mem.eql(u8, spec, ".")) return true;
        if (std.mem.eql(u8, spec, path)) return true;
        if (std.mem.startsWith(u8, path, spec) and path.len > spec.len and path[spec.len] == '/') return true;
        if (std.mem.indexOfAny(u8, spec, "*?[") != null) {
            if (wildmatch.match(spec, path, .{ .pathname = false }) catch false) return true;
        }
    }
    return false;
}

/// `git stash push`: record the index and the working tree — and the
/// untracked files, if asked — as a stash, then put the working tree and
/// the index back to `HEAD`, as git does. `null` when there is nothing to
/// stash, which git reports as "No local changes to save".
pub fn push(repo: *Repository, io: Io, options: PushOptions) Error!?Oid {
    const gpa = repo.gpa;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var ctx: Ctx = undefined;
    try ctx.init(repo, io, arena, options.filters, options.programs);
    defer ctx.deinit();

    const head = (try repo.head(io)) orelse return error.NoInitialCommit;
    gpa.free(head.name);
    if (ctx.unmerged()) return error.UnmergedIndex;

    const head_bytes = try repo.odb.read(io, head.oid);
    defer gpa.free(head_bytes.bytes);
    const head_commit = try object.Commit.parse(arena, repo.kind, try arena.dupe(u8, head_bytes.bytes));
    var head_map = try worktree.flatten(arena, io, &repo.odb, head_commit.tree);

    // Every pathspec must name something the index tracks, unless untracked
    // files are being taken too.
    if (options.untracked == .none) {
        for (options.paths) |spec| {
            const hit = for (ctx.index.entries.items) |e| {
                if (matchesAny(&.{spec}, e.path)) break true;
            } else false;
            if (!hit) {
                if (options.refusal) |r| r.set(spec);
                return error.PathspecMatchesNothing;
            }
        }
    }

    // What differs, and what the working-tree commit takes from the disk:
    // every tracked path whose file is not what `HEAD` has.
    var candidates: std.StringArrayHashMapUnmanaged(void) = .empty;
    var head_it = head_map.keyIterator();
    while (head_it.next()) |key| {
        if (matchesAny(options.paths, key.*)) try candidates.put(arena, key.*, {});
    }
    for (ctx.index.entries.items) |e| {
        if (matchesAny(options.paths, e.path)) try candidates.put(arena, e.path, {});
    }
    const Update = struct { path: []const u8, side: ?merge.Side };
    var updates: std.ArrayList(Update) = .empty;
    var changed = false;
    for (candidates.keys()) |path| {
        const entry = ctx.stage0(path);
        const in_head = mapSide(&head_map, path);
        if (entry) |e| if (e.mode == .gitlink) continue;
        if (in_head) |h| if (h.mode == .gitlink) continue;
        if (!sameSide(entrySide(entry), in_head)) changed = true;
        // A directory where a file was is not something a tree can record
        // in its place, and git leaves the entry as the index has it.
        if (try fs.statAt(io, ctx.wt, path)) |found| {
            if (found.kind == .directory) {
                if (entry != null) changed = true;
                continue;
            }
        }
        const on_disk = try ctx.side(path, entry, false);
        if (entry != null and !sameSide(on_disk, entrySide(entry))) changed = true;
        if (!sameSide(on_disk, in_head)) try updates.append(arena, .{ .path = path, .side = on_disk });
    }

    var untracked_files: std.ArrayList([]const u8) = .empty;
    if (options.untracked != .none) try collectUntracked(&ctx, options, &untracked_files);
    if (!changed and untracked_files.items.len == 0) return null;

    // A log that is gone with its ref still there is cleared first, as git
    // does, so the new stash starts a list rather than joining a broken one.
    if (!try reflog.exists(io, repo.common_dir, gpa, ref_name)) {
        if (try repo.refs.read(arena, io, ref_name)) |_| try clear(repo, io, .{ .hooks = options.hooks });
    }

    // `<branch>: <abbrev> <subject>`, which every message builds on.
    const branch = (try repo.refs.currentBranch(arena, io)) orelse "(no branch)";
    var abbrev_buf: [hash.max_hex_len]u8 = undefined;
    const abbrev = try abbreviate(repo, io, head.oid, &abbrev_buf);
    const subject = try oneline(arena, head_commit.message);
    const label = try std.fmt.allocPrint(arena, "{s}: {s} {s}", .{ branch, abbrev, subject });

    // `I`: the index as it stands.
    const index_tree = try worktree.writeTree(gpa, io, &ctx.index, &repo.odb);
    const index_commit = try writeCommit(repo, io, index_tree, &.{head.oid}, options.who, try std.fmt.allocPrint(arena, "index on {s}\n", .{label}));

    // `U`: the untracked files, in a tree of their own.
    var untracked_commit: ?Oid = null;
    if (untracked_files.items.len != 0) {
        var temp: Index = .initEmpty(gpa, repo.kind);
        defer temp.deinit();
        for (untracked_files.items) |path| {
            const s = (try ctx.side(path, null, true)) orelse continue;
            try temp.add(.{ .path = path, .oid = s.oid, .mode = s.mode });
        }
        const tree = try worktree.writeTree(gpa, io, &temp, &repo.odb);
        untracked_commit = try writeCommit(repo, io, tree, &.{}, options.who, try std.fmt.allocPrint(arena, "untracked files on {s}\n", .{label}));
    }

    // `W`: the index, with every tracked file whose content differs from
    // `HEAD` taken from the disk.
    const work_tree = blk: {
        var temp: Index = .initEmpty(gpa, repo.kind);
        defer temp.deinit();
        try temp.addMany(ctx.index.entries.items);
        for (updates.items) |u| {
            if (u.side == null) {
                _ = temp.remove(u.path);
                continue;
            }
            const s = (try ctx.side(u.path, ctx.stage0(u.path), true)).?;
            try temp.add(.{ .path = u.path, .oid = s.oid, .mode = s.mode });
        }
        break :blk try worktree.writeTree(gpa, io, &temp, &repo.odb);
    };
    const message = if (options.message) |m|
        try std.fmt.allocPrint(arena, "On {s}: {s}", .{ branch, m })
    else
        try std.fmt.allocPrint(arena, "WIP on {s}", .{label});
    var parents: std.ArrayList(Oid) = .empty;
    try parents.appendSlice(arena, &.{ head.oid, index_commit });
    if (untracked_commit) |u| try parents.append(arena, u);
    const stash_commit = try writeCommit(repo, io, work_tree, parents.items, options.who, message);

    // `refs/stash` moves, and its log, which is the list, gains the line.
    {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        tx.hooks = options.hooks;
        try tx.update(ref_name, .{ .direct = stash_commit }, .any);
        try tx.commit(io, .{
            .who = options.who,
            .message = try reflog.normalizeMessage(arena, message),
            .policy = .always,
        });
    }

    try resetAfterPush(&ctx, &head_map, head_commit.tree, index_tree, untracked_files.items, options);
    try ctx.index.write(io, repo.git_dir, "index", .{});
    return stash_commit;
}

fn collectUntracked(ctx: *Ctx, options: PushOptions, out: *std.ArrayList([]const u8)) Error!void {
    var status = try worktree.status(ctx.gpa, ctx.io, ctx.wt, &ctx.index, &ctx.repo.odb, .{
        .rules = ctx.rules,
        .programs = ctx.programs,
        .untracked = .all,
        .include_ignored = options.untracked == .all,
    });
    defer status.deinit();
    for (status.entries) |e| {
        if (e.unstaged != .untracked and e.unstaged != .ignored) continue;
        const found = (try fs.statAt(ctx.io, ctx.wt, e.path)) orelse continue;
        if (found.kind == .directory) {
            // A directory reported whole: an ignored one, whose files `--all`
            // takes one by one, or one holding a repository of its own.
            if (ctx.wt.access(ctx.io, try std.fmt.allocPrint(ctx.arena, "{s}/.git", .{e.path}), .{})) |_| {
                if (options.refusal) |r| r.set(e.path);
                return error.NestedRepository;
            } else |_| {}
            try walkFiles(ctx, e.path, options.paths, out, 0);
            continue;
        }
        if (matchesAny(options.paths, e.path)) try out.append(ctx.arena, try ctx.arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, out.items, {}, lessThanPath);
}

fn walkFiles(ctx: *Ctx, dir_path: []const u8, specs: []const []const u8, out: *std.ArrayList([]const u8), depth: u32) Error!void {
    if (depth > 64) return;
    var dir = try ctx.wt.openDir(ctx.io, dir_path, .{ .iterate = true });
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (try it.next(ctx.io)) |item| {
        const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ dir_path, item.name });
        if (item.kind == .directory) {
            try walkFiles(ctx, path, specs, out, depth + 1);
        } else if (matchesAny(specs, path)) {
            try out.append(ctx.arena, path);
        }
    }
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Put the working tree and the index back the way `git stash push` does
/// after it has saved them: `git reset --hard`, or, with paths, those paths
/// back to `HEAD`; then, with `--keep-index`, the index's own content back
/// into both.
fn resetAfterPush(
    ctx: *Ctx,
    head_map: *std.StringHashMapUnmanaged(TreeEntry),
    head_tree: Oid,
    index_tree: Oid,
    untracked: []const []const u8,
    options: PushOptions,
) Error!void {
    const io = ctx.io;
    const db = &ctx.repo.odb;
    const checkout_options = ctx.checkoutOptions();

    if (options.paths.len == 0) {
        for (untracked) |path| {
            ctx.wt.deleteFile(io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            if (std.fs.path.dirnamePosix(path)) |parent| removeEmptyDirectories(io, ctx.wt, parent);
        }
        _ = try worktree.checkout(ctx.gpa, io, ctx.wt, &ctx.index, db, head_tree, checkout_options);
        if (options.keep_index and !isEmptyTree(ctx.repo.kind, index_tree)) {
            _ = try worktree.checkout(ctx.gpa, io, ctx.wt, &ctx.index, db, index_tree, checkout_options);
        }
        return;
    }

    // Only the named paths go back to `HEAD`.
    var paths: std.StringArrayHashMapUnmanaged(void) = .empty;
    var head_it = head_map.keyIterator();
    while (head_it.next()) |key| if (matchesAny(options.paths, key.*)) try paths.put(ctx.arena, key.*, {});
    for (ctx.index.entries.items) |e| if (matchesAny(options.paths, e.path)) try paths.put(ctx.arena, try ctx.arena.dupe(u8, e.path), {});
    for (untracked) |path| try paths.put(ctx.arena, path, {});
    var writes: std.ArrayList(worktree.PathWrite) = .empty;
    for (paths.keys()) |path| {
        const want = mapSide(head_map, path);
        const entry = ctx.stage0(path);
        const on_disk = try ctx.side(path, entry, false);
        if (sameSide(entrySide(entry), want) and sameSide(on_disk, want)) continue;
        try writes.append(ctx.arena, .{ .path = path, .blob = if (want) |w| .{ .mode = w.mode, .oid = w.oid } else null });
    }
    _ = try worktree.writePaths(ctx.gpa, io, ctx.wt, &ctx.index, db, writes.items, checkout_options);

    if (options.keep_index and !isEmptyTree(ctx.repo.kind, index_tree)) {
        var index_map = try worktree.flatten(ctx.arena, io, db, index_tree);
        var keep: std.StringArrayHashMapUnmanaged(void) = .empty;
        var it = index_map.keyIterator();
        while (it.next()) |key| if (matchesAny(options.paths, key.*)) try keep.put(ctx.arena, key.*, {});
        for (ctx.index.entries.items) |e| if (matchesAny(options.paths, e.path)) try keep.put(ctx.arena, try ctx.arena.dupe(u8, e.path), {});
        writes.clearRetainingCapacity();
        for (keep.keys()) |path| {
            const want = mapSide(&index_map, path);
            if (sameSide(entrySide(ctx.stage0(path)), want)) continue;
            try writes.append(ctx.arena, .{ .path = path, .blob = if (want) |w| .{ .mode = w.mode, .oid = w.oid } else null });
        }
        _ = try worktree.writePaths(ctx.gpa, io, ctx.wt, &ctx.index, db, writes.items, checkout_options);
    }
}

fn isEmptyTree(kind: hash.Kind, oid: Oid) bool {
    return oid.eql(hash.Hasher.object(kind, "tree", ""));
}

fn removeEmptyDirectories(io: Io, wt: Io.Dir, path: []const u8) void {
    var current = path;
    while (current.len != 0) {
        wt.deleteDir(io, current) catch return;
        current = std.fs.path.dirnamePosix(current) orelse return;
    }
}

/// A stash commit, written as git writes one: unsigned whatever the
/// configuration says, because git never signs them.
fn writeCommit(repo: *Repository, io: Io, tree: Oid, parents: []const Oid, who: object.Signature, message: []const u8) Error!Oid {
    const bytes = object.Commit.build(repo.gpa, repo.kind, .{
        .tree = tree,
        .parents = parents,
        .author = who,
        .committer = who,
        .message = message,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnexpectedObjectType,
    };
    defer repo.gpa.free(bytes);
    return repo.odb.write(io, .commit, bytes);
}

/// The shortest prefix of `oid`, seven digits or more, that names nothing
/// else: git's default abbreviation for a repository of this size, or
/// `core.abbrev` when it is a number.
fn abbreviate(repo: *Repository, io: Io, oid: Oid, buf: *[hash.max_hex_len]u8) Error![]const u8 {
    const hex = oid.hex(buf);
    var len: usize = 7;
    if (repo.config.getInt("core.abbrev", 7)) |configured| {
        if (configured >= 4) len = @intCast(@min(configured, @as(i64, @intCast(hex.len))));
    } else |_| {}
    while (len < hex.len) : (len += 1) {
        _ = repo.odb.findPrefix(io, hex[0..len]) catch |err| switch (err) {
            error.AmbiguousPrefix => continue,
            error.ObjectNotFound => break,
            else => |e| return e,
        };
        break;
    }
    return hex[0..len];
}

/// A commit's subject as git's one-line format prints it: the first
/// paragraph, its lines joined by spaces, trailing whitespace off each.
fn oneline(arena: Allocator, message: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, message, '\n');
    var started = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r\n");
        if (line.len == 0) {
            if (started) break;
            continue;
        }
        if (started) try out.append(arena, ' ');
        try out.appendSlice(arena, line);
        started = true;
    }
    return out.items;
}

/// `git stash apply stash@{n}`: merge the stash onto the working tree and
/// the index as they are.
pub fn apply(repo: *Repository, io: Io, n: usize, options: ApplyOptions) Error!Applied {
    const stash = try get(repo, io, n);
    return applyStash(repo, io, stash, options);
}

/// `git stash pop stash@{n}`: apply, then drop the stash if nothing
/// conflicted.
pub fn pop(repo: *Repository, io: Io, n: usize, options: ApplyOptions) Error!Applied {
    const stash = try get(repo, io, n);
    var applied = try applyStash(repo, io, stash, options);
    errdefer applied.deinit();
    if (applied.isClean()) {
        _ = try drop(repo, io, n, .{ .hooks = options.hooks });
        applied.dropped = true;
    }
    return applied;
}

/// Apply a stash commit, by name rather than by its place in the list.
pub fn applyStash(repo: *Repository, io: Io, stash: Stash, options: ApplyOptions) Error!Applied {
    const gpa = repo.gpa;
    var result_arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer result_arena.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var ctx: Ctx = undefined;
    try ctx.init(repo, io, arena, options.filters, options.programs);
    defer ctx.deinit();
    const db = &repo.odb;

    if (ctx.unmerged()) return error.UnmergedIndex;
    const current_tree = try worktree.writeTree(gpa, io, &ctx.index, db);

    // `--index`: the stash's staged changes, merged onto the index as it is.
    const use_index = options.index orelse (repo.config.getBool("stash.index", false) catch false);
    var restored_index: ?Oid = null;
    if (use_index and !stash.base_tree.eql(stash.index_tree) and !current_tree.eql(stash.index_tree)) {
        if (!try patchApplies(gpa, io, db, stash.base_tree, current_tree, stash.index_tree)) return error.IndexConflict;
        var staged = try merge.treesWithOptions(gpa, io, db, stash.base_tree, current_tree, stash.index_tree, .{ .content_merge = true });
        defer staged.deinit();
        if (!staged.isClean()) return error.IndexConflict;
        restored_index = merge.tree(io, db, &staged) catch |err| switch (err) {
            error.MergeConflict => unreachable,
            else => |e| return e,
        };
    }

    const labels: merge.BlobOptions.Labels = .{
        .ours = if (stash.base_tree.eql(current_tree)) "Version stash was based on" else "Updated upstream",
        .base = "Stash base",
        .theirs = "Stashed changes",
    };
    var result = try merge.treesWithOptions(gpa, io, db, stash.base_tree, current_tree, stash.tree, .{
        .content_merge = true,
        .blob = .{ .labels = labels },
    });
    defer result.deinit();

    var current_map = try worktree.flatten(arena, io, db, current_tree);

    // Every path the merge changes in the working tree, decided and checked
    // before anything is written.
    var writes: std.ArrayList(worktree.PathWrite) = .empty;
    var conflicted: std.StringHashMapUnmanaged(void) = .empty;
    for (result.conflicts) |c| {
        try conflicted.put(arena, c.path, {});
        switch (c.kind) {
            .directory_file => {
                if (options.refusal) |r| r.set(c.path);
                return error.DirectoryFileConflict;
            },
            .both_modified => {
                const marked = c.merged orelse continue;
                const mode = if (c.ours) |o| o.mode else c.theirs.?.mode;
                try checkWritable(&ctx, c.path, options.refusal);
                const oid = try db.write(io, .blob, marked);
                try writes.append(arena, .{ .path = c.path, .blob = .{ .mode = mode, .oid = oid }, .index = false });
            },
            .both_added => {
                const o = c.ours.?;
                const t = c.theirs.?;
                if (!o.mode.isBlob() or !t.mode.isBlob() or o.mode == .symlink or t.mode == .symlink) continue;
                const ours_blob = try db.read(io, o.oid);
                defer gpa.free(ours_blob.bytes);
                const theirs_blob = try db.read(io, t.oid);
                defer gpa.free(theirs_blob.bytes);
                var marked = merge.blobs(gpa, "", ours_blob.bytes, theirs_blob.bytes, .{ .labels = labels }) catch |err| switch (err) {
                    error.BinaryBlob => continue,
                    else => |e| return e,
                };
                defer marked.deinit();
                try checkWritable(&ctx, c.path, options.refusal);
                const oid = try db.write(io, .blob, marked.bytes);
                try writes.append(arena, .{ .path = c.path, .blob = .{ .mode = o.mode, .oid = oid }, .index = false });
            },
            .modify_delete => {
                // The side that kept the file keeps it in the working tree:
                // ours is there already; theirs has to be written.
                if (c.ours != null) continue;
                const t = c.theirs.?;
                try checkWritable(&ctx, c.path, options.refusal);
                try writes.append(arena, .{ .path = c.path, .blob = .{ .mode = t.mode, .oid = t.oid }, .index = false });
            },
        }
    }
    var merged_paths: std.StringHashMapUnmanaged(void) = .empty;
    for (result.index.entries.items) |e| {
        if (e.stage != 0) continue;
        try merged_paths.put(arena, e.path, {});
        const want: merge.Side = .{ .mode = e.mode, .oid = e.oid };
        if (sameSide(mapSide(&current_map, e.path), want)) continue;
        try checkWritable(&ctx, e.path, options.refusal);
        try writes.append(arena, .{ .path = e.path, .blob = .{ .mode = e.mode, .oid = e.oid } });
    }
    var current_it = current_map.keyIterator();
    while (current_it.next()) |key| {
        if (merged_paths.contains(key.*) or conflicted.contains(key.*)) continue;
        try checkWritable(&ctx, key.*, options.refusal);
        try writes.append(arena, .{ .path = key.*, .blob = null });
    }

    // The untracked files come back only where nothing is.
    var untracked_writes: std.ArrayList(worktree.PathWrite) = .empty;
    if (stash.untracked_tree) |tree| {
        var untracked_map = try worktree.flatten(arena, io, db, tree);
        var it = untracked_map.iterator();
        while (it.next()) |pair| {
            if (try fs.statAt(io, ctx.wt, pair.key_ptr.*)) |_| {
                if (options.refusal) |r| r.set(pair.key_ptr.*);
                return error.UntrackedWouldBeOverwritten;
            }
            try untracked_writes.append(arena, .{
                .path = pair.key_ptr.*,
                .blob = .{ .mode = pair.value_ptr.mode, .oid = pair.value_ptr.oid },
                .index = false,
            });
        }
    }

    const checkout_options = ctx.checkoutOptions();
    _ = try worktree.writePaths(gpa, io, ctx.wt, &ctx.index, db, writes.items, checkout_options);

    const result_alloc = result_arena.allocator();
    var conflicts: std.ArrayList([]const u8) = .empty;
    var applied_index = false;
    if (result.conflicts.len != 0) {
        // The index is the merge's: what reconciled is staged, and every
        // conflict sits at its stages.
        for (result.conflicts) |c| {
            _ = ctx.index.remove(c.path);
            const tree_cache = try ctx.index.cacheTree();
            tree_cache.invalidate(c.path);
            try conflicts.append(result_alloc, try result_alloc.dupe(u8, c.path));
        }
        for (result.index.entries.items) |e| {
            if (e.stage == 0) continue;
            try ctx.index.add(e);
        }
        std.mem.sort([]const u8, conflicts.items, {}, lessThanPath);
    } else if (restored_index) |tree| {
        _ = try worktree.resetIndex(gpa, io, &ctx.index, db, tree);
        applied_index = true;
    } else {
        try unstageUnlessNew(&ctx, &current_map);
    }

    _ = try worktree.writePaths(gpa, io, ctx.wt, &ctx.index, db, untracked_writes.items, checkout_options);
    try ctx.index.write(io, repo.git_dir, "index", .{});

    return .{
        .gpa = gpa,
        .arena = result_arena.state,
        .conflicts = conflicts.items,
        .index_restored = applied_index,
    };
}

/// Whether the stash's index changes, as a patch with three lines of context,
/// apply to the index as it is — which is how git restores the index, with
/// `git apply --cached`, and why it refuses changes a three-way merge would
/// take: a patch needs its context lines unchanged as well. A file the
/// patch adds must not be there; one it removes must be exactly what it
/// removes; a binary file must be exactly its old self; and no line a hunk
/// carries, context included, may have changed since.
fn patchApplies(gpa: Allocator, io: Io, db: *odb_mod.Odb, base: Oid, current: Oid, staged: Oid) Error!bool {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var base_map = try worktree.flatten(arena, io, db, base);
    var current_map = try worktree.flatten(arena, io, db, current);
    var staged_map = try worktree.flatten(arena, io, db, staged);

    var paths: std.StringArrayHashMapUnmanaged(void) = .empty;
    inline for (.{ &base_map, &staged_map }) |map| {
        var it = map.keyIterator();
        while (it.next()) |key| try paths.put(arena, key.*, {});
    }
    for (paths.keys()) |path| {
        const b = mapSide(&base_map, path);
        const s = mapSide(&staged_map, path);
        if (sameSide(b, s)) continue;
        const c = mapSide(&current_map, path);
        const old = b orelse {
            if (c != null) return false;
            continue;
        };
        const new = s orelse {
            if (!sameSide(c, old)) return false;
            continue;
        };
        const now = c orelse return false;
        if (old.oid.eql(new.oid) or old.oid.eql(now.oid)) continue;
        const old_blob = try db.read(io, old.oid);
        defer gpa.free(old_blob.bytes);
        const new_blob = try db.read(io, new.oid);
        defer gpa.free(new_blob.bytes);
        const now_blob = try db.read(io, now.oid);
        defer gpa.free(now_blob.bytes);
        if (textdiff.isBinary(old_blob.bytes) or textdiff.isBinary(new_blob.bytes) or textdiff.isBinary(now_blob.bytes)) return false;

        const old_lines = try textdiff.splitLines(arena, old_blob.bytes);
        const new_lines = try textdiff.splitLines(arena, new_blob.bytes);
        const now_lines = try textdiff.splitLines(arena, now_blob.bytes);
        const patch = try textdiff.diffLines(arena, old_lines, new_lines, .{});
        const hunks = try textdiff.hunks(arena, patch, old_lines.len, new_lines.len, .{});
        const moved = try textdiff.diffLines(arena, old_lines, now_lines, .{});
        for (hunks) |h| {
            const start = h.old_start;
            const end = h.old_start + h.old_count;
            for (moved) |m| {
                if (m.old_count > 0) {
                    if (m.old_start < end and m.old_start + m.old_count > start) return false;
                    continue;
                }
                // An insertion breaks the run of lines the hunk needs when it
                // lands inside it, or before a hunk that starts the file or
                // after one that ends it, which git anchors there.
                const at = m.old_start;
                if (at > start and at < end) return false;
                if (at == start and start == 0) return false;
                if (at == end and end == old_lines.len) return false;
            }
        }
    }
    return true;
}

/// Refuse to write over something the merge must not lose: a tracked file
/// with changes of its own, or anything untracked.
fn checkWritable(ctx: *Ctx, path: []const u8, refusal: ?*Refusal) Error!void {
    const entry = ctx.stage0(path);
    const found = try fs.statAt(ctx.io, ctx.wt, path);
    if (entry) |e| {
        if (found) |f| if (f.kind == .directory) {
            if (refusal) |r| r.set(path);
            return error.UntrackedWouldBeOverwritten;
        };
        if (!sameSide(try ctx.side(path, e, false), entrySide(e))) {
            if (refusal) |r| r.set(path);
            return error.LocalChangesWouldBeOverwritten;
        }
        return;
    }
    const f = found orelse return;
    if (f.kind == .directory) {
        var dir = ctx.wt.openDir(ctx.io, path, .{ .iterate = true }) catch return;
        defer dir.close(ctx.io);
        var it = dir.iterate();
        if ((try it.next(ctx.io)) == null) return;
    }
    if (refusal) |r| r.set(path);
    return error.UntrackedWouldBeOverwritten;
}

/// After a clean merge without `--index`, what the merge staged goes back
/// to the index as it was — except a file that is new, which stays added,
/// so it is not lost as untracked. git's `unstage_changes_unless_new`.
fn unstageUnlessNew(ctx: *Ctx, before: *std.StringHashMapUnmanaged(TreeEntry)) Error!void {
    var it = before.iterator();
    while (it.next()) |pair| {
        const path = pair.key_ptr.*;
        const was: merge.Side = .{ .mode = pair.value_ptr.mode, .oid = pair.value_ptr.oid };
        if (sameSide(entrySide(ctx.stage0(path)), was)) continue;
        const tree_cache = try ctx.index.cacheTree();
        tree_cache.invalidate(path);
        try ctx.index.add(.{ .path = path, .oid = was.oid, .mode = was.mode, .stat = .none });
    }
}

/// What `drop` and `clear` need.
pub const DropOptions = struct {
    /// Told about the removal of `refs/stash`, when the last stash goes.
    hooks: ?*hooks.Runner = null,
};

/// `git stash drop stash@{n}`: take the line out of the list, and move
/// `refs/stash` if the newest one went. The line after it takes the dropped
/// one's old value, so the log still reads as a chain, which is what git's
/// `reflog delete --rewrite` does. Returns the commit dropped.
pub fn drop(repo: *Repository, io: Io, n: usize, options: DropOptions) Error!Oid {
    const gpa = repo.gpa;
    var ref_buffer: [256]u8 = undefined;
    var ref_lock = try fs.LockFile.open(gpa, io, repo.common_dir, ref_name, &ref_buffer, .{});
    var ref_held = true;
    defer if (ref_held) ref_lock.deinit(io);

    const log_path = "logs/" ++ ref_name;
    const bytes = (try fs.readFileAlloc(gpa, io, repo.common_dir, log_path, 1 << 30)) orelse return error.NoSuchStash;
    defer gpa.free(bytes);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var split = std.mem.splitScalar(u8, bytes, '\n');
    while (split.next()) |line| if (line.len != 0) try lines.append(gpa, line);
    if (n >= lines.items.len) return error.NoSuchStash;

    const hex_len = repo.kind.hexLen();
    const gone_at = lines.items.len - 1 - n;
    const gone_line = lines.items[gone_at];
    if (gone_line.len < 2 * hex_len + 1) return error.MalformedReflogEntry;
    const dropped = Oid.parse(repo.kind, gone_line[hex_len + 1 .. 2 * hex_len + 1]) catch return error.MalformedReflogEntry;
    _ = lines.orderedRemove(gone_at);

    if (lines.items.len == 0) {
        ref_lock.deinit(io);
        ref_held = false;
        try clear(repo, io, .{ .hooks = options.hooks });
        return dropped;
    }

    var log_buffer: [4096]u8 = undefined;
    var log_lock = try fs.LockFile.open(gpa, io, repo.common_dir, log_path, &log_buffer, .{});
    defer log_lock.deinit(io);
    var last_kept = Oid.zero(repo.kind);
    var hex: [hash.max_hex_len]u8 = undefined;
    for (lines.items) |line| {
        if (line.len < 2 * hex_len + 1) return error.MalformedReflogEntry;
        log_lock.writer().print("{s}{s}\n", .{ last_kept.hex(&hex), line[hex_len..] }) catch return error.WriteFailed;
        last_kept = Oid.parse(repo.kind, line[hex_len + 1 .. 2 * hex_len + 1]) catch return error.MalformedReflogEntry;
    }
    try log_lock.commit(io);
    if (n == 0) {
        ref_lock.writer().print("{s}\n", .{last_kept.hex(&hex)}) catch return error.WriteFailed;
        try ref_lock.commit(io);
    }
    return dropped;
}

/// `git stash clear`: remove `refs/stash` and the list with it.
pub fn clear(repo: *Repository, io: Io, options: DropOptions) Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena_instance.deinit();
    if (try repo.refs.read(arena_instance.allocator(), io, ref_name)) |current| {
        var tx = repo.beginRefs();
        defer tx.deinit(io);
        tx.hooks = options.hooks;
        switch (current) {
            .direct => |oid| try tx.delete(ref_name, .{ .matches = oid }),
            .symbolic => try tx.delete(ref_name, .any),
        }
        // Deleting the ref deletes its log, which is the list.
        try tx.commit(io, null);
    }
}
