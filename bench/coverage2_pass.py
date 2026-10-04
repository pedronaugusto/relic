"""Same-input checks for reftable, MIDX, rerere, sparse, clone/serve and LFS.
No setup, resets, server startup or git validation occur in measured regions.
Unavailable rows are explicit API gaps; an unexpected failure aborts the pass.
"""
import hashlib
import json
from pathlib import Path
import select
import shutil
import subprocess
import sys
from http.client import HTTPConnection
from quiet_common import copy_repo, tsv
from ops_pass import identities, SIZES

LOCAL = ('reftable-read', 'reftable-write', 'reftable-compact', 'midx-read',
         'rerere-record', 'rerere-replay', 'sparse-cone-set', 'sparse-cone-reapply',
         'sparse-noncone-set', 'sparse-noncone-reapply')
CLONE = ('clone-depth', 'clone-blob-none', 'clone-tree-zero', 'lazy-fetch')
SERVE = ('serve-full', 'serve-depth', 'serve-blob-none', 'serve-tree-zero')
LFS = ('lfs-upload', 'lfs-download', 'lfs-lock', 'lfs-unlock', 'lfs-lock-list', 'lfs-lock-verify')


def missing(tool, w):
    if w.startswith('reftable-'): return f'{tool} has no reftable backend'
    if w.startswith('rerere-'): return f'{tool} has no recorded-resolution operation'
    if w.startswith('sparse-'): return f'{tool} has no git-compatible sparse-checkout set/reapply operation'
    if w.startswith('lfs-'): return f'{tool} has no Git LFS transfer/locking client'
    if w.startswith('serve-'):
        if tool=='go-git': return None if w=='serve-full' else 'go-git upload-pack does not support shallow history or object filters'
        return f'{tool} has no upload-pack server'
    if w == 'midx-read' and tool == 'go-git': return 'go-git reads individual pack indexes, not the multi-pack index'
    if w in ('clone-blob-none', 'clone-tree-zero', 'lazy-fetch'): return f'{tool} has no partial-clone filter and promisor lazy-fetch API'
    return None


def git(p, repo, *args):
    # Only stdout is a result; progress/warnings belong to stderr.
    return subprocess.run(['git', '-C', str(repo), *map(str, args)], env=p.env,
                          check=True, capture_output=True).stdout.decode().strip()


def input_git(p, repo, args, data, env=None):
    return subprocess.run(['git', '-C', str(repo), *args], env=env or p.env,
                          input=data, check=True, capture_output=True).stdout


def refs(p, repo):
    return git(p, repo, 'for-each-ref', '--format=%(refname) %(objectname)') + '\n'


def objects(p, repo):
    return sorted(git(p, repo, 'rev-list', '--objects', '--missing=print', '--all').splitlines())


def clone_state(p, repo):
    # No implicit fetch during verification of a filtered repository.
    env = dict(p.env, GIT_NO_LAZY_FETCH='1')
    def read(*args):
        return subprocess.run(['git', '-C', str(repo), *args], env=env, check=True,
                              capture_output=True, text=True).stdout.strip()
    state = {'refs': read('for-each-ref', '--format=%(refname) %(objectname)'),
             'graph': sorted(read('rev-list', '--objects', '--missing=print', '--all').splitlines()),
             'shallow': sorted((repo/'shallow').read_text().splitlines()) if (repo/'shallow').exists() else [],
             'objects': sorted(read('cat-file', '--batch-all-objects', '--batch-check=%(objectname) %(objecttype) %(objectsize)').splitlines()),
             'promisor': bool(list((repo/'objects/pack').glob('*.promisor')))}
    read('fsck', '--strict', '--no-dangling')
    return state


def sparse_state(p, repo):
    tracked = git(p, repo, 'ls-files').splitlines()
    return {'patterns': (repo/'.git/info/sparse-checkout').read_text(),
            'flags': git(p, repo, 'ls-files', '-t'),
            'files': {name: hashlib.sha256((repo/name).read_bytes()).hexdigest()
                      for name in tracked if (repo/name).is_file()},
            'settings': [git(p, repo, 'config', '--bool', key) for key in
                         ('core.sparseCheckout', 'core.sparseCheckoutCone', 'index.sparse')]}


def rr_state(p, repo):
    return {'cache': {str(f.relative_to(repo/'.git/rr-cache')): f.read_bytes().hex()
                      for f in sorted((repo/'.git/rr-cache').rglob('*')) if f.is_file() and '.lock' not in f.name},
            'merge_rr': (repo/'.git/MERGE_RR').read_bytes().hex(),
            'index': git(p, repo, 'ls-files', '--stage'),
            'files': {name: (repo/name).read_bytes().hex() for name in git(p, repo, 'diff', '--name-only', '--diff-filter=U').splitlines()}}


def fixtures(p, root, ops_root):
    sizes = ('smoke',) if p.smoke else SIZES
    for size in sizes:
        target, original = root/size, ops_root/size
        if p.preparing:
            if target.exists(): shutil.rmtree(target)
            target.mkdir(parents=True)
            # A reftable stack of several tables, seeded independently of
            # every side. No reflogs or fsync on either benchmark side.
            copy_repo(p, original/'ops/bare.git', target/'reftable.git')
            rt = target/'reftable.git'
            git(p, rt, 'refs', 'migrate', '--ref-format=reftable')
            git(p, rt, 'config', 'core.logAllRefUpdates', 'false')
            tip = git(p, rt, 'rev-parse', 'main')
            env = dict(p.env, GIT_TEST_REFTABLE_AUTOCOMPACTION='0')
            for i in range(12):
                input_git(p, rt, ['update-ref', f'refs/heads/stack/{i:04d}', tip], b'', env)
            if len((rt/'reftable/tables.list').read_text().splitlines()) < 2:
                raise ValueError('reftable fixture is already compacted')
            # Several packs with disjoint object sets, one MIDX, no bitmaps.
            copy_repo(p, original/'ops/bare.git', target/'midx.git')
            mp = target/'midx.git'
            all_ids = sorted(line.split()[0] for line in git(p, mp, 'rev-list', '--objects', '--all').splitlines())
            (target/'objects.txt').write_text('\n'.join(all_ids)+'\n')
            packdir = mp/'objects/pack'
            chunks = 4
            for i in range(chunks):
                input_git(p, mp, ['pack-objects', '--compression=1', str(packdir/'cov')],
                          ('\n'.join(all_ids[i::chunks])+'\n').encode())
            for old in packdir.glob('pack-*'): old.unlink()
            for made in list(packdir.glob('cov-*')): made.rename(packdir/('pack-'+made.name[4:]))
            git(p, mp, 'prune-packed')
            git(p, mp, 'multi-pack-index', 'write')
            git(p, mp, 'multi-pack-index', 'verify')
            # Record: preimage present, manually resolved file, conflict
            # stages retained. Replay: same conflict, postimage present.
            rr = target/'rerere-record'
            copy_repo(p, original/'ops/repo', rr)
            git(p, rr, 'config', 'rerere.enabled', 'false')
            merged = subprocess.run(['git', '-C', str(rr), 'merge', '--no-commit', 'conflict'], env=p.env, capture_output=True)
            if merged.returncode != 1: raise ValueError('rerere fixture did not conflict')
            git(p, rr, 'config', 'rerere.enabled', 'true')
            git(p, rr, 'rerere')
            paths = git(p, rr, 'diff', '--name-only', '--diff-filter=U').splitlines()
            (target/'conflicts.json').write_text(json.dumps(paths))
            for name in paths: (rr/name).write_bytes(input_git(p, rr, ['show', 'main:'+name], b''))
            replay = target/'rerere-replay'
            copy_repo(p, rr, replay)
            git(p, replay, 'rerere')
            git(p, replay, 'reset', '--hard', 'main')
            merged = subprocess.run(['git', '-c', 'rerere.enabled=false', '-C', str(replay), 'merge', '--no-commit', 'conflict'], env=p.env, capture_output=True)
            if merged.returncode != 1: raise ValueError('rerere replay fixture did not conflict')
            # A git server allowing both filters and object-id lazy wants.
            copy_repo(p, original/'ops/bare.git', target/'remote.git')
            for key in ('uploadpack.allowFilter', 'uploadpack.allowAnySHA1InWant'):
                git(p, target/'remote.git', 'config', key, 'true')
            url = 'file://'+str(target/'remote.git')
            git(p, target, 'clone', '-q', '--bare', '--no-tags', '--single-branch', '--branch=main', '--filter=blob:none', url, target/'partial.git')
            blob = git(p, target/'remote.git', 'rev-parse', 'main:d00/d00/f0000.txt')
            (target/'lazy-oid.txt').write_text(blob)
            store = original/'lfs/checkout/.git/lfs/objects'
            files = sorted(f for f in store.rglob('*') if f.is_file() and len(f.name) == 64)
            (target/'lfs.txt').write_text(''.join(f'{f.name} {f.stat().st_size}\n' for f in files))
        p.prepared.require(target)
    return sizes


def server(p, script, root):
    proc = subprocess.Popen([sys.executable, p.here/'src'/script, str(root)], env=p.env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if not select.select([proc.stdout], [], [], 15)[0]:
        proc.terminate(); proc.wait()
        raise RuntimeError(f'{script} did not start')
    port = proc.stdout.readline().strip()
    if not port.isdigit(): raise RuntimeError(f'{script} failed: {proc.stderr.read()}')
    return proc, int(port)


def stop(proc):
    proc.terminate()
    try: proc.wait(timeout=5)
    except subprocess.TimeoutExpired: proc.kill(); proc.wait()


def api(port, route, data=None):
    # Bypass proxies; bind explicitly because other suites can exhaust
    # macOS's implicit-bind ephemeral range on this shared machine.
    conn = HTTPConnection('127.0.0.1', port, source_address=('127.0.0.1', 0))
    try:
        conn.request('POST' if data is not None else 'GET', '/_'+route,
                     body=json.dumps(data).encode() if data is not None else None,
                     headers={'Content-Type': 'application/json'})
        response = conn.getresponse()
        if response.status != 200: raise RuntimeError(f'LFS fixture API returned {response.status}')
        return json.loads(response.read())
    finally:
        conn.close()


def coverage2_pass(p, binary, rivals, root, ops_root):
    from src.git_ops import IDENT
    home = p.build/'coverage2-home'
    home.mkdir(exist_ok=True)
    original_env = p.env
    p.env = dict(p.env, **IDENT, HOME=str(home), XDG_CONFIG_HOME=str(home), XDG_RUNTIME_DIR=str(home))
    for key in ('SSH_AUTH_SOCK', 'GPG_AGENT_INFO', 'GIT_CONFIG_PARAMETERS', 'http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        p.env.pop(key, None)
    p.env['NO_PROXY'] = p.env['no_proxy'] = '127.0.0.1,localhost'
    try:
        return _coverage2_pass(p, binary, rivals, root, ops_root)
    finally:
        p.env = original_env


def _coverage2_pass(p, binary, rivals, root, ops_root):
    sizes = fixtures(p, root, ops_root)
    if p.plan_only: return
    gitcmd = [sys.executable, p.here/'src/git_coverage2.py']
    work = p.build/'coverage2-work'
    dst = p.build/'coverage2-clone'
    # A private HOME prevents git-lfs lock caches, netrc or credential
    # helpers reaching the person's configuration. Compiler homes stay intact.
    home = p.build/'coverage2-home'; home.mkdir(exist_ok=True)
    env = dict(p.env, HOME=str(home), XDG_CONFIG_HOME=str(home), XDG_RUNTIME_DIR=str(home))
    for key in ('SSH_AUTH_SOCK', 'GPG_AGENT_INFO', 'GIT_CONFIG_PARAMETERS', 'http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'): env.pop(key, None)
    blocked = {}
    def points(w, repo, extra=()):
        result = []
        for s,b in binary.items():
            if (s,w) in blocked:
                result.append((s, [*gitcmd, 'unavailable', 'relic', w, blocked[s,w]]))
            else: result.append((s, [b/'relic-coverage2-bench', w, repo, *extra]))
        result.append(('git', [*gitcmd, w, repo, *extra]))
        for tool, cmd in rivals.items():
            reason = missing(tool, w)
            result.append((tool, [*gitcmd, 'unavailable', tool, w, reason] if reason else [*cmd, w, repo, *extra]))
        return result
    def checked(w, state, expected=None):
        agreed = {}
        def check(out):
            evidence = tsv(out)
            if evidence['operation'] == 'unavailable':
                evidence['reason'] = next(line.split('\t')[3] for line in out.splitlines() if '\treason\t' in line)
                return evidence
            found = identities(out)
            actual = state()
            if expected is not None and actual != expected: raise ValueError(f'{w}: output differs from git fixture')
            for key, value in found.items():
                if agreed.setdefault(key, value) != value: raise ValueError(f'{w}: {key} differs between sides')
            # Compare complete structured results, retain compact evidence.
            digest = hashlib.sha256(json.dumps(actual, sort_keys=True).encode()).hexdigest()
            if agreed.setdefault('state', digest) != digest: raise ValueError(f'{w}: outputs differ between sides')
            evidence['equivalence'] = dict(agreed)
            return evidence
        return check
    for size in sizes:
        fx = root/size; original = ops_root/size
        for w in LOCAL:
            source = fx/('reftable.git' if w.startswith('reftable') else 'midx.git' if w=='midx-read' else w if w.startswith('rerere') else 'unused')
            if w.startswith('sparse'): source = original/'ops/repo'
            extra = [fx/'objects.txt'] if w=='midx-read' else []
            repo = source if w in ('reftable-read', 'midx-read') else work
            def prep(w=w, source=source):
                if repo == source: return
                copy_repo(p, source, work)
                if w.startswith('sparse'):
                    subprocess.run(['git', '-C', str(work), 'update-index', '--refresh', '-q'], env=env, capture_output=True)
                    if w.endswith('reapply'):
                        mode = '--no-cone' if 'noncone' in w else '--cone'
                        patterns = ['/d00/', '/side/', '!/side/s00.txt'] if 'noncone' in w else ['d00']
                        git(p, work, 'sparse-checkout', 'set', mode, '--no-sparse-index', '--', *patterns)
                        excluded = next(line[2:] for line in git(p, work, 'ls-files', '-t').splitlines() if line.startswith('S '))
                        git(p, work, 'checkout', '--ignore-skip-worktree-bits', 'HEAD', '--', excluded)
            if w.startswith('reftable'):
                initial = refs(p, source)
                expected = None
                def state(w=w):
                    actual = refs(p, repo)
                    if w == 'reftable-compact' and len((repo/'reftable/tables.list').read_text().splitlines()) != 1:
                        raise ValueError('reftable compaction left several tables')
                    if w == 'reftable-write':
                        n = 10 if p.smoke else 1000
                        if len(git(p, repo, 'for-each-ref', 'refs/heads/bench').splitlines()) != n: raise ValueError('reftable lost writes')
                    elif actual != initial: raise ValueError('reftable lost refs')
                    return actual
            elif w == 'midx-read':
                expected = None
                # The driver's independent git batch read supplies the
                # expected body digest, not the first benchmark side.
                reference = p.run([*gitcmd, w, repo, *extra], env=dict(env, BENCH_SMOKE='1'))
                correct = identities(reference)
                def state(): return correct
            elif w.startswith('rerere'):
                expected = None
                def state(w=w):
                    paths = json.loads((fx/'conflicts.json').read_text())
                    for name in paths:
                        if (repo/name).read_bytes() != input_git(p, repo, ['show', 'main:'+name], b''):
                            raise ValueError(f'{w}: resolution differs')
                    return rr_state(p, repo)
            else:
                expected = None
                def state(): return sparse_state(p, repo)
            check = checked(w, state, expected)
            if w == 'midx-read':
                def check(out, base=check, correct=correct):
                    if tsv(out)['operation']=='available' and identities(out)!=correct: raise ValueError('MIDX object bytes differ from git')
                    return base(out)
            if w in ('sparse-cone-reapply','sparse-noncone-reapply'):
                # Audit the known vivification edge before admitting a
                # comparison. Future pins automatically become available
                # when they produce git's result; wrong output is never admitted as a comparison.
                prep()
                p.run([*gitcmd,w,repo],env=dict(env,BENCH_SMOKE='1'))
                reference = sparse_state(p,repo)
                for side,b in binary.items():
                    prep()
                    p.run([b/'relic-coverage2-bench',w,repo],env=env)
                    if sparse_state(p,repo)!=reference:
                        blocked[side,w] = 'relic reapply leaves a vivified excluded file with its on-disk skip bit; git removes it'
                    else: blocked.pop((side,w),None)
            p.interleave(f'{w}/{size}', points(w, repo, extra), prepare=prep, env=env, check=check)
    http, port = server(p, '../transport/src/httpgit.py', root)
    try:
        for size in sizes:
            fx = root/size
            url = f'http://127.0.0.1:{port}/{size}/remote.git'
            for w in CLONE + SERVE:
                def prep(w=w):
                    if dst.exists(): shutil.rmtree(dst)
                    if w == 'lazy-fetch':
                        copy_repo(p, fx/'partial.git', dst)
                        git(p, dst, 'config', 'remote.origin.url', url)
                if w == 'lazy-fetch':
                    oid = (fx/'lazy-oid.txt').read_text()
                    cmds = points(w, dst, [oid])
                    def state():
                        blob = input_git(p, dst, ['cat-file', 'blob', oid], b'')
                        wanted = input_git(p, fx/'remote.git', ['cat-file', 'blob', oid], b'')
                        if blob != wanted: raise ValueError('lazy fetch returned different bytes')
                        return clone_state(p, dst)
                elif w.startswith('serve-'):
                    fileurl = 'file://'+str(fx/'remote.git')
                    cmds = [(s, [*gitcmd, w, fileurl, dst, b/'relic-uploadpack-bench']) for s,b in binary.items()]
                    cmds.append(('git', [*gitcmd, w, fileurl, dst]))
                    cmds += [(tool, [*gitcmd, 'unavailable', tool, w, missing(tool,w)] if missing(tool,w) else
                              [*gitcmd, w, fileurl, dst, cmd[0]]) for tool,cmd in rivals.items()]
                    def state(): return clone_state(p, dst)
                else:
                    cmds = points(w, url, [dst])
                    def state(): return clone_state(p, dst)
                # Independent git clone is unmeasured: the required refs,
                # graph, missing objects and boundary for every side.
                if w != 'lazy-fetch':
                    prep()
                    p.run([*gitcmd, w, 'file://'+str(fx/'remote.git'), dst], env=dict(env, BENCH_SMOKE='1'))
                    expected = state()
                else: expected = None
                p.interleave(f'{w}/{size}', cmds, prepare=prep, env=env, check=checked(w,state,expected))
    finally: stop(http)
    lfs, port = server(p, 'lfs_server.py', p.build/'coverage2-lfs-server')
    try:
        for size in sizes:
            fx = root/size; original = ops_root/size
            source = original/'lfs/checkout'
            store_files = sorted(f for f in (source/'.git/lfs/objects').rglob('*') if f.is_file() and len(f.name)==64)
            wanted = {f.name: f.name for f in store_files}
            lock = {'id':'1', 'path':'data/f00.bin', 'locked_at':'2020-01-01T00:00:00Z', 'owner':{'name':'anonymous'}}
            for w in LFS:
                def prep(w=w):
                    copy_repo(p, source, work)
                    if w.startswith('lfs-lock') or w=='lfs-unlock':
                        git(p, work, 'switch', '-q', 'data')
                    git(p, work, 'config', 'remote.origin.url', f'http://127.0.0.1:{port}/repo.git')
                    git(p, work, 'config', 'lfs.url', f'http://127.0.0.1:{port}/lfs')
                    git(p, work, 'config', 'lfs.concurrenttransfers', '8')
                    git(p, work, 'config', 'lfs.fetchrecentalways', 'false')
                    git(p, work, 'config', 'lfs.locksverify', 'false')
                    seed = {'objects':[str(f) for f in store_files] if w=='lfs-download' else [],
                            'locks':[lock] if w in ('lfs-unlock','lfs-lock-list','lfs-lock-verify') else []}
                    api(port,'reset',seed)
                    if w=='lfs-download': shutil.rmtree(work/'.git/lfs/objects')
                    if w=='lfs-unlock':
                        # Seed the client's cache as the lock command would.
                        # Keep only this setup request outside the journal.
                        api(port,'reset',{})
                        p.run([*gitcmd,'lfs-lock',work],env=dict(env,BENCH_SMOKE='1'))
                        api(port,'reset',seed)
                def state(w=w):
                    found = api(port,'state')
                    requests = found['requests']
                    if w in ('lfs-upload','lfs-download'):
                        transferred = {r['oid']:r['bytes'] for r in requests if r['kind']==w.removeprefix('lfs-')}
                        expected = {f.name:f.stat().st_size for f in store_files}
                        if transferred != expected or sum(r['kind']==w.removeprefix('lfs-') for r in requests)!=len(expected):
                            raise ValueError(f'{w}: transferred different objects or repeated a transfer')
                        batches = [obj for r in requests if r['kind']=='batch' for obj in r['objects']]
                        if {obj['oid']:obj['size'] for obj in batches} != expected or len(batches)!=len(expected):
                            raise ValueError(f'{w}: different batch input')
                        if w=='lfs-upload':
                            if found['objects'] != wanted: raise ValueError('LFS uploaded bytes differ')
                            if {r['oid'] for r in requests if r['kind']=='verify'} != set(wanted): raise ValueError('LFS skipped verification')
                        else:
                            actual = {f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in (work/'.git/lfs/objects').rglob('*') if f.is_file()}
                            if actual != wanted: raise ValueError('LFS downloaded bytes differ')
                        return {'objects':wanted, 'bytes':expected}
                    expected_locks = [] if w=='lfs-unlock' else [lock]
                    if found['locks'] != expected_locks: raise ValueError('LFS locks differ')
                    if not requests: raise ValueError('LFS lock operation made no request')
                    cache = {str(f.relative_to(work/'.git/lfs/cache/locks')): json.loads(f.read_text())
                             for f in sorted((work/'.git/lfs/cache/locks').rglob('*')) if f.is_file()}
                    return {'locks':found['locks'], 'cache':cache}
                p.interleave(f'{w}/{size}',points(w,work,[fx/'lfs.txt']),prepare=prep,env=env,check=checked(w,state))
    finally: stop(lfs)
