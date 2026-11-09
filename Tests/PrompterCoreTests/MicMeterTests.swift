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
}
