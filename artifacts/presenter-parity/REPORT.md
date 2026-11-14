# Presenter parity and rotation

Base: `8ae0abc`. Branch: `t3/presenter-ui-parity`.
Approved layout: `2026-11-14 Presenter parity mockup.html` in the Video Prompter Outputs folder.

## Control parity

The setup bar uses the same shared `PresenterSetupBar`, `BarGroup`, `BarDeviceControl`,
`BarToggle`, turn controls and live-meter treatment. One row is used when it fits;
otherwise transport/devices and picture/view tools occupy two rows. At large
accessibility sizes, the existing wrapping layout keeps controls inside the window.

| Control | Mac presenter | iPad presenter | Mac iPad console |
|---|---|---|---|
| Start reading / Back | Row 1 | Row 1 | Row 1 |
| Camera / Mic / live level / Script | Row 1 group | Row 1 group | Row 1 group |
| Zebras / False colour / Guides | Row 2 group, direct buttons | Same | Same; removed from More |
| Mirror / Flip | Row 2 group | Same | Same; removed from More |
| Text | Row 2, opens settings | Same, font/size/speed/margins | Same, font/size/speed/margins |
| Key / Clean | Row 2 | Same | Same; removed from More |
| iPad switcher | App menu | Connection screen | Far left of row 1 |
| Reading status / Pause / Set up / Focus | Existing reading controls preserved | Equivalent reading controls | Equivalent reading controls |
| Microphone while reading | Existing reading options | Reading options | Reading options with live level |
| Camera rotation | Rotate menu, 0/90/180/270 | Rotate menu for current source | Rotate menu for current source |
| Camera/mic picker sections | Local inputs in standalone presenter | Named Mac and iPad sections, divider | On this Mac / On named iPad, divider |
| Selection ticks | Local live configuration | Active source | iPad-reported state, not the last click |
| Camera on/off | Own camera | Current source | Current source |
| Microphone on/off | Own microphone | Current source | Current source / relay |
| Font / text size / margins / speed | Text settings | Text popover | Text popover |
| Line/paragraph spacing / presets / countdown | Existing settings | Existing library/settings | Text popover |
| Detailed exposure adjustments | Tool long-press/context menu | Existing settings | Direct toggles; guide details in context menu |
| Picture mode / link quality | Local camera settings | Existing picker/settings | Camera picker |
| Full screen | Existing native presenter | Native iPad scene | Primary full-screen window and standard AppKit action |

### Baseline → final audit

This records the full audit, including deeper controls outside the approved bar
layout. “Retained” means the existing behaviour remains; it does not claim the
settings panels are identical.

| Control | Mac presenter: before → final | iPad presenter: before → final | Mac console: before → final |
|---|---|---|---|
| Camera picker | Local list → retained, Rotate menu | Unseparated device cards → named sections/divider, Rotate menu | Mac-only list → both devices, live tick, Rotate menu |
| Mic picker | Local/default sections → retained | Unseparated device cards → named sections/divider | Separate source buttons → both devices, live tick |
| Camera / mic on-off | Split buttons → retained | Split buttons → retained | Split buttons → selected-source routing |
| Live mic level | Optional meter → shared level treatment | Live/picker meter → shared level treatment | Live meter → shared level treatment |
| Start / pause / restart | Bar → retained reading bar | Bar → shared setup + equivalent reading controls | Bar → shared setup + equivalent reading controls |
| Status / Focus / Set up | Reading controls → retained | No matching Focus → equivalent reading controls | No matching Focus → equivalent reading controls |
| Script visibility | Bar → device group | Bar → device group | Missing → device group, linked state |
| Choose / send script | Library/Open → library | Library → retained | Script menu/Send → retained outside setup bar |
| Edit script | Presenter editor → retained | Presenter editor → retained | No remote editor → retained limitation |
| Zebras / false colour | Bar → shared row 2 | Bar → shared row 2 | More → shared row 2 |
| Guides | Bar / different icons → shared row 2 icon | Bar / different icon → shared row 2 icon | More → shared row 2 icon |
| Mirror / flip | Bar → shared row 2 | Bar → shared row 2 | More → shared row 2 |
| Exposure key / Clean | Bar → shared Key/Clean | Bar → shared Key/Clean | More → shared Key/Clean |
| Font family / size / margins | Settings → Text | Size/margins only → Text also includes font | More/text page → Text |
| Voice / automatic mode | Settings → retained | Reading controls → Text | Mode menu → Text |
| Speed | Settings → retained | Mode controls → Text | Visible → Text |
| Countdown / presets | Settings → retained | Library/settings → retained | More → Text |
| Line / paragraph spacing | Settings → retained | Library/settings → retained | More/text page → Text |
| Font weight | Settings → retained | Library settings → retained | Missing → still absent |
| Reading line position | Settings → retained | Library settings → retained | More/text page → Text |
| Text colour / opacity / alignment / cues | Settings → retained | Library settings → retained | Missing → still absent |
| Zebra range / exposure mode / skin reference | Adjust → existing settings/context controls | No matching presenter adjustments → retained limitation | No matching adjustments → retained limitation |
| Guide style / frame marker | Adjust → existing controls | Library/settings → retained | More → Guides context menu |
| Mic channel / gain | Input/settings → retained | Picker/library → retained | No matching controls → retained limitation |
| Meter visibility | Mic menu → retained | Picker switch → retained | Always visible → retained |
| Auto-hide reading controls | Focus context → retained | Reading hides controls → Focus equivalent | Missing → Focus equivalent |
| Picture mode / link quality | Local video/monitor → retained | Picker/settings → retained | More → Camera picker |
| Previous/next passage | Keyboard → retained | Keyboard → retained | Buttons/keyboard → retained |
| Reading position | Text/scroll → retained | Text/scroll → retained | Slider/text → retained |
| Rotation | Local camera → retained | Missing → local/linked source Rotate menu | Missing → linked source Rotate menu |
| Recording | Mac recording controls → retained | Mac tally/status → retained | No recorder controls → retained limitation |
| Full screen | Native → retained | Native scene → retained | Default window → fullScreenPrimary + native action |
| Connection / rename / forget | Separate iPad window → retained | Connection screen → retained | Device menu → far-left switcher |

The Mac's reading-state layout was not replaced. The iPad confidence monitor retains
its specialised tally, fit/fill and script-line controls; its picture geometry now
honours camera rotation. Recording controls and library editing remain on their
existing surfaces.

## Link and rotation behaviour

Only optional Codable fields were added. Destination-less device commands preserve
their original meaning. Old peers retain the basic iPad microphone fallback.

The Mac keeps encoded frames in sensor coordinates and sends its chosen rotation
as optional status metadata. The iPad applies that rotation to both the decoded
picture and exposure layers, and draws guides on the rotated picture bounds. Local
iPad camera rotation composes with the built-in camera's horizon orientation.
Mirror and flip remain display transforms. Shared geometry and iPad layer tests
cover all quarter-turns, mirroring, flipping, zebras and false-colour alignment.

Picking a Mac mic uses the existing relay path. Picking an iPad mic stops the relay.
The camera and microphone ticks come from the state reported by the iPad, including
its echoed Mac status. System-default microphone selection resolves to a device ID.

## Evidence

Dark-mode, offscreen output lives in `final/`; baseline output remains in `before/`.
`SNAPSHOTS.txt` lists absolute paths. Key files (relative to this directory):

| Surface | Before | Final snapshot |
|---|---|---|
| Mac setup | `before/mac-setup-1180x820.png` | `final/mac-setup-1180x820.png` |
| Mac reading | See setup baseline | `final/mac-reading-camera-1180x820.png` |
| iPad setup | `before/ipad/ipad-setup-1180x820.png` | `final/ipad/ipad-setup-1180x820.png` |
| iPad reading | See setup baseline | `final/ipad/ipad-reading-camera-1180x820.png` |
| Console setup | `before/ipad-paused-100.png` | `final/ipad-paused-100.png` |
| Console reading | See setup baseline | `final/ipad-connected-reading-100.png` |
| Expanded console | See setup baseline | `final/ipad-full-screen-100.png` |
| Console camera / mic menus | See setup baseline | `final/ipad-camera-100.png`, `final/ipad-microphone-100.png` |
| iPad rotation | Not supported | `final/ipad/ipad-rotation-0.png`, `90`, `180`, `270` |

Fixtures use deterministic device names, levels and reference pictures. They prove
rendered layout and transforms, not physical camera or microphone performance.
Representative final images are committed; bulk harness images remain ignored.

## Verification

Implementation commit: `0a9cb56`. The final evidence commit also aligns the iPad Start reading label and updates the obsolete Adjust-button test expectation.

| Check | Result |
|---|---|
| Focused UI regression | 46 passed |
| Compact controls and stage-space regression | 8 passed |
| iPad full test harness | 12 passed, including rotation/overlays and smooth scrolling |
| Generic iOS Simulator build | Passed |
| End-to-end link harness | 5 passed, including rotation and presenter-state round trips |
| Final full `./test.sh` | PASS: 1115 executed / 92 skipped / 0 failures; light and dark snapshot passes each 61 executed / 1 skipped / 0 failures; grid passed |

The final full script exited 0 (`/private/tmp/parity-final-all-v3.log`). Final iPad
image refresh passed after the last source edit (2 tests); the generic simulator
build was then repeated successfully. Earlier WIP test totals are historical only.

## Limits

No visible app window, Simulator window, permission prompt, sound, push or release
was used. Native full-screen entry and physical camera/microphone switching remain
unverified. The link still does not send the iPad's local camera video back to the
Mac: the console names that source rather than showing an unrelated Mac picture.
