//! relic — read and write a git repository from Zig.
//!
//! The table below describes the exported namespaces; it is checked against
//! the API, and the README's against both, wherever relic compiles.
//!
//! | Module | Purpose |
//! |---|---|
//! | `repo` | `Repository.open`, `create` (templates and `--shared` included), `templateDir`, `openIndex`, `head`, `headTree`, `writeCommit`, `writeTag`, `peel`, `beginRefs`, `configuration`, `writeConfig`, `editConfig`, `refreshConfig`, `loadIgnore`, `loadAttrs`, `listWorktrees`, `pruneWorktrees`. The front door. |
//! | `repo.warning` | What git would print as a warning, as a value. |
//! | `repo.hooks` | git's hooks with git's arguments, environment and input. |
//! | `repo.program` | `Programs`, `SpawnHook`, `Invocation`, `run` — the one place a process starts. `Programs.spawn` supplies creation and termination using conduit children. |
//! | `repo.fs` | `Sync`, `OnContention`, `staleReport`, `Resolution`, `Shared`, `ownedByCurrentUser` — the lock, durability and timestamp policies every writer and every stat comparison here goes through. |
//! | `repo.safe` | `Ownership`, `directoryIsSafe`, `bareRepositories` — `safe.directory` and `safe.bareRepository` as git applies them to a repository it discovers: another user's repository opens only where the system, global or command-line settings name it, and a bare one is not discovered under `explicit`. |
//! | `repo.ident` | `signature` — who an author or committer is, as git's `ident.c` decides: `GIT_AUTHOR_*` and `GIT_COMMITTER_*`, `author.*`, `committer.*`, `user.*`, `EMAIL`, then what the caller says the machine has; under `user.useConfigOnly` a name or email the configuration does not give is refused by name. |
//! | `repo.state` | The state files an operation keeps in the git directory: written, read and removed in one place. |
//! | `repo.rev_parse` | git's revision grammar, `@{<date>}` with git's approximate dates included. |
//! | `hash` | `Kind` (`sha1`, `sha256`), `Oid`, `Hasher` with `Options` and `nameObject`. The hash is a parameter from the first line, not a width bolted on later. |
//! | `hash.sha1` | SHA-1 over the processor's own instructions, with the eighty rounds as the fallback and the choice made at run time. |
//! | `hash.sha1dc` | SHA-1 that checks each block for the signature of a collision attack. Off unless asked for. |
//! | `object` | `Type`, `Mode`, `Tree` and `Tree.Builder`, `Commit`, `Tag`, `Signature`, `ExtraHeader`. Parsing and writing, with git's tree sort rule and header order. |
//! | `object.fsck` | What git's `fsck` finds wrong with an object's bytes, every message id at git's level: `Rules` from `fsck.*`, `fetch.fsck.*` and `receive.fsck.*` with skip lists, `forTransfer` for `transfer.fsckObjects` and `fetch.fsckObjects`, and the `.gitmodules` and `.gitattributes` a tree names (`checkBlob`). |
//! | `odb` | `Odb.open`, `read`, `readInto`, `readHeader`, `exists`, `existsOwn`, `own`, `findPrefix`, `write`, `writeStream`, `listObjects`, `listAlternates`, `addAlternate`, `removeAlternate`, `verify`, `refresh`, `syncBatch`, `placement`, and the `stats` counters. Loose objects, the packs, `objects/info/alternates` and the multi-pack index. Writing packs: `collectReachable`, `collectLoose`, `collectAll`, `writePack`, `packLoose`, `repack`, and `beginPack` / `writeInto` / `finishPack` for a caller filling one as it goes. |
//! | `odb.abbrev` | Short object names as git prints them. |
//! | `odb.bitmap` | Pack and multi-pack reachability bitmap files, and git's EWAH/XOR encoding. |
//! | `odb.commit_graph` | The commit-graph, read and encoded as an accelerator. |
//! | `odb.commit_graph.bloom` | Git's changed-path Bloom hashes. |
//! | `odb.rev_index` | A pack's reverse index, `pack-<name>.rev`: its objects in the order they sit in the pack, each named by its position in the `.idx`. |
//! | `odb.mtimes` | A cruft pack's object times, `pack-<name>.mtimes`: when each object it holds was last written or wanted, which `prune` and `repack --cruft` date that object by instead of by the pack's own time. |
//! | `odb.islands` | Delta islands, the pack writer's side: which islands each object is in, and whether one may be a delta of another. |
//! | `odb.index_pack` | Receiving a pack: what `git index-pack --stdin --fix-thin` does. |
//! | `odb.pack` | Packfiles, and the `.idx` beside them. |
//! | `odb.delta` | The delta encoding a packfile uses. |
//! | `odb.midx` | The multi-pack index, read and encoded as an accelerator. |
//! | `odb.quarantine` | `Quarantine` — objects held apart until accepted, git's `tmp_objdir`: begun, read through, migrated or discarded. |
//! | `refs` | `Store`, `Ref`, `Resolved`, `Transaction`, `Expected`, `packed-refs` read and write. `Store.root` and `Store.special` own the root refs (`ORIG_HEAD`, `CHERRY_PICK_HEAD`, ...) and the special refs (`FETCH_HEAD`, `MERGE_HEAD`) in either ref format; `deleteRefs` removes refs by any safe name; `writeInitial` writes a new repository's first refs; `list` keeps what is no ref apart in `broken`; `main-worktree/` and `worktrees/<id>/` read another worktree's refs; `create` lays down a new ref store. Logs in either format through the store: `readLog` (`Log.at` for `HEAD@{n}`), `logExists`, `appendLog` under a `LogPolicy` (`core.logAllRefUpdates`), `createLog`, `expireLog` (git's `reflog expire` and `reflog delete`, `--rewrite` and `--updateref`), `deleteLog`. |
//! | `refs.reftable` | Reftable: the table format, and the stack of tables `tables.list` names, which is the ref store. |
//! | `refs.reftable.table` | The reftable format: one table read and written. |
//! | `refs.reftable.stack` | The stack of tables `tables.list` names: the ref store. |
//! | `refs.verify` | git's `refs verify`: what is wrong with the refs themselves, by `fsck.<msg-id>`. |
//! | `refs.names` | What a ref may be named: `checkFormat` (git's `check_refname_format`, with its one-level and pattern flags), `isSafe` (what a deletion may name), the root, special and per-worktree classes, `parseWorktreeRef` for `main-worktree/` and `worktrees/<id>/`, and every root ref by name (`Root`, `Special`). |
//! | `config` | `Config.open`, `get`, `all`, `getBool`, `getInt`, `getPath`, `subsections`, `origin`, `set`, `unset`, `renderWritable`. Lossless: setting a value rewrites one line; a repository's files are written through `Repository.writeConfig`. `include.path` and `includeIf` with `gitdir:`, `gitdir/i:`, `onbranch:` and `hasconfig:remote.*.url:`. |
//! | `config.user` | Where the person's git reads its configuration from. |
//! | `config.color` | `parse`, `When`, `wanted`, `readSlots` — git's colours: a value as `color_parse` writes it, `color.ui` beneath each writer's `color.<writer>`, and its `color.<writer>.<slot>` colours. |
//! | `index` | `Index.read` / `write` / `toBytes`, `Entry`, `CacheTree`, `ResolveUndo`, `RawExtension`. Versions 2, 3 and 4. |
//! | `index.sparse` | The sparse index. |
//! | `index.untracked` | The untracked cache, git's `UNTR`: read, kept true as entries come and go, and written. |
//! | `worktree` | `addAll`, `writeTree`, `checkout`, `resetIndex`, `status`, `list`, `applySparse`. |
//! | `worktree.sparse_checkout` | `git sparse-checkout` as an operation: `set`, `add`, `reapply`, `disable`, `init` and `list`. |
//! | `worktree.linked` | `list`, `add`, `remove`, `prune`, `lock`, `unlock`, `move`, `repair`, each worktree's refs in the repository's ref format. |
//! | `worktree.snapshot` | `Store`, `capture`, `adoptTree`, `restore`, `diff`: working trees whose complete Git object closure belongs to a private store. |
//! | `worktree.renames` | `find`, `configured`: the renames `git status` finds among the staged changes, through diff's rename detection, and what `status.renames` asks for. |
//! | `worktree.remove` | `git rm`: the index entries a pathspec names removed, and their files and submodules, after git's check for what the removal would lose. |
//! | `worktree.move` | `git mv`: files, directories and submodules renamed in the working tree and the index together, after git's checks of every source. |
//! | `worktree.sparse` | Sparse checkout: which tracked paths belong in the working tree. |
//! | `worktree.ignore` | `Rules.init` / `loadGlobal` / `addDirectory` / `addText` / `popTo` / `match` / `matchPath`, with the pattern that decided. |
//! | `worktree.attributes` | `Attrs`, `Attributes`, `unsupported`, `toGit`, `toWorktree`, `isBinaryForDiff`, `isBinaryForCheckIn`. |
//! | `worktree.convert` | What happens to a file's bytes between the working tree and the object database, in git's order. |
//! | `worktree.encoding` | Character sets, converted as git converts them through iconv: one place for both of git's jobs. |
//! | `worktree.fsmonitor` | `refresh`, `configured`, `ChangeSource`: the file monitor git asks through `core.fsmonitor` (its hook, protocol 1 and 2, or its own daemon, `true`, over the daemon's socket or pipe), or a program's own, deciding which files `status` looks at; `FSMN` read and written. |
//! | `worktree.filter` | Clean and smudge filters: the programs a `filter` attribute names. |
//! | `worktree.filter.native` | Native content-filter protocol. |
//! | `worktree.dir_scan` | `Scan` — a directory's entries with their stats, from `getattrlistbulk(2)` where the volume has it and a read and a stat per name where it does not. |
//! | `worktree.safe_path` | What a path from a tree is allowed to be. |
//! | `diff` | `tree`, `numstat`, `blobNumStat`, `unified`, `unifiedBody`, `isBinary`, `Colors`, `WhitespaceRule` — a file's patch as `git diff` and `git format-patch` write it (git's headers, unique abbreviations, `--binary`, `--full-index`, `--relative`), in colour as `git diff --color` writes it where `Options.colors` is given: `color.diff.<slot>`, whitespace errors by `core.whitespace`, the `whitespace` attribute and `diff.wsErrorHighlight`. |
//! | `diff.blame` | `file` — which commit each line of a file comes from, as `git blame` says, following renames. |
//! | `diff.combined` | `paths`, `write` — the combined diff of a merge against all its parents at once, as `git diff-tree -c` and `--cc` and `git show` write it. |
//! | `diff.driver` | `Drivers` — the diff driver each side of a diff takes by its `diff` attribute and mode, and what the driver says: binary or not, its `textconv`, the lines that start its functions. |
//! | `diff.external` | `External` — an external diff program (`diff.external`, a driver's `command`) run for a file pair in place of its patch, as `git diff` runs it. |
//! | `diff.patch_id` | Patch ids: a name for what a commit changes. |
//! | `diff.rename` | Pairing deleted paths with added ones: git's `diffcore-rename`, for `git diff -M` and `-C` and for the merge. |
//! | `diff.similarity` | How much of one blob another is made of, scored exactly as git's rename detection scores it. |
//! | `diff.stat` | `files`, `write`, `writeSummary`, `Widths.configured` — `--stat` and `--summary` as git writes them, the widths from `diff.statNameWidth` and `diff.statGraphWidth`. |
//! | `diff.textconv` | `Textconv` — a file's text as its diff driver's `textconv` program writes it, for diff, blame, grep and range-diff; a cache for `cachetextconv`. |
//! | `rev_walk` | `Walk` and `Walk.count`, `mergeBase`, `mergeBases`, `mergeBasesMany`, `isAncestor`, `parentsOf` — git's date queue and topological order, commit-graph generation numbers, the shallow boundary, and history simplified by paths (`Walk.paths`) as git simplifies it by default. |
//! | `rev_walk.bisect` | `start`, `mark`, `nextStep`, `reset`, `log`, `replay`, `run`, `terms`: `git bisect` as git 2.56 does it, with its state files, its choice of commit, skips, `--first-parent`, `--no-checkout`, `--reset-when-found`, terms and pathspecs. |
//! | `rev_walk.describe` | `describe`, `head`, `Describer`: `git describe` with `--tags`, `--all`, `--long`, `--abbrev`, `--candidates`, `--match`, `--exclude`, `--first-parent`, `--always`, `--dirty`, `--broken`, a blob as `<commit>:<path>`, and `--contains` as `git name-rev` names it. |
//! | `rev_walk.fork_point` | `forkPoint` — `git merge-base --fork-point`: where a branch forked from a ref, through the ref's log. |
//! | `rev_walk.follow` | `follow` — `git log --follow -- <path>`: the commits that changed a file, followed back through its renames as git follows them. |
//! | `rev_walk.last_modified` | `lastModified` — `git last-modified`: for each path of a commit's tree, the commit that last changed it. |
//! | `rev_walk.path_walk` | `PathWalk` — git's path-walk: the objects a history reaches, in batches by the path that reaches them. |
//! | `rev_walk.mailmap` | `Mailmap.load`, `lookup`, `map`: `.mailmap`, `mailmap.blob` and `mailmap.file` read and matched as git reads and matches them. |
//! | `rev_walk.shallow` | A shallow repository's boundary: `.git/shallow`. |
//! | `rev_walk.object` | The object walk: every object a set of tips reaches past what is excluded, and the filters a partial clone asks it to apply. |
//! | `rev_walk.object.walk` | Which objects one side has that the other lacks, and whether a set of tips is whole. |
//! | `rev_walk.object.filter` | The objects a filtered pack holds, chosen as git's `list-objects` walk and its filters (`list-objects-filter.c`) choose them, so that a server sends what git's sends, object for object. |
//! | `merge` | `blobs`, git's `ll_merge` on parallax's three-way merge, and the stage-only tree merge. |
//! | `merge.rerere` | Recorded resolutions in git's `rr-cache`: `run`, `status`, `remaining`, `diff`, `forget`, `gc`. |
//! | `merge.three_way` | A merge of three trees carried into the index and the working tree. |
//! | `merge.subtree_shift` | Lining one tree up with another that holds it one or more directories down, or that it holds: git's match-trees, which the merge strategy options `subtree` and `subtree=<path>` run before a merge. |
//! | `merge.strategy` | Git's merge strategy options: the words `-X` hands the ort strategy, as `merge`, `cherry-pick`, `revert` and `rebase` take them and as they are kept between the steps of a sequence. |
//! | `merge.ort` | `mergeTrees`, `mergeCommits` — git's merge-ort: renames, directory renames, directory/file and type conflicts, submodules, virtual merge bases, git's messages. |
//! | `merge.octopus` | `mergeCommits` — git's octopus: several heads merged one after another, `read-tree --aggressive` then `merge-one-file`. |
//! | `commit` | Making a commit the way `git commit` does, its hooks in git's order. |
//! | `commit.notes` | `Notes`, `add`, `append`, `copy`, `remove`, `prune`, `show`, `merge`, `mergeCommit`, `mergeAbort`, `formatNote`: `refs/notes/*` read and written as `git notes` does, git's fanout and every merge strategy included. |
//! | `commit.todo` | The instruction sheet a cherry-pick sequence and a rebase work through: `.git/sequencer/todo` and `.git/rebase-merge/git-rebase-todo`. |
//! | `commit.branch` | `create`, `setUpstream`, `deleteMerged` — `git branch <name> <start>`, `--set-upstream-to` and `--delete-merged`: a branch made at a revision, tracking what `branch.autoSetupMerge` and `branch.autoSetupRebase` say; the branches whose work their upstream holds, deleted as git 2.56 deletes them. |
//! | `commit.rebase` | Rebasing: replaying a branch's own commits on top of another commit, `git rebase` with the merge backend, non-interactive or driven by an instruction sheet the caller supplies. |
//! | `commit.replay` | `replay` — `git replay`: commits made again in memory onto `--onto`, `--advance` or `--revert`, and the refs that pointed at them moved in one transaction. |
//! | `commit.history` | `fixup`, `reword`, `split` — `git history`: one commit rewritten where it stands, its descendants replayed onto it and their branches moved. |
//! | `commit.sequencer` | Replaying commits: `git cherry-pick` and `git revert`, one commit or a sequence of them. |
//! | `commit.merging` | Merging commits into the current branch: `git merge`. |
//! | `commit.stash` | `push`, `create`, `store`, `apply`, `pop`, `list`, `show`, `drop`, `clear`; the autostash a merge or a rebase makes and brings back. |
//! | `commit.in_progress` | `read`: which operations a worktree is in the middle of, as `git status` says. |
//! | `commit.message` | Commit messages as git's commands shape them. |
//! | `commit.trailer` | `process`, `processFile`, `format`, `iterate`, `amend`, `Settings.load` — `git interpret-trailers` byte for byte: the trailer block found as git finds it, `--trailer` added by `--where`, `--if-exists` and `--if-missing`, `--trim-empty`, `--only-trailers`, `--only-input`, `--unfold`, `--parse`, `--no-divider`, `--in-place`; `trailer.separators`, `.where`, `.ifExists`, `.ifMissing` and every `trailer.<name>.key`, `.command` and `.cmd`. `%(trailers)` and `git commit --trailer` go through it. |
//! | `commit.head` | HEAD as git's commands move it, and the files a command in progress leaves beside it. |
//! | `commit.reset` | Putting the index and the working tree back to a commit's tree: `git reset --merge` and `git reset --hard`, which is how every history-editing command is aborted. |
//! | `commit.signing` | Sign and verify commits and tags: OpenPGP, SSH, X.509. |
//! | `commit.hooks` | The hooks git's history commands run around the commits they make: `git merge`, `git cherry-pick`, `git revert` and `git rebase`, and the `git commit` each of them hands a resolved stop to. |
//! | `transport` | `Session`: a remote, open — the one thing a fetch, a clone or a push talks to. |
//! | `transport.filter_spec` | A partial clone's filter, read as git reads `--filter=<spec>` and the `filter` line a server is sent: `blob:none`, `blob:limit=<size>`, `tree:<depth>`, `object:type=<type>`, `sparse:oid=<blob>`, and `combine:<spec>+<spec>…`, each part percent-encoded where it holds a character git reserves. |
//! | `transport.partial` | Partial clone: a repository that holds some of its objects and is promised the rest. |
//! | `transport.side_band` | The side-band: several streams over one, a pkt-line at a time. |
//! | `transport.http_settings` | The `http.*` settings for one URL, read the way git reads them. |
//! | `transport.hidden` | `Refs` — `transfer.hideRefs`, `uploadpack.hideRefs` and `receive.hideRefs` as git's `ref_is_hidden` reads them: what a served repository does not advertise, what a want may name, what a push may not touch. |
//! | `transport.promisors` | `advertisement`, `reply`, `autoFilter` — the protocol v2 `promisor-remote` capability: `promisor.advertise` and `sendFields` on a server, `promisor.acceptFromServer`, `checkFields` and `storeFields` on a client, and the filter `auto`. |
//! | `transport.push` | `git push`: update a remote's refs from this repository's, with the objects they need. |
//! | `transport.clone` | `git clone`: a new repository with a remote, the remote's refs and objects, and its default branch checked out. |
//! | `transport.fetch` | `git fetch`: bring a remote's refs and the objects under them, and keep them where the refspecs say. |
//! | `transport.pull` | `pull` — `git pull`: the fetch, then a fast-forward, a merge of `FETCH_HEAD` or a rebase from the fork point, as `pull.ff`, `pull.rebase` and `branch.<name>.rebase` say. |
//! | `transport.backfill` | `backfill` — `git backfill`: a partial clone's missing blobs fetched in batches by path, within a range, a pathspec or the sparse checkout. |
//! | `transport.refspec` | Refspecs: the rule that says which refs a fetch takes and where it keeps them, and which refs a push sends and where they land. |
//! | `transport.remote` | Remotes, as a repository's configuration describes them. |
//! | `transport.url` | What a remote's URL names: which transport reaches it, and where. |
//! | `transport.fetch_pack` | Asking a server for a pack: the `fetch` command of protocol v2, and the `want`/`have` exchange of v0 and v1 when that is all the server speaks. |
//! | `transport.send_pack` | Sending to `git-receive-pack`: commands, a pack, and the report. |
//! | `transport.local` | A remote on this machine: a path, or a `file://` URL. |
//! | `transport.ssh` | Reaching a remote over ssh: the person's own `ssh`, started the way git starts it. |
//! | `transport.smart_http` | git's smart HTTP protocol over uplink's client, and a dumb server's files: `Files` and `Early`, each body an `aegis.io.ReadEnd`. |
//! | `transport.credential` | Credentials for an HTTP remote: git's credential helper protocol, and the prompt git falls back to, as git's `credential.c` has them. |
//! | `transport.credential.cache` | git's `credential-cache` client. |
//! | `transport.credential_cache_daemon` | Git's `credential-cache--daemon`: credentials held in memory, on a unix socket of the daemon's own, for as long as each was stored for. |
//! | `transport.auth` | Why a remote would not let this client in, in the terms a person needs to put it right. |
//! | `transport.protocol` | What a git server says first, and how its refs are asked for. |
//! | `transport.connection` | A conversation with a remote git service: `git-upload-pack` for a fetch, `git-receive-pack` for a push. |
//! | `transport.pkt_line` | Pkt-line: the framing under git's wire protocol and its long-running filter processes. |
//! | `transport.upload_pack` | `Server` — serving fetches, with shallow and every filter. |
//! | `transport.receive_pack` | `Server`, `connect` — serving pushes as git's receive-pack: quarantine, connectivity and fsck, the receive hooks, `receive.*`, report-status v1 and v2. |
//! | `transport.http_backend` | `Backend` — git's smart HTTP served on uplink's server: clone, fetch and push over `http://`. Only with `http`. |
//! | `transport.bundle` | `create`, `write`, `File.open`, `Header.read`, `listHeads`, `writeSummary`, `verify`, `unbundle`, `isBundle`: `git bundle` v2 and v3, its header byte for byte, filtered by any filter git takes, `sparse:oid=` included; a path to a bundle is fetched and cloned from. |
//! | `transport.bundle_uri` | `fetch`, `fetchList`, `List`: bundle URIs as git's `bundle-uri.c` takes them, a bundle or a bundle list (`mode`, the `creationToken` heuristic) unbundled before a clone or a fetch asks the server, its refs under `refs/bundles/`. |
//! | `transport.progress` | What a long operation says while it runs. |
//! | `transport.remote_helper` | `Helper`, `Spec`, `allowed` — `git-remote-<name>` run as git runs it: capabilities, options, `list`, `connect`, `fetch`, `import` (through `fast.importer`, `bidi-import` answered), `push`, `export` (through `fast.exporter`, with the helper's marks), private refs by its `refspec`. |
//! | `transport.policy` | Which transports a remote may be reached through, as git's `is_transport_allowed` decides it. |
//! | `submodule` | Submodules: repositories a superproject records by commit, at a path, with `.gitmodules` saying what each is called and where it comes from. |
//! | `submodule.gitmodules` | `.gitmodules`: which submodule lives at which path, and where its repository comes from. |
//! | `submodule.gitlink` | A gitlink's directory in the working tree: whether a repository is there, and which commit it has checked out. |
//! | `patch` | `parse`, `Patch`, `FilePatch`, `Fragment`: git patches and plain unified diffs read as `git apply` reads them, from whatever surrounds them. |
//! | `patch.am` | `start`, `proceed`, `skip`, `abort`, `quit` — `git am` with `--3way`, its state in `rebase-apply` as git keeps it. |
//! | `patch.commit_diff` | `parts`, `write`, `configured` — a commit's diff as `git log -p` and `git show` write it: a merge's by `--diff-merges` and `log.diffMerges`, first parent, each parent, combined, dense or the remerge diff. |
//! | `patch.mail` | `split`, `info` — `git mailsplit` and `git mailinfo`. |
//! | `patch.format` | `format` — `git format-patch` byte for byte: numbering, the diffstat, binary hunks, a cover letter, base information, threading and attachments. |
//! | `patch.apply` | `apply` — `git apply` to the working tree, the index or both: renames, copies, modes, binary hunks, `-R`, `--3way`, `--reject`, `--check`, whitespace checked or fixed, nothing written unless every file applies. |
//! | `patch.range_diff` | `write`, `compute` — `git range-diff` byte for byte: two series' patches as git reads them out of `git log -p`, paired by git's own solver, and the diff of each pair; `--creation-factor`, `--left-only`, `--right-only`, `--no-notes`, `--no-patch`, colour in dual colour or not. |
//! | `grep` | `grep` — `git grep` over the working tree, the index or a tree: fixed, basic and extended patterns with back-references, `--and`/`--or`/`--not` and `--all-match`, `-i -w -v -n -l -c`, context, `-p` and `-W` with git's `diff` driver function lines, pathspecs, binary files, written as git writes it, in colour under `color.grep.<slot>`; `-P` through the caller's `Matcher`. |
//! | `archive` | `archive` — `git archive` as tar or zip, git's bytes: the pax comment, `--prefix`, `export-ignore`, `export-subst`, `tar.umask`. |
//! | `archive.remote` | `remote` — `git upload-archive` and `git archive --remote`: the arguments as git's remote archiver reads them, the archive on the side band, git's words for each refusal. |
//! | `pretty` | `formatCommit`, `Context`, `Decorations`, `Colors` — git's `--format` placeholders for one commit, the mailmap's names, decorations, notes, signatures, `%(trailers)` with every option and colour as `git log --color` writes it among them. |
//! | `pretty.log` | `writeEntry`, `parse`, `configured`, `configuredAbbrevCommit`, `configuredShowSignature` — a log's entry for a commit in git's built-in formats (`raw`, `medium`, `short`, `full`, `fuller`, `oneline`) with its `commit` line, decorations, signatures and notes; the format by name, prefix, `pretty.<name>` alias or `format.pretty`. |
//! | `pretty.refs` | `Listing`, `listRefs`, `listBranches`, `listTags`, `branchFormat`, `versioncmp` — `git for-each-ref`, `git branch --list` and `git tag --list` byte for byte: every `%(...)` atom git has for refs, `*` peeling, dates in every mode, `align` and `if` blocks, four quoting styles; `--sort` with version sort and `versionsort.suffix`, `--contains`, `--no-contains`, `--merged`, `--no-merged`, `--forked`, `--points-at`, `--exclude`, `--start-after`, `--include-root-refs`, `--count`, `--omit-empty`, `branch.sort`, `tag.sort`; `%(color:...)` and `git branch`'s `color.branch.<slot>`. |
//! | `pretty.shortlog` | `Shortlog.init`, `add`, `addCommit`, `write`, `configured`: `git shortlog` by author, committer, trailer or format, with `-s`, `-n`, `-e` and `-w`. |
//! | `clean` | `clean` — `git clean`: `-n`, `-f`, `-ff`, `-d`, `-x`, `-X`, `-e`, pathspecs, repositories inside the tree left alone, git's lines. |
//! | `fast` | git's fast-import stream. |
//! | `fast.importer` | `import`, `Marks` — `git fast-import`: every command, its dates, marks files and notes fanout, branches updated as git updates them. |
//! | `fast.exporter` | `write` — `git fast-export` byte for byte: marks, renames, tags, signatures, refspecs. |
//! | `maintenance` | `writeCommitGraph`, `writeMidx`, `repackMidx`, `expireMidx`, `writePackBitmap`, `writeMidxBitmap`, `writeConfiguredCommitGraph`, `repackRepository`, `packRefs`, `expireReflogs`, `prune` and `reachableObjects` (git's `pack-refs`, `reflog expire` and `prune`, with `gc.reflogExpire*` and `gc.pruneExpire`). The format modules own the bytes; these operations gather through the object database, diff and revision walk. Fetch applies `fetch.writeCommitGraph`; configured maintenance applies `gc.writeCommitGraph` and the bitmap settings. |

const core = @import("relic_core");

pub const repo = core.repo;
pub const hash = core.hash;
pub const object = core.object;
pub const odb = core.odb;
pub const refs = core.refs;
pub const config = core.config;
pub const index = core.index;
pub const worktree = core.worktree;
pub const diff = core.diff;
pub const rev_walk = core.rev_walk;
pub const merge = core.merge;
pub const commit = core.commit;
pub const transport = if (features.http) transport_with_http else core.transport;
pub const submodule = core.submodule;
pub const patch = core.patch;
pub const grep = core.grep;
pub const archive = core.archive;
pub const pretty = core.pretty;
pub const clean = core.clean;
pub const fast = core.fast;

pub const maintenance = core.maintenance;

/// The features this build has: `http` (uplink and cloak) and `lfs` (strand).
const features = @import("relic_options");

/// Which optional features relic was built with.
pub const Features = struct {
    /// Fetching and pushing over HTTP(S), with uplink and cloak.
    http: bool,
    /// Git LFS's transfers, locks and agents, with strand: the `relic_lfs`
    /// module, which exists only with it.
    lfs: bool,
};

/// This build's features, as the dependency's `.http` and `.lfs` options set them.
pub const built_with: Features = .{ .http = features.http, .lfs = features.lfs };

// A declaration exists exactly when its types do: a namespace with a module
// only one feature holds is chosen whole, the name absent without it, so
// `@hasDecl` tells the truth and a consumer is told "no member" when it
// compiles. The choice lists every name of its namespace and the one it
// adds, which `sameNamesBut` holds to.
/// `transport` with `http`: every name of its namespace, and git's http-backend served on uplink's server.
const transport_with_http = struct {
    const base = core.transport;
    pub const filter_spec = base.filter_spec;
    pub const partial = base.partial;
    pub const side_band = base.side_band;
    pub const http_settings = base.http_settings;
    pub const hidden = base.hidden;
    pub const promisors = base.promisors;
    pub const push = base.push;
    pub const clone = base.clone;
    pub const fetch = base.fetch;
    pub const pull = base.pull;
    pub const backfill = base.backfill;
    pub const refspec = base.refspec;
    pub const remote = base.remote;
    pub const url = base.url;
    pub const fetch_pack = base.fetch_pack;
    pub const send_pack = base.send_pack;
    pub const local = base.local;
    pub const ssh = base.ssh;
    pub const smart_http = base.smart_http;
    pub const credential = base.credential;
    pub const credential_cache_daemon = base.credential_cache_daemon;
    pub const auth = base.auth;
    pub const protocol = base.protocol;
    pub const connection = base.connection;
    pub const pkt_line = base.pkt_line;
    pub const upload_pack = base.upload_pack;
    pub const receive_pack = base.receive_pack;
    pub const bundle = base.bundle;
    pub const bundle_uri = base.bundle_uri;
    pub const progress = base.progress;
    pub const remote_helper = base.remote_helper;
    pub const policy = base.policy;
    pub const Error = base.Error;
    pub const Options = base.Options;
    pub const wantsV2 = base.wantsV2;
    pub const Session = base.Session;
    pub const download = base.download;
    pub const http_backend = core.http_backend;
};

comptime {
    core.contract.sameNamesBut(core.transport, transport_with_http, "http_backend");
}

// The contract relic's public surface keeps (`core.contract`), checked as
// relic compiles, on any target, so that no build of it breaks one; and how
// a program ended is conduit's `Term` wherever relic shows it, and a
// program's working directory is relic's own `Cwd`.
comptime {
    core.contract.check(@This(), .{
        .source = @embedFile("relic.zig"),
        .path = "src/relic.zig",
        .readme = @embedFile("README.md"),
        .begin = "<!-- BEGIN MODULES -->",
        .end = "<!-- END MODULES -->",
        .depth = 3,
    });
    checkPrograms();
}

const conduit = @import("conduit");

/// How a program ended is conduit's `Term` wherever relic shows it, never
/// the standard library's, and a program's working directory is relic's
/// own `Cwd`.
fn checkPrograms() void {
    const program = repo.program;
    if (@FieldType(program.Invocation, "cwd") != program.Cwd or @FieldType(commit.trailer.Commands, "cwd") != program.Cwd)
        @compileError("a program's working directory is `repo.program.Cwd`");
    const terms = .{
        program.Term,
        @FieldType(program.Outcome, "term"),
        program.Child.Term,
        @typeInfo(@typeInfo(@TypeOf(program.Running.wait)).@"fn".return_type.?).error_union.payload,
        @typeInfo(@typeInfo(@TypeOf(program.Child.wait)).@"fn".return_type.?).error_union.payload,
        @typeInfo(@FieldType(repo.hooks.Failure, "term")).optional.child,
        @typeInfo(@FieldType(transport.connection.Process, "term")).optional.child,
    };
    inline for (terms) |term| if (term != conduit.Term) @compileError("how a program ended is `conduit.Term`");
}
