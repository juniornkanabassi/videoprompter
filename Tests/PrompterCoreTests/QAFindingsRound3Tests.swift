import AppKit
import Foundation
import XCTest
@testable import PrompterCore
@testable import VideoPrompter

/// Round-three regressions. Disposable defaults/files; lifecycle states are synthetic.
/// No camera, audio capture, playback or visible windows are started.
@MainActor final class QAFindingsRound3Tests: XCTestCase {
  func testVoiceMicrophoneChangedDuringSeparateTakeIsUsedAfterReturningToSharedInput() throws {
    for phase in [CameraRecorder.Phase.preparing, .waitingForFrames, .recording, .saving] {
      let defaults = freshDefaults("QA3Microphone")
      var settings = PrompterSettings()
      settings.audioDeviceUID = "voice-before"
      defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
      let recorder = CameraRecorder(defaults: defaults)
      recorder.usesSeparateMicrophone = true
      recorder.microphoneUID = "separate-recording-input"
      recorder.phase = phase
      // The UI and CLI allow changing Voice input when recording uses a separate input.
      settings.audioDeviceUID = "voice-after"
      defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
      recorder.useSettings(settings)
      XCTAssertEqual(recorder.resolvedMicrophoneUID, "separate-recording-input")
      recorder.phase = .idle
      recorder.usesSeparateMicrophone = false
      XCTAssertEqual(recorder.resolvedMicrophoneUID, "voice-after",
        "After \(phase), sharing the Voice microphone must use the latest selection")
    }
  }

  func testEveryRelinkChoiceClearsUnsupportedStatusImmediately() async throws {
    for resolution in [RelinkResolution.keepBoth, .keepLibrary, .useFile] {
    let root = URL(fileURLWithPath: "/private/tmp/vp-qa3-relink-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root.appendingPathComponent("library"))
    let oldFile = root.appendingPathComponent("unmarked.md")
    let text = "Original words"
    let original = try XCTUnwrap(text.data(using: .utf16LittleEndian))
    try original.write(to: oldFile)
    let record = try await library.createLinked(title: "Original", markdown: text, to: oldFile)
    _ = try await library.save(record.id, markdown: "Local words", expectedFingerprint: record.metadata.contentFingerprint)
    let before = await library.linkedSyncWaiting()
    XCTAssertTrue(before.joined().contains("unsupported encoding"))
    // Make Find Linked File available, as if the external source was removed.
    let archived = root.appendingPathComponent("archived.md")
    try original.write(to: archived)
    try FileManager.default.removeItem(at: oldFile)
    let broken = try await library.linkState(for: record.id)
    XCTAssertTrue(broken.isBroken)
    let newFile = root.appendingPathComponent("replacement.md")
    try Data("Replacement words".utf8).write(to: newFile)
    let result = try await library.relink(id: record.id, to: newFile, resolution: resolution)
    if resolution == .keepBoth {
      XCTAssertNil(result.current.metadata.linkedPath)
      XCTAssertNotNil(result.imported)
    } else {
      XCTAssertEqual(result.current.metadata.linkedPath, newFile.standardizedFileURL.path)
    }
    let immediate = await library.linkedSyncWaiting()
    XCTAssertTrue(immediate.isEmpty, "Stale status after \(resolution): \(immediate)")
    // Run ordinary future polls too: an unlinked script can never clear this warning itself.
    for metadata in await library.listScripts() { _ = try await library.externalChange(for: metadata.id) }
    let after = await library.linkedSyncWaiting()
    XCTAssertTrue(after.isEmpty,
      "Neither retained script is linked to unmarked.md, so it must not keep a permanent sync warning: \(after)")
    XCTAssertEqual(try Data(contentsOf: archived), original)
    }
  }
}
