import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundFourteenTests: XCTestCase {
  func testKeyStripStaysOneLineAndKeepsEveryColourAtNarrowWidths() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBFourteenStrip"))
    camera.guides.zebras = true
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      for width in [240.0, 480.0, 720.0] {
        let (window, host) = await LibraryAX.host(ExposureLegend(model: camera, zoom: zoom), size: .init(width: width, height: 100))
        defer { LibraryAX.close(window) }
        host.sizingOptions = []
        host.frame.size = .init(width: width, height: 100)
        host.layoutSubtreeIfNeeded()
        let key = try XCTUnwrap(LibraryAX.named("Key", in: host).first)
        let keyFrame = frame(key)
        let colours = CameraExposure.bands.enumerated().map { "\(FalseColourKey.labels[$0.offset]). \($0.element.name)" }
        var previous: NSRect?
        for label in colours {
          let node = try XCTUnwrap(LibraryAX.named(label, in: host).first, label)
          let rect = frame(node)
          XCTAssertGreaterThan(rect.width, 0)
          XCTAssertLessThanOrEqual(abs(rect.midY - keyFrame.midY), 14 * zoom)
          if let previous { XCTAssertGreaterThanOrEqual(rect.minX, previous.maxX - 1) }
          previous = rect
        }
        XCTAssertTrue(LibraryAX.named(ExposureGuidance.colourMeanings[0], in: host).isEmpty)
        XCTAssertTrue(LibraryAX.named(ExposureLegend.measurement(level: 95, range: 0), in: host).isEmpty)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 40 * zoom)
      }
    }
  }

  func testKeyDisappearsWhenToolsAreOffOrComparisonHidesThem() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBFourteenVisibility"))
    for state in 0..<4 {
      camera.guides.zebras = state != 0
      camera.cleanView = state == 2
      camera.exposureBypassed = state == 3
      let (window, host) = await LibraryAX.host(ExposureLegend(model: camera))
      defer { LibraryAX.close(window) }
      XCTAssertEqual(!LibraryAX.named("Key", in: host).isEmpty, state == 1)
    }
  }

  func testExposureContentsDiscloseCustomLevelsAndPreserveTheSavedChoice() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBFourteenSettings"))
    camera.guides.zebraLevel = 85
    camera.guides.zebraRange = 7
    let original = camera.guides
    let (window, host) = await LibraryAX.host(Form { ExposureSettingsContent(model: camera) }.formStyle(.grouped))
    defer { LibraryAX.close(window) }
    XCTAssertEqual(camera.guides, original)
    for label in [ExposureLegend.zebraTitle(for: camera.guides.validatedZebraPurpose), "Check brightness · False colour", "Zebra reference", "Custom levels"] {
      XCTAssertFalse(LibraryAX.named(label, in: host).isEmpty, label)
    }
    XCTAssertTrue(LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityRole") == "AXIncrementor" }.isEmpty)
    window.makeKeyAndOrderFront(nil)
    let custom = try XCTUnwrap(LibraryAX.named("Custom levels", in: host).first {
      LibraryAX.value($0, "accessibilityIdentifier") == "exposure-custom-levels"
    })
    XCTAssertTrue(LibraryAX.bool(custom, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertFalse(LibraryAX.elements(host).filter { LibraryAX.value($0, "accessibilityRole") == "AXIncrementor" }.isEmpty)
    XCTAssertEqual(camera.guides, original)
  }

  func testTeachingRoutesHaveSeparatePurposesAndGuideOpensWithoutARecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("BuilderBFourteenGuide")))
    var guides = 0
    let (window, host) = await LibraryAX.host(LibraryStartView(store: store, importing: .constant(false), practice: {}, camera: {}, guide: { guides += 1 }))
    defer { LibraryAX.close(window) }
    for label in ["Quick Reading Practice", "Try reading for 30 seconds.", "Getting Started Guide", "Read the full guide to writing, reading and recording."] {
      XCTAssertFalse(LibraryAX.named(label, in: host).isEmpty)
    }
    XCTAssertTrue(LibraryAX.bool(try XCTUnwrap(LibraryAX.named("Getting Started Guide", in: host).first), "accessibilityPerformPress"))
    XCTAssertEqual(guides, 1)
    for _ in 0..<20 where store.selected?.metadata.title != WelcomeScript.title { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(store.selected?.metadata.title, WelcomeScript.title)
    XCTAssertFalse(store.session.state == .running)
  }

  func testCameraPickerInitiallyFocusesTheSelectedRowRatherThanThePreview() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBFourteenFocus"))
    camera.selectedUID = "second"
    let devices = [CameraDevice(uid: "first", name: "First camera"), CameraDevice(uid: "second", name: "Selected camera")]
    for zoom in [1.0, 1.5, 2.0] {
      let (window, host) = await LibraryAX.host(CameraPickerList(model: camera, zoom: zoom, startsPreview: false, devicesOverride: devices, close: {}).uiZoom(zoom))
      defer { LibraryAX.close(window) }
      window.makeKeyAndOrderFront(nil)
      try await Task.sleep(for: .milliseconds(100))
      let selected = try XCTUnwrap(LibraryAX.named("Selected camera", in: host).first)
      XCTAssertTrue(LibraryAX.bool(selected, "isAccessibilityFocused"))
    }
  }

  private func frame(_ object: NSObject) -> NSRect {
    (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
  }
}

extension AppearanceSnapshotTests {
  func testBuilderBRoundFourteenFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBFourteenSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    camera.guides.zebras = true
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      try await snapshot(ExposureLegend(model: camera, zoom: zoom), name: "r14-strip-\(Int(zoom * 100))-\(mode)", size: .init(width: 720, height: 100), scheme: scheme, destination: destination)
      try await snapshot(ExposureKeyPanel(model: camera, zoom: zoom), name: "r14-key-help-\(Int(zoom * 100))-\(mode)", size: .init(width: 320 * zoom, height: 300 * zoom), scheme: scheme, destination: destination)
      try await snapshot(Form { ExposureSettingsContent(model: camera) }.formStyle(.grouped).uiZoom(zoom), name: "r14-exposure-settings-\(Int(zoom * 100))-\(mode)", size: .init(width: 600, height: 800), scheme: scheme, destination: destination)
      try await snapshot(ReadingFirstUseTip(dismiss: {}).padding(Space.sm).uiZoom(zoom), name: "r14-inline-tip-\(Int(zoom * 100))-\(mode)", size: .init(width: 500, height: 100), scheme: scheme, destination: destination)
      try await snapshot(LibraryStartView(store: store, importing: .constant(false), practice: {}, camera: {}).uiZoom(zoom), name: "r14-start-\(Int(zoom * 100))-\(mode)", size: .init(width: 840, height: 900), scheme: scheme, destination: destination)
      try await snapshot(PresenterToolsMenu { Section("Text") { Button("Text size") {} }; Section("Camera") { Button("Camera") {} }; Section("Exposure") { Button("Exposure") {} }; Section("Microphone") { Button("Microphone") {} } }.uiZoom(zoom), name: "r14-tools-\(Int(zoom * 100))-\(mode)", size: .init(width: 240, height: 100), scheme: scheme, destination: destination)
    }
  }
}
