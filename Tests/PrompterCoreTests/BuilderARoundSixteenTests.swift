import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class BuilderARoundSixteenTests: XCTestCase {
  private func fixture() -> (AppStore, CameraModel, CameraRecorder, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("A16-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A16")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    store.settings.mode = "Manual"; store.settings.audioDeviceUID = nil
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.recorder = recorder
    return (store, camera, recorder, defaults)
  }

  func testSetupRecoveryRestoresWholeConfigurationAndProtectsAnActiveTake() throws {
    let (store, camera, recorder, _) = fixture()
    camera.selectedUID = "disconnected-previous-camera"
    camera.guides.thirds = true; camera.guides.zebras = true
    camera.mirrored = true; camera.cleanView = true; camera.exposureBypassed = true
    camera.displayMode = .prompterWithVideo
    recorder.preset = .high; recorder.usesSeparateMicrophone = true
    recorder.microphoneUID = "previous-mic"; recorder.floatAudio = true; recorder.mirrorSavedVideo = true
    let before = store.settings, guides = camera.guides
    var setup = ShootSetup(name: "Try this")
    setup.reading.mode = "Manual"; setup.reading.audioDeviceUID = nil; setup.reading.fontSize = 72
    XCTAssertTrue(store.applyShootSetup(setup, camera: camera, recorder: recorder, microphones: []))
    XCTAssertEqual(store.appliedShootSetupName, "Try this")
    var missing = setup; missing.cameraUID = "absent"
    XCTAssertFalse(store.applyShootSetup(missing, camera: camera, recorder: recorder, microphones: []))
    recorder.phase = .recording
    XCTAssertFalse(store.restorePreviousShootSetup(camera: camera, recorder: recorder))
    XCTAssertEqual(store.settings.fontSize, 72)
    recorder.phase = .idle
    XCTAssertTrue(store.restorePreviousShootSetup(camera: camera, recorder: recorder))
    XCTAssertEqual(store.settings, before); XCTAssertEqual(camera.guides, guides)
    XCTAssertEqual(camera.selectedUID, "disconnected-previous-camera")
    XCTAssertTrue(camera.mirrored); XCTAssertTrue(camera.cleanView); XCTAssertTrue(camera.exposureBypassed)
    XCTAssertEqual(camera.displayMode, .prompterWithVideo); XCTAssertEqual(recorder.preset, .high)
    XCTAssertTrue(recorder.floatAudio); XCTAssertTrue(recorder.mirrorSavedVideo)
    XCTAssertTrue(recorder.usesSeparateMicrophone); XCTAssertEqual(recorder.microphoneUID, "previous-mic")
    XCTAssertNil(store.previousShootSetup)
  }

  func testSaveRepairsDuplicateIDsAndUnresolvedGuidesTransferOnlyOnce() throws {
    let (store, camera, _, defaults) = fixture()
    let first = ShootSetup(name: "One")
    var second = ShootSetup(name: "Two"); second.id = first.id
    store.shootSetups = [first, second]
    XCTAssertEqual(Set(store.shootSetups.map(\.id)).count, 2)
    let saved = try JSONDecoder().decode([ShootSetup].self, from: XCTUnwrap(defaults.data(forKey: "shootSetups")))
    XCTAssertEqual(Set(saved.map(\.id)).count, 2)
    camera.guides.thirds = true
    camera.selectedUID = "first-camera"
    XCTAssertTrue(camera.guides.thirds)
    camera.selectedUID = "different-camera"
    XCTAssertFalse(camera.guides.thirds)
    camera.selectedUID = "first-camera"
    XCTAssertTrue(camera.guides.thirds)
  }



  func testShootSetupErrorHasNormalTextContrastInBothAppearances() async throws {
    let (store, camera, recorder, _) = fixture()
    let message = "The camera for Studio is unavailable. Connect it before applying this setup."
    store.shootSetupError = message
    for scheme in [ColorScheme.light, .dark] {
      let (window, host) = await LibraryAX.host(Form {
        ShootSetupSection(store: store, camera: camera, recorder: recorder)
      }.formStyle(.grouped).environment(\.colorScheme, scheme), size: .init(width: 700, height: 800))
      defer { LibraryAX.close(window) }
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      host.layoutSubtreeIfNeeded()
      let text = try XCTUnwrap(LibraryAX.named(message, in: host).first)
      let screen = try XCTUnwrap(text.value(forKey: "accessibilityFrame") as? NSValue).rectValue
      let frame = host.convert(window.convertFromScreen(screen), from: nil)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
      let sx = CGFloat(bitmap.pixelsWide) / host.bounds.width, sy = CGFloat(bitmap.pixelsHigh) / host.bounds.height
      let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
      var counts: [Int: Int] = [:]
      for y in max(0, Int(top * sy))..<min(bitmap.pixelsHigh, Int((top + frame.height) * sy)) {
        for x in max(0, Int(frame.minX * sx))..<min(bitmap.pixelsWide, Int(frame.maxX * sx)) {
          let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          let rgb = (Int((c.redComponent * 255).rounded()) << 16) | (Int((c.greenComponent * 255).rounded()) << 8) | Int((c.blueComponent * 255).rounded())
          counts[rgb, default: 0] += 1
        }
      }
      func luminance(_ rgb: Int) -> Double {
        let channels = [rgb >> 16, (rgb >> 8) & 255, rgb & 255].map { Double($0) / 255 }
        let v = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722
      }
      let background = try XCTUnwrap(counts.max { $0.value < $1.value }?.key), bg = luminance(background)
      let foreground = try XCTUnwrap(counts.filter { $0.value >= 8 }.keys.max { abs(luminance($0) - bg) < abs(luminance($1) - bg) })
      let ratio = (max(bg, luminance(foreground)) + 0.05) / (min(bg, luminance(foreground)) + 0.05)
      XCTAssertGreaterThanOrEqual(ratio, 4.5)
      print("SETUP_ERROR_CONTRAST \(scheme) \(ratio) foreground=\(String(foreground, radix: 16)) background=\(String(background, radix: 16))")
    }
  }

  func testFormatAvailabilityUsesTheExecutingEditorsResponderAndCaptureCheckIsComplete() async throws {
    let (_, camera, recorder, _) = fixture()
    let (window, host) = await LibraryAX.host(FormattedMarkdownEditor(markdown: .constant("Words"), fontName: "Helvetica", fontSize: 18))
    defer { LibraryAX.close(window) }
    func editor(_ view: NSView) -> NSTextView? {
      (view as? NSTextView) ?? view.subviews.lazy.compactMap { editor($0) }.first
    }
    let text = try XCTUnwrap(editor(host))
    window.makeFirstResponder(text)
    XCTAssertTrue(FormattedMarkdownEditor.canFormat(in: window))
    text.isEditable = false
    XCTAssertFalse(FormattedMarkdownEditor.canFormat(in: window))
    XCTAssertFalse(FormattedMarkdownEditor.formatFocused(.bold, in: window))
    text.isEditable = true; window.makeFirstResponder(window)
    XCTAssertFalse(FormattedMarkdownEditor.canFormat(in: window))
    for format in RecordingPreset.allCases {
      recorder.preset = format
      let check = recorder.preRecordConfirmation(camera: camera)
      for item in ["Orientation unknown", "resolution unknown", "Frame rate unknown", "Mic:", "saved video", CameraRecorder.recordingsFolder().path] {
        XCTAssertTrue(check.contains(item), item)
      }
    }
  }
}

extension AppearanceSnapshotTests {
  func testRoundSixteenBuilderA() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("A16Snapshot-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("A16Snapshot")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    store.settings.mode = "Manual"; store.settings.audioDeviceUID = nil
    let record = try await store.createScript(title: "A clear status", markdown: String(repeating: "Read at your own pace. ", count: 100))
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.displayMode = .prompterWithVideo; camera.recordingReadyOverride = true
    let scheme: ColorScheme = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let appearance = scheme == .dark ? "dark" : "light"
    for zoom in [1.0, 1.5, 2.0] {
      store.uiZoom = zoom
      let draft = PresenterDraft(record: record)
      for state in ["ready", "editing", "recording"] {
        if state == "editing" { draft.begin(session: store.session) } else { draft.cancel(resuming: false) }
        recorder.phase = state == "recording" ? .recording : .idle
        try await snapshot(PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder), name: "a16-\(state)-\(Int(zoom * 100))-\(appearance)", size: .init(width: 720, height: 520), scheme: scheme, destination: URL(fileURLWithPath: output))
      }
      recorder.phase = .idle
      var saved = ShootSetup(name: "Studio"); saved.displayMode = .prompterWithVideo
      saved.reading.mode = "Manual"; saved.reading.audioDeviceUID = nil
      _ = store.applyShootSetup(saved, camera: camera, recorder: recorder, microphones: [])
      try await snapshot(Form { ShootSetupSection(store: store, camera: camera, recorder: recorder) }.formStyle(.grouped).uiZoom(zoom), name: "a16-setup-recovery-\(Int(zoom * 100))-\(appearance)", size: .init(width: 700, height: 700), scheme: scheme, destination: URL(fileURLWithPath: output))
      let presenter = PresenterView(store: store, session: store.session, draft: PresenterDraft(record: record), camera: camera, startsCamera: false, recorder: recorder)
      try await snapshot(CameraRecordingPage(store: store, camera: camera, recorder: recorder, startsCamera: false).uiZoom(zoom), name: "a16-camera-\(Int(zoom * 100))-\(appearance)", size: .init(width: 780, height: 800), scheme: scheme, destination: URL(fileURLWithPath: output))
    }
  }
}
