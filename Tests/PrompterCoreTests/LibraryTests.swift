import XCTest

@testable import PrompterCore

final class CoordinatedLibraryTests: XCTestCase {
  func testCoordinatedSaveCreatesConflictForExternalEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-library-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root)
    let record = try await library.create(title: "Draft", markdown: "original")
    let url = try await library.scriptURL(for: record.metadata.id)
    try Data("external".utf8).write(to: url, options: .atomic)

    do {
      _ = try await library.save(
        record.metadata.id, markdown: "local", expectedFingerprint: record.metadata.contentFingerprint)
      XCTFail("Expected an external conflict")
    } catch PrompterCoreError.externalConflict(let conflictFile) {
      let conflictURL = root.appendingPathComponent("Conflicts", isDirectory: true)
        .appendingPathComponent(conflictFile)
      XCTAssertEqual(try String(contentsOf: conflictURL, encoding: .utf8), "local")
    }
  }

  func testDiscoversNewMarkdownAfterInitialisationWithoutDuplicatingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-library-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let url = root.appendingPathComponent("Scripts", isDirectory: true)
      .appendingPathComponent("external.md")
    try Data("external draft".utf8).write(to: url)

    let discovered = try await library.discoverExternalScripts()
    XCTAssertEqual(discovered.count, 1)
    XCTAssertEqual(discovered[0].fileName, "external.md")
    let record = try await library.read(discovered[0].id)
    XCTAssertEqual(record.markdown, "external draft")
    let repeated = try await library.discoverExternalScripts()
    XCTAssertEqual(repeated.count, 0)
    let scripts = await library.listScripts()
    XCTAssertEqual(scripts.filter { $0.fileName == "external.md" }.count, 1)
  }

  func testDiscoverySkipsSymlinksAndMalformedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-library-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-library-outside-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let target = outside.appendingPathComponent("outside.md")
    try Data("outside".utf8).write(to: target)
    let scripts = root.appendingPathComponent("Scripts", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: scripts.appendingPathComponent("link.md"), withDestinationURL: target)
    try Data([0xff, 0x00]).write(to: scripts.appendingPathComponent("malformed.md"))

    let discovered = try await library.discoverExternalScripts()
    XCTAssertTrue(discovered.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: scripts.appendingPathComponent("malformed.md").path))

    try FileManager.default.removeItem(at: scripts)
    try FileManager.default.createSymbolicLink(at: scripts, withDestinationURL: outside)
    do {
      _ = try await library.discoverExternalScripts()
      XCTFail("Expected unsafe Scripts directory")
    } catch PrompterCoreError.unsafePath {}
  }

  func testDiscoveryRetriesAfterIndexPersistenceFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-library-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-library-index-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let scripts = root.appendingPathComponent("Scripts", isDirectory: true)
    try Data("retry me".utf8).write(to: scripts.appendingPathComponent("retry.md"))
    let index = root.appendingPathComponent("LibraryIndex.json")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outside)

    do {
      _ = try await library.discoverExternalScripts()
      XCTFail("Expected index safety failure")
    } catch PrompterCoreError.unsafePath {}
    try FileManager.default.removeItem(at: index)
    let discovered = try await library.discoverExternalScripts()
    XCTAssertEqual(discovered.map(\.fileName), ["retry.md"])
  }
}

/// Scripts imported from a Markdown file keep following that file: an edit in MarkEdit or
/// Obsidian reaches the script, an in-app edit reaches the file, and when both moved the
/// disk version wins with the in-app version preserved.
final class LinkedFileTests: XCTestCase {
  private func makeLibrary() throws -> (MarkdownLibrary, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-linked-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    return (try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false), root, outside)
  }

  func testExternalEditReachesTheScript() async throws {
    let (library, root, outside) = try makeLibrary()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let file = outside.appendingPathComponent("script.md")
    try Data("first draft".utf8).write(to: file)
    let record = try await library.create(title: "Script", markdown: "first draft")
    _ = try await library.link(record.id, to: file)

    try Data("edited elsewhere".utf8).write(to: file)
    let changed = try await library.externalChange(for: record.id)
    XCTAssertEqual(changed?.markdown, "edited elsewhere")
    XCTAssertEqual(changed?.metadata.revision, record.metadata.revision + 1)
    let stored = try await library.read(record.id).markdown
    XCTAssertEqual(stored, "edited elsewhere")
    let settled = try await library.externalChange(for: record.id)
    XCTAssertNil(settled, "a settled link keeps changing")
    let conflicts = await library.takeLinkConflicts()
    XCTAssertTrue(conflicts.isEmpty)
  }

  func testAtomicRenameReplaceIsDetected() async throws {
    let (library, root, outside) = try makeLibrary()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let file = outside.appendingPathComponent("script.md")
    try Data("first draft".utf8).write(to: file)
    let record = try await library.create(title: "Script", markdown: "first draft")
    _ = try await library.link(record.id, to: file)

    // Obsidian and MarkEdit save by writing a sibling and renaming it over the original.
    let staged = outside.appendingPathComponent("script.md.tmp")
    try Data("replaced atomically".utf8).write(to: staged)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: staged)

    let changed = try await library.externalChange(for: record.id)
    XCTAssertEqual(changed?.markdown, "replaced atomically")
    let copy = try await library.scriptURL(for: record.id)
    XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "replaced atomically")
  }

  func testInAppEditIsWrittenBackToTheLinkedFile() async throws {
    let (library, root, outside) = try makeLibrary()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let file = outside.appendingPathComponent("script.md")
    try Data("first draft".utf8).write(to: file)
    let record = try await library.create(title: "Script", markdown: "first draft")
    _ = try await library.link(record.id, to: file)

    let saved = try await library.save(
      record.id, markdown: "typed in the app", expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(saved.markdown, "typed in the app")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "typed in the app")
    let settled = try await library.externalChange(for: record.id)
    XCTAssertNil(settled, "the write back looked like an external edit")
  }

  func testBothSidesChangedKeepsTheDiskVersionAndPreservesTheInAppOne() async throws {
    let (library, root, outside) = try makeLibrary()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let file = outside.appendingPathComponent("script.md")
    try Data("first draft".utf8).write(to: file)
    let record = try await library.create(title: "Script", markdown: "first draft")
    _ = try await library.link(record.id, to: file)

    // The file moves on while an in-app edit is being typed, so the write back is declined.
    try Data("changed on disk".utf8).write(to: file)
    _ = try await library.save(
      record.id, markdown: "changed in the app",
      expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed on disk")

    let resolved = try await library.externalChange(for: record.id)
    XCTAssertEqual(resolved?.markdown, "changed on disk", "the disk version must win")
    let conflicts = await library.takeLinkConflicts()
    XCTAssertEqual(conflicts.count, 1)
    let kept = root.appendingPathComponent("Conflicts", isDirectory: true)
      .appendingPathComponent(try XCTUnwrap(conflicts.first))
    XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "changed in the app")
    let repeated = await library.takeLinkConflicts()
    XCTAssertTrue(repeated.isEmpty, "the notice repeated")
  }

  func testRemovedLinkedFileKeepsTheLastContentAndTheLink() async throws {
    let (library, root, outside) = try makeLibrary()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let file = outside.appendingPathComponent("script.md")
    try Data("first draft".utf8).write(to: file)
    let record = try await library.create(title: "Script", markdown: "first draft")
    _ = try await library.link(record.id, to: file)
    try FileManager.default.removeItem(at: file)

    let unchanged = try await library.externalChange(for: record.id)
    XCTAssertNil(unchanged)
    let kept = try await library.read(record.id).markdown
    XCTAssertEqual(kept, "first draft")
    let listed = await library.listScripts()
    let metadata = try XCTUnwrap(listed.first { $0.id == record.id })
    XCTAssertEqual(metadata.linkedPath, file.standardizedFileURL.path, "the broken link must still show")
    // Saving with the file gone must not fail the in-app edit.
    let saved = try await library.save(
      record.id, markdown: "still editable", expectedFingerprint: metadata.contentFingerprint)
    XCTAssertEqual(saved.markdown, "still editable")
    let unlinked = try await library.unlink(record.id)
    XCTAssertNil(unlinked.linkedPath)
  }

  /// An unlinked script must leave every file outside the library alone, including one that
  /// happens to carry the same text: an empty folder proves nothing on its own.
  func testUnlinkedScriptsAreUntouched() async throws {
    let (library, root, outside) = try makeLibrary()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let bystander = outside.appendingPathComponent("notes.md")
    try Data("someone else's file".utf8).write(to: bystander)
    let record = try await library.create(title: "Plain", markdown: "plain body")
    let unchanged = try await library.externalChange(for: record.id)
    XCTAssertNil(unchanged)
    let link = await library.linkedURL(for: record.id)
    XCTAssertNil(link)
    let saved = try await library.save(
      record.id, markdown: "edited", expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(saved.markdown, "edited")
    _ = try await library.externalChange(for: record.id)
    XCTAssertEqual(try String(contentsOf: bystander, encoding: .utf8), "someone else's file")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: outside.path), ["notes.md"],
      "an unlinked script wrote outside the library")
    let listed = await library.listScripts()
    let metadata = try XCTUnwrap(listed.first { $0.id == record.id })
    XCTAssertNil(metadata.linkedPath)
    XCTAssertNil(metadata.linkedFingerprint)
    let conflicts = await library.takeLinkConflicts()
    XCTAssertTrue(conflicts.isEmpty)
  }

  /// The write back is the one path that runs under `NSFileCoordinator` in the real app, and it
  /// must leave the file itself in place: staging a sibling and replacing the item changed the
  /// file's identity, which breaks bookmarks and other apps' open handles.
  func testCoordinatedWriteBackKeepsTheFileItself() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-linked-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: true)
    let file = outside.appendingPathComponent("script.md")
    try Data("first draft".utf8).write(to: file)
    let bookmark = try file.bookmarkData()
    let record = try await library.create(title: "Script", markdown: "first draft")
    _ = try await library.link(record.id, to: file)

    let saved = try await library.save(
      record.id, markdown: "typed in the app",
      expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(saved.markdown, "typed in the app")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "typed in the app")

    var stale = false
    let resolved = try URL(
      resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    XCTAssertFalse(stale, "the write back invalidated the bookmark")
    XCTAssertEqual(resolved.standardizedFileURL.path, file.standardizedFileURL.path)
    XCTAssertEqual(try String(contentsOf: resolved, encoding: .utf8), "typed in the app")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: outside.path), ["script.md"],
      "the write back left a staging file in the user's folder")
    let settled = try await library.externalChange(for: record.id)
    XCTAssertNil(settled)
  }

  /// A file edited between the import preview and the Import button must not be overwritten by
  /// the preview text the library copy was seeded from: the disk version wins instead.
  func testAFileChangedSinceThePreviewIsNotOverwrittenByIt() async throws {
    let (library, root, outside) = try makeLibrary()
    defer { for url in [root, outside] { try? FileManager.default.removeItem(at: url) } }
    let file = outside.appendingPathComponent("script.md")
    try Data("preview text".utf8).write(to: file)
    // The preview was taken, then the file moved on before Import was pressed.
    let record = try await library.create(title: "Script", markdown: "preview text")
    try Data("changed after the preview".utf8).write(to: file)
    _ = try await library.link(record.id, to: file)

    let resolved = try await library.externalChange(for: record.id)
    XCTAssertEqual(resolved?.markdown, "changed after the preview")
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8), "changed after the preview",
      "the stale preview overwrote the file")
    let settled = try await library.externalChange(for: record.id)
    XCTAssertNil(settled)
  }

  func testThePollDoesNotRereadAFileWhoseModificationDateHasNotMoved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JuniorPrompter-poll-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let record = try await library.create(title: "Poll", markdown: "original")
    let url = try await library.scriptURL(for: record.metadata.id)
    let pinned = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: url.path)
    var change = try await library.externalChange(for: record.metadata.id)
    XCTAssertNil(change)
    // Rewrite the content but put the modification date back. The two-second poll reads and
    // hashes every script otherwise, which is most of its cost; it must stat first and stop.
    try Data("changed behind the stat".utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: url.path)
    change = try await library.externalChange(for: record.metadata.id)
    XCTAssertNil(change, "An unchanged modification date must skip the read and the hash.")
    // ponytail: the ceiling of that shortcut, and why it is safe. A real editor moves the date.
    try FileManager.default.setAttributes(
      [.modificationDate: pinned.addingTimeInterval(1)], ofItemAtPath: url.path)
    change = try await library.externalChange(for: record.metadata.id)
    XCTAssertEqual(change?.markdown, "changed behind the stat")
  }
}
