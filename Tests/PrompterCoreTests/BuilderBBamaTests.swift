import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBBamaTests: XCTestCase {
  private func fixture() async -> AppStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("BamaB")))
    await store.waitForInitialLoad()
    return store
  }

  func testMarkdownTransferPreservesContentsAndSanitisesFilename() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let record = ScriptRecord(metadata: .init(title: "../My:script" , fileName: "test.md"), markdown: "# Héllo\n\n**Read** this.\n")
    let file = try ScriptFile(script: record).export(in: folder)
    XCTAssertEqual(file.pathExtension, "md")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), record.markdown)
    XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent().path, folder.path)
    XCTAssertNotEqual(try ScriptFile(script: record).export(in: folder), file)
    var long = record
    long.metadata.title = String(repeating: "🎬", count: 120)
    XCTAssertLessThan(try ScriptFile(script: long).export(in: folder).lastPathComponent.utf8.count, 256)
  }

  func testSceneSelectionRestoresValidScriptAndScopeAndRejectsStaleIDs() async throws {
    let store = await fixture()
    let folder = try await store.createLibraryFolder(named: "Drafts")
    store.selectFolder(folder.id)
    let first = try await store.createScript(title: "First", markdown: "First")
    _ = try await store.createScript(title: "Second", markdown: "Second")
    let scene = LibrarySceneSelection(scriptID: first.id.uuidString, scope: folder.id.uuidString)
    store.selectFolder(nil)
    scene.restore(in: store)
    XCTAssertEqual(store.selectedFolderID, folder.id)
    XCTAssertEqual(store.selectedID, first.id)
    let library = try XCTUnwrap(store.library)
    let root = await library.rootURL
    let reopened = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: store.defaults))
    await reopened.waitForInitialLoad()
    scene.restore(in: reopened)
    XCTAssertEqual(reopened.selectedFolderID, folder.id)
    XCTAssertEqual(reopened.selectedID, first.id)
    LibrarySceneSelection(scriptID: UUID().uuidString, scope: UUID().uuidString).restore(in: store)
    XCTAssertNil(store.selectedFolderID)
    XCTAssertNotNil(store.selected)
  }

  func testRenameAndMixedFolderMoveUndoRedoIncludingImmediateUndo() async throws {
    let store = await fixture()
    let firstFolder = try await store.createLibraryFolder(named: "First")
    let secondFolder = try await store.createLibraryFolder(named: "Second")
    store.selectFolder(firstFolder.id)
    let first = try await store.createScript(title: "One", markdown: "One")
    store.selectFolder(nil)
    let second = try await store.createScript(title: "Two", markdown: "Two")
    let undo = UndoManager()
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    store.renameFolder(firstFolder.id, name: "Renamed", undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(undo.undoActionName, "Rename Folder")
    undo.undo()
    await store.libraryEditTask?.value
    XCTAssertEqual(store.folders.first { $0.id == firstFolder.id }?.name, "First")
    undo.redo()
    await store.libraryEditTask?.value
    XCTAssertEqual(store.folders.first { $0.id == firstFolder.id }?.name, "Renamed")
    undo.beginUndoGrouping()
    store.moveSelectedScripts([first.id, second.id], to: secondFolder.id, undoManager: undo)
    undo.endUndoGrouping()
    await store.libraryEditTask?.value
    XCTAssertEqual(undo.undoActionName, "Move to Folder")
    XCTAssertTrue(store.scripts.allSatisfy { $0.metadata.folderID == secondFolder.id })
    undo.undo()
    await store.libraryEditTask?.value
    XCTAssertEqual(store.scripts.first { $0.id == first.id }?.metadata.folderID, firstFolder.id)
    XCTAssertNil(store.scripts.first { $0.id == second.id }?.metadata.folderID)
    undo.redo()
    await store.libraryEditTask?.value
    XCTAssertTrue(store.scripts.allSatisfy { $0.metadata.folderID == secondFolder.id })
  }

  func testFolderRemovalCapturesMembershipAfterQueuedMoves() async throws {
    let store = await fixture()
    let folder = try await store.createLibraryFolder(named: "Drafts")
    store.selectFolder(folder.id)
    let movedOut = try await store.createScript(title: "Move out", markdown: "One")
    store.selectFolder(nil)
    let movedIn = try await store.createScript(title: "Move in", markdown: "Two")
    let undo = UndoManager()
    undo.groupsByEvent = false
    store.moveSelectedScripts([movedOut.id], to: nil)
    store.moveSelectedScripts([movedIn.id], to: folder.id)
    store.renameFolder(folder.id, name: "Ready")
    undo.beginUndoGrouping()
    store.deleteFolder(folder.id, undoManager: undo)
    undo.endUndoGrouping()
    _ = await store.flushPendingSaves()
    undo.undo()
    _ = await store.flushPendingSaves()
    XCTAssertEqual(store.folders.first { $0.id == folder.id }?.name, "Ready")
    XCTAssertNil(store.scripts.first { $0.id == movedOut.id }?.metadata.folderID)
    XCTAssertEqual(store.scripts.first { $0.id == movedIn.id }?.metadata.folderID, folder.id)
  }

  func testFailedRenameRemovesOnlyItsUndo() async throws {
    let store = await fixture()
    let folder = try await store.createLibraryFolder(named: "Original")
    let undo = UndoManager()
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    store.renameFolder(folder.id, name: "Valid", undoManager: undo)
    undo.endUndoGrouping()
    await store.libraryEditTask?.value
    undo.beginUndoGrouping()
    store.renameFolder(folder.id, name: "  ", undoManager: undo)
    undo.endUndoGrouping()
    await store.libraryEditTask?.value
    XCTAssertNotNil(store.errorMessage)
    undo.undo()
    await store.libraryEditTask?.value
    XCTAssertEqual(store.folders.first { $0.id == folder.id }?.name, "Original")
  }

  func testUnlinkUndoRestoresLinkWithoutWritingOriginal() async throws {
    let store = await fixture()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    defer { try? FileManager.default.removeItem(at: file) }
    try "Original\n".write(to: file, atomically: true, encoding: .utf8)
    let script = try await store.createScript(title: "Linked", markdown: "Original\n", linkTo: file)
    let undo = UndoManager()
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    store.unlink(script.id, undoManager: undo)
    undo.endUndoGrouping()
    await store.libraryEditTask?.value
    XCTAssertNil(store.scripts.first { $0.id == script.id }?.metadata.linkedPath)
    XCTAssertEqual(undo.undoActionName, "Unlink")
    undo.undo()
    await store.libraryEditTask?.value
    XCTAssertEqual(store.scripts.first { $0.id == script.id }?.metadata.linkedPath, script.metadata.linkedPath)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Original\n")
    undo.redo()
    await store.libraryEditTask?.value
    XCTAssertNil(store.scripts.first { $0.id == script.id }?.metadata.linkedPath)
  }

  func testRestoreOffersUndoAndRedo() async throws {
    let store = await fixture()
    let record = try await store.createScript(title: "Restore", markdown: "Keep me")
    try await store.deleteScript(record.id)
    let undo = UndoManager()
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    store.restore(record.id, undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertEqual(undo.undoActionName, "Restore Script")
    for _ in 0..<100 where !store.scripts.contains(where: { $0.id == record.id }) { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(store.selected?.markdown, "Keep me")
    undo.undo()
    for _ in 0..<100 where store.scripts.contains(where: { $0.id == record.id }) { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(store.trash.contains { $0.id == record.id })
    undo.redo()
    for _ in 0..<100 where !store.scripts.contains(where: { $0.id == record.id }) { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(store.selected?.markdown, "Keep me")
  }

  func testTipDismissalSurvivesViewRecreationAndGuideRestoresIt() async throws {
    let store = await fixture()
    _ = try await store.createScript(title: "Words", markdown: "Read these words")
    let camera = CameraModel(defaults: store.defaults)
    var (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1440, height: 1000))
    let dismiss = try XCTUnwrap(LibraryAX.named("Got it", in: host).first)
    XCTAssertTrue(LibraryAX.bool(dismiss, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(store.defaults.bool(forKey: "readingTipHidden"))
    LibraryAX.close(window)
    (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1440, height: 1000))
    defer { LibraryAX.close(window) }
    XCTAssertTrue(LibraryAX.named("Got it", in: host).isEmpty)
    store.showWelcomeScript()
    XCTAssertFalse(store.defaults.bool(forKey: "readingTipHidden"))
  }

  func testReadingFadeLeavesScrollGeometryUnchanged() throws {
    for flipped in [false, true] {
      let renderer = ImageRenderer(content: Color.white.frame(width: 100, height: 200)
        .mask { ReadingViewportMask(flipped: flipped) })
      let image = try XCTUnwrap(renderer.cgImage)
      let bitmap = NSBitmapImageRep(cgImage: image)
      XCTAssertEqual(bitmap.pixelsHigh, 200)
      let top = try XCTUnwrap(bitmap.colorAt(x: 50, y: 0)).alphaComponent
      let bottom = try XCTUnwrap(bitmap.colorAt(x: 50, y: 199)).alphaComponent
      XCTAssertGreaterThan(flipped ? bottom : top, 0.99)
      XCTAssertLessThan(flipped ? top : bottom, 0.03)
      let solid = try XCTUnwrap(bitmap.colorAt(x: 50, y: flipped ? 48 : 151)).alphaComponent
      XCTAssertGreaterThan(solid, 0.99)
    }
  }

  func testContrastTokenProducesOpaqueWhiteWhenIncreased() throws {
    for (contrast, expected) in [(ColorSchemeContrast.standard, 0.8), (.increased, 1.0)] {
      let renderer = ImageRenderer(content: Rectangle().fill(Palette.onDarkQuiet(contrast)).frame(width: 8, height: 8))
      let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
      XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)).alphaComponent, expected, accuracy: 0.01)
    }
  }

  func testToolbarHelpNamesActionsAndShortcuts() async throws {
    let store = await fixture()
    let (window, host) = await LibraryAX.host(HStack { LibraryPresenterActions(store: store) })
    defer { LibraryAX.close(window) }
    for (label, help) in [("Present", "Open the presenter with this script (⌥⌘P)"),
                          ("Camera Only", Features.recording ? "Check framing or record without a script (⌥⌘C)" : "Check framing without a script (⌥⌘C)"),
                          ("Recordings", "Show the Recordings folder in Finder")] {
      if label == "Recordings" && !Features.recording { continue }
      XCTAssertEqual(LibraryAX.value(try XCTUnwrap(LibraryAX.named(label, in: host).first), "accessibilityHelp"), help)
    }
  }
}
