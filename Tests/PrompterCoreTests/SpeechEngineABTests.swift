import AVFoundation
import Foundation
import Speech
import XCTest
@testable import VideoPrompter
import PrompterCore

@MainActor final class SpeechEngineABTests: XCTestCase {
  func testSettingDefaultRoundTripAndRouting() throws {
    var settings = try JSONDecoder().decode(PrompterSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(settings.speechEngine, "apple")
    let name = "SpeechEngineAB.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    let session = SessionStore(defaults: defaults)
    session.updateSettings(settings)
    XCTAssertEqual(session.selectedSpeechEngine, .dictation)
    settings.speechEngine = "parakeet"
    settings = try JSONDecoder().decode(PrompterSettings.self, from: JSONEncoder().encode(settings))
    session.updateSettings(settings)
    XCTAssertEqual(session.selectedSpeechEngine, .parakeet)
    settings.speechEngine = "bad"
    settings.sanitise()
    XCTAssertEqual(settings.speechEngine, "apple")
    let command = try XCTUnwrap(ControlProtocol.command(action: "settings_set"))
    XCTAssertTrue(command.params.contains { $0.name == "speechEngine" && $0.accepts("parakeet") && !$0.accepts("bad") })
  }

  func testCumulativeCandidateSharesMatcherAndRejectsDuplicate() throws {
    let name = "SpeechEngineCandidates.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    let session = SessionStore(defaults: defaults)
    session.present(record: .init(metadata: .init(title: "AB", fileName: "ab.md"),
      markdown: "Liverpool won the football match today against Arsenal"), settings: .init())
    session.play(captureAudio: false)
    defer { session.pause() }
    let first = ParakeetSpeechStream.candidate(text: "Liverpool won the football", previous: "", generation: 1, end: CMTime(seconds: 2, preferredTimescale: 16000))!
    session.acceptSpeechCandidate(first)
    XCTAssertGreaterThan(session.tokenIndex, 0)
    let before = session.tokenIndex
    session.acceptSpeechCandidate(first)
    XCTAssertEqual(session.tokenIndex, before)
    XCTAssertNil(ParakeetSpeechStream.candidate(text: first.text, previous: first.text, generation: 1, end: .zero))
    XCTAssertNil(ParakeetSpeechStream.candidate(text: "", previous: "", generation: 1, end: .zero))
    session.acceptSpeechCandidate(ParakeetSpeechStream.candidate(text: "Liverpool won the football match today", previous: first.text, generation: 1, end: CMTime(seconds: 3, preferredTimescale: 16000))!)
    XCTAssertGreaterThan(session.tokenIndex, before)
  }

  func testCumulativeRevisionHonoursSeekWatermark() {
    let tokens = PrompterDocument(markdown: "Liverpool won the football match today against Arsenal").spokenTokens
    var tracker = RecognitionTracker(generation: 1)
    func event(_ text: String, _ end: Double) -> RecognitionEvent {
      let candidate = ParakeetSpeechStream.candidate(text: text, previous: "", generation: 1,
        end: CMTime(seconds: end, preferredTimescale: 16000))!
      return .init(replacementID: candidate.replacementID, generation: candidate.generation,
        text: candidate.text, isFinal: false, timestamp: end, audioStart: 0, audioEnd: end)
    }
    _ = tracker.consume(event("Liverpool won the football match today", 3), script: tokens)
    tracker.reanchor(to: 0, minimumAudioStart: 3)
    _ = tracker.consume(event("Liverpool won the football match today against", 3.2), script: tokens)
    XCTAssertEqual(tracker.tokenIndex, 0, "Buffered speech before a seek must not undo it")
  }

  func testModelVerificationRejectsCorruption() throws {
    let file = ParakeetModel.files.first { $0.path == "vocab.json" }!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0, count: file.size).write(to: root)
    XCTAssertFalse(try ParakeetModel.valid(root, file: file))
    XCTAssertEqual(ParakeetModel.size, 224047838)
  }

  /// Opt-in file replay. No audio devices, windows, or permissions are requested.
  func testRecordedAB() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(env["VP_SPEECH_AB"] == "1")
    let audioURL = URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_AUDIO"]))
    let modelURL = URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_MODEL"]))
    let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let script = try String(contentsOf: fixtures.appendingPathComponent("canonical-script.md"), encoding: .utf8)
    // Frozen earlier Apple word times are shared by both engines, never each engine's own clock.
    let compressed = try Data(contentsOf: fixtures.appendingPathComponent("canonical-reading.jsonl.deflate"))
    let data = try (compressed as NSData).decompressed(using: .zlib) as Data
    let rows = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    var reference: [String: WordLatency.Revision] = [:]
    for row in rows where (row["locale"] as? String)?.hasPrefix("en") == true {
      guard let raw = row["words"] as? [[String: Any]], raw.count > 1 else { continue }
      let words = raw.compactMap { w -> TimedWord? in
        guard let t = w["text"] as? String, let s = w["start"] as? Double, let e = w["end"] as? Double else { return nil }
        return TimedWord(text: t, start: s, end: e)
      }
      let id = row["replacementID"] as! String
      reference[id] = .init(locale: "en_GB", replacementID: id, audioStart: row["audioStart"] as! Double,
        audioEnd: row["audioEnd"] as! Double, words: words)
    }
    let tokens = PrompterDocument(markdown: script).spokenTokens
    let heard = WordLatency.heard(Array(reference.values))
    let alignment = WordLatency.align(heard, script: tokens)
    let expected = heard.first?.map(\.word) ?? []
    let engines: [SpeechProvider.Engine] = env["VP_SPEECH_AB_ENGINE"] == "apple" ? [.dictation]
      : env["VP_SPEECH_AB_ENGINE"] == "parakeet" ? [.parakeet] : [.parakeet, .dictation]
    for engine in engines {
      FileHandle.standardError.write(Data("Preparing \(engine)\n".utf8))
      let suite = "SpeechABReplay.\(UUID())"
      let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
      defer { TestDefaults.remove(suite) }
      let session = SessionStore(defaults: defaults)
      session.voiceEndGrace = .seconds(60)
      session.present(record: .init(metadata: .init(title: "AB", fileName: "ab.md"), markdown: script), settings: .init())
      session.play(captureAudio: false)
      let provider = SpeechProvider()
      let file = try AVAudioFile(forReading: audioURL)
      let format = try await provider.prepare(locales: [Locale(identifier: "en-GB")], naturalFormat: file.processingFormat,
        contextualStrings: SpeechProvider.contextualPhrases(from: script), engine: engine, modelDirectory: modelURL)
      let capture = AudioCapture(device: .init(id: 0, uid: "ab-replay", name: "A/B replay"), outputFormat: format)
      try capture.prepareConverter(sampleRate: file.processingFormat.sampleRate)
      let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
      var published = [Double?](repeating: nil, count: tokens.count)
      var firstPartial: Double?
      var transcripts: [(start: Double, end: Double, text: String)] = []
      let start = ProcessInfo.processInfo.systemUptime
      let producer = Task {
        defer { stream.continuation.finish() }
        var frame: Int64 = 0
        while file.framePosition < file.length {
          let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate / 30))!
          try file.read(into: source)
          guard source.frameLength > 0, let output = capture.process(source)?.buffer else { continue }
          let wait = start + Double(frame + Int64(output.frameLength)) / format.sampleRate - ProcessInfo.processInfo.systemUptime
          if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
          stream.continuation.yield(.init(buffer: output, bufferStartTime: CMTime(value: frame, timescale: CMTimeScale(format.sampleRate))))
          frame += Int64(output.frameLength)
        }
      }
      do {
        try await provider.start(input: stream.stream) { candidate in
          let now = ProcessInfo.processInfo.systemUptime - start
          if firstPartial == nil { firstPartial = now }
          let a = candidate.range.start.seconds, b = candidate.range.end.seconds
          // Dictation can revise the segment's start as well as its text. Replace overlapping
          // versions rather than counting both as new speech in WER.
          Self.appendTranscript((a, b, candidate.text), to: &transcripts)
          session.acceptSpeechCandidate(candidate)
          if let index = session.lastConfirmedTokenIndex {
            for i in 0...min(index, tokens.count - 1) where published[i] == nil { published[i] = now }
          }
        }
        try await producer.value
      } catch {
        producer.cancel(); stream.continuation.finish(); await provider.stop(); session.pause(); throw error
      }
      await provider.stop()
      session.pause()
      let actual = PrompterDocument(markdown: transcripts.sorted { $0.start < $1.start }
        .map(\.text).joined(separator: " ")).spokenTokens.map(\.normalised)
      let errors = Self.distance(expected, actual)
      let result: [String: Any] = ["engine": engine == .dictation ? "apple" : "parakeet", "firstPartial": firstPartial ?? -1,
        "p50": WordLatency.percentiles(WordLatency.latencies(display: published, spoken: alignment.spoken)).p50,
        "p90": WordLatency.percentiles(WordLatency.latencies(display: published, spoken: alignment.spoken)).p90,
        "falseAdvances": WordLatency.early(display: published, alignment: alignment, script: tokens).count,
        "published": published.compactMap { $0 }.count, "scriptWords": tokens.count,
        "referenceWords": expected.count, "editErrors": errors, "wer": Double(errors) / Double(expected.count),
        "transcript": actual.joined(separator: " "),
        "segments": transcripts.map { ["start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] }]
      let out = URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_OUTPUT"]))
        .appendingPathComponent(engine == .dictation ? "apple.json" : "parakeet.json")
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out)
      print("SPEECH_AB \(result.filter { $0.key != "transcript" })")
      XCTAssertGreaterThan(published.compactMap { $0 }.count, 0)
    }
  }

  static func appendTranscript(_ segment: (start: Double, end: Double, text: String),
    to segments: inout [(start: Double, end: Double, text: String)]) {
    segments.removeAll { old in
      old.start == segment.start || (min(old.end, segment.end) - max(old.start, segment.start))
        > 0.8 * min(old.end - old.start, segment.end - segment.start)
    }
    segments.append(segment)
  }

  func testRevisedAudioRangeIsNotCountedTwiceForAccuracy() {
    var segments = [(start: 0.0, end: 10.0, text: "first draft")]
    Self.appendTranscript((0.1, 10.2, "corrected draft"), to: &segments)
    Self.appendTranscript((10.2, 12, "next sentence"), to: &segments)
    XCTAssertEqual(segments.map(\.text), ["corrected draft", "next sentence"])
  }

  static func distance(_ a: [String], _ b: [String]) -> Int {
    var row = Array(0...b.count)
    for (i, word) in a.enumerated() {
      var next = [i + 1] + Array(repeating: 0, count: b.count)
      for j in b.indices { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (word == b[j] ? 0 : 1)) }
      row = next
    }
    return row[b.count]
  }
  func testEditDistance() {
    XCTAssertEqual(Self.distance(["one", "two"], ["one", "three", "four"]), 2)
    XCTAssertEqual(Self.distance([], ["one"]), 1)
  }
}
