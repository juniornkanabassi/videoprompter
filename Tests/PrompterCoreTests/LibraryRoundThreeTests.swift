import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class LibraryRoundThreeTests: XCTestCase {
  func testDiffPreservesWhitespaceUnicodeAndIdentifiesChangedWords() {
    let before = "Bonjour à tous.\n\nThe saved draft."
    let after = "Bonjour à tous.\n\nThe revised draft."
    let diff = RelinkTextChanges(saved: before, file: after)
    XCTAssertEqual(diff.saved.joined(), before)
    XCTAssertEqual(diff.file.joined(), after)
    XCTAssertEqual(diff.removed.map { diff.saved[$0] }, ["saved"])
    XCTAssertEqual(diff.added.map { diff.file[$0] }, ["revised"])
    XCTAssertEqual(diff.removedWords, 1)
    XCTAssertEqual(diff.addedWords, 1)
    let same = RelinkTextChanges(saved: before, file: before)
    XCTAssertTrue(same.removed.isEmpty && same.added.isEmpty)
    let empty = RelinkTextChanges(saved: "", file: "New script")
    XCTAssertTrue(empty.saved.isEmpty)
    XCTAssertEqual(empty.addedWords, 2)
  }

  func testLargeReplacementUsesBoundedDiffAndKeepsBothVersions() {
    let old = String(repeating: "old ", count: 5000)
    let new = String(repeating: "new ", count: 5000)
    let diff = RelinkTextChanges(saved: old, file: new)
    XCTAssertEqual(diff.saved.joined(), old)
    XCTAssertEqual(diff.file.joined(), new)
    XCTAssertEqual(diff.removedWords, 5000)
    XCTAssertEqual(diff.addedWords, 5000)
  }

  func testCameraKeyboardHighlightReachesLastDeviceAndClampsAtEnds() {
    let devices = (1...12).map { CameraDevice(uid: "camera-\($0)", name: "Long camera name \($0)") }
    var highlighted: String? = nil
    for _ in 0..<20 {
      highlighted = CameraPickerList.nextHighlight(highlighted, selected: nil, devices: devices, step: 1)
    }
    XCTAssertEqual(highlighted, "camera-12")
    for _ in 0..<20 {
      highlighted = CameraPickerList.nextHighlight(highlighted, selected: nil, devices: devices, step: -1)
    }
    XCTAssertEqual(highlighted, "camera-1")
    XCTAssertNil(CameraPickerList.nextHighlight(highlighted, selected: nil, devices: [], step: 1))
  }

  func testCameraRecoveryDistinguishesHardwareFromPermissions() {
    XCTAssertEqual(CameraPickerList.recovery(for: .authorized).title, "No camera connected")
    XCTAssertEqual(CameraPickerList.recovery(for: .denied).title, "Camera access is off")
    XCTAssertEqual(CameraPickerList.recovery(for: .notDetermined).title, "Camera access needed")
  }

  func testPresenterEditorLinksUseTheActualForegroundAndAnUnderline() throws {
    var markdown = "Read the [reference](https://example.com)."
    let editor = FormattedMarkdownEditor(markdown: Binding(get: { markdown }, set: { markdown = $0 }),
      fontName: "Helvetica", fontSize: 30, typography: EditorTypography(textColor: .white))
    let host = NSHostingView(rootView: editor)
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
    host.layoutSubtreeIfNeeded()
    func textViews(_ view: NSView) -> [NSTextView] {
      (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
    let text = try XCTUnwrap(textViews(host).first)
    XCTAssertEqual(text.linkTextAttributes?[.foregroundColor] as? NSColor, .white)
    XCTAssertEqual(text.linkTextAttributes?[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
  }
}
