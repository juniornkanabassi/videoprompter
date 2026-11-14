import CoreImage
import CoreVideo
import XCTest
@testable import VideoPrompter

/// Compiled into both platforms, against the same production processor.
final class ExposureParityTests: XCTestCase {
  func testThresholdsAndPalette() {
    XCTAssertEqual(CameraExposure.zebraCodes(level: 45, range: 2), 110...120)
    XCTAssertEqual(CameraExposure.zebraCodes(level: 95, range: 0), 242...255)
    let table = CameraExposure.falseColourTable
    XCTAssertEqual(table[115], 0xFFBE78FF)
    XCTAssertEqual(table[0], 0xFFA00080)
    XCTAssertEqual(table[255], 0xFF0000E6)
    var guides = CameraGuides()
    guides.useZebraPreset(.faceReference)
    guides.zebras = true
    XCTAssertEqual(guides.exposure.skinCodes, 110...120)
  }

  func testDecodedFrameCostAndCIParity() throws {
    let processor = CameraExposure(settings: .init(), onFrame: { _ in })
    var settings = CameraExposure.Settings()
    settings.zebras = true
    settings.zebraLevel = 45
    settings.zebraRange = 2
    settings.falseColour = true
    let image = CIImage(color: CIColor(red: 115.0 / 255, green: 115.0 / 255, blue: 115.0 / 255))
      .cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let frame = processor.process(image: image, settings: settings)
    let mask = try XCTUnwrap(frame.zebraMask)
    let colour = try XCTUnwrap(frame.falseColour)
    XCTAssertEqual(mask.width, 960)
    let maskBytes = try XCTUnwrap(mask.dataProvider?.data) as Data
    XCTAssertEqual(Array(maskBytes.prefix(4)), [255, 255, 255, 255])
    let colourBytes = try XCTUnwrap(colour.dataProvider?.data) as Data
    XCTAssertEqual(Array(colourBytes.prefix(4)), [255, 120, 190, 255])
    // Warm the CI pipeline before timing sustained frames, including materialising both images.
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<30 {
      let frame = processor.process(image: image, settings: settings)
      XCTAssertNotNil(frame.zebraMask)
      XCTAssertNotNil(frame.falseColour)
    }
    let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 30
    print("EXPOSURE_FRAME_COST_MS=\(milliseconds)")
    XCTAssertLessThan(milliseconds, 1000 / 30, "Exposure processing must fit a 30 fps frame budget on this test host")
  }
  func testFullRangeDecodedFrameCost() throws {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let pixels = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
      base.initializeMemory(as: UInt8.self, repeating: plane == 0 ? 115 : 128,
        count: CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
    }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
    CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.advanced(by: stride * (height / 2))
      .initializeMemory(as: UInt8.self, repeating: 240, count: stride * (height - height / 2))
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let processor = CameraExposure(settings: .init(), onFrame: { _ in })
    let settings = CameraExposure.Settings(zebras: true, zebraLevel: 45, zebraRange: 2, falseColour: true)
    let first = processor.processDecoded(pixels, settings: settings)
    XCTAssertEqual(Array((try XCTUnwrap(first.falseColour?.dataProvider?.data) as Data).prefix(4)), [255, 120, 190, 255])
    let colour = try XCTUnwrap(first.falseColour)
    let bytes = try XCTUnwrap(colour.dataProvider?.data) as Data
    let last = (colour.height - 1) * colour.bytesPerRow + (colour.width - 1) * 4
    XCTAssertEqual(Array(bytes[last..<(last + 4)]), [240, 240, 240, 255], "Decoded luma must keep its vertical orientation")
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<30 {
      let frame = processor.processDecoded(pixels, settings: settings)
      XCTAssertNotNil(frame.zebraMask)
      XCTAssertNotNil(frame.falseColour)
    }
    let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 30
    print("EXPOSURE_DECODED_FRAME_COST_MS=\(milliseconds)")
    XCTAssertLessThan(milliseconds, 1000 / 30)
  }

}
