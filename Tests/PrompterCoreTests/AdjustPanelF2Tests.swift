import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testAdjustF2Snapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("AdjustF2Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    let devices = [CameraDevice(uid: "one", name: "Studio camera"), CameraDevice(uid: "two", name: "MacBook Pro camera")]
    camera.selectedUID = "one"
    for tab in AdjustTab.allCases {
      for zoom in [1.0, 2.0] {
        for size in [CGSize(width: 1600, height: 1000), CGSize(width: 1000, height: 700)] {
          let view = AdjustPanel(selection: .constant(tab), showsMic: .constant(true), camera: camera, store: store, startsMeter: false, zoom: zoom, width: 470 * zoom, devicesOverride: devices, recorder: recorder)
          try await snapshot(view, name: "f2-\(tab.rawValue.replacingOccurrences(of: " ", with: "-"))-\(Int(zoom * 100))-\(Int(size.width))", size: size, scheme: .dark, destination: URL(fileURLWithPath: output))
        }
      }
    }
  }
}
