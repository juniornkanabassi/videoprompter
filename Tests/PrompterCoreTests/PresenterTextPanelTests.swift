import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class PresenterTextPanelTests: XCTestCase {
  func testLayoutVocabulary() {
    XCTAssertEqual([0.3, 0.54, 0.55, 0.79, 0.8, 1].map(PresenterTextPanel.marginLabel), ["Wide", "Wide", "Medium", "Medium", "Narrow", "Narrow"])
    XCTAssertEqual([0, 0.16, 0.25, 0.5].map { PresenterTextPanel.spacingLabel($0, range: 0...0.5) }, ["Tight", "Tight", "Medium", "Loose"])
    XCTAssertEqual([0, 0.34, 0.67, 1].map { PresenterTextPanel.spacingLabel($0, range: 0...1) }, ["Tight", "Medium", "Loose", "Loose"])
    XCTAssertEqual(PresenterTextPanel.percent(0.44), "44%")
  }

  func testAllThreeHostsUseTheSharedControls() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for path in ["Sources/VideoPrompter/Camera/IPadRemoteView.swift", "Sources/VideoPrompter/Library/ReadingInspectorView.swift", "iPad/VideoPrompter/Presenter/PresenterScreen.swift"] {
      let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
      XCTAssertTrue(source.contains("PresenterTextPanel("), path)
      for binding in ["countdown:", "fontName:", "fontSize:", "textWidth:", "lineSpacing:", "paragraphSpacing:", "guideFraction:", "bandOpacity:"] {
        XCTAssertTrue(source.contains(binding), "\(path): \(binding)")
      }
    }
  }

  func testRemoteCleanAlwaysExposesExitAndTransport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("CleanConsole")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let link = IPadCameraSender(defaults: defaults)
    for cameraOnly in [false, true] {
      let state = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "Manual", speed: 120,
        word: 0, words: 0, look: .init(cleanLook: .pictureOnly), cleanScreen: true, cameraOnly: cameraOnly)
      let (window, host) = await LibraryAX.host(IPadRemoteView(link: link, store: store, stateOverride: state, startsLink: false), size: .init(width: 1180, height: 820))
      defer { LibraryAX.close(window) }
      for title in ["Exit Clean · Esc", "Clean", "Start reading"] {
        XCTAssertFalse(LibraryAX.named(title, in: host).isEmpty, title)
      }
    }
  }

  func testBothMacHostsExposeAllTextControls() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("TextPanel")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let link = IPadCameraSender(defaults: defaults)
    let state = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "Voice", speed: 120, word: 0, words: 0)
    for view in [AnyView(PresenterTextSettings(store: store)), AnyView(IPadRemoteView(link: link, store: store, startsLink: false).adjustControls(state))] {
      let (window, host) = await LibraryAX.host(view.padding(16), size: .init(width: 440, height: 800))
      defer { LibraryAX.close(window) }
      for label in ["Reading mode", "Countdown", "Font", "Text size", "Margins", "Line spacing", "Paragraph spacing", "Reading line", "Reading band strength", "Smaller text", "Larger text"] {
        XCTAssertFalse(LibraryAX.named(label, in: host).isEmpty, label)
      }
      XCTAssertEqual(LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityRole") == "AXSlider" }.count, 6)
    }
  }
}

extension AppearanceSnapshotTests {
  func testCleanMenuOpen() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let menu = PresenterCleanMenu(selected: .pictureAndScript, active: true, keepMicMeter: .constant(true), choose: { _ in }, leave: {})
    try await snapshot(menu.choices, name: "clean-menu-open", size: .init(width: 360, height: 340), scheme: .dark, destination: URL(fileURLWithPath: output))
  }

  func testPresenterTextPanels() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("TextPanelSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let link = IPadCameraSender(defaults: defaults)
    let state = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "Voice", speed: 120, word: 0, words: 0)
    for (name, view) in [("mac-presenter-text", AnyView(PresenterTextSettings(store: store))), ("mac-ipad-control-text", AnyView(IPadRemoteView(link: link, store: store, startsLink: false).adjustControls(state)))] {
      try await snapshot(view.padding(Space.lg), name: name, size: .init(width: 440, height: 680), scheme: .dark, destination: URL(fileURLWithPath: output))
    }
  }
}
