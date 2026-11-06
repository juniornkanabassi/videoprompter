# Video Prompter interface tokens

Application controls keep macOS semantic colours, native controls and text styles. The script's font, colour, size and background are saved user choices and remain independent.

`Sources/VideoPrompter/UI/DesignTokens.swift` owns the four-point spacing scale. Use `Space.xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (20), `xxl` (24) and `section` (32). Page margins use `Space.margin` (20). Native form and toolbar spacing stays under system control. Hairlines and compact row dividers may use 1 or 2 points. Image aspect ratios and live script/camera geometry are not spacing tokens.

Use `UIType.heading`, `body`, `secondary` and `caption` for application copy. These are semantic SwiftUI fonts, not fixed point sizes. Presenter fonts stay controlled by the saved script settings.

The grid check rejects off-grid literal padding, stack spacing and corner radii in the audited application chrome. Runtime text/camera positioning and the established reading line are excluded so the typography cleanup cannot alter scrolling or speech following.

Run `python3 checks/check-grid.py` and `zsh checks/check-snapshots.sh`. Snapshot output is intentionally offscreen native content, not a screen capture. Review the emitted PNGs; toolbar glass, active-window appearance and hardware video still require a live check.

## Reading and library hierarchy

`Library/ReadingInspectorView.swift` is the shared reading configuration. `InspectorView` remains an alias for compatibility. Keep the view/mode/font/size decisions visible and the detailed spacing, guide, backdrop and cue controls disclosed. Enlarged popup controls must retain a full readable current-value label even when the native popup abbreviates its title. Slider values must include units in accessibility values.

The first-launch library starts with the user's job, not appearance controls. Keep library scopes independent from the scrolling document list and keep routine metadata in Script details. Broken-link and failed-save recovery stays visible. In rendered Markdown, callout blocks use the available text width and primary text for their titles; colour is supporting decoration. Hidden presenter cues must also be absent from accessible/selectable text, with source mapping retained for seeking.
