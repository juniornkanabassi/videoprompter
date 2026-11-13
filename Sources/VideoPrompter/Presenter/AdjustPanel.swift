import SwiftUI

enum AdjustTab: String, CaseIterable {
  case camera = "Camera", mic = "Mic", zebras = "Zebras", falseColour = "False colour", guides = "Guides"
  /// Camera and Mic set up the sources; the rest are picture tools. The row shows them as two groups.
  static let sources: [AdjustTab] = [.camera, .mic]
  static let pictureTools: [AdjustTab] = [.zebras, .falseColour, .guides]
  var symbol: String {
    switch self {
    case .camera: "video"
    case .mic: "mic"
    case .zebras: "rectangle.pattern.checkered"
    case .falseColour: "circle.lefthalf.filled"
    case .guides: "squareshape.split.3x3"
    }
  }
}

struct AdjustPanel: View {
  @Binding var selection: AdjustTab
  @Binding var showsMic: Bool
  @State private var microphones: [AudioInputDevice] = []
  @State private var defaultMicrophoneName: String?
  @ObservedObject var camera: CameraModel
  @ObservedObject var store: AppStore
  let startsMeter: Bool
  var zoom = 1.0
  var width: CGFloat = 470 // grid: ok Approved panel content width.
  var close: () -> Void = {}
  var devicesOverride: [CameraDevice]? = nil
  var microphonesOverride: [AudioInputDevice]? = nil
  let recorder: CameraRecorder

  var body: some View {
    VStack(spacing: 0) {
        HStack(spacing: Space.xs) {
          ForEach(AdjustTab.sources, id: \.self) { tabButton($0) }
          Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 36).padding(.horizontal, Space.xs).accessibilityHidden(true)
          ForEach(AdjustTab.pictureTools, id: \.self) { tabButton($0) }
        }.accessibilityElement(children: .contain).accessibilityLabel("Adjust sections")
        .padding(.horizontal, AlphaStyle.panelInset).padding(.top, Space.md)
      HStack {
        Text(selection == .mic ? "Choose the input you speak into." : "Changes appear on your camera picture.").foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button(action: close) {
          Image(systemName: "xmark").frame(width: AlphaStyle.minTarget, height: AlphaStyle.minTarget)
        }.buttonStyle(.plain).accessibilityLabel("Close Adjust").initialPopoverFocus()
      }.padding(.horizontal, AlphaStyle.panelInset)
      ScrollView {
      VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
      Group {
        switch selection {
        case .camera: CameraAdjustView(model: camera, devicesOverride: devicesOverride ?? (startsMeter ? nil : []))
        case .zebras: keyToggle; ZebraAdjustView(model: camera)
        case .falseColour: keyToggle; FalseColourAdjustView(model: camera)
        case .guides: AlphaGuideSections(model: camera)
        case .mic: mic
        }
      }
    }.padding(AlphaStyle.panelInset)
    }
      if selection == .mic { micFooter }
    }.frame(maxWidth: 560).frame(maxWidth: .infinity) // grid: ok A wide sheet keeps the panel's proportions.
      .uiZoom(zoom).frame(width: width).frame(maxHeight: .infinity, alignment: .top) // grid: ok The approved panel width is 470 points.
      .background(Color(nsColor: NSColor(white: 0.07, alpha: 1)))
      .environment(\.colorScheme, .dark).tint(AlphaStyle.accent).accentColor(AlphaStyle.accent)
  }
  private func tabButton(_ tab: AdjustTab) -> some View {
    Button { selection = tab } label: {
      VStack(spacing: Space.xs) {
        Image(systemName: tab.symbol).font(.system(size: 18, weight: .semibold)).frame(height: Space.xxl)
        // The full name when it fits on one line, else the short one; VoiceOver always hears the full name.
        ViewThatFits(in: .horizontal) {
          tabTitle(tab.rawValue).fixedSize(horizontal: true, vertical: false)
          tabTitle(tab == .falseColour ? "Colour" : tab.rawValue).minimumScaleFactor(0.7)
        }.padding(.horizontal, Space.xs)
      }.frame(maxWidth: .infinity, minHeight: 60)
        .foregroundStyle(selection == tab ? AlphaStyle.onAccent : .white)
        .background(selection == tab ? AlphaStyle.accent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain).accessibilityLabel(tab.rawValue).accessibilityAddTraits(selection == tab ? .isSelected : [])
  }
  private func tabTitle(_ title: String) -> some View { Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1) }
  @AppStorage("presenterExposureKeyExpanded") private var keyExpanded = true
  private var keyToggle: some View {
    Toggle("Show key", isOn: $keyExpanded).toggleStyle(.switch).frame(minHeight: AlphaStyle.minTarget)
  }
  private var mic: some View {
    VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
      HStack {
        Text("Microphone").font(.title2.bold())
        Spacer(minLength: Space.sm)
        Toggle(isOn: $showsMic) { Text("Show meter").font(.callout).foregroundStyle(.secondary) }
          .toggleStyle(.switch).fixedSize().accessibilityIdentifier("show-mic-meter").accessibilityLabel("Show mic meter")
      }.frame(minHeight: AlphaStyle.minTarget)
      MicrophoneCards(store: store, devices: microphonesOverride ?? microphones, willChange: {
        store.session.stopMicrophoneTest()
        recorder.stopInputTest()
      }, meter: recorder.inputMeter)
    }.onAppear { microphones = AudioCapture.inputDevices() }
  }
  private var micFooter: some View {
    HStack {
      Text("Speak to check your level.").foregroundStyle(.secondary)
      Spacer(minLength: Space.sm)
      SettingsLink { HStack(spacing: Space.xs) { Text("More in Settings"); Image(systemName: "chevron.right") } }
        .buttonStyle(.plain).frame(minHeight: AlphaStyle.minTarget)
    }.padding(.horizontal, AlphaStyle.panelInset).overlay(alignment: .top) { Divider() }
  }
}
