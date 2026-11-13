import XCTest
@testable import VideoPrompter

@MainActor final class MicMeterTests: XCTestCase {
  func testAccessibleMeterIncludesMicrophoneAndLatchedClipping() async throws {
    let meter = InputMeter()
    meter.show(peakDBFS: -2, isClipping: true)
    let (window, host) = await LibraryAX.host(MicMeterView(meter: meter, micName: "Shure MV7 Plus desk microphone"), size: .init(width: 120, height: 320))
    defer { LibraryAX.close(window) }
    func announcements() -> [String] {
      LibraryAX.elements(host).map { LibraryAX.value($0, "accessibilityLabel") }
        .filter { $0.contains("Shure MV7 Plus desk microphone") }
    }
    XCTAssertTrue(announcements().contains { $0.contains("Clipping") }, "\(announcements())")
    meter.show(peakDBFS: -14, isClipping: false)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(announcements().contains { $0.contains("Clipping") }, "\(announcements())")
  }

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

  func testOneClearForgetsTheClipForEveryViewOfTheSameMeter() {
    let meter = InputMeter(), other = InputMeter()
    let strip = ClipLatchBox.shared(for: meter), card = ClipLatchBox.shared(for: meter)
    XCTAssertTrue(strip === card, "the strip's lamp and the card's words read one latch")
    XCTAssertFalse(strip === ClipLatchBox.shared(for: other))
    strip.hold(from: 10, seconds: MicMeterView.clipLatchSeconds)
    XCTAssertTrue(card.isLit(isClipping: false, now: 10.5))
    card.clear()
    XCTAssertFalse(strip.isLit(isClipping: false, now: 10.5))
  }

  func testUnlitGreenIsTintedLikeTheOtherZones() {
    // The track is drawn by one gradient; this keeps the three zone tints on one opacity.
    XCTAssertEqual(MeterZones.unlitOpacity, 0.28)
  }

  func testClearingTheLatchTurnsTheWarningOffAtOnceButNotALiveClip() {
    var latch = ClipLatch()
    latch.hold(from: 10, seconds: MicMeterView.clipLatchSeconds)
    XCTAssertTrue(latch.isLit(isClipping: false, now: 10.5), "remembered after the level fell")
    latch.clear()
    XCTAssertFalse(latch.isLit(isClipping: false, now: 10.5), "the pill's button forgets it")
    XCTAssertTrue(latch.isLit(isClipping: true, now: 10.5), "an input still clipping lights it again")
  }
}
