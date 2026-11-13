import SwiftUI

/// Slim vertical microphone meter for the presenter's right edge, used on setup, reading and the
/// Adjust mic card. It reads the shared `InputMeter` and scales with the interface zoom, because the
/// zoom wrapper scales the whole view. One dB scale in both orientations, piecewise linear so that
/// -20 to 0 dBFS takes 60% of the length (`MeterZones.micPosition`): green is quiet to normal speech,
/// yellow (-12 to -6 dBFS) is where the presenter should peak, red above -6 is too loud, and a
/// dark lamp at 0 lights red for two seconds when the input clips (with a two-line "Clipped earlier" button when no card is open,
/// or alone while the Adjust mic card says it in words). The numbers are always shown.
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
  /// False while the Adjust mic card is open beside the strip: the card says the clip in words, so the strip only lights its lamp.
  var showsClipBadge = true
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var peakHold = PeakHold()
  /// One latch per meter, shared by the strip and the card, so the lamp and the card's words can never disagree.
  private var clipLatch: ClipLatchBox { .shared(for: meter) }

  static let barWidth: CGFloat = 14
  /// Column widths of the vertical meter: the dB numbers, the bar, and the zone words beside it.
  static let tickColumn: CGFloat = 26
  static let zoneColumn: CGFloat = 52
  /// Width of the whole vertical strip before zoom: the two text columns at `typeScale`, the bar, the gaps and edge padding.
  static func stripWidth(typeScale: CGFloat) -> CGFloat { (tickColumn + zoneColumn) * typeScale + barWidth + 4 * Space.xs }
  private var tickWidth: CGFloat { Self.tickColumn * typeScale }
  private var zoneWidth: CGFloat { Self.zoneColumn * typeScale }
  private func size(_ points: CGFloat) -> CGFloat { points * typeScale }
  static let scale: [(value: Float, label: String)] = [
    (0, "0"), (-6, "−6"), (-12, "−12"), (-20, "−20"), (-40, "−40"), (-60, "−60")
  ]
  /// Unlabelled marks between the numbers, at 3 dB steps over the 3%-per-dB part of the bar and 10 dB steps below the knee,
  /// so the marks are an even 9 to 10% apart all the way down: that is the rule the uneven numbers sit on.
  static let minorTicks: [Float] = [-3, -9, -15, -30, -50]
  static let clipLatchSeconds: TimeInterval = 2
  /// The side strip's clip button: at least this tall and as wide as the strip, the whole of it the target.
  static let clipTarget: CGFloat = 44

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
    // The device's real name, as its card in the Adjust mic list shows it.
    return systemDefault ?? "No microphone"
  }

  /// The horizontal zone words are centred on their zones: "too loud" is held inside the bar's end,
  /// and "aim here" clear of it, however narrow the meter.
  static let zoneWordWidth: CGFloat = 60
  /// The horizontal meter's zone words, as large as the numbers beside them.
  static let zoneWordSize: CGFloat = 13
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
      let clipLit = isListening && clipLatch.isLit(isClipping: meter.isClipping, now: now)
      let clipLive = clipLit && meter.isClipping
      GeometryReader { available in
        let horizontal = available.size.width >= 180 && available.size.height < 280
        VStack(spacing: horizontal ? Space.xs : Space.sm) {
          if showsHeading { heading }
          if horizontal { horizontalBar(fill: fill, db: db, clipLit: clipLit, clipLive: clipLive, now: now) } else { verticalBar(fill: fill, db: db, clipLit: clipLit, clipLive: clipLive, now: now) }
          // The horizontal meter's clip signal sits under the loud end, level with the readout, so the bar keeps the width its zone words need.
          readoutView(db: db, clipLit: clipLit).frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
              if horizontal { clipSignal(lit: clipLit, live: clipLive, horizontal: true, earlier: true).padding(.horizontal, Space.md) }
            }
          if showsHeading {
            Text(micName)
              .font(.system(size: size(12.5))).multilineTextAlignment(.center).lineLimit(2).truncationMode(.tail).minimumScaleFactor(0.85)
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
        .accessibilityAction(named: "Clear clip warning") { clipLatch.clear() }
      }
      .onChange(of: meter.isClipping, initial: true) { wasClipping, clipping in
        if clipping || wasClipping { clipLatch.hold(from: ProcessInfo.processInfo.systemUptime, seconds: Self.clipLatchSeconds) }
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

  /// The lamp at 0 dBFS: dark, or lit red for the two seconds after the input clipped.
  private func clipLamp(horizontal: Bool, lit: Bool = false) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(MeterZones.red.opacity(lit ? 1 : 0.28))
      .overlay(RoundedRectangle(cornerRadius: 2).stroke(lit ? MeterZones.red : .white.opacity(0.25), lineWidth: 1))
      .shadow(color: lit ? MeterZones.red.opacity(0.8) : .clear, radius: 3)
      .frame(width: horizontal ? 8 : Self.barWidth, height: horizontal ? Self.barWidth : 8)
  }

  /// The clip, named, in place of the lamp: one red pill, so there is one clip signal and a past clip
  /// (a latch that holds after the level fell) is never mistaken for the live level. The side strip says "Clipped" and the
  /// Adjust card "Clipped earlier"; a past clip is a button that clears the warning, a live one is not (it would only light again).
  private func clippedPill(live: Bool, earlier: Bool) -> some View {
    let label = HStack(spacing: Space.xs) {
      Text(live ? "Clipping" : earlier ? "Clipped earlier" : "Clipped").font(.system(size: size(12), weight: .bold)).lineLimit(1).fixedSize()
      if !live { Image(systemName: "xmark").font(.system(size: size(9), weight: .bold)) }
    }
    .foregroundStyle(Color.white)
    .padding(.horizontal, Space.xs + 2).padding(.vertical, 1) // grid: ok a small capsule
    .background(MeterZones.red.opacity(0.9), in: Capsule())
    return Group {
      if live { label } else {
        Button { clipLatch.clear() } label: { label }.buttonStyle(.plain)
          .help("Click to clear").accessibilityLabel("Clear clip warning")
      }
    }
  }

  /// The horizontal meter's signal. Unlit: the dark lamp and its word. Lit: the red pill alone.
  private func clipSignal(lit: Bool, live: Bool, horizontal: Bool, earlier: Bool = false) -> some View {
    HStack(spacing: Space.xs) {
      if lit { clippedPill(live: live, earlier: earlier) }
      else { lampAndWord(lit: false, horizontal: horizontal) }
    }
  }

  private func lampAndWord(lit: Bool, horizontal: Bool) -> some View {
    HStack(spacing: Space.xs) {
      clipLamp(horizontal: horizontal, lit: lit)
      Text("clip").font(.system(size: size(12))).lineLimit(1).fixedSize()
        .foregroundStyle(lit ? loudColour : Palette.onDarkQuiet(contrast))
    }
  }

  /// The side strip's clip signal, in a slot always as tall as the button so the bar never jumps. Lit with no card open: a
  /// two-line red button, "Clipped earlier" (clears it) or "Clipping now". With the card open the card says the words, so the
  /// strip shows its lamp lit and nothing else.
  @ViewBuilder private func verticalClipSignal(lit: Bool, live: Bool) -> some View {
    if lit && showsClipBadge {
      let label = VStack(spacing: 0) {
        Text(live ? "Clipping" : "Clipped")
        HStack(spacing: Space.xs) {
          Text(live ? "now" : "earlier")
          if !live { Image(systemName: "xmark").font(.system(size: size(10), weight: .bold)) }
        }
      }
      .font(.system(size: size(13), weight: .bold)).lineLimit(1).fixedSize().foregroundStyle(Color.white)
      .padding(.vertical, Space.xs)
      .frame(maxWidth: .infinity, minHeight: Self.clipTarget)
      .background(MeterZones.red.opacity(0.9), in: RoundedRectangle(cornerRadius: Space.sm))
      .contentShape(Rectangle())
      if live { label.accessibilityLabel("Clipping now") } else {
        Button { clipLatch.clear() } label: { label }.buttonStyle(.plain)
          .help("Click to clear").accessibilityLabel("Clear clip warning")
      }
    } else {
      HStack(spacing: Space.xs) {
        Color.clear.frame(width: tickWidth, height: 1)
        lampAndWord(lit: lit, horizontal: false)
        Spacer(minLength: 0)
      }.frame(maxWidth: .infinity, minHeight: Self.clipTarget, alignment: .bottomLeading)
    }
  }

  /// The peak tick is never below the live level: a steady signal would otherwise let the held peak decay away from the bar.
  private func peakTick(db: Float, now: TimeInterval) -> Float? {
    guard isListening, db.isFinite, let held = peakHold.value(at: now) else { return nil }
    return max(held, db)
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

  private func verticalBar(fill: CGFloat, db: Float, clipLit: Bool, clipLive: Bool, now: TimeInterval) -> some View {
    VStack(spacing: Space.xs) {
      verticalClipSignal(lit: clipLit, live: clipLive)
      Color.clear.frame(height: size(4)) // keeps the pill clear of the 0 dBFS number under it
      HStack(spacing: Space.xs) {
        // Each number is centred on its boundary: the label's centre, not its top, is the anchor.
        GeometryReader { geometry in
          ZStack {
            ForEach(Self.scale, id: \.value) { entry in
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
            // Marks on the bar's left edge: long at each number, short between.
            ForEach(Self.minorTicks + Self.scale.map(\.value).filter { $0 < 0 && $0 > -60 }, id: \.self) { value in
              let major = Self.scale.contains { $0.value == value }
              Rectangle().fill(.white.opacity(major ? 0.7 : 0.4)).frame(width: major ? 6 : 3, height: 1) // grid: ok hairline marks
                .position(x: (major ? 6 : 3) / 2, y: height * (1 - MeterZones.micPosition(value)))
            }
            if let peak = peakTick(db: db, now: now) {
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

  private func horizontalBar(fill: CGFloat, db: Float, clipLit: Bool, clipLive: Bool, now: TimeInterval) -> some View {
    VStack(spacing: Space.xs) {
        // The legend row: each word centred on its zone, with a short bracket in the zone's own colour
        // under it, so the words read as the zones' names and never as numbers. The numbers sit on their own row below the bar.
        GeometryReader { geometry in
          let centres = Self.zoneWordCentres(width: geometry.size.width)
          let width = geometry.size.width
          let yellow = MeterZones.micPosition(MeterZones.yellowFrom), red = MeterZones.micPosition(MeterZones.redFrom)
          ZStack {
            Text("aim here").font(.system(size: Self.zoneWordSize, weight: .medium)).foregroundStyle(aimColour).lineLimit(1)
              .frame(width: Self.zoneWordWidth).position(x: centres.aim, y: 6)
            Text("too loud").font(.system(size: Self.zoneWordSize, weight: .medium)).foregroundStyle(loudColour).lineLimit(1)
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
            if let peak = peakTick(db: db, now: now) {
              Rectangle().fill(.white).frame(width: 2)
                .position(x: geometry.size.width * MeterZones.micPosition(peak), y: Self.barWidth / 2)
            }
          }.clipShape(RoundedRectangle(cornerRadius: Space.xs))
        }.frame(height: Self.barWidth)
        GeometryReader { geometry in
          ZStack {
            ForEach(Self.scale, id: \.value) { entry in
              Text(entry.label)
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.onDarkQuiet(contrast)).fixedSize()
                .position(x: geometry.size.width * MeterZones.micPosition(entry.value), y: 8)
            }
          }
        }.frame(height: 16)
      }
    // Room for the end numbers, which are centred on -60 and 0.
    .padding(.horizontal, Space.md)
  }
}

/// The latch a meter's views share, so one clear (the card's or the strip's button) clears every lamp and word at once.
@MainActor final class ClipLatchBox {
  private static let boxes = NSMapTable<InputMeter, ClipLatchBox>.weakToStrongObjects()
  static func shared(for meter: InputMeter) -> ClipLatchBox {
    if let box = boxes.object(forKey: meter) { return box }
    let box = ClipLatchBox()
    boxes.setObject(box, forKey: meter)
    return box
  }
  private var latch = ClipLatch()
  func hold(from now: TimeInterval, seconds: TimeInterval) { latch.hold(from: now, seconds: seconds) }
  func clear() { latch.clear() }
  func isLit(isClipping: Bool, now: TimeInterval) -> Bool { latch.isLit(isClipping: isClipping, now: now) }
}

/// How long the input's clip stays remembered, and the one way to forget it early: the pill's button.
struct ClipLatch {
  private(set) var until: TimeInterval = 0
  mutating func hold(from now: TimeInterval, seconds: TimeInterval) { until = now + seconds }
  mutating func clear() { until = 0 }
  func isLit(isClipping: Bool, now: TimeInterval) -> Bool { MicMeterView.clipLit(isClipping: isClipping, latchedUntil: until, now: now) }
}
