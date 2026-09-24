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
//! git's rule for names, the path against every rule `safepath` holds, and
//! each component of the path for a symbolic link, which git refuses since
//! the fix for a symlink that pointed a submodule's checkout into `.git`.
//!
//! This is the half that needs no network. A submodule whose repository is
//! nowhere on the disk, and a commit its repository does not have, both
//! need a fetch; `UpdateOptions.transport` is where one plugs in, and
//! without one each is a named error rather than a guess. Nothing here
//! starts a process unless the caller hands in `program.Programs` and the
//! repository's own configuration names a `!command` update.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const fs = @import("fs.zig");
const safepath = @import("safepath.zig");
const index_mod = @import("index.zig");
const config_mod = @import("config.zig");
const refs_mod = @import("refs.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const gitmodules = @import("gitmodules.zig");
const gitlink = @import("gitlink.zig");
const program = @import("program.zig");
const wildmatch = @import("wildmatch.zig");

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
    /// A `submodule.active` pathspec with magic this release does not read.
    UnsupportedPathspec,
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
    /// The superproject has no working tree.
    BareRepository,
    /// The `Transport` failed; it says why.
    TransportFailed,
} || repo_mod.Error || worktree.Error || gitmodules.ParseError || gitmodules.ResolveError ||
    config_mod.Config.SetError || refs_mod.TransactionError || program.Error || gitlink.Error ||
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
pub fn loadGitmodules(gpa: Allocator, io: Io, repo: *Repository, index: *const Index) Error!Gitmodules {
    if (isUnmerged(index, ".gitmodules")) return .empty(gpa);
    if (repo.work_dir) |wt| {
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
        const found = try repo.odb.read(io, tree);
        defer gpa.free(found.bytes);
        const parsed: object.Tree = .parse(repo.kind, found.bytes);
        const entry = (try parsed.find(".gitmodules")) orelse break :blk null;
        break :blk entry.oid;
    };
    const oid = blob orelse return .empty(gpa);
    const found = try repo.odb.read(io, oid);
    defer gpa.free(found.bytes);
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
) Error!Listing {
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
    return std.fmt.allocPrint(arena, "submodule.{s}.{s}", .{ name, variable });
}

/// A configuration value with its quotes and escapes undone, or `null`.
fn configString(arena: Allocator, config: *const config_mod.Config, key: []const u8) Error!?[]const u8 {
    const raw = config.get(key) orelse return null;
    return try config_mod.unquote(arena, raw);
}

/// Whether git counts the submodule as active: `submodule.<name>.active`
/// when it is set, else whether `submodule.active`'s pathspecs match its
/// path when those are set, else whether `submodule.<name>.url` is.
pub fn isActive(arena: Allocator, repo: *Repository, name: []const u8, path: []const u8) Error!bool {
    const active_key = try configKey(arena, name, "active");
    if (repo.config.find(active_key) != null) return repo.config.getBool(active_key, false);
    const specs = try repo.config.all("submodule.active");
    defer repo.config.gpa.free(specs);
    if (specs.len > 0) return pathspecMatches(arena, specs, path);
    return repo.config.get(try configKey(arena, name, "url")) != null;
}

/// git's pathspec match for `submodule.active`: a path, a directory above
/// it, or a glob; `:(exclude)`, `:!` and `:^` take matches away; `:(top)`,
/// `:/`, `:(glob)` and `:(literal)` are read, and any other magic is
/// refused by name.
fn pathspecMatches(arena: Allocator, specs: []const []const u8, path: []const u8) Error!bool {
    var positive = false;
    var included = false;
    var excluded = false;
    for (specs) |raw| {
        var spec: []const u8 = try config_mod.unquote(arena, raw);
        var exclude = false;
        var literal = false;
        var glob = false;
        if (std.mem.startsWith(u8, spec, ":(")) {
            const close = std.mem.indexOfScalar(u8, spec, ')') orelse return error.UnsupportedPathspec;
            var words = std.mem.splitScalar(u8, spec[2..close], ',');
            while (words.next()) |word| {
                if (std.mem.eql(u8, word, "exclude")) {
                    exclude = true;
                } else if (std.mem.eql(u8, word, "literal")) {
                    literal = true;
                } else if (std.mem.eql(u8, word, "glob")) {
                    glob = true;
                } else if (!std.mem.eql(u8, word, "top")) {
                    return error.UnsupportedPathspec;
                }
            }
            spec = spec[close + 1 ..];
        } else if (spec.len > 0 and spec[0] == ':') {
            var i: usize = 1;
            while (i < spec.len) : (i += 1) switch (spec[i]) {
                '!', '^' => exclude = true,
                '/' => {},
                ':' => {
                    i += 1;
                    break;
                },
                else => break,
            };
            spec = spec[i..];
        }
        const matches = matchOne(spec, path, literal, glob);
        if (exclude) {
            if (matches) excluded = true;
        } else {
            positive = true;
            if (matches) included = true;
        }
    }
    return (included or !positive) and !excluded;
}

fn matchOne(spec: []const u8, path: []const u8, literal: bool, glob: bool) bool {
    const p = std.mem.trimEnd(u8, spec, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return true;
    if (std.mem.eql(u8, p, path)) return true;
    if (std.mem.startsWith(u8, path, p) and path.len > p.len and path[p.len] == '/') return true;
    if (literal) return false;
    return wildmatch.match(spec, path, .{ .pathname = glob }) catch false;
}

/// The remote git resolves a relative url against: the current branch's
/// `branch.<name>.remote`, else the only remote when there is one, else
/// `origin`.
fn defaultRemote(arena: Allocator, io: Io, repo: *Repository) Error![]const u8 {
    if (try repo.refs.currentBranch(arena, io)) |branch| {
        const key = try std.fmt.allocPrint(arena, "branch.{s}.remote", .{branch});
        if (try configString(arena, &repo.config, key)) |remote| return remote;
    }
    const remotes = try repo.config.subsections(arena, "remote");
    if (remotes.len == 1) return remotes[0];
    return "origin";
}

/// What a relative url is resolved against: the default remote's url, or,
/// when it has none, the superproject's own working tree — git's "this
/// repository is its own authoritative upstream".
fn superprojectUrl(arena: Allocator, io: Io, repo: *Repository) Error![]const u8 {
    const remote = try defaultRemote(arena, io, repo);
    const key = try std.fmt.allocPrint(arena, "remote.{s}.url", .{remote});
    if (try configString(arena, &repo.config, key)) |url| {
        if (url.len > 0) return url;
    }
    return absolutePath(arena, io, repo.work_dir orelse return error.BareRepository);
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
    if (try configString(arena, &repo.config, try configKey(arena, module.name, "url"))) |url| return url;
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
    if (!gitmodules.checkUrl(url)) return refuse(refusal, display, url, error.DisallowedUrl);
    if (!gitmodules.isRelativeUrl(url)) return url;
    const base = try superprojectUrl(arena, io, repo);
    return gitmodules.resolveUrl(arena, base, url, up_path) catch |err| switch (err) {
        error.CannotStripComponent => refuse(refusal, display, url, error.CannotStripComponent),
        else => |e| e,
    };
}

/// Edits to the superproject's `.git/config`: read fresh from the disk and
/// written through its lock, and made in the repository's own copy as
/// well, so what it reads next is what was written — git forgets its cached
/// configuration after a write for the same reason.
const LocalEdits = struct {
    file: config_mod.Config,
    changed: bool = false,

    fn open(gpa: Allocator, io: Io, repo: *Repository) Error!LocalEdits {
        return .{ .file = try config_mod.Config.openFile(gpa, io, .{ .dir = repo.common_dir, .sub_path = "config" }, .local, .{}) };
    }

    fn deinit(e: *LocalEdits) void {
        e.file.deinit();
    }

    fn set(e: *LocalEdits, repo: *Repository, key: []const u8, value: []const u8) Error!void {
        try e.file.setIn(.local, key, value);
        try repo.config.setIn(.local, key, value);
        e.changed = true;
    }

    fn removeSubmodule(e: *LocalEdits, repo: *Repository, name: []const u8) Error!bool {
        const removed = try e.file.removeSectionIn(.local, "submodule", name);
        _ = try repo.config.removeSectionIn(.local, "submodule", name);
        if (removed) e.changed = true;
        return removed;
    }

    fn commit(e: *LocalEdits, io: Io, repo: *Repository) Error!void {
        if (e.changed) try e.file.write(io, repo.common_dir, "config");
        e.changed = false;
    }
};

/// Set or, with `null`, remove one value in the `config` file in `dir`.
fn editConfigFile(gpa: Allocator, io: Io, dir: Io.Dir, key: []const u8, value: ?[]const u8) Error!void {
    var config = try config_mod.Config.openFile(gpa, io, .{ .dir = dir, .sub_path = "config" }, .local, .{});
    defer config.deinit();
    if (value) |v| try config.setIn(.local, key, v) else try config.unsetIn(.local, key);
    try config.write(io, dir, "config");
}

/// Set one value in a repository's own `config` file, read fresh and
/// written through its lock, and in the configuration the repository holds.
fn setInRepository(gpa: Allocator, io: Io, repo: *Repository, key: []const u8, value: []const u8) Error!void {
    try editConfigFile(gpa, io, repo.common_dir, key, value);
    try repo.config.setIn(.local, key, value);
}

//=========================================================================
// Layout
//=========================================================================

/// The absolute path of `dir`, `/`-separated, which is how git writes one.
fn absolutePath(arena: Allocator, io: Io, dir: Io.Dir) Error![]u8 {
    var buf: [4096]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    const out = try arena.dupe(u8, buf[0..len]);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

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
        const same = if (builtin.os.tag == .windows)
            std.ascii.eqlIgnoreCase(t_parts.items[common], b_parts.items[common])
        else
            std.mem.eql(u8, t_parts.items[common], b_parts.items[common]);
        if (!same) break;
    }
    if (common == 0 and builtin.os.tag == .windows) return target;
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
    gpa: Allocator,
    io: Io,
    work: Io.Dir,
    work_abs: []const u8,
    git_dir: Io.Dir,
    git_dir_abs: []const u8,
) Error!void {
    const to_git_dir = try relativePath(arena, git_dir_abs, work_abs);
    const line = try std.fmt.allocPrint(arena, "gitdir: {s}\n", .{to_git_dir});
    try work.writeFile(io, .{ .sub_path = ".git", .data = line });
    try editConfigFile(gpa, io, git_dir, "core.worktree", try relativePath(arena, work_abs, git_dir_abs));
}

/// Refuse a path that must never become a filesystem path, and one with a
/// symbolic link for any component, which is git's
/// `validate_submodule_path`.
fn validatePath(io: Io, wt: Io.Dir, path: []const u8, display: []const u8, refusal: ?*Refusal) Error!void {
    if (safepath.check(path, .worktree)) |refused| {
        return refuse(refusal, display, @tagName(refused.reason), error.UnsafePath);
    }
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
        const prefix = try std.fmt.allocPrint(arena, "modules/{s}", .{name[0..i]});
        var dir = git_dir.openDir(io, prefix, .{}) catch continue;
        defer dir.close(io);
        if (gitlink.isGitDirectory(io, dir)) return refuse(refusal, display, prefix, error.GitDirInsideGitDir);
    }
}

/// Open the repository whose working tree is `path` in `repo`'s.
fn openSubmodule(gpa: Allocator, io: Io, repo: *Repository, path: []const u8, options: Repository.OpenOptions) Error!Repository {
    const wt = repo.work_dir orelse return error.BareRepository;
    var dir = try wt.openDir(io, path, .{});
    defer dir.close(io);
    var o = options;
    o.discover = false;
    return Repository.open(gpa, io, dir, o);
}

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
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, path });
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
pub fn status(gpa: Allocator, io: Io, repo: *Repository, options: StatusOptions) Error!Statuses {
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
    const wt = repo.work_dir orelse return error.BareRepository;
    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, paths);
    defer listing.deinit();

    for (listing.entries) |entry| {
        const display = try join(arena, prefix, entry.path);
        const module = entry.module orelse return refuse(options.refusal, display, "", error.NoSubmoduleMapping);
        const name = try arena.dupe(u8, module.name);
        const recorded = entry.recorded orelse {
            try out.append(arena, .{ .state = .conflict, .oid = .zero(repo.kind), .path = display, .name = name, .depth = depth });
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
        found.?.close(io);

        const checked_out = try gitlink.head(gpa, io, wt, entry.path, repo.kind);
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
            try statusInto(arena, gpa, io, &sub, options, null, try std.fmt.allocPrint(arena, "{s}/", .{display}), depth + 1, out);
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
        err: anyerror,

        /// The submodule's path, from the superproject the probe serves.
        pub fn path(f: *const Failure) []const u8 {
            return f.path_buffer[0..f.path_len];
        }
    };

    /// A probe for `repo`, whose index — for the `.gitmodules` blob, when
    /// the working tree has no file — is `index`.
    pub fn init(gpa: Allocator, io: Io, repo: *Repository, index: *const Index, options: ProbeOptions) Error!StatusProbe {
        return initAt(gpa, io, repo, index, options, 0);
    }

    fn initAt(gpa: Allocator, io: Io, repo: *Repository, index: *const Index, options: ProbeOptions, depth: u32) Error!StatusProbe {
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

    fn inspect(context: *anyopaque, io: Io, path: []const u8, recorded: Oid) worktree.Error!worktree.SubmoduleState {
        const p: *StatusProbe = @ptrCast(@alignCast(context));
        return p.inspectPath(io, path, recorded) catch |err| return p.fail(path, err);
    }

    fn fail(p: *StatusProbe, path: []const u8, err: anyerror) worktree.Error {
        if (err == error.SubmoduleUnreadable) return error.SubmoduleUnreadable;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        var failure: Failure = .{ .err = err };
        failure.path_len = @min(path.len, failure.path_buffer.len);
        @memcpy(failure.path_buffer[0..failure.path_len], path[0..failure.path_len]);
        p.failure = failure;
        return error.SubmoduleUnreadable;
    }

    fn inspectPath(p: *StatusProbe, io: Io, path: []const u8, recorded: Oid) Error!worktree.SubmoduleState {
        var arena_instance: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        const ignore = try p.ignoreFor(arena, path);
        if (ignore == .all) return .{};
        const wt = p.repo.work_dir orelse return error.BareRepository;
        var found = (try gitlink.open(p.gpa, io, wt, path)) orelse return .{};
        found.close(io);
        if (p.depth >= max_depth) return error.NestingTooDeep;

        var sub = try openSubmodule(p.gpa, io, p.repo, path, p.options.open);
        defer sub.deinit(io);
        var nested_failure: ?Failure = null;
        const state = inspectRepository(p.gpa, io, &sub, recorded, ignore, p.options, p.depth + 1, &nested_failure) catch |err| {
            if (nested_failure) |nested| {
                // Say which submodule, from this superproject.
                var failure = nested;
                const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ path, nested.path() }) catch path;
                failure.path_len = @min(full.len, failure.path_buffer.len);
                @memcpy(failure.path_buffer[0..failure.path_len], full[0..failure.path_len]);
                p.failure = failure;
            }
            return err;
        };
        return state;
    }

    fn ignoreFor(p: *StatusProbe, arena: Allocator, path: []const u8) Error!gitmodules.Ignore {
        if (p.options.ignore) |forced| return forced;
        if (p.modules.byPath(path)) |module| {
            if (try configString(arena, &p.repo.config, try configKey(arena, module.name, "ignore"))) |text| {
                return gitmodules.Ignore.parse(text) orelse error.InvalidIgnore;
            }
            if (module.ignore) |from_file| return from_file;
        }
        if (try configString(arena, &p.repo.config, "diff.ignoresubmodules")) |text| {
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
    var rules = sub.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.required_filters = required;

    var child = try StatusProbe.initAt(gpa, io, sub, &index, .{ .open = options.open }, depth);
    defer child.deinit();
    var result = worktree.status(gpa, io, sub.work_dir orelse return error.BareRepository, &index, &sub.odb, .{
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
pub fn init(gpa: Allocator, io: Io, repo: *Repository, options: InitOptions) Error!InitOutcome {
    var outcome: InitOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, options.paths);
    defer listing.deinit();
    var edits = try LocalEdits.open(gpa, io, repo);
    defer edits.deinit();

    const only_active = options.paths == null and repo.config.has("submodule.active");
    for (listing.entries) |entry| {
        if (only_active) {
            const m = entry.module orelse continue;
            if (!try isActive(arena, repo, m.name, entry.path)) continue;
        }
        const module = entry.module orelse return refuse(options.refusal, entry.path, "", error.NoSubmoduleMapping);

        if (!try isActive(arena, repo, module.name, entry.path)) {
            try edits.set(repo, try configKey(arena, module.name, "active"), "true");
            outcome.activated += 1;
        }
        const url_key = try configKey(arena, module.name, "url");
        if (repo.config.get(url_key) == null) {
            const url = try moduleUrl(arena, io, repo, module, null, entry.path, options.refusal);
            try edits.set(repo, url_key, url);
            outcome.registered += 1;
        }
        const update_key = try configKey(arena, module.name, "update");
        if (repo.config.get(update_key) == null) {
            if (module.update) |strategy| try edits.set(repo, update_key, strategy.name());
        }
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
pub fn sync(gpa: Allocator, io: Io, repo: *Repository, options: SyncOptions) Error!SyncOutcome {
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
    const wt = repo.work_dir orelse return error.BareRepository;

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, paths);
    defer listing.deinit();
    var edits = try LocalEdits.open(gpa, io, repo);
    defer edits.deinit();

    for (listing.entries) |entry| {
        const module = entry.module orelse continue;
        if (!try isActive(arena, repo, module.name, entry.path)) continue;
        const display = try join(arena, prefix, entry.path);
        try validatePath(io, wt, entry.path, display, options.refusal);

        var for_super: []const u8 = "";
        var for_sub: []const u8 = "";
        if (module.url != null) {
            for_super = try moduleUrl(arena, io, repo, module, null, display, options.refusal);
            for_sub = try moduleUrl(arena, io, repo, module, try upPath(arena, entry.path), display, options.refusal);
        }
        try edits.set(repo, try configKey(arena, module.name, "url"), for_super);
        outcome.synced += 1;

        var found = (try gitlink.open(gpa, io, wt, entry.path)) orelse continue;
        found.close(io);
        var sub = try openSubmodule(gpa, io, repo, entry.path, options.open);
        defer sub.deinit(io);
        const remote = try defaultRemote(arena, io, &sub);
        try setInRepository(gpa, io, &sub, try std.fmt.allocPrint(arena, "remote.{s}.url", .{remote}), for_sub);
        outcome.remotes += 1;
        if (options.recursive) {
            try syncIn(gpa, io, &sub, options, null, try std.fmt.allocPrint(arena, "{s}/", .{display}), depth + 1, outcome);
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
pub fn deinitialize(gpa: Allocator, io: Io, repo: *Repository, options: DeinitOptions) Error!DeinitOutcome {
    var outcome: DeinitOutcome = .{};
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const wt = repo.work_dir orelse return error.BareRepository;

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, options.paths);
    defer listing.deinit();
    var edits = try LocalEdits.open(gpa, io, repo);
    defer edits.deinit();
    const head_tree = try repo.headTree(io);

    for (listing.entries) |entry| {
        const module = entry.module orelse continue;
        try validatePath(io, wt, entry.path, entry.path, options.refusal);

        const on_disk = try fs.statAt(io, wt, entry.path);
        if (on_disk != null and on_disk.?.kind == .directory) {
            const dot_git = try std.fmt.allocPrint(arena, "{s}/.git", .{entry.path});
            if (try fs.statAt(io, wt, dot_git)) |git_entry| {
                if (git_entry.kind == .directory) {
                    try relocate(arena, gpa, io, repo, module, entry.path, entry.path, options.refusal);
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
            var module_dir = repo.git_dir.openDir(io, try modulePath(arena, module.name), .{}) catch null;
            if (module_dir) |*dir| {
                defer dir.close(io);
                if (gitlink.isGitDirectory(io, dir.*)) try editConfigFile(gpa, io, dir.*, "core.worktree", null);
            }
        }
        wt.createDirPath(io, entry.path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
        if (try edits.removeSubmodule(repo, module.name)) outcome.unregistered += 1;
    }
    try edits.commit(io, repo);
    return outcome;
}

fn modulePath(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "modules/{s}", .{name});
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
    const wt = repo.work_dir orelse return error.BareRepository;
    var found = (try gitlink.open(gpa, io, wt, entry.path)) orelse return false;
    found.close(io);
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
        const found = try repo.odb.read(io, current);
        defer repo.gpa.free(found.bytes);
        if (found.type != .tree) return null;
        const parsed: object.Tree = .parse(repo.kind, found.bytes);
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
pub fn absorbGitDirs(gpa: Allocator, io: Io, repo: *Repository, options: AbsorbOptions) Error!AbsorbOutcome {
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
    const wt = repo.work_dir orelse return error.BareRepository;

    var index = try repo.openIndex(io);
    defer index.deinit();
    var listing = try list(gpa, io, repo, &index, paths);
    defer listing.deinit();

    for (listing.entries) |entry| {
        const display = try join(arena, prefix, entry.path);
        try validatePath(io, wt, entry.path, display, options.refusal);
        const dot_git = try std.fmt.allocPrint(arena, "{s}/.git", .{entry.path});
        const git_entry = (try fs.statAt(io, wt, dot_git)) orelse continue;

        if (git_entry.kind == .directory) {
            const module = entry.module orelse return refuse(options.refusal, display, "", error.NoSubmoduleMapping);
            try relocate(arena, gpa, io, repo, module, entry.path, display, options.refusal);
            outcome.moved += 1;
        } else if (try gitlink.open(gpa, io, wt, entry.path)) |found_const| {
            var found = found_const;
            found.close(io);
        } else {
            // A `.git` file naming nothing: the directory it named moved
            // with the submodule this one lives in.
            const module = entry.module orelse return refuse(options.refusal, display, "", error.NoSubmoduleMapping);
            var module_dir = repo.git_dir.openDir(io, try modulePath(arena, module.name), .{}) catch continue;
            defer module_dir.close(io);
            if (!gitlink.isGitDirectory(io, module_dir)) continue;
            var work = try wt.openDir(io, entry.path, .{});
            defer work.close(io);
            try connect(arena, gpa, io, work, try absolutePath(arena, io, work), module_dir, try absolutePath(arena, io, module_dir));
            outcome.reconnected += 1;
        }

        var sub = try openSubmodule(gpa, io, repo, entry.path, options.open);
        defer sub.deinit(io);
        try absorbIn(gpa, io, &sub, options, null, try std.fmt.allocPrint(arena, "{s}/", .{display}), depth + 1, outcome);
    }
}

/// Move `<path>/.git` to `modules/<name>` and connect the two.
fn relocate(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    module: *const gitmodules.Submodule,
    path: []const u8,
    display: []const u8,
    refusal: ?*Refusal,
) Error!void {
    const wt = repo.work_dir orelse return error.BareRepository;
    const dot_git = try std.fmt.allocPrint(arena, "{s}/.git", .{path});
    if (wt.openDir(io, try std.fmt.allocPrint(arena, "{s}/worktrees", .{dot_git}), .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var it = dir.iterate();
        if (try it.next(io) != null) return refuse(refusal, display, "", error.SubmoduleHasWorktrees);
    } else |_| {}
    try validateGitDir(arena, io, repo.git_dir, module.name, display, refusal);
    const target = try modulePath(arena, module.name);
    if (try fs.statAt(io, repo.git_dir, target) != null) return refuse(refusal, display, target, error.GitDirExists);
    if (std.fs.path.dirnamePosix(target)) |parent| {
        repo.git_dir.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
    try wt.rename(dot_git, repo.git_dir, target, io);

    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    var module_dir = try repo.git_dir.openDir(io, target, .{});
    defer module_dir.close(io);
    try connect(arena, gpa, io, work, try absolutePath(arena, io, work), module_dir, try absolutePath(arena, io, module_dir));
}

//=========================================================================
// git submodule update
//=========================================================================

/// What `update` asks for when a submodule's repository or commit is not on
/// the disk. The wire protocol is not this module's; a caller that has one
/// hands it in here.
pub const Transport = struct {
    context: *anyopaque,
    /// Fill `git_dir`, an empty directory, with the repository at `url`,
    /// the way `git clone --no-checkout --separate-git-dir` leaves one: a
    /// non-bare repository with its objects, its refs, `HEAD` on the
    /// default branch, and `remote.origin` configured. `update` writes the
    /// `.git` file and `core.worktree` itself, and checks out the commit.
    cloneFn: *const fn (context: *anyopaque, gpa: Allocator, io: Io, url: []const u8, git_dir: Io.Dir) TransportError!void,
    /// Bring `want` into `repo`, a submodule's repository, from `remote`,
    /// its default remote — what git's fetch inside the submodule does.
    fetchFn: *const fn (context: *anyopaque, gpa: Allocator, io: Io, repo: *Repository, remote: []const u8, want: Oid) TransportError!void,
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
pub fn update(gpa: Allocator, io: Io, repo: *Repository, options: UpdateOptions) Error!UpdateOutcome {
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
    const wt = repo.work_dir orelse return error.BareRepository;

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
        const configured: ?gitmodules.Update = if (try configString(arena, &repo.config, update_key)) |text|
            gitmodules.Update.parse(text) orelse return refuse(options.refusal, display, text, error.InvalidUpdate)
        else
            module.update;
        const skip_none = if (options.strategy) |s| s == .none else (configured != null and configured.? == .none);
        if (skip_none or !try isActive(arena, repo, module.name, entry.path)) {
            outcome.skipped += 1;
            continue;
        }
        const url = try resolvedUrl(arena, io, repo, module, display, options.refusal);
        try validatePath(io, wt, entry.path, display, options.refusal);
        try validateGitDir(arena, io, repo.git_dir, module.name, display, options.refusal);

        const dot_git = try std.fmt.allocPrint(arena, "{s}/.git", .{entry.path});
        const just_cloned = try fs.statAt(io, wt, dot_git) == null;
        if (just_cloned) {
            try populate(arena, gpa, io, repo, module, entry.path, url, display, options, outcome);
        } else {
            try correctCoreWorktree(arena, gpa, io, wt, entry.path);
        }

        var sub = try openSubmodule(gpa, io, repo, entry.path, options.open);
        defer sub.deinit(io);

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
            try ensureCommit(arena, gpa, io, &sub, recorded, display, options);
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
            try updateIn(gpa, io, &sub, options, null, try std.fmt.allocPrint(arena, "{s}/", .{display}), depth + 1, outcome);
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
    const wt = repo.work_dir orelse return error.BareRepository;
    const target = try modulePath(arena, module.name);
    var module_dir: Io.Dir = blk: {
        if (repo.git_dir.openDir(io, target, .{})) |dir| {
            if (gitlink.isGitDirectory(io, dir)) {
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
        } else |_| {}
        const transport = options.transport orelse return refuse(options.refusal, display, url, error.NotCloned);
        if (!gitmodules.checkUrl(url)) return refuse(options.refusal, display, url, error.DisallowedUrl);
        try repo.git_dir.createDirPath(io, target);
        const dir = try repo.git_dir.openDir(io, target, .{ .iterate = true });
        errdefer dir.close(io);
        transport.cloneFn(transport.context, gpa, io, url, dir) catch |err| switch (err) {
            error.TransportFailed => return refuse(options.refusal, display, url, error.TransportFailed),
            else => |e| return e,
        };
        if (!gitlink.isGitDirectory(io, dir)) return refuse(options.refusal, display, url, error.TransportFailed);
        outcome.cloned += 1;
        break :blk dir;
    };
    defer module_dir.close(io);

    try wt.createDirPath(io, path);
    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    try connect(arena, gpa, io, work, try absolutePath(arena, io, work), module_dir, try absolutePath(arena, io, module_dir));
}

/// git's `ensure_core_worktree`: a `core.worktree` a submodule's
/// repository already carries is rewritten to point at where the working
/// tree is now, which is what keeps a superproject's worktrees sharing one
/// repository per submodule working.
fn correctCoreWorktree(arena: Allocator, gpa: Allocator, io: Io, wt: Io.Dir, path: []const u8) Error!void {
    var found = (try gitlink.open(gpa, io, wt, path)) orelse return;
    defer found.close(io);
    var config = try config_mod.Config.openFile(gpa, io, .{ .dir = found.common_dir, .sub_path = "config" }, .local, .{});
    defer config.deinit();
    if (config.get("core.worktree") == null) return;
    var work = try wt.openDir(io, path, .{});
    defer work.close(io);
    const wanted = try relativePath(arena, try absolutePath(arena, io, work), try absolutePath(arena, io, found.git_dir));
    const now = try configString(arena, &config, "core.worktree");
    if (now != null and std.mem.eql(u8, now.?, wanted)) return;
    try config.setIn(.local, "core.worktree", wanted);
    try config.write(io, found.common_dir, "config");
}

/// Make sure the submodule's repository has `commit`, fetching it through
/// the transport when there is one.
fn ensureCommit(arena: Allocator, gpa: Allocator, io: Io, sub: *Repository, commit: Oid, display: []const u8, options: UpdateOptions) Error!void {
    if (try sub.odb.exists(io, commit)) return;
    var hex: [hash.max_hex_len]u8 = undefined;
    const transport = options.transport orelse return refuse(options.refusal, display, commit.hex(&hex), error.CommitMissing);
    const remote = try defaultRemote(arena, io, sub);
    transport.fetchFn(transport.context, gpa, io, sub, remote, commit) catch |err| switch (err) {
        error.TransportFailed => return refuse(options.refusal, display, remote, error.TransportFailed),
        else => |e| return e,
    };
    try sub.odb.refresh(io);
    if (!try sub.odb.exists(io, commit)) return refuse(options.refusal, display, commit.hex(&hex), error.CommitMissing);
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
    const work = sub.work_dir orelse return error.BareRepository;
    const tree = try sub.commitTree(io, commit);
    var index = try sub.openIndex(io);
    defer index.deinit();
    var ignore_rules = try sub.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try sub.loadAttrs(io);
    defer attrs.deinit();
    const required = try sub.requiredFilters(gpa);
    defer gpa.free(required);
    var rules = sub.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;
    rules.required_filters = required;

    if (!force) {
        var current = try worktree.status(gpa, io, work, &index, &sub.odb, .{
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
    _ = worktree.checkout(gpa, io, work, &index, &sub.odb, tree, .{ .rules = rules, .refusal = &refusal, .force = force }) catch |err| switch (err) {
        error.UnsafePath => return refuse(options.refusal, display, refusal.path(), error.UnsafePath),
        else => |e| return e,
    };
    try index.write(io, sub.git_dir, "index", .{});

    var hex: [hash.max_hex_len]u8 = undefined;
    var from_hex: [hash.max_hex_len]u8 = undefined;
    const from: []const u8 = if (try sub.refs.currentBranch(arena, io)) |branch|
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
        .message = try std.fmt.allocPrint(arena, "checkout: moving from {s} to {s}", .{ from, commit.hex(&hex) }),
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
    var outcome = try program.run(programs, gpa, io, .{
        .argv = argv.items,
        .shell = true,
        .cwd = .{ .dir = sub.work_dir orelse return error.BareRepository },
        .unset = &local_repo_env,
        .stderr = .inherit,
    }, "", .{});
    defer outcome.deinit(gpa);
    if (!outcome.succeeded()) return refuse(options.refusal, display, command, error.UpdateCommandFailed);
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

/// Every populated submodule, one at a time, in the order `git submodule
/// foreach` visits them: a submodule, then — when recursive — its own,
/// depth first. Nothing is run; the caller does what it likes with each
/// repository.
pub const Walk = struct {
    gpa: Allocator,
    io: Io,
    options: WalkOptions,
    frames: std.ArrayList(*Frame) = .empty,
    /// The last visit's repository, when it has no frame of its own.
    loose: ?*Frame = null,

    const Frame = struct {
        /// `null` for the top superproject, which the caller owns.
        repo_storage: ?Repository,
        repo: *Repository,
        listing: Listing,
        next: usize = 0,
        prefix: []const u8,
        depth: u32,
        arena: std.heap.ArenaAllocator,

        fn destroy(frame: *Frame, gpa: Allocator, io: Io) void {
            frame.listing.deinit();
            if (frame.repo_storage) |*r| r.deinit(io);
            frame.arena.deinit();
            gpa.destroy(frame);
        }
    };

    /// The next populated submodule, or `null` when there are no more. The
    /// visit's slices and repository are valid until the next call.
    pub fn next(w: *Walk) Error!?Visit {
        if (w.loose) |frame| {
            frame.destroy(w.gpa, w.io);
            w.loose = null;
        }
        while (w.frames.items.len > 0) {
            const frame = w.frames.items[w.frames.items.len - 1];
            if (frame.next == frame.listing.entries.len) {
                _ = w.frames.pop();
                frame.destroy(w.gpa, w.io);
                continue;
            }
            const entry = frame.listing.entries[frame.next];
            frame.next += 1;
            const wt = frame.repo.work_dir orelse return error.BareRepository;
            var found = (try gitlink.open(w.gpa, w.io, wt, entry.path)) orelse continue;
            found.close(w.io);
            const display = try join(frame.arena.allocator(), frame.prefix, entry.path);
            const module = entry.module orelse return refuse(w.options.refusal, display, "", error.NoSubmoduleMapping);
            if (frame.depth + 1 > max_depth) return refuse(w.options.refusal, display, "", error.NestingTooDeep);

            const child = try w.gpa.create(Frame);
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
            child.prefix = try std.fmt.allocPrint(child.arena.allocator(), "{s}/", .{display});
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
pub fn walk(gpa: Allocator, io: Io, repo: *Repository, options: WalkOptions) Error!Walk {
    var w: Walk = .{ .gpa = gpa, .io = io, .options = options };
    errdefer w.deinit();
    const top = try gpa.create(Walk.Frame);
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
