import AppKit
import SwiftUI
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor final class SettingsUndoTests: XCTestCase {
  func testNewScriptAndWindowShortcutsDoNotClash() {
    XCTAssertEqual(ScriptShortcuts.newScript.key, KeyEquivalent("n"))
    XCTAssertEqual(ScriptShortcuts.newScript.modifiers, .command)
    XCTAssertEqual(ScriptShortcuts.library.modifiers, [.command, .shift])
    XCTAssertEqual(ScriptShortcuts.camera.modifiers, [.command, .shift])
    XCTAssertEqual(ScriptShortcuts.biggerText.key, KeyEquivalent(">"))
    XCTAssertEqual(ScriptShortcuts.biggerText.modifiers, .command)
    XCTAssertEqual(ScriptShortcuts.smallerText.key, KeyEquivalent("<"))
    XCTAssertEqual(ScriptShortcuts.smallerText.modifiers, .command)
    XCTAssertEqual(SettingsTab.allCases.map(\.rawValue), ["General", "Voice", "Editor", "Presets"])
  }

  func testPresetDeletionSupportsRepeatedUndoAndRedoWithoutLosingOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("preset-undo-\(UUID())")
    let suite = "PresetUndo.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    addTeardownBlock { @MainActor in
      await store.flushSettings()
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    store.savePreset(named: "One"); store.savePreset(named: "Two"); store.savePreset(named: "Three")
    let originals = store.presets
    let manager = UndoManager()
    manager.groupsByEvent = false
    manager.beginUndoGrouping()
    store.deletePreset(originals[1].id, undoManager: manager)
    manager.endUndoGrouping()
    XCTAssertEqual(store.presets.map(\.name), ["One", "Three"])
    for _ in 0..<2 {
      manager.undo()
      XCTAssertEqual(store.presets, originals)
      XCTAssertTrue(manager.canRedo)
      manager.redo()
      XCTAssertEqual(store.presets.map(\.name), ["One", "Three"])
      XCTAssertTrue(manager.canUndo)
    }
    manager.undo()
    _ = await store.flushPendingSaves()
    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(reopened.presets, originals)
    _ = await reopened.flushPendingSaves()
  }

  func testFolderDeletionRestoresIdentityAndMembershipAcrossUndoRedo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-undo-\(UUID())")
    let suite = "FolderUndo.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    addTeardownBlock { @MainActor in
      await store.flushSettings()
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let library = try XCTUnwrap(store.library)
    let folder = try await library.createFolder(name: "Recordings")
    let other = try await library.createFolder(name: "Other")
    let script = try await library.create(title: "Speech", markdown: "These words must survive.", folderID: folder.id)
    let moved = try await library.create(title: "Moved later", markdown: "Keep my new folder.", folderID: folder.id)
    let trashed = try await library.create(title: "Trashed", markdown: "Keep in trash.", folderID: folder.id)
    try await library.delete(trashed.id)
    await store.reload()
    let originalFolderOrder = store.folders.map(\.id)
    let manager = UndoManager()
    manager.groupsByEvent = false
    // Async disk success registers the first undo in its own explicit event group.
    manager.groupsByEvent = true
    store.deleteFolder(folder.id, undoManager: manager)
    for _ in 0..<100 where store.folders.contains(where: { $0.id == folder.id }) { try await Task.sleep(for: .milliseconds(10)) }
    try await store.moveScripts([moved.id], to: other.id)
    for _ in 0..<2 {
      XCTAssertTrue(manager.canUndo)
      manager.undo()
      for _ in 0..<100 where !store.folders.contains(where: { $0.id == folder.id }) { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertEqual(store.folders.first(where: { $0.id == folder.id })?.name, folder.name)
      XCTAssertEqual(store.folders.map(\.id), originalFolderOrder, "Undo preserves alphabetical folder order")
      XCTAssertEqual(store.scripts.first(where: { $0.id == script.id })?.metadata.folderID, folder.id)
      XCTAssertEqual(store.scripts.first(where: { $0.id == moved.id })?.metadata.folderID, other.id)
      XCTAssertEqual(store.trash.first(where: { $0.id == trashed.id })?.metadata.folderID, folder.id)
      XCTAssertTrue(manager.canRedo)
      manager.redo()
      for _ in 0..<100 where store.folders.contains(where: { $0.id == folder.id }) { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertNil(store.scripts.first(where: { $0.id == script.id })?.metadata.folderID)
    }
    // Rapid commands remain ordered on disk as well as in memory.
    manager.undo(); manager.redo(); manager.undo()
    for _ in 0..<100 where !store.folders.contains(where: { $0.id == folder.id }) { try await Task.sleep(for: .milliseconds(10)) }
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed, "quit waits for the complete Undo/Redo folder queue")
    let reopened = try MarkdownLibrary(rootURL: root)
    let saved = try await reopened.read(script.id)
    XCTAssertEqual(saved.markdown, script.markdown)
    XCTAssertEqual(saved.metadata.folderID, folder.id)
  }

  func testFolderRestoreFailureRollsBackTheInMemoryIndex() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-restore-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let folder = try await library.createFolder(name: "Original")
    let script = try await library.create(title: "Keep", markdown: "Keep these words.", folderID: folder.id)
    try await library.deleteFolder(folder.id)
    let index = root.appendingPathComponent("LibraryIndex.json")
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
    do {
      try await library.restoreFolder(folder, scriptIDs: [script.id])
      XCTFail("A directory in place of the index must fail safely")
    } catch {}
    let folders = await library.listFolders()
    let saved = try await library.read(script.id)
    XCTAssertTrue(folders.isEmpty)
    XCTAssertNil(saved.metadata.folderID)
    XCTAssertEqual(saved.markdown, script.markdown)
  }

}
