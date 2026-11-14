import AVFoundation
import Foundation
@testable import VideoPrompter
import XCTest
@testable import PrompterCore

final class VoiceLatencyTests: XCTestCase {
  @MainActor
  func testRemoteFollowPublishesHighlightWithoutWaitingForGlide() {
    let session = SessionStore(defaults: freshDefaults("RemoteHighlightLatency"))
    var now = 0.0
    session.clock = { now }
    var settings = PrompterSettings(); settings.mode = "Voice"
    session.present(record: .init(metadata: .init(title: "Relay", fileName: "relay.md"),
      markdown: "alpha bravo charlie delta echo foxtrot golf hotel india"), settings: settings)
    session.followsRemote = true
    session.play(captureAudio: false)
    defer { session.pause() }
    _ = session.voicePosition()
    now = 4
    _ = session.voicePosition()
    session.followRemote(confirmed: 5)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 5)
    XCTAssertEqual(session.tokenIndex, 6, "The iPad highlight input changes in the follow call")
    XCTAssertLessThan(session.voicePosition(), 1, "Scroll easing must not hold back the highlight")
    session.followRemote(confirmed: 90)
    XCTAssertEqual(session.tokenIndex, 6, "An invalid relay index must still be rejected")
  }

  func testConversionDoesNotAccumulateAudio() throws {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
    let capture = AudioCapture(device: .init(id: 0, uid: "test", name: "test"), outputFormat: format)
    try capture.prepareConverter(sampleRate: 48000)
    let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4800))
    buffer.frameLength = 4800
    buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
    var frames = 0
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<100 { frames += Int(try XCTUnwrap(capture.process(buffer)).buffer.frameLength) }
    let held = 10 - Double(frames) / 16000
    print("CONVERSION 10s input: held=\(held*1000) ms, work=\((ProcessInfo.processInfo.systemUptime-start)*1000) ms")
    XCTAssertLessThan(held, 0.01)
  }

  func testGrowingHypothesisCost() throws {
    let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let script = try String(contentsOf: root.appendingPathComponent("short-173-script.md"), encoding: .utf8)
    let tokens = PrompterDocument(markdown: script).spokenTokens
    var tracker = RecognitionTracker(generation: 1)
    for count in [50, 100, 200, 400] {
      let text = tokens.prefix(count).map(\.text).joined(separator: " ")
      let start = ProcessInfo.processInfo.systemUptime
      let update = tracker.consume(.init(replacementID: "long", generation: 1, text: text, isFinal: false, timestamp: Double(count)), script: tokens)
      XCTAssertEqual(update.tokenIndex, count - 1)
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.25)
      print("MATCHER \(count) words: \((ProcessInfo.processInfo.systemUptime - start)*1000) ms, index \(update.tokenIndex)")
    }
  }
}
