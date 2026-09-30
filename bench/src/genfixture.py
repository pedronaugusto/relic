#!/usr/bin/env python3
"""Deterministic synthetic git repository for the relic benchmark.

20,000 files in a tree of depth 4 (three directory levels plus the file),
then 200 commits of small changes. Content comes from a seeded PRNG, the
identities and the dates are fixed, so two runs of this script produce byte
identical object names.
"""
import os, random, subprocess, sys, shutil, zlib

root = sys.argv[1]
LEVELS = (1, 1, 1) if os.environ.get("BENCH_SMOKE") == "1" else (10, 10, 10)   # 1000 leaf directories
PER_DIR = 1 if os.environ.get("BENCH_SMOKE") == "1" else 20            # 20,000 files
COMMITS = 1 if os.environ.get("BENCH_SMOKE") == "1" else 200
PER_COMMIT = 1 if os.environ.get("BENCH_SMOKE") == "1" else 20         # files touched by each commit
WORDS = ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta","iota",
         "kappa","lambda","mu","nu","xi","omicron","pi","rho","sigma","tau",
         "upsilon","phi","chi","psi","omega","node","tree","blob","commit",
         "index","pack","object","worktree","refs","hash","offset","window"]

def paths():
    for i in range(LEVELS[0]):
        for j in range(LEVELS[1]):
            for k in range(LEVELS[2]):
                for n in range(PER_DIR):
                    yield "d%02d/d%02d/d%02d/f%02d.txt" % (i, j, k, n)

ALL = list(paths())

def base_lines(path):
    """The file as it was first committed. `zlib.crc32` rather than `hash`:
    Python randomises string hashing per process, and this script has to
    produce the same object names on every run."""
    rng = random.Random(zlib.crc32(path.encode()))
    return [" ".join(rng.choice(WORDS) for _ in range(8)) + "\n" for _ in range(40)]


def write(path, mark):
    """Write revision `mark` of `path`: a small change, not a rewrite, so the
    objects behind it delta against each other the way a real history does."""
    lines = base_lines(path)
    if mark:
        rng = random.Random((zlib.crc32(path.encode()) + mark * 7919) & 0xffffffff)
        lines[(mark * 3) % len(lines)] = "// rev %d: %s\n" % (
            mark, " ".join(rng.choice(WORDS) for _ in range(6)))
    with open(os.path.join(root, path), "w") as f:
        f.write("// %s\n" % path)
        f.writelines(lines)


def git(*args, **kw):
    env = dict(os.environ)
    env.update({
        "GIT_AUTHOR_NAME": "Bench", "GIT_AUTHOR_EMAIL": "bench" + chr(64) + "example.invalid",
        "GIT_COMMITTER_NAME": "Bench", "GIT_COMMITTER_EMAIL": "bench" + chr(64) + "example.invalid",
        "GIT_AUTHOR_DATE": kw.get("when", "1700000000 +0000"),
        "GIT_COMMITTER_DATE": kw.get("when", "1700000000 +0000"),
    })
    subprocess.run(["git", "-C", root] + list(args), check=True, env=env,
                   stdout=subprocess.DEVNULL)

if os.path.exists(root):
    shutil.rmtree(root)
os.makedirs(root)
git("init", "-q", "-b", "main")
git("config", "gc.auto", "0")
git("config", "core.autocrlf", "false")
git("config", "index.version", "2")
git("config", "feature.manyFiles", "false")

made = set()
for p in ALL:
    d = os.path.dirname(p)
    if d not in made:
        os.makedirs(os.path.join(root, d), exist_ok=True)
        made.add(d)
    write(p, 0)
git("add", "-A")
git("commit", "-q", "-m", "seed")

for c in range(1, COMMITS + 1):
    touched = []
    for t in range(PER_COMMIT):
        idx = (c * 7919 + t * 104729) % len(ALL)
        write(ALL[idx], c)
        touched.append(ALL[idx])
    git("add", "--", *touched)
    git("commit", "-q", "-m", "change %d" % c, when="%d +0000" % (1700000000 + c * 60))
print("ok", len(ALL), COMMITS)
