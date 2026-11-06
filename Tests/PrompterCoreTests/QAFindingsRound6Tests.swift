import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Disposable data and invisible TestOffscreen hosts only. No capture or playback.
@MainActor final class QAFindingsRound6Tests: XCTestCase {
  private func fixture() async throws -> (AppStore, UserDefaults, ScriptRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA6-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("QA6")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "QA6", markdown: "Original script. One two three.")
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    return (store, defaults, record)
  }

  func testCancelCannotDiscardOrReplaceADraftWhileItsSaveIsPending() async throws {
    let (store, _, record) = try await fixture()
    let draft = PresenterDraft(record: record)
    draft.begin(session: store.session)
    draft.markdown = "First edit being saved."
    var release: CheckedContinuation<Void, Never>?
    store.presenterSaveReservationGate = { await withCheckedContinuation { release = $0 } }
    let save = Task { await draft.confirm(store: store) }
    for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
    guard let unblock = release else { XCTFail("Save did not reach its disk reservation"); return }
    defer { store.presenterSaveReservationGate = nil }
    XCTAssertTrue(draft.isSaving)
    draft.requestCancel()
    let offeredDiscard = draft.closeRequested
    XCTAssertFalse(offeredDiscard, "Cancel editing must not offer to discard a draft that is already being written")
    if offeredDiscard {
      // Follow the enabled Discard Draft action, then start another edit before I/O completes.
      draft.cancel()
      draft.begin(session: store.session)
      draft.markdown = "Second edit that must remain open."
    }
    unblock.resume()
    await save.value
    if offeredDiscard {
      XCTAssertTrue(draft.isEditing, "The first save completion must not close the second unsaved edit")
      XCTAssertEqual(draft.markdown, "Second edit that must remain open.")
    }
  }

  func testUnicodeHexDigitsCannotBePersistedAsUnrenderableColours() async throws {
    let (store, defaults, _) = try await fixture()
    let camera = CameraModel(defaults: defaults)
    camera.selectedUID = "qa6-camera-no-hardware"
    let actions = ControlActions(store: store, camera: camera, recorder: CameraRecorder(defaults: defaults))
    for key in ["textColour", "backgroundColour"] {
      for value in ["ＦＦ００ＦＦ", "１２３４５６"] {
        let before = store.settings
        let reply = await actions.handle("settings_set", [key: value])
        XCTAssertEqual(reply.body["ok"] as? Bool, false, "\(key)=\(value) is accepted but NSColor(hex:) cannot render it")
        XCTAssertEqual(store.settings, before, "Invalid colour must not reach settings storage")
      }
    }
    let before = camera.guides
    let reply = await actions.handle("camera_guides", ["colour": "ＦＦ００ＦＦ"])
    XCTAssertEqual(reply.body["ok"] as? Bool, false)
    XCTAssertEqual(camera.guides, before, "Invalid colour must not reach per-camera storage")
    await store.flushSettings()
    let saved = try JSONDecoder().decode(PrompterSettings.self, from: XCTUnwrap(defaults.data(forKey: "settings")))
    XCTAssertNotNil(NSColor(hex: saved.textColorHex))
    XCTAssertNotNil(NSColor(hex: saved.backgroundColorHex))
  }

  func testLoadedGuideNumbersAreSanitisedBeforeFormattingOrDrawing() throws {
    let defaults = freshDefaults("QA6GuideNumbers")
    let uid = "qa6-camera-no-hardware"
    let raw: [String: Any] = ["marker": ["width": 0, "height": 1], "thirds": true,
      "opacity": 1e100, "shadeOpacity": -1, "zebraLevel": Int.max, "zebraRange": 10, "zebras": true]
    defaults.set([uid: try JSONSerialization.data(withJSONObject: raw)], forKey: "cameraGuides")
    defaults.set(uid, forKey: "cameraDeviceUID")
    let model = CameraModel(defaults: defaults)
    XCTAssertNil(model.guides.marker)
    XCTAssertTrue(model.guides.thirds)
    XCTAssertTrue((0...1).contains(model.guides.opacity), "Guide visibility must be safe for Int(opacity * 100) in the newly direct Guides panel")
    XCTAssertTrue((0...1).contains(model.guides.shadeOpacity))
    XCTAssertTrue((0...100).contains(model.guides.zebraLevel), "Exposure guidance adds level and range; Int.max causes an overflow trap")
    XCTAssertTrue((0...10).contains(model.guides.zebraRange))
    let stored = try JSONDecoder().decode(CameraGuides.self, from: XCTUnwrap(defaults.dictionary(forKey: "cameraGuides")?[uid] as? Data))
    XCTAssertTrue((0...1).contains(stored.opacity), "Repair must persist, just as invalid marker repair does")
    XCTAssertTrue((0...100).contains(stored.zebraLevel))
  }

  func testCorruptGuideNumbersDoNotCrashDirectSettingsPanels() async throws {
    let key = "VIDEOPROMPTER_QA6_PANEL_PROBE"
    if let panel = ProcessInfo.processInfo.environment[key] {
      let defaults = freshDefaults("QA6PanelCrash")
      let uid = "qa6-no-hardware"
      let raw: [String: Any] = panel == "guides"
        ? ["marker": ["width": 0, "height": 1], "opacity": 1e100]
        : ["zebraLevel": Int.max, "zebraRange": 10, "zebras": true]
      defaults.set([uid: try JSONSerialization.data(withJSONObject: raw)], forKey: "cameraGuides")
      defaults.set(uid, forKey: "cameraDeviceUID")
      let model = CameraModel(defaults: defaults)
      if panel == "guides" {
        let (window, _) = await LibraryAX.host(CameraGuideSettings(model: model))
        LibraryAX.close(window)
      } else {
        let (window, _) = await LibraryAX.host(CameraExposureSettings(model: model))
        LibraryAX.close(window)
      }
      return
    }
    for panel in ["guides", "exposure"] {
      let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("qa6-panel-\(UUID()).log")
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
      defer { try? FileManager.default.removeItem(at: logURL) }
      let output = try FileHandle(forWritingTo: logURL)
      defer { try? output.close() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
      process.arguments = ["-XCTest", "PrompterCoreTests.QAFindingsRound6Tests/testCorruptGuideNumbersDoNotCrashDirectSettingsPanels", Bundle(for: Self.self).bundlePath]
      var env = ProcessInfo.processInfo.environment
      env[key] = panel
      process.environment = env
      process.standardOutput = output
      process.standardError = output
      try process.run()
      let deadline = ContinuousClock.now + .seconds(20)
      while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
      if process.isRunning { process.terminate(); process.waitUntilExit(); XCTFail("\(panel) panel hung"); continue }
      let log = try String(contentsOf: logURL, encoding: .utf8)
      let diagnosis = log.split(separator: "\n").filter { $0.contains("Fatal error") || $0.contains("runtime failure") || $0.contains("CameraGuide") }.prefix(6).joined(separator: "\n")
      XCTAssertEqual(process.terminationReason, .exit, "\(panel) settings crashed. \(diagnosis)")
      XCTAssertEqual(process.terminationStatus, 0, "\(panel) settings must repair corrupt preferences before rendering")
    }
  }

  func testAcceptedTinyFrameMarkerHasFiniteUsableGeometry() async throws {
    let (store, defaults, _) = try await fixture()
    let camera = CameraModel(defaults: defaults)
    camera.selectedUID = "qa6-camera-no-hardware"
    let actions = ControlActions(store: store, camera: camera, recorder: CameraRecorder(defaults: defaults))
    let reply = await actions.handle("camera_guides", ["marker": "5e-324:5e-324"])
    // Rejecting an unusable dimension is also safe. If accepted, it must render a valid square.
    guard reply.body["ok"] as? Bool == true else { return }
    let marker = try XCTUnwrap(camera.guides.marker)
    let frame = marker.fitted(in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite,
      "The accepted and persisted ratio produces infinite overlay geometry: \(frame)")
    XCTAssertEqual(frame.width, 1080, accuracy: 0.001)
    XCTAssertEqual(frame.height, 1080, accuracy: 0.001)
  }

}
