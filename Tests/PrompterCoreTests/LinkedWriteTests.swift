import XCTest

@testable import PrompterCore

/// The linked Markdown file is the person's real script (Obsidian, MarkEdit). Pushing a save to it
/// replaces the file whole, never truncating it first, and keeps the link working.
final class LinkedWriteTests: XCTestCase {
  private func make() async throws -> (MarkdownLibrary, ScriptRecord, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-root-\(UUID().uuidString)")
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("linked-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    addTeardownBlock {
      // A test may leave the folder read-only on purpose.
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
      for url in [root, outside] { try? FileManager.default.removeItem(at: url) }
    }
    let file = outside.appendingPathComponent("script.md")
    try Data("first draft".utf8).write(to: file)
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let record = try await library.create(title: "Script", markdown: "first draft")
    _ = try await library.link(record.id, to: file)
    return (library, record, file, outside)
  }

  func testSavePushedToTheLinkedFileReplacesItWholeAndTheLinkSurvives() async throws {
    let (library, record, file, outside) = try await make()
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let saved = try await library.save(record.id, markdown: "second draft\n\nwith more", expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second draft\n\nwith more")
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o640, "permissions are the original file's")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["script.md"], "no temporary file is left beside it")
    let state = try await library.linkState(for: record.id)
    guard case .resolved(let url) = state else { return XCTFail("the link no longer resolves: \(state)") }
    XCTAssertEqual(url.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
    let settled = try await library.externalChange(for: record.id)
    XCTAssertNil(settled, "our own write is not reported back as an outside change")
    XCTAssertEqual(saved.markdown, "second draft\n\nwith more")
    // And an outside edit still arrives afterwards.
    try Data("edited elsewhere".utf8).write(to: file)
    let changed = try await library.externalChange(for: record.id)
    XCTAssertEqual(changed?.markdown, "edited elsewhere")
  }

  func testAFolderThatCannotBeWrittenStillTakesTheSaveInPlace() async throws {
    let (library, record, file, outside) = try await make()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outside.path)
    _ = try await library.save(record.id, markdown: "saved into a locked folder", expectedFingerprint: record.metadata.contentFingerprint)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved into a locked folder")
  }

  /// A network or FUSE volume (a Shade drive) offers no staging folder: the save still lands, in place.
  func testAVolumeThatCannotStageAReplacementIsWrittenInPlace() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linked-fuse-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("script.md")
    try Data("old".utf8).write(to: file)
    try MarkdownLibrary.replaceLinked(Data("new".utf8), at: file) { _ in throw POSIXError(.ENOTSUP) }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
    // A full disk is reported, not retried in place over the real file.
    XCTAssertThrowsError(try MarkdownLibrary.replaceLinked(Data("newer".utf8), at: file) { _ in throw CocoaError(.fileWriteOutOfSpace) })
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
  }

  func testAFailedReplaceLeavesTheOriginalAndNothingElse() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linked-fail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("script.md")
    try Data("keep me".utf8).write(to: original)
    let missing = folder.appendingPathComponent("gone/script.md")
    XCTAssertThrowsError(try MarkdownLibrary.replaceLinked(Data("new".utf8), at: missing))
    XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep me")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["script.md"])
  }
}
