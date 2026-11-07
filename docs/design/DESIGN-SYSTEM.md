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

Shared chrome colours live in `UI/DesignTokens.swift`: `Surfaces.presenterPanel` (0.12 white, 0.08 with Increase Contrast), `Surfaces.scrim` (90% black), and `Palette.onDarkQuiet` (80% white, 100% with Increase Contrast). `Palette.quietOpacity` raises quiet primary labels to full contrast.


### 8.1 Materials
- Presenter bar: one `GlassEffectContainer` with `.glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 20))`. Under Reduce Transparency, a solid `Color(white: 0.12)` fill. `.regularMaterial` is removed from the presenter.
- Bar buttons: `.buttonStyle(.glass)`. Start reading uses `.glassProminent` with the accent tint. Record uses `.glass` with a red record symbol; while recording, the Stop button is `.glassProminent` tinted red.
- Notices above the bar retain tinted glass, radius 12. Exposure legend explanatory content uses an opaque dark panel, radius 12; Liquid Glass is reserved for controls.
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


## Round 12 Builder B refinement

This supersedes the earlier always-expanded folder height and glass exposure-legend treatment.

| Surface | Visible treatment | Disclosed detail |
|---|---|---|
| Library folder navigation | Folders collapse control; expanded list capped at 30% of the available sidebar height after Interface size, and at 220 unscaled points | The current script scope stays visible above scripts even with folders collapsed; all scopes retain native list selection |
| Exposure monitor key | Tool name, calibrated ranges, six labelled adaptive swatches when enabled, and received-picture/non-universal-face qualification on a stable opaque dark panel | How to read this holds coaching, camera actions, skin-tone and flat-profile qualifications in a bounded scrolling area |
| Camera picker in a recovery host | Host supplies one explanation and one permission action; embedded list uses showsRecovery: false | Standalone pickers retain recovery, without a redundant Refresh action before camera access is granted |

ExposureLegend accepts the actual Interface size as zoom, scales once, and constrains its content width before scaling. Presenter passes controlZoom; existing Camera Monitor outer scaling continues with the default internal scale. Library, import/relink and picker text wraps rather than truncates. Storage and linked-file behaviour are unchanged.


## Round 13 Builder B refinement

- Keep the exposure scale outside scrolling. All six named bands and their
  limits, including the bright and near-white bands, and the zebra threshold
  stay visible at 100%, 150% and 200%. Only the initially collapsed How to read
  this teaching section scrolls. Lead with the checking action; place the
  received-picture qualification after the scale and face caveats in the help.
- Folder actions offers New Folder, Rename Folder and Remove Folder, Keep
  Scripts. The last two act on the selected folder; All Scripts and Recently
  Deleted disable them. Row context menus remain shortcuts to the same actions.
- Beside the editor-only size explanation, Reading text size… opens Settings >
  Reading directly. Editor and presenter sizes remain independent.
- The compact presenter's comparison should read Exposure check and state
  whether aids are visible or bypassed. Its call site is owned by Builder A.

## Settled round 14 contents (Builder B)

- ExposureLegend is one line: six swatches and a small **Key** button with
  a chevron. At 100/150/200% its height is determined only by the button and
  padding. Its four short labels are Very dark, Mid-tones, Bright and Near white,
  with no wrapping. Yellow belongs only to Bright; Near white covers the red band.
  Numerical measurements stay in Key. Builder A anchors it to
  the bottom of the camera picture, outside the reading lane.
- Key opens a bounded scrolling popover. The first line says what to do on the
  camera; colour names, renderer ranges, received-picture calibration and
  skin/profile qualifications follow. Closing returns to the exact Key opener.
- ExposureSettingsContent is the shared Exposure form contents: two switches,
  Face reference first in Zebra reference, Bright areas second. Existing custom
  settings are preserved. Custom levels and explanatory details are disclosed.
  Host integration: CameraExposureSections in CameraWindow.swift delegates to
  ExposureSettingsContent(model: model), replacing its old Section contents.
- PresenterToolsMenu supplies a word-labelled **Tools** opener with an explicit
  chevron and accessibility hint. Builder A supplies the Text, Camera, Exposure
  and Microphone job sections and places the menu in the enlarged presenter.
- The editor's session-only tip is one muted, dismissible line. It does not
  change script text. Quick Reading Practice says “Try reading for 30 seconds”.
  Getting Started Guide names the full guide to writing, reading and recording,
  both at entry and when selected. Neither is required before pasting a script.
- Camera picker entry focuses the selected camera row, falling back to the first
  row, while retaining arrow navigation and exact-opener focus on exit.


## Round 15 reading and exposure refinement

- Reading presets is exclusively the reading-preset destination. Save and Apply
  reading presets come first; Saved shoot setups belongs on its own clearly
  named camera/recording route. Reading presets preserve the separate microphone
  and spoken-language choices. The settings host owns this separation.
- The Library-owned reading preview follows the layout controls in their section.
  Two short paragraphs use the presenter's Markdown renderer, including an active
  word and emphasis. Font size, weight, text width, alignment, line and paragraph
  spacing, colour, mirroring and rotation use the current settings. Rendering at
  65% scales spacing after layout styles are made. Its height is bounded; larger samples scroll. It starts no reading session.
- Exposure switches have plain-language subtitles while off as well as on.
  Face reference describes stripes on the lit side of a face before selection;
  skin-tone and flat-profile qualifications remain beside the camera advice.
- The bottom-edge false-colour strip stays one row with all six renderer colours.
  Very dark, Mid-tones, Bright and Near white identify its groups at callout size. Labels sit
  below a thin bar with ticks on the opaque dark backing, never on bare bright colours.
  No strip band names a face target. Key retains exact ranges,
  grey-gap explanation and the received-picture qualification. The host keeps
  this strip outside the reading lane and centre of the subject.


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

Round 16 layout note: Check reading replaces the reading-status opener while a reading problem needs attention, retaining mode/state/problem in the accessible value.

## Round 16 Builder B refinement

- Keep the settled one-row, six-colour strip and Key popover. Four captions map
  purple/blue to **Very dark**, green/pink to **Mid-tones**, yellow to **Bright**,
  and red to **Near white**. Near white describes the near-white received picture,
  not proof of camera sensor clipping. At narrow widths where the captions do
  not fit, retain all six swatches and Key rather than clipping the opener or
  shrinking the text. Key and accessible help make that limit
  explicit; the colour engine and ranges stay unchanged.
- Exposure controls lead with the job before the technique: **Check bright
  areas · Zebras** for bright-area checks, **Check brightness · Zebras**
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


## Round 17 Builder B refinement

- Keep the bottom-edge key, six original measurement colours and their exact
  received-picture ranges. The key is a quiet, discrete scale: a thin colour
  bar, small ticks and neutral labels below it. It never implies a continuous
  range; the detailed Key explains grey gaps. At narrow widths, keep all six
  colours and Key without shrinking captions.
- The four captions are Very dark, Mid-tones, Bright and Near white. The red
  band describes received brightness, never a verdict that detail is lost.
  Bright-area zebras are labelled Check bright areas · Zebras. Key begins with
  “Your camera’s own monitor is the final judge of exposure.” Face-reference,
  flat-picture and custom-range qualifications remain with their guidance.
- First use demonstrates Add text, Present and Read with three clickable
  illustrated steps. The labelled example never changes scripts or settings,
  starts capture or requests permission. Paste stays primary and Quick Reading
  Practice remains directly available; Camera Only remains in the first
  enlarged viewport. Reading and recording remain separate.
- Reading settings explicitly apply to all scripts. The editor’s Reading text
  size link uses underlined primary text with a 24-point target, aiming for
  at least 7:1 contrast in both appearances.
