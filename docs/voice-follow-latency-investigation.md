# Voice-follow latency investigation

Updated 14 November 2026. Base `8ae0abc`; resumed from `732dfdc`.

## Review follow-up: braking at the lead limit

The independent review correctly identified a gap in the earlier smoothness checks: p99 acceleration could pass while an individual frame stopped abruptly at `goal + lead`.

The follow-up retains the acceleration cap and adds a stopping-distance velocity envelope (nominal 60 words/s² braking), followed by a distance-proportional approach near the lead limit. The latter includes the frame duration so a delayed frame still cannot consume all remaining distance. The hard position bound remains defensive; the tested bursts no longer reach it abruptly.

The new regression measures **the largest per-frame deceleration**, not a percentile, and counts entries into the lead clamp for 1-, 3-, 8- and 12-word bursts at both 60 and 120 Hz. It also checks nonnegative motion and the existing lead bound. It failed on the previous code and passes on the follow-up.

| Rate | Burst | 90% response before / after | Largest deceleration before / after | Clamp entries before / after |
| --- | ---: | ---: | ---: | ---: |
| 60 Hz | 3 words | 317 / 317 ms | 53 / 53 words/s² | 0 / 0 |
| 60 Hz | 8 words | 433 / 450 ms | 113 / 84 words/s² | 1 / 0 |
| 60 Hz | 12 words | 517 / 567 ms | 249 / 79 words/s² | 1 / 0 |
| 120 Hz | 3 words | 308 / 308 ms | 53 / 53 words/s² | 0 / 0 |
| 120 Hz | 8 words | 433 / 458 ms | 113 / 82 words/s² | 1 / 0 |
| 120 Hz | 12 words | 517 / 575 ms | 456 / 77 words/s² | 1 / 0 |

These before/after numbers compare the reviewed `7392e4b` implementation with this follow-up, not the original slow implementation. The one-word coasting allowance is unchanged. Evidence: `/private/tmp/vp-braking-before.log` and `/private/tmp/vp-braking-final-bursts.log`. The native coordinator replay after the follow-up reaches the 12-word destination in 567 / 575 ms at 60 / 120 Hz. Composing the existing iPad offset filter gives 650 / 667 ms. Three-word response is unchanged. The recorded replays still pass their original accuracy and motion checks: canonical/Short 173/Short 172 added-lag medians are 60 / 50 / 30 ms and p90s are 230 / 200 / 230 ms.

Validation: the repeated complete `./test.sh` exited 0 on 14 November 2026. Its main suite passed 1,114 tests (92 conditional skips); light and dark snapshots each passed 61 tests (one skip each); the final 117-file grid check passed. Log: `/private/tmp/vp-braking-full-retry.log`. The first full run had two assertions fail in the unrelated large-message CLI/MCP test; that test subsequently passed both alone and in the complete repeat. No unrelated code or test was changed to obtain the pass. The generic iPad build passed at `/private/tmp/vp-braking-ipad.log`, with no Simulator boot. Implementation commit: `9eb6744`.

## Original investigation: software delay and first fix

Recognition was only part of the delay. The production presenter adds `VoiceGlide` after SessionStore publishes the recognised word. Its position catch-up (0.5 s) and velocity filter (0.15 s) compounded the lag, especially when speech resumed or results arrived in a burst. The iPad adds its existing 0.08 s offset filter afterwards.

The fix reduces those two shared time constants to 0.15 s and 0.08 s. A 90 words/s² limit on increases in velocity prevents sudden acceleration. Braking, explicit seeks, jump handling, the one-word lead limit, recognition and all matching decisions remain unchanged. Faster constants without this acceleration limit failed the existing smoothness tests and were rejected.

This fixes a measured post-recognition delay. It does not prove that every part of the user's hardware symptom is resolved.

## First-fix measurements (before the braking follow-up)

The recorded tests feed identical recogniser candidates into the unchanged matcher, then advance the production glide at 120 Hz. These numbers are **additional scroll delay after word acceptance**, not recogniser latency.

| Recorded reading | Median before | Median after | p90 before | p90 after |
| --- | ---: | ---: | ---: | ---: |
| Canonical | 170 ms | 60 ms | 410 ms | 230 ms |
| Short 173 | 160 ms | 50 ms | 390 ms | 200 ms |
| Short 172 | 120 ms | 30 ms | 340 ms | 210 ms |

The new native AppKit regression drives a partial candidate through SessionStore and the real scroll coordinator after silence. For a 12-word burst at 60 Hz, reaching 90% of the destination improved from **717 to 517 ms on Mac**. Composing the production iPad offset filter improved **783 to 600 ms**. A three-word burst now takes **317 ms on Mac / 400 ms in the iPad model**. The tests also cover 30 and 120 Hz and verify the existing lead bound.

All three recorded motion tests retain their original limits: no more than 30 stops per minute and p99 acceleration <=100 words/s². After the fix they measured 7–20 stops/minute and p99 acceleration 90 words/s². Matching and no-ahead-word assertions are unchanged.

## Other stages

These stages were not changed to obtain the scroll improvement.

- **Input/AEC:** Mac capture never enables AVAudioEngine voice processing. iPad requests `.record` / `.measurement`, not `.voiceChat`. Actual node state and OS/hardware latency require real input capture; no live microphone was opened. The optional diagnostic log now reports node voice-processing state, actual tap frame count/duration and processing-queue wait. On iPad it also reports the session category, mode, I/O duration and input latency.
- **Buffering:** requested tap sizes remain 256 frames on Mac and 1024 on iPad. Requests are not proof of actual callbacks. The Mac's count-based 16-buffer limit could cover more time when delivered buffers are larger; no persistent backlog was observed in replay, and its live behaviour remains unverified.
- **Conversion:** 48-to-16 kHz conversion retains 2.625 ms after ten seconds, without accumulating lag. The audio replay now uses production `AudioCapture.process`, not a separately implemented converter. Its conversion p90 was about 1 ms per 100 ms chunk.
- **Recognition:** production remains on DictationTranscriber with volatile partial results. SpeechTranscriber's existing preset already enables fast and volatile results. Adding frequentFinalization to dictation and switching recognisers did not justify a change in the earlier A/B runs; both experiments were reverted.
- **Matching:** partial candidates advance immediately. There is no final-result gate or timed debounce. Confidence/evidence safeguards for skips and re-reads remain. The independently timed 25-word replay measured match/publication p90 about 1 ms; the longer natural replay previously measured callback-to-publication p90 13.36 ms.
- **UI and main thread:** the full production PresenterView now runs in a transparent TestOffscreen panel with isolated preferences and capture disabled. It does not require a physical Prompter XL. The replay explicitly completes a bitmap paint because invisible windows do not receive ordinary compositor refreshes. A quiet 25-word run measured publication-to-offscreen-paint median 21 ms / p90 32 ms, paint-work p90 10 ms, and word-end-to-painted-highlight median 476 ms / p90 838 ms. The final repeat during the full-suite load measured publication-to-paint median 23 ms / p90 98 ms, conversion p90 5 ms, match/publication p90 2 ms, paint-work p90 26 ms, and word-end-to-paint median 537 ms / p90 846 ms. All 25 words arrived with zero dropped buffers. This includes recognition, and is NOT photon/display-scanout latency.
- **Contention:** a separate hosted production-text test verifies the actual highlighted word while the production 1080p exposure processor and meter publisher run alongside it. It uses bounded synthetic frames, not camera capture. Physical camera/GPU/thermal contention remains a hardware check.
- **Relay:** the Mac-mic relay recognises once on Mac and sends confirmed positions. Follow messages coalesce for one main-actor turn, not a timed debounce. iPad state (200 ms) and remote-meter (100 ms) throttles do not gate follow commands. Network and real iPad rendering latency remain unmeasured.

## Measurement fixes retained

The original replay delivered each chunk up to 100 ms early and relied on recogniser-provided word times. Dictation's word times in one 20.785 s synthetic recording ended at 10.32 s and produced a false 9.56 s p90. The replay now waits for a complete chunk and supports independent `{text,start,end}` JSON through `VIDEOPROMPTER_SPEECH_REPLAY_WORDS`.

The rendered replay now selects the script's TrackingTextView, explicitly paints hidden content, and uses a local PresenterView/camera/preferences setup. It no longer mistakes an unrelated scroll view or a not-yet-visible script for a renderer delay. It still cannot measure a real display's presentation time.

## Reproduction and diagnostics

`./test.sh -XCTest PrompterCoreTests.VoiceScrollResponseTests,PrompterCoreTests.VoiceRenderLatencyTests,PrompterCoreTests.SpeechLogReplayTests,PrompterCoreTests.VoiceGlideTests`

For the opt-in audio-to-offscreen-paint test, set:

- `VIDEOPROMPTER_RUN_ACTUAL_SPEECH_REPLAY=1`
- `VIDEOPROMPTER_RENDERED_REPLAY=1`
- `VIDEOPROMPTER_SPEECH_REPLAY_ENGINE=dictation`
- `VIDEOPROMPTER_SPEECH_REPLAY_LOCALES=en-GB`
- `VIDEOPROMPTER_SPEECH_REPLAY_WAV=<audio.wav>`
- `VIDEOPROMPTER_SPEECH_REPLAY_SCRIPT=<script.md>`
- `VIDEOPROMPTER_SPEECH_REPLAY_WORDS=<independently timed words.json>`
- `VIDEOPROMPTER_SPEECH_REPLAY_LOG_PATH=<new path.jsonl>`
- `VIDEOPROMPTER_REPLAY_CHUNK_FRAMES=4800` for a 48 kHz file

Then run `./test.sh -XCTest PrompterCoreTests.SpeechSessionIntegrationTests/testActualWAVThroughProductionProviderAndSession`.

`VIDEOPROMPTER_AUDIO_LATENCY=1` enables the optional production input/conversion/matching/meter diagnostics. Logs contain timing and token indices, not transcript text. Real-device capture was not performed under this task's restrictions.

## First-fix validation (before the braking follow-up)

PASS: complete `./test.sh`, 1,113 main tests (92 conditional skips), both light/dark appearance passes (61 tests each, one skip each), and the final 117-file grid check. Zero failures. Log: `/private/tmp/vp-voice-full-final.log`. Focused response, jump/hold, no-false-word, render-contention and recorded smoothness checks passed. The generic iPad Simulator-target build also passed without booting a Simulator. No app was installed or released.

Earlier and current temporary evidence is under `/private/tmp/vp-voice-latency-20261114/` and `/private/tmp/vp-*.log`. The earlier six-minute natural replay accepted all 714 script words with no drops (recognition/publication median 400 ms, p90 724 ms), but retained isolated garbled/re-read stalls. None of those ASR/matcher stalls is claimed fixed by scroll damping.
