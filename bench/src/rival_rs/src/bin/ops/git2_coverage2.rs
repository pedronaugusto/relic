//! Matching shallow clone and multi-pack-index object reads.
use crate::{emit, BenchmarkInstant};
use sha1::Digest;
pub fn run(w: &str, args: &[String]) -> bool {
    match w {
        "clone-depth" => {
            let start = BenchmarkInstant::now();
            let mut fetch = git2::FetchOptions::new();
            fetch.depth(3).download_tags(git2::AutotagOption::None);
            let mut builder = git2::build::RepoBuilder::new();
            builder.bare(true).branch("main").fetch_options(fetch);
            // A single-branch refspec, matching git --single-branch.
            builder.remote_create(|r, name, url| {
                r.remote_with_fetch(name, url, "+refs/heads/main:refs/heads/main")
            });
            let r = builder
                .clone(&args[0], std::path::Path::new(&args[1]))
                .unwrap();
            drop(r);
            emit(w, "time", start.elapsed().as_secs_f64() * 1000.0, "ms");
        }
        "midx-read" => {
            let start = BenchmarkInstant::now();
            let ids = std::fs::read_to_string(&args[1]).unwrap();
            let r = git2::Repository::open(&args[0]).unwrap();
            let db = r.odb().unwrap();
            let mut hash = sha1::Sha1::new();
            let mut count = 0;
            for id in ids.lines() {
                let object = db.read(git2::Oid::from_str(id).unwrap()).unwrap();
                hash.update(object.data());
                count += 1;
            }
            let digest = hash.finalize();
            emit(w, "time", start.elapsed().as_secs_f64() * 1000.0, "ms");
            emit(w, "items", count as f64, "count");
            println!("libgit2\t{w}\tdigest\t{digest:x}\toid");
        }
        _ => return false,
    }
    true
}
