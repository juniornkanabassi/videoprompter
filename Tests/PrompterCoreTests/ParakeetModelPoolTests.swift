import AVFoundation
import FluidAudio
import Foundation
import Speech
import XCTest
@testable import VideoPrompter

/// A seek, pause or resume stops and re-prepares the speech provider; the loaded Parakeet models
/// must survive that instead of being reloaded from disk each time.
@MainActor final class ParakeetModelPoolTests: XCTestCase {
  private actor FakeManager: StreamingAsrManager {
    var displayName: String { "fake" }
    var resets = 0, cleanups = 0
    func loadModels() async throws {}
    func appendAudio(_ buffer: AVAudioPCMBuffer) throws {}
    func processBufferedAudio() async throws {}
    func finish() async throws -> String { "" }
    func reset() async throws { resets += 1 }
    func cleanup() async { cleanups += 1 }
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {}
    func getPartialTranscript() -> String { "" }
  }

  func testPoolResetsReusesAndReleases() async throws {
    let pool = ParakeetModelPool.shared
    let key = "test|\(UUID())"
    let first = FakeManager(), second = FakeManager()
    await pool.put(first, key: key)
    let resets = await first.resets
    XCTAssertEqual(resets, 1, "Handed back with fresh decoding state")
    let taken = await pool.take(key)
    XCTAssertTrue(taken === first)
    let again = await pool.take(key)
    XCTAssertNil(again, "One owner at a time")
    await pool.put(first, key: key)
    await pool.put(second, key: key)
    let replacedCleanups = await first.cleanups
    XCTAssertEqual(replacedCleanups, 1, "Only one idle copy per model is kept")
    await pool.releaseAll()
    let releasedCleanups = await second.cleanups
    XCTAssertEqual(releasedCleanups, 1)
    let left = await pool.take(key)
    XCTAssertNil(left)
  }

  /// Opt-in: real models, read only. VP_POOL_MODELS is a folder holding parakeet-eou-160ms and
  /// parakeet-unified-640ms; VP_POOL_AUDIO a recording. Nothing is written or played.
  func testRealStreamReusesLoadedModelsWithCleanState() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(env["VP_POOL_MODELS"] != nil && env["VP_POOL_AUDIO"] != nil)
    let models = URL(fileURLWithPath: env["VP_POOL_MODELS"]!)
    let audio = URL(fileURLWithPath: env["VP_POOL_AUDIO"]!)
    await ParakeetModelPool.shared.releaseAll()
    for unified in [false, true] {
      let root = models.appendingPathComponent(unified ? UnifiedModel.folder : "parakeet-eou-160ms")
      var timings: [Double] = []
      var transcripts: [String] = []
      for _ in 0..<2 {
        let stream = ParakeetSpeechStream()
        let started = ProcessInfo.processInfo.systemUptime
        try await stream.prepare(directory: root, unified: unified, allowDownload: false, onPreparation: { _ in })
        timings.append(ProcessInfo.processInfo.systemUptime - started)
        var text = ""
        try await stream.start(input: try Self.input(audio, seconds: 8), generation: 1) { text = $0.text }
        transcripts.append(text)
        await stream.stop()
      }
      print("POOL unified=\(unified) cold=\(timings[0] * 1000) ms reused=\(timings[1] * 1000) ms words=\(transcripts[0].split(separator: " ").count)")
      XCTAssertFalse(transcripts[0].isEmpty)
      XCTAssertEqual(transcripts[1], transcripts[0], "A reused model must start from a clean transcript")
      XCTAssertLessThan(timings[1], timings[0] / 5)
    }
    let provider = SpeechProvider()
    var provided: [Double] = []
    for _ in 0..<2 {
      var status = ""
      let started = ProcessInfo.processInfo.systemUptime
      _ = try await provider.prepare(locales: [.init(identifier: "en-GB")], engine: .parakeet, modelDirectory: models,
        onPreparation: { status = $0 })
      provided.append(ProcessInfo.processInfo.systemUptime - started)
      XCTAssertTrue(status.contains("pair ready"), status)
      await provider.stop()
    }
    print("POOL provider pair prepare after stop: first=\(provided[0] * 1000) ms again=\(provided[1] * 1000) ms")
    await ParakeetModelPool.shared.releaseAll()
  }

  private static func input(_ url: URL, seconds: Double) throws -> AsyncStream<AnalyzerInput> {
    let file = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let converter = AudioCapture(device: .init(id: 0, uid: "pool-file", name: "Pool file"), outputFormat: format)
    try converter.prepareConverter(sampleRate: file.processingFormat.sampleRate)
    let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    var frames: Int64 = 0
    while Double(file.framePosition) / file.processingFormat.sampleRate < seconds {
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate / 30))!
      try file.read(into: buffer)
      guard buffer.frameLength > 0 else { break }
      guard let output = converter.process(buffer)?.buffer else { continue }
      stream.continuation.yield(.init(buffer: output, bufferStartTime: CMTime(value: frames, timescale: 16_000)))
      frames += Int64(output.frameLength)
    }
    stream.continuation.finish()
    return stream.stream
  }
}
