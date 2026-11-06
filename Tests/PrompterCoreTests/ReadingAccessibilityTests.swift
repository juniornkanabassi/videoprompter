import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class ReadingAccessibilityTests: XCTestCase {
  func testKeyboardAndAccessibilitySeekUseTheSelectedCharacter() throws {
    let text = TrackingTextView()
    text.string = "Opening words. Bonjour à tous."
    var positions: [Int] = []
    text.onCharacterClick = { positions.append($0) }
    text.setSelectedRange(NSRange(location: 15, length: 7))
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    text.keyDown(with: event)
    XCTAssertEqual(positions, [15])
    XCTAssertTrue(text.accessibilityReadFromSelection())
    XCTAssertEqual(positions, [15, 15])
    text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    XCTAssertFalse(text.accessibilityReadFromSelection())
    XCTAssertEqual(positions.count, 2)
  }

  func testReferenceMonitorKeepsChosenReadingSize() {
    let caption = ReferenceMonitorCaption(passage: String(repeating: "Bonjour, welcome back. ", count: 100),
      fontName: "Helvetica Neue", readingSize: 72, end: {})
    XCTAssertEqual(caption.readingSize, 72)
    XCTAssertGreaterThan(caption.passage.count, 1000)
  }
}
