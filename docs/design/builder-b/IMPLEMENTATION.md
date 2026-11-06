# Builder B implementation

Implemented against the 6 November 2026 DESIGN-SPEC.md, starting at 64f5e6d. Builder A's enabling commits 5fb00be and f40abc1 were cherry-picked as a7ad2b2 and f493e15. No Builder A source was independently edited.

## What moved

- Removed the Library's Reading inspector and its enlarged sheet route. ReadingSettingsPage is a grouped form with Following, Reading text, Layout, Reading guide, Colours, and Rotation and stage directions.
- Added Recordings before Camera Only and Present. Removed the recordings item from Folder actions. Present points to Settings for reading preferences.
- The editor has an editable title at the title token, a single save/word-count metadata line, and Text size opening EditorTextControls. This same component is ready for A's General page.
- The start page puts Camera Only directly after the paste group, uses the specified next-step sentence, and adapts the alternative import/write actions to narrow enlarged layouts.
- Move to Folder uses No Folder. Both deletion entry points pass the environment undo manager to A's API.
- Reading choices retain a selected value and selected-item state at all zooms. The colours section checks composited contrast against a white picture and lets the user choose the lowest passing darkness. Impossible colour/opacity combinations keep the warning and explain how to change them.
- The camera picker locks during preparation, waiting for frames, recording and saving; its accessible help explains the lock. It closes an already-open picker when recording starts, preserves the full device name as help/value, and shows Choose camera when empty.
- ScriptTextView supports overVideo, defaults it to false, and applies a 60% black, radius-6 halo only when true. Text content, cue handling and seeking are unchanged.
- Relink comparison headings explicitly name both comparison directions. The design system now records the specification's principles, allowed quick controls, vocabulary and visual tokens instead of historical round notes.
- The Library displays AppStore.libraryNotice above its current content, ready for A's Google Docs progress and result notices.

## Integration contracts

- Delete and snapshot signatures now come from A's enabling commits. The temporary deletion implementation and duplicate snapshot adapter were removed.
- Remove Library/BuilderBCompatibility.swift when A supplies the published AppStore.libraryNotice. Its current getter returns nil and is explicitly marked as an integration placeholder.
- ReadingInspectorView aliases ReadingSettingsPage. The pre-existing InspectorView alias remains in A's Settings file. The old optional onVoiceSettings initialiser argument and ReadingSettingsSheet fixture wrapper are retained only because A's starting snapshot/setup callers still reference them. Remove these once those callers switch; the Library cannot open the sheet.
- A must use EditorTextControls(store:) in General and pass overVideo: camera.presentsWithVideo && !cleanView from PresenterScriptView.
- A's enabling deletion commit adds only the argument. Its actual batch Undo implementation is still required. The end-to-end deletion test reports an explicit skip until that implementation exists; it then asserts restoration of both scripts. The separate Delete-key routing test always runs.

## Acceptance evidence

Final command results and criterion outcomes are recorded below before commit. Offscreen snapshots are retained beside this report. Native active-window toolbar/glass appearance, real camera recording and spoken VoiceOver are not established by these tests.

| Criterion | Result | Evidence |
|---|---|---|
| B1 | PASS | Library 100/200 light and dark snapshots have no inspector or reading sheet; the exact toolbar action subtree exposes Recordings, Camera Only, Present in left-to-right order at both sizes. Native window toolbar glass is outside offscreen capture. |
| B2 | PASS | ReadingAccessibilityTests verifies selected names at 100/150/200, selected popup menu item state, and the selected trait on the same option view used by the enlarged inline Picker. |
| B3 | PASS | Offscreen ReadingSettingsPage tree excludes Presenter view, Editor font, Editor text size, Interface size and Voice/Microphone navigation. |
| B4 | PASS | White-on-black at 25% fails 3:1; 50% passes. Tests activate Make Readable, prove the exact first passing threshold, and cover combinations that darkness alone cannot fix. |
| B5 | PASS | Fixture tests cover preparing, waitingForFrames, recording, saving and idle. Locked picker is disabled and exposes the exact required help. |
| B6 | PASS | The 200% first-launch Camera Only frame fits in the first 800-point viewport. Light and dark first-launch snapshots retained. |
| B7 | FAIL pending A | The Delete-key and context paths pass undoManager. The end-to-end test is explicitly skipped because A's enabling commit changes the signature only and does not yet register Undo. It will check both restored scripts once A's real implementation lands. |
| B8 | PASS | Automated scan of Library, Import and Resources finds none of the three forbidden phrases. |
| B9 | PASS | All 18 required light/dark PNGs generated and reviewed, plus first-launch and relink evidence. In total, 62 affected final PNGs reviewed through contact sheets and the enlarged Reading page inspected at full size. 22 key PNGs retained in snapshots/. |
| B10 | PASS with explicit integration skip | Final `zsh test.sh`: 491 tests, 11 skipped, zero failures. Final `zsh checks/check-snapshots.sh`: all three tests pass per appearance and the grid check passes. One skip is B7; other skips are opt-in platform/hardware tests. |

## Ownership exceptions authorised during implementation

- SimpleInterfaceTests.swift: updated the two obsolete tests only. The shorter next-step sentence retains bounds/readability checks with a >24-point height threshold. Reading checks sections without opening removed disclosures. General's shared EditorTextControls is checked directly until A's new General page lands, then the same test checks the real page.
- UIZoomTests.swift: changed the minimum visible Library control count from six to three, matching removal of the inspector. Existing bounds, hit testing, editor size and sidebar scaling assertions are unchanged.

No release was built, installed, pushed or published. No app window was shown and no audio was played.

## Final verification

- Full suite: `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-builder-b-tests zsh test.sh`, 491 tests, 11 skipped, 0 failures (161.1 seconds).
- Snapshots: `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-builder-b-tests VIDEOPROMPTER_SNAPSHOTS=/private/tmp/vp-builder-b-snapshots-final zsh checks/check-snapshots.sh`, three tests passed in each appearance, grid passed.
- Targeted Library and accessibility tests: 13 tests, 1 explicit B7 integration skip, 0 failures.
- `git diff --check` and the Impeccable source detector passed (no findings).
- All 62 affected final PNGs reviewed. The 18 required snapshots plus first-launch and relink 200% pairs are retained here.
- Before integration acceptance, remove the temporary B7 missing-Undo skip once A's implementation lands and rerun it. Remove `BuilderBCompatibility.swift` when `libraryNotice` lands. The full suite being green does not establish B7 until that test runs without skipping.

The first full run exposed obsolete Reading/onboarding/control-count assertions. Only the two expressly authorised test files were updated. An intermediate rerun was stopped when the one-line control-count edit had not matched; the final run above includes the corrected source and passed.
