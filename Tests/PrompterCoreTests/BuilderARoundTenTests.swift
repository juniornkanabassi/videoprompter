import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderARoundTenTests: XCTestCase {
  private func fixture() async throws -> (AppStore, ScriptRecord, CameraModel, CameraRecorder) {
    let root = URL(fileURLWithPath: "/private/tmp/vp-r10-test-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("BuilderARoundTen")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Reading", markdown: String(repeating: "Read at your own pace. ", count: 100))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    return (store, record, camera, CameraRecorder(defaults: defaults))
  }

  func testReadingStatusAndNamedToolsSurviveCameraAndRecordingAtEveryZoom() async throws {
    let (store, record, camera, recorder) = try await fixture()
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      recorder.phase = .recording
      let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session,
        draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
      defer { LibraryAX.close(window) }
      for label in ["Start reading", "Stop recording", "Reading status", "Tools"] {
        XCTAssertFalse(LibraryAX.named(label, in: host).isEmpty, "\(label) at \(zoom)")
      }
      XCTAssertTrue(LibraryAX.named("Controls", in: host).isEmpty)
      let status = try XCTUnwrap(LibraryAX.named("Reading status", in: host).first)
      XCTAssertTrue(LibraryAX.value(status, "accessibilityValue").contains("Automatic scroll"))
    }
    recorder.phase = .idle
  }

  func testCameraMonitorKeepsPreviewMountedUnderRecovery() async throws {
    let (_, _, camera, recorder) = try await fixture()
    camera.recordingReadyOverride = nil; camera.authorization = .notDetermined
    let (window, host) = await LibraryAX.host(CameraView(model: camera, recorder: recorder, startsCamera: false))
    defer { LibraryAX.close(window) }
    func stages(_ view: NSView) -> [CameraStageView] {
      (view as? CameraStageView).map { [$0] } ?? view.subviews.flatMap(stages)
    }
    XCTAssertEqual(stages(host).count, 1, "Mounting the preview starts its shared session when access becomes available")
    XCTAssertTrue(camera.needsRecovery)
  }

  func testUnavailableCameraOffersLocalRecovery() async throws {
    let (_, _, camera, _) = try await fixture()
    for (authorization, action) in [(AVAuthorizationStatus.denied, "Open System Settings"), (.notDetermined, "Allow Camera Access"), (.authorized, "Choose camera")] {
      camera.authorization = authorization
      let (window, host) = await LibraryAX.host(CameraRecoveryView(model: camera, chooseCamera: {}))
      defer { LibraryAX.close(window) }
      XCTAssertFalse(LibraryAX.named(action, in: host).isEmpty)
    }
  }

  func testPopoverEntryFocusChoosesARealControl() async throws {
    let (window, host) = await LibraryAX.host(VStack {
      Text("Preview")
      Button("Smaller text") {}.initialPopoverFocus()
      Button("Larger text") {}
    }.popoverEntryFocus())
    defer { LibraryAX.close(window) }
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(350))
    let control = try XCTUnwrap(LibraryAX.named("Smaller text", in: host).first)
    XCTAssertTrue(LibraryAX.bool(control, "isAccessibilityFocused"))
  }

}

import AVFoundation

extension AppearanceSnapshotTests {
  func testRoundTenDelayedReadingAndRecovery() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = URL(fileURLWithPath: "/private/tmp/vp-r10-snapshot-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("RoundTenSnapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Read with confidence", markdown: "# Read with confidence\n\n" + String(repeating: "Read at your own pace. ", count: 100))
    store.settings.mode = "Manual"; store.settings.speed = 30
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults); camera.recordingReadyOverride = true; camera.displayMode = .prompterWithVideo
    let recorder = CameraRecorder(defaults: defaults)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != name { continue }
      for zoom in [1.0, 2.0] {
        store.uiZoom = zoom; recorder.phase = .recording
        store.session.play(captureAudio: false)
        try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), name: "r10-delayed-recording-\(Int(zoom * 100))-\(name)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output), settleDelay: .seconds(4))
        store.session.pause(); recorder.phase = .idle
      }
      camera.recordingReadyOverride = false; camera.authorization = .denied
      try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), name: "r10-camera-blocked-200-\(name)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
      camera.recordingReadyOverride = true
    }
  }
}
