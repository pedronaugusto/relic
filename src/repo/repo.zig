//! The front door: open or create a repository and reach everything in it.
//!
//! A repository is a local directory. Nothing here talks to a network or
//! reads a clock. Signing a write needs the caller's `program.Programs`.

const ErrorNamespace = @This();
const Self = @This();

// The modules relic's API puts under this one, as `relic.repo.<name>`.
const hooks = @import("../hooks/hooks.zig");
const program = @import("../process/program.zig");

const fs = @import("../fs/fs.zig");
const safe = @import("safe.zig");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const index_mod = @import("../index/index.zig");
const refs_mod = @import("../refs/refs.zig");
const config_mod = @import("../config/config.zig");
const config_write = @import("../config/write.zig");
const commit_cache = @import("cache.zig");
const shallow = @import("../walk/shallow.zig");
const ignore = @import("../patterns/ignore.zig");
const attributes = @import("../patterns/attributes.zig");
const worktree = @import("../checkout/checkout.zig");
const worktrees = @import("../checkout/worktrees.zig");
const filter = @import("../checkout/filter.zig");
const reftablestack = @import("../refs/reftablestack.zig");
const signing = @import("../object/signing.zig");
const diagnostic_mod = @import("../report/diagnostic.zig");
const repository_format = @import("../discover/format.zig");
const RepositoryFormat = repository_format.Format;

const Oid = hash.Oid;

/// Errors from opening, creating or refreshing a repository and reading its objects.
pub const Error = error{
    /// No `.git` directory or file at the path or above it.
    NotARepository,
    /// `.git/shallow` holds a line that is not an object name.
    MalformedShallowFile,
    /// `core.repositoryFormatVersion` is a number this release does not
    /// know. `OpenOptions.diagnostic` names the setting on a failed open;
    /// the caller-owned diagnostic does so on a failed refresh.
    UnsupportedRepositoryVersion,
    /// An `extensions.*` this release does not implement, at format version
    /// 1 where git requires every extension to be understood.
    /// The caller-owned diagnostic names it.
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
    /// The configuration read again by `refreshConfig` names another ref
    /// backend. The store and its cache were opened for the old one, so
    /// the repository must be reopened.
    RefStorageChanged,
    /// A memory-only edit (`editConfig`) names the repository's format:
    /// `core.repositoryFormatVersion` or an `extensions.*`, which only the
    /// repository's own file says. `writeConfig` writes it there.
    FormatEditInMemory,
    /// The repository discovered belongs to another user and
    /// `safe.directory` does not name it: git's "detected dubious
    /// ownership".
    DubiousOwnership,
    /// A bare repository discovered where `safe.bareRepository` is
    /// `explicit`: git's "cannot use bare repository".
    ImplicitBareRepository,
    /// `core.sharedRepository` is a mode that leaves the owner unable to
    /// read or write.
    InvalidSharedMode,
} || object.ParseError || Allocator.Error || Io.Dir.OpenError || Io.Dir.ReadFileAllocError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.WriteFileError ||
    Io.File.OpenError || Io.Writer.Error || Io.File.SyncError ||
    config_mod.ParseError || config_mod.ValueError || odb_mod.Error ||
    refs_mod.ReadError || refs_mod.TransactionError || worktrees.Error;

/// Errors from writing a commit or a tag, which may be signed.
pub const WriteError = Error || signing.Error || object.Commit.WriteError;

/// How deep `open` walks upwards looking for a `.git`.
pub const max_discovery_depth: u8 = 64;

/// Caller-owned output for repository and history operations.
pub const Diagnostic = diagnostic_mod.Diagnostic;

/// The caller-owned diagnostic used by earlier open callers.
/// How a repository is created.
pub const CreateOptions = struct {
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
    /// The template directory git copies into a new repository: what
    /// `--template`, `GIT_TEMPLATE_DIR`, `init.templateDir`
    /// (`templateDir` reads it) or git's own installed one names, opened by
    /// the caller. Everything in it but dotfiles is copied, nothing already
    /// there replaced, a `config` in it the start of the repository's own.
    template: ?Io.Dir = null,
    /// `--shared`: written as `core.sharedRepository`, with
    /// `receive.denyNonFastforwards`, and given to everything made. `null`
    /// takes the template configuration's.
    shared: ?fs.Shared = null,
    /// Whether `core.ignorecase` is recorded as true: git probes for a file
    /// system that folds case, and the caller decides here, as with
    /// `file_mode`.
    ignore_case: bool = false,
    /// Whether the file system holds symbolic links; git records
    /// `core.symlinks = false` where it does not.
    symlinks: bool = true,
    /// `core.precomposeunicode`, which git records on macOS from its probe
    /// of how the file system stores decomposed names; `null` records
    /// nothing.
    precompose_unicode: ?bool = null,
};

/// Errors from `templateDir`.
pub const TemplateDirError = Allocator.Error || error{MalformedValue};

/// `init.templateDir` in `config`, as git reads it for `git init`, with
/// `~/` expanded; `null` when it is not set. The path is `gpa`'s.
pub fn templateDir(gpa: Allocator, config: *const config_mod.Config) TemplateDirError!?[]u8 {
    return config.getPath(gpa, "init.templatedir");
}

/// An open repository.
/// What `.lfsconfig` was last found from: see `Repository.lfsconfigText`.
const LfsconfigCache = struct {
    key: LfsconfigKey,
    text: ?[]u8,
};

const LfsconfigKey = struct {
    /// The working tree's `.lfsconfig`, when there is one: nothing else
    /// is looked at then.
    worktree: ?FileStamp = null,
    index: ?IndexStamp = null,
    head: ?hash.Oid = null,
};

/// A file as `stat` sees it, for knowing it has not changed.
const FileStamp = struct {
    size: u64,
    mtime: i96,
    ctime: i96,
    inode: Io.File.INode,

    fn of(st: Io.File.Stat) FileStamp {
        return .{ .size = st.size, .mtime = st.mtime.nanoseconds, .ctime = st.ctime.nanoseconds, .inode = st.inode };
    }
};

/// The index as `stat` sees it, and the checksum it ends with, which is
/// zero when `index.skipHash` leaves it out.
const IndexStamp = struct {
    file: FileStamp,
    checksum: [hash.max_raw_len]u8 = @splat(0),
};

const RefState = opaque {};
const config_owner = @import("../config/state.zig");

/// The directories `Repository.open` found, before the repository is read.
const Discovered = struct {
    git_dir: Io.Dir,
    common_dir: Io.Dir,
    work_dir: ?Io.Dir,
    common_is_separate: bool,

    fn close(d: *Discovered, io: Io) void {
        // One handle, closed once, when the common directory is not separate.
        if (!d.common_is_separate) assert(d.common_dir.handle == d.git_dir.handle);
        if (d.common_is_separate) d.common_dir.close(io);
        d.git_dir.close(io);
        if (d.work_dir) |w| w.close(io);
    }
};

/// Where `Repository.loadIgnore` reads its two levels, as absolute paths on
/// the caller's `gpa`: what a caller watching for a rule to change watches
/// beside the working tree's own `.gitignore` files. Neither file need
/// exist.
pub const IgnoreSources = struct {
    pub const Error = ErrorNamespace.Error;

    /// `core.excludesFile`, a relative one taken from the process's
    /// current directory as `loadIgnore` reads it; `null` when unset.
    excludes_file: ?[]u8,
    /// `info/exclude` in the common directory.
    info_exclude: []u8,

    pub fn deinit(sources: *IgnoreSources, gpa: Allocator) void {
        if (sources.excludes_file) |path| gpa.free(path);
        gpa.free(sources.info_exclude);
        sources.* = undefined;
    }
};

const RepositoryData = struct {
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
    /// Owned ref state. Its format and cache are opaque to callers.
    _refs: *RefState,
    /// Opaque ownership of the published configuration: what the files
    /// held at `open`, or when `refreshConfig` last found one changed, or
    /// when `writeConfig` last wrote one, with `editConfig`'s values over
    /// them. Nothing reads the files again behind the caller's back, so
    /// another process's `git config` is seen after a `refreshConfig` and
    /// not before; a write reads its own file again under its lock, so
    /// what another process wrote there stays. An `includeIf` is decided
    /// against this repository's `.git` directory and the branch `HEAD`
    /// was on when the files were read.
    _config: *config_owner.State,
    odb: odb_mod.Odb,
    /// What `core.sharedRepository` asked of permissions when the
    /// repository was opened: the objects, refs, logs, index and
    /// configuration it writes are given them.
    shared: fs.Shared = .umask,
    /// What `lfsconfigText` last found, and what it was found from.
    lfsconfig_cache: ?LfsconfigCache = null,
    lfsconfig_mutex: Io.Mutex = .init,
    /// Commits read through `commitInfo` and `commitTree`, kept.
    _commits: commit_cache.Cache = .{},
};

pub const Repository = struct {
    pub const Error = ErrorNamespace.Error;

    /// Private ownership; handles, caches and live configuration stay together.
    _state: *anyopaque,

    fn data(repo: *const Repository) *RepositoryData {
        return @ptrCast(@alignCast(repo._state));
    }

    pub fn allocator(repo: *const Repository) Allocator {
        return repo.data().gpa;
    }

    pub fn gitDirectory(repo: *const Repository) Io.Dir {
        return repo.data().git_dir;
    }

    pub fn commonDirectory(repo: *const Repository) Io.Dir {
        return repo.data().common_dir;
    }

    /// Whether this is a linked worktree with a distinct common directory.
    pub fn isLinkedWorktree(repo: *const Repository) bool {
        return repo.data().common_is_separate;
    }

    pub fn workDirectory(repo: *const Repository) ?Io.Dir {
        return repo.data().work_dir;
    }

    /// Borrowed until this repository is deinitialized.
    pub fn objectDatabase(repo: *const Repository) *odb_mod.Odb {
        return &repo.data().odb;
    }

    pub fn sharedPermissions(repo: *const Repository) fs.Shared {
        return repo.data().shared;
    }

    /// Open the repository at `path`, or the first one above it.
    ///
    /// `path` may be the working tree, the `.git` directory, or a linked
    /// worktree. A `.git` *file* is followed, which is how a linked worktree
    /// is opened.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: OpenOptions) Self.Error!Repository {
        diagnostic_mod.reset(options.diagnostic);
        var discovered = try discover(gpa, io, dir, options);
        errdefer discovered.close(io);
        return finish(gpa, io, discovered, options);
    }

    /// The per-worktree directory at `dir`, as `open` with `discover`
    /// off finds it, without reading the repository: its `.git` folder,
    /// where a `.git` file points (a linked worktree, a submodule), or
    /// `dir` itself when it is a git directory. For a file of the caller's
    /// own kept beside the repository rather than in the working tree. The
    /// handle is the caller's to close.
    pub fn gitDirOf(gpa: Allocator, io: Io, dir: Io.Dir) Self.Error!Io.Dir {
        var discovered = try discover(gpa, io, dir, .{ .discover = false });
        if (discovered.common_is_separate) discovered.common_dir.close(io);
        if (discovered.work_dir) |work| work.close(io);
        return discovered.git_dir;
    }

    /// How a repository is opened.
    pub const OpenOptions = struct {
        /// Caller-owned output for a refused repository format or extension.
        /// Cleared on every open, and never retained by the repository.
        diagnostic: ?*Diagnostic = null,
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
        /// The XDG one, `~/.config/git/config`, read before
        /// `global_config`, as git reads both.
        xdg_config: ?config_mod.Sources.Path = null,
        /// The home directory, for `~/` in a config value or an
        /// `includeIf` condition. This package reads no environment, so the
        /// caller supplies it. The configuration keeps its own copy.
        home: ?[]const u8 = null,
        /// Values that beat every file, as `name=value`.
        config_overrides: []const []const u8 = &.{},
        /// Values that beat every file, after `config_overrides`, with the
        /// name and value apart: what `userconfig.Locations.pairs` holds.
        config_pairs: []const config_mod.Sources.Pair = &.{},
        /// What is checked of who owns the repository found: git's own
        /// check unless asked otherwise. `safe.directory` is read from the
        /// system, global and command-line settings for a repository that is
        /// not the current user's.
        ownership: safe.Ownership = .check,
        /// The directory is the git directory, as git's `GIT_DIR` and
        /// `--git-dir` name one: git checks neither `safe.bareRepository`
        /// nor ownership for it.
        explicit: bool = false,
        /// Absolute paths discovery does not walk up into, as git's
        /// `GIT_CEILING_DIRECTORIES`: the start is still looked at when it
        /// is one, and no directory at or above the nearest one above it
        /// is. Borrowed for the call.
        ceiling_directories: []const []const u8 = &.{},
        /// Whether discovery walks up past the filesystem the start is on,
        /// as git's `GIT_DISCOVERY_ACROSS_FILESYSTEM`; git stops there
        /// unless told.
        across_filesystems: bool = false,
    };

    fn discover(gpa: Allocator, io: Io, start: Io.Dir, options: OpenOptions) ErrorNamespace.Error!Discovered {
        var current = start;
        var current_owned = false;
        defer if (current_owned) current.close(io);
        // Where the walk stops climbing: the nearest ceiling above the
        // start, by the length of its path, and the start's filesystem.
        var path_buf: [4096]u8 = undefined;
        var path: []const u8 = "";
        var ceiling: ?usize = null;
        if (options.discover and options.ceiling_directories.len != 0) {
            path = try absoluteGitDir(io, start, &path_buf);
            ceiling = nearestCeiling(path, options.ceiling_directories);
        }
        const device = if (fs.statAt(io, start, ".") catch null) |found| found.stat.dev else 0;
        var depth: u8 = 0;
        while (true) : (depth += 1) {
            if (depth > max_discovery_depth) break;

            // A `.git` here: a directory that is a git directory, or a file
            // naming one, which is what a linked worktree and a submodule
            // have. git's `read_gitfile_gently` and `is_git_directory`.
            if (try dotGit(gpa, io, current)) |git_dir| {
                errdefer git_dir.close(io);
                const work = try current.openDir(io, ".", .{ .iterate = true });
                errdefer work.close(io);
                const is_file = if (current.statFile(io, ".git", .{})) |st| st.kind == .file else |_| false;
                try checkOwnership(gpa, io, options, if (is_file) work else null, work, git_dir);
                return withCommon(gpa, io, git_dir, work);
            }

            // The directory may itself be a git directory — a bare
            // repository, or `.git` handed in directly.
            if (looksLikeGitDir(io, current)) {
                const git_dir = try current.openDir(io, ".", .{ .iterate = true });
                errdefer git_dir.close(io);
                try checkBare(gpa, io, options, git_dir);
                try checkOwnership(gpa, io, options, null, null, git_dir);
                return withCommon(gpa, io, git_dir, null);
            }

            if (!options.discover) break;
            if (ceiling) |stop| {
                const up = std.Io.Dir.path.dirnamePosix(path) orelse break;
                // The root's length counts as its slash's.
                if (@max(up.len, 1) <= stop) break;
                path = up;
            }
            const parent = current.openDir(io, "..", .{ .iterate = true }) catch break;
            // The walk stops when `..` is the same directory, which is the
            // filesystem root, and where it would leave the start's
            // filesystem, as git's does unless told otherwise.
            const parent_device = if (fs.statAt(io, parent, ".") catch null) |found| found.stat.dev else device;
            if (sameDir(io, parent, current) or (!options.across_filesystems and parent_device != device)) {
                parent.close(io);
                break;
            }
            if (current_owned) current.close(io);
            current = parent;
            current_owned = true;
        }
        return error.NotARepository;
    }

    /// The length of the longest ceiling that is a directory above `path`,
    /// `path` itself excluded: git's `longest_ancestor_length`.
    fn nearestCeiling(path: []const u8, ceilings: []const []const u8) ?usize {
        var best: ?usize = null;
        for (ceilings) |raw| {
            const ceiling = if (raw.len > 1) std.mem.trimEnd(u8, raw, "/") else raw;
            if (ceiling.len == 0 or ceiling.len >= path.len) continue;
            if (!std.mem.startsWith(u8, path, ceiling)) continue;
            if (ceiling[ceiling.len - 1] != '/' and path[ceiling.len] != '/') continue;
            if (best == null or ceiling.len > best.?) best = ceiling.len;
        }
        return best;
    }

    /// The git directory a `.git` in `dir` stands for, or `null` when there
    /// is none to take, as git's discovery reads one: a directory that is a
    /// git directory is taken, one that is not is passed over; a file must
    /// be `gitdir: <path>` naming a git directory, and anything else --
    /// unreadable, malformed, naming nothing -- is `error.BrokenGitFile`,
    /// where git dies rather than look further up, as a submodule's damaged
    /// `.git` must never be taken for its superproject.
    fn dotGit(gpa: Allocator, io: Io, dir: Io.Dir) ErrorNamespace.Error!?Io.Dir {
        const st = dir.statFile(io, ".git", .{}) catch return null;
        if (st.kind != .file) {
            if (st.kind != .directory) return null;
            const git_dir = dir.openDir(io, ".git", .{ .iterate = true }) catch return null;
            if (looksLikeGitDir(io, git_dir)) return git_dir;
            git_dir.close(io);
            return null;
        }
        const text = fs.readFileAlloc(gpa, io, dir, ".git", 4096) catch return error.BrokenGitFile;
        const bytes = text orelse return error.BrokenGitFile;
        defer gpa.free(bytes);
        if (!std.mem.startsWith(u8, bytes, "gitdir: ")) return error.BrokenGitFile;
        const target = std.mem.trimEnd(u8, bytes["gitdir: ".len..], "\r\n");
        if (target.len == 0) return error.BrokenGitFile;
        // A linked worktree's names its directory absolutely; a
        // submodule's names it relative to the file itself.
        const git_dir = (if (std.Io.Dir.path.isAbsolute(target))
            Io.Dir.openDirAbsolute(io, target, .{ .iterate = true })
        else
            dir.openDir(io, target, .{ .iterate = true })) catch return error.BrokenGitFile;
        if (looksLikeGitDir(io, git_dir)) return git_dir;
        git_dir.close(io);
        return error.BrokenGitFile;
    }

    /// The settings a repository cannot write itself: the system, global
    /// and command-line ones, which git's `git_protected_config` reads.
    fn protectedConfig(gpa: Allocator, io: Io, options: OpenOptions) ErrorNamespace.Error!config_mod.Config {
        return config_mod.Config.open(gpa, io, .{
            .system = options.system_config,
            .xdg = options.xdg_config,
            .global = options.global_config,
            .command = options.config_overrides,
            .pairs = options.config_pairs,
        }, .{ .home = options.home });
    }

    /// git's `ensure_valid_ownership` for a repository found by discovery:
    /// the `.git` file's directory (`gitfile_in`), the working tree and the
    /// git directory are the current user's, or `safe.directory` names the
    /// working tree, or the git directory where there is none.
    fn checkOwnership(gpa: Allocator, io: Io, options: OpenOptions, gitfile_in: ?Io.Dir, work: ?Io.Dir, git_dir: Io.Dir) ErrorNamespace.Error!void {
        if (options.explicit or options.ownership == .trust) return;
        if (options.ownership == .check) {
            const owned = (if (gitfile_in) |d| fs.ownedByCurrentUser(io, d, ".git", options.home) else true) and
                (if (work) |w| fs.ownedByCurrentUser(io, w, ".", options.home) else true) and
                fs.ownedByCurrentUser(io, git_dir, ".", options.home);
            if (owned) return;
        }
        const real = (work orelse git_dir).realPathFileAlloc(io, ".", gpa) catch return error.DubiousOwnership;
        defer gpa.free(real);
        const path = try safe.normalize(gpa, real);
        defer gpa.free(path);
        var protected = try protectedConfig(gpa, io, options);
        defer protected.deinit();
        if (!try safe.directoryIsSafe(gpa, io, &protected, path, options.home)) {
            try refuseSetting(options.diagnostic, "safe.directory");
            return error.DubiousOwnership;
        }
    }

    /// git's refusal of a bare repository found by discovery under
    /// `safe.bareRepository=explicit`.
    fn checkBare(gpa: Allocator, io: Io, options: OpenOptions, git_dir: Io.Dir) ErrorNamespace.Error!void {
        if (options.explicit) return;
        var protected = try protectedConfig(gpa, io, options);
        defer protected.deinit();
        // A value git does not know refuses, as git dies there.
        const allowed = safe.bareRepositories(&protected) catch .explicit;
        if (allowed == .all) return;
        const real = git_dir.realPathFileAlloc(io, ".", gpa) catch return error.ImplicitBareRepository;
        defer gpa.free(real);
        const path = try safe.normalize(gpa, real);
        defer gpa.free(path);
        if (!safe.isImplicitBare(path)) {
            try refuseSetting(options.diagnostic, "safe.bareRepository");
            return error.ImplicitBareRepository;
        }
    }

    fn withCommon(gpa: Allocator, io: Io, git_dir: Io.Dir, work_dir: ?Io.Dir) ErrorNamespace.Error!Discovered {
        // `commondir` makes this a linked worktree: everything shared lives
        // where it points.
        if (try fs.readFileAlloc(gpa, io, git_dir, "commondir", 4096)) |text| {
            defer gpa.free(text);
            const target = std.mem.trim(u8, text, " \t\r\n");
            const common = try git_dir.openDir(io, target, .{ .iterate = true });
            return .{
                .git_dir = git_dir,
                .common_dir = common,
                .work_dir = work_dir,
                .common_is_separate = true,
            };
        }
        return .{
            .git_dir = git_dir,
            .common_dir = git_dir,
            .work_dir = work_dir,
            .common_is_separate = false,
        };
    }

    /// git's `is_git_directory`: a `HEAD`, and `objects` and `refs` here
    /// or in the directory `commondir` names, as a linked worktree's git
    /// directory has them.
    fn looksLikeGitDir(io: Io, dir: Io.Dir) bool {
        dir.access(io, "HEAD", .{}) catch return false;
        var buf: [4096]u8 = undefined;
        if (dir.readFile(io, "commondir", &buf)) |text| {
            const target = std.mem.trim(u8, text, " \t\r\n");
            // one that does not open is reported by the open that follows
            var common = dir.openDir(io, target, .{}) catch return true;
            defer common.close(io);
            common.access(io, "objects", .{}) catch return false;
            common.access(io, "refs", .{}) catch return false;
            return true;
        } else |_| {}
        dir.access(io, "objects", .{}) catch return false;
        dir.access(io, "refs", .{}) catch return false;
        return true;
    }

    /// Whether two handles are one directory: the same inode on the same
    /// device.
    fn sameDir(io: Io, a: Io.Dir, b: Io.Dir) bool {
        const sa = (fs.statAt(io, a, ".") catch return false) orelse return false;
        const sb = (fs.statAt(io, b, ".") catch return false) orelse return false;
        return sa.stat.ino == sb.stat.ino and sa.stat.dev == sb.stat.dev;
    }

    fn finish(gpa: Allocator, io: Io, discovered: Discovered, options: OpenOptions) ErrorNamespace.Error!Repository {
        const owned = try gpa.create(RepositoryData);
        errdefer gpa.destroy(owned);
        owned.* = .{
            .gpa = gpa,
            .git_dir = discovered.git_dir,
            .common_dir = discovered.common_dir,
            .work_dir = discovered.work_dir,
            .common_is_separate = discovered.common_is_separate,
            ._config = undefined,
            .odb = undefined,
            ._refs = undefined,
        };

        var repo: Repository = .{ ._state = owned };

        // The configuration is read before anything else, because it says
        // which hash the object names are written with.
        // An `includeIf` asks where the `.git` directory is and which branch
        // `HEAD` is on, so both are known before the first file is read.
        var path_buffer: [4096]u8 = undefined;
        const git_dir_path = try absoluteGitDir(io, repo.data().git_dir, &path_buffer);
        // The format is the repository's own file's to say, read alone, as
        // git's `read_repository_format` reads it: no include, no other
        // file and no `-c` decides which hash a repository's objects are
        // named with, or where its refs are kept.
        const format = try repository_format.read(gpa, io, repo.data().common_dir, options.diagnostic);
        const branch = try currentBranch(gpa, io, repo.data().git_dir, repo.data().common_dir, format);
        defer if (branch) |b| gpa.free(b);
        const config = try repo.readConfig(io, .{
            .system = options.system_config,
            .xdg = options.xdg_config,
            .global = options.global_config,
            .local = .{ .dir = repo.data().common_dir, .sub_path = "config" },
            .command = options.config_overrides,
            .pairs = options.config_pairs,
        }, .{ .git_dir = git_dir_path, .branch = branch, .home = options.home }, format, null);
        repo.data()._config = try config_owner.create(config);
        errdefer config_owner.destroy(repo.data()._config);
        repo.data().shared = try sharedOf(repo.configuration());
        var odb_options = options.odb;
        odb_options.shared = repo.data().shared;
        repo.data().odb = try odb_mod.Odb.open(gpa, io, repo.data().common_dir, format.kind, odb_options);
        errdefer repo.data().odb.deinit(io);
        repo.data().odb.shallow = try shallow.read(gpa, io, repo.data().common_dir, format.kind);
        const store = try gpa.create(refs_mod.Store);
        errdefer gpa.destroy(store);
        var stack_options: reftablestack.Options = if (format.ref_storage == .reftable) try reftableOptions(repo.configuration()) else .{};
        stack_options.shared = repo.data().shared;
        store.* = try refs_mod.Store.init(gpa, format.kind, repo.data().git_dir, repo.data().common_dir, .{
            .format = format.ref_storage,
            .reftable = stack_options,
            .shared = repo.data().shared,
            .packed_lock = try lockTimeout(repo.configuration(), "core.packedrefstimeout", 1000),
        });
        repo.data()._refs = @ptrCast(store); // safe: the opaque owner retains this allocated Store.
        return repo;
    }

    /// Read `sources`, with this worktree's `config.worktree` after the
    /// local file when the repository's `format` turns
    /// `extensions.worktreeConfig` on and none otherwise: the file has no
    /// say in the format. `worktree_contents`, when given, is read as that
    /// file's bytes: a write about to land there.
    fn readConfig(repo: *Repository, io: Io, sources: config_mod.Sources, context: config_mod.Context, format: RepositoryFormat, worktree_contents: ?[]const u8) ErrorNamespace.Error!config_mod.Config {
        var read = sources;
        read.worktree = if (format.worktree_config)
            .{ .dir = repo.data().git_dir, .sub_path = "config.worktree", .contents = worktree_contents }
        else
            null;
        return config_mod.Config.open(repo.data().gpa, io, read, context);
    }

    /// Read the configuration again if a file it came from has changed since
    /// it was read, or `HEAD` is on another branch than it was, which an
    /// `includeIf "onbranch:"` depends on, and say whether it read it.
    ///
    /// A daemon holding a repository for days calls this where it wants
    /// another process's `git config` to count — before an operation, say —
    /// and it costs a read of each file the configuration came from,
    /// includes among them, and of `HEAD`, and a parse only when one
    /// differs. Edits made through `editConfig` stay, read after the files
    /// as `-c` values are. A configuration that no longer passes `open`'s
    /// checks is that check's error, and the one held before is kept. A
    /// changed hash or ref backend requires reopening
    /// (`ObjectFormatChanged`, `RefStorageChanged`). `diagnostic`, when
    /// given, names the refusal and is cleared on every call.
    pub fn refreshConfig(repo: *Repository, io: Io, diagnostic: ?*Diagnostic) Self.Error!bool {
        diagnostic_mod.reset(diagnostic);
        // `onbranch:` makes the branch `HEAD` is on part of what was read.
        const short = try branchOf(repo.data().gpa, io, repo.refStore());
        defer if (short) |b| repo.data().gpa.free(b);
        const same_branch = if (repo.configuration().context.branch) |was|
            short != null and std.mem.eql(u8, was, short.?)
        else
            short == null;
        if (same_branch and !try repo.configuration().isStale(io)) return false;
        var context = repo.configuration().context;
        context.branch = short;
        const format = try repository_format.read(repo.data().gpa, io, repo.data().common_dir, diagnostic);
        var fresh = try repo.readConfig(io, repo.configuration().sources, context, format, null);
        errdefer fresh.deinit();
        try repo.publishConfig(fresh, format, diagnostic);
        return true;
    }

    /// The `.git` directory's path as git matches it in a `gitdir:`
    /// condition: absolute, symbolic links resolved, `/`-separated.
    fn absoluteGitDir(io: Io, git_dir: Io.Dir, buffer: []u8) ErrorNamespace.Error![]const u8 {
        const len = try git_dir.realPath(io, buffer);
        const path = buffer[0..len];
        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');
        return path;
    }

    /// The branch `HEAD` is on, without `refs/heads/` and the caller's, or
    /// `null` when it is detached: read through a ref store over the
    /// directories in `format`, before the repository has its own. An
    /// unborn branch counts, as it does for git's `onbranch:`.
    fn currentBranch(gpa: Allocator, io: Io, git_dir: Io.Dir, common_dir: Io.Dir, format: RepositoryFormat) ErrorNamespace.Error!?[]u8 {
        var store = try refs_mod.Store.init(gpa, format.kind, git_dir, common_dir, .{ .format = format.ref_storage });
        defer store.deinit();
        return branchOf(gpa, io, &store);
    }

    /// The branch `HEAD` names in `store`, for `onbranch:`: a `HEAD` that
    /// cannot be read names none, as git's `include_by_branch` finds none,
    /// and the repository still opens.
    fn branchOf(gpa: Allocator, io: Io, store: *const refs_mod.Store) ErrorNamespace.Error!?[]u8 {
        return store.currentBranch(gpa, io) catch |err| switch (err) {
            error.MalformedRef, error.SymbolicRefLoop, error.InvalidRefName => null,
            else => |e| e,
        };
    }

    /// The `reftable.*` settings, for the stack's writes and compactions.
    /// `core.sharedRepository`, as git reads it.
    fn sharedOf(config: *const config_mod.Config) ErrorNamespace.Error!fs.Shared {
        const entry = config.find("core.sharedrepository") orelse return .umask;
        const value = entry.value orelse return .group;
        return fs.Shared.parse(value) catch error.InvalidSharedMode;
    }

    fn reftableOptions(config: *const config_mod.Config) ErrorNamespace.Error!reftablestack.Options {
        var options: reftablestack.Options = .{};
        const block_size = try config.getInt("reftable.blocksize", options.write.block_size);
        if (block_size > 0 and block_size < (1 << 24)) options.write.block_size = @intCast(block_size);
        const restart = try config.getInt("reftable.restartinterval", options.write.restart_interval);
        if (restart > 0 and restart <= std.math.maxInt(u16)) options.write.restart_interval = @intCast(restart);
        options.write.index_objects = try config.getBool("reftable.indexobjects", true);
        const factor = try config.getInt("reftable.geometricfactor", options.geometric_factor);
        if (factor > 0 and factor <= std.math.maxInt(u8)) options.geometric_factor = @intCast(factor);
        options.lock = try lockTimeout(config, "reftable.locktimeout", 100);
        return options;
    }

    /// A lock timeout in milliseconds, as git reads one: zero means try
    /// once, a negative number means wait for ever, which here is as long
    /// as a wait can be written down.
    fn lockTimeout(config: *const config_mod.Config, key: []const u8, default: i64) ErrorNamespace.Error!fs.OnContention {
        const timeout = try config.getInt(key, default);
        if (timeout == 0) return .fail;
        if (timeout < 0) return .{ .wait_ms = std.math.maxInt(u32) };
        return .{ .wait_ms = std.math.cast(u32, timeout) orelse std.math.maxInt(u32) };
    }

    fn refuseSetting(diagnostic: ?*Diagnostic, text: []const u8) Allocator.Error!void {
        try diagnostic_mod.refuse(diagnostic, text);
    }

    /// Create a repository at `dir`.
    ///
    /// Writes `HEAD`, `config`, `objects/`, `refs/heads`, `refs/tags` and
    /// `info/`, which is what a repository needs to be one.
    pub fn create(gpa: Allocator, io: Io, dir: Io.Dir, options: CreateOptions) Self.Error!Repository {
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

        // git copies the templates first, and reads the configuration they
        // leave before it writes its own
        var shared: fs.Shared = options.shared orelse .umask;
        var logs_set = false;
        if (options.template) |template| {
            if (try templateUsable(gpa, io, template)) try copyTemplate(gpa, io, template, git_dir, shared);
            if (try fs.readFileAlloc(gpa, io, git_dir, "config", 1 << 20)) |text| {
                defer gpa.free(text);
                var template_config = try config_mod.Config.parseText(gpa, text, .local);
                defer template_config.deinit();
                if (options.shared == null) shared = template_config.sharedPermissions();
                // a template's own choice stands
                logs_set = template_config.has("core.logallrefupdates");
            }
        }
        fs.adjustShared(io, git_dir, ".", shared);

        try fs.makeDirs(io, git_dir, "objects/pack", shared);
        try fs.makeDirs(io, git_dir, "objects/info", shared);
        try git_dir.createDirPath(io, "info");

        // The refs as the format lays them down, then `HEAD` on the unborn
        // branch, written as the first ref and logged nowhere, as git's
        // `init` writes it.
        try refs_mod.create(io, git_dir, options.ref_format, .{ .shared = shared });
        {
            const target = try std.mem.concat(gpa, u8, &.{ "refs/heads/", options.default_branch });
            defer gpa.free(target);
            var store = try refs_mod.Store.init(gpa, options.object_format, git_dir, git_dir, .{
                .format = options.ref_format,
                .reftable = .{ .shared = shared },
                .shared = shared,
            });
            defer store.deinit();
            var tx = store.begin(gpa);
            defer tx.deinit(io);
            try tx.update("HEAD", .{ .symbolic = target }, .any);
            try tx.commit(io, null);
        }

        try initConfig(gpa, io, git_dir, options, shared, logs_set);

        const work_dir: ?Io.Dir = if (options.bare) null else try dir.openDir(io, ".", .{ .iterate = true });
        const discovered: Discovered = .{
            .git_dir = git_dir,
            .common_dir = git_dir,
            .work_dir = work_dir,
            .common_is_separate = false,
        };
        return finish(gpa, io, discovered, .{ .discover = false, .odb = options.odb });
    }

    /// The configuration of a new repository: the values git's `init` sets
    /// one by one, as `git config` would, in its order, in the template's
    /// file when there is one and a new one when not.
    fn initConfig(gpa: Allocator, io: Io, git_dir: Io.Dir, options: CreateOptions, shared: fs.Shared, logs_set: bool) ErrorNamespace.Error!void {
        var edits: std.ArrayList(ConfigEdit) = .empty;
        defer edits.deinit(gpa);
        const version = if (options.object_format == .sha1 and options.ref_format == .files) "0" else "1";
        try edits.append(gpa, .{ .set = .{ .name = "core.repositoryformatversion", .value = version } });
        if (options.object_format != .sha1) try edits.append(gpa, .{ .set = .{ .name = "extensions.objectformat", .value = options.object_format.name() } });
        if (options.ref_format != .files) try edits.append(gpa, .{ .set = .{ .name = "extensions.refstorage", .value = options.ref_format.name() } });
        try edits.append(gpa, .{ .set = .{ .name = "core.filemode", .value = if (options.file_mode) "true" else "false" } });
        try edits.append(gpa, .{ .set = .{ .name = "core.bare", .value = if (options.bare) "true" else "false" } });
        if (!options.bare and !logs_set) try edits.append(gpa, .{ .set = .{ .name = "core.logallrefupdates", .value = "true" } });
        if (!options.symlinks) try edits.append(gpa, .{ .set = .{ .name = "core.symlinks", .value = "false" } });
        if (options.ignore_case) try edits.append(gpa, .{ .set = .{ .name = "core.ignorecase", .value = "true" } });
        if (options.precompose_unicode) |p| try edits.append(gpa, .{ .set = .{ .name = "core.precomposeunicode", .value = if (p) "true" else "false" } });
        var shared_buf: [8]u8 = undefined;
        if (sharedSetting(shared, &shared_buf)) |value| {
            try edits.append(gpa, .{ .set = .{ .name = "core.sharedrepository", .value = value } });
            try edits.append(gpa, .{ .set = .{ .name = "receive.denyNonFastforwards", .value = "true" } });
        }
        _ = config_write.editFile(gpa, io, git_dir, "config", .local, shared, edits.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // unreachable: every key is one of git's own, and the one file
            // read is the one written
            error.InvalidKey, error.NoWritableSource => unreachable,
            else => |e| return e,
        };
    }

    /// How `git init` writes a shared mode: `1` and `2` for the old names,
    /// `0` and the octal digits for a mode.
    fn sharedSetting(shared: fs.Shared, buf: *[8]u8) ?[]const u8 {
        return switch (shared) {
            .umask => null,
            .group => "1",
            .everybody => "2",
            // unreachable: a u16 is at most six octal digits after the zero
            .mode => |m| std.mem.print(buf, "0{o}", .{m}) catch unreachable,
        };
    }

    /// Whether a template's own `config`, when it has one, is of a format
    /// git copies from: a `core.repositoryformatversion` of 0 or 1, or
    /// none.
    fn templateUsable(gpa: Allocator, io: Io, template: Io.Dir) ErrorNamespace.Error!bool {
        const text = (try fs.readFileAlloc(gpa, io, template, "config", 1 << 20)) orelse return true;
        defer gpa.free(text);
        var config = config_mod.Config.parseText(gpa, text, .local) catch return false;
        defer config.deinit();
        if (!config.has("core.repositoryformatversion")) return true;
        const version = config.getInt("core.repositoryformatversion", 0) catch return false;
        return version == 0 or version == 1;
    }

    /// git's `copy_templates_1`: every entry of `from` but a dotfile, into
    /// `to`, a directory merged, anything already there kept, a symbolic
    /// link copied as one and a file with its executable bit.
    fn copyTemplate(gpa: Allocator, io: Io, from: Io.Dir, to: Io.Dir, shared: fs.Shared) ErrorNamespace.Error!void {
        var it = from.iterate();
        while (try it.next(io)) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const exists = if (to.statFile(io, entry.name, .{ .follow_symlinks = false })) |_| true else |_| false;
            switch (entry.kind) {
                .directory => {
                    if (!exists) {
                        try to.createDir(io, entry.name, .default_dir);
                        fs.adjustShared(io, to, entry.name, shared);
                    }
                    var sub_from = try from.openDir(io, entry.name, .{ .iterate = true });
                    defer sub_from.close(io);
                    var sub_to = try to.openDir(io, entry.name, .{ .iterate = true });
                    defer sub_to.close(io);
                    try copyTemplate(gpa, io, sub_from, sub_to, shared);
                },
                .sym_link => {
                    if (exists) continue;
                    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
                    const n = from.readLink(io, entry.name, &buf) catch continue;
                    to.symLink(io, buf[0..n], entry.name, .{}) catch continue;
                },
                .file => {
                    if (exists) continue;
                    const stat = try from.statFile(io, entry.name, .{});
                    const executable = fs.isExecutable(stat.permissions);
                    const bytes = try from.readFileAlloc(io, entry.name, gpa, .limited(1 << 30));
                    defer gpa.free(bytes);
                    const file = try to.createFile(io, entry.name, .{ .exclusive = true, .permissions = fs.permissionsFor(executable) });
                    defer file.close(io);
                    try file.writeStreamingAll(io, bytes);
                    fs.adjustShared(io, to, entry.name, shared);
                },
                else => {},
            }
        }
    }

    /// Close everything the repository holds.
    pub fn deinit(repo: *Repository, io: Io) void {
        if (repo.data().lfsconfig_cache) |c| if (c.text) |t| repo.data().gpa.free(t);
        repo.data()._commits.deinit(repo.data().gpa);
        repo.refStore().deinit();
        repo.data().gpa.destroy(repo.refStore());
        repo.data().odb.deinit(io);
        config_owner.destroy(repo.data()._config);
        // One handle, closed once, when the common directory is not separate.
        if (!repo.data().common_is_separate) assert(repo.data().common_dir.handle == repo.data().git_dir.handle);
        if (repo.data().common_is_separate) repo.data().common_dir.close(io);
        repo.data().git_dir.close(io);
        if (repo.data().work_dir) |w| w.close(io);
        const gpa = repo.data().gpa;
        gpa.destroy(repo.data());
        repo.* = undefined;
    }

    /// The hash chosen when the repository was opened. A change requires reopening.
    pub fn objectFormat(repo: *const Repository) hash.Kind {
        return repo.refStore().objectFormat();
    }

    /// The repository owns this store; callers borrow it for ref operations.
    /// Its backend and cache cannot be assigned separately.
    pub fn refStore(repo: *const Repository) *refs_mod.Store {
        return @ptrCast(@alignCast(repo.data()._refs)); // safe: finish allocates _refs as an aligned Store.
    }

    /// The last published configuration, borrowed until an edit, a write,
    /// a refresh or the repository's close. Change it through the
    /// repository (`writeConfig`, `editConfig`) to keep its stores and
    /// configuration policy in agreement.
    pub fn configuration(repo: *const Repository) *const config_mod.Config {
        return config_owner.get(repo.data()._config);
    }

    /// One change `writeConfig` makes to a configuration file.
    pub const ConfigEdit = config_write.Edit;

    /// Which of the repository's own configuration files `writeConfig`
    /// writes.
    pub const ConfigFile = enum {
        /// `config` in the common directory, which every worktree shares.
        local,
        /// This worktree's own `config.worktree`; with
        /// `extensions.worktreeConfig` off, the shared file, as git's
        /// `repo_config_set_worktree_gently` falls back.
        worktree,
    };

    /// Errors from writing a configuration file.
    pub const WriteConfigError = ErrorNamespace.Error || config_write.Error;

    /// What a configuration write did beside setting values.
    pub const WriteOutcome = config_write.Outcome;

    /// Persist `edits` to one of this repository's configuration files, as
    /// git's `repo_config_set_multivar_in_file_gently` does, and publish
    /// what the files then say.
    ///
    /// The file is read again under its lock and only `edits` are applied
    /// to it, so what another process wrote since this repository read it
    /// stays. Before the file is replaced the configuration it would leave
    /// is read whole and checked as `refreshConfig` checks it: a change of
    /// hash or ref backend (`ObjectFormatChanged`, `RefStorageChanged`), or
    /// a setting `open` would refuse, writes nothing. Then the file keeps
    /// its mode, is put in place, and that configuration is published,
    /// memory-only edits replayed over it. `diagnostic`, when given, names
    /// a refusal and is cleared on every call.
    pub fn writeConfig(repo: *Repository, io: Io, file: ConfigFile, edits: []const ConfigEdit, diagnostic: ?*Diagnostic) WriteConfigError!WriteOutcome {
        diagnostic_mod.reset(diagnostic);
        const current = repo.configuration();
        const worktree_file = file == .worktree and current.sources.worktree != null;
        var pending = if (worktree_file)
            try config_write.prepare(repo.data().gpa, io, repo.data().git_dir, "config.worktree", .worktree, repo.data().shared, edits)
        else
            try config_write.prepare(repo.data().gpa, io, repo.data().common_dir, "config", .local, repo.data().shared, edits);
        defer pending.deinit(io);

        var sources = current.sources;
        if (!worktree_file) sources.local.?.contents = pending.contents();
        // The format is the shared file's to say: the bytes about to land
        // there, or the file as it is.
        const format = if (worktree_file)
            try repository_format.read(repo.data().gpa, io, repo.data().common_dir, diagnostic)
        else
            try repository_format.parse(repo.data().gpa, pending.contents(), diagnostic);
        // `onbranch:` is decided against the branch `HEAD` is on now, as a
        // refresh decides it.
        const branch = try branchOf(repo.data().gpa, io, repo.refStore());
        defer if (branch) |b| repo.data().gpa.free(b);
        var context = current.context;
        context.branch = branch;
        var fresh = try repo.readConfig(io, sources, context, format, if (worktree_file) pending.contents() else null);
        errdefer fresh.deinit();
        const policy = try repo.checkConfig(&fresh, format, diagnostic);
        pending.commit(io) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => |e| return e,
        };
        repo.installConfig(fresh, policy);
        return pending.outcome;
    }

    /// Persist `edits` to a configuration file that is not this
    /// repository's own: a submodule's under `modules/`, or the main
    /// worktree's `config.worktree` seen from a linked one. The file is
    /// read again under its lock and given this repository's permissions,
    /// as `writeConfig` does; what this repository publishes is unchanged.
    pub fn writeConfigFile(repo: *const Repository, io: Io, dir: Io.Dir, sub_path: []const u8, edits: []const ConfigEdit) config_write.Error!WriteOutcome {
        return config_write.editFile(repo.data().gpa, io, dir, sub_path, .local, repo.data().shared, edits);
    }

    /// Errors from `editConfig`.
    pub const EditConfigError = ErrorNamespace.Error || config_mod.Config.SetError;

    /// Set `values` in memory, over every file and every `-c` value given
    /// at open, as later `-c` values are: never written, and kept through
    /// `refreshConfig` and `writeConfig`, which read them after the files.
    /// A name set again replaces what memory held for it. No file is read:
    /// the published configuration takes the values, and the whole batch is
    /// checked as `open` checks a configuration before it replaces the one
    /// published. The repository's format is its own file's to say, so a
    /// value for `core.repositoryFormatVersion` or an `extensions.*` is
    /// refused (`FormatEditInMemory`); `writeConfig` writes one.
    pub fn editConfig(repo: *Repository, io: Io, values: []const config_mod.Sources.Pair, diagnostic: ?*Diagnostic) EditConfigError!void {
        diagnostic_mod.reset(diagnostic);
        for (values) |value| {
            const key = try config_mod.checkKey(value.name);
            const format_key = (std.ascii.eqlIgnoreCase(key.section, "extensions") and key.subsection == null) or
                (std.ascii.eqlIgnoreCase(key.section, "core") and key.subsection == null and std.ascii.eqlIgnoreCase(key.name, "repositoryformatversion"));
            if (format_key) {
                try refuseSetting(diagnostic, value.name);
                return error.FormatEditInMemory;
            }
        }
        const current = repo.configuration();
        var pairs: std.ArrayList(config_mod.Sources.Pair) = .empty;
        defer pairs.deinit(repo.data().gpa);
        for (current.sources.pairs) |pair| {
            const replaced = for (values) |value| {
                if (sameKey(pair.name, value.name)) break true;
            } else false;
            if (!replaced) try pairs.append(repo.data().gpa, pair);
        }
        try pairs.appendSlice(repo.data().gpa, values);
        var next = try current.withCommandValues(io, current.sources.command, pairs.items);
        errdefer next.deinit();
        const format: RepositoryFormat = .{ .kind = repo.objectFormat(), .ref_storage = repo.refStore().refFormat() };
        try repo.publishConfig(next, format, diagnostic);
    }

    /// Whether two full names are one key: section and name without case,
    /// the subsection exactly, as git compares them.
    fn sameKey(a: []const u8, b: []const u8) bool {
        const x = config_mod.splitFullName(a) orelse return false;
        const y = config_mod.splitFullName(b) orelse return false;
        if (!std.ascii.eqlIgnoreCase(x.section, y.section) or !std.ascii.eqlIgnoreCase(x.name, y.name)) return false;
        const xs = x.subsection orelse return y.subsection == null;
        const ys = y.subsection orelse return false;
        return std.mem.eql(u8, xs, ys);
    }

    /// What publishing a configuration changes beside it: the ref store's
    /// write policy, checked before anything is replaced.
    const ConfigPolicy = struct {
        ref_options: reftablestack.Options,
    };

    /// Whether `next` may be published, and the policy it sets: the same
    /// hash and ref backend the repository was opened with, and settings
    /// the stores can take.
    fn checkConfig(repo: *const Repository, next: *const config_mod.Config, format: RepositoryFormat, diagnostic: ?*Diagnostic) ErrorNamespace.Error!ConfigPolicy {
        if (format.kind != repo.objectFormat()) {
            try refuseSetting(diagnostic, "extensions.objectFormat");
            return error.ObjectFormatChanged;
        }
        if (format.ref_storage != repo.refStore().refFormat()) {
            try refuseSetting(diagnostic, "extensions.refStorage");
            return error.RefStorageChanged;
        }
        return .{ .ref_options = if (format.ref_storage == .reftable)
            try reftableOptions(next)
        else
            repo.refStore().reftableOptions() };
    }

    /// Replace the published configuration with `next`, which it takes,
    /// and the policy `checkConfig` gave for it.
    fn installConfig(repo: *Repository, next: config_mod.Config, policy: ConfigPolicy) void {
        config_owner.get(repo.data()._config).deinit();
        config_owner.get(repo.data()._config).* = next;
        repo.refStore().configureReftable(policy.ref_options);
    }

    fn publishConfig(repo: *Repository, next: config_mod.Config, format: RepositoryFormat, diagnostic: ?*Diagnostic) ErrorNamespace.Error!void {
        repo.installConfig(next, try repo.checkConfig(&next, format, diagnostic));
    }

    /// Whether the repository has a working tree.
    pub fn isBare(repo: *const Repository) bool {
        return repo.data().work_dir == null;
    }

    /// The `core` settings that take part in line-ending conversion.
    /// Invalid settings and allocation failures are returned to the caller.
    pub fn coreSettings(repo: *const Repository) Self.Error!attributes.CoreSettings {
        return .{
            .autocrlf = try repo.coreChoice(attributes.CoreSettings.AutoCrlf, true, "core.autocrlf", .false),
            .eol = try repo.coreChoice(attributes.CoreSettings.Eol, false, "core.eol", .native),
            .safecrlf = try repo.coreChoice(attributes.CoreSettings.SafeCrlf, true, "core.safecrlf", .false),
        };
    }

    fn coreChoice(repo: *const Repository, comptime T: type, comptime boolean: bool, setting: []const u8, fallback: T) ErrorNamespace.Error!T {
        const text = repo.configuration().get(setting) orelse return fallback;
        if (T == fs.Stat.Check and std.ascii.eqlIgnoreCase(text, "default")) return .full;
        inline for (@typeInfo(T).@"enum".field_names) |name| {
            if ((!boolean or (!std.mem.eql(u8, name, "true") and !std.mem.eql(u8, name, "false"))) and std.ascii.eqlIgnoreCase(text, name)) return @field(T, name);
        }
        if (boolean) return if (try repo.configuration().getBool(setting, false)) .true else .false;
        return error.MalformedValue;
    }

    /// The rules a working-tree operation needs, with `ignore` and `attrs`
    /// left for the caller to fill in. Invalid settings and resource failures
    /// are returned instead of replacing the configured policy with defaults.
    pub fn worktreeRules(repo: *const Repository) Self.Error!worktree.Rules {
        return .{
            .core = try repo.coreSettings(),
            .ignore_case = try repo.configuration().getBool("core.ignorecase", false),
            .check_stat = try repo.coreChoice(@TypeOf(@as(worktree.Rules, .{}).check_stat), false, "core.checkstat", .full),
            .timestamp_resolution = repo.data().odb.timestamp_resolution,
            .file_mode = try repo.configuration().getBool("core.filemode", Io.File.Permissions.has_executable_bit),
            .symlinks = try repo.configuration().getBool("core.symlinks", builtin.target.os.tag != .windows),
        };
    }

    /// Load the ignore rules for the working tree's root.
    ///
    /// The result is the caller's, and a walk pushes and pops deeper levels
    /// into it as it goes.
    pub fn loadIgnore(repo: *Repository, io: Io) Self.Error!ignore.Rules {
        const case_fold = try repo.configuration().getBool("core.ignorecase", false);
        var rules = try ignore.Rules.init(repo.data().gpa, case_fold);
        errdefer rules.deinit();
        const excludes = try repo.configuration().getPath(repo.data().gpa, "core.excludesfile");
        defer if (excludes) |p| repo.data().gpa.free(p);
        try rules.loadGlobal(io, repo.data().common_dir, excludes, Io.Dir.cwd());
        return rules;
    }

    /// Errors from naming one of the repository's files as a path.
    pub const PathError = Allocator.Error || Io.Dir.RealPathFileAllocError ||
        std.process.CurrentPathAllocError || error{MalformedValue};

    /// The files `loadIgnore` reads, named.
    pub fn ignoreSources(repo: *const Repository, gpa: Allocator, io: Io) PathError!IgnoreSources {
        const common = try repo.data().common_dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(common);
        const info_exclude = try std.Io.Dir.path.join(gpa, &.{ common, "info", "exclude" });
        errdefer gpa.free(info_exclude);
        const configured = try repo.configuration().getPath(gpa, "core.excludesfile");
        defer if (configured) |path| gpa.free(path);
        const excludes_file: ?[]u8 = if (configured) |path| blk: {
            if (std.Io.Dir.path.isAbsolute(path)) break :blk try gpa.dupe(u8, path);
            const cwd = try std.process.currentPathAlloc(io, gpa);
            defer gpa.free(cwd);
            break :blk try std.Io.Dir.path.join(gpa, &.{ cwd, path });
        } else null;
        return .{ .excludes_file = excludes_file, .info_exclude = info_exclude };
    }

    /// The index `openIndex` reads, as an absolute path on `gpa`: `index`
    /// in the per-worktree directory, so a linked worktree's own. It need
    /// not exist.
    pub fn indexPath(repo: *const Repository, gpa: Allocator, io: Io) PathError![]u8 {
        const git_dir = try repo.data().git_dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(git_dir);
        return std.Io.Dir.path.join(gpa, &.{ git_dir, "index" });
    }

    /// Load the attributes for the working tree's root.
    pub fn loadAttrs(repo: *Repository, io: Io) Self.Error!attributes.Attrs {
        const case_fold = try repo.configuration().getBool("core.ignorecase", false);
        var attrs = try attributes.Attrs.init(repo.data().gpa, case_fold);
        errdefer attrs.deinit();
        const file = try repo.configuration().getPath(repo.data().gpa, "core.attributesfile");
        defer if (file) |p| repo.data().gpa.free(p);
        try attrs.loadGlobal(io, repo.data().common_dir, file, Io.Dir.cwd());
        return attrs;
    }

    /// The filter names whose `filter.<name>.required` is true. The result
    /// is the caller's.
    ///
    /// A repository naming one of these in its attributes is refused, by
    /// name, rather than handed a blob git would not write.
    pub fn requiredFilters(repo: *const Repository, gpa: Allocator) config_mod.ValueError![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        const names = try repo.configuration().subsections(gpa, "filter");
        defer gpa.free(names);
        for (names) |name| {
            const key = try gpa.print("filter.{s}.required", .{name});
            defer gpa.free(key);
            const required = try repo.configuration().getBool(key, false);
            if (required) try out.append(gpa, name);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Configured filters and an optional caller-selected native provider,
    /// for `worktree.Rules.filters`. The result is the caller's, and borrows
    /// the repository's directories for as long as it lives.
    pub fn loadFilters(repo: *Repository, io: Io, options: filter.Drivers.Options) LoadFiltersError!filter.Drivers {
        var with = options;
        var text: ?[]u8 = null;
        defer if (text) |t| repo.data().gpa.free(t);
        if (with.native_provider != null and with.config_text == null) {
            text = try repo.lfsconfigText(io);
            with.config_text = text;
        }
        return filter.Drivers.load(repo.data().gpa, io, repo.configuration(), .{ .common = repo.data().common_dir, .work = repo.data().work_dir }, with);
    }

    /// Errors from `loadFilters`: the drivers', and those of finding
    /// `.lfsconfig` for relic's own LFS.
    pub const LoadFiltersError = filter.Drivers.LoadError || LfsconfigError;

    /// Errors from finding `.lfsconfig`.
    pub const LfsconfigError = Allocator.Error || Io.Dir.ReadFileAllocError ||
        index_mod.ReadError || odb_mod.Error || ErrorNamespace.Error || Io.Dir.StatFileError ||
        Io.File.OpenError || Io.File.StatError || Io.File.ReadPositionalError || Io.Cancelable;

    /// `.lfsconfig` as git-lfs finds it: the file at the top of the working
    /// tree, else its version in the index, else its version in `HEAD`;
    /// only `HEAD`'s in a bare repository. `null` when none of them has
    /// one. The text is the caller's, in the repository's allocator.
    ///
    /// What was found is kept with what it was found from — the working
    /// tree file's size, times and inode, the index's own checksum and
    /// stat, `HEAD`'s commit — and handed out again while those stay the
    /// same, so a status that asks each time reads neither the index nor
    /// `HEAD`'s tree again.
    pub fn lfsconfigText(repo: *Repository, io: Io) LfsconfigError!?[]u8 {
        try repo.data().lfsconfig_mutex.lock(io);
        defer repo.data().lfsconfig_mutex.unlock(io);
        const key = try repo.lfsconfigKey(io);
        if (repo.data().lfsconfig_cache) |cached| {
            // Windows file timestamps can stay unchanged when a same-size
            // worktree file is rewritten immediately. Re-read that small
            // file rather than handing out stale settings.
            if (std.meta.eql(cached.key, key) and !(builtin.target.os.tag == .windows and key.worktree != null)) {
                return if (cached.text) |t| try repo.data().gpa.dupe(u8, t) else null;
            }
        }
        const text = try repo.lfsconfigTextUncached(io, key);
        errdefer if (text) |t| repo.data().gpa.free(t);
        const kept = if (text) |t| try repo.data().gpa.dupe(u8, t) else null;
        if (repo.data().lfsconfig_cache) |old| if (old.text) |t| repo.data().gpa.free(t);
        repo.data().lfsconfig_cache = .{ .key = key, .text = kept };
        return text;
    }

    fn lfsconfigKey(repo: *Repository, io: Io) LfsconfigError!LfsconfigKey {
        var key: LfsconfigKey = .{};
        if (repo.data().work_dir) |wd| {
            if (wd.statFile(io, ".lfsconfig", .{})) |st| {
                if (st.kind != .directory) {
                    key.worktree = .of(st);
                    return key;
                }
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => |e| return e,
            }
            if (repo.data().git_dir.openFile(io, "index", .{})) |file| {
                defer file.close(io);
                const st = try file.stat(io);
                var stamp: IndexStamp = .{ .file = .of(st) };
                const n = repo.objectFormat().rawLen();
                if (st.size >= n) _ = try file.readPositionalAll(io, stamp.checksum[0..n], st.size - n);
                key.index = stamp;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }
        if (try repo.head(io)) |h| {
            repo.data().gpa.free(h.name);
            key.head = h.oid;
        }
        return key;
    }

    fn lfsconfigTextUncached(repo: *Repository, io: Io, key: LfsconfigKey) LfsconfigError!?[]u8 {
        if (repo.data().work_dir) |wd| {
            if (key.worktree != null) {
                if (try fs.readFileAlloc(repo.data().gpa, io, wd, ".lfsconfig", 1 << 20)) |text| return text;
            }
            var index = repo.openIndex(io) catch |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            };
            if (index) |*ix| {
                defer ix.deinit();
                if (ix.find(".lfsconfig")) |entry| {
                    if (entry.stage == 0 and (entry.mode == .file or entry.mode == .exec)) {
                        const found = try repo.data().odb.read(io, entry.oid);
                        return found.bytes;
                    }
                }
            }
        }
        const tree = (try repo.headTree(io)) orelse return null;
        const found = try repo.data().odb.read(io, tree);
        defer repo.data().odb.allocator().free(found.bytes);
        const entry = (object.Tree.parse(repo.objectFormat(), found.bytes).find(".lfsconfig") catch return null) orelse return null;
        if (entry.mode != .file and entry.mode != .exec) return null;
        const blob = try repo.data().odb.read(io, entry.oid);
        return blob.bytes;
    }

    /// Errors from `writeIndex`.
    pub const WriteIndexError = index_mod.WriteError || ErrorNamespace.Error;

    /// Open the repository's own index.
    /// Write `index` as this repository's index, as git writes one: a
    /// racily clean entry is smudged only where its file changed, read
    /// through the repository's own rules and attributes.
    pub fn writeIndex(repo: *Repository, io: Io, index: *index_mod.Index) WriteIndexError!void {
        const wt = repo.data().work_dir orelse return index.write(io, repo.data().git_dir, "index", .{ .lock = .{ .shared = repo.data().shared } });
        var attrs = try repo.loadAttrs(io);
        defer attrs.deinit();
        var rules = try repo.worktreeRules();
        rules.attrs = &attrs;
        var check: worktree.RacyCheck = .{ .gpa = repo.data().gpa, .io = io, .wt = wt, .rules = rules };
        try index.write(io, repo.data().git_dir, "index", .{ .racy = check.racy(), .lock = .{ .shared = repo.data().shared } });
    }

    pub fn openIndex(repo: *Repository, io: Io) index_mod.ReadError!index_mod.Index {
        return index_mod.Index.readWithResolution(
            repo.data().gpa,
            io,
            repo.data().git_dir,
            "index",
            repo.data().common_dir,
            repo.objectFormat(),
            repo.data().odb.timestamp_resolution,
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
        return index_mod.Index.read(repo.data().gpa, io, dir, sub_path, repo.data().common_dir, repo.objectFormat());
    }

    /// What `HEAD` resolves to, or `null` on an unborn branch.
    ///
    /// The returned name is the caller's.
    pub fn head(repo: *Repository, io: Io) refs_mod.ReadError!?refs_mod.Resolved {
        return repo.refStore().head(repo.data().gpa, io);
    }

    /// The tree `HEAD` points at, or `null` on an unborn branch.
    pub fn headTree(repo: *Repository, io: Io) Self.Error!?Oid {
        const resolved = (try repo.head(io)) orelse return null;
        defer repo.data().gpa.free(resolved.name);
        const tree = try repo.commitTree(io, resolved.oid);
        return tree;
    }

    /// The tree a commit points at.
    pub fn commitTree(repo: *Repository, io: Io, commit_oid: Oid) Self.Error!Oid {
        return (try repo.commitInfo(io, commit_oid, null)).tree;
    }

    /// A commit's tree and parents, as its object records them, the
    /// parents copied with `out` (none without it). Each commit is read
    /// once per repository handle and kept, a bounded number of them.
    pub fn commitInfo(repo: *Repository, io: Io, commit_oid: Oid, out: ?Allocator) Self.Error!commit_cache.Info {
        return repo.data()._commits.get(repo.data().gpa, io, &repo.data().odb, commit_oid, .{ .out = out });
    }

    /// Follow a tag object until it names something that is not a tag, and
    /// return that object's name.
    pub fn peel(repo: *Repository, io: Io, oid: Oid) Self.Error!Oid {
        var current = oid;
        var depth: u8 = 0;
        while (depth < 16) : (depth += 1) {
            const header = try repo.data().odb.readHeader(io, current);
            if (header.type != .tag) return current;
            const found = try repo.data().odb.read(io, current);
            defer repo.data().gpa.free(found.bytes);
            var tag = try object.Tag.parse(repo.data().gpa, repo.objectFormat(), found.bytes);
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
    /// `diagnostic`, when given, keeps the refused setting or signing stderr
    /// and is cleared on every call.
    pub fn writeCommit(repo: *Repository, io: Io, request: CommitRequest, diagnostic: ?*Diagnostic) Self.WriteError!Oid {
        diagnostic_mod.reset(diagnostic);
        const fields: object.Commit.Fields = .{
            .tree = request.tree,
            .parents = request.parents,
            .author = request.author,
            .committer = request.committer,
            .encoding = request.encoding,
            .extra = request.extra,
            .message = request.message,
        };
        var signer = try repo.signerFor(request.signing, .commit, diagnostic);
        defer if (signer) |*s| s.deinit();
        const bytes = (if (signer) |*s|
            signing.signCommit(io, s, repo.objectFormat(), fields, request.signing.key)
        else
            object.Commit.build(repo.data().gpa, repo.objectFormat(), fields)) catch |err| {
            if (err == error.SigningFailed) try diagnostic_mod.signingFailure(diagnostic, signer.?.diagnostics.items);
            return err;
        };
        defer repo.data().gpa.free(bytes);
        return repo.data().odb.write(io, .commit, bytes);
    }

    /// Write an annotated tag object. `tag.gpgSign` or
    /// `tag.forceSignAnnotated` makes it signed, which needs `writeTagWith`
    /// and the caller's `Programs`; here it is refused.
    /// `diagnostic` has the same lifetime as it does for `writeCommit`.
    /// Write an annotated tag object, signed as `request` and the
    /// configuration say, with the signature after the message.
    /// `diagnostic` has the same lifetime as it does for `writeCommit`.
    pub const TagOptions = struct {
        signing: signing.Request = .{},
        diagnostic: ?*Diagnostic = null,
    };

    pub fn writeTag(repo: *Repository, io: Io, fields: object.Tag.Fields, options: TagOptions) Self.WriteError!Oid {
        const request = options.signing;
        const diagnostic = options.diagnostic;
        diagnostic_mod.reset(diagnostic);
        var signer = try repo.signerFor(request, .tag, diagnostic);
        defer if (signer) |*s| s.deinit();
        const bytes = (if (signer) |*s|
            signing.signTag(io, s, repo.objectFormat(), fields, request.key)
        else
            object.Tag.build(repo.data().gpa, repo.objectFormat(), fields)) catch |err| {
            if (err == error.SigningFailed) try diagnostic_mod.signingFailure(diagnostic, signer.?.diagnostics.items);
            return err;
        };
        defer repo.data().gpa.free(bytes);
        return repo.data().odb.write(io, .tag, bytes);
    }

    /// The signer a write needs, or `null` when it is not to be signed.
    /// The same decision names the setting that requires programs.
    fn signerFor(repo: *Repository, request: signing.Request, target: enum { commit, tag }, diagnostic: ?*Diagnostic) WriteError!?signing.Signer {
        const primary = switch (target) {
            .commit => "commit.gpgSign",
            .tag => "tag.gpgSign",
        };
        const setting = switch (request.sign) {
            .always => "",
            .never => return null,
            .config => configured: {
                if (try settingBool(repo.configuration(), primary, diagnostic)) break :configured primary;
                if (target == .tag and try settingBool(repo.configuration(), "tag.forceSignAnnotated", diagnostic))
                    break :configured "tag.forceSignAnnotated";
                return null;
            },
        };
        const programs = request.programs orelse {
            if (setting.len != 0) try refuseSetting(diagnostic, setting);
            return error.SigningRequiresPrograms;
        };
        return signing.Signer.init(repo.data().gpa, repo.configuration(), programs) catch |err| {
            switch (err) {
                error.UnknownSignatureFormat => try refuseSetting(diagnostic, "gpg.format"),
                error.UnknownTrustLevel => try refuseSetting(diagnostic, "gpg.minTrustLevel"),
                else => {},
            }
            return err;
        };
    }

    fn settingBool(config: *const config_mod.Config, setting: []const u8, diagnostic: ?*Diagnostic) config_mod.ValueError!bool {
        return config.getBool(setting, false) catch |err| {
            if (err == error.NotABoolean) try refuseSetting(diagnostic, setting);
            return err;
        };
    }

    /// The reflog policy `core.logAllRefUpdates` asks for.
    ///
    /// A repository with a working tree defaults to writing logs for
    /// branches; a bare one defaults to writing them only where one already
    /// exists, which is git's rule.
    pub fn reflogPolicy(repo: *const Repository) refs_mod.LogPolicy {
        if (repo.configuration().get("core.logallrefupdates")) |text| return refs_mod.LogPolicy.parse(text);
        return if (repo.isBare()) .existing_only else .standard;
    }

    /// Begin a ref transaction over this repository.
    ///
    /// The transaction peels an annotated tag it writes through this
    /// repository's objects, which a reftable records beside the tag as git
    /// does. The repository must outlive the transaction.
    pub fn beginRefs(repo: *Repository) refs_mod.Transaction {
        var tx = repo.refStore().begin(repo.data().gpa);
        tx.peeler = .{ .context = repo, .peel = peelForRefs };
        return tx;
    }

    fn peelForRefs(io: Io, context: *anyopaque, oid: Oid) ?Oid {
        const repo: *Repository = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Repository
        const header = repo.data().odb.readHeader(io, oid) catch return null;
        if (header.type != .tag) return null;
        return repo.peel(io, oid) catch null;
    }

    /// Errors from `readLog`.
    pub const ReadLogError = refs_mod.ReadError || refs_mod.LogReadError;

    /// A ref's log, oldest first, whichever format the refs are kept in.
    pub fn readLog(repo: *Repository, io: Io, name: []const u8) ReadLogError!refs_mod.Log {
        return repo.refStore().readLog(repo.data().gpa, io, name);
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
        return hooks.Runner.init(repo.data().gpa, io, .{
            .config = repo.configuration(),
            .git_dir = repo.data().git_dir,
            .common_dir = repo.data().common_dir,
            .work_dir = repo.data().work_dir,
        }, programs, options);
    }

    /// Every linked worktree.
    pub fn listWorktrees(repo: *Repository, io: Io) worktrees.Error!worktrees.Listing {
        return worktrees.list(repo.data().gpa, io, repo.refStore());
    }

    /// Remove the administrative directories whose working tree is gone,
    /// skipping any with a `locked` file.
    pub fn pruneWorktrees(repo: *Repository, io: Io) worktrees.Error!worktrees.PruneOutcome {
        return worktrees.prune(repo.data().gpa, io, repo.refStore());
    }
};

test "reading a signing policy allocates nothing of the configuration's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try Self.Repository.create(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    try repo.editConfig(io, &.{.{ .name = "tag.gpgSign", .value = "true" }}, null);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(repo.data()._config).gpa;
    config_gpa.* = failing.allocator();
    defer config_gpa.* = gpa;
    var diagnostic = Self.Diagnostic.init(gpa);
    defer diagnostic.deinit();
    // The policy is read, and a tag it says to sign has nothing to sign
    // with.
    try std.testing.expectError(error.SigningRequiresPrograms, repo.writeTag(io, .{
        .target = hash.Hasher.object(.sha1, "tree", ""),
        .target_type = .tree,
        .name = "t",
        .message = "m",
    }, .{ .diagnostic = &diagnostic }));
    try std.testing.expectEqualStrings("tag.gpgSign", diagnostic.unsupported_setting);
}

test "worktree configuration adapters refuse malformed settings, and read a quoted one without allocating" {
    const Adapter = struct {
        fn core(r: *const Self.Repository) !@import("../patterns/attributes.zig").CoreSettings {
            return r.coreSettings();
        }
        fn rules(r: *const Self.Repository) !worktree.Rules {
            return r.worktreeRules();
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try Self.Repository.create(gpa, io, tmp.dir, .{});
    defer repo.deinit(io);
    inline for (.{ "core.autocrlf", "core.safecrlf", "core.ignorecase", "core.filemode", "core.symlinks" }) |setting| {
        try repo.editConfig(io, &.{.{ .name = setting, .value = "maybe" }}, null);
        try std.testing.expectError(error.NotABoolean, Adapter.rules(&repo));
        try repo.editConfig(io, &.{.{ .name = setting, .value = "false" }}, null);
    }
    inline for (.{ "core.eol", "core.checkstat" }) |setting| {
        try repo.editConfig(io, &.{.{ .name = setting, .value = "unknown" }}, null);
        try std.testing.expectError(error.MalformedValue, Adapter.rules(&repo));
        try repo.editConfig(io, &.{.{ .name = setting, .value = if (comptime std.mem.eql(u8, setting, "core.eol")) "native" else "default" }}, null);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\n autocrlf = \"input\"\n" });
    var reread = try Self.Repository.open(gpa, io, tmp.dir, .{});
    defer reread.deinit(io);
    try std.testing.expectEqual(@import("../patterns/attributes.zig").CoreSettings.AutoCrlf.input, (try Adapter.core(&reread)).autocrlf);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(reread.data()._config).gpa;
    config_gpa.* = failing.allocator();
    defer config_gpa.* = gpa;
    // The value was read once, quotes and all, when the file was.
    try std.testing.expectEqual(@import("../patterns/attributes.zig").CoreSettings.AutoCrlf.input, (try Adapter.core(&reread)).autocrlf);
}

test "rule loaders refuse a malformed case policy, and read one without the configuration allocating" {
    const Load = struct {
        fn ignoreRules(io: Io, r: *Self.Repository) !void {
            var rules = try r.loadIgnore(io);
            defer rules.deinit();
        }
        fn attributesRules(io: Io, r: *Self.Repository) !void {
            var rules = try r.loadAttrs(io);
            defer rules.deinit();
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = try Self.Repository.create(gpa, io, tmp.dir, .{});
    defer r.deinit(io);
    try r.editConfig(io, &.{.{ .name = "core.ignorecase", .value = "maybe" }}, null);
    try std.testing.expectError(error.NotABoolean, Load.ignoreRules(io, &r));
    try std.testing.expectError(error.NotABoolean, Load.attributesRules(io, &r));
    try r.editConfig(io, &.{.{ .name = "core.ignorecase", .value = "true" }}, null);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(r.data()._config).gpa;
    config_gpa.* = failing.allocator();
    defer config_gpa.* = gpa;
    try Load.ignoreRules(io, &r);
    try Load.attributesRules(io, &r);
}

test "required filter discovery keeps full names, and reads the policy without the configuration allocating" {
    const Read = struct {
        fn count(r: *Self.Repository) !usize {
            const names = try r.requiredFilters(r.allocator());
            defer r.allocator().free(names);
            return names.len;
        }
    };
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = try Self.Repository.create(gpa, io, tmp.dir, .{});
    defer r.deinit(io);
    const long_name = &@as([300]u8, @splat('x'));
    try r.editConfig(io, &.{.{ .name = "filter." ++ long_name ++ ".required", .value = "true" }}, null);
    const names = try r.requiredFilters(gpa);
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings(long_name, names[0]);
    // The values were read when the file was: asking for them allocates
    // nothing of the configuration's.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(r.data()._config).gpa;
    config_gpa.* = failing.allocator();
    defer config_gpa.* = gpa;
    try std.testing.expectEqual(@as(usize, 1), try Read.count(&r));
}
