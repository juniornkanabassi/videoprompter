import Foundation
import PrompterCore
import SwiftUI

/// Keeps the library in step with a "Video Prompter" folder in iCloud Drive, which the iPad app
/// reads and writes. Each script is linked to one Markdown file there, so the library's tested
/// two-way linked-file sync does the work: an edit on either side reaches the other, and an edit
/// on both keeps the in-app version in the Conflicts folder.
///
/// - A script with no link gets a file in the folder (in a subfolder named after its library
///   folder) and is linked to it.
/// - A file nobody links to is a script made on the iPad, and is imported as a linked script.
/// - A file whose script is in the library's Trash was deleted here, so the file goes to the
///   Finder Trash; a linked file deleted on the iPad sends its script to the library's Trash.
/// - A script linked to a file elsewhere (a Content Creation or Obsidian note, say) keeps that
///   file as its master and gets a mirror copy in the folder instead, kept in step both ways:
///   an edit on the iPad reaches the script, and so its own file; an edit here or in that file
///   reaches the mirror. Deleting a mirror on the iPad only stops the mirroring.
/// - Presets are shared through `Video Prompter presets.json` in the same folder.
@MainActor enum ICloudScripts {
  static let enabledKey = "keepScriptsInICloud"
  /// Set when the setting goes off, and cleared once every iCloud link has been undone, so a
  /// failed unlink (a full disk, say) is tried again on the poll and after a relaunch.
  static let unlinkPendingKey = "unlinkICloudScriptsPending"
  static let presetsFileName = "Video Prompter presets.json"
  /// The poll runs every two seconds; this pass checks every link, so it runs at most every five.
  /// The pass in progress, if any, so turning the setting off can wait for it.
  static var pass: Task<Void, Never>?
  static var lastPass = Date.distantPast

  /// Tests point this at a throwaway folder so they never touch the real iCloud Drive.
  static var cloudDocsOverride: URL?
  static var cloudDocs: URL {
    cloudDocsOverride ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
  }
  static var folder: URL { cloudDocs.appendingPathComponent("Video Prompter", isDirectory: true) }
  static var isAvailable: Bool { FileManager.default.fileExists(atPath: cloudDocs.path) }

  /// The folder's Markdown files, one level of subfolders deep, the same depth the iPad reads.
  /// Files iCloud has moved off this Mac are asked back.
  static func files() -> [URL] {
    var result: [URL] = []
    func scan(_ directory: URL, depth: Int) {
      let entries = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
      for url in entries {
        let name = url.lastPathComponent
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          if depth == 0, !name.hasPrefix(".") { scan(url, depth: 1) }
        } else if name.hasPrefix("."), name.hasSuffix(".md.icloud") {
          let real = directory.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
          try? FileManager.default.startDownloadingUbiquitousItem(at: real)
        } else if url.pathExtension.lowercased() == "md" {
          result.append(url.standardizedFileURL)
        }
      }
    }
    scan(folder, depth: 0)
    return result
  }

  /// A mirror copy in iCloud Drive of a script whose master is a file elsewhere, and the text
  /// both sides agreed on at the last pass, to tell which side changed since.
  struct Mirror: Codable, Equatable {
    var path: String
    var fingerprint: String
  }
  static let mirrorsKey = "iCloudScriptMirrors"
  static let declinedMirrorsKey = "iCloudScriptMirrorsDeclined"

  static var mirrors: [UUID: Mirror] {
    get {
      UserDefaults.standard.data(forKey: mirrorsKey)
        .flatMap { try? JSONDecoder().decode([UUID: Mirror].self, from: $0) } ?? [:]
    }
    set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: mirrorsKey) }
  }
  /// Scripts whose mirror was deleted on the iPad, so it is not made again.
  static var declinedMirrors: Set<UUID> {
    get { Set((UserDefaults.standard.stringArray(forKey: declinedMirrorsKey) ?? []).compactMap(UUID.init(uuidString:))) }
    set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: declinedMirrorsKey) }
  }

  /// The file is there, or iCloud has it but has not brought it to this Mac yet.
  static func exists(_ url: URL) -> Bool {
    let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
  }

  static func isInside(_ url: URL) -> Bool {
    url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
  }
  static func isInside(path: String) -> Bool { isInside(URL(fileURLWithPath: path)) }

  /// A title made safe as a file or folder name.
  static func safeName(_ title: String) -> String {
    let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t"))
      .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    return stem.hasPrefix(".") ? "Script " + stem : stem
  }

  /// A file name for a title that is not taken in `directory`.
  static func freeURL(for title: String, in directory: URL) -> URL {
    let stem = safeName(title)
    var candidate = directory.appendingPathComponent(stem + ".md")
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(stem) \(n).md")
      n += 1
    }
    return candidate
  }

  static func write(_ text: String, to url: URL) throws {
    var coordinationError: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
      do { try Data(text.utf8).write(to: target, options: .atomic) } catch { failure = error }
    }
    if let error = failure ?? coordinationError { throw error }
  }

  static func read(_ url: URL) -> String? {
    var text: String?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
      text = try? String(contentsOf: target, encoding: .utf8)
    }
    return text
  }

  static func encodePresets(_ presets: [PrompterSettings]) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(presets)).flatMap { String(data: $0, encoding: .utf8) }
  }
}

extension AppStore {
  var keepsScriptsInICloud: Bool {
    get { UserDefaults.standard.bool(forKey: ICloudScripts.enabledKey) }
    set {
      objectWillChange.send()
      UserDefaults.standard.set(newValue, forKey: ICloudScripts.enabledKey)
      UserDefaults.standard.set(!newValue, forKey: ICloudScripts.unlinkPendingKey)
      Task { newValue ? await syncICloudScripts() : await unlinkICloudScripts(reportingFailure: true) }
    }
  }

  /// Turning the setting off stops the sharing, not just the copying of new scripts: every
  /// script linked into the iCloud folder goes back to its library copy, so nothing more is
  /// written there or read from there. The files already in iCloud Drive stay where they are.
  func unlinkICloudScripts(reportingFailure: Bool = false) async {
    // A pass already under way finishes first (it stops at its next check of the setting), so
    // it cannot link a script after this has unlinked them.
    await ICloudScripts.pass?.value
    guard let library else { return }
    let states = await library.linkStates()
    var failed = 0
    for (id, state) in states {
      let inside: Bool
      switch state {
      case .resolved(let url), .staleBookmark(let url): inside = ICloudScripts.isInside(url)
      case .missing(let path): inside = ICloudScripts.isInside(path: path)
      default: inside = false
      }
      guard inside else { continue }
      guard let metadata = try? await library.unlink(id) else { failed += 1; continue }
      if let i = scripts.firstIndex(where: { $0.id == id }) { scripts[i].metadata = metadata }
    }
    // Turned back on meanwhile: the links are wanted again, so nothing is left pending.
    if failed == 0 || keepsScriptsInICloud {
      UserDefaults.standard.set(false, forKey: ICloudScripts.unlinkPendingKey)
    } else if reportingFailure {
      errorMessage = "\(failed) script\(failed == 1 ? "" : "s") could not be unlinked from iCloud Drive yet. Video Prompter will keep trying."
    }
    await refreshLinkStates()
  }

  /// One pass of the iCloud folder sync. Runs on the library's two-second poll while it is on.
  func syncICloudScripts() async {
    if !keepsScriptsInICloud, UserDefaults.standard.bool(forKey: ICloudScripts.unlinkPendingKey),
      ICloudScripts.pass == nil, Date().timeIntervalSince(ICloudScripts.lastPass) >= 5
    {
      ICloudScripts.lastPass = Date()
      await unlinkICloudScripts()
      return
    }
    guard keepsScriptsInICloud, library != nil, ICloudScripts.isAvailable, ICloudScripts.pass == nil,
      Date().timeIntervalSince(ICloudScripts.lastPass) >= 5 else { return }
    ICloudScripts.lastPass = Date()
    let pass = Task { await runICloudPass() }
    ICloudScripts.pass = pass
    await pass.value
    ICloudScripts.pass = nil
  }

  private func runICloudPass() async {
    var changed = false
    await runICloudSteps(changed: &changed)
    // Even a pass cut short by the setting going off shows what it already changed.
    if changed { await reload() }
  }

  private func runICloudSteps(changed: inout Bool) async {
    guard let library else { return }
    let fm = FileManager.default
    do { try fm.createDirectory(at: ICloudScripts.folder, withIntermediateDirectories: true) } catch {
      errorMessage = "The Video Prompter folder in iCloud Drive could not be created. \(error.localizedDescription)"
      keepsScriptsInICloud = false
      return
    }
    let states = await library.linkStates()
    let folders = Dictionary(uniqueKeysWithValues: await library.listFolders().map { ($0.id, $0.name) })
    // Mirrors are never new scripts from the iPad, whatever state their script is in.
    var linked = Set(ICloudScripts.mirrors.values.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
    for metadata in await library.listScripts() {
      // Turned off mid-pass: stop here, before anything more is written or deleted.
      guard keepsScriptsInICloud else { return }
      switch states[metadata.id] {
      case .resolved(let url), .staleBookmark(let url):
        if ICloudScripts.isInside(url) {
          linked.insert(url.standardizedFileURL.path)
        } else {
          do {
            try mirrorLinkedScript(metadata, folders: folders, linked: &linked)
          } catch {
            errorMessage = "“\(metadata.title)” could not be mirrored to iCloud Drive. \(error.localizedDescription)"
          }
        }
      case .missing(let path) where ICloudScripts.isInside(path: path):
        // Deleted on the iPad. The script goes to the library's Trash, where it can be restored.
        if !fm.fileExists(atPath: path), (try? await library.delete(metadata.id)) != nil {
          session.forgetScript(metadata.id)
          MacGoogleDocs.links[metadata.id] = nil
          changed = true
        }
      case .none, .unlinked:
        // Not yet in iCloud: write it out and link it. A script linked to some other file
        // (an Obsidian note, say) keeps that link and stays on the Mac only.
        do {
          let record = try await library.read(metadata.id)
          guard keepsScriptsInICloud else { return }
          var directory = ICloudScripts.folder
          if let name = metadata.folderID.flatMap({ folders[$0] }) {
            directory.appendPathComponent(ICloudScripts.safeName(name), isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
          }
          let url = ICloudScripts.freeURL(for: metadata.title, in: directory)
          try ICloudScripts.write(record.markdown, to: url)
          _ = try await library.link(metadata.id, to: url)
          linked.insert(url.standardizedFileURL.path)
          changed = true
        } catch {
          errorMessage = "“\(metadata.title)” could not be copied to iCloud Drive. \(error.localizedDescription)"
        }
      default:
        break
      }
    }
    let trash = await library.listTrash()
    let trashed = Set(trash.compactMap(\.metadata.linkedPath)
      .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    // A mirrored script deleted here: its mirror goes to the Finder Trash, so the iPad loses it.
    guard keepsScriptsInICloud else { return }
    var mirrors = ICloudScripts.mirrors
    for item in trash {
      guard let mirror = mirrors.removeValue(forKey: item.metadata.id) else { continue }
      try? fm.trashItem(at: URL(fileURLWithPath: mirror.path), resultingItemURL: nil)
    }
    ICloudScripts.mirrors = mirrors
    let folderIDs = Dictionary(await library.listFolders().map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    guard keepsScriptsInICloud else { return }
    for url in ICloudScripts.files() where !linked.contains(url.path) {
      guard keepsScriptsInICloud else { return }
      if trashed.contains(url.path) {
        // Deleted here: the iPad should lose it too.
        try? fm.trashItem(at: url, resultingItemURL: nil)
        continue
      }
      // New on the iPad (or dropped in from Finder): import it, linked, into the matching folder.
      guard let markdown = ICloudScripts.read(url) else { continue }
      let parent = url.deletingLastPathComponent()
      var folderID: UUID?
      if parent.standardizedFileURL.path != ICloudScripts.folder.standardizedFileURL.path {
        let name = parent.lastPathComponent
        folderID = folderIDs[name]
        if folderID == nil { folderID = try? await library.createFolder(name: name).id }
      }
      guard keepsScriptsInICloud else { return }
      do {
        _ = try await library.createLinked(
          title: url.deletingPathExtension().lastPathComponent, markdown: markdown, folderID: folderID, to: url)
        changed = true
      } catch {
        errorMessage = "“\(url.lastPathComponent)” from iCloud Drive could not be added. \(error.localizedDescription)"
      }
    }
    if keepsScriptsInICloud { syncICloudPresets() }
  }

  /// Keeps the mirror of a script linked to a file outside iCloud Drive in step with it. The
  /// script's text here already follows its own file, so only the mirror needs handling.
  private func mirrorLinkedScript(
    _ metadata: ScriptMetadata, folders: [UUID: String], linked: inout Set<String>
  ) throws {
    let id = metadata.id
    guard !ICloudScripts.declinedMirrors.contains(id),
      let text = scripts.first(where: { $0.id == id })?.markdown
    else { return }
    let ours = MarkdownLibrary.fingerprint(text)
    guard let mirror = ICloudScripts.mirrors[id] else {
      var directory = ICloudScripts.folder
      if let name = metadata.folderID.flatMap({ folders[$0] }) {
        directory.appendPathComponent(ICloudScripts.safeName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      let url = ICloudScripts.freeURL(for: metadata.title, in: directory)
      try ICloudScripts.write(text, to: url)
      ICloudScripts.mirrors[id] = .init(path: url.standardizedFileURL.path, fingerprint: ours)
      linked.insert(url.standardizedFileURL.path)
      return
    }
    let url = URL(fileURLWithPath: mirror.path)
    guard ICloudScripts.exists(url) else {
      // Deleted on the iPad. The script's master is its own file here, so the script stays and
      // is simply no longer mirrored.
      ICloudScripts.mirrors[id] = nil
      ICloudScripts.declinedMirrors.insert(id)
      return
    }
    // Still downloading: next pass.
    guard let mirrored = ICloudScripts.read(url) else { return }
    let theirs = MarkdownLibrary.fingerprint(mirrored)
    if ours == theirs {
      if mirror.fingerprint != ours { ICloudScripts.mirrors[id]?.fingerprint = ours }
    } else if ours == mirror.fingerprint {
      // Edited on the iPad: it becomes an edit here, which the library saves to the script's file.
      updateMarkdown(mirrored, for: id)
      ICloudScripts.mirrors[id]?.fingerprint = theirs
    } else {
      if theirs != mirror.fingerprint {
        // Edited on both sides: this side wins, and the iPad's version is kept beside it as a
        // new script, so nothing is lost.
        let copy = ICloudScripts.freeURL(for: metadata.title + " (iPad edit)", in: url.deletingLastPathComponent())
        try ICloudScripts.write(mirrored, to: copy)
      }
      try ICloudScripts.write(text, to: url)
      ICloudScripts.mirrors[id]?.fingerprint = ours
    }
  }

  /// Presets: whichever side changed since the last pass wins, so a preset saved on the iPad
  /// arrives here and one saved here reaches the iPad.
  private func syncICloudPresets() {
    let url = ICloudScripts.folder.appendingPathComponent(ICloudScripts.presetsFileName)
    let lastSeenKey = "iCloudPresetsFingerprint"
    let defaults = UserDefaults.standard
    let fileText = ICloudScripts.read(url)
    let lastSeen = defaults.string(forKey: lastSeenKey)
    if let fileText, MarkdownLibrary.fingerprint(fileText) != lastSeen,
      let shared = try? JSONDecoder().decode([PrompterSettings].self, from: Data(fileText.utf8))
    {
      defaults.set(MarkdownLibrary.fingerprint(fileText), forKey: lastSeenKey)
      if shared != presets { presets = shared }
      return
    }
    guard let ours = ICloudScripts.encodePresets(presets), ours != fileText else { return }
    if (try? ICloudScripts.write(ours, to: url)) != nil {
      defaults.set(MarkdownLibrary.fingerprint(ours), forKey: lastSeenKey)
    }
  }
}

/// File › Keep Scripts in iCloud Drive for iPad.
struct ICloudCommands: Commands {
  @ObservedObject var store: AppStore
  var body: some Commands {
    CommandGroup(after: .importExport) {
      Toggle("Keep Scripts in iCloud Drive for iPad", isOn: Binding(
        get: { store.keepsScriptsInICloud },
        set: { store.keepsScriptsInICloud = $0 }))
        .disabled(!ICloudScripts.isAvailable)
        .help("Copies every script to iCloud Drive › Video Prompter and keeps it in step with Video Prompter on iPad")
    }
  }
}
