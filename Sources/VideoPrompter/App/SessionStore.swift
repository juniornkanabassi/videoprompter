import AVFoundation
#if canImport(AppKit)
import AppKit
#endif
import Combine
import Foundation
import PrompterCore
import Speech
import NaturalLanguage

@MainActor
final class SessionStore: ObservableObject {
  enum RunState: Equatable {
    case stopped, paused, running
    case uncertain(String)
  }

  @Published private(set) var activeRecord: ScriptRecord?
  @Published private(set) var document = PrompterDocument(markdown: "")
  @Published private(set) var anchor: ReadingAnchor?
  /// The most recent word consumed by recognition or automatic playback.
  @Published private(set) var lastConfirmedTokenIndex: Int?
  @Published private(set) var tokenIndex = 0
  @Published private(set) var seekRevision = 0
  @Published private(set) var state: RunState = .stopped
  @Published private(set) var acceptedWords = 0
  @Published private(set) var anchorNotice: String?
  /// The microphone level lives in its own object: the presenter and the settings form observe
  /// the session, and a level published 20 times a second re-rendered both, camera controls and
  /// all, for as long as Voice was listening. Only the meters observe `meter`.
  let meter = InputMeter()
  var audioPeakDBFS: Float { meter.peakDBFS }
  var isClipping: Bool { meter.isClipping }
  @Published private(set) var isTestingMicrophone = false
  @Published private(set) var microphoneTestNotice: String?
  @Published private(set) var settings = PrompterSettings()
  var activeScriptID: UUID? { activeRecord?.metadata.id }
  var activeToken: DocumentToken? {
    document.spokenTokens.indices.contains(tokenIndex) ? document.spokenTokens[tokenIndex] : nil
  }

  private var tracker = RecognitionTracker()
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
  private(set) var manualCompleted = false
  private var speechGeneration: UInt64?
  private var minimumSpeechGeneration: UInt64 = 0
  private var pendingSpeechCandidate: (event: RecognitionEvent, tracker: RecognitionTracker)?
  private let speechProvider = SpeechProvider()
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
    var confirmed: Int?
    var markdown: String
  }
  private let defaults: UserDefaults
  private let positionKey = "readingPositions"
  private var savedAnchors: [UUID: SavedPosition] = [:]
  private var positionSaveTask: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
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
      index: tokenIndex, confirmed: lastConfirmedTokenIndex, markdown: record.markdown)
    savePositions()
  }

  func present(record: ScriptRecord, settings: PrompterSettings) {
    if activeRecord?.metadata.id != record.metadata.id {
      stopTasks()
      if activeRecord != nil {
        rememberCurrent()
      }
      self.settings = settings
      activeRecord = record
      document = PrompterDocument(markdown: record.markdown)
      let saved = savedAnchors[record.metadata.id]
      let oldDocument = saved.map { PrompterDocument(markdown: $0.markdown) }
      var remapped: Int?
      if let saved, let oldDocument, let anchor = saved.anchor,
        anchor.revision != record.metadata.revision
      {
        let sourceAnchor = ReadingAnchorRemapper.makeAnchor(
          scriptID: anchor.scriptID, revision: anchor.revision, document: oldDocument,
          globalTokenIndex: saved.index, guideFraction: anchor.guideFraction) ?? anchor
        let result = ReadingAnchorRemapper.remap(sourceAnchor, from: oldDocument, to: document,
          newRevision: record.metadata.revision)
        remapped = result.anchor.flatMap { ReadingAnchorRemapper.globalIndex(of: $0, in: document) }
      }
      let start = min(max(0, remapped ?? saved?.index ?? 0), max(0, document.spokenTokens.count - 1))
      let confirmed = remapped == nil ? saved?.confirmed ?? start - 1 : start - 1
      lastConfirmedTokenIndex = start > 0 ? min(confirmed, start - 1) : nil
      tokenIndex = start
      rebaseManual(to: Double(start))
      anchor = ReadingAnchorRemapper.makeAnchor(
        scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
        globalTokenIndex: start, guideFraction: settings.guideFraction)
      tracker = RecognitionTracker(generation: 0, tokenIndex: start)
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

  func updateSettings(_ value: PrompterSettings) {
    if value.mode != "Voice" || settings.audioDeviceUID != value.audioDeviceUID {
      stopMicrophoneTest()
    }
    let modeChanged = settings.mode != value.mode || settings.audioDeviceUID != value.audioDeviceUID || settings.speechLanguage != value.speechLanguage
    if modeChanged { anchorNotice = nil }
    let speedChanged = settings.speed != value.speed
    // Manual first catches up to now at the old speed, so a new speed continues from here.
    let now = clock()
    if isManual, state == .running { syncManualFrontier(at: now) }
    let position = rawManualPosition(at: now)
    let modeSwitched = settings.mode != value.mode
    settings = value
    if modeSwitched {
      rebaseManual(to: Double(tokenIndex), at: now)
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
    let new = PrompterDocument(markdown: record.markdown, previous: old)
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
    activeRecord = record
    rebaseManual(to: Double(tokenIndex))
    lastConfirmedTokenIndex = lastConfirmedTokenIndex.flatMap { tokenIndex > 0 ? min($0, tokenIndex - 1) : nil }
    tracker.invalidate(startingAt: tokenIndex)
    if let speechGeneration { minimumSpeechGeneration = speechGeneration + 1 }
    speechGeneration = nil
    if wasRunning { state = .paused }
  }

  func play(captureAudio: Bool = true) {
    guard activeRecord != nil, !document.spokenTokens.isEmpty else { return }
    stopMicrophoneTest()
    anchorNotice = nil
    if isManual {
      if manualCompleted {
        seek(to: 0)
      } else {
        // Already running (a second Play) keeps its progress; paused just starts the clock.
        let now = clock()
        if state == .running { syncManualFrontier(at: now) }
        rebaseManual(to: min(rawManualPosition(at: now), Double(document.spokenTokens.count)), at: now)
      }
    }
    state = .running
    restartModeTask()
    if captureAudio && settings.mode == "Voice" { startAudioMode() }
  }
  func pause() {
    freezeManual()
    state = activeRecord == nil ? .stopped : .paused
    stopTasks()
    rememberCurrent()
  }
  func toggle() { isActivelyRunning ? pause() : play() }
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
    guard let record = activeRecord, !document.spokenTokens.isEmpty else { return }
    tokenIndex = min(max(0, index), document.spokenTokens.count - 1)
    if incrementSeekRevision {
      rebaseManual(to: Double(tokenIndex))
      pendingSpeechCandidate = nil
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
    rememberSoon()
  }
  func nextPassage() {
    seek(to: passageBoundary(after: tokenIndex) ?? document.spokenTokens.count - 1)
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

  private func rebaseManual(to position: Double, at time: TimeInterval? = nil) {
    manualBase = position
    manualStart = time ?? clock()
    manualCompleted = false
  }
  /// The unclamped Manual position: it passes the last token's index while that token is read.
  private func rawManualPosition(at time: TimeInterval) -> Double {
    guard isManual, state == .running else { return manualBase }
    return manualBase + max(0, time - manualStart) * tokensPerSecond
  }
  /// The exact fractional position the presenter paints, read from the monotonic timeline on every
  /// display refresh; it publishes nothing.
  func manualPosition(at time: TimeInterval? = nil) -> Double {
    min(rawManualPosition(at: time ?? clock()), Double(max(0, document.spokenTokens.count - 1)))
  }
  /// Publishes the whole-token frontier (current word, words read) and finishes at the end. The
  /// timer task calls it a token at a time, also with no presenter open; the fraction is not stored.
  func syncManualFrontier(at time: TimeInterval? = nil) {
    guard isManual, state == .running, !document.spokenTokens.isEmpty else { return }
    let raw = rawManualPosition(at: time ?? clock())
    let count = document.spokenTokens.count
    guard raw < Double(count) else { return completeManual() }
    let index = Int(raw)
    guard index != tokenIndex else { return }
    lastConfirmedTokenIndex = index > 0 ? index - 1 : nil
    move(to: index, incrementSeekRevision: false)
  }
  /// The last token has been read: confirmed, no longer running, and the next Play starts over.
  private func completeManual() {
    let last = document.spokenTokens.count - 1
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
    guard !isActivelyRunning else {
      microphoneTestNotice = "Pause the presenter before testing the microphone."
      return
    }
    stopMicrophoneTest()
    guard let deviceUID,
      let device = AudioCapture.inputDevices().first(where: { $0.uid == deviceUID })
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
        self.microphoneTestNotice = "Microphone permission is required."
        return
      }
      guard !Task.isCancelled, self.lifecycleGeneration == generation, !self.isActivelyRunning else {
        return
      }
      do {
        guard let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw AudioCaptureError.conversionUnavailable }
        let capture = AudioCapture(device: device, outputFormat: format, gain: Float(gain))
        self.audioCapture = capture
        try capture.start(
          onBuffer: { [weak self] _, _, _, peak, clipping in
            Task { @MainActor in
              guard let self, self.lifecycleGeneration == generation else { return }
              self.publishMeter(peak: peak, clipping: clipping)
            }
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
                  : "Microphone test stopped: \(error)"
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
        self.microphoneTestNotice = "Could not test the microphone: \(error)"
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
    pendingPeak = 0
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

  /// The meter is a Settings-window readout; the eye cannot use more than 20 Hz and every
  /// publish re-renders every view observing the session. Buffers arrive at ~47 Hz.
  private var lastMeterPublish: TimeInterval = 0
  private var pendingPeak: Float = 0
  func publishMeter(peak: Float, clipping: Bool) {
    pendingPeak = max(pendingPeak, peak)
    let now = ProcessInfo.processInfo.systemUptime
    guard clipping != isClipping || now - lastMeterPublish >= 0.05 else { return }
    lastMeterPublish = now
    // The loudest buffer since the last publish, so throttling cannot hide a transient peak.
    meter.show(peakDBFS: AudioCapture.decibels(fullScalePeak: pendingPeak), isClipping: clipping)
    pendingPeak = 0
  }

  func acceptSpeechCandidate(_ candidate: SpeechCandidate) {
    guard isActivelyRunning, settings.mode == "Voice",
      candidate.generation >= minimumSpeechGeneration
    else { return }
    let tokens = document.spokenTokens
    if speechGeneration != candidate.generation {
      speechGeneration = candidate.generation
      tracker = RecognitionTracker(generation: candidate.generation, tokenIndex: tokenIndex)
    }
    let event = RecognitionEvent(
      replacementID: candidate.replacementID, generation: candidate.generation, text: candidate.text,
      isFinal: candidate.isFinal, timestamp: candidate.range.end.seconds,
      localeIdentifier: candidate.locale.identifier, audioStart: candidate.range.start.seconds,
      audioEnd: candidate.range.end.seconds)
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
      state = .running
      lastConfirmedTokenIndex = update.tokenIndex
      tokenIndex = min(update.tokenIndex + 1, document.spokenTokens.count - 1)
      if update.tokenIndex > old { acceptedWords += update.tokenIndex - old }
      if let record = activeRecord {
        anchor = ReadingAnchorRemapper.makeAnchor(
          scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
          globalTokenIndex: tokenIndex, guideFraction: settings.guideFraction)
      }
      anchorNotice = nil
      rememberSoon()
    case .held: state = .uncertain("Listening for a clearer phrase")
    case .staleGeneration, .duplicateRevision: break
    }
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
    lifecycleGeneration &+= 1
    pendingSpeechCandidate = nil
    runTask?.cancel()
    runTask = nil
    latestAudioEnd = 0
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
    pendingPeak = 0
    meter.reset()
    isTestingMicrophone = false
    audioDeviceObserver = nil
  }
  private func passageBoundary(after index: Int) -> Int? {
    let tokens = document.spokenTokens
    guard tokens.indices.contains(index) else { return nil }
    let block = tokens[index].blockID
    return tokens.indices.first {
      $0 > index && tokens[$0].blockID != block
    }
  }
  private func passageBoundary(before index: Int) -> Int? {
    let tokens = document.spokenTokens
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

  private func startAudioMode() {
    guard audioCapture == nil else { return }
    if audioDeviceObserver == nil {
      audioDeviceObserver = AudioCapture.inputDeviceObserver { [weak self] in
        guard let self else { return }
        self.microphoneDevicesDidChange(AudioCapture.inputDevices())
      }
    }
    guard let uid = settings.audioDeviceUID,
      let device = AudioCapture.inputDevices().first(where: { $0.uid == uid })
    else {
      failAudio("Choose a microphone in Presenter settings")
      return
    }
    let generation = lifecycleGeneration
    let previousStop = providerStopTask
    speechTask = Task { [weak self] in
      await previousStop?.value
      guard !Task.isCancelled, let self,
        self.lifecycleGeneration == generation, self.isActivelyRunning else { return }
      guard await AudioCapture.requestPermission() else {
        guard self.lifecycleGeneration == generation, !Task.isCancelled else { return }
        self.failAudio("Microphone permission is required")
        return
      }
      guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else { return }
      do {
        self.state = .uncertain("Preparing on-device speech recognition")
        let format = try await self.speechProvider.prepare(
          locales: try await self.speechLocales(),
          contextualStrings: SpeechProvider.contextualPhrases(from: self.document.markdown), engine: .dictation)
        guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else { return }
        self.state = .running
        let capture = AudioCapture(
          device: device, outputFormat: format, gain: Float(self.settings.inputGain))
        self.audioCapture = capture
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(20))
        self.analyzerContinuation = pair.continuation
        let counter = AudioFrameCounter(sampleRate: format.sampleRate)
        try capture.start(
          onBuffer: { [weak self] buffer, _, _, peak, clipping in
            // One main-actor hop per buffer, not two: at ~47 Hz the second hop was pure overhead.
            let start = counter.next(buffer.frameLength)
            pair.continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
            let submittedEnd = start.seconds + Double(buffer.frameLength) / format.sampleRate
            Task { @MainActor in
              guard let self, self.lifecycleGeneration == generation else { return }
              self.noteSubmittedAudioEnd(through: submittedEnd)
              self.publishMeter(peak: peak, clipping: clipping)
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
                  : "Voice following stopped: \(error)"
                self.failAudio(message)
              }
            }
          })
        guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else {
          capture.stop()
          return
        }
        try await self.speechProvider.start(input: pair.stream) { [weak self] candidate in
          guard let self, self.lifecycleGeneration == generation else { return }
          self.acceptSpeechCandidate(candidate)
        }
      } catch is CancellationError {} catch {
        guard self.lifecycleGeneration == generation else { return }
        self.failAudio("Voice following stopped: \(error)")
      }
    }
  }

  private func failAudio(_ message: String) {
    pause()
    anchorNotice = message
  }

  private func speechLocales() async throws -> [Locale] {
    if settings.speechLanguage == "Automatic" {
      let language = NLLanguageRecognizer.dominantLanguage(for: document.markdown)
      guard let language else { throw SpeechProvider.Error.unavailable }
      // With the user's region first: asked for plain "en", the recogniser answers en_GB, en_AU,
      // en_NZ or en_SG from one call to the next, while "en-GB" is always en_GB.
      let regional = Locale.current.region.map { Locale(identifier: "\(language.rawValue)-\($0.identifier)") }
      var supported: Locale?
      if let regional { supported = await DictationTranscriber.supportedLocale(equivalentTo: regional) }
      // Then the main variant, and only then whatever the recogniser offers for the bare language.
      let main = ["en": "en-GB", "fr": "fr-FR", "es": "es-ES", "pt": "pt-PT", "de": "de-DE"][language.rawValue]
      for fallback in [main, language.rawValue].compactMap({ $0 }) where supported == nil {
        supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: fallback))
      }
      guard let supported else { throw SpeechProvider.Error.unavailable }
      return [supported]
    }
    switch settings.speechLanguage {
    case "English": return [Locale(identifier: "en-GB")]
    case "French": return [Locale(identifier: "fr-FR")]
    case "Mixed": return [Locale(identifier: "en-GB"), Locale(identifier: "fr-FR")]
    default: return [Locale(identifier: settings.speechLanguage)]
    }
  }
}

/// The microphone readout the Settings meters draw. It publishes only what changed, so a reset
/// that finds it already silent wakes nothing.
@MainActor final class InputMeter: ObservableObject {
  @Published private(set) var peakDBFS: Float = -.infinity
  @Published private(set) var isClipping = false
  func show(peakDBFS: Float, isClipping: Bool) {
    if self.peakDBFS != peakDBFS { self.peakDBFS = peakDBFS }
    if self.isClipping != isClipping { self.isClipping = isClipping }
  }
  func reset() { show(peakDBFS: -.infinity, isClipping: false) }
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
