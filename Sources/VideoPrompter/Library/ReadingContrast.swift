import SwiftUI

/// Conservative sRGB contrast bound across all possible camera pixels.
enum ReadingContrast {
  static func worstCase(textHex: String, textOpacity: Double, backgroundHex: String, darkness: Double) -> Double {
    let backdrop = rgb(backgroundHex, fallback: 0)
    let low = backdrop.map { $0 * clamp(darkness) }
    let high = low.map { $0 + 1 - clamp(darkness) }
    let text = rgb(textHex, fallback: 1)
    let opacity = clamp(textOpacity)
    let foregroundLow = zip(text, low).map { $0 * opacity + $1 * (1 - opacity) }
    let foregroundHigh = zip(text, high).map { $0 * opacity + $1 * (1 - opacity) }
    let backgroundRange = luminance(low)...luminance(high)
    let foregroundRange = luminance(foregroundLow)...luminance(foregroundHigh)
    // Independent luminance bounds are conservative for every RGB picture, including colours
    // between black and white. An overlap can never be certified as readable.
    if foregroundRange.overlaps(backgroundRange) { return 1 }
    if foregroundRange.lowerBound > backgroundRange.upperBound {
      return (foregroundRange.lowerBound + 0.05) / (backgroundRange.upperBound + 0.05)
    }
    return (backgroundRange.lowerBound + 0.05) / (foregroundRange.upperBound + 0.05)
  }

  static func minimumDarkness(textHex: String, textOpacity: Double, backgroundHex: String) -> Double? {
    func passes(_ value: Double) -> Bool {
      worstCase(textHex: textHex, textOpacity: textOpacity, backgroundHex: backgroundHex, darkness: value) >= 3
    }
    if passes(0) { return 0 }
    // Search from light to dark, so coloured combinations also get their first passing interval.
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
  var minimumOpacityScale = 1.0
  var threshold = 3.0
  var highlightHex: String? = nil
  var makeReadable: (() -> Void)? = nil
  private var ratio: Double {
    let text = ReadingContrast.worstCase(textHex: textHex, textOpacity: textOpacity * minimumOpacityScale,
      backgroundHex: backgroundHex, darkness: darkness)
    let highlight = highlightHex.map { ReadingContrast.worstCase(textHex: $0, textOpacity: textOpacity,
      backgroundHex: backgroundHex, darkness: darkness) } ?? 21
    return min(text, highlight)
  }
  var body: some View {
    if ratio < threshold {
      VStack(alignment: .leading, spacing: Space.sm) {
        Label("Text may be hard to read over the camera picture.", systemImage: "exclamationmark.triangle")
          .font(UIType.secondary).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        if let makeReadable {
          Text("Make Readable uses solid black behind white text, full text visibility, and turns off stage directions and word highlighting.")
            .font(UIType.secondary).fixedSize(horizontal: false, vertical: true)
          Button("Make Readable", action: makeReadable)
        } else {
          let readable = ReadingContrast.minimumDarkness(textHex: textHex, textOpacity: textOpacity, backgroundHex: backgroundHex)
          Button("Make Readable") { if let readable { darkness = readable } }.disabled(readable == nil)
          if readable == nil { Text("Increase Text visibility or choose a different text colour.").font(UIType.secondary) }
        }
      }
    }
  }
}
