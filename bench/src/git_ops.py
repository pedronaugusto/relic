"""The machine's `git` on the operation workloads, as subprocesses.

Every time here is the wall time of one or more `git` processes, process
start included, as `git_bench.py` measures the six original workloads: what a
caller shelling out to git pays. Each workload is the command a person types
for the operation `ops.zig` performs in process. Outputs are read after the
clock stops, except where git's answer arrives on its standard output, which
is part of its work.
"""
import hashlib, os, subprocess, sys, time


def benchmark_clock():
    """Smoke exercises correctness without sampling a benchmark clock."""
    global _smoke_ticks
    if os.environ.get("BENCH_SMOKE") == "1":
        _smoke_ticks += 1
        return _smoke_ticks / 1e9
    return time.perf_counter()
_smoke_ticks = 0

SMOKE = os.environ.get("BENCH_SMOKE") == "1"
REPS = 1 if SMOKE else 3
HOT = "d00/d00/f0000.txt"
NAMES = (
    "diff-tree", "diff-renames", "diff-patch", "diff-index", "log", "log-path", "revparse", "merge-base",
    "merge-tree-clean", "merge-tree-conflict", "merge-clean", "merge-conflict", "rebase", "cherry-pick",
    "revert", "commit", "switch", "stash", "branch-create", "tag-create", "ref-list", "repack", "verify",
    "worktree-add", "lfs-add", "lfs-checkout", "submodule-status", "submodule-update", "snapshot", "patch-id",
    "shortlog", "describe", "notes-add", "bundle-create", "bundle-unbundle", "bisect",
    "blame",
)
# The identity and clock every side commits with.
IDENT = {"GIT_AUTHOR_NAME": "Bench", "GIT_AUTHOR_EMAIL": "bench" + chr(64) + "example.invalid",
         "GIT_COMMITTER_NAME": "Bench", "GIT_COMMITTER_EMAIL": "bench" + chr(64) + "example.invalid",
         "GIT_AUTHOR_DATE": "1700000000 +0000", "GIT_COMMITTER_DATE": "1700000000 +0000"}
ENV = dict(os.environ, **IDENT)


def emit(workload, metric, value, unit):
    if isinstance(value, str):
        print("git\t%s\t%s\t%s\t%s" % (workload, metric, value, unit))
    else:
        print("git\t%s\t%s\t%.3f\t%s" % (workload, metric, value, unit))


def git(repo, *args, stdin=None, capture=True):
    return subprocess.run(["git", "-C", repo, *args], input=stdin, env=ENV, check=True,
                          stdout=subprocess.PIPE if capture else subprocess.DEVNULL).stdout


def timed(fn, reps=1):
    """The best of `reps` runs of `fn`, and the last run's result."""
    best, result = float("inf"), None
    for _ in range(reps):
        t = benchmark_clock()
        result = fn()
        best = min(best, (benchmark_clock() - t) * 1000.0)
    return best, result


def letters(out):
    """Counts of a `--name-status` listing, by git's status letter."""
    counts = {"A": 0, "D": 0, "M": 0, "R": 0}
    lines = [l for l in out.decode().splitlines() if l]
    for line in lines:
        counts[line[0]] = counts.get(line[0], 0) + 1
    return len(lines), counts


def head_tree(repo):
    return git(repo, "rev-parse", "HEAD^{tree}").decode().strip()


def run(command, repo, extra):
    w = command
    if w in ("diff-tree", "diff-renames"):
        args = ["fork", "main", "--no-renames"] if w == "diff-tree" else ["main", "renamed", "-M"]
        took, out = timed(lambda: git(repo, "diff-tree", "-r", "--name-status", *args), REPS)
        n, c = letters(out)
        emit(w, "time", took, "ms")
        for metric, letter in (("changes", None), ("added", "A"), ("deleted", "D"), ("modified", "M"), ("renamed", "R")):
            emit(w, metric, n if letter is None else c[letter], "count")
    elif w == "diff-patch":
        took, out = timed(lambda: git(repo, "diff", "--no-renames", "--no-color", "fork", "main"), REPS)
        lines = out.split(b"\n")
        plus = sum(1 for l in lines if l.startswith(b"+") and not l.startswith(b"+++ "))
        minus = sum(1 for l in lines if l.startswith(b"-") and not l.startswith(b"--- "))
        emit(w, "time", took, "ms")
        emit(w, "insertions", plus, "count")
        emit(w, "deletions", minus, "count")
        emit(w, "patch_bytes", len(out), "bytes")
    elif w == "diff-index":
        # --no-optional-locks: the fixture is read by every side and written by none.
        took, out = timed(lambda: subprocess.run(["git", "--no-optional-locks", "-C", repo, "diff", "--numstat"],
                                                  env=ENV, check=True, stdout=subprocess.PIPE).stdout, REPS)
        rows = [l.split("\t") for l in out.decode().splitlines() if l]
        emit(w, "time", took, "ms")
        emit(w, "files", len(rows), "count")
        emit(w, "insertions", sum(int(r[0]) for r in rows), "count")
        emit(w, "deletions", sum(int(r[1]) for r in rows), "count")
    elif w == "log":
        took, out = timed(lambda: git(repo, "log", "--format=%H %an %s", "main"), REPS)
        emit(w, "time", took, "ms")
        emit(w, "commits", out.count(b"\n"), "count")
    elif w == "log-path":
        took, out = timed(lambda: git(repo, "log", "--format=%H", "main", "--", HOT), REPS)
        emit(w, "time", took, "ms")
        emit(w, "commits", out.count(b"\n"), "count")
    elif w == "blame":
        took, out = timed(lambda: git(repo, "blame", "--line-porcelain", "main", "--", HOT), REPS)
        heads = [l.split()[0] for l in out.decode().splitlines() if len(l) > 40 and l[40] == " " and all(c in "0123456789abcdef" for c in l[:40])]
        emit(w, "time", took, "ms")
        emit(w, "lines", len(heads), "count")
        emit(w, "commits", len(set(heads)), "count")
        emit(w, "last", heads[-1], "oid")
    elif w == "revparse":
        exprs = open(extra).read().split()
        took, out = timed(lambda: git(repo, "rev-parse", *exprs), REPS)
        emit(w, "time", took, "ms")
        emit(w, "resolved", out.count(b"\n"), "count")
    elif w == "merge-base":
        def both():
            base = git(repo, "merge-base", "main", "side")
            ancestor = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", "fork", "main"], env=ENV).returncode == 0
            return base, ancestor
        took, (base, ancestor) = timed(both, REPS)
        emit(w, "time", took, "ms")
        emit(w, "base", base.decode().strip(), "oid")
        emit(w, "ancestor", int(ancestor), "count")
    elif w == "patch-id":
        # git computes patch ids from a patch on its standard input: the log
        # of the commits as patches, and patch-id reading it.
        def ids():
            log = subprocess.Popen(["git", "-C", repo, "log", "-p", "--no-renames", "--format=commit %H", "fork..main"],
                                   env=ENV, stdout=subprocess.PIPE)
            out = subprocess.run(["git", "-C", repo, "patch-id", "--stable"], stdin=log.stdout, env=ENV,
                                 check=True, stdout=subprocess.PIPE).stdout
            log.stdout.close()
            if log.wait(): raise SystemExit("git log failed")
            return out
        took, out = timed(ids, REPS)
        rows = [l.split() for l in out.decode().splitlines() if l]
        emit(w, "time", took, "ms")
        emit(w, "commits", len(rows), "count")
        emit(w, "tip", rows[0][0], "oid")
    elif w in ("merge-tree-clean", "merge-tree-conflict"):
        theirs = "side" if w == "merge-tree-clean" else "conflict"
        t = benchmark_clock()
        proc = subprocess.run(["git", "-C", repo, "merge-tree", "--write-tree", "--name-only", "main", theirs],
                              env=ENV, stdout=subprocess.PIPE)
        took = (benchmark_clock() - t) * 1000.0
        if proc.returncode not in (0, 1): raise SystemExit("merge-tree failed")
        # The tree, then the conflicted paths, then a blank line and messages.
        out = proc.stdout.decode().split("\n\n")[0].splitlines()
        emit(w, "time", took, "ms")
        emit(w, "conflicts", len(set(out[1:])), "count")
        if proc.returncode == 0: emit(w, "tree", out[0], "oid")
    elif w in ("merge-clean", "merge-conflict"):
        theirs = "side" if w == "merge-clean" else "conflict"
        t = benchmark_clock()
        proc = subprocess.run(["git", "-C", repo, "merge", "-q", "--no-edit", theirs], env=ENV,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        took = (benchmark_clock() - t) * 1000.0
        conflicts = len(set(l.split("\t")[1] for l in git(repo, "ls-files", "-u").decode().splitlines()))
        if proc.returncode and not conflicts: raise SystemExit("merge failed")
        emit(w, "time", took, "ms")
        emit(w, "conflicts", conflicts, "count")
        if not conflicts: emit(w, "tree", head_tree(repo), "oid")
    elif w == "rebase":
        took, _ = timed(lambda: git(repo, "rebase", "-q", "main", capture=False))
        emit(w, "time", took, "ms")
        emit(w, "commits", int(git(repo, "rev-list", "--count", "main..HEAD")), "count")
        emit(w, "tree", head_tree(repo), "oid")
    elif w in ("cherry-pick", "revert"):
        args = ["cherry-pick", "side"] if w == "cherry-pick" else ["revert", "--no-edit", "main"]
        took, _ = timed(lambda: git(repo, *args, capture=False))
        emit(w, "time", took, "ms")
        emit(w, "commits", 1, "count")
        emit(w, "tree", head_tree(repo), "oid")
    elif w == "commit":
        took, _ = timed(lambda: git(repo, "commit", "-q", "--no-verify", "-m", "bench commit", capture=False))
        emit(w, "time", took, "ms")
        emit(w, "tree", head_tree(repo), "oid")
        emit(w, "commit", git(repo, "rev-parse", "HEAD").decode().strip(), "oid")
    elif w == "switch":
        took, _ = timed(lambda: git(repo, "switch", "-q", "oldb", capture=False))
        emit(w, "time", took, "ms")
        emit(w, "tree", head_tree(repo), "oid")
    elif w == "stash":
        t = benchmark_clock()
        git(repo, "stash", "push", "-q", capture=False)
        pushed = (benchmark_clock() - t) * 1000.0
        git(repo, "stash", "pop", "-q", capture=False)
        took = (benchmark_clock() - t) * 1000.0
        emit(w, "time", took, "ms")
        emit(w, "time_push", pushed, "ms")
        emit(w, "time_pop", took - pushed, "ms")
    elif w == "branch-create":
        count = 10 if SMOKE else 1000
        main = git(repo, "rev-parse", "main").decode().strip()
        lines = "".join("create refs/heads/bench/b%04d %s\n" % (i, main) for i in range(count)).encode()
        took, _ = timed(lambda: git(repo, "update-ref", "--stdin", "-m", "branch: Created from main", stdin=lines, capture=False))
        emit(w, "time", took, "ms")
        emit(w, "refs", count, "count")
    elif w == "tag-create":
        # One `git tag` per tag: git has no command that makes several
        # annotated tags at once.
        count = 5 if SMOKE else 100
        def tags():
            for i in range(count):
                git(repo, "tag", "-a", "-m", "bench tag", "bench/t%03d" % i, "main", capture=False)
        took, _ = timed(tags)
        emit(w, "time", took, "ms")
        emit(w, "tags", count, "count")
        emit(w, "first", git(repo, "rev-parse", "refs/tags/bench/t000").decode().strip(), "oid")
    elif w == "ref-list":
        took, out = timed(lambda: git(repo, "for-each-ref", "--format=%(objectname) %(refname)", "refs/"), REPS)
        emit(w, "time", took, "ms")
        emit(w, "refs", out.count(b"\n"), "count")
    elif w == "repack":
        # No bitmaps: a bare repository would write one by default, and no
        # other side does. The reverse index stays: relic writes it too.
        took, _ = timed(lambda: git(repo, "-c", "repack.writeBitmaps=false", "repack", "-a", "-d", "-q", capture=False))
        counts = dict(l.split(": ") for l in git(repo, "count-objects", "-v").decode().splitlines())
        emit(w, "time", took, "ms")
        emit(w, "objects", int(counts["in-pack"]), "count")
        packs = [os.path.join(repo, "objects", "pack", p) for p in os.listdir(os.path.join(repo, "objects", "pack")) if p.endswith(".pack")]
        emit(w, "pack_bytes", sum(os.path.getsize(p) for p in packs), "bytes")
    elif w == "verify":
        packdir = os.path.join(repo, ".git", "objects", "pack")
        idx = sorted(os.path.join(packdir, p) for p in os.listdir(packdir) if p.endswith(".idx"))
        took, _ = timed(lambda: git(repo, "verify-pack", *idx, capture=False))
        objects = sum(int(l.split()[1]) for l in git(repo, "count-objects", "-v").decode().splitlines() if l.startswith("in-pack"))
        emit(w, "time", took, "ms")
        emit(w, "objects", objects, "count")
    elif w == "worktree-add":
        took, _ = timed(lambda: git(repo, "worktree", "add", "-q", extra, "oldb", capture=False))
        emit(w, "time", took, "ms")
        emit(w, "tree", head_tree(extra), "oid")
    elif w == "lfs-add":
        took, _ = timed(lambda: git(repo, "add", "-A", capture=False))
        emit(w, "time", took, "ms")
        emit(w, "added", len(git(repo, "diff", "--cached", "--name-only").splitlines()), "count")
    elif w == "lfs-checkout":
        took, _ = timed(lambda: git(repo, "switch", "-q", "data", capture=False))
        emit(w, "time", took, "ms")
        emit(w, "tree", head_tree(repo), "oid")
        emit(w, "written", len(git(repo, "ls-files", "data").splitlines()), "count")
    elif w == "submodule-status":
        took, out = timed(lambda: git(repo, "submodule", "status"), REPS)
        emit(w, "time", took, "ms")
        emit(w, "submodules", out.count(b"\n"), "count")
    elif w == "submodule-update":
        took, _ = timed(lambda: git(repo, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q", capture=False))
        emit(w, "time", took, "ms")
        emit(w, "submodules", git(repo, "submodule", "status").count(b"\n"), "count")
    elif w == "snapshot":
        # `git stash create`: the working tree's state as an object, nothing
        # in the working tree or the stash list touched. It also writes the
        # index's commit, which a snapshot does not have.
        took, out = timed(lambda: git(repo, "stash", "create"))
        emit(w, "time", took, "ms")
        emit(w, "tree", git(repo, "rev-parse", out.decode().strip() + "^{tree}").decode().strip(), "oid")
    elif w == "shortlog":
        took, out = timed(lambda: git(repo, "shortlog", "-sne", "main"), REPS)
        commits = sum(int(l.split("\t")[0]) for l in out.decode().splitlines())
        emit(w, "time", took, "ms")
        emit(w, "groups", out.count(b"\n"), "count")
        emit(w, "commits", commits, "count")
    elif w == "describe":
        # One process for the ten: git describes every name it is given.
        revs = ["main~%d" % i for i in range(10)]
        took, out = timed(lambda: git(repo, "describe", "--tags", "--abbrev=12", "--match", "t00[0-4]*", *revs), REPS)
        emit(w, "time", took, "ms")
        emit(w, "described", out.count(b"\n"), "count")
        emit(w, "names", hashlib.sha1(b"blob %d\0" % len(out) + out).hexdigest(), "oid")
    elif w == "notes-add":
        # One `git notes add` per note: each is a notes commit, as on
        # every side.
        count = 5 if SMOKE else 100
        targets = git(repo, "rev-list", "-n", str(count), "main").decode().split()
        def add():
            for t in targets:
                git(repo, "notes", "add", "-m", "bench note", t, capture=False)
        took, _ = timed(add)
        emit(w, "time", took, "ms")
        emit(w, "notes", count, "count")
    elif w == "bundle-create":
        took, _ = timed(lambda: git(repo, "bundle", "create", "-q", extra, "main", "^oldb", capture=False))
        heads = git(repo, "bundle", "list-heads", extra)
        header = open(extra, "rb").read().split(b"\n\n", 1)[0]
        emit(w, "time", took, "ms")
        emit(w, "refs", heads.count(b"\n"), "count")
        emit(w, "prerequisites", sum(1 for l in header.split(b"\n") if l.startswith(b"-")), "count")
    elif w == "bundle-unbundle":
        took, out = timed(lambda: git(repo, "bundle", "unbundle", extra))
        emit(w, "time", took, "ms")
        emit(w, "refs", out.count(b"\n"), "count")
    elif w == "bisect":
        # The verdicts are known before the clock: main and the three
        # commits below it are bad. Each step is the `git bisect` command a
        # person types; reading BISECT_HEAD is a file read.
        bad = set(git(repo, "rev-list", "-n", "4", "main").decode().split())
        head = os.path.join(repo, ".git", "BISECT_HEAD")
        def bisect():
            out = git(repo, "bisect", "start", "--no-checkout", "main", "oldb")
            steps = 0
            while b"is the first 'bad' commit" not in out:
                testing = open(head).read().strip()
                out = git(repo, "bisect", "bad" if testing in bad else "good")
                steps += 1
            return steps
        took, steps = timed(bisect)
        emit(w, "time", took, "ms")
        emit(w, "steps", steps, "count")
        emit(w, "first_bad", git(repo, "rev-parse", "refs/bisect/bad").decode().strip(), "oid")
    else:
        raise SystemExit("unknown workload " + w)
