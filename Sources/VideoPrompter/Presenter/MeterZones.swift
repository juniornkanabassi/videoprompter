import SwiftUI

/// The meter's scale and colour zones, shared by the Mac meters and the iPad presenter's.
enum MeterZones {
  /// OBS's mapping: linear in dB from −60 to 0.
  static func position(_ dBFS: Float) -> CGFloat {
    dBFS.isFinite ? CGFloat(min(1, max(0, (dBFS + 60) / 60))) : 0
  }

  /// Green is normal speech, yellow is where Junior should peak, red is near clipping.
  static let yellowFrom: Float = -12
  static let redFrom: Float = -6

  static func zoneTrack(vertical: Bool = false) -> some View {
    LinearGradient(stops: [
      .init(color: .green, location: 0), .init(color: .green, location: position(yellowFrom)),
      .init(color: .yellow, location: position(yellowFrom)), .init(color: .yellow, location: position(redFrom)),
      .init(color: .red, location: position(redFrom)), .init(color: .red, location: 1)
    ], startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing)
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
