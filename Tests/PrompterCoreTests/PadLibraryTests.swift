import XCTest

@testable import PadScriptFolder
@testable import PrompterCore

/// The iPad library's rules (search, scopes, labels, Recently Deleted with undo, the pairing key's
/// 30 second reveal) on temporary folders, a throwaway defaults suite and a fake trash: nothing of
/// the real library or the Mac's Trash is touched.
@MainActor
final class PadLibraryTests: XCTestCase {
  private typealias Folder = PadScriptFolder.ScriptFolder

  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PadLibraryTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// A folder whose "Recently Deleted" is a plain directory beside it.
  private func folder() throws -> (folder: Folder, root: URL) {
    let base = try scratch()
    let root = base.appendingPathComponent("root", isDirectory: true)
    let bin = base.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let folder = Folder(defaults: freshDefaults("PadLibraryTests"), local: root) { url in
      let destination = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
      try FileManager.default.moveItem(at: url, to: destination)
      return destination
    }
    return (folder, root)
  }

  @discardableResult
  private func add(_ title: String, _ text: String, in folder: Folder, at modified: Date? = nil, subfolder: String? = nil) throws -> FolderScript {
    let relative = (subfolder.map { $0 + "/" } ?? "") + title + ".md"
    let url = folder.rootURL.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Folder.write(text, to: url)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    folder.refresh()
    return try XCTUnwrap(folder.scripts.first { $0.relativePath == relative })
  }

  // MARK: Search

  func testSearchFindsTitlesAndScriptTextIgnoringCaseAndAccents() throws {
    let (folder, _) = try folder()
    let title = try add("Title race", "Welcome back to the studio.", in: folder)
    let body = try add("Bench goals", "Eleven goals from substitutes. Café culture.", in: folder)
    XCTAssertEqual(folder.search("TITLE", in: folder.scripts), [title])
    XCTAssertEqual(folder.search("substitutes", in: folder.scripts), [body])
    XCTAssertEqual(folder.search("cafe", in: folder.scripts), [body], "accents do not matter")
    XCTAssertEqual(folder.search("  ", in: folder.scripts).count, 2, "a blank search shows everything")
    XCTAssertTrue(folder.search("nothing like this", in: folder.scripts).isEmpty)
  }

  func testEveryWordOfASearchMustMatchSomewhereInTheScript() throws {
    let (folder, _) = try folder()
    let match = try add("Bench goals", "Eleven goals from substitutes.", in: folder)
    try add("Podcast intro", "Goals again.", in: folder)
    XCTAssertEqual(folder.search("bench substitutes", in: folder.scripts), [match])
    XCTAssertEqual(folder.search("bench nonsense", in: folder.scripts), [])
  }

  func testSearchSeesAnEditAfterTheFileChanges() throws {
    let (folder, _) = try folder()
    let script = try add("Notes", "alpha", in: folder, at: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(folder.search("beta", in: folder.scripts), [])
    try Folder.write("alpha beta", to: script.url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: script.url.path)
    folder.refresh()
    XCTAssertEqual(folder.search("beta", in: folder.scripts).map(\.id), [script.id])
  }

  // MARK: Scopes and counts

  func testScopesCountAndOrderScriptsNewestFirst() throws {
    let (folder, _) = try folder()
    let old = try add("Old", "one", in: folder, at: Date(timeIntervalSince1970: 1_000))
    let new = try add("New", "two", in: folder, at: Date(timeIntervalSince1970: 3_000))
    let sent = try add("Sent", "three", in: folder, at: Date(timeIntervalSince1970: 2_000), subfolder: ScriptTransfer.subfolder)
    let shorts = try add("Short", "four", in: folder, at: Date(timeIntervalSince1970: 500), subfolder: "Shorts")
    XCTAssertEqual(folder.scripts(in: .all), [new, sent, old, shorts])
    XCTAssertEqual(folder.scripts(in: .sentFromMac), [sent])
    XCTAssertEqual(folder.scripts(in: .folder("Shorts")), [shorts])
    XCTAssertEqual(folder.folderNames, ["Shorts"], "Sent from Mac has its own row, not a folder row")
    XCTAssertEqual(folder.count(in: .all), 4)
    XCTAssertEqual(folder.count(in: .sentFromMac), 1)
    XCTAssertEqual(folder.count(in: .recentlyDeleted), 0)
  }

  func testWordCountSkipsMarkdownMarksAndReadingTimeIsAtLeastOneMinute() {
    XCTAssertEqual(Folder.wordCount("# Title race\n\nFirst, the **pressing**.\n- a b\n---"), 7)
    XCTAssertEqual(Folder.readingMinutes(words: 1_062), 8)
    XCTAssertEqual(Folder.readingMinutes(words: 3), 1)
    XCTAssertEqual(Folder.wordsLabel(1_062), "1,062 words")
    XCTAssertEqual(Folder.wordsLabel(1), "1 word")
  }

  func testDateLabels() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12)))
    func day(_ y: Int, _ m: Int, _ d: Int) throws -> Date { try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 8))) }
    XCTAssertEqual(Folder.dateLabel(try day(2026, 11, 13), now: now, calendar: calendar), "Today")
    XCTAssertEqual(Folder.dateLabel(try day(2026, 11, 12), now: now, calendar: calendar), "Yesterday")
    XCTAssertEqual(Folder.dateLabel(try day(2026, 11, 10), now: now, calendar: calendar), "10 Nov")
    XCTAssertEqual(Folder.dateLabel(try day(2025, 3, 2), now: now, calendar: calendar), "2 Mar 2025")
    XCTAssertEqual(Folder.dateLabel(.distantPast, now: now, calendar: calendar), "")
  }

  // MARK: Sent from Mac and the iPad copy

  func testAScriptSentFromTheMacIsNotedAndAKeptEditReadsEditedOnIPad() throws {
    let (folder, _) = try folder()
    let mac = UUID()
    let sent = try XCTUnwrap(folder.receive(.init(macID: mac, title: "194 Short", markdown: "Title race", basis: nil, present: false)))
    XCTAssertEqual(folder.origin(of: sent), .fromMac)
    XCTAssertEqual(folder.listLabel(for: sent).note, "Sent from Mac")
    XCTAssertTrue(folder.metaLine(for: sent).hasSuffix("2 words · Sent from Mac"), folder.metaLine(for: sent))
    XCTAssertTrue(folder.copyLabel(for: sent).hasPrefix("Mac’s copy from "))

    // Saved here: this copy is now the iPad's.
    try folder.save("Title race, edited", to: sent)
    let edited = try XCTUnwrap(folder.script(sent.id))
    XCTAssertEqual(folder.origin(of: edited), .editedHere)
    XCTAssertEqual(folder.copyLabel(for: edited), "Edited on this iPad")

    // The Mac resends: the edit is kept and the Mac's text lands in a copy beside it.
    let copy = try XCTUnwrap(folder.receive(.init(
      macID: mac, title: "194 Short", markdown: "Title race v2", basis: MarkdownLibrary.fingerprint("Title race"), present: false)))
    XCTAssertNotEqual(copy.id, sent.id)
    let kept = try XCTUnwrap(folder.script(sent.id))
    XCTAssertEqual(folder.listLabel(for: kept).title, "194 Short (edited on iPad)")
    XCTAssertEqual(folder.listLabel(for: kept).note, "kept when the Mac resent")
    XCTAssertTrue(folder.copyLabel(for: kept).contains("the Mac’s newer copy is kept beside it"))
    XCTAssertEqual(folder.origin(of: copy), .fromMac)
    XCTAssertEqual(folder.listLabel(for: copy).note, "Sent from Mac")
  }

  func testAMacTextReplacingTheFileInPlaceIsTheMacsCopyAgain() throws {
    let (folder, _) = try folder()
    let mac = UUID()
    let sent = try XCTUnwrap(folder.receive(.init(macID: mac, title: "Preview", markdown: "one", basis: nil, present: false)))
    try folder.save("one two", to: sent)
    XCTAssertEqual(folder.origin(of: sent), .editedHere)
    // The Mac sends exactly what is on the iPad now: nothing to keep apart, so it is the Mac's again.
    _ = try folder.receive(.init(macID: mac, title: "Preview", markdown: "one two", basis: MarkdownLibrary.fingerprint("one two"), present: false))
    XCTAssertEqual(folder.origin(of: try XCTUnwrap(folder.script(sent.id))), .fromMac)
  }

  /// An unsaved iPad draft, then the Mac sends and opens a newer version: the draft is judged against the
  /// text it began from, so it lands in a copy and the Mac's text is not overwritten.
  func testAStaleDraftAfterAMacSendKeepsBothVersions() throws {
    let (folder, _) = try folder()
    let mac = UUID()
    let sent = try XCTUnwrap(folder.receive(.init(macID: mac, title: "Draft", markdown: "v1 text", basis: nil, present: false)))
    let began = try folder.record(for: sent).markdown
    let updated = try XCTUnwrap(folder.receive(.init(
      macID: mac, title: "Draft", markdown: "v2 from the Mac", basis: MarkdownLibrary.fingerprint(began), present: true)))
    // Presenting reads the file, which moves the folder's own baseline to the Mac's text.
    _ = try folder.record(for: updated)
    XCTAssertThrowsError(try folder.save("my unsaved edit", to: updated, basis: MarkdownLibrary.fingerprint(began))) { error in
      guard case ScriptFolderError.changedElsewhere = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(try Folder.read(updated.url), "v2 from the Mac")
    let copy = try XCTUnwrap(folder.scripts.first { $0.title.contains("iPad copy") })
    XCTAssertEqual(try Folder.read(copy.url), "my unsaved edit")
  }

  func testAnUnwritableDraftCanStillBeKeptBesideItsScript() throws {
    let (folder, _) = try folder()
    let script = try add("Keep", "original", in: folder)
    let name = try folder.saveCopy("typed but unsaved", of: script)
    XCTAssertEqual(try Folder.read(script.url), "original")
    let copy = try XCTUnwrap(folder.scripts.first { $0.relativePath == name })
    XCTAssertEqual(try Folder.read(copy.url), "typed but unsaved")
  }

  func testTwoCopiesInTheSameMinuteKeepBothTexts() throws {
    let (folder, _) = try folder()
    let script = try add("Twice", "original", in: folder)
    let first = try folder.saveCopy("first draft", of: script)
    let second = try folder.saveCopy("second draft", of: script)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try Folder.read(XCTUnwrap(folder.scripts.first { $0.relativePath == first }).url), "first draft")
    XCTAssertEqual(try Folder.read(XCTUnwrap(folder.scripts.first { $0.relativePath == second }).url), "second draft")
  }

  func testAFileOfTheUsersOwnIsLabelledByWhereItIsSaved() throws {
    let (folder, _) = try folder()
    let own = try add("Mine", "words here", in: folder)
    XCTAssertEqual(folder.origin(of: own), .own)
    XCTAssertNil(folder.listLabel(for: own).note)
    XCTAssertEqual(folder.copyLabel(for: own), "Saved on this iPad")
    XCTAssertEqual(folder.readingLine(for: own), "2 words · about 1 min")
  }

  // MARK: Recently Deleted and undo

  func testDeletingMovesTheFileToRecentlyDeletedAndUndoBringsItBack() throws {
    let (folder, root) = try folder()
    let script = try add("Title race", "Welcome back", in: folder, subfolder: "Shorts")
    let entry = try XCTUnwrap(try folder.delete(script))
    XCTAssertTrue(folder.scripts.isEmpty)
    XCTAssertEqual(folder.recentlyDeleted, [entry])
    XCTAssertEqual(folder.count(in: .recentlyDeleted), 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: script.url.path))

    let restored = try folder.restore(entry)
    XCTAssertEqual(restored.relativePath, "Shorts/Title race.md")
    XCTAssertEqual(try Folder.read(root.appendingPathComponent("Shorts/Title race.md")), "Welcome back")
    XCTAssertTrue(folder.recentlyDeleted.isEmpty)
  }

  func testRestoringBesideAFileThatTookTheNameKeepsBoth() throws {
    let (folder, _) = try folder()
    let first = try add("Notes", "original", in: folder)
    let entry = try XCTUnwrap(try folder.delete(first))
    try add("Notes", "newer file", in: folder)
    let restored = try folder.restore(entry)
    XCTAssertEqual(restored.relativePath, "Notes (restored).md")
    XCTAssertEqual(try Folder.read(restored.url), "original")
    XCTAssertEqual(folder.scripts.count, 2)
  }

  func testRecentlyDeletedListsNewestFirstAndOnlyThisFoldersScripts() throws {
    let (folder, _) = try folder()
    let one = try add("One", "1", in: folder)
    let two = try add("Two", "2", in: folder)
    let first = try XCTUnwrap(try folder.delete(one))
    Thread.sleep(forTimeInterval: 0.01)
    let second = try XCTUnwrap(try folder.delete(two))
    XCTAssertEqual(folder.recentlyDeleted.map(\.title), [second.title, first.title])
    // Another folder never lists them.
    let other = try scratch()
    folder.choose(other)
    XCTAssertTrue(folder.recentlyDeleted.isEmpty)
  }

  func testRestoringWhatFilesHasEmptiedExplainsAndForgetsIt() throws {
    let (folder, _) = try folder()
    let entry = try XCTUnwrap(try folder.delete(try add("Gone", "x", in: folder)))
    try FileManager.default.removeItem(atPath: entry.trashedPath)
    XCTAssertThrowsError(try folder.restore(entry)) { error in
      XCTAssertEqual((error as? ScriptFolderError)?.errorDescription, "“Gone” is no longer in Recently Deleted. Look for it in the Files app.")
    }
    XCTAssertTrue(folder.recentlyDeleted.isEmpty)
  }

  func testTheDeletedListSurvivesARelaunch() throws {
    let base = try scratch()
    let root = base.appendingPathComponent("root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = freshDefaults("PadLibraryTests")
    let trash: (URL) throws -> URL? = { url in
      let destination = base.appendingPathComponent("bin-" + url.lastPathComponent)
      try FileManager.default.moveItem(at: url, to: destination)
      return destination
    }
    let folder = Folder(defaults: defaults, local: root, trash: trash)
    try Folder.write("hello", to: root.appendingPathComponent("Kept.md"))
    folder.refresh()
    let entry = try XCTUnwrap(try folder.delete(try XCTUnwrap(folder.scripts.first)))
    let again = Folder(defaults: defaults, local: root, trash: trash)
    XCTAssertEqual(again.recentlyDeleted, [entry])
  }

  // MARK: Folder safety

  func testACaseOnlyRenameKeepsTheScriptAndItsIdentity() throws {
    let (folder, root) = try folder()
    let script = try add("arsenal", "Kick-off", in: folder)
    try folder.rename(script, to: "Arsenal")
    let renamed = try XCTUnwrap(folder.scripts.first)
    XCTAssertEqual(folder.scripts.count, 1)
    XCTAssertEqual(renamed.relativePath, "Arsenal.md")
    XCTAssertEqual(renamed.id, script.id)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Arsenal.md"])
    XCTAssertEqual(try Folder.read(renamed.url), "Kick-off")
    // A different script's name is still refused.
    let other = try add("Chelsea", "x", in: folder)
    XCTAssertThrowsError(try folder.rename(other, to: "ARSENAL"))
  }

  /// A listing that fails keeps the last good list, so nothing reads it as every script deleted.
  func testAFolderThatCannotBeListedKeepsItsLastListAndSaysSo() throws {
    let (folder, root) = try folder()
    try add("Kept", "text", in: folder)
    XCTAssertTrue(folder.isListed)
    try FileManager.default.removeItem(at: root)
    folder.refresh()
    XCTAssertFalse(folder.isListed)
    XCTAssertEqual(folder.scripts.map(\.title), ["Kept"])
  }

  func testAFolderBookmarkThatNoLongerResolvesIsReportedNotSilentlyReplaced() throws {
    let local = try scratch()
    let defaults = freshDefaults("PadLibraryTests")
    defaults.set(Data("not a bookmark".utf8), forKey: "scriptFolderBookmark")
    let folder = Folder(defaults: defaults, local: local)
    XCTAssertEqual(folder.rootURL, local)
    XCTAssertNotNil(folder.errorMessage)
    XCTAssertNotNil(defaults.data(forKey: "scriptFolderBookmark"), "the bookmark is kept for a later launch")
  }

  // MARK: The pairing key's reveal

  func testTheKeyShowsFor30SecondsThenHidesItself() {
    var reveal = KeyReveal()
    let start = Date(timeIntervalSince1970: 1_000)
    XCTAssertFalse(reveal.isVisible(at: start, captured: false), "hidden until asked")
    reveal.show(at: start, captured: false)
    XCTAssertTrue(reveal.isVisible(at: start, captured: false))
    XCTAssertEqual(reveal.secondsLeft(at: start), 30)
    XCTAssertEqual(reveal.secondsLeft(at: start.addingTimeInterval(6.2)), 24)
    XCTAssertTrue(reveal.isVisible(at: start.addingTimeInterval(29.9), captured: false))
    XCTAssertFalse(reveal.isVisible(at: start.addingTimeInterval(30), captured: false))
    XCTAssertEqual(reveal.secondsLeft(at: start.addingTimeInterval(45)), 0)
  }

  func testTheKeyStaysHiddenWhileTheScreenIsCapturedAndDoesNotComeBack() {
    var reveal = KeyReveal()
    let start = Date(timeIntervalSince1970: 1_000)
    reveal.show(at: start, captured: false)
    XCTAssertFalse(reveal.isVisible(at: start.addingTimeInterval(5), captured: true))
    // Hidden by the view when capture starts; it does not reappear when capture ends.
    reveal.hide()
    XCTAssertFalse(reveal.isVisible(at: start.addingTimeInterval(6), captured: false))
    // And it cannot be asked for while the screen is being recorded.
    reveal.show(at: start.addingTimeInterval(7), captured: true)
    XCTAssertFalse(reveal.isVisible(at: start.addingTimeInterval(7), captured: false))
    // Asking again after the recording ends starts a fresh 30 seconds.
    reveal.show(at: start.addingTimeInterval(40), captured: false)
    XCTAssertEqual(reveal.secondsLeft(at: start.addingTimeInterval(40)), 30)
  }
}
