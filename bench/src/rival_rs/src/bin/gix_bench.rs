//! gitoxide's side of the benchmark, through the `gix` hub crate.
//!
//! Same six workloads, same timed boundary: the clock starts at "open the
//! repository" and stops when the work is done. Two workloads are `n/a`:
//! gix has no staging API (workload 2), and its pack writing lives in
//! `gix-pack` rather than in the hub crate (workload 5 is measured through
//! that crate directly, which is noted in the README).

use std::io::Write;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

use gix::prelude::*;

fn emit(workload: &str, metric: &str, value: f64, unit: &str) {
    let mut out = std::io::stdout();
    writeln!(out, "gix\t{}\t{}\t{:.3}\t{}", workload, metric, value, unit).unwrap();
}

fn na(workload: &str, metric: &str) {
    let mut out = std::io::stdout();
    writeln!(out, "gix\t{}\t{}\tn/a\tn/a", workload, metric).unwrap();
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let command = args.get(1).expect("workload").as_str();
    let repo_path = args.get(2).expect("repository path").clone();
    let extra = args.get(3).cloned();

    match command {
        "status" => status(&repo_path),
        "addall" => {
            // gix reads a working tree and writes an index, but it has no
            // `add`: nothing stages a working tree into the index. This is a
            // gap in the rival, not a workload left out.
            na("addall", "time");
        }
        "revlist" => rev_list(&repo_path),
        "catblobs" => cat_blobs(&repo_path, &extra.expect("blob list")),
        "packwrite" => pack_write(&repo_path, &extra.expect("scratch dir")),
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
        let start = Instant::now();
        let repo = gix::open(path).unwrap();
        let mut iter = repo
            .status(gix::progress::Discard)
            .unwrap()
            .untracked_files(gix::status::UntrackedFiles::Files)
            .index_worktree_submodules(gix::status::Submodule::AsConfigured { check_dirty: false })
            .into_iter(None)
            .unwrap();
        let mut n = 0usize;
        for item in iter.by_ref() {
            item.unwrap();
            n += 1;
        }
        drop(iter);
        best = best.min(start.elapsed().as_secs_f64() * 1000.0);
        entries = n;
    }
    emit("status", "time", best, "ms");
    emit("status", "entries", entries as f64, "count");
}

/// Workload 3: every commit, and every tree and blob they reach.
///
/// `gix::traverse::tree::Recorder` would record every entry of every root
/// tree, which on this fixture is 201 full walks of 20 000 files. The
/// delegate below skips a subtree it has already seen, which is what the
/// other sides do and what makes the workload the same one.
struct CountingVisit<'a> {
    seen: &'a mut gix::hashtable::HashSet<gix::ObjectId>,
    count: usize,
}

impl gix::traverse::tree::Visit for CountingVisit<'_> {
    fn pop_back_tracked_path_and_set_current(&mut self) {}
    fn pop_front_tracked_path_and_set_current(&mut self) {}
    fn push_back_tracked_path_component(&mut self, _component: &gix::bstr::BStr) {}
    fn push_path_component(&mut self, _component: &gix::bstr::BStr) {}
    fn pop_path_component(&mut self) {}

    fn visit_tree(
        &mut self,
        entry: &gix::objs::tree::EntryRef<'_>,
    ) -> gix::traverse::tree::visit::Action {
        if self.seen.insert(entry.oid.to_owned()) {
            self.count += 1;
            std::ops::ControlFlow::Continue(true)
        } else {
            std::ops::ControlFlow::Continue(false)
        }
    }

    fn visit_nontree(
        &mut self,
        entry: &gix::objs::tree::EntryRef<'_>,
    ) -> gix::traverse::tree::visit::Action {
        if self.seen.insert(entry.oid.to_owned()) {
            self.count += 1;
        }
        std::ops::ControlFlow::Continue(true)
    }
}

fn rev_list(path: &str) {
    let reps = if std::env::var("BENCH_SMOKE").as_deref() == Ok("1") { 1 } else { 3 };
    let mut best = f64::MAX;
    let mut objects = 0usize;
    for _ in 0..reps {
        let start = Instant::now();
        let repo = gix::open(path).unwrap();
        let head = repo.head_id().unwrap();
        let mut seen = gix::hashtable::HashSet::<gix::ObjectId>::default();
        let mut count = 0usize;
        for info in repo.rev_walk(Some(head.detach())).all().unwrap() {
            let info = info.unwrap();
            count += 1; // the commit itself, as `rev-list --objects` prints it
            let commit = info.object().unwrap();
            let tree_id = commit.tree_id().unwrap();
            if !seen.insert(tree_id.detach()) {
                continue;
            }
            count += 1; // the root tree
            let tree = repo.find_tree(tree_id).unwrap();
            let mut visit = CountingVisit {
                seen: &mut seen,
                count: 0,
            };
            tree.traverse().breadthfirst(&mut visit).unwrap();
            count += visit.count;
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
    let oids: Vec<gix::ObjectId> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| gix::ObjectId::from_hex(l.trim().as_bytes()).unwrap())
        .collect();

    let start = Instant::now();
    let repo = gix::open(path).unwrap();
    let mut buf: Vec<u8> = Vec::with_capacity(1 << 20);
    let mut total: u64 = 0;
    for oid in &oids {
        let data = repo.objects.find(oid, &mut buf).unwrap();
        total += data.data.len() as u64;
    }
    let took = start.elapsed().as_secs_f64() * 1000.0;
    let mb = total as f64 / 1_000_000.0;
    emit("catblobs", "throughput", mb / (took / 1000.0), "MB/s");
    emit("catblobs", "time", took, "ms");
    emit("catblobs", "bytes", total as f64, "bytes");
}

/// Workload 5: pack every object, with deltas.
///
/// `gix` itself does not expose pack writing; this goes through `gix-pack`'s
/// `data::output` pipeline directly, with every commit as a tip so that the
/// object set is the whole history rather than one tree. It writes the
/// `.pack` only — no `.idx`, which the other three sides do write.
fn pack_write(path: &str, scratch: &str) {
    use gix_pack::data::output;

    let start = Instant::now();
    let repo = gix::open(path).unwrap();
    let head = repo.head_id().unwrap();
    let tips: Vec<gix::ObjectId> = repo
        .rev_walk(Some(head.detach()))
        .all()
        .unwrap()
        .map(|info| info.unwrap().id)
        .collect();

    let mut db = repo.objects.clone().into_inner();
    db.prevent_pack_unload();
    let should_interrupt = AtomicBool::new(false);
    let progress = gix_features::progress::Discard;

    let (counts, _stats) = output::count::objects(
        db.clone(),
        Box::new(tips.into_iter().map(
            Ok::<_, Box<dyn std::error::Error + Send + Sync + 'static>>,
        )),
        &progress,
        &should_interrupt,
        output::count::objects::Options {
            thread_limit: None,
            input_object_expansion: output::count::objects::ObjectExpansion::TreeContents,
            chunk_size: 50,
        },
    )
    .unwrap();

    let num_entries = counts.len() as u32;
    let entries = output::entry::iter_from_counts(
        counts,
        db,
        Box::new(gix_features::progress::Discard),
        output::entry::iter_from_counts::Options {
            thread_limit: None,
            mode: output::entry::iter_from_counts::Mode::PackCopyAndBaseObjects,
            allow_thin_pack: false,
            chunk_size: 10,
            version: gix_pack::data::Version::V2,
            compression: gix_zlib::Compression::DEFAULT,
        },
    );

    let out = std::path::Path::new(scratch).join("gix.pack");
    let file = std::io::BufWriter::new(std::fs::File::create(&out).unwrap());
    let mut writer = output::bytes::FromEntriesIter::new(
        gix_features::parallel::InOrderIter::from(entries),
        file,
        num_entries,
        gix_pack::data::Version::V2,
        repo.object_hash(),
    );
    while let Some(written) = writer.next() {
        written.unwrap();
    }
    drop(writer); // flushes the BufWriter, so the file on disk is complete
    let bytes = std::fs::metadata(&out).unwrap().len();
    let took = start.elapsed().as_secs_f64() * 1000.0;
    emit("packwrite", "time", took, "ms");
    emit("packwrite", "pack_bytes", bytes as f64, "bytes");
    emit("packwrite", "objects", num_entries as f64, "count");
    na("packwrite", "deltas");
}

/// Workload 6: read the index and write it back out.
fn index_rw(path: &str, scratch: &str) {
    let index_path = std::path::Path::new(path).join(".git").join("index");
    let out = std::path::Path::new(scratch).join("index.gix");
    let reps = if std::env::var("BENCH_SMOKE").as_deref() == Ok("1") { 1 } else { 10 };
    let mut best = f64::MAX;
    let mut entries = 0usize;
    for _ in 0..reps {
        let start = Instant::now();
        let mut file = gix::index::File::at(
            &index_path,
            gix::hash::Kind::Sha1,
            false,
            gix::index::decode::Options::default(),
        )
        .unwrap();
        let n = file.entries().len();
        file.set_path(&out);
        file.write(gix::index::write::Options {
            extensions: gix::index::write::Extensions::All,
            skip_hash: false,
        })
        .unwrap();
        best = best.min(start.elapsed().as_secs_f64() * 1000.0);
        entries = n;
    }
    emit("indexrw", "time", best, "ms");
    emit("indexrw", "entries", entries as f64, "count");
}
