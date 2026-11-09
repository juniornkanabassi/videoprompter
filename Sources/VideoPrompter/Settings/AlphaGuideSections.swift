import SwiftUI

/// Shared by Settings and the Guides tab in Adjust.
struct AlphaGuideSections: View {
  @ObservedObject var model: CameraModel
  @State var advancedExpanded = false
  private let vertical = CameraAspect(width: 9, height: 16)
  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text("Guides").font(.title2.bold())
      Text("Guides help frame the picture. They do not change the camera.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: Space.sm) {
        card("Vertical 9:16", icon: "rectangle.portrait", selected: model.effectiveGuides.marker == vertical) {
          model.chooseFrameMarker(model.effectiveGuides.marker == vertical ? nil : vertical)
        }
        card("Thirds", icon: "grid", selected: model.effectiveGuides.thirds) { model.chooseGuide { $0.thirds = !model.effectiveGuides.thirds } }
        card("Centre mark", icon: "scope", selected: model.effectiveGuides.axes || model.effectiveGuides.bullseye) {
          let enabled = !(model.effectiveGuides.axes || model.effectiveGuides.bullseye)
          model.chooseGuide { $0.axes = enabled; $0.bullseye = false }
        }
      }
      if model.guides.axes || model.guides.bullseye {
        HStack {
          Text("Centre mark")
          ForEach([true, false], id: \.self) { dot in
            Button(dot ? "Dot" : "Cross") {
              model.chooseGuide { $0.axes = !dot; $0.bullseye = dot }
            }.buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: AlphaStyle.minTarget)
              .foregroundStyle(model.effectiveGuides.bullseye == dot && model.framingIsVisible ? AlphaStyle.onAccent : .primary)
              .background(model.effectiveGuides.bullseye == dot && model.framingIsVisible ? AlphaStyle.accent : .clear, in: RoundedRectangle(cornerRadius: Space.sm))
              .accessibilityAddTraits(model.effectiveGuides.bullseye == dot && model.framingIsVisible ? .isSelected : [])
          }
        }

      }
      DisclosureGroup(isExpanded: $advancedExpanded) { CameraGuideSections(model: model) } label: {
        Text("Advanced").font(.system(size: 17, weight: .semibold)).frame(minHeight: AlphaStyle.minTarget)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func card(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: Space.sm) {
        Image(systemName: icon).font(.system(size: 28)).frame(height: 40)
        Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
      }.frame(maxWidth: .infinity, minHeight: 96)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Space.md))
        .overlay(RoundedRectangle(cornerRadius: Space.md).stroke(selected ? AlphaStyle.accent : .clear, lineWidth: AlphaStyle.selectionStroke))
        .overlay(alignment: .topTrailing) { if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(AlphaStyle.accent).padding(Space.sm) } }
    }.buttonStyle(.plain).accessibilityValue(selected ? "On" : "Off")
      .accessibilityAddTraits(.isToggle).accessibilityAddTraits(selected ? .isSelected : [])
  }
}
