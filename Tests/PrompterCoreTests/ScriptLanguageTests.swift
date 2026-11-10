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
    for locale in installed {
      XCTAssertTrue(supported.contains { $0.language.languageCode == locale.language.languageCode }, "Installed speech must have a supported language")
    }
    for language in ScriptLanguage.allCases {
      let locale = language.preferredLocale(supported: supported)
      XCTAssertEqual(locale != nil, supported.contains { $0.language.languageCode?.identifier == language.code })
      if let locale { XCTAssertTrue(supported.contains(locale)) }
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

extension ScriptLanguageTests {
  func testLanguageMigrationAndExplicitRegions() throws {
    for (raw, expected) in [("Mixed", "Automatic"), ("fr_FR", "French"), ("en-US", "English"), ("ja_JP", "Automatic")] {
      let data = try JSONSerialization.data(withJSONObject: ["speechLanguage": raw])
      let settings = try JSONDecoder().decode(PrompterSettings.self, from: data)
      XCTAssertEqual(settings.speechLanguage, expected)
      if expected != "Automatic" { XCTAssertEqual(settings.speechLocales[expected], raw) }
    }
    XCTAssertEqual(try JSONDecoder().decode(PrompterSettings.self, from: Data("{}".utf8)).speechLanguage, "Automatic")
    let locales = [Locale(identifier: "en-GB"), Locale(identifier: "en-US"), Locale(identifier: "fr-FR"), Locale(identifier: "fr-CA")]
    XCTAssertEqual(ScriptLanguage.english.preferredLocale(system: Locale(identifier: "en-US"), supported: locales)?.identifier, "en-GB")
    XCTAssertEqual(ScriptLanguage.english.preferredLocale(supported: locales, explicit: "en_US")?.identifier, "en-US")
    XCTAssertEqual(ScriptLanguage.french.preferredLocale(supported: locales, explicit: "fr_CA")?.identifier, "fr-CA")
    var settings = PrompterSettings(); settings.speechLanguage = "fr_CA"; settings.sanitise()
    settings.speechLanguage = "English"; settings.sanitise()
    settings = try JSONDecoder().decode(PrompterSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(settings.speechLocales["French"], "fr_CA")
  }

  func testGroupedNumbersAndOneVariants() {
    func words(_ text: String, _ language: ScriptLanguage) -> [String] {
      PrompterDocument(markdown: text, language: language).spokenTokens.map(\.normalised)
    }
    for text in ["1.000", "1 000", "1\u{202f}000"] { XCTAssertEqual(words(text, .spanish), words("1000", .spanish)) }
    for text in ["1 000", "1\u{202f}000", "1\u{00a0}000"] { XCTAssertEqual(words(text, .french), words("mille", .french)) }
    for (language, variants) in [(ScriptLanguage.spanish, ["un", "una"]), (.french, ["un", "une"]), (.italian, ["un", "una"]), (.german, ["ein", "eine"]), (.portuguese, ["um", "uma"]), (.dutch, ["één", "een"])] {
      for variant in variants { XCTAssertEqual(words(variant, language), words("1", language)) }
    }
    XCTAssertEqual(words("abc123", .spanish), ["abc123"])
    XCTAssertEqual(words("l\namour", .french), ["l", "amour"])
    XCTAssertEqual(words("l\tamour", .french), ["l'amour"])
  }

  func testSpanishNumberAnchorPreservesEverySpokenWord() {
    let document = PrompterDocument(markdown: "En 2024 celebramos juntos", language: .spanish)
    for index in document.spokenTokens.indices {
      let anchor = ReadingAnchorRemapper.makeAnchor(scriptID: UUID(), revision: 1, document: document, globalTokenIndex: index)!
      XCTAssertEqual(ReadingAnchorRemapper.globalIndex(of: anchor, in: document), index)
    }
  }

  func testDetectionIgnoresProductionNotes() {
    let french = paragraphs.first { $0.0 == .french }!.1
    let note = String(repeating: "This is an English production note about the camera and the recording. ", count: 30)
    XCTAssertEqual(ScriptLanguage.detect("> [!info] \(note)\n\n\(french)\n[\(note)]\nhttps://example.com/english-production-notes"), .french)
  }

  func testLongSpanishMatchingUsesCachedFillerSets() {
    XCTAssertEqual(ScriptLanguage.commonWordSets.count, ScriptLanguage.allCases.count)
    let spanish = PrompterDocument(markdown: String(repeating: paragraphs[1].1 + " ", count: 100), language: .spanish).spokenTokens
    let english = PrompterDocument(markdown: String(repeating: paragraphs[0].1 + " ", count: 100)).spokenTokens
    func elapsed(_ tokens: [DocumentToken], _ language: ScriptLanguage) -> Double {
      var matcher = PhraseMatcher(); matcher.language = language
      let start = ProcessInfo.processInfo.systemUptime
      for index in stride(from: 0, to: 1000, by: 10) {
        _ = matcher.match(recognised: Array(tokens[index..<index + 8].map(\.normalised)), script: tokens, currentIndex: index)
      }
      return ProcessInfo.processInfo.systemUptime - start
    }
    let baseline = elapsed(english, .english)
    XCTAssertLessThan(elapsed(spanish, .spanish), max(0.1, baseline * 5))
  }

  @MainActor func testControlAcceptsAllLanguagesAndRejectsJapanese() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = freshDefaults("LanguageControl")
    let store = flushedAtTeardown(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults))
    let camera = CameraModel(defaults: defaults)
    let actions = ControlActions(store: store, presenter: PresenterController(camera: camera), camera: camera, recorder: CameraRecorder(defaults: defaults))
    for value in ["automatic"] + ScriptLanguage.allCases.map({ $0.rawValue.lowercased() }) + ["es_ES", "fr_CA", "en-US"] {
      let reply = await actions.handle("settings_set", ["language": value])
      XCTAssertEqual(reply.body["ok"] as? Bool, true, "\(value): \(reply.body)")
      XCTAssertEqual(store.settings.speechLanguage, ScriptLanguage.setting(value))
    }
    let locales = store.settings.speechLocales
    let preset = PrompterSettings()
    store.applyPreset(preset)
    XCTAssertEqual(store.settings.speechLocales, locales)
    XCTAssertTrue(store.matchesPreset(preset))
    for value in ["ja-JP", "ja_JP", "nonsense"] {
      let reply = await actions.handle("settings_set", ["language": value])
      XCTAssertEqual(reply.body["ok"] as? Bool, false)
    }
  }

  @MainActor func testLanguageChangeAndResumeUseSourcePosition() {
    let defaults = freshDefaults("LanguagePosition")
    let record = ScriptRecord(metadata: ScriptMetadata(title: "Numbers", fileName: "numbers.md"), markdown: "En 2024 celebramos juntos al final")
    var spanish = PrompterSettings(); spanish.speechLanguage = "Spanish"; spanish.mode = "Manual"
    let session = SessionStore(defaults: defaults)
    session.present(record: record, settings: spanish)
    session.seek(to: 2)
    var regional = spanish; regional.speechLocales["Spanish"] = "es-MX"
    session.updateSettings(regional)
    XCTAssertEqual(session.tokenIndex, 2, "Changing only the voice region must not jump within a number")
    session.updateSettings(spanish)
    session.seek(to: 0)
    let index = session.document.spokenTokens.firstIndex { $0.text == "juntos" }!
    var now = 0.0
    session.clock = { now }
    session.play(captureAudio: false)
    now = Double(index) / 2
    session.syncManualFrontier(at: now)
    session.pause()
    XCTAssertEqual(session.lastConfirmedTokenIndex, index - 1)
    var english = spanish; english.speechLanguage = "English"
    let relaunched = SessionStore(defaults: defaults)
    relaunched.present(record: record, settings: english)
    XCTAssertEqual(relaunched.activeToken?.text, "juntos")
    session.updateSettings(english)
    XCTAssertEqual(session.activeToken?.text, "juntos")
    XCTAssertLessThan(session.lastConfirmedTokenIndex ?? -1, session.tokenIndex)
    XCTAssertFalse(session.reachedEnd)
    // Old saves have only a token index. They must still decode and resume.
    var saved = try! JSONSerialization.jsonObject(with: defaults.data(forKey: "readingPositions")!) as! [Any]
    for position in saved.indices {
      if var entry = saved[position] as? [String: Any] { entry.removeValue(forKey: "sourceOffset"); saved[position] = entry }
    }
    defaults.set(try! JSONSerialization.data(withJSONObject: saved), forKey: "readingPositions")
    let legacy = SessionStore(defaults: defaults)
    legacy.present(record: record, settings: spanish)
    XCTAssertEqual(legacy.tokenIndex, index)
  }
}
