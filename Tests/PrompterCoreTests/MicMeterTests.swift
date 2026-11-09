import XCTest
@testable import VideoPrompter

@MainActor final class MicMeterTests: XCTestCase {
  func testReadoutRoundsAndUsesTrueMinus() {
    XCTAssertEqual(MicMeterView.readout(-14.4), "−14 dBFS")
    XCTAssertEqual(MicMeterView.readout(-2), "−2 dBFS")
  }

  func testReadoutSaysNoSignalWhenSilentOrStale() {
    XCTAssertEqual(MicMeterView.readout(-.infinity), "No signal")
    XCTAssertEqual(MicMeterView.level(peakDBFS: -6, isFresh: false), -.infinity)
    XCTAssertEqual(MicMeterView.level(peakDBFS: -6, isFresh: true), -6)
  }

  func testClipLightLatchesForTwoSeconds() {
    XCTAssertTrue(MicMeterView.clipLit(isClipping: false, latchedUntil: 12, now: 11.9))
    XCTAssertFalse(MicMeterView.clipLit(isClipping: false, latchedUntil: 12, now: 12))
    XCTAssertTrue(MicMeterView.clipLit(isClipping: true, latchedUntil: 0, now: 100))
  }
}
