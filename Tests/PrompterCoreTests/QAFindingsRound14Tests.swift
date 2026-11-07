import AppKit
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor final class QAFindingsRound14Tests: XCTestCase {
  private func fixture() async -> (AppStore, CameraModel, CameraRecorder, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa14-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("QA14")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.appendingPathComponent("library").path], defaults: defaults))
    await store.waitForInitialLoad()
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    return (store, camera, recorder, root)
  }

  private func group(_ manager: UndoManager, _ action: () -> Void) {
    manager.beginUndoGrouping(); action(); manager.endUndoGrouping()
  }

  func testBlockedSetupUndoDoesNotErasePresetRedoOnUnlock() async throws {
    let (store, camera, recorder, _) = await fixture()
    let manager = UndoManager(); manager.groupsByEvent = false
    store.savePreset(named: "Studio")
    let preset = store.presets[0]
    store.settings.fontSize = 80
    group(manager) { store.updatePreset(preset.id, undoManager: manager) }
    var setup = ShootSetup(name: "Large text"); setup.reading.fontSize = 120
    group(manager) { XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: [], undoManager: manager)) }
    recorder.phase = .recording
    manager.undo() // Blocked setup undo must not change capture settings.
    XCTAssertEqual(store.settings.fontSize, 120)
    manager.undo() // Earlier preset replacement is independent of capture.
    XCTAssertEqual(store.presets[0].fontSize, preset.fontSize)
    XCTAssertTrue(manager.canRedo)
    XCTAssertEqual(manager.redoActionName, "Replace Preset")
    recorder.phase = .idle
    XCTAssertTrue(manager.canRedo, "Unlocking the recorder must not discard an unrelated preset's redo history")
    if manager.canRedo { manager.redo() }
    XCTAssertEqual(store.presets[0].fontSize, 80)
  }

  func testBlockedSetupUndoDoesNotJumpAheadOfLaterSetupDeletion() async throws {
    let (store, camera, recorder, _) = await fixture()
    let manager = UndoManager(); manager.groupsByEvent = false
    XCTAssertTrue(store.saveShootSetup(named: "Saved", camera: camera, recorder: recorder))
    let saved = store.shootSetups[0]
    var setup = ShootSetup(name: "Large text"); setup.reading.fontSize = 120
    group(manager) { XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: [], undoManager: manager)) }
    recorder.phase = .recording
    manager.undo()
    group(manager) { store.deleteShootSetup(saved.id, undoManager: manager) }
    XCTAssertEqual(manager.undoActionName, "Delete Shoot Setup")
    recorder.phase = .idle
    XCTAssertEqual(manager.undoActionName, "Delete Shoot Setup", "A deferred old undo must not be inserted above a newer edit")
    manager.undo()
    XCTAssertEqual(store.shootSetups.map(\.id), [saved.id])
    XCTAssertEqual(store.settings.fontSize, 120, "Undo Delete must not unexpectedly switch the active setup")
  }

  func testBlockedSetupRetryPreservesRedoEntriesOnBothSides() async throws {
    let (store, camera, recorder, _) = await fixture()
    let manager = UndoManager(); manager.groupsByEvent = false
    let originalSize = store.settings.fontSize
    var setup = ShootSetup(name: "Large text"); setup.reading.fontSize = 120
    group(manager) { XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: [], undoManager: manager)) }
    store.savePreset(named: "Studio")
    let preset = store.presets[0]
    store.settings.fontSize = 80
    group(manager) { store.updatePreset(preset.id, undoManager: manager) }
    store.settings.fontSize = 120
    manager.undo()
    recorder.phase = .recording
    manager.undo()
    recorder.phase = .idle
    XCTAssertEqual(manager.undoActionName, "Apply Shoot Setup")
    XCTAssertEqual(manager.redoActionName, "Replace Preset")
    manager.undo()
    XCTAssertEqual(store.settings.fontSize, originalSize)
    recorder.phase = .recording
    manager.redo()
    recorder.phase = .idle
    XCTAssertEqual(manager.redoActionName, "Apply Shoot Setup")
    manager.redo()
    XCTAssertEqual(store.settings.fontSize, 120)
    XCTAssertEqual(manager.redoActionName, "Replace Preset")
    manager.redo()
    XCTAssertEqual(store.presets[0].fontSize, 80)
    XCTAssertTrue(store.pendingShootUndos.isEmpty)
  }

  func testRapidUnlinkDeleteUndoRedoPreservesTextAndLink() async throws {
    let (store, _, _, root) = await fixture()
    let external = root.appendingPathComponent("external.md")
    try "Original words".write(to: external, atomically: true, encoding: .utf8)
    let script = try await store.createScript(title: "Linked", markdown: "Original words", linkTo: external)
    let manager = UndoManager(); manager.groupsByEvent = false
    store.updateMarkdown("Edited words", for: script.id)
    group(manager) { store.unlink(script.id, undoManager: manager) }
    group(manager) { store.delete([script.id], undoManager: manager) }
    manager.undo()
    manager.undo()
    _ = await store.flushPendingSaves()
    XCTAssertNil(store.errorMessage)
    XCTAssertEqual(store.scripts.first?.metadata.linkedPath, external.path)
    XCTAssertEqual(store.scripts.first?.markdown, "Edited words")
    let library = try XCTUnwrap(store.library)
    let restored = try await library.read(script.id)
    XCTAssertEqual(restored.markdown, "Edited words")
    XCTAssertEqual(restored.metadata.linkedPath, external.path)
    manager.redo()
    manager.redo()
    _ = await store.flushPendingSaves()
    XCTAssertTrue(store.scripts.isEmpty)
    XCTAssertEqual(store.trash.first?.id, script.id)
    manager.undo()
    manager.undo()
    _ = await store.flushPendingSaves()
    XCTAssertEqual(store.scripts.first?.metadata.linkedPath, external.path)
    XCTAssertEqual(store.scripts.first?.markdown, "Edited words")
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "Original words")
  }

  func testRapidUndoDeleteThenUnlinkRestoresOriginalLink() async throws {
    let (store, _, _, root) = await fixture()
    let external = root.appendingPathComponent("external.md")
    try "Original words".write(to: external, atomically: true, encoding: .utf8)
    let script = try await store.createScript(title: "Linked", markdown: "Original words", linkTo: external)
    let manager = UndoManager(); manager.groupsByEvent = false
    group(manager) { store.unlink(script.id, undoManager: manager) }
    await store.libraryEditTask?.value
    group(manager) { store.delete([script.id], undoManager: manager) }
    await store.waitForScriptDeletions()
    XCTAssertTrue(store.scripts.isEmpty)
    manager.undo()
    manager.undo()
    await store.waitForScriptDeletions()
    await store.libraryEditTask?.value
    let restored = try XCTUnwrap(store.scripts.first { $0.id == script.id })
    XCTAssertEqual(restored.metadata.linkedPath, script.metadata.linkedPath,
      "Rapid Undo of Delete then Unlink must restore both operations, even before restoration finishes")
    XCTAssertNil(store.errorMessage)
    let library = try XCTUnwrap(store.library)
    let disk = try await library.read(script.id)
    XCTAssertEqual(disk.metadata.linkedPath, script.metadata.linkedPath)
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "Original words")
  }
}
