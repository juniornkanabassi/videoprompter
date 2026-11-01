# Review guide

How to review changes to Video Prompter. The shared rules (lanes, check results, finding format, the three-round checkpoint, approval of an exact revision) are in the owner's JuniorOS `03 Skills/Review workflow.md`. This file holds only what is specific here. Severity is Important, Nit (at most three, never blocking) or Pre-existing. Start the summary with the count. 0 findings is a valid result.

## Failure here means

- Voice follow drifts, jumps or stalls on recorded speech it handled before.
- A camera or device failure crashes the app or loses a take.
- A script library or iCloud copy is lost, duplicated or overwritten.
- The iPad link or remote control accepts commands from outside its boundary.
- A headless command shows a window or a Dock tile.

## Always High

Library and iCloud storage, remote control and the iPad link, recording, `release.sh`, `install.sh`, `checks/package-dmg.sh`.

## Always check

- Voice-follow changes are replayed on recorded audio, never the live mic.
- Device-missing and permission-denied paths fail safely.

## Check results

Last results on 1 Nov 2026, revision `337e9a8`. `.github/workflows/fast-checks.yml` runs `test.sh` and the source-ignore check on pull requests (macOS 26, read-only, no secrets); it has not run on GitHub yet. Report every check you run as PASS, FAIL, NOT RUN or NOT APPLICABLE with the revision.

| Command | Proves | 1 Nov |
|---|---|---|
| `zsh test.sh` | the whole XCTest suite (`swift test` does not discover it) | PASS, 414 (7 skipped by the suite) |
| `python3 checks/check-built-app.py`, `checks/check-headless.py` | built bundle on disposable data, headless start | NOT RUN (need a built app) |
| `zsh checks/ipad-link-e2e.sh` | Mac to iPad link on a headless simulator | NOT RUN |
| `zsh checks/check-source-ignore.sh` | nothing private is tracked | PASS |

## Skip

`Resources/` media, `docs/` images.

## Known gaps

Window and camera checks that need a display or hardware are recorded as owed in memory.
