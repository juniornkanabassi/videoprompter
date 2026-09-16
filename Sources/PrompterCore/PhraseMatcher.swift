import Foundation

private let commonWords: Set<String> = [
  "the", "and", "that", "this", "with", "from", "have", "your", "you", "for", "are", "was",
  "but", "not", "une", "les", "des", "dans", "pour", "est", "que", "qui",
]

public struct PhraseMatch: Equatable, Sendable {
  public var tokenIndex: Int
  public var score: Double
  public var direction: Direction
  public enum Direction: Sendable { case forward, backward }
}
public struct PhraseMatcher: Sendable {
  public var backwardWindow: Int
  public var forwardWindow: Int
  public var minimumBackwardTokens: Int
  public init(backwardWindow: Int = 120, forwardWindow: Int = 80, minimumBackwardTokens: Int = 4) {
    self.backwardWindow = backwardWindow
    self.forwardWindow = forwardWindow
    self.minimumBackwardTokens = minimumBackwardTokens
  }
  private let common = commonWords
  public func match(recognised: [String], script: [DocumentToken], currentIndex: Int)
    -> PhraseMatch?
  {
    let words = recognised.map(PrompterDocument.normalise).filter { !$0.isEmpty }
    let target = script.map(\.normalised)
    guard !words.isEmpty && !target.isEmpty else { return nil }
    let current = min(max(0, currentIndex), target.count - 1)
    if words.count >= minimumBackwardTokens {
      let phrase = Array(words.suffix(min(words.count, 10)))
      let informative = phrase.filter { $0.count > 2 && !common.contains($0) }
      guard informative.count >= minimumBackwardTokens else {
        if let match = localForwardMatch(words: words, script: script, current: current) { return match }
        return forwardMatch(words: words, script: script, current: current)
      }
      let lo = max(0, current - backwardWindow)
      let hi = min(target.count, current + forwardWindow + 1)
      var starts: [Int] = []
      if hi - lo >= phrase.count {
        for i in lo...(hi - phrase.count) where Array(target[i..<i + phrase.count]) == phrase {
          starts.append(i)
        }
      }
      let behind = starts.filter { $0 + phrase.count - 1 < current }
      if behind.count == 1 && starts.count == 1 {
        return PhraseMatch(tokenIndex: behind[0] + phrase.count - 1, score: 1, direction: .backward)
      }
    }
    if let match = localForwardMatch(words: words, script: script, current: current) { return match }
    return forwardMatch(words: words, script: script, current: current)
  }
  /// The tail of a fresh revision, when it continues the script exactly from the next token, is
  /// speech the reader has just produced, so it is credited at once rather than waiting for enough
  /// later evidence to clear the ordinary forward thresholds. That wait is what made the word being
  /// spoken dim only once the next word had begun.
  ///
  /// The run must end on the revision's last word, which keeps this to speech just heard, and must
  /// continue the script contiguously from the next token, which keeps it from speculating ahead or
  /// moving back. It deliberately does not require the revision to be a pure append: the dictation
  /// engine rewrites its own tail constantly ("a better champ" becoming "a better Champions
  /// League"), and gating on appends alone left the fix dormant for most of a reading.
  public func forwardExtension(words: [String], script: [DocumentToken], currentIndex: Int)
    -> PhraseMatch?
  {
    let target = script.map(\.normalised)
    guard !words.isEmpty, !target.isEmpty else { return nil }
    let start = min(max(0, currentIndex), target.count - 1) + 1
    guard start < target.count else { return nil }
    for source in 0..<words.count {
      var index = start
      var word = source
      while word < words.count, index < target.count {
        let components = contractionComponents(words[word])
        guard target[index...].starts(with: components) else { break }
        index += components.count
        word += 1
      }
      guard word == words.count, index > start else { continue }
      return PhraseMatch(tokenIndex: index - 1, score: 1, direction: .forward)
    }
    return nil
  }
  private func localForwardMatch(
    words: [String], script: [DocumentToken], current: Int
  ) -> PhraseMatch? {
    let target = script.map(\.normalised)
    let start = current + 1
    guard start < target.count else { return nil }
    for wordStart in words.indices {
      var source = wordStart
      var targetIndex = start
      var sourceCount = 0
      var informative = 0
      while source < words.count, targetIndex < target.count {
        let components = contractionComponents(words[source])
        guard target[targetIndex...].starts(with: components) else { break }
        sourceCount += 1
        informative += components.filter { $0.count > 2 && !common.contains($0) }.count
        targetIndex += components.count
        source += 1
      }
      if sourceCount >= 3, informative >= 2 {
        return PhraseMatch(tokenIndex: targetIndex - 1, score: 1, direction: .forward)
      }
    }
    return nil
  }
  private func forwardMatch(words: [String], script: [DocumentToken], current: Int) -> PhraseMatch? {
    let target = script.map(\.normalised)
    let lo = max(0, current - backwardWindow)
    let hi = min(target.count, current + forwardWindow + 1)
    var destinationScores: [Int: Double] = [:]
    for recognisedStart in 0..<words.count {
      let evidence = Array(words[recognisedStart...])
      guard evidence.count >= min(2, words.count) else { continue }
      let informativeCount = evidence.filter { $0.count > 2 && !common.contains($0) }.count
      guard informativeCount > 0 else { continue }
      for start in lo..<hi where target[start] == evidence[0] {
        var ti = start
        var matched = 0
        var last = start
        var trailingMatches = 0
        for word in evidence {
          let before = ti
          while ti < hi && target[ti] != word { ti += 1 }
          if ti < hi {
            matched += 1
            last = ti
            ti += 1
            trailingMatches = ti - before == 1 ? trailingMatches + 1 : 1
          } else {
            // A word that appears nowhere ahead is a misrecognition, not the end of the phrase.
            // Leaving the scan at the window's end discarded every word after it, so one wrong
            // word ("point" for "points") stranded the rest of a sentence.
            ti = before
          }
        }
        let coverage = Double(matched) / Double(evidence.count)
        let gaps = Double(max(0, last - start + 1 - matched))
        // ponytail: a lone post-gap word is weak evidence; require more tail context for local forward jumps.
        guard gaps == 0 || trailingMatches >= 2 || start + 1 < current else { continue }
        guard words.count == 1 || informativeCount >= 2 || start <= current + 1 else { continue }
        let distance = Double(max(0, start - current))
        let score =
          coverage - gaps * 0.035 - distance * 0.002 - min(0.18, Double(recognisedStart) * 0.025)
        destinationScores[last] = max(destinationScores[last] ?? -1, score)
      }
    }
    let ranked = destinationScores.map { (index: $0.key, score: $0.value) }.sorted {
      $0.score > $1.score
    }
    let best = ranked.first
    let runner = ranked.dropFirst().first?.score ?? 0
    guard let best, best.index >= current, best.score >= (words.count == 1 ? 0.98 : 0.68),
      best.score - runner >= (words.count == 1 ? 0.2 : 0.05)
    else { return nil }
    return PhraseMatch(tokenIndex: best.index, score: best.score, direction: .forward)
  }
  private func contractionComponents(_ word: String) -> [String] {
    switch word {
    case "i'm": return ["i", "am"]
    case "he's": return ["he", "is"]
    case "she's": return ["she", "is"]
    case "we're": return ["we", "are"]
    case "they're": return ["they", "are"]
    default: return [word]
    }
  }
}

public struct RecognitionUpdate: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case advanced, held, staleGeneration, duplicateRevision
  }
  public var status: Status
  public var tokenIndex: Int
}
public struct RecognitionTracker: Sendable {
  private struct Revision: Sendable {
    var words: [String]
    var isFinal: Bool
    var advanced: Bool
  }
  public private(set) var generation: UInt64
  public private(set) var tokenIndex: Int
  private var revisions: [String: Revision] = [:]
  private var seekBaselines: [String: [String]] = [:]
  /// Revisions whose first result covering audio past the re-anchor watermark has been taken as a
  /// baseline rather than credited. See `consumeCandidates`.
  private var postSeekBaselined: Set<String> = []
  private var minimumSeekAudioStart: TimeInterval?
  private var acceptedAudio: [ClosedRange<TimeInterval>] = []
  private var matcher: PhraseMatcher
  public init(generation: UInt64 = 0, tokenIndex: Int = 0, matcher: PhraseMatcher = .init()) {
    self.generation = generation
    self.tokenIndex = tokenIndex
    self.matcher = matcher
  }
  public mutating func invalidate(startingAt index: Int? = nil) {
    generation &+= 1
    revisions.removeAll()
    seekBaselines.removeAll()
    postSeekBaselined.removeAll()
    minimumSeekAudioStart = nil
    acceptedAudio.removeAll()
    if let index { tokenIndex = max(0, index) }
  }
  public mutating func seek(to index: Int) {
    tokenIndex = max(0, index)
    invalidate(startingAt: tokenIndex)
  }
  public mutating func reanchor(
    to index: Int, minimumAudioStart: TimeInterval, baselining events: [RecognitionEvent] = []
  ) {
    tokenIndex = max(0, index)
    acceptedAudio.removeAll()
    minimumSeekAudioStart = minimumAudioStart
    postSeekBaselined.removeAll()
    seekBaselines = revisions.mapValues(\.words)
    for event in events where event.generation == generation {
      let key = "\(event.localeIdentifier)|\(event.replacementID)"
      let words = PrompterDocument(markdown: event.text).spokenTokens.map(\.normalised)
      revisions[key] = .init(words: words, isFinal: event.isFinal, advanced: false)
      seekBaselines[key] = words
    }
  }
  public mutating func consume(_ event: RecognitionEvent, script: [DocumentToken])
    -> RecognitionUpdate
  {
    consumeCandidates([event], script: script)
  }
  public mutating func consumeCandidates(_ events: [RecognitionEvent], script: [DocumentToken])
    -> RecognitionUpdate
  {
    guard !events.isEmpty else { return .init(status: .held, tokenIndex: tokenIndex) }
    var candidates: [(RecognitionEvent, PhraseMatch)] = []
    var sawFresh = false
    for event in events where event.generation == generation {
      let key = "\(event.localeIdentifier)|\(event.replacementID)"
      let words = PrompterDocument(markdown: event.text).spokenTokens.map(\.normalised)
      let old = revisions[key]
      if old?.words == words && old?.isFinal == event.isFinal { continue }
      var wordsToMatch = words
      if let baseline = seekBaselines[key] {
        // Audio the reader had already spoken before re-anchoring must not count again, and the
        // first result that reaches past the watermark still describes mostly that older audio: it
        // arrives a moment late and its tail is speech from before the move. Crediting it threw the
        // reader straight back to where the scroll-back had just taken him from. Take that result
        // as the baseline too, so only what the revision adds afterwards is treated as new speech.
        if let minimumSeekAudioStart,
          event.audioEnd <= minimumSeekAudioStart || !postSeekBaselined.contains(key)
        {
          if event.audioEnd > minimumSeekAudioStart { postSeekBaselined.insert(key) }
          revisions[key] = .init(words: words, isFinal: event.isFinal, advanced: false)
          seekBaselines[key] = words
          sawFresh = true
          continue
        }
        guard words.starts(with: baseline) else {
          revisions[key] = .init(words: words, isFinal: event.isFinal, advanced: false)
          seekBaselines[key] = words
          sawFresh = true
          continue
        }
        wordsToMatch = Array(words.dropFirst(baseline.count))
      } else if let minimumSeekAudioStart, event.audioStart < minimumSeekAudioStart {
        revisions[key] = .init(words: words, isFinal: event.isFinal, advanced: false)
        seekBaselines[key] = words
        sawFresh = true
        continue
      }
      let appendedWords = old.flatMap { words.starts(with: $0.words) ? Array(words.dropFirst($0.words.count)) : nil }
      let appended = appendedWords.map { $0.count >= matcher.minimumBackwardTokens } ?? false
      revisions[key] = .init(words: words, isFinal: event.isFinal, advanced: old?.advanced ?? false)
      sawFresh = true
      if let match = matcher.match(recognised: wordsToMatch, script: script, currentIndex: tokenIndex),
        !(match.direction == .backward && old?.advanced == true && !appended)
          && !(match.direction == .forward && old?.advanced == true
            && appendedWords?.isEmpty == false
            && appendedWords?.allSatisfy { commonWords.contains($0) } == true
            && match.tokenIndex - tokenIndex > (appendedWords?.count ?? 0))
      {
        candidates.append((event, match))
      }
      if let extended = matcher.forwardExtension(
        words: wordsToMatch, script: script, currentIndex: tokenIndex)
      {
        candidates.append((event, extended))
      }
    }
    guard events.contains(where: { $0.generation == generation }) else {
      return .init(status: .staleGeneration, tokenIndex: tokenIndex)
    }
    guard sawFresh else { return .init(status: .duplicateRevision, tokenIndex: tokenIndex) }
    candidates.sort {
      $0.1.score == $1.1.score ? $0.1.tokenIndex > $1.1.tokenIndex : $0.1.score > $1.1.score
    }
    guard let winner = candidates.first else { return .init(status: .held, tokenIndex: tokenIndex) }
    if winner.1.direction == .forward && winner.1.tokenIndex > tokenIndex {
      let key = "\(winner.0.localeIdentifier)|\(winner.0.replacementID)"
      revisions[key]?.advanced = true
    }
    if winner.0.audioEnd > winner.0.audioStart {
      let range = winner.0.audioStart...winner.0.audioEnd
      if acceptedAudio.contains(where: { existing in
        let overlap = max(
          0, min(existing.upperBound, range.upperBound) - max(existing.lowerBound, range.lowerBound)
        )
        let union =
          max(existing.upperBound, range.upperBound) - min(existing.lowerBound, range.lowerBound)
        return union > 0 && overlap / union >= 0.72
      }) {
        return .init(status: .duplicateRevision, tokenIndex: tokenIndex)
      }
      if winner.0.isFinal { acceptedAudio.append(range) }
    }
    tokenIndex = winner.1.tokenIndex
    return .init(status: .advanced, tokenIndex: tokenIndex)
  }
}
