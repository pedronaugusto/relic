"""Every named comparison belongs to exactly one Windows shard."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def corpus_names():
    names = []
    for path in (ROOT / 'src').rglob('*.zig'):
        for name in re.findall(r'^test "([^"]+)"', path.read_text(), re.M):
            if ': seed ' in name or 'random corpus' in name:
                names.append(name)
    return names


def owner(name):
    if 'random corpus of three-way merges' in name:
        return 'merge-file'
    if 'diffs land on the lines' in name:
        return 'diff-algorithms'
    seed = int(re.search(r': seed (\d+)', name).group(1))
    if name.startswith('random histories'):
        return f'history-{seed % 8}'
    if name.startswith('criss-cross histories'):
        return f'recursive-{seed % 3}'
    if name.startswith('diff -M'):
        return f'rename-{seed % 6}'
    if name.startswith('a walk comes out'):
        return 'revwalk'
    raise AssertionError(f'unassigned corpus: {name}')


class Cases(unittest.TestCase):
    def test_windows_matrix_covers_every_named_comparison(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('  windows:\n', workflow)
        windows = workflow.split('  windows:\n', 1)[1].split('\n  # ReleaseSmall', 1)[0]
        matrix = re.search(r'case: \[([^]]+)\]', windows).group(1).split(', ')
        names = corpus_names()
        self.assertEqual(180, len(names))
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(set(matrix), {owner(name) for name in names})
        self.assertEqual(len(matrix), len(set(matrix)))
        self.assertIn('optimize: [Debug, ReleaseSafe]', windows)
        self.assertIn('-Dtest-case=${{ matrix.case }}', windows)
        self.assertIn('--test-timeout 60s', windows)
        self.assertNotIn('windows-latest', workflow.split('  windows-core:\n', 1)[0].split('matrix:', 1)[1])

    def test_build_and_workflow_name_the_same_cases(self):
        source = (ROOT / 'ci/test_cases.zig').read_text().split('pub const cases =', 1)[1].split('};', 1)[0]
        cases = re.findall(r'"([^"]+)"', source)
        workflow = (ROOT / '.github/workflows/ci.yml').read_text().split('  windows:\n', 1)[1]
        self.assertEqual(cases, ['core'] + re.search(r'case: \[([^]]+)\]', workflow).group(1).split(', '))

    def test_core_can_start_before_comparison_jobs(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertTrue('  windows-core:\n' in workflow, 'core jobs must start independently of the comparison matrix')
        core = workflow.split('  windows-core:\n', 1)[1].split('\n  windows:\n', 1)[0]
        comparisons = workflow.split('  windows:\n', 1)[1].split('\n  # ReleaseSmall', 1)[0]
        self.assertNotIn('needs:', core)
        self.assertIn('needs: source', comparisons)
        self.assertIn('optimize: [Debug, ReleaseSafe]', core)
        self.assertIn('-Dtest-case=core', core)
        self.assertIn('--test-timeout 60s', core)
        self.assertNotIn('core', re.search(r'case: \[([^]]+)\]', comparisons).group(1).split(', '))

    def test_filters_are_checked_by_exact_names(self):
        selection = (ROOT / 'src/test_case.zig').read_text()
        self.assertIn('std.mem.eql(u8, name, chosen)', selection)
        for path in (ROOT / 'src').rglob('*.zig'):
            text = path.read_text()
            for name in re.findall(r'^test "([^"]+)"', text, re.M):
                if ': seed ' in name or 'random corpus' in name:
                    self.assertIn(f'selected("{name}")', text)


if __name__ == '__main__':
    unittest.main()
