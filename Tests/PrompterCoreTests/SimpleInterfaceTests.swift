import AppKit
import SwiftUI
import PrompterCore
import XCTest
@testable import VidPrompt

@MainActor final class SimpleInterfaceTests: XCTestCase {
  func testPreferencePersistsPerDataDirectoryAndInspectorHidesOnlyAdvancedSections() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simple-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let arguments = ["test", "--data-directory", root.path]
    let otherRoot = root.appendingPathComponent("another")
    let otherArguments = ["test", "--data-directory", otherRoot.path]
    defer {
      for directory in [root, otherRoot] {
        let suite = "VidPrompt.\(MarkdownLibrary.fingerprint(directory.standardizedFileURL.path))"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      }
    }
    let store = AppStore(arguments: arguments)
    store.simpleInterface = true
    let before = store.settings
    let reopened = AppStore(arguments: arguments)
    XCTAssertTrue(reopened.simpleInterface)
    XCTAssertTrue(reopened.showsSimpleInterface)
    let other = AppStore(arguments: otherArguments)
    XCTAssertFalse(other.simpleInterface)
    XCTAssertFalse(other.showsSimpleInterface)
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
