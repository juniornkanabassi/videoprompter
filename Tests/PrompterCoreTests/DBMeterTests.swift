import XCTest
@testable import VideoPrompter

final class DBMeterTests: XCTestCase {
  func testScaleAndBands() {
    XCTAssertEqual(DBMeter.fraction(-80), 0)
    XCTAssertEqual(DBMeter.fraction(-30), 0.5)
    XCTAssertEqual(DBMeter.fraction(5), 1)
    XCTAssertEqual(DBMeter.fraction(.nan), 0)
    XCTAssertEqual(DBMeter.band(-12), .green)
    XCTAssertEqual(DBMeter.band(-11.9), .yellow)
    XCTAssertEqual(DBMeter.band(-6), .yellow)
    XCTAssertEqual(DBMeter.band(-5.9), .red)
    XCTAssertEqual(DBMeter.ticks.map(DBMeter.fraction), [1, 0.9, 0.8, 0.6, 0.4, 0.2, 0])
  }

  func testThresholdLabelsColourByBand() {
    XCTAssertEqual(DBMeter.ticks.map(DBMeter.thresholdBand), [.red, .red, .yellow, nil, nil, nil, nil])
  }
}
