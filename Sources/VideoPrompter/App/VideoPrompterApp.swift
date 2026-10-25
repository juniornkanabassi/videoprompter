import AppKit
import PrompterCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
  static let videoPrompterImport = Notification.Name("VideoPrompter.import")
}

/// Shared by the Add and File menus, so Import cannot steal the editor’s Italic shortcut.
enum ScriptShortcuts {
  static let importFile = KeyboardShortcut("i", modifiers: [.command, .shift])
  static let italic = KeyboardShortcut("i", modifiers: .command)
}

private struct EditorTypographyPreferences: Codable {
  var sourceFontName = "Lexend Deca"
  var sourceFontSize = 17.0
  var previewFontName = "Lexend Deca"
  var previewFontSize = 18.0
}

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
  @Published var settings = PrompterSettings() { didSet { persistSettings() } }
  @Published var presets: [PrompterSettings] = [] { didSet { persistSettings() } }
  @Published var sourceFontName = "Lexend Deca" { didSet { persistSettings() } }
  @Published var sourceFontSize = 17.0 { didSet { persistSettings() } }
  @Published var previewFontName = "Lexend Deca" { didSet { persistSettings() } }
  @Published var previewFontSize = 18.0 { didSet { persistSettings() } }
  /// View > Zoom In, Zoom Out and Actual Size: the whole library window and the presenter's controls.
  @Published var uiZoom = 1.0 { didSet { persistSettings() } }
  /// Nothing below 100%: zoomed out, a pane's AppKit views are laid out wider than their column,
  /// and AppKit then refuses clicks on the part that would overlap the next column.
  static let uiZoomSteps = [1, 1.1, 1.25, 1.5, 1.75, 2]
  static let presenterFontSizes = 18.0...120.0
  static let editorFontSizes = 12.0...40.0
  @Published var errorMessage: String?
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
  // nonisolated so `deinit` can take the observer back out again.
  nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
  /// Activation can arrive in a burst; a full refresh reads every script, so it is not worth
  /// repeating on top of the two-second poll.
  private var lastExternalRefresh = Date.distantPast
  private let defaults: UserDefaults

  static func preferences(arguments: [String] = CommandLine.arguments) -> UserDefaults {
    guard let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count else { return .standard }
    let root = ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: arguments)
    // Keep the legacy suite prefix so the public rename preserves isolated settings.
    return UserDefaults(suiteName: "VidPrompt.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))")!
  }
  init(arguments: [String] = CommandLine.arguments, defaults: UserDefaults? = nil) {
    _ = AvailableFonts.presenter
    let root = ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: arguments)
    let isolatedDefaults = defaults ?? Self.preferences(arguments: arguments)
    self.defaults = isolatedDefaults
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
        modeMigrationNotice = "Following now has two modes. Timed and Manual are one Manual mode: choose a words-per-minute speed and press Start to scroll continuously. Sound mode is gone; saved settings that used it now use Voice."
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
    if savedZoom > 0 { uiZoom = min(max(savedZoom, Self.uiZoomSteps.first!), Self.uiZoomSteps.last!) }
    if let savedPresets { presets = savedPresets }
    if let savedTypography {
      sourceFontName = savedTypography.sourceFontName
      sourceFontSize = min(max(savedTypography.sourceFontSize, Self.editorFontSizes.lowerBound), Self.editorFontSizes.upperBound)
      previewFontName = savedTypography.previewFontName
      previewFontSize = min(max(savedTypography.previewFontSize, Self.editorFontSizes.lowerBound), Self.editorFontSizes.upperBound)
    }
    if let savedSettings { settings = savedSettings }
    simpleInterface = savedSimple
    do {
      library = try MarkdownLibrary(rootURL: root)
      libraryAvailable = true
    } catch { errorMessage = "The script library could not be opened safely. \(error)" }
    initialLoad = Task { await reload() }
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
          errorMessage = "The script could not be loaded. \(error)"
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
  /// Runs a library change on the main actor; a failure shows in the error alert.
  private func withLibrary(_ work: @escaping @MainActor (MarkdownLibrary) async throws -> Void) {
    guard let library else { return }
    Task { do { try await work(library) } catch { errorMessage = String(describing: error) } }
  }
  func createFolder(named name: String) {
    withLibrary { [self] library in folders.append(try await library.createFolder(name: name)) }
  }
  func renameFolder(_ id: UUID, name: String) {
    withLibrary { [self] library in
      try await library.renameFolder(id, name: name)
      if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].name = name }
    }
  }
  func deleteFolder(_ id: UUID) {
    withLibrary { [self] library in
      try await library.deleteFolder(id)
      folders.removeAll { $0.id == id }
      scripts = scripts.map { var s = $0; if s.metadata.folderID == id { s.metadata.folderID = nil }; return s }
      if selectedFolderID == id { selectedFolderID = nil }
    }
  }
  /// Menu/shortcut deletion yields to native typing in the script, title and tags.
  func trashSelectionFromMenu(in window: NSWindow? = NSApp.keyWindow) {
    guard Self.canTrashSelection(in: window) else { return }
    delete(selectedIDs)
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
    withLibrary { [self] library in
      try await library.moveScripts(ids, to: folderID)
      for i in scripts.indices where ids.contains(scripts[i].id) { scripts[i].metadata.folderID = folderID }
      if let selectedID, !visible.contains(where: { $0.id == selectedID }) { self.selectedID = visible.first?.id }
    }
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
  /// Paste as New Script, in the File and Add menus.
  func importClipboard() {
    guard let markdown = NSPasteboard.general.string(forType: .string), !markdown.isEmpty else { return }
    create(title: "Pasted Script", markdown: markdown)
  }
  func duplicate() {
    guard let selected else { return }
    withLibrary { [self] library in
      guard await flushPendingSaves() else {
        errorMessage = "Save the pending edits before duplicating scripts."
        return
      }
      let item = try await library.duplicate(selected.metadata.id)
      scripts.insert(item, at: 0)
      selectedID = item.metadata.id
    }
  }
  func delete(_ ids: Set<UUID>) {
    for id in ids {
      withLibrary { [self] library in
        guard await flushPendingSaves() else {
          errorMessage = "Save the pending edits before moving scripts to Trash."
          return
        }
        try await library.delete(id)
        session.forgetScript(id)
        MacGoogleDocs.links[id] = nil
        scripts.removeAll { $0.metadata.id == id }
        trash = await library.listTrash()
        if selectedID == id { selectedID = visible.first?.id }
      }
    }
  }
  func restore(_ id: UUID) {
    withLibrary { [self] library in
      _ = try await library.restore(id)
      await reload()
    }
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
        }
      }
      await previous?.value
      do {
        try await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, let self, let library = self.library,
          let expected = self.scripts.first(where: { $0.metadata.id == id })?.metadata.contentFingerprint
        else { return }
        await self.saveGate?()
        self.applySaved(try await library.save(id, markdown: value, expectedFingerprint: expected), for: id)
      } catch is CancellationError {} catch {
        self?.failedSaveIDs.insert(id)
        self?.hasFailedSaves = true
        self?.errorMessage = "The edit was preserved but could not replace the file. \(error)"
      }
    }
  }
  /// A save that reached disk always brings its revision metadata, even if the user has typed
  /// since. The pending draft is dropped only when it is exactly what was just saved.
  private func applySaved(_ saved: ScriptRecord, for id: UUID) {
    guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
    scripts[index].metadata = saved.metadata
    guard pendingDrafts[id] == saved.markdown else { return }
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
  func flushPendingSaves() async -> Bool {
    while true {
      for task in Array(saveTasks.values) { await task.value }
      if let id = presenterSaveIDs.first {
        await withCheckedContinuation { presenterSaveWaiters[id, default: []].append($0) }
        continue
      }
      return failedSaveIDs.isEmpty && saveTasks.isEmpty && pendingDrafts.isEmpty
    }
  }
  private func finishPresenterSave(_ id: UUID) {
    presenterSaveIDs.remove(id)
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
          for: id)
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
  func rename(_ value: String, for id: UUID) { updateMetadata(id) { try await $0.updateMetadata(id, title: value) } }
  func setTags(_ tags: [String], for id: UUID) { updateMetadata(id) { try await $0.updateMetadata(id, tags: tags) } }
  private func updateMetadata(
    _ id: UUID, _ change: @escaping @MainActor (MarkdownLibrary) async throws -> ScriptMetadata
  ) {
    withLibrary { [self] library in
      let metadata = try await change(library)
      if let i = scripts.firstIndex(where: { $0.metadata.id == id }) { scripts[i].metadata = metadata }
    }
  }

  func savePreset(named name: String) {
    var preset = settings
    preset.id = UUID()
    preset.name =
      name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Preset \(presets.count + 1)" : name
    presets.append(preset)
  }
  func renamePreset(_ id: UUID, name: String) {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { errorMessage = "Preset names cannot be empty."; return }
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
  func applyPreset(_ preset: PrompterSettings) {
    var applied = preset
    applied.mode = PrompterSettings.normalisedMode(applied.mode)
    applied.name = settings.name
    applied.audioDeviceUID = settings.audioDeviceUID
    applied.speechLanguage = settings.speechLanguage
    settings = applied
  }
  func deletePreset(_ id: UUID) { presets.removeAll { $0.id == id } }
  private func persistSettings() {
    if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
    if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "presets") }
    let typography = EditorTypographyPreferences(
      sourceFontName: sourceFontName, sourceFontSize: sourceFontSize,
      previewFontName: previewFontName, previewFontSize: previewFontSize)
    if let data = try? JSONEncoder().encode(typography) { defaults.set(data, forKey: "editorTypography") }
    defaults.set(uiZoom, forKey: "uiZoom")
    defaults.set(simpleInterface, forKey: "simpleInterface")
  }
  private static func isMissingFile(_ error: Error) -> Bool {
    let nsError = error as NSError
    return (nsError.domain == NSCocoaErrorDomain && (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue))
      || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
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
        guard let record = found, !failedSaveIDs.contains(metadata.id), saveTasks[metadata.id] == nil,
          !presenterSaveIDs.contains(metadata.id) else { continue }
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
          errorMessage = String(describing: error)
        }
      }
    }
    await refreshLinkStates()
    let conflicts = await library.takeLinkConflicts()
    if !conflicts.isEmpty {
      let notice =
        "The linked file and your in-app edit both changed. The file on disk was used; your version is kept as \(conflicts.joined(separator: ", ")) in the library's Conflicts folder."
      errorMessage = errorMessage.map { "\($0)\n\n\(notice)" } ?? notice
    }
  }
}

@main struct VideoPrompterApp: App {
  @StateObject private var store = AppStore()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  var body: some Scene {
    WindowGroup("Video Prompter", id: "library") {
      LibraryView(store: store)
        .background(MainWindowConfigurator())
        .onAppear { appDelegate.store = store }
    }
      .defaultSize(width: 1100, height: 750)
      .windowResizability(.contentMinSize)
      .commands {
        CommandGroup(after: .textEditing) {
          Button("Find…") {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            let responder = NSApp.keyWindow?.firstResponder
            if let textView = responder as? NSTextView { textView.usesFindBar = true }
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: responder, from: item)
          }.keyboardShortcut("f", modifiers: .command)
        }
        // Grouped to stay within the commands builder's ten items.
        Group {
          SidebarCommands()
          InspectorCommands()
          PrivacyCommands()
        }
        ICloudCommands(store: store)
        IPadCameraCommands(sender: .shared)
        CommandGroup(after: .newItem) { FileItems(store: store) }
        CommandGroup(before: .toolbar) {
          Button("Zoom In") { store.stepUIZoom(in: true) }.keyboardShortcut("+", modifiers: .command)
            .disabled(store.uiZoom >= AppStore.uiZoomSteps.last!)
          Button("Zoom Out") { store.stepUIZoom(in: false) }.keyboardShortcut("-", modifiers: .command)
            .disabled(store.uiZoom <= AppStore.uiZoomSteps.first!)
          Button("Actual Size") { store.uiZoom = 1 }.keyboardShortcut("0", modifiers: .command)
            .disabled(store.uiZoom == 1)
          Divider()
          // Notes' text zoom keys. ">" is what Shift-period types, so AppKit matches it as Command-Shift-period.
          Button("Make Text Bigger") { store.zoomFocusedText(in: true) }.keyboardShortcut(">", modifiers: .command)
          Button("Make Text Smaller") { store.zoomFocusedText(in: false) }.keyboardShortcut("<", modifiers: .command)
          Divider()
        }
        CommandMenu("Format") {
          Button("Bold") { FormattedMarkdownEditor.formatFocused(.bold) }.keyboardShortcut("b")
          Button("Italic") { FormattedMarkdownEditor.formatFocused(.italic) }.keyboardShortcut(ScriptShortcuts.italic)
          Button("Heading") { FormattedMarkdownEditor.formatFocused(.heading) }
          Button("Add or Edit Link…") { FormattedMarkdownEditor.formatFocused(.link) }.keyboardShortcut("k")
        }
        CommandMenu("Prompter") {
          Button("Present Script") { PresenterController.shared.present(store: store) }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .help(store.selected == nil ? "Select a script to present" : "Present the selected script")
            .disabled(store.selected == nil)
          // Option-Command-Space is macOS's own Show Finder Search Window (and Shift-Command-Space
          // asks Siri), so the app never received it. Option-Command-S is VoicePrompter's.
          Button("Start or Pause") { store.session.toggle() }
            .keyboardShortcut("s", modifiers: [.command, .option])
          Button("Back to Start") { PresenterController.shared.moveReading { $0.restart() } }
            .keyboardShortcut("r", modifiers: [.command, .option])
          Button("Previous Passage") { PresenterController.shared.moveReading { $0.previousPassage() } }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
          Button("Next Passage") { PresenterController.shared.moveReading { $0.nextPassage() } }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
          Divider()
          PresenterVideoItems()
          Button("Presenter Full Screen") { PresenterController.shared.toggleFullScreen() }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CameraCommands()
      }
    Window("Import from Google Docs", id: "google-docs") { GoogleDocsWindow(store: store) }
      .defaultSize(width: 520, height: 560)
    Window("Camera", id: "camera") { CameraView().background(MainWindowConfigurator(size: NSSize(width: 760, height: 480))) }
      .defaultSize(width: 760, height: 480)
  }
}

/// The video background's two menu items. A view of its own so the toggle follows
/// `CameraModel.shared` without the whole app scene observing it.
struct PresenterVideoItems: View {
  @ObservedObject private var camera: CameraModel
  init(camera: CameraModel = .shared) { _camera = ObservedObject(wrappedValue: camera) }
  /// Prompter > Prompter Only / Present with Video / Video Only. Internal so the test flips the
  /// menu's own switches. Ticking the chosen one again goes back to Prompter only.
  func choice(_ mode: PresenterDisplayMode) -> Binding<Bool> {
    Binding(
      get: { camera.displayMode == mode },
      set: { camera.displayMode = $0 ? mode : .prompterOnly })
  }
  var body: some View {
    Toggle("Script Only", isOn: choice(.prompterOnly))
    Toggle("Script and Camera", isOn: choice(.prompterWithVideo))
      .keyboardShortcut("v", modifiers: [.command, .shift])
    Toggle("Camera Only", isOn: choice(.videoOnly))
    Button("Match Camera Size") { PresenterController.shared.matchCameraSize() }
      .disabled(!camera.presentsWithVideo)
  }
}

/// File menu: the library's script and folder actions. Each item is disabled when nothing applies.
private struct FileItems: View {
  @ObservedObject var store: AppStore
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    let script = store.selected
    let link = script.flatMap { store.linkStates[$0.id] }
    Button("New Script") { store.create() }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(!store.libraryAvailable)
    Button("New Folder…") { store.namingNewFolder = true }
      .disabled(!store.libraryAvailable)
    Button("Duplicate") { store.duplicate() }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(script == nil)
    Divider()
    // Keep the native Italic shortcut available in both script editors.
    Button("Import File…") { NotificationCenter.default.post(name: .videoPrompterImport, object: nil) }
      .keyboardShortcut(ScriptShortcuts.importFile)
      .disabled(!store.libraryAvailable)
    Button("Paste as New Script") { store.importClipboard() }
      .disabled(!store.libraryAvailable)
    Button("Import from Google Docs…") { openWindow(id: "google-docs") }
      .disabled(!store.libraryAvailable)
    Button("Update from Google Docs") { store.updateSelectedFromGoogle() }
      .disabled(script.map { !store.isFromGoogle($0.id) } ?? true)
    Button("Export Markdown…") { script.map(store.exportMarkdown) }
      .disabled(script == nil)
    Button("Reveal in Finder") { script.map { store.revealInFinder($0.id) } }
      .disabled(script == nil || link?.isBroken == true)
    Divider()
    Button(link?.isBroken == true ? "Find Linked File…" : "Link File…") { store.relinkingID = script?.id }
      .disabled(script == nil || (script?.metadata.linkedPath != nil && link?.isBroken != true))
    Button("Unlink") { script.map { store.unlink($0.id) } }
      .disabled(script?.metadata.linkedPath == nil)
    Divider()
    Button("Move to Trash") { store.trashSelectionFromMenu() }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(store.selectedIDs.isEmpty)
  }
}

/// The `Window` scene already lists itself under Window; this adds the shortcut.
private struct CameraCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button("Camera") { openWindow(id: "camera") }.keyboardShortcut("c", modifiers: [.command, .shift])
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controlServer: ControlServer?
  weak var store: AppStore? {
    didSet {
      guard controlServer == nil, let store else { return }
      let actions = ControlActions(store: store)
      let root = ControlProtocol.dataRoot(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments)
      let server = ControlServer(socketURL: ControlProtocol.socketURL(dataRoot: root)) { action, params in await actions.handle(action, params) }
      controlServer = server
      do { try server.start() } catch { NSLog("Control server unavailable: %@", error.localizedDescription) }
    }
  }
  func applicationWillTerminate(_ notification: Notification) { controlServer?.stop() }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if Self.deletesLineWhileTyping(event, in: NSApp.keyWindow) { return nil }
      if let presenter = NSApp.keyWindow as? PresenterPanel, presenter.handlePassageKey(event) { return nil }
      // Zoom In's "+" only matches with Shift held; take the unshifted Command-= too, as Safari does.
      guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "=", let store = self?.store
      else { return event }
      store.stepUIZoom(in: true)
      return nil
    }
  }
  /// Command-Delete is File > Move to Trash, but in a text field or editor it keeps its text meaning,
  /// delete to the start of the line, so typing can never bin a script. Runs before the menu sees it.
  static func deletesLineWhileTyping(_ event: NSEvent, in window: NSWindow?) -> Bool {
    guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers == "\u{7F}",
      let text = window?.firstResponder as? NSTextView, text.isEditable
    else { return false }
    text.deleteToBeginningOfLine(nil)
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store else { return .terminateNow }
    store.session.pause()
    Task {
      await CameraRecorder.shared.stop()
      let saved = await store.flushPendingSaves()
      if !saved && store.errorMessage == nil { store.errorMessage = "A script edit could not be saved. Retry the save before quitting." }
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}

/// Zoom for a whole pane: lays the content out in 1/scale of the space it is given and draws it
/// scaled back up, so every label, control and text view grows together. SwiftUI's own scale keeps
/// clicks on target, AppKit views inside included; an NSHostingView inside a bounds-scaled NSView
/// draws the same but stops hit-testing its AppKit subviews.
struct UIZoom: Layout {
  var scale: Double
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = subviews.first?.sizeThatFits(ProposedViewSize(
      width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })) ?? .zero
    guard scale != 1 else { return size }
    // Zoomed, a pane takes the space it is offered: passing its content's minimum on, doubled at
    // 200%, asked the split view for more than the window had and AppKit looped on constraints.
    return CGSize(width: proposal.width ?? size.width * scale, height: proposal.height ?? size.height * scale)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale))
  }
}
extension View {
  func uiZoom(_ scale: Double) -> some View { UIZoom(scale: scale) { scaleEffect(scale, anchor: .topLeading) } }
}

extension NSScreen {
  /// Where `--agent-screen` puts windows: the Prompter XL, else the Agent Screen.
  static var agentScreen: NSScreen? {
    screens.first { $0.localizedName == "Prompter XL" } ?? screens.first { $0.localizedName == "Agent Screen" }
  }
}

struct MainWindowConfigurator: NSViewRepresentable {
  var size = NSSize(width: 1100, height: 750)
  final class Coordinator {
    var placed = false
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
  func updateNSView(_ view: NSView, context: Context) {
    guard CommandLine.arguments.contains("--agent-screen"), !context.coordinator.placed else { return }
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      context.coordinator.placed = true
      guard let area = NSScreen.agentScreen?.visibleFrame else { window.orderOut(nil); return }
      window.setFrame(area.centred(size).intersection(area), display: true)
      window.orderFrontRegardless()
    }
  }
}
