import AppKit
import XCTest
import PrompterCore
@testable import VideoPrompter

@MainActor final class RelinkUndoTests: XCTestCase {
  private func fixture() async throws -> (AppStore, MarkdownLibrary, ScriptRecord, URL, UndoManager) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelinkUndo-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(
      arguments: ["test", "--data-directory", root.appendingPathComponent("library").path],
      defaults: freshDefaults("RelinkUndo")))
    await store.waitForInitialLoad()
    let script = try await store.createScript(title: "Original", markdown: "Original text")
    let file = root.appendingPathComponent("replacement.md")
    try Data("Replacement text".utf8).write(to: file)
    let manager = UndoManager()
    manager.groupsByEvent = false
    return (store, try XCTUnwrap(store.library), script, file, manager)
  }

  private func link(_ store: AppStore, _ id: UUID, to file: URL, manager: UndoManager) async {
    manager.beginUndoGrouping()
    let success = await store.relink(id, to: file, resolution: .useFile, undoManager: manager)
    manager.endUndoGrouping()
    XCTAssertTrue(success)
  }

  private func assertState(_ store: AppStore, _ library: MarkdownLibrary, _ id: UUID,
                           text: String, link: URL?, file: StaticString = #filePath, line: UInt = #line) async throws {
    await store.libraryEditTask?.value
    let result = try await library.read(id)
    XCTAssertEqual(result.markdown, text, file: file, line: line)
    XCTAssertEqual(result.metadata.linkedPath, link?.standardizedFileURL.path, file: file, line: line)
    XCTAssertEqual(store.scripts.first(where: { $0.id == id }), result, file: file, line: line)
  }

  // The reviewer's reproduction: Redo runs before the queued Undo touches disk.
  func testRapidRelinkUndoRedoUndo() async throws {
    let (store, library, script, file, manager) = try await fixture()
    await link(store, script.id, to: file, manager: manager)
    manager.undo()
    manager.redo()
    try await assertState(store, library, script.id, text: "Replacement text", link: file)
    manager.undo()
    try await assertState(store, library, script.id, text: "Original text", link: nil)
    for _ in 0..<3 {
      manager.redo()
      try await assertState(store, library, script.id, text: "Replacement text", link: file)
      manager.undo()
      try await assertState(store, library, script.id, text: "Original text", link: nil)
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Replacement text")
    XCTAssertNil(store.errorMessage)
  }

  func testRapidRelinkUndoRedoUndoRestoresPreviousFileLink() async throws {
    let (store, library, script, file, manager) = try await fixture()
    let original = file.deletingLastPathComponent().appendingPathComponent("original.md")
    try Data("Original linked text".utf8).write(to: original)
    await link(store, script.id, to: original, manager: manager)
    manager.removeAllActions()
    await link(store, script.id, to: file, manager: manager)
    manager.undo()
    manager.redo()
    manager.undo()
    try await assertState(store, library, script.id, text: "Original linked text", link: original)
    manager.redo()
    try await assertState(store, library, script.id, text: "Replacement text", link: file)
    XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "Original linked text")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Replacement text")
    XCTAssertNil(store.errorMessage)
  }

  func testFailedRelinkUndoRemovesQueuedInverse() async throws {
    let (store, library, script, file, manager) = try await fixture()
    await link(store, script.id, to: file, manager: manager)
    let managed = try await library.scriptURL(for: script.id)
    let saved = try Data(contentsOf: managed)
    try FileManager.default.removeItem(at: managed)
    manager.undo()
    manager.redo()
    await store.libraryEditTask?.value
    XCTAssertNotNil(store.errorMessage)
    XCTAssertFalse(manager.canUndo)
    XCTAssertFalse(manager.canRedo)
    try saved.write(to: managed)
    try await assertState(store, library, script.id, text: "Replacement text", link: file)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Replacement text")
  }
}
