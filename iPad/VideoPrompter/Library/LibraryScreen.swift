import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

/// Scripts on the left, the chosen one on the right with a large Present button.
struct LibraryScreen: View {
  @EnvironmentObject private var store: PadStore
  @ObservedObject var folder: ScriptFolder
  @State private var search = ""
  @State private var importing = false
  @State private var choosingFolder = false
  @State private var showingSettings = false
  @AppStorage("askedForICloudFolder") private var askedForICloudFolder = false

  private var filtered: [FolderScript] {
    let query = search.trimmingCharacters(in: .whitespaces)
    return query.isEmpty ? folder.scripts : folder.scripts.filter { $0.title.localizedCaseInsensitiveContains(query) }
  }
  private struct Group: Identifiable {
    let name: String?
    let scripts: [FolderScript]
    var id: String { name ?? "" }
  }
  /// Top-level scripts first, then one section for each subfolder, as the Mac's folders.
  private var groups: [Group] {
    let grouped = Dictionary(grouping: filtered, by: \.folder)
    return grouped.keys.sorted { ($0 ?? "") < ($1 ?? "") }.map { Group(name: $0, scripts: grouped[$0] ?? []) }
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $store.selectedID) {
        if !folder.isICloud && !askedForICloudFolder {
          ICloudPrompt(choose: { choosingFolder = true }, dismiss: { askedForICloudFolder = true })
        }
        ForEach(groups) { group in
          Section(group.name ?? "") {
            ForEach(group.scripts) { script in
              HStack {
                Label(script.title, systemImage: script.isDownloaded ? "doc.text" : "icloud.and.arrow.down")
                Spacer()
              }
              .tag(script.id)
              .contextMenu {
                Button("Present", systemImage: "play.fill") { store.present(script) }
                Button("Delete", systemImage: "trash", role: .destructive) { delete(script) }
              }
              .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(script) }
              }
            }
          }
        }
      }
      .overlay {
        if folder.scripts.isEmpty {
          ContentUnavailableView(
            "No scripts yet", systemImage: "text.alignleft",
            description: Text(folder.isICloud
              ? "Scripts saved on your Mac appear here once iCloud delivers them."
              : "Create a script, import one, or choose your Video Prompter folder in iCloud Drive."))
        }
      }
      .searchable(text: $search, prompt: "Search scripts")
      .navigationTitle("Video Prompter")
      .refreshable { folder.refresh() }
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Menu {
            Button("New Script", systemImage: "square.and.pencil") { store.newScript() }
            Button("Import from Files…", systemImage: "square.and.arrow.down") { importing = true }
          } label: { Label("Add", systemImage: "plus") }
          Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        }
      }
    } detail: {
      if let script = store.selected {
        ScriptDetail(script: script)
      } else {
        ContentUnavailableView("Choose a script", systemImage: "doc.text", description: Text("Pick a script on the left, then press Present."))
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      Task { for url in urls { await store.importFile(url) } }
    }
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      askedForICloudFolder = true
      if case .success(let url) = result { folder.choose(url) }
    }
    .sheet(isPresented: $showingSettings) {
      NavigationStack { SettingsScreen() }.environmentObject(store)
    }
  }

  static let importTypes: [UTType] = [
    UTType(filenameExtension: "md") ?? .plainText, .plainText, .rtf, .pdf,
  ]

  private func delete(_ script: FolderScript) {
    do {
      try folder.delete(script)
      if store.selectedID == script.id { store.selectedID = nil }
    } catch { store.errorMessage = error.localizedDescription }
  }
}

/// Shown until the iCloud folder is chosen or the offer dismissed.
private struct ICloudPrompt: View {
  let choose: () -> Void
  let dismiss: () -> Void
  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Label("Use the same scripts as your Mac", systemImage: "icloud").font(.headline)
        Text("On the Mac, turn on Settings › Keep scripts in iCloud Drive. Then choose iCloud Drive › Video Prompter here.")
          .font(.subheadline).foregroundStyle(.secondary)
        HStack {
          Button("Choose Folder", action: choose).buttonStyle(.borderedProminent)
          Button("Not Now", action: dismiss)
        }
      }
      .padding(.vertical, 4)
    }
  }
}

/// The chosen script: a readable preview and what can be done with it.
private struct ScriptDetail: View {
  @EnvironmentObject private var store: PadStore
  let script: FolderScript
  @State private var record: ScriptRecord?
  @State private var editing = false
  @State private var renaming = false
  @State private var newTitle = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let record {
          Text((try? AttributedString(markdown: record.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(record.markdown))
            .font(.custom("Lexend Deca", size: 19, relativeTo: .body))
            .lineSpacing(6)
            .textSelection(.enabled)
        } else if !script.isDownloaded {
          ProgressView("Downloading from iCloud…")
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(28)
      .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) {
      Button {
        store.present(script)
      } label: {
        Label("Present", systemImage: "play.fill")
          .font(.title2.weight(.semibold))
          .frame(maxWidth: 420, minHeight: 60)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .disabled(!script.isDownloaded)
      .keyboardShortcut(.return, modifiers: .command)
      .padding()
    }
    .navigationTitle(script.title)
    .toolbar {
      Button("Edit", systemImage: "pencil") { editing = true }.disabled(record == nil)
      Button("Rename", systemImage: "character.cursor.ibeam") { newTitle = script.title; renaming = true }
    }
    .task(id: script) { record = script.isDownloaded ? store.record(for: script) : nil }
    .sheet(isPresented: $editing, onDismiss: { record = store.record(for: script) }) {
      ScriptEditor(script: script).environmentObject(store)
    }
    .alert("Rename Script", isPresented: $renaming) {
      TextField("Title", text: $newTitle)
      Button("Rename") {
        do { try store.folder.rename(script, to: newTitle) } catch { store.errorMessage = error.localizedDescription }
      }
      Button("Cancel", role: .cancel) {}
    }
  }
}
