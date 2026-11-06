import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @ObservedObject var store: AppStore
  @Environment(\.undoManager) private var undoManager
  private let camera: CameraModel
  init(store: AppStore, camera: CameraModel = .shared) { self.store = store; self.camera = camera }
  @State private var selection = Set<UUID>()
  @State private var importing = false
  @State private var importPreview: ImportPreview?
  @State private var importError: String?
  @State private var newFolderName = ""
  @State private var renamingFolder: ScriptFolder?
  @State private var renamedFolderName = ""
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section("Library") {
          // Folder and Recently Deleted rows are never the list selection: SwiftUI tags every
          // `ForEach` row, and a folder or trashed script taken as the "selected script" left
          // Present with nothing to show.
          Button { store.selectFolder(nil) } label: {
            ViewThatFits(in: .horizontal) {
              Label("All Scripts", systemImage: "tray.full").foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme)).fixedSize()
              Text("All Scripts").lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
          }
            .buttonStyle(.plain)
            .help("Choose which scripts to show").selectionDisabled()
            .listRowBackground(store.selectedFolderID == nil ? Color.accentColor.opacity(0.18) : Color.clear)
            .accessibilityAddTraits(store.selectedFolderID == nil ? .isSelected : [])
          ForEach(store.folders) { folder in
            Button { store.selectFolder(folder.id) } label: {
              ViewThatFits(in: .horizontal) {
                Label(folder.name, systemImage: "folder").foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme)).fixedSize()
                Text(folder.name).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
              }
            }
              .contextMenu {
                Button("Rename Folder…") { renamingFolder = folder; renamedFolderName = folder.name }.help("Change this folder’s name")
                Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id, undoManager: undoManager) }.help("Remove the folder; its scripts return to All Scripts")
              }
              .buttonStyle(.plain)
            .help("Choose which scripts to show").selectionDisabled()
              .listRowBackground(store.selectedFolderID == folder.id ? Color.accentColor.opacity(0.18) : Color.clear)
              .accessibilityAddTraits(store.selectedFolderID == folder.id ? .isSelected : [])
          }
        }
        Section(store.folders.first(where: { $0.id == store.selectedFolderID })?.name ?? "All Scripts") {
          ForEach(store.visible) { script in
            ScriptRow(script: script, link: store.linkStates[script.id])
              .contextMenu { scriptActions(script) }
          }
        }
        if !store.trash.isEmpty {
          Section("Recently Deleted") {
            ForEach(store.trash) { entry in
              HStack {
                Label(entry.metadata.title, systemImage: "trash")
                Spacer()
                Button("Restore") { store.restore(entry.id) }.buttonStyle(.link).help("Return this script to the library")
              }.selectionDisabled()
            }
          }
        }
      }
      .foregroundColor(LibraryAppearance.color(.labelColor, scheme: colorScheme))
      .listStyle(.sidebar)
      .environment(\.colorScheme, colorScheme)
      .contextMenu {
        Button("New Folder…") { store.namingNewFolder = true }
          .disabled(!store.libraryAvailable)
      }
      .onChange(of: selection) { _, value in
        store.selectedIDs = value
        if let id = value.first { store.selectedID = id }
      }
      .onKeyPress(characters: CharacterSet(charactersIn: "\u{7f}"), phases: .down) { press in
        guard press.modifiers == .command, !selection.isEmpty,
          AppStore.canTrashSelection(in: NSApp.keyWindow) else { return .ignored }
        store.delete(selection)
        return .handled
      }
      .onChange(of: store.selectedID) { _, id in
        if let id, !selection.contains(id) { selection = [id] } else if id == nil { selection.removeAll() }
      }
      .uiZoom(store.uiZoom)
      .frame(minWidth: 200 * store.uiZoom)
      .navigationSplitViewColumnWidth(min: 200 * store.uiZoom, ideal: 240 * store.uiZoom, max: 320 * store.uiZoom)
    } detail: {
      Group {
        if let script = store.selected {
          EditorView(store: store, script: script).id(script.metadata.id)
        } else {
          if !store.libraryAvailable {
            ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle",
              description: Text("The library could not be opened. See the error message for recovery steps."))
          } else if store.scripts.isEmpty {
            ScrollView {
              VStack(spacing: 16) {
                Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                Text("Your script, ready to read").font(.title2.bold())
                  .fixedSize(horizontal: false, vertical: true)
                Text("Add a script.\nChoose Voice or Manual in Settings.\nPress Present.")
                  .fixedSize(horizontal: false, vertical: true)
                Button { importing = true } label: {
                  Label { Text("Import Script…").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "square.and.arrow.down") }
                }.buttonStyle(.borderedProminent).help("Add a Markdown, text, Word, PDF or RTF file")
                Button { store.create() } label: {
                  Label { Text("New Script").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "square.and.pencil") }
                }.help("Start with a blank script and type or paste your words")
                Button { PresenterController.shared.presentCamera(store: store) } label: {
                  Label { Text("Camera Only").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "video") }
                }.help("Open the presenter with just the camera, to record without a script")
              }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(20)
            }
          } else {
            ContentUnavailableView(store.visible.isEmpty ? "No matching scripts" : "Select a script", systemImage: "doc.text",
              description: Text(store.visible.isEmpty ? "Try another search or choose All Scripts." : "Choose a script on the left, then press Present."))
          }
        }
      }.uiZoom(store.uiZoom)
    }
    .navigationSplitViewStyle(.balanced)
    .inspector(isPresented: $store.inspector) {
      // The column width is what the split view honours; a `frame` inside it let the form
      // out-size the pane and slide under the editor.
      InspectorView(store: store, camera: camera)
        .environment(\.colorScheme, colorScheme)
        .uiZoom(store.uiZoom)
        // The inspector ideal stays fixed; zoom only raises the sidebar minimum.
        .inspectorColumnWidth(min: 280, ideal: 320, max: 480 * store.uiZoom)
    }
    .navigationTitle("Video Prompter")
    .searchable(text: $store.search, placement: .toolbar, prompt: "Search scripts")
    .toolbar {
      ToolbarItemGroup {
        Menu {
          Button("New Script") { store.create() }
            .keyboardShortcut(ScriptShortcuts.newScript)
          Button("Import File…") { importing = true }
            .keyboardShortcut(ScriptShortcuts.importFile)
          Button("Paste as New Script") { store.importClipboard() }
          Divider()
          Button("New Folder…") { store.namingNewFolder = true }
        } label: { Label("Add", systemImage: "plus") }
          .labelStyle(.iconOnly).accessibilityLabel("Add")
          .help("Add a script or folder").disabled(!store.libraryAvailable)
        Button("Present", systemImage: "play.rectangle") { PresenterController.shared.presentFromLibrary(store: store) }
          .labelStyle(.titleAndIcon)
          .buttonStyle(.borderedProminent)
          .tint(.accentColor)
          .help(store.selected == nil ? "Open the presenter with just the camera; add a script any time" : "Open the selected script in the floating presenter (⌥⌘P)")
          .disabled(!store.libraryAvailable)
        Button("Camera Only", systemImage: "video") { PresenterController.shared.presentCamera(store: store) }
          .labelStyle(.titleAndIcon)
          .help("Check framing or record without a script")
        Button("Presenter", systemImage: "sidebar.trailing") { store.inspector.toggle() }
          .labelStyle(.iconOnly)
          .help(store.inspector ? "Hide presenter controls" : "Show presenter controls")
      }
    }
    .alert(
      "Video Prompter",
      isPresented: Binding(
        // A headless copy keeps the error (commands report it) and shows it once the library comes up.
        get: { store.errorMessage != nil && !Headless.shared.active }, set: { if !$0 { store.errorMessage = nil } })
    ) {
      if store.hasFailedSaves {
        Button("Retry Save") { Task { await store.retryFailedSaves() } }.help("Try saving the pending edits again")
        Button("Keep Both") { Task { await store.keepBothFailedSaves() } }.help("Save both versions so neither edit is lost")
      }
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "Unknown error")
    }
    .alert("Following Options Changed", isPresented: Binding(
      get: { store.modeMigrationNotice != nil && store.errorMessage == nil && !Headless.shared.active },
      set: { if !$0 { store.dismissModeMigrationNotice() } })
    ) { Button("OK") { store.dismissModeMigrationNotice() } }
      message: { Text(store.modeMigrationNotice ?? "") }
    .onReceive(NotificationCenter.default.publisher(for: .videoPrompterImport)) { _ in importing = true }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md")!, .rtf, .pdf, UTType(filenameExtension: "docx")!]) { result in
      guard case .success(let url) = result else {
        if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { importError = error.localizedDescription }
        return
      }
      Task {
        do { importPreview = try await DocumentImporter().preview(url: url) }
        catch { importError = error.localizedDescription }
      }
    }
    .sheet(isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { importPreview = nil } })) {
      if let value = importPreview {
      VStack(alignment: .leading, spacing: 12) {
        Text("Import \(value.sourceURL.lastPathComponent)").font(.headline)
        ScrollView {
          Text(value.markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(Font(FormattedMarkdownEditModel.font(name: store.previewFontName, size: store.previewFontSize)))
          .frame(minWidth: 600, minHeight: 400)
        if AppStore.importTarget(for: value).linkTo != nil {
          Label("This file will be linked both ways. Editing here changes the original Markdown file. Changes to that file also appear here.", systemImage: "link")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(value.warnings, id: \.self) { Text($0).foregroundStyle(.primary) }
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { importPreview = nil }
            .keyboardShortcut(.cancelAction).help("Close this preview without importing")
          Button("Import") {
            // A Markdown original stays linked, so edits made in MarkEdit or Obsidian
            // reach the script. Converted formats (PDF, DOCX, RTF) have no such original.
            let target = AppStore.importTarget(for: value)
            store.create(title: target.title, markdown: value.markdown, linkTo: target.linkTo)
            importPreview = nil
          }.keyboardShortcut(.defaultAction).help("Add this script; Markdown originals stay linked for editing")
        }
      }.padding(24).uiZoom(store.uiZoom)
        // The zoomed layout takes only what the sheet offers, so the sheet must be asked for the
        // scaled minimum here or the preview is laid out narrower than its text and clipped.
        .frame(minWidth: 648 * store.uiZoom, minHeight: 448 * store.uiZoom)
      }
    }
    .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
      Button("OK") { importError = nil }
    } message: { Text(importError ?? "The document could not be imported.") }
    .sheet(isPresented: Binding(get: { store.relinkingID != nil }, set: { if !$0 { store.relinkingID = nil } })) {
      if let script = store.scripts.first(where: { $0.id == store.relinkingID }) {
        RelinkSheet(store: store, script: script).uiZoom(store.uiZoom).frame(minWidth: 520 * store.uiZoom)
      }
    }
    .alert("New Folder", isPresented: $store.namingNewFolder) {
      TextField("Folder name", text: $newFolderName).help("Enter a name for this folder")
      Button("Create", action: createFolder)
        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Cancel", role: .cancel) { newFolderName = "" }
    }
    .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
      TextField("Folder name", text: $renamedFolderName).help("Enter a new name for this folder")
      Button("Save") { if let folder = renamingFolder { store.renameFolder(folder.id, name: renamedFolderName) }; renamingFolder = nil }.help("Save the folder’s new name")
      Button("Cancel", role: .cancel) { renamingFolder = nil }
    }
    // Allow the 200% sidebar plus the inspector and editor without changing window constraints mid-zoom.
    .frame(minWidth: 1132, minHeight: 500)
  }

  @ViewBuilder private func scriptActions(_ script: ScriptRecord) -> some View {
    let id = script.id
    let linked = script.metadata.linkedPath != nil
    let broken = store.linkStates[id]?.isBroken == true
    Button("Present") { store.selectedID = id; PresenterController.shared.present(store: store) }
    Button("Duplicate") { store.selectedID = id; store.duplicate() }.keyboardShortcut("d")
    Menu("Move to Folder") {
      Button("All Scripts") { store.moveSelectedScripts(store.contextSelection(for: id), to: nil) }
      ForEach(store.folders) { folder in
        Button(folder.name) { store.moveSelectedScripts(store.contextSelection(for: id), to: folder.id) }
      }
    }
    Button("Export Markdown…") { store.exportMarkdown(script) }
    Button("Show in Finder") { store.revealInFinder(id) }.disabled(broken)
    if !linked { Button("Link File…") { store.relinkingID = id } }
    if linked {
      Button("Unlink") { store.unlink(id) }
      if broken { Button("Find Linked File…") { store.relinkingID = id } }
    }
    Divider()
    Button("Move to Trash", role: .destructive) { store.delete(store.contextSelection(for: id)) }.keyboardShortcut(.delete)
  }

  private func createFolder() {
    guard !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    store.createFolder(named: newFolderName)
    newFolderName = ""
  }
}

private struct ScriptRow: View {
  let script: ScriptRecord
  let link: LinkState?
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      HStack(spacing: 4) {
        Label(script.metadata.title, systemImage: "doc.text")
          .foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        if let path = script.metadata.linkedPath {
          let present = !(link?.isBroken ?? false)
          Image(systemName: present ? "link" : "link.badge.plus")
            .font(.caption).foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
            .accessibilityLabel(present ? "Linked file" : "Linked file unavailable")
            .help(path)
        }
      }
      if !script.metadata.tags.isEmpty {
        Text(script.metadata.tags.joined(separator: ", ")).font(.caption).foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme)).lineLimit(1)
      }
    }.foregroundColor(LibraryAppearance.color(.labelColor, scheme: colorScheme)).tag(script.metadata.id)
  }
}

private struct EditorView: View {
  @ObservedObject var store: AppStore
  let script: ScriptRecord
  @State private var text = ""
  @State private var title = ""
  @State private var tags = ""
  @State private var showsTags = false
  @State private var editNotice: String?
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var saver = LibraryEditorSave()

  init(store: AppStore, script: ScriptRecord) {
    self.store = store
    self.script = script
    _text = State(initialValue: script.markdown)
    _title = State(initialValue: script.metadata.title)
    _tags = State(initialValue: script.metadata.tags.joined(separator: ", "))
    _showsTags = State(initialValue: !script.metadata.tags.isEmpty)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Title", text: $title).textFieldStyle(.plain).font(.headline)
          .accessibilityLabel("Script title")
          .help("Title, tags and script text save automatically")
        DisclosureGroup("Tags", isExpanded: $showsTags) {
          TextField("Separate tags with commas", text: $tags).textFieldStyle(.plain).font(.callout)
        }
        HStack {
          Text(saver.message).font(.caption).foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
          if saver.failed { Button("Retry Save") { scheduleSave() } }
        }
      }.padding(.horizontal, 24).padding(.vertical, 12)
      Divider()
      if let editNotice {
        Text(editNotice).font(.callout).foregroundStyle(.secondary)
          .padding(.horizontal, 24).padding(.vertical, 8)
      }
      if let path = script.metadata.linkedPath {
        let state = store.linkStates[script.metadata.id]
        let present = !(state?.isBroken ?? false)
        HStack(spacing: 8) {
          Label(
            present ? "Linked to \(URL(fileURLWithPath: path).lastPathComponent)" : "Linked file unavailable: \(path)",
            systemImage: present ? "link" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
            .lineLimit(1)
            .truncationMode(.middle).help("Edits stay in sync with this Markdown file: " + path)
          Spacer()
          if !present { Button("Find linked file…") { store.relinkingID = script.id }.buttonStyle(.link).help("Choose the moved Markdown file and resolve any different text safely") }
        }.padding(.horizontal, 24).padding(.vertical, Space.sm)
      } else {
        HStack {
          Label("Stored in Video Prompter", systemImage: "doc.text")
            .font(.caption).foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
          Spacer()
        }.padding(.horizontal, 24).padding(.vertical, Space.sm)
      }
      if store.unavailableScriptIDs.contains(script.metadata.id) {
        Label("Script file unavailable. Restore the original file, or export and import a copy.", systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24).padding(.vertical, Space.md)
      }
      FormattedMarkdownEditor(markdown: $text, fontName: store.previewFontName,
        fontSize: store.previewFontSize, onUnsupportedEdit: {
          editNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
        }).help("Type or paste your script; changes save automatically").padding(24)
    }
    .onChange(of: text) { _, value in editNotice = nil; store.updateMarkdown(value, for: script.metadata.id); scheduleSave() }
    .onChange(of: title) { _, _ in scheduleSave() }
    .onChange(of: tags) { _, _ in scheduleSave() }
    .onChange(of: editNotice) { _, value in if let value { LibraryAnnouncement.post(value) } }
    .onChange(of: script.markdown) { _, value in if value != text { text = value } }
    .onChange(of: script.metadata.title) { _, value in if !saver.isSaving, value != title { title = value } }

  }

  private func scheduleSave() {
    saver.schedule(store: store, id: script.id, title: title,
      tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
  }

}
