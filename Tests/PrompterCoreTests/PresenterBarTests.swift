import AppKit
import PrompterCore
import SwiftUI
import XCTest

@testable import VideoPrompter

/// The presenter bar keeps the camera picker and Framing guides reachable while the camera is on,
/// dimmed but in place while it is off, so the bar is the same width in every view. Offscreen
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
      let role = NSSelectorFromString("accessibilityRole"), name = NSSelectorFromString("accessibilityLabel")
      guard object.responds(to: role),
        let value = object.perform(role)?.takeUnretainedValue() as? String,
        ["AXButton", "AXMenuButton", "AXPopUpButton"].contains(value),
        object.responds(to: name) else { return false }
      return object.perform(name)?.takeUnretainedValue() as? String == label
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

  func testCameraPickerAndFramingGuidesAreReachableAndTheBarKeepsOneWidth() async throws {
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
      var widths: [PresenterDisplayMode: CGFloat] = [:]
      for mode in [PresenterDisplayMode.prompterOnly, .prompterWithVideo, .videoOnly, .prompterOnly] {
        camera.displayMode = mode
        await settle()
        let picker = try button("Camera", in: host)
        let guides = try button("Framing guides", in: host)
        XCTAssertEqual(try isEnabled(picker), camera.presentsWithVideo, "\(zoom) \(mode): picker dimmed only while the camera is off")
        XCTAssertEqual(try isEnabled(guides), camera.presentsWithVideo, "\(zoom) \(mode): guides dimmed only while the camera is off")
        _ = try button("Presenter view", in: host)
        let start = try frame(button(store.session.isActivelyRunning ? "Pause" : "Start", in: host))
        let close = try frame(button("Close presenter", in: host))
        for control in [picker, guides] {
          let rect = try frame(control)
          XCTAssertGreaterThan(rect.width, 0, "\(zoom) \(mode)")
          XCTAssertEqual(rect.midY, start.midY, accuracy: 2, "\(zoom) \(mode): one row")
          XCTAssertTrue(rect.minX > start.maxX && rect.maxX < close.minX, "\(zoom) \(mode): inside the bar")
          if camera.presentsWithVideo {
            // A real click lands on the control, not on the video or script behind it.
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            let hit = host.superview?.hitTest(point)
            XCTAssertTrue(hit === host || hit?.isDescendant(of: host) == true, "\(zoom) \(mode): control is hit-testable")
          }
        }
        XCTAssertLessThanOrEqual(try frame(picker).width, PresenterView.cameraPickerWidth * zoom + 2,
                                 "\(zoom) \(mode): a camera name never widens the bar")
        let width = close.maxX - start.minX
        if let first = widths.values.first {
          XCTAssertEqual(width, first, accuracy: 1, "\(zoom) \(mode): the bar keeps one width")
        }
        widths[mode] = width
      }
    }
  }
}
