import AppKit
import SwiftUI
import CoreGraphics
import Foundation
import PrompterCore

/// A frame marker's shape. Junior shoots open gate, so the sensor frame is wider than what he
/// delivers: the marker is the delivery aspect drawn inside the picture he actually gets.
struct CameraAspect: Codable, Equatable, Hashable, Identifiable, Sendable {
  var width: Double
  var height: Double
  var id: String { label }
  var label: String { "\(trim(width)):\(trim(height))" }
  // Match the public control boundary and reject non-finite or unusable ratios.
  var isValid: Bool {
    InputValidation.frameDimension.accepts(width) && InputValidation.frameDimension.accepts(height) && (width / height).isFinite && width / height > 0
  }
  private func trim(_ value: Double) -> String {
    String(format: "%g", value)
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

/// What the camera overlay draws, remembered for each camera. Rotation lives here too: the
/// DeckLink's vertical feed and the built-in FaceTime camera do not want the same one.
struct CameraGuides: Codable, Equatable, Sendable {
  var rotation = CameraRotation.none
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
  /// Stripes over everything at or above `zebraLevel` IRE, or within ± `zebraRange` of it.
  struct SkinReference: Codable, Equatable, Sendable {
    var level = 45
    var range = 2
  }
  enum SkinTone: String, CaseIterable, Codable, Sendable {
    case deep = "Deep", brown = "Brown", medium = "Medium", light = "Light", fair = "Fair", custom = "Custom"
    var reference: SkinReference? {
      switch self {
      case .deep: SkinReference(level: 45, range: 2)
      case .brown: SkinReference(level: 50, range: 3)
      case .medium: SkinReference(level: 55, range: 3)
      case .light: SkinReference(level: 62, range: 3)
      case .fair: SkinReference(level: 68, range: 3)
      case .custom: nil
      }
    }
  }
  var selectedSkinTone: SkinTone?
  var skinTone: SkinTone { selectedSkinTone ?? (SkinTone.allCases.first { $0.reference == skinReference } ?? .custom) }
  var skinReference = SkinReference() {
    didSet {
      if skinReference != oldValue { selectedSkinTone = nil }
      if skinReference != oldValue && zebraPurpose == .faceReference {
        zebraLevel = skinReference.level; zebraRange = skinReference.range; zebraPurpose = .faceReference
      }
    }
  }
  struct GreyCardRestore: Codable, Equatable, Sendable {
    var skin: SkinReference
    var zebras: Bool
    var level: Int
    var range: Int
    var purpose: ZebraPurpose
    var savedRangeLevel: Int
    var savedRangeWidth: Int
    var savedLimitLevel: Int
    var falseColour: Bool
  }
  var greyCardRestore: GreyCardRestore?
  var greyCardCheck: Bool {
    get { greyCardRestore != nil }
    set {
      guard newValue != greyCardCheck else { return }
      if newValue {
        greyCardRestore = GreyCardRestore(skin: skinReference, zebras: zebras, level: zebraLevel, range: zebraRange, purpose: zebraPurpose, savedRangeLevel: savedRangeLevel, savedRangeWidth: savedRangeWidth, savedLimitLevel: savedLimitLevel, falseColour: falseColour)
        zebraLevel = 41; zebraRange = 2; zebras = true; falseColour = true
      } else if let previous = greyCardRestore {
        skinReference = previous.skin
        zebraLevel = previous.level; zebraRange = previous.range; zebraPurpose = previous.purpose
        zebras = previous.zebras; falseColour = previous.falseColour
        savedRangeLevel = previous.savedRangeLevel; savedRangeWidth = previous.savedRangeWidth; savedLimitLevel = previous.savedLimitLevel
        greyCardRestore = nil
      }
    }
  }
  var savedRangeLevel = 45
  var savedRangeWidth = 2
  var savedLimitLevel = 95
  var zebras = false
  var zebraLevel = 95 { didSet { if zebraLevel != oldValue { zebraPurpose = .custom } } }
  var zebraRange = 0 { didSet { if zebraRange != oldValue { zebraPurpose = .custom } } }
  var zebraPurpose = ZebraPurpose.brightAreas
  enum ZebraPurpose: String, Codable, CaseIterable {
    case brightAreas, faceReference, custom
    var label: String {
      switch self { case .brightAreas: "Highlights"; case .faceReference: "My skin"; case .custom: "Custom" }
    }
  }
  /// Lit-cheek bands: about 40 IRE for deep brown skin up to about 70 for light skin. The preset is
  /// 45 ± 2, the owner's own level for a dark complexion (6 Nov 2026, tightened from ± 5 on 7 Nov).
  static let faceLevels = 40...70, faceRanges = 2...10, faceDefault = (level: 45, range: 2)
  /// A camera seen for the first time starts with the owner's skin zebras on.
  static var firstUse: CameraGuides {
    var guides = CameraGuides()
    guides.zebras = true
    guides.useZebraPreset(.faceReference)
    return guides
  }
  var isFaceBand: Bool { zebraLevel == skinReference.level && zebraRange == skinReference.range }
  // Never infer a face reference merely from the shape of a numerical band.
  var validatedZebraPurpose: ZebraPurpose {
    switch zebraPurpose {
    case .faceReference: isFaceBand ? .faceReference : .custom
    case .brightAreas: zebraLevel == 95 && zebraRange == 0 ? .brightAreas : .custom
    case .custom: .custom
    }
  }
  mutating func useZebraPreset(_ purpose: ZebraPurpose) {
    if purpose == .faceReference {
      if !zebraRangeMode { savedLimitLevel = zebraLevel }
      zebraLevel = skinReference.level; zebraRange = skinReference.range
    }
    if purpose == .brightAreas {
      if zebraRangeMode { savedRangeLevel = zebraLevel; savedRangeWidth = zebraRange }
      zebraLevel = 95; zebraRange = 0
    }
    zebraPurpose = purpose
  }
  var zebraRangeMode: Bool {
    get { zebraRange > 0 }
    set {
      guard newValue != zebraRangeMode else { return }
      if newValue { savedLimitLevel = zebraLevel; zebraLevel = savedRangeLevel; zebraRange = savedRangeWidth }
      else { savedRangeLevel = zebraLevel; savedRangeWidth = zebraRange; zebraLevel = savedLimitLevel; zebraRange = 0 }
    }
  }
  var zebraMeasurement: String {
    zebraRange == 0 ? "Stripes mark \(zebraLevel) IRE and above in the received picture."
      : "Stripes mark \(max(0, zebraLevel - zebraRange))–\(min(100, zebraLevel + zebraRange)) IRE in the received picture."
  }
  var zebraWarning: String? {
    guard validatedZebraPurpose == .custom, zebraLevel + zebraRange >= 90 else { return nil }
    return "This custom level is near white. Do not brighten a face to make stripes appear; important detail may be lost."
  }
  var zebraGuidance: String {
    switch validatedZebraPurpose {
    case .faceReference: "For faces, check detail on the lit cheek. Skin tones vary, so there is no single target for every face. If your camera uses a flat picture setting, follow its instructions."
    case .brightAreas: "Check bright areas. Lower exposure on your camera if important parts of the picture lose detail."
    case .custom: zebraWarning ?? "Custom measurement only, not a face exposure target."
    }
  }
  /// The picture repainted by brightness band, for setting exposure against a grey card.
  var falseColour = false

  /// Colour and opacity together, as the guide layer is stroked with.
  var strokeColor: CGColor {
    Self.color(colorHex, alpha: opacity) ?? Self.color("#3F8CFF", alpha: opacity)!
  }
  /// Everything outside the frame marker goes this much darker.
  var shadeColor: CGColor { CGColor(red: 0, green: 0, blue: 0, alpha: shadeOpacity) }
  static func color(_ hex: String, alpha: Double) -> CGColor? {
    guard let value = InputValidation.hexColour(hex), let number = UInt64(value.dropFirst(), radix: 16) else { return nil }
    return CGColor(
      red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
      blue: CGFloat(number & 255) / 255, alpha: alpha)
  }

  mutating func sanitise() {
    if let marker, !marker.isValid { self.marker = nil }
    opacity = InputValidation.guideVisibility.repair(opacity)
    shadeOpacity = InputValidation.shade.repair(shadeOpacity)
    zebraLevel = Int(InputValidation.zebraLevel.repair(Double(zebraLevel)))
    zebraRange = Int(InputValidation.zebraRange.repair(Double(zebraRange)))
    skinReference.level = min(100, max(0, skinReference.level))
    skinReference.range = min(10, max(1, skinReference.range))
    savedRangeLevel = min(100, max(0, savedRangeLevel))
    savedRangeWidth = min(10, max(1, savedRangeWidth))
    savedLimitLevel = min(100, max(0, savedLimitLevel))
    colorHex = PrompterSettings.normalisedHexColour(colorHex) ?? "#3F8CFF"
  }

  init() {}
  /// Lenient, so a preference written by an older build keeps whatever it did set.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    rotation = CameraRotation(rawValue: c.preference(.rotation, default: 0)) ?? .none
    automaticRotation = c.preference(.automaticRotation, default: false)
    thirds = c.preference(.thirds, default: false)
    axes = c.preference(.axes, default: false)
    bullseye = c.preference(.bullseye, default: false)
    colorHex = c.preference(.colorHex, default: "#3F8CFF")
    opacity = c.preference(.opacity, default: 0.85)
    marker = c.preference(.marker, default: Optional<CameraAspect>.none)
    shadeOpacity = c.preference(.shadeOpacity, default: 0.5)
    zebras = c.preference(.zebras, default: false)
    zebraLevel = c.preference(.zebraLevel, default: 95)
    zebraRange = c.preference(.zebraRange, default: 0)
    zebraPurpose = c.preference(.zebraPurpose, default: Optional<ZebraPurpose>.none)
      ?? (zebraLevel == 95 && zebraRange == 0 ? .brightAreas : .custom)
    selectedSkinTone = c.preference(.selectedSkinTone, default: Optional<SkinTone>.none)
    skinReference = c.preference(.skinReference, default: zebraRange > 0 ? SkinReference(level: zebraLevel, range: zebraRange) : SkinReference())
    savedRangeLevel = c.preference(.savedRangeLevel, default: zebraRange > 0 ? zebraLevel : 45)
    savedRangeWidth = c.preference(.savedRangeWidth, default: zebraRange > 0 ? zebraRange : 2)
    savedLimitLevel = c.preference(.savedLimitLevel, default: zebraRange == 0 ? zebraLevel : 95)
    falseColour = c.preference(.falseColour, default: false)
    greyCardRestore = c.preference(.greyCardRestore, default: Optional<GreyCardRestore>.none)
    sanitise()
  }
}

/// One defaults key holds every camera's guides, keyed by `AVCaptureDevice.uniqueID` — names
/// repeat across identical cameras, unique IDs do not.
struct CameraGuideStore {
  private static let key = "cameraGuides"
  private static let pendingKey = "cameraPendingGuides"
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func guides(for uid: String?) -> CameraGuides {
    savedGuides(for: uid) ?? .firstUse
  }
  func savedGuides(for uid: String?) -> CameraGuides? {
    let stored = uid.flatMap { defaults.dictionary(forKey: Self.key)?[$0] as? Data }
      ?? (uid == nil ? defaults.data(forKey: Self.pendingKey) : nil)
    guard let stored,
      var value = try? JSONDecoder().decode(CameraGuides.self, from: stored)
    else { return nil }
    value.sanitise()
    // Persist every repair, including those applied by the decoder.
    if (try? JSONEncoder().encode(value)) != stored { set(value, for: uid) }
    return value
  }
  func set(_ guides: CameraGuides, for uid: String?) {
    var safeGuides = guides
    safeGuides.sanitise()
    guard let data = try? JSONEncoder().encode(safeGuides) else { return }
    guard let uid else { defaults.set(data, forKey: Self.pendingKey); return }
    var all = defaults.dictionary(forKey: Self.key) ?? [:]
    all[uid] = data
    defaults.set(all, forKey: Self.key)
  }
  func clearPendingGuides() { defaults.removeObject(forKey: Self.pendingKey) }
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

  /// Diagonal stripes across the whole picture, for the zebra layer to mask down to the bright
  /// parts. Spacing in points, so they look the same at any window size.
  static func zebraPath(picture: CGRect, spacing: CGFloat = 8) -> CGPath {
    let path = CGMutablePath()
    guard !picture.isEmpty else { return path }
    var x = picture.minX - picture.height
    while x < picture.maxX {
      path.move(to: CGPoint(x: x, y: picture.minY))
      path.addLine(to: CGPoint(x: x + picture.height, y: picture.maxY))
      x += spacing
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

// All manual exposure controls restore the saved check state before making their edit.
extension CameraGuides {
  mutating func changeExposure(_ change: (inout CameraGuides) -> Void) {
    if greyCardCheck {
      greyCardCheck = false
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: "Grey card check ended.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    change(&self)
  }
}

extension Binding where Value == CameraGuides {
  func manualExposure<T>(_ key: WritableKeyPath<CameraGuides, T>) -> Binding<T> {
    Binding<T>(get: { wrappedValue[keyPath: key] }, set: { value in
      var guides = wrappedValue
      guides.changeExposure { $0[keyPath: key] = value }
      wrappedValue = guides
    })
  }
}
