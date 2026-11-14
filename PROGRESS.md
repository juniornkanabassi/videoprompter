# Paused: voice-follow latency investigation

Paused at the user's request on 14 November 2026 because the laptop is closing.

## Branch and scope

- Branch: `t3/fix-voice-follow-latency`, based on `8ae0abc`.
- Existing investigation commit: `71cd6b8` (`test: correct voice replay timing and document latency investigation`).
- This WIP commit also saves the final documentation addition and this checkpoint.
- No production implementation changed. No push, release, version bump, app installation, live microphone/camera capture or Simulator boot.

## Finding / root cause status

**The reported persistent slow following is NOT fixed or conclusively reproduced. Do not report this as a production fix.**

Mac capture does not enable voice processing/AEC in code. iPad capture requests record/measurement mode. Real OS/device processing has not been measured. The Mac-mic relay runs the same SessionStore recogniser and forwards confirmed positions, rather than sending PCM to another recogniser.

Production chooses DictationTranscriber with progressiveLongDictation; it already delivers volatile partial results. Matching does not wait for final results. The alternative SpeechTranscriber preset already includes fastResults and volatileResults. Trying frequentFinalization on dictation produced no material improvement and was reverted. The alternative transcriber was not faster in the short comparison, so no engine switch was kept.

Two measurement defects were fixed in the replay harness:

1. It delivered each buffer before its samples could have been captured (100 ms early with the tested 4800-frame chunks). It now waits until the chunk's end before yielding.
2. Dictation's per-word timestamps were wrong in the short synthetic recording: final word ranges ended at 10.32 s for 20.785 s of audio. They produced a false 9.56 s p90. The replay now optionally accepts independent word times through `VIDEOPROMPTER_SPEECH_REPLAY_WORDS`.

## Measured numbers

- Independent synthetic fixture, corrected pacing, waveform-derived word endpoints: 25/25 words, zero drops, published-highlight latency median 458 ms, p90 813 ms, max 1372 ms. The p90 <= 1.2 s replay gate passed. This measures SessionStore publication, NOT physical display painting.
- Six-minute natural Short 173: all 714 words accepted, zero drops, per-word median 400 ms, p90 724 ms, max 11.552 s around garbled/repeated speech. Longest no-progress interval 12.518 s included a garbled sentence and re-reading. No growing backlog reproduced. This run used original pacing (up to 100 ms optimistic), recognised word timestamps, and ran alongside other tests; do not call it an isolated hardware measurement.
- Natural replay candidate callback to synchronous highlight-state publication: median 4.49 ms, p90 13.36 ms, maximum 26.90 ms.
- 48-to-16 kHz conversion: only 2.625 ms retained after 10 seconds; no accumulating backlog. 100 conversions took about 126 ms total in a debug test.
- Partial-hypothesis matching: approximately 1/2/2/4 ms at 50/100/200/400 words; existing larger exploratory test was about 13 ms at 1200 words.
- Existing VoiceGlide fixture tests: added lag median 0.12–0.17 s, p90 0.34–0.41 s. Highlight state does not wait for the glide.
- Read-only built-in microphone CoreAudio query: 48 kHz, 512 buffer frames, 50 safety frames, 1439 stream latency frames, 0 device latency frames (about 41.7 ms nominal total). This is NOT measured live capture latency.

## Changes saved

- `Tests/PrompterCoreTests/SpeechSessionIntegrationTests.swift`: corrected replay pacing, optional independent JSON word track and coverage check, explicit --agent-screen on disposable rendered replay store.
- `Tests/PrompterCoreTests/VoiceLatencyTests.swift`: headless conversion/backlog and partial-hypothesis advancement/cost checks.
- `docs/voice-follow-latency-investigation.md`: evidence, commands, limits and next diagnosis.

## Tests and stopped work

- Focused suite PASS: 20 tests, 1 conditional skip, zero failures.
- Corrected independent timed replay PASS: 25/25 words, zero drops, p90 gate passed.
- Six-minute production-provider replay PASS: 714/714 words, zero drops.
- `./test.sh` main suite PASS: 1110 tests, 92 skips, zero failures.
- Separate light appearance pass PASS: 61 tests, 1 skip, zero failures.
- Separate dark appearance pass was still running when the user paused. It was stopped with TERM via its run-xctest wrapper so cleanup can run. **Full test.sh must not be labelled complete/pass yet.**
- Rendered latency replay SKIPPED: no Prompter XL display. No display or visible Simulator was opened as a workaround.
- No simulators were booted, so none required shutdown.
- Existing suite emitted nonfatal CoreData/SwiftUI warnings; do not confuse these with XCTest failures.

## Evidence and exact next step

Temporary evidence lives at `/private/tmp/vp-voice-latency-20261114/`:

- `full-suite.log`, `subset.log`, `stages.log`
- `natural-before.jsonl` / `.log`
- `before.jsonl`, `frequent.jsonl`, `transcription.jsonl` and logs
- `timed-corrected.jsonl` / `.log`, `rendered.log`
- `timed/reading.wav`, `timed/script.md`, `timed/words.json` (word times derived from waveform threshold, not recogniser output)

These are temporary and may disappear after a reboot. Durable findings are in this file and the docs report.

On resume:

1. Read this file and `git status --short`; retain the existing WIP and do not revert unrelated work.
2. Run `./test.sh > /private/tmp/vp-voice-latency-resume-full.log 2>&1` and wait for BOTH appearance passes and the final grid check. Everything is headless through TestOffscreen. Do not open apps or boot a visible Simulator.
3. If further diagnosis is authorised, obtain a timestamped trace on the affected actual build/device (capture callback, converted audio, recogniser result, SessionStore update, physical paint) within the user's permission/display limits. The current source/replay evidence does not justify a speculative AEC or recogniser change.
4. Real iPad mic, Mac-mic relay/network and actual screen painting remain unverified. Severe persistent lag remains unresolved.
