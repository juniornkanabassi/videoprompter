import SwiftUI

/// Shared by Settings and the Guides tab in Adjust.
struct AlphaGuideSections: View {
  @ObservedObject var model: CameraModel
  private let vertical = CameraAspect(width: 9, height: 16)
  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("Guides").font(.title2.bold())
      Text("Guides help frame the picture. They do not change the camera.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: Space.sm) {
        card("Vertical 9:16", icon: "rectangle.portrait", selected: model.guides.marker == vertical) {
          model.guides.marker = model.guides.marker == vertical ? nil : vertical
        }
        card("Thirds", icon: "grid", selected: model.guides.thirds) { model.guides.thirds.toggle() }
        card("Centre mark", icon: "scope", selected: model.guides.axes || model.guides.bullseye) {
          let enabled = !(model.guides.axes || model.guides.bullseye)
          model.guides.axes = enabled; model.guides.bullseye = false
        }
      }
      if model.guides.axes || model.guides.bullseye {
        Picker("Centre mark", selection: Binding(get: { model.guides.bullseye }, set: { dot in
          model.guides.axes = !dot; model.guides.bullseye = dot
          model.framingGuidesBypassed = false; model.cleanView = false
        })) { Text("Dot").tag(true); Text("Cross").tag(false) }.pickerStyle(.segmented)
      }
      DisclosureGroup("Advanced") { CameraGuideSections(model: model) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func card(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button {
      if selected && (model.framingGuidesBypassed || model.cleanView) {
        model.framingGuidesBypassed = false; model.cleanView = false
      } else {
        action()
        if !selected { model.framingGuidesBypassed = false; model.cleanView = false }
      }
    } label: {
      VStack(spacing: Space.sm) {
        Image(systemName: icon).font(.system(size: 28)).frame(height: 40)
        Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
      }.frame(maxWidth: .infinity, minHeight: 96)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Space.md))
        .overlay(RoundedRectangle(cornerRadius: Space.md).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
    }.buttonStyle(.plain).accessibilityValue(selected ? "On" : "Off")
  }
}
