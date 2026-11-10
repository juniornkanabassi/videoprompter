import Foundation
import PrompterCore

/// The presenter's look and behaviour, saved as named presets. Shared with the iPad app, which
/// compiles this file too, so a preset made on either reads the same on the other.
struct PrompterSettings: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var name = "Default"
  var fontName = "Lexend Deca"
  var fontSize = 44.0 { didSet { fontSize = InputValidation.fontSize.repair(fontSize) } }
  var textOpacity = 1.0 { didSet { textOpacity = InputValidation.textOpacity.repair(textOpacity) } }
  var backgroundOpacity = 0.82 { didSet { backgroundOpacity = InputValidation.backgroundOpacity.repair(backgroundOpacity) } }
  /// The backdrop's opacity over the camera picture; the Prompter-only 0.82 blacked it out.
  var videoDimming = 0.5 { didSet { videoDimming = InputValidation.videoDimming.repair(videoDimming) } }
  var guideFraction = 0.35 { didSet { guideFraction = InputValidation.guideFraction.repair(guideFraction) } }
  var guideOpacity = 0.82 { didSet { guideOpacity = InputValidation.guideOpacity.repair(guideOpacity) } }
  var horizontalMirror = false
  var verticalMirror = false
  var rotation = 0
  /// "Voice" or "Manual". Older builds also saved "Timed" and "Sound"; decoding maps them.
  var mode = "Voice"
  /// Manual's words per minute.
  var speed = 120.0 { didSet { speed = InputValidation.speed.repair(speed) } }
  var audioDeviceUID: String?
  var inputGain = 1.0 { didSet { inputGain = InputValidation.inputGain.repair(inputGain) } }
  /// "Automatic" for new settings: one recogniser in the script's language. On 25 October the
  /// French half of "Mixed" heard English speech as noise and once sent Voice 26 words ahead.
  /// Saved settings keep their choice; missing values use automatic detection.
  var speechLanguage = "Automatic"
  var speechLocales: [String: String] = [:]
  var fontWeight = "Regular"
  var textColorHex = "#FFFFFF"
  var backgroundColorHex = "#000000"
  var lineSpacing = 0.16 { didSet { lineSpacing = InputValidation.lineSpacing.repair(lineSpacing) } }
  var paragraphSpacing = 0.34 { didSet { paragraphSpacing = InputValidation.paragraphSpacing.repair(paragraphSpacing) } }
  /// The script column as a fraction of the presenter's width, centred. It replaced the old
  /// fixed "Horizontal margin" (points), which could not narrow a full-screen column.
  var textWidth = 0.75 { didSet { textWidth = Self.clampedTextWidth(textWidth) } }
  /// Modes older builds saved. Timed and the old Manual become the new Manual; Sound and anything
  /// unknown become Voice.
  static let legacyModes: Set<String> = ["Timed", "Manual", "Sound"]
  static func normalisedMode(_ raw: String) -> String { ["Timed", "Manual"].contains(raw) ? "Manual" : "Voice" }
  static let textWidthRange = InputValidation.textWidth.range
  static func clampedTextWidth(_ value: Double) -> Double {
    InputValidation.textWidth.repair(value)
  }
  var alignment = "Left"
  var showCues = false
  var highlightActiveWord = true
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
  static func backdropOpacityRange(withVideo: Bool) -> ClosedRange<Double> { 0...1 }
  static func normalisedHexColour(_ value: String) -> String? {
    InputValidation.hexColour(value)
  }

  mutating func sanitise() {
    fontSize = InputValidation.fontSize.repair(fontSize)
    textOpacity = InputValidation.textOpacity.repair(textOpacity)
    backgroundOpacity = InputValidation.backgroundOpacity.repair(backgroundOpacity)
    videoDimming = InputValidation.videoDimming.repair(videoDimming)
    guideFraction = InputValidation.guideFraction.repair(guideFraction)
    guideOpacity = InputValidation.guideOpacity.repair(guideOpacity)
    speed = InputValidation.speed.repair(speed)
    inputGain = InputValidation.inputGain.repair(inputGain)
    lineSpacing = InputValidation.lineSpacing.repair(lineSpacing)
    paragraphSpacing = InputValidation.paragraphSpacing.repair(paragraphSpacing)
    textWidth = Self.clampedTextWidth(textWidth)
    mode = Self.normalisedMode(mode)
    let rawLanguage = speechLanguage
    speechLanguage = ScriptLanguage.setting(rawLanguage) ?? "Automatic"
    if speechLanguage != "Automatic", rawLanguage != speechLanguage,
      !ScriptLanguage.allCases.contains(where: { $0.rawValue.lowercased() == rawLanguage.lowercased() }) {
      speechLocales[speechLanguage] = rawLanguage
    }
    if ![0, 180].contains(rotation) { rotation = 0 }
    if !["Regular", "Bold"].contains(fontWeight) { fontWeight = "Regular" }
    if !["Left", "Center", "Right"].contains(alignment) { alignment = "Left" }
    if fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fontName = "Lexend Deca" }
    textColorHex = Self.normalisedHexColour(textColorHex) ?? "#FFFFFF"
    backgroundColorHex = Self.normalisedHexColour(backgroundColorHex) ?? "#000000"
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.preference(.id, default: UUID())
    name = c.preference(.name, default: "Default")
    fontName = c.preference(.fontName, default: "Lexend Deca")
    fontSize = c.preference(.fontSize, default: 44)
    textOpacity = c.preference(.textOpacity, default: 1)
    backgroundOpacity = c.preference(.backgroundOpacity, default: 0.82)
    videoDimming = c.preference(.videoDimming, default: 0.25)
    guideFraction = c.preference(.guideFraction, default: 0.35)
    guideOpacity = c.preference(.guideOpacity, default: 0.82)
    horizontalMirror = c.preference(.horizontalMirror, default: false)
    verticalMirror = c.preference(.verticalMirror, default: false)
    rotation = c.preference(.rotation, default: 0)
    mode = c.preference(.mode, default: "Voice")
    speed = c.preference(.speed, default: 120)
    inputGain = c.preference(.inputGain, default: 1)
    speechLanguage = c.preference(.speechLanguage, default: "Automatic")
    speechLocales = c.preference(.speechLocales, default: [:])
    fontWeight = c.preference(.fontWeight, default: "Regular")
    audioDeviceUID = c.preference(.audioDeviceUID, default: Optional<String>.none)
    textColorHex = c.preference(.textColorHex, default: "#FFFFFF")
    backgroundColorHex = c.preference(.backgroundColorHex, default: "#000000")
    lineSpacing = c.preference(.lineSpacing, default: 0.16)
    paragraphSpacing = c.preference(.paragraphSpacing, default: 0.34)
    textWidth = c.preference(.textWidth, default: 1)
    alignment = c.preference(.alignment, default: "Left")
    showCues = c.preference(.showCues, default: false)
    highlightActiveWord = c.preference(.highlightActiveWord, default: true)
    presenterSnappingEnabled = c.preference(.presenterSnappingEnabled, default: false)
    allowsBackwardVoiceTracking = c.preference(.allowsBackwardVoiceTracking, default: true)
    sanitise()
  }
}


extension PrompterSettings {
  var readingSummary: String {
    let following = mode == "Manual" ? "Automatic scroll · \(Int(speed)) words/min" : "Voice follow"
    return "\(following) · \(Int(fontSize)) pt · \(fontName)" + (horizontalMirror ? " · mirrored for glass" : "")
  }
}
