//! git's `refs migrate` (`refs.c`, `repo_migrate_ref_storage_format`):
//! every ref and log copied into a new store of the other format in
//! `ref_migration.XXXXXX` beside them, then, unless it is a dry run, the
//! old store removed, the new one moved into its place and the
//! repository's format changed.
//!
//! The repository must be opened again afterwards: its ref store is the
//! old format's, which no longer has anything on the disk.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const refs_mod = @import("../refs/refs.zig");
const ref_names = @import("../names.zig").ref;
const config_write = @import("../config/write.zig");
const repo_mod = @import("../repo/repo.zig");
const Repository = repo_mod.Repository;

/// What `migrate` is asked: `git refs migrate`'s options.
pub const Options = struct {
    /// `--ref-format`.
    format: refs_mod.Format,
    /// `--dry-run`: the new store is written and left in its directory,
    /// and the repository is not touched.
    dry_run: bool = false,
    /// `--no-reflog` is `false`: the logs are left behind.
    reflogs: bool = true,
};

/// What `migrate` did.
pub const Outcome = struct {
    /// With `dry_run`, the directory under the git directory the new store
    /// is in, `ref_migration.XXXXXX`, in the caller's allocator.
    dry_run_dir: ?[]u8 = null,
};

/// Failures of `migrate`.
pub const Error = refs_mod.TransactionError || refs_mod.Store.ReadLogError || refs_mod.CreateError || repo_mod.Error ||
    config_write.Error || Io.Dir.DeleteTreeError || Io.Dir.RenameError || Io.Dir.DeleteDirError || error{
    /// The repository's refs are in the format asked for already: git's
    /// "current and new ref storage format are equal".
    SameRefFormat,
    /// A linked worktree, whose refs git 2.55 does not migrate.
    WorktreesUnsupported,
};

/// git's `refs migrate`.
pub fn migrate(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    const old = repo.refStore();
    if (old.refFormat() == options.format) return error.SameRefFormat;
    {
        var linked = try repo.listWorktrees(io);
        defer linked.deinit();
        if (linked.entries.len != 0) return error.WorktreesUnsupported;
    }
    const git_dir = repo.gitDirectory();
    var name_buf: [32]u8 = undefined;
    const dir_name = try tempDirectory(io, git_dir, &name_buf);
    var dir = try git_dir.openDir(io, dir_name, .{ .iterate = true });
    defer dir.close(io);
    try refs_mod.create(io, dir, options.format, .{ .shared = old.sharedPermissions() });
    {
        var store = try refs_mod.Store.init(gpa, repo.objectFormat(), dir, dir, .{ .format = options.format, .reftable = old.reftableOptions(), .shared = old.sharedPermissions() });
        defer store.deinit();
        try copyRefs(gpa, io, repo, &store);
        if (options.reflogs) try copyLogs(gpa, io, old, &store);
        // git's one transaction makes one table.
        if (options.format == .reftable) try store.pack(gpa, io, .{ .include = &.{"*"}, .objects = repo.refObjects() });
    }
    if (options.dry_run) return .{ .dry_run_dir = try gpa.dupe(u8, dir_name) };

    try refs_mod.removeOnDisk(gpa, io, old);
    var it = dir.iterate();
    var moved: std.ArrayList([]u8) = .empty;
    defer {
        for (moved.items) |n| gpa.free(n);
        moved.deinit(gpa);
    }
    while (try it.next(io)) |entry| try moved.append(gpa, try gpa.dupe(u8, entry.name));
    for (moved.items) |entry| {
        var from_buf: [64]u8 = undefined;
        const from = std.mem.print(&from_buf, "{s}/{s}", .{ dir_name, entry }) catch return error.NameTooLong;
        try git_dir.rename(from, git_dir, entry, io);
    }
    try git_dir.deleteDir(io, dir_name);
    try writeFormat(gpa, io, repo, options.format);
    return .{};
}

/// git's `initialize_repository_version` on a reinitialization: version 1
/// for SHA-256, a reftable, an extension only version 1 knows or
/// `init.defaultSubmodulePathConfig`, else 0; `extensions.refStorage` set
/// for a reftable and unset for the files format.
fn writeFormat(gpa: Allocator, io: Io, repo: *Repository, format: refs_mod.Format) Self.Error!void {
    const config = repo.configuration();
    var edits: std.ArrayList(config_write.Edit) = .empty;
    defer edits.deinit(gpa);
    var version: []const u8 = if (repo.objectFormat() != .sha1 or format != .files) "1" else "0";
    // The extensions version 0 reads, as git's `handle_extension_v0`.
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "extensions") or entry.has_subsection) continue;
        const v0 = for ([_][]const u8{ "noop", "preciousobjects", "partialclone", "worktreeconfig", "refstorage" }) |name| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) break true;
        } else false;
        if (!v0) version = "1";
    }
    if (repo.objectFormat() == .sha1) try edits.append(gpa, .{ .unset = .{ .name = "extensions.objectformat" } });
    switch (format) {
        .reftable => try edits.append(gpa, .{ .set = .{ .name = "extensions.refstorage", .value = @tagName(refs_mod.Format.reftable) } }),
        .files => try edits.append(gpa, .{ .unset = .{ .name = "extensions.refstorage" } }),
    }
    if (try config.getBool("init.defaultsubmodulepathconfig", false)) {
        version = "1";
        try edits.append(gpa, .{ .set = .{ .name = "extensions.submodulepathconfig", .value = "true" } });
    }
    try edits.append(gpa, .{ .set = .{ .name = "core.repositoryformatversion", .value = version } });
    _ = try config_write.editFile(gpa, io, repo.commonDirectory(), "config", .local, repo.refStore().sharedPermissions(), edits.items);
}

/// `ref_migration.XXXXXX`, made in `git_dir` as `mkdtemp` makes it.
fn tempDirectory(io: Io, git_dir: Io.Dir, buf: *[32]u8) Self.Error![]const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    while (true) {
        var raw: [6]u8 = undefined;
        io.random(&raw);
        var suffix: [6]u8 = undefined;
        for (raw, &suffix) |r, *s| s.* = letters[r % letters.len];
        // unreachable: the name is twenty bytes
        const name = std.mem.print(buf, "ref_migration.{s}", .{&suffix}) catch unreachable;
        git_dir.createDir(io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        return name;
    }
}

/// `migrate_one_ref` for every ref, the root refs and the symbolic ones
/// included: the shared direct refs as git's initial transaction writes
/// them (no peeled values: git's updates carry none), the rest through one transaction,
/// no log made for any.
fn copyRefs(gpa: Allocator, io: Io, repo: *Repository, store: *refs_mod.Store) Self.Error!void {
    const old = repo.refStore();
    var listed = try old.list(gpa, io, "refs/");
    defer listed.deinit();
    var roots = try old.root().list(gpa, io);
    defer roots.deinit();
    var initial: std.ArrayList(refs_mod.Store.Initial) = .empty;
    defer initial.deinit(gpa);
    var tx = store.begin(gpa);
    defer tx.deinit(io);
    for ([_][]const refs_mod.Named{ listed.entries, roots.entries }, 0..) |entries, list_index| for (entries) |entry| switch (entry.target) {
        .direct => |oid| if (list_index == 0 and ref_names.parseWorktreeRef(entry.name).owner == .shared) {
            try initial.append(gpa, .{
                .name = entry.name,
                .oid = oid,
            });
        } else try tx.create(entry.name, .{ .direct = oid }),
        .symbolic => |target| try tx.create(entry.name, .{ .symbolic = target }),
    };
    try store.writeInitial(gpa, io, initial.items);
    try tx.commit(io, null);
}

/// `migrate_one_reflog` for every log: each entry as it was, who, when and
/// what, in order.
fn copyLogs(gpa: Allocator, io: Io, old: *refs_mod.Store, store: *refs_mod.Store) Self.Error!void {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const names = try old.logNames(gpa, arena_instance.allocator(), io, .{});
    for (names) |name| {
        var log = try old.readLog(gpa, io, name);
        defer log.deinit();
        try store.createLog(gpa, io, name);
        for (log.entries) |entry| {
            try store.appendLog(gpa, io, .{ .name = name, .old = entry.old, .new = entry.new }, .{ .who = entry.who, .message = entry.message, .policy = .always });
        }
    }
}
