import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class QA11PersistenceTests: XCTestCase {
  private func makeStore(_ defaults: UserDefaults) -> AppStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA11Persistence-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    store.settings.mode = "Manual"
    store.settings.audioDeviceUID = nil
    return store
  }

  func testPendingGuidesTransferOnceWithoutChangingOtherSavedCameras() throws {
    let defaults = freshDefaults("QA11Pending")
    let saved = CameraGuideStore(defaults: defaults)
    var other = CameraGuides()
    other.axes = true; other.rotation = .half
    saved.set(other, for: "other")
    var pending = CameraGuides()
    pending.thirds = true; pending.zebras = true; pending.falseColour = true
    pending.rotation = .quarter; pending.marker = .init(width: 9, height: 16)
    pending.colorHex = "#FF0000"; pending.opacity = 0.6
    pending.useZebraPreset(.faceReference)
    CameraModel(defaults: defaults).guides = pending

    let reopened = CameraModel(defaults: defaults)
    XCTAssertEqual(reopened.guides, pending)
    reopened.selectedUID = "first"
    XCTAssertEqual(reopened.guides, pending)
    XCTAssertNil(saved.savedGuides(for: nil), "Consume the pending configuration only after saving it for the camera")
    let afterTransfer = CameraModel(defaults: defaults)
    XCTAssertEqual(afterTransfer.guides, pending)
    afterTransfer.selectedUID = "other"
    XCTAssertEqual(afterTransfer.guides, other)
    afterTransfer.selectedUID = "new"
    XCTAssertEqual(afterTransfer.guides, CameraGuides())
    afterTransfer.selectedUID = "first"
    XCTAssertEqual(afterTransfer.guides, pending)
  }

  func testExplicitDefaultGuidesSurviveRelaunchAndReplaceTheFirstCamerasGuides() {
    let defaults = freshDefaults("QA11DefaultGuides")
    let saved = CameraGuideStore(defaults: defaults)
    var previous = CameraGuides(); previous.thirds = true
    saved.set(previous, for: "first")
    // An explicit all-off choice still matters even when it equals the model's defaults.
    CameraModel(defaults: defaults).guides = CameraGuides()
    let reopened = CameraModel(defaults: defaults)
    reopened.selectedUID = "first"
    XCTAssertEqual(reopened.guides, CameraGuides())
    XCTAssertEqual(CameraModel(defaults: defaults).guides, CameraGuides())
  }

  func testNoPendingChoiceKeepsExistingPerCameraGuides() {
    let defaults = freshDefaults("QA11NoPending")
    let saved = CameraGuideStore(defaults: defaults)
    var previous = CameraGuides(); previous.bullseye = true
    saved.set(previous, for: "first")
    let camera = CameraModel(defaults: defaults)
    _ = CameraModel(defaults: defaults)
    XCTAssertNil(saved.savedGuides(for: nil))
    camera.selectedUID = "first"
    XCTAssertEqual(camera.guides, previous)
  }

  func testSavedCountdownSurvivesEncodingReloadAndActuallyStartsACountdown() async throws {
    let defaults = freshDefaults("QA11SavedCue")
    let original = makeStore(defaults)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    for delay in [0, 3, 5] {
      original.session.startDelay = delay
      XCTAssertTrue(original.saveShootSetup(named: "Cue \(delay)", camera: camera, recorder: recorder))
    }
    let reopened = makeStore(defaults)
    XCTAssertEqual(reopened.shootSetups.map(\.startDelay), [0, 3, 5])
    XCTAssertEqual(reopened.shootSetups.map(\.id), original.shootSetups.map(\.id))
    let record = try await reopened.createScript(title: "Cue", markdown: "Read these words after the cue.")
    reopened.session.present(record: record, settings: reopened.settings)
    reopened.session.startDelay = 0
    XCTAssertTrue(reopened.applyShootSetup(reopened.shootSetups[2], camera: camera, recorder: recorder, microphones: []))
    reopened.session.startReading()
    XCTAssertEqual(reopened.session.countdownRemaining, 5)
    XCTAssertFalse(reopened.session.isActivelyRunning)
    reopened.session.pause()
    XCTAssertEqual(SessionStore(defaults: defaults).startDelay, 5)
  }

  func testLegacyAndMalformedCueKeepSavedSetupsAndCurrentDelay() throws {
    let defaults = freshDefaults("QA11LegacyCue")
    var legacy = ShootSetup(name: "Legacy")
    legacy.reading.mode = "Manual"; legacy.reading.audioDeviceUID = nil
    legacy.reading.fontSize = 64; legacy.guides.thirds = true
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    object.removeValue(forKey: "startDelay")
    var malformed = object
    malformed["name"] = "Malformed cue"
    malformed["id"] = UUID().uuidString
    malformed["startDelay"] = "obsolete"
    var invalid = malformed
    invalid["name"] = "Invalid cue"
    invalid["id"] = UUID().uuidString
    invalid["startDelay"] = -5
    defaults.set(try JSONSerialization.data(withJSONObject: [object, malformed, invalid]), forKey: "shootSetups")
    let loaded = makeStore(defaults)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    XCTAssertEqual(loaded.shootSetups.map(\.name), ["Legacy", "Malformed cue", "Invalid cue"])
    XCTAssertEqual(loaded.shootSetups.first?.id, legacy.id)
    loaded.session.startDelay = 5
    for setup in loaded.shootSetups {
      XCTAssertNil(setup.startDelay)
      XCTAssertTrue(loaded.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: []))
      XCTAssertEqual(loaded.session.startDelay, 5)
      XCTAssertEqual(loaded.settings.fontSize, 64)
      XCTAssertTrue(camera.guides.thirds)
    }
    let reloaded = makeStore(defaults)
    XCTAssertEqual(reloaded.shootSetups.map(\.id), loaded.shootSetups.map(\.id))
    XCTAssertTrue(reloaded.shootSetups.allSatisfy { $0.guides.thirds && $0.reading.fontSize == 64 })
  }

  func testFailedApplyDoesNotChangeCueOrPreviousRecovery() {
    let defaults = freshDefaults("QA11FailedApplyCue"), store = makeStore(defaults)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    store.session.startDelay = 5
    var setup = ShootSetup(name: "Three seconds")
    setup.reading = store.settings; setup.startDelay = 3
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: []))
    var missing = setup; missing.cameraUID = "missing"; missing.startDelay = 0
    XCTAssertFalse(store.applyShootSetup(missing, camera: camera, recorder: recorder, microphones: []))
    XCTAssertEqual(store.session.startDelay, 3)
    XCTAssertTrue(store.restorePreviousShootSetup(camera: camera, recorder: recorder))
    XCTAssertEqual(store.session.startDelay, 5)
  }

  func testOutputCheckFollowsPortraitAndMissingSignal() async throws {
    let defaults = freshDefaults("QA11Signal"), store = makeStore(defaults)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    let shared = SharedCameraSession.shared, previousSize = SharedCameraSession.shared.pictureSize
    defer { shared.pictureSize = previousSize }
    camera.displayMode = .videoOnly; camera.recordingReadyOverride = true
    shared.pictureSize = CGSize(width: 1920, height: 1080)
    let presenter = PresenterView(store: store, session: store.session, draft: PresenterDraft(),
      hasScript: false, camera: camera, startsCamera: false, recorder: recorder)
    let (window, host) = await LibraryAX.host(presenter)
    defer { LibraryAX.close(window) }
    for (size, expected) in [
      (CGSize(width: 2160, height: 3840), "Portrait · 2160 × 3840"),
      (nil, "Orientation unknown · resolution unknown"),
      (CGSize(width: 1920, height: 1080), "Landscape · 1920 × 1080"),
    ] as [(CGSize?, String)] {
      shared.pictureSize = size
      for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      let output = try XCTUnwrap(LibraryAX.named("Output check", in: host).first)
      XCTAssertTrue(LibraryAX.value(output, "accessibilityValue").contains(expected))
    }
  }
}

extension AppearanceSnapshotTests {
  func testQA11OutputResolutions() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA11Snapshot-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("QA11Snapshot")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    store.settings.mode = "Manual"; store.settings.audioDeviceUID = nil
    let record = try await store.createScript(title: "Check the output", markdown: "Read at your own pace. Your camera settings stay with your shoot.")
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    let shared = SharedCameraSession.shared, previousSize = SharedCameraSession.shared.pictureSize
    defer { shared.pictureSize = previousSize }
    let scheme: ColorScheme = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let appearance = scheme == .dark ? "dark" : "light"
    for (name, size) in [
      ("landscape", CGSize(width: 3840, height: 2160)),
      ("portrait", CGSize(width: 2160, height: 3840)),
      ("unknown", nil),
    ] as [(String, CGSize?)] {
      shared.pictureSize = size
      try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record),
        camera: camera, startsCamera: false, recorder: recorder), name: "qa11-output-\(name)-\(appearance)",
        size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output),
        settleDelay: .seconds(1))
    }
  }
}
