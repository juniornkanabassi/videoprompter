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
}
