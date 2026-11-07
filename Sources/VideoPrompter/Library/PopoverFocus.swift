import AppKit
import SwiftUI

extension View {
  func restoringPopoverFocus(isPresented: Binding<Bool>, identifier: String) -> some View {
    modifier(PopoverFocus(isPresented: isPresented, identifier: identifier))
  }
}

/// Keep the actual opener: a label search after dismissal can find a different picker.
private struct PopoverFocus: ViewModifier {
  @Binding var isPresented: Bool
  let identifier: String
  @FocusState private var focused: Bool
  @AccessibilityFocusState private var accessibilityFocused: Bool
  func body(content: Content) -> some View {
    content.accessibilityIdentifier(identifier).focusable().focused($focused).accessibilityFocused($accessibilityFocused)
      .background(PopoverFocusAnchor(isPresented: isPresented, identifier: identifier))
      .onChange(of: isPresented) { _, open in
        if !open {
          DispatchQueue.main.async { focused = true; accessibilityFocused = true }
        }
      }
  }
}

private struct PopoverFocusAnchor: NSViewRepresentable {
  let isPresented: Bool
  let identifier: String
  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) {
    guard view.wasOpen != isPresented else { return }
    view.wasOpen = isPresented
    if isPresented {
      view.opener = view.findOpener(identifier)
    } else {
      // SwiftUI completes the popover dismissal before native focus can be restored.
      DispatchQueue.main.async { [weak view] in view?.restore() }
    }
  }
  final class Anchor: NSView {
    var wasOpen = false
    weak var opener: NSObject?
    override func isAccessibilityElement() -> Bool { false }
    func findOpener(_ identifier: String) -> NSObject? {
      var ancestor = superview
      while let current = ancestor {
        if let match = Self.find(identifier, in: current) { return match }
        ancestor = current.superview
      }
      return nil
    }
    static func find(_ identifier: String, in root: NSObject) -> NSObject? {
      var visited = Set<ObjectIdentifier>()
      func visit(_ element: NSObject) -> NSObject? {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        let identity = NSSelectorFromString("accessibilityIdentifier")
        if element.responds(to: identity), element.perform(identity)?.takeUnretainedValue() as? String == identifier { return element }
        let children = NSSelectorFromString("accessibilityChildren")
        let accessible = element.responds(to: children) ? element.perform(children)?.takeUnretainedValue() as? [NSObject] ?? [] : []
        for child in accessible + ((element as? NSView)?.subviews ?? []) {
          if let match = visit(child) { return match }
        }
        return nil
      }
      return visit(root)
    }
    func restore() {
      guard let opener else { return }
      if let responder = opener as? NSResponder { window?.makeFirstResponder(responder) }
      if opener.responds(to: NSSelectorFromString("setAccessibilityFocused:")) {
        opener.setValue(true, forKey: "accessibilityFocused")
        NSAccessibility.post(element: opener, notification: .focusedUIElementChanged)
      }
      self.opener = nil
    }
  }
}
