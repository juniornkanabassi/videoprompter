import AppKit
import PrompterCore
import XCTest
@testable import VideoPrompter

/// Disposable data and invisible hosts only. No real device capture or key events.
@MainActor final class QAFindingsRound8Tests: XCTestCase {
  private func fixture(_ defaults: UserDefaults? = nil) -> (AppStore, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA8-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = defaults ?? freshDefaults("QA8")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), defaults)
  }

  func testSavedZoomAlwaysHasAnAvailablePickerChoice() async {
    let defaults = freshDefaults("QA8Zoom")
    defaults.set(1.3, forKey: "uiZoom")
    let (store, _) = fixture(defaults)
    XCTAssertTrue(AppStore.uiZoomSteps.contains(store.uiZoom), "Loaded zoom \(store.uiZoom) has no Settings picker item and cannot be selected through the CLI")
    await store.flushSettings()
    XCTAssertTrue(AppStore.uiZoomSteps.contains(defaults.double(forKey: "uiZoom")))
  }

  func testFolderRenameKeepsMemoryAndDiskNamesIdentical() async throws {
    let (store, defaults) = fixture()
    await store.waitForInitialLoad()
    let folder = try await store.createLibraryFolder(named: "Original")
    let camera = CameraModel(defaults: defaults)
    let actions = ControlActions(store: store, camera: camera, recorder: CameraRecorder(defaults: defaults))
    // This is the GUI rename path. The CLI trims before calling it.
    try await store.renameLibraryFolder(folder.id, name: "  Renamed  ")
    XCTAssertEqual(store.folders.first { $0.id == folder.id }?.name, "Renamed")
    let library = try XCTUnwrap(store.library)
    let disk = await library.listFolders()
    XCTAssertEqual(store.folders.first { $0.id == folder.id }?.name, disk.first { $0.id == folder.id }?.name)
    let moved = await actions.handle("script_create", ["title": "Keep", "text": "These words survive.", "folder": "Renamed"])
    XCTAssertEqual(moved.body["ok"] as? Bool, true, "The canonical renamed folder must resolve without restarting: \(moved.body)")
  }

  func testOneMalformedSavedPresetDoesNotEraseValidNeighbours() async throws {
    let defaults = freshDefaults("QA8Presets")
    var first = PrompterSettings(); first.name = "Studio"; first.fontSize = 64
    var last = PrompterSettings(); last.name = "Travel"; last.fontSize = 28
    let encoder = JSONEncoder()
    let objects: [Any] = [try JSONSerialization.jsonObject(with: encoder.encode(first)), NSNull(),
      try JSONSerialization.jsonObject(with: encoder.encode(last))]
    let original = try JSONSerialization.data(withJSONObject: objects)
    defaults.set(original, forKey: "presets")
    let (store, _) = fixture(defaults)
    await store.waitForInitialLoad()
    XCTAssertEqual(store.presets.map(\.name), ["Studio", "Travel"], "One malformed entry must not discard unrelated presets")
    await store.flushSettings()
    let saved = try XCTUnwrap(defaults.data(forKey: "presets"))
    let reopened = try JSONDecoder().decode([PrompterSettings].self, from: saved)
    XCTAssertEqual(reopened.map(\.name), ["Studio", "Travel"], "Startup must not overwrite the valid saved neighbours with an empty list")
  }

}
