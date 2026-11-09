# Video Prompter Alpha redesign, review round 4 (Claude Opus 5.5)

Branch `claude/alpha-hud` at 2e73308. Read only. Evidence: SPEC, mockups 01 to 09, both round 3 reports, the diff 0cf857d..2e73308, and fresh captures in `/private/tmp/VideoPrompter-alpha-r4/` (all written 9 Nov 08:59 to 09:06). I looked closely at about 40 of the 1,041 captures: all `g1-setup`, `g1-reading`, `g2-*`, `g3-camera`, `f2-*`, `h2-settings-*`, `h2-advanced-*`, chosen `r3-detail-*`, `first-launch-*`, `library-narrow-200`, `welcome-callout`, `f1-exit-pill-visible`, `mic-meter-hot`. I also compared one round 3 capture (`/private/tmp/VideoPrompter-alpha-r3/g1-setup-1000-200.png`) to confirm a regression. Native yellow placeholders, the fixture picture, grey switch tracks offscreen and empty camera lists in `startsCamera: false` sheets are not counted as defects. Paths are relative to `Sources/VideoPrompter/`.

## Verdict

Round 4 fixed nearly everything on the round 3 list. The Welcome guide is rewritten, Settings > Advanced now shows which orientation is chosen, the four Settings pages share one title layout, Settings uses the real mic meter, and the grey card wording is right. Fourteen areas reach 9.

It also caused **two visible regressions**, both from layout changes:

1. **The Adjust tab row now wraps at every size.** "Mic" sits alone on a second row (`g2-*-100.png`, `f2-*-1600.png`).
2. **The Exposure key disappears at 1000 × 200%** (`g1-setup-1000-200.png`). The new third source pill pushes the "Exposure key" button out of the column. It was visible in round 3.

The setup picture also now sits right of centre, because the left column is always reserved. Each of these is a small, local fix.

## Grades

| Area | R3 | R4 | Why, in one line |
|---|---|---|---|
| First launch | 9 | **9** | Matches mockup 07 at every size. Polish only: at 200% the quiet row wraps with a dangling "·" (`first-launch-200-dark.png`). |
| Library | 9 | **9** | Unchanged. Narrow 200% still shows the script under a compact header. |
| Editor | 9 | **9** | Unchanged and still readable at 200% (`g1-editing-1000-200.png`). |
| Set up the shot | 8.5 | 8.5 | Key no longer overlaps the picture, pills have no orphan dots and the shot has its own pill. New problems: the key button is lost at 1000 × 200%, the picture is about 150 pt right of centre at 1600 × 100%, and the full key collapses to a button at 1600 × 150% even with a wide pillarbox. |
| Reading | 9 | **9** | Chip clear of line one; big Pause; matches mockup 05 (`g1-reading-1600-100.png`, `-1000-200.png`). |
| Clean | 9.5 | **9.5** | Picture only, small Exit Clean · Esc pill (`f1-exit-pill-visible.png`). |
| Bar and tiles | 9 | **9** | Stable slots and badges. "False colour" still touches its tile edges at 150% and 200% (polish). |
| Adjust panel | 8.5 | 8.5 | Top padding, leading alignment and the single Mic heading are fixed. The wider tab padding now pushes "Mic" onto its own row at 100%, unlike mockup 02. |
| Zebras | 9 | **9** | Preset cards are now tight (`g2-Zebras-100.png`) and match mockup 02. The Settings sheet −/+ issue is graded under Settings. |
| False colour and key | 9 | **9** | One key, one table, footer agrees everywhere. |
| Skin tone and grey card | 8.5 | **9** | The text now says "Choose Finish grey card check…" while the check is on (`g2-grey-card-100.png`). |
| Mic meter | 8.5 | **9** | Settings > Microphone now uses `MicMeterView` (`h2-settings-Microphone-100-dark.png`), so there is one meter design. |
| Camera and shot | 9 | **9** | Settings > Advanced reuses the stateful Upside down card and Automatic switch (`h2-advanced-*`). Polish: the Shot sheet shows a "Camera" heading. |
| Guides | 8.5 | **9** | Dot/Cross keeps the stored choice, dimmed when hidden. "Centre mark style" caption. Advanced is now the leading-title layout with a % readout (`g2-guides-advanced-100.png`). |
| Settings | 8 | 8.5 | Same title placement on all four pages, 15 pt text, 44 pt buttons, real meter, no duplicate sheet titles. Still to fix: −/+ have no squares in sheets, the Advanced sheet still uses the old guide form, and sheet buttons look like plain text. |
| Wording | 8 | **9** | Welcome guide rewritten in the spec vocabulary with a guard test. "Upside down" badge, "Range or Limit", "Thirds, Centre mark". `PresenterHelp` deleted. |
| Accessibility | 8.5 | 8.5 | Settings form buttons now reach 44 pt and the shot cards announce Selected. Camera's Advanced disclosure is still 13 pt with no 44 pt row, and the sheet −/+ and Done/Save buttons have no visible edge. |
| Visual consistency | 8.5 | 8.5 | Settings pages and the meter are unified. Two guide forms, two disclosure sizes and two button styles remain, and `ExposurePictureLegend` is still in the code. |
| Responsiveness | 9 | 8.5 | Two new layout regressions: the key button is lost at 1000 × 200%, and the Adjust tabs wrap at 100%. |

## Round 3 findings: status

### My round 3 list

| R3 finding | Status |
|---|---|
| Wording 1: Welcome script teaches Tools, Mic level, Legend, arrows | **Fixed** (`App/WelcomeScript.swift:13-46`, `AlphaWelcomeWordsTests.swift`; `welcome-callout-dark.png`). |
| Wording 2: "↻ Inverted" | **Fixed** ("Upside down", `PresenterView.swift:195`). |
| Wording 3: grey card "Turn this off" | **Fixed** (`ExposureLegend.swift:613`). |
| Wording 4: "Range or Limit", "Thirds, Centre mark" | **Fixed** (`SettingsView.swift:597,599`). |
| Wording 5: delete `PresenterHelp` | **Fixed**. |
| Settings 1: one page layout | **Fixed for titles** (all four at the same position). The content column differs: Camera rows run full width from the title edge, while the other three are grouped forms inset about 90 pt. Polish. |
| Settings 2: 15 pt forms, 44 pt buttons | **Fixed** (`SettingsFormButtonStyle`, `SettingsView.swift:688`). |
| Settings 3: one meter | **Fixed**. |
| Settings 4: duplicate sheet titles | **Fixed** for Zebras, False colour, Guides and Camera (`SettingsView.swift:656`). |
| Settings 5: −/+ squares in the narrow sheet | **Not fixed** (`r3-detail-Zebras-200-lower-dark.png`: a bare "−", "±2 IRE", "+"). |
| Setup 1: key over the picture at 1000 × 100% | **Fixed**: the key is always in the left column. **This caused a regression at 200%** (see below). |
| Setup 2: own shot pill, no trailing dots | **Fixed** (`PresenterView.swift:172-187`). Overdone: every part is now its own line, so "3840 × 2160" and "25p" stack even with room to spare. |
| Setup 3: pills off the picture edge | **Fixed** (left column). |
| Adjust 1: tab row flush to the top | **Fixed** (`AdjustPanel.swift:38`). |
| Adjust 2: tab padding, leading alignment | **Fixed, but caused a regression**: "Mic" now wraps to a second row. |
| Adjust 3: "MIC" twice | **Fixed** (`showsHeading: false`). |
| Guides 1: Dot/Cross with nothing selected | **Fixed** (stored choice, dimmed). |
| Guides 2: Dot/Cross track; drop the repeated label | **Label fixed**. Still no track (polish). |
| Guides 3: Advanced as the old camera-window form | **Fixed in Adjust and the Guides sheet** (`alphaStyle: true`). **Not fixed in Settings > Advanced** (`SettingsView.swift:674` still calls `CameraGuideSections(model: camera)`; `h2-advanced-upside-down-100-dark.png` shows "Framing guides / Colour / Guide visibility" with no %). |
| Accessibility 2: Camera Advanced disclosure 17 pt / 44 pt | **Not fixed**: changed to `.headline` (13 pt) at `CameraAdjustView.swift:62`, no min height. |
| Visual 4: delete `ExposurePictureLegend` | **Not fixed** (`ExposureLegend.swift:310`, snapshot in `AppearanceSnapshotTests.swift:38`). |
| Polish: "False colour" touching its tile edges | **Not fixed** (`g1-setup-1600-150.png`, `g1-setup-1000-200.png`). |
| Polish: zebra preset card empty bottom space | **Fixed**. |

### Sol's round 3 findings

| Sol R3 | Status |
|---|---|
| F1: obsolete first-use guide | **Fixed**. The guide now names Adjust > Mic, Settings > Microphone > Test microphone, Reading settings, the three Shot choices, right-click to a tab, Exit Clean and Esc, and Paste script / New script / Import file…. |
| F2: Settings > Advanced orientation had no state | **Fixed** (`SettingsView.swift:673` reuses `CameraAdjustView(advancedOnly: true)`). `h2-advanced-upside-down` shows Upside down checked, `-automatic` shows the switch on and no card checked, `-manual` shows neither. The cards now report "Selected" / "Not selected" (`CameraAdjustView.swift:121`). |

## Fixes to reach 9, by area

### Adjust panel (8.5): tab row wraps (new regression)

`AdjustPanel.swift:23-38`. Five tabs at 12 pt side padding, plus the 44 pt close button, need about 470 pt. The row only has 422 pt (470 minus two 24 pt insets). So "Mic" wraps on its own, at 100% as well as 200% (`g2-Mic-100.png`, `f2-Zebras-100-1600.png`). Mockup 02 shows one row.

- **Simplest fix:** take the close ✕ out of the tab row. Put it trailing on the "Changes appear on your camera picture." line (line 40), as an `HStack { Text(...); Spacer(); closeButton }`. The five tabs (about 417 pt) then fit one row at 100%. `WrapLayout` still wraps them at 150% to 200%, which is allowed.
- **If that is not wanted:** change `.padding(.horizontal, Space.md)` at line 28 to `Space.sm` and `WrapLayout(spacing: 4…)` to `spacing: 2`.

Check `g2-*-100.png` shows one tab row.

### Set up the shot (8.5)

1. **Exposure key lost at 1000 × 200%** (`g1-setup-1000-200.png`; round 3 showed it). `PresenterView.swift:74-91`: the column is three pills plus the key, inside a stage about 370 pt tall. The button falls below the clip. Do both of these:
   - Keep the format on one line. At line 172, change `sourcePill(parts: format.components(separatedBy: " · "))` to `sourcePill(parts: [format])`. "3840 × 2160 · 25p" fits in 144 pt at 14 pt text, and this saves one line in every capture.
   - Put the key button above the pills when `!keyFits`, so the one control that matters is never the part that gets cut off. Or wrap the column `VStack` in `ScrollView(.vertical)`.

   Check `g1-setup-1000-200.png` shows the "Exposure key" button.
2. **Picture off centre.** At 1600 × 100% the picture centre is about x 1115 of 2000 (`g1-setup-1600-100.png`). Mockup 01 centres it at x 1000. Reserve the same width on the right of the picture region as the left column takes. For example, add `Color.clear.frame(width: columnWidth - meterWidth)` before the meter when that value is positive. The picture is then centred in the window, and the key and meter sit in equal pillarboxes.
3. **Full key hidden when there is room.** `keyFits` (line 71) needs `width >= 1100 * zoom`, so at 1600 × 150% (`g1-setup-1600-150.png`) the key becomes a button, even though the pillarbox is about 500 pt wide. Use the real space instead: `(geometry.size.width - meterWidth - pictureWidth) / 2 >= (280 + Space.md * 2) * controlZoom`, with `pictureWidth = min(geometry.size.width, geometry.size.height * sourceAspect)`. This is what my round 3 item 1 asked for.

### Settings (8.5)

1. **−/+ have no squares in Settings sheets** (`r3-detail-Zebras-200-lower-dark.png`). The cause is that `SettingsDetailButtonStyle` (`SettingsView.swift:696`) replaces their style. In `ExposureNumberRow.controls` (`Presenter/ExposureLegend.swift:505-514`), add `.buttonStyle(.plain)` to both buttons and `.background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))` to their labels. They will then look the same in Adjust and Settings.
2. **Sheet buttons look like plain text** ("Done", "Save shoot setup" in `h2-advanced-*`). Give `SettingsDetailButtonStyle` (line 696) the same `.padding(.horizontal, Space.sm)` and `.background(.primary.opacity(configuration.isPressed ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))` as `SettingsFormButtonStyle`. Or delete it and use `SettingsFormButtonStyle`.
3. **The Advanced sheet still uses the old guide form.** At `SettingsView.swift:674`, change to `CameraGuideSections(model: camera, alphaStyle: true)`. Make "Mirror camera preview" (line 672) a trailing switch like "Automatic": `HStack { Text("Mirror camera preview"); Spacer(); Toggle(...).labelsHidden() }`.
4. **Shot sheet is headed "Camera"** (`r3-detail-Shot-100-top-dark.png`: sheet title "Shot", then a "Camera" heading and "Pick the camera…"). For `.shot`, hide the Camera heading, intro and camera list in `CameraAdjustView` (for example a `shotOnly` flag next to `showsShotHeading`), so the sheet shows only the shot cards and Advanced.

### Accessibility (8.5)

1. `Camera/CameraAdjustView.swift:62`: use the same label as Guides, `Text("Advanced").font(.system(size: 17, weight: .semibold)).frame(minHeight: AlphaStyle.minTarget)`.
2. Settings items 1 and 2 above, which give the −/+ and Done/Save buttons a visible edge.

### Visual consistency (8.5)

1. Settings item 3 (one guide form) and Accessibility item 1 (one disclosure size).
2. Delete `ExposurePictureLegend` (`Presenter/ExposureLegend.swift:310`) and its `alpha-legend-*` snapshot (`Tests/PrompterCoreTests/AppearanceSnapshotTests.swift:38`).
3. Give Dot/Cross (`Settings/AlphaGuideSections.swift:24-34`) the same track as Range/Limit: `.padding(4).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))` around the two buttons.

### Responsiveness (8.5)

The Adjust panel fix and Set up the shot item 1 above.

## Polish that does not hold back a 9

- "False colour" tile label touches the tile edges at 150% and 200%. Add `.padding(.horizontal, Space.xs)` to the tile title `Text` so `minimumScaleFactor` takes effect first.
- First launch at 200%: the quiet row wraps after "Help ·" (`first-launch-200-dark.png`). In `Library/LibraryStartView.swift:35-41`, attach each "·" to the button before it (one `HStack` per item), or use a `ViewThatFits` that falls back to a `VStack` with no dots.
- Settings > Microphone: the meter card shows "MIC" under a "Microphone" section header and a "Microphone" row. Pass `showsHeading: false` at `SettingsView.swift:415`.
- Settings content column: the Camera page's rows start at the title edge, while the grouped forms start about 90 pt further in. Either inset the Camera rows to match, or accept it.

## What I did not check

No build, test run, app launch, VoiceOver, keyboard, hover, live camera or mic. Grades come from the source diff and about 40 sampled captures. The `a1x-`, `r8-` to `r15-`, `review*`, `qa*`, `a12-` to `a17-` and `b17-` sets are older fixtures and were not graded.
