import AppKit
import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

/// A file that might be the moved script. Nothing is read or changed until the user picks one.
private struct RelinkCandidate: Identifiable {
  let url: URL
  let sameName: Bool
  let sameContent: Bool
  var id: URL { url }
  var score: Int { (sameName ? 1 : 0) + (sameContent ? 2 : 0) }
}

/// Recovery for a linked file that has moved: find it (only when asked) or choose it, show what
/// was selected, and let the user say which side's text wins before anything is written.
struct RelinkSheet: View {
  @ObservedObject var store: AppStore
  let script: ScriptRecord
  @Environment(\.dismiss) private var dismiss
  @State private var candidates: [RelinkCandidate]?
  @State private var searching = false
  @State private var chosen: URL?
  @State private var problem: String?

  private var savedPath: String { script.metadata.linkedPath ?? "" }
  private var isNewLink: Bool { script.metadata.linkedPath == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(isNewLink ? "Link" : "Relink") “\(script.metadata.title)”").font(.headline)
      Text(isNewLink ? "Choose the Markdown file this script should follow." : "The linked file is no longer at \(savedPath).")
        .font(.callout).foregroundStyle(.secondary)
      if let chosen { confirmation(chosen) } else { picker }
      if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).help("Close without linking a file")
      }
    }.padding(24).frame(minWidth: 520)
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        if !isNewLink { Button("Search for It") { Task { await search() } }.disabled(searching).help("Search indexed files for a matching name or text") }
        Button("Choose File…") { chooseFile() }.help("Select the Markdown file to link")
        if searching { ProgressView().controlSize(.small) }
      }
      if let candidates {
        if candidates.isEmpty {
          Text("No matching file was found. A file on an external or unindexed volume may need Choose File.").font(.callout)
        } else {
          Text(candidates.count == 1 ? "One likely match:" : "Several files match. Pick the right one, or choose it yourself:")
            .font(.callout)
          ForEach(candidates) { candidate in
            Button { Task { await select(candidate.url) } } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(candidate.url.path).lineLimit(1).truncationMode(.middle)
                Text([candidate.sameName ? "Same file name" : nil, candidate.sameContent ? "Same text" : nil]
                  .compactMap { $0 }.joined(separator: " · "))
                  .font(.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).help("Review this matching file before linking it")
          }
        }
      }
    }
  }

  private func confirmation(_ url: URL) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(url.path, systemImage: "doc.text").lineLimit(2).truncationMode(.middle)
      Text("Which text should win? The other side is first copied into the library's Conflicts folder.")
        .font(.callout)
      HStack {
        choice("Keep Library Text", .keepLibrary, url)
        choice("Use File Text", .useFile, url)
        choice("Keep Both", .keepBoth, url)
      }
      Text("Keep Both leaves this script as it is, unlinked, and imports the file as a new linked script.")
        .font(.caption).foregroundStyle(.secondary)
      Button("Choose a Different File") { chosen = nil; problem = nil }.buttonStyle(.link).help("Return to the file choices")
    }
  }
  private func choice(_ title: String, _ resolution: RelinkResolution, _ url: URL) -> some View {
    Button(title) {
      Task {
        if await store.relink(script.metadata.id, to: url, resolution: resolution) { dismiss() }
      }
    }.help("Resolve the differing text; the other version is copied before any replacement")
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = isNewLink
      ? "Choose the Markdown file for “\(script.metadata.title)”."
      : "Choose the moved Markdown file for “\(script.metadata.title)”."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await select(url) }
  }

  /// Only a file the library itself would accept can be selected.
  private func select(_ url: URL) async {
    guard await store.library?.relinkTargetFingerprint(url) != nil else {
      problem = "That file cannot be linked. It must be a regular Markdown file under 20 MB, not a shortcut, and outside the library."
      return
    }
    problem = nil
    chosen = url
  }

  private func search() async {
    searching = true
    defer { searching = false }
    let name = URL(fileURLWithPath: savedPath).lastPathComponent
    let known = [script.metadata.linkedFingerprint, script.metadata.contentFingerprint]
    var found: [RelinkCandidate] = []
    for path in await SpotlightSearch().paths(named: name, containing: Self.snippet(of: script.markdown)).prefix(50) {
      let url = URL(fileURLWithPath: path)
      guard !path.contains("/.Trash/"), let fingerprint = await store.library?.relinkTargetFingerprint(url) else { continue }
      let sameName = url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
      let sameContent = known.contains(fingerprint)
      if sameName || sameContent { found.append(.init(url: url, sameName: sameName, sameContent: sameContent)) }
    }
    candidates = found.sorted { $0.score > $1.score }
  }

  /// The opening words of the first real line, enough for Spotlight to find a renamed copy.
  private static func snippet(of markdown: String) -> String? {
    let line = markdown.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- ").union(.whitespaces)) }
      .first { $0.count >= 12 }
    return line.map { $0.split(separator: " ").prefix(6).joined(separator: " ") }
  }
}

/// Native Spotlight search over every mounted, indexed local volume.
@MainActor private final class SpotlightSearch {
  private let query = NSMetadataQuery()
  private var continuation: CheckedContinuation<[String], Never>?
  private var observer: NSObjectProtocol?

  func paths(named name: String, containing snippet: String?) async -> [String] {
    var clauses = [NSPredicate(format: "%K ==[c] %@", NSMetadataItemFSNameKey, name)]
    if let snippet {
      clauses.append(NSPredicate(
        format: "%K LIKE[c] %@ AND %K CONTAINS[c] %@", NSMetadataItemFSNameKey, "*.md", "kMDItemTextContent", snippet))
    }
    query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: clauses)
    query.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      observer = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.finish() } }
      query.start()
      // A volume that never answers must not leave the sheet spinning.
      Task { try? await Task.sleep(for: .seconds(10)); finish() }
    }
  }
  private func finish() {
    guard let continuation else { return }
    self.continuation = nil
    query.disableUpdates()
    let items = query.results.compactMap { $0 as? NSMetadataItem }
    query.stop()
    if let observer { NotificationCenter.default.removeObserver(observer) }
    continuation.resume(returning: items.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String })
  }
}
