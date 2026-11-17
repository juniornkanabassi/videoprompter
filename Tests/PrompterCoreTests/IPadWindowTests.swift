import AppKit
@testable import VideoPrompter
import Foundation
import XCTest

final class IPadWindowTests: XCTestCase {
  private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
  func testSingleIPadMenuAndShortcut() throws {
    let app = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/App/VideoPrompterApp.swift"), encoding: .utf8)
    let commands = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Camera/IPadCameraSender.swift"), encoding: .utf8)
    XCTAssertTrue(app.contains("Window(\"iPad Control\", id: \"ipad-remote\")"))
    let window = try XCTUnwrap(app.range(of: "Window(\"iPad Control\""))
    let nextWindow = app[window.upperBound...].range(of: "Window(")
    let scene = app[window.lowerBound..<(nextWindow?.lowerBound ?? app.endIndex)]
    XCTAssertTrue(scene.contains(".commandsRemoved()"), "Suppress the automatic duplicate Window menu entry")
    XCTAssertEqual(commands.components(separatedBy: "Button(\"iPad Control…\")").count - 1, 1)
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
    XCTAssertEqual(window.level, .normal)
    XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
    XCTAssertEqual(window.standardWindowButton(.zoomButton)?.action, #selector(NSWindow.toggleFullScreen(_:)))
    XCTAssertFalse(window.styleMask.contains(.fullScreen))
  }
  @MainActor func testFullScreenMenuTargetsIPadControlWhenItIsInFront() {
    let console = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    IPadWindowConfigurator.configure(console)
    XCTAssertTrue(IPadWindowConfigurator.fullScreenTarget(key: console) === console)
    XCTAssertNil(IPadWindowConfigurator.fullScreenTarget(key: other), "Other windows keep the presenter's full screen")
    XCTAssertNil(IPadWindowConfigurator.fullScreenTarget(key: nil))
  }
  @MainActor func testSecondMonitorUsesNormalWindowAndPreservesExplicitAlwaysOnTop() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    let coordinator = CameraWindowLevel.Coordinator()
    coordinator.observe(window)
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
    XCTAssertEqual(window.level, .normal)
    coordinator.alwaysOnTop = true
    coordinator.observe(window)
    XCTAssertEqual(window.level, .floating)
    NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
    XCTAssertEqual(window.level, .normal)
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    XCTAssertEqual(window.level, .floating)
  }

  func testRemoteKeyboardBindings() throws {
    let view = try String(contentsOf: root.appendingPathComponent("Sources/VideoPrompter/Camera/IPadRemoteView.swift"), encoding: .utf8)
    for key in ["space", "home", "upArrow", "downArrow", "leftArrow", "rightArrow"] {
      XCTAssertTrue(view.contains(".keyboardShortcut(.\(key), modifiers: [])"), key)
    }
    XCTAssertTrue(view.contains(".disabled(state.editing == true)"))
  }
}
