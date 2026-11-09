import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor extension AppearanceSnapshotTests {
  func testCameraAdjustRoundTwoSnapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let model = CameraModel(defaults: freshDefaults("CameraRoundTwo"))
    model.selectedUID = "one"
    model.setRotation(.threeQuarters)
    let devices = [CameraDevice(uid: "one", name: "Cam Link 4K", nickname: "Sony FX3"), CameraDevice(uid: "two", name: "MacBook Pro Camera")]
    let info = [
      "one": CameraSourceInfo(displayName: "Sony FX3", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 30, measuredFrameRate: 25),
      "two": CameraSourceInfo(displayName: "MacBook Pro Camera", connection: .builtIn, width: 1920, height: 1080, nominalFrameRate: 30)
    ]
    for zoom in [1.0, 2.0] {
      try await snapshot(ScrollView { CameraAdjustView(model: model, devicesOverride: devices, sourceInfoOverride: info, initiallyAdvanced: true).padding() }.uiZoom(zoom), name: "g3-camera-\(Int(zoom * 100))", size: .init(width: 500, height: 1200 * zoom), scheme: .dark, destination: URL(fileURLWithPath: output))
    }
  }
}
