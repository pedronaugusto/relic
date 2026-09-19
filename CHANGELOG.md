# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Packs are written.** `pack.Writer` takes objects one at a time and streams
  them into a temporary; `finish` writes the `.idx` beside it and renames both
  into place under the name the pack's own trailing checksum gives them, which
  is what git names a pack after. All three entry kinds: a whole object, an
  offset delta against an entry already in the pack, and a reference delta
  against a name that need not be. The index is version 2 throughout —
  fanout, sorted names, a CRC per entry, the 64-bit offset table — and the
  hash is the repository's, so a SHA-256 repository gets a SHA-256 pack. What
  is held is one object, the deflate state, and twenty-eight bytes per object
  for the index; nothing is threaded.

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
  84 871, and git's own packer makes 28 557 of it.

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

- **Breaking: `fs.Stat.matches` takes a fourth argument**, the resolution.
  `worktree.Rules` carries it and `Repository.worktreeRules` fills it in from
  what the object database measured, so a caller going through the front door
  passes nothing new.

- **Breaking: `odb.Error` grew.** Writing a pack can fail in ways reading one
  cannot — `ObjectCountMismatch`, `TooManyObjects`, `DeltaBaseNotWritten`,
  `DuplicateObject` — and enumerating objects parses commits, tags and trees,
  so `object.ParseError` and `object.TreeParseError` are in it now too.
  Breaking for a caller that switches exhaustively on it; nothing returns any
  of them unless a pack is being written or a set of objects collected.

- **Breaking: `worktree.Rules` gained `timestamp_resolution`** and
  `odb.Options` gained `probe_timestamp_resolution`. Both default to the
  behaviour that was there before measuring was possible.

## [0.1.0] - 2026-09-19

The first release. It reads and writes a repository the way git leaves one on
the disk: objects loose and packed, refs loose and packed, the index at
versions 2, 3 and 4, the working tree, and diffs.

### Added

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

- **Sixteen fuzz tests**, one per parser, built and run by `zig build test
  --fuzz` and keeping a corpus each under `.zig-cache/f`. Zig 0.16.0's
  fuzzing test runner hands `@errorReturnTrace()`'s
  `std.builtin.StackTrace` to a function taking `std.debug.StackTrace`, two
  structs of the same shape and different identity, which is one compile
  error per fuzz test; the test module sets `error_tracing = false`, which
  takes the trace out of the runner's path. What that costs is the return
  trace under a failing test — the error and the test's name are still
  printed.

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

- **`EOIE` and `IEOT` are dropped rather than preserved.** Both are caches of
  byte offsets into the file being rewritten, so copying one points it at the
  wrong place. git rebuilds them.

- **A split index is read whole and written back as one complete index.** No
  entry is lost; the split is not recreated, and git re-splits on its next
  write if the setting is still on.

- **Commit-graph generation numbers are read only in their second form.**
  Version one stores topological levels, which are a different quantity with
  the same name.

- **`working-tree-encoding` and a required filter are refusals, with the
  value.** Passing the bytes through would write a blob git would not write.

[0.1.0]: https://github.com/pedronaugusto/relic/releases/tag/v0.1.0
