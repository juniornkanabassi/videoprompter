import AppKit
import CoreVideo
import XCTest
@testable import JuniorPrompter

@MainActor
final class CameraTests: XCTestCase {
  private func defaults() -> UserDefaults {
    let suite = "JuniorPrompter.camera.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    return UserDefaults(suiteName: suite)!
  }
  private let cameras = [CameraDevice(uid: "uid-built-in", name: "FaceTime HD Camera"),
                         CameraDevice(uid: "uid-obs", name: "OBS Virtual Camera")]

  func testTheRememberedCameraWinsWhileItIsStillConnected() {
    XCTAssertEqual(CameraModel.resolve("uid-obs", in: cameras)?.uid, "uid-obs")
  }
  func testAnUnpluggedCameraFallsBackToTheFirstOneLeft() {
    XCTAssertEqual(CameraModel.resolve("uid-gone", in: cameras)?.uid, "uid-built-in")
    XCTAssertEqual(CameraModel.resolve(nil, in: cameras)?.uid, "uid-built-in")
  }
  func testNoCamerasResolveToNothing() {
    XCTAssertNil(CameraModel.resolve("uid-obs", in: []))
  }

  func testChoicesSurviveTheWindowClosing() {
    let store = defaults()
    let model = CameraModel(defaults: store)
    XCTAssertNil(model.selectedUID)
    XCTAssertFalse(model.mirrored)
    model.selectedUID = "uid-obs"
    model.mirrored = true
    model.guides.thirds = true
    model.alwaysOnTop = true
    let reopened = CameraModel(defaults: store)
    XCTAssertEqual(reopened.selectedUID, "uid-obs")
    XCTAssertTrue(reopened.mirrored)
    XCTAssertTrue(reopened.guides.thirds)
    XCTAssertFalse(reopened.guides.axes)
    XCTAssertTrue(reopened.alwaysOnTop)
  }

  /// The inspector's Mode control writes straight to this, and the presenter reads it on the
  /// next launch: Junior should not have to pick "Prompter + video" twice.
  func testTheModeChoiceSurvivesARelaunch() {
    let store = defaults()
    let model = CameraModel(defaults: store)
    XCTAssertFalse(model.presentsWithVideo)
    model.presentsWithVideo = true
    XCTAssertTrue(CameraModel(defaults: store).presentsWithVideo)
    model.presentsWithVideo = false
    XCTAssertFalse(CameraModel(defaults: store).presentsWithVideo)
  }

  /// One rotation control on the model, shown by both the Camera window's toolbar and the
  /// inspector's Video section: Auto is the nil tag, an angle turns Auto off.
  func testTheRotationControlMapsAutoToNothingAndAnAngleTurnsAutoOff() {
    let model = CameraModel(defaults: defaults())
    let choice = model.rotationChoice
    model.guides.automaticRotation = true
    XCTAssertNil(choice.wrappedValue)
    choice.wrappedValue = .quarter
    XCTAssertEqual(choice.wrappedValue, .quarter)
    XCTAssertFalse(model.guides.automaticRotation)
    XCTAssertEqual(model.guides.rotation, .quarter)
    choice.wrappedValue = nil
    XCTAssertTrue(model.guides.automaticRotation)
    XCTAssertNil(choice.wrappedValue)
  }

  /// The inspector's camera picker is the Camera window's list: same devices, same remembered
  /// choice, and the tags it offers are exactly the unique IDs.
  func testTheCameraPickerListsTheSameDevicesAndRemembersTheChoice() {
    let store = defaults()
    let model = CameraModel(defaults: store)
    XCTAssertEqual(cameras.map(\.id), cameras.map(\.uid))
    model.selectedUID = CameraModel.resolve(nil, in: cameras)?.uid
    XCTAssertEqual(model.selectedUID, "uid-built-in")
    XCTAssertEqual(CameraModel(defaults: store).selectedUID, "uid-built-in")
  }

  /// Two windows can show the camera at once. One of them being covered used to detach the
  /// orientation detector and take Auto away from the other.
  func testAutoOrientationSurvivesOneOfTwoViewersGoingAway() {
    let session = SharedCameraSession.shared
    let windowView = NSView()
    let presenterView = NSView()
    defer {
      session.setAutoOrientation(false, for: windowView) { _ in }
      session.setAutoOrientation(false, for: presenterView) { _ in }
    }
    session.setAutoOrientation(false, for: windowView) { _ in }
    session.setAutoOrientation(false, for: presenterView) { _ in }
    XCTAssertFalse(session.isAutoOrienting)
    session.setAutoOrientation(true, for: windowView) { _ in }
    session.setAutoOrientation(true, for: presenterView) { _ in }
    XCTAssertTrue(session.isAutoOrienting)
    session.setAutoOrientation(false, for: presenterView) { _ in }
    XCTAssertTrue(session.isAutoOrienting)
    session.setAutoOrientation(false, for: windowView) { _ in }
    XCTAssertFalse(session.isAutoOrienting)
  }

  private func segments(_ path: CGPath) -> [(CGPoint, CGPoint)] {
    var points: [CGPoint] = []
    path.applyWithBlock { points.append($0.pointee.points[0]) }
    return stride(from: 0, to: points.count, by: 2).map { (points[$0], points[$0 + 1]) }
  }

  func testOverlayDrawsNothingWithBothGuidesOff() {
    XCTAssertTrue(CameraOverlay.thirdsAndAxes(in: CGRect(x: 0, y: 0, width: 300, height: 300), thirds: false, axes: false).isEmpty)
  }

  func testThirdsAndAxesLandOnTheVideoRectangleNotTheView() {
    // A 16:9 video letterboxed inside a taller view: the guides follow the video rect.
    let video = CGRect(x: 0, y: 30, width: 300, height: 150)
    let thirds = segments(CameraOverlay.thirdsAndAxes(in: video, thirds: true, axes: false))
    XCTAssertEqual(thirds.count, 4)
    XCTAssertEqual(thirds.map { $0.0.x }, [100, 0, 200, 0])
    XCTAssertEqual(thirds.map { $0.0.y }, [30, 80, 30, 130])
    XCTAssertEqual(thirds[0].1, CGPoint(x: 100, y: 180))
    XCTAssertEqual(thirds[1].1, CGPoint(x: 300, y: 80))

    let axes = segments(CameraOverlay.thirdsAndAxes(in: video, thirds: false, axes: true))
    XCTAssertEqual(axes.count, 2)
    XCTAssertEqual(axes[0].0, CGPoint(x: 150, y: 30))
    XCTAssertEqual(axes[0].1, CGPoint(x: 150, y: 180))
    XCTAssertEqual(axes[1].0, CGPoint(x: 0, y: 105))
    XCTAssertEqual(axes[1].1, CGPoint(x: 300, y: 105))

    XCTAssertEqual(segments(CameraOverlay.thirdsAndAxes(in: video, thirds: true, axes: true)).count, 6)
  }

  // The real Blackmagic Cam B table, cut down: a DeckLink offers the same picture in five codings.
  private func fmt(_ w: Int32, _ h: Int32, _ sub: OSType) -> SharedCameraSession.VideoFormat {
    SharedCameraSession.VideoFormat(width: w, height: h, subType: FourCharCode(sub))
  }
  private var deckLink: [SharedCameraSession.VideoFormat] {
    [fmt(720, 486, kCVPixelFormatType_422YpCbCr10),
     fmt(1920, 1080, kCVPixelFormatType_32BGRA),
     fmt(1920, 1080, kCVPixelFormatType_422YpCbCr8),
     fmt(1920, 1080, kCVPixelFormatType_422YpCbCr10),
     fmt(3840, 2160, kCVPixelFormatType_32BGRA),
     fmt(3840, 2160, kCVPixelFormatType_422YpCbCr8),
     fmt(3840, 2160, kCVPixelFormatType_422YpCbCr10)]
  }

  func testTheDeckLinkKeepsItsDetectedSizeAndDropsToTheCheaperCoding() {
    // Cam B auto-detects 4K and lands on 10-bit v210; 8-bit 2vuy is the same picture, half the bandwidth.
    let picked = SharedCameraSession.preferredFormat(in: deckLink, active: fmt(3840, 2160, kCVPixelFormatType_422YpCbCr10))
    XCTAssertEqual(picked, 5)
    XCTAssertEqual(deckLink[5], fmt(3840, 2160, kCVPixelFormatType_422YpCbCr8))
    XCTAssertEqual(SharedCameraSession.preferredFormat(in: deckLink, active: fmt(1920, 1080, kCVPixelFormatType_32BGRA)), 2)
  }

  /// 0.7.1 SIGTRAPped on every launch because this choice, and the format mapping that feeds it,
  /// were main-actor-isolated while the session ran them on its own serial queue: the Swift
  /// executor check called `dispatch_assert_queue_fail`. Run it exactly where the session does.
  func testTheFormatChoiceRunsOffTheMainActorLikeTheCaptureQueueDoes() {
    let formats = deckLink
    let active = fmt(3840, 2160, kCVPixelFormatType_422YpCbCr10)
    let chosen = expectation(description: "the cheaper coding is chosen off the main actor")
    nonisolated(unsafe) var picked: Int?
    DispatchQueue(label: "JuniorPrompter.test.camera.session").async {
      dispatchPrecondition(condition: .notOnQueue(.main))
      picked = SharedCameraSession.preferredFormat(in: formats, active: active)
      chosen.fulfill()
    }
    wait(for: [chosen], timeout: 5)
    XCTAssertEqual(picked, 5)
  }

  func testAnAlreadyCheapFormatIsLeftAlone() {
    XCTAssertNil(SharedCameraSession.preferredFormat(in: deckLink, active: fmt(3840, 2160, kCVPixelFormatType_422YpCbCr8)))
    // A built-in camera's 4:2:0 is cheaper than anything on offer at that size.
    XCTAssertNil(SharedCameraSession.preferredFormat(
      in: [fmt(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)],
      active: fmt(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
    // Nothing at that size: never resize away from the card's own signal detection.
    XCTAssertNil(SharedCameraSession.preferredFormat(in: deckLink, active: fmt(4096, 2160, kCVPixelFormatType_422YpCbCr10)))
    XCTAssertNil(SharedCameraSession.preferredFormat(in: [], active: fmt(1920, 1080, kCVPixelFormatType_32BGRA)))
  }

  /// A camera that could not be opened (unplugged, or no access yet) must not be remembered,
  /// or the next `select` of the same camera is skipped and the picture stays black.
  func testACameraThatCouldNotBeOpenedIsRetriedNextTime() {
    let session = SharedCameraSession.shared
    session.select("no-such-camera")
    XCTAssertNil(session.attachedUID)
    session.select(nil)
    XCTAssertNil(session.attachedUID)
  }
}
