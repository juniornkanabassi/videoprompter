import Foundation
import PrompterCore
import XCTest

@testable import VideoPrompter

@MainActor final class VoiceFollowFailoverTests: XCTestCase {
  func testLastLiveRecogniserFollowsAReReadAloneAndOnlyAllFailingEndsTheSession() {
    let apple = LiveRecognisers.apple
    let live = LiveRecognisers([0, 1, apple])
    XCTAssertTrue(live.needsAgreement(apple))
    XCTAssertTrue(live.needsAgreement(0))
    XCTAssertFalse(live.fail(0), "One failed model leaves the others following")
    XCTAssertTrue(live.needsAgreement(apple), "Apple still needs the surviving model to agree")
    XCTAssertFalse(live.fail(1))
    XCTAssertFalse(live.needsAgreement(apple), "Apple alone must be able to follow a re-read")
    XCTAssertTrue(live.fail(apple), "Nothing left to follow the reader")
  }

  func testAFailedAppleBackupLeavesTheLocalModelsFollowing() {
    let apple = LiveRecognisers.apple
    let live = LiveRecognisers([0, 1, apple])
    XCTAssertFalse(live.fail(apple), "An Apple failure must not end healthy Parakeet")
    XCTAssertTrue(live.needsAgreement(0))
    XCTAssertFalse(live.fail(1))
    XCTAssertFalse(live.needsAgreement(0))
    let unprepared = LiveRecognisers([0])
    XCTAssertFalse(unprepared.needsAgreement(0), "With no Apple backup one model follows re-reads alone")
  }

  func testRestoringAPositionInsideASpelledOutNumberKeepsTheSavedWord() throws {
    let name = "SpelledRestore.\(UUID())"
    let defaults = try XCTUnwrap(TestDefaults.suite(named: name))
    defer { TestDefaults.remove(name) }
    var settings = PrompterSettings()
    settings.mode = "Manual"
    settings.speechLanguage = "Spanish"
    let record = ScriptRecord(metadata: .init(title: "Año", fileName: "ano.md"), markdown: "Hola en 2024 vamos todos")
    let other = ScriptRecord(metadata: .init(title: "Otro", fileName: "otro.md"), markdown: "otra cosa")
    let session = SessionStore(defaults: defaults)
    session.present(record: record, settings: settings)
    let tokens = session.document.spokenTokens
    let number = tokens.indices.filter { tokens[$0].text == "2024" }
    XCTAssertGreaterThan(number.count, 1, "Spanish reads 2024 as several words")
    let saved = try XCTUnwrap(number.first)
    session.seek(to: saved)
    session.present(record: other, settings: settings)
    session.present(record: record, settings: settings)
    XCTAssertEqual(session.tokenIndex, saved)
    // A fresh store reads the saved position back from the defaults.
    XCTAssertEqual({ let s = SessionStore(defaults: defaults); s.present(record: record, settings: settings); return s.tokenIndex }(), saved)
  }
}
