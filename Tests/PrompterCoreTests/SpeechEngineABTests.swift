import AVFoundation
import Foundation
import CoreML
import CryptoKit
import Darwin
import FluidAudio
import Speech
import XCTest
@testable import VideoPrompter
import PrompterCore

@MainActor final class SpeechEngineABTests: XCTestCase {
  func testSettingDefaultRoundTripAndRouting() throws {
    var settings = try JSONDecoder().decode(PrompterSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(settings.speechEngine, "parakeet")
    let name = "SpeechEngineAB.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    let session = SessionStore(defaults: defaults)
    session.updateSettings(settings)
    XCTAssertEqual(session.selectedSpeechEngine, .parakeet)
    settings.speechEngine = "parakeet"
    settings = try JSONDecoder().decode(PrompterSettings.self, from: JSONEncoder().encode(settings))
    session.updateSettings(settings)
    XCTAssertEqual(session.selectedSpeechEngine, .parakeet)
    settings.speechEngine = "both"
    session.updateSettings(settings)
    XCTAssertEqual(session.selectedSpeechEngine, .parakeet)
    settings.speechEngine = "unified"
    session.updateSettings(settings)
    XCTAssertEqual(session.selectedSpeechEngine, .parakeet)
    settings.speechEngine = "both-unified"
    session.updateSettings(settings)
    XCTAssertEqual(session.selectedSpeechEngine, .parakeet)
    settings.speechEngine = "bad"
    settings.sanitise()
    XCTAssertEqual(settings.speechEngine, "apple")
    let command = try XCTUnwrap(ControlProtocol.command(action: "settings_set"))
    XCTAssertTrue(command.params.contains { $0.name == "speechEngine" && $0.accepts("parakeet") && !$0.accepts("bad") })
  }

  func testLegacyEngineMigration() throws {
    for legacy in ["both", "unified", "both-unified"] {
      let value = try JSONDecoder().decode(PrompterSettings.self,
        from: Data("{\"speechEngine\":\"\(legacy)\"}".utf8))
      XCTAssertEqual(value.speechEngine, "parakeet")
    }
    let command = try XCTUnwrap(ControlProtocol.command(action: "settings_set"))
    let parameter = try XCTUnwrap(command.params.first { $0.name == "speechEngine" })
    XCTAssertTrue(parameter.accepts("apple"))
    XCTAssertFalse(parameter.accepts("both"))
  }

  func testAutomaticBackupSelection() {
    XCTAssertFalse(SpeechProvider.needsAppleBackup(english: true, eouReady: true, unifiedReady: true))
    XCTAssertTrue(SpeechProvider.needsAppleBackup(english: false, eouReady: true, unifiedReady: true))
    XCTAssertTrue(SpeechProvider.needsAppleBackup(english: true, eouReady: false, unifiedReady: false))
    XCTAssertTrue(SpeechProvider.needsAppleBackup(english: true, eouReady: true, unifiedReady: false))
    XCTAssertTrue(SpeechProvider.needsAppleBackup(english: true, eouReady: false, unifiedReady: true))
    XCTAssertTrue(SpeechProvider.needsAppleBackup(english: true, eouReady: true, unifiedReady: true, streamFailed: true))
  }

  func testPrefetchGuardsAndAppleCancellation() {
    XCTAssertFalse(SpeechModelPrefetch.allowed(arguments: [], environment: [:], underTest: true))
    for argument in ["--agent-screen", "--list-camera-ids"] {
      XCTAssertFalse(SpeechModelPrefetch.allowed(arguments: [argument], environment: [:], underTest: false))
    }
    XCTAssertFalse(SpeechModelPrefetch.allowed(arguments: [], environment: ["VIDEOPROMPTER_SNAPSHOTS": "1"], underTest: false))
    XCTAssertTrue(SpeechModelPrefetch.allowed(arguments: [], environment: [:], underTest: false))
    XCTAssertFalse(SpeechModelPrefetch.shouldDownload(engine: "parakeet", constrained: true))
    XCTAssertFalse(SpeechModelPrefetch.shouldDownload(engine: "apple", constrained: false))
    XCTAssertTrue(SpeechModelPrefetch.shouldDownload(engine: "parakeet", constrained: false))
    let prefetch = SpeechModelPrefetch()
    prefetch.select("parakeet")
    XCTAssertFalse(prefetch.isDownloading, "Tests must never touch real model storage")
    prefetch.select("apple")
    XCTAssertFalse(prefetch.isDownloading)
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

  func testBothKeepsEngineRevisionsIndependentAndSeeksTogether() throws {
    let name = "BothCandidates.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    let session = SessionStore(defaults: defaults)
    var settings = PrompterSettings(); settings.speechEngine = "both"
    session.present(record: .init(metadata: .init(title: "Both", fileName: "both.md"),
      markdown: "Liverpool won the football match today against Arsenal Liverpool won the football match today"), settings: settings)
    session.play(captureAudio: false)
    defer { session.pause() }
    func send(_ text: String, _ source: String, _ end: Double = 2) {
      session.acceptSpeechCandidate(.init(replacementID: "same-id", generation: 1,
        locale: Locale(identifier: "en-GB"), text: text,
        range: .init(start: .zero, end: CMTime(seconds: end, preferredTimescale: 16000)),
        isFinal: false, source: source))
    }
    send("Liverpool won the football", "unified")
    let first = session.tokenIndex
    send("Liverpool won the football", "apple")
    XCTAssertEqual(session.tokenIndex, first, "Second engine must not double-credit repeated text")
    send("Liverpool won the football match today against Arsenal", "apple", 3)
    let ahead = session.tokenIndex
    XCTAssertGreaterThan(ahead, first)
    send("Liverpool won the football", "parakeet", 3)
    XCTAssertEqual(session.tokenIndex, ahead, "Lagging recogniser must not roll back the leader")
    session.noteSubmittedAudioEnd(through: 3)
    session.seek(to: 0)
    send("Liverpool won the football match today against Arsenal", "apple", 3.2)
    send("Liverpool won the football match today against Arsenal", "parakeet", 3.2)
    XCTAssertEqual(session.tokenIndex, 0, "Both histories must honour the seek watermark")
    session.pause()
    send("Liverpool won the football match today against Arsenal Liverpool", "apple", 4)
    XCTAssertEqual(session.tokenIndex, 0)
    session.play(captureAudio: false)
    send("Liverpool won the football match today against Arsenal Liverpool", "apple", 5)
    XCTAssertEqual(session.tokenIndex, 0, "Old-generation callbacks must stay invalid after resuming")
    session.restart()
    XCTAssertEqual(session.tokenIndex, 0)
  }

  func testBothRejectsLateFirstResultAfterSeekAndUnrelatedWords() throws {
    let name = "BothLateSeek.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    let session = SessionStore(defaults: defaults)
    var settings = PrompterSettings(); settings.speechEngine = "both"
    session.present(record: .init(metadata: .init(title: "Both", fileName: "both.md"),
      markdown: "Liverpool won the football match today against Arsenal"), settings: settings)
    session.play(captureAudio: false)
    defer { session.pause() }
    func send(_ text: String, _ source: String, _ end: Double) {
      session.acceptSpeechCandidate(.init(replacementID: source, generation: 1,
        locale: Locale(identifier: "en-GB"), text: text,
        range: .init(start: .zero, end: CMTime(seconds: end, preferredTimescale: 16000)),
        isFinal: false, source: source))
    }
    send("random unrelated noise", "apple", 1)
    XCTAssertEqual(session.tokenIndex, 0)
    send("Liverpool won the football", "apple", 2)
    session.noteSubmittedAudioEnd(through: 3)
    session.seek(to: 0)
    send("Liverpool won the football match today", "parakeet", 3.2)
    XCTAssertEqual(session.tokenIndex, 0, "An unseen engine must inherit the seek watermark")
  }

  func testWarmAppleContinuesImmediatelyAfterPairFailsFarIntoScript() throws {
    let name = "WarmBackup.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    let session = SessionStore(defaults: defaults)
    let words = (0..<240).map { "token\($0)" }
    session.present(record: .init(metadata: .init(title: "Long", fileName: "long.md"),
      markdown: words.joined(separator: " ")), settings: PrompterSettings())
    session.play(captureAudio: false)
    defer { session.pause() }
    func send(_ start: Int, _ end: Int, _ source: String, publish: Bool) {
      var candidate = SpeechCandidate(replacementID: "\(source)-\(start)", generation: 1,
        locale: Locale(identifier: "en-GB"), text: words[start...end].joined(separator: " "),
        range: .init(start: CMTime(seconds: Double(start), preferredTimescale: 100),
          end: CMTime(seconds: Double(end + 1), preferredTimescale: 100)), isFinal: false, source: source)
      candidate.publishesPosition = publish
      session.acceptSpeechCandidate(candidate)
    }
    for start in stride(from: 0, to: 160, by: 8) {
      send(start, start + 7, "parakeet", publish: true)
      send(start, start + 7, "apple", publish: false)
    }
    XCTAssertEqual(session.lastConfirmedTokenIndex, 159)
    send(160, 167, "apple", publish: false)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 159, "Warm Apple never publishes while healthy")
    // The provider flips only publication when a stream fails; Apple's history stays intact.
    send(168, 175, "apple", publish: true)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 175)
  }

  func testPairRequiresFreshAgreementToRepeatAndCanAdvanceAgain() throws {
    for followsRepeats in [true, false] {
      let name = "PairRepeat.\(UUID())"
      let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
      defer { TestDefaults.remove(name) }
      let session = SessionStore(defaults: defaults)
      var settings = PrompterSettings()
      settings.allowsBackwardVoiceTracking = followsRepeats
      let words = (0..<48).map { "token\($0)" }
      session.present(record: .init(metadata: .init(title: "Repeat", fileName: "repeat.md"),
        markdown: words.joined(separator: " ")), settings: settings)
      session.play(captureAudio: false)
      defer { session.pause() }
      func send(_ start: Int, _ end: Int, _ source: String, _ time: Double) {
        session.acceptSpeechCandidate(.init(replacementID: "\(source)-\(time)", generation: 1,
          locale: Locale(identifier: "en-GB"), text: words[start...end].joined(separator: " "),
          range: .init(start: CMTime(seconds: time - 0.5, preferredTimescale: 100),
            end: CMTime(seconds: time, preferredTimescale: 100)), isFinal: false, source: source))
      }
      send(0, 7, "parakeet", 1)
      send(0, 7, "unified", 1.1)
      send(8, 23, "parakeet", 2)
      send(8, 23, "unified", 2.1)
      XCTAssertEqual(session.lastConfirmedTokenIndex, 23)
      send(0, 7, "parakeet", 1.5)
      send(0, 7, "unified", 1.6)
      XCTAssertEqual(session.lastConfirmedTokenIndex, 23, "Old audio must not rewind")
      send(0, 7, "parakeet", 3)
      XCTAssertEqual(session.lastConfirmedTokenIndex, 23, "One recogniser cannot rewind the pair")
      send(0, 7, "unified", 3.1)
      XCTAssertEqual(session.lastConfirmedTokenIndex, followsRepeats ? 7 : 23)
      if followsRepeats {
        send(8, 23, "apple", 2.5)
        XCTAssertEqual(session.lastConfirmedTokenIndex, 7, "A late pre-rewind result cannot restore the old frontier")
      }
      send(24, 31, "parakeet", 4)
      XCTAssertEqual(session.lastConfirmedTokenIndex, 31, "Forward following remains immediate")
    }
  }

  func testVerificationCacheUsesSizesAfterFirstSuccessfulHash() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("verified".utf8)
    let file = ParakeetModel.File(path: "test", size: data.count,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    let url = root.appendingPathComponent(file.path)
    try data.write(to: url)
    XCTAssertTrue(ParakeetModel.ready(at: root, files: [file]))
    try Data("modified".utf8).write(to: url)
    XCTAssertTrue(ParakeetModel.ready(at: root, files: [file]), "Same-size changes are checked next launch")
    try Data("short".utf8).write(to: url)
    XCTAssertFalse(ParakeetModel.ready(at: root, files: [file]))
    try data.write(to: url)
    XCTAssertTrue(ParakeetModel.ready(at: root, files: [file]))
  }

  func testModelVerificationRejectsCorruption() throws {
    let file = ParakeetModel.files.first { $0.path == "vocab.json" }!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0, count: file.size).write(to: root)
    XCTAssertFalse(try ParakeetModel.valid(root, file: file))
    XCTAssertEqual(ParakeetModel.size, 224047838)
    XCTAssertEqual(UnifiedModel.size, 608529377)
  }

  /// Opt-in file replay. No audio devices, windows, or permissions are requested.
  func testRecordedAB() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(env["VP_SPEECH_AB"] == "1")
    if let manifest = env["VP_SPEECH_AB_MANIFEST"] {
      let clips = try JSONDecoder().decode([ReplayClip].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
      for clip in clips { try await replay(clip: clip, env: env) }
      return
    }
    let audioURL = URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_AUDIO"]))
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
    try await replay(clip: .init(id: "legacy", audio: audioURL.path, script: script,
      words: reference.values.sorted { $0.audioStart < $1.audioStart }.flatMap(\.words)), env: env)
  }

  private struct ReplayClip: Codable {
    let id: String
    let audio: String
    let script: String
    let words: [TimedWord]
  }

  private func replay(clip: ReplayClip, env: [String: String]) async throws {
    let audioURL = URL(fileURLWithPath: clip.audio)
    let modelURL = URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_MODEL"]))
    let script = clip.script
    let tokens = PrompterDocument(markdown: script).spokenTokens
    let heard = WordLatency.heard([.init(locale: "en_GB", replacementID: clip.id,
      audioStart: 0, audioEnd: clip.words.last?.end ?? 0, words: clip.words)])
    let alignment = WordLatency.align(heard, script: tokens)
    let expected = heard.first?.map(\.word) ?? []
    let engines = env["VP_SPEECH_AB_ENGINE"].map { [$0] } ?? ["apple", "parakeet", "both"]
    for engine in engines {
      FileHandle.standardError.write(Data("Preparing \(engine) / \(clip.id)\n".utf8))
      let suite = "SpeechABReplay.\(UUID())"
      let defaults = try XCTUnwrap(TestDefaults.suite(named: suite))
      defer { TestDefaults.remove(suite) }
      let session = SessionStore(defaults: defaults)
      session.voiceEndGrace = .seconds(60)
      session.present(record: .init(metadata: .init(title: "AB", fileName: "ab.md"), markdown: script), settings: { var settings = PrompterSettings(); settings.speechEngine = (engine.hasPrefix("both") || engine.hasPrefix("race-")) ? (engine.contains("unified320") ? "both-unified" : "both") : "apple"; return settings }())
      session.play(captureAudio: false)
      let provider = ReplayRecognizer(engine: engine)
      let file = try AVAudioFile(forReading: audioURL)
      let format = try await provider.prepare(locales: [Locale(identifier: "en-GB")], naturalFormat: file.processingFormat,
        contextualStrings: SpeechProvider.contextualPhrases(from: script), modelDirectory: modelURL)
      let capture = AudioCapture(device: .init(id: 0, uid: "ab-replay", name: "A/B replay"), outputFormat: format)
      try capture.prepareConverter(sampleRate: file.processingFormat.sampleRate)
      let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
      var published = [Double?](repeating: nil, count: tokens.count)
      var firstPartial: Double?
      var advances: [Double] = []
      var contextWindow = -1
      var transcripts: [String: [(start: Double, end: Double, text: String)]] = [:]
      var candidates: [[String: Any]] = []
      var usageStart = rusage()
      getrusage(RUSAGE_SELF, &usageStart)
      let start = ProcessInfo.processInfo.systemUptime
      let unpaced = env["VP_SPEECH_AB_UNPACED"] == "1"
      let producer = Task {
        defer { stream.continuation.finish() }
        var frame: Int64 = 0
        while file.framePosition < file.length {
          if let limit = env["VP_SPEECH_AB_SECONDS"].flatMap(Double.init), Double(file.framePosition) / file.processingFormat.sampleRate >= limit { break }
          let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate / 30))!
          try file.read(into: source)
          guard source.frameLength > 0, let output = capture.process(source)?.buffer else { continue }
          let wait = start + Double(frame + Int64(output.frameLength)) / format.sampleRate - ProcessInfo.processInfo.systemUptime
          if !unpaced, wait > 0 { try await Task.sleep(for: .seconds(wait)) }
          stream.continuation.yield(.init(buffer: output, bufferStartTime: CMTime(value: frame, timescale: CMTimeScale(format.sampleRate))))
          frame += Int64(output.frameLength)
        }
      }
      do {
        try await provider.start(input: stream.stream) { candidate in
          let now = unpaced ? candidate.range.end.seconds : ProcessInfo.processInfo.systemUptime - start
          if firstPartial == nil { firstPartial = now }
          let a = candidate.range.start.seconds, b = candidate.range.end.seconds
          // Dictation can revise the segment's start as well as its text. Replace overlapping
          // versions rather than counting both as new speech in WER.
          Self.appendTranscript((a, b, candidate.text), to: &transcripts[candidate.source, default: []])
          candidates.append(["source": candidate.source, "time": now, "start": a, "end": b, "text": candidate.text, "id": candidate.replacementID, "final": candidate.isFinal])
          session.acceptSpeechCandidate(candidate)
          if let index = session.lastConfirmedTokenIndex {
            let window = index / 24 * 24
            if window != contextWindow {
              contextWindow = window
              Task { try await provider.updateContext(SpeechProvider.upcomingContext(tokens, at: window)) }
            }
            if published[min(index, tokens.count - 1)] == nil { advances.append(now) }
            for i in 0...min(index, tokens.count - 1) where published[i] == nil { published[i] = now }
          }
        }
        try await producer.value
      } catch {
        producer.cancel(); stream.continuation.finish(); await provider.stop(); session.pause(); throw error
      }
      await provider.stop()
      session.pause()
      let measuredSource = transcripts[engine.contains("both") ? "apple" : (transcripts.keys.first ?? "apple")] ?? []
      let actual = PrompterDocument(markdown: measuredSource.sorted { $0.start < $1.start }
        .map(\.text).joined(separator: " ")).spokenTokens.map(\.normalised)
      let errors = Self.distance(expected, actual)
      var usageEnd = rusage()
      getrusage(RUSAGE_SELF, &usageEnd)
      func cpu(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
      }
      let latency = WordLatency.latencies(display: published, spoken: alignment.spoken)
      let sorted = latency.sorted()
      let stuck = Self.stuckSpans(advances: advances, words: clip.words,
        end: unpaced ? (clip.words.last?.end ?? 0) : ProcessInfo.processInfo.systemUptime - start)
      let result: [String: Any] = ["engine": engine, "clip": clip.id,
        "paced": !unpaced,
        "p99": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))],
        "stuckSpans": stuck, "stuckSeconds": stuck.reduce(0) { $0 + $1 }, "firstPartial": firstPartial ?? -1,
        "cpuSeconds": cpu(usageEnd) - cpu(usageStart), "wallSeconds": ProcessInfo.processInfo.systemUptime - start, "peakRSSBytes": usageEnd.ru_maxrss,
        "p50": WordLatency.percentiles(WordLatency.latencies(display: published, spoken: alignment.spoken)).p50,
        "p90": WordLatency.percentiles(WordLatency.latencies(display: published, spoken: alignment.spoken)).p90,
        "falseAdvances": WordLatency.early(display: published, alignment: alignment, script: tokens).count,
        "published": published.compactMap { $0 }.count, "scriptWords": tokens.count,
        "referenceWords": expected.count, "editErrors": errors, "wer": Double(errors) / Double(expected.count),
        "transcript": actual.joined(separator: " "),
        "format": format.description, "candidates": candidates, "publishedTimes": published.map { $0 ?? -1 },
        "wordLatencySamples": WordLatency.latencies(display: published, spoken: alignment.spoken),
        "earlyTokens": WordLatency.early(display: published, alignment: alignment, script: tokens).map { $0.token },
        "sourceWER": transcripts.mapValues { segments in
          Double(Self.distance(expected, PrompterDocument(markdown: segments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")).spokenTokens.map(\.normalised))) / Double(expected.count)
        },
        "segments": measuredSource.map { ["start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] }]
      let out = URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_OUTPUT"]))
        .appendingPathComponent(clip.id + "-" + engine + ".json")
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out)
      print("SPEECH_AB \(result.filter { !["transcript", "candidates", "segments", "publishedTimes", "wordLatencySamples"].contains($0.key) })")
      XCTAssertGreaterThan(published.compactMap { $0 }.count, 0)
    }
  }

  /// Opt-in actual managers and Apple, file input only; no capture devices or playback.
  func testRealPairStreamFailureAndResourceUse() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(env["VP_PAIR_LIVE"] == "1")
    let root = URL(fileURLWithPath: try XCTUnwrap(env["VP_PAIR_MODELS"]))
    let audio = URL(fileURLWithPath: try XCTUnwrap(env["VP_PAIR_AUDIO"]))
    let script = try String(contentsOfFile: XCTUnwrap(env["VP_PAIR_SCRIPT"]), encoding: .utf8)
    let failureAfter = env["VP_PAIR_FAIL_AFTER"].flatMap(Double.init)
    let provider = failureAfter.map { SpeechProvider(localStreamFailureAfter: $0) } ?? SpeechProvider()
    let name = "PairReal.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    let session = SessionStore(defaults: defaults)
    session.voiceEndGrace = .seconds(120)
    session.present(record: .init(metadata: .init(title: "Replay", fileName: "replay.md"), markdown: script), settings: PrompterSettings())
    session.play(captureAudio: false)
    defer { session.pause() }
    var status = ""
    let file = try AVAudioFile(forReading: audio)
    let format = try await provider.prepare(locales: [.init(identifier: "en-GB")], naturalFormat: file.processingFormat,
      contextualStrings: SpeechProvider.contextualPhrases(from: script), engine: .parakeet,
      modelDirectory: root, onPreparation: { status = $0 })
    XCTAssertTrue(status.contains("pair ready"), status)
    let converter = AudioCapture(device: .init(id: 0, uid: "pair-file", name: "Pair file"), outputFormat: format)
    try converter.prepareConverter(sampleRate: file.processingFormat.sampleRate)
    let input = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    var usageStart = rusage()
    getrusage(RUSAGE_SELF, &usageStart)
    let start = ProcessInfo.processInfo.systemUptime
    let duration = env["VP_PAIR_SECONDS"].flatMap(Double.init) ?? 35
    var localSources = Set<String>()
    var backupAdvanced = false
    var positionAtFailure = 0
    let producer = Task {
      defer { input.continuation.finish() }
      var outputFrames: Int64 = 0
      while file.framePosition < file.length {
        let time = Double(file.framePosition) / file.processingFormat.sampleRate
        if time >= duration { break }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
          frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate / 30))!
        try file.read(into: buffer)
        guard let output = converter.process(buffer)?.buffer else { continue }
        let wait = start + time - ProcessInfo.processInfo.systemUptime
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        input.continuation.yield(.init(buffer: output,
          bufferStartTime: CMTime(value: outputFrames, timescale: CMTimeScale(format.sampleRate))))
        outputFrames += Int64(output.frameLength)
      }
    }
    do {
      try await provider.start(input: input.stream) { candidate in
        let old = session.tokenIndex
        session.acceptSpeechCandidate(candidate)
        if candidate.source != "apple" { localSources.insert(candidate.source) }
        if let failureAfter, candidate.range.end.seconds < failureAfter { positionAtFailure = session.tokenIndex }
        if candidate.source == "apple", candidate.publishesPosition, session.tokenIndex > old {
          backupAdvanced = true
        }
      }
      try await producer.value
    } catch {
      print("PAIR_RUNTIME_FAILURE \(error) status=\(status)")
      producer.cancel(); input.continuation.finish(); await provider.stop(); throw error
    }
    await provider.stop()
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func cpu(_ u: rusage) -> Double {
      Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    print("PAIR_RESOURCE seconds=\(elapsed) cpuPercent=\((cpu(usage) - cpu(usageStart)) / elapsed * 100) peakRSSBytes=\(usage.ru_maxrss) sources=\(localSources.sorted()) position=\(session.tokenIndex) failurePosition=\(positionAtFailure) status=\(status)")
    XCTAssertEqual(localSources, Set(["parakeet", "unified"]))
    XCTAssertGreaterThan(session.tokenIndex, 0)
    if failureAfter != nil {
      XCTAssertTrue(status.contains("backup active"), status)
      XCTAssertTrue(backupAdvanced, "Actual Apple results must advance after the local stream fails")
      XCTAssertGreaterThan(session.tokenIndex, positionAtFailure)
    }
  }

  /// Count a hold only when speech spans at least 1.5 seconds inside a publication gap.
  static func stuckSpans(advances: [Double], words: [TimedWord], end: Double) -> [Double] {
    zip([0] + advances, advances + [end]).flatMap { start, end -> [Double] in
      var islands: [(start: Double, end: Double)] = []
      for word in words where word.end > start && word.start < end {
        let a = max(start, word.start), b = min(end, word.end)
        if let last = islands.last, a - last.end <= 0.75 {
          islands[islands.count - 1].end = max(last.end, b)
        } else { islands.append((a, b)) }
      }
      return islands.map { $0.end - $0.start }.filter { $0 > 1.5 }
    }
  }

  func testStuckSpansExcludeSilentGaps() {
    let words = [TimedWord(text: "one", start: 0, end: 0.4), TimedWord(text: "two", start: 5, end: 5.4)]
    XCTAssertEqual(Self.stuckSpans(advances: [], words: words, end: 8), [])
    XCTAssertEqual(Self.stuckSpans(advances: [2.1], words: [.init(text: "speech", start: 0, end: 2)], end: 3), [2])
  }

  /// Replays captured deliveries without running an ASR model again. No new timing claims.
  func testOfflineTuning() throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(env["VP_SPEECH_AB_TUNE"] == "1")
    let clips = try JSONDecoder().decode([ReplayClip].self,
      from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_MANIFEST"]))))
    let root = URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_RESULTS"]))
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
    var output: [[String: Any]] = []
    let aliases: [String: String]
    if let path = env["VP_SPEECH_AB_ALIASES"] {
      aliases = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } else { aliases = [:] }
    for case let url as URL in files where url.pathExtension == "json" {
      let row = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
      guard let engine = row["engine"] as? String, engine.hasPrefix("race-eou"),
        let clip = clips.first(where: { $0.id == row["clip"] as? String }),
        let deliveries = row["candidates"] as? [[String: Any]] else { continue }
      let tokens = PrompterDocument(markdown: clip.script).spokenTokens
      let alignment = WordLatency.align(WordLatency.heard([.init(locale: "en_GB", replacementID: clip.id,
        audioStart: 0, audioEnd: clip.words.last!.end, words: clip.words)]), script: tokens)
      for (label, window, limit) in [("baseline", 80, Int.max), ("window40", 40, Int.max),
        ("window20", 20, Int.max), ("advance4", 80, 4), ("advance8", 80, 8), ("advance12", 80, 12), ("aliases", 80, Int.max)] {
        var trackers: [String: RecognitionTracker] = [:]
        var published = [Double?](repeating: nil, count: tokens.count)
        var confirmed = -1
        var moves: [Double] = []
        for delivery in deliveries {
          let source = delivery["source"] as! String
          let now = delivery["time"] as! Double
          var own = trackers[source] ?? RecognitionTracker(generation: 1, matcher: .init(forwardWindow: window))
          let update = own.consume(.init(replacementID: delivery["id"] as! String, generation: 1,
            text: label == "aliases" ? Self.applyAliases(delivery["text"] as! String, aliases: aliases) : delivery["text"] as! String, isFinal: delivery["final"] as! Bool, timestamp: now,
            localeIdentifier: "en_GB", audioStart: delivery["start"] as! Double,
            audioEnd: delivery["end"] as! Double), script: tokens, allowsBackward: false)
          trackers[source] = own
          if update.status == .advanced, update.tokenIndex > confirmed, update.tokenIndex - confirmed <= limit {
            confirmed = update.tokenIndex
            moves.append(now)
            for i in 0...confirmed where published[i] == nil { published[i] = now }
          }
        }
        if label == "baseline" {
          let original = row["publishedTimes"] as! [Double]
          XCTAssertEqual(published.map { $0 ?? -1 }, original, "Offline race must reproduce SessionStore: \(url.path)")
        }
        let samples = WordLatency.latencies(display: published, spoken: alignment.spoken)
        let sorted = samples.sorted()
        let stuck = Self.stuckSpans(advances: moves, words: clip.words, end: row["wallSeconds"] as! Double)
        output.append(["engine": engine, "clip": clip.id, "run": url.path.contains("run2") ? 2 : 1,
          "variant": label, "forwardWindow": window, "maxAdvance": limit,
          "latencies": samples, "published": published.compactMap { $0 }.count,
          "scriptWords": tokens.count, "early": WordLatency.early(display: published, alignment: alignment, script: tokens).count,
          "stuckCount": stuck.count, "stuckSeconds": stuck.reduce(0, +),
          "p50": WordLatency.percentiles(samples).p50, "p90": WordLatency.percentiles(samples).p90,
          "p99": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]])
      }
    }
    XCTAssertFalse(output.isEmpty)
    try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: try XCTUnwrap(env["VP_SPEECH_AB_TUNING_OUTPUT"])))
  }

  static func applyAliases(_ text: String, aliases: [String: String]) -> String {
    var words = PrompterDocument(markdown: text).spokenTokens.map(\.normalised)
    let rules = aliases.map { (PrompterDocument(markdown: $0.key).spokenTokens.map(\.normalised),
      PrompterDocument(markdown: $0.value).spokenTokens.map(\.normalised)) }
      .filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }
    var i = 0
    while i < words.count {
      if let rule = rules.first(where: { words[i...].starts(with: $0.0) }) {
        words.replaceSubrange(i..<i + rule.0.count, with: rule.1)
        i += rule.1.count
      } else { i += 1 }
    }
    return words.joined(separator: " ")
  }

  func testAliasesMatchWholeTokensAndDoNotCascade() {
    XCTAssertEqual(Self.applyAliases("AKIMI met Akimian and Balandur", aliases: ["Akimi": "Hakimi", "Balandur": "Ballon d'Or", "Hakimi": "wrong"]), "hakimi met akimian and ballon d'or")
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

/// Benchmark-only adapters load explicit directories; they never download or touch the shared cache.
private actor ReplayRecognizer {
  let engine: String
  let provider = SpeechProvider()
  var local: (any StreamingAsrManager)?
  var paired: ReplayRecognizer?
  var race: [ReplayRecognizer] = []
  var warmContinuation: AsyncStream<AnalyzerInput>.Continuation?
  var warmTask: Task<Void, Error>?
  var callback: (@MainActor @Sendable (SpeechCandidate) -> Void)?
  init(engine: String) { self.engine = engine }
  func prepare(locales: [Locale], naturalFormat: AVAudioFormat, contextualStrings: [String], modelDirectory: URL) async throws -> AVAudioFormat {
    if engine.hasPrefix("race-") {
      let parts = engine.dropFirst(5).split(separator: "+").map(String.init)
      guard parts.count == 2 else { throw SpeechProvider.Error.unavailable }
      for part in parts {
        let child = ReplayRecognizer(engine: part)
        _ = try await child.prepare(locales: locales, naturalFormat: naturalFormat,
          contextualStrings: contextualStrings, modelDirectory: modelDirectory)
        race.append(child)
      }
      return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    }
    let ownDirectory = modelDirectory.appendingPathComponent(engine)
    let modelDirectory = FileManager.default.fileExists(atPath: ownDirectory.path) ? ownDirectory : modelDirectory
    let base = engine.replacingOccurrences(of: "both-", with: "")
    if ["apple", "apple16", "appleWarm", "transcription", "parakeet", "both", "unified320", "both-unified320"].contains(engine) {
      let format = try await provider.prepare(locales: locales, naturalFormat: naturalFormat, contextualStrings: contextualStrings,
        engine: engine.hasPrefix("apple") ? .dictation : engine == "transcription" ? .transcription : engine == "both-unified320" ? .bothUnified : engine == "unified320" ? .unified : engine == "both" ? .both : .parakeet,
        modelDirectory: modelDirectory)
      if engine == "appleWarm" {
        let stream = AsyncStream<AnalyzerInput>.makeStream()
        warmContinuation = stream.continuation
        warmTask = Task {
          try await self.provider.start(input: stream.stream) { candidate in
            Task { await self.deliver(candidate) }
          }
        }
        try await Task.sleep(for: .seconds(3))
      }
      return engine == "apple16" ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)! : format
    }
    if engine.hasPrefix("both-") {
      let child = ReplayRecognizer(engine: base)
      _ = try await child.prepare(locales: locales, naturalFormat: naturalFormat, contextualStrings: contextualStrings, modelDirectory: modelDirectory)
      paired = child
      return try await provider.prepare(locales: locales, naturalFormat: naturalFormat, contextualStrings: contextualStrings, engine: .dictation)
    }
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndNeuralEngine
    if ["unified", "unified320", "unified640", "unified1120"].contains(base) {
      let manager = StreamingUnifiedAsrManager(configuration: config, config: .init(chunkFrames: base == "unified320" ? 2 : 7, rightFrames: base == "unified320" ? 2 : base == "unified1120" ? 7 : 1))
      try await manager.loadModels(from: modelDirectory)
      local = manager
    } else if base == "eou320" || base == "eou160" {
      let manager = StreamingEouAsrManager(configuration: config, chunkSize: base == "eou320" ? .ms320 : .ms160)
      try await manager.loadModels(from: modelDirectory)
      local = manager
    } else {
      guard ["nemotron560", "nemotron1120", "nemotron2240"].contains(base) else { throw SpeechProvider.Error.unavailable }
      let manager = StreamingNemotronAsrManager(configuration: config)
      try await manager.loadModels(from: modelDirectory)
      local = manager
    }
    return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
  }
  func start(input: AsyncStream<AnalyzerInput>, onCandidate: @escaping @MainActor @Sendable (SpeechCandidate) -> Void) async throws {
    if !race.isEmpty {
      let streams = race.map { _ in AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy:
        ProcessInfo.processInfo.environment["VP_SPEECH_AB_UNPACED"] == "1" ? .unbounded : .bufferingNewest(1024)) }
      try await withThrowingTaskGroup(of: Void.self) { group in
        for (child, stream) in zip(race, streams) {
          group.addTask { try await child.start(input: stream.stream, onCandidate: onCandidate) }
        }
        group.addTask {
          defer { streams.forEach { $0.continuation.finish() } }
          for await item in input {
            for stream in streams {
              if case .dropped = stream.continuation.yield(item) { throw SpeechProvider.Error.analysisFailed("Replay consumer fell behind") }
            }
          }
        }
        do { while try await group.next() != nil {} }
        catch {
          streams.forEach { $0.continuation.finish() }; group.cancelAll()
          for child in race { await child.stop() }
          throw error
        }
      }
    } else if let warmContinuation, let warmTask {
      callback = onCandidate
      for await item in input { warmContinuation.yield(item) }
      warmContinuation.finish()
      try await warmTask.value
    } else if let paired {
      let a = AsyncStream<AnalyzerInput>.makeStream(), b = AsyncStream<AnalyzerInput>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.provider.start(input: a.stream, onCandidate: onCandidate) }
        group.addTask { try await paired.start(input: b.stream, onCandidate: onCandidate) }
        group.addTask {
          defer { a.continuation.finish(); b.continuation.finish() }
          for await item in input { a.continuation.yield(item); b.continuation.yield(item) }
        }
        do { while try await group.next() != nil {} }
        catch {
          a.continuation.finish(); b.continuation.finish(); group.cancelAll()
          await self.provider.stop(); await paired.stop()
          throw error
        }
      }
    } else if let local {
      var previous = "", end = CMTime.zero
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
      let converter = AudioCapture(device: .init(id: 0, uid: "replay", name: "Replay"), outputFormat: format)
      var prepared = false
      for await input in input {
        if !prepared { try converter.prepareConverter(sampleRate: input.buffer.format.sampleRate); prepared = true }
        let buffer = try XCTUnwrap(converter.process(input.buffer)?.buffer)
        try await local.appendAudio(buffer)
        try await local.processBufferedAudio()
        end = CMTimeAdd(input.bufferStartTime ?? end, CMTime(seconds: Double(input.buffer.frameLength) / input.buffer.format.sampleRate, preferredTimescale: 16000))
        let text = await local.getPartialTranscript()
        if var candidate = ParakeetSpeechStream.candidate(text: text, previous: previous, generation: 1, end: end) {
          previous = text; candidate.source = engine
          await onCandidate(candidate)
        }
      }
      let text = try await local.finish()
      if var candidate = ParakeetSpeechStream.candidate(text: text, previous: previous, generation: 1, end: end) {
        candidate.source = engine; await onCandidate(candidate)
      }
    } else { try await provider.start(input: input, onCandidate: onCandidate) }
  }
  func updateContext(_ strings: [String]) async throws {
    try await provider.updateContext(strings)
    for child in race { try await child.updateContext(strings) }
    try await paired?.updateContext(strings)
  }
  func deliver(_ candidate: SpeechCandidate) async { await callback?(candidate) }
  func stop() async { for child in race { await child.stop() }; await provider.stop(); await paired?.stop(); await local?.cleanup() }
}
