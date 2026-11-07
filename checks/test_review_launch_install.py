import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class ReviewLaunchInstall(unittest.TestCase):
    def test_running_check_targets_launched_copy(self):
        source = (ROOT / 'Sources/VideoPrompterCLI/main.swift').read_text()
        line = next(line for line in source.splitlines() if '&& !appRunning(' in line)
        self.assertIn('exact: launchApp.map', line)

    def test_failed_backup_removal_reports_failure(self):
        script = (ROOT / 'install.sh').read_text()
        block = script[script.index('if [[ -e "$BACKUP" ]] && ! /bin/rm -rf "$BACKUP"; then'):]
        block = block[:block.index('\nfi') + 3]
        with tempfile.TemporaryDirectory(dir='/private/tmp') as folder:
            backup = pathlib.Path(folder) / 'old.app'
            backup.mkdir()
            locked = backup / 'locked'
            locked.write_text('old')
            subprocess.run(['/usr/bin/chflags', 'uchg', str(locked)], check=True)
            try:
                result = subprocess.run(['/bin/zsh', '-c', block], env={'BACKUP': str(backup), 'ACTUAL_VERSION': 'test'}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('It is kept at', result.stderr)
            finally:
                subprocess.run(['/usr/bin/chflags', 'nouchg', str(locked)], check=False)

if __name__ == '__main__':
    unittest.main()
