# relic

[![CI](https://github.com/pedronaugusto/relic/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/relic/actions/workflows/ci.yml)

A git repository, read and written from Zig. Objects, packs, refs, the index,
the working tree and diffs, laid down the way git lays them down, so that git
reads back everything written and a program that needs a repository does not
need the `git` binary on its path.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs; `ci/readme_usage.sh` extracts it
and CI compares the two.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
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
var rules = repo.worktreeRules();
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
});

// Move the branch and write the reflog, both or neither.
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

## Install

```
zig fetch --save git+https://github.com/pedronaugusto/relic
```

```zig
const relic_dep = b.dependency("relic", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("relic", relic_dep.module("relic"));
```

One module and no dependencies: zlib comes from `std.compress.flate`, SHA-256
from `std.crypto`, and SHA-1 is in the package, so there is nothing to link and
no build option to forward. Every function that allocates takes the allocator
as its first argument and every function that touches the disk takes a
`std.Io`; the package starts no threads, spawns no process, and never reads a
clock — the caller passes the time and the identity. One word outlives a call
without a caller holding it, and it is the answer to which SHA-1 instructions
this processor has, asked once.

## The API

| Module | |
|---|---|
| `hash` | `Kind` (`sha1`, `sha256`), `Oid`, `Hasher`. The hash is a parameter from the first line, not a width bolted on later. |
| `sha1` | SHA-1 over the processor's own instructions, with the eighty rounds as the fallback and the choice made at run time. |
| `sha1dc` | SHA-1 that checks each block for the signature of a collision attack. Off unless asked for. |
| `object` | `Type`, `Mode`, `Tree` and `Tree.Builder`, `Commit`, `Tag`, `Signature`, `ExtraHeader`. Parsing and writing, with git's tree sort rule and header order. |
| `pack` | `Index` (`.idx` v2), `Pack`, `Cache`. Both delta kinds, the 64-bit offset table, a bounded chain, and `verify`. |
| `delta` | `apply`, with the copy and insert opcodes. |
| `odb` | `Odb.open`, `read`, `readHeader`, `exists`, `findPrefix`, `write`, `writeStream`, `listObjects`, `verify`, `refresh`, `syncBatch`, `stats`. Loose objects, the packs, `objects/info/alternates` and the multi-pack index. |
| `index` | `Index.read` / `write` / `toBytes`, `Entry`, `CacheTree`, `ResolveUndo`, `RawExtension`. Versions 2, 3 and 4. |
| `refs` | `Store`, `Ref`, `Resolved`, `Transaction`, `Expected`, `packed-refs` read and write. |
| `reflog` | `append`, `read`, `Log.at` for `HEAD@{n}`, `Policy` for `core.logAllRefUpdates`. |
| `config` | `Config.open`, `get`, `all`, `getBool`, `getInt`, `getPath`, `subsections`, `origin`, `set`, `unset`, `write`. Lossless: setting a value rewrites one line. |
| `ignore` | `Rules.load` / `addDirectory` / `match` / `matchPath`, with the pattern that decided. |
| `attributes` | `Attrs`, `Attributes`, `unsupported`, `toGit`, `toWorktree`, `isBinaryForDiff`, `isBinaryForCheckIn`. |
| `wildmatch` | `match` — git's own glob, which is not `fnmatch`. |
| `worktree` | `addAll`, `writeTree`, `checkout`, `resetIndex`, `status`, `list`, `applySparse`. |
| `worktrees` | `list`, `add`, `remove`, `prune`, `lock`, `unlock`, `move`, `repair`. |
| `sparse` | `Patterns` for `info/sparse-checkout`. |
| `diff` | `tree`, `numstat`, `blobNumStat`, `unified`, `unifiedBody`, `isBinary`, rename and copy detection. |
| `textdiff` | `diffLines`, `hunks`, `stat`, `similarity`, `Algorithm` (`myers`, `histogram`). |
| `revwalk` | `Walk`, `mergeBase`, `mergeBases`, `isAncestor`. |
| `merge` | `trees` — a three-way tree merge producing index stages 1 to 3. |
| `commitgraph`, `midx` | The two accelerators, read. A `revwalk.Walk` takes parents and times from a commit-graph when it is given one and reads the object when it is not; a lookup asks a multi-pack index which pack to open before it asks the packs one by one. Neither changes an answer. |
| `safepath` | What a path from a tree is allowed to be, and what a ref may be named. |
| `repo` | `Repository.open`, `init`, `openIndex`, `head`, `headTree`, `writeCommit`, `writeTag`, `peel`, `beginRefs`, `loadIgnore`, `loadAttrs`, `listWorktrees`, `pruneWorktrees`. |

Every public declaration carries a doc comment stating its contract, and every
operation has one named error set. A refusal is always a named error carrying
the setting that caused it.

## Design

### Exactness

What is written is what git reads: the index's bytes, a tree's entry order, a
commit's header order, a ref file's trailing newline, `packed-refs`' header
space. The suite proves it in both directions — an index git wrote is read and
written back byte for byte, and a tree this writes is the tree `git
write-tree` writes over the same files.

One stated exception: a loose object's *compressed* bytes need not match
git's. An object's name is the hash of its uncompressed content and git never
compares the compressed form. Objects are deflated at level 1, which is what
`core.looseCompression` defaults to.

### Line endings

`text`, `text=auto`, `eol` and `core.autocrlf` decide whether a blob is stored
with its carriage returns removed, and therefore decide its name and the name
of every tree above it. Two different rules call a file binary and both are
here: a NUL in the first 8000 bytes decides whether a *diff* is printed, and a
lone carriage return, a NUL, or fewer than one printable byte per 128
non-printable ones decides whether a file is *normalised on check-in*. The
second is the one conversion asks.

Two settings would make this store a blob git would not: `working-tree-encoding`,
and a `filter` whose `filter.<name>.required` is true. Both are refused by
name, with the value handed back, because running a filter means running a
program.

### Locking

Every replacement goes through the file git would lock: `O_CREAT|O_EXCL` on
`<file>.lock`, write, make durable, rename. No advisory lock is taken, because
git takes none and a lock that is not git's lock does not stop it. A reader
never blocks and sees either the whole old file or the whole new one.

A lock another writer holds is `error.LockHeld` and is left exactly where it
was found. `fs.staleReport` says whether it is held, which process id is in
`<file>~pid.lock`, and whether that process still exists — process ids are
reused, so that is a report for a person and not permission to remove
anything. `fs.OnContention` chooses between failing at once and waiting with
git's own backoff.

On a miss, the object database re-scans the pack directory once and tries
again, because a `git gc` may have packed the object away between the two.

A repository with many packs has one binary search per pack on every lookup
unless something narrows it, and `pack/multi-pack-index` is what git writes to
narrow it. It is read at open and consulted first: it says which pack holds
the object, and that pack's own index is still what gives the offset. Doing it
the other way round would turn a stale index into a read at a wrong offset
rather than a miss. An index that does not parse, or that names a pack this
database has not opened, is a miss and the packs are asked in turn.
`Odb.stats` counts both, so a caller can see which happened.

### Durability

`fs.Sync` is a policy with three values, and the default is git's own: `none`
makes neither a loose object nor the index durable before returning, which is
what `core.fsync` defaults to. `batch` flushes each file and puts one real
barrier at the end — a throwaway file in the same directory, synced and
removed — which is full durability at one sync per batch rather than one per
object. `per_file` syncs each one.

A lock's own descriptor is synced before the rename under both of the latter
two, which is the step that prevents an empty ref or a truncated index.
Directory entries are not made durable unless asked: git does not do it
either, and the guarantee it adds is one git does not make. On macOS
`fsync(2)` reaches the device and not the drive's own cache; `F_FULLFSYNC` is
the real barrier and costs about thirty times as much per call, which is why
it belongs at the end of a batch rather than on every object.

### Paths

A tree entry's name is written by whoever wrote the tree and becomes a
filesystem path on checkout, so every path is checked first, on every
platform. Refused: `.` and `..`; `.git` in any case, including the NTFS short
name `git~1` and any alternate-data-stream spelling such as `.git:`; DOS
device names with or without an extension; a component ending in a dot or a
space; a backslash inside a name; an absolute path or a drive letter. A ref
name ending in `.lock` is refused too, since that is the name of the file
that blocks every update to the ref without it.

### Speed

The measurements below are from `zig build test -Doptimize=ReleaseFast` on an
Apple M3 Max; the same test runs in CI with a budget, so a regression is a red
build. Three thousand files over sixty directories:

| | |
|---|---|
| `addAll`, nothing staged yet | 450 ms |
| `addAll`, nothing changed | 10 ms |
| `writeTree`, cache tree invalid | 10 ms |
| `writeTree`, cache tree valid | under a millisecond |
| `status`, one file in ten changed | 12 ms |

The warm numbers are what the stat shortcut and the `TREE` extension are for:
an entry whose recorded stat still matches is neither opened nor hashed, and a
cache-tree node that is still valid is used as it stands.

The cold number is three thousand loose objects written, which is a directory
made, a temporary file created, deflated, closed and renamed, once each.
Naming those files is under a millisecond of it, so it did not move when the
hash got faster and it is not the number to read the hash by.

The hash is the floor under a repository whose files have size. Both
architectures carry SHA-1 instructions, and this package uses them: aarch64's
`sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0` and `sha1su1`, x86-64's
`sha1rnds4`, `sha1nexte`, `sha1msg1` and `sha1msg2`. Over 64 MiB on the same
machine:

| | |
|---|---|
| SHA-1, the eighty rounds in software | 1.01 GiB/s |
| SHA-1, the aarch64 instructions | 2.56 GiB/s |
| SHA-1, with the collision check | 0.41 GiB/s |
| SHA-256, from the standard library | 2.30 GiB/s |

Which arm runs is decided by asking the processor and not by what the compiler
was told, so a binary built for a baseline target uses the instructions on a
machine that has them. Both arms assemble on a baseline target, so the choice
is never taken away at build time. The benchmark's budget is a ratio against
the software rounds timed in the same run, which is what makes it survive a
runner under load and still fail if the hardware arm is lost.

The aarch64 arm is what the number above was measured on. The x86-64 arm is
checked against the software rounds under emulation, on every length to eight
kilobytes; it has not been timed on that hardware. Both are written as
assembly, which the self-hosted x86-64 code generator has no encoding for, so
a Debug x86-64 build takes the software rounds and an optimised one takes the
instructions.

Packs are read with positional reads by default. `Odb.Options.map_packs` asks
for a memory map instead, which is faster on a cold cache and costs two
things: on macOS a pack replaced underneath a mapping is a signal rather than
an error value, and on Windows a live mapping stops the `gc` that wants to
replace the file.

### Collision detection

A SHA-1 collision is public and buildable, so two different objects can be
made to carry one name. `Odb.Options.detect_sha1_collisions`, which
`Repository.open` and `Repository.init` both forward, turns on the check the
counter-cryptanalysis paper describes: the identical-prefix attacks all follow
one of thirty-two known disturbance vectors, and a block that could have come
from such a pair is recognisable from the block alone. Per block it is a few
dozen masked comparisons that reject nearly everything; a block that survives
them has its sibling message reconstructed and the compression function re-run
from the step the vector is anchored at.

It is off, and there are three things to know before turning it on. It costs
about six times the hash, because the method needs the expanded message and the
intermediate states, which the processor's SHA-1 instructions do not hand back.
It reports rather than repairs: `error.CollisionAttack`, with nothing written,
rather than a quietly different name. And what it guards is git's object
format rather than a file on the disk — the published colliding documents are
not colliding *objects*, because `"blob <size>\0"` goes in front of the
content and moves every block of the message, so git stores both of them
today under two names. The check is there for an attack mounted at the object
and not at the document.

The disturbance-vector table and the bit conditions are transcribed from the
reference implementation, and the transcription is checked two ways: the
published colliding pair is detected, both halves, and no object in any
fixture repository is.

### Memory

Each public operation runs on an arena fed from the caller's allocator, so the
peak is bounded by the operation and the free is one call. Two things outlive
an operation and both are named in `Odb.Options`: the pack indexes, which are
read whole at open so a lookup costs no syscall, and the delta base cache,
which is a direct-mapped table on the pack offset with a byte budget. There is
no object cache; a returned slice's doc comment says who owns it.

### The index

Versions 2, 3 and 4 are read; version 2 or 3 is written, 3 only when an entry
needs an extended flag, and 4 on request. The `TREE` and `REUC` extensions are
understood. An extension whose signature begins with an upper-case letter is
optional and is kept byte for byte and written back; a lower-case one is
mandatory and is either understood or a named refusal, because quietly
dissolving one loses entries.

`link` — the split index — is understood: both of its bitmaps are decoded and
the shared file is merged, so nothing is invisible. What is written back is one
complete index rather than a split one, and git re-splits it on its next write
if `core.splitIndex` is still set.

`EOIE` and `IEOT` are dropped rather than copied. Both are caches of byte
offsets into the very file being rewritten, and copying one into a file whose
entries have moved points it at the wrong place. git reads an index without
them and rebuilds them itself.

git's racy rule is implemented: an entry whose modification time is not older
than the index file's own is content-checked rather than trusted, and a
racily-clean entry's recorded size is written as zero so the mismatch survives
into the next index. A file rewritten inside one second without changing size
is noticed, and there is a test that makes exactly that on the disk.

`dev`, `uid` and `gid` come from the platform where it reports them. Writing
zeros there is what makes the next `git status` treat every entry as needing a
refresh and re-hash the whole working tree.

## Scope

- **No network.** A repository is a local directory; fetch, push and clone are
  a wire protocol and a different discipline.
- **No pack writing.** Loose objects that a later `git gc` packs are correct
  and complete.
- **No hooks are run.** A hook is arbitrary code chosen by whoever last wrote
  to the repository; the caller has the path and may run it.
- **No named clean or smudge filters.** A filter is a shell command, and a
  repository whose attributes require one is refused with the filter's name.
- **No content-level merge.** The three-way merge is at tree level and leaves
  a conflict at index stages 1 to 3, which is where git leaves one too.
- **No reftable, no sparse index.** Both are detected and refused by name
  rather than misread.

## Platforms

| Platform | Notes | Tested where |
|---|---|---|
| Linux | Executable bit, symlinks, `statx` for the index's `dev`, `uid` and `gid` | `test (ubuntu-latest)`, and `ci/linux.sh` in Docker from any machine |
| macOS | The same, through `fstatat`; `fsync` is writeout-only, which is git's own default here | `test (macos-latest)` |
| Windows | No executable bit and no `dev`, `uid` or `gid`, so the index's mode is preserved rather than invented and those three are zero; symlinks may be refused, in which case the link target is written as file content and the outcome says so; renames retry on a sharing violation; directory entries are the operating system's | `test (windows-latest)` |

Paths in trees and in the index are always `/`-separated byte strings; the
working-tree layer converts. `core.ignoreCase` is honoured in matching, and a
tree carrying two entries that differ only in case is refused on a filesystem
that folds case rather than having one silently overwrite the other.

`zig build check -Dtarget=…` compiles everything, tests included, without
running it. CI does that for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`.

## Testing

```
zig build test          # the suite, and the examples, which are run
zig build examples      # the examples on their own
zig build check         # compile everything, including the tests, run nothing
zig build test --fuzz   # the fuzz tests, without a time limit
zig fmt --check src examples build.zig build.zig.zon
ci/linux.sh             # the suite on Linux, in Docker, from any machine
```

Every test runs under `std.testing.allocator` and `std.testing.io`, against
real directories, in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall. The
benchmark is the one exception and says why in its own file: it allocates from
a production allocator, because the testing allocator's bookkeeping costs
several times the work it is measuring.

**The fixtures are generated by the git on the machine at test time**, in a
temporary directory, and compared byte for byte where the format is exact.
Because they come from git rather than from a file in this repository, a
format change arrives as a red build rather than as a silent divergence. A
machine with no git skips those tests instead of failing them. What is
compared: an index at each version read and written back; a repacked
repository walked against `cat-file --batch-all-objects`, once with offset
deltas, once with reference deltas, and once under SHA-256; `addAll` and
`writeTree` against `add -A` and `write-tree`, including under
`core.autocrlf` with `* text=auto`; `status` against `status --porcelain`;
`list` against `ls-files`; name-status, numstat and the unified patch at four
context widths against `diff-tree` and `diff`; `worktree list` before and
after an add, a lock, a prune and a remove; and `git fsck` silent about
everything written.

Concurrency is tested rather than hoped for. A second process takes
`index.lock` exactly as a running git does; the same test shows git refusing
that lock, and this refusing it by name and leaving it alone. A stale lock is
reported with its process id and never removed. A `gc` packs the objects under
a reader's feet and every one of them still reads back.

Fifteen fuzz tests cover every parser: the loose object header, a tree, a
commit, a tag, an identity line, a mode, the pack index, a delta, the index
file, `packed-refs`, the reflog, the config file, `.gitignore`,
`.gitattributes`, the glob matcher, the commit-graph, the multi-pack index and
the EWAH bitmaps. The rule is that any input either parses to a value or
returns a named error. The diff fuzzer additionally applies the edit script it
produced and checks that it reproduces the other side, which is the property
that catches an off-by-one nothing else would.

Two pack shapes cannot be made with `git repack`, so the suite writes the
packs itself: two reference deltas naming each other, and a chain a thousand
deep. The first is a named error and the second resolves without recursing.

## Requirements

Zig 0.16.0. A `git` on the path for the fixture tests, which are skipped
without one.

## License

MIT. See [LICENSE](LICENSE).
