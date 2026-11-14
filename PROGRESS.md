# Presenter parity WIP: paused by user

User paused work to close the laptop. Do not resume until asked. No work is running;
all simulators started by this task have been shut down. No app was opened visibly,
no real full-screen transition was performed, and nothing was pushed or released.

Branch: `t3/presenter-ui-parity`. Base: `8ae0abc`.
Completed A–C/E implementation commit: `3670bfe`.
The following WIP commit contains F and this checkpoint; use `git log -1` for its SHA.

## A–F status

| Item | Done | Left / next step |
|---|---|---|
| A: console microphones | Two device sections, divider, tick from iPad-reported state, relay start/stop, actual default-device ID reporting. Old peers retain an iPad-mic fallback. | Physical mic switching remains unverified. Re-run end-to-end checks after F. |
| B: console cameras | Both device lists, source-aware live tick, validated local selection, camera toggle follows active side. | Physical camera switching remains unverified. The existing link does not return local-iPad video to the Mac; console displays its source name instead of an unrelated Mac feed. |
| C: matching iPad pickers | Named sections, visible divider, shared selection label. Before/after picker images captured. | Capture refreshed images including F's Rotate menu. |
| D: presenter bar parity | Full audit in `artifacts/presenter-parity/REPORT.md`; before snapshots captured. | HOLD. User requires an approved mockup before moving exposure/look controls out of More. No bar-layout changes were made. |
| E: console full screen | Explicit `.fullScreenPrimary`, resizable window, green button targets `toggleFullScreen:`; existing expanding replica/bar arrangement retained. Headless window tests and 1920×1080 layout snapshot passed. | Actual native full-screen entry and Ctrl-Cmd-F/Globe-F were intentionally not exercised on any display. |
| F: rotation | WIP optional `MacStatus.cameraRotation` and `Guides.rotation`; Mac sends chosen rotation metadata while encoder stays sensor-oriented. iPad applies it; local rotation and remote selection route added. Shared Rotate menu in Mac presenter, camera picker, console and iPad picker. Fixed link-layer rotation/mirror order; local camera adds manual rotation to horizon angle; reference renderer and confidence-monitor aspect handle rotation. | iPad build and new iPad rotation tests have NOT run. Validate transformed exposure/guide geometry, refresh snapshots, add link-level rotation assertion, then run full tests. See exact next steps below. |

## Latest verification

* A–E focused Mac checks: **7 passed**, including 3 protocol, 3 window and 1 console snapshot test.
* Generic iOS Simulator build, before F: **passed**.
* Before iPad harness from archived `8ae0abc`: **8 passed**, 68 PNGs.
* A–E after iPad harness: **8 passed, 1 failed**, 68 PNGs. The failing existing
  `testDisplayLinkScrollSmoothness` measured a 60.84 ms frame against its 50 ms limit
  while other checks were running. No speech/latency code was modified. Isolated
  rerun is still outstanding.
* A–E end-to-end harness: **5 passed**, including console starts Mac relay, rejects
  an invalid local mic ID, and returns to iPad mic via the optional destination.
* A–E full XCTest phase: **1112 executed, 92 skipped, 0 failures**. Its subsequent
  snapshot phase was stopped when F arrived. Therefore do NOT report `./test.sh`
  as completed for the final revision.
* F focused Mac build/tests finished just before pausing: **23 passed**, grid check
  **passed**. Filter covered DevicePickerProtocolTests, CameraOrientationTests and
  PadPresenterLayoutTests. This includes optional rotation fields and rotation /
  mirror / flip composition. F's iPad-specific changes remain unbuilt/unrun.

## Exact next steps after resume

1. Read this file and `git status`; do not touch `Speech/SpeechProvider.swift` or
   audio-capture code owned by the latency agent. D remains held.
2. Review F's WIP diff against `3670bfe`. The rendering strategy transmits optional
   orientation metadata, not re-encoded rotated pixels, to preserve latency.
   `LinkPreview` applies the same transform to decoded picture and exposure layers.
   Verify this meets the intended link behaviour and the rotated frame aspect.
3. Build iPad (no visible Simulator):
   ```sh
   env -u SDKROOT -u DYLD_FRAMEWORK_PATH -u DYLD_LIBRARY_PATH \
     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter \
     -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath /private/tmp/vp-parity-ipad-build CODE_SIGNING_ALLOWED=NO build
   ```
4. Run the headless iPad harness with the new `testRotationFollowsSourceAndKeepsExposureAligned`
   and `testRotationShots` tests:
   ```sh
   OUT="$PWD/artifacts/presenter-parity/after/ipad" \
     DERIVED_DATA=/private/tmp/vp-parity-ipad-build zsh checks/ipad-presenter-shots.sh
   ```
   Inspect all four rotation PNGs. `ExposureReferencePicture` currently rotates
   picture/exposure but has no guide-shape layers; add those if needed for honest
   guide-overlay snapshot evidence. Check built-in camera horizon plus manual
   rotation and the mirror order. Do not weaken the existing timing assertion.
5. Add a headless link assertion for Mac rotation status reaching the iPad and local
   remote rotation returning in state. Before running e2e, confirm no owned test
   simulators remain booted. Run:
   ```sh
   OUT=/private/tmp/vp-parity-e2e VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-parity-after-tests \
     zsh checks/ipad-link-e2e.sh
   ```
6. Run the COMPLETE final suite after the last source edit:
   ```sh
   VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-parity-after-tests \
     VIDEOPROMPTER_SNAPSHOTS="$PWD/artifacts/presenter-parity/after" ./test.sh
   ```
   Capture output to a NEW log filename; do not truncate one a process still holds.
7. Once other checks stop, rerun only the iPad timing test without rebuilding; a
   prepared headless script is `/private/tmp/vp-parity-timing.sh`. It creates and
   deletes its own simulator and uses `test-without-building`. It has NOT run.
8. Update the audit/results, inspect the final screenshots, commit the completed F
   and evidence, and report all commit SHAs, snapshot paths and remaining limits.
   No push, release or version bump is authorised.

## Evidence and logs

* `artifacts/presenter-parity/REPORT.md`: detailed before/after audit and selected paths.
* `artifacts/presenter-parity/SNAPSHOTS.txt`: absolute paths of all PNGs captured so far.
* Full local PNG sets are retained under ignored `before/` and `after/` directories.
  Representative existing images are committed with the WIP checkpoint. The final
  `after/mac-setup-1180x820.png` is still outstanding; full snapshots will create it.
* Logs: `/private/tmp/vp-parity-focused.log`, `vp-parity-console-final-shots.log`,
  `vp-parity-targeted-before.log`, `vp-parity-ios-final-build.log`,
  `vp-parity-ipad-baseline.log`, `vp-parity-ipad-after.log`, `vp-parity-e2e.log`,
  `vp-parity-final-test.log`, `vp-rotation-tests.log`.
* `vp-parity-final-test.log` has sparse NUL regions from a cancelled earlier writer;
  strip NUL bytes when reading it. Its 1112-test pass belongs to A–E, not final F.
* Baseline source archive used for iPad snapshots: `/private/tmp/vp-parity-baseline`.
* Shared build cache: `/private/tmp/vp-parity-after-tests`; iPad derived data:
  `/private/tmp/vp-parity-ipad-build`. No files in `/Applications` were changed.
