# Voice follow and meter response

14 November 2026. Baseline `6448929`. Headless work only.

## Result and limits

This change removes avoidable relay/meter waits and supplies the recogniser with a moving window of upcoming script words. It does **not** establish 5 ms speech recognition or an instantaneous live onset-to-highlight result. No microphone, physical iPad, network or display scanout was measured. The default highlight remains recognition-confirmed.

The previous investigation's independent natural recording measured recognition/publication at about **400 ms median / 724 ms p90**. That is historical evidence, not a new measurement and not necessarily this user's current hardware latency. Word-end timing is also not word-onset timing. It must not be relabelled onset-to-highlight.

## Changes

- Both capture sessions now use `AudioMeterDelivery`, including the iPad and the microphone test. It preserves transient peaks, attacks without an envelope ramp, releases at 20 dB/second and keeps one pending main-actor update at up to 60 Hz. A pending peak is delivered even if no subsequent audio buffer arrives. It replaces SessionStore's callback-driven throttle, which could hold the final peak until another callback. Generation checks discard delivery from a stopped/replaced capture.
- Mac microphone levels update the local console directly from the observed meter. A small, partial Mac-status message carries each update to the iPad instead of waiting for the 15 Hz source/status timer. Pending meter messages and full status messages have different coalescing keys so meters cannot starve source/control changes. The 15 Hz heartbeat/source handling remains.
- iPad microphone levels return directly to the Mac console instead of passing through a 100 ms throttle. The Combine callback uses its received value: reading the published property inside its `willSet` notification previously sent the preceding level.
- iPad requests a 256-frame tap instead of 1,024 frames and requests a 5 ms audio-session I/O duration. Its pending-buffer count becomes 16 instead of four, retaining the same nominal processing allowance at the requested sizes. These are requests, not proof of actual hardware callback size or latency. The Mac remains at 256 frames.
- `PadVoiceRelay` sends each confirmed word synchronously. There is no additional main-actor task. The existing transport still coalesces unsent follows, preserves command order, prioritises controls over queued video, and stamps the script fingerprint and seek revision. A late pre-seek word keeps its old revision and is rejected by the iPad.
- Dictation context now contains single words and adjacent pairs from the upcoming 48 script tokens, including lowercase words and single proper names. It refreshes every 24 tokens and on seeks across that window. Updates are serialised, tied to the capture generation and do not restart the recogniser. Failure of an optional context update is logged under `VIDEOPROMPTER_AUDIO_LATENCY=1` and does not stop capture.

No matcher thresholds, skip/re-read rules, confirmed-word semantics, scroll acceleration/braking, or highlight rendering were weakened. Mac highlight and iPad remote-follow already update without waiting for scroll easing at this baseline.

## Recogniser choice

The deployment targets already permit the new APIs: macOS/iPadOS 26. Production uses `SpeechAnalyzer` with `DictationTranscriber.progressiveLongDictation` and volatile results. The alternative `SpeechTranscriber.timeIndexedProgressiveTranscription` already enables fast/volatile results. The prior A/B investigation did not justify changing engines or adding frequent finalisation. Going back to `SFSpeechRecognizer` is not an established latency improvement; DictationTranscriber already uses the on-device dictation models.

Apple describes the progressive transcriber preset as immediate live transcription, not a 5 ms latency guarantee. Context is a vocabulary hint, not a command to advance without evidence. The moving context requires a future real-audio A/B to establish its effect on recognition speed and accuracy.

References:

- [SpeechTranscriber progressive preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset/timeindexedprogressivetranscription)
- [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)
- [AnalysisContext contextual strings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)

## Why onset prediction is not enabled

`VoiceInstantTests` includes a deliberately test-only energy-onset probe. It exercises a 10 ms synthetic onset response, no advance on silence, a one-word cap, and correction after a recogniser mismatch. It also supplies **identical energy observations** labelled as either a new word or a repeat. Both necessarily receive the same advance: the repeat case produces one visible wrong move, subsequently corrected. The same ambiguity exists for within-word syllables and non-script sounds.

This is a feasibility counterexample, not a recording-derived error rate, a production detector, or proof that every more sophisticated predictor fails. An energy/onset signal alone cannot meet the requested no-added-wrong-jumps gate. The saved word/ASR fixtures do not contain synchronised raw audio onsets, so they cannot validate that gate either. There is no new setting or dormant predictor in the shipped app.

A worthwhile next experiment would combine script-constrained phonetic alignment with timestamped audio, recogniser partials and independently marked word starts, including repeats, false starts, background speech and silence. It should measure visible wrong advances before enabling any predictive highlight. Guessing the next word at every energy rise is not an acceptable default.

## Per-stage evidence

| Stage | Before | After | Evidence boundary |
| --- | --- | --- | --- |
| Mac tap request at 48 kHz | 256 frames, 5.33 ms | unchanged | Requested size, not observed capture |
| iPad tap request at 48 kHz | 1,024 frames, 21.33 ms | 256 frames, 5.33 ms | Requested size, not observed capture |
| Conversion, ten seconds of 48-to-16 kHz input | 2.625 ms retained | 2.625 ms retained | Production converter, synthetic silent buffers |
| Recognition | historical 400/724 ms median/p90 | not remeasured | Context changed; no live recognition claim |
| Matcher | unchanged | unchanged | Recorded candidates and word fixtures |
| Highlight publication | immediate on accepted candidate | unchanged | Native offscreen regression and remote-follow state test |
| Glide, one/three/twelve-word step at 60 Hz | 200/267/567 ms to 90% | unchanged | Deterministic production coordinator; iPad is an offset model |
| Relay submission | one extra main-actor turn | same call as confirmation | Fake transport; network not measured |
| Mac meter link | waits for 66.7 ms status tick | direct from meter publication | Transport test, no network |
| iPad meter return | additional 100 ms throttle | direct from meter publication | Source audit and generic iPad build |
| Meter publication | callback-driven 16.7 ms gate | first update immediate, pending update within one 60 Hz interval | Timer can be delayed by main-thread contention |
| Screen presentation | next display refresh | unchanged | Physical scanout not measured |

A quiet 60 Hz estimate for the local meter is a requested 5.33 ms audio chunk plus up to 16.7 ms coalescing plus up to 16.7 ms display scheduling, about 39 ms before hardware/queue overhead. This is a budget, **not a measured end-to-end guarantee**. The test target is below 50 ms from callback to local publication/transport in the synthetic fixture. Wireless latency and main-thread load can exceed it.

## Validation

Baseline selected tests: **67 tests, one optional external speech replay skipped, zero failures**. `/tmp/vp-instant-before.log`.

Final selection: **188 tests, one optional external speech replay skipped, zero failures**, in 96.27 seconds. `/tmp/vp-instant-final.log`.

- Meter callback to local publication: **2.197 ms**; callback to partial status transport submission: **2.409 ms**. The synthetic pipeline includes AudioMeterDelivery, SessionStore, InputMeter, IPadCameraSender and a fake LinkPipe. Both are below the 50 ms test target. It excludes physical capture, the network and rendering.
- A second transient, followed by quiet input and then no more buffers, published in **17.921 ms**, preserved the peak and met the 50 ms target. This validates trailing delivery rather than waiting for another callback.
- Two recognised candidates reached the fake relay transport synchronously in **0.354 ms total**, including matching. No actor yield was needed. The baseline deliberately queued one actor turn; its exact wall duration was not measured.
- All three recorded matcher traces have exactly the same per-word timing statistics before and after: canonical median/p90 **434/875 ms**, Short 172 **433/808 ms**, Short 173 **417/725 ms**. These are replay fixture word-end times, not a new live recogniser measurement. They retain **zero unexcused early dimmed words**. Offline word replays also retain their original assertions, including zero early dimming for Shorts 189/193/194.
- Added glide lag is unchanged: canonical **30/230 ms** median/p90, Short 173 **30/190 ms**, Short 172 **20/230 ms**. Stops/minute remain **14.6 / 8.5 / 12.6**, p99 acceleration remains **90 words/s²**, and burst tests retain zero lead-clamp hits.
- One/three/twelve-word 90% scroll responses at 60 Hz remain **200/267/567 ms** on the native Mac coordinator and composed iPad model. At 120 Hz they remain **200/275/575 ms**.
- Production conversion retains **2.625 ms** after ten seconds before and after. Total conversion work was **296.2 ms before / 122.7 ms after**. There was no converter change; varying build/CPU contention explains why these work times cannot establish a conversion improvement.
- Growing-hypothesis matcher work at 50/100/200/400 words was **0.89/1.59/2.43/11.54 ms before**, **0.86/1.39/2.50/4.30 ms after**. Matching code is unchanged; these are execution samples, not a new algorithmic speed-up.
- The real offscreen presenter retains synchronous highlight and render-contention checks. Publication-to-detected-highlight medians were **29.5/54.4 ms before** without/with synthetic exposure and **19.2/19.7 ms after**. Paint medians were **10.4/12.5 ms before**, **4.3/4.2 ms after**. There was concurrent build work and no renderer change, so these are not evidence of improved physical display latency.
- The onset probe's **10 ms** number is simulated, and its repeat counterexample yields a visible wrong advance. It is not enabled or shipped as a user setting.

Commands and build evidence:

```sh
swift build -j 4
swift test -j 4 --filter 'VoiceInstantTests|VoiceLatencyTests|VoiceRenderLatencyTests|VoiceScrollResponseTests|VoiceGlideTests|SpeechLogReplayTests|OfflineWordReplayTests|AudioMeterLatencyTests|PadVoiceRelayTests|SessionStoreTests|CameraLinkTests|DevicePickerProtocolTests|AudioChannelIsolationTests|Recognition'
xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/vp-instant-ipad -jobs 4 build CODE_SIGNING_ALLOWED=NO -quiet
```

Mac build: PASS, `/tmp/vp-instant-mac-verified.log`. Generic iPad build: PASS. Early quiet invocations printed compiler-driver errors with exit status zero and no source error; the final ordinary-output run explicitly reported `BUILD SUCCEEDED`, `/tmp/vp-instant-ipad-build-proof.log`. The final repeat of the requested quiet command also exited zero with only the generic simulator destination warning, `/tmp/vp-instant-ipad-last.log`. No project build flags were changed to obtain the pass.

The selection includes meter cadence/attack/release/transient tests, immediate relay sends, stale revision rejection, separate meter/full-status coalescing, context bounds, onset feasibility, all existing voice latency/render/glide replays, microphone channel isolation, session lifecycle and recognition-safety tests. No existing accuracy/motion assertion was relaxed to obtain a pass.

Not run: `test.sh`, `checks/ipad-link-e2e.sh`, the full unrelated suite, live speech, actual iPad rendering, physical audio-route/callback calibration or network timing. No visible windows, Simulator launch, permission prompts, speaker playback, installation or real-device interaction was used. The next hardware check must log actual tap sizes, queue age, drops, input latency and display timing; requested sizes and synthetic tests cannot prove them.

**Before/after perceived onset-to-highlight latency remains unmeasured.** Recognition is still the dominant known delay. The defensible improvement is removal of the configured meter/relay waits, not a claim that live voice following now takes 5 ms.
