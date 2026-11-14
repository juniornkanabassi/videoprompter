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
- Only one engine consumes the existing capture stream at a time. `SpeechProvider.start` delivers both to `SessionStore.acceptSpeechCandidate`; matcher, backward/false-advance guards, glide and iPad relay are unchanged.
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
