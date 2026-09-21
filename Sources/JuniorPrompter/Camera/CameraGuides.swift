import AVFoundation
import CoreGraphics
import Foundation

/// A frame marker's shape. Junior shoots open gate, so the sensor frame is wider than what he
/// delivers: the marker is the delivery aspect drawn inside the picture he actually gets.
struct CameraAspect: Codable, Equatable, Hashable, Identifiable, Sendable {
  var width: Double
  var height: Double
  var id: String { label }
  var label: String { "\(trim(width)):\(trim(height))" }
  var isValid: Bool { width > 0 && height > 0 }
  private func trim(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
  }
  /// The largest rectangle of this shape that fits inside `rect`, centred. Nothing is cropped
  /// from the picture: the marker only draws where the delivered frame lands.
  func fitted(in rect: CGRect) -> CGRect {
    CameraRotation.none.fittedRect(aspect: CGSize(width: width, height: height), in: rect)
  }
  /// The shapes offered in the picker; anything else is typed in as a custom W:H.
  static let presets = [
    CameraAspect(width: 9, height: 16), CameraAspect(width: 16, height: 9),
    CameraAspect(width: 4, height: 5), CameraAspect(width: 1, height: 1),
    CameraAspect(width: 4, height: 3),
  ]
}

/// How the delivered frame's pixels are meant to be read. The S1II's 6K open gate is 3:2, and a
/// DeckLink can hand the whole of it over squeezed into a 16:9 UHD frame; stretched back out,
/// nothing is lost. Nothing cropped before the Mac can be brought back this way.
enum CameraInputAspect: String, CaseIterable, Codable, Identifiable, Sendable {
  case asDelivered, openGate3x2
  var id: String { rawValue }
  var label: String {
    switch self {
    case .asDelivered: "As delivered"
    case .openGate3x2: "3:2 open gate"
    }
  }
  /// The picture's shape before rotation: the delivered frame's own, or 3:2 however it arrived.
  func pictureSize(delivered: CGSize) -> CGSize {
    switch self {
    case .asDelivered: delivered
    case .openGate3x2: CGSize(width: 3, height: 2)
    }
  }
  /// Aspect-fit keeps the delivered shape; the open gate fills the 3:2 rectangle it is laid on,
  /// which is the unsqueeze. Geometry only: the layer scales the frame, nothing is copied.
  var videoGravity: AVLayerVideoGravity {
    switch self {
    case .asDelivered: .resizeAspect
    case .openGate3x2: .resize
    }
  }
}

/// What the camera overlay draws, remembered for each camera. Rotation lives here too: the
/// DeckLink's vertical feed and the built-in FaceTime camera do not want the same one.
struct CameraGuides: Codable, Equatable, Sendable {
  var rotation = CameraRotation.none
  /// Read before rotation, so an unsqueezed open gate turned 90° is 2:3.
  var inputAspect = CameraInputAspect.asDelivered
  /// Vision picks the rotation while this is on. A manual choice switches it back off.
  var automaticRotation = false
  var thirds = false
  var axes = false
  var bullseye = false
  /// Blue by default, like the markers on a camera monitor.
  var colorHex = "#3F8CFF"
  var opacity = 0.85
  /// The delivery frame to mark out, or nothing for no marker.
  var marker: CameraAspect?
  /// How dark everything outside the marker goes.
  var shadeOpacity = 0.5

  /// Colour and opacity together, as the guide layer is stroked with.
  var strokeColor: CGColor {
    Self.color(colorHex, alpha: opacity) ?? Self.color("#3F8CFF", alpha: opacity)!
  }
  /// Everything outside the frame marker goes this much darker.
  var shadeColor: CGColor { CGColor(red: 0, green: 0, blue: 0, alpha: shadeOpacity) }
  static func color(_ hex: String, alpha: Double) -> CGColor? {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
    return CGColor(
      red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
      blue: CGFloat(number & 255) / 255, alpha: alpha)
  }

  init() {}
  /// Lenient, so a preference written by an older build keeps whatever it did set.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    rotation = CameraRotation(rawValue: try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0) ?? .none
    inputAspect = try c.decodeIfPresent(String.self, forKey: .inputAspect)
      .flatMap(CameraInputAspect.init) ?? .asDelivered
    automaticRotation = try c.decodeIfPresent(Bool.self, forKey: .automaticRotation) ?? false
    thirds = try c.decodeIfPresent(Bool.self, forKey: .thirds) ?? false
    axes = try c.decodeIfPresent(Bool.self, forKey: .axes) ?? false
    bullseye = try c.decodeIfPresent(Bool.self, forKey: .bullseye) ?? false
    colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#3F8CFF"
    opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.85
    marker = try c.decodeIfPresent(CameraAspect.self, forKey: .marker)
    shadeOpacity = try c.decodeIfPresent(Double.self, forKey: .shadeOpacity) ?? 0.5
  }
}

/// One defaults key holds every camera's guides, keyed by `AVCaptureDevice.uniqueID` — names
/// repeat across identical cameras, unique IDs do not.
struct CameraGuideStore {
  private static let key = "cameraGuides"
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func guides(for uid: String?) -> CameraGuides {
    guard let uid, let stored = defaults.dictionary(forKey: Self.key)?[uid] as? Data,
      let value = try? JSONDecoder().decode(CameraGuides.self, from: stored)
    else { return CameraGuides() }
    return value
  }
  func set(_ guides: CameraGuides, for uid: String?) {
    guard let uid, let data = try? JSONEncoder().encode(guides) else { return }
    var all = defaults.dictionary(forKey: Self.key) ?? [:]
    all[uid] = data
    defaults.set(all, forKey: Self.key)
  }
}

/// The overlay's geometry. Two paths, both rebuilt only on layout or a settings change — the
/// layers that draw them are `CAShapeLayer`s, so there is no per-frame work anywhere here.
@MainActor enum CameraOverlay {
  /// What the guides are measured against: the frame marker when one is set, otherwise the whole
  /// picture. Thirds on an open-gate feed are useless unless they follow the delivered frame.
  static func guideRect(picture: CGRect, guides: CameraGuides) -> CGRect {
    guides.marker.map { $0.fitted(in: picture) } ?? picture
  }

  /// Everything stroked in the guide colour: the marker outline, the thirds grid, the centre
  /// axes and the centre bullseye.
  static func guidePath(picture: CGRect, guides: CameraGuides) -> CGPath {
    let frame = guideRect(picture: picture, guides: guides)
    let path = CGMutablePath()
    guard !frame.isEmpty else { return path }
    if guides.marker != nil {
      // Four segments rather than `addRect`, so the whole stroked path stays one list of lines.
      let corners = [
        CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
        CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY),
      ]
      for (index, corner) in corners.enumerated() {
        path.move(to: corner)
        path.addLine(to: corners[(index + 1) % corners.count])
      }
    }
    path.addPath(Self.thirdsAndAxes(in: frame, thirds: guides.thirds, axes: guides.axes))
    if guides.bullseye {
      let radius = min(frame.width, frame.height) * 0.045
      let centre = CGPoint(x: frame.midX, y: frame.midY)
      path.addEllipse(in: CGRect(
        x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
      let arm = radius * 2.2
      path.move(to: CGPoint(x: centre.x - arm, y: centre.y))
      path.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
      path.move(to: CGPoint(x: centre.x, y: centre.y - arm))
      path.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
    }
    return path
  }

  /// Straight lines only: two thirds lines each way, and the centre cross.
  static func thirdsAndAxes(in rect: CGRect, thirds: Bool, axes: Bool) -> CGPath {
    let path = CGMutablePath()
    func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
    if thirds {
      for step in 1...2 {
        let x = rect.minX + rect.width * CGFloat(step) / 3
        let y = rect.minY + rect.height * CGFloat(step) / 3
        line(CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY))
        line(CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y))
      }
    }
    if axes {
      line(CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY))
      line(CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY))
    }
    return path
  }

  /// What falls outside the frame marker, for the dimmed surround. Filled even-odd, so it is the
  /// picture with the marker punched out of it; empty when there is no marker to shade around.
  static func shadePath(picture: CGRect, guides: CameraGuides) -> CGPath {
    let path = CGMutablePath()
    guard let marker = guides.marker, marker.isValid, !picture.isEmpty else { return path }
    let frame = marker.fitted(in: picture)
    guard frame != picture else { return path }
    path.addRect(picture)
    path.addRect(frame)
    return path
  }
}
