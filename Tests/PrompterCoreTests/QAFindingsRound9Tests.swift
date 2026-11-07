import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Regression reproductions only. Disposable defaults, invisible hosts, no device capture.
@MainActor final class QAFindingsRound9Tests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA9-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("QA9")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    store.settings.audioDeviceUID = nil
    return (store, camera, recorder)
  }

  func testSavedSetupAcceptsConnectedCameraBeforePreviewHasPopulatedDeviceCache() throws {
    let (store, camera, recorder) = fixture()
    // Discovery lists devices only; it never opens a camera or requests permission.
    guard let connected = CameraModel.discovered().first else { throw XCTSkip("No connected camera to list") }
    camera.selectedUID = connected.uid
    store.settings.fontSize = 68
    store.saveShootSetup(named: "Connected camera", camera: camera, recorder: recorder)
    let setup = try XCTUnwrap(store.shootSetups.first)
    store.settings.fontSize = 30
    XCTAssertTrue(camera.devices.isEmpty, "A newly constructed camera has not started its preview")
    XCTAssertTrue(CameraModel.discovered().contains { $0.uid == connected.uid })
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder),
                  "A connected camera is available even before CameraModel.start/refresh; \(store.errorMessage ?? "")")
    XCTAssertEqual(store.settings.fontSize, 68)
    camera.refresh()
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder),
                  "Refreshing the device list alone makes the same setup applicable")
  }

  func testMissingCameraFailureIsVisibleInPresenterSetupPopover() async throws {
    let (store, camera, recorder) = fixture()
    store.saveShootSetup(named: "Disconnected setup", camera: camera, recorder: recorder)
    store.shootSetups[0].cameraUID = "QA9-unplugged-camera"
    let (window, host) = await LibraryAX.host(ShootSetupSection(store: store, camera: camera, recorder: recorder))
    defer { LibraryAX.close(window) }
    let apply = try XCTUnwrap(LibraryAX.named("Apply Disconnected setup", in: host).first)
    XCTAssertTrue(LibraryAX.bool(apply, "accessibilityPerformPress"))
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let error = try XCTUnwrap(store.errorMessage)
    XCTAssertTrue(error.contains("unavailable"))
    XCTAssertFalse(LibraryAX.named(error, in: host).isEmpty,
                   "The presenter-only setup popover must expose the rejection; its library window may be closed")
  }
}
