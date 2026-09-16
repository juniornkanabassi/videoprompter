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
    var previous = -1
    var steps: [Int] = []
    // Acceptance lag in audio time. While the tracker sits on a token, every fresh candidate it
    // declines is speech the reader has already produced but the presenter has not dimmed. The lag
    // for an advance is how much further into the recording the recogniser had listened between the
    // first declined candidate and the one that finally credited the word. Zero means the word dims
    // on the revision that reports it; a second means Junior had spoken a second of further script
    // before the word greyed out.
    var firstDeclinedAudioEnd: Double?
    var lags: [Double] = []
    var holds: [String] = []
    var worst: String = "none"
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
      if update.tokenIndex > previous {
        steps.append(update.tokenIndex - previous)
        let lag = firstDeclinedAudioEnd.map { audioEnd - $0 } ?? 0
        if previous >= 0 {
          lags.append(lag)
          if lag >= (lags.max() ?? 0) {
            worst = "token \(update.tokenIndex) at audioEnd \(audioEnd) lagged \(lag)s"
          }
        }
        previous = update.tokenIndex
        firstDeclinedAudioEnd = nil
      } else if update.status == .held {
        if firstDeclinedAudioEnd == nil { firstDeclinedAudioEnd = audioEnd }
        let heard = PrompterDocument(markdown: text).spokenTokens.map(\.normalised)
        let next = previous + 1 < tokens.count ? tokens[(previous + 1)...].prefix(6).map(\.normalised) : []
        holds.append("held \(audioEnd) tok \(previous) \(locale) | script: \(next.joined(separator: " ")) | heard: \(heard.suffix(8).joined(separator: " "))")
      }
      XCTAssertLessThan(update.tokenIndex, tokens.count, "Candidate line \(index) escaped the script.")
    }
    let forward = steps.dropFirst()
    let sorted = lags.sorted()
    let mean = lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count)
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    print("Candidate replay: \(lines.count) candidates, \(steps.count) advances. "
      + "Words per advance mean \(Double(forward.reduce(0, +)) / Double(max(1, forward.count))) "
      + "max \(forward.max() ?? 0). Single-word advances \(forward.filter { $0 == 1 }.count)/\(forward.count).")
    print("Acceptance lag (audio seconds a spoken word waits before it dims): n=\(lags.count) "
      + "mean \(mean)s median \(median)s p90 \(p90)s max \(sorted.last ?? 0)s. "
      + "Immediate \(lags.filter { $0 == 0 }.count)/\(lags.count). Worst: \(worst).")
    // Measured on the canonical acceptance-easing-060-20260912 trace: before crediting a fresh
    // revision's exact continuation the matcher scored mean 0.48s, median 0.24s, p90 1.44s with 58
    // of 153 advances immediate; after, mean 0.38s, median 0.24s, p90 1.20s with 74 of 175
    // immediate. The residual is dominated by the recogniser's own delivery lag, not by the
    // matcher: the declined candidates in a long wait are ones whose transcript has not yet reached
    // the next script word at all. The bound guards the matcher's share against regression.
    if environment["JUNIORPROMPTER_CANDIDATE_REPLAY_VERBOSE"] == "1" {
      for line in holds.prefix(80) { print(line) }
    }
    if !lags.isEmpty {
      let bound = Double(environment["JUNIORPROMPTER_MAX_ACCEPTANCE_LAG_P90"] ?? "") ?? 1.3
      XCTAssertLessThanOrEqual(p90, bound, "Spoken-word-to-dim lag regressed: p90 \(p90)s over \(bound)s.")
    }
    XCTAssertEqual(tracker.tokenIndex, tokens.count - 1)
  }
}
