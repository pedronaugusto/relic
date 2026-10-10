//! `git clean`: the untracked files of a working tree removed, the ones git
//! removes for the same options, with the lines git prints.
//!
//! The walk is git's `fill_directory` with the flags `git clean` sets: an
//! untracked directory is one entry unless it holds something ignored that
//! is to be kept, a directory with tracked files in it is entered, a
//! repository inside the working tree is passed over unless `force` is
//! `.nested_repositories` (git's `-ff`), and with `ignored = .only` (`-X`)
//! only ignored paths are taken. `excludes` (`-e`) are ignore rules above
//! every other, and with `ignored = .too` (`-x`) they are the only ones.
//! Pathspecs are git's (`pathspec.zig`) and imply `directories`, as they
//! do in git.
//!
//! Each removal is reported as git prints it, `Removing <path>` or, on a
//! dry run, `Would remove <path>`, and a repository left in place as
//! `Skipping repository <path>`. git takes a directory's entries in the
//! order the filesystem gives them; this takes them in name order, so the
//! lines inside one directory can come in another order than git's on a
//! filesystem that does not sort. git also refuses to remove the process's
//! current directory; this does too, and says so as git does.
//!
//! What git does that this does not offer: `-i` (interactive), which is a
//! terminal conversation and not a library call.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const repo_mod = @import("repo/repo.zig");
const index_mod = @import("index/index.zig");
const ignore = @import("patterns.zig").ignore;
const pathspec_mod = @import("patterns.zig").pathspec;
const gitlink = @import("discover.zig").gitlink;
const dirscan = @import("checkout/dirscan.zig");
const cquote = @import("text.zig").cquote;
const config_core = @import("config/config.zig");
const fs = @import("fs/fs.zig");

const Repository = repo_mod.Repository;
const Index = index_mod.Index;

/// Errors from a clean. A path that will not go is not one: it is a
/// `Failure` in the outcome, and the clean goes on, as git's does.
pub const Error = error{
    /// `clean.requireForce` is on, which it is unless set otherwise, and
    /// neither `force` nor `dry_run` was given: git's "refusing to clean".
    ForceRequired,
    /// A bare repository has no working tree to clean.
    BareRepository,
    /// A directory nested deeper than a walk goes.
    TreeTooDeep,
} || pathspec_mod.Error || index_mod.ReadError || repo_mod.Error || ignore.Error || dirscan.Error ||
    gitlink.Error || Io.Writer.Error || config_core.ValueError;

/// What happens to ignored paths: kept (the default), removed with the
/// untracked ones (`-x`), or the only ones removed (`-X`).
pub const Ignored = enum { keep, too, only };

/// How much `-f` was given.
pub const Force = enum {
    /// None: a clean that is not a dry run then needs
    /// `clean.requireForce` off.
    no,
    /// `-f`.
    yes,
    /// `-ff`: repositories inside the working tree go too.
    nested_repositories,
};

/// What a clean removes.
pub const Options = struct {
    /// `-n`: report what would go and remove nothing.
    dry_run: bool = false,
    force: Force = .no,
    /// `-d`: untracked directories go too, not only files.
    directories: bool = false,
    ignored: Ignored = .keep,
    /// `-e`: ignore patterns that take precedence over every ignore file.
    excludes: []const []const u8 = &.{},
    /// Only paths these name. Any pathspec at all implies `directories`.
    pathspecs: []const []const u8 = &.{},
    /// Where git's lines go; `null` prints nothing, which is `-q`.
    out: ?*Io.Writer = null,
    /// `core.quotePath` for the printed names; `null` reads it.
    quote_path: ?bool = null,
};

/// What one printed line was about.
pub const Kind = enum {
    /// Removed, or would be: `Removing` or `Would remove`.
    removed,
    /// A repository inside the working tree, left in place.
    skipped_repository,
    /// The process's current directory, left in place.
    skipped_current_directory,
};

/// One line of the report, its path unquoted. A directory removed whole
/// is one entry ending in `/` when it was named at the top, as git prints
/// it.
pub const Report = struct {
    path: []const u8,
    kind: Kind,
};

/// A path that would not go.
pub const Failure = struct {
    path: []const u8,
    err: RemoveError,
};

/// Why a path would not go.
pub const RemoveError = Io.Dir.DeleteFileError || Io.Dir.DeleteDirError || Io.Dir.OpenError || fs.StatError;

/// What a clean did.
pub const Outcome = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    /// In the order git prints them.
    reports: []const Report,
    failures: []const Failure,

    pub fn deinit(o: *Outcome) void {
        o.arena.deinit();
        o.* = undefined;
    }
};

/// Remove the untracked files of `repo`'s working tree that `options`
/// name.
pub fn clean(gpa: Allocator, io: Io, repo: *Repository, options: Options) Self.Error!Outcome {
    const wt = repo.workDirectory() orelse return error.BareRepository;
    const config = repo.configuration();
    if (try config.getBool("clean.requireforce", true) and options.force == .no and !options.dry_run)
        return error.ForceRequired;
    const quote_fully = options.quote_path orelse try config.getBool("core.quotepath", true);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var index = try repo.openIndex(io);
    defer index.deinit();

    var standard: ?ignore.Rules = if (options.ignored != .too) try repo.loadIgnore(io) else null;
    defer if (standard) |*r| r.deinit();
    const case_fold = try config.getBool("core.ignorecase", false);
    var command_line = try ignore.Rules.init(gpa, .{ .case_fold = case_fold });
    defer command_line.deinit();
    for (options.excludes) |pattern| {
        try command_line.addText(try a.dupe(u8, pattern), "", "--exclude option", 0);
    }

    var spec = try pathspec_mod.parse(gpa, options.pathspecs);
    defer spec.deinit();

    const directories = options.directories or options.pathspecs.len > 0;
    const show_ignored = options.ignored == .only;
    const show_ignored_too = directories and !show_ignored;
    var walk: Walk = .{
        .gpa = gpa,
        .a = a,
        .io = io,
        .wt = wt,
        .index = &index,
        .standard = if (standard) |*r| r else null,
        .command_line = &command_line,
        .spec = if (options.pathspecs.len > 0) &spec else null,
        .case_fold = case_fold,
        .show_ignored = show_ignored,
        .show_ignored_too = show_ignored_too,
        .mode_matching = show_ignored_too and options.ignored == .keep,
        .skip_nested = options.force != .nested_repositories,
    };
    defer walk.entries.deinit(gpa);
    defer walk.ignored.deinit(gpa);
    _ = try walk.readDirectory("", 0, false);
    std.mem.sort([]const u8, walk.entries.items, {}, lessThan);
    std.mem.sort([]const u8, walk.ignored.items, {}, lessThan);
    walk.correctUntracked();

    var remover: Remover = .{
        .a = a,
        .io = io,
        .wt = wt,
        .dry_run = options.dry_run,
        .keep_nested = options.force != .nested_repositories,
        .out = options.out,
        .quote_fully = quote_fully,
        .cwd = cwdUnder(a, io, wt),
    };
    for (walk.entries.items) |name| {
        if (!walk.isOther(name)) continue;
        const bare = std.mem.trimEnd(u8, name, "/");
        const found = (fs.statAt(io, wt, bare) catch |err| {
            try remover.failures.append(a, .{ .path = name, .err = err });
            continue;
        }) orelse continue;
        if (found.kind == .directory and !directories) continue;
        if (found.kind == .directory) {
            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(a, name);
            var gone = true;
            try remover.removeDirectory(&path, &gone, 0);
            if (gone) try remover.report(name, .removed);
        } else {
            if (!options.dry_run) fs.deleteFile(io, wt, bare) catch |err| {
                try remover.failures.append(a, .{ .path = name, .err = err });
                continue;
            };
            try remover.report(name, .removed);
        }
    }
    return .{ .arena = arena, .reports = remover.reports.items, .failures = remover.failures.items };
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// git's `path_treatment`, in its order: a directory's state is the
/// strongest of its entries'.
const State = enum(u2) { none, recurse, excluded, untracked };

fn max(x: State, y: State) State {
    return if (@backingInt(y) > @backingInt(x)) y else x;
}

const Treated = struct { state: State, excluded: bool };

/// git's `read_directory` with the flags `git clean` sets: always
/// `DIR_SHOW_OTHER_DIRECTORIES`, never `DIR_HIDE_EMPTY_DIRECTORIES`.
const Walk = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    wt: Io.Dir,
    index: *Index,
    standard: ?*ignore.Rules,
    command_line: *ignore.Rules,
    spec: ?*const pathspec_mod.Pathspec,
    case_fold: bool,
    /// `DIR_SHOW_IGNORED`: ignored paths are the entries (`-X`).
    show_ignored: bool,
    /// `DIR_SHOW_IGNORED_TOO`: ignored paths are collected beside the
    /// untracked ones, so a directory holding one is not taken whole.
    show_ignored_too: bool,
    /// `DIR_SHOW_IGNORED_TOO_MODE_MATCHING`: an ignored directory is not
    /// entered.
    mode_matching: bool,
    /// `DIR_SKIP_NESTED_GIT`.
    skip_nested: bool,
    entries: std.ArrayList([]const u8) = .empty,
    ignored: std.ArrayList([]const u8) = .empty,

    fn readDirectory(w: *Walk, base: []const u8, depth: u32, excluded: bool) Error!State {
        if (depth > 256) return error.TreeTooDeep;
        var dir = if (base.len == 0) w.wt else w.wt.openDir(w.io, base, .{ .iterate = true }) catch return .none;
        defer if (base.len != 0) dir.close(w.io);
        // Inside an excluded directory everything is excluded, and its own
        // ignore file is not read: git's `prep_exclude`.
        if (w.standard) |rules| if (!excluded) try rules.addDirectory(w.io, w.wt, base, depth);
        defer if (w.standard) |rules| if (!excluded) rules.popTo(depth + 2);

        var names: std.ArrayList(Named) = .empty;
        defer {
            for (names.items) |n| w.gpa.free(n.name);
            names.deinit(w.gpa);
        }
        {
            var scan = try dirscan.Scan.init(w.gpa, w.io, dir);
            defer scan.deinit();
            while (try scan.next()) |item| {
                const name = try w.gpa.dupe(u8, item.name);
                errdefer w.gpa.free(name);
                try names.append(w.gpa, .{ .name = name, .kind = item.entry.kind });
            }
        }
        std.mem.sort(Named, names.items, {}, Named.lessThan);

        var dir_state: State = .none;
        for (names.items) |item| {
            const path = if (base.len == 0)
                try w.a.dupe(u8, item.name)
            else
                try w.a.print("{s}/{s}", .{ base, item.name });
            const treated = try w.treatPath(path, item.name, item.kind, excluded);
            dir_state = max(dir_state, treated.state);
            if (treated.state == .recurse) {
                dir_state = max(dir_state, try w.readDirectory(path, depth + 1, treated.excluded));
                continue;
            }
            const listed = if (item.kind == .directory) try w.a.print("{s}/", .{path}) else path;
            try w.add(listed, treated.state);
        }
        return dir_state;
    }

    const Named = struct {
        name: []u8,
        kind: Io.File.Kind,
        fn lessThan(_: void, x: Named, y: Named) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    };

    /// git's `add_path_to_appropriate_result_list`.
    fn add(w: *Walk, path: []const u8, state: State) Allocator.Error!void {
        switch (state) {
            .excluded => if (w.show_ignored) {
                if (!w.inIndex(path)) try w.entries.append(w.gpa, path);
            } else if (w.show_ignored_too) {
                if (w.isOther(path)) try w.ignored.append(w.gpa, path);
            },
            .untracked => if (!w.show_ignored) {
                if (!w.inIndex(path)) try w.entries.append(w.gpa, path);
            },
            else => {},
        }
    }

    /// git's `treat_path`.
    fn treatPath(w: *Walk, path: []const u8, name: []const u8, kind: Io.File.Kind, parent_excluded: bool) Error!Treated {
        const none: Treated = .{ .state = .none, .excluded = false };
        const is_dot_git = if (w.case_fold) std.ascii.eqlIgnoreCase(name, ".git") else std.mem.eql(u8, name, ".git");
        if (is_dot_git) return none;
        if (w.spec) |spec| if (spec.simplifyAway(path)) return none;
        const is_dir = kind == .directory;
        if (!is_dir and w.inIndex(path)) return none;
        const excluded = parent_excluded or w.isExcluded(path, is_dir);
        if (excluded and !(w.show_ignored or w.show_ignored_too)) return .{ .state = .excluded, .excluded = true };
        switch (kind) {
            .directory => return .{ .state = try w.treatDirectory(path, excluded), .excluded = excluded },
            .file, .sym_link => {
                if (w.spec) |spec| if (spec.how(path, .{}) == .none) return none;
                return .{ .state = if (excluded) .excluded else .untracked, .excluded = excluded };
            },
            else => return none,
        }
    }

    /// git's `treat_directory`. `path` has no trailing slash; git's has.
    fn treatDirectory(w: *Walk, path: []const u8, excluded: bool) Error!State {
        switch (w.inIndexAsDirectory(path)) {
            .directory => return .recurse,
            .gitlink => return .none,
            .absent => {},
        }
        var how: pathspec_mod.How = .none;
        if (w.spec) |spec| if (!excluded) {
            const slashed = try w.a.print("{s}/", .{path});
            how = spec.how(slashed, .{ .leading = true });
            if (how == .none) return .none;
        };
        if (try gitlink.isRepository(w.gpa, w.io, w.wt, path)) {
            if (w.skip_nested or how == .leading) return .none;
            return if (excluded) .excluded else .untracked;
        }
        if (how == .leading) return .recurse;
        if (excluded) return .excluded;
        if (!(w.show_ignored or w.show_ignored_too)) return .untracked;

        const ignored_before = w.ignored.items.len;
        var state = try w.readDirectory(path, depthOf(path), false);
        if (state == .excluded) {
            // Everything in it is ignored: with ignored directories not
            // entered, the paths in it are what count; otherwise the
            // directory stands for them.
            if (w.show_ignored_too and w.mode_matching) {
                state = .none;
            } else {
                w.ignored.shrinkRetainingCapacity(ignored_before);
            }
        }
        if (state == .none) state = .untracked;
        return state;
    }

    fn depthOf(path: []const u8) u32 {
        return @intCast(std.mem.countScalar(u8, path, '/') + 1);
    }

    fn isExcluded(w: *Walk, path: []const u8, is_dir: bool) bool {
        // the command line's patterns decide first, whichever way they go
        const by_command = w.command_line.match(path, is_dir);
        if (by_command.by != null) return by_command.excluded;
        if (w.standard) |rules| return rules.match(path, is_dir).excluded;
        return false;
    }

    /// git's `index_file_exists`: an entry at any stage is `path` itself.
    fn inIndex(w: *const Walk, path: []const u8) bool {
        for (0..4) |stage| {
            if (w.index.findStage(path, @intCast(stage)) != null) return true;
        }
        return false;
    }

    /// git's `index_name_is_other`: neither in the index nor unmerged
    /// there, a trailing slash aside.
    fn isOther(w: *const Walk, path: []const u8) bool {
        return !w.inIndex(std.mem.trimEnd(u8, path, "/"));
    }

    const InIndex = enum { absent, directory, gitlink };

    /// git's `directory_exists_in_index`.
    fn inIndexAsDirectory(w: *const Walk, path: []const u8) InIndex {
        const entries = w.index.items();
        var lo: usize = 0;
        var hi: usize = entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, entries[mid].path, path) == .lt) lo = mid + 1 else hi = mid;
        }
        for (entries[lo..]) |entry| {
            if (!std.mem.startsWith(u8, entry.path, path)) break;
            const end: u8 = if (entry.path.len > path.len) entry.path[path.len] else 0;
            if (end > '/') break;
            if (end == '/') return .directory;
            if (end == 0 and entry.mode == .gitlink) return .gitlink;
        }
        return .absent;
    }

    /// git's `correct_untracked_entries`: a directory holding an ignored
    /// path is not taken whole, and a directory that is taken whole takes
    /// the entries inside it with it.
    fn correctUntracked(w: *Walk) void {
        const entries = w.entries.items;
        const ignored = w.ignored.items;
        var src: usize = 0;
        var dst: usize = 0;
        var ign: usize = 0;
        while (src < entries.len) {
            while (ign < ignored.len and std.mem.order(u8, entries[src], ignored[ign]) != .lt) ign += 1;
            if (ign < ignored.len and contains(entries[src], ignored[ign])) {
                src += 1;
                continue;
            }
            const kept = entries[src];
            entries[dst] = kept;
            dst += 1;
            src += 1;
            while (src < entries.len and contains(kept, entries[src])) src += 1;
        }
        w.entries.shrinkRetainingCapacity(dst);
    }

    fn contains(outer: []const u8, inner: []const u8) bool {
        return outer.len < inner.len and outer[outer.len - 1] == '/' and std.mem.startsWith(u8, inner, outer);
    }
};

/// The process's current directory when it lies in the working tree, as a
/// path below it; git will not remove it.
fn cwdUnder(a: Allocator, io: Io, wt: Io.Dir) ?[]const u8 {
    const cwd = std.process.currentPathAlloc(io, a) catch return null;
    const top = wt.realPathFileAlloc(io, ".", a) catch return null;
    if (std.mem.eql(u8, cwd, top)) return "";
    if (cwd.len > top.len and std.mem.startsWith(u8, cwd, top) and std.Io.Dir.path.isSep(cwd[top.len])) {
        const rest = a.dupe(u8, cwd[top.len + 1 ..]) catch return null;
        if (std.Io.Dir.path.sep != '/') std.mem.replaceScalar(u8, rest, std.Io.Dir.path.sep, '/');
        return rest;
    }
    return null;
}

/// git's `remove_dirs`, and the printing around it.
const Remover = struct {
    a: Allocator,
    io: Io,
    wt: Io.Dir,
    dry_run: bool,
    keep_nested: bool,
    out: ?*Io.Writer,
    quote_fully: bool,
    cwd: ?[]const u8,
    reports: std.ArrayList(Report) = .empty,
    failures: std.ArrayList(Failure) = .empty,

    fn report(r: *Remover, path: []const u8, kind: Kind) Error!void {
        try r.reports.append(r.a, .{ .path = try r.a.dupe(u8, path), .kind = kind });
        const w = r.out orelse return;
        switch (kind) {
            .removed => try w.writeAll(if (r.dry_run) "Would remove " else "Removing "),
            .skipped_repository => try w.writeAll(if (r.dry_run) "Would skip repository " else "Skipping repository "),
            .skipped_current_directory => {
                try w.writeAll(if (r.dry_run) "Would refuse to remove current working directory\n" else "Refusing to remove current working directory\n");
                return;
            },
        }
        try cquote.write(w, path, r.quote_fully);
        try w.writeByte('\n');
    }

    /// Remove the directory `path` and what is in it, leaving `gone`
    /// false when something stayed. What went is printed only then: a
    /// directory that went whole is printed by its parent, as one line.
    fn removeDirectory(r: *Remover, path: *std.ArrayList(u8), gone: *bool, depth: u32) Error!void {
        if (depth > 256) return error.TreeTooDeep;
        gone.* = true;
        const original_len = path.items.len;
        const bare = std.mem.trimEnd(u8, path.items, "/");
        if (r.keep_nested and try gitlink.isRepository(r.a, r.io, r.wt, bare)) {
            try r.report(path.items, .skipped_repository);
            gone.* = false;
            return;
        }
        var dir = r.wt.openDir(r.io, bare, .{ .iterate = true }) catch {
            // an empty directory can go even when it cannot be read
            if (!r.dry_run) r.wt.deleteDir(r.io, bare) catch |err| {
                try r.failures.append(r.a, .{ .path = try r.a.dupe(u8, path.items), .err = err });
                gone.* = false;
            };
            return;
        };
        var names: std.ArrayList([]const u8) = .empty;
        {
            defer dir.close(r.io);
            var it = dir.iterate();
            while (it.next(r.io) catch null) |entry| try names.append(r.a, try r.a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);

        if (path.items.len == 0 or path.items[path.items.len - 1] != '/') try path.append(r.a, '/');
        const len = path.items.len;
        var dels: std.ArrayList([]const u8) = .empty;
        for (names.items) |name| {
            path.shrinkRetainingCapacity(len);
            try path.appendSlice(r.a, name);
            const found = fs.statAt(r.io, r.wt, path.items) catch |err| {
                try r.failures.append(r.a, .{ .path = try r.a.dupe(u8, path.items), .err = err });
                gone.* = false;
                break;
            } orelse continue;
            if (found.kind == .directory) {
                var child_gone = true;
                try r.removeDirectory(path, &child_gone, depth + 1);
                if (child_gone) try dels.append(r.a, try r.a.dupe(u8, path.items)) else gone.* = false;
                continue;
            }
            if (!r.dry_run) fs.deleteFile(r.io, r.wt, path.items) catch |err| {
                try r.failures.append(r.a, .{ .path = try r.a.dupe(u8, path.items), .err = err });
                gone.* = false;
                continue;
            };
            try dels.append(r.a, try r.a.dupe(u8, path.items));
        }
        path.shrinkRetainingCapacity(original_len);
        const here = std.mem.trimEnd(u8, path.items, "/");

        if (gone.*) {
            if (r.cwd) |cwd| if (std.mem.eql(u8, cwd, here)) {
                try r.report("", .skipped_current_directory);
                gone.* = false;
            };
        }
        if (gone.* and !r.dry_run) r.wt.deleteDir(r.io, here) catch |err| {
            try r.failures.append(r.a, .{ .path = try r.a.dupe(u8, path.items), .err = err });
            gone.* = false;
        };
        if (!gone.*) for (dels.items) |d| try r.report(d, .removed);
    }
};
