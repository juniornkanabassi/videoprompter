# Round 7 Builder B

6 November 2026. Scope is library/import/presenter supporting views, the camera
picker, resources and their tests. No release, installation, push or merge.

## Changes by finding

| Finding | Result |
|---|---|
| Dark Folders heading | Explicitly resolved label colour on a separate native heading. Pixel tests measure 12.25:1 in dark and 12.39:1 in light at 100/200%, on inactive offscreen windows. |
| Two sidebar hierarchies | Folder navigation above a labelled script list; the lower heading names its folder scope and count. Document separators removed. New Folder moved to the quiet Folder actions menu. Folder context actions remain. |
| Narrow library | 640-point minimum; sidebar widths capped; native sidebar collapse below the space needed at each interface size. Tests exercise the actual minimum and 840-point layouts. The editable title measures and wraps using a native NSTextField. |
| Camera preview at 200% | Preview and caption stay above one bounded scrolling device/recovery list. Arrow keys scroll the selected row, without scrolling the preview away. Empty and twelve-device fixtures remain available. |
| Script-only readability | The same conservative colour check now covers both views, including backdrop transparency, dimmed text, cues and active words. |
| Unexpected Make Readable changes | Full change described before pressing. Prefer changing only the relevant backdrop opacity, rounded up to its displayed percentage. Otherwise use white text, black backdrop and full visibility. Preserve highlighting. Preserve stage directions unless their contrast fails at small sizes; describe that exception. Immediate Undo plus native Undo registration. |
| Linked-file destination hidden | Filename and “Edits also change this file” stay below save status, with Unlink file directly available. Original import and conflict safeguards retained. |
| Autosave lacks completion | Editor displays the save controller's actual message, including Saved, until another edit. Existing generation ordering and save-failure recovery retained. |
| Exposure jargon and misleading legend | Practical bright-area/colour decisions; no custom band is called a face target by the legend. Numeric measurements moved under disclosure. Skin-tone and flat-picture caveats remain in plain language. |
| Practice lost at enlargement | Try the Practice Script follows the primary reading instruction, ahead of Camera Only and secondary import/write actions. Enlarged heading uses the existing smaller title style. |
| Small modern icon soft | Simplified editable microphone body, stronger support, page edge and reading line. Default, Dark and TintedDark exported at 16/32/64/128 pixels. |

The matching Round 7 refinement is recorded in DESIGN-SYSTEM.md and the council
DESIGN-SPEC.md, including the section 2.1 placement changes.

## Boundaries

The CameraWindow exposure preset picker still classifies every nonzero range as
“Face brightness”. That control/model belongs to Builder A. This change removes
that inference from the owned on-picture legend and avoids prescriptive face
exposure advice in shared guidance, but does not claim to repair the preset
picker's state model. Presenter transport, Camera tools access, recording setup
labels, completion status, microphone and rotation work belong to Builder A.

Two existing cross-surface test files, UIZoomTests and SimpleInterfaceTests,
needed only their library-width expectations updated for the deliberate smaller
minimum and bounded sidebar. No production code outside Builder B was changed.

## Verification

Offscreen renders do
not certify active Liquid Glass, spoken VoiceOver, real-camera exposure or
recording. All app checks used an isolated hidden copy with --agent-screen;
no real camera recording, microphone capture, global input or audio playback.


- `zsh test.sh` with a private build cache: **530 tests, 13 skipped, zero failures**. Skips are the opt-in/snapshot cases; the separate snapshot run exercises the render fixtures.
- `zsh checks/check-snapshots.sh`: **PASS**, six snapshot tests per appearance, **238 PNGs**, grid audit passed. Inspected all 60 changed PNGs in labelled contact sheets, plus full-size checks of the camera picker, narrow editor, start page and colour-recovery surfaces. Selected light/dark evidence is in `snapshots/`; the full output manifest is `snapshot-manifest.json`.
- Nine dedicated Builder B regression tests pass, including actual heading pixel contrast, 840-point layout, editable wrapped titles, recovery/Undo, preview visibility at 200% and practice visibility.
- `swift build`: **PASS**. The debug executable SHA-256 is `de13c7ef14274d2f6a5923d8237560a2b94837fbc9844e3b2b6dca71f0a03332`.
- Current debug executable and CLI were placed in a re-identified disposable copy, signed ad hoc and run with an isolated home/data directory and `--agent-screen`. Ten CLI commands passed, covering create, present, 100/150/200% zoom, status and close. AX access was trusted; named presenter controls remained available; foreground PID stayed unchanged. Only the disposable process was terminated and its folder removed. Evidence is in `live/`.
- Native icon resource compilation: **PASS**. Actual-size Default, Dark and TintedDark exports at 16/32/64/128 pixels were inspected. Legacy raster/ICNS artwork is unchanged.

Live library-window resize and spoken VoiceOver remain unverified. The hidden
presenter and CLI results do not stand in for those checks; the library has
native offscreen geometry, editing, hit-target and pixel checks instead.
