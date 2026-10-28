//! Linked worktrees: the administrative directory git keeps and the `.git`
//! file it puts in the destination.
//!
//! What is on the disk, measured against git rather than read from a
//! document: `<common>/worktrees/<id>/` holding `HEAD`, `gitdir`,
//! `commondir`, `index` and `logs/HEAD`, and a `.git` *file* in
//! the destination whose only line is `gitdir: <absolute path>`. A worktree
//! git added with `worktree.useRelativePaths` holds both paths relative: the
//! `gitdir` file's to the administrative directory, the `.git` file's to
//! the working tree; both are read either way. In a
//! repository whose refs are a reftable stack, `HEAD` is in
//! a stack of the worktree's own under `reftable/`, and the `HEAD` file is
//! the placeholder git leaves there.

const date = @import("../text.zig").date;
const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const gitfile = @import("../discover.zig").gitfile;
const safe_path = @import("../names.zig").path;
const ref_names = @import("../names.zig").ref;
const refs_mod = @import("../refs/refs.zig");

const Oid = hash.Oid;

/// Errors from managing linked worktrees.
pub const Error = error{
    /// A worktree of that name is already registered.
    WorktreeExists,
    /// No worktree of that name is registered.
    WorktreeNotFound,
    /// The worktree has a `locked` file beside it, so it is not pruned or
    /// removed. `lockReason` says why, when a reason was given.
    WorktreeLocked,
    /// The destination is not empty, and `add` will not write into a
    /// directory that already holds something.
    DestinationNotEmpty,
    /// A name that cannot be a directory under `worktrees/`, or a path to
    /// write into one of its files that holds a newline.
    InvalidWorktreeName,
    /// `AddOptions.branch` is no name git's `check-ref-format` takes.
    InvalidBranchName,
    /// The administrative directory is there but does not hold what a
    /// worktree needs, or the working tree it names has a `.git` that does
    /// not point back at it: git's "validation failed", which `remove` and
    /// `move` stop at rather than touch a directory that is not this
    /// worktree's.
    CorruptWorktree,
} || Allocator.Error || Io.Dir.OpenError || aegis.own.ReadFileError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError ||
    Io.Dir.DeleteTreeError || Io.Dir.RenameError || Io.Dir.WriteFileError ||
    Io.File.OpenError || Io.Writer.Error || Io.File.SyncError ||
    Io.Dir.Iterator.Error || Io.Dir.RealPathError || refs_mod.ReadError ||
    refs_mod.TransactionError || refs_mod.CreateError;

/// One registered worktree.
pub const Entry = struct {
    /// The directory name under `worktrees/`. Owned by the listing.
    name: []const u8,
    /// The absolute path of the working tree, from the admin directory's
    /// `gitdir` file with the trailing `/.git` removed, a relative one taken
    /// from the admin directory. Owned by the listing.
    path: []const u8,
    /// What its `HEAD` holds: a branch name, or `null` when detached.
    /// Owned by the listing.
    branch: ?[]const u8,
    /// The object its `HEAD` resolves to, when it is detached or the branch
    /// exists.
    head: ?Oid,
    /// Whether a `locked` file sits beside it.
    locked: bool,
    /// The text of that file, when it has any. Owned by the listing.
    lock_reason: ?[]const u8,
    /// Whether the working tree the `gitdir` file names is gone, which is
    /// what makes it prunable.
    prunable: bool,
};

/// Every registered worktree.
pub const Listing = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    entries: []Entry,

    /// Release the listing.
    pub fn deinit(l: *Listing) void {
        var arena = l.arena.promote(l.gpa);
        arena.deinit();
        l.* = undefined;
    }

    /// The entry named `name`, or `null`.
    pub fn find(l: *const Listing, name: []const u8) ?Entry {
        for (l.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// The entry whose working tree is at `path`, or `null`.
    pub fn findPath(l: *const Listing, path: []const u8) ?Entry {
        for (l.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

/// Every worktree registered under the repository's `worktrees/`, each
/// one's `HEAD` read through `refs`, the repository's ref store, as
/// `worktrees/<name>/HEAD`.
///
/// The main working tree is not one of these: it has no administrative
/// directory, and a caller that wants it in a list adds it.
pub fn list(gpa: Allocator, io: Io, refs: *const refs_mod.Store) Self.Error!Listing {
    const common_dir = refs.commonDir().get();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var entries: std.ArrayList(Entry) = .empty;

    const worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{
            .gpa = gpa,
            .arena = arena_instance.state,
            .entries = &.{},
        },
        else => |e| return e,
    };
    defer worktrees_dir.close(io);

    // ids as git's `readdir` gives them: composed under
    // `core.precomposeUnicode` on macOS
    var it: fs.Names = .init(worktrees_dir, refs.precomposeUnicode());
    while (try it.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        const admin = worktrees_dir.openDir(io, dir_entry.name, .{ .iterate = true }) catch continue;
        defer admin.close(io);

        const named = try namedTree(arena, io, admin) orelse continue;

        // A worktree whose `.git` file is gone is one git prunes: the
        // directory it pointed at has been deleted by hand.
        var prunable = true;
        if (std.Io.Dir.accessAbsolute(io, named.gitfile, .{})) |_| {
            prunable = false;
        } else |_| {}

        const lock_text = try fs.readFileAlloc(arena, io, admin, "locked", 4096);
        var branch: ?[]const u8 = null;
        var head: ?Oid = null;
        const head_name = try arena.print("worktrees/{s}/HEAD", .{dir_entry.name});
        const value = refs.read(arena, io, head_name) catch |err| switch (err) {
            // A `HEAD` that is no ref, or a directory whose name no ref can
            // carry: a worktree with nothing checked out.
            error.MalformedRef, error.InvalidRefName => null,
            else => |e| return e,
        };
        if (value) |v| switch (v) {
            .symbolic => |target| {
                branch = if (std.mem.startsWith(u8, target, "refs/heads/")) target["refs/heads/".len..] else target;
                head = refs.readOid(arena, io, target) catch |err| switch (err) {
                    error.MalformedRef, error.SymbolicRefLoop, error.InvalidRefName => null,
                    else => |e| return e,
                };
            },
            .direct => |oid| head = oid,
        };

        try entries.append(arena, .{
            .name = try arena.dupe(u8, dir_entry.name),
            .path = named.work,
            .branch = branch,
            .head = head,
            .locked = lock_text != null,
            .lock_reason = if (lock_text) |text| std.mem.trim(u8, text, " \t\r\n") else null,
            .prunable = prunable,
        });
    }

    std.mem.sort(Entry, entries.items, {}, lessThanName);
    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = entries.items };
}

fn lessThanName(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Where an administrative directory's `gitdir` file says the worktree is.
const Named = struct {
    /// The working tree's `.git` file, absolute.
    gitfile: []const u8,
    /// The working tree, absolute: the `.git` file's directory.
    work: []const u8,
};

/// Read `admin`'s `gitdir` file, a relative path in it taken from `admin`
/// as git's `worktree.useRelativePaths` writes it. `null` when there is no
/// such file. Both paths are `arena`'s.
/// The `gitdir` file of a working tree's administrative directory, or
/// null where there is none: where the working tree's `.git` file is, as
/// `worktree add` wrote it.
fn readGitdir(arena: Allocator, io: Io, admin: Io.Dir, max_bytes: u64) aegis.own.ReadFileError!?[]u8 {
    // aegis: internal: the gitdir file this program, or git, wrote into the repository's own directory
    return aegis.own.readFile(io, admin, "gitdir", arena, aegis.units.Bytes(u64).fromRaw(max_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        else => |e| return e,
    };
}

fn namedTree(arena: Allocator, io: Io, admin: Io.Dir) Self.Error!?Named {
    const text = (try readGitdir(arena, io, admin, 4096)) orelse return null;
    const written = std.mem.trim(u8, text, " \t\r\n");
    if (written.len == 0) return null;
    const dot_git = if (std.Io.Dir.path.isAbsolute(written)) written else blk: {
        var buf: [4096]u8 = undefined;
        break :blk try std.Io.Dir.path.resolveAllocPosix(arena, &.{ try fs.realPath(io, admin, &buf), written });
    };
    // The `gitdir` file names the destination's `.git` *file*; the
    // working tree is its parent.
    const work = if (std.mem.endsWith(u8, dot_git, "/.git")) dot_git[0 .. dot_git.len - "/.git".len] else dot_git;
    return .{ .gitfile = dot_git, .work = work };
}

/// git's `validate_worktree`: whether the working tree's `.git` file points
/// back at `admin`. A working tree that is gone is valid, there being
/// nothing of it to touch.
fn pointsBack(arena: Allocator, io: Io, admin: Io.Dir, named: Named) Self.Error!bool {
    var work = Io.Dir.openDirAbsolute(io, named.work, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return false,
    };
    defer work.close(io);
    const target = (try gitfile.read(arena, io, work, ".git")) orelse return false;
    var target_dir = gitfile.open(io, work, target, .{}) catch return false;
    defer target_dir.deinit(io);
    var target_buf: [4096]u8 = undefined;
    var admin_buf: [4096]u8 = undefined;
    return std.mem.eql(u8, try fs.realPath(io, target_dir.lend().get(), &target_buf), try fs.realPath(io, admin, &admin_buf));
}

/// What `add` is asked to create.
pub const AddOptions = struct {
    /// The object `HEAD` will point at when detached.
    detach_at: ?Oid = null,
    /// The branch `HEAD` will point at, without `refs/heads/`. Exactly one
    /// of this and `detach_at` is used; `detach_at` wins.
    branch: ?[]const u8 = null,
    /// git for Windows' `core.hideDotFiles`, for the worktree's `.git` file.
    hide_dot_files: fs.HideDotFiles = .dot_git_only,
};

/// Where a new worktree lives.
pub const Added = struct {
    /// The name under `worktrees/`. Owned by the caller.
    name: []const u8,
    /// The administrative directory, opened, the caller's.
    admin_dir: fs.OwnedDir,
    /// The destination directory, opened, the caller's.
    work_dir: fs.OwnedDir,
};

/// Register a worktree in `dest_dir`, which the caller has made and which
/// must be empty, as git's `worktree add` refuses one that is not, and
/// write every file git writes, leaving the working tree itself empty.
///
/// The worktree's refs are laid down in the format of `refs`, the
/// repository's ref store, and its `HEAD` written through a store of its
/// own: in the files format a file, in a reftable a stack of the
/// worktree's, behind the placeholder git leaves. No `ORIG_HEAD` is
/// written: git's comes from the checkout's reset, which
/// `git worktree add --no-checkout` leaves out.
///
/// The checkout is a separate call, because it needs an object database and
/// an index and this does not: `worktree.checkout` into `Added.work_dir`.
pub const AddInputs = struct { name: []const u8, dest_dir: Io.Dir };

pub fn add(
    gpa: Allocator,
    io: Io,
    refs: *const refs_mod.Store,
    inputs: AddInputs,
    options: AddOptions,
) Self.Error!Added {
    const name = inputs.name;
    const dest_dir = inputs.dest_dir;
    const common_dir = refs.commonDir().get();
    try checkId(name);
    if (options.detach_at == null) {
        if (options.branch) |branch| {
            var ref_buf: [512]u8 = undefined;
            const ref = std.mem.print(&ref_buf, "refs/heads/{s}", .{branch}) catch return error.InvalidBranchName;
            if (!ref_names.checkFormat(ref, .{})) return error.InvalidBranchName;
        }
    }

    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    var opened_work_dir = fs.OwnedDir.init(try dest_dir.openDir(io, ".", .{ .iterate = true }));
    errdefer opened_work_dir.deinit(io);
    {
        var it = opened_work_dir.lend().get().iterate();
        if (try it.next(io) != null) return error.DestinationNotEmpty;
    }

    common_dir.createDirPath(io, "worktrees") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    var worktrees_dir = try common_dir.openDir(io, "worktrees", .{ .iterate = true });
    defer worktrees_dir.close(io);

    worktrees_dir.createDir(io, name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.WorktreeExists,
        else => |e| return e,
    };
    var admin = fs.OwnedDir.init(try worktrees_dir.openDir(io, name, .{ .iterate = true }));
    errdefer admin.deinit(io);
    const admin_dir = admin.lend().get();

    // `commondir` is relative to the administrative directory, which is what
    // makes a repository movable as a whole.
    try writeLine(io, admin_dir, "commondir", "../..");

    var abs_buf: [4096]u8 = undefined;
    const dest_abs = try fs.realPath(io, dest_dir, &abs_buf);
    var gitdir_buf: [4200]u8 = undefined;
    const gitfile_path = std.mem.print(&gitdir_buf, "{s}/.git", .{dest_abs}) catch
        return error.InvalidWorktreeName;
    try writeLine(io, admin_dir, "gitdir", gitfile_path);

    try refs_mod.create(io, admin_dir, refs.refFormat(), .{ .worktree = true, .shared = refs.sharedPermissions() });
    var own = try refs_mod.Store.init(gpa, refs.objectFormat(), admin.lend(), refs.commonDir(), .{
        .format = refs.refFormat(),
        .reftable = refs.reftableOptions(),
        .shared = refs.sharedPermissions(),
    });
    defer own.deinit();
    {
        var tx = own.begin(gpa);
        defer tx.deinit(io);
        if (options.detach_at) |oid| {
            try tx.change("HEAD", .{ .direct = oid }, .any, .{ .no_deref = true });
        } else if (options.branch) |branch| {
            const target = try std.mem.concat(gpa, u8, &.{ "refs/heads/", branch });
            defer gpa.free(target);
            try tx.update("HEAD", .{ .symbolic = target }, .any);
        } else {
            return error.CorruptWorktree;
        }
        try tx.commit(io, null);
    }

    // An empty `logs/HEAD`, as git starts one, so the first ref update in
    // the new worktree has somewhere to go. A reftable stack keeps its logs
    // in its tables.
    if (refs.refFormat() == .files) try own.createLog(gpa, io, "HEAD");

    // And the `.git` file in the destination, which is what makes the
    // directory a worktree at all.
    var admin_abs_buf: [4096]u8 = undefined;
    const admin_abs = try fs.realPath(io, admin_dir, &admin_abs_buf);
    try gitfile.write(io, dest_dir, admin_abs, options.hide_dot_files);

    return .{ .name = owned_name, .admin_dir = admin.move(), .work_dir = opened_work_dir.move() };
}

fn writeLine(io: Io, dir: Io.Dir, name: []const u8, text: []const u8) Error!void {
    // Each of these files is one line, which git and `list` read back
    // trimmed of its newline; a path holding one cannot be written there.
    if (std.mem.findScalar(u8, text, '\n') != null) return error.InvalidWorktreeName;
    var buf: [4300]u8 = undefined;
    const line = std.mem.print(&buf, "{s}\n", .{text}) catch return error.InvalidWorktreeName;
    try dir.writeFile(io, .{ .sub_path = name, .data = line });
}

/// How `remove` behaves.
pub const RemoveOptions = struct {
    /// Whether to remove a worktree with a `locked` file. Without this a
    /// locked worktree is `error.WorktreeLocked`.
    force: bool = false,
    /// Whether to delete the working tree's files as well as the
    /// administrative directory.
    delete_files: bool = true,
};

/// Remove a worktree: its administrative directory, and its files.
///
/// The working tree is removed only when its `.git` points back at the
/// administrative directory, as git's `validate_worktree` checks, so a
/// `gitdir` file naming some other directory is `error.CorruptWorktree`
/// and nothing goes. Unlike `git worktree remove`, this does not look for
/// local changes or untracked files first: that takes the worktree's index
/// and a status, which are the caller's to run before asking.
pub fn remove(
    gpa: Allocator,
    io: Io,
    common_dir: Io.Dir,
    name: []const u8,
    options: RemoveOptions,
) Self.Error!void {
    try checkId(name);
    var worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    defer worktrees_dir.close(io);

    var admin = worktrees_dir.openDir(io, name, .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    var admin_open = true;
    defer if (admin_open) admin.close(io);

    if (!options.force) {
        if (admin.access(io, "locked", .{})) |_| {
            return error.WorktreeLocked;
        } else |_| {}
    }

    // As git's delete_git_work_tree: a working tree that will not go is
    // reported, after the administrative directory has gone all the same.
    var files_error: ?Io.Dir.DeleteTreeError = null;
    if (options.delete_files) {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        if (try namedTree(arena, io, admin)) |named| {
            if (!try pointsBack(arena, io, admin, named)) return error.CorruptWorktree;
            const cwd: Io.Dir = .cwd();
            cwd.deleteTree(io, named.work) catch |err| {
                files_error = err;
            };
        }
    }

    admin.close(io);
    admin_open = false;
    try worktrees_dir.deleteTree(io, name);
    if (files_error) |err| return err;
}

/// What `prune` is asked: git's `worktree prune` options.
pub const PruneOptions = struct {
    /// `--expire`: a worktree whose working tree is gone goes only when its
    /// `index` is no newer than this, or missing; `null` takes every one,
    /// git's default.
    expire: ?date.Expiry = null,
    /// `-n`: what would go is reported, and nothing goes.
    dry_run: bool = false,
    /// `core.ignoreCase`: two worktrees at paths that differ only in case
    /// are one, as git's `fspathcmp` compares them.
    ignore_case: bool = false,
};

/// Why `prune` takes an administrative directory away, as git's
/// `should_prune_worktree` and `prune_dups` say it.
pub const PruneReason = enum {
    /// "not a valid directory": an entry of `worktrees/` that is no
    /// directory.
    not_a_directory,
    /// "gitdir file does not exist".
    no_gitdir,
    /// "unable to read gitdir file".
    unreadable_gitdir,
    /// "invalid gitdir file": empty, line endings aside.
    invalid_gitdir,
    /// "gitdir file points to non-existent location", and its `index` is
    /// no newer than the expiry.
    gone,
    /// "duplicate entry": a second worktree at a path the main one or
    /// another holds.
    duplicate,
};

/// One administrative directory `prune` took away, or with `dry_run`
/// would have.
pub const Pruned = struct { id: []const u8, reason: PruneReason };

/// What `prune` did. Release it with `deinit`.
pub const PruneOutcome = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// In git's order: the directory's, then the duplicates by path.
    pruned: []const Pruned,
    /// Worktrees left because they carry a `locked` file.
    skipped_locked: u32,

    pub fn deinit(outcome: *PruneOutcome) void {
        var arena = outcome.arena.promote(outcome.gpa);
        arena.deinit();
        outcome.* = undefined;
    }
};

/// git's `worktree prune` (`prune_worktrees`): each administrative
/// directory that holds no worktree goes, unless a `locked` file keeps it;
/// then each worktree at a path the main working tree or an earlier one
/// holds; then `worktrees/` itself when it is empty.
pub fn prune(gpa: Allocator, io: Io, refs: *const refs_mod.Store, options: PruneOptions) Self.Error!PruneOutcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const common_dir = refs.commonDir().get();
    var pruned: std.ArrayList(Pruned) = .empty;
    var skipped_locked: u32 = 0;
    const worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .gpa = gpa, .arena = arena_instance.state, .pruned = &.{}, .skipped_locked = 0 },
        else => |e| return e,
    };
    defer worktrees_dir.close(io);

    // The worktrees that stay, by the `.git` their `gitdir` file names;
    // the main one first, its id `null`.
    var kept: std.ArrayList(Kept) = .empty;
    var common_buf: [4096]u8 = undefined;
    try kept.append(arena, .{ .path = try arena.dupe(u8, try fs.realPath(io, common_dir, &common_buf)), .id = null });
    var it: fs.Names = .init(worktrees_dir, refs.precomposeUnicode());
    while (try it.next(io)) |entry| {
        const id = try arena.dupe(u8, entry.name);
        const verdict = try judge(arena, io, worktrees_dir, entry.name, options.expire);
        switch (verdict) {
            .locked => skipped_locked += 1,
            .keep => |path| try kept.append(arena, .{ .path = path, .id = id }),
            .prune => |reason| try pruned.append(arena, .{ .id = id, .reason = reason }),
        }
    }
    // `prune_dups`: by path, the main working tree ahead of any linked
    // one, then by id; each after the first at a path goes.
    std.mem.sort(Kept, kept.items, options.ignore_case, Kept.less);
    for (kept.items[1..], 1..) |k, i| {
        if (pathOrder(k.path, kept.items[i - 1].path, options.ignore_case) == .eq) try pruned.append(arena, .{ .id = k.id.?, .reason = .duplicate });
    }
    if (!options.dry_run) {
        for (pruned.items) |p| {
            worktrees_dir.deleteTree(io, p.id) catch |err| switch (err) {
                error.NotDir => try worktrees_dir.deleteFile(io, p.id),
                else => |e| return e,
            };
        }
        // glint-ignore: Z026 -- git's `delete_worktrees_dir_if_empty`: a directory that still holds something, or any other failure, is let be
        common_dir.deleteDir(io, "worktrees") catch {};
    }
    return .{ .gpa = gpa, .arena = arena_instance.state, .pruned = pruned.items, .skipped_locked = skipped_locked };
}

/// A worktree `prune` keeps, by its `.git`; `id` `null` for the main one.
const Kept = struct {
    path: []const u8,
    id: ?[]const u8,

    fn less(ignore_case: bool, a: Kept, b: Kept) bool {
        const by_path = pathOrder(a.path, b.path, ignore_case);
        if (by_path != .eq) return by_path == .lt;
        if (a.id == null) return b.id != null;
        if (b.id == null) return false;
        return std.mem.order(u8, a.id.?, b.id.?) == .lt;
    }
};

/// git's `fspathcmp`.
fn pathOrder(a: []const u8, b: []const u8, ignore_case: bool) std.math.Order {
    if (!ignore_case) return std.mem.order(u8, a, b);
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        const order = std.math.order(std.ascii.toLower(x), std.ascii.toLower(y));
        if (order != .eq) return order;
    }
    return std.math.order(a.len, b.len);
}

const Verdict = union(enum) { locked, keep: []const u8, prune: PruneReason };

/// git's `should_prune_worktree` for the entry `entry` of `worktrees/`.
fn judge(arena: Allocator, io: Io, worktrees_dir: Io.Dir, name: []const u8, expire: ?date.Expiry) Self.Error!Verdict {
    var admin = worktrees_dir.openDir(io, name, .{}) catch |err| switch (err) {
        error.NotDir, error.FileNotFound => return .{ .prune = .not_a_directory },
        else => |e| return e,
    };
    defer admin.close(io);
    const locked = if (admin.access(io, "locked", .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| return e,
    };
    if (locked) return .locked;
    const read = readGitdir(arena, io, admin, 1 << 20) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return .{ .prune = .unreadable_gitdir },
    };
    const text = read orelse return .{ .prune = .no_gitdir };
    const written = std.mem.trimEnd(u8, text, "\r\n");
    if (written.len == 0) return .{ .prune = .invalid_gitdir };
    const dot_git = if (std.Io.Dir.path.isAbsolute(written)) written else blk: {
        var buf: [4096]u8 = undefined;
        break :blk try std.Io.Dir.path.resolveAllocPosix(arena, &.{ try fs.realPath(io, admin, &buf), written });
    };
    if (std.Io.Dir.accessAbsolute(io, dot_git, .{})) |_| {} else |_| {
        const stat = admin.statFile(io, "index", .{}) catch return .{ .prune = .gone };
        if (expire == null or date.instant(stat.mtime).compare(expire.?) != .gt) return .{ .prune = .gone };
    }
    return .{ .keep = dot_git };
}

/// A worktree's id names a directory under `worktrees/`, so every entry
/// point holds it to the rules of a name written to the disk: one
/// component, never `.` or `..`, nothing a platform would take for another
/// name.
fn checkId(name: []const u8) ErrorNamespace.Error!void {
    if (safe_path.checkComponent(name, .worktree, .{}) != null) return error.InvalidWorktreeName;
}

/// Put a `locked` file beside a worktree, with an optional reason.
pub fn lock(io: Io, common_dir: Io.Dir, name: []const u8, reason: []const u8) Self.Error!void {
    try checkId(name);
    var worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    defer worktrees_dir.close(io);
    var admin = worktrees_dir.openDir(io, name, .{}) catch return error.WorktreeNotFound;
    defer admin.close(io);
    try admin.writeFile(io, .{ .sub_path = "locked", .data = reason });
}

/// Remove the `locked` file.
pub fn unlock(io: Io, common_dir: Io.Dir, name: []const u8) Self.Error!void {
    try checkId(name);
    var worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    defer worktrees_dir.close(io);
    var admin = worktrees_dir.openDir(io, name, .{}) catch return error.WorktreeNotFound;
    defer admin.close(io);
    admin.deleteFile(io, "locked") catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

/// Point a worktree's administrative directory at a new location, after the
/// working tree has been moved.
///
/// Only the two files that carry a path are rewritten: `gitdir` in the
/// administrative directory, and the `.git` file in the destination.
pub fn repair(
    io: Io,
    common_dir: Io.Dir,
    name: []const u8,
    dest_dir: Io.Dir,
    hide: fs.HideDotFiles,
) Self.Error!void {
    try checkId(name);
    var worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    defer worktrees_dir.close(io);
    var admin = worktrees_dir.openDir(io, name, .{}) catch return error.WorktreeNotFound;
    defer admin.close(io);

    var abs_buf: [4096]u8 = undefined;
    const dest_abs = try fs.realPath(io, dest_dir, &abs_buf);
    var gitdir_buf: [4200]u8 = undefined;
    const gitfile_path = std.mem.print(&gitdir_buf, "{s}/.git", .{dest_abs}) catch
        return error.InvalidWorktreeName;
    try writeLine(io, admin, "gitdir", gitfile_path);

    var admin_abs_buf: [4096]u8 = undefined;
    const admin_abs = try fs.realPath(io, admin, &admin_abs_buf);
    try gitfile.write(io, dest_dir, admin_abs, hide);
}

/// Move a worktree's files to `new_dest` and repair the two paths.
///
/// The move itself is a rename, so it fails across filesystems rather than
/// copying: a worktree that has to cross a device is one the caller should
/// remove and add again.
pub const MoveInputs = struct {
    name: []const u8,
    new_parent: Io.Dir,
    new_name: []const u8,
    /// git for Windows' `core.hideDotFiles`, for the worktree's `.git` file.
    hide_dot_files: fs.HideDotFiles = .dot_git_only,
};

pub fn move(
    gpa: Allocator,
    io: Io,
    common_dir: Io.Dir,
    inputs: MoveInputs,
) Self.Error!void {
    const name = inputs.name;
    const new_parent = inputs.new_parent;
    const new_name = inputs.new_name;
    try checkId(name);
    try checkId(new_name);
    var worktrees_dir = common_dir.openDir(io, "worktrees", .{}) catch return error.WorktreeNotFound;
    defer worktrees_dir.close(io);
    var admin = worktrees_dir.openDir(io, name, .{}) catch return error.WorktreeNotFound;
    defer admin.close(io);
    if (admin.access(io, "locked", .{})) |_| return error.WorktreeLocked else |_| {}
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const named = try namedTree(arena, io, admin) orelse return error.CorruptWorktree;
    if (!try pointsBack(arena, io, admin, named)) return error.CorruptWorktree;

    const cwd: Io.Dir = .cwd();
    try cwd.rename(named.work, new_parent, new_name, io);

    var moved = try new_parent.openDir(io, new_name, .{ .iterate = true });
    defer moved.close(io);
    try repair(io, common_dir, name, moved, inputs.hide_dot_files);
}

test "every entry point refuses a worktree id that is not one name under worktrees/" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "..", ".", "a/b", "../escape", "" }) |id| {
        try std.testing.expectError(error.InvalidWorktreeName, lock(io, tmp.dir, id, ""));
        try std.testing.expectError(error.InvalidWorktreeName, unlock(io, tmp.dir, id));
    }
}
