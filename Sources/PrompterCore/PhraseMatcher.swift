import Foundation

private let commonWords: Set<String> = [
  "the", "and", "that", "this", "with", "from", "have", "your", "you", "for", "are", "was",
  "but", "because", "not", "une", "les", "des", "dans", "pour", "est", "que", "qui",
]

/// Numbers as dictation may write them where a script has digits, or the reverse: every single-word
/// spelling from zero to ninety-nine ("five", "twenty", not "twenty-one", which is two words), and
/// the first three ordinals.
private let spelledNumbers: [String: String] = {
  let formatter = NumberFormatter()
  formatter.numberStyle = .spellOut
  formatter.locale = Locale(identifier: "en_GB")
  var table = ["first": "1st", "second": "2nd", "third": "3rd"]
  for number in 0...99 {
    if let word = formatter.string(from: number as NSNumber), word.allSatisfy(\.isLetter) { table[word] = "\(number)" }
  }
  return table
}()

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
      let (word, index, _) = follow(words, from: source, along: target, at: start)
      guard word == words.count, index > start,
        target[start..<index].contains(where: continues)
      else { continue }
      // Below 1 so a proper match always outranks a fresh tail, and never on filler alone:
      // a trailing "and" or "the" would otherwise win every candidate sort on its own.
      return PhraseMatch(tokenIndex: index - 1, score: 0.99, direction: .forward)
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
      let (source, targetIndex, informative) = follow(words, from: wordStart, along: target, at: start)
      let sourceCount = source - wordStart
      let rest = words[source...]
      // The run has to sit at the reader's frontier, so no more of the revision may be left
      // unexplained after it than the run itself covers. Without that, any interior window could
      // be credited: on a script that repeats a phrase, the "a better Champions League player
      // than" he had spoken a paragraph earlier matched the same phrase ahead of him and dimmed
      // six words he had not reached, while the eleven words he had actually said since were
      // ignored. A misrecognised tail is short, so this still credits the nearest continuation; but
      // a longer one must name a word of what follows, or it is speech after an older copy of the
      // run: "in the Champions League and you in" (he had said "... fewer minutes in") dimmed the
      // repeat's "League" before he said it.
      let next = target[targetIndex..<min(target.count, targetIndex + rest.count + 2)]
      if rest.count <= sourceCount, sourceCount >= 3, informative >= 2,
        rest.count < 2 || rest.contains(where: { continues($0) && next.contains($0) })
      {
        return PhraseMatch(tokenIndex: targetIndex - 1, score: 1, direction: .forward)
      }
    }
    return nil
  }
  private func forwardMatch(words spoken: [String], script: [DocumentToken], current: Int) -> PhraseMatch? {
    // Compared by key, so the inner loop stays a plain string comparison.
    let target = script.map { key($0.normalised) }
    let words = spoken.map(key)
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
        var leadingInformative = 0
        var leadingIntact = true
        // After a skip of eight or more words inside the phrase, the run that resumes there.
        var landing: (informative: Int, intact: Bool)?
        for word in evidence {
          let before = ti
          while ti < hi && target[ti] != word { ti += 1 }
          if ti < hi {
            let informative = word.count > 2 && !common.contains(word) ? 1 : 0
            leadingIntact = leadingIntact && ti == before
            if leadingIntact { leadingInformative += informative }
            if ti - max(before, current + 1) >= 8 { landing = (0, true) } else if ti != before { landing?.intact = false }
            if landing?.intact == true { landing?.informative += informative }
            matched += 1
            last = ti
            ti += 1
            trailingMatches = ti - before == 1 ? trailingMatches + 1 : 1
          } else {
            // A word that appears nowhere ahead is a misrecognition, not the end of the phrase.
            // Leaving the scan at the window's end discarded every word after it, so one wrong
            // word ("point" for "points") stranded the rest of a sentence. The run is broken all
            // the same, so the contiguity counter starts again.
            ti = before
            trailingMatches = 0
            leadingIntact = false
            landing?.intact = false
          }
        }
        let coverage = Double(matched) / Double(evidence.count)
        let gaps = Double(max(0, last - start + 1 - matched))
        // Skipping eight or more words he has not been heard saying takes an unbroken run of at least
        // three informative words where the match lands, before the phrase or inside it. On weaker
        // evidence a phrase said here ("their defence", "argue that Barcelona", "you still") was
        // credited to the same words a paragraph ahead and dimmed everything in between. A shorter
        // skip keeps the looser rules: that is the recogniser dropping or garbling a word or two.
        if start > current + 8, leadingInformative < 3 { continue }
        if let landing, landing.informative < 3 { continue }
        // A lone word after a gap is weak evidence wherever the phrase starts: "ties that ... they"
        // credited the "they" four words on, over the "knocked them out" he had not said.
        guard gaps == 0 || trailingMatches >= 2 || last <= current + 1 else { continue }
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
  /// Word-onset credit. A live hypothesis often ends on the start of the word being spoken ("a better
  /// champ"), a few hundred milliseconds before the recogniser commits to the whole word. When the
  /// words before that fragment end exactly where the reader already is (or continue the script from
  /// there, as `forwardExtension` credits), and the fragment is the first three or more letters of
  /// the very next script word, that word is dimmed now.
  ///
  /// Only the next word is ever considered, so nothing is skipped and nothing moves back. A fragment
  /// that is a whole common word ("the" before "these") or that begins a common word proves nothing
  /// and is refused, as is a fragment with no anchoring words before it.
  public func onsetCredit(words: [String], script: [DocumentToken], currentIndex: Int) -> PhraseMatch? {
    let target = script.map(\.normalised)
    guard let fragment = words.last, words.count >= 2, target.indices.contains(currentIndex) else { return nil }
    let head = Array(words.dropLast())
    let reached: Int
    if head.count >= 2, endsOn(head.suffix(2), target: target, through: currentIndex) {
      reached = currentIndex
    } else if let run = forwardExtension(words: head, script: script, currentIndex: currentIndex) {
      reached = run.tokenIndex
    } else {
      return nil
    }
    let next = reached + 1
    guard next < target.count, fragment.count >= 3, fragment != target[next],
      target[next].hasPrefix(fragment), !common.contains(target[next]),
      !common.contains(where: { $0.hasPrefix(fragment) })
    else { return nil }
    return PhraseMatch(tokenIndex: next, score: 0.98, direction: .forward)
  }
  /// Whether `words` are exactly the script tokens ending at `through`.
  private func endsOn(_ words: ArraySlice<String>, target: [String], through: Int) -> Bool {
    var end = through + 1
    for word in words.reversed() {
      if end >= 1, same(word, target[end - 1]) {
        end -= 1
        continue
      }
      let expanded = contractionComponents(word)
      guard expanded.count > 1, end >= expanded.count,
        Array(target[(end - expanded.count)..<end]) == expanded
      else { return false }
      end -= expanded.count
    }
    return true
  }
  /// Follows `words` from `source` along the script from `index` while each word continues it. A
  /// reader leaves a word out ("saying [that] he's a better") and the recogniser drops one ("G/A"
  /// heard as "G"), which stranded the whole continuation, so one script word may be stepped over,
  /// once, when at least two recognised words carry on after it (with only one, a false start,
  /// "defender in 2024" before "defender in the 2024", dimmed the "the" too early). Stepping over
  /// the very next word also needs the two words heard before the run to end where he is, or an
  /// already credited "I'm not saying" skips "saying" onto the "I am not saying" after it.
  private func follow(_ words: [String], from source: Int, along target: [String], at start: Int)
    -> (word: Int, index: Int, informative: Int)
  {
    let anchored = source >= 2 && endsOn(words[(source - 2)..<source], target: target, through: start - 1)
    var word = source, index = start, informative = 0
    var skip: (word: Int, index: Int, informative: Int)?
    while word < words.count {
      var covered = coverage(of: words[word], in: target, at: index)
      if covered == nil, skip == nil, word > source || anchored,
        let next = coverage(of: words[word], in: target, at: index + 1)
      {
        skip = (word, index, informative)
        index += 1
        covered = next
      }
      guard let covered else { break }
      informative += target[index..<index + covered].filter(continues).count
      index += covered
      word += 1
    }
    if let skip, word - skip.word < 2 { return skip }
    return (word, index, informative)
  }
  /// Whether a script word, heard right where the reader is, is evidence he is saying it: an
  /// informative word or a number. Numbers count only here, next to the reader: "from an xG of 5.4
  /// and" is all short words, filler and digits, and stayed bright until "put". Far from the reader
  /// they prove nothing, because a script repeats its figures ("2.88", "2024-25").
  private func continues(_ word: String) -> Bool {
    word.count > 2 && !common.contains(word) || word.contains(where: \.isNumber)
  }
  /// How many script tokens a recognised word covers at `index`: itself, or for a contraction the
  /// words it stands for ("I'm" continues a script's "I'm" as well as its "I am"), or none for the
  /// "percent" dictation may add after a script's "35%".
  private func coverage(of word: String, in target: [String], at index: Int) -> Int? {
    guard index < target.count else { return nil }
    if same(word, target[index]) { return 1 }
    if word == "percent", index > 0, target[index - 1].allSatisfy(\.isNumber) { return 0 }
    let expanded = contractionComponents(word)
    return expanded.count > 1 && target[index...].starts(with: expanded) ? expanded.count : nil
  }
  /// The form words are compared in: a spelled number is its digits ("five" is "5", "second" is
  /// "2nd"), so dictation and the script match whichever way each writes it. Without it every
  /// "five" against a "5" broke the run.
  private func key(_ word: String) -> String { spelledNumbers[word] ?? word }
  /// Whether a recognised word next to the reader is this script token: the same key, or a year
  /// for its short form ("2025" for the "25" of "2024-25").
  private func same(_ word: String, _ token: String) -> Bool {
    key(word) == key(token)
      || word.count == 4 && token.count == 2 && word.hasSuffix(token) && word.allSatisfy(\.isNumber)
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
  public mutating func reanchor(to index: Int, minimumAudioStart: TimeInterval) {
    tokenIndex = max(0, index)
    acceptedAudio.removeAll()
    minimumSeekAudioStart = minimumAudioStart
    postSeekBaselined.removeAll()
    seekBaselines = revisions.mapValues(\.words)
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
      if let onset = matcher.onsetCredit(words: wordsToMatch, script: script, currentIndex: tokenIndex) {
        candidates.append((event, onset))
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
