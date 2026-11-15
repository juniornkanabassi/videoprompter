import AVFoundation
import Foundation
import Speech
import Synchronization
import PrompterCore

public struct SpeechCandidate: Sendable, Hashable {
  public let replacementID: String
  public let generation: UInt64
  public let locale: Locale
  public let text: String
  public let range: CMTimeRange
  public let isFinal: Bool
  /// The recogniser's own result text, whose runs carry each word's audio time range. Nothing in the
  /// app reads it; replays measure per-word latency from it.
  public var transcript = AttributedString()
  public var source = "apple"
  /// Warm backup results maintain matcher history without publishing a position.
  public var publishesPosition = true
  public var requiresRewindAgreement = true
}
/// The recognisers of one reading that can still hear the reader. A rewind needs a second live one
/// to agree; once the others fail, the last one may follow a re-read alone.
final class LiveRecognisers: Sendable {
  static let apple = -1
  private let live: Mutex<Set<Int>>
  init(_ live: Set<Int>) { self.live = Mutex(live) }
  /// True when nothing is left to follow the reader.
  func fail(_ id: Int) -> Bool { live.withLock { $0.remove(id); return $0.isEmpty } }
  func needsAgreement(_ id: Int) -> Bool { live.withLock { $0.contains { $0 != id } } }
}
public actor SpeechProvider {
  public enum Engine: Sendable, Equatable { case transcription, dictation, parakeet, both, unified, bothUnified, eou }
  public enum Error: Swift.Error, Sendable, LocalizedError {
    case unavailable, notPrepared, reservationLimit
    case analysisFailed(String)
    public var errorDescription: String? {
      switch self {
      case .unavailable: "Speech recognition is not available for this language on this device."
      case .reservationLimit: "This device has reached its speech language limit. Choose another Script language in Settings > Reading and try again."
      case .notPrepared: "Speech recognition was not ready."
      case .analysisFailed(let reason): "Speech recognition failed. \(reason)"
      }
    }
  }
  #if os(macOS)
  private var pairStreams: [ParakeetSpeechStream] = []
  private var backupActive = false
  private var pairStatus: @MainActor @Sendable (String) -> Void = { _ in }
  private var parakeet: ParakeetSpeechStream?
  private var pairedProviders: [SpeechProvider] = []
  #endif
  private var analyzer: SpeechAnalyzer?
  private var modules: [SpeechTranscriber] = []
  private var dictationModules: [DictationTranscriber] = []
  private var engine: Engine = .transcription
  private var locales: [Locale] = []
  private var generation: UInt64 = 0
  private var resultTasks: [Task<Void, Swift.Error>] = []
  private var operation: UInt64 = 0
  private let localStreamFailureAfter: TimeInterval?
  public init() { localStreamFailureAfter = nil }
  // Deterministic replay fault; production always uses the public initializer.
  init(localStreamFailureAfter: TimeInterval) { self.localStreamFailureAfter = localStreamFailureAfter }
  static func needsAppleBackup(english: Bool, eouReady: Bool, unifiedReady: Bool, streamFailed: Bool = false) -> Bool {
    !english || !eouReady || !unifiedReady || streamFailed
  }
  public static func contextualPhrases(from script: String) -> [String] {
    let words = PrompterDocument(markdown: script).spokenTokens.prefix(48).map(\.text)
    var phrases: [String] = []
    for phrase in words + zip(words, words.dropFirst()).map({ "\($0) \($1)" }) {
      if !phrases.contains(phrase) { phrases.append(phrase) }
    }
    return phrases
  }
  public static func upcomingContext(_ tokens: [DocumentToken], at index: Int) -> [String] {
    contextualPhrases(from: tokens.dropFirst(max(0, index)).prefix(48).map(\.text).joined(separator: " "))
  }

  public func updateContext(_ strings: [String]) async throws {
    #if os(macOS)
    if engine == .parakeet || engine == .both || engine == .bothUnified { try await pairedProviders.first?.updateContext(strings); return }
    #endif
    guard engine == .dictation, let analyzer else { return }
    let context = AnalysisContext()
    context.contextualStrings[.general] = strings
    try await analyzer.setContext(context)
  }
  public func prepare(
    locales requested: [Locale] = [.init(identifier: "en-GB"), .init(identifier: "fr-FR")],
    naturalFormat: AVAudioFormat? = nil, contextualStrings: [String] = [], engine: Engine = .transcription,
    modelDirectory: URL? = nil, onPreparation: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) async throws -> AVAudioFormat {
    // A first download can take half a minute, and a pause, a resume or a new language can
    // start another preparation or a stop meanwhile; only the latest one may set the analyzer.
    operation &+= 1
    let op = operation
    if let analyzer { await analyzer.cancelAndFinishNow() }
    try checkCurrent(op)
    resultTasks.forEach { $0.cancel() }
    resultTasks = []
    analyzer = nil
    #if os(macOS)
    for stream in pairStreams { await stream.stop() }
    pairStreams = []
    for provider in pairedProviders { await provider.stop() }
    pairedProviders = []
    await parakeet?.stop()
    try checkCurrent(op)
    parakeet = nil
    if engine == .parakeet {
      let apple = SpeechProvider()
      // Apple is the backup: missing dictation files offline must not stop working local models.
      var appleFormat: AVAudioFormat?, appleError: Swift.Error?
      do {
        appleFormat = try await apple.prepare(locales: requested, naturalFormat: naturalFormat,
          contextualStrings: contextualStrings, engine: .dictation)
        pairedProviders = [apple]
      } catch is CancellationError { throw CancellationError() }
      catch { appleError = error; await apple.stop() }
      try checkCurrent(op)
      pairStatus = onPreparation
      pairStreams = []
      if requested.allSatisfy({ $0.language.languageCode?.identifier == "en" }) {
        for unified in [false, true] {
          let root = modelDirectory.map { $0.appendingPathComponent(unified ? UnifiedModel.folder : "parakeet-eou-160ms") }
            ?? ParakeetModel.root(unified: unified)
          let files = unified ? UnifiedModel.files : ParakeetModel.files
          let ready = await Task.detached(priority: .utility) { ParakeetModel.ready(at: root, files: files) }.value
          try checkCurrent(op)
          if ready {
            let stream = ParakeetSpeechStream()
            do {
              try await stream.prepare(directory: root, unified: unified, allowDownload: false, onPreparation: { _ in })
              try checkCurrent(op)
              pairStreams.append(stream)
            } catch is CancellationError { throw CancellationError() }
            catch { await stream.stop() }
          }
        }
      }
      if let appleError, pairStreams.isEmpty { throw appleError }
      backupActive = Self.needsAppleBackup(english: requested.allSatisfy { $0.language.languageCode?.identifier == "en" },
        eouReady: pairStreams.count == 2, unifiedReady: pairStreams.count == 2)
      await onPreparation(backupActive && appleFormat != nil ? "Apple backup active · Parakeet available when ready" : "Parakeet pair ready · on-device")
      try checkCurrent(op)
      self.engine = engine
      return appleFormat ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }
    if (engine == .both || engine == .bothUnified) {
      let apple = SpeechProvider(), local = SpeechProvider()
      pairedProviders = [apple, local]
      do {
        let format = try await apple.prepare(locales: requested, naturalFormat: naturalFormat,
          contextualStrings: contextualStrings, engine: .dictation)
        try checkCurrent(op)
        _ = try await local.prepare(locales: requested, engine: engine == .bothUnified ? .unified : .eou,
          modelDirectory: modelDirectory, onPreparation: onPreparation)
        try checkCurrent(op)
        self.engine = engine
        return format
      } catch {
        await apple.stop(); await local.stop()
        throw error
      }
    }
    if (engine == .eou || engine == .unified) {
      guard requested.allSatisfy({ $0.language.languageCode?.identifier == "en" }) else { throw Error.unavailable }
      let stream = ParakeetSpeechStream()
      try await stream.prepare(directory: modelDirectory, unified: engine == .unified, onPreparation: onPreparation)
      try checkCurrent(op)
      self.engine = engine
      parakeet = stream
      // AnalyzerInput accepts integer PCM on macOS 27; FluidAudio converts it to Float32.
      return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }
    #else
    if (engine == .eou || engine == .unified) || (engine == .both || engine == .bothUnified) { throw Error.unavailable }
    #endif
    var newModules: [SpeechTranscriber] = []
    var newDictationModules: [DictationTranscriber] = []
    var newLocales: [Locale] = []
    for requestedLocale in requested {
      let supported: Locale? = switch engine {
      case .parakeet, .both, .unified, .bothUnified, .eou: nil
      case .transcription:
        await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
      case .dictation:
        await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
      }
      try checkCurrent(op)
      guard let supported
      else { throw Error.unavailable }
      switch engine {
      case .parakeet, .both, .unified, .bothUnified, .eou: break
      case .transcription:
        newModules.append(
          SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription))
      case .dictation:
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.attributeOptions.insert(.audioTimeRange)
        newDictationModules.append(DictationTranscriber(locale: supported, preset: preset))
      }
      newLocales.append(supported)
    }
    let activeModules: [any SpeechModule]
    switch engine {
    case .parakeet, .both, .unified, .bothUnified, .eou: activeModules = []
    case .transcription: activeModules = newModules
    case .dictation: activeModules = newDictationModules
    }
    // The old analyzer has finished. Never release a locale used by this preparation.
    for reserved in await AssetInventory.reservedLocales where !newLocales.contains(reserved) {
      try checkCurrent(op)
      _ = await AssetInventory.release(reservedLocale: reserved)
    }
    for locale in newLocales {
      try checkCurrent(op)
      let reserved = await AssetInventory.reservedLocales
      try checkCurrent(op)
      if !reserved.contains(locale), reserved.count >= AssetInventory.maximumReservedLocales {
        throw Error.reservationLimit
      }
      do { try await AssetInventory.reserve(locale: locale) }
      catch {
        try checkCurrent(op)
        if await AssetInventory.reservedLocales.count >= AssetInventory.maximumReservedLocales {
          throw Error.reservationLimit
        }
        throw error
      }
      try checkCurrent(op)
    }
    // The speech files first: until a locale's files are on the device, there is no audio format
    // for it, and an iPad that has never used British English or French dictation has neither.
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: activeModules) {
      try checkCurrent(op)
      try await installation.downloadAndInstall()
    }
    try checkCurrent(op)
    guard
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: activeModules, considering: naturalFormat)
    else { throw Error.unavailable }
    let a = SpeechAnalyzer(modules: activeModules)
    if engine == .dictation {
      let context = AnalysisContext()
      context.contextualStrings[.general] = Array(contextualStrings.prefix(100))
      try await a.setContext(context)
    }
    try await a.prepareToAnalyze(in: format)
    do { try checkCurrent(op) } catch {
      await a.cancelAndFinishNow()
      throw error
    }
    self.engine = engine
    modules = newModules
    dictationModules = newDictationModules
    locales = newLocales
    analyzer = a
    return format
  }
  /// Throws when a newer preparation or a stop came in while this one waited.
  private func checkCurrent(_ op: UInt64) throws {
    if op != operation || Task.isCancelled { throw CancellationError() }
  }
  public func start<S: AsyncSequence>(
    input: S, generation externalGeneration: UInt64? = nil,
    onCandidate: @escaping @MainActor @Sendable (SpeechCandidate) -> Void
  ) async throws where S: Sendable, S.Element == AnalyzerInput {
    #if os(macOS)
    if engine == .parakeet {
      // Apple is absent when its dictation could not prepare; the local models then follow alone.
      let apple = pairedProviders.first
      guard apple != nil || !pairStreams.isEmpty else { throw Error.notPrepared }
      generation = externalGeneration ?? (generation &+ 1)
      let g = generation
      let streams = pairStreams
      let failureAfter = localStreamFailureAfter
      let live = LiveRecognisers(Set(streams.indices).union(apple == nil ? [] : [LiveRecognisers.apple]))
      let appleInput = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(1024))
      // About 2.7 s of 256-frame taps, so a brief stall in one model never drops its audio.
      let inputs = streams.map { _ in AsyncThrowingStream<AnalyzerInput, Swift.Error>.makeStream(bufferingPolicy: .bufferingNewest(512)) }
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
      let converter = AudioCapture(device: .init(id: 0, uid: "pair", name: "Speech pair"), outputFormat: format)
      try await withThrowingTaskGroup(of: Void.self) { group in
        if let apple {
          group.addTask {
            do {
              try await apple.start(input: appleInput.stream, generation: g) { candidate in
                Task { await self.deliverBackup(candidate, generation: g, live: live, onCandidate: onCandidate) }
              }
            } catch is CancellationError { throw CancellationError() }
            catch {
              appleInput.continuation.finish()
              if live.fail(LiveRecognisers.apple) { throw error }
            }
          }
        }
        for (index, (stream, input)) in zip(streams, inputs).enumerated() {
          group.addTask {
            do {
              try await stream.start(input: input.stream, generation: g) { candidate in
                var candidate = candidate
                candidate.requiresRewindAgreement = live.needsAgreement(index)
                onCandidate(candidate)
              }
            } catch is CancellationError { throw CancellationError() }
            catch {
              await stream.stop()
              if live.fail(index) { throw error }
              await self.activateBackup(generation: g)
            }
          }
        }
        group.addTask {
          defer { appleInput.continuation.finish(); inputs.forEach { $0.continuation.finish() } }
          var prepared = false
          var injected = false
          var overflowed = false
          for try await item in input {
            try Task.checkCancellation()
            if case .dropped = appleInput.continuation.yield(item) {
              appleInput.continuation.finish()
              if live.fail(LiveRecognisers.apple) { throw Error.analysisFailed("Apple speech fell behind the audio.") }
            }
            if !injected, let failureAfter, (item.bufferStartTime?.seconds ?? 0) >= failureAfter,
              let target = inputs.first {
              target.continuation.finish(throwing: Error.analysisFailed("Injected stream failure"))
              injected = true
            }
            if !prepared { try converter.prepareConverter(sampleRate: item.buffer.format.sampleRate); prepared = true }
            guard let buffer = converter.process(item.buffer)?.buffer else {
              await self.activateBackup(generation: g)
              continue
            }
            for target in inputs {
              // A model that lags loses its oldest audio but keeps following; Apple covers it meanwhile.
              if case .dropped = target.continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: item.bufferStartTime)),
                !overflowed {
                overflowed = true
                await self.activateBackup(generation: g)
              }
            }
          }
        }
        do { while try await group.next() != nil {} }
        catch {
          appleInput.continuation.finish(); inputs.forEach { $0.continuation.finish() }
          group.cancelAll(); await apple?.stop()
          for stream in streams { await stream.stop() }
          throw error
        }
      }
      return
    }
    if (engine == .both || engine == .bothUnified) {
      guard pairedProviders.count == 2 else { throw Error.notPrepared }
      generation = externalGeneration ?? (generation &+ 1)
      let g = generation
      let apple = pairedProviders[0], local = pairedProviders[1]
      let a = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(1024))
      let b = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(1024))
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
      let converter = AudioCapture(device: .init(id: 0, uid: "paired", name: "Paired speech"), outputFormat: format)
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { try await apple.start(input: a.stream, generation: g, onCandidate: onCandidate) }
          group.addTask { try await local.start(input: b.stream, generation: g, onCandidate: onCandidate) }
          group.addTask {
            defer { a.continuation.finish(); b.continuation.finish() }
            var prepared = false
            for try await item in input {
              try Task.checkCancellation()
              if !prepared { try converter.prepareConverter(sampleRate: item.buffer.format.sampleRate); prepared = true }
              guard let converted = converter.process(item.buffer)?.buffer else { throw Error.unavailable }
              if case .dropped = a.continuation.yield(item) { throw Error.analysisFailed("Apple speech fell behind the audio.") }
              if case .dropped = b.continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: item.bufferStartTime)) {
                throw Error.analysisFailed("Parakeet speech fell behind the audio.")
              }
            }
          }
          do { while try await group.next() != nil {} }
          catch {
            a.continuation.finish(); b.continuation.finish()
            group.cancelAll()
            await apple.stop(); await local.stop()
            throw error
          }
        }
      } catch {
        a.continuation.finish(); b.continuation.finish()
        await apple.stop(); await local.stop()
        throw error
      }
      return
    }
    if (engine == .eou || engine == .unified) {
      guard let parakeet else { throw Error.notPrepared }
      generation = externalGeneration ?? (generation &+ 1)
      try await parakeet.start(input: input, generation: generation, onCandidate: onCandidate)
      return
    }
    #endif
    guard let analyzer else { throw Error.notPrepared }
    resultTasks.forEach { $0.cancel() }
    resultTasks = []
    generation = externalGeneration ?? (generation &+ 1)
    let g = generation
    let modules = modules
    let dictationModules = dictationModules
    let locales = locales
    switch engine {
    case .parakeet, .both, .unified, .bothUnified, .eou: throw Error.unavailable
    case .transcription:
      for (i, module) in modules.enumerated() {
        resultTasks.append(
          Task { @MainActor in
            for try await result in module.results {
              guard !Task.isCancelled else { return }
              let id = "\(g)-\(i)-\(result.range.start.seconds)"
              onCandidate(
                .init(
                  replacementID: id, generation: g, locale: locales[i],
                  text: String(result.text.characters), range: result.range, isFinal: result.isFinal,
                  transcript: result.text))
            }
          })
      }
    case .dictation:
      for (i, module) in dictationModules.enumerated() {
        resultTasks.append(
          Task { @MainActor in
            for try await result in module.results {
              guard !Task.isCancelled else { return }
              let id = "\(g)-dictation-\(i)-\(result.range.start.value)-\(result.range.start.timescale)"
              onCandidate(
                .init(
                  replacementID: id, generation: g, locale: locales[i],
                  text: String(result.text.characters), range: result.range, isFinal: false,
                  transcript: result.text))
            }
          })
      }
    }
    do {
      try await analyzer.start(inputSequence: input)
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      for task in resultTasks { try await task.value }
    } catch {
      resultTasks.forEach { $0.cancel() }
      generation &+= 1
      await analyzer.cancelAndFinishNow()
      throw Error.analysisFailed(error.localizedDescription)
    }
  }
  #if os(macOS)
  private func activateBackup(generation: UInt64) async {
    guard generation == self.generation else { return }
    backupActive = Self.needsAppleBackup(english: true, eouReady: true, unifiedReady: true, streamFailed: true)
    await pairStatus("Apple backup active · continuing reading")
  }
  private func deliverBackup(_ candidate: SpeechCandidate, generation: UInt64, live: LiveRecognisers,
    onCandidate: @MainActor @Sendable (SpeechCandidate) -> Void) async {
    guard generation == self.generation else { return }
    var candidate = candidate
    candidate.publishesPosition = backupActive
    candidate.requiresRewindAgreement = live.needsAgreement(LiveRecognisers.apple)
    await onCandidate(candidate)
  }
  #endif
  public func stop() async {
    operation &+= 1
    #if os(macOS)
    for stream in pairStreams { await stream.stop() }
    pairStreams = []
    for provider in pairedProviders { await provider.stop() }
    pairedProviders = []
    await parakeet?.stop()
    parakeet = nil
    #endif
    generation &+= 1
    resultTasks.forEach { $0.cancel() }
    await analyzer?.cancelAndFinishNow()
    for task in resultTasks { _ = try? await task.value }
    resultTasks = []
    analyzer = nil
    modules = []
    dictationModules = []
    locales = []
  }
}
