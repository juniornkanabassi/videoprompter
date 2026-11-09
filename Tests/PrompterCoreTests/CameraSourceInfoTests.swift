import XCTest
@testable import VideoPrompter

final class CameraSourceInfoTests: XCTestCase {
  func testConnectionKinds() {
    let cases: [(String, String, CameraSourceInfo.ConnectionKind)] = [
      ("builtInWideAngleCamera", "FaceTime HD Camera", .builtIn),
      ("external", "Cam Link 4K", .hdmiCapture),
      ("external", "UltraStudio Recorder 3G", .hdmiCapture),
      ("external", "MacBook Pro Camera", .builtIn),
      ("external", "Magewell USB Capture HDMI", .hdmiCapture),
      ("external", "ATEM Mini", .hdmiCapture),
      ("external", "USB Video", .hdmiCapture),
      ("external", "Sony FX3 webcam mode", .usbCamera),
      ("external", "LUMIX Webcam", .usbCamera),
      ("continuityCamera", "iPhone Continuity", .iPhone),
      ("external", "iPad link", .iPad),
    ]
    for (type, name, expected) in cases {
      XCTAssertEqual(CameraSourceInfo.ConnectionKind.classify(deviceType: type, transportType: 0, manufacturer: "", modelID: "", name: name), expected, name)
    }
  }
  func testFormatDescriptionRetainsFormatAndConnection() {
    let info = CameraSourceInfo(displayName: "Studio", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 25)
    XCTAssertEqual(info.formatDescription, "3840 × 2160 · 25p · HDMI capture")
    XCTAssertEqual(CameraSourceInfo(displayName: "Camera", connection: .usbCamera).formatDescription, "USB camera")
  }
  func testFrameRateFromTimestamps() {
    for fps in [25.0, 30000.0 / 1001, 50.0] {
      var rate = CameraFrameRate()
      for frame in 0..<100 { rate.add(Double(frame) / fps) }
      XCTAssertEqual(rate.value ?? 0, fps, accuracy: 0.001)
      rate.add(0)
      XCTAssertNil(rate.value)
    }
  }
  @MainActor func testNicknamePersistenceAndShotMigration() {
    let suite = "CameraSourceInfoTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = CameraModel(defaults: defaults)
    model.selectedUID = "camera-one"
    model.renameCamera("camera-one", to: "Studio")
    model.setRotation(.quarter)
    let restored = CameraModel(defaults: defaults)
    XCTAssertEqual(restored.nicknames["camera-one"], "Studio")
    XCTAssertEqual(restored.shotSummary, "Turned left for vertical")
    restored.setRotation(.threeQuarters)
    XCTAssertEqual(CameraModel(defaults: defaults).shotSummary, "Turned right for vertical")
    restored.setRotation(.half)
    XCTAssertEqual(CameraModel(defaults: defaults).shotSummary, "Upside down")
    restored.guides.automaticRotation = true
    XCTAssertEqual(CameraModel(defaults: defaults).shotSummary, "Automatic")
    restored.setRotation(.half)
    XCTAssertEqual(restored.shotSummary, "Upside down")
  }
}
