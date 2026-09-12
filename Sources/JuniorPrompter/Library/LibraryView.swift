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
          Button { store.selectFolder(nil) } label: { Label("All Scripts", systemImage: "tray.full") }
            .tag(Optional<UUID>.none)
          ForEach(store.folders) { folder in
            Button { store.selectFolder(folder.id) } label: { Label(folder.name, systemImage: "folder") }
              .contextMenu {
                Button("Rename Folder") { renamingFolder = folder; renamedFolderName = folder.name }
                Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id) }
              }
          }
          HStack {
            TextField("New folder", text: $newFolderName)
            Button { store.createFolder(named: newFolderName); newFolderName = "" } label: { Image(systemName: "plus") }
              .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        Section("Scripts") {
          ForEach(store.visible) { script in ScriptRow(script: script) }
        }
        if !store.trash.isEmpty {
          Section("Recently Deleted") {
            ForEach(store.trash) { entry in
              HStack {
                Label(entry.metadata.title, systemImage: "trash")
                Spacer()
                Button("Restore") { store.restore(entry.id) }.buttonStyle(.link)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button {
            store.create()
          } label: {
            Label("New", systemImage: "plus")
          }
          Spacer()
          Button {
            store.delete(selection)
          } label: {
            Image(systemName: "trash")
          }.disabled(selection.isEmpty)
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
    } detail: {
      if let script = store.selected {
        EditorView(store: store, script: script)
      } else {
        ContentUnavailableView("Select a script", systemImage: "doc.text")
      }
    }
    .navigationSplitViewStyle(.balanced)
    .inspector(isPresented: $store.inspector) {
      InspectorView(store: store).frame(minWidth: 300, idealWidth: 320)
    }
    .navigationTitle("JuniorPrompter")
    .searchable(text: $store.search, placement: .toolbar, prompt: "Search scripts")
    .toolbar {
      ToolbarItemGroup {
        Button {
          store.create()
        } label: {
          Label("New", systemImage: "square.and.pencil")
        }.disabled(!store.libraryAvailable)
        Button("Import…") { importing = true }.disabled(!store.libraryAvailable)
        Menu {
          Button("Import from Clipboard") {
            guard let markdown = NSPasteboard.general.string(forType: .string), !markdown.isEmpty else { return }
            store.create(title: "Pasted Script", markdown: markdown)
          }
          Button("Export Markdown…") {
            guard let script = store.selected else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(script.metadata.title).md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try script.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { importError = "Could not export the script. \(error.localizedDescription)" }
          }.disabled(store.selected == nil)
          Button("Reveal in Finder") {
            guard let id = store.selectedID else { return }
            Task {
              do {
                let url = try await store.library!.scriptURL(for: id)
                NSWorkspace.shared.activateFileViewerSelecting([url])
              } catch { importError = "Could not reveal the script. \(error.localizedDescription)" }
            }
          }.disabled(store.selected == nil)
        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Script actions")
          .disabled(!store.libraryAvailable)
        Button {
          store.duplicate()
        } label: {
          Label("Duplicate", systemImage: "plus.square.on.square")
        }.disabled(store.selected == nil)
        Menu("Move to") {
          Button("All Scripts") { store.moveSelectedScripts(selection, to: nil) }
          ForEach(store.folders) { folder in
            Button(folder.name) { store.moveSelectedScripts(selection, to: folder.id) }
          }
        }.disabled(selection.isEmpty)
        Button {
          PresenterController.shared.present(store: store)
        } label: {
          Label("Present", systemImage: "play.rectangle")
        }.disabled(store.selected == nil)
        Button {
          store.inspector.toggle()
        } label: {
          Label("Inspector", systemImage: "sidebar.right")
        }
      }
    }
    .alert(
      "JuniorPrompter",
      isPresented: Binding(
        get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    ) {
      if store.hasFailedSaves {
        Button("Retry Save") { Task { await store.retryFailedSaves() } }
        Button("Keep Both") { Task { await store.keepBothFailedSaves() } }
      }
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "Unknown error")
    }
    .onReceive(NotificationCenter.default.publisher(for: .juniorPrompterImport)) { _ in importing = true }
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
        TextEditor(text: .constant(value.markdown)).font(.system(.body, design: .serif))
          .frame(minWidth: 600, minHeight: 400)
        ForEach(value.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
        HStack {
          Spacer()
          Button("Cancel") { importPreview = nil }
          Button("Import") {
            store.create(title: value.sourceURL.deletingPathExtension().lastPathComponent, markdown: value.markdown)
            importPreview = nil
          }.buttonStyle(.borderedProminent)
        }
      }.padding(24)
      }
    }
    .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
      Button("OK") { importError = nil }
    } message: { Text(importError ?? "The document could not be imported.") }
    .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
      TextField("Folder name", text: $renamedFolderName)
      Button("Save") { if let folder = renamingFolder { store.renameFolder(folder.id, name: renamedFolderName) }; renamingFolder = nil }
      Button("Cancel", role: .cancel) { renamingFolder = nil }
    }
    .frame(minWidth: 760, minHeight: 500)
  }
}

private struct ScriptRow: View {
  let script: ScriptRecord
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label(script.metadata.title, systemImage: "doc.text")
      if !script.metadata.tags.isEmpty {
        Text(script.metadata.tags.joined(separator: ", ")).font(.caption).foregroundStyle(
          .secondary
        ).lineLimit(1)
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

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Title", text: $title).textFieldStyle(.plain).font(.title2.weight(.semibold))
          .onSubmit { store.rename(title, for: script.metadata.id) }
        Spacer()
        TextField("Tags", text: $tags).textFieldStyle(.roundedBorder).frame(maxWidth: 190).onSubmit
        { store.setTags(tags.split(separator: ",").map(String.init), for: script.metadata.id) }
      }.padding(24)
      Divider()
      HStack(spacing: 10) {
        Text("Font").font(.caption).foregroundStyle(.secondary)
        Picker("Editor font", selection: $store.previewFontName) {
          ForEach(Self.fontChoices, id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.menu).labelsHidden().accessibilityLabel("Editor font")
        Stepper(value: $store.previewFontSize, in: 12...40, step: 1) {
          Text("\(Int(store.previewFontSize)) pt").monospacedDigit()
        }.accessibilityLabel("Editor font size")
        Spacer()
      }.padding(.horizontal, 24).padding(.vertical, 8)
      if let editNotice {
        Text(editNotice).font(.callout).foregroundStyle(.secondary)
          .padding(.horizontal, 24).padding(.vertical, 8)
      }
      if store.unavailableScriptIDs.contains(script.metadata.id) {
        Label("Script file unavailable. Restore the original file, or export and import a copy.", systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24).padding(.vertical, 10)
      }
      FormattedMarkdownEditor(markdown: $text, fontName: store.previewFontName,
        fontSize: store.previewFontSize, onUnsupportedEdit: {
          editNotice = "That change could not be applied safely. Your text is unchanged. Try a smaller selection."
        }).padding(24)
    }
    .onChange(of: text) { _, value in
      editNotice = nil
      store.updateMarkdown(value, for: script.metadata.id)
    }
    .onAppear {
      text = script.markdown
      title = script.metadata.title
      tags = script.metadata.tags.joined(separator: ", ")
    }
    .onChange(of: script.markdown) { _, value in if value != text { text = value } }
    .onChange(of: script.metadata.title) { _, value in if value != title { title = value } }
    .id(script.metadata.id)
  }

  private static let fontChoices = AvailableFonts.editor
}
