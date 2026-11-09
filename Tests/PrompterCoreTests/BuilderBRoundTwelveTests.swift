import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderBRoundTwelveTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBTwelve")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults))
  }

  func testPopulatedFoldersLeaveMostOfTheSidebarForScriptsAndCanCollapse() async throws {
    let (store, camera) = fixture()
    for index in 1...8 { _ = try await store.createLibraryFolder(named: "Production folder \(index)") }
    for index in 1...8 { _ = try await store.createScript(title: "Episode \(index) ready to read", markdown: "Read these words.") }
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(LibraryView(store: store, camera: camera), size: .init(width: 1440, height: 900))
      defer { LibraryAX.close(window) }
      let folders = try XCTUnwrap(LibraryAX.named("Script folders", in: host).first)
      let frame = try XCTUnwrap(folders.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      XCTAssertLessThanOrEqual(frame.height, 272, "Folders must not grow beyond 30% after zoom")
      let scripts = try XCTUnwrap(LibraryAX.named("Scripts", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXOutline" })
      let scroll = try XCTUnwrap((scripts as? NSView)?.enclosingScrollView)
      XCTAssertGreaterThan(scroll.frame.height * zoom, 450)
      let disclosure = try XCTUnwrap(LibraryAX.named("Folders", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
      XCTAssertEqual(LibraryAX.value(disclosure, "accessibilityValue"), "Expanded")
      XCTAssertTrue(LibraryAX.bool(disclosure, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(60))
      XCTAssertTrue(LibraryAX.named("Script folders", in: host).isEmpty)
      XCTAssertFalse(LibraryAX.named("All Scripts", in: host).isEmpty, "The selected scope stays visible")
      let collapsed = try XCTUnwrap(LibraryAX.named("Folders", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXButton" })
      XCTAssertEqual(LibraryAX.value(collapsed, "accessibilityValue"), "Collapsed")
      XCTAssertTrue(LibraryAX.bool(collapsed, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(60))
      XCTAssertFalse(LibraryAX.named("Script folders", in: host).isEmpty)
    }
  }

  func testEmbeddedPickerHasOnlyTheHostRecoveryAndStandaloneRetainsItsOwn() async throws {
    let (_, camera) = fixture()
    let devices = [CameraDevice(uid: "fixture", name: "Camera with a long complete device name")]
    for auth in [AVAuthorizationStatus.notDetermined, .denied, .restricted] {
      camera.authorization = auth
      for zoom in [1.0, 1.5, 2.0] {
        let (window, host) = await LibraryAX.host(VStack {
          CameraRecoveryView(model: camera, chooseCamera: {})
          CameraPickerList(model: camera, zoom: zoom, startsPreview: false, showsRecovery: false, devicesOverride: devices, close: {})
        }.uiZoom(zoom), size: .init(width: 1100, height: 1100))
        defer { LibraryAX.close(window) }
        let name = auth == .notDetermined ? "Allow Camera Access" : "Allow Camera in System Settings"
        XCTAssertEqual(LibraryAX.named(name, in: host).filter { LibraryAX.value($0, "accessibilityRole") == "AXButton" }.count, 1)
        XCTAssertTrue(LibraryAX.named(CameraPickerList.recovery(for: auth).message, in: host).isEmpty)
        XCTAssertFalse(LibraryAX.named(devices[0].name, in: host).isEmpty)
        let (standalone, standaloneHost) = await LibraryAX.host(CameraPickerList(model: camera, zoom: zoom, startsPreview: false, devicesOverride: devices, close: {}).uiZoom(zoom), size: .init(width: 1100, height: 900))
        defer { LibraryAX.close(standalone) }
        XCTAssertFalse(LibraryAX.named(CameraPickerList.recovery(for: auth).title, in: standaloneHost).isEmpty)
        XCTAssertTrue(LibraryAX.named("Refresh Cameras", in: standaloneHost).isEmpty)
      }
    }
  }

  func testMonitorKeyStartsCompactAndDisclosesFullTeachingAtEveryZoom() async throws {
    let (_, camera) = fixture()
    camera.guides.useZebraPreset(.faceReference)
    camera.guides.zebras = true
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      let (window, host) = await LibraryAX.host(ExposureLegend(model: camera, zoom: zoom), size: .init(width: 520, height: 900))
      defer { LibraryAX.close(window) }
      XCTAssertTrue(LibraryAX.named("Received picture (%)", in: host).isEmpty)
      XCTAssertTrue(LibraryAX.named(ExposureLegend.measurement(level: camera.guides.zebraLevel, range: camera.guides.zebraRange), in: host).isEmpty)
      XCTAssertTrue(LibraryAX.named(ExposureGuidance.zebraLookFor(camera.guides), in: host).isEmpty)
      for band in CameraExposure.bands {
        _ = try XCTUnwrap(LibraryAX.named("\(band.name). \(band.name)", in: host).first)
      }
      window.makeKeyAndOrderFront(nil)
      let help = try XCTUnwrap(LibraryAX.named("Key", in: host).first)
      XCTAssertTrue(LibraryAX.bool(help, "accessibilityPerformPress"))
      try await Task.sleep(for: .milliseconds(150))
      let panel = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.contentView.map {
        !LibraryAX.named(ExposureGuidance.zebraLookFor(camera.guides), in: $0).isEmpty
      } == true })
      XCTAssertFalse(LibraryAX.named("False colour", in: panel.contentView!).isEmpty)
      // Close the owned popover through its opener, restoring focus there.
      panel.close()
    }
  }
}

extension AppearanceSnapshotTests {
  func testBuilderBRoundTwelveFixtures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Run checks/check-snapshots.sh") }
    let destination = URL(fileURLWithPath: output)
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderBTwelveSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    for index in 1...8 { _ = try await store.createLibraryFolder(named: "Production folder \(index)") }
    for index in 1...10 { _ = try await store.createScript(title: "Episode \(index) with a complete long script title for reading", markdown: "Keep scripts visible while navigating folders.") }
    camera.guides.useZebraPreset(.faceReference)
    camera.guides.zebras = true
    camera.guides.falseColour = true
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      try await snapshot(LibraryView(store: store, camera: camera), name: "r12-library-populated-\(Int(zoom * 100))-\(mode)", size: .init(width: 1440, height: 900), scheme: scheme, destination: destination)
      try await snapshot(ExposureLegend(model: camera, zoom: zoom), name: "r12-monitor-key-\(Int(zoom * 100))-\(mode)", size: .init(width: 520, height: 600), scheme: scheme, destination: destination)
      camera.authorization = .notDetermined
      try await snapshot(VStack {
        CameraRecoveryView(model: camera, chooseCamera: {})
        CameraPickerList(model: camera, zoom: zoom, startsPreview: false, showsRecovery: false, devicesOverride: [], close: {})
      }.uiZoom(zoom), name: "r12-camera-recovery-\(Int(zoom * 100))-\(mode)", size: .init(width: 600, height: 900), scheme: scheme, destination: destination)
    }
  }
}
