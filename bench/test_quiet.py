"""Quiet-pass pack checks; only temporary files, no timings."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from quiet import check_packwrite, reset_pack_outputs
from quiet_common import tsv

def git_env(home):
    """Git with nothing of the person's: no global or system config, a scratch home."""
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(HOME=str(home), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0',
               GIT_CEILING_DIRECTORIES=str(Path(home).parent.parent))
    return env

def output(tool, workload, deltas):
    """A pack-writing point's five-column output, with `deltas` as reported."""
    return ''.join(f'{tool}\t{workload}\t{metric}\t{value}\t{unit}\n' for metric, value, unit in (
        ('time', '1.000', 'ms'), ('pack_bytes', '100.000', 'bytes'), ('objects', '1.000', 'count'),
        ('deltas', deltas, 'n/a' if deltas == 'n/a' else 'count')))

class Scratch:
    """A loose repository's pack directory and the comparison writers' scratch."""
    def __init__(self, root):
        self.root = root
        self.repo = root/'loose'
        self.packs = self.repo/'.git/objects/pack'
        self.packs.mkdir(parents=True)
        self.scratch = root
        self.env = git_env(root/'home')
        (root/'home').mkdir()
        self.calls = []

    def run(self, argv):
        self.calls.append([str(a) for a in argv])
        subprocess.run([str(a) for a in argv], cwd=self.root, env=self.env, check=True, capture_output=True)

    def valid_pack(self, dst):
        """A real one-blob pack written by git, at `dst`."""
        source = self.root/'source'
        subprocess.run(['git', 'init', '-q', str(source)], env=self.env, check=True)
        oid = subprocess.run(['git', '-C', str(source), 'hash-object', '-w', '--stdin'], input=b'pack me\n',
                             env=self.env, check=True, capture_output=True).stdout
        base = self.root/'made'
        subprocess.run(['git', '-C', str(source), 'pack-objects', '-q', str(base)], input=oid,
                       env=self.env, check=True, capture_output=True)
        made = next(self.root.glob('made-*.pack'))
        made.rename(dst)
        for rest in self.root.glob('made-*'): rest.unlink()

class PackCheckTests(unittest.TestCase):
    def test_an_unavailable_metric_still_validates_the_written_pack(self):
        # gix, git, libgit2 and go-git all write a pack and report `deltas` n/a.
        with tempfile.TemporaryDirectory() as name:
            s = Scratch(Path(name))
            (s.packs/'pack-broken.pack').write_bytes(b'PACK but not one')
            with self.assertRaises(subprocess.CalledProcessError):
                check_packwrite(tsv(output('gix', 'packwrite', 'n/a')), s.repo, s.scratch, s.run)

    def test_an_unavailable_operation_writes_nothing_to_validate(self):
        with tempfile.TemporaryDirectory() as name:
            s = Scratch(Path(name))
            evidence = check_packwrite(tsv('gix\tpackwrite\ttime\tn/a\tn/a\n'), s.repo, s.scratch, s.run)
            self.assertEqual(s.calls, [])
            self.assertNotIn('pack_verification', evidence)

    def test_every_written_pack_is_validated_including_gix(self):
        with tempfile.TemporaryDirectory() as name:
            s = Scratch(Path(name))
            s.valid_pack(s.scratch/'gix.pack')
            evidence = check_packwrite(tsv(output('gix', 'packwrite', '0')), s.repo, s.scratch, s.run)
            self.assertEqual(evidence['pack_verification'], 'passed')
            self.assertEqual([Path(c[-1]).name for c in s.calls], ['gix.pack'])
            self.assertEqual(s.calls[0][:3], ['git', 'index-pack', '--strict'])
            # A broken gix pack beside a good one fails the point.
            (s.scratch/'gix.pack').unlink()
            (s.scratch/'gix.pack').write_bytes(b'PACK but not one')
            s.valid_pack(s.packs/'pack-good.pack')
            with self.assertRaises(subprocess.CalledProcessError):
                check_packwrite(tsv(output('gix', 'packwrite', '0')), s.repo, s.scratch, s.run)

    def test_reset_removes_every_writer_pack_and_its_index(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            left = ['gitpack-1.pack', 'gitpack-1.idx', 'gix.pack', 'gix.idx', 'gogit.pack', 'gogit.idx']
            for file in left + ['index.gogit']: (root/file).write_bytes(b'x')
            (root/'loose').mkdir()
            reset_pack_outputs(root)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['index.gogit', 'loose'])

if __name__ == '__main__': unittest.main()
