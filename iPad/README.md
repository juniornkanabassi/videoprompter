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

## Cameras behind the script

Under teleprompter glass the iPad's own cameras face away from you, so the picture comes in another way. Turn it on in Settings › Camera or with the camera button while presenting.

Straight into the iPad, anything that shows up as a USB webcam (UVC) works: the ATEM Mini's USB-C webcam output (the programme feed), a Sony FX3 or a7 IV set to USB Streaming, an HDMI to USB-C capture adapter, or an ordinary webcam. The iPad picks the sharpest mode up to 1080p at 25 fps or more and switches to the camera when it is plugged in. This has the least delay.

Through a Mac, connect the iPad to the Mac with a USB-C cable and choose File › Send Camera to iPad in the Mac app. The Mac sends the camera its Camera window shows (a DeckLink or ATEM feed included) as hardware H.264 at up to 1080p, through usbmuxd, the same channel Finder uses, so no network or pairing is needed beyond "Trust This Computer". With Settings › Camera from a Mac › Allow a Mac on the same Wi-Fi turned on here, and File › Also Send over Wi-Fi on the Mac, the Mac also finds the iPad over Wi-Fi with Bonjour. The Mac asks once for the pairing code the iPad shows, and the link runs over TLS keyed by that code, so only a paired Mac can send and the picture is encrypted. Turning either option off ends a Wi-Fi connection at once.

Rotation, mirroring and the framing guides apply to either source and are remembered per camera.

## Scripts from Google Docs

Add › From Google Docs on the iPad, or File › Import from Google Docs… on the Mac, copies a document in as Markdown. The code is shared (`Sources/VideoPrompter/Import/GoogleDocs.swift` and `GoogleDocsSheet.swift`), so any future Apple target gets it too. The doc stays the master: Update from Google Docs on the script fetches it again, and asks first if the script was edited since.

A pasted link works with no setup for documents shared with "Anyone with the link".

Signing in with Google lists and searches the account's documents, shared drives included, and opens documents shared only with the account (a Workspace domain's, say). It needs an OAuth client: in Google Cloud Console create a project, enable the Google Drive API, set up the consent screen with the `drive.readonly` scope, and create an OAuth client of type iOS for bundle ID `com.juniornkanabassi.VideoPrompter`. Put its client ID under `GoogleClientID` in both `iPad/Info.plist` and `Resources/Info.plist` (Google's iOS client type also serves macOS apps). Until the app is verified by Google, sign-in works for up to 100 listed test users and ends after seven days.

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

The team has no registered devices, so a signed archive fails with "No profiles were found"; archive with `CODE_SIGNING_ALLOWED=NO` and let the export sign for App Store distribution. `ExportOptions.plist` carries the team ID and uploads straight to App Store Connect, once the app record exists there. Internal testers on the team can install the build in TestFlight once it finishes processing; external testers need Apple's beta review the first time.

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
