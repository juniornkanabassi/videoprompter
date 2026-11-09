import Foundation
import NaturalLanguage

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
  public func preferredLocale(system: Locale = .current, supported: [Locale]) -> Locale? {
    let matching = supported.filter { $0.language.languageCode?.identifier == code }
    return matching.first { $0.region == system.region }
      ?? matching.first { $0.region == defaultLocale.region }
      ?? matching.sorted { $0.identifier < $1.identifier }.first
  }
  public static func resolve(_ setting: String, text: String) -> ScriptLanguage {
    if let manual = Self(rawValue: setting) { return manual }
    if setting != "Automatic", setting != "Mixed",
      let manual = allCases.first(where: { $0.code == Locale(identifier: setting).language.languageCode?.identifier }) { return manual }
    return detect(text)
  }
  public static func detect(_ text: String) -> ScriptLanguage {
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
  public var commonWords: Set<String> {
    let words: String = switch self {
    case .english: ""
    case .spanish: "el la los las un una de del y que en por para es con se su al"
    case .french: "le la les un une de des du et que qui en pour est avec l d qu"
    case .german: "der die das ein eine und in im zu von mit ist es den dem"
    case .italian: "il lo la gli le un una di del e che in per con è l d"
    case .dutch: "de het een en van in op voor met is dat die"
    case .portuguese: "o a os as um uma de do da e que em para por com é"
    }
    return Set(words.split(separator: " ").map { PrompterDocument.normalise(String($0)) })
  }
}
