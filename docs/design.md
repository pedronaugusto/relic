# Relic design

Relic implements repository formats and operations as a Zig library. Architecture
phase 2 is in progress. Public namespaces publish concerns; implementation files
own state and import the implementations beneath them directly.

## Owners and layers

Hash and object representations underpin codecs and the object database. The
object database owns loose objects, packs, indexes and receipt of new objects.
Reference stores own reference transactions, reflogs and special files. The
index and checkout own staged entries, conversion and working-tree writes.
Walks, diffs, patches and merges build on these owners. Repository operations
compose them through an opaque Repository and its accessors.

Publishing facades expose the public vocabulary without executing operations or
owning mutable state. Production implementation imports point downward rather
than through publishing facades. Test fixtures live in testing modules and do not
create production dependencies upward. Stateful owners release their resources
through deinit. Public functions group policy and optional inputs in named options, with one
canonical operation instead of parallel With variants. Index.read is the
constructor exception: reading describes its creation operation. Index read options carry
a premeasured timestamp resolution when a repository already has one.
Tree, commit and ancestry inputs group the participating object names, keeping
operation policy in a separate options value. Public functions name error sets
and distinguish refusal from an empty successful result.

LFS owns its pointer format, object store, commands, transfer policy and lock
cache. Checkout accepts neutral native-filter providers and drivers; it does not
know LFS commands or storage. Clone and push accept neutral callbacks that upper
LFS composition supplies. A native filter session owns its resources and copies
configuration needed after the caller returns. Snapshot redirects object writes
through the same provider contract. Operation I/O is supplied by the caller. Cached native process buffers preserve
unconsumed bytes, but each exclusive stream borrow binds reads and writes to the
current operation. SSH holds its mutex through the request and answer; custom
adapters have one caller per conversation. Read/write failures and cancellation
return explicitly and never publish a partial lock cache.

## Publication and failure

Receiving a pack acquires an independently owned keep token before publication.
The receiver retains that token until all reference transaction work finishes,
including HEAD and FETCH_HEAD where applicable. Cleanup removes only the token
it owns. Cancellation cleanup releases it without cancellation interrupting the
release. Repacking preserves packs protected by another operation. A failed ref
transaction cannot expose refs to objects that collection has already removed.

Airlock owns atomic replacement and durability. Relic chooses the durability
policy and orders object publication before refs, and file synchronization before
parent-directory synchronization. Tests inject faults through the owning
package's published seams, including native filesystem synchronization.

LFS pagination treats an absent or empty cursor as termination. Each traversal
remembers every nonempty cursor and refuses a repeated or cyclic cursor. A failed
traversal returns an explicit error and preserves the previous lock cache; a
partial page sequence never becomes successful cached state.

## Parsing and matching

One bounded expression parser and execution core supports boolean and search
adapters. Adapters choose newline policy while sharing syntax and matching
semantics. Parsing, program size and execution work are bounded so adversarial
patterns fail explicitly. Common small programs use bounded stack scratch;
larger programs allocate checked owned scratch.

Each ignore, attribute and sparse rule level owns one Sweep Set and its cache.
Results preserve rule order and negation. Matching a level collects matching
indices under that level's lock. This makes matching proportional to candidates
rather than scanning every pattern, while small levels still pay construction
and cache costs. Long includeIf patterns use checked sizing and an allocated
fallback instead of truncating bounded scratch. Shared pathspec consumers and
line-diff parsing use one grammar each.

Warp owns the adopted checksum implementation. Remaining codec and hunk-grammar
adoption must use published dependency APIs; Relic does not copy dependency
implementations or publish compatibility wrappers. Conduit owns child termination
states. Allocation contracts exercise lifecycle failures using Shakedown's
NoResize allocator.

## Cost and validation

Received pack protection uses one token per publication and a bounded lifetime,
so collection safety does not require retaining all historical packs. Cursor
history costs space proportional to pages and guarantees cycle detection.
Expression work limits bound worst-case matching independently of input intent.
Native process buffers are allocated once. An exclusive stream borrow changes
two I/O bindings without allocating; round-trip benchmarks keep startup outside
the measured operation and validate the returned bytes. Rule sets trade per-level
construction and cache memory for cheaper repeated
queries; both construction and matching are benchmarked.

Contract tests exercise publication failure, cancellation, pagination, parser
semantics, ownership and allocation failures. Benchmarks live in bench and compile
in CI; timing is measured separately in ReleaseFast with interleaved comparisons
against the previous main. CI owns platform and complete-suite verification.

Working-tree merges group the index with their tree or commit inputs; the
index remains borrowed and the caller owns publication. Reset groups its target
index/tree and overwrite policy in Options. Neither operation moves HEAD;
sequencer.resetMerge owns HEAD/ORIG_HEAD publication and its ResetOptions carry
the ref identity and optional refusal diagnostics. The same merge and reset
engines preserve unrelated working-tree edits and refuse destructive overwrites.

Unified diff borrows its object database and one Change through UnifiedInputs,
then receives the output writer and formatting options. Blame identifies a file
with Inputs (commit and path); patch-id tree comparisons use the same TreeInputs
as diff.tree. These input groups leave formatting and attribution policy in
the existing engines and preserve the writer-before-options call order.

Pack storage operations group borrowed input identities and policy separately
from output writers. Writer.open owns file handles until deinit(io); a nullable
OpenInputs count selects header patching at finish, while openStream requires a
known count before output begins. Index/reverse-index options retain the same
checksums, entry order and durability policy. Indexpack Inputs borrow the receive
directory and input reader; Result still owns its keep token through publication.

Merge strategy aliases change only the selected algorithm; an existing minimal
policy survives bare patience/histogram. The shared algorithm grammar still
replaces both fields for diff-algorithm= and configured values. Durability tests
count logical directory barriers exactly, accounting for Airlock's Linux O_PATH
EBADF/reopen recovery through its published getfl and sync_dir seam calls.

Local receivePush owns the copied pack's keep token before publication and
retains it through every atomic or per-ref transaction and shallow update.
Transaction cleanup precedes token release on success, failure and cancellation;
cancellation remains an operation error rather than a successful refusal report.
Concurrent Git collection cannot remove the received object closure before refs
make it reachable. Tokens own their directory handle independently of the writer.
