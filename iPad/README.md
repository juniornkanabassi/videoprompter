# Video Prompter for iPad

The iPad app is for teleprompters that cannot take a computer: the iPad sits under the glass and runs the script itself, following your voice or scrolling at a set speed, the same way the Mac app does.

## What it shares with the Mac app

The Xcode project in this folder builds an iPadOS 26 app from:

- `PrompterCore` (the Swift package at the repository root): the script model, Markdown parsing and the voice tracker.
- These Mac files, compiled unchanged: `SessionStore.swift`, `PrompterSettings.swift`, `SpeechProvider.swift`, `DocumentImporter.swift`, `CameraGuides.swift`, `CameraExposure.swift` and `CameraOrientation.swift`.
- Its own files in `VideoPrompter/`: the library, presenter, settings and camera screens, and an iPad version of `AudioCapture` with the Mac's API.

A change to the voice tracking or the reading session therefore reaches both apps. Check the iPad still builds after changing any of the shared files above.

## Camera and microphone cards

The presenter’s Camera and Mic carets open device cards grouped under the connected Mac and This iPad. The chosen card has a yellow border and tick. Microphone cards offer a live level meter and channel selection where supported. Choosing a Mac microphone starts voice following on the Mac for the script currently presented on the iPad; choosing an iPad microphone stops the Mac relay. This requires an updated Mac app. Older Macs retain microphone switching when their relay is already selected.

With no Mac connected, Connect to a Mac opens the connection page. The iPad’s local cameras and microphones remain available. Camera cards show the device’s reported connection and format; these describe the source, not a guarantee of the received link resolution.

## Scripts on both devices

1. On the Mac, turn on File › Keep Scripts in iCloud Drive for iPad. Every script is copied to iCloud Drive › Video Prompter and linked to its file there. Scripts linked to other files (an Obsidian note, say) keep their link and stay on the Mac.
2. On the iPad, choose that folder when the app asks, or later in Settings › Scripts.

Edits on either side reach the other a few seconds after iCloud syncs. If both sides change the same script, the Mac keeps its version in the library's Conflicts folder and the iPad saves its version as a copy beside the file. Presets travel through `Video Prompter presets.json` in the same folder; mirroring and the microphone stay per device.

## Cameras behind the script

Under teleprompter glass the iPad's own cameras face away from you, so the picture comes in another way. Turn it on in Settings › Camera or with the camera button while presenting.

Straight into the iPad, anything that shows up as a USB webcam (UVC) works: the ATEM Mini's USB-C webcam output (the programme feed), a Sony FX3 or a7 IV set to USB Streaming, an HDMI to USB-C capture adapter, or an ordinary webcam. The iPad picks the sharpest mode up to 1080p at 25 fps or more and switches to the camera when it is plugged in. This has the least delay.

Through a Mac, connect the iPad to the Mac with a USB-C cable and open Video Prompter on both devices. The Mac connects automatically. Opening Camera Only or a presenter with a picture asks the Mac to send its camera; camera controls are in the Mac’s iPad window. The Mac sends the camera its Camera window shows (a DeckLink or ATEM feed included) as hardware H.264 at up to 1080p, through usbmuxd, the same channel Finder uses, so no network or pairing is needed beyond "Trust This Computer". With Settings › Camera from a Mac › Allow a Mac on the same Wi-Fi turned on here, and Connect over Wi-Fi in the Mac’s iPad window, the Mac also finds the iPad over Wi-Fi with Bonjour. The Mac asks once for the 16-character pairing key the iPad shows (80 random bits, so a recorded handshake cannot be guessed offline), and the link runs over TLS keyed by it, so only a paired Mac can send and the picture is encrypted. Turning either option off ends a Wi-Fi connection at once.

Alternatively, choose the iPad under Nearby iPads on the Mac. Compare the six-digit number on both screens before tapping Allow on the iPad. That comparison prevents another device on the Wi-Fi from substituting its request. Requests expire after one minute. Forget removes the Mac's credential. Older peers can still use the hidden typed-key fallback; forgetting a legacy Mac rotates that shared legacy key, so other legacy Macs must pair again.

Pairing and the camera stream use separate listeners. Pairing listeners never accept remote-control commands. The QR endpoint uses a random temporary TLS PSK; the nearby-device handshake uses ephemeral Curve25519 keys and authenticated encryption, with the matching number binding the local Allow decision to the requesting Mac. The camera link retains its existing TLS transport.

Rotation, mirroring and the framing guides apply to either source and are remembered per camera.

Zebras and false colour use the Mac's exposure tables and stripe geometry on both local capture and decoded Mac frames. The presenter hides the aids while reading without changing the saved camera settings; Camera Only and Monitor only keep them visible. Analysis runs off the main thread with at most one outstanding frame, so a slow analysis pass cannot queue up stale pictures. Full-range camera luma is sampled directly; other formats are normalised through Core Image. The GPU applies the shared Mac LUT without blending adjacent exposure bands.

## Controlling the iPad from the Mac

Window › iPad… (⌥⌘I), or the iPad button on the start screen, library toolbar or presenter setup bar, opens the iPad window. Choose a script from the script menu to send and open it, then start or pause, move by passage, or drag the reading bar. Space starts or pauses; Up and Down move by passage. Voice selects this Mac, the iPad, or automatic scrolling. The bottom setup bar holds Camera, Mic, the live microphone meter and the iPad device menu. The main picture uses the Mac’s own live capture, behind the script when requested, and a thumbnail in script-only mode. More holds picture, quality, mirror, flip, clean screen, countdown, text layout, fonts, presets, zebras, false colour, framing guides and the exposure key. Choose another paired iPad in the device menu to switch directly, or use Rename, Disconnect and Forget. An iPad can also be named on its Connect to a Mac page; that name is saved on the iPad. The live replica stays upright and follows the iPad’s current word. It uses the same USB-C or paired Wi-Fi link as the camera, with or without the camera being sent, and closing the window ends its voice relay while the shared link stays available. `videoprompter ipad` does the same from the command line and MCP, and confirms each change from what the iPad reports back. The iPad needs this version or later; an older iPad build is left alone. `checks/ipad-link-e2e.sh` tests the whole link against the iPad app in a Simulator, with nothing on screen.

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

### Alpha and Beta colours

The iPad app can wear the same channel colours as the Mac app: the white icon is the release, orange is Alpha and blue is Beta. Only the icon and the name under it change. The bundle ID stays `com.juniornkanabassi.VideoPrompter`, so a coloured build installs over the release on an iPad, updates it in place and keeps its scripts. Pass two build settings:

```sh
# Alpha: orange icon, "Video Prompter Alpha"
xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates ASSETCATALOG_COMPILER_APPICON_NAME=AppIconAlpha VP_DISPLAY_NAME="Video Prompter Alpha" build
# Beta: blue icon, "Video Prompter Beta"
xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates ASSETCATALOG_COMPILER_APPICON_NAME=AppIconBeta VP_DISPLAY_NAME="Video Prompter Beta" build
```

Leave both out for the white release icon and "Video Prompter" (the defaults, `AppIcon` and `VP_DISPLAY_NAME`). The same two settings work with `archive`. The icon sets are in `VideoPrompter/Assets.xcassets`, made from the Mac masters in `Resources/AppIcon`.

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

## Offscreen presenter comparison

`OUT=/private/tmp/vp-ipad-hud/after zsh checks/ipad-presenter-shots.sh` uses a disposable headless simulator. It captures Setup, Camera Only, Reading with camera, Mirrored + Flipped and Mac lost at 1180 × 820, 1366 × 1024 and 834 × 1194. `DERIVED_DATA` can reuse a previous build directory. The fixture uses a generated neutral reference image, silent manual playback and isolated simulator documents; it never needs a camera or microphone. The matching Mac fixture is `AppearanceSnapshotTests/testPadHUDMacReferences` with `VIDEOPROMPTER_SNAPSHOTS` set to the output directory.
