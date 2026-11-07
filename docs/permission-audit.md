# Capture permission audit, 6–7 November 2026

This source and signing investigation does not establish which process displayed each earlier dialog. No installed app was launched, no capture was started, and no permissions were changed.

## Evidence and its limits

`log show --last 1d` for `tccd`, including info/debug messages, succeeded. The oldest returned tccd entry was 23:32:53; detailed capture requests began at 23:47. Earlier dialogs were not present. Read-only SQLite access to both user and system TCC databases returned `unable to open database file`. Neither refusal was bypassed.

The camera entries identify requesting process `com.apple.xctest`, PID 61925, Xcode's `Agents/xctest`, attributed to responsible process `com.t3tools.t3code`, PID 55409, `/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)`. They say `preflight=true`, `Auth Right: Unknown (None)`, `DB Action:None`. These are permission-status checks, **not proof of a displayed dialog**, even where `promptType: 1` or `allow prompt: Allow` appears.

The microphone entries identify `com.juniornkanabassi.TalkAndRead`, PID 83000, `/Applications/JuniorOS Apps/Talk & Read.app/Contents/MacOS/TalkRead`, forwarded by `coreaudiod`. They say `Allowed (User Consent)`, `DB Action:None`, not a new dialog. No captured entry identifies an earlier Video Prompter permission dialog. Raw logs and signing evidence are retained in the council output folder, `permission-audit-f00011b6`.

## Confirmed source gaps and fixes

1. `AgentMode` trusted the bundle ID alone. A signed build in a temporary folder retained the real ID and could ask for camera/microphone permission. The interactive exception now requires an installed bundle in `/Applications` or the user’s `Applications` folder too. Other app paths use the existing invisible/silent AgentMode guards.
2. `CaptureAccess.request` ignored headless mode. CLI/MCP can auto-start the installed app with `--headless`; camera/voice commands could then request permission. Requests now require an interactive installed app. A person can reveal that app before enabling a previously ungranted device.
3. `mayUse` allowed the real-ID app to open a device at any authorization status. Device construction itself can request access. Every input now goes through a factory requiring `.authorized`. Every session start goes through a helper checking all attached camera and microphone inputs, including a recording microphone in the shared camera session.
4. `AudioCapture` constructed its engine eagerly. Construction now follows authorization and device checks. `inputNode`, AudioUnit device selection and engine start remain below those guards. Stopping an unused instance never constructs an engine/input node. Eager construction was a risk removed, not a log-confirmed historic dialog cause.
5. XCTest silenced windows and alerts, but only Swift helpers blocked capture. Its Objective-C backstop now intercepts raw permission requests and device-input construction. Tests check that the method replacements are installed and exercise all authorization states with fake requester closures.
6. The CLI could auto-start the real app for disposable `--data-directory`, including via `VIDEOPROMPTER_APP`. Disposable data now disables CLI auto-launch entirely: the CLI only connects to the explicitly launched copy. This also fixes a reproduced startup race where a command arriving before the socket was ready launched a second copy. Re-identified non-disposable launches include `--agent-screen`. MCP uses this same CLI; manifest/status do not launch an app.
7. Both check scripts already re-identified their copies, but the built-app check called `open` directly and the headless check executed the app directly and offered a visible branch. They now use the council's `launch-hidden.sh`, with validated disposable identity/home/data. `LSEnvironment` passes `CFFIXED_USER_HOME` through LaunchServices. The visible branch is removed.
8. Local/ad-hoc packages retained the real bundle ID. They now use `.development`; the existing exact-ID check in `install.sh` rejects them. Developer ID builds retain the production ID. Neither build nor install scripts launch the app.

The scan covered PrompterCore, macOS tests, gui-state.swift, check scripts and MCP. No other SFSpeechRecognizer/AVAudioApplication permission request, AudioQueue/AudioUnit input start, CoreMediaIO stream start or ScreenCaptureKit capture path exists there. gui-state.swift performs targeted AX reads, not capture. Speech replay feeds recorded buffers. Device enumeration remains allowed; it is not a device open.

## Signing

A fresh Release executable and CLI were packaged in a temporary copy and Developer ID signed locally, without launch or notarisation submission. They match the installed app's designated requirement (real bundle ID, Apple Developer ID chain, Team ID `M6L2VW4W5Z`), camera/audio-input entitlements and hardened runtime. The fresh bundle passes strict nested-code verification and explicitly satisfies the installed app's requirement.

There is no signing-identity change here to explain a lost grant. This is consistent with [Apple's explanation of designated requirements and updates](https://developer.apple.com/library/archive/technotes/tn2206/_index.html). Actual TCC grant state remains unverified because database access was refused. No permission reset or re-grant is warranted by this evidence. If the installed app reports denied permission during normal use, Junior can check its Camera/Microphone toggles once in System Settings. Granting access to test runners or disposable copies is not a workaround.

## Verification

- PASS: Release build and Developer ID signature comparison, including explicit installed requirement verification.
- PASS: five source/launcher safety checks; MCP mock protocol checks; source-ignore check; shell/Python syntax and diff checks.
- PASS: all 15 hidden headless lifecycle checks, including restart and idle exit. Zero app windows or Dock tiles were observed by the window metadata watcher. No physical capture was started.
- NOT VERIFIED: built-app accessibility/UI assertions. The hidden copy returned `trusted: true` but `windows: []`; the check stopped and cleaned up its process. It was not revealed to obtain a tree. This does not undermine the separate headless/permission checks, but the UI assertions are not reported as passing.

The final full XCTest result is appended below. Unit tests and signature checks do not establish historical dialog attribution or a currently granted TCC record.

Final full-suite result: **PASS**, `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-permission-f00011b6 zsh test.sh`, outside the sandbox. 717 tests, 35 skipped, zero failures. The final Release build and 15 hidden lifecycle checks also passed. No app was installed or pushed.
