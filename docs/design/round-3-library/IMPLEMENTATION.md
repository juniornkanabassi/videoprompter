# Round 3 library implementation

Read all five round-3 council reports and the builder brief. Work remained
headless. No app was installed, launched visibly, pushed or released.

## What moved where

1. All Scripts, folders and Recently Deleted moved into one native scope picker.
   The document list owns the only selected-document highlight. Folder actions,
   including Open Recordings Folder, sit in a separate adjacent action menu.
2. Reading settings now owns reading and editor font/size controls. The editor's
   Text size action and Settings > Editor link to it. Interface size remains in
   General and has a direct link from Reading settings.
3. At 150–200% interface size, Reading settings opens in a wide sheet. It no
   longer squeezes an enlarged inspector beside the enlarged script list.
4. Creation actions stay leading in the toolbar; Present is last in the primary
   action group. The window title follows the document. Document metadata uses
   quieter type and the title wraps instead of clipping at enlarged sizes.

## Findings addressed

| Finding | Result |
| --- | --- |
| Competing sidebar selections and growth | Compact scope picker, one script selection, bounded two-line rows. The 100-script/200% snapshots show about eight complete rows rather than two. Snapshot assertion requires at least seven. |
| Enlargement | Wide Reading sheet at 150%+, full-value menu labels without duplicate readouts, controls keep the chosen scale. |
| Text contrast | Explicit foreground for presenter editor links, underlines retained; explicit inspector surfaces. Settings Editor's low-contrast footer replaced by primary explanatory text. Pixel measurements are in contrast.md. |
| Version comparison | Added/removed word counts and separately labelled changed text, bold and underlined. Show full versions restores full context. Diff computation is bounded for large replacements. |
| Paste wording | Paste Copied Text on start page, Add and File menus, and clipboard error. Welcome action explains immediate insertion and copying first. |
| Text size homes | Actual controls consolidated in Reading settings; other surfaces link there. Reading and editor sizes remain independent. |
| Welcome selection | Start page has no highlighted script. Clicking Welcome opens and selects its actual script. |
| Inspector hierarchy | Shared grouped rows, section headings, fewer duplicate labels, explicit dark/light surfaces. Disclosures have accessible buttons and expanded/collapsed values. |
| Folder deletion | Remove Folder, Keep Scripts plus a help explanation of All Scripts and Undo. Existing undo/membership behaviour retained. |
| Camera keyboard selection | ScrollViewReader reveals every highlighted row. Twelve-camera fixtures show camera 10 visible at 100/150/200%. Arrow-bound tests retain Return/Escape and preview handover behaviour. |
| Camera empty state | Distinguishes permission not requested, permission denied/restricted and no connected hardware. Offers Open Camera Privacy Settings and Refresh Cameras without requesting permission on hover. |
| Pinned passage | Defaults to a two-line-height cue, with Expand/Collapse and a visible scrolling hint; Back to script and Esc retained. |
| Icon finish | Legacy small sizes use an optical variant. Dark lighting is closer to approved artwork; tinted appearance reuses its exact contours. Native exports and resource compilation checked. |

## Ownership seams

Three narrow changes outside the assigned source directories were necessary to
finish the shared wording and remove duplicated controls:

- App/AppStore.swift: clipboard action comment/error wording only.
- App/VideoPrompterApp.swift: File menu Paste label only.
- Settings/SettingsView.swift: Editor section becomes a link to Reading.

The other builder should retain these changes while integrating their App and
Settings work. PresenterController.swift, Control and other Camera source files
were not edited. Shared snapshot and UI tests were updated for the new layout.

## Remaining limits

The modern Icon Composer catalogue uses one bitmap per appearance. Its 16/32-point
renders are verified but still derive from the large master; per-size optical
artwork is only in the legacy ICNS. A layered vector master is not delivered.

Top/bottom placement of pinned passages relative to a delivery marker needs
PresenterController integration and real-camera framing evidence. This patch
reduces the default obstruction but does not claim that geometry is solved.

Presenter transport/material contrast, hiding/focus behaviour, recording health,
voice setup, exposure and rotation belong to the other builder. Measurements here
are specific to the changed surfaces and the supplied snapshots, not whole-app
WCAG certification. Real cameras, live VoiceOver, active native toolbar material,
Increase Contrast and Reduce Transparency combinations were not exercised.

## Verification

Results below are from the final source state. Snapshot images,
manifest and contrast script are retained beside this report. Native icon exports
are under icons/.

| Final check | Result |
| --- | --- |
| `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-round3-snapshot-build zsh test.sh` | PASS: 472 tests, 9 opt-in/environment skips, zero failures, 148.8 seconds. Includes existing reading/selection, link recovery, camera preview handover and zoom tests plus five new round-3 tests. |
| `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-round3-library-build VIDEOPROMPTER_SNAPSHOTS=/private/tmp/vp-round3-snapshots-final zsh checks/check-snapshots.sh` | PASS: 92 light/dark PNGs, four snapshot test invocations, zero failures. Includes 100-script viewport assertion at 200%. All 54 changed-surface PNGs retained and visually inspected. |
| `python3 checks/check-grid.py` | PASS: five audited chrome files. |
| `python3 docs/design/round-3-library/measure-contrast.py docs/design/round-3-library/snapshots` | PASS: 20 sampled regions, minimum 6.05:1. Presenter-editor link measures 13.58:1 light and 20.38:1 dark. |
| Resource compilation and native icon export | PASS: Assets.car compiled; nine default/dark/tinted exports at 16/32/64 points inspected. Legacy ICNS preserved byte-for-byte in output. |
| `git diff --check` | PASS. |

The full test run was headless, using the existing no-window guard and disposable
libraries/defaults. The opt-in environment/hardware skips do not certify live
recording, speech downloads, camera orientation or microphone signal quality.
