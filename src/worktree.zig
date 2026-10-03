//! The working tree: staging it, writing a tree out of it, putting a tree
//! into it, and saying how the three views differ.
//!
//! Every path that comes out of a tree or an index is validated before it
//! becomes a filesystem path, because a tree entry's name is written by
//! whoever wrote the tree.

const core = @import("worktree_core.zig");
pub const snapshot = @import("snapshot.zig");
pub const worktrees = @import("worktrees.zig");
pub const sparse = @import("sparse.zig");
pub const sparsecheckout = @import("sparsecheckout.zig");
pub const ignore = @import("ignore.zig");
pub const attributes = @import("attributes.zig");
pub const wildmatch = @import("wildmatch.zig");
pub const convert = @import("convert.zig");
pub const filter = @import("filter.zig");
pub const dirscan = @import("dirscan.zig");
pub const safepath = @import("safepath.zig");
/// Errors from working-tree operations.
pub const Error = core.Error;
/// What the caller supplies so that a blob is hashed the way git would hash
/// it, and so that ignore rules are the ones git would apply.
pub const Rules = core.Rules;
/// What `addAll` changed.
pub const AddOutcome = core.AddOutcome;
/// Where the blobs a staging pass writes are put.
pub const NewBlobs = core.NewBlobs;
/// How `addAll` behaves.
pub const AddOptions = core.AddOptions;
/// Files a staging pass skipped under `AddOptions.ignore_errors`.
/// The caller owns this report and hands it in through `error_report`.
pub const AddErrorReport = core.AddErrorReport;
/// `git add -A`: walk the working tree, stage what changed, stage deletions,
/// and keep the cache tree true.
///
/// The stat shortcut is what makes a warm call cheap: an entry whose
/// recorded stat still matches the file is neither opened nor hashed. git's
/// racy rule is what keeps it correct: an entry whose modification time is
/// not older than the index's own is read anyway, because a file rewritten
/// inside one second without changing size is invisible to a stat.
///
/// A repository inside the working tree that the index has nothing for is
/// staged as git stages it, as a gitlink to the commit it has checked out,
/// and counted in `AddOutcome.nested_repositories`; one with no commit
/// checked out is `error.NoCommitCheckedOut`, where git's `add` stops too.
pub const addAll = core.addAll;
/// Build the tree the index describes, through the cache tree, and return
/// its name.
///
/// A cache-tree node that is still valid is used as it stands: no directory
/// under it is rebuilt and no tree object is written for it. That is the
/// difference between a warm call and a cold one.
pub const writeTree = core.writeTree;
/// One path's difference between two of the three views.
pub const Change = core.Change;
/// One path's status.
pub const StatusEntry = core.StatusEntry;
/// What a submodule's working tree holds, as its superproject's status sees
/// it.
///
/// Any of the three makes the gitlink modified in the working tree, which
/// is the ` M` that `git status --porcelain` prints for all three alike.
pub const SubmoduleState = core.SubmoduleState;
/// What `status` asks of a populated submodule.
///
/// The working-tree layer cannot open another repository — that is the
/// layer above it — so the question goes through here.
/// `submodule.StatusProbe` answers it the way git does: it opens the
/// submodule, honours `submodule.<name>.ignore` and `diff.ignoreSubmodules`,
/// and runs a status inside, recursively.
pub const SubmoduleProbe = core.SubmoduleProbe;
/// What `status` found, sorted by path.
pub const Status = core.Status;
/// How `status` behaves.
pub const StatusOptions = core.StatusOptions;
/// HEAD against the index against the working tree, as values.
///
/// Never as text: `XY path` is presentation, and a caller that wants it can
/// write two characters from these two enums.
pub const status = core.status;
/// One flattened tree entry.
/// One flattened tree entry: a path's mode and object.
pub const TreeEntry = core.TreeEntry;
/// Every path a tree holds, flattened, as the caller's map from path to
/// mode and object name.
///
/// The map and its keys come from `arena`, so a caller frees them by
/// resetting it.
pub const flatten = core.flatten;
/// What `resetIndex` changed.
pub const ResetOutcome = core.ResetOutcome;
/// Make the index describe `tree`, and leave the working tree alone.
///
/// This is `git reset` with no paths and no `--hard`: what is staged goes
/// back to what the commit says, and the files on the disk are not touched.
/// An entry that keeps its object name and mode keeps its cached stat too,
/// so the next `addAll` still takes the stat shortcut over it.
pub const resetIndex = core.resetIndex;
/// What `checkout` did.
pub const CheckoutOutcome = core.CheckoutOutcome;
/// Where a refusal is written, so `error.UnsafePath` can say which path and
/// which rule without allocating.
pub const Refusal = core.Refusal;
/// How `checkout` behaves.
pub const CheckoutOptions = core.CheckoutOptions;
/// `read-tree --reset -u`: make the working tree and the index match `tree`.
///
/// Files the index has and the tree does not are removed; files whose
/// content or mode differ are rewritten; untracked and ignored files are
/// left exactly as they are. Nothing about `HEAD` moves: a caller that wants
/// a branch moved does that with a ref transaction, which is a separate
/// decision from what is on the disk.
///
/// The `.gitattributes` files the tree carries are the ones the files are
/// written by, for as long as the call lasts, as they are in git: a
/// checkout into an empty directory has no other copy of them. A file a
/// filter hands over late, or whose LFS object has to be fetched, is
/// written after all the others.
pub const checkout = core.checkout;
/// Put the tree's own `.gitattributes` files into `attrs`, each at the depth
/// its directory is at. The text lives in `arena`; the caller takes the
/// levels out again before the arena goes. A later `Attrs.enter` reads the
/// working tree's file only for a directory the tree has none in, which is
/// how git reads attributes while it checks a tree out: from the index it
/// is writing first.
pub const addTreeAttributes = core.addTreeAttributes;
/// One path `writePaths` puts into the working tree.
pub const PathWrite = core.PathWrite;
/// `checkout-index -f` for the named paths only: write each blob into the
/// working tree, or remove the file, and bring the index along. Nothing
/// else in either is touched, so a caller that has decided which paths may
/// change — a merge that has checked none of them holds local changes —
/// changes exactly those. Removals happen before writes, so a file may give
/// way to a directory of the same name. A file is written as a checkout
/// writes it, through the same line-ending conversion, smudge filters and
/// LFS, and one a filter hands over late is written after the others.
pub const writePaths = core.writePaths;
/// What `writeEntry` left on the disk.
pub const Written = core.Written;
/// Write one tree entry into the working tree the way `checkout` writes it:
/// a file through `conv` -- `ident`, line endings and the smudge filter or
/// relic's own LFS, as the attributes say -- with the executable bit set
/// where the filesystem keeps one, a symlink made or written as a file
/// holding its target, a gitlink made as an empty directory. Whatever is at
/// `path` is replaced; the directories above it are made. `conv` must not
/// be one that may hand a file over late.
pub const writeEntry = core.writeEntry;
/// Write a blob's contents already in memory at `path`, as `writeEntry`
/// writes a blob, for a caller that stores no object for them.
pub const writeBytes = core.writeBytes;
/// Remove one file from the working tree, and every directory above it that
/// it leaves empty. A file that is already gone is not an error.
pub const removeEntry = core.removeEntry;
/// The paths an update would lose work at, as git lists them.
pub const Obstructions = core.Obstructions;
/// What `verifyUpdates` is told.
pub const VerifyOptions = core.VerifyOptions;
/// `verify_uptodate` and `verify_absent` from git's `unpack-trees`, over
/// every path an update changes: `updates` maps each path whose index
/// entry the update rewrites, adds or removes to what it will hold, `null`
/// for removal.
///
/// A tracked path there whose file has changes of its own is
/// `error.LocalChangesWouldBeOverwritten`. A new path where an untracked,
/// unignored file stands -- or stands where a directory above it goes, or
/// where a directory holding anything but files the update removes stands
/// in the way -- is `error.UntrackedWouldBeOverwritten`. Every such path is
/// listed in `options.obstructions` before the error comes back, changed
/// ones taking precedence; nothing on the disk is touched either way.
pub const verifyUpdates = core.verifyUpdates;
/// The check `index.WriteOptions.racy` asks for, over the working tree at
/// `wt` read by `rules`: a racily clean entry is smudged only when its file
/// holds something else. A file that cannot be read counts as changed.
pub const RacyCheck = core.RacyCheck;
/// Whether the file at `entry.path` holds something other than the index
/// says. A file that is not there has nothing to lose, which is how git
/// treats one deleted by hand; a submodule's checkout is its own.
pub const differsFromIndex = core.differsFromIndex;
/// What `applySparse` changed.
pub const SparseOutcome = core.SparseOutcome;
/// Make the working tree hold exactly the paths the sparse patterns
/// include.
///
/// A path that leaves gets `skip-worktree` and its file is removed; a path
/// that returns loses the flag and its file is written. A file whose
/// content differs from the index is left where it is and counted, because
/// removing it would throw away work nobody asked to throw away; and a
/// returning path where something is already on the disk is not written
/// over, for the same reason, which is git's rule for both.
pub const applySparse = core.applySparse;
/// What `list` found.
pub const Listing = core.Listing;
/// The index's paths plus the untracked ones, with the ignore rules applied:
/// what `git ls-files --cached --others --exclude-standard` lists. A
/// repository inside the working tree that the index has nothing for is one
/// untracked path ending in `/`.
///
/// A sparse directory is listed as itself, with its trailing slash, which
/// is what `git ls-files --sparse` prints, and the walk for untracked paths
/// does not go into one: what is there is outside the sparse checkout.
pub const list = core.list;
