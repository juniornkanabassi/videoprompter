import AppKit
import AVFoundation
import XCTest
@testable import VideoPrompter

@MainActor final class BoldZebraTests: XCTestCase {
  func testPatternUsesDisplayedSizeAndStaysFixedAcrossSourceResolutions() throws {
    let shared = SharedCameraSession.shared
    let previousSize = shared.pictureSize
    defer { shared.pictureSize = previousSize }
    let stage = CameraStageView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
    defer { stage.stop() }
    var guides = CameraGuides()
    guides.zebras = true
    stage.apply(uid: nil, guides: guides, mirrored: false)
    shared.pictureSize = .init(width: 1920, height: 1080)
    stage.layoutSubtreeIfNeeded()
    let stripes = try XCTUnwrap(stage.pictureLayer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    XCTAssertEqual(stripes.lineWidth, 12)
    XCTAssertEqual(CameraOverlay.zebraSpacing(picture: stage.pictureLayer.bounds), 32)
    XCTAssertEqual(stripes.backgroundColor, NSColor.white.cgColor)
    XCTAssertEqual(stripes.strokeColor, NSColor.black.cgColor)
    let path = try XCTUnwrap(stripes.path)
    shared.pictureSize = .init(width: 3840, height: 2160)
    stage.layoutSubtreeIfNeeded()
    XCTAssertEqual(stripes.path, path, "Source resolution cannot change or move the displayed stripes")
    stage.layout()
    XCTAssertEqual(stripes.path, path, "Repeated layout cannot animate the stripe phase")
    let small = CGRect(x: 0, y: 0, width: 480, height: 270)
    XCTAssertEqual(CameraOverlay.zebraLineWidth(picture: small), 9)
    XCTAssertEqual(CameraOverlay.zebraSpacing(picture: small), 24)
    let large = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    XCTAssertEqual(CameraOverlay.zebraLineWidth(picture: large), 24)
  }
}

extension AppearanceSnapshotTests {
  func testAlpha251BoldZebraSnapshot() throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let source = try XCTUnwrap(NSImage(contentsOf: Bundle.module.url(forResource: "presenter-clean", withExtension: "png", subdirectory: "Fixtures")!))
    let image = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let width = 360, height = 640
    let rgb = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    rgb.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let raster = try XCTUnwrap(rgb.makeImage())
    let bytes = try XCTUnwrap(rgb.data).assumingMemoryBound(to: UInt8.self)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer), kCVReturnSuccess)
    let pixels = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    for y in 0..<height { for x in 0..<width {
      let offset = (y * width + x) * 4
      luma[y * rowBytes + x] = UInt8(0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.0722 * Double(bytes[offset + 2]))
    } }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let processor = CameraExposure(settings: .init()) { _ in }
    let mask = try XCTUnwrap(processor.process(pixels, settings: .init(zebras: true, zebraLevel: 45, zebraRange: 10)).zebraMask)
    let shared = SharedCameraSession.shared
    let previousSize = shared.pictureSize
    defer { shared.pictureSize = previousSize }
    let stage = CameraStageView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    defer { stage.stop() }
    var guides = CameraGuides(); guides.zebras = true
    stage.apply(uid: nil, guides: guides, mirrored: false)
    shared.pictureSize = .init(width: width, height: height)
    stage.layoutSubtreeIfNeeded()
    stage.pictureLayer.sublayers?.first?.isHidden = true
    let picture = CALayer(); picture.frame = stage.pictureLayer.bounds; picture.contents = raster
    stage.pictureLayer.insertSublayer(picture, at: 0)
    stage.zebraMask.contents = mask
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
    try XCTUnwrap(stage.layer).render(in: context)
    let destination = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("alpha-251-bold-zebras.png"))
  }
}
