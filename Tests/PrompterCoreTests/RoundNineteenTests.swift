import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Round 19 review findings: named Tools entries, honest preset replacement, locked-only help and content-fitting Tools.
@MainActor final class RoundNineteenTests: XCTestCase {
  private func fixture() async throws -> (AppStore, CameraModel, CameraRecorder, ScriptRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("round19-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("Round19")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Round 19", markdown: String(repeating: "Read these words. ", count: 40))
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder; camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true; camera.pictureSizeOverride = .init(width: 1080, height: 1920)
    return (store, camera, recorder, record)
  }

  func testSavingAnExistingPresetNameSaysReplace() async throws {
    let (store, _, _, _) = try await fixture()
    store.savePreset(named: "Studio")
    XCTAssertNil(SettingsPage.presetToReplace("", in: store.presets))
    XCTAssertNil(SettingsPage.presetToReplace("Field", in: store.presets))
    XCTAssertEqual(SettingsPage.presetToReplace(" Studio ", in: store.presets)?.name, "Studio")
    let manager = UndoManager(); manager.groupsByEvent = false
    let before = store.presets[0].fontSize
    store.settings.fontSize = before + 10
    manager.beginUndoGrouping(); store.updatePreset(store.presets[0].id, undoManager: manager); manager.endUndoGrouping()
    XCTAssertEqual(manager.undoActionName, "Replace Preset")
    XCTAssertEqual(store.presets[0].fontSize, before + 10)
    manager.undo()
    XCTAssertEqual(store.presets[0].fontSize, before, "Undo restores the replaced look")
    let (window, host) = await LibraryAX.host(SettingsPage(store: store, tab: .presets), size: .init(width: 720, height: 600))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named("Save Reading Preset", in: host).isEmpty, "A new or empty name still saves")
  }

  func testStopRecordingHelpOnlyWhileLocked() async throws {
    guard Features.recording else { throw XCTSkip("Recording is not available in this build") }
    let (_, camera, recorder, _) = try await fixture()
    for locked in [false, true] {
      recorder.phase = locked ? .recording : .idle
      XCTAssertEqual(recorder.settingsLocked, locked)
      let (window, host) = await LibraryAX.host(Form { RecordingSettingsSections(recorder: recorder, camera: camera) }.formStyle(.grouped), size: .init(width: 560, height: 500))
      defer { LibraryAX.close(window) }
      let helps = LibraryAX.elements(host).map { LibraryAX.value($0, "accessibilityHelp") }
      XCTAssertEqual(helps.contains("Stop recording to change this"), locked, "Locked help while idle: \(helps)")
      let format = try XCTUnwrap(LibraryAX.named("Recording format", in: host).first)
      XCTAssertEqual(LibraryAX.bool(format, "isAccessibilityEnabled"), !locked)
    }
    recorder.phase = .idle
  }



  func testCleanTakeKeepsPictureChecksAndOpensItsReceipt() async throws {
    guard Features.recording else { throw XCTSkip("Recording is not available in this build") }
    let (store, camera, recorder, record) = try await fixture()
    recorder.savedTake = URL(fileURLWithPath: "/tmp/Round 19 2026-11-07 10-00-00.mov"); recorder.lastTakeDuration = 61
    let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
    let (window, host) = await LibraryAX.host(view, size: .init(width: 720, height: 520))
    defer { LibraryAX.close(window) }
    host.sizingOptions = []; host.frame = .init(x: 0, y: 0, width: 720, height: 520)
    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    for name in ["Zebras", "False colour", "Guides", "Mic level", "Legend", "Camera", "Clean", "Last take"] { XCTAssertFalse(LibraryAX.named(name, in: host).isEmpty, name) }
    let opener = try XCTUnwrap(LibraryAX.named("Last take", in: host).first)
    XCTAssertEqual(LibraryAX.value(opener, "accessibilityValue"), "Saved Round 19 2026-11-07 10-00-00.mov · 1:01")
    let frame = try XCTUnwrap(opener.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    XCTAssertGreaterThanOrEqual(frame.height, 24)
    recorder.droppedAudioBuffers = 2
    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertTrue(LibraryAX.named("Guides", in: host).isEmpty, "Saved with problems keeps the full receipt in view")
    XCTAssertFalse(LibraryAX.named("Review", in: host).isEmpty)
  }
}
