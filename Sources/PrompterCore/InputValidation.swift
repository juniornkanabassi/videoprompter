import Foundation

/// Rules shared by saved preferences, UI input and the command-line schema.
public enum InputValidation {
  public struct NumberRule: Sendable {
    public let range: ClosedRange<Double>
    public let fallback: Double
    public init(_ range: ClosedRange<Double>, fallback: Double) {
      self.range = range; self.fallback = fallback
    }
    public func accepts(_ value: Double) -> Bool { value.isFinite && range.contains(value) }
    public func repair(_ value: Double) -> Double {
      value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
    public var percentRange: ClosedRange<Double> { range.lowerBound * 100...range.upperBound * 100 }
  }
  public static let fontSize = NumberRule(18...120, fallback: 44)
  public static let speed = NumberRule(20...300, fallback: 120)
  public static let textOpacity = NumberRule(0.2...1, fallback: 1)
  public static let backgroundOpacity = NumberRule(0...1, fallback: 0.82)
  public static let videoDimming = NumberRule(0...1, fallback: 0.5)
  public static let guideFraction = NumberRule(0.1...0.85, fallback: 0.35)
  public static let guideOpacity = NumberRule(0...1, fallback: 0.82)
  public static let lineSpacing = NumberRule(0...0.5, fallback: 0.16)
  public static let paragraphSpacing = NumberRule(0...1, fallback: 0.34)
  public static let inputGain = NumberRule(0.25...4, fallback: 1)
  public static let textWidth = NumberRule(0.3...1, fallback: 1)
  public static let editorSize = NumberRule(12...40, fallback: 18)
  public static let zoom = NumberRule(1...2, fallback: 1)
  public static let guideVisibility = NumberRule(0...1, fallback: 0.85)
  public static let shade = NumberRule(0...1, fallback: 0.5)
  public static let zebraLevel = NumberRule(0...100, fallback: 95)
  public static let zebraRange = NumberRule(0...10, fallback: 0)
  public static let frameDimension = NumberRule(Double.leastNonzeroMagnitude...100, fallback: 1)

  public static func language(_ value: String) -> String {
    if ["Automatic", "Mixed", "English", "French"].contains(value) { return value }
    let parts = value.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
    let letters = { (byte: UInt8) in (65...90).contains(byte) || (97...122).contains(byte) }
    guard value.utf8.count <= 64, let first = parts.first, (2...8).contains(first.utf8.count),
      first.utf8.allSatisfy(letters), parts.dropFirst().allSatisfy({ part in
        (1...8).contains(part.utf8.count) && part.utf8.allSatisfy { letters($0) || (48...57).contains($0) }
      }) else { return "Automatic" }
    return value
  }

  public static func hexColour(_ value: String) -> String? {
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.utf8.count == 6, digits.utf8.allSatisfy({
      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }) else { return nil }
    return "#" + digits.uppercased()
  }

  /// APFS/HFS+ constrain both encoded bytes and UTF-16 units. Keep whole graphemes,
  /// normalise decomposed text, and reserve space for the caller's extension/suffix.
  public static func filename(_ value: String, fallback: String, suffix: String = "", separator: String = "-") -> String {
    let controls = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))
    let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(controls)
    let cleaned = value.precomposedStringWithCanonicalMapping.components(separatedBy: forbidden)
      .joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
    let source = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    var result = ""
    // 240 leaves headroom for atomic-write temporary names and filesystem bookkeeping.
    let bytes = max(0, 240 - suffix.utf8.count), units = max(0, 240 - suffix.utf16.count)
    for character in source {
      let next = result + String(character)
      let decomposed = next.decomposedStringWithCanonicalMapping
      guard max(next.utf8.count, decomposed.utf8.count) <= bytes,
        max(next.utf16.count, decomposed.utf16.count) <= units else { break }
      result = next
    }
    return (result.isEmpty ? fallback : result) + suffix
  }
}

public extension KeyedDecodingContainer {
  /// A corrupt field should not discard its valid neighbours or an entire preset list.
  func preference<T: Decodable>(_ key: Key, default fallback: T) -> T {
    (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
  }
}
