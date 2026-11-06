import AppKit
import PrompterCore
import SwiftUI
import XCTest

@testable import VideoPrompter

/// The presenter bar keeps the camera picker and Framing guides reachable while the camera is on,
/// hidden while it is off, with grouped controls inside the presenter. Offscreen
/// fixture camera only: `startsCamera: false`, and no window is ordered in.
@MainActor final class PresenterBarTests: XCTestCase {
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
    }, "The bar has no \(label) button")
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

  func testCameraControlsStayReachableWithinGroupedPresenterAtEveryZoom() async throws {
    _ = NSApplication.shared
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("presenter-bar-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("PresenterBar")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Bar", markdown: "Opening words to read.")
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.authorization = .authorized
    let host = NSHostingView(rootView: PresenterView(
      store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera,
      monitor: ReferenceMonitor(), startsCamera: false))
    // Wide enough for one row at 200%, so the two ends of the bar measure its whole width.
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1500, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 1500, height: 700)
    defer { window.contentView = nil; window.close() }
    func settle() async { for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }

    for zoom in [1.0, 2.0] {
      store.uiZoom = zoom
      for mode in [PresenterDisplayMode.prompterOnly, .prompterWithVideo, .videoOnly, .prompterOnly] {
        camera.displayMode = mode
        await settle()
        _ = try button("Presenter view", in: host)
        let labels = ["Start reading", "Close presenter", "Reading", "Record camera"]
        for label in labels {
          let rect = try frame(button(label, in: host))
          XCTAssertGreaterThan(rect.width, 0)
          XCTAssertTrue(window.convertToScreen(host.bounds).contains(rect), "\(zoom) \(mode): \(label) remains inside the presenter")
        }
        if camera.presentsWithVideo {
          let picker = try button("Camera", in: host)
          let guides = try button("Framing guides", in: host)
          XCTAssertTrue(try isEnabled(picker))
          XCTAssertTrue(try isEnabled(guides))
          for control in [picker, guides] {
            let rect = try frame(control)
            XCTAssertTrue(window.convertToScreen(host.bounds).contains(rect))
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            let hit = host.superview?.hitTest(point)
            XCTAssertTrue(hit === host || hit?.isDescendant(of: host) == true)
          }
          XCTAssertLessThanOrEqual(try frame(picker).width, PresenterView.cameraPickerWidth * zoom + 2)
        }
      }
    }
  }
}
