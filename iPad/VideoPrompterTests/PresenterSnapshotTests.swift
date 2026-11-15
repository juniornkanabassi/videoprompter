import AVFoundation
import PrompterCore
import Combine
import CryptoKit
import Network
import SwiftUI
import UIKit
import XCTest

@testable import VideoPrompter

/// Draws the presenter offscreen to PNG files, for checking the iPad against the Mac's snapshots
/// without a window on any display. Run on a headless simulator (checks/ipad-presenter-shots.sh);
/// without VP_SHOTS_DIR the test does nothing.
@MainActor final class PresenterSnapshotTests: XCTestCase {
  private static let sizes: [(name: String, size: CGSize)] = [
    ("1180x820", CGSize(width: 1180, height: 820)),
    ("1366x1024", CGSize(width: 1366, height: 1024)),
    ("834x1194", CGSize(width: 834, height: 1194)),
  ]

  private static let script = """
    # Matchday preview

    Good evening, and welcome to the show. Tonight we look at how the title race has turned on a single weekend, and why the team in second place may be the happier one.

    First, the champions. They won again, but it was not pretty, and the manager knew it. Three shots on target all night, one of them a penalty.

    Second, the chasing pack. A late winner in the north, a comeback in the capital, and a goalkeeper who will want to forget his Saturday.

    Finally, the one result nobody saw coming. We will take it apart, minute by minute, and ask what it means for the run in.
    """

  func testHomeNavigationTiming() {
    XCTAssertTrue(HomeNavigation.initiallyShowsHome)
    XCTAssertFalse(HomeNavigation.shouldShowHome(backgroundTime: 0, now: 1000))
    XCTAssertFalse(HomeNavigation.shouldShowHome(backgroundTime: 100, now: 999))
    XCTAssertTrue(HomeNavigation.shouldShowHome(backgroundTime: 100, now: 1000))
  }

  func testSelectionRestoredAfterRelaunch() throws {
    let defaults = UserDefaults(suiteName: "home-relaunch-\(UUID().uuidString)")!
    let first = PadStore(defaults: defaults, discoverMicrophones: { [] })
    let script = try first.folder.create(title: "Relaunch \(UUID().uuidString)", markdown: Self.script)
    first.selectedID = script.id
    let relaunched = PadStore(defaults: defaults, discoverMicrophones: { [] })
    XCTAssertEqual(relaunched.selectedID, script.id)
  }

  func testBackgroundPresenterRestoration() throws {
    let store = PadStore(defaults: UserDefaults(suiteName: "home-presenter-\(UUID().uuidString)")!, discoverMicrophones: { [] })
    let script = try store.folder.create(title: "Resume \(UUID().uuidString)", markdown: Self.script)
    store.restoreBackgroundPresenter(script.id.uuidString)
    XCTAssertEqual(store.presentingID, script.id)
    store.closePresenter()
    store.restoreBackgroundPresenter("camera")
    XCTAssertTrue(store.cameraOnly)
    store.closePresenter()
    store.restoreBackgroundPresenter("missing")
    XCTAssertFalse(store.isPresenting)
  }

  func testMacPresentSelectsScriptFromHome() throws {
    let store = PadStore(defaults: UserDefaults(suiteName: "home-takeover-\(UUID().uuidString)")!, discoverMicrophones: { [] })
    let script = try store.folder.create(title: "Takeover \(UUID().uuidString)", markdown: Self.script)
    store.perform(.present(script.id))
    XCTAssertTrue(store.isPresenting)
    XCTAssertTrue(store.macOpenedPresenter)
    XCTAssertEqual(store.presentingID, script.id)
    XCTAssertEqual(store.selectedID, script.id)
    store.closePresenter()
    XCTAssertFalse(store.macOpenedPresenter)
    XCTAssertEqual(store.selectedID, script.id)
  }

  func testHomeAndLibraryShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "home-shots-\(UUID().uuidString)")!, discoverMicrophones: { [] })
    let last = try store.folder.create(title: "198 — 2026 PSG and 2011 Barcelona, a longer script title", markdown: Self.script)
    UserDefaults.standard.set(last.id.uuidString, forKey: "padLastOpenedScript")
    defer { UserDefaults.standard.removeObject(forKey: "padLastOpenedScript") }
    let states: [(String, HomeMacState)] = [("off", .off), ("searching", .looking("MacBook Pro")), ("connected", .connected("MacBook Pro", "USB-C"))]
    for (name, size) in Self.sizes {
      for (stateName, state) in states {
        _ = try await render(HomeScreen(showHome: .constant(true), snapshotMac: state).environmentObject(store), size: size,
          name: "ipad-home-\(stateName)-\(name)", directory: directory, beforeDraw: {})
      }
      _ = try await render(LibraryScreen(folder: store.folder, showHome: .constant(false)).environmentObject(store), size: size,
        name: "ipad-library-\(name)", directory: directory, beforeDraw: {})
    }
  }

  func testTextPanel() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "text-panel-\(UUID().uuidString)")!, discoverMicrophones: { [] })
    _ = try await render(PadPresenterTextSettings(store: store, session: store.session),
      size: CGSize(width: 440, height: 680), name: "ipad-presenter-text", directory: directory, beforeDraw: {})
  }

  func testLinkedSensorFrameMatchesMacPreview() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let url = URL(fileURLWithPath: directory)
    let expected = try JSONDecoder().decode([String: [[Double]]].self, from: Data(contentsOf: url.appendingPathComponent("linked-picture.json")))
    var reader = CameraLink.Reader()
    let messages = try reader.append(Data(contentsOf: url.appendingPathComponent("linked-picture.bin")))
    let layer = AVSampleBufferDisplayLayer()
    let view = LinkPreview.LinkView(displayLayer: layer)
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let exposure = PadExposure()
    exposure.update(.init(zebras: true, zebraLevel: 80))
    exposure.select(.linked)
    let receiver = LinkReceiver(renderer: layer.sampleBufferRenderer, exposure: exposure)
    let decoded = expectation(description: "Mac sensor frame decoded by iPad receiver")
    receiver.onEvent = { event in
      if case .frame(let time, _) = event, time != nil { decoded.fulfill() }
    }
    // The receiver acts on nothing before the Mac's hello.
    receiver.queue.sync { for message in [.hello(name: "Mac", version: CameraLink.protocolVersion)] + messages { receiver.handle(message) } }
    await fulfillment(of: [decoded], timeout: 5)
    for _ in 0..<100 where exposure.frame.zebraMask == nil { try await Task.sleep(for: .milliseconds(50)) }
    let mask = try XCTUnwrap(exposure.frame.zebraMask, "The real decoder must deliver sensor pixels")
    XCTAssertEqual(mask.width, 320)
    XCTAssertEqual(mask.height, 180)
    let bytes = try XCTUnwrap(mask.dataProvider?.data) as Data
    XCTAssertNotEqual(bytes[22 * mask.bytesPerRow + 40 * 4], 0, "Bright marker stays top left in decoded sensor coordinates")
    XCTAssertEqual(bytes[140 * mask.bytesPerRow + 280 * 4], 0)
    let markers = [CGPoint(x: 40, y: 22), CGPoint(x: 280, y: 140), CGPoint(x: 120, y: 70)]
    let store = PadStore(defaults: UserDefaults(suiteName: "linked-transform-\(UUID().uuidString)")!, discoverMicrophones: { [] })
    store.camera.selectedID = PadCamera.macLinkID
    for rotation in CameraRotation.allCases { for mirror in [false, true] {
      let status = CameraLink.Message.command(.macStatus(.init(cameraRotation: rotation.rawValue, cameraMirrored: mirror)))
      for message in try reader.append(status.encoded()) {
        if case .command(let command) = message { store.perform(command) }
      }
      view.update(size: CGSize(width: 320, height: 180), mirrored: store.camera.linkedMirrored, guides: store.camera.previewGuides)
      view.layoutIfNeeded()
      let points = try XCTUnwrap(expected["\(rotation.rawValue)-\(mirror)"])
      for (index, point) in markers.enumerated() {
        let local = CGPoint(x: point.x / 320 * layer.bounds.width, y: point.y / 180 * layer.bounds.height)
        let actual = layer.convert(local, to: view.layer)
        XCTAssertEqual(actual.x, points[index][0], accuracy: 0.01)
        XCTAssertEqual(actual.y, points[index][1], accuracy: 0.01)
      }
    } }
  }

  func testMacMicrophoneDefaultHonoursChoiceAndDoesNotRetryFailure() {
    let store = PadStore(defaults: UserDefaults(suiteName: "mic-default-\(UUID().uuidString)")!, discoverMicrophones: { [] })
    XCTAssertFalse(store.requestDefaultMacMicrophone(), "Wait for a capable Mac")
    store.perform(.macStatus(.init(supportsMicSelection: true)))
    store.camera.selectedID = PadCamera.macLinkID
    XCTAssertTrue(store.requestDefaultMacMicrophone())
    XCTAssertFalse(store.requestDefaultMacMicrophone(), "Already requested")
    store.perform(.voiceSource("iPad"))
    XCTAssertFalse(store.requestDefaultMacMicrophone(), "Relay failure must retain local fallback")
    let chosen = PadStore(defaults: UserDefaults(suiteName: "mic-choice-\(UUID().uuidString)")!, discoverMicrophones: { [] })
    chosen.chooseMicrophone("", onMac: false)
    chosen.camera.selectedID = PadCamera.macLinkID
    chosen.perform(.macStatus(.init(supportsMicSelection: true)))
    XCTAssertTrue(chosen.microphoneChosen)
    XCTAssertFalse(chosen.requestDefaultMacMicrophone())
    XCTAssertFalse(chosen.session.followsRemote)
  }

  func testLegacyFocusOffAndCountdownCancellation() throws {
    let store = PadStore(defaults: UserDefaults(suiteName: "legacy-focus-\(UUID())")!, discoverMicrophones: { [] })
    store.perform(.look(.init(focusMode: true)))
    XCTAssertTrue(store.cleanScreen)
    store.perform(.look(.init(focusMode: false)))
    XCTAssertFalse(store.cleanScreen)
    XCTAssertEqual(store.remoteState.look?.focusMode, false)
    store.chooseCleanLook(.pictureOnly)
    store.perform(.look(.init(focusMode: false)))
    XCTAssertTrue(store.cleanScreen, "Legacy Focus off must leave other looks alone")
    let script = try store.folder.create(title: "Countdown", markdown: Self.script)
    store.present(script)
    store.settings.mode = "Manual"
    store.session.startDelay = 3
    store.perform(.play)
    XCTAssertGreaterThan(store.remoteState.countdownRemaining ?? 0, 0)
    store.perform(.pause)
    XCTAssertFalse(store.session.isCountingDown)
  }

  func testCleanLooksPreserveReadingAndRoundTrip() throws {
    let store = PadStore(defaults: UserDefaults(suiteName: "clean-looks-\(UUID())")!, discoverMicrophones: { [] })
    let script = try store.folder.create(title: "Clean looks", markdown: Self.script)
    store.present(script)
    store.settings.mode = "Manual"
    store.session.play(captureAudio: false)
    defer { store.session.pause() }
    for look in PadRemote.CleanLook.allCases {
      store.perform(.look(.init(cleanLook: look, keepMicMeter: false)))
      store.perform(.cleanScreen(true))
      XCTAssertTrue(store.session.isActivelyRunning)
      XCTAssertEqual(store.remoteState.look?.cleanLook, look)
      XCTAssertEqual(store.remoteState.look?.keepMicMeter, false)
      store.chooseCleanLook(look)
      XCTAssertFalse(store.cleanScreen)
      XCTAssertTrue(store.session.isActivelyRunning)
    }
  }

  func testBandGeometryAndLookSettings() throws {
    let store = PadStore(defaults: UserDefaults(suiteName: "band-settings-\(UUID().uuidString)")!)
    store.perform(.look(.init(readingBandOpacity: 0.3, videoDimming: 0.9)))
    XCTAssertEqual(store.settings.readingBandOpacity, 0.3)
    XCTAssertEqual(store.settings.videoDimming, 0.9)
    XCTAssertEqual(store.remoteState.look?.readingBandOpacity, 0.3)
    XCTAssertEqual(store.remoteState.look?.videoDimming, 0.9)
    store.perform(.look(.init(readingBandOpacity: -1, videoDimming: 2)))
    XCTAssertEqual(store.settings.readingBandOpacity, 0)
    XCTAssertEqual(store.settings.videoDimming, 1)
    let manager = ReadingBandLayoutManager()
    let storage = NSTextStorage()
    let container = NSTextContainer(size: CGSize(width: 600, height: 1000))
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    let text = CanvasTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000), textContainer: container)
    text.attributedText = NSAttributedString(string: "First line\nSecond line", attributes: [.font: UIFont.systemFont(ofSize: 48)])
    text.readingBandRange = NSRange(location: 0, length: 5)
    text.updateReadingBand()
    let first = try XCTUnwrap(text.readingBandRect)
    let line = text.layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    XCTAssertEqual(first.minY, line.minY + text.textContainerInset.top)
    XCTAssertEqual(first.height, line.height)
    text.readingBandRange = NSRange(location: 6, length: 4)
    text.updateReadingBand()
    XCTAssertEqual(text.readingBandRect, first)
    text.readingBandRange = NSRange(location: 11, length: 6)
    text.updateReadingBand()
    XCTAssertGreaterThan(try XCTUnwrap(text.readingBandRect).minY, first.minY)
  }

  func testBandDimmingShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "band-shots-\(UUID().uuidString)")!)
    store.settings.mode = "Manual"
    store.settings.fontSize = 48
    let script = try store.folder.create(title: "Band shots", markdown: Self.script)
    store.present(script)
    store.setMirror(false)
    store.setFlip(false)
    store.session.seek(to: 24)
    store.setPictureMode(.behindScript)
    let picture = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540)).image { context in
      UIColor(white: 0.6, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 400, height: 540))
    }
    for dimming in [0.0, 0.5, 0.9] {
      store.settings.videoDimming = dimming
      _ = try await render(PresenterScreen(session: store.session, camera: store.camera,
        startsReading: true, referencePicture: picture).environmentObject(store),
        size: CGSize(width: 1180, height: 820), name: "ipad-band-dim-\(Int(dimming * 100))", directory: directory, beforeDraw: {})
    }
  }

  func testBundledFontsAndSpacing() throws {
    XCTAssertEqual(ScriptRenderer.presenterFonts, ["SF Pro", "Helvetica Neue", "Georgia", "Avenir Next", "Poppins", "Lexend", "Lexend Deca"])
    for family in ["Lexend Deca", "Lexend", "Poppins"] {
      var style = ScriptStyle()
      style.fontName = family
      XCTAssertEqual(ScriptRenderer.font(style).familyName, family)
      XCTAssertNotNil(Bundle.main.url(forResource: family == "Poppins" ? "Poppins-Regular" : family == "Lexend" ? "Lexend-Variable" : "LexendDeca-Variable", withExtension: "ttf"))
    }
    for size in [24.0, 48, 96] {
      var style = ScriptStyle()
      style.fontSize = size
      let rendered = ScriptRenderer.render(PrompterDocument(markdown: "First paragraph.\n\nSecond paragraph."), style: style)
      let paragraph = try XCTUnwrap(rendered.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
      XCTAssertEqual(paragraph.lineSpacing, max(3, size * style.lineSpacing))
      XCTAssertEqual(paragraph.paragraphSpacing, max(10, size * style.paragraphSpacing))
      XCTAssertTrue(rendered.text.string.contains("\n\n"))
    }
    let document = PrompterDocument(markdown: "Current word")
    var highlighted = ScriptStyle()
    highlighted.highlightActiveWord = true
    let view = UITextView()
    let coordinator = ScriptCanvas.Coordinator()
    coordinator.textView = view
    coordinator.parent = ScriptCanvas(document: document, tokenIndex: 0,
      layoutGuideFraction: 0.35, style: highlighted, textWidth: 0.75, onSeek: { _ in })
    coordinator.render(document: document, style: highlighted)
    XCTAssertEqual((view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?.resolvedColor(with: view.traitCollection), UIColor.systemYellow.resolvedColor(with: view.traitCollection))
    XCTAssertEqual(ScriptCanvas.sideInset(width: 1366, textWidth: 1, fontSize: 24), (1366 - 720) / 2)
    for width: CGFloat in [1180, 1366] {
      XCTAssertEqual(ScriptCanvas.sideInset(width: width, textWidth: 0.8), max(42, width * 0.1), accuracy: 0.001)
    }
  }

  func testRemotePresenterBarControls() {
    let store = PadStore(defaults: UserDefaults(suiteName: "presenter-controls-\(UUID().uuidString)")!)
    store.perform(.look(.init(scriptVisible: false, presenterSetup: false, focusMode: true)))
    XCTAssertFalse(store.scriptVisible)
    XCTAssertFalse(store.presenterSetup)
    XCTAssertTrue(store.focusMode)
    XCTAssertEqual(store.remoteState.look?.scriptVisible, false)
    XCTAssertEqual(store.remoteState.look?.focusMode, true)
    store.perform(.look(.init(presenterSetup: true)))
    XCTAssertTrue(store.presenterSetup)
    XCTAssertFalse(store.session.isActivelyRunning)
  }

  func testPresenterCloseAndCameraOnlyResetTransientControls() throws {
    guard ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] != nil else { throw XCTSkip("Snapshot capture guard required") }
    let store = PadStore(defaults: UserDefaults(suiteName: "presenter-reset-\(UUID().uuidString)")!)
    store.settings.mode = "Manual"
    store.perform(.voiceSource("Mac"))
    XCTAssertFalse(store.session.followsRemote)
    XCTAssertEqual(store.settings.mode, "Manual")
    store.scriptVisible = false
    store.focusMode = true
    store.presenterSetup = false
    store.closePresenter()
    XCTAssertTrue(store.scriptVisible)
    XCTAssertFalse(store.focusMode)
    XCTAssertTrue(store.presenterSetup)
    let script = try store.folder.create(title: "Reset \(UUID().uuidString)", markdown: Self.script)
    store.present(script)
    XCTAssertTrue(store.scriptVisible, "The next script must not inherit a hidden script")
    store.closePresenter()
    store.scriptVisible = false
    store.focusMode = true
    store.presenterSetup = false
    store.presentCamera()
    XCTAssertTrue(store.scriptVisible)
    XCTAssertFalse(store.focusMode)
    XCTAssertTrue(store.presenterSetup)
    store.closePresenter()
  }

  func testMicrophoneListIsCachedUntilTheAudioRouteChanges() async {
    var reads = 0
    var sources = [PadRemote.Source(id: "built-in", name: "iPad microphone", connection: "Built-in")]
    let store = PadStore(defaults: UserDefaults(suiteName: "microphone-cache-\(UUID().uuidString)")!, discoverMicrophones: {
      reads += 1
      return sources
    })
    XCTAssertEqual(reads, 1)
    for _ in 0..<10 {
      XCTAssertEqual(store.remoteState.localMicrophones, sources)
      XCTAssertEqual(store.remoteState.selectedMicrophone, "built-in")
    }
    XCTAssertEqual(reads, 1, "State broadcasts must not enumerate audio inputs")
    sources = [.init(id: "usb", name: "USB microphone")]
    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(store.remoteState.localMicrophones, sources)
    XCTAssertEqual(store.remoteState.selectedMicrophone, "usb")
    XCTAssertEqual(reads, 2)
  }

  func testFocusRemovesLiveCameraPreviewsAndSetupRestoresThem() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "live-focus-\(UUID().uuidString)")!)
    store.settings.mode = "Manual"
    store.settings.horizontalMirror = false
    store.setPictureMode(.behindScript)
    let script = try store.folder.create(title: "Focus \(UUID().uuidString)", markdown: Self.script)
    store.present(script)
    func previews(_ view: UIView) -> [UIView] {
      let current = view is CameraPreview.PreviewView || view is LinkPreview.LinkView ? [view] : []
      return current + view.subviews.flatMap(previews)
    }
    for source in ["local", "mac"] {
      store.camera.selectedID = source == "mac" ? PadCamera.macLinkID : "capture"
      store.camera.isOn = true
      for state in ["reading", "focus", "setup"] {
        store.setCleanScreen(false)
        if state == "focus" { store.chooseCleanLook(.scriptOnly) }
        _ = try await render(PresenterScreen(session: store.session, camera: store.camera, startsReading: state != "setup")
          .environmentObject(store), size: CGSize(width: 1180, height: 820),
          name: "ipad-live-\(source)-\(state)", directory: directory, inspect: { root in
            XCTAssertEqual(previews(root).count, state == "focus" ? 0 : 1, "\(source) \(state)")
          }, beforeDraw: {})
      }
    }
    store.camera.isOn = false
    store.closePresenter()
  }

  func testRotationFollowsSourceAndKeepsExposureAligned() throws {
    guard ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] != nil else { throw XCTSkip("Snapshot capture guard required") }
    let store = PadStore(defaults: UserDefaults(suiteName: "rotation-\(UUID().uuidString)")!)
    store.camera.pickerSnapshotDevices()
    store.perform(.selectCamera("capture", onIPad: true))
    store.perform(.cameraGuides(.init(rotation: 270)))
    XCTAssertEqual(store.camera.guides.rotation, .threeQuarters)
    XCTAssertEqual(store.remoteState.guides?.rotation, 270)
    store.perform(.cameraGuides(.init(rotation: 45)))
    XCTAssertEqual(store.camera.guides.rotation, .threeQuarters)
    store.perform(.macStatus(.init(cameraRotation: 90)))
    XCTAssertEqual(store.camera.guides.rotation, .threeQuarters, "A Mac update must not rotate the local camera")
    store.perform(.selectCamera("fx3"))
    store.perform(.macStatus(.init(cameraRotation: 90, cameraMirrored: true)))
    XCTAssertEqual(store.camera.guides.rotation, .quarter)
    XCTAssertTrue(store.camera.linkedMirrored)
    store.perform(.macStatus(.init(micLevelDB: -20)))
    XCTAssertTrue(store.camera.linkedMirrored, "Partial status must preserve camera mirror")

    let layer = AVSampleBufferDisplayLayer()
    let view = LinkPreview.LinkView(displayLayer: layer)
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    for rotation in CameraRotation.allCases {
      for mirror in [false, true] {
        var guides = CameraGuides()
        guides.rotation = rotation
        guides.zebras = true
        guides.falseColour = true
        guides.thirds = true
        view.update(size: CGSize(width: 1920, height: 1080), mirrored: mirror, guides: guides)
        view.layoutIfNeeded()
        let exposure = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? PadExposureLayer }.first)
        XCTAssertEqual(layer.affineTransform(), rotation.displayTransform(mirrored: mirror))
        XCTAssertEqual(exposure.affineTransform(), layer.affineTransform())
        XCTAssertEqual(exposure.bounds, layer.bounds)
        XCTAssertEqual(exposure.position, layer.position)
        let fitted = rotation.fittedRect(aspect: CGSize(width: 1920, height: 1080), in: view.bounds)
        XCTAssertEqual(layer.position, CGPoint(x: fitted.midX, y: fitted.midY))
      }
    }
  }

  func testPresenterDefaultsPreserveSavedOrientation() throws {
    let suite = "orientation-defaults-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = PadStore(defaults: defaults)
    XCTAssertFalse(fresh.mirror, "First launch reads normally on the iPad")
    XCTAssertFalse(fresh.flip)
    for mirror in [false, true] {
      for flip in [false, true] {
        var saved = PrompterSettings()
        saved.horizontalMirror = mirror
        saved.verticalMirror = flip
        defaults.set(try JSONEncoder().encode(saved), forKey: "padSettings")
        let restored = PadStore(defaults: defaults)
        XCTAssertEqual(restored.mirror, mirror)
        XCTAssertEqual(restored.flip, flip)
      }
    }
  }

  /// Exercise the actual native camera hosts, not only ExposureReferencePicture's still layer.
  func testNativeCameraAndTextSharePresenterOrientation() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "native-orientation-\(UUID().uuidString)")!)
    store.settings.mode = "Manual"
    let script = try store.folder.create(title: "Orientation fixture", markdown: Self.script)
    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    func assertOrientation(_ view: UIView, in root: UIView, mirror: Bool, flip: Bool, label: String) {
      let origin = view.convert(CGPoint.zero, to: root)
      let x = view.convert(CGPoint(x: 10, y: 0), to: root)
      let y = view.convert(CGPoint(x: 0, y: 10), to: root)
      XCTAssertEqual(x.x - origin.x, mirror ? -10 : 10, accuracy: 0.01, label)
      XCTAssertEqual(y.y - origin.y, flip ? -10 : 10, accuracy: 0.01, label)
    }
    for source in ["local", "mac"] {
      for cameraOnly in [false, true] {
        for mirror in [false, true] {
          for flip in [false, true] {
            for cameraMirror in [false, true] {
              store.closePresenter()
              if cameraOnly { store.presentCamera() } else { store.present(script) }
              store.setPictureMode(.behindScript)
              store.camera.link.pickerSnapshotConnection(source == "mac" ? "Fixture Mac" : nil)
              store.perform(.macStatus(.init(cameraOn: source == "mac")))
              store.camera.selectedID = source == "mac" ? PadCamera.macLinkID : "capture"
              store.camera.isOn = true
              store.camera.mirrored = cameraMirror
              store.camera.linkedMirrored = cameraMirror
              store.camera.guides.rotation = .quarter
              store.camera.guides.thirds = true
              store.setMirror(mirror)
              store.setFlip(flip)
              let label = "\(source)-\(cameraOnly ? "camera" : "script")-m\(mirror)-f\(flip)-selfie\(cameraMirror)"
              _ = try await render(PresenterScreen(session: store.session, camera: store.camera, startsReading: true)
                .environmentObject(store), size: CGSize(width: 1180, height: 820),
                name: "ipad-native-\(label)", directory: directory, inspect: { root in
                  let views = descendants(root)
                  let previews = views.filter { $0 is CameraPreview.PreviewView || $0 is LinkPreview.LinkView }
                  XCTAssertEqual(previews.count, 1, label)
                  for preview in previews {
                    assertOrientation(preview, in: root, mirror: mirror, flip: flip, label: label)
                    let exposure = (preview as? CameraPreview.PreviewView)?.exposure
                      ?? (preview as? LinkPreview.LinkView)?.exposure
                    if let exposure {
                      let origin = exposure.convert(CGPoint.zero, to: root.layer)
                      let x = exposure.convert(CGPoint(x: 10, y: 0), to: root.layer)
                      let y = exposure.convert(CGPoint(x: 0, y: 10), to: root.layer)
                      // Rotate the sensor 90 degrees, apply selfie mirror, then turn the whole stage.
                      XCTAssertEqual(x.x - origin.x, 0, accuracy: 0.01, label)
                      XCTAssertEqual(x.y - origin.y, source == "mac" ? (flip ? 10 : -10) : (flip ? -10 : 10), accuracy: 0.01, label)
                      XCTAssertEqual(y.x - origin.x, source == "mac" ? (cameraMirror != mirror ? -10 : 10) : (cameraMirror != mirror ? 10 : -10), accuracy: 0.01, label)
                      XCTAssertEqual(y.y - origin.y, 0, accuracy: 0.01, label)
                    } else { XCTFail("Missing exposure layer: \(label)") }
                  }
                  if !cameraOnly {
                    let texts = views.compactMap { $0 as? UITextView }
                    XCTAssertFalse(texts.isEmpty, label)
                    for text in texts { assertOrientation(text, in: root, mirror: mirror, flip: flip, label: label) }
                  }
                }, beforeDraw: {})
            }
          }
        }
      }
    }
    store.camera.isOn = false
  }

  func testRotationShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "rotation-shots-\(UUID().uuidString)")!)
    store.settings.horizontalMirror = false
    store.presentCamera()
    let picture = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540)).image { context in
      UIColor(white: 0.45, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
    }
    for rotation in CameraRotation.allCases {
      store.camera.guides.rotation = rotation
      store.camera.guides.zebras = true
      store.camera.guides.thirds = true
      store.setMirror(rotation == .quarter)
      store.setFlip(rotation == .threeQuarters)
      _ = try await render(PresenterScreen(session: store.session, camera: store.camera, referencePicture: picture).environmentObject(store),
        size: CGSize(width: 1180, height: 820), name: "ipad-rotation-\(rotation.rawValue)", directory: directory, beforeDraw: {})
    }
  }

  func testRemoteCameraSelectionReportsTheActualSide() throws {
    guard ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] != nil else { throw XCTSkip("Snapshot capture guard required") }
    let store = PadStore(defaults: UserDefaults(suiteName: "selection-\(UUID().uuidString)")!)
    store.camera.pickerSnapshotDevices()
    store.perform(.selectCamera("capture", onIPad: true))
    XCTAssertEqual(store.camera.selectedID, "capture")
    XCTAssertEqual(store.remoteState.localCameraID, "capture")
    XCTAssertEqual(store.remoteState.localCameras?.count, 2)
    store.perform(.selectCamera("not-a-device", onIPad: true))
    XCTAssertEqual(store.camera.selectedID, "capture")
    store.perform(.selectCamera("fx3"))
    XCTAssertTrue(store.camera.isShowingMac)
    XCTAssertNil(store.remoteState.localCameraID)
  }

  func testRemoteTypographySettings() {
    let store = PadStore(defaults: UserDefaults(suiteName: "text-sync-\(UUID().uuidString)")!)
    store.perform(.look(.init(fontName: "Lexend", fontWeight: "Bold", textColorHex: "#F5CF4A",
      textOpacity: 0.8, paragraphSpacing: 0.6, alignment: "Center", showCues: true)))
    XCTAssertEqual(store.settings.fontName, "Lexend")
    XCTAssertEqual(store.settings.fontWeight, "Bold")
    XCTAssertEqual(store.settings.textOpacity, 0.8)
    XCTAssertEqual(store.settings.paragraphSpacing, 0.6)
    XCTAssertEqual(store.settings.alignment, "Center")
    XCTAssertTrue(store.settings.showCues)
  }

  func testDisplayLinkScrollSmoothness() async throws {
    let start = CACurrentMediaTime()
    let document = PrompterDocument(markdown: String(repeating: "Reading this sentence keeps the scrolling continuously in motion. ", count: 120))
    let canvas = ScriptCanvas(document: document, tokenIndex: 0, isActivelyRunning: true,
      layoutGuideFraction: 0.35, style: ScriptStyle(), textWidth: 0.75,
      // Continuous, as SessionStore's Manual clock and VoiceGlide both are: the canvas adds no smoothing of its own.
      manualPosition: { (CACurrentMediaTime() - start) * 8 }, onSeek: { _ in })
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
    window.rootViewController = UIHostingController(rootView: canvas)
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    func findText(_ view: UIView) -> UITextView? {
      if let text = view as? UITextView { return text }
      return view.subviews.compactMap(findText).first
    }
    let text = try XCTUnwrap(findText(window))
    let probe = ScrollFrameProbe(text: text)
    let link = CADisplayLink(target: probe, selector: #selector(ScrollFrameProbe.sample(_:)))
    link.add(to: .main, forMode: .common)
    try await Task.sleep(for: .seconds(4))
    link.invalidate()
    let samples = Array(probe.samples.dropFirst(20))
    if let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] {
      let rows = probe.samples.map { ["time": $0.time, "offset": Double($0.y)] }
      let data = try JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted)
      try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("scroll-frames.json"))
    }
    XCTAssertGreaterThan(samples.count, 60)
    var stalls = 0
    for (before, after) in zip(samples, samples.dropFirst()) {
      XCTAssertGreaterThanOrEqual(after.y - before.y, -0.01, "Backwards jump")
      stalls = after.y - before.y < 0.01 ? stalls + 1 : 0
      XCTAssertLessThanOrEqual(stalls, 2, "Offset stalled for more than two refreshes")
      XCTAssertLessThan(after.time - before.time, 3.0 / 60, "Main thread missed more than two 60 Hz refreshes")
    }
  }

  func testTextParityShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    var settings = PrompterSettings()
    settings.fontSize = 48
    settings.highlightActiveWord = true
    let document = PrompterDocument(markdown: Self.script)
    for (name, size) in Self.sizes.prefix(2) {
      let canvas = ScriptCanvas(document: document, tokenIndex: 24, lastConfirmedTokenIndex: 23,
        layoutGuideFraction: 0.35, style: ScriptStyle(settings), textWidth: settings.textWidth, onSeek: { _ in })
      _ = try await render(ZStack(alignment: .top) {
        Color.black
        canvas.mask(VStack(spacing: 0) {
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 48 * 1.6) // grid: ok Matches the Mac viewport fade.
        })
      }.ignoresSafeArea(), size: size, name: "ipad-text-" + name, directory: directory, beforeDraw: {})
    }
  }

  func testPresenterShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "vp-shots-\(UUID().uuidString)")!
    let store = PadStore(defaults: defaults)
    store.settings.horizontalMirror = false
    store.settings.mode = "Manual"
    store.settings.fontSize = 48
    store.settings.videoDimming = 0 // Keep orientation colour probes independent of dimming.
    let script = try store.folder.create(title: "Shots \(UUID().uuidString.prefix(6))", markdown: Self.script)
    // The script stays in the throwaway simulator's folder; deleting it here waits on the folder watcher.
    store.present(script)
    let session = store.session
    session.seek(to: 24)

    let picture = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540)).image { context in
      UIColor(white: 0.18, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
      UIColor.blue.setFill()
      context.fill(CGRect(x: 720, y: 380, width: 240, height: 160))
      ("TOP LEFT →" as NSString).draw(at: CGPoint(x: 32, y: 32), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.white])
    }
    for state in ["pictureOnly", "pictureAndScript", "scriptOnly", "setup", "camera-only", "reading-camera", "mirrored", "flipped", "mirrored-flipped", "camera-only-mirrored", "camera-only-flipped", "camera-only-mirrored-flipped", "monitor", "monitor-mirrored", "monitor-flipped", "monitor-mirrored-flipped", "mac-lost"] {
      store.closePresenter()
      session.pause()
      store.setMirror(state.contains("mirrored"))
      store.setFlip(state.contains("flipped"))
      if state.hasPrefix("camera-only") { store.presentCamera() } else { store.present(script) }
      store.setPictureMode(state.hasPrefix("monitor") ? .monitorOnly : .behindScript)
      store.setCleanScreen(false)
      if let look = PadRemote.CleanLook(rawValue: state) { store.chooseCleanLook(look) }
      session.seek(to: 24)
      if state == "reading-camera" || state.contains("mirrored") || state == "flipped" { session.play(captureAudio: false) }
      for (name, size) in Self.sizes {
        let image = try await render(PresenterScreen(session: session, camera: store.camera,
          startsReading: state != "setup" && state != "camera-only", referencePicture: picture,
          previouslyConnected: state == "mac-lost").environmentObject(store),
          size: size, name: "ipad-\(state)-\(name)", directory: directory) {
          store.micMeter.show(-9)
        }
        if name == "1180x820", ["reading-camera", "mirrored", "flipped", "mirrored-flipped"].contains(state) {
          // The persistent camera card covers red; find the blue marker in its expected quadrant.
          let cg = try XCTUnwrap(image.cgImage)
          var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
          let context = try XCTUnwrap(CGContext(data: &rgba, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
          let xs = store.mirror ? 0..<cg.width / 2 : cg.width / 2..<cg.width
          let ys = store.flip ? 0..<cg.height / 2 : cg.height / 2..<cg.height
          let hasMarker = ys.contains { y in xs.contains { x in
            let offset = (y * cg.width + x) * 4
            return rgba[offset] < 40 && rgba[offset + 1] < 40 && rgba[offset + 2] > 200
          } }
          XCTAssertTrue(hasMarker, state)
        }
      }
    }
    session.pause()
  }

  func testExposureShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "exposure-shots-\(UUID().uuidString)")!)
    store.settings.mode = "Manual"
    store.settings.horizontalMirror = false
    store.presentCamera()
    store.setPictureMode(.behindScript)
    var visibilityUpdates = 0
    let visibility = store.camera.objectWillChange.sink { visibilityUpdates += 1 }
    store.camera.setExposureHidden(false)
    store.camera.setExposureHidden(false)
    XCTAssertEqual(visibilityUpdates, 0, "An unchanged visibility must not invalidate the presenter again")
    store.camera.setExposureHidden(true)
    XCTAssertEqual(visibilityUpdates, 1)
    visibility.cancel()
    store.camera.setExposureHidden(false)
    let states = ["zebra-45ire", "false-colour-ramp", "zebra-45ire-flip", "false-colour-ramp-flip", "meter-white", "meter-black", "camera-only-rounded"]
    for state in states {
      store.setFlip(state.hasSuffix("-flip"))
      store.camera.guides.zebras = state.hasPrefix("zebra")
      store.camera.guides.useZebraPreset(.faceReference)
      store.camera.guides.falseColour = state.hasPrefix("false")
      let picture = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540)).image { context in
        if state.hasPrefix("false") {
          for y in 0..<540 {
            UIColor(white: CGFloat(y) / 539, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: y, width: 960, height: 1))
          }
        } else {
          UIColor(white: state == "meter-white" ? 1 : state == "meter-black" ? 0 : 115.0 / 255, alpha: 1).setFill()
          context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
          if state.hasPrefix("zebra") {
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
          }
        }
      }
      for (name, size) in Self.sizes.prefix(2) {
        _ = try await render(PresenterScreen(session: store.session, camera: store.camera,
          referencePicture: picture).environmentObject(store), size: size,
          name: "\(state)-\(name)", directory: directory) { store.micMeter.show(-9) }
      }
    }
  }

  func testPickerShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "picker-shots-\(UUID().uuidString)")!)
    store.settings.mode = "Manual"
    store.settings.horizontalMirror = false
    let reference = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540)).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
    }
    let script = try store.folder.create(title: "Picker fixture", markdown: Self.script)
    store.present(script)
    for state in ["3A", "3B", "3C"] {
      let status = PadRemote.MacStatus(
        cameras: [.init(id: "fx3", name: "Sony FX3", connection: "HDMI capture", width: 1920, height: 1080, fps: 25),
          .init(id: "face", name: "FaceTime HD Camera", connection: "Built-in", width: 1280, height: 720, fps: 30)],
        selectedCamera: "fx3", cameraOn: true,
        microphones: [.init(id: "external", name: "External Microphone", connection: "USB", channels: 2, sampleRate: 48000),
          .init(id: "built-in", name: "MacBook Pro Microphone", connection: "Built-in", channels: 1, sampleRate: 48000)],
        selectedMicrophone: "external", displayName: "Junior’s MacBook Pro", connectionKind: "USB-C",
        supportsMicSelection: true, microphoneChannel: "Both")
      store.camera.link.pickerSnapshotConnection(state == "3C" ? nil : "Junior’s MacBook Pro")
      store.camera.pickerSnapshotDevices()
      store.camera.selectedID = state == "3C" ? "capture" : PadCamera.macLinkID
      if state == "3C" { store.perform(.macStatus(.init(connectionKind: ""))) }
      if state == "3B" { store.perform(.voiceSource("Mac")) }
      for (name, size) in Self.sizes.prefix(2) {
        store.present(script)
        store.session.seek(to: 24)
        store.camera.guides = CameraGuides()
        if state == "3B" { store.perform(.voiceSource("Mac")) }
        _ = try await render(PresenterScreen(session: store.session, camera: store.camera, referencePicture: reference, snapshotPicker: state == "3B")
          .environmentObject(store), size: size, name: "ipad-picker-\(state)-\(name)", directory: directory) {
            store.perform(.macStatus(status))
            store.camera.link.pickerSnapshotConnection(state == "3C" ? nil : "Junior’s MacBook Pro")
            store.camera.pickerSnapshotDevices()
            store.camera.selectedID = state == "3C" ? "capture" : PadCamera.macLinkID
            store.setPictureMode(.behindScript)
            store.micMeter.show(-12)
          }
      }
    }
  }

  func testPairingShots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["VP_SHOTS_DIR"] else { throw XCTSkip("Set VP_SHOTS_DIR") }
    let store = PadStore(defaults: UserDefaults(suiteName: "qr-shots-\(UUID().uuidString)")!)
    let legacyKey = store.camera.link.pairingCode
    KnownMacs.note(name: "USB history fixture", kind: "USB-C")
    store.camera.link.forgetMac(id: "USB history fixture")
    XCTAssertEqual(store.camera.link.pairingCode, legacyKey, "Forgetting USB history must preserve Wi-Fi pairings")
    _ = try await render(MacControlScreen(link: store.camera.link).environmentObject(store),
      size: CGSize(width: 1180, height: 820), name: "qr-ipad-connect", directory: directory, beforeDraw: {})
    let key = Curve25519.KeyAgreement.PrivateKey()
    store.camera.link.pendingPermission = .init(request: .init(id: UUID().uuidString, name: "Studio Mac",
      publicKeyCommitment: PairingExchange.commitment(key.publicKey.rawRepresentation)),
      connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), privateKey: key,
      peerPublicKey: key.publicKey.rawRepresentation, confirmationCode: "482916")
    _ = try await render(MacControlScreen(link: store.camera.link).environmentObject(store)
      .modifier(PairingPresentation(link: store.camera.link)),
      size: CGSize(width: 1180, height: 820), name: "qr-ipad-allow", directory: directory, beforeDraw: {})
    store.camera.link.approvePairing(false)
    _ = try await render(PairingScanner(link: store.camera.link),
      size: CGSize(width: 1180, height: 820), name: "qr-ipad-scanner", directory: directory, beforeDraw: {})
    store.camera.link.scanStatus = "That code has expired. On the Mac, choose New code, then scan again."
    _ = try await render(MacControlScreen(link: store.camera.link, failure: store.camera.link.scanStatus).environmentObject(store),
      size: CGSize(width: 1180, height: 820), name: "qr-ipad-expired", directory: directory, beforeDraw: {})
  }

  /// A window the size of the iPad (or a Stage Manager window), drawn into a PNG once SwiftUI has laid out.
  private func render<V: View>(_ view: V, size: CGSize, name: String, directory: String,
    inspect: ((UIView) -> Void)? = nil, beforeDraw: () -> Void) async throws -> UIImage {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
    window.frame = CGRect(origin: .zero, size: size)
    let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
    window.rootViewController = host
    window.isHidden = false
    host.view.frame = window.bounds
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .seconds(1))
    beforeDraw()
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .seconds(1))
    inspect?(host.view)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    window.isHidden = true
    let data = try XCTUnwrap(image.pngData())
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    return image
  }
}

@MainActor private final class ScrollFrameProbe: NSObject {
  weak var text: UITextView?
  var samples: [(time: Double, y: CGFloat)] = []
  init(text: UITextView) { self.text = text }
  @objc func sample(_ link: CADisplayLink) {
    if let text { samples.append((link.timestamp, text.contentOffset.y)) }
  }
}
