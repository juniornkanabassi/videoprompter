import Foundation
import XCTest

@testable import PrompterCore

/// Short 172, the edited rough cut. Candidates are the production trace's own (traces-20260916/s172.jsonl,
/// every result of the dictation window that opens at 120.12 s), fed in arrival order.
final class Replay_s172_Tests: XCTestCase {
  private struct Line: Decodable {
    let generation: UInt64
    let replacementID: String
    let locale: String
    let audioStart: Double
    let audioEnd: Double
    let isFinal: Bool
    let text: String
  }

  /// "than him and if you still" is the recogniser's first try at "than him and if you're still". The
  /// "you still" in it also opens "and you still think" nine words on, and crediting it there dimmed
  /// "not convinced by my argument and you still" before he had said them.
  func testMisheardYouStillDoesNotSkipToTheSameWordsAhead() throws {
    continueAfterFailure = false
    let script = """
      Then, under this logic, shouldn't Harry Kane be ahead of Mbappé, as over the totality of the season he was a better goalscorer than him?

      And if you're still not convinced by my argument and you still think Mbappé deserves to win the Ballon d'Or, let me ask you this.
      """
    let tokens = PrompterDocument(markdown: script).spokenTokens
    let normalised = tokens.map(\.normalised)
    let argument = try XCTUnwrap(normalised.firstIndex(of: "argument"))
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "replay-s172-you-still", withExtension: "jsonl", subdirectory: "Fixtures"))
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(Line.self, from: Data($0.utf8))
    }
    var tracker = RecognitionTracker(
      generation: 1, tokenIndex: try XCTUnwrap(normalised.firstIndex(of: "goalscorer")))
    var heardArgument = false
    for line in lines {
      _ = tracker.consume(
        .init(
          replacementID: line.replacementID, generation: line.generation, text: line.text,
          isFinal: line.isFinal, timestamp: line.audioEnd, localeIdentifier: line.locale,
          audioStart: line.audioStart, audioEnd: line.audioEnd),
        script: tokens)
      heardArgument = heardArgument
        || PrompterDocument(markdown: line.text).spokenTokens.contains { $0.normalised == "argument" }
      if !heardArgument {
        XCTAssertLessThan(
          tracker.tokenIndex, argument, "\"\(line.text)\" dimmed \(normalised[tracker.tokenIndex]) ahead of the reader")
      }
    }
    XCTAssertEqual(normalised[tracker.tokenIndex], "d'or")
  }

  /// The numbered list: he reads the script's "1." as "number one", and the recogniser writes "one".
  /// Revision texts are the trace's own (25.2 to 25.92 s), from the start of the sentence.
  func testSpokenNumberCreditsTheScriptsDigit() throws {
    let tokens = PrompterDocument(markdown: """
      The main 3 criteria on which the Ballon d’Or is awarded are as follows:

      1. Individual performances, decisive and impressive character
      2. Team performances and achievements
      """).spokenTokens
    var tracker = RecognitionTracker(
      generation: 1, tokenIndex: try XCTUnwrap(tokens.firstIndex { $0.normalised == "follows" }))
    let sentence = "The main three criteria on which the Ballon d'Or is awarded or as follows"
    for (end, tail) in [(25.2, " number"), (25.44, " number one"), (25.92, ", number one individual")] {
      _ = tracker.consume(
        .init(
          replacementID: "1-dictation-0-0-16000", generation: 1, text: sentence + tail, isFinal: false,
          timestamp: end, localeIdentifier: "en_GB", audioStart: 21.6, audioEnd: end),
        script: tokens)
    }
    XCTAssertEqual(tokens[tracker.tokenIndex].text, "Individual")
  }
}
