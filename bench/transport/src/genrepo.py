#!/usr/bin/env python3
"""A deterministic fast-import stream: <files> files of ~<size> bytes in a
tree of depth 3, one commit adding them, then <commits> commits each
changing <touch> files by one line. Seeded, fixed identities and dates."""
import random, sys
files, size, commits, touch, extra = map(int, sys.argv[1:6])
rng = random.Random(1234)
words = [''.join(rng.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(rng.randint(2, 9))) for _ in range(2000)]
def text(n):
    out, total = [], 0
    while total < n:
        line = ' '.join(rng.choice(words) for _ in range(12))
        out.append(line); total += len(line) + 1
    return out
paths = []
for i in range(files):
    paths.append('d%02d/d%02d/f%04d.txt' % (i % 37, (i // 37) % 23, i))
contents = {p: text(size) for p in paths}
w = sys.stdout.buffer
t = 1_600_000_000
def blob(data):
    w.write(b'data %d\n' % len(data)); w.write(data); w.write(b'\n')
def commit(mark, parent, changes, msg):
    global t
    t += 3600
    w.write(b'commit refs/heads/main\nmark :%d\n' % mark)
    w.write(b'committer C <c\x40example.invalid> %d +0000\n' % t)
    blob_msg = msg.encode()
    w.write(b'data %d\n%s\n' % (len(blob_msg), blob_msg))
    if parent: w.write(b'from :%d\n' % parent)
    for p in changes:
        data = ('\n'.join(contents[p]) + '\n').encode()
        w.write(b'M 100644 inline %s\n' % p.encode()); blob(data)
    w.write(b'\n')
commit(1, 0, paths, 'add')
total = commits + extra
for c in range(total):
    changed = rng.sample(paths, touch)
    for p in changed:
        lines = contents[p]; lines[rng.randrange(len(lines))] = ' '.join(rng.choice(words) for _ in range(12))
    commit(c + 2, c + 1, changed, 'change %d' % c)
    if c + 1 == commits:
        w.write(b'reset refs/tags/base\nfrom :%d\n\n' % (c + 2))
w.write(b'done\n')
