import XCTest

/// Pins iPad lifecycle wiring which SwiftPM cannot compile; the iPad build checks its types.
final class PadRemoteReadinessTests: XCTestCase {
  private func source(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  func testCommandsAndIncomingPictureWorkOutsidePresenter() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    XCTAssertTrue(store.contains("link.onCommand = { [weak self] in self?.perform($0) }"))
    XCTAssertTrue(store.contains("link.$pictureSize.receive(on: DispatchQueue.main)"))
    XCTAssertTrue(store.contains("guard let self, size != nil, !isPresenting else { return }\n      presentCamera()"))
    XCTAssertTrue(store.contains("if presentingID == nil, !cameraOnly, let script = selected { present(script) }"))
    XCTAssertTrue(store.contains("case .play: startReading()"))
    let app = try source("iPad/VideoPrompter/App/VideoPrompterPadApp.swift")
    XCTAssertTrue(app.contains("get: { store.isPresenting }"))
  }

  func testPresentAndStartRevealScriptForBothLocalAndRemoteActions() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    XCTAssertTrue(store.contains("revealScript()\n    presentingID = script.id"))
    XCTAssertTrue(store.contains("revealScript()\n    presenterSetup = false\n    session.startReading()"))
    XCTAssertTrue(store.contains("scriptVisible = true\n    if pictureMode == .monitorOnly { setPictureMode(.behindScript) }"))
    XCTAssertTrue(store.contains("else { revealScript() }"), "re-presenting the same transfer must reveal it too")
    let presenter = try source("iPad/VideoPrompter/Presenter/PresenterScreen.swift")
    XCTAssertTrue(presenter.contains("store.startReading()"))
    XCTAssertFalse(presenter.contains("session.startReading()"))
  }

  func testSetupMeterHasConsoleLifetimePermissionAndReadingGuards() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    for wiring in ["case .microphoneMeter(let value): consoleMeterRequested = value; updateSetupMeter()",
      "(pickerMeter || consoleMeterRequested && camera.link.macName != nil) && !usesMacMic && micOn",
      "(!session.isActivelyRunning || session.isManual)",
      "AVCaptureDevice.authorizationStatus(for: .audio) == .authorized",
      "if !needed { session.stopMicrophoneTest() }",
      "else if !session.isTestingMicrophone",
      "self?.updateSetupMeter()", "link.send(.microphoneLevel(micOn ? micMeter.levelDB : -60))"] {
      XCTAssertTrue(store.contains(wiring), wiring)
    }
  }
}
