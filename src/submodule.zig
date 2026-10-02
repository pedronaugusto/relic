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

const core = @import("submodule_core.zig");
pub const gitmodules = @import("gitmodules.zig");
pub const gitlink = @import("gitlink.zig");
pub const submoduletransport = @import("submoduletransport.zig");
/// How deep submodules may nest inside submodules before a recursive
/// operation stops.
pub const max_depth = core.max_depth;
/// Errors from submodule operations.
pub const Error = core.Error;
/// Where a refusal says which submodule and which setting, without
/// allocating.
pub const Refusal = core.Refusal;
/// Read `.gitmodules` from where git reads it: the working tree's file; or,
/// when there is none, the blob the index records; or, when the index
/// records none, the one in `HEAD`'s tree. While the index holds the file
/// unmerged git reads none of it, and neither does this.
pub const loadGitmodules = core.loadGitmodules;
/// One gitlink in the index.
pub const Entry = core.Entry;
/// Every gitlink in an index, in index order, each path once.
pub const Listing = core.Listing;
/// The gitlinks `index` holds, with the `.gitmodules` section for each.
///
/// `paths` narrows the list the way a pathspec does: each is a submodule's
/// path or a directory above some. `null` lists every one.
pub const list = core.list;
/// Whether git counts the submodule as active: `submodule.<name>.active`
/// when it is set, else whether `submodule.active`'s pathspecs match its
/// path when those are set, else whether `submodule.<name>.url` is.
pub const isActive = core.isActive;
/// What `git submodule status` prints in its first column.
pub const State = core.State;
/// One submodule, as `git submodule status` reports it.
pub const StatusEntry = core.StatusEntry;
/// What `status` found, in the order git prints it.
pub const Statuses = core.Statuses;
/// How `status` behaves.
pub const StatusOptions = core.StatusOptions;
/// `git submodule status`: each submodule's state and commit.
///
/// A gitlink `.gitmodules` does not name is `error.NoSubmoduleMapping`, as
/// it is for git. The describe name git prints after the path is not
/// computed.
pub const status = core.status;
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
pub const StatusProbe = core.StatusProbe;
/// How `init` behaves.
pub const InitOptions = core.InitOptions;
/// What `init` wrote.
pub const InitOutcome = core.InitOutcome;
/// `git submodule init`: copy each submodule's url and update strategy
/// from `.gitmodules` into `.git/config`, and mark it active.
///
/// A url already configured is left as it is. A relative one is resolved
/// against the default remote's url, or against the superproject's own
/// path when that remote has none, exactly as git resolves it.
pub const init = core.init;
/// How `sync` behaves.
pub const SyncOptions = core.SyncOptions;
/// What `sync` wrote.
pub const SyncOutcome = core.SyncOutcome;
/// `git submodule sync`: rewrite each active submodule's url in
/// `.git/config` from `.gitmodules`, and point a populated submodule's
/// default remote at it.
///
/// A relative url is resolved twice, as git does: once for the
/// superproject's configuration, and once for the submodule's own remote,
/// where a superproject url that is itself relative needs a `../` for each
/// component of the submodule's path in front of it.
pub const sync = core.sync;
/// How `deinitialize` behaves.
pub const DeinitOptions = core.DeinitOptions;
/// What `deinitialize` did.
pub const DeinitOutcome = core.DeinitOutcome;
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
pub const deinitialize = core.deinitialize;
/// How `absorbGitDirs` behaves.
pub const AbsorbOptions = core.AbsorbOptions;
/// What `absorbGitDirs` did.
pub const AbsorbOutcome = core.AbsorbOutcome;
/// `git submodule absorbgitdirs`: move each submodule's `.git` directory
/// into `modules/<name>` in the superproject's git directory, and leave
/// a `.git` file behind that names it. Every populated submodule is then
/// absorbed into in turn, so nested ones land in
/// `modules/<outer>/modules/<inner>`; a nested `.git` file left pointing at
/// where its parent's directory used to be is pointed at where it went.
pub const absorbGitDirs = core.absorbGitDirs;
/// What `update` asks for when a submodule's repository or commit is not on
/// the disk. The wire protocol is not this module's; a caller that has one
/// hands it in here.
pub const Transport = core.Transport;
/// Errors a `Transport` may give. Its own detail is its to keep.
pub const TransportError = core.TransportError;
/// How `update` behaves.
pub const UpdateOptions = core.UpdateOptions;
/// What `update` did.
pub const UpdateOutcome = core.UpdateOutcome;
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
pub const update = core.update;
/// One populated submodule, as `Walk.next` hands it over.
pub const Visit = core.Visit;
/// How `walk` behaves.
pub const WalkOptions = core.WalkOptions;
/// Every populated submodule, one at a time, in the order `git submodule
/// foreach` visits them: a submodule, then — when recursive — its own,
/// depth first. Nothing is run; the caller does what it likes with each
/// repository.
pub const Walk = core.Walk;
/// Begin walking `repo`'s populated submodules. `repo` is the caller's and
/// must outlive the walk.
pub const walk = core.walk;
