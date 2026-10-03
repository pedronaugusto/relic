"""Quiet-pass checks and report names; only temporary files, no timings."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from quiet import check_packwrite, reset_pack_outputs
from quiet_common import Pass, tsv

HERE = Path(__file__).resolve().parent

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

    def test_a_streamed_pack_is_reported_as_not_kept(self):
        with tempfile.TemporaryDirectory() as name:
            s = Scratch(Path(name))
            evidence = check_packwrite(tsv(output('libgit2', 'packwrite', 'n/a')), s.repo, s.scratch, s.run)
            self.assertEqual(s.calls, [])
            self.assertEqual(evidence['pack_verification'], 'not kept: streamed to a byte count')

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

def bare_pass(out, smoke=False, prepare_only=False, check_prepared=False):
    """A pass that only saves: no builds, snapshots or git calls."""
    p = Pass.__new__(Pass)
    p.here, p.repo, p.build, p.out = HERE, HERE.parent, out/'build', out
    p.args = argparse.Namespace(smoke=smoke, prepare_only=prepare_only, check_prepared=check_prepared)
    p.smoke = smoke
    p.preparing = smoke or prepare_only
    p.plan_only = prepare_only or check_prepared
    p.revisions = {'before': '0' * 40, 'after': '1' * 40}
    p.metadata, p.machine, p.rows, p.complete = {}, {}, [], False
    p.git = lambda *args: ''
    return p

class ReportNameTests(unittest.TestCase):
    def test_smoke_preparation_and_checks_leave_a_quiet_report_alone(self):
        with tempfile.TemporaryDirectory() as name:
            out = Path(name)
            quiet = {'report.json': '{"mode": "benchmark"}\n', 'report.md': '# Quiet benchmark\n'}
            for file, text in quiet.items(): (out/file).write_text(text)
            # What a default smoke run does: its preparation subprocess, then
            # the smoke itself; and a later preparation check.
            for mode in ({'prepare_only': True}, {'smoke': True}, {'check_prepared': True}):
                bare_pass(out, **mode).save()
            for file, text in quiet.items(): self.assertEqual((out/file).read_text(), text)

    def test_a_quiet_pass_writes_the_report(self):
        with tempfile.TemporaryDirectory() as name:
            out = Path(name)
            bare_pass(out).save()
            self.assertTrue((out/'report.json').is_file())
            self.assertTrue((out/'report.md').is_file())

if __name__ == '__main__': unittest.main()
