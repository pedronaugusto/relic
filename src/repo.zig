//! The front door: open or create a repository and reach everything in it.
//!
//! A repository is a local directory. Nothing here talks to a network, runs
//! another program, or reads a clock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("reflog.zig");
const config_mod = @import("config.zig");
const ignore = @import("ignore.zig");
const attributes = @import("attributes.zig");
const worktree = @import("worktree.zig");
const worktrees = @import("worktrees.zig");
const filter = @import("filter.zig");
const reftablestack = @import("reftablestack.zig");
const fs = @import("fs.zig");
const safepath = @import("safepath.zig");
const program = @import("program.zig");
const hooks = @import("hooks.zig");
const signing = @import("signing.zig");

const Oid = hash.Oid;

/// Errors from opening or creating a repository.
pub const Error = error{
    /// No `.git` directory or file at the path or above it.
    NotARepository,
    /// `core.repositoryFormatVersion` is a number this release does not
    /// know. `unsupported` on the repository says which.
    UnsupportedRepositoryVersion,
    /// An `extensions.*` this release does not implement, at format version
    /// 1 where git requires every extension to be understood.
    /// `unsupported` names it.
    UnsupportedExtension,
    /// `extensions.refStorage` names a format other than `files` and
    /// `reftable`. The refs are somewhere this release does not read, and
    /// reporting the repository as having none would be worse than refusing
    /// it.
    UnsupportedRefStorage,
    /// `extensions.objectFormat` names a hash this release does not have.
    UnknownObjectFormat,
    /// The `.git` file's `gitdir:` line points nowhere.
    BrokenGitFile,
    /// `init` was given a path that already holds a repository.
    RepositoryExists,
    /// Peeling crossed the maximum annotated-tag chain without reaching a
    /// non-tag object.
    TagDepthExceeded,
    /// The configuration read again by `refreshConfig` names another hash
    /// than the one the repository was opened with. Every object name it
    /// holds would change, so it is opened again rather than refreshed.
    ObjectFormatChanged,
} || object.ParseError || Allocator.Error || Io.Dir.OpenError || Io.Dir.ReadFileAllocError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.WriteFileError ||
    Io.File.OpenError || Io.Writer.Error || Io.File.SyncError ||
    config_mod.ParseError || config_mod.ValueError || odb_mod.Error ||
    refs_mod.ReadError || refs_mod.TransactionError || worktrees.Error;

/// Errors from writing a commit or a tag, which may be signed.
pub const WriteError = Error || signing.Error;

/// How deep `open` walks upwards looking for a `.git`.
pub const max_discovery_depth: u8 = 64;

/// How a repository is created.
pub const InitOptions = struct {
    /// The hash every object name is written with.
    object_format: hash.Kind = .sha1,
    /// The branch `HEAD` points at before the first commit. git's own
    /// default comes from `init.defaultBranch`, which this package does not
    /// read because it reads no environment; the caller passes it.
    default_branch: []const u8 = "main",
    /// A repository with no working tree.
    bare: bool = false,
    /// Whether `core.filemode` is recorded as true. The caller decides,
    /// because probing means writing a file.
    file_mode: bool = Io.File.Permissions.has_executable_bit,
    /// What the object database is opened with, including whether every
    /// SHA-1 name it takes is checked for a collision attack.
    odb: odb_mod.Options = .{},
    /// Where the refs are kept: loose files and `packed-refs`, or a
    /// reftable stack, which is `git init --ref-format=reftable` and which
    /// git 3.0 makes the default.
    ref_format: refs_mod.Format = .files,
};

/// An open repository.
pub const Repository = struct {
    gpa: Allocator,
    /// The per-worktree directory: `.git`, or a linked worktree's
    /// administrative directory.
    git_dir: Io.Dir,
    /// The shared directory: the same as `git_dir` in a repository with no
    /// linked worktrees, and the main `.git` otherwise.
    common_dir: Io.Dir,
    /// The working tree, or `null` in a bare repository.
    work_dir: ?Io.Dir,
    /// Whether `common_dir` is a separate handle that must be closed.
    common_is_separate: bool,
    /// The hash this repository's object names are written with.
    kind: hash.Kind,
    /// What the configuration files held at `open`, or when `refreshConfig`
    /// last found one changed. Nothing reads them again behind the caller's
    /// back, so another process's `git config` is seen after a
    /// `refreshConfig` and not before. The operations that read a file
    /// fresh from the disk are the ones that write it: a submodule's
    /// settings are edited in `.git/config` as read at that moment. An
    /// `includeIf` is decided against this repository's `.git` directory
    /// and the branch `HEAD` was on when the files were read.
    config: config_mod.Config,
    odb: odb_mod.Odb,
    refs: refs_mod.Store,
    /// The setting that caused `error.UnsupportedExtension`,
    /// `error.UnsupportedRepositoryVersion` or
    /// `error.SigningRequiresPrograms`, for a message. Empty otherwise.
    unsupported: [64]u8 = @splat(0),
    unsupported_len: usize = 0,

    /// Open the repository at `path`, or the first one above it.
    ///
    /// `path` may be the working tree, the `.git` directory, or a linked
    /// worktree. A `.git` *file* is followed, which is how a linked worktree
    /// is opened.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: OpenOptions) Error!Repository {
        var discovered = try discover(gpa, io, dir, options);
        errdefer discovered.close(io);
        return finish(gpa, io, discovered, options);
    }

    /// How a repository is opened.
    pub const OpenOptions = struct {
        /// Whether to walk upwards looking for a `.git`.
        discover: bool = true,
        /// What the object database is told.
        odb: odb_mod.Options = .{},
        /// A system-wide configuration file, if the caller wants one read.
        /// `refreshConfig` reads it again through the same directory, which
        /// therefore stays open while the repository does.
        system_config: ?config_mod.Sources.Path = null,
        /// A per-user configuration file, if the caller wants one read. Its
        /// directory stays open while the repository does, as the system
        /// one's does.
        global_config: ?config_mod.Sources.Path = null,
        /// The home directory, for `~/` in a config value or an
        /// `includeIf` condition. This package reads no environment, so the
        /// caller supplies it. The configuration keeps its own copy.
        home: ?[]const u8 = null,
        /// Values that beat every file, as `name=value`.
        config_overrides: []const []const u8 = &.{},
    };

    const Discovered = struct {
        git_dir: Io.Dir,
        common_dir: Io.Dir,
        work_dir: ?Io.Dir,
        common_is_separate: bool,

        fn close(d: *Discovered, io: Io) void {
            if (d.common_is_separate) d.common_dir.close(io);
            d.git_dir.close(io);
            if (d.work_dir) |w| w.close(io);
        }
    };

    fn discover(gpa: Allocator, io: Io, start: Io.Dir, options: OpenOptions) Error!Discovered {
        var current = start;
        var current_owned = false;
        var depth: u8 = 0;
        while (true) : (depth += 1) {
            if (depth > max_discovery_depth) break;

            // A `.git` directory here?
            if (current.openDir(io, ".git", .{ .iterate = true })) |git_dir| {
                const work = try current.openDir(io, ".", .{ .iterate = true });
                if (current_owned) current.close(io);
                return try withCommon(gpa, io, git_dir, work);
            } else |_| {}

            // A `.git` file, which is what a linked worktree has.
            if (try worktrees.readGitFile(gpa, io, current)) |target| {
                defer gpa.free(target);
                // A linked worktree's names its directory absolutely; a
                // submodule's names it relative to the file itself.
                const git_dir = (if (std.fs.path.isAbsolute(target))
                    Io.Dir.openDirAbsolute(io, target, .{ .iterate = true })
                else
                    current.openDir(io, target, .{ .iterate = true })) catch
                    return error.BrokenGitFile;
                const work = try current.openDir(io, ".", .{ .iterate = true });
                if (current_owned) current.close(io);
                return try withCommon(gpa, io, git_dir, work);
            }

            // The directory may itself be a git directory — a bare
            // repository, or `.git` handed in directly.
            if (looksLikeGitDir(io, current)) {
                const git_dir = try current.openDir(io, ".", .{ .iterate = true });
                if (current_owned) current.close(io);
                return try withCommon(gpa, io, git_dir, null);
            }

            if (!options.discover) break;
            const parent = current.openDir(io, "..", .{ .iterate = true }) catch break;
            // The walk stops when `..` is the same directory, which is the
            // filesystem root.
            if (sameDir(io, parent, current)) {
                parent.close(io);
                break;
            }
            if (current_owned) current.close(io);
            current = parent;
            current_owned = true;
        }
        if (current_owned) current.close(io);
        return error.NotARepository;
    }

    fn withCommon(gpa: Allocator, io: Io, git_dir: Io.Dir, work_dir: ?Io.Dir) Error!Discovered {
        // `commondir` makes this a linked worktree: everything shared lives
        // where it points.
        if (try fs.readFileAlloc(gpa, io, git_dir, "commondir", 4096)) |text| {
            defer gpa.free(text);
            const target = std.mem.trim(u8, text, " \t\r\n");
            if (git_dir.openDir(io, target, .{ .iterate = true })) |common| {
                return .{
                    .git_dir = git_dir,
                    .common_dir = common,
                    .work_dir = work_dir,
                    .common_is_separate = true,
                };
            } else |_| {}
        }
        return .{
            .git_dir = git_dir,
            .common_dir = git_dir,
            .work_dir = work_dir,
            .common_is_separate = false,
        };
    }

    fn looksLikeGitDir(io: Io, dir: Io.Dir) bool {
        dir.access(io, "HEAD", .{}) catch return false;
        dir.access(io, "objects", .{}) catch return false;
        dir.access(io, "refs", .{}) catch return false;
        return true;
    }

    fn sameDir(io: Io, a: Io.Dir, b: Io.Dir) bool {
        const sa = a.stat(io) catch return false;
        const sb = b.stat(io) catch return false;
        return sa.inode == sb.inode;
    }

    fn finish(gpa: Allocator, io: Io, discovered: Discovered, options: OpenOptions) Error!Repository {
        var repo: Repository = .{
            .gpa = gpa,
            .git_dir = discovered.git_dir,
            .common_dir = discovered.common_dir,
            .work_dir = discovered.work_dir,
            .common_is_separate = discovered.common_is_separate,
            .kind = .sha1,
            .config = .initEmpty(gpa),
            .odb = undefined,
            .refs = undefined,
        };

        // The configuration is read before anything else, because it says
        // which hash the object names are written with.
        // An `includeIf` asks where the `.git` directory is and which branch
        // `HEAD` is on, so both are known before the first file is read.
        var path_buffer: [4096]u8 = undefined;
        const git_dir_path = try absoluteGitDir(io, repo.git_dir, &path_buffer);
        const branch = try currentBranch(gpa, io, repo.git_dir);
        defer if (branch) |b| gpa.free(b);
        const read = try repo.readConfig(io, .{
            .system = options.system_config,
            .global = options.global_config,
            .local = .{ .dir = repo.common_dir, .sub_path = "config" },
            .command = options.config_overrides,
        }, .{ .git_dir = git_dir_path, .branch = if (branch) |b| b["refs/heads/".len..] else null, .home = options.home });
        repo.config = read.config;
        errdefer repo.config.deinit();
        repo.kind = read.kind;

        repo.odb = try odb_mod.Odb.open(gpa, io, repo.common_dir, repo.kind, options.odb);
        errdefer repo.odb.deinit(io);
        repo.refs = .init(gpa, repo.kind, repo.git_dir, repo.common_dir);
        const version = repo.config.getInt("core.repositoryformatversion", 0) catch 0;
        if (version == 1) {
            if (repo.config.get("extensions.refstorage")) |text| {
                if (std.ascii.eqlIgnoreCase(text, "reftable")) {
                    repo.refs.format = .reftable;
                    repo.refs.reftable_options = try repo.reftableOptions();
                }
            }
        }
        return repo;
    }

    /// Read `sources` — every one but the worktree's — and check the format
    /// they name; then, when `extensions.worktreeConfig` is on, read them
    /// again with `config.worktree` after the local file, which exists only
    /// when the extension says so and has no say in the format.
    fn readConfig(repo: *Repository, io: Io, sources: config_mod.Sources, context: config_mod.Context) Error!struct { config: config_mod.Config, kind: hash.Kind } {
        var config = try config_mod.Config.open(repo.gpa, io, sources, context);
        errdefer config.deinit();
        const kind = try repo.checkFormat(&config);
        if (!(config.getBool("extensions.worktreeconfig", false) catch false)) return .{ .config = config, .kind = kind };
        var with_worktree = sources;
        with_worktree.worktree = .{ .dir = repo.git_dir, .sub_path = "config.worktree" };
        const both = try config_mod.Config.open(repo.gpa, io, with_worktree, context);
        config.deinit();
        return .{ .config = both, .kind = kind };
    }

    /// The format version and the extensions `config` names, checked, and
    /// the hash it says object names are written with.
    fn checkFormat(repo: *Repository, config: *const config_mod.Config) Error!hash.Kind {
        const version = config.getInt("core.repositoryformatversion", 0) catch 0;
        if (version < 0 or version > 1) {
            repo.setUnsupported("core.repositoryFormatVersion");
            return error.UnsupportedRepositoryVersion;
        }
        if (version == 1) try repo.checkExtensions(config);
        const text = config.get("extensions.objectformat") orelse return .sha1;
        return hash.Kind.parse(text) catch error.UnknownObjectFormat;
    }

    /// Read the configuration again if a file it came from has changed since
    /// it was read, or `HEAD` is on another branch than it was, which an
    /// `includeIf "onbranch:"` depends on, and say whether it read it.
    ///
    /// A daemon holding a repository for days calls this where it wants
    /// another process's `git config` to count — before an operation, say —
    /// and it costs a read of each file the configuration came from,
    /// includes among them, and of `HEAD`, and a parse only when one
    /// differs. Edits made
    /// to `config` in memory and never written are replaced by what the
    /// files hold. A configuration that no longer passes `open`'s checks is
    /// that check's error, and the one held before is kept.
    pub fn refreshConfig(repo: *Repository, io: Io) Error!bool {
        // `onbranch:` makes the branch `HEAD` is on part of what was read.
        const branch = try currentBranch(repo.gpa, io, repo.git_dir);
        defer if (branch) |b| repo.gpa.free(b);
        const short = if (branch) |b| b["refs/heads/".len..] else null;
        const same_branch = if (repo.config.context.branch) |was|
            short != null and std.mem.eql(u8, was, short.?)
        else
            short == null;
        if (same_branch and !try repo.config.isStale(io)) return false;
        var sources = repo.config.sources;
        sources.worktree = null;
        var context = repo.config.context;
        context.branch = short;
        var fresh = try repo.readConfig(io, sources, context);
        errdefer fresh.config.deinit();
        if (fresh.kind != repo.kind) return error.ObjectFormatChanged;
        repo.config.deinit();
        repo.config = fresh.config;
        return true;
    }

    /// The `.git` directory's path as git matches it in a `gitdir:`
    /// condition: absolute, symbolic links resolved, `/`-separated.
    fn absoluteGitDir(io: Io, git_dir: Io.Dir, buffer: []u8) Error![]const u8 {
        const len = try git_dir.realPath(io, buffer);
        const path = buffer[0..len];
        if (@import("builtin").os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');
        return path;
    }

    /// The branch `HEAD` is on, as `refs/heads/<name>` and the caller's, or
    /// `null` when it is detached. An unborn branch counts, as it does for
    /// git's `onbranch:`.
    fn currentBranch(gpa: Allocator, io: Io, git_dir: Io.Dir) Error!?[]u8 {
        const text = (try fs.readFileAlloc(gpa, io, git_dir, "HEAD", 4096)) orelse return null;
        defer gpa.free(text);
        const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "ref:")) return null;
        const target = std.mem.trim(u8, trimmed["ref:".len..], " \t");
        // A reftable repository's `HEAD` file is a placeholder; `HEAD` is
        // in the stack, read before the configuration says which hash the
        // tables are written with, so each is tried.
        if (std.mem.eql(u8, target, "refs/heads/.invalid")) {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            for ([_]hash.Kind{ .sha1, .sha256 }) |kind| {
                const head_value = reftablestack.headIn(gpa, arena.allocator(), io, git_dir, kind) catch |err| switch (err) {
                    error.HashMismatch => continue,
                    else => return null,
                };
                const value = head_value orelse return null;
                switch (value) {
                    .direct => return null,
                    .symbolic => |name| {
                        if (!std.mem.startsWith(u8, name, "refs/heads/")) return null;
                        return try gpa.dupe(u8, name);
                    },
                }
            }
            return null;
        }
        if (!std.mem.startsWith(u8, target, "refs/heads/")) return null;
        return try gpa.dupe(u8, target);
    }

    /// The `reftable.*` settings, for the stack's writes and compactions.
    fn reftableOptions(repo: *const Repository) Error!reftablestack.Options {
        var options: reftablestack.Options = .{};
        const block_size = try repo.config.getInt("reftable.blocksize", options.write.block_size);
        if (block_size > 0 and block_size < (1 << 24)) options.write.block_size = @intCast(block_size);
        const restart = try repo.config.getInt("reftable.restartinterval", options.write.restart_interval);
        if (restart > 0 and restart <= std.math.maxInt(u16)) options.write.restart_interval = @intCast(restart);
        options.write.index_objects = try repo.config.getBool("reftable.indexobjects", true);
        const factor = try repo.config.getInt("reftable.geometricfactor", options.geometric_factor);
        if (factor > 0 and factor <= std.math.maxInt(u8)) options.geometric_factor = @intCast(factor);
        return options;
    }

    fn setUnsupported(repo: *Repository, text: []const u8) void {
        repo.unsupported_len = @min(text.len, repo.unsupported.len);
        @memcpy(repo.unsupported[0..repo.unsupported_len], text[0..repo.unsupported_len]);
    }

    /// The setting that was refused, or an empty string.
    pub fn unsupportedSetting(repo: *const Repository) []const u8 {
        return repo.unsupported[0..repo.unsupported_len];
    }

    /// The extensions this release understands at format version 1.
    ///
    /// Anything else is refused by name rather than ignored, which is what
    /// git's own format document requires: an extension exists precisely
    /// because a reader that does not know it would read the repository
    /// wrongly.
    const known_extensions = [_][]const u8{
        "noop",
        "noop-v1",
        "objectformat",
        "preciousobjects",
        "worktreeconfig",
        "relativeworktrees",
        "refstorage",
    };

    fn checkExtensions(repo: *Repository, config: *const config_mod.Config) Error!void {
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "extensions")) continue;
            var known = false;
            for (known_extensions) |name| {
                if (std.ascii.eqlIgnoreCase(entry.name, name)) known = true;
            }
            if (!known) {
                repo.setUnsupported(entry.name);
                return error.UnsupportedExtension;
            }
            if (std.ascii.eqlIgnoreCase(entry.name, "refstorage")) {
                const value = entry.value orelse "";
                if (!std.ascii.eqlIgnoreCase(value, "files") and !std.ascii.eqlIgnoreCase(value, "reftable")) {
                    repo.setUnsupported("extensions.refStorage");
                    return error.UnsupportedRefStorage;
                }
            }
        }
    }

    /// Create a repository at `dir`.
    ///
    /// Writes `HEAD`, `config`, `objects/`, `refs/heads`, `refs/tags` and
    /// `info/`, which is what a repository needs to be one.
    pub fn init(gpa: Allocator, io: Io, dir: Io.Dir, options: InitOptions) Error!Repository {
        const git_path = if (options.bare) "." else ".git";
        if (!options.bare) {
            dir.createDir(io, ".git", .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => return error.RepositoryExists,
                else => |e| return e,
            };
        } else if (looksLikeGitDir(io, dir)) {
            return error.RepositoryExists;
        }
        var git_dir = try dir.openDir(io, git_path, .{ .iterate = true });
        errdefer git_dir.close(io);

        try git_dir.createDirPath(io, "objects/pack");
        try git_dir.createDirPath(io, "objects/info");
        try git_dir.createDirPath(io, "info");

        var head_buf: [512]u8 = undefined;
        switch (options.ref_format) {
            .files => {
                try git_dir.createDirPath(io, "refs/heads");
                try git_dir.createDirPath(io, "refs/tags");
                const head_line = std.fmt.bufPrint(&head_buf, "ref: refs/heads/{s}\n", .{options.default_branch}) catch
                    return error.NotARepository;
                try git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = head_line });
            },
            .reftable => {
                const target = std.fmt.bufPrint(&head_buf, "refs/heads/{s}", .{options.default_branch}) catch
                    return error.NotARepository;
                try reftablestack.initialize(gpa, io, git_dir, options.object_format, .{ .symbolic = target }, null, .{});
            },
        }

        var config_text: std.Io.Writer.Allocating = .init(gpa);
        defer config_text.deinit();
        const w = &config_text.writer;
        const version: u8 = if (options.object_format == .sha1 and options.ref_format == .files) 0 else 1;
        w.print("[core]\n", .{}) catch return error.OutOfMemory;
        w.print("\trepositoryformatversion = {d}\n", .{version}) catch return error.OutOfMemory;
        w.print("\tfilemode = {s}\n", .{if (options.file_mode) "true" else "false"}) catch return error.OutOfMemory;
        w.print("\tbare = {s}\n", .{if (options.bare) "true" else "false"}) catch return error.OutOfMemory;
        if (!options.bare) {
            w.print("\tlogallrefupdates = true\n", .{}) catch return error.OutOfMemory;
        }
        if (options.object_format != .sha1 or options.ref_format == .reftable) {
            w.print("[extensions]\n", .{}) catch return error.OutOfMemory;
        }
        if (options.object_format != .sha1) {
            w.print("\tobjectformat = {s}\n", .{options.object_format.name()}) catch return error.OutOfMemory;
        }
        if (options.ref_format == .reftable) {
            w.print("\trefstorage = reftable\n", .{}) catch return error.OutOfMemory;
        }
        try git_dir.writeFile(io, .{ .sub_path = "config", .data = config_text.written() });

        const work_dir: ?Io.Dir = if (options.bare) null else try dir.openDir(io, ".", .{ .iterate = true });
        const discovered: Discovered = .{
            .git_dir = git_dir,
            .common_dir = git_dir,
            .work_dir = work_dir,
            .common_is_separate = false,
        };
        return finish(gpa, io, discovered, .{ .discover = false, .odb = options.odb });
    }

    /// Close everything the repository holds.
    pub fn deinit(repo: *Repository, io: Io) void {
        repo.odb.deinit(io);
        repo.config.deinit();
        if (repo.common_is_separate) repo.common_dir.close(io);
        repo.git_dir.close(io);
        if (repo.work_dir) |w| w.close(io);
        repo.* = undefined;
    }

    /// Whether the repository has a working tree.
    pub fn isBare(repo: *const Repository) bool {
        return repo.work_dir == null;
    }

    /// The `core` settings that take part in line-ending conversion.
    pub fn coreSettings(repo: *const Repository) attributes.CoreSettings {
        const autocrlf: attributes.CoreSettings.AutoCrlf = blk: {
            const text = repo.config.get("core.autocrlf") orelse break :blk .false;
            if (std.ascii.eqlIgnoreCase(text, "input")) break :blk .input;
            const as_bool = config_mod.parseBool(text) catch break :blk .false;
            break :blk if (as_bool) .true else .false;
        };
        const eol: attributes.CoreSettings.Eol = blk: {
            const text = repo.config.get("core.eol") orelse break :blk .native;
            if (std.ascii.eqlIgnoreCase(text, "lf")) break :blk .lf;
            if (std.ascii.eqlIgnoreCase(text, "crlf")) break :blk .crlf;
            break :blk .native;
        };
        const safecrlf: attributes.CoreSettings.SafeCrlf = blk: {
            const text = repo.config.get("core.safecrlf") orelse break :blk .false;
            if (std.ascii.eqlIgnoreCase(text, "warn")) break :blk .warn;
            const as_bool = config_mod.parseBool(text) catch break :blk .false;
            break :blk if (as_bool) .true else .false;
        };
        return .{ .autocrlf = autocrlf, .eol = eol, .safecrlf = safecrlf };
    }

    /// The rules a working-tree operation needs, with `ignore` and `attrs`
    /// left for the caller to fill in.
    pub fn worktreeRules(repo: *const Repository) worktree.Rules {
        return .{
            .core = repo.coreSettings(),
            .ignore_case = repo.config.getBool("core.ignorecase", false) catch false,
            .check_stat = if (repo.config.get("core.checkstat")) |text|
                (if (std.ascii.eqlIgnoreCase(text, "minimal")) .minimal else .full)
            else
                .full,
            .timestamp_resolution = repo.odb.timestamp_resolution,
            .file_mode = repo.config.getBool("core.filemode", Io.File.Permissions.has_executable_bit) catch true,
            .symlinks = repo.config.getBool("core.symlinks", @import("builtin").os.tag != .windows) catch true,
        };
    }

    /// Load the ignore rules for the working tree's root.
    ///
    /// The result is the caller's, and a walk pushes and pops deeper levels
    /// into it as it goes.
    pub fn loadIgnore(repo: *Repository, io: Io) Error!ignore.Rules {
        const case_fold = repo.config.getBool("core.ignorecase", false) catch false;
        var rules = try ignore.Rules.init(repo.gpa, case_fold);
        errdefer rules.deinit();
        const excludes = try repo.config.getPath(repo.gpa, "core.excludesfile");
        defer if (excludes) |p| repo.gpa.free(p);
        try rules.loadGlobal(io, repo.common_dir, excludes, Io.Dir.cwd());
        return rules;
    }

    /// Load the attributes for the working tree's root.
    pub fn loadAttrs(repo: *Repository, io: Io) Error!attributes.Attrs {
        const case_fold = repo.config.getBool("core.ignorecase", false) catch false;
        var attrs = try attributes.Attrs.init(repo.gpa, case_fold);
        errdefer attrs.deinit();
        const file = try repo.config.getPath(repo.gpa, "core.attributesfile");
        defer if (file) |p| repo.gpa.free(p);
        try attrs.loadGlobal(io, repo.common_dir, file, Io.Dir.cwd());
        return attrs;
    }

    /// The filter names whose `filter.<name>.required` is true. The result
    /// is the caller's.
    ///
    /// A repository naming one of these in its attributes is refused, by
    /// name, rather than handed a blob git would not write.
    pub fn requiredFilters(repo: *const Repository, gpa: Allocator) Allocator.Error![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        const names = try repo.config.subsections(gpa, "filter");
        defer gpa.free(names);
        for (names) |name| {
            var key_buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "filter.{s}.required", .{name}) catch continue;
            if (repo.config.getBool(key, false) catch false) try out.append(gpa, name);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The filter drivers the configuration defines and relic's own LFS,
    /// for `worktree.Rules.filters`. The result is the caller's, and borrows
    /// the repository's directories for as long as it lives.
    pub fn loadFilters(repo: *Repository, io: Io, options: filter.Drivers.Options) filter.Drivers.LoadError!filter.Drivers {
        return filter.Drivers.load(repo.gpa, io, &repo.config, repo.common_dir, repo.work_dir, options);
    }

    /// Open the repository's own index.
    pub fn openIndex(repo: *Repository, io: Io) index_mod.ReadError!index_mod.Index {
        return index_mod.Index.readWithResolution(
            repo.gpa,
            io,
            repo.git_dir,
            "index",
            repo.common_dir,
            repo.kind,
            repo.odb.timestamp_resolution,
        );
    }

    /// Open an index anywhere.
    ///
    /// A private index is a first-class argument and not an environment
    /// variable: a caller that keeps its own staging area passes its path.
    pub fn openIndexAt(
        repo: *Repository,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
    ) index_mod.ReadError!index_mod.Index {
        return index_mod.Index.read(repo.gpa, io, dir, sub_path, repo.common_dir, repo.kind);
    }

    /// What `HEAD` resolves to, or `null` on an unborn branch.
    ///
    /// The returned name is the caller's.
    pub fn head(repo: *Repository, io: Io) refs_mod.ReadError!?refs_mod.Resolved {
        return repo.refs.head(repo.gpa, io);
    }

    /// The tree `HEAD` points at, or `null` on an unborn branch.
    pub fn headTree(repo: *Repository, io: Io) Error!?Oid {
        const resolved = (try repo.head(io)) orelse return null;
        defer repo.gpa.free(resolved.name);
        return try repo.commitTree(io, resolved.oid);
    }

    /// The tree a commit points at.
    pub fn commitTree(repo: *Repository, io: Io, commit_oid: Oid) Error!Oid {
        const found = try repo.odb.read(io, commit_oid);
        defer repo.gpa.free(found.bytes);
        if (found.type != .commit) return error.UnexpectedObjectType;
        var commit = try object.Commit.parse(repo.gpa, repo.kind, found.bytes);
        defer commit.deinit();
        return commit.tree;
    }

    /// Follow a tag object until it names something that is not a tag, and
    /// return that object's name.
    pub fn peel(repo: *Repository, io: Io, oid: Oid) Error!Oid {
        var current = oid;
        var depth: u8 = 0;
        while (depth < 16) : (depth += 1) {
            const header = try repo.odb.readHeader(io, current);
            if (header.type != .tag) return current;
            const found = try repo.odb.read(io, current);
            defer repo.gpa.free(found.bytes);
            var tag = try object.Tag.parse(repo.gpa, repo.kind, found.bytes);
            defer tag.deinit();
            current = tag.target;
        }
        return error.TagDepthExceeded;
    }

    /// What `commit` needs from the caller: who, when, and what to say.
    ///
    /// The time is the caller's, because nothing in this package reads a
    /// clock.
    pub const CommitRequest = struct {
        tree: Oid,
        parents: []const Oid = &.{},
        author: object.Signature,
        committer: object.Signature,
        message: []const u8,
        encoding: ?[]const u8 = null,
        extra: []const object.ExtraHeader = &.{},
        /// Whether and how to sign it. By default `commit.gpgSign` decides,
        /// as it does for `git commit-tree`.
        signing: signing.Request = .{},
    };

    /// Write a commit object. No ref is moved and no log is written: that is
    /// a ref transaction, and keeping the two apart is what makes
    /// `commit-tree` a usable primitive.
    ///
    /// A commit that is to be signed and comes with no `Programs` to sign it
    /// is `error.SigningRequiresPrograms`, never an unsigned commit.
    pub fn writeCommit(repo: *Repository, io: Io, request: CommitRequest) WriteError!Oid {
        const fields: object.Commit.Fields = .{
            .tree = request.tree,
            .parents = request.parents,
            .author = request.author,
            .committer = request.committer,
            .encoding = request.encoding,
            .extra = request.extra,
            .message = request.message,
        };
        var signer = try repo.signerFor(request.signing, "commit.gpgsign", "commit.gpgSign");
        defer if (signer) |*s| s.deinit();
        const bytes = (if (signer) |*s|
            signing.signCommit(s, io, repo.kind, fields, request.signing.key)
        else
            object.Commit.build(repo.gpa, repo.kind, fields)) catch |err| switch (err) {
            error.InvalidSignature, error.MixedHashKinds => return error.UnexpectedObjectType,
            else => |e| return e,
        };
        defer repo.gpa.free(bytes);
        return repo.odb.write(io, .commit, bytes);
    }

    /// Write an annotated tag object. `tag.gpgSign` or
    /// `tag.forceSignAnnotated` makes it signed, which needs `writeTagWith`
    /// and the caller's `Programs`; here it is refused.
    pub fn writeTag(repo: *Repository, io: Io, fields: object.Tag.Fields) WriteError!Oid {
        return repo.writeTagWith(io, fields, .{});
    }

    /// Write an annotated tag object, signed as `request` and the
    /// configuration say, with the signature after the message.
    pub fn writeTagWith(repo: *Repository, io: Io, fields: object.Tag.Fields, request: signing.Request) WriteError!Oid {
        var signer = try repo.signerFor(request, "tag.gpgsign", "tag.gpgSign");
        defer if (signer) |*s| s.deinit();
        const bytes = (if (signer) |*s|
            signing.signTag(s, io, repo.kind, fields, request.key)
        else
            object.Tag.build(repo.gpa, repo.kind, fields)) catch |err| switch (err) {
            error.InvalidSignature, error.MixedHashKinds => return error.UnexpectedObjectType,
            else => |e| return e,
        };
        defer repo.gpa.free(bytes);
        return repo.odb.write(io, .tag, bytes);
    }

    /// The signer a write needs, or `null` when it is not to be signed.
    fn signerFor(repo: *Repository, request: signing.Request, key: []const u8, spelling: []const u8) WriteError!?signing.Signer {
        const wanted = switch (request.sign) {
            .always => true,
            .never => false,
            .config => (repo.config.getBool(key, false) catch false) or
                (std.mem.startsWith(u8, key, "tag.") and (repo.config.getBool("tag.forcesignannotated", false) catch false)),
        };
        if (!wanted) return null;
        const programs = request.programs orelse {
            repo.setUnsupported(if (request.sign == .config) spelling else "");
            return error.SigningRequiresPrograms;
        };
        return try signing.Signer.init(repo.gpa, &repo.config, programs);
    }

    /// The reflog policy `core.logAllRefUpdates` asks for.
    ///
    /// A repository with a working tree defaults to writing logs for
    /// branches; a bare one defaults to writing them only where one already
    /// exists, which is git's rule.
    pub fn reflogPolicy(repo: *const Repository) reflog.Policy {
        if (repo.config.get("core.logallrefupdates")) |text| return reflog.Policy.parse(text);
        return if (repo.isBare()) .existing_only else .standard;
    }

    /// Begin a ref transaction over this repository.
    ///
    /// The transaction peels an annotated tag it writes through this
    /// repository's objects, which a reftable records beside the tag as git
    /// does. The repository must outlive the transaction.
    pub fn beginRefs(repo: *Repository) refs_mod.Transaction {
        var tx = repo.refs.begin(repo.gpa);
        tx.peeler = .{ .context = repo, .peel = peelForRefs };
        return tx;
    }

    fn peelForRefs(context: *anyopaque, io: Io, oid: Oid) ?Oid {
        const repo: *Repository = @ptrCast(@alignCast(context));
        const header = repo.odb.readHeader(io, oid) catch return null;
        if (header.type != .tag) return null;
        return repo.peel(io, oid) catch null;
    }

    /// A ref's log, oldest first, whichever format the refs are kept in.
    pub fn readLog(repo: *Repository, io: Io, name: []const u8) (refs_mod.ReadError || reflog.ReadError)!reflog.Log {
        return repo.refs.readLog(repo.gpa, io, name);
    }

    /// A runner for this repository's hooks, carrying the caller's
    /// permission to start them. It is what an operation that may run a
    /// hook takes; the configuration is read now and not again.
    pub fn hookRunner(
        repo: *Repository,
        io: Io,
        programs: program.Programs,
        options: hooks.Options,
    ) hooks.InitError!hooks.Runner {
        return hooks.Runner.init(repo.gpa, io, .{
            .config = &repo.config,
            .git_dir = repo.git_dir,
            .common_dir = repo.common_dir,
            .work_dir = repo.work_dir,
        }, programs, options);
    }

    /// Every linked worktree.
    pub fn listWorktrees(repo: *Repository, io: Io) worktrees.Error!worktrees.Listing {
        return worktrees.list(repo.gpa, io, repo.common_dir, repo.kind);
    }

    /// Remove the administrative directories whose working tree is gone,
    /// skipping any with a `locked` file.
    pub fn pruneWorktrees(repo: *Repository, io: Io) worktrees.Error!worktrees.PruneOutcome {
        return worktrees.prune(repo.gpa, io, repo.common_dir, repo.kind);
    }
};
