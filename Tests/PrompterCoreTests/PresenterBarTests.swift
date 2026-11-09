import AppKit
import PrompterCore
import SwiftUI
import XCTest

@testable import VideoPrompter

/// The presenter bar keeps the camera picker and Framing guides reachable while the camera is on,
/// hidden while it is off, with grouped controls inside the presenter. Offscreen
/// fixture camera only: `startsCamera: false`, and no window is ordered in.
@MainActor final class PresenterBarTests: XCTestCase {
  override func setUp() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
  }
  private func elements(_ element: Any) -> [NSObject] {
    guard let object = element as? NSObject else { return [] }
    let selector = NSSelectorFromString("accessibilityChildren")
    let children = object.responds(to: selector)
      ? object.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
    return [object] + (children.isEmpty ? (object as? NSView)?.subviews ?? [] : children).flatMap(elements)
  }

  private func button(_ label: String, in host: NSView) throws -> NSObject {
    try XCTUnwrap(elements(host).first { object in
      let role = NSSelectorFromString("accessibilityRole")
      guard object.responds(to: role),
        let value = object.perform(role)?.takeUnretainedValue() as? String,
        ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(value) else { return false }
      return ["accessibilityLabel", "accessibilityTitle"].contains { name in
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        let value = object.perform(selector)?.takeUnretainedValue()
        return (value as? String ?? (value as? NSAttributedString)?.string) == label
      }
    }, "The bar has no \(label) button. AX: \(elements(host).compactMap { self.label($0, "accessibilityLabel") ?? self.label($0, "accessibilityTitle") })")
  }

  private func frame(_ object: NSObject) throws -> NSRect {
    try XCTUnwrap(object.value(forKey: "accessibilityFrame") as? NSValue).rectValue
  }

  private func isEnabled(_ object: NSObject) throws -> Bool {
    // SwiftUI's virtual accessibility nodes implement this getter without adopting the protocol.
    let selector = NSSelectorFromString("isAccessibilityEnabled")
    guard object.responds(to: selector) else {
      XCTFail("Missing enabled getter on \(type(of: object))")
      throw NSError(domain: "PresenterBarTests", code: 1)
    }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
  }

  private func label(_ object: NSObject, _ name: String) -> String? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    let value = object.perform(selector)?.takeUnretainedValue()
    return value as? String ?? (value as? NSAttributedString)?.string
  }
  private func has(_ name: String, in host: NSView) -> Bool {
    elements(host).contains { label($0, "accessibilityLabel") == name || label($0, "accessibilityTitle") == name }
  }
  private func insideScrollView(_ node: NSObject) -> Bool {
    var current: NSObject? = node
    var seen = Set<ObjectIdentifier>()
    while let object = current, seen.insert(ObjectIdentifier(object)).inserted {
      if object is NSScrollView || label(object, "accessibilityRole") == "AXScrollArea" { return true }
      let getter = NSSelectorFromString("accessibilityParent")
      current = object.responds(to: getter) ? object.perform(getter)?.takeUnretainedValue() as? NSObject : nil
    }
    return false
  }





  func testEverySettingsPageHasAnEnabledSetting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("RealSettings")))
    let host = NSHostingView(rootView: SettingsPage(store: store, tab: .general))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 1000), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
    defer { window.contentView = nil; window.close() }
    for tab in SettingsTab.allCases {
      host.rootView = SettingsPage(store: store, tab: tab)
      for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      let controls = elements(host).filter { node in
        ["AXCheckBox", "AXSlider", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXButton"].contains(label(node, "accessibilityRole") ?? "")
      }
      XCTAssertTrue(controls.contains { (try? isEnabled($0)) == true }, "\(tab) needs a real enabled setting")
    }
  }



}
