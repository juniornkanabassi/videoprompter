# Video Prompter design system

The 6 November 2026 design specification is authoritative. This is the durable interface contract, replacing earlier round-by-round notes. Preserve existing saved settings and features. Library and Settings use native macOS controls; presenter chrome follows the glass rules below.

## 0. Principles

These settle every argument the reviews kept reopening.

1. **Doing is on the surface, choosing is one level down.** Anything the creator *does* during a session (start reading, record, stop, check exposure, see the clean picture) is a button on the presenter bar. Anything they *choose* once (fonts, formats, thresholds) lives on a settings page.
2. **One home per setting.** Every setting is fully configured on exactly one page view. That page may be shown in the Settings window or in a presenter popover, but it is the same view type with the same bindings. A setting may also have at most one *quick control* elsewhere (listed in section 2.7). The quick control uses the same label and the same binding. There are no signpost pages.
3. **The transport never moves or hides.** Reading state, Start/Pause, Record/Stop and the recording timer sit in one fixed row in a fixed order. They are never inside a popover, a scroll view or a "Show controls" state.
4. **Reading and recording stay separate actions.** Neither starts the other. Each has its own button next to the other one.
5. **Enlarging means fewer things, not more rows.** At bigger interface sizes, the same controls get bigger and secondary ones fold into menus. The script keeps at least 60% of the presenter's height.
6. **Words over icons.** Every bar control has a visible word. Icons support the word.

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
| Reading presets | Settings > Reading presets | Presenter More ▸ Reading presets |

Interface size is under General only, plus ⌘+ / ⌘− / ⌘0.

## 7. Vocabulary

One name per concept. UI text, help text, accessibility labels, menus, the Welcome Script and the README use these words. Menu items use title case of the same words.

| Concept | Use | Never use |
|---|---|---|
| A piece of text to read | script | document, file (unless it is the linked file) |
| The floating reading window | presenter | prompter window, camera-only presenter |
| What the presenter shows | view: Script only, Script and camera, Camera only | Presenter view, Video only, Prompter only |
| Making the words move | Start reading, Pause, Back to start | Start or Pause (menu only), play |
| Following modes | Voice follow, Automatic scroll | Manual, Timed |
| Recording the camera | Record, Stop recording | Record camera, Record Camera |
| One recording | take | clip, recording file |
| Where takes go | Recordings folder | Movies folder, output folder |
| After a take | Saved [file name] · Play · Show in Finder · Hide | Review last take, Dismiss receipt |
| The input device | microphone | mic (except "Mic:" in the health line), input, following microphone |
| Second device (advanced) | recording microphone | microphone saved with video |
| Exposure stripes | Zebras | zebra stripes, stripes |
| Brightness colours | False colour | |
| Skin preset | Face brightness | Skin exposure check |
| The picture with nothing over it | Clean view | Clean picture, Hide exposure aids |
| Composition lines | Framing guides (Guides in compact) | |
| Output shape outline | Frame marker | |
| Saved reading looks | Reading presets | Saved settings |
| Text sizes | Reading text size, Editor text size, Interface size | Text size alone in Settings |
| Editing in the presenter | Edit script, Save changes, Cancel editing; status "Editing · not saved yet" | Finish editing |
| Second camera window | Camera Monitor | Separate Camera Monitor, separate camera monitor |
| Pasting a script | Paste Copied Text | Paste as New Script |
| Folder removal from a script | No Folder | All Scripts (as a destination) |
| Codec choice | Recording format: H.264 (most compatible), HEVC (smaller files), ProRes 422 (for editing) | Recording quality, Standard, High, Edit |

## 8. Visual rules

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
SF Symbols only, `.symbolRenderingMode(.hierarchical)`, weight matching the label. Filled variants mean "on". Red is reserved for recording and for problems. The app icon is out of scope for this spec.

## Verification

Run `zsh test.sh`, `zsh checks/check-snapshots.sh` and the included grid check. Inspect every changed light and dark image. All tests and renders stay offscreen with disposable scripts and preferences. Offscreen renders do not prove live glass, hardware recording or spoken VoiceOver.

## Round 5 refinements

These implement the council follow-up to the authoritative design specification.

- The two-column library keeps folder navigation visible above the script list at
  every interface size. Both lists draw native selection. Selected text uses the
  semantic active or inactive selection colour; no fixed blue row backgrounds.
  Folder removal and renaming are available on the folder's context menu.
- The writing control is labelled **Editor text size** before it is opened. Its
  explanation points to the presenter Text control and Settings > Reading.
- **Try the Practice Script** saves/selects a short guided practice and opens the
  presenter. It never starts a microphone or recording. Instructions reflect the
  selected following mode, without changing the user's saved mode.
- The start page explains that Voice follow moves the text as the user speaks
  after **Start reading**. Add also exposes the existing Google Docs import.
- Save feedback and camera recovery copy use primary text at callout size in both
  appearances. Their contrast is measured from final rendered PNGs, not assumed
  from semantic colour names.
- Exposure guidance describes what stripes mean, checks the lit cheek only as a
  standard-video reference, and keeps skin-tone/profile qualifications visible.
  The false-colour key explains every colour in terms of detail and brightness.
- Reading contrast uses a conservative bound over all possible camera pixels,
  includes dimmed cues/confirmed words and the active-word colour, and uses 4.5:1
  below 24 pt or 3:1 for large reading text. Make Readable changes only backdrop
  darkness; an impossible combination explains which preferences need changing.
  Backdrop labels identify the camera or script-only scope. Show Presenter offers
  a direct way to preview the reading settings.
- Modern app-icon artwork consists of editable vector objects in three native
  Icon Composer groups. The system applies the outer mask. Default, dark and
  tinted appearances are exported at 16, 32, 64 and 128 points for inspection.


## Round 7 Builder B refinement

- Library (section 2.1): keep two columns. Label folder navigation and the current script scope separately. Folder creation is a quiet Folder actions menu beside its heading. Below 560 points per interface scale, collapse the sidebar with the native toggle retaining access. The library minimum width is 640 points. Linked-file destination and Unlink stay below save status. Saved remains visible until the next edit.
- Start page (section 2.1): place Try the Practice Script immediately after the reading instruction, before Camera Only and secondary import/write choices. At larger sizes use the smaller existing heading style so the teaching route fits.
- Camera picker: at 150/200%, keep the preview and its caption visible above a bounded scrolling list of camera choices and permission/recovery actions. Keyboard selection scrolls its row into view.
- Readability (section 8.5): evaluate both camera and script-only backdrops, including translucent backgrounds, dimmed words, stage directions and the active-word colour. Describe the complete proposed change before Make Readable. Prefer only increasing the relevant backdrop opacity. If impossible, use white text on solid black at full visibility, preserving highlighting and stage directions unless their dimming fails the threshold. Expose Undo Make Readable immediately.
- Exposure legend: use practical decisions and plain brightness descriptions. A nonzero custom range never implies a face target. Numerical received-picture measurements are secondary details.
- Icon: simplify the existing editable vector layers, strengthen page/reading-marker separation, and remove fine microphone seams so the modern renditions remain distinct at 16 and 32 points.


## Round 8 Builder B refinement

This section supersedes the earlier editor-header and icon wording above.

| Surface | Visible by default | Disclosed detail |
|---|---|---|
| Editor header | Editable regular-weight title; one muted save-state/word-count line; Text size and Script details together; compact Linked indicator | Script details contains tags, linked filename, two-way editing explanation and Unlink file. Broken-link recovery stays visible. |
| False-colour monitor key | Six colour swatches, short brightness labels and the renderer's ranges, labelled as the received picture | Help contains colour explanations, skin-tone/profile qualifications and zebra calibration. The swatches are a key, not a continuous scale. |
| Preset empty state | Primary callout guidance | No detail required. Verify normal-size foreground/background pixels at 4.5:1 or above in each appearance. |
| Library Text size and camera picker | Existing named opener | Dismissal returns keyboard and native accessibility focus to that exact instance, including nested and repeated openers. |
| Icon | Script page, reading marker and lens | Layered Icon Composer source with default/dark/tinted artwork and matching optical ICNS. |

Quiet metadata still needs readable contrast. Use 75% of the resolved primary
label colour rather than the low-contrast system secondary label on plain editor
backgrounds. Keep explanations in primary callout text. Reading-size button work
in PresenterController.swift belongs to Builder A; its required labels are
Smaller text and Larger text with the current point value and disabled limits.

## Round 9 Builder B refinement

- Keep Paste Copied Text primary and show Try the Practice Script as a native
  bordered secondary button immediately below the reading instruction.
- Label the library opener Editor text size. Its explanation names Reading text
  size in Settings > Reading and the presenter's Text control. Slider values use
  at least the callout tier with monospaced digits, never caption text.
- Size the folder list for its rows plus modest inset padding, capped at 220
  unscaled points with scrolling. Scripts takes the remaining sidebar height.
- Keep visible menu indicators on library menus and enlarged reading choices.
- Exposure titles name the job first: Check bright areas, Check your face, or
  Check custom brightness for Zebras, and Check brightness for False colour.
  Keep the received-picture qualification and state beside the false-colour
  swatches that grey shows brightness between the coloured bands.

## Round 10 library and exposure refinement

- New Folder and Rename Folder use a labelled native sheet. The actual input
  exposes Folder name, including before typing; Create/Save is unavailable for
  a blank or whitespace-only name. The existing folder actions are unchanged.
- Quick Reading Practice opens the short rehearsal in the presenter. Getting
  Started Guide in Help selects the longer welcome guide in the library.
- The editor title is regular title3. Metadata stays at callout size and the
  established readable muted colour. Editor text size and Script details use
  matching plain controls with at least 24-point-high targets at 100%. Their
  focus indication remains native. The Markdown heading stays in the script.
- Exposure guidance reads in this order: semibold job/purpose, what to look for,
  what to do on the camera, then calibration details. False colour retains the
  six labelled swatches and renderer ranges; numbers are quieter than actions.
- Each exposure settings toggle has a purpose line alongside it, visible when
  off as well as on, through ExposureToolToggles. Face guidance retains the
  selected reference, varied skin tones and flat-profile caveat. Custom ranges
  never imply a face target. None of these controls changes the saved picture.
- The original app icon is unchanged; earlier icon-edit directions do not apply.


## Review 2 corrections

- While editing, Save changes (Command Return) and Cancel editing replace Start reading on the transport. The shortcut is active before More is opened.
- A paused mid-script take has a direct Back to start arrow on the transport, including compact sizes. It resets reading without changing the take.
- During recording, a compact live meter beside REC observes the recording input already being captured. It starts no second microphone. Health remains a separate named recovery control.
- All popovers use the shared opener-based focus restoration.
- Entering Camera only cancels reading and its countdown. Entering Clean view cancels a pending countdown, while an already running reading continues.

- Custom frame dimensions must be finite, greater than 0 and no more than 100, using the same rule as CLI input. Invalid input retains the current marker and explains the range. Saved invalid markers are removed on load without changing other guide settings. The Custom editor stays open when an intermediate value matches a preset.


## Round 11 Builder B clarification

- Direct-paste users see a short Voice follow explanation above the editor as
  well as on the start page. Got it dismisses the editor tip for that library
  window session, across script changes. It does not alter or save script text.
- Camera rows say Selected and/or Highlighted, never Previewing merely because
  a row is highlighted. Blocked camera access is named and its recovery action
  remains available even when macOS can enumerate devices.
- Exposure switches own their purpose lines. Guidance below the preset names
  what to look for and gives one camera action with stronger weight. The monitor
  key keeps its six swatches and quieter calibrated values after that guidance.
  Retain skin-tone, flat-profile and custom-range qualifications.
- The Reading mode target remains Builder A's PresenterController responsibility.
