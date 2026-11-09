# Video Prompter Alpha: independent design review, round 1

Reviewer: GPT-6.1 Sol. Revision: `7d95117c315431c9d52ef31e4f23a49cee69fa0c`, branch `claude/alpha-hud`. Reviewed 9 November 2026.

**15 ranked findings. Not ready to approve.** The new direction is right. The implementation preserves the names of the controls more successfully than it preserves the activity those controls support. At 200%, the setup toolbar can consume almost the entire camera stage. A reference monitor without a usable picture is not accessible simply because its buttons are large.

## Evidence and limits

Read-only inspection of the spec, all nine approved mockups, supplied screenshots and relevant SwiftUI/model code. No app launch, build, test run, source edit or commit. Only this report and temporary contact sheets were written. Test results below are source inspection of existing tests, not claims that I ran them.

Screenshot names below refer to `/private/tmp/VideoPrompter-alpha-r1/`, unless prefixed `artifacts/package-e/`. Approved targets are `01-09*.png` in the supplied Mockups folder. Dimensions proposed below are logical points at 100%, before interface scaling.

I inspected the 100/150/200% setup captures, first launch at all three sizes, narrow/enlarged library, reading/editor, Clean, both themes of the new Settings pages, exposure panels, tone/grey-card states and meter states. I did not treat old round captures as current truth. In particular, `library-200-light.png` includes a Recordings folder, but current `LibraryView.swift:60-75` does not create that folder. That screenshot is not evidence of a current recording regression. `artifacts/package-e/pkgE-adjust-False colour.png` predates the portrait picker; current `alpha-false-colour-*` and source supersede it. Missing native window toolbars in content-only captures are not missing product controls. Yellow native-control placeholders are not defects. Fixture imagery cannot establish live camera performance or calibration.

The supplied spec and mockups, not missing generic PRODUCT.md metadata, define the product. Scores assess the worst supported relevant condition, not just the best-looking 100% screenshot. A 9 means ship-quality for this user; it does not mean live hardware or VoiceOver was tested.

## Grades

| Area | /10 | Why | Required fixes below |
|---|---:|---|---|
| First launch | 8.5 | Clear two-path introduction, but fixed-height cards push the second decision below the initial enlarged viewport. | 12, 15 |
| Library | 8 | Calm structure and readable script titles; terminology and tiny secondary controls weaken the next action. | 7, 11 |
| Editor | 7.5 | Writing surface is strong; its control row breaks at 200%, and useful controls are only 24 pt high. | 7 |
| Set up the shot | 5 | The stage loses to toolbar growth and independent overlays; enlargement destroys its principal purpose. | 1, 3, 5 |
| Reading | 8 | Dominant script and three transport actions are good; mode/status and keyboard guidance from the target are missing. | 6, 3 |
| Clean | 9 | Picture-only view, pause-at-word, Escape and temporary exit affordance are implemented coherently. | None required for 9; see verification limits |
| Bar and tiles | 6 | Labelled, legible buttons and state borders work; indiscriminate wrapping creates a wall of controls. | 1, 5 |
| Adjust panel | 6 | Correct sections, wrong responsive geometry, tiny tab text and no visible close action. | 2, 10 |
| Zebras | 8 | Presets and large number controls are a good base; “Stripes on” can describe a disabled effect. | 8, 9, 10 |
| False colour and key | 7.5 | Shared colour model is good; the key has no height strategy and the panel reverts to a tiny differently ordered list. | 3, 8, 9, 10 |
| Skin tone and grey card | 7 | Portraits are useful; ranges shrink, Custom is local UI state and grey-card state can contradict its controls. | 8, 9, 10 |
| Mic meter | 7 | Proper zones, peak hold and clip latch exist; scale labels overlap when the stage shrinks and narrow readouts truncate. | 4 |
| Camera and shot | 8 | Clear shot cards, nicknames and connection information; Settings still exposes degrees and source text cannot reflow safely. | 2, 5, 9, 10 |
| Guides | 8 | Three useful choices are first; Advanced repeats them under competing names and choices can be hidden by bypass. | 9, 13 |
| Settings | 6.5 | Four-page navigation is improved; the camera page is still the old long form, not the approved overview/shared controls. | 9, 10 |
| Wording | 7 | Main transport language is clear; menus, hints and other entry points still use competing or recording-specific language. | 6, 8, 11 |
| Accessibility | 6.5 | Scaling, labels and several state values exist; small targets, truncation and inconsistent selection semantics remain. | 1–5, 7, 10, 14 |
| Visual consistency | 7 | Monitor shell is coherent; accent, hierarchy, exposure lists and Settings still look like separate generations. | 9, 10, 15 |
| Responsiveness, from code | 4.5 | Width wrapping exists; height budgets and scaled fixed-width side panels are not solved. | 1–4, 7, 12 |

## Ranked fixes to reach 9

### 1. Important: give the camera stage a protected height budget

**Evidence:** `presenter-idle-camera-200-dark.png` shows little more than a strip of stage above three rows of controls. The 150% capture already spends roughly half its height on the bar. `PresenterView.swift:222-225,256-297` scales a wrapping bar containing 190×92 transports and 104×92 tiles. `WrapLayout` at `457-493` wraps solely by width, measures children with an unspecified proposal, and has no stage-height constraint. The 200% package-E screenshot at a larger window is better, but still gives a very large fraction to controls.

**Change:** choose the bar layout using available width **and height before scaling**. Keep the approved full 132 pt bar where it fits. At constrained sizes, move Guides and Mic into Adjust first, as the spec permits, then use 44 pt minimum base-height transport rows instead of retaining 92 pt tile height for everything. Use 16–18 pt labels, allow two-line labels, and never shrink the text. Keep Camera, Zebras, False colour, Adjust and Clean reachable. Reserve at least half the usable window height for the picture at the supplied 1000×700 case; keep at most two toolbar rows there. If even the reduced bar cannot fit, use a labelled, scrollable tools sheet rather than another permanent row.

**Regression:** mockups 01–04 make the picture dominant. Current 200% layout reverses that hierarchy. Acceptance must assert visible camera-stage dimensions, not just that every AX button frame is inside the window. The current test at `PresenterShellTests.swift:testSetupLabelsAndRealToggleValuesPersistAt200Percent` checks containment in 1600×1200, which misses this failure.

### 2. Important: make Adjust usable when enlarged, with an obvious exit

**Evidence:** `AdjustPanel.swift:18-44` applies `.uiZoom(zoom)` inside a fixed 470 pt outer width. At 200%, content gets only about 235 unscaled points before its own padding. Fixed three-shot rows, two-preset rows and number rows do not all fit. `PresenterView.swift:177-181` always reserves that panel beside the stage. There is no Close button; Escape and the bottom Adjust tile are the exits. Standalone package-E captures prove the sections at 100%, not an integrated enlarged panel.

**Change:** keep 470 pt at 100%. Above that, allocate sufficient scaled width only when at least 400 pt of usable stage width remains. Otherwise present Adjust as a full-width sheet with a persistent 44×44 minimum **“Close Adjust”** button, 18 pt title and a short instruction, **“Changes appear on your camera picture.”** Wrap tab labels at 16 pt rather than keeping 13 pt. Reflow Shot cards and Zebra presets vertically when their intrinsic widths exceed the body. Number rows should place the 18 pt label above the 46 pt minus/value/plus controls at narrow widths. Use one vertical scroll container, not the outer ScrollView plus CameraAdjustView's inner ScrollView. Restore keyboard focus to the opening tile on dismissal.

### 3. Important: lay out the picture, exposure key and meter as one stage

**Evidence:** `PresenterView.swift:71` reserves left picture space with a formula based on `300 * controlZoom`; the key at `104-105` and meter at `110-116` are independent overlays. There is no corresponding reserved right gutter for the meter. The full key has an intrinsic, non-scrollable seven-row height (`ExposureLegend.swift:381-413`), so a 200% key can exceed the remaining stage even after fixing the bar. The meter overlays the same area in which script text is laid out (`PresenterView.swift:59,86`).

**Change:** use explicit left key / fitted picture / right meter regions in setup. Prefer existing pillarboxes; otherwise reduce the fitted picture symmetrically inside the remaining stage rather than the current one-sided padding calculation. Use measured key dimensions and 16 pt gutters. If a full key cannot fit vertically, show a 44 pt **“Exposure key”** button opening the full list in a scrollable panel. Keep the reading chip compact, 14–16 pt, and reserve the meter gutter from script width as well. Do not allow key rows, source pills or meter labels to overlap the face or the reading column.

**Regression:** the target explicitly places the key beside the picture and preserves the script's dominance. Width-only positioning does not fulfil that at enlarged sizes.

### 4. Important: give the meter an honest minimum geometry

**Evidence:** the 150% setup capture has overlapping 0 and −6 labels; the 200% capture collapses the scale into the stage strip. `MicMeter.swift:45-76` distributes labels over whatever height remains after title, CLIP, readout and mic name. The standalone `alpha-vertical-mic-*` captures truncate “dBFS” and “No signal”, but those fixtures offer only 80 pt including padding (`AppearanceSnapshotTests.swift:385-394`), narrower than the presenter's 120 pt allocation. Do not present that fixture truncation as proof that the normal 120 pt presenter always truncates.

**Change:** retain the 34 pt bar, 14 pt tick labels and 22 pt numeric readout. Give the scale track at least 180 pt base height so the closely spaced 0/−6 labels remain distinct. Put the value and **“dBFS”** on separate deliberate lines, not arbitrary wrapping; show **“No signal”** in full. Wrap the mic name to two 14 pt lines and provide the full name to accessibility. In a shorter stage use a horizontal meter with the same named value and CLIP state instead of squeezing the vertical one. AX output must include mic name and the latched **“Clipping”** state, not just the instantaneous clipping boolean (`MicMeter.swift:84-87`). Capture actual 120 pt presenter usage as well as the deliberately narrow fixture.

### 5. Important: make source identity fit and tile state tell the truth

**Evidence:** `PresenterView.swift:188-191` is a non-wrapping HStack of source summary and Shot pill, with unscaled `.callout` typography. A real nickname + capture card + resolution + rate is much longer than the fixture's “Camera”. Camera tile value at `264` reduces all nonzero angles, including 180°, to “↻ Vertical”. The Adjust tile never displays its open/selected state. Zebra/False colour tiles announce stored values even when `camera.exposureBypassed` hides both (`265-266`, `CameraModel.swift:120-139`).

**Change:** use a wrapping 14 pt scaled status layout. First line: nickname and connection; second line: resolution, rate and full Shot label. Preserve full names through wrapping or an accessible details action. Use **“Landscape”**, **“Vertical turned left”**, **“Vertical turned right”**, **“Upside down”** or **“Automatic”** from the actual state for the Camera value. Give Adjust a selected border and AX expanded value when open. Drive tile visuals and AX On/Off from effective displayed exposure state. Clicking an apparently-off aid must restore it immediately, including clearing bypass, rather than first changing a hidden stored boolean.

### 6. Important: restore reading status without adding a dashboard

**Evidence:** mockup 05 contains “Voice follow · on” and keyboard guidance. Neither is in `artifacts/package-e/pkgE-reading.png`. `PresenterView.swift:257-260` supplies only transport; `readingStatus` is announced at `215` but not persistently shown. Reading mode/speed is available only through the conditional notice popover (`319-358`) or elsewhere in app Settings. With no notice, the bottom bar does not explain whether speech or timed scrolling is driving it.

**Change:** add one quiet 14 pt status line, **“Voice follow · Listening”**, **“Voice follow · Paused”**, or **“Automatic scroll · [speed]”**, according to actual mode/state. A 44 pt-high **“Reading settings”** action should reach mode and speed even without an error. Show **“Space: pause or resume · Esc: set up the shot”** in 13–14 pt, wrapping below the buttons when necessary. Keep status outside the reading column and use existing session state. Preserve the existing script size; do not enlarge every footer item until it steals the text area.

### 7. Important: repair the editor header, not the writing surface

**Evidence:** `library-narrow-200-dark.png` visibly shows “Editor text si…”, splits “Linked” into “Linke / d”, and truncates the first-use instruction. `LibraryView.swift:481-499` is an inflexible HStack; its two controls have 24 pt minimum height. `LibraryStartView.swift:62-65` forces the instruction to one line and offers the same string twice as its supposed fallback.

**Change:** use a wrapping header row, moving **“Linked file”** onto its own 14–16 pt status line when needed. Make **“Editor text size”** and **“Script details”** 44 pt-high targets with 16 pt labels. Allow the whole instruction **“Choose Present, then Start reading.”** to wrap to two lines. Keep “Got it” at 44×44 minimum. Retain the generous editable text area and autosave message. Apply the same minimum target to presenter **“Save changes”** and **“Cancel editing”** individually (`PresenterView.swift:242-244`); setting the parent HStack's height does not enlarge each button's hit area.

### 8. Important: keep grey-card mode and its effective state coherent

**Evidence:** `CameraGuides.swift:86-99` enables both exposure aids at 41 ±2 and restores earlier values on exit. That is good. But only FalseColourAdjustView's own toggle and SkinTonePicker are disabled (`ExposureLegend.swift:515,523`). Toolbar toggles and ZebraAdjustView can still turn aids off or change the target while **“Grey card check”** remains selected. The card then tells the user to look for green/stripes that need not be active. Its status says green at 39–43, while the key deliberately describes the combined green range as 38–43 (`CameraExposure.swift:28-30,52-53`), another avoidable ambiguity.

**Change:** while grey-card check is on, either disable conflicting aid/target edits everywhere, or exit the check before applying an explicit manual change and announce **“Grey card check ended.”** Use the same policy in tiles, Settings, keyboard/menu actions and Adjust. Show an undimmed 16 pt status **“Grey card check on · Zebra target 41 ±2 IRE”** and **“Green shows 38 to 43 IRE”** to match the actual colour table. Keep the 18 pt action **“Finish grey card check”** visible and restore the saved skin/zebra settings on that action. Do not recolour the renderer simply to conceal a wording disagreement.

### 9. Important: finish the shared Settings implementation

**Evidence:** `SettingsView.swift:573-590` still uses CameraSettingsSections and CameraExposureSections, with a TODO at `582` saying to replace them. `alpha-settings-Camera and monitor-*.png` shows Shot as **“0°”**, a Camera/Guides/Exposure jump strip and a long form. Mockup 08 instead has a short overview with rows for Camera, Shot, My skin reference, Zebras, False colour, Guides, Exposure key and Advanced. `CameraWindow.swift:155-157` still builds the old rotation choices. Settings has the portrait picker but not the complete shared grey-card workflow.

**Change:** implement those eight overview rows, 56 pt minimum height, 17 pt labels and 15 pt current values. Open the same CameraAdjustView, ZebraAdjustView, FalseColourAdjustView and guides content used by Adjust. Make **“Exposure key”** a real user setting/reachable control, not merely an always-conditional overlay. Keep uncommon options under Advanced. Remove the redundant jump strip. This also supplies the grey-card check in Settings and eliminates competing presentations of the same settings.

### 10. Important: stop shrinking the information that supports decisions

**Evidence:** tone ranges use `.caption2`, a one-line limit and a 0.7 minimum scale (`ExposureLegend.swift:497-499`). The six cards are packed into a 64 pt adaptive minimum (`484`); the enlarged fixed-width panel then has too few base points. Custom selection is local `@State` (`479`) while actual `skinTone` is derived from numeric equality; choosing Custom without changing the default value can reopen as Deep and hide Custom controls. Adjust tabs are 13 pt. Its tiny FalseColourKey uses 16 pt swatches and `.callout` (`249-264`) rather than the setup key's hierarchy.

**Change:** tone cards minimum 88 pt width, portrait minimum 64×64, name 16 pt, range 14 pt. Reflow rather than scale down. Persist an explicit Custom editing choice, or make Custom open an editor that stays available even when its numbers equal a preset. Use one shared ordered legend: My skin, Signal white, Near white, Mid grey, Very dark, Near black. In Adjust use 32×24 minimum swatches, 16 pt names and 14 pt ranges; in the full setup key retain the spec's 44×28, 19 and 15 pt. Every selection needs an explicit selected indication and AX selected state, not just a thin accent border. Use a checkmark for chosen preset/Shot/tone cards.

### 11. Important: complete the vocabulary pass, including hints and menus

**Evidence:** `LibraryView.swift:579` still says **“Camera Only”** while onboarding says **“Set up camera”**. `VideoPrompterApp.swift:181-183` retains **“Clean Presenter View”** and **“Check Brightness · False Colour”**. `CameraWindow.swift:154,157` exposes the help text **“Stop recording to change this”** even in Alpha. ZebraAdjustView's summary (`ExposureLegend.swift:430`) always says **“Stripes on…”** although the effect can be off. `SkinTonePicker` tells the user pink and My skin zebras show where skin should sit regardless of whether either aid is enabled.

**Change:** use **“Set up camera”**, **“Clean”**, **“False colour”** everywhere, including native menus and accessibility labels. In Alpha remove recording-only help instead of replacing it with another warning. When Zebras is off show **“Zebras off · Target 43 to 47 IRE”**; when on show **“Stripes on 43 to 47 IRE”**. Skin help: **“Choose the face closest to your skin tone. Turn on False colour to check your skin in pink.”** Keep IRE for pro users, with one 14 pt explanation **“IRE is the brightness level of the incoming picture.”** Do not imply these aids change camera exposure.

### 12. Important: make both first-launch choices discoverable when enlarged

**Evidence:** `first-launch-150-light.png` shows the second card's heading but its camera action falls below the initial viewport. At 200%, mostly the first card is visible. `LibraryStartView.swift:29,52` keeps a 600 pt minimum content height and 260 pt minimum card height before scaling. Scrolling works structurally, but the opening question promises two choices and immediately shows only one actionable choice.

**Change:** retain the current headline and exact non-recording explanation. In the stacked layout reduce card padding to 20 pt, remove the 260 pt minimum, and arrange each card as title, one short 16 pt explanation and 44 pt actions. Put the two primary choices before secondary Help/Practice/Import. If both cards still cannot fit, use two compact 56 pt-high labelled entry rows, **“Read a script”** and **“Set up camera”**, then expand the selected path. Do not solve this by shrinking the type.

### 13. Important: make Guides one coherent control surface

**Evidence:** `AdjustPanel.swift:51-55` and `AlphaGuideSections.swift:8-15` offer the right simple choices, then include the old settings wholesale. `CameraWindow.swift:197-200` repeats Thirds as “Rule of thirds” and Centre mark as both “Centre cross” and “Centre target”. The simple bindings update stored guides but do not clear `framingGuidesBypassed`, so selecting a guide after the tile hid guides can leave it invisible (`CameraModel.swift:105-128`).

**Change:** retain 44 pt rows **“Vertical 9:16”**, **“Thirds”**, **“Centre mark”**. Advanced should contain only additional frame shapes, guide colour/visibility and a **“Centre mark style”** choice of **“Dot”** or **“Cross”**, not duplicate enable switches. Selecting any guide should enable its display and clear bypass. Provide 14 pt helper text **“Guides help frame the picture. They do not change the camera.”**

### 14. Important: complete semantics and focus for the custom controls

**Evidence:** tiles have useful On/Off values, but presets/Shot/tone cards mostly supply an AX value string rather than selected traits; camera rows lack an explicit selected AX value (`CameraAdjustView.swift:18-32,64-74`). Step buttons announce “Increase Level” without the current value (`ExposureLegend.swift:454-458`). The Adjust content swaps with no explicit focus move. Clean's exit button is conditionally inserted only after pointer movement or while already focused (`PresenterView.swift:184-186`), so keyboard-only discovery needs direct verification.

**Change:** expose Camera rows and preset choices as named selection groups with selected state. Name the number controls **“Increase zebra level, currently 45 IRE”** and equivalent range/skin controls. Move focus to the chosen Adjust section heading on open and back to its tile on close. Keep an accessible, keyboard-reachable **“Exit Clean”** action even when its visual pill is faded; show the pill while that action has keyboard focus. Verify Space, Escape, tab order, selected-state announcements and focus return with the actual app in a later authorised offscreen/assistive-technology pass. Static attributes and screenshots alone do not prove the VoiceOver experience.

### 15. Nit: use one accent and finish the hierarchy

**Evidence:** mockups use a yellow primary/selected treatment throughout; presenter hardcodes yellow, isolated new panels show blue selected borders, and first launch relies on the system accent (`LibraryStartView.swift:37,48`; `ExposureLegend.swift:441,502`; `AdjustPanel.swift:46`). This is a visual regression, not a reason to invent another design system. The camera cards also get extra nested padding compared with neighbouring panels.

**Change:** apply the same approved yellow accent to the Alpha's primary actions and selections, with black text on yellow and a checkmark for state. Reserve white for normal text and a separate visible focus outline for keyboard focus. Use consistent 24 pt panel insets, 16 pt section gaps and 12 pt control gaps. Preserve light-mode surfaces with adequate contrast; do not force every library/settings surface black just to match the monitor.

## What deserves to stay

The main picture/reading/Clean distinction is right. Keep the explicit Start reading, Pause, Back to start and Set up the shot actions. Keep the per-camera naming and Shot persistence. Keep independent skin reference and zebra targets, the shared exposure colour model, and the grey-card restore snapshot. Keep the mic's permanent zone track and timed clip latch. Keep the simplified four-page Settings navigation. Fix the integration around these decisions rather than restarting the design.

## Approval boundary

Clean earns 9 on the supplied image and inspected pause/fade/Escape implementation; its runtime tests were read, not rerun. All other grades remain below 9 until their mapped fixes are implemented and shown in fresh integrated evidence. Later verification should cover 1000×700 and 1600×1000 at 100/150/200%, both themes, integrated Adjust on every tab, long real camera/mic names, a full false-colour key, grey-card conflicts, and keyboard/VoiceOver focus. Show the whole usable stage as well as each control. Do not call a native-control capture artefact a product bug, and do not call a passing containment test proof of a usable reference monitor.
