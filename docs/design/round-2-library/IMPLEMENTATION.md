# Round 2 library, first launch and reading setup

Read all five supplied round-2 reports. This pass implements the library/editor/inspector/import/reading-text findings. Presenter transport, recording behaviour, App settings and iPad Remote remain with the other builder.

## What moved

- First launch opens a task-based start screen. Paste a Script is the main action; importing/writing, Camera Only and the practice script are available without opening a menu. The appearance inspector is hidden on the start screen. The original practice script remains intact and editable.
- Reading settings now have one shared implementation beside the script and wherever `InspectorView` was used. Presenter view, reading mode and text size are prominent. Spacing/alignment, guide, colours/backdrop, and rotation/cues have their own disclosures. Every slider has a visible value and an explicit accessible value with units. At 150–200%, the selected popup value also wraps as a separate readout.
- The editor's header contains the title, save status and Editor text size. Tags and routine storage information moved into Script details. A broken-file warning stays visible with its recovery button.
- Library scopes stay above the separately scrolling script list. Only folders scroll within the scope area; All Scripts, Recently Deleted and Open Recordings Folder remain available. Recently Deleted is a destination. Script selection is initialised from the store and shown with a background and heavier title.

## Findings addressed

| Reports / finding | Implementation and evidence |
| --- | --- |
| First-time 1, 5; visual 2, 4 | First-launch task screen; fixed the NSTextBlock's missing width (100% of available text width); primary-colour callout title; explicit Image foregrounds for sidebar symbols; initial document selection. Fresh-library and welcome-note snapshots cover both appearances. |
| Visual 3; heuristics 4; first-time 6, 8 | Shared `ReadingInspectorView`, progressively disclosed detail, full selected values at enlarged sizes, adjacent editor-size control, consistent slider labels/values. |
| Heuristics 3 | Reconnect preview shows both complete scrollable texts and modification dates before the choice. A changed file or in-app script requires a new comparison. Empty UTF-8 files are supported. Keep Both remains available. After replacement the completion screen offers Show Preserved Versions. Existing core relink tests retain backup-before-replacement coverage. |
| Heuristics 8 | Stable scopes, independent script list, separate Recently Deleted destination, 100-script/12-folder fixtures at 100% and 200%. |
| Accessibility 7 | Hidden cues are removed from the actual NSTextView string. Source offsets are remapped so selection and word seeking still target the correct spoken words. Shown cues retain their separate treatment. Mixed English/French regression coverage verifies both modes. |
| Accessibility contrast; first-time instruction readability | High-contrast primary text in the start screen, recovery and inspector. The measured regions pass the 4.5:1 normal-text threshold. Read-word opacity rises from 0.38 to 0.5 in both presenter and in-place editor. Custom user text colours/opacity are still user choices. |
| First-time 7 | Open Recordings Folder is always available in the library, including after restarting. Recording filenames remain with the recording builder. |
| Visual 6; heuristics 9 | Reading settings, Reading text size, Editor text size, Script details; Google Docs describes shared-link importing without “This build”. |
| Accessibility 3 within ownership | Camera picker names wrap; at 150–200% its device list and preview stack vertically. A no-preview switch keeps snapshot fixtures from acquiring hardware. Camera window and iPad Remote scaling remain with the other builder. |
| Visual 7 | Authored Default/Dark/Tinted Icon Composer appearances preserve the approved composition. Native `ictool` exports were inspected at 16, 32 and 64 points. Resource compilation produces `Assets.car` and a fallback ICNS; the build now consumes them. |

## Ownership exceptions

- `Settings/SettingsView.swift`: removed only the old inspector implementation and replaced it with `typealias InspectorView = ReadingInspectorView`. Other Settings code is unchanged. This prevents two independently maintained reading inspectors. Integrators should retain the alias while merging the other builder's Settings work.
- `build.sh`: replaced only the old ICNS copy line with `Resources/AppIcon/compile-icon.sh`. The new source is referenced by `CFBundleIconName` and `CFBundleIconFile`. No release was built, installed, pushed or published.
- Existing mixed test files were updated only where they exercised the changed inspector, start screen, hidden-cue representation or read-word opacity.

## Validation

The full suite passed with 458 tests, 9 explicitly skipped, and zero failures. The final focused interface check also passed all 8 tests. The full run took 150.5 seconds; its opt-in external/hardware checks account for the skips. Commands use dedicated scratch directories and the existing no-windows guard. Snapshot tests also redirect their iCloud root to a nonexistent disposable path; the former harness used the global iCloud setting despite an isolated library, which could contaminate captures with real script names.

- `zsh checks/check-snapshots.sh` (final images at `/private/tmp/vp-library-r2-final-images`, representative files retained in `snapshots/`): 62 offscreen images, including first launch, 100 scripts, version comparison and camera picker at enlarged sizes. All inspected in both appearances, with full-size checks of changed primary views.
- `python3 docs/design/round-2-library/measure-contrast.py <snapshot directory>`: ten sampled text/background pairs pass, minimum 11.01:1. See `contrast.md`. Uses repeated solid glyph colours and nearby composited backgrounds; this is sampled evidence, not a complete AA certification.
- Final test log: `/private/tmp/vp-library-r2-final-pass.log`; final focused log: `/private/tmp/vp-library-r2-final-focused.log`; snapshot log: `/private/tmp/vp-library-r2-final-captures.log`.
- `zsh Resources/AppIcon/compile-icon.sh <disposable directory>`: native icon resource compilation, no app launch.
- `ictool` exports: three appearances at 16, 32 and 64 points. See `icons/`.
- `python3 checks/check-grid.py` and `git diff --check`.

## Remaining work and limits

The other builder owns presenter transport layout, Camera Only's reading chrome, keyboard dispatch, Reduce Transparency, recording readiness/microphones/close behaviour, recording labels and save-error text, Settings pages and preset feedback, full Camera-window/iPad Remote enlargement, and Google Docs replacement confirmation in App. This branch does not claim those findings are fixed.

Active/inactive native titlebar glass, VoiceOver speech/focus traversal, hardware camera/audio recording, live iPad operation and installed Dock appearance were not tested. Offscreen snapshots omit native toolbar chrome. Icon layers are editable appearance bitmaps, not separately reconstructed microphone/page geometry. The 200% popup itself may abbreviate a long value; the always-visible wrapped value above it supplies the full selection.
