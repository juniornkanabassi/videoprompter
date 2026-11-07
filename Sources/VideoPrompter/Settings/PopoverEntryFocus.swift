import SwiftUI

private struct PopoverEntryRequested: EnvironmentKey {
  static let defaultValue = false
}
extension EnvironmentValues {
  var popoverEntryRequested: Bool {
    get { self[PopoverEntryRequested.self] }
    set { self[PopoverEntryRequested.self] = newValue }
  }
}
extension View {
  /// Request entry focus without stealing it when the same page is used in Settings.
  func popoverEntryFocus() -> some View { environment(\.popoverEntryRequested, true) }
  func initialPopoverFocus(when eligible: Bool = true) -> some View {
    modifier(InitialPopoverFocus(eligible: eligible))
  }
}
private struct InitialPopoverFocus: ViewModifier {
  @Environment(\.popoverEntryRequested) private var requested
  let eligible: Bool
  @FocusState private var keyboardFocused: Bool
  @AccessibilityFocusState private var accessibilityFocused: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if requested && eligible {
    content.focusable()
      .focused($keyboardFocused).accessibilityFocused($accessibilityFocused)
      .task(id: requested && eligible) {
        guard requested && eligible else { return }
        // The popover must be attached before SwiftUI accepts either focus request.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        keyboardFocused = true; accessibilityFocused = true
      }
    } else { content }
  }
}
