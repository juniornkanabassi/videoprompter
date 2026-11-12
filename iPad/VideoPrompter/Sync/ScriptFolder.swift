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

enum ScriptFolderError: LocalizedError {
  case changedElsewhere(conflictCopy: String)
  case nameTaken(String)
  case notDownloaded
  var errorDescription: String? {
    switch self {
    case .changedElsewhere(let copy):
      "This script changed on another device while you were editing. Your version was saved as “\(copy)”."
    case .nameTaken(let name): "A script called “\(name)” already exists."
    case .notDownloaded: "This script is still downloading from iCloud. Try again in a moment."
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
  /// Each file's identity, by folder and path: another folder may hold a file at the same path.
  private var ids: [String: UUID]
  private let defaults: UserDefaults
  private let localURL: URL
  private var accessing: URL?
  private var pollTask: Task<Void, Never>?
  private static let bookmarkKey = "scriptFolderBookmark"
  private static let idsKey = "scriptFolderIDs"
  private static let sentKey = "scriptFolderSentFromMac"
  /// Mac script to iPad script, per folder (`ScriptTransfer.key`); survives renames.
  private var sent: [String: UUID]
  private var fingerprints: [UUID: (modified: Date, value: String)] = [:]
  static let presetsFileName = "Video Prompter presets.json"

  init(defaults: UserDefaults = .standard, local: URL = ScriptFolder.localFolder) {
    self.defaults = defaults
    localURL = local
    ids = (defaults.dictionary(forKey: Self.idsKey) as? [String: String] ?? [:])
      .compactMapValues(UUID.init(uuidString:))
    sent = (defaults.dictionary(forKey: Self.sentKey) as? [String: String] ?? [:])
      .compactMapValues(UUID.init(uuidString:))
    rootURL = local
    if let data = defaults.data(forKey: Self.bookmarkKey), let url = Self.resolve(data) {
      use(url)
    } else {
      try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
    refresh()
  }

  static var localFolder: URL {
    URL.documentsDirectory.appendingPathComponent("Scripts", isDirectory: true)
  }

  private static func resolve(_ data: Data) -> URL? {
    var stale = false
    return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
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
    rootURL = localURL
    isICloud = false
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    refresh()
  }

  private func use(_ url: URL) {
    accessing?.stopAccessingSecurityScopedResource()
    accessing = url.startAccessingSecurityScopedResource() ? url : nil
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

  func refresh() {
    var found: [FolderScript] = []
    var seen = Set<String>()
    collect(in: rootURL, prefix: "", depth: 0, into: &found, seen: &seen)
    found.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    if found != scripts { scripts = found }
  }

  private func collect(in directory: URL, prefix: String, depth: Int, into found: inout [FolderScript], seen: inout Set<String>) {
    let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
    let coordinator = NSFileCoordinator()
    var listing: [URL] = []
    var error: NSError?
    coordinator.coordinate(readingItemAt: directory, options: [.immediatelyAvailableMetadataOnly], error: &error) { url in
      listing = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
    }
    for url in listing {
      var name = url.lastPathComponent
      let values = try? url.resourceValues(forKeys: Set(keys))
      if values?.isDirectory == true {
        // One level of subfolders, the same depth as the Mac library's folders.
        if depth == 0, !name.hasPrefix(".") {
          collect(in: url, prefix: prefix + name + "/", depth: depth + 1, into: &found, seen: &seen)
        }
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
  }

  private static let separator = "\u{1F}"
  private var rootPrefix: String { rootURL.resolvingSymlinksInPath().standardizedFileURL.path + Self.separator }

  private func id(for path: String) -> UUID {
    let key = rootPrefix + path
    if let id = ids[key] { return id }
    // An identity saved before they were per folder is shared by every folder that had a file at
    // this path. `init` lists the folder in use at launch before any other, so that folder owns
    // them; only paths it does not have go to the first other folder that asks.
    let id = ids.removeValue(forKey: path) ?? UUID()
    ids[key] = id
    defaults.set(ids.mapValues(\.uuidString), forKey: Self.idsKey)
    return id
  }

  func script(_ id: UUID) -> FolderScript? { scripts.first { $0.id == id } }

  /// A script whose file is gone keeps no identity: a new file later saved at the same path
  /// is a new script, not the old one with its reading position and Google link.
  func forget(_ id: UUID) {
    // This folder's entries only: the same id may be remembered for another folder.
    ids = ids.filter { !($0.value == id && ($0.key.hasPrefix(rootPrefix) || !$0.key.contains(Self.separator))) }
    defaults.set(ids.mapValues(\.uuidString), forKey: Self.idsKey)
    sent = sent.filter { !($0.value == id && $0.key.hasPrefix(rootPrefix)) }
    defaults.set(sent.mapValues(\.uuidString), forKey: Self.sentKey)
    fingerprints[id] = nil
  }

  /// Of the identities a folder listed last time and no longer lists, the ones really gone. One
  /// that another folder now holds was reassigned, not deleted, and its reading position and
  /// Google link belong to that folder.
  func removedIdentities(known: Set<UUID>, current: Set<UUID>) -> Set<UUID> {
    let elsewhere = Set(ids.filter { !$0.key.hasPrefix(rootPrefix) }.values)
    return known.subtracting(current).subtracting(elsewhere)
  }

  // MARK: Scripts sent from a Mac

  /// The Mac script this iPad script was sent from, in the current folder.
  func macID(of id: UUID) -> UUID? {
    let prefix = ScriptTransfer.key(root: rootURL, macID: UUID()).dropLast(36)
    return sent.first { $0.value == id && $0.key.hasPrefix(prefix) }.flatMap { UUID(uuidString: String($0.key.dropFirst(prefix.count))) }
  }

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
    let linked = sent[key].flatMap(script)
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
      }
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
    sent[key] = target.id
    defaults.set(sent.mapValues(\.uuidString), forKey: Self.sentKey)
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

  /// Saves an edit in place. If the file moved on since it was read here, the edit goes to a
  /// conflict copy beside it instead, as the Mac does for linked files, and nothing is lost.
  @discardableResult
  func save(_ markdown: String, to script: FolderScript) throws -> ScriptRecord {
    let current = try Self.read(script.url)
    if let baseline = baselines[script.id], MarkdownLibrary.fingerprint(current) != baseline,
      current != markdown
    {
      let copyName = "\(script.title) (iPad copy \(Self.stamp())).md"
      try Self.write(markdown, to: script.url.deletingLastPathComponent().appendingPathComponent(copyName))
      refresh()
      throw ScriptFolderError.changedElsewhere(conflictCopy: copyName)
    }
    try Self.write(markdown, to: script.url)
    refresh()
    return try record(for: self.script(script.id) ?? script)
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
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScriptFolderError.nameTaken(title) }
    var error: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: script.url, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error
    ) { from, to in
      do { try FileManager.default.moveItem(at: from, to: to) } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
    // The reading position follows the file to its new name.
    let newPath = (script.folder.map { $0 + "/" } ?? "") + destination.lastPathComponent
    ids[rootPrefix + newPath] = script.id
    ids[rootPrefix + script.relativePath] = nil
    defaults.set(ids.mapValues(\.uuidString), forKey: Self.idsKey)
    refresh()
  }

  /// Moves the file to the Recently Deleted folder of Files, so it can be brought back.
  func delete(_ script: FolderScript) throws {
    var error: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(writingItemAt: script.url, options: .forDeleting, error: &error) { url in
      // Recently Deleted or nothing: a script is never removed for good without a way back.
      do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
    refresh()
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
