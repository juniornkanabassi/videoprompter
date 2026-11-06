import AppKit
import AVFoundation
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderARoundFifteenTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A15")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), CameraModel(defaults: defaults), CameraRecorder(defaults: defaults))
  }

  func testComparisonNeverEnablesAnAidAndRestoresConfiguredChoices() {
    let (_, camera, _) = fixture()
    camera.toggleExposureCheck()
    XCTAssertFalse(camera.exposureIsConfigured)
    camera.guides.falseColour = true
    let saved = camera.guides
    camera.toggleExposureCheck()
    XCTAssertEqual(camera.exposureCheckState, "Aids bypassed")
    XCTAssertEqual(camera.guides, saved)
    camera.toggleExposureCheck()
    XCTAssertEqual(camera.exposureCheckState, "Aids visible")
    camera.cleanView = true
    camera.restoreExposureAids()
    XCTAssertFalse(camera.cleanView)
    XCTAssertEqual(camera.guides, saved)
  }

  func testEveryGuideControlNamesAnExistingUIControl() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let ui = root.appendingPathComponent("Sources/VideoPrompter")
    let enumerator = FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)!
    let source = try enumerator.compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "WelcomeScript.swift" }
      .map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    let names = try NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    for match in names.matches(in: WelcomeScript.markdown, range: NSRange(WelcomeScript.markdown.startIndex..., in: WelcomeScript.markdown)) {
      let name = String(WelcomeScript.markdown[Range(match.range(at: 1), in: WelcomeScript.markdown)!])
      // Exact literal at a control or label declaration, never the guide's own text.
      let escaped = NSRegularExpression.escapedPattern(for: name)
      let control = try NSRegularExpression(pattern: #"(?:Button|Toggle|Picker|Text|Label|accessibilityLabel)\s*\([^\n]*""# + escaped + #"""#)
      XCTAssertNotNil(control.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), "Guide names a missing control: \(name)")
    }
    XCTAssertFalse(WelcomeScript.markdown.contains("More →"))
  }

  func testToolsHasFourJobsAndSingleSettingsLinks() async throws {
    let (store, camera, recorder) = fixture()
    let record = try await store.createScript(title: "Tools", markdown: "Read these words.")
    store.session.present(record: record, settings: store.settings)
    camera.displayMode = .prompterWithVideo
    let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
    let (window, host) = await LibraryAX.host(Form { ForEach(["Text", "Camera", "Exposure", "Microphone"], id: \.self) { view.toolContents($0) } }, size: .init(width: 520, height: 700))
    defer { LibraryAX.close(window) }
    for name in ["Smaller text", "Larger text", "Reading mode…", "Edit this script", "Choose camera…", "Framing guides…", ExposureLegend.zebraTitle(for: camera.guides.validatedZebraPurpose), "Check brightness · False colour", "Check sound…", "More text settings…", "More camera settings…", "More exposure settings…", "More microphone settings…"] {
      XCTAssertFalse(LibraryAX.named(name, in: host).isEmpty, name)
    }
    for name in ["Settings for all scripts…", "Microphone settings for all scripts…", "Save or manage shoot setups…"] {
      XCTAssertTrue(LibraryAX.named(name, in: host).isEmpty, name)
    }
  }

  func testPermissionRecoveryAndOutputNameTheActualPrerequisites() async throws {
    let (store, camera, recorder) = fixture()
    let record = try await store.createScript(title: "Recovery", markdown: "Read these words.")
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    camera.displayMode = .prompterWithVideo; camera.authorization = .denied
    XCTAssertEqual(camera.recordingBlockReason, "Allow camera in System Settings")
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
      let recovery = try XCTUnwrap(LibraryAX.named("Allow camera in System Settings", in: host).first)
      let frame = try XCTUnwrap(recovery.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      XCTAssertTrue(window.convertToScreen(host.bounds).contains(frame), "Recovery at \(zoom): \(frame)")
      XCTAssertFalse(LibraryAX.named("Reading status", in: host).isEmpty)
      LibraryAX.close(window)
    }
    for preset in RecordingPreset.allCases {
      recorder.preset = preset
      XCTAssertTrue(recorder.inputAndFormatConfirmation.contains(recorder.microphoneName))
      XCTAssertTrue(recorder.inputAndFormatConfirmation.contains(preset == .standard ? "H.264" : preset == .high ? "HEVC" : "ProRes 422"))
    }
  }

  func testReadingPresetsExcludesShootSetupsAndCameraPageOwnsManagement() async throws {
    let (store, camera, recorder) = fixture()
    let (window, host) = await LibraryAX.host(SettingsPage(store: store, tab: .presets), size: .init(width: 600, height: 700))
    XCTAssertTrue(LibraryAX.named("Saved shoot setups", in: host).isEmpty)
    XCTAssertFalse(LibraryAX.named("Save Reading Preset", in: host).isEmpty)
    LibraryAX.close(window)
    XCTAssertTrue(store.saveShootSetup(named: "Studio", camera: camera, recorder: recorder))
    let id = try XCTUnwrap(store.shootSetups.first?.id)
    XCTAssertFalse(store.saveShootSetup(named: " studio ", camera: camera, recorder: recorder))
    XCTAssertTrue(store.renameShootSetup(id, to: "Desk"))
    XCTAssertEqual(store.shootSetups.first?.name, "Desk")
    let (setupWindow, setupHost) = await LibraryAX.host(Form { ShootSetupSection(store: store, camera: camera, recorder: recorder) }.formStyle(.grouped), size: .init(width: 600, height: 700))
    XCTAssertFalse(LibraryAX.named("Save shoot setup", in: setupHost).isEmpty)
    XCTAssertFalse(LibraryAX.named("Actions for Desk", in: setupHost).isEmpty)
    LibraryAX.close(setupWindow)
    store.deleteShootSetup(id)
    XCTAssertTrue(store.shootSetups.isEmpty)
  }
}

extension AppearanceSnapshotTests {
  func testRoundFifteenBuilderA() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A15Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Recovery and working tools", markdown: String(repeating: "Read these words at your own pace. ", count: 100))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != name { continue }
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        for state in ["denied", "scrolling", "bypassed", "ready", "receipt", "reading-recovery"] {
          store.session.pause(); camera.authorization = .denied; camera.recordingReadyOverride = nil
          recorder.savedTake = nil; recorder.droppedFrames = 0
          camera.guides.falseColour = false; camera.exposureBypassed = false
          if state == "scrolling" { store.session.play(captureAudio: false) }
          if state == "bypassed" { camera.guides.falseColour = true; camera.exposureBypassed = true; camera.recordingReadyOverride = true }
          if state == "ready" { camera.recordingReadyOverride = true }
          if state == "receipt" { recorder.savedTake = URL(fileURLWithPath: "/tmp/Take.mov"); recorder.droppedFrames = 7; camera.recordingReadyOverride = true }
          let draft = PresenterDraft(record: record)
          if state == "reading-recovery" {
            store.settings.mode = "Voice"; store.session.updateSettings(store.settings)
            draft.noticeMessage = "Allow microphone access in System Settings, then try reading again."
          }
          let view = PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder)
          try await snapshot(view, name: "a15-\(state)-\(Int(zoom * 100))-\(name)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
          store.settings.mode = "Manual"
        }
        let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
        try await snapshot(view.toolsSurface, name: "a15-tools-\(Int(zoom * 100))-\(name)", size: .init(width: 640, height: 680), scheme: scheme, destination: URL(fileURLWithPath: output))
        try await snapshot(Form { ShootSetupSection(store: store, camera: camera, recorder: recorder) }.formStyle(.grouped).uiZoom(zoom), name: "a15-setups-\(Int(zoom * 100))-\(name)", size: .init(width: 600, height: 700), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
    }
    store.session.pause()
  }
}
