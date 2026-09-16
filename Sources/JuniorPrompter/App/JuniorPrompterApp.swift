import AppKit
import PrompterCore
import SwiftUI

extension Notification.Name {
  static let juniorPrompterImport = Notification.Name("JuniorPrompter.import")
}

struct PrompterSettings: Codable, Equatable, Identifiable {
  var id = UUID()
  var name = "Default"
  var fontName = "Lexend Deca"
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
  var showCues = false
  var highlightActiveWord = false
  var presenterSnappingEnabled = false
  var allowsBackwardVoiceTracking = true
  private enum CodingKeys: String, CodingKey { case id,name,fontName,fontSize,textOpacity,backgroundOpacity,guideFraction,horizontalMirror,verticalMirror,rotation,mode,speed,audioDeviceUID,inputGain,soundThreshold,speechLanguage,fontWeight,textColorHex,backgroundColorHex,lineSpacing,paragraphSpacing,horizontalMargin,alignment,showCues,highlightActiveWord,presenterSnappingEnabled,allowsBackwardVoiceTracking }
  init() {}
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Default"; fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Lexend Deca"; fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 44; textOpacity = try c.decodeIfPresent(Double.self, forKey: .textOpacity) ?? 1; backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.82; guideFraction = try c.decodeIfPresent(Double.self, forKey: .guideFraction) ?? 0.35; horizontalMirror = try c.decodeIfPresent(Bool.self, forKey: .horizontalMirror) ?? false; verticalMirror = try c.decodeIfPresent(Bool.self, forKey: .verticalMirror) ?? false; rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0; mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "Voice"; speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 120; audioDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioDeviceUID); inputGain = try c.decodeIfPresent(Double.self, forKey: .inputGain) ?? 1; soundThreshold = try c.decodeIfPresent(Double.self, forKey: .soundThreshold) ?? 0.055; speechLanguage = try c.decodeIfPresent(String.self, forKey: .speechLanguage) ?? "Mixed"; fontWeight = try c.decodeIfPresent(String.self, forKey: .fontWeight) ?? "Regular"; textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"; backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? "#000000"; lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0.16; paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 0.34; horizontalMargin = try c.decodeIfPresent(Double.self, forKey: .horizontalMargin) ?? 42; alignment = try c.decodeIfPresent(String.self, forKey: .alignment) ?? "Left"; showCues = try c.decodeIfPresent(Bool.self, forKey: .showCues) ?? false; highlightActiveWord = try c.decodeIfPresent(Bool.self, forKey: .highlightActiveWord) ?? false; presenterSnappingEnabled = try c.decodeIfPresent(Bool.self, forKey: .presenterSnappingEnabled) ?? false; allowsBackwardVoiceTracking = try c.decodeIfPresent(Bool.self, forKey: .allowsBackwardVoiceTracking) ?? true
  }
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
  @Published var search = ""
  @Published var inspector = true
  @Published var settings = PrompterSettings() { didSet { persistSettings() } }
  @Published var presets: [PrompterSettings] = []
  @Published var sourceFontName = "Lexend Deca" { didSet { persistSettings() } }
  @Published var sourceFontSize = 17.0 { didSet { persistSettings() } }
  @Published var previewFontName = "Lexend Deca" { didSet { persistSettings() } }
  @Published var previewFontSize = 18.0 { didSet { persistSettings() } }
  @Published var errorMessage: String?
  @Published private(set) var hasFailedSaves = false
  @Published private(set) var libraryAvailable = false
  @Published private(set) var unavailableScriptIDs = Set<UUID>()
  var scriptsTracked: Int { Set(scripts.map(\.id)).union(trash.map(\.id)).count }

  private(set) var library: MarkdownLibrary?
  let session = SessionStore()
  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  private var saveTaskTokens: [UUID: UUID] = [:]
  private var presenterSaveIDs = Set<UUID>()
  var presenterSaveReservationHook: (() -> Void)?
  var presenterSaveReservationGate: (() async -> Void)?
  private var presenterSaveWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var failedSaveIDs = Set<UUID>()
  private var pendingDrafts: [UUID: String] = [:]
  private var externalWatcher: Task<Void, Never>?
  private var activationObserver: NSObjectProtocol?  // held for the app's lifetime; the block is [weak self]
  private let defaults: UserDefaults

  init(arguments: [String] = CommandLine.arguments, defaults: UserDefaults? = nil) {
    _ = AvailableFonts.presenter
    let root: URL
    if let i = arguments.firstIndex(of: "--data-directory"), i + 1 < arguments.count {
      root = URL(fileURLWithPath: arguments[i + 1])
    } else {
      root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".alpha") == true
          ? "JuniorPrompter Alpha" : "JuniorPrompter", isDirectory: true)
    }
    let hasTestDirectory = arguments.firstIndex(of: "--data-directory").map { $0 + 1 < arguments.count } ?? false
    let isolatedDefaults = defaults ?? (hasTestDirectory
      ? UserDefaults(suiteName: "JuniorPrompter.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))")!
      : .standard)
    self.defaults = isolatedDefaults
    let savedPresets = isolatedDefaults.data(forKey: "presets")
    let savedTypography = isolatedDefaults.data(forKey: "editorTypography")
    let savedSettings = isolatedDefaults.data(forKey: "settings")
    if let data = savedPresets,
      let saved = try? JSONDecoder().decode([PrompterSettings].self, from: data)
    {
      presets = saved
    }
    if let data = savedTypography,
      let saved = try? JSONDecoder().decode(EditorTypographyPreferences.self, from: data)
    {
      sourceFontName = saved.sourceFontName
      sourceFontSize = saved.sourceFontSize
      previewFontName = saved.previewFontName
      previewFontSize = saved.previewFontSize
    }
    if let data = savedSettings,
      let saved = try? JSONDecoder().decode(PrompterSettings.self, from: data)
    {
      settings = saved
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
    // Coming back from MarkEdit or Obsidian should not wait for the next tick.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in await self?.refreshExternalChanges() } }
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
    var loaded: [ScriptRecord] = []
    for metadata in await library.listScripts() {
      do {
        loaded.append(try await library.read(metadata.id))
        unavailableScriptIDs.remove(metadata.id)
      } catch {
        if let cached = scripts.first(where: { $0.id == metadata.id }) {
          loaded.append(cached)
        }
        let nsError = error as NSError
        let missing = (nsError.domain == NSCocoaErrorDomain && (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue))
          || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
        if missing {
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
      protectedIDs.contains(record.id)
        ? (scripts.first(where: { $0.id == record.id }) ?? record)
        : record
    }
    scripts = loaded
    trash = await library.listTrash()
    folders = await library.listFolders()
    if let selectedID, loaded.contains(where: { $0.metadata.id == selectedID }) {
      self.selectedID = selectedID
    } else {
      selectedID = loaded.first?.metadata.id
    }
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

  func create(title: String = "Untitled Script", markdown: String = "", linkTo: URL? = nil) {
    guard let library else { return }
    Task {
      do {
        var item = try await library.create(title: title, markdown: markdown, folderID: selectedFolderID)
        if let linkTo { item.metadata = try await library.link(item.id, to: linkTo) }
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
    pendingDrafts[id] = value
    guard !presenterSaveIDs.contains(id) else { return }
    scheduleMarkdownSave(value, for: id, expectedFingerprint: scripts[position].metadata.contentFingerprint)
  }
  private func scheduleMarkdownSave(_ value: String, for id: UUID, expectedFingerprint: String) {
    saveTasks[id]?.cancel()
    let taskToken = UUID()
    saveTaskTokens[id] = taskToken
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
        let saved = try await library.save(id, markdown: value, expectedFingerprint: expectedFingerprint)
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
        scheduleMarkdownSave(queued, for: id, expectedFingerprint: saved.metadata.contentFingerprint)
      } else if scripts[index] == baseline {
        scripts[index] = saved
        session.applyEditedRecord(saved)
      } else {
        throw PresenterSaveError.changedDuringSave
      }
    } catch {
      if let queued = pendingDrafts[id], let current = scripts.first(where: { $0.id == id }) {
        scheduleMarkdownSave(queued, for: id, expectedFingerprint: current.metadata.contentFingerprint)
      }
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
        let saved = try await library.save(id, markdown: draft, expectedFingerprint: current.metadata.contentFingerprint)
        guard let index = scripts.firstIndex(where: { $0.id == id }), scripts[index].markdown == draft else { continue }
        scripts[index] = saved
        failedSaveIDs.remove(id)
        hasFailedSaves = !failedSaveIDs.isEmpty
        pendingDrafts[id] = nil
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
    guard let library else { return }
    Task {
      do {
        let metadata = try await library.unlink(id)
        if let i = scripts.firstIndex(where: { $0.metadata.id == id }) { scripts[i].metadata = metadata }
      } catch { errorMessage = String(describing: error) }
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
    var applied = preset
    applied.name = settings.name
    applied.audioDeviceUID = settings.audioDeviceUID
    applied.speechLanguage = settings.speechLanguage
    settings = applied
  }
  func deletePreset(_ id: UUID) {
    presets.removeAll { $0.id == id }
    persistSettings()
  }
  private func persistSettings() {
    if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
    if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "presets") }
    let typography = EditorTypographyPreferences(
      sourceFontName: sourceFontName, sourceFontSize: sourceFontSize,
      previewFontName: previewFontName, previewFontSize: previewFontSize)
    if let data = try? JSONEncoder().encode(typography) { defaults.set(data, forKey: "editorTypography") }
  }
  func refreshExternalChanges() async {
    guard let library else { return }
    do {
      if !(try await library.discoverExternalScripts()).isEmpty { await reload() }
    } catch { errorMessage = "New script files could not be added. \(error)" }
    for metadata in await library.listScripts()
    where (saveTasks[metadata.id] == nil || saveTasks[metadata.id]?.isCancelled == true)
      && !failedSaveIDs.contains(metadata.id) && !presenterSaveIDs.contains(metadata.id) {
      do {
        let changed = try await library.externalChange(for: metadata.id)
        if let changed {
          guard !failedSaveIDs.contains(metadata.id), saveTasks[metadata.id] == nil,
            !presenterSaveIDs.contains(metadata.id) else { continue }
          if let i = scripts.firstIndex(where: { $0.id == metadata.id }) {
            scripts[i] = changed
          } else {
            scripts.insert(changed, at: 0)
          }
          session.applyEditedRecord(changed)
          unavailableScriptIDs.remove(metadata.id)
        } else if unavailableScriptIDs.contains(metadata.id) {
          let restored = try await library.read(metadata.id)
          guard !failedSaveIDs.contains(metadata.id), saveTasks[metadata.id] == nil,
            !presenterSaveIDs.contains(metadata.id) else { continue }
          if let i = scripts.firstIndex(where: { $0.id == metadata.id }) {
            scripts[i] = restored
          } else {
            scripts.insert(restored, at: 0)
          }
          session.applyEditedRecord(restored)
          unavailableScriptIDs.remove(metadata.id)
        }
      } catch {
        let nsError = error as NSError
        let missing = (nsError.domain == NSCocoaErrorDomain && (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue))
          || (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
        if missing, unavailableScriptIDs.insert(metadata.id).inserted {
          if session.activeScriptID == metadata.id { session.pause() }
          errorMessage = "The script file is unavailable. Restore the original file, or export and import a copy."
        } else if !missing {
          errorMessage = String(describing: error)
        }
      }
    }
    if let conflict = await library.takeLinkConflicts().first {
      errorMessage =
        "The linked file and your in-app edit both changed. The file on disk was used; your version is kept as \(conflict) in the library's Conflicts folder."
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
        CommandGroup(after: .textEditing) {
          Button("Find…") {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            let responder = NSApp.keyWindow?.firstResponder
            if let textView = responder as? NSTextView { textView.usesFindBar = true }
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: responder, from: item)
          }.keyboardShortcut("f", modifiers: .command)
        }
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
      guard let screen = (NSScreen.screens.first(where: { $0.localizedName == "Prompter XL" }) ?? NSScreen.screens.first(where: { $0.localizedName == "Agent Screen" })) else {
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
