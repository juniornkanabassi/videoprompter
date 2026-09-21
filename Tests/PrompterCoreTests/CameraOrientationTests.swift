import AppKit
import XCTest

@testable import JuniorPrompter

/// Camera orientation: the rotation's own geometry, the automatic chooser, the per-camera
/// memory and the shared session's holder count. Nothing here opens a camera.
@MainActor
final class CameraOrientationTests: XCTestCase {
  private func defaults() -> UserDefaults {
    let suite = "JuniorPrompter.orientation.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    return UserDefaults(suiteName: suite)!
  }
  private func segments(_ path: CGPath) -> [(CGPoint, CGPoint)] {
    var points: [CGPoint] = []
    path.applyWithBlock { points.append($0.pointee.points[0]) }
    return stride(from: 0, to: points.count, by: 2).map { (points[$0], points[$0 + 1]) }
  }

  // Cam B's 3840x2160 in a square window: upright it letterboxes, turned it pillarboxes as 9:16.
  private let feed = CGSize(width: 3840, height: 2160)
  private let window = CGRect(x: 0, y: 0, width: 360, height: 360)

  func testATurnedFeedIsFittedAsNineBySixteenWithoutCropping() {
    XCTAssertEqual(CameraRotation.none.fittedRect(aspect: feed, in: window),
                   CGRect(x: 0, y: 78.75, width: 360, height: 202.5))
    XCTAssertEqual(CameraRotation.half.fittedRect(aspect: feed, in: window),
                   CGRect(x: 0, y: 78.75, width: 360, height: 202.5))
    // 90° and 270° swap the axes: the same picture, now taller than it is wide, still whole.
    for rotation in [CameraRotation.quarter, .threeQuarters] {
      XCTAssertEqual(rotation.fittedRect(aspect: feed, in: window),
                     CGRect(x: 78.75, y: 0, width: 202.5, height: 360), "\(rotation.label)")
      XCTAssertTrue(rotation.swapsAxes)
    }
    XCTAssertFalse(CameraRotation.none.swapsAxes)
    XCTAssertFalse(CameraRotation.half.swapsAxes)
    // Degenerate inputs leave the bounds alone rather than producing an empty rectangle.
    XCTAssertEqual(CameraRotation.quarter.fittedRect(aspect: .zero, in: window), window)
  }

  func testTheGuidesTurnWithThePicture() {
    // The guides are drawn on the rotated video rectangle, so a vertical feed gets vertical thirds.
    let upright = CameraRotation.none.fittedRect(aspect: feed, in: window)
    let turned = CameraRotation.quarter.fittedRect(aspect: feed, in: window)
    let uprightThirds = segments(CameraOverlay.thirdsAndAxes(in: upright, thirds: true, axes: false))
    let turnedThirds = segments(CameraOverlay.thirdsAndAxes(in: turned, thirds: true, axes: false))
    XCTAssertEqual(uprightThirds.count, 4)
    XCTAssertEqual(turnedThirds.count, 4)
    // First vertical third: a third across the wide picture, a third across the narrow one.
    XCTAssertEqual(uprightThirds[0].0.x, 120, accuracy: 0.001)
    XCTAssertEqual(turnedThirds[0].0.x, 78.75 + 67.5, accuracy: 0.001)
    // First horizontal third spans the full width of its own rectangle, not the window's.
    XCTAssertEqual(uprightThirds[1].0, CGPoint(x: 0, y: 78.75 + 67.5))
    XCTAssertEqual(uprightThirds[1].1, CGPoint(x: 360, y: 78.75 + 67.5))
    XCTAssertEqual(turnedThirds[1].0, CGPoint(x: 78.75, y: 120))
    XCTAssertEqual(turnedThirds[1].1, CGPoint(x: 78.75 + 202.5, y: 120))
    // The centre cross stays on the picture's own centre, which is the window's here.
    let axes = segments(CameraOverlay.thirdsAndAxes(in: turned, thirds: false, axes: true))
    XCTAssertEqual(axes[0].0, CGPoint(x: 180, y: 0))
    XCTAssertEqual(axes[1].0, CGPoint(x: 78.75, y: 180))
  }

  // A face detected by Vision at each of the four orientations. Only one of them is upright:
  // the wrong ones find a smaller, less certain face or nothing at all.
  private func face(_ confidence: Float, _ side: CGFloat) -> [CameraAutoOrientation.Face] {
    [CameraAutoOrientation.Face(
      confidence: confidence, boundingBox: CGRect(x: 0.3, y: 0.3, width: side, height: side))]
  }
  private func candidates(_ faces: [CameraRotation: [CameraAutoOrientation.Face]])
    -> [CameraAutoOrientation.Candidate]
  {
    CameraRotation.allCases.compactMap {
      CameraAutoOrientation.candidate($0, faces: faces[$0] ?? [])
    }
  }

  func testTheUprightFacePicksTheAngle() {
    // Junior shoots vertical into a landscape feed: the picture wants turning a quarter turn.
    let turned = candidates([
      .none: face(0.52, 0.10), .quarter: face(0.97, 0.30), .half: [], .threeQuarters: face(0.61, 0.08),
    ])
    XCTAssertEqual(CameraAutoOrientation.bestRotation(among: turned), .quarter)
    // An already-upright camera is left where it is.
    XCTAssertEqual(
      CameraAutoOrientation.bestRotation(among: candidates([.none: face(0.95, 0.28), .half: face(0.55, 0.26)])),
      CameraRotation.none)
    XCTAssertEqual(
      CameraAutoOrientation.bestRotation(among: candidates([.threeQuarters: face(0.9, 0.3)])),
      .threeQuarters)
    XCTAssertEqual(
      CameraAutoOrientation.bestRotation(among: candidates([.half: face(0.9, 0.3)])), .half)
  }

  func testNothingConvincingLeavesTheRotationAlone() {
    XCTAssertNil(CameraAutoOrientation.bestRotation(among: []))
    // Below the confidence floor, and a zero-area rectangle, are both ignored.
    XCTAssertNil(CameraAutoOrientation.bestRotation(among: candidates([.quarter: face(0.2, 0.3)])))
    XCTAssertNil(CameraAutoOrientation.bestRotation(among: candidates([.quarter: face(0.9, 0)])))
    // The largest face at an orientation is the one that speaks for it.
    let crowd = [CameraAutoOrientation.Face(confidence: 0.9, boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),
                 CameraAutoOrientation.Face(confidence: 0.6, boundingBox: CGRect(x: 0, y: 0, width: 0.4, height: 0.4))]
    XCTAssertEqual(CameraAutoOrientation.candidate(.half, faces: crowd)?.confidence, 0.6)
  }

  func testEachOrientationAsksVisionForADifferentUpright() {
    XCTAssertEqual(
      CameraRotation.allCases.map(\.visionOrientation), [.up, .right, .down, .left])
  }

  func testGuidesAreRememberedForEachCamera() {
    let store = CameraGuideStore(defaults: defaults())
    XCTAssertEqual(store.guides(for: "uid-decklink"), CameraGuides())
    var deckLink = CameraGuides()
    deckLink.rotation = .quarter
    deckLink.inputAspect = .openGate3x2
    deckLink.thirds = true
    deckLink.bullseye = true
    deckLink.colorHex = "#FF0000"
    deckLink.opacity = 0.4
    deckLink.marker = CameraAspect(width: 9, height: 16)
    deckLink.shadeOpacity = 0.7
    store.set(deckLink, for: "uid-decklink")
    var builtIn = CameraGuides()
    builtIn.rotation = .half
    store.set(builtIn, for: "uid-built-in")
    XCTAssertEqual(store.guides(for: "uid-decklink"), deckLink)
    XCTAssertEqual(store.guides(for: "uid-built-in"), builtIn)
    // An unknown camera, and no camera at all, get the blue defaults and no marker.
    let fresh = store.guides(for: "uid-obs")
    XCTAssertEqual(fresh, CameraGuides())
    XCTAssertEqual(fresh.rotation, CameraRotation.none)
    XCTAssertEqual(fresh.colorHex, "#3F8CFF")
    XCTAssertEqual(fresh.opacity, 0.85)
    XCTAssertEqual(fresh.shadeOpacity, 0.5)
    XCTAssertNil(fresh.marker)
    XCTAssertEqual(fresh.inputAspect, .asDelivered)
    XCTAssertEqual(store.guides(for: nil), CameraGuides())
  }

  /// Guides saved before the input aspect existed keep the picture exactly as it was.
  func testGuidesSavedByAnOlderBuildStayAsDelivered() throws {
    let old = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"rotation":90,"thirds":true}"#.utf8))
    XCTAssertEqual(old.inputAspect, .asDelivered)
    XCTAssertEqual(old.rotation, .quarter)
    let unknown = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"inputAspect":"anamorphic"}"#.utf8))
    XCTAssertEqual(unknown.inputAspect, .asDelivered)
  }

  func testTheFrameMarkerIsInscribedInTheTurnedPicture() {
    // Open gate: the delivered 9:16 frame is drawn inside whatever the card hands over.
    let ninebysixteen = CameraAspect(width: 9, height: 16)
    let upright = CameraRotation.none.fittedRect(aspect: feed, in: window)
    XCTAssertEqual(upright, CGRect(x: 0, y: 78.75, width: 360, height: 202.5))
    // Inside a 16:9 picture the 9:16 marker is a tall strip down the middle, height-limited.
    XCTAssertEqual(
      ninebysixteen.fitted(in: upright),
      CGRect(x: 180 - 113.90625 / 2, y: 78.75, width: 113.90625, height: 202.5))
    // Turned a quarter, the picture is 9:16 itself, so the marker is the whole of it.
    let turned = CameraRotation.quarter.fittedRect(aspect: feed, in: window)
    XCTAssertEqual(turned, CGRect(x: 78.75, y: 0, width: 202.5, height: 360))
    XCTAssertEqual(ninebysixteen.fitted(in: turned), turned)
    // A wider delivery frame inside that vertical picture is width-limited instead.
    XCTAssertEqual(
      CameraAspect(width: 4, height: 5).fitted(in: turned),
      CGRect(x: 78.75, y: 180 - 253.125 / 2, width: 202.5, height: 253.125))
    XCTAssertEqual(CameraAspect(width: 1, height: 1).fitted(in: turned),
                   CGRect(x: 78.75, y: 78.75, width: 202.5, height: 202.5))
    // A nonsense custom aspect leaves the picture alone rather than collapsing the marker.
    XCTAssertEqual(CameraAspect(width: 0, height: 4).fitted(in: turned), turned)
    XCTAssertEqual(CameraAspect(width: 21, height: 9).label, "21:9")
  }

  func testGuidesFollowTheMarkerFrameRatherThanTheWholePicture() {
    let picture = CGRect(x: 0, y: 0, width: 400, height: 200)
    var guides = CameraGuides()
    guides.thirds = true
    XCTAssertEqual(CameraOverlay.guideRect(picture: picture, guides: guides), picture)
    guides.marker = CameraAspect(width: 1, height: 1)
    let marker = CGRect(x: 100, y: 0, width: 200, height: 200)
    XCTAssertEqual(CameraOverlay.guideRect(picture: picture, guides: guides), marker)
    // The marker's own outline, then the thirds measured across it: 4 + 4 segments.
    let drawn = segments(CameraOverlay.guidePath(picture: picture, guides: guides))
    XCTAssertEqual(drawn.count, 8)
    XCTAssertEqual(drawn[0].0, CGPoint(x: 100, y: 0))
    XCTAssertEqual(drawn[0].1, CGPoint(x: 300, y: 0))
    XCTAssertEqual(drawn[3].0, CGPoint(x: 100, y: 200))
    XCTAssertEqual(drawn[3].1, CGPoint(x: 100, y: 0))
    XCTAssertEqual(drawn[4].0, CGPoint(x: 100 + 200.0 / 3, y: 0))
    XCTAssertEqual(drawn[4].1, CGPoint(x: 100 + 200.0 / 3, y: 200))
    XCTAssertEqual(drawn[5].0, CGPoint(x: 100, y: 200.0 / 3))
    XCTAssertEqual(drawn[5].1, CGPoint(x: 300, y: 200.0 / 3))
    // Everything outside the marker is shaded; with no marker there is nothing to shade.
    XCTAssertEqual(
      CameraOverlay.shadePath(picture: picture, guides: guides).boundingBox, picture)
    guides.marker = CameraAspect(width: 2, height: 1)
    XCTAssertTrue(CameraOverlay.shadePath(picture: picture, guides: guides).isEmpty,
                  "a marker the size of the picture shades nothing")
    guides.marker = nil
    XCTAssertTrue(CameraOverlay.shadePath(picture: picture, guides: guides).isEmpty)
    XCTAssertEqual(segments(CameraOverlay.guidePath(picture: picture, guides: guides)).count, 4)
  }

  func testTheBullseyeSitsOnTheFrameCentre() {
    let picture = CGRect(x: 0, y: 0, width: 400, height: 200)
    var guides = CameraGuides()
    guides.bullseye = true
    // Radius and crosshair arms are proportional to the shorter side: 200 * 0.045 = 9, and the
    // arms reach 2.2 radii, so the whole bullseye is 39.6 across, centred on the picture.
    let drawn = CameraOverlay.guidePath(picture: picture, guides: guides).boundingBox
    XCTAssertEqual(drawn.midX, 200, accuracy: 0.001)
    XCTAssertEqual(drawn.midY, 100, accuracy: 0.001)
    XCTAssertEqual(drawn.width, 39.6, accuracy: 0.001)
    XCTAssertEqual(drawn.height, 39.6, accuracy: 0.001)
    // With a marker it follows the marker's centre, not the picture's.
    guides.marker = CameraAspect(width: 1, height: 1)
    XCTAssertEqual(
      CameraOverlay.guidePath(picture: picture, guides: guides).boundingBox.midX, 200,
      accuracy: 0.001)
    XCTAssertTrue(CameraOverlay.guidePath(picture: .zero, guides: guides).isEmpty)
  }

  func testTheSharedSessionRunsWhileSomethingIsShowingIt() {
    var holders = CameraHolders()
    XCTAssertTrue(holders.retain(), "the first holder starts the session")
    XCTAssertFalse(holders.retain(), "the presenter joining does not reopen the device")
    XCTAssertEqual(holders.count, 2)
    XCTAssertFalse(holders.release(), "one window left showing it keeps the session running")
    XCTAssertTrue(holders.release(), "the last one leaving stops it")
    XCTAssertEqual(holders.count, 0)
    XCTAssertFalse(holders.release(), "an extra release never drives the count negative")
    XCTAssertEqual(holders.count, 0)
    XCTAssertTrue(holders.retain(), "and it starts again on the next window")
  }
}
