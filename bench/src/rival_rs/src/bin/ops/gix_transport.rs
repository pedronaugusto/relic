//! gitoxide's clone and fetch over HTTP (curl) and ssh (the `ssh` program
//! `GIT_SSH_COMMAND` names), timed from the call to its return.
//!
//!   gix_bench clone <url> <dst> [check]
//!   gix_bench fetch <dir> [check]
//!   gix_bench push <dir>

use std::sync::atomic::AtomicBool;

use crate::{emit, BenchmarkInstant};

fn unavailable(workload: &str, reason: &str) {
    println!("gix\t{workload}\ttime\tunavailable\tms");
    println!("gix\t{workload}\treason\t{reason}\ttext");
}

/// Run a transport command; false when `command` is not one.
pub fn run(command: &str, args: &[String]) -> bool {
    let check = args.last().map(String::as_str) == Some("check");
    match command {
        "clone" | "fetch" if check => unavailable(command, "gix checks no objects on receipt (transfer.fsckObjects)"),
        "clone" => clone(&args[0], &args[1]),
        "fetch" => fetch(&args[0]),
        "push" => unavailable(command, "gix has no push"),
        _ => return false,
    }
    true
}

fn clone(url: &str, dst: &str) {
    let _ = std::fs::remove_dir_all(dst);
    let interrupt = AtomicBool::new(false);
    let start = BenchmarkInstant::now();
    let mut prepare = gix::prepare_clone_bare(url, dst).unwrap();
    let (repo, _outcome) = prepare.fetch_only(gix::progress::Discard, &interrupt).unwrap();
    drop(repo);
    let took = start.elapsed().as_secs_f64() * 1000.0;
    emit("clone", "time", took, "ms");
}

fn fetch(dir: &str) {
    let interrupt = AtomicBool::new(false);
    let start = BenchmarkInstant::now();
    // The ref updates' log lines need a committer; git and relic have one
    // without configuration, gix only when it is told.
    let options = gix::open::Options::default().config_overrides(["committer.name=Bench", "committer.email=bench\x40example.invalid"]);
    let repo = gix::open_opts(dir, options).unwrap();
    let remote = repo.find_remote("origin").unwrap();
    let connection = remote.connect(gix::remote::Direction::Fetch).unwrap();
    let outcome = connection
        .prepare_fetch(gix::progress::Discard, Default::default())
        .unwrap()
        .receive(gix::progress::Discard, &interrupt)
        .unwrap();
    std::hint::black_box(&outcome.status);
    let took = start.elapsed().as_secs_f64() * 1000.0;
    emit("fetch", "time", took, "ms");
}
