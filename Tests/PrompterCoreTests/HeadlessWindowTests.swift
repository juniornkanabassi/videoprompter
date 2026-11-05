import AppKit
import XCTest
@testable import VideoPrompter

@MainActor final class HeadlessWindowTests: XCTestCase {
  private func window() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 320, height: 240),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    return window
  }

  func testPrefersCurrentLibraryAndKeepsSurvivorWhenFirstCloses() {
    let tracker = Headless(arguments: ["test"])
    let first = window(), second = window(), unrelated = window()
    defer { first.close(); second.close(); unrelated.close() }
    tracker.registerLibraryWindow(first)
    tracker.registerLibraryWindow(second)
    XCTAssertTrue(tracker.preferredLibraryWindow(key: second, main: first) === second)
    XCTAssertTrue(tracker.preferredLibraryWindow(key: unrelated, main: second) === second)
    first.close()
    XCTAssertTrue(tracker.preferredLibraryWindow(key: first, main: nil) === second,
      "A retained but closed first window must not displace the surviving library")
    second.close()
    XCTAssertNil(tracker.preferredLibraryWindow(key: first, main: second))
    XCTAssertFalse(unrelated.isVisible)
  }

  func testEveryRegisteredHeadlessLibraryIsHidden() async throws {
    let tracker = Headless(arguments: ["test", "--headless"])
    let first = window(), second = window()
    defer { first.close(); second.close() }
    tracker.registerLibraryWindow(first)
    tracker.registerLibraryWindow(second)
    for window in [first, second] {
      XCTAssertEqual(window.alphaValue, 0)
      XCTAssertTrue(window.ignoresMouseEvents)
      XCTAssertFalse(window.isVisible)
      XCTAssertLessThan(window.frame.maxX, 0)
      // Simulate SwiftUI ordering after the probe, while remaining transparent and off screen.
      window.orderFront(nil)
      XCTAssertTrue(window.isVisible)
    }
    XCTAssertTrue(tracker.preferredLibraryWindow(key: nil, main: nil) === second,
      "With no key library, prefer the frontmost library before unordered hidden windows")
    // Drain the deferred hiding; neither transparent window has displayed any pixels.
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertFalse(first.isVisible)
    XCTAssertFalse(second.isVisible)
    XCTAssertTrue(tracker.windowHidden)
  }
}
