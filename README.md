# VidPrompt

VidPrompt is a teleprompter for the Mac. You write or import a script, then read it from a floating presenter window while you record yourself. The presenter can follow your voice as you speak, or scroll at a steady speed you choose. VidPrompt can also record from your camera.

Current version: **1.2.2** (build **37**), a preview.

## Watch the first use guide

The [visual quick-start guide](https://juniornkanabassi.com/apps/vidprompt/#walkthrough) shows how to add a script, set up Manual scrolling and use the presenter. It also introduces optional Voice tracking and the camera background. The guide uses genuine high-resolution VidPrompt 1.2.2 captures with fictional scripts, short on-screen instructions, music and sound effects. There is no narration. Written setup steps sit below the video, including permissions, linked Markdown files and recording controls.

## What you need

- A Mac with Apple silicon (arm64).
- macOS 26 or later.
- You do not need an Apple Developer account, Xcode or this source code to use the app.

## Download

[Download VidPrompt 1.2.2 preview](https://github.com/juniornkanabassi/vidprompt-releases/releases/latest/download/VidPrompt.dmg).

The public [Releases page](https://github.com/juniornkanabassi/vidprompt-releases/releases) contains the disk image, installation notes and SHA-256 checksum. The app source remains private. Every release uses the filename `VidPrompt.dmg`, so the download link above always points to the latest published version.

This is a self-signed preview, not an Apple notarised release. Read the requirements and first-launch guidance below before installing.

VidPrompt does not update itself. To get a newer version, download the latest disk image again by hand and replace the app.

## Install

1. Open `VidPrompt.dmg`.
2. Drag `VidPrompt.app` onto the `Applications` shortcut in the window. If you prefer to keep apps in a named folder, create it inside Applications first and drag VidPrompt there instead.
3. Eject the disk image, then open VidPrompt from Applications.

The disk image also contains a short install note.

### If macOS blocks the app the first time

This preview has not been signed with an Apple Developer ID or notarised by Apple, so macOS may say it cannot verify the developer. If that happens:

1. Try to open VidPrompt once.
2. Open **System Settings > Privacy & Security**, scroll to Security and choose **Open Anyway** for VidPrompt, if macOS offers it.
3. Confirm the next prompt only if you trust the copy you downloaded.

Apple warns that overriding this check carries risk, and this build has not been reviewed by Apple. Do not remove quarantine attributes or turn off Gatekeeper in Terminal. Apple's guide: [Open a Mac app from an unknown developer](https://support.apple.com/en-jo/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

Install and removal on a fresh Mac by someone new to the app have not yet been fully tested.

## First use

1. Open VidPrompt.
2. Import a script or choose **New Script**.
3. Open **Presenter settings** and choose **Voice** or **Manual**.
4. Press **Present**.
5. In the presenter, press **Start**. Press **Pause** to stop, or **Back to start** to return to the first word.

New libraries start with simple controls. **Show advanced settings** reveals detailed appearance, voice and saved settings. Showing or hiding them does not change any saved choices.

### Voice or Manual

- **Voice** follows your spoken words, using speech recognition on your Mac.
- **Manual** scrolls at the speed you choose. It needs no microphone or speech download.

### Microphone, speech downloads and camera

- Allow microphone access when you use Voice, and camera access when you use the camera.
- The first time you use Voice, macOS may need an internet connection to download Apple speech files. Which languages and audio formats work is checked while the app runs.
- A Mac that has never been online is not guaranteed to be ready for Voice.
- If Voice cannot get ready, check your connection and permissions, then try Voice again, or use Manual.
- Testing of the speech download, failure and retry steps on a brand-new user account is still pending.

### Recording

Recording is in the **Camera** toolbar. It uses the preview format you have pinned, up to 1920×1080. Testing with real cameras and microphones is still pending.

Normally the presenter window is hidden from screen capture. Specific recording and screen-sharing apps have not yet been tested to confirm this.

### Scripts and Markdown files

Scripts are stored as Markdown. When you import a Markdown file, it stays **linked both ways** with the original: edits in VidPrompt change the original file, and changes to the original appear in VidPrompt. Other formats are converted on import and are not linked.

## Privacy

- Voice follows you on your Mac. There is no hidden fallback to cloud transcription.
- Your scripts and settings are kept in your user account, in `~/Library/Application Support/VidPrompt`. Recordings are saved to `~/Movies/VidPrompt` by default.
- The disk image contains only the app, not your data.
- The optional command-line and AI control (see below) works only for your own user account on the same Mac.

## Remove VidPrompt

Quit VidPrompt and move the app to the Bin. Removing the app does not delete your scripts or recordings; they stay in the folders listed under Privacy until you remove them yourself.

If you set up the optional `vidprompt` command link or an AI host connection, remove those separately.

## Earlier name

VidPrompt was previously called JuniorPrompter. Installing VidPrompt does not import a JuniorPrompter library automatically. Keep any old library and its backups until you have checked that any recovery you plan has worked. Removing either app must not delete scripts or recordings.

## Not included yet

- Automatic updates (there is no Sparkle updater or signed update feed).
- Developer ID signing and Apple notarisation.
- OBS integration.
- Editing from iPhone or iCloud.

---

## Technical details

The rest of this file is for people building VidPrompt from source or controlling it from scripts and AI tools.

VidPrompt is a native Swift app for macOS 26. Markdown scripts are the source of truth, with a library/editor and a separate floating presenter. The source has no external package dependencies.

### Build and test

Requires macOS 26 or later, full Xcode with Swift 6.2 or later, and its command-line tools. `env.sh` selects the Xcode toolchain and SDK explicitly; the Command Line Tools alone cannot build the SwiftUI app. Accept Xcode's licence and finish its first-launch setup before building. MCP also needs Node 18 or later on PATH; the app and CLI do not need Node.

From this `Source/` directory:

```sh
source env.sh
zsh test.sh
zsh mcp/check-mcp.sh
zsh build.sh
```

The build produces `../Outputs/VidPrompt 1.2.2.zip`. Builds are staged outside file-provider folders, signed with the hardened runtime, and both the app and its helper are verified. The local ReadAlong Dev signing identity is used if available; otherwise the build is signed ad hoc. These are local development archives, not Developer ID signed or notarised releases for other Macs.

To make a download disk image from an app bundle that has already been verified, run `checks/package-dmg.sh /path/to/VidPrompt.app /path/to/output-folder`. It stages in `/private/tmp`, adds the standard Applications shortcut and the install note, and reports the bundle's minimum macOS version and executable architectures. It requires arm64 in both the app and the CLI helper. It writes `VidPrompt <version>.dmg` and refuses to replace an existing DMG; a release upload must be named `VidPrompt.dmg`. It does not sign or notarise the app.

Optional overrides: `VIDPROMPT_BUILD_ROOT`, `VIDPROMPT_TEST_SCRATCH` and `VIDPROMPT_OUTPUT_ROOT` choose disposable cache and output paths. Use a short path you own outside Documents, such as `/private/tmp/vp-build`. Never test against a personal library.

### Install from source

From this source checkout, install with `zsh install.sh`. The guarded installer refuses to run while the app is open, verifies the archive and keeps the previous installation if anything fails. It also links `~/.local/bin/vidprompt`. Keep the previous archive so you can roll back.

A drag-installed app does not need this source tree, Xcode or `install.sh`. It includes the CLI at `Contents/Helpers/vidprompt` and the MCP adapter at `Contents/Resources/mcp/vidprompt-mcp.mjs`, but does not create a PATH link or configure an AI host.

App details: bundle ID `com.juniornkanabassi.VidPrompt`, data folder `~/Library/Application Support/VidPrompt`, default recordings folder `~/Movies/VidPrompt`.

### Checking a built app in a disposable location

```sh
work=$(mktemp -d /private/tmp/vp-check.XXXXXX)
ditto -x -k '../Outputs/VidPrompt 1.2.2.zip' "$work"
source env.sh
python3 checks/check-built-app.py "$work/VidPrompt.app"
```

The checker creates its own `--data-directory`, runs the packaged CLI and MCP, and reads the app's accessibility state without sending input or changing focus. The terminal needs Accessibility permission for the GUI checks; if it is denied, the check fails rather than passes. Only the checker's own disposable process is stopped. Evidence is kept in the temporary folder it prints. `test.sh` separately builds and runs the XCTest bundle; six external and audio acceptance tests are opt-in and reported as skipped unless configured.

For a manual test with disposable data, launch the app executable with `--data-directory /private/tmp/vp-data`. This flag alone does not isolate all window restoration; use the packaged checker for its stronger disposable-home setup. `--agent-screen` uses an already-connected Agent Screen. `--capture-visible` lets the presenter be captured, for inspection only.

### Command line and AI control

VidPrompt exposes its existing app actions through a private Unix socket, a bundled CLI and an MCP shim. It requires macOS 26; MCP requires Node 18 or later and uses protocol version 2025-06-18. The source installer links `~/.local/bin/vidprompt` after a verified local install. A downloaded app does not create that link.

For a standard drag installation, set the real app path and use the bundled helper directly:

```sh
VIDPROMPT_APP="/Applications/VidPrompt.app"
"$VIDPROMPT_APP/Contents/Helpers/vidprompt" --help
"$VIDPROMPT_APP/Contents/Helpers/vidprompt" status --json
```

The short `vidprompt` examples below assume the optional command link exists and `~/.local/bin` is on PATH. Otherwise, replace `vidprompt` with the full helper path. These CLI commands do not need Node.

| Command | Example |
|---|---|
| Report state (never launches) | `vidprompt status --json` |
| List scripts | `vidprompt script list` |
| Import, with retry protection | `vidprompt script import ./script.md --request-id take1` |
| Select by ID or exact title | `vidprompt script open 'My Script'` |
| Present the selection or a named script | `vidprompt present 'My Script'` |
| Pause | `vidprompt pause` |
| Resume | `vidprompt resume` |
| Reset reading position | `vidprompt back-to-start` |
| Set tracking (`voice` or `manual`) | `vidprompt set-mode manual` |
| Set interface zoom (100, 110, 125, 150, 175 or 200) | `vidprompt set-zoom 150` |
| MCP tools manifest | `vidprompt mcp-manifest` |
| Full help | `vidprompt --help` |

Options can go before or after the command words. `--json` prints one response line. `--show` brings the library or presenter forward, and only works with `script open` or `present`. Other commands launch the app in the background if needed and wait up to 10 seconds. Exit codes: 0 success, 1 action or connection error, 2 usage error. A bundled helper uses its own app's identity. `--data-directory /private/tmp/vpc-test` isolates app data and preferences (keep the socket path under 104 UTF-8 bytes). On its own it does not isolate the whole account or window restoration; the packaged checker also uses an isolated home folder and restoration arguments.

Claude Code:

```sh
claude mcp add vidprompt -- node "/Applications/VidPrompt.app/Contents/Resources/mcp/vidprompt-mcp.mjs"
```

Codex, in `~/.codex/config.toml` (use the absolute path from `command -v node` if the host cannot find Node):

```toml
[mcp_servers.vidprompt]
command = "node"
args = ["/Applications/VidPrompt.app/Contents/Resources/mcp/vidprompt-mcp.mjs"]
```

Change these example paths to match where you installed the app. Any other stdio MCP host needs the command `node` with the matching bundled shim path as its argument; add `--data-directory /private/tmp/vpc-test` to isolate a test connection. The shim finds its own bundled helper. You set up the host yourself; the app does not run any setup command.

The socket is `control.sock` in the app's data folder: folder permissions 0700, socket 0600, and only processes from the same user can connect. VidPrompt data and disposable test data stay separate. Creation request IDs are idempotent within one app session. There are no delete, edit or recording actions. Markdown imports are linked to the original both ways, as in the app; converted formats are not linked. Resuming Voice may ask for microphone permission if access has not been decided yet. Token savings have not been measured and are not claimed.

### Release status

Current builds are signed with the local ReadAlong Dev identity, not Developer ID, and are not notarised. Normal Gatekeeper acceptance on a fresh Mac and the full install and removal workflow for a new user remain unverified. Sparkle, a signed appcast and an authorised public release pipeline are not shipped. No public release has been published. An unnotarised beta can be distributed separately with clear first-launch instructions, but the downloaded, quarantined install still needs verification on another Mac. A strict local signature check does not prove that first-launch workflow.
