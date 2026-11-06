import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class RecordingRoundThreeTests: XCTestCase {
  func testExposureBypassPreservesConfiguredToolsAndCameraPreferences() {
    let defaults = freshDefaults("ExposureBypass")
    let camera = CameraModel(defaults: defaults)
    camera.selectedUID = "fixture"
    camera.guides.zebras = true
    camera.guides.falseColour = true
    camera.guides.zebraLevel = 75
    let saved = camera.guides
    camera.exposureBypassed = true
    XCTAssertFalse(camera.previewGuides.zebras)
    XCTAssertFalse(camera.previewGuides.falseColour)
    XCTAssertEqual(camera.guides, saved)
    camera.exposureBypassed = false
    XCTAssertEqual(camera.previewGuides, saved)
    XCTAssertEqual(CameraModel(defaults: defaults).guides, saved)
    camera.applySkinExposurePreset()
    XCTAssertEqual(camera.guides.zebraLevel, 45)
    XCTAssertEqual(camera.guides.zebraRange, 5)
    XCTAssertTrue(camera.previewGuides.zebras)
    XCTAssertFalse(camera.previewGuides.falseColour)
  }

  func testNewFailedAttemptNeverShowsOlderTakeAsItsReceipt() async {
    let defaults = freshDefaults("RecordingReceipt")
    let recorder = CameraRecorder(defaults: defaults)
    recorder.savedTake = URL(fileURLWithPath: "/tmp/previous-take.mov")
    let camera = CameraModel(defaults: defaults)
    camera.selectedUID = nil
    await recorder.start(camera: camera) // Stops before permissions or hardware are opened.
    XCTAssertNil(recorder.savedTake)
    XCTAssertEqual(recorder.phase, .idle)
    XCTAssertNotNil(recorder.takeFailure)
    XCTAssertEqual(recorder.recovery, .camera)
    recorder.errorMessage = nil
    XCTAssertNotNil(recorder.takeFailure, "Dismissing an alert must not erase the persistent failed-take result")
  }

  func testClosingAnInputTestDoesNotClearTheLiveRecordingMeter() {
    let recorder = CameraRecorder(defaults: freshDefaults("RecordingMeter"))
    recorder.phase = .recording
    recorder.inputMeter.show(channelPeaks: [0.25, 0.99])
    recorder.stopInputTest()
    XCTAssertEqual(recorder.inputMeter.channelPeaks, [0.25, 0.99])
  }

  func testSavedRotationAppearsInOutputSummary() {
    let defaults = freshDefaults("RecordingRotation")
    let camera = CameraModel(defaults: defaults)
    camera.guides.rotation = .quarter
    let recorder = CameraRecorder(defaults: defaults)
    XCTAssertTrue(recorder.outputSummary(camera: camera).contains("90° saved rotation"))
  }
  func testPresenterEditorLinksUseReadableScriptColourInLightAppearance() async throws {
    _ = NSApplication.shared
    let defaults = freshDefaults("PresenterLinks")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Links", markdown: "A [readable link](https://example.com).")
    store.session.present(record: record, settings: store.settings)
    let draft = PresenterDraft(record: record)
    draft.begin(session: store.session)
    let host = NSHostingView(rootView: PresenterEditorView(session: store.session, draft: draft,
      settings: store.settings, sideInset: 20, onUnsupportedEdit: {}).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    func texts(_ node: NSView) -> [NSTextView] { (node as? NSTextView).map { [$0] } ?? node.subviews.flatMap(texts) }
    let text = try XCTUnwrap(texts(host).first)
    let colour = try XCTUnwrap(text.linkTextAttributes?[.foregroundColor] as? NSColor).usingColorSpace(.sRGB)
    XCTAssertGreaterThan(try XCTUnwrap(colour).redComponent, 0.9)
    XCTAssertEqual(text.linkTextAttributes?[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
  }

  func testRecoveryMatchesFailureInsteadOfSendingEveryErrorToPrivacy() {
    XCTAssertEqual(CameraRecorder.recovery(for: NSError(domain: "CameraRecorder", code: 2)), .camera)
    XCTAssertEqual(CameraRecorder.recovery(for: CocoaError(.fileWriteOutOfSpace)), .storage)
    XCTAssertEqual(CameraRecorder.recovery(for: CocoaError(.featureUnsupported)), .format)
    XCTAssertEqual(CameraRecorder.recovery(for: NSError(domain: "Unexpected", code: 1)), .retry)
  }

}
