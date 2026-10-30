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
    let fd = try XCTUnwrap(Self.connect(port: CameraLink.usbPort), "the iPad app is not listening")
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

    let first = try state("state on connect") { !$0.scripts.isEmpty }
    let script = first.scripts[0]
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
