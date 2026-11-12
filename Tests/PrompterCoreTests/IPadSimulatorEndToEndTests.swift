@preconcurrency import AVFoundation
import Synchronization
import XCTest

@testable import PrompterCore
@testable import VideoPrompter

/// Drives the real iPad app in a Simulator through the link, as the Mac does over USB-C: the
/// Simulator shares this Mac's loopback, so its listener on `CameraLink.usbPort` stands in for
/// usbmuxd's tunnel. Runs only with VP_IPAD_E2E=1 and the app open in a booted Simulator with
/// at least one script; `checks/ipad-link-e2e.sh` sets that up headless.
final class IPadSimulatorEndToEndTests: XCTestCase {
  func testTheMacDrivesTheIPadAndSendsItsCamera() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VP_IPAD_E2E"] == "1")
    let environment = ProcessInfo.processInfo.environment
    let port = try XCTUnwrap(environment["VP_IPAD_E2E_PORT"].flatMap(UInt16.init), "the fixture needs its own port")
    XCTAssertGreaterThanOrEqual(port, 1024)
    let expectedTitle = try XCTUnwrap(environment["VP_IPAD_E2E_SCRIPT"], "the fixture needs its own script")
    let fd = try XCTUnwrap(Self.connect(port: port), "the fixture iPad app is not listening")
    let pipe = SocketPipe(socket: fd, name: "USB-C")
    let latest = Mutex<PadRemote.State?>(nil)
    pipe.onMessage = { if case .state(let state) = $0 { latest.withLock { $0 = state } } }
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
    let script = try XCTUnwrap(first.scripts.first(where: { $0.title == expectedTitle }))
    send(.close)
    send(.mode("Manual"))
    send(.speed(240))
    _ = try state("manual at 240") { $0.mode == "Manual" && $0.speed == 240 && $0.presenting == nil }
    send(.present(script.id))
    let open = try state("presenting") { $0.presenting == script.id && $0.words > 5 }
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
    // Untouched since the last send: the same script takes the new text.
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
    send(.look(.init(horizontalMirror: false, verticalMirror: true, fontSize: 64, guideFraction: 0.4)))
    let looked = try state("look applied") { $0.look?.fontSize == 64 && $0.look?.verticalMirror == true }
    XCTAssertEqual(looked.look?.horizontalMirror, false)
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
    pipe.send(CameraLink.Message.goodbye.encoded())
    pipe.close()
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
      mac.send(.voiceSource("Mac"))
      mac.send(.present(script.id))
      _ = try mac.state("following") { $0.voiceSource == "Mac" && $0.presenting == script.id }
      mac.send(.play)
      _ = try mac.state("running on the Mac's voice") { $0.running && $0.voiceSource == "Mac" }
    }
    // The Mac goes away: the iPad stops, and does not fall back to its own microphone.
    let first = try Mac(port: port, name: "Mac one")
    try startRelay(first)
    first.pipe.close()
    // Nothing is connected to read the state, so the app records why it reset (a hook under the
    // end-to-end launch); the next Mac connects only once the plain drop has been seen to do it.
    try reset("drop")
    let second = try Mac(port: port, name: "Mac two")
    _ = try second.state("stopped after a drop") { $0.voiceSource == "iPad" && !$0.running }
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
