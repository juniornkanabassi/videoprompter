import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderARoundSeventeenTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("A17-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A17")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    return (store, camera, recorder)
  }

  func testPictureChecksPreserveConfigurationAndKeepMonitorIndependent() {
    let (_, camera, recorder) = fixture()
    camera.guides.axes = true; camera.guides.marker = .init(width: 9, height: 16)
    let before = camera.guides
    camera.toggleFramingGuides()
    XCTAssertFalse(camera.framingIsVisible)
    XCTAssertFalse(camera.previewGuides.axes); XCTAssertNil(camera.previewGuides.marker)
    XCTAssertTrue(camera.monitorGuides.axes); XCTAssertEqual(camera.guides, before)
    camera.toggleFramingGuides(); XCTAssertEqual(camera.previewGuides, before)
    camera.guides = .init()
    camera.toggleFramingGuides(); XCTAssertTrue(camera.previewGuides.thirds)
    camera.cleanView = true
    camera.togglePictureExposureCheck()
    XCTAssertTrue(camera.previewGuides.falseColour); XCTAssertFalse(camera.cleanView)
    camera.guides.zebras = true; camera.guides.zebraLevel = 72
    let exposure = camera.guides
    camera.togglePictureExposureCheck()
    XCTAssertFalse(camera.previewGuides.falseColour); XCTAssertEqual(camera.guides, exposure)
    camera.togglePictureExposureCheck(); XCTAssertEqual(camera.previewGuides, exposure)
    recorder.phase = .recording
    camera.togglePictureExposureCheck(); XCTAssertTrue(camera.exposureBypassed)
  }

  func testPictureRowActsDirectlyAtEverySizeAndModeNameNeverAbbreviates() async throws {
    let (store, camera, recorder) = fixture()
    let record = try await store.createScript(title: "Picture", markdown: String(repeating: "Read these words. ", count: 100))
    store.settings.mode = "Manual"
    store.session.present(record: record, settings: store.settings)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
      let (window, host) = await LibraryAX.host(view, size: .init(width: 720, height: 520))
      host.sizingOptions = []; host.frame = .init(x: 0, y: 0, width: 720, height: 520)
      for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      for name in ["Zebras", "False colour", "Guides", "Mic level", "Legend", "Camera", "Clean", "Tools"] {
        let action = try XCTUnwrap(LibraryAX.named(name, in: host).first, name)
        XCTAssertTrue(LibraryAX.bool(action, "isAccessibilityEnabled"))
        let frame = try XCTUnwrap(action.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertGreaterThanOrEqual(frame.height, 24 * zoom)
        let local = host.convert(window.convertFromScreen(frame), from: nil)
        XCTAssertGreaterThanOrEqual(local.minX, -1)
        XCTAssertLessThanOrEqual(local.maxX, 721, "Picture control must fit at \(zoom): \(name)")
      }
      let guide = try XCTUnwrap(LibraryAX.named("Guides", in: host).first)
      let before = camera.framingIsVisible
      XCTAssertTrue(LibraryAX.bool(guide, "accessibilityPerformPress"))
      XCTAssertNotEqual(camera.framingIsVisible, before)
      let exposureButton = try XCTUnwrap(LibraryAX.named("False colour", in: host).first)
      let exposureBefore = camera.previewGuides.falseColour
      XCTAssertTrue(LibraryAX.bool(exposureButton, "accessibilityPerformPress"))
      XCTAssertNotEqual(camera.previewGuides.falseColour, exposureBefore)
      XCTAssertTrue(LibraryAX.named("Tools section", in: host).isEmpty, "A picture check must not open the full Tools form")
      let status = try XCTUnwrap(LibraryAX.named("Reading status", in: host).first)
      XCTAssertTrue(LibraryAX.value(status, "accessibilityValue").contains("Automatic scroll"))
      camera.exposureBypassed = true
      for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
      let text = try XCTUnwrap(views(host).compactMap { $0 as? NSTextView }.first)
      let height = try XCTUnwrap(text.enclosingScrollView).frame.height
      print("A17_GEOMETRY zoom=\(zoom) reading=\(height)")
      XCTAssertGreaterThanOrEqual(height, 520 * 0.65)
      LibraryAX.close(window)
    }
  }

  func testMicrophoneVolumeStepsAndResetAreVisibleAndWork() async throws {
    var gain = 1.37
    let (window, host) = await LibraryAX.host(MicrophoneVolumeControl(value: Binding(get: { gain }, set: { gain = $0 })), size: .init(width: 500, height: 260))
    defer { LibraryAX.close(window) }
    let up = try XCTUnwrap(LibraryAX.named("Increase microphone volume by 1 percent", in: host).first)
    XCTAssertTrue(LibraryAX.bool(up, "accessibilityPerformPress")); XCTAssertEqual(gain, 1.38, accuracy: 0.0001)
    let down = try XCTUnwrap(LibraryAX.named("Decrease microphone volume by 1 percent", in: host).first)
    XCTAssertTrue(LibraryAX.bool(down, "accessibilityPerformPress")); XCTAssertEqual(gain, 1.37, accuracy: 0.0001)
    let reset = try XCTUnwrap(LibraryAX.named("Reset microphone volume to 100 percent", in: host).first)
    XCTAssertTrue(LibraryAX.bool(reset, "accessibilityPerformPress")); XCTAssertEqual(gain, 1)
    XCTAssertEqual(MicrophoneVolumeControl.stepped(4, by: 1), 4)
    XCTAssertEqual(MicrophoneVolumeControl.stepped(0.25, by: -1), 0.25)
  }

  func testNoReceivedPictureMeansNoClaimedOutputDimensions() {
    let (_, camera, recorder) = fixture()
    camera.refreshDevices(); camera.selectedUID = camera.devices.first?.uid; camera.recordingReadyOverride = false
    let output = recorder.outputSummary(camera: camera)
    XCTAssertTrue(output.contains("Orientation unknown")); XCTAssertTrue(output.contains("resolution unknown"))
  }
}

extension AppearanceSnapshotTests {
  func testRoundSeventeenBuilderA() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("A17Snapshot-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A17Snapshot")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    store.settings.mode = "Manual"
    let record = try await store.createScript(title: "Quick picture checks", markdown: String(repeating: "Read at your own pace. ", count: 100))
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder; camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    let scheme: ColorScheme = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let appearance = scheme == .dark ? "dark" : "light"
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      for state in ["ready", "camera", "exposure", "failed", "clean", "recording", "saved"] {
        let recorder = CameraRecorder(defaults: defaults)
        camera.recorder = recorder
        camera.displayMode = state == "camera" ? .videoOnly : .prompterWithVideo
        camera.cleanView = state == "clean"; camera.guides.falseColour = state == "exposure"
        recorder.phase = state == "recording" ? .recording : .idle
        recorder.phase = .recording; recorder.errorMessage = state == "failed" ? "Camera disconnected." : nil
        recorder.phase = state == "recording" ? .recording : .idle
        if state == "saved" { recorder.savedTake = URL(fileURLWithPath: "/tmp/Practice take.mov") }
        let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), hasScript: state != "camera", camera: camera, startsCamera: false, recorder: recorder)
        try await snapshot(view, name: "a17-\(state)-\(Int(zoom * 100))-\(appearance)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
      recorder.phase = .recording; recorder.errorMessage = nil; recorder.phase = .idle; camera.cleanView = false
      let view = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
      try await snapshot(view.toolsSurface, name: "a17-tools-\(Int(zoom * 100))-\(appearance)", size: .init(width: 640, height: 600), scheme: scheme, destination: URL(fileURLWithPath: output))
      try await snapshot(MicrophonePage(store: store, compact: true, startsMeter: false, recorder: recorder).uiZoom(zoom), name: "a17-mic-\(Int(zoom * 100))-\(appearance)", size: .init(width: 640, height: 600), scheme: scheme, destination: URL(fileURLWithPath: output))
    }
  }
}
