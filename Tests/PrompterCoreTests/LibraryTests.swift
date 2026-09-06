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
