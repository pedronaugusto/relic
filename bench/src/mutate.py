#!/usr/bin/env python3
"""Modify 1 percent (at least one) of a generated fixture's files."""
import sys
from pathlib import Path
root = Path(sys.argv[1])
files = sorted(root.glob("d*/d*/d*/f*.txt"))
count = max(1, len(files) // 100)
step = max(1, len(files) // count)
for path in files[::step][:count]:
    with path.open("a") as stream:
        stream.write("// modified for the add-all workload\n")
print("modified", count)
