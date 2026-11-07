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
    let caption = PresenterReferenceCue(passage: String(repeating: "Bonjour, welcome back. ", count: 100),
      fontName: "Helvetica Neue", readingSize: 72, end: {})
    XCTAssertEqual(caption.readingSize, 72)
    XCTAssertGreaterThan(caption.passage.count, 1000)
  }
}

extension ReadingAccessibilityTests {
  func testReadingChoicesExposeTheSelectedValueAtEveryZoom() async throws {
    for zoom in [1.0, 1.5, 2.0] {
      for (label, values, names, selected) in [
        ("Mode", ["Voice", "Manual"], ["Voice follow", "Automatic scroll"], "Voice"),
        ("Reading font", ["SF Pro", "Lexend"], ["SF Pro", "Lexend"], "SF Pro"),
        ("Alignment", ["Left", "Center", "Right"], ["Left", "Centre", "Right"], "Center")
      ] {
        let (window, host) = await LibraryAX.host(ReadingChoice(title: label, values: values, names: names, selection: .constant(selected), zoom: zoom).uiZoom(zoom))
        defer { LibraryAX.close(window) }
        let expected = names[try XCTUnwrap(values.firstIndex(of: selected))]
        let controls = LibraryAX.named(label, in: host).filter {
          ["AXMenuButton", "AXPopUpButton"].contains(LibraryAX.value($0, "accessibilityRole"))
        }
        let control = try XCTUnwrap(controls.first, "\(label) at \(zoom)")
        XCTAssertEqual(LibraryAX.value(control, "accessibilityValue"), expected)
        let (optionWindow, optionHost) = await LibraryAX.host(ReadingChoiceOption(name: expected, isSelected: true).uiZoom(zoom))
        defer { LibraryAX.close(optionWindow) }
        let selectedOption = try XCTUnwrap(LibraryAX.named(expected, in: optionHost).first)
        XCTAssertTrue(LibraryAX.bool(selectedOption, "isAccessibilitySelected"))
        if let popup = control as? NSPopUpButtonCell {
          XCTAssertEqual(popup.selectedItem?.title, expected)
          XCTAssertEqual(popup.selectedItem?.state, .on)
        }
      }
    }
  }
}
