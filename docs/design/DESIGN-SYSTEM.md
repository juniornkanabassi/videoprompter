# Video Prompter interface tokens

Application controls keep macOS semantic colours, native controls and text styles. The script's font, colour, size and background are saved user choices and remain independent.

`Sources/VideoPrompter/UI/DesignTokens.swift` owns the four-point spacing scale. Use `Space.xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (20), `xxl` (24) and `section` (32). Page margins use `Space.margin` (20). Native form and toolbar spacing stays under system control. Hairlines and compact row dividers may use 1 or 2 points. Image aspect ratios and live script/camera geometry are not spacing tokens.

Use `UIType.heading`, `body`, `secondary` and `caption` for application copy. These are semantic SwiftUI fonts, not fixed point sizes. Presenter fonts stay controlled by the saved script settings.

The grid check rejects off-grid literal padding, stack spacing and corner radii in the audited application chrome. Runtime text/camera positioning and the established reading line are excluded so the typography cleanup cannot alter scrolling or speech following.

Run `python3 checks/check-grid.py` and `zsh checks/check-snapshots.sh`. Snapshot output is intentionally offscreen native content, not a screen capture. Review the emitted PNGs; toolbar glass, active-window appearance and hardware video still require a live check.
