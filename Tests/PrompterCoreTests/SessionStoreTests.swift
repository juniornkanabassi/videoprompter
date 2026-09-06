import AVFoundation
import XCTest

@testable import JuniorPrompter
import PrompterCore

@MainActor
final class SessionStoreTests: XCTestCase {
  private func record() -> ScriptRecord {
    ScriptRecord(
      metadata: ScriptMetadata(title: "Test", fileName: "test.md"), markdown: "One two three")
  }

  func testMissingAudioInputPausesAndPreservesAnchor() {
    let session = SessionStore()
    session.present(record: record(), settings: PrompterSettings())
    let anchor = session.anchor
    session.play()

    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.anchorNotice, "Choose an audio input in the inspector")
    session.play(captureAudio: false)
    XCTAssertEqual(session.state, .running)
    XCTAssertNil(session.anchorNotice)
    session.pause()
  }

  func testMissingAudioInputDoesNotAccumulateDuration() async {
    let session = SessionStore()
    session.present(record: record(), settings: PrompterSettings())
    session.play()
    try? await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(session.activeDuration, 0, accuracy: 0.01)
  }

  func testPausingCancelsDurationClock() async {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Timed"
    session.present(record: record(), settings: settings)
    session.play(captureAudio: false)
    try? await Task.sleep(for: .milliseconds(20))
    session.pause()
    let duration = session.activeDuration
    try? await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(session.activeDuration, duration, accuracy: 0.01)
  }

  func testTogglePausesAndResumesTimedSession() {
    let session = SessionStore()
    var settings = PrompterSettings()
    settings.mode = "Timed"
    session.present(record: record(), settings: settings)
    session.play()
    XCTAssertEqual(session.state, .running)
    session.toggle()
    XCTAssertEqual(session.state, .paused)
    session.toggle()
    XCTAssertEqual(session.state, .running)
  }

  func testOBSSnapshotPreservesPunctuationAndOmitsStageDirections() async throws {
    let session = SessionStore()
    session.present(
      record: ScriptRecord(
        metadata: ScriptMetadata(title: "Test", fileName: "test.md"),
        markdown: "Hello, [pause] world!"), settings: PrompterSettings())
    try await session.startOBS()
    defer { session.stopOBS() }
    let url = try XCTUnwrap(session.obsURL)
    let (data, _) = try await URLSession.shared.data(from: url.appending(path: "state"))
    let snapshot = try JSONDecoder().decode(OBSSnapshot.self, from: data)
    XCTAssertEqual(snapshot.runs.first?.text, "Hello,  world!")
    XCTAssertEqual(snapshot.runs.first?.spokenTokenCount, 2)
  }

  func testSwitchingToTimedKeepsAnActiveSessionRunning() async {
    let session = SessionStore()
    session.present(record: record(), settings: PrompterSettings())
    session.play(captureAudio: false)
    var settings = PrompterSettings(); settings.mode = "Timed"; settings.speed = 600
    session.updateSettings(settings)
    XCTAssertEqual(session.state, .running)
    try? await Task.sleep(for: .milliseconds(500))
    XCTAssertGreaterThan(session.tokenIndex, 0)
    XCTAssertGreaterThan(session.activeDuration, 0)
    session.pause()
  }

  func testOldSettingsDecodeWithMixedLanguageDefault() throws {
    let value = try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"mode":"Voice","speed":120}"#.utf8))
    XCTAssertEqual(value.speechLanguage, "Mixed")
    XCTAssertEqual(value.soundThreshold, 0.055)
  }

  func testSessionStatsStartAtZeroWithNextHundredWordMilestone() {
    let session = SessionStore()
    XCTAssertEqual(session.estimatedWPM, 0)
    XCTAssertEqual(session.sessionMilestone, 100)
  }

  func testSoundModeUsesThresholdAndConfiguredSpeed() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Sound"; settings.speed = 600; settings.soundThreshold = 0.2
    session.present(record: record(), settings: settings)
    session.play(captureAudio: false)
    session.acceptSoundLevel(0.1, at: 1)
    XCTAssertEqual(session.tokenIndex, 0)
    session.acceptSoundLevel(0.3, at: 1)
    XCTAssertEqual(session.tokenIndex, 1)
    session.acceptSoundLevel(0.3, at: 1.05)
    XCTAssertEqual(session.tokenIndex, 1)
    session.acceptSoundLevel(0.3, at: 1.11)
    XCTAssertEqual(session.tokenIndex, 2)
  }

  func testContinuousInterimCandidatesFlushBeforeStreamStops() async {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: record(), settings: settings)
    session.play(captureAudio: false)
    let initialRevision = session.seekRevision
    for index in 0..<5 {
      session.acceptSpeechCandidate(
        SpeechCandidate(
          replacementID: "revision-\(index)", generation: 1, locale: Locale(identifier: "en-GB"),
          text: "One two three", range: CMTimeRange(
            start: CMTime(seconds: Double(index), preferredTimescale: 1000),
            duration: CMTime(seconds: 1, preferredTimescale: 1000)), isFinal: false))
      try? await Task.sleep(for: .milliseconds(10))
      if index == 3 { XCTAssertGreaterThan(session.tokenIndex, 0) }
    }
    XCTAssertGreaterThan(session.tokenIndex, 0)
    XCTAssertEqual(session.seekRevision, initialRevision)
    session.pause()
  }

  func testExplicitSeekIncrementsRevisionButAutomaticAdvanceDoesNot() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Timed"
    session.present(record: record(), settings: settings)
    let initialRevision = session.seekRevision
    session.seek(to: 1)
    XCTAssertEqual(session.seekRevision, initialRevision + 1)
    session.advanceOneToken()
    XCTAssertEqual(session.seekRevision, initialRevision + 1)
  }

  func testPauseCancelsBufferedSpeechCandidateFlush() async {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: record(), settings: settings)
    session.play(captureAudio: false)
    session.acceptSpeechCandidate(
      SpeechCandidate(
        replacementID: "pending", generation: 1, locale: Locale(identifier: "en-GB"),
        text: "One two three", range: CMTimeRange(
          start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1000)), isFinal: false))
    session.pause()
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.tokenIndex, 0)
  }

  func testLanguageChangePreservesReadingAnchor() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Timed"
    session.present(record: record(), settings: settings)
    session.seek(to: 1)
    let before = session.anchor
    var changed = settings; changed.speechLanguage = "French"
    session.updateSettings(changed)
    XCTAssertEqual(session.anchor, before)
    XCTAssertEqual(session.tokenIndex, 1)
  }
}
