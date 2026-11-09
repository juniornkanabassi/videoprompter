import SwiftUI

struct AlphaGuideSections: View {
  @ObservedObject var model: CameraModel
  private let vertical = CameraAspect(width: 9, height: 16)
  var body: some View {
    Section("Guides") {
      Toggle("Vertical 9:16", isOn: Binding(
        get: { model.guides.marker == vertical },
        set: { enabled in model.guides.marker = enabled ? vertical : nil }))
      Toggle("Thirds", isOn: $model.guides.thirds)
      Toggle("Centre mark", isOn: Binding(
        get: { model.guides.axes || model.guides.bullseye },
        set: { enabled in model.guides.axes = enabled; model.guides.bullseye = false }))
      DisclosureGroup("Advanced") { CameraGuideSections(model: model) }
    }
  }
}
