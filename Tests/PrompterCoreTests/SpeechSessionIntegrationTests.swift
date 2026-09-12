@preconcurrency import AVFoundation
import AppKit
import Foundation
import Speech
import XCTest

@testable import JuniorPrompter
import PrompterCore

@MainActor
final class SpeechSessionIntegrationTests: XCTestCase {
  private struct ReplayEvent: Encodable {
    let type: String
    let generation: UInt64?
    let replacementID: String?
    var identitySource: String? = nil
    let wallSecondsSinceFirstAudio: Double?
    let audioStart: Double?
    let audioEnd: Double?
    let recognitionDeliveryLag: Double?
    let tokenIndex: Int?
    let acceptedWords: Int?
    let droppedBuffers: Int?
    let submittedBuffers: Int?
    let isFinal: Bool?
    let locale: String?
    let text: String?
    var progressEvents: Int? = nil
    var largestProgressHoldSeconds: Double? = nil
    var renderedOffsetY: Double? = nil
    var renderedOffsetSource: String? = nil
  }

  @MainActor private final class ReplayLedger {
    var events: [ReplayEvent] = []
    var firstAudioWall: TimeInterval?
    var submittedBuffers = 0
    var droppedBuffers = 0
  }

  private func scrollView(in view: NSView?) -> NSScrollView? {
    guard let view else { return nil }
    if let scrollView = view as? NSScrollView { return scrollView }
    return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
  }

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
    let engine: SpeechProvider.Engine = ProcessInfo.processInfo.environment[
      "JUNIORPROMPTER_SPEECH_REPLAY_ENGINE"
    ] == "dictation" ? .dictation : .transcription
    let format = try await provider.prepare(
      naturalFormat: audio.processingFormat,
      contextualStrings: engine == .dictation ? SpeechProvider.contextualPhrases(from: expected) : [], engine: engine)
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

  func testActualWAVThroughProductionProviderAndSession() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["JUNIORPROMPTER_RUN_ACTUAL_SPEECH_REPLAY"] == "1")
    guard let logPath = environment["JUNIORPROMPTER_SPEECH_REPLAY_LOG_PATH"] else {
      throw XCTSkip("Set JUNIORPROMPTER_SPEECH_REPLAY_LOG_PATH to keep recognition logs outside the repository.")
    }
    let wavURL = URL(fileURLWithPath: environment[
      "JUNIORPROMPTER_SPEECH_REPLAY_WAV"
    ] ?? "/Users/junior.nkanabassi/Downloads/JuniorPrompter v0.3.0 (9) Test Script Reading.wav")
    let scriptURL = URL(fileURLWithPath: environment[
      "JUNIORPROMPTER_SPEECH_REPLAY_SCRIPT"
    ] ?? "/Users/junior.nkanabassi/Documents/JuniorOS/05 Other/Codex Workspace/JuniorPrompter-research-20260905/demo-test-script-exact.md")
    let startOffset = max(0, Double(environment["JUNIORPROMPTER_SPEECH_REPLAY_START_OFFSET"] ?? "0") ?? 0)
    let logURL = URL(fileURLWithPath: logPath)
    guard !FileManager.default.fileExists(atPath: logURL.path) else {
      XCTFail("Refusing to overwrite replay log at \(logURL.path). Choose a new path.")
      return
    }
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    let engine: SpeechProvider.Engine = environment["JUNIORPROMPTER_SPEECH_REPLAY_ENGINE"] == "dictation"
      ? .dictation : .transcription
    let rendersPresenter = environment["JUNIORPROMPTER_RENDERED_REPLAY"] == "1"
    let session: SessionStore
    var renderedPanel: NSPanel?
    var renderedStore: AppStore?
    var renderedDirectory: URL?
    var renderedDefaults: (suiteName: String, defaults: UserDefaults)?
    var presenterStayedVisible = true
    if rendersPresenter {
      guard let screen = NSScreen.screens.first(where: { $0.localizedName == "Prompter XL" }) else {
        throw XCTSkip("Rendered replay requires the Prompter XL display.")
      }
      let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("juniorprompter-rendered-replay-\(UUID().uuidString)", isDirectory: true)
      let suiteName = "JuniorPrompter.rendered-replay.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suiteName)!
      defaults.removePersistentDomain(forName: suiteName)
      let store = AppStore(arguments: ["tests", "--data-directory", directory.path], defaults: defaults)
      guard let library = store.library else {
        return XCTFail("Rendered replay could not create its disposable library.")
      }
      let record = try await library.create(title: "Rendered replay", markdown: script)
      await store.reload()
      store.selectedID = record.id
      store.settings.mode = "Voice"
      PresenterController.shared.present(store: store, on: screen)
      guard let panel = NSApp.windows.first(where: { $0.title == "JuniorPrompter · Rendered replay" }) as? NSPanel else {
        return XCTFail("Rendered replay presenter panel was not created.")
      }
      panel.sharingType = .readOnly
      renderedPanel = panel
      renderedStore = store
      renderedDirectory = directory
      renderedDefaults = (suiteName, defaults)
      session = store.session
    } else {
      session = SessionStore()
      let record = ScriptRecord(metadata: .init(title: "Actual replay", fileName: "actual-replay.md"), markdown: script)
      var settings = PrompterSettings(); settings.mode = "Voice"
      session.present(record: record, settings: settings)
    }
    defer {
      session.pause()
      renderedPanel?.contentView = nil
      PresenterController.shared.closeNow()
      renderedStore = nil
      if let renderedDirectory { try? FileManager.default.removeItem(at: renderedDirectory) }
      if let renderedDefaults { renderedDefaults.defaults.removePersistentDomain(forName: renderedDefaults.suiteName) }
    }
    session.play(captureAudio: false)

    let ledger = ReplayLedger()
    defer {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      do {
        try FileManager.default.createDirectory(
          at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try ledger.events.map { event in
          String(decoding: try encoder.encode(event), as: UTF8.self)
        }.joined(separator: "\n")
        try Data((lines + "\n").utf8).write(to: logURL, options: .withoutOverwriting)
      } catch {
        XCTFail("Could not write replay log at \(logURL.path): \(error.localizedDescription)")
      }
    }

    let provider = SpeechProvider()
    let audio = try AVAudioFile(forReading: wavURL)
    let startFrame = min(
      audio.length, AVAudioFramePosition((startOffset * audio.processingFormat.sampleRate).rounded()))
    audio.framePosition = startFrame
    let actualStartOffset = Double(startFrame) / audio.processingFormat.sampleRate
    let format = try await provider.prepare(
      naturalFormat: audio.processingFormat,
      contextualStrings: engine == .dictation ? SpeechProvider.contextualPhrases(from: script) : [], engine: engine)
    let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(20))
    let monitor = Task { @MainActor in
      var previousToken = session.tokenIndex
      var previousSeekRevision = session.seekRevision
      var previousRenderedOffset: Double?
      while !Task.isCancelled {
        let elapsed = ledger.firstAudioWall.map { ProcessInfo.processInfo.systemUptime - $0 }
        if let renderedPanel, let scrollView = scrollView(in: renderedPanel.contentView) {
          presenterStayedVisible = presenterStayedVisible && renderedPanel.isVisible
          let presentationOffset = scrollView.contentView.layer?.presentation()?.bounds.origin.y
          let offset = Double(presentationOffset ?? scrollView.contentView.bounds.origin.y)
          if previousRenderedOffset != offset {
            ledger.events.append(.init(
              type: "rendered_scroll_offset", generation: nil, replacementID: nil,
              wallSecondsSinceFirstAudio: elapsed,
              audioStart: nil, audioEnd: nil, recognitionDeliveryLag: nil,
              tokenIndex: session.tokenIndex, acceptedWords: session.acceptedWords,
              droppedBuffers: nil, submittedBuffers: nil, isFinal: nil, locale: nil,
              text: "Observed presenter scroll movement; this is UI cadence evidence, not ASR-to-render latency.",
              renderedOffsetY: offset,
              renderedOffsetSource: presentationOffset == nil ? "model_clip_bounds" : "presentation_layer_bounds"))
            previousRenderedOffset = offset
          }
        }
        if session.tokenIndex != previousToken {
          ledger.events.append(.init(
            type: "session_token_progress", generation: nil, replacementID: nil,
            wallSecondsSinceFirstAudio: elapsed,
            audioStart: nil, audioEnd: nil, recognitionDeliveryLag: nil,
            tokenIndex: session.tokenIndex, acceptedWords: session.acceptedWords,
            droppedBuffers: nil, submittedBuffers: nil, isFinal: nil, locale: nil, text: nil))
          previousToken = session.tokenIndex
        }
        if session.seekRevision != previousSeekRevision {
          ledger.events.append(.init(
            type: "unexpected_seek", generation: nil, replacementID: nil,
            wallSecondsSinceFirstAudio: elapsed,
            audioStart: nil, audioEnd: nil, recognitionDeliveryLag: nil,
            tokenIndex: session.tokenIndex, acceptedWords: session.acceptedWords,
            droppedBuffers: nil, submittedBuffers: nil, isFinal: nil, locale: nil,
            text: "Untouched replay changed the presenter seek revision."))
          previousSeekRevision = session.seekRevision
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    defer { monitor.cancel() }
    let producer = Task { @MainActor in
      defer { stream.continuation.finish() }
      let converter = try XCTUnwrap(AVAudioConverter(from: audio.processingFormat, to: format))
      var outputFrame: Int64 = 0
      while audio.framePosition < audio.length {
        let source = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1_600)!
        try audio.read(into: source, frameCount: 1_600)
        guard source.frameLength > 0 else { break }
        let capacity = AVAudioFrameCount(
          ceil(Double(source.frameLength) * format.sampleRate / audio.processingFormat.sampleRate)) + 1
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var used = false; var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
          if used { status.pointee = .noDataNow; return nil }
          used = true; status.pointee = .haveData; return source
        }
        if let conversionError { throw conversionError }
        let delivery = ProcessInfo.processInfo.systemUptime
        if ledger.firstAudioWall == nil { ledger.firstAudioWall = delivery }
        ledger.submittedBuffers += 1
        if case .dropped = stream.continuation.yield(.init(
          buffer: output,
          bufferStartTime: CMTime(value: outputFrame, timescale: CMTimeScale(format.sampleRate))))
        {
          ledger.droppedBuffers += 1
        }
        outputFrame += Int64(output.frameLength)
        let elapsedAudio = Double(audio.framePosition - startFrame) / audio.processingFormat.sampleRate
        let target = ledger.firstAudioWall! + elapsedAudio
        let remaining = target - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
      }
    }
    defer { producer.cancel() }
    let providerTask = Task {
      try await provider.start(input: stream.stream) { candidate in
        let delivered = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
          let elapsed = ledger.firstAudioWall.map { delivered - $0 }
          ledger.events.append(.init(
            type: "candidate", generation: candidate.generation, replacementID: candidate.replacementID,
            identitySource: engine == .dictation
              ? "SpeechProvider deterministic Dictation range key; DictationTranscriber.Result has no native replacement ID or finality."
              : "SpeechProvider",
            wallSecondsSinceFirstAudio: elapsed,
            audioStart: candidate.range.start.seconds, audioEnd: candidate.range.end.seconds,
            recognitionDeliveryLag: elapsed.map { $0 - candidate.range.end.seconds },
            tokenIndex: session.tokenIndex,
            acceptedWords: session.acceptedWords, droppedBuffers: nil, submittedBuffers: nil,
            isFinal: candidate.isFinal, locale: candidate.locale.identifier, text: candidate.text))
          session.acceptSpeechCandidate(candidate)
        }
      }
    }
    let timeout = Double(audio.length - startFrame) / audio.processingFormat.sampleRate + 30
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await providerTask.value }
        group.addTask {
          try await Task.sleep(for: .seconds(timeout))
          throw NSError(domain: "SpeechSessionIntegration", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Provider did not finish within \(timeout) seconds."
          ])
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
      try await producer.value
      await provider.stop()
    } catch {
      producer.cancel()
      providerTask.cancel()
      await provider.stop()
      throw error
    }
    try await Task.sleep(for: .milliseconds(200))
    let progress = ledger.events.filter { $0.type == "session_token_progress" }
    XCTAssertEqual(session.seekRevision, 0, "Untouched replay changed the presenter seek revision. See \(logURL.path).")
    let largestHold = zip(progress, progress.dropFirst()).map {
      ($1.wallSecondsSinceFirstAudio ?? 0) - ($0.wallSecondsSinceFirstAudio ?? 0)
    }.max() ?? 0
    if rendersPresenter {
      XCTAssertTrue(presenterStayedVisible, "Rendered presenter was not visible throughout sampling. See \(logURL.path).")
      let renderedOffsets = Set(ledger.events.compactMap { event in
        event.type == "rendered_scroll_offset" ? event.renderedOffsetY : nil
      })
      XCTAssertGreaterThan(
        renderedOffsets.count, 1,
        "Rendered replay did not observe presenter scroll movement. See \(logURL.path).")
    }
    ledger.events.append(.init(
      type: "summary", generation: nil, replacementID: nil,
      wallSecondsSinceFirstAudio: ledger.firstAudioWall.map {
        ProcessInfo.processInfo.systemUptime - $0
      }, audioStart: actualStartOffset, audioEnd: Double(audio.length) / audio.processingFormat.sampleRate,
      recognitionDeliveryLag: nil, tokenIndex: session.tokenIndex,
      acceptedWords: session.acceptedWords, droppedBuffers: ledger.droppedBuffers,
      submittedBuffers: ledger.submittedBuffers, isFinal: nil, locale: nil,
      text: "\(engine == .dictation ? "DictationTranscriber contextual" : "SpeechTranscriber") replay. \(rendersPresenter ? "Rendered scroll offsets record UI cadence only, not ASR-to-render latency." : "Recognition delivery lag and session token progress are measured separately; rendered UI latency is not measured by this test.")",
      progressEvents: progress.count, largestProgressHoldSeconds: largestHold))
    XCTAssertEqual(
      session.tokenIndex, session.document.spokenTokens.count - 1,
      "Replay ended at token \(session.tokenIndex)/\(session.document.spokenTokens.count - 1). See \(logURL.path).")
    XCTAssertEqual(
      ledger.droppedBuffers, 0,
      "Replay dropped \(ledger.droppedBuffers) input buffers. See \(logURL.path).")
  }

}
