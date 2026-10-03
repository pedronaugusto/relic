//! gitoxide's side of the operation workloads (`src/ops.zig` is relic's).
//!
//! Each workload is the `gix` API a caller would reach for. An operation
//! `gix` 0.87 has no API for is reported unavailable with the reason, rather
//! than assembled from plumbing.

use std::collections::BTreeSet;
use std::sync::atomic::AtomicBool;

use gix::bstr::{BStr, ByteSlice};

use crate::{emit, BenchmarkInstant};

const HOT: &str = "d00/d00/f0000.txt";

fn smoke() -> bool {
    std::env::var("BENCH_SMOKE").as_deref() == Ok("1")
}

fn reps() -> usize {
    if smoke() { 1 } else { 3 }
}

fn ms(start: &BenchmarkInstant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

fn count(workload: &str, metric: &str, value: usize) {
    emit(workload, metric, value as f64, "count");
}

fn oid(workload: &str, metric: &str, id: impl std::fmt::Display) {
    println!("gix\t{workload}\t{metric}\t{id}\toid");
}

fn unavailable(workload: &str, reason: &str) {
    println!("gix\t{workload}\ttime\tunavailable\tms");
    println!("gix\t{workload}\treason\t{reason}\ttext");
}

fn id(repo: &gix::Repository, spec: &str) -> gix::ObjectId {
    repo.rev_parse_single(spec).unwrap().detach()
}

fn tree_of<'r>(repo: &'r gix::Repository, spec: &str) -> gix::Tree<'r> {
    repo.find_commit(id(repo, spec)).unwrap().tree().unwrap()
}

/// Run `workload`, or return false when it is not an operation workload.
pub fn run(workload: &str, path: &str, extra: Option<&str>) -> bool {
    match workload {
        "diff-tree" => diff_tree(workload, path, "refs/tags/fork", "refs/heads/main", false),
        "diff-renames" => diff_tree(workload, path, "refs/heads/main", "refs/heads/renamed", true),
        "diff-patch" => diff_patch(workload, path),
        "diff-index" => diff_index(workload, path),
        "log" => log(workload, path),
        "log-path" => log_path(workload, path),
        "blame" => blame(workload, path),
        "revparse" => revparse(workload, path, extra.expect("expressions")),
        "merge-base" => merge_base(workload, path),
        "merge-tree-clean" => merge_tree(workload, path, "side"),
        "merge-tree-conflict" => merge_tree(workload, path, "conflict"),
        "branch-create" => branch_create(workload, path),
        "tag-create" => tag_create(workload, path),
        "ref-list" => ref_list(workload, path),
        "verify" => verify(workload, path),
        "submodule-status" => submodule_status(workload, path),
        "patch-id" => unavailable(workload, "gix has no patch-id"),
        "merge-clean" | "merge-conflict" => unavailable(workload, "gix merges trees in memory only; nothing merges into the index and working tree"),
        "rebase" => unavailable(workload, "gix has no rebase"),
        "cherry-pick" => unavailable(workload, "gix has no cherry-pick"),
        "revert" => unavailable(workload, "gix has no revert"),
        "commit" => unavailable(workload, "gix has no tree from an index, so no commit of the staged changes"),
        "switch" => unavailable(workload, "gix checks out into an empty directory only; it has no branch switch"),
        "stash" => unavailable(workload, "gix has no stash"),
        "repack" => unavailable(workload, "gix has no repack"),
        "worktree-add" => unavailable(workload, "gix has no linked-worktree creation"),
        "lfs-add" | "lfs-checkout" => unavailable(workload, "gix has no LFS"),
        "submodule-update" => unavailable(workload, "gix has no submodule update"),
        "snapshot" => unavailable(workload, "gix has no working-tree snapshot (stash create)"),
        "shortlog" => unavailable(workload, "gix has no shortlog"),
        "describe" => unavailable(workload, "gix's describe takes no --match pattern"),
        "notes-add" => unavailable(workload, "gix has no notes"),
        "bundle-create" | "bundle-unbundle" => unavailable(workload, "gix has no bundles"),
        "bisect" => unavailable(workload, "gix has no bisect"),
        _ => return false,
    }
    true
}

fn diff_tree(w: &str, path: &str, old: &str, new: &str, renames: bool) {
    let mut best = f64::MAX;
    let mut counts = [0usize; 5];
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        let (a, b) = (tree_of(&repo, old), tree_of(&repo, new));
        // git's diff.renameLimit of 1000 bounds sources times destinations
        // by its square; gix compares the product with the limit itself, so
        // its default of 1000 gives up where git and relic search.
        let rewrites = gix::diff::Rewrites { limit: 1000 * 1000, ..Default::default() };
        let options = gix::diff::Options::default().with_rewrites(if renames { Some(rewrites) } else { None });
        let changes = repo.diff_tree_to_tree(&a, &b, Some(options)).unwrap();
        best = best.min(ms(&start));
        counts = [0; 5];
        for change in &changes {
            use gix::object::tree::diff::ChangeDetached as C;
            // Trees themselves are not paths a recursive diff reports.
            if change.entry_mode().is_tree() {
                continue;
            }
            counts[0] += 1;
            match change {
                C::Addition { .. } => counts[1] += 1,
                C::Deletion { .. } => counts[2] += 1,
                C::Modification { .. } => counts[3] += 1,
                C::Rewrite { .. } => counts[4] += 1,
            }
        }
    }
    emit(w, "time", best, "ms");
    for (metric, value) in ["changes", "added", "deleted", "modified", "renamed"].iter().zip(counts) {
        count(w, metric, value);
    }
}

/// Lines added and removed between two blobs, by gix's own line diff.
fn line_counts(old: &[u8], new: &[u8]) -> (usize, usize) {
    use gix::diff::blob::{Algorithm, Diff, InternedInput};
    let input = InternedInput::new(old, new);
    let diff = Diff::compute(Algorithm::Myers, &input);
    (diff.count_additions() as usize, diff.count_removals() as usize)
}

/// The hunks of every changed file, fork to main, as unified text in memory.
/// gix renders hunks; the `diff --git` file headers are not its to write.
fn diff_patch(w: &str, path: &str) {
    use gix::diff::blob::unified_diff::{ConsumeBinaryHunk, ContextSize};
    use gix::diff::blob::{Algorithm, Diff, InternedInput, UnifiedDiff};
    let mut best = f64::MAX;
    let (mut plus, mut minus, mut bytes) = (0, 0, 0);
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        let (a, b) = (tree_of(&repo, "refs/tags/fork"), tree_of(&repo, "refs/heads/main"));
        let changes = repo.diff_tree_to_tree(&a, &b, Some(gix::diff::Options::default())).unwrap();
        let mut patch: Vec<u8> = Vec::new();
        for change in &changes {
            use gix::object::tree::diff::ChangeDetached as C;
            if change.entry_mode().is_tree() {
                continue;
            }
            let (old_id, new_id) = match change {
                C::Addition { id, .. } => (None, Some(*id)),
                C::Deletion { id, .. } => (Some(*id), None),
                C::Modification { previous_id, id, .. } => (Some(*previous_id), Some(*id)),
                C::Rewrite { source_id, id, .. } => (Some(*source_id), Some(*id)),
            };
            let read = |id: Option<gix::ObjectId>| id.map_or_else(Vec::new, |id| repo.find_object(id).unwrap().detach().data);
            let (old, new) = (read(old_id), read(new_id));
            let input = InternedInput::new(old.as_slice(), new.as_slice());
            let diff = Diff::compute(Algorithm::Myers, &input);
            let text = UnifiedDiff::new(&diff, &input, ConsumeBinaryHunk::new(Vec::new(), "\n"), ContextSize::symmetrical(3))
                .consume()
                .unwrap();
            patch.extend_from_slice(&text);
        }
        best = best.min(ms(&start));
        bytes = patch.len();
        plus = 0;
        minus = 0;
        for line in patch.lines() {
            if line.starts_with(b"+") {
                plus += 1;
            } else if line.starts_with(b"-") {
                minus += 1;
            }
        }
    }
    emit(w, "time", best, "ms");
    count(w, "insertions", plus);
    count(w, "deletions", minus);
    emit(w, "patch_bytes", bytes as f64, "bytes");
}

/// The index against the working tree, and each modified file's line counts.
fn diff_index(w: &str, path: &str) {
    use gix::status::index_worktree::Item;
    use gix::status::plumbing::index_as_worktree::{Change, EntryStatus};
    let mut best = f64::MAX;
    let (mut files, mut plus, mut minus) = (0, 0, 0);
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        let workdir = repo.workdir().unwrap().to_owned();
        let iter = repo
            .status(gix::progress::Discard)
            .unwrap()
            .untracked_files(gix::status::UntrackedFiles::None)
            .index_worktree_submodules(gix::status::Submodule::AsConfigured { check_dirty: false })
            .into_index_worktree_iter(Vec::new())
            .unwrap();
        (files, plus, minus) = (0, 0, 0);
        for item in iter {
            if let Item::Modification { entry, rela_path, status: EntryStatus::Change(Change::Modification { .. }), .. } = item.unwrap() {
                let old = repo.find_object(entry.id).unwrap().detach().data;
                let new = std::fs::read(workdir.join(rela_path.to_path().unwrap())).unwrap();
                let (p, m) = line_counts(&old, &new);
                files += 1;
                plus += p;
                minus += m;
            }
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "files", files);
    count(w, "insertions", plus);
    count(w, "deletions", minus);
}

fn by_date(repo: &gix::Repository, tip: gix::ObjectId) -> gix::revision::Walk<'_> {
    repo.rev_walk([tip])
        .sorting(gix::revision::walk::Sorting::ByCommitTime(Default::default()))
        .all()
        .unwrap()
}

/// Every commit from main, by date, each decoded for its author and message.
fn log(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut commits = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        commits = 0;
        for info in by_date(&repo, id(&repo, "refs/heads/main")) {
            let commit = info.unwrap().object().unwrap();
            let decoded = commit.decode().unwrap();
            std::hint::black_box(decoded.author().unwrap().name.len() + decoded.message.len());
            commits += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "commits", commits);
}

/// `git blame main -- <hot path>`, following renames as git does.
fn blame(w: &str, path: &str) {
    let mut best = f64::MAX;
    let (mut lines, mut commits, mut last) = (0, 0, None);
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        let options = gix::repository::blame_file::Options { rewrites: Some(Default::default()), ..Default::default() };
        let outcome = repo.blame_file(HOT.into(), id(&repo, "refs/heads/main"), options).unwrap();
        best = best.min(ms(&start));
        lines = outcome.entries.iter().map(|e| e.len.get() as usize).sum();
        commits = outcome.entries.iter().map(|e| e.commit_id).collect::<BTreeSet<_>>().len();
        last = outcome.entries.last().map(|e| e.commit_id);
    }
    emit(w, "time", best, "ms");
    count(w, "lines", lines);
    count(w, "commits", commits);
    oid(w, "last", last.unwrap());
}

/// The commits whose change from their first parent touches the hot path.
fn log_path(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut commits = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        let entry = |commit: gix::ObjectId| {
            repo.find_commit(commit).unwrap().tree().unwrap().lookup_entry_by_path(HOT).unwrap().map(|e| e.object_id())
        };
        commits = 0;
        for info in by_date(&repo, id(&repo, "refs/heads/main")) {
            let info = info.unwrap();
            let here = entry(info.id);
            let before = info.parent_ids.first().and_then(|p| entry(*p));
            if here != before {
                commits += 1;
            }
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "commits", commits);
}

fn revparse(w: &str, path: &str, list: &str) {
    let text = std::fs::read_to_string(list).unwrap();
    let mut best = f64::MAX;
    let mut resolved = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        resolved = 0;
        for line in text.lines().filter(|l| !l.is_empty()) {
            std::hint::black_box(repo.rev_parse_single(line).unwrap());
            resolved += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "resolved", resolved);
}

/// The merge base of main and side. gix has no ancestry query of its own,
/// so `ancestor` is not reported.
fn merge_base(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut base = None;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        base = Some(repo.merge_base(id(&repo, "refs/heads/main"), id(&repo, "refs/heads/side")).unwrap().detach());
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    oid(w, "base", base.unwrap());
}

/// `git merge-tree --write-tree main <theirs>`, in a bare copy.
fn merge_tree(w: &str, path: &str, theirs: &str) {
    let start = BenchmarkInstant::now();
    let repo = gix::open(path).unwrap();
    let labels = gix::merge::blob::builtin_driver::text::Labels {
        ancestor: None,
        current: Some("main".into()),
        other: Some(theirs.into()),
    };
    let options = repo.tree_merge_options().unwrap().into();
    let mut outcome = repo
        .merge_commits(id(&repo, "refs/heads/main"), id(&repo, &format!("refs/heads/{theirs}")), labels, options)
        .unwrap();
    let how = gix::merge::tree::TreatAsUnresolved::default();
    let conflicted: BTreeSet<Vec<u8>> = outcome
        .tree_merge
        .conflicts
        .iter()
        .filter(|c| c.is_unresolved(how))
        .map(|c| c.ours.location().to_vec())
        .collect();
    let tree = outcome.tree_merge.tree.write().unwrap().detach();
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "conflicts", conflicted.len());
    if conflicted.is_empty() {
        oid(w, "tree", tree);
    }
}

/// 1,000 branches at main in one `edit_references` transaction.
fn branch_create(w: &str, path: &str) {
    use gix::refs::transaction::{Change, LogChange, PreviousValue, RefEdit, RefLog};
    let n = if smoke() { 10 } else { 1000 };
    let start = BenchmarkInstant::now();
    let repo = gix::open(path).unwrap();
    let main = id(&repo, "refs/heads/main");
    let edits: Vec<RefEdit> = (0..n)
        .map(|i| RefEdit {
            change: Change::Update {
                log: LogChange {
                    mode: RefLog::AndReference,
                    force_create_reflog: false,
                    message: "branch: Created from main".into(),
                },
                expected: PreviousValue::MustNotExist,
                new: gix::refs::Target::Object(main),
            },
            name: format!("refs/heads/bench/b{i:04}").try_into().unwrap(),
            deref: false,
        })
        .collect();
    repo.edit_references(edits).unwrap();
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "refs", n);
}

/// 100 annotated tags on main, each its object and its ref.
fn tag_create(w: &str, path: &str) {
    let n = if smoke() { 5 } else { 100 };
    let start = BenchmarkInstant::now();
    let repo = gix::open(path).unwrap();
    let main = id(&repo, "refs/heads/main");
    let tagger = gix::actor::SignatureRef {
        name: BStr::new("Bench"),
        email: BStr::new("bench\x40example.invalid"),
        time: "1700000000 +0000",
    };
    let mut first = None;
    for i in 0..n {
        let made = repo
            .tag(format!("bench/t{i:03}"), main, gix::object::Kind::Commit, Some(tagger), "bench tag\n", gix::refs::transaction::PreviousValue::MustNotExist)
            .unwrap();
        first.get_or_insert(made.id().detach());
    }
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "tags", n);
    oid(w, "first", first.unwrap());
}

/// Every ref under refs/ and the object it names.
fn ref_list(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut refs = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        refs = 0;
        for reference in repo.references().unwrap().prefixed("refs/").unwrap() {
            let mut reference = reference.unwrap();
            // Symbolic refs followed, tags not peeled: the object each ref
            // names, as `for-each-ref --format=%(objectname)` prints it.
            std::hint::black_box(reference.follow_to_object().unwrap());
            refs += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "refs", refs);
}

/// Every object rehashed and every pack entry checked, as `verify-pack`.
fn verify(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let repo = gix::open(path).unwrap();
    let interrupt = AtomicBool::new(false);
    let mut progress = gix::progress::Discard;
    let outcome = repo
        .objects
        .store_ref()
        .verify_integrity(
            &mut progress,
            &interrupt,
            gix::odb::pack::index::verify::integrity::Options::default(),
        )
        .unwrap();
    let took = ms(&start);
    let mut objects = 0usize;
    for index in &outcome.index_statistics {
        use gix::odb::store::verify::integrity::SingleOrMultiStatistics as S;
        let mut add = |s: &gix::odb::pack::index::traverse::Statistics| {
            objects += (s.num_commits + s.num_trees + s.num_tags + s.num_blobs) as usize;
        };
        match &index.statistics {
            S::Single(s) => add(s),
            S::Multi(many) => many.iter().for_each(|(_, s)| add(s)),
        }
    }
    for loose in &outcome.loose_object_stores {
        objects += loose.statistics.num_objects;
    }
    emit(w, "time", took, "ms");
    count(w, "objects", objects);
}

/// Each submodule's checked-out commit against the recorded one, as
/// `git submodule status` reports it: working-tree changes ignored.
fn submodule_status(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut n = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = gix::open(path).unwrap();
        n = 0;
        for module in repo.submodules().unwrap().into_iter().flatten() {
            std::hint::black_box(module.status(gix::submodule::config::Ignore::Dirty, false).unwrap());
            n += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "submodules", n);
}
