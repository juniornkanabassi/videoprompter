import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class PresenterReview2Tests: XCTestCase {
  func testSpaceTogglesReadingWhenHostingViewHasFocus() throws {
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    let host = NSHostingView(rootView: Text("Presenter"))
    panel.contentView = host
    XCTAssertTrue(panel.makeFirstResponder(host))
    XCTAssertTrue(panel.firstResponder === host)
    var reading = false
    panel.onPassageKey = { _ in reading.toggle(); return true }
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    XCTAssertTrue(panel.handlePassageKey(event))
    XCTAssertTrue(reading)
    XCTAssertTrue(panel.handlePassageKey(event))
    XCTAssertFalse(reading)
  }
}
