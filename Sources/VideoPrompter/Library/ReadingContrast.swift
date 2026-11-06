import SwiftUI

/// sRGB compositing over a white camera frame, followed by WCAG relative luminance.
enum ReadingContrast {
  static func worstCase(textHex: String, textOpacity: Double, backgroundHex: String, darkness: Double) -> Double {
    let background = rgb(backgroundHex, fallback: 0).map { $0 * clamp(darkness) + 1 - clamp(darkness) }
    let foreground = zip(rgb(textHex, fallback: 1), background).map { $0 * clamp(textOpacity) + $1 * (1 - clamp(textOpacity)) }
    let a = luminance(foreground), b = luminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
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
  var body: some View {
    if ReadingContrast.worstCase(textHex: textHex, textOpacity: textOpacity, backgroundHex: backgroundHex, darkness: darkness) < 3 {
      VStack(alignment: .leading, spacing: Space.sm) {
        Label("Text may be hard to read over a bright picture.", systemImage: "exclamationmark.triangle")
          .font(UIType.secondary).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        let readable = ReadingContrast.minimumDarkness(textHex: textHex, textOpacity: textOpacity, backgroundHex: backgroundHex)
        Button("Make Readable") { if let readable { darkness = readable } }
          .disabled(readable == nil)
        if readable == nil {
          Text("Increase Text visibility or choose a different text colour.")
            .font(UIType.secondary).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
