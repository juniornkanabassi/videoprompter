import PrompterCore
import XCTest
@testable import VideoPrompter

final class HeardWordListTests: XCTestCase {
  private let list = HeardWordList(entries: [
    "Akimi": "Hakimi", "Athletico": "Atlético", "Balandur": "Ballon d'Or", "Ballon Dor": "Ballon d'Or",
    "ATM vertical": "Aitum Vertical", "ATM": "ATEM", "Brugge": "Brugge",
  ])!

  func testRewritesCaseAccentAndPunctuationInsensitively() {
    XCTAssertEqual(list.rewrite("so AKIMI, again"), "so Hakimi again")
    XCTAssertEqual(list.rewrite("atlétiço athletico"), "atlétiço Atlético")
  }
  func testMultiWordAndLongestFirst() {
    XCTAssertEqual(list.rewrite("use ATM vertical now"), "use Aitum Vertical now")
    XCTAssertEqual(list.rewrite("the ATM now"), "the ATEM now")
    XCTAssertEqual(list.rewrite("a Ballon Dor win"), "a Ballon d'Or win")
  }
  func testNoPartialWordReplacement() {
    XCTAssertEqual(list.rewrite("Akimis and xAkimi"), "Akimis and xAkimi")
  }
  func testHeardFormAlreadyInScriptIsLeftAlone() {
    XCTAssertEqual(list.rewrite("the ATM", avoiding: ["atm"]), "the ATM")
  }
  func testMissingOrInvalidFileIsNil() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heard-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertNil(HeardWordList(contentsOf: dir.appendingPathComponent("missing.json")))
    let bad = dir.appendingPathComponent("bad.json")
    try Data("[1, 2".utf8).write(to: bad)
    XCTAssertNil(HeardWordList(contentsOf: bad))
    let good = dir.appendingPathComponent("vocabulary.json")
    try Data(#"{"Akimi": "Hakimi", "Bad": 3}"#.utf8).write(to: good)
    XCTAssertEqual(HeardWordList(contentsOf: good)?.count, 1)
  }
  func testContextOnlyHasWordsInTheScript() {
    let script = PrompterDocument(markdown: "Then Hakimi won the Ballon d'Or in Brugge.").spokenTokens
    XCTAssertEqual(list.contextualPhrases(in: script), ["Hakimi", "Ballon d'Or", "Brugge"])
    XCTAssertEqual(list.contextualPhrases(in: script, at: 3), ["Ballon d'Or", "Brugge", "Hakimi"])
    XCTAssertEqual(list.contextualPhrases(in: script, limit: 1), ["Hakimi"])
    XCTAssertEqual(list.addingContext(to: ["Then", "Hakimi"], script: script, at: 0).prefix(4), ["Hakimi", "Ballon d'Or", "Brugge", "Then"])
  }
  func testMatcherAdvancesOnTheIntendedWord() {
    let script = PrompterDocument(markdown: "Tonight Hakimi crossed the ball into the box").spokenTokens
    func advance(_ words: HeardWordList?) -> Int {
      var matcher = PhraseMatcher()
      matcher.heardWords = words
      var tracker = RecognitionTracker(tokenIndex: 0, matcher: matcher)
      let event = RecognitionEvent(replacementID: "1", generation: 0, text: "Akimi", isFinal: false, timestamp: 1)
      return tracker.consume(event, script: script).tokenIndex
    }
    XCTAssertEqual(advance(list), 1)
    XCTAssertEqual(advance(nil), 0)
  }
  func testSettingsDefaultOnForOlderSettings() throws {
    XCTAssertTrue(try JSONDecoder().decode(PrompterSettings.self, from: Data("{\"fontSize\":40}".utf8)).usesTalkAndReadWords)
    var off = PrompterSettings()
    off.usesTalkAndReadWords = false
    XCTAssertFalse(try JSONDecoder().decode(PrompterSettings.self, from: JSONEncoder().encode(off)).usesTalkAndReadWords)
  }
}
