import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @ObservedObject var store: AppStore
  @Environment(\.openWindow) private var openWindow
  @Environment(\.undoManager) private var undoManager
  private let camera: CameraModel
  init(store: AppStore, camera: CameraModel = .shared) { self.store = store; self.camera = camera }
  @State private var selection = Set<UUID>()
  @State private var showsDeleted = false
  @State private var showsPractice = false
  @State private var showsReadingTip = true
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  @State private var importing = false
  @State private var importPreview: ImportPreview?
  @State private var importError: String?
  @State private var newFolderName = ""
  @State private var renamingFolder: ScriptFolder?
  @State private var renamedFolderName = ""
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    GeometryReader { geometry in
    NavigationSplitView(columnVisibility: $columnVisibility) {
      VStack(spacing: 0) {
        HStack {
          sidebarHeading("Folders")
          Spacer()
          Menu {
            Button("New Folder…") { store.namingNewFolder = true }
          } label: { Image(systemName: "folder.badge.plus") }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .accessibilityLabel("Folder actions").help("Create a folder")
            .disabled(!store.libraryAvailable)
        }.padding(.horizontal, Space.md).padding(.top, Space.md)
        List(selection: scopeSelection) {
          scopeRow("All Scripts", symbol: "tray", scope: .all)
          Group {
            ForEach(store.folders) { folder in
              scopeRow(folder.name, symbol: "folder", scope: .folder(folder.id))
                .help(folder.name)
                .contextMenu {
                  Button("Rename Folder…") { renamingFolder = folder; renamedFolderName = folder.name }
                  Button("Remove Folder, Keep Scripts", role: .destructive) {
                    store.deleteFolder(folder.id, undoManager: undoManager)
                  }
                }
            }
          }
          scopeRow("Recently Deleted", symbol: "trash", scope: .deleted)
        }.listStyle(.inset)
          .accessibilityLabel("Script folders")
          .frame(height: min(220, CGFloat((store.folders.count + 2) * 28) + Space.lg))
        Divider()
        HStack {
          sidebarHeading(scriptScopeTitle)
          Spacer()
          Text("\(showsDeleted ? store.trash.count : store.visible.count)")
            .font(UIType.secondary).foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme).opacity(0.75))
        }.padding(.horizontal, Space.md).padding(.vertical, Space.sm)
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
                .listRowSeparator(.hidden)
                .contextMenu { scriptActions(script) }
                .simultaneousGesture(TapGesture().onEnded { showsPractice = true })
            }
          }
        }.listStyle(.inset).accessibilityLabel("Scripts")
        .onKeyPress(characters: CharacterSet(charactersIn: "\u{7f}"), phases: .down) { press in
          guard !showsDeleted, press.modifiers == .command, !selection.isEmpty,
            AppStore.canTrashSelection(in: NSApp.keyWindow) else { return .ignored }
          store.delete(selection, undoManager: undoManager)
          return .handled
        }
      }
      .environment(\.colorScheme, colorScheme)
      .contextMenu {
        Button("New Folder…") { store.namingNewFolder = true }
          .disabled(!store.libraryAvailable)
      }
      .onAppear { selection = showsStart ? [] : store.selectedID.map { [$0] } ?? [] }
      .onChange(of: selection) { _, value in
        store.selectedIDs = value
        if let id = value.first { showsPractice = true; store.selectedID = id }
      }
      .onChange(of: store.selectedID) { _, id in
        if id != nil { showsDeleted = false }
        if let id, !selection.contains(id) { selection = [id] } else if id == nil { selection.removeAll() }
      }
      .uiZoom(store.uiZoom)
      .navigationSplitViewColumnWidth(min: min(320, 220 * store.uiZoom), ideal: min(360, 260 * store.uiZoom), max: 400)
    } detail: {
      VStack(spacing: 0) {
        if let notice = store.libraryNotice {
          Text(notice).font(UIType.secondary).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.margin).padding(.vertical, Space.md)
            .accessibilityAddTraits(.updatesFrequently)
        }
        Group {
        if showsDeleted {
          ContentUnavailableView("Recently Deleted", systemImage: "trash",
            description: Text("Choose Restore Script to return a deleted script to your library."))
        } else if showsStart {
          LibraryStartView(store: store, importing: $importing, practice: {
            showsPractice = true
            Task { await PracticeReading.present(store: store) }
          },
            camera: { PresenterController.shared.presentCamera(store: store) })
        } else if let script = store.selected {
          EditorView(store: store, script: script, showsReadingTip: $showsReadingTip).id(script.metadata.id)
        } else {
          if !store.libraryAvailable {
            ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle",
              description: Text("The library could not be opened. See the error message for recovery steps."))
          } else {
            ContentUnavailableView(store.visible.isEmpty ? "No matching scripts" : "Select a script", systemImage: "doc.text",
              description: Text(store.visible.isEmpty ? "Try another search or choose All Scripts." : "Choose a script on the left, then press Present."))
          }
        }
        }
      }.uiZoom(store.uiZoom)
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle(showsStart ? "Get started" : showsDeleted ? "Recently Deleted" : "Scripts")
    .searchable(text: $store.search, placement: .toolbar, prompt: "Search scripts")
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Menu {
          Button("New Script") { store.create() }
            .keyboardShortcut(ScriptShortcuts.newScript)
          Button("Import File…") { importing = true }
            .keyboardShortcut(ScriptShortcuts.importFile)
          Button("Paste Copied Text") { store.importClipboard() }
          Button("Import from Google Docs…") { openWindow(id: "google-docs") }
          Divider()
          Button("New Folder…") { store.namingNewFolder = true }
        } label: { Label("Add", systemImage: "plus") }
          .labelStyle(.titleAndIcon).menuIndicator(.visible).accessibilityLabel("Add script or folder")
          .help("Add a script or folder").disabled(!store.libraryAvailable)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        LibraryPresenterActions(store: store, showsDeleted: showsDeleted)
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
      VStack(alignment: .leading, spacing: Space.md) {
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
      }.padding(Space.xxl).uiZoom(store.uiZoom)
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
    .sheet(isPresented: $store.namingNewFolder, onDismiss: { newFolderName = "" }) {
      FolderNameSheet(title: "New Folder", name: $newFolderName, action: "Create", zoom: store.uiZoom,
        cancel: { store.namingNewFolder = false }, save: {
          createFolder()
          store.namingNewFolder = false
        })
    }
    .sheet(isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
      FolderNameSheet(title: "Rename Folder", name: $renamedFolderName, action: "Save", zoom: store.uiZoom,
        cancel: { renamingFolder = nil }, save: {
          if let folder = renamingFolder { store.renameFolder(folder.id, name: renamedFolderName) }
          renamingFolder = nil
        })
    }
    .onChange(of: geometry.size.width < 560 * store.uiZoom, initial: true) { _, compact in
      columnVisibility = compact ? .detailOnly : .all
    }
    }
    .frame(minWidth: 640, minHeight: 500)
  }

  private var scriptScopeTitle: String {
    if showsDeleted { return "Recently Deleted" }
    if let id = store.selectedFolderID, let folder = store.folders.first(where: { $0.id == id }) {
      return "Scripts in \(folder.name)"
    }
    return "Scripts"
  }

  private func sidebarHeading(_ title: String) -> some View {
    Text(title).font(UIType.secondary.weight(.semibold))
      .foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme))
      .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
  }

  private var showsStart: Bool {
    store.libraryAvailable && !showsPractice && (store.scripts.isEmpty ||
      (store.scripts.count == 1 && store.selected?.metadata.title == WelcomeScript.title && store.selected?.markdown == WelcomeScript.markdown))
  }

  private var scopeSelection: Binding<LibraryScope?> {
    Binding(get: { showsDeleted ? .deleted : store.selectedFolderID.map(LibraryScope.folder) ?? .all }, set: { scope in
      guard let scope else { return }
      showsDeleted = scope == .deleted
      switch scope {
      case .all: store.selectFolder(nil)
      case .folder(let id): store.selectFolder(id)
      case .deleted: break
      }
    })
  }

  private func scopeRow(_ title: String, symbol: String, scope: LibraryScope) -> some View {
    Label(title, systemImage: symbol)
      .lineLimit(3).fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(LibraryAppearance.color(scopeSelection.wrappedValue == scope ? (controlActiveState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) : .labelColor, scheme: colorScheme))
      .tag(scope)
  }

  @ViewBuilder private func scriptActions(_ script: ScriptRecord) -> some View {
    let id = script.id
    let linked = script.metadata.linkedPath != nil
    let broken = store.linkStates[id]?.isBroken == true
    Button("Present") { store.selectedID = id; PresenterController.shared.present(store: store) }
    Button("Duplicate") { store.selectedID = id; store.duplicate() }.keyboardShortcut("d")
    Menu("Move to Folder") {
      Button("No Folder") { store.moveSelectedScripts(store.contextSelection(for: id), to: nil) }
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
    Button("Move to Trash", role: .destructive) { store.delete(store.contextSelection(for: id), undoManager: undoManager) }.keyboardShortcut(.delete)
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
  @Environment(\.controlActiveState) private var controlActiveState
  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      HStack(spacing: Space.xs) {
        Text(script.metadata.title)
          .lineLimit(2).help(script.metadata.title).layoutPriority(1)
        if let path = script.metadata.linkedPath {
          let present = !(link?.isBroken ?? false)
          Image(systemName: present ? "link" : "link.badge.plus")
            .font(UIType.secondary)
            .accessibilityLabel(present ? "Linked file" : "Linked file unavailable")
            .help(path)
        }
      }
      if !script.metadata.tags.isEmpty {
        Text(script.metadata.tags.joined(separator: ", ")).font(UIType.secondary).lineLimit(1)
      }
    }.foregroundStyle(LibraryAppearance.color(selected ? (controlActiveState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) : .labelColor, scheme: colorScheme)).tag(script.metadata.id)
  }
}

private struct EditorView: View {
  @ObservedObject var store: AppStore
  let script: ScriptRecord
  @Binding var showsReadingTip: Bool
  @State private var text = ""
  @State private var title = ""
  @State private var tags = ""
  @State private var showsDetails = false
  @State private var showsTextSize = false
  @State private var editNotice: String?
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var saver = LibraryEditorSave()

  init(store: AppStore, script: ScriptRecord, showsReadingTip: Binding<Bool>) {
    self.store = store
    self.script = script
    _showsReadingTip = showsReadingTip
    _text = State(initialValue: script.markdown)
    _title = State(initialValue: script.metadata.title)
    _tags = State(initialValue: script.metadata.tags.joined(separator: ", "))
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Space.xs) {
        LibraryTitleField(title: $title)
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
          Text("\(saver.message) · \(PrompterDocument(markdown: text).spokenTokens.count) words")
            .font(UIType.secondary).foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme).opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
          if saver.failed { Button("Retry Save") { scheduleSave() } }
        }
        HStack(alignment: .center, spacing: Space.md) {
          Button { showsTextSize = true } label: {
            Text("Editor text size").frame(minHeight: 24).contentShape(Rectangle())
          }
            .accessibilityLabel("Editor text size")
            .buttonStyle(.plain).help("Change the editor font and text size")
            .restoringPopoverFocus(isPresented: $showsTextSize, identifier: "editor-text-size")
            .popover(isPresented: $showsTextSize) { EditorTextPopover(store: store) }
          Button { showsDetails.toggle() } label: {
            Label("Script details", systemImage: showsDetails ? "chevron.down" : "chevron.right")
              .frame(minHeight: 24).contentShape(Rectangle())
          }.buttonStyle(.plain).focusable().accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
          if script.metadata.linkedPath != nil {
            Label("Linked", systemImage: "link")
              .foregroundStyle(LibraryAppearance.color(.labelColor, scheme: colorScheme).opacity(0.75))
              .help("Edits also change the linked file. Open Script details to see the file or unlink it.")
          }
        }.font(.callout)
        if showsDetails {
          VStack(alignment: .leading, spacing: Space.sm) {
            TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder)
              .accessibilityLabel("Script tags")
            if let path = script.metadata.linkedPath {
              Label("Linked to \(URL(fileURLWithPath: path).lastPathComponent). Edits also change this file.", systemImage: "link")
                .fixedSize(horizontal: false, vertical: true).help(path)
              Button("Unlink file") { store.unlink(script.id) }.buttonStyle(.link)
                .help("Keep this script in Video Prompter without changing the original file again")
            } else {
              Text("Stored in Video Prompter")
            }
          }.font(.callout)
        }
      }.padding(.horizontal, Space.xxl).padding(.vertical, Space.sm)
      Divider()
      if showsReadingTip {
        ReadingFirstUseTip(dismiss: { showsReadingTip = false })
          .padding(.horizontal, Space.xxl).padding(.vertical, Space.sm)
      }
      if let status = store.linkedSyncStatus {
        Text(status).font(.callout).accessibilityIdentifier("linked-sync-status")
          .padding(.horizontal, Space.xxl).padding(.vertical, Space.sm)
      }
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
        }).help("Type or paste your script; changes save automatically").padding(Space.xxl)
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

private enum LibraryScope: Hashable { case all, folder(UUID), deleted }

/// The exact trailing toolbar content, also renderable in offscreen accessibility checks.
struct LibraryPresenterActions: View {
  @ObservedObject var store: AppStore
  var showsDeleted = false
  var body: some View {
        Button("Recordings", systemImage: "film.stack") { NSWorkspace.shared.open(CameraRecorder.recordingsFolder()) }
          .labelStyle(.titleAndIcon).help("Open the Recordings folder")
        Button("Camera Only", systemImage: "video") { PresenterController.shared.presentCamera(store: store) }
          .labelStyle(.titleAndIcon)
          .help("Check framing or record without a script")
        Button("Present", systemImage: "play.rectangle") { PresenterController.shared.presentFromLibrary(store: store) }
          .labelStyle(.titleAndIcon)
          .buttonStyle(.borderedProminent)
          .tint(.accentColor)
          .help("Reading settings are in Settings (⌘,)")
          .disabled(!store.libraryAvailable || showsDeleted)
  }
}
