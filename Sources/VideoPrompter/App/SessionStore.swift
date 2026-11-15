import AVFoundation
#if canImport(AppKit)
import AppKit
#endif
import Combine
import Foundation
import PrompterCore
import Speech

@MainActor
final class SessionStore: ObservableObject {
  enum RunState: Equatable {
    case stopped, paused, running
    case uncertain(String)
  }

  @Published private(set) var activeRecord: ScriptRecord?
  @Published private(set) var document = PrompterDocument(markdown: "") {
    // `document.spokenTokens` flattens the whole script on every read; recognition reads it per
    // result and the positions per display frame, so it is flattened once per change here.
    didSet {
      spokenTokens = document.spokenTokens
      lastToken = Double(max(0, spokenTokens.count - 1))
    }
  }
  private var spokenTokens: [DocumentToken] = []
  private var lastToken = 0.0
  @Published private(set) var anchor: ReadingAnchor?
  /// The most recent word consumed by recognition or automatic playback.
  @Published private(set) var lastConfirmedTokenIndex: Int?
  @Published private(set) var tokenIndex = 0
  @Published private(set) var seekRevision = 0
  @Published private(set) var state: RunState = .stopped
  @Published private(set) var isPreparingVoice = false
  @Published private(set) var speechEngineStatus = ""
  #if os(macOS)
  let speechModels = SpeechModelPrefetch()
  #endif
  @Published private(set) var hasLiveRecognition = false
  @Published private(set) var countdownRemaining = 0
  @Published var startDelay = 3 {
    didSet {
      if ![0, 3, 5].contains(startDelay) { startDelay = 3 }
      defaults.set(startDelay, forKey: "automaticScrollStartDelay")
    }
  }
  /// True while a Mac's microphone drives this session (the iPad link's voice relay): this
  /// device never opens its own capture, and `followRemote` moves the position instead.
  var followsRemote = false {
    didSet {
      guard followsRemote != oldValue, isActivelyRunning, settings.mode == "Voice" else { return }
      if followsRemote {
        // Hand over from this device's microphone: stop its capture, keep reading from here.
        stopTasks()
        state = .running
      } else {
        // Back to this device's microphone, deliberately, while the script is running.
        startAudioMode()
      }
    }
  }
  private var countdownTask: Task<Void, Never>?
  var countdownTick: Duration = .seconds(1)
  var isCountingDown: Bool { countdownRemaining > 0 }
  func startReading() {
    hasStartedReading = true
    guard !isCountingDown, !isActivelyRunning, activeRecord != nil, !spokenTokens.isEmpty else { return }
    guard isManual, startDelay > 0 else { play(); return }
    countdownRemaining = startDelay
    countdownTask = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled else { return }
      while self.countdownRemaining > 0 {
        do { try await Task.sleep(for: self.countdownTick) } catch { return }
        guard !Task.isCancelled else { return }
        self.countdownRemaining -= 1
      }
      guard !Task.isCancelled else { return }
      self.countdownTask = nil
      self.play()
    }
  }
  private func cancelCountdown() {
    countdownTask?.cancel(); countdownTask = nil; countdownRemaining = 0
  }
  var readingStatus: String {
    if isCountingDown { return "Starting in \(countdownRemaining)…" }
    if reachedEnd { return "End of script" }
    if isPreparingVoice { return "Preparing" }
    if settings.mode == "Voice", !isActivelyRunning && anchorNotice?.lowercased().contains("microphone") == true { return "Needs microphone" }
    guard isActivelyRunning else { return "Paused" }
    if isManual { return "Scrolling" }
    if !listensToMicrophone { return "Microphone off" }
    if !hasLiveRecognition { return "Waiting for your voice" }
    if case .uncertain = state { return "Matching words" }
    return "Listening"
  }
  /// Short, explicit state for the persistent presenter label at every interface size.
  private(set) var hasStartedReading = false
  var visibleReadingState: String {
    if isCountingDown { return "Starts in \(countdownRemaining)" }
    if reachedEnd { return "End of script" }
    if isPreparingVoice { return "Preparing" }
    if hasStartedReading && readingStatus == "Needs microphone" { return "Needs microphone" }
    if !isActivelyRunning { return hasStartedReading ? "Paused" : "Ready" }
    if isManual { return "Scrolling" }
    if !listensToMicrophone { return "Microphone off" }
    if case .uncertain = state, hasLiveRecognition { return "Matching words" }
    return hasLiveRecognition ? "Following" : "Listening"
  }
  @Published private(set) var scriptLanguage: ScriptLanguage = .english
  private func languageMatcher() -> PhraseMatcher {
    var matcher = PhraseMatcher()
    matcher.language = scriptLanguage
    matcher.heardWords = wordList
    return matcher
  }
  var readingDetail: String? {
    if case .uncertain(let message) = state { return message }
    return nil
  }
  @Published private(set) var acceptedWords = 0
  @Published private(set) var anchorNotice: String?
  /// The microphone level lives in its own object: the presenter and the settings form observe
  /// the session, and publishing levels there re-rendered both, camera controls and
  /// all, for as long as Voice was listening. Only the meters observe `meter`.
  let meter = InputMeter()
  var audioPeakDBFS: Float { meter.peakDBFS }
  var isClipping: Bool { meter.isClipping }
  @Published private(set) var isTestingMicrophone = false
  @Published private(set) var microphoneTestNotice: String?
  @Published private(set) var settings = PrompterSettings()
  var activeScriptID: UUID? { activeRecord?.metadata.id }
  var activeToken: DocumentToken? {
    spokenTokens.indices.contains(tokenIndex) ? spokenTokens[tokenIndex] : nil
  }

  private var tracker = RecognitionTracker()
  private var wordList: HeardWordList?
  private var rewindVotes: [String: (position: Int, audioEnd: Double, received: TimeInterval)] = [:]
  private var pairedAudioFrontier = -Double.infinity
  private var rewindAudioFloor = -Double.infinity
  private var pairedTrackers: [String: RecognitionTracker] = [:]
  private var runTask: Task<Void, Never>?
  private var latestAudioEnd: TimeInterval = 0
  /// Monotonic seconds. Injectable so Manual's timeline is tested without sleeping.
  var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  /// Manual's timeline: `manualBase` is the fractional token position (token index plus progress
  /// through that token) at `manualStart`, and it advances at `speed / 60` tokens a second only
  /// while running. Every seek, edit, speed or mode change rebases it, so it never jumps.
  private var manualBase = 0.0
  private var manualStart: TimeInterval = 0
  /// Manual ran off the end. The next Play starts again from the beginning unless a seek came first.
  @Published private(set) var manualCompleted = false
  var reachedEnd: Bool { manualCompleted || (lastConfirmedTokenIndex == spokenTokens.count - 1 && !spokenTokens.isEmpty) }
  private var voiceEndTask: Task<Void, Never>?
  var voiceEndGrace: Duration = .seconds(3)
  var readingModeName: String { isManual ? "Automatic scroll" : "Voice follow" }
  var readingNextAction: String { isManual ? "Scrolls at \(Int(settings.speed)) wpm" : "Follows your voice" }
  private var speechGeneration: UInt64?
  private var minimumSpeechGeneration: UInt64 = 0
  private var pendingSpeechCandidate: (event: RecognitionEvent, tracker: RecognitionTracker)?
  private let speechProvider = SpeechProvider()
  private var contextTask: Task<Void, Never>?
  private var contextWindow: Int?
  private var audioCapture: AudioCapture?
  private var speechTask: Task<Void, Never>?
  private var microphoneTestTask: Task<Void, Never>?
  private var analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var lifecycleGeneration: UInt64 = 0
  private var providerStopTask: Task<Void, Never>?
  private var audioDeviceObserver: AudioInputDeviceObserver?

  func noteSubmittedAudioEnd(through end: TimeInterval) {
    latestAudioEnd = max(latestAudioEnd, end)
  }

  private struct SavedPosition: Codable {
    var anchor: ReadingAnchor?
    var index: Int
    var sourceOffset: Int?
    var confirmed: Int?
    var markdown: String
  }
  private let defaults: UserDefaults
  private let positionKey = "readingPositions"
  private var savedAnchors: [UUID: SavedPosition] = [:]
  private var positionSaveTask: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let savedDelay = defaults.object(forKey: "automaticScrollStartDelay") as? Int ?? 3
    startDelay = [0, 3, 5].contains(savedDelay) ? savedDelay : 3
    if let data = defaults.data(forKey: positionKey),
      let saved = try? JSONDecoder().decode([UUID: SavedPosition].self, from: data)
    { savedAnchors = saved }
  }

  private func savePositions() {
    positionSaveTask?.cancel()
    positionSaveTask = nil
    guard let data = try? JSONEncoder().encode(savedAnchors) else { return }
    defaults.set(data, forKey: positionKey)
  }

  /// While reading: at most once a second, and the anchor is only computed when the timer fires.
  private func rememberSoon() {
    guard positionSaveTask == nil else { return }
    positionSaveTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.positionSaveTask = nil
      self.rememberCurrent()
    }
  }

  private func rememberCurrent() {
    guard let record = activeRecord else { return }
    savedAnchors[record.metadata.id] = SavedPosition(
      anchor: anchor ?? ReadingAnchorRemapper.makeAnchor(
        scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
        globalTokenIndex: tokenIndex, guideFraction: settings.guideFraction),
      index: tokenIndex, sourceOffset: activeToken?.sourceRange.location, confirmed: lastConfirmedTokenIndex, markdown: record.markdown)
    savePositions()
  }

  func present(record: ScriptRecord, settings: PrompterSettings) {
    var settings = settings
    settings.sanitise()
    if activeRecord?.metadata.id != record.metadata.id {
      stopTasks()
      if activeRecord != nil {
        rememberCurrent()
      }
      self.settings = settings
      activeRecord = record
      hasStartedReading = false
      scriptLanguage = ScriptLanguage.resolve(settings.speechLanguage, text: record.markdown)
      document = PrompterDocument(markdown: record.markdown, language: scriptLanguage)
      let saved = savedAnchors[record.metadata.id]
      let oldDocument = saved.map { PrompterDocument(markdown: $0.markdown, language: ScriptLanguage.resolve(settings.speechLanguage, text: $0.markdown)) }
      // A number read as several words (2024 in Spanish) gives each word its offset; keep the saved word, not the last.
      let savedOrdinal: Int? = saved.flatMap { saved in
        guard let old = oldDocument?.spokenTokens, old.indices.contains(saved.index),
          old[saved.index].sourceRange.location == saved.sourceOffset else { return nil }
        return old[..<saved.index].reversed().prefix { $0.sourceRange.location == saved.sourceOffset }.count
      }
      func restoredIndex(_ tokens: [DocumentToken], _ offset: Int) -> Int? {
        guard let last = tokens.lastIndex(where: { $0.sourceRange.location <= offset }) else { return nil }
        guard tokens[last].sourceRange.location == offset, let savedOrdinal else { return last }
        let first = last - tokens[..<last].reversed().prefix { $0.sourceRange.location == offset }.count
        return min(first + savedOrdinal, last)
      }
      var remapped: Int? = saved?.sourceOffset.flatMap { restoredIndex(spokenTokens, $0) }
      if let saved, let oldDocument, let anchor = saved.anchor,
        anchor.revision != record.metadata.revision
      {
        let sourceAnchor = ReadingAnchorRemapper.makeAnchor(
          scriptID: anchor.scriptID, revision: anchor.revision, document: oldDocument,
          globalTokenIndex: saved.sourceOffset.flatMap { restoredIndex(oldDocument.spokenTokens, $0) } ?? saved.index, guideFraction: anchor.guideFraction) ?? anchor
        let result = ReadingAnchorRemapper.remap(sourceAnchor, from: oldDocument, to: document,
          newRevision: record.metadata.revision)
        remapped = result.anchor.flatMap { ReadingAnchorRemapper.globalIndex(of: $0, in: document) }
      }
      let start = min(max(0, remapped ?? saved?.index ?? 0), max(0, spokenTokens.count - 1))
      let confirmed = remapped == nil ? saved?.confirmed ?? start - 1 : start - 1
      lastConfirmedTokenIndex = start > 0 ? min(confirmed, start - 1) : nil
      tokenIndex = start
      rebaseManual(to: Double(start))
      anchor = ReadingAnchorRemapper.makeAnchor(
        scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
        globalTokenIndex: start, guideFraction: settings.guideFraction)
      tracker = RecognitionTracker(generation: 0, tokenIndex: start, matcher: languageMatcher())
      speechGeneration = nil
      minimumSpeechGeneration = 0
      pendingSpeechCandidate = nil
      acceptedWords = 0
      anchorNotice = nil
      state = .paused
      if saved?.anchor?.revision != record.metadata.revision { rememberCurrent() }
    } else {
      updateSettings(settings)
    }
  }

  func audioChannelDidChange() {
    if isActivelyRunning, settings.mode == "Voice" {
      stopTasks()
      restartModeTask()
      startAudioMode()
    }
  }

  func updateSettings(_ value: PrompterSettings) {
    var value = value
    value.sanitise()
    if value.mode != "Voice" || settings.audioDeviceUID != value.audioDeviceUID {
      stopMicrophoneTest()
    }
    let modeChanged = settings.speechEngine != value.speechEngine || settings.mode != value.mode || settings.audioDeviceUID != value.audioDeviceUID || (settings.speechLanguage != value.speechLanguage || settings.speechLocales != value.speechLocales)
    if modeChanged { anchorNotice = nil; cancelCountdown() }
    let speedChanged = settings.speed != value.speed
    // Manual first catches up to now at the old speed, so a new speed continues from here.
    let now = clock()
    if isManual, state == .running { syncManualFrontier(at: now) }
    let position = rawManualPosition(at: now)
    let modeSwitched = settings.mode != value.mode
    let languageChanged = settings.speechLanguage != value.speechLanguage
    settings = value
    #if os(macOS)
    speechModels.select(value.speechEngine)
    #endif
    if languageChanged {
      let old = document
      scriptLanguage = ScriptLanguage.resolve(settings.speechLanguage, text: old.markdown)
      document = PrompterDocument(markdown: old.markdown, previous: old, language: scriptLanguage)
      if let source = old.spokenTokens.indices.contains(tokenIndex) ? old.spokenTokens[tokenIndex].sourceRange.location : nil {
        tokenIndex = spokenTokens.lastIndex { $0.sourceRange.location <= source } ?? 0
      } else { tokenIndex = 0 }
      lastConfirmedTokenIndex = lastConfirmedTokenIndex.flatMap { confirmed in
        guard tokenIndex > 0, old.spokenTokens.indices.contains(confirmed) else { return nil }
        let offset = old.spokenTokens[confirmed].sourceRange.location
        return min(spokenTokens.lastIndex { $0.sourceRange.location <= offset } ?? 0, tokenIndex - 1)
      }
      if let record = activeRecord {
        anchor = ReadingAnchorRemapper.makeAnchor(scriptID: record.id, revision: record.metadata.revision,
          document: document, globalTokenIndex: tokenIndex, guideFraction: settings.guideFraction)
      }
      tracker = RecognitionTracker(generation: tracker.generation, tokenIndex: tokenIndex, matcher: languageMatcher())
      // Word numbers now count the new language's tokens: positions stamped before this are stale.
      seekRevision &+= 1
    }
    if modeSwitched || languageChanged {
      let fraction = modeSwitched ? 0 : position - floor(position)
      rebaseManual(to: Double(tokenIndex) + fraction, at: now)
    } else if speedChanged, isManual {
      manualBase = position
      manualStart = now
    }
    audioCapture?.setGain(Float(value.inputGain))
    if var current = anchor {
      current.guideFraction = value.guideFraction
      anchor = current
    }
    if isActivelyRunning, modeChanged {
      stopTasks()
      if isManual { state = .running }
      restartModeTask()
      if value.mode == "Voice" { startAudioMode() }
    } else if isActivelyRunning, speedChanged {
      restartModeTask()
    }
    if modeChanged, value.mode != "Voice" || selectedSpeechEngine == .dictation || scriptLanguage != .english {
      releaseSpeechModels()
    }
  }

  func applyEditedRecord(_ record: ScriptRecord) {
    guard record.metadata.id == activeRecord?.metadata.id else { return }
    if record.markdown == activeRecord?.markdown {
      activeRecord = record
      anchor?.revision = record.metadata.revision
      return
    }
    let wasRunning = state == .running
    pause()
    let old = document
    scriptLanguage = ScriptLanguage.resolve(settings.speechLanguage, text: record.markdown)
    let new = PrompterDocument(markdown: record.markdown, previous: old, language: scriptLanguage)
    if let anchor {
      let result = ReadingAnchorRemapper.remap(
        anchor, from: old, to: new, newRevision: record.metadata.revision)
      self.anchor = result.anchor
      tokenIndex = result.anchor.flatMap { ReadingAnchorRemapper.globalIndex(of: $0, in: new) } ?? 0
      anchorNotice =
        result.disposition == .currentPassageDeleted
        ? "The current passage was deleted. Position moved to the nearest remaining text." : nil
    } else {
      tokenIndex = 0
      anchor = ReadingAnchorRemapper.makeAnchor(
        scriptID: record.metadata.id, revision: record.metadata.revision, document: new,
        globalTokenIndex: 0, guideFraction: settings.guideFraction)
    }
    document = new
    tracker = RecognitionTracker(generation: tracker.generation, tokenIndex: tokenIndex, matcher: languageMatcher())
    activeRecord = record
    rebaseManual(to: Double(tokenIndex))
    lastConfirmedTokenIndex = lastConfirmedTokenIndex.flatMap { tokenIndex > 0 ? min($0, tokenIndex - 1) : nil }
    tracker.invalidate(startingAt: tokenIndex)
    if let speechGeneration { minimumSpeechGeneration = speechGeneration + 1 }
    speechGeneration = nil
    if wasRunning { state = .paused }
  }

  func play(captureAudio: Bool = true) {
    cancelCountdown()
    guard activeRecord != nil, !spokenTokens.isEmpty else { return }
    stopMicrophoneTest()
    anchorNotice = nil
    if reachedEnd { seek(to: 0) }
    if isManual {
      if manualCompleted {
        seek(to: 0)
      } else {
        // Already running (a second Play) keeps its progress; paused just starts the clock.
        let now = clock()
        if state == .running { syncManualFrontier(at: now) }
        rebaseManual(to: min(rawManualPosition(at: now), Double(spokenTokens.count)), at: now)
      }
    }
    state = .running
    restartModeTask()
    if captureAudio && settings.mode == "Voice" { startAudioMode() }
  }
  func pause() {
    hasStartedReading = true
    freezeManual()
    glide.hold()
    state = activeRecord == nil ? .stopped : .paused
    stopTasks()
    rememberCurrent()
  }
  func toggle() {
    if isCountingDown { pause(); return }
    if reachedEnd { seek(to: 0); startReading(); return }
    isActivelyRunning ? pause() : startReading()
  }
  func restart() {
    seek(to: 0)
    pause()
    if let id = activeRecord?.metadata.id { savedAnchors.removeValue(forKey: id); savePositions() }
  }
  func forgetPosition(for id: UUID) { savedAnchors.removeValue(forKey: id); savePositions() }
  /// A deleted script: its saved position goes, and if it is the one loaded the session stops,
  /// so presenting another script cannot save it again.
  func forgetScript(_ id: UUID) {
    if activeRecord?.metadata.id == id { stop() } else { forgetPosition(for: id) }
  }
  func stop() {
    if let id = activeRecord?.metadata.id { forgetPosition(for: id) }
    stopTasks()
    releaseSpeechModels()
    activeRecord = nil
    document = PrompterDocument(markdown: "")
    anchor = nil
    lastConfirmedTokenIndex = nil
    tokenIndex = 0
    rebaseManual(to: 0)
    anchorNotice = nil
    state = .stopped
  }

  func seek(to index: Int) {
    move(to: index, incrementSeekRevision: true)
  }
  private func move(to index: Int, incrementSeekRevision: Bool) {
    guard let record = activeRecord, !spokenTokens.isEmpty else { return }
    tokenIndex = min(max(0, index), spokenTokens.count - 1)
    if incrementSeekRevision {
      voiceEndTask?.cancel(); voiceEndTask = nil
      rebaseManual(to: Double(tokenIndex))
      pendingSpeechCandidate = nil
      rewindVotes.removeAll()
      for source in pairedTrackers.keys {
        pairedTrackers[source]?.reanchor(to: tokenIndex, minimumAudioStart: latestAudioEnd)
      }
      seekRevision &+= 1
      lastConfirmedTokenIndex = lastConfirmedTokenIndex.flatMap { tokenIndex > 0 ? min($0, tokenIndex - 1) : nil }
      if isActivelyRunning, settings.mode == "Voice" {
        tracker.reanchor(to: tokenIndex, minimumAudioStart: latestAudioEnd)
      } else {
        tracker.seek(to: tokenIndex)
      }
    }
    anchor = ReadingAnchorRemapper.makeAnchor(
      scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
      globalTokenIndex: tokenIndex, guideFraction: settings.guideFraction)
    if !incrementSeekRevision { tracker.seek(to: tokenIndex) }
    anchorNotice = nil
    refreshSpeechContext()
    rememberSoon()
    if incrementSeekRevision, (settings.speechEngine == "parakeet" || settings.speechEngine.hasPrefix("both")), audioCapture != nil {
      stopTasks()
      startAudioMode()
    }
  }
  func nextPassage() {
    seek(to: passageBoundary(after: tokenIndex) ?? spokenTokens.count - 1)
  }
  func previousPassage() { seek(to: passageBoundary(before: tokenIndex) ?? 0) }
  /// A scroll the reader made by hand. In Manual it pauses first, so the seek to the word at the
  /// guide holds until Play; Voice keeps running from the new word. Programmatic movement never
  /// comes through here.
  func seekFromUserScroll(to index: Int) {
    if isManual { pause() }
    seek(to: index)
  }

  var isManual: Bool { settings.mode == "Manual" }
  private var tokensPerSecond: Double { max(1, settings.speed) / 60 }

  /// Every position change that is not the reader's voice comes through here, so Voice's glide
  /// jumps with it.
  private func rebaseManual(to position: Double, at time: TimeInterval? = nil) {
    manualBase = position
    manualStart = time ?? clock()
    manualCompleted = false
    glide = VoiceGlide(at: position)
  }
  private var glide = VoiceGlide(at: 0)
  /// Voice's position for the presenter to paint on every display refresh: `tokenIndex`, followed
  /// smoothly (see `VoiceGlide`). Held while paused.
  func voicePosition(at time: TimeInterval? = nil) -> Double {
    guard isActivelyRunning else { glide.hold(); return glide.position }
    return min(glide.step(toward: tokenIndex, at: time ?? clock()), lastToken)
  }
  /// The unclamped Manual position: it passes the last token's index while that token is read.
  private func rawManualPosition(at time: TimeInterval) -> Double {
    guard isManual, state == .running else { return manualBase }
    return manualBase + max(0, time - manualStart) * tokensPerSecond
  }
  /// The exact fractional position the presenter paints, read from the monotonic timeline on every
  /// display refresh; it publishes nothing.
  func manualPosition(at time: TimeInterval? = nil) -> Double {
    min(rawManualPosition(at: time ?? clock()), lastToken)
  }
  /// Publishes the whole-token frontier (current word, words read) and finishes at the end. The
  /// timer task calls it a token at a time, also with no presenter open; the fraction is not stored.
  func syncManualFrontier(at time: TimeInterval? = nil) {
    guard isManual, state == .running, !spokenTokens.isEmpty else { return }
    let raw = rawManualPosition(at: time ?? clock())
    let count = spokenTokens.count
    guard raw < Double(count) else { return completeManual() }
    let index = Int(raw)
    guard index != tokenIndex else { return }
    lastConfirmedTokenIndex = index > 0 ? index - 1 : nil
    move(to: index, incrementSeekRevision: false)
  }
  /// The last token has been read: confirmed, no longer running, and the next Play starts over.
  private func completeManual() {
    let last = spokenTokens.count - 1
    lastConfirmedTokenIndex = last
    move(to: last, incrementSeekRevision: false)
    state = .paused
    stopTasks()
    manualBase = Double(last)
    manualCompleted = true
  }
  /// Pausing keeps the exact fraction, so Play carries on from the same place.
  private func freezeManual() {
    guard isManual, state == .running else { return }
    let now = clock()
    syncManualFrontier(at: now)
    guard state == .running else { return }
    manualBase = rawManualPosition(at: now)
    manualStart = now
  }

  func startMicrophoneTest(deviceUID: String?, gain: Double) {
    guard !isActivelyRunning || isManual else {
      microphoneTestNotice = "Pause the presenter before testing the microphone."
      return
    }
    stopMicrophoneTest()
    guard let device = resolveAudioInput(deviceUID)
    else {
      microphoneTestNotice = "Choose an available microphone to test."
      return
    }
    microphoneTestNotice = nil
    isTestingMicrophone = true
    let generation = lifecycleGeneration
    microphoneTestTask = Task { [weak self] in
      guard let self else { return }
      guard await AudioCapture.requestPermission() else {
        guard self.lifecycleGeneration == generation else { return }
        self.isTestingMicrophone = false
        self.microphoneTestTask = nil
        self.microphoneTestNotice = "Allow Video Prompter in System Settings > Privacy & Security > Microphone, then try again."
        return
      }
      guard !Task.isCancelled, self.lifecycleGeneration == generation, !self.isActivelyRunning || self.isManual else {
        return
      }
      do {
        guard let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw AudioCaptureError.conversionUnavailable }
        let capture = AudioCapture(device: device, outputFormat: format, gain: Float(gain), channel: AudioChannel.load(device.uid, defaults: defaults))
        self.audioCapture = capture
        let meterDelivery = self.meterDelivery(generation: generation)
        try capture.start(
          onBuffer: { _, time, _, peak, _ in
            meterDelivery.receive(peaks: [peak], callback: ProcessInfo.processInfo.systemUptime,
              capture: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
          },
          onStop: { [weak self] error in
            Task { @MainActor in
              guard let self, self.lifecycleGeneration == generation else { return }
              self.audioCapture = nil
              self.microphoneTestTask = nil
              self.isTestingMicrophone = false
              if let error {
                self.meter.reset()
                self.microphoneTestNotice = error == .deviceLost
                  ? "The selected microphone was disconnected."
                  : "Microphone test stopped: \(error.localizedDescription)"
              }
            }
          })
        guard !Task.isCancelled, self.lifecycleGeneration == generation else {
          capture.stop()
          return
        }
      } catch is CancellationError {} catch {
        guard self.lifecycleGeneration == generation else { return }
        self.audioCapture = nil
        self.microphoneTestTask = nil
        self.isTestingMicrophone = false
        self.microphoneTestNotice = "Could not test the microphone: \(error.localizedDescription)"
      }
    }
  }

  func stopMicrophoneTest() {
    guard microphoneTestTask != nil || isTestingMicrophone else { return }
    lifecycleGeneration &+= 1
    microphoneTestTask?.cancel()
    microphoneTestTask = nil
    audioCapture?.stop()
    audioCapture = nil
    isTestingMicrophone = false
    meter.reset()
  }

  func setMicrophoneTestGain(_ gain: Double) {
    // The test's capture or the reading session's: whichever is listening hears the drag at once.
    audioCapture?.setGain(Float(gain))
  }

  func microphoneDevicesDidChange(_ devices: [AudioInputDevice]) {
    guard let audioCapture else { return }
    guard !devices.contains(where: { $0.uid == audioCapture.selectedDevice.uid }) else { return }
    audioCapture.stop(reason: .deviceLost)
  }

  /// AudioMeterDelivery coalesces capture callbacks, preserving transients with fast attack.
  func publishMeter(peak: Float, clipping: Bool) {
    meter.show(peakDBFS: AudioCapture.decibels(fullScalePeak: peak), isClipping: clipping)
  }

  private func meterDelivery(generation: UInt64) -> AudioMeterDelivery {
    AudioMeterDelivery { [weak self] peaks in
      guard let self, self.lifecycleGeneration == generation else { return }
      let peak = peaks.first ?? 0
      self.publishMeter(peak: peak, clipping: peak >= 0.98)
    }
  }

  private static let logsLatency = ProcessInfo.processInfo.environment["VIDEOPROMPTER_AUDIO_LATENCY"] == "1"
  func acceptSpeechCandidate(_ candidate: SpeechCandidate) {
    let logsLatency = Self.logsLatency
    let started = logsLatency ? ProcessInfo.processInfo.systemUptime : 0
    defer {
      if logsLatency {
        NSLog("Voice match: audioBacklog=%.3f ms work=%.3f ms token=%d final=%d",
          (latestAudioEnd - candidate.range.end.seconds) * 1000,
          (ProcessInfo.processInfo.systemUptime - started) * 1000, tokenIndex, candidate.isFinal ? 1 : 0)
      }
    }
    guard isActivelyRunning, settings.mode == "Voice",
      candidate.generation >= minimumSpeechGeneration
    else { return }
    if candidate.publishesPosition { hasLiveRecognition = true }
    let tokens = spokenTokens
    if speechGeneration != candidate.generation {
      pairedTrackers.removeAll()
      rewindVotes.removeAll()
      pairedAudioFrontier = -Double.infinity
      rewindAudioFloor = -Double.infinity
      speechGeneration = candidate.generation
      tracker = RecognitionTracker(generation: candidate.generation, tokenIndex: tokenIndex, matcher: languageMatcher())
    }
    let event = RecognitionEvent(
      replacementID: candidate.replacementID, generation: candidate.generation, text: candidate.text,
      isFinal: candidate.isFinal, timestamp: candidate.range.end.seconds,
      localeIdentifier: candidate.locale.identifier, audioStart: candidate.range.start.seconds,
      audioEnd: candidate.range.end.seconds)
    if (settings.speechEngine == "parakeet" || settings.speechEngine.hasPrefix("both")) {
      guard event.audioEnd >= rewindAudioFloor else { return }
      // Keep the warm Apple history current too, without letting it move the reader.
      var own = pairedTrackers[candidate.source] ?? tracker
      let update = own.consume(event, script: tokens, allowsBackward: settings.allowsBackwardVoiceTracking)
      pairedTrackers[candidate.source] = own
      let old = lastConfirmedTokenIndex ?? (tokenIndex - 1)
      if update.status == .advanced, update.tokenIndex < old,
        event.audioEnd > pairedAudioFrontier, settings.allowsBackwardVoiceTracking {
        let now = clock()
        rewindVotes = rewindVotes.filter { now - $0.value.received <= 1 }
        rewindVotes[candidate.source] = (update.tokenIndex, event.audioEnd, now)
        let agreed = rewindVotes.contains { source, vote in
          source != candidate.source && vote.position == update.tokenIndex
            && abs(vote.audioEnd - event.audioEnd) <= 1
        }
        if candidate.publishesPosition, agreed || !candidate.requiresRewindAgreement {
          rewindVotes.removeAll()
          pairedAudioFrontier = event.audioEnd
          rewindAudioFloor = event.audioEnd
          advance(toConfirmed: update.tokenIndex, old: old)
        }
      } else if candidate.publishesPosition, update.status == .advanced, update.tokenIndex > old {
        rewindVotes.removeAll()
        pairedAudioFrontier = max(pairedAudioFrontier, event.audioEnd)
        advance(toConfirmed: update.tokenIndex, old: old)
      }
      return
    }
    if let pending = pendingSpeechCandidate,
      pending.event.generation == event.generation,
      pending.event.localeIdentifier != event.localeIdentifier,
      overlapping(pending.event, event)
    {
      // Replay the pair from before the first result, but only keep it if it does not go behind
      // what is already accepted; otherwise the weaker sibling would undo the stronger one.
      let old = lastConfirmedTokenIndex ?? (tokenIndex - 1)
      let current = tracker
      tracker = pending.tracker
      pendingSpeechCandidate = nil
      let update = tracker.consumeCandidates([pending.event, event], script: tokens)
      // The first final was already accepted. Its sibling may improve that result, but a held or
      // weaker replay must not replace the accepted tracker or turn the session uncertain.
      guard update.status == .advanced, update.tokenIndex >= old else {
        tracker = current
        return
      }
      applySpeechUpdate(update, old: old, trackerBeforeMatch: current)
      return
    }
    let old = lastConfirmedTokenIndex ?? (tokenIndex - 1)
    let trackerBeforeMatch = tracker
    let update = tracker.consume(event, script: tokens)
    pendingSpeechCandidate = candidate.isFinal ? (event, trackerBeforeMatch) : nil
    applySpeechUpdate(update, old: old, trackerBeforeMatch: trackerBeforeMatch)
  }

  private func overlapping(_ lhs: RecognitionEvent, _ rhs: RecognitionEvent) -> Bool {
    let overlap = max(0, min(lhs.audioEnd, rhs.audioEnd) - max(lhs.audioStart, rhs.audioStart))
    let union = max(lhs.audioEnd, rhs.audioEnd) - min(lhs.audioStart, rhs.audioStart)
    return union > 0 && overlap / union >= 0.72
  }

  private func applySpeechUpdate(
    _ update: RecognitionUpdate, old: Int? = nil, trackerBeforeMatch: RecognitionTracker? = nil
  ) {
    let old = old ?? (lastConfirmedTokenIndex ?? (tokenIndex - 1))
    switch update.status {
    case .advanced:
      guard settings.allowsBackwardVoiceTracking || update.tokenIndex >= old else {
        if let trackerBeforeMatch { tracker = trackerBeforeMatch }
        state = .uncertain("Following repeated earlier words is off")
        return
      }
      advance(toConfirmed: update.tokenIndex, old: old)
    case .held: state = .uncertain("Listening for a clearer phrase")
    case .staleGeneration, .duplicateRevision: break
    }
  }

  /// A word the Mac's tracker confirmed (0-based). Moves exactly as a recognised word does,
  /// except that backward tracking is not checked again: the Mac already applied its own rule.
  func followRemote(confirmed: Int) {
    guard followsRemote, isActivelyRunning, activeRecord != nil,
      confirmed >= 0, confirmed < spokenTokens.count
    else { return }
    advance(toConfirmed: confirmed, old: lastConfirmedTokenIndex ?? (tokenIndex - 1))
  }

  private func advance(toConfirmed confirmed: Int, old: Int) {
    state = .running
    lastConfirmedTokenIndex = confirmed
    tokenIndex = min(confirmed + 1, spokenTokens.count - 1)
    if confirmed > old { acceptedWords += confirmed - old }
    if let record = activeRecord {
      anchor = ReadingAnchorRemapper.makeAnchor(
        scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
        globalTokenIndex: tokenIndex, guideFraction: settings.guideFraction)
    }
    anchorNotice = nil
    refreshSpeechContext()
    if confirmed < spokenTokens.count - 1 {
      voiceEndTask?.cancel(); voiceEndTask = nil
    } else if confirmed > old {
      voiceEndTask?.cancel()
      voiceEndTask = Task { [weak self] in
        guard let self else { return }
        do { try await Task.sleep(for: self.voiceEndGrace) } catch { return }
        guard !Task.isCancelled, self.reachedEnd else { return }
        self.pause()
      }
    }
    rememberSoon()
  }

  private func restartModeTask() {
    runTask?.cancel()
    runTask = nil
    guard state == .running, isManual else { return }
    // Wakes once per token, at its boundary, and ends with pause, stop or completion. It only
    // publishes the whole-token frontier; the display link reads the fraction itself.
    runTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let delay = self?.secondsToNextManualToken() else { return }
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        self?.syncManualFrontier()
      }
    }
  }
  private func secondsToNextManualToken() -> TimeInterval {
    let position = rawManualPosition(at: clock())
    return max(0.01, (position.rounded(.down) + 1 - position) / tokensPerSecond + 0.002)
  }
  private func stopTasks() {
    contextTask?.cancel(); contextTask = nil; contextWindow = nil
    voiceEndTask?.cancel(); voiceEndTask = nil
    cancelCountdown()
    isPreparingVoice = false
    speechEngineStatus = ""
    hasLiveRecognition = false
    lifecycleGeneration &+= 1
    pendingSpeechCandidate = nil
    runTask?.cancel()
    runTask = nil
    latestAudioEnd = 0
    pairedTrackers.removeAll()
    rewindVotes.removeAll()
    pairedAudioFrontier = -Double.infinity
    rewindAudioFloor = -Double.infinity
    if (settings.speechEngine == "parakeet" || settings.speechEngine.hasPrefix("both")), let speechGeneration { minimumSpeechGeneration = speechGeneration + 1 }
    if (settings.speechEngine == "parakeet" || settings.speechEngine.hasPrefix("both")) { speechGeneration = nil }
    analyzerContinuation?.finish()
    analyzerContinuation = nil
    microphoneTestTask?.cancel()
    microphoneTestTask = nil
    audioCapture?.stop()
    audioCapture = nil
    speechTask?.cancel()
    speechTask = nil
    let previousStop = providerStopTask
    providerStopTask = Task {
      await previousStop?.value
      await speechProvider.stop()
    }
    meter.reset()
    isTestingMicrophone = false
    audioDeviceObserver = nil
  }
  /// Parakeet's models stay loaded across a seek, pause or resume (`ParakeetModelPool`); they are
  /// dropped here, after the pending stop has handed them back, once this session stops using them.
  private func releaseSpeechModels() {
    #if os(macOS)
    let previousStop = providerStopTask
    providerStopTask = Task {
      await previousStop?.value
      await ParakeetModelPool.shared.releaseAll()
    }
    #endif
  }
  private func passageBoundary(after index: Int) -> Int? {
    let tokens = spokenTokens
    guard tokens.indices.contains(index) else { return nil }
    let block = tokens[index].blockID
    return tokens.indices.first {
      $0 > index && tokens[$0].blockID != block
    }
  }
  private func passageBoundary(before index: Int) -> Int? {
    let tokens = spokenTokens
    guard tokens.indices.contains(index) else { return nil }
    let block = tokens[index].blockID
    guard let last = tokens.indices.last(where: {
      $0 < index && tokens[$0].blockID != block
    }) else { return nil }
    let target = tokens[last].blockID
    return tokens.indices.first {
      $0 <= last && tokens[$0].blockID == target
    }
  }
  var isActivelyRunning: Bool {
    if case .paused = state { return false }
    if case .stopped = state { return false }
    return true
  }

  var resolveAudioInput: (String?) -> AudioInputDevice? = AudioCapture.resolvedInput

  /// The presenter's Mic button. Off, Voice follow never opens the microphone; the reading stays paused
  /// until Start reading, and starts without listening. Automatic scroll never listens either way.
  @Published private(set) var listensToMicrophone = true
  func setListensToMicrophone(_ on: Bool) {
    guard on != listensToMicrophone else { return }
    listensToMicrophone = on
    if !on, settings.mode == "Voice", isActivelyRunning { pause() }
  }

  private func startAudioMode() {
    guard listensToMicrophone else { return }
    // Also while a start is still preparing: a second one would race it for the recogniser.
    // The single gate for every path (play, a settings change): a relayed session never listens.
    guard !followsRemote, audioCapture == nil, speechTask == nil else { return }
    reloadWordList()
    if audioDeviceObserver == nil {
      audioDeviceObserver = AudioCapture.inputDeviceObserver { [weak self] in
        guard let self else { return }
        self.microphoneDevicesDidChange(AudioCapture.inputDevices())
      }
    }
    guard let device = resolveAudioInput(settings.audioDeviceUID)
    else {
      failAudio("Choose a microphone in Settings > Microphone, then press Start reading.")
      return
    }
    isPreparingVoice = true
    let generation = lifecycleGeneration
    let previousStop = providerStopTask
    speechTask = Task { [weak self] in
      await previousStop?.value
      guard !Task.isCancelled, let self,
        self.lifecycleGeneration == generation, self.isActivelyRunning else { return }
      guard await AudioCapture.requestPermission() else {
        guard self.lifecycleGeneration == generation, !Task.isCancelled else { return }
        self.failAudio("Allow Video Prompter in System Settings > Privacy & Security > Microphone, then press Start reading.")
        return
      }
      guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else { return }
      do {
        self.state = .uncertain("Preparing \(self.scriptLanguage.rawValue) speech recognition. Missing speech files will download before listening.")
        let selectedEngine = self.selectedSpeechEngine
        let locales = try await self.speechLocales()
        let format = try await self.speechProvider.prepare(
          locales: locales,
          contextualStrings: self.speechContext(at: self.tokenIndex),
          engine: selectedEngine, onPreparation: { [weak self] message in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.speechEngineStatus = message
          })
        guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else { return }
        let capture = AudioCapture(
          device: device, outputFormat: format, gain: Float(self.settings.inputGain), channel: AudioChannel.load(device.uid, defaults: self.defaults))
        self.audioCapture = capture
        let meterDelivery = self.meterDelivery(generation: generation)
        // About 430 ms of 256-frame buffers, so a short stall never drops spoken words.
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(80))
        self.analyzerContinuation = pair.continuation
        let counter = AudioFrameCounter(sampleRate: format.sampleRate)
        try capture.start(
          onBuffer: { [weak self] buffer, time, _, peak, _ in
            // Feed recognition immediately; progress bookkeeping and coalesced metering hop to main.
            let start = counter.next(buffer.frameLength)
            pair.continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
            meterDelivery.receive(peaks: [peak], callback: ProcessInfo.processInfo.systemUptime,
              capture: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
            let submittedEnd = start.seconds + Double(buffer.frameLength) / format.sampleRate
            Task { @MainActor in
              guard let self, self.lifecycleGeneration == generation else { return }
              self.noteSubmittedAudioEnd(through: submittedEnd)
            }
          },
          onStop: { [weak self] error in
            pair.continuation.finish()
            Task { @MainActor in
              guard let self else { return }
              guard self.lifecycleGeneration == generation else { return }
              self.audioCapture = nil
              if let error {
                let message = error == .deviceLost
                  ? "The selected microphone was disconnected. Tracking paused."
                  : "Voice following stopped. \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                self.failAudio(message)
              }
            }
          })
        guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else {
          capture.stop()
          return
        }
        self.isPreparingVoice = false
        self.refreshSpeechContext()
        self.state = .uncertain("Microphone ready. Read the script to begin following.")
        try await self.speechProvider.start(input: pair.stream) { [weak self] candidate in
          guard let self, self.lifecycleGeneration == generation else { return }
          self.acceptSpeechCandidate(candidate)
        }
      } catch is CancellationError {} catch {
        guard self.lifecycleGeneration == generation else { return }
        self.failAudio("Voice following stopped. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
      }
    }
  }

  private func failAudio(_ message: String) {
    pause()
    anchorNotice = message
  }

  private func refreshSpeechContext() {
    guard audioCapture != nil, !isPreparingVoice, settings.mode == "Voice", !followsRemote else { return }
    let window = tokenIndex / 24 * 24
    guard contextWindow != window else { return }
    contextWindow = window
    let strings = speechContext(at: window)
    let generation = lifecycleGeneration
    let previous = contextTask
    contextTask = Task { [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled, self.lifecycleGeneration == generation else { return }
      do { try await self.speechProvider.updateContext(strings) }
      catch {
        // Context is a recognition hint; failure must not stop the microphone or lose words.
        if Self.logsLatency {
          NSLog("Voice context update failed: %@", error.localizedDescription)
        }
      }
    }
  }

  /// Talk & Read's pronunciation list (Mac only, nil on the iPad), reloaded at each Start reading so a
  /// word just added there counts at once. See `HeardWordList`.
  private func reloadWordList() {
    wordList = settings.usesTalkAndReadWords ? HeardWordList.talkAndReadURL.flatMap { HeardWordList(contentsOf: $0) } : nil
  }
  /// Apple's contextual strings: the script's known names first, then the rolling script context.
  private func speechContext(at index: Int) -> [String] {
    let rolling = SpeechProvider.upcomingContext(spokenTokens, at: index)
    return wordList?.addingContext(to: rolling, script: spokenTokens, at: index) ?? rolling
  }

  var selectedSpeechEngine: SpeechProvider.Engine {
    // The iPad keeps using Apple locally; the Mac's Parakeet position is relayed unchanged.
    #if os(macOS)
    settings.speechEngine == "apple" ? .dictation : .parakeet
    #else
    .dictation
    #endif
  }

  private func speechLocales() async throws -> [Locale] {
    let supported = await DictationTranscriber.supportedLocales
    guard let locale = scriptLanguage.preferredLocale(supported: supported, explicit: settings.speechLocales[scriptLanguage.rawValue]) else {
      throw SpeechProvider.Error.analysisFailed("\(scriptLanguage.rawValue) is unavailable on this Mac. Choose another Script language in Settings > Reading.")
    }
    return [locale]
  }

}

/// The microphone readout the Settings meters draw. It publishes only what changed, so a reset
/// that finds it already silent wakes nothing.
@MainActor final class InputMeter: ObservableObject {
  @Published private(set) var peakDBFS: Float = -.infinity
  @Published private(set) var isClipping = false
  @Published private(set) var channelPeaks: [Float] = []
  private(set) var lastSampleAt: TimeInterval?
  private(set) var lastAudibleSampleAt: TimeInterval?
  func isFresh(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    lastSampleAt.map { now - $0 < 1.5 } ?? false
  }
  func show(channelPeaks: [Float]) {
    if self.channelPeaks != channelPeaks { self.channelPeaks = channelPeaks }
    let peak = channelPeaks.max() ?? 0
    show(peakDBFS: AudioCapture.decibels(fullScalePeak: peak), isClipping: peak >= 0.99)
  }
  func show(peakDBFS: Float, isClipping: Bool) {
    lastSampleAt = ProcessInfo.processInfo.systemUptime
    if peakDBFS > -60 { lastAudibleSampleAt = lastSampleAt }
    if self.peakDBFS != peakDBFS { self.peakDBFS = peakDBFS }
    if self.isClipping != isClipping { self.isClipping = isClipping }
  }
  func reset() { show(peakDBFS: -.infinity, isClipping: false); if !channelPeaks.isEmpty { channelPeaks = [] }; lastSampleAt = nil; lastAudibleSampleAt = nil }
}

private final class AudioFrameCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: Int64 = 0
  private let scale: CMTimeScale
  init(sampleRate: Double) { scale = CMTimeScale(sampleRate) }
  func next(_ count: AVAudioFrameCount) -> CMTime {
    lock.lock()
    defer { lock.unlock() }
    let time = CMTime(value: frame, timescale: scale)
    frame += Int64(count)
    return time
  }
}
