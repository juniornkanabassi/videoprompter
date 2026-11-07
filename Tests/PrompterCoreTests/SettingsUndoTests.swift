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
    XCTAssertEqual(ScriptShortcuts.camera.modifiers, [.command, .control])
    XCTAssertEqual(ScriptShortcuts.biggerText.key, KeyEquivalent(">"))
    XCTAssertEqual(ScriptShortcuts.biggerText.modifiers, .command)
    XCTAssertEqual(ScriptShortcuts.smallerText.key, KeyEquivalent("<"))
    XCTAssertEqual(ScriptShortcuts.smallerText.modifiers, .command)
    let shortcuts = [ScriptShortcuts.newScript, ScriptShortcuts.library, ScriptShortcuts.camera,
                     ScriptShortcuts.importFile, ScriptShortcuts.italic,
                     ScriptShortcuts.biggerText, ScriptShortcuts.smallerText]
    let reserved = [KeyboardShortcut("c", modifiers: [.command, .shift]),
                    KeyboardShortcut("c", modifiers: [.command, .option]),
                    KeyboardShortcut("+", modifiers: .command),
                    KeyboardShortcut("-", modifiers: .command)]
    for (index, shortcut) in shortcuts.enumerated() {
      for other in Array(shortcuts.dropFirst(index + 1)) + reserved {
        XCTAssertFalse(shortcut.key == other.key && shortcut.modifiers == other.modifiers,
                       "Script commands must not collide with each other, Show Colors, Camera Only or interface zoom")
      }
    }
    XCTAssertEqual(SettingsTab.allCases.map(\.rawValue), ["General", "Reading", "Reading presets", "Shoot setups", "Microphone", "Camera & Recording"])
  }

  func testPresetDeletionSupportsRepeatedUndoAndRedoWithoutLosingOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("preset-undo-\(UUID())")
    let suite = "PresetUndo.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    addTeardownBlock { @MainActor in
      await store.flushSettings()
      TestDefaults.remove(suite)
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
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    addTeardownBlock { @MainActor in
      await store.flushSettings()
      TestDefaults.remove(suite)
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
    manager.groupsByEvent = true
    store.deleteFolder(folder.id, undoManager: manager)
    await store.libraryEditTask?.value
    try await store.moveScripts([moved.id], to: other.id)
    for _ in 0..<2 {
      XCTAssertTrue(manager.canUndo)
      manager.undo()
      await store.libraryEditTask?.value
      XCTAssertEqual(store.folders.first(where: { $0.id == folder.id })?.name, folder.name)
      XCTAssertEqual(store.folders.map(\.id), originalFolderOrder, "Undo preserves alphabetical folder order")
      XCTAssertEqual(store.scripts.first(where: { $0.id == script.id })?.metadata.folderID, folder.id)
      XCTAssertEqual(store.scripts.first(where: { $0.id == moved.id })?.metadata.folderID, other.id)
      XCTAssertEqual(store.trash.first(where: { $0.id == trashed.id })?.metadata.folderID, folder.id)
      XCTAssertTrue(manager.canRedo)
      manager.redo()
      await store.libraryEditTask?.value
      XCTAssertNil(store.scripts.first(where: { $0.id == script.id })?.metadata.folderID)
    }
    // Rapid commands remain ordered on disk as well as in memory.
    manager.undo(); manager.redo(); manager.undo()
    await store.libraryEditTask?.value
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


  /// Undo is registered before the disk work, so it is offered at once and keeps its place when
  /// another undoable action follows before the library has finished.
  func testFolderDeletionIsUndoableAtOnceAndStaysInOrderWithLaterActions() async throws {
    let (store, folder, script) = try await folderFixture("folder-undo-order")
    store.savePreset(named: "Keep")
    let manager = UndoManager()
    manager.groupsByEvent = false
    manager.beginUndoGrouping(); store.deleteFolder(folder.id, undoManager: manager); manager.endUndoGrouping()
    XCTAssertTrue(manager.canUndo, "offered before the disk change completes")
    XCTAssertEqual(manager.undoActionName, "Remove Folder")
    manager.beginUndoGrouping(); store.deletePreset(store.presets[0].id, undoManager: manager); manager.endUndoGrouping()
    XCTAssertEqual(manager.undoActionName, "Delete Preset", "the later action is undone first")
    manager.undo()
    XCTAssertEqual(store.presets.map(\.name), ["Keep"])
    XCTAssertEqual(manager.undoActionName, "Remove Folder")
    manager.undo()
    XCTAssertFalse(manager.canUndo)
    XCTAssertEqual(manager.redoActionName, "Remove Folder")
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    XCTAssertEqual(store.folders.map(\.id), [folder.id])
    XCTAssertEqual(store.scripts.first(where: { $0.id == script.id })?.metadata.folderID, folder.id)
    XCTAssertNil(store.errorMessage)
    manager.redo()
    _ = await store.flushPendingSaves()
    XCTAssertTrue(store.folders.isEmpty)
    XCTAssertNil(store.scripts.first(where: { $0.id == script.id })?.metadata.folderID)
    XCTAssertEqual(manager.undoActionName, "Remove Folder")
  }

  func testFailedFolderDeletionDropsOnlyItsOwnQueuedUndoAndRedo() async throws {
    let (store, folder, script) = try await folderFixture("folder-undo-failure")
    store.savePreset(named: "Keep")
    let manager = UndoManager()
    manager.groupsByEvent = false
    manager.beginUndoGrouping()
    store.deletePreset(store.presets[0].id, undoManager: manager)
    manager.endUndoGrouping()

    let library = try XCTUnwrap(store.library)
    let index = await library.rootURL.appendingPathComponent("LibraryIndex.json")
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
    manager.beginUndoGrouping()
    store.deleteFolder(folder.id, undoManager: manager)
    manager.endUndoGrouping()
    manager.undo()
    manager.redo()
    _ = await store.flushPendingSaves()

    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(store.folders.map(\.id), [folder.id])
    XCTAssertEqual(store.scripts.first(where: { $0.id == script.id })?.metadata.folderID, folder.id)
    XCTAssertEqual(manager.undoActionName, "Delete Preset", "failed folder entries leave unrelated undo intact")
    XCTAssertFalse(manager.canRedo)
    manager.undo()
    XCTAssertEqual(store.presets.map(\.name), ["Keep"])
    XCTAssertFalse(manager.canUndo)
    let saved = try await library.read(script.id)
    XCTAssertEqual(saved.markdown, script.markdown)
    XCTAssertEqual(saved.metadata.folderID, folder.id)
  }

  /// Undo entries must not hold the UndoManager they live in, or a closed window's manager leaks.
  func testUndoEntriesDoNotKeepTheirUndoManagerAlive() async throws {
    let (store, folder, _) = try await folderFixture("undo-release")
    store.savePreset(named: "One")
    weak var released: UndoManager?
    do {
      let manager = UndoManager()
      manager.groupsByEvent = false
      manager.beginUndoGrouping(); store.deletePreset(store.presets[0].id, undoManager: manager); manager.endUndoGrouping()
      manager.undo(); manager.redo()
      manager.beginUndoGrouping(); store.deleteFolder(folder.id, undoManager: manager); manager.endUndoGrouping()
      manager.undo(); manager.redo()
      _ = await store.flushPendingSaves()
      XCTAssertTrue(manager.canUndo)
      XCTAssertEqual(manager.undoActionName, "Remove Folder")
      released = manager
    }
    for _ in 0..<50 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(released, "the store outlives the manager without keeping it alive")
    XCTAssertTrue(store.presets.isEmpty)
  }

  private func folderFixture(_ name: String) async throws -> (AppStore, ScriptFolder, ScriptRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
    let suite = "\(name).\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    addTeardownBlock { @MainActor in
      _ = await store.flushPendingSaves()
      TestDefaults.remove(suite)
      try? FileManager.default.removeItem(at: root)
    }
    let library = try XCTUnwrap(store.library)
    let folder = try await library.createFolder(name: "Recordings")
    let script = try await library.create(title: "Speech", markdown: "These words must survive.", folderID: folder.id)
    await store.reload()
    return (store, folder, script)
  }

}
