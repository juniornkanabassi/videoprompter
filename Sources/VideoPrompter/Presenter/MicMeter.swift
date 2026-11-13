import SwiftUI

/// Slim vertical microphone meter for the presenter's right edge, used on setup, reading and the
/// Adjust mic card. It reads the shared `InputMeter` and scales with the interface zoom, because the
/// zoom wrapper scales the whole view. One dB scale in both orientations, piecewise linear so that
/// -20 to 0 dBFS takes 60% of the length (`MeterZones.micPosition`): green is quiet to normal speech,
/// yellow (-12 to -6 dBFS) is where the presenter should peak, red above -6 is too loud, and a
/// separate lamp at 0 latches when the input clips. The numbers are always shown.
struct MicMeterView: View {
  @ObservedObject var meter: InputMeter
  /// The input actually listened to, as the Mic menu names it.
  let micName: String
  /// False where the surrounding card already names the device (the Adjust mic card): the heading
  /// and the device caption both go.
  var showsHeading = true
  /// Off means the presenter turned the microphone off: nothing is listened to or measured.
  var isListening = true
  /// The words and numbers grow by this much beyond the strip's own zoom (the Mac presenter caps the strip at
  /// 150% but lets its type follow the interface size); the columns they sit in grow with them.
  var typeScale: CGFloat = 1
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var peakHold = PeakHold()
  @State private var clipLatchUntil: TimeInterval = 0

  static let barWidth: CGFloat = 14
  /// Column widths of the vertical meter: the dB numbers, the bar, and the zone words beside it.
  static let tickColumn: CGFloat = 34
  static let zoneColumn: CGFloat = 56
  /// Width of the whole vertical strip before zoom: the two text columns at `typeScale`, the bar, the gaps and edge padding.
  static func stripWidth(typeScale: CGFloat) -> CGFloat { (tickColumn + zoneColumn) * typeScale + barWidth + 4 * Space.xs }
  private var tickWidth: CGFloat { Self.tickColumn * typeScale }
  private var zoneWidth: CGFloat { Self.zoneColumn * typeScale }
  private func size(_ points: CGFloat) -> CGFloat { points * typeScale }
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

  /// The horizontal zone words are centred on their zones: "too loud" is held inside the bar's end,
  /// and "aim here" clear of it, however narrow the meter.
  static let zoneWordWidth: CGFloat = 52
  static func zoneWordCentres(width: CGFloat) -> (aim: CGFloat, loud: CGFloat) {
    let yellow = MeterZones.micPosition(MeterZones.yellowFrom), red = MeterZones.micPosition(MeterZones.redFrom)
    let loud = min(width - zoneWordWidth / 2, width * (red + 1) / 2)
    let aim = min(loud - zoneWordWidth - Space.xs, width * (yellow + red) / 2)
    return (aim, loud)
  }

  private var aimColour: Color { MeterZones.yellow }
  private var loudColour: Color { Color(red: 1, green: 0.5, blue: 0.46) }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
      let now = ProcessInfo.processInfo.systemUptime
      let db = isListening ? Self.level(peakDBFS: meter.peakDBFS, isFresh: meter.isFresh(at: now)) : -.infinity
      let fill = MeterZones.micPosition(db)
      let clipLit = isListening && Self.clipLit(isClipping: meter.isClipping, latchedUntil: clipLatchUntil, now: now)
      GeometryReader { available in
        let horizontal = available.size.width >= 180 && available.size.height < 280
        VStack(spacing: horizontal ? Space.xs : Space.sm) {
          if showsHeading { heading }
          if horizontal { horizontalBar(fill: fill, clipLit: clipLit, now: now) } else { verticalBar(fill: fill, clipLit: clipLit, now: now) }
          readoutView(db: db, clipLit: clipLit).frame(maxWidth: .infinity)
            // Beside the readout, level with the lamp's end of the bar, so the two read together.
            .overlay(alignment: .trailing) { if horizontal && clipLit { clippedBadge(lit: true).padding(.trailing, Space.md) } }
          if showsHeading {
            Text(micName)
              .font(.system(size: size(14))).multilineTextAlignment(.center).lineLimit(2)
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
      .onChange(of: meter.isClipping, initial: true) { wasClipping, clipping in
        if clipping || wasClipping { clipLatchUntil = ProcessInfo.processInfo.systemUptime + Self.clipLatchSeconds }
      }
      .onChange(of: db, initial: true) { _, value in
        peakHold.ingest(value, at: ProcessInfo.processInfo.systemUptime)
      }
    }
  }

  private var heading: some View {
    Text("MIC")
      .font(.system(size: size(14), weight: .semibold))
      .foregroundStyle(Palette.onDarkQuiet(contrast))
  }

  /// A separate lamp at 0 dBFS: dark until the input clips, then lit for two seconds.
  private func clipLamp(lit: Bool, horizontal: Bool) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(MeterZones.red.opacity(lit ? 1 : 0.28))
      .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(lit ? 0.9 : 0.25), lineWidth: 1))
      .frame(width: horizontal ? 8 : Self.barWidth, height: horizontal ? Self.barWidth : 8)
  }

  /// The latched clip, named: a small badge that appears with the lamp and goes with it, so a past clip is
  /// never mistaken for the live level.
  private func clippedBadge(lit: Bool) -> some View {
    Text(lit ? "Clipped" : "clip").font(.system(size: size(12), weight: lit ? .bold : .regular)).lineLimit(1)
      .foregroundStyle(lit ? Color.white : Palette.onDarkQuiet(contrast))
      .padding(.horizontal, lit ? Space.xs : 0).padding(.vertical, 1)
      .background(MeterZones.red.opacity(lit ? 0.85 : 0), in: Capsule())
  }

  private func readoutView(db: Float, clipLit: Bool) -> some View {
    VStack(spacing: 0) {
      Text(!isListening ? "Mic off" : db.isFinite ? Self.readout(db).replacingOccurrences(of: " dBFS", with: "") : "No signal")
        .font(.system(size: size(db.isFinite && isListening ? 22 : 15), weight: .semibold)).monospacedDigit()
        .foregroundStyle(isListening ? MeterZones.readoutColour(db, loud: loudColour) : .white.opacity(0.7))
        .minimumScaleFactor(0.7).lineLimit(1)
      Text("dBFS").font(.system(size: size(13))).foregroundStyle(Palette.onDarkQuiet(contrast))
        .opacity(db.isFinite && isListening ? 1 : 0)
    }
  }

  private func verticalBar(fill: CGFloat, clipLit: Bool, now: TimeInterval) -> some View {
    VStack(spacing: Space.xs) {
      HStack(spacing: Space.xs) {
        Color.clear.frame(width: tickWidth, height: 1)
        clipLamp(lit: clipLit, horizontal: false)
        clippedBadge(lit: clipLit).frame(width: zoneWidth, alignment: .leading)
      }
      HStack(spacing: Space.xs) {
        // Each number is centred on its boundary: the label's centre, not its top, is the anchor.
        GeometryReader { geometry in
          ZStack {
            ForEach(Self.visibleScale(height: geometry.size.height), id: \.value) { entry in
              Text(entry.label)
                .font(.system(size: size(13))).monospacedDigit()
                .foregroundStyle(Palette.onDarkQuiet(contrast))
                .frame(width: tickWidth, alignment: .trailing)
                .position(x: tickWidth / 2, y: geometry.size.height * (1 - MeterZones.micPosition(entry.value)))
            }
          }
        }
        .frame(width: tickWidth)
        GeometryReader { geometry in
          let height = geometry.size.height
          ZStack {
            MeterZones.unlitTrack(vertical: true, scale: MeterZones.micPosition)
            MeterZones.zoneTrack(vertical: true, scale: MeterZones.micPosition).mask(alignment: .bottom) {
              Rectangle().frame(height: height * fill)
            }
            ForEach([MeterZones.yellowFrom, MeterZones.redFrom], id: \.self) { boundary in
              Rectangle().fill(.black.opacity(0.5)).frame(height: 1)
                .position(x: Self.barWidth / 2, y: height * (1 - MeterZones.micPosition(boundary)))
            }
            if isListening, let peak = peakHold.value(at: now) {
              Rectangle().fill(.white).frame(height: 2)
                .position(x: Self.barWidth / 2, y: height * (1 - MeterZones.micPosition(peak)))
            }
          }.clipShape(RoundedRectangle(cornerRadius: Space.xs))
        }
        .frame(width: Self.barWidth)
        GeometryReader { geometry in
          let height = geometry.size.height
          ZStack {
            // Each word sits on the middle of its zone, as drawn, not of its dB range.
            zoneWord("aim here", colour: aimColour, middle: (MeterZones.micPosition(MeterZones.yellowFrom) + MeterZones.micPosition(MeterZones.redFrom)) / 2, height: height)
            zoneWord("too loud", colour: loudColour, middle: (MeterZones.micPosition(MeterZones.redFrom) + 1) / 2, height: height)
          }
        }
        .frame(width: zoneWidth)
      }
    }
    .padding(.top, Space.xs).padding(.vertical, Space.sm)
    .frame(minHeight: 160, maxHeight: .infinity)
  }

  private func zoneWord(_ text: String, colour: Color, middle: CGFloat, height: CGFloat) -> some View {
    Text(text).font(.system(size: size(12), weight: .medium)).foregroundStyle(colour).lineLimit(1)
      .frame(width: zoneWidth, alignment: .leading)
      .position(x: zoneWidth / 2, y: height * (1 - middle))
  }

  private func horizontalBar(fill: CGFloat, clipLit: Bool, now: TimeInterval) -> some View {
    HStack(alignment: .top, spacing: Space.xs) {
      VStack(spacing: Space.xs) {
        // The legend row: each word centred on its zone, with a short bracket in the zone's own colour
        // under it, so the words read as the zones' names and never as numbers. The numbers sit on their own row below the bar.
        GeometryReader { geometry in
          let centres = Self.zoneWordCentres(width: geometry.size.width)
          let width = geometry.size.width
          let yellow = MeterZones.micPosition(MeterZones.yellowFrom), red = MeterZones.micPosition(MeterZones.redFrom)
          ZStack {
            Text("aim here").font(.system(size: 12, weight: .medium)).foregroundStyle(aimColour).lineLimit(1)
              .frame(width: Self.zoneWordWidth).position(x: centres.aim, y: 6)
            Text("too loud").font(.system(size: 12, weight: .medium)).foregroundStyle(loudColour).lineLimit(1)
              .frame(width: Self.zoneWordWidth).position(x: centres.loud, y: 6)
            Capsule().fill(MeterZones.yellow).frame(width: max(0, width * (red - yellow) - Space.xs), height: 2)
              .position(x: width * (yellow + red) / 2, y: 16)
            Capsule().fill(MeterZones.red).frame(width: max(0, width * (1 - red) - Space.xs), height: 2)
              .position(x: width * (red + 1) / 2, y: 16)
          }
        }.frame(height: 18) // grid: ok legend row: a word line and its bracket
        GeometryReader { geometry in
          ZStack {
            MeterZones.unlitTrack(vertical: false, scale: MeterZones.micPosition)
            MeterZones.zoneTrack(vertical: false, scale: MeterZones.micPosition).mask(alignment: .leading) {
              Rectangle().frame(width: geometry.size.width * fill)
            }
            ForEach([MeterZones.yellowFrom, MeterZones.redFrom], id: \.self) { boundary in
              Rectangle().fill(.black.opacity(0.5)).frame(width: 1)
                .position(x: geometry.size.width * MeterZones.micPosition(boundary), y: Self.barWidth / 2)
            }
            if isListening, let peak = peakHold.value(at: now) {
              Rectangle().fill(.white).frame(width: 2)
                .position(x: geometry.size.width * MeterZones.micPosition(peak), y: Self.barWidth / 2)
            }
          }.clipShape(RoundedRectangle(cornerRadius: Space.xs))
        }.frame(height: Self.barWidth)
        GeometryReader { geometry in
          ZStack {
            ForEach(Self.visibleScale(width: geometry.size.width), id: \.value) { entry in
              Text(entry.label)
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.onDarkQuiet(contrast)).fixedSize()
                .position(x: geometry.size.width * MeterZones.micPosition(entry.value), y: 8)
            }
          }
        }.frame(height: 16)
      }
      // At 0 dBFS, beside the bar's loud end and level with the bar.
      clipLamp(lit: clipLit, horizontal: true).padding(.top, 18 + Space.xs) // grid: ok the legend row above the bar
    }
    // Room for the end numbers, which are centred on -60 and 0.
    .padding(.horizontal, Space.md)
  }
}
