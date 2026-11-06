# Builder B, round 5

## What moved

Folder navigation is a visible native list above the native script list inside
the existing two-column library. The writing control now names its scope before
it opens. Practice creates/selects a short script and opens its reading window.
Exposure guidance and the colour meanings live in the owned presenter file
`ExposureLegend.swift`; the shared camera settings use the same guidance.

## Findings addressed

| Council finding | Result |
| --- | --- |
| First-time user 2; creator workflow 5 | Visible plain-language exposure guidance. Face brightness says to look for stripes on the lit cheek, qualified as a standard-video reference. Skin tones and log/profile differences remain explicit. Every false-colour band has a practical meaning, including why bright details or shadows may need attention. |
| First-time user 4 | The library button says Editor text size; its popover points to the separate presenter text control and Reading settings. |
| First-time user 5 | The basic paste/present instructions explicitly explain voice following after Start reading. |
| First-time user 7 | Try the Practice Script now opens a saved, short guided try, instead of merely selecting Welcome in the editor. No microphone or recording is started. The script respects Voice follow or Automatic scroll. A camera-only or clean-view state cannot hide the practice text, and the saved view preference is retained. |
| First-time user 6; visual design 3 | The library retains the same folder and script navigation at every interface size. Folder organisation is visible; native list selection replaces the fixed blue painted background. Active/inactive semantic text colours keep the selection legible. |
| Accessibility 5 | Save feedback and camera recovery descriptions use primary text. Measured contrast from final PNG glyph interiors is recorded below. |
| Accessibility 1 | The reading contrast guard includes unknown dark/bright/intermediate camera pixels, dimmed stage directions and confirmed words, active-word colour, and the normal/large-text threshold. It cannot approve black text on a possible black picture. Make Readable changes only darkness and explains impossible combinations. The bound is deliberately conservative. |
| UX heuristics 3 | Undetermined camera access offers Allow Camera Access in the picker itself. Merely opening the picker never requests permission. Denied access retains the System Settings route. |
| UX heuristics 4, library portion | Add includes the existing Import from Google Docs window. |
| UX heuristics 6, reading portion | The backdrop label identifies camera versus script-only scope. Show Presenter previews the settings using the existing presenter. |
| Visual design 5 | The modern icon has separate editable vector background, page, lines, reading marker, microphone body and support. Three native groups, with default/dark/tinted object variants, compile successfully. Native system masking replaces the baked rounded tile. Legacy bitmap masters and ICNS are preserved. |

## Ownership exceptions

- `Camera/CameraWindow.swift`: removed the relocated `ExposureLegend` definition,
  inserted the shared guidance into exposure settings and strengthened two
  recovery descriptions. No recorder, transport or camera-model behaviour changed.
- `Tests/PrompterCoreTests/PresenterPresentTests.swift`: the sidebar regression
  now finds the last native list (scripts), because the first list is intentionally
  folder navigation. The original selectable-script assertion is retained.

Everything else is within Builder B ownership. No push, merge, release build,
installation, visible app launch or audio playback was performed.

## Verification

Results and exact commands are recorded after the final runs below. All windows
were covered by the existing TestOffscreen guard and all data/preferences were
disposable. Logs contain pre-existing Contacts/CoreData service warnings.

- Full XCTest suite: PASS, 511 tests, 12 skipped, zero failures (171.5 s).
  Command: `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-builder-b-r5 zsh test.sh`.
  Final log: `/private/tmp/vp-builder-b-r5-complete.log`. The seven new focused
  behaviour tests passed, including the camera-only/clean-view practice path.
- Snapshot suite and grid check: PASS. Five snapshot tests in each appearance,
  ten executions total, 198 PNGs generated; grid check passed for all five files.
  All changed surfaces were inspected in light and dark using contact sheets
  and full-size checks of the start path, native selection, exposure guidance,
  camera recovery and icon variants.
  Command: `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-builder-b-r5
  VIDEOPROMPTER_SNAPSHOTS="$PWD/docs/design/round-5-builder-b/snapshots"
  zsh checks/check-snapshots.sh`. Log: `/private/tmp/vp-builder-b-r5-snapshots-final.log`.
- Native icon compile: PASS, `zsh Resources/AppIcon/compile-icon.sh
  /private/tmp/vp-builder-b-r5-icon`. This is resource compilation, not a release.
- Native icon exports: Default, Dark, TintedLight and TintedDark at 16, 32, 64 and
  128 points; inspected at native size and enlarged. See `icons/`.
- Contrast: `python3 docs/design/round-5-builder-b/measure-contrast.py`.
  Save status, disconnected-camera guidance, undetermined-permission guidance
  and denied-permission guidance all measure **14.94:1** in light appearance
  (`#272727` on `#FFFFFF`) and **12.43:1** in dark (`#DCDCDC` on `#1C1C1C`).
  See `contrast.json` for exact crops. These are ordinary text measurements,
  above 4.5:1, not claims of whole-app WCAG certification.

## Remaining scope and live checks

Builder A owns the recording receipts/notices and health layout, early REC state,
dropped video reporting, default-microphone resolution, compact presenter focus
and camera navigation, duplicate Settings navigation and presenter/menu wording.
Those are not repaired by this branch. The Reading form's existing stacked
controls remain outside the specific follow-up requested here; this change adds
a direct preview and accurate scope without rebuilding that form's layout.

Live Liquid Glass composition, hardware exposure calibration and recording,
spoken VoiceOver and system-wide keyboard traversal remain untested, as required
by the offscreen-only brief. Native inactive selection is visible in the offscreen
captures; active accent/Increase Contrast should still receive a live check.

The icon source follows Apple's unmasked-layer workflow:
[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer).
