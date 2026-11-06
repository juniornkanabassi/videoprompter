import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderARoundThirteenTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A13")
    return (flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)),
      CameraModel(defaults: defaults), CameraRecorder(defaults: defaults))
  }

  func testExposureSwitchesDescribeEffectAndRestoreItAcrossSurfaces() async throws {
    let (store, camera, recorder) = fixture()
    camera.guides.zebras = true; camera.guides.falseColour = true
    for key in [\CameraGuides.zebras, \CameraGuides.falseColour] {
      camera.exposureBypassed = true
      XCTAssertFalse(camera.exposureBinding(key).wrappedValue)
      XCTAssertEqual(camera.exposureCheckState, "Aids bypassed")
      camera.exposureBinding(key).wrappedValue = true
      XCTAssertTrue(camera.previewGuides[keyPath: key])
      XCTAssertEqual(camera.exposureCheckState, "Aids visible")
      camera.cleanView = true
      XCTAssertFalse(camera.exposureBinding(key).wrappedValue)
      XCTAssertEqual(camera.exposureCheckState, "Hidden in Clean view")
      camera.exposureBinding(key).wrappedValue = true
      XCTAssertFalse(camera.cleanView)
      XCTAssertTrue(camera.previewGuides[keyPath: key])
    }
    let actions = ControlActions(store: store, camera: camera, recorder: recorder)
    camera.exposureBypassed = true
    _ = await actions.handle("camera_guides", ["zebras": "on"])
    XCTAssertTrue(camera.previewGuides.zebras, "An explicit CLI on also restores an already configured tool")
    camera.toggleExposureCheck()
    XCTAssertTrue(camera.guides.zebras)
    XCTAssertTrue(camera.guides.falseColour)
    XCTAssertFalse(camera.previewGuides.zebras)
    camera.toggleExposureCheck()
    XCTAssertTrue(camera.previewGuides.zebras)
  }

  func testAudioScaleColoursMeetSmallTextContrast() throws {
    func luminance(_ colour: NSColor) throws -> Double {
      let c = try XCTUnwrap(colour.usingColorSpace(.sRGB))
      func linear(_ value: CGFloat) -> Double {
        let channel = Double(value)
        return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
      }
      return linear(c.redComponent) * 0.2126 + linear(c.greenComponent) * 0.7152 + linear(c.blueComponent) * 0.0722
    }
    for (scheme, background) in [(ColorScheme.light, NSColor.white), (.dark, NSColor(white: 0.11, alpha: 1))] {
      let foreground = try luminance(NSColor(InputLevelMeter.scaleColour(scheme)))
      let back = try luminance(background)
      XCTAssertGreaterThanOrEqual((max(foreground, back) + 0.05) / (min(foreground, back) + 0.05), 4.5)
    }
  }

  func testFailureSummaryKeepsTheCause() {
    XCTAssertEqual(RecordingReceipt.shortCause("No completed take was saved. Camera disconnected. Choose camera."), "Camera disconnected")
    XCTAssertEqual(RecordingReceipt.shortCause("Sound dropped from the file (2 times)."), "Sound dropped from the file (2 times).")
  }

  func testSavingDoesNotShowLiveMicrophoneAdviceButRetainsDrops() async throws {
    let (_, camera, recorder) = fixture()
    recorder.phase = .saving
    recorder.droppedAudioBuffers = 2
    let (window, host) = await LibraryAX.host(RecordingStatusPanel(recorder: recorder, camera: camera, dismiss: {}))
    defer { recorder.phase = .idle; LibraryAX.close(window) }
    let labels = LibraryAX.elements(host).map { LibraryAX.value($0, "accessibilityLabel") + LibraryAX.value($0, "accessibilityValue") }.joined(separator: " ")
    XCTAssertTrue(labels.contains("Saving"))
    XCTAssertTrue(labels.contains("Sound dropped from the file (2 times)"))
    for text in ["Check the microphone", "Waiting for sound", "Too loud", "Mic:"] { XCTAssertFalse(labels.contains(text), text) }
  }

  func testCompactFailureShowsCauseAndOneRecoveryAction() async throws {
    let (_, camera, recorder) = fixture()
    recorder.phase = .preparing
    recorder.errorMessage = "No completed take was saved. Camera disconnected. Reconnect it."
    recorder.phase = .idle
    let (window, host) = await LibraryAX.host(RecordingReceipt(recorder: recorder, camera: camera, compact: true))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.named("Take not saved · Camera disconnected", in: host).isEmpty)
    XCTAssertFalse(LibraryAX.named("Try recording again", in: host).isEmpty)
  }

  func testOwnedVocabularyUsesOneNamePerTask() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let paths = ["Sources/VideoPrompter/App", "Sources/VideoPrompter/Camera", "Sources/VideoPrompter/Settings", "Sources/VideoPrompter/Control"]
    var files = [root.appendingPathComponent("Sources/VideoPrompter/Presenter/PresenterController.swift"), root.appendingPathComponent("README.md")]
    for path in paths {
      files += (FileManager.default.enumerator(at: root.appendingPathComponent(path), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CameraPicker.swift" }
    }
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      for stale in ["Exposure on/off", "Exposure on\"", "Exposure off\"", "Sound OK", "Show recording folder in Finder", "Button(\"Recordings folder\"", "? \"Auto\" :"] {
        XCTAssertFalse(text.contains(stale), "\(file.lastPathComponent): \(stale)")
      }
    }
  }

  func testSettingsKeepNavigationBesideTopAlignedContent() async throws {
    let (store, _, _) = fixture()
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(AppSettingsView(store: store, selectedTab: .general), size: .init(width: 900, height: 700))
      defer { LibraryAX.close(window) }
      host.sizingOptions = []
      window.setContentSize(.init(width: 900, height: 700))
      host.frame = .init(x: 0, y: 0, width: 900, height: 700)
      for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      XCTAssertFalse(LibraryAX.named("Camera & Recording", in: host).isEmpty)
      let size = try XCTUnwrap(LibraryAX.named("Interface size", in: host).first { $0.value(forKey: "accessibilityFrame") is NSValue })
      let frame = try XCTUnwrap(size.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      let bounds = window.convertToScreen(host.bounds)
      XCTAssertGreaterThan(frame.minX, bounds.minX + 200)
      XCTAssertGreaterThan(frame.maxY, bounds.maxY - 180, "Content must start near the top at \(zoom)")
    }
  }

  func testPresenterToolsKeepOrderAndRemainPresentAtEverySize() async throws {
    let (store, camera, recorder) = fixture()
    let record = try await store.createScript(title: "Order", markdown: String(repeating: "One two three four five. ", count: 50))
    store.settings.mode = "Manual"; store.session.present(record: record, settings: store.settings)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    let names = ["Tools"]
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let (window, host) = await LibraryAX.host(PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder), size: .init(width: 720, height: 520))
      defer { LibraryAX.close(window) }
      let buttons = LibraryAX.elements(host)
      let actual = buttons.map { LibraryAX.value($0, "accessibilityLabel").isEmpty ? LibraryAX.value($0, "accessibilityTitle") : LibraryAX.value($0, "accessibilityLabel") }.filter { names.contains($0) }
      XCTAssertEqual(actual, names, "Only wrapping changes at \(zoom)")
      let bounds = window.convertToScreen(host.bounds)
      for button in buttons where names.contains(LibraryAX.value(button, "accessibilityLabel")) {
        let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX, "Whole controls wrap inside the presenter")
      }
      let status = try XCTUnwrap(LibraryAX.named("Reading status", in: host).first)
      XCTAssertTrue(LibraryAX.value(status, "accessibilityValue").contains("Automatic scroll"))
    }
  }
}

extension AppearanceSnapshotTests {
  func testRoundThirteenBuilderA() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A13Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      if let requested = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"], requested != name { continue }
      for zoom in [1.0, 1.5, 2.0] {
        store.uiZoom = zoom
        try await snapshot(AppSettingsView(store: store, selectedTab: .general), name: "a13-settings-\(Int(zoom * 100))-\(name)", size: .init(width: 900, height: 700), scheme: scheme, destination: URL(fileURLWithPath: output))
        try await snapshot(InputLevelMeter(peakDBFS: -12, isClipping: false).padding().uiZoom(zoom), name: "a13-meter-\(Int(zoom * 100))-\(name)", size: .init(width: 700, height: 100), scheme: scheme, destination: URL(fileURLWithPath: output))
        recorder.phase = .saving
        try await snapshot(RecordingStatusPanel(recorder: recorder, camera: camera, zoom: zoom, dismiss: {}), name: "a13-saving-\(Int(zoom * 100))-\(name)", size: .init(width: 700, height: 300), scheme: scheme, destination: URL(fileURLWithPath: output))
        recorder.phase = .idle
      }
    }
  }
}
