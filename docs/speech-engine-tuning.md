# Speech engine tuning on recorded owner speech

15 November 2026. Base `21c97f9`, branch `t3/speech-engine-replay-tuning`. No release, install, push or product change.

## Method

Six non-overlapping excerpts, five minutes total, from the three documented owner readings. Two excerpts each from the canonical, Short 172 and Short 173 recordings. Original recordings are read-only. Source paths, SHA-256 hashes and ranges are recorded in the aggregate JSON. Excerpts and all transcripts exist only under `/tmp/vp-speech-corpus` during the experiment and are deleted at completion.

The original sources are not six independent speakers or sessions. Train on Short 173, reserve both canonical and Short 172 recordings for held-out checks. Splitting by source recording avoids training on an adjacent excerpt of a held-out recording.

Exclude C0019–C0033: their opening 25-second transcripts show interviews, quizzes, directions and multiple participants. Exclude `brief-audio.wav`: spoken editing instructions, not a script performance. Exclude `mac.wav` and `web.wav`: teleprompter product-review narration without evidence that the speaker is the owner. Exclude the 22-minute VoicePrompter demonstration: mixed app demonstration/reference material, not a verified additional owner reading. Do not count duplicate exports as independent recordings.

Reference: local whisper.cpp 1.9.5, `ggml-large-v3-turbo.bin`, English, full JSON, `-dtw large.v3.turbo -nfa`. Flash attention must be disabled explicitly: otherwise this build prints that DTW is unsupported and silently disables it. The JSON's DTW token anchors are grouped into words; start/end boundaries use the midpoints to neighbouring word anchors, capped at 150 ms from the word's first/last anchor. Punctuation does not extend the word. This avoids invalid negative-duration token offsets emitted at some segment boundaries. DTW anchors themselves are not word ends; these derived boundaries remain approximate. The transcript itself is the benchmark script, including spoken false starts. This tests following the recognised reading, not recovering the intended author's script through omissions or re-reads. Whisper text and word times are an imperfect proxy, not human annotation. Names, numbers, contractions and boundaries can be wrong. Do not interpret a small latency difference as decisive or call reference WER true accuracy.

The existing opt-in harness receives 16 kHz mono Int16 copies in ~33 ms buffers, paced against the monotonic clock. Each model configuration runs alone; the engines *within* a racing pair consume the same buffers concurrently. The real `SessionStore.acceptSpeechCandidate` publishes progress. Each source retains independent revision history. Strictly newer matched positions win, backward tracking is disabled for races. No microphone, camera, device capture, audio playback, visible windows or simulator.

Report pooled word-end-to-first-publication p50/p90/p99, coverage, existing early-advance flags, speech-active holds over 1.5 seconds, per-source reference WER, process CPU and process high-water RSS. A speech hold excludes silent gaps over 0.75 seconds. CPU means process user+system seconds divided by wall time; Apple service and ANE utilisation are outside that measure. RSS includes preparation and all previous clips in the process. Racing has two transcripts, not one fused transcript or single WER.

Swift release build with testability enabled:

```sh
swift package resolve --scratch-path /tmp/vp-tune-build
swift build --build-tests -c release --scratch-path /tmp/vp-tune-build -Xswiftc -enable-testing
```

Replay environment:

```sh
VP_SPEECH_AB=1 \
VP_SPEECH_AB_MANIFEST=/tmp/vp-speech-corpus/manifest.json \
VP_SPEECH_AB_MODEL=/tmp/vp-tune-models \
VP_SPEECH_AB_ENGINE='race-eou160+unified320' \
VP_SPEECH_AB_OUTPUT=/tmp/vp-tune-results/run1/race-eou160+unified320 \
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
DYLD_LIBRARY_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib \
zsh checks/run-xctest.sh /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
-XCTest PrompterCoreTests.SpeechEngineABTests/testRecordedAB \
/tmp/vp-tune-build/out/Products/Release/PrompterCoreTests.xctest
```

Manifest is a JSON array of `{id, audio, script, words:[{text,start,end}]}`. Legacy `VP_SPEECH_AB_AUDIO` remains supported. Model root contains `eou160`, `eou320`, `unified320`, `unified640`, `unified1120` directories. Each must contain the corresponding compiled encoder, decoder, joint and vocabulary. The test-only race adapter uses `race-<engine>+<engine>`, bounded fan-out, the existing production matcher and publication path. No `SpeechProvider` or `SessionStore` edit is needed.

Models: EOU revision `40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355`; Unified revision `d32e972dd4315f1dc3f6be28fb2aab0ab3e80358`. Downloaded from publisher paths pinned to these commits, verified against published LFS SHA-256 and size. Unified int8 tiers are distinct exported encoders `[70,2,2]`, `[70,7,1]`, `[70,7,7]`. FluidAudio 0.18.0, CPU+ANE. No shared FluidAudio cache access. See [upstream benchmark](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Sources/FluidAudio/ASR/Parakeet/Unified/benchmark.md) and [model variants](https://github.com/FluidInference/FluidAudio/blob/v0.18.0/Sources/FluidAudio/ASR/Parakeet/Streaming/ParakeetModelVariant.swift).

The revised schedule runs one paced pass per configuration, then repeats the best three configurations plus Apple and EOU160. Separate unpaced passes are for reference accuracy only: their candidate audio clock is not publication latency and must never be pooled with paced latency. Offline matcher/race/alias variants consume saved candidates without ASR reruns. Baseline offline output is asserted equal to SessionStore before accepting variant results.

## Results

All timed passes finished at **01:31:43 London, 15 November 2026**. The first Apple and EOU160 passes overlapped other agents' tests and are excluded from the headline latency comparison. Both were repeated cleanly. A `pgrep -fl 'xctest|swift-build|swift-frontend'` gate preceded each subsequent configuration. It waited from 00:16:04 to 00:20:51 (287 seconds), including offline work while a foreign test was still active. After the gate cleared, no other XCTest/compiler process was present at configuration starts. Background applications and OS services were not stopped.

The table below uses the clean baseline repeat, both runs of repeated contenders, and one pass for pruned contenders. Percentiles pool actual word samples, not per-clip percentiles. Early/stuck counts are per five-minute pass (mean count where repeated). Missing final words remain missing; they do not enter latency percentiles. Coverage counts published tokens, including skipped or early words, so it must be read with early/stuck counts.

| Configuration | Timed runs used | Median | p90 | p99 | Coverage | Early/pass | Stuck/pass | Reference WER (sources) | CPU | Peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| apple | 1 | 452 ms | 1057 ms | 2989 ms | 98.86% | 2 | 13 | apple: 11.33% | 4.7% | 64 MB |
| eou160 | 1 | 113 ms | 1722 ms | 7812 ms | 98.05% | 0 | 31 | eou160: 24.03% | 17.5% | 103 MB |
| eou320 | 1 | 505 ms | 1780 ms | 5306 ms | 98.51% | 0 | 24 | eou320: 18.99% | 7.2% | 103 MB |
| race-apple+eou160 | 1 | 117 ms | 597 ms | 1814 ms | 99.54% | 4 | 12 | apple: 11.33% / eou160: 24.03% | 14.8% | 107 MB |
| race-eou160+unified1120 | 1 | 114 ms | 964 ms | 1726 ms | 99.89% | 0 | 14 | eou160: 24.03% / unified1120: 4.69% | 18.2% | 134 MB |
| race-eou160+unified320 | 2 | 102 ms | 443 ms | 1576 ms | 99.66% | 1 | 7.5 | eou160: 24.03% / unified: 6.75% | 22.2% | 1166 MB |
| race-eou160+unified640 | 2 | 104 ms | 612 ms | 1390 ms | 99.54% | 0 | 10 | eou160: 24.03% / unified640: 5.72% | 19.6% | 134 MB |
| race-eou320+unified640 | 1 | 387 ms | 696 ms | 2218 ms | 99.43% | 0 | 9 | eou320: 18.99% / unified640: 5.72% | 13.1% | 134 MB |
| unified1120 | 1 | 937 ms | 1262 ms | 3119 ms | 99.89% | 0 | 15 | unified1120: 4.69% | 6.4% | 107 MB |
| unified320 | 2 | 329 ms | 532 ms | 1724 ms | 99.54% | 0 | 6 | unified: 6.75% | 13.2% | 779 MB |
| unified640 | 1 | 461 ms | 806 ms | 2664 ms | 99.31% | 0 | 15 | unified640: 5.72% | 6.7% | 106 MB |

The recommended pair versus clean Apple: median 104 vs 452 ms (348 ms quicker), p90 612 vs 1057 ms, p99 1390 vs 2989 ms, coverage 99.54 vs 98.86%, and zero vs two early flags. Against clean EOU160: similar median (104 vs 113 ms), p90 improves from 1722 to 612 ms and p99 from 7812 to 1390 ms; coverage rises from 98.05 to 99.54%, with 10 vs 31 stuck spans. Paired WER remains two independent measurements: EOU 24.03%, Unified640 5.72%; Apple is 11.33%. There is no fused recognition WER.

The pair used 18.3–21.0% of one core across runs (pooled 19.6%) and peak process RSS 131–134 MB. These are process measurements on this machine and warmed model execution, not total model residency. Unified320's first-load high-water memory was much higher. Other shared services, ANE use, thermal/power and video encoding were not measured.

## Recommendation

**EOU120M 160 ms + Unified0.6B int8 640 ms `[70,7,1]`, fastest strictly newer matched position wins.** Keep the existing independent per-engine revision history and no-backward rule, with no extra stability delay. Keep PhraseMatcher defaults: backward window 120, forward window 80, minimum backward evidence 4; all existing local-tail, onset and skip guards remain. The ordinary forward threshold is 0.68 (single-word 0.98), runner margin 0.05 (single-word 0.2), gap penalty 0.035 and distance penalty 0.002. Do not loosen these on this evidence.

This recommendation gives up about 175 ms of p90 versus the 320 ms pair, for zero early flags in both runs, a slightly better p99, and lower observed process high-water RSS. Its repeat medians are 104/105 ms, p90 612/614 ms, p99 1396/1390 ms. Coverage is 870/874 on each run, with ten stuck spans per pass. The 320 ms pair has 871/874 coverage but the same early flag on both held-out Short 172 runs. The reference is imperfect; zero flags does not prove zero false jumps, nor does that one flag prove a harmful jump. The pair choice is conservative under the requested accuracy constraint, not a universal ranking.

Use Apple as an explicit backup if the local pair cannot prepare; this experiment did not test a failure-triggered backup transition. Apple+EOU is a separate actively racing configuration and had four flags in its first pass. It is not evidence that passive Apple backup is unsafe.

Keep VoiceGlide unchanged (`catchUpSeconds=0.10`, `velocitySeconds=0.08`, `lead=1.0`, `paceWindow=3.0`, `jumpWords=12`, `jumpSeconds=0.08`, braking 60). It is downstream of synchronous publication and cannot improve the measured publication metric. These results do not validate visible scroll motion.

## Tuning and aliases

The offline pass reconstructs all 24 paced clip traces from the two repeated pairs. The baseline reproduces every SessionStore publication time exactly. The following table pools the two passes within each predeclared source split. Short 173 is tuning; canonical and Short 172 are held out. Latencies here are counterfactual replay of recorded delivery times, not fresh model timings.

| Recommended 640 pair | Split | Published | Early | Stuck | Median | p90 |
|---|---|---:|---:|---:|---:|---:|
| Baseline window 80 | Tune | 568/572 | 0 | 8 | 143 ms | 617 ms |
| Window 40 | Tune | 568/572 | 0 | 6 | 143 ms | 639 ms |
| Window 20 | Tune | 568/572 | 0 | 6 | 167 ms | 681 ms |
| Baseline window 80 | Held out | 1172/1176 | 0 | 12 | 89 ms | 611 ms |
| Window 40 or 20 | Held out | 1172/1176 | 0 | 12 | 86 ms | 583 ms |
| Max advance 4 | Tune | 518/572 | 0 | 8 | 131 ms | 596 ms |
| Max advance 4 | Held out | 146/1176 | 0 | 16 | 66 ms | 576 ms |
| Aliases | Tune | 568/572 | 0 | 8 | 131 ms | 591 ms |
| Aliases | Held out | 1172/1176 | 0 | 12 | 89 ms | 611 ms |

No matcher change is justified. Narrower windows trade lower held-out p90 for worse tuning p90; hard max-advance 4 destroys coverage. Max-advance 8 and 12 did not improve the recommended pair's paced traces. On the 320 pair, window 20 worsened tuning median/p90, and no tested window or max-advance limit removed its held-out early flag without serious coverage loss. Threshold constants are not exposed as knobs by the current matcher; rather than add product/test-only copies of its internals, the experiment varies its existing forward-window setting and the race's acceptance rule. It does not claim an exhaustive threshold search.

The 240-entry Talk & Read map was read-only. Offline aliasing normalises whole tokens, tries longest phrases first, and does not cascade a replacement into another rule. On this small corpus, aliases leave recommended-pair publication coverage, early flags and stuck counts unchanged. Tuning p90 falls 26 ms but held-out p90 is unchanged. On the 320 pair they remove two tuning stuck spans across both runs, but neither held-out early flag. This supports neither a latency claim nor a default-safety claim for aliases.

A separate transcript edit-distance check with case/diacritic/punctuation normalisation shows modest improvements on the same 874 reference words: EOU160 210 → 208 edits (24.03 → 23.80%), Unified320 59 → 56 (6.75 → 6.41%), Unified640 50 → 47 (5.72 → 5.38%), Unified1120 41 → 36 (4.69 → 4.12%). These are small reference-text gains, not evidence of improved following. Accent-only corrections already normalise away. No alias content or owner transcript is committed.

The timings were used to choose among the predeclared engine configurations, so the reserved recordings are a check against matcher overfitting, not a wholly unseen final engine-selection test. A larger, independently recorded owner corpus is still needed before calling this a general optimum.

## Validation and limits

- PASS release build with `-Xswiftc -enable-testing`; first attempt without it failed at existing `@testable` imports, not at a product change.
- PASS focused `SpeechEngineABTests`: ten ordinary tests, two opt-in skips. Includes new silence/stuck and whole-token/non-cascading alias tests.
- PASS eleven unpaced accuracy configurations; race retries used the unpaced test queue after its live 1024-buffer guard correctly rejected an immediate whole-file producer.
- PASS sixteen full paced configurations (96 clip replays). Eleven first-pass configurations and five repeats. The first two baseline passes are explicitly contaminated, not used in headline latency.
- PASS offline baseline reconstruction assertion before accepting tuning results; no product matcher constants changed.
- NOT RUN microphone/camera capture, encoding contention, hardware or visible UI, app installation, iPad, backup failure injection, human word-time labelling, long-session memory/thermal behaviour.

Five minutes of excerpts is a small corpus from three source recordings, not six independent performances. The transcript-as-script method removes the real product's mismatch between intended script and spoken false starts. It is useful for controlled engine comparison but cannot establish reread/skip behaviour against original scripts. English-only results do not support changing other languages.

CPU is not whole-system power or ANE usage; shared/service memory is outside RSS, and warmed compiled model caches can materially change observed RSS. The initial Unified320 and paired320 process peaks were 779/1166 MB, versus much smaller warmed runs. Do not treat the latter as a guaranteed deployment memory budget.

All original source files and the owner's vocabulary map are unchanged. No source audio, transcript, candidate text or model weight is committed. All task-owned temporary audio copies, Whisper references, and candidate traces were deleted after aggregation; source hashes were verified unchanged. Pinned model copies and the isolated build remain under `/tmp` only. No push, release, version change, installation or product edit.

Final report and cleanup completed approximately 01:38 London. The revised expected finish was 01:40; all timed work ended at 01:31:43, permitting other agents to resume before report completion.
