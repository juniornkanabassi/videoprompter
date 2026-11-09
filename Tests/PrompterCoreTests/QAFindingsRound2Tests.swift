import AppKit
import Foundation
import PrompterCore
import Synchronization
import XCTest
@testable import VideoPrompter

private final class QA2HeldEditor: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  let releaseSave = DispatchSemaphore(value: 0)
  let saveRequests = Mutex(0)
  init(url: URL) { presentedItemURL = url; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1 }
  func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
    saveRequests.withLock { $0 += 1 }
    _ = releaseSave.wait(timeout: .now() + 4)
    completionHandler(nil)
  }
}

/// Round-two reproductions. Disposable files/defaults only; no live audio or camera capture.
@MainActor final class QAFindingsRound2Tests: XCTestCase {
  private func fixture() async throws -> (AppStore, UserDefaults, URL) {
    let root = URL(fileURLWithPath: "/private/tmp/vp-qa2-\(UUID())")
    let defaults = freshDefaults("QAFindingsRound2")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    await store.waitForInitialLoad()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (store, defaults, root)
  }

  func testScriptDeleteUndoKeepsItsOrderBeforeLaterPresetDelete() async throws {
    let (store, _, _) = try await fixture()
    let script = try await store.createScript(title: "Keep my words", markdown: "Original words")
    store.savePreset(named: "Keep my preset")
    let manager = UndoManager()
    // Use AppKit's normal event grouping, including for the async deletion callback.
    manager.beginUndoGrouping()
    store.delete([script.id], undoManager: manager)
    manager.endUndoGrouping()
    manager.beginUndoGrouping()
    store.deletePreset(store.presets[0].id, undoManager: manager)
    manager.endUndoGrouping()
    for _ in 0..<100 where !store.trash.contains(where: { $0.id == script.id }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(store.trash.contains(where: { $0.id == script.id }))
    XCTAssertEqual(manager.undoActionName, "Delete Preset", "A completed async delete must not jump ahead of a later action")
    manager.undo()
    for _ in 0..<100 where store.presets.isEmpty && !store.scripts.contains(where: { $0.id == script.id }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(store.presets.map(\.name), ["Keep my preset"], "Undo must restore the last action first")
    XCTAssertFalse(store.scripts.contains(where: { $0.id == script.id }), "The earlier script delete must remain until the next Undo")
  }

  func testLegacyRecordingMicrophoneSurvivesSystemDefaultVoiceMicrophone() throws {
    guard Features.recording else { throw XCTSkip("Recording is not available in this build") }
    let defaults = freshDefaults("QA2MicrophoneMigration")
    var settings = PrompterSettings()
    settings.audioDeviceUID = nil // The legacy Voice choice was System default.
    defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
    defaults.set("explicit-recording-microphone", forKey: "recordingMicrophoneUID")
    let recorder = CameraRecorder(defaults: defaults)
    XCTAssertTrue(recorder.usesSeparateMicrophone, "Migration must retain an explicitly chosen recording input")
    XCTAssertEqual(recorder.resolvedMicrophoneUID, "explicit-recording-microphone")
    let relaunched = CameraRecorder(defaults: defaults)
    XCTAssertEqual(relaunched.resolvedMicrophoneUID, "explicit-recording-microphone", "A relaunch must not cement the lost choice")
  }

  func testCLIRejectsSharedMicrophoneChangeWhileRecordingSettingsAreLocked() async throws {
    let (store, defaults, _) = try await fixture()
    store.settings.mode = "Manual"
    store.settings.audioDeviceUID = "original-input"
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    let actions = ControlActions(store: store, presenter: PresenterController(camera: camera), camera: camera, recorder: recorder)
    for phase in [CameraRecorder.Phase.preparing, .waitingForFrames, .recording, .saving] {
      recorder.phase = phase // Synthetic lifecycle only; start(camera:) is never called.
      let response = await actions.handle("settings_set", ["microphone": "none"])
      XCTAssertEqual(response.body["ok"] as? Bool, false, "The CLI must honour the same shared-input lock as the UI during \(phase)")
      XCTAssertEqual(store.settings.audioDeviceUID, "original-input")
    }
    recorder.phase = .idle
  }

  func testBOMlessUTF16ImportDoesNotTreatNULBytesAsUTF8Characters() async throws {
    let (_, _, root) = try await fixture()
    let text = "# Match day\n\nRead these words."
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
      let file = root.appendingPathComponent("utf16-\(encoding.rawValue).md")
      try XCTUnwrap(text.data(using: encoding)).write(to: file)
      let preview = try await DocumentImporter().preview(url: file)
      XCTAssertEqual(preview.markdown, text, "A UTF-16 file must not import with an embedded NUL between every character")
    }
  }
  func testUnlinkDuringPendingPushDoesNotReappearInAppMetadata() async throws {
    let (store, _, root) = try await fixture()
    let external = root.deletingLastPathComponent().appendingPathComponent("vp-qa2-external-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: external) }
    try "original".write(to: external, atomically: true, encoding: .utf8)
    let script = try await store.createScript(title: "Linked", markdown: "original", linkTo: external)
    let editor = QA2HeldEditor(url: external)
    NSFileCoordinator.addFilePresenter(editor)
    defer { editor.releaseSave.signal(); NSFileCoordinator.removeFilePresenter(editor) }
    store.updateMarkdown("new local words", for: script.id)
    for _ in 0..<150 where editor.saveRequests.withLock({ $0 }) == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertGreaterThan(editor.saveRequests.withLock { $0 }, 0, "Exercise an in-flight linked write")
    store.unlink(script.id)
    for _ in 0..<100 where store.scripts.first(where: { $0.id == script.id })?.metadata.linkedPath != nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNil(store.scripts.first(where: { $0.id == script.id })?.metadata.linkedPath)
    editor.releaseSave.signal()
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    let library = try XCTUnwrap(store.library)
    let durable = try await library.read(script.id)
    XCTAssertNil(durable.metadata.linkedPath)
    XCTAssertEqual(durable.markdown, "new local words")
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "original")
    XCTAssertNil(store.scripts.first(where: { $0.id == script.id })?.metadata.linkedPath,
      "The older save result must not resurrect link metadata after Unlink completed")
  }

}
