#!/usr/bin/env python3
"""Exercise a supplied built bundle with disposable data and PID-targeted GUI reads.
Usage: source env.sh; python3 checks/check-built-app.py '/tmp/.../Video Prompter.app'
No show, mouse, key, recording, installation or real-data operations.
"""
import argparse, json, os, pathlib, plistlib, shutil, socket, stat, subprocess, sys, tempfile, time
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--data-directory', type=pathlib.Path)
args = parser.parse_args()
supplied = args.app.resolve()
script_dir = pathlib.Path(__file__).resolve().parent
swift = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
root = pathlib.Path(tempfile.mkdtemp(prefix='vpv-', dir='/private/tmp'))
(root / 'home').mkdir()
# The shipped bundle must be validly signed. The check then runs a copy with its own bundle identifier, because
# AppKit window and split-view autosave write to the standard defaults domain, which would otherwise be the real app's.
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(supplied)], check=True, timeout=60)
CHECK_ID = 'com.juniornkanabassi.VidPrompt.check'
app = root / 'Video Prompter.app'
subprocess.run(['ditto', str(supplied), str(app)], check=True, timeout=120)
subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Set :CFBundleIdentifier '+CHECK_ID, str(app / 'Contents/Info.plist')], check=True)
# Keep the shipped entitlements and hardened-runtime flags; only the identity changes.
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--preserve-metadata=entitlements,flags', str(app)], check=True, timeout=120)
# An ad hoc signature has no Team ID, so hardened runtime would refuse the embedded Sparkle.framework: the copy alone
# turns library validation off, on top of the shipped entitlements.
entitlements = plistlib.loads(subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(supplied)], capture_output=True, check=True, timeout=60).stdout or plistlib.dumps({}))
entitlements['com.apple.security.cs.disable-library-validation'] = True
(root / 'check.entitlements').write_bytes(plistlib.dumps(entitlements))
subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=flags', '--entitlements', str(root / 'check.entitlements'), str(app)], check=True, timeout=120)
def bundle_id(bundle): return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
assert bundle_id(supplied) == 'com.juniornkanabassi.VidPrompt' and bundle_id(app) == CHECK_ID, (bundle_id(supplied), bundle_id(app))
cli = app / 'Contents/Helpers/videoprompter'
shim = app / 'Contents/Resources/mcp/videoprompter-mcp.mjs'
data = args.data_directory.resolve() if args.data_directory else root / 'data'
assert data.is_relative_to(pathlib.Path('/private/tmp')) and not data.exists(), 'Use a fresh disposable data directory under /private/tmp'
input_file = root / 'CLI Evidence.md'
input_file.write_text('# CLI Evidence\n\nOne two three four five six seven eight nine ten.\n')
pid = None
replies = []
def gui(target):
    result = subprocess.run([swift, str(script_dir / 'gui-state.swift'), str(target)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    state = json.loads(result.stdout)
    interactive = {'AXButton', 'AXCheckBox', 'AXSwitch', 'AXSlider', 'AXPopUpButton',
                   'AXTextField', 'AXTextArea', 'AXComboBox', 'AXRadioButton',
                   'AXIncrementor', 'AXColorWell', 'AXMenuButton', 'AXLink'}
    native_parts = {'AXCloseButton', 'AXMinimizeButton', 'AXFullScreenButton', 'AXZoomButton',
                    'AXIncrementArrow', 'AXDecrementArrow', 'AXIncrementPage', 'AXDecrementPage'}
    unnamed = [row for row in state['windows'] if row.get('AXRole') in interactive
               and not any(row.get(key, '').strip() for key in
                           ['AXTitle', 'AXDescription', 'labelledBy', 'AXPlaceholderValue'])
               and not (row.get('AXSubrole') in native_parts and row.get('AXRoleDescription'))]
    assert not unnamed, ('Interactive controls need accessible names', unnamed)
    return state
def command(words, expected=0):
    result = subprocess.run([str(cli), '--data-directory', str(data), *words, '--json'], capture_output=True, text=True, timeout=45)
    assert result.returncode == expected, (words, result.returncode, result.stdout, result.stderr)
    reply = json.loads(result.stdout)
    assert reply['ok'] == (expected == 0), reply
    replies.append({'command': words, 'exit': result.returncode, 'reply': reply})
    return reply.get('result', reply.get('error'))
def raw(payload):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5); connection.connect(str(data / 'control.sock')); connection.sendall(payload)
        line = b''
        while b'\n' not in line:
            part = connection.recv(8192)
            if not part: break
            line += part
        return json.loads(line) if line else None
try:
    help_result = subprocess.run([str(cli), '--help'], capture_output=True, text=True, timeout=10)
    assert help_result.returncode == 0 and 'mcp-manifest' in help_result.stdout and 'back-to-start' in help_result.stdout
    before = gui(1)['frontmostPID']
    assert command(['status'])['running'] is False
    data.mkdir()
    stale = socket.socket(socket.AF_UNIX); stale.bind(str(data / 'control.sock')); stale.close()
    # Ignore shared macOS scene restoration for this disposable instance.
    subprocess.run(['open', '-g', '-n', '-a', str(app), '--env', 'CFFIXED_USER_HOME='+str(root / 'home'), '--args', '--data-directory', str(data), '-ApplePersistenceIgnoreState', 'YES', '-NSQuitAlwaysKeepsWindows', 'NO', '--agent-screen'], check=True, timeout=10)
    time.sleep(3)
    processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    matches = [int(line.split(None, 1)[0]) for line in processes.splitlines() if str(app / 'Contents/MacOS/VideoPrompter') in line and str(data) in line]
    assert len(matches) == 1, matches
    pid = matches[0]
    empty_gui = gui(pid)
    (root / 'empty-gui.json').write_text(json.dumps(empty_gui, indent=2))
    empty_text = json.dumps(empty_gui['windows'])
    for label in ['Your script, ready to read', 'Add a script', 'Choose Voice or Manual in Settings', 'Press Present', 'Import Script', 'New Script', 'More']:
        assert label in empty_text, (label, empty_text)
    mirror_switches = [row for row in empty_gui['windows'] if row.get('AXRole') in ['AXCheckBox', 'AXSwitch']
                       and row.get('AXDescription') == 'Mirror for teleprompter glass']
    assert mirror_switches, 'Glass mirroring needs a direct accessible label'
    advanced_switches = [row for row in empty_gui['windows'] if row.get('AXRole') in ['AXDisclosureTriangle', 'AXCheckBox', 'AXSwitch', 'AXButton'] and 'More' in str(row)]
    assert advanced_switches and all(row.get('AXValue') == '0' for row in advanced_switches), advanced_switches
    assert 'Saved settings' not in empty_text and 'Microphone volume' not in empty_text, 'More must start collapsed'
    started = time.monotonic()
    imported = command(['script', 'import', str(input_file), '--request-id', 'once'])
    assert time.monotonic() - started < 10, 'Background import exceeded 10 seconds'
    time.sleep(1)
    # Identify only the executable and unique --data-directory owned by this check.
    processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    matches = [int(line.split(None, 1)[0]) for line in processes.splitlines() if str(app / 'Contents/MacOS/VideoPrompter') in line and str(data) in line]
    assert len(matches) == 1, matches
    pid = matches[0]
    assert imported['linked'] is True and imported['repeated'] is False
    repeated = command(['script', 'import', str(input_file), '--request-id', 'once'])
    assert repeated['id'] == imported['id'] and repeated['repeated'] is True
    assert len(command(['script', 'list'])['scripts']) == 1
    for action in ['pause', 'resume', 'back-to-start']:
        assert command([action], 1)['code'] == 'no_active_script'
    command(['script', 'open', imported['id']])
    command(['script', 'open', imported['title']])
    assert command(['script', 'open', 'missing'], 1)['code'] == 'script_not_found'
    command(['set-mode', 'manual'])
    time.sleep(0.5)
    normal_gui = gui(pid)
    for _ in range(5):
        if normal_gui['windows']: break
        time.sleep(1)
        normal_gui = gui(pid)
    (root / 'normal-gui.json').write_text(json.dumps(normal_gui, indent=2))
    normal_rows = [row for row in normal_gui['windows'] if row.get('AXRole') == 'AXRow' and row.get('AXSelected') == '1']
    assert normal_rows, 'Selected script row missing before zoom'
    normal_height = float(normal_rows[0]['height'])
    command(['set-zoom', '150'])
    assert command(['set-zoom', '130'], 2)['code'] == 'usage'
    command(['present', imported['id']])
    command(['resume'])
    running_gui = gui(pid)
    (root / 'scrolling-gui.json').write_text(json.dumps(running_gui, indent=2))
    for label in ['Scrolling', 'Pause']:
        assert any(label in row.values() for row in running_gui['windows']), (label, running_gui)
    command(['pause']); command(['back-to-start'])
    status = command(['status'])
    assert status['running'] and status['selected']['id'] == imported['id']
    assert status['script']['id'] == imported['id'] and status['presenter'] == 'visible'
    assert status['mode'] == 'manual' and status['zoom'] == 150 and status['position']['word'] == 1
    assert command(['settings', 'set', '--speed', '150'])['speed'] == 150 and command(['status'])['speed'] == 150
    assert command(['settings', 'set', '--speed', '301'], 2)['code'] == 'usage'
    assert stat.S_IMODE((data / 'control.sock').stat().st_mode) == 0o600
    assert stat.S_IMODE(data.stat().st_mode) == 0o700
    assert raw(b'not JSON\n')['error']['code'] == 'bad_request'
    assert raw(b'{"id":"x","action":"unknown"}\n')['error']['code'] == 'unknown_action'
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5); connection.connect(str(data / 'control.sock'))
        connection.sendall(b'x' * 65537 + b'\n')
        try: assert connection.recv(4096) == b''
        except ConnectionResetError: pass
    assert command(['status'])['running']
    manifest = json.loads(subprocess.check_output([str(cli), 'mcp-manifest'], text=True))
    tool_count = len(manifest['tools'])
    assert tool_count == 40, tool_count
    requests = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
                {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'status'}},
                {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'script_open', 'arguments': {'script': 'missing'}}},
                {'jsonrpc': '2.0', 'id': 5, 'method': 'ping'}]
    mcp = subprocess.run(['node', str(shim), '--data-directory', str(data)], input=''.join(json.dumps(r)+'\n' for r in requests), capture_output=True, text=True, timeout=45)
    assert mcp.returncode == 0, mcp.stderr
    messages = [json.loads(line) for line in mcp.stdout.splitlines()]
    assert [m['id'] for m in messages] == [1, 2, 3, 4, 5]
    assert len(messages[1]['result']['tools']) == tool_count
    assert messages[2]['result']['isError'] is False and messages[3]['result']['isError'] is True
    time.sleep(1)
    visible = gui(pid)
    assert visible['trusted'] and visible['windows'], visible
    rows = visible['windows']
    rendered = json.dumps(rows)
    assert imported['title'] in rendered and 'Manual' in rendered and 'How it follows you' in rendered, rendered
    assert any("More" in row.values() for row in rows), rendered
    for label in ['Start', 'Back to start', 'Edit script', 'Close presenter', 'Paused']:
        assert any(label in row.values() for row in rows), (label, rendered)
    for removed in ['Previous passage', 'Next passage']:
        assert not any(removed in row.values() for row in rows), ('Secondary action still in presenter chrome', removed)
    camera_buttons = [label for label in ['Show camera', 'Hide camera'] if any(label in row.values() for row in rows)]
    assert len(camera_buttons) == 1, ('Presenter bar must offer exactly one of Show/Hide camera', camera_buttons, rendered)
    # Framing guides appear only while the camera is on (a fresh data directory starts with it off).
    assert any('Framing guides' in row.values() for row in rows) == (camera_buttons == ['Hide camera']), (camera_buttons, rendered)
    selected = [row for row in rows if row.get('AXSelected') == '1']
    assert selected, 'No selected row in the running GUI'
    zoomed_rows = [row for row in rows if row.get('AXRole') == 'AXRow' and row.get('AXSelected') == '1']
    assert zoomed_rows and abs(float(zoomed_rows[0]['height']) / normal_height - 1.5) < 0.05, (normal_rows, zoomed_rows)
    assert visible['frontmostPID'] == before, (before, visible['frontmostPID'])
    # A symlink on PATH must retain the containing bundle's identity and version.
    link = root / 'videoprompter'; link.symlink_to(cli)
    env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'])
    linked = subprocess.run(['videoprompter', '--data-directory', str(data), 'status', '--json'], env=env, capture_output=True, text=True, timeout=10)
    assert linked.returncode == 0 and json.loads(linked.stdout)['result']['app'] == status['app']
    for number in range(200):
        extra = root / (f'Large library {number} '+('x' * 200)+'.md')
        extra.write_text(f'# Large library {number} '+('x' * 700)+'\n\nDisposable script.\n')
        command(['script', 'import', str(extra)])
    assert len(command(['script', 'list'])['scripts']) == 201
    large_request = {'jsonrpc': '2.0', 'id': 100, 'method': 'tools/call', 'params': {'name': 'script_list'}}
    large_mcp = subprocess.run(['node', str(shim), '--data-directory', str(data)], input=json.dumps(large_request)+'\n', capture_output=True, text=True, timeout=45)
    assert len(large_mcp.stdout.encode()) > 65_536
    large_reply = json.loads(large_mcp.stdout)
    assert large_mcp.returncode == 0 and large_reply['result']['isError'] is False, large_reply
    assert len(json.loads(large_reply['result']['content'][0]['text'])['result']['scripts']) == 201
    report = {'ok': True, 'bundle': str(supplied), 'checkedCopy': str(app), 'data': str(data), 'pid': pid, 'commands': replies, 'mcp': messages, 'gui': visible, 'frontmostUnchanged': True}
    (root / 'evidence.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({'ok': True, 'commands': len(replies), 'tools': tool_count, 'guiRows': len(rows), 'evidence': str(root / 'evidence.json')}))
finally:
    if pid is None:
        processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
        matches = [int(line.split(None, 1)[0]) for line in processes.splitlines() if str(app / 'Contents/MacOS/VideoPrompter') in line and str(data) in line]
        pid = matches[0] if len(matches) == 1 else None
    if pid:
        # Only the disposable PID owned by this check; no recordings or unsaved edits exist.
        os.kill(pid, 15)
    # The check bundle id has its own defaults domain and saved state; remove them so nothing outlives the check.
    subprocess.run(['defaults', 'delete', CHECK_ID], capture_output=True)
    library = pathlib.Path.home() / 'Library'
    (library / 'Preferences' / (CHECK_ID+'.plist')).unlink(missing_ok=True)
    shutil.rmtree(library / 'Saved Application State' / (CHECK_ID+'.savedState'), ignore_errors=True)
    print('Disposable evidence retained at '+str(root), file=sys.stderr)
