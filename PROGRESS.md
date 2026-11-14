# Presenter parity: implementation and verification complete

Branch: `t3/presenter-ui-parity`. Base: `8ae0abc`.

The 14 November mockup released D. Implementation is committed in `0a9cb56`,
following `3670bfe` (A–C/E) and `01b090a` (rotation WIP). The final evidence commit
aligns the iPad Start reading label, updates its affected test and records results.

## A–F status

| Item | Status | Remaining verification / limits |
|---|---|---|
| A: console microphones | Named Mac/iPad sections and divider; selection tick from reported state; Mac relay starts/stops with source selection. | Physical microphone switching is not tested. |
| B: console cameras | Both device lists, live tick, source-aware selection/on-off. | Physical switching is not tested. Existing link has no reverse iPad-local video stream; console labels that source. |
| C: iPad pickers | Named sections/divider and shared selection labels; matching Rotate menu. | Physical-device verification only. |
| D: approved bar | Shared responsive setup bar on all three presenters, approved order/icons/labels, live level, direct picture tools, no console More button. Existing Mac reading bar retained; iPad/console have equivalent status/Pause/Set up/Focus. | Deeper settings and specialist monitor differences are listed explicitly in the audit; this change does not make every settings panel identical. |
| E: console full screen | fullScreenPrimary, resizable, green-button/native toggle action; expanded layout and window-flag tests. | No actual full-screen transition or keyboard shortcut was exercised on a display. |
| F: rotation | Optional link metadata/commands; 0/90/180/270 for current source; rotation composes with mirror/flip and exposure layers/guides. | Physical camera calibration remains unverified. |

## Verification

- Full `./test.sh`: PASS (exit 0). Main: 1115 executed / 92 skipped / 0 failures.
  Light and dark snapshot passes: each 61 executed / 1 skipped / 0 failures.
  Grid: 117 Swift source files passed. Log: `/private/tmp/parity-final-all-v3.log`.
- Focused UI: 46 passed. Compact controls/stage-space regression: 8 passed.
- iPad full harness: 12 passed, including rotation/overlay geometry, optional remote
  UI fields and scroll smoothness (`/private/tmp/parity-ipad-current.log`).
- Refreshed final iPad presenter images: 2 passed after label alignment
  (`/private/tmp/parity-final-ipad-label.log`).
- Generic iOS Simulator build: passed after the last source edit
  (`/private/tmp/parity-ios-final-label.log`).
- Headless link e2e: 5 passed, including rotation metadata/requests, presenter state
  and microphone switching (`/private/tmp/parity-final-e2e-v2.log`).
- Owned simulators were shut down before e2e; none remain booted.

## Evidence and next step

- [Complete before/final audit and results](artifacts/presenter-parity/REPORT.md).
- [Absolute snapshot inventory](artifacts/presenter-parity/SNAPSHOTS.txt).
- Representative dark images are committed from `artifacts/presenter-parity/final/`;
  bulk harness output remains locally in ignored directories.

No automated implementation step remains. Any follow-up should start with the
explicit hardware and deeper-settings limits in the report. No push/release/version change.
No visible window, Simulator window, permission prompt or sound was used.
Speech/SpeechProvider.swift and the audio-capture implementation were not changed.
