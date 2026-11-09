# Video Prompter Alpha redesign, review round 6 (Claude Opus 5.5)

Branch `claude/alpha-hud` at 62feefb. Read only. Evidence: my round 5 report, Sol's round 5 report, the diff a70ea1c..62feefb in `Sources` (4 files) and fresh captures in `/private/tmp/VideoPrompter-alpha-r6/` (9 Nov, 10:53 to 10:58, after the commit). I viewed `r3-detail-Advanced-100-top/lower`, `r3-detail-Advanced-200-lower`, `h2-advanced-upside-down-100`, `g1-landscape-1000-100`, `g1-landscape-1000-200`, `g1-landscape-1600-100`, `g1-setup-1000-150/200`, `g1-setup-1600-150`, `r13-presenter-key-200-dark` (against round 5), `first-launch-200-dark`, `h2-settings-Microphone-100` and `g2-guides-advanced-100`. Paths are relative to `Sources/VideoPrompter/`.

## Verdict

**All 19 areas are now 9 or above. There is no regression that costs a grade.**

- Settings rises from 8.5 to 9.
- All five polish items are fixed.
- The landscape risk is fixed.
- Sol's r13 overlap at 720 × 520, 200% is fixed.

One new blemish appears at 1000 × 700, 200%: the last setup pill is cut off. It is polish, not a grade loss.

## Round 5 findings: status

| Finding | Status |
|---|---|
| Settings 1: Advanced repeats the Guides cards, with "Advanced" inside "Advanced" | **Fixed.** `SettingsView.swift:684-685` now shows "Guide look" with Colour, Guide visibility and Frame shape. No guide cards and no second "Advanced" appear (`r3-detail-Advanced-100-top-dark.png`, `h2-advanced-upside-down-100-dark.png`). |
| Settings 2: Saved shoot setups and Permissions look unstyled | **Fixed.** Permissions are removed from the sheet, and they are still on the Microphone page. Saved shoot setups is a grouped form with a heading, dividers and a styled button (`r3-detail-Advanced-100-lower-dark.png`, `r3-detail-Advanced-200-lower-dark.png`). |
| Settings 3: Exposure key switch sits next to its label | **Fixed.** It is now a trailing switch (`SettingsView.swift:672-676`). |
| Polish: "False colour" touches its tile edges | **Fixed.** The label wraps onto two centred lines with side padding (`PresenterView.swift:444-446`; `g1-setup-1000-200.png`, `r13-presenter-key-200-dark.png`). |
| Polish: Dot/Cross has no track | **Fixed.** The buttons now sit in a segmented track (`g2-guides-advanced-100.png`). |
| Polish: first launch "Help ·" dangling dot | **Fixed.** The dots are gone and the spacing is wider (`first-launch-200-dark.png`). "Import file…" wraps to its own centred line, which is acceptable. |
| Polish: "MIC" heading on Settings > Microphone | **Fixed.** `showsHeading: false` (`h2-settings-Microphone-100-dark.png`). |
| Landscape gutter risk | **Fixed.** The gutter is capped at 25% of the width for landscape (`PresenterView.swift:80`). At 1000 × 700, 200%, the landscape frame is 500 of 1000 pt, up from about 360 estimated. It is 66% of the width at 1000 × 100% and 79% at 1600 × 100% (`g1-landscape-*`). The pills stay clear of the picture. |
| Sol R1: key overlaps "No camera chosen" at 720 × 520, 200% | **Fixed.** The column now scrolls and its children keep their real height, so the key and the status no longer overlap (`r13-presenter-key-200-dark.png` against round 5). |

## Grades

| Area | R5 | R6 | Remaining issue |
|---|---|---|---|
| First launch | 9 | **9** | None. |
| Library | 9 | **9** | None. |
| Editor | 9 | **9** | None. |
| Set up the shot | 9 | **9** | Polish P1 below: the last pill is cut off at 1000 × 200%. |
| Reading | 9 | **9** | None. |
| Clean | 9.5 | **9.5** | None. |
| Bar and tiles | 9 | **9** | None. Two-line "False colour" fits. "Back to start" is cut off at 720 × 520, 200%, as before; that is not charged to this diff. |
| Adjust panel | 9 | **9** | None new. Round 5's 60 pt top gap remains polish. |
| Zebras | 9 | **9** | None. |
| False colour and key | 9 | **9** | None. |
| Skin tone and grey card | 9 | **9** | None. |
| Mic meter | 9 | **9** | None. The "MIC" duplicate is gone. |
| Camera and shot | 9 | **9** | None. |
| Guides | 9 | **9** | None. Dot/Cross now has a track. |
| Settings | 8.5 | **9** | Polish P2 below: the Saved shoot setups card is inset differently. |
| Wording | 9 | **9** | None. |
| Accessibility | 9 | **9** | None. |
| Visual consistency | 9 | **9** | Polish P2. |
| Responsiveness | 9 | **9** | Landscape and 720 × 520 are fixed. Polish P1. |

## Polish (does not hold back a 9)

**P1. The last setup pill is cut off at 1000 × 700, 200%** (`g1-setup-1000-200.png`, "Turned right / for vertical" is cut mid-line by the bar).

- **Cause.** The round 5 build fitted the column only because it squashed the key button, which was the r13 overlap bug. The key now keeps its true height of 44 × 2 = 88 pt, so the column needs about 20 pt more than the stage gives it.
- **Effect.** It scrolls, but nothing shows that it does.
- **Fix.** At `PresenterView.swift:90`, change `.frame(minHeight: 44)` to `.frame(minHeight: 44 / controlZoom)`. The hit target stays 44 real points at every zoom, and the column gets about 44 pt back at 200%. Recheck `g1-setup-1000-200` and `r13-presenter-key-200`.

**P2. The Saved shoot setups card is inset differently** in the Advanced sheet (`r3-detail-Advanced-100-lower-dark.png`).

- **Cause.** The grouped `Form` adds its own margins. The card edge sits at x 88 against 48 for the Guide look card above it, and its heading at 108 against 48.
- **Fix.** At `SettingsView.swift:686`, add `.padding(.horizontal, -20)` to the `Form`. Or better, add `.contentMargins(.horizontal, 0, for: .scrollContent)`, so the card lines up with the Guide look card.

## What I did not check

I did no build, test run, app launch, VoiceOver or live camera or mic check. Grades come from the source diff and the 15 captures listed above. I also did not view light-mode captures or Settings > Advanced at 150%.
