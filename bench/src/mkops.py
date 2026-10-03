#!/usr/bin/env python3
"""The repositories the operation workloads run on, one directory per size.

    mkops.py <dir> <size>        size: smoke, small, medium or large

Everything is generated from a seeded stream through `git fast-import`, with
fixed identities and dates, so every run names the same objects:

  bare.git   main's history and the branches below, bare: one pack holding
             main, the branches' objects loose, and 1,000 packed tags
  repo       the same refs with main checked out, fully packed, index warm
  dirty      a copy of repo with 1 % of its files appended to, never written
  exprs.txt  revision expressions for revparse, one per line

Refs, all in both repositories:
  main            the history: `commits` commits, each changing `touch` files
                  by one line; every tenth also changes HOT
  fork            a tag at main~K, where side and conflict start
  side            5 commits from fork, each changing one file main has not
                  touched since fork and adding one: merges, rebases and
                  cherry-picks cleanly onto main
  conflict        1 commit from fork rewriting two files main changed since
                  fork: two conflicts
  renamed         1 commit on main moving 1 % of the files (at least two)
                  to moved/, one line of each changed
  oldb            a branch at main~O, for switching
  tags/tNNNN      lightweight tags on main's history, packed

The LFS and submodule fixtures are `lfs` and `submodules` below.
"""
import os, random, shutil, subprocess, sys
from pathlib import Path

SIZES = {  # files, bytes per file, commits, files changed per commit, tags
    'smoke': (12, 600, 12, 1, 20),
    'small': (200, 1000, 100, 3, 1000),
    'medium': (3000, 2000, 1000, 10, 1000),
    'large': (20000, 2000, 300, 20, 1000),
}
LFS_SIZES = {'smoke': (2, 4 << 10), 'small': (20, 64 << 10), 'medium': (20, 1 << 20), 'large': (20, 16 << 20)}
HOT = 'd00/d00/f0000.txt'
IDENT = b'Bench <bench\x40example.invalid>'


def git(*args, cwd=None, data=None, quiet=True):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0',
               GIT_AUTHOR_NAME='Bench', GIT_AUTHOR_EMAIL='bench\x40example.invalid',
               GIT_COMMITTER_NAME='Bench', GIT_COMMITTER_EMAIL='bench\x40example.invalid',
               GIT_AUTHOR_DATE='1700000000 +0000', GIT_COMMITTER_DATE='1700000000 +0000')
    out = subprocess.run(['git', *map(str, args)], cwd=cwd, input=data, env=env, check=True,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL if quiet else None)
    return out.stdout.decode().strip()


class Stream:
    """A fast-import stream with one clock and one identity."""
    def __init__(self):
        self.out = bytearray()
        self.when = 1_600_000_000
        self.mark = 0

    def commit(self, ref, parent, changes, message, deletes=()):
        self.when += 3600
        self.mark += 1
        o = self.out
        o += b'commit %s\nmark :%d\n' % (ref.encode(), self.mark)
        o += b'author %s %d +0000\ncommitter %s %d +0000\n' % (IDENT, self.when, IDENT, self.when)
        msg = message.encode()
        o += b'data %d\n%s\n' % (len(msg), msg)
        if parent: o += b'from :%d\n' % parent
        for path in deletes: o += b'D %s\n' % path.encode()
        for path, data in changes:
            o += b'M 100644 inline %s\ndata %d\n' % (path.encode(), len(data)) + data + b'\n'
        o += b'\n'
        return self.mark

    def ref(self, ref, mark):
        self.out += b'reset %s\nfrom :%d\n\n' % (ref.encode(), mark)


def history(size):
    files, nbytes, commits, touch, tags = SIZES[size]
    rng = random.Random(4321)
    words = [''.join(rng.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(rng.randint(2, 9))) for _ in range(2000)]
    line = lambda: ' '.join(rng.choice(words) for _ in range(12))
    paths = ['d%02d/d%02d/f%04d.txt' % (i % 37, (i // 37) % 23, i) for i in range(files)]
    contents = {}
    for p in paths:
        lines, total = [], 0
        while total < nbytes:
            lines.append(line()); total += len(lines[-1]) + 1
        contents[p] = lines
    blob = lambda p: ('\n'.join(contents[p]) + '\n').encode()

    main, rest = Stream(), Stream()
    marks = [main.commit('refs/heads/main', 0, [(p, blob(p)) for p in paths], 'add')]
    fork_back = min(10, commits // 4)
    old_back = min(50, commits // 2)
    touched_since_fork = []
    for c in range(1, commits + 1):
        changed = rng.sample(paths, touch)
        if c % 10 == 0 and HOT not in changed: changed.append(HOT)
        for p in changed:
            lines = contents[p]
            lines[rng.randrange(len(lines))] = line()
        if c > commits - fork_back: touched_since_fork += changed
        # The state each commit leaves, for the branches that start from it.
        if c == commits - fork_back: at_fork = {p: list(contents[p]) for p in paths}
        marks.append(main.commit('refs/heads/main', marks[-1], [(p, blob(p)) for p in changed], 'change %d' % c))
    tip, fork, old = marks[-1], marks[-1 - fork_back], marks[-1 - old_back]
    main.ref('refs/heads/oldb', old)
    for i in range(tags): main.ref('refs/tags/t%04d' % i, marks[1 + i % commits])
    main.ref('refs/tags/fork', fork)
    main.out += b'done\n'

    # The branches go into a second stream: their objects end up loose in
    # bare.git, so a repack there has both a pack and loose objects to take.
    rest.when = main.when
    rest.mark = main.mark
    untouched = [p for p in paths if p not in touched_since_fork and p != HOT]
    parent = fork
    for j in range(5):
        p = untouched[j % len(untouched)]
        lines = list(at_fork[p]); lines[-1] = 'side %d: %s' % (j, line()); at_fork[p] = lines
        new = 'side/s%02d.txt' % j
        parent = rest.commit('refs/heads/side', parent, [(p, ('\n'.join(lines) + '\n').encode()),
                                                          (new, ('side file %d\n%s\n' % (j, line())).encode())],
                             'side %d' % j)
    conflicted = sorted(set(touched_since_fork) - {HOT})[:2]
    rest.commit('refs/heads/conflict', fork,
                [(p, ('\n'.join('conflict: ' + line() for _ in at_fork[p]) + '\n').encode()) for p in conflicted],
                'conflict')
    moved = paths[1:1 + max(2, files // 100)]
    renames = []
    for p in moved:
        lines = list(contents[p]); lines[0] = 'moved: ' + line()
        renames.append(('moved/' + p.replace('/', '_'), ('\n'.join(lines) + '\n').encode()))
    rest.commit('refs/heads/renamed', tip, renames, 'renamed', deletes=moved)
    rest.out += b'done\n'
    return bytes(main.out), bytes(rest.out), commits


def exprs(repo, commits, count):
    """Expressions every tool's revision parser takes."""
    back = min(40, commits)
    forms = ['main~%d' % i for i in range(back)]
    forms += ['side^', 'side~2', 'side~3^', 'fork', 'refs/tags/t0003', 'oldb~1', 'HEAD~2', 'renamed^', 'conflict~1']
    shas = git('rev-list', '-n', '20', 'main', cwd=repo).split()
    forms += shas + [s[:12] for s in shas]
    return '\n'.join(forms[i % len(forms)] for i in range(count)) + '\n'


def ops(root, size):
    root = Path(root)
    if root.exists(): shutil.rmtree(root)
    root.mkdir(parents=True)
    main, rest, commits = history(size)
    bare = root/'bare.git'
    git('init', '-q', '--bare', '-b', 'main', bare)
    git('config', 'gc.auto', '0', cwd=bare)
    marks = root/'marks'
    git('fast-import', '--quiet', '--done', '--export-marks=%s' % marks, cwd=bare, data=main)
    git('-c', 'repack.writeBitmaps=false', 'repack', '-adq', cwd=bare)
    before = set((bare/'objects/pack').glob('pack-*.pack'))
    git('fast-import', '--quiet', '--done', '--import-marks=%s' % marks, cwd=bare, data=rest)
    marks.unlink()
    for made in set((bare/'objects/pack').glob('pack-*.pack')) - before:
        data = made.read_bytes()
        for leftover in (bare/'objects/pack').glob(made.stem + '.*'): leftover.unlink()
        git('unpack-objects', '-q', cwd=bare, data=data)
    git('pack-refs', '--all', cwd=bare)

    repo = root/'repo'
    shutil.copytree(bare, repo/'.git', symlinks=True)
    git('config', 'core.bare', 'false', cwd=repo)
    git('config', 'core.logAllRefUpdates', 'true', cwd=repo)
    git('checkout', '-q', '-f', 'main', cwd=repo)
    git('repack', '-adq', cwd=repo)
    git('status', '--porcelain', cwd=repo)   # warm the index
    (root/'exprs.txt').write_text(exprs(repo, commits, 20 if size == 'smoke' else 1000))

    dirty = root/'dirty'
    subprocess.run(['cp', '-ac' if sys.platform == 'darwin' else '-a', str(repo), str(dirty)], check=True)
    git('update-index', '--refresh', '-q', cwd=dirty)
    files = sorted(p for p in dirty.glob('d*/d*/f*.txt'))
    count = max(1, len(files) // 100)
    for path in files[::max(1, len(files) // count)][:count]:
        with path.open('a') as stream: stream.write('appended for the dirty worktree\n')


def lfs(root, size):
    """`add`: N incompressible files untracked under data/, filter=lfs by the
    committed .gitattributes, git-lfs's filter in the repository's own config.
    `checkout`: main checked out, and the same files committed through
    git-lfs on branch `data`, their contents in the store."""
    root = Path(root)
    if root.exists(): shutil.rmtree(root)
    count, nbytes = LFS_SIZES[size]
    add = root/'add'
    add.mkdir(parents=True)
    git('init', '-q', '-b', 'main', add)
    for key, value in (('gc.auto', '0'), ('filter.lfs.clean', 'git-lfs clean -- %f'),
                       ('filter.lfs.smudge', 'git-lfs smudge -- %f'),
                       ('filter.lfs.process', 'git-lfs filter-process'), ('filter.lfs.required', 'true')):
        git('config', key, value, cwd=add)
    (add/'.gitattributes').write_text('*.bin filter=lfs diff=lfs merge=lfs -text\n')
    git('add', '.gitattributes', cwd=add)
    git('commit', '-q', '-m', 'attributes', cwd=add)
    rng = random.Random(99)
    (add/'data').mkdir()
    for i in range(count):
        (add/'data'/('f%02d.bin' % i)).write_bytes(rng.randbytes(nbytes))
    git('status', '--porcelain', cwd=add)
    checkout = root/'checkout'
    subprocess.run(['cp', '-ac' if sys.platform == 'darwin' else '-a', str(add), str(checkout)], check=True)
    git('switch', '-q', '-c', 'data', cwd=checkout)
    git('add', '-A', cwd=checkout)
    git('commit', '-q', '-m', 'data', cwd=checkout)
    git('switch', '-q', 'main', cwd=checkout)


def submodules(root, count=10):
    """`super-fresh`: a superproject with `count` submodules, none of them
    cloned. `super-init`: the same with every one initialized and updated.
    The submodules' sources are local repositories under sources/."""
    root = Path(root)
    if root.exists(): shutil.rmtree(root)
    sources = root/'sources'
    for i in range(count):
        src = sources/('s%d' % i)
        src.mkdir(parents=True)
        git('init', '-q', '-b', 'main', src)
        rng = random.Random(i)
        for j in range(50):
            (src/('f%02d.txt' % j)).write_text(''.join('%x\n' % rng.getrandbits(64) for _ in range(40)))
        git('add', '-A', cwd=src)
        git('commit', '-q', '-m', 'module %d' % i, cwd=src)
    sup = root/'super-init'
    sup.mkdir()
    git('init', '-q', '-b', 'main', sup)
    git('config', 'protocol.file.allow', 'always', cwd=sup)
    (sup/'README').write_text('superproject\n')
    git('add', 'README', cwd=sup)
    for i in range(count):
        git('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(sources/('s%d' % i)), 'mods/s%d' % i, cwd=sup)
    git('commit', '-q', '-m', 'submodules', cwd=sup)
    git('submodule', 'status', cwd=sup)
    fresh = root/'super-fresh'
    git('clone', '-q', '--no-local', sup, fresh)
    git('config', 'protocol.file.allow', 'always', cwd=fresh)


if __name__ == '__main__':
    target, size = sys.argv[1], sys.argv[2]
    ops(Path(target)/'ops', size)
    lfs(Path(target)/'lfs', size)
    if size in ('smoke', 'small'): submodules(Path(target)/'submodules', 2 if size == 'smoke' else 10)
    print('ok', target, size)
