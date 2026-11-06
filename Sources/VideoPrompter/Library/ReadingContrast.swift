import SwiftUI
import PrompterCore

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

/// Computes the complete change before the button is offered; no reading aid is removed
/// unless its dimmed text cannot meet the selected type size's contrast threshold.
struct ReadingRecovery {
  let settings: PrompterSettings
  let explanation: String

  init(current: PrompterSettings, overVideo: Bool) {
    var next = current
    let threshold = current.fontSize >= 24 ? 3.0 : 4.5
    let scale = current.showCues ? 0.42 : 0.5
    let highlight = current.highlightActiveWord ? NSColor.systemYellow.hex : nil
    let backgroundName = overVideo ? "Background over camera" : "Script-only background"
    if let minimum = ReadingContrast.minimumDarkness(textHex: current.textColorHex,
      textOpacity: current.textOpacity * scale, backgroundHex: current.backgroundColorHex,
      threshold: threshold, highlightHex: highlight) {
      // Round upwards to the displayed percentage, so the stated change is exact.
      let opacity = min(1, ceil(minimum * 100) / 100)
      next.setBackdropOpacity(opacity, withVideo: overVideo)
      explanation = "Make Readable changes only \(backgroundName) to \(Int(opacity * 100))%."
    } else {
      next.backgroundColorHex = "#000000"
      next.textColorHex = "#FFFFFF"
      next.textOpacity = 1
      next.setBackdropOpacity(1, withVideo: overVideo)
      let needsHideCues = current.showCues && ReadingContrast.worstCase(textHex: "#FFFFFF",
        textOpacity: 0.42, backgroundHex: "#000000", darkness: 1) < threshold
      next.showCues = current.showCues && !needsHideCues
      explanation = "Make Readable sets Text colour to white, Background colour to black, Text visibility to 100%, and \(backgroundName) to 100%."
        + (needsHideCues ? " It also hides stage directions because they are too faint at this text size." : " It keeps stage directions and word highlighting as chosen.")
    }
    settings = next
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
  var overVideo = true
  var changeExplanation: String? = nil
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
        Label(overVideo ? "Text may be hard to read over the camera picture." : "These script colours may be hard to read.", systemImage: "exclamationmark.triangle")
          .font(UIType.secondary).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        if let makeReadable {
          Text(changeExplanation ?? "Make Readable changes the background darkness to improve text contrast.")
            .font(UIType.secondary).fixedSize(horizontal: false, vertical: true)
          Button("Make Readable", action: makeReadable)
        } else {
          let readable = ReadingContrast.minimumDarkness(textHex: textHex, textOpacity: textOpacity, backgroundHex: backgroundHex)
          if let readable {
            Text("Make Readable changes only background darkness to \(Int(ceil(readable * 100)))%.").font(UIType.secondary)
          }
          Button("Make Readable") { if let readable { darkness = ceil(readable * 100) / 100 } }.disabled(readable == nil)
          if readable == nil { Text("Increase Text visibility or choose a different text colour.").font(UIType.secondary) }
        }
      }
    }
  }
}
