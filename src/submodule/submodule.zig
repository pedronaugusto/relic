//! Submodules: repositories a superproject records by commit, at a path,
//! with `.gitmodules` saying what each is called and where it comes from.
//!
//! What is on the disk, measured against git rather than read from a
//! document: a submodule's repository lives in the superproject's git
//! directory at `modules/<name>`, and its working tree holds a `.git` file
//! whose only line is `gitdir: ` and the path to that directory relative to
//! the file. The repository's own configuration says `core.worktree`,
//! relative the other way. A submodule of a submodule nests the same way
//! inside its parent's repository: `modules/<outer>/modules/<inner>`. A
//! linked worktree of the superproject has a git directory of its own,
//! `worktrees/<id>`, so a submodule checked out there is a clone of its own
//! under `worktrees/<id>/modules/<name>`. A submodule cloned before any of
//! that existed has its `.git` directory in its working tree, and
//! `absorbGitDirs` moves it to where it belongs.
//!
//! Names and paths come from `.gitmodules`, which arrives in a tree, so both
//! are checked before either becomes a filesystem path: the name against
//! git's rule for names, the path against every rule `safe_path` holds, and
//! each component of the path for a symbolic link, which git refuses since
//! the fix for a symlink that pointed a submodule's checkout into `.git`.
//!
//! This is the half that needs no network. A submodule whose repository is
//! nowhere on the disk, and a commit its repository does not have, both
//! need a fetch; `UpdateOptions.transport` is where one plugs in, and
//! without one each is a named error rather than a guess. Nothing here
//! starts a process unless the caller hands in `program.Programs` and the
//! repository's own configuration names a `!command` update.

const ErrorNamespace = @This();
const Self = @This();

// The modules relic's API puts under this one, as `relic.submodule.<name>`.
const gitmodules = @import("../config/gitmodules.zig");
const gitlink = @import("../discover.zig").gitlink;
const discover = @import("../discover.zig");
const gitfile = @import("../discover.zig").gitfile;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const fs = @import("../fs/fs.zig");
const safe_path = @import("../names.zig").path;
const index_mod = @import("../index/index.zig");
const config_mod = @import("../config/config.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const worktree = @import("../checkout/checkout.zig");
const program = @import("../process.zig").program;
const pathspec_mod = @import("../patterns.zig").pathspec;
const remote_mod = @import("../wire.zig").remote;
const promisors = @import("../wire.zig").promisors;
const three_way = @import("../merge/three_way.zig");
const branch_mod = @import("../commit/branch.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Repository = repo_mod.Repository;
const Gitmodules = gitmodules.Gitmodules;

/// How deep submodules may nest inside submodules before a recursive
/// operation stops.
pub const max_depth: u32 = 32;

/// Errors from submodule operations.
pub const Error = error{
    /// A gitlink in the index with no `.gitmodules` section naming its
    /// path. `Refusal.path` says which.
    NoSubmoduleMapping,
    /// No url for the submodule in the configuration or in `.gitmodules`.
    MissingUrl,
    /// A url `gitmodules.checkUrl` refuses. `Refusal.setting` holds it.
    DisallowedUrl,
    /// A submodule path whose component is a symbolic link.
    SymlinkInPath,
    /// `modules/<name>` would lie inside another submodule's repository —
    /// `a` and `a/hooks` — and share its files.
    GitDirInsideGitDir,
    /// The submodule has changes this operation would throw away: its
    /// `HEAD` moved, content modified, untracked files, or a gitlink change
    /// staged in the superproject. `force` is what discards them.
    LocalModifications,
    /// `merge` or `rebase`, which this release does not run. The setting
    /// names it.
    UnsupportedUpdate,
    /// A `!command` update, and no `Programs` to run it with.
    UpdateCommandRefused,
    /// The `!command` update exited with a failure.
    UpdateCommandFailed,
    /// `submodule.<name>.update` in the configuration is not a strategy.
    InvalidUpdate,
    /// `submodule.<name>.ignore` or `diff.ignoreSubmodules` is not `none`,
    /// `untracked`, `dirty` or `all`.
    InvalidIgnore,
    /// No repository for the submodule anywhere on the disk, and no
    /// `Transport` to clone one: a clone is what is missing.
    NotCloned,
    /// The recorded commit is not in the submodule's repository, and no
    /// `Transport` brought it: a fetch is what is missing.
    CommitMissing,
    /// The submodule's `HEAD` names no commit, so there is no revision to
    /// move from.
    NoCurrentRevision,
    /// The submodule's `.git` directory has worktrees of its own, which
    /// moving it would break.
    SubmoduleHasWorktrees,
    /// `modules/<name>` is already there, so a `.git` directory cannot move
    /// into it.
    GitDirExists,
    /// A submodule nested deeper than `max_depth`.
    NestingTooDeep,
    /// `.gitmodules` is unmerged in the index, so it cannot be edited.
    GitmodulesUnmerged,
    /// The superproject has no working tree.
    BareRepository,
    /// Under `extensions.submodulePathConfig`, no `submodule.<name>.gitdir`
    /// names the submodule's repository, or none of git's defaults for one
    /// passes its check. `Refusal.setting` names the setting.
    NoSubmoduleGitDir,
    /// The `Transport` failed; it says why.
    TransportFailed,
    /// Under `UpdateOptions.init`, the submodule's path holds something
    /// before it is cloned: git's "directory not empty", which keeps a
    /// clone from landing beside files already there.
    DirectoryNotEmpty,
    /// `branch --recurse-submodules` without `submodule.propagateBranches`.
    BranchesNotPropagated,
} || branch_mod.Error || pathspec_mod.Error || repo_mod.Error || worktree.Error || gitmodules.ParseError || gitmodules.ResolveError ||
    Repository.WriteConfigError || refs_mod.TransactionError || program.Error || gitlink.Error ||
    Io.Dir.RealPathError || Io.Dir.RenameError || Io.Dir.DeleteTreeError;

/// Where a refusal says which submodule and which setting, without
/// allocating.
pub const Refusal = struct {
    path_buffer: [512]u8 = undefined,
    path_len: usize = 0,
    setting_buffer: [512]u8 = undefined,
    setting_len: usize = 0,

    /// The submodule's path, from the top superproject. Empty when nothing
    /// was refused.
    pub fn path(r: *const Refusal) []const u8 {
        return r.path_buffer[0..r.path_len];
    }

    /// The setting or value that decided, when one did.
    pub fn setting(r: *const Refusal) []const u8 {
        return r.setting_buffer[0..r.setting_len];
    }

    fn set(r: *Refusal, p: []const u8, s: []const u8) void {
        r.path_len = @min(p.len, r.path_buffer.len);
        @memcpy(r.path_buffer[0..r.path_len], p[0..r.path_len]);
        r.setting_len = @min(s.len, r.setting_buffer.len);
        @memcpy(r.setting_buffer[0..r.setting_len], s[0..r.setting_len]);
    }
};

fn refuse(refusal: ?*Refusal, path: []const u8, setting: []const u8, err: Error) Error {
    if (refusal) |r| r.set(path, setting);
    return err;
}

//=========================================================================
// .gitmodules and the list of submodules
//=========================================================================

/// Read `.gitmodules` from where git reads it: the working tree's file; or,
/// when there is none, the blob the index records; or, when the index
/// records none, the one in `HEAD`'s tree. While the index holds the file
/// unmerged git reads none of it, and neither does this.
pub fn loadGitmodules(gpa: Allocator, io: Io, repo: *Repository, index: *const Index) Self.Error!Gitmodules {
    if (isUnmerged(index, ".gitmodules")) return .empty(gpa);
    if (repo.workDirectory()) |lent_wt| {
        const wt = lent_wt.get();
        const text = fs.readFileAlloc(gpa, io, wt, ".gitmodules", 1 << 24) catch |err| switch (err) {
            error.IsDir => null,
            else => |e| return e,
        };
        if (text) |bytes| {
            defer gpa.free(bytes);
            return Gitmodules.parse(gpa, bytes);
        }
    }
    const blob: ?Oid = if (index.find(".gitmodules")) |entry| entry.oid else blk: {
        const tree = (try repo.headTree(io)) orelse break :blk null;
        const found = try repo.objectDatabase().read(io, tree);
        defer repo.objectDatabase().allocator().free(found.bytes);
        const parsed: object.Tree = .parse(repo.objectFormat(), found.bytes);
        const entry = (try parsed.find(".gitmodules")) orelse break :blk null;
        break :blk entry.oid;
    };
    const oid = blob orelse return .empty(gpa);
    const found = try repo.objectDatabase().read(io, oid);
    defer repo.objectDatabase().allocator().free(found.bytes);
    if (found.type != .blob) return error.UnexpectedObjectType;
    return Gitmodules.parse(gpa, found.bytes);
}

fn isUnmerged(index: *const Index, path: []const u8) bool {
    return index.findStage(path, 1) != null or index.findStage(path, 2) != null or
        index.findStage(path, 3) != null;
}

/// One gitlink in the index.
pub const Entry = struct {
    /// Relative to the superproject's working tree. Owned by the listing.
    path: []const u8,
    /// The commit the index records, or `null` while the path is unmerged.
    recorded: ?Oid,
    /// The `.gitmodules` section naming the path, or `null` when none does.
    /// Borrowed from the listing.
    module: ?*const gitmodules.Submodule,

    /// The submodule's name, when `.gitmodules` gives it one.
    pub fn name(e: Entry) ?[]const u8 {
        return if (e.module) |m| m.name else null;
    }
};

/// Every gitlink in an index, in index order, each path once.
pub const Listing = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    entries: []Entry,
    gitmodules: Gitmodules,

    /// Release the listing.
    pub fn deinit(l: *Listing) void {
        l.gitmodules.deinit();
        var arena = l.arena.promote(l.gpa);
        arena.deinit();
        l.* = undefined;
    }

    /// The entry at `path`, or `null`.
    pub fn find(l: *const Listing, path: []const u8) ?*const Entry {
        for (l.entries) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

/// The gitlinks `index` holds, with the `.gitmodules` section for each.
///
/// `paths` narrows the list the way a pathspec does: each is a submodule's
/// path or a directory above some. `null` lists every one.
pub fn list(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    index: *const Index,
    paths: ?[]const []const u8,
) Self.Error!Listing {
    var modules = try loadGitmodules(gpa, io, repo, index);
    errdefer modules.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    for (index.entries.items) |entry| {
        if (entry.mode != .gitlink) continue;
        if (!selected(paths, entry.path)) continue;
        if (entries.items.len > 0 and std.mem.eql(u8, entries.items[entries.items.len - 1].path, entry.path)) {
            if (entry.stage != 0) entries.items[entries.items.len - 1].recorded = null;
            continue;
        }
        try entries.append(arena, .{
            .path = try arena.dupe(u8, entry.path),
            .recorded = if (entry.stage == 0) entry.oid else null,
            .module = null,
        });
    }
    for (entries.items) |*entry| entry.module = modules.byPath(entry.path);
    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = entries.items, .gitmodules = modules };
}

fn selected(paths: ?[]const []const u8, path: []const u8) bool {
    const wanted = paths orelse return true;
    for (wanted) |raw| {
        const p = std.mem.trimEnd(u8, raw, "/");
        if (p.len == 0 or std.mem.eql(u8, p, ".")) return true;
        if (std.mem.eql(u8, p, path)) return true;
        if (std.mem.startsWith(u8, path, p) and path.len > p.len and path[p.len] == '/') return true;
    }
    return false;
}

//=========================================================================
// Settings
//=========================================================================

fn configKey(arena: Allocator, name: []const u8, variable: []const u8) Allocator.Error![]const u8 {
    return arena.print("submodule.{s}.{s}", .{ name, variable });
}

/// A configuration value with its quotes and escapes undone, or `null`.
fn configString(arena: Allocator, config: *const config_mod.Config, key: []const u8) Error!?[]const u8 {
    const value = config.get(key) orelse return null;
    const copy = try arena.dupe(u8, value);
    return copy;
}

/// Whether git counts the submodule as active: `submodule.<name>.active`
/// when it is set, else whether `submodule.active`'s pathspecs match its
/// path when those are set, else whether `submodule.<name>.url` is.
pub fn isActive(arena: Allocator, repo: *Repository, name: []const u8, path: []const u8) Self.Error!bool {
    const active_key = try configKey(arena, name, "active");
    if (repo.configuration().find(active_key) != null) return repo.configuration().getBool(active_key, false);
    const specs = try repo.configuration().all("submodule.active");
    defer repo.configuration().gpa.free(specs);
    if (specs.len > 0) {
        // git reads `submodule.active` as pathspecs: a path, a directory above it or a glob,
        // with `:(exclude)`, `:!` and `:^` taking matches away.
        var parsed = try pathspec_mod.parse(arena, specs);
        defer parsed.deinit();
        return parsed.matches(path);
    }
    return repo.configuration().get(try configKey(arena, name, "url")) != null;
}

/// The remote git resolves a relative url against, and fetches from when
/// none is named: the current branch's `branch.<name>.remote`, else the
/// only remote when there is one, else `origin`.
pub fn defaultRemote(arena: Allocator, io: Io, repo: *Repository) Error![]const u8 {
    if (try repo.refStore().currentBranch(arena, io)) |branch| {
        const key = try arena.print("branch.{s}.remote", .{branch});
        if (try configString(arena, repo.configuration(), key)) |remote| return remote;
    }
    return remote_mod.fallback(repo.configuration());
}

/// The remote of the submodule `sub` that git fetches a commit from and
/// sets the url of: git's `get_default_remote_submodule`, the first remote
/// whose url is `module`'s in `.gitmodules` (a relative one resolved
/// against the superproject's), once the submodule's `url.<base>.insteadOf`
/// has rewritten it, as git 2.56 rewrites it before comparing; else
/// `defaultRemote`.
fn moduleRemote(arena: Allocator, io: Io, repo: *Repository, sub: *Repository, module: *const gitmodules.Submodule) Error![]const u8 {
    const raw = module.url orelse return defaultRemote(arena, io, sub);
    const url = if (gitmodules.isRelativeUrl(raw)) try gitmodules.resolveUrl(arena, try superprojectUrl(arena, io, repo), raw, null) else raw;
    const config = sub.configuration();
    const wanted = try remote_mod.rewrite(arena, config, url, .fetch) orelse url;
    for (try remote_mod.names(arena, config)) |name| {
        for (try remote_mod.resetList(arena, config, try arena.print("remote.{s}.url", .{name}))) |configured| {
            const each = try remote_mod.rewrite(arena, config, configured, .fetch) orelse configured;
            if (std.mem.eql(u8, each, wanted)) return name;
        }
    }
    return defaultRemote(arena, io, sub);
}

/// What a relative url is resolved against: the default remote's url, or,
/// when it has none, the superproject's own working tree — git's "this
/// repository is its own authoritative upstream".
fn superprojectUrl(arena: Allocator, io: Io, repo: *Repository) Error![]const u8 {
    const remote = try defaultRemote(arena, io, repo);
    const key = try arena.print("remote.{s}.url", .{remote});
    if (try configString(arena, repo.configuration(), key)) |url| {
        if (url.len > 0) return url;
    }
    return try fs.realPathAlloc(arena, io, (repo.workDirectory() orelse return error.BareRepository).get(), ".");
}

/// `../` for every component of `path`, which is what a url relative to a
/// relative superproject url needs in front of it from inside the
/// submodule.
fn upPath(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const components = std.mem.count(u8, std.mem.trimEnd(u8, path, "/"), "/") + 1;
    const out = try arena.alloc(u8, components * 3);
    for (0..components) |i| @memcpy(out[i * 3 ..][0..3], "../");
    return out;
}

/// The submodule's url as its superproject's configuration should hold it:
/// the configured one, or `.gitmodules`' resolved against the
/// superproject's.
fn resolvedUrl(
    arena: Allocator,
    io: Io,
    repo: *Repository,
    module: *const gitmodules.Submodule,
    display: []const u8,
    refusal: ?*Refusal,
) Error![]const u8 {
    if (try configString(arena, repo.configuration(), try configKey(arena, module.name, "url"))) |url| return url;
    return moduleUrl(arena, io, repo, module, null, display, refusal);
}

/// `.gitmodules`' url for the module, checked, and resolved against the
/// superproject's own when it is relative.
fn moduleUrl(
    arena: Allocator,
    io: Io,
    repo: *Repository,
    module: *const gitmodules.Submodule,
    up_path: ?[]const u8,
    display: []const u8,
    refusal: ?*Refusal,
) Error![]const u8 {
    const url = module.url orelse return refuse(refusal, display, "", error.MissingUrl);
    if (!try gitmodules.checkUrl(arena, url)) return refuse(refusal, display, url, error.DisallowedUrl);
    if (!gitmodules.isRelativeUrl(url)) return url;
    const base = try superprojectUrl(arena, io, repo);
    return gitmodules.resolveUrl(arena, base, url, up_path) catch |err| switch (err) {
        error.CannotStripComponent => refuse(refusal, display, url, error.CannotStripComponent),
        else => |e| e,
    };
}

/// Settings for the superproject's `.git/config`, written together when
/// the operation is done: `writeConfig` reads the file again under its lock
/// and applies only these, so what another process wrote meanwhile stays,
/// and the repository publishes what the file then says.
const LocalEdits = struct {
    arena: Allocator,
    edits: std.ArrayList(Repository.ConfigEdit) = .empty,

    fn set(e: *LocalEdits, key: []const u8, value: []const u8) Error!void {
        try e.edits.append(e.arena, .{ .set = .{ .name = try e.arena.dupe(u8, key), .value = try e.arena.dupe(u8, value) } });
    }

    fn commit(e: *LocalEdits, io: Io, repo: *Repository) Error!void {
        if (e.edits.items.len != 0) _ = try repo.writeConfig(io, .local, e.edits.items, .{});
        e.edits.clearRetainingCapacity();
    }
};

/// Set or, with `null`, remove `core.worktree` in the `config` of the
/// submodule repository in `dir`, with `repo`'s permissions.
fn setCoreWorktree(io: Io, repo: *const Repository, dir: Io.Dir, value: ?[]const u8) Error!void {
    const edit: Repository.ConfigEdit = if (value) |v| .{ .set = .{ .name = "core.worktree", .value = v } } else .{ .unset = .{ .name = "core.worktree" } };
    _ = try repo.writeConfigFile(io, dir, "config", &.{edit});
}

//=========================================================================
// Layout
//=========================================================================

/// `target` relative to the directory `base`, both absolute and
/// `/`-separated: `../` for each component of `base` below what the two
/// share, then the rest of `target`. Two paths on different drives have
/// nothing in common and the absolute path is the answer, as it is for git.
fn relativePath(arena: Allocator, target: []const u8, base: []const u8) Allocator.Error![]const u8 {
    var t = std.mem.tokenizeScalar(u8, target, '/');
    var b = std.mem.tokenizeScalar(u8, base, '/');
    var t_parts: std.ArrayList([]const u8) = .empty;
    var b_parts: std.ArrayList([]const u8) = .empty;
    while (t.next()) |part| try t_parts.append(arena, part);
    while (b.next()) |part| try b_parts.append(arena, part);
    var common: usize = 0;
    while (common < t_parts.items.len and common < b_parts.items.len) : (common += 1) {
        const same = if (builtin.target.os.tag == .windows)
            std.ascii.eqlIgnoreCase(t_parts.items[common], b_parts.items[common])
        else
            std.mem.eql(u8, t_parts.items[common], b_parts.items[common]);
        if (!same) break;
    }
    if (common == 0 and builtin.target.os.tag == .windows) return target;
    var out: std.ArrayList(u8) = .empty;
    for (b_parts.items[common..]) |_| try out.appendSlice(arena, "../");
    for (t_parts.items[common..], 0..) |part, i| {
        if (i > 0) try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    if (out.items.len == 0) return "./";
    if (out.items[out.items.len - 1] == '/') out.items.len -= 1;
    return out.items;
}

/// Point a working tree and a git directory at each other, the way git's
/// `connect_work_tree_and_git_dir` does: `gitdir: <relative>` in the
/// working tree's `.git` file, and `core.worktree` relative the other way.
fn connect(
    arena: Allocator,
    io: Io,
    repo: *const Repository,
    work: Io.Dir,
    work_abs: []const u8,
    git_dir: Io.Dir,
    git_dir_abs: []const u8,
) Error!void {
    const to_git_dir = try relativePath(arena, git_dir_abs, work_abs);
    // `gitfile.target` refuses a `.git` file with no path in it.
    assert(to_git_dir.len != 0);
    try gitfile.write(io, work, to_git_dir, repo.settings().hide_dot_files);
    try setCoreWorktree(io, repo, git_dir, try relativePath(arena, work_abs, git_dir_abs));
}

/// Refuse a path that must never become a filesystem path, and one with a
/// symbolic link for any component, which is git's
/// `validate_submodule_path`.
fn validatePath(io: Io, wt: Io.Dir, path: []const u8, display: []const u8, refusal: ?*Refusal, protect: safe_path.Protect) Error!void {
    var refused: safe_path.Refusal = undefined;
    _ = safe_path.checked(path, .{ .use = .worktree, .protect = protect, .refusal = &refused }) catch
        return refuse(refusal, display, @tagName(refused.reason), error.UnsafePath);
    var end: usize = 0;
    while (end <= path.len) : (end += 1) {
        if (end < path.len and path[end] != '/') continue;
        if (try fs.statAt(io, wt, path[0..end])) |found| {
            if (found.kind == .sym_link) return refuse(refusal, display, path[0..end], error.SymlinkInPath);
        }
    }
}

/// Refuse a name whose `modules/<name>` would lie inside the repository of
/// another name, which is git's `validate_submodule_git_dir`.
fn validateGitDir(arena: Allocator, io: Io, git_dir: Io.Dir, name: []const u8, display: []const u8, refusal: ?*Refusal) Error!void {
    for (name, 0..) |c, i| {
        if (c != '/' and c != '\\') continue;
        const prefix = try arena.print("modules/{s}", .{name[0..i]});
        var dir = git_dir.openDir(io, prefix, .{}) catch continue;
        defer dir.close(io);
        if (try discover.directory.isGitDirectory(io, dir)) return refuse(refusal, display, prefix, error.GitDirInsideGitDir);
    }
}

/// Open the repository whose working tree is `path` in `repo`'s.
fn openSubmodule(gpa: Allocator, io: Io, repo: *Repository, path: []const u8, options: Repository.OpenOptions) Error!Repository {
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    var dir = try wt.openDir(io, path, .{});
    defer dir.close(io);
    var o = options;
    o.discover = false;
    return Repository.open(gpa, io, dir, o);
}

/// The repository of the submodule `name` at `path`, as git's
/// `repo_submodule_init` finds it: the one its working tree's `.git`
/// opens, else its repository in `modules`, which has no working tree;
/// `null` when neither is there.
pub fn openRepository(gpa: Allocator, io: Io, repo: *Repository, module: PathName, options: Repository.OpenOptions) Self.Error!?Repository {
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    if (try gitlink.isRepository(gpa, io, wt, module.path)) return try openSubmodule(gpa, io, repo, module.path, options);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const where = moduleDir(arena_instance.allocator(), io, repo, module.name, module.path, null) catch |err| switch (err) {
        error.NoSubmoduleGitDir, error.GitDirInsideGitDir => return null,
        else => |e| return e,
    };
    var dir = where.base.openDir(io, where.path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
    defer dir.close(io);
    if (!try discover.directory.isGitDirectory(io, dir)) return null;
    var o = options;
    o.discover = false;
    return try Repository.open(gpa, io, dir, o);
}

/// A submodule's path and its name in `.gitmodules`.
pub const PathName = struct { path: []const u8, name: []const u8 };

/// The commit a repository's `HEAD` resolves to, or `null`.
fn headOf(gpa: Allocator, io: Io, repo: *Repository) Error!?Oid {
    const resolved = (repo.head(io) catch |err| switch (err) {
        error.MalformedRef, error.MalformedPackedRefs, error.SymbolicRefLoop, error.InvalidRefName => return null,
        else => |e| return e,
    }) orelse return null;
    gpa.free(resolved.name);
    return resolved.oid;
}

fn join(arena: Allocator, prefix: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (prefix.len == 0) return arena.dupe(u8, path);
    return arena.print("{s}{s}", .{ prefix, path });
}

//=========================================================================
// git submodule status
//=========================================================================

/// What `git submodule status` prints in its first column.
pub const State = enum(u8) {
    /// Not initialised, or initialised and not populated: `-`.
    not_initialized = '-',
    /// Its `HEAD` is the recorded commit: a space.
    current = ' ',
    /// Its `HEAD` is another commit: `+`.
    differs = '+',
    /// The superproject's index holds the gitlink unmerged: `U`.
    conflict = 'U',
};

/// One submodule, as `git submodule status` reports it.
pub const StatusEntry = struct {
    state: State,
    /// The recorded commit; the submodule's `HEAD` for `differs`, unless
    /// `StatusOptions.cached`; zeros for `conflict`.
    oid: Oid,
    /// Relative to the top superproject's working tree. Owned by the result.
    path: []const u8,
    /// Owned by the result.
    name: []const u8,
    /// 0 for the top superproject's own submodules.
    depth: u32,
};

/// What `status` found, in the order git prints it.
pub const Statuses = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    entries: []StatusEntry,

    /// Release the result.
    pub fn deinit(s: *Statuses) void {
        var arena = s.arena.promote(s.gpa);
        arena.deinit();
        s.* = undefined;
    }

    /// The entry at `path`, or `null`.
    pub fn find(s: *const Statuses, path: []const u8) ?StatusEntry {
        for (s.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

/// How `status` behaves.
pub const StatusOptions = struct {
    /// Which submodules; see `list`.
    paths: ?[]const []const u8 = null,
    /// `--recursive`: the submodules of every populated submodule too.
    recursive: bool = false,
    /// `--cached`: the recorded commit even where `HEAD` differs.
    cached: bool = false,
    /// What each submodule's repository is opened with.
    open: Repository.OpenOptions = .{},
    refusal: ?*Refusal = null,
};

/// `git submodule status`: each submodule's state and commit.
///
/// A gitlink `.gitmodules` does not name is `error.NoSubmoduleMapping`, as
/// it is for git. The describe name git prints after the path is not
/// computed.
pub fn status(gpa: Allocator, io: Io, repo: *Repository, options: StatusOptions) Self.Error!Statuses {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    var out: std.ArrayList(StatusEntry) = .empty;
    try statusInto(arena_instance.allocator(), gpa, io, repo, options, options.paths, "", 0, &out);
    return .{ .gpa = gpa, .arena = arena_instance.state, .entries = out.items };
}

fn statusInto(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    options: StatusOptions,
    paths: ?[]const []const u8,
    prefix: []const u8,
    depth: u32,
    out: *std.ArrayList(StatusEntry),
) Error!void {
    if (depth > max_depth) return refuse(options.refusal, prefix, "", error.NestingTooDeep);
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, paths);
    defer listing.deinit();

    for (listing.entries) |entry| {
        const display = try join(arena, prefix, entry.path);
        const module = entry.module orelse return refuse(options.refusal, display, "", error.NoSubmoduleMapping);
        const name = try arena.dupe(u8, module.name);
        const recorded = entry.recorded orelse {
            try out.append(arena, .{ .state = .conflict, .oid = .zero(repo.objectFormat()), .path = display, .name = name, .depth = depth });
            continue;
        };
        var found: ?gitlink.GitDir = if (try isActive(arena, repo, module.name, entry.path))
            try gitlink.open(gpa, io, wt, entry.path)
        else
            null;
        if (found == null) {
            try out.append(arena, .{ .state = .not_initialized, .oid = recorded, .path = display, .name = name, .depth = depth });
            continue;
        }
        found.?.deinit(io);

        const checked_out = try gitlink.head(gpa, io, wt, entry.path);
        if (checked_out == null or checked_out.?.eql(recorded)) {
            try out.append(arena, .{ .state = .current, .oid = recorded, .path = display, .name = name, .depth = depth });
        } else {
            try out.append(arena, .{
                .state = .differs,
                .oid = if (options.cached) recorded else checked_out.?,
                .path = display,
                .name = name,
                .depth = depth,
            });
        }
        if (options.recursive) {
            var sub = try openSubmodule(gpa, io, repo, entry.path, options.open);
            defer sub.deinit(io);
            try statusInto(arena, gpa, io, &sub, options, null, try arena.print("{s}/", .{display}), depth + 1, out);
        }
    }
}

//=========================================================================
// The superproject's status: what `worktree.status` asks
//=========================================================================

/// Answers `worktree.status`'s question about each populated submodule the
/// way `git status` does.
///
/// The ignore setting comes from `ProbeOptions.ignore` when given, which is
/// `--ignore-submodules`; else `submodule.<name>.ignore` from the
/// configuration, else from `.gitmodules`; else `diff.ignoreSubmodules`.
/// `all` reports nothing, `dirty` only a moved `HEAD`, `untracked`
/// everything but untracked files. Content is a status run inside the
/// submodule with a probe of its own, so a change two submodules down shows
/// on the gitlink at the top — and a submodule of the submodule whose only
/// change is untracked files counts as untracked content, not as modified,
/// which is git's rule too.
pub const StatusProbe = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    repo: *Repository,
    modules: Gitmodules,
    options: ProbeOptions,
    depth: u32,
    /// What went wrong when `worktree.status` returned
    /// `error.SubmoduleUnreadable`.
    failure: ?Failure = null,

    /// How the probe reads settings.
    pub const ProbeOptions = struct {
        /// `--ignore-submodules=<when>`, which beats every setting. `all`
        /// leaves out a staged gitlink change as well, which no setting
        /// does.
        ignore: ?gitmodules.Ignore = null,
        /// What each submodule's repository is opened with.
        open: Repository.OpenOptions = .{},
    };

    /// A submodule that could not be read, and why.
    pub const Failure = struct {
        path_buffer: [512]u8 = undefined,
        path_len: usize = 0,
        /// The error its repository gave.
        err: ErrorNamespace.Error,

        /// The submodule's path, from the superproject the probe serves.
        pub fn path(f: *const Failure) []const u8 {
            return f.path_buffer[0..f.path_len];
        }
    };

    /// A probe for `repo`, whose index — for the `.gitmodules` blob, when
    /// the working tree has no file — is `index`.
    pub fn init(gpa: Allocator, io: Io, repo: *Repository, index: *const Index, options: ProbeOptions) Self.Error!StatusProbe {
        return initAt(gpa, io, repo, index, options, 0);
    }

    fn initAt(gpa: Allocator, io: Io, repo: *Repository, index: *const Index, options: ProbeOptions, depth: u32) ErrorNamespace.Error!StatusProbe {
        return .{
            .gpa = gpa,
            .repo = repo,
            .modules = try loadGitmodules(gpa, io, repo, index),
            .options = options,
            .depth = depth,
        };
    }

    /// Release the probe.
    pub fn deinit(p: *StatusProbe) void {
        p.modules.deinit();
        p.* = undefined;
    }

    /// The interface `worktree.StatusOptions.submodules` takes. The probe
    /// must outlive the status call.
    pub fn probe(p: *StatusProbe) worktree.SubmoduleProbe {
        return .{ .context = p, .inspectFn = inspect, .ignore_staged = p.options.ignore == .all };
    }

    fn inspect(io: Io, context: *anyopaque, path: []const u8, recorded: Oid) worktree.Error!worktree.SubmoduleState {
        const p: *StatusProbe = @ptrCast(@alignCast(context)); // aegis: no-danger: the context handed out with this function is a StatusProbe
        return p.inspectPath(io, path, recorded) catch |err| return p.fail(path, err);
    }

    fn fail(p: *StatusProbe, path: []const u8, err: ErrorNamespace.Error) worktree.Error {
        if (err == error.SubmoduleUnreadable) return error.SubmoduleUnreadable;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        var failure: Failure = .{ .err = err };
        failure.path_len = @min(path.len, failure.path_buffer.len);
        @memcpy(failure.path_buffer[0..failure.path_len], path[0..failure.path_len]);
        p.failure = failure;
        return error.SubmoduleUnreadable;
    }

    fn inspectPath(p: *StatusProbe, io: Io, path: []const u8, recorded: Oid) ErrorNamespace.Error!worktree.SubmoduleState {
        var arena_instance: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        const ignore = try p.ignoreFor(arena, path);
        if (ignore == .all) return .{};
        const wt = (p.repo.workDirectory() orelse return error.BareRepository).get();
        var found = (try gitlink.open(p.gpa, io, wt, path)) orelse return .{};
        found.deinit(io);
        if (p.depth >= max_depth) return error.NestingTooDeep;

        var sub = try openSubmodule(p.gpa, io, p.repo, path, p.options.open);
        defer sub.deinit(io);
        var nested_failure: ?Failure = null;
        const state = inspectRepository(p.gpa, io, &sub, recorded, ignore, p.options, p.depth + 1, &nested_failure) catch |err| {
            if (nested_failure) |nested| {
                // Say which submodule, from this superproject.
                var failure = nested;
                const full = arena.print("{s}/{s}", .{ path, nested.path() }) catch path;
                failure.path_len = @min(full.len, failure.path_buffer.len);
                @memcpy(failure.path_buffer[0..failure.path_len], full[0..failure.path_len]);
                p.failure = failure;
            }
            return err;
        };
        return state;
    }

    fn ignoreFor(p: *StatusProbe, arena: Allocator, path: []const u8) ErrorNamespace.Error!gitmodules.Ignore {
        if (p.options.ignore) |forced| return forced;
        if (p.modules.byPath(path)) |module| {
            if (try configString(arena, p.repo.configuration(), try configKey(arena, module.name, "ignore"))) |text| {
                return gitmodules.Ignore.parse(text) orelse error.InvalidIgnore;
            }
            if (module.ignore) |from_file| return from_file;
        }
        if (try configString(arena, p.repo.configuration(), "diff.ignoresubmodules")) |text| {
            return gitmodules.Ignore.parse(text) orelse error.InvalidIgnore;
        }
        return .none;
    }
};

/// What a submodule's working tree holds against `recorded`, under
/// `ignore`: git's `is_submodule_modified`, which reads a
/// `status --porcelain=2` run inside it.
fn inspectRepository(
    gpa: Allocator,
    io: Io,
    sub: *Repository,
    recorded: Oid,
    ignore: gitmodules.Ignore,
    options: StatusProbe.ProbeOptions,
    depth: u32,
    failure: *?StatusProbe.Failure,
) Error!worktree.SubmoduleState {
    var state: worktree.SubmoduleState = .{};
    if (try headOf(gpa, io, sub)) |checked_out| state.new_commits = !checked_out.eql(recorded);
    if (ignore == .dirty or ignore == .all) return state;

    var index = try sub.openIndex(io);
    defer index.deinit();
    var ignore_rules = try sub.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try sub.loadAttrs(io);
    defer attrs.deinit();
    const required = try sub.requiredFilters(gpa);
    defer gpa.free(required);
    var rules = try sub.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.required_filters = required;

    var child = try StatusProbe.initAt(gpa, io, sub, &index, .{ .open = options.open }, depth);
    defer child.deinit();
    var result = worktree.status(gpa, io, (sub.workDirectory() orelse return error.BareRepository).get(), .{ .index = &index, .db = sub.objectDatabase() }, .{
        .rules = rules,
        .head_tree = try sub.headTree(io),
        .untracked = if (ignore == .untracked) .no else .normal,
        .submodules = child.probe(),
    }) catch |err| {
        failure.* = child.failure;
        return err;
    };
    defer result.deinit();

    for (result.entries) |entry| {
        if (entry.unstaged == .ignored) continue;
        if (entry.unstaged == .untracked and entry.staged == .unmodified and !entry.conflicted) {
            state.untracked_content = true;
            continue;
        }
        if (entry.submodule) |nested| {
            if (nested.untracked_content) state.untracked_content = true;
            const untracked_only = nested.untracked_content and !nested.new_commits and !nested.modified_content;
            if (entry.conflicted or !untracked_only) state.modified_content = true;
            continue;
        }
        state.modified_content = true;
    }
    return state;
}

//=========================================================================
// git submodule init / sync / deinit
//=========================================================================

/// How `init` behaves.
pub const InitOptions = struct {
    /// Which submodules; see `list`. `null` is git's default: every one, or
    /// only the active ones when `submodule.active` is set.
    paths: ?[]const []const u8 = null,
    refusal: ?*Refusal = null,
};

/// What `init` wrote.
pub const InitOutcome = struct {
    /// Submodules whose url was copied into `.git/config`.
    registered: u32 = 0,
    /// Submodules given `submodule.<name>.active = true`.
    activated: u32 = 0,
};

/// `git submodule init`: copy each submodule's url and update strategy
/// from `.gitmodules` into `.git/config`, and mark it active.
///
/// A url already configured is left as it is. A relative one is resolved
/// against the default remote's url, or against the superproject's own
/// path when that remote has none, exactly as git resolves it.
pub fn init(gpa: Allocator, io: Io, repo: *Repository, options: InitOptions) Self.Error!InitOutcome {
    var outcome: InitOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, options.paths);
    defer listing.deinit();
    var edits: LocalEdits = .{ .arena = arena };

    const only_active = options.paths == null and repo.configuration().has("submodule.active");
    for (listing.entries) |entry| {
        if (only_active) {
            const m = entry.module orelse continue;
            if (!try isActive(arena, repo, m.name, entry.path)) continue;
        }
        const module = entry.module orelse return refuse(options.refusal, entry.path, "", error.NoSubmoduleMapping);

        if (!try isActive(arena, repo, module.name, entry.path)) {
            try edits.set(try configKey(arena, module.name, "active"), "true");
            outcome.activated += 1;
        }
        const url_key = try configKey(arena, module.name, "url");
        if (repo.configuration().get(url_key) == null) {
            const url = try moduleUrl(arena, io, repo, module, null, entry.path, options.refusal);
            try edits.set(url_key, url);
            outcome.registered += 1;
        }
        const update_key = try configKey(arena, module.name, "update");
        if (repo.configuration().get(update_key) == null) {
            if (module.update) |strategy| try edits.set(update_key, strategy.name());
        }
        if (repo.submodulePathConfig()) try setDefaultGitDir(arena, io, repo, module.name, &edits);
    }
    try edits.commit(io, repo);
    return outcome;
}

/// How `sync` behaves.
pub const SyncOptions = struct {
    /// Which submodules; see `list`.
    paths: ?[]const []const u8 = null,
    /// `--recursive`.
    recursive: bool = false,
    /// What each submodule's repository is opened with.
    open: Repository.OpenOptions = .{},
    refusal: ?*Refusal = null,
};

/// What `sync` wrote.
pub const SyncOutcome = struct {
    /// Submodules whose url in `.git/config` was rewritten.
    synced: u32 = 0,
    /// Populated submodules whose own remote was pointed at the url too.
    remotes: u32 = 0,
};

/// `git submodule sync`: rewrite each active submodule's url in
/// `.git/config` from `.gitmodules`, and point a populated submodule's
/// default remote at it.
///
/// A relative url is resolved twice, as git does: once for the
/// superproject's configuration, and once for the submodule's own remote,
/// where a superproject url that is itself relative needs a `../` for each
/// component of the submodule's path in front of it.
pub fn sync(gpa: Allocator, io: Io, repo: *Repository, options: SyncOptions) Self.Error!SyncOutcome {
    var outcome: SyncOutcome = .{};
    try syncIn(gpa, io, repo, options, options.paths, "", 0, &outcome);
    return outcome;
}

fn syncIn(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    options: SyncOptions,
    paths: ?[]const []const u8,
    prefix: []const u8,
    depth: u32,
    outcome: *SyncOutcome,
) Error!void {
    if (depth > max_depth) return refuse(options.refusal, prefix, "", error.NestingTooDeep);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, paths);
    defer listing.deinit();
    var edits: LocalEdits = .{ .arena = arena };

    for (listing.entries) |entry| {
        const module = entry.module orelse continue;
        if (!try isActive(arena, repo, module.name, entry.path)) continue;
        const display = try join(arena, prefix, entry.path);
        try validatePath(io, wt, entry.path, display, options.refusal, repo.settings().protect);

        var for_super: []const u8 = "";
        var for_sub: []const u8 = "";
        if (module.url != null) {
            for_super = try moduleUrl(arena, io, repo, module, null, display, options.refusal);
            for_sub = try moduleUrl(arena, io, repo, module, try upPath(arena, entry.path), display, options.refusal);
        }
        try edits.set(try configKey(arena, module.name, "url"), for_super);
        outcome.synced += 1;

        var found = (try gitlink.open(gpa, io, wt, entry.path)) orelse continue;
        found.deinit(io);
        var sub = try openSubmodule(gpa, io, repo, entry.path, options.open);
        defer sub.deinit(io);
        const remote = try moduleRemote(arena, io, repo, &sub, module);
        _ = try sub.writeConfig(io, .local, &.{.{ .set = .{ .name = try arena.print("remote.{s}.url", .{remote}), .value = for_sub } }}, .{});
        outcome.remotes += 1;
        if (options.recursive) {
            try syncIn(gpa, io, &sub, options, null, try arena.print("{s}/", .{display}), depth + 1, outcome);
        }
    }
    try edits.commit(io, repo);
}

/// How `deinitialize` behaves.
pub const DeinitOptions = struct {
    /// Which submodules; see `list`. `null` is every one, which is what
    /// git's `--all` asks for.
    paths: ?[]const []const u8 = null,
    /// `--force`: remove a working tree with local changes.
    force: bool = false,
    /// What each submodule's repository is opened with, to look for local
    /// changes.
    open: Repository.OpenOptions = .{},
    refusal: ?*Refusal = null,
};

/// What `deinitialize` did.
pub const DeinitOutcome = struct {
    /// Working trees removed and left as an empty directory.
    cleared: u32 = 0,
    /// Submodules whose `[submodule "<name>"]` left `.git/config`.
    unregistered: u32 = 0,
    /// `.git` directories moved into `modules/` first, so the repository
    /// outlives its working tree.
    absorbed: u32 = 0,
};

/// `git submodule deinit`: remove each submodule's working tree, leave an
/// empty directory where it was, and remove its section from
/// `.git/config`. Its repository stays in `modules/<name>`, so an `update`
/// brings it back without a fetch.
///
/// Without `force` a submodule with anything to lose is refused, which is
/// what git decides by asking `git rm -n`: a `HEAD` moved from the recorded
/// commit, modified content, untracked files, or a gitlink change staged in
/// the superproject. A `.git` directory inside the working tree is moved
/// into `modules/` first, as git does.
pub fn deinit(gpa: Allocator, io: Io, repo: *Repository, options: DeinitOptions) Self.Error!DeinitOutcome {
    var outcome: DeinitOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, options.paths);
    defer listing.deinit();
    const head_tree = try repo.headTree(io);

    for (listing.entries) |entry| {
        const module = entry.module orelse continue;
        try validatePath(io, wt, entry.path, entry.path, options.refusal, repo.settings().protect);

        const on_disk = try fs.statAt(io, wt, entry.path);
        if (on_disk != null and on_disk.?.kind == .directory) {
            const dot_git = try arena.print("{s}/.git", .{entry.path});
            if (try fs.statAt(io, wt, dot_git)) |git_entry| {
                if (git_entry.kind == .directory) {
                    try relocate(arena, io, repo, module, entry.path, entry.path, options.refusal);
                    outcome.absorbed += 1;
                }
            }
            if (!options.force) {
                if (try hasLocalChanges(gpa, io, repo, entry, head_tree, options.open)) {
                    return refuse(options.refusal, entry.path, "", error.LocalModifications);
                }
            }
            try wt.deleteTree(io, entry.path);
            outcome.cleared += 1;
            const where = try moduleDir(arena, io, repo, module.name, entry.path, options.refusal);
            var module_dir = where.base.openDir(io, where.path, .{}) catch null;
            if (module_dir) |*dir| {
                defer dir.close(io);
                if (try discover.directory.isGitDirectory(io, dir.*)) try setCoreWorktree(io, repo, dir.*, null);
            }
        }
        wt.createDirPath(io, entry.path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
        const written = try repo.writeConfig(io, .local, &.{.{ .remove_section = .{ .section = "submodule", .subsection = module.name } }}, .{});
        if (written.sections_removed != 0) outcome.unregistered += 1;
    }
    return outcome;
}

/// git's `submodule--helper migrate-gitdir-configs`: each repository in
/// `modules/` that no `submodule.<name>.gitdir` names is given one, as
/// `init` gives one, then the format moves to version 1 and
/// `extensions.submodulePathConfig` is turned on. How many were given one.
pub fn migrateGitDirConfigs(gpa: Allocator, io: Io, repo: *Repository) Self.Error!usize {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var edits: LocalEdits = .{ .arena = arena };
    var migrated: usize = 0;
    if (repo.gitDirectory().get().openDir(io, "modules", .{ .iterate = true })) |modules_const| {
        var modules = modules_const;
        defer modules.close(io);
        var it = modules.iterate();
        while (try it.next(io)) |entry| {
            var dir = modules.openDir(io, entry.name, .{}) catch continue;
            defer dir.close(io);
            if (!try discover.directory.isGitDirectory(io, dir)) continue;
            if (repo.configuration().get(try configKey(arena, entry.name, "gitdir")) != null) continue;
            try setDefaultGitDir(arena, io, repo, try arena.dupe(u8, entry.name), &edits);
            migrated += 1;
        }
    } else |_| {}
    const version = try repo.configuration().getInt(c_int, "core.repositoryformatversion", 0);
    if (version == 0) try edits.set("core.repositoryformatversion", "1");
    try edits.set("extensions.submodulePathConfig", "true");
    try edits.commit(io, repo);
    return migrated;
}

/// Where a submodule's repository lives, as git's `submodule_name_to_gitdir`
/// has it: `modules/<name>` in the superproject's git directory, or under
/// `extensions.submodulePathConfig` the path `submodule.<name>.gitdir`
/// names -- from the top of the working tree, as git writes it, unless
/// absolute. Checked as git checks it each time.
const ModuleDir = struct {
    base: Io.Dir,
    path: []const u8,

    fn absolute(m: ModuleDir, arena: Allocator, io: Io) Error![]const u8 {
        if (std.Io.Dir.path.isAbsolute(m.path)) return m.path;
        const base = try fs.realPathAlloc(arena, io, m.base, ".");
        return arena.print("{s}/{s}", .{ base, m.path });
    }
};

fn moduleDir(arena: Allocator, io: Io, repo: *Repository, name: []const u8, display: []const u8, refusal: ?*Refusal) Error!ModuleDir {
    if (!repo.submodulePathConfig()) {
        try validateGitDir(arena, io, repo.gitDirectory().get(), name, display, refusal);
        return .{ .base = repo.gitDirectory().get(), .path = try arena.print("modules/{s}", .{name}) };
    }
    const value = repo.configuration().get(try configKey(arena, name, "gitdir")) orelse
        return refuse(refusal, display, try configKey(arena, name, "gitdir"), error.NoSubmoduleGitDir);
    const found: ModuleDir = if (std.Io.Dir.path.isAbsolute(value))
        .{ .base = Io.Dir.cwd(), .path = value }
    else
        .{ .base = repo.topDirectory().get(), .path = value };
    if (!try encodedGitDirOk(arena, io, repo, found, name)) return refuse(refusal, display, value, error.GitDirInsideGitDir);
    return found;
}

/// git's `validate_submodule_encoded_git_dir`: the last name after a
/// `/modules/` holds no slash, no other submodule's `gitdir` is the same
/// repository, and under `core.ignoreCase` no name beside it differs only in
/// case.
fn encodedGitDirOk(arena: Allocator, io: Io, repo: *Repository, dir: ModuleDir, name: []const u8) Error!bool {
    const marker = "/modules/";
    const at = std.mem.findLast(u8, dir.path, marker) orelse return false;
    const last = dir.path[at + marker.len ..];
    if (std.mem.findScalar(u8, last, '/') != null) return false;
    const is_git_dir = if (dir.base.openDir(io, dir.path, .{})) |d_const| blk: {
        var d = d_const;
        defer d.close(io);
        break :blk try discover.directory.isGitDirectory(io, d);
    } else |_| false;
    if (is_git_dir) {
        // `submodule_conflicts_with_existing`.
        const mine = try dir.absolute(arena, io);
        for (repo.configuration().entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "submodule") or !std.ascii.eqlIgnoreCase(entry.name, "gitdir")) continue;
            if (std.mem.eql(u8, entry.subsection, name)) continue;
            const value = entry.value orelse continue;
            const theirs: ModuleDir = if (std.Io.Dir.path.isAbsolute(value)) .{ .base = Io.Dir.cwd(), .path = value } else .{ .base = repo.topDirectory().get(), .path = value };
            if (std.mem.eql(u8, mine, try theirs.absolute(arena, io))) return false;
        }
    }
    if (repo.settings().ignore_case) {
        // `check_casefolding_conflict`.
        const parent = std.Io.Dir.path.dirnamePosix(dir.path) orelse return true;
        var modules = dir.base.openDir(io, parent, .{ .iterate = true }) catch return true;
        defer modules.close(io);
        const suffixes_match = std.mem.eql(u8, last, name);
        var it = modules.iterate();
        while (try it.next(io)) |entry| {
            if ((suffixes_match or is_git_dir) and std.ascii.eqlIgnoreCase(entry.name, name) and !std.mem.eql(u8, entry.name, name)) return false;
        }
    }
    return true;
}

/// git's `create_default_gitdir_config`, under
/// `extensions.submodulePathConfig`: `submodule.<name>.gitdir` set, unless it
/// is, to the first of `modules/<name>`, the name percent-encoded as RFC
/// 3986 allows, then with its capitals encoded too, then either with a
/// digit after, then the name's blob hash, that passes git's check.
fn setDefaultGitDir(arena: Allocator, io: Io, repo: *Repository, name: []const u8, edits: *LocalEdits) Error!void {
    const key = try configKey(arena, name, "gitdir");
    if (repo.configuration().get(key) != null) return;
    const git_dir = try gitDirText(arena, io, repo);
    var candidates: std.ArrayList([]const u8) = .empty;
    try candidates.append(arena, name);
    const encoded = try percentEncoded(arena, name, false);
    const folded = try percentEncoded(arena, name, true);
    try candidates.appendSlice(arena, &.{ encoded, folded });
    for ('0'..'9' + 1) |digit| {
        const c: u8 = @intCast(digit);
        try candidates.appendSlice(arena, &.{ try arena.print("{s}{c}", .{ encoded, c }), try arena.print("{s}{c}", .{ folded, c }) });
    }
    var hasher: hash.Hasher = .init(repo.objectFormat());
    hasher.update(try arena.print("blob {d}\x00", .{name.len}));
    hasher.update(name);
    var hex: [hash.max_hex_len]u8 = undefined;
    try candidates.append(arena, try arena.dupe(u8, hasher.final().hex(&hex)));
    for (candidates.items) |candidate| {
        const path = try arena.print("{s}/modules/{s}", .{ git_dir, candidate });
        const dir: ModuleDir = if (std.Io.Dir.path.isAbsolute(path)) .{ .base = Io.Dir.cwd(), .path = path } else .{ .base = repo.topDirectory().get(), .path = path };
        // git checks each as `validate_submodule_git_dir` does: before the
        // extension is on, as a migration runs, the plain name alone.
        if (repo.submodulePathConfig()) {
            if (!try encodedGitDirOk(arena, io, repo, dir, name)) continue;
        } else {
            validateGitDir(arena, io, repo.gitDirectory().get(), name, name, null) catch |err| switch (err) {
                error.GitDirInsideGitDir => return error.NoSubmoduleGitDir,
                else => |e| return e,
            };
        }
        return edits.set(key, path);
    }
    return error.NoSubmoduleGitDir;
}

/// The superproject's git directory as git names it from the top of its
/// working tree: `.git` where it is there, its absolute path otherwise.
fn gitDirText(arena: Allocator, io: Io, repo: *Repository) Error![]const u8 {
    const git_dir = try fs.realPathAlloc(arena, io, repo.gitDirectory().get(), ".");
    const top = try fs.realPathAlloc(arena, io, repo.topDirectory().get(), ".");
    const local = try arena.print("{s}/.git", .{top});
    return if (std.mem.eql(u8, git_dir, local)) ".git" else git_dir;
}

/// `strbuf_addstr_urlencode` with git's `is_rfc3986_unreserved`, or with
/// `fold` its `is_casefolding_rfc3986_unreserved`, which encodes capitals.
fn percentEncoded(arena: Allocator, name: []const u8, fold: bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        const kept = (std.ascii.isLower(c) or std.ascii.isDigit(c) or (!fold and std.ascii.isUpper(c))) or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (kept) try out.append(arena, c) else try out.print(arena, "%{x:0>2}", .{c});
    }
    return out.items;
}

/// What `git rm -n` refuses a submodule for: a staged gitlink change, a
/// `HEAD` other than the recorded commit, modified content, or untracked
/// files.
fn hasLocalChanges(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    entry: Entry,
    head_tree: ?Oid,
    open: Repository.OpenOptions,
) Error!bool {
    const recorded = entry.recorded orelse return true;
    const in_head = if (head_tree) |tree| try lookupPath(io, repo, tree, entry.path) else null;
    if (in_head == null or !in_head.?.eql(recorded)) return true;
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    var found = (try gitlink.open(gpa, io, wt, entry.path)) orelse return false;
    found.deinit(io);
    var sub = try openSubmodule(gpa, io, repo, entry.path, open);
    defer sub.deinit(io);
    var failure: ?StatusProbe.Failure = null;
    const state = try inspectRepository(gpa, io, &sub, recorded, .none, .{ .open = open }, 1, &failure);
    return !state.isClean();
}

/// The object a tree records at `path`, or `null`.
fn lookupPath(io: Io, repo: *Repository, tree: Oid, path: []const u8) Error!?Oid {
    var current = tree;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        const found = try repo.objectDatabase().read(io, current);
        defer repo.allocator().free(found.bytes);
        if (found.type != .tree) return null;
        const parsed: object.Tree = .parse(repo.objectFormat(), found.bytes);
        const entry = (try parsed.find(part)) orelse return null;
        current = entry.oid;
    }
    return current;
}

//=========================================================================
// git submodule absorbgitdirs
//=========================================================================

/// How `absorbGitDirs` behaves.
pub const AbsorbOptions = struct {
    /// Which submodules; see `list`.
    paths: ?[]const []const u8 = null,
    /// What each submodule's repository is opened with.
    open: Repository.OpenOptions = .{},
    refusal: ?*Refusal = null,
};

/// What `absorbGitDirs` did.
pub const AbsorbOutcome = struct {
    /// `.git` directories moved into `modules/<name>`.
    moved: u32 = 0,
    /// `.git` files pointed back at `modules/<name>` after the directory
    /// they named moved away with the submodule above them.
    reconnected: u32 = 0,
};

/// `git submodule absorbgitdirs`: move each submodule's `.git` directory
/// into `modules/<name>` in the superproject's git directory, and leave
/// a `.git` file behind that names it. Every populated submodule is then
/// absorbed into in turn, so nested ones land in
/// `modules/<outer>/modules/<inner>`; a nested `.git` file left pointing at
/// where its parent's directory used to be is pointed at where it went.
pub fn absorbGitDirs(gpa: Allocator, io: Io, repo: *Repository, options: AbsorbOptions) Self.Error!AbsorbOutcome {
    var outcome: AbsorbOutcome = .{};
    try absorbIn(gpa, io, repo, options, options.paths, "", 0, &outcome);
    return outcome;
}

fn absorbIn(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    options: AbsorbOptions,
    paths: ?[]const []const u8,
    prefix: []const u8,
    depth: u32,
    outcome: *AbsorbOutcome,
) Error!void {
    if (depth > max_depth) return refuse(options.refusal, prefix, "", error.NestingTooDeep);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, paths);
    defer listing.deinit();

    for (listing.entries) |entry| {
        const display = try join(arena, prefix, entry.path);
        try validatePath(io, wt, entry.path, display, options.refusal, repo.settings().protect);
        const dot_git = try arena.print("{s}/.git", .{entry.path});
        const git_entry = (try fs.statAt(io, wt, dot_git)) orelse continue;

        if (git_entry.kind == .directory) {
            const module = entry.module orelse return refuse(options.refusal, display, "", error.NoSubmoduleMapping);
            try relocate(arena, io, repo, module, entry.path, display, options.refusal);
            outcome.moved += 1;
        } else if (try gitlink.open(gpa, io, wt, entry.path)) |found_const| {
            var found = found_const;
            found.deinit(io);
        } else {
            // A `.git` file naming nothing: the directory it named moved
            // with the submodule this one lives in.
            const module = entry.module orelse return refuse(options.refusal, display, "", error.NoSubmoduleMapping);
            const where = try moduleDir(arena, io, repo, module.name, display, options.refusal);
            var module_dir = where.base.openDir(io, where.path, .{}) catch continue;
            defer module_dir.close(io);
            if (!try discover.directory.isGitDirectory(io, module_dir)) continue;
            var work = try wt.openDir(io, entry.path, .{});
            defer work.close(io);
            try connect(arena, io, repo, work, try fs.realPathAlloc(arena, io, work, "."), module_dir, try fs.realPathAlloc(arena, io, module_dir, "."));
            outcome.reconnected += 1;
        }

        var sub = try openSubmodule(gpa, io, repo, entry.path, options.open);
        defer sub.deinit(io);
        try absorbIn(gpa, io, &sub, options, null, try arena.print("{s}/", .{display}), depth + 1, outcome);
    }
}

/// Move `<path>/.git` to `modules/<name>` and connect the two.
fn relocate(
    arena: Allocator,
    io: Io,
    repo: *Repository,
    module: *const gitmodules.Submodule,
    path: []const u8,
    display: []const u8,
    refusal: ?*Refusal,
) Error!void {
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    const dot_git = try arena.print("{s}/.git", .{path});
    if (wt.openDir(io, try arena.print("{s}/worktrees", .{dot_git}), .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var it = dir.iterate();
        if (try it.next(io) != null) return refuse(refusal, display, "", error.SubmoduleHasWorktrees);
    } else |_| {}
    const where = try moduleDir(arena, io, repo, module.name, display, refusal);
    const target = where.path;
    if (try fs.statAt(io, where.base, target) != null) return refuse(refusal, display, target, error.GitDirExists);
    if (std.Io.Dir.path.dirnamePosix(target)) |parent| try fs.makeDirs(io, where.base, parent, repo.sharedPermissions());
    try wt.rename(dot_git, where.base, target, io);

    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    var module_dir = try where.base.openDir(io, target, .{});
    defer module_dir.close(io);
    try connect(arena, io, repo, work, try fs.realPathAlloc(arena, io, work, "."), module_dir, try fs.realPathAlloc(arena, io, module_dir, "."));
}

//=========================================================================
// What git rm and git mv do to a submodule
//=========================================================================

/// Whether `.gitmodules` in the working tree holds what the index does, so
/// an edit to it can be staged without taking other changes along: git's
/// `is_staging_gitmodules_ok`. No file, or no entry for one, is fine.
pub fn gitmodulesStaged(gpa: Allocator, io: Io, repo: *Repository, index: *const Index) Self.Error!bool {
    const wt = (repo.workDirectory() orelse return true).get();
    const entry = index.find(".gitmodules") orelse return true;
    return !try worktree.differsFromIndex(gpa, io, wt, .{ .index = index, .entry = entry.* }, try repo.worktreeRules());
}

/// Take the `submodule.<name>` section whose path is `path` out of
/// `.gitmodules`: git's `remove_path_from_gitmodules`. Whether it went; with
/// no file, or no section for the path, nothing changes.
pub fn removeFromGitmodules(gpa: Allocator, io: Io, repo: *Repository, index: *const Index, path: []const u8) Self.Error!bool {
    var modules = (try gitmodulesToEdit(gpa, io, repo, index)) orelse return false;
    defer modules.deinit();
    const module = modules.byPath(path) orelse return false;
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    const written = try repo.writeConfigFile(io, wt, ".gitmodules", &.{.{ .remove_section = .{ .section = "submodule", .subsection = module.name } }});
    return written.sections_removed != 0;
}

/// A submodule's path before and after a move.
pub const PathMove = struct { old: []const u8, new: []const u8 };

/// Point the `.gitmodules` section whose path is `move.old` at `move.new`:
/// git's `update_path_in_gitmodules`. Whether it did; with no file, or no
/// section for the path, nothing changes.
pub fn moveInGitmodules(gpa: Allocator, io: Io, repo: *Repository, index: *const Index, move: PathMove) Self.Error!bool {
    var modules = (try gitmodulesToEdit(gpa, io, repo, index)) orelse return false;
    defer modules.deinit();
    const module = modules.byPath(move.old) orelse return false;
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    const key = try std.mem.concat(gpa, u8, &.{ "submodule.", module.name, ".path" });
    defer gpa.free(key);
    _ = try repo.writeConfigFile(io, wt, ".gitmodules", &.{.{ .set = .{ .name = key, .value = move.new } }});
    return true;
}

/// `.gitmodules` as an edit to it reads it, or `null` when the working tree
/// has none.
fn gitmodulesToEdit(gpa: Allocator, io: Io, repo: *Repository, index: *const Index) Error!?Gitmodules {
    const wt = (repo.workDirectory() orelse return null).get();
    if (try fs.statAt(io, wt, ".gitmodules") == null) return null;
    if (isUnmerged(index, ".gitmodules")) return error.GitmodulesUnmerged;
    return try loadGitmodules(gpa, io, repo, index);
}

/// The git directory the `.git` file in the submodule at `path` names, as
/// an absolute path in `arena`; `null` when `<path>/.git` is not a `.git`
/// file, a directory among them. git's `read_gitfile`, which `mv` asks
/// before the working tree moves and the file's relative path with it.
pub fn gitDirOf(arena: Allocator, io: Io, repo: *Repository, path: []const u8) Self.Error!?[]const u8 {
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    const named = (try gitfile.read(arena, io, work, ".git")) orelse return null;
    var git_dir = try gitfile.open(io, work, named, .{});
    defer git_dir.deinit(io);
    return try fs.realPathAlloc(arena, io, git_dir.lend().get(), ".");
}

/// Connect the working tree at `path` and the git directory `git_dir`, an
/// absolute path, to each other, then each active submodule inside it to
/// its own: git's `connect_work_tree_and_git_dir` after a move.
pub fn connectGitDir(gpa: Allocator, io: Io, repo: *Repository, path: []const u8, git_dir: []const u8) Self.Error!void {
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    try connectAt(gpa, io, repo, wt, path, git_dir, 0);
}

fn connectAt(gpa: Allocator, io: Io, repo: *Repository, wt: Io.Dir, path: []const u8, git_dir: []const u8, depth: u32) Error!void {
    if (depth > max_depth) return error.NestingTooDeep;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // Both made if they are not there, as git's are.
    try fs.makeDirs(io, wt, path, repo.sharedPermissions());
    try fs.makeDirs(io, Io.Dir.cwd(), git_dir, repo.sharedPermissions());
    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    var module_dir = try Io.Dir.openDirAbsolute(io, git_dir, .{});
    defer module_dir.close(io);
    try connect(arena, io, repo, work, try fs.realPathAlloc(arena, io, work, "."), module_dir, try fs.realPathAlloc(arena, io, module_dir, "."));

    // `connect_wt_gitdir_in_nested`: a working tree no repository opens at
    // has nothing nested to connect.
    var sub = openSubmodule(gpa, io, repo, path, .{}) catch return;
    defer sub.deinit(io);
    const sub_wt = (sub.workDirectory() orelse return).get();
    var index = try sub.openIndex(io);
    defer index.deinit();
    var modules = try loadGitmodules(gpa, io, &sub, &index);
    defer modules.deinit();
    for (index.items(), 0..) |entry, i| {
        if (entry.mode != .gitlink) continue;
        if (i > 0 and std.mem.eql(u8, index.items()[i - 1].path, entry.path)) continue;
        const module = modules.byPath(entry.path) orelse continue;
        if (!try isActive(arena, &sub, module.name, entry.path)) continue;
        const nested = try (try moduleDir(arena, io, &sub, module.name, entry.path, null)).absolute(arena, io);
        try connectAt(gpa, io, &sub, sub_wt, entry.path, nested, depth + 1);
    }
}

//=========================================================================
// git submodule update
//=========================================================================

/// What `update` asks for when a submodule's repository or commit is not on
/// the disk. The wire protocol is not this module's; a caller that has one
/// hands it in here.
pub const Transport = struct {
    context: *anyopaque,
    /// Fill `request.git_dir`, an empty directory, with the repository at
    /// `request.url`, the way `git clone --no-checkout --separate-git-dir`
    /// leaves one: a non-bare repository with its objects, its refs, `HEAD`
    /// on the default branch, and `remote.origin` configured. `update`
    /// writes the `.git` file and `core.worktree` itself, and checks out
    /// the commit.
    cloneFn: *const fn (gpa: Allocator, io: Io, context: *anyopaque, request: CloneRequest) TransportError!void,
    /// Bring `want` into `repo`, a submodule's repository, from `remote`,
    /// its default remote — what git's fetch inside the submodule does.
    fetchFn: *const fn (gpa: Allocator, io: Io, context: *anyopaque, repo: *Repository, remote: []const u8, want: Oid) TransportError!void,
    /// Bring `oids`, which `repo` -- a submodule's repository that is a
    /// partial clone -- was promised, from its promisor remotes: what git's
    /// lazy fetch does when a checkout reads one. `update` has every read
    /// of a missing object in such a submodule ask; `null` leaves it
    /// missing.
    fetchPromisedFn: ?*const fn (gpa: Allocator, io: Io, context: *anyopaque, repo: *Repository, oids: []const Oid) TransportError!void = null,
};

/// A submodule's reads of what it was promised, sent to the transport
/// while `update` has its repository open.
const Promised = struct {
    gpa: Allocator,
    repo: *Repository,
    transport: Transport,

    /// Install on `repo` when it is a partial clone and `transport` fetches
    /// what is promised.
    fn install(p: *Promised, arena: Allocator) Allocator.Error!void {
        if (p.transport.fetchPromisedFn == null) return;
        if ((try promisors.remotes(arena, p.repo.configuration())).len == 0) return;
        p.repo.objectDatabase().lazy = .{ .context = p, .fetch = fetch };
    }

    fn uninstall(p: *Promised) void {
        if (p.repo.objectDatabase().lazy) |lazy| if (lazy.context == @as(*anyopaque, p)) {
            p.repo.objectDatabase().lazy = null;
        };
    }

    fn fetch(io: Io, context: *anyopaque, oids: []const Oid) (Allocator.Error || Io.Cancelable || error{PromisorFetchFailed})!void {
        const p: *Promised = @ptrCast(@alignCast(context)); // aegis: no-danger: the context handed out with this function is a Promised
        p.transport.fetchPromisedFn.?(p.gpa, io, p.transport.context, p.repo, oids) catch |err| return switch (err) {
            error.TransportFailed => error.PromisorFetchFailed,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
        };
    }
};

/// What `Transport.cloneFn` is asked to clone.
pub const CloneRequest = struct {
    url: []const u8,
    git_dir: Io.Dir,
    /// The submodule's name and the repository it is a submodule of, whose
    /// `submodule.alternateLocation` and lenders the clone may borrow from;
    /// `null` for a clone that borrows nothing.
    within: ?Within = null,

    pub const Within = struct { name: []const u8, superproject: *Repository };
};

/// Errors a `Transport` may give. Its own detail is its to keep.
pub const TransportError = error{TransportFailed} || Allocator.Error || Io.Cancelable;

/// How `update` behaves.
pub const UpdateOptions = struct {
    /// Which submodules; see `list`.
    paths: ?[]const []const u8 = null,
    /// `--init`: `init` the same submodules first.
    init: bool = false,
    /// `--recursive`: the submodules of each updated submodule too, with the
    /// same options.
    recursive: bool = false,
    /// `--force`: check out even where `HEAD` already is the commit, and
    /// discard local changes in the way.
    force: bool = false,
    /// `--checkout`, `--merge`, `--rebase` or `--no-...`: beats the
    /// configured strategy.
    strategy: ?gitmodules.Update = null,
    /// Who the line appended to each submodule's `HEAD` log says moved it.
    /// No line is written without one, because this package reads no clock
    /// and no identity.
    who: ?object.Signature = null,
    /// Where a missing repository or commit comes from. Without one they
    /// are `error.NotCloned` and `error.CommitMissing`.
    transport: ?Transport = null,
    /// The permission to run a `!command` update. Without it one is
    /// `error.UpdateCommandRefused`.
    programs: ?program.Programs = null,
    /// What each submodule's repository is opened with.
    open: Repository.OpenOptions = .{},
    refusal: ?*Refusal = null,
};

/// What `update` did.
pub const UpdateOutcome = struct {
    /// Submodules brought to their recorded commit.
    updated: u32 = 0,
    /// Submodules already at it.
    unchanged: u32 = 0,
    /// Working trees connected to a repository that was already in
    /// `modules/<name>`, as after a `deinitialize`.
    reconnected: u32 = 0,
    /// Repositories the transport cloned.
    cloned: u32 = 0,
    /// Submodules skipped: unmerged, not in `.gitmodules`, not active, or
    /// with the strategy `none`.
    skipped: u32 = 0,
};

/// `git submodule update`: bring each active submodule to the commit its
/// superproject records.
///
/// A submodule with no working tree is connected to its repository in
/// `modules/<name>` when that is on the disk, and cloned through the
/// transport when it is not. The `checkout` strategy detaches `HEAD` at the
/// commit and checks its tree out; without `force` a submodule with
/// modified tracked content is refused rather than having it carried over,
/// which is stricter than git, which carries over what it can. `merge` and
/// `rebase` are refused by name. A `!command` from the repository's own
/// configuration runs with `programs`, in the submodule, with the commit as
/// its argument, as git runs it.
pub fn update(gpa: Allocator, io: Io, repo: *Repository, options: UpdateOptions) Self.Error!UpdateOutcome {
    var outcome: UpdateOutcome = .{};
    try updateIn(gpa, io, repo, options, options.paths, "", 0, &outcome);
    return outcome;
}

fn updateIn(
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    options: UpdateOptions,
    paths: ?[]const []const u8,
    prefix: []const u8,
    depth: u32,
    outcome: *UpdateOutcome,
) Error!void {
    if (depth > max_depth) return refuse(options.refusal, prefix, "", error.NestingTooDeep);
    if (options.init) _ = try init(gpa, io, repo, .{ .paths = paths, .refusal = options.refusal });

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, paths);
    defer listing.deinit();

    for (listing.entries) |entry| {
        const display = try join(arena, prefix, entry.path);
        const recorded = entry.recorded orelse {
            outcome.skipped += 1;
            continue;
        };
        const module = entry.module orelse {
            outcome.skipped += 1;
            continue;
        };
        const update_key = try configKey(arena, module.name, "update");
        const configured: ?gitmodules.Update = if (try configString(arena, repo.configuration(), update_key)) |text|
            gitmodules.Update.parse(text) orelse return refuse(options.refusal, display, text, error.InvalidUpdate)
        else
            module.update;
        const skip_none = if (options.strategy) |s| s == .none else (configured != null and configured.? == .none);
        if (skip_none or !try isActive(arena, repo, module.name, entry.path)) {
            outcome.skipped += 1;
            continue;
        }
        const url = try resolvedUrl(arena, io, repo, module, display, options.refusal);
        try validatePath(io, wt, entry.path, display, options.refusal, repo.settings().protect);
        try validateGitDir(arena, io, repo.gitDirectory().get(), module.name, display, options.refusal);

        const dot_git = try arena.print("{s}/.git", .{entry.path});
        const just_cloned = try fs.statAt(io, wt, dot_git) == null;
        if (just_cloned) {
            try populate(arena, gpa, io, repo, module, entry.path, url, display, options, outcome);
        } else {
            try correctCoreWorktree(arena, gpa, io, repo, wt, entry.path);
        }

        var sub = try openSubmodule(gpa, io, repo, entry.path, options.open);
        defer sub.deinit(io);
        var promised: ?Promised = if (options.transport) |t| .{ .gpa = gpa, .repo = &sub, .transport = t } else null;
        if (promised) |*p| try p.install(arena);
        defer if (promised) |*p| p.uninstall();

        var strategy: gitmodules.Update = options.strategy orelse configured orelse .checkout;
        if (just_cloned) switch (strategy) {
            .merge, .rebase, .none => strategy = .checkout,
            else => {},
        };
        const current: ?Oid = if (just_cloned)
            null
        else
            (try headOf(gpa, io, &sub)) orelse return refuse(options.refusal, display, "HEAD", error.NoCurrentRevision);

        if (current == null or !current.?.eql(recorded) or options.force) {
            try ensureCommit(arena, gpa, io, repo, &sub, module, recorded, display, options);
            switch (strategy) {
                .checkout => try checkoutCommit(arena, gpa, io, &sub, recorded, current == null or options.force, display, options),
                .merge, .rebase => return refuse(options.refusal, display, strategy.name(), error.UnsupportedUpdate),
                .command => |command| try runUpdateCommand(arena, gpa, io, &sub, command, recorded, display, update_key, options),
                .none => {
                    outcome.skipped += 1;
                    continue;
                },
            }
            outcome.updated += 1;
        } else {
            outcome.unchanged += 1;
        }

        if (options.recursive) {
            try updateIn(gpa, io, &sub, options, null, try arena.print("{s}/", .{display}), depth + 1, outcome);
        }
    }
}

/// Give a submodule with no working tree its repository: the one already
/// in `modules/<name>`, with its stale index removed as git removes it, or
/// one the transport clones there.
fn populate(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    module: *const gitmodules.Submodule,
    path: []const u8,
    url: []const u8,
    display: []const u8,
    options: UpdateOptions,
    outcome: *UpdateOutcome,
) Error!void {
    const wt = (repo.workDirectory() orelse return error.BareRepository).get();
    const where = try moduleDir(arena, io, repo, module.name, display, options.refusal);
    const target = where.path;
    var module_dir: Io.Dir = blk: {
        if (where.base.openDir(io, target, .{})) |dir| {
            const is_git = discover.directory.isGitDirectory(io, dir) catch |err| {
                dir.close(io);
                return err;
            };
            if (is_git) {
                dir.deleteFile(io, "index") catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| {
                        dir.close(io);
                        return e;
                    },
                };
                outcome.reconnected += 1;
                break :blk dir;
            }
            dir.close(io);
        } else |err| if (err == error.Canceled) return error.Canceled;
        const transport = options.transport orelse return refuse(options.refusal, display, url, error.NotCloned);
        if (!try gitmodules.checkUrl(gpa, url)) return refuse(options.refusal, display, url, error.DisallowedUrl);
        // git's `clone_submodule` under `--init`: a path that is there and
        // is not an empty directory is not cloned into.
        if (options.init and !try emptyOrAbsent(io, wt, path)) return refuse(options.refusal, display, url, error.DirectoryNotEmpty);
        try fs.makeDirs(io, where.base, target, repo.sharedPermissions());
        const dir = try where.base.openDir(io, target, .{ .iterate = true });
        errdefer dir.close(io);
        transport.cloneFn(gpa, io, transport.context, .{ .url = url, .git_dir = dir, .within = .{ .name = module.name, .superproject = repo } }) catch |err| switch (err) {
            error.TransportFailed => return refuse(options.refusal, display, url, error.TransportFailed),
            else => |e| return e,
        };
        if (!try discover.directory.isGitDirectory(io, dir)) return refuse(options.refusal, display, url, error.TransportFailed);
        outcome.cloned += 1;
        break :blk dir;
    };
    defer module_dir.close(io);

    try wt.createDirPath(io, path);
    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    try connect(arena, io, repo, work, try fs.realPathAlloc(arena, io, work, "."), module_dir, try fs.realPathAlloc(arena, io, module_dir, "."));
}

/// Whether `path` is not there, or is a directory with nothing in it.
fn emptyOrAbsent(io: Io, wt: Io.Dir, path: []const u8) Error!bool {
    const st = wt.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => |e| return e,
    };
    if (st.kind != .directory) return false;
    var dir = try wt.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    return try it.next(io) == null;
}

/// git's `ensure_core_worktree`: a `core.worktree` a submodule's
/// repository already carries is rewritten to point at where the working
/// tree is now, which is what keeps a superproject's worktrees sharing one
/// repository per submodule working.
fn correctCoreWorktree(arena: Allocator, gpa: Allocator, io: Io, repo: *const Repository, wt: Io.Dir, path: []const u8) Error!void {
    var found = (try gitlink.open(gpa, io, wt, path)) orelse return;
    defer found.deinit(io);
    var config = try config_mod.Config.openFile(gpa, io, .{ .dir = found.commonDirectory().get(), .sub_path = "config" }, .local, .{});
    defer config.deinit();
    if (config.get("core.worktree") == null) return;
    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    const wanted = try relativePath(arena, try fs.realPathAlloc(arena, io, work, "."), try fs.realPathAlloc(arena, io, found.gitDirectory().get(), "."));
    const now = try configString(arena, &config, "core.worktree");
    if (now != null and std.mem.eql(u8, now.?, wanted)) return;
    try setCoreWorktree(io, repo, found.commonDirectory().get(), wanted);
}

/// Make sure the submodule's repository has `commit`, fetching it through
/// the transport when there is one.
fn ensureCommit(arena: Allocator, gpa: Allocator, io: Io, repo: *Repository, sub: *Repository, module: *const gitmodules.Submodule, commit: Oid, display: []const u8, options: UpdateOptions) Error!void {
    if (try sub.objectDatabase().exists(io, commit)) return;
    var hex: [hash.max_hex_len]u8 = undefined;
    const transport = options.transport orelse return refuse(options.refusal, display, commit.hex(&hex), error.CommitMissing);
    const remote = try moduleRemote(arena, io, repo, sub, module);
    transport.fetchFn(gpa, io, transport.context, sub, remote, commit) catch |err| switch (err) {
        error.TransportFailed => return refuse(options.refusal, display, remote, error.TransportFailed),
        else => |e| return e,
    };
    try sub.objectDatabase().refresh(io);
    if (!try sub.objectDatabase().exists(io, commit)) return refuse(options.refusal, display, commit.hex(&hex), error.CommitMissing);
}

/// `git checkout -q [-f] <commit>` inside the submodule: its index and
/// working tree become the commit's tree and its `HEAD` is detached there.
fn checkoutCommit(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    sub: *Repository,
    commit: Oid,
    force: bool,
    display: []const u8,
    options: UpdateOptions,
) Error!void {
    const work = (sub.workDirectory() orelse return error.BareRepository).get();
    const tree = try sub.commitTree(io, commit);
    var locked_index = try sub.lockIndex(io);
    defer locked_index.deinit(io);
    const index = &locked_index.index;
    var ignore_rules = try sub.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try sub.loadAttrs(io);
    defer attrs.deinit();
    const required = try sub.requiredFilters(gpa);
    defer gpa.free(required);
    var rules = try sub.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.required_filters = required;

    if (!force) {
        var current = try worktree.status(gpa, io, work, .{ .index = index, .db = sub.objectDatabase() }, .{
            .rules = rules,
            .head_tree = try sub.headTree(io),
            .untracked = .no,
        });
        defer current.deinit();
        for (current.entries) |entry| {
            // A submodule of the submodule is not checked out with it, so
            // its state is not a change in the way.
            if (entry.submodule != null and entry.staged == .unmodified and !entry.conflicted) continue;
            if (entry.unstaged == .untracked or entry.unstaged == .ignored) continue;
            return refuse(options.refusal, display, entry.path, error.LocalModifications);
        }
    }

    var refusal: worktree.Refusal = .{};
    // `git checkout`, or with `--force` `git checkout -f`, as git's
    // submodule update runs it.
    _ = worktree.checkout(gpa, io, work, .{ .index = index, .db = sub.objectDatabase(), .tree = tree }, .{ .rules = rules, .refusal = &refusal, .force = force }) catch |err| switch (err) {
        error.UnsafePath => return refuse(options.refusal, display, refusal.path(), error.UnsafePath),
        else => |e| return e,
    };
    try locked_index.commit(io);

    var hex: [hash.max_hex_len]u8 = undefined;
    var from_hex: [hash.max_hex_len]u8 = undefined;
    const from: []const u8 = if (try sub.refStore().currentBranch(arena, io)) |branch|
        branch
    else if (try headOf(gpa, io, sub)) |old|
        try arena.dupe(u8, old.hex(&from_hex))
    else
        "HEAD";
    var tx = sub.beginRefs();
    defer tx.deinit(io);
    // A submodule is left on a detached `HEAD`, as `git submodule update`
    // leaves it, not with its branch moved.
    try tx.change("HEAD", .{ .direct = commit }, .any, .{ .no_deref = true });
    const log: ?refs_mod.LogMessage = if (options.who) |who| .{
        .who = who,
        .message = try arena.print("checkout: moving from {s} to {s}", .{ from, commit.hex(&hex) }),
        .policy = sub.reflogPolicy(),
    } else null;
    try tx.commit(io, log);
}

/// The variables git clears before it runs a program in another
/// repository, so the program sees the submodule and not the superproject.
const local_repo_env = [_][]const u8{
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG",     "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",                          "GIT_WORK_TREE",  "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",                   "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",             "GIT_PREFIX",     "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
};

/// Run a `!command` update: the command split at whitespace, the commit
/// after it, through `sh` as git hands a configured command to it, in the
/// submodule's working tree.
fn runUpdateCommand(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    sub: *Repository,
    command: []const u8,
    commit: Oid,
    display: []const u8,
    setting: []const u8,
    options: UpdateOptions,
) Error!void {
    const programs = options.programs orelse return refuse(options.refusal, display, setting, error.UpdateCommandRefused);
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, command, " \t\n");
    while (words.next()) |word| try argv.append(arena, word);
    var hex: [hash.max_hex_len]u8 = undefined;
    try argv.append(arena, try arena.dupe(u8, commit.hex(&hex)));
    var outcome = try program.run(gpa, io, programs, .{
        .argv = argv.items,
        .shell = true,
        .cwd = .{ .dir = (sub.workDirectory() orelse return error.BareRepository).get() },
        .unset = &local_repo_env,
        .stderr = .inherit,
    }, .{});
    defer outcome.deinit(gpa);
    if (!outcome.succeeded()) return refuse(options.refusal, display, command, error.UpdateCommandFailed);
}

//=========================================================================
// --recurse-submodules
//=========================================================================

/// What a `Mover` moves submodules with.
pub const MoverOptions = struct {
    /// Who the line in each submodule's `HEAD` log says moved it. No line
    /// is written without one, because this package reads no clock and no
    /// identity.
    who: ?object.Signature = null,
    /// What each submodule's repository is opened with.
    open: Repository.OpenOptions = .{},
    /// The permission to run the filters a submodule's files are written
    /// through.
    programs: ?program.Programs = null,
    refusal: ?*Refusal = null,
};

/// Why a `Mover` refused a move: a submodule's reason or its checkout's.
pub const MoveError = Error || three_way.Error;

/// git's `submodule_move_head`: what moves a submodule when a checkout, a
/// reset or a merge under `--recurse-submodules` writes or removes its
/// gitlink. `submodules` is what `worktree.Rules.submodules`,
/// `reset.Options.submodules` and `three_way.Options.submodules` take.
///
/// Only an active submodule moves, and one moved from a commit only where
/// it is populated. Unforced, a submodule whose index has changes staged
/// against its `HEAD` is `error.DirtyIndex`, and its checkout moves as
/// `read-tree -m -u` moves one, refusing to lose its work; forced, as
/// `read-tree --reset -u`. Its `HEAD` is then detached at the new commit;
/// or, when the gitlink goes, its `.git` file goes, its directory once
/// empty, and its repository's `core.worktree`. A `.git` directory in its
/// working tree is absorbed into the superproject's `modules` first. Its
/// own submodules move with it, by a mover of its own.
///
/// A submodule that comes into being is made from its repository in
/// `modules`, which must be there with the commit: git, without one, dies
/// halfway through the checkout; this refuses the move before anything is
/// written, as `error.NotCloned` or `error.CommitMissing`.
pub const Mover = struct {
    gpa: Allocator,
    /// The superproject.
    repo: *Repository,
    /// The superproject's index as the update has it, which `.gitmodules`
    /// is read from where the working tree has none.
    index: *const Index,
    options: MoverOptions = .{},
    /// Where the superproject is, from the top one, `/`-terminated.
    prefix: []const u8 = "",
    depth: u32 = 0,
    /// Why the last refused move was refused. `options.refusal` says which
    /// submodule.
    failure: ?MoveError = null,

    /// What an update moves its submodules with.
    pub fn submodules(m: *Mover) worktree.SubmoduleMover {
        return .{ .context = m, .moveFn = moveFn };
    }

    fn moveFn(io: Io, context: *anyopaque, request: worktree.SubmoduleMove) worktree.Error!void {
        const m: *Mover = @ptrCast(@alignCast(context)); // aegis: no-danger: the context handed out with this function is a Mover
        m.move(io, request) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            // A nested mover's, already recorded here.
            error.SubmoduleNotUpdated => return error.SubmoduleNotUpdated,
            else => |e| {
                m.failure = e;
                return error.SubmoduleNotUpdated;
            },
        };
    }

    fn move(m: *Mover, io: Io, request: worktree.SubmoduleMove) MoveError!void {
        if (m.depth > max_depth) return error.NestingTooDeep;
        var arena_instance: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const repo = m.repo;
        const wt = (repo.workDirectory() orelse return error.BareRepository).get();
        const display = try join(arena, m.prefix, request.path);
        errdefer if (m.options.refusal) |r| {
            if (r.path().len == 0) r.set(display, "");
        };

        var modules = try loadGitmodules(m.gpa, io, repo, m.index);
        defer modules.deinit();
        const module = modules.byPath(request.path) orelse return;
        if (!try isActive(arena, repo, module.name, request.path)) return;
        try validatePath(io, wt, request.path, display, m.options.refusal, repo.settings().protect);
        if (request.from != .none and !try gitlink.isRepository(m.gpa, io, wt, request.path)) return;
        const where = try moduleDir(arena, io, repo, module.name, display, m.options.refusal);
        const target: Target = .{ .request = request, .where = where, .display = display };
        if (request.from == .none) return m.populate(arena, io, target);
        return m.moveFrom(arena, io, target);
    }

    const Target = struct { request: worktree.SubmoduleMove, where: ModuleDir, display: []const u8 };

    /// A populated submodule, moved from its `HEAD` or a recorded commit.
    fn moveFrom(m: *Mover, arena: Allocator, io: Io, target: Target) MoveError!void {
        const request = target.request;
        const wt = m.repo.workDirectory().?.get();
        if (!request.force) {
            var sub = try openSubmodule(m.gpa, io, m.repo, request.path, m.options.open);
            defer sub.deinit(io);
            var index = try sub.openIndex(io);
            defer index.deinit();
            if (try three_way.indexDiffers(arena, io, sub.objectDatabase(), &index, try sub.headTree(io)) != null) {
                if (m.options.refusal) |r| r.set(target.display, "index");
                return error.DirtyIndex;
            }
        }
        if (!request.dry_run) {
            const dot_git = try arena.print("{s}/.git", .{request.path});
            const found = try fs.statAt(io, wt, dot_git);
            if (found != null and found.?.kind == .directory) {
                _ = try absorbGitDirs(m.gpa, io, m.repo, .{ .paths = &.{request.path}, .open = m.options.open, .refusal = m.options.refusal });
            }
            if (request.force) try connectGitDir(m.gpa, io, m.repo, request.path, try target.where.absolute(arena, io));
        }
        var sub = try openSubmodule(m.gpa, io, m.repo, request.path, m.options.open);
        defer sub.deinit(io);
        const from: Oid = switch (request.from) {
            .head => (try headOf(m.gpa, io, &sub)) orelse return refuse(m.options.refusal, target.display, "HEAD", error.NoCurrentRevision),
            .commit => |commit| commit,
            .none => unreachable,
        };
        try m.checkoutIn(arena, io, &sub, from, target);
    }

    /// A submodule coming into being: its working tree connected to its
    /// repository in `modules`, an empty index, and its commit checked
    /// out, as git's `submodule_move_head` with no old head makes one.
    fn populate(m: *Mover, arena: Allocator, io: Io, target: Target) MoveError!void {
        const request = target.request;
        const wt = m.repo.workDirectory().?.get();
        var module_dir = target.where.base.openDir(io, target.where.path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return refuse(m.options.refusal, target.display, target.where.path, error.NotCloned),
            else => |e| return e,
        };
        defer module_dir.close(io);
        if (!try discover.directory.isGitDirectory(io, module_dir)) return refuse(m.options.refusal, target.display, target.where.path, error.NotCloned);
        if (request.dry_run) {
            var sub = try Repository.open(m.gpa, io, module_dir, .{ .discover = false });
            defer sub.deinit(io);
            const to = request.to orelse return;
            var hex: [hash.max_hex_len]u8 = undefined;
            if (!try sub.objectDatabase().exists(io, to)) return refuse(m.options.refusal, target.display, to.hex(&hex), error.CommitMissing);
            return;
        }
        try fs.makeDirs(io, wt, request.path, m.repo.sharedPermissions());
        var work = try wt.openDir(io, request.path, .{});
        defer work.close(io);
        try connect(arena, io, m.repo, work, try fs.realPathAlloc(arena, io, work, "."), module_dir, try fs.realPathAlloc(arena, io, module_dir, "."));
        // git's `submodule_reset_index`: whatever index the repository
        // kept from an earlier checkout is not this one's.
        module_dir.deleteFile(io, "index") catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        var sub = try openSubmodule(m.gpa, io, m.repo, request.path, m.options.open);
        defer sub.deinit(io);
        try m.checkoutIn(arena, io, &sub, null, target);
    }

    /// `read-tree --recurse-submodules` in the submodule, from `from` to
    /// the request's commit, then its `HEAD` detached there, or the
    /// submodule taken away.
    fn checkoutIn(m: *Mover, arena: Allocator, io: Io, sub: *Repository, from: ?Oid, target: Target) MoveError!void {
        const request = target.request;
        var hex: [hash.max_hex_len]u8 = undefined;
        const new_tree: Oid = if (request.to) |to|
            try commitTreeOf(sub, io, to) orelse return refuse(m.options.refusal, target.display, to.hex(&hex), error.CommitMissing)
        else
            sub.objectFormat().emptyTree();
        if (request.force and request.dry_run) return;

        var locked: ?Repository.LockedIndex = if (request.dry_run) null else try sub.lockIndex(io);
        defer if (locked) |*l| l.deinit(io);
        var plain: ?Index = if (request.dry_run) try sub.openIndex(io) else null;
        defer if (plain) |*p| p.deinit();
        const index: *Index = if (locked) |*l| &l.index else &plain.?;

        var nested: Mover = .{
            .gpa = m.gpa,
            .repo = sub,
            .index = index,
            .options = m.options,
            .prefix = try arena.print("{s}/", .{target.display}),
            .depth = m.depth + 1,
        };
        if (request.force) {
            var ignore_rules = try sub.loadIgnore(io);
            defer ignore_rules.deinit();
            var attrs = try sub.loadAttrs(io);
            defer attrs.deinit();
            var rules = try sub.worktreeRules();
            rules.ignore = &ignore_rules;
            rules.attrs = &attrs;
            rules.required_filters = try sub.requiredFilters(arena);
            rules.submodules = nested.submodules();
            _ = worktree.checkout(m.gpa, io, sub.workDirectory().?.get(), .{ .index = index, .db = sub.objectDatabase(), .tree = new_tree }, .{
                .rules = rules,
                .force = true,
                .programs = m.options.programs,
            }) catch |err| return m.passOn(&nested, err);
        } else {
            const old_tree: ?Oid = if (from) |commit|
                try commitTreeOf(sub, io, commit) orelse return refuse(m.options.refusal, target.display, commit.hex(&hex), error.CommitMissing)
            else
                null;
            var outcome = three_way.fastForward(m.gpa, io, sub, .{ .index = index, .old = old_tree, .new = new_tree }, .{
                .submodules = nested.submodules(),
                .dry_run = request.dry_run,
                .programs = m.options.programs,
            }) catch |err| return m.passOn(&nested, err);
            outcome.deinit();
        }
        if (request.dry_run) return;
        try locked.?.commit(io);
        if (request.to) |to| return m.detach(io, sub, to);
        try m.takeAway(io, target);
    }

    /// A nested mover's refusal is this one's.
    fn passOn(m: *Mover, nested: *const Mover, err: MoveError) MoveError {
        if (err == error.SubmoduleNotUpdated) m.failure = nested.failure;
        return err;
    }

    /// `update-ref --no-deref HEAD <commit>` in the submodule.
    fn detach(m: *Mover, io: Io, sub: *Repository, to: Oid) MoveError!void {
        var tx = sub.beginRefs();
        defer tx.deinit(io);
        try tx.change("HEAD", .{ .direct = to }, .any, .{ .no_deref = true });
        const log: ?refs_mod.LogMessage = if (m.options.who) |who| .{ .who = who, .message = "", .policy = sub.reflogPolicy() } else null;
        try tx.commit(io, log);
    }

    /// The submodule's `.git` file, its directory once empty, and its
    /// repository's `core.worktree`, gone.
    fn takeAway(m: *Mover, io: Io, target: Target) MoveError!void {
        const wt = m.repo.workDirectory().?.get();
        var work = try wt.openDir(io, target.request.path, .{});
        defer work.close(io);
        work.deleteFile(io, ".git") catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        wt.deleteDir(io, target.request.path) catch |err| switch (err) {
            error.DirNotEmpty, error.FileNotFound => {},
            else => |e| return e,
        };
        var module_dir = try target.where.base.openDir(io, target.where.path, .{});
        defer module_dir.close(io);
        try setCoreWorktree(io, m.repo, module_dir, null);
    }
};

/// The tree of `commit` in `repo`, or `null` when the repository does not
/// have it.
fn commitTreeOf(repo: *Repository, io: Io, commit: Oid) Error!?Oid {
    if (!try repo.objectDatabase().exists(io, commit)) return null;
    return try repo.commitTree(io, commit);
}

//=========================================================================
// git branch --recurse-submodules
//=========================================================================

/// The `.gitmodules` the tree `tree` carries at its top, as git reads it
/// for a revision (`gitmodules_config_oid`); none is an empty one.
pub fn gitmodulesOfTree(gpa: Allocator, io: Io, repo: *Repository, tree: Oid) Self.Error!Gitmodules {
    const db = repo.objectDatabase();
    const found = try db.read(io, tree);
    defer db.allocator().free(found.bytes);
    if (found.type != .tree) return error.UnexpectedObjectType;
    const parsed: object.Tree = .parse(repo.objectFormat(), found.bytes);
    const entry = (try parsed.find(".gitmodules")) orelse return .empty(gpa);
    const blob = try db.read(io, entry.oid);
    defer db.allocator().free(blob.bytes);
    if (blob.type != .blob) return .empty(gpa);
    return Gitmodules.parse(gpa, blob.bytes);
}

/// Whether a checkout, a reset or a `read-tree` moves the submodules:
/// `--recurse-submodules` or `--no-recurse-submodules` (`explicit`), else
/// `submodule.recurse`. One that does hands a `Mover` to the update.
pub fn updatesRecurse(config: *const config_mod.Config, explicit: ?bool) Self.Error!bool {
    return explicit orelse try config.getBool("submodule.recurse", false);
}

/// Whether `git branch` makes its branches in the submodules too:
/// `--recurse-submodules` (`explicit`) or `submodule.recurse`, and either
/// only under `submodule.propagateBranches`. `explicit` without it is
/// `error.BranchesNotPropagated`, which git dies on.
pub fn branchesRecurse(config: *const config_mod.Config, explicit: bool) Self.Error!bool {
    const propagate = try config.getBool("submodule.propagatebranches", false);
    if (explicit and !propagate) return error.BranchesNotPropagated;
    return (explicit or try config.getBool("submodule.recurse", false)) and propagate;
}

/// How `createBranches` makes its branches.
pub const BranchOptions = struct {
    /// Who each reflog line is by.
    who: object.Signature,
    /// `-f`.
    force: bool = false,
    /// As `commit.branch.Options.track`; `null` takes
    /// `branch.autoSetupMerge`, in each submodule its own.
    track: ?branch_mod.Track = null,
    /// What each submodule's repository is opened with.
    open: Repository.OpenOptions = .{},
    refusal: ?*Refusal = null,
};

/// git's `create_branches_recursively`, `git branch --recurse-submodules
/// <name> <start>`: the branch made in the superproject at `start`, and in
/// each active submodule the start's tree has, at the commit its gitlink
/// records, theirs in turn. Every one is checked before any is made: a
/// submodule whose repository is nowhere is `error.NotCloned`, one where
/// the branch cannot be made its reason. Each submodule's branch is set up
/// to track what the superproject's start is, as its own remotes map it.
pub fn createBranches(gpa: Allocator, io: Io, repo: *Repository, inputs: branch_mod.Inputs, options: BranchOptions) Self.Error!void {
    try branchesIn(gpa, io, repo, .{ .name = inputs.name, .start = inputs.start, .track = options.track }, options, true);
    try branchesIn(gpa, io, repo, .{ .name = inputs.name, .start = inputs.start, .track = options.track }, options, false);
}

/// One repository's part of `createBranches`: `tracking` the
/// superproject's branch point, `null` at the top, where it is the start's
/// own; `track` what the command line said, `null` the repository's
/// configuration.
const BranchesAt = struct {
    name: []const u8,
    start: []const u8,
    tracking: ?[]const u8 = null,
    track: ?branch_mod.Track,
    prefix: []const u8 = "",
    depth: u32 = 0,
};

fn branchesIn(gpa: Allocator, io: Io, repo: *Repository, at: BranchesAt, options: BranchOptions, dry_run: bool) Error!void {
    if (at.depth > max_depth) return refuse(options.refusal, at.prefix, "", error.NestingTooDeep);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const start = try branch_mod.resolveStart(arena, io, repo, at.start, false);
    const tracking = at.tracking orelse start.ref;
    const how = at.track orelse try branch_mod.configuredTrack(repo.configuration());
    // What `submodule_create_branch` passes on: `--no-track`,
    // `--track=direct`, `--track=inherit`, or nothing.
    const passed: ?branch_mod.Track = switch (how) {
        .never => .never,
        .always, .explicit => .explicit,
        .inherit => .inherit,
        .remote, .simple => null,
    };

    var subs: std.ArrayList(TreeSubmodule) = .empty;
    defer for (subs.items) |*s| if (s.repo) |*r| r.deinit(io);
    const root = try repo.commitTree(io, start.oid);
    var modules = try gitmodulesOfTree(gpa, io, repo, root);
    defer modules.deinit();
    try submodulesOfTree(arena, io, repo, &modules, .{ .oid = root }, options.open, &subs);
    for (subs.items) |s| {
        if (s.repo == null) return refuse(options.refusal, try join(arena, at.prefix, s.path), s.name, error.NotCloned);
    }
    var hex: [hash.max_hex_len]u8 = undefined;
    for (subs.items) |*s| {
        const inner: BranchesAt = .{
            .name = at.name,
            .start = try arena.dupe(u8, s.oid.hex(&hex)),
            .tracking = tracking,
            .track = passed,
            .prefix = try arena.print("{s}{s}/", .{ at.prefix, s.path }),
            .depth = at.depth + 1,
        };
        try branchesIn(gpa, io, &s.repo.?, inner, options, true);
    }
    var created = try branch_mod.create(gpa, io, repo, .{ .name = at.name, .start = at.start }, .{
        .who = options.who,
        .force = options.force,
        .track = .never,
        .dry_run = dry_run,
    });
    created.deinit();
    if (dry_run) return;
    if (tracking) |orig| _ = try branch_mod.setTracking(arena, io, repo, .{ .name = at.name, .orig = orig, .how = how });
    for (subs.items) |*s| {
        const inner: BranchesAt = .{
            .name = at.name,
            .start = try arena.dupe(u8, s.oid.hex(&hex)),
            .tracking = tracking,
            .track = passed,
            .prefix = try arena.print("{s}{s}/", .{ at.prefix, s.path }),
            .depth = at.depth + 1,
        };
        try branchesIn(gpa, io, &s.repo.?, inner, options, false);
    }
}

/// An active submodule a tree has: git's `submodule_tree_entry`.
const TreeSubmodule = struct { path: []const u8, name: []const u8, oid: Oid, repo: ?Repository };

/// git's `submodules_of_tree`: the active gitlinks under a tree, in tree
/// order, each with its repository, `null` where it is nowhere.
fn submodulesOfTree(
    arena: Allocator,
    io: Io,
    repo: *Repository,
    modules: *const Gitmodules,
    tree: struct { oid: Oid, prefix: []const u8 = "" },
    open: Repository.OpenOptions,
    out: *std.ArrayList(TreeSubmodule),
) Error!void {
    const db = repo.objectDatabase();
    const found = try db.read(io, tree.oid);
    defer db.allocator().free(found.bytes);
    const parsed: object.Tree = .parse(repo.objectFormat(), found.bytes);
    var it = parsed.iterate();
    while (try it.next()) |entry| {
        const path = if (tree.prefix.len == 0) try arena.dupe(u8, entry.name) else try arena.print("{s}/{s}", .{ tree.prefix, entry.name });
        switch (entry.mode) {
            .gitlink => {
                const module = modules.byPath(path) orelse continue;
                if (!try isActive(arena, repo, module.name, path)) continue;
                const name = try arena.dupe(u8, module.name);
                try out.append(arena, .{ .path = path, .name = name, .oid = entry.oid, .repo = null });
                out.items[out.items.len - 1].repo = try openRepository(repo.allocator(), io, repo, .{ .path = path, .name = name }, open);
            },
            .tree => try submodulesOfTree(arena, io, repo, modules, .{ .oid = entry.oid, .prefix = path }, open, out),
            else => {},
        }
    }
}

//=========================================================================
// git submodule foreach
//=========================================================================

/// One populated submodule, as `Walk.next` hands it over.
pub const Visit = struct {
    /// From `.gitmodules`.
    name: []const u8,
    /// Relative to the top superproject's working tree.
    path: []const u8,
    /// Relative to the superproject that records it: git's `$sm_path`.
    local_path: []const u8,
    /// The commit its superproject's index records, or `null` while the
    /// gitlink is unmerged.
    recorded: ?Oid,
    /// 0 for the top superproject's own submodules.
    depth: u32,
    /// Its repository, open until the walk moves on.
    repo: *Repository,
};

/// How `walk` behaves.
pub const WalkOptions = struct {
    /// Which submodules of the top superproject; see `list`.
    paths: ?[]const []const u8 = null,
    /// `--recursive`: each submodule's own populated submodules follow it.
    recursive: bool = false,
    /// What each submodule's repository is opened with.
    open: Repository.OpenOptions = .{},
    refusal: ?*Refusal = null,
};

/// One repository a `Walk` is inside: its listing and how far through it.
const WalkFrame = struct {
    /// `null` for the top superproject, which the caller owns.
    repo_storage: ?Repository,
    repo: *Repository,
    listing: Listing,
    next: usize = 0,
    prefix: []const u8,
    depth: u32,
    arena: std.heap.ArenaAllocator,

    fn destroy(frame: *WalkFrame, gpa: Allocator, io: Io) void {
        frame.listing.deinit();
        if (frame.repo_storage) |*r| r.deinit(io);
        frame.arena.deinit();
        gpa.destroy(frame);
    }
};

/// Every populated submodule, one at a time, in the order `git submodule
/// foreach` visits them: a submodule, then — when recursive — its own,
/// depth first. Nothing is run; the caller does what it likes with each
/// repository.
pub const Walk = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    io: Io,
    options: WalkOptions,
    frames: std.ArrayList(*WalkFrame) = .empty,
    /// The last visit's repository, when it has no frame of its own.
    loose: ?*WalkFrame = null,

    /// The next populated submodule, or `null` when there are no more. The
    /// visit's slices and repository are valid until the next call.
    pub fn next(w: *Walk) Self.Error!?Visit {
        if (w.loose) |frame| {
            frame.destroy(w.gpa, w.io);
            w.loose = null;
        }
        while (w.frames.items.len > 0) {
            const frame = w.frames.items[w.frames.items.len - 1];
            // Each frame is one level below the one under it, and only the
            // caller's superproject, at the bottom, is not the walk's to close.
            assert(frame.depth == w.frames.items.len - 1);
            assert((frame.repo_storage == null) == (frame.depth == 0));
            assert(frame.next <= frame.listing.entries.len);
            if (frame.next == frame.listing.entries.len) {
                _ = w.frames.pop();
                frame.destroy(w.gpa, w.io);
                continue;
            }
            const entry = frame.listing.entries[frame.next];
            frame.next += 1;
            const wt = (frame.repo.workDirectory() orelse return error.BareRepository).get();
            var found = (try gitlink.open(w.gpa, w.io, wt, entry.path)) orelse continue;
            found.deinit(w.io);
            const display = try join(frame.arena.allocator(), frame.prefix, entry.path);
            const module = entry.module orelse return refuse(w.options.refusal, display, "", error.NoSubmoduleMapping);
            if (frame.depth + 1 > max_depth) return refuse(w.options.refusal, display, "", error.NestingTooDeep);

            const child = try w.gpa.create(WalkFrame);
            errdefer w.gpa.destroy(child);
            child.* = .{
                .repo_storage = try openSubmodule(w.gpa, w.io, frame.repo, entry.path, w.options.open),
                .repo = undefined,
                .listing = undefined,
                .prefix = undefined,
                .depth = frame.depth + 1,
                .arena = .init(w.gpa),
            };
            child.repo = &child.repo_storage.?;
            errdefer {
                child.repo_storage.?.deinit(w.io);
                child.arena.deinit();
            }
            child.prefix = try child.arena.allocator().print("{s}/", .{display});
            if (w.options.recursive) {
                try w.frames.ensureUnusedCapacity(w.gpa, 1);
                var index = try child.repo.openIndex(w.io);
                defer index.deinit();
                child.listing = try list(w.gpa, w.io, child.repo, &index, null);
                w.frames.appendAssumeCapacity(child);
            } else {
                child.listing = .{ .gpa = w.gpa, .arena = .{}, .entries = &.{}, .gitmodules = .empty(w.gpa) };
                w.loose = child;
            }
            return .{
                .name = module.name,
                .path = display,
                .local_path = entry.path,
                .recorded = entry.recorded,
                .depth = frame.depth,
                .repo = child.repo,
            };
        }
        return null;
    }

    /// Close every repository the walk opened.
    pub fn deinit(w: *Walk) void {
        if (w.loose) |frame| frame.destroy(w.gpa, w.io);
        while (w.frames.pop()) |frame| frame.destroy(w.gpa, w.io);
        w.frames.deinit(w.gpa);
        w.* = undefined;
    }
};

/// Begin walking `repo`'s populated submodules. `repo` is the caller's and
/// must outlive the walk.
pub fn walk(gpa: Allocator, io: Io, repo: *Repository, options: WalkOptions) Self.Error!Walk {
    var w: Walk = .{ .gpa = gpa, .io = io, .options = options };
    errdefer w.deinit();
    const top = try gpa.create(WalkFrame);
    errdefer gpa.destroy(top);
    var index = try repo.openIndex(io);
    defer index.deinit();
    top.* = .{
        .repo_storage = null,
        .repo = repo,
        .listing = try list(gpa, io, repo, &index, options.paths),
        .prefix = "",
        .depth = 0,
        .arena = .init(gpa),
    };
    w.frames.append(gpa, top) catch |err| {
        top.listing.deinit();
        top.arena.deinit();
        return err;
    };
    return w;
}
