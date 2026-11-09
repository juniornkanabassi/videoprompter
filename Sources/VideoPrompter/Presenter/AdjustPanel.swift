import SwiftUI

enum AdjustTab: String, CaseIterable {
  case camera = "Camera", zebras = "Zebras", falseColour = "False colour", guides = "Guides", mic = "Mic"
}

struct AdjustPanel: View {
  @Binding var selection: AdjustTab
  @Binding var showsMic: Bool
  @ObservedObject var camera: CameraModel
  @ObservedObject var store: AppStore
  let startsMeter: Bool
  var zoom = 1.0
  var devicesOverride: [CameraDevice]? = nil
  let recorder: CameraRecorder

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Group {
        WrapLayout(spacing: 4) {
          ForEach(AdjustTab.allCases, id: \.self) { tab in
            Button { selection = tab } label: {
              Text(tab.rawValue).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, Space.sm).frame(minHeight: 44)
                .foregroundStyle(selection == tab ? .black : .white)
                .background(selection == tab ? Color.white : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityValue(selection == tab ? "Selected" : "")
          }
        }
      }
      ScrollView {
        switch selection {
        case .camera: CameraAdjustView(model: camera, devicesOverride: devicesOverride ?? (startsMeter ? nil : []))
        case .zebras: ZebraAdjustView(guides: $camera.guides)
        case .falseColour: FalseColourAdjustView(guides: $camera.guides)
        case .guides: guides
        case .mic:
          VStack(alignment: .leading) {
            Toggle("Show mic meter", isOn: $showsMic)
            MicrophonePage(store: store, compact: true, startsMeter: startsMeter, recorder: recorder)
          }
        }
      }
    }.padding(24).uiZoom(zoom).frame(width: 470).frame(maxHeight: .infinity, alignment: .top) // grid: ok The approved panel width is 470 points.
      .background(Color(nsColor: NSColor(white: 0.07, alpha: 1)))
      .environment(\.colorScheme, .dark).tint(.yellow).accentColor(.yellow)
  }
  private var guides: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("Guides").font(.title2.bold())
      Toggle("Vertical 9:16", isOn: Binding(get: { camera.guides.marker == CameraAspect(width: 9, height: 16) }, set: { camera.guides.marker = $0 ? CameraAspect(width: 9, height: 16) : nil })).frame(minHeight: 44)
      Toggle("Thirds", isOn: $camera.guides.thirds).frame(minHeight: 44)
      Toggle("Centre mark", isOn: Binding(get: { camera.guides.axes || camera.guides.bullseye }, set: { camera.guides.axes = $0; camera.guides.bullseye = false })).frame(minHeight: 44)
      DisclosureGroup("Advanced") {
        CameraGuideSettings(model: camera).frame(height: 600)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

}
