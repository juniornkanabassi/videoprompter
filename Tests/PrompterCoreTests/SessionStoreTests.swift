import XCTest

@testable import JuniorPrompter
import PrompterCore

@MainActor
final class SessionStoreTests: XCTestCase {
  private func record() -> ScriptRecord {
    ScriptRecord(
      metadata: ScriptMetadata(title: "Test", fileName: "test.md"), markdown: "One two three")
  }

  func testTogglePausesAnUncertainActiveSession() {
    let session = SessionStore()
    session.present(record: record(), settings: PrompterSettings())
    session.play()

    if case .uncertain = session.state {
      session.toggle()
      XCTAssertEqual(session.state, .paused)
    } else {
      XCTFail("Voice mode without a selected device should be uncertain")
    }
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
    session.play()
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

  func testSoundModeUsesThresholdAndConfiguredSpeed() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Sound"; settings.speed = 600; settings.soundThreshold = 0.2
    session.present(record: record(), settings: settings)
    session.play()
    session.acceptSoundLevel(0.1, at: 1)
    XCTAssertEqual(session.tokenIndex, 0)
    session.acceptSoundLevel(0.3, at: 1)
    XCTAssertEqual(session.tokenIndex, 1)
    session.acceptSoundLevel(0.3, at: 1.05)
    XCTAssertEqual(session.tokenIndex, 1)
    session.acceptSoundLevel(0.3, at: 1.11)
    XCTAssertEqual(session.tokenIndex, 2)
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
