import AppKit
import AVFoundation
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Regression probes only: disposable defaults, no capture, invisible TestOffscreen hosts.
@MainActor final class QAFindingsRound7Tests: XCTestCase {
  private func fixture(_ defaults: UserDefaults? = nil) -> (AppStore, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA7-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = defaults ?? freshDefaults("QA7")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)), defaults)
  }

  func testLoadedReadingNumbersStayInsideTheSupportedControlRanges() throws {
    let fields: [(String, KeyPath<PrompterSettings, Double>, ClosedRange<Double>)] = [
      ("textOpacity", \.textOpacity, 0.2...1),
      ("backgroundOpacity", \.backgroundOpacity, 0...1),
      ("videoDimming", \.videoDimming, 0...1),
      ("guideFraction", \.guideFraction, 0.1...0.85),
      ("guideOpacity", \.guideOpacity, 0...1),
      ("lineSpacing", \.lineSpacing, 0...0.5),
      ("paragraphSpacing", \.paragraphSpacing, 0...1),
      ("inputGain", \.inputGain, 0.25...4)
    ]
    for (field, path, range) in fields {
      for number in [-1e100, 1e100] {
        let data = try JSONSerialization.data(withJSONObject: [field: number])
        let settings = try JSONDecoder().decode(PrompterSettings.self, from: data)
        XCTAssertTrue(range.contains(settings[keyPath: path]), "\(field)=\(number) survives decoding outside \(range)")
      }
    }
  }

  func testCorruptSavedReadingOpacityDoesNotCrashSettingsGet() async throws {
    let probe = "VIDEOPROMPTER_QA7_CORRUPT_SETTINGS_PROBE"
    if ProcessInfo.processInfo.environment[probe] == "1" {
      let defaults = freshDefaults("QA7Crash")
      defaults.set(try JSONSerialization.data(withJSONObject: ["mode": "Manual", "textOpacity": 1e100]), forKey: "settings")
      let (store, _) = fixture(defaults)
      let actions = ControlActions(store: store, camera: CameraModel(defaults: defaults), recorder: CameraRecorder(defaults: defaults))
      let reply = await actions.handle("settings_get", [:])
      XCTAssertEqual(reply.body["ok"] as? Bool, true)
      return
    }
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("QA7-crash-\(UUID()).log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: log) }
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
    child.arguments = ["-XCTest", "PrompterCoreTests.QAFindingsRound7Tests/testCorruptSavedReadingOpacityDoesNotCrashSettingsGet", Bundle(for: Self.self).bundlePath]
    var environment = ProcessInfo.processInfo.environment
    environment[probe] = "1"
    child.environment = environment
    child.standardOutput = output
    child.standardError = output
    try child.run()
    let deadline = ContinuousClock.now + .seconds(20)
    while child.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    if child.isRunning { child.terminate(); child.waitUntilExit(); XCTFail("Settings get hung"); return }
    let text = try String(contentsOf: log, encoding: .utf8)
    let diagnosis = text.split(separator: "\n").filter { $0.contains("Fatal error") || $0.contains("percent") }.prefix(3).joined(separator: "\n")
    XCTAssertEqual(child.terminationReason, .exit, diagnosis)
    XCTAssertEqual(child.terminationStatus, 0, "Corrupt saved opacity must be repaired before conversion to Int. \(diagnosis)")
  }

  func testUnmatchedLiveSpeechDoesNotClaimTheScriptIsFollowing() async throws {
    let (store, _) = fixture()
    let record = try await store.createScript(title: "Voice status", markdown: "one two three four five six seven eight nine ten eleven twelve")
    var settings = store.settings
    settings.mode = "Voice"
    settings.audioDeviceUID = "qa7-no-hardware"
    let session = store.session
    session.present(record: record, settings: settings)
    session.play(captureAudio: false)
    defer { session.pause() }
    func candidate(_ id: String, _ text: String, _ start: Double) -> SpeechCandidate {
      SpeechCandidate(replacementID: id, generation: 1, locale: Locale(identifier: "en-GB"), text: text,
        range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 100), duration: CMTime(seconds: 1, preferredTimescale: 100)), isFinal: false)
    }
    session.acceptSpeechCandidate(candidate("match", "one two three", 0))
    XCTAssertTrue(session.hasLiveRecognition)
    let position = session.tokenIndex
    session.acceptSpeechCandidate(candidate("unmatched", "purple elephants dance slowly", 2))
    XCTAssertEqual(session.tokenIndex, position)
    XCTAssertEqual(session.readingStatus, "Matching words")
    XCTAssertEqual(session.visibleReadingState, "Matching words", "The persistent compact label must not claim Following while the matcher is holding the script")
  }

  func testEnablingAnExposureToolWorksAfterTheCompactMasterWasTurnedOff() async throws {
    let (store, defaults) = fixture()
    let record = try await store.createScript(title: "Exposure", markdown: "one two three four five")
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    store.uiZoom = 2
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.recordingReadyOverride = true
    let recorder = CameraRecorder(defaults: defaults)
    let (narrow, narrowHost) = await LibraryAX.host(PresenterView(store: store, session: store.session,
      draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder),
      size: .init(width: 720, height: 520))
    defer { LibraryAX.close(narrow) }
    XCTAssertFalse(LibraryAX.named("Tools", in: narrowHost).isEmpty)
    camera.guides.zebras = true
    XCTAssertTrue(camera.previewGuides.zebras)
    camera.toggleExposureCheck()
    XCTAssertFalse(camera.previewGuides.zebras)
    XCTAssertTrue(camera.exposureBypassed)

    let (wide, wideHost) = await LibraryAX.host(CameraExposureSettings(model: camera))
    defer { LibraryAX.close(wide) }
    let tool = try XCTUnwrap(LibraryAX.named("Check brightness · False colour", in: wideHost).first {
      LibraryAX.value($0, "accessibilityRole") == "AXCheckBox"
    })
    _ = LibraryAX.bool(tool, "accessibilityPerformPress")
    XCTAssertTrue(camera.guides.falseColour)
    XCTAssertTrue(camera.previewGuides.falseColour, "The shared exposure control restores a bypassed preview")
  }

  func testUnicodeTakeNameProducesAWritableMoviePath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QA7-take-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let label = String(repeating: "👍🏿", count: 100)
    let path = CameraRecorder.fileURL(in: root, date: Date(timeIntervalSince1970: 0), label: label)
    // Check only the generated path. No camera, audio or recording is started.
    XCTAssertNoThrow(try Data().write(to: path), "The accepted Take name must fit the filesystem after the date and .mov suffix are added")
  }
}
