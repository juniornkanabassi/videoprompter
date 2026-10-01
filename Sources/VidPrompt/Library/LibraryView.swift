import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @ObservedObject var store: AppStore
  @State private var selection = Set<UUID>()
  @State private var importing = false
  @State private var importPreview: ImportPreview?
  @State private var importError: String?
  @State private var newFolderName = ""
  @State private var renamingFolder: ScriptFolder?
  @State private var renamedFolderName = ""

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section("Library") {
          // Folder and Recently Deleted rows are never the list selection: SwiftUI tags every
          // `ForEach` row, and a folder or trashed script taken as the "selected script" left
          // Present with nothing to show.
          Button { store.selectFolder(nil) } label: {
            ViewThatFits(in: .horizontal) {
              Label("All Scripts", systemImage: "tray.full").fixedSize()
              Text("All Scripts").lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
          }
            .help("Choose which scripts to show").selectionDisabled()
          ForEach(store.folders) { folder in
            Button { store.selectFolder(folder.id) } label: {
              ViewThatFits(in: .horizontal) {
                Label(folder.name, systemImage: "folder").fixedSize()
                Text(folder.name).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
              }
            }
              .contextMenu {
                Button("Rename Folder") { renamingFolder = folder; renamedFolderName = folder.name }.help("Change this folder’s name")
                Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id) }.help("Remove the folder; its scripts return to All Scripts")
              }
              .help("Choose which scripts to show").selectionDisabled()
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("New folder").lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            HStack {
              TextField("", text: $newFolderName)
                .accessibilityLabel("New folder")
                .textFieldStyle(.roundedBorder)
                .help("Name a folder, then press Return to create it")
                .onSubmit(createFolder)
              Button("Create Folder", systemImage: "plus", action: createFolder)
                .labelStyle(.iconOnly)
                .help("Create folder")
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
        }
        Section("Scripts") {
          ForEach(store.visible) { script in ScriptRow(script: script, link: store.linkStates[script.id])
            .listRowBackground(store.selectedID == script.id ? Color.accentColor.opacity(0.12) : Color.clear) }
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
      .listStyle(.sidebar)
      // Zoom widens the ideal and widest column, never the narrowest: doubled minimums asked
      // more of the smallest window than it had, and AppKit looped on constraints.
      .navigationSplitViewColumnWidth(min: 200, ideal: 240 * store.uiZoom, max: 320 * store.uiZoom)
      // New lives in the toolbar and File menu; this bar keeps Move to Trash (Command-Delete).
      .safeAreaInset(edge: .bottom) {
        HStack {
          Spacer()
          Button("Move to Trash", systemImage: "trash") { store.delete(selection) }
            .labelStyle(.iconOnly)
            .help("Move to Trash")
            .disabled(selection.isEmpty)
        }.padding(10)
      }
      .onChange(of: selection) { _, value in if let id = value.first { store.selectedID = id } }
      .onKeyPress(characters: CharacterSet(charactersIn: "\u{7f}"), phases: .down) { press in
        guard press.modifiers == .command, !selection.isEmpty,
          !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }
        store.delete(selection)
        return .handled
      }
      .onChange(of: store.selectedID) { _, id in
        if let id, !selection.contains(id) { selection = [id] } else if id == nil { selection.removeAll() }
      }
      .uiZoom(store.uiZoom)
    } detail: {
      Group {
        if let script = store.selected {
          EditorView(store: store, script: script)
        } else {
          if !store.libraryAvailable {
            ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle",
              description: Text("The library could not be opened. See the error message for recovery steps."))
          } else if store.scripts.isEmpty {
            ContentUnavailableView {
              Label("Your script, ready to read", systemImage: "doc.text")
            } description: {
              Text("VidPrompt keeps your script in view while you speak.\n1. Add a script.\n2. Choose Voice or Manual in Script settings.\n3. After adding a script, press Present.")
            } actions: {
              Button("Import Script…", systemImage: "square.and.arrow.down") { importing = true }
                .buttonStyle(.borderedProminent).help("Add a Markdown, text, Word, PDF or RTF file")
              Button("New Script", systemImage: "square.and.pencil") { store.create() }
                .help("Start with a blank script and type or paste your words")
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
      InspectorView(store: store).uiZoom(store.uiZoom)
        // The ideal stays put under zoom: the window's minimum is measured from it (see minWidth).
        .inspectorColumnWidth(min: 280, ideal: 320, max: 480 * store.uiZoom)
    }
    .navigationTitle("VidPrompt")
    .searchable(text: $store.search, placement: .toolbar, prompt: "Search scripts")
    .toolbar {
      ToolbarItemGroup {
        Button("New Script", systemImage: "square.and.pencil") { store.create() }
          .help("Start with a blank script (⇧⌘N)")
          .disabled(!store.libraryAvailable)
        Button("Import Script…", systemImage: "square.and.arrow.down") { importing = true }
          .help("Add a Markdown, text, Word, PDF or RTF script (⌘I)")
          .disabled(!store.libraryAvailable)
        Menu {
          Button("Import from Clipboard") { store.importClipboard() }.help("Create a script from copied text")
          Button("Export Markdown…") {
            guard let script = store.selected else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(script.metadata.title).md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try script.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { importError = "Could not export the script. \(error.localizedDescription)" }
          }.help("Save a Markdown copy of the selected script").disabled(store.selected == nil)
          Button("Reveal in Finder") {
            guard let id = store.selectedID else { return }
            Task {
              do {
                let url = try await store.library!.scriptURL(for: id)
                NSWorkspace.shared.activateFileViewerSelecting([url])
              } catch { importError = "Could not reveal the script. \(error.localizedDescription)" }
            }
          }.help("Show the selected script’s Markdown file in Finder").disabled(store.selected == nil)
        } label: { Label("More Actions", systemImage: "ellipsis.circle") }
          .accessibilityLabel("More Actions")
          .help("More script actions")
          .disabled(!store.libraryAvailable)
        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate() }
          .help("Duplicate script")
          .disabled(store.selected == nil)
        Menu {
          Button("All Scripts") { store.moveSelectedScripts(selection, to: nil) }.help("Remove the selected scripts from their folders")
          ForEach(store.folders) { folder in
            Button(folder.name) { store.moveSelectedScripts(selection, to: folder.id) }.help("Move the selected scripts to this folder")
          }
        } label: { Label("Move to folder", systemImage: "folder") }
          .accessibilityLabel("Move to folder")
          .help("Move to folder")
          .disabled(selection.isEmpty)
        Button("Present", systemImage: "play.rectangle") { PresenterController.shared.present(store: store) }
          .labelStyle(.titleAndIcon)
          .buttonStyle(.borderedProminent)
          .tint(.accentColor)
          .help(store.selected == nil ? "Select a script to present" : "Open the selected script in the floating presenter (⌥⌘P)")
          .disabled(store.selected == nil)
        Button("Script settings", systemImage: "sidebar.right") { store.inspector.toggle() }
          .labelStyle(.titleAndIcon)
          .help(store.inspector ? "Hide script settings" : "Choose how the script follows you and how it looks")
      }
    }
    .alert(
      "VidPrompt",
      isPresented: Binding(
        get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    ) {
      if store.hasFailedSaves {
        Button("Retry Save") { Task { await store.retryFailedSaves() } }.help("Try saving the pending edits again")
        Button("Keep Both") { Task { await store.keepBothFailedSaves() } }.help("Save both versions so neither edit is lost")
      }
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "Unknown error")
    }
    .onReceive(NotificationCenter.default.publisher(for: .vidPromptImport)) { _ in importing = true }
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
        ForEach(value.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
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
    .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
      TextField("Folder name", text: $renamedFolderName).help("Enter a new name for this folder")
      Button("Save") { if let folder = renamingFolder { store.renameFolder(folder.id, name: renamedFolderName) }; renamingFolder = nil }.help("Save the folder’s new name")
      Button("Cancel", role: .cancel) { renamingFolder = nil }
    }
    // The narrowest the three columns lay out in: SwiftUI asks twice the inspector's ideal width
    // (320) on top of the sidebar and editor. A smaller minimum let the window get narrower and
    // AppKit looped on constraints until it crashed; it holds with the inspector hidden too, so
    // showing it never needs a wider window. UIZoomTests checks it at every zoom step.
    .frame(minWidth: 932, minHeight: 500)
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
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Label(script.metadata.title, systemImage: "doc.text")
        if let path = script.metadata.linkedPath {
          let present = !(link?.isBroken ?? false)
          Image(systemName: present ? "link" : "link.badge.plus")
            .font(.caption).foregroundStyle(present ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .accessibilityLabel(present ? "Linked file" : "Linked file missing")
            .help(path)
        }
      }
      if !script.metadata.tags.isEmpty {
        Text(script.metadata.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }.tag(script.metadata.id)
  }
}

private struct EditorView: View {
  @ObservedObject var store: AppStore
  let script: ScriptRecord
  @State private var text = ""
  @State private var title = ""
  @State private var tags = ""
  @State private var editNotice: String?
  @State private var relinking = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Title", text: $title).textFieldStyle(.plain).font(.title2.weight(.semibold))
          .help("Name this script; press Return to save the title")
          .onSubmit { store.rename(title, for: script.metadata.id) }
        Spacer()
        TextField("Tags", text: $tags).help("Separate tags with commas; press Return to save them").textFieldStyle(.roundedBorder).frame(minWidth: 80, maxWidth: 190).onSubmit
        { store.setTags(tags.split(separator: ",").map(String.init), for: script.metadata.id) }
      }.padding(24)
      Divider()
      HStack(spacing: 10) {
        Text("Editor text").font(.caption).foregroundStyle(.secondary)
        Picker("Editor font", selection: $store.previewFontName) {
          ForEach(AvailableFonts.editor, id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.menu).labelsHidden().accessibilityLabel("Editor font").help("Change the editor font; presenter text has its own settings")
        Stepper(value: $store.previewFontSize, in: AppStore.editorFontSizes, step: 1) {
          Text("\(Int(store.previewFontSize)) pt").monospacedDigit()
        }.accessibilityLabel("Editor text size").help("Change text size while editing; presenter text has its own settings")
        Spacer()
      }.padding(.horizontal, 24).padding(.vertical, 8)
      if let editNotice {
        Text(editNotice).font(.callout).foregroundStyle(.secondary)
          .padding(.horizontal, 24).padding(.vertical, 8)
      }
      if let path = script.metadata.linkedPath {
        let state = store.linkStates[script.metadata.id]
        let present = !(state?.isBroken ?? false)
        HStack(spacing: 8) {
          Label(
            present ? "Linked to \(path)" : "Linked file missing: \(path)",
            systemImage: present ? "link" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(present ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .lineLimit(1)
            .truncationMode(.middle).help("Edits stay in sync with this Markdown file: " + path)
          Spacer()
          if !present { Button("Find linked file…") { relinking = true }.buttonStyle(.link).help("Choose the moved Markdown file and resolve any different text safely") }
          Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([state?.url ?? URL(fileURLWithPath: path)])
          }.buttonStyle(.link).disabled(!present).help("Show the linked Markdown file in Finder")
          Button("Unlink") { store.unlink(script.metadata.id) }.buttonStyle(.link).help("Keep this script in VidPrompt and stop updating the original file")
        }.padding(.horizontal, 24).padding(.vertical, 6)
      } else {
        HStack {
          Label("Stored in VidPrompt", systemImage: "doc.text")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Link File…") { relinking = true }.buttonStyle(.link).help("Link a Markdown file so edits stay in sync both ways")
        }.padding(.horizontal, 24).padding(.vertical, 6)
      }
      if store.unavailableScriptIDs.contains(script.metadata.id) {
        Label("Script file unavailable. Restore the original file, or export and import a copy.", systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24).padding(.vertical, 10)
      }
      FormattedMarkdownEditor(markdown: $text, fontName: store.previewFontName,
        fontSize: store.previewFontSize, onUnsupportedEdit: {
          editNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
        }).help("Type or paste your script; changes save automatically").padding(24)
    }
    .onChange(of: text) { _, value in editNotice = nil; store.updateMarkdown(value, for: script.metadata.id) }
    .onAppear {
      text = script.markdown
      title = script.metadata.title
      tags = script.metadata.tags.joined(separator: ", ")
    }
    .onChange(of: script.markdown) { _, value in if value != text { text = value } }
    .onChange(of: script.metadata.title) { _, value in if value != title { title = value } }
    .sheet(isPresented: $relinking) { RelinkSheet(store: store, script: script).uiZoom(store.uiZoom).frame(minWidth: 520 * store.uiZoom) }
    .id(script.metadata.id)
  }
}
