# Video Prompter icon

Renamed from VidPrompt to Video Prompter on 8 October 2026; the same white microphone master is now `VideoPrompter.png`/`VideoPrompter.icns`. Earlier, on 1 October 2026, it was renamed from JuniorPrompter to VidPrompt and the amber Alpha variant was retired with the Alpha channel.

Approved by Junior on 5 September 2026. Use the current white microphone-and-script master and ICNS going forward.

## Current generation prompt

Edit image 1, the VidPrompt icon. Use image 2 only as inspiration for clean Apple Mac icon dimensional craftsmanship and strong simple foreground/background hierarchy; do not copy its stars, sidebar symbols or purple colour. Keep image 1's recognisable large angled broadcast microphone silhouette as the main symbol and a script page behind it. Change the blue background to a white softly rounded macOS app tile. Simplify the microphone to smooth charcoal sculpted shapes with a broad foam capsule, one clean supporting yoke, minimal tiny hardware, no photographic grain, no cables, no logos. The page behind it is pale cool grey with three broad dark grey script lines, a very restrained warm coral reading marker. Reduce glossy glass and neon highlights; gentle depth, soft natural shadow and satin materials. Bold recognisable silhouette at 32 pixels, generous spacing, uncluttered. The microphone must clearly be the dominant object; script page legible behind. Original Apple-esque icon, not flat generic microphone glyph. Single centred finished square app icon, transparent outside rounded white tile, no typography, no surrounding mockup or comparison.

Revised 5 September 2026 using the built-in image generation tool. Master is now `VideoPrompter.png`, packaged into `VideoPrompter.icns`. Junior requested the first microphone-led composition on a white tile with simplified shapes and a script page. Sidebar Favorites Manager supplied visual hierarchy inspiration only. The previous blue-page design is superseded.

## Previous generation prompt (superseded)

Use case: logo-brand. Create ONE finished minimalist macOS app icon for VidPrompt, a script teleprompter. Apple-esque simplicity and excellent tiny-size legibility. Square 1024x1024. Warm off-white porcelain rounded-square tile with standard macOS icon proportions and generous clear padding. Centre one simple flat royal-blue document/page glyph, with three generous white horizontal script bars in its upper portion and a tiny white microphone glyph elegantly integrated into the lower portion of the same page. The microphone is just a rounded vertical capsule and one U-shaped support/stem, a clean symbolic pictogram, not a realistic product. Make one script line a subtly darker blue reading indicator only if it remains simple. Bold clean geometry, spacious proportions, carefully optically aligned, almost flat vector style with only the faintest natural tile-edge depth. The composition should feel as simple and purposeful as an Apple utility app, with no more than two main colours plus the ivory background. No realistic microphone, no photorealism, no reflective glass, no neon glow, no glossy chrome, no 3D extrusions, no busy stacked panels, no lens flares, no gradients inside the glyph, no lettering, no text labels, no app name, no Apple logo, no branding, no watermark, no surrounding mockup. Transparent exterior outside the rounded tile. This replaces a rejected over-detailed glossy microphone design with something restrained, minimal, approachable and distinctly about reading a script aloud.


## Testing variant approved 12 September 2026

Junior approved an amber tile retaining the dark microphone and white script as a testing variant. It was retired with the Alpha channel on 1 October 2026; builds use the white icon. Generated preview exterior checkerboard was replaced with real alpha before packaging.

## 6 November 2026 alpha repair

The approved artwork is retained. Two image-tool cutout attempts left exterior speckles, so the packaged master uses a deterministic border-connected exterior mask. Only near-black pixels connected to the image boundary are made transparent; the microphone's enclosed dark pixels remain intact. Every legacy ICNS representation is regenerated with high-quality downsampling and transparent corners. This is an alpha/export repair, not new icon artwork.

## 6 November 2026 appearance variants

`VideoPrompter.icon` is now the shipping Icon Composer source. Its default layer contains the unchanged approved white master. Separate Dark and Tinted layers were generated from that master using the built-in image tool, preserving the microphone/page composition. The tinted layer has no coral; Icon Composer applies the chosen system tint. The exterior is masked by the native icon renderer. The original master, iconset and ICNS remain available for provenance.

`compile-icon.sh <destination>` compiles the three appearances with Apple's `actool` into `Assets.car` and `VideoPrompter.icns`. `build.sh` invokes this resource-only step; `Info.plist` names VideoPrompter. No release was built or installed during this change. Offscreen `ictool` exports at 16, 32 and 64 points are in `docs/design/round-2-library/icons/`.

Generated source images: built-in image tool outputs `exec-65b91f39-a087-4a86-af41-75334e096961.png` (dark) and `exec-04b8ffa8-a953-4862-a112-9b6944401634.png` (tinted). Canonical copies live inside the Icon Composer Assets directory. These are bitmap appearance layers, not separate editable microphone/page geometry.

## Round 3 finishing, 6 November 2026

The approved large white master remains unchanged. A simplified optical variant
(`VideoPrompter-Small.png`) strengthens the paper outline and suppresses tiny
hardware reflections for the legacy 16/32/64-pixel representations. The variant
was generated from the approved master, then exported through Icon Composer's
native rounded mask. Raw generated outputs with exterior flecks were rejected.
The legacy ICNS is retained by `compile-icon.sh` after compiling Assets.car.

`VideoPrompter-Dark-R3.png` changes the tile while retaining lighting closer to
the approved microphone. The tinted layer now reuses the exact approved default
bitmap, so the system supplies tint without different geometry or exterior
speckles. Older generated appearance sources are retained for provenance.

Native Icon Composer exports at 16/32/64 points and a comparison are in
`docs/design/round-3-library/icons`. The modern catalogue still derives all sizes
from one bitmap per appearance. Per-size optical artwork is applied to the
legacy ICNS only; a layered vector master remains future work.
