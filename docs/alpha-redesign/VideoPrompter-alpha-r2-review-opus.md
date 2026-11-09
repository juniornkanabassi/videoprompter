# Video Prompter Alpha redesign, review round 2 (Claude Opus 5.5)

Branch `claude/alpha-hud` at 5a7775a. Read only. Evidence: mockups 01 to 09, fresh captures in `/private/tmp/VideoPrompter-alpha-r2/` (all timestamped 9 Nov 07:00 to 07:02, so `f1-`, `f2-`, `f3-`, `f4-`, `r2-adjust-` are current), and the source. Yellow native placeholders and the fixture picture are not graded as defects. In the `r2-adjust-*` captures the pill says "No camera chosen" while a picture shows; that is the fixture (reference picture, no `sourceInfo`), not a product bug.

## Verdict

Large step up. Responsiveness went from 4 to 8: the picture now keeps about half the window at 200%, Guides and Mic fold into Adjust with a "2 more" badge, and the meter switches to a horizontal bar when short. Clean and First launch reach ship quality. Nothing else is at 9 yet; the gaps are now polish and consistency, not structure.

## Grades

| Area | R1 | R2 | Why, in one line |
|---|---|---|---|
| First launch | 6 | **9** | Matches mockup 07 at 100%; at 200% collapses to two big labelled rows, both visible. |
| Library | 6 | 8 | Calm and consistent wording, but at 200% in a narrow window the header and tip eat the whole editor. |
| Editor | 5 | 8.5 | Save and Cancel are now proper transport buttons; labels touch the button edges and the status line is 13 pt. |
| Set up the shot | 6 | 8 | Picture dominant at every size, key in the pillarbox; the source pill wraps into a ragged centred block with orphan "·". |
| Reading | 7 | 8 | Big Pause, chip with swatch, status and keyboard hint all in; at 200% the chip sits on top of the first script line. |
| Clean | 8 | **9.5** | Picture only, "✕ Exit Clean · Esc" pill now evidenced (`f1-exit-pill-visible.png`). |
| Bar and tiles | 5 | 8 | Labels never drop, stripe icon, 13 pt badges, toggle traits; tile icons and names sit at different heights. |
| Adjust panel | 6 | 7.5 | Close button, 16 pt tabs, one scroll; about 200 pt of stacked headings before any control, Mic tab inset differs and has no meter. |
| Zebras | 7 | 8.5 | Now matches mockup 02 (sub-labels, big values, stripe readout, off wording); Range/Limit selection is grey not accent. |
| False colour and key | 7 | 8 | Setup key is right; the Adjust list's footer still disagrees and the on/off switch sits mid-row. |
| Skin tone and grey card | 7 | 8.5 | Portraits, grey card policy and "Finish grey card check" are good; Custom card looks like an empty placeholder. |
| Mic meter | 7 | 8.5 | No label overlap, latched CLIP, split readout, horizontal fallback; mic name truncates at 200% and Settings uses a second meter design. |
| Camera and shot | 6 | 7.5 | Two-camera evidence and checkmarks; Adjust rows still lack resolution and frame rate, shot cards jump when selected. |
| Guides | 4 | 8.5 | Three picture cards, helper line, Dot/Cross, bypass cleared; selection has no checkmark and no capture shows a guide on. |
| Settings | 5 | 8 | Camera and monitor now matches mockup 08; the other three pages have no page title and keep r1 leftovers. |
| Wording | 6 | 8 | Core vocabulary consistent; "Show in Presenter", "Narrow Column", "Presenter full screen", "Presenter help" remain. |
| Accessibility | 6 | 8.5 | isToggle, isSelected, Expanded/Collapsed, Clipping in meter label, grey card announcement; a few truncations and small disclosures remain. |
| Visual consistency | 5 | 7.5 | One accent now, but four selection treatments, two switch placements and three exposure key designs. |
| Responsiveness | 4 | 8 | Stage protected at 200%; remaining failures are the reading chip overlap, library narrow 200% and text truncation. |

## Round 1 findings: status

Fixed: Zebras icon (stripe swatch); status pill fallback "No camera chosen" and pill is a button to Adjust; "Skin, 43 to 47 IRE"; zebra sub-labels, full-width Range/Limit, large values, stripe readout card, fuller note; Camera adjust double inset; Shot in Settings as Landscape / Vertical turned left / right (no degrees); first launch yellow, icons, quiet row, card heights, 200% fit; Settings Camera page to mockup 08; Pause dominant, chip swatch, reading hint; one yellow accent in Adjust and Settings exposure views; bar staged fit with "2 more"; badge 13 pt, icon 24 pt, transport 22 pt; long press via `simultaneousGesture`; Guides picture cards, Dot/Cross, no fixed 600 pt form, helper note, duplicate guide names removed from Advanced; mic label overlap and readout split; "MIC" heading; Clean pill icon and evidence; Custom card height; grey card switch and coherent conflict policy (`CameraGuides.swift:352` `changeExposure`); toggle and selected traits; Mic tab no longer embeds the Settings card; editor Save/Cancel transport buttons; "Test microphone", "Speech recognition", "Also connect over Wi-Fi" sentence case; Close Adjust button; tile truth uses `!exposureBypassed`; Adjust tile shows Expanded/Collapsed; grey card legend says 38 to 43.

Partly fixed: status pill (content right, layout ragged, not top centre as mockup); Camera tile value (says the actual shot, but "Vertical turned right" takes two lines); Mic tab (flat, but no live meter and different inset); one meter design (Settings still the segmented bar); switches (now switches, but beside the label instead of trailing).

Not fixed: `ReadingInspectorView.swift:34` "Show in Presenter" still disabled and grey with no script; line 40 "Narrow Column"; Adjust key footer "Grey shows brightness between these bands." (`ExposureLegend.swift:267`) vs setup key "Everything else shows in grey."; Camera rows show only the connection, not "3840 × 2160 · 25p"; shot card icons are rotate arrows and the checkmark is inline; Advanced "Automatic" is a bare button with no visible state (`CameraAdjustView.swift:44`, `SettingsView.swift:601`); Rename still as loud as the row.

## Fixes to reach 9, by area

### Reading (8) and Responsiveness (8)
1. **Chip covers the script at 200%** (`f1-reading-1000-200.png`, "Arsenal" hidden under "Zebras on"). `PresenterView.swift:118-127` draws the chip in the stage ZStack with no space reserved. Give the script a top inset equal to the chip when it shows: pass `topInset: keyVisible && shell.reading ? (36 + Space.md * 2) * controlZoom : 0` into `PresenterScriptView`, or move the chip into the bottom bar's left slot when `compactReading`. Add a snapshot assertion that the chip frame and the first line frame do not intersect at 1000 × 700, 200%.
2. **Library at 200% narrow** (`library-narrow-200-dark.png`): title, save line, two disclosures, Linked file and tip fill all 700 pt; no editable text visible. In `LibraryView.swift:481-499`, when width / zoom < 500 put "Editor text size" and "Script details" in one row of icon+label buttons (or a single "Script options" menu), hide the "Changes save automatically" line behind the title, and show the tip only once per script. Assert at least 200 pt of editor text area at 840 × 700, 200%.
3. **Mic name truncates** to "ZOOM UAC-2…" in the horizontal meter (`f1-setup-1000-200.png`). Allow two lines (`lineLimit(2)`, `fixedSize(vertical: true)`) as the vertical meter already does.

### Set up the shot (8)
1. Source pill (`PresenterView.swift:166-176`): it is constrained to the 280 × zoom left column, so even at 1600 wide it wraps to three centred lines and splits "Vertical / turned right" and starts lines with "·". Make it two left-aligned lines with no joining "·" across lines: line 1 "Sony FX3 · HDMI capture", line 2 "3840 × 2160 · 25p", and show the shot as its own pill, as mockup 01 ("Turned ↻ for vertical"). Prefer mockup placement (top centre over the top of the picture) when the picture is at least 360 pt wide; keep top left otherwise. `.multilineTextAlignment(.leading)`.
2. The picture is centred in what is left after the 280 pt key column, so it sits right of centre (`f1-setup-1600-100.png`). When the window is wide enough for the key in the left pillarbox, overlay the column instead of reserving it, so the picture centres in the window like mockup 01.

### Bar and tiles (8)
1. Fixed slots in `shellTile` (`PresenterView.swift:402-409`): badge row fixed at 16 pt × zoom (one line, `lineLimit(1)`, `minimumScaleFactor(0.8)`), icon row fixed 28 pt, name row fixed. Today a two-line badge pushes "Camera" down and tiles without a badge centre their icon, so names sit on three different baselines (`f1-setup-1600-100.png`).
2. Camera badge: use the short form "↻ Right", "↺ Left", "Landscape", "↻ Upside down", "Auto" (the full words stay in the pill and the accessibility value).
3. The check badge overlaps the rounded corner (top left, flush). Inset it 6 pt and make it 18 pt.

### Adjust panel (7.5)
1. Vertical waste: "Close Adjust", then "Adjust", then "Changes appear…", tabs, then "Zebras", then its sentence. At 200% the first control starts below half height (`r2-adjust-Zebras-200.png`). Put Close as a 44 × 44 "✕" with label at the top right of the tab row, drop the "Adjust" title (the tile already says it), keep the one-line note under the tabs. Mockup 02 starts with the tabs.
2. Mic tab (`AdjustPanel.swift:56-66`): it is the only tab with its own leading inset (`r2-adjust-Mic-100.png`, content at x 1150 vs 1108). Remove the extra inset, add a horizontal `MicMeterView` live level under the picker, label the picker "Microphone" not "Input", add "More in Settings" link.
3. All on/off switches in the panel go trailing: `LabeledContent` or `HStack { Text; Spacer(); Toggle().labelsHidden() }` for "False colour", "Show meter", "Grey card check".
4. Zebras tab has no on/off switch while False colour has one. Add the same trailing "Zebras" switch at the top of `ZebraAdjustView` (`ExposureLegend.swift:424`).
5. At 1000 wide with the panel open the meter sits jammed between the picture and the panel (`r2-adjust-Camera-100.png`). Hide the vertical meter while Adjust is open below 1200 pt, or switch to the horizontal meter under the key.

### Camera and shot (7.5)
1. `CameraAdjustView.swift:62-69`: the row shows `formatDescription`, which in the capture is only "HDMI capture". Show "3840 × 2160 · 25p · HDMI capture" for the active camera from `model.sourceInfo` (resolution and measured rate are already in the presenter pill, so the data exists).
2. Shot cards (lines 70-81): move the checkmark to an overlay in the top right so the selected card does not shift its icon and text (`alpha-camera-adjust-dark.png`, Landscape text sits 20 pt lower). Use portrait/landscape rectangle icons at 28 pt with the turn arrow (mockup 03), and let the three cards fill the width (remove `.fixedSize(horizontal: true…)` at line 38, keep the `ViewThatFits` fallback).
3. Advanced (line 42-46 and `SettingsView.swift:601`): render Upside down and Automatic with the same `shot()` card so Automatic shows its selected ring.
4. Rename: make it a small trailing text button ("Rename", 14 pt, secondary) or a context menu item.
5. "SHOT" caption (line 36): use the same 17 pt semibold section heading as the other sections; no all caps.

### Zebras (8.5)
1. Range/Limit selected segment (`ExposureLegend.swift:432-437`) uses grey `primary.opacity(0.16)`. Use the accent fill with black text like the Adjust tabs, so selection reads the same everywhere.
2. Sub-labels truncate in narrow widths (`alpha-zebra-range-dark.png`: "Centre of the strip…"). In `ExposureNumberRow`, put title and subtitle above the − value + controls when the row is under 420 pt, as Sol asked in round 1.
3. Preset cards: remove the empty top padding so title, question and value start at the top like mockup 02.

### False colour and key (8)
1. `ExposureLegend.swift:267`: change to "Everything else shows in grey." to match the setup key.
2. Adjust list swatches are 40 × 28 but names 17 pt and ranges right-aligned far away; match the setup key layout (name over range, 15 pt range under name) so one design is used in both places.
3. `ExposurePictureLegend` (the grid in `alpha-legend-range-dark.png`, used by the camera window) is a third key design. Replace it with `ExposureKey` so all keys are one component.

### Skin tone and grey card (8.5)
1. Custom card (`f2-False-colour-100-1600.png`): the 12 pt slider glyph in a 64 pt grey square reads as a missing picture. Use a 28 pt `slider.horizontal.3` glyph centred, or a split swatch, and keep "Set your own" on one line (it wraps to "Set your / own").
2. In grey card mode (`f3-false-grey-100.png`) Custom becomes selected and shows dimmed "45 IRE ±2" under "Zebra target 41 ±2". While grey card is on, hide the Custom number rows and keep the previous tone visibly selected (dimmed), so the screen shows only one target.
3. Grey card switch and "Finish grey card check" do the same thing; keep only the button while on and the switch while off, or drop the button.

### Mic meter (8.5)
1. Two-line mic name in the horizontal variant (see Responsiveness 3).
2. Settings Microphone page (`alpha-settings-Microphone-dark.png`) still draws the old segmented bar. Replace it with the horizontal `MicMeterView` (same zones, ticks, peak, CLIP, dBFS readout).

### Guides (8.5)
1. `AlphaGuideSections.swift:45`: add the same top-right checkmark badge the shot and tone cards use, not only the border, and `.isSelected` alongside the On/Off value.
2. Capture a snapshot with Thirds on and Centre mark on, showing the Dot/Cross picker and Advanced expanded; none of the current captures show a guide selected.

### Settings (8)
1. Give Reading, Microphone and App the same large page title as "Camera and monitor" (mockup 08). Today they open on a small section header ("Following", "Microphone").
2. `ReadingInspectorView.swift:34`: "Show in prompter", hidden (not disabled) when no script is selected. Line 40: "Narrow column".
3. Light mode sidebar selection is a solid black pill (`alpha-settings-App-light.png`). Use the system selection or a light grey fill; black reads as a different app.
4. Microphone page meter (see Mic meter 2). "Reset to 100%" disabled grey at 100% is fine.

### Wording (8)
1. "Show in Presenter", "Narrow Column" (above).
2. `VideoPrompterApp.swift:84` "Presenter full screen" → "Prompter full screen"; `ShootSetup.swift:304` "Presenter help" → "Prompter help". The library and menus say "Open presenter"; pick one noun ("prompter", as in "open the prompter" on the presenter's own empty state) and use it in all four places.
3. Settings Camera rows lowercased the mode names: "Range or limit", "thirds, centre mark". These are control names in the vocabulary; keep "Range or Limit" and "Vertical 9:16, Thirds, Centre mark" as mockup 08.
4. False colour footer (above).

### Accessibility (8.5)
1. Fix the truncations (zebra sub-labels, mic name); truncated text is lost to a dyslexic reader and to VoiceOver hints.
2. "Advanced" disclosures in Camera and Guides are 15 pt with a tiny chevron; give them 17 pt semibold and 44 pt row height.
3. Editor status "Editing · not saved yet" is 13 pt at 75% white; raise to 15 pt primary.

### Visual consistency (7.5)
Pick one selection treatment and apply it everywhere: accent border plus top-right check badge for cards (presets, tones, shot, guides, camera rows), accent fill with black text for segments and tabs (Adjust tabs, Range/Limit). Today: tabs filled, presets border plus check, shot cards border plus inline check, camera row fill plus border plus inline check, guides border only, Range/Limit grey fill. Plus: switches trailing everywhere, one exposure key component, one meter component.

### Library (8) and Editor (8.5)
1. Library: the narrow 200% fix above. Align "Script details" and "Linked file" with "Editor text size" when wrapped (they are indented 25 pt more).
2. Editor (`presenter-editor-dark.png`): add `Space.md` horizontal padding inside Save changes and Cancel editing; the labels touch the edges. Status line 15 pt.

## What I did not check

No app run, no VoiceOver, no live camera or mic, no hover. Light mode was judged on Settings and first launch only (the presenter forces dark). I did not verify `PresenterBarFit` thresholds beyond the 1000 and 1600 wide captures.
