# Video Prompter

Video Prompter is a teleprompter for the Mac. You write or import a script in Markdown, then read it from a floating presenter window while you record yourself. The presenter can follow your voice as you speak, or scroll at a steady speed you choose. It can also show your camera behind the script and record from it.

I record in English and French in the same take, so I built a prompter that follows both.

[Download Video Prompter](https://github.com/juniornkanabassi/videoprompter/releases/latest/download/VideoPrompter.dmg) · [Release notes](https://github.com/juniornkanabassi/videoprompter/releases/latest) · [App page](https://juniornkanabassi.com/apps/videoprompter/)

The public download is 2.0.3 (build 42). Every release uses the file name `VideoPrompter.dmg`, so the download link above always gives you the latest one. Older releases, back to the VidPrompt previews, are on the [Releases page](https://github.com/juniornkanabassi/videoprompter/releases) too.

The source version is 2.1.0 (build 45), prepared for local installation with native Settings, simpler presenter controls, undoable organisation and smoother settings saves. It has no new public download.

## Watch the quick-start guide

The [visual guide](https://juniornkanabassi.com/apps/videoprompter/#walkthrough) on the app page shows how to add a script, set up manual scrolling and use the presenter. It also introduces voice tracking and the camera background. Written setup steps sit below the video.

## What you need

- A Mac with Apple silicon. Intel Macs are not supported.
- macOS 26 or later.
- Microphone access if you use voice tracking or record, and camera access if you use the camera.
- Node.js 18 or later, but only if you want to use the MCP server with an AI assistant.

You do not need an Apple Developer account, Xcode or this source code to use the app.

## Install

1. Open `VideoPrompter.dmg`.
2. Drag Video Prompter onto the Applications shortcut in the window. If you keep apps in a named folder, make it inside Applications first and drag Video Prompter there.
3. Eject the disk image, then open Video Prompter from Applications.

The app and the disk image are signed with my Developer ID and notarised by Apple, so macOS opens them normally, though it may ask you to confirm the first time. If macOS says the app is damaged or cannot be verified, download a fresh copy from the Releases page. Please do not remove quarantine attributes or turn off Gatekeeper in Terminal to get round it.

From the first release built with Sparkle, Video Prompter checks for updates once a day and shows you each new version with its release notes. It installs only after you agree, unless you tick the option to install updates automatically, and Video Prompter › Check for Updates… checks straight away. Versions up to 2.0.2 do not update themselves, so install that first Sparkle release by hand from the disk image. Your scripts and settings stay where they are.

## First use

A new library starts with a script called Welcome to Video Prompter. Present it and read it aloud for a tour of every feature, trying each one as you go. If you delete it, Help › Practice Script brings it back.

1. Choose **Paste Copied Text** to paste a script, or use **Add** to create or import one. Pasted scripts take their title from the text.
2. Choose **Present**.
3. Open **Microphone** to check the live level, then close the popover.
4. Choose **Start reading**. **Pause** stops reading and **Controls > Back to start** returns to the first word.

Reading and recording are separate actions. With a camera shown, **Record** sits beside **Start reading**. In Script only view, **Show camera** switches the presenter to Script and camera.

Settings has five pages: **General**, **Reading**, **Reading presets**, **Microphone**, and **Camera & Recording**. General holds interface and editor sizes. Reading holds the script's appearance and following mode. The presenter's **Controls > Presenter options > Settings…** opens those same reading, microphone and camera controls in a popover.

Voice follow tracks your spoken words using speech recognition on your Mac, including mixed English and French. Automatic scroll moves at the speed you choose and needs no microphone or speech download. It waits three seconds before moving; Settings > Reading > Start delay offers Off, 3 or 5 seconds. Cancel countdown stops it. The first time you use Voice follow in a language, macOS may need to download Apple's speech files for it, so you need to be online then. A Mac that has never been online may not be ready for Voice follow. If Voice follow cannot get ready, check your connection and permissions and try again, or use Automatic scroll.

Voice tracking is still a preview. It can hesitate when your wording differs from the script while it finds the right passage, and one false-start timing check is still open. Automatic scroll is always there as a fallback.

## Scripts, camera and recording

Scripts are stored as Markdown. When you import a Markdown file it stays linked both ways with the original. Edits in Video Prompter change the file, and changes to the file appear in Video Prompter. Other formats are converted on import and are not linked.

The **Controls > View** menu switches between Script only, Script and camera, and Camera only. Open **Controls** for the camera picker, **Framing guides**, **Zebras**, **False colour** and **Exposure…**. This location stays the same while reading. **Clean view** temporarily hides the script, backdrop and all guides while reading continues. **Exit clean view** or Esc restores the script at its current reading position.

Choose **Camera Only** in the library to check framing or record without a script. Choose **Controls → Camera → Open Camera Monitor** or **Window → Open Camera Monitor** for a second-display view of the same camera. It shares the presenter’s camera and recording setup. Fresh setups prefer a physical camera and name the choice; virtual cameras must be chosen explicitly.

Drag across a passage in the presenter or editor, then choose **Pin Selected Text over Camera** from **Controls > Presenter options** or the Prompter menu (⌥⌘L). **Expand passage** reveals longer text. **Back to script** or Esc returns to reading. Clicking a word in the presenter moves the reading position. **Edit script** opens an unsaved draft; **Save changes** (⌘Return) saves it, and **Cancel editing** keeps the original wording.

**Microphone** normally chooses one device for both Voice follow and recorded sound. In Settings > Microphone > Advanced, **Record from a different microphone** enables a separate recording input. Camera, rotation and saved-video settings are locked while a take is preparing, recording or saving.

Choose **Record**, optionally **Start reading**, then **Stop recording**. While the camera starts, a cancellable Waiting message stays visible. REC appears only after the first video frame is written. The fixed transport keeps Stop visible and the REC timer sits just below it. **Controls** opens the tools without reducing the reading area. The health line shows the recording microphone, its input level and any sound problem. Dropped audio buffers are reported during the take and retained with its saved message.

Before Record, the presenter shows the output resolution, orientation and save location. Controls holds the camera choice and microphone level check. The level check starts only when Microphone is opened. **Camera** shows format, dimensions when available, saved rotation, mirroring and whether a frame marker is only a guide. Presenter controls honour the full Interface size, including 150% and 200%. The stable Controls popover holds live adjustments before and during reading. Chrome recedes while reading and returns on hover, keyboard or clicker use; its reserved area leaves at least 65% of the window for the script.

After a take, the app checks its stored video and sound. **Show saved take…** opens playback and details; **Show in Finder** is directly available. An amber **Saved with problems** names the fault and asks you to review the take. Dropped picture or sound and interrupted takes keep a warning beside the file, with a retry action. A file that fails verification is labelled incomplete, with a route to it in Finder when available. The library's **Recordings** button and Prompter > **Show Recordings Folder** reopen the folder later. Settings > Camera & Recording holds H.264, HEVC and ProRes 422 recording formats, saved-video mirroring and take names. Frame markers and exposure aids only affect the preview.

Move to Trash is reversible with **Edit > Undo** for the whole selected batch. Applying a reading preset can also be undone. Google Docs updates show progress and report **Updated** or **Already up to date**; replacing locally edited text requires an explicit choice, with Cancel selected by default.

Physical camera and microphone recording, spoken VoiceOver, active-window Liquid Glass and capture-app exclusion still need live checks. Offscreen snapshots use the solid Reduce Transparency appearance because bitmap capture cannot composite Liquid Glass.

## Privacy

Voice tracking runs on your Mac. There is no hidden fallback to cloud transcription. Your scripts are kept in `~/Library/Application Support/Video Prompter`, your settings in the app's macOS preferences, and recordings go to `~/Movies/Video Prompter` by default. The disk image also has a short install note. It contains only the app, never your data. It checks juniornkanabassi.com for updates and downloads them from GitHub, and the first time you use Voice macOS may download Apple's speech files. The command line and MCP control only work for your own user account on the same Mac.

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

## Video Prompter for iPad (in testing)

An iPad version for teleprompters that cannot take a computer is in testing through TestFlight. It follows your voice the same way, mirrors for the glass, and takes a Bluetooth clicker or foot pedal. To share scripts with it, turn on File › Keep Scripts in iCloud Drive for iPad on the Mac. See [iPad/README.md](iPad/README.md).

## Not included yet

- OBS integration.
- Editing from iPhone.

## Building from source

You need macOS 26 or later and full Xcode with Swift 6.2 or later; the Command Line Tools alone cannot build the SwiftUI app. The only dependency is Sparkle 2.10.0, which handles updates; SwiftPM fetches it.

```sh
source env.sh
zsh test.sh
zsh build.sh
```

`build.sh` signs and notarises with my Developer ID when that certificate is in the keychain. On any other Mac it uses a local signing identity if `env.sh` finds one, or signs ad hoc, and skips notarisation, which is fine for running it yourself. Set `VIDEOPROMPTER_LOCAL_SIGNING=1` to skip notarisation even when the certificate is there. Building, checking a built app, the installer and the release steps are covered in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Licence

Copyright (C) 2026 Junior Nkanabassi. Licensed under the GNU General Public License v3.0 or later (GPL-3.0-or-later); see [LICENSE](LICENSE). The Video Prompter name and icon are not covered by the licence.

In plain terms, you can use, change and share this code, but anything you distribute that is built on it has to stay open source under the same licence.

The bundled Lexend fonts are under the SIL Open Font License, in [Resources/Fonts/OFL.txt](Resources/Fonts/OFL.txt), and Sparkle, which handles updates, is under the MIT licence.

### Reading and exposure controls

The **Reading mode** button in **Controls** names the mode and status. Its chevron opens mode and speed controls; the current speed or voice-follow behaviour is described there. **End of script** is distinct from a pause, with **Back to start** and **Read again**; finishing a script never stops a recording.

At ordinary and compact sizes, **Camera**, **Text**, **Microphone** and **Edit script** have named controls. **Controls > Back to start** returns to the opening. **Camera** opens the camera picker, framing, exposure, output settings and the optional second Camera Monitor. During a take, **Zebras**, **False colour** and **Clean view** remain in the same Controls popover.

Exposure presets distinguish bright areas, a qualified face reference, and custom measurements. Editing a level selects Custom. Custom bands are never presented as face targets, and near-white levels carry a warning. Camera rotation changes both the preview and saved take; frame markers do not crop the recording.
