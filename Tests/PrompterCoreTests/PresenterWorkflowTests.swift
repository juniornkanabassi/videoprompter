import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class PresenterWorkflowTests: XCTestCase {
  func testPresenterKeysWorkAcrossNoneditingResponders() throws {
    _ = NSApplication.shared
    let panel = PresenterPanel(captureVisible: false)
    defer { panel.close() }
    var passages = 0
    panel.onPassageKey = { _ in passages += 1; return true }
    let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    text.isEditable = false; text.isSelectable = true; text.string = "Choose these words"
    panel.contentView = text
    XCTAssertTrue(panel.makeFirstResponder(text))
    XCTAssertTrue(panel.handlePassageKey(right))
    text.isEditable = true
    XCTAssertFalse(panel.handlePassageKey(right), "An actual text editor keeps native arrow keys")
    text.isEditable = false
    let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    panel.contentView = slider
    XCTAssertTrue(panel.makeFirstResponder(slider))
    XCTAssertTrue(panel.handlePassageKey(right))
    XCTAssertEqual(passages, 2)
    XCTAssertTrue(panel.makeFirstResponder(panel))
    XCTAssertTrue(panel.handlePassageKey(right))
    XCTAssertEqual(passages, 3)
  }

  func testRecordingAudioReportsEachChannelAndExpiresOldSamples() {
    XCTAssertEqual(RecordingAudioTest.channelPeaks(samples: [0.1, -0.8, 0.3, 0.4], channels: 2), [0.3, 0.8])
    XCTAssertEqual(RecordingAudioTest.channelPeaks(samples: [.nan, .infinity, 0.4, -0.2], channels: 2), [0.4, 0.2])
    let meter = InputMeter()
    XCTAssertFalse(meter.isFresh())
    meter.show(channelPeaks: [0, 0.5])
    XCTAssertTrue(meter.isFresh())
    XCTAssertEqual(meter.peakDBFS, AudioCapture.decibels(fullScalePeak: 0.5))
    XCTAssertFalse(meter.isFresh(at: ProcessInfo.processInfo.systemUptime + 2))
    meter.reset()
    XCTAssertFalse(meter.isFresh())
    XCTAssertTrue(meter.channelPeaks.isEmpty)
  }

  func testPreviewMirrorDoesNotChangeSavedVideoAndOutputPreferencePersists() {
    let defaults = freshDefaults("SeparateMirroring")
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    camera.mirrored = true
    XCTAssertFalse(recorder.mirrorSavedVideo)
    XCTAssertTrue(recorder.outputSummary(camera: camera).contains("unmirrored output"))
    recorder.mirrorSavedVideo = true
    XCTAssertTrue(CameraRecorder(defaults: defaults).mirrorSavedVideo)
    camera.mirrored = false
    XCTAssertTrue(recorder.mirrorSavedVideo)
  }

  func testPreparingNeverSaysSavingAndMissingCameraCannotRecord() async {
    XCTAssertEqual(CameraRecorder.Phase.preparing.message, "Preparing camera and microphone…")
    XCTAssertEqual(CameraRecorder.Phase.saving.message, "Saving recording…")
    let defaults = freshDefaults("RecordingReadiness")
    let camera = CameraModel(defaults: defaults)
    camera.authorization = .authorized
    camera.selectedUID = "missing-camera"
    XCTAssertFalse(camera.isReadyToRecord)
    let recorder = CameraRecorder(defaults: defaults)
    await recorder.start(camera: camera)
    XCTAssertEqual(recorder.phase, .idle)
    XCTAssertFalse(recorder.isRecording)
    XCTAssertNil(recorder.lastFile)
    XCTAssertTrue(recorder.errorMessage?.contains("camera") == true)
  }

  func testTakeLabelsCannotCreatePathsAndLastTakeSurvivesRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = CameraRecorder.fileURL(in: root, label: "  Studio / intro: take 1  ")
    XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
    XCTAssertTrue(url.lastPathComponent.hasPrefix("Studio   intro  take 1"))
    try Data("fixture".utf8).write(to: url)
    let defaults = freshDefaults("LastTake")
    defaults.set(url.path, forKey: "lastRecording")
    XCTAssertEqual(CameraRecorder(defaults: defaults).lastFile, url)
  }

  func testReducedTransparencyUsesOpaqueBackdropWithoutChangingSetting() {
    XCTAssertEqual(PresenterView.backdropOpacity(saved: 0.25, reduceTransparency: true), 1)
    XCTAssertEqual(PresenterView.backdropOpacity(saved: 0.25, reduceTransparency: false), 0.25)
  }

  func testBothCloseRoutesKeepAnActiveTakeVisibleUntilAChoice() {
    _ = NSApplication.shared
    let defaults = freshDefaults("CloseActiveTake")
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    let controller = PresenterController(camera: camera, recorder: recorder, frameDefaults: nil)
    let panel = PresenterPanel(captureVisible: false)
    controller.panel = panel
    defer { recorder.phase = .idle; panel.close() }
    for phase in [CameraRecorder.Phase.preparing, .waitingForFrames, .recording, .saving] {
      recorder.phase = phase
      controller.asksToCloseRecording = false
      XCTAssertFalse(controller.windowShouldClose(panel))
      XCTAssertTrue(controller.asksToCloseRecording)
      controller.asksToCloseRecording = false
      controller.closeNow()
      XCTAssertTrue(controller.asksToCloseRecording)
      XCTAssertEqual(recorder.phase, phase)
    }
  }

  func testKeepingRecordingAndMinimisingRetainAStopSurface() {
    _ = NSApplication.shared
    let defaults = freshDefaults("RecordingStopSurface")
    let camera = CameraModel(defaults: defaults)
    let recorder = CameraRecorder(defaults: defaults)
    let controller = PresenterController(camera: camera, recorder: recorder, frameDefaults: nil)
    let panel = PresenterPanel(captureVisible: false)
    controller.panel = panel
    recorder.phase = .recording
    controller.keepRecordingAndClose()
    let status = NSApp.windows.filter { $0.title == "Camera Recording" }
    XCTAssertEqual(status.count, 1)
    XCTAssertNotNil(status.first?.contentView)
    XCTAssertEqual(recorder.phase, .recording)
    controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: panel))
    XCTAssertEqual(NSApp.windows.filter { $0.title == "Camera Recording" }.count, 1, "Minimising reuses the recording surface")
    XCTAssertEqual(status.first?.alphaValue, 0, "The test guard keeps every window invisible")
    recorder.phase = .idle
    status.forEach { $0.close() }
    panel.close()
  }

  func testPresetSummaryMatchingAndModification() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("PresetFeedback")))
    store.settings.mode = "Manual"; store.settings.speed = 140; store.settings.fontSize = 48
    store.savePreset(named: "Studio")
    let preset = try XCTUnwrap(store.presets.first)
    XCTAssertTrue(preset.readingSummary.contains("140 words/min"))
    XCTAssertTrue(store.matchesPreset(preset))
    store.settings.fontSize = 62
    XCTAssertFalse(store.matchesPreset(preset))
    store.settings.audioDeviceUID = "keep-voice"
    store.applyPreset(preset)
    XCTAssertTrue(store.matchesPreset(preset))
    XCTAssertEqual(store.settings.audioDeviceUID, "keep-voice")
  }
}
