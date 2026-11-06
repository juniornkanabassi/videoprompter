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
  @State private var comparison: RelinkComparison?
  @State private var committing = false
  @State private var completed = false
  @State private var preservedVersion = false

  private var savedPath: String { script.metadata.linkedPath ?? "" }
  private var isNewLink: Bool { script.metadata.linkedPath == nil }

  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("\(isNewLink ? "Link" : "Relink") “\(script.metadata.title)”").font(UIType.heading)
      Text(isNewLink ? "Choose the Markdown file this script should follow." : "The linked file is no longer at \(savedPath).")
        .font(UIType.secondary).foregroundStyle(.primary)
      if completed {
        Label("Your scripts are saved.", systemImage: "checkmark.circle")
        if preservedVersion {
          Button("Show Preserved Versions") {
            Task {
              guard let library = store.library else { return }
              let root = await library.rootURL
              NSWorkspace.shared.open(root.appendingPathComponent("Conflicts"))
            }
          }.help("Open the folder containing the version saved before replacement")
        } else {
          Text("Both versions are available in your script library.")
        }
      } else if let chosen { confirmation(chosen) } else { picker }
      if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(UIType.secondary).foregroundStyle(.primary) }
      HStack {
        Spacer()
        Button(completed ? "Done" : "Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).help(completed ? "Close this confirmation" : "Close without linking a file")
      }
    }.padding(Space.xxl)
    }.frame(minWidth: 520, idealWidth: 640, minHeight: 320, idealHeight: 600)
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      HStack {
        if !isNewLink { Button("Search for It") { Task { await search() } }.disabled(searching).help("Search indexed files for a matching name or text") }
        Button("Choose File…") { chooseFile() }.help("Select the Markdown file to link")
        if searching { ProgressView().controlSize(.small) }
      }
      if let candidates {
        if candidates.isEmpty {
          Text("No matching file was found. A file on an external or unindexed volume may need Choose File.").font(UIType.secondary)
        } else {
          Text(candidates.count == 1 ? "One likely match:" : "Several files match. Pick the right one, or choose it yourself:")
            .font(UIType.secondary)
          ForEach(candidates) { candidate in
            Button { Task { await select(candidate.url) } } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(candidate.url.path).lineLimit(1).truncationMode(.middle)
                Text([candidate.sameName ? "Same file name" : nil, candidate.sameContent ? "Same text" : nil]
                  .compactMap { $0 }.joined(separator: " · "))
                  .font(UIType.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).help("Review this matching file before linking it")
          }
        }
      }
    }
  }

  private func confirmation(_ url: URL) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Label(url.path, systemImage: "doc.text").lineLimit(2).truncationMode(.middle)
      if let comparison {
        RelinkComparisonView(comparison: comparison)
        Text("Choose which version to use. A replaced version is preserved before anything changes.")
          .font(UIType.secondary)
        ViewThatFits(in: .horizontal) {
          HStack { choices(url) }
          VStack(alignment: .leading, spacing: Space.sm) { choices(url) }
        }.disabled(committing)
        Text("Keep Both leaves this script unchanged and imports the file as a separate linked script.")
          .font(UIType.secondary)
      }
      Button("Choose a Different File") { chosen = nil; comparison = nil; problem = nil }.buttonStyle(.link).help("Return to the file choices")
    }
  }
  @ViewBuilder private func choices(_ url: URL) -> some View {
    choice("Use Script Text", .keepLibrary, url)
    choice("Use File Text", .useFile, url)
    choice("Keep Both", .keepBoth, url)
  }

  private func choice(_ title: String, _ resolution: RelinkResolution, _ url: URL) -> some View {
    Button(title) {
      Task {
        guard let comparison else { return }
        committing = true
        defer { committing = false }
        guard await store.library?.relinkTargetFingerprint(url) == comparison.fingerprint,
          store.scripts.first(where: { $0.id == script.id })?.markdown == comparison.libraryText else {
          problem = "A version changed while you were comparing. Choose the file again to review the latest text."
          chosen = nil; self.comparison = nil
          return
        }
        if await store.relink(script.metadata.id, to: url, resolution: resolution) {
          switch resolution {
          case .keepBoth: preservedVersion = false
          default: preservedVersion = true
          }
          completed = true
          LibraryAnnouncement.post("Your scripts are saved.")
        }
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
    guard let fingerprint = await store.library?.relinkTargetFingerprint(url) else {
      problem = "That file cannot be linked. It must be a regular Markdown file under 20 MB, not a shortcut, and outside the library."
      return
    }
    do {
      let fileText = try String(contentsOf: url, encoding: .utf8)
      guard await store.library?.relinkTargetFingerprint(url) == fingerprint else {
        problem = "The file changed while opening it. Choose it again to compare the latest text."
        return
      }
      let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      comparison = RelinkComparison(libraryText: script.markdown, fileText: fileText,
        libraryDate: script.metadata.modifiedAt, fileDate: date, fingerprint: fingerprint)
      problem = nil
      chosen = url
    } catch { problem = "The file could not be read. Choose it again or select a different file." }
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

struct RelinkComparison {
  let libraryText: String
  let fileText: String
  let libraryDate: Date
  let fileDate: Date?
  let fingerprint: String
}

struct RelinkComparisonView: View {
  let comparison: RelinkComparison
  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text(comparison.libraryText == comparison.fileText ? "Both versions contain the same text." : "These versions contain different text.")
        .font(.headline)
      preview("Script in Video Prompter", text: comparison.libraryText, date: comparison.libraryDate)
      preview("Chosen file", text: comparison.fileText, date: comparison.fileDate)
    }
  }
  private func preview(_ title: String, text: String, date: Date?) -> some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text(title).font(.headline)
      if let date { Text(date, format: .dateTime.day().month().year().hour().minute()).font(.callout) }
      ScrollView {
        Text(text.isEmpty ? "Empty script" : text).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(height: 120).padding(Space.sm).background(.background, in: .rect(cornerRadius: Space.xs))
    }.foregroundStyle(.primary)
  }
}
