import Combine
import Foundation
import PrompterCore
import UIKit

/// The iPad app's state: the scripts folder, the reading session shared with the Mac app, and
/// the presenter settings. Presets live in the scripts folder so the Mac and iPad share them;
/// the settings that belong to this iPad's hardware (mirroring, microphone) stay on the iPad.
@MainActor final class PadStore: ObservableObject {
  let folder = ScriptFolder()
  let session = SessionStore()
  let camera = PadCamera()
  let google = GoogleDocs()
  @Published var selectedID: UUID?
  @Published var presentingID: UUID?
  @Published var errorMessage: String?
  @Published var settings = PrompterSettings() {
    didSet {
      guard settings != oldValue else { return }
      persist()
      if session.activeRecord != nil { session.updateSettings(settings) }
    }
  }
  @Published var presets: [PrompterSettings] = [] {
    didSet {
      guard presets != oldValue else { return }
      persist()
      folder.writePresets(presets)
    }
  }

  private let defaults: UserDefaults
  private var bag = Set<AnyCancellable>()
  private var presentedModified: Date?
  /// The scripts each folder held at the last look, by folder path and kept across launches,
  /// to notice files deleted anywhere, including while the app was closed or another folder
  /// was in use.
  private var knownIDs: [String: [String]]
  private static let settingsKey = "padSettings"
  private static let presetsKey = "padPresets"
  private static let knownIDsKey = "padKnownScriptsByFolder"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    knownIDs = defaults.dictionary(forKey: Self.knownIDsKey) as? [String: [String]] ?? [:]
    if let data = defaults.data(forKey: Self.settingsKey),
      let saved = try? JSONDecoder().decode(PrompterSettings.self, from: data)
    { settings = saved } else {
      // An iPad under teleprompter glass is the usual case, so a first launch starts mirrored.
      settings.horizontalMirror = true
      settings.fontSize = 56
    }
    if let data = defaults.data(forKey: Self.presetsKey),
      let saved = try? JSONDecoder().decode([PrompterSettings].self, from: data)
    { presets = saved }
    folder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    // The first value is the listing the folder made at launch, compared with the last launch's.
    folder.$scripts.sink { [weak self] scripts in
      Task { @MainActor in self?.foldersChanged(scripts) }
    }.store(in: &bag)
    pullPresets()
    startMacRemote()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.presetsKey) }
  }

  // MARK: Presets

  /// Presets made on the Mac appear here, and the other way round. The newer file wins.
  func pullPresets() {
    guard let shared = folder.readPresets(), shared != presets else { return }
    presets = shared
  }

  func savePreset(named name: String) {
    var preset = settings
    preset.id = UUID()
    preset.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Preset \(presets.count + 1)" : name
    presets.append(preset)
  }

  /// A preset brings its look, but this iPad keeps its own mirroring and microphone.
  func apply(_ preset: PrompterSettings) {
    var next = preset
    next.horizontalMirror = settings.horizontalMirror
    next.verticalMirror = settings.verticalMirror
    next.audioDeviceUID = settings.audioDeviceUID
    next.inputGain = settings.inputGain
    next.rotation = settings.rotation
    settings = next
  }

  func deletePresets(at offsets: IndexSet) { presets.remove(atOffsets: offsets) }

  // MARK: Scripts

  var selected: FolderScript? { selectedID.flatMap(folder.script) }

  func newScript() {
    var title = "New Script"
    var n = 2
    while folder.scripts.contains(where: { $0.title == title }) { title = "New Script \(n)"; n += 1 }
    do {
      let script = try folder.create(title: title, markdown: "# \(title)\n\n")
      selectedID = script.id
    } catch { errorMessage = error.localizedDescription }
  }

  func importFile(_ url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let preview = try await DocumentImporter().preview(url: url)
      var title = url.deletingPathExtension().lastPathComponent
      if folder.scripts.contains(where: { $0.title == title }) { title += " (imported)" }
      let script = try folder.create(title: title, markdown: preview.markdown)
      selectedID = script.id
      if let warning = preview.warnings.first { errorMessage = warning }
    } catch { errorMessage = error.localizedDescription }
  }

  func record(for script: FolderScript) -> ScriptRecord? {
    do { return try folder.record(for: script) } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func save(_ markdown: String, to script: FolderScript) -> Bool {
    do {
      let record = try folder.save(markdown, to: script)
      if session.activeScriptID == script.id { session.applyEditedRecord(record) }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  // MARK: Presenting

  func present(_ script: FolderScript) {
    guard let record = record(for: script) else { return }
    ensureMicrophone()
    session.present(record: record, settings: settings)
    presentedModified = script.modified
    presentingID = script.id
    UIApplication.shared.isIdleTimerDisabled = true
  }

  func closePresenter() {
    session.pause()
    presentingID = nil
    UIApplication.shared.isIdleTimerDisabled = false
    // A script deleted while it was on screen is cleaned up now.
    forgetRemoved(folder.scripts)
  }

  /// Voice needs a microphone chosen; the built-in one unless another is plugged in and chosen.
  func ensureMicrophone() {
    let devices = AudioCapture.inputDevices()
    if settings.audioDeviceUID.map({ uid in devices.contains { $0.uid == uid } }) != true {
      settings.audioDeviceUID = AudioCapture.defaultDevice()?.uid
    }
  }

  /// A change saved on the Mac reaches the open presenter as an edit: the reading position is
  /// carried across exactly as it is for an edit made here.
  private func foldersChanged(_ scripts: [FolderScript]) {
    pullPresets()
    forgetRemoved(scripts)
    guard let id = presentingID ?? session.activeScriptID,
      let script = scripts.first(where: { $0.id == id }), script.isDownloaded,
      script.modified != presentedModified,
      let record = try? folder.record(for: script),
      record.markdown != session.activeRecord?.markdown
    else { return }
    presentedModified = script.modified
    session.applyEditedRecord(record)
  }

  /// A script deleted here, on the Mac or in Files leaves nothing behind: its reading position
  /// (which holds a copy of its text), its Google link and its identity all go. Skipped while
  /// the folder itself is unreachable, when an empty list means nothing.
  private func forgetRemoved(_ scripts: [FolderScript]) {
    let root = folder.rootURL.standardizedFileURL.path
    // An unreachable folder lists nothing, which says nothing about what was deleted.
    guard FileManager.default.fileExists(atPath: root) else { return }
    var current = Set(scripts.map(\.id))
    // Each folder is compared only with its own last listing: choosing another folder is not
    // deleting the old one's scripts.
    if let saved = knownIDs[root] {
      let known = Set(saved.compactMap(UUID.init(uuidString:)))
      for id in known.subtracting(current) {
        // The script on screen stays until the presenter closes, which comes back here.
        if id == presentingID { current.insert(id); continue }
        session.forgetScript(id)
        googleLinks[id] = nil
        folder.forget(id)
      }
    }
    knownIDs[root] = current.map(\.uuidString)
    defaults.set(knownIDs, forKey: Self.knownIDsKey)
  }

  // MARK: Google Docs

  private var googleLinks: GoogleDocLinks { GoogleDocLinks(defaults: defaults) }

  func isFromGoogle(_ script: FolderScript) -> Bool { googleLinks[script.id] != nil }
  /// A deleted script keeps no record of where it came from.
  func forgetGoogleLink(_ script: FolderScript) { googleLinks[script.id] = nil }

  /// Imports a Google Doc as a new script and selects it. Returns why it failed, or nil.
  func importGoogleDoc(_ document: String) async -> String? {
    do {
      let (name, markdown) = try await google.export(document)
      var title = name
      var n = 2
      while folder.scripts.contains(where: { $0.title == title }) { title = "\(name) \(n)"; n += 1 }
      let script = try folder.create(title: title, markdown: markdown)
      googleLinks[script.id] = .init(document: document, fingerprint: MarkdownLibrary.fingerprint(markdown))
      selectedID = script.id
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  enum GoogleRefresh { case updated, unchanged, hasLocalEdits }

  /// Fetches the script's Google Doc again. Without `overwrite`, a script edited since the last
  /// import is left alone and `.hasLocalEdits` comes back, so the caller can ask first.
  func refreshFromGoogle(_ script: FolderScript, overwrite: Bool = false) async -> GoogleRefresh? {
    guard let link = googleLinks[script.id] else { return nil }
    do {
      let current = try ScriptFolder.read(script.url)
      if !overwrite, MarkdownLibrary.fingerprint(current) != link.fingerprint { return .hasLocalEdits }
      let (_, markdown) = try await google.export(link.document)
      // Deleted while Google answered: do not bring it back.
      guard googleLinks[script.id] != nil, folder.script(script.id) != nil,
        FileManager.default.fileExists(atPath: script.url.path)
      else { return nil }
      let fresh = GoogleDocLinks.Link(document: link.document, fingerprint: MarkdownLibrary.fingerprint(markdown))
      guard markdown != current else {
        googleLinks[script.id] = fresh
        // Google still matches what was read, but the file may have been edited meanwhile.
        return try ScriptFolder.read(script.url) == current ? .unchanged : .hasLocalEdits
      }
      // Written straight over the file: the doc is the master. An open presenter picks the
      // change up from the folder like an edit made on the Mac, keeping its place. Edited here
      // or on the Mac while Google answered: those edits were never confirmed away.
      guard try ScriptFolder.replace(current, with: markdown, at: script.url) else { return .hasLocalEdits }
      googleLinks[script.id] = fresh
      folder.refresh()
      return .updated
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}

// MARK: - Control from a Mac

extension PadStore {
  /// The Mac's File › Control iPad drives the presenter the way its own buttons do, and sees
  /// what it shows: sent a moment after anything changes, and at once when a Mac connects.
  fileprivate func startMacRemote() {
    let link = camera.link
    link.onCommand = { [weak self] in self?.perform($0) }
    var lastSent: PadRemote.State?
    // DispatchQueue, not RunLoop: a run loop scheduler waits while a finger is on the screen.
    objectWillChange.receive(on: DispatchQueue.main)
      .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        guard let self, link.macName != nil else { return }
        let state = remoteState
        if state != lastSent { link.send(state) }
        lastSent = state
      }.store(in: &bag)
    link.$macName.receive(on: DispatchQueue.main).sink { [weak self] name in
      guard let self, name != nil else { return }
      lastSent = remoteState
      link.send(lastSent!)
    }.store(in: &bag)
  }

  var remoteState: PadRemote.State {
    let open = presentingID != nil
    let words = open ? session.document.spokenTokens.count : 0
    return PadRemote.State(
      scripts: folder.scripts.map { PadRemote.Script(id: $0.id, title: $0.title) },
      presenting: presentingID, running: open && session.isActivelyRunning,
      mode: settings.mode, speed: Int(settings.speed.rounded()),
      word: words > 0 ? session.tokenIndex + 1 : 0, words: words)
  }

  func perform(_ command: PadRemote.Command) {
    switch command {
    case .present(let id):
      guard let script = folder.script(id) else { return }
      selectedID = id
      present(script)
    case .mode(let mode):
      if ["Voice", "Manual"].contains(mode) { settings.mode = mode }
    case .speed(let speed):
      settings.speed = Double(min(max(speed, 20), 300))
    default:
      // The rest act on the open presenter, as its buttons do.
      guard presentingID != nil else { return }
      switch command {
      case .close: closePresenter()
      case .play: session.play()
      case .pause: session.pause()
      case .backToStart: session.restart()
      case .nextPassage: session.nextPassage()
      case .previousPassage: session.previousPassage()
      case .seek(let word):
        if word >= 1, word <= session.document.spokenTokens.count { session.seek(to: word - 1) }
      case .present, .mode, .speed: break
      }
    }
  }
}
