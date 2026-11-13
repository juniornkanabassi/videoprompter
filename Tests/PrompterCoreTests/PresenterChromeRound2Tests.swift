import AppKit
import SwiftUI
import PrompterCore
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

  func testMicScaleGivesTheLoudHalfAtLeastHalfTheLength() {
    XCTAssertEqual(MeterZones.micPosition(-60), 0)
    XCTAssertEqual(MeterZones.micPosition(0), 1)
    XCTAssertEqual(MeterZones.micPosition(-20), 0.4, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual(1 - MeterZones.micPosition(-20), 0.5, "-20 to 0 dBFS takes at least half the meter")
    XCTAssertEqual(MeterZones.micPosition(-90), 0)
    XCTAssertEqual(MeterZones.micPosition(6), 1)
    XCTAssertEqual(MeterZones.micPosition(-.infinity), 0)
    XCTAssertEqual(MeterZones.micPosition(.nan), 0)
    var last: CGFloat = -1
    for db in stride(from: Float(-60), through: 0, by: 1) {
      XCTAssertGreaterThan(MeterZones.micPosition(db), last, "the scale only rises (\(db))"); last = MeterZones.micPosition(db)
    }
    // The red zone is a clear share of the bar, and the yellow band sits inside the loud half.
    XCTAssertGreaterThanOrEqual(1 - MeterZones.micPosition(MeterZones.redFrom), 0.15)
    XCTAssertGreaterThan(MeterZones.micPosition(MeterZones.yellowFrom), 0.5)
  }

  func testHorizontalZoneWordsStayOnTheirZonesAndClearEachOther() {
    for width in [160.0, 200, 260, 320, 480, 720] as [CGFloat] {
      let centres = MicMeterView.zoneWordCentres(width: width)
      let half = MicMeterView.zoneWordWidth / 2
      XCTAssertLessThanOrEqual(centres.loud + half, width + 0.001, "too loud stays inside the bar at \(width)")
      XCTAssertLessThanOrEqual(centres.aim + half, centres.loud - half, "the words never overlap at \(width)")
      XCTAssertGreaterThanOrEqual(centres.aim - half, 0)
    }
    let wide = MicMeterView.zoneWordCentres(width: 720)
    XCTAssertEqual(wide.aim, 720 * (MeterZones.micPosition(-12) + MeterZones.micPosition(-6)) / 2, accuracy: 0.001, "centred on the yellow band")
    XCTAssertEqual(wide.loud, 720 * (MeterZones.micPosition(-6) + 1) / 2, accuracy: 0.001, "centred on the red band")
  }

  func testSetupBarWordsFollowOneRuleByWidth() {
    XCTAssertEqual(PresenterView.barTier(width: 2560), .full)
    XCTAssertEqual(PresenterView.barTier(width: 1600), .standard, "picture tools keep their words at 1600")
    XCTAssertEqual(PresenterView.barTier(width: 1280), .standard, "and at 1280")
    XCTAssertEqual(PresenterView.barTier(width: 1100), .compact, "icons only below about 1100 to 1150")
    XCTAssertEqual(PresenterView.barTier(width: 800), .compact)
  }

  func testBlankLinesShrinkWithoutChangingTheText() {
    let text = NSMutableAttributedString(string: "One.\n\nTwo.\n\n\nThree.", attributes: [.paragraphStyle: NSParagraphStyle.default])
    let before = text.string
    ScriptTextView.Coordinator.shrinkBlankLines(in: text, fontSize: 50)
    XCTAssertEqual(text.string, before, "no character is added or removed")
    func height(at index: Int) -> CGFloat { (text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.maximumLineHeight ?? -1 }
    XCTAssertEqual(height(at: 5), 50 * ScriptTextView.Coordinator.blankLineHeight, "the blank line is shortened")
    XCTAssertEqual(height(at: 0), 0, "text lines are untouched")
    XCTAssertEqual(height(at: 4), 0, "even the newline that ends a text line")
    XCTAssertEqual(height(at: 11), 50 * ScriptTextView.Coordinator.blankLineHeight)
    XCTAssertEqual(height(at: 12), 50 * ScriptTextView.Coordinator.blankLineHeight)
    XCTAssertEqual(ScriptTextView.fadeHeight(fontSize: 20), ReadingViewportMask.fadeHeight)
    XCTAssertEqual(ScriptTextView.fadeHeight(fontSize: 52), 52 * 1.6, accuracy: 0.001)
    XCTAssertEqual(ScriptTextView.fadeHeight(fontSize: 200), 160)
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
  /// About 4,500 characters: past the editor's fitted-height limit, so the editing box fills the room.
  static let presenterLongScript: String = {
    let paragraph = "Arsenal pressed high from the first whistle and Saliba stepped out to meet every ball that came through the middle. When it went wide, the back three slid across together, and that is why the space behind never opened."
    return (1...20).map { "\($0). " + paragraph }.joined(separator: "\n\n")
  }()

  func testPresenterChromeRound4Snapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let destination = URL(fileURLWithPath: output)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("PresenterRound4Snapshots")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let record = try await store.createScript(title: "Matchday", markdown: "Arsenal went to Anfield with a plan.\n\nAnd that is why the back three changed everything this season.\n\nWatch where Saliba stands when the ball goes wide.")
    let longRecord = try await store.createScript(title: "Long", markdown: Self.presenterLongScript)
    XCTAssertGreaterThan(Self.presenterLongScript.count, 4000)
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
                 zoom: Double = 1, focus: Bool = false, autoHide: Bool = false, adjust: AdjustTab? = nil, script: ScriptRecord? = nil) async throws {
      let script = script ?? record
      store.uiZoom = zoom
      store.session.present(record: script, settings: store.settings)
      recorder.inputMeter.show(peakDBFS: -9, isClipping: false)
      defaults.set(focus, forKey: "presenterFocusMode")
      defaults.set(autoHide, forKey: "presenterAutoHideBar")
      if reading { store.session.play(captureAudio: false) } else { store.session.pause() }
      let draft = PresenterDraft(record: script)
      if editing { draft.begin(session: store.session) }
      let view = PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder,
        shell: PresenterShell(reading: reading, adjustTab: adjust, scriptPreview: preview), referencePicture: noCamera ? nil : picture,
        sourceInfoOverride: noCamera ? nil : source, microphoneNameOverride: "ATEM ISO").environment(\.presenterReduceTransparency, false).defaultAppStorage(defaults)
      try await snapshot(view, name: name, size: size, scheme: .dark, destination: destination, settleDelay: .milliseconds(300))
      if editing { draft.cancel() }
    }
    let wide = CGSize(width: 1600, height: 1000), laptop = CGSize(width: 1280, height: 800), narrow = CGSize(width: 1000, height: 700), uhd = CGSize(width: 3840, height: 2160)
    // The picture is a portrait one, so the camera is turned for vertical: the card says the same.
    camera.setRotation(.quarter)
    // Setup with no camera: one centred empty state, one clear button, no exposure key.
    camera.displayMode = .prompterWithVideo
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r4-setup-nocamera-\(label)", size: size, noCamera: true)
    }
    try await present("r4-setup-nocamera-200", size: wide, noCamera: true, zoom: 2)
    // Setup with the camera on: the same words at 1600, 1280 and 4K, icons only when narrow.
    for (label, size) in [("1600", wide), ("1280", laptop), ("1000", narrow), ("4k", uhd)] {
      try await present("r4-setup-camera-\(label)", size: size)
    }
    try await present("r4-setup-camera-200", size: wide, zoom: 2)
    // Camera off (just the script): a neutral off button, not an alarm.
    camera.displayMode = .prompterOnly
    for (label, size) in [("1600", wide), ("1280", laptop)] {
      try await present("r4-setup-cameraoff-\(label)", size: size, preview: true, noCamera: true)
    }
    camera.displayMode = .prompterWithVideo
    try await present("r4-adjust-mic-1600", size: wide, adjust: .mic)
    // Reading: a soft band and a clear line, no column edges, a faded bottom at every size.
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r4-reading-\(label)", size: size, reading: true)
    }
    try await present("r4-reading-200", size: wide, reading: true, zoom: 2)
    try await present("r4-reading-long-1280", size: laptop, reading: true, script: longRecord)
    try await present("r4-reading-autohide-1600", size: wide, reading: true, autoHide: true)
    // Focus: only the text, the audio meter and the reading line, with a short "Esc to exit".
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r4-reading-focus-\(label)", size: size, reading: true, focus: true)
    }
    // Editing: Save and Cancel on the editor's own edge, at every size and with a long script.
    for (label, size) in [("1600", wide), ("1280", laptop)] {
      try await present("r4-editing-\(label)", size: size, editing: true)
    }
    try await present("r4-editing-200", size: wide, editing: true, zoom: 2)
    try await present("r4-editing-4k", size: uhd, editing: true)
    try await present("r4-editing-long-1600", size: wide, editing: true, script: longRecord)
    try await present("r4-editing-long-200", size: wide, editing: true, zoom: 2, script: longRecord)
    store.session.pause()
    store.uiZoom = 1
    defaults.set(false, forKey: "presenterFocusMode")
  }

  func testMicMeterRound4States() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let meter = InputMeter()
    // Peaking sits in the yellow band at about -8; hot has the clip lamp lit; the rest are the quiet states.
    for (name, peak, clipping, listening) in [("quiet", Float(-48), false, true), ("speech", Float(-20), false, true), ("peaking", Float(-8), false, true),
                                              ("hot", Float(-2), true, true), ("nosignal", nil, false, true), ("off", Float(-9), false, false)] as [(String, Float?, Bool, Bool)] {
      meter.reset()
      if let peak { meter.show(peakDBFS: peak, isClipping: clipping) }
      try await snapshot(MicMeterView(meter: meter, micName: "ATEM ISO", isListening: listening).frame(width: 96, height: 420).padding(Space.md).background(Color(white: 0.035)),
                         name: "r4-mic-meter-\(name)", size: .init(width: 130, height: 460), scheme: .dark, destination: URL(fileURLWithPath: output))
    }
    // The horizontal meter (the Adjust mic card) keeps the same scale and centred words.
    for (name, peak, clipping) in [("peaking", Float(-8), false), ("hot", Float(-2), true)] {
      meter.reset()
      meter.show(peakDBFS: peak, isClipping: clipping)
      try await snapshot(MicMeterView(meter: meter, micName: "ATEM ISO", showsHeading: false).frame(width: 360, height: 96).padding(Space.md).background(Color(white: 0.12)),
                         name: "r4-mic-meter-horizontal-\(name)", size: .init(width: 400, height: 130), scheme: .dark, destination: URL(fileURLWithPath: output))
    }
    meter.reset()
  }
}
