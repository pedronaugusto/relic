//! The front door: open or create a repository and reach everything in it.
//!
//! A repository is a local directory. Nothing here talks to a network or
//! reads a clock. Signing a write needs the caller's `program.Programs`.

const ErrorNamespace = @This();
const Self = @This();

// The modules relic's API puts under this one, as `relic.repo.<name>`.
const hooks = @import("../hooks/hooks.zig");
const program = @import("../process.zig").program;

const fs = @import("../fs/fs.zig");
const names_path = @import("../names/path.zig");
const names_ref = @import("../names.zig").ref;
const discover_directory = @import("../discover/directory.zig");
const safe = @import("safe.zig");
const rev_parse = @import("rev_parse.zig");

const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const odb_policy = @import("../odb/policy.zig");
const pack_mod = @import("../odb/pack.zig");
const index_mod = @import("../index/index.zig");
const untracked_mod = @import("../index/untracked.zig");
const refs_mod = @import("../refs/refs.zig");
const config_mod = @import("../config/config.zig");
const config_write = @import("../config/write.zig");
const commit_cache = @import("cache.zig");
const shallow = @import("../walk/shallow.zig");
const ignore = @import("../patterns.zig").ignore;
const attributes = @import("../patterns.zig").attributes;
const worktree = @import("../checkout/checkout.zig");
const worktrees = @import("../checkout/worktrees.zig");
const filter = @import("../checkout/filter.zig");
const reftable_stack = @import("../refs/reftable/stack.zig");
const signing = @import("../object/signing.zig");
const message = @import("../object/message.zig");
const encoding = @import("../text.zig").encoding;
const date_mod = @import("../text.zig").date;
const diagnostic_mod = @import("../report.zig").diagnostic;
const repository_format = @import("../discover.zig").format;
const gitfile = @import("../discover.zig").gitfile;
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
} || object.ParseError || discover_directory.Error || Allocator.Error || Io.Dir.OpenError || aegis.own.ReadFileError ||
    Io.Dir.CreateDirError || Io.Dir.CreateDirPathError || Io.Dir.WriteFileError ||
    Io.File.OpenError || Io.Writer.Error || Io.File.SyncError ||
    config_mod.ParseError || config_mod.ValueError || config_mod.PathSettingError || odb_mod.Error ||
    refs_mod.ReadError || refs_mod.TransactionError || worktrees.Error;

/// Errors from writing a commit or a tag, which may be signed.
pub const WriteError = Error || signing.Error || object.Commit.WriteError || error{
    /// `i18n.commitEncoding` set with no value, which git dies on.
    InvalidEncodingSetting,
    /// A commit message holding a NUL byte, which git refuses.
    NulInMessage,
};

/// How deep `open` walks upwards looking for a `.git`.
pub const max_discovery_depth: u8 = 64;

/// Caller-owned output for repository and history operations.
pub const Diagnostic = diagnostic_mod.Diagnostic;

/// Errors from `templateDir`.
pub const TemplateDirError = Allocator.Error || error{ UnexpandablePath, UnstatablePath };

/// `init.templateDir` in `config`, as git's `template_dir_cb` reads it for
/// `git init`: every value in order, a bare name unsetting it, the rest a
/// path setting (`config.pathSetting`) found from `base`, the directory
/// being made into a repository, where git init runs; an `:(optional)`
/// directory that is not there is the value as written, `:(optional)`
/// and all, as git keeps it. `null` when it is not set. The path is
/// `gpa`'s.
pub fn templateDir(gpa: Allocator, io: Io, base: Io.Dir, config: *const config_mod.Config) TemplateDirError!?[]u8 {
    var found: ?[]u8 = null;
    errdefer if (found) |path| gpa.free(path);
    var it = config.iterate(&.{"init.templatedir"});
    while (it.next()) |entry| {
        const path: ?[]u8 = if (entry.value) |value| (config_mod.pathSetting(gpa, io, base, config.context.home, value) catch |err| return switch (err) {
            error.MissingPath => unreachable,
            else => |e| e,
        }) orelse try gpa.dupe(u8, value) else null;
        if (found) |old| gpa.free(old);
        found = path;
    }
    return found;
}

/// An open repository.
/// What `.lfsconfig` was last found from: see `Repository.lfsconfigText`.
const LfsconfigCache = struct {
    key: LfsconfigKey,
    text: ?[]u8,
    /// When the key was taken, by the wall clock files are stamped from.
    seen_at: Io.Timestamp,

    /// Whether the key can prove nothing changed since: each file in it
    /// was stamped well before it was looked at. A file stamped close to
    /// that moment can be rewritten at the same size inside one tick of
    /// the filesystem's clock and keep every time it had, git's racy-clean
    /// case, so it is read again instead.
    fn settled(cache: LfsconfigCache) bool {
        const cutoff = cache.seen_at.subDuration(racy_window);
        if (cache.key.worktree) |w| if (!w.before(cutoff)) return false;
        if (cache.key.index) |ix| if (!ix.file.before(cutoff)) return false;
        return true;
    }
};

/// How far behind the moment it was looked at a file's times must lie for
/// a rewrite to be sure to move them: filesystems stamp from a coarse clock
/// (a scheduler tick on Linux, about 16ms on Windows, two seconds on FAT).
const racy_window = Io.Duration.fromSeconds(2);

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
    mtime: Io.Timestamp,
    ctime: Io.Timestamp,
    inode: Io.File.INode,

    fn of(st: Io.File.Stat) FileStamp {
        return .{ .size = st.size, .mtime = st.mtime, .ctime = st.ctime, .inode = st.inode };
    }
    fn before(stamp: FileStamp, cutoff: Io.Timestamp) bool {
        return stamp.mtime.nanoseconds < cutoff.nanoseconds and stamp.ctime.nanoseconds < cutoff.nanoseconds;
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

/// The directories `Repository.open` found, before the repository is read,
/// each with its one owner.
const Discovered = struct {
    git_dir: fs.OwnedDir,
    /// The shared directory where it is a handle of its own, a linked
    /// worktree's; `null` where it is `git_dir`.
    common_dir: ?fs.OwnedDir,
    work_dir: ?fs.OwnedDir,

    fn close(d: *Discovered, io: Io) void {
        if (d.common_dir) |*common| common.deinit(io);
        d.git_dir.deinit(io);
        if (d.work_dir) |*work| work.deinit(io);
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
    git_dir: fs.OwnedDir,
    /// The shared directory where it is a handle of its own: the main
    /// `.git` of a linked worktree. `null` in a repository with no linked
    /// worktrees, where it is `git_dir`.
    common_dir: ?fs.OwnedDir,
    /// The working tree, or `null` in a bare repository.
    work_dir: ?fs.OwnedDir,
    /// Owned ref state. Its format and cache are opaque to callers.
    refs_state: *RefState,
    /// Opaque ownership of the published configuration: what the files
    /// held at `open`, or when `refreshConfig` last found one changed, or
    /// when `writeConfig` last wrote one, with `editConfig`'s values over
    /// them. Nothing reads the files again behind the caller's back, so
    /// another process's `git config` is seen after a `refreshConfig` and
    /// not before; a write reads its own file again under its lock, so
    /// what another process wrote there stays. An `includeIf` is decided
    /// against this repository's `.git` directory and the branch `HEAD`
    /// was on when the files were read.
    config_state: *config_owner.State,
    odb: odb_mod.Odb,
    /// What `core.sharedRepository` asked of permissions when the
    /// repository was opened: the objects, refs, logs, index and
    /// configuration it writes are given them.
    shared: fs.Shared = .umask,
    /// `core.fsync`, `core.fsyncMethod` and `core.fsyncObjectFiles`, as the
    /// published configuration says: which of the objects, packs, refs and
    /// index are synced, and how.
    fsync: fs.Fsync = .default,
    /// What `lfsconfigText` last found, and what it was found from.
    lfsconfig_cache: aegis.BlockingGuarded(?LfsconfigCache) = .init(null),
    /// The engines' `core` settings, from the published configuration.
    settings: Settings = undefined,
    /// The shallow file as it was read or last written: a write over
    /// another writer's change is refused.
    shallow_seen: shallow.Seen = null,
    /// Commits read through `commitInfo` and `commitTree`, kept.
    commits: commit_cache.Cache = .{},
    /// Where an untracked cache made here says it was made: git's
    /// "Location <working tree>, system <kernel>". `null` without a
    /// working tree.
    untracked_ident: ?[]u8 = null,
    /// `extensions.submodulePathConfig`, from the repository's format.
    submodule_path_config: bool = false,
    /// git for Windows' `core.unsetenvvars`, each name owned: what
    /// `Repository.programsWith` takes out of every program's environment.
    unset_env_vars: [][]u8 = &.{},
    /// `OpenOptions.replace_objects`: whether replace refs may be followed
    /// at all, whatever `core.useReplaceRefs` says.
    replace_objects: bool = true,
    /// `OpenOptions.replace_ref_base`, owned.
    replace_ref_base: []u8 = &.{},

    fn closeDirectories(d: *RepositoryData, io: Io) void {
        if (d.common_dir) |*common| common.deinit(io);
        d.git_dir.deinit(io);
        if (d.work_dir) |*work| work.deinit(io);
    }
};

/// The `core` settings engines take, read once from a published
/// configuration with git's defaults: what the working tree is like and how
/// far to believe it.
/// `core.createObject`: `rename` or `link`, git's default; anything else, a
/// bare name among them, git's "invalid mode for object creation".
fn createObjectOf(config: *const config_mod.Config) ErrorNamespace.Error!odb_policy.CreateObject {
    const entry = config.find("core.createobject") orelse return .link;
    const value = entry.value orelse return error.MalformedValue;
    if (std.mem.eql(u8, value, "rename")) return .rename;
    if (std.mem.eql(u8, value, "link")) return .link;
    return error.MalformedValue;
}

/// git for Windows' `core.unsetenvvars`: its names, split at each comma as
/// git's `do_unset_environment_variables` splits them, `PERL5LIB` unset;
/// none outside Windows. Owned.
fn unsetEnvVarsOf(gpa: Allocator, config: *const config_mod.Config) Allocator.Error![][]u8 {
    if (builtin.target.os.tag != .windows) return &.{};
    const value = config.get("core.unsetenvvars") orelse "PERL5LIB";
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |name| {
        if (name.len == 0) continue;
        try names.ensureUnusedCapacity(gpa, 1);
        names.appendAssumeCapacity(try gpa.dupe(u8, name));
    }
    return names.toOwnedSlice(gpa);
}

fn freeNames(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    if (names.len != 0) gpa.free(names);
}

/// git for Windows' `core.hideDotFiles` (`mingw_core_config`): `dotGitOnly`
/// in any case, else a boolean; `dotGitOnly` unset. Outside Windows git
/// reads none of it and nothing is hidden.
fn hideDotFilesOf(config: *const config_mod.Config) ErrorNamespace.Error!fs.HideDotFiles {
    if (builtin.target.os.tag != .windows) return .none;
    const entry = config.find("core.hidedotfiles") orelse return .dot_git_only;
    const value = entry.value orelse return .all;
    if (std.ascii.eqlIgnoreCase(value, "dotgitonly")) return .dot_git_only;
    return if (try config_mod.parseBool(value)) .all else .none;
}

pub const Settings = struct {
    /// `core.ignoreCase`: the working tree folds case.
    ignore_case: bool,
    /// `core.precomposeUnicode`, acted on on macOS only, as git acts on it:
    /// a name read from a directory in its decomposed spelling is taken
    /// composed.
    precompose_unicode: bool,
    /// `core.fileMode`: the executable bit is real (git's default where
    /// the platform has one).
    file_mode: bool,
    /// `core.symlinks`: links are made as links (not on Windows by default).
    symlinks: bool,
    /// `core.checkStat`: how much of a stat to compare.
    check_stat: fs.Stat.Check,
    /// `core.trustCtime`: whether a changed status-change time says the
    /// file may have changed (git's default: true).
    trust_ctime: bool,
    /// `core.ignoreStat`: what an add or a write takes the stat of is
    /// assumed unchanged from then on.
    ignore_stat: bool,
    /// `core.lockfilePid`: each lock names its holder in a `~pid.lock`
    /// beside it while it is held.
    lockfile_pid: bool,
    /// `core.configLockTimeout`: how long a configuration file's lock is
    /// waited for (git's default: a second).
    config_lock: fs.OnContention,
    /// `core.preferSymlinkRefs`: a symbolic ref written as a symbolic link.
    prefer_symlink_refs: bool,
    /// `core.createObject`: how a new loose object takes its name.
    create_object: odb_policy.CreateObject,
    /// git for Windows' `core.hideDotFiles`: what is made hidden. Read on
    /// Windows alone, as git reads it; elsewhere nothing is hidden.
    hide_dot_files: fs.HideDotFiles,
    /// `core.maxTreeDepth`: how deep a tree may nest (git's default 2048).
    max_tree_depth: u32,
    /// `core.protectNTFS` (on everywhere) and `core.protectHFS` (on macOS):
    /// the spellings of `.git` another file system opens as it.
    protect: names_path.Protect,
    /// `core.untrackedCache` as git's `prepare_repo_settings` reads it: a
    /// boolean writes or removes the cache an index carries, anything else
    /// keeps what it carries; unset, `feature.manyFiles` writes it.
    untracked_cache: UntrackedCacheSetting,
    /// The walk a new untracked cache serves, as git's
    /// `new_untracked_cache_flags` reads `status.showUntrackedFiles`.
    untracked_flags: u32,
    /// `core.splitIndex`: `true` splits the index on its next write,
    /// `false` writes it whole, `null` keeps what it is.
    split_index: ?bool,
    /// `core.useReplaceRefs`: objects are read through the replace refs
    /// (git's default: true).
    use_replace_refs: bool,

    pub const UntrackedCacheSetting = enum { keep, write, remove };

    /// The settings `config` gives, git's defaults where it gives none.
    pub fn of(config: *const config_mod.Config) ErrorNamespace.Error!Settings {
        const check: fs.Stat.Check = if (config.get("core.checkstat")) |text|
            (if (std.ascii.eqlIgnoreCase(text, "default")) .full else if (std.ascii.eqlIgnoreCase(text, "minimal")) .minimal else return error.MalformedValue)
        else
            .full;
        const depth = try config.getInt("core.maxtreedepth", object.max_tree_depth);
        if (depth < 0 or depth > std.math.maxInt(u32)) return error.MalformedValue;
        return .{
            .ignore_case = try config.getBool("core.ignorecase", false),
            .use_replace_refs = try config.getBool("core.usereplacerefs", true),
            // git reads the setting everywhere, and refuses a bad value
            // everywhere, but composes on macOS alone
            .precompose_unicode = try config.getBool("core.precomposeunicode", false) and builtin.target.os.tag == .macos,
            .file_mode = try config.getBool("core.filemode", Io.File.Permissions.has_executable_bit),
            .symlinks = try config.getBool("core.symlinks", builtin.target.os.tag != .windows),
            .check_stat = check,
            .trust_ctime = try config.getBool("core.trustctime", true),
            .ignore_stat = try config.getBool("core.ignorestat", false),
            .lockfile_pid = try config.getBool("core.lockfilepid", false),
            .config_lock = try Repository.lockTimeout(config, "core.configlocktimeout", 1000),
            .hide_dot_files = try hideDotFilesOf(config),
            .prefer_symlink_refs = try config.getBool("core.prefersymlinkrefs", false),
            .create_object = try createObjectOf(config),
            .max_tree_depth = @intCast(depth),
            .protect = .{
                .ntfs = try config.getBool("core.protectntfs", true),
                .hfs = try config.getBool("core.protecthfs", builtin.target.os.tag == .macos),
            },
            .untracked_cache = untracked: {
                const fallback: UntrackedCacheSetting = if (try config.getBool("feature.manyfiles", false)) .write else .keep;
                const entry = config.find("core.untrackedcache") orelse break :untracked fallback;
                const value = entry.value orelse break :untracked fallback;
                const on = config_mod.parseBool(value) catch break :untracked fallback;
                break :untracked if (on) .write else .remove;
            },
            .split_index = if (config.find("core.splitindex")) |entry|
                (if (entry.value) |value| (config_mod.parseBool(value) catch null) else true)
            else
                null,
            .untracked_flags = if (config.get("status.showuntrackedfiles")) |mode|
                (if (std.mem.eql(u8, mode, "all")) 0 else untracked_mod.show_other_directories | untracked_mod.hide_empty_directories)
            else
                untracked_mod.show_other_directories | untracked_mod.hide_empty_directories,
        };
    }
};

/// git's `get_ident_string`: "Location <the working tree's real path>,
/// system <the kernel's name>", which an untracked cache carries and is
/// trusted by.
fn untrackedIdent(gpa: Allocator, io: Io, work: Io.Dir) (Allocator.Error || Io.Dir.RealPathFileAllocError)![]u8 {
    const real = try fs.realPathAlloc(gpa, io, work, ".");
    defer gpa.free(real);
    if (builtin.target.os.tag == .windows) return gpa.print("Location {s}, system Windows", .{real});
    const uts = std.posix.uname();
    return gpa.print("Location {s}, system {s}", .{ real, std.mem.sliceTo(&uts.sysname, 0) });
}

pub const Repository = struct {
    /// How `refreshConfig` reports.
    pub const RefreshConfigOptions = struct {
        /// Names a refusal; cleared on every call.
        diagnostic: ?*Diagnostic = null,
    };

    /// How `writeConfig` reports.
    pub const WriteConfigOptions = struct {
        /// Names a refusal; cleared on every call.
        diagnostic: ?*Diagnostic = null,
    };

    /// How `editConfig` reports.
    pub const EditConfigOptions = struct {
        /// Names a refusal; cleared on every call.
        diagnostic: ?*Diagnostic = null,
    };

    /// How `writeCommit` reports.
    pub const WriteCommitOptions = struct {
        /// Keeps the refused setting or signing stderr; cleared on every call.
        diagnostic: ?*Diagnostic = null,
    };

    /// How a repository is created.
    pub const CreateOptions = struct {
        /// The hash every object name is written with. `null` takes
        /// `init.defaultObjectFormat` from the configuration levels below,
        /// else SHA-1, as git's `repository_format_configure` does.
        object_format: ?hash.Kind = null,
        /// The branch `HEAD` points at before the first commit. `null` takes
        /// `init.defaultBranch` from the levels below and the template's own
        /// configuration, as git's `repo_default_branch_name` reads it after
        /// the template is copied, else git 2.55's `master`.
        default_branch: ?[]const u8 = null,
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
        /// git 3.0 makes the default. `null` takes `init.defaultRefFormat`
        /// from the levels below, else a reftable under `feature.experimental`,
        /// else files.
        ref_format: ?refs_mod.Format = null,
        /// The configuration levels git's `init` reads its defaults from, as
        /// `OpenOptions` names them: the repository being made has none yet.
        system_config: ?config_mod.Sources.Path = null,
        xdg_config: ?config_mod.Sources.Path = null,
        global_config: ?config_mod.Sources.Path = null,
        config_overrides: []const []const u8 = &.{},
        config_pairs: []const config_mod.Sources.Pair = &.{},
        /// The user's home directory, for an include path beginning `~/`.
        home: ?[]const u8 = null,
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

    pub const Error = ErrorNamespace.Error;

    /// Private: handles, caches and live configuration, together.
    state: *anyopaque,

    fn data(repo: *const Repository) *RepositoryData {
        return @ptrCast(@alignCast(repo.state)); // aegis: no-danger: a Repository's state is the RepositoryData its open allocated
    }

    pub fn allocator(repo: *const Repository) Allocator {
        return repo.data().gpa;
    }

    /// The per-worktree directory, lent until this repository is
    /// deinitialized.
    pub fn gitDirectory(repo: *const Repository) fs.LentDir {
        return repo.data().git_dir.lend();
    }

    /// The shared directory, lent until this repository is deinitialized:
    /// the git directory itself but in a linked worktree.
    pub fn commonDirectory(repo: *const Repository) fs.LentDir {
        const d = repo.data();
        return if (d.common_dir) |*common| common.lend() else d.git_dir.lend();
    }

    /// Whether this is a linked worktree with a distinct common directory.
    pub fn isLinkedWorktree(repo: *const Repository) bool {
        return repo.data().common_dir != null;
    }

    /// The working tree, lent until this repository is deinitialized, or
    /// `null` in a bare repository.
    pub fn workDirectory(repo: *const Repository) ?fs.LentDir {
        return if (repo.data().work_dir) |*work| work.lend() else null;
    }

    /// Where git runs for this repository, and so where a relative path in
    /// a setting is found from: the top of the working tree, else the git
    /// directory. Lent, as `gitDirectory` is.
    pub fn topDirectory(repo: *const Repository) fs.LentDir {
        return repo.workDirectory() orelse repo.gitDirectory();
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
        return finish(gpa, io, &discovered, options);
    }

    /// A second handle on this repository, opened as this one was: its
    /// working tree, or its git directory when it has none, with the same
    /// configuration files and values, home and object database settings,
    /// for work that runs beside this handle -- a fetch from several
    /// remotes at once. Nothing is discovered or checked again. It borrows
    /// what this handle keeps open, and must be deinited before it.
    pub fn openAgain(repo: *const Repository, io: Io) Self.Error!Repository {
        const config = repo.configuration();
        return open(repo.data().gpa, io, repo.topDirectory().get(), .{
            .discover = false,
            .ownership = .trust,
            .odb = repo.objectDatabase().settings(),
            .system_config = config.sources.system,
            .xdg_config = config.sources.xdg,
            .global_config = config.sources.global,
            .home = config.context.home,
            .config_overrides = config.sources.command,
            .config_pairs = config.sources.pairs,
            .replace_objects = repo.data().replace_objects,
            .replace_ref_base = repo.data().replace_ref_base,
        });
    }

    /// The per-worktree directory at `dir`, as `open` with `discover`
    /// off finds it, without reading the repository: its `.git` folder,
    /// where a `.git` file points (a linked worktree, a submodule), or
    /// `dir` itself when it is a git directory. For a file of the caller's
    /// own kept beside the repository rather than in the working tree. The
    /// handle is the caller's.
    pub fn gitDirOf(gpa: Allocator, io: Io, dir: Io.Dir) Self.Error!fs.OwnedDir {
        var discovered = try discover(gpa, io, dir, .{ .discover = false });
        if (discovered.common_dir) |*common| common.deinit(io);
        if (discovered.work_dir) |*work| work.deinit(io);
        return discovered.git_dir.move();
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
        /// name and value apart: what `user_config.Locations.pairs` holds.
        config_pairs: []const config_mod.Sources.Pair = &.{},
        /// What is checked of who owns the repository found: git's own
        /// check unless asked otherwise. `safe.directory` is read from the
        /// system, global and command-line settings for a repository that is
        /// not the current user's.
        ownership: safe.Ownership = .check,
        /// `false` is git's `GIT_NO_REPLACE_OBJECTS` (`--no-replace-objects`):
        /// every object is read as stored, whatever `core.useReplaceRefs`
        /// says. This package reads no environment, so the caller says.
        replace_objects: bool = true,
        /// git's `GIT_REPLACE_REF_BASE`: where the replace refs are, each
        /// named by the object it replaces.
        replace_ref_base: []const u8 = "refs/replace/",
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
            path = try fs.realPath(io, start, &path_buf);
            ceiling = nearestCeiling(path, options.ceiling_directories);
        }
        const device = if (fs.statAt(io, start, ".") catch null) |found| found.stat.dev else 0;
        var depth: u8 = 0;
        while (true) : (depth += 1) {
            if (depth > max_discovery_depth) break;

            // A `.git` here: a directory that is a git directory, or a file
            // naming one, which is what a linked worktree and a submodule
            // have. git's `read_gitfile_gently` and `is_git_directory`.
            var dot = try dotGit(gpa, io, current);
            if (dot) |*git_dir| {
                errdefer git_dir.deinit(io);
                var work = fs.OwnedDir.init(try current.openDir(io, ".", .{ .iterate = true }));
                errdefer work.deinit(io);
                const is_file = if (current.statFile(io, ".git", .{})) |st| st.kind == .file else |_| false;
                try checkOwnership(gpa, io, options, if (is_file) work.lend().get() else null, work.lend().get(), git_dir.lend().get());
                return withCommon(io, git_dir, &work);
            }

            // The directory may itself be a git directory — a bare
            // repository, or `.git` handed in directly.
            if (discover_directory.isGitDirectory(io, current)) {
                var git_dir = fs.OwnedDir.init(try current.openDir(io, ".", .{ .iterate = true }));
                errdefer git_dir.deinit(io);
                try checkBare(gpa, io, options, git_dir.lend().get());
                try checkOwnership(gpa, io, options, null, null, git_dir.lend().get());
                return withCommon(io, &git_dir, null);
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
    fn dotGit(gpa: Allocator, io: Io, dir: Io.Dir) ErrorNamespace.Error!?fs.OwnedDir {
        const st = dir.statFile(io, ".git", .{}) catch return null;
        if (st.kind != .file) {
            if (st.kind != .directory) return null;
            var git_dir = fs.OwnedDir.init(dir.openDir(io, ".git", .{ .iterate = true }) catch return null);
            if (discover_directory.isGitDirectory(io, git_dir.lend().get())) return git_dir.move();
            git_dir.deinit(io);
            return null;
        }
        const target = (gitfile.read(gpa, io, dir, ".git") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BrokenGitFile,
        }) orelse return error.BrokenGitFile;
        defer gpa.free(target);
        var git_dir = gitfile.open(io, dir, target, .{ .iterate = true }) catch return error.BrokenGitFile;
        if (discover_directory.isGitDirectory(io, git_dir.lend().get())) return git_dir.move();
        git_dir.deinit(io);
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
        const path = fs.realPathAlloc(gpa, io, work orelse git_dir, ".") catch return error.DubiousOwnership;
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
        const path = fs.realPathAlloc(gpa, io, git_dir, ".") catch return error.ImplicitBareRepository;
        defer gpa.free(path);
        if (!safe.isImplicitBare(path)) {
            try refuseSetting(options.diagnostic, "safe.bareRepository");
            return error.ImplicitBareRepository;
        }
    }

    /// The repository's directories, taking `git_dir` and `work_dir` from
    /// their owners when it returns them.
    fn withCommon(io: Io, git_dir: *fs.OwnedDir, work_dir: ?*fs.OwnedDir) ErrorNamespace.Error!Discovered {
        // `commondir` makes this a linked worktree: everything shared lives
        // where it points.
        const common = try discover_directory.openCommon(io, git_dir.lend().get());
        return .{
            .git_dir = git_dir.move(),
            .common_dir = common,
            .work_dir = if (work_dir) |work| work.move() else null,
        };
    }

    /// Whether two handles are one directory.
    fn sameDir(io: Io, a: Io.Dir, b: Io.Dir) bool {
        return fs.sameFile(io, a, ".", b, ".");
    }

    /// The repository `discovered` names, read. Its handles are taken
    /// whatever comes of it: held by the repository, or closed with the
    /// error.
    fn finish(gpa: Allocator, io: Io, discovered: *Discovered, options: OpenOptions) ErrorNamespace.Error!Repository {
        const owned = gpa.create(RepositoryData) catch |err| {
            discovered.close(io);
            return err;
        };
        owned.* = .{
            .gpa = gpa,
            .git_dir = discovered.git_dir.move(),
            .common_dir = if (discovered.common_dir) |*common| common.move() else null,
            .work_dir = if (discovered.work_dir) |*work| work.move() else null,
            .config_state = undefined,
            .odb = undefined,
            .refs_state = undefined,
        };
        errdefer {
            owned.closeDirectories(io);
            gpa.destroy(owned);
        }

        var repo: Repository = .{ .state = owned };

        // The configuration is read before anything else, because it says
        // which hash the object names are written with.
        // An `includeIf` asks where the `.git` directory and the work tree
        // are and which branch `HEAD` is on, so all three are known before
        // the first file is read.
        var path_buffer: [4096]u8 = undefined;
        const git_dir_path = try fs.realPath(io, repo.gitDirectory().get(), &path_buffer);
        var work_buffer: [4096]u8 = undefined;
        const work_tree_path = if (repo.workDirectory()) |work| try fs.realPath(io, work.get(), &work_buffer) else null;
        // The format is the repository's own file's to say, read alone, as
        // git's `read_repository_format` reads it: no include, no other
        // file and no `-c` decides which hash a repository's objects are
        // named with, or where its refs are kept.
        const format = try repository_format.read(gpa, io, repo.commonDirectory().get(), options.diagnostic);
        const branch = try currentBranch(gpa, io, repo.gitDirectory(), repo.commonDirectory(), format);
        defer if (branch) |b| gpa.free(b);
        const config = try repo.readConfig(io, .{
            .system = options.system_config,
            .xdg = options.xdg_config,
            .global = options.global_config,
            .local = .{ .dir = repo.commonDirectory().get(), .sub_path = "config" },
            .command = options.config_overrides,
            .pairs = options.config_pairs,
        }, .{ .git_dir = git_dir_path, .work_tree = work_tree_path, .branch = branch, .home = options.home }, format, null);
        repo.data().config_state = try config_owner.create(config);
        errdefer config_owner.destroy(repo.data().config_state);
        repo.data().shared = try sharedOf(repo.configuration());
        repo.data().fsync = try fsyncOf(repo.configuration());
        repo.data().settings = try Settings.of(repo.configuration());
        repo.data().replace_objects = options.replace_objects;
        repo.data().replace_ref_base = try gpa.dupe(u8, options.replace_ref_base);
        errdefer gpa.free(repo.data().replace_ref_base);
        repo.data().submodule_path_config = format.submodule_path_config;
        repo.data().unset_env_vars = try unsetEnvVarsOf(gpa, repo.configuration());
        errdefer freeNames(gpa, repo.data().unset_env_vars);
        if (repo.workDirectory()) |work| repo.data().untracked_ident = try untrackedIdent(gpa, io, work.get());
        errdefer if (repo.data().untracked_ident) |ident| gpa.free(ident);
        var odb_options = options.odb;
        odb_options.shared = repo.data().shared;
        odb_options.fsync = repo.data().fsync;
        odb_options.pid_file = repo.data().settings.lockfile_pid;
        odb_options.create_object = repo.data().settings.create_object;
        odb_options.packing = try packingOf(repo.configuration());
        repo.data().odb = try odb_mod.Odb.open(gpa, io, repo.commonDirectory().get(), format.kind, odb_options);
        errdefer repo.data().odb.deinit(io);
        repo.data().shallow_seen = try shallow.seen(io, repo.commonDirectory().get());
        repo.data().odb.shallow = try shallow.read(gpa, io, repo.commonDirectory().get(), format.kind);
        const store = try gpa.create(refs_mod.Store);
        errdefer gpa.destroy(store);
        var stack_options: reftable_stack.Options = if (format.ref_storage == .reftable) try reftableOptions(repo.configuration()) else .{};
        stack_options.shared = repo.data().shared;
        store.* = try refs_mod.Store.init(gpa, format.kind, repo.gitDirectory(), repo.commonDirectory(), .{
            .format = format.ref_storage,
            .reftable = stack_options,
            .shared = repo.data().shared,
            .fsync = repo.data().fsync,
            .locks = try refLocks(repo.configuration()),
            .precompose_unicode = repo.data().settings.precompose_unicode,
            .prefer_symlink_refs = repo.data().settings.prefer_symlink_refs,
        });
        repo.data().refs_state = @ptrCast(store); // aegis: no-danger: the opaque owner retains this allocated Store.
        repo.data().odb.replacements = .{
            .lister = .{ .context = repo.data(), .list = listReplacements },
            .enabled = options.replace_objects and repo.data().settings.use_replace_refs,
        };
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
            .{ .dir = repo.gitDirectory().get(), .sub_path = "config.worktree", .contents = worktree_contents }
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
    /// (`ObjectFormatChanged`, `RefStorageChanged`). `options.diagnostic`,
    /// when given, names the refusal and is cleared on every call.
    pub fn refreshConfig(repo: *Repository, io: Io, options: RefreshConfigOptions) Self.Error!bool {
        const diagnostic = options.diagnostic;
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
        const format = try repository_format.read(repo.data().gpa, io, repo.commonDirectory().get(), diagnostic);
        var fresh = try repo.readConfig(io, repo.configuration().sources, context, format, null);
        errdefer fresh.deinit();
        try repo.publishConfig(fresh, format, diagnostic);
        return true;
    }

    /// The branch `HEAD` is on, without `refs/heads/` and the caller's, or
    /// `null` when it is detached: read through a ref store over the
    /// directories in `format`, before the repository has its own. An
    /// unborn branch counts, as it does for git's `onbranch:`.
    fn currentBranch(gpa: Allocator, io: Io, git_dir: fs.LentDir, common_dir: fs.LentDir, format: RepositoryFormat) ErrorNamespace.Error!?[]u8 {
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
    /// `core.fsync`, `core.fsyncMethod` and `core.fsyncObjectFiles`, read as
    /// git reads them: `core.fsync` over git's default, and when it is
    /// unset, git's default with the references and the index besides
    /// (`fs.Fsync.default`). `core.fsyncObjectFiles = true` syncs loose
    /// objects whatever `core.fsync` says (`fs.Fsync.object_files`): one by
    /// one, flushed to the hardware under `fsync` and `batch` and written out
    /// under `writeout-only`, and batched only where `core.fsync` names them,
    /// as git's `close_loose_object` syncs them. A value git ignores is
    /// ignored.
    /// git's pack-objects and object-writer settings: `pack.window` and
    /// `pack.depth` (below 0 is 0; a depth past 4095 is 4095),
    /// `pack.windowMemory` (0 is no bound), `pack.compression` and
    /// `core.looseCompression`, each falling back to `core.compression`
    /// (-1 is zlib's default; anything else outside 0 to 9 refused, as git
    /// dies), `pack.indexVersion` (past 2 refused), `core.multiPackIndex` and
    /// `core.bigFileThreshold` (`odb_policy.bigFileThreshold`).
    fn packingOf(config: *const config_mod.Config) ErrorNamespace.Error!odb_policy.Packing {
        var packing: odb_policy.Packing = .{};
        if (config.has("pack.window")) packing.window = std.math.cast(u32, @max(try config.getInt("pack.window", 10), 0)) orelse std.math.maxInt(u32);
        if (config.has("pack.depth")) packing.depth = @intCast(std.math.clamp(try config.getInt("pack.depth", 50), 0, 4095));
        if (config.has("pack.windowmemory")) {
            const bytes = try config.getInt("pack.windowmemory", 0);
            packing.window_bytes = .fromRaw(if (bytes <= 0) std.math.maxInt(usize) else std.math.cast(usize, bytes) orelse std.math.maxInt(usize));
        }
        const core_level: ?i64 = if (config.has("core.compression")) try config.getInt("core.compression", -1) else null;
        if (config.has("pack.compression") or core_level != null) {
            const level = if (config.has("pack.compression")) try config.getInt("pack.compression", -1) else core_level.?;
            packing.compression = pack_mod.Compression.fromLevel(level) orelse return error.MalformedValue;
        }
        if (config.has("core.loosecompression") or core_level != null) {
            const level = if (config.has("core.loosecompression")) try config.getInt("core.loosecompression", -1) else core_level.?;
            packing.loose_compression = pack_mod.Compression.fromLevel(level) orelse return error.MalformedValue;
        }
        if (config.has("pack.indexversion")) {
            const version = try config.getInt("pack.indexversion", 2);
            if (version < 0 or version > 2) return error.MalformedValue;
            packing.index_version = @intCast(@max(version, 1));
        }
        packing.multi_pack_index = try config.getBool("core.multipackindex", true);
        packing.big_file_bytes = try odb_policy.bigFileThreshold(config);
        return packing;
    }

    fn fsyncOf(config: *const config_mod.Config) ErrorNamespace.Error!fs.Fsync {
        var fsync: fs.Fsync = .default;
        if (config.find("core.fsync")) |entry| {
            const value = entry.value orelse return error.MalformedValue;
            fsync.components = fs.Fsync.parseComponents(value);
        }
        if (config.find("core.fsyncmethod")) |entry| {
            const value = entry.value orelse return error.MalformedValue;
            if (fs.Fsync.parseMethod(value)) |method| fsync.method = method;
        }
        fsync.object_files = try config.getBool("core.fsyncobjectfiles", false);
        return fsync;
    }

    /// How the index lock is taken and synced: `core.sharedRepository`'s
    /// permissions and `core.fsync`'s `index`.
    pub fn indexLock(repo: *const Repository) fs.LockFile.Options {
        return .{ .shared = repo.data().shared, .sync = repo.data().fsync.sync(.index), .write_pid = repo.data().settings.lockfile_pid };
    }

    /// `base` with git for Windows' `core.unsetenvvars` taken out of every
    /// program's environment (`PERL5LIB` unless set), as git's
    /// `mingw_spawnve_fd` takes them. Elsewhere `base` as it is.
    pub fn programsWith(repo: *const Repository, base: program.Programs) program.Programs {
        var with = base;
        with.unset = repo.data().unset_env_vars;
        return with;
    }

    /// How a configuration file of this repository is locked.
    pub fn configLock(repo: *const Repository) config_write.LockOptions {
        return .{ .shared = repo.data().shared, .pid_file = repo.data().settings.lockfile_pid, .on_contention = repo.data().settings.config_lock };
    }

    /// `core.lockfilePid`: whether a lock taken for this repository names
    /// its holder in a `~pid.lock` beside it.
    pub fn lockfilePid(repo: *const Repository) bool {
        return repo.data().settings.lockfile_pid;
    }

    /// How `index` is written, as git's `do_write_index` reads its settings:
    /// `index.version` for an index first written now (`feature.manyFiles`
    /// makes it 4; a value outside 2 to 4 is git's default, 3), the all-zero
    /// trailer of `index.skipHash` (on under `feature.manyFiles`), `EOIE` and
    /// `IEOT` as `index.recordEndOfIndexEntries` and
    /// `index.recordOffsetTable` say, each else on when `index.threads` asks
    /// for other than one thread; the table only with `index.threads`, in
    /// as many blocks as threads, or for `true` one per ten thousand entries
    /// up to one fewer than the processors. The index lock's settings too.
    pub fn indexWriteOptions(repo: *const Repository, index: *const index_mod.Index) Self.Error!index_mod.WriteOptions {
        const config = repo.configuration();
        const many_files = try config.getBool("feature.manyfiles", false);
        const new_version: u32 = if (config.find("index.version")) |entry| blk: {
            const value = try config_mod.parseInteger(entry.value orelse return error.NotAnInteger);
            break :blk if (value >= 2 and value <= 4) @intCast(value) else 3;
        } else if (many_files) 4 else 3;
        // git's `repo_config_get_index_threads`: `true` is 0, as many as
        // the index wants; `false` is 1.
        const threads: ?u32 = if (config.find("index.threads")) |entry| switch (try config_mod.parseBoolOrInt(entry.value)) {
            .boolean => |on| if (on) 0 else 1,
            .integer => |n| std.math.cast(u32, n) orelse return error.NotAnInteger,
        } else null;
        const threaded = if (threads) |n| n != 1 else false;
        const end_of_index_entries = try config.getBool("index.recordendofindexentries", threaded);
        const blocks: u32 = blk: {
            const n = threads orelse break :blk 0;
            if (n == 1 or !try config.getBool("index.recordoffsettable", threaded)) break :blk 0;
            const entries: u32 = @intCast(index.entries.items.len);
            if (n != 0) break :blk @min(n, entries);
            const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 1);
            break :blk @min(entries / 10_000, cpus -| 1);
        };
        return .{
            .new_version = new_version,
            .skip_hash = try config.getBool("index.skiphash", many_files),
            .end_of_index_entries = end_of_index_entries,
            .entry_offset_blocks = blocks,
            .lock = repo.indexLock(),
        };
    }

    /// git's split index on a write: `core.splitIndex` turns it on or off;
    /// a split index with no shared index yet, or one where more entries
    /// than `splitIndex.maxPercentChange` allows (20 percent unless set; 0
    /// always, 100 never) are not in it, has a new shared index written
    /// first, and the old ones `splitIndex.sharedIndexExpire` (two weeks)
    /// has passed are removed. Returns the name of the shared index the
    /// main file goes on standing on, which git freshens after the write.
    fn writeSharedIfDue(repo: *Repository, io: Io, index: *index_mod.Index, options: index_mod.WriteOptions) WriteIndexError!?[hash.max_hex_len + 16]u8 {
        if (repo.data().settings.split_index) |on| if (on) index.useSplit() else index.dropSplit();
        const split = index.split orelse return null;
        const config = repo.configuration();
        const max_percent: i64 = blk: {
            const value = try config.getInt("splitindex.maxpercentchange", -1);
            break :blk if (value >= 0 and value <= 100) value else 20;
        };
        const entries: i64 = @intCast(index.entries.items.len);
        const not_shared: i64 = @intCast(index.notShared());
        const too_many = switch (max_percent) {
            0 => true,
            100 => false,
            else => entries * max_percent < not_shared * 100,
        };
        if (split.base) |base| if (!too_many) {
            var name: [hash.max_hex_len + 16]u8 = @splat(0);
            var hex: [hash.max_hex_len]u8 = undefined;
            // unreachable: a hex name is at most max_hex_len digits, the prefix twelve bytes
            _ = std.mem.print(&name, "sharedindex.{s}", .{base.hex(&hex)}) catch unreachable;
            return name;
        };
        const written_at = try index.writeShared(io, repo.gitDirectory().get(), options);
        const text = config.get("splitindex.sharedindexexpire") orelse "2.weeks.ago";
        const expire = date_mod.parseExpiry(text, .{ .now = written_at }) orelse return error.MalformedValue;
        index.removeSharedBefore(io, repo.gitDirectory().get(), expire);
        return null;
    }

    /// git's `freshen_shared_index`: the shared index a write stood on is
    /// dated now, so that it outlives its expiry while it is in use.
    fn freshenShared(repo: *Repository, io: Io, name: *const [hash.max_hex_len + 16]u8) void {
        const path = std.mem.sliceTo(name, 0);
        fs.setTimestamps(io, repo.gitDirectory().get(), path, .{ .access_timestamp = .now, .modify_timestamp = .now }) catch |err|
            std.log.warn("could not freshen shared index '{s}': {t}", .{ path, err });
    }

    /// Which writes are synced, and how.
    pub fn fsyncPolicy(repo: *const Repository) fs.Fsync {
        return repo.data().fsync;
    }

    fn sharedOf(config: *const config_mod.Config) ErrorNamespace.Error!fs.Shared {
        const entry = config.find("core.sharedrepository") orelse return .umask;
        const value = entry.value orelse return .group;
        return fs.Shared.parse(value) catch error.InvalidSharedMode;
    }

    fn reftableOptions(config: *const config_mod.Config) ErrorNamespace.Error!reftable_stack.Options {
        var options: reftable_stack.Options = .{};
        const block_size = try config.getInt("reftable.blocksize", options.write.block_size);
        if (block_size > 0 and block_size < (1 << 24)) options.write.block_size = @intCast(block_size);
        const restart = try config.getInt("reftable.restartinterval", options.write.restart_interval);
        if (restart > 0 and restart <= std.math.maxInt(u16)) options.write.restart_interval = @intCast(restart);
        options.write.index_objects = try config.getBool("reftable.indexobjects", true);
        const factor = try config.getInt("reftable.geometricfactor", options.geometric_factor);
        if (factor > 0 and factor <= std.math.maxInt(u8)) options.geometric_factor = @intCast(factor);
        options.lock = try lockTimeout(config, "reftable.locktimeout", 100);
        options.pid_file = try config.getBool("core.lockfilepid", false);
        return options;
    }

    /// How the refs' locks wait and name their holders, as `config` says.
    fn refLocks(config: *const config_mod.Config) ErrorNamespace.Error!refs_mod.Locks {
        return .{
            .packed_refs = try lockTimeout(config, "core.packedrefstimeout", 1000),
            .loose = try lockTimeout(config, "core.filesreflocktimeout", 100),
            .pid_file = try config.getBool("core.lockfilepid", false),
        };
    }

    /// A lock timeout in milliseconds, as git reads one: zero means try
    /// once, a negative number means wait for ever, which here is as long
    /// as a wait can be written down.
    fn lockTimeout(config: *const config_mod.Config, key: []const u8, default: i64) ErrorNamespace.Error!fs.OnContention {
        const timeout = try config.getInt(key, default);
        if (timeout == 0) return .fail;
        if (timeout < 0) return .{ .wait = .max };
        return .{ .wait = .fromMilliseconds(timeout) };
    }

    fn refuseSetting(diagnostic: ?*Diagnostic, text: []const u8) Allocator.Error!void {
        try diagnostic_mod.refuse(diagnostic, text);
    }

    /// Create a repository at `dir`.
    ///
    /// Writes `HEAD`, `config`, `objects/`, `refs/heads`, `refs/tags` and
    /// `info/`, which is what a repository needs to be one.
    pub fn create(gpa: Allocator, io: Io, dir: Io.Dir, options: CreateOptions) Self.Error!Repository {
        var discovered: Discovered = .{ .git_dir = try layOut(gpa, io, dir, options), .common_dir = null, .work_dir = null };
        if (!options.bare) discovered.work_dir = fs.OwnedDir.init(dir.openDir(io, ".", .{ .iterate = true }) catch |err| {
            discovered.close(io);
            return err;
        });
        return finish(gpa, io, &discovered, .{ .discover = false, .odb = options.odb });
    }

    /// `create`'s git directory, written, and its handle.
    fn layOut(gpa: Allocator, io: Io, dir: Io.Dir, options: CreateOptions) ErrorNamespace.Error!fs.OwnedDir {
        // git's `repository_format_configure` reads the levels above the
        // repository; `repo_default_branch_name` reads the template's too.
        var user = try config_mod.Config.open(gpa, io, .{
            .system = options.system_config,
            .xdg = options.xdg_config,
            .global = options.global_config,
            .command = options.config_overrides,
            .pairs = options.config_pairs,
        }, .{ .home = options.home });
        defer user.deinit();

        const git_path = if (options.bare) "." else ".git";
        if (!options.bare) {
            dir.createDir(io, ".git", .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => return error.RepositoryExists,
                else => |e| return e,
            };
            // git for Windows' `mingw_mkdir` hides it, as
            // `core.hideDotFiles` says.
            fs.hideIfAsked(io, dir, ".git", try hideDotFilesOf(&user));
        } else if (discover_directory.isGitDirectory(io, dir)) {
            return error.RepositoryExists;
        }
        var owned = fs.OwnedDir.init(try dir.openDir(io, git_path, .{ .iterate = true }));
        errdefer owned.deinit(io);
        const git_dir = owned.lend().get();

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

        const object_format = options.object_format orelse initObjectFormat(&user);
        const ref_format = options.ref_format orelse initRefFormat(&user);
        const choices = try initChoices(gpa, io, git_dir, options);
        const branch = choices.branch;
        defer gpa.free(branch);

        try fs.makeDirs(io, git_dir, "objects/pack", shared);
        try fs.makeDirs(io, git_dir, "objects/info", shared);
        try git_dir.createDirPath(io, "info");

        // The refs as the format lays them down, then `HEAD` on the unborn
        // branch, written as the first ref and logged nowhere, as git's
        // `init` writes it.
        try refs_mod.create(io, git_dir, ref_format, .{ .shared = shared });
        {
            const target = try std.mem.concat(gpa, u8, &.{ "refs/heads/", branch });
            defer gpa.free(target);
            var store = try refs_mod.Store.init(gpa, object_format, owned.lend(), owned.lend(), .{
                .format = ref_format,
                .reftable = .{ .shared = shared },
                .shared = shared,
            });
            defer store.deinit();
            var tx = store.begin(gpa);
            defer tx.deinit(io);
            try tx.update("HEAD", .{ .symbolic = target }, .any);
            try tx.commit(io, null);
        }

        try initConfig(gpa, io, git_dir, options, .{ .object_format = object_format, .ref_format = ref_format, .submodule_path_config = choices.submodule_path_config }, shared, logs_set);

        return owned.move();
    }

    /// `init.defaultObjectFormat`, the last one deciding, an unknown name
    /// SHA-1 (git warns), as git's `read_default_format_config` reads it.
    fn initObjectFormat(config: *const config_mod.Config) hash.Kind {
        const name = config.get("init.defaultobjectformat") orelse return .sha1;
        return hash.Kind.parse(name) catch .sha1;
    }

    /// `init.defaultRefFormat`, and `feature.experimental` for a reftable
    /// while no known format is named yet, in the configuration's order, as
    /// git's `read_default_format_config` reads them; files when none.
    fn initRefFormat(config: *const config_mod.Config) refs_mod.Format {
        var chosen: ?refs_mod.Format = null;
        var it = config.iterate(&.{ "init.defaultrefformat", "feature.experimental" });
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "defaultrefformat")) {
                chosen = refs_mod.Format.parse(entry.value orelse "");
            } else if (chosen == null) {
                const on = if (entry.value) |v| config_mod.parseBool(v) catch false else true;
                if (on) chosen = .reftable;
            }
        }
        return chosen orelse .files;
    }

    /// What git's `init` reads once the template is in place, from the
    /// configuration with the template's own: the initial branch --
    /// `CreateOptions.default_branch`, else `init.defaultBranch`, else
    /// `master`, a name no branch can have refused as git's "invalid branch
    /// name" -- and `init.defaultSubmodulePathConfig`. The branch is the
    /// caller's.
    fn initChoices(gpa: Allocator, io: Io, git_dir: Io.Dir, options: CreateOptions) ErrorNamespace.Error!struct { branch: []u8, submodule_path_config: bool } {
        var config = try config_mod.Config.open(gpa, io, .{
            .system = options.system_config,
            .xdg = options.xdg_config,
            .global = options.global_config,
            .local = .{ .dir = git_dir, .sub_path = "config" },
            .command = options.config_overrides,
            .pairs = options.config_pairs,
        }, .{ .home = options.home });
        defer config.deinit();
        const submodule_path_config = try config.getBool("init.defaultsubmodulepathconfig", false);
        const name = if (options.default_branch) |given| try gpa.dupe(u8, given) else blk: {
            const entry = config.find("init.defaultbranch") orelse break :blk try gpa.dupe(u8, "master");
            break :blk try gpa.dupe(u8, entry.value orelse return error.MalformedValue);
        };
        errdefer gpa.free(name);
        const ref = try std.mem.concat(gpa, u8, &.{ "refs/heads/", name });
        defer gpa.free(ref);
        if (!names_ref.checkFormat(ref, .{})) return error.InvalidBranchName;
        return .{ .branch = name, .submodule_path_config = submodule_path_config };
    }

    /// The configuration of a new repository: the values git's `init` sets
    /// one by one, as `git config` would, in its order, in the template's
    /// file when there is one and a new one when not.
    fn initConfig(gpa: Allocator, io: Io, git_dir: Io.Dir, options: CreateOptions, format: struct { object_format: hash.Kind, ref_format: refs_mod.Format, submodule_path_config: bool }, shared: fs.Shared, logs_set: bool) ErrorNamespace.Error!void {
        var edits: std.ArrayList(ConfigEdit) = .empty;
        defer edits.deinit(gpa);
        // The extensions before the version, as git's
        // `initialize_repository_version` sets them.
        if (format.object_format != .sha1) try edits.append(gpa, .{ .set = .{ .name = "extensions.objectformat", .value = format.object_format.name() } });
        if (format.ref_format != .files) try edits.append(gpa, .{ .set = .{ .name = "extensions.refstorage", .value = format.ref_format.name() } });
        if (format.submodule_path_config) try edits.append(gpa, .{ .set = .{ .name = "extensions.submodulepathconfig", .value = "true" } });
        const version = if (format.object_format == .sha1 and format.ref_format == .files and !format.submodule_path_config) "0" else "1";
        try edits.append(gpa, .{ .set = .{ .name = "core.repositoryformatversion", .value = version } });
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
        _ = config_write.editFile(gpa, io, git_dir, "config", .local, .{ .shared = shared }, edits.items) catch |err| switch (err) {
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
                    const bytes = try aegis.own.readFile(io, from, entry.name, gpa, aegis.units.Bytes(u64).fromRaw(1 << 30));
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
        if (repo.data().lfsconfig_cache.teardown().*) |c| if (c.text) |t| repo.data().gpa.free(t);
        repo.data().commits.deinit(repo.data().gpa);
        repo.refStore().deinit();
        repo.data().gpa.destroy(repo.refStore());
        repo.data().odb.deinit(io);
        config_owner.destroy(repo.data().config_state);
        repo.data().closeDirectories(io);
        const gpa = repo.data().gpa;
        if (repo.data().untracked_ident) |ident| gpa.free(ident);
        freeNames(gpa, repo.data().unset_env_vars);
        gpa.free(repo.data().replace_ref_base);
        gpa.destroy(repo.data());
        repo.* = undefined;
    }

    /// The hash chosen when the repository was opened. A change requires reopening.
    pub fn objectFormat(repo: *const Repository) hash.Kind {
        return repo.refStore().objectFormat();
    }

    /// Where the replace refs are: `OpenOptions.replace_ref_base`.
    pub fn replaceRefBase(repo: *const Repository) []const u8 {
        return repo.data().replace_ref_base;
    }

    /// The object database's `Odb.Replacements.Lister`: git's
    /// `prepare_replace_object`, every ref under the replace ref base
    /// registered as replacing the object its last name component names
    /// (`register_replace_ref`). A ref that names no object is passed over,
    /// where git warns of it; a broken one, or a symbolic one that leads
    /// nowhere, replaces with no object, so a read of what it replaces finds
    /// nothing, as git's does.
    fn listReplacements(io: Io, context: *anyopaque, gpa: Allocator, map: *Oid.Map(Oid)) odb_mod.Odb.Replacements.ListError!void {
        const d: *RepositoryData = @ptrCast(@alignCast(context)); // aegis: no-danger: open installs the RepositoryData as the context
        const repo: Repository = .{ .state = d };
        const store = repo.refStore();
        const kind = repo.objectFormat();
        var listing = store.list(gpa, io, d.replace_ref_base) catch |err| return unreadable(err);
        defer listing.deinit();
        for (listing.entries) |entry| {
            const original = replacedBy(kind, entry.name[d.replace_ref_base.len..]) orelse continue;
            const replacement = switch (entry.target) {
                .direct => |oid| oid,
                .symbolic => blk: {
                    const resolved = (store.resolve(gpa, io, entry.name) catch |err| return unreadable(err)) orelse break :blk Oid.zero(kind);
                    gpa.free(resolved.name);
                    break :blk resolved.oid;
                },
            };
            try registerReplacement(gpa, map, original, replacement);
        }
        for (listing.broken) |broken| if (broken.why == .bad_content) {
            if (!std.mem.startsWith(u8, broken.name, d.replace_ref_base)) continue;
            const original = replacedBy(kind, broken.name[d.replace_ref_base.len..]) orelse continue;
            try registerReplacement(gpa, map, original, Oid.zero(kind));
        };
    }

    fn unreadable(err: refs_mod.ReadError) odb_mod.Odb.Replacements.ListError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.ReplaceRefsUnreadable,
        };
    }

    /// The object a replace ref names, from its name past the base: the hex
    /// at the start of its last component, as git's `get_oid_hex_algop`
    /// reads it.
    fn replacedBy(kind: hash.Kind, name: []const u8) ?Oid {
        const last = name[if (std.mem.findScalarLast(u8, name, '/')) |slash| slash + 1 else 0..];
        if (last.len < kind.hexLen()) return null;
        return Oid.parse(kind, last[0..kind.hexLen()]) catch null;
    }

    fn registerReplacement(gpa: Allocator, map: *Oid.Map(Oid), original: Oid, replacement: Oid) odb_mod.Odb.Replacements.ListError!void {
        const slot = try map.getOrPut(gpa, original);
        if (slot.found_existing) return error.DuplicateReplaceRef;
        slot.value_ptr.* = replacement;
    }

    /// The repository owns this store; callers borrow it for ref operations.
    /// Its backend and cache cannot be assigned separately.
    pub fn refStore(repo: *const Repository) *refs_mod.Store {
        return @ptrCast(@alignCast(repo.data().refs_state)); // aegis: no-danger: finish allocates refs_state as an aligned Store.
    }

    /// The last published configuration, borrowed until an edit, a write,
    /// a refresh or the repository's close. Change it through the
    /// repository (`writeConfig`, `editConfig`) to keep its stores and
    /// configuration policy in agreement.
    pub fn configuration(repo: *const Repository) *const config_mod.Config {
        return config_owner.get(repo.data().config_state);
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
    /// memory-only edits replayed over it. `options.diagnostic`, when given,
    /// names a refusal and is cleared on every call.
    pub fn writeConfig(repo: *Repository, io: Io, file: ConfigFile, edits: []const ConfigEdit, options: WriteConfigOptions) WriteConfigError!WriteOutcome {
        const diagnostic = options.diagnostic;
        diagnostic_mod.reset(diagnostic);
        const current = repo.configuration();
        const worktree_file = file == .worktree and current.sources.worktree != null;
        var pending = if (worktree_file)
            try config_write.prepare(repo.data().gpa, io, repo.gitDirectory().get(), "config.worktree", .worktree, repo.configLock(), edits)
        else
            try config_write.prepare(repo.data().gpa, io, repo.commonDirectory().get(), "config", .local, repo.configLock(), edits);
        defer pending.deinit(io);

        var sources = current.sources;
        if (!worktree_file) sources.local.?.contents = pending.contents();
        // The format is the shared file's to say: the bytes about to land
        // there, or the file as it is.
        const format = if (worktree_file)
            try repository_format.read(repo.data().gpa, io, repo.commonDirectory().get(), diagnostic)
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
        errdefer freeNames(repo.data().gpa, policy.unset_env_vars);
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
        return config_write.editFile(repo.data().gpa, io, dir, sub_path, .local, repo.configLock(), edits);
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
    pub fn editConfig(repo: *Repository, io: Io, values: []const config_mod.Sources.Pair, options: EditConfigOptions) EditConfigError!void {
        const diagnostic = options.diagnostic;
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
        ref_options: reftable_stack.Options,
        shared: fs.Shared,
        fsync: fs.Fsync,
        settings: Settings,
        packing: odb_policy.Packing,
        submodule_path_config: bool,
        locks: refs_mod.Locks,
        /// Owned until installed.
        unset_env_vars: [][]u8,
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
        return .{
            .ref_options = if (format.ref_storage == .reftable)
                try reftableOptions(next)
            else
                repo.refStore().reftableOptions(),
            .shared = try sharedOf(next),
            .fsync = try fsyncOf(next),
            .settings = try Settings.of(next),
            .packing = try packingOf(next),
            .submodule_path_config = format.submodule_path_config,
            .locks = try refLocks(next),
            .unset_env_vars = try unsetEnvVarsOf(repo.data().gpa, next),
        };
    }

    /// Replace the published configuration with `next`, which it takes,
    /// and the policy `checkConfig` gave for it.
    fn installConfig(repo: *Repository, next: config_mod.Config, policy: ConfigPolicy) void {
        config_owner.get(repo.data().config_state).deinit();
        config_owner.get(repo.data().config_state).* = next;
        repo.refStore().configureReftable(policy.ref_options);
        // Every writer takes the new policy at once: a changed
        // `core.sharedRepository` used to reach none of them.
        repo.refStore().configureWrites(policy.shared, policy.fsync);
        repo.refStore().configureNames(policy.settings.precompose_unicode);
        repo.refStore().configureLocks(policy.locks);
        repo.refStore().configureSymlinkRefs(policy.settings.prefer_symlink_refs);
        repo.data().odb.configureWrites(policy.shared, policy.fsync);
        repo.data().odb.configureLockPid(policy.settings.lockfile_pid);
        repo.data().odb.configureCreateObject(policy.settings.create_object);
        repo.data().odb.configurePacking(policy.packing);
        repo.data().shared = policy.shared;
        repo.data().fsync = policy.fsync;
        repo.data().settings = policy.settings;
        repo.data().odb.replacements.enabled = repo.data().replace_objects and policy.settings.use_replace_refs;
        // The replace refs may have changed with the files.
        repo.data().odb.forgetReplacements();
        repo.data().submodule_path_config = policy.submodule_path_config;
        freeNames(repo.data().gpa, repo.data().unset_env_vars);
        repo.data().unset_env_vars = policy.unset_env_vars;
    }

    /// The `core` settings the engines take, as the published configuration
    /// says: parsed once each time one is published, so a malformed value
    /// refuses the configuration as git refuses it.
    pub fn settings(repo: *const Repository) Settings {
        return repo.data().settings;
    }

    fn publishConfig(repo: *Repository, next: config_mod.Config, format: RepositoryFormat, diagnostic: ?*Diagnostic) ErrorNamespace.Error!void {
        repo.installConfig(next, try repo.checkConfig(&next, format, diagnostic));
    }

    /// Whether a submodule's repository is where `submodule.<name>.gitdir`
    /// says, rather than at `modules/<name>`: `extensions.submodulePathConfig`.
    pub fn submodulePathConfig(repo: *const Repository) bool {
        return repo.data().submodule_path_config;
    }

    /// Whether the repository has a working tree.
    pub fn isBare(repo: *const Repository) bool {
        return repo.workDirectory() == null;
    }

    /// The `core` settings that take part in line-ending conversion.
    /// Invalid settings and allocation failures are returned to the caller.
    pub fn coreSettings(repo: *const Repository) Self.Error!attributes.CoreSettings {
        return .{
            .autocrlf = try repo.coreChoice(attributes.CoreSettings.AutoCrlf, true, "core.autocrlf", .false),
            .eol = try repo.coreChoice(attributes.CoreSettings.Eol, false, "core.eol", .native),
            .safecrlf = try repo.coreChoice(attributes.CoreSettings.SafeCrlf, true, "core.safecrlf", .false),
            .check_roundtrip_encoding = if (repo.configuration().find("core.checkroundtripencoding")) |entry|
                entry.value orelse return error.MalformedValue
            else
                "SHIFT-JIS",
        };
    }

    fn coreChoice(repo: *const Repository, comptime T: type, comptime boolean: bool, setting: []const u8, fallback: T) ErrorNamespace.Error!T {
        const text = repo.configuration().get(setting) orelse return fallback;
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
            .ignore_case = repo.data().settings.ignore_case,
            .precompose_unicode = repo.data().settings.precompose_unicode,
            .check_stat = repo.data().settings.check_stat,
            .trust_ctime = repo.data().settings.trust_ctime,
            .ignore_stat = repo.data().settings.ignore_stat,
            .hide_dot_files = repo.data().settings.hide_dot_files,
            .timestamp_resolution = repo.data().odb.timestamp_resolution,
            .big_file_bytes = repo.data().odb.packOptions().big_file_bytes,
            .file_mode = repo.data().settings.file_mode,
            .symlinks = repo.data().settings.symlinks,
            .protect = repo.data().settings.protect,
        };
    }

    /// Load the ignore rules for the working tree's root.
    ///
    /// The result is the caller's, and a walk pushes and pops deeper levels
    /// into it as it goes.
    pub fn loadIgnore(repo: *Repository, io: Io) Self.Error!ignore.Rules {
        const case_fold = repo.data().settings.ignore_case;
        var rules = try ignore.Rules.init(repo.data().gpa, .{ .case_fold = case_fold });
        errdefer rules.deinit();
        const excludes = try repo.configuration().getPath(repo.data().gpa, io, repo.topDirectory().get(), "core.excludesfile");
        defer if (excludes) |p| repo.data().gpa.free(p);
        try rules.loadGlobal(io, repo.commonDirectory().get(), excludes, repo.topDirectory().get());
        return rules;
    }

    /// Errors from naming one of the repository's files as a path.
    pub const PathError = Allocator.Error || Io.Dir.RealPathFileAllocError ||
        config_mod.PathSettingError;

    /// The files `loadIgnore` reads, named.
    pub fn ignoreSources(repo: *const Repository, gpa: Allocator, io: Io) PathError!IgnoreSources {
        const common = try repo.commonDirectory().get().realPathFileAlloc(io, ".", gpa);
        defer gpa.free(common);
        const info_exclude = try std.Io.Dir.path.join(gpa, &.{ common, "info", "exclude" });
        errdefer gpa.free(info_exclude);
        const configured = try repo.configuration().getPath(gpa, io, repo.topDirectory().get(), "core.excludesfile");
        defer if (configured) |path| gpa.free(path);
        const excludes_file: ?[]u8 = if (configured) |path| blk: {
            if (std.Io.Dir.path.isAbsolute(path)) break :blk try gpa.dupe(u8, path);
            const top = try repo.topDirectory().get().realPathFileAlloc(io, ".", gpa);
            defer gpa.free(top);
            break :blk try std.Io.Dir.path.join(gpa, &.{ top, path });
        } else null;
        return .{ .excludes_file = excludes_file, .info_exclude = info_exclude };
    }

    /// The index `openIndex` reads, as an absolute path on `gpa`: `index`
    /// in the per-worktree directory, so a linked worktree's own. It need
    /// not exist.
    pub fn indexPath(repo: *const Repository, gpa: Allocator, io: Io) PathError![]u8 {
        const git_dir = try repo.gitDirectory().get().realPathFileAlloc(io, ".", gpa);
        defer gpa.free(git_dir);
        return std.Io.Dir.path.join(gpa, &.{ git_dir, "index" });
    }

    /// Load the attributes for the working tree's root.
    /// The attributes a working-tree operation reads before the working
    /// tree's own: `core.attributesFile` and `info/attributes`, and, where
    /// `attr.tree` names a tree (`attrTree`), every `.gitattributes` of that
    /// tree, which then stand in for the working tree's and any other
    /// tree's (`Attrs.from_tree`), as git reads them.
    pub fn loadAttrs(repo: *Repository, io: Io) Self.Error!attributes.Attrs {
        var attrs = try repo.loadGlobalAttrs(io);
        errdefer attrs.deinit();
        const tree = (try repo.attrTree(io)) orelse return attrs;
        try repo.addAttrsOfTree(io, &attrs, tree, "", 0);
        attrs.from_tree = true;
        return attrs;
    }

    /// `attr.tree`, as git's `compute_default_attr_source` takes it: any
    /// revision expression (`repo_get_oid_treeish`), `HEAD` in a bare
    /// repository as git documents it, peeled to a tree as git's
    /// `get_tree_entry` peels it. `null` where it is unset or names nothing,
    /// which git then reads as though it were unset; the empty tree where it
    /// names an object that is no tree-ish, from which git reads nothing.
    pub fn attrTree(repo: *Repository, io: Io) Self.Error!?Oid {
        const name = repo.configuration().get("attr.tree") orelse return null;
        const oid = rev_parse.resolve(repo.data().gpa, io, repo.revisionSource(), name) catch |err| return switch (err) {
            error.BadRevision, error.AmbiguousRevision, error.RelativePathUnsupported, error.InvalidPattern, error.PatternTooComplex => null,
            else => |e| e,
        };
        const peeled = try repo.peel(io, oid);
        const header = try repo.objectDatabase().readHeader(io, peeled);
        return switch (header.type) {
            .tree => peeled,
            .commit => try repo.commitTree(io, peeled),
            else => repo.objectFormat().emptyTree(),
        };
    }

    /// Every `.gitattributes` blob under `tree`, at `base`, into `attrs`, at
    /// the precedence its depth gives, as git's `read_attr_from_blob` reads
    /// one for each directory.
    fn addAttrsOfTree(repo: *Repository, io: Io, attrs: *attributes.Attrs, tree: Oid, base: []const u8, depth: u32) Self.Error!void {
        if (depth > repo.settings().max_tree_depth) return;
        const db = repo.objectDatabase();
        const found = try db.read(io, tree);
        defer db.allocator().free(found.bytes);
        if (found.type != .tree) return;
        const arena = attrs.arena.allocator();
        var it = (object.Tree.parse(repo.objectFormat(), found.bytes)).iterate();
        while (try it.next()) |entry| {
            const path = if (base.len == 0) try arena.dupe(u8, entry.name) else try arena.print("{s}/{s}", .{ base, entry.name });
            if (entry.mode == .tree) {
                try repo.addAttrsOfTree(io, attrs, entry.oid, path, depth + 1);
            } else if (entry.mode.isBlob() and std.mem.eql(u8, entry.name, ".gitattributes")) {
                const blob = try db.read(io, entry.oid);
                defer db.allocator().free(blob.bytes);
                if (blob.type != .blob) continue;
                try attrs.addText(try arena.dupe(u8, blob.bytes), .{ .base = base, .source = path, .precedence = depth + 1, .form = .blob });
            }
        }
    }

    /// `core.attributesFile` and `info/attributes`, which git reads in every
    /// direction: for a caller that brings a tree's own files, as `git
    /// archive` reads them.
    pub fn loadGlobalAttrs(repo: *Repository, io: Io) Self.Error!attributes.Attrs {
        const case_fold = repo.data().settings.ignore_case;
        var attrs = try attributes.Attrs.init(repo.data().gpa, .{ .case_fold = case_fold });
        errdefer attrs.deinit();
        const file = try repo.configuration().getPath(repo.data().gpa, io, repo.topDirectory().get(), "core.attributesfile");
        defer if (file) |p| repo.data().gpa.free(p);
        try attrs.loadGlobal(io, repo.commonDirectory().get(), file, repo.topDirectory().get());
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
        return filter.Drivers.load(repo.data().gpa, io, repo.configuration(), .{ .common = repo.commonDirectory().get(), .work = if (repo.workDirectory()) |work| work.get() else null, .shared = repo.data().shared }, with);
    }

    /// Errors from `loadFilters`: the drivers', and those of finding
    /// `.lfsconfig` for relic's own LFS.
    pub const LoadFiltersError = filter.Drivers.LoadError || LfsconfigError;

    /// Errors from finding `.lfsconfig`.
    pub const LfsconfigError = Allocator.Error || aegis.own.ReadFileError ||
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
    /// `HEAD`'s tree again. A file stamped within two seconds of being
    /// looked at proves nothing yet and is read again.
    pub fn lfsconfigText(repo: *Repository, io: Io) LfsconfigError!?[]u8 {
        var guard = try repo.data().lfsconfig_cache.acquire(io);
        defer guard.deinit(io);
        const cache = guard.value();
        const seen_at = Io.Clock.real.now(io);
        const key = try repo.lfsconfigKey(io);
        if (cache.*) |cached| {
            if (std.meta.eql(cached.key, key) and cached.settled()) {
                return if (cached.text) |t| try repo.data().gpa.dupe(u8, t) else null;
            }
        }
        const text = try repo.lfsconfigTextUncached(io, key);
        errdefer if (text) |t| repo.data().gpa.free(t);
        const kept = if (text) |t| try repo.data().gpa.dupe(u8, t) else null;
        if (cache.*) |old| if (old.text) |t| repo.data().gpa.free(t);
        cache.* = .{ .key = key, .text = kept, .seen_at = seen_at };
        return text;
    }

    fn lfsconfigKey(repo: *Repository, io: Io) LfsconfigError!LfsconfigKey {
        var key: LfsconfigKey = .{};
        if (repo.workDirectory()) |work| {
            const wd = work.get();
            if (wd.statFile(io, ".lfsconfig", .{})) |st| {
                if (st.kind != .directory) {
                    key.worktree = .of(st);
                    return key;
                }
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => |e| return e,
            }
            if (repo.gitDirectory().get().openFile(io, "index", .{})) |file| {
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
        if (repo.workDirectory()) |work| {
            const wd = work.get();
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

    /// Errors from `LockedIndex.commit`.
    pub const WriteIndexError = index_mod.WriteError || ErrorNamespace.Error;

    /// Errors from `writeShallow`.
    pub const WriteShallowError = shallow.Error;

    /// Write the shallow boundary the object database holds to
    /// `.git/shallow`, or remove the file when there is none, with the
    /// repository's shared mode: refused (`ShallowChanged`) when another
    /// writer changed the file since this repository read it, as git
    /// refuses it.
    pub fn writeShallow(repo: *Repository, io: Io) WriteShallowError!void {
        const d = repo.data();
        d.shallow_seen = try shallow.write(d.gpa, io, repo.commonDirectory().get(), &d.odb.shallow, .{ .seen = d.shallow_seen, .shared = d.shared, .pid_file = d.settings.lockfile_pid });
    }

    /// Errors from `lockIndex`.
    pub const LockIndexError = fs.LockFile.OpenError || index_mod.ReadError;

    /// The repository's index, held under `index.lock` from its read to its
    /// write, as git's `repo_hold_locked_index` holds it: no other writer's
    /// change lands between the two and is lost, and a second writer is
    /// refused while this one holds it.
    pub const LockedIndex = struct {
        /// The index as read under the lock. Change it, or put another in
        /// its place, then `commit`.
        index: index_mod.Index,
        /// Private: `index.lock`.
        lock: fs.LockFile,
        /// Private: the lock's write buffer.
        buffer: []u8,
        /// Private: the repository whose index this is.
        repo: *Repository,

        /// Write the index as git writes one, a racily clean entry smudged
        /// only where its file changed, read through the repository's own
        /// rules and attributes, and put it in place.
        pub fn commit(locked: *LockedIndex, io: Io) WriteIndexError!void {
            const repo = locked.repo;
            var options = try repo.indexWriteOptions(&locked.index);
            var attrs: ?attributes.Attrs = null;
            defer if (attrs) |*a| a.deinit();
            var check: worktree.RacyCheck = undefined;
            if (repo.workDirectory()) |work| {
                const wt = work.get();
                attrs = try repo.loadAttrs(io);
                var rules = try repo.worktreeRules();
                rules.attrs = &attrs.?;
                check = .{ .gpa = repo.data().gpa, .io = io, .wt = wt, .rules = rules };
                options.racy = check.racy();
            }
            const freshen = try repo.writeSharedIfDue(io, &locked.index, options);
            try locked.index.commitTo(io, &locked.lock, options);
            // Only once the file that stands on it is in place, as git's.
            if (freshen) |name| repo.freshenShared(io, &name);
        }

        /// Give the lock up, the index file as it was unless `commit` put
        /// this one in its place, and release the index.
        pub fn deinit(locked: *LockedIndex, io: Io) void {
            locked.lock.deinit(io);
            locked.repo.data().gpa.free(locked.buffer);
            locked.index.deinit();
            locked.* = undefined;
        }
    };

    /// Take `index.lock` and read the index under it.
    pub fn lockIndex(repo: *Repository, io: Io) LockIndexError!LockedIndex {
        const gpa = repo.data().gpa;
        const buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(buffer);
        var lock = try fs.LockFile.open(gpa, io, repo.gitDirectory().get(), .{ .sub_path = "index", .buffer = buffer }, repo.indexLock());
        errdefer lock.deinit(io);
        const index = try repo.openIndex(io);
        return .{ .index = index, .lock = lock, .buffer = buffer, .repo = repo };
    }

    /// How this repository's index file is read.
    fn indexReadOptions(repo: *const Repository) index_mod.ReadOptions {
        return .{ .git_dir = repo.gitDirectory().get(), .kind = repo.objectFormat(), .timestamp_resolution = repo.data().odb.timestamp_resolution };
    }

    /// The stores a revision expression is read against (`rev_parse`).
    pub fn revisionSource(repo: *Repository) rev_parse.Source {
        return .{
            .gpa = repo.data().gpa,
            .config = repo.configuration(),
            .odb = repo.objectDatabase(),
            .refs = repo.refStore(),
            .commits = &repo.data().commits,
            .index = repo.indexReadOptions(),
        };
    }

    /// Read the index, its untracked cache made, kept or dropped as
    /// `core.untrackedCache` says (git's `tweak_untracked_cache`).
    pub fn openIndex(repo: *Repository, io: Io) index_mod.ReadError!index_mod.Index {
        var index = try index_mod.Index.read(repo.data().gpa, io, repo.gitDirectory().get(), "index", repo.indexReadOptions());
        errdefer index.deinit();
        try repo.tweakUntrackedCache(&index);
        return index;
    }

    /// git's `tweak_untracked_cache`: `core.untrackedCache=true` gives the
    /// index a cache, a new one where it has none or one made elsewhere
    /// (`add_untracked_cache`); `false` takes it away.
    fn tweakUntrackedCache(repo: *const Repository, index: *index_mod.Index) Allocator.Error!void {
        switch (repo.data().settings.untracked_cache) {
            .keep => {},
            .remove => if (index.untracked) |*cache| {
                cache.deinit();
                index.untracked = null;
            },
            .write => {
                // A bare repository has no working tree to cache.
                const ident = repo.data().untracked_ident orelse return;
                if (index.untracked) |*cache| {
                    if (cache.madeFor(ident)) return;
                    cache.deinit();
                    index.untracked = null;
                }
                index.untracked = try untracked_mod.UntrackedCache.init(repo.data().gpa, ident, repo.data().settings.untracked_flags);
            },
        }
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
        var index = try index_mod.Index.read(repo.data().gpa, io, dir, sub_path, .{ .git_dir = repo.gitDirectory().get(), .kind = repo.objectFormat() });
        errdefer index.deinit();
        try repo.tweakUntrackedCache(&index);
        return index;
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
        return repo.data().commits.get(repo.data().gpa, io, &repo.data().odb, commit_oid, .{ .out = out });
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
            defer repo.data().odb.allocator().free(found.bytes);
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
        /// The message, in `i18n.commitEncoding` (`message.commitEncoding`),
        /// which the commit's `encoding` header names when it is not UTF-8,
        /// as git's `commit_tree` writes it.
        message: []const u8,
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
    /// `options.diagnostic`, when given, keeps the refused setting or signing
    /// stderr and is cleared on every call.
    pub fn writeCommit(repo: *Repository, io: Io, request: CommitRequest, options: WriteCommitOptions) Self.WriteError!Oid {
        const diagnostic = options.diagnostic;
        diagnostic_mod.reset(diagnostic);
        const commit_encoding = message.commitEncoding(repo.configuration()) catch |err| {
            try refuseSetting(diagnostic, "i18n.commitEncoding");
            return err;
        };
        if (std.mem.findScalar(u8, request.message, 0) != null) return error.NulInMessage;
        var fields: object.Commit.Fields = .{
            .tree = request.tree,
            .parents = request.parents,
            .author = request.author,
            .committer = request.committer,
            .encoding = if (encoding.isUtf8(commit_encoding)) null else commit_encoding,
            .extra = request.extra,
            .message = request.message,
        };
        // git's `commit_tree`: in UTF-8, what is not UTF-8 is taken as
        // Latin-1, the people and the headers too; the separators between
        // the pieces are ASCII, so each piece converts as the whole would
        var arena: std.heap.ArenaAllocator = .init(repo.data().gpa);
        defer arena.deinit();
        if (fields.encoding == null) {
            const a = arena.allocator();
            fields.author.name = try encoding.ensureUtf8(a, fields.author.name);
            fields.author.email = try encoding.ensureUtf8(a, fields.author.email);
            fields.committer.name = try encoding.ensureUtf8(a, fields.committer.name);
            fields.committer.email = try encoding.ensureUtf8(a, fields.committer.email);
            fields.message = try encoding.ensureUtf8(a, fields.message);
            const extra = try a.dupe(object.ExtraHeader, fields.extra);
            for (extra) |*h| h.value = try encoding.ensureUtf8(a, h.value);
            fields.extra = extra;
        }
        var signer = try repo.signerFor(io, request.signing, .commit, diagnostic);
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
        var signer = try repo.signerFor(io, request, .tag, diagnostic);
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
    fn signerFor(repo: *Repository, io: Io, request: signing.Request, target: enum { commit, tag }, diagnostic: ?*Diagnostic) WriteError!?signing.Signer {
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
        return signing.Signer.init(repo.data().gpa, io, repo.configuration(), repo.topDirectory().get(), programs) catch |err| {
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
        tx.peeler = repo.refObjects();
        return tx;
    }

    /// What the ref store asks of this repository's objects: what an
    /// annotated tag peels to, and whether an object exists. The
    /// repository must outlive it.
    pub fn refObjects(repo: *Repository) refs_mod.Peeler {
        return .{ .context = repo, .peel = peelForRefs, .exists = existsForRefs };
    }

    fn existsForRefs(io: Io, context: *anyopaque, oid: Oid) bool {
        const repo: *Repository = @ptrCast(@alignCast(context)); // aegis: no-danger: the context handed out with this function is a Repository
        return repo.data().odb.exists(io, oid) catch false;
    }

    fn peelForRefs(io: Io, context: *anyopaque, oid: Oid) ?Oid {
        const repo: *Repository = @ptrCast(@alignCast(context)); // aegis: no-danger: the context handed out with this function is a Repository
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
            .git_dir = repo.gitDirectory(),
            .common_dir = repo.commonDirectory(),
            .work_dir = repo.workDirectory(),
        }, programs, options);
    }

    /// Every linked worktree.
    pub fn listWorktrees(repo: *Repository, io: Io) worktrees.Error!worktrees.Listing {
        return worktrees.list(repo.data().gpa, io, repo.refStore());
    }

    /// git's `worktree prune`: the administrative directories that hold no
    /// worktree go, but for any with a `locked` file, as `options` asks;
    /// `core.ignoreCase` in place of `options.ignore_case`.
    pub fn pruneWorktrees(repo: *Repository, io: Io, options: worktrees.PruneOptions) (worktrees.Error || config_mod.ValueError)!worktrees.PruneOutcome {
        var asked = options;
        asked.ignore_case = try repo.configuration().getBool("core.ignorecase", false);
        return worktrees.prune(repo.data().gpa, io, repo.refStore(), asked);
    }
};

test "reading a signing policy allocates nothing of the configuration's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try Self.Repository.create(gpa, io, tmp.dir, .{ .default_branch = "main" });
    defer repo.deinit(io);
    try repo.editConfig(io, &.{.{ .name = "tag.gpgSign", .value = "true" }}, .{});
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(repo.data().config_state).gpa;
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

test "a malformed core setting is refused when it is published, as git dies reading it, and a quoted one is read without allocating" {
    const Adapter = struct {
        fn core(r: *const Self.Repository) !attributes.CoreSettings {
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
    var repo = try Self.Repository.create(gpa, io, tmp.dir, .{ .default_branch = "main" });
    defer repo.deinit(io);
    // The engines' settings are read once, as a configuration is published.
    inline for (.{ "core.ignorecase", "core.filemode", "core.symlinks", "core.trustctime" }) |setting| {
        try std.testing.expectError(error.NotABoolean, repo.editConfig(io, &.{.{ .name = setting, .value = "maybe" }}, .{}));
    }
    try std.testing.expectError(error.MalformedValue, repo.editConfig(io, &.{.{ .name = "core.checkstat", .value = "unknown" }}, .{}));
    // The line-ending settings are asked for by the conversions that use them.
    inline for (.{ "core.autocrlf", "core.safecrlf" }) |setting| {
        try repo.editConfig(io, &.{.{ .name = setting, .value = "maybe" }}, .{});
        try std.testing.expectError(error.NotABoolean, Adapter.rules(&repo));
        try repo.editConfig(io, &.{.{ .name = setting, .value = "false" }}, .{});
    }
    try repo.editConfig(io, &.{.{ .name = "core.eol", .value = "unknown" }}, .{});
    try std.testing.expectError(error.MalformedValue, Adapter.rules(&repo));
    try repo.editConfig(io, &.{.{ .name = "core.eol", .value = "native" }}, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\n autocrlf = \"input\"\n" });
    var reread = try Self.Repository.open(gpa, io, tmp.dir, .{});
    defer reread.deinit(io);
    try std.testing.expectEqual(attributes.CoreSettings.AutoCrlf.input, (try Adapter.core(&reread)).autocrlf);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(reread.data().config_state).gpa;
    config_gpa.* = failing.allocator();
    defer config_gpa.* = gpa;
    // The value was read once, quotes and all, when the file was.
    try std.testing.expectEqual(attributes.CoreSettings.AutoCrlf.input, (try Adapter.core(&reread)).autocrlf);
}

test "a malformed case policy is refused when it is published, and the rule loaders read the published one without the configuration allocating" {
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
    var r = try Self.Repository.create(gpa, io, tmp.dir, .{ .default_branch = "main" });
    defer r.deinit(io);
    try std.testing.expectError(error.NotABoolean, r.editConfig(io, &.{.{ .name = "core.ignorecase", .value = "maybe" }}, .{}));
    try r.editConfig(io, &.{.{ .name = "core.ignorecase", .value = "true" }}, .{});
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(r.data().config_state).gpa;
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
    var r = try Self.Repository.create(gpa, io, tmp.dir, .{ .default_branch = "main" });
    defer r.deinit(io);
    const long_name = &@as([300]u8, @splat('x'));
    try r.editConfig(io, &.{.{ .name = "filter." ++ long_name ++ ".required", .value = "true" }}, .{});
    const names = try r.requiredFilters(gpa);
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings(long_name, names[0]);
    // The values were read when the file was: asking for them allocates
    // nothing of the configuration's.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const config_gpa = &config_owner.get(r.data().config_state).gpa;
    config_gpa.* = failing.allocator();
    defer config_gpa.* = gpa;
    try std.testing.expectEqual(@as(usize, 1), try Read.count(&r));
}
