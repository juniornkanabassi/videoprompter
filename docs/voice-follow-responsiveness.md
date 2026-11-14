# Voice follow responsiveness

Base: `0f37099`. Headless investigation, 14 November 2026.

## Findings and changes

The remaining avoidable delay is chiefly after recognition. Local and relayed voice share
`SessionStore` and `VoiceGlide`. A partial result is matched and published synchronously;
there is no final-result gate, timed debounce or new multi-word agreement requirement.
The existing matcher can accept an immediate single word at the current position. Its
stronger evidence requirements for distant skips, repeated phrases and corrections remain
unchanged.

- Shared glide: catch-up time constant 150 → 100 ms. Velocity filtering remains 80 ms,
  acceleration remains capped at 90 words/s², braking remains 60 words/s² and the lead
  limit remains one word. This principally helps normal small updates; large bursts
  are still acceleration/braking limited.
- Mac colour updates: `updateReadState()` runs inside the representable update, before
  the deferred scroll/layout block. There is no additional main-queue turn before the
  current word becomes yellow. The highlight still means the next reading word, with
  confirmed words dimmed; it does not predict recognition.
- iPad scrolling: removed the second 80 ms offset filter from the continuous-position
  path. The session's voice glide already supplies smooth per-frame positions. Manual
  scrolling uses its continuous clock, and the drag-release settle remains. The discrete
  fallback (including Reduce Motion) retains its existing behaviour.

## Pipeline audit

| Stage | Before | After / finding |
| --- | --- | --- |
| Input tap request, Mac | 256 frames, 5.33 ms at 48 kHz | unchanged |
| Input tap request, iPad | 1,024 frames, 21.33 ms at 48 kHz | unchanged |
| Conversion | prior production replay retained 2.625 ms; about 1 ms p90 work per 100 ms chunk | conversion regression rerun; no changes |
| Recognition | prior independently timed natural replay: 400 ms median, 724 ms p90 | unchanged; not remeasured with live audio |
| Matching/publication | synchronous partial acceptance; prior replay about 1 ms p90 (13.36 ms on longer natural replay) | thresholds and decisions unchanged |
| Mac highlight | SwiftUI delivery, then one extra main-queue turn | SwiftUI delivery only; no scroll wait |
| Relay | one main-actor turn coalescing, then transport | unchanged; latest word bypasses queued video |
| iPad receive | main actor, validity checks, synchronous `followRemote` | unchanged; 100 ms meter and 200 ms state throttles do not gate follows |
| Display scheduling | next refresh, nominal 0–16.7 ms at 60 Hz / 0–8.3 ms at 120 Hz | unchanged |
| iPad extra offset filter | 80 ms time constant after voice glide | removed for continuous positions |

Requested tap sizes are not measured hardware callback sizes. Neither recognition nor
network/display scanout timing can be inferred from deterministic replay. No live input,
permission prompt, visible app, Simulator boot, installation or keychain operation was used.

## Validation

The response measure is 90% of the guide's destination after an accepted partial, excluding
recognition. Mac uses the production AppKit coordinator; the iPad figure models its
continuous offset application, not UIKit or a physical display. Recorded matcher traces
retain their existing no-ahead-word, end-of-script, smoothness and lead-limit assertions.

### Measured response

Milliseconds to 90% of the destination, at 60 Hz:

| Input | Mac before | Mac after | iPad model before | iPad model after |
| --- | ---: | ---: | ---: | ---: |
| One-word glide step (pure core test) | 267 | 200 | not measured | not measured |
| Three-word partial through SessionStore and AppKit | 317 | 267 | 400 | 267 |
| Twelve-word partial through SessionStore and AppKit | 567 | 567 | 650 | 567 |

At 120 Hz, the three-word partial changes from 308/400 ms (Mac/iPad model) to
275/275 ms, and the twelve-word partial from 575/667 ms to 575/575 ms.
The new unique-first-word integration fixture also reaches its one-word destination
in 200 ms at 30, 60 and 120 Hz. Its original repeated opening word was correctly
held by the ambiguity guard; the fixture was corrected rather than weakening matching.

The unchanged recorded candidates give these added scroll-lag medians/p90s:

| Recording | Before | After |
| --- | --- | --- |
| Canonical | 60 / 230 ms | 30 / 230 ms |
| Short 173 | 50 / 200 ms | 30 / 190 ms |
| Short 172 | 30 / 230 ms | 20 / 230 ms |

All three remain below 30 stops/minute and 100 words/s² p99 acceleration. Measured
stops/minute before → after are 14.0 → 14.6, 6.8 → 8.5 and 12.2 → 12.6 respectively;
p99 acceleration is 90 before and after. Worst burst deceleration remains below
100 words/s² at 60/120 Hz, with zero lead-clamp entries. The remaining large-burst
response is the cost of retaining these motion bounds.

The new native highlight regression forces a layout pass without yielding to the
main queue. It fails against the original `ScriptTextView` (still highlights `alpha`
after `golf` becomes current), and passes with the change. A separate relay test
checks that `followRemote` publishes current/confirmed words synchronously while
scrolling has not caught up, and still rejects an out-of-range word.

Hosted offscreen text timing is noisy rather than a proven wall-time improvement:
publication-to-detected-highlight median was 11.8 ms before / 12.1 ms after without
exposure, 12.3 / 12.0 ms with synthetic exposure. Those loops poll every 5 ms and
paint offscreen; they do not resolve a main-queue turn or measure photons. The
regression above proves removal of the extra turn. Match-work medians are about
3.4–3.6 ms in both runs. Conversion retains exactly 2.625 ms from 10 seconds of
input in both runs; total conversion work was 139 / 123 ms, without a converter change.

### Commands and evidence

- `swift build -j 4`: PASS, `/tmp/vp-follow-build.log`.
- Baseline `swift test --filter ...`: 60 tests, one optional external replay skipped,
  zero failures, `/tmp/vp-follow-before.log`.
- Final full selection: 91 tests, one optional external replay skipped, zero failures,
  `/tmp/vp-follow-final.log`. Includes 29 recognition-safety tests, seven offline
  word replays, six speech-log tests, 39 relay/transport tests and ten latency/render/glide tests.
- Final focused checks: 10 tests, zero failures, `/tmp/vp-follow-final-focused.log`.
- Original-renderer regression check: expected failure, `/tmp/vp-follow-highlight-before.log`.
- Generic iPad build with signing disabled: PASS, `/tmp/vp-follow-ipad.log`.
  Command: `xcodebuild -project iPad/VideoPrompter.xcodeproj -scheme VideoPrompter -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/vp-follow-ipad-69e2 -jobs 4 build CODE_SIGNING_ALLOWED=NO -quiet`.

No `checks/ipad-link-e2e.sh`, live recognition, physical display/network measurement,
or full unrelated suite was run. Real-device reading remains the check for perceived
responsiveness and thermal/render contention.
