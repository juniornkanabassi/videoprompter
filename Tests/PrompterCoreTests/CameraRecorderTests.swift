import Foundation
import XCTest
@testable import VidPrompt

@MainActor final class CameraRecorderTests: XCTestCase {
  func testPathsSpaceAndPreferencesWithoutOpeningDevices() throws {
    XCTAssertEqual(CameraRecorder.recordingsFolder(arguments: ["app", "--data-directory", "/tmp/disposable"]).path, "/tmp/disposable/Recordings")
    XCTAssertTrue(CameraRecorder.recordingsFolder(arguments: ["app"]).path.hasSuffix("/Movies/VidPrompt"))
    XCTAssertFalse(CameraRecorder.hasRecordingSpace(1_999_999_999)); XCTAssertTrue(CameraRecorder.hasRecordingSpace(2_000_000_000))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_000_000)
    let first = CameraRecorder.fileURL(in: root, date: date)
    try Data("preserve".utf8).write(to: first)
    let second = CameraRecorder.fileURL(in: root, date: date)
    XCTAssertTrue(first.lastPathComponent.hasPrefix("VidPrompt "))
    XCTAssertNotEqual(first, second); XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.mov"))
    XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "preserve")
    let suite = "RecorderTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let isolated = AppStore.preferences(arguments: ["app", "--data-directory", root.path])

    let camera = CameraModel(defaults: isolated)
    camera.mirrored = true
    XCTAssertTrue(CameraModel(defaults: AppStore.preferences(arguments: ["app", "--data-directory", root.path])).mirrored)
    let other = root.appendingPathComponent("other")
    XCTAssertFalse(CameraModel(defaults: AppStore.preferences(arguments: ["app", "--data-directory", other.path])).mirrored)
    let recorder = CameraRecorder(defaults: defaults)
    recorder.preset = .edit; recorder.floatAudio = true; recorder.microphoneUID = "specific-device"
    let reopened = CameraRecorder(defaults: defaults)
    XCTAssertEqual(reopened.preset, .edit); XCTAssertTrue(reopened.floatAudio); XCTAssertEqual(reopened.microphoneUID, "specific-device")
  }
}
