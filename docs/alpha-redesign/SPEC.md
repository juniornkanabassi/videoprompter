# Alpha redesign: build spec (9 Nov 2026)

Approved by Junior from the mockups in
`/Users/junior.nkanabassi/JuniorOS/02 Projects/Development/Video Prompter/Outputs/2026-11-09 Alpha UX redesign/Mockups/` (01 to 08 PNG, 3200 × 2000).
The audits behind them are in `../Audits/` beside that folder. Read the mockups before building. They are the visual target.

The app is the Alpha (bundle id `.alpha`, `Features.recording = false`): a teleprompter plus camera reference monitor for one dyslexic creator. Plain words, big targets, nothing that disappears when he zooms in.

## Global rules for every package

- Tests never show a window and never trigger camera or microphone permission prompts. Keep `Tests/TestOffscreen`. Never `open` the app, never use computer use.
- `zsh test.sh` must pass (XCTest, snapshots, `checks/check-grid.py` spacing tokens). SwiftPM may need running outside the sandbox. `QAControlRegressionTests/testSlowSocketReaderCannotBlockOtherControlCommandsAndExpires` is a known timing flake: if only it fails, rerun it alone.
- British English in UI text, no em dashes, no hyphens as punctuation. One vocabulary everywhere: **Camera, Zebras, False colour, Guides, Mic, Clean, Adjust, Start reading, Pause, Back to start, Set up the shot, Exit Clean, Exposure key**.
- No recording words anywhere visible while `Features.recording` is false.
- Minimum hit target 44 pt. Labels never drop when the interface is enlarged; wrap or move into Adjust instead.
- Keep each package inside its listed files plus new files and tests. Commit on your branch when green. Do not push, build.sh, install or open a PR.

## Packages

### A. Exposure model and Exposure key
Files: `Camera/CameraGuides.swift`, `Camera/CameraExposure.swift`, `Presenter/ExposureLegend.swift`, new files as needed.
1. **Skin reference, independent of zebras.** A persisted per-camera `skinReference` (level, plus or minus). Pink in false colour always uses it; changing zebras never moves it. Tone presets for any user, labelled by tone not ethnicity, each with a small swatch: **Deep** 45 ±2 IRE (Junior's, default), **Medium** 55 ±3, **Fair** 65 ±3, **Custom**. Migrate existing saves: today's zebra range becomes the skin reference if it was a range, else Deep.
2. **Zebras** keep Sony Range and Limit. Each mode remembers its own values. Presets: **My skin** (Range, follows the skin reference) and **Highlights** (Limit 95+). Rename every "Clipping", "Face reference", "Bright areas", "Check brightness" string to this vocabulary.
3. **False colour names**, one table used by both the picture and every key: My skin (pink, skin reference range), Signal white 99 to 100, Near white 97 to 99, Mid grey 38 to 42, Very dark 2.5 to 4, Near black 0 to 2.5. Everything else grey. Delete the second, disagreeing key table.
4. **Exposure key view** (`ExposureKey`): a setup card as mockup 01 and 04 (large swatches 44 × 28, 19 pt semibold names, 15 pt ranges, rounded dark card), and a compact reading chip ("Zebras on", "False colour on"). It scales with the interface zoom. A one-line note: "Measured from the incoming picture."
5. Adjust sections as plain SwiftUI views for package E to host: `ZebraAdjustView` (mockup 02: presets, Range/Limit segment, Level and Plus or minus with 46 pt − and + buttons and large values, readout "Stripes on 43 to 47 IRE", note) and `FalseColourAdjustView` (on/off, skin tone presets with swatches, custom level and plus or minus, the colour list).

### B. Camera identity and Shot
Files: `Camera/CameraPicker.swift`, `Camera/CameraOrientation.swift`, `Camera/SharedCameraSession.swift`, `Camera/CameraModel.swift`, new files as needed.
1. **Camera source info** (`CameraSourceInfo`) for the active device: display name, connection kind, resolution, nominal and measured frame rate.
   - Connection kind from `AVCaptureDevice` (deviceType, transportType, manufacturer, modelID, localizedName): Built-in, USB camera, HDMI capture, iPhone (Continuity), iPad link.
   - HDMI capture: macOS only sees the capture card (Elgato Cam Link, UltraStudio, Magewell, AJA, ATEM, generic "USB Video" or "UVC"), not the camera behind it. Recognise common card names and say "HDMI capture: Cam Link 4K".
   - Cameras in USB webcam mode (Sony, Panasonic LUMIX, Canon) report their own name; show it.
   - **Nickname**: the user can name any input once ("LUMIX S1R II", "Footballco FX3"), remembered by device uniqueID, shown first everywhere.
   - Measured frame rate from frame timestamps (rolling, e.g. "25p"), shown with resolution: "LUMIX S1R II · HDMI capture · 3840 × 2160 · 25p".
2. **Shot**: three choices replace the five-way rotation picker: **Landscape** (0°), **Vertical turned left**, **Vertical turned right** (the two quarter turns, named for what the user sees). Remembered per camera. 180° and Automatic move to an Advanced disclosure.
3. `CameraAdjustView` for package E (mockup 03): camera list with nickname, connection and format lines and a checkmark on the active one, Rename, the three Shot cards with icons, one-line note. Hover must not change the live preview.
4. A status-pill text API for package E: `CameraSourceInfo.summary` and `shotSummary` ("Turned right for vertical").

### C. Mic meter
New file `Presenter/MicMeter.swift` (do not edit PresenterView.swift).
`MicMeterView`: vertical, 34 pt bar, scale labels 0, −6, −18, −30, −45, −60 in 14 pt, zone track always faintly visible (green to −18, yellow to −6, red above), white ticks at −18 and −6, peak hold, a CLIP light that latches for 2 s, a large dBFS readout ("−14 dBFS"), the mic name underneath, "No signal" when stale. Reads the existing `InputMeter`. Scales with interface zoom. Matches mockup 01. Snapshot tests for quiet, speech, hot and no signal.

### D. First launch, Settings and wording
Files: `Library/LibraryStartView.swift`, `Settings/SettingsView.swift`, `Settings/ShootSetup.swift`, `App/WelcomeScript.swift`, text strings in `Camera/CameraWindow.swift`.
1. First launch as mockup 07: "What do you want to do?", the line "Video Prompter Alpha is for reading your script and checking your camera. It does not record.", two cards: **Read a script** (Paste script, New script) and **Set up camera** (Choose camera). Practice and Help as a quiet row. Delete the fake three-step demo.
2. Settings as mockup 08: four pages, **Reading** (includes reading presets), **Camera and monitor** (camera, shot, skin reference, zebras, false colour, guides, exposure key, Advanced), **Microphone**, **App**. Rows link to the same views package A and B provide where they exist; otherwise keep the current controls in the right page.
3. Remove every recording word from visible UI: "Camera and saved-video rotation", "saved take", "Recording is separate", "Recordings" folder and similar.
4. Guides: offer Vertical 9:16, Thirds and Centre mark first (merge Centre cross and Centre target into Centre mark: dot or cross); others under Advanced.

### E. Presenter shell (after A to D are merged)
Files: `Presenter/PresenterView.swift`, `Presenter/PresenterController.swift`, new `Presenter/AdjustPanel.swift`.
1. **Set up the shot state** (mockup 01): picture fitted in the stage; Exposure key top left in the pillarbox (beside the picture, never over the face or script); `MicMeterView` on the right edge; status pills top centre (camera summary, shot). Bottom bar 132 pt: **Start reading** (primary, accent), **Back to start**, then tiles **Camera, Zebras, False colour, Guides, Mic**, separator, **Adjust**, **Clean**. Tiles 104 × 92, icon plus name always, on state = accent border and check badge, small value badge (e.g. "45 ±2", "↻ Vertical"). Tapping a tile toggles it (Camera opens Adjust at Camera). Right-click or long press on a tile opens Adjust at that section. No settings arrows.
2. **Adjust panel** (mockups 02, 03): a 470 pt right-hand panel with tabs Camera, Zebras, False colour, Guides, Mic hosting the package A, B, C views and the guides controls. Escape closes it. Replaces the Tools popover and `zebraControls`.
3. **Reading state** (mockup 05): setup tiles and full key go away; script owns the screen; key becomes the compact chip top left; meter stays (optional in Adjust > Mic); bar shows **Back to start**, big **Pause**, **Set up the shot**; Space pauses, Escape returns to setup.
4. **Clean** (mockup 06): only the picture. Entering pauses reading on the exact word. Mouse movement shows only a small **Exit Clean · Esc** pill that fades after 2 s; keyboard focus keeps it. Escape exits. Fix the flag that kept controls revealed.
5. Labels never drop at 125 to 200%: the bar wraps to two rows or moves Guides and Mic into Adjust before any name is hidden.
6. VoiceOver: tiles that toggle report On/Off; openers (Camera, Adjust) are buttons with the selected camera as value.

## Review loop (after E)
Fresh offscreen snapshots of every screen go to two independent reviewers (GPT-6.1 Sol and Claude Opus 5.5). Each grades these areas out of 10: first launch, library, editor, set up the shot, reading, Clean, bar and tiles, Adjust panel, zebras, false colour and key, mic meter, camera and shot, guides, settings, wording, accessibility, responsiveness. Anything below 9 gets a fix package. Repeat until every area is 9 or above from both reviewers.
