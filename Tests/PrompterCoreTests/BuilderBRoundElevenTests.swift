import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundElevenTests: XCTestCase {
  func testDirectScriptShowsGuidanceAndDismissalSurvivesScriptChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBEleven")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let first = try await store.createScript(title: "Pasted words", markdown: "These are my copied words.")
    let second = try await store.createScript(title: "Next script", markdown: "Another script.")
    let camera = CameraModel(defaults: defaults)
    for zoom in [1.0, 1.5, 2.0] {
      store.selectedID = first.id
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1440, height: 1000))
      defer { LibraryAX.close(window) }
      XCTAssertFalse(LibraryAX.named(ReadingFirstUseTip.explanation, in: host).isEmpty)
      let dismiss = try XCTUnwrap(LibraryAX.named("Got it, hide reading tip", in: host).first)
      let frame = try XCTUnwrap(dismiss.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "Tip must be readable before Present at \(zoom)")
      XCTAssertTrue(LibraryAX.bool(dismiss, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(80))
      XCTAssertTrue(LibraryAX.named(ReadingFirstUseTip.explanation, in: host).isEmpty)
      store.selectedID = second.id
      try await Task.sleep(for: .milliseconds(80))
      XCTAssertTrue(LibraryAX.named(ReadingFirstUseTip.explanation, in: host).isEmpty)
      XCTAssertEqual(store.scripts.first { $0.id == first.id }?.markdown, first.markdown)
    }
  }

  func testCameraRowsNeverClaimPreviewFromHighlightAlone() {
    for authorization in [AVAuthorizationStatus.notDetermined, .denied, .restricted, .authorized] {
      for selected in [true, false] {
        for highlighted in [true, false] {
          let value = CameraPickerList.rowStatus(selected: selected, highlighted: highlighted, authorization: authorization)
          XCTAssertFalse(value.contains("Previewing"))
          XCTAssertEqual(value.contains("Selected"), selected)
          XCTAssertEqual(value.contains("Highlighted"), highlighted)
          if authorization != .authorized { XCTAssertTrue(value.contains(CameraPickerList.recovery(for: authorization).title)) }
        }
      }
    }
  }

  func testCameraPermissionRecoveryRemainsAvailableWithDiscoveredDevices() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBElevenPicker"))
    let devices = [CameraDevice(uid: "fixture", name: "Discovered camera")]
    for authorization in [AVAuthorizationStatus.notDetermined, .denied, .restricted] {
      camera.authorization = authorization
      for zoom in [1.0, 1.5, 2.0] {
        let (window, host) = await LibraryAX.host(CameraPickerList(model: camera, zoom: zoom, startsPreview: false, devicesOverride: devices, close: {}).uiZoom(zoom), size: .init(width: 1100, height: 900))
        defer { LibraryAX.close(window) }
        XCTAssertFalse(LibraryAX.named("Discovered camera", in: host).isEmpty)
        let action = authorization == .notDetermined ? "Allow Camera Access" : "Open Camera Privacy Settings"
        let recovery = try XCTUnwrap(LibraryAX.named(action, in: host).first)
        let frame = try XCTUnwrap(recovery.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "Recovery must remain in view at \(zoom)")
        XCTAssertFalse(LibraryAX.named("Refresh Cameras", in: host).isEmpty)
        XCTAssertFalse(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityValue").contains("Previewing") })
      }
    }
  }

  func testExposureGuidanceDoesNotRepeatSwitchPurposeAndKeepsQualifications() async throws {
    let camera = CameraModel(defaults: freshDefaults("BuilderBElevenExposure"))
    for purpose in CameraGuides.ZebraPurpose.allCases {
      camera.guides.useZebraPreset(purpose)
      let (window, host) = await LibraryAX.host(ExposureGuidance(zebras: true, guides: camera.guides, falseColour: true))
      defer { LibraryAX.close(window) }
      let values = LibraryAX.elements(host).map { LibraryAX.value($0, "accessibilityValue") }
      XCTAssertFalse(values.contains(ExposureGuidance.zebraPurpose(camera.guides)))
      XCTAssertFalse(values.contains(ExposureGuidance.colourPurpose))
      XCTAssertTrue(values.contains(ExposureGuidance.zebraLookFor(camera.guides)))
      XCTAssertTrue(values.contains(ExposureGuidance.zebraAction(camera.guides)))
    }
    camera.guides.zebraLevel = 95
    camera.guides.zebraRange = 5
    XCTAssertTrue(ExposureGuidance.zebraAction(camera.guides).contains("Do not brighten a face"))
  }
}

extension AppearanceSnapshotTests {
  func testBuilderBRoundElevenFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let camera = CameraModel(defaults: freshDefaults("BuilderBElevenSnapshots"))
    for zoom in [1.0, 1.5, 2.0] {
      try await snapshot(ReadingFirstUseTip(dismiss: {}).padding(Space.margin).uiZoom(zoom), name: "r11-reading-tip-\(Int(zoom * 100))-\(mode)", size: .init(width: 800, height: 320 * zoom), scheme: scheme, destination: destination)
      for authorization in [AVAuthorizationStatus.notDetermined, .denied] {
        camera.authorization = authorization
        try await snapshot(CameraPickerList(model: camera, zoom: zoom, startsPreview: false, devicesOverride: [CameraDevice(uid: "fixture", name: "Discovered camera")], close: {}).uiZoom(zoom), name: "r11-camera-access-\(authorization.rawValue)-\(Int(zoom * 100))-\(mode)", size: .init(width: (zoom < 1.5 ? 520 : 280) * zoom, height: 350 * zoom), scheme: scheme, destination: destination)
      }
    }
  }
}
