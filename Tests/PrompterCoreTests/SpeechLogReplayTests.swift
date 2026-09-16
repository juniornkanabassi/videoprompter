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
    var tail: [String] = []
  }
  struct Spoken {
    let start: Double
    let end: Double
    /// Start of the recogniser's run the word came from; a run can hold several words.
    var runStart: Double
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
          return (token.normalised, Spoken(
            start: word.start + share * before, end: word.start + share * Double(through), runStart: word.start))
        }
      }
    }
  }

  struct Alignment {
    /// When each script token was spoken.
    var spoken: [Spoken?]
    /// Heard words the alignment did not use: a re-read, a false start, or a word said twice.
    var unaligned: [(word: String, time: Spoken)]
    /// Every revision as it arrived: when, how far into the audio, and its last three words.
    var named: [(arrival: Double, audioEnd: Double, tail: [String])] = []
  }

  /// The heard words aligned to the script by longest common subsequence, the locale that aligns
  /// the most tokens winning and the others filling its gaps.
  static func align(_ revisions: [Revision], arrivals: [Double?], script: [DocumentToken]) -> Alignment {
    var alignment = align(heard(revisions), script: script)
    alignment.named = zip(revisions, arrivals).compactMap { revision, arrival in
      arrival.map { ($0, revision.audioEnd, Array(revision.tail.suffix(3))) }
    }
    return alignment
  }

  static func align(_ heard: [Heard], script: [DocumentToken]) -> Alignment {
    let target = script.map(\.normalised)
    var unaligned: [(word: String, time: Spoken)] = []
    let alignments = heard.map { words -> [Spoken?] in
      let n = target.count, m = words.count
      var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
      for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
          table[i][j] = target[i] == words[j].word ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
      }
      var times = [Spoken?](repeating: nil, count: n)
      var used = Set<Int>()
      var i = 0, j = 0
      while i < n, j < m {
        if target[i] == words[j].word {
          times[i] = words[j].time
          used.insert(j)
          i += 1
          j += 1
        } else if table[i + 1][j] >= table[i][j + 1] {
          i += 1
        } else {
          j += 1
        }
      }
      unaligned += words.indices.filter { !used.contains($0) }.map { words[$0] }
      return times
    }.sorted { $0.compactMap { $0 }.count > $1.compactMap { $0 }.count }
    guard let primary = alignments.first else { return Alignment(spoken: [], unaligned: []) }
    return Alignment(
      spoken: primary.indices.map { index in primary[index] ?? alignments.lazy.compactMap { $0[index] }.first },
      unaligned: unaligned)
  }

  static func latencies(display: [Double?], spoken: [Spoken?]) -> [Double] {
    zip(display, spoken).compactMap { shown, spoken in
      guard let shown, let spoken else { return nil }
      return shown - spoken.end
    }
  }

  /// Words dimmed before he said them: shown before the start of the recogniser's run that holds
  /// the word, less 0.07 s (one 33 ms replay chunk, which reaches the recogniser before its wall
  /// time, plus the 30 ms grid of its word times). Two things excuse it. The recogniser itself
  /// named the word by then, in the last three words of a revision reaching within 0.3 s of the
  /// word's finalised start: measured over the six traces of 16 and 17 September, a revision names
  /// a word before its finalised start for 11 of 2907 words, by at most 0.30 s but for one 0.84 s.
  /// Or the word (or its singular or plural, "chance" for "chances"), or one of the next two
  /// words dimmed within a second after it, was heard in the five seconds before as a word the
  /// alignment left out: a re-read or a false start, whose other reading the alignment picked, or
  /// a neighbour said where the recogniser missed this word ("Hansi Flick" heard as "Honda").
  static func early(display: [Double?], alignment: Alignment, script: [DocumentToken]) -> [(token: Int, lead: Double)] {
    display.indices.compactMap { token in
      guard let shown = display[token], let run = alignment.spoken[token]?.runStart, shown < run - 0.07 else { return nil }
      let named = alignment.named.contains {
        $0.arrival <= shown && $0.audioEnd >= run - 0.3 && $0.tail.contains(script[token].normalised)
      }
      let excused = named || (token...min(script.count - 1, token + 2)).contains { other in
        guard let dimmed = display[other], dimmed <= shown + 1 else { return false }
        let word = script[other].normalised
        return alignment.unaligned.contains {
          ($0.word == word || min($0.word.count, word.count) >= 4 && ($0.word.hasPrefix(word) || word.hasPrefix($0.word)))
            && $0.time.start > shown - 5 && $0.time.start < dimmed
        }
      }
      return excused ? nil : (token, run - shown)
    }
  }

  static func report(display: [Double?], alignment: Alignment, script: [DocumentToken]) -> String {
    let spoken = alignment.spoken
    let early = early(display: display, alignment: alignment, script: script)
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

  /// A recorded trace fed candidate by candidate through a fresh tracker, exactly as `SessionStore`
  /// consumes results.
  private struct Replay {
    var finalToken = 0
    var steps: [Int] = []
    /// Acceptance lag in audio time. While the tracker sits on a token, every fresh candidate it
    /// declines is speech the reader has already produced but the presenter has not dimmed. The lag
    /// for an advance is how much further into the recording the recogniser had listened between
    /// the first declined candidate and the one that finally credited the word.
    var lags: [Double] = []
    var worstLag = "none"
    /// First instant each token is dimmed, had this run been live: the arrival of the revision
    /// that credited it.
    var shown: [Double?] = []
    var log: [String] = []
    var alignment = WordLatency.Alignment(spoken: [], unaligned: [])
  }

  private static func replay(_ lines: [CandidateLogLine], script tokens: [DocumentToken]) throws -> Replay {
    let generation = try XCTUnwrap(lines.first?.generation, "The trace must carry provider generations.")
    var tracker = RecognitionTracker(generation: generation)
    var result = Replay(shown: Array(repeating: nil, count: tokens.count))
    var previous = -1
    var reached = -1
    var firstDeclinedAudioEnd: Double?
    for (index, line) in lines.enumerated() {
      guard let lineGeneration = line.generation, let replacementID = line.replacementID,
        let audioStart = line.audioStart, let audioEnd = line.audioEnd,
        let isFinal = line.isFinal, let locale = line.locale, let text = line.text
      else {
        XCTFail("Candidate line \(index) is missing replay identity or timing.")
        return result
      }
      let update = tracker.consume(
        .init(
          replacementID: replacementID, generation: lineGeneration, text: text, isFinal: isFinal,
          timestamp: audioEnd, localeIdentifier: locale, audioStart: audioStart, audioEnd: audioEnd),
        script: tokens)
      let heard = PrompterDocument(markdown: text).spokenTokens.map(\.normalised).suffix(8).joined(separator: " ")
      if update.status == .advanced, update.tokenIndex != previous {
        result.log.append("moved \(audioEnd) \(previous)->\(update.tokenIndex) \(locale) | heard: \(heard)")
      }
      if update.status == .advanced, update.tokenIndex > reached, let wall = line.wallSecondsSinceFirstAudio {
        for token in (reached + 1)...update.tokenIndex { result.shown[token] = wall }
        reached = update.tokenIndex
      }
      if update.tokenIndex > previous {
        result.steps.append(update.tokenIndex - previous)
        let lag = firstDeclinedAudioEnd.map { audioEnd - $0 } ?? 0
        if previous >= 0 {
          result.lags.append(lag)
          if lag >= (result.lags.max() ?? 0) {
            result.worstLag = "token \(update.tokenIndex) at audioEnd \(audioEnd) lagged \(lag)s"
          }
        }
        previous = update.tokenIndex
        firstDeclinedAudioEnd = nil
      } else if update.status == .held {
        if firstDeclinedAudioEnd == nil { firstDeclinedAudioEnd = audioEnd }
        let next = previous + 1 < tokens.count ? tokens[(previous + 1)...].prefix(6).map(\.normalised) : []
        result.log.append("held \(audioEnd) tok \(previous) \(locale) | script: \(next.joined(separator: " ")) | heard: \(heard)")
      }
      XCTAssertLessThan(update.tokenIndex, tokens.count, "Candidate line \(index) escaped the script.")
    }
    result.finalToken = tracker.tokenIndex
    let revisions = lines.compactMap { line -> (WordLatency.Revision, Double?)? in
      guard let locale = line.locale, let id = line.replacementID, let start = line.audioStart,
        let end = line.audioEnd, let text = line.text else { return nil }
      return (.init(locale: locale, replacementID: id, audioStart: start, audioEnd: end, words: line.words ?? [],
        tail: PrompterDocument(markdown: text).spokenTokens.suffix(3).map(\.normalised)), line.wallSecondsSinceFirstAudio)
    }
    result.alignment = WordLatency.align(revisions.map(\.0), arrivals: revisions.map(\.1), script: tokens)
    return result
  }

  private static func lines(_ text: String) throws -> [CandidateLogLine] {
    try text.split(separator: "\n").map { try JSONDecoder().decode(CandidateLogLine.self, from: Data($0.utf8)) }
  }

  /// A real reading replayed from its committed trace: the candidates the production recogniser
  /// produced from the recording on 16 September, with its own word timings, deflated. Every word
  /// must dim within the bound measured on that trace after he finishes saying it, none may dim
  /// before he says it, and the reading must end on the last word.
  private func assertRecording(
    _ name: String, p50: Double, p90: Double, max: Double, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let tokens = PrompterDocument(markdown: try String(
      contentsOf: fixtures.appendingPathComponent("\(name)-script.md"), encoding: .utf8)).spokenTokens
    let deflated = try Data(contentsOf: fixtures.appendingPathComponent("\(name)-reading.jsonl.deflate"))
    let trace = try (deflated as NSData).decompressed(using: .zlib) as Data
    let replay = try Self.replay(Self.lines(String(decoding: trace, as: UTF8.self)), script: tokens)
    let latency = WordLatency.percentiles(WordLatency.latencies(display: replay.shown, spoken: replay.alignment.spoken))
    print("\(name) fixture: \(WordLatency.report(display: replay.shown, alignment: replay.alignment, script: tokens))")
    XCTAssertEqual(replay.finalToken, tokens.count - 1, "\(name) did not reach the end", file: file, line: line)
    XCTAssertGreaterThan(replay.alignment.spoken.compactMap { $0 }.count, tokens.count * 4 / 5, "\(name): too few timed words", file: file, line: line)
    let early = WordLatency.early(display: replay.shown, alignment: replay.alignment, script: tokens)
    XCTAssertTrue(early.isEmpty, "\(name) dimmed words before they were said: \(early)", file: file, line: line)
    XCTAssertLessThanOrEqual(latency.p50, p50, "\(name) p50", file: file, line: line)
    XCTAssertLessThanOrEqual(latency.p90, p90, "\(name) p90", file: file, line: line)
    XCTAssertLessThanOrEqual(latency.max, max, "\(name) max", file: file, line: line)
  }

  /// Canonical reading. Before this work the same measure on the rendered presenter was p50 0.501 s,
  /// p90 1.231 s, max 3.586 s; this trace replays at p50 0.434 s, p90 0.875 s, max 2.606 s.
  func testCanonicalRecordingDimsEachWordWithinTheMeasuredBound() throws {
    try assertRecording("canonical", p50: 0.44, p90: 0.90, max: 2.7)
  }

  /// Short 173: six minutes with false starts and re-reading, where four phrases once jumped the
  /// presenter up to sixty words ahead. Replays at p50 0.417 s, p90 0.725 s; the 11.45 s maximum is
  /// "has gotten" said as "have gotten weaker", a pause, and the sentence read again.
  func testShort173RecordingNeverJumpsAhead() throws {
    try assertRecording("short-173", p50: 0.43, p90: 0.75, max: 11.5)
  }

  /// Short 172: the precision case, with names, accents, a title line and a numbered list.
  /// Replays at p50 0.433 s, p90 0.808 s, max 4.012 s ("Gerd Müller Trophy" garbled).
  func testShort172RecordingNeverJumpsAhead() throws {
    try assertRecording("short-172", p50: 0.44, p90: 0.83, max: 4.1)
  }

  func testExternalCandidateReplayUsesProviderRevisionIdentity() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let logPath = environment["JUNIORPROMPTER_CANDIDATE_REPLAY_LOG_PATH"],
      let scriptPath = environment["JUNIORPROMPTER_CANDIDATE_REPLAY_SCRIPT_PATH"]
    else {
      throw XCTSkip("Set candidate replay log and script paths to run an external replay.")
    }
    let all = try Self.lines(String(contentsOfFile: logPath, encoding: .utf8))
    let lines = all.filter { $0.type == "candidate" }
    guard lines.first?.replacementID != nil
    else { return XCTFail("Candidate replay log must include generation and replacementID.") }
    let tokens = PrompterDocument(markdown: try String(contentsOfFile: scriptPath, encoding: .utf8))
      .spokenTokens
    let replay = try Self.replay(lines, script: tokens)
    let forward = replay.steps.dropFirst()
    let sorted = replay.lags.sorted()
    let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    print("Candidate replay: \(lines.count) candidates, \(replay.steps.count) advances. "
      + "Words per advance mean \(Double(forward.reduce(0, +)) / Double(max(1, forward.count))) "
      + "max \(forward.max() ?? 0). Single-word advances \(forward.filter { $0 == 1 }.count)/\(forward.count).")
    print("Acceptance lag (audio seconds a spoken word waits before it dims): n=\(sorted.count) "
      + "mean \(mean)s median \(median)s p90 \(p90)s max \(sorted.last ?? 0)s. "
      + "Immediate \(sorted.filter { $0 == 0 }.count)/\(sorted.count). Worst: \(replay.worstLag).")
    if lines.contains(where: { $0.words != nil }) {
      print("Replayed (revision arrival that dims the word): \(WordLatency.report(display: replay.shown, alignment: replay.alignment, script: tokens))")
      XCTAssertTrue(WordLatency.early(display: replay.shown, alignment: replay.alignment, script: tokens).isEmpty,
        "The replay dimmed words before they were said.")
      var painted = [Double?](repeating: nil, count: tokens.count)
      for line in all where line.type == "token_display" {
        if let token = line.tokenIndex, tokens.indices.contains(token) { painted[token] = line.wallSecondsSinceFirstAudio }
      }
      if painted.contains(where: { $0 != nil }) {
        print("Recorded (dim painted in the rendered run): \(WordLatency.report(display: painted, alignment: replay.alignment, script: tokens))")
      }
    }
    if environment["JUNIORPROMPTER_CANDIDATE_REPLAY_VERBOSE"] == "1" {
      for line in replay.log { print(line) }
    }
    // The residual acceptance lag is dominated by the recogniser, not the matcher: in a long wait
    // the declined candidates have not yet reached the next script word at all. The bound guards
    // the matcher's share against regression.
    if !sorted.isEmpty {
      let bound = Double(environment["JUNIORPROMPTER_MAX_ACCEPTANCE_LAG_P90"] ?? "") ?? 1.3
      XCTAssertLessThanOrEqual(p90, bound, "Spoken-word-to-dim lag regressed: p90 \(p90)s over \(bound)s.")
    }
    XCTAssertEqual(replay.finalToken, tokens.count - 1)
  }
}
