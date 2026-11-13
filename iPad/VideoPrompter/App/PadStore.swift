import Combine
import Foundation
import PrompterCore
import UIKit

/// The iPad app's state: the scripts folder, the reading session shared with the Mac app, and
/// the presenter settings. Presets live in the scripts folder so the Mac and iPad share them;
/// the settings that belong to this iPad's hardware (mirroring, microphone) stay on the iPad.
/// UI API: mirror/flip (Bool, backed by settings); editing/cleanScreen/micOn (Bool);
/// pictureMode/priority (PadRemote enums); macStatus (sources, selection, REC, connection),
/// micMeter (RemoteMicMeter; observe it directly for levelDB, -60...0). Call setMirror/setFlip, beginEditing/endEditing,
/// setPictureMode/setPicturePriority/setCleanScreen, selectCamera/setCameraOn,
/// selectMicrophone/setMicOn. Editing pauses and never resumes automatically.
@MainActor final class PadStore: ObservableObject {
  @Published private(set) var editing = false
  private var editingFromMac = false
  @Published private(set) var rejectionReason: String?
  @Published private(set) var pictureMode: PadRemote.PictureMode = .off
  @Published private(set) var picturePriority: PadRemote.PicturePriority = .realTime720p
  @Published private(set) var cleanScreen = false
  @Published private(set) var micOn = true
  @Published private(set) var macStatus = PadRemote.MacStatus()
  let micMeter = RemoteMicMeter()
  private(set) var macMicLevelDB: Double = -60
  var micLevelDB: Double {
    let level = session.followsRemote ? macMicLevelDB : Double(session.audioPeakDBFS)
    return level.isFinite ? min(0, max(-60, level)) : -60
  }
  var recordingState: PadRemote.RecordingState { macStatus.recording ?? .unknown }
  var macDisplayName: String? { macStatus.displayName ?? camera.link.macName }
  var connectionKind: String? { macStatus.connectionKind }
  var mirror: Bool { settings.horizontalMirror }
  var flip: Bool { settings.verticalMirror }
  var voiceSource: String { session.followsRemote ? "Mac" : "iPad" }
  var cameraSources: [PadRemote.Source] { macStatus.cameras ?? [] }
  var selectedCamera: String? { macStatus.selectedCamera }
  var cameraOn: Bool { macStatus.cameraOn ?? false }
  var microphoneSources: [PadRemote.Source] {
    if session.followsRemote { return macStatus.microphones ?? [] }
    return AudioCapture.inputDevices().map { .init(id: $0.uid, name: $0.name) }
  }
  var selectedMicrophone: String? {
    session.followsRemote ? macStatus.selectedMicrophone : settings.audioDeviceUID
  }
  func setVoiceSource(_ value: String) { perform(.voiceSource(value)) }
  func setMirror(_ value: Bool) { settings.horizontalMirror = value }
  func setFlip(_ value: Bool) { settings.verticalMirror = value }
  func beginEditing() { editingFromMac = false; editing = true; session.pause() }
  func endEditing() { editing = false; editingFromMac = false; rejectionReason = nil }
  func setPictureMode(_ value: PadRemote.PictureMode) { pictureMode = value; defaults.set(value.rawValue, forKey: "padPictureMode") }
  func setPicturePriority(_ value: PadRemote.PicturePriority) { picturePriority = value; defaults.set(value.rawValue, forKey: "padPicturePriority") }
  func setCleanScreen(_ value: Bool) { cleanScreen = value; defaults.set(value, forKey: "padCleanScreen") }
  func selectCamera(_ id: String) { camera.link.send(.selectCamera(id)) }
  func setCameraOn(_ value: Bool) { camera.link.send(.cameraOn(value)) }
  func selectMicrophone(_ id: String) {
    if session.followsRemote { camera.link.send(.selectMicrophone(id)) }
    else if microphoneSources.contains(where: { $0.id == id }) { settings.audioDeviceUID = id }
  }
  func setMicOn(_ value: Bool) {
    micOn = value
    if !value { session.pause() }
    if session.followsRemote { camera.link.send(.micOn(value)) }
  }

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
  private var lastSent: PadRemote.State?
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
    pictureMode = defaults.string(forKey: "padPictureMode").flatMap(PadRemote.PictureMode.init(rawValue:)) ?? .off
    picturePriority = defaults.string(forKey: "padPicturePriority").flatMap(PadRemote.PicturePriority.init(rawValue:)) ?? .realTime720p
    cleanScreen = defaults.bool(forKey: "padCleanScreen")
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
    session.meter.$peakDBFS.sink { [weak self] level in
      guard let self, !session.followsRemote else { return }
      micMeter.show(Double(level))
    }.store(in: &bag)
    session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    // The first value is the listing the folder made at launch, compared with the last launch's.
    folder.$scripts.sink { [weak self] scripts in
      Task { @MainActor in self?.foldersChanged(scripts) }
    }.store(in: &bag)
    pullPresets()
    #if DEBUG && targetEnvironment(simulator)
    if ProcessInfo.processInfo.environment["VP_IPAD_E2E_PORT"] != nil { checkRemoteContractsForE2E() }
    #endif
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
    link.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    link.onCommand = { [weak self] in self?.perform($0) }
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
      guard let self else { return }
      if name == nil {
        resetMacControls()
        // A relayed session never falls back to this iPad's microphone on its own: it stops, and
        // the next Play here is the reader's choice.
        if session.followsRemote {
          session.pause(); session.followsRemote = false
          // Test hook, only under the end-to-end launch: why the relay was reset, "drop" or "replaced".
          #if DEBUG && targetEnvironment(simulator)
          if ProcessInfo.processInfo.environment["VP_IPAD_E2E_PORT"] != nil {
            try? Data(link.lastEndReason.utf8).write(
              to: URL.documentsDirectory.appendingPathComponent("vp-e2e-link-reset.txt"), options: .atomic)
          }
          #endif
        }
        return
      }
      lastSent = remoteState
      link.send(lastSent!)
    }.store(in: &bag)
  }

  private func resetMacControls() {
    macStatus = PadRemote.MacStatus()
    macMicLevelDB = -60
    micMeter.show(-60)
    lastSent = nil
    micOn = true
    if editingFromMac { endEditing() }
    rejectionReason = nil
  }

  #if DEBUG && targetEnvironment(simulator)
  /// Actual store checks for the headless fixture, including local actions absent from the wire protocol.
  private func checkRemoteContractsForE2E() {
    var checks: [String: Bool] = [:]
    session.followsRemote = true
    var changes = 0
    let observation = objectWillChange.sink { changes += 1 }
    perform(.macStatus(.init(micLevelDB: -12)))
    checks["meterIsIsolated"] = changes == 0 && micMeter.levelDB == -12 && remoteState.macStatus?.micLevelDB == nil
    observation.cancel()
    session.followsRemote = false

    beginEditing()
    perform(.seek(word: 2))
    checks["immediateStateIsDeduplicated"] = lastSent == remoteState && rejectionReason != nil
    setMicOn(false)
    resetMacControls()
    checks["localEditSurvivesDrop"] = editing && rejectionReason == nil && micOn
    perform(.editing(false))
    checks["remoteCannotEndLocalEdit"] = editing
    endEditing()
    perform(.editing(true))
    perform(.seek(word: 2))
    setMicOn(false)
    resetMacControls()
    checks["remoteEditEndsOnDrop"] = !editing && rejectionReason == nil && micOn
    perform(.macStatus(.init(displayName: "Status Mac")))
    checks["statusDisplayNameWins"] = macDisplayName == "Status Mac"
    resetMacControls()
    if let data = try? JSONEncoder().encode(checks) {
      try? data.write(to: URL.documentsDirectory.appendingPathComponent("vp-e2e-contract-checks.json"), options: .atomic)
    }
  }
  #endif

  var remoteState: PadRemote.State {
    let open = presentingID != nil
    let words = open ? session.document.spokenTokens.count : 0
    return PadRemote.State(
      scripts: folder.scripts.map {
        let macID = folder.macID(of: $0.id)
        return PadRemote.Script(
          id: $0.id, title: $0.title, macID: macID, fingerprint: macID == nil ? nil : folder.fingerprint(of: $0))
      },
      presenting: presentingID, running: open && session.isActivelyRunning,
      mode: settings.mode, speed: Int(settings.speed.rounded()),
      word: words > 0 ? session.tokenIndex + 1 : 0, words: words,
      version: CameraLink.protocolVersion,
      look: PadRemote.Look(
        horizontalMirror: settings.horizontalMirror, verticalMirror: settings.verticalMirror,
        fontSize: settings.fontSize, textWidth: settings.textWidth, lineSpacing: settings.lineSpacing,
        guideFraction: settings.guideFraction),
      presets: presets.map(\.name), startDelay: session.startDelay,
      voiceSource: session.followsRemote ? "Mac" : "iPad",
      seekRevision: open ? session.seekRevision : nil,
      fingerprint: open ? session.activeRecord?.metadata.contentFingerprint : nil,
      editing: editing, rejectionReason: rejectionReason, pictureMode: pictureMode,
      picturePriority: picturePriority, cleanScreen: cleanScreen, micOn: micOn, macStatus: macStatus,
      microphoneSources: microphoneSources, selectedMicrophone: selectedMicrophone, selectedID: selectedID,
      deviceName: UIDevice.current.name,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      scriptPreview: open ? session.document.spokenTokens.dropFirst(max(0, session.tokenIndex)).prefix(30).map(\.text).joined(separator: " ") : nil)
  }

  func perform(_ command: PadRemote.Command) {
    if editing {
      var blocked = false
      switch command {
      case .play, .seek, .backToStart, .nextPassage, .previousPassage, .follow, .present, .close:
        blocked = true
      case .sendScript(let transfer):
        blocked = presentingID.flatMap { folder.macID(of: $0) } == transfer.macID
          || selectedID.flatMap { folder.macID(of: $0) } == transfer.macID || transfer.present
      default: break
      }
      if blocked {
        rejectionReason = "Finish editing on the iPad first"
        lastSent = remoteState
        camera.link.send(lastSent!)
        return
      }
    }
    switch command {
    case .editing(let value):
      if value {
        if !editing { beginEditing(); editingFromMac = true }
      } else if editingFromMac { endEditing() }
    case .pictureMode(let value): setPictureMode(value)
    case .picturePriority(let value): setPicturePriority(value)
    case .cleanScreen(let value): setCleanScreen(value)
    case .micOn(let value): setMicOn(value)
    case .selectCamera(let id): selectCamera(id)
    case .cameraOn(let value): setCameraOn(value)
    case .selectMicrophone(let id): selectMicrophone(id)
    case .macStatus(var value):
      if let db = value.micLevelDB {
        macMicLevelDB = db.isFinite ? min(0, max(-60, db)) : -60
        if session.followsRemote { micMeter.show(macMicLevelDB) }
      }
      // Meter updates must not reset the source list.
      value.micLevelDB = nil
      var next = macStatus
      if let cameras = value.cameras { next.cameras = cameras }
      if let microphones = value.microphones { next.microphones = microphones }
      // List-only updates preserve selections; a complete list that removes one clears it.
      if let cameras = value.cameras, let id = next.selectedCamera, !cameras.contains(where: { $0.id == id }) { next.selectedCamera = nil }
      if let microphones = value.microphones, let id = next.selectedMicrophone, !microphones.contains(where: { $0.id == id }) { next.selectedMicrophone = nil }
      if let selected = value.selectedCamera { next.selectedCamera = selected }
      if let selected = value.selectedMicrophone { next.selectedMicrophone = selected }
      if let on = value.cameraOn { next.cameraOn = on }
      if let on = value.micOn { next.micOn = on }
      if let recording = value.recording { next.recording = recording }
      if let name = value.displayName { next.displayName = name }
      if let kind = value.connectionKind { next.connectionKind = kind }
      if next != macStatus { macStatus = next }

    case .present(let id):
      guard let script = folder.script(id) else { return }
      selectedID = id
      present(script)
    case .mode(let mode):
      if ["Voice", "Manual"].contains(mode) { settings.mode = mode }
    case .speed(let speed):
      settings.speed = Double(min(max(speed, 20), 300))
    case .sendScript(let transfer):
      do {
        guard let script = try folder.receive(transfer) else { return }
        if !editing { selectedID = script.id }
        if transfer.present, presentingID != script.id { present(script) }
        objectWillChange.send()
      } catch { errorMessage = error.localizedDescription }
    case .look(let look):
      var next = settings
      if let value = look.horizontalMirror { next.horizontalMirror = value }
      if let value = look.verticalMirror { next.verticalMirror = value }
      if let value = look.fontSize, value.isFinite { next.fontSize = value }
      if let value = look.textWidth, value.isFinite { next.textWidth = value }
      if let value = look.lineSpacing, value.isFinite { next.lineSpacing = value }
      if let value = look.guideFraction, value.isFinite { next.guideFraction = value }
      settings = next
    case .preset(let name):
      if let preset = presets.first(where: { $0.name == name }) { apply(preset) }
    case .startDelay(let seconds):
      if [0, 3, 5].contains(seconds) { session.startDelay = seconds }
    case .voiceSource(let source):
      switch source {
      case "Mac":
        micMeter.show(macMicLevelDB)
        // Before the mode change, so switching to Voice cannot start this iPad's microphone.
        session.followsRemote = true
        settings.mode = "Voice"
      case "iPad": session.followsRemote = false; micMeter.show(Double(session.audioPeakDBFS))
      default: return
      }
      objectWillChange.send()
    case .follow(let follow):
      guard session.followsRemote, presentingID != nil, settings.mode == "Voice",
        follow.fingerprint == session.activeRecord?.metadata.contentFingerprint,
        follow.seekRevision == session.seekRevision
      else { return }
      session.followRemote(confirmed: follow.confirmed)
    default:
      // The rest act on the open presenter, as its buttons do.
      guard presentingID != nil else { return }
      switch command {
      case .close: closePresenter()
      // The iPad's own Start: honours the Manual countdown. Pause cancels it.
      case .play: if micOn || settings.mode != "Voice" { session.startReading() }
      case .pause: session.pause()
      case .backToStart: session.restart()
      case .nextPassage: session.nextPassage()
      case .previousPassage: session.previousPassage()
      case .seek(let word):
        if word >= 1, word <= session.document.spokenTokens.count { session.seek(to: word - 1) }
      default: break
      }
    }
  }
}
