import PrompterCore
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

  func testBundledFontsAndSpacing() throws {
    for family in ["Lexend Deca", "Lexend"] {
      var style = ScriptStyle()
      style.fontName = family
      XCTAssertEqual(ScriptRenderer.font(style).familyName, family)
      XCTAssertNotNil(Bundle.main.url(forResource: family == "Lexend" ? "Lexend-Variable" : "LexendDeca-Variable", withExtension: "ttf"))
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
      manualPosition: { floor((CACurrentMediaTime() - start) * 8) }, onSeek: { _ in })
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
        PresenterReadingLine(settings: settings)
          .frame(width: size.width - 2 * ScriptCanvas.sideInset(width: size.width, textWidth: settings.textWidth) + 64)
          .offset(y: size.height * 0.35 - PresenterReadingLine.bandHeight(fontSize: 48))
        canvas.mask(VStack(spacing: 0) {
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 48 * 1.6)
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
    for state in ["setup", "camera-only", "reading-camera", "mirrored", "flipped", "mirrored-flipped", "camera-only-mirrored", "camera-only-flipped", "camera-only-mirrored-flipped", "monitor", "monitor-mirrored", "monitor-flipped", "monitor-mirrored-flipped", "mac-lost"] {
      store.closePresenter()
      session.pause()
      store.setMirror(state.contains("mirrored"))
      store.setFlip(state.contains("flipped"))
      if state.hasPrefix("camera-only") { store.presentCamera() } else { store.present(script) }
      store.setPictureMode(state.hasPrefix("monitor") ? .monitorOnly : .behindScript)
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
          // The red upper-left corner must travel with the text's presenter transform.
          let scale = CGFloat(try XCTUnwrap(image.cgImage).width) / size.width
          let point = CGPoint(x: (store.mirror ? 1120 : 60) * scale, y: (store.flip ? 720 : 100) * scale)
          let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
          var rgba = [UInt8](repeating: 0, count: 4)
          let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
          XCTAssertGreaterThan(rgba[0], 200, state)
          XCTAssertLessThan(rgba[2], 40, state)
        }
      }
    }
    session.pause()
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
  private func render<V: View>(_ view: V, size: CGSize, name: String, directory: String, beforeDraw: () -> Void) async throws -> UIImage {
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
