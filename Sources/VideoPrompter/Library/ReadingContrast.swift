import SwiftUI

/// A conservative WCAG bound across every possible sRGB camera pixel, including dark scenes.
enum ReadingContrast {
  static func worstCase(textHex: String, textOpacity: Double, backgroundHex: String, darkness: Double) -> Double {
    let tint = rgb(backgroundHex, fallback: 0), text = rgb(textHex, fallback: 1)
    let low = tint.map { $0 * clamp(darkness) }
    let high = low.map { $0 + 1 - clamp(darkness) }
    let foregroundLow = zip(text, low).map { $0 * clamp(textOpacity) + $1 * (1 - clamp(textOpacity)) }
    let foregroundHigh = zip(text, high).map { $0 * clamp(textOpacity) + $1 * (1 - clamp(textOpacity)) }
    // sRGB luminance is monotonic in each channel. Disjoint ranges give a safe lower
    // bound; overlapping ranges cannot guarantee contrast over an unknown picture.
    if luminance(foregroundLow) > luminance(high) {
      return (luminance(foregroundLow) + 0.05) / (luminance(high) + 0.05)
    }
    if luminance(low) > luminance(foregroundHigh) {
      return (luminance(low) + 0.05) / (luminance(foregroundHigh) + 0.05)
    }
    return 1
  }

  static func minimumDarkness(textHex: String, textOpacity: Double, backgroundHex: String,
    threshold: Double = 3, highlightHex: String? = nil) -> Double? {
    func passes(_ value: Double) -> Bool {
      let colours = [textHex] + (highlightHex.map { [$0] } ?? [])
      return colours.allSatisfy {
        worstCase(textHex: $0, textOpacity: textOpacity, backgroundHex: backgroundHex, darkness: value) >= threshold
      }
    }
    if passes(0) { return 0 }
    for step in 1...1000 where passes(Double(step) / 1000) {
      var low = Double(step - 1) / 1000, high = Double(step) / 1000
      for _ in 0..<40 {
        let mid = (low + high) / 2
        if passes(mid) { high = mid } else { low = mid }
      }
      return high
    }
    return nil
  }

  private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
  private static func rgb(_ hex: String, fallback: Double) -> [Double] {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return [fallback, fallback, fallback] }
    return [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)].map { $0 / 255 }
  }
  private static func luminance(_ rgb: [Double]) -> Double {
    let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
  }
}

struct ReadingContrastWarning: View {
  let textHex: String
  let textOpacity: Double
  let backgroundHex: String
  @Binding var darkness: Double
  var minimumRunOpacity: Double = 1
  var threshold: Double = 3
  var highlightHex: String? = nil
  var body: some View {
    let opacity = textOpacity * minimumRunOpacity
    let colours = [textHex] + (highlightHex.map { [$0] } ?? [])
    if colours.contains(where: { ReadingContrast.worstCase(textHex: $0, textOpacity: opacity, backgroundHex: backgroundHex, darkness: darkness) < threshold }) {
      VStack(alignment: .leading, spacing: Space.sm) {
        Label("Text may be hard to read over the camera picture.", systemImage: "exclamationmark.triangle")
          .font(UIType.secondary).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        let readable = ReadingContrast.minimumDarkness(textHex: textHex, textOpacity: opacity, backgroundHex: backgroundHex, threshold: threshold, highlightHex: highlightHex)
        Button("Make Readable") { if let readable { darkness = readable } }
          .disabled(readable == nil)
        if readable == nil {
          Text("Increase Text visibility, hide stage directions, or choose a different text or background colour.")
            .font(UIType.secondary).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
