@preconcurrency import AVFoundation
import Synchronization
import Network
import Security
import XCTest

@testable import PrompterCore
@testable import VideoPrompter

/// Drives the real iPad app in a Simulator through the link, as the Mac does over USB-C: the
/// Simulator shares this Mac's loopback, so its listener on `CameraLink.usbPort` stands in for
/// usbmuxd's tunnel. Runs only with VP_IPAD_E2E=1 and the app open in a booted Simulator with
/// at least one script; `checks/ipad-link-e2e.sh` sets that up headless.
final class IPadSimulatorEndToEndTests: XCTestCase {
  @MainActor func testZInjectedQRPairing() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1")
    let documents = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["VP_IPAD_E2E_CONTAINER"]))
      .appendingPathComponent("Documents")
    let defaults = freshDefaults()
    // The real store, as the shipped app uses: this test binary has no team, like the local Alpha
    // that once lost every key it was given. A throwaway service keeps the user's keys untouched.
    let service = "VideoPrompter.e2e-pairing.\(UUID().uuidString)"
    let store = PairingKeyStore(service: service)
    defer {
      SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecUseDataProtectionKeychain as String: true] as CFDictionary)
      UserDefaults.standard.removeObject(forKey: service + ".sendCameraPairingCodes")
    }
    let sender = IPadCameraSender(defaults: defaults, credentialStore: store)
    sender.searchesForIPad = false
    sender.refreshPairingOffer()
    defer { sender.stopPairingOffer(); sender.disconnect() }
    let offer = try XCTUnwrap(sender.pairingOffer)
    try offer.encoded().write(to: documents.appendingPathComponent("vp-qr-payload.txt"), atomically: true, encoding: .utf8)
    let result = documents.appendingPathComponent("vp-qr-result.txt")
    var confirmedOnMac = false
    var pairedName: String?
    for _ in 0..<400 where !FileManager.default.fileExists(atPath: result.path) {
      if sender.pairingRequestCode != nil, !confirmedOnMac {
        XCTAssertNil(store.load([String: String].self, key: "sendCameraPairingCodes", defaults: defaults), "A photographed QR must not bypass local Mac approval")
        pairedName = sender.pairingRequestName
        sender.confirmPairingRequest()
        confirmedOnMac = true
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(confirmedOnMac)
    XCTAssertTrue(try String(contentsOf: result, encoding: .utf8).hasPrefix("Paired with"))
    XCTAssertNil(sender.pairingFailure, "The Mac must keep the key it was given")
    // Read back through a new store, as the app does after a relaunch.
    let codes = try XCTUnwrap(PairingKeyStore(service: service).load([String: String].self, key: "sendCameraPairingCodes", defaults: freshDefaults()))
    let padID = try XCTUnwrap(codes.keys.first)
    let code = try XCTUnwrap(codes[padID])
    let name = try XCTUnwrap(pairedName)
    let endpoint = NWEndpoint.service(name: "\(name) [\(padID)]", type: CameraLink.bonjourType, domain: "local.", interface: nil)
    for _ in 0..<2 {
      guard case .opened(let pipe) = await NetworkPipe.open(endpoint, code: code) else { return XCTFail("Paired TLS link did not reconnect") }
      pipe.startReading()
      pipe.send(CameraLink.Message.hello(name: "QR test Mac", version: CameraLink.protocolVersion).encoded())
      try await Task.sleep(for: .milliseconds(200))
      pipe.close()
      try await Task.sleep(for: .milliseconds(200))
    }
  }

  @MainActor
  func testAIdleSenderAnswersCameraOnlyAndReconnects() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1")
    let environment = ProcessInfo.processInfo.environment
    let port = try XCTUnwrap(environment["VP_IPAD_E2E_PORT"].flatMap(UInt16.init))
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    sender.capturesCamera = false
    defer { sender.disconnect() }
    let frameURL = URL(fileURLWithPath: try XCTUnwrap(environment["VP_IPAD_E2E_CONTAINER"]))
      .appendingPathComponent("Documents/vp-e2e-frame.txt")
    for _ in 0..<2 {
      try? FileManager.default.removeItem(at: frameURL)
      let pipe = SocketPipe(socket: try XCTUnwrap(Self.connect(port: port)), name: "USB-C")
      XCTAssertFalse(sender.isOn)
      sender.use(pipe)
      for _ in 0..<100 where !sender.isOn { try await Task.sleep(for: .milliseconds(50)) }
      XCTAssertTrue(sender.isOn, "Camera Only requests the feed with the sender initially off")
      for _ in 0..<100 where sender.iPadState?.macStatus?.cameras == nil {
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertNotNil(sender.iPadState?.macStatus?.cameras)
      XCTAssertNotNil(sender.iPadState?.macStatus?.microphones)
      XCTAssertEqual(sender.iPadState?.cameraOnly, true)
      let encoder = LinkEncoder()
      encoder.attach(pipe)
      for index in 0..<30 {
        encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try CameraLinkPipelineTests.frame(320, 180, index), from: CameraLinkPipelineTests.connection)
        try await Task.sleep(for: .milliseconds(33))
      }
      for _ in 0..<100 where !FileManager.default.fileExists(atPath: frameURL.path) {
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertEqual(try String(contentsOf: frameURL, encoding: .utf8), "decoded")
      encoder.finish(pipe)
      sender.disconnect()
      try await Task.sleep(for: .milliseconds(300))
    }
  }

  @MainActor func testBIPadMicrophonePickerStartsAndStopsMacRelay() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1")
    let env = ProcessInfo.processInfo.environment
    let port = try XCTUnwrap(env["VP_IPAD_E2E_PORT"].flatMap(UInt16.init))
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    sender.capturesCamera = false
    sender.relay.captureAudio = false
    sender.relay.presenterIsCapturing = { false }
    defer { sender.disconnect() }
    sender.use(SocketPipe(socket: try XCTUnwrap(Self.connect(port: port)), name: "USB-C"))
    for _ in 0..<100 where sender.iPadState?.scripts.isEmpty != false { try await Task.sleep(for: .milliseconds(50)) }
    let script = try XCTUnwrap(sender.iPadState?.scripts.first)
    sender.send(.present(script.id))
    for _ in 0..<100 where sender.iPadState?.presenting != script.id { try await Task.sleep(for: .milliseconds(50)) }
    let trigger = URL(fileURLWithPath: try XCTUnwrap(env["VP_IPAD_E2E_CONTAINER"]))
      .appendingPathComponent("Documents/vp-picker-request.txt")
    try "Mac".write(to: trigger, atomically: true, encoding: .utf8)
    for _ in 0..<100 where sender.relay.session == nil { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertNotNil(sender.relay.session, "Relay: \(sender.relay.status); presented fingerprint: \(sender.iPadState?.fingerprint ?? "none"); request pending: \(FileManager.default.fileExists(atPath: trigger.path))")
    XCTAssertEqual(sender.iPadState?.voiceSource, "Mac")
    try "iPad".write(to: trigger, atomically: true, encoding: .utf8)
    for _ in 0..<100 where sender.relay.isRelaying || sender.iPadState?.voiceSource != "iPad" { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertFalse(sender.relay.isRelaying)
    XCTAssertEqual(sender.iPadState?.voiceSource, "iPad")
    // The console uses the same relay path as the iPad picker.
    sender.chooseMicrophone("", onIPad: false)
    for _ in 0..<100 where sender.relay.session == nil { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertNotNil(sender.relay.session, sender.relay.status)
    for _ in 0..<100 where sender.iPadState?.voiceSource != "Mac" { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(sender.iPadState?.voiceSource, "Mac")
    // A simulator normally has no microphone. Invalid local IDs must not stop the active relay.
    sender.chooseMicrophone("not-a-device", onIPad: true)
    XCTAssertTrue(sender.relay.isRelaying)
    sender.chooseMicrophone("", onIPad: true)
    for _ in 0..<100 where sender.relay.isRelaying || sender.iPadState?.voiceSource != "iPad" { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertFalse(sender.relay.isRelaying)
    XCTAssertEqual(sender.iPadState?.voiceSource, "iPad")
    sender.send(.close)
    for _ in 0..<100 where sender.iPadState?.presenting != nil { try await Task.sleep(for: .milliseconds(50)) }
    sender.disconnect()
    try await Task.sleep(for: .milliseconds(300))
  }

  @MainActor func testCMacMicrophoneChosenBeforeScriptStartsWhenScriptOpens() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1")
    let env = ProcessInfo.processInfo.environment
    let port = try XCTUnwrap(env["VP_IPAD_E2E_PORT"].flatMap(UInt16.init))
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    sender.capturesCamera = false
    sender.relay.captureAudio = false
    sender.relay.presenterIsCapturing = { false }
    defer { sender.disconnect() }
    sender.use(SocketPipe(socket: try XCTUnwrap(Self.connect(port: port)), name: "USB-C"))
    for _ in 0..<100 where sender.iPadState?.scripts.isEmpty != false { try await Task.sleep(for: .milliseconds(50)) }
    let script = try XCTUnwrap(sender.iPadState?.scripts.first)
    let trigger = URL(fileURLWithPath: try XCTUnwrap(env["VP_IPAD_E2E_CONTAINER"]))
      .appendingPathComponent("Documents/vp-picker-request.txt")
    for fromIPad in [false, true] {
      sender.send(.close)
      sender.send(.mode("Manual"))
      for _ in 0..<100 where sender.iPadState?.presenting != nil || sender.iPadState?.mode != "Manual" {
        try await Task.sleep(for: .milliseconds(50))
      }
      if fromIPad { try "Mac".write(to: trigger, atomically: true, encoding: .utf8) }
      else { sender.chooseMicrophone("", onIPad: false) }
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertNil(sender.relay.session)
      XCTAssertEqual(sender.iPadState?.mode, "Manual", "Choosing a mic cannot enter Voice before a relay exists")
      sender.send(.present(script.id))
      for _ in 0..<100 where sender.relay.session == nil { try await Task.sleep(for: .milliseconds(50)) }
      XCTAssertNotNil(sender.relay.session, sender.relay.status)
      XCTAssertEqual(sender.iPadState?.voiceSource, "Mac")
      sender.send(.play)
      for _ in 0..<100 where sender.relay.session?.isActivelyRunning != true { try await Task.sleep(for: .milliseconds(50)) }
      XCTAssertTrue(sender.relay.session?.isActivelyRunning == true, sender.relay.status)
      sender.chooseMicrophone("", onIPad: true)
      for _ in 0..<100 where sender.relay.isRelaying { try await Task.sleep(for: .milliseconds(50)) }
      XCTAssertFalse(sender.relay.isRelaying)
      sender.send(.close)
      for _ in 0..<100 where sender.iPadState?.presenting != nil { try await Task.sleep(for: .milliseconds(50)) }
      try await Task.sleep(for: .seconds(1))
    }
  }

  func testTheMacDrivesTheIPadAndSendsItsCamera() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1")
    let environment = ProcessInfo.processInfo.environment
    let port = try XCTUnwrap(environment["VP_IPAD_E2E_PORT"].flatMap(UInt16.init), "the fixture needs its own port")
    XCTAssertGreaterThanOrEqual(port, 1024)
    let expectedTitle = try XCTUnwrap(environment["VP_IPAD_E2E_SCRIPT"], "the fixture needs its own script")
    let fd = try XCTUnwrap(Self.connect(port: port), "the fixture iPad app is not listening")
    let pipe = SocketPipe(socket: fd, name: "USB-C")
    let latest = Mutex<PadRemote.State?>(nil)
    let latestMarkdown = Mutex<String?>(nil)
    let commands = Mutex<[PadRemote.Command]>([])
    pipe.onMessage = {
      switch $0 {
      case .state(let state):
        latest.withLock { $0 = state }
        // Status-only updates omit unchanged text, just as they do for the Mac replica.
        if let markdown = state.markdown { latestMarkdown.withLock { $0 = markdown } }
      case .command(let command): commands.withLock { $0.append(command) }
      default: break
      }
    }
    pipe.startReading()
    pipe.send(CameraLink.Message.hello(name: "End-to-end Mac", version: CameraLink.protocolVersion).encoded())
    func state(_ what: String, _ check: (PadRemote.State) -> Bool) throws -> PadRemote.State {
      for _ in 0..<50 {
        if let state = latest.withLock({ $0 }), check(state) { return state }
        Thread.sleep(forTimeInterval: 0.1)
      }
      XCTFail("\(what): the iPad reported \(String(describing: latest.withLock { $0 }))")
      throw XCTSkip("stopped")
    }
    func send(_ command: PadRemote.Command) { pipe.send(CameraLink.Message.command(command).encoded()) }

    defer { pipe.close() }
    let first = try state("fixture state on connect") { $0.scripts.contains(where: { $0.title == expectedTitle }) }
    XCTAssertFalse(try XCTUnwrap(first.deviceName).isEmpty)
    XCTAssertFalse(try XCTUnwrap(first.appVersion).isEmpty)
    let checksURL = URL(fileURLWithPath: try XCTUnwrap(environment["VP_IPAD_E2E_CONTAINER"]))
      .appendingPathComponent("Documents/vp-e2e-contract-checks.json")
    let checks = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: checksURL))
    for key in ["meterIsIsolated", "immediateStateIsDeduplicated", "localEditSurvivesDrop",
                "remoteCannotEndLocalEdit", "remoteEditEndsOnDrop", "statusDisplayNameWins",
                "cameraOnlyIsReportedHonestly", "cameraOnlyIgnoresReading", "scriptJoinsCameraOnly",
                "closeRestoresSavedPicture", "remoteCloseEndsCameraOnly"] {
      XCTAssertEqual(checks[key], true, key)
    }
    XCTAssertEqual(first.picturePriority, .realTime720p)
    let script = try XCTUnwrap(first.scripts.first(where: { $0.title == expectedTitle }))
    // Camera Only opens as this Mac connects (the app is launched with VP_IPAD_E2E_CAMERA_ONLY): no
    // script is open, and the Mac was asked for its picture with the Camera button's own command.
    let cameraOnly = try state("camera only") { $0.cameraOnly == true }
    XCTAssertNil(cameraOnly.presenting)
    XCTAssertEqual(cameraOnly.words, 0)
    XCTAssertEqual(cameraOnly.pictureMode, .monitorOnly)
    // Ownership of the Mac's feed depends on whether it was already on, so nothing is asked until the
    // Mac's first camera status says so.
    XCTAssertFalse(commands.withLock { $0.contains(.cameraOn(true)) }, "Camera Only must wait for the Mac's camera status")
    send(.macStatus(.init(cameraOn: false)))
    for _ in 0..<50 where !commands.withLock({ $0.contains(.cameraOn(true)) }) { Thread.sleep(forTimeInterval: 0.1) }
    XCTAssertTrue(commands.withLock { $0.contains(.cameraOn(true)) }, "Camera Only must ask the Mac for its picture")
    send(.play)
    send(.mode("Manual"))
    _ = try state("reading commands are ignored with no script") { $0.mode == "Manual" && !$0.running && $0.cameraOnly == true }
    send(.present(script.id))
    let over = try state("a script joins Camera Only") { $0.presenting == script.id && $0.cameraOnly == false }
    XCTAssertEqual(over.pictureMode, .behindScript)
    send(.selectCamera("rotation-fixture"))
    send(.macStatus(.init(cameraRotation: 90)))
    _ = try state("Mac rotation reaches the iPad") { $0.guides?.rotation == 90 && $0.cameraUsesMac == true }
    send(.cameraGuides(.init(rotation: 270)))
    for _ in 0..<50 where !commands.withLock({ $0.contains(.cameraGuides(.init(rotation: 270))) }) { Thread.sleep(forTimeInterval: 0.1) }
    XCTAssertTrue(commands.withLock { $0.contains(.cameraGuides(.init(rotation: 270))) }, "Rotating the Mac source on iPad must ask the Mac")
    send(.macStatus(.init(cameraRotation: 270)))
    _ = try state("Mac confirms the requested rotation") { $0.guides?.rotation == 270 }
    send(.look(.init(scriptVisible: false, presenterSetup: true, focusMode: true)))
    _ = try state("presenter controls reach iPad") { $0.look?.scriptVisible == false && $0.look?.presenterSetup == true && $0.look?.focusMode == true }
    send(.look(.init(scriptVisible: true, focusMode: false)))

    send(.close)
    _ = try state("closed after Camera Only") { $0.presenting == nil && $0.cameraOnly == false }
    for _ in 0..<50 where !commands.withLock({ $0.contains(.cameraOn(false)) }) { Thread.sleep(forTimeInterval: 0.1) }
    XCTAssertTrue(commands.withLock { $0.contains(.cameraOn(false)) }, "closing switches off the feed Camera Only switched on")
    // Let the cover finish dismissing, or its end would close the next presentation.
    Thread.sleep(forTimeInterval: 1.5)
    send(.mode("Manual"))
    send(.speed(240))
    _ = try state("manual at 240") { $0.mode == "Manual" && $0.speed == 240 && $0.presenting == nil }
    send(.present(script.id))
    let open = try state("presenting") { $0.presenting == script.id && $0.words > 5 }
    XCTAssertFalse(try XCTUnwrap(open.scriptPreview).isEmpty)
    send(.seek(word: open.words / 2))
    _ = try state("seeked") { $0.word == open.words / 2 }
    send(.backToStart)
    _ = try state("back to start") { $0.word == 1 }
    send(.nextPassage)
    _ = try state("next passage") { $0.word > 1 }
    send(.play)
    let running = try state("running") { $0.running }
    _ = try state("manual scrolling moves on") { $0.word > running.word }
    send(.pause)
    _ = try state("paused") { !$0.running }
    send(.speed(9_999))
    _ = try state("speed clamped") { $0.speed == 300 }
    send(.seek(word: 10_000_000))
    send(.mode("Sideways"))
    _ = try state("nonsense ignored") { $0.mode == "Manual" && $0.presenting == script.id }

    // Version 3: a script from the Mac, the look, and the Mac's voice.
    send(.close)
    let macID = UUID()
    let sentTitle = "Sent \(expectedTitle)"
    let text = "# \(sentTitle)\n\nOne two three four five six seven eight nine ten eleven twelve."
    send(.sendScript(.init(macID: macID, title: sentTitle, markdown: text, basis: nil, present: true)))
    let sent = try state("sent script opens") { state in
      state.scripts.contains { $0.macID == macID } && state.presenting == state.scripts.first { $0.macID == macID }?.id
    }
    let sentScript = try XCTUnwrap(sent.scripts.first { $0.macID == macID })
    XCTAssertEqual(sentScript.fingerprint, MarkdownLibrary.fingerprint(text))
    XCTAssertEqual(sent.fingerprint, sentScript.fingerprint)
    XCTAssertEqual(sent.version, CameraLink.protocolVersion)
    // Select a second script without changing the open presenter. Both must be protected.
    let selectedMacID = UUID()
    let selectedText = "A selected draft that must stay untouched"
    send(.sendScript(.init(macID: selectedMacID, title: "Selected draft", markdown: selectedText)))
    let selected = try state("selected separate draft") { state in
      state.selectedID == state.scripts.first { $0.macID == selectedMacID }?.id && state.selectedID != nil
    }
    // Start from a different marker value: the default countdown can already be three.
    send(.startDelay(0))
    // UI parity uses the same intent path as beginEditing/endEditing on the iPad.
    send(.editing(true))
    let locked = try state("editing lock") { $0.editing == true && !$0.running && $0.startDelay == 0 }
    send(.seek(word: 8))
    send(.nextPassage)
    send(.previousPassage)
    send(.backToStart)
    send(.play)
    send(.sendScript(.init(macID: macID, title: sentTitle, markdown: "Do not overwrite",
                          basis: MarkdownLibrary.fingerprint(text), present: true)))
    send(.sendScript(.init(macID: selectedMacID, title: "Selected draft", markdown: "Do not overwrite selected draft",
                          basis: MarkdownLibrary.fingerprint(selectedText), present: false)))
    let unrelatedID = UUID()
    send(.sendScript(.init(macID: unrelatedID, title: "Unrelated draft", markdown: "Import without selecting")))
    // An acknowledgement of this final marker proves every blocked command above was processed.
    send(.startDelay(3))
    let rejected = try state("editing rejects movement and overwrite") { $0.startDelay == 3 && $0.rejectionReason != nil }
    XCTAssertEqual(rejected.word, locked.word)
    XCTAssertEqual(rejected.fingerprint, locked.fingerprint)
    XCTAssertEqual(rejected.selectedID, selected.selectedID)
    XCTAssertEqual(rejected.scripts.first { $0.macID == macID }?.fingerprint, MarkdownLibrary.fingerprint(text))
    XCTAssertEqual(rejected.scripts.first { $0.macID == selectedMacID }?.fingerprint, MarkdownLibrary.fingerprint(selectedText))
    XCTAssertTrue(rejected.scripts.contains { $0.macID == unrelatedID }, "unrelated imports still work during editing")
    XCTAssertFalse(rejected.running)
    send(.editing(false))
    _ = try state("editing ended") { $0.editing == false && $0.rejectionReason == nil }
    for mirror in [false, true] {
      for flip in [false, true] {
        send(.look(.init(horizontalMirror: mirror, verticalMirror: flip)))
        _ = try state("independent mirror and flip") {
          $0.look?.horizontalMirror == mirror && $0.look?.verticalMirror == flip
        }
      }
    }
    for mode in PadRemote.PictureMode.allCases {
      send(.pictureMode(mode))
      _ = try state("picture mode") { $0.pictureMode == mode }
    }
    send(.picturePriority(.sharper1080p))
    send(.cameraGuides(.init(zebras: true)))
    _ = try state("zebras enabled") { $0.guides?.zebras == true }
    send(.rename("Footballco Studio iPad"))
    _ = try state("iPad renamed") { $0.deviceName == "Footballco Studio iPad" }
    send(.look(.init(fontName: "Georgia", paragraphSpacing: 0.6)))
    _ = try state("text parity") { $0.look?.fontName == "Georgia" && $0.look?.paragraphSpacing == 0.6 }
    send(.cleanScreen(true))
    _ = try state("priority and clean screen") { $0.picturePriority == .sharper1080p && $0.cleanScreen == true }
    send(.cleanScreen(false))
    for recording in [PadRemote.RecordingState.recording, .standby, .unknown] {
      send(.macStatus(.init(cameras: [], recording: recording, displayName: "End-to-end Mac",
                           connectionKind: "USB-C", micLevelDB: -18)))
      _ = try state("Mac recorder tally") { $0.macStatus?.recording == recording }
    }
    let cameraChoice = PadRemote.Source(id: "camera-fixture", name: "Camera")
    let micChoice = PadRemote.Source(id: "mic-fixture", name: "Microphone")
    send(.macStatus(.init(cameras: [cameraChoice], selectedCamera: cameraChoice.id,
                         microphones: [micChoice], selectedMicrophone: micChoice.id)))
    _ = try state("source selections") { $0.macStatus?.selectedCamera == cameraChoice.id && $0.macStatus?.selectedMicrophone == micChoice.id }
    send(.macStatus(.init(cameras: [cameraChoice], microphones: [micChoice])))
    send(.startDelay(0))
    let listed = try state("list-only update") { $0.startDelay == 0 }
    XCTAssertEqual(listed.macStatus?.selectedCamera, cameraChoice.id)
    XCTAssertEqual(listed.macStatus?.selectedMicrophone, micChoice.id)
    // Untouched since the last send: the same script takes the new text.
    XCTAssertEqual(latestMarkdown.withLock { $0 }, text, "The replica receives the presented script, not the selected draft")
    let newer = text + " Thirteen fourteen."
    send(.sendScript(.init(macID: macID, title: sentTitle, markdown: newer, basis: MarkdownLibrary.fingerprint(text), present: false)))
    _ = try state("resend replaces in place") { state in
      state.scripts.first { $0.macID == macID }.map { $0.id == sentScript.id && $0.fingerprint == MarkdownLibrary.fingerprint(newer) } == true
    }
    // No basis and different text is a conflict: a new file, the old one kept.
    send(.sendScript(.init(macID: macID, title: sentTitle, markdown: text, basis: nil, present: false)))
    _ = try state("conflict keeps the iPad's file") { state in
      state.scripts.count(where: { $0.title.hasPrefix(sentTitle) }) == 2
        && state.scripts.first { $0.macID == macID }.map { $0.id != sentScript.id } == true
    }
    // Past the limits: ignored. A look sent after them comes back only once they were handled.
    let longTitle = UUID(), hugeText = UUID()
    send(.sendScript(.init(macID: longTitle, title: String(repeating: "T", count: 201), markdown: "x")))
    send(.sendScript(.init(macID: hugeText, title: "Huge \(expectedTitle)", markdown: String(repeating: "y", count: PadRemote.Transfer.maximumMarkdownBytes + 1))))
    send(.look(.init(horizontalMirror: false, verticalMirror: true, fontSize: 64, guideFraction: 0.4, fontName: "Lexend", paragraphSpacing: 0.6)))
    let looked = try state("look applied") { $0.look?.fontSize == 64 && $0.look?.verticalMirror == true }
    XCTAssertEqual(looked.look?.horizontalMirror, false)
    XCTAssertEqual(looked.look?.fontName, "Lexend")
    XCTAssertEqual(looked.look?.paragraphSpacing, 0.6)
    XCTAssertFalse(looked.scripts.contains { $0.macID == longTitle }, "a 201-character title must be refused")
    XCTAssertFalse(looked.scripts.contains { $0.macID == hugeText }, "a markdown body over 2 MB must be refused")
    XCTAssertFalse(looked.scripts.contains { $0.title.hasPrefix("Huge ") })
    send(.startDelay(5))
    _ = try state("countdown set") { $0.startDelay == 5 }
    send(.startDelay(7))
    send(.voiceSource("Mac"))
    send(.present(sentScript.id))
    let following = try state("following the Mac") { $0.voiceSource == "Mac" && $0.presenting == sentScript.id && $0.seekRevision != nil }
    let revision = try XCTUnwrap(following.seekRevision)
    XCTAssertEqual(following.startDelay, 5)
    send(.seek(word: 1))
    let sought = try state("seeked to the start") { ($0.seekRevision ?? revision) > revision }
    let freshRevision = try XCTUnwrap(sought.seekRevision)
    send(.play)
    _ = try state("running on the Mac's voice") { $0.running }
    let fingerprint = try XCTUnwrap(sought.fingerprint)
    // A stale revision and a wrong script are dropped; the right ones move the word.
    send(.follow(.init(confirmed: 6, fingerprint: fingerprint, seekRevision: freshRevision - 1)))
    send(.follow(.init(confirmed: 6, fingerprint: "0000000000000000", seekRevision: freshRevision)))
    send(.follow(.init(confirmed: 99, fingerprint: fingerprint, seekRevision: freshRevision)))
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(latest.withLock { $0?.word }, 1, "stale, foreign and out-of-range follows must not move it")
    send(.follow(.init(confirmed: 6, fingerprint: fingerprint, seekRevision: freshRevision)))
    _ = try state("follow moves the word") { $0.word == 8 }
    send(.voiceSource("iPad"))
    send(.pause)
    _ = try state("voice back on the iPad") { $0.voiceSource == "iPad" && !$0.running }
    send(.close)
    _ = try state("version 3 closed") { $0.presenting == nil }

    // The camera: a 1080p picture behind the script, for the screenshot the script takes.
    let encoder = LinkEncoder()
    encoder.attach(pipe)
    for index in 0..<60 {
      encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try CameraLinkPipelineTests.frame(1920, 1080, index), from: CameraLinkPipelineTests.connection)
      Thread.sleep(forTimeInterval: 1.0 / 30)
    }
    if let marker = ProcessInfo.processInfo.environment["VP_IPAD_E2E_MARKER"] {
      FileManager.default.createFile(atPath: marker, contents: nil)
      // Hold the picture while the script takes its screenshot.
      for index in 60..<150 {
        encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: try CameraLinkPipelineTests.frame(1920, 1080, index), from: CameraLinkPipelineTests.connection)
        Thread.sleep(forTimeInterval: 1.0 / 30)
      }
    }
    encoder.finish(pipe)
    send(.close)
    _ = try state("closed") { $0.presenting == nil }
    send(.pictureMode(.monitorOnly))
    send(.picturePriority(.sharper1080p))
    send(.cleanScreen(true))
    _ = try state("saved picture preferences") { $0.pictureMode == .monitorOnly && $0.picturePriority == .sharper1080p && $0.cleanScreen == true }
    pipe.send(CameraLink.Message.goodbye.encoded())
    pipe.close()
    try verifyPicturePreferencesAfterRelaunch(port: port)
  }

  private func verifyPicturePreferencesAfterRelaunch(port: UInt16) throws {
    let environment = ProcessInfo.processInfo.environment
    let container = try XCTUnwrap(environment["VP_IPAD_E2E_CONTAINER"])
    let components = URL(fileURLWithPath: container).pathComponents
    let deviceIndex = try XCTUnwrap(components.firstIndex(of: "Devices")) + 1
    let device = components[deviceIndex]
    func simctl(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = ["simctl"] + arguments
      var childEnvironment = environment
      childEnvironment["SIMCTL_CHILD_VP_IPAD_E2E_PORT"] = String(port)
      childEnvironment["SIMCTL_CHILD_VP_IPAD_E2E_QR"] = "1"
      process.environment = childEnvironment
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0, "simctl \(arguments)")
    }
    try simctl(["terminate", device, "com.juniornkanabassi.VideoPrompter"])
    try simctl(["launch", device, "com.juniornkanabassi.VideoPrompter"])
    var descriptor: Int32?
    for _ in 0..<50 where descriptor == nil {
      descriptor = Self.connect(port: port)
      if descriptor == nil { Thread.sleep(forTimeInterval: 0.1) }
    }
    let pipe = SocketPipe(socket: try XCTUnwrap(descriptor), name: "USB-C")
    defer { pipe.close() }
    let latest = Mutex<PadRemote.State?>(nil)
    pipe.onMessage = { if case .state(let state) = $0 { latest.withLock { $0 = state } } }
    pipe.startReading()
    pipe.send(CameraLink.Message.hello(name: "Relaunch check", version: CameraLink.protocolVersion).encoded())
    for _ in 0..<50 where latest.withLock({ $0 }) == nil { Thread.sleep(forTimeInterval: 0.1) }
    let restored = try XCTUnwrap(latest.withLock { $0 })
    XCTAssertEqual(restored.pictureMode, .monitorOnly)
    XCTAssertEqual(restored.picturePriority, .sharper1080p)
    XCTAssertEqual(restored.cleanScreen, true)
  }

  /// The Mac's voice relay must end when the Mac goes, and when another Mac takes over the link.
  func testTheMacVoiceStopsWhenTheMacDropsOrIsReplaced() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1")
    let environment = ProcessInfo.processInfo.environment
    let port = try XCTUnwrap(environment["VP_IPAD_E2E_PORT"].flatMap(UInt16.init))
    let expectedTitle = try XCTUnwrap(environment["VP_IPAD_E2E_SCRIPT"])
    final class Mac: @unchecked Sendable {
      let pipe: SocketPipe
      let latest = Mutex<PadRemote.State?>(nil)
      init(port: UInt16, name: String) throws {
        let fd = try XCTUnwrap(IPadSimulatorEndToEndTests.connect(port: port), "the fixture iPad app is not listening")
        pipe = SocketPipe(socket: fd, name: name)
        pipe.onMessage = { [self] in if case .state(let state) = $0 { latest.withLock { $0 = state } } }
        pipe.startReading()
        pipe.send(CameraLink.Message.hello(name: name, version: CameraLink.protocolVersion).encoded())
      }
      func send(_ command: PadRemote.Command) { pipe.send(CameraLink.Message.command(command).encoded()) }
      func state(_ what: String, _ check: (PadRemote.State) -> Bool) throws -> PadRemote.State {
        for _ in 0..<50 {
          if let state = latest.withLock({ $0 }), check(state) { return state }
          Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("\(what): the iPad reported \(String(describing: latest.withLock { $0 }))")
        throw XCTSkip("stopped")
      }
    }
    let resetFile = URL(fileURLWithPath: try XCTUnwrap(environment["VP_IPAD_E2E_CONTAINER"]))
      .appendingPathComponent("Documents/vp-e2e-link-reset.txt")
    try? FileManager.default.removeItem(at: resetFile)
    /// Waits for the iPad to record that it reset the relay for `reason`, then clears the record.
    func reset(_ reason: String) throws {
      for _ in 0..<100 {
        if (try? String(contentsOf: resetFile, encoding: .utf8)) == reason {
          try? FileManager.default.removeItem(at: resetFile)
          return
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      XCTFail("expected the relay to reset for \(reason), the iPad recorded \(String(describing: try? String(contentsOf: resetFile, encoding: .utf8)))")
      throw XCTSkip("stopped")
    }
    func startRelay(_ mac: Mac) throws {
      let first = try mac.state("connected") { $0.scripts.contains { $0.title == expectedTitle } }
      let script = try XCTUnwrap(first.scripts.first { $0.title == expectedTitle })
      mac.send(.present(script.id))
      _ = try mac.state("presenting before the relay starts") { $0.presenting == script.id }
      mac.send(.voiceSource("Mac"))
      _ = try mac.state("following") { $0.voiceSource == "Mac" && $0.presenting == script.id }
      mac.send(.play)
      _ = try mac.state("running on the Mac's voice") { $0.running && $0.voiceSource == "Mac" }
    }
    // The Mac goes away: the iPad stops, and does not fall back to its own microphone.
    let first = try Mac(port: port, name: "Mac one")
    try startRelay(first)
    first.send(.editing(true))
    _ = try first.state("Mac edit started") { $0.editing == true && !$0.running }
    first.send(.seek(word: 2))
    first.send(.micOn(false))
    _ = try first.state("edit rejection before drop") { $0.rejectionReason != nil && $0.micOn == false }
    first.pipe.close()
    // Nothing is connected to read the state, so the app records why it reset (a hook under the
    // end-to-end launch); the next Mac connects only once the plain drop has been seen to do it.
    try reset("drop")
    let second = try Mac(port: port, name: "Mac two")
    let afterDrop = try second.state("stopped after a drop") { $0.voiceSource == "iPad" && !$0.running }
    XCTAssertEqual(afterDrop.editing, false)
    XCTAssertNil(afterDrop.rejectionReason)
    XCTAssertEqual(afterDrop.micOn, true)
    // Another Mac takes the link over while one is relaying: the same.
    try startRelay(second)
    let third = try Mac(port: port, name: "Mac three")
    _ = try third.state("stopped after a replacement") { $0.voiceSource == "iPad" && !$0.running }
    try reset("replaced")
    third.send(.close)
    _ = try third.state("closed") { $0.presenting == nil }
    third.pipe.send(CameraLink.Message.goodbye.encoded())
    third.pipe.close()
    second.pipe.close()
  }

  static func connect(port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { Darwin.close(fd); return nil }
    return fd
  }
}
