import XCTest

@testable import PrompterCore

final class DocumentAndAnchorTests: XCTestCase {
  func testMarkdownMappingCuesLinksEscapesAndUnicode() {
    let markdown =
      "# Hé 👋🏽 world\n\n[LOOK LEFT] Visit [Café PSG](https://example.test) and \\[say this]."
    let document = PrompterDocument(markdown: markdown)
    XCTAssertEqual(document.blocks.map(\.kind), [.heading, .paragraph])
    XCTAssertEqual(document.blocks[1].stageDirections.map(\.text), ["LOOK LEFT"])
    XCTAssertEqual(
      document.spokenTokens.map(\.text),
      ["Hé", "world", "Visit", "Café", "PSG", "and", "say", "this"])
    let cafe = try! XCTUnwrap(document.spokenTokens.first { $0.text == "Café" })
    XCTAssertEqual(
      (markdown as NSString).substring(
        with: NSRange(location: cafe.sourceRange.location, length: cafe.sourceRange.length)), "Café"
    )
  }

  func testEditedBlockKeepsIdentityAndAnchor() throws {
    let id = UUID()
    let old = PrompterDocument(
      markdown: "Opening words.\n\nThe crucial passage stays right here.\n\nEnding.")
    let anchor = try XCTUnwrap(
      ReadingAnchorRemapper.makeAnchor(
        scriptID: id, revision: 1, document: old, globalTokenIndex: 5, guideFraction: 0.61))
    let new = PrompterDocument(
      markdown: "New intro.\n\nThe crucial amended passage stays right here.\n\nEnding.",
      previous: old)
    let result = ReadingAnchorRemapper.remap(anchor, from: old, to: new, newRevision: 2)
    XCTAssertNotNil(result.anchor)
    XCTAssertEqual(result.anchor?.guideFraction, 0.61)
    XCTAssertNotEqual(result.disposition, .documentEmpty)
    let mapped = try XCTUnwrap(
      result.anchor.flatMap { ReadingAnchorRemapper.globalIndex(of: $0, in: new) })
    XCTAssertTrue((2...7).contains(mapped))
  }

  func testDeletingCurrentPassageMovesNearbyAndReportsIt() throws {
    let id = UUID()
    let old = PrompterDocument(
      markdown: "alpha beta gamma\n\nremove all of this passage\n\nomega final")
    let anchor = try XCTUnwrap(
      ReadingAnchorRemapper.makeAnchor(
        scriptID: id, revision: 1, document: old, globalTokenIndex: 5))
    let new = PrompterDocument(markdown: "alpha beta gamma\n\nomega final", previous: old)
    let result = ReadingAnchorRemapper.remap(anchor, from: old, to: new, newRevision: 2)
    XCTAssertEqual(result.disposition, .currentPassageDeleted)
    XCTAssertNotNil(result.anchor)
  }
  func testInsertionBeforeAnchorKeepsTheSameWord() throws {
    let id = UUID()
    let old = PrompterDocument(markdown: "alpha beta target delta epsilon")
    let anchor = try XCTUnwrap(
      ReadingAnchorRemapper.makeAnchor(
        scriptID: id, revision: 1, document: old, globalTokenIndex: 2))
    let new = PrompterDocument(
      markdown: "new opening alpha beta target delta epsilon", previous: old)
    let result = ReadingAnchorRemapper.remap(anchor, from: old, to: new, newRevision: 2)
    let mapped = try XCTUnwrap(
      result.anchor.flatMap { ReadingAnchorRemapper.globalIndex(of: $0, in: new) })
    XCTAssertEqual(new.spokenTokens[mapped].text, "target")
  }
  func testLongEditUsesBoundedMemoryAndKeepsAnchor() throws {
    let words = (0..<10_000).map { "word\($0)" }
    let id = UUID()
    let old = PrompterDocument(markdown: words.joined(separator: " "))
    let anchor = try XCTUnwrap(
      ReadingAnchorRemapper.makeAnchor(
        scriptID: id, revision: 1, document: old, globalTokenIndex: 8_000))
    let new = PrompterDocument(
      markdown: (["inserted"] + words).joined(separator: " "), previous: old)
    let result = ReadingAnchorRemapper.remap(anchor, from: old, to: new, newRevision: 2)
    let mapped = try XCTUnwrap(
      result.anchor.flatMap { ReadingAnchorRemapper.globalIndex(of: $0, in: new) })
    XCTAssertEqual(new.spokenTokens[mapped].text, "word8000")
  }
}

final class RecognitionTests: XCTestCase {
  func testOrderedForwardMatchRejectsBagOfWordsAndAmbiguousSingleWord() {
    let script = PrompterDocument(
      markdown: "we begin in Paris today and then close\n\nParis appears once more"
    ).spokenTokens
    let matcher = PhraseMatcher()
    XCTAssertNil(
      matcher.match(recognised: ["today", "Paris", "begin"], script: script, currentIndex: 0))
    XCTAssertNil(matcher.match(recognised: ["Paris"], script: script, currentIndex: 0))
    XCTAssertEqual(
      matcher.match(
        recognised: ["begin", "in", "Paris", "today"], script: script, currentIndex: 0)?.tokenIndex,
      4)
  }

  func testBackwardRequiresUniqueContiguousMultiwordEvidence() {
    let script = PrompterDocument(
      markdown:
        "one unmistakable earlier phrase lives here then lots of later script words continue onward"
    ).spokenTokens
    let matcher = PhraseMatcher(minimumBackwardTokens: 4)
    XCTAssertNil(matcher.match(recognised: ["earlier"], script: script, currentIndex: 10))
    let match = matcher.match(
      recognised: ["unmistakable", "earlier", "phrase", "lives"], script: script, currentIndex: 10)
    XCTAssertEqual(match?.direction, .backward)
    XCTAssertEqual(match?.tokenIndex, 4)
  }

  func testRepeatedBackwardPhraseIsAmbiguous() {
    let script = PrompterDocument(
      markdown: "the same four word phrase now filler filler the same four word phrase now ending"
    ).spokenTokens
    XCTAssertNil(
      PhraseMatcher().match(
        recognised: ["same", "four", "word", "phrase"], script: script, currentIndex: 12))
  }
  func testPhraseStartingBehindButEndingAheadIsForward() {
    let script = PrompterDocument(markdown: "alpha beta gamma delta epsilon zeta eta theta")
      .spokenTokens
    let match = PhraseMatcher().match(
      recognised: script.map(\.normalised), script: script, currentIndex: 3)
    XCTAssertEqual(match?.direction, .forward)
    XCTAssertEqual(match?.tokenIndex, 7)
  }
  func testCommonFourWordPhraseCannotRewind() {
    let script = PrompterDocument(
      markdown: "the and this that meaningful middle passage continues onward"
    ).spokenTokens
    XCTAssertNil(
      PhraseMatcher().match(
        recognised: ["the", "and", "this", "that"], script: script, currentIndex: 8))
  }

  func testLocalAnchorAdvancesBeforeAContractionBreaksTheLongInterim() {
    let script = PrompterDocument(
      markdown: "I am not saying he is a better player than Yamal. I am simply saying that he is a better Champions League player."
    ).spokenTokens
    let current = try! XCTUnwrap(script.firstIndex { $0.normalised == "yamal" })
    let match = PhraseMatcher().match(
      recognised: ["I'm", "simply", "saying", "he's", "a", "better"],
      script: script, currentIndex: current)
    XCTAssertEqual(
      match?.tokenIndex,
      script.indices.first { $0 > current && script[$0].normalised == "saying" })
  }

  func testZeroLookaheadLocalAnchorDoesNotSkipAnUnmatchedName() {
    let script = PrompterDocument(
      markdown: "Start Désiré Doué is a better Champions League player."
    ).spokenTokens
    XCTAssertNil(
      PhraseMatcher(forwardWindow: 0).match(
        recognised: ["is", "a", "better", "Champions", "League", "player"],
        script: script, currentIndex: 0))
  }

  func testLocalAnchorRejectsCommonAndUnrelatedPhrases() {
    let common = PrompterDocument(markdown: "Start the and this that follows.").spokenTokens
    XCTAssertNil(
      PhraseMatcher().match(recognised: ["the", "and", "this", "that"], script: common, currentIndex: 0))
    let unrelated = PrompterDocument(
      markdown: "Start Désiré Doué. I am simply saying that he is right."
    ).spokenTokens
    XCTAssertNil(
      PhraseMatcher(forwardWindow: 0).match(
        recognised: ["I", "am", "simply", "saying"], script: unrelated, currentIndex: 0))
  }

  func testLocalAnchorAcceptsCapitalisedSentenceAndHeading() {
    let sentence = PrompterDocument(markdown: "Start. This Sentence Continues.").spokenTokens
    XCTAssertEqual(
      PhraseMatcher().match(
        recognised: ["This", "Sentence", "Continues"], script: sentence, currentIndex: 0)?.tokenIndex,
      3)
    let heading = PrompterDocument(markdown: "Start\n\n# This Heading Continues").spokenTokens
    XCTAssertEqual(
      PhraseMatcher().match(
        recognised: ["This", "Heading", "Continues"], script: heading, currentIndex: 0)?.tokenIndex,
      3)
  }

  func testReplacementDedupAndGenerationInvalidation() {
    let script = PrompterDocument(markdown: "alpha beta gamma delta epsilon zeta").spokenTokens
    var tracker = RecognitionTracker(generation: 7, tokenIndex: 0)
    let first = RecognitionEvent(
      replacementID: "segment-1", generation: 7, text: "alpha beta gamma", isFinal: false,
      timestamp: 1)
    XCTAssertEqual(tracker.consume(first, script: script).status, .advanced)
    XCTAssertEqual(tracker.consume(first, script: script).status, .duplicateRevision)
    tracker.invalidate(startingAt: 3)
    XCTAssertEqual(
      tracker.consume(
        .init(
          replacementID: "segment-1", generation: 7, text: "alpha beta gamma delta", isFinal: true,
          timestamp: 2), script: script
      ).status, .staleGeneration)
    XCTAssertEqual(tracker.tokenIndex, 3)
  }

  func testVolatileRevisionCannotRewindAfterItAdvanced() {
    let script = PrompterDocument(markdown: "one two three four five six seven eight").spokenTokens
    var tracker = RecognitionTracker(generation: 1)
    let advancing = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "one two three four five six",
      isFinal: false, timestamp: 1, audioStart: 0, audioEnd: 1)
    XCTAssertEqual(tracker.consume(advancing, script: script).tokenIndex, 5)
    let revision = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "one two three four",
      isFinal: false, timestamp: 2, audioStart: 0, audioEnd: 2)
    XCTAssertEqual(tracker.consume(revision, script: script).status, .held)
    XCTAssertEqual(tracker.tokenIndex, 5)
  }

  func testNewRevisionCanRewindToAnIntentionalRepeatedPhrase() {
    let script = PrompterDocument(markdown: "one two three four five six seven eight").spokenTokens
    var tracker = RecognitionTracker(generation: 1)
    let advancing = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "one two three four five six",
      isFinal: false, timestamp: 1, audioStart: 0, audioEnd: 1)
    XCTAssertEqual(tracker.consume(advancing, script: script).tokenIndex, 5)
    let repeated = RecognitionEvent(
      replacementID: "range-5", generation: 1, text: "one two three four",
      isFinal: false, timestamp: 6, audioStart: 5, audioEnd: 6)
    XCTAssertEqual(tracker.consume(repeated, script: script).tokenIndex, 3)
  }

  func testSameRevisionCanRewindAfterAnAppendedRepeatedPhrase() {
    let script = PrompterDocument(
      markdown: "one unique earlier phrase lives here then many later words continue onward ending"
    ).spokenTokens
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 6)
    let advancing = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "many later words continue onward ending",
      isFinal: false, timestamp: 1, audioStart: 0, audioEnd: 1)
    XCTAssertEqual(tracker.consume(advancing, script: script).tokenIndex, 12)
    let repeated = RecognitionEvent(
      replacementID: "range-0", generation: 1,
      text: "many later words continue onward ending one unique earlier phrase lives here then many later words",
      isFinal: false, timestamp: 2, audioStart: 0, audioEnd: 2)
    XCTAssertEqual(tracker.consume(repeated, script: script).tokenIndex, 9)
  }
  func testCumulativePhraseAndDualLocaleCandidatesArbitrateTogether() {
    let script = PrompterDocument(
      markdown:
        "bonjour tout le monde nous parlons football aujourd'hui puis nous terminons calmement"
    ).spokenTokens
    var tracker = RecognitionTracker(generation: 2, tokenIndex: 3)
    let english = RecognitionEvent(
      replacementID: "r1", generation: 2, text: "football today", isFinal: true, timestamp: 2,
      localeIdentifier: "en_GB", audioStart: 0, audioEnd: 4)
    let french = RecognitionEvent(
      replacementID: "r1", generation: 2,
      text: "bonjour tout le monde nous parlons football aujourd'hui", isFinal: true, timestamp: 2,
      localeIdentifier: "fr_FR", audioStart: 0, audioEnd: 4)
    let update = tracker.consumeCandidates([english, french], script: script)
    XCTAssertEqual(update.status, .advanced)
    XCTAssertEqual(script[update.tokenIndex].normalised, "aujourd'hui")
    let duplicate = tracker.consume(
      .init(
        replacementID: "r2", generation: 2, text: "football aujourd'hui", isFinal: true,
        timestamp: 2.1, localeIdentifier: "fr_FR", audioStart: 1, audioEnd: 4), script: script)
    XCTAssertEqual(duplicate.status, .duplicateRevision)
  }
}

final class MarkdownLibraryTests: XCTestCase {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrompterCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func testAtomicRoundTripTrashAndRestore() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let created = try await library.create(title: "PSG preview", markdown: "First draft")
    let saved = try await library.save(
      created.metadata.id, markdown: "Second draft",
      expectedFingerprint: created.metadata.contentFingerprint)
    let readBack = try await library.read(created.metadata.id)
    XCTAssertEqual(saved.metadata.revision, 1)
    XCTAssertEqual(readBack.markdown, "Second draft")
    try await library.delete(created.metadata.id)
    let scripts = await library.listScripts()
    let trash = await library.listTrash()
    XCTAssertEqual(scripts.count, 0)
    XCTAssertEqual(trash.count, 1)
    let restored = try await library.restore(created.metadata.id)
    XCTAssertEqual(restored.markdown, "Second draft")
    let reopened = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let reopenedRecord = try await reopened.read(created.metadata.id)
    XCTAssertEqual(reopenedRecord.markdown, "Second draft")
  }
  func testExternalEditPreservesUnsavedLocalRevision() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let created = try await library.create(title: "Conflict", markdown: "disk v1")
    let url = try await library.scriptURL(for: created.metadata.id)
    try "external edit".write(to: url, atomically: true, encoding: .utf8)
    do {
      _ = try await library.save(
        created.metadata.id, markdown: "unsaved local",
        expectedFingerprint: created.metadata.contentFingerprint)
      XCTFail("Expected conflict")
    } catch PrompterCoreError.externalConflict(let file) {
      let preserved = root.appendingPathComponent("Conflicts").appendingPathComponent(file)
      XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "unsaved local")
      XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external edit")
    }
  }
  func testUnknownSchemaRefusesToOpen() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"schemaVersion":99,"scripts":[],"trash":[]}"#.write(
      to: root.appendingPathComponent("LibraryIndex.json"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)) {
      XCTAssertEqual($0 as? PrompterCoreError, .unknownSchema(99))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Scripts").path))
  }
  func testMalformedIndexIsPreservedAndOrphanMarkdownRecovered() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appendingPathComponent("Scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try "orphan body".write(
      to: scripts.appendingPathComponent("orphan.md"), atomically: true, encoding: .utf8)
    try Data([0xff, 0x00, 0x12]).write(to: root.appendingPathComponent("LibraryIndex.json"))
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let recovered = await library.listScripts()
    let record = try await library.read(recovered[0].id)
    XCTAssertEqual(recovered.count, 1)
    XCTAssertEqual(record.markdown, "orphan body")
    let backups = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("LibraryIndex.corrupt-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: backups[0]), Data([0xff, 0x00, 0x12]))
  }
  func testSymlinkedScriptCannotEscapeLibrary() async throws {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let created = try await library.create(title: "Safe", markdown: "inside")
    let url = try await library.scriptURL(for: created.metadata.id)
    try FileManager.default.removeItem(at: url)
    let target = outside.appendingPathComponent("private.md")
    try "outside".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    do {
      _ = try await library.read(created.metadata.id)
      XCTFail("Expected unsafe path")
    } catch PrompterCoreError.unsafePath {}
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "outside")
  }
  func testMetadataDuplicateAndSearchAPI() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let original = try await library.create(title: "Draft", markdown: "Ligue 1 analysis")
    let changed = try await library.updateMetadata(
      original.metadata.id, title: "PSG Draft", tags: ["football", " football "])
    let results = try await library.search("ligue")
    XCTAssertEqual(changed.tags, ["football"])
    XCTAssertEqual(results.map(\.id), [original.metadata.id])
    let copy = try await library.duplicate(original.metadata.id)
    XCTAssertEqual(copy.markdown, "Ligue 1 analysis")
    XCTAssertNotEqual(copy.metadata.id, original.metadata.id)
  }
}
