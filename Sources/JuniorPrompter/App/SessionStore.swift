import AVFoundation
import AppKit
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
  @Published private(set) var activeDuration: TimeInterval = 0
  @Published private(set) var anchorNotice: String?
  @Published private(set) var audioLevel: Float = 0
  @Published private(set) var audioPeakDBFS: Float = -.infinity
  @Published private(set) var isClipping = false
  @Published private(set) var isTestingMicrophone = false
  @Published private(set) var microphoneTestNotice: String?
  var estimatedWPM: Int { activeDuration > 0 ? Int((Double(acceptedWords) / activeDuration * 60).rounded()) : 0 }
  var sessionMilestone: Int { ((acceptedWords / 100) + 1) * 100 }
  @Published private(set) var settings = PrompterSettings()
  @Published private(set) var obsURL: URL?
  @Published private(set) var obsStatus = "Stopped"

  var activeScriptID: UUID? { activeRecord?.metadata.id }
  var activeToken: DocumentToken? {
    document.spokenTokens.indices.contains(tokenIndex) ? document.spokenTokens[tokenIndex] : nil
  }

  private var tracker = RecognitionTracker()
  private var runTask: Task<Void, Never>?
  private var durationTask: Task<Void, Never>?
  private var candidateBuffer: [SpeechCandidate] = []
  private var bufferedCandidateSeekRevision = 0
  private var candidateFlush: Task<Void, Never>?
  private var latestAudioEnd: TimeInterval = 0
  private var lastSoundAdvance: TimeInterval = 0
  private var speechGeneration: UInt64?
  private var minimumSpeechGeneration: UInt64 = 0
  private let speechProvider = SpeechProvider()
  private var audioCapture: AudioCapture?
  private var speechTask: Task<Void, Never>?
  private var microphoneTestTask: Task<Void, Never>?
  private var analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var lifecycleGeneration: UInt64 = 0
  private var providerStopTask: Task<Void, Never>?
  private var audioDeviceObserver: AudioInputDeviceObserver?
  private let obsServer = OBSServer()

  func present(record: ScriptRecord, settings: PrompterSettings) {
    if activeRecord?.metadata.id != record.metadata.id {
      stopTasks()
      self.settings = settings
      activeRecord = record
      document = PrompterDocument(markdown: record.markdown)
      lastConfirmedTokenIndex = nil
      tokenIndex = 0
      anchor = ReadingAnchorRemapper.makeAnchor(
        scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
        globalTokenIndex: 0, guideFraction: settings.guideFraction)
      tracker = RecognitionTracker(generation: 0, tokenIndex: 0)
      speechGeneration = nil
      minimumSpeechGeneration = 0
      acceptedWords = 0
      activeDuration = 0
      state = .paused
      refreshOBSSnapshot()
    } else {
      updateSettings(settings)
    }
  }

  func updateSettings(_ value: PrompterSettings) {
    let modeChanged = settings.mode != value.mode || settings.audioDeviceUID != value.audioDeviceUID || settings.speechLanguage != value.speechLanguage
    let speedChanged = settings.speed != value.speed
    settings = value
    refreshOBSSnapshot()
    audioCapture?.setGain(Float(value.inputGain))
    if var current = anchor {
      current.guideFraction = value.guideFraction
      anchor = current
    }
    if isActivelyRunning, modeChanged {
      stopTasks()
      if value.mode == "Timed" { state = .running }
      startDurationClock()
      restartModeTask()
      if value.mode == "Voice" || value.mode == "Sound" { startAudioMode() }
    } else if isActivelyRunning, speedChanged {
      restartModeTask()
    }
  }

  func applyEditedRecord(_ record: ScriptRecord) {
    guard record.metadata.id == activeRecord?.metadata.id else { return }
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
    lastConfirmedTokenIndex = lastConfirmedTokenIndex.flatMap { tokenIndex > 0 ? min($0, tokenIndex - 1) : nil }
    tracker.invalidate(startingAt: tokenIndex)
    if let speechGeneration { minimumSpeechGeneration = speechGeneration + 1 }
    speechGeneration = nil
    if wasRunning { state = .paused }
    refreshOBSSnapshot()
  }

  func play(captureAudio: Bool = true) {
    guard activeRecord != nil, !document.spokenTokens.isEmpty else { return }
    stopMicrophoneTest()
    anchorNotice = nil
    state = .running
    startDurationClock()
    restartModeTask()
    if captureAudio && (settings.mode == "Voice" || settings.mode == "Sound") { startAudioMode() }
    refreshOBSSnapshot()
  }
  func pause() {
    state = activeRecord == nil ? .stopped : .paused
    stopTasks()
    refreshOBSSnapshot()
  }
  func toggle() { isActivelyRunning ? pause() : play() }
  func restart() {
    seek(to: 0)
    pause()
  }
  func stop() {
    stopTasks()
    activeRecord = nil
    document = PrompterDocument(markdown: "")
    anchor = nil
    lastConfirmedTokenIndex = nil
    tokenIndex = 0
    state = .stopped
    refreshOBSSnapshot()
  }

  func seek(to index: Int) {
    move(to: index, incrementSeekRevision: true)
  }
  private func move(to index: Int, incrementSeekRevision: Bool) {
    guard let record = activeRecord, !document.spokenTokens.isEmpty else { return }
    tokenIndex = min(max(0, index), document.spokenTokens.count - 1)
    if incrementSeekRevision {
      seekRevision &+= 1
      lastConfirmedTokenIndex = lastConfirmedTokenIndex.flatMap { tokenIndex > 0 ? min($0, tokenIndex - 1) : nil }
      let queued = candidateBuffer.map { value in
        RecognitionEvent(
          replacementID: value.replacementID, generation: value.generation, text: value.text,
          isFinal: value.isFinal, timestamp: value.range.end.seconds,
          localeIdentifier: value.locale.identifier, audioStart: value.range.start.seconds,
          audioEnd: value.range.end.seconds)
      }
      candidateBuffer.removeAll()
      candidateFlush?.cancel()
      candidateFlush = nil
      if isActivelyRunning, settings.mode == "Voice" {
        tracker.reanchor(to: tokenIndex, minimumAudioStart: latestAudioEnd, baselining: queued)
      } else {
        tracker.seek(to: tokenIndex)
      }
    }
    anchor = ReadingAnchorRemapper.makeAnchor(
      scriptID: record.metadata.id, revision: record.metadata.revision, document: document,
      globalTokenIndex: tokenIndex, guideFraction: settings.guideFraction)
    if !incrementSeekRevision { tracker.seek(to: tokenIndex) }
    anchorNotice = nil
    refreshOBSSnapshot()
  }
  func nextPassage() {
    seek(to: passageBoundary(after: tokenIndex) ?? document.spokenTokens.count - 1)
  }
  func previousPassage() { seek(to: passageBoundary(before: tokenIndex) ?? 0) }
  func advanceOneToken() {
    lastConfirmedTokenIndex = tokenIndex
    move(to: min(tokenIndex + 1, max(0, document.spokenTokens.count - 1)), incrementSeekRevision: false)
  }

  func acceptSoundLevel(
    _ level: Float, at time: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    guard isActivelyRunning, settings.mode == "Sound", level >= Float(settings.soundThreshold),
      time - lastSoundAdvance >= 60 / max(1, settings.speed)
    else { return }
    lastSoundAdvance = time
    advanceOneToken()
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
              self.audioPeakDBFS = AudioCapture.decibels(fullScalePeak: peak)
              self.isClipping = clipping
            }
          },
          onStop: { [weak self] error in
            Task { @MainActor in
              guard let self, self.lifecycleGeneration == generation else { return }
              self.audioCapture = nil
              self.microphoneTestTask = nil
              self.isTestingMicrophone = false
              if let error {
                self.audioPeakDBFS = -.infinity
                self.isClipping = false
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
    audioLevel = 0
    audioPeakDBFS = -.infinity
    isClipping = false
  }

  func setMicrophoneTestGain(_ gain: Double) {
    guard isTestingMicrophone else { return }
    audioCapture?.setGain(Float(gain))
  }

  func microphoneDevicesDidChange(_ devices: [AudioInputDevice]) {
    guard let audioCapture else { return }
    guard !devices.contains(where: { $0.uid == audioCapture.selectedDevice.uid }) else { return }
    audioCapture.stop(reason: .deviceLost)
  }

  func acceptSpeechCandidate(_ candidate: SpeechCandidate) {
    guard isActivelyRunning, settings.mode == "Voice",
      candidate.generation >= minimumSpeechGeneration
    else { return }
    if speechGeneration != candidate.generation {
      speechGeneration = candidate.generation
      tracker = RecognitionTracker(generation: candidate.generation, tokenIndex: tokenIndex)
    }
    bufferedCandidateSeekRevision = seekRevision
    candidateBuffer.removeAll {
      $0.locale.identifier == candidate.locale.identifier
        && $0.replacementID == candidate.replacementID
    }
    candidateBuffer.append(candidate)
    guard candidateFlush == nil else { return }
    candidateFlush = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(25))
      guard !Task.isCancelled else { return }
      self?.flushCandidates()
    }
  }

  private func flushCandidates() {
    let seekRevision = bufferedCandidateSeekRevision
    let candidates = candidateBuffer
    candidateBuffer.removeAll()
    candidateFlush = nil
    guard seekRevision == self.seekRevision, !candidates.isEmpty else { return }
    let events = candidates.map { value in
      RecognitionEvent(
        replacementID: value.replacementID, generation: value.generation, text: value.text,
        isFinal: value.isFinal, timestamp: value.range.end.seconds,
        localeIdentifier: value.locale.identifier, audioStart: value.range.start.seconds,
        audioEnd: value.range.end.seconds)
    }
    let old = lastConfirmedTokenIndex ?? (tokenIndex - 1)
    let trackerBeforeMatch = tracker
    let update = tracker.consumeCandidates(events, script: document.spokenTokens)
    switch update.status {
    case .advanced:
      guard settings.allowsBackwardVoiceTracking || update.tokenIndex >= old else {
        tracker = trackerBeforeMatch
        state = .uncertain("Backward voice tracking is off")
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
      refreshOBSSnapshot()
    case .held: state = .uncertain("Listening for a clearer phrase")
    case .staleGeneration, .duplicateRevision: break
    }
  }

  func startOBS() async throws {
    let value = try await obsServer.start()
    obsURL = value
    obsStatus = obsServer.status
    refreshOBSSnapshot()
  }

  func stopOBS() {
    obsServer.stop()
    obsURL = obsServer.url
    obsStatus = obsServer.status
  }

  private func refreshOBSSnapshot() {
    guard obsURL != nil else { return }
    var offset = 0
    let runs = document.blocks.compactMap { block -> OBSSnapshot.Run? in
      guard !block.spokenTokens.isEmpty else { return nil }
      defer { offset += block.spokenTokens.count }
      let text = block.rawMarkdown
        .replacingOccurrences(of: #"(?<!\\)\[[^\]\n]+\](?!\s*\()"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\[([^\]\n]+)\]\([^\)\n]+\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"^(?:\s*#{1,6}\s|\s*(?:[-+*]|\d+[.)])\s)"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "`", with: "")
      let ns = text as NSString
      var cursor = 0
      let ranges = block.spokenTokens.map { token -> OBSSnapshot.TokenRange in
        let found = ns.range(of: token.text, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: cursor, length: ns.length - cursor))
        if found.location != NSNotFound { cursor = found.upperBound; return .init(location: found.location, length: found.length) }
        return .init(location: 0, length: 0)
      }
      return .init(
        text: text, spokenTokenStart: offset, spokenTokenCount: block.spokenTokens.count, tokenRanges: ranges)
    }
    obsServer.update(snapshot: .init(
      runs: runs, activeTokenIndex: tokenIndex, fontSize: settings.fontSize,
      textOpacity: settings.textOpacity, backgroundOpacity: settings.backgroundOpacity,
      mirrorX: settings.horizontalMirror, mirrorY: settings.verticalMirror,
      rotation: settings.rotation, guideFraction: settings.guideFraction, fontName: settings.fontName))
  }

  private func restartModeTask() {
    runTask?.cancel()
    runTask = nil
    guard state == .running, settings.mode == "Timed" else { return }
    let interval = max(0.1, 60 / max(1, settings.speed))
    runTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        self?.advanceOneToken()
      }
    }
  }
  private func startDurationClock() {
    durationTask?.cancel()
    durationTask = Task { [weak self] in
      var previous = ProcessInfo.processInfo.systemUptime
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if self?.isActivelyRunning == true { self?.activeDuration += now - previous }
        previous = now
      }
    }
  }
  private func stopTasks() {
    lifecycleGeneration &+= 1
    runTask?.cancel()
    runTask = nil
    durationTask?.cancel()
    durationTask = nil
    candidateFlush?.cancel()
    candidateFlush = nil
    candidateBuffer.removeAll()
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
    audioLevel = 0
    audioPeakDBFS = -.infinity
    isClipping = false
    isTestingMicrophone = false
    audioDeviceObserver = nil
  }
  private func passageBoundary(after index: Int) -> Int? {
    guard document.spokenTokens.indices.contains(index) else { return nil }
    let block = document.spokenTokens[index].blockID
    return document.spokenTokens.indices.first {
      $0 > index && document.spokenTokens[$0].blockID != block
    }
  }
  private func passageBoundary(before index: Int) -> Int? {
    guard document.spokenTokens.indices.contains(index) else { return nil }
    let block = document.spokenTokens[index].blockID
    guard let last = document.spokenTokens.indices.last(where: {
      $0 < index && document.spokenTokens[$0].blockID != block
    }) else { return nil }
    let target = document.spokenTokens[last].blockID
    return document.spokenTokens.indices.first {
      $0 <= last && document.spokenTokens[$0].blockID == target
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
      failAudio("Choose an audio input in the inspector")
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
        let mode = self.settings.mode
        let format: AVAudioFormat
        if mode == "Voice" {
          self.state = .uncertain("Preparing on-device English and French speech models")
          format = try await self.speechProvider.prepare(
            locales: try await self.speechLocales(),
            contextualStrings: SpeechProvider.contextualPhrases(from: self.document.markdown), engine: .dictation)
          guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else { return }
          self.state = .running
        } else {
          guard
            let value = AVAudioFormat(
              commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
          else { throw AudioCaptureError.conversionUnavailable }
          format = value
        }
        let capture = AudioCapture(
          device: device, outputFormat: format, gain: Float(self.settings.inputGain))
        self.audioCapture = capture
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(20))
        if mode == "Voice" { self.analyzerContinuation = pair.continuation }
        let counter = AudioFrameCounter(sampleRate: format.sampleRate)
        try capture.start(
          onBuffer: { [weak self] buffer, _, level, peak, clipping in
            if mode == "Voice" {
              let start = counter.next(buffer.frameLength)
              pair.continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
              let end = start.seconds + Double(buffer.frameLength) / format.sampleRate
              Task { @MainActor in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.latestAudioEnd = max(self.latestAudioEnd, end)
              }
            }
            Task { @MainActor in
              guard let self, self.lifecycleGeneration == generation else { return }
              self.audioLevel = level
              self.audioPeakDBFS = AudioCapture.decibels(fullScalePeak: peak)
              self.isClipping = clipping
              if mode == "Sound" { self.acceptSoundLevel(level) }
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
                  : "Audio tracking stopped: \(error)"
                self.failAudio(message)
              }
            }
          })
        if mode == "Voice" {
          guard !Task.isCancelled, self.lifecycleGeneration == generation, self.isActivelyRunning else {
            capture.stop()
            return
          }
          try await self.speechProvider.start(input: pair.stream) { [weak self] candidate in
            Task { @MainActor in
              guard let self, self.lifecycleGeneration == generation else { return }
              self.acceptSpeechCandidate(candidate)
            }
          }
        }
      } catch is CancellationError {} catch {
        guard self.lifecycleGeneration == generation else { return }
        self.failAudio("Audio tracking stopped: \(error)")
      }
    }
  }

  private func failAudio(_ message: String) {
    pause()
    anchorNotice = message
    refreshOBSSnapshot()
  }

  private func speechLocales() async throws -> [Locale] {
    if settings.speechLanguage == "Automatic" {
      let language = NLLanguageRecognizer.dominantLanguage(for: document.markdown)
      guard let language else { throw SpeechProvider.Error.unavailable }
      guard let supported = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: language.rawValue))
      else { throw SpeechProvider.Error.unavailable }
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
