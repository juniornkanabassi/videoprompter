import AVFoundation
import XCTest

@testable import VideoPrompter

/// The camera picker's preview choices and its session count. No camera is opened: the sessions
/// are fakes, and the one real session in here is given a camera that does not exist.
@MainActor
final class CameraPickerTests: XCTestCase {
  /// Counts the dedicated sessions the picker has open.
  @MainActor private final class Feeds {
    var opened: [String] = []
    var live = 0
    var fallBacks = 0
    var events: [String] = []
    var firstFrame: (@Sendable () -> Void)?

    var factory: CameraPickerPreview.Factory {
      { [unowned self] uid, _, _, firstFrame in
        opened.append(uid)
        live += 1
        self.firstFrame = firstFrame
        return Feed(feeds: self)
      }
    }
  }

  @MainActor private final class Feed: CameraPreviewFeed {
    let feeds: Feeds
    private var stopped = false
    init(feeds: Feeds) { self.feeds = feeds }
    func fallBack() { feeds.fallBacks += 1 }
    func stop(then done: @escaping @Sendable () -> Void) {
      XCTAssertFalse(stopped, "a session was stopped twice")
      stopped = true
      feeds.live -= 1
      feeds.events.append("closed")
      done()
    }
  }

  private let session = SharedCameraSession.shared

  func testThePreviewUsesTheSharedSessionForItsOwnCameraAndNothingWithoutAccess() {
    typealias Preview = CameraPickerPreview
    XCTAssertEqual(Preview.source(for: "cam-b", sharedUID: "cam-b", authorized: true), .shared("cam-b"))
    XCTAssertEqual(Preview.source(for: "cam-a", sharedUID: "cam-b", authorized: true), .dedicated("cam-a"))
    XCTAssertEqual(Preview.source(for: "cam-a", sharedUID: nil, authorized: true), .dedicated("cam-a"))
    XCTAssertEqual(Preview.source(for: nil, sharedUID: "cam-b", authorized: true), .none)
    XCTAssertEqual(Preview.source(for: "cam-b", sharedUID: "cam-b", authorized: false), .none)
    XCTAssertEqual(Preview.source(for: "cam-a", sharedUID: "cam-b", authorized: false), .none)
  }

  func testOneDedicatedSessionAtATimeAcrossRapidHoversAndNoneAfterClosing() async {
    XCTAssertEqual(session.holderCount, 0, "another test left the camera held")
    let feeds = Feeds()
    let preview = CameraPickerPreview(sharedUID: { "cam-b" }, authorized: { true }, makeFeed: feeds.factory)
    for uid in ["cam-a", "cam-c", "cam-a", "cam-d", nil, "cam-c", "cam-c"] {
      preview.show(uid)
      XCTAssertLessThanOrEqual(feeds.live, 1, "after hovering \(uid ?? "nothing")")
    }
    XCTAssertEqual(feeds.live, 1)
    XCTAssertEqual(preview.source, .dedicated("cam-c"))
    XCTAssertEqual(feeds.opened, ["cam-a", "cam-c", "cam-a", "cam-d", "cam-c"], "staying on a camera reopened it")

    // The shared session's own camera: no second session, and the shared one is held meanwhile.
    preview.show("cam-b")
    XCTAssertEqual(feeds.live, 0)
    XCTAssertEqual(preview.source, .shared("cam-b"))
    XCTAssertNotNil(preview.layer)
    XCTAssertEqual(session.holderCount, 1)
    preview.show("cam-a")
    XCTAssertEqual(session.holderCount, 0)
    XCTAssertEqual(feeds.live, 1)

    // Choosing a camera: the selection waits until its preview session has closed.
    let chosen = expectation(description: "selection made")
    preview.stop {
      feeds.events.append("selected")
      chosen.fulfill()
    }
    await fulfillment(of: [chosen], timeout: 1)
    XCTAssertEqual(feeds.events.suffix(2), ["closed", "selected"])
    XCTAssertEqual(feeds.live, 0)
    XCTAssertEqual(preview.source, .none)
    XCTAssertNil(preview.layer)
    XCTAssertNil(preview.feed)
    preview.stop()
    XCTAssertEqual(feeds.live, 0)

    // Without camera access, hovering opens nothing.
    let denied = CameraPickerPreview(sharedUID: { nil }, authorized: { false }, makeFeed: feeds.factory)
    denied.show("cam-a")
    XCTAssertEqual(denied.source, .none)
    XCTAssertNil(denied.layer)
    XCTAssertEqual(feeds.live, 0)
  }

  func testNoSignalAfterTheTimeoutFallsBackOnceAndClearsOnAFrame() async throws {
    let feeds = Feeds()
    let preview = CameraPickerPreview(
      timeout: .milliseconds(20), sharedUID: { nil }, authorized: { true }, makeFeed: feeds.factory)
    preview.show("cam-a")
    XCTAssertFalse(preview.noSignal)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(preview.noSignal)
    XCTAssertEqual(feeds.fallBacks, 1)
    feeds.firstFrame?()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(preview.noSignal)

    // A frame in time: no warning, no fallback. A late frame from a camera left behind: ignored.
    preview.show("cam-c")
    let left = feeds.firstFrame
    feeds.firstFrame?()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(preview.noSignal)
    XCTAssertEqual(feeds.fallBacks, 1)
    preview.show("cam-d")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(preview.noSignal)
    left?()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(preview.noSignal, "a frame from the previous camera cleared the warning")
    preview.stop()
    XCTAssertFalse(preview.noSignal)
  }

  /// Cam B is mounted on its side: its thumbnail turns by its own saved 90° and comes out
  /// portrait, while a camera with nothing saved stays as it is.
  func testThePreviewTakesEachCamerasOwnSavedRotation() throws {
    let suite = "VideoPrompter.picker.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = CameraGuideStore(defaults: UserDefaults(suiteName: suite)!)
    var turned = CameraGuides()
    turned.rotation = .quarter
    store.set(turned, for: "cam-b")
    turned.rotation = .half
    store.set(turned, for: "cam-a")
    let feeds = Feeds()
    let preview = CameraPickerPreview(
      sharedUID: { nil }, authorized: { true }, guides: store, makeFeed: feeds.factory)

    preview.show("cam-b")
    XCTAssertEqual(preview.rotation, .quarter)
    let thumbnail = CameraThumbnailView()
    thumbnail.frame = NSRect(x: 0, y: 0, width: 240, height: 135)
    thumbnail.preview = preview.layer
    thumbnail.rotation = preview.rotation
    thumbnail.aspect = CGSize(width: 3840, height: 2160)
    thumbnail.layout()
    let shown = try XCTUnwrap(preview.layer).frame
    XCTAssertEqual(shown.height, 135, accuracy: 0.5)
    XCTAssertEqual(shown.width, 135 * 9 / 16, accuracy: 0.5)
    XCTAssertEqual(shown.midX, 120, accuracy: 0.5)

    preview.show("cam-a")
    XCTAssertEqual(preview.rotation, .half)
    preview.show("cam-c")
    XCTAssertEqual(preview.rotation, .none)
    preview.stop()
  }

  func testTheButtonAlwaysNamesACamera() {
    let cameras = [
      CameraDevice(uid: "uid-built-in", name: "FaceTime HD Camera"),
      CameraDevice(uid: "uid-cam-b", name: "Blackmagic Cam B"),
    ]
    XCTAssertEqual(CameraPicker.label(for: "uid-cam-b", in: cameras), "Blackmagic Cam B")
    XCTAssertEqual(CameraPicker.label(for: "uid-gone", in: cameras), "FaceTime HD Camera")
    XCTAssertEqual(CameraPicker.label(for: nil, in: cameras), "FaceTime HD Camera")
    XCTAssertEqual(CameraPicker.label(for: nil, in: []), "No camera")
    XCTAssertEqual(CameraPicker.label(for: "uid-cam-b", in: []), "No camera")
    XCTAssertEqual(CameraPicker.label(for: "blank", in: [CameraDevice(uid: "blank", name: " ")]), "Unnamed camera")
  }

  /// The real session, with a camera that is not there: it opens nothing, and it closes on its
  /// own queue, never the main one, which is where 0.7.1 trapped.
  func testARealPreviewSessionClosesOffTheMainQueue() async {
    let closed = expectation(description: "closed")
    let feed = CameraPreviewSession(uid: "no-such-camera", layer: AVCaptureVideoPreviewLayer(), mirrored: true) {}
    feed.fallBack()
    feed.stop {
      dispatchPrecondition(condition: .notOnQueue(.main))
      closed.fulfill()
    }
    await fulfillment(of: [closed], timeout: 2)
  }
}

/// The preview gives the device its original format back only while the device is still on the
/// exact one the preview applied; a format chosen later is not the preview's to undo.
final class CameraPickerFormatOwnershipTests: XCTestCase {
  func testOriginalFormatIsRestoredOnlyWhileTheDeviceStillHasThePreviewsOwn() {
    typealias Session = CameraPreviewSession
    XCTAssertEqual(Session.formatToRestore(original: "4K", applied: "medium", current: "medium"), "4K")
    XCTAssertNil(Session.formatToRestore(original: "4K", applied: "medium", current: "1080"), "chosen later")
    XCTAssertNil(Session.formatToRestore(original: "4K", applied: nil, current: "4K"), "never applied")
    XCTAssertNil(Session.formatToRestore(original: "4K", applied: "4K", current: "4K"), "nothing changed")
  }
}
