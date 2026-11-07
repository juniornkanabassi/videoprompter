import AVFoundation
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

extension AppearanceSnapshotTests {
  func testRepairedPreferencesAndUnmatchedVoice() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("validation-snapshots-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("ValidationSnapshots")
    defaults.set(Data(#"{"mode":"Voice","fontSize":44,"textOpacity":1e100,"audioDeviceUID":"no-hardware"}"#.utf8), forKey: "settings")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Keep your place", markdown: "One two three four five six seven eight nine ten eleven twelve.")
    store.session.present(record: record, settings: store.settings)
    store.session.play(captureAudio: false)
    defer { store.session.pause() }
    for (id, text, start) in [("match", "one two three", 0.0), ("unmatched", "purple elephants dance slowly", 2.0)] {
      store.session.acceptSpeechCandidate(SpeechCandidate(replacementID: id, generation: 1, locale: Locale(identifier: "en-GB"), text: text,
        range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 100), duration: CMTime(seconds: 1, preferredTimescale: 100)), isFinal: false))
    }
    XCTAssertEqual(store.session.visibleReadingState, "Matching words")
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    let recorder = CameraRecorder(defaults: defaults)
    for (mode, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != mode { continue }
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        try await snapshot(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera,
          startsCamera: false, recorder: recorder), name: "qa7-matching-\(Int(zoom * 100))-\(mode)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
    }
  }
}
