@preconcurrency import AVFoundation
import Combine
import Network
import Synchronization
import XCTest

@testable import PrompterCore

final class CameraLinkTests: XCTestCase {
  func testReplicaStateAndSeekAreCompatibleWithOlderPeers() throws {
    let old = Data(#"{"scripts":[],"running":false,"mode":"Manual","speed":120,"word":0,"words":0}"#.utf8)
    var state = try JSONDecoder().decode(PadRemote.State.self, from: old)
    XCTAssertNil(state.markdown)
    let oldLook = try JSONDecoder().decode(PadRemote.Look.self, from: Data(#"{"fontSize":44}"#.utf8))
    XCTAssertNil(oldLook.fontName)
    state.markdown = "# Reading\n\nOne two three."
    state.look = .init(horizontalMirror: true, verticalMirror: true, fontSize: 52,
                       fontName: "Helvetica", fontWeight: "Bold", textColorHex: "#FFFF00",
                       textOpacity: 0.8, paragraphSpacing: 0.5, alignment: "Center", showCues: true)
    var reader = CameraLink.Reader()
    XCTAssertEqual(try reader.append(CameraLink.Message.state(state).encoded()), [.state(state)])
    struct OldState: Decodable { var word: Int; var words: Int }
    XCTAssertEqual(try JSONDecoder().decode(OldState.self, from: JSONEncoder().encode(state)).word, 0)
    struct OldLook: Decodable { var fontSize: Double? }
    XCTAssertEqual(try JSONDecoder().decode(OldLook.self, from: JSONEncoder().encode(state.look)).fontSize, 52)
    enum OldCommand: Codable, Equatable { case seek(word: Int) }
    let command = PadRemote.Command.seek(word: 12)
    XCTAssertEqual(try JSONDecoder().decode(OldCommand.self, from: JSONEncoder().encode(command)), .seek(word: 12))
    XCTAssertEqual(try JSONDecoder().decode(PadRemote.Command.self, from: JSONEncoder().encode(OldCommand.seek(word: 12))), command)
  }

  func testDeviceDetailsRemainOptionalAndRoundTrip() throws {
    let old = Data(#"{"scripts":[],"running":false,"mode":"Manual","speed":120,"word":0,"words":0}"#.utf8)
    var state = try JSONDecoder().decode(PadRemote.State.self, from: old)
    XCTAssertNil(state.linkHeartbeat)
    XCTAssertNil(state.deviceName)
    XCTAssertNil(state.appVersion)
    XCTAssertNil(state.scriptPreview)
    state.linkHeartbeat = true
    state.deviceName = "Studio iPad"
    state.appVersion = "2.5.1"
    state.scriptPreview = "The current script line"
    var reader = CameraLink.Reader()
    XCTAssertEqual(try reader.append(CameraLink.Message.state(state).encoded()), [.state(state)])
  }

  @MainActor
  func testInstallIdentitySurvivesRenameAndKeepsSameNamedIPadsSeparate() {
    let suiteA = "identity-a-\(UUID())", suiteB = "identity-b-\(UUID())"
    let a = UserDefaults(suiteName: suiteA)!
    let b = UserDefaults(suiteName: suiteB)!
    defer { a.removePersistentDomain(forName: suiteA); b.removePersistentDomain(forName: suiteB) }
    let first = PadIdentity(defaults: a)
    a.set("Studio", forKey: "macLinkDeviceName")
    b.set("Studio", forKey: "macLinkDeviceName")
    let renamed = PadIdentity(defaults: a)
    let other = PadIdentity(defaults: b)
    XCTAssertEqual(first.id, renamed.id)
    XCTAssertNotEqual(renamed.id, other.id)
    XCTAssertEqual(PadIdentity.peer(serviceName: renamed.serviceName).id, first.id)
    XCTAssertEqual(PadIdentity.peer(serviceName: renamed.serviceName).name, "Studio")
    XCTAssertEqual(PadIdentity.peer(serviceName: "Old iPad").id, "Old iPad")
    XCTAssertLessThanOrEqual(PadIdentity.cleanName(String(repeating: "📷", count: 30)).utf8.count + 39, 63)
  }

  @MainActor
  func testSameNamedIPadsPairIndependentlyAndSurviveRename() {
    let suite = "pair-identities-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let sender = IPadCameraSender(defaults: defaults)
    let a = UUID().uuidString, b = UUID().uuidString
    func endpoint(_ name: String, _ id: String) -> NWEndpoint {
      .service(name: "\(name) [\(id)]", type: CameraLink.bonjourType, domain: "local.", interface: nil)
    }
    sender.wifiChanged([endpoint("iPad", a), endpoint("iPad", b)])
    XCTAssertEqual(sender.wifiDevices.count, 2)
    sender.selectedWiFiID = a
    sender.pair(key: "0123456789ABCDEF")
    sender.selectedWiFiID = b
    XCTAssertEqual(sender.unpairedDeviceName, "iPad")
    sender.pair(key: "FEDCBA9876543210")
    let codes = defaults.dictionary(forKey: "sendCameraPairingCodes")
    XCTAssertEqual(codes?[a] as? String, "0123456789ABCDEF")
    XCTAssertEqual(codes?[b] as? String, "FEDCBA9876543210")
    sender.wifiChanged([endpoint("Renamed", a), endpoint("iPad", b)])
    sender.selectedWiFiID = a
    XCTAssertNil(sender.unpairedDeviceName)
  }

  @MainActor
  func testLegacyMigrationWaitsForProofAndRefusalIsPerDevice() {
    let defaults = freshDefaults()
    defaults.set(["iPad": "0123456789ABCDEF"], forKey: "sendCameraPairingCodes")
    let sender = IPadCameraSender(defaults: defaults)
    sender.searchesForIPad = false
    XCTAssertEqual(sender.pairingCode(id: "first", name: "Studio"), "0123456789ABCDEF")
    XCTAssertNil(defaults.dictionary(forKey: "sendCameraPairingCodes")?["first"])
    sender.acceptedPairing(id: "first", code: "0123456789ABCDEF")
    sender.refusedPairing(id: "second", name: "Other iPad")
    XCTAssertNil(sender.pairingCode(id: "second", name: "Other iPad"))
    XCTAssertEqual(sender.pairingCode(id: "first", name: "Renamed"), "0123456789ABCDEF")
    XCTAssertEqual(sender.unpairedDeviceName, "Other iPad")
    sender.pair(key: "FEDCBA9876543210")
    XCTAssertEqual(sender.pairingCode(id: "second", name: "Other iPad"), "FEDCBA9876543210")
    XCTAssertEqual(defaults.dictionary(forKey: "sendCameraPairingCodes")?["iPad"] as? String, "0123456789ABCDEF")
  }

  @MainActor
  func testInlinePairingValidatesAndStoresTheDiscoveredIPadKey() {
    let defaults = freshDefaults()
    let sender = IPadCameraSender(defaults: defaults)
    sender.searchesForIPad = false
    sender.wifiChanged([.service(name: "Studio iPad", type: CameraLink.bonjourType, domain: "local.", interface: nil)])
    XCTAssertEqual(sender.unpairedDeviceName, "Studio iPad")
    sender.pair(key: "wrong")
    XCTAssertNotNil(sender.pairingFailure)
    XCTAssertNil(defaults.dictionary(forKey: "sendCameraPairingCodes")?["Studio iPad"])
    let key = CameraLinkSecurity.newCode()
    sender.pair(key: key)
    XCTAssertNil(sender.pairingFailure)
    XCTAssertEqual(defaults.dictionary(forKey: "sendCameraPairingCodes")?["Studio iPad"] as? String, CameraLinkSecurity.normalised(key))
    sender.disconnect()
    XCTAssertFalse(sender.controlsIPad)
    XCTAssertNil(sender.pipe)
  }

  @MainActor
  func testDisconnectSendsGoodbyeAndClosesThePipe() throws {
    final class Pipe: LinkPipe, @unchecked Sendable {
      var bytes = Data()
      var didClose = false
      override func write(_ data: Data, done: @escaping @Sendable () -> Void) { bytes.append(data); done() }
      override func close() { didClose = true }
    }
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    sender.controlsIPad = true
    let pipe = Pipe(name: "USB-C")
    sender.pipe = pipe
    sender.disconnect()
    var reader = CameraLink.Reader()
    XCTAssertEqual(try reader.append(pipe.bytes), [.goodbye])
    XCTAssertTrue(pipe.didClose)
    XCTAssertNil(sender.pipe)
    XCTAssertFalse(sender.controlsIPad)
  }

  @MainActor
  func testIdleLinkPublishesStatusAndHonoursRequestsOnBothTransports() async throws {
    final class Pipe: LinkPipe, @unchecked Sendable {
      let messages = Synchronization.Mutex<[CameraLink.Message]>([])
      override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
        var reader = CameraLink.Reader()
        if let decoded = try? reader.append(data) { messages.withLock { $0 += decoded } }
        done()
      }
    }
    for transport in ["USB-C", "Wi-Fi"] {
      let sender = IPadCameraSender(defaults: freshDefaults())
      sender.searchesForIPad = false
      sender.capturesCamera = false
      sender.relay.captureAudio = false
      let pipe = Pipe(name: transport)
      sender.use(pipe)
      XCTAssertFalse(sender.isOn)
      let status = pipe.messages.withLock { messages in
        messages.compactMap { message -> PadRemote.MacStatus? in
          if case .command(.macStatus(let status)) = message { return status }
          return nil
        }.last
      }
      XCTAssertNotNil(status?.cameras)
      XCTAssertNotNil(status?.microphones)
      XCTAssertEqual(status?.cameraOn, false)
      XCTAssertEqual(status?.connectionKind, transport)
      pipe.onMessage?(.command(.cameraOn(true)))
      await Task.yield()
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertTrue(sender.isOn)
      pipe.onClose?()
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertFalse(sender.isOn, "an iPad-owned feed is released on drop")
      let replacement = Pipe(name: transport)
      sender.use(replacement)
      XCTAssertNotNil(sender.macStatus.cameras)
      sender.isOn = true
      replacement.onClose?()
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertTrue(sender.isOn, "a manual override survives a drop")
      sender.use(pipe)
      pipe.onMessage?(.command(.cameraOn(false)))
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertFalse(sender.isOn)
      XCTAssertTrue(sender.pipe === pipe, "camera off keeps the control session")
      sender.disconnect()
    }
  }

  @MainActor
  func testSilentPeerIsDroppedInsteadOfKeepingADeadSession() async throws {
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    sender.capturesCamera = false
    defer { sender.disconnect() }
    let pipe = LinkPipe(name: "Wi-Fi")
    sender.use(pipe)
    let state = try JSONDecoder().decode(PadRemote.State.self,
      from: Data(#"{"scripts":[],"running":false,"mode":"Manual","speed":120,"word":0,"words":0,"linkHeartbeat":true}"#.utf8))
    pipe.onMessage?(.state(state))
    try await Task.sleep(for: .seconds(9))
    XCTAssertNil(sender.pipe)
    XCTAssertNil(sender.iPadState)
  }

  func testUSBHandshakeTimeoutDoesNotPersistIntoTheCameraStream() {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(fd) }
    for seconds in [3, 0] {
      USBMux.handshakeTimeout(on: fd, seconds: seconds)
      for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
        var timeout = timeval()
        var size = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(getsockopt(fd, SOL_SOCKET, option, &timeout, &size), 0)
        XCTAssertEqual(timeout.tv_sec, seconds)
      }
    }
  }

  func testEncoderReportsSkippedFramesWithoutEncodingAThumbnail() throws {
    let encoder = LinkEncoder()
    let pipe = LinkPipe(name: "stalled")
    encoder.attach(pipe)
    pipe.queued(4_000_000)
    let sample = try CameraLinkLatencyTests.noisyFrame(16, 16, 0)
    encoder.captureOutput(AVCaptureVideoDataOutput(), didOutput: sample, from: CameraLinkPipelineTests.connection)
    XCTAssertEqual(encoder.framesSkipped, 1)
    let status = PadRemote.MacStatus(framesSkipped: encoder.framesSkipped)
    var reader = CameraLink.Reader()
    XCTAssertEqual(try reader.append(CameraLink.Message.command(.macStatus(status)).encoded()), [.command(.macStatus(status))])
    encoder.attach(nil)
    XCTAssertEqual(encoder.framesSkipped, 0)
  }

  private let messages: [CameraLink.Message] = [
    .hello(name: "Junior's MacBook Pro", version: CameraLink.protocolVersion),
    .format(width: 1920, height: 1080, parameterSets: [Data([0x67, 0x64, 0x00, 0x28]), Data([0x68, 0xEE])]),
    .frame(time: 1_234_567_890, keyFrame: true, data: Data([0, 0, 0, 2, 0x65, 0x88])),
    .frame(time: 1_234_601_256, keyFrame: false, data: Data()),
    .goodbye,
  ]

  func testEveryMessageSurvivesTheRoundTrip() throws {
    var reader = CameraLink.Reader()
    let bytes = messages.reduce(into: Data()) { $0.append($1.encoded()) }
    XCTAssertEqual(try reader.append(bytes), messages)
  }

  func testMessagesSplitAcrossReadsComeOutWhole() throws {
    var reader = CameraLink.Reader()
    let bytes = messages.reduce(into: Data()) { $0.append($1.encoded()) }
    var received: [CameraLink.Message] = []
    // One byte at a time is the worst a stream can do.
    for byte in bytes { received += try reader.append(Data([byte])) }
    XCTAssertEqual(received, messages)
  }

  func testUnknownKindsAreSkipped() throws {
    var reader = CameraLink.Reader()
    var bytes = Data([0, 0, 0, 3, 99, 1, 2])
    bytes.append(CameraLink.Message.goodbye.encoded())
    XCTAssertEqual(try reader.append(bytes), [.goodbye])
  }

  func testAnAbsurdLengthIsRefused() {
    var reader = CameraLink.Reader()
    XCTAssertThrowsError(try reader.append(Data([0x7F, 0xFF, 0xFF, 0xFF, 3])))
    var empty = CameraLink.Reader()
    XCTAssertThrowsError(try empty.append(Data([0, 0, 0, 0])))
  }

  func testRemoteMessagesSurviveTheRoundTrip() throws {
    let id = UUID()
    let commands: [PadRemote.Command] = [
      .present(id), .close, .play, .pause, .backToStart, .nextPassage, .previousPassage,
      .seek(word: 42), .mode("Manual"), .speed(150),
    ]
    let state = PadRemote.State(
      scripts: [.init(id: id, title: "Arsenal v Spurs")], presenting: id, running: true,
      mode: "Voice", speed: 120, word: 12, words: 340)
    let sent = commands.map(CameraLink.Message.command) + [.state(state)]
    var reader = CameraLink.Reader()
    XCTAssertEqual(try reader.append(sent.reduce(into: Data()) { $0.append($1.encoded()) }), sent)
  }

  func testVersionThreeMessagesSurviveTheRoundTrip() throws {
    let id = UUID()
    let commands: [PadRemote.Command] = [
      .sendScript(.init(macID: id, title: "Preview", markdown: "# Preview\n\nHello.", basis: "abc", present: true)),
      .sendScript(.init(macID: id, title: "First", markdown: "Hi")),
      .look(.init(horizontalMirror: true, fontSize: 60, guideFraction: 0.4)), .look(.init()),
      .preset("Glass"), .startDelay(5), .voiceSource("Mac"),
      .editing(true), .editing(false), .pictureMode(.off), .pictureMode(.behindScript),
      .pictureMode(.monitorOnly), .picturePriority(.realTime720p), .picturePriority(.sharper1080p),
      .cleanScreen(true), .cameraOn(false), .selectCamera("camera-1"),
      .micOn(false), .selectMicrophone("mic-1"),
      .macStatus(.init(cameras: [.init(id: "camera-1", name: "Studio")], selectedCamera: "camera-1",
        cameraOn: true, microphones: [.init(id: "mic-1", name: "Desk")], selectedMicrophone: "mic-1",
        micOn: true, recording: .recording, displayName: "Studio Mac", connectionKind: "USB-C", micLevelDB: -12)),
      .follow(.init(confirmed: 12, fingerprint: "0123456789abcdef", seekRevision: 3)),
    ]
    let state = PadRemote.State(
      scripts: [.init(id: id, title: "A", macID: UUID(), fingerprint: "ff")], presenting: id, running: true,
      mode: "Voice", speed: 120, word: 12, words: 340, version: 3,
      look: .init(horizontalMirror: true, verticalMirror: false, fontSize: 56, textWidth: 0.8, lineSpacing: 0.2, guideFraction: 0.35),
      presets: ["Glass", "Desk"], startDelay: 3, voiceSource: "Mac", seekRevision: 4, fingerprint: "ff", editing: true,
      rejectionReason: "Finish editing on the iPad first", pictureMode: .monitorOnly,
      picturePriority: .sharper1080p, cleanScreen: true, micOn: false,
      macStatus: .init(recording: .standby, displayName: "Mac", connectionKind: "Wi-Fi"),
      microphoneSources: [.init(id: "ipad-mic", name: "iPad")], selectedMicrophone: "ipad-mic", selectedID: id)
    let sent = commands.map(CameraLink.Message.command) + [.state(state)]
    var reader = CameraLink.Reader()
    XCTAssertEqual(try reader.append(sent.reduce(into: Data()) { $0.append($1.encoded()) }), sent)
    XCTAssertEqual(CameraLink.protocolVersion, 3)
  }

  /// Frozen from what a version 2 Mac and iPad wrote: they must keep decoding as version 3.
  func testFrozenVersionTwoJSONDecodesAsVersionThree() throws {
    let id = "5C0A5D2E-8E9F-4B1B-9D0B-1C2D3E4F5A6B"
    let commands: [(String, PadRemote.Command)] = [
      (#"{"present":{"_0":"\#(id)"}}"#, .present(UUID(uuidString: id)!)), (#"{"close":{}}"#, .close),
      (#"{"play":{}}"#, .play), (#"{"pause":{}}"#, .pause), (#"{"backToStart":{}}"#, .backToStart),
      (#"{"nextPassage":{}}"#, .nextPassage), (#"{"previousPassage":{}}"#, .previousPassage),
      (#"{"seek":{"word":42}}"#, .seek(word: 42)), (#"{"mode":{"_0":"Manual"}}"#, .mode("Manual")),
      (#"{"speed":{"_0":150}}"#, .speed(150)),
    ]
    for (json, expected) in commands {
      XCTAssertEqual(try JSONDecoder().decode(PadRemote.Command.self, from: Data(json.utf8)), expected, json)
    }
    let v2State = #"{"scripts":[{"id":"\#(id)","title":"Arsenal v Spurs"}],"presenting":"\#(id)","running":true,"mode":"Voice","speed":120,"word":12,"words":340}"#
    let state = try JSONDecoder().decode(PadRemote.State.self, from: Data(v2State.utf8))
    XCTAssertEqual(state.scripts, [.init(id: UUID(uuidString: id)!, title: "Arsenal v Spurs")])
    XCTAssertEqual(state.word, 12)
    XCTAssertNil(state.version); XCTAssertNil(state.look); XCTAssertNil(state.presets); XCTAssertNil(state.startDelay)
    XCTAssertNil(state.voiceSource); XCTAssertNil(state.seekRevision); XCTAssertNil(state.fingerprint)
    XCTAssertNil(state.editing); XCTAssertNil(state.rejectionReason); XCTAssertNil(state.pictureMode)
    XCTAssertNil(state.picturePriority); XCTAssertNil(state.cleanScreen); XCTAssertNil(state.micOn)
    XCTAssertNil(state.selectedID); XCTAssertNil(state.macStatus); XCTAssertNil(state.microphoneSources); XCTAssertNil(state.selectedMicrophone)
    XCTAssertNil(state.scripts[0].macID); XCTAssertNil(state.scripts[0].fingerprint)
  }

  /// What a version 2 iPad makes of version 3 traffic, read with a frozen copy of the version 2
  /// types and framing (not the current reader).
  func testVersionThreeTrafficStillReadsAsVersionTwo() throws {
    struct V2Script: Codable, Equatable { var id: UUID; var title: String }
    struct V2State: Codable, Equatable {
      var scripts: [V2Script]; var presenting: UUID?; var running: Bool; var mode: String
      var speed: Int; var word: Int; var words: Int
    }
    enum V2Command: Codable, Equatable {
      case present(UUID), close, play, pause, backToStart, nextPassage, previousPassage
      case seek(word: Int), mode(String), speed(Int)
    }
    /// The version 2 reader: four-byte length, kind, payload; unknown kinds and unreadable JSON skipped.
    func readAsV2(_ bytes: Data) -> [String] {
      var out: [String] = []
      var at = bytes.startIndex
      while at + 5 <= bytes.endIndex {
        let length = bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
        let kind = bytes[at + 4]
        let payload = bytes.subdata(in: (at + 5)..<(at + 4 + length))
        at += 4 + length
        switch kind {
        case 4: out.append("goodbye")
        case 5: if let command = try? JSONDecoder().decode(V2Command.self, from: payload) { out.append("command \(command)") }
        case 6: if let state = try? JSONDecoder().decode(V2State.self, from: payload) { out.append("state \(state.word)/\(state.words) \(state.mode)") }
        default: break
        }
      }
      return out
    }
    let id = UUID()
    let v3State = PadRemote.State(
      scripts: [.init(id: id, title: "A", macID: UUID(), fingerprint: "ff")], presenting: id, running: false,
      mode: "Voice", speed: 100, word: 3, words: 30, version: 3, look: .init(fontSize: 50), presets: ["x"],
      startDelay: 3, voiceSource: "iPad", seekRevision: 1, fingerprint: "ff",
      editing: true, pictureMode: .behindScript, picturePriority: .realTime720p, cleanScreen: true,
      micOn: false, macStatus: .init(recording: .recording))
    let sent: [CameraLink.Message] = [
      .command(.voiceSource("Mac")), .command(.play), .command(.preset("x")), .command(.startDelay(5)),
      .command(.look(.init(fontSize: 50))), .command(.sendScript(.init(macID: id, title: "T", markdown: "m"))),
      .command(.follow(.init(confirmed: 1, fingerprint: "ff", seekRevision: 1))), .command(.seek(word: 7)),
      .command(.editing(true)), .command(.pictureMode(.monitorOnly)),
      .command(.picturePriority(.sharper1080p)), .command(.cleanScreen(true)),
      .command(.cameraOn(true)), .command(.selectCamera("camera")),
      .command(.micOn(false)), .command(.selectMicrophone("mic")),
      .command(.macStatus(.init(recording: .recording))),
      .state(v3State), .goodbye,
    ]
    // The new commands are skipped; everything a version 2 iPad knows still arrives.
    XCTAssertEqual(
      readAsV2(sent.reduce(into: Data()) { $0.append($1.encoded()) }),
      ["command play", "command seek(word: 7)", "state 3/30 Voice", "goodbye"])
  }

  func testACommandFromANewerMacIsSkipped() throws {
    var reader = CameraLink.Reader()
    let json = Data(#"{"teleport":{}}"#.utf8)
    var bytes = Data([0, 0, 0, UInt8(json.count + 1), 5])
    bytes.append(json)
    bytes.append(CameraLink.Message.goodbye.encoded())
    XCTAssertEqual(try reader.append(bytes), [.goodbye])
  }

  func testMirrorAndFlipAreIndependentAndKeepTheirWireNames() throws {
    for mirror in [false, true] {
      for flip in [false, true] {
        let look = PadRemote.Look(horizontalMirror: mirror, verticalMirror: flip)
        let data = try JSONEncoder().encode(look)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        XCTAssertEqual(json["horizontalMirror"], mirror)
        XCTAssertEqual(json["verticalMirror"], flip)
        XCTAssertEqual(try JSONDecoder().decode(PadRemote.Look.self, from: data), look)
      }
    }
    XCTAssertEqual(PadRemote.PicturePriority.realTime720p.longSide, 1280)
    XCTAssertEqual(PadRemote.PicturePriority.sharper1080p.longSide, 1920)
  }

  func testPictureBitrateScalesWithResolutionAndTransport() {
    XCTAssertEqual(PadRemote.PicturePriority.realTime720p.bitRate(overUSB: true), 6_000_000)
    XCTAssertEqual(PadRemote.PicturePriority.sharper1080p.bitRate(overUSB: true), 10_000_000)
    XCTAssertEqual(PadRemote.PicturePriority.realTime720p.bitRate(overUSB: false), 4_000_000)
    XCTAssertGreaterThan(PadRemote.PicturePriority.sharper1080p.bitRate(overUSB: false), 4_000_000)
  }

  @MainActor
  func testMeterClampsInvalidLevelsAndPublishesOnlyChanges() {
    let meter = RemoteMicMeter()
    var changes = 0
    let observation = meter.objectWillChange.sink { changes += 1 }
    defer { observation.cancel() }
    meter.show(-90)
    XCTAssertEqual(changes, 0)
    meter.show(-12)
    meter.show(-12)
    XCTAssertEqual(meter.levelDB, -12)
    XCTAssertEqual(changes, 1)
    meter.show(20)
    XCTAssertEqual(meter.levelDB, 0)
    meter.show(.nan)
    XCTAssertEqual(meter.levelDB, -60)
    meter.show(.infinity)
    XCTAssertEqual(changes, 3)
  }

  @MainActor
  func testMacMeterRetainsPeakBetweenTicksWithoutPublishingTheSender() {
    let sender = IPadCameraSender(defaults: freshDefaults())
    sender.searchesForIPad = false
    let meter = InputMeter()
    var changes = 0
    let observation = sender.objectWillChange.sink { changes += 1 }
    defer { observation.cancel() }
    sender.sampleMicLevel(meter)
    meter.show(peakDBFS: -3, isClipping: false)
    meter.show(peakDBFS: -42, isClipping: false)
    sender.sampleMicLevel(meter)
    XCTAssertEqual(sender.micMeter.levelDB, -3)
    sender.sampleMicLevel(meter)
    XCTAssertEqual(sender.micMeter.levelDB, -42, "each interval consumes its peak")
    XCTAssertEqual(changes, 0, "meter samples must not rebuild menus and the remote window")
    let replacement = InputMeter()
    replacement.show(peakDBFS: -25, isClipping: false)
    meter.show(peakDBFS: -1, isClipping: false)
    sender.sampleMicLevel(replacement)
    XCTAssertEqual(sender.micMeter.levelDB, -25, "switching source discards the previous microphone's peak")
  }

  func testStatusIsLatestWinsAndOvertakesQueuedVideoWithoutReplacingFollows() throws {
    final class Stalled: LinkPipe, @unchecked Sendable {
      var writes: [Data] = []
      var completion: (@Sendable () -> Void)?
      override func write(_ data: Data, done: @escaping @Sendable () -> Void) {
        writes.append(data); completion = done
      }
      func advance() { let done = completion; completion = nil; done?() }
    }
    let pipe = Stalled(name: "test")
    pipe.send(CameraLink.Message.frame(time: 1, keyFrame: true, data: Data()).encoded())
    pipe.send(CameraLink.Message.frame(time: 2, keyFrame: false, data: Data()).encoded())
    pipe.send(CameraLink.Message.command(.macStatus(.init(micLevelDB: -40))).encoded())
    pipe.send(CameraLink.Message.command(.follow(.init(confirmed: 3, fingerprint: "f", seekRevision: 0))).encoded())
    pipe.send(CameraLink.Message.command(.macStatus(.init(micLevelDB: -10))).encoded())
    for _ in 0..<4 { pipe.advance() }
    var reader = CameraLink.Reader()
    let messages = try reader.append(pipe.writes.reduce(into: Data()) { $0.append($1) })
    XCTAssertEqual(messages, [
      .frame(time: 1, keyFrame: true, data: Data()),
      .command(.follow(.init(confirmed: 3, fingerprint: "f", seekRevision: 0))),
      .command(.macStatus(.init(micLevelDB: -10))),
      .frame(time: 2, keyFrame: false, data: Data())
    ])
    XCTAssertEqual(pipe.pendingBytes, 0)
  }

  @MainActor
  func testEditingPausesRelayAndRejectsANewRelay() async throws {
    final class Link: PadRelayLink {
      var sent: [PadRemote.Command] = []
      func send(_ command: PadRemote.Command) { sent.append(command) }
      func setRelayActive(_ active: Bool) {}
    }
    let link = Link()
    let suite = "VideoPrompterTests.parityRelay." + UUID().uuidString
    removeDefaultsAtTeardown(suite)
    let relay = PadVoiceRelay(link: link, suiteName: suite, defaults: freshDefaults())
    relay.captureAudio = false
    relay.presenterIsCapturing = { false }
    let macID = UUID(), padID = UUID()
    let text = "alpha bravo charlie delta echo foxtrot"
    let record = ScriptRecord(metadata: ScriptMetadata(id: macID, title: "Test", fileName: "test.md"), markdown: text)
    let fingerprint = MarkdownLibrary.fingerprint(text)
    var state = PadRemote.State(
      scripts: [.init(id: padID, title: "Test", macID: macID, fingerprint: fingerprint)],
      presenting: padID, running: true, mode: "Voice", speed: 120, word: 1, words: 6,
      version: 3, voiceSource: "Mac", seekRevision: 0, fingerprint: fingerprint, editing: true)
    relay.iPadStateChanged(state)
    relay.start(script: record, settings: PrompterSettings())
    XCTAssertFalse(relay.isRelaying)
    XCTAssertTrue(link.sent.isEmpty)
    state.editing = false
    relay.iPadStateChanged(state)
    relay.start(script: record, settings: PrompterSettings())
    for _ in 0..<100 where relay.session == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(relay.session?.isActivelyRunning, true)
    // Still reports running: the editing flag alone must suspend the recogniser.
    state.editing = true
    relay.iPadStateChanged(state)
    XCTAssertEqual(relay.session?.isActivelyRunning, false)
    let count = link.sent.count
    await Task.yield()
    XCTAssertEqual(link.sent.count, count)
    state.editing = false
    state.running = false
    relay.iPadStateChanged(state)
    XCTAssertEqual(relay.session?.isActivelyRunning, false, "ending an edit never resumes reading")
    relay.stop()
  }

  func testATruncatedParameterSetIsRefused() {
    var reader = CameraLink.Reader()
    // Format with one parameter set claiming 5 bytes but carrying 1.
    var payload = Data([0, 0, 7, 128, 0, 0, 4, 56, 1, 0, 5, 0x67])
    payload.insert(2, at: 0)
    var bytes = Data([0, 0, 0, UInt8(payload.count)])
    bytes.append(payload)
    XCTAssertThrowsError(try reader.append(bytes))
  }
}

@testable import VideoPrompter

final class CameraLinkSecurityTests: XCTestCase {
  func testPairingKeysAreSixteenCharactersOfCrockfordBase32() {
    let key = CameraLinkSecurity.newCode()
    XCTAssertEqual(key.count, 19)
    XCTAssertEqual(key.split(separator: "-").map(\.count), [4, 4, 4, 4])
    XCTAssertNil(key.first { "ILOU".contains($0) })
    XCTAssertNotEqual(CameraLinkSecurity.newCode(), key)
  }

  func testTypedKeysAreReadForgivingly() {
    XCTAssertEqual(CameraLinkSecurity.normalised("k7qf 2mzx p9rt w3hd"), "K7QF-2MZX-P9RT-W3HD")
    XCTAssertEqual(CameraLinkSecurity.normalised("O1IL-AAAA-BBBB-CCCC"), "0111-AAAA-BBBB-CCCC")
    XCTAssertNil(CameraLinkSecurity.normalised("123456"))
  }
}
