import XCTest
@testable import VideoPrompter

@MainActor
final class ReferenceMonitorTests: XCTestCase {
  private func camera() -> CameraModel {
    let suite = "VideoPrompter.monitor.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    return CameraModel(defaults: UserDefaults(suiteName: suite)!)
  }

  func testCleanKeepsWordsAndDropsMarkdownMarkers() {
    XCTAssertEqual(ReferenceMonitor.clean("## Opening\n\n**Welcome** back.\n- First point"),
                   "Opening\n\nWelcome back.\nFirst point")
    XCTAssertEqual(ReferenceMonitor.clean("  \n\n  "), "")
  }

  func testMonitorShowsCameraOnlyAndRestoresTheEarlierView() {
    let camera = camera()
    let monitor = ReferenceMonitor()
    camera.displayMode = .prompterOnly
    monitor.begin("Welcome back to the channel.", camera: camera)
    XCTAssertEqual(monitor.passage, "Welcome back to the channel.")
    XCTAssertEqual(camera.displayMode, .videoOnly)
    // A second selection replaces the passage but still returns to the original view.
    monitor.begin("Second passage.", camera: camera)
    monitor.end(camera: camera)
    XCTAssertNil(monitor.passage)
    XCTAssertEqual(camera.displayMode, .prompterOnly)
  }

  func testBlankSelectionDoesNothing() {
    let camera = camera()
    let monitor = ReferenceMonitor()
    camera.displayMode = .prompterWithVideo
    monitor.begin("   ", camera: camera)
    XCTAssertNil(monitor.passage)
    XCTAssertEqual(camera.displayMode, .prompterWithVideo)
  }

  func testChoosingAnotherViewEndsTheMonitorWithoutOverridingIt() {
    let camera = camera()
    let monitor = ReferenceMonitor()
    camera.displayMode = .prompterOnly
    monitor.begin("Lines to check.", camera: camera)
    camera.displayMode = .prompterWithVideo
    monitor.displayModeDidChange(camera.displayMode)
    XCTAssertNil(monitor.passage)
    monitor.end(camera: camera)
    XCTAssertEqual(camera.displayMode, .prompterWithVideo)
  }
}
