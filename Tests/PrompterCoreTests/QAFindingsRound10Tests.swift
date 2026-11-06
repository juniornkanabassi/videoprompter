import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// QA reproductions. All libraries/defaults are disposable; no device capture or visible windows.
@MainActor final class QAFindingsRound10Tests: XCTestCase {
  private func fixture(defaults: UserDefaults? = nil) -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA10-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = defaults ?? freshDefaults("QA10")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    store.settings.mode = "Manual"
    store.settings.audioDeviceUID = nil
    return (store, camera, recorder)
  }

  func testRecoveredDuplicateSetupIDsCannotDeleteAnUnrelatedSetup() throws {
    let defaults = freshDefaults("QA10DuplicateIDs")
    var first = ShootSetup(name: "Studio")
    first.reading.fontSize = 72
    var second = ShootSetup(name: "Desk")
    second.id = first.id
    second.reading.fontSize = 28
    defaults.set(try JSONEncoder().encode([first, second]), forKey: "shootSetups")
    let (store, _, _) = fixture(defaults: defaults)
    XCTAssertEqual(store.shootSetups.map(\.name), ["Studio", "Desk"])
    XCTAssertEqual(Set(store.shootSetups.map(\.id)).count, 2,
                   "Recovered entries need distinct identities before ForEach and destructive actions use them")
    let studio = try XCTUnwrap(store.shootSetups.first { $0.name == "Studio" })
    store.deleteShootSetup(studio.id)
    XCTAssertEqual(store.shootSetups.map(\.name), ["Desk"],
                   "Deleting Studio must not permanently delete Desk too")
    let (reloaded, _, _) = fixture(defaults: defaults)
    XCTAssertEqual(reloaded.shootSetups.map(\.name), ["Desk"])
  }

  func testSetupSavedBeforeCameraSelectionKeepsGuidesAfterDiscovery() throws {
    let (store, camera, recorder) = fixture()
    guard CameraModel.discovered().contains(where: { $0.isPhysical && !$0.name.localizedCaseInsensitiveContains("virtual") }) else {
      throw XCTSkip("No physical camera available for inventory-only discovery")
    }
    camera.guides.thirds = true
    camera.guides.zebras = true
    XCTAssertTrue(store.saveShootSetup(named: "Before choosing camera", camera: camera, recorder: recorder))
    let setup = try XCTUnwrap(store.shootSetups.first)
    XCTAssertNil(setup.cameraUID)
    camera.guides = CameraGuides()
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: []))
    XCTAssertTrue(camera.guides.thirds)
    XCTAssertTrue(camera.guides.zebras)
    // This is the inventory-only phase of CameraModel.start, without opening a device.
    camera.refresh()
    XCTAssertNotNil(camera.selectedUID)
    XCTAssertTrue(camera.guides.thirds, "Resolving the default camera must not undo the setup just applied")
    XCTAssertTrue(camera.guides.zebras)
  }

  func testChooseCameraListsConnectedDevicesBeforePreviewHasStarted() async throws {
    let (_, camera, _) = fixture()
    guard let connected = CameraModel.discovered().first else { throw XCTSkip("No connected camera to list") }
    camera.authorization = .authorized
    XCTAssertTrue(camera.devices.isEmpty)
    let (window, host) = await LibraryAX.host(CameraPickerList(model: camera, startsPreview: false, close: {}))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named(connected.displayName, in: host).isEmpty,
                   "Choose camera must list connected devices, not report no camera until Refresh is pressed")
    camera.refreshDevices()
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(LibraryAX.named(connected.displayName, in: host).isEmpty,
                   "The same picker displays the connected camera after inventory alone is refreshed")
  }
}
