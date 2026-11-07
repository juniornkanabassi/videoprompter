import Foundation
import XCTest
@testable import PrompterCore

@MainActor final class LibraryReview2Tests: XCTestCase {
  func testFailedUnsupportedRelinkLeavesNoConflictCopies() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/vp-relink-review2-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"), coordinatesExternalChanges: false)
    let file = root.appendingPathComponent("unsupported.md")
    let original = try XCTUnwrap("# Café 世界".data(using: .utf16LittleEndian))
    try original.write(to: file)
    let record = try await library.create(title: "Local", markdown: "Local edit")
    for _ in 0..<2 {
      do { _ = try await library.relink(id: record.id, to: file, resolution: .keepLibrary); XCTFail("Relink should fail") } catch {}
      let copies = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library/Conflicts").path)
      XCTAssertTrue(copies.isEmpty, "A failed relink must not create conflict copies")
      let unchanged = try await library.read(record.id)
      XCTAssertEqual(unchanged, record)
      XCTAssertEqual(try Data(contentsOf: file), original)
    }
  }
}
