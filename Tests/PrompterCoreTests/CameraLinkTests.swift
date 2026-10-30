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
