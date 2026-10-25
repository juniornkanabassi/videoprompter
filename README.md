# Video Prompter

Video Prompter is a teleprompter for the Mac. You write or import a script, then read it from a floating presenter window while you record yourself. The presenter can follow your voice as you speak, or scroll at a steady speed you choose. Video Prompter can also record from your camera.

Current release: **2.0.0** (build **39**).

2.0.0 renames the app to Video Prompter (formerly VidPrompt), simplifies the interface, and is the first release signed with Developer ID and notarised by Apple.

Voice tracking remains a preview. One recorded false-start timing check is unresolved, and tracking can pause while it finds the right passage after your wording differs from the script. Manual scrolling remains available.

## Watch the first use guide

The [visual quick-start guide](https://juniornkanabassi.com/apps/videoprompter/#walkthrough) shows how to add a script, set up Manual scrolling and use the presenter. It also introduces optional Voice tracking and the camera background. The guide uses genuine high-resolution captures of version 1.2.2 with fictional scripts, short on-screen instructions, music and sound effects. There is no narration. Written setup steps sit below the video, including permissions, linked Markdown files and recording controls.

## What you need

- A Mac with Apple silicon (arm64).
- macOS 26 or later.
- You do not need an Apple Developer account, Xcode or this source code to use the app.

## Download

[Download the latest Video Prompter](https://github.com/juniornkanabassi/videoprompter/releases/latest/download/VideoPrompter.dmg).

The [Releases page](https://github.com/juniornkanabassi/videoprompter/releases) contains the disk image, installation notes and SHA-256 checksum. Releases up to 2.0.2 are on the archived [videoprompter-releases](https://github.com/juniornkanabassi/videoprompter-releases/releases). Every release uses the filename `VideoPrompter.dmg`, so the download link above always points to the latest published version.

Release 2.0.0 is signed with an Apple Developer ID and notarised by Apple, so macOS opens it normally after download. Read the requirements below before installing.

From the first release built with Sparkle, Video Prompter checks for updates once a day and offers each new version with its release notes; it installs only after you agree. Video Prompter > Check for Updates… checks straight away. Versions before that release do not update themselves, so install that one by hand from the disk image.

## Install

1. Open `VideoPrompter.dmg`.
2. Drag `Video Prompter.app` onto the `Applications` shortcut in the window. If you prefer to keep apps in a named folder, create it inside Applications first and drag Video Prompter there instead.
3. Eject the disk image, then open Video Prompter from Applications.

The disk image also contains a short install note.

### First launch

The release includes Apple’s notarisation ticket. macOS may ask you to confirm opening a downloaded app. If it says the app is damaged or cannot be verified, download a fresh copy from the Releases page and check your Mac’s security policy. Do not remove quarantine attributes or turn off Gatekeeper in Terminal.

## First use

1. Open Video Prompter.
2. Choose **Add** to import a file or create a **New Script**.
3. Open **Settings** and choose **Voice** or **Manual**.
4. Press **Present**.
5. In the presenter, press **Start**. Press **Pause** to stop, or **Back to start** to return to the first word.

New libraries start with simple controls. **More** in Settings reveals detailed appearance, voice and saved settings. Showing or hiding them does not change any saved choices.

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

### Camera and reference monitor

The **View** menu in the presenter bar switches between Script only, Script and camera, and Camera only. **Camera Settings…** in the same menu holds the camera choice, rotation, mirroring and framing guides.

To record without a script, press **Present** with no script selected, or choose **Camera Only** in an empty library or **Present Camera Only** in the Prompter menu. The presenter opens with just the camera. When you have a script, select it and press **Present** again: it appears over the same camera picture. Going the other way, choose **Script and camera** from the View menu to add the camera to a script you are already reading.

To use the presenter as a reference monitor, drag across a passage in the presenter or the library editor, then choose **Monitor Selection with Camera** from the View menu or the Prompter menu (⌥⌘M). The camera fills the presenter with that passage pinned across the bottom. Press **Back to script** or Esc to return to the full script. A single click in the presenter still moves the reading position.

### Scripts and Markdown files

Scripts are stored as Markdown. When you import a Markdown file, it stays **linked both ways** with the original: edits in Video Prompter change the original file, and changes to the original appear in Video Prompter. Other formats are converted on import and are not linked.

## Privacy

- Voice follows you on your Mac. There is no hidden fallback to cloud transcription.
- Your scripts and settings are kept in your user account, in `~/Library/Application Support/Video Prompter`. Recordings are saved to `~/Movies/Video Prompter` by default.
- The disk image contains only the app, not your data.
- The optional command-line and AI control (see below) works only for your own user account on the same Mac.

## Remove Video Prompter

Quit Video Prompter and move the app to the Bin. Removing the app does not delete your scripts or recordings; they stay in the folders listed under Privacy until you remove them yourself.

If you set up the optional `videoprompter` command link or an AI host connection, remove those separately.

## Earlier names

Video Prompter was formerly VidPrompt, and JuniorPrompter before that. Version 2.0.0 keeps the same bundle identifier for existing settings. The library migrates on first launch; existing recordings migrate when the new app first stores a recording. Both use the new `Video Prompter` folder name. If the move cannot finish, it continues using the original folder. The new signing identity may require fresh camera or microphone permission. Quit VidPrompt before opening Video Prompter. Once you have checked that your scripts are present, move the old `VidPrompt.app` to the Bin so you keep one active copy. Removing the old app does not delete its scripts.

Installing Video Prompter does not import a JuniorPrompter library automatically. Keep any old library and its backups until you have checked that any recovery you plan has worked. Removing either app must not delete scripts or recordings.

## Not included yet

- OBS integration.
- Editing from iPhone or iCloud.

---

## Technical details

The rest of this file is for people building Video Prompter from source or controlling it from scripts and AI tools.

Video Prompter is a native Swift app for macOS 26. Its source is in the private repository https://github.com/juniornkanabassi/videoprompter. Markdown scripts are the source of truth, with a library/editor and a separate floating presenter. The source has no external package dependencies.

### Build and test

Requires macOS 26 or later, full Xcode with Swift 6.2 or later, and its command-line tools. `env.sh` selects the Xcode toolchain and SDK explicitly; the Command Line Tools alone cannot build the SwiftUI app. Accept Xcode's licence and finish its first-launch setup before building. MCP also needs Node 18 or later on PATH; the app and CLI do not need Node.

From this `Source/` directory:

```sh
source env.sh
zsh test.sh
zsh mcp/check-mcp.sh
zsh build.sh
```

The build produces `../Outputs/Video Prompter 2.0.0.zip`. Builds are staged outside file-provider folders, signed with the hardened runtime, and both the app and its helper are verified. With the Developer ID certificate in the keychain, `build.sh` signs with it (hardened runtime, secure timestamp), submits the app to Apple's notary service through the `JuniorOS` keychain profile, staples the ticket and checks the result with `spctl`. Set `VIDEOPROMPTER_LOCAL_SIGNING=1` for a quick local build signed with the ReadAlong Dev identity and not notarised.

To make a download disk image from an app bundle that has already been verified, run `checks/package-dmg.sh "/path/to/Video Prompter.app" /path/to/output-folder`. It stages in `/private/tmp`, adds the standard Applications shortcut and the install note, and reports the bundle's minimum macOS version and executable architectures. It requires arm64 in both the app and the CLI helper. It writes `Video Prompter <version>.dmg` and refuses to replace an existing DMG; a release upload must be named `VideoPrompter.dmg`. For a Developer ID build it also signs, notarises and staples the disk image.

Optional overrides: `VIDEOPROMPTER_BUILD_ROOT`, `VIDEOPROMPTER_TEST_SCRATCH` and `VIDEOPROMPTER_OUTPUT_ROOT` choose disposable cache and output paths. Use a short path you own outside Documents, such as `/private/tmp/vp-build`. Never test against a personal library.

### Install from source

From this source checkout, install with `zsh install.sh`. The guarded installer refuses to run while the app is open, verifies the archive and keeps the previous installation if anything fails. It also links `~/.local/bin/videoprompter`. Keep the previous archive so you can roll back.

A drag-installed app does not need this source tree, Xcode or `install.sh`. It includes the CLI at `Contents/Helpers/videoprompter` and the MCP adapter at `Contents/Resources/mcp/videoprompter-mcp.mjs`, but does not create a PATH link or configure an AI host.

App details: bundle ID `com.juniornkanabassi.VidPrompt` (kept from the earlier name so permissions and settings survive), data folder `~/Library/Application Support/Video Prompter`, default recordings folder `~/Movies/Video Prompter`.

### Checking a built app in a disposable location

```sh
work=$(mktemp -d /private/tmp/vp-check.XXXXXX)
ditto -x -k '../Outputs/Video Prompter 2.0.0.zip' "$work"
source env.sh
python3 checks/check-built-app.py "$work/Video Prompter.app"
```

The checker creates its own `--data-directory`, runs the packaged CLI and MCP, and reads the app's accessibility state without sending input or changing focus. The terminal needs Accessibility permission for the GUI checks; if it is denied, the check fails rather than passes. Only the checker's own disposable process is stopped. Evidence is kept in the temporary folder it prints. `test.sh` separately builds and runs the XCTest bundle; six external and audio acceptance tests are opt-in and reported as skipped unless configured.

For a manual test with disposable data, launch the app executable with `--data-directory /private/tmp/vp-data`. This flag alone does not isolate all window restoration; use the packaged checker for its stronger disposable-home setup. `--agent-screen` uses an already-connected Agent Screen. `--capture-visible` lets the presenter be captured, for inspection only.

### Command line and AI control

Video Prompter exposes its existing app actions through a private Unix socket, a bundled CLI and an MCP shim. It requires macOS 26; MCP requires Node 18 or later and uses protocol version 2025-06-18. The source installer links `~/.local/bin/videoprompter` after a verified local install. A downloaded app does not create that link.

For a standard drag installation, set the real app path and use the bundled helper directly:

```sh
VIDEOPROMPTER_APP="/Applications/Video Prompter.app"
"$VIDEOPROMPTER_APP/Contents/Helpers/videoprompter" --help
"$VIDEOPROMPTER_APP/Contents/Helpers/videoprompter" status --json
```

The short `videoprompter` examples below assume the optional command link exists and `~/.local/bin` is on PATH. Otherwise, replace `videoprompter` with the full helper path. These CLI commands do not need Node.

| Command | Example |
|---|---|
| Report state, including speed, camera and recording (never launches) | `videoprompter status --json` |
| List scripts | `videoprompter script list` |
| Read a script's Markdown, folder and tags | `videoprompter script read 'My Script'` |
| Create a script from text, with retry protection | `videoprompter script create --title Intro --text '# Intro' --request-id intro1` |
| Create a script from standard input | `cat intro.md \| videoprompter script create --title Intro --text -` |
| Import, with retry protection | `videoprompter script import ./script.md --request-id take1` |
| Select by ID or exact title | `videoprompter script open 'My Script'` |
| Rename a script | `videoprompter script rename 'My Script' --title 'Launch video'` |
| Replace a script's tags (`none` clears them) | `videoprompter script tag 'My Script' --tags 'launch, draft'` |
| Move a script to a folder (`none` for All Scripts) | `videoprompter script move 'My Script' --folder Drafts` |
| Duplicate a script, with retry protection | `videoprompter script duplicate 'My Script' --request-id copy1` |
| Save a script's Markdown to a file (`--replace --yes` to overwrite) | `videoprompter script export 'My Script' --path ./my-script.md` |
| Move a script to Recently Deleted | `videoprompter script delete 'My Script' --yes` |
| List Recently Deleted | `videoprompter script trash` |
| Restore from Recently Deleted | `videoprompter script restore 'My Script'` |
| List, create and rename folders | `videoprompter folder list`, `folder create Drafts --request-id drafts1`, `folder rename Drafts --name 'In progress'` |
| Present the selection or a named script | `videoprompter present 'My Script'` |
| Close the presenter | `videoprompter presenter close` |
| Pause | `videoprompter pause` |
| Resume | `videoprompter resume` |
| Reset reading position | `videoprompter back-to-start` |
| Next or previous passage | `videoprompter next-passage`, `videoprompter previous-passage` |
| Move to a word number, as `status` counts them | `videoprompter seek 120` |
| Set tracking (`voice` or `manual`) | `videoprompter set-mode manual` |
| Set interface zoom (100, 110, 125, 150, 175 or 200) | `videoprompter set-zoom 150` |
| Report or change presenter settings: speed, text size, font, mirroring, reading line, colours, spacing, stage directions, language, Voice microphone and more | `videoprompter settings get`, `videoprompter settings set --speed 150 --text-size 60 --mirror on` |
| List, apply and save saved settings | `videoprompter preset list`, `preset apply Studio`, `preset save Studio --request-id studio1` |
| List cameras, with view, mirroring, rotation and framing guides | `videoprompter camera list` |
| Choose a camera | `videoprompter camera select 'FaceTime HD Camera'` |
| Show the camera behind the script (`on`), alone (`only`) or not (`off`); mirror or rotate it | `videoprompter camera set on --rotation auto` |
| Framing guides and frame marker for the selected camera | `videoprompter camera guides --thirds on --marker 9:16` |
| List microphones for Voice and for recording | `videoprompter microphone list` |
| Start recording the shown camera, with retry protection | `videoprompter record start --yes --request-id take1` |
| Stop recording and report the saved file | `videoprompter record stop --recording <id>` |
| Recording quality, microphone and audio format | `videoprompter record set --quality high --float-audio off` |
| MCP tools manifest | `videoprompter mcp-manifest` |
| Full help, with every option and its valid values | `videoprompter --help` |

Options can go before or after the command words, and flags can be written `--text-size 60`, `--text-size=60` or `--textSize=60`. `--json` prints one response line. `--show` brings the library or presenter forward, and only works with `script open` or `present`; no other command changes focus. Other commands launch the app in the background if needed and wait up to 10 seconds. Exit codes: 0 success, 1 action or connection error, 2 usage error. A bundled helper uses its own app's identity. `--data-directory /private/tmp/vpc-test` isolates app data and preferences (keep the socket path under 104 UTF-8 bytes). On its own it does not isolate the whole account or window restoration; the packaged checker also uses an isolated home folder and restoration arguments.

Every command acts through the running app, so its effect shows in the library, Settings panel, presenter or Camera window at once. Commands that would discard work refuse instead: presenter commands answer `presenter_editing` while a presenter edit is open, `script delete` answers `script_presented` for the script on screen, and recording settings and camera choice answer `recording_active` while recording. Errors carry a short `code` and a message naming the next step. Creating, importing or duplicating a script selects it, as the app does, so when several agents share one app, pass a script ID to `present` rather than relying on the selection.

`script delete` needs `--yes` and only moves the script to Recently Deleted, where `script restore` or the app's Restore button brings it back. `record start` needs `--yes`, never raises a permission prompt and needs the camera already showing, in the Camera window or behind the script after `camera set on`; the Camera window shows the timer and Stop button. Recordings go to `Movies/Video Prompter`, and `record start` returns a recording id. Stop with `record stop --recording <id>` (or `--force` to stop any recording); it reports the saved file. Camera view, mirror and rotation changes are refused while recording. Script text can be created, read and exported but not replaced, and folders and saved settings cannot be deleted from the command line, because the app has no undo for those. Window placement, full screen, the microphone test, linking files and the editor's own font remain in the app.

Claude Code:

```sh
claude mcp add videoprompter -- node "/Applications/Video Prompter.app/Contents/Resources/mcp/videoprompter-mcp.mjs"
```

Codex, in `~/.codex/config.toml` (use the absolute path from `command -v node` if the host cannot find Node):

```toml
[mcp_servers.videoprompter]
command = "node"
args = ["/Applications/Video Prompter.app/Contents/Resources/mcp/videoprompter-mcp.mjs"]
```

Change these example paths to match where you installed the app. Any other stdio MCP host needs the command `node` with the matching bundled shim path as its argument; add `--data-directory /private/tmp/vpc-test` to isolate a test connection. The shim finds its own bundled helper. You set up the host yourself; the app does not run any setup command.

The socket is `control.sock` in the app's data folder: folder permissions 0700, socket 0600, and only processes from the same user can connect. Video Prompter data and disposable test data stay separate. Creation request IDs (`script create`, `script import`, `script duplicate`, `folder create`, `preset save` and `record start`) are idempotent within one app session: a repeated ID returns the first result with `"repeated": true`. Text sent with `--text` must fit in a 64 KB request. Markdown imports are linked to the original both ways, as in the app; converted formats are not linked. Resuming Voice may ask for microphone permission if access has not been decided yet. Token savings have not been measured and are not claimed.

### Release status

Release builds are Developer ID signed, notarised and stapled, and so is the disk image. Gatekeeper acceptance is checked with `spctl` on the build Mac; the full install and removal workflow for a new user on another Mac remains unverified. Updates use Sparkle 2.10.0, as in Talk & Read. The feed is `https://juniornkanabassi.com/apps/videoprompter/appcast.xml` and each update is a zip signed with an EdDSA key kept in the login keychain (account `videoprompter`). `zsh release.sh --website <website checkout> --notes <notes.md>` builds, signs the zip, writes the appcast item, publishes `VideoPrompter_<version>.zip` and `VideoPrompter.dmg` as a release of this repository from a pushed `v<version>` tag, then verifies both downloads; `--dry-run` does everything except publish. Updates stay off in local builds and until `SUPublicEDKey` in `Resources/Info.plist` holds the real public key from Sparkle's `generate_keys --account videoprompter`.

If notarisation times out, the build retains its staged bundle or disk image and submission log in the printed temporary folder. Use the printed submission ID with `xcrun notarytool info` and the printed staple, verification and archive commands after Apple reports Accepted. Do not resubmit the same pending upload.
