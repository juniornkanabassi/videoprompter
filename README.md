# Video Prompter

Video Prompter is a teleprompter for the Mac. You write or import a script in Markdown, then read it from a floating presenter window while you record yourself. The presenter can follow your voice as you speak, or scroll at a steady speed you choose. It can also show your camera behind the script and record from it.

I record in English and French in the same take, so I built a prompter that follows both.

[Download Video Prompter](https://github.com/juniornkanabassi/videoprompter/releases/latest/download/VideoPrompter.dmg) · [Release notes](https://github.com/juniornkanabassi/videoprompter/releases/latest) · [App page](https://juniornkanabassi.com/apps/videoprompter/)

The current release is 2.0.2 (build 41). Every release uses the file name `VideoPrompter.dmg`, so the download link above always gives you the latest one.

## Watch the quick-start guide

The [visual guide](https://juniornkanabassi.com/apps/videoprompter/#walkthrough) on the app page shows how to add a script, set up manual scrolling and use the presenter. It also introduces voice tracking and the camera background. Written setup steps sit below the video.

## What you need

- A Mac with Apple silicon. Intel Macs are not supported.
- macOS 26 or later.
- Microphone access if you use voice tracking, and camera access if you use the camera.
- Node.js 18 or later, but only if you want to use the MCP server with an AI assistant.

You do not need an Apple Developer account, Xcode or this source code to use the app.

## Install

1. Open `VideoPrompter.dmg`.
2. Drag Video Prompter onto the Applications shortcut in the window. If you keep apps in a named folder, make it inside Applications first and drag Video Prompter there.
3. Eject the disk image, then open Video Prompter from Applications.

The app and the disk image are signed with my Developer ID and notarised by Apple, so macOS opens them normally, though it may ask you to confirm the first time. If macOS says the app is damaged or cannot be verified, download a fresh copy from the Releases page. Please do not remove quarantine attributes or turn off Gatekeeper in Terminal to get round it.

Video Prompter does not update itself yet. To get a newer version, download the disk image again and replace the app. Your scripts and settings stay where they are.

## First use

1. Choose Add to import a file, or create a New Script.
2. Open Settings and choose Voice or Manual.
3. Press Present.
4. In the presenter, press Start. Pause stops, and Back to start returns to the first word.

New libraries start with simple controls. More in Settings reveals the detailed appearance, voice and saved settings. Showing or hiding them does not change anything you have saved.

Voice follows your spoken words using speech recognition on your Mac, including mixed English and French. Manual scrolls at the speed you choose and needs no microphone or speech download. The first time you use Voice, macOS may need to download Apple's speech files, so you need to be online for that once. A Mac that has never been online may not be ready for Voice. If Voice cannot get ready, check your connection and permissions and try again, or use Manual.

Voice tracking is still a preview. It can hesitate when your wording differs from the script while it finds the right passage, and one false-start timing check is still open. Manual scrolling is always there as a fallback.

## Scripts, camera and recording

Scripts are stored as Markdown. When you import a Markdown file it stays linked both ways with the original: edits in Video Prompter change the file, and changes to the file appear in Video Prompter. Other formats are converted on import and are not linked.

While the camera is on, the presenter bar has a camera switcher and Framing guides (rule of thirds, a centre cross, a centre target and a frame marker). Recording is in the Camera toolbar and uses the preview format you have pinned, up to 1920×1080. I have not yet tested recording with a wide range of real cameras and microphones. The presenter window is normally hidden from screen capture, so it should not appear in a screen recording, though I have not tested every recording and screen-sharing app.

## Privacy

Voice tracking runs on your Mac. There is no hidden fallback to cloud transcription. Your scripts and settings are kept in your user account in `~/Library/Application Support/Video Prompter`, and recordings go to `~/Movies/Video Prompter` by default. The disk image also has a short install note. It contains only the app, never your data. The command line and MCP control only work for your own user account on the same Mac.

## Command line and AI assistants

The app includes a `videoprompter` command and an MCP server, so you can drive it from Terminal or from Claude, Codex and other assistants. They use the same actions as the buttons in the app, and the result shows in the app straight away.

The command lives inside the app:

```sh
VP="/Applications/Video Prompter.app/Contents/Helpers/videoprompter"
"$VP" --help
"$VP" status --json
"$VP" script import ./script.md --request-id take1
"$VP" present 'My Script'
"$VP" pause
```

To connect the MCP server to Claude Code:

```sh
claude mcp add videoprompter -- node "/Applications/Video Prompter.app/Contents/Resources/mcp/videoprompter-mcp.mjs"
```

For Codex, add this to `~/.codex/config.toml`:

```toml
[mcp_servers.videoprompter]
command = "node"
args = ["/Applications/Video Prompter.app/Contents/Resources/mcp/videoprompter-mcp.mjs"]
```

Change the paths if you installed the app somewhere else. The full command list, the safety rules and the socket details are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#command-line-and-ai-control).

## Remove Video Prompter

Quit Video Prompter and move the app to the Bin. That does not delete your scripts or recordings; they stay in the folders listed under Privacy until you remove them yourself. If you linked the `videoprompter` command onto your PATH or connected an AI assistant, remove those separately.

## Earlier names

Video Prompter was called VidPrompt before 2.0.0, and JuniorPrompter before that. It keeps the same bundle identifier, so your settings carry over, and the library moves to the new `Video Prompter` folder on first launch. Existing recordings move the first time you record. If the move cannot finish, it carries on using the original folder. macOS may ask for camera or microphone permission again because the signing identity changed.

Quit VidPrompt before opening Video Prompter. Once you have checked your scripts are there, move the old `VidPrompt.app` to the Bin so you only have one copy. A JuniorPrompter library is not imported automatically, so keep it and its backups until you have recovered what you need.

## Not included yet

- Automatic updates.
- OBS integration.
- Editing from iPhone or iCloud.

## Building from source

You need macOS 26 or later and full Xcode with Swift 6.2 or later; the Command Line Tools alone cannot build the SwiftUI app. The project has no external package dependencies.

```sh
source env.sh
zsh test.sh
zsh build.sh
```

`build.sh` signs and notarises with my Developer ID when that certificate is in the keychain. On any other Mac it signs the build ad hoc and skips notarisation, which is fine for running it yourself. Set `VIDEOPROMPTER_LOCAL_SIGNING=1` to skip notarisation even when the certificate is there. Building, checking a built app, the installer and the release steps are covered in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Licence

The licence for Video Prompter's own code is in [LICENSE](LICENSE). The name and icon are not covered by it. The bundled Lexend fonts are under the SIL Open Font License, in [Resources/Fonts/OFL.txt](Resources/Fonts/OFL.txt).
