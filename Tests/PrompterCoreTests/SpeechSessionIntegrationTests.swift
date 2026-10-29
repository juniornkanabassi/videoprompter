@preconcurrency import AVFoundation
import AppKit
import CoreText
import Foundation
import Speech
import XCTest

@testable import VideoPrompter
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
    var acceptanceLatencySeconds: Double? = nil
    var words: [TimedWord]? = nil
    var publishedSeconds: Double? = nil
  }

  @MainActor private final class ReplayLedger {
    var events: [ReplayEvent] = []
    var firstAudioWall: TimeInterval?
    var submittedBuffers = 0
    var droppedBuffers = 0
    var acceptanceLatencies: [Double] = []
    /// First wall instant each token was published as confirmed, and first instant it was painted dim.
    var published: [Double?] = []
    var painted: [Double?] = []
    var dimObserver: NSObjectProtocol?
    var tokenEnds: [Int] = []
  }

  /// How far into the script the presenter's text storage is painted dim: the last token whose text
  /// ends at or before the last dimmed character. Each token is looked for inside its own passage
  /// (passages render separated by a blank line), so this reads what is on the page rather than the
  /// session's state; a token the page does not show (a list number) takes its predecessor's end.
  private static func paintedThrough(_ storage: NSTextStorage, document: PrompterDocument, opacity: Double, ends: inout [Int]) -> Int {
    let text = storage.string as NSString
    let passages = text.components(separatedBy: "\n\n")
    if ends.isEmpty, passages.count == document.blocks.count {
      var start = 0
      for (passage, block) in zip(passages, document.blocks) {
        let range = NSRange(location: start, length: (passage as NSString).length)
        var cursor = start
        for token in block.spokenTokens {
          let found = text.range(of: token.text, options: [.caseInsensitive, .diacriticInsensitive],
            range: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
          if found.location != NSNotFound { cursor = NSMaxRange(found) }
          ends.append(cursor)
        }
        start = NSMaxRange(range) + 2
      }
    }
    var lastDimmed = 0
    storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      if let colour = value as? NSColor, colour.alphaComponent < opacity * 0.7 { lastDimmed = max(lastDimmed, NSMaxRange(range)) }
    }
    return ends.lastIndex { $0 <= lastDimmed } ?? -1
  }

  private func scrollView(in view: NSView?) -> NSScrollView? {
    guard let view else { return nil }
    if let scrollView = view as? NSScrollView { return scrollView }
    return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
  }

  func testBilingualFixtureThroughProductionProviderAndSession() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VIDEOPROMPTER_RUN_SPEECH_INTEGRATION"] == "1")
    let root = researchFolder.appendingPathComponent("speech-fixtures")
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
      "VIDEOPROMPTER_SPEECH_REPLAY_ENGINE"
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
    try await provider.start(input: stream.stream) { candidate in session.acceptSpeechCandidate(candidate) }
    try await producer.value
    try await Task.sleep(for: .milliseconds(150))
    print("Speech integration acceptedWords=\(session.acceptedWords) finalTokenIndex=\(session.tokenIndex)/\(session.document.spokenTokens.count - 1)")
    XCTAssertGreaterThan(session.acceptedWords, 0)
    XCTAssertGreaterThanOrEqual(session.tokenIndex, session.document.spokenTokens.count - 2)
  }

  func testActualWAVThroughProductionProviderAndSession() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["VIDEOPROMPTER_RUN_ACTUAL_SPEECH_REPLAY"] == "1")
    try await replayRecording(
      environment["VIDEOPROMPTER_SPEECH_REPLAY_WAV"].map { URL(fileURLWithPath: $0) }
        ?? acceptanceInputs.appendingPathComponent("JuniorPrompter v0.3.0 (9) Test Script Reading.wav"),
      script: URL(fileURLWithPath: environment["VIDEOPROMPTER_SPEECH_REPLAY_SCRIPT"]
        ?? researchFolder.appendingPathComponent("demo-test-script-exact.md").path))
  }

  /// The opt-in replays read recordings kept outside the repository, under VIDEOPROMPTER_JUNIOROS
  /// (default ~/Documents/JuniorOS).
  private let juniorOS = ProcessInfo.processInfo.environment["VIDEOPROMPTER_JUNIOROS"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/JuniorOS")
  private var researchFolder: URL { juniorOS.appendingPathComponent("05 Other/Codex Workspace/JuniorPrompter-research-20260905") }
  private var acceptanceInputs: URL { juniorOS.appendingPathComponent("02 Projects/Development/Video Prompter/00 Project State/Acceptance inputs") }

  /// Short 173: six minutes of natural reading with mistakes, false starts, going back to re-read,
  /// hard names and numbers. Same production path and the same environment as the replay above.
  func testShort173ReadingThroughProductionProviderAndSession() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VIDEOPROMPTER_RUN_173_REPLAY"] == "1")
    // The spaces after both dashes in the file name are non-breaking, so find it rather than spell it.
    let wav = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: acceptanceInputs, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix("173") && $0.pathExtension == "wav" })
    try await replayRecording(wav, script: acceptanceInputs.appendingPathComponent("173 script.md"))
  }

  /// Short 172: an edited rough cut with the pauses removed, so the precision case: names, accents,
  /// curly apostrophes, a Markdown title line and a numbered list.
  func testShort172ReadingThroughProductionProviderAndSession() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VIDEOPROMPTER_RUN_172_REPLAY"] == "1")
    try await replayRecording(
      researchFolder.appendingPathComponent("172-rough-cut-reading.wav"),
      script: acceptanceInputs.appendingPathComponent("172 script.md"))
  }

  private func replayRecording(_ wavURL: URL, script scriptURL: URL) async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let logPath = environment["VIDEOPROMPTER_SPEECH_REPLAY_LOG_PATH"] else {
      throw XCTSkip("Set VIDEOPROMPTER_SPEECH_REPLAY_LOG_PATH to keep recognition logs outside the repository.")
    }
    let startOffset = max(0, Double(environment["VIDEOPROMPTER_SPEECH_REPLAY_START_OFFSET"] ?? "0") ?? 0)
    let logURL = URL(fileURLWithPath: logPath)
    guard !FileManager.default.fileExists(atPath: logURL.path) else {
      XCTFail("Refusing to overwrite replay log at \(logURL.path). Choose a new path.")
      return
    }
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    let engine: SpeechProvider.Engine = environment["VIDEOPROMPTER_SPEECH_REPLAY_ENGINE"] == "dictation"
      ? .dictation : .transcription
    let rendersPresenter = environment["VIDEOPROMPTER_RENDERED_REPLAY"] == "1"
    let replayScrollBack = environment["VIDEOPROMPTER_REPLAY_SCROLL_BACK"] == "1"
    let replayReread = environment["VIDEOPROMPTER_REPLAY_REREAD"] == "1"
    try XCTSkipUnless(!replayScrollBack || rendersPresenter,
      "Scroll-back replay requires VIDEOPROMPTER_RENDERED_REPLAY=1.")
    try XCTSkipUnless(!replayReread || (replayScrollBack && rendersPresenter && startOffset == 0),
      "Re-read replay requires rendered scroll-back from the full recording.")
    XCTAssertFalse(replayScrollBack && startOffset != 0,
      "Scroll-back replay must use the full recording from offset 0.")
    let session: SessionStore
    var renderedPanel: NSPanel?
    var renderedStore: AppStore?
    var renderedDirectory: URL?
    var renderedDefaults: (suiteName: String, defaults: UserDefaults)?
    var presenterStayedVisible = true
    var scrollBackTriggered = false
    var intentionalSeekRevision: Int?
    var acceptedWordsAtScrollBack: Int?
    var providerGenerationAtScrollBack: UInt64?
    var progressedAfterScrollBack = false
    var tokenBeforeScrollBack: Int?
    var tokenAfterScrollBack: Int?
    var sourceRewindFrame: AVAudioFramePosition?
    var sourceRewindApplied = false
    var streamTimeAtSourceRewind: Double?
    var acceptedWordsAtSourceRewind: Int?
    var rereadProgressedIntoPriorRange = false
    if rendersPresenter {
      let fontRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
      for file in ["Lexend-Variable.ttf", "LexendDeca-Variable.ttf"] {
        CTFontManagerRegisterFontsForURL(fontRoot.appendingPathComponent(file) as CFURL, .process, nil)
      }
      XCTAssertNotNil(NSFont(name: "Lexend Deca", size: 18), "Rendered acceptance must not silently use a system fallback.")
      guard let screen = NSScreen.screens.first(where: { $0.localizedName == "Prompter XL" }) else {
        throw XCTSkip("Rendered replay requires the Prompter XL display.")
      }
      let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("videoprompter-rendered-replay-\(UUID().uuidString)", isDirectory: true)
      let suiteName = "VideoPrompter.rendered-replay.\(UUID().uuidString)"
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
      guard let panel = NSApp.windows.first(where: { $0.title == "Video Prompter · Rendered replay" }) as? NSPanel else {
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
    let document = session.document
    let tokens = document.spokenTokens
    ledger.published = Array(repeating: nil, count: tokens.count)
    ledger.painted = Array(repeating: nil, count: tokens.count)
    // Exact publish instants: the sink runs synchronously inside the property's willSet.
    let confirmedSink = session.$lastConfirmedTokenIndex.sink { value in
      MainActor.assumeIsolated {
        guard let value, let first = ledger.firstAudioWall else { return }
        let now = ProcessInfo.processInfo.systemUptime - first
        for token in 0...min(value, tokens.count - 1) where ledger.published[token] == nil { ledger.published[token] = now }
      }
    }
    defer {
      confirmedSink.cancel()
      if let observer = ledger.dimObserver { NotificationCenter.default.removeObserver(observer) }
    }
    let textOpacity = renderedStore?.settings.textOpacity ?? 1
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
    // VIDEOPROMPTER_SPEECH_REPLAY_LOCALES="en-GB" compares one recogniser with the Mixed pair.
    let locales = environment["VIDEOPROMPTER_SPEECH_REPLAY_LOCALES"].map {
      $0.split(separator: ",").map { Locale(identifier: String($0)) }
    } ?? [Locale(identifier: "en-GB"), Locale(identifier: "fr-FR")]
    let format = try await provider.prepare(
      locales: locales, naturalFormat: audio.processingFormat,
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
          if ledger.dimObserver == nil, let storage = (scrollView.documentView as? NSTextView)?.textStorage {
            // Posted synchronously from the presenter's own attribute write, so this is the dim instant.
            nonisolated(unsafe) let storage = storage
            ledger.dimObserver = NotificationCenter.default.addObserver(
              forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
            ) { _ in
              MainActor.assumeIsolated {
                guard let first = ledger.firstAudioWall else { return }
                let now = ProcessInfo.processInfo.systemUptime - first
                let through = Self.paintedThrough(storage, document: document, opacity: textOpacity, ends: &ledger.tokenEnds)
                guard through >= 0 else { return }
                for token in 0...through where ledger.painted[token] == nil { ledger.painted[token] = now }
              }
            }
          }
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
        if replayScrollBack, !scrollBackTriggered, elapsed ?? 0 >= 35,
          let renderedPanel, let scrollView = scrollView(in: renderedPanel.contentView),
          scrollView.contentView.bounds.origin.y > 24, session.acceptedWords > 0
        {
          providerGenerationAtScrollBack = ledger.events.reversed().first(where: { $0.type == "candidate" })?.generation
          acceptedWordsAtScrollBack = session.acceptedWords
          let tokenBeforeScroll = session.tokenIndex
          tokenBeforeScrollBack = tokenBeforeScroll
          if replayReread {
            sourceRewindFrame = AVAudioFramePosition((31 * audio.processingFormat.sampleRate).rounded())
          }
          let origin = scrollView.contentView.bounds.origin
          NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
          scrollView.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: max(0, origin.y - 100)))
          scrollView.reflectScrolledClipView(scrollView.contentView)
          NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
          NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
          XCTAssertLessThan(session.tokenIndex, tokenBeforeScroll, "Scroll-back must actually move the reading anchor backwards.")
          intentionalSeekRevision = session.seekRevision
          tokenAfterScrollBack = session.tokenIndex
          scrollBackTriggered = true
          ledger.events.append(.init(
            type: "intentional_scroll_seek", generation: providerGenerationAtScrollBack, replacementID: nil,
            wallSecondsSinceFirstAudio: elapsed, audioStart: nil, audioEnd: nil, recognitionDeliveryLag: nil,
            tokenIndex: session.tokenIndex, acceptedWords: session.acceptedWords,
            droppedBuffers: nil, submittedBuffers: nil, isFinal: nil, locale: nil,
            text: replayReread
              ? "Programmatic native live-scroll lifecycle requested an AVAudioFile rewind to 31 seconds; provider stream time stays monotonic."
              : "Programmatic native live-scroll lifecycle exercised the presenter reanchor; not hardware wheel evidence."))
          previousSeekRevision = session.seekRevision
        }
        if scrollBackTriggered, let acceptedWordsAtScrollBack,
          session.acceptedWords > acceptedWordsAtScrollBack
        { progressedAfterScrollBack = true }
        if sourceRewindApplied, let tokenBeforeScrollBack, let tokenAfterScrollBack,
          let streamTimeAtSourceRewind, let acceptedWordsAtSourceRewind,
          session.acceptedWords > acceptedWordsAtSourceRewind,
          ledger.events.contains(where: {
            $0.type == "candidate" && ($0.audioEnd ?? -.infinity) >= streamTimeAtSourceRewind + 0.5
          }),
          session.tokenIndex > tokenAfterScrollBack, session.tokenIndex < tokenBeforeScrollBack
        { rereadProgressedIntoPriorRange = true }
        if session.tokenIndex != previousToken {
          // Spoken-word-to-dim latency: the presenter dims at this instant, and the newest
          // candidate's audioEnd is how far into the recording the recogniser had listened.
          let latestCandidateAudioEnd = ledger.events.reversed().first(where: { $0.type == "candidate" })?.audioEnd
          var latency: Double?
          if let elapsed, let latestCandidateAudioEnd { latency = elapsed - latestCandidateAudioEnd }
          if let latency, session.tokenIndex > previousToken { ledger.acceptanceLatencies.append(latency) }
          ledger.events.append(.init(
            type: "session_token_progress", generation: nil, replacementID: nil,
            wallSecondsSinceFirstAudio: elapsed,
            audioStart: nil, audioEnd: latestCandidateAudioEnd, recognitionDeliveryLag: nil,
            tokenIndex: session.tokenIndex, acceptedWords: session.acceptedWords,
            droppedBuffers: nil, submittedBuffers: nil, isFinal: nil, locale: nil, text: nil,
            acceptanceLatencySeconds: latency))
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
    // 1600 frames (33 ms at 48 kHz) by default. The live input tap cannot deliver less than 100 ms
    // (AVAudioNode.installTap), so 4800 here reproduces what the microphone path feeds the recogniser.
    let chunk = AVAudioFrameCount(environment["VIDEOPROMPTER_REPLAY_CHUNK_FRAMES"] ?? "") ?? 1_600
    let producer = Task { @MainActor in
      defer { stream.continuation.finish() }
      let converter = try XCTUnwrap(AVAudioConverter(from: audio.processingFormat, to: format))
      var outputFrame: Int64 = 0
      while audio.framePosition < audio.length {
        if replayReread, let frame = sourceRewindFrame, !sourceRewindApplied {
          audio.framePosition = min(audio.length, frame)
          sourceRewindApplied = true
          streamTimeAtSourceRewind = Double(outputFrame) / format.sampleRate
          acceptedWordsAtSourceRewind = session.acceptedWords
          ledger.events.append(.init(
            type: "source_rewind", generation: providerGenerationAtScrollBack, replacementID: nil,
            wallSecondsSinceFirstAudio: ledger.firstAudioWall.map { ProcessInfo.processInfo.systemUptime - $0 },
            audioStart: Double(audio.framePosition) / audio.processingFormat.sampleRate,
            audioEnd: nil, recognitionDeliveryLag: nil, tokenIndex: session.tokenIndex,
            acceptedWords: session.acceptedWords, droppedBuffers: nil, submittedBuffers: nil,
            isFinal: nil, locale: nil,
            text: "AVAudioFile source rewound while AnalyzerInput bufferStartTime continued monotonically from \(streamTimeAtSourceRewind ?? 0) seconds."))
        }
        let source = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk)!
        try audio.read(into: source, frameCount: chunk)
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
        session.noteSubmittedAudioEnd(through: Double(outputFrame) / format.sampleRate)
        let elapsedAudio = Double(outputFrame) / format.sampleRate
        let target = ledger.firstAudioWall! + elapsedAudio
        let remaining = target - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
      }
    }
    defer { producer.cancel() }
    let providerTask = Task {
      try await provider.start(input: stream.stream) { candidate in
        // Delivered on the main actor, exactly as production receives it.
        let delivered = ProcessInfo.processInfo.systemUptime
        do {
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
            isFinal: candidate.isFinal, locale: candidate.locale.identifier, text: candidate.text,
            words: candidate.transcript.runs.compactMap { run in
              run.audioTimeRange.map {
                TimedWord(text: String(candidate.transcript[run.range].characters), start: $0.start.seconds, end: $0.end.seconds)
              }
            }))
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
    if replayScrollBack {
      XCTAssertTrue(scrollBackTriggered, "Replay did not reach the intentional live scroll. See \(logURL.path).")
      XCTAssertGreaterThan(intentionalSeekRevision ?? 0, 0,
        "Live-scroll notification did not reanchor the session. See \(logURL.path).")
      XCTAssertEqual(session.seekRevision, intentionalSeekRevision,
        "Replay changed the seek revision after the intentional reanchor. See \(logURL.path).")
      XCTAssertTrue(progressedAfterScrollBack,
        "Production recognition did not advance after the intentional reanchor. See \(logURL.path).")
      if replayReread {
        XCTAssertTrue(sourceRewindApplied, "Replay did not apply the requested source rewind. See \(logURL.path).")
        XCTAssertTrue(rereadProgressedIntoPriorRange,
          "Recognition did not re-read through the pre-seek token range. See \(logURL.path).")
      }
      if let providerGenerationAtScrollBack,
        let scrollTime = ledger.events.first(where: { $0.type == "intentional_scroll_seek" })?.wallSecondsSinceFirstAudio
      {
        let candidateGenerationsAfterScroll = Set(ledger.events.compactMap { event -> UInt64? in
          guard event.type == "candidate", (event.wallSecondsSinceFirstAudio ?? 0) > scrollTime else { return nil }
          return event.generation
        })
        XCTAssertEqual(candidateGenerationsAfterScroll, [providerGenerationAtScrollBack],
          "Provider generation changed or stopped after the intentional reanchor. See \(logURL.path).")
      }
    } else {
      XCTAssertEqual(session.seekRevision, 0, "Untouched replay changed the presenter seek revision. See \(logURL.path).")
    }
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
    let latencies = ledger.acceptanceLatencies.sorted()
    if !latencies.isEmpty {
      let median = latencies[latencies.count / 2]
      let p90 = latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.9))]
      print("Acceptance latency (dim instant minus recognised audio end): n=\(latencies.count) median=\(median)s p90=\(p90)s max=\(latencies.last!)s")
      if let bound = Double(environment["VIDEOPROMPTER_MAX_ACCEPTANCE_LATENCY_P90"] ?? "") {
        XCTAssertLessThanOrEqual(p90, bound,
          "Spoken-word-to-dim latency regressed: p90 \(p90)s over \(bound)s. See \(logURL.path).")
      }
    }
    if !replayScrollBack {
      let revisions = ledger.events.compactMap { event -> (WordLatency.Revision, Double?)? in
        guard event.type == "candidate", let locale = event.locale, let id = event.replacementID,
          let start = event.audioStart, let end = event.audioEnd, let text = event.text else { return nil }
        return (.init(locale: locale, replacementID: id, audioStart: start, audioEnd: end, words: event.words ?? [],
          tail: PrompterDocument(markdown: text).spokenTokens.suffix(3).map(\.normalised)), event.wallSecondsSinceFirstAudio)
      }
      let alignment = WordLatency.align(revisions.map(\.0), arrivals: revisions.map(\.1), script: tokens)
      let spoken = alignment.spoken
      let shown = rendersPresenter ? ledger.painted : ledger.published
      for token in tokens.indices {
        ledger.events.append(.init(
          type: "token_display", generation: nil, replacementID: nil,
          wallSecondsSinceFirstAudio: shown[token], audioStart: spoken[token]?.start, audioEnd: spoken[token]?.end,
          recognitionDeliveryLag: nil, tokenIndex: token, acceptedWords: nil, droppedBuffers: nil,
          submittedBuffers: nil, isFinal: nil, locale: nil,
          text: "First instant the token was shown dim (painted when rendered, else published) and published confirmed; audio range is when it was spoken.",
          publishedSeconds: ledger.published[token]))
      }
      print("Script length \(tokens.count), words with a spoken time \(spoken.compactMap { $0 }.count), "
        + "final token \(session.tokenIndex), accepted \(session.acceptedWords), drops \(ledger.droppedBuffers). "
        + "\(rendersPresenter ? "Dim painted" : "Session publish"): \(WordLatency.report(display: shown, alignment: alignment, script: tokens))")
      if let hold = zip(progress, progress.dropFirst()).max(by: {
        ($0.1.wallSecondsSinceFirstAudio ?? 0) - ($0.0.wallSecondsSinceFirstAudio ?? 0)
          < ($1.1.wallSecondsSinceFirstAudio ?? 0) - ($1.0.wallSecondsSinceFirstAudio ?? 0)
      }) {
        print(String(format: "Longest stall %.3fs at wall %.2fs, on token %d", largestHold, hold.0.wallSecondsSinceFirstAudio ?? 0, hold.0.tokenIndex ?? -1))
      }
      if rendersPresenter {
        let publishToPaint = zip(ledger.published, ledger.painted).compactMap { published, painted in
          published.flatMap { p in painted.map { $0 - p } }
        }
        print("Session publish to dim painted: \(WordLatency.describe(publishToPaint))")
      }
      let early = WordLatency.early(display: shown, alignment: alignment, script: tokens)
      XCTAssertTrue(early.isEmpty, "Dimmed \(early.count) words before they were said, first \(early.first?.token ?? -1). See \(logURL.path).")
      if let bound = Double(environment["VIDEOPROMPTER_MAX_WORD_LATENCY_P90"] ?? "") {
        XCTAssertLessThanOrEqual(WordLatency.percentiles(WordLatency.latencies(display: shown, spoken: spoken)).p90, bound,
          "Per-word dim latency regressed over \(bound)s. See \(logURL.path).")
      }
    }
    XCTAssertEqual(
      session.tokenIndex, session.document.spokenTokens.count - 1,
      "Replay ended at token \(session.tokenIndex)/\(session.document.spokenTokens.count - 1). See \(logURL.path).")
    XCTAssertEqual(
      ledger.droppedBuffers, 0,
      "Replay dropped \(ledger.droppedBuffers) input buffers. See \(logURL.path).")
  }

}
