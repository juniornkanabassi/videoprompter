import XCTest

@testable import PadScriptFolder
@testable import PrompterCore

/// The iPad's script folder receiving scripts from a Mac, on temporary folders and a throwaway
/// defaults suite: nothing of the real library is touched.
@MainActor
final class ScriptFolderTransferTests: XCTestCase {
  private typealias Folder = PadScriptFolder.ScriptFolder

  private func directory(_ name: String = "root") throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ScriptFolderTransferTests-\(UUID())", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return url
  }

  private func folder(_ local: URL? = nil) throws -> Folder {
    let defaults = freshDefaults("ScriptFolderTransferTests")
    return Folder(defaults: defaults, local: try local ?? directory())
  }

  private func transfer(
    _ mac: UUID, _ text: String, basis: String? = nil, title: String = "Preview"
  ) -> PadRemote.Transfer {
    .init(macID: mac, title: title, markdown: text, basis: basis, present: false)
  }

  private func text(_ script: FolderScript) throws -> String { try Folder.read(script.url) }

  func testFirstSendGoesToSentFromMacAndAResendWithItsBasisReplacesInPlace() throws {
    let folder = try folder()
    let mac = UUID()
    let first = try XCTUnwrap(folder.receive(transfer(mac, "One two three")))
    XCTAssertEqual(first.relativePath, "Sent from Mac/Preview.md")
    XCTAssertEqual(folder.macID(of: first.id), mac)
    XCTAssertEqual(folder.fingerprint(of: first), MarkdownLibrary.fingerprint("One two three"))
    let second = try XCTUnwrap(folder.receive(transfer(mac, "One two three four", basis: MarkdownLibrary.fingerprint("One two three"))))
    XCTAssertEqual(second.id, first.id)
    XCTAssertEqual(try text(second), "One two three four")
    XCTAssertEqual(folder.scripts.count, 1)
    // Unchanged text is a harmless resend.
    let third = try XCTUnwrap(folder.receive(transfer(mac, "One two three four", basis: MarkdownLibrary.fingerprint("One two three four"))))
    XCTAssertEqual(third.id, first.id)
    XCTAssertEqual(folder.scripts.count, 1)
  }

  func testAnEditMadeOnTheIPadIsKeptAndTheMacTextLandsInACopy() throws {
    let folder = try folder()
    let mac = UUID()
    let first = try XCTUnwrap(folder.receive(transfer(mac, "Original")))
    try Folder.write("Edited on the iPad", to: first.url)
    folder.refresh()
    let copy = try XCTUnwrap(folder.receive(transfer(mac, "New from the Mac", basis: MarkdownLibrary.fingerprint("Original"))))
    XCTAssertNotEqual(copy.id, first.id)
    XCTAssertTrue(copy.title.hasPrefix("Preview (from Mac "), copy.title)
    XCTAssertEqual(copy.folder, "Sent from Mac", "beside the file it conflicts with")
    XCTAssertEqual(try text(copy), "New from the Mac")
    XCTAssertEqual(try Folder.read(first.url), "Edited on the iPad")
    XCTAssertEqual(folder.macID(of: copy.id), mac, "the link moves to the copy")
    XCTAssertNil(folder.macID(of: first.id))
    // Sending again goes to the copy, not to a second duplicate.
    let again = try XCTUnwrap(folder.receive(transfer(mac, "Newer", basis: MarkdownLibrary.fingerprint("New from the Mac"))))
    XCTAssertEqual(again.id, copy.id)
    XCTAssertEqual(folder.scripts.count, 2)
  }

  func testAConflictCopyOfATopLevelScriptStaysAtTheTopLevelWithAStableIdentity() throws {
    let folder = try folder()
    let mac = UUID()
    // A same-title file the Mac mirrors, linked by equal text, then edited here.
    let existing = try folder.create(title: "Preview", markdown: "Mirror")
    let linked = try XCTUnwrap(folder.receive(transfer(mac, "Mirror")))
    XCTAssertEqual(linked.id, existing.id)
    try Folder.write("Edited", to: existing.url)
    folder.refresh()
    let copy = try XCTUnwrap(folder.receive(transfer(mac, "Mac text", basis: MarkdownLibrary.fingerprint("Mirror"))))
    XCTAssertNil(copy.folder)
    XCTAssertEqual(folder.scripts.count, 2)
    XCTAssertEqual(folder.script(copy.id)?.relativePath, copy.relativePath, "the new file keeps one identity")
    let again = try XCTUnwrap(folder.receive(transfer(mac, "Mac text 2", basis: MarkdownLibrary.fingerprint("Mac text"))))
    XCTAssertEqual(again.id, copy.id)
    XCTAssertEqual(folder.scripts.count, 2)
  }

  func testNoBasisAndDifferentTextIsAConflict() throws {
    let folder = try folder()
    let mac = UUID()
    let first = try XCTUnwrap(folder.receive(transfer(mac, "Original")))
    let copy = try XCTUnwrap(folder.receive(transfer(mac, "Something else")))
    XCTAssertNotEqual(copy.id, first.id)
    XCTAssertEqual(try text(first), "Original")
    XCTAssertEqual(folder.scripts.count, 2)
  }

  func testASameTitleFileLinksWhenTheTextMatchesAndIsNeverOverwrittenOtherwise() throws {
    let folder = try folder()
    let icloudCopy = try folder.create(title: "Preview", markdown: "Same text")
    let linked = try XCTUnwrap(folder.receive(transfer(UUID(), "Same text")))
    XCTAssertEqual(linked.id, icloudCopy.id)
    XCTAssertEqual(folder.scripts.count, 1)
    let other = try XCTUnwrap(folder.receive(transfer(UUID(), "Different", title: "Preview")))
    XCTAssertNotEqual(other.id, icloudCopy.id)
    XCTAssertEqual(other.relativePath, "Sent from Mac/Preview.md")
    XCTAssertEqual(try text(icloudCopy), "Same text")
  }

  func testRenamingTheScriptHereKeepsTheLink() throws {
    let folder = try folder()
    let mac = UUID()
    let first = try XCTUnwrap(folder.receive(transfer(mac, "Original")))
    try folder.rename(first, to: "Renamed")
    let again = try XCTUnwrap(folder.receive(transfer(mac, "Updated", basis: MarkdownLibrary.fingerprint("Original"))))
    XCTAssertEqual(again.id, first.id)
    XCTAssertEqual(again.relativePath, "Sent from Mac/Renamed.md")
    XCTAssertEqual(try text(again), "Updated")
    XCTAssertEqual(folder.scripts.count, 1)
  }

  func testTheLinkAndTheIdentityBelongToTheirFolder() throws {
    let rootA = try directory("A"), rootB = try directory("B")
    let folder = try folder(rootA)
    let mac = UUID()
    let inA = try XCTUnwrap(folder.receive(transfer(mac, "In A")))
    // Another folder: the same Mac script is not linked here, and the same relative path is a new file.
    folder.choose(rootB)
    XCTAssertTrue(folder.scripts.isEmpty)
    let inB = try XCTUnwrap(folder.receive(transfer(mac, "In B")))
    XCTAssertEqual(inB.relativePath, inA.relativePath)
    XCTAssertNotEqual(inB.id, inA.id)
    XCTAssertEqual(try text(inB), "In B")
    XCTAssertEqual(try Folder.read(inA.url), "In A", "the other folder's file is untouched")
    // Deleting here forgets only this folder's entries.
    folder.forget(inB.id)
    folder.choose(rootA)
    XCTAssertEqual(folder.scripts.map(\.id), [inA.id], "its identity survived the switch and the other folder's forget")
    XCTAssertEqual(folder.macID(of: inA.id), mac)
    let again = try XCTUnwrap(folder.receive(transfer(mac, "In A 2", basis: MarkdownLibrary.fingerprint("In A"))))
    XCTAssertEqual(again.id, inA.id)
    // A forgotten script is a new one when its path comes back.
    folder.choose(rootB)
    XCTAssertNotEqual(folder.scripts.first?.id, inB.id)
  }

  func testAnUndownloadedFileDoesNotFailTheTransfer() throws {
    let folder = try folder()
    // An iCloud placeholder with the same title is not a match, and not an error.
    let root = folder.rootURL
    try Data().write(to: root.appendingPathComponent(".Preview.md.icloud"))
    folder.refresh()
    XCTAssertEqual(folder.scripts.first?.isDownloaded, false)
    let mac = UUID()
    let made = try XCTUnwrap(folder.receive(transfer(mac, "Fresh")))
    XCTAssertEqual(made.relativePath, "Sent from Mac/Preview.md")
    // The linked file turning into a placeholder: kept, with the Mac's text in a copy.
    let placeholder = made.url.deletingLastPathComponent().appendingPathComponent(".Preview.md.icloud")
    try FileManager.default.moveItem(at: made.url, to: placeholder)
    let copy = try XCTUnwrap(folder.receive(transfer(mac, "Updated", basis: MarkdownLibrary.fingerprint("Fresh"))))
    XCTAssertTrue(copy.title.hasPrefix("Preview (from Mac "), copy.title)
    XCTAssertEqual(try text(copy), "Updated")
    XCTAssertTrue(FileManager.default.fileExists(atPath: placeholder.path))
  }

  func testTransfersPastTheLimitsAreIgnored() throws {
    let folder = try folder()
    XCTAssertNil(try folder.receive(transfer(UUID(), String(repeating: "x", count: PadRemote.Transfer.maximumMarkdownBytes + 1))))
    XCTAssertNil(try folder.receive(transfer(UUID(), "ok", title: String(repeating: "T", count: 201))))
    XCTAssertTrue(folder.scripts.isEmpty)
    XCTAssertNotNil(try folder.receive(transfer(UUID(), String(repeating: "x", count: PadRemote.Transfer.maximumMarkdownBytes))))
  }

  /// Before identities were per folder, A/Preview.md and B/Preview.md shared one. The folder in
  /// use at the upgrade keeps it, whichever folder is opened first afterwards.
  func testASharedLegacyIdentityStaysWithTheFolderInUseAtTheUpgrade() throws {
    for (ownerName, otherName) in [("A", "B"), ("B", "A")] {
      let roots = [ownerName: try directory(ownerName), otherName: try directory(otherName)]
      let owner = try XCTUnwrap(roots[ownerName]), other = try XCTUnwrap(roots[otherName])
      for (name, root) in roots { try Folder.write("Text \(name)", to: root.appendingPathComponent("Preview.md")) }
      let legacy = UUID()
      let defaults = freshDefaults("ScriptFolderLegacy")
      defaults.set(["Preview.md": legacy.uuidString], forKey: "scriptFolderIDs")
      defaults.set(try owner.bookmarkData(), forKey: "scriptFolderBookmark")
      let folder = Folder(defaults: defaults, local: try directory("local"))
      XCTAssertEqual(folder.scripts.map(\.id), [legacy], "\(ownerName) owns it from the first listing")
      // The other folder opened first or second makes no difference to who owns it.
      folder.choose(other)
      let otherID = try XCTUnwrap(folder.scripts.first?.id)
      XCTAssertNotEqual(otherID, legacy)
      // Its old membership names the shared id, which the owner holds: reassigned, not deleted, so
      // the owner's reading position and Google link are not cleaned away.
      XCTAssertEqual(folder.removedIdentities(known: [legacy], current: [otherID]), [])
      // Mac links are per folder and a resend lands on the same file, never a duplicate.
      let mac = UUID()
      let linked = try XCTUnwrap(folder.receive(transfer(mac, "Text \(otherName)")))
      XCTAssertEqual(linked.id, otherID)
      let resent = try XCTUnwrap(folder.receive(transfer(mac, "Text \(otherName) more", basis: MarkdownLibrary.fingerprint("Text \(otherName)"))))
      XCTAssertEqual(resent.id, otherID)
      XCTAssertEqual(folder.scripts.count, 1)
      folder.choose(owner)
      XCTAssertEqual(folder.scripts.map(\.id), [legacy])
      let ownerLink = try XCTUnwrap(folder.receive(transfer(mac, "Text \(ownerName)")))
      XCTAssertEqual(ownerLink.id, legacy)
      let ownerResent = try XCTUnwrap(folder.receive(transfer(mac, "Text \(ownerName) more", basis: MarkdownLibrary.fingerprint("Text \(ownerName)"))))
      XCTAssertEqual(ownerResent.id, legacy)
      XCTAssertEqual(folder.scripts.count, 1)
      XCTAssertEqual(folder.macID(of: legacy), mac)
      // A script really deleted from its own folder is still cleaned up.
      XCTAssertEqual(folder.removedIdentities(known: [legacy], current: []), [legacy])
    }
  }
}
