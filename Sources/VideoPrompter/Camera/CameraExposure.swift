@preconcurrency import AVFoundation
import CoreGraphics

extension Notification.Name {
  static let cameraExposureDidChange = Notification.Name("VideoPrompter.cameraExposureDidChange")
}

/// The exposure aids of a camera monitor, from one small luma thumbnail about 15 times a second:
/// - zebras, an alpha mask of everything at or above the chosen level, which the stage view fills
///   with a stroked stripe path so the stripes stay sharp at any window size;
/// - false colour, the picture repainted by brightness band (ARRI's scale), shown over it.
/// Attached only while one of them is on and a window shows the camera, like auto orientation.
/// `@unchecked Sendable`: `settings` and `lastSampled` are touched on `queue` only.
final class CameraExposure: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  struct Settings: Equatable, Sendable {
    var zebras = false
    var zebraLevel = 95
    var zebraRange = 0
    var falseColour = false
    var isOn: Bool { zebras || falseColour }
  }
  struct Frame: @unchecked Sendable {
    var zebraMask: CGImage?
    var falseColour: CGImage?
  }

  /// Thumbnail size. Plenty for an exposure aid, and it keeps a 4K feed off this path.
  static let width = 640, height = 360

  /// One opaque white RGBA pixel where the luma falls in `codes`, clear elsewhere: a layer mask
  /// reads only the alpha. Rows may be padded, as a pixel buffer's are.
  static func mask(luma: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, codes: ClosedRange<UInt8>) -> [UInt32] {
    var out = [UInt32](repeating: 0, count: width * height)
    for y in 0..<height {
      let row = y * bytesPerRow
      for x in 0..<width where codes.contains(luma[row + x]) { out[y * width + x] = .max }
    }
    return out
  }

  /// IRE to the luma code the output delivers. The output is asked for full range, so a
  /// video-range source (code 16 = 0 IRE, 235 = 100 IRE, which is what HDMI from a camera and
  /// Sony's own zebras measure) is stretched to 0...255 and IRE is simply code / 255 x 100.
  static func code(ire: Double) -> UInt8 { UInt8(min(255, max(0, (ire * 255 / 100).rounded()))) }

  /// Sony's two zebra kinds: range 0 stripes everything at or above the level; otherwise only
  /// level ± range, for holding skin at a chosen exposure.
  static func zebraCodes(level: Int, range: Int) -> ClosedRange<UInt8> {
    range <= 0
      ? code(ire: Double(level))...255
      : code(ire: Double(level - range))...code(ire: Double(level + range))
  }

  /// ARRI's false colour bands, in percent of full scale; everything else shows as grey.
  static let bands: [(range: ClosedRange<Double>, name: String, rgb: (UInt8, UInt8, UInt8))] = [
    (0...2.5, "Purple: 0–2.5% brightness", (128, 0, 160)),
    (2.5...4, "Blue: 2.5–4% brightness", (0, 80, 255)),
    (38...42, "Green: 38–42% brightness", (0, 200, 0)),
    (52...56, "Pink: 52–56% brightness", (255, 120, 190)),
    (97...99, "Yellow: 97–99% brightness", (255, 230, 0)),
    (99...100, "Red: 99–100% brightness", (230, 0, 0)),
  ]

  /// Luma byte to an RGBA pixel as laid out in memory (R first), for every possible byte.
  static let falseColourTable: [UInt32] = (0...255).map { value in
    let percent = Double(value) / 255 * 100
    let (r, g, b) = bands.last { $0.range.contains(percent) }?.rgb ?? (UInt8(value), UInt8(value), UInt8(value))
    return UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
  }

  static func falseColour(luma: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt32] {
    var out = [UInt32](repeating: 0, count: width * height)
    falseColourTable.withUnsafeBufferPointer { table in
      for y in 0..<height {
        let row = y * bytesPerRow
        for x in 0..<width { out[y * width + x] = table[Int(luma[row + x])] }
      }
    }
    return out
  }

  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "VideoPrompter.camera.exposure")
  private var lastSampled = 0.0
  private var settings: Settings
  private let onFrame: @Sendable (Frame?) -> Void

  init(settings: Settings, onFrame: @escaping @Sendable (Frame?) -> Void) {
    self.settings = settings
    self.onFrame = onFrame
    super.init()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelBufferWidthKey as String: Self.width,
      kCVPixelBufferHeightKey as String: Self.height,
    ]
    output.setSampleBufferDelegate(self, queue: queue)
  }

  func update(_ settings: Settings) { queue.async { self.settings = settings } }

  func attach(to session: AVCaptureSession) {
    guard !session.outputs.contains(output) else { return }
    session.beginConfiguration()
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
  }
  func detach(from session: AVCaptureSession) {
    guard session.outputs.contains(output) else { return }
    session.beginConfiguration()
    session.removeOutput(output)
    session.commitConfiguration()
    onFrame(nil)
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    let now = CACurrentMediaTime()
    guard now - lastSampled >= 1.0 / 15, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lastSampled = now
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
    let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    let luma = UnsafeRawBufferPointer(start: base, count: stride * height)
    func image(_ pixels: [UInt32]) -> CGImage? {
      var pixels = pixels
      return pixels.withUnsafeMutableBytes { raw in
        CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
      }
    }
    var frame = Frame()
    if settings.zebras {
      frame.zebraMask = image(Self.mask(
        luma: luma, width: width, height: height, bytesPerRow: stride, codes: Self.zebraCodes(level: settings.zebraLevel, range: settings.zebraRange)))
    }
    if settings.falseColour {
      frame.falseColour = image(Self.falseColour(luma: luma, width: width, height: height, bytesPerRow: stride))
    }
    onFrame(frame)
  }
}

/// Here rather than in CameraGuides.swift, which the iPad app compiles without this file.
extension CameraGuides {
  var exposure: CameraExposure.Settings {
    CameraExposure.Settings(zebras: zebras, zebraLevel: zebraLevel, zebraRange: zebraRange, falseColour: falseColour)
  }
}
