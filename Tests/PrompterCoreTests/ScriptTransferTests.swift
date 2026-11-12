import XCTest

@testable import PrompterCore

final class ScriptTransferTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptTransferTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testActionMatrix() {
    let old = "Old text", edited = "Edited on the iPad", new = "New from the Mac"
    let basis = MarkdownLibrary.fingerprint(old)
    // First send, nothing to link to.
    XCTAssertEqual(ScriptTransfer.action(markdown: new, basis: nil, linked: nil, sameTitle: nil), .create)
    // The iCloud copy the Mac mirrors: same title and same text links; different text makes a new file.
    XCTAssertEqual(ScriptTransfer.action(markdown: new, basis: nil, linked: nil, sameTitle: new), .link)
    XCTAssertEqual(ScriptTransfer.action(markdown: new, basis: nil, linked: nil, sameTitle: old), .create)
    // Linked and untouched since the last send.
    XCTAssertEqual(ScriptTransfer.action(markdown: new, basis: basis, linked: old, sameTitle: nil), .replace)
    // Edited on the iPad since: keep it.
    XCTAssertEqual(ScriptTransfer.action(markdown: new, basis: basis, linked: edited, sameTitle: nil), .createCopy)
    // No basis and different text is a conflict, not a replace; equal text is harmless.
    XCTAssertEqual(ScriptTransfer.action(markdown: new, basis: nil, linked: edited, sameTitle: nil), .createCopy)
    XCTAssertEqual(ScriptTransfer.action(markdown: new, basis: nil, linked: new, sameTitle: nil), .replace)
  }

  func testTheLinkIsPerFolder() {
    let mac = UUID()
    let a = URL(fileURLWithPath: "/tmp/ScriptsA"), b = URL(fileURLWithPath: "/tmp/ScriptsB")
    XCTAssertNotEqual(ScriptTransfer.key(root: a, macID: mac), ScriptTransfer.key(root: b, macID: mac))
    XCTAssertEqual(ScriptTransfer.key(root: a, macID: mac), ScriptTransfer.key(root: a.appendingPathComponent("."), macID: mac))
    // The same relative path under two roots is two files, so one map entry must not serve both.
    var map: [String: UUID] = [ScriptTransfer.key(root: a, macID: mac): UUID()]
    XCTAssertNil(map[ScriptTransfer.key(root: b, macID: mac)])
    map[ScriptTransfer.key(root: b, macID: mac)] = UUID()
    XCTAssertEqual(map.count, 2)
  }

  func testFilesAreNeverOverwrittenAndGetNumberedNames() throws {
    let root = try folder()
    let sub = root.appendingPathComponent(ScriptTransfer.subfolder)
    let first = try ScriptTransfer.createFile(title: "Preview", markdown: "one", in: sub)
    let second = try ScriptTransfer.createFile(title: "Preview", markdown: "two", in: sub)
    let third = try ScriptTransfer.createFile(title: "Preview", tag: " (from Mac 2026-11-12 14-03-07)", markdown: "three", in: sub)
    XCTAssertEqual([first, second, third].map(\.lastPathComponent),
      ["Preview.md", "Preview 2.md", "Preview (from Mac 2026-11-12 14-03-07).md"])
    XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
    XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
    XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Sent from Mac")
  }

  func testAVeryLongTitleStillFitsAndStaysCollisionProof() throws {
    let root = try folder()
    let title = String(String(repeating: "Arsenal v Tottenham match preview ", count: 6).prefix(200))
    XCTAssertEqual(title.count, 200)
    let tag = " (from Mac 2026-11-12 14-03-07)"
    var urls: [URL] = []
    for _ in 0..<12 { urls.append(try ScriptTransfer.createFile(title: title, tag: tag, markdown: "x", in: root)) }
    XCTAssertEqual(Set(urls).count, 12, "a long title must not collapse every copy onto one name")
    for url in urls {
      XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))
      XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255)
    }
    // The suffix survives the truncation: the tag is still at the end of the stem.
    XCTAssertTrue(urls[0].lastPathComponent.hasSuffix(tag + ".md"), urls[0].lastPathComponent)
    XCTAssertTrue(urls[1].lastPathComponent.hasSuffix(tag + " 2.md"), urls[1].lastPathComponent)
    // Four-byte characters: 120 of them would be 480 bytes.
    let emoji = String(repeating: "\u{1F3C6}", count: 150)
    XCTAssertLessThanOrEqual(ScriptTransfer.fileName(for: emoji).utf8.count, 203)
  }

  func testFileNamesAreCleanedAndNeverHidden() {
    XCTAssertEqual(ScriptTransfer.fileName(for: "a/b:c"), "a-b-c.md")
    XCTAssertEqual(ScriptTransfer.fileName(for: "  "), "Untitled.md")
    XCTAssertEqual(ScriptTransfer.fileName(for: ".hidden"), "Script .hidden.md")
  }
}
