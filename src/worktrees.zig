//! Linked worktrees: the administrative directory git keeps and the `.git`
//! file it puts in the destination.
//!
//! What is on the disk, measured against git rather than read from a
//! document: `<common>/worktrees/<id>/` holding `HEAD`, `gitdir`,
//! `commondir`, `index`, `ORIG_HEAD` and `logs/HEAD`, and a `.git` *file* in
//! the destination whose only line is `gitdir: <absolute path>`. In a
//! repository whose refs are a reftable stack, `HEAD` and `ORIG_HEAD` are in
//! a stack of the worktree's own under `reftable/`, and the `HEAD` file is
//! the placeholder git leaves there.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const fs = @import("fs.zig");
const safepath = @import("safepath.zig");
const refs_mod = @import("refs.zig");
const reftablestack = @import("reftablestack.zig");
const config_mod = @import("config.zig");

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
    /// A name that cannot be a directory under `worktrees/`.
    InvalidWorktreeName,
    /// The administrative directory is there but does not hold what a
    /// worktree needs.
    CorruptWorktree,
} || Allocator.Error || Io.Dir.OpenError || Io.Dir.ReadFileAllocError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError ||
    Io.Dir.DeleteTreeError || Io.Dir.RenameError || Io.Dir.WriteFileError ||
    Io.File.OpenError || Io.Writer.Error || Io.File.SyncError ||
    Io.Dir.Iterator.Error || Io.Dir.RealPathError || refs_mod.ReadError ||
    refs_mod.TransactionError || config_mod.ParseError;

/// One registered worktree.
pub const Entry = struct {
    /// The directory name under `worktrees/`. Owned by the listing.
    name: []const u8,
    /// The absolute path of the working tree, from the admin directory's
    /// `gitdir` file with the trailing `/.git` removed. Owned by the
    /// listing.
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

/// Every worktree registered under `<common_dir>/worktrees`.
///
/// The main working tree is not one of these: it has no administrative
/// directory, and a caller that wants it in a list adds it.
pub fn list(gpa: Allocator, io: Io, common_dir: Io.Dir, kind: hash.Kind) Error!Listing {
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

    var it = worktrees_dir.iterate();
    while (try it.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        const admin = worktrees_dir.openDir(io, dir_entry.name, .{ .iterate = true }) catch continue;
        defer admin.close(io);

        const gitdir_text = (try fs.readFileAlloc(arena, io, admin, "gitdir", 4096)) orelse continue;
        const gitfile_path = std.mem.trim(u8, gitdir_text, " \t\r\n");
        // The `gitdir` file names the destination's `.git` *file*; the
        // working tree is its parent.
        const work_path = if (std.mem.endsWith(u8, gitfile_path, "/.git"))
            gitfile_path[0 .. gitfile_path.len - "/.git".len]
        else
            gitfile_path;

        // A worktree whose `.git` file is gone is one git prunes: the
        // directory it pointed at has been deleted by hand.
        var prunable = true;
        if (std.Io.Dir.accessAbsolute(io, gitfile_path, .{})) |_| {
            prunable = false;
        } else |_| {}

        const lock_text = try fs.readFileAlloc(arena, io, admin, "locked", 4096);
        var head_text = try fs.readFileAlloc(arena, io, admin, "HEAD", 4096);
        // A reftable worktree's `HEAD` is in its own stack; the file is a
        // placeholder.
        if (try reftablestack.headIn(gpa, arena, io, admin, kind)) |value| {
            head_text = switch (value) {
                .symbolic => |target| try std.fmt.allocPrint(arena, "ref: {s}", .{target}),
                .direct => |oid| blk: {
                    var hex: [hash.max_hex_len]u8 = undefined;
                    break :blk try arena.dupe(u8, oid.hex(&hex));
                },
            };
        }
        var branch: ?[]const u8 = null;
        var head: ?Oid = null;
        if (head_text) |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "ref:")) {
                const target = std.mem.trim(u8, trimmed[4..], " \t");
                branch = if (std.mem.startsWith(u8, target, "refs/heads/"))
                    target["refs/heads/".len..]
                else
                    target;
            } else {
                head = Oid.parse(kind, trimmed) catch null;
            }
        }

        try entries.append(arena, .{
            .name = try arena.dupe(u8, dir_entry.name),
            .path = try arena.dupe(u8, work_path),
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

/// What `add` is asked to create.
pub const AddOptions = struct {
    /// The object `HEAD` will point at when detached.
    detach_at: ?Oid = null,
    /// The branch `HEAD` will point at, without `refs/heads/`. Exactly one
    /// of this and `detach_at` is used; `detach_at` wins.
    branch: ?[]const u8 = null,
    /// Whether to create the destination directory if it is not there.
    create_destination: bool = true,
};

/// Where a new worktree lives.
pub const Added = struct {
    /// The name under `worktrees/`. Owned by the caller.
    name: []const u8,
    /// The administrative directory, opened. The caller closes it.
    admin_dir: Io.Dir,
    /// The destination directory, opened. The caller closes it.
    work_dir: Io.Dir,
};

/// Register a worktree and write every file git writes, leaving the working
/// tree itself empty.
///
/// The checkout is a separate call, because it needs an object database and
/// an index and this does not. `Repository.addWorktree` does both.
pub fn add(
    gpa: Allocator,
    io: Io,
    common_dir: Io.Dir,
    name: []const u8,
    dest_dir: Io.Dir,
    dest_path: []const u8,
    options: AddOptions,
) Error!Added {
    if (safepath.checkComponent(name, .stored) != null) return error.InvalidWorktreeName;
    _ = options.create_destination;

    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const opened_work_dir = try dest_dir.openDir(io, ".", .{ .iterate = true });
    errdefer opened_work_dir.close(io);

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
    var admin = try worktrees_dir.openDir(io, name, .{ .iterate = true });
    errdefer admin.close(io);

    // `commondir` is relative to the administrative directory, which is what
    // makes a repository movable as a whole.
    try writeLine(io, admin, "commondir", "../..");

    var abs_buf: [4096]u8 = undefined;
    const dest_abs = try absolutePath(io, dest_dir, &abs_buf);
    var gitdir_buf: [4200]u8 = undefined;
    const gitfile_path = std.fmt.bufPrint(&gitdir_buf, "{s}/.git", .{dest_abs}) catch
        return error.InvalidWorktreeName;
    try writeLine(io, admin, "gitdir", gitfile_path);

    if (reftablestack.isReftableRepository(io, common_dir)) {
        // `HEAD` goes into a stack of the worktree's own, which is what git
        // reads there, and the file beside it is the placeholder.
        var config = try config_mod.Config.openFile(gpa, io, .{ .dir = common_dir, .sub_path = "config" }, .local, .{});
        defer config.deinit();
        const kind: hash.Kind = if (config.get("extensions.objectformat")) |text|
            hash.Kind.parse(text) catch return error.CorruptWorktree
        else
            .sha1;
        var target_buf: [512]u8 = undefined;
        if (options.detach_at) |oid| {
            try reftablestack.initialize(gpa, io, admin, kind, .{ .direct = oid }, oid, .{});
        } else if (options.branch) |branch| {
            const target = std.fmt.bufPrint(&target_buf, "refs/heads/{s}", .{branch}) catch
                return error.InvalidWorktreeName;
            try reftablestack.initialize(gpa, io, admin, kind, .{ .symbolic = target }, null, .{});
        } else {
            return error.CorruptWorktree;
        }
    } else if (options.detach_at) |oid| {
        var hex: [hash.max_hex_len]u8 = undefined;
        try writeLine(io, admin, "HEAD", oid.hex(&hex));
        try writeLine(io, admin, "ORIG_HEAD", oid.hex(&hex));
    } else if (options.branch) |branch| {
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "ref: refs/heads/{s}", .{branch}) catch
            return error.InvalidWorktreeName;
        try writeLine(io, admin, "HEAD", line);
    } else {
        return error.CorruptWorktree;
    }

    // git creates the log directory and an empty `logs/HEAD` so the first
    // ref update in the new worktree has somewhere to go. A reftable stack
    // keeps its logs in its tables.
    if (!reftablestack.isReftableRepository(io, common_dir)) {
        admin.createDirPath(io, "logs") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
        const log_file = try admin.createFile(io, "logs/HEAD", .{ .truncate = false });
        log_file.close(io);
    }

    // And the `.git` file in the destination, which is what makes the
    // directory a worktree at all.
    var admin_abs_buf: [4096]u8 = undefined;
    const admin_abs = try absolutePath(io, admin, &admin_abs_buf);
    var pointer_buf: [4200]u8 = undefined;
    const pointer = std.fmt.bufPrint(&pointer_buf, "gitdir: {s}\n", .{admin_abs}) catch
        return error.InvalidWorktreeName;
    try dest_dir.writeFile(io, .{ .sub_path = ".git", .data = pointer });

    _ = dest_path;
    return .{ .name = owned_name, .admin_dir = admin, .work_dir = opened_work_dir };
}

fn writeLine(io: Io, dir: Io.Dir, name: []const u8, text: []const u8) Error!void {
    var buf: [4300]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{text}) catch return error.InvalidWorktreeName;
    try dir.writeFile(io, .{ .sub_path = name, .data = line });
}

/// The absolute path of `dir`, written the way git writes a path: with `/`
/// between the components whatever the platform underneath.
///
/// Windows hands back `D:\a\tree`, and a `gitdir` file holding that is one
/// git prints back with the backslashes still in it and one another
/// implementation has to guess about. git itself stores `D:/a/tree`. The
/// separator is only rewritten there, because on a POSIX filesystem a
/// backslash is an ordinary character in a name.
fn absolutePath(io: Io, dir: Io.Dir, buf: []u8) Error![]const u8 {
    const len = try dir.realPath(io, buf);
    const out = buf[0..len];
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
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
pub fn remove(
    gpa: Allocator,
    io: Io,
    common_dir: Io.Dir,
    name: []const u8,
    options: RemoveOptions,
) Error!void {
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

    if (options.delete_files) {
        const gitdir_text = try fs.readFileAlloc(gpa, io, admin, "gitdir", 4096);
        if (gitdir_text) |text| {
            defer gpa.free(text);
            const gitfile_path = std.mem.trim(u8, text, " \t\r\n");
            const work_path = if (std.mem.endsWith(u8, gitfile_path, "/.git"))
                gitfile_path[0 .. gitfile_path.len - "/.git".len]
            else
                gitfile_path;
            const cwd: Io.Dir = .cwd();
            cwd.deleteTree(io, work_path) catch {};
        }
    }

    admin.close(io);
    admin_open = false;
    try worktrees_dir.deleteTree(io, name);
}

/// What `prune` removed.
pub const PruneOutcome = struct {
    removed: u32 = 0,
    /// Worktrees skipped because they carry a `locked` file.
    skipped_locked: u32 = 0,
};

/// Remove the administrative directories whose working tree is gone.
///
/// A worktree with a `locked` file beside it is skipped whatever its state,
/// which is what git does and is the whole point of that file.
pub fn prune(gpa: Allocator, io: Io, common_dir: Io.Dir, kind: hash.Kind) Error!PruneOutcome {
    var outcome: PruneOutcome = .{};
    var listing = try list(gpa, io, common_dir, kind);
    defer listing.deinit();

    for (listing.entries) |entry| {
        if (entry.locked) {
            outcome.skipped_locked += 1;
            continue;
        }
        if (!entry.prunable) continue;
        remove(gpa, io, common_dir, entry.name, .{ .force = false, .delete_files = false }) catch continue;
        outcome.removed += 1;
    }
    return outcome;
}

/// Put a `locked` file beside a worktree, with an optional reason.
pub fn lock(io: Io, common_dir: Io.Dir, name: []const u8, reason: []const u8) Error!void {
    var worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    defer worktrees_dir.close(io);
    var admin = worktrees_dir.openDir(io, name, .{}) catch return error.WorktreeNotFound;
    defer admin.close(io);
    try admin.writeFile(io, .{ .sub_path = "locked", .data = reason });
}

/// Remove the `locked` file.
pub fn unlock(io: Io, common_dir: Io.Dir, name: []const u8) Error!void {
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
) Error!void {
    var worktrees_dir = common_dir.openDir(io, "worktrees", .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    defer worktrees_dir.close(io);
    var admin = worktrees_dir.openDir(io, name, .{}) catch return error.WorktreeNotFound;
    defer admin.close(io);

    var abs_buf: [4096]u8 = undefined;
    const dest_abs = try absolutePath(io, dest_dir, &abs_buf);
    var gitdir_buf: [4200]u8 = undefined;
    const gitfile_path = std.fmt.bufPrint(&gitdir_buf, "{s}/.git", .{dest_abs}) catch
        return error.InvalidWorktreeName;
    try writeLine(io, admin, "gitdir", gitfile_path);

    var admin_abs_buf: [4096]u8 = undefined;
    const admin_abs = try absolutePath(io, admin, &admin_abs_buf);
    var pointer_buf: [4200]u8 = undefined;
    const pointer = std.fmt.bufPrint(&pointer_buf, "gitdir: {s}\n", .{admin_abs}) catch
        return error.InvalidWorktreeName;
    try dest_dir.writeFile(io, .{ .sub_path = ".git", .data = pointer });
}

/// Move a worktree's files to `new_dest` and repair the two paths.
///
/// The move itself is a rename, so it fails across filesystems rather than
/// copying: a worktree that has to cross a device is one the caller should
/// remove and add again.
pub fn move(
    gpa: Allocator,
    io: Io,
    common_dir: Io.Dir,
    name: []const u8,
    new_parent: Io.Dir,
    new_name: []const u8,
) Error!void {
    var listing = try list(gpa, io, common_dir, .sha1);
    defer listing.deinit();
    const entry = listing.find(name) orelse return error.WorktreeNotFound;
    if (entry.locked) return error.WorktreeLocked;

    const cwd: Io.Dir = .cwd();
    try cwd.rename(entry.path, new_parent, new_name, io);

    var moved = try new_parent.openDir(io, new_name, .{ .iterate = true });
    defer moved.close(io);
    try repair(io, common_dir, name, moved);
}

/// Read a `.git` file's `gitdir:` line. The result is the caller's.
///
/// This is how a linked worktree's directory is found from the worktree
/// itself, and the reason a `.git` that is a file is not an error.
pub fn readGitFile(gpa: Allocator, io: Io, dir: Io.Dir) Error!?[]u8 {
    const text = (try fs.readFileAlloc(gpa, io, dir, ".git", 4096)) orelse return null;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
    const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
    if (target.len == 0) return null;
    return try gpa.dupe(u8, target);
}
