import AVFoundation
import PrompterCore
import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class RoundFiveBuilderATests: XCTestCase {
  func testWaitingForFirstFrameIsBusyButNeverRecording() {
    let recorder = CameraRecorder(defaults: freshDefaults("R5Waiting"))
    recorder.phase = .waitingForFrames
    XCTAssertTrue(recorder.isBusy)
    XCTAssertTrue(recorder.isCapturing)
    XCTAssertTrue(recorder.settingsLocked)
    XCTAssertFalse(recorder.isRecording)
    XCTAssertNil(recorder.startedAt)
    recorder.phase = .recording
    XCTAssertTrue(recorder.isRecording)
  }
  func testDefaultAndExplicitMicrophonesUseSameResolver() {
    let devices = [AudioInputDevice(id: 1, uid: "one", name: "One"), AudioInputDevice(id: 2, uid: "two", name: "Two")]
    XCTAssertEqual(AudioCapture.resolveInput(nil, devices: devices, defaultID: 2)?.uid, "two")
    XCTAssertEqual(AudioCapture.resolveInput("one", devices: devices, defaultID: 2)?.uid, "one")
    XCTAssertNil(AudioCapture.resolveInput("missing", devices: devices, defaultID: 2))
    XCTAssertNil(AudioCapture.resolveInput(nil, devices: [], defaultID: 2))
  }
  func testDroppedPictureAndSoundAreBothPersistentWarnings() {
    let recorder = CameraRecorder(defaults: freshDefaults("R5Warnings"))
    XCTAssertNil(recorder.qualityWarning)
    recorder.droppedFrames = 12
    recorder.droppedAudioBuffers = 3
    XCTAssertTrue(recorder.qualityWarning?.contains("12") == true)
    XCTAssertTrue(recorder.qualityWarning?.contains("Sound dropped") == true)
    recorder.errorMessage = nil
    XCTAssertNotNil(recorder.qualityWarning)
  }
  func testWorstCaseIncludesDarkAndIntermediatePicturesAndDimRuns() {
    XCTAssertEqual(ReadingContrast.worstCase(textHex: "#000000", textOpacity: 1, backgroundHex: "#000000", darkness: 0), 1)
    XCTAssertEqual(ReadingContrast.worstCase(textHex: "#808080", textOpacity: 1, backgroundHex: "#000000", darkness: 0.2), 1)
    XCTAssertLessThan(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 0.42, backgroundHex: "#000000", darkness: 0.5), 3)
    XCTAssertGreaterThan(ReadingContrast.worstCase(textHex: "#FFFFFF", textOpacity: 0.5, backgroundHex: "#000000", darkness: 1), 4.5)
  }
  func testHealthStatesDistinguishClippingSilenceAndRecovery() {
    XCTAssertEqual(RecordingHealth.state(clipping: true, fresh: true), .clipping)
    XCTAssertEqual(RecordingHealth.state(clipping: false, fresh: false), .silence)
    XCTAssertEqual(RecordingHealth.state(clipping: false, fresh: true), .receiving)
  }
  func testDefaultMicrophoneSelectionReachesBothTestAndVoiceFollowResolver() {
    let session = SessionStore()
    var requests: [String?] = []
    session.resolveAudioInput = { uid in requests.append(uid); return nil }
    session.startMicrophoneTest(deviceUID: nil, gain: 1)
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(requests[0])
    var settings = PrompterSettings(); settings.mode = "Voice"; settings.audioDeviceUID = nil
    let record = ScriptRecord(metadata: ScriptMetadata(title: "Test", fileName: "test.md"), markdown: "Reading words")
    session.present(record: record, settings: settings)
    session.play()
    XCTAssertEqual(requests.count, 2)
    XCTAssertNil(requests[1])
  }

  func testDismissingAnAlertWhileSavingCannotEraseAnInterruptedTake() {
    let recorder = CameraRecorder(defaults: freshDefaults("R5Interrupted"))
    recorder.phase = .recording
    recorder.errorMessage = "The camera disconnected."
    recorder.phase = .saving
    recorder.errorMessage = nil
    recorder.savedTake = URL(fileURLWithPath: "/tmp/partial.mov")
    recorder.phase = .idle
    XCTAssertEqual(recorder.takeFailure, "The camera disconnected.")
    XCTAssertTrue(recorder.qualityWarning?.contains("camera disconnected") == true)
  }

}
