# Presenter parity audit

Baseline: 8ae0abc. Scope update: A–C approved; D (bar layout) held for an approved mockup.

Each cell is before → after. “Unchanged” means deliberately held, not parity passed.

| Control | Mac presenter | iPad presenter | Mac iPad console |
|---|---|---|---|
| Camera picker | Local cameras; selection tick → unchanged | Mac/local cards without divider → named sections + divider | Mac cameras only; no tick → both devices + live tick |
| Microphone picker | Default/input/other sections → unchanged | Mac/local cards without divider → named sections + divider | Active side only, separate source buttons → both devices + live tick |
| Camera on/off | Split button → unchanged | Split button → unchanged | Split button → follows selected side |
| Mic on/off | Split button → unchanged | Split button → unchanged | Split button → unchanged |
| Mic meter | Optional live meter → unchanged | Live meter / picker meter → unchanged | Live meter → unchanged |
| Voice / manual mode | Presenter settings → unchanged | Reading mode controls → unchanged | Mode menu → unchanged |
| Start / pause / restart | Bar → unchanged | Bar → unchanged | Bar → unchanged |
| Previous / next passage | Keyboard → unchanged | Keyboard → unchanged | Buttons / keyboard → unchanged |
| Reading position | Text / scroll → unchanged | Text / scroll → unchanged | Slider / text → unchanged |
| Speed / countdown | Settings → unchanged | Mode controls / settings → unchanged | Speed visible, countdown More → unchanged |
| Script visible | Bar toggle → unchanged | Bar toggle → unchanged | No equivalent toggle → unchanged |
| Choose / send script | Library / Open → unchanged | Library → unchanged | Script menu / Send → unchanged |
| Edit script | Presenter edit → unchanged | Presenter edit → unchanged | No remote editing UI → unchanged |
| Zebras | Bar; long press adjusts → unchanged | Bar → unchanged | More → unchanged |
| False colour | Bar; long press adjusts → unchanged | Bar → unchanged | More → unchanged |
| Guides | Bar, squareshape.split.3x3 → unchanged | Bar, grid → unchanged | More (thirds / centre / marker) → unchanged |
| Zebra range / exposure mode / skin reference | Adjust panel → unchanged | No matching presenter adjustments → unchanged | No matching adjustments → unchanged |
| Guide style / frame marker | Adjust panel → unchanged | Library/settings → unchanged | More (thirds / centre / frame marker) → unchanged |
| Mic channel / input gain | Input menu / settings → unchanged | Picker channel / library gain → unchanged | No matching console controls → unchanged |
| Meter visibility | Mic menu → unchanged | Picker switch → unchanged | Always shown → unchanged |
| Auto-hide reading controls | Focus context menu → unchanged | Reading mode hides controls → unchanged | No matching option → unchanged |
| Exposure key | Bar → unchanged | Bar → unchanged | More → unchanged |
| Mirror / flip | Bar → unchanged | Bar → unchanged | More → unchanged |
| Clean screen | Bar → unchanged | Bar → unchanged | More → unchanged |
| Focus | Reading bar → unchanged | No matching mode → unchanged | No matching mode → unchanged |
| Text size / margins | Text/settings → unchanged | Text popover → unchanged | More, then text page → unchanged |
| Font family / weight | Settings → unchanged | Library settings; absent presenter popover → unchanged | Family in text page, no weight control → unchanged |
| Line / paragraph spacing | Settings → unchanged | Library settings; absent presenter popover → unchanged | More text page → unchanged |
| Reading line position | Settings → unchanged | Library settings → unchanged | More text page → unchanged |
| Colour / opacity / alignment / cues | Settings → unchanged | Library settings → unchanged | No matching controls → unchanged |
| Reading presets | Settings → unchanged | Library settings → unchanged | More text page → unchanged |
| Picture mode / quality | Local video/monitor → unchanged | Picker/settings → unchanged | More → unchanged |
| Recording | Mac recording controls → unchanged | Mac tally/status → unchanged | No matching recording controls → unchanged |
| Full screen | Native presenter → unchanged | Native iPad scene → unchanged | Default window → explicit primary full-screen, green button and native action |
| Connection / rename / forget | Separate iPad window → unchanged | Connection screen → unchanged | Device menu → unchanged |

The iPad ConfidenceMonitorView is a separate monitor surface: fit/fill, script line,
mirror, flip, Done, recording tally and connection status. It does not expose the
presenter’s camera/mic pickers, exposure tools or text controls. This remains a D gap.

No voice-latency or audio-capture implementation changes are included.

## Approved E: full screen

The console window opts into `fullScreenPrimary`, remains resizable, and routes
its green button to AppKit's `toggleFullScreen:`. AppKit owns the standard View
menu and Control-Command-F / Globe-F full-screen handling. The existing flexible
replica occupies remaining height and the transport/setup controls follow it at
the bottom. A 1920×1080 offscreen snapshot checks the expanded layout; tests inspect
window flags and the green-button selector without performing a screen transition.

## Compatibility and limits

Only optional fields were added to the Codable payloads. Destination-less camera
and microphone commands keep their prior Mac selection meaning. New local-iPad
commands are offered only when the iPad advertises its local lists. Protocol tests
cover old payload decoding and the older decoder ignoring the optional destination.

The picker ticks use iPad-reported state, including its echoed Mac status. They do
not update merely because a row was clicked. A missing or unplugged source is not
invented as a selectable entry. System-default microphone reporting resolves to a
real device ID so the tick can match the corresponding row.

An iPad local camera can be selected, but the current link has no reverse video
stream. The console labels that source instead of showing the unrelated Mac feed.
Physical device switching and native full-screen transitions need hardware checks;
this work deliberately performs neither on the user's screens.

## Representative snapshot paths

All paths below are relative to `artifacts/presenter-parity/`. Both phases use dark mode.
Device names and readings are deterministic fixtures, not hardware evidence.

| Surface | Before | After |
|---|---|---|
| Mac presenter | `before/mac-setup-1180x820.png` | `after/mac-setup-1180x820.png` |
| iPad presenter | `before/ipad/ipad-setup-1180x820.png` | `after/ipad/ipad-setup-1180x820.png` |
| Mac console | `before/ipad-paused-100.png` | `after/ipad-paused-100.png` |
| iPad camera picker | `before/ipad/ipad-picker-3A-1180x820.png` | `after/ipad/ipad-picker-3A-1180x820.png` |
| iPad mic picker | `before/ipad/ipad-picker-3B-1180x820.png` | `after/ipad/ipad-picker-3B-1180x820.png` |
| Console camera picker | Existing console surface above | `after/ipad-camera-100.png` |
| Console mic picker | Existing console surface above | `after/ipad-microphone-100.png` |
| Expanded console | Existing console surface above | `after/ipad-full-screen-100.png` |

These representative images are committed. The complete local harness output is
retained in the ignored `before/` and `after/` directories, with an inventory in
`SNAPSHOTS.txt`. Baseline iPad images were rendered from an archived 8ae0abc tree.
