import Foundation

/// The presenter's look and behaviour, saved as named presets. Shared with the iPad app, which
/// compiles this file too, so a preset made on either reads the same on the other.
struct PrompterSettings: Codable, Equatable, Identifiable {
  var id = UUID()
  var name = "Default"
  var fontName = "Lexend Deca"
  var fontSize = 44.0
  var textOpacity = 1.0
  var backgroundOpacity = 0.82
  /// The backdrop's opacity over the camera picture; the Prompter-only 0.82 blacked it out.
  var videoDimming = 0.25
  var guideFraction = 0.35
  var guideOpacity = 0.82
  var horizontalMirror = false
  var verticalMirror = false
  var rotation = 0
  /// "Voice" or "Manual". Older builds also saved "Timed" and "Sound"; decoding maps them.
  var mode = "Voice"
  /// Manual's words per minute.
  var speed = 120.0
  var audioDeviceUID: String?
  var inputGain = 1.0
  var speechLanguage = "Mixed"
  var fontWeight = "Regular"
  var textColorHex = "#FFFFFF"
  var backgroundColorHex = "#000000"
  var lineSpacing = 0.16
  var paragraphSpacing = 0.34
  /// The script column as a fraction of the presenter's width, centred. It replaced the old
  /// fixed "Horizontal margin" (points), which could not narrow a full-screen column.
  var textWidth = 1.0 { didSet { textWidth = Self.clampedTextWidth(textWidth) } }
  /// Modes older builds saved. Timed and the old Manual become the new Manual; Sound and anything
  /// unknown become Voice.
  static let legacyModes: Set<String> = ["Timed", "Manual", "Sound"]
  static func normalisedMode(_ raw: String) -> String { ["Timed", "Manual"].contains(raw) ? "Manual" : "Voice" }
  static let textWidthRange = 0.3...1.0
  static func clampedTextWidth(_ value: Double) -> Double {
    value.isNaN ? 1 : min(max(value, textWidthRange.lowerBound), textWidthRange.upperBound)
  }
  var alignment = "Left"
  var showCues = false
  var highlightActiveWord = false
  var presenterSnappingEnabled = false
  var allowsBackwardVoiceTracking = true
  init() {}
  func backdropOpacity(withVideo: Bool) -> Double { withVideo ? videoDimming : backgroundOpacity }
  /// The inspector's one Background opacity control edits the value for the mode in use, so it is
  /// never a dead slider; each mode keeps its own stored value. Video stops at 0.9 so the
  /// picture is never blacked out.
  mutating func setBackdropOpacity(_ value: Double, withVideo: Bool) {
    if withVideo { videoDimming = value } else { backgroundOpacity = value }
  }
  static func backdropOpacityRange(withVideo: Bool) -> ClosedRange<Double> { withVideo ? 0...0.9 : 0...1 }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Default"; fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Lexend Deca"; fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 44; textOpacity = try c.decodeIfPresent(Double.self, forKey: .textOpacity) ?? 1; backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.82; videoDimming = try c.decodeIfPresent(Double.self, forKey: .videoDimming) ?? 0.25; guideFraction = try c.decodeIfPresent(Double.self, forKey: .guideFraction) ?? 0.35; guideOpacity = try c.decodeIfPresent(Double.self, forKey: .guideOpacity) ?? 0.82; horizontalMirror = try c.decodeIfPresent(Bool.self, forKey: .horizontalMirror) ?? false; verticalMirror = try c.decodeIfPresent(Bool.self, forKey: .verticalMirror) ?? false; rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0; mode = Self.normalisedMode(try c.decodeIfPresent(String.self, forKey: .mode) ?? "Voice"); speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 120; audioDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioDeviceUID); inputGain = try c.decodeIfPresent(Double.self, forKey: .inputGain) ?? 1; speechLanguage = try c.decodeIfPresent(String.self, forKey: .speechLanguage) ?? "Mixed"; fontWeight = try c.decodeIfPresent(String.self, forKey: .fontWeight) ?? "Regular"; textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"; backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? "#000000"; lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0.16; paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 0.34; textWidth = Self.clampedTextWidth(try c.decodeIfPresent(Double.self, forKey: .textWidth) ?? 1); alignment = try c.decodeIfPresent(String.self, forKey: .alignment) ?? "Left"; showCues = try c.decodeIfPresent(Bool.self, forKey: .showCues) ?? false; highlightActiveWord = try c.decodeIfPresent(Bool.self, forKey: .highlightActiveWord) ?? false; presenterSnappingEnabled = try c.decodeIfPresent(Bool.self, forKey: .presenterSnappingEnabled) ?? false; allowsBackwardVoiceTracking = try c.decodeIfPresent(Bool.self, forKey: .allowsBackwardVoiceTracking) ?? true
    fontSize = min(max(fontSize, 18), 120)
    speed = min(max(speed, 20), 300)
  }
}
