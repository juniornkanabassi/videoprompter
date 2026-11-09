import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testAlphaSettingsF4Snapshots() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("F4Settings")))
    let camera = CameraModel(defaults: freshDefaults("F4Guides"))
    let scheme: ColorScheme = env["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let mode = scheme == .dark ? "dark" : "light"
    let destination = URL(fileURLWithPath: output)
    for zoom in [1.0, 2.0] {
      store.uiZoom = zoom
      for tab in SettingsTab.allCases {
        try await snapshot(AppSettingsView(store: store, selectedTab: tab), name: "f4-settings-\(tab.label)-\(Int(zoom * 100))-\(mode)", size: .init(width: 1600, height: 1200), scheme: scheme, destination: destination)
      }
      try await snapshot(ScrollView { AlphaGuideSections(model: camera).padding(24) }.uiZoom(zoom), name: "f4-guides-\(Int(zoom * 100))-\(mode)", size: .init(width: 1000, height: 1000), scheme: scheme, destination: destination)
    }
  }
}
