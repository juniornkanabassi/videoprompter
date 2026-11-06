import AVFoundation
import AppKit
import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

private enum PresenterSaveError: LocalizedError {
  case changedBeforeSave, changedDuringSave
  var errorDescription: String? {
    switch self {
    case .changedBeforeSave: return "A newer library edit is waiting to be saved."
    case .changedDuringSave: return "A newer library edit arrived while this draft was saving."
    }
  }
}

@MainActor final class AppStore: ObservableObject {
  /// The app's one store. Shared so the control server can start without a library window: a headless launch has none.
  static let shared = AppStore()
  @Published var scripts: [ScriptRecord] = []
  @Published var folders: [ScriptFolder] = []
  @Published var selectedFolderID: UUID?
  @Published var trash: [TrashEntry] = []
  @Published var selectedID: UUID?
  /// The sidebar's selection, which File > Move to Trash acts on as a whole.
  @Published var selectedIDs = Set<UUID>()
  @Published var search = ""
  @Published var inspector = true
  /// Settings › More is expanded while this is false. The name is the stored key's.
  @Published var simpleInterface = true { didSet { persistSettings() } }
  /// File > New Folder…, the Add menu and the sidebar ask the library window for a name.
  @Published var namingNewFolder = false
  /// The script whose Markdown file is being linked or found again.
  @Published var relinkingID: UUID?
  @Published var settings = PrompterSettings() { didSet { var safe = settings; safe.sanitise(); if safe != settings { settings = safe }; persistSettings(); CameraRecorder.shared.useSettings(settings) } }
  @Published var presets: [PrompterSettings] = [] { didSet { persistSettings() } }
  @Published var sourceFontName = "Lexend Deca" { didSet { persistSettings() } }
  @Published var sourceFontSize = 17.0 { didSet { let safe = InputValidation.editorSize.repair(sourceFontSize); if sourceFontSize != safe { sourceFontSize = safe }; persistSettings() } }
  @Published var previewFontName = "Lexend Deca" { didSet { persistSettings() } }
  @Published var previewFontSize = 18.0 { didSet { let safe = InputValidation.editorSize.repair(previewFontSize); if previewFontSize != safe { previewFontSize = safe }; persistSettings() } }
  /// View > Zoom In, Zoom Out and Actual Size: the whole library window and the presenter's controls.
  @Published var uiZoom = 1.0 { didSet { let safe = InputValidation.zoom.repair(uiZoom); if uiZoom != safe { uiZoom = safe }; persistSettings() } }
  /// Nothing below 100%: zoomed out, a pane's AppKit views are laid out wider than their column,
  /// and AppKit then refuses clicks on the part that would overlap the next column.
  static let uiZoomSteps = [1, 1.1, 1.25, 1.5, 1.75, 2]
  static let presenterFontSizes = InputValidation.fontSize.range
  static let editorFontSizes = InputValidation.editorSize.range
  @Published var libraryNotice: String?
  @Published var errorMessage: String?
  @Published var linkedSyncStatus: String?
  private var deferredExternalReads = Set<UUID>()
  /// Shown once, in the inspector, when a saved Timed, Manual or Sound mode was migrated.
  @Published private(set) var modeMigrationNotice: String?
  private static let modeMigrationKey = "modeMigrationNoticeVersion"

  func stepUIZoom(in zoomIn: Bool) {
    let steps = Self.uiZoomSteps
    uiZoom = zoomIn ? steps.first { $0 > uiZoom + 0.001 } ?? steps.last! : steps.last { $0 < uiZoom - 0.001 } ?? steps.first!
  }

  /// View > Make Text Bigger and Make Text Smaller: about 10% a step, on the presenter's text when
  /// it is the key window and on the library editor's otherwise. Both sizes are the saved settings.
  func zoomText(in zoomIn: Bool, presenter: Bool) {
    func step(_ size: Double, _ sizes: ClosedRange<Double>) -> Double {
      let next = zoomIn ? max(size + 1, (size * 1.1).rounded()) : min(size - 1, (size / 1.1).rounded())
      return min(max(next, sizes.lowerBound), sizes.upperBound)
    }
    if presenter { settings.fontSize = step(settings.fontSize, Self.presenterFontSizes) }
    else { previewFontSize = step(previewFontSize, Self.editorFontSizes) }
  }
  func zoomFocusedText(in zoomIn: Bool) {
    let panel = PresenterController.shared.panel
    zoomText(in: zoomIn, presenter: panel != nil && NSApp.keyWindow === panel)
  }
  /// Written when a legacy mode is first seen, because the settings saved right after decoding
  /// overwrite it; a relaunch before dismissal still finds this and shows the notice again.
  private static let modeMigrationPendingKey = "modeMigrationNoticePending"
  @Published private(set) var hasFailedSaves = false
  @Published private(set) var libraryAvailable = false
  @Published private(set) var unavailableScriptIDs = Set<UUID>()
  private(set) var deletingIDs = Set<UUID>()
  var deleteGate: (() async -> Void)?
  /// The library's own answer for each linked script; the views never ask the file system.
  @Published private(set) var linkStates: [UUID: LinkState] = [:]

  private(set) var library: MarkdownLibrary?
  let session: SessionStore
  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  private var saveTaskTokens: [UUID: UUID] = [:]
  private var presenterSaveIDs = Set<UUID>()
  var presenterSaveReservationHook: (() -> Void)?
  var presenterSaveReservationGate: (() async -> Void)?
  /// Test seam: runs after a debounced save has resolved its fingerprint, just before it writes.
  var saveGate: (() async -> Void)?
  private var presenterSaveWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var failedSaveIDs = Set<UUID>()
  private var pendingDrafts: [UUID: String] = [:]
  private var externalWatcher: Task<Void, Never>?
  private var initialLoad: Task<Void, Never>?
  private var welcomeTask: Task<Void, Never>?
  // nonisolated so `deinit` can take the observer back out again.
  nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
  /// Activation can arrive in a burst; a full refresh reads every script, so it is not worth
  /// repeating on top of the two-second poll.
  private var lastExternalRefresh = Date.distantPast
  private let defaults: UserDefaults
  private let settingsPersistence: SettingsPersistence

  static func preferences(arguments: [String] = CommandLine.arguments) -> UserDefaults {
    guard let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count else { return .standard }
    let root = ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: arguments)
    // Keep the legacy suite prefix so the public rename preserves isolated settings.
    return UserDefaults(suiteName: "VidPrompt.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))")!
  }
  /// `offersWelcomeScript` defaults to off for `--data-directory` launches (tests and the built-app
  /// checker), so their libraries start empty.
  init(arguments: [String] = CommandLine.arguments, defaults: UserDefaults? = nil, offersWelcomeScript: Bool? = nil) {
    _ = AvailableFonts.presenter
    let root = ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: arguments)
    let isolatedDefaults = defaults ?? Self.preferences(arguments: arguments)
    self.defaults = isolatedDefaults
    self.settingsPersistence = SettingsPersistence(defaults: isolatedDefaults)
    self.session = SessionStore(defaults: isolatedDefaults)
    func stored<T: Decodable>(_ key: String) -> T? {
      isolatedDefaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    // Decoding folds legacy modes into Voice and Manual and the assignments below save that over
    // them, so the notice looks at the stored modes first and keeps a pending marker until it is
    // dismissed. A launch with nothing to migrate is marked as seen, so a later saved "Manual" is
    // not mistaken for a legacy one.
    if isolatedDefaults.integer(forKey: Self.modeMigrationKey) < 1 {
      struct SavedMode: Decodable { var mode: String? }
      let saved = (isolatedDefaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(SavedMode.self, from: $0) }
        .map { [$0] } ?? [])
        + (isolatedDefaults.data(forKey: "presets").flatMap { try? JSONDecoder().decode([SavedMode].self, from: $0) } ?? [])
      if isolatedDefaults.bool(forKey: Self.modeMigrationPendingKey)
        || saved.contains(where: { PrompterSettings.legacyModes.contains($0.mode ?? "") })
      {
        isolatedDefaults.set(true, forKey: Self.modeMigrationPendingKey)
        modeMigrationNotice = "Reading now has two modes. The older Timed and Manual modes now use Automatic scroll: choose a words-per-minute speed and press Start reading. Reading presets that used Sound now use Voice follow."
      } else {
        isolatedDefaults.set(1, forKey: Self.modeMigrationKey)
      }
    }
    // Read all three first: a @Published didSet runs even here, and it saves all three.
    let savedPresets: [PrompterSettings]? = stored("presets")
    let savedTypography: EditorTypographyPreferences? = stored("editorTypography")
    let savedSettings: PrompterSettings? = stored("settings")
    let savedSimple = isolatedDefaults.object(forKey: "simpleInterface") == nil || isolatedDefaults.bool(forKey: "simpleInterface")
    let savedZoom = isolatedDefaults.double(forKey: "uiZoom")
    uiZoom = InputValidation.zoom.repair(savedZoom)
    if let savedPresets { presets = savedPresets }
    if let savedTypography {
      sourceFontName = savedTypography.sourceFontName
      sourceFontSize = InputValidation.editorSize.repair(savedTypography.sourceFontSize)
      previewFontName = savedTypography.previewFontName
      previewFontSize = InputValidation.editorSize.repair(savedTypography.previewFontSize)
    }
    if let savedSettings { settings = savedSettings }
    else { settings.audioDeviceUID = AVCaptureDevice.default(for: .audio)?.uniqueID }
    simpleInterface = savedSimple
    do {
      library = try MarkdownLibrary(rootURL: root)
      libraryAvailable = true
    } catch { errorMessage = "The script library could not be opened safely. Check that its folder is available and readable, then reopen Video Prompter. Details: \(error.localizedDescription)" }
    initialLoad = Task { await reload() }
    if offersWelcomeScript ?? !arguments.contains("--data-directory") {
      welcomeTask = Task { [weak self] in await self?.addWelcomeScriptIfNew() }
    }
    externalWatcher = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        await self?.refreshExternalChanges()
        await self?.syncICloudScripts()
      }
    }
    // Coming back from MarkEdit or Obsidian should not wait for the next tick.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, Date().timeIntervalSince(self.lastExternalRefresh) >= 1 else { return }
        await self.refreshExternalChanges()
      }
    }
  }

  deinit {
    externalWatcher?.cancel()
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
  }


  var selected: ScriptRecord? { scripts.first { $0.metadata.id == selectedID } }
  var visible: [ScriptRecord] {
    let scoped = selectedFolderID.map { id in scripts.filter { $0.metadata.folderID == id } } ?? scripts
    guard !search.isEmpty else { return scoped }
    // Case and accents both fold: "Barca" finds "Barça".
    func matches(_ text: String) -> Bool {
      text.range(of: search, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
    return scoped.filter {
      matches($0.metadata.title) || matches($0.markdown) || $0.metadata.tags.contains(where: matches)
    }
  }

  func reload() async {
    guard let library else { return }
    var loaded: [ScriptRecord] = []
    for metadata in await library.listScripts() {
      do {
        loaded.append(try await library.read(metadata.id))
        unavailableScriptIDs.remove(metadata.id)
      } catch {
        if let cached = scripts.first(where: { $0.id == metadata.id }) {
          loaded.append(cached)
        }
        if Self.isMissingFile(error) {
          unavailableScriptIDs.insert(metadata.id)
        } else {
          errorMessage = "The script could not be loaded. Check that its file is available, then select it again. Details: \(error.localizedDescription)"
        }
      }
    }
    let protectedIDs = Set(saveTasks.keys).union(failedSaveIDs).union(presenterSaveIDs)
    for id in protectedIDs {
      if !loaded.contains(where: { $0.id == id }), let cached = scripts.first(where: { $0.id == id }) {
        loaded.append(cached)
      }
    }
    loaded = loaded.map { record in
      protectedIDs.contains(record.id) ? (scripts.first(where: { $0.id == record.id }) ?? record) : record
    }
    scripts = loaded
    await refreshLinkStates()
    trash = await library.listTrash()
    folders = await library.listFolders()
    if let selectedID, loaded.contains(where: { $0.metadata.id == selectedID }) {
      self.selectedID = selectedID
    } else {
      selectedID = loaded.first?.metadata.id
    }
  }
  func waitForInitialLoad() async { await initialLoad?.value }
  func waitForWelcomeScript() async { await welcomeTask?.value }
  /// A new library starts with the welcome script, once. A library that already has scripts, in it
  /// or in its Trash, is only marked as offered, so updating never adds it. The library's index decides,
  /// not `scripts`, which leaves out a script whose file could not be read. A failed add is not marked,
  /// so it is tried again next launch.
  private func addWelcomeScriptIfNew() async {
    await waitForInitialLoad()
    guard let library, libraryAvailable, !defaults.bool(forKey: WelcomeScript.offeredKey) else { return }
    guard await library.listScripts().isEmpty, await library.listTrash().isEmpty else {
      defaults.set(true, forKey: WelcomeScript.offeredKey)
      return
    }
    do {
      _ = try await createScript(title: WelcomeScript.title, markdown: WelcomeScript.markdown)
      defaults.set(true, forKey: WelcomeScript.offeredKey)
    } catch {
      errorMessage = "The welcome script could not be added. \(error)"
    }
  }
  /// Help > Practice Script: selects it in the whole library, or adds a fresh copy when it has gone.
  /// While the first-launch add is still running it waits for that, so the script is never added twice.
  func showWelcomeScript() {
    guard let welcomeTask else { return selectWelcomeScript() }
    Task { [weak self] in
      await welcomeTask.value
      self?.selectWelcomeScript()
    }
  }
  private func selectWelcomeScript() {
    selectedFolderID = nil
    search = ""
    if let existing = scripts.first(where: { $0.metadata.title == WelcomeScript.title }) {
      selectedID = existing.id
    } else {
      create(title: WelcomeScript.title, markdown: WelcomeScript.markdown)
    }
  }
  /// Runs a library change on the main actor; a failure shows in the error alert.
  private func withLibrary(_ work: @escaping @MainActor (MarkdownLibrary) async throws -> Void) {
    guard let library else { return }
    Task { do { try await work(library) } catch let error as PendingEditsError { errorMessage = error.description } catch { errorMessage = "The library change could not be saved. Check free space and access to the script folder, then try again. Details: \(error.localizedDescription)" } }
  }
  func createFolder(named name: String) {
    withLibrary { [self] _ in _ = try await createLibraryFolder(named: name) }
  }
  func renameFolder(_ id: UUID, name: String) {
    withLibrary { [self] _ in try await renameLibraryFolder(id, name: name) }
  }
  @discardableResult func createLibraryFolder(named name: String) async throws -> ScriptFolder {
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    let folder = try await library.createFolder(name: name)
    folders.append(folder)
    return folder
  }
  func renameLibraryFolder(_ id: UUID, name: String) async throws {
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    try await library.renameFolder(id, name: name)
    if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].name = name }
  }
  private var folderChangeTask: Task<Void, Never>?
  private var folderChangeRevision = 0
  func deleteFolder(_ id: UUID, undoManager: UndoManager? = nil) {
    guard let folder = folders.first(where: { $0.id == id }) else { return }
    let members = Set(scripts.filter { $0.metadata.folderID == id }.map(\.id)
      + trash.filter { $0.metadata.folderID == id }.map(\.id))
    changeFolder(folder, members: members, deleting: true, undoManager: undoManager)
  }
  /// One queued folder change. It is also the undo target, so a failed change can remove just its own
  /// entry instead of the store's whole undo stack.
  private final class FolderChange { var failed = false }
  private func changeFolder(_ folder: ScriptFolder, members: Set<UUID>, deleting: Bool,
                            undoManager: UndoManager?, inverting: FolderChange? = nil) {
    let change = FolderChange()
    // Registered now, before the disk work, so Undo is offered at once and sits in the right place
    // on the stack; the disk changes stay ordered behind folderChangeTask.
    undoManager?.registerUndo(withTarget: change) { [weak self, weak undoManager] _ in
      // `change` is held here, not by UndoManager, so the entry keeps its target alive.
      self?.changeFolder(folder, members: members, deleting: !deleting, undoManager: undoManager, inverting: change)
    }
    undoManager?.setActionName("Delete Folder")
    folderChangeRevision += 1
    let previous = folderChangeTask
    folderChangeTask = Task { [self, weak undoManager] in
      await previous?.value
      // Undoing a change that never reached the disk has nothing to reverse.
      if inverting?.failed == true {
        change.failed = true
        undoManager?.removeAllActions(withTarget: change)
        return
      }
      guard let library else { return }
      do {
        if deleting { try await library.deleteFolder(folder.id) }
        else { try await library.restoreFolder(folder, scriptIDs: members) }
        folders = await library.listFolders()
        for i in scripts.indices {
          if deleting, scripts[i].metadata.folderID == folder.id { scripts[i].metadata.folderID = nil }
          else if !deleting, members.contains(scripts[i].id), scripts[i].metadata.folderID == nil { scripts[i].metadata.folderID = folder.id }
        }
        trash = await library.listTrash()
        if deleting, selectedFolderID == folder.id { selectedFolderID = nil }
      } catch {
        change.failed = true
        undoManager?.removeAllActions(withTarget: change)
        errorMessage = "The library change could not be saved. Check free space and access to the script folder, then try again. Details: \(error.localizedDescription)"
      }
    }
  }
  /// Menu/shortcut deletion yields to native typing in the script, title and tags.
  func trashSelectionFromMenu(in window: NSWindow? = NSApp.keyWindow) {
    guard Self.canTrashSelection(in: window) else { return }
    delete(selectedIDs, undoManager: window?.undoManager)
  }
  static func canTrashSelection(in window: NSWindow?) -> Bool {
    guard !(window is PresenterPanel), !(window?.firstResponder is NSTextView) else { return false }
    if let field = window?.firstResponder as? NSTextField, field.isEditable { return false }
    return true
  }

  /// Right-clicking within a selection keeps bulk actions; another row acts on itself.
  func contextSelection(for id: UUID) -> Set<UUID> {
    selectedIDs.contains(id) ? selectedIDs : [id]
  }

  func moveSelectedScripts(_ ids: Set<UUID>, to folderID: UUID?) {
    withLibrary { [self] _ in try await moveScripts(ids, to: folderID) }
  }
  func moveScripts(_ ids: Set<UUID>, to folderID: UUID?) async throws {
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    try await library.moveScripts(ids, to: folderID)
    for i in scripts.indices where ids.contains(scripts[i].id) { scripts[i].metadata.folderID = folderID }
    if let selectedID, !visible.contains(where: { $0.id == selectedID }) { self.selectedID = visible.first?.id }
  }
  func selectFolder(_ id: UUID?) {
    selectedFolderID = id
    selectedID = visible.first?.id
  }

  func create(title: String = "Untitled Script", markdown: String = "", linkTo: URL? = nil) {
    withLibrary { [self] _ in _ = try await createScript(title: title, markdown: markdown, linkTo: linkTo) }
  }
  @discardableResult func createScript(title: String, markdown: String, linkTo: URL? = nil) async throws -> ScriptRecord {
    await waitForInitialLoad()
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    let item: ScriptRecord
    if let linkTo { item = try await library.createLinked(title: title, markdown: markdown, folderID: selectedFolderID, to: linkTo) }
    else { item = try await library.create(title: title, markdown: markdown, folderID: selectedFolderID) }
    scripts.insert(item, at: 0)
    selectedID = item.id
    await refreshLinkStates()
    return item
  }
  static func importTarget(for preview: ImportPreview) -> (title: String, linkTo: URL?) {
    (preview.sourceURL.deletingPathExtension().lastPathComponent,
     ["md", "markdown"].contains(preview.sourceURL.pathExtension.lowercased()) ? preview.sourceURL : nil)
  }
  /// Paste Copied Text, in the File and Add menus.
  func importClipboard() {
    guard let markdown = NSPasteboard.general.string(forType: .string),
      !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMessage = "Copy some text first, then choose Paste Copied Text."
      return
    }
    create(title: Self.pastedTitle(markdown), markdown: markdown)
  }
  static func pastedTitle(_ markdown: String) -> String {
    let lines = markdown.components(separatedBy: .newlines)
    if let heading = lines.first(where: { $0.range(of: #"^\s{0,3}#{1,6}\s+\S"#, options: .regularExpression) != nil }) {
      return String(heading.replacingOccurrences(of: #"^\s*#+\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(60))
    }
    let words = (lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "").split(whereSeparator: { $0.isWhitespace }).prefix(6).joined(separator: " ")
    return words.isEmpty ? "Pasted Script" : String(words.prefix(60))
  }
  struct PendingEditsError: Error, CustomStringConvertible {
    let description: String
  }
  func duplicate() {
    guard let selected else { return }
    withLibrary { [self] _ in _ = try await duplicateScript(selected.id) }
  }
  @discardableResult func duplicateScript(_ id: UUID) async throws -> ScriptRecord {
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    guard await flushPendingSaves() else {
      throw PendingEditsError(description: "Save the pending edits before duplicating scripts.")
    }
    let item = try await library.duplicate(id)
    scripts.insert(item, at: 0)
    selectedID = item.id
    return item
  }
  private final class ScriptDeletion {
    var completed = Set<UUID>()
  }
  private var scriptDeletionTask: Task<Void, Never>?
  func delete(_ ids: Set<UUID>, undoManager: UndoManager? = nil) {
    let links = Dictionary(uniqueKeysWithValues: ids.compactMap { id in MacGoogleDocs.links[id].map { (id, $0) } })
    changeScriptDeletion(ids, links: links, deleting: true, undoManager: undoManager)
  }
  private func changeScriptDeletion(_ ids: Set<UUID>, links: [UUID: GoogleDocLinks.Link], deleting: Bool,
                                    undoManager: UndoManager?, inverting: ScriptDeletion? = nil) {
    guard !ids.isEmpty else { return }
    let change = ScriptDeletion()
    undoManager?.registerUndo(withTarget: change) { [weak self, weak undoManager] _ in
      self?.changeScriptDeletion(ids, links: links, deleting: !deleting, undoManager: undoManager, inverting: change)
    }
    undoManager?.setActionName("Move to Trash")
    let previous = scriptDeletionTask
    scriptDeletionTask = Task { [self, weak undoManager] in
      await previous?.value
      let targets = inverting?.completed ?? ids
      do {
        for id in targets {
          if deleting { try await deleteScript(id) }
          else { try await restoreScript(id); MacGoogleDocs.links[id] = links[id] }
          change.completed.insert(id)
        }
      } catch {
        errorMessage = "The library change could not be saved. \(error.localizedDescription)"
      }
      if change.completed.isEmpty { undoManager?.removeAllActions(withTarget: change) }
      if deleting, !change.completed.isEmpty {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
          userInfo: [.announcement: "Moved \(change.completed.count) scripts to Recently Deleted", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
      }
    }
  }
  func deleteScript(_ id: UUID, afterSaving: () throws -> Void = {}) async throws {
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    guard await flushPendingSaves() else {
      throw PendingEditsError(description: "Save the pending edits before moving scripts to Trash.")
    }
    try afterSaving()
    deletingIDs.insert(id)
    defer { deletingIDs.remove(id) }
    await deleteGate?()
    try await library.delete(id)
    session.forgetScript(id)
    MacGoogleDocs.links[id] = nil
    scripts.removeAll { $0.metadata.id == id }
    trash = await library.listTrash()
    if selectedID == id { selectedID = visible.first?.id }
  }
  func restore(_ id: UUID) {
    withLibrary { [self] _ in try await restoreScript(id) }
  }
  func restoreScript(_ id: UUID) async throws {
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    _ = try await library.restore(id)
    await reload()
  }
  func exportMarkdown(_ script: ScriptRecord) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(script.metadata.title).md"
    panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try script.markdown.write(to: url, atomically: true, encoding: .utf8) }
    catch { errorMessage = "Could not export the script. \(error.localizedDescription)" }
  }
  /// The linked file when there is one, otherwise the library's own copy.
  func revealInFinder(_ id: UUID) {
    withLibrary { [self] library in
      let url: URL
      if let linked = linkStates[id]?.url { url = linked }
      else { url = try await library.scriptURL(for: id) }
      NSWorkspace.shared.activateFileViewerSelecting([url])
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
    pendingDrafts[id] = value
    guard !presenterSaveIDs.contains(id) else { return }
    scheduleMarkdownSave(value, for: id)
  }
  /// Saves of one script run strictly one after another. A save already inside the library cannot
  /// be cancelled, so a newer one cancels only the debounce, waits for it, and reads the
  /// fingerprint it left behind when it actually runs, not the one seen when it was typed.
  private func scheduleMarkdownSave(_ value: String, for id: UUID) {
    let previous = saveTasks[id]
    previous?.cancel()
    let taskToken = UUID()
    saveTaskTokens[id] = taskToken
    saveTasks[id] = Task { [weak self] in
      defer {
        if self?.saveTaskTokens[id] == taskToken {
          self?.saveTasks[id] = nil
          self?.saveTaskTokens[id] = nil
          Task { await self?.refreshDeferredExternalRead(id) }
        }
      }
      await previous?.value
      do {
        try await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, let self, let library = self.library,
          let expected = self.scripts.first(where: { $0.metadata.id == id })?.metadata.contentFingerprint
        else { return }
        await self.saveGate?()
        self.applySaved(try await library.save(id, markdown: value, expectedFingerprint: expected), for: id, submitted: value)
      } catch is CancellationError {} catch {
        self?.failedSaveIDs.insert(id)
        self?.hasFailedSaves = true
        self?.errorMessage = "The edit was preserved but could not replace the file. \(error)"
      }
    }
  }
  /// A save that reached disk always brings its revision metadata, even if the user has typed
  /// since. Drop only the submitted draft; a linked-file conflict may have replaced its text.
  private func applySaved(_ saved: ScriptRecord, for id: UUID, submitted: String) {
    guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
    scripts[index].metadata = saved.metadata
    guard pendingDrafts[id] == submitted else { return }
    scripts[index] = saved
    pendingDrafts[id] = nil
    failedSaveIDs.remove(id)
    hasFailedSaves = !failedSaveIDs.isEmpty
    session.applyEditedRecord(scripts[index])
  }
  func savePresentedMarkdown(
    _ value: String, for id: UUID, expectedFingerprint: String, expectedRevision: UInt64
  ) async throws {
    while let task = saveTasks[id] { await task.value }
    guard !failedSaveIDs.contains(id) else { throw CocoaError(.fileWriteUnknown) }
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    guard let baseline = scripts.first(where: { $0.id == id }),
      baseline.metadata.contentFingerprint == expectedFingerprint,
      baseline.metadata.revision == expectedRevision,
      pendingDrafts[id] == nil
    else { throw PresenterSaveError.changedBeforeSave }
    guard !presenterSaveIDs.contains(id) else { throw PresenterSaveError.changedDuringSave }
    presenterSaveIDs.insert(id)
    presenterSaveReservationHook?()
    if let gate = presenterSaveReservationGate { await gate() }
    do {
      let saved = try await library.save(id, markdown: value, expectedFingerprint: expectedFingerprint)
      guard let index = scripts.firstIndex(where: { $0.id == id }) else {
        throw PresenterSaveError.changedDuringSave
      }
      if let queued = pendingDrafts[id], scripts[index].markdown == queued {
        var latest = saved
        latest.markdown = queued
        scripts[index] = latest
        session.applyEditedRecord(latest)
        scheduleMarkdownSave(queued, for: id)
      } else if scripts[index] == baseline {
        scripts[index] = saved
        session.applyEditedRecord(saved)
      } else {
        scripts[index].metadata = saved.metadata
        throw PresenterSaveError.changedDuringSave
      }
    } catch {
      if let queued = pendingDrafts[id] { scheduleMarkdownSave(queued, for: id) }
      finishPresenterSave(id)
      throw error
    }
    finishPresenterSave(id)
  }
  func savePresentedDraftAsCopy(_ value: String, for id: UUID) async throws {
    guard let library, let source = scripts.first(where: { $0.id == id }) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let copy = try await library.create(
      title: "\(source.metadata.title) (Presenter Draft)", markdown: value,
      folderID: source.metadata.folderID, tags: source.metadata.tags)
    scripts.insert(copy, at: 0)
    selectedID = copy.id
  }
  func flushSettings() async {
    await settingsPersistence.flush()
  }
  func flushPendingSaves() async -> Bool {
    while true {
      let folderRevision = folderChangeRevision
      await folderChangeTask?.value
      for task in Array(saveTasks.values) { await task.value }
      if let id = presenterSaveIDs.first {
        await withCheckedContinuation { presenterSaveWaiters[id, default: []].append($0) }
        continue
      }
      await settingsPersistence.flush()
      if folderRevision != folderChangeRevision { continue }
      return failedSaveIDs.isEmpty && saveTasks.isEmpty && pendingDrafts.isEmpty
    }
  }
  private func finishPresenterSave(_ id: UUID) {
    presenterSaveIDs.remove(id)
    Task { await refreshDeferredExternalRead(id) }
    let waiters = presenterSaveWaiters.removeValue(forKey: id) ?? []
    for waiter in waiters { waiter.resume() }
  }
  func retryFailedSaves() async {
    guard let library else { return }
    for id in Array(failedSaveIDs) {
      guard !presenterSaveIDs.contains(id) else { continue }
      guard let draft = pendingDrafts[id], let current = scripts.first(where: { $0.id == id }) else { continue }
      do {
        applySaved(
          try await library.save(id, markdown: draft, expectedFingerprint: current.metadata.contentFingerprint),
          for: id, submitted: draft)
      } catch { hasFailedSaves = true; errorMessage = "The edit was preserved but could not replace the file. \(error)" }
    }
  }
  func keepBothFailedSaves() async {
    guard let library else { return }
    for id in Array(failedSaveIDs) {
      guard !presenterSaveIDs.contains(id) else { continue }
      guard let draft = pendingDrafts[id], let current = scripts.first(where: { $0.id == id }) else { continue }
      do {
        let local = try await library.create(
          title: "\(current.metadata.title) (Local Draft)", markdown: draft,
          folderID: current.metadata.folderID, tags: current.metadata.tags)
        scripts.insert(local, at: 0)
        guard pendingDrafts[id] == draft,
          scripts.first(where: { $0.id == id })?.markdown == draft
        else { continue }
        let external: ScriptRecord
        if let changed = try await library.externalChange(for: id) {
          external = changed
        } else {
          external = try await library.read(id)
        }
        guard pendingDrafts[id] == draft,
          scripts.first(where: { $0.id == id })?.markdown == draft
        else { continue }
        if let index = scripts.firstIndex(where: { $0.id == id }) {
          scripts[index] = external
          session.applyEditedRecord(external)
        }
        selectedID = local.id
        failedSaveIDs.remove(id)
        pendingDrafts[id] = nil
      } catch {
        errorMessage = "The local draft could not be preserved as a separate script. \(error)"
      }
    }
    hasFailedSaves = !failedSaveIDs.isEmpty
  }
  /// Stop mirroring the external file. The script keeps the content it already has.
  func unlink(_ id: UUID) {
    withLibrary { [self] library in
      let metadata = try await library.unlink(id)
      if let i = scripts.firstIndex(where: { $0.id == id }) { scripts[i].metadata = metadata }
      await refreshLinkStates()
    }
  }
  func refreshLinkStates() async {
    guard let library else { return }
    let states = await library.linkStates()
    if states != linkStates { linkStates = states }
  }
  /// Point a script whose file moved at its new place; `resolution` says which text survives.
  func relink(_ id: UUID, to url: URL, resolution: RelinkResolution) async -> Bool {
    guard let library else { return false }
    guard await flushPendingSaves() else {
      errorMessage = "Save the pending edits before relinking."
      return false
    }
    do {
      let outcome = try await library.relink(id: id, to: url, resolution: resolution)
      if let i = scripts.firstIndex(where: { $0.id == id }) {
        scripts[i] = outcome.current
        if resolution == .useFile { session.applyEditedRecord(outcome.current) }
      }
      if let imported = outcome.imported { scripts.insert(imported, at: 0) }
      unavailableScriptIDs.remove(id)
      await refreshLinkStates()
      return true
    } catch {
      errorMessage = "The file could not be relinked. Nothing was changed. \(error)"
      return false
    }
  }
  func rename(_ value: String, for id: UUID) {
    withLibrary { [self] _ in try await updateScriptMetadata(id, title: value) }
  }
  func setTags(_ tags: [String], for id: UUID) {
    withLibrary { [self] _ in try await updateScriptMetadata(id, tags: tags) }
  }
  func updateScriptMetadata(_ id: UUID, title: String? = nil, tags: [String]? = nil) async throws {
    guard let library else { throw CocoaError(.fileNoSuchFile) }
    let metadata = try await library.updateMetadata(id, title: title, tags: tags)
    if let i = scripts.firstIndex(where: { $0.metadata.id == id }) { scripts[i].metadata = metadata }
  }

  func savePreset(named name: String) {
    var preset = settings
    preset.id = UUID()
    preset.name =
      name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Reading preset \(presets.count + 1)" : name.trimmingCharacters(in: .whitespacesAndNewlines)
    presets.append(preset)
  }
  func renamePreset(_ id: UUID, name: String) {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { errorMessage = "Enter a name for these saved settings."; return }
    presets[index].name = clean
  }
  func duplicatePreset(_ id: UUID) {
    guard let source = presets.first(where: { $0.id == id }) else { return }
    var copy = source
    copy.id = UUID()
    copy.name = "\(source.name) copy"
    presets.append(copy)
  }
  func updatePreset(_ id: UUID) {
    guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
    var updated = settings
    updated.id = id
    updated.name = presets[index].name
    presets[index] = updated
  }
  func dismissModeMigrationNotice() {
    modeMigrationNotice = nil
    defaults.set(1, forKey: Self.modeMigrationKey)
    defaults.removeObject(forKey: Self.modeMigrationPendingKey)
  }
  func matchesPreset(_ preset: PrompterSettings) -> Bool {
    var compared = preset
    compared.id = settings.id; compared.name = settings.name
    compared.audioDeviceUID = settings.audioDeviceUID
    compared.speechLanguage = settings.speechLanguage
    return compared == settings
  }
  func applyPreset(_ preset: PrompterSettings, undoManager: UndoManager? = nil) {
    let previous = settings
    undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in target.applyPreset(previous, undoManager: undoManager) }
    undoManager?.setActionName("Apply Reading Preset")
    var applied = preset
    applied.mode = PrompterSettings.normalisedMode(applied.mode)
    applied.name = settings.name
    applied.audioDeviceUID = settings.audioDeviceUID
    applied.speechLanguage = settings.speechLanguage
    settings = applied
  }
  func deletePreset(_ id: UUID, undoManager: UndoManager? = nil) {
    guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
    let preset = presets.remove(at: index)
    undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in
      target.restorePreset(preset, at: index, undoManager: undoManager)
    }
    undoManager?.setActionName("Delete Preset")
  }
  private func restorePreset(_ preset: PrompterSettings, at index: Int, undoManager: UndoManager?) {
    guard !presets.contains(where: { $0.id == preset.id }) else { return }
    presets.insert(preset, at: min(index, presets.count))
    undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in target.deletePreset(preset.id, undoManager: undoManager) }
    undoManager?.setActionName("Delete Preset")
  }
  private func persistSettings() {
    settingsPersistence.schedule(SettingsSnapshot(
      settings: settings, presets: presets,
      typography: EditorTypographyPreferences(
        sourceFontName: sourceFontName, sourceFontSize: sourceFontSize,
        previewFontName: previewFontName, previewFontSize: previewFontSize),
      uiZoom: uiZoom, simpleInterface: simpleInterface))
  }

  private static func isMissingFile(_ error: Error) -> Bool {
    let nsError = error as NSError
    return (nsError.domain == NSCocoaErrorDomain && (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue))
      || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
  }
  func refreshLinkedSyncStatus() async {
    guard let library else { return }
    let waiting = await library.linkedSyncWaiting()
    linkedSyncStatus = waiting.isEmpty ? nil : waiting.joined(separator: "\n")
  }
  private func refreshDeferredExternalRead(_ id: UUID) async {
    guard deferredExternalReads.contains(id), let library, saveTasks[id] == nil,
      pendingDrafts[id] == nil, !failedSaveIDs.contains(id), !presenterSaveIDs.contains(id),
      let record = try? await library.read(id) else { return }
    guard saveTasks[id] == nil, pendingDrafts[id] == nil, !failedSaveIDs.contains(id),
      !presenterSaveIDs.contains(id) else { return }
    deferredExternalReads.remove(id)
    if let i = scripts.firstIndex(where: { $0.id == id }) { scripts[i] = record }
    session.applyEditedRecord(record)
  }
  func refreshExternalChanges() async {
    guard let library else { return }
    lastExternalRefresh = Date()
    do {
      if !(try await library.discoverExternalScripts()).isEmpty { await reload() }
    } catch { errorMessage = "New script files could not be added. \(error)" }
    for metadata in await library.listScripts()
    where (saveTasks[metadata.id] == nil || saveTasks[metadata.id]?.isCancelled == true)
      && !failedSaveIDs.contains(metadata.id) && !presenterSaveIDs.contains(metadata.id) {
      do {
        // An external edit, or a file that has come back.
        var found = try await library.externalChange(for: metadata.id)
        if found == nil, unavailableScriptIDs.contains(metadata.id) { found = try await library.read(metadata.id) }
        guard let record = found else { continue }
        guard !failedSaveIDs.contains(metadata.id), saveTasks[metadata.id] == nil,
          !presenterSaveIDs.contains(metadata.id) else {
          deferredExternalReads.insert(metadata.id)
          continue
        }
        if let i = scripts.firstIndex(where: { $0.id == metadata.id }) {
          scripts[i] = record
        } else {
          scripts.insert(record, at: 0)
        }
        session.applyEditedRecord(record)
        unavailableScriptIDs.remove(metadata.id)
      } catch {
        let missing = Self.isMissingFile(error)
        if missing, unavailableScriptIDs.insert(metadata.id).inserted {
          if session.activeScriptID == metadata.id { session.pause() }
          errorMessage = "The script file is unavailable. Restore the original file, or export and import a copy."
        } else if !missing {
          errorMessage = "The library change could not be saved. Check free space and access to the script folder, then try again. Details: \(error.localizedDescription)"
        }
      }
    }
    await refreshLinkStates()
    await refreshLinkedSyncStatus()
    let conflicts = await library.takeLinkConflicts()
    if !conflicts.isEmpty {
      let notice =
        "The linked file and your in-app edit both changed. The file on disk was used; your version is kept as \(conflicts.joined(separator: ", ")) in the library's Conflicts folder."
      errorMessage = errorMessage.map { "\($0)\n\n\(notice)" } ?? notice
    }
  }
}

