import XCTest

/// The iPad app cannot be built by SwiftPM, so these pin the wiring of Camera Only's safety rules in
/// its source, as PadEditingTests does; the headless end-to-end check exercises the Mac side of them.
final class PadCameraOnlyTests: XCTestCase {
  private func source(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  /// With no script on screen, the keyboard must not resume the old session (which could also ask for the microphone).
  func testReadingKeysAndStartAreIgnoredInCameraOnly() throws {
    let screen = try source("iPad/VideoPrompter/Presenter/PresenterScreen.swift")
    for call in ["    if store.cameraOnly {\n      // Only Escape, Mirror and Flip mean anything with no script",
      "      default: return .ignored\n      }\n      return .handled\n    }\n    switch press.key {",
      "guard !store.cameraOnly, store.micOn || !isVoice else { return }",
      "  private func primaryAction() {\n    guard !store.cameraOnly else { return }"] {
      XCTAssertTrue(screen.contains(call), "Missing Camera Only keyboard gate: \(call)")
    }
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    XCTAssertTrue(store.contains("// The rest act on the open presenter, as its buttons do.\n      guard presentingID != nil else { return }"),
      "reading commands from the Mac need a script")
  }

  /// Closing switches off only what Camera Only switched on, and never lets a lost Mac feed start the local camera.
  func testClosingRestoresTheCamerasCameraOnlyStarted() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    for call in ["guard isPresenting, cameraOnly || pictureMode != .off,\n      camera.link.macName != nil, macStatus.cameraOn == false, !startedMacCamera else { return }",
      "if camera.isShowingMac { camera.isOn = false }\n      setCameraOn(false)",
      "if startedLocalCamera { startedLocalCamera = false; camera.isOn = false }",
      "guard cameraOnly, camera.link.macName == nil, !camera.isOn else { return }\n    startedLocalCamera = true",
      "// Whatever this connection switched on is gone with it, and never belongs to the next Mac.\n        startedMacCamera = false",
      "if firstCameraStatus { askMacForPicture() }"] {
      XCTAssertTrue(store.contains(call), "Missing Camera Only ownership rule: \(call)")
    }
    // The view starts the local camera only through the store, which records ownership.
    let screen = try source("iPad/VideoPrompter/Presenter/PresenterScreen.swift")
    XCTAssertTrue(screen.contains("private func useOwnCameraWithoutMac() { store.useOwnCameraWithoutMac() }"))
    XCTAssertFalse(screen.contains("camera.isOn = true }\n  }\n\n  private func countdown"), "no unowned local camera start")
  }
  func testPictureRequestCoversScriptModesAndReconnectWithoutRepeatingUserOff() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    XCTAssertTrue(store.contains("guard isPresenting, cameraOnly || pictureMode != .off,"))
    XCTAssertTrue(store.contains("macStatus.cameraOn == false, !startedMacCamera"))
    XCTAssertTrue(store.contains("presentingID = script.id\n    askMacForPicture()"))
    XCTAssertTrue(store.contains("if firstCameraStatus { askMacForPicture() }"))
    let link = try source("iPad/VideoPrompter/Camera/MacLink.swift")
    XCTAssertTrue(link.contains("case .failed, .cancelled: true"))
    XCTAssertTrue(link.contains("Self.needsRestart(usb!.state)"))
    XCTAssertTrue(link.contains("Self.needsRestart(wifi!.state)"))
    XCTAssertTrue(store.contains("camera.link.send(remoteState)"), "unchanged state must still acknowledge the heartbeat")
  }

  func testDiscoverySurvivesIdleDisconnectAndTransportFailure() throws {
    let sender = try source("Sources/VideoPrompter/Camera/IPadCameraSender.swift")
    XCTAssertTrue(sender.contains("(automaticallyLinks || isOn || controlsIPad || calls > 0)"))
    XCTAssertTrue(sender.contains("pipe.close()\n          self.lost(pipe)"))
    XCTAssertTrue(sender.contains("while !socket.withLock({ $0.stopped })"))
    XCTAssertTrue(sender.contains("if self.linkOn && self.usesWiFi { self.startBrowsing() }"))
    let app = try source("Sources/VideoPrompter/App/VideoPrompterApp.swift")
    XCTAssertTrue(app.contains("IPadCameraSender.shared.startDiscovering()"))
  }

}
