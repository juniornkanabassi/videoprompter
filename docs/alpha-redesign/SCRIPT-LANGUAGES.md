# Script languages, Alpha 2.6.0 (71)

## Investigation and implementation

| Area | Previous assumption | Change |
| --- | --- | --- |
| Voice engine | The app uses SpeechAnalyzer with DictationTranscriber. Automatic used unconstrained dominantLanguage and failed on empty text; explicit UI choices favoured English, French and Mixed. | Seven supported script languages, constrained NaturalLanguage detection, confidence and minimum-length fallback to English. Keep English at en-GB unless an explicit regional choice was saved. For other languages, prefer a supported locale matching the Mac's region, then the language's default region. |
| Speech assets | Preparation already downloaded missing assets, but the language was unclear. | Settings reports whether local speech files are ready, need downloading, or the language is unavailable. Preparation names the language; failures remain visible. DictationTranscriber runs on device, with no SFSpeechRecognizer authorisation request. |
| Settings | Language lived under Microphone, missing legacy values decoded as Mixed. | One persisted global Script language in Reading. Automatic is the default. Existing supported locale identifiers migrate to language names with the explicit regional identifier retained alongside; Mixed migrates to Automatic. Reading presets continue preserving the user's language. No per-script schema change. |
| Script tokens | Unicode letters, combining marks and punctuation were supported, but apostrophes joined elisions. | Preserve the English tokeniser. French and Italian recognise spaced elision prefixes as the equivalent apostrophe form while retaining exact source ranges and original written word indices. Spanish inverted punctuation already works. German compounds remain intact. |
| Normalisation | Fixed en_GB case, width and diacritic folding. | Retained deliberately: this locale-independent matching key already folds accents, umlauts and sharp s correctly in the seven supported languages. Tests cover these cases. |
| Numbers | English single-word spellings 0–99 and first/second/third, plus English year shortening. | Preserve those English rules exactly. Other languages use NumberFormatter spellOut to expand integer tokens in both scripts and heard speech, including multiword spellings, with each expanded token pointing to the written number. English contractions, percent and shortened-year exceptions run only for English. |
| Matching confidence | English/French filler list and an additional fixed filler check in RecognitionTracker. | Per-language filler lists in both paths. Matcher language travels with the session, including after edits and settings changes. |
| Contextual phrases | Unicode alphanumeric words, preferring capitalised adjacent pairs. | Already language-compatible; unchanged, passed to the selected language's dictation module. No English abbreviation expansion exists beyond the listed matching exceptions. SpeechProvider.prepare retains its legacy default locale pair for existing replay callers; the application always passes its resolved single locale explicitly. |
| Reading pace and counts | Manual speed is a user-selected number of tokens per minute; no language-specific duration estimator exists. Library counted default English tokens. | Library and session now count the same language-aware spoken tokens, including spelled-out numbers. Keep the user's chosen pace rather than imposing an average for a language. |
| Layout | Native Unicode text layout, wrapping and source-range highlighting; no English hyphenation dictionary or forced English layout locale. | Retained. Expanded numbers and elisions preserve source positions. No automatic hyphenation is enabled. |
| Status and controls | Voice readout omitted language; control protocol documented English/French/Mixed. | Existing Voice readout includes the active language; control help lists the seven choices. No new presenter control. |

## Safety and scope

All verification uses the existing TestOffscreen guards and disposable defaults/libraries. No app launch, live microphone capture, speech authorisation request, camera prompt or audio playback is needed. Availability inspection reads supported and installed locale lists only; it does not download speech assets.

English replay fixtures and replay test sources are unchanged. The legacy missing-setting test now expects Automatic, as required by the new default.

## Local availability, 9 November 2026

Read from DictationTranscriber.supportedLocales and installedLocales, without starting recognition.

| Language | Selected locale | On-device support | Files installed |
| --- | --- | --- | --- |
| English | en_GB | Yes | Yes |
| Spanish | es_ES | Yes | No |
| French | fr_FR | Yes | Yes |
| German | de_DE | Yes | No |
| Italian | it_IT | Yes | No |
| Dutch | nl_NL | Yes | No |
| Portuguese | pt_PT | Yes | No |

## Initial implementation verification

Ran the required command with no live app launch:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VIDEOPROMPTER_TEST_SCRATCH=$TMPDIR/vp-sol-lang zsh test.sh
```

- Main suite: 888 tests, 81 skipped, zero failures.
- Light snapshots: 54 tests, one skipped, zero failures.
- Dark snapshots: 54 tests, one skipped, zero failures.
- Grid: PASS, 96 Swift source files across Mac and iPad.
- Existing Replay_*_Tests, OfflineWordReplayTests and SpeechLogReplayTests pass unchanged.
- Eight new language tests pass, including seven-language detection, fallback, regional selection, persistence through an AppStore reload, accents/elisions/source ranges, Spanish/French number spell-out, local asset availability and a short Spanish offline replay.
- The old missing-setting test now expects Automatic, and the settings structure test expects Script language in Reading rather than Spoken language in Microphone.
- The existing mixed English/French regression and fractional manual-speed test pass unchanged after preserving apostrophe tokens and fractional scroll position.

The requested offscreen PNGs are retained and visually checked at 1100 × 1000:

- `artifacts/script-languages/script-language-automatic.png`
- `artifacts/script-languages/script-language-spanish.png`

Their companion JSON files record the offscreen renderer and invisible-window state. Live microphone recognition was not run. No speech assets were downloaded during verification. No build.sh, installation, push or pull request was performed.

## Language review fixes

- Filler sets are constructed once. Detection ignores production notes, stage directions and URLs, and uses a bounded content-revision cache. Session updates resolve once; the inspector shares that result within a render. The live editor counts using the last saved revision's cached language without running detection per keystroke.
- All seven language names and their locale identifiers share the CLI/settings validator. Legacy Mixed becomes Automatic; unsupported language codes become Automatic on migration and are rejected by the CLI. Explicit regional identifiers are retained per language, including across settings saves. English defaults to en-GB regardless of the Mac region.
- Positions retain UTF-16 source offsets, with legacy token-index fallback. Language switches remap and clamp confirmed progress. Number anchors use their actual index within the block.
- Non-English grouped integers and common spoken forms of one normalise together. Elision joins spaces and tabs only.
- Apple documents a device-dependent per-app reservation cap in [maximumReservedLocales](https://developer.apple.com/documentation/speech/assetinventory/maximumreservedlocales). [reserve(locale:)](https://developer.apple.com/documentation/speech/assetinventory/reserve(locale:)) throws if the cap would be exceeded. The installed SDK exposes both APIs and release(reservedLocale:). After stopping the old analyser, preparation releases reservations outside the new locale set before reserving it, with a clear storage-limit message. No speech assets were downloaded for this review.

## Review verification, 10 November 2026

Required full run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VIDEOPROMPTER_TEST_SCRATCH=$TMPDIR/vp-sol-lang2 zsh test.sh
```

- Main suite: 895 tests, 81 skipped, zero failures.
- Light snapshots: 54 tests, one skipped, zero failures.
- Dark snapshots: 54 tests, one skipped, zero failures.
- Final focused ScriptLanguageTests run, including the region-only position regression: 15 tests, zero failures.
- Grid and all 19 Python safety/runner checks passed. English replay fixtures and tests remain unchanged and pass.
- The initial full run exposed excess anchor scanning in the 5,000-word benchmark. Computing the block start from preceding block counts fixed it; the original performance limit passed both alone and in the final full run. No threshold was relaxed.
- The known slow-socket test failed in the initial run, then passed alone and in the final full run. The folder regression passed in both full runs.
- No review finding was skipped. Repeated filler-set construction was confirmed; a claim of asymptotically quadratic behaviour was not established.
- Version remains 2.6.0 (71). No app was opened, no speech assets were downloaded, and no installation, push or pull request was performed.
