import AppKit
import XCTest
import PrompterCore
@testable import VideoPrompter

@MainActor
final class VoiceScrollResponseTests: XCTestCase {
  func testPartialBurstReachesItsLinePromptlyAfterSilence() throws {
    for frameRate in [30, 60, 120] {
      for count in [1, 3, 12] {
      let script = (0..<30).map { "\($0 == 0 ? "Zephyr" : "Line") \($0) has words to read." }.joined(separator: "\n\n")
      let session = SessionStore()
      var now = 0.0
      session.clock = { now }
      var settings = PrompterSettings(); settings.mode = "Voice"
      session.present(record: .init(metadata: .init(title: "Response", fileName: "response.md"), markdown: script), settings: settings)
      session.play(captureAudio: false)
      defer { session.pause() }
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
      let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 2400))
      scroll.documentView = text
      let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
      coordinator.textView = text
      coordinator.render(document: session.document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)
      coordinator.guideFraction = 0.35
      coordinator.isActivelyRunning = true
      coordinator.setManualSource { session.voicePosition() }
      coordinator.alignManual(in: scroll)
      for _ in 0..<(4 * frameRate) { now += 1.0 / Double(frameRate); coordinator.alignManual(in: scroll) }
      let start = now
      let initial = scroll.contentView.bounds.origin.y
      let target = try XCTUnwrap(coordinator.manualScrollY(at: Double(count), in: scroll))
      session.acceptSpeechCandidate(.init(replacementID: "partial", generation: 1, locale: .init(identifier: "en-GB"),
        text: session.document.spokenTokens.prefix(count).map(\.text).joined(separator: " "),
        range: .init(start: .zero, duration: .init(seconds: 1, preferredTimescale: 48000)), isFinal: false))
      XCTAssertEqual(session.tokenIndex, count)
      var macReached: Double?, padReached: Double?
      var pad = initial
      for _ in 0..<(3 * frameRate) {
        now += 1.0 / Double(frameRate)
        let position = session.voicePosition()
        XCTAssertLessThanOrEqual(position, Double(count) + VoiceGlide.lead)
        coordinator.applyManualPosition(position, in: scroll)
        let mac = scroll.contentView.bounds.origin.y
        // ScriptCanvas applies the already-smoothed fractional position directly.
        pad = mac
        if macReached == nil, mac >= initial + (target - initial) * 0.9 { macReached = now - start }
        if padReached == nil, pad >= initial + (target - initial) * 0.9 { padReached = now - start }
      }
      print("VOICE PARTIAL TO SCROLL 90% for \(count) words at \(frameRate) Hz: Mac=\(macReached ?? -1)s iPad=\(padReached ?? -1)s")
      XCTAssertLessThan(try XCTUnwrap(macReached), count == 1 ? 0.24 : count == 3 ? 0.31 : 0.6)
      XCTAssertLessThan(try XCTUnwrap(padReached), count == 1 ? 0.24 : count == 3 ? 0.31 : 0.6)
      }
    }
  }
}
