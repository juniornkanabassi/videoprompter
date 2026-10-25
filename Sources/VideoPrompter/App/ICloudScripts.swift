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
/// - Presets are shared through `Video Prompter presets.json` in the same folder.
@MainActor enum ICloudScripts {
  static let enabledKey = "keepScriptsInICloud"
  static let presetsFileName = "Video Prompter presets.json"
  /// The poll runs every two seconds; this pass checks every link, so it runs at most every five.
  static var lastPass = Date.distantPast

  static var cloudDocs: URL {
    FileManager.default.homeDirectoryForCurrentUser
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
      if newValue { Task { await syncICloudScripts() } }
    }
  }

  /// One pass of the iCloud folder sync. Runs on the library's two-second poll while it is on.
  func syncICloudScripts() async {
    guard keepsScriptsInICloud, let library, ICloudScripts.isAvailable,
      Date().timeIntervalSince(ICloudScripts.lastPass) >= 5 else { return }
    ICloudScripts.lastPass = Date()
    let fm = FileManager.default
    do { try fm.createDirectory(at: ICloudScripts.folder, withIntermediateDirectories: true) } catch {
      errorMessage = "The Video Prompter folder in iCloud Drive could not be created. \(error.localizedDescription)"
      keepsScriptsInICloud = false
      return
    }
    var changed = false
    let states = await library.linkStates()
    let folders = Dictionary(uniqueKeysWithValues: await library.listFolders().map { ($0.id, $0.name) })
    var linked = Set<String>()
    for metadata in await library.listScripts() {
      switch states[metadata.id] {
      case .resolved(let url), .staleBookmark(let url):
        if ICloudScripts.isInside(url) { linked.insert(url.standardizedFileURL.path) }
      case .missing(let path) where ICloudScripts.isInside(path: path):
        // Deleted on the iPad. The script goes to the library's Trash, where it can be restored.
        if !fm.fileExists(atPath: path) {
          try? await library.delete(metadata.id)
          changed = true
        }
      case .none, .unlinked:
        // Not yet in iCloud: write it out and link it. A script linked to some other file
        // (an Obsidian note, say) keeps that link and stays on the Mac only.
        do {
          let record = try await library.read(metadata.id)
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
    let trashed = Set(await library.listTrash().compactMap(\.metadata.linkedPath)
      .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    let folderIDs = Dictionary(await library.listFolders().map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    for url in ICloudScripts.files() where !linked.contains(url.path) {
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
      do {
        _ = try await library.createLinked(
          title: url.deletingPathExtension().lastPathComponent, markdown: markdown, folderID: folderID, to: url)
        changed = true
      } catch {
        errorMessage = "“\(url.lastPathComponent)” from iCloud Drive could not be added. \(error.localizedDescription)"
      }
    }
    syncICloudPresets()
    if changed { await reload() }
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
