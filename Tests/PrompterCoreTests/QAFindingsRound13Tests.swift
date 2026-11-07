import AppKit
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor final class QAFindingsRound13Tests: XCTestCase {
  private func fixture() async -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa13-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("QA13")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    await store.waitForInitialLoad()
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    return (store, camera, recorder)
  }

  func testUndoSetupDeletionAfterNameReuseKeepsNamesUnambiguous() async throws {
    let (store, camera, recorder) = await fixture()
    XCTAssertTrue(store.saveShootSetup(named: "Studio", camera: camera, recorder: recorder))
    let original = try XCTUnwrap(store.shootSetups.first)
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    store.deleteShootSetup(original.id, undoManager: manager)
    manager.endUndoGrouping()
    store.settings.fontSize = 80
    XCTAssertTrue(store.saveShootSetup(named: "Studio", camera: camera, recorder: recorder))
    let replacement = try XCTUnwrap(store.shootSetups.first)
    manager.undo()
    XCTAssertEqual(Set(store.shootSetups.map(\.id)), [original.id, replacement.id], "Both distinct configurations must survive")
    XCTAssertEqual(Set(store.shootSetups.map { $0.name.lowercased() }).count, 2,
      "Undo must not create duplicate setup names which normal save and rename explicitly prohibit")
    let persisted = try JSONDecoder().decode([ShootSetup].self,
      from: XCTUnwrap(store.defaults.data(forKey: "shootSetups")))
    XCTAssertEqual(Set(persisted.map { $0.name.lowercased() }).count, 2,
      "The duplicate names must not survive a relaunch")
  }

  func testUndoPresetReplacementPreservesLaterRename() async throws {
    let (store, _, _) = await fixture()
    store.savePreset(named: "Studio")
    let original = store.presets[0]
    store.settings.fontSize = 80
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    store.updatePreset(original.id, undoManager: manager)
    manager.endUndoGrouping()
    store.renamePreset(original.id, name: "Studio renamed")
    manager.undo()
    XCTAssertEqual(store.presets[0].fontSize, original.fontSize)
    XCTAssertEqual(store.presets[0].name, "Studio renamed", "Undo Replace Preset must not undo a later independent rename")
    _ = await store.flushPendingSaves()
    let persisted = try JSONDecoder().decode([PrompterSettings].self,
      from: XCTUnwrap(store.defaults.data(forKey: "presets")))
    XCTAssertEqual(persisted.first { $0.id == original.id }?.name, "Studio renamed",
      "The later rename must survive a relaunch")
  }

  func testUndoApplySetupWhileRecordingDoesNotDiscardUndo() async throws {
    let (store, camera, recorder) = await fixture()
    let originalSize = store.settings.fontSize
    var setup = ShootSetup(name: "Large text")
    setup.reading.fontSize = 80
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: [], undoManager: manager))
    manager.endUndoGrouping()
    recorder.phase = .recording
    manager.undo()
    XCTAssertEqual(store.settings.fontSize, 80, "Recording must keep the active setup locked")
    recorder.phase = .idle
    XCTAssertTrue(manager.canUndo, "An undo blocked during recording must remain available afterwards")
    if manager.canUndo { manager.undo() }
    XCTAssertEqual(store.settings.fontSize, originalSize, "Stop recording then undo must restore the previous setup")
  }
}
