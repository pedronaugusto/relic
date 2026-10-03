#!/usr/bin/env python3
"""Modify 1 percent (at least one) of a generated fixture's files.

    mutate.py <worktree> [glob]    glob: the fixture's file pattern
"""
import sys
from pathlib import Path
root = Path(sys.argv[1])
files = sorted(root.glob(sys.argv[2] if len(sys.argv) > 2 else "d*/d*/d*/f*.txt"))
if not files: raise SystemExit("no files to modify under " + str(root))
count = max(1, len(files) // 100)
step = max(1, len(files) // count)
for path in files[::step][:count]:
    with path.open("a") as stream:
        stream.write("// modified for the add-all workload\n")
print("modified", count)
