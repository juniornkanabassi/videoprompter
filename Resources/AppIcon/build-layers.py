#!/usr/bin/env python3
"""Editable geometric sources for the native Icon Composer document; no app launch."""
import json
from pathlib import Path
root = Path(__file__).resolve().parent / 'VideoPrompter.icon'
assets = root / 'Assets'
palettes = {
    'Default': dict(background='#F5F5F3', page='#E6E7E7', pageEdge='#C3C6C8', ink='#454B50', marker='#F47866', micLight='#494F55', micDark='#20252B', rim='#717A82'),
    'Dark': dict(background='#1B1E23', page='#505A65', pageEdge='#B8C2CE', ink='#CFD4DA', marker='#F58D7D', micLight='#69747F', micDark='#303943', rim='#B6C0CB'),
    'Tinted': dict(background='#E6E6E6', page='#FFFFFF', pageEdge='#333333', ink='#666666', marker='#4B4B4B', micLight='#555555', micDark='#202020', rim='#929292'),
}
names = ['Background', 'Script page', 'Script lines', 'Reading marker', 'Camera lens', 'Lens glass']
groups = []
for name in names:
    layers = []
    for appearance, c in palettes.items():
        svg = {
            'Background': f'<path fill="{c["background"]}" d="M0 0H1024V1024H0Z"/>',
            'Script page': f'<rect x="184" y="148" width="564" height="688" rx="54" fill="{c["page"]}" stroke="{c["pageEdge"]}" stroke-width="12"/>',
            'Script lines': f'<g fill="{c["ink"]}"><rect x="260" y="256" width="404" height="48" rx="24"/><rect x="260" y="480" width="280" height="48" rx="24"/></g>',
            'Reading marker': f'<rect x="244" y="360" width="424" height="72" rx="36" fill="{c["marker"]}"/>',
            'Camera lens': f'<circle cx="678" cy="684" r="170" fill="{c["micDark"]}" stroke="{c["rim"]}" stroke-width="16"/><circle cx="678" cy="684" r="132" fill="{c["micLight"]}"/>',
            'Lens glass': f'<circle cx="678" cy="684" r="100" fill="{c["micDark"]}" stroke="{c["rim"]}" stroke-width="10"/><circle cx="678" cy="684" r="56" fill="{c["ink"]}"/><circle cx="651" cy="655" r="20" fill="{c["page"]}"/>',

        }[name]
        filename = f'{name.replace(" ", "-")}-{appearance}.svg'
        (assets / filename).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{svg}</svg>\n')
        layers.append(dict(name=f"{name} {appearance}", **{'image-name': filename}, glass=name == 'Script page', hidden=False,
            **{'opacity-specializations': [dict(value=int(appearance=='Default')), dict(appearance='dark', value=int(appearance=='Dark')), dict(appearance='tinted', value=int(appearance=='Tinted'))]}))
    groups.append(dict(name=name, layers=layers, shadow=dict(kind='neutral', opacity=0.15 if name=='Script page' else 0), translucency=dict(enabled=False,value=0), specular=name=='Script page'))
(root/'icon.json').write_text(json.dumps(dict(fill=dict(solid='srgb:0,0,0,0'),groups=[dict(groups[4], layers=groups[5]['layers'] + groups[4]['layers']), dict(groups[1], layers=groups[3]['layers'] + groups[2]['layers'] + groups[1]['layers']), groups[0]],**{'supported-platforms':{'squares':['macOS']}}),indent=2)+'\n')
