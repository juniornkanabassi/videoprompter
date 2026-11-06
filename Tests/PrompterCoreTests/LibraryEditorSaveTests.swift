import XCTest
@testable import VideoPrompter

@MainActor final class LibraryEditorSaveTests: XCTestCase {
  func testNewestMetadataAndBodyReachDiskBeforeSavedFeedback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "VideoPrompter.EditorSave.\(UUID())"
    defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: TestDefaults.suite(named: suite)!)
    let record = try await store.createScript(title: "Original", markdown: "Original body")
    let saver = LibraryEditorSave()
    saver.schedule(store: store, id: record.id, title: "Intermediate", tags: [], delay: .seconds(1))
    store.updateMarkdown("The newest body", for: record.id)
    let last = saver.schedule(store: store, id: record.id, title: "Final title", tags: ["take"], delay: .zero)
    XCTAssertTrue(saver.isSaving)
    await last.value
    XCTAssertEqual(saver.message, "Saved")
    XCTAssertFalse(saver.failed)
    await store.reload()
    let saved = try XCTUnwrap(store.scripts.first { $0.id == record.id })
    XCTAssertEqual(saved.metadata.title, "Final title")
    XCTAssertEqual(saved.metadata.tags, ["take"])
    XCTAssertEqual(saved.markdown, "The newest body")
  }
}
