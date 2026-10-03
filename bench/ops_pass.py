"""The operation workloads: every public operation the six original
workloads and the transport pass leave out, on the repositories
`src/mkops.py` builds, at three sizes.

Each point runs on the fixture itself when the operation only reads, and on
a fresh copy when it writes, with the index refreshed and any setup the
operation needs done before the clock. Every side that does the work must
report the same results (counts and object names) as every other, and what
the operation left behind is checked with git afterwards.
"""
import subprocess
import sys
import tarfile
from quiet_common import copy_repo, tsv

# workload: (fixture, setup). Fixtures are directories of an mkops.py
# size; `copy` makes a fresh copy first, `None` reads the fixture.
OPS = {
    'diff-tree': ('ops/repo', None), 'diff-renames': ('ops/repo', None), 'diff-patch': ('ops/repo', None),
    'diff-index': ('ops/dirty', None), 'log': ('ops/repo', None), 'log-path': ('ops/repo', None),
    'revparse': ('ops/repo', 'exprs'), 'merge-base': ('ops/repo', None), 'patch-id': ('ops/repo', None),
    'ref-list': ('ops/repo', None), 'verify': ('ops/repo', None), 'blame': ('ops/repo', None),
    'merge-tree-clean': ('ops/bare.git', 'copy'), 'merge-tree-conflict': ('ops/bare.git', 'copy'),
    'branch-create': ('ops/bare.git', 'copy'), 'tag-create': ('ops/bare.git', 'copy'),
    'repack': ('ops/bare.git', 'copy'), 'worktree-add': ('ops/bare.git', 'worktree'),
    'merge-clean': ('ops/repo', 'copy'), 'merge-conflict': ('ops/repo', 'copy'),
    'cherry-pick': ('ops/repo', 'copy'), 'revert': ('ops/repo', 'copy'), 'switch': ('ops/repo', 'copy'),
    'rebase': ('ops/repo', 'side'), 'commit': ('ops/repo', 'staged'), 'stash': ('ops/repo', 'modified'),
    'snapshot': ('ops/dirty', 'store'),
    'lfs-add': ('lfs/add', 'copy'), 'lfs-checkout': ('lfs/checkout', 'copy'),
    'submodule-status': ('submodules/super-init', None), 'submodule-update': ('submodules/super-fresh', 'copy'),
    'apply': ('ops/repo', 'patch'), 'format-patch': ('ops/repo', None), 'am': ('ops/repo', 'mbox'),
    'grep': ('ops/repo', None), 'archive': ('ops/repo', 'archive'), 'clean': ('ops/repo', 'untracked'),
}
# Sizes each fixture family is built at; submodules have one.
SIZES = ('small', 'medium', 'large')
SUBMODULE_SIZES = ('small',)
# Results every side reports the same way; byte counts differ by tool
# (abbreviations, compression) and are reported, not compared.
COMPARED_UNITS = ('count', 'oid')


def identities(output):
    """The `count` and `oid` rows of a point, by metric, counts as integers."""
    rows = [line.split('\t') for line in output.splitlines() if line.count('\t') == 4]
    return {r[2]: str(int(float(r[3]))) if r[4] == 'count' else r[3]
            for r in rows if r[4] in COMPARED_UNITS and r[3] != 'unavailable'}


def build(p, root):
    """Every size's fixtures, during preparation only."""
    sizes = ('smoke',) if p.smoke else SIZES
    if p.preparing:
        for size in sizes:
            p.run([sys.executable, p.here/'src/mkops.py', root/size, size])
    for size in sizes:
        p.prepared.require(root/size)
    return sizes


def ops_pass(p, binary, commands, scratch, root):
    sizes = build(p, root)
    work = scratch/'ops'
    dest = scratch/'ops-worktree'
    store = scratch/'ops-store'
    # What the patch workloads read and archive writes, made per sample.
    patch, mbox, tar = scratch/'ops.patch', scratch/'ops.mbox', scratch/'ops.tar'
    for size in sizes:
        fx = root/size
        for workload, (fixture, setup) in OPS.items():
            if fixture.startswith('submodules') and size not in ('smoke',) + SUBMODULE_SIZES: continue
            source = fx/fixture
            repo = source if setup in (None, 'exprs', 'archive') else work
            extra = []
            if setup == 'exprs': extra = [fx/'ops/exprs.txt']
            if setup == 'worktree': extra = [dest]
            if setup == 'store': extra = [store]
            if setup == 'patch': extra = [patch]
            if setup == 'mbox': extra = [mbox]
            if setup == 'archive': extra = [tar]
            prep = None
            if setup == 'archive':
                def prep():
                    if tar.exists(): tar.unlink()
            elif setup not in (None, 'exprs'):
                def prep(source=source, setup=setup):
                    copy(p, source, work)
                    for leftover in (dest, store, patch, mbox):
                        if leftover.exists(): p.run(['rm', '-rf', leftover])
                    if source.name.endswith('.git'): return
                    git = ['git', '-C', str(work)]
                    # `cp` keeps no ctime, so without a refresh every side
                    # would rehash every file rather than the ones changed.
                    subprocess.run(git + ['update-index', '--refresh', '-q'], env=p.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if setup == 'side': p.run(git + ['switch', '-q', 'side'])
                    if setup in ('staged', 'modified'): p.run([sys.executable, p.here/'src/mutate.py', work, 'd*/d*/f*.txt'])
                    if setup == 'staged': p.run(git + ['add', '-A'])
                    # main~10..main as git writes it, for the copy at main~10
                    # to take: a patch for apply, a mailbox for am.
                    if setup == 'patch': write(p, patch, git + ['diff', 'main~10', 'main'])
                    if setup == 'mbox': write(p, mbox, git + ['format-patch', '--stdout', '--signature=bench', 'main~10..main'])
                    if setup in ('patch', 'mbox'): p.run(git + ['switch', '-q', '--detach', 'main~10'])
                    if setup == 'untracked': untracked(work)
            points = [(side, [*argv, workload, repo, *extra]) for side, argv in binary.items()]
            points += [(tool, [*argv, workload, repo, *extra]) for tool, argv in commands.items()]
            agreed = {}
            def check(out, workload=workload, repo=repo, agreed=agreed, extra=extra):
                evidence = tsv(out)
                if evidence['operation'] != 'available': return evidence
                found = identities(out)
                for metric, value in after(p, workload, repo, extra).items():
                    if found.setdefault(metric, value) != value:
                        raise ValueError(f'{workload}: reported {metric} {found[metric]}, git finds {value}')
                for metric, value in found.items():
                    if agreed.setdefault(metric, value) != value:
                        raise ValueError(f'{workload}: {metric} {value} differs from {agreed[metric]}')
                evidence['agreed'] = found
                return evidence
            p.interleave(f'{workload}/{size}', points, prepare=prep, check=check)


def write(p, path, argv):
    """A command's standard output, into `path`."""
    with open(path, 'wb') as out:
        subprocess.run(argv, env=p.env, check=True, stdout=out)


def untracked(repo):
    """1 % of the fixture's file count in untracked files, at least ten:
    half in new directories, half beside tracked files."""
    tracked = sorted(repo.glob('d*/d*/f*.txt'))
    count = max(10, len(tracked) // 100)
    for i in range(count):
        if i % 2: path = repo/'untracked'/('u%02d' % (i % 7))/('n%04d.txt' % i)
        else: path = tracked[i % len(tracked)].with_name('n%04d.txt' % i)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('untracked %d\n' % i)


def copy(p, src, dst):
    copy_repo(p, src, dst)


def after(p, workload, repo, extra):
    """What git finds the operation left behind, for the comparison."""
    git = lambda *args: p.run(['git', '-C', repo, *args]).strip()
    found = {}
    if workload in ('merge-clean', 'cherry-pick', 'revert', 'rebase', 'switch', 'commit'):
        found['tree'] = git('rev-parse', 'HEAD^{tree}')
        if git('status', '--porcelain', '--untracked-files=no'): raise ValueError(f'{workload} left changes')
    if workload == 'switch' and git('symbolic-ref', 'HEAD') != 'refs/heads/oldb': raise ValueError('switch left HEAD elsewhere')
    if workload == 'merge-conflict':
        found['conflicts'] = str(len({l.split('\t')[1] for l in git('ls-files', '-u').splitlines()}))
    if workload == 'stash':
        if git('stash', 'list'): raise ValueError('stash left an entry')
        found['modified'] = str(len(git('status', '--porcelain', '--untracked-files=no').splitlines()))
    if workload == 'branch-create':
        found['refs'] = str(len(git('for-each-ref', 'refs/heads/bench/').splitlines()))
    if workload == 'tag-create':
        found['tags'] = str(len(git('for-each-ref', 'refs/tags/bench/').splitlines()))
        found['first'] = git('rev-parse', 'refs/tags/bench/t000')
    if workload == 'repack':
        # Standard output only: a tool that leaves an old pack's reverse
        # index behind makes git warn about it on standard error.
        listing = subprocess.run(['git', '-C', str(repo), 'count-objects', '-v'], env=p.env, check=True,
                                 capture_output=True, text=True).stdout
        counts = dict(line.split(': ', 1) for line in listing.splitlines())
        if counts['count'] != '0' or counts['packs'] != '1': raise ValueError(f'repack left {counts}')
        found['objects'] = counts['in-pack']
        reachable = git('rev-list', '--objects', '--all').count('\n') + 1
        if str(reachable) != counts['in-pack']: raise ValueError('repack lost or kept objects')
    if workload == 'worktree-add':
        wt = lambda *args: p.run(['git', '-C', extra[0], *args]).strip()
        found['tree'] = wt('rev-parse', 'HEAD^{tree}')
        if wt('status', '--porcelain'): raise ValueError('worktree-add left changes')
    if workload == 'lfs-add':
        found['tree'] = git('write-tree')
        found['lfs_objects'] = str(sum(1 for f in (repo/'.git/lfs/objects').rglob('*') if f.is_file()))
    if workload == 'lfs-checkout':
        found['tree'] = git('rev-parse', 'HEAD^{tree}')
        if git('status', '--porcelain'): raise ValueError('lfs-checkout left changes')
        for path in (repo/'data').iterdir():
            if path.read_bytes().startswith(b'version https://git-lfs'): raise ValueError('lfs-checkout left a pointer')
    if workload in ('apply', 'am'):
        if workload == 'am': found['commits'] = git('rev-list', '--count', 'main~10..HEAD')
        tree = git('write-tree')
        if tree != git('rev-parse', 'main^{tree}'): raise ValueError(f'{workload} left a different tree')
        if git('diff', '--name-only'): raise ValueError(f'{workload} left the working tree unlike the index')
        if workload == 'am' and git('rev-parse', 'HEAD^{tree}') != tree: raise ValueError('am left changes uncommitted')
    if workload == 'archive':
        with tarfile.open(extra[0]) as archived:
            found['files'] = str(sum(1 for member in archived if member.isfile()))
    if workload == 'clean':
        if git('status', '--porcelain', '--untracked-files=all'): raise ValueError('clean left something')
    if workload == 'submodule-update':
        lines = p.run(['git', '-C', repo, 'submodule', 'status']).splitlines()
        if any(not line.startswith(' ') for line in lines): raise ValueError('submodule-update left one out')
        found['submodules'] = str(len(lines))
    return found
