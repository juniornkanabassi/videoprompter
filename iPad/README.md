# Video Prompter for iPad

The iPad app is for teleprompters that cannot take a computer: the iPad sits under the glass and runs the script itself, following your voice or scrolling at a set speed, the same way the Mac app does.

## What it shares with the Mac app

The Xcode project in this folder builds an iPadOS 26 app from:

- `PrompterCore` (the Swift package at the repository root): the script model, Markdown parsing and the voice tracker.
- These Mac files, compiled unchanged: `SessionStore.swift`, `PrompterSettings.swift`, `SpeechProvider.swift`, `DocumentImporter.swift`, `CameraGuides.swift` and `CameraOrientation.swift`.
- Its own files in `VideoPrompter/`: the library, presenter, settings and camera screens, and an iPad version of `AudioCapture` with the Mac's API.

A change to the voice tracking or the reading session therefore reaches both apps. Check the iPad still builds after changing any of the shared files above.

## Scripts on both devices

1. On the Mac, turn on File › Keep Scripts in iCloud Drive for iPad. Every script is copied to iCloud Drive › Video Prompter and linked to its file there. Scripts linked to other files (an Obsidian note, say) keep their link and stay on the Mac.
2. On the iPad, choose that folder when the app asks, or later in Settings › Scripts.

Edits on either side reach the other a few seconds after iCloud syncs. If both sides change the same script, the Mac keeps its version in the library's Conflicts folder and the iPad saves its version as a copy beside the file. Presets travel through `Video Prompter presets.json` in the same folder; mirroring and the microphone stay per device.

## Build

Open `iPad/VideoPrompter.xcodeproj` in Xcode 26, and run on the iPad (the project signs automatically with team M6L2VW4W5Z). From the command line:

```sh
xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  build
```

## TestFlight

1. Create the app in App Store Connect with bundle ID `com.juniornkanabassi.VideoPrompter`. The App Store name must be unique, so it may need to differ from "Video Prompter"; the home screen name stays "Video Prompter".
2. Raise `CURRENT_PROJECT_VERSION` for each upload.
3. Archive and upload:

```sh
xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter \
  -destination 'generic/platform=iOS' -archivePath /private/tmp/VideoPrompter-iPad.xcarchive \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath /private/tmp/VideoPrompter-iPad.xcarchive \
  -exportOptionsPlist iPad/ExportOptions.plist -exportPath /private/tmp/VideoPrompter-iPad -allowProvisioningUpdates
```

`ExportOptions.plist` uploads straight to App Store Connect. Internal testers on the team can install the build in TestFlight once it finishes processing; external testers need Apple's beta review the first time.

## Controls while presenting

| Key | Action |
| --- | --- |
| Space or Return | Start or pause |
| Right, Down, Page Down | Next passage (Down raises the speed in Manual) |
| Left, Up, Page Up | Previous passage (Up lowers the speed in Manual) |
| Home | Back to start |
| + and − | Larger or smaller text |
| M | Mirror on or off |
| V | Switch between Voice and Manual |
| Escape | Close the presenter |

Tap the screen to show or hide the controls. Drag to move the reading position by hand; double-tap a word to jump to it.
