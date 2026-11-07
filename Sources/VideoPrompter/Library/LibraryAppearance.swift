import AppKit
import SwiftUI

/// Resolve semantic colours before a split view reparents its row hosts into vibrant surfaces.
enum LibraryAppearance {
  static func color(_ color: NSColor, scheme: ColorScheme) -> Color {
    var resolved = color
    NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.deviceRGB) ?? color
    }
    return Color(nsColor: resolved)
  }
}

struct InspectorSection<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  @ViewBuilder let content: () -> Content
  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: Space.md) { content() }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.97), in: .rect(cornerRadius: Space.md))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// An AppKit popup resolves its own appearance even when the inspector is hosted in a split view.
struct InspectorChoice<Value: Hashable>: NSViewRepresentable {
  let title: String
  let values: [Value]
  let names: [String]
  @Binding var selection: Value
  @Environment(\.colorScheme) private var scheme
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton()
    button.target = context.coordinator
    button.action = #selector(Coordinator.choose(_:))
    button.font = .systemFont(ofSize: NSFont.systemFontSize)
    button.setAccessibilityLabel(title)
    button.cell?.setAccessibilityLabel(title)
    return button
  }
  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    button.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    if button.itemTitles != names { button.removeAllItems(); button.addItems(withTitles: names) }
    if let index = values.firstIndex(of: selection) {
      button.selectItem(at: index)
      for (itemIndex, item) in button.itemArray.enumerated() { item.state = itemIndex == index ? .on : .off }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.fittingSize.width, height: nsView.fittingSize.height)
  }
  @MainActor final class Coordinator: NSObject {
    var parent: InspectorChoice
    init(_ parent: InspectorChoice) { self.parent = parent }
    @objc func choose(_ sender: NSPopUpButton) {
      guard parent.values.indices.contains(sender.indexOfSelectedItem) else { return }
      parent.selection = parent.values[sender.indexOfSelectedItem]
    }
  }
}
