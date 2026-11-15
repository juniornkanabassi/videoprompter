# Default Mac speech engine (14 November 2026)

The Mac now defaults to **Parakeet (recommended)**: EOU 160 ms and Unified 320 ms run on the same mono 16 kHz input using CPU + Neural Engine. Each retains its own matcher history; the first matching forward position wins. Apple (no download) is the only alternative. Legacy `both`, `unified` and `both-unified` settings migrate to `parakeet`. iPad continues using Apple.

Apple stays warm as a silent backup. It contributes results for non-English scripts, while either verified model is missing or fails to load, and after either stream errors or overflows its bounded input queue. A short status explains backup use. Model failures do not pause the script. Completed downloads take effect on the next Start reading.

Background preparation starts shortly after launch, runs one model at a time at background priority and reuses individually SHA-256 verified files. Cancel and choosing Apple stop the download. Low Data Mode blocks automatic downloads and offers Download now. Tests, snapshots, agent-screen and camera-list child processes never prefetch. All files remain under the app data root in Models/parakeet-eou-160ms and Models/parakeet-unified-320ms.

Unified's chunk setting and pinned export are kept together in `UnifiedModel.swift`. A different tier requires the corresponding verified encoder manifest; changing runtime chunk size alone is not safe. Existing measurements below are historical single-engine/Apple-pair experiments, not measurements of the new default pair.

---

# Speech engine A/B experiment

14 November 2026. Base `9910919`. Apple stays the default. This is an opt-in Mac experiment, not a claim that a new recogniser is more accurate for Junior.

## Selection

Compare **word end → first published matching position**. Chunk size, inference time, first transcript, endpoint latency and file throughput are different quantities. None of the vendor benchmarks below establishes latency or accuracy on British football commentary while this app encodes video.

| Engine | Streaming latency evidence | English / football accuracy | Mac load and model size | Integration, iPad and licence |
|---|---|---|---|---|
| Apple DictationTranscriber | Existing project replays: about 400–430 ms median publication, 720–875 ms p90. Progressive volatile candidates. First partial depends on speech onset. | Current baseline, contextual upcoming words supported. No independently labelled football WER. | OS-managed model; app does not control its placement or download size. | Already integrated, Mac/iPad; Apple framework terms. |
| **FluidAudio Parakeet EOU 120M, 160 ms** | True cached streaming; 160 ms input with 80 ms shift; incremental transcript. NVIDIA claims 80–160 ms model latency. Not a measured app word-end delay. | NVIDIA reports 9.30% average WER / 3.61% LibriSpeech clean in its 160 ms setting. FluidAudio's converted model documents about 8–9% clean WER, so upstream accuracy cannot simply be assigned to this export. No hotword API on this engine. | Our exact required files total **224,047,838 bytes**. CPU + ANE chosen, GPU excluded. Upstream M5 compute-plan audit assigns the heavy encoder to ANE; this is not measured utilisation during encoding. | Native Swift, SPM. iOS 17+ supported upstream; integrated on Mac only here. FluidAudio Apache-2.0; weights NVIDIA Open Model License, commercially usable subject to its conditions. |
| sherpa-onnx streaming Zipformer | True streaming, checkpoint-specific chunk/lookahead; published English chunk-16 exports typically around 320 ms before compute. Smaller chunk models need separate validation. No comparable first-partial/word-end numbers on this workload. Streaming Paraformer examples primarily target Chinese, not a demonstrated better English choice. | English 20M through larger GigaSpeech/LibriSpeech checkpoints. Hotword/context graph support with modified beam search. British names need our own test. | CPU ONNX runtime by default; thread count configurable. Tens to hundreds of MB depending on checkpoint and quantisation. CPU contention under encoding unmeasured. | Swift wrappers and macOS/iOS XCFrameworks, plus ONNX runtime package. Apache-2.0 runtime; check each model's own licence. More native binary packaging than FluidAudio. |
| Moonshine streaming | True streaming encoder. Default transcript update interval **500 ms** is configurable. Its headline latency measures final transcript after endpoint detection, often on faster-than-realtime input, not per-word publication. | Tiny/Small/Medium streaming published float average WER 12.00/7.84/6.65%. Quantised shipping clean WER 4.83/2.61/2.17%, tested whole-utterance. Football not established. | 34M / 123M / 245M parameters, quantised ONNX; size varies by export. CPU load and competing encoding not measured here. | Swift package exists, but its Mac instructions require a locally built dylib/framework, unlike ready iOS slices. MIT code and streaming models; old non-English batch models have other terms. |
| WhisperKit | Chunked Whisper inference with partial agreement, rather than a cache-aware streaming acoustic model. Paper reports 0.46 s latency and 2.2% WER in its benchmark, not this word-end metric. | Strong multilingual/general English; prompt tokens can help names but require testing against hallucinations. | Core ML/ANE/GPU options. Tiny to large models span tens of MB to multi-GB; repeated decoding competes for compute. | Swift/SPM, iOS 16+/macOS 13+. MIT. Easy integration but no demonstrated speed win over current ~0.4 s median. |
| whisper.cpp stream | Official example samples every **500 ms** and reruns a **5 s** window. Window/step can shrink, trading accuracy/stability. Not true streaming. | Good larger-model English, prompt support; small windows and names need testing. | CPU/Metal; model-dependent roughly 75 MB tiny to multi-GB large. Repeated window inference; encoding contention unmeasured. | C/C++ bridge, Apple Silicon and iOS examples. MIT code/Whisper weights. More glue and no convincing low-latency win. |

Sources (primary): [NVIDIA model card](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1), [FluidAudio 0.18.0 implementation](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Sources/FluidAudio/ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift), [FluidAudio models](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Documentation/Models.md), [ANE compute-plan audit](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Documentation/ANE_Profiler.md), [sherpa streaming models](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html), [sherpa Swift package](https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift), [Moonshine benchmark definitions](https://github.com/moonshine-ai/moonshine/blob/main/docs/using/benchmarks.md), [Moonshine model accuracy](https://github.com/moonshine-ai/moonshine/blob/main/docs/models/accuracy.md), [Moonshine Mac packaging](https://github.com/moonshine-ai/moonshine-swift), [WhisperKit paper](https://arxiv.org/abs/2507.10860), [WhisperKit package](https://github.com/argmaxinc/WhisperKit), [whisper.cpp stream](https://github.com/ggml-org/whisper.cpp/tree/master/examples/stream).

**Choice:** Parakeet EOU is the smallest practical integration with a genuine lower-latency streaming architecture and a CPU/ANE route that avoids intentionally loading the GPU. This is a candidate for user A/B, not an assertion that it is fastest among all models. Medium Moonshine is a credible follow-up if Parakeet's football-name accuracy is poor. We have not benchmarked every alternative.

## Implementation and model

- Mac Settings → Reading → Following → **Speech engine: Apple / Parakeet**. Apple remains the decoded/default value. Reading presets preserve the chosen engine, as they preserve microphone and language.
- CLI: `videoprompter settings set --speechEngine parakeet` or `--speechEngine apple`. `settings get` includes `speechEngine` and preparation status. The MCP manifest is generated from this same command table.
- Choosing Parakeet then starting Voice follow asynchronously downloads/verifies/loads its model with a visible status and spinner. No model work occurs at launch. Pausing/switching invalidates old candidates. Download/network failure pauses with the existing error notice; it never silently switches engines.
- In the original two-option implementation, only one engine consumed the capture stream at a time; the follow-up below adds simultaneous consumption. `SpeechProvider.start` delivers both to `SessionStore.acceptSpeechCandidate`; matcher, backward/false-advance guards, glide and iPad relay are unchanged.
- Apple retains rolling script context. Parakeet EOU's RNNT decoder exposes no contextual/hotword bias API. No invented substitutions or forced script words were added.
- Parakeet emits a cumulative partial under one revision ID per generation. Its range records submitted audio, **not word timestamps**. Do not calculate word-end latency by subtracting that range end.
- Transport to `AnalyzerInput` is mono 16 kHz Int16, converted by the existing capture converter; FluidAudio converts to Float32. This avoids an observed macOS 27 `AnalyzerInput.data(from:)` trap on Float32. No change to Apple's negotiated format.
- Mac model cache: `<ControlProtocol.dataRoot>/Models/parakeet-eou-160ms`, normally `~/Library/Application Support/Video Prompter/Models/parakeet-eou-160ms`; Alpha/Development and `--data-directory` use their own root. Test downloads used `/tmp/vp-speech-ab-model`, so the user's app data was not changed.
- Exact model repository revision **40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355**, URL prefix `https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/resolve/40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355/160ms/`. Required components: `streaming_encoder.mlmodelc`, `decoder.mlmodelc`, `joint_decision.mlmodelc`, `vocab.json`. No preprocessor needed. All 16 sizes and SHA-256 values are pinned in `ParakeetModel.files` and verified on cache use and download; see `speech-engine-model-manifest.json`.
- FluidAudio **0.18.0**, published 28 October 2026 (over two weeks old), exact SPM pin `e15287985625dbf544a343df679436789ffb03fb`. TTS, diarisation and NeMo text-processing traits are disabled. The small fastcluster C wrapper remains a dependency of the upstream package; its BSD notice is included. No models/audio committed. Notices and licence texts are copied by `build.sh`.
- iPad keeps Apple for its own mic. Shared settings decode the engine field, but `selectedSpeechEngine` uses Apple on iOS. A Mac's Parakeet progress still relays normally. Native iPad integration was deferred to avoid adding an unmeasured model/thermal burden and a second download/settings flow. The generic simulator build verifies source compatibility, not runtime recognition on an iPad.

Licences: [FluidAudio Apache-2.0](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/LICENSE), [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/), [Moonshine licence](https://github.com/moonshine-ai/moonshine/blob/main/LICENSE). NVIDIA's licence allows commercial use but is not Apache/MIT; model redistribution requires its agreement and notice. The app fetches from the model publisher. Bundled acknowledgements retain the source and terms.

## Measurement

Hardware: Apple M3 Max, 64 GB; Xcode Swift 6.4.2, macOS 27.3 runtime. Debug build. No video encoding, live microphone, playback, physical display or real iPad was used.

`SpeechEngineABTests.testRecordedAB` reads the original canonical WAV from the existing acceptance-input folder, paced in real time in ~33 ms buffers through `AudioCapture.process`. The same earlier frozen English word-time track is used for both engines. It is an ASR-derived proxy, not a human-labelled transcript: report reference WER as disagreement with that frozen transcript, not true human WER. First partial is measured from file start (which includes initial silence), not speech onset. False advances use the existing `WordLatency.early` definition and its re-read allowances. Position latency uses actual synchronous session publication. No rendering timings are claimed.

Run after `swift build --build-tests --scratch-path /tmp/vp-speech-ab-build`:

```sh
VP_SPEECH_AB=1 \
VP_SPEECH_AB_ENGINE=parakeet \
VP_SPEECH_AB_AUDIO='/path/to/JuniorPrompter v0.3.0 (9) Test Script Reading.wav' \
VP_SPEECH_AB_MODEL=/tmp/vp-speech-ab-model \
VP_SPEECH_AB_OUTPUT=/tmp/vp-speech-ab-results \
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
DYLD_LIBRARY_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib \
zsh checks/run-xctest.sh /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
-XCTest 'PrompterCoreTests.SpeechEngineABTests/testRecordedAB' \
/tmp/vp-speech-ab-build/out/Products/Debug/PrompterCoreTests.xctest
```

Set `VP_SPEECH_AB_ENGINE=apple` for Apple, or omit it for both. The model directory is a required explicit override in this test to prevent writing real application data. Output contains reference WER, first-partial, p50/p90 publication latency, coverage, false advances and final recognised text. The opt-in test requires model files or downloads only to that override.

## Validation and limits

- PASS `swift build --scratch-path /tmp/vp-speech-ab-build` (Mac).
- PASS requested generic iPad `xcodebuild ... build CODE_SIGNING_ALLOWED=NO -quiet`, with `/tmp/vp-speech-ab-ipad` derived data. No simulator boot.
- PASS 14 focused XCTest cases: setting default/round trip/routing, cumulative candidates through the real session, seek watermark, checksum corruption, edit distance and revised-range transcript stitching, seven offline word replay cases, CLI/MCP command-table validation. Log `/tmp/vp-speech-ab-verified-final2.log`.
- PASS source ignore assertions (equivalent read-only commands without sourcing the keychain-checking env.sh), `git diff --check`, and generated MCP `settings_set.speechEngine` enum inspection.
- NOT RUN `test.sh`, `checks/ipad-link-e2e.sh`, visible UI, microphone permissions/capture, physical iPad, or concurrent video encoding, per task boundaries. Settings rendering at all scales and live hardware/thermal performance need the lead's acceptance pass.
- Two earlier replay attempts trapped in macOS 27's `AnalyzerInput.data(from:)` with Float32 input. A standalone Int16 constructor check passed; the working replay and Parakeet input format now use Int16.
- Broader `SpeechLogReplayTests` reached a Contacts service error in the host's existing test/runtime path and were stopped. The pure `OfflineWordReplayTests` passed. No Contacts interaction or permission request was made, and no unrelated code was changed to work around the host service.
- This is not an accuracy upgrade yet. Names such as Doué and Lamine Yamal are a weakness of the small unbiassed recogniser. Poor tail latency and recogniser substitutions must remain visible in the report. No cloud fallback exists.


Two complete Parakeet runs were consistent: median 171.8 / 172.3 ms, p90 2544.5 / 2545.8 ms, 288/288 published, zero early advances, 62/292 reference edits (21.23%). First partial 5.876 / 5.889 s from file start; the recording begins with roughly five seconds of silence. This reduces the median substantially but does not satisfy “as accurate or better” or demonstrate better tail latency. Keep Apple as the normal choice; use the switch to evaluate the trade-off in the actual studio setup.

The first two Apple runs measured median 477.1 / 476.6 ms, p90 1481.0 / 1483.1 ms, 288/288 published and one flagged early advance. Their initially calculated WER was invalid because timestamp-shifted revisions were concatenated twice. The corrected harness replaces overlapping audio ranges; a focused test covers that correction. The final Apple WER below comes only from that corrected run.

The two engines ran in separate XCTest processes with overlapping wall time, each on its own real-time stream. These are exploratory debug-build results, not isolated production performance certification. No encoding load was introduced. Parakeet process RSS was observed around 319 MB and CPU snapshots around 10–43% of one core; these samples are not an average or a measurement of ANE utilisation. A release build, isolated alternating runs and representative camera encoding remain necessary before promoting the engine.


### Final corrected measurements

| Engine | First partial from file start | Word end → publication median | p90 | Reference WER | Script coverage | Early advances |
|---|---:|---:|---:|---:|---:|---:|
| Apple, contextual en-GB | 5.865 s | 478 ms | 1,492 ms | 5.82% (17/292 edits) | 288/288 | 1 |
| Parakeet EOU, 160 ms | 5.889 s | 172 ms | 2,546 ms | 21.23% (62/292 edits) | 288/288 | 0 |

Apple corrected replay: `/tmp/vp-speech-ab-apple-corrected.log`; Parakeet: `/tmp/vp-speech-ab-parakeet-final.log`. Both passed. Machine-readable results and final text are in `speech-engine-ab-results.json`. The single Apple early flag uses the older ASR-derived word alignment and is not human-verified. No claim that Parakeet is safer follows from one flag versus zero.

**Decision:** leave Apple enabled. Parakeet gives roughly 306 ms faster median following on this recording, but poorer recognition and a slower p90. It does not meet “as accurate or better”. The opt-in switch makes the requested personal trial possible without changing any matcher safeguards. A release-build trial during real video encoding and a human-labelled British football sample are required before any default change. Consider a packaged Moonshine Small/Medium streaming trial next if retaining Parakeet's faster median is not worth its errors.


## Follow-up: fastest matching engine (14 November 2026)

Base `f1e7c0a`. The Mac now offers **Both (fastest wins)**, keeping Apple as the default. Both consumes the same captured PCM: Apple gets its negotiated format, Parakeet gets an independently converted mono 16 kHz Int16 copy. Each engine has its own candidate source and recognition tracker. Only a strictly newer confirmed script position is published. A delayed result cannot overwrite the other engine's revision or roll the published position back. Both intentionally follows forward; use the reading controls to reread. Seeks restart both live recognisers, and both histories honour the audio watermark during the transition. Pause, restart, engine change and failed preparation cancel both providers. A bounded input queue fails visibly if an engine cannot keep up instead of silently dropping audio.

### Method

Same canonical WAV, 288-word script, frozen 292-word ASR-derived reference, real-time 30 Hz file input, synchronous SessionStore publication, Debug build on M3 Max / macOS 27.3. No microphone, camera, playback, simulator boot, windows or encoding. Full runs are sequential. All numbers are word end to publication, not model chunk sizes. Negative differences are retained and the existing early-advance detector is unchanged. Reference WER measures disagreement with the older Apple-derived transcript, not human-labelled accuracy. It can favour Apple.

Both is a position race, not transcript fusion. Its WER column reports the two independent transcripts; there is no honest single combined WER. CPU is this process's user+system CPU time divided by elapsed replay time (100% = one core). Apple service CPU and ANE utilisation are excluded. Peak RSS is process high-water memory including preparation. CPU+ANE is requested for local models; utilisation is not measured.

`SpeechEngineABTests.testRecordedAB` supports `apple`, `parakeet`, `both`, `transcription`, `apple16`, `appleWarm`, `eou320`, `unified`, `unified320`, `nemotron560`, `nemotron1120`, `nemotron2240` and `both-` plus each local model name. Use the command above with `VP_SPEECH_AB_ENGINE` and an explicit model directory. `VP_SPEECH_AB_SECONDS=8` is a smoke test only, not a full accuracy result. JSON includes source-specific WER, candidates with actual delivery times, publication times, audio format, CPU time and peak RSS.

### Apple tuning

The production provider already checks/installs locale assets, sets context, calls `prepareToAnalyze`, uses `bestAvailableAudioFormat`, and forwards the very first volatile result. There is no final-result or stability wait to remove. The existing matcher immediately accepts a matching frontier tail, with additional ambiguity/false-advance guards. Unconditionally crediting any occurrence of the next word would reuse earlier words in cumulative revisions. Those safeguards are retained.

The current countdown is **manual-scroll only**; Voice starts preparation immediately, so there is no Voice countdown to overlap. `appleWarm` tests starting the analyser three seconds before file input without synthesising speech or silence. `apple16` explicitly supplies 16 kHz Int16; ordinary Apple already negotiates this format on this machine. `transcription` uses `SpeechTranscriber` with `.timeIndexedProgressiveTranscription` instead of contextual DictationTranscriber. None changes the shipping Apple behaviour unless the replay demonstrates a latency win with no extra early flags.

### Available model variants

FluidAudio remains exactly **0.18.0**, released 28 October 2026. 0.18.1/0.18.2 (1 November) and 0.18.3 (7 November) are less than two weeks old as of this experiment and are ineligible. Its `NemotronChunkSize` offers only 560/1120/2240 ms: no 320 or 80 ms Nemotron Streaming 0.6B export is available in an eligible release. Do not confuse the model's 80 ms encoder frame with an exposed streaming chunk. EOU 320 ms is still **120M**, not a larger model. Unified is **0.6B** and really streams; cached [70,7,1] has 640 ms chunk+lookahead, and [70,2,2] has 320 ms. Both are measured.

Models used for experiments are either read directly from the existing FluidAudio cache (`loadModels(from:)`, no download/recovery APIs), or downloaded into `/tmp/vp-dual-models` at immutable Hugging Face revisions with recorded sizes/SHA-256. The user's FluidAudio cache was never modified. No weights or audio are committed.

Primary sources: [FluidAudio 0.18.0 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.0), [Nemotron documentation at 0.18.0](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Documentation/ASR/Nemotron.md), [Unified model and streaming tiers](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml), [Apple preparation API](https://developer.apple.com/documentation/speech/speechanalyzer/preparetoanalyze(in:)).


### Full replay results

Milliseconds; CPU is % of one core. Every completed row reached 288/288 words. In paired WER cells, values are Apple / local recogniser respectively. These are *two transcripts*, not a merged transcript's WER. Model size is decimal MB, excluding Apple's OS-managed assets. Local models request CPU+ANE; actual ANE utilisation and external Apple service CPU are not measured.

| Engine / mode | Median | p90 | Reference WER | Early | Words | Process CPU | Peak RSS MB | Model MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Apple Dictation (default) | 476 | 1513 | 5.82% | 1 | 288/288 | 6.2% | 62 | OS |
| Parakeet EOU 160 | 174 | 2542 | 21.23% | 0 | 288/288 | 15.9% | 328 | 224.0 |
| Both: Apple + EOU 160 | 171 | 645 | 5.82% / 21.23% | 1 | 288/288 | 21.0% | 332 | 224.0 |
| Apple SpeechTranscriber | 688 | 1290 | 15.07% | 0 | 288/288 | 4.4% | 62 | OS |
| Apple explicit 16 kHz | 477 | 1488 | 5.82% | 1 | 288/288 | 6.3% | 65 | OS |
| Apple started 3 s early | 475 | 1485 | 5.82% | 1 | 288/288 | 7.7% | 65 | OS |
| Parakeet EOU 320 | 540 | 2187 | 19.18% | 0 | 288/288 | 19.1% | 307 | 224.3 |
| Apple + EOU 320 | 423 | 822 | 5.82% / 19.18% | 1 | 288/288 | 16.5% | 109 | 224.3 |
| Unified 640 | 646 | 1976 | 18.84% | 0 | 288/288 | 18.4% | 107 | 608.5 |
| Apple + Unified 640 | 425 | 878 | 5.82% / 18.84% | 1 | 288/288 | 19.2% | 111 | 608.5 |
| Unified 320 | 444 | 809 | 18.15% | 0 | 288/288 | 38.8% | 715 | 608.3 |
| Apple + Unified 320 | 397 | 753 | 5.82% / 18.15% | 1 | 288/288 | 41.6% | 717 | 608.3 |
| Nemotron 560 | 427 | 2246 | 18.49% | 0 | 288/288 | 14.6% | 152 | 625.8 |
| Apple + Nemotron 560 | 338 | 757 | 5.82% / 18.49% | 1 | 288/288 | 13.9% | 157 | 625.8 |
| Nemotron 1120 | 908 | 4211 | 17.81% | 0 | 288/288 | 9.1% | 709 | 626.2 |
| Apple + Nemotron 1120 | 440 | 955 | 5.82% / 17.81% | 1 | 288/288 | 11.1% | 153 | 626.2 |
| Nemotron 2240 | 2098 | 8296 | 17.47% | 0 | 288/288 | 20.4% | 3120 | 626.9 |
| Apple + Nemotron 2240 | 467 | 1093 | 5.82% / 17.47% | 1 | 288/288 | 23.0% | 3313 | 626.9 |

**Decision:** propose **Both (Apple + EOU 160)** for the lead's default decision: 171 ms median and 645 ms p90 beat Apple's 476 / 1,513 ms with the same one flagged early advance. Leave Apple as the decoded and initial default. The result is from one short recording, with ASR-derived alignment and no camera encoding; it is not broad safety or real-studio certification. Both's forward-only behaviour is explicit in settings and CLI help.

**Additional option:** Parakeet Unified 320 ms trades a slower 444 ms median than EOU 160 for a much better 809 ms p90 and lower 18.15% reference WER (versus 21.23%). This qualifies as a different speed/accuracy trade-off, not Pareto dominance. Its shipping paired mode is 397 / 753 ms; the benchmark-only adapter measured 398 / 757 ms. Both new choices remain opt-in. Nemotron 560 plus Apple gives 338 / 757 ms and lower process CPU, but the original EOU pair is faster overall on this recording; adding every measured option would clutter settings without establishing a better default. Unified is selected for its stronger standalone p90 and reference accuracy. Larger Nemotron chunks add too much delay. No eligible 80/320 ms Nemotron Streaming 0.6B model was found.

**Run history and limits:** The first EOU 160 run overlapped compilation and measured 354 / 2,773 ms. The clean repeat measured 174 / 2,542 ms and is the table row. The first paired EOU run filled an 80-buffer queue and failed safely after ~37 seconds. The final queue is bounded at 1,024 buffers and throws on overrun; the complete repeat passed. This queue prevents short recognition stalls from losing audio, not an unlimited backlog. The first Nemotron 2240 load was stopped after four minutes waiting in Core ML/ANE model load. A second attempt loaded after 73 s but was stopped during diagnosis; the complete retry loaded after 16 s and supplies the table. Its >3 GB peak RSS includes model loading. No services were reset, no devices accessed, and no shared models changed. The Apple baseline test passed; its temporary shell wrapper emitted a parse error after completion while being edited, so that wrapper exit is not a test failure. Final JSON is the metric authority.

Machine-readable full results: `speech-engine-dual-results.json`. Experiment model pins: `speech-engine-experiment-models.json`. Shipping Unified 320 pins: `speech-engine-unified-model-manifest.json`, mirrored by `UnifiedModel.files`, exact revision `d32e972dd4315f1dc3f6be28fb2aab0ab3e80358`. 13 required files total 608,328,567 bytes, CC BY 4.0 attribution/licence bundled. The EOU model/pin is unchanged. Models remain on-demand and outside Git.

### Follow-up validation

- PASS Mac `swift build` and `swift build --build-tests` using `/tmp/vp-dual-build`.
- PASS generic iPad simulator build with `CODE_SIGNING_ALLOWED=NO`, `/tmp/vp-dual-ipad`; no simulator boot or app launch.
- PASS 66 focused tests (1 opt-in replay skipped): settings/default/CLI routes, revision identity, duplicate confirmation, seek watermark including a late first source, pause/resume stale generation, matcher regressions and seven frozen offline replays.
- PASS CLI generated MCP manifest contains `apple`, `parakeet`, `both`, `unified`, `both-unified`; Apple stays default.
- PASS whitespace checks. No models, WAVs or screenshots in the diff.
- NOT RUN visible UI, live microphone/camera, real iPad, encoding/thermal load, `test.sh`, `checks/ipad-link-e2e.sh`, or full suite. No push/merge/install.

Shipping-adapter confirmation: Unified 320 measured 444 / 809 ms, 18.15% WER, zero early, 288/288; Apple + Unified measured 397 / 753 ms, one early, 288/288. These replace the benchmark-only adapter rows above. Original adapter numbers are retained here for comparison (440 / 826 and 398 / 757 ms). Final standalone Unified CPU 38.8%, paired 41.6%, peak RSS ~715/717 MB. Full per-candidate traces remain in `/tmp/vp-dual-results`, not Git.

Final EOU paired shipping-adapter repeat: 171 / 645 ms, one early flag, 288/288; previous full run was 171 / 647 ms. Both independent transcripts retain 5.82% / 21.23% reference WER.

## Paired-default validation (15 November 2026)

- Full isolated Mac XCTest run: 1,176 executed, 98 skipped, zero failures (`/tmp/vp-pair-complete.log`). Focused engine checks: 12 executed, one opt-in replay skipped, zero failures.
- Generic iPad simulator build: succeeded, signing disabled, `/tmp/vp-pair-ipad`; no simulator was booted.
- Grid: 121 Swift source files passed. TestOffscreen and capture-permission guards remain unchanged.
- Light/dark snapshot verification was stopped during the first appearance at the lead's request to clear CPU for serial speech benchmarks. Resume this stage before final acceptance.
- Pair CPU/memory and real microphone recovery were not measured. The benchmark agent owns timed replay. Backup-selection tests cover policy and existing matcher tests cover independent sources; injected real-stream failure and a full downloader/network integration test remain unverified.
- Downloads resume at verified-file boundaries; an interrupted individual file restarts. Apple is kept warm, with candidates suppressed while both local streams are healthy, to avoid a recognition gap on failure.


## Lead review corrections (verification queued)

Warm Apple candidates now maintain their own matcher history while publication is disabled, so enabling backup mid-script does not begin from the generation's starting position. With Follow repeats enabled, two sources must agree on the same earlier word within one second, using audio newer than the published frontier. Apple-only fallback keeps normal single-source repeat handling. Late audio from before a confirmed rewind cannot restore the old position.

The paired path no longer changes the run state to uncertain for held matches. Nil Parakeet conversion output activates Apple backup and skips that buffer. Full model verification is cached by folder and manifest for this launch; subsequent starts check file sizes, and completed downloads refresh verification. Same-size external file changes are detected on the next launch.

Code and regression tests for these corrections are written but NOT RUN. The lead paused all builds/tests for latency measurement; resume is required before focused/full tests, pending snapshots, injected stream-failure verification and pair CPU/RSS measurements.
