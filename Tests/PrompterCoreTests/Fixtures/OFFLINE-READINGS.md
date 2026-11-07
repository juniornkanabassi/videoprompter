# Offline real-reading fixtures

`short-189`, `short-193` and `short-194` use Junior's final Markdown scripts and
raw A-roll from the read-only Shorts archive. The script files are copied without
editing. `*-offline-words.jsonl.deflate` contains raw DEFLATE (Foundation's `.zlib`)
JSON lines with `text`, `start` and `end` in seconds from the recording's start.
They contain Whisper's words, including mistakes, repetitions and ad-libs, not
corrected script text. Marked non-speech such as `*Clap*` is omitted.

These are deliberately **not** `*-reading.jsonl.deflate` files. The older 172/173
and canonical files contain real Apple recogniser candidates: replacement IDs,
generations, locales, revised text, audio ranges, wall-clock arrivals and final
word ranges. Their origin is the production-provider replay in
`SpeechSessionIntegrationTests`, documented by commits `73ada2a` and `5c2a9f2`.
They can measure recognition delivery lag. Offline Whisper timestamps cannot
reconstruct those arrivals, revisions or the second locale.

`OfflineWordReplayTests` feeds stable prefixes to the same `RecognitionTracker`
at each completed word's end, starting a new synthetic phrase after sentence
punctuation, a 1.5-second silence, or 24 words. This bounded, explicitly synthetic
input measures **matcher-only** lag, not live recognition or rendered scrolling.
Whisper word boundaries are estimates, sometimes zero-length or spanning a
pause. Tests use the existing LCS alignment and early-word check, including its
false-start/re-read allowances. Words absent from the transcript have no timing.
The 193 skipped-passages test deliberately removes recorded passages; it does
not claim Junior skipped them in that take.

## Rebuilding

1. Read the source drive only. Extract `0:a:0` from the A-roll movie using
   `ffmpeg -nostdin -i SOURCE -map 0:a:0 -vn -ac 1 -ar 16000 -c:a pcm_s16le TMP.wav`.
2. Run local `transcribe --names 'PLAYER NAMES' TMP.wav`. The wrapper lacks a word
   JSON option, so a temporary PATH shim for `whisper-cli` adds
   `--max-len 1 --split-on-word --output-json-full` to the normal invocation.
   It calls the installed binary, without changing `transcribe` or Apple Speech.
3. Run `python3 checks/make-offline-word-fixture.py TMP.json DEST.jsonl.deflate`.
4. Delete extracted audio, plain transcripts, JSON and the temporary shim. Keep
   provenance and test reports outside the repository in the design council folder.

All three use large-v3-turbo. For 194, the 42.5-second non-speaking lead-in is
trimmed before transcription and restored to every timestamp by passing `42.5`
as the converter's optional third argument. Both turbo and large-v3 hallucinated
text when given that lead-in; trimming it retained the full scripted reading.
No audio is played and no permission is requested during generation or replay.

194 has one explicit reference alignment correction in the test. LCS picks the
later, script-ordered retake for "official Champions League". The first attempt
already says "Champions League official". Those three reference times are pinned
to their first occurrences, with assertions on their text. This changes reference
timing only; the words fed to the matcher remain unedited.
