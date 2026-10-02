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

  func testCalloutHasNoSpokenTokensOrCuesButAPlainQuoteDoes() {
    let markdown = "Say this.\n\n> [!info] Graphic — the [quote]\n> On screen, **24.7%** of words.\n\n> A plain [cue] quote is read.\n\n> [!warning]- Folded\n> hidden\n\nThen this."
    let document = PrompterDocument(markdown: markdown)
    XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .callout, .quote, .callout, .paragraph])
    XCTAssertTrue(document.blocks[1].spokenTokens.isEmpty)
    XCTAssertTrue(document.blocks[1].stageDirections.isEmpty)
    XCTAssertEqual(document.blocks[2].spokenTokens.map(\.text), ["A", "plain", "quote", "is", "read"])
    XCTAssertEqual(document.blocks[2].stageDirections.map(\.text), ["cue"])
    XCTAssertEqual(document.spokenTokens.map(\.text),
      ["Say", "this", "A", "plain", "quote", "is", "read", "Then", "this"])
    // Script text touching a callout, with no blank line, stays script.
    let touching = PrompterDocument(markdown: "Before it.\n> [!info] Note\n> hidden\nAfter it.\n> plain quote stays")
    XCTAssertEqual(touching.blocks.map(\.kind), [.paragraph, .callout, .paragraph])
    XCTAssertEqual(touching.spokenTokens.map(\.text), ["Before", "it", "After", "it", "plain", "quote", "stays"])
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

  func testSameRevisionCommonSuffixCannotJumpToARepeatedPhrase() {
    let script = PrompterDocument(
      markdown: "start alpha beta gamma delta omega different alpha beta gamma delta and finish"
    ).spokenTokens
    var tracker = RecognitionTracker(generation: 1)
    XCTAssertEqual(tracker.consume(
      .init(
        replacementID: "volatile-range", generation: 1, text: "start alpha beta gamma delta omega",
        isFinal: false, timestamp: 0, audioStart: 0, audioEnd: 0), script: script).tokenIndex, 5)
    let update = tracker.consume(
      .init(
        replacementID: "volatile-range", generation: 1,
        text: "start alpha beta gamma delta omega and",
        isFinal: false, timestamp: 1, audioStart: 0, audioEnd: 1), script: script)
    XCTAssertEqual(update.status, .held)
    XCTAssertEqual(tracker.tokenIndex, 5)
  }

  func testNewRevisionCanSkipToTheSameRepeatedPhrase() {
    let script = PrompterDocument(
      markdown: "start alpha beta gamma delta omega different alpha beta gamma delta and finish"
    ).spokenTokens
    var tracker = RecognitionTracker(generation: 1)
    XCTAssertEqual(tracker.consume(
      .init(
        replacementID: "volatile-range", generation: 1, text: "start alpha beta gamma delta omega",
        isFinal: false, timestamp: 0, audioStart: 0, audioEnd: 0), script: script).tokenIndex, 5)
    XCTAssertEqual(tracker.consume(
      .init(
        replacementID: "new-range", generation: 1,
        text: "start alpha beta gamma delta omega and",
        isFinal: false, timestamp: 1, audioStart: 1, audioEnd: 2), script: script).tokenIndex, 11)
  }

  func testLocalAnchorAdvancesBeforeAContractionBreaksTheLongInterim() {
    let script = PrompterDocument(
      markdown: "I am not saying he is a better player than Yamal. I am simply saying that he is a better Champions League player."
    ).spokenTokens
    let current = try! XCTUnwrap(script.firstIndex { $0.normalised == "yamal" })
    let match = PhraseMatcher().match(
      recognised: ["I'm", "simply", "saying", "he's", "a", "better"],
      script: script, currentIndex: current)
    // He dropped "that" and contracted "he is": the continuation steps over the one function word
    // and reaches the "better" he has said, instead of stopping at "saying".
    XCTAssertEqual(
      match?.tokenIndex,
      script.indices.first { $0 > current && script[$0].normalised == "better" })
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

  func testSeekReanchorsCumulativeRevisionsWithoutAcceptingStaleOrCorrectedPrefixes() {
    let script = PrompterDocument(markdown: "alpha beta gamma delta epsilon zeta eta theta").spokenTokens
    var tracker = RecognitionTracker(generation: 1)
    let initial = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "alpha beta gamma", isFinal: false,
      timestamp: 3, audioStart: 0, audioEnd: 3)
    XCTAssertEqual(tracker.consume(initial, script: script).tokenIndex, 2)
    tracker.reanchor(to: 5, minimumAudioStart: 5)

    XCTAssertEqual(tracker.consume(initial, script: script).status, .duplicateRevision)
    let corrected = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "alpha bravo gamma", isFinal: false,
      timestamp: 4, audioStart: 0, audioEnd: 4)
    XCTAssertEqual(tracker.consume(corrected, script: script).status, .held)
    XCTAssertEqual(tracker.tokenIndex, 5)
    // The first result to reach past the watermark is still describing audio the reader spoke
    // before re-anchoring: it is simply delivered late. It becomes the baseline in turn, and only
    // what the revision adds after that counts as new speech. Without this, a result covering
    // pre-seek audio threw the reader straight back to where a scroll-back had just left.
    let continued = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "alpha bravo gamma zeta eta", isFinal: false,
      timestamp: 6, audioStart: 0, audioEnd: 6)
    XCTAssertEqual(tracker.consume(continued, script: script).status, .held)
    XCTAssertEqual(tracker.tokenIndex, 5)
    let continuedAgain = RecognitionEvent(
      replacementID: "range-0", generation: 1, text: "alpha bravo gamma zeta eta theta",
      isFinal: false, timestamp: 8, audioStart: 0, audioEnd: 8)
    XCTAssertEqual(tracker.consume(continuedAgain, script: script).tokenIndex, 7)

    tracker.reanchor(to: 5, minimumAudioStart: 5)
    let crossingOldAudio = RecognitionEvent(
      replacementID: "old-segment", generation: 1, text: "zeta eta", isFinal: false,
      timestamp: 6, audioStart: 4, audioEnd: 6)
    XCTAssertEqual(tracker.consume(crossingOldAudio, script: script).status, .held)
    XCTAssertEqual(tracker.tokenIndex, 5)
    let newAudio = RecognitionEvent(
      replacementID: "new-segment", generation: 1, text: "zeta eta", isFinal: false,
      timestamp: 6, audioStart: 5, audioEnd: 6)
    XCTAssertEqual(tracker.consume(newAudio, script: script).tokenIndex, 6)

    var beforeFirstCandidate = RecognitionTracker(generation: 2, tokenIndex: 5)
    beforeFirstCandidate.reanchor(to: 5, minimumAudioStart: 5)
    let preSeekSegment = RecognitionEvent(
      replacementID: "range-0", generation: 2, text: "alpha beta gamma", isFinal: false,
      timestamp: 4, audioStart: 0, audioEnd: 4)
    XCTAssertEqual(beforeFirstCandidate.consume(preSeekSegment, script: script).status, .held)
    let postSeekExtension = RecognitionEvent(
      replacementID: "range-0", generation: 2, text: "alpha beta gamma zeta eta", isFinal: false,
      timestamp: 6, audioStart: 0, audioEnd: 6)
    XCTAssertEqual(beforeFirstCandidate.consume(postSeekExtension, script: script).status, .held)
    let laterExtension = RecognitionEvent(
      replacementID: "range-0", generation: 2, text: "alpha beta gamma zeta eta theta",
      isFinal: false, timestamp: 8, audioStart: 0, audioEnd: 8)
    XCTAssertEqual(beforeFirstCandidate.consume(laterExtension, script: script).tokenIndex, 7)
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

  func testSkippedWordsRecoverWithContiguousTail() {
    let script = PrompterDocument(markdown: "alpha beta gamma delta epsilon").spokenTokens
    let match = PhraseMatcher().match(recognised: ["alpha", "delta", "epsilon"], script: script, currentIndex: 0)
    XCTAssertEqual(match?.tokenIndex, 4)
  }

  func testIncompleteReorderedPrefixCannotJumpToLaterRepeatedWord() {
    let script = PrompterDocument(markdown: """
      Doué is a better Champions League player than Yamal

      As of the 28th of August 2026, Désiré Doué is a better Champions League player than Lamine Yamal.

      Now, get what I'm not saying. I am not saying he's a better player than Yamal; I am simply saying that he is a better Champions League player.

      And this should be fairly uncontroversial.

      Doué’s played fewer seasons, fewer games in the Champions League, and has fewer minutes in the Champions League.

      Yet, despite that, using UEFA’s own stats, Yamal’s only got 1 more G/A than Doué. And that’s only because he takes penalties.

      Only counting non-penalty G/A, Doué’s actually got more G/A than Yamal.

      And before you try to say that Doué’s only stat-padding against small teams.

      Over 70% of Doué's G/A in the Champions League are in the knockout stages.

      Not to mention the fact that Doué has played against better opposition and performed better in big Champions League games.

      So, with all this evidence presented, if one is to be intellectually honest, one ought to conclude that Désiré Doué is a better Champions League player than Lamine Yamal

      Conceding this does not mean that Doué is a better player than Yamal, in the same way that conceding that Ronaldo is a better Champions League player than Messi doesn’t make Ronaldo better than Messi

      If you are unable to admit this fact, then I'm sorry to say, you're just being dogmatic.

      And if you try to use the excuse that Doué plays for a better team, then I'm sorry, you just have got confirmation bias. You're just looking for points that suit your narrative without actually addressing the main points of the argument.
      """).spokenTokens
    XCTAssertEqual(script[260].normalised, "team")
    XCTAssertEqual(script[271].normalised, "just")
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 260)
    let englishUpdate = tracker.consume(.init(
      replacementID: "1-dictation-0-1512960-16000", generation: 1,
      text: "you have just", isFinal: false, timestamp: 95.125,
      localeIdentifier: "en_GB", audioStart: 94.56, audioEnd: 95.04), script: script)
    XCTAssertEqual(tracker.tokenIndex, 260)
    XCTAssertEqual(englishUpdate.status, .held)
    XCTAssertEqual(englishUpdate.tokenIndex, 260)
    let update = tracker.consume(.init(
      replacementID: "1-dictation-1-533760-16000", generation: 1,
      text: "youy to excuse For better team I'm sorry You have just", isFinal: false,
      timestamp: 95.158, localeIdentifier: "fr_FR", audioStart: 88.74, audioEnd: 95.166), script: script)
    // The French revision does carry "better team I'm sorry you", which he has said, so the
    // continuation credits through "you" (its "then" dropped). The reordered "have just" must not
    // reach this sentence's "just" or the later repeated one.
    XCTAssertEqual(script[264].normalised, "you")
    XCTAssertEqual(update.tokenIndex, 264)
    XCTAssertEqual(tracker.tokenIndex, 264)
  }

  func testDualLocaleHallucinatedTailCannotJumpFromEarlierPrefix() {
    let script = PrompterDocument(markdown: """
      Doué is a better Champions League player than Yamal

      As of the 28th of August 2026, Désiré Doué is a better Champions League player than Lamine Yamal.

      Now, get what I'm not saying. I am not saying he's a better player than Yamal; I am simply saying that he is a better Champions League player.

      And this should be fairly uncontroversial.

      Doué’s played fewer seasons, fewer games in the Champions League, and has fewer minutes in the Champions League.

      Yet, despite that, using UEFA’s own stats, Yamal’s only got 1 more G/A than Doué. And that’s only because he takes penalties.

      Only counting non-penalty G/A, Doué’s actually got more G/A than Yamal.

      And before you try to say that Doué’s only stat-padding against small teams.

      Over 70% of Doué's G/A in the Champions League are in the knockout stages.

      Not to mention the fact that Doué has played against better opposition and performed better in big Champions League games.

      So, with all this evidence presented, if one is to be intellectually honest, one ought to conclude that Désiré Doué is a better Champions League player than Lamine Yamal

      Conceding this does not mean that Doué is a better player than Yamal, in the same way that conceding that Ronaldo is a better Champions League player than Messi doesn’t make Ronaldo better than Messi

      If you are unable to admit this fact, then I'm sorry to say, you're just being dogmatic.

      And if you try to use the excuse that Doué plays for a better team, then I'm sorry, you just have got confirmation bias. You're just looking for points that suit your narrative without actually addressing the main points of the argument.
      """).spokenTokens
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 24)
    _ = tracker.consume(.init(
      replacementID: "1-dictation-0-0-16000", generation: 1,
      text: "Duet is a better Champions League player than Yamal As of the 28th of August 2026. Doué is a better Champions League player then", isFinal: false,
      timestamp: 14.739, localeIdentifier: "en_GB", audioStart: 0, audioEnd: 14.739), script: script)
    let update = tracker.consume(.init(
      replacementID: "1-dictation-1-0-16000", generation: 1,
      text: "Tu es ici better Champions the Play, le mot Azov, Twenty, Twenty, Twenty, Sex Desire, the Better, the Player and",
      isFinal: false, timestamp: 14.784, localeIdentifier: "fr_FR", audioStart: 0, audioEnd: 14.784), script: script)
    XCTAssertEqual(update.status, .held)
    XCTAssertEqual(tracker.tokenIndex, 24)
  }

  func testRepeatedPhraseAlreadySpokenCannotCreditWordsAheadOfTheReader() {
    let script = PrompterDocument(markdown: """
      Doué is a better Champions League player than Yamal

      As of the 28th of August 2026, Désiré Doué is a better Champions League player than Lamine Yamal.
      """).spokenTokens
    XCTAssertEqual(script[18].normalised, "is")
    XCTAssertEqual(script[19].normalised, "a")
    XCTAssertEqual(script[24].normalised, "than")
    // The canonical trace at 12.96s: the reader has just reached "Doué is a" in the second
    // sentence, and the revision still carries the first sentence's "a better Champions League
    // player than". That earlier, already-spoken phrase must not be credited against the same
    // phrase ahead of him; only the word he actually reached may dim.
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 18)
    let update = tracker.consume(.init(
      replacementID: "1-dictation-0-0-16000", generation: 1,
      text: "Duet is a better Champions League player than Yamal as of the 28th of August 2026 Doué is a",
      isFinal: false, timestamp: 12.96, localeIdentifier: "en_GB",
      audioStart: 0, audioEnd: 12.96), script: script)
    XCTAssertEqual(update.tokenIndex, 19)
    XCTAssertEqual(tracker.tokenIndex, 19)
  }

  func testImmediateSingleAndWeakTwoWordForwardMatchesRemainEligible() {
    let single = PrompterDocument(markdown: "alpha beta").spokenTokens
    XCTAssertEqual(
      PhraseMatcher().match(recognised: ["beta"], script: single, currentIndex: 0)?.tokenIndex,
      1)
    let near = PrompterDocument(markdown: "start the planet").spokenTokens
    XCTAssertEqual(
      PhraseMatcher().match(recognised: ["the", "planet"], script: near, currentIndex: 0)?.tokenIndex,
      2)
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

extension RecognitionTests {
  /// Word-onset credit: a partial last word dims the next script word at once, and nothing else.
  func testWordOnsetDimsOnlyTheNextWordAndNeverACommonOne() {
    let script = PrompterDocument(
      markdown: "He is a better Champions League player than [look up] these others, and that is final."
    ).spokenTokens
    XCTAssertEqual(script.map(\.normalised)[3...8], ["better", "champions", "league", "player", "than", "these"])
    let matcher = PhraseMatcher()
    func onset(_ words: [String], after current: Int) -> Int? {
      matcher.onsetCredit(words: words, script: script, currentIndex: current)?.tokenIndex
    }
    // "a better" is credited and "champ" begins the next word.
    XCTAssertEqual(onset(["a", "better", "champ"], after: 3), 4)
    // New whole words continuing the script, then the fragment of the word after them.
    XCTAssertEqual(onset(["a", "better", "champions", "lea"], after: 3), 5)
    // The bracket cue and the punctuation are not words, so "thes" still begins the next one.
    XCTAssertEqual(onset(["player", "than", "thes"], after: 7), 8)
    // A prefix of a later word never skips the next one.
    XCTAssertNil(onset(["a", "better", "lea"], after: 3))
    // Fewer than three letters, the whole word (the ordinary extension's job), no anchoring words.
    XCTAssertNil(onset(["a", "better", "ch"], after: 3))
    XCTAssertNil(onset(["a", "better", "champions"], after: 3))
    XCTAssertNil(onset(["champ"], after: 3))
    XCTAssertNil(onset(["quite", "unrelated", "champ"], after: 3))
    // Common short words prove nothing: "the" said before "these", or "tha" before "that".
    XCTAssertNil(onset(["player", "than", "the"], after: 7))
    XCTAssertNil(onset(["others", "and", "tha"], after: 10))

    var tracker = RecognitionTracker(generation: 1, tokenIndex: 3)
    let dimmed = tracker.consume(.init(
      replacementID: "r", generation: 1, text: "He is a better champ", isFinal: false, timestamp: 1,
      localeIdentifier: "en_GB", audioStart: 0, audioEnd: 1), script: script)
    XCTAssertEqual(dimmed.tokenIndex, 4)
    // Further on, the same fragment is behind the reader and cannot move him back.
    var ahead = RecognitionTracker(generation: 1, tokenIndex: 6)
    let stayed = ahead.consume(.init(
      replacementID: "s", generation: 1, text: "a better champ", isFinal: false, timestamp: 1,
      localeIdentifier: "en_GB", audioStart: 0, audioEnd: 1), script: script)
    XCTAssertEqual(stayed.status, .held)
    XCTAssertEqual(ahead.tokenIndex, 6)
  }

  /// The canonical trace sat on "then" for a second: "I'm" in the script only matched "I am".
  func testScriptContractionContinuesFromTheSameContraction() {
    let script = PrompterDocument(markdown: "then I'm sorry to say you're just being dogmatic").spokenTokens
    let matcher = PhraseMatcher()
    XCTAssertEqual(matcher.forwardExtension(words: ["fact", "then", "i'm", "sorry"], script: script, currentIndex: 0)?.tokenIndex, 2)
    let expanded = PrompterDocument(markdown: "then I am sorry").spokenTokens
    XCTAssertEqual(matcher.forwardExtension(words: ["then", "i'm", "sorry"], script: expanded, currentIndex: 0)?.tokenIndex, 3)
  }

  /// A garbled second-locale tail must not move the frontier into a repeated later clause.
  func testCompetingLocaleCommonTailCannotCreditLaterRepeatedClause() {
    let script = PrompterDocument(markdown:
      "Arbor weren't knocked out because they wasted chances. They were knocked out because the chances they gave away were so good.").spokenTokens
    XCTAssertEqual(script[4].normalised, "because")
    XCTAssertEqual(script[13].normalised, "the")
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 4)
    func event(_ locale: String, _ text: String, at time: Double) -> RecognitionEvent {
      .init(replacementID: locale == "fr_FR" ? "fr-range" : "en-range", generation: 1,
        text: text, isFinal: false, timestamp: time, localeIdentifier: locale,
        audioStart: locale == "fr_FR" ? 2.04 : 0, audioEnd: time)
    }
    let held = tracker.consume(event("fr_FR", "Who work knock out because the", at: 4.75), script: script)
    XCTAssertEqual(held.status, .held, "A garbled common tail must not select the repeated later clause")
    XCTAssertEqual(held.tokenIndex, 4)
    let first = tracker.consume(event("en_GB", "Birch weren't knocked out because they wasted chances", at: 4.77), script: script)
    XCTAssertEqual(first.tokenIndex, 7, "The first spoken chances must remain in the first clause")
    let next = tracker.consume(event("fr_FR", "Who work knock out because the waste the chances They", at: 5.75), script: script)
    XCTAssertEqual(next.tokenIndex, 8, "The next They belongs to the start of the second clause")
    let recovered = tracker.consume(event("en_GB", "They were knocked out because the chances they gave away", at: 8.63), script: script)
    XCTAssertEqual(recovered.tokenIndex, 17)
    XCTAssertEqual(PhraseMatcher().forwardExtension(words: ["knocked", "out", "because", "they"],
      script: script, currentIndex: 3)?.tokenIndex, 5, "A local conjunction still continues known speech")
    let skipped = PrompterDocument(markdown:
      "anchor filler filler filler filler filler filler filler filler radiant amber lanterns shine").spokenTokens
    XCTAssertEqual(PhraseMatcher().match(recognised: ["radiant", "amber", "lanterns", "shine"],
      script: skipped, currentIndex: 0)?.tokenIndex, skipped.count - 1, "Distinct informative skip evidence remains valid")
  }

  /// Short 173 at 166.9 s: re-reading "one could argue that Barcelona's" jumped sixty words to the
  /// later "I would argue that Barcelona".
  func testWeakPhraseCannotJumpAParagraphAhead() {
    let script = PrompterDocument(markdown: """
      One could argue Barcelona's defensive personnel has gotten worse. In the last 2 years Barcelona lost Inigo Martinez. As excellent a midfielder as Rodri is.

      And I would argue that Barcelona would have been much better served.
      """).spokenTokens
    XCTAssertEqual(script[5].normalised, "personnel")
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 5)
    let update = tracker.consume(.init(
      replacementID: "r", generation: 1, text: "one could argue that Barcelona", isFinal: false,
      timestamp: 1, localeIdentifier: "en_GB", audioStart: 0, audioEnd: 1), script: script)
    XCTAssertEqual(update.status, .held)
    XCTAssertEqual(tracker.tokenIndex, 5)
    // A lone name or word from further down moves nothing either.
    for (id, text) in [("n", "Rodri"), ("w", "served")] {
      let lone = tracker.consume(.init(
        replacementID: id, generation: 1, text: text, isFinal: false,
        timestamp: 1, localeIdentifier: "en_GB", audioStart: 0, audioEnd: 1), script: script)
      XCTAssertEqual(lone.tokenIndex, 5, text)
    }
    // Three informative words in a row where he really is do carry a skip that far.
    let skipped = tracker.consume(.init(
      replacementID: "s", generation: 1, text: "I would argue that Barcelona would have been much better served",
      isFinal: false, timestamp: 2, localeIdentifier: "en_GB", audioStart: 1, audioEnd: 2), script: script)
    XCTAssertEqual(skipped.tokenIndex, script.count - 1)
  }

  /// Short 173 at 291.4 s, a false start: "the ties that they" credited the "they" after
  /// "knocked them out", which he had not said yet.
  func testLoneWordAfterAGapCannotCreditPastTheNextWord() {
    let script = PrompterDocument(markdown: "even in the ties that knocked them out they scored 8 goals").spokenTokens
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 4)
    let update = tracker.consume(.init(
      replacementID: "r", generation: 1, text: "clinical and even in the ties that they", isFinal: false,
      timestamp: 1, localeIdentifier: "en_GB", audioStart: 0, audioEnd: 1), script: script)
    XCTAssertEqual(update.status, .held)
    XCTAssertEqual(tracker.tokenIndex, 4)
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
  func testMetadataAndDuplicateAPI() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try MarkdownLibrary(rootURL: root, coordinatesExternalChanges: false)
    let original = try await library.create(title: "Draft", markdown: "Ligue 1 analysis")
    let changed = try await library.updateMetadata(
      original.metadata.id, title: "PSG Draft", tags: ["football", " football "])
    XCTAssertEqual(changed.tags, ["football"])
    let copy = try await library.duplicate(original.metadata.id)
    XCTAssertEqual(copy.markdown, "Ligue 1 analysis")
    XCTAssertNotEqual(copy.metadata.id, original.metadata.id)
  }
}
