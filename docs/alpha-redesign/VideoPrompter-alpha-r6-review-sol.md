# Video Prompter Alpha: Sol round 6 confirming review

**0 new findings. R1 is fixed. All 19 areas are now 9/10 or above within this confirming source and supplied-screenshot review.**

Reviewer: GPT-6.1 Sol. Reviewed HEAD `62feefb83b5184b4f350e1582e36cb0540f5a57b`, using `git diff a70ea1c 62feefb -- Sources` and the round 5 report as the baseline. Unaffected grades are carried forward, not represented as a fresh whole-product runtime audit.

| Area | /10 | Remaining issue / confirmation |
|---|---:|---|
| First launch | 9 | None found. Quiet actions remain distinct after separator removal; r14 start captures at 100/200%. |
| Library | 9 | None introduced; previous grade retained. |
| Editor | 9 | None found. `g1-editing-1000-200.png` retains readable text and Save/Cancel. |
| Set up the shot | 9 | R1 fixed. Compact key and source identity are separated; g1 setup matrix retains centred picture and meter. |
| Reading | 9 | None found. `g1-reading-1000-200.png` retains the separate exposure chip and reading surface. |
| Clean | 9.5 | None introduced. Setup column is still excluded; Clean capture remains clear. |
| Bar and tiles | 9 | None introduced. Two-line False colour label now fits at 200%. Existing minimum-fixture bar clipping is unchanged from round 5. |
| Adjust panel | 9 | None found. Five tabs and separate close control retained in g2 captures. |
| Zebras | 9 | None introduced. Shared numeric controls and exposure behaviour unchanged. |
| False colour and key | 9 | R1 fixed. Key label no longer paints behind camera identity; shared colour bands unchanged. |
| Skin tone and grey card | 9 | None found. Shared controls and grey-card state retained in `g2-grey-card-200.png`. |
| Mic meter | 9 | None found. Presenter meter retained; Settings removes the duplicate meter heading. |
| Camera and shot | 9 | None found. Identity wraps in the narrower gutter; Shot choices and Advanced remain available. |
| Guides | 9 | None found. Dot/Cross grouping remains clear; Advanced uses the existing Guide look controls. |
| Settings | 9 | None found in supplied states. Advanced top/lower captures retain Done and Save shoot setup; Exposure key toggle has a separate label. |
| Wording | 9 | None found. Guide look is specific; camera/exposure vocabulary remains consistent. |
| Accessibility | 9 | None introduced in source/render evidence. Labels, selected traits and 44 pt minimum targets retained. Live VoiceOver not exercised. |
| Visual consistency | 9 | None found. Shared Guide look controls and grouped Dot/Cross match existing patterns. |
| Responsiveness | 9 | R1 fixed. Scrolling prevents vertical compression; landscape gutter guard preserves picture space in the supplied g1 captures. |

## R1 confirmation

`Sources/VideoPrompter/Presenter/PresenterView.swift:83-100` now wraps the setup column in a vertical ScrollView, preserves intrinsic vertical size for the exposure key and source status, and constrains the outer scroll view to the stage. This implements the round 5 fix without shrinking the camera-name text.

Direct comparison of `/private/tmp/VideoPrompter-alpha-r5/r13-presenter-key-200-dark.png` and `/private/tmp/VideoPrompter-alpha-r6/r13-presenter-key-200-dark.png` confirms that Exposure key is now fully above the camera identity at 720 × 520 and 200%. The light counterpart agrees. Source information may continue below this very short stage and is now scrollable rather than drawn into the key. Pointer/keyboard scrolling itself was not run.

The landscape guard at `PresenterView.swift:80` limits each setup gutter while retaining symmetric space around the picture. `g1-landscape-1000-100.png`, `g1-landscape-1000-200.png` and `g1-landscape-1600-100.png` show no new overlap or off-centre picture. All six `g1-setup-{1000,1600}-{100,150,200}.png` captures retain separated key/source information.

No remaining fix is requested for this package.

## Evidence and limits

Inspected all four changed production files, connected UIZoom, source-status, Guide look and saved-setup code, plus the added g1 frame assertions. Visually sampled 33 round 6 images covering exact R1 dark/light, all six g1 setup states, three landscape states, reading/editing, Settings Advanced top/lower, Guides, camera/shot, exposure controls, microphone, first launch and Clean. This is a targeted regression sample, not every PNG. The supplied captures have no embedded commit hash; they are accepted as the round 6 evidence supplied for this HEAD.

- Source and supplied-render review: **PASS**, at `62feefb83b5184b4f350e1582e36cb0540f5a57b`.
- `git diff --check a70ea1c 62feefb`: **PASS**.
- Added minimum-size non-overlap and landscape-width assertions: inspected, **NOT RUN**.
- Build, XCTest/snapshot regeneration, live camera/microphone, native window chrome, VoiceOver and pointer/keyboard operation: **NOT RUN**, as instructed. Populated saved-setup interaction was not independently exercised.
- Repository was clean before and after review. No source edits, builds, commits or app launches. Only this requested report and temporary contact sheets were written.

**Verdict: pass the round 6 confirming review at the exact HEAD above. All 19 grades meet the requested threshold; no new regression was established.**
