# Package E review evidence

These are offscreen NSHostingView captures of the real SwiftUI shell, using TestOffscreen and `startsCamera: false`. No app was opened and no camera or microphone permission was requested.

- `pkgE-setup.png`: setup with zebras
- `pkgE-setup-200.png`: the same bar at 200%, wrapping with every label retained
- `pkgE-reading.png`: reading transport and compact exposure key
- `pkgE-clean.png`: picture only, exit pill hidden at rest
- `pkgE-adjust-Camera.png`, `pkgE-adjust-Zebras.png`, `pkgE-adjust-False colour.png`, `pkgE-adjust-Guides.png`, `pkgE-adjust-Mic.png`: all five Adjust tabs

Picture fixtures are cropped from the approved 9 November mockups 01 and 06. Their baked-in zebra stripes are reference artwork, not evidence of live exposure processing. Meter data is deliberately absent and says No signal. Camera identity and format require a live attached camera; these captures do not claim live-device verification.

Compared visually with mockups 01, 02, 03, 05 and 06. The shell preserves the large labelled transport, named tiles, pillarbox key, right-edge meter, dark panel and selected tab treatment. The smaller 200% stage keeps all labels. Camera, exposure and mic controls reuse the merged package views; FalseColourAdjustView remains owned by its separate builder.
