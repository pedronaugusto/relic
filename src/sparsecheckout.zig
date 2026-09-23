//! `git sparse-checkout` as an operation: `set`, `add`, `reapply`,
//! `disable`, `init` and `list`.
//!
//! What each one leaves behind is what git's command leaves: the same
//! `info/sparse-checkout`, byte for byte; `core.sparseCheckout`,
//! `core.sparseCheckoutCone` and `index.sparse` in the worktree's own
//! `config.worktree`, with `extensions.worktreeConfig` turned on first and
//! `core.bare` and `core.worktree` moved out of the shared file as git moves
//! them; and an index whose `skip-worktree` bits, and a working tree whose
//! files, follow the new patterns. The order is git's too: the pattern file's
//! lock is taken, then the index's, the working tree is updated, the index is
//! written, and only then does the new pattern file replace the old one.
//!
//! The settings are read from the repository's files on every call rather
//! than from `Repository.config`, which is the configuration as it was when
//! the repository was opened and which these operations change. A caller
//! that reads the settings itself afterwards reopens the repository.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("config.zig");
const fs = @import("fs.zig");
const index_mod = @import("index.zig");
const repo_mod = @import("repo.zig");
const sparse = @import("sparse.zig");
const worktree = @import("worktree.zig");

const Config = config_mod.Config;
const Repository = repo_mod.Repository;

/// Errors from a sparse-checkout operation.
pub const Error = error{
    /// The repository has no working tree to be sparse.
    NoWorkingTree,
    /// `add`, `reapply` and `list` need `core.sparseCheckout` to be on.
    NotSparse,
    /// `add` in cone mode found a pattern file that is not a cone, which
    /// git refuses rather than rewriting.
    NotACone,
    /// In cone mode a directory was given as a pattern: with a leading `/`
    /// or `!`, or holding one of `*?[]`. `skip_checks` lets it through.
    PatternNotADirectory,
    /// In cone mode a path names a file the index holds, which cannot be a
    /// directory to include. `skip_checks` lets it through.
    PathIsAFile,
    /// A path climbs out of the working tree with `..`.
    PathOutsideWorktree,
    /// `add` found no pattern file to add to.
    PatternFileMissing,
} || worktree.Error || Config.SetError || config_mod.ParseError || config_mod.ValueError ||
    fs.LockError || fs.CommitError || sparse.Error || repo_mod.Error;

/// How an operation behaves. Each field is one of the command's options.
pub const Options = struct {
    /// `--cone` or `--no-cone`. `null` keeps the mode a sparse worktree
    /// already has, and picks cone mode for one that is not sparse yet,
    /// which is git's default since 2.37.
    cone: ?bool = null,
    /// `--sparse-index` or `--no-sparse-index`: whether `index.sparse` is
    /// set. `null` leaves it as it is.
    sparse_index: ?bool = null,
    /// `--skip-checks`: take cone-mode paths as they are given, even ones
    /// that look like patterns or name a file.
    skip_checks: bool = false,
};

/// The three settings, as they apply to this worktree.
pub const Settings = struct {
    /// `core.sparseCheckout`.
    enabled: bool,
    /// `core.sparseCheckoutCone`.
    cone: bool,
    /// `index.sparse`.
    sparse_index: bool,
};

/// What an operation did to the working tree and the index.
pub const Outcome = struct {
    /// The working-tree update, or zeros when there was none to make.
    update: worktree.SparseOutcome = .{},
    /// Whether the index was written, which it is not in a repository
    /// whose index has never been written: there is nothing checked out to
    /// make sparse.
    index_written: bool = false,
};

/// The settings as the repository's files hold them now.
pub fn settings(repo: *Repository, io: Io) Error!Settings {
    var files = try Files.open(repo, io);
    defer files.deinit();
    return files.settings(repo);
}

/// `git sparse-checkout set`: replace the patterns with `patterns` and make
/// the working tree follow them.
///
/// In cone mode each pattern is a directory to include with everything
/// under it; with none, only the files at the root are included. Otherwise
/// each is a line of the pattern file, and with none the file is `/*` and
/// `!/*/`, which is the same root-only checkout.
pub fn set(repo: *Repository, io: Io, patterns: []const []const u8, options: Options) Error!Outcome {
    var op = try Op.init(repo, io);
    defer op.deinit();
    try op.updateModes(options);
    try op.sanitize(patterns, options);

    var arena_instance: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const text = if (op.state.cone) blk: {
        var cone: sparse.Cone = .{ .fold = op.fold };
        defer cone.deinit(repo.gpa);
        for (patterns) |raw| {
            const dir = (try normalizeDirectory(arena, raw)) orelse continue;
            try cone.addRecursive(repo.gpa, arena, dir);
        }
        break :blk try renderCone(arena, &cone);
    } else blk: {
        const lines: []const []const u8 = if (patterns.len == 0) &.{ "/*", "!/*/" } else patterns;
        break :blk try renderLines(arena, lines);
    };
    return op.writePatternsAndUpdate(text);
}

/// `git sparse-checkout add`: include more.
///
/// In cone mode the directories are added to the cone already there; a
/// pattern file without the cone's shape is `error.NotACone`. Otherwise the
/// lines are appended to the file's own.
pub fn add(repo: *Repository, io: Io, patterns: []const []const u8, options: Options) Error!Outcome {
    var op = try Op.init(repo, io);
    defer op.deinit();
    if (!op.state.enabled) return error.NotSparse;
    try op.sanitize(patterns, options);

    var arena_instance: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const existing = (try fs.readFileAlloc(arena, io, repo.git_dir, pattern_file, 1 << 24)) orelse
        return error.PatternFileMissing;

    const text = if (op.state.cone) blk: {
        var cone: sparse.Cone = .{ .fold = op.fold };
        defer cone.deinit(repo.gpa);
        for (patterns) |raw| {
            const dir = (try normalizeDirectory(arena, raw)) orelse continue;
            try cone.addRecursive(repo.gpa, arena, dir);
        }
        var old = (try sparse.Cone.parse(repo.gpa, arena, existing, op.fold)) orelse return error.NotACone;
        defer old.deinit(repo.gpa);
        // git keeps an old directory unless a new one above it is included
        // whole and another above it is a parent -- the second half of
        // which cannot hold for a directory at the top.
        var it = old.recursive.keyIterator();
        while (it.next()) |dir| {
            if (!hasAncestorIn(&cone, dir.*, .recursive) or !hasAncestorIn(&cone, dir.*, .parents)) {
                try cone.addRecursive(repo.gpa, arena, dir.*);
            }
        }
        break :blk try renderCone(arena, &cone);
    } else blk: {
        var lines: std.ArrayList([]const u8) = .empty;
        try existingLines(arena, existing, &lines);
        try lines.appendSlice(arena, patterns);
        break :blk try renderLines(arena, lines.items);
    };
    return op.writePatternsAndUpdate(text);
}

/// `git sparse-checkout reapply`: make the working tree follow the
/// patterns already there, after a merge or a checkout brought back files
/// they leave out.
pub fn reapply(repo: *Repository, io: Io, options: Options) Error!Outcome {
    var op = try Op.init(repo, io);
    defer op.deinit();
    if (!op.state.enabled) return error.NotSparse;
    try op.updateModes(options);
    return op.updateWorkingTree(null);
}

/// `git sparse-checkout init`: turn sparse checkout on.
///
/// A pattern file already there is kept and applied. Without one the file
/// becomes `/*` and `!/*/` -- only the files at the root.
pub fn init(repo: *Repository, io: Io, options: Options) Error!Outcome {
    var op = try Op.init(repo, io);
    defer op.deinit();
    try op.updateModes(options);
    if (try fs.statAt(io, repo.git_dir, pattern_file)) |_| return op.updateWorkingTree(null);
    return op.writePatternsAndUpdate("/*\n!/*/\n");
}

/// `git sparse-checkout disable`: put every file back and turn sparse
/// checkout off. The pattern file is left where it is, as git leaves it.
pub fn disable(repo: *Repository, io: Io) Error!Outcome {
    var op = try Op.init(repo, io);
    defer op.deinit();

    var everything = try sparse.Patterns.fromText(repo.gpa, "/*\n", .{ .case_fold = op.fold });
    defer everything.deinit();
    op.state.sparse_index = false;
    const outcome = try op.updateWorkingTreeWith(&everything);
    try op.setConfig(.off);
    return outcome;
}

/// What `list` found: the directories of a cone, or the lines of a file
/// that is not one.
pub const Listing = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// Whether `entries` are cone directories rather than pattern lines.
    cone: bool,
    /// In cone mode the directories included whole, sorted, without a
    /// leading slash; otherwise the pattern lines in file order.
    entries: []const []const u8,

    /// Release the listing.
    pub fn deinit(l: *Listing) void {
        var arena = l.arena.promote(l.gpa);
        arena.deinit();
        l.* = undefined;
    }
};

/// `git sparse-checkout list`. A worktree whose pattern file is missing
/// lists nothing, which git reports with a warning rather than an error.
pub fn list(repo: *Repository, io: Io) Error!Listing {
    var op = try Op.init(repo, io);
    defer op.deinit();
    if (!op.state.enabled) return error.NotSparse;

    var arena_instance: std.heap.ArenaAllocator = .init(repo.gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const text = (try fs.readFileAlloc(arena, io, repo.git_dir, pattern_file, 1 << 24)) orelse "";

    var entries: std.ArrayList([]const u8) = .empty;
    var cone_listing = false;
    if (op.state.cone) {
        if (try sparse.Cone.parse(repo.gpa, arena, text, op.fold)) |parsed| {
            var cone = parsed;
            defer cone.deinit(repo.gpa);
            var it = cone.recursive.keyIterator();
            while (it.next()) |dir| try entries.append(arena, dir.*);
            std.mem.sort([]const u8, entries.items, {}, lessThanBytes);
            cone_listing = true;
        }
    }
    if (!cone_listing) try existingLines(arena, text, &entries);
    return .{
        .gpa = repo.gpa,
        .arena = arena_instance.state,
        .cone = cone_listing,
        .entries = entries.items,
    };
}

/// Where the patterns live, under the worktree's own git directory.
const pattern_file = "info/sparse-checkout";

/// The two configuration files an operation reads and writes, opened
/// fresh: the shared `config` and this worktree's `config.worktree`.
const Files = struct {
    gpa: Allocator,
    local: Config,
    worktree: ?Config,

    fn open(repo: *Repository, io: Io) Error!Files {
        var local = try Config.openFile(repo.gpa, io, .{ .dir = repo.common_dir, .sub_path = "config" }, .local, .{});
        errdefer local.deinit();
        const on = try local.getBool("extensions.worktreeconfig", false);
        const wt: ?Config = if (on)
            try Config.openFile(repo.gpa, io, .{ .dir = repo.git_dir, .sub_path = "config.worktree" }, .worktree, .{})
        else
            null;
        return .{ .gpa = repo.gpa, .local = local, .worktree = wt };
    }

    fn deinit(f: *Files) void {
        f.local.deinit();
        if (f.worktree) |*w| w.deinit();
        f.* = undefined;
    }

    /// A value by git's precedence: a value the caller passed at open beats
    /// every file, this worktree's file beats the shared one, and the
    /// shared one beats the user's and the system's.
    fn get(f: *const Files, repo: *const Repository, name: []const u8) ?[]const u8 {
        if (levelValue(&repo.config, name, &.{.command})) |v| return v;
        if (f.worktree) |*w| {
            if (w.find(name)) |entry| return entry.value orelse "true";
        }
        if (f.local.find(name)) |entry| return entry.value orelse "true";
        return levelValue(&repo.config, name, &.{ .global, .system });
    }

    fn getBool(f: *const Files, repo: *const Repository, name: []const u8) Error!bool {
        const text = f.get(repo, name) orelse return false;
        return config_mod.parseBool(text);
    }

    fn settings(f: *const Files, repo: *const Repository) Error!Settings {
        return .{
            .enabled = try f.getBool(repo, "core.sparsecheckout"),
            .cone = try f.getBool(repo, "core.sparsecheckoutcone"),
            .sparse_index = try f.getBool(repo, "index.sparse"),
        };
    }
};

/// The last value of `name` among the entries at one of `levels`.
fn levelValue(config: *const Config, name: []const u8, levels: []const config_mod.Level) ?[]const u8 {
    const split = config_mod.splitFullName(name) orelse return null;
    var found: ?[]const u8 = null;
    for (config.entries.items) |entry| {
        if (std.mem.indexOfScalar(config_mod.Level, levels, entry.level) == null) continue;
        if (!entry.matches(split.section, split.subsection, split.name)) continue;
        found = entry.value orelse "true";
    }
    return found;
}

/// One operation's view of the worktree: its settings, and the state git
/// keeps in globals while the command runs.
const Op = struct {
    repo: *Repository,
    io: Io,
    files: Files,
    state: Settings,
    fold: bool,

    fn init(repo: *Repository, io: Io) Error!Op {
        if (repo.work_dir == null) return error.NoWorkingTree;
        var files = try Files.open(repo, io);
        errdefer files.deinit();
        const state = try files.settings(repo);
        return .{
            .repo = repo,
            .io = io,
            .files = files,
            .state = state,
            .fold = try files.getBool(repo, "core.ignorecase"),
        };
    }

    fn deinit(op: *Op) void {
        op.files.deinit();
        op.* = undefined;
    }

    /// git's `update_modes`: settle cone or not, record it where it was
    /// asked for or where sparse checkout was off, and record
    /// `index.sparse` where it was asked for.
    fn updateModes(op: *Op, options: Options) Error!void {
        const record = options.cone != null or !op.state.enabled;
        const cone = options.cone orelse (if (op.state.enabled) op.state.cone else true);
        op.state.enabled = true;
        op.state.cone = cone;
        if (record) try op.setConfig(if (cone) .cone else .patterns);
        if (options.sparse_index) |on| {
            try op.setWorktreeValue("index.sparse", if (on) "true" else "false");
            op.state.sparse_index = on;
        }
    }

    const Mode = enum { off, patterns, cone };

    /// git's `set_config`: the worktree gets its own configuration file,
    /// and the two settings go into it; turning sparse checkout off also
    /// turns the sparse index off.
    fn setConfig(op: *Op, mode: Mode) Error!void {
        try op.initWorktreeConfig();
        try op.setWorktreeValue("core.sparseCheckout", if (mode != .off) "true" else "false");
        try op.setWorktreeValue("core.sparseCheckoutCone", if (mode == .cone) "true" else "false");
        if (mode == .off) {
            try op.setWorktreeValue("index.sparse", "false");
            op.state.sparse_index = false;
        }
    }

    /// git's `init_worktree_config`: turn `extensions.worktreeConfig` on in
    /// the shared file, and move `core.bare = true` and `core.worktree` out
    /// of it into the main worktree's own file, where every other worktree
    /// stops seeing them.
    fn initWorktreeConfig(op: *Op) Error!void {
        if (op.files.worktree != null) return;
        const repo = op.repo;
        const io = op.io;
        try op.files.local.set("extensions.worktreeConfig", "true");
        try op.files.local.write(io, repo.common_dir, "config");

        const bare = op.files.local.getBool("core.bare", false) catch false;
        const core_worktree = if (op.files.local.get("core.worktree")) |v| try repo.gpa.dupe(u8, v) else null;
        defer if (core_worktree) |v| repo.gpa.free(v);
        if (bare or core_worktree != null) {
            var main = try openWritable(repo.gpa, io, repo.common_dir, "config.worktree", .worktree);
            defer main.deinit();
            if (bare) try main.set("core.bare", "true");
            if (core_worktree) |v| try main.set("core.worktree", v);
            try main.write(io, repo.common_dir, "config.worktree");
            if (bare) try op.files.local.unset("core.bare");
            if (core_worktree != null) try op.files.local.unset("core.worktree");
            try op.files.local.write(io, repo.common_dir, "config");
        }
        op.files.worktree = try openWritable(repo.gpa, io, repo.git_dir, "config.worktree", .worktree);
    }

    /// Set one value in this worktree's `config.worktree`, writing it at
    /// once as git's `repo_config_set_worktree_gently` does.
    fn setWorktreeValue(op: *Op, name: []const u8, value: []const u8) Error!void {
        try op.initWorktreeConfig();
        const wt = &op.files.worktree.?;
        if (wt.files.items.len == 0) {
            wt.deinit();
            op.files.worktree = try openWritable(op.repo.gpa, op.io, op.repo.git_dir, "config.worktree", .worktree);
        }
        try op.files.worktree.?.set(name, value);
        try op.files.worktree.?.write(op.io, op.repo.git_dir, "config.worktree");
    }

    /// Refuse, in cone mode, what cannot be a directory: git's
    /// `sanitize_paths`.
    fn sanitize(op: *Op, patterns: []const []const u8, options: Options) Error!void {
        if (options.skip_checks or patterns.len == 0) return;
        if (op.state.cone) {
            for (patterns) |p| {
                if (p.len > 0 and (p[0] == '/' or p[0] == '!')) return error.PatternNotADirectory;
                if (std.mem.indexOfAny(u8, p, "*?[]") != null) return error.PatternNotADirectory;
            }
            var index = try op.repo.openIndex(op.io);
            defer index.deinit();
            for (patterns) |p| {
                const entry = index.find(p) orelse continue;
                if (entry.mode != .tree) return error.PathIsAFile;
            }
        }
    }

    /// git's `write_patterns_and_update`: hold the pattern file's lock
    /// across the working-tree update, and replace the file only once the
    /// update has succeeded.
    fn writePatternsAndUpdate(op: *Op, text: []const u8) Error!Outcome {
        const repo = op.repo;
        try makeInfoDir(repo, op.io);
        var buffer: [4096]u8 = undefined;
        var lock = try fs.LockFile.open(repo.gpa, op.io, repo.git_dir, pattern_file, &buffer, .{});
        defer lock.deinit(op.io);

        var patterns = try sparse.Patterns.fromText(repo.gpa, text, .{ .case_fold = op.fold, .cone = op.state.cone });
        defer patterns.deinit();
        const outcome = try op.updateWorkingTreeWith(&patterns);

        lock.writer().writeAll(text) catch return error.WriteFailed;
        try lock.commit(op.io);
        return outcome;
    }

    /// Apply the patterns in the pattern file, or `null` for them: git's
    /// `update_working_directory(NULL)`.
    fn updateWorkingTree(op: *Op, patterns: ?*const sparse.Patterns) Error!Outcome {
        if (patterns) |p| return op.updateWorkingTreeWith(p);
        var loaded = (try sparse.Patterns.loadMode(op.repo.gpa, op.io, op.repo.git_dir, .{
            .case_fold = op.fold,
            .cone = op.state.cone,
        })) orelse try sparse.Patterns.init(op.repo.gpa, op.fold);
        defer loaded.deinit();
        return op.updateWorkingTreeWith(&loaded);
    }

    /// Take the index's lock, move the `skip-worktree` bits and the files,
    /// and write the index. An index that has never been written means
    /// nothing is checked out, and nothing is done.
    fn updateWorkingTreeWith(op: *Op, patterns: *const sparse.Patterns) Error!Outcome {
        const repo = op.repo;
        const io = op.io;
        if (try fs.statAt(io, repo.git_dir, "index") == null) return .{};

        const buffer = try repo.gpa.alloc(u8, 64 * 1024);
        defer repo.gpa.free(buffer);
        var lock = try fs.LockFile.open(repo.gpa, io, repo.git_dir, "index", buffer, .{});
        defer lock.deinit(io);

        var index = try repo.openIndex(io);
        defer index.deinit();

        var rules = repo.worktreeRules();
        var attrs = try repo.loadAttrs(io);
        defer attrs.deinit();
        rules.attrs = &attrs;

        const update = try worktree.applySparse(repo.gpa, io, repo.work_dir.?, &index, &repo.odb, patterns, .{ .rules = rules });
        index.writeTo(lock.writer(), .{}) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => |e| return e,
        };
        try lock.commit(io);
        return .{ .update = update, .index_written = true };
    }
};

/// Open a configuration file for writing, making it first if it is not
/// there: git creates `config.worktree` the first time it writes a value.
fn openWritable(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, level: config_mod.Level) Error!Config {
    if (dir.createFile(io, sub_path, .{ .exclusive = true })) |file| {
        file.close(io);
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    }
    return Config.openFile(gpa, io, .{ .dir = dir, .sub_path = sub_path }, level, .{});
}

fn makeInfoDir(repo: *Repository, io: Io) Error!void {
    repo.git_dir.createDirPath(io, "info") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

/// A cone-mode path as git reads it: trimmed, its trailing slashes taken
/// off, `.` and `..` resolved and repeated slashes folded, and one leading
/// slash dropped. `null` for a path that comes to nothing, which git skips.
fn normalizeDirectory(arena: Allocator, raw: []const u8) Error!?[]const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
    while (text.len > 0 and text[text.len - 1] == '/') text = text[0 .. text.len - 1];
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.PathOutsideWorktree;
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, part);
    }
    if (parts.items.len == 0) return null;
    return try std.mem.join(arena, "/", parts.items);
}

const Set = enum { recursive, parents };

/// Whether a directory above `dir` is in one of the cone's sets: git's
/// `hashmap_contains_parent`.
fn hasAncestorIn(cone: *const sparse.Cone, dir: []const u8, which: Set) bool {
    var end = dir.len;
    while (std.mem.lastIndexOfScalar(u8, dir[0..end], '/')) |slash| {
        end = slash;
        const found = switch (which) {
            .recursive => cone.isRecursive(dir[0..end]),
            .parents => cone.isParent(dir[0..end]),
        };
        if (found) return true;
    }
    return false;
}

/// The pattern file a cone is written as, which is git's
/// `write_cone_to_file`: the root lines, then each parent with the line
/// that keeps its subdirectories out, then each directory included whole,
/// each group sorted, and nothing that a directory above it already covers.
fn renderCone(arena: Allocator, cone: *const sparse.Cone) Allocator.Error![]const u8 {
    var parents: std.ArrayList([]const u8) = .empty;
    var pit = cone.parents.keyIterator();
    while (pit.next()) |dir| {
        if (cone.isRecursive(dir.*)) continue;
        if (hasAncestorIn(cone, dir.*, .recursive)) continue;
        try parents.append(arena, dir.*);
    }
    std.mem.sort([]const u8, parents.items, {}, lessThanBytes);

    var recursive: std.ArrayList([]const u8) = .empty;
    var rit = cone.recursive.keyIterator();
    while (rit.next()) |dir| {
        if (hasAncestorIn(cone, dir.*, .recursive)) continue;
        try recursive.append(arena, dir.*);
    }
    std.mem.sort([]const u8, recursive.items, {}, lessThanBytes);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "/*\n!/*/\n");
    for (dedupe(parents.items)) |dir| {
        const escaped = try escapeName(arena, dir);
        try out.print(arena, "/{s}/\n!/{s}/*/\n", .{ escaped, escaped });
    }
    for (dedupe(recursive.items)) |dir| {
        try out.print(arena, "/{s}/\n", .{try escapeName(arena, dir)});
    }
    return out.items;
}

/// A sorted list with equal neighbours taken out, which a set that folds
/// case cannot produce and one that does not can.
fn dedupe(items: [][]const u8) [][]const u8 {
    if (items.len == 0) return items;
    var kept: usize = 1;
    for (items[1..]) |item| {
        if (std.mem.eql(u8, item, items[kept - 1])) continue;
        items[kept] = item;
        kept += 1;
    }
    return items[0..kept];
}

/// A directory name with each glob character escaped, as git writes it.
fn escapeName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (c == '*' or c == '?' or c == '[' or c == '\\') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.items;
}

/// Lines written one to a line, each ended with a newline.
fn renderLines(arena: Allocator, lines: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// The pattern lines of a file as git keeps them when it reads one:
/// comments and blank lines gone, trailing spaces trimmed.
fn existingLines(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (lines.peek() == null and raw.len == 0) break;
        const line = sparse.trimPattern(raw);
        if (line.len == 0 or line[0] == '#') continue;
        try out.append(arena, line);
    }
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

//=========================================================================
// Tests
//
// Twin repositories: git runs the command in one and this runs it in the
// other, and what each leaves behind is compared -- the pattern file and
// both configuration files byte for byte, and `git ls-files -t`, `git
// status` and `git sparse-checkout list` as git prints them.
//
// The git these are held to is 2.45 or later. The command has changed in
// small ways since it arrived -- cone mode became the default in 2.37, the
// path checks and `--skip-checks` came after, and `init` stopped treating a
// branch with no commit specially -- and this follows the current release.
//=========================================================================

const testgit = @import("testgit.zig");

fn requireCurrentGit(gpa: Allocator, io: Io) !void {
    try testgit.requireGitVersion(gpa, io, 2, 45);
}

const Twin = struct {
    theirs: testgit.Repo,
    ours: testgit.Repo,

    fn init(gpa: Allocator, io: Io, extra: []const []const u8, comptime setup: fn (*testgit.Repo, Io) anyerror!void) !Twin {
        try requireCurrentGit(gpa, io);
        var theirs = try testgit.Repo.init(gpa, io, extra);
        errdefer theirs.deinit();
        try setup(&theirs, io);
        var ours = try testgit.Repo.init(gpa, io, extra);
        errdefer ours.deinit();
        try setup(&ours, io);
        return .{ .theirs = theirs, .ours = ours };
    }

    fn deinit(t: *Twin) void {
        t.theirs.deinit();
        t.ours.deinit();
    }

    /// Run `git sparse-checkout <args>` in theirs.
    fn git(t: *Twin, io: Io, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(t.theirs.gpa);
        try argv.append(t.theirs.gpa, "sparse-checkout");
        try argv.appendSlice(t.theirs.gpa, args);
        try t.theirs.exec(io, argv.items);
    }

    fn open(t: *Twin, io: Io) !Repository {
        return Repository.open(t.ours.gpa, io, t.ours.dir, .{});
    }

    /// Everything the two commands leave behind, compared.
    fn expectSame(t: *Twin, io: Io) !void {
        const gpa = t.ours.gpa;
        for ([_][]const u8{ ".git/info/sparse-checkout", ".git/config.worktree", ".git/config" }) |path| {
            const a = try readOptional(gpa, io, t.theirs.dir, path);
            defer if (a) |bytes| gpa.free(bytes);
            const b = try readOptional(gpa, io, t.ours.dir, path);
            defer if (b) |bytes| gpa.free(bytes);
            expectOptional(a, b) catch |err| {
                std.debug.print("{s} differs\n", .{path});
                return err;
            };
        }
        const commands = [_][]const []const u8{
            &.{ "ls-files", "-t" },
            &.{ "status", "--porcelain", "--untracked-files=all" },
            &.{ "sparse-checkout", "list" },
        };
        // `list` fails outside a sparse worktree, on both sides alike.
        t.theirs.report_failures = false;
        t.ours.report_failures = false;
        defer t.theirs.report_failures = true;
        defer t.ours.report_failures = true;
        for (commands) |args| {
            const a = t.theirs.run(io, args) catch |err| switch (err) {
                error.GitFailed => null,
                else => |e| return e,
            };
            defer if (a) |bytes| gpa.free(bytes);
            const b = t.ours.run(io, args) catch |err| switch (err) {
                error.GitFailed => null,
                else => |e| return e,
            };
            defer if (b) |bytes| gpa.free(bytes);
            expectOptional(a, b) catch |err| {
                std.debug.print("git {s} differs\n", .{args[0]});
                return err;
            };
        }
        const a = try listFiles(gpa, io, t.theirs.dir);
        defer gpa.free(a);
        const b = try listFiles(gpa, io, t.ours.dir);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(a, b);
    }
};

fn readOptional(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
}

fn expectOptional(a: ?[]const u8, b: ?[]const u8) !void {
    if (a == null or b == null) return std.testing.expectEqual(a == null, b == null);
    try std.testing.expectEqualStrings(a.?, b.?);
}

/// Every file under the working tree outside `.git`, one path to a line,
/// sorted.
fn listFiles(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.path, ".git")) continue;
        if (entry.kind == .directory) continue;
        const path = try gpa.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        try paths.append(gpa, path);
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths.items) |p| {
        try out.appendSlice(gpa, p);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn setupTree(repo: *testgit.Repo, io: Io) anyerror!void {
    for ([_][]const u8{
        "top.txt",      "A/a.txt",   "A/B/b.txt", "A/B/C/c.txt",
        "D/d.txt",      "E/F/f.txt", "E/e.txt",   "g[1]/y.txt",
        "sp ace/z.txt",
    }) |path| try repo.writeFile(io, path, path);
    try repo.exec(io, &.{ "add", "-A" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "one" });
}

test "set, add, reapply and disable leave what git's own commands leave" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var twin = try Twin.init(gpa, io, &.{}, setupTree);
    defer twin.deinit();

    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        const out = try set(&repo, io, &.{ "A/B", "E", "./D/../g[1]//" }, .{ .skip_checks = true });
        try std.testing.expect(out.index_written);
        try std.testing.expect(out.update.skipped > 0);
    }
    // git's own checks refuse `g[1]` without --skip-checks, so git is told
    // to skip them too.
    try twin.git(io, &.{ "set", "--skip-checks", "A/B", "E", "./D/../g[1]//" });
    try twin.expectSame(io);

    try twin.git(io, &.{ "add", "D", "A/B/C" });
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        _ = try add(&repo, io, &.{ "D", "A/B/C" }, .{});
    }
    try twin.expectSame(io);

    try twin.git(io, &.{ "set", "--no-cone", "A/*.txt", "!A/B/", "/sp ace/" });
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        _ = try set(&repo, io, &.{ "A/*.txt", "!A/B/", "/sp ace/" }, .{ .cone = false });
    }
    try twin.expectSame(io);

    try twin.git(io, &.{ "add", "/top.txt" });
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        _ = try add(&repo, io, &.{"/top.txt"}, .{});
    }
    try twin.expectSame(io);

    try twin.git(io, &.{"reapply"});
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        _ = try reapply(&repo, io, .{});
    }
    try twin.expectSame(io);

    try twin.git(io, &.{ "reapply", "--cone" });
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        _ = try reapply(&repo, io, .{ .cone = true });
    }
    try twin.expectSame(io);

    try twin.git(io, &.{"disable"});
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        const out = try disable(&repo, io);
        try std.testing.expect(out.update.restored > 0);
    }
    try twin.expectSame(io);

    try twin.git(io, &.{ "init", "--no-sparse-index" });
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        _ = try init(&repo, io, .{ .sparse_index = false });
    }
    try twin.expectSame(io);
}

test "a list is git's list, in both modes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var twin = try Twin.init(gpa, io, &.{}, setupTree);
    defer twin.deinit();

    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        try std.testing.expectError(error.NotSparse, list(&repo, io));
        _ = try set(&repo, io, &.{ "E/F", "A" }, .{});
        var listing = try list(&repo, io);
        defer listing.deinit();
        try std.testing.expect(listing.cone);
        try std.testing.expectEqual(@as(usize, 2), listing.entries.len);
        try std.testing.expectEqualStrings("A", listing.entries[0]);
        try std.testing.expectEqualStrings("E/F", listing.entries[1]);
    }
    const git_list = try twin.ours.run(io, &.{ "sparse-checkout", "list" });
    defer gpa.free(git_list);
    try std.testing.expectEqualStrings("A\nE/F\n", git_list);

    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        _ = try set(&repo, io, &.{ "/*", "!D/" }, .{ .cone = false });
        var listing = try list(&repo, io);
        defer listing.deinit();
        try std.testing.expect(!listing.cone);
        try std.testing.expectEqual(@as(usize, 2), listing.entries.len);
        try std.testing.expectEqualStrings("!D/", listing.entries[1]);
    }
    const git_patterns = try twin.ours.run(io, &.{ "sparse-checkout", "list" });
    defer gpa.free(git_patterns);
    try std.testing.expectEqualStrings("/*\n!D/\n", git_patterns);
}

test "a dirty file stays, and a file in the way is not written over" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var twin = try Twin.init(gpa, io, &.{}, setupTree);
    defer twin.deinit();

    for ([_]*testgit.Repo{ &twin.theirs, &twin.ours }) |r| {
        try r.writeFile(io, "D/d.txt", "changed and not staged\n");
    }
    try twin.git(io, &.{ "set", "A" });
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        const out = try set(&repo, io, &.{"A"}, .{});
        try std.testing.expectEqual(@as(u32, 1), out.update.kept_dirty);
    }
    try twin.expectSame(io);

    for ([_]*testgit.Repo{ &twin.theirs, &twin.ours }) |r| {
        try r.writeFile(io, "E/e.txt", "an untracked file where a tracked one returns\n");
    }
    try twin.git(io, &.{ "add", "E" });
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        const out = try add(&repo, io, &.{"E"}, .{});
        try std.testing.expectEqual(@as(u32, 1), out.update.already_present);
    }
    try twin.expectSame(io);
}

test "cone-mode paths that are patterns or files are refused unless checks are skipped" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireCurrentGit(gpa, io);
    var repo_git = try testgit.Repo.init(gpa, io, &.{});
    defer repo_git.deinit();
    try setupTree(&repo_git, io);

    var repo = try Repository.open(gpa, io, repo_git.dir, .{});
    defer repo.deinit(io);
    try std.testing.expectError(error.NotSparse, add(&repo, io, &.{"A"}, .{}));
    try std.testing.expectError(error.PathIsAFile, set(&repo, io, &.{"top.txt"}, .{}));
    try std.testing.expectError(error.PatternNotADirectory, set(&repo, io, &.{"A*"}, .{}));
    try std.testing.expectError(error.PatternNotADirectory, set(&repo, io, &.{"/A"}, .{}));
    try std.testing.expectError(error.PatternNotADirectory, set(&repo, io, &.{"!A"}, .{}));
    try std.testing.expectError(error.PathOutsideWorktree, set(&repo, io, &.{"../A"}, .{}));
    _ = try set(&repo, io, &.{"top.txt"}, .{ .skip_checks = true });
    const text = try repo_git.readFile(io, ".git/info/sparse-checkout");
    defer gpa.free(text);
    try std.testing.expectEqualStrings("/*\n!/*/\n/top.txt/\n", text);
}

test "a branch with no commit gets the root-only patterns and no index" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var twin = try Twin.init(gpa, io, &.{}, struct {
        fn setup(_: *testgit.Repo, _: Io) anyerror!void {}
    }.setup);
    defer twin.deinit();

    try twin.git(io, &.{"init"});
    {
        var repo = try twin.open(io);
        defer repo.deinit(io);
        const out = try init(&repo, io, .{});
        try std.testing.expect(!out.index_written);
    }
    try twin.expectSame(io);
}

test "a linked worktree gets its own patterns and its own configuration" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var twin = try Twin.init(gpa, io, &.{}, struct {
        fn setup(r: *testgit.Repo, i: Io) anyerror!void {
            try setupTree(r, i);
            try r.exec(i, &.{ "worktree", "add", "-q", "linked" });
        }
    }.setup);
    defer twin.deinit();

    try twin.theirs.exec(io, &.{ "-C", "linked", "sparse-checkout", "set", "A" });
    {
        var linked = try twin.ours.dir.openDir(io, "linked", .{ .iterate = true });
        defer linked.close(io);
        var repo = try Repository.open(gpa, io, linked, .{});
        defer repo.deinit(io);
        _ = try set(&repo, io, &.{"A"}, .{});
    }
    for ([_][]const u8{
        ".git/config",
        ".git/config.worktree",
        ".git/worktrees/linked/config.worktree",
        ".git/worktrees/linked/info/sparse-checkout",
        ".git/info/sparse-checkout",
    }) |path| {
        const a = try readOptional(gpa, io, twin.theirs.dir, path);
        defer if (a) |bytes| gpa.free(bytes);
        const b = try readOptional(gpa, io, twin.ours.dir, path);
        defer if (b) |bytes| gpa.free(bytes);
        expectOptional(a, b) catch |err| {
            std.debug.print("{s} differs\n", .{path});
            return err;
        };
    }
    const a = try twin.theirs.run(io, &.{ "-C", "linked", "ls-files", "-t" });
    defer gpa.free(a);
    const b = try twin.ours.run(io, &.{ "-C", "linked", "ls-files", "-t" });
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "a bare repository's core.bare moves where git moves it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var twin = try Twin.init(gpa, io, &.{"--bare"}, struct {
        fn setup(r: *testgit.Repo, i: Io) anyerror!void {
            try r.exec(i, &.{ "worktree", "add", "-q", "--orphan", "-b", "main", "linked" });
            try r.writeFile(i, "linked/A/a.txt", "a\n");
            try r.writeFile(i, "linked/top.txt", "top\n");
            try r.exec(i, &.{ "-C", "linked", "add", "-A" });
            try r.exec(i, &.{ "-C", "linked", "commit", "-q", "-m", "one" });
        }
    }.setup);
    defer twin.deinit();

    try twin.theirs.exec(io, &.{ "-C", "linked", "sparse-checkout", "set", "--cone" });
    {
        var linked = try twin.ours.dir.openDir(io, "linked", .{ .iterate = true });
        defer linked.close(io);
        var repo = try Repository.open(gpa, io, linked, .{});
        defer repo.deinit(io);
        _ = try set(&repo, io, &.{}, .{ .cone = true });
    }
    for ([_][]const u8{ "config", "config.worktree", "worktrees/linked/config.worktree" }) |path| {
        const a = try readOptional(gpa, io, twin.theirs.dir, path);
        defer if (a) |bytes| gpa.free(bytes);
        const b = try readOptional(gpa, io, twin.ours.dir, path);
        defer if (b) |bytes| gpa.free(bytes);
        expectOptional(a, b) catch |err| {
            std.debug.print("{s} differs\n", .{path});
            return err;
        };
    }
}
