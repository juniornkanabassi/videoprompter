import AppKit
import PrompterCore
import SwiftUI

extension Notification.Name {
  static let juniorPrompterImport = Notification.Name("JuniorPrompter.import")
}

struct PrompterSettings: Codable, Equatable, Identifiable {
  var id = UUID()
  var name = "Default"
  var fontName = "SF Pro"
  var fontSize = 44.0
  var textOpacity = 1.0
  var backgroundOpacity = 0.82
  var guideFraction = 0.35
  var horizontalMirror = false
  var verticalMirror = false
  var rotation = 0
  var mode = "Voice"
  var speed = 120.0
  var audioDeviceUID: String?
  var inputGain = 1.0
  var soundThreshold = 0.055
  var speechLanguage = "Mixed"
  var fontWeight = "Regular"
  var textColorHex = "#FFFFFF"
  var backgroundColorHex = "#000000"
  var lineSpacing = 0.16
  var paragraphSpacing = 0.34
  var horizontalMargin = 42.0
  var alignment = "Left"
  var showCues = true
  var highlightActiveWord = false
  private enum CodingKeys: String, CodingKey { case id,name,fontName,fontSize,textOpacity,backgroundOpacity,guideFraction,horizontalMirror,verticalMirror,rotation,mode,speed,audioDeviceUID,inputGain,soundThreshold,speechLanguage,fontWeight,textColorHex,backgroundColorHex,lineSpacing,paragraphSpacing,horizontalMargin,alignment,showCues,highlightActiveWord }
  init() {}
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Default"; fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "SF Pro"; fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 44; textOpacity = try c.decodeIfPresent(Double.self, forKey: .textOpacity) ?? 1; backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.82; guideFraction = try c.decodeIfPresent(Double.self, forKey: .guideFraction) ?? 0.35; horizontalMirror = try c.decodeIfPresent(Bool.self, forKey: .horizontalMirror) ?? false; verticalMirror = try c.decodeIfPresent(Bool.self, forKey: .verticalMirror) ?? false; rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0; mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "Voice"; speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 120; audioDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioDeviceUID); inputGain = try c.decodeIfPresent(Double.self, forKey: .inputGain) ?? 1; soundThreshold = try c.decodeIfPresent(Double.self, forKey: .soundThreshold) ?? 0.055; speechLanguage = try c.decodeIfPresent(String.self, forKey: .speechLanguage) ?? "Mixed"; fontWeight = try c.decodeIfPresent(String.self, forKey: .fontWeight) ?? "Regular"; textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"; backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? "#000000"; lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0.16; paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 0.34; horizontalMargin = try c.decodeIfPresent(Double.self, forKey: .horizontalMargin) ?? 42; alignment = try c.decodeIfPresent(String.self, forKey: .alignment) ?? "Left"; showCues = try c.decodeIfPresent(Bool.self, forKey: .showCues) ?? true; highlightActiveWord = try c.decodeIfPresent(Bool.self, forKey: .highlightActiveWord) ?? false
  }
}

@MainActor final class AppStore: ObservableObject {
  @Published var scripts: [ScriptRecord] = []
  @Published var folders: [ScriptFolder] = []
  @Published var selectedFolderID: UUID?
  @Published var trash: [TrashEntry] = []
  @Published var selectedID: UUID?
  @Published var search = ""
  @Published var inspector = true
  @Published var settings = PrompterSettings() { didSet { persistSettings() } }
  @Published var presets: [PrompterSettings] = []
  @Published var errorMessage: String?
  @Published private(set) var hasFailedSaves = false
  @Published private(set) var libraryAvailable = false
  var scriptsTracked: Int { Set(scripts.map(\.id)).union(trash.map(\.id)).count }

  private(set) var library: MarkdownLibrary?
  let session = SessionStore()
  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  private var saveTaskTokens: [UUID: UUID] = [:]
  private var failedSaveIDs = Set<UUID>()
  private var pendingDrafts: [UUID: String] = [:]
  private var externalWatcher: Task<Void, Never>?
  private let defaults: UserDefaults

  init(arguments: [String] = CommandLine.arguments, defaults: UserDefaults? = nil) {
    let root: URL
    if let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count {
      root = URL(fileURLWithPath: arguments[i + 1])
    } else {
      root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("JuniorPrompter", isDirectory: true)
    }
    let hasTestDirectory = arguments.firstIndex(of: "--data-directory").map { $0 + 1 < arguments.count } ?? false
    let isolatedDefaults = defaults ?? (hasTestDirectory
      ? UserDefaults(suiteName: "JuniorPrompter.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))")!
      : .standard)
    self.defaults = isolatedDefaults
    if let data = isolatedDefaults.data(forKey: "settings"),
      let saved = try? JSONDecoder().decode(PrompterSettings.self, from: data)
    {
      settings = saved
    }
    if let data = isolatedDefaults.data(forKey: "presets"),
      let saved = try? JSONDecoder().decode([PrompterSettings].self, from: data)
    {
      presets = saved
    }
    do {
      library = try MarkdownLibrary(rootURL: root)
      libraryAvailable = true
    } catch { errorMessage = "The script library could not be opened safely. \(error)" }
    Task { await reload() }
    externalWatcher = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        await self?.refreshExternalChanges()
      }
    }
  }

  var selected: ScriptRecord? { scripts.first { $0.metadata.id == selectedID } }
  var visible: [ScriptRecord] {
    let scoped = selectedFolderID.map { id in scripts.filter { $0.metadata.folderID == id } } ?? scripts
    guard !search.isEmpty else { return scoped }
    return scoped.filter {
      $0.metadata.title.localizedCaseInsensitiveContains(search)
        || $0.markdown.localizedCaseInsensitiveContains(search)
        || $0.metadata.tags.contains { $0.localizedCaseInsensitiveContains(search) }
    }
  }

  func reload() async {
    guard let library else { return }
    do {
      var loaded: [ScriptRecord] = []
      for metadata in await library.listScripts() {
        loaded.append(try await library.read(metadata.id))
      }
      scripts = loaded
      trash = await library.listTrash()
      folders = await library.listFolders()
      if let selectedID, loaded.contains(where: { $0.metadata.id == selectedID }) {
        self.selectedID = selectedID
      } else {
        selectedID = loaded.first?.metadata.id
      }
    } catch { errorMessage = String(describing: error) }
  }
  func createFolder(named name: String) {
    guard let library else { return }
    Task { do { folders.append(try await library.createFolder(name: name)) } catch { errorMessage = String(describing: error) } }
  }
  func renameFolder(_ id: UUID, name: String) { guard let library else { return }; Task { do { try await library.renameFolder(id, name: name); if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].name = name } } catch { errorMessage = String(describing: error) } } }
  func deleteFolder(_ id: UUID) { guard let library else { return }; Task { do { try await library.deleteFolder(id); folders.removeAll { $0.id == id }; scripts = scripts.map { var s = $0; if s.metadata.folderID == id { s.metadata.folderID = nil }; return s }; if selectedFolderID == id { selectedFolderID = nil } } catch { errorMessage = String(describing: error) } } }
  func moveSelectedScripts(_ ids: Set<UUID>, to folderID: UUID?) {
    guard let library else { return }
    Task {
      do {
        try await library.moveScripts(ids, to: folderID)
        for i in scripts.indices where ids.contains(scripts[i].id) { scripts[i].metadata.folderID = folderID }
        if let selectedID, !visible.contains(where: { $0.id == selectedID }) { self.selectedID = visible.first?.id }
      } catch { errorMessage = String(describing: error) }
    }
  }
  func selectFolder(_ id: UUID?) {
    selectedFolderID = id
    selectedID = visible.first?.id
  }

  func create(title: String = "Untitled Script", markdown: String = "") {
    guard let library else { return }
    Task {
      do {
        let item = try await library.create(title: title, markdown: markdown, folderID: selectedFolderID)
        scripts.insert(item, at: 0)
        selectedID = item.metadata.id
      } catch { errorMessage = String(describing: error) }
    }
  }
  func duplicate() {
    guard let library, let selected else { return }
    Task {
      do {
        let item = try await library.duplicate(selected.metadata.id)
        scripts.insert(item, at: 0)
        selectedID = item.metadata.id
      } catch { errorMessage = String(describing: error) }
    }
  }
  func delete(_ ids: Set<UUID>) {
    guard let library else { return }
    for id in ids {
      Task {
        do {
          guard await self.flushPendingSaves() else {
            self.errorMessage = "Save the pending edits before moving scripts to Trash."
            return
          }
          try await library.delete(id)
          scripts.removeAll { $0.metadata.id == id }
          trash = await library.listTrash()
          if selectedID == id { selectedID = visible.first?.id }
          if session.activeScriptID == id { session.stop() }
        } catch { errorMessage = String(describing: error) }
      }
    }
  }
  func restore(_ id: UUID) {
    guard let library else { return }
    Task {
      do {
        _ = try await library.restore(id)
        await reload()
      } catch { errorMessage = String(describing: error) }
    }
  }

  func updateMarkdown(_ value: String, for id: UUID) {
    guard let position = scripts.firstIndex(where: { $0.metadata.id == id }),
      scripts[position].markdown != value
    else { return }
    scripts[position].markdown = value
    var draft = scripts[position]
    draft.metadata.revision &+= 1
    session.applyEditedRecord(draft)
    saveTasks[id]?.cancel()
    let taskToken = UUID()
    saveTaskTokens[id] = taskToken
    let expected = scripts[position].metadata.contentFingerprint
    pendingDrafts[id] = value
    saveTasks[id] = Task { [weak self] in
      defer {
        if self?.saveTaskTokens[id] == taskToken {
          self?.saveTasks[id] = nil
          self?.saveTaskTokens[id] = nil
        }
      }
      do {
        try await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, let self, let library = self.library else { return }
        let saved = try await library.save(id, markdown: value, expectedFingerprint: expected)
        guard !Task.isCancelled,
          let current = self.scripts.firstIndex(where: { $0.metadata.id == id }),
          self.scripts[current].markdown == value
        else { return }
        self.scripts[current] = saved
        self.failedSaveIDs.remove(id)
        self.hasFailedSaves = !self.failedSaveIDs.isEmpty
        self.pendingDrafts[id] = nil
        self.session.applyEditedRecord(saved)
      } catch is CancellationError {} catch {
        self?.failedSaveIDs.insert(id)
        self?.hasFailedSaves = true
        self?.errorMessage = "The edit was preserved but could not replace the file. \(error)"
      }
    }
  }
  func flushPendingSaves() async -> Bool {
    let pending = Array(saveTasks.values)
    for task in pending { await task.value }
    return failedSaveIDs.isEmpty && saveTasks.isEmpty
  }
  func retryFailedSaves() async {
    guard let library else { return }
    for id in failedSaveIDs {
      guard let draft = pendingDrafts[id], let current = scripts.first(where: { $0.id == id }) else { continue }
      do {
        let saved = try await library.save(id, markdown: draft, expectedFingerprint: current.metadata.contentFingerprint)
        guard let index = scripts.firstIndex(where: { $0.id == id }), scripts[index].markdown == draft else { continue }
        scripts[index] = saved
        failedSaveIDs.remove(id)
        hasFailedSaves = !failedSaveIDs.isEmpty
        pendingDrafts[id] = nil
      } catch { hasFailedSaves = true; errorMessage = "The edit was preserved but could not replace the file. \(error)" }
    }
  }
  func rename(_ value: String, for id: UUID) {
    guard let library else { return }
    Task {
      do {
        let metadata = try await library.updateMetadata(id, title: value)
        if let i = scripts.firstIndex(where: { $0.metadata.id == id }) {
          scripts[i].metadata = metadata
        }
      } catch { errorMessage = String(describing: error) }
    }
  }
  func setTags(_ tags: [String], for id: UUID) {
    guard let library else { return }
    Task {
      do {
        let metadata = try await library.updateMetadata(id, tags: tags)
        if let i = scripts.firstIndex(where: { $0.metadata.id == id }) {
          scripts[i].metadata = metadata
        }
      } catch { errorMessage = String(describing: error) }
    }
  }

  func savePreset(named name: String) {
    var preset = settings
    preset.id = UUID()
    preset.name =
      name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Preset \(presets.count + 1)" : name
    presets.append(preset)
    persistSettings()
  }
  func renamePreset(_ id: UUID, name: String) {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { errorMessage = "Preset names cannot be empty."; return }
    presets[index].name = clean
    persistSettings()
  }
  func duplicatePreset(_ id: UUID) {
    guard let source = presets.first(where: { $0.id == id }) else { return }
    var copy = source
    copy.id = UUID()
    copy.name = "\(source.name) copy"
    presets.append(copy)
    persistSettings()
  }
  func updatePreset(_ id: UUID) {
    guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
    var updated = settings
    updated.id = id
    updated.name = presets[index].name
    presets[index] = updated
    persistSettings()
  }
  func applyPreset(_ preset: PrompterSettings) {
    let currentName = settings.name
    settings = preset
    settings.name = currentName
  }
  func deletePreset(_ id: UUID) {
    presets.removeAll { $0.id == id }
    persistSettings()
  }
  private func persistSettings() {
    if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
    if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "presets") }
  }
  func refreshExternalChanges() async {
    guard let library else { return }
    for item in scripts
    where (saveTasks[item.metadata.id] == nil || saveTasks[item.metadata.id]?.isCancelled == true)
      && !failedSaveIDs.contains(item.metadata.id) {
      do {
        if let changed = try await library.externalChange(for: item.metadata.id),
          !failedSaveIDs.contains(item.metadata.id),
          saveTasks[item.metadata.id] == nil,
          let i = scripts.firstIndex(where: { $0.metadata.id == item.metadata.id })
        {
          scripts[i] = changed
          session.applyEditedRecord(changed)
        }
      } catch { errorMessage = String(describing: error) }
    }
  }
}

@main struct JuniorPrompterApp: App {
  @StateObject private var store = AppStore()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  var body: some Scene {
    WindowGroup("JuniorPrompter") {
      LibraryView(store: store)
        .background(MainWindowConfigurator())
        .onAppear { appDelegate.store = store }
    }
      .defaultSize(width: 1100, height: 750)
      .windowResizability(.contentSize)
      .commands {
        CommandMenu("Prompter") {
          Button("Present Script") { PresenterController.shared.present(store: store) }
            .keyboardShortcut("P", modifiers: [.command, .option])
          Button("New Script") { store.create() }.keyboardShortcut(
            "N", modifiers: [.command, .shift])
          Button("Import Script") { NotificationCenter.default.post(name: .juniorPrompterImport, object: nil) }
            .keyboardShortcut("I", modifiers: [.command])
          Button("Import Clipboard") {
            if let markdown = NSPasteboard.general.string(forType: .string), !markdown.isEmpty {
              store.create(title: "Pasted Script", markdown: markdown)
            }
          }
          Divider()
          Button("Play or Pause") { store.session.toggle() }.keyboardShortcut(
            .space, modifiers: [.command, .option])
        }
      }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var store: AppStore?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store else { return .terminateNow }
    Task {
      let saved = await store.flushPendingSaves()
      if !saved && store.errorMessage == nil { store.errorMessage = "A script edit could not be saved. Retry the save before quitting." }
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}

private struct MainWindowConfigurator: NSViewRepresentable {
  final class Coordinator {
    var placed = false
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
  func updateNSView(_ view: NSView, context: Context) {
    guard CommandLine.arguments.contains("--agent-screen"), !context.coordinator.placed else { return }
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      guard let screen = NSScreen.screens.first(where: { $0.localizedName == "Agent Screen" }) else {
        window.orderOut(nil)
        context.coordinator.placed = true
        return
      }
      var frame = NSRect(origin: .zero, size: NSSize(width: 1100, height: 750))
      frame.origin = NSPoint(
        x: screen.visibleFrame.midX - frame.width / 2,
        y: screen.visibleFrame.midY - frame.height / 2)
      frame = frame.intersection(screen.visibleFrame)
      window.setFrame(frame, display: true)
      window.orderFrontRegardless()
      context.coordinator.placed = true
    }
  }
}
