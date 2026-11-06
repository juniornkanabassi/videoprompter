# Round 8 Builder B completion

Merged the requested earlier attempt, `ba0d008`, by fast-forward from `efe4c97`.
Read all five round-8 reports, the builder brief, design spec and hidden-app
instructions. The work below includes the retained changes from that attempt.

## Findings and placement

- **Visual design 3, library metadata.** The editable title uses regular weight.
  Save state and word count share one quiet line. Text size and Script details
  share the next line at every zoom. Linked scripts show only Linked until
  Script details opens; the two-way editing explanation, filename, tags and
  Unlink file are there. Actual broken-link recovery stays visible. Markdown
  headings and the user's script are untouched. Strengthened the inherited
  metadata colour to avoid trading readability for restraint.
- **Creator 5 / first-time user 5, exposure.** False colour immediately shows
  six swatches with short brightness labels and ranges taken from the renderer.
  The compact 200% fixture is 760 points wide. Numerical zebra calibration,
  colour explanations and face/profile qualifications stay in Help. Guidance
  starts with what to check and where to change brightness. Grey gaps are
  explicitly explained; this is a band key, not a continuous scale or universal
  face target.
- **Accessibility 1, popover focus.** Text size and Camera use the same native
  opener capture plus SwiftUI keyboard/accessibility focus restoration. Each
  instance now has a unique anchor. Tested two openers in one window, selection,
  Escape and the real library editor popover. The regression fixture ignores
  closed popover windows, so it cannot accidentally press a stale Done button.
- **Accessibility 2, preset contrast.** Retained primary callout guidance. The
  necessary one-line change in Settings/SettingsView.swift is the sole retained
  production change outside Builder B's ownership. Final normal-size PNG
  measurements are recorded in verification/preset-contrast.json, with crops.
  Disabled Save remains disabled.
- **Visual design 5, icon meaning.** Retained the earlier script/page/reading
  marker and lens artwork. Verified 18 editable appearance layers across three
  groups, ten matching legacy sizes, and compiled the native catalogue in the
  isolated test bundle. Updated the source documentation and generator's
  leftover microphone variable names. Prior masters remain preserved. The
  16/32/64/128-pixel appearance contact sheet is in icons/contact-sheet.png.

No generic reading-size buttons occur in Builder B's owned files. The existing
Smaller/Bigger controls are in PresenterController.swift, which belongs to A;
the required Smaller text/Larger text labels and point values remain A's work.

## Verification

- `zsh test.sh`: 542 tests, 15 skipped, zero failures. The opt-in hardware/
  external tests and snapshot-only cases explain the skips.
- `zsh checks/check-snapshots.sh`: 248 PNGs generated across light and dark;
  all 40 changed/owned library, exposure and preset examples inspected, including
  the 760-point-wide key at 200%. Grid check passed.
- Preset sentence in final 100% PNGs: **14.13:1 light**, **11.57:1 dark**.
  Measurements use linearised sRGB luminance, dominant interior glyph/background
  pixels and the recorded crop. Antialiasing edge pixels are excluded.
- Six focused regression tests pass, including repeated and separate openers,
  Escape from the real library text popover, link disclosure, band ranges and
  rendered preset contrast.
- The final re-identified hidden app returns native Camera focus after AXCancel
  at 100/150/200%. Its frontmost process stayed unchanged. Executable and source
  hashes, AX evidence, measurements and test summary are under `verification/`.
- Native icon compilation/signature verification passed in that disposable
  bundle. The icon assets remain layered; no release build was made.

## Limits and handoff

The hidden copy uses the worktree's compiled executable and helper, current
compiled icon resources, a separate bundle identifier, ad-hoc signature,
isolated home/data and --agent-screen. It was stopped and its disposable bundle,
data and defaults were removed. The owner's installed app was not touched.

The hidden library did not expose an accessibility window, so actual library
focus is verified in an offscreen host of LibraryView, not claimed as a live
library-window pass. The live Camera cancellation check does expose the real
nested picker and its opener at 100/150/200%. No real camera selection, recording,
microphone test, audio playback, physical VoiceOver session or live glass
appearance was exercised. Selection focus is covered by the offscreen fixture.

Presenter geometry, reading-mode discovery, pre-take checks, saved-take identity
and camera-window naming are outside this ownership and remain for Builder A.
Nothing was pushed, released or installed.
