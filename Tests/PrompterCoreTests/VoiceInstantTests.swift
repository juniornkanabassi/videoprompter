import XCTest
import PrompterCore
@testable import VideoPrompter

final class VoiceInstantTests: XCTestCase {
  func testContextFollowsTheUpcomingWordsIncludingLowercaseAndSingleNames() {
    let tokens = PrompterDocument(markdown: "already read these words Mbappe finds space then scores").spokenTokens
    let context = SpeechProvider.upcomingContext(tokens, at: 4)
    XCTAssertTrue(context.contains("Mbappe"))
    XCTAssertTrue(context.contains("finds space"))
    XCTAssertFalse(context.contains("already"))
    XCTAssertTrue(SpeechProvider.upcomingContext(tokens, at: tokens.count).isEmpty)
    XCTAssertEqual(SpeechProvider.upcomingContext(tokens, at: -10), SpeechProvider.upcomingContext(tokens, at: 0))
  }

  func testContextRemainsBoundedAndMovesPastTheOpeningOfLongScripts() {
    let tokens = PrompterDocument(markdown: (0..<500).map { "word\($0)" }.joined(separator: " ")).spokenTokens
    let context = SpeechProvider.upcomingContext(tokens, at: 240)
    XCTAssertLessThanOrEqual(context.count, 100)
    XCTAssertTrue(context.contains("word240"))
    XCTAssertFalse(context.contains("word0"))
    XCTAssertFalse(context.contains("word288"))
    XCTAssertEqual(Set(context).count, context.count)
  }

  func testOnsetPrototypeAdvancesWithinOneBufferAndNeverMoreThanOneWord() {
    var probe = OnsetProbe()
    probe.audio(rms: 0, at: 0)
    probe.audio(rms: 0.1, at: 0.01)
    XCTAssertEqual(probe.shown, 1)
    for i in 2..<100 { probe.audio(rms: i.isMultiple(of: 2) ? 0 : 0.1, at: Double(i) * 0.01) }
    XCTAssertEqual(probe.shown, 1, "Never more than one unconfirmed word")
  }

  func testOnsetPrototypeStopsOnSilenceAndCorrectsMismatch() {
    var probe = OnsetProbe()
    for i in 0..<100 { probe.audio(rms: 0, at: Double(i) * 0.01) }
    XCTAssertEqual(probe.shown, 0)
    probe.audio(rms: 0.1, at: 1)
    XCTAssertEqual(probe.shown, 1)
    probe.recognised(confirmed: -1)
    XCTAssertEqual(probe.shown, 0, "Correction cannot undo the already visible wrong advance")
    probe.audio(rms: 0, at: 1.01)
    XCTAssertEqual(probe.shown, 0)
  }

  func testSameEnergyCanBeTheNextWordOrARepeatSoDefaultOnIsUnsafe() {
    // The observation is identical whether the reader says the next word or repeats this one.
    var next = OnsetProbe(), repeated = OnsetProbe()
    for (time, rms) in [(0.0, Float(0)), (0.01, 0.1), (0.02, 0.1)] {
      next.audio(rms: rms, at: time)
      repeated.audio(rms: rms, at: time)
    }
    XCTAssertEqual(next.shown, repeated.shown)
    XCTAssertEqual(repeated.shown, 1, "One visible wrong advance in the repeat case, before recognition can correct it")
    next.recognised(confirmed: 0)
    repeated.recognised(confirmed: -1)
    XCTAssertEqual(next.shown, 1)
    XCTAssertEqual(repeated.shown, 0)
    print("ONSET PROTOTYPE: 10 ms simulated response; 1/1 repeated-word counterexample advances incorrectly. Not enabled in production.")
  }
}

/// Test-only feasibility probe, deliberately not a production word detector.
private struct OnsetProbe {
  var confirmed = -1
  var shown = 0
  var aboveThreshold = false
  var lastAdvance = -Double.infinity
  mutating func audio(rms: Float, at time: Double) {
    let voiced = rms >= 0.025
    defer { aboveThreshold = voiced }
    guard voiced, !aboveThreshold, shown == confirmed + 1, time - lastAdvance >= 0.25 else { return }
    shown = confirmed + 2
    lastAdvance = time
  }
  mutating func recognised(confirmed: Int) {
    self.confirmed = confirmed
    shown = confirmed + 1
  }
}
