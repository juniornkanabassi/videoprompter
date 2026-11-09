import AVFoundation
import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class ExposurePipelineTests: XCTestCase {
  private func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &result), kCVReturnSuccess)
    let buffer = try XCTUnwrap(result)
    CVPixelBufferLockBaseAddress(buffer, [])
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let bytes = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
      for x in 0..<stride { bytes[y * stride + x] = x < width / 4 && y < height / 4 ? 255 : 128 }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  private func render(_ layer: CALayer) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
    bytes.withUnsafeMutableBytes {
      let context = CGContext(data: $0.baseAddress, width: 128, height: 128,
        bitsPerComponent: 8, bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      layer.render(in: context)
    }
    return bytes
  }

  func testAsymmetricPixelBufferKeepsItsCornerThroughBothPipelinesAndPlacement() throws {
    let processor = CameraExposure(settings: .init()) { _ in }
    for (width, height) in [(80, 40), (40, 80), (1920, 1080)] {
      let pixels = try buffer(width: width, height: height)
      let frame = processor.process(pixels, settings: .init(zebras: true, falseColour: true, skinLevel: 55, skinRange: 3))
      let colour = try XCTUnwrap(frame.falseColour)
      let mask = try XCTUnwrap(frame.zebraMask)
      XCTAssertLessThanOrEqual(max(colour.width, colour.height), 960)
      XCTAssertEqual(Double(colour.width) / Double(colour.height), Double(width) / Double(height), accuracy: 0.01)
      // Independent raw reference: white only in the source's upper-left quarter.
      var reference = [UInt32](repeating: 0, count: width * height)
      for y in 0..<height/4 { for x in 0..<width/4 { reference[y * width + x] = .max } }
      let image = reference.withUnsafeMutableBytes {
        CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
      }
      for rotation in CameraRotation.allCases {
        for mirrored in [false, true] {
          let bounds = CGRect(x: 0, y: 0, width: 128, height: 128)
          let picture = rotation.fittedRect(aspect: CGSize(width: width, height: height), in: bounds)
          func placed(_ image: CGImage) -> CALayer {
            let root = CALayer(); root.bounds = bounds
            let parent = CALayer(); root.addSublayer(parent)
            CameraStageView.place(parent, on: picture, turnedBy: rotation, mirrored: mirrored)
            let content = CALayer(); content.frame = parent.bounds; content.contents = image
            content.magnificationFilter = .nearest; content.minificationFilter = .nearest
            parent.addSublayer(content)
            return root
          }
          let expected = render(placed(image))
          let coloured = render(placed(colour))
          let striped = render(placed(mask))
          for index in stride(from: 0, to: expected.count, by: 4) {
            // Omit antialiased boundary pixels; compare the interior marker at every pixel.
            guard expected[index + 3] == 0 || expected[index + 3] == 255 else { continue }
            let isMarker = expected[index] == 255
            XCTAssertEqual(coloured[index] > 200 && coloured[index + 1] < 10, isMarker,
                           "false colour \(width)x\(height) \(rotation) mirror \(mirrored)")
            XCTAssertEqual(striped[index] > 200, isMarker, "zebra \(rotation) mirror \(mirrored)")
          }
        }
      }
    }
  }

  func testPreviewReconfigurationCannotEraseTheSharedDisplayTurn() throws {
    let view = CameraStageView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
    defer { view.stop() }
    let preview = try XCTUnwrap(view.pictureLayer.sublayers?.first as? AVCaptureVideoPreviewLayer)
    for rotation in CameraRotation.allCases {
      for mirrored in [false, true] {
        var guides = CameraGuides()
        guides.rotation = rotation
        for (zebras, colours) in [(false, false), (true, false), (false, true), (true, true)] {
          guides.zebras = zebras; guides.falseColour = colours
          view.apply(uid: nil, guides: guides, mirrored: mirrored)
          view.layoutSubtreeIfNeeded()
          // AVFoundation can reset its own layer while reconnecting. It must not own our turn.
          preview.setAffineTransform(.identity)
          XCTAssertEqual(view.pictureLayer.affineTransform(), rotation.displayTransform(mirrored: mirrored))
          XCTAssertEqual(guides.rotation, rotation)
          XCTAssertFalse(guides.automaticRotation)
          XCTAssertTrue(SharedCameraSession.shared.session.inputs.isEmpty)
        }
      }
    }
  }

  func testSkinTableUpdatesAndEarlierFramesSurviveBufferReuse() throws {
    let pixels = try buffer(width: 80, height: 40)
    CVPixelBufferLockBaseAddress(pixels, [])
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<40 { for x in 0..<80 { base[y * stride + x] = CameraExposure.code(ire: 45) } }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let processor = CameraExposure(settings: .init()) { _ in }
    let skin = CameraExposure.Settings(zebras: true, zebraLevel: 45, zebraRange: 2, falseColour: true)
    let first = processor.process(pixels, settings: skin)
    let image = try XCTUnwrap(first.falseColour)
    let before = render({ let layer = CALayer(); layer.bounds = CGRect(x: 0, y: 0, width: 128, height: 128); layer.contents = image; return layer }())
    let next = processor.process(pixels, settings: .init(zebras: true, falseColour: true, skinLevel: 55, skinRange: 3))
    let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
    XCTAssertEqual(Array(bytes.prefix(4)), [255, 120, 190, 255], "Active skin range is pink")
    let nextBytes = try XCTUnwrap(next.falseColour?.dataProvider?.data) as Data
    XCTAssertNotEqual(Array(nextBytes.prefix(4)), [255, 120, 190, 255], "Changing settings rebuilds the colour lookup")
    let after = render({ let layer = CALayer(); layer.bounds = CGRect(x: 0, y: 0, width: 128, height: 128); layer.contents = image; return layer }())
    XCTAssertEqual(before, after, "Reusing scratch arrays must not mutate published images")
  }

  func testBenchmarksAndOffscreenMeterSnapshots() throws {
    let processor = CameraExposure(settings: .init()) { _ in }
    for (width, height, iterations) in [(640, 360, 30), (3840, 2160, 8)] {
      let pixels = try buffer(width: width, height: height)
      CVPixelBufferLockBaseAddress(pixels, .readOnly)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
      let luma = UnsafeRawBufferPointer(start: CVPixelBufferGetBaseAddressOfPlane(pixels, 0), count: stride * height)
      func bench(_ work: () -> Void) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { autoreleasepool { work() } }
        return (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(iterations)
      }
      let before = bench {
        var a = CameraExposure.mask(luma: luma, width: width, height: height, bytesPerRow: stride, codes: 242...255)
        var b = CameraExposure.falseColour(luma: luma, width: width, height: height, bytesPerRow: stride)
        func oldImage(_ values: inout [UInt32]) -> CGImage? {
          values.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
          }
        }
        XCTAssertNotNil(oldImage(&a)); XCTAssertNotNil(oldImage(&b))
      }
      CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
      let after = bench { XCTAssertNotNil(processor.process(pixels, settings: .init(zebras: true, falseColour: true, skinLevel: 55, skinRange: 3)).falseColour) }
      let off = bench { XCTAssertNil(processor.process(pixels, settings: .init()).falseColour) }
      print("EXPOSURE_BENCH \(width)x\(height) baseline pipeline \(before) ms; new including images \(after) ms; off \(off) ms")
    }
    let stageStart = ProcessInfo.processInfo.systemUptime
    for _ in 0..<30 {
      let view = CameraStageView(frame: CGRect(x: 0, y: 0, width: 760, height: 520))
      view.apply(uid: nil, guides: CameraGuides(), mirrored: false)
      view.layoutSubtreeIfNeeded()
      view.stop()
    }
    print("STAGE_BENCH no-device construction/apply/layout \((ProcessInfo.processInfo.systemUptime - stageStart) * 1000 / 30) ms")
    guard let directory = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, peak) in [("quiet", -Float.infinity), ("speech", -12), ("hot", -3)] {
      let renderer = ImageRenderer(content: InputLevelMeter(peakDBFS: peak, isClipping: false)
        .padding(Space.lg).frame(width: 380).background(Color.black).environment(\.colorScheme, .dark))
      renderer.scale = 2
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("mic-meter-\(name).png"))
    }
  }
}
