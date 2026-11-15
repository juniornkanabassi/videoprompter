#if os(macOS)
import Combine
import Foundation
import PrompterCore

/// What the relay needs from the iPad link: the iPad's own commands, and a way to tell the
/// camera encoder to keep its video queue short while words are being sent.
@MainActor protocol PadRelayLink: AnyObject {
  func send(_ command: PadRemote.Command)
  func setRelayActive(_ active: Bool)
}

/// Mac voice relay: this Mac's microphone follows a script, and every word it confirms goes to
/// the iPad's presenter as a `.follow` command. Audio never travels, only the word.
///
/// The relay owns a SessionStore of its own, on a throwaway defaults suite, so the presenter's
/// saved reading positions are never touched. It runs alone in v1: if the Mac's own presenter is
/// already listening, it refuses to start.
@MainActor final class PadVoiceRelay: ObservableObject {
  @Published private(set) var status = "Off"
  @Published private(set) var isRelaying = false
  /// The relay session's microphone level, for a meter. Nil while off.
  @Published private(set) var meter: InputMeter?

  weak var link: PadRelayLink?
  /// True while the Mac's own presenter is listening to a microphone. Replaced in tests.
  var presenterIsCapturing: () -> Bool = {
    let session = AppStore.shared.session
    return session.isActivelyRunning && session.settings.mode == "Voice" && !session.followsRemote
  }
  /// Tests replay recorded candidates instead of opening the microphone.
  var captureAudio = true
  /// How long to wait for the iPad to confirm each step before giving up.
  var confirmationTimeout: Duration = .seconds(5)

  private let suiteName: String
  /// The Mac's own preferences: only the text last sent to the iPad is kept there, per script.
  private let defaults: UserDefaults
  private static let sentKey = "padRelaySentFingerprints"
  /// Bumped by every start and finish, so a start that was stopped never acts afterwards.
  private var run = 0
  private enum Phase { case idle, preparing, live }
  private var phase = Phase.idle
  private(set) var session: SessionStore?
  private var bag = Set<AnyCancellable>()
  private var startTask: Task<Void, Never>?
  private var iPadState: PadRemote.State?
  private var iPadScriptID: UUID?
  private var fingerprint = ""
  private var knownRevision = 0
  private var wantsRunning = false
  private var requestedMacVoice = false
  private var micPaused = false
  private var resumeAfterMic = false
  private var iPadRunning = false
  /// Set while the relay itself moves the session, so its own seek is not sent back.
  private var movingSession = false

  init(link: PadRelayLink? = nil, suiteName: String = "VideoPrompter.padRelay", defaults: UserDefaults = .standard) {
    self.link = link
    self.suiteName = suiteName
    self.defaults = defaults
  }

  /// Sends the script to the iPad if it lacks it, then listens and follows. Asynchronous: the
  /// status says how far it got.
  func startFromIPad(settings: PrompterSettings) {
    guard let state = iPadState, let id = state.presenting,
      let text = state.markdown, text.utf8.count <= PadRemote.Transfer.maximumMarkdownBytes,
      MarkdownLibrary.fingerprint(text) == state.fingerprint,
      let entry = state.scripts.first(where: { $0.id == id }) else { return fail("Open a script on the iPad first") }
    let record = ScriptRecord(metadata: ScriptMetadata(id: entry.macID ?? id, title: entry.title, fileName: "ipad.md"), markdown: text)
    start(script: record, settings: settings, fromIPad: true)
  }

  func start(script: ScriptRecord, settings: PrompterSettings, fromIPad: Bool = false) {
    guard phase == .idle else { return }
    guard let state = iPadState else { return fail("No iPad is connected") }
    guard (state.version ?? 2) >= 3 else { return fail("Update Video Prompter on the iPad to use the Mac's voice") }
    guard state.editing != true else { return fail("Finish editing on the iPad first") }
    guard !presenterIsCapturing() else { return fail("The Mac's own presenter is listening. Stop it first") }
    phase = .preparing
    isRelaying = true
    status = "Getting the script onto the iPad…"
    run += 1
    let thisRun = run
    let presentedID = fromIPad ? state.presenting : nil
    startTask = Task { [weak self] in await self?.begin(script: script, settings: settings, run: thisRun, presentedID: presentedID) }
  }

  func setChannel(_ channel: AudioChannel) {
    guard let device = AudioCapture.resolvedInput(session?.settings.audioDeviceUID),
      let preferences = UserDefaults(suiteName: suiteName) else { return }
    channel.save(device.uid, defaults: preferences)
    let resume = wantsRunning
    pause()
    if resume { play() }
  }

  /// Returns voice following to the iPad and pauses it before releasing the relay.
  func stop() { finish("Stopped", pausingIPad: true) }

  /// A microphone toggle suspends capture without ending the relay or losing its place.
  public func pauseForMic() {
    guard phase == .live, !micPaused else { return }
    micPaused = true
    resumeAfterMic = wantsRunning
    pause()
  }

  public func resumeForMic() {
    guard phase == .live, micPaused else { return }
    micPaused = false
    let resume = resumeAfterMic && iPadState?.editing != true
    resumeAfterMic = false
    if resume {
      play()
      link?.send(.play)
    }
  }

  /// Fed with every state the iPad sends, and nil when the link drops.
  func iPadStateChanged(_ state: PadRemote.State?) {
    iPadState = state
    if state?.editing == true, phase == .preparing {
      return finish("Finish editing on the iPad first", pausingIPad: false)
    }
    if state == nil, phase == .preparing { return finish("The link to the iPad dropped", pausingIPad: false) }
    guard phase == .live else { return }
    guard let state else { return finish("The link to the iPad dropped", pausingIPad: false) }
    guard state.presenting == iPadScriptID, state.seekRevision != nil else {
      return finish("The iPad opened another script or closed this one", pausingIPad: true)
    }
    // shortcut: the iPad reports only a fingerprint, never its saved text, so the relay cannot adopt an
    // edit; upgrade by sending the saved text in State and remapping with ScriptTransfer. Until then it
    // hands the voice back to the iPad's own microphone instead of waiting for words nobody sends.
    guard state.fingerprint == fingerprint else {
      return finish("The script was edited on the iPad, so the Mac's voice stopped. The iPad is using its own microphone", pausingIPad: true)
    }
    guard state.voiceSource == "Mac" else { return finish("The iPad is listening with its own microphone", pausingIPad: false) }
    if state.editing == true {
      resumeAfterMic = false
      pause()
      iPadRunning = false
      return
    }
    if state.micOn == false {
      pauseForMic()
      iPadRunning = false
      return
    }
    if micPaused { resumeForMic(); return }
    // A new language on the iPad renumbers its words and bumps its revision, adopted just below.
    if let language = Self.language(of: state), let session, session.settings.speechLanguage != language {
      var changed = session.settings
      changed.speechLanguage = language
      movingSession = true
      session.updateSettings(changed)
      movingSession = false
    }
    // Only a seek on the iPad moves the relay; its word changing as it follows us does not. The iPad
    // checks each follow against its current revision and states arrive in order, so any change
    // (the counter wraps) is a seek to adopt, and a follow stamped earlier is already stale.
    if let revision = state.seekRevision, revision != knownRevision {
      knownRevision = revision
      move(to: state.word - 1)
      // The relay stopped itself at the end of the script; a seek on a running iPad starts it again.
      if state.running, session?.isActivelyRunning == false { play() }
    }
    // Transitions only: after the script's end the relay stays stopped while the iPad's own pause catches up.
    if state.running != iPadRunning {
      iPadRunning = state.running
      state.running ? play() : pause()
    }
  }

  // MARK: - Starting

  private func begin(script: ScriptRecord, settings: PrompterSettings, run: Int, presentedID: UUID?) async {
    // A stopped or replaced start does nothing at all, and above all sends nothing.
    func current() -> Bool { run == self.run && phase == .preparing && !Task.isCancelled }
    guard current() else { return }
    let wanted = MarkdownLibrary.fingerprint(script.markdown)
    let macID = script.metadata.id
    func entry(_ state: PadRemote.State?) -> PadRemote.Script? { state?.scripts.first { presentedID != nil ? $0.id == presentedID : $0.macID == macID } }
    func ready(_ state: PadRemote.State?) -> Bool {
      guard let state, let found = entry(state), presentedID != nil || found.fingerprint == wanted else { return false }
      return state.presenting == found.id && state.fingerprint == wanted && state.seekRevision != nil
    }
    if presentedID != nil, !ready(iPadState) { return finish("The iPad closed or changed the script", pausingIPad: false) }
    if let state = iPadState, !ready(state) {
      if let found = entry(state), found.fingerprint == wanted {
        link?.send(.present(found.id))
      } else {
        // The basis is the text last sent from this Mac: an iPad copy edited there is kept, and the
        // Mac's text arrives beside it as a new file; an untouched one is updated in place.
        link?.send(.sendScript(.init(
          macID: macID, title: script.metadata.title, markdown: script.markdown,
          basis: sentFingerprints[macID.uuidString], present: true)))
      }
    }
    status = "Waiting for the iPad to open the script…"
    let opened = await wait({ [self] in ready(iPadState) })
    guard current() else { return }
    guard opened else { return finish("The iPad did not open the script", pausingIPad: false) }
    if presentedID == nil { remember(wanted, for: macID) }
    requestedMacVoice = true
    link?.send(.voiceSource("Mac"))
    let switched = await wait({ [self] in iPadState?.voiceSource == "Mac" })
    guard current() else { return }
    guard switched else { return finish("The iPad did not switch to the Mac's voice", pausingIPad: false) }
    // The iPad may have changed or closed the script while it switched.
    guard let state = iPadState, ready(state), let found = entry(state) else {
      return finish("The iPad closed or changed the script", pausingIPad: false)
    }

    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    guard let defaults = UserDefaults(suiteName: suiteName) else { return finish("Could not start the relay", pausingIPad: false) }
    var relaySettings = PrompterSettings()
    relaySettings.mode = "Voice"
    // The iPad's word numbers count tokens in its resolved language; an older iPad sends none.
    relaySettings.speechLanguage = Self.language(of: state) ?? settings.speechLanguage
    relaySettings.speechLocales = settings.speechLocales
    relaySettings.speechEngine = settings.speechEngine
    relaySettings.usesTalkAndReadWords = settings.usesTalkAndReadWords
    relaySettings.allowsBackwardVoiceTracking = settings.allowsBackwardVoiceTracking
    relaySettings.audioDeviceUID = settings.audioDeviceUID
    relaySettings.inputGain = settings.inputGain
    if let device = AudioCapture.resolvedInput(settings.audioDeviceUID) {
      AudioChannel.load(device.uid, defaults: self.defaults).save(device.uid, defaults: defaults)
    }
    let session = SessionStore(defaults: defaults)
    session.present(record: script, settings: relaySettings)
    self.session = session
    meter = session.meter
    iPadScriptID = found.id
    fingerprint = wanted
    knownRevision = state.seekRevision ?? 0
    move(to: state.word - 1)
    session.$lastConfirmedTokenIndex.dropFirst().sink { [weak self] index in
      guard let self, !self.movingSession, let index else { return }
      guard self.phase == .live, self.iPadState?.editing != true,
        self.iPadState?.micOn != false else { return }
      // LinkPipe already coalesces unsent follows behind an in-flight write.
      self.link?.send(.follow(.init(confirmed: index, fingerprint: self.fingerprint, seekRevision: self.knownRevision)))
    }.store(in: &bag)
    // The failure shows once the session has settled, so its notice is already set.
    session.$state.dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.sessionStopped() }
    }.store(in: &bag)
    link?.setRelayActive(true)
    phase = .live
    iPadRunning = state.running
    if state.running { play() } else { status = "Ready. Press play on the iPad, then read" }
  }

  private var sentFingerprints: [String: String] {
    defaults.dictionary(forKey: Self.sentKey) as? [String: String] ?? [:]
  }

  private func remember(_ fingerprint: String, for macID: UUID) {
    var all = sentFingerprints
    all[macID.uuidString] = fingerprint
    defaults.set(all, forKey: Self.sentKey)
  }

  private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + confirmationTimeout
    while !condition() {
      if Task.isCancelled || ContinuousClock.now > deadline { return false }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return true
  }

  // MARK: - Running

  private func play() {
    guard let session else { return }
    wantsRunning = true
    status = "Following your voice"
    session.play(captureAudio: captureAudio)
  }

  private func pause() {
    wantsRunning = false
    session?.pause()
    status = "Paused with the iPad"
  }

  static func language(of state: PadRemote.State) -> String? {
    state.language.flatMap(ScriptLanguage.init(rawValue:))?.rawValue
  }

  private func move(to index: Int) {
    guard let session, index >= 0 else { return }
    movingSession = true
    session.seek(to: index)
    movingSession = false
  }

  /// The relay session stopped without the iPad asking: a microphone failure, or the script's end.
  private func sessionStopped() {
    guard phase == .live, wantsRunning, let session, !session.isActivelyRunning else { return }
    wantsRunning = false
    if session.reachedEnd {
      status = "Reached the end of the script"
    } else {
      finish(session.anchorNotice ?? "The Mac's microphone stopped", pausingIPad: true)
    }
  }

  // MARK: - Ending

  /// A refused start also returns an unserved voice source to the iPad.
  private func fail(_ message: String) { finish(message, pausingIPad: false) }

  private func finish(_ message: String, pausingIPad: Bool) {
    if iPadState != nil, requestedMacVoice || iPadState?.voiceSource == "Mac" { link?.send(.voiceSource("iPad")) }
    requestedMacVoice = false
    guard phase != .idle else { status = message; return }
    run += 1
    startTask?.cancel()
    startTask = nil
    // Only a script the iPad was following needs to be paused; before that it was not moving.
    if pausingIPad, phase == .live, iPadState != nil { link?.send(.pause) }
    phase = .idle
    wantsRunning = false
    micPaused = false
    resumeAfterMic = false
    bag.removeAll()
    session?.pause()
    session = nil
    meter = nil
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    link?.setRelayActive(false)
    isRelaying = false
    status = message
  }
}
#endif
