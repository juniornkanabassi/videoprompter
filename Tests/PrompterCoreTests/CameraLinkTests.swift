import XCTest

@testable import PrompterCore

final class CameraLinkTests: XCTestCase {
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
      .follow(.init(confirmed: 12, fingerprint: "0123456789abcdef", seekRevision: 3)),
    ]
    let state = PadRemote.State(
      scripts: [.init(id: id, title: "A", macID: UUID(), fingerprint: "ff")], presenting: id, running: true,
      mode: "Voice", speed: 120, word: 12, words: 340, version: 3,
      look: .init(horizontalMirror: true, verticalMirror: false, fontSize: 56, textWidth: 0.8, lineSpacing: 0.2, guideFraction: 0.35),
      presets: ["Glass", "Desk"], startDelay: 3, voiceSource: "Mac", seekRevision: 4, fingerprint: "ff")
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
    XCTAssertNil(state.scripts[0].macID); XCTAssertNil(state.scripts[0].fingerprint)
  }

  /// What a version 2 reader (the shapes before version 3, frozen here) makes of version 3 output.
  func testVersionThreeOutputStillDecodesAsVersionTwo() throws {
    struct V2Script: Codable, Equatable { var id: UUID; var title: String }
    struct V2State: Codable, Equatable {
      var scripts: [V2Script]; var presenting: UUID?; var running: Bool; var mode: String
      var speed: Int; var word: Int; var words: Int
    }
    enum V2Command: Codable, Equatable { case play; case seek(word: Int); case mode(String) }
    let id = UUID()
    let v3 = PadRemote.State(
      scripts: [.init(id: id, title: "A", macID: UUID(), fingerprint: "ff")], presenting: id, running: false,
      mode: "Voice", speed: 100, word: 3, words: 30, version: 3, look: .init(fontSize: 50), presets: ["x"],
      startDelay: 3, voiceSource: "iPad", seekRevision: 1, fingerprint: "ff")
    let old = try JSONDecoder().decode(V2State.self, from: JSONEncoder().encode(v3))
    XCTAssertEqual(old, V2State(scripts: [.init(id: id, title: "A")], presenting: id, running: false, mode: "Voice", speed: 100, word: 3, words: 30))
    // A version 2 iPad cannot read the new commands; the framing skips them, so they are not fatal.
    XCTAssertThrowsError(try JSONDecoder().decode(V2Command.self, from: JSONEncoder().encode(PadRemote.Command.preset("x"))))
    var reader = CameraLink.Reader()
    let messages: [CameraLink.Message] = [.command(.voiceSource("Mac")), .command(.play), .goodbye]
    XCTAssertEqual(try reader.append(messages.reduce(into: Data()) { $0.append($1.encoded()) }), messages)
  }

  func testACommandFromANewerMacIsSkipped() throws {
    var reader = CameraLink.Reader()
    let json = Data(#"{"teleport":{}}"#.utf8)
    var bytes = Data([0, 0, 0, UInt8(json.count + 1), 5])
    bytes.append(json)
    bytes.append(CameraLink.Message.goodbye.encoded())
    XCTAssertEqual(try reader.append(bytes), [.goodbye])
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
