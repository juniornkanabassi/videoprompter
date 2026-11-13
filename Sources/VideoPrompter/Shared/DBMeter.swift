import SwiftUI

struct DBMeter: View {
  var levelDB: Double
  var peakDB: Double? = nil
  var axis: Axis
  var showsScale = true

  nonisolated static let ticks: [Double] = [0, -6, -12, -24, -36, -48, -60]
  enum Band { case green, yellow, red }
  nonisolated static func fraction(_ db: Double) -> Double {
    guard !db.isNaN else { return 0 }
    return min(1, max(0, (db + 60) / 60))
  }
  nonisolated static func band(_ db: Double) -> Band { db <= -12 ? .green : db <= -6 ? .yellow : .red }
  private static let colours: [Color] = [Color(red: 0.37, green: 0.76, blue: 0.54), Color(red: 0.96, green: 0.81, blue: 0.29), Color(red: 0.89, green: 0.41, blue: 0.36)]

  var body: some View {
    let vertical = axis == .vertical
    VStack(spacing: 4) {
      Text("\(Int((levelDB.isFinite ? min(0, max(-60, levelDB)) : -60).rounded())) dB")
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
      GeometryReader { geometry in
        let length = vertical ? geometry.size.height : geometry.size.width
        ZStack(alignment: vertical ? .bottomLeading : .leading) {
          RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12))
          // Segments retain their fixed scale positions as the signal changes.
          ForEach(0..<3) { index in
            let starts = [0.0, 0.8, 0.9]
            let ends = [0.8, 0.9, 1.0]
            let active = max(0, min(Self.fraction(levelDB), ends[index]) - starts[index])
            Rectangle().fill(Self.colours[index])
              .frame(width: vertical ? nil : length * active, height: vertical ? length * active : nil)
              .offset(x: vertical ? 0 : length * starts[index], y: vertical ? -length * starts[index] : 0)
          }
          if let peakDB {
            Rectangle().fill(.white)
              .frame(width: vertical ? nil : 2, height: vertical ? 2 : nil)
              .offset(x: vertical ? 0 : min(length - 2, length * Self.fraction(peakDB)), y: vertical ? -min(length - 2, length * Self.fraction(peakDB)) : 0)
          }
        }.clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .frame(width: vertical ? 12 : nil, height: vertical ? nil : 12)
      .overlay(alignment: vertical ? .leading : .bottomLeading) {
        if showsScale {
          GeometryReader { geometry in
            ForEach(Self.ticks, id: \.self) { tick in
              Text("\(Int(tick))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .fixedSize()
                .position(x: vertical ? -12 : geometry.size.width * Self.fraction(tick),
                          y: vertical ? geometry.size.height * (1 - Self.fraction(tick)) : geometry.size.height + 10)
            }
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Audio level")
    .accessibilityValue("\(Int((levelDB.isFinite ? min(0, max(-60, levelDB)) : -60).rounded())) decibels")
  }
}
