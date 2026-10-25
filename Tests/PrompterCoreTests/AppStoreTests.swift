import XCTest
@testable import VideoPrompter
import PrompterCore

private actor PresenterSaveGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }
  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

@MainActor
final class AppStoreTests: XCTestCase {
  func testMetadataActionUpdatesMemoryAndDiskAndThrowsWithoutChangingMemory() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpm-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "AppStoreTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.createScript(title: "Read", markdown: "one two")
    try await store.updateScriptMetadata(record.id, title: "Renamed", tags: [" draft ", "ready", "draft"])
    let updated = try XCTUnwrap(store.scripts.first)
    XCTAssertEqual(updated.metadata.title, "Renamed")
    XCTAssertEqual(updated.metadata.tags, ["draft", "ready"])
    await store.reload()
    XCTAssertEqual(store.scripts.first?.metadata, updated.metadata)
    do {
      try await store.updateScriptMetadata(record.id, title: " ")
      XCTFail("An empty title should be rejected")
    } catch {}
    XCTAssertEqual(store.scripts.first?.metadata, updated.metadata)
  }

  func testDuplicateFlushesDraftAndKeepsTheInvokedScriptWhenSelectionChanges() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let first = try await store.library!.create(title: "First", markdown: "old")
    let second = try await store.library!.create(title: "Second", markdown: "other")
    await store.reload()
    store.selectedID = first.id
    store.updateMarkdown("new draft", for: first.id)
    store.duplicate()
    store.selectedID = second.id
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    for _ in 0..<100 where store.scripts.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
    let copy = try XCTUnwrap(store.scripts.first { $0.metadata.title == "First copy" })
    XCTAssertEqual(copy.markdown, "new draft")
  }

  func testDuplicateAbortsWhenPendingDraftCannotSave() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let first = try await store.library!.create(title: "First", markdown: "old")
    await store.reload()
    store.selectedID = first.id
    let script = try await store.library!.scriptURL(for: first.id)
    try "external conflict".write(to: script, atomically: true, encoding: .utf8)
    store.updateMarkdown("new draft", for: first.id)
    store.duplicate()
    let flushed = await store.flushPendingSaves()
    XCTAssertFalse(flushed)
    for _ in 0..<100 where store.errorMessage != "Save the pending edits before duplicating scripts." { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(store.errorMessage, "Save the pending edits before duplicating scripts.")
    XCTAssertEqual(store.scripts.count, 1)
    XCTAssertEqual(store.selectedID, first.id)
    XCTAssertEqual(store.selected?.markdown, "new draft")
  }

  func testAutosaveAcknowledgementDoesNotPauseResumedPresenter() async throws {
    for mode in ["Manual", "Voice"] {
      let (store, root, outside) = makeStore()
      defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
      let record = try await store.library!.create(title: "Read", markdown: "one two three four five six")
      await store.reload()
      var settings = PrompterSettings()
      settings.mode = mode
      store.session.present(record: record, settings: settings)
      store.session.seek(to: 2)
      store.updateMarkdown("one two three four five six seven", for: record.id)
      store.session.play(captureAudio: false)
      let anchor = store.session.anchor
      let blocks = store.session.document.blocks.map(\.id)
      let frontier = store.session.lastConfirmedTokenIndex
      let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
      XCTAssertEqual(store.session.state, .running, mode)
      XCTAssertEqual(store.session.anchor?.blockID, anchor?.blockID)
      XCTAssertEqual(store.session.anchor?.tokenOffset, anchor?.tokenOffset)
      XCTAssertEqual(store.session.document.blocks.map(\.id), blocks)
      XCTAssertEqual(store.session.lastConfirmedTokenIndex, frontier)
      XCTAssertEqual(store.session.anchor?.revision, store.selected?.metadata.revision)
      store.session.pause()
    }
  }

  /// The whole point of linking: the file changes in MarkEdit or Obsidian, the script
  /// follows it live, and the reader stays on the passage they were reading.
  func testLinkedFileChangeUpdatesTheScriptAndKeepsTheAnchor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VideoPrompter-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let markdown = "Opening lines of the script.\n\nSecond passage holds the target word here."
    let file = outside.appendingPathComponent("script.md")
    try Data(markdown.utf8).write(to: file)
    let record = try await store.library!.create(title: "Linked", markdown: markdown)
    _ = try await store.library!.link(record.id, to: file)
    await store.reload()
    let presented = try XCTUnwrap(store.scripts.first { $0.id == record.id })
    XCTAssertEqual(presented.metadata.linkedPath, file.standardizedFileURL.path)
    store.session.present(record: presented, settings: PrompterSettings())
    let target = try XCTUnwrap(store.session.document.spokenTokens.firstIndex { $0.normalised == "target" })
    store.session.seek(to: target)

    try Data("Rewritten opening entirely.\n\nSecond passage holds the target word here.".utf8)
      .write(to: file, options: .atomic)
    await store.refreshExternalChanges()

    XCTAssertEqual(
      store.scripts.first { $0.id == record.id }?.markdown,
      "Rewritten opening entirely.\n\nSecond passage holds the target word here.")
    XCTAssertEqual(store.session.activeToken?.normalised, "target")
    XCTAssertNil(store.session.anchorNotice)
    XCTAssertNil(store.errorMessage)
  }

  /// What the Import button actually does: create the script from the preview and link the
  /// file it came from, in one step, so later edits in MarkEdit reach the script.
  func testImportingAMarkdownFileCreatesALinkedScript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VideoPrompter-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let file = outside.appendingPathComponent("Imported notes.md")
    try Data("Imported body.".utf8).write(to: file)

    store.create(title: "Imported notes", markdown: "Imported body.", linkTo: file)
    try await Task.sleep(for: .milliseconds(200))
    let created = try XCTUnwrap(store.scripts.first { $0.metadata.title == "Imported notes" })
    XCTAssertEqual(created.markdown, "Imported body.")
    XCTAssertEqual(created.metadata.linkedPath, file.standardizedFileURL.path)
    XCTAssertNil(store.errorMessage)

    // The point of the link: an edit made elsewhere reaches the script.
    try Data("Edited in MarkEdit.".utf8).write(to: file)
    await store.refreshExternalChanges()
    XCTAssertEqual(store.scripts.first { $0.id == created.id }?.markdown, "Edited in MarkEdit.")

    // And an in-app edit reaches the file.
    store.updateMarkdown("Edited in the app.", for: created.id)
    _ = await store.flushPendingSaves()
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Edited in the app.")
    XCTAssertNil(store.errorMessage)
  }

  /// Edits typed right as the previous save runs: every save must read the fingerprint the one
  /// before it left, keep its revision metadata, and end with no conflict and the newest text.
  func testOverlappingEditsSaveInOrderWithoutConflict() async throws {
    let (store, root, _) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try await store.library!.create(title: "Race", markdown: "v0")
    await store.reload()
    // Hold the first save after it has resolved its fingerprint, type the next value, release.
    let gate = PresenterSaveGate()
    var held = false
    store.saveGate = {
      guard !held else { return }
      held = true
      await gate.wait()
    }
    store.updateMarkdown("v1", for: record.id)
    await gate.waitUntilEntered()
    store.updateMarkdown("v2", for: record.id)
    await gate.release()
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed, "no save left running and no pending draft")
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.hasFailedSaves)
    let disk = try await store.library!.read(record.id)
    XCTAssertEqual(disk.markdown, "v2")
    let shown = try XCTUnwrap(store.scripts.first { $0.id == record.id })
    XCTAssertEqual(shown.markdown, "v2")
    XCTAssertEqual(shown.metadata, disk.metadata, "the visible revision must be the newest saved one")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Conflicts").path).isEmpty)
  }

  func testLinkStateFollowsTheFile() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let library = store.library!
    let file = outside.appendingPathComponent("moved.md")
    try Data("body".utf8).write(to: file)
    let plain = try await library.create(title: "Plain", markdown: "body")
    let linked = try await library.create(title: "Linked", markdown: "body")
    _ = try await library.link(linked.id, to: file)
    var states = await library.linkStates()
    XCTAssertNil(states[plain.id])
    let plainState = try await library.linkState(for: plain.id)
    XCTAssertEqual(plainState, .unlinked)
    guard case .resolved(let url) = states[linked.id] else { return XCTFail("expected a resolved link") }
    XCTAssertEqual(url.lastPathComponent, "moved.md")
    // A bookmark follows a rename, so only a deleted file leaves the link broken.
    try FileManager.default.removeItem(at: file)
    states = await library.linkStates()
    XCTAssertEqual(states[linked.id]?.isBroken, true)
    await store.refreshLinkStates()
    XCTAssertEqual(store.linkStates[linked.id]?.isBroken, true)
  }

  func testUnavailableLinkedOriginalKeepsManagedScriptUsableWithoutRepeatedAlerts() async throws {
    for obstruction in ["permission", "trash"] {
      let root = URL(fileURLWithPath: "/private/tmp/link-unavailable-\(UUID())")
      let outside = URL(fileURLWithPath: "/private/tmp/link-original-\(UUID())")
      let suite = "VideoPrompterTests.link-unavailable.\(UUID())"
      let defaults = UserDefaults(suiteName: suite)!
      defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
        defaults.removePersistentDomain(forName: suite)
      }
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
      let library = try XCTUnwrap(store.library)
      let original = outside.appendingPathComponent("script.md")
      try "One two three".write(to: original, atomically: true, encoding: .utf8)
      let record = try await library.create(title: "Cached", markdown: "One two three")
      let linked = try await library.link(record.id, to: original)
      await store.reload()
      await store.refreshExternalChanges() // Warm the link-sync date before access is lost.
      store.selectedID = record.id
      var settings = PrompterSettings(); settings.mode = "Manual"
      store.session.present(record: try await library.read(record.id), settings: settings)
      store.session.seek(to: 1)
      let anchor = store.session.anchor
      var obstructed = original
      if obstruction == "permission" {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: original.path)
      } else {
        let trash = outside.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        obstructed = trash.appendingPathComponent("script.md")
        try FileManager.default.moveItem(at: original, to: obstructed)
      }
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: obstructed.path) }
      for _ in 0..<3 {
        store.errorMessage = nil
        await store.refreshExternalChanges()
        XCTAssertNil(store.errorMessage, obstruction)
        XCTAssertEqual(store.linkStates[record.id]?.isBroken, true, obstruction)
        XCTAssertFalse(store.unavailableScriptIDs.contains(record.id), "the managed script remains available")
        XCTAssertEqual(store.selected?.markdown, "One two three")
        XCTAssertEqual(store.session.anchor, anchor)
      }
      store.updateMarkdown("One two three, edited locally", for: record.id)
      let flushed = await store.flushPendingSaves()
      XCTAssertTrue(flushed)
      XCTAssertNil(store.errorMessage)
      let saved = try await library.read(record.id)
      XCTAssertEqual(saved.markdown, "One two three, edited locally")
      XCTAssertEqual(saved.metadata.linkedPath, linked.linkedPath)
      XCTAssertEqual(saved.metadata.linkedBookmark, linked.linkedBookmark)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: obstructed.path)
      XCTAssertEqual(try String(contentsOf: obstructed, encoding: .utf8), "One two three", "the inaccessible/trashed original is untouched")
      if obstruction == "trash" { try FileManager.default.moveItem(at: obstructed, to: original) }
      await store.refreshExternalChanges()
      XCTAssertNil(store.errorMessage)
      XCTAssertEqual(store.linkStates[record.id]?.isBroken, false, "restoring access/location resumes the preserved link")
      XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "One two three, edited locally")
    }
  }

  func testRelinkKeepLibraryOverwritesTheFileAfterCopyingIt() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let library = store.library!
    let (record, moved) = try await brokenLink(library, outside, library: "library text", file: "file text")
    let conflicts = root.appendingPathComponent("Conflicts")

    // A recovery copy that cannot be written leaves both sides and the link alone.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: conflicts.path)
    do {
      _ = try await library.relink(id: record.id, to: moved, resolution: .keepLibrary)
      XCTFail("Expected the failed recovery copy to stop the relink")
    } catch {}
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conflicts.path)
    XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "file text")
    let kept = try await library.read(record.id).markdown
    XCTAssertEqual(kept, "library text")
    let stillBroken = try await library.linkState(for: record.id).isBroken
    XCTAssertTrue(stillBroken)

    let outcome = try await library.relink(id: record.id, to: moved, resolution: .keepLibrary)
    XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "library text")
    XCTAssertEqual(outcome.current.markdown, "library text")
    XCTAssertEqual(outcome.current.metadata.linkedPath, moved.standardizedFileURL.path)
    XCTAssertEqual(outcome.current.metadata.linkedFingerprint, MarkdownLibrary.fingerprint("library text"))
    XCTAssertEqual(try conflictTexts(conflicts), ["file text"])
    let nowBroken = try await library.linkState(for: record.id).isBroken
    XCTAssertFalse(nowBroken)
  }

  func testRelinkUseFileAdoptsTheFileAfterCopyingTheLibraryText() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let library = store.library!
    let (record, moved) = try await brokenLink(library, outside, library: "library text", file: "file text")
    let outcome = try await library.relink(id: record.id, to: moved, resolution: .useFile)
    let adopted = try await library.read(record.id).markdown
    XCTAssertEqual(adopted, "file text")
    XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "file text")
    XCTAssertEqual(outcome.current.metadata.contentFingerprint, MarkdownLibrary.fingerprint("file text"))
    XCTAssertEqual(outcome.current.metadata.linkedFingerprint, MarkdownLibrary.fingerprint("file text"))
    XCTAssertGreaterThan(outcome.current.metadata.revision, record.metadata.revision)
    XCTAssertEqual(try conflictTexts(root.appendingPathComponent("Conflicts")), ["library text"])
    let changed = try await library.externalChange(for: record.id)
    XCTAssertNil(changed, "the adopted text must not look like a fresh external edit")
  }

  func testRelinkCanAttachAnUnlinkedLegacyScript() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let library = store.library!
    let record = try await library.create(title: "Legacy", markdown: "library text")
    let file = outside.appendingPathComponent("legacy.md")
    try Data("file text".utf8).write(to: file)

    let outcome = try await library.relink(id: record.id, to: file, resolution: .useFile)

    XCTAssertEqual(outcome.current.markdown, "file text")
    XCTAssertEqual(outcome.current.metadata.linkedPath, file.standardizedFileURL.path)
    XCTAssertEqual(try conflictTexts(root.appendingPathComponent("Conflicts")), ["library text"])
    let state = try await library.linkState(for: record.id)
    XCTAssertFalse(state.isBroken)
  }

  func testRelinkKeepBothLeavesTheScriptUnlinkedAndImportsTheFile() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let library = store.library!
    let (record, moved) = try await brokenLink(library, outside, library: "library text", file: "file text")
    let outcome = try await library.relink(id: record.id, to: moved, resolution: .keepBoth)
    let kept = try await library.read(record.id).markdown
    XCTAssertEqual(kept, "library text")
    XCTAssertNil(outcome.current.metadata.linkedPath)
    XCTAssertNil(outcome.current.metadata.linkedFingerprint)
    let imported = try XCTUnwrap(outcome.imported)
    XCTAssertEqual(imported.markdown, "file text")
    XCTAssertEqual(imported.metadata.linkedPath, moved.standardizedFileURL.path)
    XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "file text")
    let count = await library.listScripts().count
    XCTAssertEqual(count, 2)
  }

  func testRelinkRejectsSymlinksAndNonMarkdown() async throws {
    let (store, root, outside) = makeStore()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let library = store.library!
    let (record, moved) = try await brokenLink(library, outside, library: "library text", file: "file text")
    let link = outside.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
    let text = outside.appendingPathComponent("notes.txt")
    try Data("file text".utf8).write(to: text)
    for bad in [link, text] {
      do {
        _ = try await library.relink(id: record.id, to: bad, resolution: .useFile)
        XCTFail("Expected \(bad.lastPathComponent) to be rejected")
      } catch PrompterCoreError.unsafePath {}
    }
    let kept = try await library.read(record.id).markdown
    XCTAssertEqual(kept, "library text")
  }

  private func makeStore() -> (AppStore, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VideoPrompter-notes-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    return (AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults), root, outside)
  }
  /// A script linked to a file that has since moved: returns the script and the file's new place.
  private func brokenLink(
    _ library: MarkdownLibrary, _ outside: URL, library text: String, file: String
  ) async throws -> (ScriptRecord, URL) {
    let original = outside.appendingPathComponent("script.md")
    try Data(text.utf8).write(to: original)
    let record = try await library.create(title: "Script", markdown: text)
    _ = try await library.link(record.id, to: original)
    let moved = outside.appendingPathComponent("moved/script.md")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: original)
    try Data(file.utf8).write(to: moved)
    return (record, moved)
  }
  private func conflictTexts(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .map { try String(contentsOf: $0, encoding: .utf8) }
  }

  func testFlushPendingSavePersistsImmediateEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)"))
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let first = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(first.settings.fontName, "Lexend Deca")
    XCTAssertEqual(first.sourceFontName, "Lexend Deca")
    XCTAssertEqual(first.previewFontName, "Lexend Deca")
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let injected = UserDefaults(suiteName: "VideoPrompterTests.injected.\(UUID().uuidString)")!
    let explicit = AppStore(arguments: ["test", "--data-directory", second.path], defaults: injected)
    explicit.settings.fontSize = 37
    let explicitReopened = AppStore(arguments: ["test", "--data-directory", second.path], defaults: injected)
    XCTAssertEqual(explicitReopened.settings.fontSize, 37)
  }

  /// Create, duplicate, move to Trash and restore, as the library and a relaunch see them.
  func testCreateDuplicateTrashAndRestoreKeepTheLibraryInStep() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    _ = try await store.library!.create(title: "Existing", markdown: "one")
    await store.reload()
    XCTAssertEqual(store.scripts.count, 1)

    store.create(title: "Created", markdown: "two")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(store.scripts.count, 2)
    store.duplicate()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(store.scripts.count, 3)
    let duplicatedID = try XCTUnwrap(store.selectedID)
    store.delete([duplicatedID])
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(store.scripts.count, 2)
    XCTAssertEqual(store.trash.map(\.id), [duplicatedID])
    store.restore(duplicatedID)
    try await Task.sleep(for: .milliseconds(100))
    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    await reopened.reload()
    XCTAssertEqual(reopened.scripts.count, 3)
    XCTAssertTrue(reopened.trash.isEmpty)
  }

  func testExternalConflictCanKeepExternalAndLocalDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Reading", markdown: "one two three four")
    await store.reload()
    var settings = PrompterSettings(); settings.mode = "Manual"
    store.session.clock = { 0 }
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

  func testPresenterSaveUsesPresentedRecordAndOpeningFingerprint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let presented = try await store.library!.create(title: "Presented", markdown: "one two three")
    let other = try await store.library!.create(title: "Selected", markdown: "other")
    await store.reload()
    store.selectedID = other.id
    store.session.present(record: presented, settings: PrompterSettings())
    try await store.savePresentedMarkdown(
      "one changed three", for: presented.id,
      expectedFingerprint: presented.metadata.contentFingerprint,
      expectedRevision: presented.metadata.revision)
    XCTAssertEqual(store.selectedID, other.id)
    XCTAssertEqual(store.session.activeRecord?.markdown, "one changed three")
    let saved = try await store.library!.read(presented.id)
    XCTAssertEqual(saved.markdown, "one changed three")
  }

  func testPresenterSaveWaitsForPendingLibraryEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Presented", markdown: "original")
    await store.reload()
    store.updateMarkdown("library edit", for: record.id)
    do {
      try await store.savePresentedMarkdown(
        "presenter draft", for: record.id, expectedFingerprint: record.metadata.contentFingerprint,
        expectedRevision: record.metadata.revision)
      XCTFail("Expected the pending library edit to win the fingerprint check")
    } catch {}
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "library edit")
  }

  func testLibraryEditQueuedDuringPresenterSavePersistsAfterPresenterDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Presented", markdown: "original")
    await store.reload()
    store.presenterSaveReservationHook = { store.updateMarkdown("newer library edit", for: record.id) }
    try await store.savePresentedMarkdown(
      "presenter draft", for: record.id, expectedFingerprint: record.metadata.contentFingerprint,
      expectedRevision: record.metadata.revision)
    store.presenterSaveReservationHook = nil
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "newer library edit")
  }

  func testLibraryEditQueuedDuringFailedPresenterSaveEntersRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Presented", markdown: "original")
    let url = try await store.library!.scriptURL(for: record.id)
    await store.reload()
    store.presenterSaveReservationHook = {
      store.updateMarkdown("queued library edit", for: record.id)
      try? Data("external".utf8).write(to: url)
    }
    do {
      try await store.savePresentedMarkdown(
        "presenter draft", for: record.id, expectedFingerprint: record.metadata.contentFingerprint,
        expectedRevision: record.metadata.revision)
      XCTFail("Expected the external write to reject the presenter save")
    } catch {}
    store.presenterSaveReservationHook = nil
    let flushed = await store.flushPendingSaves()
    XCTAssertFalse(flushed)
    XCTAssertTrue(store.hasFailedSaves)
    XCTAssertEqual(store.scripts.first(where: { $0.id == record.id })?.markdown, "queued library edit")
  }

  func testFlushWaitsForReservedPresenterSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Presented", markdown: "original")
    await store.reload()
    let gate = PresenterSaveGate()
    store.presenterSaveReservationGate = { await gate.wait() }
    let presenterSave = Task { try await store.savePresentedMarkdown(
      "presenter draft", for: record.id, expectedFingerprint: record.metadata.contentFingerprint,
      expectedRevision: record.metadata.revision) }
    await gate.waitUntilEntered()
    let flush = Task { await store.flushPendingSaves() }
    await Task.yield()
    await gate.release()
    try await presenterSave.value
    let flushed = await flush.value
    XCTAssertTrue(flushed)
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "presenter draft")
  }

  func testPresenterSavePreservesDraftWhenExternalEditChangedFingerprint() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(title: "Presented", markdown: "original")
    await store.reload()
    let url = try await store.library!.scriptURL(for: record.id)
    try Data("external".utf8).write(to: url)
    await store.refreshExternalChanges()
    do {
      try await store.savePresentedMarkdown(
        "presenter draft", for: record.id, expectedFingerprint: record.metadata.contentFingerprint,
        expectedRevision: record.metadata.revision)
      XCTFail("Expected an external conflict")
    } catch {}
    XCTAssertEqual(store.scripts.first(where: { $0.id == record.id })?.markdown, "external")
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "external")
  }

  func testMissingExternalFilePreservesDraftAndRecoversWhenRestored() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
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

  func testTextZoomStepsTheFocusedWindowsTextWithinItsRange() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VideoPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    store.previewFontSize = 18
    store.settings.fontSize = 44
    store.zoomText(in: true, presenter: false)
    XCTAssertEqual(store.previewFontSize, 20)
    XCTAssertEqual(store.settings.fontSize, 44, "the library zoom leaves the presenter alone")
    store.zoomText(in: true, presenter: true)
    XCTAssertEqual(store.settings.fontSize, 48)
    store.zoomText(in: false, presenter: true)
    XCTAssertEqual(store.settings.fontSize, 44)
    store.previewFontSize = 12
    store.zoomText(in: false, presenter: false)
    XCTAssertEqual(store.previewFontSize, 12, "stops at the smallest size")
    store.zoomText(in: true, presenter: false)
    XCTAssertEqual(store.previewFontSize, 13, "small sizes still move a whole point")
    store.settings.fontSize = 118
    store.zoomText(in: true, presenter: true)
    XCTAssertEqual(store.settings.fontSize, 120, "stops at the largest size")
  }

  func testANewLibraryGetsTheWelcomeScriptOnceAndDeletingItIsFinal() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpw-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "AppStoreTests.\(UUID())")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults, offersWelcomeScript: true)
    await store.waitForWelcomeScript()
    XCTAssertEqual(store.scripts.map(\.metadata.title), [WelcomeScript.title])
    XCTAssertEqual(store.selected?.markdown, WelcomeScript.markdown)
    try await store.deleteScript(try XCTUnwrap(store.scripts.first).id)
    let again = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults, offersWelcomeScript: true)
    await again.waitForWelcomeScript()
    XCTAssertTrue(again.scripts.isEmpty, "offered once per library")
    again.showWelcomeScript()
    try await waitUntil { again.scripts.count == 1 }
    XCTAssertEqual(again.selected?.metadata.title, WelcomeScript.title, "Help > Welcome Script brings it back")
  }

  func testAnEmptyLibraryAlreadyOfferedTheWelcomeScriptStaysEmpty() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpw-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "AppStoreTests.\(UUID())")!
    defaults.set(true, forKey: WelcomeScript.offeredKey)
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults, offersWelcomeScript: true)
    await store.waitForWelcomeScript()
    XCTAssertTrue(store.scripts.isEmpty && store.trash.isEmpty, "the saved marker alone keeps it out")
  }

  func testAnExistingLibraryIsNotGivenTheWelcomeScript() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vpw-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "AppStoreTests.\(UUID())")!
    _ = try await MarkdownLibrary(rootURL: root).create(title: "Mine", markdown: "my words")
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults, offersWelcomeScript: true)
    await store.waitForWelcomeScript()
    XCTAssertEqual(store.scripts.map(\.metadata.title), ["Mine"])
    XCTAssertTrue(defaults.bool(forKey: WelcomeScript.offeredKey))
    let isolated = AppStore(arguments: ["test", "--data-directory", root.path + "-isolated"], defaults: UserDefaults(suiteName: "AppStoreTests.\(UUID())")!)
    defer { try? FileManager.default.removeItem(atPath: root.path + "-isolated") }
    await isolated.waitForInitialLoad()
    await isolated.waitForWelcomeScript()
    XCTAssertTrue(isolated.scripts.isEmpty, "--data-directory launches start empty")
  }

  func testTheWelcomeScriptKeepsItsNotesAndStageDirectionsOutOfTracking() {
    let document = PrompterDocument(markdown: WelcomeScript.markdown)
    let spoken = Set(document.spokenTokens.map(\.normalised))
    XCTAssertFalse(spoken.contains("practice"), "the opening note is a callout")
    XCTAssertEqual(document.blocks.flatMap(\.stageDirections).map(\.text),
                   ["Look at the camera, not the screen.", "Smile. You made it to the end."])
    XCTAssertTrue(spoken.contains("teleprompter"))
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition())
  }
}
