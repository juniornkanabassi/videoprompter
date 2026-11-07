"""Use the council's authorised launcher; never launch an installed/real-identity app."""
import os
import pathlib
import plistlib
import subprocess

LAUNCHER = pathlib.Path('/Users/junior.nkanabassi/Documents/JuniorOS/02 Projects/Development/Outputs/2026-11-06 Video Prompter design council/launch-hidden.sh')
REAL_ID = 'com.juniornkanabassi.VidPrompt'


def launch(app, data, *arguments):
    app, data = pathlib.Path(app).resolve(), pathlib.Path(data).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if app.is_relative_to('/Applications') or info.get('CFBundleIdentifier') in (None, REAL_ID):
        raise ValueError('Checks require a disposable, re-identified app')
    if not data.is_relative_to('/private/tmp'):
        raise ValueError('Checks require disposable data under /private/tmp')
    home = str(app.parent / 'home')
    if info.get('LSEnvironment', {}).get('CFFIXED_USER_HOME') != home:
        raise ValueError('Checks require an isolated home in the signed app environment')
    # launch-hidden.sh unconditionally adds --agent-screen and restoration suppression.
    subprocess.run(['zsh', str(LAUNCHER), str(app), str(data), *arguments],
                   check=True, timeout=15, env={**os.environ, 'CFFIXED_USER_HOME': home})
