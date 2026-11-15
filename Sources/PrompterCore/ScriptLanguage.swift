import Foundation
import NaturalLanguage
import Synchronization

public enum ScriptLanguage: String, CaseIterable, Codable, Sendable {
  case english = "English", spanish = "Spanish", french = "French", german = "German"
  case italian = "Italian", dutch = "Dutch", portuguese = "Portuguese"

  public var code: String {
    switch self {
    case .english: "en"
    case .spanish: "es"
    case .french: "fr"
    case .german: "de"
    case .italian: "it"
    case .dutch: "nl"
    case .portuguese: "pt"
    }
  }
  public var label: String {
    switch self {
    case .english: "English"
    case .spanish: "Español (Spanish)"
    case .french: "Français (French)"
    case .german: "Deutsch (German)"
    case .italian: "Italiano (Italian)"
    case .dutch: "Nederlands (Dutch)"
    case .portuguese: "Português (Portuguese)"
    }
  }
  public var defaultLocale: Locale {
    let region: String = switch self {
    case .english: "GB"
    case .spanish: "ES"
    case .french: "FR"
    case .german: "DE"
    case .italian: "IT"
    case .dutch: "NL"
    case .portuguese: "PT"
    }
    return Locale(identifier: "\(code)-\(region)")
  }
  public func preferredLocale(system: Locale = .current, supported: [Locale], explicit: String? = nil) -> Locale? {
    let matching = supported.filter { $0.language.languageCode?.identifier == code }
    if let explicit, let saved = matching.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == explicit.replacingOccurrences(of: "_", with: "-").lowercased() }) { return saved }
    if self == .english { return matching.first { $0.region == defaultLocale.region } }
    return matching.first { $0.region == system.region }
      ?? matching.first { $0.region == defaultLocale.region }
      ?? matching.sorted { $0.identifier < $1.identifier }.first
  }
  /// The CLI and saved-settings migration use exactly the same accepted language set.
  public static func setting(_ value: String) -> String? {
    if ["automatic", "mixed"].contains(value.lowercased()) { return "Automatic" }
    if let named = allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) { return named.rawValue }
    guard InputValidation.language(value) != "Automatic" else { return nil }
    return allCases.first { $0.code == Locale(identifier: value).language.languageCode?.identifier }?.rawValue
  }
  public static func resolve(_ setting: String, text: String) -> ScriptLanguage {
    if let name = Self.setting(setting), let manual = Self(rawValue: name) { return manual }
    return detect(text)
  }
  /// A sample's language, or nil for a sample with too little speech, which is read further.
  private static let detections = Mutex<[String: ScriptLanguage?]>([:])
  /// Detection reads only the start of a script: 4,000 characters is hundreds of words, plenty to
  /// tell the language, and edits further down then cost nothing (the cache key is the sample).
  /// A start that is mostly notes (a long callout) is read further, until half of that is speech.
  static let detectionSampleLimit = 4_000
  static var detectionCacheCount: Int { detections.withLock { $0.count } }
  public static func detect(_ markdown: String) -> ScriptLanguage {
    var limit = detectionSampleLimit
    while true {
      let end = markdown.index(markdown.startIndex, offsetBy: limit, limitedBy: markdown.endIndex) ?? markdown.endIndex
      let sample = String(markdown[..<end])
      // A whole script and an unfinished prefix with the same text must not share an entry.
      let key = (end == markdown.endIndex ? "=" : "+") + sample
      let found: ScriptLanguage?? = detections.withLock { cache in
        if let cached = cache[key] { return cached }
        let spoken = PrompterDocument(markdown: sample).spokenTokens.map(\.text).joined(separator: " ")
        if cache.count >= 8 { cache.removeAll(keepingCapacity: true) }
        if end != markdown.endIndex, spoken.count < detectionSampleLimit / 2 {
          cache.updateValue(nil, forKey: key)
          return .some(nil)
        }
        let result = detectSpoken(spoken)
        cache[key] = result
        return result
      }
      if case .some(.some(let language)) = found { return language }
      limit *= 2
    }
  }
  private static func detectSpoken(_ text: String) -> ScriptLanguage {
    let words = text.split { !$0.isLetter }
    guard words.count >= 6, text.filter(\.isLetter).count >= 30 else { return .english }
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = allCases.map { NLLanguage(rawValue: $0.code) }
    recognizer.processString(text)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 7).sorted { $0.value > $1.value }
    guard let best = hypotheses.first, best.value >= 0.65,
      best.value - (hypotheses.dropFirst().first?.value ?? 0) >= 0.2 else { return .english }
    return allCases.first { $0.code == best.key.rawValue } ?? .english
  }
  public func spellOut(_ number: String) -> String? {
    guard number.allSatisfy(\.isNumber), number.count <= 12, let value = Int64(number) else { return nil }
    let formatter = NumberFormatter()
    formatter.numberStyle = .spellOut
    formatter.locale = defaultLocale
    return formatter.string(from: NSNumber(value: value))
  }
  static let commonWordSets: [ScriptLanguage: Set<String>] = Dictionary(uniqueKeysWithValues: allCases.map { language in
    let words: String = switch language {
    case .english: ""
    case .spanish: "el la los las un una de del y que en por para es con se su al"
    case .french: "le la les un une de des du et que qui en pour est avec l d qu"
    case .german: "der die das ein eine und in im zu von mit ist es den dem"
    case .italian: "il lo la gli le un una di del e che in per con è l d"
    case .dutch: "de het een en van in op voor met is dat die"
    case .portuguese: "o a os as um uma de do da e que em para por com é"
    }
    return (language, Set(words.split(separator: " ").map { PrompterDocument.normalise(String($0)) }))
  })
  public var commonWords: Set<String> { Self.commonWordSets[self]! }
  private static let ones: [ScriptLanguage: Set<String>] = [.spanish: ["un", "una", "uno"], .italian: ["un", "una", "uno"], .french: ["un", "une"], .portuguese: ["um", "uma"], .german: ["ein", "eine", "eins"], .dutch: ["een"]]
  public func normaliseWord(_ word: String) -> String {
    let folded = PrompterDocument.normalise(word)
    if Self.ones[self]?.contains(folded) == true { return "1" }
    return folded
  }
}
