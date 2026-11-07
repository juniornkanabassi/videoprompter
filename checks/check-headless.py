#!/usr/bin/env python3
"""Check headless behaviour on a re-identified copy using the council's hidden launcher.
Usage: source env.sh; python3 checks/check-headless.py '/tmp/.../Video Prompter.app'
No visible mode, direct executable launch, real capture or audio playback.
"""
import json, os, pathlib, plistlib, re, shutil, statistics, subprocess, sys, tempfile, time
from agent_launch import launch

supplied = pathlib.Path(sys.argv[1]).resolve()
if len(sys.argv) != 2:
    raise SystemExit('Only an app path is accepted; visible checks are disabled')
swift = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
root = pathlib.Path(tempfile.mkdtemp(prefix='vph-', dir='/private/tmp'))
CHECK_ID = 'com.juniornkanabassi.VidPrompt.headless-check'
app = root / 'Video Prompter.app'
subprocess.run(['ditto', str(supplied), str(app)], check=True, timeout=120)
subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Set :CFBundleIdentifier '+CHECK_ID, str(app / 'Contents/Info.plist')], check=True)
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
(root / 'home').mkdir(exist_ok=True)
info['LSEnvironment'] = {'CFFIXED_USER_HOME': str(root / 'home')}
info_path.write_bytes(plistlib.dumps(info))
entitlements = plistlib.loads(subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(supplied)], capture_output=True, check=True, timeout=60).stdout or plistlib.dumps({}))
entitlements['com.apple.security.cs.disable-library-validation'] = True
(root / 'check.entitlements').write_bytes(plistlib.dumps(entitlements))
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--preserve-metadata=flags', '--entitlements', str(root / 'check.entitlements'), str(app)], check=True, timeout=120)
cli, exe = app / 'Contents/Helpers/videoprompter', app / 'Contents/MacOS/VideoPrompter'
data, idle_data = root / 'data', root / 'idle-data'
checks = 0

def check(condition, label):
    global checks
    assert condition, label
    checks += 1; print('PASS', label, flush=True)

def command(*words, directory=data):
    started = time.monotonic()
    result = subprocess.run([str(cli), '--data-directory', str(directory), *words, '--json'], capture_output=True, text=True, timeout=45)
    assert result.returncode == 0, (words, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)['result'], (time.monotonic() - started) * 1000

def pids(directory):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    return [int(row.split(None, 1)[0]) for row in rows if str(exe) in row and '--data-directory '+str(directory) in row]

def suite_domains(directory):
    """The defaults suite AppStore.preferences opens for --data-directory: VidPrompt.<FNV-1a of the standardised path>."""
    path = str(directory)
    # NSURL standardising drops a leading /private when the shorter path exists, so cover both spellings.
    for candidate in {path, path.removeprefix('/private') if path.startswith('/private/') else path}:
        value = 14695981039346656037
        for byte in candidate.encode():
            value = ((value ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        yield 'VidPrompt.%016x' % value

def activation_type(pid):
    found = re.search(r'type="(\w+)"', subprocess.run(['lsappinfo', 'info', '-app', str(pid)], capture_output=True, text=True).stdout)
    return found.group(1) if found else None

def watch(seconds):
    """Starts watch-headless.swift on the copy's executable; call the result to get (most windows at once, Dock tile)."""
    watcher = subprocess.Popen([swift, str(pathlib.Path(__file__).with_name('watch-headless.swift')), str(exe), str(seconds)],
                               stdout=subprocess.PIPE, text=True)
    assert watcher.stdout.readline().strip() == 'READY', 'the screen watcher did not start'
    def result():
        found = re.search(r'WINDOWS (\d+) DOCK (\w+)', watcher.communicate(timeout=seconds + 60)[0])
        return int(found.group(1)), found.group(2) == 'yes'
    return result

def onscreen_windows(pid):
    out = subprocess.run([swift, '-e', '''
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
print(windows.filter { $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowLayer as String] as? Int == 0
    && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }.count)''', str(pid)], capture_output=True, text=True, timeout=120)
    return int(out.stdout.strip())

try:
    check(command('status')[0]['running'] is False, 'status works while stopped without launching')
    seen = watch(4)  # the launch and a little after it, sampled every 5 ms
    launch_started = time.monotonic()
    launch(app, data, '--headless')
    _, cold = command('script', 'list')
    cold = (time.monotonic() - launch_started) * 1000
    state, _ = command('status')
    [pid] = pids(data)
    print('INFO cold command, launch included: %.0f ms' % cold)
    check(state['headless'] is True, 'the copy the command started reports headless')
    check(activation_type(pid) in ('UIElement', 'BackgroundOnly'), 'the headless copy has no Dock tile')
    windows, dock = seen()
    check(windows == 0, 'the headless launch never put a window on screen, not even for a frame (saw %d)' % windows)
    check(not dock, 'the headless launch never showed a Dock tile')
    check(onscreen_windows(pid) == 0, 'the headless copy shows no window')
    warm = [command('script', 'list')[1] for _ in range(7)]
    print('INFO warm command: median %.0f ms, slowest %.0f ms' % (statistics.median(warm), max(warm)))
    check(statistics.median(warm) < 500, 'a command to the running headless copy is quick')
    created, _ = command('script', 'create', '--title', 'Headless check', '--text', '# Headless check', '--request-id', 'headless-1')
    command('script', 'open', created['id'])
    check(command('status')[0]['headless'] is True, 'opening a script without --show keeps the copy headless')
    command('set-mode', 'manual')
    check(command('settings', 'set', '--speed', '150')[0]['speed'] == 150, 'settings command confirms the new speed')
    os.kill(pid, 15)  # No grace period after the successful settings response.
    for _ in range(100):
        if not pids(data): break
        time.sleep(0.05)
    check(not pids(data), 'SIGTERM stopped the settings writer')
    launch(app, data, '--headless')
    command('script', 'list')  # Same disposable library and preferences.
    [restarted_pid] = pids(data)
    check(command('settings', 'get')[0]['speed'] == 150, 'settings survive SIGTERM immediately after CLI success')
    check(onscreen_windows(restarted_pid) == 0, 'settings recovery remains headless')
    os.kill(restarted_pid, 15)
    for _ in range(100):
        if not pids(data): break
        time.sleep(0.05)
    # An unused headless copy quits by itself; only the authorised hidden launcher starts it.
    seen = watch(4)
    launch(app, idle_data, '--headless', '--idle-quit', '2')
    for _ in range(100):
        if (idle_data / 'control.sock').exists(): break
        time.sleep(0.1)
    check(command('status', directory=idle_data)[0]['headless'] is True, 'a hidden --headless copy is headless')
    windows, dock = seen()
    check(windows == 0 and not dock, 'a hidden --headless copy never showed a window or Dock tile (saw %d, Dock %s)' % (windows, dock))
    for _ in range(150):
        if not pids(idle_data): break
        time.sleep(0.1)
    check(not pids(idle_data), 'an unused headless copy quits by itself')

finally:
    for directory in (data, idle_data):
        for stray in pids(directory):
            try: os.kill(stray, 9)
            except ProcessLookupError: pass  # it quit by itself after the listing
    # Only once every copy has exited can no settings writer recreate a suite removed below.
    for _ in range(100):
        if not any(pids(directory) for directory in (data, idle_data)): break
        time.sleep(0.05)
    subprocess.run(['defaults', 'delete', CHECK_ID], capture_output=True)
    library = pathlib.Path.home() / 'Library'
    (library / 'Preferences' / (CHECK_ID+'.plist')).unlink(missing_ok=True)
    if not any(pids(directory) for directory in (data, idle_data)):
        for directory in (data, idle_data):
            for domain in suite_domains(directory):  # derived from this check's own disposable paths only
                subprocess.run(['defaults', 'delete', domain], capture_output=True)
                (library / 'Preferences' / (domain+'.plist')).unlink(missing_ok=True)
    else:
        raise RuntimeError('A check copy is still running; isolated defaults cleanup did not finish')
    shutil.rmtree(library / 'Saved Application State' / (CHECK_ID+'.savedState'), ignore_errors=True)
print('RESULT %d headless checks passed' % checks)
