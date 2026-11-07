import AppKit
import PrompterCore
import SwiftUI
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
    manager.redo()
    XCTAssertEqual(store.presets[0].fontSize, 80)
    XCTAssertEqual(store.presets[0].name, "Studio renamed")
    store.renamePreset(original.id, name: "Renamed again")
    manager.undo()
    XCTAssertEqual(store.presets[0].fontSize, original.fontSize)
    XCTAssertEqual(store.presets[0].name, "Renamed again")
    _ = await store.flushPendingSaves()
    let persisted = try JSONDecoder().decode([PrompterSettings].self,
      from: XCTUnwrap(store.defaults.data(forKey: "presets")))
    XCTAssertEqual(persisted.first { $0.id == original.id }?.name, "Renamed again",
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
    recorder.phase = .saving
    manager.redo()
    XCTAssertEqual(store.settings.fontSize, originalSize)
    recorder.phase = .idle
    XCTAssertTrue(manager.canRedo)
    manager.redo()
    XCTAssertEqual(store.settings.fontSize, 80)
    XCTAssertTrue(store.pendingShootUndos.isEmpty)
  }

  func testRestoredSetupNameAvoidsAccentsCaseAndExistingSuffixes() async throws {
    let (store, camera, recorder) = await fixture()
    XCTAssertTrue(store.saveShootSetup(named: "Studio", camera: camera, recorder: recorder))
    let original = try XCTUnwrap(store.shootSetups.first)
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    store.deleteShootSetup(original.id, undoManager: manager)
    manager.endUndoGrouping()
    XCTAssertTrue(store.saveShootSetup(named: "STÚDIO", camera: camera, recorder: recorder))
    XCTAssertTrue(store.saveShootSetup(named: "studio (2)", camera: camera, recorder: recorder))
    for _ in 0..<3 {
      manager.undo()
      XCTAssertEqual(store.shootSetups.first?.id, original.id)
      XCTAssertEqual(store.shootSetups.first?.name, "Studio (3)")
      manager.redo()
      XCTAssertEqual(store.shootSetups.map(\.name), ["STÚDIO", "studio (2)"])
    }
    manager.undo()
    let persisted = try JSONDecoder().decode([ShootSetup].self,
      from: XCTUnwrap(store.defaults.data(forKey: "shootSetups")))
    XCTAssertEqual(persisted.map(\.name), ["Studio (3)", "STÚDIO", "studio (2)"])
  }

  func testUndoApplySetupWhileReadingRemainsAvailable() async throws {
    let (store, camera, recorder) = await fixture()
    store.settings.mode = "Manual"
    let originalSize = store.settings.fontSize
    var setup = ShootSetup(name: "Large text")
    setup.reading.mode = "Manual"
    setup.reading.fontSize = 80
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: [], undoManager: manager))
    manager.endUndoGrouping()
    store.session.present(record: ScriptRecord(metadata: ScriptMetadata(title: "Reading", fileName: "reading.md"), markdown: "One two three"), settings: store.settings)
    store.session.startDelay = 0
    store.session.startReading()
    defer { store.session.stop() }
    XCTAssertTrue(store.session.isActivelyRunning)
    manager.undo()
    XCTAssertEqual(store.settings.fontSize, 80)
    store.session.pause()
    XCTAssertTrue(manager.canUndo)
    manager.undo()
    XCTAssertEqual(store.settings.fontSize, originalSize)
    manager.redo()
    XCTAssertEqual(store.settings.fontSize, 80)
  }


  func testReplacementReceiptCannotUndoALaterApply() async throws {
    let (store, _, _) = await fixture()
    store.savePreset(named: "Studio")
    let original = store.presets[0]
    store.settings.fontSize = 120
    store.savePreset(named: "Field")
    let field = store.presets[1]
    store.settings.fontSize = 80
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    let operationID = store.updatePreset(original.id, undoManager: manager)
    manager.endUndoGrouping()
    XCTAssertTrue(store.canUndoPresetReplacement(operationID, manager: manager))
    let (window, host) = await LibraryAX.host(PresetReplacementReceipt(store: store, preset: original,
      operationID: operationID, manager: manager), size: .init(width: 520, height: 120))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named("Undo", in: host).isEmpty)
    manager.beginUndoGrouping()
    store.applyPreset(field, undoManager: manager)
    manager.endUndoGrouping()
    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertTrue(LibraryAX.named("Undo", in: host).isEmpty, "The old receipt must remove Undo after Apply")
    XCTAssertFalse(store.undoPresetReplacement(operationID, manager: manager), "A stale receipt must not consume Apply")
    XCTAssertEqual(store.settings.fontSize, 120)
    XCTAssertEqual(store.presets[0].fontSize, 80)
    XCTAssertEqual(manager.undoActionName, "Apply Reading Preset")
    manager.undo()
    XCTAssertEqual(store.settings.fontSize, 80, "Edit > Undo must still undo Apply normally")
    XCTAssertTrue(store.canUndoPresetReplacement(operationID, manager: manager))
    XCTAssertTrue(store.undoPresetReplacement(operationID, manager: manager))
    XCTAssertEqual(store.presets[0].fontSize, original.fontSize)
  }

  func testReplacementReceiptDistinguishesTwoReplacements() async throws {
    let (store, _, _) = await fixture()
    store.savePreset(named: "Studio")
    let id = store.presets[0].id
    let manager = UndoManager(); manager.groupsByEvent = false
    store.settings.fontSize = 80
    manager.beginUndoGrouping()
    let first = store.updatePreset(id, undoManager: manager)
    manager.endUndoGrouping()
    store.settings.fontSize = 120
    manager.beginUndoGrouping()
    let second = store.updatePreset(id, undoManager: manager)
    manager.endUndoGrouping()
    XCTAssertEqual(manager.undoActionName, "Replace Preset")
    XCTAssertFalse(store.undoPresetReplacement(first, manager: manager))
    XCTAssertEqual(store.presets[0].fontSize, 120)
    XCTAssertTrue(store.undoPresetReplacement(second, manager: manager))
    XCTAssertEqual(store.presets[0].fontSize, 80)
  }

}


extension AppearanceSnapshotTests {
  func testReplacementReceipt() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"]
    let defaults = freshDefaults("ReplacementReceiptSnapshot")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    await store.waitForInitialLoad()
    store.savePreset(named: "Studio")
    let preset = store.presets[0]
    let manager = UndoManager(); manager.groupsByEvent = false
    manager.beginUndoGrouping()
    let operationID = store.updatePreset(preset.id, undoManager: manager)
    manager.endUndoGrouping()
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] where requested == nil || requested == name {
      let receipt = PresetReplacementReceipt(store: store, preset: preset, operationID: operationID, manager: manager)
      try await snapshot(receipt.padding(), name: "replacement-receipt-current-\(name)", size: .init(width: 520, height: 120), scheme: scheme, destination: URL(fileURLWithPath: output))
    }
    manager.beginUndoGrouping(); store.applyPreset(preset, undoManager: manager); manager.endUndoGrouping()
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] where requested == nil || requested == name {
      let receipt = PresetReplacementReceipt(store: store, preset: preset, operationID: operationID, manager: manager)
      try await snapshot(receipt.padding(), name: "replacement-receipt-later-apply-\(name)", size: .init(width: 520, height: 120), scheme: scheme, destination: URL(fileURLWithPath: output))
    }
  }
}
