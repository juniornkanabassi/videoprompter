"""No app launches or device access: enforce the capture and hidden-launch boundaries."""
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from agent_launch import launch, REAL_ID, LAUNCHER

ROOT = pathlib.Path(__file__).resolve().parent.parent


class CaptureSafetyTests(unittest.TestCase):
    def test_raw_capture_entry_points_stay_in_guarded_owners(self):
        allowed = {
            'AVCaptureDevice.requestAccess(': {'Sources/VideoPrompter/App/CaptureAccess.swift'},
            'AVCaptureDeviceInput(device:': {'Sources/VideoPrompter/App/CaptureAccess.swift'},
            '.startRunning()': {'Sources/VideoPrompter/App/CaptureAccess.swift'},
            '.inputNode': {'Sources/VideoPrompter/Audio/AudioCapture.swift'},
            'AVAudioEngine()': {'Sources/VideoPrompter/Audio/AudioCapture.swift'},
        }
        # Any new low-level input API needs a permission review before joining this allowlist.
        forbidden = ['requestRecordPermission(', 'SFSpeechRecognizer.requestAuthorization(',
                     'AudioQueueNewInput(', 'AudioUnitInitialize(', 'AudioOutputUnitStart(', 'AudioDeviceStart(',
                     'SCStream(', 'SCShareableContent.', 'CGRequestScreenCaptureAccess(', 'CMIODeviceStartStream(', 'CMIOStreamStart(']
        for folder in ['Sources', 'Tests']:
            for path in (ROOT / folder).rglob('*.swift'):
                text = path.read_text()
                relative = str(path.relative_to(ROOT))
                for token, owners in allowed.items():
                    if token in text:
                        self.assertIn(relative, owners, f'{relative}: unreviewed {token}')
                for token in forbidden:
                    self.assertNotIn(token, text, relative)

    def test_audio_engine_is_created_only_after_permission_and_device_checks(self):
        text = (ROOT / 'Sources/VideoPrompter/Audio/AudioCapture.swift').read_text()
        self.assertIn('private var engine: AVAudioEngine?', text)
        self.assertLess(text.index('guard CaptureAccess.mayUse(.audio)'), text.index('AVAudioEngine()'))
        self.assertLess(text.index('guard Self.inputDevices().contains'), text.index('AVAudioEngine()'))

    def test_launcher_rejects_real_identity_and_requires_isolated_home(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            root = pathlib.Path(directory).resolve()
            app = root / 'Video Prompter.app'
            (app / 'Contents').mkdir(parents=True)
            info = app / 'Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': REAL_ID}))
            with patch('agent_launch.subprocess.run') as run:
                with self.assertRaises(ValueError):
                    launch(app, root / 'data')
                info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'check'}))
                with self.assertRaises(ValueError):
                    launch(app, root / 'data')
                info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'check',
                    'LSEnvironment': {'CFFIXED_USER_HOME': str(root / 'home')}}))
                with self.assertRaises(ValueError):
                    launch(app, pathlib.Path('/Users/not-disposable'))
                run.assert_not_called()
                launch(app, root / 'data', '--headless')
                self.assertEqual(run.call_args.args[0],
                    ['zsh', str(LAUNCHER), str(app), str(root / 'data'), '--headless'])

    def test_local_builds_cannot_replace_the_installed_identity(self):
        build = (ROOT / 'build.sh').read_text()
        install = (ROOT / 'install.sh').read_text()
        self.assertIn('Set :CFBundleIdentifier $REAL_ID.development', build)
        self.assertIn('"$ACTUAL_ID" == "$EXPECTED_ID"', install)

    def test_checks_use_only_authorised_launcher(self):
        for name in ['check-built-app.py', 'check-headless.py']:
            text = (ROOT / 'checks' / name).read_text()
            self.assertIn('from agent_launch import launch', text)
            self.assertNotIn("['open',", text)
            self.assertNotIn('Popen([str(exe)', text)
        self.assertIn('visible checks are disabled', (ROOT / 'checks/check-headless.py').read_text())


if __name__ == '__main__':
    unittest.main()
