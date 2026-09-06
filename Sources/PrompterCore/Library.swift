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
    enum CodingKeys: String, CodingKey { case schemaVersion, scripts, trash, folders }
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
      if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int == 1 {
        let backup = rootURL.appendingPathComponent("LibraryIndex.schema1-\(UUID().uuidString).json")
        try data.write(to: backup, options: .withoutOverwriting)
      }
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let schema = object["schemaVersion"] as? Int, schema > 2
      {
        throw PrompterCoreError.unknownSchema(schema)
      }
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
    var known = Set(index.scripts.map(\.fileName))
    known.formUnion(index.trash.map { $0.metadata.fileName })
    for url in try fm.contentsOfDirectory(
      at: scriptsURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    where url.pathExtension.lowercased() == "md" && !known.contains(url.lastPathComponent) {
      guard !Self.isSymbolicLink(url) else { continue }
      let markdown = try String(contentsOf: url, encoding: .utf8)
      let now = Date()
      index.scripts.append(
        .init(
          title: url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent,
          createdAt: now, modifiedAt: now, contentFingerprint: Self.fingerprint(markdown)))
    }
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
  public func listFolders() -> [ScriptFolder] { index.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
  public func createFolder(name: String) throws -> ScriptFolder {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw PrompterCoreError.invalidTitle }
    let old = index.folders
    let folder = ScriptFolder(name: clean); index.folders.append(folder)
    do { try persistIndex() } catch { index.folders = old; throw error }
    return folder
  }
  public func renameFolder(_ id: UUID, name: String) throws {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, let index = index.folders.firstIndex(where: { $0.id == id }) else { throw PrompterCoreError.invalidTitle }
    let old = self.index.folders[index]; self.index.folders[index].name = clean
    do { try persistIndex() } catch { self.index.folders[index] = old; throw error }
  }
  public func deleteFolder(_ id: UUID) throws {
    let oldScripts = index.scripts, oldTrash = index.trash, oldFolders = index.folders
    index.scripts = index.scripts.map { var value = $0; if value.folderID == id { value.folderID = nil }; return value }
    index.trash = index.trash.map { var value = $0; if value.metadata.folderID == id { value.metadata.folderID = nil }; return value }
    index.folders.removeAll { $0.id == id }
    do { try persistIndex() } catch { index.scripts = oldScripts; index.trash = oldTrash; index.folders = oldFolders; throw error }
  }
  public func moveScripts(_ ids: Set<UUID>, to folderID: UUID?) throws {
    if let folderID, !index.folders.contains(where: { $0.id == folderID }) { throw PrompterCoreError.scriptNotFound(folderID) }
    let old = index.scripts
    for i in index.scripts.indices where ids.contains(index.scripts[i].id) { index.scripts[i].folderID = folderID }
    do { try persistIndex() } catch { index.scripts = old; throw error }
  }
  public func listTrash() -> [TrashEntry] { index.trash.sorted { $0.deletedAt > $1.deletedAt } }
  public func scriptURL(for id: UUID) throws -> URL {
    guard let item = index.scripts.first(where: { $0.id == id }) else {
      throw PrompterCoreError.scriptNotFound(id)
    }
    return try validatedURL(item.fileName, in: scriptsURL)
  }
  public func read(_ id: UUID) throws -> ScriptRecord {
    guard let metadata = index.scripts.first(where: { $0.id == id }) else {
      throw PrompterCoreError.scriptNotFound(id)
    }
    let markdown = try Self.coordinatedRead(
      try validatedURL(metadata.fileName, in: scriptsURL), coordinated: coordinatesExternalChanges)
    return ScriptRecord(metadata: metadata, markdown: markdown)
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
    try Self.writeAtomic(
      markdown, to: scriptsURL.appendingPathComponent(file), coordinated: coordinatesExternalChanges
    )
    index.scripts.append(metadata)
    do { try persistIndex() } catch {
      try? FileManager.default.removeItem(at: scriptsURL.appendingPathComponent(file))
      index.scripts.removeAll { $0.id == id }
      throw error
    }
    return ScriptRecord(metadata: metadata, markdown: markdown)
  }
  public func save(_ id: UUID, markdown: String, expectedFingerprint: String) throws -> ScriptRecord
  {
    guard let position = index.scripts.firstIndex(where: { $0.id == id }) else {
      throw PrompterCoreError.scriptNotFound(id)
    }
    let url = try validatedURL(index.scripts[position].fileName, in: scriptsURL)
    try validateManagedDirectories()
    let oldMetadata = index.scripts[position]
    func saveWithinAccess(_ target: URL) throws {
      let disk = try String(contentsOf: target, encoding: .utf8)
      guard Self.fingerprint(disk) == expectedFingerprint else {
        let conflictURL = conflictsURL.appendingPathComponent(
          "\(oldMetadata.fileName.dropLast(3))-local-\(UUID().uuidString.lowercased()).md")
        try Self.writeAtomic(markdown, to: conflictURL, coordinated: false)
        throw PrompterCoreError.externalConflict(conflictFile: conflictURL.lastPathComponent)
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
    let record = try read(id)
    let actual = Self.fingerprint(record.markdown)
    guard actual != record.metadata.contentFingerprint else { return nil }
    var updated = record.metadata
    updated.contentFingerprint = actual
    updated.revision &+= 1
    updated.modifiedAt = Date()
    if let i = index.scripts.firstIndex(where: { $0.id == id }) {
      let old = index.scripts[i]
      index.scripts[i] = updated
      do { try persistIndex() } catch {
        index.scripts[i] = old
        throw error
      }
    }
    return ScriptRecord(metadata: updated, markdown: record.markdown)
  }
  public func updateMetadata(
    _ id: UUID, title: String? = nil, folderID: UUID?? = nil, tags: [String]? = nil
  ) throws -> ScriptMetadata {
    guard let position = index.scripts.firstIndex(where: { $0.id == id }) else {
      throw PrompterCoreError.scriptNotFound(id)
    }
    let old = index.scripts[position]
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
    do { try persistIndex() } catch {
      index.scripts[position] = old
      throw error
    }
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
      let content = try Self.coordinatedRead(
        validatedURL(item.fileName, in: scriptsURL), coordinated: coordinatesExternalChanges)
      if PrompterDocument.normalise(content).contains(needle) { matches.append(item) }
    }
    return matches
  }
  public func delete(_ id: UUID) throws {
    guard let position = index.scripts.firstIndex(where: { $0.id == id }) else {
      throw PrompterCoreError.scriptNotFound(id)
    }
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
  private func persistIndex() throws {
    try validateManagedDirectories()
    try Self.writeAtomic(index, to: indexURL, coordinated: coordinatesExternalChanges)
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
    guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("/"),
      !name.contains("\\"), name.lowercased().hasSuffix(".md")
    else { throw PrompterCoreError.unsafePath(name) }
    let url = directory.appendingPathComponent(name)
    if Self.isSymbolicLink(url) { throw PrompterCoreError.unsafePath(url.path) }
    return url
  }
  private func validateManagedDirectories() throws {
    for directory in [scriptsURL, trashURL, conflictsURL] {
      guard !Self.isSymbolicLink(directory) else {
        throw PrompterCoreError.unsafePath(directory.path)
      }
    }
    guard !Self.isSymbolicLink(indexURL) else { throw PrompterCoreError.unsafePath(indexURL.path) }
  }
  private static func validate(_ value: Index) throws {
    var ids = Set<UUID>()
    var names = Set<String>()
    for item in value.scripts + value.trash.map(\.metadata) {
      guard ids.insert(item.id).inserted, names.insert(item.fileName).inserted,
        item.fileName == URL(fileURLWithPath: item.fileName).lastPathComponent,
        !item.fileName.contains("/"), !item.fileName.contains("\\"),
        item.fileName.lowercased().hasSuffix(".md")
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
  private static func coordinatedWrite(_ data: Data, to url: URL, coordinated: Bool) throws {
    guard coordinated, FileManager.default.fileExists(atPath: url.path) else {
      try data.write(to: url, options: .atomic)
      return
    }
    let staged = url.deletingLastPathComponent().appendingPathComponent(
      ".jp-stage-\(UUID().uuidString)")
    try data.write(to: staged, options: .withoutOverwriting)
    var result: Result<Void, Error>!
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(
      writingItemAt: url, options: .forReplacing, error: &coordinationError
    ) { coordinated in
      result = Result { _ = try FileManager.default.replaceItemAt(coordinated, withItemAt: staged) }
    }
    if let coordinationError {
      try? FileManager.default.removeItem(at: staged)
      throw coordinationError
    }
    do { try result.get() } catch {
      try? FileManager.default.removeItem(at: staged)
      throw error
    }
  }
}
