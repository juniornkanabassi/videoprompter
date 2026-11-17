import XCTest

/// Pins iPad lifecycle wiring which SwiftPM cannot compile; the iPad build checks its types.
final class PadRemoteReadinessTests: XCTestCase {
  private func source(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
  }

  func testOnlyExplicitCommandsLeaveLibrary() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    XCTAssertTrue(store.contains("link.onCommand = { [weak self] in self?.perform($0) }"))
    XCTAssertFalse(store.contains("link.$pictureSize.receive"))
    XCTAssertTrue(store.contains("case .present, .sendScript, .play, .selectCamera, .cameraOn(true):"))
    XCTAssertTrue(store.contains("if presentingID == nil, !cameraOnly, let script = selected { present(script) }"))
    XCTAssertTrue(store.contains("case .play: startReading()"))
    let app = try source("iPad/VideoPrompter/App/VideoPrompterPadApp.swift")
    XCTAssertTrue(app.contains("get: { store.isPresenting }"))
  }

  func testExposureSettingsAreReportedAndApplied() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    XCTAssertTrue(store.contains("guides.applyExposure(update)"))
    for field in ["zebraPurpose: camera.guides.validatedZebraPurpose.rawValue", "skinTone: camera.guides.skinTone.rawValue",
      "greyCardCheck: camera.guides.greyCardCheck"] { XCTAssertTrue(store.contains(field), field) }
  }

  func testLocalCameraNeverRequestsOrAcceptsMacPicture() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    let start = try XCTUnwrap(store.range(of: "case .selectCamera(let id, let onIPad):"))
    let end = try XCTUnwrap(store.range(of: "case .selectMicrophone", range: start.upperBound..<store.endIndex))
    let cameraCommands = String(store[start.lowerBound..<end.lowerBound])
    XCTAssertTrue(cameraCommands.contains("camera.acceptsMacPicture = false"))
    XCTAssertTrue(cameraCommands.contains("presentCamera(requestMacPicture: false)"))
    XCTAssertFalse(cameraCommands.contains("presentCamera()"))
    XCTAssertTrue(cameraCommands.contains("presentCamera(requestMacPicture: camera.isShowingMac)"))
    XCTAssertTrue(store.contains("guard camera.acceptsMacPicture else { return }"))
    let camera = try source("iPad/VideoPrompter/Camera/PadCamera.swift")
    XCTAssertTrue(camera.contains("if acceptsMacPicture, link.pictureSize != nil, !hadMac"))
  }

  func testChannelChangeRestartsTestAndFailuresWaitForUserAction() throws {
    let store = try source("iPad/VideoPrompter/App/PadStore.swift")
    let start = try XCTUnwrap(store.range(of: "func chooseChannel"))
    let end = try XCTUnwrap(store.range(of: "func setVoiceSource", range: start.upperBound..<store.endIndex))
    let channel = String(store[start.lowerBound..<end.lowerBound])
    XCTAssertTrue(channel.contains("session.stopMicrophoneTest()"))
    XCTAssertTrue(channel.contains("setupMeterAttempted = false"))
    XCTAssertTrue(channel.contains("updateSetupMeter()"))
    XCTAssertTrue(store.contains("else if !session.isTestingMicrophone, !setupMeterAttempted"))
    XCTAssertTrue(store.contains("if show != pickerMeter { setupMeterAttempted = false }"))
    let sender = try source("Sources/VideoPrompter/Camera/IPadCameraSender.swift")
    XCTAssertFalse(sender.contains("if pendingMacMicrophone { send(.voiceSource(\"Mac\")) }"))
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
      "session.stopMicrophoneTest()",
      "else if !session.isTestingMicrophone, !setupMeterAttempted",
      "setupMeterAttempted = true",
      "self?.updateSetupMeter()", "link.send(.microphoneLevel(micOn ? level : -60))"] {
      XCTAssertTrue(store.contains(wiring), wiring)
    }
  }
}
