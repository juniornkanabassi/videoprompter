import XCTest
import PrompterCore
@testable import VideoPrompter

@MainActor final class RoundNineTests: XCTestCase {
  private func session(_ defaults: UserDefaults) -> SessionStore {
    let session = SessionStore(defaults: defaults)
    var settings = PrompterSettings(); settings.mode = "Manual"
    session.present(record: ScriptRecord(metadata: ScriptMetadata(title: "Count in", fileName: "count.md"), markdown: "One two three four five six"), settings: settings)
    return session
  }
  func testCountdownHoldsPositionAndCanBeCancelledOrComplete() async throws {
    let defaults = freshDefaults("Countdown")
    let session = session(defaults)
    defer { session.stop() }
    XCTAssertEqual(session.startDelay, 3)
    session.countdownTick = .milliseconds(30)
    session.startReading()
    XCTAssertEqual(session.countdownRemaining, 3)
    XCTAssertFalse(session.isActivelyRunning)
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertEqual(session.readingStatus, "Starting in 3…")
    session.toggle()
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertFalse(session.isCountingDown)
    XCTAssertFalse(session.isActivelyRunning)
    session.startReading()
    for _ in 0..<50 where !session.isActivelyRunning { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(session.isActivelyRunning)
    XCTAssertEqual(session.countdownRemaining, 0)
  }
  func testCountdownPreferenceAndAllCancellationPaths() {
    let defaults = freshDefaults("CountdownSettings")
    let session = session(defaults)
    session.startDelay = 5
    XCTAssertEqual(self.session(defaults).startDelay, 5)
    for cancel in [{ session.pause() }, { session.restart() }, {
      var settings = session.settings; settings.mode = "Voice"; session.updateSettings(settings)
    }, { session.stop() }] {
      var settings = session.settings; settings.mode = "Manual"; session.updateSettings(settings)
      session.startReading()
      XCTAssertTrue(session.isCountingDown)
      cancel()
      XCTAssertFalse(session.isCountingDown)
      XCTAssertFalse(session.isActivelyRunning)
    }
    let immediate = self.session(defaults)
    immediate.startDelay = 0; immediate.startReading()
    XCTAssertTrue(immediate.isActivelyRunning)
    immediate.stop()
  }
  func testTakeProblemNamesFaultAndRecovery() {
    XCTAssertEqual(RecordingReceipt.problemSummary(frames: 1, audio: 0, failure: nil), "Picture dropped. Review take.")
    XCTAssertEqual(RecordingReceipt.problemSummary(frames: 0, audio: 1, failure: nil), "Sound dropped. Review take.")
    XCTAssertEqual(RecordingReceipt.problemSummary(frames: 1, audio: 1, failure: nil), "Picture and sound dropped. Review take.")
    XCTAssertEqual(RecordingReceipt.problemSummary(frames: 0, audio: 0, failure: "Interrupted. Check take."), "Interrupted. Check take.")
  }
  func testWelcomeUsesCurrentNavigation() {
    for label in ["More", "Reading mode", "Text", "Camera", "Framing guides", "Open Camera Monitor", "Show in Finder", "Cancel countdown"] {
      XCTAssertTrue(WelcomeScript.markdown.contains(label), label)
    }
    for obsolete in ["**Setup**", "Open second camera monitor"] {
      XCTAssertFalse(WelcomeScript.markdown.contains(obsolete), obsolete)
    }
  }
}
