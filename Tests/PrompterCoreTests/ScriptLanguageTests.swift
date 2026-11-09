import XCTest
import SwiftUI
import Speech
@testable import PrompterCore
@testable import VideoPrompter

final class ScriptLanguageTests: XCTestCase {
  let paragraphs: [(ScriptLanguage, String)] = [
    (.english, "Today we are reading a new story about the people who live near the river and their beautiful village."),
    (.spanish, "Hoy vamos a leer una historia sobre las personas que viven cerca del río y trabajan juntas en este hermoso pueblo."),
    (.french, "Aujourd'hui nous allons lire une histoire sur les personnes qui habitent près de la rivière et travaillent ensemble dans ce beau village."),
    (.german, "Heute lesen wir eine Geschichte über die Menschen, die am Fluss wohnen und gemeinsam in diesem schönen Dorf arbeiten."),
    (.italian, "Oggi leggiamo una storia sulle persone che abitano vicino al fiume e lavorano insieme in questo bellissimo paese."),
    (.dutch, "Vandaag lezen we een verhaal over de mensen die bij de rivier wonen en samen in dit prachtige dorp werken."),
    (.portuguese, "Hoje vamos ler uma história sobre as pessoas que vivem perto do rio e trabalham juntas nesta bela aldeia.")
  ]
  func testDetectionAndFallback() {
    for (language, text) in paragraphs { XCTAssertEqual(ScriptLanguage.detect(text), language, text) }
    for text in ["", "Hola", "12345", "Bonjour mon ami"] { XCTAssertEqual(ScriptLanguage.detect(text), .english) }
  }
  func testRegionalChoice() {
    XCTAssertEqual(ScriptLanguage.spanish.preferredLocale(system: Locale(identifier: "en-MX"), supported: [Locale(identifier: "es-ES"), Locale(identifier: "es-MX")])?.region?.identifier, "MX")
    XCTAssertEqual(ScriptLanguage.spanish.preferredLocale(system: Locale(identifier: "en-GB"), supported: [Locale(identifier: "es-MX"), Locale(identifier: "es-ES")])?.region?.identifier, "ES")
    XCTAssertNil(ScriptLanguage.dutch.preferredLocale(supported: [Locale(identifier: "en-GB")]))
  }
  func testSettingsRoundTrip() throws {
    for choice in ["Automatic"] + ScriptLanguage.allCases.map(\.rawValue) {
      var settings = PrompterSettings()
      settings.speechLanguage = choice
      settings.sanitise()
      let restored = try JSONDecoder().decode(PrompterSettings.self, from: JSONEncoder().encode(settings))
      XCTAssertEqual(restored.speechLanguage, choice)
    }
  }
  @MainActor func testPersistedLanguageSurvivesRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("LanguagePersistence")
    let first = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    for choice in ["Spanish", "Automatic"] {
      first.settings.speechLanguage = choice
      _ = await first.flushPendingSaves()
      let next = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
      XCTAssertEqual(next.settings.speechLanguage, choice)
    }
  }
  func testMatchingAndSourceRanges() {
    let examples: [(ScriptLanguage, String, String)] = [
      (.spanish, "¿Dónde está la información? ¡Aquí está!", "donde esta la informacion aqui esta"),
      (.french, "L’équipe sait qu’elle vient d’ici", "l'equipe sait qu elle vient d ici"),
      (.german, "Die Straße führt über Fußballplätze", "die strasse fuhrt uber fussballplatze"),
      (.portuguese, "A informação da ação está na praça", "a informacao da acao esta na praca"),
      (.dutch, "Wij lezen het mooie verhaal samen", "wij lezen het mooie verhaal samen"),
      (.italian, "L’amico legge una bellissima storia", "l amico legge una bellissima storia")
    ]
    for (language, script, heard) in examples {
      let tokens = PrompterDocument(markdown: script, language: language).spokenTokens
      XCTAssertEqual(tokens.map(\.normalised), PrompterDocument(markdown: heard, language: language).spokenTokens.map(\.normalised))
      var matcher = PhraseMatcher(); matcher.language = language
      XCTAssertEqual(matcher.match(recognised: tokens.map(\.normalised), script: tokens, currentIndex: 0)?.tokenIndex, tokens.count - 1)
      for token in tokens { XCTAssertEqual((script as NSString).substring(with: NSRange(location: token.sourceRange.location, length: token.sourceRange.length)), token.text) }
    }
  }
  func testNumbers() {
    for (language, script, heard) in [(ScriptLanguage.spanish, "Tenemos 21 libros y 5 cartas", "Tenemos veintiuno libros y cinco cartas"), (.french, "Nous avons 21 livres et 5 lettres", "Nous avons vingt et un livres et cinq lettres")] {
      XCTAssertEqual(PrompterDocument(markdown: script, language: language).spokenTokens.map(\.normalised), PrompterDocument(markdown: heard, language: language).spokenTokens.map(\.normalised))
    }
  }
  func testSpanishOfflineReplay() {
    let script = "Hoy estamos aquí para contar una historia sobre nuestro equipo y celebrar juntos esta gran victoria"
    let tokens = PrompterDocument(markdown: script, language: .spanish).spokenTokens
    var matcher = PhraseMatcher(); matcher.language = .spanish
    var tracker = RecognitionTracker(generation: 1, matcher: matcher)
    let words = script.split(separator: " ")
    for end in words.indices {
      let update = tracker.consume(.init(replacementID: "spanish", generation: 1, text: words[...end].joined(separator: " "), isFinal: end == words.count - 1, timestamp: Double(end), localeIdentifier: "es_ES", audioStart: 0, audioEnd: Double(end + 1)), script: tokens)
      XCTAssertLessThanOrEqual(update.tokenIndex, end)
    }
    XCTAssertEqual(tracker.tokenIndex, tokens.count - 1)
  }
  func testLocalSpeechAvailability() async {
    let supported = await DictationTranscriber.supportedLocales
    let installed = await DictationTranscriber.installedLocales
    for language in ScriptLanguage.allCases {
      let locale = language.preferredLocale(supported: supported)
      print("LANGUAGE_AVAILABILITY \(language.rawValue): \(locale?.identifier ?? "unavailable"), on-device supported=\(locale != nil), installed=\(locale.map { installed.contains($0) } ?? false)")
    }
  }
}

@MainActor extension AppearanceSnapshotTests {
  func testLanguageSnapshots() async throws {
    guard let output = ProcessInfo.processInfo.environment["VIDEOPROMPTER_SNAPSHOTS"] else { throw XCTSkip("Opt-in snapshots") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: freshDefaults("ScriptLanguages")))
    _ = try await store.createScript(title: "Historia", markdown: "Hoy vamos a leer una historia sobre las personas que viven cerca del río y trabajan juntas en este hermoso pueblo.")
    for choice in ["Automatic", "Spanish"] {
      store.settings.speechLanguage = choice
      try await snapshot(AppSettingsView(store: store, selectedTab: .reading), name: "script-language-\(choice.lowercased())", size: .init(width: 1100, height: 1000), scheme: .dark, destination: URL(fileURLWithPath: output))
    }
  }
}
