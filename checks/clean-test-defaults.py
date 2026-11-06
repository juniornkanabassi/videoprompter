#!/usr/bin/env python3
"""Remove exactly the defaults suites a finished XCTest process recorded.
Usage: python3 checks/clean-test-defaults.py MANIFEST
Run only after the test process has exited (checks/run-xctest.sh does this). Every name is checked
before anything is deleted; one bad name fails the run with nothing removed. For each suite,
`defaults delete` makes cfprefsd drop its cached domain, then the exact plist is unlinked. No
patterns, no other folder and no cfprefsd restart.
"""
import pathlib, re, subprocess, sys, time

UUID = r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
# A test's own name: dotted words ending in a fresh UUID, or AppStore's derived per-directory suite.
TEST_SUITE = re.compile(r'[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)*\.' + UUID)
DERIVED_SUITE = re.compile(r'VidPrompt\.[0-9a-f]{16}')
PRODUCTION = {'com.juniornkanabassi.VidPrompt', 'com.juniornkanabassi.VideoPrompter'}

def allowed(name):
    if not name or name.startswith('.') or '/' in name or '\0' in name or name.lower().startswith('com.apple.'):
        return False
    if name in PRODUCTION or name.startswith('com.juniornkanabassi.'):
        return False
    return bool(TEST_SUITE.fullmatch(name) or DERIVED_SUITE.fullmatch(name))

def self_test():
    uuid = '0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9'
    for name in ['BarCentre.' + uuid, 'VideoPrompterTests.cleanup.' + uuid.lower(), 'VidPrompt.0123456789abcdef',
                 'VideoPrompter.rendered-replay.' + uuid]:
        assert allowed(name), name
    for name in ['', '.GlobalPreferences', 'com.apple.finder.' + uuid, 'com.juniornkanabassi.VidPrompt',
                 'com.juniornkanabassi.VidPrompt.check', '../x.' + uuid, 'a/b.' + uuid, 'BarCentre',
                 'VidPrompt.0123', 'VidPrompt.0123456789ABCDEF', 'x.' + uuid + '.plist']:
        assert not allowed(name), name
    print('clean-test-defaults self-test passed')
    return 0

def main():
    if sys.argv[1:] == ['--self-test']:
        return self_test()
    if len(sys.argv) != 2:
        sys.exit('usage: clean-test-defaults.py MANIFEST')
    manifest = pathlib.Path(sys.argv[1])
    if not manifest.exists():
        return 0  # the process never opened a suite
    names = list(dict.fromkeys(line.strip() for line in manifest.read_text().splitlines() if line.strip()))
    bad = [name for name in names if not allowed(name)]
    if bad:
        sys.exit('Refusing a manifest with names that are not test suites: %r' % bad)
    folder = pathlib.Path.home() / 'Library' / 'Preferences'
    for name in names:
        # Exit status ignored: "Domain not found" is the usual, harmless answer.
        subprocess.run(['/usr/bin/defaults', 'delete', name], capture_output=True, timeout=30)
        (folder / (name + '.plist')).unlink(missing_ok=True)
    time.sleep(1)  # cfprefsd can write a final empty plist shortly after the process exits
    left = [name for name in names if (folder / (name + '.plist')).exists()]
    for name in left:
        subprocess.run(['/usr/bin/defaults', 'delete', name], capture_output=True, timeout=30)
        (folder / (name + '.plist')).unlink(missing_ok=True)
    if left:
        time.sleep(1)
    still = [name for name in names if (folder / (name + '.plist')).exists()]
    if still:
        sys.exit('Test defaults files remain after cleanup: %r' % still)
    print('Removed %d test defaults suites' % len(names), file=sys.stderr)
    return 0

if __name__ == '__main__':
    sys.exit(main())
