import Foundation
import XCTest

@testable import PrompterCore

/// Short 173 at 314-318 s: dictation writes "missed five of their seven big" where the script has
/// "missed 5 of their 7 big". Every spelled number broke the run, so "of their", "7" and "big" waited
/// until "their opponents" six seconds later.
final class Replay_s173_Tests: XCTestCase {
  private struct Line: Decodable {
    let generation: UInt64
    let replacementID: String
    let locale: String
    let audioStart: Double
    let audioEnd: Double
    let isFinal: Bool
    let text: String
  }

  func testSpelledNumbersContinueTheScriptsDigits() throws {
    let script = PrompterDocument(markdown: """
      And Bayern, 40% both years. Thus, of the 3 best attacks in Europe, Barcelona are the most clinical.

      And even in the ties that knocked them out, they scored 8 goals from an xG of 7.5. Against Inter, 6 from an xG of just over 4.

      Yes, they missed 5 of their 7 big chances in the 2nd leg against Atletico.

      But across those 4 games, their opponents scored 10 goals from an xG of 5.4 and put away 8 of their 10 big chances.
      """).spokenTokens
    let words = script.map(\.normalised)
    let over = try XCTUnwrap(words.firstIndex(of: "over"))
    let missed = try XCTUnwrap(words.firstIndex(of: "missed"))
    XCTAssertEqual(words[missed...].prefix(5), ["missed", "5", "of", "their", "7"])
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "s173-spelled-numbers", withExtension: "jsonl", subdirectory: "Fixtures"))
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(Line.self, from: Data($0.utf8))
    }
    var tracker = RecognitionTracker(generation: lines[0].generation, tokenIndex: over)
    var reached: [Double: Int] = [:]
    for line in lines {
      _ = tracker.consume(.init(
        replacementID: line.replacementID, generation: line.generation, text: line.text,
        isFinal: line.isFinal, timestamp: line.audioEnd, localeIdentifier: line.locale,
        audioStart: line.audioStart, audioEnd: line.audioEnd), script: script)
      reached[line.audioEnd] = tracker.tokenIndex
      XCTAssertLessThanOrEqual(tracker.tokenIndex, missed + 5, "Dimmed past \"big\", which he had not reached.")
    }
    XCTAssertEqual(reached[314.64], missed)
    XCTAssertEqual(reached[317.04], missed + 3, "\"five of their\" must dim through \"their\".")
    XCTAssertEqual(reached[317.52], missed + 4, "\"their seven\" must dim \"7\".")
    XCTAssertEqual(reached[318.24], missed + 5, "\"seven big\" must dim \"big\".")
  }
}
