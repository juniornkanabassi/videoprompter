# Video Prompter Alpha redesign, review round 1 (Claude Opus 5.5)

Branch `claude/alpha-hud` at 7d95117. Read only. Evidence: mockups 01 to 09, `/private/tmp/VideoPrompter-alpha-r1/*.png`, `artifacts/package-e/*.png`, and the source.

Caveat on evidence. `artifacts/package-e/*` was captured on `alpha-redesign/e-shell` **before** A2 (skin tone portraits) was merged, so its False colour tab shows the old four dots. The r1 presenter shots (`presenter-idle-camera-*`, `presenter-dark`) are 1000 × 700 pt windows with no camera picture, and `presenter-clean-view-*` is entirely black, so Clean's exit pill is not evidenced at all. I graded what is on screen and in code, not what the reports claim.

## Grades

| Area | Grade | Why, in one line |
|---|---|---|
| First launch | 6 | Right words and structure, but system blue icons, no yellow primary, no button icons, and three loud pills where the mockup has one quiet line. |
| Library | 6 | Unchanged from before; tip says "Present, then Start reading." in small grey text and the Present button lives in a toolbar the snapshots cannot show. |
| Editor | 5 | The presenter edit bar is two small default buttons with no primary and a 13 pt status line, against a 92 pt transport everywhere else. |
| Set up the shot | 6 | Matches mockup 01 at 2000 pt wide; at a normal 1000 pt window the bar wraps and at 200% the stage disappears. |
| Reading | 7 | Close to mockup 05, but Pause is not bigger, the chip has no icon and the "Space pauses · Esc returns" hint is missing. |
| Clean | 8 | Picture only, exact-word pause in code; the exit pill has no visual evidence and no icon. |
| Bar and tiles | 5 | Zebras and False colour icons are near twins, value badges are 11 pt, and the bar wraps with Mic orphaned on a second row. |
| Adjust panel | 6 | Right structure, but uneven insets, a scroll view inside a scroll view, checkboxes, and a Settings form pasted into the Mic tab. |
| Zebras | 7 | Behaviour right; lost the mockup's sub-labels, full-width Range/Limit control, large values and the striped readout card. |
| False colour and key | 7 | One table, correct names, the key card is good; the adjust tab starts with a tiny checkbox and has no heading. |
| Skin tone and grey card | 7 | Portraits are good; the selection ring is system blue outside the panel, Custom is taller than its row, grey card uses a checkbox in Settings. |
| Mic meter | 7 | Excellent at full height; scale labels collide and the readout truncates to "dB…" when the stage is short. |
| Camera and shot | 6 | Three shot cards are right; the camera line lacks resolution and frame rate, and Settings still offers a "0°" rotation picker. |
| Guides | 4 | Three 16 pt checkboxes with no pictures, Centre mark style missing, Advanced opens a fixed 600 pt legacy form. |
| Settings | 5 | Not mockup 08: no summary rows with values, extra segmented pickers inside pages, degrees, Title Case and an orphan "Off" row. |
| Wording | 6 | Core vocabulary is in; "Present", "Rotation", "Test Microphone", "Narrow Column" and other Title Case strings remain. |
| Accessibility | 6 | 44 pt tiles and On/Off values are in; missing toggle and selected traits, 11 pt badges, small checkboxes and a long-press gesture on a Button. |
| Visual consistency | 5 | Three selection colours, three toggle styles, two meter designs and three different content insets. |
| Responsiveness | 4 | At 200% in a 1000 × 700 window the bar takes about 665 of 700 pt; at 150% the meter labels overlap; first launch pushes the camera card off screen. |

Nothing reaches 9. The single biggest problem is responsiveness of the setup bar, because it breaks the one promise of the spec ("nothing disappears when he zooms in") by making the picture disappear instead.

## Regressions against the mockups

1. **Zebras tile icon** is `circle.lefthalf.striped.horizontal` (PresenterView.swift:265). Mockup 01 uses a striped square. Next to False colour's `circle.lefthalf.filled` (line 266) the two are almost identical at a glance.
2. **Status pill** falls back to the bare word "Camera" (PresenterView.swift:189); mockup shows "Sony FX3 · 3840 × 2160 · 25p". Pills are 12 pt callout with 8 pt padding; mockup is about 15 pt.
3. **Exposure key** reads "43 to 47 IRE"; mockup 01 reads "Skin, 43 to 47 IRE".
4. **Zebra adjust**: no "Centre of the stripes" or "How wide the band is" sub-labels, no "Is my face exposed right?" on presets, Range/Limit is a small segmented control beside a "Mode" label instead of full width, − and + are 13 pt glyphs in 46 pt boxes, values are "45 IRE" at one size instead of big "45" plus small "IRE", and the readout is plain bold text instead of the stripe-swatch card.
5. **Camera adjust**: the card line says only "HDMI capture"; mockup says "3840 × 2160 · 25p · HDMI". Content is inset 16 pt more than the other tabs (CameraAdjustView.swift:45 adds `.padding(Space.md)` inside the panel's 24 pt).
6. **Shot in Settings** is a "0°" pop-up (CameraWindow.swift:155, `model.rotationChoice`), with the footer "Rotation changes the camera picture." (line 160). Spec B2 removed degrees.
7. **First launch**: icons are system blue (LibraryStartView.swift:48 uses `Color.accentColor`, which is blue in the library window), "Paste script" is not yellow, buttons have no icons, and "Practice · Help" became three bordered pills plus an extra "Import file…" (lines 24 to 28).
8. **Settings Camera and monitor** is a long form with an inner Camera / Guides / Exposure segmented control, not the eight summary rows with values and chevrons in mockup 08.
9. **Reading**: "Pause" is the same 18 pt size as the other two buttons; mockup makes it the dominant control. The "Zebras on" chip lost its stripe icon. The bottom right hint "Voice follow · on / Space pauses · Esc returns" is gone.
10. **Selection colour**: skin tone and zebra preset selection use `Color.accentColor` (ExposureLegend.swift:441 and 502). Inside the Adjust panel it is tinted yellow, in Settings it renders blue (`alpha-settings-Camera and monitor-dark.png`). Mockup 09 is yellow everywhere.

## Fixes to reach 9, ranked by impact

### 1. Responsiveness and the setup bar (Responsiveness 4, Bar and tiles 5, Set up the shot 6)

Evidence: `presenter-idle-camera-200-dark.png` (stage about 35 pt tall, meter labels "−60" over "−30"); `presenter-idle-camera-100-dark.png` (bar wraps at 100%, Mic alone on row 2 with the separator orphaned); `presenter-idle-camera-150-dark.png`.

- PresenterView.swift:256. Replace `WrapLayout(distributeAfter: 2)` with a staged fit, tried in order with `ViewThatFits(in: .horizontal)`:
  1. One row as now.
  2. One row with transport buttons at their natural width (drop `minWidth: 190` at line 284 to 0, keep 92 pt height).
  3. One row with Guides and Mic removed from the bar and shown as rows at the top of Adjust (the spec's own fallback). Show a small "2 more in Adjust" badge on the Adjust tile.
  4. Two rows only as a last resort: transport buttons on row 1, tiles on row 2, never a single orphan tile.
- Cap the bar so the stage always keeps at least 50% of the window height. If even step 4 exceeds that, scale tiles down to 88 × 80 before dropping anything. Never let the bar push the picture below about 240 pt.
- Put the separator only between Mic and Adjust when they are on the same row; hide it when a row break falls there.
- Add snapshot tests at 1000 × 700 and 1280 × 800 for 100, 125, 150 and 200%, asserting stage height ≥ 50% of window and every tile label present.

### 2. Settings to mockup 08 (Settings 5, Camera and shot 6, Wording 6)

- SettingsView.swift:112. Delete the "Reading section" segmented picker. Put reading presets as a section at the bottom of the Reading page.
- Camera and monitor page: replace the inner Camera / Guides / Exposure picker with mockup 08's rows. Each row: 17 pt semibold title, 14 pt secondary line, current value plus chevron on the right, 64 pt minimum height. Rows: Camera ("Sony FX3"), Shot ("Vertical, turned right"), My skin reference ("45 ±2 IRE"), Zebras ("Range 45 ±2"), False colour ("On"), Guides ("Thirds"), Exposure key ("On"), Advanced. Each pushes the same `CameraAdjustView`, `ZebraAdjustView`, `FalseColourAdjustView` and guides view the Adjust panel uses.
- CameraWindow.swift:155 and 160. Replace the degrees picker with the three shot cards from `CameraAdjustView`. Delete the "Rotation changes the camera picture." footer. Move 180° and Automatic under Advanced.
- App page: delete the duplicate "Interface size" section header (keep the row), delete the orphan "Off" row under iPad (SettingsView.swift:628 area: give that picker a label or remove it), and sentence-case "Keep scripts in iCloud Drive for iPad" (line 680) and "Also connect over Wi-Fi" (line 685).
- Microphone page: "Test microphone" (line 399), "Speech recognition" (line 644). Replace the horizontal segmented meter with a horizontal version of `MicMeterView` colours and labels so there is one meter design.

### 3. One control vocabulary and one accent (Visual consistency 5, Adjust panel 6, Accessibility 6)

- Use yellow for every selection ring: replace `Color.accentColor` with the app's accent token at ExposureLegend.swift:441 and 502, and LibraryStartView.swift:48. Or set `.tint(.yellow)` on the Settings and library windows.
- Every on/off in Adjust and Settings uses `.toggleStyle(.switch)` with the label on the left and the switch on the right, at least 44 pt row height. Today: checkbox at AdjustPanel.swift:39, 51 to 53 and ExposureLegend.swift:523 and 528; switch in the grey card mockup.
- One content inset for every Adjust tab: remove `.padding(Space.md)` and the inner `ScrollView` at CameraAdjustView.swift:13 and 45, because AdjustPanel already wraps every tab in a ScrollView with 24 pt padding (AdjustPanel.swift:31 and 44).
- Every Adjust tab starts with the same header: 22 pt bold title, then one 15 pt secondary line. False colour today starts with a checkbox and a "Skin tone" subheading.
- Mic tab (AdjustPanel.swift:38 to 41): do not embed `MicrophonePage(compact:)`, which renders a card inside a card. Build a flat tab: title "Mic", a "Show mic meter" switch, microphone picker row, a live horizontal meter, and "More in Settings" link.

### 4. Bar and tiles detail (Bar and tiles 5)

- PresenterView.swift:265. Zebras icon: draw the same diagonal stripe swatch used in the Exposure key (ExposureLegend.swift:391) in a 24 × 18 rounded rectangle, or use `rectangle.pattern.checkered` until then. False colour keeps `circle.lefthalf.filled`.
- Line 299. Value badges from 11 pt to 13 pt semibold; show "↻ Right" or "↺ Left" for the Camera tile instead of "↻ Vertical" for both turns (line 264 ignores which way).
- Line 293. Tile icon `.title2` (about 17 pt) to 24 pt, as in the mockup.
- Line 281. Transport label from 18 pt to 22 pt bold for Start reading and Pause; 18 pt semibold for the secondary ones.
- Lines 306 and 307. Drop `.onLongPressGesture` on the Button: on macOS it can delay or swallow the tap. Keep the context menu for right-click and add a press-and-hold via `simultaneousGesture(LongPressGesture(minimumDuration: 0.5))`, then test that a normal click still toggles.

### 5. Guides (Guides 4)

- AdjustPanel.swift:48 to 58. Replace the three checkboxes with three 140 × 96 picture cards (the Shot cards' style): a small drawing of 9:16 frame lines, the thirds grid and the centre mark, with the name below, yellow ring when on.
- Add the spec D4 "Centre mark: Dot or Cross" choice as a two-option segmented row under the Centre mark card when it is on. Today line 53 forces `bullseye = false`, so the dot style is unreachable.
- Line 55. Remove `.frame(height: 600)` around `CameraGuideSettings`. Show the other shapes as a list of switches inside Advanced at natural height.
- Add a one-line note: "Guides are drawn on the monitor only."

### 6. Zebras adjust to mockup 02 (Zebras 7)

- ExposureLegend.swift:427. Remove the "Mode" label and make Range | Limit full width, 44 pt tall, 15 pt semibold.
- `ExposureNumberRow` (line 447 on): title 17 pt semibold plus a 14 pt secondary line ("Centre of the stripes", "How wide the band is"). − and + as `Image(systemName: "minus" / "plus")` at 20 pt in the 46 pt buttons. Value: number 32 pt semibold, unit "IRE" 15 pt secondary.
- Preset cards: add the question line ("Is my face exposed right?", "Is anything too bright?").
- Readout: a 56 pt card with the stripe swatch and "Stripes on 43 to 47 IRE" at 17 pt semibold.
- Line 431. Use the mockup's fuller note: "Each mode keeps its own values, so switching to Limit and back does not lose your 45 ±2. Your skin colour in false colour is set separately."

### 7. First launch to mockup 07 (First launch 6)

- LibraryStartView.swift:37. Paste script: yellow fill, black 17 pt semibold text, `doc.on.clipboard` icon. New script: `plus` icon. Choose camera: `video` icon.
- Line 48. Icons yellow, 32 pt.
- Lines 24 to 28. Replace the three bordered pills with one quiet text row: "Practice with an example script · Help" as plain link buttons, 15 pt secondary, each at least 44 pt tall. Move "Import file…" into the Read a script card as a third button or the File menu.
- Line 52. Remove `minHeight: 260` so the cards hug their content, and align the two cards' titles: both icons in a fixed 40 pt tall frame (today "Read a script" sits 10 pt lower than "Set up camera").
- At 200% (`first-launch-200-dark.png`) the second card is below the fold. Hide the library sidebar on first launch or let the cards shrink to one column inside the visible height.

### 8. Mic meter in short stages (Mic meter 7)

- MicMeter.swift:47 to 53. Hide −30 and −45 labels when the bar is under 260 pt tall, and hide −6 when under 160 pt, so labels never overlap (`alpha-vertical-mic-speech.png`, `presenter-idle-camera-150-dark.png`).
- Line 77. Split the readout: number 22 pt semibold, "dBFS" 13 pt secondary, with `.minimumScaleFactor(0.7)` and `.lineLimit(1)`, so "−12 dB…" never happens.
- Line 38. "MIC" in 13 pt semibold with tracking, matching "EXPOSURE KEY".

### 9. Reading (Reading 7)

- PresenterView.swift:258. Pause: 240 pt minimum width and 22 pt bold label so it is the biggest control, as in mockup 05.
- ExposureKey compact chip (ExposureLegend.swift:383): add the stripe swatch for "Zebras on" and a mini colour strip for "False colour on", 15 pt text, 36 pt tall.
- Add the bottom right hint, 14 pt secondary: "Voice follow · on" and "Space pauses · Esc returns".

### 10. Editor and library (Editor 5, Library 6)

- PresenterView.swift:244 to 248. Editing bar: "Save changes" as a yellow 92 pt transport button and "Cancel editing" as a secondary one, through `transportButton`. Status line 15 pt.
- LibraryStartView.swift:59 and 64, PresenterView.swift:120, LibraryView.swift:180. "Present" is not in the spec vocabulary. Use "Open the prompter" (or rename the toolbar action to match), for example "Choose a script, then Start reading." The tip should be 15 pt primary, not 75% opacity callout.
- ReadingInspectorView.swift:34 and 40. "Show in prompter" and "Narrow column" in sentence case. "Show in Presenter" currently renders disabled and grey in `alpha-settings-Reading-dark.png`; either enable it or hide it when no script is selected.

### 11. Camera and shot (Camera and shot 6)

- CameraAdjustView.swift:57. The detail line must be resolution, frame rate and connection ("3840 × 2160 · 25p · HDMI capture"). The `replacingOccurrences` trick drops the format when `sourceInfo` is nil.
- Line 31. Make Rename a small trailing text button or a context menu item; today it is as loud as the row.
- Lines 36 to 38. Use `rectangle.portrait.rotate`-style icons at 28 pt and show the turn arrow next to the word, as in mockup 03.
- Lines 41 to 44. Advanced: show Upside down and Automatic as selectable cards with a ring, not bare buttons with no state.
- Add evidence with two or more cameras in the Adjust panel (the r1 set only has one).

### 12. Set up the shot details (Set up the shot 6)

- PresenterView.swift:189. Fallback text "No camera chosen" and make the pill a button that opens Adjust at Camera.
- Pill font 15 pt semibold, 10 pt vertical padding.
- ExposureKey: "Skin, 43 to 47 IRE" when the My skin preset is active.
- `presenter-idle-camera-100-dark.png` shows the stage split into dark grey left and black right with no picture. Give the empty stage one colour and a centred "Choose a camera" button.
- `presenter-dark.png` (no camera): Mic tile is on but no meter appears. Either show the meter or make the tile state match.

### 13. Clean (Clean 8)

- Line 185. Use `Label("Exit Clean · Esc", systemImage: "xmark")`, 15 pt semibold, as mockup 06.
- Capture a snapshot of the revealed pill with a camera fixture; the current `presenter-clean-view-*` is all black.

### 14. Skin tone and grey card (7)

- ExposureLegend.swift:477 on. Fix the Custom card height so the row lines up (it is about 12 pt taller in `alpha-settings-Camera and monitor-dark.png`).
- Line 512. Add a pink swatch to the "Pink shows skin…" bar, as in mockup 09, and use a neutral card background instead of dark red.
- Line 528. Grey card check as a switch on the right of the card.

### 15. Accessibility (6)

- PresenterView.swift:304. Add `.accessibilityAddTraits(.isToggle)` on tiles that toggle, and `.isSelected` on the selected Adjust tab (AdjustPanel.swift:27) and shot cards (CameraAdjustView.swift:74) instead of the value "Selected".
- Raise all secondary text inside the dark panel to at least 4.5:1 (the 15 pt grey on 0.07 white is borderline).
- Every checkbox replaced by a switch row (fix 3) also fixes the 16 pt hit targets in Guides and False colour.

### 16. Wording sweep (6)

Sentence case everywhere: "Test microphone", "Stop test", "Speech recognition", "Narrow column", "Also connect over Wi-Fi", "Keep scripts in iCloud Drive for iPad". Replace "Present" and "Presenter" in visible text with the spec vocabulary. Remove "Rotation" from visible labels (CameraWindow.swift:85, 160, 411). Make the false colour footers agree: the key says "Everything else shows in grey", the panel says "Grey shows brightness between these bands." Pick the first.

## What I did not check

I did not run the app or tests, VoiceOver, live camera, real Liquid Glass rendering or hover behaviour on the shot cards. Light mode presenter shots are identical to dark (the presenter forces dark), so light mode was only judged on Settings and first launch.
