import AVFoundation
import Combine
import Foundation
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor
final class PresenterObservationTests: XCTestCase {
  func testManualWordInvalidationBenchmark() {
    let suite = "PresenterObservationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = SessionStore(defaults: defaults)
    var now = 100.0
    session.clock = { now }
    var settings = PrompterSettings()
    settings.mode = "Manual"
    settings.speed = 60
    session.present(record: ScriptRecord(
      metadata: ScriptMetadata(title: "Benchmark", fileName: "benchmark.md"),
      markdown: Array(repeating: "word", count: 1002).joined(separator: " ")), settings: settings)
    session.play(captureAudio: false)
    let presentation = PresenterSessionState(session: session)
    var changes = 0
    var shellChanges = 0
    let watch = session.objectWillChange.sink { changes += 1 }
    let shellWatch = presentation.objectWillChange.sink { shellChanges += 1 }
    let start = ContinuousClock.now
    for index in 1...1000 {
      now = 100 + Double(index)
      session.syncManualFrontier(at: now)
    }
    let elapsed = start.duration(to: .now)
    print("PRESENTER_BENCHMARK words=1000 original_outer_invalidations=\(changes) narrowed_outer_invalidations=\(shellChanges) elapsed=\(elapsed)")
    XCTAssertEqual(session.tokenIndex, 1000)
    XCTAssertGreaterThanOrEqual(changes, 2000)
    XCTAssertEqual(shellChanges, 0)
    withExtendedLifetime((watch, shellWatch)) {}
    session.pause()
  }

  func testSpeechWordsOnlyInvalidateTheTextAndLifecycleChangesStillReachTheShell() {
    let suite = "PresenterObservationSpeechTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = SessionStore(defaults: defaults)
    var settings = PrompterSettings()
    settings.mode = "Voice"
    let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    session.present(record: ScriptRecord(
      metadata: ScriptMetadata(title: "Speech", fileName: "speech.md"),
      markdown: words.joined(separator: " ")), settings: settings)
    session.play(captureAudio: false)
    let presentation = PresenterSessionState(session: session)
    var wordChanges = 0
    var shellChanges = 0
    let wordWatch = session.$tokenIndex.dropFirst().sink { _ in wordChanges += 1 }
    let shellWatch = presentation.objectWillChange.sink { shellChanges += 1 }
    for count in 2...9 {
      session.acceptSpeechCandidate(SpeechCandidate(
        replacementID: "speech", generation: 1, locale: Locale(identifier: "en-GB"),
        text: words.prefix(count).joined(separator: " "),
        range: CMTimeRange(start: .zero, duration: CMTime(seconds: Double(count), preferredTimescale: 1000)),
        isFinal: false))
    }
    XCTAssertEqual(session.tokenIndex, 9)
    XCTAssertGreaterThan(wordChanges, 0)
    XCTAssertEqual(shellChanges, 0, "Recognised words must not invalidate camera or controls.")
    session.pause()
    XCTAssertEqual(shellChanges, 1, "The controls must still show Paused immediately.")
    settings.fontSize += 4
    session.updateSettings(settings)
    XCTAssertEqual(shellChanges, 2, "Typography still reaches the whole presenter.")
    session.updateSettings(settings)
    XCTAssertEqual(shellChanges, 2, "Repeated equivalent state must not wake the shell.")
    var replacement = session.activeRecord!
    replacement.markdown += " eleven"
    replacement.metadata.revision += 1
    session.applyEditedRecord(replacement)
    XCTAssertGreaterThan(shellChanges, 2, "Editing must rebuild the document.")
    withExtendedLifetime((wordWatch, shellWatch)) {}
  }
}
