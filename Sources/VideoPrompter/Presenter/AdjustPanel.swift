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
  var sourceInfoOverride: [String: CameraSourceInfo]? = nil
  var microphonesOverride: [AudioInputDevice]? = nil
  let recorder: CameraRecorder

  var body: some View {
    VStack(spacing: 0) {
      // Close sits at the top right of the panel, on the row of the panel's own name.
      HStack {
        Text("Adjust").font(.system(size: 17, weight: .semibold))
        Spacer(minLength: Space.sm)
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: AlphaStyle.minTarget, height: AlphaStyle.minTarget)
            .background(Color.white.opacity(0.10), in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel("Close Adjust").initialPopoverFocus()
      }.padding(.horizontal, AlphaStyle.panelInset).padding(.top, Space.md)
      HStack(spacing: Space.xs) {
        ForEach(AdjustTab.sources, id: \.self) { tabButton($0) }
        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 28).padding(.horizontal, Space.xs).accessibilityHidden(true)
        ForEach(AdjustTab.pictureTools, id: \.self) { tabButton($0) }
      }.accessibilityElement(children: .contain).accessibilityLabel("Adjust sections")
        .padding(.horizontal, AlphaStyle.panelInset).padding(.top, Space.xs)
      Text(selection == .mic ? "Choose the input you speak into." : "Changes appear on your camera picture.").cardCaption()
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, AlphaStyle.panelInset).padding(.top, Space.md)
      ScrollView {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
            switch selection {
            case .camera: CameraAdjustView(model: camera, devicesOverride: devicesOverride ?? (startsMeter ? nil : []), sourceInfoOverride: sourceInfoOverride)
            case .zebras: keyToggle; ZebraAdjustView(model: camera)
            case .falseColour: keyToggle; FalseColourAdjustView(model: camera)
            case .guides: AlphaGuideSections(model: camera)
            case .mic: mic
            }
          }.padding(AlphaStyle.panelInset)
          // The footer follows the content, so a short tab does not leave it floating at the bottom.
          if selection == .mic || selection == .camera { footer }
        }
      }
    }.frame(maxWidth: 560).frame(maxWidth: .infinity) // grid: ok A wide sheet keeps the panel's proportions.
      .uiZoom(zoom).frame(width: width).frame(maxHeight: .infinity, alignment: .top) // grid: ok The approved panel width is 470 points.
      .background(Color(nsColor: NSColor(white: 0.07, alpha: 1)))
      .environment(\.colorScheme, .dark).tint(AlphaStyle.accent).accentColor(AlphaStyle.accent)
  }
  private func tabButton(_ tab: AdjustTab) -> some View {
    Button { selection = tab } label: {
      VStack(spacing: Space.xs) {
        Image(systemName: tab.symbol).font(.system(size: 16, weight: .semibold)).frame(height: Space.xl)
        // The full name when it fits on one line, else the short one; VoiceOver always hears the full name.
        ViewThatFits(in: .horizontal) {
          tabTitle(tab.rawValue).fixedSize(horizontal: true, vertical: false)
          tabTitle(tab == .falseColour ? "Colour" : tab.rawValue).minimumScaleFactor(0.7)
        }.padding(.horizontal, Space.xs)
      }.frame(maxWidth: .infinity, minHeight: 52)
        // Navigation stays quieter than the content: the open tab is yellow, the others are plain.
        .foregroundStyle(selection == tab ? AlphaStyle.onAccent : .white.opacity(0.8))
        .background(selection == tab ? AlphaStyle.accent : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain).accessibilityLabel(tab.rawValue).accessibilityAddTraits(selection == tab ? .isSelected : [])
  }
  private func tabTitle(_ title: String) -> some View { Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1) }
  @AppStorage("presenterExposureKeyExpanded") private var keyExpanded = true
  private var keyToggle: some View {
    Toggle("Show key", isOn: $keyExpanded).toggleStyle(AccentSwitchStyle()).frame(minHeight: AlphaStyle.minTarget)
  }
  private var mic: some View {
    VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
      HStack {
        Text("Microphone").font(.title2.bold())
        Spacer(minLength: Space.sm)
        Toggle(isOn: $showsMic) { Text("Show meter").cardCaption() }
          .toggleStyle(AccentSwitchStyle())
          .fixedSize().accessibilityIdentifier("show-mic-meter").accessibilityLabel("Show mic meter")
      }.frame(minHeight: AlphaStyle.minTarget)
      Text("Inputs").font(.system(size: 17, weight: .semibold))
      MicrophoneCards(store: store, devices: microphonesOverride ?? microphones, willChange: {
        store.session.stopMicrophoneTest()
        recorder.stopInputTest()
      }, meter: recorder.inputMeter)
    }.onAppear { microphones = AudioCapture.inputDevices() }
  }
  private var footer: some View {
    HStack {
      Text(selection == .mic ? "Speak to check your level." : "Remembered for each camera.").cardCaption()
      Spacer(minLength: Space.sm)
      SettingsLink { HStack(spacing: Space.xs) { Text("More in Settings"); Image(systemName: "chevron.right") } }
        .buttonStyle(.plain).frame(minHeight: AlphaStyle.minTarget)
    }.padding(.horizontal, AlphaStyle.panelInset).overlay(alignment: .top) { Divider() }
  }
}

/// A switch that is yellow whenever it is on, even in a window that is not frontmost (the system switch goes
/// grey there). VoiceOver still hears an ordinary switch.
struct AccentSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: Space.sm) {
        configuration.label
        Spacer(minLength: Space.sm)
        Capsule().fill(configuration.isOn ? AlphaStyle.accent : Color.white.opacity(0.25)).frame(width: 44, height: 26) // grid: ok switch drawing
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle().fill(configuration.isOn ? AlphaStyle.onAccent : Color.white).padding(3).frame(width: 26, height: 26) // grid: ok switch drawing
          }
      }.frame(minHeight: AlphaStyle.minTarget).contentShape(Rectangle())
    }.buttonStyle(.plain).animation(.easeInOut(duration: 0.15), value: configuration.isOn)
      .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
  }
}
