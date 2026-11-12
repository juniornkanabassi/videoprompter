import Foundation

/// The rules the iPad applies to a script the Mac sends (`PadRemote.Transfer`), kept apart from
/// its folder so they can be tested without an iPad: what to do with the text, which names are
/// safe, and the file written without ever overwriting.
public enum ScriptTransfer {
  public enum Action: Equatable, Sendable {
    /// The script linked to this Mac script is untouched since the Mac's last send: overwrite it.
    case replace
    /// A file of the same title already holds this text: just link to it.
    case link
    /// The linked file was edited here: keep it, write the Mac's text beside it and relink.
    case createCopy
    /// Nothing to link to: a new file in the "Sent from Mac" folder.
    case create
  }

  public static let subfolder = "Sent from Mac"

  /// `linked` is the current text of the script already linked to this Mac script, `sameTitle` the
  /// text of an unlinked file with the same title (the iCloud copy the Mac mirrors).
  public static func action(markdown: String, basis: String?, linked: String?, sameTitle: String?) -> Action {
    if let linked {
      if linked == markdown { return .replace }
      // No basis means the Mac cannot say what it last sent, so an edit here cannot be ruled out.
      if let basis, MarkdownLibrary.fingerprint(linked) == basis { return .replace }
      return .createCopy
    }
    if let sameTitle, sameTitle == markdown { return .link }
    return .create
  }

  /// The link from a Mac script to an iPad script is per folder: another folder may hold a file
  /// at the same relative path that is a different script.
  public static func key(root: URL, macID: UUID) -> String {
    root.resolvingSymlinksInPath().standardizedFileURL.path + "\u{1F}" + macID.uuidString
  }

  /// A file name for a title, with `reserving` characters left free for a suffix. Never longer
  /// than 200 UTF-8 bytes in the stem, so it stays inside the file system's 255.
  public static func fileName(for title: String, reserving: Int = 0) -> String {
    let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t"))
      .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    var stem = cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(max(1, 120 - reserving)))
    // By scalar, not character: one character can be longer than the limit on its own.
    while stem.utf8.count > 200 { stem.unicodeScalars.removeLast() }
    stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
    if stem.isEmpty { stem = "Untitled" }
    return stem.hasPrefix(".") ? "Script " + stem + ".md" : stem + ".md"
  }

  /// Writes `markdown` to a new file `<title><tag>.md` in `directory`, then `<title><tag> 2.md`
  /// and so on if the name is taken. Creation fails rather than overwrites, so two senders cannot
  /// land on one file.
  public static func createFile(title: String, tag: String = "", markdown: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = String(fileName(for: title, reserving: tag.count + 8).dropLast(3))
    for n in 1...999 {
      let url = directory.appendingPathComponent(stem + tag + (n == 1 ? "" : " \(n)") + ".md")
      var error: NSError?
      var failure: Error?
      NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { url in
        // Written whole beside it, then moved in: the move fails if the name is taken.
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
          try Data(markdown.utf8).write(to: temporary)
          try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
          failure = error
          try? FileManager.default.removeItem(at: temporary)
        }
      }
      if let failure = failure ?? error {
        if (failure as NSError).code == NSFileWriteFileExistsError { continue }
        throw failure
      }
      return url
    }
    throw CocoaError(.fileWriteFileExists)
  }
}
