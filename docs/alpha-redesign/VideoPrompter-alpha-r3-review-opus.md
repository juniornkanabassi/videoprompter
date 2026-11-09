# Video Prompter Alpha redesign, review round 3 (Claude Opus 5.5)

Branch `claude/alpha-hud` at 0cf857d. Read only. Evidence: SPEC, mockups 01 to 09, both round 2 reports, the diff 5a7775a..0cf857d, and fresh captures in `/private/tmp/VideoPrompter-alpha-r3/` (all written 9 Nov 08:12; current ones are `g1-`, `g2-`, `g3-`, `g4-detail-`, `r3-detail-`, `r3-settings-`, `f3-`, `f4-`, and the regenerated `r2-adjust-`, `library-`, `first-launch-`, `mic-meter-`). Yellow native placeholders, the fixture picture, "No camera chosen" in `r2-adjust-*` and grey (untinted) switch tracks in an inactive offscreen window are not graded as defects. Paths below are relative to `Sources/VideoPrompter/`.

## Verdict

Round 3 closed almost everything structural. All five of Sol's Important findings are fixed in source (editors, effective visibility, sheet zoom, mic name, accessibility values), and most of my round 2 list landed. Twelve areas now meet ship quality. The seven left are each one or two small, local fixes. The biggest single gap is not visual: the **Welcome script**, the first script every new user sees, still teaches a UI that no longer exists (Tools, Mic level, Legend, settings arrows).

## Grades

| Area | R2 | R3 | Why, in one line |
|---|---|---|---|
| First launch | 9 | **9** | Unchanged and right; mockup 07 at every size. |
| Library | 8 | **9** | Narrow 200% now shows the script text under a compact header (`library-narrow-200-dark.png`). |
| Editor | 8.5 | **9** | 200% presenter editing shows full editable sentences; compact Save/Cancel (`g1-editing-1000-200.png`). |
| Set up the shot | 8 | 8.5 | Picture dominant and centred; source pill still two stacked pills with shot merged, and the key card overlaps the picture edge at 1000 × 100%. |
| Reading | 8 | **9** | Chip no longer covers line one at 200% (`g1-reading-1000-200.png`); matches mockup 05. |
| Clean | 9.5 | **9.5** | Picture only, exit pill with icon and Esc. |
| Bar and tiles | 8 | **9** | Fixed badge, icon and name slots, short shot badge, inset 18 pt check; only "False colour" touches its tile edges. |
| Adjust panel | 7.5 | 8.5 | Close ✕ in the tab row, no title, trailing switches, Mic tab has meter and Settings link; tab row is flush to the top edge and tab labels nearly touch their pills. |
| Zebras | 8.5 | **9** | Trailing on/off, accent Range/Limit, stacked rows when narrow, mockup 02 match. |
| False colour and key | 8 | **9** | One key design in setup, Adjust and grey card; footer wording now identical. |
| Skin tone and grey card | 8.5 | 8.5 | Custom card, dimmed previous tone and single Finish button all fixed; the card text still tells him to "Turn this off" when there is no switch. |
| Mic meter | 8.5 | 8.5 | Name now two full lines everywhere, Adjust Mic tab has the live meter; Settings Microphone page still draws the old thin segmented bar. |
| Camera and shot | 7.5 | **9** | Rows show "3840 × 2160 · 25p", overlay checks, full-width shot cards with rectangle icons, quiet Rename, Automatic as a switch (`g3-camera-100.png`). |
| Guides | 8.5 | 8.5 | Check badges and a guides-on capture now exist; Dot/Cross row shows with nothing selected when guides are hidden, and Advanced is the old centred camera-window form. |
| Settings | 8 | 8 | Camera and monitor matches mockup 08 and sheets now zoom; the other three pages use two different title layouts, 13 pt forms, small buttons and the old meter. |
| Wording | 8 | 8 | Presenter strings fixed; the Welcome script is stale, "↻ Inverted" contradicts "Upside down", Settings rows lowercase mode names. |
| Accessibility | 8.5 | 8.5 | Exposure rows, Camera value and guide traits now correct; Settings form buttons are under 44 pt and the Camera Advanced disclosure is still 13 pt. |
| Visual consistency | 7.5 | 8.5 | One selection system and one key; Settings pages, the Settings meter and two disclosure styles still differ. |
| Responsiveness | 8 | **9** | Setup, reading, editor, library and Settings sheets all hold at 200%; the remaining overlap is listed under Set up the shot. |

## Round 2 findings: status

### My round 2 list

| R2 finding | Status |
|---|---|
| Reading chip covers script at 200% | **Fixed** (`PresenterView.swift:116` `topInset`; `g1-reading-1000-200.png`). |
| Library narrow 200% | **Fixed** (`library-narrow-200-dark.png`, "Text size" and "Script details" on one row, script visible). |
| Mic name truncates | **Fixed** ("ZOOM / UAC-232" on two lines in all g1 captures). |
| Source pill two left-aligned lines, shot its own pill, top centre | **Partly fixed**: two left-aligned pills now, but shot is merged into line 2 and it is not top centre. At 200% lines still end in "·" (`g1-setup-1000-200.png`). |
| Picture right of centre | **Fixed**: picture centres in the stage left of the meter. |
| Tile fixed slots, short Camera badge, check inset | **Fixed** (`PresenterView.swift:434-445`). |
| Adjust: drop title, Close in tab row | **Fixed**. |
| Adjust Mic tab inset, live meter, "Microphone" label, Settings link | **Fixed** (`r2-adjust-Mic-100.png`). |
| Trailing switches in panel | **Fixed** (Zebras, False colour, Show meter, Automatic). |
| Zebras on/off switch | **Fixed** (`ExposureLegend.swift:436`). |
| Hide meter beside Adjust under 1200 | **Fixed** (meter hidden in `r2-adjust-*` at 1000). |
| Camera rows show resolution and rate | **Fixed**. |
| Shot checkmark overlay, rectangle icons, cards fill width | **Fixed**. |
| Advanced Automatic visible state | **Fixed** (now a trailing switch). |
| Rename quieter | **Fixed**. |
| "SHOT" caption | **Fixed** ("Shot", semibold). |
| Range/Limit accent fill | **Fixed**. |
| Zebra sub-labels truncate when narrow | **Fixed** (`ViewThatFits` stack, `ExposureLegend.swift:515-519`). |
| Preset cards empty top padding | **Not fixed**: text is now at the top but the cards keep about 70 pt of empty space at the bottom (`g2-Zebras-100.png`). Polish only. |
| Adjust key footer wording | **Fixed**. |
| Adjust list layout matches setup key | **Fixed**. |
| Replace `ExposurePictureLegend` | **Fixed in practice**: no call site remains, but the struct (`ExposureLegend.swift:310`) and its `alpha-legend-*` snapshots are dead code. |
| Custom card glyph and "Set your own" | **Fixed**. |
| Grey card hides Custom rows, keeps tone dimmed | **Fixed** (`g2-grey-card-100.png`). |
| Grey card switch and button duplicate | **Fixed** (switch when off, button when on), but see wording fix below. |
| Settings Microphone meter | **Not fixed** (`f4-settings-Microphone-100-dark.png`). |
| Guide checkmark badge and selected trait | **Fixed** (`AlphaGuideSections.swift:50-52`). |
| Guides-on capture | **Fixed** (`g2-guides-advanced-100.png`). |
| Settings page titles | **Partly fixed**: all four have a large title, but in three different places (see Settings). |
| "Show in Presenter", "Narrow Column" | **Fixed** ("Open presenter", "Narrow column"); the disabled button is replaced by a grey "Choose a script first" line. |
| Light sidebar black pill | **Fixed** (pale yellow selection). |
| "Presenter full screen", "Presenter help" | **Fixed** in menus; `PresenterHelp` (`ShootSetup.swift:300`) is now unreferenced dead code with stale text. |
| "Range or limit", "thirds, centre mark" | **Not fixed** (`SettingsView.swift:589,591`). |
| Advanced disclosures 17 pt, 44 pt | **Fixed in Guides**, **not fixed in Camera** (`CameraAdjustView.swift:57`). |
| Editor status 15 pt | **Fixed**. |
| One selection treatment | **Fixed** for cards, tabs and segments. Dot/Cross has no track, unlike Range/Limit. |
| Editor button padding | **Fixed**. |

### Sol's round 2 Important findings

| Sol R2 | Status |
|---|---|
| 1 Protect the writing area in both editors | **Fixed** (`LibraryView.swift` compact header; presenter editor uses its own `GeometryReader`, `PresenterView.swift:103-108`; setup gutter suppressed while editing, line 74). |
| 2 Every explicit monitor choice restores visibility | **Fixed** (`CameraModel.swift` `exposureControls`, `changeExposure`, `zebraBinding`, `chooseZebraPreset`, `setGreyCardCheck`, `chooseGuide`, `chooseFrameMarker`; Advanced shapes routed through `chooseFrameMarker`, `CameraWindow.swift:169-178`; Settings summaries use `effectiveZebras`, `framingIsVisible`). Tests in `AlphaExposureTests.swift`. |
| 3 Settings detail sheets keep zoom and targets | **Fixed** (`g4-detail-*-200`, `r3-detail-*-200`, sheet bounded to window, scrollable, Done at top). |
| 4 Mic name readable | **Fixed**. |
| 5 Truthful accessibility values | **Fixed** (`ExposureNumberRow.subject`, "skin reference level" vs "zebra level"; Camera tile value is "name, shot", `PresenterView.swift:451`; guide cards toggle trait plus check). |
| N1 to N3 optional | N1 fixed; N2 (pink swatch in the skin help line) not done, still optional; N3 fixed. |

## Fixes to reach 9, by area

### Wording (8) — do this first

1. **Welcome script teaches a UI that no longer exists.** `App/WelcomeScript.swift:13-45` (`monitorMarkdown`) is the first script in every new library (`first-launch-100-dark.png` sidebar) and the practice script. It says "open **Tools**, choose Microphone in **Tools section**, then **Check sound…**", "Open **Tools**, choose Text, then **Reading mode…**", "**Mic level** and **Legend**", "The arrow beside an aid opens its settings" (the spec removed settings arrows), "Option-Command-K", "**Paste Copied Text**, **New Script**". There is no Tools button in the Alpha (`PresenterToolsMenu` has no caller). Rewrite the monitor version in the spec vocabulary, short sections, one idea each:
   - Start here: "Click **Open presenter**, then **Start reading**. To check your sound, choose **Mic**, then speak and watch the meter."
   - Reading: "**Reading settings** under the Pause button changes the mode, font, size and spacing. **Space** pauses. **Esc** goes back to **Set up the shot**."
   - Camera: "**Camera** picks your camera and turns the picture upright. **Zebras**, **False colour**, **Guides** and **Mic** switch each aid on and off. Right-click any of them, or choose **Adjust**, to change it. **Clean** shows only the picture; press **Esc** to leave."
   - Your scripts: "Choose **Paste script**, **New script** or **Import file…**."
   Add a test that `WelcomeScript.markdown` contains none of "Tools", "Mic level", "Legend", "Check sound", "arrow beside" when `!Features.recording`.
2. `Presenter/PresenterView.swift:207` `case .half: return "↻ Inverted"`. The card is called **Upside down**; use "↻ Upside down".
3. `Presenter/ExposureLegend.swift:611`: when `greyCardCheck` is on there is no switch, so "Turn this off to go back to your skin settings." is wrong. Use "Choose Finish grey card check to go back to your skin settings." while on, keep the current sentence while off.
4. `Settings/SettingsView.swift:589` "Range or limit" → "Range or Limit"; line 591 "Vertical 9:16, thirds, centre mark" → "Vertical 9:16, Thirds, Centre mark" (control names, mockup 08).
5. Delete the unreachable `PresenterHelp` (`Settings/ShootSetup.swift:300-321`): it still says "Picture row", "Mic level" and "Tools contains…".

### Settings (8)

1. **One page layout.** Today: Camera and monitor has the title at x 342 and full-width rows; Reading has the title at x 342 but the form centred at x 716 to 1596; Microphone and App put the title inside a grouped card (`f4-settings-*-100-dark.png`). Put the same `Text(title).font(.system(size: 28, weight: .bold))` outside every Form at the Camera page's leading inset, remove it from inside `MicrophonePage` (`SettingsView.swift:250`) and the App form, and give all four pages one content column (either all full width, or all `maxWidth: 880` leading-aligned under the title).
2. **Readable form text.** The Reading, Microphone and App forms are 13 pt with 22 pt buttons ("−1%", "+1%", "Reset to 100%", "System settings…", "Test microphone"). Apply `.font(.system(size: 15))` and `.controlSize(.large)` to those Forms so rows match the 17/14 pt Camera rows and buttons reach 44 pt (also an accessibility fix).
3. Replace the segmented bar on the Microphone page with the horizontal `MicMeterView` the Adjust Mic tab already uses (`AdjustPanel.swift:65`).
4. Detail sheets repeat the title ("Zebras" header, then "Zebras" switch row; "Guides" twice, `r3-detail-Zebras-200-top-dark.png`, `r3-detail-Guides-200-lower-light.png`). Give `ZebraAdjustView`, `FalseColourAdjustView` and `AlphaGuideSections` a `showsTitle` flag; in the sheet show only the switch row label, or label the switch row "Show zebras".
5. The − and + buttons in the narrow sheet lose their visible squares (`r3-detail-Zebras-200-lower-dark.png`). In `ExposureNumberRow.controls` (`ExposureLegend.swift:501-512`) use `.buttonStyle(.plain)` with an explicit `.background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))` so they look the same everywhere.
6. Wording items 4 above.

### Set up the shot (8.5)

1. **Key card over the picture at 1000 × 100%** (`g1-setup-1000-100.png`: card right edge x 584, picture left edge x 564). `PresenterView.swift:71` decides `keyFits` from window width only. Also require the actual pillarbox to fit: `(geometry.size.width - meterWidth - pictureWidth) / 2 >= (280 + Space.md * 2) * controlZoom`, with `pictureWidth` from the stage height and the source aspect. Otherwise use the compact "Exposure key" button already used at 200%.
2. **Source pills** (`PresenterView.swift:184-191`). Make line 2 "3840 × 2160 · 25p" only and show the shot as its own pill ("↻ Turned right for vertical" / "Landscape"), as mockup 01. When the pills wrap (200%), build each pill as a `VStack` of its parts instead of joining with "·", so no line ends in a dot (`g1-setup-1000-200.png` "Sony FX3 ·").
3. Keep pills off the picture edge: at 1600 × 100% the pills start in the pillarbox and run onto the picture (`g1-setup-1600-100.png`). Either place them fully inside the picture's top edge (mockup) or fully in the left column under the key.

### Adjust panel (8.5)

1. Tab row is flush with the panel top (`g2-*-100.png`, pills at y 0). Add `.padding(.top, Space.md)` to the tab `HStack` at `AdjustPanel.swift:38`.
2. Tab labels nearly touch their pills ("Zebras", "Mic"). Change `.padding(.horizontal, Space.xs)` at line 28 to `Space.md`, and lead-align the row with the content inset (tabs start about 16 pt right of the content today).
3. Mic tab shows "MIC" twice (tab and the meter heading). Pass a flag to `MicMeterView` to hide its 13 pt heading when hosted in Adjust (`MicMeter.swift:40`).

### Skin tone and grey card (8.5)

1. Wording item 3 above. That is the only blocker.

### Mic meter (8.5)

1. Settings item 3 above (one meter design everywhere).

### Guides (8.5)

1. `Settings/AlphaGuideSections.swift:23` shows Dot/Cross from stored `model.guides` but selects from `effectiveGuides`, so with guides hidden the row appears with nothing selected (`g2-guides-bypassed-100.png`). Show the row only when `effectiveGuides.axes || effectiveGuides.bullseye`, or keep it and show the stored choice selected (dimmed).
2. Give Dot/Cross the same track as Range/Limit (`ExposureLegend.swift`, Range/Limit container) and drop the separate "Centre mark" text label, which repeats the card name; use "Centre mark style" as a small caption above it, or nothing.
3. Advanced embeds `CameraGuideSections` (`AlphaGuideSections.swift:37`), the camera-window form: centred "Framing guides", "Colour", "Frame marker", "Frame shape" labels and a value-less "Guide visibility" slider (`g2-guides-advanced-100.png`). Lay it out like the rest of the panel: leading 17 pt semibold row titles, trailing controls, and a percentage readout on the slider.

### Accessibility (8.5)

1. Settings item 2 (44 pt buttons, 15 pt text in the Settings forms).
2. `Camera/CameraAdjustView.swift:57` `DisclosureGroup("Advanced", …)` is the default 13 pt label. Use the same label as `AlphaGuideSections.swift:37-39` (17 pt semibold, 44 pt min height).

### Visual consistency (8.5)

1. Settings items 1 and 3 (one page layout, one meter).
2. Accessibility item 2 (one disclosure style).
3. Guides item 2 (one segmented style).
4. Delete `ExposurePictureLegend` (`ExposureLegend.swift:310`) and its `alpha-legend-*` snapshots so only `ExposureKey` remains.

### Polish that does not hold back a 9

- Bar: "False colour" touches its tile edges at 150% and 1000 × 100% (`g1-setup-1600-150.png`). Add `.padding(.horizontal, Space.xs)` to the title `Text` at `PresenterView.swift:442` so `minimumScaleFactor` engages before the edge.
- Zebra preset cards: trim the empty bottom space (`g2-Zebras-100.png`).
- Reading page "Choose a script first" grey line is fine, but it sits alone with no button; consider hiding the row entirely when there is no script.

## What I did not check

No build, test run, app launch, VoiceOver, live camera or mic, hover or keyboard. I sampled about 45 of the 1,015 captures (all g1, g2, g3 and f4 sets, chosen g4/r3 detail sheets, library, first launch, mic meter, Clean) and read the source diff since round 2; the `a1x-`, `r8-` to `r15-`, `review*` and `qa*` captures are older fixtures and were not graded.
