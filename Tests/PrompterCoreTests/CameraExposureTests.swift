import XCTest

@testable import VideoPrompter

/// The zebra mask from a luma plane, padding included, and the threshold scale.
final class CameraExposureTests: XCTestCase {
  func testOnlyPixelsAtOrAboveTheLevelAreMasked() {
    // 3x2 picture in rows padded to 4 bytes; the padding byte is bright and must be ignored.
    let plane: [UInt8] = [10, 242, 255, 255, 241, 0, 243, 255]
    let mask = plane.withUnsafeBytes {
      CameraExposure.mask(luma: $0, width: 3, height: 2, bytesPerRow: 4, threshold: CameraExposure.threshold(percent: 95))
    }
    XCTAssertEqual(mask.map { $0 != 0 }, [false, true, true, false, false, true])
  }

  func testThresholdIsPercentOfFullScale() {
    XCTAssertEqual(CameraExposure.threshold(percent: 95), 242)
    XCTAssertEqual(CameraExposure.threshold(percent: 100), 255)
    XCTAssertEqual(CameraExposure.threshold(percent: 150), 255)
  }

  func testFalseColourBandsFollowTheARRIScale() {
    func colour(_ percent: Double) -> UInt32 { CameraExposure.falseColourTable[Int((percent / 100 * 255).rounded())] }
    let grey: (UInt32) -> UInt32 = { $0 | $0 << 8 | $0 << 16 | 0xFF00_0000 }
    XCTAssertEqual(colour(0), 0xFFA0_0080, "crushed black is purple")
    XCTAssertEqual(colour(40), 0xFF00_C800, "middle grey is green")
    XCTAssertEqual(colour(54), 0xFFBE_78FF, "one stop over is pink")
    XCTAssertEqual(colour(100), 0xFF00_00E6, "clipped is red")
    XCTAssertEqual(CameraExposure.falseColourTable[128], grey(128), "everything else stays grey")
  }

  func testOlderSavedGuidesDecodeWithZebrasOff() throws {
    let guides = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"thirds":true}"#.utf8))
    XCTAssertFalse(guides.zebras)
    XCTAssertEqual(guides.zebraLevel, 95)
    XCTAssertFalse(guides.falseColour)
  }
}
