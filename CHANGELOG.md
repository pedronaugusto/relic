# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- The public functions that appended to an `*std.ArrayList(u8)` take a `*std.Io.Writer` first, after the receiver, `gpa` and `io` (review 3 m46): `quote.sq(w, text)`, with `quote.sqArgv` for git's `sq_quote_argv`; `date.show`, `date.showRelative` and `date.strftime` (`date.ShowError` holds `std.Io.Writer.Error` where it held `Allocator.Error`); `whitespace.fixCopy(w, src, rule)`; `mail.format.writeWrapped`, `writeRfc822Quoted` and `writeRfc2047`, which takes the column the line is at, where `appendWrapped`, `appendRfc822Quoted` and `appendRfc2047` read it from the buffer; `todo.writeHelp`, where `appendHelp` was; `message.writeCommented`, the commented lines `appendCommented` completes; `sequencer.revertMessage`; `credential.Session.write(w, audience)`; `diff.stat.write`, `writeTotals` and `writeSummary`; `trailer.format(gpa, w, ...)`, `trailer.process(gpa, io, w, input, request)` and `trailer.FileOptions.out`; `pretty.sanitizedSubject(w, subject)` and `pretty.Decorations.write(w, oid, options)`; `pretty.log.writeEntry(a, io, w, inputs, options)`; `pretty.refs.Listing.formatItem(gpa, w, index, format)`. Each fails with `error.WriteFailed` where the writer does. Those that read what the buffer holds keep it: `message.appendSignoff`, `appendCherryPicked`, `appendCommented` and `appendConflictsHint`, which extend a message; `pretty.formatCommit`, whose `%-` and `%C(auto)` act on what precedes the format, as `git archive` hands it; `Odb.readInto` and `Pack.readAtInto`, which reuse a buffer.
- `transport.fetch_pack.fetch` returns `fetch_pack.Fetched` (the pack's `index_pack.Result` as `pack`, with the `uris` a server named and the `found` blobs left to check) where it returned the `index_pack.Result`; `fetch_pack.Error.PackfileUrisUnsupported` is gone.
- `pretty.refs.Error` gains `CommitAncestryCycle`.
- `odb.Error` gains `ReplaceDepthTooHigh`, `ReplaceRefsUnreadable` and `DuplicateReplaceRef`; `odb.Odb.commitGraph` takes `*Odb` and fails with them too; `repo.Settings` has `use_replace_refs`.
- Cancellation (design §11): `diff.unifiedBody` takes `io` and the two texts as `diff.Texts`, `diff.blobNumStat` takes `io`, and `merge.blobs` takes `io` and the three as `merge.Sides`, so their line diffs end with `error.Canceled` once the task is canceled; `diff.Options.lines` takes the `io` it passes to parallax. `diff.TextError` and `merge.BlobError` carry `Canceled`.
- `diff.Status` has `unmerged`, git's `U`: a path the index holds as conflict stages, which `diff.index` gives as one change with the tree's side in `old` where it has one, no `new`, and its path in `Change.unmerged_path` (`Change.path` returns it). `diff.unified` writes it as `* Unmerged path <name>`, an external diff is given its name alone, `diff.numstat` counts nothing for it, `diff.stat.files` marks it `unmerged` and `writeSummary` passes it over, as git does; `diff.rename.Pair.unmerged` keeps it out of rename sources while `-C` may still copy from the tree's side.
- `commit.branch.Error` carries `NotABranchOrPattern` and `pretty.refs.Error`, for `deleteMerged`.
- `maintenance.repack.Error` carries `DropNeedsBlobLimit`, `DropIncompatible`, `NoPromisorRemote`, `OperationInProgress` and `DroppedBlobInIndex`, for `drop_filtered`.
- `merge.ort.Error` carries `DuplicateTreeEntry`.
- `stage.move.Reason` gains `destination_parent_not_directory` and `beyond_symlink`: `mv` checks a destination as git 2.56 does before it moves anything, a dry run and `skip_errors` included. A destination beyond a symbolic link is refused, and a move on the disk whose destination's leading directory is missing (`destination_directory_missing`) or not a directory is refused, where the rename failed partway.
- `odb.pack.Pack.verify` takes `Pack.VerifyOptions` (`cache`, `pack_id`, and `stream_past`, the threshold past which a whole object is checked as it is read) in place of the cache and the pack's id.
- `transport.partial.storeAdvertised` takes the remotes to configure (`transport.Session.promisorCreates`) before the fields to store.
- `transport.upload_pack.bundleSettings` and `transport.Session.bundleUri` take the `?*report.warning.Warnings` that a `bundle.*` setting with no value is said to.
- `odb.Odb.read` and `readInto` of an object longer than `Options.max_object_bytes` are `error.ObjectTooLarge` (a new `odb.Error`), where they were `error.StreamTooLong`; a packed object past it is refused too, where only a loose one was. `odb.pack.Pack.readAt` takes `Pack.ReadOptions` (the cache, the pack's id and `max_bytes`, a delta base or result past which is `error.ObjectTooLarge`, now in `pack.Error`) where it took the cache and the id.
- aegis W3's units in the rest of relic: `text.date.Expiry` is `aegis.units.Instant(.real, .second, i64)` (`expire_all` and `parseExpiry` with it), and the expiries that take one are typed so (`maintenance` gc, prune, repack and reach options, `odb.Odb.PruneOptions.expire`, `index.Index.removeSharedBefore`, `checkout.worktrees` prune's `expire`); `odb.PackOptions.window_bytes`, `loose_cache_bytes`, `batch_bytes` and `big_file_bytes` and `odb.Packing.window_bytes` are `aegis.units.Bytes`; `receive.certNonceSlop`, `receive.keepAlive` and `uploadpack.keepAlive` are `aegis.units.Duration(.second, ...)` (the `keepalive_secs` fields are `keepalive`).
- A function that writes takes its writer first, after `gpa` and `io` (and the receiver), as the family's convention puts it (packages.md §4.7): `grep.grep`, `archive.archive`, `archive.remote.fetch`, `notes.formatNote`, `transport.bundle.write`, `transport.download`, `transport.smart_http.download`, `transport.pkt_line.print`, `fast.exporter.write`, `diff.unified`, `patch.range_diff.write`, `pretty.refs.listRefs`, `listBranches`, `listTags` and `Listing.write`, `odb.pack.Writer.openStream`, `index.UntrackedCache.write`, and the servers' `serve` and `serveRequest` (`upload_pack`, `receive_pack`, `archive.remote`: the writer before the reader).
- `submodule.Transport.cloneFn` takes a `submodule.CloneRequest` (the URL, the directory, and the submodule's name and superproject), so a submodule's clone can borrow from the superproject's lenders; `Transport.fetchPromisedFn`, optional, brings what a submodule that is a partial clone was promised, and `update` has its reads ask through it.
- `submodule.transport` is `transport.clone.SubmoduleTransport` (its `Options` `SubmoduleOptions`): the submodule core sits below transport now, so fetch, clone and push can recurse into submodules, and the seam's clone and fetch live with the clone that recurses through it.
- `transport.clone.Options.origin`, `default_branch` and `ref_format` are optional: `null` takes `clone.defaultRemoteName` (else `origin`), `init.defaultBranch` (else git's `master`, where relic named `main`) and `init.defaultRefFormat` from the caller's levels, as git's clone reads them.
- `pretty.Decorations.load` takes `LoadOptions` (`filter`, and `style`, short or full names) where it took the filter.
- `merge.ort.emptyTree(kind)` is `hash.Kind.emptyTree()`, the one name of the empty tree; the sequencer, `am`, the stash, subtree shifting and fast-import name it there.
- `transport.push.Options.push_options` is optional, `null` taking `push.pushOption`. A default push refuses as git's `setup_default_push_refspecs` does, with git's cases apart: `NoUpstreamBranch` (a branch with no upstream pushed to its own remote under `simple` or `upstream`, where relic pushed it to its own name), `UpstreamNameDiffers`, `MultipleUpstreams`, `NotUpstreamRemote`.
- `patch.format.Options` takes what the caller leaves from the `format.*` settings (step F group 14): `numbered`, `subject_prefix`, `suffix`, `filename_max_length`, `encode_email_headers`, `force_in_body_from` and `mboxrd` are optional; `signoff` is `?bool` and names `who`; `thread` is `Thread` (`configured`, `off`, `shallow`, `deep`) with `who`'s time and address; `from`, `attach` and `signature` are `Choice(T)` (`configured`, `off`, `on`); `cover_letter` is `CoverLetter` (`configured`, `off`, `on`, `auto`) and its details `Options.cover` (`Cover.sender` defaulting to `who`, `format` and `from_description` optional); `base` is `Base` (`configured`, `off`, `auto`, `commit`); `to`, `cc` and `headers` are `Listed` (the setting's, unless cleared, then the given); `CoverFormat` is a union with `log`. New: `who`, `version`, `output_directory`, `Series.directory`; errors `InvalidFormatSetting`, `NoIdentity`, `NoAutoBase`.
- `discover.gitfile.write` takes `(io, dir, path, hide)`, with no allocator; a linked worktree's `.git` file is written through it. `checkout.worktrees.repair` takes the `core.hideDotFiles` setting; `AddOptions` and `MoveInputs` carry it.
- `fs.LockFile.Options.write_pid` is git's `core.lockfilePid`, off by default: the holder is named in `<file>~pid.lock` beside the lock, gone with it, where it was the lock's own first bytes by default; `fs.staleReport` reads that file, so it names a git holder too. `refs.Store.Options.packed_lock` is `locks` (`refs.Locks`: `core.packedRefsTimeout`, `core.filesRefLockTimeout`, `core.lockfilePid`), refreshed with the configuration (`Store.configureLocks`). `config.write.prepare` and `editFile` take `LockOptions` where they took `fs.Shared`.
- `repo.Repository.CreateOptions.object_format`, `ref_format` and `default_branch` are optional: `null` takes `init.defaultObjectFormat`, `init.defaultRefFormat` (else a reftable under `feature.experimental`) and `init.defaultBranch` (with the template's own configuration) from the configuration levels `CreateOptions` now names as `OpenOptions` does (`system_config`, `xdg_config`, `global_config`, `config_overrides`, `config_pairs`, `home`), else SHA-1, files and git 2.55's `master` -- where the branch was `main`. An initial branch no branch can have is `error.InvalidBranchName`. Held to `git init` under each.
- `wire.protocol.writeCommand` takes `CommandExtras` (the session id and server options) in place of the session id.
- `transport.fetch.Outcome.pack` is `null` for a fetch whose pack was stored loose below the unpack limit; `objects` counts what came either way.
- `index.Index.split_base` is `Index.split` (`index.Split`: the shared index's checksum and its entries). A split index read is written back split, as git keeps it, where it was written whole.
- `maintenance.Expiry`, `maintenance.expire_all` and `maintenance.parseExpiry` are `text.date.Expiry`, `expire_all` and `parseExpiry`: git's `parse_expiry_date` is date reading, and the index's shared files expire by it too.
- `index.Index.version` is 0 for an index made here, not 2; `WriteOptions.version` `.auto` keeps the version the index carries (a version 4 index stays 4), as git's `do_write_index` does, and `WriteOptions.new_version` is the one an index made here is first written in.
- `maintenance.RepackOptions.pack`, `GcOptions.pack`, `RunOptions.pack`, `transport.bundle`'s `pack` and `transport.local.Remote.CopyOptions.pack` are optional: `null` takes the repository's pack settings (`Odb.packOptions`).
- `transport.smart_http.Error` has `PinnedPubkeyMismatch` (curl's `CURLE_SSL_PINNEDPUBKEYNOTMATCH`, its message curl's "SSL: public key does not match pinned public key") where a pin failed with `TlsFailed`, and no `PinnedPubkeyUnsupported`.
- `archive.Format` is a tagged union, with `filtered` for a tar filter; `archive.Error` gains `UnknownFormat`, `LevelNotSupported`, `FilterNotRun` and `FilterFailed`.
- `commit.merging.conclude` returns `Concluded` (the commit, and what became of `MERGE_AUTOSTASH`); `merging.abort` takes `AbortOptions` and returns `?stash.Restored`; `merging.removeMergeState` takes who saves a leftover `MERGE_AUTOSTASH`.
- `commit.rebase.abort` and `rebase.quit` take `rebase.Options` and return `?stash.Restored`; `commit.sequencer.quit` takes `who`.
- `transport.remote.Branch.fetchRemote` takes the configuration, for git's fallback to the only remote.
- `commit.merging.Kind` has `remote_head` and `remote_ref` for what `FETCH_HEAD` names; `merging.Target` carries `source` and `what`.
- Every lock relic holds is aegis's `BlockingGuarded`, its data reached only through a guard. `lfs.api.Client.message` takes an `Io` and an allocator and returns a copy, read under its lock (the borrowed buffer it returned could change under a reader). `lfs.ssh.Transfer.connection` returns the connection's `Transfer.Line`, held for a request and its answer in place of `Connection.mutex`; `Transfer.failure` copies what ssh said when one did not start; `Connection.open` returns the connection itself. `refs.reftable.stack.Cache.reloads` is a function of an `Io`.
- `commit.sequencer`'s revert message is `sequencer.revertMessage`, taking an arena.
- `commit.merging.Options.commit`, `signoff`, `allow_unrelated_histories` and `verify` are optional: `null` takes `branch.<name>.mergeOptions`, then git's default.
- A ref transaction leaves out an update to the value a ref already holds, as both of git's backends do: the ref is not written and gains no log line, while a ref logged through it (`HEAD` for its branch) still does.
- `rebase.Options.autosquash`, `update_refs` and `reschedule_failed_exec` are optional: `null` takes `rebase.autoSquash` (for an interactive rebase only), `rebase.updateRefs` and `rebase.rescheduleFailedExec`, each read and checked as git dies on a value that is no boolean. `rebase.Stop` has `missing_commits`.
- `commit.rebase.Error.ApplyBackendInProgress` is gone: a rebase git's apply backend stopped is continued, skipped and aborted. `commit.rebase` lives in `src/rebase/`, its own layer above `patch`, as it drives `am`; its name is unchanged.
- `rev_walk.Commit` carries the commit's root tree (`tree`).
- `maintenance.repackRepository` is gone: `maintenance.repack` is git's `repack`, and the commit graph is `writeConfiguredCommitGraph`'s, as git's `gc` writes it after the repack.
- `worktree prune` is git's `prune_worktrees`: `worktrees.prune` and `Repository.pruneWorktrees` take `PruneOptions` (`expire`, git's `--expire` against the administrative directory's `index`; `dry_run`; `ignore_case`, which `pruneWorktrees` reads from `core.ignoreCase`) and return a `PruneOutcome` to `deinit`, listing each directory pruned with its `PruneReason` (an entry that is no directory, no `gitdir`, an unreadable or empty one, a working tree gone, a duplicate of the main worktree's or an earlier one's path); an empty `worktrees/` goes too. It took away only the directories `list` called prunable, and kept the rest.
- `maintenance.GcError` is `gc`'s; the error of `packRefs` and `expireReflogs` is `maintenance.HousekeepingError`.
- `maintenance.PruneError` no longer has `InvalidRebaseState`, which nothing returned; reachability's own failures are `maintenance.ReachError` (`maintenance/reach.zig`, moved out of `prune`).
- `Odb.recentObjects` is gone: `Odb.timedObjects` lists every object of the database's own directory with the time `prune` and `repack --cruft` date it by (a loose file's time; a cruft pack's object by its own time in the pack's `.mtimes`, any other packed one by its pack's time) and the pack it was found in. An `.mtimes` that is not git's is `error.InvalidMtimes`, where git dies.
- aegis W3, units: relic's own sizes and times are aegis's `Bytes` and `Duration`, so no count is read in the wrong unit. `transport.http_settings.Settings.post_buffer` is `Bytes(u64)`; `low_speed_time`, `retry_after` and `max_retry_time` are `http_settings.Seconds` (signed, as git's `int` is); `repo.warning.Warning.rate_limited` is a `Duration(.second, u64)`. `odb.index_pack.Options.max_pack_bytes`, `max_object_bytes` and `delta_base_cache_limit`, the filter's `blob_limit` (`transport.filter_spec.Spec`, `rev_walk.object`'s filters), `patch.range_diff.Options.max_memory` and `odb.Options.delta_cache_bytes`, `read_buffer_size`, `pack_read_cache_bytes` and `max_object_bytes` are `Bytes`. `lfs.server.S3.expires` is a `Duration(.second, u32)`.
- aegis W3, input: what a peer sends is aegis's `input.Untrusted` until a parser reads it. `transport.pkt_line.Packet.data` is `pkt_line.Unparsed`; `lfs.api.Exchange.readJson` and `readAll` return `lfs.api.Unparsed`, which `lfs.api.parseJson`, `parseAuthenticate`, `lfs.transfer.parseBatch`, `parseBatchRequest`, `lfs.locks.parseLockAnswer`, `parseListPage`, `parseVerifyPage`, `parseRequest` and `lfs.custom.parseAnswer` take; `lfs.ssh.Status.lines` is `lfs.ssh.Lines`, which `lfs.transfer.parseSshBatch` and `lfs.locks.parseSshLocks` take, and `Status.message` is its first line; `transport.credential.Session.readAnswer` takes the helper's answer as one.
- `diff.UnifiedError`, `diff.blame.Error`, `grep.Error`, `patch.format`'s and `patch.range_diff`'s errors carry `diff.textconv.Error` and `diff.driver.Error`.
- `diff.BinaryRule` is `diff.driver.Drivers`, and `diff.UnifiedInputs.binary` is `drivers`; `patch_id.ofCommit` and `ofTrees` take `Drivers`. A side that is no regular file (a symbolic link, a gitlink, the side a creation or a deletion lacks) takes the `default` driver, as git's `diff_filespec_load_driver` gives it, where its path's attributes decided before.
- `odb.quarantine.Quarantine.begin` takes the `Purpose` the objects are held for, which names the directory as git names it: `incoming` for a push, `remerge_diff` for `git log --remerge-diff`.
- `diff.driver.Error`, `diff.driver.Drivers.isBinary` (`Drivers.BinaryError`) and `diff.patch_id.Error` carry `InvalidBigFileThreshold`, for a `core.bigFileThreshold` git dies on.
- `diff.numstat` takes `diff.NumstatInputs` (the object store, the changes and their `drivers`) where it took the store and the changes; `diff.NumstatError` carries the attribute and driver errors.
- A directory or file relic opens is owned by one holder, which closes it, and lent to the rest (aegis's danger rules, A015): `fs.OwnedDir`, `fs.OwnedFile`, `fs.OwnedStream` and `fs.OwnedServer` (aegis `own.OwnedIo`) and `fs.LentDir` (`own.Lent`). `repo.Repository.gitDirectory`, `commonDirectory` and `topDirectory` return an `fs.LentDir` and `workDirectory` a `?fs.LentDir` (`.get()` gives the `Io.Dir`); `refs.Store.init` takes the git and common directories as `fs.LentDir` and `Store.gitDir` and `commonDir` lend them; `odb.Odb.objectsDirectory` lends, `Odb.addSource` takes the `*fs.OwnedDir` it keeps, and `Odb.OpenPack` is a pointer. What opens hands over an owner: `Repository.gitDirOf`, `Odb.openPackDirectory`, `discover.gitlink.GitDir`'s directories, `checkout.worktrees.Added`'s, `lfs.Store.open` and `checkout.filter.native.Content.file`.
- The credentials a helper, askpass or the person gives never sit in memory that is freed unwiped. `credential.Prompt.ask` is `fn (context, field, prompt, answer: *std.Io.Writer) (Allocator.Error || std.Io.Writer.Error)!bool`: the prompt writes the answer into the writer relic hands it (aegis's `SecretBytes.Writer`) and returns `true`, `false` declining. `credential.store.Found.password` and `credential.cache.request`'s answer are `aegis.SecretBytes`.
- A whole file is read through aegis's `own.readFile`, which reads at offsets and keeps a cancel that lands on the file's length (std's `Dir.readFileAlloc` guessed the length there and lost it): every error set that held `Io.Dir.ReadFileAllocError` holds `aegis.own.ReadFileError`, `credential.store.Error` among them.
- `config.Entry.file_index` is a `config.FileId`.

### Added

- relic's upload-pack serves packfile URIs and `sideband-all` as git 2.56's does: `uploadpack.allowSidebandAll` (`upload_pack.Options.allow_sideband_all`) offers `sideband-all`, and a fetch that asks for it is answered with every line on the side band (`side_band.Lines`, git's `packet_writer`); any `uploadpack.blobPackfileUri` with a value offers `packfile-uris`, and an object a value names at a URI of a protocol the client asked for is left out of the pack and named in the response's `packfile-uris` section, unless a pack holds it, as git's pack-objects leaves out loose objects alone; a value not of git's form ends the pack in git's words; `uploadpack.packObjectsHook` is handed `--uri-protocol` and what it prints before the pack is relayed.
- Packfile URIs, as git 2.56's fetch takes them: `fetch.uriProtocols` (`fetch_pack.Request.uri_protocols`) asks a v2 server that offers `packfile-uris` for the `http` and `https` of them, and each pack it names (`fetch_pack.PackfileUri`) is downloaded with the remote's `http.*` settings and indexed beside the main pack as `http-fetch --packfile` does, refused as `PackfileUriMismatch` unless it has the checksum named (`transport.Session.Fetched.uri_packs`, `Session.UriPack`); a fetch then keeps the main pack, a promisor fetch marks every pack, and the `.gitmodules` and `.gitattributes` the packs name are checked once all are in, as `fsck_finish` (`index_pack.Options.found`, `index_pack.checkFound`). `sideband-all` is asked for wherever a v2 server offers it, as git asks, every line of the response read through the side band (`side_band.Demux.band`).
- `Walk.exclude_first_parent_only`, git's `rev-list --exclude-first-parent-only`, also in `path_walk.Options` and `backfill.Options`: what a hidden commit reaches is marked through first parents alone, and a hidden commit whose first parent was already seen goes no further, as git 2.56 walks it (2.55 went on to the next parent and hid it).
- Cancellation points (design §11): every line diff relic runs passes its `io` to parallax 0.3.0, which asks once per work unit and per histogram or patience region (`diff.unified` and its body, `numstat`, combined diffs, word diffs, blame, patch ids, range-diff, the stash's moved-line check, every blob merge); blame asks once per commit, range-diff once per pair of patches, and status, add, checkout, the working-tree listing and grep once per file, so a canceled call returns `error.Canceled` within one step. A checkout canceled partway keeps the files it wrote, flushed with cancellation blocked. Tested per loop on std's threaded `Io` and on reactor's evented runtime, canceled at a point halfway through its own and run uncanceled for the same answer.
- Cancellation points in the history and pack loops (design §11): the delta search once per object, written alone or on tasks; the revision walk once per commit popped, sorted and handed out (`rev_walk.Walk.prepare` and `next`, so log, describe, bisect, the path walk, last-modified and what else is built on it); merge bases' paint and `reachableSubset` once per commit; the object walk once per commit taken or marked had, tree listed, filtered or marked had, and object checked present; index-pack once per entry read, delta resolved, collision checked and thin base taken; describe's search and depth count, `--contains`'s naming, last-modified, the path walk and bisect's distances and weights once per commit or path. A canceled call returns `error.Canceled` within one step and leaves no temporary file. Tested per loop on std's threaded `Io` and on reactor's runtime, canceled at a point of its own and run uncanceled for the same answer and a point per step. `relic-rows` has the rows that measure them (`bench/walk.zig`).
- `diff.index`: a tree against the index, as git 2.56's `git diff-index --cached` and `git diff --cached` compare them (`do_oneway_diff`), with `IndexInputs` and `IndexOptions` (renames, the prefix of `--relative`, a pathspec, an order file, and `hide_intent_to_add`, git's `ita_invisible_in_index`, which the porcelain sets): each merged entry against the tree's file, a sparse directory as the files of its tree, conflict stages as one unmerged path, and under `--relative` an unmerged path outside the prefix left out, as 2.56 leaves it.
- `commit.branch.deleteMerged` (`MergedInputs`, `MergedOptions`, `MergedOutcome`), git 2.56's `git branch --delete-merged`: the local branches tracking an upstream the patterns name whose tips that upstream reaches, deleted with their `branch.<name>` sections, `--dry-run` with them. A branch stays when its upstream is gone, a worktree holds it, a push of it to its remote would update that upstream, a branch that stays builds on it, or `branch.<name>.deleteMerged` is false (`kept`, git's "Skipping"); a base kept for another has its own upstream cleared when that upstream goes. `error.NotABranchOrPattern` where git refuses a pattern.
- `maintenance.repack.Options.drop_filtered` and `dropCandidates`, git 2.56's `git repack --drop-filtered` and its `--dry-run`: with `-a` or `-A` and `--filter=blob:limit=<n>`, the promisor blobs of at least that size dropped where they would be packed apart, the packs they were in deleted, refused as git refuses it (no promisor remote, an operation under way, a blob the index names, `--filter-to`, `-b`). A blob the filter leaves out that no promisor remote has is still packed apart, where git 2.56 deletes it. `Report.dropped` counts them. `commit.in_progress` lives in the repository layer, so a repack reads it.
- `pretty.refs.Filter.forked` and `BranchListOptions.forked`, git 2.56's `git branch --forked`: the branches whose upstream a full name or a glob names, `pretty.refs.forkedPattern` reading the argument as git does (a remote for the branch its `HEAD` points at).
- `commit.history.drop` (`DropInputs`), git 2.56's `git history drop`: a commit taken out, its descendants replayed onto its parent and the refs on it moved there (`--update-refs`, `--empty`, `--dry-run` as the other subcommands take them), the index and the working tree following `HEAD` two ways, checked before any ref moves; a root commit is `error.CannotDropRoot`, a merge `error.MergeCommit`.
- `commit.replay.Options.linearize`, git 2.56's `replay --linearize`: the merges in the range dropped and the rest replayed in a line, each onto the last commit made, a ref at a merge moved to the commit made before it; `error.LinearizeWithContained` and `error.LinearizeWithMultipleBranches` where git refuses it.
- `git add`'s pack for a file past `core.bigFileThreshold` that nothing converts is written from the file read in pieces, never held, as git's `index_blob_bulk_checkin` (`odb.Odb.writeIntoFrom`): hashed and deflated as it is read, taken back out of the pack where the database or the pack holds the blob already (design §10).
- `worktree.addResolved` (`ResolvedOutcome`), git 2.56's `add --resolved`: every unmerged path under the prefix staged as `addAll` stages it and nothing else, refused with the files still holding a conflict marker of their `conflict-marker-size`.
- `repo.head.bisectingBranch`: the worktree whose bisection started from a branch, git's `branch_bisecting`, which git 2.56's `branch -d` reports apart from a branch held otherwise.
- `includeIf "worktree:"` and `"worktree/i:"` (git 2.56): a condition matched against the work tree as `gitdir:` is against the `.git` directory, a linked worktree its own and a bare repository none. `config.Context.work_tree` carries it, and `Repository.open` supplies it.
- The built-in `swift` diff driver, git 2.56's: its function lines (attributes, modifiers, `func`, `init`, `subscript`, the type declarations) and its words.
- `archive` writes a regular file past `core.bigFileThreshold` from the object database's stream, as git's archive streams it: a tar entry in blocks, a zip entry stored or deflated as it is read, its checksum and deflated size in the data descriptor after it, the text flag from its first piece as git's `write_zip_entry` asks it; nothing of it held whole (design §10).
- A checkout, `reset --hard`, `checkout-index` and a sparse checkout write a regular file past `core.bigFileThreshold` from the object database's stream where its conversion streams (git's `get_stream_filter`: no filter driver, no `working-tree-encoding`, line endings the attributes decide), through git's stream filters, never holding the blob (`odb.Odb.readOrStream`, `checkout.convert.StreamFilter`, `convert.Session.streamFilter`); one whose conversion needs the whole blob is read whole, within `max_object_bytes`, as git reads it (design §10).
- `odb.pack.Writer.addFrom`: a whole object of a stated size added from a reader, hashed into its name and deflated as it comes (`Writer.From`: its type and length, `expect`, `hash`), as git's bulk-checkin writes a large blob; `Writer.dropLast` takes the last such entry back on a pack written to a file, and an object the pack holds already comes back not `Added.new`, taken back; `Writer.addDeflatedFrom` (`Writer.DeflatedEntry`) copies a stored entry's zlib stream from a reader. `WriteError` gains `ReadFailed`, `ShortRead`, `ObjectNameMismatch` and `CollisionAttack`. `odb.pack.Pack.readerAt`, `sumStored` (`Pack.Sums`) and `nameStreamed`; `odb.ObjectStream.time`.
- `odb.pack.Writer.addFrom`: a whole object of a stated size added from a reader, hashed into its name and deflated as it comes (`Writer.From`: its type and length, `expect`, `hash`), as git's bulk-checkin writes a large blob; `Writer.dropLast` takes the last such entry back on a pack written to a file; `Writer.addDeflatedFrom` (`Writer.DeflatedEntry`) copies a stored entry's zlib stream from a reader. `WriteError` gains `ReadFailed`, `ShortRead`, `ObjectNameMismatch` and `CollisionAttack`. `odb.pack.Pack.readerAt`, `sumStored` (`Pack.Sums`) and `nameStreamed`; `odb.ObjectStream.time`.
- The client's `object-info`, git 2.56's `transport_fetch_object_info` that cat-file's `remote-object-info` asks: `transport.Session.objectInfo` (`transport.protocol.objectInfo`, `ObjectInfoRequest`, `ObjectInfo`) asks a v2 server the size and type of objects, only the attributes its `object-info=` names, and reads which it does not have; `error.ObjectInfoNeedsV2`, `ObjectInfoNotEnabled` and `ObjectInfoUnsupported` (a bundle, a remote helper) are git's refusals. Held to git 2.56's cat-file over a repository on this machine and over HTTP.
- git 2.56's `promisor.acceptFromServerUrl`: an advertised promisor remote whose URL a pattern allows (scheme and port the same, host and path each a glob, as `match_one_url`) is taken whatever `promisor.acceptFromServer` says; one the client does not know is configured as `name=` names it or as `promisor-auto-<host-port-path>` (`-1` to `-19` past a remote of that name with another URL, reused with the same URL) with `remote.<name>.promisor` and `remote.<name>.advertisedAs`, and said (`report.warning.Warning.promisor_auto_created`); fields are stored in the client's remote of it (`transport.promisors.Info.local_name`, `Reply.creates`, `Create`). `transport.remote.validName` is git's `valid_remote_name`, which clone's `--origin` check now is.
- A push to a remote given as a URL moves the remote-tracking refs of the one configured remote whose push URL that is, and `@{push}` names them, as git 2.56's `repo_remote_for_push_tracking` (`transport.remote.Remote.forPushTracking`); relic moved none.
- `remote.<name>.followRemoteHEAD` whole and git 2.56's `fetch.followRemoteHEAD` beneath it (git's `set_head`): `always` points `refs/remotes/<name>/HEAD` at the remote's `HEAD` whatever it named, `warn` and `warn-if-not-<branch>` note where it names another branch or an object (`report.warning.Warning.remote_head_differs`, `remote_head_detached`, git's words), a bare mirror's `HEAD` follows, the remote's `HEAD` found by its symbolic ref or else the one branch at its object, and nothing done for a fetch with refspecs named or a remote with none of its own. An unknown word is noted and passed over; `fetch.followRemoteHEAD` with no value is `error.FollowRemoteHeadWithoutValue`. Only `never` and the default `create` were read before.
- git's `credential-cache` in process: a `cache` helper whose words need no shell (`--timeout`, `--socket`, git's parse-options abbreviations and negations, the first word that is no option taken for the action) talks to the daemon itself through `transport.credential.cache` (git's `send_request`: `action=`, `timeout=`, the helper's input, the socket's side shut, the answer read to its end; the socket `~/.git-credential-cache/socket` or the XDG cache one). A store with no daemon listening starts one through `credential.Options.cache_daemon`, a `cache.Starter`, else git's own `git credential-cache--daemon` through the programs, as git's client does. `transport.credential_cache_daemon` is git's daemon: `Daemon.listen` (the socket's directory made 0700, refused when looser), `Daemon.run` (git's matching, order, `authtype` and `credential` to a client that takes them, partial, ephemeral and timeout refusals, erasure, expiry and the thirty seconds' grace, by the `Io`'s clock), and `InProcess`, a starter that runs daemons on tasks of this process. Held to git 2.56's client and daemon both ways.
- `odb.Odb.stream` opens an object of any length for reading, as git's `open_istream`: `Odb.Stream`'s `reader()` gives exactly its `size` (`u64`) bytes, a loose object and a pack's whole entry inflated as they are read with no more held than the stream's buffers, a delta made whole within `Options.max_object_bytes`; a stored object that cannot give its header's bytes fails the read, `err()` naming `CorruptLooseObject`, `CorruptPackEntry` or the file's error. `read` and `readInto` share its lookup and its loose inflater (design §10's reading side).
- A push to a remote group, as git 2.55's: `transport.push.remotesToPush` (`remotes.<name>`'s remotes, in order and as often as listed, else the name) and `push.pushMany` (each pushed in turn, a failure noted and the rest pushed; `atomic` across several is `error.AtomicAcrossRemotes`, git's "--atomic can only be used when pushing to one remote").
- git's `credential-store` runs in process (`wire/credential/store.zig`) for a `credential.helper` of `store` whose words a shell hands over as written (quotes, a leading `~/`): `~/.git-credentials` and the XDG `credentials` file, or `--file`'s, read, written and erased as git's are — lines percent-encoded in git's lower case, the first file there written or the first made, the file locked for `credentialStore.lockTimeoutMS` and made readable by its owner alone; a word only a shell can read still runs `git credential-store` through it. The URL-parts reader both share is `wire/credential/parts.zig`.
- `transport.push.Options.recurse_submodules` (`push.Recurse`: `no`, `check`, `on_demand`, `only`; `null` takes `push.recurseSubmodules` or `submodule.recurse`, the later set) and `in_superproject`, as git 2.55's `transport_push` has them: the submodules whose commits the push records and no remote-tracking ref of theirs reaches (`submodule.unpushedSubmodules`, git's `find_unpushed_submodules`) are pushed first under `on_demand` and `only` — after git's push-check in each when the remote is configured (`SubmoduleRemoteNotConfigured`, `SubmoduleHeadMismatch`, `SubmoduleRefspecUnmatched`), to that remote with the push's refspecs, else to their own default — then any still unpushed refuse the push (`error.UnpushedSubmodules`, each a warning); `only` sends nothing of the superproject's, and a submodule's own `only` is taken as `on_demand` with git's warning.
- `transport.clone.Options.recurse_submodules`, `shallow_submodules` and `filter_submodules` (`clone.filterSubmodules`): git's `--recurse-submodules[=<pathspec>]`, `--shallow-submodules` and `--also-filter-submodules` — `submodule.active` written as the pathspecs, `submodule.recurse` under `submodule.stickyRecursiveClone`, and after the checkout every active submodule cloned and checked out, theirs too, as git's `submodule update --require-init --recursive` runs, with the clone's own single-branch choice handed on as git hands it; a filtered submodule's checkout fetches what it was promised. With `--reference`, `submodule.alternateLocation=superproject` and its error strategy are written and each submodule borrows from the lenders' `modules/<name>` (git's `prepare_possible_alternates`), writing both settings into its own configuration for its submodules. `transport.clone.SubmoduleOptions` gains `depth`, `filter`, `single_branch`, `ref_format` and `warnings`.
- `transport.clone.Options.reference` and `dissociate`: git's `--reference`, `--reference-if-able` and `--dissociate`. A lender (`clone/reference.zig`, git's `compute_alternate_path`: a working tree, a git directory or a `.git` file; not missing, not a linked checkout, not shallow or grafted) is named in the new repository's alternates before the fetch, its refs offered as haves, and a want it already holds not asked for, as git's fetch-pack leaves it out; one that cannot lend is `error.ReferenceNotFound`, `ReferenceNotARepository`, `ReferenceLinkedCheckout`, `ReferenceShallow` or `ReferenceGrafted`, or under `--reference-if-able` git's "Could not add alternate" warning. `--dissociate` repacks what was borrowed in and removes the alternates file.
- A fetch goes into the submodules as git 2.55's `fetch_submodules` does (`fetch.Options.recurse_submodules`, `recurse_submodules_default`, `submodule_jobs`; `Outcome.submodules`): on demand by default — a submodule whose commits the fetched history records (each submodule changed in every parent of a fetched commit, named by that commit's `.gitmodules`) and that lacks them — always or never by `--recurse-submodules`, `fetch.recurseSubmodules` and `submodule.recurse` (the later set), `.gitmodules`' `fetch.recurseSubmodules`, and each submodule's `fetchRecurseSubmodules`; a commit still missing asked for by name after; `submodule.fetchJobs`, else `fetch.parallel`, at once; a submodule's failure kept and the fetch going on. Nested submodules fetch the same way. The pieces are `submodule.changedSubmodules`, `hasCommits` and `planFetch` (git's `collect_changed_submodules`, `submodule_has_commits` and fetch-task choice). Maintenance's prefetch passes `--recurse-submodules=no`, as git's does.
- `diff.submodule` and `--submodule` as git 2.55 writes them (`diff.Options.submodule`, `diff.SubmoduleFormat`, read by `diff.configured`, an unknown format kept out as git keeps the last): a gitlink's change under `log` is git's `show_submodule_header` and `show_submodule_diff_summary` (`Submodule <path> <old>..<new>:`, `...` off a common line, ` (rewind)`, `(new submodule)`, `(submodule deleted)`, `(commits not present)`, then `  < ` and `  > ` for each first-parent commit either side, in the old and new colours), and under `diff` the header and the submodule's own diff between the two commits with `<prefix><path>/` prefixes, its settings, renames, drivers and colours, nested submodules the same way (`show_submodule_inline_diff`). The diff layer writes it through `diff.SubmoduleWriter` (`UnifiedInputs.submodules`, `error.NoSubmoduleWriter` without one), which `submodule.DiffWriter` is. Held to `git diff --submodule=log` and `--submodule=diff`, in colour and by `diff.submodule`.
- `diff.autoRefreshIndex` as `git diff` reads it (`worktree.StatusOptions.StatOnly.configured`): a tracked file whose stat changed and whose content did not is, under `refresh` (git's default, and `git status`'s), unchanged and its new stat put in the index (`Index.stat_refreshed`) for the caller to write, as git's refresh writes it; under `report` (`false`), modified without its content read, as `git diff --name-status` and `git diff-files` list it. Held to `git diff --name-status` and to `git diff-files` after the refresh.
- `pretty.log`: a log's entry for a commit in git 2.55's built-in formats, as `show_log` and `pretty_print_commit` write it (`writeEntry`): `raw`, `medium`, `short`, `full`, `fuller` and `oneline`, the `commit` line whole or cut short (`--abbrev-commit`, `log.abbrevCommit` by `configuredAbbrevCommit`) with ` (from <parent>)` and its decorations, `Merge:`, the people through the mailmap, their dates in the log's mode, the message indented with tabs expanded, the notes; `--show-signature` and `log.showSignature` (`configuredShowSignature`): gpg's or ssh-keygen's lines for the commit's signature and each mergetag of a merge, in `color.diff.frag` or `color.diff.whitespace` (`pretty.Colors.frag` and `whitespace`). `parse` and `configured` choose the format as git's `get_commit_format` reads `--pretty`, `--format` and `format.pretty`: a name or any prefix of one, `reference`, `pretty.<name>` aliases (a loop is `error.AliasLoop`), `format:` and `tformat:`. Held to `git log --pretty=<format>` and `git log --show-signature` for ssh and openpgp keys.
- `diff.stat`: `--stat` and `--summary` as git 2.55 writes them (`show_stats`, `builtin_diffstat`, `diff_summary`), once, where format-patch had its own: `files` counts the changes (lines, a binary file's sizes), `write` scales names and graph to `Widths` (`--stat-width`, `--stat-name-width`, `--stat-graph-width`, `--stat-count`) with the `...` line, `Unmerged` and colour, `writeSummary`, `printName` and `renamed` (`pprint_rename`), `writeTotals`; `Widths.configured` takes `diff.statNameWidth` and `diff.statGraphWidth` as `git diff` and `git log` do. Held to `git diff --stat --summary` at each width and setting.
- `attr.tree` as git 2.55's `compute_default_attr_source`: `Repository.loadAttrs` reads every `.gitattributes` of the tree it names (any revision expression, by `repo.rev_parse`, peeled to a tree; one that names nothing is as unset, one that names a blob gives no attributes), `HEAD` in a bare repository included, which then stand in for the working tree's and for a checked-out or merged tree's own (`Attrs.from_tree`); `Repository.attrTree`; `loadGlobalAttrs` for git's index direction, where `git archive` reads the archived tree's and `attr.tree` has no say. `rev_walk.rev_parse` is `repo.rev_parse`, in the layer that reads the setting. Held to `git check-attr` and `git checkout`.
- `names.ref.rev_parse_rules`, `refnameMatch`, `matchRule` and `expandRule`, and `refs.Store.resolveShort`: git's `ref_rev_parse_rules`, once, where rev-parse, merging, the sequencer, LFS, push, fetch and `pretty.refs` each had a copy.
- `status.showUntrackedFiles` as `git status` reads it: `worktree.StatusOptions.Untracked.configured` (`normal` when it says nothing, a boolean as `no` or `normal`, an unknown mode `error.InvalidUntrackedMode`) and `Untracked.parse`, git's `parse_untracked_setting_name`, for `--untracked-files`. Held to `git status --porcelain` under each mode.
- `core.checkRoundtripEncoding` as git 2.55's `check_roundtrip`: a file stored in a `working-tree-encoding` the list names (SHIFT-JIS when it says nothing; only the name's first occurrence counts, as `strcasestr` finds it) is converted back from UTF-8 and compared, and one that is not the same is `error.WorkingTreeEncodingRoundtrip`, where git dies (`attributes.CoreSettings.check_roundtrip_encoding`). A UTF-16 file with a little-endian mark fails it, as it fails git's. Held to `git add`.
- `clone.rejectShallow` and `transport.clone.Options.reject_shallow` (`--[no-]reject-shallow`): a shallow source is `error.ShallowSourceRefused` — by path, in a v0 advertisement, or in a v2 `shallow-info` (`wire.fetch_pack.ShallowInfo.reject`) before the pack is read — unless the clone deepens, as git's clone and fetch-pack refuse it.
- Several remotes, as git's `fetch` takes them: `fetch.remotesToFetch` (`fetch.all` and `Selection.all`, `remote.<name>.skipFetchAll` beside its older name `skipDefaultUpdate`, the last deciding; `remotes.<group>`; a name neither remote nor group refused among several) and `fetch.fetchMany` (`ManyOptions`; git's `fetch_multiple`: `FETCH_HEAD` emptied first and each remote's lines added, the commit graph written once after, a failure noted and the rest fetched, `fetch.parallel` remotes at once each on its own `Repository.openAgain`). `fetch.Options.write_commit_graph`; `remote.isConfigured`. Held to git 2.55's fetch.
- `push.negotiate`, as git's `get_commons_through_negotiation`: before the pack is made, a fetch's negotiation with the push URL from `remote.<name>.negotiationRestrict`, else each new value, with `negotiationInclude`, and what the remote acknowledges is left out of the pack; a negotiation that fails leaves nothing out. `fetch.negotiateOnly` is git's `git fetch --negotiate-only` (`fetch_pack.negotiateOnly`, `transport.Session.negotiateOnly`: `wait-for-done`, rounds until every tip reaches a commit known common; `NegotiateOnlyNeedsV2`, `WaitForDoneUnsupported`, `NegotiationRestrictNeeded`). Held to git 2.55: the same negotiation heard by git's upload-pack.
- `push.useForceIfIncludes` and `push.Options.force_if_includes` (`--force-if-includes`), as git's `check_if_includes_upstream`: a lease that expects the remote-tracking ref's value is refused (`rejected_remote_updated`, git's "remote ref updated since checkout") unless the remote's value is in the local ref's log, or reachable from a commit an entry names, back to the tracking ref's newest entry. Held to git 2.55's push.
- push's settings as git 2.55's: `push.pushOption` (`Options.push_options` `null`, an empty value clearing those before it), `push.followTags` and `Options.follow_tags` (git's `add_missing_tags`: each annotated tag the remote lacks on a commit a ref it will have reaches, pushed too, by `rev_walk.reachableSubset`, git's `get_reachable_subset`), `Options.set_upstream` (`--set-upstream`, git's `set_upstreams`: each branch the remote took or had tracks the branch it went to; `Outcome.upstreams`) and `push.autoSetupRemote` (a default push of a branch with no upstream goes to its own name and sets it); `commit.branch.installBranchConfig` (`TrackedRefs`) is git's `install_branch_config`, which `branch` and `push` share. Held to git 2.55's push.
- `log.date` and `log.decorate` as git 2.55's log reads them: `pretty.Context.date_mode` is how `%ad` and `%cd` show a date (`pretty.configuredDateMode` reads `log.date`, a mode git does not know `error.InvalidDateFormat`); every date placeholder is `text.date.show`, so `%ar` and `%ah` are written with `Context.clock`; `Decorations.configuredStyle` is `log.decorate`, `full` naming each ref whole in `%d`, `%D` and `%(decorate)`. Held to `git log --format` under each.
- Display notes as git 2.55's `load_display_notes` and `format_display_notes`: `commit.notes.DisplayNotes` opens the notes refs a log shows -- the default ref and `notes.displayRef`'s globs unless `notes.Display` says otherwise, then `--notes=<ref>`'s, each once -- and writes an object's notes from each. Held to `git log` and `--format=%N`.
- Fetch negotiation as git 2.55's: `fetch.negotiationAlgorithm` (`consecutive`, `skipping`, `noop`, `default`; `feature.experimental` making `skipping` the default; another name refused, `UnknownNegotiationAlgorithm`) as `fetch_pack.Negotiation`, the consecutive negotiator now git's `default.c` itself (its `mark_common` with ancestors only and without reading, its queue breaking a tie between equal dates by order queued) and the skipping one git's `skipping.c`; `remote.<name>.negotiationRestrict` and `fetch.Options.negotiation_restrict` (`--negotiation-restrict`), the only tips offered from, and `negotiationInclude` (`--negotiation-include`), haves offered whatever the negotiator chooses (`fetch_pack.Request.include_haves`), a name or a pattern over every ref, `Warning.negotiation_tip_unmatched` for a pattern that matches none, `NegotiationTipMissing` where git dies; and what the server is taken to have, as git's `mark_complete_and_common_ref` decides it: the remote's refs whose commit is complete here, our refs' history back to the newest of them, from every ref a v0 server advertised. Held to git 2.55: the same haves in the same rounds against git's upload-pack, in v2 and v0.
- Server options, as git's transport sends them: `transport.Options.server_options` (`--server-option`; `fetch.Options` and `clone.Options` pass theirs through), `null` taking `remote.<name>.serverOption` as git's handshake does (`remote.serverOptions`); sent with every v2 `ls-refs` and `fetch` in git's places (`protocol.CommandExtras`), and refused to a v0 or v1 server (`ServerOptionsNeedV2`) or a v2 one that does not advertise `server-option` (`ServerOptionNotSupported`), as git dies. `remote.Remote.negotiation_restrict` and `negotiation_include` are read. Held to git 2.55's fetch against git's upload-pack.
- A fetch's unpack limit, as git's `get_pack`: a pack of fewer than `fetch.unpackLimit` objects (else `transfer.unpackLimit`, else 100; every pack at 0) is stored loose once the refs name it, unless `fetch.Options.keep` (`--keep`), a promisor fetch, or objects checked one by one under `fetch.fsckObjects`; `Odb.unpackPack` is git's `unpack-objects` for a pack the database holds, and receive-pack's `receive.unpackLimit` now goes through it too. `fetch.Outcome.pack` is `null` when what came was stored loose. Held to git 2.55's fetch.
- `--recurse-submodules` for the updates of the working tree, as git 2.55's `submodule_move_head`: `submodule.Mover`, handed to `worktree.Rules.submodules`, `commit.reset.Options.submodules` or `merge.three_way.Options.submodules`, moves each active submodule whose gitlink a checkout, `checkout -- <path>`, reset or merge writes or removes -- a two-way `read-tree -m -u` unforced, refused where the submodule would lose work or its index has staged changes, then forced as git's `check_updates` forces every entry; `read-tree --reset -u` under `reset --hard`, which moves every submodule to its commit; `HEAD` detached at it, or the `.git` file, empty directory and `core.worktree` taken away; a `.git` directory absorbed first; a submodule's own submodules moved by a mover of its own. Every move is asked as a dry run before anything is written (`worktree.verifySubmoduleMoves`, the checks of `verify_uptodate`, `verify_absent` and `merged_entry`), a refusal `error.SubmoduleNotUpdated` with the paths in `Obstructions.submodules`; a submodule coming into being whose repository or commit is not there is refused then, where git dies halfway. `merge.three_way.Options.dry_run` is `read-tree -n`. `submodule.updatesRecurse` reads `submodule.recurse` under a `--[no-]recurse-submodules`. Held to git 2.55 for checkout and `reset --hard` over a changed, added, removed and nested submodule, with local changes, staged changes, untracked files and an inactive one.
- `grep.Options.recurse_submodules` (`null` reads `submodule.recurse`): each active submodule the pathspecs reach is searched in its gitlink's place, named from the top, from its index and working tree, or in a tree at the commit its gitlink records with its repository found in `modules` when it is not checked out, as git's `grep_submodule`; a tree's gitlink is entered only where a pathspec matches it, as `tree_entry_interesting` does. `submodule.openRepository` is git's `repo_submodule_init`; `submodule.gitmodulesOfTree` reads a revision's `.gitmodules`.
- `submodule.createBranches`, `git branch --recurse-submodules` as git 2.55's `create_branches_recursively`: the branch in the superproject and in every active submodule of the start's tree at its gitlink's commit, theirs in turn, each checked before any is made, each submodule tracking what the superproject's start is as its own remotes map it, `--track`, `--no-track` and `branch.autoSetupMerge` passed on as git passes them. `submodule.branchesRecurse` is `submodule.propagateBranches` with `submodule.recurse`. `commit.branch.resolveStart`, `setTracking`, `configuredTrack` and `Options.dry_run` are the pieces it shares with `branch.create`.
- format-patch reads its configured defaults as git's `git_format_config` does (step F group 14): `format.attach`, `cc`, `coverLetter` (`auto` too), `coverFromDescription`, `commitListFormat` (`shortlog`, `modern`, `log:<format>` or any format with a `%`), `encodeEmailHeaders`, `filenameMaxLength`, `forceInBodyFrom`, `from`, `headers` (`To:`/`Cc:` ones as addresses), `mboxrd`, `numbered` (`auto`; dropped under `-k`), `outputDirectory`, `signature`, `signatureFile`, `signOff`, `subjectPrefix`, `suffix`, `thread`, `to` and `useAutoBase` (`whenAble` too, with `--base=auto`'s merge base against the upstream), each overridden by the caller's option; `format.noprefix` (`diff.noprefix` is not format-patch's); and `format.notes` with `Options.notes` (`--notes`, `--notes=<ref>`, `--no-notes`, each over the settings as git applies them), the notes below a `---` after the message. `diff.statGraphWidth` and `statNameWidth` are left alone, as git's format-patch never reads them; `diff.stat.Widths.configured` reads them for a `git diff` or `git log --stat`. The apply backend of `rebase` passes `--no-cover-letter` and `--no-base` as git's does and its committer, so the other settings reach the mails it applies as they do in git.
- `pretty`: `%w(<width>,<indent1>,<indent2>)` wraps what follows as git's `rewrap_message_tail` does, and `%(count)`/`%(total)` number a commit in a list (`Context.numbered`), as git's cover letter lists them.
- Group 6's rest, on uplink 0.9.0: `http.pinnedPubkey` under `http.sslVerify=false` holds the server's key to the pins with nothing else checked, as curl does; `http.version=HTTP/2` over `http://` asks the server to upgrade (`Upgrade: h2c`, curl's `CURL_HTTP_VERSION_2_0`) and goes on in HTTP/2 when it switches, where curl's default asks nothing; `http.cookieFile`'s `Set-Cookie:` lines are read as curl reads them. Held to git 2.55 against relic's server and an `openssl s_server`.
- `rebase.autoStash` and `merge.autoStash` (`Options.autostash`, `--autostash`/`--no-autostash`, the setting when `null`, a value that is no boolean refused where git dies): the changes in the index and the working tree put aside as git's `create_autostash` puts them (`rebase-merge/autostash`, the `MERGE_AUTOSTASH` root ref, made before the merge locks the index) and brought back where git brings them back: a rebase's finish, its up-to-date end, `--abort`, and a start that fails (the state removed with it); a merge's fast-forward and commit, `conclude`, `abort`, and a failed merge; `commit.commit` after a squashed merge. `Outcome.autostash` is the stash made, and `stash.Restored` git's three messages: applied, kept on the list after a conflict or refusal, or stored unapplied (`rebase.quit`, `removeMergeState`). Held to git 2.55 in both ref formats, each side finishing what the other stopped.
- `merge.verifySignatures` (`merging.Options.verify_signatures`, `--verify-signatures`, the setting when `null`): every commit merged must carry a good signature, checked through `signing`'s programs, before anything moves, as git's `verify_merge_signature` checks it: no signature or one not good (an unknown SSH key, an expired one) is `MissingSignature`, a bad one `BadSignature`, a good one below marginal trust (git's own check, only while `gpg.minTrustLevel` is unset) or below `gpg.minTrustLevel` `UntrustedSignature`; `Options.unverified` names the commit and the signer. `Outcome.signatures` lists the good ones. A commit `HEAD` already has is not asked about. Held to git 2.55 in both ref formats with SSH signatures.
- `transport.pull` (`git pull`): git's `cmd_pull` over relic's fetch, merge and rebase. Before the fetch, a conflicted index or a waiting merge refuses it, and a rebase asks for a clean working tree unless `pull.autoStash` or `rebase.autoStash` puts the changes aside, and notes the fork point; a fetch that moves the branch checked out brings the working tree along (`Warning.pull_moved_head`); the heads are `FETCH_HEAD`'s, none refused with git's reason (`NoMergeCandidates`, `BranchNotGiven`, `NotOnABranch`, `NoDefaultUpstream`, `UpstreamNotFetched`); an unborn branch takes its one head as "initial pull", what the index holds kept; `pull.ff` (`only` giving way to an explicit rebase), `pull.rebase` and `branch.<name>.rebase` (`interactive` taken as written) decide between a fast-forward, a merge of `FETCH_HEAD` and a rebase onto the head from the fork point when the upstream was rewritten, and diverged branches with nothing said are `DivergentBranches`. `Options.reflog_action` is git's `GIT_REFLOG_ACTION` in every reflog line. Held to git 2.55 in both ref formats. `rebase=merges` rebases with `rebase_merges`; `submodule.recurse` is not acted on.
- `commit.replay` (`git replay`, git 2.55's `replay_revisions` and `cmd_replay`): the commits a range names made again in memory, without a working tree or an index, oldest first in graph order onto `--onto` (the branches the revisions name moving with them, every branch on a replayed commit with `contained`), onto `--advance`'s branch, or reverted newest first onto `--revert`'s branch, which moves; `--ref` moves one ref instead. A commit left empty is dropped, kept or stops it (`Options.empty`); a conflict stops it with no ref moved (`Outcome.stopped`); a merge commit is refused. The refs move in one transaction from the values they had, logged `replay --onto <commit>`, `replay --advance <branch>` or `replay --revert <branch>`, or are only returned (`RefAction.print`, `replay.refAction`). `replay.plan` makes the commits without moving anything, `replay.updateRefs` moves them. Held to git 2.55 in both ref formats.
- `commit.history` (`git history`, git 2.55's `builtin/history.c`): `fixup` merges what is staged into a commit (`HEAD` the base, as a cherry-pick of the staged changes), dropping, keeping or refusing one left empty; `reword` gives a commit a new message; `split` makes it two, the first with the tree the caller picked (what `add -p` leaves staged). The descendants are replayed onto the rewrite through `replay.plan`, and every branch on or above the commit (or `HEAD` alone, which must descend from it) moves in one transaction, logged `<subcommand>: updating <commit>`, or is returned on a dry run; a merge among them is refused before anything is written, a message is cleaned as git cleans what its editor returns. Held to git 2.55 in both ref formats.
- `rev_walk.last_modified` (`git last-modified`, git 2.55's `builtin/last-modified.c`): for each path of a commit's tree -- the top level, `max_depth` levels down or every file, subtrees with `trees`, under a pathspec -- the commit that last changed it, by git's walk: newest generation (a commit-graph's corrected dates) then date first, each path handed to the first parent that has it the same, a commit reached from `exclude` or past `max_count` a boundary. The entries come in git's order, a commit's own paths as git's hash map keeps them. Where a clock runs backwards and no commit-graph gives generations, git can walk a commit before a child that hands it paths and stops on its "paths remaining" bug; relic walks that commit again. Held to git 2.55, with and without a commit-graph.
- `rev_walk.follow` (`git log --follow -- <path>`, git 2.55's `try_to_follow_renames`): every commit newest first with no history simplified, merges passed by, each commit's diff from its parent limited to the path followed; where it creates a file, the whole diff searched for the path's source with the path the only destination (`diff.RenameOptions.single_follow`, git's `single_follow`) and renames and copies from any file found whatever `diff.renames` says, as `--find-copies-harder` turns copies on; the rename or copy shown and older commits following the source's path, which changes when the commit is met on whichever line of history. `follow.configured` reads `log.follow`. Held to git 2.55's `--name-status` under every `diff.renames`.
- `diff.blame.Options.ignore` (`--ignore-rev`, `--ignore-revs-file`, `blame.ignoreRevsFile`): an ignored commit's changed lines go to the parent lines git 2.55's `guess_line_blames` finds for them -- fingerprints of each line's byte pairs, the surest match first with its pairs taken out of the parent line, the lines on either side matched within the parent lines on either side, the ten nearest compared, a line no part of the change matches looked for in the whole parent file -- marked `Hunk.ignored`; a line none is found for stays the commit's, `Hunk.unblamable`. `blame.ignoredRevisions` reads the files as git's `build_ignorelist` does (`blame.ignoreRevsFile`'s values sorted and each once, as `string_list_insert` keeps them, then the files given, an empty name forgetting; full object names peeled to commits, comments and blank lines left out), and `blame.marks` reads `blame.markIgnoredLines` and `blame.markUnblamableLines`. Held to git 2.55's porcelain, over random histories and random reformats.
- `commit.branch` (`git branch <name> <start>`, git 2.55's `create_branch`, and `--set-upstream-to`, its `dwim_and_setup_tracking`): the branch made at a revision with git's `branch: Created from`/`Reset to` line, refused where git refuses (an invalid name, an existing branch without `force`, one a worktree has checked out, a start that is no commit or names two refs); its upstream set up as `branch.autoSetupMerge` says (`true` for a remote-tracking start, `always`, `inherit`, `simple`, `false`) or `Options.track`, through the remote whose fetch refspec maps the start (`wire.remote.Remote.sourceOf`, git's `remote_find_tracking` by destination; two remotes refused), `.` for a local start, and `branch.<name>.rebase` as `branch.autoSetupRebase` says. `branch.<name>.mergeOptions` read as `git merge` options under the caller's (long options by any unique beginning, `--no-`, bundled short ones; what this merge does not do refused by name). `repo.head.checkedOutBranches` (git's `prepare_checked_out_branches`, which rebase now shares) and `text.quote.splitCmdline`. A configured remote with no URL keeps its refspecs, the name taken as the URL, as git's `add_url_alias` does. Held to git 2.55.
- `rebase.instructionFormat` writes a sheet's lines through `pretty` (`# ` before a format without one; `%h` the full name, as git's sheet context gives no abbreviation), and `rebase.missingCommitsCheck=error` refuses a sheet that leaves commits out without `drop`: the sheet kept as it was left, git's `dropped` marker, `onto` checked out, `Stop.missing_commits`, and `proceed` checks the corrected sheet against `git-rebase-todo.backup` again; the help says "Do not remove any line" then, as git's. `--apply` with `rebase.updateRefs` set is `ApplyWithUpdateRefs`, and `reschedule_failed_exec` with the apply backend `RequiresMergeBackend`. Held to git 2.55.
- A rebase given `exec` keeps commits that become empty when `empty` is `null`, as git's `EMPTY_KEEP` default under `--exec`; `proceed` and `skip` write `rebase-merge/end` again as git's `read_populate_todo` does.
- The apply backend of `rebase` (`rebase.Options.backend = .apply`, `--apply`; `rebase.backend` when `null`, the merge backend wherever an option only it has is asked for, `RequiresMergeBackend` and `ApplyWithRebaseMerges` where git refuses, `UnknownRebaseBackend`): `HEAD` detached at `onto` (`rebase (start): checkout <onto>`), a branch with nothing of its own fast-forwarded, else its commits written as git's `format-patch -k --full-index --cherry-pick --right-only --no-renames --pretty=mboxrd --topo-order` writes them and applied by `am --rebasing`, the branch moved back with git's `(finish)` lines; a stop leaves git's `rebase-apply` with the rebase's `head-name`, `onto`, `orig-head` and options, and `proceed`, `skip`, `abort` and `quit` take up a rebase either backend left. `patch.am.Options.rebasing` (git's `--rebasing`: each mail is the commit its `From` line names, author, message and patch taken from it, three-way always, `rewritten` recorded, notes copied as `Notes added by 'git rebase'` and `post-rewrite` run at the end, the directory left for the rebase) and `reflog_action`; `patch.format.Range.exclude` and `Options.topo_order`; `notes.RewriteOptions.message`. Held to git 2.55: clean, stopped and continued, skipped or aborted by either side, in both ref formats for the clean rebase.
- `am`'s three-way fallback records a conflicted result in `AUTO_MERGE`, as merge-ort's `merge_switch_to_result` does under `git am -3`.
- `rebase.Options.fork_point` (`--fork-point`, `--no-fork-point`) and `default_upstream`: the commits replayed are those after where the branch forked from the ref `upstream_name` names, by its reflog (`rev_walk.fork_point`, git's `get_fork_point` and `restrict_revision`), so a commit the upstream once had and dropped is left out, and a branch whose fork point is not `onto` is not up to date; `null` is git's default, on for a rebase onto the branch's own upstream unless `rebase.forkPoint` is false. Held to git 2.55 in both ref formats.
- `rebase.Options.rebase_merges` (`--rebase-merges[=rebase-cousins|no-rebase-cousins]`, `--no-rebase-merges`, `rebase.rebaseMerges` when `null`, a mode git does not know refused as git dies on it): the sheet git's `make_script_with_merges` writes -- `label onto`, each run of commits from a tip back to where it leaves the others after a `reset` (to `onto`, to a label, to a commit not rebased by its short name, or to `onto` with `rebase-cousins`), `label`s where a merge takes a branch in (the branch's name, else the merge message's) and where a second child leaves a commit (`branch-point`), sanitized and cut to `rebase.maxLabelLength` as git cuts them, and `merge -C` for each merge, octopus included -- in `plan` and `start`. `transport.pull`'s `rebase=merges` rebases with it. A sheet's subjects follow `# ` whatever `core.commentChar` says, as git's `# %s` format writes them. Held to git 2.55 in both ref formats: the sheet, then the commits, refs and logs.
- `transport.backfill` (`git backfill`, git 2.55's `builtin/backfill.c`): a partial clone's missing blobs fetched from the promisor remote in batches by path, a batch asked for once it holds `min_batch_size` (50000) and the rest at the end, from `HEAD` or the commits given less the excluded ones' history, with the trees of the excluded parents at the range's edge (`include_edges`), `first_parent`, under a pathspec, within the sparse checkout (`sparse`, `core.sparseCheckout` when `null`; directories outside a cone passed by) or a `sparse:oid=` filter's cone. A blob size limit, a filter the path walk lacks and sparse checkout without patterns are refused as git refuses them. Held to git 2.55: the same objects fetched, in the same packs.
- `rev_walk.path_walk` (git 2.55's `path-walk.c`): the commits, trees and blobs a history reaches, in batches by the path that reaches them, in git's order -- blob batches before tree batches, each by path, so the trees are gone down depth first -- each object once, at the first path that reaches it; submodules passed by; `paths` limiting the commits and the blob batches, a pathspec of plain paths also the entries walked (compared as git's `dir_prefix` compares them); sparse-checkout patterns, in cone mode or not, passing by blobs and, with `sparse_trees`, trees; `edges` giving the hidden parents' trees first; `filter` taking `blob:none`, `blob:limit=`, `tree:0`, `object:type=`, `sparse:oid=` (in cone mode, a tree already walked outside the cone walked again inside it) and `combine:`. `pathspec.Pathspec.isExact` and `sparse.Patterns.decides` (git's `path_matches_pattern_list`).
- `diff.TreeOptions.paths`, `max_depth` and `trees`: a tree diff under a pathspec, a subtree below the depth listed as one change and not entered (git's `--max-depth`, its levels counted from the top or from the pathspec item, `check_recursion_depth`), and subtrees entered listed ahead of their contents (`-t`); held to `git diff-tree`. `pathspec.Pathspec.hasWildcard` and `entersAt`.
- `merge.three_way.inCore`: git's `merge_incore_nonrecursive` with the merge's settings and attributes read as for a merge in the working tree, nothing but objects written; `three_way.Options.basic` leaves `diff.algorithm` unread, as `init_basic_merge_options` does.
- `rev_walk.Walk.ancestry_path` (`--ancestry-path`, `--ancestry-path=<commit>`): only the commits that reach one given, or that one reaches, as git's `limit_to_ancestry` and its flag passed to the parents walked keep them.
- `repo.rev_parse.dwimRef` (git's `repo_dwim_ref`): a short name by `ref_rev_parse_rules`, with `@`, `@{-<n>}`, `@{upstream}` and `@{push}` put in place first, how many rules name a ref under `core.warnAmbiguousRefs`, and the first; `for-each-ref`'s and `bundle create`'s lookups go through it. `pretty.Decorations.of` is git's `get_name_decoration`.
- `rev_walk.fork_point` (`git merge-base --fork-point`, git's `get_fork_point`): where a branch forked from a ref, through every value the ref's log names.
- `commit.merging.fetchHead` (`git merge FETCH_HEAD`): the lines marked for merging, each named by its object and described as the line says, so the message is git's `Merge branch 'main' of <url>`; the title groups targets by where they came from, as `fmt_merge_msg_title` does. `merging.Options.reflog_action` and `rebase.Options.reflog_action` (git's `GIT_REFLOG_ACTION`); `merging.verify` (the signature check alone) and `rebase.requireCleanWorkTree` are public.
- `merge.three_way.fastForward` (git's `checkout_fast_forward`, a two-way `read-tree -m -u`), the one path for a merge's and a pick's fast-forward, a rebase's checkouts and bisect's.
- `transport.remote.fallback`: git's `remote_for_branch` with no branch remote, the only remote configured, else `origin`.
- `commit.stash.create` and `stash.store` (`git stash create`, `git stash store`) beside `push`, one path making all three; `stash.createAutostash`, `stash.restoreAutostash` and `stash.restoreStash` for an operation's autostash.
- `refs.Transaction.allow_failure`, git's `REF_TRANSACTION_ALLOW_FAILURE`: an edit refused for what it asks (its expected value not met, its name in conflict with a ref or another edit) is left out and listed in `Transaction.rejected` (`refs.Rejected`: the name, a `refs.Rejection` with git's `ref_transaction_error_msg`, and git's own words for it), and the rest are written; a failure that is not the edit's own still fails them all. Both ref formats, each in its git backend's order and words (the files backend meets loose refs as it locks, `packed-refs` and the other edits once all are held; reftable checks the names once every value is). `reference-transaction` is still shown a refused edit, as git shows it.
- receive-pack's `proc-receive` hook, as git 2.55 runs it: the commands under `receive.procReceiveRefs` (a ref prefix matched whole, after optional `a`/`d`/`m`/`!` modifiers) are scheduled before `pre-receive`, which sees them, and handed to the hook once the objects are moved, in git's pkt-line conversation (the version with `atomic` and `push-options`, the commands, the push options when the hook asks for them). Its report is taken as git takes it: `ok` with `option refname`/`old-oid`/`new-oid`/`forced-update`, several for one ref, carried to report-status-v2 and `post-receive`; `ng` with or without a reason; `option fall-through`, which hands the ref back to receive-pack; and git's words for each fault (an unknown or unexpected ref, a bad status, an option with no `ok`, a ref left unanswered, an exit before answering, a version it cannot speak, `cannot find hook 'proc-receive'`), a failed hook failing the refs it did not answer for and an atomic push whole. Its standard error reaches the client as it writes it. `hooks.Runner.start` starts a hook for such a conversation.
- Signed pushes, as git 2.55 makes and takes them. receive-pack under `receive.certNonceSeed` asks for a certificate (`push-cert=<nonce>`, the nonce git's HMAC of the seed keyed with the served path and the time, in the repository's hash; `Options.service_dir`), reads it in place of the commands, refuses every command when its `push-option`s are not the ones sent (`inconsistent push options`), keeps it as a blob and tells `pre-receive` and `post-receive` `GIT_PUSH_CERT`, `_SIGNER`, `_KEY`, `_STATUS`, `_NONCE`, `_NONCE_STATUS` and `_NONCE_SLOP`: the signature checked through `signing` (`signing.Result.checkLetter`, the letter git's check records), the nonce held to the one asked for, or over HTTP recognised by its HMAC and judged against `receive.certNonceSlop`. `push.Options.signed` and `push.gpgSign` (`always`, `if_asked`, `never`; `send_pack.PushCert`) sign a push: the certificate (`pusher` as git's `get_signing_key_id` names the key, `signing.Signer.keyId`; `pushee`, the nonce, the push options, the commands) signed through `signing` and sent in place of the commands (`send_pack.Request.certificate`, `transport.Session.certOffer`); a server that asks for none refuses an `always` push before anything is sent (`SignedPushUnsupported`) and takes an `if_asked` one unsigned with git's warning (`warning.Warning.push_cert_not_asked`); a nonce git would not sign is `InvalidPushCertNonce`, a `push.gpgSign` that is neither a boolean nor `if-asked` `InvalidPushGpgSign`; a remote helper is told `option pushcert`. Held to git 2.55 both ways with SSH signatures, over ssh and HTTP, the nonce's HMAC checked against git's own in SHA-1 and SHA-256.
- `receive.denyCurrentBranch=updateInstead`, as git 2.55 takes it: a push to a branch a working tree has checked out, the main one or a linked one, brings that working tree along once every other check has passed. The `push-to-checkout` hook decides when there is one (the new commit its argument, `GIT_DIR` and `GIT_WORK_TREE` set; `push-to-checkout hook declined`); otherwise git's `push_to_deploy`: refused when the index is conflicted or locked (`Up-to-date check failed`), when the working tree differs from the index (`Working directory has unstaged changes`) or the index from `HEAD` (`Working directory has staged changes`), submodules and untracked files aside, and when an untracked file is in the way (`Could not update working tree to new HEAD`); an unborn branch's files appear.
- `maintenance.repack`: git 2.55's `repack` (`builtin/repack.c`, `repack*.c`, `pack-objects`' paths it asks for). `RepackMode` `.loose` (git's default, `--unpacked --incremental`), `.all` (`-a`), `.all_loosen` (`-A`) and `.cruft` (`--cruft`); `-d`, `-k` (with `--pack-loose-unreachable`), `--unpack-unreachable`, `--cruft-expiration`, `--max-cruft-size`, `--combine-cruft-below-size`, `--max-pack-size` (else `pack.packSizeLimit`, at least a megabyte), `-l`, `--keep-pack`, `--pack-kept-objects` (`repack.packKeptObjects`), `-b` (`repack.writeBitmaps`/`pack.writeBitmaps`, by default for `-a` in a bare repository), `-n` (`repack.updateServerInfo`), `repack.cruftWindow`/`cruftDepth`/`cruftThreads`, a promisor pack of its own, `prune-packed` and the shallow boundary's gone commits after `-d`. What is reached is `pack-objects --all --reflog --indexed-objects` (`maintenance.reachableToPack`); a cruft pack holds the unreachable objects with each one's newest time (with an expiration, the recent ones by time or `gc.recentObjectsHook` and what they reach, at the expiration); `-A` writes each unreachable object of a pack it removes loose with its pack's time (`Odb.loosen`). Every new pack is written, and every loosened object, before a pack goes. Refusals as git's: `IncompatibleOptions`, `IncrementalBitmaps`, `PreciousObjects`. Held to git 2.55 in every mode, both ref formats (each pack's objects and kind, a cruft pack's times, the loose objects and their times, `.git/shallow`, `info/refs`, `objects/info/packs`), and at every crash point on shakedown's simulated disk for `-a -d` and `--cruft -d`.
- `maintenance.RepackOptions.geometric` (`--geometric=<factor>`, git 2.55's `repack-geometry.c`): the packs that are not kept or cruft, an alternate's too but for `-l`, weighed by their objects, and those that break the progression rolled up with every loose object into one pack, as `pack-objects --stdin-packs --unpacked` with the packs left `^`-marked; promisor packs weighed apart and rolled up into a promisor pack of their own; with `-d` the rolled-up local packs go. `RepackOptions.write_midx` (`--write-midx`): a multi-pack index over the kept packs, the new ones, those that stay and the cruft packs, preferring the largest that stays or else the first new one that is not cruft, carrying the bitmap `-b` asks for, the bitmaps of the packs it covers removed (`write_midx_included_packs`, `remove_redundant_bitmaps`). `RepackReport.midx`. Each held to git 2.55 in both ref formats; crash-tested on the simulated disk.
- `maintenance.gc` (`git gc`, git 2.55's `cmd_gc`): `GcOptions.auto` runs only past `gc.auto` (the loose objects of `objects/17` times 256, above the setting rounded up to 256) or `gc.autoPackLimit` (local packs without a `.keep`), keeping the packs at least `gc.bigPackThreshold` large (only the largest when they are too many), and only when the `pre-auto-gc` hook agrees; then, under `gc.pid` (`<pid> <host>`, a holder within twelve hours on another host or still running stops it: `error.GcRunning`, or with `auto` `GcOutcome.running` and the `GcHolder`; `force` aside), `pack-refs --all --prune` (`gc.packRefs`, `notbare`), `reflog expire --all` (unless both expiries are `never`), `repack -d -l` as `add_repack_all_option` sets it (`-a` for `--prune=now`, else `--cruft` with `--cruft-expiration` and `gc.maxCruftSize` under `gc.cruftPacks`, else `-A --unpack-unreachable`; `aggressive` with `gc.aggressiveWindow`/`Depth`; `keep_largest_pack`), `prune --expire` (`gc.pruneExpire`, `GcPrune`), `worktree prune --expire` (`gc.worktreePruneExpire`), `rerere gc`, the pack directory's garbage, the commit graph (`gc.writeCommitGraph`), and with `auto` whether too many loose objects are left. `detach` (`gc.autoDetach` with `auto`) is git's detached run as the repository sees it: a `gc.log` newer than `gc.logExpiry` stops it (`GcOutcome.last_failed`), and its failure or warning is recorded there. Held to git 2.55's `gc` in both ref formats; the commit graph it writes crash-tested on the simulated disk.
- `maintenance.run` (`git maintenance run`, git 2.55's `maintenance_run`): its ten tasks (`maintenance.Task`: prefetch, loose-objects, incremental-repack, geometric-repack, gc, commit-graph, pack-refs, reflog-expire, worktree-prune, rerere-gc) as `selectTasks` chooses them (`--task`, else `maintenance.strategy` -- `geometric` unless set for a manual run, none for a scheduled one -- with `maintenance.<task>.enabled` and, under `--schedule`, `maintenance.<task>.schedule`), each with `--auto` only when its condition says so (`maintenance.<task>.auto` and git's counts: loose objects, packs no multi-pack index covers, the geometric split, commits the commit graph lacks, `HEAD`'s entries reflog expire would take, prunable worktrees, `rr-cache`, `refs.Store.packRequired`, gc's `need_to_gc` with the `pre-auto-gc` hook), under `objects/maintenance.lock`, the foreground tasks first; a task that fails leaves the others (`RunReport.outcomes`). The prefetch fetches through `maintenance.Prefetch`, which `transport.fetch.Prefetcher` gives. `maintenance.isNeeded` (`maintenance is-needed`), `maintenance.autoMaintenance` (`prepare_auto_maintenance`: `maintenance.auto` else `gc.auto`, `maintenance.autoDetach` else `gc.autoDetach`). `maintenance.register` and `unregister` (`maintenance.auto`, `maintenance.strategy`, `maintenance.repo` in the file given, git's global one or `--config-file`). `maintenance.schedulerRegistration` and `crontab`: what `maintenance start` registers with launchd, systemd timers and schtasks, and the crontab region, byte for byte, as data. Held to git 2.55 (the tasks git's trace2 regions show, what each leaves, `maintenance start`'s files under git's scheduler mocks, `register`'s config); the loose-objects and incremental-repack tasks crash-tested on the simulated disk.
- `transport.fetch.Options.prefetch` (`--prefetch`, git's `filter_prefetch_refspec`) and `transport.fetch.prefetchAll`; `wire.remote.Remote.skip_default_update` (`remote.<name>.skipDefaultUpdate`).
- `config.write.Edit.add` (`git config --add`) and `Edit.unset.value` (`--fixed-value --unset-all`); `config.Config.addIn` and `unsetValueIn`.
- `pack.WriteOptions.prefix` and `odb.PackOptions.prefix`: a pack named as `pack-objects <base>` names it, `loose-<name>` for the loose-objects task. `Odb.countLoose`; `Odb.PackListing.in_midx`.
- `maintenance.planGeometry` (the geometric split `repack --geometric` and the geometric-repack task share), `maintenance.gcAutoNeeded`, `maintenance.countExpiring`; `maintenance.Maintenance.maintenance` for the commit-graph task (`--split`, under `core.commitGraph`).
- The pack and loose-object settings git's pack-objects and object writer read: `pack.window`, `pack.depth` (0 to 4095), `pack.windowMemory`, `pack.compression` and `core.looseCompression`, each else `core.compression` (-1 zlib's default, 0 to 9), `pack.indexVersion` (git's version 1 index, version 2 past two gigabytes) and `core.multiPackIndex` (off, no multi-pack index read), as `odb.Packing` in the database's options, refreshed with the configuration; `Odb.packOptions` is what a pack is built with unless its caller says otherwise, and `repack`, `gc`, `maintenance`, bundles, upload-pack, send-pack and a local copy take it. `pack.Compression` holds any level; `pack.IndexWriteOptions.version`. Held to git 2.55's packs and loose objects under each setting.
- The commit graph's changed-path filters as git 2.55 writes them: `commitGraph.changedPathsVersion` (else -1, or 0 under `commitGraph.readChangedPaths=false`, which carries no filter into the next graph; another version writes no graph, as git only warns), and for `maintenance`'s commit-graph task `commitGraph.changedPaths` and `commitGraph.maxNewFilters` (`CommitGraphOptions.max_new_filters`: by generation, then date; a filter the graph holds is kept). Held to git's `maintenance run --task=commit-graph`.
- `maintenance.migrateRefs` (`git refs migrate`, git 2.55's `repo_migrate_ref_storage_format`): every ref (root refs, symbolic refs and broken ones included) and, unless `reflogs` is off, every log entry as it was, written into a store of the other format in `ref_migration.XXXXXX`; with `dry_run` left there, else the old store removed (`refs.removeOnDisk`, git's `ref_store_remove_on_disk`), the new one moved into its place and `core.repositoryformatversion` and `extensions.refStorage` written as `initialize_repository_version` writes them. A repository with linked worktrees is refused, as git refuses it; the swap is git's, so a crash between the removal and the move leaves the refs in that directory. Held to git 2.55 both ways.
- Delta islands (`pack.island`, `repack.useDeltaIslands`, `maintenance.RepackOptions.delta_islands` for `-i`): each `pack.island` a regular expression over ref names, anchored as git anchors it, the island a ref is in named by the last matching one's groups joined by `-`, every object its refs reach in it (`maintenance.loadIslands`); the reachable objects' pack writes no object as a delta of one in fewer islands, nor keeps a stored delta that is (`odb.islands`, `PackOptions.islands`, git's `in_same_island`). `pack.islandCore` is read for nothing: it orders git's pack, never what it holds. Held to git's `repack -i`.
- `text.ere.Regex.findGroups`: what each group took, as `regexec` reports it, sixteen at most.
- `maintenance.RepackOptions.expire_to` (`--expire-to`, with `--cruft -d`): what is about to go -- the objects of the packs taken away and the loose ones no new pack holds -- written first into a cruft pack of its own in the directory given, as git's second `write_cruft_pack` writes it; `GcOptions.expire_to`, with which `--prune=now` takes the cruft path, as `add_repack_all_option` does. `RepackReport.expired_written`. Held to git 2.55, but for the second copies git's `want_cruft_object_mtime` bug makes of objects its own cruft pack holds.
- `maintenance.RepackOptions.filter` (`--filter`, a walk filter `wire.filter_spec.toWalk` makes from a spec) and `filter_to` (`--filter-to`): the reachable objects' pack leaves out what the filter does, but for the objects the index names, and what it left out of the packs taken away goes into a pack of its own, beside them or in the directory given (`write_filtered_pack`). `GcOptions.filter`, else `gc.repackFilter` and `gc.repackFilterTo` for the repack of every pack. `RepackReport.filtered_written`. `wire.filter_spec.toWalk` is the one conversion of a spec to a walk filter, upload-pack's too. Held to git 2.55.
- `Odb.removePackGarbage`: the files of a pack with an index and no pack, as `gc` removes what `prepare_packed_git_one` reports.
- `fs.hostName` (conduit's), `fs.currentPid` and `fs.processAlive` are public.
- `maintenance.MidxOptions.packs`: the packs a multi-pack index covers, as `multi-pack-index write --stdin-packs`, the earlier index's assignments not carried over.
- `maintenance.updateServerInfo`: git's `update-server-info` (`info/refs` with peeled tags, `objects/info/packs` keeping the order the file had, `info/rev-cache` removed), each file replaced only when it would change; `repack` runs it.
- `odb.mtimes` writes a cruft pack's `.mtimes` too (`pack.WriteOptions.mtimes`, `PackOptions.mtimes`), renamed into place before the `.idx`.
- `maintenance.repositoryTips`: the commit every ref names, peeled.
- `Odb.writePacks`: `writePack` under a size limit (`SplitOptions`), the entries cut by what each takes here and a pack that comes out larger written again as two, each pack whole.
- `Odb.removePacks` (git's `unlink_pack_path`, the `.idx` first, a kept pack left, the multi-pack index cleared when it names one), `Odb.prunePacked` (`prune-packed`), `Odb.listPacks` (the own directory's, or with each alternate's as `repo_for_each_pack`, each marked local or not), `Odb.packNamed`, `Odb.isPacked`, `Odb.hasAlternates`.
- `odb.mtimes`: a cruft pack's `.mtimes` read as git's `load_pack_mtimes_file` checks it.
- `gc.recentObjectsHook` in `maintenance.reachableObjects` and `prune` (`ReachOptions.programs`, `PruneOptions.programs`): each value run through the shell where git runs, its output one object name per line, the objects named recent whatever their time and what they reach kept; run once, at the first object too old to be recent, as git loads it. Without `programs` it is `ProgramsNotGranted`; a failed command `RecentObjectsHookFailed`, a line that is no object name `InvalidRecentObject`, as git dies; a bare value `MissingValue` (git reports it and runs no hook). Held to git 2.55's prune, as are a git-written cruft pack's per-object times.
- `receive.unpackLimit`, else `transfer.unpackLimit`, else git's 100: a pushed pack of fewer objects is stored loose, as git's `unpack-objects` stores it (an object the repository holds already, a thin pack's base among them, not written again), once the refs are written: until then it is held as any received pack is, a pack with its `.keep`, against a collection running beside the push. One at the limit or above is kept as a pack; a failure below it is `unpack-objects abnormal exit`. A pack whose header does not read is refused before anything is kept, in git's `parse_pack_header` words.
- `receive.keepAlive` (default 5 seconds; zero or less, none): from the pack's end, or from the commands of a push that only deletes, receive-pack sends git's keepalive, an empty packet on side-band channel one, whenever the client has heard nothing for that long, as git's muxers send it while index-pack, the connectivity check and the hooks run.
- `receive.updateServerInfo`: after a push's last hook, receive-pack writes the dumb HTTP files again (`info/refs`, `objects/info/packs`) through `maintenance.updateServerInfo`, as git's does, what that comes to not the push's to answer for.
- receive-pack's aliased updates, as git's `check_aliased_updates`: a command on a symbolic ref whose target another command of the push updates is left to that one when the two agree, and both are refused (`inconsistent aliased update`, with git's message naming both and their values) when they do not; a symbolic ref that leads nowhere a ref can be is refused (`broken symref`).
- `transport.http_backend` serves the dumb protocol's files as git's http-backend does, unless `http.getanyfile` is off (403): `HEAD`, `info/refs` without a service (every ref, an annotated tag's peeled object after it) and `objects/info/packs` made as they are asked for, the alternates files, and loose objects, packs and pack indexes from the repository with git's cache headers; held to git's dumb client cloning and fetching.
- `lfs.server.Transfer`: git-lfs's pure-ssh protocol (`git-lfs-transfer <path> <operation>`, version 1) served over the same `Store` and locks as the HTTP backend, for an ssh server to run: `serve` a whole connection (`Connection`), or a `Session` (`greet`, `next`, `answer`) request by request. `batch` answers each object with the connection's action on it, objects move through the store in packets as they come (an upload kept only when its SHA-256 and length are the ones it was sent for), `lock`, `list-lock` and `unlock` keep the locks in `<git dir>/lfs/locks.json`; `Caller.authorize` decides each request as the HTTP backend's does, and actions may carry an id and token the caller makes and checks (`Tokens`). The suite's own `git-lfs-transfer` is now this server, held to git-lfs's and relic's clients.
- upload-pack's `uploadpack.allowRefInWant` (`Options.allow_ref_in_want`): protocol v2's `ref-in-want`, a `want-ref` naming a ref the client may see, refused as git's `unknown ref` or `duplicate want-ref`, answered in a `wanted-refs` section before the pack; and `uploadpackfilter.*`: `allow` for every filter, `<filter>.allow` for one, `tree.maxDepth` allowing `tree` to that depth, each filter a combine holds checked too, refused in git's words (`filter '<name>' not supported`, `tree filter allows max depth <n>, but got <m>`).
- `worktree.remove` (`git rm`, git 2.55's `builtin/rm.c`): the index entries the pathspecs name taken out and, unless `cached`, their files and the directories they leave empty; `check_local_mod`'s refusals (`Outcome.staged_and_local`, `staged`, `local`) unless `force`; `recursive`, `ignore_unmatch`, `dry_run`; entries outside the sparse-checkout cone only under `sparse`, else `Outcome.sparse_only` (git's advice and exit 1); a submodule's `.git` directory absorbed before its working tree goes, its `.gitmodules` section removed and the file staged. Held to git 2.55 for files, directories, submodules and a sparse cone.
- `worktree.move` (`git mv`, git 2.55's `builtin/mv.c`): a file or directory renamed, or several moved into a directory, in the working tree and the index together, each source checked as git checks it (`Outcome.refusal` with git's reason, or under `skip_errors` passed over into `Outcome.skipped`); `force`, `dry_run`; a submodule's `.gitmodules` path rewritten and staged and its `.git` file and `core.worktree` reconnected, nested submodules too; across the sparse-checkout cone only under `sparse` (a dirty file moved out of the cone stays, `Outcome.dirty`); a case-only rename under `core.ignoreCase`, a directory's refused as git fails it (`error.DirectoryIntoItself`). Held to git 2.55 for files, directories, submodules (in place and absorbed) and a sparse cone.
- `index.Index.rename` (git's `rename_index_entry_at`, replacing what the new name collides with); `submodule.gitmodulesStaged`, `removeFromGitmodules`, `moveInGitmodules`, `gitDirOf` and `connectGitDir` (git's `connect_work_tree_and_git_dir`); `patterns.pathspec.normalize`. `checkout.AddOptions.prefix` may name one file.
- `worktree.ignoreErrorsConfigured`: `add.ignoreErrors`, or `add.ignore-errors`, the last of either deciding, as git's `add_config` reads them, for `AddOptions.ignore_errors`. Held to `git add -A`.
- `repo.Repository.indexWriteOptions`: the index written as git 2.55's settings say -- `index.version` for a new index (`feature.manyFiles` makes it 4), `index.skipHash` (on under `feature.manyFiles`), `EOIE` and `IEOT` by `index.recordEndOfIndexEntries`, `index.recordOffsetTable` and `index.threads` -- which `LockedIndex.commit` writes with. Held to git 2.55's index files under each setting.
- `index.untracked`, git's untracked cache (`UNTR`): read (`Index.untracked`; a malformed one dropped, `Dropped.untracked_cache`), kept true as entries come and go -- a path that joins or leaves the index invalidates the directories it is in, and each above it under `DIR_SHOW_OTHER_DIRECTORIES`, as git's `untracked_cache_add_to_index` and `remove_from_index` do -- and written back. `core.untrackedCache` (else `feature.manyFiles`) read as git's `tweak_untracked_cache` reads it whenever the repository reads its index: `true` gives the index a new cache where it has none or one made elsewhere (git's ident, `status.showUntrackedFiles` deciding its flags), `false` takes it away. Held to git 2.55: a cache git filled written back byte for byte, git's new one, and after each add and removal git's directories and git's next status.
- The split index as git 2.55 writes it (`split-index.c`): `core.splitIndex` splits the index or writes it whole, unset keeps what it is; an entry carries its place in the shared index (`Entry.shared_at`, git's `ce->index`) and a write compares it there -- unchanged and not racy it stays shared, changed it is a replacement written with no name, the shared entries no entry holds any more are deleted, the rest written after -- in the `link` extension's two bitmaps; a new shared index (`Index.writeShared`, `sharedindex.<checksum>`, no extension but the offset tables) when there is none or more than `splitIndex.maxPercentChange` (20 percent; 0 always, 100 never) of the entries are not in it, the others older than `splitIndex.sharedIndexExpire` (two weeks, counted from the new file's time) removed (`Index.removeSharedBefore`), and the one a write stands on freshened. `Index.useSplit`, `dropSplit`, `notShared`. Held to git 2.55: twin repositories, git's write and relic's, leave the same main file and shared index, and git reads relic's as its own. `codec.ewah.writePositions`.
- `diff.textconv` (`diff.<driver>.textconv`, `diff.<driver>.cachetextconv`): a file whose driver has a `textconv` is diffed, blamed and searched as the program's text, as git 2.55's `fill_textconv` makes it, never binary once converted -- `diff.UnifiedInputs.textconv` (on in `git diff` and `git log -p`; a change whose sides convert to the same text is not written), `blame.Options.textconv` (on in `git blame`), `grep.Options.textconv` (`--textconv`) and `range_diff.Options.textconv` (on in the `git log -p` range-diff reads); a program that fails is `error.TextconvFailed`. `commit.notes.TextconvCaches` keeps the texts in git's `refs/notes/textconv/<driver>`, its commit named for the command, and takes them from there. `fs.TempFile` is the temporary file git names `<random>_<name>`, which `signing` writes too.
- Function lines by the diff driver (`diff.driver`): a patch's `@@` lines carry what the driver's `diff.<driver>.xfuncname` or `funcname`, or git's built-in pattern for one of its 27 drivers (`python`, `cpp`, `rust` and the rest, some blind to case), takes for the start of a function -- its first group, else the whole match, a negated line refusing -- the old side's driver before the new one's, as git 2.55's `diff_funcname_pattern` and `ff_regexp` find them; in `diff.unified`, `patch.format` and `patch.range_diff`. `diff.FilePair` is one file pair as `builtin_diff` compares it (each side's driver, its text after `textconv`, whether it is binary, its function lines), which `unified` and range-diff share.
- Word diff as git 2.55's (`diff.Options.word_diff`, `diff.WordDiff`: `--word-diff=plain|porcelain|color`, `--color-words`): the removed and added lines of each run diffed as words, the words kept written as the new side has them and the others marked `[-...-]{+...+}`, a line each after `-`/`+`/` ` with `~` for a newline, or in colour alone; words are what `Options.word_regex` (`--word-diff-regex`) matches, else the old side's driver's `diff.<driver>.wordRegex` or built-in words (git's 27, with userdiff's `|[^[:space:]]` and UTF-8 tail), else the new side's, else `diff.wordRegex` (`configured_word_regex`, read by `diff.configured`), else runs of bytes that are no space.
- External diff as git 2.55's (`diff.external`: `External`, `UnifiedInputs.external`, `git diff --ext-diff`): `diff.external` (`external.configured`, with `diff.trustExitCode`; a caller's `GIT_EXTERNAL_DIFF` in its place) and a driver's `diff.<driver>.command` and `trustExitCode` (`driver.Driver.command`, the driver found by the path's attribute alone, `driver.Drivers.ofPath`) run through the shell for a file pair in place of its patch, with git's arguments -- the path; each side's file, object and mode (`/dev/null . .` for none); for a rename or a copy the new path and the metadata lines -- and `GIT_DIFF_PATH_COUNTER`/`GIT_DIFF_PATH_TOTAL`. A side is a temporary `git-blob-XXXXXX/<name>` holding the blob as a checkout writes it, or, where the caller's diff read the index (`Worktree.lends`), the working tree's own file the index vouches for (`reuse_worktree_file`); an exit other than 0 (or 1, trusted) is `error.ExternalDiffFailed`. `checkout.Tracked` is git's `ie_match_stat`, which status now goes through; `fs.TempFile` names files as git does, six letters or digits retried on a collision, and makes git's directory form (`Name.directory`).
- A patch's prefixes as git 2.55's (`diff.Options.prefixes`, `diff.Prefixes`, `--src-prefix`/`--dst-prefix`): `Prefixes.configured` reads `diff.noPrefix`, `diff.srcPrefix`, `diff.dstPrefix` and `diff.mnemonicPrefix`, whose letters follow what is compared (`i/`/`w/`, `c/`/`i/`, `c/`/`w/`, `o/`/`w/`, `1/`/`2/`, `a/`/`b/` for two commits); format-patch takes them and passes `diff.noPrefix` over, as git's does.
- The combined diff of a merge as git 2.55's `combine-diff.c` writes it (`diff.combined`, `git diff-tree -c` and `--cc`): `paths` keeps what the merge changed against every parent, each parent's diff made apart, renames and all, in the first parent's order, the order file last; `write` merges what the parents lost by git's `coalesce_lines`, marks each line by parent, cuts hunks with git's context (a gap shorter than it joined), `--cc` drops a hunk where the result took one side whole, and writes git's `@@@` lines (the comment line before a hunk cut short as git cuts it), the `index` line of every parent's object, the modes, `--combined-all-paths`, binary paths, a gitlink's line, textconv, the whitespace a diff overlooks, colour.
- A commit's diff as `git log -p` and `git show` write it (`patch.commit_diff`, git's `log_tree_diff`): `parts` chooses them, a root commit's under `log.showRoot`, a merge's by `--diff-merges` (`Merges`: off, first parent, separate, combined, dense combined, remerge); `configured` reads `log.diffMerges` for `-m` and `--diff-merges=on`, case and all, an earlier value kept by `on`, a value git dies on refused. The remerge diff merges the parents again in memory (`merge.three_way.inCoreCommits`, git's `merge_incore_recursive`, labelled `%h (%s)`, `merge.conflictStyle` honoured) into a quarantine thrown away after (`odb.quarantine.Quarantine.Purpose.remerge_diff`), and writes it against the merge with each conflict as a `remerge CONFLICT` header (`diff.UnifiedInputs.headers`, `diff.PathHeader`: a path met only there written with its headers alone, every file then in the order of its old path, as git sorts them); an octopus gets git's warning.
- `core.bigFileThreshold` as git 2.55 acts on it, read as git's `git_config_ulong` reads it (512 MiB unset; a value git dies on refused when the repository opens) into `Odb.packOptions().big_file_bytes`: a pack deltifies no object past it, nor keeps one as a base, a delta a pack holds for one still reused (git's `no_try_delta`, the bound now past rather than at); a file past it is binary to a diff unless its driver says (`diff.driver.Drivers.binary`, git's `diff_filespec_is_binary`; patches, patch ids, format-patch, range-diff), but under `--binary`, which reads both sides first, unless a stat asked before (`diff.Options.after_stat`, format-patch's); `git add` stores such a file that nothing would convert (`worktree.convert.Session.wouldConvertToGit`) in a pack of its own for the call, as git's `index_fd` streams it (`AddOutcome.streamed_pack`); an archive takes it as its blob, unconverted unless `export-subst` asks, a zip writing it as git's stream: flagged, deflated larger or not, its checksum and sizes in a data descriptor; a zip64 entry's central record says version 45, as git's.
- Protocol v2's `object-info` under `transfer.advertiseObjectInfo`: each object's size as git's `cap_object_info` answers it, an empty one for an object the repository lacks, a line not asked for or not an object's name refused in git's words and passed over. And `session-id` under `transfer.advertiseSID`: upload-pack and receive-pack name their side in their capabilities, and a fetch (v0 and v2) and a push name theirs to a server that takes one, an id of the time and random bits where git's trace2 names the host and process (`protocol.sessionId`).
- `core.alternateRefsCommand` and `core.alternateRefsPrefixes`, read as git's `odb_for_each_alternate_ref` reads the alternates' refs (`transport.alternate_refs`): the command's object names, run through the shell with the alternate's path (`AlternateRefsCommandNotRun` without `Programs`; a line that is no object's name stops it with git's warning, `warning.Warning.alternate_refs_line`), or the refs under the prefixes. receive-pack shows them as `.have`, and a fetch now starts its negotiation from them too, as git's `insert_one_alternate_object` does, so what an alternate already holds is not fetched again.
- `archive.remote`: git's `upload-archive` (`Server.serve`) and `git archive --remote` (`fetch` of a `Request`, over a repository on this machine through that server or over ssh through `git-upload-archive`, `--exec` naming another program). The server reads the client's arguments as git's remote archiver reads them -- the options a local archive alone takes refused in git's words, a bad one answered with git's usage text, a tree-ish that does not start at a ref refused unless `uploadarchive.allowUnreachable` -- and sends the archive on side-band channel one, the archiver's words on two and git's "archiver died with error" on three; `Served.refused` tells a server program to end as git's does. Held to git 2.55's client and server, both ways, over the local transport and ssh.
- git's tar filters in `archive`: `Format.filtered` names `tgz`, `tar.gz` (gzip made in process, as git 2.38's internal gzip makes it) or any `tar.<name>.command`, run through the shell with `-<level>`, its own words to `Options.filter_messages` (channel two from `upload-archive`); `archive.formats` lists them in git's order with `tar.<name>.remote`, which `upload-archive` offers and `--list` prints.
- upload-pack's `uploadpack.packObjectsHook`, read only where the repository cannot write it (`config.Config.findProtected`, git's `git_protected_config`): the pack is made by the hook, run through the shell in the git directory with git's `git pack-objects` command line after it -- `--thin`, `--shallow` with the boundary on its input, `--progress`, `--delta-base-offset`, `--include-tag`, `--filter` as the client asked -- and told the wants, `--not` and the haves as git tells it; its progress goes on channel two and its failure ends the pack with git's words on channel three (`PackObjectsFailed`). `upload_pack.Options.programs` runs it, and the in-process `file://` fetch passes the caller's. And `uploadpack.keepAlive`: an empty packet on channel one whenever the client has heard nothing for that many seconds while the pack is made, between whole packets. Held to git 2.55's upload-pack, in v2 and v0, whole, shallow, deepened and filtered.
- receive-pack's `receive.autogc` (on unless set false): after `post-update`, `maintenance.run` with `auto`, when `maintenance.autoMaintenance` says so, as git's `prepare_auto_maintenance` runs `maintenance run --auto --quiet`; where git detaches it, it runs once the client has heard all of the push. Held to git 2.55's receive-pack.

- `core.ignoreStat` (`checkout.Rules.ignore_stat`, `Rules.fillStat`): what an add or a write takes the stat of -- `addAll`, a checkout's and `writePaths`' files, a sparse checkout's restored ones, `apply --index`, rerere's staging -- is marked assume-valid, as git's `fill_stat_cache_info` marks it; a refresh leaves the bit as it was. Held to `git ls-files -v` after `add` and `checkout-index -u`.
- `extensions.submodulePathConfig` (git 2.55): a submodule's repository is where `submodule.<name>.gitdir` says, from the top of the working tree, for every use -- deinit, absorb, update, and the nested reconnection after a move -- checked as git's `validate_submodule_encoded_git_dir` checks it (`error.NoSubmoduleGitDir` where none is set); `submodule.init` sets git's default (`modules/<name>`, else percent-encoded, then with capitals encoded, then with a digit, then the name's blob hash); `submodule.migrateGitDirConfigs` (`submodule--helper migrate-gitdir-configs`); `init.defaultSubmodulePathConfig` turns the extension on in a new repository, at version 1 (`Repository.submodulePathConfig`). A new repository's extensions are written before its version, as git writes them. Held to git 2.55's `submodule init`, `absorbgitdirs`, migration and `init`.
- `core.filesRefLockTimeout` (100 milliseconds unless set; 0 once, below 0 for ever): how long a loose ref's lock is waited for, with git's backoff, in a transaction, the special refs, reflog expiry and pruning after a pack. `core.lockfilePid` for every lock a repository takes -- the index, refs and their logs, `packed-refs`, reftable's list, configuration files, `shallow`, sparse-checkout patterns, `MERGE_RR`, the multi-pack index and commit graph, `maintenance`, `gc.pid` and `gc.log` (`Repository.lockfilePid`, `Repository.configLock`, `Odb.configureLockPid`). Held to git 2.55: a lock relic holds is named in git's own refusal.
- git for Windows' `core.hideDotFiles` (`fs.HideDotFiles`, `Settings.hide_dot_files`, `checkout.Rules.hide_dot_files`): `.git` -- the directory `Repository.create` makes, a submodule's and a worktree's `.git` file -- hidden under `dotGitOnly`, the default, and every file and directory a checkout makes whose name starts with a dot under `true`, as `mingw_mkdir` and `mingw_open` hide them; a hidden `.git` file shown before it is written again. `core.unsetenvvars` (`PERL5LIB` unless set): `program.Programs.unset`, taken out of every program's environment, filled by `Repository.programsWith`. Both read on Windows alone, as git reads them.
- `core.preferSymlinkRefs` (`refs.Store.Options.prefer_symlink_refs`, `configureSymlinkRefs`): a symbolic ref the files format writes is a symbolic link to its target's name, its lock given up, the text where no link can be made, as git's `create_ref_symlink`; never on Windows. A loose ref that is a symbolic link naming a ref is read as that symbolic ref, as git's `files_read_raw_ref` reads one, whatever the setting. `core.createObject` (`odb.CreateObject`, `Odb.configureCreateObject`): a new loose object is linked into place, git's default, renamed where no link can be made, or renamed; an object already there is kept and compared, as git's `finalize_object_file` and `check_collision` keep it: `error.LooseObjectDiffers` where the bytes differ, where relic renamed over it. A value git does not know is refused. Held to git 2.55.
- An event's hooks run at once as git 2.55's `run_hooks_opt` runs them: `hook.jobs` (one unless set; `-1` for every processor), `hook.<event>.jobs` over it, `Runner.Request.jobs` over both, and one at a time while a configured hook is not `hook.<name>.parallel = true` (`Configured.parallel`, `Runner.jobs`, `Runner.event_jobs`, `hooks.EventJobs`); at once, each hook's standard output joins its standard error and the whole is given out, captured or written, in the order the hooks started, the first failure in that order the one reported. Held to `git hook run`'s output and timing.
- `commit.branch.guessRemote` (git's `unique_tracking_name`): the remote-tracking ref a branch no local ref has is checked out from -- the one remote whose fetch refspecs map it to a ref that is there, or of several the one `checkout.defaultRemote` names -- and how many remotes had one; `commit.branch.guessing` reads `checkout.guess` (on unless set) and `worktree.guessRemote` (off unless set). Held to `git checkout <name>`.
- `fast.importer`: a pack of no more objects than `fastimport.unpackLimit` (else `transfer.unpackLimit`, else 100) is written as loose objects and dropped, as git's `end_packfile` unpacks a small one, at the end and at each `checkpoint`. Held to `git count-objects -v` after `git fast-import`.
- `program.runInto`: a program run with its standard output and standard error written into the caller's writers, over conduit's `Child.exchangeInto`; a credential helper's and askpass's answers go straight into `SecretBytes`.

### Changed

- For development: preflight 0.18.0, through 0.16.0: releasing is bay's (`ci/workflow.json` drops `land` and `release`, the caller its `land` job), and the caller is generated by `bay generate`. relic is held to aegis's danger rules (glint 0.7.0's A007 to A021) type first: an escape is `// aegis: <reason>: <why>` for one of the five reasons only. shakedown 0.4.18 for the tests. The ThreadSanitizer job records its durations (`-Dci-timings=true`) for the next shard balance, and the riscv64 machine's git is `git@edge=2.56.0-r0`.
- aegis 0.1.18 (from 0.1.17), for `own.OwnedIo`, `own.Lent`, `own.readFile` and `SecretBytes.Writer`.
- `maintenance run --auto` runs the geometric-repack task for loose objects as git 2.56 does, past `gc --auto`'s threshold (`maintenance.geometric-repack.auto`, 6700 unless set), where it ran past 100; and the rerere-gc task only when the stale records `rerere gc` would prune, estimated from those named `17...` at 256 each, come to `maintenance.rerere-gc.auto` (512 unless set), where any record ran it (`merge.rerere.gcNeeded`).
- A signature from gpg or ssh-keygen has a CR taken out only where it ends a line, as git 2.56 takes it out, where every CR was.
- A configuration file's lock is waited for as `core.configLockTimeout` says (git 2.56; a second by default, 0 not at all, a negative value for ever), where a held `config.lock` was refused at once: `config.write.LockOptions.on_contention`, set by `Repository.configLock`.
- The release tier runs a test of a blob past 4 GiB (design §10), in a job of its own (`-Dlarge-objects=true`, ReleaseSafe, Linux): the blob is made as it is read, never held; relic adds and commits it and pushes it to git's receive-pack, and git checks it, clones it, checks it out and archives it as relic does; git adds and commits it, the same commit as relic's, and relic clones it from git's upload-pack, checks it out, checks it and archives it as git does. The archives are held alike byte for byte as both are written, and the test process's peak resident memory below an eighth of the blob.
- The release tier's Linux ARM suite runs in two shards per mode (`shards.linux_arm`): Debug on the ARM runner took past the job's 45 minutes, its every-crash cases about a quarter of it, twice what the x86_64 runner takes for the same work.
- The release tier's Windows ARM suite runs in five shards per mode (`shards.windows_arm`), as Windows x86_64's does: in one job it ran past 45 minutes with a third of the suite to go. The ThreadSanitizer run is eight jobs where it was four, three of which ran out of their 30 minutes. `ci/durations.json` and `ci/costs.json` hold what the nightlies measured, so shards split by recorded time instead of by count, and the cross compile is dealt out by each target's measured cost (six jobs in the release tier, where four that assumed 90 s a target ran out of their 20 minutes).
- The tests' git is asked for its release once, before they run, where they run (`relic-held-git`, on the riscv64 machine under `-Dci-vm`): a git other than the release the comparisons are held to stops the build there, naming both. Asked in each test process, it ended the process at its first git and Zig started another for the next test, about 1500 times: the riscv64 job, whose Alpine machine has git 2.54.0, ran out of its 45 minutes every night instead of failing.
- The tests' ThreadSanitizer build is preflight's (`-Dci-tsan=true`, `Config.hardened`), where relic had an option of its own (`-Dthread-sanitizer`, gone): one way to build them so, whose bound preflight scales for the detector's slowdown, on Linux and now macOS. preflight 0.15.1, which also scales the bound for a test module built with `sanitize_thread` however it was asked for. The nightly ThreadSanitizer job held the crash tests to the unscaled 120 s.
- The public surface's contract is checked as relic compiles, on every target, beside the module tables: a namespace that is another's, offers test access or names no `Error`; a type a caller `deinit`s with no `Error`; a facade not publishing a declaration of its implementation, or one of another type; a public function taking more than five positional inputs, anywhere in the surface; a program's `Term` not conduit's or its working directory not `repo.program.Cwd`. Each is a compile error naming it, where the surface tests found them only when run. `testing.surface` and `testing.public_calls` are gone into it.
- relic's tests are held to git 2.56.0, declared once (`src/testing/git_release.zig`): CI's setup builds and checks that release on every runner, and a test run whose git is another release stops at its first git naming both, where the comparisons whose behaviour moved failed one by one. The jobs that run the oldest supported git or git's development branch on purpose are exempt.
- `rev_walk.follow` follows a file as git 2.56's `git log --follow` does: each commit hands its parents the path they follow, a merge each parent the path its own diff leads to, so two lines of history that renamed the file differently are each followed down their own name. Where no child handed a commit a path, the one followed last stays, as before.
- relic follows git 2.56: protocol v2's `object-info` is advertised as `object-info=size type` and answers `type` beside `size` (each value in the order the attributes were asked, an object the repository lacks a space alone, as git 2.56's `cap_object_info`); `uploadpack.packObjectsHook` is handed `pack-objects` in git 2.56's order (`odb_source_files_generate_pack`: `--revs --stdout --thin --shallow --delta-base-offset --include-tag --missing=allow-promisor`, then `--quiet` or `--progress`, then `--filter=`). A `bundle.*` setting with no value or an empty one is left out of `bundle-uri`'s answer, with git's "config '<key>' has no value" to the new `upload_pack.Options.warnings`. A request naming `promisor-remote` with no value ends the conversation (`error.ProtocolError`), as git 2.56 dies on it. The side band keeps a colour sequence with colon subfields (`\e[38:5:196m`) as it keeps one with semicolons. `submodule.sync` and `update`'s fetch of a missing commit use the submodule's remote whose url is the `.gitmodules` one (a relative one resolved against the superproject's), compared once the submodule's `url.<base>.insteadOf` has rewritten it, as git 2.56's `get_default_remote_submodule`, else the branch's remote as before; relic looked only at the branch.
- The module tables are checked as relic compiles: every namespace it exports, three levels down, has one row in `src/relic.zig`'s table and one in the README's, and neither has a row for anything else, or relic does not build, on any target. The README reaches the module as the `README.md` import; the surface test no longer reads it.
- `odb.Odb` has the empty tree whether or not a file holds it -- `read`, `readInto`, `readHeader` and `exists` answer it, as git's in-memory source does -- and `write` still writes it when asked. The sequencer and `am` no longer write it to read it.
- A pass over the loose objects (`prune`, `prune-packed`, `repack`, `gc`) lists the objects directory once and opens only the fan-outs there, where it tried all 256; the order is git's, `00` to `ff`.
- A hook's output, when the caller captures it (`hooks.Output.capture`, receive-pack's), is its standard output and standard error as one stream in the order the hook wrote them, as git relays it, where it was all of the one and then all of the other: conduit's `2>&1` (`program.Invocation.stderr = .to_stdout`).
- receive-pack sends the hooks' output and its own messages on the side band as they are written, as git's does, where they waited in its buffer for the end of the push.
- A non-atomic push's refs go in two transactions allowing failure, the deletions and then the rest, as git 2.55's receive-pack batches them: `reference-transaction` runs once per batch, a ref whose old value moved or whose name conflicts is refused alone (`incorrect old value provided`, `refname conflict`, ...) with git's message on the side band, and a failure of a batch's own refuses every command (`failed to update refs`).
- A transaction's name checks follow git's: in a reftable repository, a ref created where another edit of the same transaction deletes one in its way is refused (`cannot process ... at the same time`), as git refuses it.
- The rest of aegis W1: every password and key relic reads is held in aegis's `SecretBytes`, wiped when let go, and no copy of it is freed unwiped on the way. A password in a URL is decoded straight into its owner; `http.proxy`'s user and password are parsed in wiped scratch (uplink's `Proxy.parseKept`) and kept in one; `~/.netrc` is read into one (`fs.engine.readSecretFile`) and `lfs.netrc.Netrc` keeps its entries' strings in another; LFS's `Authorization` headers, the passphrases that opened client keys and the client certificate and key files themselves are read and held the same way.
- uplink 0.9.2 (from 0.8.6), for `Proxy.parseKept`, `Diagnostics.tls_verification`, HTTP/2 by upgrade and a cookie file's `Set-Cookie:` lines.
- conduit 0.10.5 (from 0.9.3), for `hostName` and `Child.exchangeInto`.
- reactor 0.8.5 (0.8.3 the Lanes deadlock and io_uring's file table, 0.8.4 and 0.8.5 socket options through the Io's own connect), a direct dependency now, with conduit 0.10.4 and uplink 0.9.3 on it: the credential cache and fsmonitor connect to their daemons' Unix sockets through its `net.connectUnix`, which connects through Winsock on Windows as git for Windows does and names a refused connect and a missing socket there as on POSIX (Winsock's ENETDOWN for a missing directory is `FileNotFound`, so the cache passes no daemon over without a Windows case of its own), where std's Windows connect took either for `Unexpected` and a cache with no daemon was an error rather than nothing cached.

### Fixed

- A credential-cache store with no daemon and no starter starts git's `credential-cache--daemon` with git's exec path ahead of `PATH`, as git's `spawn_daemon` does (`setup_path`, `git_cmd`), where it ran the `git` on the caller's `PATH`: on Windows that is Git for Windows' wrapper, which waits on the git it starts and so held the daemon's output open, and the store failed with nothing cached.
- A tracked file past `core.bigFileThreshold` that nothing converts is named as it is read where git's `index_fd` streams it, never held: status's and a diff's comparison of a file whose stat no longer vouches for it (`worktree.Tracked`), `worktree.differsFromIndex` (reset, mv, apply, submodules), sparse checkout's racy check before it removes a file, and stash, which writes such a file into a pack as it reads it, as `git add` does (design §10). Each read the file whole, failing past 2 GiB, and `differsFromIndex` took the failure for a change. One decision for all of them and add: `worktree.streamsIn`, by `worktree.Rules.big_file_bytes`, which `Repository.worktreeRules` fills from the object database's settings; `worktree.hashFile` and `worktree.writeFileInto` read the file in pieces, its length the opened file's.
- A fixup or squash that fails and is skipped finishes its chain as git 2.56's sequencer does (`commit_staged_changes`): the stop is one to amend (`error_failed_squash`), the skipped one leaves `current-fixups`, and where it was the chain's last and others came before it `HEAD` is committed again with the chain's message cleaned, in the editor where the chain had a `squash` or a `fixup -c`; where a fixup follows, the squash message starts again from `HEAD`'s. `current-fixups` records a `fixup -c` as git 2.56 writes it.
- `pretty.refs.listTags` answers `--contains` and `--no-contains` by git's memoized walk (`contains_tag_algo`, `Filter.tag_walk`), as `git tag` does, so an ancestry a replacement makes loop is `error.CommitAncestryCycle` where git 2.56 dies ("commit ancestry contains a cycle"); branches and `for-each-ref` keep the descendant walk, which git also takes while replacements are in use.
- Objects are read through the replace refs, as git reads them (`lookup_replace_object`), where relic read every object as stored: `odb.Odb`'s reads (`read`, `readInto`, `stream`, `readOrStream`, `readHeader`, `placement`) take an object's replacement, followed four deep and `error.ReplaceDepthTooHigh` at git's fifth, from the refs under `OpenOptions.replace_ref_base` (`GIT_REPLACE_REF_BASE`, `refs/replace/`), unless `OpenOptions.replace_objects` (`GIT_NO_REPLACE_OBJECTS`) or `core.useReplaceRefs` turn them off. What git runs with them off reads as stored (`Odb.pauseReplacements`): pack writing and reachability, index-pack, upload-pack, a push's and a bundle's objects, the local transport's copy, repack, prune, and the commit-graph, multi-pack-index and bitmap writes; the commit-graph is not read while replacements are in use, and gc and fetch write none then, as git's `commit_graph_compatible` refuses. A log's `replaced` decoration follows the same base and switch.
- On Windows, a program run directly that is a script starts through the interpreter its `#!` line names, as git for Windows' `mingw_spawnvpe` starts one, for every program relic runs (`process.program.start`) where it did so for hooks alone: `uploadpack.packObjectsHook`, a helper or a filter named by its path no longer fails with `InvalidExe`.
- On Windows a real path is `/`-separated, as Git for Windows' `strbuf_realpath` gives it (`fs.realPath`, `fs.realPathAlloc`, where the submodule, worktree, `gitdir:` and `safe.directory` code each kept a copy): `clone --reference` and a submodule's lenders write `objects/info/alternates` as git does, where relic wrote backslashes git quotes.
- On Windows, the rest of the real paths git takes through `strbuf_realpath` are `/`-separated through `fs.realPath` too: the quarantine's `GIT_OBJECT_DIRECTORY`, `GIT_QUARANTINE_PATH` and alternates given to receive-pack's hooks, the hooks' directory and a relative `core.hooksPath`, a commit hook's git directory, the main worktree's path where a branch is checked out or bisected (`checkedOutBranches`, `bisectingBranch`, `%(worktreepath)`), `refs verify`'s symbolic-link referent, and the paths `safe.directory`, `safe.bareRepository` and `maintenance.repo` compare, each of which kept its own copy or wrote backslashes git does not.
- On Windows, a fetch or clone from a repository that borrows objects offers the lender's refs as haves, as git's `refs_from_alternate_cb` finds the lender through `strbuf_realpath`'s `/`-separated path: `transport.alternate_refs` took the lender's path with backslashes, never found it ending in `/objects`, and offered nothing, so `clone --reference` was sent every object (31 where git is sent 11). A remote helper's `GIT_DIR` is `/`-separated too, as git hands it.
- On Windows, `file://<host>…` is a UNC path once a separator follows the host anywhere, brackets or none, as git for Windows' `parse_connect_url` reads it; relic looked for the path after a bracketed host and refused the address.
- The credential-cache daemon waits for a client and for its time on two concurrent tasks; its wait was an `async` call, which Zig's threaded `Io` runs inline once its async threads (one fewer than the CPUs) are taken, so on a busy machine the daemon slept through its whole timeout before it accepted anyone (CI's macOS and Windows runners hit the 120 s watchdog). On Windows, a connect refused for want of a network (`ENETDOWN`) is no daemon there, as git for Windows' `connection_fatally_broken` reads it.
- The merge refuses a tree that names one path twice (`error.DuplicateTreeEntry`), as git 2.56's merge-ort does ("tree has duplicate entries"), where the second entry silently replaced the first.
- A commit a rebase drops as empty is no longer recorded as rewritten, so `notes.rewriteRef` copies none of its notes to an unrelated commit, as git 2.56's sequencer (`PICK_RESULT_DROPPED`); a final fixup dropped so still ends its chain, and an `edit` it drops stops with nothing to amend.
- On Windows, a repository opened when allocation failed partway through `core.unsetEnvVars` leaked the name it had just copied; each name now belongs to the list once it is copied.
- Pins airlock 0.5.3 and conduit 0.10.3, whose descriptors open and close through the C library: a descriptor airlock closed past ThreadSanitizer and another thread then got under the same number read as a data race "in close" in every ThreadSanitizer report of the 2026-10-22 runs (15); conduit closed a pidfd the same way.
- A working-tree file of 4 GiB or more is read and stored by its length in full, as git's `st_size`: `fs.Entry.size` (`u64`) beside `stat`, whose `size` is the index's, modulo 2^32. `git add` decided by the index's size, so a file of 4 GiB and a few bytes looked like a few bytes, was read whole where git streams it past `core.bigFileThreshold`, and failed; stash, sparse checkout's and status's comparisons and LFS's pointer check sized their reads the same way.
- Objects past `core.bigFileThreshold` are held by nothing that writes, receives or checks them (design §10): a pack written for a fetch, a clone, a push or a repack copies the entry its pack stores in blocks, or deflates the object as `Odb.stream` reads it, where it read each object whole and failed past 2 GiB, and the ordering pass no longer caches such a body; index-pack compares one the database already holds as both are read; `Odb.loosen` and `Odb.own`, and so a received pack unpacked below `receive.unpackLimit`, write one loose from the stream; `Odb.verify` names each such loose object and pack entry as it reads it, the concurrent pack check taking an entry stored past it alone. A streamed loose object is finalized as every other (`core.createObject`, the file time `loosen` gives).
- On Windows: `~/` in a path setting expands to `HOME` with its backslashes turned to `/`, as Git for Windows' `interpolate_path` turns them; a bundle list read from a path with backslashes resolves its relative bundle URIs against its directory, as `find_last_dir_sep` finds it, where relic resolved them against nothing. A repository opened while allocation fails no longer leaks a `core.unsetenvvars` name; the pack directory's listings in `odb` and `refs migrate`'s reserve before they copy a name, so a failed append leaks nothing.
- `promisor-remote` goes only with `ls-refs` and `bundle-uri`, as git's `send_capabilities` sends it; relic sent it with `fetch` too, where git's `write_command_and_capabilities` has none, so a stateless server took remotes on a fetch that git's client never names there.
- `@{push}` is git's `branch_get_push`: a remote's push refspecs name the destination, a mirror the branch itself, `simple` refuses a push remote other than the upstream's ("cannot resolve 'simple' push to a single destination"), an unknown `push.default` is refused, and the remote falls back to `origin`; relic took the branch's own name under `simple` to another remote and read no push refspecs. The upstream's tracking ref honours negative refspecs (`transport.refspec.map`, git's `apply_refspecs`, which `Remote.trackingRef` now is).
- A loose object's time is set through `fs.setTimestamps`, which Windows has, where Zig 0.17's `Dir.setTimestamps` panics there: a loose object written with a time of its own (an unpacked cruft object's) no longer stops the process on Windows, nor do the repack, prune and gc tests that age files.
- Bytes `Odb.read` returns are freed with the object database's allocator everywhere: the merge-base walk, `rev_walk.Walk`, `.gitmodules` loading, checkout, stash, snapshots, fast-import (whose pending objects now come in that allocator too) and fast-export freed them with the caller's, which leaked or worse where the two differed.
- A pack written from packed objects keeps every delta its pack holds whose base is written too, as git 2.55's `write_one` keeps it by writing the base first: a delta the order put ahead of its base moves to just after it, before the search groups are cut, and only one of a loop of such deltas is written as the search makes it. Before, one ahead of its base was searched again, and under `core.bigFileThreshold` written whole.
- A file whose conversion streams is written through git's stream filters whatever its length, as git's `write_entry` writes every such file: the streaming `ident` expands a `$Id` as it reads, so `$$Id$` keeps its `$Id$`, which relic's in-core `ident` expanded.
- `reset --hard` writes back a tracked file the working tree lost, as git's `oneway_merge` updates an entry whose `lstat` fails; relic left it missing when the index and the target agreed.
- index-pack names a blob past `core.bigFileThreshold` as it inflates it, holding none of it, as git's `unpack_entry_data` does; it held any blob up to 16 MiB whole whatever the threshold. A pack of objects of any size is received in memory bounded by the threshold.
- `diff.combined` writes a `-U0` hunk's wrapped counts as git's `unsigned long` holds them on the platform: 32 bits on Windows, where git writes `+1,4294967295`.
- On Windows an address is local only where git for Windows' `url_is_local_not_ssh` takes it so: a drive is any character before a colon (`win32_has_dos_drive_prefix`), and the path after it must be one Windows opens as itself (`is_valid_win32_path`), so `h:22:r` is an ssh address; `file://` with a drive in the same sense is a path with its drive.
- `diff.numstat` decides binary as git's `--numstat` does (`diff_filespec_is_binary`): a driver's `binary`, a `-diff` and `core.bigFileThreshold` make a file binary or text, where a NUL alone did. A `textconv` changes nothing, as in git, which counts a stat in the bytes.
- Remotes fetched at once by `transport.fetch.fetchMany` shared the caller's warning list and credential report across tasks, which neither locks; each fetch now keeps its own and hands them over when all are done, and runs without the progress and prompt callbacks, which answer on the caller's task.
- A clone of an empty remote sets its unborn branch to track the remote's (`branch.<name>.remote` and `.merge`), as git's `update_head` does; relic left it untracked.
- An empty `remote.<name>.url` or `pushurl` clears the values before it, as git's `add_url` and `add_pushurl` do; relic kept them all.
- `commit.reset.toTree` no longer deletes a populated submodule's checkout when its gitlink changes: it stays, as git leaves it without `--recurse-submodules`.
- `index.Index.remove` reads `path` before it frees an entry, so an entry's own path may be passed.
- `repack --geometric` no longer reads freed memory when it rolls loose objects into the new pack: each entry keeps its own copy of the path its delta search sorts by (an intermittent crash in the promisor-pack case).
- A push's pack loses its `.keep` once the refs hold its objects, as git's receive-pack removes it, not at the end of the push: a collection run by a hook or the auto maintenance after it packs it with the rest.
- A push to a repository on this machine, and a fetch from one, no longer hold the pack whole: the receive-pack or upload-pack in this process (`transport.in_process`, one for both) serves each request on a task beside the client, the request and the answer crossing through bounded pipes, so a pack goes over as it is written. A server that stops reading has the rest of the request taken, so the client reads its answer; a client canceled cancels the server's task. Where the caller's `Io` runs no second task, a request is held whole and answered after it, as before.
- A ref list a server advertises, receive-pack's and upload-pack's, and a local fetch's, leaves out a symbolic ref that goes round in a circle, as git leaves a broken ref out, where it ended the conversation with `SymbolicRefLoop`.
- An object database finds a `pack` directory made after it was opened, on its next scan or on a read that misses, as git reads `objects/pack` again; it found no pack there before.
- A split commit graph written over a single `info/commit-graph` no longer fails on the layer file that file never was.
- An unset that takes a section's last setting takes the section with it, as git's `maybe_remove_section` does, unless a comment is in it or just before it; relic left the empty header.
- The multi-pack index and `objects/info/packs` cover every pack whatever its name, as git's do; relic took only `pack-*`, and so left out the `loose-*` packs git's maintenance writes.
- A fast-forward merge keeps what is staged beside it, where it refused a staged change as `DirtyIndex`; a staged change the fast-forward would overwrite is still refused. The same holds for a rebase's checkouts, a cherry-pick's fast-forward and bisect's checkouts, all git's two-way merge.
- `transport.remote.Branch.fetchRemote` and `pushRemote` fall back to the only remote when there is one, before `origin`, as git does.
- Two tasks of one LFS operation no longer allocate from its arena at once: an API request's URL, and a custom adapter's failure, were made in it without its lock.
- A push sends its commands in git's order, the remote's refs as it listed them and then those it lacks as they were matched, where it sent them in refspec order; the server's hooks see them in that order. The outcome's refs keep the refspecs' order.
- `stash.apply`, `pop` and `applyEntry` write `AUTO_MERGE` and drop the index's resolve-undo record, as git's stash apply leaves them (merge-ort's `merge_switch_to_result`).
- receive-pack stages the deletion of a ref that is not there, as git does, so the ref transaction and its hook see it.
- receive-pack says git's explanations when `receive.denyCurrentBranch` or `receive.denyDeleteCurrent` is unset (the latter's before its refusal, as git orders them), and an object `receive.fsckObjects` refuses as git's unpacker says it (`object <oid>: <msg-id>: <text>`, `fsck error in packed object`).
- receive-pack says git's explanations when `receive.denyCurrentBranch` or `receive.denyDeleteCurrent` is unset, and an object `receive.fsckObjects` refuses as git's unpacker says it (`object <oid>: <msg-id>: <text>`, `fsck error in packed object`).
- `Odb.repack` took a replaced pack's `.pack` away before its `.idx`, so a reader could find an index whose pack was gone; it now removes in git's order, through `Odb.removePacks`' path, and reports a removal that fails.

## [0.29.1] - 2026-10-21

### Added

- `lfs.server.S3`: the LFS server's objects in S3-compatible object storage, at `<prefix><repository>/<aa>/<bb>/<oid>` in a bucket (path-style or virtual-host addressing). Its actions are URLs the storage signed (uplink's `wire.sigv4`, AWS Signature Version 4) for `expires` seconds, which git-lfs follows straight to the storage; whether it holds an object is a signed `HEAD` through the caller's uplink client. Held to git-lfs's push, re-push and clone against storage that takes only a signature it recomputes for the exact URL sent.

### Changed

- uplink 0.8.6 (from 0.8.4), for `wire.sigv4`, and the cloak 0.19.0 it takes (from 0.14.0).

## [0.29.0] - 2026-10-21

### Breaking

- `refs.Store.logNames` takes `LogNamesOptions`; `every_worktree` adds each other linked worktree's own logs as `worktrees/<id>/<name>` and, from a linked worktree, the main worktree's as `main-worktree/<name>`, in both formats.
- `maintenance.expireReflogs` with `refs` of `null` is git's `--all`: every worktree's logs, each other worktree's own expired through a store opened in it (`refs.Store.sibling`); `single_worktree` is `--single-worktree`, what `null` was.

### Added

- `maintenance.prune`: git's `prune` (`--expire`, `<head>...`, `-n`). Reachability as git's `mark_reachable_objects` (`maintenance.reachableObjects`): every worktree's index with its cache-tree and resolve-undo, every ref, every worktree's `HEAD`, every rebase's `autostash` and `orig-head`, every worktree's reflog entries, then the recent objects (`Odb.recentObjects`: loose by file time, packed by the pack's) and what they reach. `Odb.prune` removes, in git's order, the unkept loose objects no newer than the expiry with stale `tmp_obj_*` files and empty fan-out directories, then the loose objects a pack holds (`prune-packed`), then stale `tmp_*` in `objects/` and `objects/pack/`; the shallow boundary loses the commits nothing reaches. `extensions.preciousObjects` refuses it (`PreciousObjects`). `maintenance.pruneExpiry`: `gc.pruneExpire`, `2.weeks.ago` by default, `never` for none. Held to git 2.55 in both ref formats and at every crash point on shakedown's simulated disk.
- `walk.object.walk.MissingOptions.ignore_missing_links`: git's `ignore_missing_links`, what prune walks its recent objects with.
- `refs.Store.sibling`: a store over another worktree of the repository with this one's options, which writes that worktree's own refs and logs.

### Fixed

- `maintenance.expireReflogs`' defaults are git 2.55's `REFLOG_EXPIRE_OPTIONS_INIT`: 30 days for every entry and 90 for unreachable ones, so with neither configured an entry older than 30 days goes whatever reaches it. git's documentation gives 90 and 30; relic kept those.

## [0.28.0] - 2026-10-21

### Breaking

- `transport.credential.Session` holds its secrets (`password`, `credential`, `oauth_refresh_token` and the `Authorization` header it makes) in aegis's `SecretBytes`, which wipes them when let go and refuses to format them; `Session.exposePassword()` hands the password on, explicitly. A prompt's answer is wiped as it is let go, and the `Basic` header's plain `user:password` lives in one such owner while it is encoded. relic depends on aegis 0.1.14 itself.
- `warning.Warning` has `advertised_bundles_failed` and `bundle_uri` (git's words on the way through a bundle URI: a download that failed, a file that is neither a bundle nor a list, a `creationToken` that does not parse, a recursion past four lists, a server's list that does not read).
- `commit.Error` and `rebase.Error` take `notes.Error`, with its new `InvalidRewriteSetting`; `warning.Warning` has `notes`.

### Added

- Protocol v2's `bundle-uri` command, as git 2.55 asks and answers it. A clone under `transfer.bundleURI=true` with no `bundle_uri` asks a server that advertises the command for its list (`transport.Session.bundleUri`, `protocol.bundleUri`), relative URIs taken against the remote's URL, and takes its bundles before the fetch (git's `transport_get_remote_bundle_uri` and `fetch_bundle_list`); a repository read directly answers as its upload-pack would. `upload_pack` advertises and answers it under `uploadpack.advertiseBundleURIs` (`Options.advertise_bundle_uris`), every `bundle.*` setting as a `key=value` line (`upload_pack.bundleSettings`, `advertisesBundleUris`).
- The warnings git prints inside a bundle URI's fetch reach `Warnings`.
- Notes follow rewritten commits as git 2.55's `copy_note_for_rewrite` copies them (`notes.copyForRewrite`): after `commit --amend` and every amend a rebase makes (`notes.rewrite.amend`, `Notes added by 'git commit --amend'`), and at a rebase's end for every commit in `rewritten-list` (`notes.rewrite.rebase`, as git's `notes copy --for-rewrite=rebase`), into each ref `notes.rewriteRef` names (globs matched over every ref, one outside `refs/notes/` warned of and left out), met as `notes.rewriteMode` says. `GIT_NOTES_REWRITE_REF` and `GIT_NOTES_REWRITE_MODE` are not read.
- `lfs.server`: a Git LFS server, as a handler for uplink's server, held to git-lfs 3.8's push, clone, pull and locks. `Backend` finds repositories under a root as `transport.http_backend` does (`http_backend.openServed`, now shared) and answers `<repository>/info/lfs`: the batch API (download and upload, a `verify` action with each upload, an object's own error for one missing or malformed, 409 for another hash algorithm), the basic transfer adapter through the backend, and the locking API (create, list with `path`/`id`/`cursor`/`limit`, verify split into ours and theirs, unlock and forced unlock), every answer in git-lfs's JSON. Requests it does not own go to an `http_backend.Backend` it is given, so one server is the whole remote. The objects go to a `Store` the caller gives: `Directory` lays them out per repository as git-lfs's own store and keeps an upload only when its SHA-256 and length match. `Caller.authorize` decides each request (`download`, `upload`, `force_unlock`) and names the lock's owner, or asks for credentials (401 with its `LFS-Authenticate`) or refuses (403). Locks are kept in `<git dir>/lfs/locks.json` under git's lock file.
- `lfs.transfer.parseBatchRequest` and `writeBatch`, `lfs.locks.parseRequest`, `writeLockAnswer`, `writeListPage`, `writeVerifyPage` and `writeLockList`: the server's side of the API's JSON, on the types the client reads it with, written as git-lfs's Go writes them.

### Fixed

- A `rebase --continue` that amends the stopped commit tells `post-rewrite amend`, as the `git commit --amend` git runs there does.

## [0.27.0] - 2026-10-21

### Breaking

- A push to a repository on this machine goes through relic's receive-pack in process (`transport.receive_pack.connect`), as git runs its own: `local.Remote.receivePush` and its options are gone. The repository's hooks run with the caller's `programs` (`push.Options.programs`); without them a repository with a receive hook is still refused (`error.RemoteHooksNotRun`). Push options reach a local repository whose `receive.advertisePushOptions` takes them, where they were refused.

### Added

- `transport.receive_pack`: the serving side of a push, git's `receive-pack`, held to git 2.55's `git push`: the v0 advertisement (`version 1` first when asked; v2 answered in v0, as git's is) with `.have` lines for the alternates' tips, `report-status` and `report-status-v2` on `side-band-64k`, atomic pushes, push options (`receive.advertiseAtomic`, `receive.advertisePushOptions`), a shallow pusher's boundary under `receive.shallowUpdate`; the pack received into a quarantine, indexed and checked there by `receive.fsckObjects`/`transfer.fsckObjects` and `receive.maxInputSize`, every new tip connected; `pre-receive` (the quarantine as `GIT_OBJECT_DIRECTORY`/`GIT_QUARANTINE_PATH`, `GIT_PUSH_OPTION_*`), `update`, `post-receive` and `post-update`, their output on side-band channel two, run in the git directory; `receive.denyCurrentBranch` (every worktree), `denyDeleteCurrent`, `denyDeletes`, `denyNonFastForwards`, `receive.hideRefs`; refs written one by one, deletions first, or all in one transaction for an atomic push, with git's reasons. `Server.serve` for a pipe, `serveRequest` for HTTP.
- `odb.quarantine`: objects held apart until accepted, git's `tmp_objdir` (`tmp_objdir-incoming-*` under `objects`), migrated with each pack's index last and a `.keep` held until the refs are written, or discarded. `Odb.borrow` reads another objects directory after a database's own, as `GIT_ALTERNATE_OBJECT_DIRECTORIES`.
- `transport.http_backend`: git's `http-backend` as a handler for uplink's server: `info/refs` (with the `# service=` line unless v2), `POST git-upload-pack`/`git-receive-pack`, `Git-Protocol`, gzip request bodies, `git-daemon-export-ok` or `Options.export_all`, `http.uploadpack`, `http.receivepack` (on for an authenticated caller unless set), a push logged as `<user>@http.<address>`; held to git's clone, fetch and push over `http://` in v2 and v0.
- `side_band.Mux` and `side_band.send`: the side-band a server writes, cut as git's `send_sideband` cuts it (995 bytes of data on `side-band`), shared by upload-pack and receive-pack.

## [0.26.1] - 2026-10-21

### Added

- `maintenance.packRefs`: git's `pack-refs` (`--include`, `--exclude`, `--all` as `*`, `--no-prune`, `--auto`) through `refs.Store.pack`. Files: under `packed-refs.lock`, the shared, direct loose refs whose objects exist go into `packed-refs` beside what it held, an annotated tag peeled; each loose file then goes under its own lock when it still holds what was packed, with the directories that leaves empty; `--auto` waits for git's `log2(size / 100) * 5` loose refs, at least 16. Reftable: the worktree's stack compacted whole (geometrically with `--auto`), then cleaned of the tables no list names that are no newer than the stack (`reftable_stack_clean`). Held to git byte for byte in both formats, and on shakedown's simulated disk at every crash point.
- `maintenance.expireReflogs`: git's `reflog expire` (`--all` over this worktree's store, named refs, `--expire`, `--expire-unreachable`, `--rewrite`, `--updateref`), with `gc.reflogExpire`, `gc.reflogExpireUnreachable` and their `gc.<pattern>.*` forms read as git reads them (patterns by wildmatch in the order they first appear, a slot a pattern leaves unset never expiring, `refs/stash` never expiring unless configured, values git dies on refused as `InvalidExpiryDate`), unreachability from the ref's own tip or, for `HEAD`, from every ref's; `maintenance.parseExpiry` (git's `parse_expiry_date`). The defaults are the documented 90 and 30 days: git 2.55's `REFLOG_EXPIRE_OPTIONS_INIT` has the two the other way round. Held to git in both formats and at every crash point.
- `refs.Store.logNames`: the refs with a log, as git's `refs_for_each_reflog` lists them, in both formats. `refs.Peeler.exists` and `Repository.refObjects` (the peeler `beginRefs` hands its transactions, now able to say an object exists).

### Fixed

- A ref deletion holds `packed-refs.lock` to its end whether or not the ref is packed, as git's does, so a `pack-refs` between its read and its removal cannot pack the ref again; it was given up when no deleted ref was packed.
- With `core.fsync` covering references, the name of a new `packed-refs` is made durable before anything follows it, so a crash cannot keep the removal of loose refs a pack made and lose the file that now holds them.
- `refs.Store.expireLog` with `rewrite` asks the keeper about each entry with the old value it will be written with, as git's files backend asks (`expire_reflog_ent`).

## [0.26.0] - 2026-10-21

### Breaking

- `clone.Error` has `BundleUriShallow` (`bundle_uri` with a depth, `shallow_since` or `shallow_exclude`, which git refuses together); `warning.Warning` has `bundle_uri_clone_failed` and `bundle_uri_fetch_failed`.

### Added

- Bundle URIs as git 2.55's `bundle-uri.c` fetches them (`transport.bundle_uri`): `clone.Options.bundle_uri` (`--bundle-uri`) takes a bundle's or a bundle list's objects before the server is asked, its refs under `refs/bundles/` offered as haves; a list in git's config format (`bundle.version`, `mode = all|any`, `heuristic = creationToken`, `bundle.<id>.uri` relative to the list, `creationToken`), lists within lists four deep; under `creationToken` the newest bundles first down to one that unbundles, the greatest token kept in `fetch.bundleCreationToken`, the URI kept in `fetch.bundleURI`; every fetch reads `fetch.bundleURI` first. A failure is warned of and the clone or fetch goes on, as git's. Bundles come from a path, a `file://` URL, or http and https through `transport.download` (`smart_http.download`: one `GET` with git's `http.*` settings and credentials, as git-remote-https's `get`, a redirect followed only under `http.followRedirects=true`).
- `http.sslVersion=tlsv1.3` holds the server to TLS 1.3 (uplink's `tls.ClientOptions.min_version`), as curl holds it for git, where it was refused.
- `http.pinnedPubkey` holds the server's certificate to the keys it names, as curl's `Curl_pin_peer_pubkey` reads them for git: `sha256//<base64>` hashes with `;sha256//` between them, each compared as written, or a file holding the key as DER or a `PUBLIC KEY` PEM block (`wire.pinned_key`, through uplink's `pins`). A value that can match no key fails with `TlsFailed` before connecting; a hash list is no longer made a path from the configuration's directory.

### Changed

- Pins airlock 0.5.1 and shakedown 0.4.15: a stat over the simulated disk carries the device, owner and group it keeps, so the crash tests' index entries hold every field git's index stores.
- `smart_http.Error.PinnedPubkeyUnsupported` is a pin under `http.sslVerify=false` alone, which curl checks with nothing else checked and uplink's TLS cannot yet; `SslVersionUnsupported` is SSL 2 or 3 alone.

## [0.25.0] - 2026-10-20

### Breaking

- `diff.findRenames` takes `diff.RenameBlobs` in place of the database: the database and the blobs not in it (`diff.rename.Options.contents`), the working tree's files under the names their stored bytes hash to, as git's `hash_filespec` names them.
- `worktree.status` reports a file the index holds as an intent to add as git does (`ita_invisible_in_index`): nothing staged (a path in `HEAD` is staged as deleted), the file `added` in the working tree, `deleted` when it is gone. It was staged as added.
- `sequencer.Error` has `diff.BasicConfigError` (`InvalidDiffSetting` and the colour errors), which a cherry-pick, a revert and a rebase now refuse as they begin.

### Added

- `status.renames` in the working tree: `worktree.renames.find` pairs the working tree's deletions with the files the index holds as an intent to add (and with copies its modifications as sources), as git's `wt_status_collect_changes_worktree`, through diff's one rename engine. The status keeps those files' bytes as they would be stored when `StatusOptions.added_content` asks (`StatusEntry.added`: clean filter, encoding, line endings and `ident`, a symlink's target, as git's `diff_populate_filespec`); a working tree's rename or copy is `unstaged = .renamed`/`.copied` with its `source` and `score`.
- `diff.checkBasic`: what git's `git_diff_basic_config` dies on, every value wherever it stands (`diff.renameLimit`, a driver's `diff.<driver>.*`, `diff.color.<slot>`/`color.diff.<slot>`, `diff.wsErrorHighlight`, `diff.suppressBlankEmpty`, a bare `diff.dirstat`, `diff.indentHeuristic`); `sequencer.initConfig` refuses them all, as git's sequencer dies on them before a cherry-pick, a revert (`--abort` and `--quit` too) or a rebase does anything.

## [0.24.1] - 2026-10-20

### Changed

- Pins conduit 0.9.3, uplink 0.8.4, cloak 0.14.0, warp 0.4.1 and xenoglyph 0.4.1; development: preflight 0.10.2, shakedown 0.4.14.

### Fixed

- `Odb.syncBatch` makes the names of loose objects durable under `core.fsyncMethod = fsync` too, as it does under `batch`: each object was synced, but its name is its fan-out directory's, and an index or a ref published after it could survive a crash that lost the object.
- reftable: a new table's name, and the list's, are made durable (the `reftable` directory synced) before the next step when `core.fsync` syncs the references. A crash could keep the `tables.list` naming a table while losing the table's rename beside it, after which every read of the refs failed (`ReftableMissing`); and a compaction removed the old tables before the list without them was durable.
- A renormalizing merge into a working tree without a `.gitattributes` checked the files it would overwrite through the merged `.gitattributes`, which the merge had put among the working tree's attributes: an entry racily clean (written in the second of the index) was then judged changed (`LocalChangesWouldBeOverwritten`) where git, which refreshes the index through the working tree's and the index's attributes before it merges, finds it clean. The merge reads attributes of its own (git's `attr_index`).
- LFS transfers: the run no longer names the event queue of `runJobs`'s frame after it returns (latent: nothing read it after the workers finished; glint's E001).

## [0.24.0] - 2026-10-20

### Breaking

- `smart_http.Error` has `RateLimited`, `SslVersionUnsupported` and `PinnedPubkeyUnsupported`; `warning.Warning` has `http_version_unknown`, `ssl_version_unknown`, `cookie_file_stdin`, `save_cookies_without_file`, `http_env_unparsed` and `rate_limited`.

### Added

- The `http.*` settings of a transfer act as they do for git (read since 0.13.0): `http.cookieFile`'s cookies are sent (uplink's cookie jar), and `http.saveCookies` writes the jar back when the conversation ends, the session's cookies included, as curl writes it for git (`-` and an empty name warned of, as git warns); `http.lowSpeedLimit` and `http.lowSpeedTime` (and `GIT_HTTP_LOW_SPEED_*`) give up on a transfer slower than the limit for the time; a 429 to the advertisement is tried again as git's `http_request_recoverable` tries it: `http.maxRetries` requests in all (none: the 429 is an error), each after the `Retry-After` the server asks, seconds or a date against the caller's `now`, or else `http.retryAfter`, neither longer than `http.maxRetryTime` (`GIT_HTTP_RETRY_AFTER`, `GIT_HTTP_MAX_RETRIES`, `GIT_HTTP_MAX_RETRY_TIME`; a variable that is not a number warned of); `http.version` keeps HTTP/1.1 or lets TLS agree HTTP/2, another value warned of. `http.sslVersion` (and `GIT_SSL_VERSION`): `tlsv1` to `tlsv1.2` are what relic speaks already, `sslv2` and `sslv3` are refused as git fails on them, an unknown name is warned of; `tlsv1.3` alone and `http.pinnedPubkey` are refused by name until uplink can hold a connection to them. Held to git over a local server.
- `diff.RenameSettings.readLimit`: `diff.renameLimit` alone, every value as git's `git_diff_basic_config` reads it; and `sequencer.initConfig`, what git's `sequencer_init_config` dies on. A cherry-pick and a revert (every action, `--abort` and `--quit` too) and a rebase as it begins, continues or skips refuse a bad `diff.renameLimit` wherever it stands (`error.InvalidMergeSetting`), where they checked only the merge's last value; `diff.renames` stays the merge's last value, as git reads it there. Held to git.

## [0.23.0] - 2026-10-20

### Breaking

- `diff.UnifiedInputs.changes` replaces `change`: `diff.unified` writes a whole diff, every change of it, as git's `diff_flush_patch_all_file_pairs` writes its queue.
- `transport.progress.Control` is git 2.55's set (`color`, `cursor`, `erase`, `all`; `.none`, `.everything`, the default colour alone): `sanitize` keeps the cursor movements (`ESC [ … A`-`H`, `f`) and erasures (`J`, `K`, `M`, `P`, `X`) it allows, as git's `handle_ansi_sequence`, and shows a carriage return inside a line as `^M`, the side band splitting the remote's text at line endings first as git's `demultiplex_sideband` does.
- `pretty.Decorations.load` takes a `?*const Decorations.Filter`: `null` loads every ref, as `git archive` does.
- `fs.StatError` is airlock's `StatError`, and `worktree.dir_scan.Scan.initPlain` allocates its buffer (`Allocator.Error`).
- `fsmonitor.Error` has `NotABoolean` (`fsmonitor.allowRemote`, where git dies).

### Added

- `transport.side_band.allowedControl`: `sideband.allowControlCharacters` read from the configuration, the `sideband.<url>` section that matches the remote best deciding, as git's `sideband_apply_url_config`; a word git does not know (on which git warns without end) is `error.InvalidControlSetting`. Held to git's t5409 cases.
- The server's fatal side-band message in colour: under `Progress.remote_keywords`, `Demux.message` paints the keyword it starts with, as git's `demultiplex_sideband` writes channel 3.
- `pretty.Decorations.Filter` (git's `decoration_filter`) and `Filter.log`, the filter `git log` decorates through (`set_default_decoration_filter`): `--decorate-refs`, `--decorate-refs-exclude`, `--clear-decorations`, `log.excludeDecoration` and `log.initialDecorationSet`, and otherwise only the namespaces git decorates by default (`HEAD`, branches, tags, remote-tracking branches, the stash, replaced objects), so `%d` no longer names `refs/other/*`. Held to `git log --format=%d` under each.
- `diff.Options.color_moved` and `color_moved_ws` (`diff.ColorMoved`, `diff.ColorMovedWs`; `diff.configured` reads `diff.colorMoved` and `diff.colorMovedWS`, a value git dies on refused): moved lines in colour, found over every file of the diff `diff.unified` writes, or within the body `diff.unifiedBody` writes, as git's `mark_color_as_moved` finds them (`plain`, `blocks` of twenty alphanumerics, `zebra`'s alternate blocks, `dimmed-zebra`'s uninteresting lines; `ignore-space-change`, `ignore-space-at-eol`, `ignore-all-space` and `allow-indentation-change` with the file's tab width) and painted in the `*Moved*` slots. The painter records the diff and replays it once the moved lines are marked. Held to `git diff --color=always` under every mode, each whitespace mode and the moved slots.

### Changed

- The stat of every path is `airlock.stat` (git's view kept here: on Windows the mode from the attributes, the creation time as ctime, inode 0, a link's size by `readLink`); `ENOENT` and `ENOTDIR` apart for `:(optional)` paths, as git tells them.
- `worktree.dir_scan` reads through `airlock.scan`, the batch arm (`getattrlistbulk`) moved there.
- Pins airlock 0.5.0 and strand 0.13.1.

### Fixed

- `fs.probeTimestampResolution` on a file system that keeps whole seconds: every sample reports zero nanoseconds, which it took to `std.math.gcd(0, 0)`, an assertion in safe builds; it reports a second, as it says. Found by the crash tests on shakedown's simulated disk.
- fsmonitor as git's `check_for_incompatible`: a working tree on another machine's volume has no monitor unless `fsmonitor.allowRemote`, nor one whose volume cannot be asked; on Windows none under `core.virtualFilesystem`; the daemon's socket for a git directory on another machine's volume is `<fsmonitor.socketDir or ~>/.git-fsmonitor-<SHA-1 of the working tree's real path>`, and a socket directory on another machine's volume, or named `msdos` or `ntfs`, has no daemon.

## [0.22.0] - 2026-10-18

### Breaking

- `config.color.readSlots` takes a `SlotRead`: the sections, and what a writer does with a slot it does not have (`UnknownSlot`); a name may set more than one slot; `config.color.Error` has `UnknownColorSlot`.
- `pretty.Error` has `InvalidColor`; `%C` is no longer `error.UnsupportedPlaceholder`.
- `diff.UnifiedError` has the attribute lookup's errors and `InvalidDriverBinary`: `diff.unified` decides which files are binary by `UnifiedInputs.binary` (`diff.BinaryRule`: the `diff` attribute and `diff.<driver>.binary`), as git's `diff_filespec_is_binary` does.

### Added

- `pretty.Context.colors` (`pretty.Colors.configured`, read as `git log` reads `color.decorate.<slot>` and `color.diff.commit`): `%C(...)` with `auto,` and `always,`, the old `%Cred`, `%Cgreen`, `%Cblue` and `%Creset`, and `%C(auto)`, under which `%H`, `%h`, `%d`, `%D` and `%(decorate)` are painted as `git log --format` paints them. A colour that does not parse is `error.InvalidColor` where git dies, and passed over where git writes none. Held to `git log --format` under `--color=always` and `--no-color`.
- `grep.Options.colors` (`grep.Colors.configured`: `color.grep`, `color.ui` and `color.grep.<slot>`, `match` setting both match slots, a slot grep does not have refused as git dies on it): names, numbers, separators, hunk marks, matches and the text around them painted as git's `show_line`. Held to `git grep --color=always` under every slot.
- `patch.range_diff.Options.colors` and `dual_color`: a range-diff in colour as git's, each pair's line in `commit`, `old` and `new` as `output_pair_header` paints it, and the diff of two patches in dual colour (`diff.DiffOfPatches`, git's `dual_color_diffed_diffs`: each line by both its signs, the outer one reversed, in the `*Bold` and `*Dimmed` slots) or, under `--no-dual-color`, as a patch. The diff of two patches is written by the painter, its indent and its `@@` lines without ranges included, in colour or not. Held to `git range-diff --color=always` with and without `--no-dual-color` under the colour and whitespace settings.
- `transport.progress.Progress.remote_keywords` (`transport.side_band.RemoteColors.configured`: `color.remote`, else `color.ui`, and `color.remote.<keyword>` as git's `use_sideband_colors` reads them): `hint`, `warning`, `success` and `error` at the start of each line of a remote's text in their colours, as git's `maybe_colorize_sideband` writes them. Held to `git push` over HTTP against a `pre-receive` hook's messages.
- `pretty.refs.Context.color`: `%(color:...)` writes its colour, parsed by `config.color` (the listing's own colour check gone), and a line whose last colour is not `reset` ends in one, as git's `need_color_reset_at_eol`; `pretty.refs.BranchColors` (`color.branch.<slot>`, `color.branch` and `color.ui`) paints `git branch`'s own format and decides `%(color:...)` in `listBranches`. Held to `git for-each-ref`, `git branch` and `git tag` under `--color=always`, `color.ui` (which for-each-ref does not read) and every branch slot.

### Changed

- One writer for a file's patch: `patch.format` writes each file through `diff.unified`, its own header writer gone. `diff.unified` gains what only format-patch had, each held to `git diff` and `git format-patch`: `Options.binary_patches` (`--binary`, a `GIT binary patch` with its objects named in full), `Options.full_index`, `Options.relative_to` (`--relative`), and the `index` line's names lengthened past `Options.abbrev` until unique, as git's `diff_abbrev_oid` writes them. The binary patch codec moves from `patch` to `diff`.

### Fixed

- `diff.unified` writes a change between a file and a symbolic link or a gitlink as a deletion and a creation, as git's `run_diff` splits it; it wrote one pair with `old mode`/`new mode`.

## [0.21.0] - 2026-10-18

### Breaking

- `diff.ConfigError` has `ConflictingWhitespaceRules`: `diff.configured` reads `core.whitespace` (and refuses `tab-in-indent` with `indent-with-non-tab`, where git dies), `diff.wsErrorHighlight` and `core.quotePath`.

### Added

- Colour, one layer for every writer that colours, as git's `color.c` (`config.color`): a value read into the sequence `color_parse` writes, `color.ui` beneath a writer's `color.<writer>` and the caller's `--color=<when>` (`Output`, whose `terminal` is what `auto` means, since relic does not see where its text goes), and a writer's `color.<writer>.<slot>` slots, each value refused where git dies.
- `diff.Options.colors` (`diff.Colors.configured`, `color.diff.<slot>` and `diff.color.<slot>`): `diff.unified` and `diff.unifiedBody` write a patch in colour as `git diff --color` does, line by line through parallax 0.2.6's `Paint`, whitespace errors marked as git's `ws_check_emit` marks them (`Options.whitespace_rule`, `Options.ws_error_highlight`, `diff.WhitespaceRule` for the `whitespace` attribute, which `patch.apply` now reads through too) and blank lines added at the end of a file painted whole. Held to `git diff --color=always` under colour, `core.whitespace` and `diff.wsErrorHighlight` settings.

### Changed

- Pins parallax 0.2.6.

### Fixed

- `diff.unified` writes git's headers: a name C-quoted as `quote_two_c_style` quotes it (`Options.quote_path`, `core.quotePath`), a tab after a `---`/`+++` name with a space in it, `old mode`/`new mode` before a rename's `similarity index`, and no `---`/`+++` lines for a patch with no hunks.

## [0.20.0] - 2026-10-18

### Breaking

- `core.precomposeUnicode` is acted on as git acts on it on macOS: a name the disk spells decomposed is read composed, as git's `readdir` composes it through iconv's `UTF-8-MAC` (`worktree.encoding.precompose`: each character with the one before it, no reordering and no singletons, Unicode's compositions before 5.0, and a name holding anything outside the Basic Multilingual Plane or not UTF-8 kept as it is, where macOS's iconv refuses it). Every name read from the working tree (status, add, checkout's scans, clean, stash's untracked files), the loose refs (listing and `refs verify`) and the worktree ids comes through `repo.fs.Names` or `worktree.dir_scan` (`Scan.init` and `initPlain` take `Options.precompose`). `repo.Settings.precompose_unicode` reads the setting everywhere, a bad value refused as git refuses it, and is true on macOS only; `worktree.Rules.precompose_unicode` and `refs.Store.Options.precompose_unicode` (`Store.configureNames`) carry it. Callers composing their own paths, git's argv step, use `precompose`. Held to `git ls-files -o`, `git add -A`, `git clean -n -d` and `git for-each-ref` over decomposed names, and `precompose` to macOS's iconv over every code point and every pair of the plane.

### Changed

- Depends on xenoglyph 0.3.2 for Unicode's canonical compositions.

## [0.19.0] - 2026-10-18

### Breaking

- Commits are read and written in their encodings as git's are, through one conversion (`text.encoding.reencode`, git's `reencode_string_len`, with `same` and `Charset`: UTF-8, US-ASCII and ISO-8859-1; another name is `UnsupportedEncoding`, where git converts through iconv). `pretty.reencodeCommit` is git's `logmsg_reencode`, `commit.message.logOutputEncoding` and `commitEncoding` read `i18n.logOutputEncoding` and `i18n.commitEncoding` (a bare name refused, `InvalidEncodingSetting`). `pretty.formatCommit` expands placeholders on the commit in UTF-8 and writes `Context.output_encoding`, `null` being the commit's own encoding as `git archive` and a merge message's list write it (`outputEncoding`, `toOutput`); `%e` names the commit's encoding. The shortlog (`configured` sets the log's encoding; `addCommit`, `FormatGroupNeedsName` and `EncodingUnsupported` are gone, a commit is added by name), format-patch (the mails' `charset` and RFC 2047 words name the log's encoding; the people convert too; `patch.format.logMessage` and `logText`, its Latin-1-only path, are gone), range-diff, stash's subject and the sequencer's instruction sheets write the log's encoding; a pick, a revert and a rebase take messages and authors in the commit encoding, as git's `get_message` does. `patch.mail.InfoOptions.charset` replaces `utf8`: am takes mail into `i18n.commitEncoding`. Held to `git log --format`, `git shortlog`, `git format-patch --cover-letter` and `git cherry-pick` over commits in Latin-1 and UTF-8 in each log encoding.
- `Repository.writeCommit` names `i18n.commitEncoding` in the `encoding` header when it is not UTF-8 (`CommitRequest.encoding` is gone), and under UTF-8 takes what is not UTF-8 as Latin-1, people and headers too, as git's `commit_tree` does (`text.encoding.ensureUtf8`, git's `ensure_utf8`); a message holding a NUL is refused (`NulInMessage`), as git refuses it. A stash's commits are written through it, unsigned. Held to `git commit-tree`.
- The cover letter's shortlog is the one shortlog (`pretty.shortlog`), the mailmap applied (`MailmapUnsupported` is gone); `pretty.shortlog.addWrappedText` and `WrapOptions` are gone for the one wrapper git's `strbuf_add_wrapped_text` has.

### Added

- `fast.exporter.Reencode.yes`: git's `--reencode=yes`, the message in UTF-8 and no `encoding`, one that will not convert kept as `no` keeps it. Held to `git fast-export --reencode=yes`.

## [0.18.0] - 2026-10-18

### Breaking

- Path settings are read as git's `git_config_pathname`, one function (`config.pathSetting`, `PathSettingError`): `:(optional)` marks a file that may be missing and is no value when its stat says it is not there, a stat failing any other way and a bare name are refused (`UnstatablePath`, `MissingPath`), and a relative path is found from where git runs, the top of the working tree, else the git directory (`Repository.topDirectory`). `Config.getPath(gpa, io, base, name)` reads every value in order, as git's callbacks do. Used by `core.excludesFile`, `core.attributesFile`, `commit.template`, `core.hooksPath` and `mailmap.file` (the last value, as git's configset), `init.templateDir` (`templateDir(gpa, io, base, config)`: bare unsets, a missing `:(optional)` directory is the value as written, as git's `template_dir_cb`), `core.fsmonitor`'s hook (`fsmonitor.configured(arena, io, config, dirs, programs)`), `fsck.skipList` (`fsck.Rules.readSkipList(…, SkipListAt, path)`, `ConfigureOptions.base`, `TransferInputs.base`), `gpg.*.program` (a missing optional program keeps the one before it) and `gpg.ssh.allowedSignersFile`/`revocationFile` (`Signer.init(gpa, io, config, base, programs)`; the signing programs run in `base`, as git runs them), and `http.*` paths (`http_settings.Sources.base`, `smart_http.Options.base`; a relative path is made whole from it). `lfs.storage` keeps plain interpolation, being git-lfs's setting. Held to `git config --type=path` over a listed corpus.
- `diff.renames` and `diff.renameLimit` are read as git's diff callbacks read them, every value, one git dies on refused (`diff.RenameSettings`, `diff.parseRenameSetting`, `diff.parseRenameLimit`; `patch.format.configuredRenames` is gone): relic took a bad value as the default. Held to `git log` over listed settings.
- A merge reads `merge_recursive_config`'s settings as merge-ort does, the last value of each: `merge.verbosity`, `diff.renameLimit` then `merge.renameLimit` (below -1 refused, where git's assertion stops), `merge.renormalize`, `diff.renames` then `merge.renames`, `merge.directoryRenames`, each refused where git dies (`InvalidMergeSetting`; relic took them as defaults, a bare `merge.directoryRenames` as off); `git merge` also reads every `diff.renames` and `diff.renameLimit` value as its diff settings do. Held to `git merge`.
- Status finds renames as `git status` finds them: `worktree.renames.find` puts the staged changes through diff's one rename engine (`diff.findRenames`), as git's `wt_status_collect_changes_index` does, and `worktree.renames.configured` reads `status.renames` and `status.renameLimit` over `diff.renames` and `diff.renameLimit`. The pass is in the worktree layer, above checkout's status and diff both. `worktree.Change` gains `renamed` and `copied`, `StatusEntry` its `source` and `score`. Held to `git status --porcelain` under each setting. Not yet: the working tree's side (a deletion paired with an intent-to-add file), which needs the working tree's bytes in the pairing.

### Added

- `diff.Order`: an order file (`-O`, `diff.orderFile`) as git's `diffcore_order` reads and applies it, through `TreeOptions.order`; format-patch (`Options.order`, `null` reads the setting) and range-diff read `diff.orderFile`. Held to `git diff-tree -O`.
- format-patch's `--relative` (`Options.directory`, where the caller stands, and `Options.relative`, `null` reading `diff.relative`, `diff.configuredRelative`): only the changes under the directory, named from it in the headers and the diffstat, the summary lines keeping whole paths, as git writes them. `TreeOptions.prefix` takes git's prefix with its trailing `/`. Held to `git format-patch --relative`.
- `diff.Options.suppress_blank_empty`, read by `diff.configured` from `diff.suppressBlankEmpty` and its old name `diff.suppress-blank-empty` (parallax 0.2.5's writer option). Held to `git diff` in the random settings corpus.

### Changed

- Pins parallax 0.2.5.

## [0.17.0] - 2026-10-17

### Breaking

- `commit.merging` writes `merge.log`'s list as git's `fmt-merge-msg` writes it with no editor open: under the title or the `-m` message, each merged branch, tag or commit with the subjects of the commits `HEAD` lacks, in `git log`'s order, merges left out, the count and `...` past the length, and under `merge.branchDesc` a local branch's description; held to `git merge` over branches, tags, remote-tracking branches, commits and octopuses. `error.UnsupportedMergeMessage` is gone; `mergeLogLength` is `MessageSettings.read`, which reads `merge.log`, `merge.summary`, `merge.branchDesc` and `merge.suppressDest` as git's callback reads them: `error.InvalidMergeSetting` for a `merge.branchDesc` that is not a boolean or a bare `merge.suppressDest` (relic took a bare one as empty), `error.InvalidBranchDescription` for a bare description the list reads. The message is made before anything is merged, as git makes it.
- `commit.cleanup` is git's explicit cleanup for picks, reverts and rebases, as git's sequencer reads it: `-x` and `--signoff` follow it (relic cleaned only whitespace with either whatever it said), and a pick sequence keeps it in `opts` as `--cleanup` is kept. `message.sequencerCleanup` returns `null` when no value names a mode; `message.sequencerDefault` and `message.uncut` give `try_to_commit`'s cleanup. `message.Cleanup` gains `scissors`, which cuts at the scissors line and cleans whitespace, as `git commit` does after an editor; `cleanupMode` gives it only for an editor. A message a person edits in a rebase (`reword`, `squash`, a commit after a stop) and a concluded merge are cleaned by `commit.cleanup` read for an editor (relic always stripped): `merging.ConcludeOptions.cleanup` is optional, `null` for that.
- The `Conflicts:` list a stopped merge, pick, revert or rebase leaves is git's `append_conflicts_hint`, one writer (`message.appendConflictsHint`): under the scissors line when the cleanup is `scissors`, a path with a newline commented line by line. `message.appendCommented` is git's `strbuf_add_commented_lines`, which the rebase sheet's help (`todo.appendHelp`, was `writeHelp`) and squash messages use; `trailer.locateEnd` (public, with `cut_line`) finds a whole scissors line only.
- send-pack reads report-status-v2 as git's `receive_status`: each run of `option` lines after an `ok` is one update of that ref (`RefReport.updates`, read by `RefReport.Update.take`, which the remote helper's reader uses too); a status about a ref not pushed is passed over; a ref said twice keeps the last word; an `ng` with no reason is `failed`; an `option` with no `ok` before it fails the push as git's does, what the rest said kept (`Report.stray_option`, `push.Outcome.stray_option`). The remote-tracking refs move as git's `transport_update_tracking_ref` moves them: by each update the remote named, to the value it said, a zero one deleting (relic moved only the ref pushed, for helpers too); held to `git push` against a `proc-receive` hook.
- `git am`'s `-p<n>` is read as `git apply` reads it, `strtol_i` of the whole word and not negative (relic took `-p-1` as a huge strip count).

### Changed

- GnuPG test homes are made under `/tmp` (`.zig-cache/gpg` on Windows), so gpg-agent's sockets fit the socket path limit from any checkout.

## [0.16.0] - 2026-10-17

### Breaking

- `worktree.fsmonitor.configured(arena, config, git_dir, programs)`: `core.fsmonitor=true` is git's daemon, `Source.daemon`, asked over the socket it listens on in the git directory (on Windows the pipe named after it) as git's `fsmonitor_ipc__send_query` asks it, held to git against a stand-in daemon (questions, answers split over lines or ended early, broken answers, what status reports, what the index vouches for and the token it keeps) and to git's own daemon where git has one. With no daemon listening every file is looked at and `builtin:fake` is kept, as git keeps it; git starts its daemon first, relic does not. `error.FsmonitorDaemonUnsupported` is gone. A bare `core.fsmonitor` is the daemon and a hook's path has its `~` expanded, as git reads them (relic took a bare name as off).
- `diff.configured` reads `diff.context`, `diff.interHunkContext` and `diff.indentHeuristic` beside `diff.algorithm`, every value in order as git's callback reads them, held to `git diff` over a random corpus of settings and texts: a count that is not an `int` of zero or more, or a heuristic that is not a boolean, is the new `error.InvalidDiffSetting` wherever it stands (relic read a bad `diff.context` as 3 or 0), and a bare `diff.algorithm` is `UnknownDiffAlgorithm`. `Options.inter_hunk_context` joins hunks as `--inter-hunk-context` does. `patch.format.configuredDiff` is gone: `format-patch` and `range-diff` take `diff.configured`.

## [0.15.0] - 2026-10-17

### Breaking

- Git LFS answers are read into git-lfs's own shapes, with Go's zero values for what is missing: `lfs.transfer.BatchResponse.transfer` and `hash_algo` are strings; `BatchObject.size` is an `i64`, `actions` and `_links` an `ActionSet` (an action by name, as Go's `map[string]*Action`; `Actions` is gone), and it gains `name` and `path`; an `Action`'s fields have defaults, `header` is an `lfs.api.HeaderMap`, `expires_at` a Go time and `expires_in` an `i64`. `lfs.locks.Lock.locked_at` and `Table.Entry.locked_at` are a Go time, zero for none. `lfs.api.SshAuth.expires_at` and `lfs.custom.Action.expires_at` are a Go time; `expiresWithin` takes one, and takes `in` to nanoseconds as Go multiplies. `lfs.api.json_policy` is gone; `parseJson` takes where the JSON came from (`JsonFrom`: an HTTP body, the first value read and the rest left, or a program's answer, whole), and `headersOf` a `HeaderMap`. `lfs.custom.writeRequest` and an agent's transfer fail with `UnwritableTime` for an expiry Go refuses to write, and the object fails as git-lfs's does.

- `lfs.netrc.Machine.name` is a string, empty for the `default` entry (`isDefault`), as go-netrc holds it: a `machine` with no name at the end of the file is one too.

### Added

- `lfs.api.go_json`: the reading choices of strand 0.12.0 that read JSON as git-lfs's Go reads it, which every LFS answer is read with. A corpus of 600 random answers of each kind relic reads (batch, lock, lock list and verify list, ssh authentication, custom adapter) holds relic to Go 1.27 reading them into git-lfs 3.8.0's types.
- `lfs.api.Exchange.readJson`: an answer's body only under git-lfs's JSON media types.
- `lfs.custom.Answer` and `parseAnswer`: an adapter's answer line, read as git-lfs reads it.

### Fixed

- A batch or lock answer under a `Content-Type` other than `application/vnd.git-lfs+json` or `application/json` (parameters after `;`) is refused with git-lfs's "Expected JSON type" (relic read it); an error body is read for its message only under them.
- A member given twice is read into what the first left, as Go reads it (relic took the last); a member's name matches its field exactly, then by case folding; `null` keeps a value and empties a list or a map; an integer is one only as written (`1.0` and `1e2` are refused, and `-0` for a size); a byte that is not UTF-8 and a lone surrogate escape read as U+FFFD; what follows an HTTP body's value is left, as Go's `json.Decoder` leaves it.
- Times are read as Go's `time.Parse(time.RFC3339)` reads them (a one-digit hour, a `,` before the fraction, its first nine digits, offsets to 24:00 and 60 minutes) and written as Go's `MarshalJSON` writes them, in their own offset; an ssh lock's `locked-at` is read so too (relic kept the text), and a listed lock with no time is incomplete, as git-lfs's `lockDataIsIncomplete` has it. A lock cache with a time Go cannot write is left empty, as git-lfs's file is.
- A custom adapter is sent every header of an action, sorted (relic wrote at most 64).
- `.netrc` is read as git-lfs's go-netrc reads it, held to it over 400 random files: tokens cut at Unicode's white space by Go's `bufio.Scanner`, through its growing buffer (white space at its end a token of its own, a token past 64 KiB refusing the file); no quotes or escapes (relic read `"…"` with `\`); a keyword's value is the next token whatever it is, a comment line among them, and empty at the end; a macro's keywords read as keywords (relic passed the body over); any other word passed over (relic refused the file); a second `default`, a `machine` after it, or a field given twice refuse the file. An entry is looked up by the host git-lfs's `getNetrcHostname` takes from the URL (Go's `SplitHostPort` where there is a `:`, brackets gone, no `.netrc` where it refuses) and the URL's user decoded (relic compared `%40` as written).

### Changed

- Pins strand 0.12.0. For development: preflight 0.8.2, whose riscv64 machine now carries git (`vm_packages`), so the comparisons with git run there instead of skipping.

## [0.14.0] - 2026-10-17

### Breaking

- `wire.credential.Session` is git's `struct credential`, held to `git credential fill` over a listed and a random corpus of URLs, `credential.*` settings and helper answers (what each helper and the person are asked, what fill prints, where git dies): its parts are read from the URL as `credential_from_url` reads them (the host with its port and brackets, the user, password, host and path decoded, a `%00` kept as written, the path without the slashes at either end, an empty user not the URL's); the `credential.*` settings are read once for a credential, every matching `credential.<url>.*` in order by git's urlmatch against the percent-encoded credential, and a pattern git cannot normalize compared part by part (`match_partial_url`); the path is dropped after them unless `useHttpPath`. `credential.urlMatches` is gone; `cert_path` is `Session.origin`, and `Session.forParts` names the parts as git-lfs hands them to `git credential fill`. New errors `InvalidCredentialSetting` (a bare `credential.*`, or a `useHttpPath`, `sanitizePrompt` or `protectProtocol` that is not a boolean) and `InvalidCredentialAnswer` (`quit`, `continue` or `ephemeral` not a boolean, a `url` git cannot read); `CredentialMultistageUnsupported` is gone.
- `wire.send_pack.RefReport.ok` is `status`, a `Status` with the states a remote helper's reason names (`up to date`, `no match`, `non-fast forward`, `already exists`, `fetch first`, `needs force`, `stale info`, `remote ref updated since checkout`, `expecting report`), with `forced` and the `updates` its `option` lines describe; `ok()` asks whether it was taken. `transport.push.RefResult.Status` gains `rejected_remote_updated`, `unreported` (a ref the remote said nothing of, git's "remote failed to report status"; relic took it as pushed) and `no_match` (no failure), and `RefResult.updates`.

### Added

- `wire.filter_spec.join`: a filter given again added as git's `parse_list_objects_filter` adds it.
- `text.ctype.char_signed` and `asChar`: a byte as git's C `char` compares it where relic runs.
- `report.warning.Warning.remote_helper`: what git warns of in a remote helper's answers (a helper that imports or exports without a `refspec`, an `option` answer git does not know, a refused `servpath`, a status for a ref nobody pushed).
- A helper's `continue=1` is a conversation of more than one round, as git and git-lfs hold one: a 401 to its credential asks the helper again, with the server's challenges and the state it answered with, where any other credential is erased; over smart HTTP three requests at most, as git's `http_request_recoverable`.

### Fixed

- A helper's answer is read as `credential_read` reads it: a line with no `=` ends it, keeping what came before; a line ends at a newline with one carriage return before it, and a key or value at a NUL; `protocol`, `host`, `path`, `wwwauth[]` and `url` are taken (`url` starts the credential over with no helper left to ask); `password_expiry_utc` as `strtoumax` reads it, a negative number wrapping; what a helper that fails wrote is still taken.
- A helper is handed what `credential_write` writes: the password with `get` too, the capabilities with `store` and `erase` only when a helper announced them, `continue=1` with the state capability, and the state answered at the last question rather than the one before; an expired credential loses its token as well as its password.
- A refused credential keeps its authtype and state, and loses its username, refresh token and expiry, as `credential_reject` leaves them; a credential is stored once.
- `credential.interactive` is read as `credential_getpass` reads it, only the plain key: false as a boolean, or `never`. A prompt names the path when it is kept.
- A `combine:` filter's part refuses every byte up to a space, control bytes among them, and bytes past ASCII where C's `char` is signed, as git's `has_reserved_character` compares them; `%00` stays as written, as `url_percent_decode` leaves it (relic decoded it to a NUL).
- A bundle's second `@filter=` joins the first in a `combine:`, encoded as git's `parse_list_objects_filter` encodes it (relic kept the last).
- A remote helper's answers are read as git's `transport-helper.c` reads them, held to `git ls-remote` and `git push --porcelain` against a scripted helper: a line ends at a newline with one carriage return before it, and at a NUL; a ref list's value is read as `get_oid_hex_algop` reads it, the bytes before a bad digit kept and no failure (relic refused the list), an `unchanged` ref this repository lacks refused (`UnchangedRefMissing`); a push status's reason is the state git names by it, a quoted one unquoted, `forced update` a forced update, `no match` ignored for a ref already settled, an `option` with no `ok` before it refused, and the private ref moved by each `option refname`/`new-oid`.
- An LFS credential is asked for with git-lfs's parts: the scheme in lower case, the host as written, a username only when there is one, and the path only under `credential.<url>.useHttpPath`.

## [0.13.0] - 2026-10-17

### Breaking

- `wire.url.Url.parse` reads an address as git's `transport_get`, `parse_connect_url` and `get_host_and_port` do, held to `git ls-remote` and `git fetch-pack --diag-url` over a listed and a random corpus: a scheme is matched exactly (`SSH://` and `HTTPS://` name the helpers `git-remote-SSH` and `git-remote-HTTPS`); a helper's name or a URL's scheme may begin with a digit (`1foo://`, `2x::`), and `::addr` names the helper `git-remote-`; `rsync:` is refused rather than handed to a helper; a `://` after anything that is no scheme git connects to is refused (`./dir/ssh://host/repo`); an ssh port is what `strtol` reads (`+22`, ` 22`, `-0`), and anything else after the colon stays in the host as ssh is given it (`host:abc`, `host:65536`); an ssh user is split from the host at its last `@` only, with no password; the scp-like form takes an empty path (`host:`) and git's `~` rule (`host:a~b` reaches `~b`); an http URL's authority ends at the first `/`, `?` or `#` and its user at the first `@`, as curl and `credential_from_url` read it. relic still reaches a local directory whose name begins `[...]` as named, where `git fetch` drops that part (`git clone` does not).
- `config.gitmodules.checkUrl` takes an allocator: a URL curl is given is checked by normalizing it as git does.
- `wire.http_settings.resolve` takes an `Io`, the URL, and its `Sources` (configuration, environment, remote name), and `resolveForRemote` is gone into it: a path setting marked `:(optional)` is dropped when no file is there, as `git_config_pathname` drops it.

### Added

- `text.urlmatch`: git's `url_normalize`, `match_urls` and `cmp_matches`, held to `git config --get-urlmatch`.

### Fixed

- `http.<url>.*` settings match as git's urlmatch matches them: the URL and each pattern normalized (case, escapes, default and zero-padded ports, `.` and `..`), the longer host winning, then the longer path, then a named user (relic preferred an exact host over a wildcard, which git does not); a URL git cannot normalize takes only the settings written without one.
- `http.*` values are read as git's `http_options` reads them: a bare string or path setting, `extraHeader`, `curloptResolve` or `proactiveAuth` is refused, as git dies on it; a number must be an `int`, a boolean one of git's spellings or an `int`, for the settings relic does not use as well; path settings (`sslCert`, `sslKey`, `sslCAInfo`, `sslCAPath`) are interpolated where they are read and the environment's (`GIT_SSL_CERT` and the rest) are used as they are; `http.postBuffer` below 65520 bytes is 65520, with no upper bound (relic clamped to 1 KiB-1 GiB).
- `transfer.credentialsInUrl` finds a password as git's `url_normalize` does, in a URL of any scheme, and names the normalized URL in its warning; a value other than `allow`, `warn` and `die` is refused whatever the URL.
- An ssh target is refused as an option when the `user@host` ssh is given begins with `-`, as git checks it (relic checked the user and the host apart).
- A boolean setting written as a number must fit an `int`, as `git_parse_maybe_bool` reads it.

## [0.12.0] - 2026-10-17

### Breaking

- One reader per operation setting, each refusing a value git dies on wherever it stands, the last good one deciding: `commit.message.Comment` (`core.commentChar` and `core.commentString` as one setting, `auto` choosing as `git commit`'s `adjust_comment_line_char` does against the message given, before trailers and hooks) replaces `commit.message.commentString`; `message.cleanupMode`, `cleanupSetting`, `commitCleanup` and `sequencerCleanup` (which now refuses a bare `commit.cleanup`); `merge.configuredStyle` for every content merge (`merge`, picks, rebase, notes, rerere, `apply --3way`). New errors: `MissingSigningValue`, `InvalidCommentString`, `NoCommentCharacter`, `InvalidConflictStyle`, `InvalidCleanupMode` (merge, picks, rebase), `InvalidMergeLog`, `InvalidDriverBinary`.
- `user_diff.Driver.says` and `isBinary`, and `diff.BinaryRule.isBinary`, refuse a `diff.<driver>.binary` that is neither a boolean nor `auto` (`InvalidDriverBinary`), as git dies on it, and read every value as userdiff's `parse_tristate` does: `auto` after a boolean leaves it to the bytes again.
- `patch.apply.keptFiles` takes the object format whose names bound an `index` line.
- `wire.refspec.Refspec.parse` and `wire.remote.Remote.get` take the repository's object format, and `transport.remote_helper.OpenOptions.object_format` the helper's: a refspec's source is an object only at that format's full length, as git's `get_oid_hex_algop` reads one; one of the other format's length is a ref name (relic took 40 or 64 digits as an object in either).
- `commit.rebase.parseAuthorScript` is gone: `repo.state.AuthorScript.parse` reads `author-script` for rebase and `am` alike, as git's `read_author_script` does (a blank line, a repeated or unknown variable, or a value that is not one single-quoted word refused), and a rebase reads the date as `git commit` does, any form git's `parse_date` takes (`InvalidDate` where it takes none).

### Added

- `config.Config.iterate`: every entry of one or more names in git's reading order, for settings git reads value by value and names it reads as one setting.
- `config.parseBoolOrInt` (git's `git_config_bool_or_int`) and `config.parseNonNegative` (git's `git_parse_unsigned`).
- `commit.merging.Options.cleanup` (`--cleanup`) and `commit.merging.mergeLogLength`: `merge.log` and its old name `merge.summary`, read as one setting, true being 20; a merge reads `commit.cleanup` before it merges anything, as `git merge` does.

### Fixed

- A Windows stat that cannot be taken names its failure (`AccessDenied`, `BadPathName`, `NetworkNotFound`, ...) instead of answering with `std.Io`'s stat, which describes a file otherwise (no attributes, the attribute-change time, a link's size as zero); a reparse point other than a symbolic link or a junction is the file or directory its attributes say, as git for Windows' `file_attr_to_st_mode` makes it, where relic called it unknown (cloud placeholders, deduplicated files).
- `git commit` with `auto` comment characters: the characters a line begins with in the message are passed over, `\r` line starts too, and those in the comments at its end are not, as git counts them; every candidate taken is refused, as git dies. The message is cleaned of whitespace only before the `prepare-commit-msg` hook, its comments after, as `git commit` does.
- `merge.summary` is read, as `merge.log`'s old name; a `merge.log` count or boolean is read where relic refused a count (a positive length is still `UnsupportedMergeMessage`).
- A stopped rebase's one-line files read as git's `read_oneliner` takes them (one `\n`, then one `\r`, off the end) and its names as `get_oid_hex` reads them; `orig-head` falls back to an older git's `head`; a `gpg_sign_opt` that is not `-S…` and an unknown `allow_rerere_autoupdate` are passed over as git passes them over; `current-fixups` counts as git counts it; how many steps are done comes from `done`, as `read_populate_todo` counts it, not from `msgnum`.
- A cherry-pick or revert sequence reads `sequencer/opts` as `populate_opts_cb` does: a key outside `[options]`, a bare one, a switch that is not a boolean (a count included) and a cleanup mode git does not know are refused, and `default-msg-cleanup = default` is `strip`; `--abort` reads the first line of `sequencer/head` and refuses an `abort-safety` with no name in it, as git dies on both.
- Signing settings read value by value as `git_gpg_config` reads them: a `gpg.format` or `gpg.minTrustLevel` git does not know is refused even with a good one after it, a bare `user.signingKey`, `gpg.format`, program or SSH setting is refused (`MissingSigningValue`), and `user.signingKey` is kept as written, an SSH key file's `~` expanded where it is signed with, a `-S<file>` key's too, as git expands it (relic expanded every format's key and no `-S` key).
- `git am`'s `-C<n>` reads as `git apply`'s `OPT_UNSIGNED`: base 0 and a `k`, `m` or `g` suffix (`-C0x2`, `-C+1`).
- A patch's quoted name ends at a `\000`, as git's C string does, in the `diff --git` line and the `---`/`+++` lines; an `index` line naming more hex digits than the repository's object names is not read, its mode included, as `gitdiff_index` reads none (relic took up to 64 in a SHA-1 repository).

### Changed

- The release tier's ThreadSanitizer run is four jobs, each a shard of the suite (preflight 0.6.3, pinned for development, splits a declared job); the whole suite under the sanitizer outgrew one job's 30 minutes.

## [0.11.0] - 2026-10-15

### Breaking

- Pins uplink 0.7.0, cloak 0.10.3 and warp 0.4.0, whose types relic's HTTP options carry (`cloak.ClientAuth`, `cloak.Trust.Snapshot`, `uplink.tls.ClientOptions`). A TLS 1.2 server that asks for an Ed25519 client certificate now gets one (cloak 0.7.1).
- `text.ere` reads a pattern as git's `compat/regex` (glibc's) reads it, where it read some as literals: an extended expression's `{` must open a whole interval after an operand (`a{1`, `a{x}`, `a{}`, `{1}` and `^{` are refused), no repetition may follow an anchor or word boundary in an extended expression (`^*`, `$+`, `\b?`), a basic expression takes no `*` or `\{` straight after a repetition (`a**`) and keeps `*` after an anchor as itself, and a bracket refuses a range from or to a class or equivalence class and a `-` after a range anywhere but last (`[[:alpha:]-z]`, `[a-z-9]`); a range may end at a collating symbol (`[a-[.z.]]`). `git grep`, `diff`'s function patterns and `:/` searches see the same.
- `index.Index` reads an entry with any mode, as git's `do_read_index` does, and writes it back as it was spelled while the entry keeps that mode (`Entry.raw_mode`, `Entry.diskMode`); `Error.InvalidMode` is gone.

### Added

- `refs.verify.check`: git's `refs verify` over one worktree's store, findings named by `fsck.<msg-id>` at the levels `fsck.Rules` give: loose refs (`badRefContent`, `refMissingNewline`, `trailingRefContent`, `badRefName`, `badRefFiletype`, `symlinkRef`, `badRefOid`, `badHeadTarget`, `badReferentName`, `symrefTargetIsNotARef`), root refs as git walks them, `packed-refs` (header, entries, peeled lines, newline, order) and reftable table names and refs, a linked worktree's under `worktrees/<id>/`.
- `refs.Log.skipped`: how many reflog lines git's reader would pass over.

### Fixed

- A zip archive marks an entry text or binary by its `diff` driver as git's `entry_is_binary` does: `diff.<driver>.binary`, a link by its attributes too, and a path with no driver or an unknown one by the `default` driver's configuration. `diff`, `grep` and `range-diff` take the same driver lookup for binary files (`diff.default.binary`), and `grep -p` and `-W` the `default` driver's `xfuncname`.
- `clean` adds each `-e` pattern as given, git's `add_pattern`: `#` and trailing spaces are part of it (sweep 0.2.4's `gitignore.parsePattern`).
- A sparse-checkout file with CRLF lines is read as a cone in cone mode, as git reads it.
- `-X patience` and `-X histogram` clear `diff-algorithm=minimal`, as git's `DIFF_WITH_ALG` replaces the whole algorithm.
- An empty `trailer.separators` joins a trailer's key to its value with the NUL git writes, where relic read past the end.
- A merge concluded from `MERGE_HEAD` takes each line as git's `get_merge_parent` takes it: any revision, peeled to its commit.

### Changed

- Pins sweep 0.2.4; preflight 0.6.0 for development.

## [0.10.0] - 2026-10-15

### Breaking

- Pins uplink 0.6.0 and cloak 0.6.0, whose types relic's HTTP options carry (`cloak.ClientAuth`, `cloak.Trust.Snapshot`, `uplink.tls.ClientOptions`). cloak stays on uplink's line: relic hands cloak's values to uplink, so both must build one cloak. An RSA client key is no longer tested for primality as it loads (cloak 0.6), only for the agreement of its numbers.

### Changed

- Pins conduit 0.8.1 (its spans are `conduit.Duration`), strand 0.11.0, airlock 0.3.5, sweep 0.2.3 and parallax 0.2.4; preflight 0.5.6 and shakedown 0.4.3 for development. warp stays 0.3.1, uplink's line, until uplink moves.

## [0.9.0] - 2026-10-14

### Breaking

- `object.Signature.parse` reads an ident as git's `split_ident_line`: a malformed date or zone is a person with no date, never `InvalidSignatureTime`. A commit whose author or committer git cannot read parses with `Signature.unknown` and `Commit.malformed_idents` set, a tag whose tagger git cannot read has none, and a header line with no space is an extra header with no value; fsck still refuses each.
- `object.Mode.parse` reads any number of octal digits and folds them as git's `canon_mode` (`Mode.canonical`): only the owner's execute bit makes a file executable, and `0` and every value of no other type is a gitlink. A tree entry whose name holds a `/` reads, as git reads it, and fsck reports it.
- `odb.pack.Index` reads version 1 indexes (`Index.version`); `Index.Located.crc` and `Index.crcAt` are `?u32`, `null` in version 1, whose entries a repack writes again rather than copies. `UnsupportedIndexVersion` is gone.
- `index.Index` reads the extended flag word in any version and refuses a bit git does not know (`UnknownEntryFlags`); a `TREE`, `REUC` or `FSMN` that cannot be read is dropped and said in `Index.dropped`, where it refused the index; unknown optional extensions such as `UNTR` are read but no longer written back; a split index's `link` is held to its shared index (`CorruptLinkExtension`).
- `config.interpolatePath` and `Config.getPath` return `config.PathError`: `~user` expands to that user's home, and no home, no such user and `%(prefix)/` are `UnexpandablePath`, as git's `interpolate_path` gives up on them. An include that cannot be expanded or that does not parse is an error and only a missing one is skipped; a relative include or `gitdir:./` condition from the command line is `RelativeIncludeOutsideFile`.
- `patterns.attributes.Attributes.isTrue` says whether an attribute is set and nothing more. `patterns.attributes.Attrs.addText` takes the text and a `TextOptions` (`base`, `source`, `precedence`, `form`), its `Form` `.file` as git reads a file (a UTF-8 BOM passed over, a line ending at a NUL) or `.blob` as it reads one from the index or a tree (ending at its first NUL).
- `patterns.pathspec.parse` refuses `""` (`EmptyPathspec`), short magic git has no mnemonic for and a `prefix:` that is not a number (`InvalidPathspecMagic`).
- `refs.Format.parse`, `extensions.refStorage` and `extensions.objectFormat` take a format's name exactly.

### Fixed

- `packed-refs` is read by git's grammar: a traits header only as the first line, any space character after the object name, a newline after every line, the peeled line exactly, a name that reaches outside the store refused, and a broken name's peeled value dropped.
- A reflog line is read as git's `show_one_reflog_ent`: a last line with no newline, a zero time, or a zone that is not a sign and four digits is skipped, and the message starts after one tab.
- A `tables.list` whose last name has no newline is refused; a `.git/shallow` line is an object name and whatever follows, an empty line refused; `@{-n}` is read with `strtol`; a `commondir` that is there but cannot be read is an error.
- An alternates file is cut as git's `parse_alt_odb_entries` cuts it: a CR stays in the path, broken quoting reads the line as it is, a quoted name may hold a newline, and the byte after a closing quote is passed over.
- An `@<stamp>` past a time's range is no stamp, and the date goes on to the general reader.
- An attributes line is read as git's `parse_attr_line`: a CR is blank, a name no attribute may have or one beginning `builtin_` passes the line over, `-a=b` unsets `a`, a negative pattern is ignored, and `[attr] x` is a pattern.
- `GIT_CONFIG_COUNT` is read by `strtoul` and no more than an `int` holds; a `GIT_CONFIG_NOSYSTEM` that is no boolean is an error.
- A configuration file is read up to 1 GiB, where 16 MiB was the cap.
- An in-tree `.gitignore` that is a symbolic link is not read, as git does not follow one.
- `export-ignore` and `export-subst` take effect only when set, git's `ATTR_TRUE`, never for a value.

## [0.8.0] - 2026-10-14

### Breaking

- Pins uplink 0.4.1, cloak 0.4.0, strand 0.10.2 and warp 0.3.1, whose types relic's options carry: an HTTP timeout is `uplink.Duration`, aegis's duration in nanoseconds, where it was `Io.Duration`.

### Changed

- Pins conduit 0.7.1 (reactor 0.4); preflight 0.5.2 and shakedown 0.4.2 for development.
- HTTPS speaks TLS 1.2 as well as TLS 1.3 (cloak 0.4), and a client certificate with an RSA key answers a server that asks for one, signing with RSA-PSS. In TLS 1.2 an Ed25519 key is answered with no certificate: cloak does not sign a whole TLS 1.2 handshake yet.

## [0.7.1] - 2026-10-14

### Added

- `repo.fs.permissionsAt` (a path's permissions without following a link: its mode, or on Windows its attributes), `repo.fs.sameFile` (one file by the platform's identity) and `repo.fs.validityAt` (a stat for telling whether a file changed, as git's `stat_validity`).

### Fixed

- On Windows a file's stat is git for Windows' own: its creation time as the change time, no inode, a link's target length as its size. An index relic writes there no longer looks changed in every entry to git, and an index git refreshed no longer looks changed to relic, which had kept files a sparse checkout removes.
- On Windows a lockable file's read-only attribute is read from the file: the standard library reports no attributes there, so taking a lock never made a read-only file writable again.
- On Windows a forced checkout replaces a link to a directory standing where a directory goes, and `repo.fs.deleteFile` removes such a link, not what it points at, as git for Windows' `unlink` does.

## [0.7.0] - 2026-10-14

### Breaking

- An index is written under the lock it was read under: `Repository.lockIndex` takes `index.lock`, reads the index, and its `LockedIndex.commit` writes it as git does (`Index.commitTo` writes into a held lock); `Repository.writeIndex` is gone. `merge.rerere.afterStop` takes the lock itself and no index.
- The state files an operation keeps are `repo.state` (`write`, `read`, `remove`, `exists`), where they were `commit.head`'s `writeState`, `readState`, `removeState` and `stateExists`; `commit.in_progress.read` says which operations a worktree is in the middle of, as `git status` says.
- `.git/shallow` is written by `Repository.writeShallow`; `rev_walk.shallow.write` takes `WriteOptions` (the file as it was read, and the shared mode) and returns what the file is after.
- `repo.Settings` holds the engines' `core` settings, read once per published configuration (`Repository.settings`): a malformed `core.ignoreCase`, `core.fileMode`, `core.symlinks`, `core.checkStat`, `core.trustCtime`, `core.maxTreeDepth`, `core.protectNTFS` or `core.protectHFS` refuses the configuration, as git dies on it. `fs.Stat.matches` takes a `Stat.Compare`; `worktree.Rules` gains `trust_ctime` and `protect`.
- `names.path`'s checks take a `Protect` (`core.protectNTFS`, on everywhere, and `core.protectHFS`, on on macOS), and `worktree.removeEntry` takes one.
- `lfs.Lfs.Options`, `checkout.filter.Drivers.Directories` and the native filter's `LoadOptions` take the repository's `shared` mode.
- The object database owns its pack directory and `.promisor` files: `Odb.openPackDirectory`, `Odb.writePromisor`, `Odb.commitGraph`; `transport.partial.writePromisor` takes the database; `transport.bundle.ReceiveInputs` has no `pack_dir`.
- `discover.directory` is the one check of a git directory (`isGitDirectory`, `validHead`, `openCommon`); `discover.gitlink.isGitDirectory` is gone.
- `config.parseInt` is `config.parseInteger`; `config.interpolatePath` expands every path setting.
- `commit.Cleanup` and `commit.stripspace` are gone: `commit.message.Cleanup`, `stripSpace`, `commitCleanup` and `sequencerCleanup` are the one cleanup. `fast.importer.signedOffset` is `commit.signing.signedOffset`; `object.findHeader` is the one header search.

### Fixed

- Two index writers no longer lose an update: the lock is held from the read to the write, and `git add` waits its turn while relic holds it.
- A linked worktree's split index is read with the shared index in its own git directory.
- A changed status-change time says a file may have changed under `core.trustCtime`, as in git.
- `repack` with `remove_packs` leaves a kept pack and its objects alone, keeps promisor objects in a promisor pack, and removes every companion of a pack it replaces.
- A shallow file another writer changed since it was read is not replaced; `MERGE_RR.lock` is held across a rerere run; LFS storage and a submodule's git directory are made with `core.sharedRepository`'s modes.
- Numbers in git's data are read by git's grammars: a `+` or `_` no longer passes where git takes only digits, and C's `strtol` is followed where git calls it.
- A vertical tab and a form feed are not spaces, as git's `isspace` has it, in mail, patches, trailers, diffs and dates.
- An author script with `'\!'` in it reads back.
- A directory is a git directory only with a `HEAD` that names a ref or an object and with `objects` and `refs` in its common directory, as git's `is_git_directory` asks.
- A worktree id is one name in every worktree entry point.
- An index git wrote with names Windows refuses opens: paths are checked by the checkout that would write them.
- A version-one changed-path Bloom filter hashes a byte with the high bit as the platform's `char`, as git does, so relic's commit-graph matches git's byte for byte on Linux on ARM too.
- A file's stat builds where `st_dev` is unsigned, as on FreeBSD.
- A `.lfsconfig` rewritten at the same size within one tick of the filesystem's clock is read again on every platform, not only on Windows.

### Changed

- The LFS lockable-file tests and the cancelled-ssh fetch run on Windows; every test still skipped there says why at the test.
- Pins airlock 0.3.3, parallax 0.2.3 and warp 0.2.4.

## [0.6.0] - 2026-10-13

### Breaking

- Every public namespace whose name ran two words together is snake_case, the family's one naming convention, and the names that shared a prefix are one namespace each: `fast` (was `fastimport` and `fastexport`) with `fast.importer` and `fast.exporter`; `rev_walk` (was `revwalk`) with `rev_walk.rev_parse` and `rev_walk.object` (was `objectwalk` and `objectfilter`) with `object.walk` and `object.filter`; `odb.commit_graph`, `odb.rev_index`, `odb.index_pack`; `refs.reftable` with `reftable.table` (the format, was `refs.reftable`) and `reftable.stack` (was `refs.reftablestack`); `worktree.sparse_checkout`, `worktree.dir_scan`, `worktree.safe_path`; `diff.patch_id`; `merge.three_way`, `merge.subtree_shift`; `transport.filter_spec`, `transport.side_band`, `transport.http_settings`, `transport.fetch_pack`, `transport.send_pack`, `transport.smart_http`, `transport.pkt_line`, `transport.upload_pack`, `transport.remote_helper`; `patch.range_diff`. Names git spells as one word stay one: `reftable`, `refspec`, `gitlink`, `gitmodules`, `mailmap`, `fsmonitor`, `shortlog`, `rerere`, `netrc`, `midx`, `sha1dc`.
- `worktree.ignore`, `worktree.attributes` and `worktree.sparse` take a path's kind as sweep names it (`.file` or `.dir`), where they took `is_dir: bool`: `Rules.match`, `Rules.matchPath`, `Checker.excluded`, `Checker.match`, `Attrs.lookup`, `Patterns.includes`, `Cone.match`. Their rules, attributes and patterns hold the set caches their queries run on, so one thread at a time asks them; the spin locks that made threads take turns are gone, and so is the one behind a pattern longer than sweep compiles as a `Pattern`.
- `worktree.ignore.Checker.release` is `toRules`, as a value moved out is named in Zig.
- `repo.CreateOptions` is `repo.Repository.CreateOptions`, beside `Repository.create`.
- `Repository.refreshConfig`, `writeConfig`, `editConfig` and `writeCommit` take an options struct last (`RefreshConfigOptions`, `WriteConfigOptions`, `EditConfigOptions`, `WriteCommitOptions`) whose `diagnostic` is the one their trailing `?*Diagnostic` was: `.{}` for none.
- `repo.program.Child` is `conduit.Child`, conduit's own type, where it was a wrapper over it; `process.child` is gone.
- `transport.connection.Connection.VTable.close` is `deinit`, the one word that releases a connection.
- `lfs.ssh.Connection.readStatus` is `readAnswer`, and `readStatusWithData` is `readHead`, which returns an `lfs.ssh.Head`.

### Fixed

- upload-pack's advertisement reports a failure reading refs or objects as that failure, where it reported every one as `WriteFailed`.

### Changed

- The test that ran `python3` to make zlib streams for warp's decoder is gone: the decoder's corpus is warp's.

## [0.5.0] - 2026-10-13

### Breaking

- `wire.clientcert.Files` takes `cert_format` and `key_format`, a `clientcert.Format` (`pem` or `der`) that `Format.parse` reads from `http.sslCertType` and `http.sslKeyType`, where it took the setting's text. `wire.hidden.Service` is `wire.connection.Service`, the one enum of the two services.

### Changed

- Pins conduit 0.7.0, sweep 0.2.2, parallax 0.2.2, uplink 0.2.5, airlock 0.3.1, warp 0.2.2, cloak 0.3.0, strand 0.8.3, preflight 0.4.2 and shakedown 0.3.2.

## [0.4.2] - 2026-10-13

### Changed

- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.4.1] - 2026-10-12

### Changed

- Pins sweep 0.2.1, parallax 0.2.1, uplink 0.2.3, airlock 0.2.1, warp 0.2.1, cloak 0.2.1, strand 0.8.1, preflight 0.3.4 and shakedown 0.2.6.

## [0.4.0] - 2026-10-12

### Breaking

- relic is developed with [bay](https://github.com/pedronaugusto/bay): preflight and shakedown are dev dependencies, and the tests, helpers, examples, checks and benchmarks are the development build's (`bay test`, `bay check`, `bay bench`). relic ships with conduit, sweep, parallax, airlock and warp, and with `-Dhttp` (the default) uplink, cloak and strand; what a project that depends on it builds is unchanged. The family's packages are pinned to the revisions developed with bay, on one aegis. The tests link relic's own shakedown, bound to the aegis airlock is built on, with airlock's seam built on it through airlock's `testing` and `aegis`.
- Time a caller gives is typed: every "now" (`transport`, `credential`, smart-HTTP and LFS options, `date.Context` and `date.Clock`, `revparse.Clock`, `archive.Options.now` and `mtime`, `patch.format` threading, `rerere.gc`, LFS `sweepTmp` and `expiredAt`) is a `std.Io.Timestamp`, `--shallow-since` and the commit-graph's `expire_time` too; a lock's wait is `fs.OnContention.wait`, a `std.Io.Duration`; LFS `retryAfterSeconds` is `parseRetryAfter`, returning a duration. `date.timestamp` makes one from git's seconds. Times git stores (a commit's, a reflog entry's) stay git's seconds.
- relic reads `core.fsync`, `core.fsyncMethod` and `core.fsyncObjectFiles`, as git reads them, and every writer they name keeps them: loose objects, packs (received ones included), their indexes and bitmaps, the commit-graph, the index, and refs, logs and reftable tables. Unset, packs, their metadata, the commit-graph, the index and references are synced, git's default with the last two besides; set, the value is read over git's default alone, so `core.fsync = pack` leaves references unsynced as git does. `core.fsyncObjectFiles` syncs loose objects whatever `core.fsync` says (`fs.Fsync.object_files`), batched only where `core.fsync` names them, as git's `close_loose_object` syncs them. Config and state files are not synced, as git does not. A received pack was not synced at all before, so a crash after a fetch could leave refs naming a pack that never reached the disk. `fs.Fsync` holds the policy and `fs.Sync` gains `ordered` (`writeout-only`); `odb.Options.sync` is `odb.Options.fsync`, `pack.WriteOptions.sync` is `fsync`, `PackOptions.sync` and `indexpack.Options.sync` are gone (the database's policy applies), the maintenance writers' `sync` is optional and defaults to the database's, `LockFile.Options.sync` has no default, and `Repository.indexLock` gives an index writer its lock options.
- A `.git` file is read in one place, `discover.gitfile`, as git reads it: `gitdir: ` with its space, the path up to the line ending, spaces kept, up to 1 MiB. Submodules and linked worktrees used to accept `gitdir:` without the space and trim spaces around the path. `checkout.worktrees.readGitFile` is removed; `discover.gitfile.read` takes its place.
- Certificates, keys and trust are [cloak](https://github.com/pedronaugusto/cloak)'s, which relic depends on directly; uplink makes the connections. `wire.clientcert.load` returns a `cloak.ClientAuth` (released with `deinit`), and the new `wire.authorities` reads `http.sslCAInfo`, `http.sslCAPath` and `http.proxySSLCAInfo` into a `cloak.Trust.Snapshot`, used by the smart-HTTP and LFS transports alike. On macOS and Windows the system's authorities are the system's own verifier, with `http.sslCAPath`'s besides it. A certificate file may also hold its key, and text before a block, as OpenSSL writes it, is read past. Until cloak speaks TLS 1.2 and signs with RSA keys, a server that speaks only TLS 1.2 fails with `error.TlsFailed`, and an RSA client key with `error.ClientCertificateSchemeUnsupported`.
- airlock owns relic's lock files, replacements and syncs. `LockFile` is an airlock temp named `<path>.lock`, still taken exclusively with git's backoff and the holder's pid in its first bytes, and `LockFile.Options.sync_directory` still makes its target's directory durable; `atomicWrite` is an airlock temp too, and takes `permissions` for a replacement that keeps the replaced file's; `fs.renameWithRetry` is `fs.rename`, which retries on Windows as airlock does; `fs.syncBarrier` and `fs.syncPath` are removed, and `odb.Options.sync_directories` with them. `Odb.syncBatch` flushes the fan-out directories that received loose objects since the last call, once each, where it created and removed a file to flush none; a pack written or received while `core.fsync` syncs packs flushes its directory once its names are in place, before a ref moves to it or a loose object it holds is removed. `Odb.makeDurable` and a durable checkout sync their files and directories together, one flush of the volume for all of them.
- `Attrs.Macro.assignments` is read-only; the built-in binary macro borrows static assignments.
- Native filter, clone-filter and before-send callbacks receive allocator and Io before their opaque context; LFS SSH status readers receive allocator before Io.
- Conversion sessions use `open(gpa, io, Options)` and `deinit(io)`. Filter processes and native providers receive the teardown call’s I/O.
- Hook, trailer, mailmap, remote URL, LFS pattern and helper operations take defaulted policy options. Ref listing writes take the output writer before `WriteOptions`; transport policy takes a name and `Options`.
- Ignore, attribute and sparse pattern constructors take defaulted `InitOptions`. Sparse file loading has one `load` operation with `LoadOptions`; `loadMode` is removed.
- Object and binary-patch decoding use warp directly; the internal `odb.inflate` namespace and copied decoder are removed. Pack resource failures retain their I/O causes.
- Object validation, conversion, hook preparation, identity, branch movement and pretty formatting group related inputs and defaulted options. Every exported function and method takes at most five positional inputs.
- Archive, range-diff, linked-worktree, bisect marking, subtree shifting and bitmap writes take named input groups. Archive and range-diff output writers precede their options. Published bytes, selection policies, local edits and bitmap object ordering keep their behavior.
- Ref-log append takes AppendInputs before LogMessage; expiration takes its generic keeper before named options containing the ref name. Reftable writes take WriteInputs before WriteOptions, and compaction takes CompactInputs. Keeper order, rewrite/update-ref policy and record bytes are preserved across files and reftable.
- Working-tree staging/status, checkout, path writes, verification, comparisons and sparse application take named input groups after the working directory. The index and object database stay borrowed; path selection, refusal diagnostics, local edits and durability keep their behavior.
- Transport session, fetch/send pack, local receive and bundle APIs group their named inputs; bundle creation takes Target. LFS pre-push and SSH invocation take input groups and options. Object retention, protocol bytes, lock pagination and failure/cancellation outcomes keep their contracts.
- LockFile.open takes Inputs for the path and borrowed buffer; atomicWrite and readFileSized take named options. Program invocation and trailer commands use relic's own Cwd type. Sized-read fallback failures free their original allocation exactly once, including a grown file over its limit.
- Pack/index opening and pack decode requests take named inputs and options. Pack Writer.open replaces init and initCounting, with a nullable count in OpenInputs; openStream takes StreamInputs before its output writer. Index and reverse-index writes take write options; indexpack and bitmap encoding take input groups. Pack publication, retention and format bytes keep their contracts.
- Unified diff takes UnifiedInputs before its output writer; blame groups commit/path in Inputs; patch ids take the shared diff.TreeInputs. Output formatting, attribution and patch-id semantics are unchanged.
- Working-tree merges take TreeInputs, CommitInputs or OctopusInputs, including their mutable index. Reset takes Options for its index, target tree and overwrite policy; sequencer.resetMerge takes ResetOptions for ref identity and refusal diagnostics. Unrelated edits and abort restoration keep their existing behavior.
- Merge trees/commits and diff tree pairs take named input groups; ancestry and merge-base walks take Pair, Many or Ancestry plus BaseOptions. Options and all semantic outcomes are preserved in their canonical operations.
- Index reads take ReadOptions, including optional measured timestamp resolution. Object walks use MissingOptions, ConnectedOptions and ReceivedOptions in their canonical operations; the With variants are removed. Top-level note copy takes CopyRefOptions; trailer processing and amendment take named request options.
- `Repository.create` replaces `Repository.init`; repository mutable state is reached through directory, allocator, object database and configuration accessors. Public concerns move to `maintenance`, `pretty.refs` and `pretty.shortlog`; object walks are under `revwalk`. LFS submodules drop the repeated `lfs` prefix; configuration, sparse index, hooks and linked worktree namespaces use their concern names.
- Owned connections use `deinit` as their release word. Program calls take allocator and I/O before the program policy; `run` takes `RunOptions` for input and bounds. Signing takes I/O before its signer. Arena choices belong to operation options. Inline public error unions have names.
- HTTP and TLS are [uplink](https://github.com/pedronaugusto/uplink)'s; relic's own HTTP/1.1 client, its proxy authentication, its SOCKS client and its copy of std's TLS client are gone, and relic's API names no uplink type. `transport.httpclient`, `transport.httpauth`, `transport.tls`, `transport.clientcert` and `lfs.lfsapi.timeoutsFor` are removed; LFS transport and exchange network state are opaque, and `Exchange.response` and `Exchange.diagnostics` are removed; smart HTTP and LFS are configured by git's and git-lfs's settings as before, which relic maps onto uplink's options. The errors a proxy fails with are uplink's: `ProxyNetworkUnreachable` and `ProxyTtlExpired` are `ProxyHostUnreachable`, `ProxyCommandUnsupported` is `ProxyRefused`, and `SocksProtocolError` is `ProxyProtocolError`, the SOCKS reply code in the message. A remote URL whose path holds a space or a control character is `MalformedUrl`, as git refuses it, where the bytes went onto the request line; an `http.extraHeader` that is no field (a name that is not a token, a control character in its value) or names `Host`, `Content-Length` or `Transfer-Encoding`, and an `http.userAgent` with a control character, are `InvalidHttpHeader`, where they were sent as given. Responses are read as git reads them: a bare LF ends a line and a folded field is unfolded, where both were refused, and a `Content-Length` with an underscore, which std's number parser took, is refused. `no_proxy` names an address range in CIDR notation, as git reads it. Every socket has `TCP_NODELAY`, as git sets it.
- A repository's ref format is decided once, from its own `config`, and handed to whatever opens its refs. A submodule's gitlink reads its repository's own format rather than probing for `reftable/tables.list` (`submodule.gitlink.head` and `GitDir.refStore` take no `kind`), and `worktree.worktrees.add`, `list` and `prune` take the repository's `refs.Store` in place of its `common_dir` and hash, reading each worktree's `HEAD` through it as `worktrees/<id>/HEAD`. `refs.create` lays down a new ref store's directories as git's `ref_store_create_on_disk` does, and `Repository.init` and `worktrees.add` then write `HEAD` through a transaction; `refs.reftablestack.initialize`, `headIn` and `isReftableRepository` are removed, and `refs.Format.name` and `parse` spell the formats as `extensions.refStorage` does. `refs.Store.writeInitial` is git's initial ref transaction: a clone writes the fetched refs through it, packed in the files format and as one table in a reftable, where it wrote `packed-refs` in either, and `clone.Options.ref_format` (git's `--ref-format`) clones into a reftable repository. `refs.Store.list` keeps what is no ref apart in `Listing.broken` -- a name no ref may have, a file that holds no ref, an object name of zeros -- as git marks them broken, where a bad name in `packed-refs` failed the whole listing and a bad loose ref was dropped unseen; in a linked worktree it no longer lists the main worktree's `refs/bisect`, `refs/worktree` and `refs/rewritten`, and `%(worktreepath)` finds the main worktree's branch in a reftable repository. A transaction that cannot take a symbolic value no longer leaks it.
- The ref store owns the root refs and the special refs. `refs.Store.root()` writes, reads, lists and removes `ORIG_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `REBASE_HEAD`, `AUTO_MERGE`, `BISECT_HEAD`, `BISECT_EXPECTED_REV` and the notes merge refs (`refs.names.Root`) as themselves, never through a ref they name (git's `REF_NO_DEREF`), in either ref format; `refs.Store.special()` reads, replaces and appends to `FETCH_HEAD` and `MERGE_HEAD`, which stay files in either format, through their locks (`git fetch --append` reads and writes under one). `commit.head.writeRef`, `readRef`, `deleteRef` and `refExists` are removed, and `refs.reftablestack.initialize` takes no `orig_head`. `refs.Store.deleteRefs` is git's `refs_delete_refs`, and a transaction deletes a ref by any name git's `refname_is_safe` takes, so a ref with a bad name is removed by its name; `refs.Store.readOid` is git's `read_ref`. `main-worktree/<ref>` and `worktrees/<id>/<ref>` read another worktree's `HEAD`, root refs, per-worktree refs and their logs in either format, as git's do, and a transaction or a log write (`appendLog`, `createLog`, `expireLog`, `deleteLog`) refuses them (`error.OtherWorktreeRef`). Fixed with it: in a reftable repository `commit` refuses while a cherry-pick or a revert is stopped, and a rebase with `--update-refs` leaves alone a branch another worktree has checked out; writing `ORIG_HEAD` while it named a branch no longer moves the branch; `--include-root-refs` lists a reftable repository's root refs from its tables alone; a bisection tells `reference-transaction` of `BISECT_HEAD` and `BISECT_EXPECTED_REV`; `worktree.worktrees.add` writes no `ORIG_HEAD`, as `git worktree add --no-checkout` writes none.
- What a ref may be named is decided in one place, `refs.names`. `checkFormat` is git's `check_refname_format` with its `allow_onelevel` and `pattern` flags, held to `git check-ref-format` under every combination; `isSafe` is git's `refname_is_safe`; `isRootRef`, `isSpecial`, `isPerWorktree` and `parseWorktreeRef` classify names as git does. `worktree.safepath.checkRefName`, `safepath.isValidRefName` and `safepath.Reason.invalid_ref_name`, `transport.refspec.checkRefFormat` and `refspec.Format`, `refs.filter.isRootRef` and `refs.reftablestack.isSpecial` are removed: use `refs.names.checkFormat(name, .{ .allow_onelevel = true })`, `refs.names.isRootRef` and `refs.names.isSpecial`. A push to a repository on this machine refuses a ref of one level under `refs/` (`refs/funny`) with receive-pack's "funny refname", where it took it; a revision of one level spelled with a dash (`FOO-BAR`) resolves as git resolves it.
- One way to write a repository's configuration. `Repository.writeConfig(io, file, edits, diagnostic)` writes `.git/config` or the worktree's `config.worktree` (the shared file while `extensions.worktreeConfig` is off, as git falls back) as git's `repo_config_set_multivar_in_file_gently` does: the file read again under its lock and only `edits` applied, so another process's `git config` since open survives; the configuration it would leave checked whole before it lands (`ObjectFormatChanged`, `RefStorageChanged`, any setting `open` refuses), then published. It returns a `WriteOutcome` (`sections_removed`). `writeConfigFile` writes a file that is not the repository's own, a submodule's or the main worktree's `config.worktree`, with its permissions. `Config.write` is removed, and `Config.SetError` no longer carries lock or commit errors. `editConfig` takes the `Io` and `config.Sources.Pair` values, set in memory only over every file as later `-c` values are, kept through `refreshConfig` and every write and never written; a value for the repository's format is refused (`FormatEditInMemory`, which replaces `WorktreeConfigChanged`). Clone, a lazy fetch's filter, the promisor fields a server asks to store, what an LFS server teaches, submodule `init`, `sync`, `deinit` and `absorb`, sparse-checkout and `init` itself write through it: none renders a configuration read earlier over the file, none writes a memory-only value, and sparse-checkout leaves `configuration()` what the files say. `config.Sources.Path.contents` reads given bytes in place of a file, and `Config.withCommandValues` is a configuration with other `-c` values and nothing read again.
- A ref's log is the ref store's, in either format. `refs.reflog` is no longer public, and `Store.dirFor` is private: `Store.readLog`, `logExists` and `appendLog` read and write a log where the format keeps it, and the new `Store.createLog`, `expireLog` (git's `reflog expire` and `reflog delete`, with `--rewrite` and `--updateref`) and `deleteLog` start, prune and remove one. `refs.Log`, `LogEntry`, `LogPolicy` and `LogReadError` name what they return. `Store.appendLog` takes a `LogMessage` and logs only where its policy says, so `HEAD` moved under `core.logAllRefUpdates = false` gains its line in a reftable repository as in a files one. `Resolved.from_packed` says whether a resolved ref came from `packed-refs`. In a reftable repository the stash works: two pushes keep both, `stash list` reads git's list and git reads relic's, and `drop` rewrites the log as git's does, with no `reference-transaction` hook until the last stash takes `refs/stash` with it. A deleted ref's log goes with it whether or not the transaction logs anything, so fetch's prune and push's tracking deletes leave no log behind in a reftable stack.
- `relic.diff.textdiff` and `relic.merge.blobmerge` are gone; parallax is the line diff for anyone who wants one. `diff.Algorithm` and `merge.ConflictStyle`, `merge.Labels`, `merge.Resolve` and `merge.Level` are parallax's types; `merge.ConflictStyle.parse` is `merge.parseConflictStyle`. `merge.Favor` is `merge.Resolve` (`none` is `markers`, `union_` is `both`), and every `favor` option is `resolve`: `merge.BlobOptions`, `merge.strategy.Settings`, `merge.ort.Options`, `patch.apply.Options`, whose refusal is `ResolveWithoutThreeWay`. `BlobOptions.join_without_alnum` is `level` (`.zealous_alnum` for `git merge-file`'s). `diff.Options.context` and `max_work` are `u32`, and `diff.function_context_max` is gone. `diff.unifiedBody`, `unified`, `blobNumStat` and `numstat` return `error.InputTooLarge` (`diff.TextError`) for a side of 4 GiB or more, where they returned `error.OutOfMemory`.
- `relic.wildmatch` and `relic.worktree.wildmatch` are gone. Match with `sweep.match`: `.syntax = .git` for git's `pathname` flag and `.git_text` without it, `.case = .ascii_git` for `case_fold`.
- `lfs.Settings.fetch_include` and `fetch_exclude` hold `lfs.FetchPattern`s, which `Lfs.load` compiles (or `FetchPattern.compile`); `Settings.case_fold` and `lfs.patternMatches` are gone, the case being compiled into each pattern.
- `worktree.ignore.parseLine` takes an allocator and `LineOptions` and compiles the glob; `ignore.Pattern` and `attributes.Rule` carry it as `matcher`. An ignore line is read by git's grammar: a trailing tab stays part of the pattern, where it was trimmed, and a line ending in an escaped backslash and spaces loses every space, where one stayed.
- Pin conduit at confirmed per-child scope completion; callers releasing an unfinished contained `program.Child` use its fallible `release`.
- HTTP Streaming.finish consumes its connection on success and failure; callers abort only before finish, and smart HTTP and LFS transfer cleanup with the stream.
- HTTP connect, send and stream take a caller-owned Diagnostic as their last argument (or null), replacing Client.tls_error, proxy_status and proxy_offered; LFS and smart HTTP keep diagnostics with each exchange.
- `program.SpawnHook.start` receives an allocator and `conduit.Child.SpawnOptions`, returns `conduit.Child`, and reports its spawn errors; `terminate` receives that child too. `Running.child` uses conduit's stream accessors and ownership transfers. conduit links libc on POSIX through its module.
- Odb allocator, format, source, policy and storage fields are opaque state read through `allocator`, `objectFormat` and `settings`; repository configuration is borrowed through `configuration` and changed atomically through `editConfig`, with format/backend checks and ref policy publication shared with refresh; memory-only source changes return `WorktreeConfigChanged` and require a standalone write followed by refresh.
- `Odb.makeDurable` reports foreign hashes as `ObjectFormatMismatch`, distinct from an unexpected object type.
- `reftablestack.isReftableRepository` and `GitDir.refStore` preserve backend-probe I/O refusals; only absent paths select the files backend.
- `sequencer.signs` and persisted sequencer/rebase signing policy preserve configuration value and allocation errors instead of choosing unsigned writes.
- `Repository.requiredFilters` returns configuration value errors instead of treating malformed required policy as optional.
- `Odb.openAt` borrows its directory handle on success and failure; callers that transferred a handle must close their original.
- `CheckoutOptions`, snapshot `OpenOptions` and snapshot `Store` carry durability policy; callers depending on their layouts or constructing stores directly must migrate.
- Repository hash/ref fields and ref-store allocator/directory/backend/cache fields are opaque owner state accessed through `objectFormat`, `refStore`, `refFormat` and `reftableOptions`; ref-store construction is fallible and requires `deinit`, including `GitDir.refStore`, with backend selection at construction and write-policy changes through `configureReftable`.
- Caller-owned `repo.Diagnostic` includes `signing_stderr`, preserved after a failed commit or tag signing program; layout-dependent callers must review the new field.
- Commit, merge, sequencer and rebase options carry optional caller-owned write diagnostics; callers depending on their layouts must review the new field.
- `Repository.coreSettings` and `worktreeRules` return malformed-setting and resource failures; callers must handle their error unions.
- Repository commit and tag writes preserve `InvalidSignature` and `MixedHashKinds` in `WriteError` instead of reporting `UnexpectedObjectType`.
- Delta results over the size limit return `DeltaSizeLimitExceeded`; `DeltaSizeOverflow` means a size encoding wider than 64 bits.
- A refresh that changes the ref backend returns `RefStorageChanged`, requires reopening and keeps the old configuration and ref store.
- `refreshConfig`, `writeCommit`, `writeTag` and `writeTagWith` take caller-owned `repo.Diagnostic` output; the repository's `unsupported`, `unsupported_len` and `unsupportedSetting` are removed.
- Client.proxy_retry is removed; HTTP proxy retry decisions belong only to the connection attempt that accepted the challenge.
- The root is one module per concern, each holding the modules that belong to it, in place of 106 flat modules. The sixteen at the top are `repo`, `hash`, `object`, `odb`, `refs`, `config`, `index`, `worktree`, `wildmatch`, `diff`, `revwalk`, `merge`, `commit`, `transport`, `submodule` and `lfs`; the rest moved under them:

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

  So `relic.reflog` is `relic.refs.reflog`, `relic.fetch` is `relic.transport.fetch` and `relic.program` is `relic.repo.program`. The declarations inside each module are unchanged. `blobmerge`, `objectfilter` and `clientcert`, which the README listed and the root did not export, are now reachable.

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
- Reach HTTP(S) remotes and LFS through SOCKS4, SOCKS4a, SOCKS5 and SOCKS5h proxies, with local or proxy DNS, URL credentials and TLS inside the tunnel, as git does; honor `remote.<name>.proxy` and name SOCKS refusals. closes #1.
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

- The Smith fuzz tests are shakedown `check` properties: a plain `bay test` runs each on many seeded cases and shrinks a failure, and `bay test --fuzz` fuzzes the same bodies.
- The `http` build option (on by default) brings uplink, cloak and strand, which are now lazy: a program built with `.http = false` fetches none of them, and an `http` or `https` remote is `error.HttpUnavailable`, as is every Git LFS operation that needs them (opening an LFS server, its transfers and locks, a custom transfer agent, the lock cache); `smarthttp.connect` and `httpsettings.resolve` say so themselves. `bay check-consumer` builds a project with `.http = false` that names each of them.
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
- Pins conduit 0.6.0, sweep 0.2.0, parallax 0.2.0, uplink 0.2.0, airlock 0.2.0, warp 0.2.0, cloak 0.2.0 and strand 0.8.0; developed with preflight 0.2.2 and shakedown 0.2.0.

### Removed

- `repo.fs.macos_fsync_is_writeout_only`, a constant nothing read.

### Fixed

- On Linux a received pack's directory, and every directory `fs.syncDirectory` syncs, is synced with one call: each was opened `O_PATH`, which fsync refuses, so a sync was a refused call and a reopen.
- Applying a delta reserves the size its header states only up to what its commands could produce, each copy at most 16 MiB and no more than the base, so a delta of a few bytes whose header claims gigabytes is refused as `DeltaResultSizeMismatch` without reserving them first.
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
- Hostile remotes and servers cannot turn relic's transports against the person. A value handed to a credential helper that holds a newline, or a carriage return unless `credential.protectProtocol` is false, is refused with `error.CredentialValueUnsafe` (`credential.Error`), as git's `credential_write_item` refuses it, and a URL whose user, password, host or path holds a newline fills nothing — a redirect's `Location` included. Every transport is checked as git's `is_transport_allowed` checks it: `transport.policy` reads `GIT_ALLOW_PROTOCOL`, `protocol.<name>.allow`, `protocol.allow` and git's defaults (`file` and remote helpers only for the person, `ext` never), and `transport.Options.from_user`, with `clone`, `fetch` and `push` `Options.from_user`, says whether the person named the remote; the submodule transport passes false, so a `.gitmodules` cannot reach a repository on this machine unless `protocol.file.allow` says so. `remotehelper.allowed` and `remotehelper.Error.TransportNotAllowed` are gone: the error is `transport.Error`'s and `smarthttp.Error`'s. A smart HTTP redirect goes only to an allowed transport and, to another host or port, drops `Authorization` and `Cookie` from `http.extraHeader` as git drops them; `http.followRedirects` is read (`httpsettings.FollowRedirects`, `Settings.follow_redirects`), `false` following none. An LFS redirect to another host leaves the request's own `Authorization` behind, as git-lfs's does. A lock taken or given back changes the write bits of the path asked for, never of the path the server answered with; one given back by id touches the server's path only when it is a plain path inside the working tree. A refused credential is forgotten even when a helper cannot be told, and a cancellation while telling the helpers is no longer swallowed.
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

[Unreleased]: https://github.com/pedronaugusto/relic/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/pedronaugusto/relic/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/pedronaugusto/relic/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/pedronaugusto/relic/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/pedronaugusto/relic/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/pedronaugusto/relic/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/pedronaugusto/relic/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.1.0
