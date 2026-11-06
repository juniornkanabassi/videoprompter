#!/usr/bin/env python3
"""Check solid interior text/background pixels in the offscreen fixtures (not anti-aliased edges)."""
from pathlib import Path
from collections import Counter
import json, sys
from PIL import Image

root = Path(sys.argv[1])
# Region, foreground, background. Disabled controls are intentionally excluded.
samples = [
 ('library-light', 'Script titles', (65,200,380,320), (38,38,38), (250,250,250)),
 ('library-dark', 'Script titles', (65,200,380,320), (220,220,220), (26,26,26)),
 ('library-inspector-light', 'Inspector labels', (2270,20,2870,350), (39,39,39), (255,255,255)),
 ('library-inspector-dark', 'Inspector labels', (2270,20,2870,350), (220,220,220), (28,28,28)),
 ('library-inspector-light', 'Inspector popup', (2270,0,2870,900), (36,36,36), (235,235,235)),
 ('library-inspector-dark', 'Inspector popup', (2270,0,2870,900), (223,223,223), (46,46,46)),
 ('google-docs-light', 'Import explanation', (60,270,1200,340), (39,39,39), (255,255,255)),
 ('google-docs-dark', 'Import explanation', (60,270,1200,340), (220,220,220), (28,28,28)),
 ('presenter-inspector-light', 'Small size readout', (620,390,700,435), (39,39,39), (255,255,255)),
 ('presenter-inspector-dark', 'Small size readout', (620,390,700,435), (220,220,220), (28,28,28)),
 ('reference-monitor-light', 'Passage', (50,100,1500,300), (255,255,255), (25,25,25)),
 ('reference-monitor-dark', 'Passage', (50,100,1500,300), (255,255,255), (3,3,3)),
 ('presenter-camera-light', 'Enabled camera picker', (1080,1310,1280,1360), (255,255,255), (71,71,71)),
]
def luminance(rgb):
    c = [v/255 for v in rgb]
    c = [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in c]
    return sum(v*w for v,w in zip(c,(.2126,.7152,.0722)))
rows=[]
for name, label, box, fg, bg in samples:
    pixels=Counter(Image.open(root/(name+'.png')).convert('RGB').crop(box).getdata())
    assert pixels[fg] >= 5 and pixels[bg] >= 5, (name,label,'missing expected solid pixels',pixels.most_common(5))
    lights=sorted((luminance(fg),luminance(bg)))
    ratio=(lights[1]+.05)/(lights[0]+.05)
    assert ratio >=4.5, (name,label,ratio)
    rows.append(dict(snapshot=name,label=label,foreground=fg,background=bg,ratio=round(ratio,2)))
print(json.dumps(rows, indent=2))
