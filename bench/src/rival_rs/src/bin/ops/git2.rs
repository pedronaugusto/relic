//! libgit2's side of the operation workloads (`src/ops.zig` is relic's),
//! through the `git2` crate: each workload the libgit2 call a caller makes.
//! An operation libgit2 has no API for is reported unavailable.

use std::collections::BTreeSet;
use std::path::Path;

use git2::{Oid, Repository, Signature, Time};

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

fn oid(workload: &str, metric: &str, id: Oid) {
    println!("libgit2\t{workload}\t{metric}\t{id}\toid");
}

fn unavailable(workload: &str, reason: &str) {
    println!("libgit2\t{workload}\ttime\tunavailable\tms");
    println!("libgit2\t{workload}\treason\t{reason}\ttext");
}

/// The identity and clock every side commits, tags and stashes with.
fn who() -> Signature<'static> {
    Signature::new("Bench", "bench\x40example.invalid", &Time::new(1_700_000_000, 0)).unwrap()
}

fn id(repo: &Repository, spec: &str) -> Oid {
    repo.revparse_single(spec).unwrap().id()
}

fn head_tree(repo: &Repository) -> Oid {
    repo.head().unwrap().peel_to_tree().unwrap().id()
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
        "revparse" => revparse(workload, path, extra.expect("expressions")),
        "merge-base" => merge_base(workload, path),
        "patch-id" => patch_id(workload, path),
        "merge-tree-clean" => merge_tree(workload, path, "side"),
        "merge-tree-conflict" => merge_tree(workload, path, "conflict"),
        "merge-clean" => merge(workload, path, "side"),
        "merge-conflict" => merge(workload, path, "conflict"),
        "rebase" => rebase(workload, path),
        "cherry-pick" => cherry_pick(workload, path),
        "revert" => revert(workload, path),
        "commit" => commit(workload, path),
        "switch" => switch(workload, path),
        "stash" => stash(workload, path),
        "branch-create" => branch_create(workload, path),
        "tag-create" => tag_create(workload, path),
        "ref-list" => ref_list(workload, path),
        "worktree-add" => worktree_add(workload, path, extra.expect("destination")),
        "submodule-status" => submodule_status(workload, path),
        "submodule-update" => submodule_update(workload, path),
        "repack" => unavailable(workload, "libgit2 has no repack: its packbuilder writes a pack and removes nothing"),
        "verify" => unavailable(workload, "libgit2 has no pack or object verification"),
        "lfs-add" | "lfs-checkout" => unavailable(workload, "libgit2 has no LFS"),
        "snapshot" => unavailable(workload, "libgit2 has no stash create: its stash always resets the working tree"),
        _ => return false,
    }
    true
}

fn trees<'r>(repo: &'r Repository, old: &str, new: &str) -> (git2::Tree<'r>, git2::Tree<'r>) {
    let a = repo.revparse_single(old).unwrap().peel_to_tree().unwrap();
    let b = repo.revparse_single(new).unwrap().peel_to_tree().unwrap();
    (a, b)
}

fn diff_tree(w: &str, path: &str, old: &str, new: &str, renames: bool) {
    let mut best = f64::MAX;
    let mut counts = [0usize; 5];
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let (a, b) = trees(&repo, old, new);
        let mut diff = repo.diff_tree_to_tree(Some(&a), Some(&b), None).unwrap();
        if renames {
            diff.find_similar(Some(git2::DiffFindOptions::new().renames(true))).unwrap();
        }
        counts = [0; 5];
        for delta in diff.deltas() {
            counts[0] += 1;
            match delta.status() {
                git2::Delta::Added => counts[1] += 1,
                git2::Delta::Deleted => counts[2] += 1,
                git2::Delta::Modified => counts[3] += 1,
                git2::Delta::Renamed => counts[4] += 1,
                _ => {}
            }
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    for (metric, value) in ["changes", "added", "deleted", "modified", "renamed"].iter().zip(counts) {
        count(w, metric, value);
    }
}

/// `git diff fork main`: the patch of every change, in memory.
fn diff_patch(w: &str, path: &str) {
    let mut best = f64::MAX;
    let (mut plus, mut minus, mut bytes) = (0, 0, 0);
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let (a, b) = trees(&repo, "refs/tags/fork", "refs/heads/main");
        let diff = repo.diff_tree_to_tree(Some(&a), Some(&b), None).unwrap();
        let mut patch: Vec<u8> = Vec::new();
        (plus, minus) = (0, 0);
        diff.print(git2::DiffFormat::Patch, |_, _, line| {
            match line.origin() {
                '+' => plus += 1,
                '-' => minus += 1,
                _ => {}
            }
            if matches!(line.origin(), '+' | '-' | ' ') {
                patch.push(line.origin() as u8);
            }
            patch.extend_from_slice(line.content());
            true
        })
        .unwrap();
        best = best.min(ms(&start));
        bytes = patch.len();
    }
    emit(w, "time", best, "ms");
    count(w, "insertions", plus);
    count(w, "deletions", minus);
    emit(w, "patch_bytes", bytes as f64, "bytes");
}

/// `git diff --numstat`: the index against the working tree.
fn diff_index(w: &str, path: &str) {
    let mut best = f64::MAX;
    let (mut files, mut plus, mut minus) = (0, 0, 0);
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let diff = repo.diff_index_to_workdir(None, None).unwrap();
        let stats = diff.stats().unwrap();
        (files, plus, minus) = (stats.files_changed(), stats.insertions(), stats.deletions());
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "files", files);
    count(w, "insertions", plus);
    count(w, "deletions", minus);
}

fn by_date<'r>(repo: &'r Repository, tip: Oid) -> git2::Revwalk<'r> {
    let mut walk = repo.revwalk().unwrap();
    walk.set_sorting(git2::Sort::TIME).unwrap();
    walk.push(tip).unwrap();
    walk
}

fn log(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut commits = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        commits = 0;
        for c in by_date(&repo, id(&repo, "refs/heads/main")) {
            let commit = repo.find_commit(c.unwrap()).unwrap();
            std::hint::black_box(commit.author().name_bytes().len() + commit.message_bytes().len());
            commits += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "commits", commits);
}

fn log_path(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut commits = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let entry = |c: &git2::Commit| c.tree().unwrap().get_path(Path::new(HOT)).ok().map(|e| e.id());
        commits = 0;
        for c in by_date(&repo, id(&repo, "refs/heads/main")) {
            let commit = repo.find_commit(c.unwrap()).unwrap();
            let here = entry(&commit);
            let before = commit.parents().next().and_then(|p| entry(&p));
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
        let repo = Repository::open(path).unwrap();
        resolved = 0;
        for line in text.lines().filter(|l| !l.is_empty()) {
            std::hint::black_box(repo.revparse_single(line).unwrap().id());
            resolved += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "resolved", resolved);
}

fn merge_base(w: &str, path: &str) {
    let mut best = f64::MAX;
    let (mut base, mut ancestor) = (None, false);
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let main = id(&repo, "refs/heads/main");
        base = Some(repo.merge_base(main, id(&repo, "refs/heads/side")).unwrap());
        ancestor = repo.graph_descendant_of(main, id(&repo, "refs/tags/fork")).unwrap();
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    oid(w, "base", base.unwrap());
    count(w, "ancestor", ancestor as usize);
}

/// The stable patch id of each commit fork..main, from its first parent.
fn patch_id(w: &str, path: &str) {
    let mut best = f64::MAX;
    let (mut commits, mut tip) = (0, None);
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let mut walk = by_date(&repo, id(&repo, "refs/heads/main"));
        walk.hide(id(&repo, "refs/tags/fork")).unwrap();
        (commits, tip) = (0, None);
        for c in walk {
            let commit = repo.find_commit(c.unwrap()).unwrap();
            let parent = commit.parent(0).unwrap().tree().unwrap();
            let diff = repo.diff_tree_to_tree(Some(&parent), Some(&commit.tree().unwrap()), None).unwrap();
            let pid = diff.patchid(None).unwrap();
            tip.get_or_insert(pid);
            commits += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "commits", commits);
    oid(w, "tip", tip.unwrap());
}

/// The paths an index holds conflicted.
fn conflicted(index: &git2::Index) -> usize {
    let mut paths = BTreeSet::new();
    for c in index.conflicts().unwrap() {
        let c = c.unwrap();
        let entry = c.our.or(c.their).or(c.ancestor).unwrap();
        paths.insert(entry.path);
    }
    paths.len()
}

/// `git merge-tree --write-tree main <theirs>`: an in-memory merge whose
/// tree is written when it is clean (libgit2 cannot write a tree from a
/// conflicted index).
fn merge_tree(w: &str, path: &str, theirs: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let ours = repo.find_commit(id(&repo, "refs/heads/main")).unwrap();
    let theirs = repo.find_commit(id(&repo, &format!("refs/heads/{theirs}"))).unwrap();
    let mut index = repo.merge_commits(&ours, &theirs, None).unwrap();
    let conflicts = conflicted(&index);
    let tree = if conflicts == 0 { Some(index.write_tree_to(&repo).unwrap()) } else { None };
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "conflicts", conflicts);
    if let Some(tree) = tree {
        oid(w, "tree", tree);
    }
}

/// Commit the index onto `HEAD`, with `parents` after it.
fn commit_index(repo: &Repository, author: &Signature, message: &str, extra_parent: Option<Oid>) -> (Oid, Oid) {
    let mut index = repo.index().unwrap();
    let tree_id = index.write_tree().unwrap();
    let tree = repo.find_tree(tree_id).unwrap();
    let head = repo.head().unwrap().peel_to_commit().unwrap();
    let other = extra_parent.map(|p| repo.find_commit(p).unwrap());
    let mut parents = vec![&head];
    if let Some(o) = other.as_ref() {
        parents.push(o);
    }
    let made = repo.commit(Some("HEAD"), author, &who(), message, &tree, &parents).unwrap();
    (tree_id, made)
}

/// `git merge <theirs>` on the checked-out main: merged into the index and
/// working tree, and committed when clean.
fn merge(w: &str, path: &str, theirs: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let target = id(&repo, &format!("refs/heads/{theirs}"));
    let annotated = repo.find_annotated_commit(target).unwrap();
    repo.merge(&[&annotated], None, None).unwrap();
    let conflicts = conflicted(&repo.index().unwrap());
    let tree = if conflicts == 0 {
        let (tree, _) = commit_index(&repo, &who(), &format!("Merge branch '{theirs}'\n"), Some(target));
        repo.cleanup_state().unwrap();
        Some(tree)
    } else {
        None
    };
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "conflicts", conflicts);
    if let Some(tree) = tree {
        oid(w, "tree", tree);
    }
}

/// `git rebase main` with side checked out.
fn rebase(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let upstream = repo.find_annotated_commit(id(&repo, "refs/heads/main")).unwrap();
    let mut rebase = repo.rebase(None, Some(&upstream), None, None).unwrap();
    let mut commits = 0;
    while let Some(op) = rebase.next() {
        op.unwrap();
        rebase.commit(None, &who(), None).unwrap();
        commits += 1;
    }
    rebase.finish(Some(&who())).unwrap();
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "commits", commits);
    oid(w, "tree", head_tree(&repo));
}

/// `git cherry-pick side` on the checked-out main, committed.
fn cherry_pick(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let picked = repo.find_commit(id(&repo, "refs/heads/side")).unwrap();
    repo.cherrypick(&picked, None).unwrap();
    let message = picked.message().unwrap().to_owned();
    let (tree, _) = commit_index(&repo, &picked.author(), &message, None);
    repo.cleanup_state().unwrap();
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "commits", 1);
    oid(w, "tree", tree);
}

/// `git revert main`, committed.
fn revert(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let reverted = repo.find_commit(id(&repo, "refs/heads/main")).unwrap();
    repo.revert(&reverted, None).unwrap();
    let message = format!(
        "Revert \"{}\"\n\nThis reverts commit {}.\n",
        reverted.summary().ok().flatten().unwrap_or(""),
        reverted.id()
    );
    let (tree, _) = commit_index(&repo, &who(), &message, None);
    repo.cleanup_state().unwrap();
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "commits", 1);
    oid(w, "tree", tree);
}

/// `git commit -m 'bench commit'` with 1 % of the files staged.
fn commit(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let (tree, made) = commit_index(&repo, &who(), "bench commit\n", None);
    let took = ms(&start);
    emit(w, "time", took, "ms");
    oid(w, "tree", tree);
    oid(w, "commit", made);
}

/// `git switch oldb`: a safe checkout of the branch's tree, then `HEAD`.
fn switch(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let target = repo.revparse_single("refs/heads/oldb").unwrap();
    let tree = target.peel_to_tree().unwrap().id();
    repo.checkout_tree(&target, Some(git2::build::CheckoutBuilder::new().safe())).unwrap();
    repo.set_head("refs/heads/oldb").unwrap();
    let took = ms(&start);
    emit(w, "time", took, "ms");
    oid(w, "tree", tree);
}

/// `git stash push`, then `git stash pop`.
fn stash(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let mut repo = Repository::open(path).unwrap();
    repo.stash_save(&who(), "bench", None).unwrap();
    let pushed = ms(&start);
    repo.stash_pop(0, None).unwrap();
    let took = ms(&start);
    emit(w, "time", took, "ms");
    emit(w, "time_push", pushed, "ms");
    emit(w, "time_pop", took - pushed, "ms");
}

/// 1,000 branches at main, one reference each: libgit2 has no batch.
fn branch_create(w: &str, path: &str) {
    let n = if smoke() { 10 } else { 1000 };
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let main = id(&repo, "refs/heads/main");
    for i in 0..n {
        repo.reference(&format!("refs/heads/bench/b{i:04}"), main, false, "branch: Created from main").unwrap();
    }
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "refs", n);
}

/// 100 annotated tags on main.
fn tag_create(w: &str, path: &str) {
    let n = if smoke() { 5 } else { 100 };
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let main = repo.revparse_single("refs/heads/main").unwrap();
    let mut first = None;
    for i in 0..n {
        let made = repo.tag(&format!("bench/t{i:03}"), &main, &who(), "bench tag\n", false).unwrap();
        first.get_or_insert(made);
    }
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "tags", n);
    oid(w, "first", first.unwrap());
}

fn ref_list(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut refs = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        refs = 0;
        for reference in repo.references_glob("refs/*").unwrap() {
            let reference = reference.unwrap();
            std::hint::black_box(reference.resolve().unwrap().target());
            refs += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "refs", refs);
}

/// `git worktree add <dir> oldb` from a bare repository.
fn worktree_add(w: &str, path: &str, dest: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let branch = repo.find_reference("refs/heads/oldb").unwrap();
    let mut options = git2::WorktreeAddOptions::new();
    options.reference(Some(&branch));
    repo.worktree("wt", Path::new(dest), Some(&options)).unwrap();
    let took = ms(&start);
    let linked = Repository::open(dest).unwrap();
    emit(w, "time", took, "ms");
    oid(w, "tree", head_tree(&linked));
}

/// Each submodule's recorded commit against its checked-out one, working
/// tree changes ignored, as `git submodule status` reports.
fn submodule_status(w: &str, path: &str) {
    let mut best = f64::MAX;
    let mut n = 0;
    for _ in 0..reps() {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        n = 0;
        for module in repo.submodules().unwrap() {
            std::hint::black_box(repo.submodule_status(module.name().unwrap(), git2::SubmoduleIgnore::Dirty).unwrap());
            n += 1;
        }
        best = best.min(ms(&start));
    }
    emit(w, "time", best, "ms");
    count(w, "submodules", n);
}

/// `git submodule update --init`: every submodule cloned and checked out.
fn submodule_update(w: &str, path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let mut n = 0;
    for mut module in repo.submodules().unwrap() {
        module.update(true, None).unwrap();
        n += 1;
    }
    let took = ms(&start);
    emit(w, "time", took, "ms");
    count(w, "submodules", n);
}
