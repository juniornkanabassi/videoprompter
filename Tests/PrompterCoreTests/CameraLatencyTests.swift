import CoreMedia
import CoreVideo
import XCTest
@testable import JuniorPrompter

/// The camera's format, frame-rate and fallback decisions, over a DeckLink-like table: every size
/// in 10-bit `v210` and 8-bit `2vuy`, each listing the same single rates.
final class CameraLatencyTests: XCTestCase {
  private typealias Format = SharedCameraSession.VideoFormat
  private typealias Choice = SharedCameraSession.FormatChoice

  private let ntsc30 = time(1001, 30000)
  private let rates = [(1001, 24000), (1, 24), (1, 25), (1001, 30000), (1, 30), (1, 50), (1001, 60000), (1, 60)]
    .map { time(Int64($0.0), Int32($0.1)) }.map { $0...$0 }

  private func fmt(_ w: Int32, _ h: Int32, _ sub: OSType) -> Format {
    Format(width: w, height: h, subType: FourCharCode(sub), frameDurations: rates)
  }
  private var deckLink: [Format] {
    ([720, 1920, 3840] as [Int32]).flatMap { w -> [Format] in
      let h: Int32 = w == 720 ? 486 : w == 1920 ? 1080 : 2160
      return [fmt(w, h, kCVPixelFormatType_422YpCbCr10), fmt(w, h, kCVPixelFormatType_422YpCbCr8)]
    }
  }
  private var uhd: Format { fmt(3840, 2160, kCVPixelFormatType_422YpCbCr10) }
  private var hd: Format { fmt(1920, 1080, kCVPixelFormatType_422YpCbCr10) }

  /// Cam B today: a 4K 29.97 signal. The preview asks for 1080p in 8-bit, at 29.97.
  func testA4KSignalIsPreviewedAt1080pInItsCheapestCodingAndItsOwnRate() throws {
    let choice = try XCTUnwrap(Choice(in: deckLink, signal: uhd, signalDuration: ntsc30))
    XCTAssertEqual(choice.wanted, .init(format: 3, frameDuration: ntsc30))
    XCTAssertEqual(deckLink[3], fmt(1920, 1080, kCVPixelFormatType_422YpCbCr8))
    XCTAssertEqual(choice.fallback, .init(format: 3, frameDuration: .invalid))
    XCTAssertEqual(try XCTUnwrap(Choice(in: deckLink, signal: hd, signalDuration: ntsc30)), choice)
  }

  /// Never upscaled, and a shape with no smaller listed twin keeps its own size.
  func testASmallerOrOddSignalKeepsItsOwnSize() throws {
    let sd = try XCTUnwrap(Choice(in: deckLink, signal: fmt(720, 486, kCVPixelFormatType_422YpCbCr10), signalDuration: ntsc30))
    XCTAssertEqual(sd.wanted.format, 1)
    let dci = fmt(4096, 2160, kCVPixelFormatType_422YpCbCr10)
    let wide = try XCTUnwrap(Choice(in: deckLink + [dci], signal: dci, signalDuration: ntsc30))
    XCTAssertEqual(wide.wanted.format, 6)
    let qhd = fmt(2560, 1440, kCVPixelFormatType_422YpCbCr8)
    XCTAssertEqual(try XCTUnwrap(Choice(in: deckLink + [qhd], signal: qhd, signalDuration: ntsc30)).wanted.format, 3)
  }

  func testTheDurationGoesInAsTheDevicesOwnValue() {
    let doubled = Choice.frameDuration(time(2002, 60000), in: uhd)
    XCTAssertEqual(doubled, ntsc30)
    XCTAssertEqual(doubled.timescale, 30000)
  }

  func testARateTheFormatDoesNotListLeavesTheFormatsDefault() {
    XCTAssertEqual(Choice.frameDuration(time(1, 48), in: uhd), .invalid)
    XCTAssertEqual(Choice.frameDuration(.invalid, in: uhd), .invalid)
    XCTAssertEqual(Choice.frameDuration(.zero, in: uhd), .invalid)
    XCTAssertEqual(Choice.frameDuration(ntsc30, in: Format(width: 1, height: 1, subType: 0)), .invalid)
  }

  func testARangeOfRatesTakesTheSignalAsItIs() {
    let webcam = Format(width: 1920, height: 1080, subType: 0, frameDurations: [time(1, 60)...time(1, 24)])
    XCTAssertEqual(Choice.frameDuration(ntsc30, in: webcam), ntsc30)
    XCTAssertEqual(Choice.frameDuration(time(1, 120), in: webcam), .invalid)
  }

  func testASignalOutsideTheTableGivesNoChoice() {
    XCTAssertNil(Choice(in: deckLink, signal: fmt(4096, 2160, kCVPixelFormatType_422YpCbCr10), signalDuration: ntsc30))
    XCTAssertNil(Choice(in: [], signal: uhd, signalDuration: ntsc30))
  }

  /// A pinned rate that shows nothing goes back to the format's default rate, once.
  func testNoFrameInTimeGoesBackToTheDefaultRate() throws {
    let choice = try XCTUnwrap(Choice(in: deckLink, signal: uhd, signalDuration: ntsc30))
    XCTAssertEqual(choice.revert(sawFrame: false), .init(format: 3, frameDuration: .invalid))
    XCTAssertNil(choice.revert(sawFrame: true))
    XCTAssertNil(choice.settled.revert(sawFrame: false), "settled: nothing left to go back to")
    XCTAssertEqual(choice.settled.wanted, choice.fallback)
  }

  /// A rate the format does not list is never pinned, so there is nothing to watch.
  func testAnUnlistedRateLeavesNothingToWatch() throws {
    let choice = try XCTUnwrap(Choice(in: deckLink, signal: uhd, signalDuration: time(1, 48)))
    XCTAssertEqual(choice.wanted, choice.fallback)
    XCTAssertNil(choice.revert(sawFrame: false))
  }

  func testEachFrameIsPlacedOnTheFirstRefreshAtOrAfterItArrives() {
    let samples = [CameraLatency.Sample(capture: 10.000, delivered: 10.020),
                   CameraLatency.Sample(capture: 10.033, delivered: 10.050),
                   CameraLatency.Sample(capture: 10.066, delivered: 10.200)]
    let (delivered, shown) = CameraLatency.delays(samples, refreshes: [10.050, 10.0167, 10.0334])
    assertClose(delivered, [20, 17, 134])
    assertClose(shown, [33.4, 17], "a frame after the last refresh is left out")
    XCTAssertTrue(CameraLatency.report(samples, refreshes: [10.05]).hasPrefix("3 frames"))
  }

  func testPercentilesAreNearestRank() {
    let values = (1...10).map(Double.init).shuffled()
    XCTAssertEqual(CameraLatency.percentile(values, 0.5), 5)
    XCTAssertEqual(CameraLatency.percentile(values, 0.9), 9)
    XCTAssertEqual(CameraLatency.percentile([7], 0.9), 7)
    XCTAssertNil(CameraLatency.percentile([], 0.5))
  }
}

private func assertClose(
  _ a: [Double], _ b: [Double], _ message: String = "",
  file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertEqual(a.count, b.count, message, file: file, line: line)
  for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-6, message, file: file, line: line) }
}

private func time(_ value: Int64, _ scale: Int32) -> CMTime { CMTime(value: value, timescale: scale) }
