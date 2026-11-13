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
  /// The bands that start at a labelled threshold: red from -6 up, yellow from -12 up. Other numbers stay quiet.
  nonisolated static func thresholdBand(_ tick: Double) -> Band? { tick >= -6 ? .red : tick >= -12 ? .yellow : nil }
  private static let colours: [Color] = [Color(red: 0.37, green: 0.76, blue: 0.54), Color(red: 0.96, green: 0.81, blue: 0.29), Color(red: 0.89, green: 0.41, blue: 0.36)]
  private static func colour(_ band: Band) -> Color { colours[band == .green ? 0 : band == .yellow ? 1 : 2] }
  private static let quiet = Color.white
  /// Half a label's height, kept free above and below the bar so the end numbers are never clipped.
  private static let labelRoom: CGFloat = 10

  private var shownDB: Double { levelDB.isFinite ? min(0, max(-60, levelDB)) : -60 }

  private var readout: some View {
    Text("\(Int(shownDB.rounded()))")
      .font(.system(size: 20, weight: .bold, design: .monospaced))
      .foregroundStyle(Self.colour(Self.band(shownDB)))
      .lineLimit(1).minimumScaleFactor(0.8)
  }

  private func label(_ tick: Double) -> some View {
    Text("\(Int(tick))").font(.system(size: 16, weight: .semibold, design: .monospaced))
      .foregroundStyle(Self.thresholdBand(tick).map(Self.colour) ?? Self.quiet)
      .fixedSize()
  }

  private func bar(vertical: Bool) -> some View {
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
  }

  var body: some View {
    Group {
      if axis == .vertical {
        VStack(spacing: 8) {
          HStack(alignment: .top, spacing: 8) {
            if showsScale {
              GeometryReader { geometry in
                ForEach(Self.ticks, id: \.self) { tick in
                  label(tick).position(x: geometry.size.width - 16, y: geometry.size.height * (1 - Self.fraction(tick)))
                }
              }.frame(width: 40)
            }
            bar(vertical: true)
          }
          .padding(.vertical, showsScale ? Self.labelRoom : 0)
          readout
        }
      } else {
        VStack(spacing: 4) {
          readout
          bar(vertical: false)
            .overlay(alignment: .topLeading) {
              if showsScale {
                GeometryReader { geometry in
                  ForEach(Self.ticks, id: \.self) { tick in
                    label(tick).position(x: geometry.size.width * Self.fraction(tick), y: geometry.size.height + 14)
                  }
                }
              }
            }
            .padding(.horizontal, showsScale ? 16 : 0)
            .padding(.bottom, showsScale ? 28 : 0)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Audio level")
    .accessibilityValue("\(Int(shownDB.rounded())) decibels")
  }
}
