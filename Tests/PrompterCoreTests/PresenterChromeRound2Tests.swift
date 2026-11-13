import AppKit
import SwiftUI
import XCTest
@testable import VideoPrompter

/// Round 2 of the presenter chrome: video-call controls, the shared mic meter, the reading line,
/// Focus mode, and the editing band. Everything runs offscreen on disposable data.
@MainActor final class PresenterChromeRound2Tests: XCTestCase {
  private let script = "Arsenal went to Anfield with a plan.\n\nAnd that is why the back three changed everything this season.\n\nWatch where Saliba stands when the ball goes wide."

  private func fixture() async throws -> (AppStore, CameraModel, CameraRecorder, PresenterDraft, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("PresenterRound2")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Matchday", markdown: script)
    store.settings.mode = "Voice"
    store.settings.fontSize = 52
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults)
    camera.displayMode = .prompterWithVideo
    camera.authorization = .authorized
    return (store, camera, CameraRecorder(defaults: defaults), PresenterDraft(record: record), defaults)
  }

  private func view(_ f: (AppStore, CameraModel, CameraRecorder, PresenterDraft, UserDefaults), shell: PresenterShell = PresenterShell()) -> some View {
    PresenterView(store: f.0, session: f.0.session, draft: f.3, camera: f.1, startsCamera: false, recorder: f.2, shell: shell,
                  microphoneNameOverride: "ATEM ISO").defaultAppStorage(f.4)
  }

  // MARK: Mic meter

  func testMeterZonesAndInputCaption() {
    XCTAssertEqual(InputLevelMeter.yellowFrom, -12)
    XCTAssertEqual(InputLevelMeter.redFrom, -6)
    let atem = AudioInputDevice(id: 1, uid: "atem", name: "ATEM ISO")
    let builtIn = AudioInputDevice(id: 2, uid: "mac", name: "MacBook Pro Microphone")
    XCTAssertEqual(MicMeterView.inputName(uid: "atem", devices: [builtIn, atem], systemDefault: "MacBook Pro Microphone"), "ATEM ISO",
                   "The caption names the chosen input, never another device")
    XCTAssertEqual(MicMeterView.inputName(uid: nil, devices: [builtIn, atem], systemDefault: "MacBook Pro Microphone"), "System default · MacBook Pro Microphone")
    XCTAssertEqual(MicMeterView.inputName(uid: "gone", devices: [builtIn], systemDefault: nil), "Selected microphone unavailable")
    XCTAssertEqual(MicMeterView.inputName(uid: nil, devices: [], systemDefault: nil), "No microphone")
    XCTAssertEqual(MicMeterView.visibleScale(height: 300).map(\.label), ["0", "−6", "−12", "−20", "−40", "−60"])
    XCTAssertEqual(MicMeterView.visibleScale(height: 220).map(\.label), ["0", "−6", "−12", "−20", "−60"])
    XCTAssertEqual(MicMeterView.visibleScale(height: 160).map(\.label), ["0", "−6", "−12", "−60"])
  }

  func testMeterShowsNumbersAndMicOffState() async throws {
    let meter = InputMeter()
    meter.show(peakDBFS: -9, isClipping: false)
    let (window, host) = await LibraryAX.host(MicMeterView(meter: meter, micName: "ATEM ISO").frame(width: 96, height: 320), size: .init(width: 120, height: 340))
    defer { LibraryAX.close(window) }
    let labels = LibraryAX.elements(host).map { LibraryAX.value($0, "accessibilityLabel") }
    XCTAssertTrue(labels.contains("Microphone level, ATEM ISO, −9 dBFS"), "\(labels)")
    let (offWindow, offHost) = await LibraryAX.host(MicMeterView(meter: meter, micName: "ATEM ISO", isListening: false).frame(width: 96, height: 320), size: .init(width: 120, height: 340))
    defer { LibraryAX.close(offWindow) }
    XCTAssertTrue(LibraryAX.elements(offHost).contains { LibraryAX.value($0, "accessibilityLabel") == "Microphone off, ATEM ISO" })
  }

  // MARK: Microphone off stops listening

  func testMicrophoneOffUsesThePauseAndNeverOpensTheMicrophone() async throws {
    let (store, _, _, _, _) = try await fixture()
    let session = store.session
    session.seek(to: 5)
    session.play(captureAudio: false)
    XCTAssertTrue(session.isActivelyRunning)
    let word = session.tokenIndex
    session.setListensToMicrophone(false)
    XCTAssertFalse(session.isActivelyRunning, "Turning the microphone off pauses Voice follow")
    XCTAssertEqual(session.tokenIndex, word, "The reading anchor is never reset")
    session.play()   // Start reading with the microphone off: no capture opens.
    XCTAssertTrue(session.isActivelyRunning)
    XCTAssertFalse(session.hasLiveRecognition)
    XCTAssertEqual(session.visibleReadingState, "Microphone off")
    session.pause()
    session.setListensToMicrophone(true)
    XCTAssertTrue(session.listensToMicrophone)
  }

  // MARK: Video-call controls

  func testCameraOffLeavesJustTheScriptAndBackOn() async throws {
    let f = try await fixture()
    let shell = PresenterShell()
    let (window, host) = await LibraryAX.host(view(f, shell: shell), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    XCTAssertFalse(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-script-content" })
    let camera = try XCTUnwrap(LibraryAX.named("Camera", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXCheckBox" })
    XCTAssertTrue(LibraryAX.bool(camera, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(f.1.presentsWithVideo)
    XCTAssertTrue(shell.scriptPreview, "Camera off shows the script")
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-script-content" })
    XCTAssertEqual(LibraryAX.value(camera, "accessibilityValue"), "Off")
    XCTAssertTrue(LibraryAX.bool(camera, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(f.1.presentsWithVideo)
  }

  func testScriptToggleShowsAndHidesTheScriptInSetup() async throws {
    let f = try await fixture()
    let shell = PresenterShell()
    let (window, host) = await LibraryAX.host(view(f, shell: shell), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    let toggle = try XCTUnwrap(LibraryAX.named("Script", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXCheckBox" })
    XCTAssertEqual(LibraryAX.value(toggle, "accessibilityValue"), "Off")
    XCTAssertTrue(LibraryAX.bool(toggle, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(shell.scriptPreview)
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-script-content" })
  }

  // MARK: Reading: Focus mode and the one-row bar

  func testFocusModeShowsOnlyTextMeterAndExitsFromTheMenuKey() async throws {
    let f = try await fixture()
    f.4.set(true, forKey: "presenterFocusMode")
    let (window, host) = await LibraryAX.host(view(f, shell: PresenterShell(reading: true)), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    for title in ["Pause", "Start reading", "Back to start", "Set up the shot", "Mic", "Focus", "Open script"] {
      XCTAssertTrue(LibraryAX.named(title, in: host).isEmpty, "\(title) is hidden in Focus mode")
    }
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityLabel").hasPrefix("Microphone level") }, "The meter stays")
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-script-content" })
    f.4.set(false, forKey: "presenterFocusMode")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(LibraryAX.named("Set up the shot", in: host).isEmpty, "Leaving Focus brings the bar back")
  }

  func testReadingBarIsOneRowOfStatusTransportAndQuietOptions() async throws {
    let f = try await fixture()
    let (window, host) = await LibraryAX.host(view(f, shell: PresenterShell(reading: true)), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    for title in ["Back to start", "Start reading", "Set up the shot", "Mic", "Focus", "Reading settings", "Open script"] {
      XCTAssertFalse(LibraryAX.named(title, in: host).isEmpty, title)
    }
    XCTAssertTrue(LibraryAX.named("Camera", in: host).isEmpty)
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityLabel").hasPrefix("Voice · ") }, "One status pill names the mode and state")
  }

  func testChromeGrowsWithTheWindowButNotBelowOne() {
    XCTAssertEqual(PresenterView.sizeBoost(width: 720), 1)
    XCTAssertEqual(PresenterView.sizeBoost(width: 1600), 1)
    XCTAssertEqual(PresenterView.sizeBoost(width: 2400), 1)
    XCTAssertEqual(PresenterView.sizeBoost(width: 3840), 1.5, accuracy: 0.0001)
    XCTAssertEqual(PresenterView.sizeBoost(width: 7680), 1.5)
  }

  func testReadingMeasureAndEditorTypography() {
    let fraction = ScriptTextView.measureCappedFraction(width: 3600, textWidth: 0.9, fontSize: 40)
    XCTAssertEqual(fraction * 3600, 1200, accuracy: 0.01)
    XCTAssertEqual(ScriptTextView.sideInset(width: 3600, textWidth: fraction), 1200, accuracy: 0.01)
    let rendered = FormattedMarkdownEditModel(markdown: "A short paragraph").rendered(
      fontName: "System", fontSize: 40,
      typography: EditorTypography(lineSpacing: 8, paragraphSpacing: 16, bold: true))
    let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
    let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(paragraph?.lineSpacing, 8)
    XCTAssertEqual(paragraph?.paragraphSpacing, 16)
  }

  func testBothMeterOrientationsUseTheSameBoundaries() {
    XCTAssertEqual(MeterZones.position(-60), 0)
    XCTAssertEqual(MeterZones.position(-12), 0.8, accuracy: 0.0001)
    XCTAssertEqual(MeterZones.position(-6), 0.9, accuracy: 0.0001)
    XCTAssertEqual(MeterZones.position(0), 1)
    XCTAssertEqual(MicMeterView.visibleScale(width: 300).map(\.value), MicMeterView.visibleScale(height: 300).map(\.value))
  }

  // MARK: Editing

  func testEditingHasABandWithSaveAndCancelAndNoMicMeter() async throws {
    let f = try await fixture()
    f.3.begin(session: f.0.session)
    defer { f.3.cancel() }
    let (window, host) = await LibraryAX.host(view(f), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    let nodes = LibraryAX.elements(host)
    XCTAssertTrue(nodes.contains { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-editing-band" })
    XCTAssertTrue(nodes.contains { LibraryAX.value($0, "accessibilityIdentifier") == "presenter-editing-surface" })
    XCTAssertFalse(LibraryAX.named("Save changes", in: host).isEmpty)
    XCTAssertFalse(LibraryAX.named("Cancel editing", in: host).isEmpty)
    XCTAssertFalse(nodes.contains { LibraryAX.value($0, "accessibilityLabel").hasPrefix("Microphone level") }, "The meter is hidden while editing")
    XCTAssertTrue(LibraryAX.named("Start reading", in: host).isEmpty, "No reading bar while editing")
  }
}

// MARK: - Snapshots

extension AppearanceSnapshotTests {
  func testPresenterChromeRound3Snapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let destination = URL(fileURLWithPath: output)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("PresenterRound2Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Matchday", markdown: "Arsenal went to Anfield with a plan.\n\nAnd that is why the back three changed everything this season.\n\nWatch where Saliba stands when the ball goes wide.")
    store.settings.mode = "Voice"
    store.settings.fontSize = 52
    store.settings.videoDimming = 0.35
    store.session.present(record: record, settings: store.settings)
    let camera = CameraModel(defaults: defaults), recorder = CameraRecorder(defaults: defaults)
    camera.authorization = .authorized
    camera.displayMode = .prompterWithVideo
    camera.guides.zebras = true
    let picture = try XCTUnwrap(NSImage(contentsOf: Bundle.module.url(forResource: "presenter-zebras", withExtension: "png", subdirectory: "Fixtures")!))
    let source = CameraSourceInfo(displayName: "Sony FX3", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 25)
    // One level everywhere: the side meter and the Adjust mic card read the same peak, never "No signal" beside -9.
    recorder.inputMeter.show(peakDBFS: -9, isClipping: false)
    store.session.meter.show(peakDBFS: -9, isClipping: false)

    func present(_ name: String, size: CGSize, reading: Bool = false, editing: Bool = false, preview: Bool = false, noCamera: Bool = false,
                 zoom: Double = 1, focus: Bool = false, autoHide: Bool = false, adjust: AdjustTab? = nil) async throws {
      store.uiZoom = zoom
      recorder.inputMeter.show(peakDBFS: -9, isClipping: false)
      defaults.set(focus, forKey: "presenterFocusMode")
      defaults.set(autoHide, forKey: "presenterAutoHideBar")
      if reading { store.session.play(captureAudio: false) } else { store.session.pause() }
      let draft = PresenterDraft(record: record)
      if editing { draft.begin(session: store.session) }
      let view = PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder,
        shell: PresenterShell(reading: reading, adjustTab: adjust, scriptPreview: preview), referencePicture: noCamera ? nil : picture,
        sourceInfoOverride: noCamera ? nil : source, microphoneNameOverride: "ATEM ISO").environment(\.presenterReduceTransparency, false).defaultAppStorage(defaults)
      try await snapshot(view, name: name, size: size, scheme: .dark, destination: destination, settleDelay: .milliseconds(300))
      if editing { draft.cancel() }
    }
    let wide = CGSize(width: 1600, height: 1000), laptop = CGSize(width: 1280, height: 800), uhd = CGSize(width: 3840, height: 2160)
    camera.setRotation(.none)
    // Setup with no camera: one centred empty state, one clear button.
    camera.displayMode = .prompterWithVideo
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r3-setup-nocamera-\(label)", size: size, noCamera: true)
    }
    try await present("r3-setup-nocamera-200", size: wide, noCamera: true, zoom: 2)
    // Setup with the camera on, then off (just the script).
    try await present("r3-setup-camera-1600", size: wide)
    camera.displayMode = .prompterOnly
    for (label, size) in [("1600", wide), ("1280", laptop)] {
      try await present("r3-setup-cameraoff-\(label)", size: size, preview: true, noCamera: true)
    }
    camera.displayMode = .prompterWithVideo
    try await present("r3-setup-camera-4k", size: uhd)
    try await present("r3-setup-camera-200", size: wide, zoom: 2)
    try await present("r3-adjust-mic-1600", size: wide, adjust: .mic)
    // Reading: soft backing, the reading line, one status pill, the meter with numbers.
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r3-reading-\(label)", size: size, reading: true)
    }
    try await present("r3-reading-200", size: wide, reading: true, zoom: 2)
    try await present("r3-reading-autohide-1600", size: wide, reading: true, autoHide: true)
    // Clean full screen: only the text, the audio meter and the reading line.
    try await present("r3-reading-focus-1600", size: wide, reading: true, focus: true)
    try await present("r3-reading-focus-1280", size: laptop, reading: true, focus: true)
    // Editing: a top band, an editable surface, no meter.
    for (label, size) in [("1600", wide), ("1280", laptop)] {
      try await present("r3-editing-\(label)", size: size, editing: true)
    }
    try await present("r3-editing-200", size: wide, editing: true, zoom: 2)
    try await present("r3-editing-4k", size: uhd, editing: true)
    try await present("r3-reading-focus-4k", size: uhd, reading: true, focus: true)
    store.session.pause()
    store.uiZoom = 1
    defaults.set(false, forKey: "presenterFocusMode")
  }

  func testMicMeterRound2States() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let meter = InputMeter()
    for (name, peak, clipping, listening) in [("quiet", Float(-48), false, true), ("speech", Float(-20), false, true), ("peaking", Float(-9), false, true),
                                              ("hot", Float(-2), true, true), ("nosignal", nil, false, true), ("off", Float(-9), false, false)] as [(String, Float?, Bool, Bool)] {
      meter.reset()
      if let peak { meter.show(peakDBFS: peak, isClipping: clipping) }
      try await snapshot(MicMeterView(meter: meter, micName: "ATEM ISO", isListening: listening).frame(width: 96, height: 420).padding(Space.md).background(Color(white: 0.035)),
                         name: "r2-mic-meter-\(name)", size: .init(width: 130, height: 460), scheme: .dark, destination: URL(fileURLWithPath: output))
    }
    meter.reset()
  }
}
