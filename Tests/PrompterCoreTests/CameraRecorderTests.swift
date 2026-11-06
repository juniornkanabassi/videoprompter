import Foundation
import XCTest
@testable import VideoPrompter

@MainActor final class CameraRecorderTests: XCTestCase {
  func testUnknownRecordingFailuresGiveAnActionWithoutWriterInternals() {
    let message = CameraRecorder.recoveryMessage(for: NSError(domain: "MovieWriter", code: 20,
      userInfo: [NSLocalizedDescriptionKey: "writer failed with internal status -11800"]))
    XCTAssertTrue(message.contains("try recording again"))
    XCTAssertFalse(message.contains("writer"))
    XCTAssertFalse(message.contains("11800"))
  }

  func testRecordingTransformMatchesPreviewRotationAndHorizontalMirror() {
    for rotation in CameraRotation.allCases {
      let point = CGPoint(x: 3, y: 7)
      let rotated = point.applying(CGAffineTransform(rotationAngle: rotation.radians))
      let plain = point.applying(RecordingSink.recordingTransform(rotation: rotation, mirrored: false))
      let mirrored = point.applying(RecordingSink.recordingTransform(rotation: rotation, mirrored: true))
      XCTAssertEqual(plain.x, rotated.x, accuracy: 0.001)
      XCTAssertEqual(plain.y, rotated.y, accuracy: 0.001)
      XCTAssertEqual(mirrored.x, -rotated.x, accuracy: 0.001)
      XCTAssertEqual(mirrored.y, rotated.y, accuracy: 0.001)
    }
  }
  func testMissingFramesTimeOutFromAttachmentOrLastWrittenFrame() {
    let start = Date(timeIntervalSince1970: 100)
    XCTAssertFalse(CameraRecorder.framesTimedOut(attachedAt: start, lastFrameAt: nil, now: start.addingTimeInterval(4)))
    XCTAssertTrue(CameraRecorder.framesTimedOut(attachedAt: start, lastFrameAt: nil, now: start.addingTimeInterval(6)))
    XCTAssertFalse(CameraRecorder.framesTimedOut(attachedAt: start, lastFrameAt: start.addingTimeInterval(10), now: start.addingTimeInterval(14)))
    XCTAssertTrue(CameraRecorder.framesTimedOut(attachedAt: start, lastFrameAt: start.addingTimeInterval(10), now: start.addingTimeInterval(16)))
  }
  func testIdleRecorderNeverClaimsWrittenFrames() {
    let suite = "RecorderTests.\(UUID())"
    let recorder = CameraRecorder(defaults: TestDefaults.suite(named: suite)!)
    defer { TestDefaults.remove(suite) }
    XCTAssertNil(recorder.startedAt)
    XCTAssertFalse(recorder.isRecording)
    XCTAssertEqual(recorder.recordedDuration, 0)
    XCTAssertNil(recorder.lastFile)
  }
  func testPathsSpaceAndPreferencesWithoutOpeningDevices() throws {
    XCTAssertEqual(CameraRecorder.recordingsFolder(arguments: ["app", "--data-directory", "/tmp/disposable"]).path, "/tmp/disposable/Recordings")
    let movies = FileManager.default.temporaryDirectory.appendingPathComponent("videoprompter-movies-\(UUID().uuidString)", isDirectory: true)
    XCTAssertEqual(CameraRecorder.recordingsFolder(arguments: ["app"], movies: movies).path, movies.appendingPathComponent("Video Prompter").path)
    XCTAssertFalse(CameraRecorder.hasRecordingSpace(1_999_999_999)); XCTAssertTrue(CameraRecorder.hasRecordingSpace(2_000_000_000))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_000_000)
    let first = CameraRecorder.fileURL(in: root, date: date)
    try Data("preserve".utf8).write(to: first)
    let second = CameraRecorder.fileURL(in: root, date: date)
    XCTAssertTrue(first.lastPathComponent.hasPrefix("Video Prompter "))
    XCTAssertNotEqual(first, second); XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.mov"))
    XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "preserve")
    let suite = "RecorderTests.\(UUID())"; let defaults = TestDefaults.suite(named: suite)!
    defer { TestDefaults.remove(suite) }
    // AppStore.preferences writes the derived suites of both data directories.
    removeDerivedDefaultsAtTeardown(dataDirectory: root)
    removeDerivedDefaultsAtTeardown(dataDirectory: root.appendingPathComponent("other"))
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
