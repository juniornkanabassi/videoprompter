@preconcurrency import AVFoundation
import Speech
import XCTest

@testable import JuniorPrompter
import PrompterCore

@MainActor
final class SpeechSessionIntegrationTests: XCTestCase {
  func testBilingualFixtureThroughProductionProviderAndSession() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["JUNIORPROMPTER_RUN_SPEECH_INTEGRATION"] == "1")
    let root = URL(fileURLWithPath: "/Users/junior.nkanabassi/Documents/JuniorOS/05 Other/Codex Workspace/JuniorPrompter-research-20260905/speech-fixtures")
    let expected = try String(contentsOf: root.appendingPathComponent("expected.txt"), encoding: .utf8)
    let session = SessionStore()
    let record = ScriptRecord(metadata: .init(title: "Fixture", fileName: "fixture.md"), markdown: expected)
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: record, settings: settings)
    session.play(captureAudio: false)
    defer { session.pause() }
    let provider = SpeechProvider()
    let audio = try AVAudioFile(forReading: root.appendingPathComponent("bilingual.wav"))
    let format = try await provider.prepare(naturalFormat: audio.processingFormat)
    let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(20))
    let producer = Task {
      let converter = try XCTUnwrap(AVAudioConverter(from: audio.processingFormat, to: format))
      var frame: Int64 = 0
      while audio.framePosition < audio.length {
        let source = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1600)!
        try audio.read(into: source, frameCount: 1600)
        guard source.frameLength > 0 else { break }
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / audio.processingFormat.sampleRate)) + 1
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var used = false; var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
          if used { status.pointee = .noDataNow; return nil }
          used = true; status.pointee = .haveData; return source
        }
        if let conversionError { throw conversionError }
        stream.continuation.yield(.init(buffer: output, bufferStartTime: CMTime(value: frame, timescale: CMTimeScale(format.sampleRate))))
        frame += Int64(output.frameLength)
        try await Task.sleep(for: .milliseconds(Int((Double(source.frameLength) / audio.processingFormat.sampleRate) * 1000)))
      }
      stream.continuation.finish()
    }
    defer { producer.cancel() }
    try await provider.start(input: stream.stream) { candidate in
      Task { @MainActor in session.acceptSpeechCandidate(candidate) }
    }
    try await producer.value
    try await Task.sleep(for: .milliseconds(150))
    print("Speech integration acceptedWords=\(session.acceptedWords) finalTokenIndex=\(session.tokenIndex)/\(session.document.spokenTokens.count - 1)")
    XCTAssertGreaterThan(session.acceptedWords, 0)
    XCTAssertGreaterThanOrEqual(session.tokenIndex, session.document.spokenTokens.count - 2)
  }
}
