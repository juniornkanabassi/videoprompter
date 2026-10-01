import Foundation
import XCTest

@testable import PrompterCore

/// The canonical reading ("VidPrompt v0.3.0 test reading.wav" against "Demo script.txt"):
/// windows cut from traces-20260916/canonical.jsonl, each replayed through a fresh tracker from
/// the word the live session had reached.
final class Replay_canonical_Tests: XCTestCase {
  private struct Line: Decodable {
    let window: String
    let replacementID: String
    let generation: UInt64
    let locale: String
    let audioStart: Double
    let audioEnd: Double
    let isFinal: Bool
    let text: String
  }

  private static let script = PrompterDocument(markdown: """
      Doué is a better Champions League player than Yamal

      As of the 28th of August 2026, Doué is a better Champions League player than Lamine Yamal.

      Now, get what I'm not saying. I am not saying he's a better player than Yamal; I am simply saying that he is a better Champions League player.

      And this should be fairly uncontroversial.

      Doué's played fewer seasons, fewer games in the Champions League, and has fewer minutes in the Champions League.

      Yet, despite that, using UEFA's own stats, Yamal's only got 1 more G/A than Doué. And that's only because he takes penalties.

      Only counting non-penalty G/A, Doué's actually got more G/A than Yamal.

      And before you try to say that Doué's only stat-padding against small teams.

      Over 70% of Doué's G/A in the Champions League are in the knockout stages.

      Not to mention the fact that Doué has played against better opposition and performed better in big Champions League games.

      So, with all this evidence presented, if one is to be intellectually honest, one ought to conclude that Désiré Doué is a better Champions League player than Lamine Yamal

      Conceding this does not mean that Doué is a better player than Yamal, in the same way that conceding that Ronaldo is a better Champions League player than Messi doesn't make Ronaldo better than Messi

      If you are unable to admit this fact, then I'm sorry to say, you're just being dogmatic.

      And if you try to use the excuse that Doué plays for a better team, then I'm sorry, you have just got confirmation bias. You're just looking for points that suit your narrative without actually addressing the main points of the argument.
      """).spokenTokens

  /// The furthest token the window's candidates reach.
  private func replay(_ window: String, from start: Int) throws -> Int {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "replay-canonical", withExtension: "jsonl", subdirectory: "Fixtures"))
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
      .map { try JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
      .filter { $0.window == window }
    XCTAssertFalse(lines.isEmpty)
    var tracker = RecognitionTracker(generation: lines[0].generation, tokenIndex: start)
    var furthest = start
    for line in lines {
      _ = tracker.consume(.init(
        replacementID: line.replacementID, generation: line.generation, text: line.text,
        isFinal: line.isFinal, timestamp: line.audioEnd, localeIdentifier: line.locale,
        audioStart: line.audioStart, audioEnd: line.audioEnd), script: Self.script)
      furthest = max(furthest, tracker.tokenIndex)
    }
    return furthest
  }

  func testScriptMatchesTheTrace() {
    XCTAssertEqual(Self.script.count, 287)
    XCTAssertEqual(Self.script[53].normalised, "player")
    XCTAssertEqual(Self.script[77].normalised, "league")
    XCTAssertEqual(Self.script[90].normalised, "g")
    XCTAssertEqual(Self.script[114].normalised, "yamal")
  }

  /// 21.9-23.52 s, "I'm simply saying he's a better Champions League player" with no "that": the
  /// session sat on "saying" (45) until 24.48 s. 45.0-46.08 s, "got more G than Yamal" with G/A
  /// heard as "G": it sat on "more" (110) until 47.52 s. Neither may pass what he had said.
  func testDroppedWordDoesNotStallTheContinuation() throws {
    XCTAssertEqual(try replay("A", from: 45), 53)
    XCTAssertEqual(try replay("C", from: 110), 114)
  }

  /// 36.5-37.2 s, "only got one more G" against "1 more G/A": the session sat on "got" (87) until
  /// 39.6 s.
  func testSpokenNumberMatchesTheDigit() throws {
    XCTAssertEqual(try replay("B", from: 87), 90)
  }

  /// 30.7-30.96 s, he has said "fewer minutes in the Cham": the French revision's older "in the
  /// Champions League and you in" dimmed the repeat's "League" (77) before he said it.
  func testOlderPhraseInTheRevisionDoesNotDimItsRepeatAhead() throws {
    XCTAssertLessThan(try replay("W", from: 72), 77)
  }
}
