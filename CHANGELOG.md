# Changelog

Each entry says what the shape could not express before, so a port has the
reason and not only the diff. Versions follow
[semantic versioning](https://semver.org); before 1.0 the minor is the
breaking one.

## Unreleased

### Added

- **`sha1`** — SHA-1 over the instructions the processor has for it: aarch64's
  `sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0` and `sha1su1`, x86-64's
  `sha1rnds4`, `sha1nexte`, `sha1msg1` and `sha1msg2`, with the eighty rounds
  written out as the fallback. Measured over 64 MiB on an Apple M3 Max: 1.01
  GiB/s before, 2.56 GiB/s after, which puts SHA-1 past the standard library's
  hardware SHA-256 at 2.30 GiB/s rather than 2.3 times behind it.

  Two decisions are worth the reason. **The arm is chosen by asking the
  processor rather than by what the compiler was told**, because a package
  built for a baseline target is the normal case and a compile-time gate would
  hand every such build the slow path on a machine that has the instructions.
  **Both arms assemble on a baseline target** — aarch64 through
  `.arch_extension crypto` in the assembly itself, x86-64 because its
  assembler does not gate these — so nothing has to be added to a consumer's
  build graph for the choice to exist.

  Both arms are assembly, which the self-hosted x86-64 code generator has no
  encoding for; a build that uses it — a Debug x86-64 build, in practice —
  takes the software rounds rather than failing to compile.

  `hash.Hasher` is unchanged in shape; `hash.Hasher.sha1Backend()` says which
  arm a measurement was taken on.

- **`sha1dc`** — SHA-1 with collision detection, as an arm of `hash.Hasher`
  and an option on the object database. `Odb.Options.detect_sha1_collisions`,
  which both `Repository.open` and `Repository.init` forward, makes every
  SHA-1 name the database takes carry the check; bytes that look like half of
  a near-collision pair are `error.CollisionAttack` with nothing written.

  Off, for three reasons that belong together. It costs about six times the
  hash, because the method needs the expanded message and the intermediate
  states and so cannot use the processor's SHA-1 instructions. It reports
  rather than repairs, so a caller gets a named error instead of a name
  nothing else in the world agrees with. And what it guards is git's object
  format: the published colliding documents are not colliding objects, since
  `"blob <size>\0"` goes in front of the content and moves every block, which
  is why git stores both of them today under two names.

  The table and the bit conditions are transcribed from the published
  reference. Checked both directions: the published pair is detected, both
  halves and across every split of the feed, and nothing in the fixture
  repositories — text, a deltified file, a binary blob — is flagged.

- **The multi-pack index is wired into lookup.** It was read and consulted by
  nothing; now `read`, `readHeader` and `exists` ask it which pack holds an
  object before asking the packs one at a time. It is read at open and
  re-read on every pack scan, because a `gc` replaces it along with the packs
  it names.

  It says which pack, and that pack's own index still gives the offset.
  Trusting the offset would make a stale index a read at a wrong position
  rather than a miss, and the two-step costs one binary search against the
  one per pack it replaces. An index that does not parse, or that names a
  pack this database has not opened, is a miss.

- **`Odb.stats`** — `midx_hits` and `pack_scans`, counting how lookups
  resolved. Nothing in the package reads them.

- **`Odb.multiPackIndexCount`** — how many of the database's object
  directories have one.

### Changed

- **`zig build test --fuzz` builds and runs.** It did not: the fuzzing test
  runner on 0.16.0 hands `@errorReturnTrace()`'s `std.builtin.StackTrace` to a
  function taking `std.debug.StackTrace`, two structs of the same shape and
  different identity, which is one compile error per fuzz test. The test
  module now sets `error_tracing = false`, which takes the trace out of the
  runner's path. What it costs is the return trace under a failing test; the
  error and the test's name are still printed. Sixteen fuzz tests build, run
  until stopped, and keep a corpus each under `.zig-cache/f`.

- **`hash.Hasher`'s SHA-1 is this package's rather than the standard
  library's.** The digest is the same digest — the suite checks it against
  `std.crypto.hash.Sha1` on every length from zero to four kilobytes, on
  several large inputs, and against the object names in the git-generated
  fixtures — so nothing a caller stored changes.

## 0.1.0

The first release. It reads and writes a repository the way git leaves one on
the disk: objects loose and packed, refs loose and packed, the index at
versions 2, 3 and 4, the working tree, and diffs.

What is here:

- **`hash`** — `Kind` is `sha1` or `sha256` and `Oid` carries it, so nothing
  assumes twenty bytes and a name from one repository cannot be compared with
  a name from another by accident.
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
  is git's own default for them.
- **`index`** — versions 2, 3 and 4 read; 2 or 3 written by default and 4 on
  request. `TREE` and `REUC` are understood; an unknown optional extension is
  kept byte for byte and written back; an unknown mandatory one is a named
  refusal. git's racy rule is implemented, including writing a racily-clean
  entry's size as zero.
- **`config`** — read with `include.path` and `includeIf` (`gitdir`,
  `gitdir/i`, `onbranch`), and written losslessly: setting one value rewrites
  one line and every comment stays where its author put it.
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

Decisions worth knowing before reading the source:

- **A loose object's compressed bytes need not match git's.** An object's name
  is the hash of its uncompressed content and git never compares the
  compressed form.
- **Durability is a policy rather than a constant.** `fs.Sync` defaults to
  what git defaults to, which makes neither a loose object nor the index
  durable before returning; `batch` gives full durability for one barrier per
  batch. Directory entries are not synced unless asked, because git does not
  sync them either.
- **Packs are read positionally by default.** A memory map is faster on a cold
  cache and turns an IO error into a signal on macOS and a lock on the file
  on Windows; `Odb.Options.map_packs` opts in.
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
- **SHA-1 collision detection is not here.** Its method is a table of
  cryptanalytic disturbance vectors; a mistranscribed one is a check that
  silently passes, which is worse than the plain hash. `hash.Hasher` is the
  seam, and a measured 2.3× gap between the standard library's SHA-1 and its
  SHA-256 is the thing to close first.
