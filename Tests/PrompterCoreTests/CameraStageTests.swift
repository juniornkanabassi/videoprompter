import AVFoundation
import AppKit
import XCTest

@testable import JuniorPrompter

/// The stage view's life in a window, driven the way the presenter and the Camera window drive
/// it, and its geometry through a resize. Nothing here opens a camera or puts a window on screen.
@MainActor
final class CameraStageTests: XCTestCase {
  /// A window that never reaches the screen but orders in and out the way AppKit does, as
  /// measured on this Mac: `isVisible` changes at once and says so through KVO, while the
  /// occlusion report comes 20–300 ms later, and in 0.8.1 once said "hidden" for a presenter
  /// that was plainly on screen.
  private final class StageWindow: NSWindow {
    private var shown = false
    private var occlusion: NSWindow.OcclusionState = []
    override var isVisible: Bool { shown }
    override var occlusionState: NSWindow.OcclusionState { occlusion }

    /// `makeKeyAndOrderFront`, `orderOut`, `miniaturize` and friends.
    func order(_ on: Bool) {
      willChangeValue(for: \.isVisible)
      shown = on
      didChangeValue(for: \.isVisible)
    }
    /// The close button: `willClose`, then ordered out.
    func closeFromTheButton() {
      NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: self)
      order(false)
    }
    /// Whatever the window server says about coverage, whenever it says it.
    func reportOcclusion(visible: Bool) {
      occlusion = visible ? .visible : []
      NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }
  }

  private let session = SharedCameraSession.shared
  private var held: Int { session.holderCount }

  private func window() -> StageWindow {
    let window = StageWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = NSView()
    return window
  }

  /// What SwiftUI does with `CameraPreview`: make the view and update it once.
  private func stage(_ guides: CameraGuides = CameraGuides()) -> CameraStageView {
    let view = CameraStageView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    view.apply(uid: nil, guides: guides, mirrored: false)
    return view
  }
  /// And what it does when the view leaves the tree.
  private func dismantle(_ view: CameraStageView) {
    view.removeFromSuperview()
    CameraPreview.dismantleNSView(view, coordinator: ())
  }

  override func setUp() {
    super.setUp()
    XCTAssertEqual(held, 0, "another test left the camera held")
  }

  /// 0.8.1: Prompter + video worked the first time and showed no picture the next. `present`
  /// builds the content while the panel is ordered out and shows the panel straight after; the
  /// view then waited for an occlusion report. Twice round, with the mode switched off and on in
  /// between, and the close button at the end.
  func testTheSessionIsHeldExactlyWhileAPresenterViewIsShowing() {
    let panel = window()
    for round in 1...2 {
      // present(): a fresh hosting view into the ordered-out panel, then makeKeyAndOrderFront.
      let host = NSView()
      let first = stage()
      host.addSubview(first)
      panel.contentView = host
      XCTAssertEqual(held, 0, "round \(round): an ordered-out panel holds nothing")
      panel.order(true)
      XCTAssertEqual(held, 1, "round \(round): shown is held, before any occlusion report")
      panel.reportOcclusion(visible: true)
      XCTAssertEqual(held, 1, "round \(round): the late report adds no second hold")

      // Prompter only, then Prompter + video, with the presenter up the whole time.
      dismantle(first)
      XCTAssertEqual(held, 0, "round \(round): Prompter only lets go")
      panel.reportOcclusion(visible: false)
      let second = stage()
      host.addSubview(second)
      XCTAssertEqual(held, 1, "round \(round): Prompter + video holds again at once")

      // closeNow(): orderOut, then the content view is swapped and SwiftUI dismantles.
      panel.order(false)
      XCTAssertEqual(held, 0, "round \(round): ordered out lets go")
      panel.contentView = NSView()
      CameraPreview.dismantleNSView(second, coordinator: ())
      XCTAssertEqual(held, 0, "round \(round): dismantling after the swap releases nothing twice")
    }

    // The close button leaves the hosting view in the panel.
    let view = stage()
    panel.contentView?.addSubview(view)
    panel.order(true)
    XCTAssertEqual(held, 1)
    panel.closeFromTheButton()
    XCTAssertEqual(held, 0, "closed lets go")
    panel.order(true)
    XCTAssertEqual(held, 1, "shown again holds again")
    panel.order(false)
    dismantle(view)
    XCTAssertEqual(held, 0)
  }

  /// Prompter + video chosen while the presenter is already up: the view arrives in a window
  /// that is on screen, whatever the occlusion report says.
  func testAViewAddedToAnAlreadyVisibleWindowHolds() {
    let shown = window()
    shown.order(true)
    let view = stage()
    shown.contentView?.addSubview(view)
    XCTAssertEqual(held, 1)
    shown.reportOcclusion(visible: false)
    XCTAssertEqual(held, 1, "an occlusion report does not take the picture off a shown window")
    dismantle(view)
    XCTAssertEqual(held, 0)
    shown.order(false)
  }

  /// With Auto on, the orientation detector kept the view that first asked for it alive, and
  /// with it that view's preview layer on the running session.
  func testAutoOrientationKeepsNoDismantledViewAlive() {
    var auto = CameraGuides()
    auto.automaticRotation = true
    let shown = window()
    shown.order(true)
    let other = stage(auto)
    weak var gone: CameraStageView?
    autoreleasepool {
      let first = stage(auto)
      shown.contentView?.addSubview(first)
      shown.contentView?.addSubview(other)
      gone = first
      dismantle(first)
    }
    XCTAssertTrue(session.isAutoOrienting, "the other view still wants Auto")
    XCTAssertNil(gone)
    dismantle(other)
    XCTAssertFalse(session.isAutoOrienting)
    XCTAssertEqual(held, 0)
    shown.order(false)
  }

  /// 0.8.1 took the guides from the preview layer's own idea of the video rectangle, which lags a
  /// resize and is empty before the first frame. They follow the fitted picture instead, at 0°
  /// and 90°, whether the connection or the layer turns the picture.
  func testGuidesFollowTheFittedPictureThroughAResize() throws {
    let aspect = session.pictureSize ?? CGSize(width: 16, height: 9)
    for rotation in [CameraRotation.none, .quarter] {
      for turnedByConnection in [false, true] {
        let label = "\(rotation.label), turned by \(turnedByConnection ? "connection" : "layer")"
        var guides = CameraGuides()
        guides.rotation = rotation
        guides.thirds = true
        guides.axes = true
        let host = window()
        let view = stage(guides)
        // Stands in for a camera connection that accepts the angle; none exists in a test.
        view.rotatesInConnection = turnedByConnection
        host.contentView?.addSubview(view)
        let preview = try XCTUnwrap(
          view.layer?.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }, label)
        for size in [
          NSSize(width: 760, height: 520), NSSize(width: 1395, height: 1024),
          NSSize(width: 400, height: 900),
        ] {
          view.setFrameSize(size)
          view.layoutSubtreeIfNeeded()
          let fitted = rotation.fittedRect(aspect: aspect, in: view.bounds)
          let drawn = try XCTUnwrap(view.guideLayer.path, label).boundingBoxOfPath
          let where_ = "\(label) at \(Int(size.width))x\(Int(size.height))"
          assertEqual(drawn, fitted, where_)
          XCTAssertEqual(view.guideLayer.frame, view.bounds, where_)
          assertEqual(preview.frame, turnedByConnection ? view.bounds : fitted, where_)
        }
        XCTAssertEqual(view.guideLayer.contentsScale, host.backingScaleFactor, "\(label): sharp lines")
        dismantle(view)
      }
    }
  }

  private func assertEqual(
    _ a: CGRect, _ b: CGRect, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
      XCTAssertEqual(x, y, accuracy: 0.001, "\(message): \(a) is not \(b)", file: file, line: line)
    }
  }
}
