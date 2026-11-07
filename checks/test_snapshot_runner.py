"""The snapshot runner cleans temporary outputs on success and failure, retaining chosen evidence."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check-snapshots.sh')


class SnapshotRunnerTests(unittest.TestCase):
    def run_fixture(self, fail=False, explicit=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'checks').mkdir()
            shutil.copyfile(SCRIPT, root / 'checks/check-snapshots.sh')
            (root / 'env.sh').write_text('SWIFT=/usr/bin/false\nXCTEST=/usr/bin/true\n')
            (root / 'checks/run-xctest.sh').write_text(
                'print -r -- "$VIDEOPROMPTER_SNAPSHOTS" > "$TRACK"\n'
                'touch "$VIDEOPROMPTER_SNAPSHOTS/evidence.png"\n'
                'exit "$FAIL"\n')
            env = dict(os.environ, TRACK=str(root / 'track'), FAIL='1' if fail else '0')
            env.pop('VIDEOPROMPTER_SNAPSHOTS', None)
            if explicit:
                (root / 'chosen').mkdir()
                env['VIDEOPROMPTER_SNAPSHOTS'] = str(root / 'chosen')
            result = subprocess.run(['zsh', str(root / 'checks/check-snapshots.sh'), 'existing.xctest'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1 if fail else 0, result.stderr)
            output = Path((root / 'track').read_text().strip())
            self.assertEqual(output.exists(), explicit)
            if explicit: self.assertTrue((output / 'evidence.png').exists())

    def test_temporary_output_is_removed_after_success(self): self.run_fixture()
    def test_temporary_output_is_removed_after_failure(self): self.run_fixture(fail=True)
    def test_chosen_evidence_is_kept_after_success(self): self.run_fixture(explicit=True)
    def test_chosen_evidence_is_kept_after_failure(self): self.run_fixture(fail=True, explicit=True)

    def test_direct_run_keeps_its_temporary_output_to_look_at(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'checks').mkdir()
            shutil.copyfile(SCRIPT, root / 'checks/check-snapshots.sh')
            (root / 'env.sh').write_text('SWIFT=/usr/bin/true\nXCTEST=/usr/bin/true\n')
            (root / 'checks/check-grid.py').write_text('')
            (root / 'checks/run-xctest.sh').write_text('print -r -- "$VIDEOPROMPTER_SNAPSHOTS" > "$TRACK"\n')
            env = dict(os.environ, TRACK=str(root / 'track'), VIDEOPROMPTER_TEST_SCRATCH=str(root / 'cache'))
            env.pop('VIDEOPROMPTER_SNAPSHOTS', None)
            result = subprocess.run(['zsh', str(root / 'checks/check-snapshots.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = Path((root / 'track').read_text().strip())
            self.assertTrue(output.exists(), output)
            shutil.rmtree(output)


    def test_normal_and_filtered_test_runs_route_snapshots(self):
        for filtered in (False, True):
            with self.subTest(filtered=filtered), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'checks').mkdir()
                shutil.copyfile(SCRIPT.parent.parent / 'test.sh', root / 'test.sh')
                (root / 'env.sh').write_text('')
                swift = root / 'swift'
                swift.write_text('#!/bin/zsh\nprint -r -- "$FAKE_BUNDLE"\n')
                swift.chmod(0o700)
                for name in ['test_capture_safety.py', 'test_check_grid.py', 'test_snapshot_runner.py', 'check-grid.py']:
                    (root / 'checks' / name).write_text('')
                (root / 'checks/run-xctest.sh').write_text('print "tests:$VIDEOPROMPTER_SNAPSHOTS" >> "$TRACK"\n')
                (root / 'checks/check-snapshots.sh').write_text('print "snapshots:$1" >> "$TRACK"\n')
                env = dict(os.environ, SWIFT=str(swift), XCTEST='/usr/bin/true',
                           VIDEOPROMPTER_TEST_SCRATCH=str(root / 'cache'),
                           FAKE_BUNDLE=str(root / 'bin'), TRACK=str(root / 'track'),
                           VIDEOPROMPTER_SNAPSHOTS=str(root / 'chosen'))
                args = ['-XCTest', 'SomeTest'] if filtered else []
                result = subprocess.run(['zsh', str(root / 'test.sh'), *args], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                # A filtered snapshot test keeps the chosen evidence folder; the normal pass clears it for the main run.
                expected = [f'tests:{root}/chosen'] if filtered else ['tests:', f'snapshots:{root}/bin/PrompterCoreTests.xctest']
                self.assertEqual((root / 'track').read_text().splitlines(), expected)


if __name__ == '__main__': unittest.main()
