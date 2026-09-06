import Foundation
import XCTest

@testable import PrompterCore

final class SpeechLogReplayTests: XCTestCase {
  private struct Line: Decodable {
    let start: Double
    let end: Double
    let isFinal: Bool
    let locale: String
    let text: String
  }
  func testActualDualLocaleLogExcerptReachesEndWithoutPhoneticFalseJump() throws {
    let expected =
      "Today I want to explain why Désiré Doué est un joueur exceptionnel and what that means for the next match. We can pause here and repeat the previous sentence. Je pense que Paris peut gagner cette compétition because the team is playing with confidence. Now we return to the original script."
    let tokens = PrompterDocument(markdown: expected).spokenTokens
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "speech-primary-dual-repeat", withExtension: "jsonl", subdirectory: "Fixtures")
    )
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(Line.self, from: Data($0.utf8))
    }
    var tracker = RecognitionTracker(generation: 1)
    var reachedFrench = false
    for (index, line) in lines.enumerated() {
      let event = RecognitionEvent(
        replacementID: "\(line.locale)-\(line.start)", generation: 1, text: line.text,
        isFinal: line.isFinal, timestamp: line.end, localeIdentifier: line.locale,
        audioStart: line.start, audioEnd: line.end)
      let update = tracker.consumeCandidates([event], script: tokens)
      if update.tokenIndex >= (tokens.firstIndex { $0.normalised == "pense" } ?? .max) {
        reachedFrench = true
      }
      XCTAssertLessThan(
        update.tokenIndex, tokens.count, "Log line \(index) moved outside the script")
    }
    XCTAssertTrue(reachedFrench)
    XCTAssertEqual(tokens[tracker.tokenIndex].normalised, "script")
  }
}
