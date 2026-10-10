# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- time a caller gives is typed: every "now" (`transport`, `credential`, smart-HTTP and LFS options, `date.Context` and `date.Clock`, `revparse.Clock`, `archive.Options.now` and `mtime`, `patch.format` threading, `rerere.gc`, LFS `sweepTmp` and `expiredAt`) is a `std.Io.Timestamp`, `--shallow-since` and the commit-graph's `expire_time` too; a lock's wait is `fs.OnContention.wait`, a `std.Io.Duration`; LFS `retryAfterSeconds` is `parseRetryAfter`, returning a duration. `date.timestamp` makes one from git's seconds. Times git stores (a commit's, a reflog entry's) stay git's seconds.

- relic reads `core.fsync`, `core.fsyncMethod` and `core.fsyncObjectFiles`, as git reads them, and every writer they name keeps them: loose objects, packs (received ones included), their indexes and bitmaps, the commit-graph, the index, and refs, logs and reftable tables. Unset, packs, their metadata, the commit-graph, the index and references are synced, git's default with the last two besides; set, the value is read over git's default alone, so `core.fsync = pack` leaves references unsynced as git does. Config and state files are not synced, as git does not. A received pack was not synced at all before, so a crash after a fetch could leave refs naming a pack that never reached the disk. `fs.Fsync` holds the policy and `fs.Sync` gains `ordered` (`writeout-only`); `odb.Options.sync` is `odb.Options.fsync`, `pack.WriteOptions.sync` is `fsync`, `PackOptions.sync` and `indexpack.Options.sync` are gone (the database's policy applies), the maintenance writers' `sync` is optional and defaults to the database's, `LockFile.Options.sync` has no default, and `Repository.indexLock` gives an index writer its lock options.

- a `.git` file is read in one place, `discover.gitfile`, as git reads it: `gitdir: ` with its space, the path up to the line ending, spaces kept, up to 1 MiB. Submodules and linked worktrees used to accept `gitdir:` without the space and trim spaces around the path. `checkout.worktrees.readGitFile` is removed; `discover.gitfile.read` takes its place.

- certificates, keys and trust are [cloak](https://github.com/pedronaugusto/cloak)'s, which relic depends on directly; uplink makes the connections. `wire.clientcert.load` returns a `cloak.ClientAuth` (released with `deinit`), and the new `wire.authorities` reads `http.sslCAInfo`, `http.sslCAPath` and `http.proxySSLCAInfo` into a `cloak.Trust.Snapshot`, used by the smart-HTTP and LFS transports alike. On macOS and Windows the system's authorities are the system's own verifier, with `http.sslCAPath`'s besides it. A certificate file may also hold its key, and text before a block, as OpenSSL writes it, is read past. Until cloak speaks TLS 1.2 and signs with RSA keys, a server that speaks only TLS 1.2 fails with `error.TlsFailed`, and an RSA client key with `error.ClientCertificateSchemeUnsupported`.

- airlock owns relic's lock files, replacements and syncs. `LockFile` is an airlock temp named `<path>.lock`, still taken exclusively with git's backoff and the holder's pid in its first bytes, and `LockFile.Options.sync_directory` still makes its target's directory durable; `atomicWrite` is an airlock temp too, and takes `permissions` for a replacement that keeps the replaced file's; `fs.renameWithRetry` is `fs.rename`, which retries on Windows as airlock does; `fs.syncBarrier` and `fs.syncPath` are removed, and `odb.Options.sync_directories` with them. `Odb.syncBatch` flushes the fan-out directories that received loose objects since the last call, once each, where it created and removed a file to flush none; a pack written under `batch` flushes its directory. `Odb.makeDurable` and a durable checkout sync their files and directories together, one flush of the volume for all of them.

- `Attrs.Macro.assignments` is read-only; the built-in binary macro
  borrows static assignments.

- native filter, clone-filter and before-send callbacks receive allocator and Io before their opaque context; LFS SSH status readers receive allocator before Io.

- conversion sessions use `open(gpa, io, Options)` and `deinit(io)`. Filter processes and native providers receive the teardown call’s I/O.

- hook, trailer, mailmap, remote URL, LFS pattern and helper operations take defaulted policy options. Ref listing writes take the output writer before `WriteOptions`; transport policy takes a name and `Options`.

- ignore, attribute and sparse pattern constructors take defaulted `InitOptions`. Sparse file loading has one `load` operation with `LoadOptions`; `loadMode` is removed.

- object and binary-patch decoding use Warp directly; the internal `odb.inflate` namespace and copied decoder are removed. Pack resource failures retain their I/O causes.

- object validation, conversion, hook preparation, identity, branch movement and pretty formatting group related inputs and defaulted options. Every exported function and method takes at most five positional inputs.

- archive, range-diff, linked-worktree, bisect marking, subtree
  shifting and bitmap writes take named input groups. Archive and range-diff
  output writers precede their options. Published bytes, selection policies,
  local edits and bitmap object ordering keep their behavior.

- ref-log append takes AppendInputs before LogMessage; expiration
  takes its generic keeper before named options containing the ref name.
  Reftable writes take WriteInputs before WriteOptions, and compaction takes
  CompactInputs. Keeper order, rewrite/update-ref policy and record bytes
  are preserved across files and reftable.

- working-tree staging/status, checkout, path writes, verification,
  comparisons and sparse application take named input groups after the working
  directory. The index and object database stay borrowed; path selection,
  refusal diagnostics, local edits and durability keep their behavior.

- transport session, fetch/send pack, local receive and bundle APIs
  group their named inputs; bundle creation takes Target. LFS pre-push and SSH
  invocation take input groups and options. Object retention, protocol bytes,
  lock pagination and failure/cancellation outcomes keep their contracts.

- LockFile.open takes Inputs for the path and borrowed buffer;
  atomicWrite and readFileSized take named options. Program invocation and
  trailer commands use Relic's own Cwd type. Sized-read fallback failures free
  their original allocation exactly once, including a grown file over its limit.

- pack/index opening and pack decode requests take named inputs and
  options. Pack Writer.open replaces init and initCounting, with a nullable count
  in OpenInputs; openStream takes StreamInputs before its output writer. Index
  and reverse-index writes take write options; indexpack and bitmap encoding take
  input groups. Pack publication, retention and format bytes keep their contracts.

- unified diff takes UnifiedInputs before its output writer; blame
  groups commit/path in Inputs; patch ids take the shared diff.TreeInputs.
  Output formatting, attribution and patch-id semantics are unchanged.

- working-tree merges take TreeInputs, CommitInputs or OctopusInputs,
  including their mutable index. Reset takes Options for its index, target tree
  and overwrite policy; sequencer.resetMerge takes ResetOptions for ref identity
  and refusal diagnostics. Unrelated edits and abort restoration keep their
  existing behavior.

- merge trees/commits and diff tree pairs take named input groups;
  ancestry and merge-base walks take Pair, Many or Ancestry plus BaseOptions.
  Options and all semantic outcomes are preserved in their canonical operations.

- index reads take ReadOptions, including optional measured timestamp
  resolution. Object walks use MissingOptions, ConnectedOptions and ReceivedOptions
  in their canonical operations; the With variants are removed. Top-level note copy
  takes CopyRefOptions; trailer processing and amendment take named request options.

- `Repository.create` replaces `Repository.init`; repository
  mutable state is reached through directory, allocator, object database and
  configuration accessors. Public concerns move to `maintenance`, `pretty.refs`
  and `pretty.shortlog`; object walks are under `revwalk`. LFS submodules drop the
  repeated `lfs` prefix; configuration, sparse index, hooks and linked worktree
  namespaces use their concern names.

- owned connections use `deinit` as their release word.
  Program calls take allocator and I/O before the program policy; `run` takes
  `RunOptions` for input and bounds. Signing takes I/O before its signer. Arena
  choices belong to operation options. Inline public error unions have names.

- HTTP and TLS are [uplink](https://github.com/pedronaugusto/uplink)'s; relic's own HTTP/1.1 client, its proxy authentication, its SOCKS client and its copy of std's TLS client are gone, and relic's API names no uplink type. `transport.httpclient`, `transport.httpauth`, `transport.tls`, `transport.clientcert` and `lfs.lfsapi.timeoutsFor` are removed; LFS transport and exchange network state are opaque, and `Exchange.response` and `Exchange.diagnostics` are removed; smart HTTP and LFS are configured by git's and git-lfs's settings as before, which relic maps onto uplink's options. The errors a proxy fails with are uplink's: `ProxyNetworkUnreachable` and `ProxyTtlExpired` are `ProxyHostUnreachable`, `ProxyCommandUnsupported` is `ProxyRefused`, and `SocksProtocolError` is `ProxyProtocolError`, the SOCKS reply code in the message. A remote URL whose path holds a space or a control character is `MalformedUrl`, as curl refuses it, where the bytes went onto the request line; an `http.extraHeader` that is no field (a name that is not a token, a control character in its value) or names `Host`, `Content-Length` or `Transfer-Encoding`, and an `http.userAgent` with a control character, are `InvalidHttpHeader`, where they were sent as given. Responses are read as curl reads them: a bare LF ends a line and a folded field is unfolded, where both were refused, and a `Content-Length` with an underscore, which std's number parser took, is refused. `no_proxy` names an address range in CIDR notation, as curl 7.86 and later read it. Every socket has `TCP_NODELAY`, as curl sets it.

- a repository's ref format is decided once, from its own `config`, and handed to whatever opens its refs. A submodule's gitlink reads its repository's own format rather than probing for `reftable/tables.list` (`submodule.gitlink.head` and `GitDir.refStore` take no `kind`), and `worktree.worktrees.add`, `list` and `prune` take the repository's `refs.Store` in place of its `common_dir` and hash, reading each worktree's `HEAD` through it as `worktrees/<id>/HEAD`. `refs.create` lays down a new ref store's directories as git's `ref_store_create_on_disk` does, and `Repository.init` and `worktrees.add` then write `HEAD` through a transaction; `refs.reftablestack.initialize`, `headIn` and `isReftableRepository` are removed, and `refs.Format.name` and `parse` spell the formats as `extensions.refStorage` does. `refs.Store.writeInitial` is git's initial ref transaction: a clone writes the fetched refs through it, packed in the files format and as one table in a reftable, where it wrote `packed-refs` in either, and `clone.Options.ref_format` (git's `--ref-format`) clones into a reftable repository. `refs.Store.list` keeps what is no ref apart in `Listing.broken` -- a name no ref may have, a file that holds no ref, an object name of zeros -- as git marks them broken, where a bad name in `packed-refs` failed the whole listing and a bad loose ref was dropped unseen; in a linked worktree it no longer lists the main worktree's `refs/bisect`, `refs/worktree` and `refs/rewritten`, and `%(worktreepath)` finds the main worktree's branch in a reftable repository. A transaction that cannot take a symbolic value no longer leaks it.

- the ref store owns the root refs and the special refs. `refs.Store.root()` writes, reads, lists and removes `ORIG_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `REBASE_HEAD`, `AUTO_MERGE`, `BISECT_HEAD`, `BISECT_EXPECTED_REV` and the notes merge refs (`refs.names.Root`) as themselves, never through a ref they name (git's `REF_NO_DEREF`), in either ref format; `refs.Store.special()` reads, replaces and appends to `FETCH_HEAD` and `MERGE_HEAD`, which stay files in either format, through their locks (`git fetch --append` reads and writes under one). `commit.head.writeRef`, `readRef`, `deleteRef` and `refExists` are removed, and `refs.reftablestack.initialize` takes no `orig_head`. `refs.Store.deleteRefs` is git's `refs_delete_refs`, and a transaction deletes a ref by any name git's `refname_is_safe` takes, so a ref with a bad name is removed by its name; `refs.Store.readOid` is git's `read_ref`. `main-worktree/<ref>` and `worktrees/<id>/<ref>` read another worktree's `HEAD`, root refs, per-worktree refs and their logs in either format, as git's do, and a transaction or a log write (`appendLog`, `createLog`, `expireLog`, `deleteLog`) refuses them (`error.OtherWorktreeRef`). Fixed with it: in a reftable repository `commit` refuses while a cherry-pick or a revert is stopped, and a rebase with `--update-refs` leaves alone a branch another worktree has checked out; writing `ORIG_HEAD` while it named a branch no longer moves the branch; `--include-root-refs` lists a reftable repository's root refs from its tables alone; a bisection tells `reference-transaction` of `BISECT_HEAD` and `BISECT_EXPECTED_REV`; `worktree.worktrees.add` writes no `ORIG_HEAD`, as `git worktree add --no-checkout` writes none.

- what a ref may be named is decided in one place, `refs.names`. `checkFormat` is git's `check_refname_format` with its `allow_onelevel` and `pattern` flags, held to `git check-ref-format` under every combination; `isSafe` is git's `refname_is_safe`; `isRootRef`, `isSpecial`, `isPerWorktree` and `parseWorktreeRef` classify names as git does. `worktree.safepath.checkRefName`, `safepath.isValidRefName` and `safepath.Reason.invalid_ref_name`, `transport.refspec.checkRefFormat` and `refspec.Format`, `refs.filter.isRootRef` and `refs.reftablestack.isSpecial` are removed: use `refs.names.checkFormat(name, .{ .allow_onelevel = true })`, `refs.names.isRootRef` and `refs.names.isSpecial`. A push to a repository on this machine refuses a ref of one level under `refs/` (`refs/funny`) with receive-pack's "funny refname", where it took it; a revision of one level spelled with a dash (`FOO-BAR`) resolves as git resolves it.

- one way to write a repository's configuration. `Repository.writeConfig(io, file, edits, diagnostic)` writes `.git/config` or the worktree's `config.worktree` (the shared file while `extensions.worktreeConfig` is off, as git falls back) as git's `repo_config_set_multivar_in_file_gently` does: the file read again under its lock and only `edits` applied, so another process's `git config` since open survives; the configuration it would leave checked whole before it lands (`ObjectFormatChanged`, `RefStorageChanged`, any setting `open` refuses), then published. It returns a `WriteOutcome` (`sections_removed`). `writeConfigFile` writes a file that is not the repository's own, a submodule's or the main worktree's `config.worktree`, with its permissions. `Config.write` is removed, and `Config.SetError` no longer carries lock or commit errors. `editConfig` takes the `Io` and `config.Sources.Pair` values, set in memory only over every file as later `-c` values are, kept through `refreshConfig` and every write and never written; a value for the repository's format is refused (`FormatEditInMemory`, which replaces `WorktreeConfigChanged`). Clone, a lazy fetch's filter, the promisor fields a server asks to store, what an LFS server teaches, submodule `init`, `sync`, `deinit` and `absorb`, sparse-checkout and `init` itself write through it: none renders a configuration read earlier over the file, none writes a memory-only value, and sparse-checkout leaves `configuration()` what the files say. `config.Sources.Path.contents` reads given bytes in place of a file, and `Config.withCommandValues` is a configuration with other `-c` values and nothing read again.

- a ref's log is the ref store's, in either format. `refs.reflog` is no longer public, and `Store.dirFor` is private: `Store.readLog`, `logExists` and `appendLog` read and write a log where the format keeps it, and the new `Store.createLog`, `expireLog` (git's `reflog expire` and `reflog delete`, with `--rewrite` and `--updateref`) and `deleteLog` start, prune and remove one. `refs.Log`, `LogEntry`, `LogPolicy` and `LogReadError` name what they return. `Store.appendLog` takes a `LogMessage` and logs only where its policy says, so `HEAD` moved under `core.logAllRefUpdates = false` gains its line in a reftable repository as in a files one. `Resolved.from_packed` says whether a resolved ref came from `packed-refs`. In a reftable repository the stash works: two pushes keep both, `stash list` reads git's list and git reads relic's, and `drop` rewrites the log as git's does, with no `reference-transaction` hook until the last stash takes `refs/stash` with it. A deleted ref's log goes with it whether or not the transaction logs anything, so fetch's prune and push's tracking deletes leave no log behind in a reftable stack.

- `relic.diff.textdiff` and `relic.merge.blobmerge` are gone; parallax is the line diff for anyone who wants one. `diff.Algorithm` and `merge.ConflictStyle`, `merge.Labels`, `merge.Resolve` and `merge.Level` are parallax's types; `merge.ConflictStyle.parse` is `merge.parseConflictStyle`. `merge.Favor` is `merge.Resolve` (`none` is `markers`, `union_` is `both`), and every `favor` option is `resolve`: `merge.BlobOptions`, `merge.strategy.Settings`, `merge.ort.Options`, `patch.apply.Options`, whose refusal is `ResolveWithoutThreeWay`. `BlobOptions.join_without_alnum` is `level` (`.zealous_alnum` for `git merge-file`'s). `diff.Options.context` and `max_work` are `u32`, and `diff.function_context_max` is gone. `diff.unifiedBody`, `unified`, `blobNumStat` and `numstat` return `error.InputTooLarge` (`diff.TextError`) for a side of 4 GiB or more, where they returned `error.OutOfMemory`.

- `relic.wildmatch` and `relic.worktree.wildmatch` are gone. Match with `sweep.match`: `.syntax = .git` for git's `pathname` flag and `.git_text` without it, `.case = .ascii_git` for `case_fold`.

- `lfs.Settings.fetch_include` and `fetch_exclude` hold `lfs.FetchPattern`s, which `Lfs.load` compiles (or `FetchPattern.compile`); `Settings.case_fold` and `lfs.patternMatches` are gone, the case being compiled into each pattern.

- `worktree.ignore.parseLine` takes an allocator and `LineOptions` and compiles the glob; `ignore.Pattern` and `attributes.Rule` carry it as `matcher`. An ignore line is read by git's grammar: a trailing tab stays part of the pattern, where it was trimmed, and a line ending in an escaped backslash and spaces loses every space, where one stayed.

- pin conduit at confirmed per-child scope completion; callers releasing an unfinished contained `program.Child` use its fallible `release`.

- HTTP Streaming.finish consumes its connection on success and failure; callers abort only before finish, and smart HTTP and LFS transfer cleanup with the stream.

- HTTP connect, send and stream take a caller-owned Diagnostic as their last argument (or null), replacing Client.tls_error, proxy_status and proxy_offered; LFS and smart HTTP keep diagnostics with each exchange.

- `program.SpawnHook.start` receives an allocator and `conduit.Child.SpawnOptions`, returns `conduit.Child`, and reports its spawn errors; `terminate` receives that child too. `Running.child` uses conduit's stream accessors and ownership transfers. Conduit links libc on POSIX through its module.

- Odb allocator, format, source, policy and storage fields are opaque state read through `allocator`, `objectFormat` and `settings`; repository configuration is borrowed through `configuration` and changed atomically through `editConfig`, with format/backend checks and ref policy publication shared with refresh; memory-only source changes return `WorktreeConfigChanged` and require a standalone write followed by refresh.

- `Odb.makeDurable` reports foreign hashes as `ObjectFormatMismatch`, distinct from an unexpected object type.

- `reftablestack.isReftableRepository` and `GitDir.refStore` preserve backend-probe I/O refusals; only absent paths select the files backend.

- `sequencer.signs` and persisted sequencer/rebase signing policy preserve configuration value and allocation errors instead of choosing unsigned writes.

- `Repository.requiredFilters` returns configuration value errors instead of treating malformed required policy as optional.

- `Odb.openAt` borrows its directory handle on success and failure; callers that transferred a handle must close their original.

- `CheckoutOptions`, snapshot `OpenOptions` and snapshot `Store` carry durability policy; callers depending on their layouts or constructing stores directly must migrate.

- repository hash/ref fields and ref-store allocator/directory/backend/cache fields are opaque owner state accessed through `objectFormat`, `refStore`, `refFormat` and `reftableOptions`; ref-store construction is fallible and requires `deinit`, including `GitDir.refStore`, with backend selection at construction and write-policy changes through `configureReftable`.

- caller-owned `repo.Diagnostic` includes `signing_stderr`, preserved after a failed commit or tag signing program; layout-dependent callers must review the new field.

- commit, merge, sequencer and rebase options carry optional caller-owned write diagnostics; callers depending on their layouts must review the new field.

- `Repository.coreSettings` and `worktreeRules` return malformed-setting and resource failures; callers must handle their error unions.

- repository commit and tag writes preserve `InvalidSignature` and `MixedHashKinds` in `WriteError` instead of reporting `UnexpectedObjectType`.

- delta results over the size limit return `DeltaSizeLimitExceeded`; `DeltaSizeOverflow` means a size encoding wider than 64 bits.

- a refresh that changes the ref backend returns `RefStorageChanged`, requires reopening and keeps the old configuration and ref store.

- `refreshConfig`, `writeCommit`, `writeTag` and `writeTagWith` take caller-owned `repo.Diagnostic` output; the repository's `unsupported`, `unsupported_len` and `unsupportedSetting` are removed.

- Client.proxy_retry is removed; HTTP proxy retry decisions belong only to the connection attempt that accepted the challenge.

- the root is one module per concern, each holding the modules
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

### Added

- `zig build bench` builds relic's own benchmarks from `bench/`: staging, `write-tree` and `status`, packed reads, SHA-1 and SHA-256, and pack writing. `zig build check` compiles them.

- Promisor remotes told and taken, as git's `promisor-remote` capability does. `transport.promisors` is git's `promisor-remote.c` for the protocol: a served repository with `promisor.advertise` names its promisor remotes with a URL in its v2 capabilities, each with the `partialCloneFilter` and `token` `promisor.sendFields` lists, percent-encoded as git encodes them (`advertisement`), and leaves out of a pack what it lacks once a client says it took one (git's `--missing=allow-promisor`). A client answers with `promisor.acceptFromServer` (`None`, `KnownUrl`, `KnownName`, `All`) and `promisor.checkFields` (`reply`), sends the names it took with every command, writes what `promisor.storeFields` asks into the remotes it has (`partial.storeAdvertised`, `Warning.promisor_stored` with git's text; an invalid filter or a token with control characters is not stored, `Warning.promisor`), and its lazy fetch asks the remotes it took first (`partial.Lazy.Options.accepted`). `clone` and `fetch` take the filter `auto`, recorded as it is and sent as the filter of the first remote taken with one (`autoFilter`). `Session.promisorsTaken` and `promisorStores` say what was answered; `partial.promisorRemotes` now comes from `promisors.remotes`.

- Hidden refs, as git's servers hide them. `transport.hidden.HiddenRefs` reads `transfer.hideRefs` with `uploadpack.hideRefs` or `receive.hideRefs` in the order they are set (`!` to show again, `^` for the name with its namespace, the last match deciding, a trailing `/` dropped). A repository on this machine served through `upload-pack` or read directly leaves hidden refs out of its listing, v0 and v2 (`local.Remote.listRefs`; `listAllRefs` keeps them), a v0 want of a hidden ref's tip is allowed only under `uploadpack.allowTipSHA1InWant` or `allowReachableSHA1InWant`, as git's `is_our_ref` allows it, and a push to one is refused with git's `deny updating a hidden ref` or `deny deleting a hidden ref` (`local.Remote.serve` takes `receive.hideRefs` for a push).

- Received objects checked as git checks them. `object.fsck` is git's `fsck.c` for objects: every message id in git's order with git's level (`Problem`, `Level`, `defaultLevel`), `Rules` with git's strict mode, `fsck.<msg-id>`, `fetch.fsck.<msg-id>` and `receive.fsck.<msg-id>` (`error`, `warn`, `ignore`; `largePathname`'s length; `FsckFatalLowered` for a fatal one lowered, `UnknownFsckMessage` under `fsck.` where `fetch.` and `receive.` warn, `Warning.fsck_unknown_message`) and their `skipList`s, `wanted` for `fetch.fsckObjects` or `receive.fsckObjects` over `transfer.fsckObjects`, and `forTransfer`. A tree's checks are git's whole list (null names, full paths, empty names, `.`, `..`, `.git` as HFS+ and NTFS spell it, zero-padded and bad modes, duplicates, order, long names, symbolic `.gitmodules`, `.gitattributes`, `.gitignore` and `.mailmap`), a commit's and tag's are git's (a NUL in a commit, a tag's name, tagger, `gpgsig` and extra headers too), and a commit or tag git's parser cannot read is refused before any level is asked (`Finding.problem` `null`). `Found` gathers the `.gitmodules` and `.gitattributes` trees name, and `checkBlob` reads them as git does: submodule names, urls, paths and `update` commands, the entries before a parse error included (`Config.parseTextUntilError`), and `.gitattributes` size and line length. `inspect`, `checkObject` and `checkFoundObject` replace `check`. `indexpack.Options.fsck` replaces `check_objects` (`null` checks nothing, `fsck.baseline` by default), `promised` takes a missing found blob as a promisor's and `warnings` keeps what the rules make warnings (`Warning.fsck`); a found blob is read back from the pack before it is kept, and a bad or missing one is `error.MalformedBlob`. `fetch`, `clone`, the lazy fetch and a submodule's transport take `check_objects: ?bool`: `null` reads `fetch.fsckObjects` or `transfer.fsckObjects` and `fetch.fsck.*`, git's strict checks when on, `fsck.baseline` when unset, nothing when off.

- Shared repositories, templates and identities, as git has them. `core.sharedRepository` (`umask`, `group`, `all`, an octal mode, git's `1` and `2`; `error.InvalidSharedMode` for a mode the owner cannot read and write) gives what a repository writes git's permissions: loose objects, packs, indexes, reverse indexes, commit-graphs and bitmaps read-only as git leaves them, refs, logs, `packed-refs`, reftables, the index, the configuration (whose old mode a rewrite keeps, as git's does) and every directory made, through `repo.fs.Shared`, `adjustShared`, `makeDirs`, `readOnlyObject` and `LockFile.Options.shared`; `Repository.shared` holds the setting. `InitOptions.template` copies a template directory as `git init --template` does (dotfiles skipped, nothing replaced, links kept, a `config` of a format git takes carried on with git's own values set into it), `InitOptions.shared` is `--shared`, written with `receive.denyNonFastforwards`, `ignore_case`, `symlinks` and `precompose_unicode` record what a caller probed, and `repo.templateDir` reads `init.templateDir`. `commit.template` reads `commit.template`, and `commit.Options.template` refuses a message that is that template unedited (`error.TemplateUntouched`), as git does when the message came from it. `repo.ident.signature` decides an author or committer as git's `ident.c` does, `user.useConfigOnly` refusing a name or email the configuration does not give (`NoNameGiven`, `NoEmailGiven`).

- Trailers, as git reads and writes them. `commit.trailer` is git's `trailer.c`: the block found as git finds it (the last paragraph when all trailers, or a quarter with one of git's own or a configured name, the title never, a `---` divider, trailing comments and a scissors line before it), `process` as `git interpret-trailers` with `--trailer` placed by `--where`, `--if-exists` and `--if-missing`, `--trim-empty`, `--only-trailers`, `--only-input`, `--unfold`, `--parse` and `--no-divider`, `processFile` with `--in-place`, and `Settings.load` reading `trailer.separators`, `trailer.where`, `trailer.ifExists`, `trailer.ifMissing` and every `trailer.<name>.key`, `.where`, `.ifExists`, `.ifMissing`, `.command` and `.cmd`, a command run through the caller's `Commands` (`error.TrailerCommandNeedsPrograms` without them). `pretty` writes `%(trailers)` with `key`, `only`, `unfold`, `keyonly`, `valueonly`, `separator` and `key_value_separator`, and `refs.filter` writes `%(trailers)` and `%(contents:trailers)`. `commit.Options.trailers` is `git commit --trailer` (`error.InvalidTrailer` for an empty one or one with no key). Signing off, `-x` and a shortlog by trailer read trailers by the repository's rules: `message.conformingFooter`, `appendSignoff` and `appendCherryPicked` take `trailer.Settings` (`message.trailerSettings` reads them) where they took a comment string, `message.trailers` and `trailerBlock` are gone for `trailer.iterate` and `trailer.block`, and `shortlog.Options.trailers` replaces `comment` and `trailer_config`, with `TrailerConfigUnsupported` gone and `configured` taking an arena.

- Ref listings, as git makes them. `refs.filter` gathers refs as git's `ref-filter` does — by kind, by `for-each-ref`'s path patterns or the globs `branch` and `tag` match, `exclude`, `points_at` through tags, `contains`, `no_contains`, `merged`, `no_merged`, `start_after` and the root refs — sorts them by any key, the last first, with git's `versioncmp` and `versionsort.suffix` (or `versionsort.prereleaseSuffix`), `--ignore-case` and a detached `HEAD` first, and writes each with every atom git has for refs: `refname` and `symref` with `short` (git's `shorten_unambiguous_ref`), `lstrip` and `rstrip`, `objectname`, `objecttype`, `objectsize` and `:disk`, `deltabase`, `tree`, `parent`, `numparent`, `object`, `type`, `tag`, the people with `mailmap`, `trim` and `localpart`, dates in every mode, `subject` and `:sanitize`, `body`, `contents` and its parts, `raw`, `describe`, `signature` and its parts, `upstream` and `push` with `track`, `trackshort`, `remotename` and `remoteref`, `flag`, `HEAD`, `worktreepath`, `ahead-behind`, `is-base`, `*` atoms on what a tag peels to, `align`, `if`, `then`, `else` and `end`, under `--shell`, `--perl`, `--python` or `--tcl`. `listRefs`, `listBranches` and `listTags` are the three commands, `branch.sort` and `tag.sort` included, and `branchFormat` and `tagFormat` the formats `git branch` (with `-v`, `-vv` and its detached `HEAD` descriptions) and `git tag -n` build. `%(color:...)` writes nothing and `%(trailers)` is refused by name. `object.gitdate.show` is git's `show_date` in every mode, `relative` and `human` and `-local` against a caller's `Clock`, and `Odb.placement` says where an object is kept: its size on disk and a delta's base.

- Range-diff, as git makes it. `patch.rangediff.write` compares two ranges (`Range`, `<base>..<tip>`; git's `<base> <old> <new>` and `<old>...<new>` are two of these) and writes what `git range-diff` writes: each commit's patch as git's `read_patches` makes it out of `git log -p` (the mailmap's author, the message as `--pretty=medium` shows it, the notes, a ` ## <file> ##` section per file with renames, mode changes, deletions and binary files named), identical diffs paired first as git's hash map pairs them, the rest by git's Jonker-Volgenant solver over the same costs, ties and all, and the pairs in the new range's order, each followed by the diff of its two patches with `@@` lines naming the section. `compute` gives the pairing alone. `creation_factor`, `left_only`, `right_only`, `notes`, `max_memory` (`error.RangeDiffTooLarge`) and `patch` are git's options. `revwalk.Sort.date_order` is `git rev-list --date-order`. `diff.Options.function_line` takes a caller's rule for the text after `@@`. `patch.format.configuredDiff`, `configuredRenames`, `logMessage` and `logText` are what `git log -p` reads and shows with nothing asked.

- The file monitor, as git uses it. `worktree.fsmonitor.refresh` asks it what changed since the index's token and takes what it names, a directory with everything under it, out of what it vouches for, keeping its new token: git's hook from `core.fsmonitor`, run through the shell in the working tree with protocol 2 (a token, a NUL, the paths) or 1 (the paths, the question's time as the token), 2 tried before 1 unless `core.fsmonitorHookVersion` says, a lone `/` or a failure making every file be looked at (`fsmonitor.configured`); or a program's own `ChangeSource`, asked the same question. `StatusOptions.fsmonitor` does that first, then takes a file the monitor vouches for as the index has it and vouches for a file found unchanged; under `untracked = .no` it looks at the other files one by one and reads no directory. The index reads and writes `FSMN` (`Index.fsmonitor_token`, `Entry.fsmonitor_valid`, version 1 read, version 2 written, byte for byte as git writes it after the untracked cache), believes it only once refreshed, and says in `fsmonitor_changed` when git would write the index for it. It was kept as opaque bytes, whose bitmap stopped matching the entries once they moved. `core.fsmonitor=true`, git's own daemon, is `error.FsmonitorDaemonUnsupported`.

- Octopus merges, as git makes them. `merging.startHeads` merges several commits (`start` is one): the ones `HEAD` or another already reaches are dropped as git's `reduce_parents` drops them, one left is merged by ort, and two or more by `merge.octopus`, git's `merge-octopus` — each head against the result so far, a first fast-forward taken whole, `read-tree -m --aggressive` and then `merge-one-file` (no renames, `git merge-file`'s merges at its level, labelled with the names of its temporary files), only the last head allowed to leave conflicts; a conflict earlier, or a head sharing no history, is `error.OctopusFailed` with nothing written. The commit lists `HEAD` only when no head contains it or `--no-ff` is asked; the message is `fmt-merge-msg`'s for several heads (`Merge branches 'a' and 'b', tag 'v1'; commit 'abc1234'`), the reflog `merge <heads>: Merge made by the 'octopus' strategy.`, and a stop writes every head into `MERGE_HEAD`. `merging.conclude` drops a parent another reaches unless `MERGE_MODE` is `no-ff`, as `git commit` does. `merging.upstreams` gives every `branch.<name>.merge`; `upstream` and `MultipleUpstreams` are gone. A rebase's `merge` line with several labels makes the octopus as git's sequencer has `git merge -s octopus` make it, and reuses an original whose parents are unchanged; `OctopusMerge` is gone. `merge.BlobOptions.join_without_alnum` is `git merge-file`'s level. Add `threeway.applyOctopus`.

- LFS custom transfer adapters run as git-lfs runs them. `lfs.customtransfer.<name>.path` and `.args` (through the shell), `.concurrent` (`lfs.concurrenttransfers` processes, all started at once, or one) and `.direction` define them; add `lfs.lfscustom`. A batch request offers them beside `basic` (`transfers`), and an answer naming one hands its objects to the processes with the batch's actions; `lfs.<url>.standalonetransferagent` (or `lfs.standalonetransferagent`) names one that is used with no API at all, its actions `null`. Each process gets git-lfs's line-delimited JSON as its Go writes it — `init` (an error answer is `error.LfsAdapterInitFailed`), `upload` with the object's path in the store, `download`, `terminate` — and its `progress` and `complete` answers are read; a downloaded file is checked against the object's name on its way into the store, and an upload's verify action is still sent. The tus adapter, and a name the configuration does not define, are still `error.LfsTransferUnsupported`.

- Remote helpers run as git runs them: `<helper>::<address>`, a `<scheme>://` URL for a scheme relic does not speak, and `remote.<name>.vcs` start `git-remote-<name>` from `PATH` with the remote, the address and `GIT_DIR`, as `protocol.<name>.allow` permits (`ext` never by default; `error.TransportNotAllowed`). Add `transport.remotehelper` and `url.helperOf`. A helper that can `connect` carries the git protocol like ssh; otherwise `list`/`list for-push` give the refs (`?`, `@<target>`, `unchanged`, `:object-format`), `fetch` has the helper write the objects, `import` reads its fast-import stream through `fastimport` (answering `bidi-import` on its input) and takes the values from its private refs, `push` sends `push [+]<src>:<dst>` lines and `export` writes a `fastexport` stream with the helper's marks, the `ok`/`error` lines being the report and the private refs following unless `no-private-update`. `fetch`, `clone`, `push` and the lazy fetch hand the session the repository (`Options.repository`, `who`, `cloning`); a clone through a helper makes the repository first, as git does. `fetchpack.Request.want_names` and `Session.PushRequest.sources`/`force` carry what a helper is asked by name; `Session.fetchedValue` is what an import brought. `stateless-connect` and `get` are not used.

- Add `fastimport` and `fastexport`: git's fast-import streams read and written. `fastimport.import` reads every command `git fast-import` reads — `blob`, `commit` with `M`, `D`, `C`, `R`, `deleteall` and `N` (a notes ref's fanout following its count), `tag`, `reset`, `alias`, `checkpoint`, `progress`, `done`, `get-mark`, `cat-blob`, `ls`, `feature` and `option git` — into one pack per checkpoint, updates a branch only when the new tip contains the old (or with `force`), and returns the branches left as `Report.rejected`; the dates are `raw`, `raw-permissive`, `rfc2822` or `now`, the marks files are git's, and a stream's own marks files need `allow_unsafe_features`. `fastexport.write` writes git's stream for a set of refs and exclusions, byte for byte: sources, topological order, marks, `-M`/`-C`, `--no-data`, `--full-tree`, `--mark-tags`, `--signed-tags`/`--signed-commits`, `--tag-of-filtered-object`, `--reencode=no`, `--refspec`, `--reference-excluded-parents`, `--show-original-ids`, `--progress`, `--use-done-feature` and the marks files. Refused by name: commit signature checking on import (`*-if-invalid`), `rewrite-submodules-*`, `export-pack-edges`, and on export `--anonymize`, a path limit and `--reencode=yes`.

- `fetch`, `clone` and `push` take a `proxy` (`transport.Proxy`, also on `transport.Options`): `.auto` is git's choice from `remote.<name>.proxy`, `http.proxy` and the environment; `.none` goes direct whatever they say; `.url` goes through that proxy over the configuration, the environment and `no_proxy`. It is for HTTP remotes; ssh and local ones do not read it. README Scope names GSS-API (Kerberos) to a SOCKS5 proxy as not offered.

- `pretty` is public, and its `Context` carries what git reads besides the commit: `mailmap` for `%aN`, `%aE`, `%aL` and the committer's; `decorations` (`Decorations.load`, every ref, `HEAD` and the shallow commits as git loads them for a format) for `%d`, `%D` and `%(decorate:<options>)`; `notes` for `%N`, which without them stands as it is, as in `git archive`; and `signer` for `%G?`, `%GG`, `%GS`, `%GK`, `%GF`, `%GP` and `%GT`, which a signed commit without one is `error.SignatureNeedsSigner`. `archive` loads each for an `export-subst` file the first time a placeholder asks, the signer from `Options.programs`. `tar.umask=user` is the process's umask, read as git reads it or given as `Options.user_umask`; `UnsupportedTarUmask` is gone, and a value that is not a number is `error.InvalidTarUmask`.

- `grep` matches back-references (`\1` to `\9`, in basic and extended expressions) as glibc's matcher does, the furthest end of any way the groups can be taken; a search past the budget of work is `error.PatternTooComplex`. `Options.expression` takes `--and`, `--or`, `--not` and parentheses as git's command line gives them, combined by git's grammar, `error.InvalidExpression` where git dies; `all_match` keeps the files where each term of the top-level either-or matched. `show_function` (`-p`) and `function_context` (`-W`) show the function lines git finds: the `diff` driver's `funcname` or `xfuncname`, git's built-in drivers by name, else its default; a pattern that does not compile is `error.InvalidFunctionPattern`. `Options.perl` takes a caller's `Matcher` for `-P`, which without one is still `error.UnsupportedPerlRegex`. `UnsupportedBackreference` is gone; `patterns` defaults to none.

- `git bisect` takes pathspecs as git does: `BISECT_NAMES` holds them as git writes them (what follows the revisions, a `--` included, from two arguments on), the walk is simplified to the commits that change them, and a commit that does not is neither counted nor tested. Add `revwalk.Walk.paths` and `Commit.treesame`: history simplified by paths as git's default `try_to_simplify_commit` does it, a merge the same as a parent that matters following that parent alone.

- `shortlog` groups by `--group=format:<format>` (or a group given with `%`) through `pretty`, the formats before the author's and committer's groups as git orders them, for commits added by name; `addCommit` with a format group is `error.FormatGroupNeedsName`. `FormatGroupUnsupported` is gone.

- `bundle.create` takes a `sparse:oid=` filter, its blob named by any revision expression, the patterns deciding which blobs go in as git's sparse filter decides; a name that is no blob is `error.SparseBlobMissing`, where git cannot access the sparse blob. `SparseFilterUnsupported` is gone.

- `working-tree-encoding` converts UTF-16, UTF-16LE, UTF-16BE, UTF-32, UTF-32LE, UTF-32BE and git's UTF-16LE-BOM and UTF-16BE-BOM files to UTF-8 when they are stored and back when they are checked out, between the filter and the line endings both ways, as git's `convert.c` does. git's byte order mark rules hold: UTF-16 and UTF-32 need one on the way in, the names that state an order may not have one, and a file that breaks them, or does not decode, is `error.WorkingTreeEncodingFailed` when it is stored and taken as it is by a status; UTF-16 and UTF-32 are written with a mark in the byte order the platform's git writes (little-endian on Linux, big-endian elsewhere); an empty file is not converted. A value of true or false is `error.InvalidWorkingTreeEncoding`, which git refuses too. Any other character set is still refused by name. Add `worktree.encoding`.

- `<ref>@{<date>}` and `@{<date>}` pick the reflog entry in force at a date, as `git rev-parse` does: the date read by git's `approxidate` (`yesterday`, `3.days.ago`, `last Friday at noon`, `6am yesterday`, ISO and RFC 2822 dates, `@<secs>`; held to git's own t0006 vectors), a number from 100000000 on read as seconds, and git's answers at the log's ends. `revparse.resolveAt` takes the time now and the local zone; `resolve` reads the `Io`'s clock and takes UTC. `RevisionDateUnsupported` is gone.

- Reach HTTP(S) remotes and LFS through SOCKS4, SOCKS4a, SOCKS5 and SOCKS5h proxies, with local or proxy DNS, URL credentials and TLS inside the tunnel, as curl does for git; honor `remote.<name>.proxy` and name SOCKS refusals. closes #1.

- Write and verify full and split commit-graphs, with git's size and commit-count merge rules, corrected commit dates and overflow, and changed-path Bloom filters v1/v2; read split chains, and apply `gc.writeCommitGraph` and `fetch.writeCommitGraph`.

- Write multi-pack indexes with git's preferred-pack and duplicate selection, RIDX and BTMP chunks, and separate MIDX repack and expire operations that retain kept and cruft packs.

- Write and read pack and MIDX reachability bitmaps, with git's EWAH, commit selection, XOR search, hash cache and lookup table. Object enumeration and `revwalk.count` / `countObjects` use them when applicable; fix EWAH reading to accept compressed runs longer than the encoded word array.

- Add `diff.blame.file`: which commit each line of a file comes from, the line it was there and the path the file had, as `git blame` gives them. It walks history as git's blame does, newest commit first, a line passing to the first parent whose copy leaves it unchanged by git's line diff, and follows a file to the path a whole-file rename gave it unless told not to (`--no-follow`). `-M` and `-C` are off, as in git. Tested line for line against `git blame --line-porcelain` on fixtures and on random histories with merges, renames and repeated lines.

- Add `revwalk.bisect`: `git bisect` start, good, bad, skip, next, reset, log, replay and run, with git's `BISECT_*` state files and refs, the commit git picks (skips and `--first-parent` included), git's merge-base check and terms, and git's output; a pathspec is refused by name.

- Add `revwalk.bisect`: `git bisect` start, good, bad, skip, next, reset, log, replay and run as git 2.56 does them, `--reset-when-found` included, with git's `BISECT_*` state files and refs, the commit git picks (skips and `--first-parent` included), git's merge-base check and terms, and git's output; a pathspec is refused by name.

- Add `revwalk.Walk.first_parent` (`--first-parent`), `Walk.isHidden`, and `revwalk.mergeBasesMany`, git's `get_merge_bases_many`.

- Add `transport.bundle`: bundles created (v2 and v3, with `@object-format` and `@filter`), read, verified, listed and unbundled as `git bundle` does, the header byte for byte and the prerequisites git's boundary in git's order; a fetch or clone from a path that names a bundle reads it as git's bundle transport does.

- Add `commit.notes`: notes read, added, appended, copied, removed, pruned and merged (`manual`, `ours`, `theirs`, `union`, `cat_sort_uniq`) as `git notes` does, with git's in-memory notes tree so the fanout written is git's, other entries in a notes tree kept, and `formatNote` for the notes `git log` shows.

- Add `revwalk.describe`: `git describe`'s candidate search, depth and output under every option, a blob described by the commit and path that first hold it, `--dirty` and `--broken` for `HEAD`, and `--contains` through git's `name-rev` naming; a tag whose object gives another name is reported as the new `warning.Warning.tag_known_as`.

- Add `revwalk.shortlog`: `git shortlog` grouped by author, committer or trailer, sorted, counted and folded as git does it, and `commit.message.trailers`, the trailers of a message as git iterates them.

- Add `revwalk.mailmap`: `.mailmap`, `mailmap.blob` and `mailmap.file` parsed and looked up as git does, a long line read in `fgets`-sized pieces included.

- Add `patch.apply`: `git apply` to the working tree, the index or both, with `--3way`, `--reject`, `--check`, `-R` and git's whitespace rules, and `patch.parse` for the patch itself.

- Add `patch.format`: `git format-patch`, byte for byte, cover letter and base information included.

- Add `patch.am` and `patch.mail`: `git am` with its `rebase-apply` state, over `git mailsplit` and `git mailinfo`.

- Add `grep`: `git grep` over the working tree, the index or a tree, its output git's.

- Add `archive`: `git archive` as tar or zip, the tar and a stored zip git's bytes.

- Add `clean`: `git clean`, with git's walk, its lines and its handling of ignored paths and repositories inside the tree.

- Add `Odb.readInto`, which reads an object into a buffer the caller keeps, and `Pack.readAtInto`.

- Add `pack.Deflater` and `Writer.addDeflated` for entries deflated ahead of the writer.

- Add `transport.remote.defaultFetchRefspec`: the refspec `git remote add` and clone write for a remote; clone uses it.

- Add `Repository.gitDirOf`: the per-worktree directory a working tree names, through a `.git` file too, without reading the repository.

- Add `transport.remote.Remote.trackingRef`: the ref that tracks a remote's ref by its fetch refspecs, as git's `remote_find_tracking` decides; push uses it.

- Add `refs.Store.watchScopes`: the folders a change to `HEAD` or a ref lands in, loose, packed or reftable, a linked worktree's shared `packed-refs` included.

- Add `Repository.ignoreSources` and `Repository.indexPath`: the files `loadIgnore` and `openIndex` read, as absolute paths, a linked worktree's own index included.

- Add `ignore.Checker`, a working tree's ignore rules asked one path at a time, reading each folder's `.gitignore` once and only after it reads; checkout's obstruction check uses it.

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

- The `http` build option (on by default) brings uplink, cloak and strand, which are now lazy: a program built with `.http = false` fetches none of them, and an `http` or `https` remote is `error.HttpUnavailable`.

- A server's JSON (LFS batch, locks, `git-lfs-authenticate`, a custom transfer agent's answers, a refusal's reason) is read through [strand](https://github.com/pedronaugusto/strand), within its limits on input, depth, items, strings and memory, where it was read without any. It is still read as git-lfs reads it: members a type does not name are ignored, and one given twice is its last.

- The grammar of a hunk is [parallax](https://github.com/pedronaugusto/parallax)'s. relic still finds each file's header and reads its extended lines, modes and binary patches, and reads the hunks after it with `parallax.patch.scanHunk` in git's dialect (counts end a hunk, `\ No newline` is the one line after a line, a hunk that changes nothing is refused unless `--recount` takes its counts from its lines); applying walks a hunk's lines with `HunkLines`. What patches are accepted and refused, and the line a refusal names, do not change. `patch_parse_64_files` times reading a patch.

- The package ships `build.zig`, `build.zig.zon`, `src`, the license, README and changelog, which is all a consumer's build reads.

- Attribute pattern sets compile once per file and keep one matching cache, so
  repeated lookups reuse the states earlier paths built. Assignment parsing and
  macro expansion avoid temporary growth where their sizes or continuations are
  already known.

- Shared ERE parsing allocates nodes in stable blocks and avoids clearing
  search marks twice.

- Warp decodes LFS zstd bodies with the frame-declared window and the existing 512 MiB refusal. Test fixtures use the adopted codecs, while external zlib and Git parity remain checked.

- Loose reads verify the Adler checksum before returning content. Warp owns loose-object streaming and compression; partial header reads decode only their bounded output. Compressor and writer buffers have one database or stream owner.

- Local push retains the copied pack until all receiver ref transactions and
  shallow updates finish, including rollback. Cancellation propagates after ref
  locks are released; the keep token's uncancelable cleanup then runs.

- Native LFS operations use the supplied Io for cached process pipe reads and
  writes, including failures and cancellation. Breaking: SSH connection stream
  operations take Io per call. Process.streams borrows native buffered streams
  for an exclusive operation; a foreign transport is explicitly refused.

- Native LFS filtering and clone/push composition live at `lfs.filter`,
  `lfs.clone` and `lfs.push`. Lower operations accept neutral owner callbacks;
  native LFS selection is explicit. Checkout's missing-content diagnostics use
  `native_fallbacks` and `Report.native_missing`.

- Received packs are retained through ref publication and cancellation. LFS lock
  pagination refuses a cursor it has already followed, on HTTP and over SSH. The
  boolean and search ERE adapters share one core.

- Line diffs and three-way merges are [parallax](https://github.com/pedronaugusto/parallax)'s, git's xdiff output byte for byte; relic's own differ and merge are gone. A unified diff under a whitespace option prints a context line as the new side has it, as git does, where it printed the old side's; `\v` and `\f` are text to the whitespace options and stay at the end of a hunk heading, as git's whitespace class has them. A merge side larger than git's `MAX_XDIFF_SIZE` (1023 MiB) is merged as binary data is, as git's `ll_merge` does. `numstat`, `blame` and range-diff take every diff in one reusable workspace. Against the code before: unified bodies take 0.83 of the time, line counts 0.82, content merges 0.55 and a blame through 200 commits 0.78.

- Globs are matched by [sweep](https://github.com/pedronaugusto/sweep), git's wildmatch in time linear in the subject, for ignore and attribute lines, pathspecs, sparse patterns, `includeIf` conditions, ref, branch, tag and `describe` filters, `merge.suppressDest`, `apply --include`/`--exclude`, `submodule.active` and LFS fetch patterns. A pattern of any length is matched as git matches it: one nested past 1024 stars, which the old matcher refused, and an LFS fetch pattern longer than a kilobyte, which named nothing, now match what they name. Ignore, attribute and sparse patterns and pathspecs compile their globs once, when they are read: per path, an ignore decision costs 0.54 of what it did and an attribute lookup 0.56, and reading a file costs about 1.8 µs a line more. An ignore or attribute pattern whose `**` follows a literal start, such as `foo**/bar`, is decided as git 2.52 decides it: the `**` stays inside its own component, so `foobar` and `foo/x/bar` are not matched, where they were as older git matched them.

- The suite finds a hosted job's git and git-lfs while it runs (`RUNNER_TEMP`, `RELIC_GIT`), where the build set `PATH` and `RELIC_REQUIRE_SIGNERS` on the test run and Zig 0.17 kept them in its cached configuration. The helper programs reach the suite as paths the build tracks, not as installed copies. `ci/linux.Dockerfile` is gone, with `zig build check-git-flags`, which compared it to the hosted installer; `zig build check-ci-setup` tests the installer.

- Requires Zig 0.17.0, and conduit's 0.17 release, whose API relic passes through: `program.readAvailable` takes the `Io` first (`readAvailable(io, file, buffer)`), and a `program.SpawnHook`'s `start` and `terminate` meet conduit's `Child` as it now is, ended with `finish` and `deinit`, `killWait` taking a `std.Io.Duration`. The TLS client copy is std 0.17.0's with the same recorded diff, so it takes std's record-length, empty-plaintext and nonce fixes. `zig build test -Dtest-case=...` is gone with the named Windows comparison groups: the hosted jobs now split the suite test by test.

- Supported git: 2.39 and newer (was 2.30). The floor is the oldest git a supported LTS distribution ships, Debian 12's, and is reviewed yearly. The library's behaviour does not change: nothing in it existed only for git older than 2.39.

- relic's `build.zig` no longer imports `preflight` at the top: a project that depends on relic builds without fetching it.

- The worktree, repo, config, submodule and diff take the allocator, then `Io`, then the rest, and name what they expose through their owners (`Self.Error`, `rename.Error`, the cone's `DirContext`); the sets themselves are unchanged. `worktree.sparsecheckout.settings`, `set`, `add`, `reapply`, `init`, `disable` and `list` take `Io` before the repository; `worktree.filter.runCommand` and `filter.Process.start` take the allocator and `Io` before the `Programs`; a `fsmonitor.ChangeSource.queryFn` takes the arena before its context; a `submodule.Transport`'s `cloneFn` and `fetchFn` take the allocator and `Io` before the context, and `refs.Peeler.peel` and a `worktree.SubmoduleProbe`'s `inspectFn` take `Io` before the context. `repo.IgnoreSources` is declared at the top of `repo`, where it was `Repository.IgnoreSources`, and `diff.rename.GitMapIterator` is the walk a `GitMap.Iterator` names. Every `deinit` in these leaves its value undefined (`repo.Diagnostic`, `submodule.submoduletransport.Transport` among them), so a second release is caught. `worktree.worktrees.remove` reports a working tree it could not delete, after removing the administrative directory as git does, where the error was dropped; a symbolic link or file written over a read-only file on Windows clears it as checkout does; and `fastimport.Marks.put` asserts that a mark is not zero, the mark `Marks.parse` already refuses.

- Storage takes the allocator, then `Io`, then the rest, and names what it exposes. `refs.reftablestack.read`, `list`, `readLog`, `logExists` and `appendLog` take the allocator and `Io` before the store, and `prepare`, `commit` and `releasePending` take `Io` before the transaction; `refs.reflog.exists` takes the allocator, then `Io`, then the git directory; `odb.pack.Pack.headers` takes the allocator before `Io`. `odb.ObjectStream` is the writer `Odb.writeStream` begins (`Odb.Stream` names it still), `index.CacheTreeNode` a `CacheTree`'s directory (`CacheTree.Node` names it still), and `revwalk.mailmap.Folded` and `refs.reftable.ObjectKeyOrder` are public. Every `deinit` in storage leaves its value undefined, so a second release is caught. A pack written in a SHA-256 repository is named in full, where its file names overflowed their buffers; `Odb.makeDurable` syncs a pack of any name `Pack.open` accepts, where a name over 123 bytes overflowed; a watch scope below a worktree of any name is matched; and `hash.Hasher.updateHeader` takes a type name of any length.

- Merge, commit and patch take the allocator, then `Io`, then the rest. `commit.commit` and every `stash` call (`list`, `get`, `inspect`, `show`, `push`, `apply`, `pop`, `applyStash`, `drop`, `clear`) take `Io` before the repository, as does `sequencer.commitResolver`; `notes.Notes.list` and `prune` take the allocator before `Io`; `merging.upstreams` and `rerere.afterStop` (`merging.runRerere`) take their arena second, after `gpa`. `rerere.KeyOrder` and `ort.KeyOrder`, the order their records are sorted in, are public. A merge reset in a SHA-256 repository (`sequencer.resetMerge`, under `skip` and `abort`) records its whole target in the reflog, where it failed on a buffer one byte short. A directory a merge, a reset or rerere could not create or remove, a reference a finished rebase could not delete, and a `.gitattributes` `format-patch` or `range-diff` could not read are errors, where they were passed over; an empty submodule directory and an emptied `rr-cache` entry are still removed only when empty.

- Transport and LFS name what they expose and invalidate what they release. `remotehelper.Helper.OptionValue` and `Helper.Answer`, the form and the answer of `Helper.option`, are public. `httpclient.Response.conn` is `*Connection`: a response always has one until `deinit`. Every `deinit` in transport and LFS leaves its value undefined, so a second release is caught; `auth.Failure.begin` still empties a failure for reuse. `objectfilter.collect` takes its output arena second, after `gpa`, and its commits as `objectfilter.CommitTree`. `Session.fetch` takes `want_names` empty or one per want, and `Session.push` takes `sources` and `force` empty or one per command. A protocol v0 server that answers NAK to a flush the client never sent is `error.ProtocolError`, where it overflowed a counter. `lfs.locks.lock`, `unlock` and `unlockPath` take their arena first, `ssh.explain` its `Io` before the connection, and `pktline.print` its format and arguments before the writer. Callbacks take the allocator or `Io` before their context: `credential.Prompt.ask`, `Connection.VTable.close`, `lfs.Fetcher.fetchFn`, `Odb.Lazy.fetch`, `hooks.LfsHooks.run` and `program.SpawnHook.start` and `terminate`.

- Share the Zig CI gate through preflight, with requested fast runs and full merge checks.

- A merge carried into the working tree, as merge, cherry-pick, revert and rebase make one, changes the index where the merge changed it and nowhere else: what changed is the merged tree against ours by a walk past the subtrees they share, the index is checked against ours through its cache tree where that is valid, and only the `.gitattributes` above a written path are read. It flattened ours and the merged tree, twice, and built the index again from the whole merged tree for every commit. `Index.addMany` merges the entries it adds into the sorted list rather than sorting the whole list again.

- A checkout writes its files on tasks of the caller's `Io`, four by default (`CheckoutOptions.workers`, as git's `checkout.workers`) once a batch holds a hundred files (git's `checkout.thresholdForParallelism`), in batches whose bounds depend only on the files, so the files written, the index and the error returned are the same whatever the count, and a path that fails leaves every path before it written; each file is still written beside its place and renamed over it, so a reader sees the old bytes or the new. A path the index already has as the tree has it is no longer looked at on the disk unless `force` asks. Files are created with git's 0666 or 0777 and the umask trims them as it trims git's; they were set to 0666 or 0777 after creation whatever the umask said, which left every checked-out file writable by everyone.

- A lock names the process that holds it in its own first bytes, `pid <n>`, which the new contents write over, where it wrote `<path>~pid.lock` beside every lock and removed it after: a lock now costs one file, not two, and a transaction of a thousand refs half the directory changes. `staleReport` reads the name from the lock.

- A repository handle keeps each commit it reads, its tree and parents, as git keeps a parsed commit: `revparse`'s `main~40` reads forty commits once rather than once per expression, and `commitTree` reads none twice. At most 8,192 are kept before the handle starts over. Add `Repository.commitInfo`.

- A snapshot capture writes the blobs past git's unpack limit of a hundred into one pack in the private store, and then every tree into a second, where it wrote every blob, and every tree it borrowed from the source, as a loose object: the first capture of a twenty-thousand-file tree was forty thousand filesystem calls before any reading. The store still owns every tree and blob before the capture returns. A capture that brings fewer new blobs writes them loose, so a store captured often gathers no packs. Add `NewBlobs.auto`, which `addAll` does this with, and `CacheTree.rebuildInto`.

- `merge.fromOrt` stages the merged tree's clean paths in one sorted pass; it inserted them one at a time in hash-map order, a move of the rest of the index for almost every path, which on a twenty-thousand-file tree was most of each commit a rebase, cherry-pick or merge made.

- Rename and copy detection cuts each blob into spans once, as git keeps its `cnt_data` on the file, and scores a pair by one pass over the two sorted span lists; it counted both blobs into hash maps again for every pair it scored. Add `similarity.spans`, `similarity.scoreSpans` and `similarity.sizesRuleOut`; `similarity.score` gives the scores it gave.

- `diff.tree` walks the two trees side by side as git's tree diff does, and passes over a subtree both hold unchanged without reading it; it read and listed every path of both trees. A diff of two commits of a large tree costs what differs between them, and so do the patch ids `rebase` compares.

- `Odb.findPrefix` finds an abbreviated name in a pack index by bisection and looks at the one name after it; it walked every name past the match to the end of the index.

- A ref store keeps `packed-refs` parsed between lookups and checks it with a stat of the file before each one, as git's files backend does: the file's identity, size and times, taken from the descriptor the bytes were read through. `read`, `resolve` and `list` no longer read and parse the whole file for every lookup, which made resolving a name in a repository with a thousand packed tags cost a parse of every line, three times over for a name tried under `refs/`, `refs/tags/` and `refs/heads/`. `readPacked` still reads the file afresh, and its listing is now sorted by name, as git sorts a file that does not say it is.

- `Odb.verify` checks each pack on tasks of the caller's `std.Io`: the pack is read forward a batch at a time, one read each, and the tasks check every entry's CRC and every whole object's name from those bytes while one of them runs the pack's checksum on; deltas are still resolved on the calling task. Verifying the bench's large repository takes 64 ms where it took 250.

- A pack written from objects in packs, as `repack` and a local clone or fetch write it, copies what those packs store, as git's pack-objects does (`PackOptions.reuse_packed`, on): a delta whose base is written before it, its chain of copied deltas within `depth`, is neither read, searched nor deflated, and an object written whole is not deflated again; every copy is checked against its pack index's CRC. The choice depends on the objects and their packs alone, so every task count writes the same pack. `collectAll` reads each pack's headers in file order (`Pack.headers`), and `repack` removes only the loose files it found, on tasks. Repacking the bench's large repository takes 0.67 s where it took 1.9.

- Pack entries' CRC-32s are computed eight bytes at a time, with the CPU's CRC instructions on AArch64 and from eight tables elsewhere, where `std.hash.Crc32` takes a byte at a time: 7 ms or 26 ms for 64 MiB instead of 159 on an M3 Max. Writing, indexing and verifying packs use it.

- The delta search encodes its candidates into two buffers each window keeps, and allocates only the delta it chooses: searching tasks no longer wait on each other for the allocator's lock, which took more of a repack's search than the search did. Add `delta.Encoder.encodeInto`.

- Pack writing on tasks searches for deltas on the tasks too. The objects in pack order are cut into groups of at least 512 that end where the path hint changes, and each object is tried against its own group's window only, so every task count still writes the bytes `threads = 1` writes; the serial writer cuts the same groups. Groups cost 0.04% of the pack on a repack of ghostty. A searching task allocates through the database's allocator one call at a time, under a lock, so that allocator still need not be thread-safe.

- A pack keeps up to 32 MiB of the blocks positional reads read, never more than its own size, each allocated when it is first read (`Options.pack_read_cache_bytes`, `Pack.open`'s `read_cache_bytes`, both 256 KiB before): a pack that fits is read at most once in any order, as a map reads it, without the map. Reading 24,000 blobs in name order from a 14.5 MB pack made a read call for nearly every one.

- Inflate builds its Huffman tables as libdeflate does: each code written once and the table doubled by copies, subtables only as large as their codes need, and the code lengths counted while they are read. Building them was a fifth of reading small packed objects; inflating every entry of a 14.5 MB pack takes 73 ms where it took 87.

- `collectLoose` and `collectAll` read the loose trees their hints come from on tasks too, eight megabytes at a time, and parse them in order, so every task count gives the same hints.

- Pack writing on tasks overlaps the batches: while the calling task searches one batch for deltas, the tasks read the next and deflate the one before, so the search no longer waits on reads and compression. Each batch takes a third of `PackOptions.batch_bytes`, three being under way at once; the bytes written are unchanged.

- A pack written from objects already in packs, as `repack` writes it, has their whole objects inflated by the pack tasks too, each task with a decoder and a read buffer of its own; deltas are still resolved on the calling task with the delta-base cache. `collectAll` marks what it found only in packs with the new `PackEntry.in_pack`, so neither it nor `writePack` looks for a loose copy of those first.

- `Odb.readHeader` of a loose object, and the header passes of `collectLoose`, `collectAll` and `writePack`, inflate the object's header and no more, and read at most a kilobyte of the file to do it, where they filled the 64 KiB inflate window.

- A pack of fewer objects than `PackOptions.threads` asks for, and each batch of a larger one, starts no more tasks than it has objects.

- A fetch or clone that copies a repository on this machine writes its pack on the tasks `pack.threads` asks for, as git's pack-objects reads it; unset, one per processor.

- Pin conduit at the version with `Child.exchange` and `processExists`.

- Write packs on tasks of the caller's `std.Io` by default: `PackOptions.threads` is now zero, one task per processor. The tasks read loose objects and deflate entries into buffers the calling task allocates, bounded by the new `PackOptions.batch_bytes`; the delta search and the writing stay on the calling task in pack order, so every task count and every Io writes the bytes `threads = 1`, the unchanged serial writer, writes. A cancel or a failure on any task stops the write and leaves no temporary file.

- `collectLoose` and `collectAll` read headers on tasks too (`CollectOptions.threads`) and pass them on in the new `PackEntry.header`, so `writePack` reads each loose object once; the body of an object found loose is always read from the loose copy.

- Read packs positionally in 8 KiB blocks aligned in the file and kept direct-mapped, 256 KiB per pack by default (`Options.pack_read_cache_bytes`, `Pack.open`'s `read_cache_bytes`), with entries of 64 KiB or more streamed apart: a pass whose delta-base cache holds at least what an earlier pass's held reads no more calls and no more bytes. Each read uses the Io of the call that makes it.

- Scan one 120-commit delta chain in every build mode, single-threaded, so the cold and warm read bounds measure the delta cache rather than where the read window sat, and name the failed bound with every count.

- Fix git's author and committer dates in every test fixture, so a fixture's object names do not change from run to run.

- Run a program through conduit's `Child.exchange`: one deadline over input, run, reap and drain, its allocations serialized by conduit.

- Ask conduit whether a lock holder's process exists, Windows included.

- Apply a program's variables and removals through conduit's environment overrides.

- Count the five new performance checks in Windows source-family coverage.

- Copy only defined compressor state when starting each pack entry.

- Keep small pack entries in the fast decode loop with bounded scratch and exact owned results.

- Limit small random pack reads to 8 KiB of read-ahead while keeping 64 KiB for large bodies.

- Complete packed entry headers across short reads and buffer boundaries.

- Reduce hash collisions and long-match comparisons in delta searches, with larger buffered loose pack reads.

- Keep suffix-related test modules in one Windows family so substring filters do not run them twice.

- Divide remaining Windows tests into five named source families without changing their assertions.

- Start Windows core tests before comparison jobs fill the runner queue.

- Give process execution and transport fixtures one conduit owner.

- Supply concurrency fixtures through build options without importing the test root.

- Reject undeclared dependencies, duplicate layer membership and imports of source executables.

- Keep API namespaces above their implementations and shared storage contracts.

- Split Windows git-comparison corpora across named parallel cases with the same assertions.

- Check named source layers, cycles, entry files and dependency owners during source CI.

- Bound local Zig build caches before builds, retaining downloaded packages and tools.

- Connect timeout and SSH cancellation tests use controlled deadlines and read barriers, with named watchdogs for hangs, instead of elapsed wall-time assertions.

- Process-filter parity tests count only each add's logs, excluding Git write-tree's separate racy-index rechecks.

- Merge, rename/diff and revwalk parity corpora give every seed its own named test and deadline without reducing coverage.

- HTTP counter fixtures release their held mutex when worker readiness times out, and CI reports each stalled test by name before the job limit.

- Unit tests count work and compare results instead of asserting speed ratios or performance ceilings; all measurements and their timing example live in the bench branch harness.

- The warm staging fixture gives its files an earlier modification time than the index instead of assuming two writes cannot share a clock tick.

- GnuPG fixtures use private homes under `.zig-cache/gpg` by default; `-Dgnupg-fixture-root=/short/path` gives long checkouts a short root for agent sockets, and each home is removed after its daemons stop.

- CI runs Debug and ReleaseSafe on every host, ReleaseFast and ThreadSanitizer once on Linux, and ReleaseSmall as a compile check.

- Relic depends on conduit for process spawning, bounded input and output, waiting and termination. Git command preparation, environment scrubbing and caller execution policy remain in relic.

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

- The TLS client is the standard library's with a recorded diff and nothing
  else. The code the added handshake steps call moved out of the copy into
  `src/transport/tls/auth_wire.zig`, and the four doc comments the copy had added to
  std's own declarations are gone, so the copy differs from std only where
  the handshake has to change. `src/transport/tls/Client.zig.diff` is that difference,
  with the SHA-256 of the std file it was taken against; its header states
  the rule for bringing std's fixes across, and `ci/tls-fork.sh` takes the
  diff again.

- The smart HTTP doc comments describe relic's TLS client and its configured client certificates.

- The test TLS front exits when its parent test process ends, including on a
  failed assertion, and explicit cleanup closes its input pipe.

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

- The signing tests' git read the machine's system configuration, which on
  a Homebrew or Xcode git names the keychain as the credential helper. They
  now run in the same isolated environment as the rest of the suite: no
  system configuration, a scratch home, no agents, no prompt. The lock
  helper the concurrency tests start is given that environment too, and the
  gpg tests stop every daemon gpg started for their home rather than only the
  agent.

### Fixed

- A refreshed configuration's `core.sharedRepository` reaches every writer at once (objects, packs, refs, logs, reftable tables, the index): it used to stay what the repository was opened with. `Odb.configureWrites` and `refs.Store.configureWrites` take the permissions and the syncs together.

- `transport.clone` lists its destination through a handle of its own, so the current directory (`Io.Dir.cwd()`) can be cloned into; it used to fail on a handle not opened for listing.

- Percent escapes are read in one place, `text.percent`, with git's `hex2chr`: credential URLs, LFS paths, promisor and filter specs, `.gitmodules` URLs, and the `%xHH` of pretty, trailer and ref formats. Three readers took a sign as a digit, so `%+1` decoded to a byte where git keeps it.

- A remote helper's symbolic refs are recorded after a fetch however it ends; an allocation failure used to drop them silently.

- Both ERE adapters refuse reversed and out-of-range numeric intervals;
  malformed interval syntax remains literal under the extended grammar.
  Interval validation stays in their shared core and never falls back on a
  numeric-bound error.

- Bare merge strategy aliases patience/histogram preserve the existing minimal
  policy, as Git does; diff-algorithm= still replaces it. Durability contracts
  account for Airlock's Linux O_PATH recovery before the successful directory sync.

- LFS presents a client certificate as git-lfs does in three more ways, each found by a test that now serves objects over TLS apart from the API: the certificate for a host is read whatever the URL's scheme, so a key that does not open fails a plain request too; a passphrase that opened a key is remembered, so the helpers are asked once however many hosts the key goes to; and a download or an upload refused at the TLS handshake or by a proxy is tried again, as git-lfs tries any request that got no answer, where it failed at once. A download that breaks off keeps every byte that came before the break.

- `refs.Store.resolve` returns `error.SymbolicRefLoop` for symbolic refs that name each other round, where it freed the name it held twice.

- `describe --match` and `--exclude`, and their `--contains` forms, match without git's `WM_PATHNAME`, as git does, so a `*` crosses the `/` in a tag such as `rel/1.0`, where it stopped at it.

- A host name is looked up with no task waiting on work Zig 0.17 may not run beside it. `httpclient` looks a name up as a task of its own and drains it as it answers; with no task to spare, a libc target asks `getaddrinfo` itself and other targets (Windows, Linux without libc) return `httpclient.Error.ConcurrencyUnavailable`, where a name with more than 32 addresses waited on itself forever. An address still connects anywhere. A name's addresses are tried as tasks that race, and one after another when no task is free, in place of std's `HostName.connect`, which hides the same wait. smart HTTP and LFS report the new error as a failed connection.

- The working tree, configuration, discovery and archive take hostile input as git does. A checkout refuses a tree whose entry stands where another entry's directory goes -- the same name twice, or under `core.ignoreCase` a name that folds to it -- before anything is written (`safepath.Reason.path_collision`), and nothing is written, removed or made a directory past a symbolic link on the disk (`safepath.Reason.beyond_symlink`; a forced checkout replaces the link with a directory, as git's does), in `checkout`, `writePaths`, `writeEntry`, `writeBytes`, `removeEntry`, `applySparse` and a merge's writes; `worktree.realLeadingPath` is git's `has_symlink_or_noent_leading_path` turned around. `safepath.Use.worktree` refuses device names, a trailing dot or space, a colon, a control character, a backslash and a drive letter only on Windows, as git does, so `aux.c` checks out elsewhere; `.git` in every NTFS and HFS+ spelling is refused everywhere, fast-import's paths included. `applySparse` restores a link as a link and a gitlink as its empty directory. Without `core.symlinks` a file where the index has a link stays a link to status and add. Every tree walk stops at `object.max_tree_depth`, git's `core.maxTreeDepth` of 2048, with `error.TreeTooDeep` -- `worktree.flatten` (which said `UnsupportedEntry` past 64), diff (past 64), archive, grep, describe, path-limited revision walks, the object filter, LFS's scan, the sparse index and fast-import's paths, copies and tree writes, which recursed off the stack (`fastimport.Error`, `grep.Error`, `revwalk.Error`, `revwalk.simplify.Error`, `describe.Error`, `objectwalk.Error` and LFS's `FetchError` gain it). An archive of a commit dated before 1970 is a tar with git's unsigned time and a zip refused (`archive.Error.TimestampTooLarge`), where it panicked; a zip past 65535 entries or four gigabytes gets git's zip64 records. Attribute macros expand as git's `fill_one` does -- the last assignment of a line first, each macro once and only when set -- where each mention expanded again, exponentially; `[attr]` lines count only at the top, a later or higher file's definition wins (`Attrs.Macro.precedence`), a `.gitattributes` in the tree is never read through a link, and one past `Attrs.max_file_size` (git's 100 MiB) is passed over. Globs match with git's `dowild`, abort codes included, so alternating `**/` and `*` no longer backtrack exponentially. `worktrees` reads relative paths as `worktree.useRelativePaths` writes them, `remove` and `move` touch only a tree whose `.git` points back (`error.CorruptWorktree`), `add` refuses a destination with anything in it (`error.DestinationNotEmpty`) and a branch git would not name (`error.InvalidBranchName`), and loses its `dest_path` argument and `AddOptions.create_destination`, which did nothing. Patch ids hash a file the attributes call binary by its names (`patchid.ofCommit` and `ofTrees` take a `diff.BinaryRule`, git's `diff_filespec_is_binary`, which format-patch and range-diff now share and which reads `diff.<driver>.binary`). `Config.get` returns the value git reads, quotes and escapes undone once at parse, and an unknown escape is `ParseError.MalformedValue` there, as git's "bad config line"; `getPath` can no longer fail but for memory; `parseInt` is git's base-0 `strtoimax` with no `_`, and `parseBool` takes any integer; `includeIf "gitdir:./"` starts from the including file and `-c include.path` is followed; `Config.Read` keeps a digest (`Read.digest`, `Read.digestOf`) where it kept a second copy of every file. The repository format is read from the repository's own file alone, and a v1-only extension at version 0 is `error.UnsupportedExtension`. Discovery stops at a `.git` file that is not `gitdir: <path>` naming a repository (`error.BrokenGitFile`), passes over a `.git` directory that is no repository, compares directories by device and inode, stops at the start's filesystem and at `OpenOptions.ceiling_directories` unless `OpenOptions.across_filesystems`, as git's `GIT_CEILING_DIRECTORIES` and `GIT_DISCOVERY_ACROSS_FILESYSTEM` say. `safe.bareRepositories` refuses a value git does not know (`error.InvalidSafeBareRepository`, which discovery takes as `explicit`), and `fs.ownedByCurrentUser` takes a path whose owner the platform cannot say as not owned. A directory whose `.git` file cannot be read is a repository to clean, status and add, as git's `is_nonbare_repository_dir` has it. A ref transaction refuses `FETCH_HEAD` and `MERGE_HEAD`, as git does, and a one-level name not spelled as a root ref. `gitmodules.checkUrl` checks a `git://` URL for a decoded newline, and `submodule.update` with `init` does not clone into a path that holds something (`submodule.Error.DirectoryNotEmpty`).

- Objects, refs, packs and the index read hostile input as git does. `Commit.parse` takes the tree from the first line and the parents from the lines after it, and `Tag.parse` the object, type and name from the first three, as git's parsers do, a later `tree` or `parent` being an extra header; a header's continuation lines are unfolded in one copy, where each line copied the value again. `parseHeader` takes a size of digits only, and bytes after a loose object's stream are `error.CorruptLooseObject`. `Tree.Builder.add` finds a duplicate without a scan. Ref deletions take `packed-refs.lock` in `prepare` and read the file under it, waiting `core.packedRefsTimeout` (`refs.Store.Options.packed_lock`, a second by default), so a ref that is loose and packed at once is deleted from both, and a loose ref and its log are removed while their lock is held; FETCH_HEAD and MERGE_HEAD in a reftable repository likewise. A new ref whose path a ref already there, loose or packed, shares is `error.RefNameConflict`; a symbolic target is checked as a ref name, and `HEAD` must name one under `refs/` (`error.InvalidRefName`); a symbolic ref that moved between reading it and locking it is `error.ExpectedValueMismatch`; and a loose ref is read as its first object name, as git reads FETCH_HEAD. Reftable compaction lets the stack's lock go while it merges, as git does. Every pack is the database's for its life under one id (`NamedPack.id`), so the delta-base cache never answers for another pack after a refresh. `Odb.Options.detect_sha1_collisions` is on by default, as git's SHA-1 always is, and index-pack refuses an object the database holds with other bytes (`indexpack.Error.HashCollision`) and holds no more delta bases along a chain than `indexpack.Options.delta_base_cache_limit` (96 MiB), rebuilding the ones let go. An alternate already in the chain, or the database's own directory, is skipped, and a file deeper than `max_alternate_depth` is not read, as git only logs it (`error.AlternatesTooDeep` is gone). A pack whose `.pack` is missing is not listed and one that does not read is left out, `verify` naming it; `Pack.open` refuses a pack its index was not made from (`pack.Error.PackIndexMismatch`), and `verify` an index offset past its pack. A multi-pack index naming anything but a file in its directory, or with version 1 names out of order, is no index, version 2 is read, and `expireMidx` removes only packs the database has open. A commit-graph or multi-pack index that does not read is replaced by the writers and passed over by `describe --contains` (`commitgraph.Graph.openUsable`, `midx.Index.openUsable`); replace refs no longer stop the commit-graph write (`MaintenanceError.ReplacedCommitGraph` is gone), which records the parents commits carry, as git's does. The index reads the names only Windows refuses (`aux.c`, `t.`, a tab), which `safepath.Use.stored` now leaves to the checkout, as it does a backslash and a drive letter off Windows; it refuses `.git` as HFS+ spells it too; a worktree's name is held to the working-tree rules. A split index is checked once merged and its shared file against its link, a cache tree is read without recursion and no deeper than 2048, entries out of order are `index.WriteError.UnsortedIndex` on write, a write sets the racy cutoff, and a gitlink is never racy. Dates past a calendar show as the epoch in UTC rather than crash, a malformed reflog line is skipped, and `@{-N}` reads the branch a checkout left only as an object name or a ref.

- Merges, patches and the state they leave read hostile input as git does. A merge is clean only when ort's rename processing is, as git's `detect_and_process_renames` decides: a directory rename split leaves no path conflicted and is still a stop, never a commit (`ort.Result.renames_clean`, `threeway.Outcome.renames_clean`, `merge.Result.renames_clean` and `stash.Applied.renames_clean`, each read by `isClean`, and a stash so popped is kept). `apply` refuses to read, copy, rename or delete a file past a symbolic link (`Reason.reading_beyond_symlink`), and a symbolic link named `.gitmodules` in any spelling HFS+ or NTFS opens as it, as do checkout, reset and the sparse checkout (`worktree.safepath.checkEntry`, `Reason.symlinked_gitmodules`; `isHfsDot`, `isNtfsDot` and `isNtfsDotGit` move there from `object.fsck`). A hunk placed past an `int` lands where git's lands it, a binary hunk stating more than `odb.delta.max_result_bytes` is `error.CorruptBinaryPatch`, and a mail ending in a bare `---` breaks there, where each crashed. rerere refuses a `MERGE_RR` whose conflict name is no object name or whose path is unsafe (`rerere.clear` included, `error.MalformedMergeRr`), takes a variant only as unsigned digits up to 65536, reads markers followed by a vertical tab or form feed as content, and marks a replayed resolution used so `gc` keeps it. `merge.BlobOptions.marker_size` is a `u32`, so markers past 255 are written and read back. A finished rebase deletes only its `refs/rewritten/` labels, as refs; `rebase.abort` and `quit` give up a rebase whose sheet cannot be read; `reset [new root]` is `error.UnsupportedNewRoot`. Pseudo-refs are removed and found through the ref store (`head.deleteRef`, `head.refExists`), so a reftable repository sees a pick or rebase end. A signature is verified with its own format's program (`signing.Signer.format_programs`), a relative `gpg.ssh.revocationFile` or `TMPDIR` is taken as git takes it. Tree walks stop at git's `core.maxTreeDepth` default (`ort.max_tree_depth`, 2048) wherever a directory is picked up, the stage-only and content tree merges read trees that deep, `-X subtree` scores any size of tree, and `merge.TreeOptions.blob.whitespace` reaches the content merges. `am`'s three-way fallback reads the patch with `--directory` and the limits as the failed apply did (`apply.keptFiles`), and `am.abort` and `quit` remove a stray `rebase-apply`. A notes tree whose fanout cannot be read no longer leaks.

- Hostile remotes and servers cannot turn relic's transports against the person. A value handed to a credential helper that holds a newline, or a carriage return unless `credential.protectProtocol` is false, is refused with `error.CredentialValueUnsafe` (`credential.Error`), as git's `credential_write_item` refuses it, and a URL whose user, password, host or path holds a newline fills nothing — a redirect's `Location` included. Every transport is checked as git's `is_transport_allowed` checks it: `transport.policy` reads `GIT_ALLOW_PROTOCOL`, `protocol.<name>.allow`, `protocol.allow` and git's defaults (`file` and remote helpers only for the person, `ext` never), and `transport.Options.from_user`, with `clone`, `fetch` and `push` `Options.from_user`, says whether the person named the remote; the submodule transport passes false, so a `.gitmodules` cannot reach a repository on this machine unless `protocol.file.allow` says so. `remotehelper.allowed` and `remotehelper.Error.TransportNotAllowed` are gone: the error is `transport.Error`'s and `smarthttp.Error`'s. A smart HTTP redirect goes only to an allowed transport and, to another host or port, drops `Authorization` and `Cookie` from `http.extraHeader` as curl drops them; `http.followRedirects` is read (`httpsettings.FollowRedirects`, `Settings.follow_redirects`), `false` following none. An LFS redirect to another host leaves the request's own `Authorization` behind, as git-lfs's does. A lock taken or given back changes the write bits of the path asked for, never of the path the server answered with; one given back by id touches the server's path only when it is a plain path inside the working tree. A refused credential is forgotten even when a helper cannot be told, and a cancellation while telling the helpers is no longer swallowed.

- git's published security fixes, each held by a test named for it, and the eleven relic did not yet match fixed. A backslash inside a name is a separator to an NTFS volume, so `.git` after one (`a\git~1`, `.\.GIT\x`) is refused on every platform, as is a symbolic link spelling `.gitmodules` there, as git's `verify_path` refuses them. On Windows a drive is any character `subst` names one by (`safepath.dosDrivePrefixLen`), the device names are git's (`conin$`, `conout$`, `lpt0`, spaces before an extension), and `<`, `>`, `"`, `|`, `?`, `*` and `:` are `safepath.Reason.reserved_character`; `safepath.win32Reason` and `win32PathReason` are git's `is_valid_win32_path`, and `isNtfsDotGitmodules` is public. On Windows a program named without a path is looked for in `PATH` alone (`program.lookupOnPath`, git for Windows' `path_lookup`), not first beside the running executable or in the current directory. A diff whose two sides hold more lines than a `u32` numbers (`textdiff.max_lines`) is `error.OutOfMemory` before a line is read, and blame likewise, where the line names wrapped; `apply` and `keptFiles` refuse a patch of git's `MAX_APPLY_SIZE` or more (`apply.max_patch_size`, `apply.Error.PatchTooLarge`, at which `am` stops); an attributes line of 2048 bytes or more is passed over whole (`Attrs.max_line_length`). A tree's entries sort as git's `base_name_compare` sorts them at any length, where a tree named in 4096 bytes or more sorted as a file. A credential prompt names the URL percent-encoded as git's `credential_format` does, unless `credential.sanitizePrompt` is false. A remote's progress and error text keeps no control character but ANSI colour, the rest shown as `^[` and the like, as git 2.55's side-band does (`progress.sanitize`, `progress.Control`, `Progress.remote_control`; a long line may come in more than one `.remote` event), and every message a connection keeps from the other side keeps none. `transfer.credentialsInUrl` is read: `warn` adds `Warning.credentials_in_url`, `die` is `transport.Error.CredentialsInUrl`. upload-pack keeps a `have` the client repeats once, whatever its type, and acknowledges v2's from that set, as git 2.51.1 does. `local.Remote.openWith` opens a local remote with the caller's repository options, its ownership checked against their `safe.directory`. A response head longer than the connection's read buffer is `error.HttpProtocolError`, where a server sending one tripped an assertion in the reader: a crash, and undefined behaviour in a release build.

- Discovery refuses what git refuses. `Repository.open` checks that a discovered repository's `.git` file, working tree and git directory are the current user's (the owner's uid on POSIX; the user's SID, or Administrators for an administrator, on Windows), and otherwise opens it only where `safe.directory` names it — `*`, the path, a `<path>/*` above it, `.` for the current directory, an empty value forgetting the rest — read from the system, global and command-line settings and never the repository's own (`error.DubiousOwnership`). `safe.bareRepository=explicit` refuses a bare repository found by discovery unless it is a `.git` directory or a linked worktree's or a submodule's git directory (`error.ImplicitBareRepository`). `OpenOptions.ownership` takes git's check, `assume_different` (git's `GIT_TEST_ASSUME_DIFFERENT_OWNER`) or `trust`, and `OpenOptions.explicit` names the git directory outright as `GIT_DIR` does, which checks neither. A linked worktree's git directory, whose `objects` and `refs` are where `commondir` points, is found as one. `repo.fs.ownedByCurrentUser` and `repo.safe` are the pieces.

- `includeIf "hasconfig:remote.*.url:<glob>"` holds as git decides it: against every `remote.<name>.url` the whole read sets, at every level and through plain includes, wherever the condition stands, matched as a path glob. A file an `includeIf` brings in that sets a remote URL itself is `error.RemoteUrlInConditionalInclude`, which git refuses too. The condition never held before.

- `sparsecheckout.reapply` (and `set`, `add`, `init`) takes out an excluded file a checkout brought back with `--ignore-skip-worktree-bits`, as git does: an entry marked `skip-worktree` whose file is on the disk loses the mark when the index is read (git's `clear_skip_worktree_from_present_files`, off under `sparse.expectFilesOutsideOfPatterns`), so the update removes it if it is unchanged; `Outcome.unmarked` counts them. `applySparse` keeps a file whose stat does not match the index, as git's `verify_uptodate` does, and reads the content only of a racy entry whose stat matches; it read the content of every file whose stat differed and removed it when that matched.

- `Index.addMany` keeps the entry added last where one names a path and stage already in the index, as it says it does; its sort was not stable, so past a few dozen entries it could keep the older one.

- A trailer line whose token is followed by `://` is a URL and not a trailer, as git 2.56 reads it; `commit.message.Trailer.separated` says which lines of a trailer block had a separator.

- A unified diff's hunk header carries up to 80 bytes of the enclosing line, as git's does; it was cut at 40.

- A program run over its standard streams, ssh above all, whose standard error is captured no longer holds the conversation once it has ended while something it started (an ssh ControlMaster, a credential daemon) still holds that standard error open: what it wrote is read without waiting for more, through conduit's `readAvailable`.

- `inflate.Decoder.raw` decodes a stream whose last code ends in the input's final bytes; asking for bits past the end handed those bytes back to the reader and refused the stream as `EndOfStream`.

- `indexpack.receive` canceled while it resolves deltas cancels every resolving task, so one waiting in a read no longer holds the receive until the read ends; any failure among them now does the same.

- Each usage-example execution creates and removes its own scratch directory, so concurrent builds cannot share or delete another run’s repository.

- TLS handshakes and trust refreshes sample current real time through the caller’s Io, so a long-lived client checks new connections against current certificate validity.

- Proxy authentication allocates replacement offered schemes before releasing the previous diagnostic, so allocation failure leaves a valid value to release.

- The HTTP timeout-counter fixture observes only its client mutex and clears worker state, so hostname helper threads can wait on their own queues safely.

- Digest session authentication releases its intermediate credential hash if allocating the session hash fails.

- An HTTP proxy challenge that cannot be answered releases its response and connection before returning the refusal.

- HTTP CONNECT retries belong to the connection attempt that accepted the proxy challenge, so concurrent requests cannot consume each other’s retry decisions.

- LFS transfer workers read and publish fatal errors under one lock, preserving the first failure without racing another worker.

- Concurrent HTTP timeout fallbacks increment their diagnostic count under the client lock, preserving every connection made without a watchdog.

- HTTP watchdogs observe refreshed activity after sampling the clock, so a previous operation's start cannot expire the new one.

- HTTP watchdogs reject starts later than their clock sample when computing elapsed time, so concurrent activity cannot underflow and close a fresh connection as timed out.

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

- Configuration source paths enter their owner only after copying succeeds, so allocation failure cannot leave a partial path for cleanup.

- Snapshot reads and reopening use only private objects, borrowing the source database for capture alone, so damaged source packs and alternate metadata cannot affect recorded snapshots.

- Staging, status and listing share one directory-read policy so unreadable contents cannot disappear from an otherwise successful result.

- Filesystem staging, status and listing return `TreeTooDeep` at their walk limit instead of returning a partial result.

- Snapshots keep the indexed contents of sparse tracked paths absent by policy and read edits to skipped paths present on disk.

- URL parsing and display share scheme boundaries, and drive prefixes and file authorities follow Git's platform rules.

- An object source transfers its directory handles once on registration, rolls back failed alternate sources, and preserves allocation failure and cancellation.

- A registered pack and its name have one owner, and allocation failure or cancellation while opening packs and their multi-pack index remains a resource failure.

- Staging refuses a directory it cannot open instead of recording its tracked files as deleted.

- A staging scan keeps ownership of each copied directory name until its entry has been appended, including allocation failure.

- Remote URLs keep bracketed IPv6 hosts, users, ports and home paths distinct from remote helpers, and file authorities and local paths follow Git's scheme boundaries.

- Opening or refreshing refuses an invalid `extensions.worktreeConfig` boolean by name and preserves resource failures instead of ignoring the worktree file.

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

- A file whose stat no longer matched the index was compared with it by
  line endings alone, under attributes from outside the working tree only:
  the `.gitattributes` files in it were never read there. So a checked-out
  CRLF or expanded `$Id$` whose stat had changed -- a touch, or a checkout
  on Linux, whose file clock is coarse enough that files written in the same
  tick as the index are racy -- was a local change, and a merge, a pick or a
  `reset --merge` refused to overwrite it. The file is now read the whole
  way in, as `add` reads it: the directories' `.gitattributes`, the filter,
  line endings and `ident`.

- `Signer.init` and `Lfs.load` leaked memory when a setting was long. Each
  took its arena's state before its last allocations, so the blocks those
  allocations made were not in the state `deinit` freed: a signing key,
  key command, allowed-signers or revocation file, or `lfs.fetchinclude`
  and `lfs.fetchexclude` lists, long enough to need a block of their own.
  A path to the key under a long home directory was enough.

### Removed

- `repo.fs.macos_fsync_is_writeout_only`, a constant nothing read.

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

[Unreleased]: https://github.com/pedronaugusto/relic/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.1.0
