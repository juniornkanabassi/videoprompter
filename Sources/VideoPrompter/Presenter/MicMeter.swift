import SwiftUI

/// Slim vertical microphone meter for the presenter's right edge, used on setup, reading and the
/// Adjust mic card. It reads the shared `InputMeter` and scales with the interface zoom, because the
/// zoom wrapper scales the whole view. One dB scale in both orientations, linear from -60 to 0 like
/// `InputLevelMeter`: green is quiet to normal speech, yellow (-12 to -6 dBFS) is where the presenter
/// should peak, red above -6 is too loud, and a separate lamp at 0 latches when the input clips.
/// The numbers are always shown.
struct MicMeterView: View {
  @ObservedObject var meter: InputMeter
  /// The input actually listened to, as the Mic menu names it.
  let micName: String
  /// False where the surrounding card already names the device (the Adjust mic card): the heading
  /// and the device caption both go.
  var showsHeading = true
  /// Off means the presenter turned the microphone off: nothing is listened to or measured.
  var isListening = true
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var peakHold = PeakHold()
  @State private var clipLatchUntil: TimeInterval = 0

  static let barWidth: CGFloat = 14
  /// Column widths of the vertical meter: the dB numbers, the bar, and the zone words beside it.
  static let tickColumn: CGFloat = 34
  static let zoneColumn: CGFloat = 56
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

  /// The same scale along the width of the horizontal meter.
  static func visibleScale(width: CGFloat) -> [(value: Float, label: String)] {
    scale.filter { entry in
      switch entry.value {
      case -40: width >= 200
      case -20: width >= 240
      default: true
      }
    }
  }

  /// Where the horizontal "aim here" word ends: over the yellow zone, but clear of "too loud".
  static func aimLabelTrailing(width: CGFloat, tooLoudWidth: CGFloat = 52) -> CGFloat {
    min(width * MeterZones.position(MeterZones.redFrom) - 3, width - tooLoudWidth - 6)
  }

  private var aimColour: Color { Color(red: 1, green: 0.84, blue: 0.3) }
  private var loudColour: Color { Color(red: 1, green: 0.5, blue: 0.46) }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
      let now = ProcessInfo.processInfo.systemUptime
      let db = isListening ? Self.level(peakDBFS: meter.peakDBFS, isFresh: meter.isFresh(at: now)) : -.infinity
      let fill = MeterZones.position(db)
      let clipLit = isListening && Self.clipLit(isClipping: meter.isClipping, latchedUntil: clipLatchUntil, now: now)
      GeometryReader { available in
        let horizontal = available.size.height < 280
        VStack(spacing: horizontal ? Space.xs : Space.sm) {
          if showsHeading { heading }
          if horizontal { horizontalBar(fill: fill, clipLit: clipLit, now: now) } else { verticalBar(fill: fill, clipLit: clipLit, now: now) }
          readoutView(db: db, clipLit: clipLit)
          if showsHeading {
            Text(micName)
              .font(.system(size: 14)).multilineTextAlignment(.center).lineLimit(2)
              .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
              .help(micName)
              .foregroundStyle(Palette.onDarkQuiet(contrast))
          }
        }
        .padding(.horizontal, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isListening ? "Microphone level, \(micName), \(Self.readout(db))" + (clipLit ? ", Clipping" : "") : "Microphone off, \(micName)")
        .accessibilityValue(isListening ? Self.readout(db) + (clipLit ? ", Clipping" : "") : "Off")
        .accessibilityHint(clipLit ? "Input is clipping." : "Green is quiet to normal speech, yellow is where to peak, red above minus 6 dBFS is too loud.")
      }
      .onChange(of: meter.isClipping, initial: true) { _, clipping in
        if clipping { clipLatchUntil = ProcessInfo.processInfo.systemUptime + Self.clipLatchSeconds }
      }
      .onChange(of: db, initial: true) { _, value in
        peakHold.ingest(value, at: ProcessInfo.processInfo.systemUptime)
      }
    }
  }

  private var heading: some View {
    Text("MIC")
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(Palette.onDarkQuiet(contrast))
  }

  /// A separate lamp at 0 dBFS: dark until the input clips, then lit for two seconds.
  private func clipLamp(lit: Bool, horizontal: Bool) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(Color.red.opacity(lit ? 1 : 0.28))
      .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(lit ? 0.9 : 0.25), lineWidth: 1))
      .frame(width: horizontal ? 8 : Self.barWidth, height: horizontal ? Self.barWidth : 8)
  }

  private func readoutView(db: Float, clipLit: Bool) -> some View {
    VStack(spacing: 0) {
      Text(!isListening ? "Mic off" : db.isFinite ? Self.readout(db).replacingOccurrences(of: " dBFS", with: "") : "No signal")
        .font(.system(size: db.isFinite && isListening ? 22 : 15, weight: .semibold)).monospacedDigit()
        .foregroundStyle(clipLit ? Color.red : .white.opacity(db.isFinite && isListening ? 1 : 0.7))
        .minimumScaleFactor(0.7).lineLimit(1)
      Text("dBFS").font(.system(size: 13)).foregroundStyle(Palette.onDarkQuiet(contrast))
        .opacity(db.isFinite && isListening ? 1 : 0)
    }
  }

  private func verticalBar(fill: CGFloat, clipLit: Bool, now: TimeInterval) -> some View {
    VStack(spacing: Space.xs) {
      HStack(spacing: Space.xs) {
        Color.clear.frame(width: Self.tickColumn, height: 1)
        clipLamp(lit: clipLit, horizontal: false)
        Text("clip").font(.system(size: 12)).foregroundStyle(clipLit ? loudColour : Palette.onDarkQuiet(contrast))
          .frame(width: Self.zoneColumn, alignment: .leading)
      }
      HStack(spacing: Space.xs) {
        // Each number is centred on its boundary: the label's centre, not its top, is the anchor.
        GeometryReader { geometry in
          ZStack(alignment: .topTrailing) {
            ForEach(Self.visibleScale(height: geometry.size.height), id: \.value) { entry in
              Text(entry.label)
                .font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(Palette.onDarkQuiet(contrast))
                .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                .offset(y: geometry.size.height * (1 - MeterZones.position(entry.value)))
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: Self.tickColumn)
        GeometryReader { geometry in
          let height = geometry.size.height
          ZStack(alignment: .bottom) {
            MeterZones.zoneTrack(vertical: true).opacity(0.28)
            MeterZones.zoneTrack(vertical: true).mask(alignment: .bottom) {
              Rectangle().frame(height: height * fill)
            }
            ForEach([MeterZones.yellowFrom, MeterZones.redFrom], id: \.self) { boundary in
              Rectangle().fill(.white.opacity(0.7)).frame(height: 1)
                .offset(y: -height * MeterZones.position(boundary))
            }
            if isListening, let peak = peakHold.value(at: now) {
              Rectangle().fill(.white).frame(height: 2)
                .offset(y: -height * MeterZones.position(peak))
            }
          }.clipShape(RoundedRectangle(cornerRadius: Space.xs))
        }
        .frame(width: Self.barWidth)
        GeometryReader { geometry in
          let height = geometry.size.height
          ZStack(alignment: .topLeading) {
            zoneWord("aim here", colour: aimColour, middle: (MeterZones.yellowFrom + MeterZones.redFrom) / 2, height: height)
            zoneWord("too loud", colour: loudColour, middle: MeterZones.redFrom / 2, height: height)
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.zoneColumn)
      }
    }
    .padding(.top, Space.xs).padding(.vertical, Space.sm)
    .frame(minHeight: 160, maxHeight: .infinity)
  }

  private func zoneWord(_ text: String, colour: Color, middle: Float, height: CGFloat) -> some View {
    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(colour).lineLimit(1).fixedSize()
      .alignmentGuide(.top) { $0[VerticalAlignment.center] }
      .offset(y: height * (1 - MeterZones.position(middle)))
  }

  private func horizontalBar(fill: CGFloat, clipLit: Bool, now: TimeInterval) -> some View {
    HStack(alignment: .top, spacing: Space.xs) {
      VStack(spacing: Space.xs) {
        GeometryReader { geometry in
          ZStack(alignment: .topLeading) {
            Text("aim here").font(.system(size: 12, weight: .medium)).foregroundStyle(aimColour).lineLimit(1).fixedSize()
              .alignmentGuide(.leading) { $0.width }
              .offset(x: Self.aimLabelTrailing(width: geometry.size.width))
            Text("too loud").font(.system(size: 12, weight: .medium)).foregroundStyle(loudColour).lineLimit(1).fixedSize()
              .alignmentGuide(.leading) { $0.width }
              .offset(x: geometry.size.width)
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(height: 16)
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            MeterZones.zoneTrack(vertical: false).opacity(0.28)
            MeterZones.zoneTrack(vertical: false).mask(alignment: .leading) {
              Rectangle().frame(width: geometry.size.width * fill)
            }
            ForEach([MeterZones.yellowFrom, MeterZones.redFrom], id: \.self) { boundary in
              Rectangle().fill(.white.opacity(0.7)).frame(width: 1)
                .offset(x: geometry.size.width * MeterZones.position(boundary))
            }
            if isListening, let peak = peakHold.value(at: now) {
              Rectangle().fill(.white).frame(width: 2)
                .offset(x: geometry.size.width * MeterZones.position(peak))
            }
          }.clipShape(RoundedRectangle(cornerRadius: Space.xs))
        }.frame(height: Self.barWidth)
        GeometryReader { geometry in
          ZStack(alignment: .topLeading) {
            ForEach(Self.visibleScale(width: geometry.size.width), id: \.value) { entry in
              Text(entry.label)
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.onDarkQuiet(contrast)).fixedSize()
                .alignmentGuide(.leading) { $0[HorizontalAlignment.center] }
                .offset(x: geometry.size.width * MeterZones.position(entry.value))
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(height: 16)
      }
      // At 0 dBFS, beside the bar's loud end and level with the bar.
      clipLamp(lit: clipLit, horizontal: true).padding(.top, 16 + Space.xs)
    }
    // Room for the end numbers, which are centred on -60 and 0.
    .padding(.horizontal, Space.md)
  }
}
