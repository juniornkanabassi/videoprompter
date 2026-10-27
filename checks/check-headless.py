#!/usr/bin/env python3
"""A command against a closed Video Prompter starts it headless: no window on screen, no Dock tile, quick to answer.
--show turns that copy into the ordinary app with its library in front, and an unused headless copy quits by itself.
Usage: source env.sh; python3 checks/check-headless.py '/tmp/.../Video Prompter.app'
Runs a re-identified copy on disposable data, as check-built-app.py does; --show briefly brings that copy forward.
"""
import json, os, pathlib, plistlib, re, shutil, statistics, subprocess, sys, tempfile, time
supplied = pathlib.Path(sys.argv[1]).resolve()
swift = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
root = pathlib.Path(tempfile.mkdtemp(prefix='vph-', dir='/private/tmp'))
CHECK_ID = 'com.juniornkanabassi.VidPrompt.headless-check'
app = root / 'Video Prompter.app'
subprocess.run(['ditto', str(supplied), str(app)], check=True, timeout=120)
subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Set :CFBundleIdentifier '+CHECK_ID, str(app / 'Contents/Info.plist')], check=True)
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

def activation_type(pid):
    found = re.search(r'type="(\w+)"', subprocess.run(['lsappinfo', 'info', '-app', str(pid)], capture_output=True, text=True).stdout)
    return found.group(1) if found else None

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
    _, cold = command('script', 'list')
    state, _ = command('status')
    [pid] = pids(data)
    print('INFO cold command, launch included: %.0f ms' % cold)
    check(state['headless'] is True, 'the copy the command started reports headless')
    check(activation_type(pid) in ('UIElement', 'BackgroundOnly'), 'the headless copy has no Dock tile')
    time.sleep(2)  # past the launch pass in which SwiftUI orders its window front
    check(onscreen_windows(pid) == 0, 'the headless copy shows no window')
    warm = [command('script', 'list')[1] for _ in range(7)]
    print('INFO warm command: median %.0f ms, slowest %.0f ms' % (statistics.median(warm), max(warm)))
    check(statistics.median(warm) < 500, 'a command to the running headless copy is quick')
    created, _ = command('script', 'create', '--title', 'Headless check', '--text', '# Headless check', '--request-id', 'headless-1')
    command('script', 'open', created['id'], '--show')
    state, _ = command('status')
    check(state['headless'] is False, '--show turns the same copy into the visible app')
    check(activation_type(pid) == 'Foreground', 'the revealed app has its Dock tile')
    time.sleep(1)
    check(onscreen_windows(pid) >= 1, 'the revealed app shows its library')
    os.kill(pid, 15)
    # An unused headless copy quits by itself; --idle-quit shortens the ten minutes for this check.
    idle = subprocess.Popen([str(exe), '--headless', '--idle-quit', '2', '--data-directory', str(idle_data)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if (idle_data / 'control.sock').exists(): break
        time.sleep(0.1)
    check(command('status', directory=idle_data)[0]['headless'] is True, 'a directly launched --headless copy is headless')
    try: idle.wait(timeout=15)
    except subprocess.TimeoutExpired: pass
    check(idle.poll() is not None, 'an unused headless copy quits by itself')
finally:
    for directory in (data, idle_data):
        for stray in pids(directory): os.kill(stray, 9)
    subprocess.run(['defaults', 'delete', CHECK_ID], capture_output=True)
    library = pathlib.Path.home() / 'Library'
    (library / 'Preferences' / (CHECK_ID+'.plist')).unlink(missing_ok=True)
    shutil.rmtree(library / 'Saved Application State' / (CHECK_ID+'.savedState'), ignore_errors=True)
print('RESULT %d headless checks passed' % checks)
