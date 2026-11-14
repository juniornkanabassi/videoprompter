# Review follow-up complete: smooth braking

Branch `t3/fix-voice-follow-latency`. Implementation commit: `9eb6744`.

The faster glide could reach `goal + lead` with positive velocity, causing a hard stop that the previous percentile check missed. The follow-up adds a stopping-distance speed limit and gradual final approach. It leaves acceleration, recognition, matching and the coasting allowance unchanged.

- Regression in `VoiceGlideTests`: largest per-frame deceleration <=100 words/s², zero clamp entries, no negative motion, no lead-bound violation. Covers 1/3/8/12-word bursts at 60/120 Hz.
- Previous code failed: worst deceleration 249 / 456 words/s² at 60 / 120 Hz; the 8- and 12-word cases each hit the clamp.
- New code passes: worst deceleration 84 / 82 words/s²; zero clamp hits. Three-word response unchanged. Twelve-word 90% response 517 -> 567 ms (60 Hz), 517 -> 575 ms (120 Hz). This retains 75% of the original 12-word latency improvement at 60 Hz.
- Native coordinator replay: after the fix, 12 words reaches 90% in 567 / 575 ms; with the existing iPad offset filter, 650 / 667 ms, at 60 / 120 Hz.
- Recorded canonical/Short 173/Short 172 added-lag medians 60 / 50 / 30 ms, p90s 230 / 200 / 230 ms. Accuracy and original motion assertions pass.
- Full `./test.sh` PASS, exit 0: 1,114 main tests (92 conditional skips); both appearance passes each 61 tests (one skip each); 117-file grid PASS. Log `/private/tmp/vp-braking-full-retry.log`. Completed 14 November 2026, approximately 04:45 UTC.
- First full run had two failed assertions in the unrelated large-message CLI/MCP test (`/private/tmp/vp-braking-full.log`). That case passed both alone (`/private/tmp/vp-braking-cli-retry.log`) and in the complete repeat. No unrelated production/test change was made.
- Generic iPad build PASS: `/private/tmp/vp-braking-ipad.log`. No Simulator was booted, so none required shutdown. No app was opened, installed, pushed or released.
- Final burst evidence: `/private/tmp/vp-braking-before.log` and `/private/tmp/vp-braking-final-bursts.log`. Full report: `docs/voice-follow-latency-investigation.md`.

Implementation and headless validation are complete. Remaining hardware checks: subjective smoothness and actual display timing on a real Mac/iPad, plus live input/relay behaviour from the original investigation. No real-device capture was performed.

---

## Previous implementation checkpoint

# Voice-follow latency: source fix and validation complete

Branch `t3/fix-voice-follow-latency`, resumed from `732dfdc` on 14 November 2026. Implementation commit: `2b886e6`.

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
- Final full run PASS: 1,113 tests, 92 conditional skips, zero failures; both appearance passes each passed 61 tests with one skip; final grid check passed. Command: `VIDEOPROMPTER_TEST_SCRATCH=/private/tmp/vp-voice-final-732dfdc ./test.sh > /private/tmp/vp-voice-full-final.log 2>&1`. Completed at 03:48:59 UTC on 14 November 2026.
- Focused recorded glide test with final acceleration limit passed. Faster constants without that limit failed smoothness and were discarded.
- Generic iPad build: `/private/tmp/vp-voice-ipad-final.log`, succeeded without booting a Simulator.
- Full 25-word audio-to-offscreen-paint replay: `/private/tmp/vp-rendered-isolated4.log`, passed; 25/25 words, zero drops; conversion and matching p90 ~1 ms; publication-to-paint p90 32 ms; word-end-to-paint p90 838 ms. This was run before final acceleration calibration; it does not measure real display scanout.
- Final repeat of that replay: `/private/tmp/vp-rendered-verified.log`, PASS. All 25 words, zero drops; conversion p90 5 ms; matching p90 2 ms; paint-work p90 26 ms; publication-to-paint p90 98 ms during full-suite load.
- Focused final short tests: `/private/tmp/vp-voice-verified-short.log`, passed (5 tests).
- Current response/motion evidence: `/private/tmp/vp-limited-glide.log` and `/private/tmp/vp-voice-verified-short.log`.
- Existing independent audio fixture: `/private/tmp/vp-voice-latency-20261114/timed/reading.wav`, `script.md`, `words.json`.

## Next step / handback

The source fix and required headless checks are complete. No push, release, app installation or version bump was performed. No Simulator was booted.

Review the implementation and, when authorised, validate the affected real Mac/iPad build using `VIDEOPROMPTER_AUDIO_LATENCY=1`. The optional logs report input-node voice processing, actual buffer duration/queue wait, conversion and matching. Do not claim live hardware confirmation from these offscreen replays.

## Remaining hardware limits

Actual microphone callback sizes, OS voice processing, live camera/GPU/thermal contention, network relay latency and physical display paint require real-device confirmation. Recognition and matching are unchanged; garbled/repeated-speech stalls remain possible. The iPad timing composition is tested through shared logic, not real UIKit/display hardware.
