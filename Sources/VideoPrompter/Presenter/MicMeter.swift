import SwiftUI

/// Slim vertical microphone meter for the presenter's right edge, used on setup, reading and the
/// Adjust mic card. It reads the shared `InputMeter` and scales with the interface zoom, because the
/// zoom wrapper scales the whole view. Green is normal speech, yellow is where the presenter should
/// peak (-12 to -6 dBFS), red is near clipping; the numbers are always shown.
struct MicMeterView: View {
  @ObservedObject var meter: InputMeter
  /// The input actually listened to, as the Mic menu names it.
  let micName: String
  var showsHeading = true
  /// Off means the presenter turned the microphone off: nothing is listened to or measured.
  var isListening = true
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var peakHold = PeakHold()
  @State private var clipLatchUntil: TimeInterval = 0

  static let barWidth: CGFloat = 14
  static let scale: [(value: Float, label: String)] = [
    (0, "0"), (-6, "−6"), (-12, "−12"), (-20, "−20"), (-40, "−40"), (-60, "−60")
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

  /// The caption names the input the meter listens to, not whichever device the system lists first:
  /// the saved choice when it is present, else the system default.
  static func inputName(uid: String?, devices: [AudioInputDevice], systemDefault: String?) -> String {
    if let uid {
      return devices.first { $0.uid == uid }?.name ?? "Selected microphone unavailable"
    }
    return systemDefault.map { "System default · " + $0 } ?? "No microphone"
  }

  /// Short labels that always clear each other: the middle ones drop first.
  static func visibleScale(height: CGFloat) -> [(value: Float, label: String)] {
    scale.filter { entry in
      switch entry.value {
      case -40: height >= 260
      case -20: height >= 200
      default: true
      }
    }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
      let now = ProcessInfo.processInfo.systemUptime
      let db = isListening ? Self.level(peakDBFS: meter.peakDBFS, isFresh: meter.isFresh(at: now)) : -.infinity
      let fill = InputLevelMeter.position(db)
      let clipLit = isListening && Self.clipLit(isClipping: meter.isClipping, latchedUntil: clipLatchUntil, now: now)
      GeometryReader { available in
        let horizontal = available.size.height < 280
        VStack(spacing: horizontal ? Space.xs : Space.sm) {
          if showsHeading { heading(clipLit: clipLit) }
          if horizontal { horizontalBar(fill: fill, now: now) } else { verticalBar(fill: fill, now: now) }
          readoutView(db: db, clipLit: clipLit)
          Text(micName)
            .font(.system(size: 13)).multilineTextAlignment(.center).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            .help(micName)
            .foregroundStyle(Palette.onDarkQuiet(contrast))
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isListening ? "Microphone level, \(micName), \(Self.readout(db))" + (clipLit ? ", Clipping" : "") : "Microphone off, \(micName)")
        .accessibilityValue(isListening ? Self.readout(db) + (clipLit ? ", Clipping" : "") : "Off")
        .accessibilityHint(clipLit ? "Input is clipping." : "Green is normal speech, yellow is where to peak, red is near clipping at minus 6 dBFS.")
      }
      .onChange(of: meter.isClipping, initial: true) { _, clipping in
        if clipping { clipLatchUntil = ProcessInfo.processInfo.systemUptime + Self.clipLatchSeconds }
      }
      .onChange(of: db, initial: true) { _, value in
        peakHold.ingest(value, at: ProcessInfo.processInfo.systemUptime)
      }
    }
  }

  private func heading(clipLit: Bool) -> some View {
    Text(clipLit ? "CLIP" : "MIC")
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(clipLit ? .white : Palette.onDarkQuiet(contrast))
      .padding(.horizontal, Space.sm)
      .background(Capsule().fill(Color.red.opacity(clipLit ? 0.9 : 0)))
  }

  private func readoutView(db: Float, clipLit: Bool) -> some View {
    VStack(spacing: 0) {
      Text(!isListening ? "Mic off" : db.isFinite ? Self.readout(db).replacingOccurrences(of: " dBFS", with: "") : "No signal")
        .font(.system(size: db.isFinite && isListening ? 22 : 15, weight: .semibold)).monospacedDigit()
        .foregroundStyle(clipLit ? Color.red : .white.opacity(db.isFinite && isListening ? 1 : 0.7))
        .minimumScaleFactor(0.7).lineLimit(1)
      Text("dBFS").font(.system(size: 12)).foregroundStyle(Palette.onDarkQuiet(contrast))
        .opacity(db.isFinite && isListening ? 1 : 0)
    }
  }

  private func verticalBar(fill: CGFloat, now: TimeInterval) -> some View {
    HStack(spacing: Space.xs) {
      GeometryReader { geometry in
        ZStack(alignment: .topTrailing) {
          ForEach(Self.visibleScale(height: geometry.size.height), id: \.value) { entry in
            Text(entry.label)
              .font(.system(size: 12)).monospacedDigit()
              .foregroundStyle(Palette.onDarkQuiet(contrast))
              .offset(y: geometry.size.height * (1 - InputLevelMeter.position(entry.value)) - 8)
          }
        }
      }
      .frame(width: 36)
      GeometryReader { geometry in
        let height = geometry.size.height
        ZStack(alignment: .bottom) {
          InputLevelMeter.zoneTrack(vertical: true).opacity(0.2)
          InputLevelMeter.zoneTrack(vertical: true).mask(alignment: .bottom) {
            Rectangle().frame(height: height * fill)
          }
          ForEach([InputLevelMeter.yellowFrom, InputLevelMeter.redFrom], id: \.self) { boundary in
            Rectangle().fill(.white.opacity(0.55)).frame(height: 1)
              .offset(y: -height * InputLevelMeter.position(boundary))
          }
          if isListening, let peak = peakHold.value(at: now) {
            Rectangle().fill(.white).frame(height: 2)
              .offset(y: -height * InputLevelMeter.position(peak))
          }
        }.clipShape(RoundedRectangle(cornerRadius: Space.xs))
      }
      .frame(width: Self.barWidth)
    }
    .padding(.top, Space.sm)
    .frame(minHeight: 160, maxHeight: .infinity)
  }

  private func horizontalBar(fill: CGFloat, now: TimeInterval) -> some View {
    VStack(spacing: Space.xs) {
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          InputLevelMeter.zoneTrack(vertical: false).opacity(0.2)
          InputLevelMeter.zoneTrack(vertical: false).mask(alignment: .leading) {
            Rectangle().frame(width: geometry.size.width * fill)
          }
          ForEach([InputLevelMeter.yellowFrom, InputLevelMeter.redFrom], id: \.self) { boundary in
            Rectangle().fill(.white.opacity(0.55)).frame(width: 1)
              .offset(x: geometry.size.width * InputLevelMeter.position(boundary))
          }
          if isListening, let peak = peakHold.value(at: now) {
            Rectangle().fill(.white).frame(width: 2)
              .offset(x: geometry.size.width * InputLevelMeter.position(peak))
          }
        }.clipShape(RoundedRectangle(cornerRadius: Space.xs))
      }.frame(height: Self.barWidth)
      HStack(spacing: 0) { Text("−60"); Spacer(minLength: 0); Text("−12"); Spacer(minLength: 0); Text("0") }
        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.onDarkQuiet(contrast))
    }
  }
}
