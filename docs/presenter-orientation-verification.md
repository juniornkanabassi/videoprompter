# Presenter orientation verification

Base revision: `0f37099`.

The reported mismatch is not explained by separate text and camera presenter
transforms in this revision. The iPad already encloses background, script,
reading band, camera aids and Camera Only picture in the same `ZStack`, with one
`PadPresenterLayout.turn` scale. Operator controls remain outside it.

The Mac `PresenterView.readingStage` likewise transforms the complete stage.
`IPadRemoteView` deliberately does not apply the iPad's glass transform, keeping
the operator's replica readable. These production paths were left unchanged.

Camera orientation is separate. The local iPad camera sets rotation and camera
mirror on its capture connection and applies the same transform to exposure aids.
The linked picture and exposure layer use `CameraRotation.displayTransform`.
That transform rotates first, then applies the camera mirror; the enclosing
presenter applies its own Mirror/Flip last. Framing guides live in the displayed
picture's coordinate system and inherit the presenter transform.

`PadStore` already starts a fresh installation with horizontal mirror enabled and
vertical mirror disabled. A decoded `padSettings` value takes precedence. No
migration is appropriate: changing an existing false value would change the
meaning of the user's saved text orientation. Camera mirroring is saved
separately as `cameraMirrored`.

Added regression coverage exercises the native local and linked preview hosts,
the script's `UITextView`, and the exposure layer through every Mirror/Flip
combination, with camera rotation 90 degrees and camera mirroring both off and
on, in script and Camera Only modes. These checks inspect the composed UIKit /
Core Animation coordinates, complementing the existing asymmetric still-image
pixel checks and all-rotation matrix tests. They do not open capture devices.
The settings test covers first launch and all four saved orientation combinations.

No iPad reset is required by this change. An existing installation with Mirror
off retains that choice; choose Mirror for beam-splitter glass. Treat “Mirror
camera” as an independent selfie-preview preference, not as compensation for the
whole presenter's orientation. The installed build and actual camera path must
be checked on hardware if the reported mismatch persists: headless geometry
and synthetic pixels cannot establish how a real AVFoundation feed appears on
a specific iPad and glass assembly.

Validation on 14 November 2026:

- `swift build`: passed.
- Requested generic iOS Simulator `xcodebuild ... build CODE_SIGNING_ALLOWED=NO -quiet`: passed.
- Focused `PadPresenterLayoutTests` and `CameraOrientationTests` through `test.sh`: 19 tests, zero failures; grid check passed.
- `zsh checks/ipad-presenter-shots.sh`: 17 tests passed, zero failures; throwaway simulator cleaned up.
- Native camera/text matrix: 32 rendered cases, zero failures, including both camera sources, Camera Only, every presenter mirror/flip combination, 90-degree rotation and both camera mirror states.
- Visually inspected `ipad-reading-camera`, `ipad-mirrored`, `ipad-flipped` and `ipad-mirrored-flipped` at 1180×820: the asymmetric red/blue picture markers, text, highlight band and meter turn together; the transport stays upright. Also inspected the flipped zebra fixture.

PNG evidence was generated under `/tmp/vp-orientation-before.jzCB6W/` and is not committed.

The hardware-only report remains unconfirmed. Do not describe this test-only
commit as a newly implemented orientation fix or proof of live camera pixels.
