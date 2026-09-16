import Foundation
import XCTest

@testable import PrompterCore

/// One recognised word and its audio time range, as the recogniser reported it.
struct TimedWord: Codable {
  let text: String
  let start: Double
  let end: Double
}

/// Per-word latency: the instant a script word is shown dimmed minus the instant it finished being
/// spoken. The spoken time comes from the recogniser's own word time ranges, not from when a revision
/// arrived, so the recogniser's listening lag is counted.
enum WordLatency {
  struct Revision {
    let locale: String
    let replacementID: String
    let audioStart: Double
    let audioEnd: Double
    let words: [TimedWord]
  }
  struct Spoken {
    let start: Double
    let end: Double
  }
  typealias Heard = [(word: String, time: Spoken)]

  /// Everything he was heard saying, per locale, with times. Only finalised dictation results carry a
  /// time range per word (a volatile result is one run spanning its whole range), so those are the
  /// source, taking the last revision of each result range. A run holding several words is shared
  /// out by character count.
  static func heard(_ revisions: [Revision]) -> [Heard] {
    Set(revisions.map(\.locale)).sorted().map { locale in
      var latest: [String: Revision] = [:]
      for revision in revisions where revision.locale == locale && revision.words.count > 1 {
        latest[revision.replacementID] = revision
      }
      return latest.values.sorted { $0.audioStart < $1.audioStart }.flatMap(\.words).flatMap { word in
        let tokens = PrompterDocument(markdown: word.text).spokenTokens
        let share = (word.end - word.start) / Double(max(1, tokens.reduce(0) { $0 + $1.text.count }))
        var through = 0
        return tokens.map { token in
          let before = Double(through)
          through += token.text.count
          return (token.normalised, Spoken(start: word.start + share * before, end: word.start + share * Double(through)))
        }
      }
    }
  }

  /// When each script token was spoken: the heard words aligned to the script by longest common
  /// subsequence, the locale that aligns the most tokens winning and the others filling its gaps.
  static func spoken(_ heard: [Heard], script: [DocumentToken]) -> [Spoken?] {
    let target = script.map(\.normalised)
    let alignments = heard.map { words -> [Spoken?] in
      let n = target.count, m = words.count
      var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
      for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
          table[i][j] = target[i] == words[j].word ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
      }
      var times = [Spoken?](repeating: nil, count: n)
      var i = 0, j = 0
      while i < n, j < m {
        if target[i] == words[j].word {
          times[i] = words[j].time
          i += 1
          j += 1
        } else if table[i + 1][j] >= table[i][j + 1] {
          i += 1
        } else {
          j += 1
        }
      }
      return times
    }.sorted { $0.compactMap { $0 }.count > $1.compactMap { $0 }.count }
    guard let primary = alignments.first else { return [] }
    return primary.indices.map { index in primary[index] ?? alignments.lazy.compactMap { $0[index] }.first }
  }

  static func latencies(display: [Double?], spoken: [Spoken?]) -> [Double] {
    zip(display, spoken).compactMap { shown, spoken in
      guard let shown, let spoken else { return nil }
      return shown - spoken.end
    }
  }

  /// Words dimmed before he said them: shown more than the timing noise before their aligned spoken
  /// start, although neither the word nor one of the next two had been heard in the five seconds
  /// before (for those two, before they too were dimmed, within a second). Hearing it keeps a re-read or a false start from counting (the alignment
  /// can only pick one of the readings); hearing a word just after it covers a word he said that
  /// the recogniser missed ("Hansi Flick" heard as "Honda"). A jump ahead still shows, because the
  /// words it passes over were not heard.
  static func early(display: [Double?], spoken: [Spoken?], heard: [Heard], script: [DocumentToken]) -> [(token: Int, lead: Double)] {
    display.indices.compactMap { token in
      guard let shown = display[token], let start = spoken[token]?.start, shown < start - 0.3 else { return nil }
      let recent = (token...min(script.count - 1, token + 2)).contains { other in
        guard let dimmed = display[other], dimmed <= shown + 1 else { return false }
        return heard.contains { $0.contains {
          $0.word == script[other].normalised && $0.time.start > shown - 5 && $0.time.start < dimmed
        } }
      }
      return recent ? nil : (token, start - shown)
    }
  }

  static func report(display: [Double?], spoken: [Spoken?], heard: [Heard], script: [DocumentToken]) -> String {
    let early = early(display: display, spoken: spoken, heard: heard, script: script)
    let worst = display.indices.compactMap { token -> (Int, Double)? in
      guard let shown = display[token], let end = spoken[token]?.end else { return nil }
      return (token, shown - end)
    }.max { $0.1 < $1.1 }
    var slowest = "none"
    if let (token, lag) = worst {
      let words = script[max(0, token - 3)...min(script.count - 1, token + 1)].map(\.text).joined(separator: " ")
      slowest = String(format: "%.3fs on token %d (\"%@\", spoken ending %.2fs)", lag, token, words, spoken[token]?.end ?? 0)
    }
    return "per-word latency \(describe(latencies(display: display, spoken: spoken))); "
      + "dimmed ahead of the reader \(early.count): \(early.map { "\($0.token) \(script[$0.token].text) by \(String(format: "%.2f", $0.lead))s" }); "
      + "slowest \(slowest)"
  }

  static func percentiles(_ values: [Double]) -> (p50: Double, p90: Double, max: Double) {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return (0, 0, 0) }
    return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))], sorted[sorted.count - 1])
  }

  static func describe(_ values: [Double]) -> String {
    let p = percentiles(values)
    return String(format: "n=%d p50 %.3fs p90 %.3fs max %.3fs", values.count, p.p50, p.p90, p.max)
  }
}

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
    let wallSecondsSinceFirstAudio: Double?
    let words: [TimedWord]?
    let tokenIndex: Int?
    let publishedSeconds: Double?
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
    let all = try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n").compactMap {
      try JSONDecoder().decode(CandidateLogLine.self, from: Data($0.utf8))
    }
    let lines = all.filter { $0.type == "candidate" }
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
    // First instant each token is dimmed, if this replay had been live: the arrival of the revision
    // that credited it.
    var shown = [Double?](repeating: nil, count: tokens.count)
    var reached = -1
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
      if update.status == .advanced, update.tokenIndex != previous {
        let heard = PrompterDocument(markdown: text).spokenTokens.map(\.normalised)
        holds.append("moved \(audioEnd) \(previous)->\(update.tokenIndex) \(locale) | heard: \(heard.suffix(8).joined(separator: " "))")
      }
      if update.status == .advanced, update.tokenIndex > reached, let wall = line.wallSecondsSinceFirstAudio {
        for token in (reached + 1)...update.tokenIndex { shown[token] = wall }
        reached = update.tokenIndex
      }
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
    // of 153 advances immediate; after that and after a misrecognised word stopped stranding the
    // rest of its phrase, mean 0.35s, median 0.24s, p90 1.08s with 85 of 188 immediate. The residual is dominated by the recogniser's own delivery lag, not by the
    // matcher: the declined candidates in a long wait are ones whose transcript has not yet reached
    // the next script word at all. The bound guards the matcher's share against regression.
    if lines.contains(where: { $0.words != nil }) {
      let heard = WordLatency.heard(lines.compactMap { line in
        guard let locale = line.locale, let id = line.replacementID, let start = line.audioStart,
          let end = line.audioEnd, let words = line.words else { return nil }
        return .init(locale: locale, replacementID: id, audioStart: start, audioEnd: end, words: words)
      })
      let spoken = WordLatency.spoken(heard, script: tokens)
      print("Replayed (revision arrival that dims the word): \(WordLatency.report(display: shown, spoken: spoken, heard: heard, script: tokens))")
      XCTAssertTrue(WordLatency.early(display: shown, spoken: spoken, heard: heard, script: tokens).isEmpty,
        "The replay dimmed words before they were said.")
      var painted = [Double?](repeating: nil, count: tokens.count)
      for line in all where line.type == "token_display" {
        if let token = line.tokenIndex, tokens.indices.contains(token) { painted[token] = line.wallSecondsSinceFirstAudio }
      }
      if painted.contains(where: { $0 != nil }) {
        print("Recorded (dim painted in the rendered run): \(WordLatency.report(display: painted, spoken: spoken, heard: heard, script: tokens))")
      }
    }
    if environment["JUNIORPROMPTER_CANDIDATE_REPLAY_VERBOSE"] == "1" {
      for line in holds { print(line) }
    }
    if !lags.isEmpty {
      let bound = Double(environment["JUNIORPROMPTER_MAX_ACCEPTANCE_LAG_P90"] ?? "") ?? 1.3
      XCTAssertLessThanOrEqual(p90, bound, "Spoken-word-to-dim lag regressed: p90 \(p90)s over \(bound)s.")
    }
    XCTAssertEqual(tracker.tokenIndex, tokens.count - 1)
  }
}
