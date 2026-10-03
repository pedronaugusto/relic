//! libgit2's clone, fetch and push over HTTP, timed from the call to its
//! return.
//!
//!   git2_bench clone <url> <dst> [check]
//!   git2_bench fetch <dir> [check]
//!   git2_bench push <dir>

use git2::Repository;

use crate::{emit, BenchmarkInstant};

fn unavailable(workload: &str, reason: &str) {
    println!("libgit2\t{workload}\ttime\tunavailable\tms");
    println!("libgit2\t{workload}\treason\t{reason}\ttext");
}

/// The URL a command talks to: the clone's, or the remote's.
fn over_ssh(url: &str) -> bool {
    url.starts_with("ssh://")
}

/// Run a transport command; false when `command` is not one.
pub fn run(command: &str, args: &[String]) -> bool {
    let check = args.last().map(String::as_str) == Some("check");
    let url = match command {
        "clone" => args[0].clone(),
        "fetch" | "push" => match Repository::open(&args[0]).and_then(|r| r.find_remote("origin").map(|o| o.url().unwrap_or("").to_owned())) {
            Ok(url) => url,
            Err(_) => return false,
        },
        _ => return false,
    };
    if over_ssh(&url) {
        unavailable(command, "built without ssh, and libgit2's ssh is libssh2, which cannot run the ssh program the stand-in is");
    } else if check {
        unavailable(command, "libgit2 checks no objects on receipt (transfer.fsckObjects)");
    } else {
        match command {
            "clone" => clone(&args[0], &args[1]),
            "fetch" => fetch(&args[0]),
            _ => push(&args[0]),
        }
    }
    true
}

fn clone(url: &str, dst: &str) {
    let _ = std::fs::remove_dir_all(dst);
    let start = BenchmarkInstant::now();
    let repo = git2::build::RepoBuilder::new().bare(true).clone(url, std::path::Path::new(dst)).unwrap();
    drop(repo);
    let took = start.elapsed().as_secs_f64() * 1000.0;
    emit("clone", "time", took, "ms");
}

fn fetch(dir: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(dir).unwrap();
    let mut remote = repo.find_remote("origin").unwrap();
    remote.fetch::<&str>(&[], None, None).unwrap();
    let took = start.elapsed().as_secs_f64() * 1000.0;
    emit("fetch", "time", took, "ms");
}

fn push(dir: &str) {
    let start = BenchmarkInstant::now();
    let repo = Repository::open(dir).unwrap();
    let mut remote = repo.find_remote("origin").unwrap();
    remote.push(&["refs/heads/main:refs/heads/main"], None).unwrap();
    let took = start.elapsed().as_secs_f64() * 1000.0;
    emit("push", "time", took, "ms");
}
