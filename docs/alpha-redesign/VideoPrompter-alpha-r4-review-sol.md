# Video Prompter Alpha: Sol Round 4 review

**0 Important findings. 3 optional polish notes. All 19 areas reach 9/10 or above.** Both Important findings from Sol Round 3 are fixed. The remaining Opus Round 3 requests are either fixed or explicitly accepted as non-blocking below. No further redesign is needed for design approval at this revision.

Reviewer: GPT-6.1 Sol, 9 November 2026. Branch `claude/alpha-hud`, HEAD `2e733083fb35e0c12e497ac069e57a332710cceb`. Read-only review. No source edits, builds, tests, commits, application launches or live interaction. This report and temporary review contact sheets are the only writes.

## Basis and limits

The authority is `docs/alpha-redesign/SPEC.md`, approved mockups 01–09, and the stated user: one dyslexic creator, reading scripts and checking a camera reference picture, without recording. I compared current source with Round 3 (`0cf857d`), read both Round 3 reports and their earlier-finding ledgers, and consulted the Round 1/2 reports for context.

I inspected selected fresh captures in `/private/tmp/VideoPrompter-alpha-r4/`, including the complete g1, g2 and f4-settings sets, g3 camera, selected g4/r3 detail sheets, all three h2 Advanced states at 100% plus an enlarged light state, first launch, narrow library, Help, Clean and meter states. Contact sheets were followed by full-size checks of disputed details. This is a sample of the supplied 1,041 PNGs, not a claim to have inspected every file. Old-looking filename prefixes inside this directory do not make a fresh capture historical evidence.

Native yellow placeholders are excluded from scoring. The fixture picture proves layout, not live exposure accuracy. Blank no-device captures do not prove camera failure. Content-only captures do not establish native window chrome. Tests and source support intended behaviour; I did not execute them. In particular, no claim here verifies physical camera orientation, microphone calibration, VoiceOver operation, pointer hit testing or keyboard timing.

A 9 means usable, clear and ready to ship from a product-design perspective, with polish remaining. It does not mean exact pixel identity with a mockup. Safe scrolling in enlarged settings, a compact key when space is short and labelled controls moved into Adjust are acceptable. Previously accepted polish is not promoted into a blocker merely to prolong the loop.

## The 19 grades

| Area | /10 | One-line reason and Round 3 status |
|---|---:|---|
| First launch | 9 | Two understandable entry paths survive enlargement; Help now describes the actual Alpha workflow, closing Sol F1. |
| Library | 9 | Narrow 200% retains readable script text, a compact header and clear save status; previous fixes remain intact. |
| Editor | 9 | Enlarged multiword lines and labelled Save/Cancel preserve the writing task; no renewed one-letter column. |
| Set up the shot | 9 | Source, format and shot remain readable beside the fitted picture; the key no longer touches the image edge, closing Opus's overlap finding. |
| Reading | 9 | The script remains primary, Pause is dominant and the compact key stays above the opening line; previous overlap fix retained. |
| Clean | 9.5 | Picture-only composition and the source's transient Exit Clean control preserve the intended distraction-free state. |
| Bar and tiles | 9 | Stable icon/name slots and checked states remain clear at 100–200%; wrapping and moving two aids into Adjust preserve labels. |
| Adjust panel | 9 | Tabs now have top and side breathing space, Close stays visible and the duplicate Mic heading is gone. |
| Zebras | 9 | Range/Limit, compact presets, readable values and a plain stripe-range explanation now form one clear task. |
| False colour and key | 9 | Picture/key data agree, named ranges remain legible and the active presentation uses the shared band data. |
| Skin tone and grey card | 9 | Five named portraits plus Custom, a dimmed saved tone during checking and the correct Finish instruction close the remaining wording defect. |
| Mic meter | 9 | Named input, warning zones, peak/CLIP states and no-signal feedback remain clear; Settings now uses the same meter component. |
| Camera and shot | 9 | Source identity and three shot cards are legible; both Advanced destinations now expose actual Automatic/Upside down state, closing Sol F2. |
| Guides | 9 | Primary choices retain checked states, hidden guides retain a dimmed stored Dot/Cross choice, and Adjust's Advanced controls now show named values. |
| Settings | 9 | Four consistent page titles, larger form actions and shared detail controls close the practical hierarchy/state gaps; column alignment is polish. |
| Wording | 9 | Help uses current routes and labels; Upside down, Range/Limit and Finish grey card check now agree with the controls. |
| Accessibility | 9 | Main controls retain names, effective state and enlarged layouts; Advanced shot state is now exposed, with one secondary target refinement left as polish. |
| Visual consistency | 9 | Shared meter, accent selection, calmer tabs and page headings now read as one product; small native-form differences are non-blocking. |
| Responsiveness | 9 | Sampled setup, reading, editor, library and settings work at 100–200% without lost primary labels or key/picture overlap. |

No area is below 9, so there is no required fix package.

## Sol Round 3 findings rechecked

| Finding | Round 4 result and evidence |
|---|---|
| F1: obsolete first-use Help | **Fixed.** `Sources/VideoPrompter/App/WelcomeScript.swift:13–45` now teaches Open presenter, Start reading, Pause, Reading settings, Adjust > Mic, current camera/aid controls, Clean/Escape and current script actions. `welcome-callout-dark.png` visibly contains the new text. The Alpha guide no longer teaches Tools, settings arrows, Mic level or Legend. The separate recording guide is not Alpha-visible and was not falsely flagged. |
| F1: preserve user-edited scripts | **No bulk rewrite introduced in the reviewed diff.** The change replaces the guide template. It does not add migration code to rewrite users' libraries. |
| F2: stateless Settings > Advanced rotation actions | **Fixed.** `Settings/SettingsView.swift:670–674` hosts `CameraAdjustView(... advancedOnly: true)`; `Camera/CameraAdjustView.swift:74–82,104–121` supplies a two-way Automatic switch and an Upside down card selected only for manual half-turn. The card also reports Selected/Not selected. |
| F2: demonstrate all states | **Supplied.** `h2-advanced-automatic-100-dark.png`, `h2-advanced-manual-100-dark.png`, `h2-advanced-upside-down-100-dark.png` distinguish the three states. `h2-advanced-upside-down-200-light.png` retains the selected border and check. The snapshot test creates these states explicitly; this is rendering evidence, not a live interaction test. |

The earlier Sol fixes audited again through Round 3 remain intact in the sampled current evidence: compact library/editor, effective aid actions, bounded scaled detail sheets, full presenter microphone name, correct zebra/skin accessibility subjects and checked guide state. The optional pink decoration remains optional. The formerly partial Automatic fix now covers Settings as well as Adjust.

## Opus Round 3 findings rechecked

Rows cover every requested fix in its final “Fixes to reach 9” sections, plus the remaining items explicitly carried in its Round 2 status ledger.

| Round 3 request | Round 4 disposition |
|---|---|
| Wording 1: rewrite Welcome script | **Fixed**, as Sol F1 above. Current instructions use actual routes, plain words and short sections. |
| Wording 2: replace “Inverted” | **Fixed.** `Presenter/PresenterView.swift:195` now says “Upside down”. |
| Wording 3 / Skin 1: active grey-card instruction | **Fixed.** `Presenter/ExposureLegend.swift:613` changes the active instruction to “Choose Finish grey card check…”. `g2-grey-card-200.png` has a single Finish action and no contradictory switch instruction. |
| Wording 4: Range/Limit and guide-name capitalisation | **Fixed.** `Settings/SettingsView.swift:597–599` uses Range or Limit, Thirds and Centre mark. |
| Wording 5: remove stale unused PresenterHelp | **Fixed.** Removed from `Settings/ShootSetup.swift`; no remaining definition there. |
| Settings 1: title placement and one content column | **Partly fixed; accepted at 9.** All titles now sit outside their forms at the leading page inset. Grouped forms remain narrower/centred while Camera overview spans its page. The f4-settings set shows a clear heading and legible controls, not a broken reading path. See N2. |
| Settings 2 / Accessibility 1: readable forms and large buttons | **Fixed for the named form actions.** Forms get 15 pt text and large control size; `SettingsFormButtonStyle` gives actions a 44 pt minimum. `f4-settings-Microphone-100-dark.png` shows Test microphone, gain actions and System settings as substantial controls. |
| Settings 3 / Mic 1: shared Settings meter | **Fixed.** `Settings/SettingsView.swift:415–416` now hosts `MicMeterView`; f4 Microphone captures show its zones, input name and no-signal state. |
| Settings 4: repeated detail titles | **Fixed for Zebras, False colour and Guides.** The redundant outer header is suppressed for those destinations at `SettingsView.swift:656–658`. `g4-detail-Zebras-200-dark.png` has a single Zebras heading with the switch. |
| Settings 5: visible numeric button squares in sheets | **Not changed; accepted at 9.** Shared numeric buttons still have explicit 48 pt content frames and descriptive accessibility labels. Sheet rendering remains plainer than Adjust, but minus/value/plus are understandable and well separated. See N3. |
| Settings 6: wording | **Fixed**, as Wording 4 above. |
| Setup 1: key overlaps picture at 1000 × 100% | **Fixed by layout separation.** `PresenterView.swift:73–97` always allocates a separate setup status/key column. `g1-setup-1000-100.png` uses the compact key button; `g1-setup-1600-100.png` fits the card beside the image. No face overlap in either. The suggested geometry formula was not necessary. |
| Setup 2: separate shot and remove orphan separators | **Fixed.** `PresenterView.swift:171–184` has separate source, format and shot pills, with component lines rather than trailing separators. `g1-setup-1000-200.png` shows complete identity and “Turned right for vertical”. |
| Setup 3: keep pills off image edge | **Fixed.** The explicit left column keeps all pills beside the image. This is the review's permitted alternative to top-centre placement. |
| Adjust 1: top padding | **Fixed.** `AdjustPanel.swift:38` adds top padding; all g2 panels show clear space above the tabs. |
| Adjust 2: tab padding and leading alignment | **Fixed.** Horizontal `Space.md`, leading wrap layout and panel inset now align the tabs with the body. The second-row Mic tab is an intentional wrap, not lost content. |
| Adjust 3: duplicate MIC heading | **Fixed.** `AdjustPanel.swift:65` supplies `showsHeading: false` to the shared meter. |
| Guides 1: blank Dot/Cross selection when hidden | **Fixed.** `AlphaGuideSections.swift:28–33` uses stored state and dims it when guides are hidden. `g2-guides-bypassed-200.png` retains a dim Cross selection. |
| Guides 2: matching segment track and caption | **Partly fixed; accepted at 9.** Caption is now Centre mark style. The segment still lacks Range/Limit's surrounding track, but the selected fill and two labels are unambiguous. No extra redesign required. |
| Guides 3: Advanced form hierarchy and value readout | **Fixed in Adjust.** `CameraWindow.swift:193–227` supplies leading named rows, percentage values and a grouped card via `alphaStyle: true`. `g2-guides-advanced-200.png` shows Colour, Guide visibility 80% and Frame shape. Settings' general Advanced sheet retains native form styling, without losing its labels. |
| Accessibility 2: Camera Advanced disclosure at 17 pt / 44 pt | **Partly fixed; accepted as secondary-control polish, consistent with Sol Round 3.** It now explicitly uses headline typography but has no explicit 44 pt label frame. Do not call this literal implementation complete. See N1. |
| Visual consistency 1–3: Settings, shared meter, disclosure and segments | **Fixed to ship quality**, with the partial title-column/disclosure/segment refinements explicitly identified above. |
| Visual consistency 4: delete unused ExposurePictureLegend and fixtures | **Not done; no visible defect.** Definition remains at `ExposureLegend.swift:310`; no production call site was found. This is cleanup, not a competing on-screen key or a condition for design approval. |
| Polish: inset False colour tile title | **Not done; accepted at 9.** Text remains close to the edges in `g1-setup-1000-200.png`, but is complete, readable and inside the tile. |
| Polish: trim zebra preset empty space | **Fixed.** The fixed minimum card height was removed; current `g2-Zebras-200.png` has compact, balanced preset cards. |
| Polish: hide no-script hint row entirely | **Not done; accepted.** A plain “Choose a script first” hint is useful and does not promise a working disabled action. |

Opus's Round 3 passed areas remain supported: library, editor, reading, Clean, main tile alignment, zebra state, shared colour ranges and camera identity. Nothing in this review revives a closed Round 1/2 defect merely because an old fixture filename still exists.

## Optional polish, not a further approval gate

**N1. Finish the Camera Advanced target treatment.** At `Sources/VideoPrompter/Camera/CameraAdjustView.swift:62`, use the same explicit label treatment as Guides: `.font(.system(size: 17, weight: .semibold)).frame(minHeight: AlphaStyle.minTarget)`. The current secondary disclosure is legible and expandable; this completes the requested target consistency. Runtime hit testing was not performed, so I am not claiming a measured missed-click defect.

**N2. Align Settings content columns.** In `Settings/SettingsView.swift:110–123,251–255`, give the grouped form content the same leading content-column alignment as its title, rather than the centred inset visible in `f4-settings-Microphone-100-dark.png` and the Reading/App counterparts. Keep the existing scrolling and text sizes. This reduces empty lateral space; it does not unlock a currently blocked task.

**N3. Match numeric button backgrounds between Adjust and detail sheets.** At `Presenter/ExposureLegend.swift:505–514`, give both 48 pt button labels the same explicit rounded background and plain button style instead of inheriting each host's style. Compare `g2-Zebras-200.png` with `g4-detail-Zebras-200-dark.png`. Retain existing labels, bounds and action logic. This is visual affordance polish, not evidence of a broken numeric control.

## Verification and verdict

- Source/diff and supplied screenshot inspection: **PASS as review activity** at `2e733083fb35e0c12e497ac069e57a332710cceb`.
- `zsh test.sh`, build/package checks, live camera/mic, VoiceOver and keyboard/pointer interaction: **NOT RUN**, as required by the read-only/no-build/no-launch brief.
- No hardware, persistence or release approval is implied. No external facts or new feature requirements were introduced.

**Verdict: design approval for this exact revision.** All 19 areas meet the requested 9/10 threshold; the three notes above can remain polish. Preserve the current reading surface and camera layout rather than starting another broad visual pass.
