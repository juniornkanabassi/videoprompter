import Foundation
import PrompterCore

/// One Markdown file in the scripts folder.
struct FolderScript: Identifiable, Hashable, Sendable {
  let id: UUID
  /// Path inside the scripts folder, such as `Match previews/Arsenal.md`.
  let relativePath: String
  let url: URL
  let modified: Date
  /// False while iCloud still holds only a placeholder; the file is downloading.
  let isDownloaded: Bool
  var title: String { url.deletingPathExtension().lastPathComponent }
  /// The subfolder it sits in, which the Mac shows as a library folder. Nil at the top level.
  var folder: String? {
    let parts = relativePath.split(separator: "/")
    return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
  }
}

/// A script moved to Files' Recently Deleted, remembered so it can be brought back.
struct DeletedScript: Codable, Identifiable, Hashable, Sendable {
  var id: UUID
  var title: String
  /// Where it lived in the scripts folder, such as `Match previews/Arsenal.md`.
  var relativePath: String
  /// Where Files holds it now.
  var trashedPath: String
  var deletedAt: Date
  /// The scripts folder it came from, so another folder never lists it.
  var root: String
}

/// What the library's sidebar can show.
enum LibraryScope: Hashable {
  case all, sentFromMac, folder(String), recentlyDeleted
}

/// Whose text a script holds, for the list's note and the footer.
enum ScriptOrigin: Equatable { case fromMac, editedHere, own }

enum ScriptFolderError: LocalizedError {
  case changedElsewhere(conflictCopy: String)
  case nameTaken(String)
  case notDownloaded
  case notInTrash(String)
  var errorDescription: String? {
    switch self {
    case .changedElsewhere(let copy):
      "This script changed on another device while you were editing. Your version was saved as “\(copy)”."
    case .nameTaken(let name): "A script called “\(name)” already exists."
    case .notDownloaded: "This script is still downloading from iCloud. Try again in a moment."
    case .notInTrash(let title): "“\(title)” is no longer in Recently Deleted. Look for it in the Files app."
    }
  }
}

/// The iPad's library is a plain folder of Markdown files: by default one the user picked in
/// iCloud Drive, which the Mac app keeps in step with its own library, otherwise the app's own
/// Documents folder (visible in the Files app). There is no index file, so the Mac and the iPad
/// never fight over one; each file's identity on this iPad is remembered by its path.
@MainActor final class ScriptFolder: ObservableObject {
  @Published private(set) var scripts: [FolderScript] = []
  @Published private(set) var rootURL: URL
  @Published private(set) var isICloud = false
  @Published var errorMessage: String?

  /// Each file's last-read fingerprint, the baseline a save compares against.
  private var baselines: [UUID: String] = [:]
  private var ids: [String: UUID]
  private let defaults: UserDefaults
  private let localURL: URL
  private var accessing: URL?
  private var pollTask: Task<Void, Never>?
  private static let bookmarkKey = "scriptFolderBookmark"
  private static let idsKey = "scriptFolderIDs"
  private static let sentKey = "scriptFolderMacLinks"
  /// Mac script to the iPad script's path, per folder (`ScriptTransfer.key`). The path is kept,
  /// not the id, so the link needs nothing from `ids`; `rename` and `forget` keep it in step.
  private var sent: [String: String]
  private var fingerprints: [UUID: (modified: Date, value: String)] = [:]
  static let presetsFileName = "Video Prompter presets.json"
  @Published private(set) var recentlyDeleted: [DeletedScript] = []
  private var deleted: [DeletedScript]
  /// Scripts saved from this iPad since the Mac last replaced their text.
  private var editedHere: Set<UUID>
  private var texts: [UUID: (modified: Date, text: String)] = [:]
  private let trash: (URL) throws -> URL?
  private static let deletedKey = "scriptFolderDeleted"
  private static let editedKey = "scriptFolderEditedHere"
  /// Files empties Recently Deleted after 30 days.
  static let deletedRetention: TimeInterval = 30 * 24 * 3600

  init(defaults: UserDefaults = .standard, local: URL = ScriptFolder.localFolder, trash: @escaping (URL) throws -> URL? = ScriptFolder.moveToTrash) {
    self.defaults = defaults
    self.trash = trash
    deleted = defaults.data(forKey: Self.deletedKey).flatMap { try? JSONDecoder().decode([DeletedScript].self, from: $0) } ?? []
    editedHere = Set((defaults.stringArray(forKey: Self.editedKey) ?? []).compactMap(UUID.init(uuidString:)))
    localURL = local
    ids = (defaults.dictionary(forKey: Self.idsKey) as? [String: String] ?? [:])
      .compactMapValues(UUID.init(uuidString:))
    sent = defaults.dictionary(forKey: Self.sentKey) as? [String: String] ?? [:]
    rootURL = local
    if let data = defaults.data(forKey: Self.bookmarkKey), let resolved = Self.resolve(data) {
      use(resolved.url)
      // A stale bookmark still resolves today but may not after the next move or restore.
      if resolved.stale, let fresh = try? resolved.url.bookmarkData() { defaults.set(fresh, forKey: Self.bookmarkKey) }
    } else {
      if defaults.data(forKey: Self.bookmarkKey) != nil {
        // The bookmark is kept, so choosing the folder again (or a later launch) can still reach it.
        errorMessage = "Video Prompter cannot reach your scripts folder, so it is showing the scripts on this iPad. Choose the folder again in Settings."
      }
      try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
    refresh()
  }

  static var localFolder: URL {
    URL.documentsDirectory.appendingPathComponent("Scripts", isDirectory: true)
  }

  private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
    return (url, stale)
  }

  /// A folder the document picker returned. Its access lasts as long as the bookmark does.
  func choose(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? url.bookmarkData() else {
      errorMessage = "Video Prompter could not keep access to that folder. Choose it again."
      return
    }
    defaults.set(data, forKey: Self.bookmarkKey)
    use(url)
    refresh()
  }

  /// Back to the folder inside the app, keeping whatever is in it.
  func useLocalFolder() {
    defaults.removeObject(forKey: Self.bookmarkKey)
    accessing?.stopAccessingSecurityScopedResource()
    accessing = nil
    fingerprints = [:]
    scripts = []  // the old folder's files must never stand in for the new one's
    rootURL = localURL
    isICloud = false
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    refresh()
  }

  private func use(_ url: URL) {
    accessing?.stopAccessingSecurityScopedResource()
    accessing = url.startAccessingSecurityScopedResource() ? url : nil
    // Ids are shared by path across folders, so a cached fingerprint is only good for one folder.
    fingerprints = [:]
    scripts = []  // the old folder's files must never stand in for the new one's
    rootURL = url
    isICloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
      || url.path.contains("/Mobile Documents/")
  }

  /// Every few seconds while the app is open: a listing and a date check, no reads.
  func startWatching() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        self?.refresh()
      }
    }
  }
  func stopWatching() {
    pollTask?.cancel()
    pollTask = nil
  }

  /// False while the last look at the folder failed: its list is then the last good one, and an
  /// empty or partial listing must not be read as scripts deleted.
  private(set) var isListed = false

  func refresh() {
    var found: [FolderScript] = []
    var seen = Set<String>()
    isListed = collect(in: rootURL, prefix: "", depth: 0, into: &found, seen: &seen)
    guard isListed else { updateRecentlyDeleted(); return }
    found.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    if found != scripts { scripts = found }
    updateRecentlyDeleted()
  }

  /// False when a folder (or one of its subfolders) could not be listed.
  private func collect(in directory: URL, prefix: String, depth: Int, into found: inout [FolderScript], seen: inout Set<String>) -> Bool {
    let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
    let coordinator = NSFileCoordinator()
    var listing: [URL] = []
    var error: NSError?
    var listed = false
    coordinator.coordinate(readingItemAt: directory, options: [.immediatelyAvailableMetadataOnly], error: &error) { url in
      if let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) {
        listing = entries; listed = true
      }
    }
    guard listed, error == nil else { return false }
    for url in listing {
      var name = url.lastPathComponent
      let values = try? url.resourceValues(forKeys: Set(keys))
      if values?.isDirectory == true {
        // One level of subfolders, the same depth as the Mac library's folders.
        if depth == 0, !name.hasPrefix("."),
          !collect(in: url, prefix: prefix + name + "/", depth: depth + 1, into: &found, seen: &seen) { listed = false }
        continue
      }
      // An iCloud file not yet on this iPad is a hidden ".Name.md.icloud" placeholder.
      var placeholder = false
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        name = String(name.dropFirst().dropLast(".icloud".count))
        placeholder = true
      }
      guard name.lowercased().hasSuffix(".md"), !name.hasPrefix(".") else { continue }
      let real = directory.appendingPathComponent(name)
      let path = prefix + name
      guard seen.insert(path).inserted else { continue }
      let status = values?.ubiquitousItemDownloadingStatus
      let downloaded = !placeholder && (status == nil || status == .current || status == .downloaded)
      if !downloaded { try? FileManager.default.startDownloadingUbiquitousItem(at: real) }
      found.append(FolderScript(
        id: id(for: path), relativePath: path, url: real,
        modified: values?.contentModificationDate ?? .distantPast, isDownloaded: downloaded))
    }
    return listed
  }

  // shortcut: identities are by relative path, so two folders with a file at the same path share
  // one id (and its reading position and Google link); as shipped, change only with a migration.
  private func id(for path: String) -> UUID {
    if let id = ids[path] { return id }
    let id = UUID()
    ids[path] = id
    defaults.set(ids.mapValues(\.uuidString), forKey: Self.idsKey)
    return id
  }

  func script(_ id: UUID) -> FolderScript? { scripts.first { $0.id == id } }

  /// A script whose file is gone keeps no identity: a new file later saved at the same path
  /// is a new script, not the old one with its reading position and Google link.
  func forget(_ id: UUID) {
    // Only this folder's Mac links: another folder's link to a file at the same path stays.
    let prefix = macLinkPrefix
    sent = sent.filter { !($0.key.hasPrefix(prefix) && ids[$0.value] == id) }
    defaults.set(sent, forKey: Self.sentKey)
    ids = ids.filter { $0.value != id }
    defaults.set(ids.mapValues(\.uuidString), forKey: Self.idsKey)
    fingerprints[id] = nil
    texts[id] = nil
    if editedHere.remove(id) != nil { saveEditedHere() }
  }

  // MARK: Scripts sent from a Mac

  /// The Mac script this iPad script was sent from, in the current folder.
  func macID(of id: UUID) -> UUID? {
    let prefix = macLinkPrefix
    return sent.first { $0.key.hasPrefix(prefix) && ids[$0.value] == id }
      .flatMap { UUID(uuidString: String($0.key.dropFirst(prefix.count))) }
  }

  /// What every `ScriptTransfer.key` of this folder starts with (the key ends in a 36-character id).
  private var macLinkPrefix: String { String(ScriptTransfer.key(root: rootURL, macID: UUID()).dropLast(36)) }

  /// The fingerprint of a Mac-sent script's text, read again only when its file changed.
  func fingerprint(of script: FolderScript) -> String? {
    if let cached = fingerprints[script.id], cached.modified == script.modified { return cached.value }
    guard script.isDownloaded, let text = try? Self.read(script.url) else { return nil }
    let value = MarkdownLibrary.fingerprint(text)
    fingerprints[script.id] = (script.modified, value)
    return value
  }

  /// Applies a Mac's script by `ScriptTransfer.action`; nothing here overwrites an edit made on
  /// this iPad. Returns nil for a transfer past the limits.
  func receive(_ transfer: PadRemote.Transfer) throws -> FolderScript? {
    guard transfer.markdown.utf8.count <= PadRemote.Transfer.maximumMarkdownBytes,
      transfer.title.count <= PadRemote.Transfer.maximumTitleLength
    else { return nil }
    refresh()
    let key = ScriptTransfer.key(root: rootURL, macID: transfer.macID)
    // An iCloud placeholder has no text to compare yet.
    func text(_ script: FolderScript) throws -> String? { script.isDownloaded ? try Self.read(script.url) : nil }
    let linked = sent[key].flatMap { path in scripts.first { $0.relativePath == path } }
    let fileName = Self.fileName(for: transfer.title)
    let sameTitle = linked != nil ? nil
      : scripts.first { $0.relativePath == fileName } ?? scripts.first { $0.title == transfer.title }
    let linkedText = try linked.flatMap(text)
    // The linked file cannot be read yet: it may hold an edit, so it is kept and the text goes beside it.
    var action = linked != nil && linkedText == nil
      ? ScriptTransfer.Action.createCopy
      : ScriptTransfer.action(
        markdown: transfer.markdown, basis: transfer.basis, linked: linkedText, sameTitle: try sameTitle.flatMap(text))
    var target = linked ?? sameTitle
    if action == .replace, let linked, let linkedText {
      // Checked and written in one coordinated write, so an edit that lands meanwhile wins.
      if linkedText != transfer.markdown, try !Self.replace(linkedText, with: transfer.markdown, at: linked.url) {
        action = .createCopy
      } else if editedHere.remove(linked.id) != nil { saveEditedHere() }
    }
    if action == .createCopy || action == .create {
      let folder = action == .create ? ScriptTransfer.subfolder : linked?.folder
      let directory = folder.map { rootURL.appendingPathComponent($0, isDirectory: true) } ?? rootURL
      let tag = action == .create ? "" : " (from Mac \(Self.macStamp()))"
      let url = try ScriptTransfer.createFile(
        title: transfer.title, tag: tag, markdown: transfer.markdown, in: directory)
      refresh()
      let path = (folder.map { $0 + "/" } ?? "") + url.lastPathComponent
      target = scripts.first { $0.relativePath == path } ?? FolderScript(
        id: id(for: path), relativePath: path, url: url, modified: Date(), isDownloaded: true)
    }
    guard let target else { return nil }
    sent[key] = target.relativePath
    defaults.set(sent, forKey: Self.sentKey)
    refresh()
    return self.script(target.id) ?? target
  }

  private static func macStamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
  }

  /// The script as a record the shared session can present. The revision follows the content,
  /// so a change made on the Mac moves the saved reading position the way an edit would.
  func record(for script: FolderScript) throws -> ScriptRecord {
    guard script.isDownloaded else { throw ScriptFolderError.notDownloaded }
    let markdown = try Self.read(script.url)
    let fingerprint = MarkdownLibrary.fingerprint(markdown)
    baselines[script.id] = fingerprint
    return ScriptRecord(
      metadata: ScriptMetadata(
        id: script.id, title: script.title, fileName: script.relativePath,
        modifiedAt: script.modified, revision: UInt64(fingerprint, radix: 16) ?? 0,
        contentFingerprint: fingerprint),
      markdown: markdown)
  }

  /// Saves an edit in place. If the file moved on since the edit began, the edit goes to a
  /// conflict copy beside it instead, as the Mac does for linked files, and nothing is lost.
  /// `basis` is the fingerprint of the text the edit started from. The editor passes it so another
  /// read of the file here (presenting it, say) cannot move the point the conflict is judged from.
  @discardableResult
  func save(_ markdown: String, to script: FolderScript, basis: String? = nil) throws -> ScriptRecord {
    let current = try Self.read(script.url)
    if let baseline = basis ?? baselines[script.id], MarkdownLibrary.fingerprint(current) != baseline,
      current != markdown
    {
      throw ScriptFolderError.changedElsewhere(conflictCopy: try saveCopy(markdown, of: script))
    }
    // Checked and written in one coordinated write, so a sync that lands after the read above is never overwritten.
    if current != markdown, try !Self.replace(current, with: markdown, at: script.url) {
      throw ScriptFolderError.changedElsewhere(conflictCopy: try saveCopy(markdown, of: script))
    }
    if current != markdown, editedHere.insert(script.id).inserted { saveEditedHere() }
    refresh()
    return try record(for: self.script(script.id) ?? script)
  }

  /// Puts text beside its script as an iPad copy, leaving the script itself alone. Returns the copy's name.
  @discardableResult
  func saveCopy(_ markdown: String, of script: FolderScript) throws -> String {
    // Numbered and exclusive, so a second copy in the same minute never replaces the first.
    let url = try ScriptTransfer.createFile(
      title: script.title, tag: " (iPad copy \(Self.stamp()))", markdown: markdown, in: script.url.deletingLastPathComponent())
    refresh()
    return url.lastPathComponent
  }

  func create(title: String, markdown: String) throws -> FolderScript {
    let name = Self.fileName(for: title)
    let url = rootURL.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: url.path) else { throw ScriptFolderError.nameTaken(title) }
    try Self.write(markdown, to: url)
    refresh()
    return scripts.first { $0.relativePath == name } ?? FolderScript(
      id: id(for: name), relativePath: name, url: url, modified: Date(), isDownloaded: true)
  }

  func rename(_ script: FolderScript, to title: String) throws {
    let destination = script.url.deletingLastPathComponent().appendingPathComponent(Self.fileName(for: title))
    guard destination != script.url else { return }
    // "arsenal" to "Arsenal": the same file to a case-insensitive volume, so it is not a name clash.
    let caseOnly = destination.path.caseInsensitiveCompare(script.url.path) == .orderedSame
    guard caseOnly || !FileManager.default.fileExists(atPath: destination.path) else { throw ScriptFolderError.nameTaken(title) }
    var error: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: script.url, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error
    ) { from, to in
      do {
        if caseOnly {
          // Through a hidden name, which the library never lists, since a direct move can see the target as taken.
          let between = from.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).md")
          try FileManager.default.moveItem(at: from, to: between)
          do { try FileManager.default.moveItem(at: between, to: to) } catch {
            try? FileManager.default.moveItem(at: between, to: from)
            throw error
          }
        } else { try FileManager.default.moveItem(at: from, to: to) }
      } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
    // The reading position follows the file to its new name.
    let newPath = (script.folder.map { $0 + "/" } ?? "") + destination.lastPathComponent
    ids[newPath] = script.id
    ids[script.relativePath] = nil
    defaults.set(ids.mapValues(\.uuidString), forKey: Self.idsKey)
    let prefix = macLinkPrefix
    for (key, path) in sent where key.hasPrefix(prefix) && path == script.relativePath { sent[key] = newPath }
    defaults.set(sent, forKey: Self.sentKey)
    refresh()
  }

  /// Moves the file to the Recently Deleted folder of Files, so it can be brought back, and
  /// remembers where it went. Nil only if the system gave no place to find it again.
  @discardableResult
  func delete(_ script: FolderScript) throws -> DeletedScript? {
    var error: NSError?
    var failure: Error?
    var trashed: URL?
    let trash = self.trash
    NSFileCoordinator().coordinate(writingItemAt: script.url, options: .forDeleting, error: &error) { url in
      // Recently Deleted or nothing: a script is never removed for good without a way back.
      do { trashed = try trash(url) } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
    var entry: DeletedScript?
    if let trashed {
      entry = DeletedScript(
        id: script.id, title: script.title, relativePath: script.relativePath,
        trashedPath: trashed.path, deletedAt: Date(), root: rootKey)
      deleted.append(entry!)
      saveDeleted()
    }
    refresh()
    return entry
  }

  /// Puts a deleted script back where it was, beside any file that took its name.
  @discardableResult
  func restore(_ entry: DeletedScript) throws -> FolderScript {
    let source = URL(fileURLWithPath: entry.trashedPath)
    let manager = FileManager.default
    guard manager.fileExists(atPath: source.path) else {
      forgetDeleted(entry)
      throw ScriptFolderError.notInTrash(entry.title)
    }
    let relative = entry.relativePath as NSString
    let subfolder = relative.deletingLastPathComponent
    let directory = subfolder.isEmpty ? rootURL : rootURL.appendingPathComponent(subfolder, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = (relative.lastPathComponent as NSString).deletingPathExtension
    var name = relative.lastPathComponent
    var n = 1
    while manager.fileExists(atPath: directory.appendingPathComponent(name).path) {
      name = "\(stem) (restored\(n == 1 ? "" : " \(n)")).md"
      n += 1
    }
    let destination = directory.appendingPathComponent(name)
    var error: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error
    ) { from, to in
      do { try manager.moveItem(at: from, to: to) } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
    forgetDeleted(entry)
    refresh()
    let path = (subfolder.isEmpty ? "" : subfolder + "/") + name
    return scripts.first { $0.relativePath == path }
      ?? FolderScript(id: id(for: path), relativePath: path, url: destination, modified: Date(), isDownloaded: true)
  }

  private var rootKey: String { rootURL.standardizedFileURL.path }

  private func forgetDeleted(_ entry: DeletedScript) {
    deleted.removeAll { $0 == entry }
    saveDeleted()
    updateRecentlyDeleted()
  }

  private func saveDeleted() {
    defaults.set(try? JSONEncoder().encode(deleted), forKey: Self.deletedKey)
  }

  private func saveEditedHere() { defaults.set(editedHere.map(\.uuidString), forKey: Self.editedKey) }

  /// Newest first, this folder's only, and nothing Files has already emptied. A trashed file is
  /// not checked for: the app may not be allowed to look in Files' trash, so only age drops one.
  private func updateRecentlyDeleted(now: Date = Date()) {
    let kept = deleted.filter { now.timeIntervalSince($0.deletedAt) < Self.deletedRetention }
    if kept.count != deleted.count { deleted = kept; saveDeleted() }
    let mine = kept.filter { $0.root == rootKey }.sorted { $0.deletedAt > $1.deletedAt }
    if mine != recentlyDeleted { recentlyDeleted = mine }
  }

  nonisolated static func moveToTrash(_ url: URL) throws -> URL? {
    var result: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    return result as URL?
  }

  // MARK: What the library shows

  /// The sidebar's folders: every subfolder except the one the Mac's scripts land in.
  var folderNames: [String] {
    Set(scripts.compactMap(\.folder).filter { $0 != ScriptTransfer.subfolder }).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }

  /// A scope's scripts, newest first. Recently Deleted holds no live scripts.
  func scripts(in scope: LibraryScope) -> [FolderScript] {
    let inScope: [FolderScript]
    switch scope {
    case .all: inScope = scripts
    case .sentFromMac: inScope = scripts.filter { $0.folder == ScriptTransfer.subfolder || macID(of: $0.id) != nil }
    case .folder(let name): inScope = scripts.filter { $0.folder == name }
    case .recentlyDeleted: inScope = []
    }
    return inScope.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.title < $1.title }
  }

  func count(in scope: LibraryScope) -> Int {
    scope == .recentlyDeleted ? recentlyDeleted.count : scripts(in: scope).count
  }

  /// A script's text, read again only when its file changed. Nil while it is still downloading.
  func text(of script: FolderScript) -> String? {
    if let cached = texts[script.id], cached.modified == script.modified { return cached.text }
    guard script.isDownloaded, let text = try? Self.read(script.url) else { return nil }
    texts[script.id] = (script.modified, text)
    return text
  }

  func wordCount(of script: FolderScript) -> Int? { text(of: script).map(Self.wordCount) }

  /// Words as a reader counts them: Markdown marks such as `#` or `-` on their own are not words.
  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
  }

  /// Whole minutes at a steady 130 words a minute, never less than one.
  static func readingMinutes(words: Int) -> Int { max(1, Int((Double(words) / 130).rounded())) }

  /// Scripts whose title or text holds every word of `query`, ignoring case and accents.
  func search(_ query: String, in list: [FolderScript]) -> [FolderScript] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return list }
    return list.filter { script in
      let haystack = script.title + "\n" + (text(of: script) ?? "")
      return terms.allSatisfy { haystack.localizedStandardContains($0) }
    }
  }

  func origin(of script: FolderScript) -> ScriptOrigin {
    if editedHere.contains(script.id) || macCopyBeside(script) { return .editedHere }
    return macID(of: script.id) != nil || script.folder == ScriptTransfer.subfolder ? .fromMac : .own
  }

  /// A file the Mac's resend landed in because this one was edited here.
  private func macCopyBeside(_ script: FolderScript) -> Bool {
    scripts.contains { $0.folder == script.folder && $0.title.hasPrefix(script.title + " (from Mac ") }
  }

  /// The title the list shows and its note under the date: a script kept beside the Mac's newer
  /// copy reads "(edited on iPad)".
  func listLabel(for script: FolderScript) -> (title: String, note: String?) {
    switch origin(of: script) {
    case .editedHere where macCopyBeside(script): (script.title + " (edited on iPad)", "kept when the Mac resent")
    case .editedHere: (script.title, macID(of: script.id) == nil ? nil : "edited on iPad")
    case .fromMac: (script.title, "Sent from Mac")
    case .own: (script.title, nil)
    }
  }

  /// "Today · 1,062 words · Sent from Mac".
  func metaLine(for script: FolderScript, now: Date = Date()) -> String {
    guard script.isDownloaded else { return "Downloading from iCloud…" }
    return [Self.dateLabel(script.modified, now: now), wordCount(of: script).map { Self.wordsLabel($0) }, listLabel(for: script).note]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// "1,062 words · about 8 min".
  func readingLine(for script: FolderScript) -> String? {
    wordCount(of: script).map { "\(Self.wordsLabel($0)) · about \(Self.readingMinutes(words: $0)) min" }
  }

  /// Which copy the editor shows, as the footer says it.
  func copyLabel(for script: FolderScript) -> String {
    switch origin(of: script) {
    case .fromMac: "Mac’s copy from \(Self.timeLabel(script.modified)) · saved here"
    case .editedHere: macCopyBeside(script) ? "Edited on this iPad · the Mac’s newer copy is kept beside it" : "Edited on this iPad"
    case .own: isICloud ? "Saved in iCloud Drive" : "Saved on this iPad"
    }
  }

  static func wordsLabel(_ words: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_GB")
    return (formatter.string(from: NSNumber(value: words)) ?? "\(words)") + (words == 1 ? " word" : " words")
  }

  /// "Today", "Yesterday", "10 Nov", and the year once it is another one.
  static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    guard date > .distantPast else { return "" }
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM yyyy"
    return formatter.string(from: date)
  }

  static func timeLabel(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }

#if !PAD_FOLDER_TESTS  // PrompterSettings lives in the app target; the test build leaves presets out.
  // MARK: Presets shared with the Mac

  var presetsURL: URL { rootURL.appendingPathComponent(Self.presetsFileName) }

  func readPresets() -> [PrompterSettings]? {
    guard let text = try? Self.read(presetsURL) else { return nil }
    return try? JSONDecoder().decode([PrompterSettings].self, from: Data(text.utf8))
  }

  func writePresets(_ presets: [PrompterSettings]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(presets), let text = String(data: data, encoding: .utf8) else { return }
    if (try? Self.read(presetsURL)) == text { return }
    try? Self.write(text, to: presetsURL)
  }
#endif

  // MARK: Files

  static func fileName(for title: String) -> String { ScriptTransfer.fileName(for: title) }

  private static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM HH.mm"
    formatter.locale = Locale(identifier: "en_GB")
    return formatter.string(from: Date())
  }

  static func read(_ url: URL) throws -> String {
    var error: NSError?
    var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
      result = Result(catching: { try String(contentsOf: url, encoding: .utf8) })
    }
    if let error { throw error }
    return try result.get()
  }

  static func write(_ text: String, to url: URL) throws {
    var error: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
      do { try Data(text.utf8).write(to: url, options: .atomic) } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
  }

  /// Writes `text` only if the file still holds `expected`, checked and written in one
  /// coordinated write so no other writer lands in between. False when the file had changed.
  static func replace(_ expected: String, with text: String, at url: URL) throws -> Bool {
    var error: NSError?
    var result: Result<Bool, Error> = .success(false)
    NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { url in
      result = Result {
        guard try String(contentsOf: url, encoding: .utf8) == expected else { return false }
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
      }
    }
    if let error { throw error }
    return try result.get()
  }
}

/// The pairing key on screen: shown for 30 seconds on request, and never while the screen is
/// recorded or shared. Pure, so the clock and the capture state are given, not read.
struct KeyReveal: Equatable {
  static let duration: TimeInterval = 30
  private var shownAt: Date?

  /// Does nothing while the screen is captured.
  mutating func show(at now: Date, captured: Bool) { shownAt = captured ? nil : now }
  mutating func hide() { shownAt = nil }

  func isVisible(at now: Date, captured: Bool) -> Bool { !captured && secondsLeft(at: now) > 0 }

  /// Whole seconds still to run, rounded up so "30 s" shows at the start and 0 only at the end.
  func secondsLeft(at now: Date) -> Int {
    guard let shownAt else { return 0 }
    return min(Int(Self.duration), max(0, Int((Self.duration - now.timeIntervalSince(shownAt)).rounded(.up))))
  }
}
