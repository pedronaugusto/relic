#!/usr/bin/env python3
"""Pick the best of several runs of one point.

Each argument is one run's TSV output. The run with the smallest `time` wins
and its whole output is printed, so every metric reported comes from the same
run rather than from a mixture of the best of each. A point whose `time` is
`n/a` or `ERROR` on every run has nothing to compare, and the first run is
printed as it stands.
"""
import sys

paths = [p for p in sys.argv[1:]]
best_file, best_time = None, float("inf")
for path in paths:
    try:
        rows = [l.rstrip("\n").split("\t") for l in open(path) if l.strip()]
    except OSError:
        continue
    if not rows:
        continue
    for row in rows:
        if len(row) >= 4 and row[2] == "time":
            try:
                t = float(row[3])
            except ValueError:
                t = float("inf")
            if t < best_time:
                best_time, best_file = t, path
            break

if best_file is None:
    # Nothing timed: an `n/a` point, or one that failed on every run.
    for path in paths:
        try:
            if open(path).read().strip():
                best_file = path
                break
        except OSError:
            continue

if best_file is not None:
    sys.stdout.write(open(best_file).read())
