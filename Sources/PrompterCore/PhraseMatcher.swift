import Foundation

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
  public func match(recognised: [String], script: [DocumentToken], currentIndex: Int)
    -> PhraseMatch?
  {
    let words = recognised.map(PrompterDocument.normalise).filter { !$0.isEmpty }
    let target = script.map(\.normalised)
    guard !words.isEmpty && !target.isEmpty else { return nil }
    let current = min(max(0, currentIndex), target.count - 1)
    let common: Set<String> = [
      "the", "and", "that", "this", "with", "from", "have", "your", "you", "for", "are", "was",
      "but", "not", "une", "les", "des", "dans", "pour", "est", "que", "qui",
    ]
    if words.count >= minimumBackwardTokens {
      let phrase = Array(words.suffix(min(words.count, 10)))
      let informative = phrase.filter { $0.count > 2 && !common.contains($0) }
      guard informative.count >= minimumBackwardTokens else {
        return forwardMatch(words: words, target: target, current: current)
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
    return forwardMatch(words: words, target: target, current: current)
  }
  private func forwardMatch(words: [String], target: [String], current: Int) -> PhraseMatch? {
    let lo = max(0, current - backwardWindow)
    let hi = min(target.count, current + forwardWindow + 1)
    var destinationScores: [Int: Double] = [:]
    for recognisedStart in 0..<words.count {
      let evidence = Array(words[recognisedStart...])
      guard evidence.count >= min(2, words.count) else { continue }
      for start in lo..<hi where target[start] == evidence[0] {
        var ti = start
        var matched = 0
        var last = start
        for word in evidence {
          while ti < hi && target[ti] != word { ti += 1 }
          if ti < hi {
            matched += 1
            last = ti
            ti += 1
          }
        }
        let coverage = Double(matched) / Double(evidence.count)
        let gaps = Double(max(0, last - start + 1 - matched))
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
}

public struct RecognitionUpdate: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case advanced, held, staleGeneration, duplicateRevision
  }
  public var status: Status
  public var tokenIndex: Int
}
public struct RecognitionTracker: Sendable {
  public private(set) var generation: UInt64
  public private(set) var tokenIndex: Int
  private var revisions: [String: (String, Bool)] = [:]
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
    acceptedAudio.removeAll()
    if let index { tokenIndex = max(0, index) }
  }
  public mutating func seek(to index: Int) {
    tokenIndex = max(0, index)
    invalidate(startingAt: tokenIndex)
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
      let signature = (event.text, event.isFinal)
      if let old = revisions[key], old.0 == signature.0 && old.1 == signature.1 { continue }
      revisions[key] = signature
      sawFresh = true
      let words = PrompterDocument(markdown: event.text).spokenTokens.map(\.normalised)
      if let match = matcher.match(recognised: words, script: script, currentIndex: tokenIndex) {
        candidates.append((event, match))
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
