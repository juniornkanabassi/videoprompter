import XCTest

@testable import VideoPrompter

/// The zebra mask from a luma plane, padding included, and the threshold scale.
final class CameraExposureTests: XCTestCase {
  func testCustomBandsNeverBecomeFaceAdvice() throws {
    var guides = CameraGuides()
    guides.zebraRange = 5
    XCTAssertEqual(guides.validatedZebraPurpose, .custom)
    XCTAssertEqual(guides.zebraMeasurement, "Stripes mark 90–100 IRE in the received picture.")
    XCTAssertNotNil(guides.zebraWarning)
    XCTAssertFalse(guides.zebraGuidance.contains("should show stripes"))
    guides.useZebraPreset(.faceReference)
    XCTAssertEqual(guides.validatedZebraPurpose, .faceReference)
    XCTAssertNil(guides.zebraWarning)
    guides.zebraLevel = 95
    XCTAssertEqual(guides.validatedZebraPurpose, .custom)
    guides.zebraPurpose = .faceReference
    XCTAssertEqual(guides.validatedZebraPurpose, .custom, "Invalid saved presets cannot bypass validation")
    let restored = try JSONDecoder().decode(CameraGuides.self, from: JSONEncoder().encode(guides))
    XCTAssertEqual(restored.validatedZebraPurpose, .custom)
    let legacy = try JSONDecoder().decode(CameraGuides.self, from: Data(#"{"zebraLevel":60,"zebraRange":5}"#.utf8))
    XCTAssertEqual(legacy.validatedZebraPurpose, .custom)
  }

  func testOnlyPixelsAtOrAboveTheLevelAreMasked() {
    // 3x2 picture in rows padded to 4 bytes; the padding byte is bright and must be ignored.
    let plane: [UInt8] = [10, 242, 255, 255, 241, 0, 243, 255]
    let mask = plane.withUnsafeBytes {
      CameraExposure.mask(luma: $0, width: 3, height: 2, bytesPerRow: 4, codes: CameraExposure.zebraCodes(level: 95, range: 0))
    }
    XCTAssertEqual(mask.map { $0 != 0 }, [false, true, true, false, false, true])
  }

  func testZebraCodesFollowIRE() {
    XCTAssertEqual(CameraExposure.zebraCodes(level: 95, range: 0), 242...255)
    // Sony-style 50 ± 2: 48 to 52 IRE, so 49.8 and 50.2 IRE stripe and 47 and 53 do not.
    let skin = CameraExposure.zebraCodes(level: 50, range: 2)
    XCTAssertEqual(skin, 122...133)
    XCTAssertFalse(skin.contains(CameraExposure.code(ire: 47)))
    XCTAssertFalse(skin.contains(CameraExposure.code(ire: 53)))
    XCTAssertEqual(CameraExposure.code(ire: 150), 255)
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
