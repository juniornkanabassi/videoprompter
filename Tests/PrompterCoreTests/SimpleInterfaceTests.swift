import AppKit
import SwiftUI
import PrompterCore
import XCTest
@testable import JuniorPrompter

@MainActor final class SimpleInterfaceTests: XCTestCase {
  func testAlphaPreferencePersistsAndInspectorHidesOnlyAdvancedSections() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simple-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "SimpleTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    store.isAlphaChannel = true; store.simpleInterface = true
    let before = store.settings
    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertTrue(reopened.simpleInterface)
    reopened.isAlphaChannel = false; XCTAssertFalse(reopened.showsSimpleInterface)
    let otherRoot = root.appendingPathComponent("another")
    let other = AppStore(arguments: ["test", "--data-directory", otherRoot.path], defaults: UserDefaults(suiteName: "SimpleOther.\(UUID())")!)
    XCTAssertFalse(other.simpleInterface)
    let host = NSHostingView(rootView: InspectorView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 1800), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    func labels(_ element: Any) -> [String] {
      guard let object = element as? NSObject else { return [] }
      func attribute(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
      }
      let own = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { attribute($0).map { String(describing: $0) } }.joined(separator: " ")
      let children = attribute("accessibilityChildren") as? [Any] ?? (object.accessibilityAttributeValue(.children) as? [Any] ?? [])
      let viewChildren = (object as? NSView)?.subviews ?? []
      return [own] + (children.isEmpty ? viewChildren.flatMap(labels) : children.flatMap(labels))
    }
    func settle() async { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
    await settle()
    let simple = labels(host).joined(separator: "|")
    XCTAssertTrue(simple.contains("Text size")); XCTAssertTrue(simple.contains("Tracking"))
    XCTAssertFalse(simple.contains("Advanced appearance")); XCTAssertFalse(simple.contains("Presets"))
    store.simpleInterface = false; await settle()
    let full = labels(host).joined(separator: "|")
    XCTAssertTrue(full.contains("Advanced appearance")); XCTAssertTrue(full.contains("Presets"))
    XCTAssertTrue(full.contains("Text size")); XCTAssertTrue(full.contains("Tracking"))
    XCTAssertEqual(store.settings, before)
  }
}
