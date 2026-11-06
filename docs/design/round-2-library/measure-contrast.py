#!/usr/bin/env python3
"""Sample solid glyph interiors and composited backgrounds in the offscreen PNGs.
Not an exhaustive automated accessibility audit. Pillow is only used to inspect pixels.
"""
import collections
import pathlib
import sys
from PIL import Image

root = pathlib.Path(sys.argv[1])
regions = {
    "first-launch-100": (0.40, 0.10, 0.85, 0.35),
    "welcome-callout": (0.05, 0.10, 0.95, 0.23),
    "relink-comparison-100": (0.03, 0.04, 0.90, 0.24),
    "library": (0.005, 0.15, 0.18, 0.40),
    "presenter-inspector": (0.04, 0.02, 0.92, 0.20),
}
def luminance(rgb):
    def linear(x):
        x /= 255
        return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4
    r, g, b = map(linear, rgb)
    return 0.2126*r + 0.7152*g + 0.0722*b

def colour(rgb):
    return "#" + "".join(f"{v:02X}" for v in rgb)

print("| Snapshot region | Foreground | Background | Ratio | AA normal text |")
print("| --- | --- | --- | ---: | --- |")
for name, box in regions.items():
    for mode in ("light", "dark"):
        image = Image.open(root / f"{name}-{mode}.png").convert("RGB")
        w, h = image.size
        counts = collections.Counter(image.crop(tuple(int(v*(w if i%2==0 else h)) for i,v in enumerate(box))).getdata())
        background = counts.most_common(1)[0][0]
        # Repeated solid colours exclude isolated edge pixels; the bounds select text and its backing.
        candidates = [(rgb,n) for rgb,n in counts.items() if n >= 30 and
            (luminance(rgb) < 0.16 if mode == "light" else luminance(rgb) > 0.45)]
        foreground = max(candidates, key=lambda item:item[1])[0]
        a,b = sorted([luminance(foreground),luminance(background)])
        ratio = (b+0.05)/(a+0.05)
        print(f"| {name}-{mode} | {colour(foreground)} | {colour(background)} | {ratio:.2f}:1 | {'Pass' if ratio>=4.5 else 'FAIL'} |")
        assert ratio >= 4.5, name
