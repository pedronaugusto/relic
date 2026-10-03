//! libgit2's side of the benchmark, through the `git2` crate.
//!
//! Same six workloads, same timed boundary: the clock starts at "open the
//! repository" and stops when the work is done. The operation workloads are
//! in `ops/git2.rs`, clone, fetch and push in `ops/git2_transport.rs`.

use std::collections::HashSet;
use std::io::Write;
use std::time::Instant;

use git2::{Oid, Repository};

#[path = "ops/git2.rs"]
mod ops;
#[path = "ops/git2_transport.rs"]
mod transport;

fn emit(workload: &str, metric: &str, value: f64, unit: &str) {
    let mut out = std::io::stdout();
    writeln!(out, "libgit2\t{}\t{}\t{:.3}\t{}", workload, metric, value, unit).unwrap();
}

/// A metric the tool cannot give, with the reason.
fn unavailable(workload: &str, metric: &str, unit: &str, reason: &str) {
    let mut out = std::io::stdout();
    writeln!(out, "libgit2\t{}\t{}\tunavailable\t{}", workload, metric, unit).unwrap();
    writeln!(out, "libgit2\t{}\treason\t{}\ttext", workload, reason).unwrap();
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let command = args.get(1).expect("workload").as_str();
    let repo_path = args.get(2).expect("repository path").clone();
    let extra = args.get(3).cloned();

    if ops::run(command, &repo_path, extra.as_deref()) || transport::run(command, &args[2..]) {
        return;
    }
    match command {
        "status" => status(&repo_path),
        "addall" => add_all(&repo_path),
        "revlist" => rev_list(&repo_path),
        "catblobs" => cat_blobs(&repo_path, &extra.expect("blob list")),
        "packwrite" => pack_write(&repo_path),
        "indexrw" => index_rw(&repo_path, &extra.expect("scratch dir")),
        other => panic!("unknown workload {other}"),
    }
}

/// Workload 1: status of a clean worktree with a warm index.
fn status(path: &str) {
    let reps = if std::env::var("BENCH_SMOKE").as_deref() == Ok("1") { 1 } else { 5 };
    let mut best = f64::MAX;
    let mut entries = 0usize;
    for _ in 0..reps {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let mut opts = git2::StatusOptions::new();
        opts.include_untracked(true)
            .recurse_untracked_dirs(true)
            .include_ignored(false)
            .include_unmodified(false);
        let statuses = repo.statuses(Some(&mut opts)).unwrap();
        let n = statuses.len();
        best = best.min(start.elapsed().as_secs_f64() * 1000.0);
        entries = n;
    }
    emit("status", "time", best, "ms");
    emit("status", "entries", entries as f64, "count");
}

/// Workload 2: add -A then write-tree, on a fresh 1 %-dirty copy.
fn add_all(path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let mut index = repo.index().unwrap();
    index
        .add_all(["*"].iter(), git2::IndexAddOption::DEFAULT, None)
        .unwrap();
    index.write().unwrap();
    let tree = index.write_tree().unwrap();
    let took = start.elapsed().as_secs_f64() * 1000.0;
    std::hint::black_box(tree);
    emit("addall", "time", took, "ms");
}

/// Workload 3: every commit, and every tree and blob they reach.
fn rev_list(path: &str) {
    let reps = if std::env::var("BENCH_SMOKE").as_deref() == Ok("1") { 1 } else { 3 };
    let mut best = f64::MAX;
    let mut objects = 0usize;
    for _ in 0..reps {
        let start = BenchmarkInstant::now();
        let repo = Repository::open(path).unwrap();
        let mut walk = repo.revwalk().unwrap();
        walk.push_head().unwrap();
        let mut seen: HashSet<Oid> = HashSet::new();
        let mut count = 0usize;
        let mut pending: Vec<Oid> = Vec::new();
        for oid in walk {
            let oid = oid.unwrap();
            count += 1; // the commit itself, as `rev-list --objects` prints it
            let commit = repo.find_commit(oid).unwrap();
            let tree = commit.tree_id();
            if seen.insert(tree) {
                pending.push(tree);
            }
        }
        while let Some(tree_id) = pending.pop() {
            count += 1;
            let tree = repo.find_tree(tree_id).unwrap();
            for entry in tree.iter() {
                match entry.kind() {
                    Some(git2::ObjectType::Tree) => {
                        if seen.insert(entry.id()) {
                            pending.push(entry.id());
                        }
                    }
                    Some(git2::ObjectType::Blob) => {
                        if seen.insert(entry.id()) {
                            count += 1;
                        }
                    }
                    _ => {}
                }
            }
        }
        best = best.min(start.elapsed().as_secs_f64() * 1000.0);
        objects = count;
    }
    emit("revlist", "time", best, "ms");
    emit("revlist", "objects", objects as f64, "count");
}

/// Workload 4: read every blob through the pack.
fn cat_blobs(path: &str, list: &str) {
    let text = std::fs::read_to_string(list).unwrap();
    let oids: Vec<Oid> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| Oid::from_str(l.trim()).unwrap())
        .collect();

    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let odb = repo.odb().unwrap();
    let mut total: u64 = 0;
    for oid in &oids {
        let object = odb.read(*oid).unwrap();
        total += object.len() as u64;
    }
    let took = start.elapsed().as_secs_f64() * 1000.0;
    let mb = total as f64 / 1_000_000.0;
    emit("catblobs", "throughput", mb / (took / 1000.0), "MB/s");
    emit("catblobs", "time", took, "ms");
    emit("catblobs", "bytes", total as f64, "bytes");
}

/// Workload 5: pack every loose object, with deltas.
///
/// `git_packbuilder` is given every object the database holds — which in a
/// loose-only copy is every loose object — and writes one pack.
fn pack_write(path: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(path).unwrap();
    let odb = repo.odb().unwrap();
    let mut names: Vec<Oid> = Vec::new();
    odb.foreach(|oid| {
        names.push(*oid);
        true
    })
    .unwrap();
    let mut builder = repo.packbuilder().unwrap();
    for oid in &names {
        builder.insert_object(*oid, None).unwrap();
    }
    let mut bytes: u64 = 0;
    builder
        .foreach(|chunk| {
            bytes += chunk.len() as u64;
            true
        })
        .unwrap();
    let took = start.elapsed().as_secs_f64() * 1000.0;
    emit("packwrite", "time", took, "ms");
    emit("packwrite", "pack_bytes", bytes as f64, "bytes");
    emit("packwrite", "objects", names.len() as f64, "count");
    unavailable("packwrite", "deltas", "count", "the packbuilder streams its pack and reports no delta count");
}

/// Workload 6: read the index and write it back out.
fn index_rw(path: &str, scratch: &str) {
    let index_path = std::path::Path::new(path).join(".git").join("index");
    let out = std::path::Path::new(scratch).join("index.libgit2");
    let reps = if std::env::var("BENCH_SMOKE").as_deref() == Ok("1") { 1 } else { 10 };
    let mut best = f64::MAX;
    let mut entries = 0usize;
    for _ in 0..reps {
        std::fs::copy(&index_path, &out).unwrap();
        let start = BenchmarkInstant::now();
        let mut index = git2::Index::open(&out).unwrap();
        let n = index.len();
        assert!(n > 0, "libgit2 index open read nothing");
        index.write().unwrap();
        best = best.min(start.elapsed().as_secs_f64() * 1000.0);
        entries = n;
    }
    emit("indexrw", "time", best, "ms");
    emit("indexrw", "entries", entries as f64, "count");
}

// Runtime smoke mode never starts a performance clock.
struct BenchmarkInstant(Option<Instant>);
impl BenchmarkInstant {
    fn now() -> Self {
        Self(if std::env::var("BENCH_SMOKE").as_deref() == Ok("1") { None } else { Some(Instant::now()) })
    }
    fn elapsed(&self) -> std::time::Duration {
        self.0.map_or(std::time::Duration::from_nanos(1), |start| start.elapsed())
    }
}
