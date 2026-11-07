import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderARoundFourteenTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A14")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults), CameraRecorder(defaults: defaults), defaults)
  }
  func testRetakeTransportIsOneRowAndStaysInsideMinimumWindow() async throws {
    let (store, camera, recorder, _) = fixture()
    let record = try await store.createScript(title: "Retake", markdown: String(repeating: "Read these words. ", count: 100))
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for phase in [CameraRecorder.Phase.idle, .recording] {
        recorder.phase = phase; store.session.seek(to: 12)
        let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
        defer { LibraryAX.close(window) }
        host.sizingOptions = []; host.frame = .init(x: 0, y: 0, width: 720, height: 520)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        var frames = [NSRect]()
        for name in ["Start reading", "Back to start", phase == .recording ? "Stop recording" : "Record"] {
          let element = try XCTUnwrap(LibraryAX.named(name, in: host).first)
          let frame = try XCTUnwrap(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
          XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "\(name) at \(zoom): \(frame)")
          frames.append(frame)
        }
        XCTAssertEqual(frames[0].midY, frames[1].midY, accuracy: 1)
        XCTAssertEqual(frames[1].midY, frames[2].midY, accuracy: 1)
        XCTAssertFalse(LibraryAX.named("Tools", in: host).isEmpty)
        if phase == .idle { XCTAssertFalse(LibraryAX.named("Recording status", in: host).isEmpty) }
      }
    }
    recorder.phase = .idle
  }
  func testCameraViewSuppressesOldReadingProblemAndMonitorRetainsGuides() async throws {
    let (store, camera, recorder, _) = fixture()
    let record = try await store.createScript(title: "Camera", markdown: "One two three")
    store.session.present(record: record, settings: store.settings)
    camera.displayMode = .videoOnly; camera.guides.zebras = true; camera.guides.thirds = true; camera.cleanView = true
    XCTAssertFalse(camera.previewGuides.zebras); XCTAssertFalse(camera.previewGuides.thirds)
    XCTAssertTrue(camera.monitorGuides.zebras); XCTAssertTrue(camera.monitorGuides.thirds)
    XCTAssertTrue(camera.exposureBinding(\.zebras, presenter: false).wrappedValue)
    camera.exposureBinding(\.falseColour, presenter: false).wrappedValue = true
    XCTAssertTrue(camera.cleanView, "Monitor tools cannot leave the presenter's Clean view")
    let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder))
    defer { LibraryAX.close(window) }
    XCTAssertTrue(LibraryAX.named("Reading status", in: host).isEmpty)
    XCTAssertTrue(LibraryAX.named("Start reading", in: host).isEmpty)
    XCTAssertEqual(PresenterDisplayMode.videoOnly.label, "Camera view")
  }
  func testMeterIsLevelIndicatorWithUsefulValue() async throws {
    let (window, host) = await LibraryAX.host(InputLevelMeter(peakDBFS: -12, isClipping: false))
    defer { LibraryAX.close(window) }
    let meter = try XCTUnwrap(LibraryAX.named("Microphone peak level", in: host).first)
    XCTAssertEqual(LibraryAX.value(meter, "accessibilityRole"), "AXLevelIndicator")
    XCTAssertTrue(AccessibleInputLevel.description(peakDBFS: -12, isClipping: false).contains("Receiving sound"))
    XCTAssertEqual(AccessibleInputLevel.description(peakDBFS: -.infinity, isClipping: false), "No sound")
  }
  func testShootSetupRestoresAllChoicesAndRefusesActiveTakeOrMissingDevice() async throws {
    let (store, camera, recorder, defaults) = fixture()
    let microphones = [AudioInputDevice(id: 1, uid: "voice", name: "Voice"), AudioInputDevice(id: 2, uid: "record", name: "Record")]
    store.settings.audioDeviceUID = "voice"; store.settings.fontSize = 68
    store.settings.horizontalMirror = true; store.settings.verticalMirror = true
    camera.guides.thirds = true; camera.guides.zebras = true; camera.setRotation(.quarter)
    camera.mirrored = true; camera.displayMode = .prompterWithVideo
    recorder.preset = .high; recorder.mirrorSavedVideo = true
    recorder.usesSeparateMicrophone = true; recorder.microphoneUID = "record"; recorder.floatAudio = true
    store.saveShootSetup(named: "Portrait", camera: camera, recorder: recorder)
    let reloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: reloadRoot) }
    let reloaded = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", reloadRoot.path], defaults: defaults))
    let setup = try XCTUnwrap(reloaded.shootSetups.first)
    XCTAssertEqual(setup.id, store.shootSetups.first?.id)
    camera.guides.thirds = false; camera.guides.zebras = false; camera.setRotation(.none)
    camera.mirrored = false; camera.displayMode = .prompterOnly
    recorder.preset = .standard; recorder.mirrorSavedVideo = false
    recorder.usesSeparateMicrophone = false; recorder.microphoneUID = nil; recorder.floatAudio = false
    store.settings.fontSize = 30; store.settings.audioDeviceUID = nil
    store.settings.horizontalMirror = false; store.settings.verticalMirror = false
    let beforeReading = store.settings
    let beforeGuides = camera.guides
    func assertUnchanged(file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertEqual(store.settings, beforeReading, file: file, line: line)
      XCTAssertEqual(camera.guides, beforeGuides, file: file, line: line)
      XCTAssertNil(camera.selectedUID, file: file, line: line)
      XCTAssertFalse(camera.mirrored, file: file, line: line)
      XCTAssertEqual(camera.displayMode, .prompterOnly, file: file, line: line)
      XCTAssertEqual(recorder.preset, .standard, file: file, line: line)
      XCTAssertFalse(recorder.mirrorSavedVideo, file: file, line: line)
      XCTAssertFalse(recorder.usesSeparateMicrophone, file: file, line: line)
      XCTAssertNil(recorder.microphoneUID, file: file, line: line)
      XCTAssertFalse(recorder.floatAudio, file: file, line: line)
    }
    recorder.phase = .recording
    XCTAssertFalse(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: microphones))
    assertUnchanged()
    recorder.phase = .idle
    var missing = setup; missing.cameraUID = "missing"
    XCTAssertFalse(store.applyShootSetup(missing, camera: camera, recorder: recorder, microphones: microphones))
    assertUnchanged()
    XCTAssertFalse(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: Array(microphones.prefix(1))))
    assertUnchanged()
    XCTAssertFalse(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: Array(microphones.suffix(1))))
    assertUnchanged()
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: microphones))
    XCTAssertEqual(store.settings.fontSize, 68); XCTAssertTrue(camera.guides.thirds); XCTAssertTrue(camera.guides.zebras)
    XCTAssertTrue(store.settings.horizontalMirror); XCTAssertTrue(store.settings.verticalMirror)
    XCTAssertEqual(camera.guides.rotation, .quarter); XCTAssertEqual(recorder.preset, .high)
    XCTAssertTrue(camera.mirrored); XCTAssertEqual(camera.displayMode, .prompterWithVideo)
    XCTAssertTrue(recorder.mirrorSavedVideo); XCTAssertTrue(recorder.usesSeparateMicrophone)
    XCTAssertEqual(recorder.microphoneUID, "record"); XCTAssertEqual(store.settings.audioDeviceUID, "voice")
    XCTAssertEqual(recorder.resolvedMicrophoneUID, "record"); XCTAssertTrue(recorder.floatAudio)
  }
  func testExposureHostUsesTheReplacementSectionWithoutOldControls() async throws {
    let (_, camera, _, _) = fixture()
    camera.cleanView = true
    let (window, host) = await LibraryAX.host(CameraExposureSettings(model: camera, presenter: false))
    defer { LibraryAX.close(window) }
    XCTAssertTrue(LibraryAX.named("Zebra reference", in: host).isEmpty, "Reference presets are one level down in Custom levels")
    XCTAssertTrue(LibraryAX.named("Zebras show", in: host).isEmpty)
    XCTAssertTrue(LibraryAX.named("Show exposure aids", in: host).isEmpty, "Presenter Clean view must not hide monitor aids")
    XCTAssertEqual(LibraryAX.named("Custom levels", in: host).filter { LibraryAX.value($0, "accessibilityIdentifier") == "exposure-custom-levels" }.count, 1)
  }

  func testZoomRepairsToNearestSupportedStepAndKeepsFiniteFallback() {
    XCTAssertEqual(InputValidation.zoom.repair(1.3), 1.25)
    XCTAssertEqual(InputValidation.zoom.repair(1.48), 1.5)
    XCTAssertEqual(InputValidation.zoom.repair(.nan), 1)
    XCTAssertEqual(InputValidation.zoom.repair(9), 2)
  }
}

extension AppearanceSnapshotTests {
  func testRoundFourteenBuilderA() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let defaults = freshDefaults("A14Snapshots")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "A clear reading lane", markdown: String(repeating: "Read these words at your own pace. ", count: 100))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != name { continue }
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        for state in ["idle", "retake", "recording", "clean", "key", "camera"] {
          recorder.phase = state == "recording" ? .recording : .idle
          camera.displayMode = state == "camera" ? .videoOnly : .prompterWithVideo
          camera.cleanView = state == "clean"
          camera.guides.zebras = state == "key"; camera.guides.falseColour = state == "key"
          store.session.seek(to: state == "retake" ? 12 : 0)
          try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), name: "a14-\(state)-\(Int(zoom * 100))-\(name)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
        }
        recorder.phase = .idle
        try await snapshot(ReadingAppearancePreview(settings: store.settings, overVideo: true).padding().uiZoom(zoom), name: "a14-preview-\(Int(zoom * 100))-\(name)", size: .init(width: 380, height: 400), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
      try await snapshot(PresenterHelp(), name: "a14-help-\(name)", size: .init(width: 400, height: 400), scheme: scheme, destination: URL(fileURLWithPath: output))
    }
  }
}
