#!/usr/bin/env python3
"""Editable geometric sources for the native Icon Composer document; no app launch."""
import json
from pathlib import Path
root = Path(__file__).resolve().parent / 'VideoPrompter.icon'
assets = root / 'Assets'
palettes = {
    'Default': dict(background='#F5F5F3', page='#E6E7E7', pageEdge='#C3C6C8', ink='#454B50', marker='#F47866', micLight='#494F55', micDark='#20252B', rim='#717A82'),
    'Dark': dict(background='#1B1E23', page='#40464D', pageEdge='#616A73', ink='#CFD4DA', marker='#F58D7D', micLight='#69747F', micDark='#303943', rim='#B6C0CB'),
    'Tinted': dict(background='#E6E6E6', page='#FFFFFF', pageEdge='#AAAAAA', ink='#666666', marker='#4B4B4B', micLight='#555555', micDark='#202020', rim='#929292'),
}
names = ['Background', 'Script page', 'Script lines', 'Reading marker', 'Microphone', 'Microphone support']
groups = []
for name in names:
    layers = []
    for appearance, c in palettes.items():
        svg = {
            'Background': f'<path fill="{c["background"]}" d="M0 0H1024V1024H0Z"/>',
            'Script page': f'<rect x="156" y="174" width="460" height="574" rx="54" fill="{c["page"]}" stroke="{c["pageEdge"]}" stroke-width="5"/>',
            'Script lines': f'<g fill="{c["ink"]}"><rect x="220" y="258" width="314" height="38" rx="19"/><rect x="220" y="474" width="192" height="38" rx="19"/></g>',
            'Reading marker': f'<rect x="211" y="360" width="332" height="54" rx="27" fill="{c["marker"]}"/>',
            'Microphone': f'''<defs><linearGradient id="body" x1="0" x2="1"><stop stop-color="{c['micLight']}"/><stop offset=".55" stop-color="{c['micDark']}"/><stop offset="1" stop-color="{c['micLight']}"/></linearGradient></defs>
<g transform="rotate(36 612 565)"><rect x="498" y="198" width="228" height="518" rx="114" fill="url(#body)"/><path d="M503 546H721V602H503Z" fill="{c['micDark']}"/><path d="M506 548H718" fill="none" stroke="{c['rim']}" stroke-width="5"/></g>''',
            'Microphone support': f'''<g transform="rotate(36 612 565)" fill="none" stroke="{c['rim']}" stroke-width="32" stroke-linecap="round"><path d="M471 555V670C471 858 753 858 753 670V555"/></g><path d="M468 764V900" fill="none" stroke="{c['rim']}" stroke-width="32"/><path d="M386 900H558" fill="none" stroke="{c['micLight']}" stroke-width="36" stroke-linecap="round"/>''',
        }[name]
        filename = f'{name.replace(" ", "-")}-{appearance}.svg'
        (assets / filename).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{svg}</svg>\n')
        layers.append(dict(name=f"{name} {appearance}", **{'image-name': filename}, glass=name == 'Script page', hidden=False,
            **{'opacity-specializations': [dict(value=int(appearance=='Default')), dict(appearance='dark', value=int(appearance=='Dark')), dict(appearance='tinted', value=int(appearance=='Tinted'))]}))
    groups.append(dict(name=name, layers=layers, shadow=dict(kind='neutral', opacity=0.15 if name=='Script page' else 0), translucency=dict(enabled=False,value=0), specular=name=='Script page'))
(root/'icon.json').write_text(json.dumps(dict(fill=dict(solid='srgb:0,0,0,0'),groups=[dict(groups[4], layers=groups[5]['layers'] + groups[4]['layers']), dict(groups[1], layers=groups[3]['layers'] + groups[2]['layers'] + groups[1]['layers']), groups[0]],**{'supported-platforms':{'squares':['macOS']}}),indent=2)+'\n')
