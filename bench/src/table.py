#!/usr/bin/env python3
"""Print results.tsv as a table, one block per workload."""
import sys
from collections import defaultdict

rows = defaultdict(dict)          # workload -> side -> {metric: (value, unit)}
order_w, order_s = [], []
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 5:
        continue
    side, workload, metric, value, unit = parts[:5]
    if workload not in order_w:
        order_w.append(workload)
    if side not in order_s:
        order_s.append(side)
    rows[workload].setdefault(side, {})[metric] = (value, unit)

TITLES = {
    "status": "1. STATUS, clean worktree, warm index",
    "addall": "2. ADD-ALL + WRITE-TREE, 1 % of files modified",
    "revlist": "3. REV-LIST WALK, every commit, trees + blobs counted",
    "catblobs": "4. CAT ALL BLOBS through the pack",
    "packwrite": "5. PACK WRITE, every loose object, with deltas",
    "indexrw": "6. INDEX READ + WRITE",
}
EXTRA = {
    "status": ["entries"],
    "addall": ["hashed"],
    "revlist": ["time_collect", "objects"],
    "catblobs": ["throughput", "bytes"],
    "packwrite": ["pack_bytes", "objects", "deltas"],
    "indexrw": ["time_durable", "entries"],
}


def fmt(cell):
    if cell is None:
        return "-"
    value, unit = cell
    if value in ("n/a", "ERROR") or unit == "n/a":
        return value if value != "n/a" else "n/a"
    try:
        v = float(value)
    except ValueError:
        return value
    if unit == "bytes":
        return "%.1f MB" % (v / 1e6)
    if unit == "MB/s":
        return "%.1f MB/s" % v
    if unit == "count":
        return "%d" % v
    return "%.1f" % v


for workload in order_w:
    print()
    print(TITLES.get(workload, workload))
    cols = ["time"] + EXTRA.get(workload, [])
    head = "  %-9s" % "side" + "".join("%14s" % c for c in cols)
    print(head)
    print("  " + "-" * (len(head) - 2))
    for side in order_s:
        cells = rows[workload].get(side)
        if cells is None:
            continue
        line = "  %-9s" % side
        for c in cols:
            line += "%14s" % fmt(cells.get(c))
        print(line)
print()
print("time is milliseconds, best of the measured runs: five by default, three")
print("for the two workloads that copy the repository first. The `git` row is wall")
print("time for one or more git processes and includes process start.")
