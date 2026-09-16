import AppKit
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
    model.showsThirds = true
    model.alwaysOnTop = true
    let reopened = CameraModel(defaults: store)
    XCTAssertEqual(reopened.selectedUID, "uid-obs")
    XCTAssertTrue(reopened.mirrored)
    XCTAssertTrue(reopened.showsThirds)
    XCTAssertFalse(reopened.showsAxes)
    XCTAssertTrue(reopened.alwaysOnTop)
  }

  private func segments(_ path: CGPath) -> [(CGPoint, CGPoint)] {
    var points: [CGPoint] = []
    path.applyWithBlock { points.append($0.pointee.points[0]) }
    return stride(from: 0, to: points.count, by: 2).map { (points[$0], points[$0 + 1]) }
  }

  func testOverlayDrawsNothingWithBothGuidesOff() {
    XCTAssertTrue(CameraPreviewView.overlayPath(in: CGRect(x: 0, y: 0, width: 300, height: 300), thirds: false, axes: false).isEmpty)
  }

  func testThirdsAndAxesLandOnTheVideoRectangleNotTheView() {
    // A 16:9 video letterboxed inside a taller view: the guides follow the video rect.
    let video = CGRect(x: 0, y: 30, width: 300, height: 150)
    let thirds = segments(CameraPreviewView.overlayPath(in: video, thirds: true, axes: false))
    XCTAssertEqual(thirds.count, 4)
    XCTAssertEqual(thirds.map { $0.0.x }, [100, 0, 200, 0])
    XCTAssertEqual(thirds.map { $0.0.y }, [30, 80, 30, 130])
    XCTAssertEqual(thirds[0].1, CGPoint(x: 100, y: 180))
    XCTAssertEqual(thirds[1].1, CGPoint(x: 300, y: 80))

    let axes = segments(CameraPreviewView.overlayPath(in: video, thirds: false, axes: true))
    XCTAssertEqual(axes.count, 2)
    XCTAssertEqual(axes[0].0, CGPoint(x: 150, y: 30))
    XCTAssertEqual(axes[0].1, CGPoint(x: 150, y: 180))
    XCTAssertEqual(axes[1].0, CGPoint(x: 0, y: 105))
    XCTAssertEqual(axes[1].1, CGPoint(x: 300, y: 105))

    XCTAssertEqual(segments(CameraPreviewView.overlayPath(in: video, thirds: true, axes: true)).count, 6)
  }
}
