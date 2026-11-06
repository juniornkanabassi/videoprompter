import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Regression reproductions only. Every default, library and movie is disposable.
@MainActor final class QAFindingsRound11Tests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA11-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("QA11")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    store.settings.mode = "Manual"
    store.settings.audioDeviceUID = nil
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    return (store, camera, recorder, defaults)
  }

  func testShootSetupRecallsSavedAutomaticScrollStartDelay() throws {
    let (store, camera, recorder, _) = fixture()
    store.session.startDelay = 5
    XCTAssertTrue(store.saveShootSetup(named: "Five-second cue", camera: camera, recorder: recorder))
    let setup = try XCTUnwrap(store.shootSetups.first)
    store.session.startDelay = 0
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: []))
    XCTAssertEqual(store.session.startDelay, 5, "A recalled shoot must retain its saved reading start cue")
  }

  func testRestorePreviousSetupRestoresStartDelayChangedAfterApply() throws {
    let (store, camera, recorder, _) = fixture()
    store.session.startDelay = 5
    var setup = ShootSetup(name: "Try this")
    setup.reading = store.settings
    setup.reading.fontSize = 72
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: []))
    store.session.startDelay = 0
    XCTAssertTrue(store.restorePreviousShootSetup(camera: camera, recorder: recorder))
    XCTAssertEqual(store.settings.fontSize, 44)
    XCTAssertEqual(store.session.startDelay, 5, "Restore must recover the reading cue as well as text size")
  }

  func testAppliedUnresolvedGuidesSurviveRelaunchBeforeCameraDiscovery() throws {
    let (store, camera, recorder, defaults) = fixture()
    var setup = ShootSetup(name: "Camera arrives later")
    setup.reading = store.settings
    setup.guides.thirds = true
    setup.guides.zebras = true
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: []))
    XCTAssertNil(camera.selectedUID)
    XCTAssertTrue(camera.guides.thirds)
    XCTAssertTrue(camera.guides.zebras)
    let reopened = CameraModel(defaults: defaults)
    reopened.recorder = recorder
    XCTAssertEqual(reopened.guides, setup.guides, "Unresolved applied settings must survive restarting the app")
    reopened.selectedUID = "first-camera-after-relaunch"
    XCTAssertEqual(reopened.guides, setup.guides, "Discovery after relaunch must transfer the saved pending guides")
  }

  func testPresenterOutputCheckUpdatesWhenDeliveredResolutionChanges() async throws {
    let (store, camera, recorder, _) = fixture()
    let shared = SharedCameraSession.shared
    let previousSize = shared.pictureSize
    defer { shared.pictureSize = previousSize }
    shared.pictureSize = CGSize(width: 1920, height: 1080)
    let record = try await store.createScript(title: "Output check", markdown: "Read these words.")
    store.session.present(record: record, settings: store.settings)
    camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true
    let presenter = PresenterView(store: store, session: store.session,
      draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
    let (window, host) = await LibraryAX.host(presenter)
    defer { LibraryAX.close(window) }
    let before = try XCTUnwrap(LibraryAX.named("Output check", in: host).first)
    XCTAssertTrue(LibraryAX.value(before, "accessibilityValue").contains("1920 × 1080"))
    shared.pictureSize = CGSize(width: 3840, height: 2160)
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertEqual(recorder.compactOutputConfirmation(camera: camera), "Landscape · 3840 × 2160")
    let after = try XCTUnwrap(LibraryAX.named("Output check", in: host).first)
    let value = LibraryAX.value(after, "accessibilityValue")
    print("QA11_OUTPUT_CHECK actual=\(value)")
    XCTAssertTrue(value.contains("3840 × 2160"),
                  "The pre-record check must follow the delivered feed instead of retaining old dimensions")
    XCTAssertFalse(value.contains("1920 × 1080"))
    // A different observed camera setting refreshes it: the missing dependency is pictureSize.
    camera.mirrored.toggle()
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let refreshed = try XCTUnwrap(LibraryAX.named("Output check", in: host).first)
    XCTAssertTrue(LibraryAX.value(refreshed, "accessibilityValue").contains("3840 × 2160"))
  }
}
