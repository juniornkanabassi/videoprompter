import SwiftUI

/// Shared look of the presenter bar: one control height, one corner, one selected state.
enum PresenterBar {
  static let height = AlphaStyle.minTarget
  static let corner: CGFloat = 12 // grid: ok Matches the Alpha tile corner.
  /// Between the transport, the video-call group and the picture tools.
  static let groupGap = Space.lg
  static let background = Color(white: 0.08)
  /// Fingers need 44 pt each way; the pointer's icon-only button is a little narrower.
  #if os(iOS)
  static let iconWidth = AlphaStyle.minTarget
  static let caretWidth = AlphaStyle.minTarget
  #else
  static let iconWidth: CGFloat = 0
  static let caretWidth: CGFloat = 28
  #endif
  static let warning = Color(red: 1, green: 0.45, blue: 0.42)
}

/// Icon, and the word beside it when there is room. The word stays as the accessibility label.
struct BarLabel: View {
  let title: String
  let symbol: String
  var showsTitle = true
  var weight = Font.Weight.semibold
  var body: some View {
    HStack(spacing: Space.xs) {
      Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 24)
      if showsTitle { Text(title).font(.system(size: 15, weight: weight)).lineLimit(1).fixedSize() }
    }.padding(.horizontal, showsTitle ? Space.md : Space.sm)
      .frame(minWidth: showsTitle ? 0 : PresenterBar.iconWidth, minHeight: PresenterBar.height)
  }
}

/// One style for every bar button, so Start reading, the call group and the picture tools line up.
struct BarButtonStyle: ButtonStyle {
  enum Role { case plain, secondary, on, off, prominent }
  var role = Role.plain
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: PresenterBar.corner)
    configuration.label
      .foregroundStyle(foreground)
      .frame(minHeight: PresenterBar.height)
      .background(shape.fill(fill))
      .overlay { if role == .on { shape.stroke(AlphaStyle.accent.opacity(0.75), lineWidth: 1.5) } }
      .overlay { if configuration.isPressed { shape.fill(.white.opacity(0.12)) } }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(shape)
  }
  private var foreground: Color {
    switch role {
    case .prominent: AlphaStyle.onAccent
    case .on: AlphaStyle.accent
    case .off: PresenterBar.warning
    default: .white
    }
  }
  private var fill: Color {
    switch role {
    case .prominent: AlphaStyle.accent
    case .on: AlphaStyle.selectedFill
    case .off: Color.red.opacity(0.18)
    case .secondary: .white.opacity(0.08)
    case .plain: .clear
    }
  }
}

/// A named run of controls on one soft backing: the video-call group, the picture tools.
struct BarGroup<Content: View>: View {
  let label: String
  @ViewBuilder var content: () -> Content
  var body: some View {
    HStack(spacing: 0, content: content)
      .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: PresenterBar.corner))
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
  let title: String
  let onSymbol: String
  let offSymbol: String
  let isOn: Bool
  var showsTitle = true
  var isEnabled = true
  let toggleHelp: String
  let menuLabel: String
  let menuValue: String
  let toggle: () -> Void
  @ViewBuilder var menu: () -> MenuContent

  var body: some View {
    HStack(spacing: 0) {
      Button(action: toggle) { BarLabel(title: title, symbol: isOn ? onSymbol : offSymbol, showsTitle: showsTitle) }
        .buttonStyle(BarButtonStyle(role: isOn ? .plain : .off))
        .help(toggleHelp)
        .accessibilityLabel(title).accessibilityValue(isOn ? "On" : "Off").accessibilityAddTraits(.isToggle)
        .disabled(!isEnabled)
      Menu(content: menu) {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
          .frame(width: PresenterBar.caretWidth, height: PresenterBar.height).contentShape(Rectangle())
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .foregroundStyle(isOn ? Color.white.opacity(0.8) : PresenterBar.warning)
      .help(menuLabel)
      .accessibilityLabel(menuLabel).accessibilityValue(menuValue)
    }
    .background(isOn ? Color.clear : Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: PresenterBar.corner))
  }
}

/// A picture tool or toggle on the bar.
struct BarToggle: View {
  let title: String
  let symbol: String
  let isOn: Bool
  var showsTitle = true
  var help: String? = nil
  var traits: AccessibilityTraits = .isToggle
  var value: String? = nil
  let action: () -> Void
  var body: some View {
    Button(action: action) { BarLabel(title: title, symbol: symbol, showsTitle: showsTitle) }
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

/// A soft dark panel behind a narrower text column, so the picture and the zebras stop fighting the words.
struct ReadingBacking: View {
  let opacity: Double
  var body: some View {
    RoundedRectangle(cornerRadius: AlphaStyle.cardCorner + Space.sm)
      .fill(Color.black.opacity(opacity))
      .overlay(RoundedRectangle(cornerRadius: AlphaStyle.cardCorner + Space.sm).stroke(.white.opacity(0.06)))
      .shadow(color: .black.opacity(0.35), radius: Space.xl)
      .allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// A small status capsule: a dot for the state, then the words.
struct BarStatusPill: View {
  let text: String
  let isActive: Bool
  var body: some View {
    HStack(spacing: Space.sm) {
      Circle().fill(isActive ? Color.green : .white.opacity(0.4)).frame(width: 8, height: 8)
      Text(text).font(.system(size: 14, weight: .medium)).lineLimit(1)
    }.padding(.horizontal, Space.md).frame(minHeight: 32) // grid: ok A calm status capsule, shorter than a control.
      .background(.white.opacity(0.07), in: Capsule())
      .foregroundStyle(.white.opacity(0.85))
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
      Text("Editing").font(.system(size: 17, weight: .semibold))
      Text("not saved yet").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
      Spacer(minLength: Space.md)
      Button(action: cancel) {
        HStack(spacing: Space.xs) {
          Text("Cancel").font(.system(size: 15, weight: .semibold))
          if !compact { Text("esc").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
        }.padding(.horizontal, Space.md).frame(minHeight: PresenterBar.height)
      }.buttonStyle(BarButtonStyle(role: .secondary)).accessibilityLabel("Cancel editing").disabled(isSaving)
        .help("Discard this draft (Esc)")
      Button(action: save) {
        HStack(spacing: Space.xs) {
          Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
          Text("Save").font(.system(size: 15, weight: .bold))
          if !compact { Text("⌘↩").font(.system(size: 12, weight: .medium)).foregroundStyle(AlphaStyle.onAccent.opacity(0.65)) }
        }.padding(.horizontal, Space.md).frame(minHeight: PresenterBar.height)
      }.buttonStyle(BarButtonStyle(role: .prominent)).accessibilityLabel("Save changes").disabled(isSaving)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Save changes to the script (⌘↩)")
    }
    .foregroundStyle(.white)
    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
    .frame(maxWidth: .infinity)
    .background(Color(white: 0.07).overlay(AlphaStyle.accent.opacity(0.12)))
    .overlay(alignment: .bottom) { Rectangle().fill(AlphaStyle.accent.opacity(0.4)).frame(height: 1) }
    .accessibilityElement(children: .contain).accessibilityIdentifier("presenter-editing-band")
  }
}
