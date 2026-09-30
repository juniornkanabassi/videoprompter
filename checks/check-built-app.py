#!/usr/bin/env python3
"""Exercise a supplied built bundle with disposable data and PID-targeted GUI reads.
Usage: source env.sh; python3 checks/check-built-app.py '/tmp/.../JuniorPrompter Alpha.app'
No show, mouse, key, recording, installation or real-data operations.
"""
import json, os, pathlib, socket, stat, subprocess, sys, tempfile, time
app = pathlib.Path(sys.argv[1]).resolve()
cli = app / 'Contents/Helpers/juniorprompter'
shim = app / 'Contents/Resources/mcp/juniorprompter-mcp.mjs'
script_dir = pathlib.Path(__file__).resolve().parent
swift = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
root = pathlib.Path(tempfile.mkdtemp(prefix='jpv-', dir='/private/tmp'))
data = root / 'data'
input_file = root / 'CLI Evidence.md'
input_file.write_text('# CLI Evidence\n\nOne two three four five six seven eight nine ten.\n')
pid = None
replies = []
def gui(target):
    result = subprocess.run([swift, str(script_dir / 'gui-state.swift'), str(target)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)
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
    before = gui(1)['frontmostPID']
    assert command(['status'])['running'] is False
    data.mkdir()
    stale = socket.socket(socket.AF_UNIX); stale.bind(str(data / 'control.sock')); stale.close()
    started = time.monotonic()
    imported = command(['script', 'import', str(input_file), '--request-id', 'once'])
    assert time.monotonic() - started < 10, 'Background launch exceeded 10 seconds'
    time.sleep(1)
    # Identify only the executable and unique --data-directory owned by this check.
    processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    matches = [int(line.split(None, 1)[0]) for line in processes.splitlines() if str(app / 'Contents/MacOS/JuniorPrompter') in line and str(data) in line]
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
    normal_rows = [row for row in normal_gui['windows'] if row.get('AXRole') == 'AXRow' and row.get('AXSelected') == '1']
    assert normal_rows, 'Selected script row missing before zoom'
    normal_height = float(normal_rows[0]['height'])
    command(['set-zoom', '150'])
    assert command(['set-zoom', '130'], 2)['code'] == 'usage'
    command(['present', imported['id']])
    command(['resume']); command(['pause']); command(['back-to-start'])
    status = command(['status'])
    assert status['running'] and status['selected']['id'] == imported['id']
    assert status['script']['id'] == imported['id'] and status['presenter'] == 'visible'
    assert status['mode'] == 'manual' and status['zoom'] == 150 and status['position']['word'] == 1
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
    assert len(manifest['tools']) == 10
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
    assert len(messages[1]['result']['tools']) == 10
    assert messages[2]['result']['isError'] is False and messages[3]['result']['isError'] is True
    time.sleep(1)
    visible = gui(pid)
    assert visible['trusted'] and visible['windows'], visible
    rows = visible['windows']
    rendered = json.dumps(rows)
    assert imported['title'] in rendered and 'Manual' in rendered and 'Tracking' in rendered, rendered
    alpha = app.name.endswith('Alpha.app')
    assert any("Simple" in row.values() for row in rows) == alpha, rendered
    selected = [row for row in rows if row.get('AXSelected') == '1']
    assert selected, 'No selected row in the running GUI'
    zoomed_rows = [row for row in rows if row.get('AXRole') == 'AXRow' and row.get('AXSelected') == '1']
    assert zoomed_rows and abs(float(zoomed_rows[0]['height']) / normal_height - 1.5) < 0.05, (normal_rows, zoomed_rows)
    assert visible['frontmostPID'] == before, (before, visible['frontmostPID'])
    # A symlink on PATH must retain the containing bundle's channel and version.
    link = root / 'juniorprompter'; link.symlink_to(cli)
    env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'])
    linked = subprocess.run(['juniorprompter', '--data-directory', str(data), 'status', '--json'], env=env, capture_output=True, text=True, timeout=10)
    assert linked.returncode == 0 and json.loads(linked.stdout)['result']['app'] == status['app']
    report = {'ok': True, 'bundle': str(app), 'data': str(data), 'pid': pid, 'commands': replies, 'mcp': messages, 'gui': visible, 'frontmostUnchanged': True}
    (root / 'evidence.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({'ok': True, 'commands': len(replies), 'tools': 10, 'guiRows': len(rows), 'evidence': str(root / 'evidence.json')}))
finally:
    if pid is None:
        processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
        matches = [int(line.split(None, 1)[0]) for line in processes.splitlines() if str(app / 'Contents/MacOS/JuniorPrompter') in line and str(data) in line]
        pid = matches[0] if len(matches) == 1 else None
    if pid:
        # Only the disposable PID owned by this check; no recordings or unsaved edits exist.
        os.kill(pid, 15)
    print('Disposable evidence retained at '+str(root), file=sys.stderr)
