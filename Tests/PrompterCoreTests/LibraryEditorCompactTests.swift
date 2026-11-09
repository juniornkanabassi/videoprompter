import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class LibraryEditorCompactTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("LibraryEditorCompact")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults))
  }

  func testCompactLayoutFollowsNarrowOrShortPane() {
    XCTAssertFalse(LibraryEditorLayout.isCompact(width: 840, height: 800))
    XCTAssertTrue(LibraryEditorLayout.isCompact(width: 559, height: 800))
    XCTAssertTrue(LibraryEditorLayout.isCompact(width: 840, height: 619))
  }

  func testNarrowDoubleZoomLeavesRoomForSeveralEditableLines() async throws {
    let (store, camera) = fixture()
    let markdown = "Read these words.\n\nSecond line of the script.\n\nThird line of the script."
    let script = try await store.createScript(title: "An opening with a long title that wraps in a narrow window", markdown: markdown)
    store.selectedID = script.id
    store.uiZoom = 2
    let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 840, height: 700))
    defer { LibraryAX.close(window) }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let editor = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first(where: { $0.isEditable }))
    XCTAssertEqual(editor.string, markdown)
    // Layout points, before the 200% scale: about five 20 pt lines of writing area.
    let writingHeight = try XCTUnwrap(editor.enclosingScrollView?.frame.height)
    XCTAssertGreaterThanOrEqual(writingHeight, 100, "writing area at 200% in 840 by 700")
  }
}
