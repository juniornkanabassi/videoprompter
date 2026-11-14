import SwiftUI
import PrompterCore

/// Shared look of the presenter bar: one control height, one corner, one selected state.
enum PresenterBar {
  static let height = AlphaStyle.minTarget
  static let corner: CGFloat = 12 // grid: ok Matches the Alpha tile corner.
  /// Between the transport, the video-call group and the picture tools.
  static let groupGap = Space.section
  static let background = Color(white: 0.08)
  /// Fingers need 44 pt each way; the pointer's icon-only button is a little narrower.
  #if os(iOS)
  static let iconWidth = AlphaStyle.minTarget
  static let caretWidth = AlphaStyle.minTarget
  #else
  static let iconWidth: CGFloat = 0
  static let caretWidth: CGFloat = 24 // grid: ok A pointer target a little narrower than a finger's.
  #endif
  /// Side room of an icon-only button with a pointer: a bar of icons fits a narrow window or a large interface size.
  static let iconPadding: CGFloat = 6 // grid: ok
  static let warning = Color(red: 1, green: 0.45, blue: 0.42)
}

private struct BarControlHeightKey: EnvironmentKey { static let defaultValue = PresenterBar.height }
extension EnvironmentValues {
  /// One control height for the whole bar; a two-row bar at a large interface size lowers it to stay short.
  var barControlHeight: CGFloat {
    get { self[BarControlHeightKey.self] }
    set { self[BarControlHeightKey.self] = newValue }
  }
}

/// Icon, and the word beside it when there is room. The word stays as the accessibility label.
struct BarLabel: View {
  @Environment(\.barControlHeight) private var controlHeight
  let title: String
  let symbol: String
  var showsTitle = true
  var weight = Font.Weight.semibold
  /// A tool that is on keeps a neutral fill and shows it with a yellow icon, so only Start reading is yellow-filled.
  var accentIcon = false
  /// A little less room each side of the word, for a bar that is short of width.
  var snug = false
  var body: some View {
    HStack(spacing: Space.xs) {
      if accentIcon {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 24).foregroundStyle(AlphaStyle.accent)
      } else {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 24)
      }
      if showsTitle {
        Text(title).font(.system(size: 15, weight: weight)).lineLimit(1).fixedSize()
      }
    }.padding(.horizontal, showsTitle ? (snug || controlHeight < PresenterBar.height ? Space.sm : Space.md) : PresenterBar.iconPadding)
      .frame(minWidth: showsTitle ? 0 : PresenterBar.iconWidth, minHeight: controlHeight)
  }
}

/// One style for every bar button, so Start reading, the call group and the picture tools line up.
struct BarButtonStyle: ButtonStyle {
  /// `muted` is a device that is simply switched off: crossed icon on a quiet grey, not an alarm.
  enum Role { case plain, secondary, on, off, muted, prominent }
  var role = Role.plain
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.barControlHeight) private var controlHeight

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: PresenterBar.corner)
    configuration.label
      .foregroundStyle(foreground)
      .frame(minHeight: controlHeight)
      .background(shape.fill(fill))
      .overlay { if configuration.isPressed { shape.fill(.white.opacity(0.12)) } }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(shape)
  }
  private var foreground: Color {
    switch role {
    case .prominent: AlphaStyle.onAccent
    case .off: PresenterBar.warning
    case .muted: .white.opacity(0.75)
    default: .white
    }
  }
  private var fill: Color {
    switch role {
    case .prominent: AlphaStyle.accent
    case .on: .white.opacity(0.2)
    case .off: Color.red.opacity(0.18)
    case .secondary: .white.opacity(0.08)
    case .muted: .clear
    case .plain: .clear
    }
  }
}

/// A named run of controls on one soft backing: the video-call group, the picture tools. The picture
/// tools are a quieter, outlined group, so the two read as different kinds of control.
struct BarGroup<Content: View>: View {
  let label: String
  var raised = true
  @ViewBuilder var content: () -> Content
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: PresenterBar.corner)
    HStack(spacing: 0) { content() }
      .background(shape.fill(.white.opacity(raised ? 0.1 : 0)))
      .overlay(shape.stroke(.white.opacity(raised ? 0.1 : 0.22), lineWidth: 1))
      .accessibilityElement(children: .contain).accessibilityLabel(label)
  }
}

struct BarDivider: View {
  var body: some View {
    Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 24).accessibilityHidden(true)
  }
}

/// A video-call style split button: the main part turns the device on or off, the caret lists the choices.
struct BarDeviceControl<MenuContent: View>: View {
  /// Off is a warning (the microphone: Voice stops following) or just a choice (the camera).
  var offIsWarning = true
  let title: String
  /// The word while it is switched off ("Camera off"), where off is a plain state and not a warning.
  var offTitle: String? = nil
  let onSymbol: String
  let offSymbol: String
  let isOn: Bool
  var showsTitle = true
  var snug = false
  var isEnabled = true
  @Environment(\.barControlHeight) private var controlHeight
  let toggleHelp: String
  let menuLabel: String
  let menuValue: String
  let toggle: () -> Void
  @ViewBuilder var menu: () -> MenuContent
  @State private var showingDevices = false

  var body: some View {
    HStack(spacing: 0) {
      Button(action: toggle) { BarLabel(title: isOn ? title : offTitle ?? title, symbol: isOn ? onSymbol : offSymbol, showsTitle: showsTitle, snug: snug) }
        .buttonStyle(BarButtonStyle(role: isOn ? .plain : offIsWarning ? .off : .muted))
        .help(toggleHelp)
        .accessibilityLabel(title).accessibilityValue(isOn ? "On" : "Off").accessibilityAddTraits(.isToggle)
        .disabled(!isEnabled)
      Group {
      #if os(iOS)
      Button { showingDevices = true } label: {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
          .frame(width: max(44, PresenterBar.caretWidth), height: max(44, controlHeight)).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showingDevices) { menu().presentationCompactAdaptation(.popover) }
      #else
      Menu(content: menu) {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
          .frame(width: PresenterBar.caretWidth, height: controlHeight).contentShape(Rectangle())
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      #endif
      }
      .foregroundStyle(isOn ? Color.white.opacity(0.8) : offIsWarning ? PresenterBar.warning : .white.opacity(0.7))
      .help(menuLabel)
      .accessibilityLabel(menuLabel).accessibilityValue(menuValue)
    }
    .background(isOn || !offIsWarning ? Color.clear : Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: PresenterBar.corner))
    // A camera that is simply off is an empty, quiet outline (the same corner and weight as its group) and says "Camera off": nothing filled, so it never matches the lit Script pill.
    .overlay {
      if !isOn && !offIsWarning {
        RoundedRectangle(cornerRadius: PresenterBar.corner).stroke(.white.opacity(0.35), lineWidth: 1)
      }
    }
  }
}

/// A picture tool or toggle on the bar.
struct BarToggle: View {
  let title: String
  let symbol: String
  let isOn: Bool
  var showsTitle = true
  /// A shorter word to show beside the icon; the full title stays the accessibility label.
  var displayTitle: String? = nil
  var snug = false
  var help: String? = nil
  var traits: AccessibilityTraits = .isToggle
  var value: String? = nil
  let action: () -> Void
  var body: some View {
    Button(action: action) { BarLabel(title: displayTitle ?? title, symbol: symbol, showsTitle: showsTitle, accentIcon: isOn, snug: snug) }
      .buttonStyle(BarButtonStyle(role: isOn ? .on : .plain))
      .help(help ?? title)
      .accessibilityLabel(title)
      .accessibilityValue(value ?? (traits.contains(.isToggle) ? (isOn ? "On" : "Off") : ""))
      .accessibilityAddTraits(traits)
  }
}

/// The reading line: a full-width line at the reading position, as the first versions drew it.
struct GuideLine: View {
  let settings: PrompterSettings
  var body: some View {
    Rectangle().fill(.cyan.opacity(settings.guideOpacity)).frame(height: 2)
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// A calm column behind the text, the full height of the picture, so the picture and the zebras stop
/// showing through the words. It is a touch lighter than the dimmed picture around it, so the column
/// reads as a step and not as a hole. No edge lines (they read as a frame): the sides just soften.
struct ReadingBacking: View {
  let opacity: Double
  static let feather = Space.md
  /// How far the column reaches past the current-line band on each side.
  static let margin = Space.lg
  var body: some View {
    Rectangle().fill(Color(white: 0.1).opacity(opacity))
      .mask {
        HStack(spacing: 0) {
          LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: Self.feather)
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Self.feather)
        }
      }
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// The Mac presenter's reading line: a soft band that lifts the current line about 11% above the
/// backing, and under it a clear full-width line, in the gap between lines so it never crosses a letter.
struct PresenterReadingLine: View {
  let settings: PrompterSettings
  /// A line box and the gap under it: the line sits on the band's lower edge.
  static func bandHeight(fontSize: Double) -> CGFloat { fontSize * 1.3 } // grid: ok follows the line height
  var body: some View {
    ZStack(alignment: .bottom) {
      Rectangle().fill(.white.opacity(0.11))
      Rectangle().fill(Color.cyan.opacity(max(0.7, settings.guideOpacity))).frame(height: 2)
    }.frame(height: Self.bandHeight(fontSize: settings.fontSize))
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// A small status capsule: a dot for the state, then the words.
struct BarStatusPill: View {
  /// How much of the status the bar has room for: the whole line, just the state, or the dot alone.
  enum Style { case full, compact, dot }
  let text: String
  /// The mode and state ("Voice · Listening"), shown in the compact pill.
  var shortText: String? = nil
  let isActive: Bool
  var style = Style.full
  var body: some View {
    HStack(spacing: Space.sm) {
      Circle().fill(isActive ? Color.green : .white.opacity(0.4)).frame(width: 8, height: 8)
      if style != .dot { Text(style == .compact ? (shortText ?? text) : text).font(.system(size: 14, weight: .medium)).lineLimit(1) }
    }.padding(.horizontal, style == .dot ? Space.sm : Space.md).frame(minHeight: 32) // grid: ok A calm status capsule, shorter than a control.
      .background(.white.opacity(0.07), in: Capsule())
      .foregroundStyle(.white.opacity(0.85))
      .help(text)
      .accessibilityElement(children: .ignore).accessibilityLabel(text)
      .accessibilityIdentifier("presenter-status-pill")
  }
}

/// The "Editing" band across the top, with Save and Cancel where the hands already are.
struct PresenterEditingBand: View {
  var isSaving: Bool
  var compact: Bool
  var save: () -> Void
  var cancel: () -> Void
  var body: some View {
    HStack(spacing: Space.md) {
      Image(systemName: "pencil").font(.system(size: 17, weight: .semibold)).foregroundStyle(AlphaStyle.accent)
      HStack(spacing: Space.sm) {
        Text("Editing").font(.system(size: 17, weight: .semibold))
        Text("·").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
        Text("Not saved yet").font(.system(size: 17)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
      }
      Spacer(minLength: Space.md)
      Button(action: cancel) {
        HStack(spacing: Space.sm) {
          Text("Cancel").font(.system(size: 15, weight: .semibold))
          if !compact { KeyCap(text: "esc") }
        }.padding(.horizontal, Space.md).frame(minHeight: PresenterBar.height)
      }.buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Cancel editing").disabled(isSaving)
        .help("Discard this draft (Esc)")
      Button(action: save) {
        HStack(spacing: Space.sm) {
          Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
          Text("Save").font(.system(size: 15, weight: .bold))
          if !compact { KeyCap(text: "⌘↩", dark: true) }
        }.padding(.horizontal, Space.md).frame(minHeight: PresenterBar.height)
      }.buttonStyle(BarButtonStyle(role: .prominent)).accessibilityLabel("Save changes").disabled(isSaving)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Save changes to the script (⌘↩)")
    }
    .foregroundStyle(.white)
    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
    .frame(maxWidth: .infinity)
    .background(Color(white: 0.15))
    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.22)).frame(height: 1) }
    .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-editing-band")
  }
}

/// A key hint in a small outlined box: 14 pt, readable at a glance. The same box for Esc, Save and Pause.
struct KeyCap: View {
  let text: String
  var dark = false
  var body: some View {
    Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
      .foregroundStyle(dark ? AlphaStyle.onAccent.opacity(0.85) : .white.opacity(0.9))
      .padding(.horizontal, Space.sm).padding(.vertical, 2)
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(dark ? AlphaStyle.onAccent.opacity(0.45) : .white.opacity(0.45), lineWidth: 1)) // grid: ok hairline key-hint border
      .accessibilityHidden(true)
  }
}

/// Zoom for a whole pane: lays the content out in 1/scale of the space it is given and draws it
/// scaled back up, so every label, control and text view grows together. SwiftUI's own scale keeps
/// clicks on target, AppKit views inside included; an NSHostingView inside a bounds-scaled NSView
/// draws the same but stops hit-testing its AppKit subviews.
struct UIZoom: Layout {
  var scale: Double
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = subviews.first?.sizeThatFits(ProposedViewSize(
      width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })) ?? .zero
    guard scale != 1 else { return size }
    // Zoomed, a pane takes the space it is offered: passing its content's minimum on, doubled at
    // 200%, asked the split view for more than the window had and AppKit looped on constraints.
    return CGSize(width: proposal.width ?? size.width * scale, height: proposal.height ?? size.height * scale)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale))
  }
}
extension View {
  func uiZoom(_ scale: Double) -> some View { UIZoom(scale: scale) { scaleEffect(scale, anchor: .topLeading) } }
}


struct PresenterZebraSwatch: View {
  var body: some View {
    Canvas { context, size in
      let picture = CGRect(origin: .zero, size: size)
      context.fill(Path(picture), with: .color(.white))
      context.stroke(Path(CameraOverlay.zebraPath(picture: picture)), with: .color(.black),
                     lineWidth: CameraOverlay.zebraLineWidth(picture: picture))
    }.clipShape(RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6)))
  }
}

struct PresenterExposureKey: View {
  let guides: CameraGuides
  @Binding var expanded: Bool
  var zoom = 1.0

  var body: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Button { expanded.toggle() } label: {
        HStack {
          Text(expanded ? "Hide key" : "Exposure key")
          if expanded { Spacer(minLength: Space.xs) }
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
        }.frame(minHeight: AlphaStyle.minTarget)
      }.buttonStyle(.plain).accessibilityLabel(expanded ? "Hide key" : "Show key")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      if expanded {
        if guides.zebras {
          HStack(spacing: Space.sm) {
            PresenterZebraSwatch().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: Space.xs) {
              Text("Zebras").fontWeight(.semibold)
              Text(guides.exposure.zebraRangeLabel + " IRE").font(.system(size: 14))
            }
          }
        }
        if guides.falseColour {
          ForEach(Array(guides.exposure.legendBands.enumerated()), id: \.offset) { _, band in
            HStack(spacing: Space.sm) {
              RoundedRectangle(cornerRadius: Space.xs)
                .fill(Color(red: Double(band.colour & 255)/255, green: Double((band.colour >> 8) & 255)/255, blue: Double((band.colour >> 16) & 255)/255))
                .frame(width: 24, height: 24)
              VStack(alignment: .leading, spacing: 0) {
                Text(band.label).fontWeight(.semibold)
                Text(band.range + " IRE").font(.system(size: 14)).foregroundStyle(.secondary)
              }
            }
          }
        }
        Text("Measured from the incoming picture.").font(.system(size: 13)).foregroundStyle(.secondary)
      }
    }.font(.system(size: 16)).padding(Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Surfaces.presenterPanel, in: RoundedRectangle(cornerRadius: AlphaStyle.cardCorner))
      .environment(\.colorScheme, .dark).uiZoom(zoom)
  }
}

/// The same live-selection tick in the Mac menu and the iPad picker.
struct DeviceChoiceLabel: View {
  let name: String
  let selected: Bool
  var body: some View {
    Group {
      if selected { Label(name, systemImage: "checkmark") }
      else { Text(name) }
    }.accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// One rotation menu for the local presenter, remote console and iPad camera picker.
struct CameraRotationMenu: View {
  let angle: Int
  let choose: (Int) -> Void
  var body: some View {
    Menu {
      ForEach(CameraRotation.allCases) { rotation in
        Button { choose(rotation.rawValue) } label: {
          DeviceChoiceLabel(name: rotation.label, selected: angle == rotation.rawValue)
        }
      }
    } label: { Label("Rotate", systemImage: "rotate.right") }
      .accessibilityValue("\(angle) degrees")
  }
}

/// The same setup rows on Mac, iPad and the linked-iPad console.
struct PresenterSetupBar<Transport: View, Devices: View, Tools: View, Options: View>: View {
  var scale = 1.0
  @ViewBuilder var transport: () -> Transport
  @ViewBuilder var devices: () -> Devices
  @ViewBuilder var tools: () -> Tools
  @ViewBuilder var options: () -> Options
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Space.md) {
        transport(); Spacer(minLength: Space.md); devices(); tools(); options()
      }.fixedSize(horizontal: true, vertical: false)
      rows
    }.frame(maxWidth: .infinity, alignment: .leading)
      .environment(\.barControlHeight, scale >= 1.5 ? 36 : PresenterBar.height) // grid: ok UI scale threshold; targets remain at least 54 pt on screen.
      .padding(.vertical, scale >= 1.5 ? Space.xs : Space.sm) // grid: ok UI scale threshold, not a spacing dimension.
  }
  private var rowGap: CGFloat { scale >= 1.5 ? Space.xs : Space.sm }
  private var rows: some View {
    VStack(spacing: rowGap) {
      WrapLayout(spacing: rowGap, distributeAfter: 1, leading: true) {
        HStack(spacing: Space.sm) { transport() }
        devices()
      }
      WrapLayout(spacing: rowGap, distributeAfter: 1, leading: true) {
        tools()
        options()
      }
    }.fixedSize(horizontal: false, vertical: true)
  }
}

struct PresenterTurnControls: View {
  @Binding var mirror: Bool
  @Binding var flip: Bool
  var body: some View {
    BarGroup(label: "Mirror and flip", raised: false) {
      BarToggle(title: "Mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: mirror) { mirror.toggle() }
      BarToggle(title: "Flip", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", isOn: flip) { flip.toggle() }
    }
  }
}

struct PresenterLevel: View {
  let level: Double
  var body: some View {
    DBMeter(levelDB: level, axis: .horizontal, showsScale: false)
      .frame(width: 48, height: 24).padding(.horizontal, Space.xs)
      .accessibilityLabel("Microphone level")
  }
}

struct PresenterLinkedLevel: View {
  @ObservedObject var meter: RemoteMicMeter
  var body: some View { PresenterLevel(level: meter.levelDB) }
}

#if canImport(AppKit)
struct PresenterInputLevel: View {
  @ObservedObject var meter: InputMeter
  var body: some View { PresenterLevel(level: Double(meter.peakDBFS)) }
}
#endif

/// An HStack that wraps onto further centred rows when its content is wider than it is offered.
struct WrapLayout: Layout {
  var spacing: CGFloat = 8
  var distributeAfter: Int? = nil
  var leading = false
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(for: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: distributeAfter != nil && rows.count == 1 ? proposal.width ?? width : width, height: height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    let rows = rows(for: bounds.width, subviews: subviews)
    for row in rows {
      let distribute = rows.count == 1 && distributeAfter != nil
      var x = (distribute || leading) ? bounds.minX : bounds.midX - row.width / 2
      for index in row.indices {
        if distribute, index == distributeAfter { x += max(0, bounds.width - row.width) }
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }
  private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
  private func rows(for maxWidth: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = [Row()]
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      if rows[rows.count - 1].width + extra > maxWidth, !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
      let extraNow = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      rows[rows.count - 1].indices.append(index)
      rows[rows.count - 1].width += extraNow
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
    }
    return rows
  }
}
