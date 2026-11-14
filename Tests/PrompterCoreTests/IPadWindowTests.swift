import AppKit
@testable import VideoPrompter
import Foundation
import XCTest

final class IPadWindowTests: XCTestCase {
  private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
  func testSingleIPadMenuAndShortcut() throws {
    let app = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/App/VideoPrompterApp.swift"), encoding: .utf8)
    let commands = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Camera/IPadCameraSender.swift"), encoding: .utf8)
    XCTAssertTrue(app.contains("Window(\"iPad\", id: \"ipad-remote\")"))
    let window = try XCTUnwrap(app.range(of: "Window(\"iPad\""))
    let nextWindow = app[window.upperBound...].range(of: "Window(")
    let scene = app[window.lowerBound..<(nextWindow?.lowerBound ?? app.endIndex)]
    XCTAssertTrue(scene.contains(".commandsRemoved()"), "Suppress the automatic duplicate Window menu entry")
    XCTAssertEqual(commands.components(separatedBy: "Button(\"iPad…\")").count - 1, 1)
    XCTAssertTrue(commands.contains(".keyboardShortcut(\"i\", modifiers: [.option, .command])"))
    XCTAssertFalse(commands.contains("Button(\"Control iPad"))
  }
  @MainActor func testConsoleSupportsStandardFullScreenWithoutEnteringIt() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
    IPadWindowConfigurator.configure(window)
    XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
    XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertEqual(window.standardWindowButton(.zoomButton)?.action, #selector(NSWindow.toggleFullScreen(_:)))
    XCTAssertFalse(window.styleMask.contains(.fullScreen))
  }
  func testRemoteKeyboardBindings() throws {
    let view = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Camera/IPadRemoteView.swift"), encoding: .utf8)
    for key in ["space", "home", "upArrow", "downArrow", "leftArrow", "rightArrow"] {
      XCTAssertTrue(view.contains(".keyboardShortcut(.\(key), modifiers: [])"), key)
    }
    XCTAssertTrue(view.contains(".disabled(state.editing == true)"))
  }
}
