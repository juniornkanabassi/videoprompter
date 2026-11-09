# Video Prompter Alpha: Sol round 2 design review

**5 Important findings remain. Not yet all at 9.** The redesign is substantially better. The setup bar, reading transport, Clean, first launch, exposure controls and Settings overview now look like the intended product. The remaining work is bounded: preserve the editor, make all monitor controls act on the visible state, carry enlargement into Settings sheets, finish microphone-name layout and correct accessibility values.

Reviewer: GPT-6.1 Sol. Reviewed 9 November 2026, branch `claude/alpha-hud`, HEAD `5a7775aa2cc53bf83852b603d7558275b2232c73`.

## Evidence and limits

Read-only review of `docs/alpha-redesign/SPEC.md`, both round 1 reports, all nine approved mockups, the current source, and selected fresh offscreen captures in `/private/tmp/VideoPrompter-alpha-r2/`. No app launch, build, test execution, source edit or commit. Only this report and temporary review contact sheets were written. The checkout was clean at inspection.

Screenshot names below are relative to that r2 directory. I inspected setup and reading at 100/150/200%, integrated Adjust at 100/200%, each standalone Adjust section, all four Settings pages in light mode at 100/200%, dark first launch/library, exposure/grey-card/Custom states, the editor and Clean. Contact sheets were followed by full-size inspection of the problematic views. This is a sampled review of the 867 PNGs, not a claim that every file was examined.

Native segmented-control/stepper placeholders are capture artefacts. Camera imagery is a fixture, not evidence of live exposure accuracy. Old names such as `Camera & Recording` do not establish visible recording UI: current call sites and feature guards take precedence. In particular, the absent device rows in integrated Adjust are an intentional `startsCamera: false` fixture condition, not a broken camera chooser. The separate `f2-Camera-*` captures do show two device rows. Scrolling below the fold in an Adjust sheet is acceptable; cropped initial scroll positions alone are not failures.

A 9 means ship quality for the stated user, with only polish remaining. This review does not add recording, calibration, new modes or new product requirements. Numerical sizes in fixes below are implementation guidance for the existing big-control and usable-reading-surface requirements.

## The 19 areas

| Area | /10 | Why, in one line | Fixes needed for 9 |
|---|---:|---|---|
| First launch | 9 | Clear two-path choice, yellow primary and compact enlarged fallback keep both actions discoverable. | None |
| Library | 8 | Navigation and linked-file labels are clearer, but the narrow enlarged editor pane is consumed by its header. | 1 |
| Editor | 7 | Save/Cancel now have proper prominence, but enlargement can leave no writing area or a one-letter-wide presenter editor. | 1 |
| Set up the shot | 8.5 | The picture survives toolbar enlargement and has separate gutters; some Adjust actions can still leave the requested aid hidden. | 2 |
| Reading | 9 | Script dominates, Pause is prominent, and mode, speed, reading settings and keyboard guidance are now present. | None |
| Clean | 9.5 | Picture-only state, visible exit evidence, timed reveal and an always-mounted keyboard-focusable exit match the intended behaviour. | None |
| Bar and tiles | 9 | Distinct zebra icon, larger values, accurate shot labels and deliberate two-row fallback replace the old wall of controls. | None |
| Adjust panel | 9 | Clear close action, consistent inset, readable tabs and one scrolling body now work at both sizes; a full-width sheet is the accepted constrained fallback. | None |
| Zebras | 8.5 | Presets, explanatory labels, large numbers and striped readout now match the target, but bypass can still contradict the readout. | 2 |
| False colour and key | 8.5 | Shared ordered bands and a bounded key fallback are sound; the switch can say on while bypass hides the effect. | 2 |
| Skin tone and grey card | 8.5 | Portraits, explicit Custom state and restoration are improved; starting a grey-card check must also make its aids visible. | 2 |
| Mic meter | 8.5 | Zones, peak/clip behaviour and short-stage fallback are coherent, but the actual enlarged presenter truncates the input name. | 4 |
| Camera and shot | 9 | Three meaningful shot cards, device rows, rename and format-aware source status meet the camera-selection brief. | None; AX value covered under accessibility |
| Guides | 8.5 | Useful illustrated choices and Dot/Cross are present; Advanced shape changes still bypass the visibility-restoration path. | 2 |
| Settings | 8 | The eight-row overview is correct, but opening a detail sheet does not retain the interface enlargement or minimum target treatment. | 3 |
| Wording | 9 | Core vocabulary and non-recording framing are clear; remaining legacy labels are a small, local polish pass. | None; optional N1 |
| Accessibility | 8 | Main controls gained targets, selected traits and focus return; several spoken values still identify the wrong setting or omit the selected camera. | 3, 5 |
| Visual consistency | 9 | Yellow selection, restrained dark monitor chrome and shared card hierarchy now form a coherent system. | None; optional N2–N3 |
| Responsiveness | 7.5 | Setup is dramatically improved; the enlarged editor and separate Settings-sheet path still violate the usable enlarged interface requirement. | 1, 3, 4 |

## Concrete remaining fixes

Paths in this section are relative to `Sources/VideoPrompter/` at the reviewed HEAD.

### 1. Important: protect the writing area in both editors

**Trigger/evidence:** `library-narrow-200-dark.png` shows the long title, save message, three separate header rows and first-use tip occupying the entire detail pane; the script visible at 100% is absent. `Library/LibraryView.swift:471–514` keeps that expanding header outside the writing area. This is not solved by making each header label readable.

`review2-editing-200-dark.png` shows “Read…” as a near-vertical string of characters. In `Presenter/PresenterView.swift:74–90`, the setup source/key gutter remains present whenever `!shell.reading`, including `draft.isEditing`. Lines 105–106 then calculate the editor side inset from the full stage width minus the meter, rather than the editor's actual width after both gutters. Large Save/Cancel controls do not compensate for an unusable editor.

**Exact change:** give the library's enlarged constrained layout a compact persistent header containing the title and a labelled details disclosure; put linked-file metadata and the expanded details inside that disclosure. Make the first-use tip dismissible without consuming the writing pane, retaining its full wording when expanded. Choose this layout from available height as well as width. Keep enough visible text area to read and edit several lines before any header/details scrolling.

For presenter editing, suppress the setup source/key gutter while `draft.isEditing`, and calculate text insets from a GeometryReader belonging to the actual editor region. Use the compact Save/Cancel height at constrained sizes. Preserve the user's chosen text size. Verify with the existing long-title 840×700 library fixture at 200%, and presenter editing with camera/meter on at 1000×700 and the smaller existing editor fixture. The acceptance criterion is readable editable sentences, not merely contained buttons.

### 2. Important: route every explicit monitor choice through effective visibility

**Trigger/evidence, from current source:** set an exposure aid, bypass exposure through the existing exposure action, then open Adjust and switch False colour on or start Grey card check. `Presenter/AdjustPanel.swift:43–45` passes only `$camera.guides`; `Presenter/ExposureLegend.swift:545–558` writes those stored flags. `Camera/CameraModel.swift:119–123` still suppresses them through `exposureBypassed`. A grey-card check can therefore tell the user to make the card green while neither aid is displayed. Zebra presets/number changes have the same visibility mismatch. Settings' False colour summary at `Settings/SettingsView.swift:579` also reports the stored flag, not the displayed state.

The round 1 grey-card edit conflict itself **is fixed**: `CameraGuides.changeExposure` restores the saved check before a manual change and announces the end. This remaining issue is the adjacent bypass path, not a repeat claim that the restore implementation is absent.

Guides has the equivalent partial fix: `Settings/AlphaGuideSections.swift:31–38` restores visibility for the three cards, but its Advanced section embeds `CameraGuideSections`; `Camera/CameraWindow.swift:166–178` changes frame shape/custom dimensions without clearing `framingGuidesBypassed`. After hiding Guides, choosing an Advanced frame can leave that new frame invisible.

**Exact change:** supply model-level actions/bindings to shared Adjust and Settings controls. An explicit request to enable an aid, choose a zebra preset/target, start a grey-card check or choose a guide shape must restore that aid's visibility. Starting Grey card check must clear exposure bypass. Preserve the existing save/restore policy and do not silently enable the other aid after the check ends. Summaries and On/Off values must use effective state, or explicitly say the aid is hidden. Route Advanced shapes and custom dimensions through the same guide-visibility setter as the simple cards.

Verify the sequences “bypass → False colour on”, “bypass → Grey card check → Finish”, “bypass → My skin/Highlights” and “Guides off → Advanced shape”. Assert both displayed/model effective state and the visible readout. Existing grey-card restoration tests start with bypass false and do not establish these cases.

### 3. Important: retain enlargement and large targets inside Settings detail sheets

**Evidence:** the Settings overview correctly scales through `Settings/SettingsView.swift:70`. Its separately presented sheet at lines 586–608 builds a new VStack, fixed minimum 480×500, with no `.uiZoom(store.uiZoom)`. `App/VideoPrompterApp.swift:332–348` implements zoom as a layout/scale wrapper, not an inherited environment scale. Presenting a sheet from within that wrapper does not apply it to the new sheet content. The overview captures therefore cannot certify the sheet.

The sheet's Done action at line 588, exposure-key toggle at 596 and Advanced buttons at 600–601 also lack the explicit 44 pt target treatment used in Adjust. This is the remaining shared-Settings integration gap.

**Exact change:** apply the chosen interface zoom to the sheet's content, including its persistent heading and Done action. Bound the outer sheet to the available window/screen and keep its body vertically scrollable. Give Done and the discrete controls at least 44 pt base targets. At narrow effective widths, wrap the Zebra presets and put the label above the number-control row rather than squeezing the current fixed HStack (`ExposureLegend.swift:428–441,477–483`). Reuse the responsive Camera shot cards already implemented.

Obtain fresh detail-sheet evidence for Camera, Shot, skin, Zebras, False colour, Guides and Exposure key at 200%, including a scrolled lower section. Do not simply enlarge the hard-coded sheet until it exceeds the display. No detail-sheet capture in the inspected set proves this path at present.

### 4. Important: keep the microphone identity readable in its real presenter allocation

**Evidence:** `f1-setup-1000-200.png` and `f1-reading-1000-200.png` show “ZOOM UAC-2…” even though the real input is the short name “ZOOM UAC-232”. `Presenter/MicMeter.swift:105–110` allows two lines but lets the label compress inside the available-height stack. This is actual presenter evidence, unlike round 1's deliberately undersized standalone fixture. The numeric readout and No signal are now readable, and the scale no longer collapses.

**Exact change:** give the name its measured two-line height (`fixedSize(horizontal: false, vertical: true)` or equivalent) and have the short-stage horizontal layout reserve that space before allocating the track. Keep the complete name available through an accessible details/help action for genuinely long device names. Do not shrink the name to make it fit. Preserve the current 34 pt track, zone boundaries, dBFS unit and clipping latch.

### 5. Important: finish truthful accessibility values on the new controls

**Evidence:** `Presenter/ExposureLegend.swift:480,482` hard-codes “zebra” into both number-button labels, but those same rows are reused for Custom skin level/range at lines 532–534. A screen-reader user changing skin reference is told they are changing zebras, precisely the two independent controls the redesign separates.

`Presenter/PresenterView.swift` in `shellTile` supplies `shotLabel` as Camera's accessibility value instead of the selected camera. The spec explicitly asks for the selected camera as the opener's value. `Settings/AlphaGuideSections.swift:45–46` has an On/Off string but no toggle trait or non-colour selected marker; selection is otherwise just the border.

**Exact change:** parameterise the exposure row's semantic subject so it says “skin reference level” or “zebra level” as appropriate, retaining the current value. Give Camera a value containing the selected display name and shot. Add the toggle trait and an explicit checked indicator to enabled guide cards, driven by effective visibility. Keep the current opening/closing focus restoration; do not replace it with another focus system.

Inspect the resulting accessibility tree for both Custom rows, Camera with a nickname, and Guides on/off/bypassed. VoiceOver and keyboard runtime checks remain NOT RUN here, as requested.

## Every round 1 finding rechecked

“Fixed” below means supported by current source and the supplied evidence where applicable, not that I executed its test. “Partial” points to a remaining issue above. A prior request that exceeds the spec is explicitly retired rather than silently made a new release requirement.

### Sol's 15 numbered findings

| R1 | Status | Round 2 result |
|---|---|---|
| 1 Stage height budget | Fixed for setup | Deliberate bar fit, secondary tools in Adjust and two rows preserve a substantial stage in `f1-setup-1000-200`; editor has separate issue 1. |
| 2 Enlarged Adjust and exit | Fixed for Adjust | Scaled-width/full-width-sheet choice, Close Adjust, 16 pt tabs, one scrolling body and focus-return implementation are present. Separate Settings sheets are issue 3. |
| 3 Unified stage/key/meter layout | Partial | Explicit gutters and Exposure key fallback are implemented; presenter editing incorrectly retains the setup gutter, issue 1. |
| 4 Meter geometry | Partial | Horizontal fallback, separate dBFS, readable No signal and latched AX clipping fixed; input-name truncation remains, issue 4. |
| 5 Identity/tile truth | Partial | Wrapping source, actual shot labels, expanded Adjust and effective main-tile state fixed; shared adjustment bypass and Camera AX value remain, issues 2/5. |
| 6 Reading status/settings | Fixed | Mode/speed/status, Reading settings and keyboard hint now appear alongside the prominent Pause control. |
| 7 Editor header and targets | Partial | Names wrap and header/Save/Cancel targets improved; the header now consumes the editor at 200%, issue 1. |
| 8 Grey-card consistency | Partial | Manual edits end and restore the check; green range wording agrees; starting under bypass remains broken, issue 2. |
| 9 Shared Settings | Partial | Eight overview rows and shared detail views replace degrees/jump strip; sheet zoom/targets remain, issue 3. |
| 10 Decision-support legibility | Fixed visually; semantics partial | 88 pt grid, 64 pt portraits, readable ranges, persisted Custom, ordered legend and selected checks are in place; reused Custom number labels need issue 5. |
| 11 Vocabulary | Substantially fixed | Set up camera, Clean, False colour and honest off-state zebra wording are present; small residual labels are N1. No current recording-label regression established. |
| 12 Both first-launch choices | Fixed | Compact enlarged fallback exposes Read a script and Set up camera together. |
| 13 Coherent Guides | Partial | Illustrated primary cards, Dot/Cross and removal of duplicate advanced enable switches fixed; Advanced visibility remains issue 2. |
| 14 Semantics/focus | Partial | Selected traits and focus restoration added; always-mounted Clean exit fixed; inaccurate Custom/Camera values and guide semantics remain issue 5. |
| 15 Accent/hierarchy | Fixed to ship level | Yellow primary/selection and shared insets are consistent; small decorative differences are optional N2–N3. |

### Opus's 16 fix packages

| R1 | Status | Round 2 result |
|---|---|---|
| 1 Responsive setup bar | Fixed | Deliberate grouped two-row fallback, no orphan Mic/separator, readable labels and surviving picture. |
| 2 Settings overview | Partial | Eight rows, no inner navigation strip/degrees, cleaner App/Microphone pages; detail enlargement is issue 3. A wholly new meter component is not required when the existing shared zone model is coherent. |
| 3 Controls/accent/insets | Fixed to ship level | Yellow selections, switches, flat Mic tab and consistent padding. Adding a second local live meter/Settings shortcut is retired as an optional enhancement, not required by the spec. |
| 4 Tile detail | Fixed | Stripe swatch, 13 pt values, meaningful shot, 24 pt icons, 22 pt primary, simultaneous long press. |
| 5 Guides | Partial | Picture-style cards, Dot/Cross and natural-height Advanced fixed; visibility and guide semantics remain issues 2/5. |
| 6 Zebra adjust | Fixed visually | Questions, full-width mode row, large number/glyph treatment and striped readout match the target. Effective-state issue is 2. |
| 7 First launch | Fixed | Yellow icons/primary, button icons, quiet extras and compact enlarged choices. Extra Import link is useful and does not block 9. |
| 8 Short-stage meter | Partial | Colliding labels and dBFS truncation fixed by fallback; input-name truncation is issue 4. |
| 9 Reading | Fixed | Prominent Pause, illustrated compact exposure chip, mode and shortcut guidance. |
| 10 Editor/library | Partial | Proper edit transport and consistent Open presenter entry points implemented; editor area issue 1 remains. Two legacy Reading labels are N1. |
| 11 Camera/shot | Fixed to ship level | Two-device fixture, format-aware source code, smaller Rename, clear shot cards and advanced selection semantics; bare Automatic visual state is optional N3. |
| 12 Setup details | Fixed to ship level | No camera chosen is actionable, mic visibility is independent, key says Skin where relevant, neutral empty stage/recovery path. The fixture's no-device condition is not a product regression. |
| 13 Clean | Fixed | `f1-exit-pill-visible.png` supplies missing visual evidence; icon, Escape and fade/focus implementation present. |
| 14 Skin/grey-card visuals | Fixed to ship level | Custom aligns, neutral help card and grey-card switch implemented. Missing pink decoration is optional N2; bypass behaviour remains issue 2. |
| 15 Accessibility | Partial | Main toggle/selection traits and larger controls landed; specific remaining issues 3/5. No unsupported contrast failure inferred from the image. |
| 16 Wording | Substantially fixed | Main vocabulary and sentence-case pass landed; small leftovers N1. Text rotation degrees are not camera Shot controls and need not be removed. |

Opus's separate ten-item “Regressions against the mockups” list is also covered: 1 icon fixed; 2 source/status fixed with source-dependent format; 3 Skin prefix fixed; 4 Zebra hierarchy fixed; 5 camera detail/inset fixed; 6 Shot degrees removed from the principal path; 7 first launch fixed; 8 Settings overview fixed, detail path still issue 3; 9 reading fixed; 10 accent fixed. No item in that list is silently omitted.

## Optional polish, not reasons to withhold a 9

- **N1, wording:** `Library/ReadingInspectorView.swift:34,40` still says “Show in Presenter” and “Narrow Column”. Use “Open presenter” and “Narrow column”. `Presenter/ExposureLegend.swift:267` and the setup key use two equivalent grey-band explanations; standardise on “Everything else shows in grey.” This is a local consistency pass, not a new vocabulary rewrite.
- **N2, skin help:** add the mockup's small pink swatch alongside the normal “Pink shows skin…” card (`ExposureLegend.swift:536`). The current plain-language text already conveys the meaning.
- **N3, advanced camera:** give Automatic the same visible selected indication as Upside down (`Camera/CameraAdjustView.swift:42–45`). Its selected accessibility trait already exists; this is a secondary-path visual consistency improvement.

## Verification and handback

Current-source inspection: complete. Screenshot review: complete within the sampling scope above. `zsh test.sh`, built-app checks, live camera, VoiceOver, actual sheet interaction and hardware microphone checks: **NOT RUN**, by the read-only/no-launch instruction. Existing test implementations were read, not treated as passing results.

Retain the current design direction. Fix the five bounded classes above, then review fresh evidence of those paths. There is no justification here for another broad redesign or adding recording. Questions skipped because the review brief and output destination were complete.
