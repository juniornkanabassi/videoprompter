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
      Button(action: close) {
        Label("Close Adjust", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: AlphaStyle.minTarget)
      }.buttonStyle(.plain).initialPopoverFocus().padding(.horizontal, AlphaStyle.panelInset)
      ScrollView {
    VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
      Text("Adjust").font(.title2.bold()).accessibilityAddTraits(.isHeader)
      Text("Changes appear on your camera picture.").foregroundStyle(.secondary)
      Group {
        WrapLayout(spacing: 4) {
          ForEach(AdjustTab.allCases, id: \.self) { tab in
            Button { selection = tab } label: {
              Text(tab.rawValue).font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, Space.sm).frame(minHeight: 44)
                .foregroundStyle(selection == tab ? AlphaStyle.onAccent : .white)
                .background(selection == tab ? AlphaStyle.accent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityAddTraits(selection == tab ? .isSelected : [])
          }
        }.accessibilityElement(children: .contain).accessibilityLabel("Adjust sections")
      }
      Group {
        switch selection {
        case .camera: CameraAdjustView(model: camera, devicesOverride: devicesOverride ?? (startsMeter ? nil : []))
        case .zebras: ZebraAdjustView(guides: $camera.guides)
        case .falseColour: FalseColourAdjustView(guides: $camera.guides)
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
  private var mic: some View {
    VStack(alignment: .leading, spacing: AlphaStyle.sectionGap) {
      Text("Mic").font(.title2.bold())
      Picker("Input", selection: Binding(get: { store.settings.audioDeviceUID ?? "" }, set: { store.session.stopMicrophoneTest(); store.settings.audioDeviceUID = $0.isEmpty ? nil : $0 })) {
        Text("System default").tag("")
        if let uid = store.settings.audioDeviceUID, !microphones.contains(where: { $0.uid == uid }) { Text("Selected microphone unavailable").tag(uid) }
        ForEach(microphones) { Text($0.name).tag($0.uid) }
      }.frame(minHeight: AlphaStyle.minTarget)
      Toggle("Show meter", isOn: $showsMic).toggleStyle(.switch).frame(minHeight: AlphaStyle.minTarget)
      Text("Speak to check your microphone level.").foregroundStyle(.secondary)
    }.onAppear { microphones = AudioCapture.inputDevices() }
  }

}
