import Foundation

public struct TrashEntry: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID { metadata.id }
  public var metadata: ScriptMetadata
  public var deletedAt: Date
}

public actor MarkdownLibrary {
  private struct Index: Codable {
    var schemaVersion = 2
    var scripts: [ScriptMetadata] = []
    var trash: [TrashEntry] = []
    var folders: [ScriptFolder] = []
    init() {}
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
      scripts = try c.decodeIfPresent([ScriptMetadata].self, forKey: .scripts) ?? []
      trash = try c.decodeIfPresent([TrashEntry].self, forKey: .trash) ?? []
      folders = try c.decodeIfPresent([ScriptFolder].self, forKey: .folders) ?? []
    }
  }
  public let rootURL: URL
  private let scriptsURL: URL
  private let trashURL: URL
  private let conflictsURL: URL
  private let indexURL: URL
  private let coordinatesExternalChanges: Bool
  private var index: Index
  private var linkConflicts: [String] = []
  /// Last seen modification date of each linked file, so an untouched file is not re-read.
  private var lastLinkSync: [UUID: Date] = [:]
  /// Modification date of each library file the last time the poll read it, and of the Scripts
  /// folder the last time it was scanned. The two-second poll used to coordinate-read and
  /// fingerprint every script and re-enumerate the folder every tick, whether or not anything
  /// on disk had moved; a stat is orders of magnitude cheaper than a read plus a hash.
  private var lastExternalRead: [UUID: Date] = [:]
  private var lastScriptsScan: Date?

  public init(rootURL: URL, coordinatesExternalChanges: Bool = true) throws {
    self.rootURL = rootURL
    scriptsURL = rootURL.appendingPathComponent("Scripts", isDirectory: true)
    trashURL = rootURL.appendingPathComponent("Trash", isDirectory: true)
    conflictsURL = rootURL.appendingPathComponent("Conflicts", isDirectory: true)
    indexURL = rootURL.appendingPathComponent("LibraryIndex.json")
    self.coordinatesExternalChanges = coordinatesExternalChanges
    let fm = FileManager.default
    if fm.fileExists(atPath: indexURL.path) {
      guard !Self.isSymbolicLink(indexURL) else {
        throw PrompterCoreError.unsafePath(indexURL.path)
      }
      let data = try Data(contentsOf: indexURL)
      let schema = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
      if schema == 1 {
        let backup = rootURL.appendingPathComponent("LibraryIndex.schema1-\(UUID().uuidString).json")
        try data.write(to: backup, options: .withoutOverwriting)
      }
      if let schema, schema > 2 { throw PrompterCoreError.unknownSchema(schema) }
      do {
        let decoded = try JSONDecoder().decode(Index.self, from: data)
        try Self.validate(decoded)
        index = decoded
        index.schemaVersion = 2
      } catch let error as PrompterCoreError { throw error } catch {
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let backup = rootURL.appendingPathComponent(
          "LibraryIndex.corrupt-\(UUID().uuidString).json")
        try data.write(to: backup, options: .withoutOverwriting)
        index = Index()
      }
    } else {
      index = Index()
    }
    for directory in [scriptsURL, trashURL, conflictsURL] {
      if fm.fileExists(atPath: directory.path), Self.isSymbolicLink(directory) {
        throw PrompterCoreError.unsafePath(directory.path)
      }
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var known = Set(index.scripts.map(\.fileName) + index.trash.map(\.metadata.fileName))
    index.scripts.append(contentsOf: try Self.discoverScripts(in: scriptsURL, known: &known))
    for url in try fm.contentsOfDirectory(
      at: trashURL, includingPropertiesForKeys: [.isSymbolicLinkKey])
    where url.pathExtension.lowercased() == "md" && !known.contains(url.lastPathComponent) {
      guard !Self.isSymbolicLink(url) else { continue }
      let markdown = try String(contentsOf: url, encoding: .utf8)
      let now = Date()
      index.trash.append(
        .init(
          metadata: .init(
            title: url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent,
            createdAt: now, modifiedAt: now, contentFingerprint: Self.fingerprint(markdown)),
          deletedAt: now))
    }
    try Self.writeAtomic(index, to: indexURL, coordinated: coordinatesExternalChanges)
  }

  public func listScripts() -> [ScriptMetadata] {
    index.scripts.sorted { $0.modifiedAt > $1.modifiedAt }
  }
  public func discoverExternalScripts() throws -> [ScriptMetadata] {
    try validateManagedDirectories()
    // A file added or removed changes the folder's own modification date, so an unchanged date
    // means there is nothing new to enumerate.
    let scanned = Self.modificationDate(of: scriptsURL)
    if let scanned, lastScriptsScan == scanned { return [] }
    lastScriptsScan = scanned
    var known = Set(index.scripts.map(\.fileName) + index.trash.map(\.metadata.fileName))
    let discovered = try Self.discoverScripts(in: scriptsURL, known: &known)
    guard !discovered.isEmpty else { return [] }
    let old = index
    index.scripts.append(contentsOf: discovered)
    try persist(restoring: old)
    return discovered
  }
  public func listFolders() -> [ScriptFolder] { index.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
  public func createFolder(name: String) throws -> ScriptFolder {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw PrompterCoreError.invalidTitle }
    let old = index
    let folder = ScriptFolder(name: clean)
    index.folders.append(folder)
    try persist(restoring: old)
    return folder
  }
  public func renameFolder(_ id: UUID, name: String) throws {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, let i = index.folders.firstIndex(where: { $0.id == id }) else { throw PrompterCoreError.invalidTitle }
    let old = index
    index.folders[i].name = clean
    try persist(restoring: old)
  }
  public func deleteFolder(_ id: UUID) throws {
    let old = index
    index.scripts = index.scripts.map { var value = $0; if value.folderID == id { value.folderID = nil }; return value }
    index.trash = index.trash.map { var value = $0; if value.metadata.folderID == id { value.metadata.folderID = nil }; return value }
    index.folders.removeAll { $0.id == id }
    try persist(restoring: old)
  }
  public func moveScripts(_ ids: Set<UUID>, to folderID: UUID?) throws {
    if let folderID, !index.folders.contains(where: { $0.id == folderID }) { throw PrompterCoreError.scriptNotFound(folderID) }
    let old = index
    for i in index.scripts.indices where ids.contains(index.scripts[i].id) { index.scripts[i].folderID = folderID }
    try persist(restoring: old)
  }
  public func listTrash() -> [TrashEntry] { index.trash.sorted { $0.deletedAt > $1.deletedAt } }
  public func scriptURL(for id: UUID) throws -> URL {
    try validatedURL(index.scripts[position(of: id)].fileName, in: scriptsURL)
  }
  public func read(_ id: UUID) throws -> ScriptRecord {
    let metadata = index.scripts[try position(of: id)]
    return ScriptRecord(metadata: metadata, markdown: try readText(validatedURL(metadata.fileName, in: scriptsURL)))
  }
  public func create(
    title: String, markdown: String = "", folderID: UUID? = nil, tags: [String] = []
  ) throws -> ScriptRecord {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw PrompterCoreError.invalidTitle }
    let id = UUID()
    let file = "\(safeStem(clean))-\(id.uuidString.lowercased()).md"
    let now = Date()
    let fingerprint = Self.fingerprint(markdown)
    let metadata = ScriptMetadata(
      id: id, title: clean, fileName: file, createdAt: now, modifiedAt: now, revision: 0,
      folderID: folderID, tags: tags, contentFingerprint: fingerprint)
    try validateManagedDirectories()
    try Self.writeAtomic(markdown, to: scriptsURL.appendingPathComponent(file), coordinated: coordinatesExternalChanges)
    index.scripts.append(metadata)
    do { try persistIndex() } catch {
      try? FileManager.default.removeItem(at: scriptsURL.appendingPathComponent(file))
      index.scripts.removeAll { $0.id == id }
      throw error
    }
    return ScriptRecord(metadata: metadata, markdown: markdown)
  }
  public func save(_ id: UUID, markdown: String, expectedFingerprint: String) throws -> ScriptRecord {
    let position = try position(of: id)
    let url = try validatedURL(index.scripts[position].fileName, in: scriptsURL)
    try validateManagedDirectories()
    let oldMetadata = index.scripts[position]
    func saveWithinAccess(_ target: URL) throws {
      let disk = try String(contentsOf: target, encoding: .utf8)
      guard Self.fingerprint(disk) == expectedFingerprint else {
        throw PrompterCoreError.externalConflict(conflictFile: try writeConflict(markdown, for: oldMetadata))
      }
      try Data(markdown.utf8).write(to: target, options: .atomic)
      index.scripts[position].modifiedAt = Date()
      index.scripts[position].revision &+= 1
      index.scripts[position].contentFingerprint = Self.fingerprint(markdown)
      do { try persistIndex() } catch {
        try? Data(disk.utf8).write(to: target, options: .atomic)
        index.scripts[position] = oldMetadata
        throw error
      }
      pushToLinkedFile(position, markdown: markdown)
    }
    if coordinatesExternalChanges {
      var result: Result<Void, Error>!
      var coordinationError: NSError?
      NSFileCoordinator().coordinate(
        writingItemAt: url, options: .forReplacing, error: &coordinationError
      ) { target in result = Result { try saveWithinAccess(target) } }
      if let coordinationError { throw coordinationError }
      try result.get()
    } else {
      try saveWithinAccess(url)
    }
    return ScriptRecord(metadata: index.scripts[position], markdown: markdown)
  }
  public func externalChange(for id: UUID) throws -> ScriptRecord? {
    try syncLinkedFile(id)
    // Nothing can have changed in a file whose modification date has not moved, so the poll does
    // not read or hash it. `syncLinkedFile` may have just rewritten it, which moves the date.
    if let metadata = index.scripts.first(where: { $0.id == id }),
      let url = try? validatedURL(metadata.fileName, in: scriptsURL),
      let modified = Self.modificationDate(of: url)
    {
      if lastExternalRead[id] == modified { return nil }
      lastExternalRead[id] = modified
    }
    let record = try read(id)
    let actual = Self.fingerprint(record.markdown)
    guard actual != record.metadata.contentFingerprint else { return nil }
    var updated = record.metadata
    updated.contentFingerprint = actual
    updated.revision &+= 1
    updated.modifiedAt = Date()
    if let i = index.scripts.firstIndex(where: { $0.id == id }) {
      let old = index
      index.scripts[i] = updated
      try persist(restoring: old)
    }
    return ScriptRecord(metadata: updated, markdown: record.markdown)
  }
  public func updateMetadata(
    _ id: UUID, title: String? = nil, folderID: UUID?? = nil, tags: [String]? = nil
  ) throws -> ScriptMetadata {
    let position = try position(of: id)
    let old = index
    if let title {
      let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty else { throw PrompterCoreError.invalidTitle }
      index.scripts[position].title = clean
    }
    if let folderID { index.scripts[position].folderID = folderID }
    if let tags {
      index.scripts[position].tags = Array(
        Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
      ).sorted()
    }
    index.scripts[position].modifiedAt = Date()
    try persist(restoring: old)
    return index.scripts[position]
  }
  public func duplicate(_ id: UUID, title: String? = nil) throws -> ScriptRecord {
    let source = try read(id)
    return try create(
      title: title ?? "\(source.metadata.title) copy", markdown: source.markdown,
      folderID: source.metadata.folderID, tags: source.metadata.tags)
  }
  public func search(_ query: String) throws -> [ScriptMetadata] {
    let needle = PrompterDocument.normalise(query)
    if needle.isEmpty { return listScripts() }
    var matches: [ScriptMetadata] = []
    for item in index.scripts {
      if PrompterDocument.normalise(item.title).contains(needle)
        || item.tags.contains(where: { PrompterDocument.normalise($0).contains(needle) })
      {
        matches.append(item)
        continue
      }
      let content = try readText(validatedURL(item.fileName, in: scriptsURL))
      if PrompterDocument.normalise(content).contains(needle) { matches.append(item) }
    }
    return matches
  }
  public func delete(_ id: UUID) throws {
    let position = try position(of: id)
    let metadata = index.scripts[position]
    let source = try validatedURL(metadata.fileName, in: scriptsURL)
    let destination = try validatedURL(metadata.fileName, in: trashURL)
    try FileManager.default.moveItem(at: source, to: destination)
    index.scripts.remove(at: position)
    index.trash.append(.init(metadata: metadata, deletedAt: Date()))
    do { try persistIndex() } catch {
      try? FileManager.default.moveItem(
        at: trashURL.appendingPathComponent(metadata.fileName),
        to: scriptsURL.appendingPathComponent(metadata.fileName))
      index.scripts.insert(metadata, at: position)
      index.trash.removeAll { $0.id == id }
      throw error
    }
  }
  public func restore(_ id: UUID) throws -> ScriptRecord {
    guard let position = index.trash.firstIndex(where: { $0.id == id }) else {
      throw PrompterCoreError.scriptNotFound(id)
    }
    let entry = index.trash[position]
    let destination = try validatedURL(entry.metadata.fileName, in: scriptsURL)
    let source = try validatedURL(entry.metadata.fileName, in: trashURL)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw PrompterCoreError.destinationExists
    }
    try FileManager.default.moveItem(at: source, to: destination)
    index.trash.remove(at: position)
    index.scripts.append(entry.metadata)
    do { try persistIndex() } catch {
      try? FileManager.default.moveItem(
        at: destination, to: trashURL.appendingPathComponent(entry.metadata.fileName))
      index.trash.insert(entry, at: position)
      index.scripts.removeAll { $0.id == id }
      throw error
    }
    return try read(id)
  }
  // MARK: Linked external files

  /// Mirror this script to an external Markdown file, so edits on either side reach the other.
  public func link(_ id: UUID, to url: URL) throws -> ScriptMetadata {
    let position = try position(of: id)
    let old = index
    index.scripts[position].linkedPath = url.standardizedFileURL.path
    index.scripts[position].linkedBookmark =
      (try? url.bookmarkData(options: .withSecurityScope)) ?? (try? url.bookmarkData())
    // The fingerprint records what the library copy holds, not what the file holds now: an
    // import seeds the copy from the preview, and a file changed since that preview would
    // otherwise look unchanged and be silently overwritten with the stale preview text.
    index.scripts[position].linkedFingerprint =
      (try? readText(validatedURL(index.scripts[position].fileName, in: scriptsURL))).map(Self.fingerprint)
    lastLinkSync[id] = nil
    try persist(restoring: old)
    return index.scripts[position]
  }
  public func unlink(_ id: UUID) throws -> ScriptMetadata {
    let position = try position(of: id)
    let old = index
    index.scripts[position].linkedPath = nil
    index.scripts[position].linkedBookmark = nil
    index.scripts[position].linkedFingerprint = nil
    lastLinkSync[id] = nil
    try persist(restoring: old)
    return index.scripts[position]
  }
  /// Conflict files written since the last call, for the caller to show once.
  public func takeLinkConflicts() -> [String] {
    defer { linkConflicts.removeAll() }
    return linkConflicts
  }

  /// Pull an external edit into the library copy, push an in-app edit out, and when both
  /// sides moved keep the in-app version in Conflicts and let the disk version win.
  private func syncLinkedFile(_ id: UUID) throws {
    guard let position = index.scripts.firstIndex(where: { $0.id == id }),
      index.scripts[position].linkedPath != nil,
      let link = Self.resolveLink(index.scripts[position])
    else { return }
    // Two coordinated reads per linked script every two seconds is most of the poll's cost,
    // and an untouched file cannot have changed either side.
    let modified = Self.modificationDate(of: link)
    guard lastLinkSync[id] != modified || modified == nil else { return }
    defer { lastLinkSync[id] = Self.modificationDate(of: link) }
    let metadata = index.scripts[position]
    let libraryURL = try validatedURL(metadata.fileName, in: scriptsURL)
    // A missing or unreadable file leaves the library copy exactly as it is; the
    // indicator reads `linkedPath` and shows the link as broken.
    guard let disk = try? Self.withLinkAccess(link, readText) else { return }
    let local = try readText(libraryURL)
    let diskPrint = Self.fingerprint(disk)
    let localPrint = Self.fingerprint(local)
    if diskPrint == localPrint {
      guard metadata.linkedFingerprint != diskPrint else { return }
      index.scripts[position].linkedFingerprint = diskPrint
      try persistIndex()
      return
    }
    if diskPrint == metadata.linkedFingerprint {
      try Self.withLinkAccess(link) { try writeText(local, to: $0) }
      index.scripts[position].linkedFingerprint = localPrint
      try persistIndex()
      return
    }
    if localPrint != metadata.linkedFingerprint {
      linkConflicts.append(try writeConflict(local, for: metadata))
    }
    try writeText(disk, to: libraryURL)
    index.scripts[position].linkedFingerprint = diskPrint
    try persistIndex()
  }
  /// An in-app edit reaches the linked file too, unless the file has moved on ahead of
  /// us: that is a genuine conflict and `syncLinkedFile` resolves it on the next pass.
  private func pushToLinkedFile(_ position: Int, markdown: String) {
    let metadata = index.scripts[position]
    guard metadata.linkedPath != nil, let link = Self.resolveLink(metadata),
      let disk = try? Self.withLinkAccess(link, readText), Self.fingerprint(disk) == metadata.linkedFingerprint
    else { return }
    do {
      try Self.withLinkAccess(link) { try writeText(markdown, to: $0) }
      index.scripts[position].linkedFingerprint = Self.fingerprint(markdown)
      try persistIndex()
    } catch {
      // Let the next poll retry rather than skip the file on an unchanged date.
      lastLinkSync[metadata.id] = nil
    }
  }
  private static func resolveLink(_ metadata: ScriptMetadata) -> URL? {
    var stale = false
    if let data = metadata.linkedBookmark {
      for options: URL.BookmarkResolutionOptions in [.withSecurityScope, []] {
        if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
          return url
        }
      }
    }
    // ponytail: a stale bookmark is never rewritten; relink by hand if a moved file stops resolving.
    return metadata.linkedPath.map { URL(fileURLWithPath: $0) }
  }
  private static func modificationDate(of url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
  private static func withLinkAccess<T>(_ url: URL, _ body: (URL) throws -> T) rethrows -> T {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try body(url)
  }

  private func persistIndex() throws {
    try validateManagedDirectories()
    try Self.writeAtomic(index, to: indexURL, coordinated: coordinatesExternalChanges)
  }
  /// Saves the index; on failure puts back `old`, the index from before the change, and rethrows.
  private func persist(restoring old: Index) throws {
    do { try persistIndex() } catch { index = old; throw error }
  }
  private func position(of id: UUID) throws -> Int {
    guard let position = index.scripts.firstIndex(where: { $0.id == id }) else { throw PrompterCoreError.scriptNotFound(id) }
    return position
  }
  private func readText(_ url: URL) throws -> String {
    try Self.coordinatedRead(url, coordinated: coordinatesExternalChanges)
  }
  private func writeText(_ text: String, to url: URL) throws {
    try Self.coordinatedWrite(Data(text.utf8), to: url, coordinated: coordinatesExternalChanges)
  }
  /// Keeps the in-app version beside the library as `<name>-local-<uuid>.md`; returns the file name.
  private func writeConflict(_ markdown: String, for metadata: ScriptMetadata) throws -> String {
    let url = conflictsURL.appendingPathComponent(
      "\(metadata.fileName.dropLast(3))-local-\(UUID().uuidString.lowercased()).md")
    try Self.writeAtomic(markdown, to: url, coordinated: false)
    return url.lastPathComponent
  }
  private static func discoverScripts(in directory: URL, known: inout Set<String>) throws -> [ScriptMetadata] {
    var discovered: [ScriptMetadata] = []
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    where url.pathExtension.lowercased() == "md" && !known.contains(url.lastPathComponent) {
      guard !isSymbolicLink(url),
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        let markdown = try? String(contentsOf: url, encoding: .utf8)
      else { continue }
      let now = Date()
      discovered.append(.init(
        title: url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent,
        createdAt: now, modifiedAt: now, contentFingerprint: fingerprint(markdown)))
      known.insert(url.lastPathComponent)
    }
    return discovered
  }
  private func safeStem(_ value: String) -> String {
    String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-")
      .joined(separator: "-").prefix(60) + ""
  }
  public static func fingerprint(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }
  private func validatedURL(_ name: String, in directory: URL) throws -> URL {
    try validateManagedDirectories()
    guard Self.isPlainMarkdownName(name) else { throw PrompterCoreError.unsafePath(name) }
    let url = directory.appendingPathComponent(name)
    if Self.isSymbolicLink(url) { throw PrompterCoreError.unsafePath(url.path) }
    return url
  }
  private func validateManagedDirectories() throws {
    for url in [scriptsURL, trashURL, conflictsURL, indexURL] where Self.isSymbolicLink(url) {
      throw PrompterCoreError.unsafePath(url.path)
    }
  }
  private static func isPlainMarkdownName(_ name: String) -> Bool {
    name == URL(fileURLWithPath: name).lastPathComponent && !name.contains("/") && !name.contains("\\")
      && name.lowercased().hasSuffix(".md")
  }
  private static func validate(_ value: Index) throws {
    var ids = Set<UUID>()
    var names = Set<String>()
    for item in value.scripts + value.trash.map(\.metadata) {
      guard ids.insert(item.id).inserted, names.insert(item.fileName).inserted, isPlainMarkdownName(item.fileName)
      else { throw PrompterCoreError.corruptIndex }
    }
  }
  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
      == .typeSymbolicLink
  }
  private static func coordinatedRead(_ url: URL, coordinated: Bool) throws -> String {
    guard coordinated else { return try String(contentsOf: url, encoding: .utf8) }
    var result: Result<String, Error>!
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      coordinated in result = Result { try String(contentsOf: coordinated, encoding: .utf8) }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
  }
  private static func writeAtomic<T: Encodable>(_ value: T, to url: URL, coordinated: Bool) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try coordinatedWrite(encoder.encode(value), to: url, coordinated: coordinated)
  }
  private static func writeAtomic(_ value: String, to url: URL, coordinated: Bool) throws {
    try coordinatedWrite(Data(value.utf8), to: url, coordinated: coordinated)
  }
  /// Writes in place under the coordinator. It deliberately does not stage a sibling and
  /// `replaceItemAt` it: the sibling landed in the user's own vault folder, and replacing the
  /// item gave the file a new identity, which breaks bookmarks and other apps' open handles.
  private static func coordinatedWrite(_ data: Data, to url: URL, coordinated: Bool) throws {
    guard coordinated else {
      try data.write(to: url, options: .atomic)
      return
    }
    var result: Result<Void, Error>!
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) {
      // ponytail: written in place, not atomically. An atomic write is a rename over the
      // original, which makes the file a new one and leaves bookmarks stale (proved by
      // `testCoordinatedWriteBackKeepsTheFileItself`). The coordinator keeps other apps out
      // for the duration; a crash mid-write is the residual risk.
      coordinated in result = Result { try data.write(to: coordinated) }
    }
    if let coordinationError { throw coordinationError }
    try result.get()
  }
}
