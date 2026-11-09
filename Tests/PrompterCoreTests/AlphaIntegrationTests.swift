import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class AlphaIntegrationTests: XCTestCase {
  private func camera() -> CameraModel {
    let model = CameraModel(defaults: freshDefaults("AlphaIntegration"))
    model.guides.zebraLevel = 55
    model.guides.zebraRange = 3
    model.guides.zebras = false
    model.guides.falseColour = false
    model.guides.greyCardCheck = true
    return model
  }

  private func assertRestored(_ model: CameraModel, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(model.guides.greyCardCheck, file: file, line: line)
    XCTAssertEqual(model.guides.zebraLevel, 55, file: file, line: line)
    XCTAssertEqual(model.guides.zebraRange, 3, file: file, line: line)
  }

  func testMenuAndKeyboardZebraBindingEndsGreyCard() {
    let model = camera()
    model.exposureBinding(\.zebras).wrappedValue = false
    assertRestored(model)
    XCTAssertFalse(model.guides.zebras)
    XCTAssertFalse(model.guides.falseColour)
  }
  func testMenuAndKeyboardFalseColourBindingEndsGreyCard() {
    let model = camera()
    model.exposureBinding(\.falseColour).wrappedValue = false
    assertRestored(model)
    XCTAssertFalse(model.guides.falseColour)
    XCTAssertFalse(model.guides.zebras)
  }
  private func press<V: View>(_ title: String, in view: V) async throws {
    let (window, host) = await LibraryAX.host(view, size: .init(width: 1000, height: 900))
    defer { LibraryAX.close(window) }
    let node = try XCTUnwrap(LibraryAX.named(title, in: host).first { ["AXButton", "AXCheckBox", "AXSwitch"].contains(LibraryAX.value($0, "accessibilityRole")) }, title)
    // Native switches can return false after applying the action; assert the model below.
    _ = LibraryAX.bool(node, "accessibilityPerformPress")
  }
  func testSettingsExposureRowEndsGreyCard() async throws {
    let model = camera()
    try await press("False colour", in: ExposureToolToggles(model: model))
    assertRestored(model)
    XCTAssertFalse(model.guides.falseColour)
  }
  func testFalseColourAdjustSwitchEndsGreyCard() async throws {
    let model = camera()
    try await press("False colour", in: FalseColourAdjustView(guides: Binding(get: { model.guides }, set: { model.guides = $0 })))
    assertRestored(model)
    XCTAssertFalse(model.guides.falseColour)
  }
  func testLegacyZebraPresetEndsGreyCard() async throws {
    let model = camera()
    try await press("Highlights", in: ZebraSettings(guides: Binding(get: { model.guides }, set: { model.guides = $0 })))
    XCTAssertFalse(model.guides.greyCardCheck)
    XCTAssertEqual(model.guides.zebraLevel, 95)
    XCTAssertFalse(model.guides.falseColour)
  }
  func testLegacyAndAdjustNumberBindingsRestoreBeforeEditing() {
    for key in [\CameraGuides.zebraLevel, \.zebraRange] {
      let model = camera()
      let binding = Binding(get: { model.guides }, set: { model.guides = $0 })
      binding.manualExposure(key).wrappedValue = 4
      XCTAssertFalse(model.guides.greyCardCheck)
      XCTAssertEqual(model.guides[keyPath: key], 4)
      XCTAssertFalse(model.guides.falseColour)
    }
  }
  func testLegacyAndAdjustModeBindingEndsGreyCard() {
    let model = camera()
    let binding = Binding(get: { model.guides }, set: { model.guides = $0 })
    binding.manualExposure(\.zebraRangeMode).wrappedValue = false
    XCTAssertFalse(model.guides.greyCardCheck)
    XCTAssertFalse(model.guides.zebraRangeMode)
    XCTAssertFalse(model.guides.falseColour)
  }
  func testPresenterTilesEndGreyCard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("GreyCardTiles")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Test", markdown: "Test script")
    store.session.present(record: record, settings: store.settings)
    for title in ["Zebras", "False colour"] {
      let model = camera()
      model.displayMode = .prompterWithVideo
      try await press(title, in: PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: model, startsCamera: false, recorder: CameraRecorder(defaults: defaults)))
      assertRestored(model)
      XCTAssertFalse(model.guides.zebras)
      XCTAssertFalse(model.guides.falseColour)
    }
  }
  func testFirstLaunchActionsAreVisibleAtEnlargedSizes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("FirstLaunchFit")))
    for zoom in [1.5, 2.0] {
      var openedCamera = false
      let view = LibraryStartView(store: store, importing: .constant(false), practice: {}, camera: { openedCamera = true }).uiZoom(zoom)
      let (window, host) = await LibraryAX.host(view, size: .init(width: 800, height: 700))
      for title in ["Read a script", "Set up camera"] {
    let node = try XCTUnwrap(LibraryAX.named(title, in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
        let frame = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "\(title) at \(zoom): \(frame)")
        XCTAssertGreaterThanOrEqual(frame.height, 56)
        if title == "Set up camera" { XCTAssertTrue(LibraryAX.bool(node, "accessibilityPerformPress")) }
      }
      XCTAssertTrue(openedCamera)
      LibraryAX.close(window)
    }
  }
  func testExposureKeyPreferenceAppliesToSetupAndReading() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("ExposureKeyVisibility")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Test", markdown: "Test script")
    store.session.present(record: record, settings: store.settings)
    let model = camera()
    model.displayMode = .prompterWithVideo
    for enabled in [false, true] {
      defaults.set(enabled, forKey: "presenterExposureKey")
      for reading in [false, true] {
        let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: model, startsCamera: false, recorder: CameraRecorder(defaults: defaults), shell: PresenterShell(reading: reading)).defaultAppStorage(defaults)
        let (window, host) = await LibraryAX.host(view, size: .init(width: 1600, height: 1000))
        let keys = LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-exposure-legend" }
        XCTAssertEqual(!keys.isEmpty, enabled)
        LibraryAX.close(window)
      }
    }
  }
  func testAdjustCloseReturnsFocusToOpeningTileInBothForms() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("AdjustFocus")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Test", markdown: "Test script")
    store.session.present(record: record, settings: store.settings)
    for zoom in [1.0, 2.0] {
      store.uiZoom = zoom
      let shell = PresenterShell()
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera(), startsCamera: false, recorder: CameraRecorder(defaults: defaults), shell: shell)
      let (window, host) = await LibraryAX.host(view, size: .init(width: 1000, height: 700))
      let opener = try XCTUnwrap(LibraryAX.named("Adjust", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
      XCTAssertTrue(LibraryAX.bool(opener, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(200))
      let close = try XCTUnwrap(LibraryAX.named("Close Adjust", in: host).first)
      XCTAssertTrue(LibraryAX.bool(close, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(200))
      XCTAssertNil(shell.adjustTab)
      XCTAssertTrue(LibraryAX.bool(opener, "isAccessibilityFocused"))
      LibraryAX.close(window)
    }
  }
  func testAdjustSheetKeepsFourHundredPointsOfStage() {
    XCTAssertFalse(PresenterView.usesAdjustSheet(width: 1000, zoom: 1))
    XCTAssertTrue(PresenterView.usesAdjustSheet(width: 1000, zoom: 1.5))
    XCTAssertTrue(PresenterView.usesAdjustSheet(width: 1000, zoom: 2))
    XCTAssertFalse(PresenterView.usesAdjustSheet(width: 1600, zoom: 2))
  }
}

extension AppearanceSnapshotTests {
  func testAlphaIntegratedAdjustSnapshots() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("AlphaIntegratedAdjust")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "A clear opening", markdown: "Read these opening words at your own pace.")
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.guides.zebras = true
    let recorder = CameraRecorder(defaults: defaults)
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for tab in AdjustTab.allCases {
        let shell = PresenterShell(adjustTab: tab)
        try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder, shell: shell, referencePicture: NSImage(contentsOf: Bundle.module.url(forResource: "presenter-zebras", withExtension: "png", subdirectory: "Fixtures")!)), name: "r2-adjust-\(tab.rawValue)-\(Int(zoom * 100))", size: .init(width: 1000, height: 700), scheme: .dark, destination: URL(fileURLWithPath: output))
      }
    }
  }
}
