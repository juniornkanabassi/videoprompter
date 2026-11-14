# Voice-follow latency: resumed implementation

Branch `t3/fix-voice-follow-latency`, resumed from `732dfdc` on 14 November 2026.

## Confirmed cause and current change

The production scroll path applies VoiceGlide after recognised words have already been published. The previous position (0.5 s) and velocity (0.15 s) filters compound the lag. The iPad applies a further 0.08 s offset filter. A native coordinator replay reproduced 717 ms to reach 90% of a 12-word burst's destination on Mac, or 783 ms with the iPad filter.

The current fix uses 0.15 s / 0.08 s shared filtering and caps increases in velocity at 90 words/s². Braking and matching are unchanged. It measured 517/600 ms for the same 12-word case, and 317/400 ms for a three-word case at 60 Hz (Mac / modelled iPad). Tests cover 30/60/120 Hz. The recorded scroll tests improve added p90 delay from 340–410 ms to 200–230 ms while retaining their original smoothness limits and no-false-word checks.

This is a demonstrated software contributor, not proof that every part of the hardware symptom is fixed.

## Changes

- Shared `Sources/PrompterCore/VoiceGlide.swift`: faster response with bounded positive acceleration.
- `AudioCapture.swift` on Mac/iPad: opt-in actual buffer/queue/conversion and AEC-state timing logs. iPad also logs session mode/category and reported device latency.
- `SessionStore.swift`: opt-in matching work and audio-position diagnostics. No transcript text logged.
- `VoiceScrollResponseTests.swift`: native scroll geometry / partial results / silence / frame cadence regression.
- `VoiceRenderLatencyTests.swift`: actual hosted text highlight and bitmap paint; also bounded production exposure processing and meter publication.
- `SpeechSessionIntegrationTests.swift`: production audio conversion and local transparent PresenterView replay, without physical screen dependency; timestamps completed offscreen bitmap paint.
- Detailed evidence and commands: `docs/voice-follow-latency-investigation.md`.

## Checks / evidence

- Original full main suite before this implementation: 1110 tests, 92 skips, zero failures; light snapshots passed, dark interrupted by the earlier user pause.
- Final full run now active: `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-voice-final-732dfdc ./test.sh > /private/tmp/vp-voice-full-final.log 2>&1`. Check its actual completion; both appearance passes and grid check are required.
- Focused recorded glide test with final acceleration limit passed. Faster constants without that limit failed smoothness and were discarded.
- Generic iPad build: `/private/tmp/vp-voice-ipad-final.log`, succeeded without booting a Simulator.
- Full 25-word audio-to-offscreen-paint replay: `/private/tmp/vp-rendered-isolated4.log`, passed; 25/25 words, zero drops; conversion and matching p90 ~1 ms; publication-to-paint p90 32 ms; word-end-to-paint p90 838 ms. This was run before final acceleration calibration; it does not measure real display scanout.
- Final repeat of that replay: `/private/tmp/vp-rendered-verified.log` (check completion).
- Focused final short tests: `/private/tmp/vp-voice-verified-short.log`, passed (5 tests).
- Current response/motion evidence: `/private/tmp/vp-limited-glide.log` and `/private/tmp/vp-voice-verified-short.log`.
- Existing independent audio fixture: `/private/tmp/vp-voice-latency-20261114/timed/reading.wav`, `script.md`, `words.json`.

## Exact next steps

1. Check running jobs and the final full test log. Do not launch another full run unnecessarily. If it fails, address actual findings and rerun the affected check, then finish full validation.
2. Check final audio replay and the optional exposure contention test results. Update the report from actual final logs, not earlier failed test prototypes.
3. Commit all final changes on this branch. No push, release, install or version bump.
4. Report the confirmed post-recognition cause, bounded before/after results, checks and remaining hardware work. No real microphone/camera capture or Simulator boot has been used; no simulator needs shutdown.

## Remaining hardware limits

Actual microphone callback sizes, OS voice processing, live camera/GPU/thermal contention, network relay latency and physical display paint require real-device confirmation. Recognition and matching are unchanged; garbled/repeated-speech stalls remain possible. The iPad timing composition is tested through shared logic, not real UIKit/display hardware.
