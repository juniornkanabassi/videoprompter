import AVFoundation
import Foundation
import Speech

public struct SpeechCandidate: Sendable, Hashable {
  public let replacementID: String
  public let generation: UInt64
  public let locale: Locale
  public let text: String
  public let range: CMTimeRange
  public let isFinal: Bool
}
public actor SpeechProvider {
  public enum Error: Swift.Error, Sendable {
    case unavailable, notPrepared
    case analysisFailed(String)
  }
  private var analyzer: SpeechAnalyzer?
  private var modules: [SpeechTranscriber] = []
  private var locales: [Locale] = []
  private var generation: UInt64 = 0
  private var resultTasks: [Task<Void, Swift.Error>] = []
  public init() {}
  public var currentGeneration: UInt64 { generation }
  public func prepare(
    locales requested: [Locale] = [.init(identifier: "en-GB"), .init(identifier: "fr-FR")],
    naturalFormat: AVAudioFormat? = nil
  ) async throws -> AVAudioFormat {
    if let analyzer { await analyzer.cancelAndFinishNow() }
    resultTasks.forEach { $0.cancel() }
    resultTasks = []
    modules = []
    locales = []
    for requestedLocale in requested {
      guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
      else { throw Error.unavailable }
      modules.append(
        SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription))
      locales.append(supported)
    }
    guard
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: modules, considering: naturalFormat)
    else { throw Error.unavailable }
    let a = SpeechAnalyzer(modules: modules)
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
      try await installation.downloadAndInstall()
    }
    try await a.prepareToAnalyze(in: format)
    analyzer = a
    return format
  }
  public func start<S: AsyncSequence>(
    input: S, generation externalGeneration: UInt64? = nil,
    onCandidate: @escaping @Sendable (SpeechCandidate) -> Void
  ) async throws where S: Sendable, S.Element == AnalyzerInput {
    guard let analyzer else { throw Error.notPrepared }
    resultTasks.forEach { $0.cancel() }
    resultTasks = []
    generation = externalGeneration ?? (generation &+ 1)
    let g = generation
    let modules = modules
    let locales = locales
    for (i, module) in modules.enumerated() {
      resultTasks.append(
        Task { [weak self] in
          for try await result in module.results {
            guard let self, await self.currentGeneration == g else { return }
            let id = "\(g)-\(i)-\(result.range.start.seconds)"
            onCandidate(
              .init(
                replacementID: id, generation: g, locale: locales[i],
                text: String(result.text.characters), range: result.range, isFinal: result.isFinal))
          }
        })
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
  public func stop() async {
    generation &+= 1
    resultTasks.forEach { $0.cancel() }
    await analyzer?.cancelAndFinishNow()
    for task in resultTasks { _ = try? await task.value }
    resultTasks = []
    analyzer = nil
    modules = []
    locales = []
  }
}
