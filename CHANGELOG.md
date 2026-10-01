# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- HTTP CONNECT retries belong to the connection attempt that accepted the proxy challenge, so concurrent requests cannot consume each other’s retry decisions.

- LFS transfer workers read and publish fatal errors under one lock, preserving the first failure without racing another worker.

- Concurrent HTTP timeout fallbacks increment their diagnostic count under the client lock, preserving every connection made without a watchdog.

- HTTP watchdogs read operation timestamps before the clock, so concurrent activity cannot underflow elapsed time and close a fresh connection as timed out.

- Program timeouts cover feeding stdin, collecting output, waiting and cleanup under one deadline, ending the child on expiry; unavailable concurrency is refused instead of feeding a pipe synchronously.

- Shared LFS, promisor and clone configuration writes select their local source, preserving separate worktree configuration and shared repository settings.

- Commit-graph chain discovery preserves filesystem refusals instead of interpreting an unreadable chain as absent.

- Pack-index, multi-pack-index and commit-graph readers transfer their buffers to the parser once, so malformed on-disk data cannot free the same bytes twice.

- Object discovery uses one absence policy for source directories and loose probes, preserving unreadable walks, prefix iteration, corrupt packs and optional-index or hint read resource failures instead of returning incomplete success.

- Snapshot closure ownership validates tree and blob edge types, including objects already private, before certifying a retained tree.

- The linked reftable fetch fixture requires Git 2.45, which can create its backend, while every assertion runs on the primary platform gates.

- Required-filter discovery keeps full filter names and allocation failures instead of silently omitting a required driver.

- Fetch checks the main worktree’s checked-out branch through the repository’s ref backend, including linked reftable worktrees.

- History entry points clear earlier diagnostic output even when they refuse the operation before a repository write, through the diagnostic owner.

- Replacing a setting added in memory transfers its name to the new line before freeing the old text, so subsequent reads and edits retain the setting.

- Ignore and attribute loaders preserve malformed case-folding policy and allocation failures instead of loading a different policy.

- Unit tests count work and compare results instead of asserting speed ratios or performance ceilings; all measurements and their timing example live in the bench branch harness.

- The warm staging fixture gives its files an earlier modification time than the index instead of assuming two writes cannot share a clock tick.

- Configuration source paths enter their owner only after copying succeeds, so allocation failure cannot leave a partial path for cleanup.

- Snapshot reads and reopening use only private objects, borrowing the source database for capture alone, so damaged source packs and alternate metadata cannot affect recorded snapshots.

- Staging, status and listing share one directory-read policy so unreadable contents cannot disappear from an otherwise successful result.
- Filesystem staging, status and listing return `TreeTooDeep` at their walk limit instead of returning a partial result.
- Snapshots keep the indexed contents of sparse tracked paths absent by policy and read edits to skipped paths present on disk.
- URL parsing and display share scheme boundaries, and drive prefixes and file authorities follow Git's platform rules.
- GnuPG fixtures use private homes under `.zig-cache/gpg` by default; `-Dgnupg-fixture-root=/short/path` gives long checkouts a short root for agent sockets, and each home is removed after its daemons stop.
- An object source transfers its directory handles once on registration, rolls back failed alternate sources, and preserves allocation failure and cancellation.
- A registered pack and its name have one owner, and allocation failure or cancellation while opening packs and their multi-pack index remains a resource failure.
- Staging refuses a directory it cannot open instead of recording its tracked files as deleted.
- A staging scan keeps ownership of each copied directory name until its entry has been appended, including allocation failure.
- Remote URLs keep bracketed IPv6 hosts, users, ports and home paths distinct from remote helpers, and file authorities and local paths follow Git's scheme boundaries.

### Changed

- Relic depends on conduit for process spawning, bounded input and output, waiting and termination. Git command preparation, environment scrubbing and caller execution policy remain in relic.

- Breaking: `program.SpawnHook.start` receives an allocator and `conduit.Child.SpawnOptions`, returns `conduit.Child`, and reports its spawn errors; `terminate` receives that child too. `Running.child` uses conduit's stream accessors and ownership transfers. Conduit links libc on POSIX through its module.

- Breaking: Odb allocator, format, source, policy and storage fields are opaque state read through `allocator`, `objectFormat` and `settings`; repository configuration is borrowed through `configuration` and changed atomically through `editConfig`, with format/backend checks and ref policy publication shared with refresh; memory-only source changes return `WorktreeConfigChanged` and require a standalone write followed by refresh.

- Breaking: `Odb.makeDurable` reports foreign hashes as `ObjectFormatMismatch`, distinct from an unexpected object type.

- Breaking: `reftablestack.isReftableRepository` and `GitDir.refStore` preserve backend-probe I/O refusals; only absent paths select the files backend.

- Breaking: `sequencer.signs` and persisted sequencer/rebase signing policy preserve configuration value and allocation errors instead of choosing unsigned writes.

- Breaking: `Repository.requiredFilters` returns configuration value errors instead of treating malformed required policy as optional.

- Breaking: `Odb.openAt` borrows its directory handle on success and failure; callers that transferred a handle must close their original.

- Breaking: `CheckoutOptions`, snapshot `OpenOptions` and snapshot `Store` carry durability policy; callers depending on their layouts or constructing stores directly must migrate.

- Breaking: repository hash/ref fields and ref-store allocator/directory/backend/cache fields are opaque owner state accessed through `objectFormat`, `refStore`, `refFormat` and `reftableOptions`; ref-store construction is fallible and requires `deinit`, including `GitDir.refStore`, with backend selection at construction and write-policy changes through `configureReftable`.

- Breaking: caller-owned `repo.Diagnostic` includes `signing_stderr`, preserved after a failed commit or tag signing program; layout-dependent callers must review the new field.

- Breaking: commit, merge, sequencer and rebase options carry optional caller-owned write diagnostics; callers depending on their layouts must review the new field.

- Breaking: `Repository.coreSettings` and `worktreeRules` return malformed-setting and resource failures; callers must handle their error unions.

- Breaking: repository commit and tag writes preserve `InvalidSignature` and `MixedHashKinds` in `WriteError` instead of reporting `UnexpectedObjectType`.

- Breaking: delta results over the size limit return `DeltaSizeLimitExceeded`; `DeltaSizeOverflow` means a size encoding wider than 64 bits.

- Breaking: a refresh that changes the ref backend returns `RefStorageChanged`, requires reopening and keeps the old configuration and ref store.

- Breaking: `refreshConfig`, `writeCommit`, `writeTag` and `writeTagWith` take caller-owned `repo.Diagnostic` output; the repository's `unsupported`, `unsupported_len` and `unsupportedSetting` are removed.

### Removed

- `repo.fs.macos_fsync_is_writeout_only`, a constant nothing read.

### Performance

- A racily clean index entry is smudged on the way out only when its file
  changed, as git smudges one (`WriteOptions.racy`, `worktree.RacyCheck`,
  `Repository.writeIndex`), so the next status does not hash it again and
  an index read and written back keeps its bytes. Every index relic writes
  for a repository goes through `Repository.writeIndex`.
- A pack entry is inflated in one pass by relic's own decoder, into the
  buffer its header sizes, rather than streamed through std's.
- Packs are looked in before loose objects, as git looks: a packed
  repository no longer pays a failed `open` for every object read.
- An entry's header and data come from one buffered read, and a seek
  backwards to a delta's base reuses what the buffer already holds.
- `worktree.status` does not read HEAD's side of a directory whose tree the
  index's cache tree already names; with nothing staged, HEAD is not read.

### Added

- `transport.url.Identity` owns decoded SSH/file URL identities and their raw text; SSH and file transports use decoded paths while scp, local and HTTP spellings stay literal.

- `worktree.snapshot.Store.adoptTree` migrates retained borrowed trees into owned storage without recapturing files, with the same closure and durability policy as capture.

- Checkout and snapshot stores offer opt-in durable completion, and `Odb.makeDurable` owns and syncs selected object closures before an intent is recorded; file barriers precede directory barriers, with drive-cache flushes on macOS and failures preserved.

- `worktree.snapshot.Store` captures repository working trees and plain folders with an owned tree-and-blob closure, restores and diffs snapshots, and copies only objects the private store does not already hold.
- `Repository.OpenOptions.diagnostic` keeps the full refused setting in caller-owned output after a failed open.

- A test that holds the TLS client to the standard library's: it fails when
  the compiler ships a different `std/crypto/tls/Client.zig` than the diff
  was taken against, and when the copy is not std's file with the diff
  applied.
- `zig build test -Dtest-filter=…` selects tests by name for focused fixture checks.
- `Odb.listAlternates`, `addAlternate` and `removeAlternate` read and update
  git's alternates file, including comments and quoted paths, with changes
  visible to the open database at once.
- Export `wildmatch.match` at the package root, with git's pathname and
  case-fold options for callers matching globs directly.
- `program.Programs.spawn` accepts a caller's process launcher and optional
  termination hook for hooks, filters and other programs relic runs.
- `Odb.existsOwn` and `Odb.own`: whether an object is in the database's own
  objects rather than only in an alternate, and taking one an alternate
  holds into its own. A repository that borrows another's objects owns what
  it cannot afford to lose to the other's `gc`.

### Changed

- **Breaking:** the root is one module per concern, each holding the modules
  that belong to it, in place of 106 flat modules. The sixteen at the top are
  `repo`, `hash`, `object`, `odb`, `refs`, `config`, `index`, `worktree`,
  `wildmatch`, `diff`, `revwalk`, `merge`, `commit`, `transport`, `submodule` and `lfs`;
  the rest moved under them:

  | Under | Modules |
  |---|---|
  | `repo` | `hooks`, `program`, `warning`, `fs` |
  | `hash` | `sha1`, `sha1dc` |
  | `object` | `fsck` |
  | `odb` | `pack`, `delta`, `inflate`, `indexpack`, `revindex`, `commitgraph`, `midx`, `abbrev` |
  | `refs` | `reflog`, `reftable`, `reftablestack` |
  | `config` | `userconfig` |
  | `index` | `sparseindex` |
  | `worktree` | `worktrees`, `sparse`, `sparsecheckout`, `ignore`, `attributes`, `wildmatch`, `convert`, `filter`, `dirscan`, `safepath` |
  | `diff` | `textdiff`, `rename`, `similarity`, `patchid` |
  | `revwalk` | `revparse`, `shallow` |
  | `merge` | `blobmerge`, `ort`, `strategy`, `subtreeshift`, `threeway`, `rerere` |
  | `commit` | `message`, `head`, `reset`, `stash`, `signing`, `commithooks`, `merging`, `sequencer`, `rebase`, `todo` |
  | `transport` | `remote`, `url`, `refspec`, `fetch`, `fetchpack`, `clone`, `push`, `sendpack`, `local`, `ssh`, `smarthttp`, `httpclient`, `tls`, `clientcert`, `httpauth`, `httpsettings`, `credential`, `auth`, `protocol`, `connection`, `pktline`, `sideband`, `uploadpack`, `objectwalk`, `objectfilter`, `partial`, `filterspec`, `progress` |
  | `submodule` | `gitmodules`, `gitlink`, `submoduletransport` |
  | `lfs` | `lfsapi`, `lfstransfer`, `lfslocks`, `lfspush`, `lfshooks`, `lfsssh`, `netrc` |

  So `relic.reflog` is `relic.refs.reflog`, `relic.fetch` is
  `relic.transport.fetch` and `relic.program` is `relic.repo.program`. The
  declarations inside each module are unchanged. `blobmerge`, `objectfilter`
  and `clientcert`, which the README listed and the root did not export, are
  now reachable.
- The TLS client is the standard library's with a recorded diff and nothing
  else. The code the added handshake steps call moved out of the copy into
  `src/tls/auth_wire.zig`, and the four doc comments the copy had added to
  std's own declarations are gone, so the copy differs from std only where
  the handshake has to change. `src/tls/Client.zig.diff` is that difference,
  with the SHA-256 of the std file it was taken against; its header states
  the rule for bringing std's fixes across, and `ci/tls-fork.sh` takes the
  diff again.

### Fixed

- Opening or refreshing refuses an invalid `extensions.worktreeConfig` boolean by name and preserves resource failures instead of ignoring the worktree file.

- The smart HTTP doc comments describe relic's TLS client and its configured client certificates.

- Commit and tag writes name refused `gpg.format` and `gpg.minTrustLevel` settings in caller-owned diagnostics.

- A `commondir` that cannot be opened returns the filesystem error instead of reading shared state from the worktree directory.

- Listing loose refs preserves allocation and filesystem failures instead of returning an incomplete list or an older packed value.

- Repository discovery keeps each directory handle until it can transfer ownership, closing them when opening or reading the next part fails.

- Reading `packed-refs` gives its bytes to the parser once, avoiding a double free when parsing or allocation stops.

- A signing policy that is not a boolean is refused by name, and allocation failures while reading it remain resource failures; neither writes an unsigned object.

- Reading a reftable `HEAD` during open or refresh preserves stack failures instead of treating them as a detached branch.

- A config refresh updates the ref store's `reftable.*` settings together with the configuration, keeping both when the settings are invalid.

- A tag signing refusal names `tag.forceSignAnnotated` when that is what requires signing.

- Repository format decisions come from the shared configuration once, and an invalid version is refused rather than read as zero.

- A configuration keeps one owner for copied command values when a later source allocation fails.

- A config refresh clears an earlier refused setting and names a changed object format itself.

- Allocation, cancellation, I/O and size-limit failures stay distinct from corrupt objects, malformed settings and bad revisions.

- A cache-tree rebuild that stops on a staged conflict frees the directory
  node it took out of the tree, which it leaked.
- A corrupt cache tree that fails below a directory frees that directory's
  name once, not twice; an index that carries `TREE` or `REUC` twice keeps
  the later one and frees the first.
- `LockFile.Options.sync_directory` now syncs the target's parent directory
  after the commit rename where the platform supports it.
- `AddOptions.ignore_errors` now skips files that cannot be read or hashed,
  reports each path and error through `error_report`, and stages the rest.
- A conversation with a program (ssh, a helper) that is cancelled stops the
  program on `close` or `diagnose` rather than waiting for it to end, so a
  fetch or push whose remote never answers returns when its caller cancels.
- `connection.Process.sayTo`, `finish` and `diagnose` leave a connection
  that is not a program's alone, rather than reading and writing its context
  as a `Process`.
- `diff.numstat` and `diff.unified` free an object's bytes with the object
  database's allocator, which allocated them, rather than the caller's.
- `reset.toTree` writes files through the target tree's `.gitattributes`,
  matching `git reset --hard` when attributes change between trees.
- The test TLS front exits when its parent test process ends, including on a
  failed assertion, and explicit cleanup closes its input pipe.
- A file whose stat no longer matched the index was compared with it by
  line endings alone, under attributes from outside the working tree only:
  the `.gitattributes` files in it were never read there. So a checked-out
  CRLF or expanded `$Id$` whose stat had changed -- a touch, or a checkout
  on Linux, whose file clock is coarse enough that files written in the same
  tick as the index are racy -- was a local change, and a merge, a pick or a
  `reset --merge` refused to overwrite it. The file is now read the whole
  way in, as `add` reads it: the directories' `.gitattributes`, the filter,
  line endings and `ident`.

- `ci/linux.sh` is green. Its image builds git 2.55.0, the version CI's
  Linux job builds, from the release tarball checked against a pinned
  SHA-256, where it had Debian's 2.39.5, older than the suite's fixtures
  need; the image is tagged with a digest of its Dockerfile, so it is built
  once and rebuilt when the file changes. The suite runs on a copy of the
  checkout on the container's own filesystem rather than on the bind mount
  from macOS, whose permissions and stat are the host's. Three tests
  assumed macOS: one changed a directory's mode through a handle Linux opens
  with `O_PATH`, one knew git's assertion failures by the BSD C library's
  wording, and one knew `openssl s_server`'s peer signature line only as
  OpenSSL 3.2 and later print it.

- `Signer.init` and `Lfs.load` leaked memory when a setting was long. Each
  took its arena's state before its last allocations, so the blocks those
  allocations made were not in the state `deinit` freed: a signing key,
  key command, allowed-signers or revocation file, or `lfs.fetchinclude`
  and `lfs.fetchexclude` lists, long enough to need a block of their own.
  A path to the key under a long home directory was enough.

- The signing tests' git read the machine's system configuration, which on
  a Homebrew or Xcode git names the keychain as the credential helper. They
  now run in the same isolated environment as the rest of the suite: no
  system configuration, a scratch home, no agents, no prompt. The lock
  helper the concurrency tests start is given that environment too, and the
  gpg tests stop every daemon gpg started for their home rather than only the
  agent.

## [0.3.0] - 2026-09-25

relic grows from a local repository library into all of git a program needs:
fetch, clone and push over HTTP(S), ssh and local paths, with the person's
own credentials; git's merge machinery; hooks, filters, signing, submodules,
stash; LFS with locks; sparse index and reftable. Every behaviour is checked
against the git and git-lfs on the machine running the suite.

### Added

**Running programs.**
- `program`: the one place the library starts a process, and only through a
  `Programs` value the caller hands in. Without one, a setting that would run
  a program is a named refusal, as before. Commands read from configuration
  run as git runs them: through `sh -c` when they hold anything a shell reads,
  directly otherwise.
- `pktline`: git's packet lines, read and written.

**Network.**
- `transport`, `fetch`, `clone`, `push`: fetch in protocol v2 and v0 and push
  as receive-pack speaks it, over smart HTTP, over ssh through the person's
  own `ssh` (`GIT_SSH_COMMAND`, `core.sshCommand`, their `~/.ssh/config`), and
  from `file://` and local paths. Remote-tracking refs,
  `FETCH_HEAD`, refspecs, reflogs, atomic pushes and fetches, thin packs
  completed on receipt, `url.<base>.insteadOf` and `pushInsteadOf`.
- `uploadpack`: relic serves fetches itself, in protocol v2 and v0, with
  shallow, deepen and every filter git has. `file://` fetches go through it in
  process.
- `shallow`: shallow clone and fetch by depth, date and excluded ref; deepen,
  unshallow and `update_shallow`; a push from a shallow repository sends its
  boundary. A shallow repository is walked as git walks it.
- `partial`, `filterspec`, `objectfilter`: partial clone with `blob:none`,
  `blob:limit`, `tree:<depth>`, `sparse:oid=`, `object:type=` and `combine:`,
  choosing exactly the objects git's filters choose. A promised object is
  fetched when it is read, asking every promisor remote in git's order. A
  server that cannot filter is asked for everything, with git's warning.
- `submoduletransport`: submodules cloned and fetched through relic itself.
- `httpclient`: relic's own HTTP/1.1 client. https through a proxy's CONNECT
  tunnel, `http.sslVerify=false`, kept connections, chunked and gzip bodies,
  and connect, handshake and activity timeouts.
- `tls`: relic's own TLS client, the standard library's with client
  authentication added, importing nothing but std. Every https connection
  goes through it.
- Client certificates for git and LFS: `http.sslCert`, `sslKey`,
  `sslCertType`, `sslKeyType` and `sslCertPasswordProtected`, and the proxy
  forms; RSA, ECDSA P-256/P-384 and Ed25519 keys in PEM or DER, PKCS#8,
  PKCS#1 or SEC1, plain or encrypted, in TLS 1.3 and 1.2. A passphrase comes
  from the credential helpers as git asks for one.
- `httpsettings`, `httpauth`: git's `http.*` for a URL, `http.<url>.*`
  sections, the `GIT_SSL_*` variables, `http.sslCAInfo` and `sslCAPath`,
  proxies as curl reads them, and proxy authentication as curl does it for
  git (anyauth, Basic, Digest with MD5 and SHA-256).
- `warning`: what git would print as a warning, returned as a value.
- `revindex`: `.rev` files written while `pack.writeReverseIndex` is on.
- `inflate`: relic's own zlib decoder for pack entries, which checks the
  Adler-32. Received packs are indexed as they arrive, their deltas resolved
  on several threads through the caller's `std.Io` (`pack.threads`, or git's
  rule when it is unset).

**Credentials.**
- `credential`: the helper protocol as git 2.55 speaks it, including bearer
  tokens, `wwwauth[]`, `state[]`, `password_expiry_utc` against the caller's
  time, and scheme-less `credential.<host>` sections. Nothing is asked of the
  person unless the caller passes a `credential.Prompt`.
- `auth`: why a remote refused, as values: the URL, the transport, each
  helper asked and what it answered, whether a prompt was available, and what
  the server or ssh said. ssh's "Permission denied" and host-key failures are
  their own errors.
- `userconfig`: the configuration the person's git reads — the system file
  their git was built with, the XDG file and `~/.gitconfig`,
  `GIT_CONFIG_COUNT` and `GIT_CONFIG_PARAMETERS`. A clone takes it for its
  fetch and for its checkout's filters.
- `netrc`: `~/.netrc` on the LFS path, as git-lfs reads it.

**History.**
- `ort`: merge, cherry-pick, revert and rebase follow git's merge-ort. Renames,
  directory renames, directory/file and file/symlink conflicts, submodule
  fast-forwards, several merge bases merged into virtual ones, git's conflict
  messages, and the inner merges' messages at verbosity 5. Where git's
  merge-ort stops on its own assertion, relic stops with
  `DirectoryRenameLostStage`.
- `strategy`, `subtreeshift`: every `-X` word git's merge takes — ours,
  theirs, patience, histogram, `diff-algorithm=`, the whitespace options,
  renames and their threshold, renormalize, `subtree` and `subtree=<path>` —
  kept between the steps of a stopped sequence as git keeps them.
- `rename`, `similarity`: rename and copy detection in diffs with git's score
  and matching order (`-M`, `-C`, `--find-copies-harder`).
- `rerere`: resolutions recorded and replayed in git's `rr-cache` and
  `MERGE_RR`, with `status`, `remaining`, `diff`, `forget` and `gc`. The index
  keeps git's resolve-undo record.
- `sequencer`, `rebase`, `merging`, `threeway`: the commands on top, with
  their state files in git's format, so git and relic continue each other's
  stops.
- `revparse`: git's revision grammar.
- Merged files are written through ident, smudge filters and LFS, as checkout
  writes them.

**Hooks, signing, stash.**
- `hooks`, `commithooks`: git's hooks with git's arguments, environment and
  standard input — around commit, merge, cherry-pick, revert and rebase, and
  pre-push, post-checkout and reference-transaction where git runs them.
- `signing`: commits and tags signed and verified with OpenPGP, SSH or X.509
  as `gpg.format` says, through the person's `gpg` or `ssh-keygen`.
- `stash`: push, apply, pop, list, drop and show in git's own shape.

**Filters and LFS.**
- `filter`, `convert`: clean and smudge filters by name, the long-running
  process protocol, and `ident`.
- `lfs`: LFS pointers and the object store, cleaned on add and smudged on
  checkout without git-lfs.
- `lfsapi`, `lfstransfer`, `lfsssh`: the batch API with the basic adapter,
  over https or git-lfs's pure-ssh protocol, finding the server where git-lfs
  finds it and authenticating as it does. Downloads resume with a Range and
  are checked by SHA-256; gzip and zstd bodies; chunked uploads; `fetch` with
  `lfs.fetchrecent*`; objects taken from a `--reference` or `--shared` store
  first.
- `lfslocks`, `lfspush`: lock, list, verify and unlock, with git-lfs's cache
  on disk so either tool shows the other's; lockable files read-only unless
  held; a push uploads its LFS objects and checks other people's locks
  first.
- `lfshooks`: when git-lfs's own hooks are in a repository and git-lfs is not
  installed, relic does their work.

**Submodules, sparse, reftable.**
- `submodule`, `gitmodules`: `.gitmodules`, gitlinks, recursive status,
  init, update, sync and absorbed git directories.
- `sparseindex`, `sparsecheckout`: cone-mode sparse checkout and the sparse
  index, read and written.
- `reftable`, `reftablestack`: the reftable ref backend, read and written.
- `config`: `includeIf` decided by the repository's own git directory and
  branch; a variable before any section, and a name's case, read as git reads
  them; an XDG slot beside the global file, and command-line pairs.

### Changed

- Breaking: `worktree.CheckoutOptions.force` defaults to false, so a checkout
  keeps local changes and names the paths it would lose. Callers that mean
  `read-tree --reset` pass `force = true`.
- Breaking: `merge.Conflict.Kind` names stage shapes and `Conflict.merged` is
  gone; `favor` gives way to `strategy_options`; `revwalk.mergeBasesWith`
  takes options; `Walk.Commit.parents` is borrowed from the walk;
  `worktree.writeEntry` takes a `convert.Session`; `textdiff.similarity` is
  removed.
- Breaking: `push.Options` gains `lfs`, and a push from a repository that uses
  LFS uploads its objects and may refuse a change to a file someone else has
  locked.
- Breaking: `Repository.loadFilters` returns `LoadFiltersError`.
- History walks, merge bases and ancestry checks use git's ordering and
  commit-graph generation numbers, and look only at the commits between the
  two sides. They are no longer quadratic.
- A read-only file is replaced and removed on Windows as it is elsewhere.
- A merge keeps a given message byte for byte, and `MERGE_MSG` ends with a
  newline as `git merge -m` writes it.

### Fixed

- `add -A` over a conflicted index left the conflict stages beside the new
  entry, which git refuses to read.
- `Index.removeMany` read a path it had already freed.

## [0.2.0] - 2026-09-20

Pack writing at git's cost for a smaller pack, with an opt-in thread count
for the delta search; reads and status faster; and the fixes a second
reading found.

### Added

- `PackOptions.threads` opts into concurrent delta candidate searches through
  the caller's `std.Io` executor. Its default of one submits no concurrent
  work and every count writes the same pack bytes.

### Changed

- Clean status avoids materializing unchanged result entries, and repository
  index reads reuse the timestamp resolution measured at open.
- Packed inflates retain their positional read buffer across nearby delta
  entries instead of discarding it after every object.
- Pack writing indexes each delta-window base once and reuses that index for
  every candidate search.
- Single-thread pack delta search filters impossible size and depth candidates
  before indexing a base and rolls its target hash forward one byte at a time.
  On the 35,512-object pack fixture this moved 9.82 seconds to 9.36 seconds;
  the resulting pack is 18,691,709 bytes.
- Pack ordering retains loose-object bodies within a configurable 64 MiB
  default budget, so those objects are opened and inflated only once. On the
  same fixture this moved 9.36 seconds to 8.83 seconds with identical pack
  bytes.
- Packed reads keep resolved delta bases in a byte-bounded
  least-recently-used cache, so small bases no longer collide in a fixed-size
  table.
- Sparse checkout preserves files whose matching stat is too recent to trust but whose content changed.
- Checkout handles tracked directory/file transitions and refuses untracked collisions before changing the worktree.
- Ref transactions document that commit-time I/O failure may leave an installed prefix that callers must reread.
- Concurrent relic reflog appenders serialize their writes so no entry is overwritten.
- Lock sidecars record the process through the host system interface on every supported platform.
- Commit-graphs reject fanout tables inconsistent with their sorted object names.
- Cache trees reject roots and subtrees that do not account for the index entries beneath them.
- Object stream writers hash and count bytes written through their advertised `writer` interface.
- Breaking: staging can return `error.IrreversibleConversion`, and `AddOutcome` reports `safecrlf_warnings` for `core.safecrlf=warn`.
- Failed lock-file installation removes both the lock and its process sidecar.
- Batch durability barriers propagate failures to create their synchronization file.
- Setting a previously bare config variable writes valid syntax that remains safe across later edits.
- Breaking: typed config getters decode quoted values; `getBool` and `getInt` can return `OutOfMemory`, and `getPath` can return `MalformedValue`.
- Relative config includes resolve beside the file containing each include, including nested includes.
- Breaking: writing extended flags in index version 2 returns `error.ExtendedFlagsRequireVersion3` instead of dropping them.
- Breaking: pack-index parsing can return `error.ChecksumMismatch` when its trailing hash is invalid.
- Gitlink diffs count and print the synthetic `Subproject commit` lines git uses.
- Ancestry queries propagate missing, corrupt, and non-commit history instead of answering false.
- Signature parsing rejects malformed numeric timezone offsets instead of silently using UTC.
- Breaking: tree builders return `error.ObjectFormatMismatch` when entries use another hash format.
- Breaking: tag peeling returns `error.TagDepthExceeded` when sixteen hops still end at a tag.
- Lock acquisition, symbolic-ref preparation, and config section creation release or own their memory on every path.
- Added worktrees return an owned name and an independently opened worktree directory as documented.
- Failed object-stream installation remains abortable and removes its temporary file.
- Breaking: sparse indexes return `error.SparseIndexUnsupported` specifically for the mandatory `sdir` extension.
- Blob merging composes independent edits, emits git-compatible merge or diff3 conflicts, refuses binary content, and can resolve tree conflicts when requested.

## [0.1.0] - 2026-09-19

The first release. It reads and writes a repository the way git leaves one on
the disk: objects loose and packed, refs loose and packed, the index at
versions 2, 3 and 4, the working tree, and diffs.

### Breaking

- **`fs.Stat.matches` takes a fourth argument**, the resolution.
  `worktree.Rules` carries it and `Repository.worktreeRules` fills it in from
  what the object database measured, so a caller going through the front door
  passes nothing new.

- **`odb.Error` grew.** Writing a pack can fail in ways reading one
  cannot — `ObjectCountMismatch`, `TooManyObjects`, `DeltaBaseNotWritten`,
  `DuplicateObject` — and enumerating objects parses commits, tags and trees,
  so `object.ParseError` and `object.TreeParseError` are in it now too.
  Breaking for a caller that switches exhaustively on it; nothing returns any
  of them unless a pack is being written or a set of objects collected.

- **`worktree.Rules` gained `timestamp_resolution`** and
  `odb.Options` gained `probe_timestamp_resolution`. Both default to the
  behaviour that was there before measuring was possible.

### Added

- **Packs are written.** `pack.Writer` takes objects one at a time and streams
  them into a temporary; `finish` writes the `.idx` beside it and renames both
  into place under the name the pack's own trailing checksum gives them, which
  is what git names a pack after. All three entry kinds: a whole object, an
  offset delta against an entry already in the pack, and a reference delta
  against a name that need not be. The index is version 2 throughout —
  fanout, sorted names, a CRC per entry, the 64-bit offset table — and the
  hash is the repository's, so a SHA-256 repository gets a SHA-256 pack. What
  is held is one object, the deflate state, and one index entry per object;
  nothing is threaded.

  `Writer.init` is told the object count, because it goes in the header and
  the header is written first. `Writer.initCounting` is for a caller that does
  not know it: the header is patched at the end and the checksum taken again
  over one sequential pass across the file, which is what not knowing costs.

  The order the two files become visible in is not free to choose. A reader
  finds a pack by its `.idx`, so the pack is renamed into place first and the
  index second, which is git's order too.

- **`delta.encode`** — the copy and insert commands that turn one object into
  another. The base is indexed by its sixteen-byte blocks and the longest run
  is taken; `EncodeOptions.max_bytes` gives up as soon as the delta has grown
  past what would be worth writing. The suite decodes every delta it writes,
  over seven shapes of change and under the fuzzer.

- **`Odb.writePack`, `packLoose` and `repack`.** The objects are ordered the
  way git's packer orders them — type, then git's own hash of the tail of the
  path hint, then size descending — and each is tried against a sliding window
  of the ones already written: ten, a chain no deeper than fifty, and a delta
  kept only if it is at most half the object it stands in for and beats the
  best so far. `PackOptions.window_bytes` bounds the window by weight as well
  as by count.

  `packLoose` and `repack` take the loose files away afterwards, in the order
  a running git has to survive: pack, then index, then a re-scan so this
  database can read the new pack itself, and only then the loose files — and
  only the ones the new index confirms. At no point is an object in neither
  place. Removing the packs a repack replaces is off by default, because a
  pack a second process has open can be removed on one platform and not on
  another.

  On a repository of twenty files each grown over six commits, 138 objects:
  the deltified pack is 29 692 bytes where the same objects written whole are
  84 871. What the suite asserts of the two is that the deltified one used
  deltas and came out smaller.

- **`Odb.collectReachable`, `collectLoose` and `collectAll`** — which objects
  to put in one. `collectReachable` walks commits, their parents, the trees
  those name and the blobs under the trees, and gives each object the path it
  was found at, which is the hint the delta search orders by; the other two
  read the trees they collected to get the same thing. Without a hint two
  versions of one file sort next to two versions of a different file of the
  same length and the window looks at the wrong base — 108 per cent of the
  undeltified pack rather than 35. `CollectOptions.exclude_packs` names packs
  whose objects to leave out, which is what makes a pack incremental.

- **`worktree.AddOptions.new_blobs`** — a staging pass can write one pack
  instead of one loose object per blob. Measured on an Apple M3 Max over three
  thousand files in sixty directories: 392 ms as loose objects, 68 ms as one
  pack, and the tree that comes out is the same tree. What it gives up is that
  another reader sees nothing until the pass is over, and that nothing is
  deltified, because a delta wants the object before it and a walk hands them
  over one at a time.

- **`Odb.beginPack`, `writeInto` and `finishPack`** — the seam that makes the
  above possible, for any caller writing many objects at once.

- **`dirscan`** — a directory's entries with the stat of each, in as few calls
  as the platform has. macOS has `getattrlistbulk(2)`, which returns, for a
  whole batch of directory entries, the name and the modification and change
  times, the file id, the owner, the group, the access mask, the device and
  the data length — every field git's index compares, including the `dev`,
  `ino`, `uid` and `gid` that `std.Io.File.Stat` does not carry. The ordinary
  shape is a directory read and then one `lstat` per name. `dirscan.Scan` is
  both arms behind one iterator and `addAll`, `status` and `list` all take it.

  Measured on an Apple M3 Max over three thousand files in sixty directories,
  minimum of ten alternating runs: a warm `addAll`, which is the walk and
  nothing else, 9.4 ms to 4.8 ms; `status` over a tree with one file in ten
  changed, 11.9 ms to 7.8 ms. On one directory on its own the call is 2.1 to
  2.5 times the read-then-stat shape, and two syscalls rather than one per
  file.

  A volume that refuses it answers on the first call, before anything has been
  handed out, so the fallback is clean. `Scan.initPlain` takes the ordinary
  arm on purpose, which is what the suite compares against; a volume that
  refuses the batch call skips that test rather than passing it, because
  comparing the ordinary arm with itself proves nothing.

- **`fs.Resolution` and `fs.probeTimestampResolution`** — how fine a
  modification time a filesystem records, measured instead of assumed. One
  file is created in the directory, written to three times and stat'd after
  each write; the answer is the largest power of ten that divides every
  nanosecond field reported, capped at a second. It runs at `Odb.open` and at
  `Index.read`, and `odb.Options.probe_timestamp_resolution` turns it off.

- **`Odb.Stats` gained `loose_written`, `loose_present`, `fan_out_created` and
  `packed_written`.** The benchmark asserts on the last two rather than on a
  wall-clock figure, because a count is what a busy runner cannot move.

- **`index.WriteOptions.end_of_index_entries` and `.entry_offset_blocks`**,
  and **`Index.had_end_of_index_entries` and `Index.entry_offset_blocks`**.

- **`hash`** — `Kind` is `sha1` or `sha256` and `Oid` carries it, so nothing
  assumes twenty bytes and a name from one repository cannot be compared with
  a name from another by accident.

- **`sha1`** — SHA-1 over the instructions the processor has for it:
  aarch64's `sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0` and `sha1su1`,
  x86-64's `sha1rnds4`, `sha1nexte`, `sha1msg1` and `sha1msg2`, with the
  eighty rounds written out as the fallback. Measured over 64 MiB on an Apple
  M3 Max: 0.99 GiB/s for the rounds, 2.47 GiB/s for the instructions, which
  puts SHA-1 past the standard library's hardware SHA-256 at 2.29 GiB/s
  rather than well behind it.

  Two decisions are worth the reason. **The arm is chosen by asking the
  processor rather than by what the compiler was told**, because a package
  built for a baseline target is the normal case and a compile-time gate
  would hand every such build the slow path on a machine that has the
  instructions. **The target does not take the choice away either** —
  aarch64 asks for the extension inside the assembly and x86-64's assembler
  does not gate these — so nothing has to be added to a consumer's build
  graph. One thing does take it away: both arms are assembly, and the
  self-hosted x86-64 code generator has no encoding for these instructions,
  so a build that uses it — a Debug x86-64 build, in practice — takes the
  software rounds rather than failing to compile.
  `hash.Hasher.sha1Backend()` says which arm a measurement was taken on.

- **`sha1dc`** — SHA-1 with collision detection, as an arm of `hash.Hasher`
  and an option on the object database. `Odb.Options.detect_sha1_collisions`,
  which both `Repository.open` and `Repository.init` forward, makes every
  SHA-1 name the database takes carry the check; bytes that look like half of
  a near-collision pair are `error.CollisionAttack` with nothing written.

  It is off, for three reasons that belong together. It costs about five
  times the hash, because the method needs the expanded message and the
  intermediate states and so cannot use the processor's SHA-1 instructions.
  It reports rather than repairs, so a caller gets a named error instead of a
  name nothing else in the world agrees with. And what it guards is git's
  object format: the published colliding documents are not colliding objects,
  since `"blob <size>\0"` goes in front of the content and moves every block,
  which is why git stores both of them today under two names.

  The table and the bit conditions are transcribed from the published
  reference. Checked both directions: the published pair is detected, both
  halves and across every split of the feed, and nothing in the fixture
  repositories — text, a deltified file, a binary blob — is flagged.
  `hash.Hasher.Options` carries the choice, `hash.Hasher.initOptions` takes
  it, `hash.Hasher.collisionAttack` reads the answer, and
  `hash.Hasher.nameObject` does both in one call and returns a `Named`.
  `sha1dc.collision_test_vector_a` and `_b` are the published pair, for a
  caller that wants to prove the wiring in its own suite.

- **`object`** — the four types parsed and written, with git's tree sort rule
  (the key is the name for a blob and the name with `/` appended for a
  subtree), git's commit header order, and `gpgsig` unfolded on the way out
  and folded on the way in.

- **`pack`** and **`delta`** — `.idx` version 2 including the 64-bit offset
  table, both delta kinds, a chain bounded three ways (an offset delta may
  only point backwards, a depth cap, and a byte budget on the whole chain),
  the twenty-byte header probe that gives a deltified object's type and true
  size without materialising it, and `verify`, which rehashes every object
  against the name its index gives it and checks every entry's CRC.

- **`odb`** — loose objects, the packs and `objects/info/alternates`. A miss
  re-scans the pack directory once before it is a miss, because a `gc` may
  have packed the object away. Loose objects are deflated at level 1, which
  is git's own default for them. The multi-pack index is wired into lookup:
  `read`, `readHeader` and `exists` ask it which pack holds an object before
  asking the packs one at a time, and it is re-read on every pack scan
  because a `gc` replaces it along with the packs it names. It says which
  pack, and that pack's own index still gives the offset — trusting the
  offset would make a stale index a read at a wrong position rather than a
  miss, and the two-step costs one binary search against the one per pack it
  replaces. An index that does not parse, or that names a pack this database
  has not opened, is a miss. `Odb.stats` counts `midx_hits` and `pack_scans`,
  and `Odb.multiPackIndexCount` says how many of the database's object
  directories have one.

- **`index`** — versions 2, 3 and 4 read; 2 or 3 written by default and 4 on
  request. `TREE` and `REUC` are understood; an unknown optional extension is
  kept byte for byte and written back; an unknown mandatory one is a named
  refusal. git's racy rule is implemented, including writing a racily-clean
  entry's size as zero.

- **`config`** — read with `include.path` and `includeIf` (`gitdir`,
  `gitdir/i`, `onbranch`), and written losslessly: setting one value rewrites
  one line and every comment stays where it was.

- **`ignore`**, **`attributes`** and **`wildmatch`** — git's own glob rather
  than `fnmatch`, the four ignore precedence levels with the last match
  inside a level winning, `[attr]` macros, and `text`/`eol`/`core.autocrlf`
  conversion driven by git's check-in binary rule.

- **`refs`** and **`reflog`** — transactions that take every lock in their
  prepare step and roll back completely if one is held, `packed-refs` read
  and written, and a log line for every ref the policy names.

- **`worktree`** — `addAll` with the stat shortcut and the racy rule,
  `writeTree` through the cache tree, `checkout` as `read-tree --reset -u`
  with `HEAD` untouched, `resetIndex` as `git reset` with the files left
  alone, structured `status`, `list`, and sparse checkout.

- **`worktrees`** — add, remove, prune, lock, unlock, move and repair, with
  the administrative directory and the `.git` file git writes.

- **`diff`** and **`textdiff`** — tree to tree, added and removed counts with
  the binary case, and the unified patch git prints, including the enclosing
  line on the `@@` header. Myers carries git's give-up constants and the
  indent heuristic rather than being the textbook minimal algorithm, because
  `git diff` does not emit a minimal diff. Histogram is behind the enum.
  Rename and copy detection has a threshold and a limit and is off by
  default.

- **`revwalk`** and **`merge`** — a history walk by date or topologically,
  merge bases, and a three-way tree merge leaving conflicts at index stages 1
  to 3.

- **`commitgraph`** and **`midx`** — read, as accelerators. Correctness never
  depends on either.

- **`safepath`** — what a path from a tree may become on the disk, applied on
  every platform.

- **`repo`** — the front door, which refuses by name any repository extension
  it does not implement.

- **Eighteen fuzz tests**, one per parser, built and run by `zig build test
  --fuzz` and keeping a corpus each under `.zig-cache/f`. Zig 0.16.0's
  fuzzing test runner hands `@errorReturnTrace()`'s
  `std.builtin.StackTrace` to a function taking `std.debug.StackTrace`, two
  structs of the same shape and different identity, which is one compile
  error per fuzz test; the test module sets `error_tracing = false`, which
  takes the trace out of the runner's path. What that costs is the return
  trace under a failing test — the error and the test's name are still
  printed.

### Changed

- **A cold `addAll` no longer opens a directory per object.** Profiled first,
  on an Apple M3 Max over three thousand files: of 475 ms, the loose-object
  write was 390 and inside it the two irreducible calls — the
  `O_CREAT|O_EXCL` that makes the temporary, at 35 µs, and the `rename` that
  finishes it, at 54 µs — were 105 and 155. Everything else the write did per
  object is gone.

  The temporary and the object it becomes are now both named relative to the
  `objects` directory, so a `mkdir`, an `opendir` and a `close` per object
  became one `mkdir` per fan-out directory, made by the write that first lands
  in one that is not there yet. The deflate state, two hundred and twenty-four
  kilobytes of it, and the output buffer beside it moved off the stack of
  every object written and onto the database, allocated on the first object it
  writes; a database that is only read allocates neither. A walk asks the
  platform for a path's stat once rather than twice, because the call that
  fetches the three fields `std.Io` leaves out already reports the ones it
  carries. And a file whose length a stat has already reported is read without
  asking again.

  Minimum of ten alternating runs: 475 ms to 426 ms cold, 9.4 ms to 4.8 ms
  warm. The two calls that remain are what one file per object costs on this
  filesystem: the same two straight through libc cost the same, so nothing is
  being lost in a layer.

- **`EOIE` and `IEOT` are written again rather than dropped.** Both are caches
  of byte offsets into the index file itself, so copying one into a file whose
  entries have moved points it at the wrong place — which was right about the
  numbers and wrong about the conclusion. The numbers are now taken again from
  the file being written. `EOIE` carries the offset of the first extension and
  a hash over the signature and size of every extension header before it;
  `IEOT` divides the entries into blocks and is written first, and at version
  4 the first entry of each block has its path written whole, because a reader
  that decodes the blocks independently has no entry before it.

  How many blocks is a reader's business: the count comes from the index that
  was read, and stock git writes neither extension unless `index.threads` asks
  for a reader that can use them. The fixture test therefore asks for one and
  compares the bytes.

- **git's racy rule uses the filesystem's measured timestamp resolution.** On
  a filesystem that keeps nothing below a second, every entry in the index's
  own second is racy, because the filesystem cannot put the two in order. On a
  finer one the comparison is at the unit that was measured. The old rule
  believed a reported nanosecond was a kept nanosecond, which is wrong in both
  directions.

Decisions worth knowing before reading the source:

- **A loose object's compressed bytes need not match git's.** An object's
  name is the hash of its uncompressed content and git never compares the
  compressed form.

- **Durability is a policy rather than a constant.** `fs.Sync` defaults to
  what git defaults to, which makes neither a loose object nor the index
  durable before returning; `batch` gives full durability for one barrier per
  batch. Directory entries are not synced unless asked, because git does not
  sync them either.

- **Packs are read positionally by default.** A memory map is faster on a
  cold cache and turns an IO error into a signal on macOS and a lock on the
  file on Windows; `Odb.Options.map_packs` opts in.

- **A split index is read whole and written back as one complete index.** No
  entry is lost; the split is not recreated, and git re-splits on its next
  write if the setting is still on.

- **Commit-graph generation numbers are read only in their second form.**
  Version one stores topological levels, which are a different quantity with
  the same name.

- **`working-tree-encoding` and a required filter are refusals, with the
  value.** Passing the bytes through would write a blob git would not write.

[0.3.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.1.0
