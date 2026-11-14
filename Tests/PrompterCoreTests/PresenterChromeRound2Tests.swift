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
    XCTAssertEqual(MicMeterView.inputName(uid: nil, devices: [builtIn, atem], systemDefault: "MacBook Pro Microphone"), "MacBook Pro Microphone", "The meter names the real device, as its card does")
    XCTAssertEqual(MicMeterView.inputName(uid: "gone", devices: [builtIn], systemDefault: nil), "Selected microphone unavailable")
    XCTAssertEqual(MicMeterView.inputName(uid: nil, devices: [], systemDefault: nil), "No microphone")
    XCTAssertEqual(MicMeterView.scale.map(\.label), ["0", "−6", "−12", "−20", "−40", "−60"], "one set of numbers at every size and in both orientations")
    // The marks between the numbers keep the drawn spacing even: 3 dB steps above the knee, 10 dB steps below it.
    let marks = (MicMeterView.scale.map(\.value) + MicMeterView.minorTicks).sorted(by: >).map { MeterZones.micPosition($0) }
    for pair in zip(marks, marks.dropFirst()) { XCTAssertLessThanOrEqual(pair.0 - pair.1, 0.151, "no gap between marks is wider than 15% of the bar") }
  }

  func testMeterShowsNumbersAndMicOffState() async throws {
    let meter = InputMeter()
    meter.show(peakDBFS: -9, isClipping: false)
    let (window, host) = await LibraryAX.host(MicMeterView(meter: meter, micName: "ATEM ISO").frame(width: 96, height: 320), size: .init(width: 120, height: 340))
    defer { LibraryAX.close(window) }
    // Hosting can outlast the meter's 1.5-second freshness window; feed the fixture after setup.
    meter.reset()
    meter.show(peakDBFS: -9, isClipping: false)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
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
    XCTAssertFalse(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityLabel") == "Presenter script" })
    let camera = try XCTUnwrap(LibraryAX.named("Camera", in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXCheckBox" })
    XCTAssertTrue(LibraryAX.bool(camera, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(f.1.presentsWithVideo)
    XCTAssertTrue(shell.scriptPreview, "Camera off shows the script")
    XCTAssertTrue(LibraryAX.elements(host).contains { LibraryAX.value($0, "accessibilityLabel") == "Presenter script" })
    XCTAssertEqual(LibraryAX.value(camera, "accessibilityValue"), "Off")
    XCTAssertTrue(LibraryAX.bool(camera, "accessibilityPerformPress"))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(f.1.presentsWithVideo)
  }

  func testPictureToolsAreNeverOnWithoutAPicture() async throws {
    let f = try await fixture()
    f.1.guides.zebras = true
    let (window, host) = await LibraryAX.host(view(f), size: .init(width: 1600, height: 1000))
    defer { LibraryAX.close(window) }
    for title in ["Zebras", "False colour", "Guides"] {
      let tool = try XCTUnwrap(LibraryAX.named(title, in: host).first { LibraryAX.value($0, "accessibilityRole") == "AXCheckBox" }, title)
      XCTAssertEqual(LibraryAX.value(tool, "accessibilityValue"), "Off", "\(title) is not shown as on with no camera picture")
    }
    XCTAssertFalse(LibraryAX.named("Choose camera", in: host).isEmpty, "Camera settings stay reachable from the picker")
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
    XCTAssertEqual(PresenterView.sizeBoost(width: 1920), 1)
    XCTAssertEqual(PresenterView.sizeBoost(width: 2560), 1 + 1.4 / 3, accuracy: 0.0001)
    XCTAssertEqual(PresenterView.sizeBoost(width: 3840), 2.4, accuracy: 0.0001, "a 4K window's chrome reads next to its picture")
    XCTAssertEqual(PresenterView.sizeBoost(width: 7680), 2.4)
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

  func testCompactReadingControlsKeepMinimumTargets() {
    XCTAssertEqual(PresenterView.compactControlHeight(zoom: 1), PresenterBar.height, "a 100% bar keeps the 44 pt target")
    XCTAssertLessThan(PresenterView.compactControlHeight(zoom: 2), PresenterBar.height)
    XCTAssertGreaterThanOrEqual(PresenterView.compactControlHeight(zoom: 1.5) * 1.5, PresenterBar.height, "on screen never below 44 pt")
    XCTAssertLessThanOrEqual(PresenterView.compactRowGap, 8)
  }

  func testMeterTypeKeepsGrowingAfterTheStripStops() {
    XCTAssertEqual(PresenterView.meterTypeScale(controlZoom: 1, uiZoom: 1), 1)
    XCTAssertEqual(PresenterView.meterTypeScale(controlZoom: 1.5, uiZoom: 1.5), 1, accuracy: 0.0001)
    XCTAssertEqual(PresenterView.meterTypeScale(controlZoom: 2, uiZoom: 2), 4.0 / 3.0, accuracy: 0.0001, "at 200% the type is the interface's size inside the capped strip")
    XCTAssertEqual(MicMeterView.stripWidth(typeScale: 1), 108, "the unscaled strip, a little narrower than before so the meter takes less from the script")
    XCTAssertLessThan(MicMeterView.stripWidth(typeScale: 4.0 / 3.0) * 1.5, 210, "the strip stays modest at 200%")
  }

  func testLiveNumberColourFollowsTheLevelNeverTheClipLatch() {
    let loud = Color.red
    XCTAssertEqual(MeterZones.readoutColour(-14, loud: loud), .white, "-14 after a clip is a calm number")
    XCTAssertEqual(MeterZones.readoutColour(-9, loud: loud), MeterZones.yellow)
    XCTAssertEqual(MeterZones.readoutColour(-3, loud: loud), loud)
    XCTAssertEqual(MeterZones.readoutColour(-.infinity, loud: loud), .white.opacity(0.7))
  }

  func testShortWindowsRaiseTheReadingLineAndTallOnesKeepIt() {
    XCTAssertEqual(PresenterView.readingGuideFraction(saved: 0.35, height: 1000, fontSize: 52), 0.35, "a tall window keeps the saved line")
    XCTAssertEqual(PresenterView.readingGuideFraction(saved: 0.35, height: 2000, fontSize: 52), 0.35)
    XCTAssertLessThan(PresenterView.readingGuideFraction(saved: 0.35, height: 740, fontSize: 52), 0.3, "1280 x 800 raises it")
    XCTAssertEqual(PresenterView.readingGuideFraction(saved: 0.2, height: 300, fontSize: 52), 0.2, "never lower than the saved line or 0.2")
    XCTAssertEqual(PresenterView.readingGuideFraction(saved: 0.15, height: 400, fontSize: 52), 0.15, "a saved line above the floor stays")
  }

  func testMeterStripStopsGrowingAt150Percent() {
    XCTAssertEqual(PresenterView.meterZoom(controlZoom: 1, uiZoom: 1), 1)
    XCTAssertEqual(PresenterView.meterZoom(controlZoom: 1.5, uiZoom: 1), 1.5, "a 4K window still scales the strip")
    XCTAssertEqual(PresenterView.meterZoom(controlZoom: 1.5, uiZoom: 1.5), 1.5)
    XCTAssertEqual(PresenterView.meterZoom(controlZoom: 2, uiZoom: 2), 1.5, "at 200% the text keeps the room")
    XCTAssertEqual(PresenterView.meterZoom(controlZoom: 3, uiZoom: 2), 2.25, accuracy: 0.0001, "a 4K window at 200% stays in proportion")
  }

  func testBottomFadeIsAboutALineAndAHalfAtEveryTextSize() {
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

  func testPresenterChromeRound10Snapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let destination = URL(fileURLWithPath: output)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("PresenterRound8Snapshots")
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
    // While reading the app draws no zebras on the picture, so reading fixtures use the same shot without them.
    let cleanPicture = try XCTUnwrap(NSImage(contentsOf: Bundle.module.url(forResource: "presenter-clean", withExtension: "png", subdirectory: "Fixtures")!))
    let source = CameraSourceInfo(displayName: "Sony FX3", connection: .hdmiCapture, width: 3840, height: 2160, nominalFrameRate: 25)
    // The same input everywhere: the Adjust mic card selects the ATEM and the side meter names it.
    var atem = AudioInputDevice(id: 1, uid: "atem", name: "ATEM Mini Extreme ISO G2")
    atem.channels = 2; atem.connection = "Thunderbolt"
    store.settings.audioDeviceUID = "atem"
    // One level everywhere: the side meter and the Adjust mic card read the same peak, never "No signal" beside -9.
    recorder.inputMeter.show(peakDBFS: -9, isClipping: false)
    store.session.meter.show(peakDBFS: -9, isClipping: false)

    func present(_ name: String, size: CGSize, reading: Bool = false, editing: Bool = false, preview: Bool = false, noCamera: Bool = false,
                 zoom: Double = 1, focus: Bool = false, autoHide: Bool = false, adjust: AdjustTab? = nil, script: ScriptRecord? = nil,
                 level: Float = -9, clipping: Bool = false, latched: Bool = false, fallsTo: Float = -14, zebraChip: Double = 0) async throws {
      let script = script ?? record
      store.uiZoom = zoom
      store.session.present(record: script, settings: store.settings)
      // `latched`: the input clipped a moment ago and is now at `fallsTo`, so the lamp is still lit (it holds for two seconds).
      // The shared clip latch outlives a fixture's view, so each fixture starts with it forgotten.
      for meter in [recorder.inputMeter, store.session.meter] { ClipLatchBox.shared(for: meter).clear() }
      for meter in [recorder.inputMeter, store.session.meter] { meter.show(peakDBFS: latched ? -2 : level, isClipping: clipping || latched) }
      if latched { Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); for meter in [recorder.inputMeter, store.session.meter] { meter.show(peakDBFS: fallsTo, isClipping: false) } } }
      defaults.set(focus, forKey: "presenterFocusMode")
      defaults.set(autoHide, forKey: "presenterAutoHideBar")
      if reading { store.session.play(captureAudio: false) } else { store.session.pause() }
      let draft = PresenterDraft(record: script)
      if editing { draft.begin(session: store.session) }
      let view = PresenterView(store: store, session: store.session, draft: draft, camera: camera, startsCamera: false, recorder: recorder,
        shell: PresenterShell(reading: reading, adjustTab: adjust, scriptPreview: preview), referencePicture: noCamera ? nil : reading ? cleanPicture : picture,
        sourceInfoOverride: noCamera ? nil : source, microphoneNameOverride: atem.name, microphonesOverride: [atem], zebraChipSeconds: zebraChip).environment(\.presenterReduceTransparency, false).defaultAppStorage(defaults)
      var caret: ((NSView) -> Void)?
      if editing { caret = { Self.showEditingCaret($0) } }
      try await snapshot(view, name: name, size: size, scheme: .dark, destination: destination, settleDelay: .milliseconds(300), prepare: caret)
      if editing { draft.cancel() }
    }
    let wide = CGSize(width: 1600, height: 1000), laptop = CGSize(width: 1280, height: 800), narrow = CGSize(width: 1000, height: 700), uhd = CGSize(width: 3840, height: 2160)
    // The picture is a portrait one, so the camera is turned for vertical: the card says the same.
    camera.setRotation(.quarter)
    // Setup with no camera: one centred empty state, one clear button, no exposure key.
    camera.displayMode = .prompterWithVideo
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r10-setup-nocamera-\(label)", size: size, noCamera: true)
    }
    try await present("r10-setup-nocamera-200", size: wide, noCamera: true, zoom: 2)
    // Setup with the camera on: the same words at 1600, 1280 and 4K, icons only when narrow.
    for (label, size) in [("1600", wide), ("1280", laptop), ("1000", narrow), ("4k", uhd)] {
      try await present("r10-setup-camera-\(label)", size: size)
    }
    try await present("r10-setup-camera-150", size: wide, zoom: 1.5)
    try await present("r10-setup-camera-200", size: wide, zoom: 2)
    // Camera off (just the script): a neutral off button, not an alarm.
    camera.displayMode = .prompterOnly
    for (label, size) in [("1600", wide), ("1280", laptop)] {
      try await present("r10-setup-cameraoff-\(label)", size: size, preview: true, noCamera: true)
    }
    try await present("r10-setup-cameraoff-200", size: wide, preview: true, noCamera: true, zoom: 2)
    camera.displayMode = .prompterWithVideo
    try await present("r10-adjust-mic-1600", size: wide, adjust: .mic)
    // The meters in the real screens at the loud states: too loud (-3, lamp dark), clipping now (-3, lamp lit, "Clipping now"),
    // and clip earlier (clipped a moment ago, live level back at -14, "Clipped earlier" with the live number calm).
    // With the Adjust mic card open the card says the words and the side strip shows its lamp lit, never dark.
    for (name, level, clipping, latched, fallsTo) in [("tooloud", Float(-3), false, false, Float(-14)), ("clipearlier", Float(-14), false, true, Float(-14)), ("clipnow", Float(-3), true, false, Float(-14))] {
      try await present("r10-setup-nocamera-1600-\(name)", size: wide, noCamera: true, level: level, clipping: clipping, latched: latched, fallsTo: fallsTo)
      try await present("r10-adjust-mic-1600-\(name)", size: wide, adjust: .mic, level: level, clipping: clipping, latched: latched, fallsTo: fallsTo)
    }
    try await present("r10-setup-nocamera-200-clipearlier", size: wide, noCamera: true, zoom: 2, level: -14, latched: true, fallsTo: -14)
    try await present("r10-setup-nocamera-1280-clipearlier", size: laptop, noCamera: true, level: -14, latched: true, fallsTo: -14)
    try await present("r10-setup-nocamera-200-clipnow", size: wide, noCamera: true, zoom: 2, level: -3, clipping: true)
    try await present("r10-setup-nocamera-1280-clipnow", size: laptop, noCamera: true, level: -3, clipping: true)
    try await present("r10-adjust-mic-1280-clipearlier", size: laptop, adjust: .mic, level: -14, latched: true, fallsTo: -14)
    try await present("r10-adjust-mic-1280-clipnow", size: laptop, adjust: .mic, level: -3, clipping: true)
    // Reading: a soft band and a clear line, no column edges, a faded bottom at every size.
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r10-reading-\(label)", size: size, reading: true)
    }
    try await present("r10-reading-200", size: wide, reading: true, zoom: 2)
    // Just after reading starts the "Zebras off while reading" note is up; the others are its steady state (gone).
    try await present("r10-reading-1600-chipstart", size: wide, reading: true, zebraChip: 60)
    try await present("r10-reading-200-chipstart", size: wide, reading: true, zoom: 2, zebraChip: 60)
    try await present("r10-reading-200-clipearlier", size: wide, reading: true, zoom: 2, level: -14, latched: true, fallsTo: -14)
    try await present("r10-reading-long-1280", size: laptop, reading: true, script: longRecord)
    try await present("r10-reading-autohide-1600", size: wide, reading: true, autoHide: true)
    // Focus: only the text, the audio meter and the reading line, with a short "Esc to exit".
    for (label, size) in [("1600", wide), ("1280", laptop), ("4k", uhd)] {
      try await present("r10-reading-focus-\(label)", size: size, reading: true, focus: true)
    }
    // Editing: Save and Cancel on the editor's own edge, at every size and with a long script.
    for (label, size) in [("1600", wide), ("1280", laptop)] {
      try await present("r10-editing-\(label)", size: size, editing: true)
    }
    try await present("r10-editing-200", size: wide, editing: true, zoom: 2)
    try await present("r10-editing-4k", size: uhd, editing: true)
    try await present("r10-editing-long-1600", size: wide, editing: true, script: longRecord)
    try await present("r10-editing-long-200", size: wide, editing: true, zoom: 2, script: longRecord)
    store.session.pause()
    store.uiZoom = 1
    defaults.set(false, forKey: "presenterFocusMode")
  }

  /// Offscreen windows are never key, so AppKit never draws the real insertion point; the fixture lays a 2 pt bar
  /// where the editor's text view puts it (before the first letter), so the review sees where the caret sits.
  static func showEditingCaret(_ host: NSView) {
    func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
    guard let text = textViews(host).first, let layout = text.layoutManager, let container = text.textContainer, text.string.count > 0 else { return }
    text.setSelectedRange(NSRange(location: 0, length: 0))
    let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
    let origin = text.textContainerOrigin
    let bar = NSView(frame: NSRect(x: origin.x + glyph.minX - 3, y: origin.y + glyph.minY, width: 2, height: glyph.height))
    bar.wantsLayer = true
    bar.layer?.backgroundColor = NSColor.white.cgColor
    text.addSubview(bar)
  }

  func testMicMeterRound10States() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    guard ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOT_APPEARANCE"] != "light" else { return }
    let meter = InputMeter()
    let destination = URL(fileURLWithPath: output)
    /// `latched`: the input clipped a moment ago and is back at -14, so the lamp is still lit (it holds for two seconds).
    func show(_ peak: Float?, clipping: Bool, latched: Bool) {
      meter.reset()
      if let peak { meter.show(peakDBFS: latched ? -2 : peak, isClipping: clipping || latched) }
      if latched { Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); meter.show(peakDBFS: peak ?? -14, isClipping: false) } }
    }
    // Peaking sits in the yellow band at about -8, "too loud" is -3 with the lamp dark, "clipnow" is clipping at -3 with the lamp lit,
    // "clipearlier" clipped a moment ago and is back at -14 (lamp still lit); "cardopen" is the strip while the Adjust mic card
    // says the words, so it shows the lamp lit and no button. The rest are the quiet states.
    let states = [("quiet", Float(-48), false, true, false, true), ("speech", Float(-20), false, true, false, true), ("peaking", Float(-8), false, true, false, true),
                  ("tooloud", Float(-3), false, true, false, true), ("clipnow", Float(-3), true, true, false, true), ("clipearlier", Float(-14), false, true, true, true),
                  ("clipnow-cardopen", Float(-3), true, true, false, false), ("clipearlier-cardopen", Float(-14), false, true, true, false),
                  ("nosignal", nil, false, true, false, true), ("off", Float(-9), false, false, false, true)] as [(String, Float?, Bool, Bool, Bool, Bool)]
    for (name, peak, clipping, listening, latched, badge) in states {
      ClipLatchBox.shared(for: meter).clear()
      show(peak, clipping: clipping, latched: latched)
      try await snapshot(MicMeterView(meter: meter, micName: "ATEM Mini Extreme ISO G2", isListening: listening, showsClipBadge: badge).frame(width: MicMeterView.stripWidth(typeScale: 1), height: 420).padding(Space.md).background(Color.black).foregroundStyle(.white),
                         name: "r10-mic-meter-\(name)", size: .init(width: 140, height: 460), scheme: .dark, destination: destination, settleDelay: .milliseconds(200))
    }
    // The horizontal meter (the Adjust mic card) keeps the same scale, colours and centred words.
    for (name, peak, clipping, latched) in [("peaking", Float(-8), false, false), ("tooloud", Float(-3), false, false), ("clipnow", Float(-3), true, false), ("clipearlier", Float(-14), false, true)] as [(String, Float, Bool, Bool)] {
      ClipLatchBox.shared(for: meter).clear()
      show(peak, clipping: clipping, latched: latched)
      try await snapshot(MicMeterView(meter: meter, micName: "ATEM Mini Extreme ISO G2", showsHeading: false).frame(width: 360, height: 96).padding(Space.md).background(Color(white: 0.12)),
                         name: "r10-mic-meter-horizontal-\(name)", size: .init(width: 400, height: 130), scheme: .dark, destination: destination, settleDelay: .milliseconds(200))
    }
    meter.reset()
  }
}
