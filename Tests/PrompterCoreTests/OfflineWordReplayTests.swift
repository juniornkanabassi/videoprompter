import Foundation
import XCTest

@testable import PrompterCore

/// Offline Whisper words are not Apple Speech candidates. Feed stable prefixes at word ends to
/// measure matcher-only delay; no invented recogniser arrival time or hypothesis revisions.
final class OfflineWordReplayTests: XCTestCase {
  private struct Replay {
    let tokens: [DocumentToken]
    let words: [TimedWord]
    let shown: [Double?]
    let alignment: WordLatency.Alignment
    let finalToken: Int
    let positions: [Int]
  }

  private func replay(_ name: String) throws -> Replay {
    let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let tokens = PrompterDocument(markdown: try String(
      contentsOf: fixtures.appendingPathComponent("\(name)-script.md"), encoding: .utf8)).spokenTokens
    let compressed = try Data(contentsOf: fixtures.appendingPathComponent("\(name)-offline-words.jsonl.deflate"))
    let data = try (compressed as NSData).decompressed(using: .zlib) as Data
    let words = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
      try JSONDecoder().decode(TimedWord.self, from: Data($0.utf8))
    }
    XCTAssertFalse(words.isEmpty)
    var tracker = RecognitionTracker(generation: 1)
    var shown = [Double?](repeating: nil, count: tokens.count)
    var reached = -1
    var positions: [Int] = []
    var start = 0
    for i in words.indices {
      XCTAssertGreaterThanOrEqual(words[i].start, 0)
      XCTAssertGreaterThanOrEqual(words[i].end, words[i].start)
      if i > 0 {
        XCTAssertGreaterThanOrEqual(words[i].start, words[i - 1].end)
        if words[i].start - words[i - 1].end >= 1.5
          || words[i - 1].text.last.map({ ".?!".contains($0) }) == true || i - start >= 24 {
          start = i
        }
      }
      let update = tracker.consume(.init(
        replacementID: "offline-\(start)", generation: 1,
        text: words[start...i].map(\.text).joined(separator: " "), isFinal: false,
        timestamp: words[i].end, localeIdentifier: "en_GB",
        audioStart: words[start].start, audioEnd: words[i].end), script: tokens)
      positions.append(update.tokenIndex)
      if update.status == .advanced, update.tokenIndex > reached {
        for token in (reached + 1)...update.tokenIndex { shown[token] = words[i].end }
        reached = update.tokenIndex
      }
    }
    let heard: WordLatency.Heard = words.flatMap { word in
      PrompterDocument(markdown: word.text).spokenTokens.map {
        ($0.normalised, WordLatency.Spoken(start: word.start, end: word.end, runStart: word.start))
      }
    }
    var alignment = WordLatency.align([heard], script: tokens)
    if name == "short-194" {
      // LCS selects the later corrected order. All three words were already said in the first
      // "UEFA's Champions League official" attempt; bind them to that actual occurrence.
      for (token, word) in [(255, 425), (256, 423), (257, 424)] {
        XCTAssertEqual(tokens[token].normalised, PrompterDocument.normalise(words[word].text.replacingOccurrences(of: "...", with: "")))
        alignment.spoken[token] = .init(start: words[word].start, end: words[word].end, runStart: words[word].start)
      }
    }
    return Replay(tokens: tokens, words: words, shown: shown,
      alignment: alignment, finalToken: tracker.tokenIndex, positions: positions)
  }

  private func assertReading(_ name: String, p50: Double, p90: Double, maximum: Double) throws {
    let result = try replay(name)
    let latency = WordLatency.percentiles(WordLatency.latencies(display: result.shown, spoken: result.alignment.spoken))
    let early = WordLatency.early(display: result.shown, alignment: result.alignment, script: result.tokens)
    print("\(name) OFFLINE matcher-only: \(WordLatency.report(display: result.shown, alignment: result.alignment, script: result.tokens))")
    XCTAssertEqual(result.finalToken, result.tokens.count - 1)
    XCTAssertGreaterThan(result.alignment.spoken.compactMap { $0 }.count, result.tokens.count * 4 / 5)
    XCTAssertTrue(early.isEmpty, "Ahead: \(early.map { "\($0.token):\(result.tokens[$0.token].text) \($0.lead)s" })")
    XCTAssertLessThanOrEqual(latency.p50, p50)
    XCTAssertLessThanOrEqual(latency.p90, p90)
    XCTAssertLessThanOrEqual(latency.max, maximum)
  }

  /// Use the actual repeated sentence, including the recogniser's "goal-creating" spelling.
  func testShort193RepeatedLineReturnsToTheSamePassage() throws {
    let result = try replay("short-193")
    let last = try XCTUnwrap(result.tokens.firstIndex { $0.normalised == "interceptions" })
    // First reading ends at word 170; word 180 begins the deliberate second reading.
    XCTAssertEqual(result.words[180].text, "He")
    XCTAssertEqual(result.words[192].text, "interceptions.")
    XCTAssertEqual(result.positions[170], last)
    XCTAssertLessThan(result.positions[188], last, "The repeated line should move the reader back")
    XCTAssertEqual(result.positions[192], last, "The repeat must return to the same endpoint")
  }

  func testShort193ClosingAdLibDoesNotMoveTheFinishedScript() throws {
    let result = try replay("short-193")
    XCTAssertEqual(result.words[303...].map(\.text).joined(separator: " "), "Done. You can flip it, Bob!")
    XCTAssertTrue(result.positions[302...].allSatisfy { $0 == result.tokens.count - 1 })
  }

  /// Deliberately omit passages from the recorded words; this is a perturbation, not an actual take.
  func testShort193SkippedPassagesWaitForDistinctLandingWords() throws {
    let result = try replay("short-193")
    let fair = try XCTUnwrap(result.tokens.firstIndex { $0.normalised == "fair" })
    let end = try XCTUnwrap(result.tokens.firstIndex { $0.normalised == "interceptions" })
    var tracker = RecognitionTracker(generation: 1, tokenIndex: fair)
    for i in 158...170 {
      let words = result.words[158...i]
      let update = tracker.consume(.init(
        replacementID: "skip", generation: 1, text: words.map(\.text).joined(separator: " "),
        isFinal: false, timestamp: words.last!.end, localeIdentifier: "en_GB",
        audioStart: words.first!.start, audioEnd: words.last!.end), script: result.tokens)
      if i < 161 { XCTAssertEqual(update.tokenIndex, fair, "A weak opening must not skip a passage") }
      XCTAssertLessThanOrEqual(update.tokenIndex, end)
    }
    XCTAssertEqual(tracker.tokenIndex, end)
  }

  func testShort189OfflineReading() throws {
    try assertReading("short-189", p50: 0.01, p90: 0.30, maximum: 2.1)
  }
  func testShort193OfflineReading() throws {
    try assertReading("short-193", p50: 0.01, p90: 0.33, maximum: 1.8)
  }
  /// The transcript says "Pedry since the 2024-2025 season" for "Pedri since 2024/25".
  /// Recovery used a different year comparison from the local continuation, stalling until
  /// "Vitinha completes" 18.76 seconds later. Credit the year as soon as it is supplied.
  func testShort194ExpandedYearRecoversAfterAMisheardName() throws {
    let result = try replay("short-194")
    XCTAssertEqual(result.words[319].text, "2024-2025")
    XCTAssertEqual(result.tokens[218].text, "25")
    XCTAssertLessThan(result.positions[318], 217, "Do not credit the year before it is heard")
    XCTAssertEqual(result.positions[319], 218)
    var wrongYear = RecognitionTracker(generation: 1, tokenIndex: 214)
    let update = wrongYear.consume(.init(
      replacementID: "wrong-year", generation: 1,
      text: "Going back to our per 90 comparison with Pedry since the 2024-2026",
      isFinal: false, timestamp: 195.49, localeIdentifier: "en_GB",
      audioStart: 188, audioEnd: 195.49), script: result.tokens)
    XCTAssertLessThan(update.tokenIndex, 218, "A different season must not match the script's 25")
  }

  func testShort194OfflineReading() throws {
    try assertReading("short-194", p50: 0.01, p90: 0.30, maximum: 15.7)
  }
}
