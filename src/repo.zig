//! The front door: open or create a repository and reach everything in it.
//!
//! A repository is a local directory. Nothing here talks to a network or
//! reads a clock. Signing a write needs the caller's `program.Programs`.

const Self = @This();

pub const warning = @import("repo/warning.zig");
// The modules relic's API puts under this one, as `relic.repo.<name>`.
pub const hooks = @import("repo/hooks.zig");
pub const program = @import("repo/program.zig");

pub const fs = @import("repo/fs.zig");
pub const safe = @import("repo/safe.zig");
pub const ident = @import("repo/ident.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const index_mod = @import("index.zig");
const refs_mod = @import("refs.zig");
const reflog = @import("refs/reflog.zig");
const config_mod = @import("config.zig");
const commit_cache = @import("commit/cache.zig");
const shallow = @import("revwalk/shallow.zig");
const ignore = @import("worktree/ignore.zig");
const attributes = @import("worktree/attributes.zig");
const worktree = @import("worktree.zig");
const worktrees = @import("worktree/worktrees.zig");
const filter = @import("worktree/filter.zig");
const reftablestack = @import("refs/reftablestack.zig");
const signing = @import("commit/signing.zig");
const diagnostic_mod = @import("repo/diagnostic.zig");

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
    /// An in-memory edit changes which configuration files apply. Write
    /// that change with a standalone Config and refresh the repository.
    WorktreeConfigChanged,
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
pub const OpenDiagnostic = Diagnostic;

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

/// `init.templateDir` in `config`, as git reads it for `git init`, with
/// `~/` expanded; `null` when it is not set. The path is `gpa`'s.
pub fn templateDir(gpa: Allocator, config: *const config_mod.Config) (Allocator.Error || error{MalformedValue})!?[]u8 {
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
const config_owner = @import("config/state.zig");

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
    /// Owned ref state. Its format and cache are opaque to callers.
    _refs: *RefState,
    /// Opaque ownership of what the configuration files held at `open`, or when `refreshConfig`
    /// last found one changed. Nothing reads them again behind the caller's
    /// back, so another process's `git config` is seen after a
    /// `refreshConfig` and not before. The operations that read a file
    /// fresh from the disk are the ones that write it: a submodule's
    /// settings are edited in `.git/config` as read at that moment. An
    /// `includeIf` is decided against this repository's `.git` directory
    /// and the branch `HEAD` was on when the files were read.
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
        defer if (current_owned) current.close(io);
        var depth: u8 = 0;
        while (true) : (depth += 1) {
            if (depth > max_discovery_depth) break;

            // A `.git` directory here?
            if (current.openDir(io, ".git", .{ .iterate = true })) |git_dir| {
                errdefer git_dir.close(io);
                const work = try current.openDir(io, ".", .{ .iterate = true });
                errdefer work.close(io);
                try checkOwnership(gpa, io, options, null, work, git_dir);
                return withCommon(gpa, io, git_dir, work);
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
                errdefer git_dir.close(io);
                const work = try current.openDir(io, ".", .{ .iterate = true });
                errdefer work.close(io);
                try checkOwnership(gpa, io, options, work, work, git_dir);
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
        return error.NotARepository;
    }

    /// The settings a repository cannot write itself: the system, global
    /// and command-line ones, which git's `git_protected_config` reads.
    fn protectedConfig(gpa: Allocator, io: Io, options: OpenOptions) Error!config_mod.Config {
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
    fn checkOwnership(gpa: Allocator, io: Io, options: OpenOptions, gitfile_in: ?Io.Dir, work: ?Io.Dir, git_dir: Io.Dir) Error!void {
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
    fn checkBare(gpa: Allocator, io: Io, options: OpenOptions, git_dir: Io.Dir) Error!void {
        if (options.explicit) return;
        var protected = try protectedConfig(gpa, io, options);
        defer protected.deinit();
        if (safe.bareRepositories(&protected) == .all) return;
        const real = git_dir.realPathFileAlloc(io, ".", gpa) catch return error.ImplicitBareRepository;
        defer gpa.free(real);
        const path = try safe.normalize(gpa, real);
        defer gpa.free(path);
        if (!safe.isImplicitBare(path)) {
            try refuseSetting(options.diagnostic, "safe.bareRepository");
            return error.ImplicitBareRepository;
        }
    }

    fn withCommon(gpa: Allocator, io: Io, git_dir: Io.Dir, work_dir: ?Io.Dir) Error!Discovered {
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
            ._config = undefined,
            .odb = undefined,
            ._refs = undefined,
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
            .xdg = options.xdg_config,
            .global = options.global_config,
            .local = .{ .dir = repo.common_dir, .sub_path = "config" },
            .command = options.config_overrides,
            .pairs = options.config_pairs,
        }, .{ .git_dir = git_dir_path, .branch = if (branch) |b| b["refs/heads/".len..] else null, .home = options.home }, options.diagnostic);
        repo._config = try config_owner.create(read.config);
        errdefer config_owner.destroy(repo._config);
        repo.shared = try sharedOf(repo.configuration());
        var odb_options = options.odb;
        odb_options.shared = repo.shared;
        repo.odb = try odb_mod.Odb.open(gpa, io, repo.common_dir, read.format.kind, odb_options);
        errdefer repo.odb.deinit(io);
        repo.odb.shallow = try shallow.read(gpa, io, repo.common_dir, read.format.kind);
        const store = try gpa.create(refs_mod.Store);
        errdefer gpa.destroy(store);
        var stack_options: reftablestack.Options = if (read.format.ref_storage == .reftable) try reftableOptions(repo.configuration()) else .{};
        stack_options.shared = repo.shared;
        store.* = try refs_mod.Store.initWithOptions(gpa, read.format.kind, repo.git_dir, repo.common_dir, .{
            .format = read.format.ref_storage,
            .reftable = stack_options,
            .shared = repo.shared,
        });
        repo._refs = @ptrCast(store); // safe: the opaque owner retains this allocated Store.
        return repo;
    }

    /// Read `sources` — every one but the worktree's — and check the format
    /// they name; then, when `extensions.worktreeConfig` is on, read them
    /// again with `config.worktree` after the local file, which exists only
    /// when the extension says so and has no say in the format.
    fn readConfig(repo: *Repository, io: Io, sources: config_mod.Sources, context: config_mod.Context, diagnostic: ?*Diagnostic) Error!struct { config: config_mod.Config, format: RepositoryFormat } {
        var config = try config_mod.Config.open(repo.gpa, io, sources, context);
        errdefer config.deinit();
        const format = try checkFormat(&config, diagnostic);
        if (!try settingBool(&config, "extensions.worktreeConfig", diagnostic)) return .{ .config = config, .format = format };
        var with_worktree = sources;
        with_worktree.worktree = .{ .dir = repo.git_dir, .sub_path = "config.worktree" };
        const both = try config_mod.Config.open(repo.gpa, io, with_worktree, context);
        config.deinit();
        return .{ .config = both, .format = format };
    }

    const RepositoryFormat = struct {
        kind: hash.Kind,
        ref_storage: refs_mod.Format,
    };

    /// Decide the repository's format once, from the configuration shared
    /// by its worktrees. A worktree's settings have no say in this decision.
    fn checkFormat(config: *const config_mod.Config, diagnostic: ?*Diagnostic) Error!RepositoryFormat {
        const version = try config.getInt("core.repositoryformatversion", 0);
        if (version < 0 or version > 1) {
            try refuseSetting(diagnostic, "core.repositoryFormatVersion");
            return error.UnsupportedRepositoryVersion;
        }
        if (version == 1) try checkExtensions(config, diagnostic);
        const kind = if (config.get("extensions.objectformat")) |text|
            hash.Kind.parse(text) catch {
                try refuseSetting(diagnostic, "extensions.objectFormat");
                return error.UnknownObjectFormat;
            }
        else
            hash.Kind.sha1;
        const storage = config.get("extensions.refstorage") orelse "files";
        return .{
            .kind = kind,
            .ref_storage = if (version == 1 and std.ascii.eqlIgnoreCase(storage, "reftable")) .reftable else .files,
        };
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
    /// through `editConfig` in memory and never written are replaced by what the
    /// files hold. A configuration that no longer passes `open`'s checks is
    /// that check's error, and the one held before is kept. A changed hash or
    /// ref backend requires reopening (`ObjectFormatChanged`, `RefStorageChanged`).
    /// `diagnostic`, when given, names the refusal and is cleared on every call.
    pub fn refreshConfig(repo: *Repository, io: Io, diagnostic: ?*Diagnostic) Self.Error!bool {
        diagnostic_mod.reset(diagnostic);
        // `onbranch:` makes the branch `HEAD` is on part of what was read.
        const branch = try currentBranch(repo.gpa, io, repo.git_dir);
        defer if (branch) |b| repo.gpa.free(b);
        const short = if (branch) |b| b["refs/heads/".len..] else null;
        const same_branch = if (repo.configuration().context.branch) |was|
            short != null and std.mem.eql(u8, was, short.?)
        else
            short == null;
        if (same_branch and !try repo.configuration().isStale(io)) return false;
        var sources = repo.configuration().sources;
        sources.worktree = null;
        var context = repo.configuration().context;
        context.branch = short;
        var fresh = try repo.readConfig(io, sources, context, diagnostic);
        errdefer fresh.config.deinit();
        try repo.publishConfig(fresh.config, fresh.format, diagnostic);
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
                    else => |e| return e,
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
        const branch = try gpa.dupe(u8, target);
        return branch;
    }

    /// The `reftable.*` settings, for the stack's writes and compactions.
    /// `core.sharedRepository`, as git reads it.
    fn sharedOf(config: *const config_mod.Config) Error!fs.Shared {
        const entry = config.find("core.sharedrepository") orelse return .umask;
        const raw = entry.value orelse return .group;
        const value = config_mod.unquote(config.gpa, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSharedMode,
        };
        defer config.gpa.free(value);
        return fs.Shared.parse(value) catch error.InvalidSharedMode;
    }

    fn reftableOptions(config: *const config_mod.Config) Error!reftablestack.Options {
        var options: reftablestack.Options = .{};
        const block_size = try config.getInt("reftable.blocksize", options.write.block_size);
        if (block_size > 0 and block_size < (1 << 24)) options.write.block_size = @intCast(block_size);
        const restart = try config.getInt("reftable.restartinterval", options.write.restart_interval);
        if (restart > 0 and restart <= std.math.maxInt(u16)) options.write.restart_interval = @intCast(restart);
        options.write.index_objects = try config.getBool("reftable.indexobjects", true);
        const factor = try config.getInt("reftable.geometricfactor", options.geometric_factor);
        if (factor > 0 and factor <= std.math.maxInt(u8)) options.geometric_factor = @intCast(factor);
        // git's reading: zero means try once, a negative number means wait
        // for ever, which here is as long as a wait can be written down.
        const timeout = try config.getInt("reftable.locktimeout", 100);
        options.lock = if (timeout == 0)
            .fail
        else if (timeout < 0)
            .{ .wait_ms = std.math.maxInt(u32) }
        else
            .{ .wait_ms = std.math.cast(u32, timeout) orelse std.math.maxInt(u32) };
        return options;
    }

    fn refuseSetting(diagnostic: ?*Diagnostic, text: []const u8) Allocator.Error!void {
        try diagnostic_mod.refuse(diagnostic, text);
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
        // A partial clone's promisor remote, as git before 2.44 names it;
        // the objects it may be asked for are read as any others.
        "partialclone",
    };

    fn checkExtensions(config: *const config_mod.Config, diagnostic: ?*Diagnostic) Error!void {
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "extensions")) continue;
            var known = false;
            for (known_extensions) |name| {
                if (std.ascii.eqlIgnoreCase(entry.name, name)) known = true;
            }
            if (!known) {
                try refuseSetting(diagnostic, entry.name);
                return error.UnsupportedExtension;
            }
            if (std.ascii.eqlIgnoreCase(entry.name, "refstorage")) {
                const value = entry.value orelse "";
                if (!std.ascii.eqlIgnoreCase(value, "files") and !std.ascii.eqlIgnoreCase(value, "reftable")) {
                    try refuseSetting(diagnostic, "extensions.refStorage");
                    return error.UnsupportedRefStorage;
                }
            }
        }
    }

    /// Create a repository at `dir`.
    ///
    /// Writes `HEAD`, `config`, `objects/`, `refs/heads`, `refs/tags` and
    /// `info/`, which is what a repository needs to be one.
    pub fn init(gpa: Allocator, io: Io, dir: Io.Dir, options: InitOptions) Self.Error!Repository {
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
        if (options.template) |template| {
            if (try templateUsable(gpa, io, template)) try copyTemplate(gpa, io, template, git_dir, shared);
            if (options.shared == null) {
                if (try fs.readFileAlloc(gpa, io, git_dir, "config", 1 << 20)) |text| {
                    defer gpa.free(text);
                    var template_config = try config_mod.Config.parseText(gpa, text, .local);
                    defer template_config.deinit();
                    shared = template_config.sharedPermissions();
                }
            }
        }
        fs.adjustShared(io, git_dir, ".", shared);

        try fs.makeDirs(io, git_dir, "objects/pack", shared);
        try fs.makeDirs(io, git_dir, "objects/info", shared);
        try git_dir.createDirPath(io, "info");

        var head_buf: [512]u8 = undefined;
        switch (options.ref_format) {
            .files => {
                try fs.makeDirs(io, git_dir, "refs/heads", shared);
                try fs.makeDirs(io, git_dir, "refs/tags", shared);
                const head_line = std.fmt.bufPrint(&head_buf, "ref: refs/heads/{s}\n", .{options.default_branch}) catch
                    return error.NotARepository;
                try git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = head_line });
                fs.adjustShared(io, git_dir, "HEAD", shared);
            },
            .reftable => {
                const target = std.fmt.bufPrint(&head_buf, "refs/heads/{s}", .{options.default_branch}) catch
                    return error.NotARepository;
                try reftablestack.initialize(gpa, io, git_dir, options.object_format, .{ .symbolic = target }, null, .{});
            },
        }

        const version: u8 = if (options.object_format == .sha1 and options.ref_format == .files) 0 else 1;
        if (git_dir.access(io, "config", .{})) |_| {
            try initTemplateConfig(gpa, io, git_dir, options, version, shared);
        } else |_| try initConfig(gpa, io, git_dir, options, version, shared);

        const work_dir: ?Io.Dir = if (options.bare) null else try dir.openDir(io, ".", .{ .iterate = true });
        const discovered: Discovered = .{
            .git_dir = git_dir,
            .common_dir = git_dir,
            .work_dir = work_dir,
            .common_is_separate = false,
        };
        return finish(gpa, io, discovered, .{ .discover = false, .odb = options.odb });
    }

    /// The configuration of a new repository with none from a template:
    /// the lines git's `init` sets, in its order.
    fn initConfig(gpa: Allocator, io: Io, git_dir: Io.Dir, options: InitOptions, version: u8, shared: fs.Shared) Error!void {
        var config_text: std.Io.Writer.Allocating = .init(gpa);
        defer config_text.deinit();
        const w = &config_text.writer;
        w.print("[core]\n", .{}) catch return error.OutOfMemory;
        w.print("\trepositoryformatversion = {d}\n", .{version}) catch return error.OutOfMemory;
        w.print("\tfilemode = {s}\n", .{if (options.file_mode) "true" else "false"}) catch return error.OutOfMemory;
        w.print("\tbare = {s}\n", .{if (options.bare) "true" else "false"}) catch return error.OutOfMemory;
        if (!options.bare) {
            w.print("\tlogallrefupdates = true\n", .{}) catch return error.OutOfMemory;
        }
        if (!options.symlinks) w.print("\tsymlinks = false\n", .{}) catch return error.OutOfMemory;
        if (options.ignore_case) w.print("\tignorecase = true\n", .{}) catch return error.OutOfMemory;
        if (options.precompose_unicode) |p| w.print("\tprecomposeunicode = {s}\n", .{if (p) "true" else "false"}) catch return error.OutOfMemory;
        var shared_buf: [8]u8 = undefined;
        if (sharedSetting(shared, &shared_buf)) |value| w.print("\tsharedrepository = {s}\n", .{value}) catch return error.OutOfMemory;
        if (options.object_format != .sha1 or options.ref_format == .reftable) {
            w.print("[extensions]\n", .{}) catch return error.OutOfMemory;
        }
        if (options.object_format != .sha1) {
            w.print("\tobjectformat = {s}\n", .{options.object_format.name()}) catch return error.OutOfMemory;
        }
        if (options.ref_format == .reftable) {
            w.print("\trefstorage = reftable\n", .{}) catch return error.OutOfMemory;
        }
        if (shared != .umask) w.print("[receive]\n\tdenyNonFastforwards = true\n", .{}) catch return error.OutOfMemory;
        try git_dir.writeFile(io, .{ .sub_path = "config", .data = config_text.written() });
        fs.adjustShared(io, git_dir, "config", shared);
    }

    /// How `git init` writes a shared mode: `1` and `2` for the old names,
    /// `0` and the octal digits for a mode.
    fn sharedSetting(shared: fs.Shared, buf: *[8]u8) ?[]const u8 {
        return switch (shared) {
            .umask => null,
            .group => "1",
            .everybody => "2",
            // unreachable: a u16 is at most six octal digits after the zero
            .mode => |m| std.fmt.bufPrint(buf, "0{o}", .{m}) catch unreachable,
        };
    }

    /// A template's configuration, carried on: git's `init` sets its own
    /// values in it one by one, as `git config` would, a template's
    /// `core.logallrefupdates` kept.
    fn initTemplateConfig(gpa: Allocator, io: Io, git_dir: Io.Dir, options: InitOptions, version: u8, shared: fs.Shared) Error!void {
        var config = try config_mod.Config.openFile(gpa, io, .{ .dir = git_dir, .sub_path = "config" }, .local, .{});
        defer config.deinit();
        const set = struct {
            fn one(c: *config_mod.Config, name: []const u8, value: []const u8) Error!void {
                c.set(name, value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.MalformedValue,
                };
            }
        }.one;
        if (options.object_format != .sha1) try set(&config, "extensions.objectformat", options.object_format.name());
        if (options.ref_format == .reftable) try set(&config, "extensions.refstorage", "reftable");
        var version_buf: [4]u8 = undefined;
        // unreachable: a u8 is at most three digits
        try set(&config, "core.repositoryformatversion", std.fmt.bufPrint(&version_buf, "{d}", .{version}) catch unreachable);
        try set(&config, "core.filemode", if (options.file_mode) "true" else "false");
        try set(&config, "core.bare", if (options.bare) "true" else "false");
        if (!options.bare and !config.has("core.logallrefupdates")) try set(&config, "core.logallrefupdates", "true");
        if (!options.symlinks) try set(&config, "core.symlinks", "false");
        if (options.ignore_case) try set(&config, "core.ignorecase", "true");
        if (options.precompose_unicode) |p| try set(&config, "core.precomposeunicode", if (p) "true" else "false");
        var shared_buf: [8]u8 = undefined;
        if (sharedSetting(shared, &shared_buf)) |value| {
            try set(&config, "core.sharedrepository", value);
            try set(&config, "receive.denyNonFastforwards", "true");
        }
        config.write(io, git_dir, "config") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedValue,
        };
    }

    /// Whether a template's own `config`, when it has one, is of a format
    /// git copies from: a `core.repositoryformatversion` of 0 or 1, or
    /// none.
    fn templateUsable(gpa: Allocator, io: Io, template: Io.Dir) Error!bool {
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
    fn copyTemplate(gpa: Allocator, io: Io, from: Io.Dir, to: Io.Dir, shared: fs.Shared) Error!void {
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
        if (repo.lfsconfig_cache) |c| if (c.text) |t| repo.gpa.free(t);
        repo._commits.deinit(repo.gpa);
        repo.refStore().deinit();
        repo.gpa.destroy(repo.refStore());
        repo.odb.deinit(io);
        config_owner.destroy(repo._config);
        if (repo.common_is_separate) repo.common_dir.close(io);
        repo.git_dir.close(io);
        if (repo.work_dir) |w| w.close(io);
        repo.* = undefined;
    }

    /// The hash chosen when the repository was opened. A change requires reopening.
    pub fn objectFormat(repo: *const Repository) hash.Kind {
        return repo.refStore().objectFormat();
    }

    /// The repository owns this store; callers borrow it for ref operations.
    /// Its backend and cache cannot be assigned separately.
    pub fn refStore(repo: *const Repository) *refs_mod.Store {
        return @ptrCast(@alignCast(repo._refs)); // safe: finish allocates _refs as an aligned Store.
    }

    /// The last published configuration, borrowed until an edit, refresh
    /// or repository close. Edit through the repository to keep its stores
    /// and configuration policy in agreement.
    pub fn configuration(repo: *const Repository) *const config_mod.Config {
        return config_owner.get(repo._config);
    }

    pub const ConfigEdit = union(enum) {
        set: struct { name: []const u8, value: []const u8, level: ?config_mod.Level = null },
        unset: struct { name: []const u8, level: ?config_mod.Level = null },
        remove_section: struct { section: []const u8, subsection: ?[]const u8 = null, level: config_mod.Level },
    };

    /// Apply a batch in memory, publishing only after every edit and the
    /// resulting repository policy pass. No file is written. Format or
    /// backend changes require reopening and retain the previous policy.
    /// Changes to worktree configuration sources require a standalone
    /// configuration write followed by refresh (`WorktreeConfigChanged`).
    pub fn editConfig(repo: *Repository, edits: []const ConfigEdit, diagnostic: ?*Diagnostic) (Error || config_mod.Config.SetError)!void {
        diagnostic_mod.reset(diagnostic);
        var next = try config_owner.copy(repo.gpa, repo.configuration());
        errdefer next.deinit();
        for (edits) |edit| switch (edit) {
            .set => |e| if (e.level) |level| try next.setIn(level, e.name, e.value) else try next.set(e.name, e.value),
            .unset => |e| if (e.level) |level| try next.unsetIn(level, e.name) else try next.unset(e.name),
            .remove_section => |e| _ = try next.removeSectionIn(e.level, e.section, e.subsection),
        };
        const policy = try sharedConfigPolicy(&next, diagnostic);
        // A memory-only edit cannot read or drop the worktree sources.
        // Refresh owns that filesystem transition after a standalone write.
        if (policy.worktree_config != (repo.configuration().sources.worktree != null)) {
            try refuseSetting(diagnostic, "extensions.worktreeConfig");
            return error.WorktreeConfigChanged;
        }
        try repo.publishConfig(next, policy.format, diagnostic);
    }

    fn sharedConfigPolicy(config: *const config_mod.Config, diagnostic: ?*Diagnostic) Error!struct { format: RepositoryFormat, worktree_config: bool } {
        var entries: std.ArrayList(config_mod.Entry) = .empty;
        defer entries.deinit(config.gpa);
        for (config.entries.items) |entry| {
            if (entry.level != .worktree) try entries.append(config.gpa, entry);
        }
        // Only the entry array belongs to this view; all file bytes remain
        // borrowed for the check. Worktree settings have no say in format
        // or in whether their own source is read, just as during open.
        var shared = config.*;
        shared.entries = entries;
        return .{
            .format = try checkFormat(&shared, diagnostic),
            .worktree_config = try settingBool(&shared, "extensions.worktreeConfig", diagnostic),
        };
    }

    fn publishConfig(repo: *Repository, next: config_mod.Config, format: RepositoryFormat, diagnostic: ?*Diagnostic) Error!void {
        if (format.kind != repo.objectFormat()) {
            try refuseSetting(diagnostic, "extensions.objectFormat");
            return error.ObjectFormatChanged;
        }
        if (format.ref_storage != repo.refStore().refFormat()) {
            try refuseSetting(diagnostic, "extensions.refStorage");
            return error.RefStorageChanged;
        }
        const ref_options = if (format.ref_storage == .reftable)
            try reftableOptions(&next)
        else
            repo.refStore().reftableOptions();
        config_owner.get(repo._config).deinit();
        config_owner.get(repo._config).* = next;
        repo.refStore().configureReftable(ref_options);
    }

    /// Whether the repository has a working tree.
    pub fn isBare(repo: *const Repository) bool {
        return repo.work_dir == null;
    }

    /// The `core` settings that take part in line-ending conversion.
    /// Invalid settings and allocation failures are returned to the caller.
    pub fn coreSettings(repo: *const Repository) Self.Error!attributes.CoreSettings {
        return .{
            .autocrlf = try repo.coreChoice(attributes.CoreSettings.AutoCrlf, "core.autocrlf", .false, true),
            .eol = try repo.coreChoice(attributes.CoreSettings.Eol, "core.eol", .native, false),
            .safecrlf = try repo.coreChoice(attributes.CoreSettings.SafeCrlf, "core.safecrlf", .false, true),
        };
    }

    fn coreChoice(repo: *const Repository, comptime T: type, setting: []const u8, fallback: T, comptime boolean: bool) Error!T {
        const raw = repo.configuration().get(setting) orelse return fallback;
        const text = try config_mod.unquote(repo.configuration().gpa, raw);
        defer repo.configuration().gpa.free(text);
        if (T == fs.Stat.Check and std.ascii.eqlIgnoreCase(text, "default")) return .full;
        inline for (@typeInfo(T).@"enum".fields) |field| {
            if ((!boolean or (!std.mem.eql(u8, field.name, "true") and !std.mem.eql(u8, field.name, "false"))) and std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
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
            .check_stat = try repo.coreChoice(@TypeOf(@as(worktree.Rules, .{}).check_stat), "core.checkstat", .full, false),
            .timestamp_resolution = repo.odb.timestamp_resolution,
            .file_mode = try repo.configuration().getBool("core.filemode", Io.File.Permissions.has_executable_bit),
            .symlinks = try repo.configuration().getBool("core.symlinks", @import("builtin").os.tag != .windows),
        };
    }

    /// Load the ignore rules for the working tree's root.
    ///
    /// The result is the caller's, and a walk pushes and pops deeper levels
    /// into it as it goes.
    pub fn loadIgnore(repo: *Repository, io: Io) Self.Error!ignore.Rules {
        const case_fold = try repo.configuration().getBool("core.ignorecase", false);
        var rules = try ignore.Rules.init(repo.gpa, case_fold);
        errdefer rules.deinit();
        const excludes = try repo.configuration().getPath(repo.gpa, "core.excludesfile");
        defer if (excludes) |p| repo.gpa.free(p);
        try rules.loadGlobal(io, repo.common_dir, excludes, Io.Dir.cwd());
        return rules;
    }

    /// Where `loadIgnore` reads its two levels, as absolute paths on the
    /// caller's `gpa`: what a caller watching for a rule to change watches
    /// beside the working tree's own `.gitignore` files. Neither file need
    /// exist.
    pub const IgnoreSources = struct {
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

    /// Errors from naming one of the repository's files as a path.
    pub const PathError = Allocator.Error || Io.Dir.RealPathFileAllocError ||
        std.process.CurrentPathAllocError || error{MalformedValue};

    /// The files `loadIgnore` reads, named.
    pub fn ignoreSources(repo: *const Repository, gpa: Allocator, io: Io) PathError!IgnoreSources {
        const common = try repo.common_dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(common);
        const info_exclude = try std.fs.path.join(gpa, &.{ common, "info", "exclude" });
        errdefer gpa.free(info_exclude);
        const configured = try repo.configuration().getPath(gpa, "core.excludesfile");
        defer if (configured) |path| gpa.free(path);
        const excludes_file: ?[]u8 = if (configured) |path| blk: {
            if (std.fs.path.isAbsolute(path)) break :blk try gpa.dupe(u8, path);
            const cwd = try std.process.currentPathAlloc(io, gpa);
            defer gpa.free(cwd);
            break :blk try std.fs.path.join(gpa, &.{ cwd, path });
        } else null;
        return .{ .excludes_file = excludes_file, .info_exclude = info_exclude };
    }

    /// The index `openIndex` reads, as an absolute path on `gpa`: `index`
    /// in the per-worktree directory, so a linked worktree's own. It need
    /// not exist.
    pub fn indexPath(repo: *const Repository, gpa: Allocator, io: Io) PathError![]u8 {
        const git_dir = try repo.git_dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(git_dir);
        return std.fs.path.join(gpa, &.{ git_dir, "index" });
    }

    /// Load the attributes for the working tree's root.
    pub fn loadAttrs(repo: *Repository, io: Io) Self.Error!attributes.Attrs {
        const case_fold = try repo.configuration().getBool("core.ignorecase", false);
        var attrs = try attributes.Attrs.init(repo.gpa, case_fold);
        errdefer attrs.deinit();
        const file = try repo.configuration().getPath(repo.gpa, "core.attributesfile");
        defer if (file) |p| repo.gpa.free(p);
        try attrs.loadGlobal(io, repo.common_dir, file, Io.Dir.cwd());
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
            const key = try std.fmt.allocPrint(gpa, "filter.{s}.required", .{name});
            defer gpa.free(key);
            const required = try repo.configuration().getBool(key, false);
            if (required) try out.append(gpa, name);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The filter drivers the configuration defines and relic's own LFS,
    /// for `worktree.Rules.filters`. The result is the caller's, and borrows
    /// the repository's directories for as long as it lives.
    pub fn loadFilters(repo: *Repository, io: Io, options: filter.Drivers.Options) LoadFiltersError!filter.Drivers {
        var with = options;
        var text: ?[]u8 = null;
        defer if (text) |t| repo.gpa.free(t);
        if (with.native_lfs and with.lfsconfig == null) {
            text = try repo.lfsconfigText(io);
            with.lfsconfig = text;
        }
        return filter.Drivers.load(repo.gpa, io, repo.configuration(), repo.common_dir, repo.work_dir, with);
    }

    /// Errors from `loadFilters`: the drivers', and those of finding
    /// `.lfsconfig` for relic's own LFS.
    pub const LoadFiltersError = filter.Drivers.LoadError || LfsconfigError;

    /// Errors from finding `.lfsconfig`.
    pub const LfsconfigError = Allocator.Error || Io.Dir.ReadFileAllocError ||
        index_mod.ReadError || odb_mod.Error || Error || Io.Dir.StatFileError ||
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
        try repo.lfsconfig_mutex.lock(io);
        defer repo.lfsconfig_mutex.unlock(io);
        const key = try repo.lfsconfigKey(io);
        if (repo.lfsconfig_cache) |cached| {
            // Windows file timestamps can stay unchanged when a same-size
            // worktree file is rewritten immediately. Re-read that small
            // file rather than handing out stale settings.
            if (std.meta.eql(cached.key, key) and !(@import("builtin").os.tag == .windows and key.worktree != null)) {
                return if (cached.text) |t| try repo.gpa.dupe(u8, t) else null;
            }
        }
        const text = try repo.lfsconfigTextUncached(io, key);
        errdefer if (text) |t| repo.gpa.free(t);
        const kept = if (text) |t| try repo.gpa.dupe(u8, t) else null;
        if (repo.lfsconfig_cache) |old| if (old.text) |t| repo.gpa.free(t);
        repo.lfsconfig_cache = .{ .key = key, .text = kept };
        return text;
    }

    fn lfsconfigKey(repo: *Repository, io: Io) LfsconfigError!LfsconfigKey {
        var key: LfsconfigKey = .{};
        if (repo.work_dir) |wd| {
            if (wd.statFile(io, ".lfsconfig", .{})) |st| {
                if (st.kind != .directory) {
                    key.worktree = .of(st);
                    return key;
                }
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => |e| return e,
            }
            if (repo.git_dir.openFile(io, "index", .{})) |file| {
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
            repo.gpa.free(h.name);
            key.head = h.oid;
        }
        return key;
    }

    fn lfsconfigTextUncached(repo: *Repository, io: Io, key: LfsconfigKey) LfsconfigError!?[]u8 {
        if (repo.work_dir) |wd| {
            if (key.worktree != null) {
                if (try fs.readFileAlloc(repo.gpa, io, wd, ".lfsconfig", 1 << 20)) |text| return text;
            }
            var index = repo.openIndex(io) catch |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            };
            if (index) |*ix| {
                defer ix.deinit();
                if (ix.find(".lfsconfig")) |entry| {
                    if (entry.stage == 0 and (entry.mode == .file or entry.mode == .exec)) {
                        const found = try repo.odb.read(io, entry.oid);
                        return found.bytes;
                    }
                }
            }
        }
        const tree = (try repo.headTree(io)) orelse return null;
        const found = try repo.odb.read(io, tree);
        defer repo.odb.allocator().free(found.bytes);
        const entry = (object.Tree.parse(repo.objectFormat(), found.bytes).find(".lfsconfig") catch return null) orelse return null;
        if (entry.mode != .file and entry.mode != .exec) return null;
        const blob = try repo.odb.read(io, entry.oid);
        return blob.bytes;
    }

    /// Open the repository's own index.
    /// Write `index` as this repository's index, as git writes one: a
    /// racily clean entry is smudged only where its file changed, read
    /// through the repository's own rules and attributes.
    pub fn writeIndex(repo: *Repository, io: Io, index: *index_mod.Index) (index_mod.WriteError || Error)!void {
        const wt = repo.work_dir orelse return index.write(io, repo.git_dir, "index", .{ .lock = .{ .shared = repo.shared } });
        var attrs = try repo.loadAttrs(io);
        defer attrs.deinit();
        var rules = try repo.worktreeRules();
        rules.attrs = &attrs;
        var check: worktree.RacyCheck = .{ .gpa = repo.gpa, .io = io, .wt = wt, .rules = rules };
        try index.write(io, repo.git_dir, "index", .{ .racy = check.racy(), .lock = .{ .shared = repo.shared } });
    }

    pub fn openIndex(repo: *Repository, io: Io) index_mod.ReadError!index_mod.Index {
        return index_mod.Index.readWithResolution(
            repo.gpa,
            io,
            repo.git_dir,
            "index",
            repo.common_dir,
            repo.objectFormat(),
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
        return index_mod.Index.read(repo.gpa, io, dir, sub_path, repo.common_dir, repo.objectFormat());
    }

    /// What `HEAD` resolves to, or `null` on an unborn branch.
    ///
    /// The returned name is the caller's.
    pub fn head(repo: *Repository, io: Io) refs_mod.ReadError!?refs_mod.Resolved {
        return repo.refStore().head(repo.gpa, io);
    }

    /// The tree `HEAD` points at, or `null` on an unborn branch.
    pub fn headTree(repo: *Repository, io: Io) Self.Error!?Oid {
        const resolved = (try repo.head(io)) orelse return null;
        defer repo.gpa.free(resolved.name);
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
        return repo._commits.get(repo.gpa, io, &repo.odb, commit_oid, out);
    }

    /// Follow a tag object until it names something that is not a tag, and
    /// return that object's name.
    pub fn peel(repo: *Repository, io: Io, oid: Oid) Self.Error!Oid {
        var current = oid;
        var depth: u8 = 0;
        while (depth < 16) : (depth += 1) {
            const header = try repo.odb.readHeader(io, current);
            if (header.type != .tag) return current;
            const found = try repo.odb.read(io, current);
            defer repo.gpa.free(found.bytes);
            var tag = try object.Tag.parse(repo.gpa, repo.objectFormat(), found.bytes);
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
            signing.signCommit(s, io, repo.objectFormat(), fields, request.signing.key)
        else
            object.Commit.build(repo.gpa, repo.objectFormat(), fields)) catch |err| {
            if (err == error.SigningFailed) try diagnostic_mod.signingFailure(diagnostic, signer.?.diagnostics.items);
            return err;
        };
        defer repo.gpa.free(bytes);
        return repo.odb.write(io, .commit, bytes);
    }

    /// Write an annotated tag object. `tag.gpgSign` or
    /// `tag.forceSignAnnotated` makes it signed, which needs `writeTagWith`
    /// and the caller's `Programs`; here it is refused.
    /// `diagnostic` has the same lifetime as it does for `writeCommit`.
    pub fn writeTag(repo: *Repository, io: Io, fields: object.Tag.Fields, diagnostic: ?*Diagnostic) Self.WriteError!Oid {
        return repo.writeTagWith(io, fields, .{}, diagnostic);
    }

    /// Write an annotated tag object, signed as `request` and the
    /// configuration say, with the signature after the message.
    /// `diagnostic` has the same lifetime as it does for `writeCommit`.
    pub fn writeTagWith(repo: *Repository, io: Io, fields: object.Tag.Fields, request: signing.Request, diagnostic: ?*Diagnostic) Self.WriteError!Oid {
        diagnostic_mod.reset(diagnostic);
        var signer = try repo.signerFor(request, .tag, diagnostic);
        defer if (signer) |*s| s.deinit();
        const bytes = (if (signer) |*s|
            signing.signTag(s, io, repo.objectFormat(), fields, request.key)
        else
            object.Tag.build(repo.gpa, repo.objectFormat(), fields)) catch |err| {
            if (err == error.SigningFailed) try diagnostic_mod.signingFailure(diagnostic, signer.?.diagnostics.items);
            return err;
        };
        defer repo.gpa.free(bytes);
        return repo.odb.write(io, .tag, bytes);
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
        return signing.Signer.init(repo.gpa, repo.configuration(), programs) catch |err| {
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
    pub fn reflogPolicy(repo: *const Repository) reflog.Policy {
        if (repo.configuration().get("core.logallrefupdates")) |text| return reflog.Policy.parse(text);
        return if (repo.isBare()) .existing_only else .standard;
    }

    /// Begin a ref transaction over this repository.
    ///
    /// The transaction peels an annotated tag it writes through this
    /// repository's objects, which a reftable records beside the tag as git
    /// does. The repository must outlive the transaction.
    pub fn beginRefs(repo: *Repository) refs_mod.Transaction {
        var tx = repo.refStore().begin(repo.gpa);
        tx.peeler = .{ .context = repo, .peel = peelForRefs };
        return tx;
    }

    fn peelForRefs(context: *anyopaque, io: Io, oid: Oid) ?Oid {
        const repo: *Repository = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Repository
        const header = repo.odb.readHeader(io, oid) catch return null;
        if (header.type != .tag) return null;
        return repo.peel(io, oid) catch null;
    }

    /// A ref's log, oldest first, whichever format the refs are kept in.
    pub fn readLog(repo: *Repository, io: Io, name: []const u8) (refs_mod.ReadError || reflog.ReadError)!reflog.Log {
        return repo.refStore().readLog(repo.gpa, io, name);
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
            .config = repo.configuration(),
            .git_dir = repo.git_dir,
            .common_dir = repo.common_dir,
            .work_dir = repo.work_dir,
        }, programs, options);
    }

    /// Every linked worktree.
    pub fn listWorktrees(repo: *Repository, io: Io) worktrees.Error!worktrees.Listing {
        return worktrees.list(repo.gpa, io, repo.common_dir, repo.objectFormat());
    }

    /// Remove the administrative directories whose working tree is gone,
    /// skipping any with a `locked` file.
    pub fn pruneWorktrees(repo: *Repository, io: Io) worktrees.Error!worktrees.PruneOutcome {
        return worktrees.prune(repo.gpa, io, repo.common_dir, repo.objectFormat());
    }
};
