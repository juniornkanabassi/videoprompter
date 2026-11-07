import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class PresenterReview2Tests: XCTestCase {
  func testHostedSwiftUIButtonKeepsSpace() throws {
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    let host = NSHostingView(rootView: Button("Record") {}.focusable())
    panel.contentView = host
    panel.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()
    panel.makeFirstResponder(panel)
    panel.selectNextKeyView(nil)
    XCTAssertFalse(panel.firstResponder === panel)
    panel.onPassageKey = { _ in true }
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    XCTAssertFalse(panel.handlePassageKey(event), "The hosted control must keep Space")
  }

}
