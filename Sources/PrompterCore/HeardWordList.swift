import Foundation

/// The presenter's personal pronunciation list from Talk & Read: a map from the form a recogniser
/// hears ("Akimi") to the word he means ("Hakimi"). Recognised text is rewritten through it before it
/// reaches the matcher, so a name every engine mishears still moves the script. Read-only: nothing
/// here ever writes the file.
public struct HeardWordList: Sendable {
  private struct Entry: Sendable {
    var heard: [String]
    var intended: String
  }
  private var byFirstWord: [String: [Entry]] = [:]
  private var intended: [(text: String, words: [String])] = []
  /// How many heard forms the list knows.
  public private(set) var count = 0

  public init?(entries: [String: String]) {
    var seen: Set<String> = []
    for (heard, wanted) in entries {
      let heardWords = Self.words(heard), wantedWords = Self.words(wanted)
      guard !heardWords.isEmpty, !wantedWords.isEmpty else { continue }
      byFirstWord[heardWords[0], default: []].append(Entry(heard: heardWords, intended: wanted))
      if seen.insert(wantedWords.joined(separator: " ")).inserted { intended.append((wanted, wantedWords)) }
      count += 1
    }
    guard count > 0 else { return nil }
    // Longest phrase first, so "Ballon Dor" is not cut short by a one-word entry; then by text so
    // the result never depends on dictionary order.
    for key in byFirstWord.keys {
      byFirstWord[key]?.sort { ($0.heard.count, $1.intended) > ($1.heard.count, $0.intended) }
    }
  }

  /// nil when the file is missing, unreadable or not a JSON object of strings (entries that are not
  /// strings are skipped).
  public init?(contentsOf url: URL) {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    self.init(entries: object.compactMapValues { $0 as? String })
  }

  /// Talk & Read's list on the Mac. The iPad cannot see it, so the feature is absent there.
  public static var talkAndReadURL: URL? {
    #if os(macOS)
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Talk and Read/vocabulary.json")
    #else
    nil
    #endif
  }

  /// Case-, accent- and punctuation-insensitive words, the form both sides are compared in.
  private static func fold(_ word: String) -> String {
    PrompterDocument.normalise(word).filter { $0.isLetter || $0.isNumber }
  }
  private static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
  }

  /// `text` with each heard form replaced by the word he means: whole words only, longest phrase
  /// first. A heard form whose words all occur in `script` is left alone, because the script then
  /// really contains it. Punctuation on a replaced run is dropped, which the matcher ignores anyway.
  public func rewrite(_ text: String, avoiding script: Set<String> = []) -> String {
    let original = text.split(whereSeparator: \.isWhitespace).map(String.init)
    let folded = original.map(Self.fold)
    var out: [String] = []
    var changed = false
    var i = 0
    while i < original.count {
      if !folded[i].isEmpty,
        let hit = byFirstWord[folded[i]]?.first(where: { entry in
          i + entry.heard.count <= folded.count && Array(folded[i..<i + entry.heard.count]) == entry.heard
            && !entry.heard.allSatisfy(script.contains)
        })
      {
        out.append(hit.intended)
        i += hit.heard.count
        changed = true
      } else {
        out.append(original[i])
        i += 1
      }
    }
    return changed ? out.joined(separator: " ") : text
  }

  /// The set `rewrite(_:avoiding:)` expects for a script.
  public static func scriptWords(_ script: [DocumentToken]) -> Set<String> {
    Set(script.map { fold($0.normalised) }.filter { !$0.isEmpty })
  }

  /// Intended words and names that actually occur in `script`, nearest to `index` first (the script
  /// wraps round), for the recogniser's contextual strings.
  public func contextualPhrases(in script: [DocumentToken], at index: Int = 0, limit: Int = 25) -> [String] {
    let folded = script.map { Self.fold($0.normalised) }
    var positions: [String: [Int]] = [:]
    for (i, word) in folded.enumerated() where !word.isEmpty { positions[word, default: []].append(i) }
    var found: [(distance: Int, text: String)] = []
    for item in intended {
      let distances = (positions[item.words[0]] ?? []).filter {
        $0 + item.words.count <= folded.count && Array(folded[$0..<$0 + item.words.count]) == item.words
      }.map { $0 >= index ? $0 - index : $0 + folded.count }
      if let nearest = distances.min() { found.append((nearest, item.text)) }
    }
    return found.sorted { ($0.distance, $0.text) < ($1.distance, $1.text) }.prefix(limit).map(\.text)
  }

  /// `rolling` with the script's intended words in front, within Apple's 100 contextual strings.
  public func addingContext(to rolling: [String], script: [DocumentToken], at index: Int) -> [String] {
    let names = contextualPhrases(in: script, at: index)
    return Array((names + rolling.filter { !names.contains($0) }).prefix(100))
  }
}
