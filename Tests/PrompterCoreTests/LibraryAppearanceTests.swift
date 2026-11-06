import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class LibraryAppearanceTests: XCTestCase {
  func testInspectorChoiceKeepsItsAppearanceAndWritesSelection() throws {
    var selection = "one"
    let host = NSHostingView(rootView: InspectorChoice(title: "Test choice", values: ["one", "two"],
      names: ["One", "Two"], selection: Binding(get: { selection }, set: { selection = $0 }))
      .environment(\.colorScheme, .dark))
    host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
    host.layoutSubtreeIfNeeded()
    func buttons(_ view: NSView) -> [NSPopUpButton] {
      (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let button = try XCTUnwrap(buttons(host).first)
    XCTAssertEqual(button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    XCTAssertEqual(button.title, "One")
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(selection, "two")
    XCTAssertEqual(button.accessibilityLabel(), "Test choice")
  }
}
