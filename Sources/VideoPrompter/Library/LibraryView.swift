import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @ObservedObject var store: AppStore
  @Environment(\.undoManager) private var undoManager
  private let camera: CameraModel
  init(store: AppStore, camera: CameraModel = .shared) { self.store = store; self.camera = camera }
  @State private var selection = Set<UUID>()
  @State private var showsDeleted = false
  @State private var showsPractice = false
  @State private var showsFolders = true
  @State private var importing = false
  @State private var importPreview: ImportPreview?
  @State private var importError: String?
  @State private var newFolderName = ""
  @State private var renamingFolder: ScriptFolder?
  @State private var renamedFolderName = ""
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: Space.sm) {
            scope("All Scripts", symbol: "tray.full", selected: !showsDeleted && store.selectedFolderID == nil) {
              showsDeleted = false; store.selectFolder(nil)
            }
            DisclosureGroup("Folders", isExpanded: $showsFolders) {
              ScrollView {
                VStack(alignment: .leading, spacing: Space.xs) {
              ForEach(store.folders) { folder in
                scope(folder.name, symbol: "folder", selected: !showsDeleted && store.selectedFolderID == folder.id) {
                  showsDeleted = false; store.selectFolder(folder.id)
                }.contextMenu {
                  Button("Rename Folder…") { renamingFolder = folder; renamedFolderName = folder.name }
                  Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id, undoManager: undoManager) }
                }
              }
                }
              }.frame(height: store.folders.isEmpty ? 0 : min(96, CGFloat(store.folders.count) * 36))
              Button("New Folder…") { store.namingNewFolder = true }.buttonStyle(.link)
            }
            scope("Recently Deleted", symbol: "trash", selected: showsDeleted) { showsDeleted = true }
            Button { NSWorkspace.shared.open(CameraRecorder.recordingsFolder()) } label: {
              Label("Open Recordings Folder", systemImage: "film.stack")
            }.buttonStyle(.link).help("Find takes saved in earlier sessions")
        }.padding(Space.md)
        Divider()
        Text(showsDeleted ? "Recently Deleted" : store.folders.first(where: { $0.id == store.selectedFolderID })?.name ?? "All Scripts")
          .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
        List(selection: $selection) {
          if showsDeleted {
            ForEach(store.trash) { entry in
              VStack(alignment: .leading, spacing: Space.sm) {
                Text(entry.metadata.title).fixedSize(horizontal: false, vertical: true)
                Button("Restore Script") { store.restore(entry.id) }.buttonStyle(.link)
              }.selectionDisabled()
            }
          } else {
            ForEach(store.visible) { script in
              ScriptRow(script: script, link: store.linkStates[script.id], selected: selection.contains(script.id))
                .listRowBackground(selection.contains(script.id) ? LibraryAppearance.color(.selectedContentBackgroundColor, scheme: colorScheme).opacity(0.18) : Color.clear)
                .accessibilityAddTraits(selection.contains(script.id) ? .isSelected : [])
                .contextMenu { scriptActions(script) }
                .simultaneousGesture(TapGesture().onEnded { showsPractice = true })
            }
          }
        }.listStyle(.plain)
      }
      .foregroundColor(LibraryAppearance.color(.labelColor, scheme: colorScheme))
      .environment(\.colorScheme, colorScheme)
      .contextMenu {
        Button("New Folder…") { store.namingNewFolder = true }
          .disabled(!store.libraryAvailable)
      }
      .onAppear { selection = store.selectedID.map { [$0] } ?? [] }
      .onChange(of: selection) { _, value in
        store.selectedIDs = value
        if let id = value.first { store.selectedID = id }
      }
      .onKeyPress(characters: CharacterSet(charactersIn: "\u{7f}"), phases: .down) { press in
        guard !showsDeleted, press.modifiers == .command, !selection.isEmpty,
          AppStore.canTrashSelection(in: NSApp.keyWindow) else { return .ignored }
        store.delete(selection)
        return .handled
      }
      .onChange(of: store.selectedID) { _, id in
        if id != nil { showsDeleted = false }
        if let id, !selection.contains(id) { selection = [id] } else if id == nil { selection.removeAll() }
      }
      .uiZoom(store.uiZoom)
      .frame(minWidth: 200 * store.uiZoom)
      .navigationSplitViewColumnWidth(min: 200 * store.uiZoom, ideal: 240 * store.uiZoom, max: 320 * store.uiZoom)
    } detail: {
      Group {
        if showsDeleted {
          ContentUnavailableView("Recently Deleted", systemImage: "trash",
            description: Text("Choose Restore Script to return a deleted script to your library."))
        } else if showsStart {
          LibraryStartView(store: store, importing: $importing, practice: { showsPractice = true },
            camera: { PresenterController.shared.presentCamera(store: store) })
        } else if let script = store.selected {
          EditorView(store: store, script: script).id(script.metadata.id)
        } else {
          if !store.libraryAvailable {
            ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle",
              description: Text("The library could not be opened. See the error message for recovery steps."))
          } else {
            ContentUnavailableView(store.visible.isEmpty ? "No matching scripts" : "Select a script", systemImage: "doc.text",
              description: Text(store.visible.isEmpty ? "Try another search or choose All Scripts." : "Choose a script on the left, then press Present."))
          }
        }
      }.uiZoom(store.uiZoom)
    }
    .navigationSplitViewStyle(.balanced)
    .inspector(isPresented: Binding(get: { store.inspector && !showsStart && !showsDeleted }, set: { store.inspector = $0 })) {
      // The column width is what the split view honours; a `frame` inside it let the form
      // out-size the pane and slide under the editor.
      ReadingInspectorView(store: store, camera: camera)
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
          .labelStyle(.titleAndIcon).accessibilityLabel("Add script or folder")
          .help("Add a script or folder").disabled(!store.libraryAvailable)
        Button("Present", systemImage: "play.rectangle") { PresenterController.shared.presentFromLibrary(store: store) }
          .labelStyle(.titleAndIcon)
          .buttonStyle(.borderedProminent)
          .tint(.accentColor)
          .help(store.selected == nil ? "Open the presenter with just the camera; add a script any time" : "Open the selected script in the floating presenter (⌥⌘P)")
          .disabled(!store.libraryAvailable || showsDeleted)
        Button("Camera Only", systemImage: "video") { PresenterController.shared.presentCamera(store: store) }
          .labelStyle(.titleAndIcon)
          .help("Check framing or record without a script")
        Button("Reading settings", systemImage: "sidebar.trailing") { store.inspector.toggle() }
          .labelStyle(.iconOnly)
          .help(store.inspector ? "Hide reading settings" : "Show reading settings")
      }
    }
    .alert(
      "Could not finish that action",
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
          .frame(minHeight: 220)
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
        .frame(minWidth: min(648 * store.uiZoom, 900), minHeight: min(448 * store.uiZoom, 700))
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

  private var showsStart: Bool {
    store.libraryAvailable && !showsPractice && (store.scripts.isEmpty ||
      (store.scripts.count == 1 && store.selected?.metadata.title == WelcomeScript.title && store.selected?.markdown == WelcomeScript.markdown))
  }

  private func scope(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: Space.sm) {
        Image(systemName: symbol).foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
        Text(title).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }.padding(Space.sm)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: Space.xs))
        .contentShape(.rect)
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
  var selected = false
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      HStack(spacing: 4) {
        Image(systemName: "doc.text").foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
        Text(script.metadata.title).fontWeight(selected ? .semibold : .regular)
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
  @State private var showsDetails = false
  @State private var editNotice: String?
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var saver = LibraryEditorSave()

  init(store: AppStore, script: ScriptRecord) {
    self.store = store
    self.script = script
    _text = State(initialValue: script.markdown)
    _title = State(initialValue: script.metadata.title)
    _tags = State(initialValue: script.metadata.tags.joined(separator: ", "))
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Title", text: $title).textFieldStyle(.plain).font(.headline)
          .accessibilityLabel("Script title")
          .help("Title, tags and script text save automatically")
        HStack(alignment: .firstTextBaseline) {
          Text(saver.message).font(.caption)
          if saver.failed { Button("Retry Save") { scheduleSave() } }
          Spacer()
          Menu("Editor text size") {
            ForEach([14.0, 18, 22, 28, 36], id: \.self) { size in
              Button("\(Int(size)) pt") { store.previewFontSize = size }
            }
          }.fixedSize().help("Change the words in this editor; reading text has its own size")
        }
        DisclosureGroup("Script details", isExpanded: $showsDetails) {
          VStack(alignment: .leading, spacing: Space.sm) {
            TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder)
              .accessibilityLabel("Script tags")
            if let path = script.metadata.linkedPath {
              Label("Changes sync with \(URL(fileURLWithPath: path).lastPathComponent)", systemImage: "link")
                .fixedSize(horizontal: false, vertical: true).help(path)
            } else {
              Text("Stored in Video Prompter")
            }
          }.font(.callout)
        }.font(.callout)
      }.padding(.horizontal, Space.xxl).padding(.vertical, Space.md)
      Divider()
      if let editNotice {
        Text(editNotice).font(.callout).foregroundStyle(.primary)
          .padding(.horizontal, Space.xxl).padding(.vertical, Space.sm)
      }
      if script.metadata.linkedPath != nil && store.linkStates[script.id]?.isBroken == true {
        VStack(alignment: .leading, spacing: Space.sm) {
          Label("The linked file has moved or is unavailable. Your saved script is still here.", systemImage: "exclamationmark.triangle")
            .fixedSize(horizontal: false, vertical: true)
          Button("Find Linked File…") { store.relinkingID = script.id }.buttonStyle(.link)
        }.font(.callout).padding(.horizontal, Space.xxl).padding(.vertical, Space.md)
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
