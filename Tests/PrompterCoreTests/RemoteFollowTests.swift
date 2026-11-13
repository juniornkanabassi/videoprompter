import XCTest

@testable import VideoPrompter
import PrompterCore

/// The Mac's voice relay drives an iPad session: its words arrive as `followRemote`, and this
/// device never listens itself.
@MainActor
final class RemoteFollowTests: XCTestCase {
  private let words = (1...30).map { "word\($0)" }.joined(separator: " ")

  private func session(follows: Bool = true, mode: String = "Voice") -> (SessionStore, () -> Int) {
    let session = SessionStore(defaults: freshDefaults())
    var requests = 0
    session.resolveAudioInput = { _ in requests += 1; return nil }
    session.followsRemote = follows
    var settings = PrompterSettings()
    settings.mode = mode
    session.present(record: ScriptRecord(metadata: ScriptMetadata(title: "Relay", fileName: "relay.md"), markdown: words), settings: settings)
    return (session, { requests })
  }

  func testAFollowedWordAdvancesAndGlides() {
    let (session, _) = session()
    session.play()
    session.followRemote(confirmed: 9)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 9)
    XCTAssertEqual(session.tokenIndex, 10)
    XCTAssertEqual(session.state, .running)
    XCTAssertNotNil(session.anchor)
    // The glide eases toward the new word, as it does for a recognised one.
    let first = session.voicePosition(at: 100)
    let later = session.voicePosition(at: 100.3)
    XCTAssertGreaterThan(later, first)
    XCTAssertLessThanOrEqual(later, 10)
    // Backward tracking is the Mac's decision, so an earlier word is applied as sent.
    session.followRemote(confirmed: 4)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 4)
  }

  func testTheLastWordPausesAfterTheGrace() async throws {
    let (session, _) = session()
    session.voiceEndGrace = .milliseconds(20)
    session.play()
    session.followRemote(confirmed: 29)
    XCTAssertTrue(session.reachedEnd)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(session.isActivelyRunning)
  }

  func testIgnoredWhilePaused() {
    let (session, _) = session()
    session.followRemote(confirmed: 5)
    XCTAssertNil(session.lastConfirmedTokenIndex)
    session.play(); session.pause()
    session.followRemote(confirmed: 5)
    XCTAssertNil(session.lastConfirmedTokenIndex)
  }

  func testIgnoredWhenNotFollowing() {
    let (session, _) = session(follows: false)
    session.play(captureAudio: false)
    session.followRemote(confirmed: 5)
    XCTAssertNil(session.lastConfirmedTokenIndex)
    XCTAssertEqual(session.tokenIndex, 0)
  }

  func testIgnoredOutOfRange() {
    let (session, _) = session()
    session.play()
    session.followRemote(confirmed: -1)
    session.followRemote(confirmed: 30)
    session.followRemote(confirmed: Int.max)
    XCTAssertNil(session.lastConfirmedTokenIndex)
    session.followRemote(confirmed: 29)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 29)
  }

  func testPlayNeverStartsCaptureWhileFollowing() {
    let (session, requests) = session()
    session.play()
    XCTAssertEqual(requests(), 0)
    XCTAssertFalse(session.isPreparingVoice)
    XCTAssertTrue(session.isActivelyRunning)
    // A settings change that would restart the microphone must not either.
    var settings = session.settings
    settings.audioDeviceUID = "another-microphone"
    session.updateSettings(settings)
    XCTAssertEqual(requests(), 0)
    XCTAssertFalse(session.isPreparingVoice)
    // Control: the same session without the relay does look for a microphone.
    let (own, ownRequests) = self.session(follows: false)
    own.play()
    XCTAssertEqual(ownRequests(), 1)
  }

  func testSwitchingTheVoiceSourceHandsTheMicrophoneOver() {
    let (session, _) = session(follows: false)
    session.resolveAudioInput = { _ in AudioInputDevice(id: 1, uid: "built-in", name: "Built-in") }
    session.play()
    XCTAssertTrue(session.isPreparingVoice, "this iPad's microphone is starting")
    session.followsRemote = true
    XCTAssertFalse(session.isPreparingVoice, "handing over to the Mac stops this iPad's capture")
    XCTAssertTrue(session.isActivelyRunning)
    XCTAssertEqual(session.state, .running)
    session.followsRemote = false
    XCTAssertTrue(session.isPreparingVoice, "switching back restarts capture deliberately")
    session.pause()
    XCTAssertFalse(session.isPreparingVoice)
  }

  func testStartReadingHonoursTheCountdownAndPauseCancelsIt() async throws {
    let (session, _) = session(follows: false, mode: "Manual")
    session.startDelay = 3
    session.countdownTick = .milliseconds(5)
    session.startReading()
    XCTAssertEqual(session.countdownRemaining, 3)
    XCTAssertFalse(session.isActivelyRunning, "a remote Play counts down first, like the iPad's own Start")
    session.pause()
    XCTAssertEqual(session.countdownRemaining, 0)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(session.isActivelyRunning, "the cancelled countdown must not start the script")
    session.startReading()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(session.isActivelyRunning)
    session.startDelay = 0
    session.pause()
    session.startReading()
    XCTAssertTrue(session.isActivelyRunning, "no delay starts at once")
    session.pause()
  }
}
