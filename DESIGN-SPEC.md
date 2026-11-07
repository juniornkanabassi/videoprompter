# Video Prompter design spec

Written 6 November 2026 against branch `claude/2.1.1` at `64f5e6d`. It replaces patch lists from earlier review rounds. When a later finding seems to conflict with this spec, change the spec first, then the code. Do not move a control without updating the table in section 2.

Paths are relative to `Sources/VideoPrompter/` unless they start with `Tests/`, `docs/` or `checks/`.

## Final presenter footer, frozen 7 November 2026

This is the lead-authorised final footer. It supersedes every earlier footer and output-line amendment below. Only defects may change it. The three-band layout is checked by `FinalFooterTests` and the `fable-bar-*` snapshot fixtures. No reading or recording action starts the other.

```text
720 × 520, all sizes (controls scale fully)
┌─────────────────────────────────────────────────────────────────────┐
│ [Start reading] [Back to start]                      [● Record]     │ Transport
│ Automatic scroll · Ready ⌄      Ready · Portrait 1080 × 1920 › Tools⌄│ State
│ ✓ Guides       Exposure check       Switch camera                  │ Context
└─────────────────────────────────────────────────────────────────────┘

Recording: [Pause] [Back to start]             [Stop recording]
           Automatic scroll · Scrolling ⌄    ● REC 01:24 ▮▮  ›  Tools⌄
                                             Receiving sound
           ✓ Guides  Exposure check  Switch camera (disabled)

Saved:     same transport and state bands
           ✓ Guides       Exposure check       Switch camera        ✓ Saved 1:24 ›
           (Last take opens the receipt: file, Play, Show in Finder, Hide)

Problem:   same transport and state bands
           Saved with problems My Script … .mov · 1:24 [Review] [Show in Finder] [×]
```

A clean saved take keeps the Picture row (round 19) and adds a Last take opener at its trailing edge: a checkmark, Saved and the duration. The duration is dropped first when the row is short of width; the three picture checks never shrink. The opener's popover holds the full receipt. Saved with problems and a failed take keep the full receipt row in place of the Picture row until Hide, so the warning stays prominent. The receipt stays in one row at the minimum width, instead of the proposed second action line, to honour the 65% reading floor. Only its filename may middle-truncate; its full path is the help and accessible value. Actions, receipt state and duration never truncate. Saved with problems keeps its full state label; its complete diagnosis is in Review, help and the accessible description. Hide restores the Picture row. Last take in Tools opens details; Prompter > Last Take reveals the most recent file. A new recording shows the Picture row and retains the prior receipt in Last take until the new result replaces it.

| Budget at 720 × 520 | 100% | 150% | 200% |
|---|---:|---:|---:|
| Transport target height | 24 pt | 36 pt | 48 pt |
| State, maximum two text lines | 32 pt | 48 pt | 64 pt |
| Context target height | 24 pt | 36 pt | 48 pt |
| Remaining padding allowance | 0 pt | 0 pt | 0 pt |
| Maximum footer budget | 80 pt | 120 pt | 160 pt |
| Reading area minimum without exposure | 440 pt | 400 pt | 360 pt |
| Exposure strip target height | 24 pt | 36 pt | 48 pt |
| Clear upper area with exposure | 416 pt | 364 pt | 312 pt |

The hard gate for the footer state matrix without exposure is ≥65% reading height (338 pt at 720 × 520). With the exposure strip enabled, the clear area above the strip and footer must remain ≥60% (312 pt), including waiting/ready camera, active recording and saved-take states at 200%. The strip retains a fully scaled 24 pt Key target without extra vertical padding; the footer has no bottom padding. Start and Back to start have an 8 pt unscaled gap. Record is trailing. The state controls are unboxed, use full mode names and chevrons adjacent to their words. The recording meter shares the timer line; health is the second line. Neutral camera status and secondary picture actions use the contrast-aware quiet foreground. Context alone may recede to 75%. The last 48 pt of reading glyphs fade into the footer; the scroll area's height is unchanged.

State band weight and wrapping (round 19 defect fix, lead authorised): the mode name and active recording or recovery state are semibold; neutral camera status and Tools are regular callout text; the changing reading state and the output detail (Portrait 1080 × 1920) are regular. The output check is sized first, then the reading status, then the spacer, so neither wraps unless the band truly cannot hold it. Up to 150% the band is one line in every camera state; at 200% in the minimum window it may use two lines (the mode above its state as whole words, or the output check wrapped), never three. `FinalFooterTests` measures both status controls against these line limits.

| Reading state | Transport | State |
|---|---|---|
| Before first start | Start reading | Ready |
| Countdown | Cancel (AX Cancel countdown) | Starts in N |
| Active | Pause | Following / Listening / Scrolling |
| Paused | Start reading | Paused |
| End | Read again | End of script |
| Editing | Save changes · Cancel editing | Editing · not saved yet |
| Clean view | Transport retained | Clean view |

| Recording state | Trailing state button opens |
|---|---|
| Ready · Portrait/Landscape/Square · width × height | Before recording check |
| Waiting for picture | Check with explicit unknown resolution |
| Camera unavailable | Camera recovery |
| Starting… / Saving… | Recording status |
| REC mm:ss · Receiving sound / Waiting for sound | Recording health |
| REC mm:ss · Check microphone (warning symbol) | Recording health, fault visible |

Space toggles reading. Page Down / Right starts from pause, otherwise moves forward a passage. Page Up / Left moves back a passage. Home returns to the first word and pauses reading. These bare keys are handled whenever the presenter is the key window and no text field or script editor has focus (QA round 12); they never type into a text field, and a popover keeps its own keys. Escape closes a popover, exits Clean view, then cancels editing. Shift-Command-R remains the recording shortcut; no bare key records. Retaking from a word never stops the recording.

Empty take names use the presented script title, with Video Prompter as the camera-view fallback. User-entered take names win. The pre-record check owns picture, frame rate, microphone, format, mirroring, rotation, folder and take-name detail; it never requests permissions.

## 0. Principles

These settle every argument the reviews kept reopening.

1. **Doing is on the surface, choosing is one level down.** Anything the creator *does* during a session (start reading, record, stop, check exposure, see the clean picture) is a button on the presenter bar. Anything they *choose* once (fonts, formats, thresholds) lives on a settings page.
2. **One home per setting.** Every setting is fully configured on exactly one page view. That page may be shown in the Settings window or in a presenter popover, but it is the same view type with the same bindings. A setting may also have at most one *quick control* elsewhere (listed in section 2.7). The quick control uses the same label and the same binding. There are no signpost pages.
3. **The transport never moves or hides.** Reading state, Start/Pause, Record/Stop and the recording timer sit in one fixed row in a fixed order. They are never inside a popover, a scroll view or a "Show controls" state.
4. **Reading and recording stay separate actions.** Neither starts the other. Each has its own button next to the other one.
5. **Protect the reading surface.** Presenter chrome scales only to 110%; editor and Settings retain the full Interface size. The script keeps at least 75% of the presenter height, including notices and saved receipts. The minimum useful presenter is 720 × 520. Secondary controls open on demand rather than adding rows.
6. **Words over icons.** Every bar control has a visible word. Icons support the word.

## 1. Core jobs and their single primary path

Counting rule: one click, one menu choice, or one system permission answer is one action. Typing is one action. Looking and speaking are not actions. Counts below are for first use, including permission prompts.

| Job | Primary path | Actions |
|---|---|---|
| A. Camera only: check framing and exposure | Library **Camera Only** · Allow camera · **Guides** · tick **Rule of thirds** · click away · **Zebras** | 6 (picture visible after 2) |
| B. Write or paste a script | Copy text elsewhere · **Paste Copied Text** (start page or **Add** menu). Title comes from the first line. | 1 in the app |
| C. Present, following my voice | **Present** · **Microphone** (live level shows at once) · Allow microphone · click away · **Start reading** | 5 (3 if the microphone is not checked) |
| D. Record a take | In the presenter with a camera on: **Record** · (optional **Start reading**) · **Stop recording** | 2 (3 with reading) |
| E. Find takes | Saved message **Show in Finder**, or library toolbar **Recordings** | 1 |

Fixed rules behind these paths:

- **A.** The library start page **Camera Only** button and the toolbar **Camera Only** button open the presenter in the Camera only view. The same presenter bar is used; nothing about reading is shown in that view (no reading status, no Start reading, no "Reading does not record").
- **B.** `AppStore.importClipboard()` names the script from the first Markdown heading, otherwise the first 6 words of the first line, trimmed to 60 characters. "Pasted Script" is used only when no words exist. The title stays editable.
- **C.** Opening the **Microphone** popover starts the live level meter immediately and stops it when the popover closes. There is no separate Test button in the popover. The Settings Microphone page keeps an explicit **Test microphone** button, because Settings pages stay open for a long time.
- **D.** If the view is Script only, the Record slot shows **Show camera** instead. One click switches to Script and camera, and the slot becomes **Record**. If the camera is shown but not ready, **Record** is disabled and a **Choose camera** button appears directly after it, with the reason as its help text and accessibility hint.
- **E.** The library toolbar gets a **Recordings** button (icon `film.stack`, titled). The Prompter menu keeps **Show Recordings Folder**. The library Folder actions menu no longer contains a recordings item.

Not added in this round: a combined "Record and start reading" action and a countdown. The two separate buttons side by side cover the job.

## 2. Information architecture

### 2.1 Library window (`Library/LibraryView.swift`, `Library/LibraryStartView.swift`)

- **Sidebar:** scope picker (All Scripts, folders, Recently Deleted) and the Folder actions menu (New Folder…, Rename Folder…, Remove Folder, Keep Scripts). Script list below.
- **Toolbar, leading:** **Add** menu (New Script, Import File…, Paste Copied Text, New Folder…).
- **Toolbar, trailing, in this order:** search field, **Recordings**, **Camera Only**, **Present** (prominent).
- **Removed:** the trailing reading inspector (`.inspector` and the 200% `ReadingSettingsSheet`) and its toolbar toggle. Reading settings have one home, the Settings window Reading page. The Present button's help text says "Reading settings are in Settings (⌘,)".
- **Editor header:** one title row: the editable script title in `.title2.weight(.semibold)`, left-aligned with the writing surface. Under it, one quiet metadata line in `.callout` secondary: "Changes save automatically · 312 words". At the right of the metadata line, a single **Text size** button opens a popover holding the editor's quick control (Editor font, Editor text size; see 2.7). **Script details** disclosure stays, below the metadata line.
- **Start page:** unchanged structure. Fix its last line to "Then choose **Present**, then **Start reading**." At 200% the Camera Only button must sit in the first viewport: put the Camera Only group directly under the paste group with no Divider gap larger than `Space.xxl`.
- **Move to Folder menu:** the destination currently called "All Scripts" becomes **No Folder**. "All Scripts" stays as the scope name.
- **Deleting a script:** Move to Trash registers one Undo action for the whole selection ("Undo Move to Trash") and posts the announcement "Moved 3 scripts to Recently Deleted". No confirmation dialog.

### 2.2 Presenter (`Presenter/PresenterView.swift`, struct `PresenterView`; its controller in `Presenter/PresenterController.swift`)

Current placement, superseding the older arrangements below (round 13 Builder A):

| Job | Current placement |
|---|---|
| Start/Pause and Record/Stop | Fixed transport with whole labels; Save/Cancel while editing |
| Back to start | Beside Start whenever applicable; transport wraps whole controls in place |
| State and countdown | Primary reading mode, pace and state control opens mode/speed; recording state aligns beside it; draft state is Editing · not saved yet |
| Camera monitoring | Picture row whenever camera is shown: Guides on/off, Exposure check on/off, Switch camera. Detailed choices stay in the selected Tools section. |
| Secondary adjustments | Tools has a named section picker at every size: Text, Camera, Exposure, Microphone. Below the section, Before recording check…, Shoot setups…, Presenter help… and Last take are listed by name (round 19 retired the generic More menu). |
| Narrow Script only | Text, Camera and Microphone remain in the same wrapping tools region |
| Take receipt | A clean take keeps the Picture row with a Last take opener; a take with problems replaces the row with the full receipt until Hide |
| Camera prerequisites and destination | Recovery replaces unknown output metadata; a received picture is required for the output summary; Show Recordings Folder is in Before recording check… |


The presenter always uses dark appearance for its own chrome (`.environment(\.colorScheme, .dark)` on the control bar and notices), whatever the system setting. It is a stage, like QuickTime full screen. The script colours remain the user's.

The bottom bar is one Liquid Glass container with two rows.

**Row 1, the transport row (always visible, never scrolls):**

| Slot | Content |
|---|---|
| 1 | Status capsule: "Voice follow · Listening", "Automatic scroll · Paused", "Editing · not saved yet" or, in Camera only view, the camera name. |
| 2 | **Start reading** / **Pause** (prominent). Hidden in Camera only view. |
| 3 | **Back to start**. Shown only when not actively reading. Hidden in Camera only view. |
| 4 | **Record** / **Stop recording**, or **Show camera** when the view is Script only. While recording, a red dot and "REC 01:23" follow the button. |
| 5 | **Choose camera**, only when a camera is shown but not ready. |
| 6 | During a take only: **More controls** / **Fewer controls** toggle. |

Under row 1, while recording only, a single **recording health line**: "Mic: ZOOM UAC-232 · [one combined level bar] · Receiving sound". When there is a problem, the status words are replaced by the problem in `.callout.weight(.semibold)` with a warning symbol: "Too loud. Lower the microphone level.", "No sound for 3 seconds. Check the microphone.", "Sound dropped from the file (12 times)". Per-channel meters appear only when More controls is on.

**Row 2, the tools row (shown when no take is running, or when More controls is on):**

Full layout, in this order:
**View** menu · **Camera** picker · **Guides** · **Zebras** · **False colour** · **Exposure…** · **Clean view** · **Text** A− A+ · **Microphone** · **Edit script** · **More** menu

- Camera, Guides, Zebras, False colour, Exposure… and Clean view appear only when the view shows a camera.
- Text A− A+ and Edit script appear only when the view shows the script.
- **More** menu: Reading presets ▸ (each item shows its summary as a second line), Settings… (opens the presenter settings popover, see 2.4), Pin Selected Text over Camera, Match Camera Size, Presenter Full Screen, Close Presenter.
- The close button leaves the bar. Close is in More, in the window's own close button and on ⌘W.

Compact layout, chosen automatically with `ViewThatFits(in: .horizontal)` when the full row does not fit on one line:
**View** · **Camera tools** menu · **Text** A− A+ · **Microphone** · **Edit** · **More**

- **Camera tools** menu holds: the camera list as a submenu, Framing Guides…, Zebras (toggle), False Colour (toggle), Exposure…, Clean View (toggle).
- When any exposure aid is on, the Camera tools button shows a filled `sun.max.fill` symbol and its accessibility value names what is on ("Zebras on, False colour off").

The tools row may wrap to a second line in the full layout only between groups (camera group, script group, More). It never wraps inside a group.

**Removed from the presenter:** the "Set up this take" button and `TakeSetupPanel` (in `Settings/SettingsView.swift`); the "Reading does not record" text (the separate Record button now says it); the View menu's "Camera Settings…" item and its `CameraSettingsPanel` popover.

**Kept:** the drag handle at the top, the reference cue (pin) at the top, notices above the bar, the close-during-take dialog, the discard-draft dialog, every keyboard shortcut.

### 2.3 Second monitor window (`Camera/CameraWindow.swift`, `CameraView`)

This is the secondary camera surface, for a second display. It is named **Second monitor window** (window title and Window menu item "Open Second monitor window", shortcut ⌃⌘C, since ⇧⌘C is the system Show Colors chord).

Toolbar, in order: **Camera** picker, **Rotation** pop-up, **Zebras**, **False colour**, **Exposure…**, **Record** / **Stop recording** with REC timer, **Options** menu (Mirror Camera Preview, Framing Guides…, Always on Top). The "Set up recording" popover inside `RecordingControls` is removed; recording choices live on the Camera & Recording page, reachable from Options ▸ Camera & Recording Settings….

### 2.4 Settings window (`Settings/SettingsView.swift`)

Six tabs, each a real destination with its own controls. `SettingsTab` becomes:

| Tab | Symbol | Contents (in order) |
|---|---|---|
| **General** | `gearshape` | Interface size · Writing: Editor font, Editor text size · Windows: Align presenter to screen edges |
| **Reading** | `text.book.closed` | Following: Mode, Reading speed (Automatic scroll only) · Reading text: font, size, weight, Mirror for teleprompter glass · Layout: Text width (with a "Narrow column" button setting 65%), Alignment, Line spacing, Paragraph spacing · Reading guide · Colours (with the contrast warning, section 8.5) · Rotation and stage directions |
| **Reading presets** | `slider.horizontal.3` | Save current reading settings · list with Apply, summary, In use, Actions menu |
| **Shoot setups** | `camera.badge.ellipsis` | Save, apply, rename and delete full shoot setups; Restore previous setup after a successful Apply |
| **Microphone** | `mic` | Microphone · live level and Loudest sound · Microphone volume · Spoken language · Follow me when I repeat earlier words · Advanced disclosure (section 3) |
| **Camera & Recording** | `video` | Camera: picker, rotation (with detected angle in Automatic), Mirror camera preview · Saved video: one-line summary, Recording format, Mirror saved video, Take name · Framing guides and Frame marker · Exposure (section 4) · Recordings: Show Recordings Folder, Show Last Take in Finder |

- The Editor tab is deleted. Settings > General's "Open Reading settings…" signpost is deleted.
- The Reading page no longer contains Presenter view (a presenter choice, see 2.5), Camera Settings…, Voice and Microphone Settings…, Editor text or Interface size….
- **Presenter settings popover:** More ▸ Settings… in the presenter opens a 560 × 600 popover containing a segmented control (Reading · Microphone · Camera & Recording) above the same `SettingsPage(tab:)` view the Settings window uses. It has no Record button and no footer.
- **Presenter popovers for single jobs:** Guides opens `CameraGuideSections`. Exposure… opens `CameraExposureSections`. Microphone opens `MicrophonePage(compact: true)` (picker, live level, volume, clipping row; Advanced hidden). All are the same views as the Settings pages.

### 2.5 Menus (`App/VideoPrompterApp.swift`)

| Menu | Items |
|---|---|
| **File** | as now (New Script … Move to Trash). |
| **Edit** | standard, plus Find… |
| **Format** | as now. |
| **View** | Zoom In, Zoom Out, Actual Size (Interface size) · Make Text Bigger, Make Text Smaller · **Script Only**, **Script and Camera** (⇧⌘V), **Camera Only** · **Clean View** (⌥⌘K) · **Zebras** (⌥⌘Z), **False Colour** (⌥⌘X) · Presenter Full Screen (⌃⌘F) |
| **Prompter** | Present Script (⌥⌘P) · Camera Only presenter (⌥⌘C) · Start or Pause (⌥⌘S), Back to Start (⌥⌘R), Previous Passage, Next Passage · **Record** / **Stop Recording** (⇧⌘R) · Show Recordings Folder · Pin Selected Text over Camera (⌥⌘L) · Match Camera Size |
| **Window** | Camera Monitor Window (⌃⌘C), iPad Remote, standard items |
| **Help** | Welcome Script, Privacy |

The presenter view choice moves from the Prompter menu to the View menu. Builder A must check the three new shortcuts against `ScriptShortcuts` and system shortcuts before committing, and pick another letter if one clashes.

### 2.6 What is not shown during a take

A take is running when reading is active, a recording is preparing, recording or saving (`isTaking`).

- **Stays:** transport row, recording health line, notices that need action (errors, permission, "not saved yet" draft warning), the pinned reference cue, the exposure legend if an aid is on.
- **Hidden until More controls:** the whole tools row, per-channel meters, the reading detail line.
- **Locked while recording (disabled with the help text "Stop recording to change this"):** camera choice, rotation, recording format, mirror saved video, take name, recording microphone, 32-bit float. Framing guides, zebras, false colour and Clean view stay usable because they only change the monitor.
- The bar never hides while the pointer is over it, a bar control has keyboard focus, or a popover or menu from it is open.

### 2.7 Quick controls (the only allowed duplicates)

| Setting | Home | Quick control |
|---|---|---|
| Reading text size | Settings > Reading | Presenter **Text** A− A+ (steps of 4 pt, announces "Reading text 48 points") |
| Editor font and size | Settings > General | Library editor **Text size** popover |
| Microphone | Settings > Microphone | Presenter **Microphone** popover |
| Camera | Settings > Camera & Recording | Presenter **Camera** picker, Camera Monitor toolbar |
| Zebras, False colour | Settings > Camera & Recording > Exposure | Presenter bar toggles, Camera Monitor toolbar, View menu |
| Framing guides | Settings > Camera & Recording | Presenter **Guides** popover, Camera Monitor Options |
| Presenter view | Presenter **View** menu | View menu in the menu bar |
| Reading presets | Settings > Reading presets | Shared Settings page |
| Reading mode and speed | Settings > Reading | Presenter reading-status control |
| Whole-shoot setups | Settings > Shoot setups | Tools > Shoot setups… |

Interface size is under General only, plus ⌘+ / ⌘− / ⌘0.

## 3. Microphone model

The sentence the UI uses, at the top of the Microphone page and as the Microphone popover's help:

> **Video Prompter listens to this microphone to follow your words, and records it with your video.**

- Default: one **Microphone** choice. It drives both Voice follow (`PrompterSettings.audioDeviceUID`) and the recording (`CameraRecorder`).
- Advanced disclosure on the Microphone page: a toggle **Record from a different microphone**. When on, it reveals **Recording microphone** (picker), **Test recording microphone** with its own level, and **32-bit float audio** with its one-line explanation. When off, those controls are not shown.
- Storage: a new `CameraRecorder.usesSeparateMicrophone` (UserDefaults key `recordingUsesSeparateMicrophone`). The recorder resolves its input as `usesSeparateMicrophone ? microphoneUID : settings.audioDeviceUID`, with the system default when nil. Migration: on first launch of this version, set it to true only if both UIDs are saved and different. Otherwise false. `PrompterSettings` is not changed, so presets and the iPad app stay compatible.
- "Use the following microphone for recording" is deleted. The phrase "following microphone" is deleted from all UI text.
- On the presenter bar, the **Microphone** button's title is "Microphone" and its accessibility value and help are the device name. When separate microphones are on, its help reads "Following: Studio Mic. Recording: ZOOM UAC-232." The recording health line always names the recording microphone.
- The clipping warning gets its own wrapping row: "Too loud. Lower Microphone volume." The dBFS number goes on the next line, never in the same `fixedSize` HStack.

## 4. Exposure

- **Zebras** and **False colour** are toggle buttons on the presenter bar and the Camera Monitor toolbar. On-state: filled symbol (`circle.lefthalf.striped.horizontal` filled for Zebras, `paintpalette.fill` for False colour), accent-tinted glass background, and accessibility value "On" or "Off". The word is always visible. Toggling announces "Zebras on" or "Zebras off".
- **Exposure…** opens `CameraExposureSections`, in this order:
  1. The same two toggles, at the top.
  2. **Zebras show** picker: **Bright areas** (95 IRE and above, the default) or **Face brightness** (60 IRE ± 5, the existing `applySkinExposurePreset`). Choosing Face brightness also turns Zebras on.
  3. A single line: "Exposure aids only change this preview. Adjust exposure on your camera."
  4. **Custom levels** disclosure: level and range steppers.
  5. **How exposure aids work** disclosure: the existing IRE, profile and skin-tone explanations, unchanged in meaning.
- **Clean view** is a toggle on the bar (`eye`), in View menu (⌥⌘K) and in Camera tools. When on, the presenter shows the camera picture only: no script, no backdrop or dimming, no reading guide, no framing guides, no zebras or false colour, no exposure legend, no pinned cue. The bar collapses to the status capsule ("Clean view"), **Record**/**Stop recording** with timer, and **Exit clean view**. Esc also exits. The reading position and the view mode are unchanged when it ends. While clean view is on, reading is paused if it was running, and the status capsule says so.
- The legend overlay `ExposureLegend` loses its "Clean picture" / "Show exposure aids" button. It shows only what is on ("Zebras: bright areas, 95 IRE and above"; the false colour key in a disclosure).

## 5. Presenter during a take, and at 200%

- Section 2.6 defines what stays and what recedes.
- The bar container's maximum height is 40% of the presenter's height. Only row 2 and the per-channel meters may scroll. Row 1 and the health line sit outside the scroll view (`PresenterControlViewport` wraps row 2 only).
- At Interface size 150% and 200% the compact tools layout is used when needed (`ViewThatFits`). The transport row keeps full words at every size. If it still cannot fit, it drops in this order: Back to start (still in Prompter menu), then the status capsule text shortens to the state word only ("Listening"). Stop recording, the REC timer and any recording problem are never dropped.
- During a take at 200% in a 1000 × 700 presenter, the bar is at most two lines tall: transport row plus health line.
- The drag handle stays at 72 × 24 points at every zoom; it is not enlarged.

## 6. Settings tabs

Section 2.4 is the rule: five real destinations, no page that only links to another. Every in-app link to Settings opens a specific tab (`AppSettingsView.requestTab(_:)`). Native tab labels do not scale with Interface size, so at 150% and above each page shows an enlarged segmented page picker at its top, bound to the same selection, with the same five names.

## 7. Frozen vocabulary

One name per concept. These are the allowed words on the presenter; native buttons, menus and window titles use their title-case equivalent. `FinalVocabularyTests` checks these labels and rejects retired UI names. Changing this table requires the lead's approval.

| Concept | Use | Never use |
|---|---|---|
| Text to read | script | document as a script name |
| Floating reading window | presenter | prompter window |
| Views | Script only, Script and camera, Camera view | Video only, Prompter only |
| Launch camera without script | Camera Only | Camera Monitor as launch action |
| Separate camera window | Second Monitor; Open Second Monitor Window | Camera Monitor; Second monitor window as a title |
| Reading actions | Start reading, Pause, Back to start, Read again | Start or Pause |
| Reading modes | Voice follow, Automatic scroll | Manual, Timed as UI mode names |
| Reading states | Ready, Paused, Starts in N, Listening, Following, Scrolling, End of script | Finished |
| Recording | Record, Stop recording, Starting…, Saving…, Waiting for picture, Camera unavailable | Not recording, Waiting for camera as status |
| Ready picture | Ready · Portrait, Ready · Landscape, Ready · Square | Claimed resolution before a received picture |
| Take receipt | Saved, Saved with problems, Take not saved, Play, Review, Show in Finder, Hide | Show saved take…, Dismiss receipt |
| Receipt recovery | Last take | Review last take |
| Recording health | Receiving sound, Waiting for sound, Check microphone | Healthy sound alongside a problem |
| Microphones | Microphone, Recording microphone | following microphone |
| Exposure switches | Check bright areas · Zebras, Check brightness · Zebras, Check custom brightness · Zebras, Check brightness · False colour | Find blown highlights, Clipping as a caption |
| Exposure key | Very dark, Mid-tones, Bright, Near white, Key | Face target |
| Qualified preset, custom disclosure only | Face reference | Skin exposure check |
| Clean picture toggle | Clean presenter view; Clean view as state; Exit clean view | Clean picture, Hide exposure aids |
| Picture row | Guides, Exposure check, Switch camera | More controls |
| Other presenter controls | Tools, View, Edit this script, Save changes, Cancel editing | Finish editing |
| Settings | Reading presets, Shoot setups, Reading text size, Editor text size, Interface size | Saved settings |
| Clipboard action | Paste Copied Text | Paste as New Script |
| Import alert | Unable to Import | Import failed |
| Zoom menu | Zoom In, Zoom Out, Actual Size, Make Text Bigger, Make Text Smaller | Increase Interface Size for All Scripts |
| Dismiss a notice | Hide | Dismiss, OK |
| Format | H.264 (most compatible), HEVC (smaller files), ProRes 422 (for editing) | Recording quality |

## 8. Visual rules

### Presenter popover contrast correction, 7 November 2026

The presenter bar retains its dark appearance. Every popover explicitly resets the inherited bar button style and uses the system light/dark appearance for native controls, resolved label colour and an opaque native window-background content surface. Glass may surround the content but never puts words directly over the script. Reduce Transparency changes chrome rendering, not the foreground/background pairing. `PresenterPopoverContrastTests` verifies appearance isolation and AA semantic pairs; `testPresenterPopoverContrastMatrix` renders light/dark × transparency/reduced fixtures and checks actual heading, body and button pixels against 4.5:1.


### 8.1 Materials
- Presenter bar: one `GlassEffectContainer` with `.glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 20))`. Under Reduce Transparency, a solid `Color(white: 0.12)` fill. `.regularMaterial` is removed from the presenter.
- Bar buttons: `.buttonStyle(.glass)`. Start reading uses `.glassProminent` with the accent tint. Record uses `.glass` with a red record symbol; while recording, the Stop button is `.glassProminent` tinted red.
- Notices above the bar and the exposure legend: the same tinted glass, radius 12.
- Library, Settings and popovers: native materials and grouped forms only. No custom cards around Form sections; the Reading page uses `Form { Section }` with `.formStyle(.grouped)` like every other page.

### 8.2 Radii
Bar container 20. Notices, legend, popover inner cards 12. Bar buttons capsule. Drag handle 8. Everything else is system-drawn. These are the only literal radii in app chrome, and `checks/check-grid.py` must accept them.

### 8.3 Spacing
Only `Space` tokens. Inside the bar: 8 between buttons in a group, 16 between groups, 12 padding inside the container. Form rows: system. Page margins `Space.margin` (20). Section gaps `Space.xxl` (24).

### 8.4 Type scale (`UI/DesignTokens.swift` `UIType`)
| Token | Font | Use |
|---|---|---|
| `title` | `.title2.weight(.semibold)` | library editor title, start page headings below the large title |
| `heading` | `.headline` | section headings |
| `body` | `.body` | labels, buttons, bar buttons |
| `secondary` | `.callout` | explanations, status capsule, health line, metadata |
| `caption` | `.caption` | numbers beside meters only |

Rule for a dyslexic reader: nothing a person must read to act is smaller than `.callout`. Explanations use primary colour at `.callout`, never `.secondary` foreground on light backgrounds. No explanation longer than two lines sits above a control; longer text goes in a "How … works" disclosure.

### 8.5 Contrast over the camera picture
- New `PrompterSettings` default `videoDimming = 0.5` (was 0.25). Saved settings keep their value.
- When the script is over a camera picture, the script text gets a soft dark halo (shadow radius 6, black at 60%). Toggle-free; it is part of the over-video rendering.
- The Reading page Colours section shows a warning when the worst case falls below 3:1 (text colour at Text visibility over the background colour at Background darkness, on a white picture): "Text may be hard to read over a bright picture." with a **Make Readable** button that sets Background darkness to the lowest value reaching 3:1. It never changes saved values on its own.
- Presenter chrome is always the dark appearance, so bar text is light on dark glass in both system appearances.

### 8.6 Icon finish
SF Symbols only, `.symbolRenderingMode(.hierarchical)`, weight matching the label. Filled variants mean "on". Red is reserved for recording and for problems. Round 8 Builder B exception: refine the app icon to prioritise a script and camera lens over audio. Keep separate editable Icon Composer groups, default/dark/tinted appearances, and matching crisp legacy sizes.

## 9. Accessibility rules

1. **Name, role, value at every zoom.** Every choice control has a label and a value at 100%, 150% and 200%. The enlarged `Menu` in `ReadingInspectorView.choice` keeps a `Picker(.inline)` inside the menu so items carry selected state, and adds `.accessibilityValue(selectedName)`. Same for the Microphone and Recording microphone menus.
2. **Toggles report state.** Zebras, False colour, Clean view and More controls expose "On"/"Off" (or Expanded/Collapsed) as their value.
3. **Announcements** (`NSAccessibility.post(.announcementRequested)`, medium priority): reading started, paused, recording started, recording stopped, "Saved [file name]", any recording problem (high priority), Zebras/False colour/Clean view on or off, reading text size change, script changes saved, scripts moved to Recently Deleted.
4. **Focus.** Tab order in the bar follows visual order: transport row left to right, then tools row. Hiding the tools row never removes the focused control; it waits until focus leaves. Closing any bar popover returns focus to the button that opened it. Esc closes popovers, then exits Clean view, then cancels editing, in that order.
5. **Enlarged layouts wrap.** At 150% and 200%: labels wrap, values sit on their own line when needed, nothing uses `.fixedSize()` horizontally on text longer than one word. Long device names wrap to two lines and expose the full name as help and accessibility label.
6. **Keyboard.** Every bar action has a menu command (section 2.5). Bare arrow keys only move passages when the script itself has focus.
7. **Motion.** Reduce Motion keeps jump-not-glide seeking. No new animation is added except the system's own glass transitions.

## 10. Builder assignments

Both builders work from this spec. Ownership is disjoint; the only cross-boundary needs are the contracts in 10.3.

### 10.1 Builder A: presenter, app, camera, settings, control

**Owns:** `Presenter/PresenterController.swift`, `Presenter/PresenterView.swift`, `App/**`, `Camera/**` except `Camera/CameraPicker.swift`, `Settings/**`, `Control/**`. Also `Audio/**`, `Speech/**` and `Sources/PrompterCore/**` if a change there is unavoidable. Tests: `Tests/PrompterCoreTests/AppearanceSnapshotTests.swift`, `PresenterBarTests.swift`, `PresenterControllerTests.swift`, `PresenterWorkflowTests.swift`, `PresenterPresentTests.swift`, `SettingsUndoTests.swift`, `SettingsPersistenceTests.swift`, `UIZoomTests.swift`, `SimpleInterfaceTests.swift`, `RecordingRoundThreeTests.swift`, `CameraRecorderTests.swift`, `MovieWriterTests.swift`, `CameraTests.swift`, `CameraExposureTests.swift`, `AppStoreTests.swift`, `ControlTests.swift`, `ControlCLITests.swift`, and new test files it creates.

**Work:**
1. Presenter bar rebuilt to section 2.2: transport row, health line, tools row (full and compact via `ViewThatFits`), More menu, dark chrome, glass (8.1), 40% cap with only row 2 scrolling (5).
2. Delete `TakeSetupPanel`, the View menu's Camera Settings… item, "Reading does not record", and the "Set up recording" popover in `RecordingControls`. Recovery actions that opened setup now open the presenter settings popover at the right segment.
3. Show camera / Record / Choose camera slot logic (1, D). Rename labels per section 7.
4. Clean view (`CameraModel.cleanView`, published) and its effect on `PresenterView` and `CameraView` (4).
5. Exposure toggles on bar and Camera Monitor toolbar; `CameraExposureSections` reordered (4); `ExposureLegend` simplified.
6. One recording lock: `CameraModel.selectedUID`, rotation and every recorder setting refuse changes while `CameraRecorder.shared.isRecording || isBusy` (model-level guard, not just disabled views). Remove `CameraView`'s `.onChange(of: model.selectedUID) { recorder.stop() }`.
7. Audio drop reporting: count dropped and unready audio appends in `MovieWriter`/`RecordingSink`, publish to `CameraRecorder.droppedAudioBuffers` while rolling, show in the health line, keep the count on the saved message.
8. Microphone model (3), including `usesSeparateMicrophone`, migration and the Microphone page. Split `VoiceSettingsPage` into `MicrophonePage(store:compact:)`.
9. Settings tabs (2.4, 6): new `SettingsTab` cases and order, delete Editor tab and signposts, Camera & Recording page built from `CameraSettingsPanel` + `RecordingSettingsPanel` sections, presenter settings popover, enlarged page picker at ≥150%.
10. Menus (2.5). Rename Camera Monitor window. Prompter/View split.
11. `AppStore`: first-line titles for pasted scripts; undoable batch Move to Trash with announcement (`delete(_:undoManager:)`, see 10.3); Apply preset registers Undo.
12. `PrompterSettings.videoDimming` default 0.5 and `textWidth` default 0.75 for new settings only (decoding of saved values unchanged).
13. `WelcomeScript` rewritten to the new path: Present, then Microphone, then Start reading; Record beside it; Paste Copied Text; no "Set up this take".
14. Presenter edit badge and button: "Editing · not saved yet", **Save changes** (⌘Return), announcement "Changes saved to [title]".
15. Google Docs update: "Updating from Google Docs…" then "Updated" or "Already up to date" as a library notice; the replace alert's default button is Cancel.
16. Make `AppearanceSnapshotTests.snapshot(_:name:size:scheme:destination:)` internal (not private) in the first commit, so Builder B can add an extension.

**Acceptance (all automated):**
- A1. `PresenterBarTests`: for views Script and camera and Camera only, at zoom 1.0, 1.5 and 2.0, idle, reading, recording: a button labelled "Record" or "Stop recording" exists, is enabled when the fixture camera is ready, and its frame lies inside the presenter bounds. No such button exists in Script only; "Show camera" exists in its place.
- A2. Same matrix: "Start reading"/"Pause" and "Record"/"Stop recording" have the same vertical midpoint (same row) and are not inside an `NSScrollView`.
- A3. While reading or recording with More controls off, no element labelled "View", "Guides", "Edit script" or "More" exists; "More controls" exists. With More controls on, they exist.
- A4. At 2.0 in 1000 × 700, recording: the bar's frame height is at most 280 points (40%).
- A5. Clean view on: no `ScriptTextView`, no backdrop, `CameraStageView` receives guides with all overlays off; "Exit clean view" and "Record" exist; reading position unchanged after exit.
- A6. Changing `selectedUID`, rotation, format, mirror saved video or recording microphone while a fixture recorder is recording leaves the value unchanged.
- A7. A `MovieWriter` fixture whose audio input reports not ready increments `droppedAudioBuffers` and the health line text contains "Sound dropped".
- A8. `usesSeparateMicrophone == false`: setting `audioDeviceUID` changes the recorder's resolved input. Migration test for the three cases (none saved, same, different).
- A9. `SettingsTab.allCases.map(\.rawValue) == ["General", "Reading", "Reading presets", "Microphone", "Camera & Recording"]`. Every tab's page contains at least one enabled control that is not a link to another tab.
- A10. Zebras/False colour toggle buttons expose accessibility values "On"/"Off" matching `CameraModel.guides`.
- A11. A source text check (in a test) finds none of these strings in `Sources/`: "Set up this take", "following microphone", "Clean picture", "Dismiss receipt", "Paste as New Script", "Record camera", "Skin exposure check", "Separate Camera Monitor".
- A12. Undo after deleting two scripts restores both to All Scripts.
- A13. Snapshots (light and dark): `presenter-idle-camera-{100,150,200}`, `presenter-taking-{100,200}`, `presenter-clean-view`, `presenter-camera-only-200`, `settings-{tab}-{100,200}` for all five tabs, `microphone-separate`, `exposure-panel`. Each reviewed by eye before commit.
- A14. `zsh test.sh` and `zsh checks/check-snapshots.sh` pass.

### 10.2 Builder B: library, import, script surfaces, picker, design docs

**Owns:** `Library/**`, `Import/**`, `Presenter/**` except `PresenterController.swift` and `PresenterView.swift` (so `ScriptTextView.swift`, `ReferenceMonitor.swift`, `PresenterSessionState.swift`), `Camera/CameraPicker.swift`, `Resources/**`, `UI/DesignTokens.swift`, `docs/design/**`. Tests: `LibraryTests.swift`, `LibraryRoundTwoTests.swift`, `LibraryRoundThreeTests.swift`, `LibraryAppearanceTests.swift`, `LibraryEditorSaveTests.swift`, `CameraPickerTests.swift`, `ReadingAccessibilityTests.swift`, `ReferenceMonitorTests.swift`, `FormattedMarkdownEditorTests.swift`, `TypographyTests.swift`, `GoogleDocsTests.swift`, and new files, including `AppearanceSnapshotTests+Library.swift` (an extension of `AppearanceSnapshotTests` so `checks/check-snapshots.sh` runs it).

**Work:**
1. Library window to section 2.1: remove the inspector and the 200% reading sheet; toolbar order with **Recordings**; editor header with one title, one metadata line and the **Text size** popover; start page fixes; No Folder; pass `undoManager` to `store.delete`.
2. `ReadingInspectorView` becomes `ReadingSettingsPage` (keep `typealias ReadingInspectorView` and `InspectorView` for callers until A has switched): grouped `Form`, sections per 2.4 Reading row, minus Presenter view, Camera Settings…, Voice and Microphone Settings…, Editor text and Interface size…. Remove the `onVoiceSettings` parameter once A no longer passes it (A deletes `TakeSetupPanel` first; see 10.3).
3. New `EditorTextControls(store:)` view in `Library/` (Editor font, Editor text size, one-line explanation), used by the library Text size popover and by A's General tab.
4. Accessibility of choices at every zoom (9.1), wrapping rules (9.5) for everything in `Library/`.
5. Contrast warning and **Make Readable** in the Reading page Colours section (8.5), with a pure function `ReadingContrast.worstCase(textHex:textOpacity:backgroundHex:darkness:) -> Double` in `Library/ReadingContrast.swift`.
6. `ScriptTextView` gains `overVideo: Bool = false`; when true it draws the legibility halo (8.5).
7. `CameraPicker`: disables itself and shows help "Stop recording to change camera" whenever `CameraRecorder.shared.isRecording || isBusy`, so every entry point inherits the lock. Empty title "Choose camera" instead of "No camera". Long names wrap to two lines on the bar with the full name as help.
8. `UIType` gains `title` (8.4). `docs/design/DESIGN-SYSTEM.md` rewritten to sections 0, 2.7, 7 and 8 of this spec, replacing the round-by-round notes.
9. Relink comparison heading "Removed from saved script" becomes "In the saved script, not in the file", and its counterpart "In the file, not in the saved script".

**Acceptance (all automated):**
- B1. `LibraryView` snapshot at 100% and 200%: no inspector column and no reading sheet; toolbar accessibility tree contains "Recordings", "Camera Only", "Present" in that order.
- B2. `ReadingAccessibilityTests`: at zoom 1.0, 1.5 and 2.0, the Mode, Reading font and Alignment controls each expose a non-empty accessibility value equal to the selected name, and the selected menu item has the selected trait.
- B3. `ReadingSettingsPage` contains no element labelled "Presenter view", "Editor font", "Editor text size", "Interface size…" or "Voice and Microphone Settings…".
- B4. `ReadingContrast.worstCase` unit tests: white text, black background at 0.25 darkness is below 3; at 0.5 it is at or above 3; the warning appears in the first case and **Make Readable** sets darkness to the lowest passing value.
- B5. `CameraPickerTests`: with a fixture recorder recording, the picker is disabled and its help is "Stop recording to change camera".
- B6. Pasting from the start page at 200%: the Camera Only button's frame lies within the first 800-point viewport (`first-launch-200` fixture).
- B7. Library deletion via the Delete key path registers an undo action (checks `undoManager.canUndo`).
- B8. A source text check finds none of "Paste as New Script", "Dismiss receipt", "Saved settings" in `Library/`, `Import/` or `Resources/`.
- B9. Snapshots (light and dark): `library-{100,200}`, `library-text-size-popover`, `reading-settings-page-{100,150,200}`, `reading-contrast-warning`, `camera-picker-recording-locked`, `presenter-script-over-video-halo`. Each reviewed by eye.
- B10. `zsh test.sh` and `zsh checks/check-snapshots.sh` pass, including `check-grid.py` with the radii in 8.2.

### 10.3 Contracts between the builders

| Contract | Provider | Consumer | Rule |
|---|---|---|---|
| `AppStore.delete(_ ids: Set<UUID>, undoManager: UndoManager? = nil)` | A | B | Default parameter, so B's call compiles before and after. |
| `AppearanceSnapshotTests.snapshot(...)` internal | A, first commit | B | B rebases on it before adding its extension. |
| `ReadingSettingsPage(store:)` | B | A (Settings > Reading, presenter settings popover) | B keeps the old type names as aliases until A has switched; A removes its `onVoiceSettings` argument when deleting `TakeSetupPanel`. |
| `EditorTextControls(store:)` | B | A (Settings > General) | Same bindings as today (`previewFontName`, `previewFontSize`). |
| `ScriptTextView(..., overVideo:)` | B | A (`PresenterScriptView`) | Default `false`; A passes `camera.presentsWithVideo && !cleanView`. |
| `CameraPicker` recording lock | B | A (bar, Settings, Camera Monitor) | A also guards at model level (A6); the picker lock is the visible half. |
| `CameraRecorder.recordingsFolder()` | A (existing) | B (Recordings button) | Unchanged signature. |

Order: A commits the two enabling changes (delete signature, snapshot helper) first; then both work in parallel; A switches Settings to `ReadingSettingsPage` after B lands it. Each builder runs the full suite and the snapshot check before finishing, and lists anything it could not prove offscreen (live glass, hardware recording, spoken VoiceOver) as owed to a live check.


## Round 5 Builder A clarification (6 November 2026)

The owner's Round 5 implementation request supersedes the original pause-on-Clean-view behaviour. Clean view hides script and monitoring overlays while reading continues; exiting restores the current reading position, without a transport change. Start/Pause remains available in that view. It does not change the saved picture.

Section 2 toolbar refinement: keep transport order; Back to start is first in More at compact sizes. Tools are grouped with 16-point gaps: View/Clean view/camera tools, Microphone, Text, More. Text becomes one quick-control menu with smaller/bigger actions; Edit script moves into More (Save changes/Cancel editing remain surfaced during editing). Saved video beside Record opens the existing output summary, including format, dimensions when known, rotation, mirroring and guide-only framing. These are disclosure controls, not duplicated settings.

Section 6 refinement: native tabs at ordinary size, one page menu replacing tabs at enlarged sizes. Reading settings may show a representative live sample, explicitly labelled as a sample rather than the actual camera picture. Settings camera permission is requested only by Allow Camera Access in that page.

Section 8.5 refinement: the readability warning must conservatively cover all attainable camera colours, including intermediate colours, and the rendered cue, confirmed-word and highlight opacities. Use 4.5:1 for text below large-text size, otherwise 3:1. Make Readable may use an opaque black backdrop, full white text and disable highlighting when darkness alone cannot meet the requirement; explain this beside the action. Never approve a sample merely because average or white-frame contrast passes. Retain a minimal cross-owner edit in ReadingContrast/ReadingInspectorView for this shared contract.

Recording is confirmed only after a successful video append. Waiting for camera remains cancellable. A completed file is inspected for playable video and expected audio; interruptions and dropped video/audio remain persistent warnings with Play/Show in Finder and retry actions. Receipts/notices scale once with Interface size on a protected dark surface. Health warnings announce transitions, not meter ticks.

## Round 7 Builder A refinement (6 November 2026)

This supersedes the corresponding controls in sections 2.2, 2.3, 2.7 and the Round 5 refinement.

| Job | Primary / quick control |
|---|---|
| Read mode and next behaviour; adjust mode/speed | Persistent transport status button, at every size. Opens a small Mode/Reading speed popover using existing settings bindings. |
| Exposure and clean picture during a take | Persistent monitoring row with direct Zebras, False colour and Clean view buttons, plus More controls. More controls moves off the transport row to preserve full reading/recording labels at 200%. No setup disclosure required. |
| Compact/enlarged idle setup | One row: View, Setup, Clean view (with camera), More. Setup groups the existing preview camera picker, guides, exposure, microphone, text sizes and Recording setup disclosure. Wide tools retain their current homes. |
| Output information before recording | Recording setup, never Saved video. Wide transport or compact Setup, using the same output summary. |
| Camera workspaces | Prompter > Open Camera View in Presenter; Window > Open Camera Monitor for a second display. Camera only remains the presenter view choice; both surfaces share camera and recording configuration. |

Completion is shown as End of script with Back to start and Read again. It never stops the recording. Before reading, status says Follows your voice or Scrolls at N wpm. Compact controls retain the mode and make speed directly adjustable through the status button.

Zebras have an explicit purpose: Bright areas, Face reference or Custom. Manual level/range edits select Custom; loaded invalid face settings are treated as Custom. Only the fixed 60 ±5 reference receives qualified face guidance, never an arbitrary band. Custom levels describe the measured received-picture range, and near-white customs warn against brightening a face to reach them. Legacy non-default bands migrate to Custom.

Fresh camera selection prefers a physical device, retains saved device choices and does not automatically choose virtual devices. The chosen camera is named in camera view/Setup and announced on first selection. Rotation states that it changes both preview and saved take. Help covers compact Setup/More paths and the second-display purpose. Recording recovery text states the outcome and recovery action, not writer internals.


## Round 7 Builder B refinement

- Library (section 2.1): keep two columns. Label folder navigation and the current script scope separately. Folder creation is a quiet Folder actions menu beside its heading. Below 560 points per interface scale, collapse the sidebar with the native toggle retaining access. The library minimum width is 640 points. Linked-file destination and Unlink stay below save status. Saved remains visible until the next edit.
- Start page (section 2.1): place Try the Practice Script immediately after the reading instruction, before Camera Only and secondary import/write choices. At larger sizes use the smaller existing heading style so the teaching route fits.
- Camera picker: at 150/200%, keep the preview and its caption visible above a bounded scrolling list of camera choices and permission/recovery actions. Keyboard selection scrolls its row into view.
- Readability (section 8.5): evaluate both camera and script-only backdrops, including translucent backgrounds, dimmed words, stage directions and the active-word colour. Describe the complete proposed change before Make Readable. Prefer only increasing the relevant backdrop opacity. If impossible, use white text on solid black at full visibility, preserving highlighting and stage directions unless their dimming fails the threshold. Expose Undo Make Readable immediately.
- Exposure legend: use practical decisions and plain brightness descriptions. A nonzero custom range never implies a face target. Numerical received-picture measurements are secondary details.
- Icon: simplify the existing editable vector layers, strengthen page/reading-marker separation, and remove fine microphone seams so the modern renditions remain distinct at 16 and 32 points.

## Round 8 Builder B refinements

- Editor header: title remains editable, using regular title weight. Keep save state and word count on one quiet line; place Text size and Script details together below it at all zoom levels. Show only a compact Linked indicator by default. Move link explanation and Unlink file into Script details; broken-link warnings remain visible.
- False colour: show a compact six-band key directly while enabled, using short everyday labels and the implemented received-picture brightness ranges. Longer guidance and numeric zebra calibration live in a Help disclosure. Never imply every face needs the same brightness.
- Preset empty-state guidance uses primary callout text and must measure at least 4.5:1 at normal size in both appearances.
- Library Text size and Camera picker popovers restore keyboard and native accessibility focus to their own opener after cancellation or selection.


## Round 8 Builder A refinement (6 November 2026)

Supersedes the 60% reading minimum, 40% bar cap, Round 5 hidden Edit/restart and Round 7 Setup/status arrangements. Live review at 760 × 520 showed those rules left only 50% for reading at 200%.

| Job | Control and placement |
|---|---|
| Change reading mode/speed | Bordered **Reading mode** button, visible chevron, named mode/state; same popover bindings. |
| Restart text | **Back to start** beside Start reading whenever paused, at every width, independent of recording. |
| Choose camera, guides, exposure, output | **Camera** on idle tools row opens a content-sized, bounded popover. Camera Monitor is an optional second window from here and Window menu. Prompter menu's entry is **Camera**. |
| Reading size | **Text** opens content-sized **Smaller text** / **Larger text** controls with point values and disabled limits. |
| Edit | **Edit script** stays on idle tools row at ordinary/compact widths. |
| Check before Record | Idle summary names camera, recording microphone, level/check-level action and save folder. Opening Microphone explicitly starts the test; idle summary does not. Camera popover retains output orientation/format/guide details. |
| Record readiness | Keep disabled **Record** plus **Choose camera** until ready; never replace Record with readiness alone. |
| Save result | Name the take at every size; middle truncation allowed with full accessible value/path. |

The whole bottom region, including transport, notices, health and tools, consumes at most 25% of window height. Only secondary content scrolls. Transport remains outside scrolling. Presenter control scaling caps at 110%; reading text and other app windows retain independent sizing. Drag handle overlays instead of subtracting reading height. During reading/recording, tools recede; direct exposure/Clean view and More controls stay available. Native focus and VoiceOver focus return to the actual popover opener, including nested Camera options.


## Round 8 Builder A amendment, 6 November 2026

The enlarged two-row specification failed in the real 760 × 520 presenter: only 50% remained for reading at 200%. The following replaces the presenter placement and sizing rules above. Other surfaces retain full Interface size.

| Control or information | Home after round 8 |
|---|---|
| Reading mode and speed | Named Reading mode button with visible chevron and current state in the fixed transport; opens the shared settings bindings. |
| Start/Pause, Back to start, Record/Stop | Fixed transport. Back to start remains visible while paused anywhere in the script and never changes recording state. Unready camera keeps disabled Record plus Choose camera. |
| View, Camera, Text, Microphone, Edit script, More | One idle tools row, including at ordinary widths. Generic Setup is removed. Camera contains picker, guides, exposure, saved output summary and optional second monitor. Text contains Smaller text/Larger text with point values. |
| Before Record | Visible camera identity, microphone identity and explicit level-check action, and destination. A meter reports existing samples only; opening Microphone opts into capture. |
| During reading or recording | Tools recede into More controls popover. Zebras, False colour and Clean view stay on the surface. Recording health stays visible. |
| Saved result | One-line named take button with middle truncation and full AX value; opens full receipt with warning, playback, Finder and retry. Does not add a tall receipt over the script. |
| Notices | Named surface action opens complete recovery message and actions. |
| Popovers | Text fits content; device/settings pages are bounded to display height. Dismissal returns keyboard and accessibility focus to the opener, including nested camera tools. |

Camera entry points describe the purpose: Camera Only opens the existing presenter without a script; the optional second camera monitor explicitly shares the camera and recording. This supersedes the earlier requirement to enlarge every presenter control to the full interface scale, the 60% floor and the requirement that More controls add inline rows.


## Round 9 Builder A amendment

This supersedes the round 8 control cap, moving tools during a take, and earlier no-countdown rule. Interface size governs all presenter controls and popovers without a cap. A stable **Controls** disclosure owns Reading mode, Back to start, View, Camera, Text, Microphone, Edit script and a named Presenter options menu at every size and reading state. The fixed transport keeps Start/Pause (Cancel countdown while settling), Record/Stop and Controls. Secondary controls open in a bounded popover, never over the script within the window's layout. The reserved bottom region must leave at least 65% for the script at 720 × 520 and above. Idle chrome recedes during reading, returning on hover, focus, click or a local key/clicker action.

Output dimensions (or an explicit unknown state), orientation and destination sit below Record before a take. Saved results replace that line with **Show saved take…** or an amber **Saved with problems** receipt naming the fault and review action; Finder is a separate visible button. Camera & Recording uses a local Camera / Recording / Framing / Exposure page selector. Recording includes its folder controls.

Automatic scroll has a remembered **Start delay** of Off, 3 seconds (default), or 5 seconds, independent of recording and reading presets. Starting from any user control honours it; Cancel countdown, Pause, Back to start, closing/changing the script and changing reading mode cancel it. **Present**, **Open Camera Monitor**, **Framing guides**, **Presenter options** and **Controls** are the canonical action names. The icon stays untouched.


## Round 10 Builder A amendment

Supersedes the generic Controls disclosure and output-first status in round 9.

| Job | Placement |
|---|---|
| Reading state and mode | Persistent single-line Reading mode control in every script view, including camera and Clean view. Never fades. |
| Start/Pause, Record/Stop, REC and recording health | Fixed transport and status area at full contrast. Audio warnings use a named Check microphone / Check recording notice with complete wrapping details. |
| Repeated adjustments | Named Text, Camera, Exposure and Microphone entries on a stable tools row. Camera opens the device choices directly; Exposure contains the live aids and Clean view. Only this secondary row recedes, to 75% opacity. |
| Occasional actions | Presenter options beside transport: View, Back to start, Edit script, settings, presets and window actions. |
| Camera recovery | Explanation and next action directly over the picture for blocked access, missing device or waiting picture. |
| Before Record | Plain next action. Format, dimensions and destination details stay in Camera options; Recordings folder is an action there. Saved receipts share the status row and retain their complete warning in take details. |
| Reading notice | Reading status adds Check reading and opens the full notice directly, without another disclosure. |
| Settings | Stable sidebar destinations at every size, bounded by available display width/height. Camera section selector has no redundant visible caption and retains its complete accessible name. |

The protected reading area remains at least 65% at the minimum presenter size. The first reading guidance states that reading does not record. Format recovery selects Recording explicitly. Custom frame fields read and update the stored ratio without substituting default dimensions. The icon is unchanged.

## Round 10 Builder B refinement

| Surface | Visible treatment | Destination or detail |
|---|---|---|
| New/Rename Folder | Small labelled sheet, explicit Folder name field, Cancel and Create/Save | Existing folder actions; empty and whitespace-only names cannot be submitted |
| Start page practice | Quick Reading Practice | Short guided script, opened in the presenter without starting capture |
| Help guide (Builder A call site) | Getting Started Guide | Existing longer welcome guide, selected in the library |
| Editor header | Editable regular title3; quiet save/word count line; matching plain Editor text size and Script details controls below | Both control targets at least 24 pt tall at 100%; existing popover and details; preserve the script's Markdown heading |
| Exposure guidance | Semibold purpose heading, explanation and next action, then labelled brightness swatches and quieter measurements | Preserve received-picture, skin-tone, flat-profile and custom-range caveats |
| Exposure settings toggles (Builder A call site) | Zebras and False colour, each with a short adjacent purpose line, visible when off | Shared ExposureToolToggles view; unchanged guide bindings |

The app icon remains outside the task. This refinement supersedes older practice names and editor title weight/size; it does not move any presenter transport or settings destination.


## Claude review 2 implementation clarification

Save changes (Command Return) and Cancel editing stay on the presenter transport while editing. A paused mid-script take has a direct Back to start arrow at compact widths, without stopping recording. During a take, the status row shows a compact live level from the recording input beside REC; this observes existing samples and does not open another microphone. All popovers use the shared opener-based focus mechanism. Clean view preserves an active reading but cancels a pending countdown; Camera only pauses both. Normal Settings starts the Camera section afresh, while explicit format recovery still opens Recording.

Custom frame dimensions use the same finite, positive, at-most-100 boundary as CLI ratios. Invalid values leave the previous marker intact and show the valid range. Old invalid saved markers are removed on load, preserving other guides. Custom editing remains a distinct user choice even when an intermediate ratio matches a preset.


## Round 11 Builder A amendment

This supersedes the round 10 camera-recovery overlay and output-hidden wording. Section 2 presenter placements now follow this table.

| Job | Placement |
|---|---|
| Camera recovery with a script | Named Camera unavailable action in the reserved bar, beside reading mode when idle. During recording or a saved-take notice, Camera keeps its stable slot and exposes the fault and recovery in its accessible value and popover. Opens full instructions in Camera. The recovery card is never layered on a script. Camera only retains its full picture-area recovery. |
| Reading mode | Native bordered target at least 24 unscaled points high. Full Voice follow / Automatic scroll name remains visible while busy; full state and next behaviour stay in its accessible value and popover. |
| Retake | Named Back to start button beside Start reading whenever paused mid-script. Preserves any ongoing recording. Practice and welcome text name that exact control. |
| Repeated monitoring | Guides directly opens Framing guides, alongside Exposure on the presenter. Wide presenters also expose Zebras, False colour and Clean view directly; narrow presenters retain them one disclosure away in Exposure. Camera Monitor has direct Framing guides and Exposure. |
| Output check | Persistent single-line resolution, orientation and save-folder summary before recording, outside Camera options. Unknown resolution/orientation are stated explicitly. Full format, saved mirroring, rotation, guide-only warning and destination path remain in help/details. |
| Camera subtopics | Camera, Recording, Framing guides, Exposure vocabulary; the existing shared sections and settings are retained. |
| Sound evidence | Waiting for sound until audible samples have been measured in the current take. Sound OK only follows recent audible input. Existing clipping, silence and drop warnings remain. |
| Settings selection | Keep native selection. Resolve its selected foreground explicitly only in offscreen fixtures, where the native selected text otherwise renders black on black. |

No icon, installed app, real library or permissions changes. Presenter controls retain full Interface size. The output summary is one line and the recovery action shares the existing status row to preserve reading height.


## Round 12 Builder B refinement

This supersedes the earlier always-expanded folder height and glass exposure-legend treatment.

| Surface | Visible treatment | Disclosed detail |
|---|---|---|
| Library folder navigation | Folders collapse control; expanded list capped at 30% of the available sidebar height after Interface size, and at 220 unscaled points | The current script scope stays visible above scripts even with folders collapsed; all scopes retain native list selection |
| Exposure monitor key | Tool name, calibrated ranges, six labelled adaptive swatches when enabled, and received-picture/non-universal-face qualification on a stable opaque dark panel | How to read this holds coaching, camera actions, skin-tone and flat-profile qualifications in a bounded scrolling area |
| Camera picker in a recovery host | Host supplies one explanation and one permission action; embedded list uses showsRecovery: false | Standalone pickers retain recovery, without a redundant Refresh action before camera access is granted |

ExposureLegend accepts the actual Interface size as zoom, scales once, and constrains its content width before scaling. Presenter passes controlZoom; existing Camera Monitor outer scaling continues with the default internal scale. Library, import/relink and picker text wraps rather than truncates. Storage and linked-file behaviour are unchanged.


## Round 12 Builder A amendment

Whole control labels take priority over fixed row membership. Presenter transport measures its contents; Back to start moves intact into More when the full transport would not fit. Text, Microphone, Framing guides and exposure configuration remain in the named More menu as secondary tools. Camera, the Exposure on/off comparison and Clean view stay on the compact camera bar. Exposure comparison preserves the configured tools/levels using the existing preview bypass.

Reading mode always shows its short operational state and countdown. Compact automatic scrolling is labelled Auto; Voice follow retains its name. Normal sound status has quieter styling; important recording recovery remains a named control. A compact saved-take receipt occupies the secondary tools row. Output metadata is omitted when the camera needs recovery; full destination details and a named Finder folder action remain reachable.

Settings uses its native sidebar only when full scaled destinations and the content pane fit; otherwise a fully named native page menu replaces it. Camera & Recording retains a labelled section selector. Custom ratio labels sit above their fields. Explanatory panels use a stable opaque surface; glass belongs to controls.

Builder B supplies CameraPickerList showsRecovery (default true) and internally scaled ExposureLegend zoom (default 1); the presenter requests false and controlZoom respectively.


## Round 13 Builder B refinement

- Exposure monitor key leads with the checking action. All six colour bands, labels, calibrated limits and the zebra threshold remain visible without scrolling at 100/150/200%. Only teaching text scrolls inside the initially collapsed How to read this disclosure. The received-picture qualification stays beside the key; face and flat-profile caveats stay with face guidance.
- The visible Folder actions menu includes New Folder, Rename Folder and Remove Folder, Keep Scripts. Rename and remove apply to the selected folder and are disabled for All Scripts and Recently Deleted. Existing row context menus remain.
- The editor size popover includes a direct Reading text size… action to the existing Settings > Reading page. Editor and reading sizes remain independent.
- The compact exposure comparison should be labelled Exposure check with an explicit aid/bypass state, rather than sounding like a camera setting. Its PresenterController call site belongs to Builder A.


## Round 13 Builder A amendment

- Settings keeps a native, wrapping sidebar beside a full-height content pane at 100/150/200%. Navigation does not take vertical space from the form.
- Presenter tools preserve their order and membership across Interface size. Whole controls wrap inside a bounded secondary scrolling region, leaving transport outside scrolling and protecting the script. Automatic scroll keeps its full name.
- Exposure check reports Aids visible, Aids bypassed, Off, or Hidden in Clean view. Tool switches reflect the effective preview; enabling either aid restores it from bypass/Clean view. Saved configuration survives comparison.
- The exposure key is shown while paused; starting reading/countdown hides the teaching key while keeping the chosen preview effects active.
- Failed takes show a short cause plus one direct recovery action; damaged saved takes show a short cause plus Review problem. Long details stay in the receipt.
- Saving shows saving and recorded drop counts only, never live silence/clipping advice.
- Use Show Recordings Folder for the folder command, and Receiving sound for healthy active input. Exposure guidance starts with the camera action.

## Settled rules (lead decision after round 14; do not reverse without new evidence from two or more reviewers)
- Exposure key: shown only while an exposure tool is on. It is a thin strip pinned to the bottom edge of the camera picture (never over the script's reading lane, never over the centre of the frame). At 150/200% it stays one line high and the colours stay visible; numbers and teaching open from a small "Key" button. Exposure aids default to two simple switches (Zebras, False colour) plus Face reference; custom levels live one level down.
- Enlarged presenter: the transport row (Start/Pause, Back to start, Record) keeps a fixed order and position at every size and never wraps. Everything else goes into one clearly labelled "Tools" menu with a visible chevron, organised by job (Text, Camera, Exposure, Microphone), not a feature inventory. Retake controls at 200% use the transport row, not an extra panel.
- Clean view hides overlays on the presenter only; a second camera monitor keeps its own overlays.
- Compact mode keeps a one-line output check (orientation and resolution) visible.
- "Camera Only" names only the launch action; the view is called "Camera view".


## Round 15 Builder A refinement (authorised Tools refinement)

This refines the settled Tools rule without changing the fixed transport or camera naming.

| Job | Current placement |
|---|---|
| Tools | One button with visible chevron opens a bounded working popover, not a command inventory. At most four sections: Text, Camera, Exposure, Microphone. Each has 2–4 common actions and one More … settings link. |
| Text | Smaller text, Larger text, Reading mode, Edit this script; More text settings opens Reading. Reading presets remain on the named Settings page. |
| Camera | View, Choose camera, Framing guides; More camera settings opens Camera & Recording. Recording, Exposure and Saved shoot setups are named sections there. Rare window, pin and sizing actions live in its Camera section and keep menu shortcuts. |
| Exposure | Zebras, False colour, Bypass/Restore exposure aids, Clean presenter view; More exposure settings opens Exposure. Comparison never enables an aid. A bypass/clean state and Restore action remain visible on the presenter while configured aids are hidden. |
| Microphone | Microphone choice and Check sound; More microphone settings opens Microphone. No sound capture starts just by opening Tools. |
| Status and recovery | Whole state words wrap above/below the fixed transport as needed. Reading problems have a direct Check reading action. Camera permission recovery names the actual next step. Receipts wrap whole actions and messages. |
| Output check | Orientation/resolution stay visible when the camera is ready. Opening Output check shows the full microphone and recording format in a wrapping line; its accessibility value includes both, preserving the 65% reading-area floor at 200%. |
| Saved shoot setups | Settings > Camera & Recording > Saved shoot setups owns saving, applying, renaming and deleting. Reading presets begins with reading presets only. |
| Camera names and Clean scope | Camera Only is the launch action; Camera view is the presenter view; Camera window is the separate window. Clean presenter view hides script, framing and exposure overlays in the presenter only; Camera window overlays remain. |

The full guide uses current control labels. Its emphasised control names are checked against UI declarations; behaviour and geometry are separately tested offscreen at 720 × 520 and 100/150/200%.


## Round 16 Builder A refinement

Authorised by round-16 UX, visual and creator findings. The fixed transport, single-row exposure key and presenter-only Clean view remain settled.

| Job | Placement and behaviour |
|---|---|
| Whole-shoot setup | Top-level Settings > Shoot setups, and first group in Tools > Shoot setups. The same ShootSetupSection owns all management. Successful Apply offers Restore previous setup on that page until used or replaced by another successful Apply. Failed Apply preserves the existing recovery. |
| Presenter help | First group in Tools > Presenter help, outside camera configuration. |
| Primary status | Reading mode, pace and state at the leading side; recording state at the trailing side. Reading status opens mode/speed directly. Compact automatic mode shows Auto and the state; its direct popover shows pace, with full Automatic scroll in its accessible value. Draft state visibly reads Editing · not saved yet. |
| Secondary status | Smaller microphone health and output details. The one-line orientation/resolution check remains, with a visible Saves to folder line. Output check opens full orientation, resolution, frame rate, microphone, format, mirroring and destination before recording, plus the shared recording controls. Unknown values stay explicit. |
| Recording choices | Tools > Recording settings opens the shared recording controls directly. Camera & Recording is one continuous grouped form with visible Camera, Recording, Framing guides and Exposure jump buttons, not a hidden subpage picker. Explicit recovery routes scroll to the requested section. |
| Separate window | Second monitor window is the window title; Open Second monitor window is the command. Camera view remains the presenter mode; Camera Only remains the launch action. |
| Format commands | Enabled only when the executing FormattingTextView is editable and has a format handler. |
| Setup errors | Primary text with a warning symbol; normal-text contrast measured in both appearances. |

QA round 10 adds unique-ID repair on load and every save, single-item deletion, unresolved guide transfer to the first selected camera, and inventory discovery on opening Choose camera without requesting access.

Round 16 layout note: when reading needs attention, Check reading replaces the primary reading-status opener and retains the complete mode/state/problem in its accessible value. This avoids another permanent status-row control.


## Round 16 Builder B refinement

- Keep the settled one-row, six-colour strip and Key popover. Four captions map
  purple/blue to **Too dark**, green/pink to **Mid-tones**, yellow to **Bright**,
  and red to **Clipping**. Clipping describes the near-white received picture,
  not proof of camera sensor clipping. At narrow widths where the captions do
  not fit, retain all six swatches and Key rather than clipping the opener or
  shrinking the text. Key and accessible help make that limit
  explicit; the colour engine and ranges stay unchanged.
- Exposure controls lead with the job before the technique: **Find blown
  highlights · Zebras** for bright-area checks, **Check brightness · Zebras**
  for the qualified reference, **Check custom brightness · Zebras** for custom
  levels, and **Check brightness · False colour**. Stripes flag areas to inspect;
  they do not prove lost detail. Face guidance stays with the **Face reference**
  explanation, including varied skin tones and flat-picture qualifications.
- Editor and Reading sliders use native sliders with a verified minimum
  24-point interactive height at 100%, scaling with Interface size. Preserve
  native tracking, focus and spoken values.
- The **Editor text size** opener has a disclosure chevron matching **Script
  details**, with the existing 24-point target and exact-opener focus return.
  Save state, word count and Linked remain quiet metadata.

Combined implementation: immediate Tools exposure switches reuse ExposureToolToggles. Native 24-point sliders also serve presenter pace, framing guide visibility and microphone volume.

## Round 17 Builder A refinement

Three independent reports (first-time user, creator workflow and accessibility) identify serial searching for picture jobs; this is the evidence required to refine the settled Tools rule. The fixed transport order, full scaling, camera naming, high-contrast take warnings and the bottom-edge exposure key remain binding.

| Job | Placement and behaviour |
|---|---|
| Check the picture | A compact Picture row, with Tools at its trailing edge, is visible whenever a camera is shown: Guides toggles the configured framing overlay (thirds on first use), Exposure check toggles the configured exposure aids (brightness colours on first use), Switch camera opens the existing picker. Turning either check off retains its configuration. Framing bypass affects only the presenter. Camera switching remains locked during a take. |
| Full tools | Tools opens one selected job at a time, with a named Text / Camera / Exposure / Microphone section picker. Text is the script default; Exposure is the monitor default. More holds Shoot setups, Presenter help and Recording settings. No microphone capture starts from opening Tools. |
| State versus configuration | Reading state is unboxed semibold text with a direct mode/speed action, retaining Automatic scroll at every size. Recording and health remain explicit. Output check retains one concise orientation/resolution line; destination and complete output details are disclosed there. Camera view retains Record as a secondary action. |
| Microphone volume | The shared page and compact popover display percentage, one-percent steps and Reset to 100%. The label explains that gain affects voice following and its test, not saved audio or speakers. |
| Reading scope | The shared Reading page, mode popover and Text tools all state that changes apply to all scripts. |
| Exposure labels | App menu and second-monitor buttons reuse Builder B's job-first zebra title and Check brightness · False colour. Technique and brightness qualifications stay unchanged. |
| Output certainty | Resolution in every output summary is based on the received picture. Device configuration alone cannot establish the received resolution. |

Round 17 integration: merged Builder B f8d1d3d. The shared Reading page owns its scope sentence; no duplicate was added by Builder A. The Picture row uses visible checkmarks plus accessible On/Off or bypass values. It replaces the old separate Restore exposure aids notice. Reading status remains a 24-point minimum target, and the ready/paused 720 × 520 presenter preserves 65% for reading at 200%. Camera view places its title at the leading side and the secondary Record action at the trailing side.

Round 17 recording/receipt refinement: recording health and its live meter sit beside REC on the status row, with the recording microphone named in help and the health detail. A take receipt temporarily replaces the Picture row, as allowed by the existing receipt rule; Tools stays available on the status row. This retains the full 65% reading budget at all six Interface sizes in the existing idle, countdown, reading, waiting, recording and three warning fixtures.

## Round 19 Builder refinement (7 November 2026, lead authorised)

| Finding | Placement and behaviour |
|---|---|
| Quick picture controls during a receipt (creator) | A clean saved take keeps Guides, Exposure check and Switch camera and adds a Last take opener (checkmark, Saved, duration) at the row's trailing edge; its popover is the full receipt. Saved with problems and failed takes keep the full receipt row until Hide. The transport is not displaced. |
| Save Reading Preset silently replacing (UX) | When the entered name matches an existing preset the button reads Replace “Name”, a line says the saved look will change, and after activation Replaced “Name” shows with an Undo button. A new name keeps Save Reading Preset. |
| Idle controls say Stop recording (first-time user) | The recording setup section carries "Stop recording to change this" only while `settingsLocked` is true. |
| Generic More menu (first-time user) | Tools lists Before recording check…, Shoot setups…, Presenter help… and Last take directly under the selected section. |
| Lower chrome weight and height at 150/200% (visual) | State band weights and wrapping as described under the frozen footer. The three-band order, the 65% floor and the vocabulary are unchanged. |
| Tall Tools popover for small sections (visual) | The Tools surface sizes to its content and keeps the bounded scrolling viewport for enlarged content. |

Verified by `RoundNineteenTests`, the updated `FinalFooterTests` state matrix (with a Waiting for picture state) and the `fable-bar-*` / `fable-tools-*` fixtures.
