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
