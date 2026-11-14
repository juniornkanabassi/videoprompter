# Voice-follow latency investigation, 14 November 2026

Base: `8ae0abc`. No production behaviour change is justified by these replays. The reported severe lag has not yet been reproduced. AEC is not enabled by the Mac capture implementation; iPad capture requests `.record` / `.measurement`. This is a source audit, not a live-device AEC measurement.

## Measurements

All playback was file-to-recogniser, without audio output, live capture, app launching or a Simulator. XCTest links TestOffscreen. Runtime app launches were not needed.

- Mac tap request: 256 frames (5.33 ms at 48 kHz); iPad: 1024 (21.33 ms). These requests do not prove actual callback sizes. Replay used 4800-frame / 100 ms input chunks.
- Read-only CoreAudio query of the built-in MacBook Pro microphone: 48 kHz, 512 buffer frames, 50 safety frames, 1439 stream-latency frames, zero device-latency frames. Those reported components total about 41.7 ms; this is nominal device configuration, not a live capture measurement.
- 48-to-16 kHz conversion: 10 seconds of synthetic input retained 2.625 ms, with no accumulating backlog; 100 conversions took 125.64 ms total in a debug test.
- Matcher: growing partial hypotheses of 50 / 100 / 200 / 400 words took roughly 2 / 2 / 3 / 5 ms. Partial results advanced immediately; no final-result gate or debounce.
- Short continuous synthesised reading: current dictation delivered result ranges about 55 ms after their audio end, p90 97 ms. This is NOT per-word recognition latency: a result range can end after the last recognised word.
- Independently timed, individually synthesised words: waveform endpoints (last sample exceeding 80/32768 amplitude), median word-end-to-published-highlight 458 ms, p90 813 ms, maximum 1372 ms. All 25 words reached, zero dropped input buffers. Published highlight state is measured; actual display painting and live hardware input are not.
- Adding `.frequentFinalization` to long dictation did not materially change the short continuous replay (result-range p90 97 -> 94 ms). The experiment was reverted.
- Existing fast/volatile SpeechTranscriber replay: median per-word 632 ms, p90 889 ms. It did not justify replacing production dictation.
- VoiceGlide deliberately smooths scrolling after the highlight updates; existing recorded-replay tests separately bound its added delay. Highlight colouring itself does not wait for the glide.
- Six-minute natural Short 173 replay: PASS, all 714 script words accepted, zero dropped buffers. Word-to-published-highlight p50 400 ms, p90 724 ms, maximum 11.552 seconds on garbled/re-read speech. The longest no-progress interval (12.518 seconds) includes a garbled phrase and the speaker repeating the sentence. This run used the original replay pacing, so it can be up to one 100 ms chunk optimistic. It ran alongside other tests and is not an isolated hardware benchmark.
- On that natural replay, candidate callback to synchronous highlight-state publication: p50 4.49 ms, p90 13.36 ms, maximum 26.90 ms. This covers matching and SessionStore publication, not the UI run loop or actual paint.
- Mac-mic relay performs recognition in the same SessionStore, then sends confirmed positions to the iPad; it does not send PCM through a second recogniser. Follow messages coalesce over one MainActor turn, without a timed debounce. Network and iPad rendering latency remain hardware measurements.

## Measurement correction

The current OS's final DictationTranscriber word ranges for a 20.785-second synthetic recording ended at 10.32 seconds, although the result range ended at 20.785. Trusting those word ranges yielded a spurious 9.56-second p90. Do not use that number as evidence of app lag.

The replay also now waits until a whole audio chunk has elapsed before delivering it. Previously each chunk was submitted up to 100 ms early in these measurements.

The existing production replay now accepts `VIDEOPROMPTER_SPEECH_REPLAY_WORDS`, a JSON array of `{text,start,end}` objects in recording seconds. It aligns this independent word track instead of the recogniser's own timestamps, checks coverage, and retains the existing `VIDEOPROMPTER_MAX_WORD_LATENCY_P90` gate.

The opt-in rendered replay was attempted and skipped because this machine has no Prompter XL display. No display or Simulator was opened as a workaround.

## Reproduction

Use `./test.sh -XCTest PrompterCoreTests.SpeechSessionIntegrationTests/testActualWAVThroughProductionProviderAndSession` with:

- `VIDEOPROMPTER_RUN_ACTUAL_SPEECH_REPLAY=1`
- `VIDEOPROMPTER_SPEECH_REPLAY_ENGINE=dictation`
- `VIDEOPROMPTER_SPEECH_REPLAY_LOCALES=en-GB`
- `VIDEOPROMPTER_SPEECH_REPLAY_WAV=<audio.wav>`
- `VIDEOPROMPTER_SPEECH_REPLAY_SCRIPT=<script.md>`
- `VIDEOPROMPTER_SPEECH_REPLAY_WORDS=<independent-words.json>`
- `VIDEOPROMPTER_SPEECH_REPLAY_LOG_PATH=<new-log.jsonl>`
- `VIDEOPROMPTER_REPLAY_CHUNK_FRAMES=4800` for 48 kHz source audio

Do not enable `VIDEOPROMPTER_RENDERED_REPLAY` for this headless investigation. No microphone or camera access is needed. Evidence from this run is under `/private/tmp/vp-voice-latency-20261114/` (temporary, not committed).

## Validation

Focused suite: PASS, 20 tests, one expected opt-in skip. The corrected, independently timed production replay: PASS, 25/25 words, zero drops, p90 below the 1.2-second gate. Six-minute natural-reading replay: PASS. Full main XCTest suite: PASS, 1,110 tests, 92 expected/conditional skips, zero failures. The runner also performs separate offscreen appearance snapshots and the source grid check.

## Remaining diagnosis

The reported persistent slow following has not been reproduced, and no production fix is claimed. A live-device capture/callback/paint trace on the affected Mac and iPad is needed to separate actual capture buffering, OS microphone processing, recogniser arrival, main-thread scheduling and display latency. No live-device capture or permission prompts were attempted. The tests do not prove the latency of the Mac-mic network relay.
