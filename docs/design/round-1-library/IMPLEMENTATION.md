# Round 1 implementation: library and reading accessibility

Branch `t3/prompter-library-accessibility`, 6 November 2026. Read the five council reports and builder brief. No release, install, push or merge.

## Implemented findings

- **Accessibility 1; visual 1 and 7:** the sidebar resolves semantic ink against its actual light/dark scheme. The inspector uses a scrollable stack with consistent label/value rows; its native AppKit popups explicitly inherit that scheme. This removes the white cards and invisible popup values in the composed dark inspector. Small value readouts and import instructions retain full text contrast. All presenter controls remain available.
- **UX 7; visual 4:** the current folder has a persistent selected background and selected accessibility trait. The script section names the folder being shown, while script multiselection remains independent.
- **First-time 8; visual 8:** document identity uses a quieter heading; empty tags collapse, existing tags remain visible. Title, tags and body all autosave. A serial metadata queue cancels stale debounces, waits for body persistence, and displays Saving, Saved or a recoverable failure. The header offers Retry Save on failure. User-authored Markdown headings are preserved.
- **First-time 4:** Camera Only remains a labelled library toolbar action even when the welcome script or another script is selected.
- **UX linked-file finding:** the import preview explicitly explains the two-way Markdown link before confirmation. The linked-file row shows a short filename, with the full path and sync explanation in help.
- **UX 9; accessibility 5:** Google import names its URL field and keeps a stable accessible import action while busy. Instructions depend on whether sign-in exists; private files can be downloaded and imported without making them public. Errors have a heading and retry action. Import completion/errors, saved edits and keyboard camera selection announce status without moving focus.
- **Accessibility 2 and 6:** the reference monitor exposes the entire passage as its accessibility value, uses the saved reading size, and scrolls long selections rather than shrinking or truncating them. Its header follows interface zoom and the return action has readable contrast.
- **Visual 3; accessibility 4:** the reading guide is two margin ticks, leaving letters unobscured without changing the reading anchor. The presenter text view supports Option-Command-Return, a Read from Selection context-menu item and a named accessibility action, using the same character-to-word seek callback as clicking.
- **Accessibility 3:** the Google import window receives the stored interface zoom. The library zoom test validates current visible controls instead of SwiftUI object identities that change during reflow. Auto-hidden overlay scrollers are excluded from permanent-control checks because they intentionally pass clicks through; the editor hit grid still covers that area. Native popup layout has a bounded fitting height and honours the proposed width.
- **Camera picker:** retain previews and arrow/Return/Escape selection, restore native focus visibility, announce keyboard-preview/selection changes, initialise the preview to the current device, and use explicit light ink when the picker sits on the dark presenter surface.
- **Visual 5:** preserve the approved microphone/page art, recover a border-connected exterior alpha mask, regenerate all ten ICNS sizes and verify transparent corners. Inspected 16, 32, 64 and 128 pixels against both backgrounds. `Resources/AppIcon/package-icon.swift` records the deterministic export; two generated cutouts with exterior speckles were rejected.

## Necessary cross-owner edits

These are integration edits, not broader ownership changes:

- `App/AppStore.swift`: central empty-clipboard feedback so File and Add behave identically.
- `App/GoogleDocsCommands.swift`: pass saved zoom into the owned Google import view.
- `Settings/SettingsView.swift`: the existing InspectorView was physically defined here; changes are limited to this inspector and one shared readout foreground.
- `Presenter/PresenterController.swift`: pass reading size and UI zoom into the reference caption, identify the camera picker's dark surface, and replace the guide drawing with margin ticks.
- `Tests/PrompterCoreTests/PresenterControllerTests.swift`: sample a margin tick and assert the middle remains transparent, instead of expecting a strike-through line.

## Guarded validation

The owner reported visible test windows during the earlier run. All runners were stopped/absent before cherry-picking `a28a30c` as `a19f5c7`. The TestOffscreen target and its application guard are retained without changes. No further tests ran before that commit was installed. Subsequent checks run one at a time.

- **PASS:** TestOffscreenTests, verifies forced zero opacity, click-through test windows and blocked application activation.
- **PASS:** all eight UIZoomTests under TestOffscreen, including `testTheLibraryWindowScalesEveryPaneAndKeepsEveryControlClickable`.
- **PASS:** offscreen light/dark snapshot runs and grid check before the guard; a guarded final run is recorded below.
- **PASS:** semantic popup selection/appearance, rapid title/tags/body save ordering and keyboard/accessibility seeking regression tests in the broader suite.
- **PASS:** thirteen solid-pixel contrast samples, checked by `check-contrast.py`; see `contrast-results.json`. Small text minimum is 4.5:1. Sidebar titles are 14.50:1 light and 12.69:1 dark; inspector labels 14.94:1 and 12.43:1; popup text 13.02:1 and 10.19:1; the reference passage 17.58:1 and 20.62:1; the enabled light-mode presenter camera picker is 9.29:1. Disabled controls and antialiased edge pixels are excluded.
- **PASS:** PNG/ICNS alpha checks for all ten representations, plus light/dark visual inspection at 16/32/64/128 pixels.

**PASS:** full guarded `zsh test.sh`, 449 tests, eight opt-in skips, zero failures (185 seconds). Log: `/private/tmp/vp-library-guarded-full.log`. The iCloud mirror test also passes in this sequential run. Earlier overlapping runs are not final acceptance evidence; they included an iCloud timing failure and obsolete guide/overlay-scrollbar assertions.

**PASS:** final guarded `checks/check-snapshots.sh`, both appearances, 38 PNGs and the grid check. Output: `/private/tmp/vp-library-guarded-snapshots`; log: `/private/tmp/vp-library-guarded-snapshots.log`. All 38 PNGs are byte-identical to the final images already visually inspected, including the library and Google import at 200%. `check-contrast.py` also passes against this guarded output.

**PASS:** ten ICNS representations extracted with `iconutil` and checked for alpha-zero corners. The original artwork remains recognisable at 16, 32, 64 and 128 pixels.

The checks ran against the final implementation after `a19f5c7`. The guard commit is retained as a separate ancestor so it can be carried into the combined branch.

## Integration and limits

The other builder owns the remaining App/Settings/Camera work. **Still to integrate there:** UI zoom for the standalone Camera and iPad Remote windows and their remaining popovers; presenter transport/readiness/error announcements. This branch does not claim those windows are complete. The camera picker already accepts explicit zoom, and the Google import integration is complete here.

Live VoiceOver traversal, active/inactive-window glass, system Increase Contrast/Reduce Transparency combinations and real camera/microphone operation were not run. The brief prohibits visible app use and hardware audio/video. Static contrast samples do not certify the whole app. Minimum-width SwiftUI layout still logs its existing recoverable constraint warning.
