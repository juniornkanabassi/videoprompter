import SwiftUI
import PrompterCore

/// The same controls and value vocabulary on both presenters and the Mac remote.
struct PresenterTextPanel: View {
  @Binding var mode: String
  @Binding var countdown: Int
  @Binding var fontName: String
  @Binding var fontSize: Double
  @Binding var textWidth: Double
  @Binding var lineSpacing: Double
  @Binding var paragraphSpacing: Double
  @Binding var guideFraction: Double
  @Binding var bandOpacity: Double
  let fonts: [String]
  var readingExtras = AnyView(EmptyView())

  #if os(iOS)
  private let target: CGFloat = 44
  #else
  private let target: CGFloat = 24
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: Space.lg) {
      section("READING") {
        HStack(spacing: Space.xs) {
          modeButton("Voice follow", symbol: "mic.fill", value: "Voice")
          modeButton("Automatic", symbol: "play.fill", value: "Manual")
        }
        .padding(Space.xs).background(.quaternary, in: RoundedRectangle(cornerRadius: Space.sm))
        .accessibilityElement(children: .contain).accessibilityLabel("Reading mode")
        HStack(spacing: Space.sm) {
          Label("Countdown", systemImage: "timer")
          Picker("Countdown", selection: $countdown) {
            ForEach(Array(Set([0, 3, 5, countdown])).sorted(), id: \.self) { delay in
              Text(delay == 0 ? "Off" : "\(delay) s").tag(delay)
            }
          }.labelsHidden().pickerStyle(.segmented).frame(minHeight: target)
        }
        readingExtras
      }
      Divider()
      section("FONT") {
        HStack {
          symbol("textformat", title: "Font")
          Picker("Font", selection: $fontName) {
            ForEach(Array(Set(fonts + [fontName])).sorted(), id: \.self) { Text($0).tag($0) }
          }.frame(minHeight: target)
        }
        HStack(spacing: Space.sm) {
          symbol("textformat", title: "Text size")
          slider("Text size", value: $fontSize, range: InputValidation.fontSize.range, spoken: "\(Int(fontSize)) points")
          Text("\(Int(fontSize))").monospacedDigit().accessibilityHidden(true)
          sizeButton("A−", title: "Smaller text", delta: -4)
          sizeButton("A+", title: "Larger text", delta: 4)
        }
        preview
      }
      Divider()
      section("LAYOUT") {
        row("Margins", symbol: "arrow.left.and.right", value: $textWidth, range: InputValidation.textWidth.range,
            readout: Self.marginLabel(textWidth))
        row("Line spacing", symbol: "line.3.horizontal", value: $lineSpacing, range: InputValidation.lineSpacing.range,
            readout: Self.spacingLabel(lineSpacing, range: InputValidation.lineSpacing.range))
        row("Paragraph spacing", symbol: "paragraphsign", value: $paragraphSpacing, range: InputValidation.paragraphSpacing.range,
            readout: Self.spacingLabel(paragraphSpacing, range: InputValidation.paragraphSpacing.range))
      }
      Divider()
      section("READING LINE") {
        row("Reading line", symbol: "arrow.up.and.down", value: $guideFraction, range: InputValidation.guideFraction.range,
            readout: Self.percent(guideFraction))
        row("Reading band strength", symbol: "rectangle.fill", value: $bandOpacity, range: 0...1,
            readout: Self.percent(bandOpacity), yellow: true)
      }
    }
    .tint(AlphaStyle.accent)
  }

  static func marginLabel(_ width: Double) -> String {
    width < 0.55 ? "Wide" : width < 0.8 ? "Medium" : "Narrow"
  }
  static func spacingLabel(_ value: Double, range: ClosedRange<Double>) -> String {
    let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    return fraction < 0.34 ? "Tight" : fraction < 0.67 ? "Medium" : "Loose"
  }
  static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
      content()
    }
  }
  private func symbol(_ name: String, title: String) -> some View {
    Image(systemName: name).frame(width: Space.xxl).accessibilityHidden(true).help(title)
  }
  private func row(_ title: String, symbol name: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String, yellow: Bool = false) -> some View {
    let exact = value.wrappedValue.formatted(.number.precision(.fractionLength(0...2)))
    return HStack(spacing: Space.sm) {
      symbol(name, title: title).foregroundStyle(yellow ? AlphaStyle.accent : .primary)
      slider(title, value: value, range: range, spoken: "\(readout), \(exact)\(yellow && value.wrappedValue == 0 ? ", off" : "")")
      Text(readout).font(.callout).monospacedDigit().frame(width: 64, alignment: .trailing)
        .accessibilityHidden(true)
    }.help("\(title): \(exact)\(yellow ? "; 0 = off" : "")")
  }
  @ViewBuilder private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, spoken: String) -> some View {
    #if os(macOS)
    ReadingSlider(value: value, range: range, title: title, spokenValue: spoken)
    #else
    Slider(value: value, in: range).accessibilityLabel(title).accessibilityValue(spoken).frame(minHeight: target)
    #endif
  }
  private func modeButton(_ title: String, symbol: String, value: String) -> some View {
    Button { mode = value } label: {
      Label(title, systemImage: symbol).font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: target)
        .foregroundStyle(mode == value ? AlphaStyle.onAccent : .primary)
        .background(mode == value ? AlphaStyle.accent : .clear, in: RoundedRectangle(cornerRadius: Space.xs))
    }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? .isSelected : [])
  }
  private func sizeButton(_ text: String, title: String, delta: Double) -> some View {
    Button { fontSize = InputValidation.fontSize.repair(fontSize + delta) } label: {
      Text(text).frame(minWidth: target, minHeight: target)
    }.accessibilityLabel(title)
      .disabled(delta < 0 ? fontSize <= InputValidation.fontSize.range.lowerBound : fontSize >= InputValidation.fontSize.range.upperBound)
  }
  private var preview: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text("4 players who started in")
      HStack(spacing: Space.xs) {
        Text("back-to-back").foregroundStyle(AlphaStyle.accent)
          .padding(.horizontal, Space.xs)
          .background(AlphaStyle.accent.opacity(bandOpacity), in: RoundedRectangle(cornerRadius: Space.xs))
        Text("finals.")
      }
    }
      .font(previewFont).padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
      .background(.black, in: RoundedRectangle(cornerRadius: Space.sm))
      .foregroundStyle(.white).accessibilityLabel("Font preview, \(fontName), \(Int(fontSize)) points")
  }
  private var previewFont: Font {
    let size = min(32, max(14, fontSize * 0.4))
    #if os(macOS)
    return Font(FormattedMarkdownEditModel.font(name: fontName, size: size))
    #else
    var style = ScriptStyle()
    style.fontName = fontName
    style.fontSize = size
    return Font(ScriptRenderer.font(style))
    #endif
  }
}
