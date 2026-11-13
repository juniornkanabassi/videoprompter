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
  private var iPadRunning = false
  /// Set while the relay itself moves the session, so its own seek is not sent back.
  private var movingSession = false
  private var pendingFollow: Int?
  private var flushScheduled = false

  init(link: PadRelayLink? = nil, suiteName: String = "VideoPrompter.padRelay", defaults: UserDefaults = .standard) {
    self.link = link
    self.suiteName = suiteName
    self.defaults = defaults
  }

  /// Sends the script to the iPad if it lacks it, then listens and follows. Asynchronous: the
  /// status says how far it got.
  func start(script: ScriptRecord, settings: PrompterSettings) {
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
    startTask = Task { [weak self] in await self?.begin(script: script, settings: settings, run: thisRun) }
  }

  /// Pauses the iPad, then lets go. The voice source is left for the user to change.
  func stop() { finish("Stopped", pausingIPad: true) }

  /// Fed with every state the iPad sends, and nil when the link drops.
  func iPadStateChanged(_ state: PadRemote.State?) {
    iPadState = state
    if state?.editing == true, phase == .preparing {
      return finish("Finish editing on the iPad first", pausingIPad: false)
    }
    if state == nil, phase == .preparing { return finish("The link to the iPad dropped", pausingIPad: false) }
    guard phase == .live else { return }
    guard let state else { return finish("The link to the iPad dropped", pausingIPad: false) }
    guard state.presenting == iPadScriptID, state.fingerprint == fingerprint, state.seekRevision != nil else {
      return finish("The iPad opened another script or closed this one", pausingIPad: true)
    }
    guard state.voiceSource == "Mac" else { return finish("The iPad is listening with its own microphone", pausingIPad: false) }
    if state.editing == true || state.micOn == false {
      pendingFollow = nil
      pause()
      iPadRunning = false
      return
    }
    // Only a seek on the iPad moves the relay; its word changing as it follows us does not. The iPad
    // checks each follow against its current revision and states arrive in order, so any change
    // (the counter wraps) is a seek to adopt, and a follow stamped earlier is already stale.
    if let revision = state.seekRevision, revision != knownRevision {
      knownRevision = revision
      pendingFollow = nil
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

  private func begin(script: ScriptRecord, settings: PrompterSettings, run: Int) async {
    // A stopped or replaced start does nothing at all, and above all sends nothing.
    func current() -> Bool { run == self.run && phase == .preparing && !Task.isCancelled }
    guard current() else { return }
    let wanted = MarkdownLibrary.fingerprint(script.markdown)
    let macID = script.metadata.id
    func entry(_ state: PadRemote.State?) -> PadRemote.Script? { state?.scripts.first { $0.macID == macID } }
    func ready(_ state: PadRemote.State?) -> Bool {
      guard let state, let found = entry(state), found.fingerprint == wanted else { return false }
      return state.presenting == found.id && state.fingerprint == wanted && state.seekRevision != nil
    }
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
    remember(wanted, for: macID)
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
    relaySettings.speechLanguage = settings.speechLanguage
    relaySettings.allowsBackwardVoiceTracking = settings.allowsBackwardVoiceTracking
    relaySettings.audioDeviceUID = settings.audioDeviceUID
    relaySettings.inputGain = settings.inputGain
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
      self.pendingFollow = index
      self.scheduleFlush()
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

  /// At most one follow per turn of the main actor, always the newest word.
  private func scheduleFlush() {
    guard !flushScheduled else { return }
    flushScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.flushScheduled = false
      guard self.phase == .live, self.iPadState?.editing != true, self.iPadState?.micOn != false, let confirmed = self.pendingFollow else { return }
      self.pendingFollow = nil
      self.link?.send(.follow(.init(confirmed: confirmed, fingerprint: self.fingerprint, seekRevision: self.knownRevision)))
    }
  }

  // MARK: - Ending

  /// Refused before anything started: only the status says why.
  private func fail(_ message: String) { status = message }

  private func finish(_ message: String, pausingIPad: Bool) {
    guard phase != .idle else { return }
    run += 1
    startTask?.cancel()
    startTask = nil
    // Only a script the iPad was following needs to be paused; before that it was not moving.
    if pausingIPad, phase == .live, iPadState != nil { link?.send(.pause) }
    phase = .idle
    wantsRunning = false
    pendingFollow = nil
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
