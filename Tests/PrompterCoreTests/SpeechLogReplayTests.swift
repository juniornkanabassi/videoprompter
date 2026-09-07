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
  private struct CandidateLogLine: Decodable {
    let type: String
    let generation: UInt64?
    let replacementID: String?
    let audioStart: Double?
    let audioEnd: Double?
    let isFinal: Bool?
    let locale: String?
    let text: String?
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

  func testExternalCandidateReplayUsesProviderRevisionIdentity() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let logPath = environment["JUNIORPROMPTER_CANDIDATE_REPLAY_LOG_PATH"],
      let scriptPath = environment["JUNIORPROMPTER_CANDIDATE_REPLAY_SCRIPT_PATH"]
    else {
      throw XCTSkip("Set candidate replay log and script paths to run an external replay.")
    }
    let lines = try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n").compactMap {
      try JSONDecoder().decode(CandidateLogLine.self, from: Data($0.utf8))
    }.filter { $0.type == "candidate" }
    guard let first = lines.first,
      let generation = first.generation,
      first.replacementID != nil
    else { return XCTFail("Candidate replay log must include generation and replacementID.") }
    let tokens = PrompterDocument(markdown: try String(contentsOfFile: scriptPath, encoding: .utf8))
      .spokenTokens
    var tracker = RecognitionTracker(generation: generation)
    for (index, line) in lines.enumerated() {
      guard let lineGeneration = line.generation, let replacementID = line.replacementID,
        let audioStart = line.audioStart, let audioEnd = line.audioEnd,
        let isFinal = line.isFinal, let locale = line.locale, let text = line.text
      else { return XCTFail("Candidate line \(index) is missing replay identity or timing.") }
      let update = tracker.consume(
        .init(
          replacementID: replacementID, generation: lineGeneration, text: text, isFinal: isFinal,
          timestamp: audioEnd, localeIdentifier: locale, audioStart: audioStart, audioEnd: audioEnd),
        script: tokens)
      XCTAssertLessThan(update.tokenIndex, tokens.count, "Candidate line \(index) escaped the script.")
    }
    XCTAssertEqual(tracker.tokenIndex, tokens.count - 1)
  }
}
