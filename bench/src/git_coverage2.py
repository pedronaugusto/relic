"""Git CLI points for the second coverage pass; startup is included.
Smoke uses git_ops' synthetic clock. Every result is checked by the pass.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from git_ops import benchmark_clock


def emit(side, w, metric, value, unit):
    print(f'{side}\t{w}\t{metric}\t{value}\t{unit}')


def main():
    w, repo, *extra = sys.argv[1:]
    if w == 'unavailable':
        side, workload, reason = repo, *extra
        emit(side, workload, 'time', 'unavailable', 'ms')
        emit(side, workload, 'reason', reason, 'text')
        return
    def git(*args, data=None):
        return subprocess.run(['git', '-C', repo, *args], input=data, check=True,
                              capture_output=True).stdout
    def lock_digest(locks):
        return hashlib.sha1(b''.join('\x00'.join((lock['id'],lock['path'],(lock.get('owner') or {}).get('name',''),lock.get('locked_at',''))).encode()+b'\x00\n' for lock in locks)).hexdigest()
    start = benchmark_clock()
    metrics = {}
    if w == 'reftable-read':
        metrics['digest'] = hashlib.sha1(git('for-each-ref', '--format=%(refname) %(objectname)')).hexdigest()
    elif w == 'reftable-write':
        count = 10 if os.environ.get('BENCH_SMOKE') == '1' else 1000
        tip = git('rev-parse', 'main').decode().strip()
        commands = ''.join(f'create refs/heads/bench/b{i:04d} {tip}\n' for i in range(count))
        git('update-ref', '--stdin', data=commands.encode())
        metrics['items'] = count
    elif w == 'reftable-compact':
        git('pack-refs', '--all')
    elif w == 'midx-read':
        ids = Path(extra[0]).read_bytes()
        # Read each object body (not only its header), through the same MIDX.
        out = git('cat-file', '--batch', data=ids)
        pos, count, digest = 0, 0, hashlib.sha1()
        for oid in ids.splitlines():
            end = out.index(b'\n', pos)
            name, kind, length = out[pos:end].split()
            assert name == oid
            length = int(length)
            pos = end + 1
            digest.update(out[pos:pos+length])
            pos += length + 1
            count += 1
        assert pos == len(out)
        metrics.update(items=count, digest=digest.hexdigest())
    elif w.startswith('rerere-'):
        git('rerere')
    elif w.startswith('sparse-'):
        mode = '--no-cone' if 'noncone' in w else '--cone'
        if w.endswith('set'):
            patterns = ['/d00/', '/side/', '!/side/s00.txt'] if 'noncone' in w else ['d00']
            git('sparse-checkout', 'set', mode, '--no-sparse-index', '--', *patterns)
        else:
            git('sparse-checkout', 'reapply', mode, '--no-sparse-index')
    elif w.startswith('clone-') or w.startswith('serve-'):
        command = ['git', '-c', 'protocol.version='+('0' if w.startswith('serve-') else '2'), 'clone', '-q', '--bare', '--single-branch', '--branch=main', '--no-tags']
        if 'depth' in w: command += ['--depth=3']
        if 'blob-none' in w: command += ['--filter=blob:none']
        if 'tree-zero' in w: command += ['--filter=tree:0']
        if w.startswith('serve-') and len(extra) > 1: command += ['--upload-pack='+extra[1]]
        subprocess.run([*command, repo, extra[0]], check=True, capture_output=True)
    elif w == 'lazy-fetch':
        out = git('cat-file', 'blob', extra[0])
        metrics['digest'] = hashlib.sha1(out).hexdigest()
    elif w == 'lfs-upload':
        ids = [line.split()[0] for line in Path(extra[0]).read_text().splitlines()]
        git('lfs', 'push', '--object-id', 'origin', *ids)
        metrics['items'] = len(ids)
    elif w == 'lfs-download':
        git('lfs', 'fetch', 'origin', 'data')
    elif w == 'lfs-lock':
        out = __import__('json').loads(git('lfs', 'lock', '--json', 'data/f00.bin'))
        metrics['digest'] = lock_digest([out.get('lock',out)])
    elif w == 'lfs-unlock':
        out = __import__('json').loads(git('lfs', 'unlock', '--json', 'data/f00.bin'))
        metrics['digest'] = lock_digest([out.get('lock',out)])
    elif w in ('lfs-lock-list', 'lfs-lock-verify'):
        import json
        args = ['lfs', 'locks', '--json'] + (['--verify'] if w.endswith('verify') else [])
        locks = json.loads(git(*args))
        metrics['digest'] = lock_digest(locks if isinstance(locks,list) else locks.get('ours',[]) + locks.get('theirs',[]))
        metrics['items'] = len(locks) if isinstance(locks, list) else len(locks.get('ours', [])) + len(locks.get('theirs', []))
    else:
        raise ValueError(w)
    emit('git', w, 'time', (benchmark_clock()-start)*1000, 'ms')
    for metric, value in metrics.items():
        emit('git', w, metric, value, 'oid' if metric == 'digest' else 'count')


if __name__ == '__main__':
    main()
