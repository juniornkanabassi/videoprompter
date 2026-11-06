# Video Prompter interface tokens

Application controls keep macOS semantic colours, native controls and text styles. The script's font, colour, size and background are saved user choices and remain independent.

`Sources/VideoPrompter/UI/DesignTokens.swift` owns the four-point spacing scale. Use `Space.xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (20), `xxl` (24) and `section` (32). Page margins use `Space.margin` (20). Native form and toolbar spacing stays under system control. Hairlines and compact row dividers may use 1 or 2 points. Image aspect ratios and live script/camera geometry are not spacing tokens.

Use `UIType.heading`, `body`, `secondary` and `caption` for application copy. These are semantic SwiftUI fonts, not fixed point sizes. Presenter fonts stay controlled by the saved script settings.

The grid check rejects off-grid literal padding, stack spacing and corner radii in the audited application chrome. Runtime text/camera positioning and the established reading line are excluded so the typography cleanup cannot alter scrolling or speech following.

Run `python3 checks/check-grid.py` and `zsh checks/check-snapshots.sh`. Snapshot output is intentionally offscreen native content, not a screen capture. Review the emitted PNGs; toolbar glass, active-window appearance and hardware video still require a live check.

## Reading and library hierarchy

`Library/ReadingInspectorView.swift` is the shared reading configuration. `InspectorView` remains an alias for compatibility. Keep the view/mode/font/size decisions visible and the detailed spacing, guide, backdrop and cue controls disclosed. Enlarged popup controls must retain a full readable current-value label even when the native popup abbreviates its title. Slider values must include units in accessibility values.

The first-launch library starts with the user's job, not appearance controls. Keep library scopes independent from the scrolling document list and keep routine metadata in Script details. Broken-link and failed-save recovery stays visible. In rendered Markdown, callout blocks use the available text width and primary text for their titles; colour is supporting decoration. Hidden presenter cues must also be absent from accessible/selectable text, with source mapping retained for seeking.

## Round 3 library and reading controls

The library sidebar has one compact scope selector and one document list. Folder
management and the recordings-folder action live in the adjacent Folder actions
menu. Scope is a filter, not a second highlighted document. The start page does
not highlight Welcome until its script is displayed. Rows use two lines with a
full-title tooltip so the list remains useful with hundreds of scripts.

Reading settings is the single home for reading and editor typography. The
editor and Settings > Editor link there. Interface size remains under General,
with a link from Reading. At 150% and above, the library opens Reading settings
in a wide sheet rather than narrowing the editor around three large columns.
The shared groups resolve their background and label colours explicitly because
native grouped Form surfaces can resolve white inside a dark split-view host.
Section titles, labels and short explanations remain distinct without faint text.

Relinking shows additions and removals first, using written labels, bold and
underlines. Full original versions remain available. Camera keyboard previews
scroll their highlighted row into view and empty states offer a privacy-settings
route plus Refresh. No preview hover requests camera permission.
