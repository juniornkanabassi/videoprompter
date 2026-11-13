import SwiftUI

/// The meter's scale and colour zones, shared by the Mac meters and the iPad presenter's.
enum MeterZones {
  /// OBS's mapping: linear in dB from −60 to 0.
  static func position(_ dBFS: Float) -> CGFloat {
    dBFS.isFinite ? CGFloat(min(1, max(0, (dBFS + 60) / 60))) : 0
  }

  /// Green is normal speech, yellow is where Junior should peak, red is too loud (and near clipping).
  static let yellowFrom: Float = -12
  static let redFrom: Float = -6

  /// The presenter's mic meter gives the range that matters, -20 to 0 dBFS, 60% of its length: the
  /// quiet half of the scale (-60 to -20) shares the rest. Piecewise linear, so the zones stay straight.
  static let micKnee: Float = -20
  static let micKneePosition: CGFloat = 0.4
  static func micPosition(_ dBFS: Float) -> CGFloat {
    guard dBFS.isFinite else { return 0 }
    let level = min(0, max(-60, dBFS))
    if level >= micKnee { return micKneePosition + (1 - micKneePosition) * CGFloat((level - micKnee) / -micKnee) }
    return micKneePosition * CGFloat((level + 60) / (micKnee + 60))
  }

  /// One saturated colour set for every meter, vertical and horizontal, so a scheme or a card never tints it.
  static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
  static let yellow = Color(red: 1, green: 0.84, blue: 0.3)
  static let red = Color(red: 0.96, green: 0.32, blue: 0.3)

  /// `scale` maps dBFS to a position: the OBS-style linear one, or `micPosition`.
  static func zoneTrack(vertical: Bool = false, scale: (Float) -> CGFloat = position) -> some View {
    LinearGradient(stops: [
      .init(color: green, location: 0), .init(color: green, location: scale(yellowFrom)),
      .init(color: yellow, location: scale(yellowFrom)), .init(color: yellow, location: scale(redFrom)),
      .init(color: red, location: scale(redFrom)), .init(color: red, location: 1)
    ], startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing)
  }
}

extension MeterZones {
  /// The part of the bar the level has not reached: a neutral track where the green is (so no half-lit green
  /// block reads as an extra zone), with the yellow and red zones faintly tinted, as their words name them.
  static func unlitTrack(vertical: Bool = false, scale: (Float) -> CGFloat = position) -> some View {
    LinearGradient(stops: [
      .init(color: .white.opacity(0.12), location: 0), .init(color: .white.opacity(0.12), location: scale(yellowFrom)),
      .init(color: yellow.opacity(0.28), location: scale(yellowFrom)), .init(color: yellow.opacity(0.28), location: scale(redFrom)),
      .init(color: red.opacity(0.28), location: scale(redFrom)), .init(color: red.opacity(0.28), location: 1)
    ], startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing)
  }

  /// The live number's colour comes from the live level alone: a past clip never tints it.
  static func readoutColour(_ dBFS: Float, loud: Color) -> Color {
    guard dBFS.isFinite else { return .white.opacity(0.7) }
    return dBFS >= redFrom ? loud : dBFS >= yellowFrom ? yellow : .white
  }
}

struct PeakHold {
  private(set) var peak: Float?
  private(set) var at = 0.0
  private(set) var generation = 0
  mutating func ingest(_ value: Float, at now: TimeInterval) {
    guard value.isFinite, value >= (self.value(at: now) ?? -.infinity) else { return }
    peak = value; at = now; generation += 1
  }
  func value(at now: TimeInterval) -> Float? {
    guard let peak else { return nil }
    let result = peak - Float(max(0, now - at - 0.4) * 11.76)
    return result >= -60 ? result : nil
  }
  mutating func expire() { peak = nil; generation += 1 }
}
