# Video Prompter Alpha redesign, review round 5 (Claude Opus 5.5)

Branch `claude/alpha-hud` at 136dfa8. Read only. Evidence: SPEC, mockups 01 to 09, my round 4 report, the diff 8f4dd60..136dfa8 (8 files, +74 / −105), and fresh captures in `/private/tmp/VideoPrompter-alpha-r5/` (written 9 Nov 10:04 to 10:07). I looked closely at about 25 captures: all `g1-setup-*` that matter (1000 and 1600, at 100, 150 and 200%), `f1-setup-1000-200`, `pkgE-setup`, `qa11-output-landscape-dark`, `g1-reading-1000-200`, `g2-Mic-100`, `g2-Camera-200`, `g2-Guides-100`, `f2-Zebras-100-1600`, `f3-setup-key-200`, `h2-settings-Camera and monitor-100`, `h2-settings-Microphone-100`, `h2-advanced-upside-down-100`, `h2-advanced-automatic-200`, `r3-detail-Zebras-200-lower`, `r3-detail-Shot-100-top`, `r3-detail-Guides-100-top`, `r3-detail-Advanced-100-lower`, `r3-detail-Exposure key-100-top`, `first-launch-200-dark`. As before, I did not count native yellow placeholders, the fixture picture, grey switch tracks offscreen or empty camera lists. Paths are relative to `Sources/VideoPrompter/`.

## Verdict

Round 5 fixed both round 4 regressions and nearly every item on my list:

- The Adjust tabs fit on one row again.
- The Exposure key is back at 1000 × 200%.
- The setup picture is centred.
- The full key now shows whenever there is room for it.
- The −/+ buttons and Done have visible edges.
- The Shot sheet no longer shows a Camera heading.
- The Camera Advanced disclosure is 17 pt with a 44 pt row.
- `ExposurePictureLegend` is deleted.

Eighteen of the 19 areas now reach 9.

One area is still under 9: **Settings, at 8.5**, because of a new problem in the Advanced sheet. My round 4 fix asked for the guide *Advanced* form. The build used the whole `AlphaGuideSections` instead. So Settings > Advanced now repeats the three guide cards from Settings > Guides, followed by a second disclosure that is also called "Advanced" (`h2-advanced-upside-down-100-dark.png`). For a dyslexic user, an "Advanced" inside "Advanced" that repeats another page is exactly the confusion the redesign set out to remove. The fix is one line.

## Grades

| Area | R4 | R5 | Why, in one line |
|---|---|---|---|
| First launch | 9 | **9** | Unchanged and matches mockup 07. Polish still open: at 200% the quiet row wraps after "Help ·" (`first-launch-200-dark.png`). |
| Library | 9 | **9** | Unchanged. |
| Editor | 9 | **9** | Unchanged. |
| Set up the shot | 8.5 | **9** | Key button back at 1000 × 200%. Picture centred (x 697 to 1303 of 2000 at 1600 × 100%; a test now checks the centre, `PresenterG1Tests.swift:52`). Full key at 1600 × 150%. Format on one line. |
| Reading | 9 | **9** | Unchanged (`g1-reading-1000-200.png`). |
| Clean | 9.5 | **9.5** | Unchanged. |
| Bar and tiles | 9 | **9** | Unchanged. "False colour" still touches its tile edges at 150% and 200% (polish). |
| Adjust panel | 8.5 | **9** | Five tabs on one row at 100% and 200% (`g2-Mic-100.png`, `g2-Camera-200.png`, `f2-Zebras-100-1600.png`). The ✕ now sits at the end of the caption line. |
| Zebras | 9 | **9** | −/+ now have 46 pt squares in Adjust and Settings (`r3-detail-Zebras-200-lower-dark.png`). |
| False colour and key | 9 | **9** | One key, and the full card shows at 200% when there is room (`f3-setup-key-200.png`). |
| Skin tone and grey card | 9 | **9** | Unchanged. |
| Mic meter | 9 | **9** | One meter design. Polish: Settings > Microphone still shows "MIC" inside the Microphone section. |
| Camera and shot | 9 | **9** | The Shot sheet shows only the three shot cards, the hint and Advanced (`r3-detail-Shot-100-top-dark.png`). |
| Guides | 9 | **9** | The Adjust tab and Guides sheet match mockup 02. The duplicate in Settings > Advanced is graded under Settings. |
| Settings | 8.5 | 8.5 | −/+ squares, a filled Done button, trailing Mirror switch, no old guide form. New: the Advanced sheet repeats the guide cards with "Advanced" inside "Advanced". Saved shoot setups and Permissions still look like an unstyled form. |
| Wording | 9 | **9** | No changes to wording. |
| Accessibility | 8.5 | **9** | Camera Advanced disclosure is 17 pt / 44 pt (`CameraAdjustView.swift:65`). Sheet −/+ and Done have visible edges and 44 pt or larger targets. |
| Visual consistency | 8.5 | **9** | `ExposurePictureLegend` and its snapshot are deleted. One disclosure size, one button style in sheets (`SettingsFormButtonStyle`). Polish left: Dot/Cross has no track, and the shoot setup and permission rows use the old form look. |
| Responsiveness | 8.5 | **9** | Both round 4 regressions are fixed. There is one risk I could not verify (see "Landscape at narrow sizes" below). |

## Round 4 findings: status

| R4 finding | Status |
|---|---|
| Adjust: tab row wraps, "Mic" alone | **Fixed** (`AdjustPanel.swift:22-40`; ✕ moved onto the caption line). A test was added (`AdjustPanelF2Tests.swift`). |
| Setup 1: key lost at 1000 × 200% | **Fixed** (`g1-setup-1000-200.png`, `f1-setup-1000-200.png`). The key is first in the column and the format is one pill on one line (`PresenterView.swift:183`). |
| Setup 2: picture off centre | **Fixed**. Matching gutters on both sides (`PresenterView.swift:79-80, 99, 153`). |
| Setup 3: full key hidden when there is room | **Fixed**. `keyFits` now uses the real gutter width (`PresenterView.swift:72-78`). `g1-setup-1600-150.png` shows the full card. |
| Settings 1: −/+ squares in sheets | **Fixed** (`ExposureLegend.swift:433-443`). |
| Settings 2: sheet buttons look like plain text | **Fixed**. Done is a filled accent button. Other buttons use `SettingsFormButtonStyle` ("Save shoot setup", "System settings…" now have backgrounds). |
| Settings 3: old guide form in Advanced; Mirror as a trailing switch | **Mirror fixed. The guide form is replaced, but by the wrong view**: `SettingsView.swift:679` uses `AlphaGuideSections(...)`, which brings the Guides heading, all three cards, Dot/Cross and a nested "Advanced". See the fix below. |
| Settings 4: Shot sheet headed "Camera" | **Fixed** (`shotOnly`, `CameraAdjustView.swift:12, 21`). |
| Accessibility 1: Camera Advanced disclosure | **Fixed**. |
| Visual 2: delete `ExposurePictureLegend` | **Fixed**. |
| Visual 3: Dot/Cross track | **Not fixed** (`g2-Guides-100.png`: "Dot" floats as bare text next to a filled "Cross"). Polish. |
| Polish: "False colour" touches its tile edges | **Not fixed** (`g1-setup-1000-200.png`). |
| Polish: first launch "Help ·" dangling dot at 200% | **Not fixed** (`first-launch-200-dark.png`). |
| Polish: "MIC" heading in Settings > Microphone | **Not fixed** (`h2-settings-Microphone-100-dark.png`; `SettingsView.swift:415`). |
| Polish: Camera page content inset differs | Unchanged. I accept it. |

## Fixes to reach 9

### Settings (8.5)

1. **Advanced repeats Guides, with "Advanced" inside "Advanced".** `SettingsView.swift:679`. Replace `AlphaGuideSections(model: camera, advancedExpanded: true)` with:
   ```swift
   Text("Guide look").font(.system(size: 17, weight: .semibold))
   CameraGuideSections(model: camera, alphaStyle: true)
   ```
   This keeps Colour, Guide visibility and Frame shape (the things only Advanced has). It drops the three cards and Dot/Cross, which belong to the Guides sheet. Check that `h2-advanced-*-100` shows no "Vertical 9:16 / Thirds / Centre mark" cards and only one "Advanced", the sheet title.
2. **Saved shoot setups and Permissions look unfinished in the sheet** (`r3-detail-Advanced-100-lower-dark.png`). "Saved shoot setups" and "Permissions" show as plain 15 pt body text rather than headings. The permission rows run "Camera Allowed [System settings…]" on one line with no alignment. The cause is that `ShootSetupSection` and `PermissionSection` are `Section` / `LabeledContent` views placed outside a `Form`. Permissions already appear on the Microphone page (`SettingsView.swift:319`), so the simplest fix is:
   - Delete `PermissionSection()` at line 681.
   - Wrap the shoot setups so they render as a grouped form, as they do elsewhere: `Form { ShootSetupSection(store: store, camera: camera, recorder: recorder) }.formStyle(.grouped).scrollDisabled(true).frame(minHeight: 260)`.
   - Or move Saved shoot setups to its own row on the Camera and monitor page.
3. Polish, same sheet family: `SettingsView.swift:672`. The Exposure key switch sits right next to its label (`r3-detail-Exposure key-100-top-dark.png`), unlike Mirror and Automatic. Use the same `HStack { Text("Show exposure key"); Spacer(); Toggle(...).labelsHidden() }`.

## Landscape at narrow sizes (risk to check, not graded down)

The setup stage now reserves a gutter of `max(columnWidth, meterWidth)` on **both** sides (`PresenterView.swift:80, 153`). When the key does not fit, each gutter is `144 × zoom + 32` pt. At 1000 pt and 200%, that is about 320 pt per side, so 640 of 1000 pt go to gutters. For the vertical picture this costs nothing, but a **landscape** picture (the default shot) would be only about 360 pt wide. `qa11-output-landscape-dark.png` shows the black picture region squeezed between the two gutters, but it has no camera picture, so I cannot measure it.

The suggested guard keeps centring only while it is cheap. At line 80, use the larger gutter only when the picture is narrower than the space left:

```swift
let gutterWidth = setup ? (availableGutter >= columnWidth ? max(columnWidth, meterWidth) : max(meterWidth, 0)) : 0
```

With this, the pills overlay the picture edge as a fallback. Alternatively, apply the symmetric spacer only when `pictureAspect < 1`. Before calling it fixed, add a capture of a landscape fixture at 1000 × 200%.

## Polish that does not hold back a 9

- "False colour" tile label touches its edges at 150% and 200%. At `PresenterView.swift:442`, add `.padding(.horizontal, Space.xs)` to the title so `minimumScaleFactor(0.8)` takes effect first.
- Dot/Cross track: in `Settings/AlphaGuideSections.swift:25-34`, wrap the two buttons in `HStack { … }.padding(4).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))`, like Range/Limit.
- First launch at 200%: in `Library/LibraryStartView.swift:35-41`, attach each "·" to the item before it (one `HStack` per item), so a line never ends with a dot.
- Settings > Microphone: pass `showsHeading: false` to `MicMeterView` at `SettingsView.swift:415`.
- Adjust panel: the caption line plus ✕ leaves about 60 pt of empty space before the first heading (`g2-Mic-100.png`). It is not wrong, but trimming the `ScrollView` top padding by `Space.md` would tighten it.

## What I did not check

I did no build, test run, app launch, VoiceOver, keyboard, hover, live camera or live mic. Grades come from the source diff and about 25 sampled captures. The landscape setup layout is reasoned from code; no capture with a picture exists. Older capture sets (`a12` to `a17`, `r8` to `r15`, `review*`, `qa*` other than qa11) were not graded.
