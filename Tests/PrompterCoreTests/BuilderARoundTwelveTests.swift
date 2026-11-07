import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderARoundTwelveTests: XCTestCase {
  func testTypingDuringSaveKeepsTheNewTextOpen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("A12Save")))
    let record = try await store.createScript(title: "Draft", markdown: "Original text")
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    let draft = PresenterDraft(record: record); draft.begin(session: store.session); draft.markdown = "First edit"
    var release: CheckedContinuation<Void, Never>?
    store.presenterSaveReservationGate = { await withCheckedContinuation { release = $0 } }
    let save = Task { await draft.confirm(store: store) }
    for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
    let unblock = try XCTUnwrap(release)
    draft.markdown = "New text while saving"
    draft.cancel(); draft.begin(session: store.session)
    XCTAssertEqual(draft.markdown, "New text while saving")
    unblock.resume(); await save.value
    XCTAssertTrue(draft.isEditing); XCTAssertTrue(draft.hasEdits)
    XCTAssertEqual(draft.markdown, "New text while saving")
    XCTAssertEqual(store.scripts.first { $0.id == record.id }?.markdown, "First edit")
  }

  func testStoredUnicodeColoursAreRepairedOnLoad() throws {
    let data = Data(##"{"textColorHex":"#ＦＦ００ＦＦ","backgroundColorHex":"#１２３４５６"}"##.utf8)
    let settings = try JSONDecoder().decode(PrompterSettings.self, from: data)
    XCTAssertEqual(settings.textColorHex, "#FFFFFF")
    XCTAssertEqual(settings.backgroundColorHex, "#000000")
    let guides = try JSONDecoder().decode(CameraGuides.self, from: Data(##"{"colorHex":"#ＦＦ００ＦＦ"}"##.utf8))
    XCTAssertEqual(guides.colorHex, "#3F8CFF")
    XCTAssertEqual(PrompterSettings.normalisedHexColour("ff00af"), "#FF00AF")
  }
}

extension AppearanceSnapshotTests {
  func testRoundTwelveLabelsAndStates() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A12Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Complete labels", markdown: "# Complete labels\n\n" + String(repeating: "Read these words at your own pace. ", count: 100))
    let camera = CameraModel(defaults: defaults); camera.recordingReadyOverride = true; camera.displayMode = .prompterWithVideo
    let recorder = CameraRecorder(defaults: defaults)
    for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != appearance { continue }
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        for state in ["idle", "countdown", "retake", "editing", "voice-listening", "voice-following", "voice-paused", "monitor-key"] {
          camera.guides.zebras = state == "monitor-key"; camera.guides.falseColour = state == "monitor-key"
          store.session.pause(); store.settings.mode = state.hasPrefix("voice") ? "Voice" : "Manual"
          store.settings.audioDeviceUID = "fixture"; store.session.present(record: record, settings: store.settings)
          store.session.countdownTick = .seconds(60)
          recorder.phase = state == "retake" || state == "editing" ? .recording : .idle
          let draft = PresenterDraft(record: record)
          if state == "retake" { store.session.seek(to: 40) }
          if state == "editing" { draft.begin(session: store.session) }
          if state == "countdown" { store.session.startReading() }
          if state == "voice-listening" || state == "voice-following" { store.session.play(captureAudio: false) }
          if state == "voice-following" {
            store.session.acceptSpeechCandidate(SpeechCandidate(replacementID: "fixture", generation: 1,
              locale: Locale(identifier: "en-GB"), text: "Complete labels read these words",
              range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1)), isFinal: false))
            XCTAssertEqual(store.session.visibleReadingState, "Following")
          }
          try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder), name: "a12-\(state)-\(Int(zoom * 100))-\(appearance)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
        }
        try await snapshot(AppSettingsView(store: store, selectedTab: .camera), name: "a12-navigation-\(Int(zoom * 100))-\(appearance)", size: .init(width: 900, height: 700), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
    }
    recorder.phase = .idle; store.session.pause()
  }
}
