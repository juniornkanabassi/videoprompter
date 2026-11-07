import AppKit
import XCTest
@testable import VideoPrompter

@MainActor final class PresenterMinimumReview2Tests: XCTestCase {
  func testMinimumUsesVisibleArea() {
    let area = NSRect(x: 0, y: 0, width: 800, height: 600)
    XCTAssertEqual(PresenterFrameMemory.clamp(NSRect(x: 0, y: 0, width: 200, height: 150), into: area).size, NSSize(width: 720, height: 520))
    let tiny = NSRect(x: 0, y: 0, width: 500, height: 400)
    XCTAssertEqual(PresenterFrameMemory.clamp(NSRect(x: 0, y: 0, width: 200, height: 150), into: tiny).size, tiny.size)
  }
}
