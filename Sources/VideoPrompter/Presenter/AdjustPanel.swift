import SwiftUI

enum AdjustTab: String, CaseIterable {
  case camera = "Camera", zebras = "Zebras", falseColour = "False colour", guides = "Guides", mic = "Mic"
}

struct AdjustPanel: View {
  @Binding var selection: AdjustTab
  @Binding var showsMic: Bool
  @State private var microphones: [AudioInputDevice] = []
  @ObservedObject var camera: CameraModel
  @ObservedObject var store: AppStore
  let startsMeter: Bool
  var zoom = 1.0
  var width: CGFloat = 470 // grid: ok Approved panel content width.
  var close: () -> Void = {}
  var devicesOverride: [CameraDevice]? = nil
  let recorder: CameraRecorder

  var body: some View {
    VStack(spacing: 0) {
        WrapLayout(spacing: 4, leading: true) {
          ForEach(AdjustTab.allCases, id: \.self) { tab in
            Button { selection = tab } label: {
              Text(tab.rawValue).font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, Space.md).frame(minHeight: AlphaStyle.minTarget)
                .foregroundStyle(selection == tab ? AlphaStyle.onAccent : .white)
                .background(selection == tab ? AlphaStyle.accent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityAddTraits(selection == tab ? .isSelected : [])
          }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .contain).accessibilityLabel("Adjust sections")
        .padding(.horizontal, AlphaStyle.panelInset).padding(.top, Space.md)
      HStack {
        Text("Changes appear on your camera picture.").foregroundStyle(.secondary)
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
    }.uiZoom(zoom).frame(width: width).frame(maxHeight: .infinity, alignment: .top) // grid: ok The approved panel width is 470 points.
      .background(Color(nsColor: NSColor(white: 0.07, alpha: 1)))
      .environment(\.colorScheme, .dark).tint(AlphaStyle.accent).accentColor(AlphaStyle.accent)
  }
  @AppStorage("presenterExposureKeyExpanded") private var keyExpanded = true
  private var keyToggle: some View {
    Toggle("Show key", isOn: $keyExpanded).toggleStyle(.switch).frame(minHeight: AlphaStyle.minTarget)
  }
  private var mic: some View {
    VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
      Text("Microphone").font(.title2.bold())
      Toggle("Show mic meter", isOn: $showsMic).toggleStyle(.switch).accessibilityIdentifier("show-mic-meter").accessibilityLabel("Show mic meter").frame(minHeight: AlphaStyle.minTarget)
      microphoneChoice("System default", uid: nil)
      ForEach(microphones) { device in microphoneChoice(device.name, uid: device.uid) }
      if let uid = store.settings.audioDeviceUID, !microphones.contains(where: { $0.uid == uid }) {
        microphoneChoice("Selected microphone unavailable", uid: uid)
      }
      MicMeterView(meter: recorder.inputMeter, micName: recorder.microphoneName, showsHeading: false).frame(height: 180)
      SettingsLink { Text("More in Settings") }.frame(minHeight: AlphaStyle.minTarget)
      Text("Speak to check your microphone level.").foregroundStyle(.secondary)
    }.onAppear { microphones = AudioCapture.inputDevices() }
  }

  private func microphoneChoice(_ name: String, uid: String?) -> some View {
    Button {
      guard store.settings.audioDeviceUID != uid else { return }
      store.session.stopMicrophoneTest()
      recorder.stopInputTest()
      store.settings.audioDeviceUID = uid
    } label: {
      HStack {
        Text(name).multilineTextAlignment(.leading)
        Spacer()
        if store.settings.audioDeviceUID == uid { Image(systemName: "checkmark").foregroundStyle(AlphaStyle.accent) }
      }.frame(maxWidth: .infinity, minHeight: AlphaStyle.minTarget)
    }.buttonStyle(.plain).accessibilityAddTraits(store.settings.audioDeviceUID == uid ? .isSelected : [])
  }

}
