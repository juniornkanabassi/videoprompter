import AppKit
import SwiftUI

/// Give the native tracking control the full target height, not a padded wrapper.
struct ReadingSlider: NSViewRepresentable {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let title: String
  let spokenValue: String
  @Environment(\.isEnabled) private var isEnabled

  func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

  func makeNSView(context: Context) -> NSSlider {
    let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                          target: context.coordinator, action: #selector(Coordinator.changed(_:)))
    slider.isContinuous = true
    return slider
  }

  func updateNSView(_ slider: NSSlider, context: Context) {
    context.coordinator.value = $value
    slider.minValue = range.lowerBound
    slider.maxValue = range.upperBound
    slider.doubleValue = value
    slider.isEnabled = isEnabled
    slider.setAccessibilityLabel(title)
    slider.setAccessibilityValueDescription(spokenValue)
    slider.cell?.setAccessibilityLabel(title)
    slider.cell?.setAccessibilityValueDescription(spokenValue)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 24)
  }

  @MainActor final class Coordinator: NSObject {
    var value: Binding<Double>
    init(value: Binding<Double>) { self.value = value }
    @objc func changed(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue }
  }
}
