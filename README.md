# relic

[![CI](https://github.com/pedronaugusto/relic/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/relic/actions/workflows/ci.yml)

relic is git as a Zig library: objects, packs, refs, the index, the working
tree and diffs; fetch, clone and push over HTTP(S), ssh and local paths;
merge, cherry-pick, revert and rebase; hooks, filters, signing, submodules,
stash; LFS with locks. What it lays down is what git reads back, so a program
that needs a repository can have one in process.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs. CI compares the two.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const relic = @import("relic");

// Create a repository. `HEAD`, `config`, `objects/` and `refs/` land on
// the disk and git reads what is written.
var repo = try relic.repo.Repository.init(gpa, io, dir, .{
    .default_branch = "main",
    .object_format = .sha1,
});
defer repo.deinit(io);

try dir.writeFile(io, .{ .sub_path = "README.md", .data = "# a project\n" });
try dir.createDirPath(io, "src");
try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
try dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
try dir.writeFile(io, .{ .sub_path = "build.log", .data = "not staged\n" });

// The ignore rules and the attributes come from the repository, because
// `core.autocrlf` and a `text=auto` line decide the bytes a blob holds
// and therefore its name.
var ignore_rules = try repo.loadIgnore(io);
defer ignore_rules.deinit();
var attrs = try repo.loadAttrs(io);
defer attrs.deinit();
var rules = try repo.worktreeRules();
rules.ignore = &ignore_rules;
rules.attrs = &attrs;

// Stage the working tree. An entry whose recorded stat still matches is
// neither opened nor hashed, so a second call over an unchanged tree
// costs a walk and nothing else.
var index = try repo.openIndex(io);
defer index.deinit();
const staged = try relic.worktree.addAll(gpa, io, dir, &index, &repo.odb, .{ .rules = rules });
std.debug.assert(staged.added == 3);

// Write the tree, through the cache tree, and the index that describes
// it. The index goes through `index.lock`; a lock another writer holds
// is `error.LockHeld` and is never broken.
const tree = try relic.worktree.writeTree(gpa, io, &index, &repo.odb);
try index.write(io, repo.git_dir, "index", .{});

// A commit object, with no ref moved: moving one is a transaction.
const commit = try repo.writeCommit(io, .{
    .tree = tree,
    .author = who,
    .committer = who,
    .message = "first commit\n",
}, null);

// Move the branch under its lock, then append the reflog.
var tx = repo.beginRefs();
defer tx.deinit(io);
try tx.update("refs/heads/main", .{ .direct = commit }, .must_not_exist);
try tx.commit(io, .{ .who = who, .message = "commit (initial): first commit" });

// Read it back through the front door.
const head = (try repo.head(io)).?;
defer gpa.free(head.name);
std.debug.assert(std.mem.eql(u8, head.name, "refs/heads/main"));
std.debug.assert(head.oid.eql(commit));

// Change a file, stage it, and write a second tree.
try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {\n    work();\n}\n" });
_ = try relic.worktree.addAll(gpa, io, dir, &index, &repo.odb, .{ .rules = rules });
const second = try relic.worktree.writeTree(gpa, io, &index, &repo.odb);

// What changed, as values rather than as text.
var changes = try relic.diff.tree(gpa, io, &repo.odb, tree, second, .{});
defer changes.deinit();
std.debug.assert(changes.items.len == 1);
std.debug.assert(changes.items[0].status == .modified);
std.debug.assert(std.mem.eql(u8, changes.items[0].path(), "src/main.zig"));

// And as the patch git prints, when text is what you want.
var patch: std.Io.Writer.Allocating = .init(gpa);
defer patch.deinit();
try relic.diff.unified(gpa, io, &patch.writer, &repo.odb, changes.items[0], .{});
std.debug.assert(std.mem.startsWith(u8, patch.written(), "diff --git a/src/main.zig b/src/main.zig\n"));

// Put the first tree back: files the tree lacks go, changed ones are
// rewritten, and untracked and ignored files are left alone.
const restored = try relic.worktree.checkout(gpa, io, dir, &index, &repo.odb, tree, .{ .rules = rules });
std.debug.assert(restored.written == 1);
```
<!-- END GENERATED -->

## Snapshots

Checkout's `durability = .durable` syncs the selected file bytes, including
files whose writes were skipped, then their directories before success.
The default is `.none`. A snapshot store opened with `.durability = .durable`
also makes its entire owned tree/blob closure durable before returning an ID
and uses durable checkout for restore. `Odb.makeDurable(io, roots)` gives
other callers the same barrier for selected objects, including commit history
and tag targets. Record an intent only after that barrier succeeds, and record
restoration only after durable checkout succeeds. A barrier failure is returned.

Durable completion reads the object closure and opens and syncs each loose
object or used pack/index and each affected directory. It waits on storage;
on macOS it also requests drive-cache flushes. Directory barriers are requested
on Windows through writable directory handles; a filesystem that refuses them
returns an error. The caller owns durability of the supplied root directory's
entry in its parent. Gitlinks and LFS payloads belong to separate stores.

`Odb.openAt` borrows its directory handle on success and failure; close
that original handle in the caller. Odb owns its format, sources and storage
policy together. Use `objectFormat()`, `settings()` and `allocator()` to
read them; changing format or storage policy requires a new database.
Repository configuration is borrowed through `configuration()`. Apply
in-memory changes with `editConfig(edits, diagnostic)`; a whole batch is
validated before it replaces the old view and ref policy. Hash and backend
changes require reopening. Changing worktree configuration sources requires
a standalone configuration write followed by refresh; a memory-only edit
returns `WorktreeConfigChanged`. For persisted edits, open the intended file
with `Config.openFile`, edit and write that configuration, then refresh the
repository. `Config.write` selects the last writable source.

`worktree.snapshot.Store` records a working tree in a private object store.
A snapshot is a tree ID. Before returning it, capture takes every tree and
blob it reaches into the store, including unchanged objects held only by
the source. Reads and reopening use only the private objects, never the
source's packs or alternate metadata. A rewrite and prune in the source
cannot make a snapshot unreadable.
Objects already owned are not copied again; a bounded cache skips subtrees
whose closure has been completed. Reopening rebuilds that cache as needed.

```zig
const snapshots = relic.worktree.snapshot;
var store = try snapshots.Store.open(gpa, io, private_dir, .{
    .kind = repo.objectFormat(),
});
defer store.deinit(io);
const first = (try store.capture(io, .{ .repository = &repo }, .{})).snapshot;
const second = (try store.capture(io, .{ .repository = &repo }, .{})).snapshot;
var changes = try store.diff(io, first, second, .{});
defer changes.deinit();
_ = try store.restore(io, first, destination_dir, .{});
```

The source index supplies tracked paths, including ignored ones. Capture
reads their working files and untracked-not-ignored files under the source's
ignore, attribute, line-ending and filter rules, without writing its index,
refs or objects. Present files are read afresh each time; sparse tracked
paths absent by policy keep their indexed contents. Configured filter programs
need `CaptureOptions.programs`; native LFS writes into the private store even
when the source has its own `lfs.storage`. For a folder without a repository,
pass `.{ .folder = folder_dir }`: its `.gitignore` and `.gitattributes` apply,
and no configuration is read from outside it.

Like jj's working-copy snapshots, capture includes new files automatically
and returns the same tree for unchanged contents. Like `git stash create`,
it leaves the working tree alone and returns an object name. The result
needs only its tree closure, with no history parents, stash stack or index
snapshot. Gitlinks record submodule commits rather than their files. LFS
pointers are Git blobs; referenced LFS payloads are outside the Git object
closure, and restoring emits pointers unless filter drivers are supplied.

Restore writes an empty destination by default and refuses files in the
way. `RestoreOptions.from` names its previous snapshot so removed paths can
be deleted; `checkout.force` allows discarding local changes. Tree attributes
apply on restore, and `checkout.rules` supplies additional core settings and
filter drivers. Paths outside the previous and new snapshots are left alone.

The caller serializes operations, retains tree IDs, and decides sequence
numbers, frames and retention. The store writes no refs. Objects needed by
retained IDs must be kept; close the store before collecting its objects
and reopen it afterwards. To migrate existing borrowed tree IDs, call
`store.adoptTree(io, &source_db, tree)` while their old objects still exist.
It copies the same tree and blob closure without recapturing files, including
objects split between the source and store, and applies the store’s durability
policy before returning the unchanged ID. A failed capture returns no snapshot, and any
objects already written remain reusable. Set the object database's sync
options when retained IDs need durable objects before they are published.

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/relic
```

```zig
const relic_dep = b.dependency("relic", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("relic", relic_dep.module("relic"));
```

One module, with [conduit](https://github.com/pedronaugusto/conduit) for
running programs and [sweep](https://github.com/pedronaugusto/sweep) for git's globs. Conduit carries its libc linkage on POSIX; Windows needs
no C runtime. SHA-256 and the TLS primitives come from `std.crypto`; SHA-1,
inflate and the TLS client are in the package. There is no build option to
forward. Every function that allocates takes the allocator as its first argument and every function that
touches the disk or the network takes a `std.Io`. Concurrent work — reading
objects and deflating entries while a pack is written
(`PackOptions.threads`, one task per processor unless asked otherwise),
resolving a received pack's deltas — goes to the caller's executor, never to
threads of the package's own. A
process starts only through a `repo.program.Programs` the caller hands in; without
one, a hook is not run and a setting that would run a program is a named
refusal. Relic prepares git commands, scrubs the supplied environment and
keeps the caller's launcher and execution policy; conduit spawns, feeds,
collects, waits and kills. `program.run` applies one deadline to input, output,
waiting and cleanup, and refuses unavailable concurrency. Clocks are read
for program deadlines and the HTTP client's certificates and timeouts.
Everything else that needs the time takes it from the caller, with the identity. One word outlives a call without a caller holding
it, and it is the answer to which SHA-1 instructions this processor has,
asked once.

## The API

The root is one module per concern, and each of those holds the modules
that belong to it: `relic.refs` is refs and their transactions, and
`relic.refs.reflog` is the log git writes beside them.

| Path | |
|---|---|
| `repo` | `Repository.open`, `init` (templates and `--shared` included), `templateDir`, `openIndex`, `head`, `headTree`, `writeCommit`, `writeTag`, `peel`, `beginRefs`, `loadIgnore`, `loadAttrs`, `listWorktrees`, `pruneWorktrees`. The front door. |
| `repo.hooks` | git's hooks with git's arguments, environment and input. |
| `repo.program` | `Programs`, `SpawnHook`, `Invocation`, `run` — the one place a process starts. `Programs.spawn` supplies creation and termination using conduit children. |
| `repo.warning` | What git would print as a warning, as a value. |
| `repo.fs` | `Sync`, `OnContention`, `staleReport`, `Resolution`, `Shared`, `ownedByCurrentUser` — the lock, durability and timestamp policies every writer and every stat comparison here goes through. |
| `repo.ident` | `signature` — who an author or committer is, as git's `ident.c` decides: `GIT_AUTHOR_*` and `GIT_COMMITTER_*`, `author.*`, `committer.*`, `user.*`, `EMAIL`, then what the caller says the machine has; under `user.useConfigOnly` a name or email the configuration does not give is refused by name. |
| `repo.safe` | `Ownership`, `directoryIsSafe`, `bareRepositories` — `safe.directory` and `safe.bareRepository` as git applies them to a repository it discovers: another user's repository opens only where the system, global or command-line settings name it, and a bare one is not discovered under `explicit`. |
| `hash` | `Kind` (`sha1`, `sha256`), `Oid`, `Hasher` with `Options` and `nameObject`. The hash is a parameter from the first line, not a width bolted on later. |
| `hash.sha1` | SHA-1 over the processor's own instructions, with the eighty rounds as the fallback and the choice made at run time. |
| `hash.sha1dc` | SHA-1 that checks each block for the signature of a collision attack. Off unless asked for. |
| `object` | `Type`, `Mode`, `Tree` and `Tree.Builder`, `Commit`, `Tag`, `Signature`, `ExtraHeader`. Parsing and writing, with git's tree sort rule and header order. |
| `object.fsck` | What git's `fsck` finds wrong with an object's bytes, every message id at git's level: `Rules` from `fsck.*`, `fetch.fsck.*` and `receive.fsck.*` with skip lists, `forTransfer` for `transfer.fsckObjects` and `fetch.fsckObjects`, and the `.gitmodules` and `.gitattributes` a tree names (`checkBlob`). |
| `odb` | `Odb.open`, `read`, `readInto`, `readHeader`, `exists`, `existsOwn`, `own`, `findPrefix`, `write`, `writeStream`, `listObjects`, `listAlternates`, `addAlternate`, `removeAlternate`, `verify`, `refresh`, `syncBatch`, `placement`, and the `stats` counters. Loose objects, the packs, `objects/info/alternates` and the multi-pack index. Writing packs: `collectReachable`, `collectLoose`, `collectAll`, `writePack`, `packLoose`, `repack`, and `beginPack` / `writeInto` / `finishPack` for a caller filling one as it goes. |
| `odb.Alternates.deinit` | Release a `listAlternates` result after reading its paths. |
| `odb.pack`, `odb.delta` | `Index` (`.idx` v2), `Pack`, `Cache`, `Writer`; `apply` and `encode`. Both delta kinds, the 64-bit offset table, a bounded chain, `verify`, and writing a pack and its index. |
| `odb.indexpack`, `odb.inflate`, `odb.revindex` | Receiving a pack: indexed as it arrives, deltas resolved on the caller's executor, each object checked as `index-pack --strict` checks it under the rules given, `.rev` files. |
| `odb.commitgraph`, `odb.midx`, `odb.bitmap` | Read, verify and encode git's accelerators: full and split commit-graphs, generation v2 and overflow, changed-path Bloom filters v1/v2; MIDX preferred-pack selection, RIDX and BTMP; pack and MIDX bitmaps, EWAH, XORs, hash caches and lookup tables. |
| `odb.accelerators` | `writeCommitGraph`, `writeMidx`, `repackMidx`, `expireMidx`, `writePackBitmap`, `writeMidxBitmap`, `writeConfiguredCommitGraph`, `repackRepository`. The format modules own the bytes; these operations gather through the object database, diff and revision walk. Fetch applies `fetch.writeCommitGraph`; configured maintenance applies `gc.writeCommitGraph` and the bitmap settings. |
| `odb.abbrev` | Short object names as git prints them. |
| `refs` | `Store`, `Ref`, `Resolved`, `Transaction`, `Expected`, `packed-refs` read and write. |
| `refs.reflog` | `append`, `read`, `Log.at` for `HEAD@{n}`, `Policy` for `core.logAllRefUpdates`. |
| `refs.reftable`, `refs.reftablestack` | The reftable ref backend, read and written. |
| `refs.filter` | `Listing`, `listRefs`, `listBranches`, `listTags`, `branchFormat`, `versioncmp` — `git for-each-ref`, `git branch --list` and `git tag --list` byte for byte: every `%(...)` atom git has for refs, `*` peeling, dates in every mode, `align` and `if` blocks, four quoting styles; `--sort` with version sort and `versionsort.suffix`, `--contains`, `--no-contains`, `--merged`, `--no-merged`, `--points-at`, `--exclude`, `--start-after`, `--include-root-refs`, `--count`, `--omit-empty`, `branch.sort`, `tag.sort`. |
| `config` | `Config.open`, `get`, `all`, `getBool`, `getInt`, `getPath`, `subsections`, `origin`, `set`, `unset`, `write`. Lossless: setting a value rewrites one line. `include.path` and `includeIf` with `gitdir:`, `gitdir/i:`, `onbranch:` and `hasconfig:remote.*.url:`. |
| `config.userconfig` | Where the person's git reads its configuration from. |
| `index` | `Index.read` / `write` / `toBytes`, `Entry`, `CacheTree`, `ResolveUndo`, `RawExtension`. Versions 2, 3 and 4. |
| `index.sparseindex` | The sparse index. |
| `worktree.snapshot` | `Store`, `capture`, `adoptTree`, `restore`, `diff`: working trees whose complete Git object closure belongs to a private store. |
| `worktree` | `addAll`, `writeTree`, `checkout`, `resetIndex`, `status`, `list`, `applySparse`. |
| `worktree.worktrees` | `list`, `add`, `remove`, `prune`, `lock`, `unlock`, `move`, `repair`. |
| `worktree.sparse`, `worktree.sparsecheckout` | `Patterns` for `info/sparse-checkout`, and cone-mode sparse checkout as an operation. |
| `worktree.ignore` | `Rules.init` / `loadGlobal` / `addDirectory` / `addText` / `popTo` / `match` / `matchPath`, with the pattern that decided. |
| `worktree.attributes` | `Attrs`, `Attributes`, `unsupported`, `toGit`, `toWorktree`, `isBinaryForDiff`, `isBinaryForCheckIn`. |
| `worktree.filter`, `worktree.convert`, `worktree.encoding` | Clean and smudge filters, the long-running process protocol, `ident`, line endings, `working-tree-encoding`. |
| `worktree.fsmonitor` | `refresh`, `configured`, `ChangeSource`: the file monitor git asks through `core.fsmonitor` (hook protocol 1 and 2), or a program's own, deciding which files `status` looks at; `FSMN` read and written. |
| `worktree.dirscan` | `Scan` — a directory's entries with their stats, from `getattrlistbulk(2)` where the volume has it and a read and a stat per name where it does not. |
| `worktree.safepath` | What a path from a tree is allowed to be, and what a ref may be named. |
| `diff` | `tree`, `numstat`, `blobNumStat`, `unified`, `unifiedBody`, `isBinary`. |
| `diff.textdiff` | `diffLines`, `hunks`, `stat`, `sameLine`, `Algorithm` (`myers`, `histogram`, `patience`), and git's `--minimal`. |
| `diff.rename`, `diff.similarity` | Rename and copy detection with git's score and diffcore's order: `-M`, `-C`, `--find-copies-harder`. |
| `diff.patchid` | Patch ids: a name for what a commit changes. |
| `diff.blame` | `file` — which commit each line of a file comes from, as `git blame` says, following renames. |
| `revwalk` | `count`, `countObjects` (bitmap-backed counts, ordinary walks on a miss), `Walk`, `mergeBase`, `mergeBases`, `mergeBasesWith`, `mergeBasesMany`, `isAncestor`, `isAncestorWith`, `parentsOf` — git's date queue and topological order, commit-graph generation numbers, the shallow boundary, and history simplified by paths (`Walk.paths`) as git simplifies it by default. |
| `revwalk.revparse` | git's revision grammar, `@{<date>}` with git's approximate dates included. |
| `revwalk.shallow` | A shallow repository's boundary: `.git/shallow`. |
| `revwalk.describe` | `describe`, `head`, `Describer`: `git describe` with `--tags`, `--all`, `--long`, `--abbrev`, `--candidates`, `--match`, `--exclude`, `--first-parent`, `--always`, `--dirty`, `--broken`, a blob as `<commit>:<path>`, and `--contains` as `git name-rev` names it. |
| `revwalk.bisect` | `start`, `mark`, `nextStep`, `reset`, `log`, `replay`, `run`, `terms`: `git bisect` as git 2.56 does it, with its state files, its choice of commit, skips, `--first-parent`, `--no-checkout`, `--reset-when-found`, terms and pathspecs. |
| `revwalk.shortlog` | `Shortlog.init`, `add`, `addCommit`, `write`, `configured`: `git shortlog` by author, committer, trailer or format, with `-s`, `-n`, `-e` and `-w`. |
| `revwalk.mailmap` | `Mailmap.load`, `lookup`, `map`: `.mailmap`, `mailmap.blob` and `mailmap.file` read and matched as git reads and matches them. |
| `merge`, `merge.blobmerge` | Content merging as xdiff does it, and the stage-only tree merge. |
| `merge.ort` | `mergeTrees`, `mergeCommits` — git's merge-ort: renames, directory renames, directory/file and type conflicts, submodules, virtual merge bases, git's messages. |
| `merge.octopus` | `mergeCommits` — git's octopus: several heads merged one after another, `read-tree --aggressive` then `merge-one-file`. |
| `merge.strategy`, `merge.subtreeshift` | Every `-X` word git's merge takes, and git's match-trees for `subtree`. |
| `merge.threeway` | A merge of three trees carried into the index and the working tree. |
| `merge.rerere` | Recorded resolutions in git's `rr-cache`: `run`, `status`, `remaining`, `diff`, `forget`, `gc`. |
| `commit` | Making a commit the way `git commit` does, its hooks in git's order. |
| `commit.merging`, `commit.sequencer`, `commit.rebase`, `commit.todo` | Merge, cherry-pick, revert and rebase, with their state files in git's format. |
| `commit.message`, `commit.head`, `commit.reset`, `commit.commithooks` | What those commands share: messages as git shapes them, `HEAD` as git moves it, `git reset`, the hooks around the commits they make. |
| `commit.trailer` | `process`, `processFile`, `format`, `iterate`, `amend`, `Settings.load` — `git interpret-trailers` byte for byte: the trailer block found as git finds it, `--trailer` added by `--where`, `--if-exists` and `--if-missing`, `--trim-empty`, `--only-trailers`, `--only-input`, `--unfold`, `--parse`, `--no-divider`, `--in-place`; `trailer.separators`, `.where`, `.ifExists`, `.ifMissing` and every `trailer.<name>.key`, `.command` and `.cmd`. `%(trailers)` and `git commit --trailer` go through it. |
| `commit.stash` | `push`, `apply`, `pop`, `list`, `show`, `drop`, `clear`. |
| `commit.notes` | `Notes`, `add`, `append`, `copy`, `remove`, `prune`, `show`, `merge`, `mergeCommit`, `mergeAbort`, `formatNote`: `refs/notes/*` read and written as `git notes` does, git's fanout and every merge strategy included. |
| `commit.signing` | Sign and verify commits and tags: OpenPGP, SSH, X.509. |
| `transport` | `Session`: a remote, open — the one thing a fetch, a clone or a push talks to. |
| `transport.fetch`, `transport.clone`, `transport.push` | The commands. Protocol v2 and v0, refspecs, `FETCH_HEAD`, atomic updates, `insteadOf`. |
| `transport.remote`, `transport.url`, `transport.refspec` | Remotes as the configuration describes them, what a URL names, and which refs a fetch takes. |
| `transport.smarthttp`, `transport.ssh`, `transport.local`, `transport.httpclient`, `transport.tls`, `transport.clientcert` | The transports: HTTP(S) through relic's own HTTP/1.1 and TLS clients, HTTP(S) and SOCKS4/4a/5/5h proxies, the person's `ssh`, and `file://` and paths. |
| `transport.credential`, `transport.auth`, `transport.httpsettings`, `transport.httpauth` | The person's own setup: credential helpers, why a remote refused, git's `http.*`, proxy authentication. |
| `transport.protocol`, `transport.connection`, `transport.pktline`, `transport.sideband`, `transport.fetchpack`, `transport.sendpack`, `transport.progress` | The wire underneath the commands. |
| `transport.remotehelper` | `Helper`, `Spec`, `allowed` — `git-remote-<name>` run as git runs it: capabilities, options, `list`, `connect`, `fetch`, `import` (through `fastimport`, `bidi-import` answered), `push`, `export` (through `fastexport`, with the helper's marks), private refs by its `refspec`. |
| `transport.uploadpack` | `Server` — serving fetches, with shallow and every filter. |
| `transport.hidden` | `HiddenRefs` — `transfer.hideRefs`, `uploadpack.hideRefs` and `receive.hideRefs` as git's `ref_is_hidden` reads them: what a served repository does not advertise, what a want may name, what a push may not touch. |
| `transport.promisors` | `advertisement`, `reply`, `autoFilter` — the protocol v2 `promisor-remote` capability: `promisor.advertise` and `sendFields` on a server, `promisor.acceptFromServer`, `checkFields` and `storeFields` on a client, and the filter `auto`. |
| `transport.bundle` | `create`, `write`, `File.open`, `Header.read`, `listHeads`, `writeSummary`, `verify`, `unbundle`, `isBundle`: `git bundle` v2 and v3, its header byte for byte, filtered by any filter git takes, `sparse:oid=` included; a path to a bundle is fetched and cloned from. |
| `transport.objectwalk`, `transport.objectfilter`, `transport.partial`, `transport.filterspec` | Which objects one side lacks; partial clone, its filters and the lazy fetch. |
| `submodule`, `submodule.gitmodules`, `submodule.gitlink`, `submodule.submoduletransport` | `.gitmodules`, status, init, update, sync, absorbed git directories, and fetching them. |
| `lfs` | LFS without git-lfs: pointers and the store. |
| `lfs.lfsapi`, `lfs.lfstransfer`, `lfs.lfsssh`, `lfs.lfslocks`, `lfs.lfspush`, `lfs.lfshooks`, `lfs.lfscustom` | The batch API over https or ssh, locks, pre-push, git-lfs's hooks, custom transfer adapters (`lfs.customtransfer.*`, standalone or chosen by the batch answer). |
| `lfs.netrc` | What the LFS client reads beside: `~/.netrc`. |
| `patch` | `parse`, `Patch`, `FilePatch`, `Fragment`: git patches and plain unified diffs read as `git apply` reads them, from whatever surrounds them. |
| `patch.apply` | `apply` — `git apply` to the working tree, the index or both: renames, copies, modes, binary hunks, `-R`, `--3way`, `--reject`, `--check`, whitespace checked or fixed, nothing written unless every file applies. |
| `patch.format` | `format` — `git format-patch` byte for byte: numbering, the diffstat, binary hunks, a cover letter, base information, threading and attachments. |
| `patch.rangediff` | `write`, `compute` — `git range-diff` byte for byte: two series' patches as git reads them out of `git log -p`, paired by git's own solver, and the diff of each pair; `--creation-factor`, `--left-only`, `--right-only`, `--no-notes`, `--no-patch`. |
| `patch.mail` | `split`, `info` — `git mailsplit` and `git mailinfo`. |
| `patch.am` | `start`, `proceed`, `skip`, `abort`, `quit` — `git am` with `--3way`, its state in `rebase-apply` as git keeps it. |
| `grep` | `grep` — `git grep` over the working tree, the index or a tree: fixed, basic and extended patterns with back-references, `--and`/`--or`/`--not` and `--all-match`, `-i -w -v -n -l -c`, context, `-p` and `-W` with git's `diff` driver function lines, pathspecs, binary files, written as git writes it; `-P` through the caller's `Matcher`. |
| `archive` | `archive` — `git archive` as tar or zip, git's bytes: the pax comment, `--prefix`, `export-ignore`, `export-subst`, `tar.umask`. |
| `pretty` | `formatCommit`, `Context`, `Decorations` — git's `--format` placeholders for one commit, the mailmap's names, decorations, notes, signatures and `%(trailers)` with every option among them. |
| `clean` | `clean` — `git clean`: `-n`, `-f`, `-ff`, `-d`, `-x`, `-X`, `-e`, pathspecs, repositories inside the tree left alone, git's lines. |
| `fastimport` | `import`, `Marks` — `git fast-import`: every command, its dates, marks files and notes fanout, branches updated as git updates them. |
| `fastexport` | `write` — `git fast-export` byte for byte: marks, renames, tags, signatures, refspecs. |

Every public declaration carries a doc comment stating its contract, and every
operation has one named error set. A refusal is a named error. For a refused
repository format or extension,
pass a caller-owned `repo.Diagnostic` in `Repository.OpenOptions.diagnostic`:
its `unsupported_setting` survives a failed open, and `deinit` releases its copy.
Pass the same output to `refreshConfig`, `writeCommit`, `writeTag` or
`writeTagWith`, or pass `null` when the setting is not needed. Each call clears
it; the repository never retains it. `OpenDiagnostic` is an alias for `Diagnostic`.
A refresh that changes the hash or ref backend requires reopening and returns
`ObjectFormatChanged` or `RefStorageChanged`, keeping the old configuration and store.

A ref transaction acquires and validates every loose-ref lock before it writes
any ref. Its commit is the same sequence of per-ref renames and reflog appends
that git's files backend performs, not one filesystem transaction: an I/O
error after commit starts may leave a prefix installed, and the caller must
reread the affected refs before retrying.

## Design

**What is written is what git reads.** The index's bytes, a tree's entry
order, a commit's header order, a ref file's trailing newline,
`packed-refs`' header space. The suite proves it in both directions: an index
git wrote is read and written back byte for byte, and a tree this writes is
the tree `git write-tree` writes over the same files. One stated exception is
that a loose object's *compressed* bytes need not match git's — an object's
name is the hash of its uncompressed content and git never compares the
compressed form. Objects are deflated at level 1, which is what
`core.looseCompression` defaults to.

**Line endings decide a blob's name.** `text`, `text=auto`, `eol` and
`core.autocrlf` decide whether a blob is stored with its carriage returns
removed, and therefore decide its name and the name of every tree above it.
Two different rules call a file binary and both are here: a NUL in the first
8000 bytes decides whether a *diff* is printed, and a lone carriage return, a
NUL, or more than one non-printable byte per 128 printable ones decides
whether a file is *normalised on check-in*. The second is the one conversion
asks. A `filter` runs the program its configuration names, through the
caller's `Programs`; without them, a required filter is a named refusal
carrying its name. `working-tree-encoding` converts UTF-16 and UTF-32 files
to UTF-8 on the way in and back on the way out, with git's byte order mark
rules; another character set is refused by name.

**Every replacement goes through the file git would lock.**
`O_CREAT|O_EXCL` on `<file>.lock`, write, make durable, rename. No advisory
lock is taken, because git takes none and a lock that is not git's lock does
not stop it, and a reader never blocks: it sees either the whole old file or
the whole new one. A lock another writer holds is `error.LockHeld` and is left
exactly where it was found. `repo.fs.staleReport` says whether it is held, which
process id is in `<file>~pid.lock`, and whether that process still exists —
process ids are reused, so that is a report for a person and not permission to
remove anything. `repo.fs.OnContention` chooses between failing at once and waiting
with git's own backoff.

**A lookup narrows before it searches.** A repository with many packs has one
binary search per pack on every lookup unless something narrows it, and
`pack/multi-pack-index` is what git writes to narrow it. It is read at open
and consulted first: it says which pack holds the object, and that pack's own
index is still what gives the offset. Doing it the other way round would turn
a stale index into a read at a wrong offset rather than a miss. An index that
does not parse, or that names a pack this database has not opened, is a miss
and the packs are asked in turn; `Odb.stats` counts both, so a caller can see
which happened. On a miss the object database re-scans the pack directory once
and tries again, because a `git gc` may have packed the object away between
the two.

**Durability is a policy with three values, and the default is git's own.**
`repo.fs.Sync.none` makes neither a loose object nor the index durable before
returning, which is what `core.fsync` defaults to. `batch` flushes each file
and puts one real barrier at the end — a throwaway file in the same directory,
synced and removed — which is full durability at one sync per batch rather
than one per object. `per_file` syncs each one. Under the latter two a lock's
own descriptor is synced before the rename, which is the step that prevents an
empty ref or a truncated index. Directory entries are not made durable unless
asked: git does not do it either, and the guarantee it adds is one git does
not make. On macOS `fsync(2)` reaches the device and not the drive's own
cache, so `F_FULLFSYNC` is the real barrier. Waiting for the drive's cache
adds a storage barrier, which is why ordinary object writes can put it at
the end of a batch.

**Every path from a tree is checked before it is written.** A tree entry's
name is written by whoever wrote the tree and becomes a filesystem path on
checkout. Refused everywhere: `.` and `..`; `.git` in any case and in every
spelling NTFS or HFS+ opens as it, `git~1` and `.git::$DATA` among them; a
link named `.gitmodules`; an entry standing where another entry of the tree
has its directory; and any write, removal or new directory past a symbolic
link on the disk. Refused on Windows, as git refuses them there: DOS device
names such as `aux.c`, a component ending in a dot or a space, a colon, a
backslash inside a name and a drive letter; elsewhere these are names like
any other, and the Linux kernel's tree checks out. A ref name ending in
`.lock` is refused too, since that is the name of the file that blocks every
update to the ref without it.

**A remote that works from the person's terminal works from here.** relic
reads the configuration their git reads — the system file their git was built
with, the XDG file, `~/.gitconfig`, the `GIT_CONFIG_*` variables — runs their
`ssh` with their `~/.ssh/config`, and asks their credential helpers, the ones
`gh`, the keychain or a credential manager installed, byte for byte as git
asks them. It stores no secret of its own and asks the person nothing unless
the caller passes a prompt. When a remote refuses, the caller gets values
rather than a sentence — which helpers were asked and what they said, what
the server or ssh said — so it can tell the person what to fix.

`transport.url.Url.parse` gives the scheme, user, host, port and path as
slices of the supplied text. Bracketed IPv6 and ports work in scp syntax as
well as `ssh://`; an at-sign in a repository path stays in the path.
`file://` and local paths name local repositories. `<helper>::<address>`,
a `<scheme>://` URL for a scheme relic does not speak and `remote.<name>.vcs`
name a remote helper: `Url.parse` refuses them as `UnsupportedTransport`,
`url.helperOf` names the helper, and a `Session` runs `git-remote-<name>`
from `PATH` as git runs it, `protocol.<name>.allow` deciding whether it may.
Callers decide which schemes and default ports name the same remote; they do
not need to split the URL themselves.
`transport.url.Identity.parse(gpa, text)` owns the raw text and decoded
SSH/file URL fields under `identity.url`; release them with `deinit`.
Decoding precedes splitting, including home paths and encoded delimiters.
Scp shorthand and plain paths keep percent signs literal, HTTP keeps its
encoded request path, and `identity.url.raw` always retains the original.

**TLS, HTTP and inflate are relic's own, each for something the standard
library cannot do.** Every https connection goes through relic's TLS and HTTP
clients; a test fails if any other file names the standard library's HTTP or
TLS client, and another checks that what crosses a proxy's tunnel is TLS.

- **TLS** is the standard library's client with client authentication added.
  std's client runs the whole handshake inside `init`, takes no client
  certificate, and refuses a server's CertificateRequest, so nothing outside
  it could add one: the answer has to be written into the handshake.
  `src/transport/tls/Client.zig` is therefore a copy of Zig 0.17.0's file, and
  `src/transport/tls/Client.zig.diff` is everything the copy adds — the two options,
  the CertificateRequest arm, the client's Certificate and CertificateVerify
  for TLS 1.2 and 1.3 — with the code they call in `src/transport/tls/auth_wire.zig`.
  The copy is held to std on every `zig build test`: the std file the
  compiler ships is hashed against the one the diff was taken from, and the
  diff applied to it must give the copy byte for byte. A Zig release that
  changes std's client fails the build until its fixes are brought across;
  the header of `src/transport/tls/Client.zig` says how, and `zig build tls-fork` takes the
  diff again.
- **HTTP/1.1** is relic's because std's client builds its TLS inside a
  private connect path: verification cannot be turned off for
  `http.sslVerify=false`, there is one trust store where git has
  `http.sslCAInfo`, `http.sslCAPath` and a proxy's own `http.proxySSLCAInfo`,
  there is no client certificate for `http.sslCert`, and a CONNECT tunnel
  carries no TLS of its own, so an https remote behind an http proxy would
  be spoken to in the clear. It answers a proxy only with Basic
  authentication from the URL, where git's curl answers a 407 with Basic or
  Digest, and it applies no connect, handshake or activity timeout, which
  git-lfs's settings need. Heads, chunked bodies and compression are read
  with std's `http.Reader`.
- **inflate** is relic's because std's zlib decoder reads the Adler-32 at the
  end of a stream and does not check it, so a corrupt object would be taken
  as it came; relic's checks it and refuses what zlib refuses. It decodes a
  pack entry into one buffer of known size and is fuzzed against std's
  decoder and compressor.

HTTP(S) remotes and LFS accept `socks4://`, `socks4a://`, `socks5://` and
`socks5h://` proxies, with port 1080 when none is given. SOCKS4 and SOCKS5
resolve the origin locally; SOCKS4a and SOCKS5h send its name to the proxy.
A URL's `user:password@` supplies SOCKS5 authentication, or the userid for
SOCKS4. HTTPS starts TLS to the origin inside the SOCKS tunnel. A named
remote's `remote.<name>.proxy` overrides `http.proxy`; `no_proxy` still applies.
A fetch, clone or push given a `proxy` (`transport.Proxy`) goes through that
one, or none, whatever these say.

The HTTP client's `connect`, `send` and `stream` take an optional caller-owned
`transport.httpclient.Diagnostic` as their last argument. Initialize it with
`Diagnostic.init(allocator)` and release it with `deinit`. Each exchange clears
its diagnostic before starting. Keep it alive through connection release,
response cleanup, streaming abort or a failed finish; separate simultaneous
exchanges use separate diagnostics. Its TLS error, proxy status and owned
offered schemes remain available after a failed exchange, even after the
client is closed.

A streaming request ends with `finish` or `abort`. `finish` consumes the stream
on every outcome: the response owns the connection on success, and failure
closes it. Abort only when giving up before finish.

**A merge is git's merge-ort.** Renames, directory renames, directory/file and
type conflicts, submodules and criss-cross histories resolve as git resolves
them, with git's conflict messages, and a stopped merge, cherry-pick or rebase
leaves git's state files, so either tool continues the other's. Thousands of
random histories are merged by both and compared tree, stages and messages;
where git's own merge-ort stops on an assertion, relic stops with a named
error at the same place.

**LFS needs no git-lfs.** Pointers are cleaned on add and smudged on checkout
in process; the server is found where git-lfs looks for it and asked the way
git-lfs asks it, over https or git-lfs's pure-ssh protocol; the last lock
listing is kept where git-lfs keeps it, in its JSON, so either tool shows the
other's locks offline. A repository carrying git-lfs's own hooks works on a
machine without git-lfs.

**The hash is the floor under a repository whose files have size.** Both
architectures carry SHA-1 instructions, and this package uses them: aarch64's
`sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0` and `sha1su1`, x86-64's
`sha1rnds4`, `sha1nexte`, `sha1msg1` and `sha1msg2`. Which arm runs is decided
by asking the processor and not by what the compiler was told, so a binary
built for a baseline target — which is what anything distributed is built for
— uses the instructions on a machine that has them. The target does not take
that choice away either: the aarch64 assembly asks for the extension itself
and the x86-64 assembler does not gate these. One thing does take it away.
Both arms are assembly, and the self-hosted x86-64 code generator has no
encoding for these instructions, so a build that uses it — a Debug x86-64
build, in practice — takes the software rounds. The x86-64 arm is checked against the software rounds under emulation,
on every length to eight kilobytes.

Performance measurements live in the `bench` branch harness and run on a
quiet machine. The unit suite counts objects written, fan-out directories,
hashed files, cache-tree work, packed reads and bytes; it compares hashes,
staged trees and pack sizes without clock ratios or speed limits.

An entry whose recorded stat still matches is neither opened nor hashed, and
a valid cache-tree node is used as it stands. A staging pass can put its new
blobs into one pack instead of separate loose objects. Another reader sees
that pack only after the pass finishes; `Odb.repack` can deltify it afterwards.

**A pack is written in git's order, and nothing is taken away until it is
there.** `odb.pack.Writer` streams the entries into a temporary and writes the
index beside it; what is held is one object, the deflate state, and one index
entry per object. `Odb.writePack` is the policy on top: the objects are
ordered by type descending, then by git's own hash of the tail of the path
they were found at, descending, then by size descending, and each is tried
against a sliding window of the ones already written — ten of them, a chain no
deeper than fifty, and a delta kept only if it is at most half the object it
stands in for. `PackOptions.window_bytes` bounds that window by weight as well
as by count, so a few large objects cannot become the high-water mark, and an
object past `big_file_bytes` is written whole and never enters it.
Small delta bases use a 16 KiB hash table and matches compare whole words;
loose pack inputs are read through a 16 KiB buffer.
Starting an entry compressor copies its defined state, leaving token and chain
bytes to be filled before use instead of copying their unused storage.

The writing is spread over tasks of the caller's `std.Io` (`Io.Group.async`),
one per processor by default. They read the loose objects, inflate the whole
objects of packs and deflate the entries, batch by batch, into buffers the
calling task sized and allocated beforehand, so those allocate nothing. They
search for deltas too: the objects in pack order are cut into groups of at
least 512, each ending where the path hint changes, and an object is tried
only against the window of its own group. The groups depend on the objects
alone, so every task count, and every Io, writes the serial writer's bytes.
git cuts one segment per thread and moves the cuts as threads steal work, so
its deltas change with `pack.threads`; the groups here cost 0.04% of the pack
on a repack of ghostty against one window over everything. A searching task
allocates its delta indexes through the database's allocator one call at a
time, under a lock, so that allocator need not be thread-safe. The deltas
packs hold and the writing stay on the calling task, in pack order. While the
tasks search one batch, they read the next and deflate the one before.
Objects that come from packs are written as their packs store them, as git's
pack-objects reuses them (`PackOptions.reuse_packed`): a delta whose base is
written before it, with its chain of such deltas within `depth`, is copied
without being read, searched or deflated, and an object written whole is
copied rather than deflated again. Each copy is checked against the CRC its
pack's index gives, and an object a reused chain rests on is searched only for
deltas shallow enough to keep that chain within `depth`. Which deltas are
reused depends on the objects and their packs alone, so every task count
still writes the same pack.
`PackOptions.batch_bytes` bounds what the three batches hold ahead of the
writer. At most six tasks read loose files at once: beyond a few, opening
files contends in the kernel. An Io that cannot run a task in parallel runs it
inline, and `threads = 1` is the serial writer with no tasks at all.
`collectLoose` and `collectAll` read the headers and the loose trees on tasks
too, and hand the headers to `writePack`, which then reads every loose object
once and an object `collectAll` found in a pack from the pack.

The order the two files become visible in is not free to choose. A reader
finds a pack by its `.idx`, so the pack is renamed into place first and the
index second, which is git's order too. `Odb.packLoose` and `Odb.repack`
extend that to the objects they replace: the pack is written and made durable,
the index likewise, the database re-scans so it can read the new pack itself,
and only then are the loose files removed — and only the ones the new index is
asked about and confirms. At no point is an object in neither place, and a
reader that listed the packs before all this and looks for a loose object
after it finds the pack on its second look, because a miss re-scans once
before it is a miss.

Removing the packs a repack replaces is off by default: a pack a second
process has open can be removed on one platform and not on another, and
nothing here can tell whether one has. A repack of the same objects with the
same settings writes the same bytes, so it has the same checksum and the same
name — the new pack *is* the old one, and that is the one name the removal
pass skips.

**Packs are read with positional reads by default.**
A read is one 8 KiB block, aligned in the file, and each pack keeps up to
32 MiB of them, never more than its own size, each allocated when first read
(`Odb.Options.pack_read_cache_bytes`), block `b` only ever in slot `b`
modulo their count. A pack that fits is read at most once, whatever order its
objects are read in, as a map would read it. An entry of 64 KiB or more streams through a 64 KiB buffer
of its own instead. Where a read lands therefore depends only on what is
wanted, never on the reads before it, and a pass whose delta-base cache holds
at least what an earlier pass's held reads no more calls and no more bytes
than it did. I/O failures are still returned to the caller.
An inflate uses at most 266 bytes of temporary slack for its fast loop, then
returns an owned result of the exact checked size.
`Odb.Options.map_packs` asks for a memory map instead, which is faster on a
cold cache and costs two things: on macOS a pack replaced underneath a mapping
is a signal rather than an error value, and on Windows a live mapping stops
the `gc` that wants to replace the file.

**Collision detection is off, and there are three things to know before
turning it on.** A SHA-1 collision is public and buildable, so two different
objects can be made to carry one name.
`Odb.Options.detect_sha1_collisions`, which `Repository.open` and
`Repository.init` both forward, turns on the check the counter-cryptanalysis
paper describes: the identical-prefix attacks all follow one of thirty-two
known disturbance vectors, and a block that could have come from such a pair
is recognisable from the block alone. Per block it is a few dozen masked
comparisons that reject nearly everything; a block that survives them has its
sibling message reconstructed and the compression function re-run from the
step the vector is anchored at. The method needs the expanded message and
the intermediate states, which the processor's SHA-1 instructions do not
hand back. It reports rather than
repairs: `error.CollisionAttack`, with nothing written, in place of a quietly
different name. And what it guards is git's object format rather than a file
on the disk — the published colliding documents are not colliding *objects*,
because `"blob <size>\0"` goes in front of the content and moves every block
of the message, so git stores both of them today under two names. The
disturbance-vector table and the bit conditions are transcribed from the
reference implementation, and the transcription is checked two ways: the
published colliding pair is detected, both halves, and no object in any
fixture repository is.

**Each public operation runs on an arena fed from the caller's allocator**, so
the peak is bounded by the operation and the free is one call. What outlives
an operation is held by the object database: the pack indexes, read whole at
open so a lookup costs no syscall; the multi-pack index, when there is one,
for the same reason; the delta base cache, keyed by pack offset and kept in
least-recently-used order under a byte budget named in `Odb.Options`; the
blocks positional pack reads keep, up to 32 MiB or the pack's size for each
pack read, as they are read, under `Odb.Options.pack_read_cache_bytes`; one
deflate window, which is sixty-four kilobytes and is taken at `open` whether or
not anything is written; and, once a database has written anything, one
deflate state and one
output buffer, the state being two hundred and twenty-four kilobytes, because
a cold `addAll` writes one object per file. A database that is only read takes
neither of those two. Writing a pack adds
the delta window on top, which `PackOptions.window_bytes` bounds by weight as
well as by count, its per-base delta indexes, and one index entry per object — a name, an offset and a
CRC — which has to be sorted before it is written; written on several tasks,
three batches within `PackOptions.batch_bytes` and a deflate state for each
task, and a decoder and a read buffer for each when objects come from packs. There is no object cache; a returned slice's
doc comment says who owns it.

**The index is read and written at three versions.** Versions 2, 3 and
4 are read; version 2 or 3 is written, 3 only when an entry needs an extended
flag, and 4 on request. The `TREE` and `REUC` extensions are understood. An
extension whose signature begins with an upper-case letter is optional and is
kept byte for byte and written back; a lower-case one is mandatory and is
either understood or a named refusal, because quietly dissolving one loses
entries. `link` — the split index — is understood: both of its bitmaps are
decoded and the shared file is merged, so nothing is invisible, and what is
written back is one complete index rather than a split one, which git
re-splits on its next write if `core.splitIndex` is still set. `EOIE` and
`IEOT` are caches of byte offsets into the very file being rewritten, so what
is copied is nothing and what is kept is that they were there: the offsets are
taken again from the file being written. An index that carried them gets them
back, one that did not gets neither — which is what stock git writes, since it
writes them only when `index.threads` asks for a reader that can use them.
`WriteOptions` says so outright for a caller writing for a particular reader.
git's racy rule is implemented: an entry whose modification time is not older
than the index file's own is content-checked rather than trusted, and a
racily-clean entry's recorded size is written as zero so the mismatch survives
into the next index. How much of a modification time means anything is
measured rather than assumed — a file written into the directory, stat'd three
times, and the largest round unit every reported time is a multiple of is the
answer — because a filesystem that keeps whole seconds and one that keeps
nanoseconds need opposite answers here, and guessing either way is a bug.
`dev`, `uid` and `gid` come from the platform where it reports them — writing
zeros there is what makes the next `git status` treat every entry as needing a
refresh and re-hash the whole working tree.

Reachability bitmaps are opened on first use and kept until `Odb.refresh`.
`objectwalk.missing` uses their wanted-minus-hidden object set for unfiltered,
non-shallow requests, including upload-pack's enumeration; their name hashes
remain delta hints. `revwalk.count` intersects that set with the commit type
map. `Odb.stats.bitmap_hits` records the requests answered this way.
`Odb.Options.use_bitmaps = false` makes the same requests walk objects instead.
A commit outside the selected bitmap entries, a filter or a shallow boundary
uses the ordinary walk. Pack bitmap writing requires a closed DAG and refuses
`BitmapNotClosed`; commit-graph writing refuses shallow input and cycles.

## Scope

- **No pseudo-merge bitmap extension or incremental MIDX chains.** `UnsupportedBitmapOptions` and `ChainUnsupported` name these; ordinary pack and MIDX bitmaps are read and written. An unusable optional accelerator falls back to the object walk.
- **`working-tree-encoding` for UTF-16 and UTF-32 only.** Any other character set is refused by name.
- **No Negotiate or NTLM** authentication, to a server or a proxy; refused by name. **No GSS-API (Kerberos) to a SOCKS5 proxy:** it is never offered, so a proxy that takes nothing else refuses every method and the fetch stops with `ProxyAuthenticationRequired`.
- **LFS without tus.** The tus adapter is refused by name; custom transfer adapters run as git-lfs runs them.
- **No receive-pack server.** relic serves fetches; a push goes to git's server. `receive.fsckObjects` and `receive.fsck.*` are read (`fsck.Scope.receive`) for a program that receives pushes itself.
- **A promisor fetch's pack takes every `.gitmodules` and `.gitattributes` it lacks as promised,** where git asks whether a promisor pack names the blob. With nothing configured, a fetch still checks what it receives, at git's levels with `.`, `..` and `.git` in a tree refused (`fsck.baseline`), where git checks nothing; `fetch.fsckObjects=false` checks nothing.
- **No `git://` or dumb HTTP.** Refused by name. A remote helper is spoken to through `connect`, `fetch`, `import`, `push` and `export`; one with only `stateless-connect` or `get` cannot fetch here, `HelperCannotFetch`.
- **No editor for a note.** Refused by name.
- **`apply` with the index compares content where a stat differs.** git says "does not match index" until the index is refreshed; this reads the file and agrees when its content does.
- **A binary hunk in a written patch is this package's deflate.** It decodes to the same file; the compressed bytes are not zlib's. A cover letter's shortlog under a mailmap is refused by name.
- **`am` reads mailboxes only.** StGit and Mercurial patches are refused by name, as is a mail in a character set other than UTF-8, US-ASCII or ISO-8859-1.
- **`grep -P` only through a caller's matcher.** Without one, Perl expressions are refused by name; back-references follow glibc's matcher, which git uses on Linux and builds in for Windows, where macOS's differs.
- **A deflated zip entry is this package's deflate,** decoding to the same file; a stored zip and every tar are git's bytes. `export-subst` leaves `%N` as it stands, as git does, and refuses `%(describe)`, relative and human dates, wrapping, padding and colour by name.
- **No interactive `clean`.**
- **A hunk's function line by git's default rule.** In `patch.format` and `patch.rangediff` a `diff` driver's `funcname` does not reach the `@@` line, and in `patch.rangediff` its `textconv` does not reach the patch.
- **`range-diff` over commits that are not merges, without colour.** `--diff-merges`, `--remerge-diff` and dual colour are not offered; the notes compared are `core.notesRef`'s (or `refs/notes/commits`), not `--notes=<ref>` or `notes.displayRef`, and no `git log` arguments follow the ranges.
- **Ref listings write no colour.** A `%(color:...)` git accepts writes nothing, as git's does when it is not writing to a terminal, and `--column` is not offered.
- **`info/` is made by `init` with or without a template,** where git makes it only from one. A template's configuration keeps the spelling of a key `init` sets again, where git writes its own.
- **A root process is root.** git takes a repository owned by the user `sudo` ran it for (`SUDO_UID`) as the current user's; this package reads no environment, so `OpenOptions.ownership` is where a caller says otherwise.
- **No fsmonitor daemon.** `core.fsmonitor=true`, git's built-in daemon, is `error.FsmonitorDaemonUnsupported`; a hook and a program's own change source are asked as git asks the hook.
- **fast-import does not check signatures, and fast-export does not anonymize.** git's `--signed-commits=*-if-invalid`, `rewrite-submodules-*` and `export-pack-edges` are refused by name; fast-export takes no path limit and no `--reencode=yes`.

## Ahead

Planned, in the order they are likely to come; none is promised for a date.

- **Loose object reads through relic's own inflate.** Packed object reads
  and received packs already use it; loose reads still use the standard library.
- **`-s subtree`** as a strategy name, beside the `-X subtree` forms.

## Platforms

| Platform | What it uses there | Tested |
|---|---|---|
| Linux | The executable bit, symlinks, and one `statx` per entry for the index's `dev`, `uid` and `gid` alongside everything `std.Io` reports | `ubuntu-latest` in CI, Debug, ReleaseSafe and ReleaseFast |
| macOS | The same through `fstatat`, and `getattrlistbulk(2)` for a whole directory at once where the volume has it, which the walk falls back from on `ENOTSUP`; `fsync` is writeout-only, which is git's own default here | `macos-latest` in CI, Debug and ReleaseSafe |
| Windows | No executable bit and no `dev`, `uid` or `gid`, so the index's mode is preserved rather than invented and those three are zero; symlinks may be refused, in which case the link target is written as file content and the outcome says so; renames retry on a sharing violation | `windows-latest` in CI, Debug and ReleaseSafe |

Paths in trees and in the index are always `/`-separated byte strings; the
working-tree layer converts. `core.ignoreCase` is honoured in matching, and a
tree carrying two entries that differ only in case, or one whose name folds to
another's directory, is refused on a filesystem that folds case rather than
having one written over or through the other.

`zig build check -Dtarget=…` compiles everything, tests included, without
running it, and CI does that for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`.

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap through preflight; run `zig build cache` before direct Zig builds (only a rebuild is lost).

```sh
zig build test --test-timeout 60s   # the suite, and the examples, which are run
zig build test -Dtest-filter=hooks --test-timeout 60s   # run matching tests while developing
zig build examples      # the examples on their own
zig build check         # compile everything, including the tests, run nothing
zig build check-imports # named source layers and dependency owners
zig build test --fuzz   # the fuzz tests, until stopped
zig build docs -- usage --check   # the Usage block against the example
zig build tls-fork --check       # the TLS client's recorded diff against std's
```

Every test runs under `std.testing.allocator` and `std.testing.io`, against
real directories. CI runs in tiers. Every push runs the source checks and the
Debug suite on Linux, and compiles every other target; the run that lands a
change on main adds the Debug suite on macOS and Windows; a release adds
ReleaseSafe on all three platforms, ReleaseFast on Linux, ReleaseSmall as a
compile check, and ThreadSanitizer on Linux. Each parity corpus seed has its
own named test, and the hosted jobs split the suite test by test, balanced by
the durations the last run recorded. A test that stalls is reported by name.
The package's own benchmarks are in `bench/`: `zig build bench` builds them,
and [bench/README.md](bench/README.md) says how to run them. CI only compiles
them.

**The fixtures are generated by the git on the machine at test time**, in a
temporary directory, and compared byte for byte where the format is exact.
Because they come from git and not from a file in this repository, a format
change arrives as a red build rather than as a silent divergence, and
CI runs the suite against the oldest supported git (Debian 12's 2.39.5) and
against git's own main branch as well as against the runner's. A machine
with no git skips those tests instead of failing them. What is compared:
an index at each version read and written
back; a repacked repository walked against `cat-file --batch-all-objects`,
once with offset deltas, once with reference deltas, and once under SHA-256;
`addAll` and `writeTree` against `add -A` and `write-tree`, including under
`core.autocrlf` with `* text=auto`; `status` against `status --porcelain`;
`list` against `ls-files`; name-status, numstat and the unified patch against
`diff-tree` and `diff`, with the `@@` header checked at four context widths;
`worktree list` before and after an add, a lock, a prune and a remove;
clone, fetch and push against `git http-backend`, git's own ssh transport
through a stand-in, and relic's upload-pack, with refs, reflogs,
`.git/shallow` and `.promisor` files compared; merges, cherry-picks, rebases
and rerere against the git that made the fixture, state files and reflogs
included; `for-each-ref`, `branch` and `tag` listings under every atom, sort key and filter; `interpret-trailers` under every option and `trailer.*` rule, and `%(trailers)` in `log` and `for-each-ref`; `describe` (with `--contains`), `shortlog` and `check-mailmap`
under each of their options; notes added, appended, copied, removed and
merged under every strategy, commit for commit, fanout included; a bundle's
header byte for byte and what git unbundles from it, and git's bundles read
and fetched from; a bisection step by step, its state files, refs, logs and
checkouts, through skips, `--first-parent`, pathspecs, replay and `run`; LFS transfers and locks against git-lfs on a local server; a pack
this wrote against `git verify-pack -v` and `git index-pack --verify`, with
and without deltas and with either delta kind; the reachable object set
against `git rev-list --objects --all`; a repository whose loose objects have
all moved into a pack read back object for object; and `git fsck` silent about
everything written.

**The suite is a guest on the machine it runs on.** Every process it starts
— git, git-lfs, gpg, gpgsm, ssh-keygen, OpenSSL, the suite's own helpers —
runs with the system's git configuration off (`GIT_CONFIG_NOSYSTEM`), a
scratch `HOME` holding the only global configuration it reads, a scratch
`GNUPGHOME` where gpg is involved, no ssh or gpg agent of the person's, and no
prompt. gpg's daemons for a scratch home are stopped with it. GnuPG homes
are under `.zig-cache/gpg` by default. From a long checkout, pass
`-Dgnupg-fixture-root=/short/path` to give the agent's Unix sockets a short
root; only the random private homes beneath that root are removed.
The tests that
exercise the person's credential helpers point git at stand-ins, and check
each one answers as a stand-in before anything is asked of it, so no test
reaches a real keychain.

Concurrency is tested rather than hoped for. A second process takes
`index.lock` exactly as a running git does; the same test shows git refusing
that lock, and this refusing it by name and leaving it alone. A stale lock is
reported with its process id and never removed. A `gc` packs the objects under
a reader's feet and every one of them still reads back.

git's published security fixes are a regression suite: each of the 49 that apply to relic is a test in `src/testing/security/`, one file per kind of hole, named for its CVE and the git test it mirrors.

Seventy-eight fuzz tests. Most of them take arbitrary bytes and hold a parser to
one rule — any input either parses to a value or returns a named error — and
between them they cover every format relic reads: the object formats, packs
and their indexes, the index file, refs, reftable and reflogs, config and
attributes, the accelerators, packet lines and the wire
protocol's answers, credential helper answers, filter specs, LFS batch and
lock answers, TLS handshake messages and private keys, the merge state
files, mailmaps, bundle headers, notes trees and the bisect log's quoting.
The notes fuzzer also edits a notes tree against a map and reads back what it
wrote. Five check
lock answers, TLS handshake messages and private keys, the merge state files,
patches, mailboxes, binary hunks and dates. Five check
files, patches, mailboxes, binary hunks, regular expressions, dates and
pathspecs. Five check
more than that. The diff fuzzer applies the
edit script it produced and checks that it reproduces the other side, which is
the property that catches an off-by-one nothing else would. The
collision-check fuzzer asserts both that the name is SHA-1's name and that
nothing reached by chance is flagged. The delta fuzzer decodes every delta it
encodes and compares it with what it was encoded from. And the pack fuzzer
writes a pack of random objects, some of them deltas, then reads it back and
rehashes every one against the name its index gives it. The merge fuzzer
merges three random blobs and proves that an unchanged theirs preserves ours
byte for byte. `zig build test
--fuzz` builds the suite a second time with the instrumentation on and runs
them until stopped, keeping a corpus per property under `.zig-cache/f` and
printing a web address where the coverage is.

Two pack shapes cannot be made with `git repack`, so the suite writes the
packs itself: two reference deltas naming each other, and a chain a thousand
deep. The first is a named error and the second resolves without recursing.

## Requirements

Zig 0.17.0. A `git` on the path for the fixture tests, which are skipped
without one.

Supported git: 2.39 and newer. The floor is the oldest git shipped by a
supported LTS distribution, reviewed yearly; today that is Debian 12's 2.39,
which is also the release Apple ships on macOS. Correctness is held to the
newest git, 2.55 and git's main branch. The floor job only proves interop:
repositories relic writes open in git 2.39, and its credential helpers, remote
helpers and LFS filters work with relic.

## Licence

MIT. See [LICENSE](LICENSE).
