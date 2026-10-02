
_smoke_ticks = 0
def benchmark_clock_ns():
    global _smoke_ticks
    if os.environ.get("BENCH_SMOKE") == "1":
        _smoke_ticks += 1
        return _smoke_ticks
    return time.perf_counter_ns()
def benchmark_clock():
    if os.environ.get("BENCH_SMOKE") == "1":
        return benchmark_clock_ns() / 1e9
    return time.perf_counter()

#!/usr/bin/env python3
"""The machine's `git` binary as a rival, measured as a subprocess.

Every number here is wall time for one or more `git` processes and therefore
INCLUDES process start, which the in-process library sides do not pay. It is
reported that way on purpose: it is what a caller shelling out to git gets.
"""
import os, subprocess, sys, time, glob


def emit(workload, metric, value, unit):
    if isinstance(value, str):
        print("git\t%s\t%s\t%s\t%s" % (workload, metric, value, unit))
    else:
        print("git\t%s\t%s\t%.3f\t%s" % (workload, metric, value, unit))


def run(args, **kw):
    return subprocess.run(args, check=True, **kw)


command = sys.argv[1]
repo = sys.argv[2]
extra = sys.argv[3] if len(sys.argv) > 3 else None
G = ["git", "-C", repo]

if command == "status":
    best, entries = float("inf"), 0
    for _ in range(1 if os.environ.get("BENCH_SMOKE") == "1" else 5):
        t = benchmark_clock()
        out = subprocess.run(G + ["status", "--porcelain=v1", "--untracked-files=all"],
                             check=True, stdout=subprocess.PIPE)
        took = (benchmark_clock() - t) * 1000.0
        best = min(best, took)
        entries = len([l for l in out.stdout.split(b"\n") if l])
    emit("status", "time", best, "ms")
    emit("status", "entries", entries, "count")

elif command == "addall":
    t = benchmark_clock()
    run(G + ["add", "-A"])
    run(G + ["write-tree"], stdout=subprocess.DEVNULL)
    emit("addall", "time", (benchmark_clock() - t) * 1000.0, "ms")

elif command == "revlist":
    best, objects = float("inf"), 0
    for _ in range(1 if os.environ.get("BENCH_SMOKE") == "1" else 3):
        t = benchmark_clock()
        out = subprocess.run(G + ["rev-list", "--objects", "HEAD"],
                             check=True, stdout=subprocess.PIPE)
        took = (benchmark_clock() - t) * 1000.0
        best = min(best, took)
        objects = out.stdout.count(b"\n")
    emit("revlist", "time", best, "ms")
    emit("revlist", "objects", objects, "count")

elif command == "catblobs":
    names = open(extra, "rb").read()
    # The uncompressed size of every blob, taken outside the timed region so
    # that every side divides the same number of bytes by its own time.
    check = subprocess.run(G + ["cat-file", "--batch-check=%(objectsize)"],
                           input=names, check=True, stdout=subprocess.PIPE)
    total = sum(int(x) for x in check.stdout.split())
    t = benchmark_clock()
    p = subprocess.run(G + ["cat-file", "--batch"], input=names,
                       check=True, stdout=subprocess.DEVNULL)
    took = (benchmark_clock() - t) * 1000.0
    mb = total / 1e6
    emit("catblobs", "throughput", mb / (took / 1000.0), "MB/s")
    emit("catblobs", "time", took, "ms")
    emit("catblobs", "bytes", total, "bytes")

elif command == "packwrite":
    base = os.path.join(extra, "gitpack")
    for stale in glob.glob(base + "-*"):
        os.remove(stale)
    t = benchmark_clock()
    names = subprocess.run(G + ["cat-file", "--batch-all-objects",
                                "--batch-check=%(objectname)"],
                           check=True, stdout=subprocess.PIPE).stdout
    subprocess.run(G + ["pack-objects", "--delta-base-offset",
                        "--window=10", "--depth=50", "-q", base],
                   input=names, check=True, stdout=subprocess.DEVNULL)
    took = (benchmark_clock() - t) * 1000.0
    packs = glob.glob(base + "-*.pack")
    size = os.path.getsize(packs[0]) if packs else 0
    emit("packwrite", "time", took, "ms")
    emit("packwrite", "pack_bytes", size, "bytes")
    emit("packwrite", "objects", names.count(b"\n"), "count")
    emit("packwrite", "deltas", "n/a", "n/a")

elif command == "indexrw":
    # There is no git plumbing that only reads the index and writes it back:
    # `update-index --refresh` stats the working tree, `read-tree` builds the
    # index from a tree. Nothing comparable to measure.
    emit("indexrw", "time", "n/a", "n/a")
    emit("indexrw", "entries", "n/a", "n/a")

else:
    raise SystemExit("unknown workload " + command)
