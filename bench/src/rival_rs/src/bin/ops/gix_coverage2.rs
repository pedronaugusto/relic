//! Matching shallow clone and multi-pack-index object reads.
use crate::{emit, BenchmarkInstant};
use gix::prelude::*;
use sha1::Digest;
pub fn run(w: &str, args: &[String]) -> bool {
    match w {
        "clone-depth" => {
            let start = BenchmarkInstant::now();
            let mut p = gix::prepare_clone_bare(args[0].as_str(), &args[1])
                .unwrap()
                .with_ref_name(Some("main"))
                .unwrap()
                .with_shallow(gix::remote::fetch::Shallow::DepthAtRemote(
                    3.try_into().unwrap(),
                ))
                .configure_remote(|r| Ok(r.with_fetch_tags(gix::remote::fetch::Tags::None)));
            let (r, _) = p
                .fetch_only(
                    gix::progress::Discard,
                    &std::sync::atomic::AtomicBool::new(false),
                )
                .unwrap();
            drop(r);
            emit(w, "time", start.elapsed().as_secs_f64() * 1000.0, "ms");
        }
        "midx-read" => {
            let start = BenchmarkInstant::now();
            let ids = std::fs::read_to_string(&args[1]).unwrap();
            let r = gix::open(&args[0]).unwrap();
            let mut hash = sha1::Sha1::new();
            let mut data = Vec::new();
            let mut count = 0;
            for id in ids.lines() {
                let oid = gix::ObjectId::from_hex(id.as_bytes()).unwrap();
                let object = r.objects.find(&oid, &mut data).unwrap();
                hash.update(object.data);
                count += 1;
            }
            let digest = hash.finalize();
            emit(w, "time", start.elapsed().as_secs_f64() * 1000.0, "ms");
            emit(w, "items", count as f64, "count");
            println!("gix\t{w}\tdigest\t{digest:x}\toid");
        }
        _ => return false,
    }
    true
}
