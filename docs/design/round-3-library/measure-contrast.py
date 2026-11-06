#!/usr/bin/env python3
"""Sample repeated glyph-interior pixels in reviewed offscreen text regions.
WCAG 2.2 AA yardstick; not a native-app conformance certificate.
"""
from collections import Counter
from pathlib import Path
import sys
from PIL import Image

root = Path(sys.argv[1])
regions = {
    'first-launch-100': (.40,.08,.90,.38),
    'library-100-scripts-200': (.02,.12,.34,.20),
    'presenter-inspector': (.05,.02,.90,.18),
    'library-inspector': (.79,.05,.98,.25),
    'settings-Editor': (.03,.10,.98,.85),
    'relink-comparison-200': (.05,.03,.92,.18),
    'camera-picker-200': (.10,.06,.85,.24),
    'camera-picker-many-200': (.06,.49,.82,.55),
    'presenter-editor': (.73,.79,.94,.85),
}
def lum(rgb):
    c = [v/255 for v in rgb]
    c = [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in c]
    return sum(v*w for v,w in zip(c,(.2126,.7152,.0722)))
def hx(c): return '#' + ''.join(f'{v:02X}' for v in c)
print('| Snapshot text region | Foreground | Background | Contrast | AA normal text |')
print('| --- | --- | --- | ---: | --- |')
for name, box in regions.items():
    for mode in ('light','dark'):
        image = Image.open(root/f'{name}-{mode}.png').convert('RGB')
        w,h=image.size
        counts=Counter(image.crop(tuple(int(v*(w if i%2==0 else h)) for i,v in enumerate(box))).getdata())
        bg=counts.most_common(1)[0][0]
        on_dark=lum(bg)<.3
        candidates=[(c,n) for c,n in counts.items() if n>=12 and max(c)-min(c)<20 and (lum(c)>.45 if on_dark else lum(c)<.12)]
        if not candidates: raise RuntimeError(f'No stable text pixels: {name}-{mode}')
        fg=max(candidates,key=lambda item:item[1])[0]
        a,b=sorted((lum(fg),lum(bg)));ratio=(b+.05)/(a+.05)
        print(f'| {name}-{mode} | {hx(fg)} | {hx(bg)} | {ratio:.2f}:1 | {"Pass" if ratio>=4.5 else "FAIL"} |')
        assert ratio>=4.5,(name,mode,ratio)
