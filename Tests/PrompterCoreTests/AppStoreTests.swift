import XCTest
@testable import JuniorPrompter
import PrompterCore

@MainActor
final class AppStoreTests: XCTestCase {
  func testFlushPendingSavePersistsImmediateEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.library!.create(title: "Draft", markdown: "first")
    await store.reload()
    let id = try XCTUnwrap(store.selectedID)
    store.updateMarkdown("latest", for: id)
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    let saved = try await store.library!.read(id)
    XCTAssertEqual(saved.markdown, "latest")
  }

  func testFlushPendingSaveUsesLatestOfRapidEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.library!.create(title: "Draft", markdown: "first")
    await store.reload()
    let id = try XCTUnwrap(store.selectedID)
    store.updateMarkdown("second", for: id)
    store.updateMarkdown("final", for: id)
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    let saved = try await store.library!.read(id)
    XCTAssertEqual(saved.markdown, "final")
  }

  func testFailedSaveBlocksQuitUntilFixtureIsRepairedAndRetried() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.library!.create(title: "Draft", markdown: "first")
    await store.reload()
    let record = try XCTUnwrap(store.selected)
    let script = root.appendingPathComponent("Scripts").appendingPathComponent(record.metadata.fileName)
    let backup = script.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: script, to: backup)
    try FileManager.default.createDirectory(at: script, withIntermediateDirectories: false)
    store.updateMarkdown("recovered draft", for: record.id)
    let failed = await store.flushPendingSaves()
    XCTAssertFalse(failed)
    store.errorMessage = nil
    let stillFailed = await store.flushPendingSaves()
    XCTAssertFalse(stillFailed)
    try FileManager.default.removeItem(at: script)
    try FileManager.default.moveItem(at: backup, to: script)
    await store.retryFailedSaves()
    let recovered = await store.flushPendingSaves()
    XCTAssertTrue(recovered)
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "recovered draft")
    try? FileManager.default.removeItem(at: root)
  }

  func testImmediateEditThenDeleteRestoresLatestDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.library!.create(title: "Draft", markdown: "first")
    await store.reload()
    let record = try XCTUnwrap(store.selected)
    store.updateMarkdown("latest before delete", for: record.id)
    store.delete([record.id])
    try await Task.sleep(for: .milliseconds(700))
    let trash = await store.library!.listTrash()
    XCTAssertEqual(trash.count, 1)
    _ = try await store.library!.restore(record.id)
    let restored = try await store.library!.read(record.id)
    XCTAssertEqual(restored.markdown, "latest before delete")
  }

  func testFailedSaveSurvivesExternalRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.library!.create(title: "Draft", markdown: "first")
    await store.reload()
    let record = try XCTUnwrap(store.selected)
    let script = root.appendingPathComponent("Scripts").appendingPathComponent(record.metadata.fileName)
    let backup = script.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: script, to: backup)
    try FileManager.default.createDirectory(at: script, withIntermediateDirectories: false)
    store.updateMarkdown("keep this draft", for: record.id)
    let failed = await store.flushPendingSaves()
    XCTAssertFalse(failed)
    try FileManager.default.removeItem(at: script)
    try FileManager.default.moveItem(at: backup, to: script)
    try Data("external edit".utf8).write(to: script)
    await store.refreshExternalChanges()
    XCTAssertEqual(store.selected?.markdown, "keep this draft")
    try? FileManager.default.removeItem(at: root)
  }

  func testFolderFilterAndDeletionPreserveScript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let folder = try await library.createFolder(name: "Work")
    let record = try await library.create(title: "Draft", markdown: "keep", folderID: folder.id)
    let before = try Data(contentsOf: try await library.scriptURL(for: record.id))
    try await library.deleteFolder(folder.id)
    let after = try Data(contentsOf: try await library.scriptURL(for: record.id))
    XCTAssertEqual(before, after)
    let restored = try await library.read(record.id)
    XCTAssertNil(restored.metadata.folderID)
  }

  func testSchemaOneMigrationBacksUpAndReopensAsSchemaTwo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let index = root.appendingPathComponent("LibraryIndex.json")
    try Data("{\"schemaVersion\":1,\"scripts\":[],\"trash\":[]}".utf8).write(to: index)
    _ = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertTrue(files.contains { $0.hasPrefix("LibraryIndex.schema1-") })
    let migrated = try Data(contentsOf: index)
    XCTAssertEqual((try JSONSerialization.jsonObject(with: migrated) as? [String: Any])?["schemaVersion"] as? Int, 2)
    _ = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
  }

  func testFolderSelectionFiltersAndNewScriptInheritsFolder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let folder = try await store.library!.createFolder(name: "Work")
    _ = try await store.library!.create(title: "Existing", markdown: "one", folderID: folder.id)
    await store.reload()
    store.selectFolder(folder.id)
    XCTAssertEqual(store.visible.count, 1)
    XCTAssertEqual(store.selectedID, store.visible.first?.id)
    store.selectFolder(UUID())
    XCTAssertNil(store.selectedID)
    store.selectFolder(folder.id)
    store.create(title: "New", markdown: "two")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(store.visible.contains { $0.metadata.title == "New" })
    store.moveSelectedScripts(Set(store.visible.map(\.id)), to: nil)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(store.selectedID)
  }

  func testRefreshDiscoversExternalMarkdownAndPreservesPendingDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let created = try await store.library!.create(title: "Draft", markdown: "original")
    await store.reload()
    store.updateMarkdown("unsaved local", for: created.id)
    let external = root.appendingPathComponent("Scripts", isDirectory: true)
      .appendingPathComponent("external.md")
    try Data("external script".utf8).write(to: external)

    await store.refreshExternalChanges()
    XCTAssertTrue(store.scripts.contains { $0.metadata.fileName == "external.md" })
    XCTAssertEqual(store.scripts.first { $0.id == created.id }?.markdown, "unsaved local")
    await store.refreshExternalChanges()
    XCTAssertEqual(store.scripts.filter { $0.metadata.fileName == "external.md" }.count, 1)
  }

  func testPresetLifecyclePreservesIdentityAndSettings() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)"))
    store.savePreset(named: "Camera")
    let original = store.presets[0]
    store.settings.fontSize = 72
    store.updatePreset(original.id)
    XCTAssertEqual(store.presets[0].id, original.id)
    XCTAssertEqual(store.presets[0].fontSize, 72)
    store.duplicatePreset(original.id)
    XCTAssertEqual(store.presets.count, 2)
    XCTAssertNotEqual(store.presets[1].id, original.id)
    store.renamePreset(original.id, name: "Renamed")
    XCTAssertEqual(store.presets[0].name, "Renamed")
    store.settings.audioDeviceUID = "selected-zoom-input"
    store.settings.speechLanguage = "French"
    store.applyPreset(store.presets[0])
    XCTAssertEqual(store.settings.fontSize, 72)
    XCTAssertEqual(store.settings.audioDeviceUID, "selected-zoom-input")
    XCTAssertEqual(store.settings.speechLanguage, "French")
    store.deletePreset(store.presets[1].id)
    XCTAssertEqual(store.presets.count, 1)
  }

  func testSettingsAndMultiplePresetsSurviveNewStoreInstance() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let first = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(first.sourceFontName, "System Serif")
    first.settings.fontSize = 83
    first.savePreset(named: "Camera")
    first.settings.fontSize = 27
    first.savePreset(named: "Desk")
    let expected = first.presets
    first.settings.fontSize = 83

    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(reopened.settings.fontSize, 83)
    XCTAssertEqual(reopened.presets, expected)
    let reopenedAgain = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(reopenedAgain.presets, expected)
  }

  func testEditorTypographyPersistsIndependentlyOfPresenterSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let first = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await first.library!.create(title: "Typography", markdown: "# Bonjour\n\n*accent*")
    let before = try Data(contentsOf: try await first.library!.scriptURL(for: record.id))
    first.sourceFontName = "Georgia"
    first.sourceFontSize = 22
    first.previewFontName = "Monospaced"
    first.previewFontSize = 31
    first.settings.fontSize = 67

    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await reopened.reload()
    XCTAssertEqual(reopened.sourceFontName, "Georgia")
    XCTAssertEqual(reopened.sourceFontSize, 22)
    XCTAssertEqual(reopened.previewFontName, "Monospaced")
    XCTAssertEqual(reopened.previewFontSize, 31)
    XCTAssertEqual(reopened.settings.fontSize, 67)
    let reopenedURL = try await reopened.library!.scriptURL(for: record.id)
    XCTAssertEqual(try Data(contentsOf: reopenedURL), before)
  }

  func testDataDirectoryDefaultsAreIsolated() async throws {
    let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = AppStore(arguments: ["test", "--data-directory", first.path])
    a.settings.fontSize = 91
    let b = AppStore(arguments: ["test", "--data-directory", second.path])
    XCTAssertNotEqual(b.settings.fontSize, 91)
    let reopened = AppStore(arguments: ["test", "--data-directory", first.path])
    XCTAssertEqual(reopened.settings.fontSize, 91)
    let injected = UserDefaults(suiteName: "JuniorPrompterTests.injected.\(UUID().uuidString)")!
    let explicit = AppStore(arguments: ["test", "--data-directory", second.path], defaults: injected)
    explicit.settings.fontSize = 37
    let explicitReopened = AppStore(arguments: ["test", "--data-directory", second.path], defaults: injected)
    XCTAssertEqual(explicitReopened.settings.fontSize, 37)
  }

  func testScriptsTrackedCountsCreatedAndDuplicatedScripts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.library!.create(title: "Existing", markdown: "one")
    await store.reload()
    XCTAssertEqual(store.scriptsTracked, 1)

    store.create(title: "Created", markdown: "two")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(store.scriptsTracked, 2)
    store.duplicate()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(store.scriptsTracked, 3)
    let duplicatedID = try XCTUnwrap(store.selectedID)
    store.delete([duplicatedID])
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(store.scriptsTracked, 3)
    store.restore(duplicatedID)
    try await Task.sleep(for: .milliseconds(100))
    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await reopened.reload()
    XCTAssertEqual(reopened.scriptsTracked, 3)
  }

  func testExternalConflictCanKeepExternalAndLocalDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Draft", markdown: "original")
    await store.reload()
    store.updateMarkdown("local draft", for: record.id)
    let url = try await store.library!.scriptURL(for: record.id)
    try Data("external edit".utf8).write(to: url)
    let failed = await store.flushPendingSaves()
    XCTAssertFalse(failed)
    await store.keepBothFailedSaves()
    XCTAssertFalse(store.hasFailedSaves)
    XCTAssertEqual(store.scripts.count, 2)
    XCTAssertEqual(store.selected?.markdown, "local draft")
    XCTAssertEqual(store.selected?.metadata.title, "Draft (Local Draft)")
    let original = try await store.library!.read(record.id)
    XCTAssertEqual(original.markdown, "external edit")
    XCTAssertEqual(store.scripts.first(where: { $0.id == record.id })?.markdown, "external edit")
    store.updateMarkdown("continued external draft", for: record.id)
    let recovered = await store.flushPendingSaves()
    XCTAssertTrue(recovered)
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "continued external draft")
  }

  func testExternalEditRetainsActiveAnchorAndPausesSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Reading", markdown: "one two three four")
    await store.reload()
    var settings = PrompterSettings(); settings.mode = "Timed"
    store.session.present(record: record, settings: settings)
    store.session.seek(to: 1)
    store.session.play()
    let url = try await store.library!.scriptURL(for: record.id)
    try Data("prefix one two changed three four".utf8).write(to: url)
    await store.refreshExternalChanges()
    XCTAssertEqual(store.session.state, .paused)
    XCTAssertEqual(store.session.activeToken?.text, "two")
    XCTAssertEqual(store.selected?.markdown, "prefix one two changed three four")
  }

  func testMissingExternalFilePreservesDraftAndRecoversWhenRestored() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Missing", markdown: "keep me")
    await store.reload()
    let url = try await store.library!.scriptURL(for: record.id)
    let original = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    await store.refreshExternalChanges()
    XCTAssertTrue(store.unavailableScriptIDs.contains(record.id))
    XCTAssertEqual(store.selected?.markdown, "keep me")
    XCTAssertNotNil(store.errorMessage)
    store.errorMessage = nil
    await store.refreshExternalChanges()
    XCTAssertNil(store.errorMessage)
    try original.write(to: url)
    await store.refreshExternalChanges()
    XCTAssertFalse(store.unavailableScriptIDs.contains(record.id))
    XCTAssertEqual(store.selected?.markdown, "keep me")
  }

  func testColdReloadKeepsOtherScriptsWhenOneFileIsMissing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let missing = try await library.create(title: "Missing", markdown: "gone")
    _ = try await library.create(title: "Valid", markdown: "still here")
    try FileManager.default.removeItem(at: try await library.scriptURL(for: missing.id))
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await store.reload()
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(store.scripts.first?.markdown, "still here")
    XCTAssertTrue(store.unavailableScriptIDs.contains(missing.id))
    let url = try await library.scriptURL(for: missing.id)
    try Data("gone".utf8).write(to: url)
    await store.refreshExternalChanges()
    XCTAssertEqual(store.scripts.count, 2)
    XCTAssertFalse(store.unavailableScriptIDs.contains(missing.id))
    store.updateMarkdown("pending local edit", for: missing.id)
    await store.reload()
    XCTAssertEqual(store.scripts.first(where: { $0.id == missing.id })?.markdown, "pending local edit")
    let saved = await store.flushPendingSaves()
    XCTAssertTrue(saved)
  }
}
