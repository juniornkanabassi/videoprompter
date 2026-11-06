#!/usr/bin/env python3
"""Measure solid interior glyphs against their adjacent flat snapshot background."""
import json
from collections import Counter
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parent
# Raw bitmap pixels. Each crop isolates the status/recovery line and avoids titles/buttons.
samples = [
    ('library-light', (700, 80, 1200, 115)),
    ('library-dark', (700, 80, 1200, 115)),
    ('camera-light', (80, 250, 720, 285)),
    ('camera-dark', (80, 250, 720, 285)),
    ('camera-recovery-0-light', (20, 110, 490, 160)),
    ('camera-recovery-0-dark', (20, 110, 490, 160)),
    ('camera-recovery-2-light', (20, 110, 490, 160)),
    ('camera-recovery-2-dark', (20, 110, 490, 160)),
]
def luminance(rgb):
    def channel(c):
        c /= 255
        return c/12.92 if c <= .04045 else ((c+.055)/1.055)**2.4
    return sum(w*channel(c) for c,w in zip(rgb,(.2126,.7152,.0722)))
results=[]
for name, crop in samples:
    image = Image.open(root/'snapshots'/f'{name}.png').convert('RGB')
    colours = Counter(image.crop(crop).getdata()).most_common()
    background = colours[0][0]
    # Solid glyph interiors are the most frequent colour away from the background;
    # antialias pixels near that background are excluded before choosing the dominant ink.
    ink = next(rgb for rgb, count in colours[1:] if max(abs(a-b) for a,b in zip(rgb,background)) > 80)
    a,b = sorted((luminance(ink),luminance(background)))
    ratio = (b+.05)/(a+.05)
    results.append(dict(snapshot=name+'.png',crop=crop,ink='#%02X%02X%02X'%ink,
        background='#%02X%02X%02X'%background,ratio=round(ratio,2),passes_AA=ratio>=4.5))
assert all(s['passes_AA'] for s in results), results
(root/'contrast.json').write_text(json.dumps(results,indent=2)+'\n')
for sample in results: print(f"{sample['snapshot']}: {sample['ink']} on {sample['background']} = {sample['ratio']}:1 PASS")
