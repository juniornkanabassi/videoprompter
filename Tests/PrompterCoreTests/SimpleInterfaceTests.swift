import AppKit
import SwiftUI
import PrompterCore
import XCTest
@testable import VidPrompt


@MainActor
private func labels(_ element: Any) -> [String] {
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

@MainActor
private func accessibilityObjects(_ element: Any) -> [NSObject] {
  guard let object = element as? NSObject else { return [] }
  let selector = NSSelectorFromString("accessibilityChildren")
  let children = object.responds(to: selector)
    ? object.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
  let fallback = object.accessibilityAttributeValue(.children) as? [Any] ?? (object as? NSView)?.subviews ?? []
  return [object] + (children.isEmpty ? fallback : children).flatMap(accessibilityObjects)
}

@MainActor final class SimpleInterfaceTests: XCTestCase {
  func testEmptyLibraryExplainsTheStepsAndOffersBothCreationActions() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-ui-\(UUID())")
    let suite = "VidPrompt.\(MarkdownLibrary.fingerprint(root.standardizedFileURL.path))"
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    let store = AppStore(arguments: ["test", "--data-directory", root.path])
    let host = NSHostingView(rootView: LibraryView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1132, height: 750), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    for zoom in [1.0, 1.5, 2.0] {
    store.uiZoom = zoom
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    let rendered = labels(host).joined(separator: "|")
    for text in ["Your script, ready to read", "Add a script", "Choose Voice or Manual in Presenter settings", "After adding a script, press Present", "Import Script", "New Script"] {
      XCTAssertTrue(rendered.contains(text), "Missing first-use guidance: \(text)")
    }
    }
    // Geometry, not just AX presence: the whole guide stays inside the 200% detail column.
    let guidance = try XCTUnwrap(accessibilityObjects(host).first {
      labels($0).first?.contains("VidPrompt keeps your script") == true
    })
    XCTAssertTrue(guidance.responds(to: NSSelectorFromString("accessibilityFrame")))
    let frame = try XCTUnwrap(guidance.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    let guideFrame = window.convertFromScreen(frame)
    XCTAssertGreaterThanOrEqual(guideFrame.minX, 400, "guide stays to the right of the zoomed sidebar")
    XCTAssertLessThanOrEqual(guideFrame.maxX, 813, "guide stays to the left of the inspector")
    XCTAssertGreaterThan(frame.height, 200, "all steps wrap into a readable column")
    store.create()
    for _ in 0..<20 where store.selected == nil { try? await Task.sleep(for: .milliseconds(30)) }
    XCTAssertNotNil(store.selected, "New Script creates and selects a script")
  }

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
    XCTAssertTrue(store.simpleInterface, "a new data root starts with the simple interface")
    let before = store.settings
    let reopened = AppStore(arguments: arguments)
    XCTAssertTrue(reopened.simpleInterface)
    XCTAssertTrue(reopened.showsSimpleInterface)
    let other = AppStore(arguments: otherArguments)
    XCTAssertTrue(other.simpleInterface)
    XCTAssertTrue(other.showsSimpleInterface)
    let host = NSHostingView(rootView: InspectorView(store: store))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 1800), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async { for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
    await settle()
    let simple = labels(host).joined(separator: "|")
    XCTAssertTrue(simple.contains("Text size")); XCTAssertTrue(simple.contains("How it follows you"))
    XCTAssertFalse(simple.contains("Advanced appearance")); XCTAssertFalse(simple.contains("Saved settings"))
    XCTAssertFalse(simple.contains("Microphone volume"))
    XCTAssertFalse(simple.contains("Loudest sound"))
    XCTAssertFalse(simple.contains("Spoken language"))
    XCTAssertTrue(simple.contains("Test microphone"))
    XCTAssertTrue(simple.contains("Microphone peak level"))
    XCTAssertTrue(simple.contains("Mirror for teleprompter glass"))
    store.simpleInterface = false
    XCTAssertTrue(AppStore(arguments: otherArguments).simpleInterface, "the other data directory keeps its own preference")
    XCTAssertFalse(AppStore(arguments: arguments).simpleInterface, "an explicit advanced preference survives reopening")
    await settle()
    let full = labels(host).joined(separator: "|")
    XCTAssertTrue(full.contains("Advanced appearance")); XCTAssertTrue(full.contains("Saved settings"))
    XCTAssertTrue(full.contains("Text size")); XCTAssertTrue(full.contains("How it follows you"))
    XCTAssertTrue(full.contains("Microphone volume"))
    XCTAssertTrue(full.contains("Loudest sound"))
    XCTAssertTrue(full.contains("Spoken language"))
    store.simpleInterface = true
    XCTAssertTrue(AppStore(arguments: arguments).simpleInterface, "an explicit simple preference survives reopening")
    XCTAssertEqual(store.settings, before)
  }
}
