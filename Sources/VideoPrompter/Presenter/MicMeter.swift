import SwiftUI

/// Vertical microphone meter for the presenter's right edge. It reads the shared `InputMeter`
/// and scales with the interface zoom, because the zoom wrapper scales the whole view.
struct MicMeterView: View {
  @ObservedObject var meter: InputMeter
  let micName: String
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var peakHold = PeakHold()
  @State private var clipLatchUntil: TimeInterval = 0

  static let barWidth: CGFloat = 34
  static let scale: [(value: Float, label: String)] = [
    (0, "0"), (-6, "−6"), (-18, "−18"), (-30, "−30"), (-45, "−45"), (-60, "−60")
  ]
  static let clipLatchSeconds: TimeInterval = 2

  /// A stale meter shows silence, so the bar falls and the readout says "No signal".
  static func level(peakDBFS: Float, isFresh: Bool) -> Float { isFresh ? peakDBFS : -.infinity }

  static func readout(_ dBFS: Float) -> String {
    guard dBFS.isFinite else { return "No signal" }
    return "\(Int(dBFS.rounded())) dBFS".replacingOccurrences(of: "-", with: "−")
  }

  /// The CLIP light stays lit for two seconds after the input last clipped.
  static func clipLit(isClipping: Bool, latchedUntil: TimeInterval, now: TimeInterval) -> Bool {
    isClipping || now < latchedUntil
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
      let now = ProcessInfo.processInfo.systemUptime
      let db = Self.level(peakDBFS: meter.peakDBFS, isFresh: meter.isFresh(at: now))
      let fill = InputLevelMeter.position(db)
      let clipLit = Self.clipLit(isClipping: meter.isClipping, latchedUntil: clipLatchUntil, now: now)
      GeometryReader { available in
      let horizontal = available.size.height < 360
      VStack(spacing: Space.sm) {
        Text("MIC").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.onDarkQuiet(contrast))
        Text("CLIP")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white.opacity(clipLit ? 1 : 0))
          .padding(.horizontal, Space.xs)
          .background(Capsule().fill(Color.red.opacity(clipLit ? 0.9 : 0)))
        if horizontal {
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              InputLevelMeter.zoneTrack(vertical: false).opacity(0.2)
              InputLevelMeter.zoneTrack(vertical: false).mask(alignment: .leading) {
                Rectangle().frame(width: geometry.size.width * fill)
              }
              ForEach([-18, -6], id: \.self) { boundary in
                Rectangle().fill(.white.opacity(0.65)).frame(width: 1)
                  .offset(x: geometry.size.width * InputLevelMeter.position(Float(boundary)))
              }
              if let peak = peakHold.value(at: now) {
                Rectangle().fill(.white).frame(width: 2)
                  .offset(x: geometry.size.width * InputLevelMeter.position(peak))
              }
            }
          }.frame(height: Self.barWidth)
          HStack(spacing: 0) { Text("−60"); Spacer(minLength: 0); Text("0") }.font(.system(size: 14))
        } else {
        HStack(spacing: Space.xs) {
          GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
              ForEach(Self.scale.indices, id: \.self) { index in
                let entry = Self.scale[index]
                if geometry.size.height >= 260 || ![-30, -45].contains(entry.value) {
                Text(entry.label)
                  .font(.system(size: 14)).monospacedDigit()
                  .foregroundStyle(Palette.onDarkQuiet(contrast))
                  .offset(y: geometry.size.height * (1 - InputLevelMeter.position(entry.value)) - 8)
                }
              }
            }
          }
          .frame(width: 40)
          GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
              InputLevelMeter.zoneTrack(vertical: true).opacity(0.2)
              InputLevelMeter.zoneTrack(vertical: true).mask(alignment: .bottom) {
                Rectangle().frame(height: height * fill)
              }
              ForEach([-18, -6], id: \.self) { boundary in
                Rectangle().fill(.white.opacity(0.65)).frame(height: 1)
                  .offset(y: -height * InputLevelMeter.position(Float(boundary)))
              }
              if let peak = peakHold.value(at: now) {
                Rectangle().fill(.white).frame(height: 2)
                  .offset(y: -height * InputLevelMeter.position(peak))
              }
            }
          }
          .frame(width: Self.barWidth)
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        }
        Text(db.isFinite ? Self.readout(db).replacingOccurrences(of: " dBFS", with: "") : "No signal")
          .font(.system(size: 22, weight: .semibold)).monospacedDigit()
          .foregroundStyle(.white).minimumScaleFactor(0.7).lineLimit(1)
        if db.isFinite { Text("dBFS").font(.system(size: 13)).foregroundStyle(Palette.onDarkQuiet(contrast)) }
        Text(micName)
          .font(.system(size: 14)).multilineTextAlignment(.center).lineLimit(2)
          .foregroundStyle(Palette.onDarkQuiet(contrast))
      }
      .padding(.horizontal, Space.sm)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Microphone level, \(micName), \(Self.readout(db))" + (clipLit ? ", Clipping" : ""))
      .accessibilityValue(Self.readout(db) + (clipLit ? ", Clipping" : ""))
      .accessibilityHint(clipLit ? "Input is clipping." : "Warning zones at minus 18 and minus 6 dBFS.")
      }
      .onChange(of: meter.isClipping, initial: true) { _, clipping in
        if clipping { clipLatchUntil = ProcessInfo.processInfo.systemUptime + Self.clipLatchSeconds }
      }
      .onChange(of: db, initial: true) { _, value in
        peakHold.ingest(value, at: ProcessInfo.processInfo.systemUptime)
      }
    }
  }
}
