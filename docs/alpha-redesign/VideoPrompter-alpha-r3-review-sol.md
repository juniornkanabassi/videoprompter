# Video Prompter Alpha: Sol round 3 design review

**2 Important findings remain. 14 of 19 areas reach 9 or above.** The main presenter is now at ship quality. The remaining work is a stale first-use guide and the separate Settings > Advanced orientation controls. Keep the design; do not start another broad redesign.

Reviewer: GPT-6.1 Sol, independent read-only review, 9 November 2026. Checkout `claude/alpha-hud`, HEAD `0cf857d`. No edits to the checkout, builds, test runs, launches, commits or live-device interaction. Only this report and temporary image contact sheets were written.

## Scope and evidence

Read `docs/alpha-redesign/SPEC.md`, both round 2 reports, their round 1 status ledgers, current connected source and the round 2-to-3 diff. Inspected all nine approved mockups and sampled fresh screenshots from `/private/tmp/VideoPrompter-alpha-r3/`, using contact sheets followed by full-size inspection of disputed details. This is not a claim to have examined all 1,015 PNGs.

Screenshot names below are relative to that r3 directory, including names beginning `r2`, `review2` and `f1`. They are current captures, not historical screenshots. Native yellow picker/stepper placeholders are excluded from scoring. The picture is a fixture; it proves layout, not live camera, exposure or microphone accuracy. Empty device lists in `startsCamera: false` captures are not camera-selection failures: `g3-camera-200.png` separately demonstrates the populated chooser.

This uses the native, single-reviewer path of the Impeccable critique guidance. The explicit user brief supplies the product context and grading scale. No additional reviewers were spawned. A 9 means ship quality with polish remaining, not pixel identity with a mockup. Scrolling within a bounded enlarged settings sheet is acceptable. Small decorative differences, existing alternate-window components and unexecuted hardware checks do not automatically subtract a point.

## The 19 grades

| Area | /10 | One-line reason and round 2 status | To reach 9 |
|---|---:|---|---|
| First launch | 8.5 | Both large entry paths meet the mockup and survive enlargement; Help still opens instructions for the removed Tools workflow. R2 visual findings fixed. | F1 |
| Library | 9 | The compact header, aligned disclosures and dismissible tip leave actual writing space at narrow 200%; both reviewers' header finding fixed. | None |
| Editor | 9 | Readable sentences replace the one-letter column; Save/Cancel padding and enlarged status work. Both R2 editor findings fixed. | None |
| Set up the shot | 9 | Fitted picture, gutter/key fallback and complete source identity survive 200%; effective aid actions and source wrapping fixed. Exact separate shot-pill styling is polish. | None |
| Reading | 9 | Prominent Pause, status and settings remain clear; the key has reserved top space and no longer covers the first line. R2 overlap fixed. | None |
| Clean | 9.5 | Picture-only view and small Exit Clean pill match the target; fade, focus and pause-on-entry paths remain intact. R2 passed state retained. | None |
| Bar and tiles | 9 | Names and icons now align, badges fit inside tiles, and deliberate two-row fallback keeps labels. R2 alignment issues fixed. | None |
| Adjust panel | 9 | Tabs, close target and one scrolling body replace stacked headers; Mic includes a meter and narrow layouts suppress the crowded stage meter. R2 findings fixed. | None |
| Zebras | 9 | Accent Range/Limit, adaptive presets, labelled numeric controls and effective on/off/readout meet the task. R2 visibility and layout issues fixed. | None |
| False colour and key | 9 | Shared band data, stacked name/range and identical footer agree; the switch reflects effective visibility. R2 functional findings fixed; literal component unification is unnecessary. | None |
| Skin tone and grey card | 9 | Custom is deliberate; grey-card mode keeps the previous tone dimmed, hides Custom edits and has one finish action. R2 bypass and conflicting-target findings fixed. | None |
| Mic meter | 9 | Actual enlarged presenter retains the input name, no-signal state and zones; peak/CLIP logic is present. R2 name fix landed; alternate Settings styling is non-blocking. | None |
| Camera and shot | 8.5 | Populated rows, formats, stable shot cards and Adjust's Automatic switch are fixed; Settings > Advanced still offers stateless orientation actions. | F2 |
| Guides | 9 | Checked, labelled primary cards and Dot/Cross use effective state; Advanced frame choices now restore visibility. R2 findings fixed. | None |
| Settings | 8.5 | Four titled pages and scaled, bounded detail sheets are fixed; Advanced still duplicates orientation with no selected state. | F2 |
| Wording | 8 | Most local labels are fixed, but the first-use guide teaches Tools, arrows, Mic level and Legend instead of the shipped workflow. | F1 |
| Accessibility | 8.5 | Custom number subjects, Camera identity, guide toggle traits and enlarged targets are fixed; Advanced orientation omits current state for assistive users too. | F2 |
| Visual consistency | 9 | Primary/selection accent, stable card checks, aligned tiles and trailing main switches form one recognisable system. Remaining alternate Settings meter/key styling is polish. | None |
| Responsiveness | 9 | Enlarged script, library and Settings detail paths now remain usable; sampled 100/150/200% layouts no longer show the R2 blockers. | None |

## Concrete fixes

Paths below are relative to `Sources/VideoPrompter/` at `0cf857d`.

### F1. Important: replace the obsolete first-use instructions

**Trigger:** choose Help on first launch, or restore the Getting Started Guide. `Library/LibraryStartView.swift:38` calls `store.showWelcomeScript()`. `App/WelcomeScript.swift:12–17` selects the Alpha `monitorMarkdown` and immediately instructs the reader to open **Tools > Microphone > Check sound**. Current `welcome-callout-dark.png` visibly contains this text. This is current product text, not a stale filename.

The same guide teaches **Tools > Text > Reading mode** at line 23, Tools-based text and editing controls at lines 27–29, and arrows beside **Mic level** and **Legend** at lines 33–35. Package E explicitly replaced Tools and removed the arrows. For a novice seeking help, these instructions lead to missing controls. The correct-looking first-launch cards do not compensate for a broken Help destination. This was missed in the previous wording pass.

**Exact change:** rewrite only the Alpha monitor guide, `App/WelcomeScript.swift:13–45`, around the actual routes:

- Sound: **Set up the shot > Adjust > Mic**, select the microphone, speak and watch the meter. For the explicit microphone test, **Settings > Microphone > Test microphone**.
- Reading mode, speed and appearance: **Reading settings**, or **Settings > Reading**. Text-size menu commands are **Make text bigger** and **Make text smaller**, not the old Tools labels.
- Camera: **Set up camera**, then **Camera** or **Adjust > Camera**; name the three Shot choices. Explain that a tile toggles an aid and right-click/long press opens its Adjust section. Use **Mic** and **Exposure key**.
- Clean: mouse movement reveals **Exit Clean · Esc**; **Esc** exits. Say entering Clean pauses reading. Do not imply the whole old toolbar returns on movement.
- Remove obsolete Tools-based editing directions; describe the library editor and its autosave, and only document a presenter-edit entry point if it is actually reachable in the Alpha.
- Use the current **Paste script**, **New script**, **Import file…** labels. Keep optional advanced capabilities in Settings only where the actual route is verified.

Do not rewrite stored user-edited scripts as a side effect. Verify the newly offered/restored guide in its existing offscreen fixture against the current controls. This resolves First launch and Wording to 9 without changing their visual design.

### F2. Important: make Settings > Advanced report and control orientation state

**Trigger:** open Settings > Camera and monitor > Advanced, choose Automatic, then reopen it or attempt to switch Automatic off. `Settings/SettingsView.swift:661–664` renders two bare buttons. Automatic only writes `true`; neither button reports a selection or an accessibility value. `g4-detail-Advanced-200-dark.png` and `r3-detail-Advanced-200-top-dark.png` visibly show the plain text actions. The user cannot tell here whether Automatic or Upside down is selected, and Automatic has no off action in this location.

The adjacent implementation is already correct: `Camera/CameraAdjustView.swift:57–64` uses a selected Upside down card and a two-way Automatic switch. Its full-size `g3-camera-200.png` and `r3-shot-advanced-200-dark.png` demonstrate the solution. The round 2 issue was fixed in Adjust but not in the duplicated Settings path.

**Exact change:** replace `SettingsView.swift:663–664` with the same stateful controls used in `CameraAdjustView`: Upside down selected only when `!automaticRotation && rotation == .half`, activation through `camera.setRotation(.half)`; Automatic as a trailing switch with a getter and setter for `camera.guides.automaticRotation`. Preserve the existing 44 pt target and sheet zoom. Prefer extracting only that small shared section if it avoids another divergent copy; no new settings system is needed.

Show Automatic on and off, and Upside down selected, in fresh offscreen Advanced captures. Check the accessible state in both locations. This resolves Camera and shot, Settings and Accessibility to 9. It is not a demand for a new orientation feature.

## Every round 2 finding rechecked

“Fixed” means current source supports the change and supplied visual evidence supports the appearance where applicable. It does not mean I ran a test. “Accepted at 9” identifies a previous proposed refinement that is not required for this user to ship.

### Sol's five Important findings and three optional notes

| R2 item | R3 result and evidence |
|---|---|
| 1. Protect both writing areas | **Fixed.** `LibraryView.swift:471–549` chooses compact mode by width and height, aligns the disclosures, hides metadata behind details and allows tip dismissal. `library-narrow-200-dark.png` shows text. `PresenterView.swift:74,104–110` suppresses the setup gutter for editing and measures the actual editor region; `review2-editing-200-dark.png` and `g1-editing-1000-200.png` show readable multiword lines and padded Save/Cancel. |
| 2. Effective monitor choices, including Advanced guides | **Fixed.** `CameraModel.swift:114–146,176–180` supplies shared exposure actions, clears bypass on explicit enabling/preset/grey-card actions and preserves normal off behaviour. Adjust and Settings use them. `CameraWindow.swift:162–178` routes preset/custom shapes through `chooseFrameMarker`. Settings summaries use effective values at `SettingsView.swift:589–604`. Existing grey-card restoration policy is retained. |
| 3. Settings sheet zoom and targets | **Fixed.** `SettingsView.swift:632–683` bounds size, scales the whole sheet, keeps its body scrollable and adds 44 pt buttons. `r3-detail-*-200-top/lower-dark.png` and `g4-detail-*-200-dark.png` cover the eight destinations. Numeric rows/presets adapt rather than squeeze. F2 concerns state, not enlargement. |
| 4. Mic identity | **Fixed in the actual presenter.** `MicMeter.swift:105–108` fixes vertical size/priority and supplies full-name help. `g1-setup-1000-200.png`, `g1-reading-1000-200.png` and `g1-editing-1000-200.png` retain ZOOM UAC-232. The deliberately narrow standalone hot fixture is not proof of a regression in the real allocation. |
| 5. AX values | **Fixed for every cited control.** `ExposureLegend.swift:484–518,570–572` parameterises zebra versus skin subjects; `PresenterView.swift:451` includes selected camera and shot; `AlphaGuideSections.swift:42–52` supplies checked/toggle/selected states. F2 is the previously separate Advanced path. |
| N1. Local wording/footer | **Fixed.** `ReadingInspectorView.swift:34–43` has a no-script hint, Open presenter and Narrow column. `ExposureLegend.swift:269,417` uses the same grey-band explanation. The wider help text is F1. |
| N2. Pink decoration | **Accepted at 9.** The skin instruction is plain and legible without a decorative swatch; tone portraits and the actual key already provide colour context. |
| N3. Automatic selection | **Partly fixed.** Adjust has a stateful switch; the remaining Settings path is F2. |

### Opus's round 2 requests, including their individual sub-points

| Area / R2 requests | R3 disposition |
|---|---|
| Reading and responsiveness 1–3: chip overlap, library header, mic name | **All fixed** in the actual layouts, as above. The 200% chip sits above the opening line in `g1-reading-1000-200.png`; the chosen large reading text has not been shrunk to fit. |
| Setup 1–2: source wrapping/placement, centred picture | **Fixed to ship quality.** `PresenterView.swift:121–132,184–198` overlays the key/status when space permits, uses separate left-aligned source blocks and attaches separators to preceding text. Narrow mode reserves an explicit gutter. `g1-setup-1600-100.png` and `g1-setup-1000-200.png` show no orphan separator or lost identity. A separate shot-only capsule would be polish. |
| Tiles 1–3: fixed row slots, short camera badge, inset check | **Fixed/accepted.** Slots are fixed at `PresenterView.swift:437–447`; camera badge is short and check inset. The precise suggested Right/Left abbreviations are not required when the full source status supplies direction. |
| Adjust 1–5: heading stack, Mic content/inset, trailing switches, zebra switch, crowded meter | **Fixed.** `AdjustPanel.swift:20–67` removes the extra title/close row, flattens Mic, adds live meter and Settings link and labels Microphone. Exposure and Mic switches trail; Zebras has its own switch. `PresenterView.swift:220` hides the stage meter under 1200 while Adjust is open. `g2-*` and `r2-adjust-Zebras-200.png` confirm the layout. |
| Camera 1: format lines | **Fixed.** `CameraAdjustView.swift:22–33,81–87`, `g3-camera-200.png` show connection, resolution and frame rate. |
| Camera 2: selection jump, icons and fill width | **Fixed.** Check overlays no longer reflow cards; orientation glyphs use rectangles/arrows and horizontal/vertical fallback is present at lines 52–55,95–112. |
| Camera 3: Automatic/Upside down selection | **Partly fixed; F2.** Correct in Adjust, still absent in Settings > Advanced. |
| Camera 4–5: Rename prominence and Shot heading | **Fixed.** Rename is secondary callout text with a large hit area; Shot is a standard heading. |
| Zebras 1–3: accent segment, squeezed number labels, preset top alignment | **Fixed.** `ExposureLegend.swift:439–478,495–519`; `g2-Zebras-200.png`, `g4-detail-Zebras-200-dark.png` and lower captures show the adaptive alternatives. |
| Key 1–2: footer agreement and stacked ranges | **Fixed.** `ExposureLegend.swift:253–270,407–417`; Custom and grey-card captures show matching text/data. |
| Key 3: replace the third key component | **Retired as a shipping requirement.** `ExposurePictureLegend` remains defined but has no source call sites. An unused definition is not a third visible key. The two used presentations share `legendBands`; slight swatch-size differences do not mislead. |
| Skin 1–3: Custom placeholder, grey-card competing target, duplicate finish controls | **Fixed.** `ExposureLegend.swift:555–561,570–577,598–609` enlarges the Custom glyph, suppresses Custom numbers while checking, dims the saved tone and shows only Finish when active. `g2-grey-card-200.png`, `f3-false-custom-200.png`. |
| Mic 1: real presenter name | **Fixed**, as above. |
| Mic 2: replace Settings' other meter | **Not literally implemented; accepted at 9.** Settings still uses `LiveInputLevelMeter`, but this is a labelled speech-input test with its own gain, not an unlabelled competing camera meter. `SettingsView.swift:418–424,482–528` shares zones, scale mapping and peak display. Exact visual unification is polish, not an unmet requirement for the specified presenter meter. |
| Guides 1: checkmark and selected trait | **Fixed.** Effective state drives cards and Dot/Cross; checkmark, selected and toggle semantics present at `AlphaGuideSections.swift:13–52`. |
| Guides 2: selected/Advanced evidence | **Supplied.** `g2-guides-advanced-100/200.png` shows Thirds and Centre mark checked, Cross selected and Advanced open; bypassed captures show no checked cards. These control captures do not certify live overlay geometry. |
| Settings 1: page titles | **Fixed.** Four titled pages in `alpha-settings-*` / `f4-settings-*`; lower scroll captures also supplied. |
| Settings 2: no-script presenter action and Narrow column | **Fixed.** No-script hint replaces disabled action; Open presenter and Narrow column at `ReadingInspectorView.swift:34–43`. Literal “Show in prompter” is not required; existing Open presenter terminology remains consistent. |
| Settings 3: black light-mode sidebar | **Fixed.** `f4-settings-App-200-light.png` uses a restrained pale selection. |
| Settings 4: microphone meter | **Accepted**, same decision as Mic 2. |
| Wording 1–4 | **Local pass substantially fixed.** Open presenter/Narrow column, Full screen (`VideoPrompterApp.swift:84`), renamed help and matching key footer landed. Lowercase “limit/thirds/centre mark” in explanatory subtitles is minor sentence-style polish, not a misleading renamed control. Stale guide instructions are F1. |
| Accessibility 1: truncated labels | **Fixed in actual allocation.** Adaptive number rows and full real presenter input name; arbitrary standalone narrow-fixture truncation is not scored as the shipped allocation. |
| Accessibility 2: Advanced 17 pt / 44 pt | **Guides fixed.** Camera's disclosure still uses native headline-scale/default disclosure presentation. Enlarging that secondary disclosure further is polish; F2 is about missing state, not its type size. |
| Accessibility 3: editor status | **Fixed.** Larger current status is legible in the actual enlarged editor capture; Save/Cancel also retain comfortable padding. |
| Visual consistency: selection treatments, switches, keys, meter | **Fixed to 9 with the F2 exception scoped to its affected settings controls.** Main cards have consistent checked borders; tabs/segments use accent fill; main switches trail. Remaining key/meter variations are justified by space/context. No broad replacement needed. |
| Library/editor 1–2: headers, indentation, button padding, status | **Fixed**, as Sol 1 and above. |

The round 2 “fixed” conclusions about first-launch choices, Clean, core reading transport and non-recording framing remain supported. I did not reclassify legacy fixture names as recording regressions.

## Verification boundary and handback

Source and sampled screenshot review: **PASS as an inspection activity**, with the two findings above at `0cf857d`. `zsh test.sh`, built-app checks, VoiceOver execution, keyboard interaction, camera/mic hardware and real permission paths: **NOT RUN**, explicitly excluded by the read-only/no-launch brief. Existing test source is evidence of intended coverage, not proof those tests passed.

Next measurable work is limited: update Alpha Help to the current workflow and reuse the correct stateful Advanced shot controls in Settings. Re-review those paths and their connected snapshots. The successful presenter, library and sheet fixes do not need another redesign. Questions skipped because the brief and output destination were complete.
