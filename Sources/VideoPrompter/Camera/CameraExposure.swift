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
/// `@unchecked Sendable`: settings, sampling clock and scratch arrays are confined to `queue`.
final class CameraExposure: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  struct Settings: Equatable, Sendable {
    var zebras = false
    var zebraLevel = 95
    var zebraRange = 0
    var falseColour = false
    var isOn: Bool { zebras || falseColour }
    var skinCodes: ClosedRange<UInt8>? {
      zebraRange > 0 ? CameraExposure.zebraCodes(level: zebraLevel, range: zebraRange) : nil
    }
    var colourTable: [UInt32] { CameraExposure.falseColourTable(skin: skinCodes) }
    var zebraRangeLabel: String {
      zebraRange > 0 ? "\(max(0, zebraLevel - zebraRange)) to \(min(100, zebraLevel + zebraRange))" : "\(zebraLevel)+"
    }
    var zebraReadout: String {
      zebraRange > 0 ? "Stripes on \(zebraRangeLabel) IRE" : "Stripes on \(zebraLevel) IRE and above"
    }
    var zebraLegend: String {
      zebraRange > 0 ? "Zebras: Range \(zebraRangeLabel) IRE" : "Zebras: Limit \(zebraLevel) IRE and above"
    }
    var legendBands: [LegendBand] {
      let table = colourTable
      let labels = ["Crushed", "Very dark", "Mid grey", "Skin", "Near white", "Clipped"]
      return CameraExposure.bands.enumerated().compactMap { index, band in
        let (r, g, b) = band.rgb
        let colour = UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
        let codes = table.indices.filter { table[$0] == colour }
        guard !codes.isEmpty else { return nil }
        let range: String
        if index == 3, skinCodes != nil {
          range = zebraRangeLabel
        } else if skinCodes.map({ CameraExposure.codesForBand(band.range).overlaps($0) }) == true {
          // A skin band can split a colour in two. Do not label the missing middle as coloured.
          var runs: [ClosedRange<Int>] = []
          for code in codes {
            if let last = runs.last, code == last.upperBound + 1 {
              runs[runs.count - 1] = last.lowerBound...code
            } else { runs.append(code...code) }
          }
          range = runs.map {
            "\(Self.ireLabel($0.lowerBound)) to \(Self.ireLabel($0.upperBound))"
          }.joined(separator: ", ")
        } else {
          range = "\(band.range.lowerBound.formatted()) to \(band.range.upperBound.formatted())"
        }
        return LegendBand(label: index == 3 && skinCodes == nil ? "Brighter mid-tones" : labels[index], range: range, colour: colour)
      }
    }
    private static func ireLabel(_ code: Int) -> String {
      (Double(code) / 255 * 100).formatted(.number.precision(.fractionLength(0...1)))
    }
  }
  struct LegendBand {
    let label: String
    let range: String
    let colour: UInt32
  }

  private static func codesForBand(_ range: ClosedRange<Double>) -> ClosedRange<UInt8> {
    code(ire: range.lowerBound)...code(ire: range.upperBound)
  }

  struct Frame: @unchecked Sendable {
    var zebraMask: CGImage?
    var falseColour: CGImage?
  }

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
  static let falseColourTable = falseColourTable(skin: nil)
  /// With a zebra band set (± range), the pink band moves from ARRI's 52–56% onto those codes,
  /// so false colour and zebras agree on where skin should sit.
  static func falseColourTable(skin: ClosedRange<UInt8>?) -> [UInt32] {
    let pink = bands[3]
    return (0...255).map { value in
      let percent = Double(value) / 255 * 100
      var band = bands.last { $0.range.contains(percent) }
      if let skin { band = skin.contains(UInt8(value)) ? pink : band?.name == pink.name ? nil : band }
      let (r, g, b) = band?.rgb ?? (UInt8(value), UInt8(value), UInt8(value))
      return UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }
  }

  static func falseColour(luma: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                          table: [UInt32] = falseColourTable) -> [UInt32] {
    var out = [UInt32](repeating: 0, count: width * height)
    table.withUnsafeBufferPointer { table in
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
    ]
    output.setSampleBufferDelegate(self, queue: queue)
  }

  func update(_ settings: Settings) { queue.async { self.settings = settings } }

  func attach(to session: AVCaptureSession) {
    guard !session.outputs.contains(output) else { return }
    session.beginConfiguration()
    if session.canAddOutput(output) {
      session.addOutput(output)
      CameraRotation.keepSensorOrientation(output.connection(with: .video))
    }
    session.commitConfiguration()
  }
  func restoreConnectionOrientation() {
    CameraRotation.keepSensorOrientation(output.connection(with: .video))
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
    onFrame(process(pixels, settings: settings))
  }

  private var zebraPixels = [UInt32]()
  private var colourPixels = [UInt32]()
  private var cachedSettings: Settings?
  private var zebraTable = [UInt32](repeating: 0, count: 256)
  private var colourTable = CameraExposure.falseColourTable

  /// Serial exposure queue only. Capture output size hints are not honoured by every device.
  /// Bound the actual delivered plane, preserve its shape and never rotate recording pixels.
  func process(_ pixels: CVPixelBuffer, settings: Settings) -> Frame {
    guard settings.isOn else { return Frame() }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard CVPixelBufferIsPlanar(pixels),
      let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return Frame() }
    let sourceWidth = CVPixelBufferGetWidthOfPlane(pixels, 0)
    let sourceHeight = CVPixelBufferGetHeightOfPlane(pixels, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    let scale = min(1, 960.0 / Double(max(sourceWidth, sourceHeight)))
    let width = max(1, Int(Double(sourceWidth) * scale))
    let height = max(1, Int(Double(sourceHeight) * scale))
    let count = width * height
    if settings.zebras, zebraPixels.count != count { zebraPixels = [UInt32](repeating: 0, count: count) }
    if settings.falseColour, colourPixels.count != count { colourPixels = [UInt32](repeating: 0, count: count) }
    if cachedSettings != settings {
      let codes = Self.zebraCodes(level: settings.zebraLevel, range: settings.zebraRange)
      for value in 0...255 { zebraTable[value] = codes.contains(UInt8(value)) ? .max : 0 }
      colourTable = settings.colourTable
      cachedSettings = settings
    }
    let luma = base.assumingMemoryBound(to: UInt8.self)
    let drawsZebras = settings.zebras, drawsColour = settings.falseColour
    zebraPixels.withUnsafeMutableBufferPointer { mask in
      colourPixels.withUnsafeMutableBufferPointer { colour in
        zebraTable.withUnsafeBufferPointer { zebra in
          colourTable.withUnsafeBufferPointer { table in
            for y in 0..<height {
              let row = (y * sourceHeight / height) * stride
              for x in 0..<width {
                let value = Int(luma[row + x * sourceWidth / width])
                let index = y * width + x
                if drawsZebras { mask[index] = zebra[value] }
                if drawsColour { colour[index] = table[value] }
              }
            }
          }
        }
      }
    }
    func image(_ pixels: inout [UInt32]) -> CGImage? {
      pixels.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
      }
    }
    return Frame(zebraMask: settings.zebras ? image(&zebraPixels) : nil,
                 falseColour: settings.falseColour ? image(&colourPixels) : nil)
  }
}

/// Here rather than in CameraGuides.swift, which the iPad app compiles without this file.
extension CameraGuides {
  var exposure: CameraExposure.Settings {
    CameraExposure.Settings(zebras: zebras, zebraLevel: zebraLevel, zebraRange: zebraRange, falseColour: falseColour)
  }
}
