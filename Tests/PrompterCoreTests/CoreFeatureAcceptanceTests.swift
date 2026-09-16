import AVFoundation
import AppKit
import SwiftUI
import XCTest

@testable import JuniorPrompter
import PrompterCore

// MARK: - Harness

private let acceptanceInputs = URL(
  fileURLWithPath:
    "/Users/junior.nkanabassi/Documents/JuniorOS/02 Projects/Development/JuniorPrompter/00 Project State/Acceptance inputs",
  isDirectory: true)

/// The reading half of the file-private `PresenterView`: the same `ScriptTextView`, fed from the
/// same session and settings with the same derivations (column inset, mirror XOR 180°), hosted
/// in a window that is never ordered in. Nothing here reaches the screen, takes focus or opens a
/// device.
private struct ReadingSurface: View {
  @ObservedObject var store: AppStore
  @ObservedObject var session: SessionStore
  var body: some View {
    GeometryReader { geometry in
      let settings = store.settings
      ScriptTextView(
        document: session.document, tokenIndex: session.tokenIndex,
        lastConfirmedTokenIndex: session.lastConfirmedTokenIndex,
        isActivelyRunning: session.isActivelyRunning, seekRevision: session.seekRevision,
        guideFraction: settings.guideFraction,
        verticalMirror: settings.verticalMirror != (settings.rotation == 180),
        fontName: settings.fontName, fontSize: settings.fontSize, textOpacity: settings.textOpacity,
        fontWeight: settings.fontWeight, textColorHex: settings.textColorHex,
        lineSpacing: settings.lineSpacing, paragraphSpacing: settings.paragraphSpacing,
        horizontalMargin: ScriptTextView.sideInset(width: geometry.size.width, textWidth: settings.textWidth),
        alignment: settings.alignment, showCues: settings.showCues,
        highlightActiveWord: settings.highlightActiveWord, onSeek: session.seek)
    }
  }
}

@MainActor private final class Surface {
  let store: AppStore
  let host: NSHostingView<ReadingSurface>
  private let window: NSWindow

  init(store: AppStore, size: NSSize = NSSize(width: 760, height: 520)) {
    self.store = store
    host = NSHostingView(rootView: ReadingSurface(store: store, session: store.session))
    host.frame = NSRect(origin: .zero, size: size)
    window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
  }
  /// What `closeNow` does to the presenter's hosting view.
  func close() { window.contentView = NSView() }

  var scroll: NSScrollView { Self.find(host)! }
  var text: NSTextView { scroll.documentView as! NSTextView }
  private static func find(_ view: NSView) -> NSScrollView? {
    (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
  }

  /// One SwiftUI update plus the deferred read-state/alignment pass; `animations` also waits
  /// out the 0.6 s scroll easing a running session uses.
  func settle(animations: Bool = false) async {
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(30))
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(animations ? 750 : 30))
  }

  var mirrored: Bool { store.settings.verticalMirror != (store.settings.rotation == 180) }

  /// Characters of the rendered line the reading guide crosses, in layout terms (so flipped
  /// with the text when the presenter is mirrored vertically or turned 180°).
  func guideLine() -> NSRange {
    let manager = text.layoutManager!
    let container = text.textContainer!
    manager.ensureLayout(for: container)
    let height = scroll.contentView.bounds.height
    let visual = ScriptTextView.visualGuideY(height: height, fraction: store.settings.guideFraction)
    let layoutY = mirrored ? height - visual : visual
    let y = scroll.contentView.bounds.origin.y + layoutY - text.textContainerInset.height
    let glyph = manager.glyphIndex(for: NSPoint(x: container.size.width / 2, y: y), in: container)
    var line = NSRange()
    _ = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
    return manager.characterRange(forGlyphRange: line, actualGlyphRange: nil)
  }

  /// Whether the active token's own rendered word sits on the guide line.
  func activeWordIsOnGuide(_ session: SessionStore) -> Bool {
    let ranges = wordRanges(session.document.spokenTokens, in: text.string)
    guard ranges.indices.contains(session.tokenIndex), let word = ranges[session.tokenIndex] else { return false }
    return NSIntersectionRange(guideLine(), word).length > 0
  }

  func alpha(at location: Int) -> CGFloat {
    (text.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)?
      .alphaComponent ?? -1
  }

  /// Words whose dimming disagrees with the session: everything up to the last confirmed word
  /// is dimmed, nothing after it is.
  func wronglyDimmed(_ session: SessionStore) -> [String] {
    let tokens = session.document.spokenTokens
    var wrong: [String] = []
    for (index, range) in wordRanges(tokens, in: text.string).enumerated() {
      guard let range else { continue }
      let dimmed = alpha(at: range.location) < 0.6
      let shouldDim = session.lastConfirmedTokenIndex.map { index <= $0 } ?? false
      if dimmed != shouldDim { wrong.append("#\(index) \(tokens[index].text) dimmed=\(dimmed)") }
    }
    return wrong
  }
}

/// An independent reading of where each spoken token is drawn: whole words, in order.
private func wordRanges(_ tokens: [DocumentToken], in string: String) -> [NSRange?] {
  let ns = string as NSString
  var cursor = 0
  return tokens.map { token in
    let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: token.text)
      + "(?![\\p{L}\\p{N}])"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      cursor <= ns.length,
      let match = regex.firstMatch(in: string, range: NSRange(location: cursor, length: ns.length - cursor))
    else { return nil }
    cursor = NSMaxRange(match.range)
    return match.range
  }
}

/// Indices of the tokens a reader says off the presenter: all of them except ordered-list
/// numbers, which the presenter does not draw.
private func readableIndices(_ document: PrompterDocument) -> [Int] {
  let ns = document.markdown as NSString
  return document.spokenTokens.indices.filter { index in
    let token = document.spokenTokens[index]
    guard token.text.allSatisfy(\.isNumber) else { return true }
    let lineStart = ns.lineRange(for: NSRange(location: token.sourceRange.location, length: 0)).location
    let before = ns.substring(with: NSRange(location: lineStart, length: token.sourceRange.location - lineStart))
    let after = token.sourceRange.upperBound < ns.length
      ? ns.substring(with: NSRange(location: token.sourceRange.upperBound, length: 1)) : ""
    return !(before.trimmingCharacters(in: .whitespaces).isEmpty && (after == "." || after == ")"))
  }
}

/// DictationTranscriber as the session sees it: one cumulative, never-final revision per audio
/// range, delivered through `acceptSpeechCandidate`, optionally with the second locale's take.
@MainActor private final class Dictation {
  let session: SessionStore
  let generation: UInt64
  private var english: [String] = []
  private var french: [String] = []
  private var range = 0
  private var start: Double
  private var clock: Double

  init(_ session: SessionStore, generation: UInt64, startingAt clock: Double = 0) {
    self.session = session
    self.generation = generation
    self.clock = clock
    start = clock
  }

  /// A pause in speech: the engine opens a new range.
  func breath() {
    range += 1
    english = []
    french = []
    clock += 0.5
    start = clock
  }

  func say(_ phrase: String, french frenchPhrase: String? = nil) async {
    let words = phrase.split(separator: " ").map(String.init)
    english += words
    if let frenchPhrase { french += frenchPhrase.split(separator: " ").map(String.init) }
    clock += 0.3 * Double(max(1, words.count))
    session.noteSubmittedAudioEnd(through: clock)
    let span = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 1000),
      end: CMTime(seconds: clock, preferredTimescale: 1000))
    session.acceptSpeechCandidate(.init(
      replacementID: "\(generation)-dictation-0-\(range)", generation: generation,
      locale: Locale(identifier: "en-GB"), text: english.joined(separator: " "), range: span,
      isFinal: false))
    if !french.isEmpty {
      session.acceptSpeechCandidate(.init(
        replacementID: "\(generation)-dictation-1-\(range)", generation: generation,
        locale: Locale(identifier: "fr-FR"), text: french.joined(separator: " "), range: span,
        isFinal: false))
    }
    // The session batches candidates for 25 ms before matching them.
    try? await Task.sleep(for: .milliseconds(50))
  }
}

private struct ReplayResult {
  var final = 0
  var worstLag = 0
  var worstAt = ""
  var ahead: [String] = []
  var backwards: [String] = []
}

/// Reads a whole document aloud through the production tracker, the way the dual-locale
/// dictation engine reports it: the English range grows word by word, the French engine
/// produces filler alongside, and a new range opens every `rangeLength` words.
private func replay(_ document: PrompterDocument, rangeLength: Int = 18) -> ReplayResult {
  let tokens = document.spokenTokens
  var tracker = RecognitionTracker(generation: 1, tokenIndex: 0)
  var result = ReplayResult()
  var english: [String] = []
  var french: [String] = []
  var range = 0
  var start = 0.0
  var clock = 0.0
  var previous = 0
  let filler = ["euh", "passe", "donc", "voilà", "sélection"]
  for index in readableIndices(document) {
    if english.count == rangeLength {
      range += 1
      english = []
      french = []
      start = clock
    }
    english.append(tokens[index].text)
    french.append(filler[index % filler.count])
    clock += 0.3
    let events = [("en-GB", english), ("fr-FR", french)].map { locale, words in
      RecognitionEvent(
        replacementID: "1-dictation-\(locale)-\(range)", generation: 1,
        text: words.joined(separator: " "), isFinal: false, timestamp: clock,
        localeIdentifier: locale, audioStart: start, audioEnd: clock)
    }
    let update = tracker.consumeCandidates(events, script: tokens)
    if update.tokenIndex < previous {
      result.backwards.append("after #\(index) \(tokens[index].text): #\(previous) -> #\(update.tokenIndex)")
    }
    if update.tokenIndex > index {
      result.ahead.append(
        "said #\(index) \(tokens[index].text), dimmed to #\(update.tokenIndex) \(tokens[update.tokenIndex].text)")
    }
    if index - update.tokenIndex > result.worstLag {
      result.worstLag = index - update.tokenIndex
      result.worstAt = "said #\(index) '\(tokens[index].text)' with '\(tokens[update.tokenIndex].text)' #\(update.tokenIndex) last dimmed"
    }
    previous = update.tokenIndex
  }
  result.final = tracker.tokenIndex
  return result
}

// MARK: - Tests

@MainActor
final class CoreFeatureAcceptanceTests: XCTestCase {
  private func fixture(_ name: String) throws -> String {
    try String(contentsOf: acceptanceInputs.appendingPathComponent(name), encoding: .utf8)
  }

  private func makeStore() -> AppStore {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jp-core-qa-\(UUID().uuidString)", isDirectory: true)
    let suite = "JuniorPrompterCoreQA.\(UUID().uuidString)"
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    return AppStore(arguments: ["tests", "--data-directory", root.path],
      defaults: UserDefaults(suiteName: suite)!)
  }

  /// A store presenting `markdown` from its own disposable library.
  private func presenting(_ markdown: String, title: String = "Script", mode: String = "Voice")
    async throws -> (AppStore, ScriptRecord)
  {
    let store = makeStore()
    let record = try await XCTUnwrap(store.library).create(title: title, markdown: markdown)
    await store.reload()
    store.selectedID = record.id
    store.settings.mode = mode
    let selected = try XCTUnwrap(store.selected)
    store.session.present(record: selected, settings: store.settings)
    return (store, selected)
  }

  private func record(_ markdown: String, title: String = "Script") -> ScriptRecord {
    ScriptRecord(
      metadata: .init(title: title, fileName: "\(UUID().uuidString).md", contentFingerprint: "x"),
      markdown: markdown)
  }

  private func index(of word: String, in session: SessionStore, occurrence: Int = 1) throws -> Int {
    let matches = session.document.spokenTokens.indices.filter {
      session.document.spokenTokens[$0].normalised == PrompterDocument.normalise(word)
    }
    return try XCTUnwrap(matches.dropFirst(occurrence - 1).first, "no \(word) #\(occurrence)")
  }

  // MARK: Load and present

  /// Import-like creation of both real scripts: lossless, and presented paused at the top.
  func testTheRealScriptsLoadLosslesslyAndPresentFromTheTop() async throws {
    let store = makeStore()
    for (name, first) in [("172 script.md", "Kylian"), ("173 script.md", "Barcelona")] {
      let markdown = try fixture(name)
      let created = try await XCTUnwrap(store.library).create(title: name, markdown: markdown)
      await store.reload()
      store.selectedID = created.id
      let selected = try XCTUnwrap(store.selected)
      XCTAssertEqual(selected.markdown, markdown, "\(name) must load byte for byte")
      store.session.present(record: selected, settings: store.settings)
      XCTAssertEqual(store.session.activeScriptID, created.id)
      XCTAssertEqual(store.session.state, .paused, "presenting never starts on its own")
      XCTAssertEqual(store.session.tokenIndex, 0)
      XCTAssertNil(store.session.lastConfirmedTokenIndex)
      XCTAssertEqual(store.session.anchor?.scriptID, created.id)
      XCTAssertEqual(store.session.activeToken?.text, first)
      XCTAssertGreaterThan(store.session.document.spokenTokens.count, 450)
    }
  }

  /// Every word the reader has to say is drawn by the presenter as that same word, in order.
  private func unmappedWords(_ markdown: String) -> (failures: [String], total: Int) {
    let document = PrompterDocument(markdown: markdown)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 44, textOpacity: 1, showCues: false)
    let rendered = view.string as NSString
    var byIndex: [Int: NSRange] = [:]
    for (range, index) in coordinator.mappings where byIndex[index] == nil { byIndex[index] = range }
    var failures: [String] = []
    var previous = -1
    for (index, token) in document.spokenTokens.enumerated() {
      guard let range = byIndex[index] else {
        failures.append("#\(index) '\(token.text)' is not drawn")
        continue
      }
      let shown = rendered.substring(with: range)
      let word = (shown as NSString).substring(to: min(shown.utf16.count, token.text.utf16.count))
      let letterBefore = range.location > 0
        && CharacterSet.alphanumerics.contains(UnicodeScalar(rendered.character(at: range.location - 1)) ?? " ")
      if word.compare(token.text, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        || letterBefore || range.location <= previous
      {
        let context = rendered.substring(with: NSRange(
          location: max(0, range.location - 12), length: min(30, rendered.length - max(0, range.location - 12))))
        failures.append("#\(index) '\(token.text)' drawn as '\(shown)' in '…\(context)…'")
      }
      previous = range.location
    }
    return (failures, document.spokenTokens.count)
  }

  func test173EveryWordIsDrawnAsItselfInOrder() throws {
    let result = unmappedWords(try fixture("173 script.md"))
    XCTAssertEqual(result.failures, [], "\(result.failures.count) of \(result.total) words")
  }

  /// 172 has a numbered list. The presenter drops the "1." markers, but the document keeps
  /// "1", "2", "3" as spoken tokens, and the renderer then looks for "1" as a bare substring
  /// from its cursor: it lands inside "15" twenty paragraphs later and every word in between
  /// loses its place on screen (no dimming, no scrolling, clicks seek to the wrong word).
  func test172EveryWordIsDrawnAsItselfInOrder() throws {
    let result = unmappedWords(try fixture("172 script.md"))
    XCTExpectFailure("BUG: ordered-list numbers are spoken tokens the presenter never draws; their unanchored search desynchronises every later word mapping") {
      XCTAssertEqual(result.failures, [], "\(result.failures.count) of \(result.total) words: \(result.failures.prefix(6))")
    }
    // The damage is not limited to the list numbers themselves.
    let beyondTheList = result.failures.filter { !$0.contains("'1'") && !$0.contains("'2'") && !$0.contains("'3'") }
    XCTExpectFailure("BUG: words after the numbered list are drawn at the wrong place or not at all") {
      XCTAssertEqual(beyondTheList, [], "\(beyondTheList.count) ordinary words lost: \(beyondTheList.prefix(6))")
    }
  }

  /// Next passage onto the numbered list must put the list's first visible word on the guide.
  func test172NextPassageOntoTheNumberedListScrollsToIt() async throws {
    let (store, _) = try await presenting(try fixture("172 script.md"), mode: "Manual")
    let session = store.session
    let surface = Surface(store: store)
    defer { surface.close() }
    session.seek(to: try index(of: "follows", in: session))
    await surface.settle()
    session.nextPassage()
    await surface.settle()
    let guide = (surface.text.string as NSString).substring(with: surface.guideLine())
    XCTExpectFailure("BUG: next passage lands on the invisible list number, mapped to the '1' inside '15'") {
      XCTAssertTrue(guide.contains("Individual performances"), "guide shows '\(guide)'")
    }
  }

  func testEmptyOneWordAndHeadingsAndCuesOnlyScripts() async throws {
    // Empty: nothing to anchor, nothing to play, no control misbehaves.
    let empty = SessionStore()
    var manual = PrompterSettings()
    manual.mode = "Manual"
    empty.present(record: record(""), settings: manual)
    XCTAssertNil(empty.anchor)
    XCTAssertNil(empty.activeToken)
    empty.play()
    XCTAssertEqual(empty.state, .paused)
    empty.nextPassage()
    empty.previousPassage()
    empty.seek(to: 5)
    empty.restart()
    XCTAssertEqual(empty.tokenIndex, 0)
    XCTAssertNil(empty.lastConfirmedTokenIndex)
    // Cue-only text is the same as empty.
    let cues = record("[INTRO MUSIC]\n\n[CUT TO CAMERA B]")
    empty.present(record: cues, settings: manual)
    XCTAssertTrue(empty.document.spokenTokens.isEmpty)
    XCTAssertEqual(empty.document.blocks.flatMap(\.stageDirections).map(\.text), ["INTRO MUSIC", "CUT TO CAMERA B"])
    empty.play()
    XCTAssertEqual(empty.state, .paused)
    // Typing words into it gives it an anchor at the top.
    var typed = cues
    typed.markdown = "[INTRO MUSIC]\n\nBonjour tout le monde"
    typed.metadata.revision += 1
    empty.applyEditedRecord(typed)
    XCTAssertEqual(empty.activeToken?.text, "Bonjour")

    // One word: speaking it dims it, and that is the end of the script.
    let (store, _) = try await presenting("Bonjour")
    let one = store.session
    one.play(captureAudio: false)
    await Dictation(one, generation: 1).say("bonjour")
    XCTAssertEqual(one.lastConfirmedTokenIndex, 0)
    XCTAssertEqual(one.tokenIndex, 0)
    XCTAssertEqual(one.acceptedWords, 1)
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    XCTAssertEqual(surface.wronglyDimmed(one), [])
    XCTAssertTrue(surface.activeWordIsOnGuide(one))
    one.restart()
    await surface.settle()
    XCTAssertNil(one.lastConfirmedTokenIndex)
    XCTAssertEqual(surface.wronglyDimmed(one), [], "restart undims the word")

    // Headings and cues only: headings are read, cues are skipped, passages step over cues.
    let outline = "# Barça v PSG\n\n[INTRO MUSIC]\n\n## First half\n\n[CUT TO CAMERA B]\n\n### Verdict"
    let (outlineStore, _) = try await presenting(outline)
    let headings = outlineStore.session
    XCTAssertEqual(headings.document.spokenTokens.map(\.text), ["Barça", "v", "PSG", "First", "half", "Verdict"])
    headings.nextPassage()
    XCTAssertEqual(headings.activeToken?.text, "First")
    headings.nextPassage()
    XCTAssertEqual(headings.activeToken?.text, "Verdict")
    headings.restart()
    let outlineSurface = Surface(store: outlineStore)
    defer { outlineSurface.close() }
    await outlineSurface.settle()
    headings.play(captureAudio: false)
    let reader = Dictation(headings, generation: 1)
    for phrase in ["Barca v PSG", "first half", "verdict"] {
      await reader.say(phrase)
      await outlineSurface.settle()
      XCTAssertEqual(outlineSurface.wronglyDimmed(headings), [], "after '\(phrase)'")
    }
    XCTAssertEqual(headings.lastConfirmedTokenIndex, 5)
    let drawn = outlineSurface.text.string as NSString
    let cue = drawn.range(of: "[INTRO MUSIC]")
    XCTAssertNotEqual(cue.location, NSNotFound)
    XCTAssertEqual(outlineSurface.alpha(at: cue.location + 1), 0, accuracy: 0.01, "hidden cues stay hidden")
  }

  // MARK: Transport

  func testPlayPauseResumeRestartAndStop() async throws {
    let (store, record) = try await presenting(try fixture("173 script.md"))
    let session = store.session
    let tokens = session.document.spokenTokens
    session.play(captureAudio: false)
    XCTAssertEqual(session.state, .running)
    let first = Dictation(session, generation: 1)
    await first.say("Barcelona will not win the Champions League")
    XCTAssertEqual(session.lastConfirmedTokenIndex, 6)
    XCTAssertEqual(session.tokenIndex, 7)
    XCTAssertEqual(session.acceptedWords, 7)

    // Pause holds everything, and speech while paused moves nothing.
    let anchor = session.anchor
    session.pause()
    XCTAssertEqual(session.state, .paused)
    await first.say("because of Hansi Flick's stubbornness")
    XCTAssertEqual(session.tokenIndex, 7)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 6)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.acceptedWords, 7)

    // Resume carries on from the anchor with the recogniser's next generation.
    session.play(captureAudio: false)
    XCTAssertEqual(session.state, .running)
    XCTAssertEqual(session.anchor, anchor)
    let resumed = Dictation(session, generation: 2, startingAt: 10)
    await resumed.say("because of Hansi Flick's stubbornness")
    XCTAssertEqual(tokens[try XCTUnwrap(session.lastConfirmedTokenIndex)].text, "stubbornness")
    XCTAssertEqual(session.acceptedWords, 12)

    // Toggle pauses a running session (its play half needs a microphone, so it is not used here).
    session.toggle()
    XCTAssertEqual(session.state, .paused)
    session.play(captureAudio: false)

    // Restart is explicit: top of the script, nothing dimmed, paused.
    let revision = session.seekRevision
    session.restart()
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertNil(session.lastConfirmedTokenIndex)
    XCTAssertEqual(session.seekRevision, revision + 1)
    XCTAssertEqual(session.anchor?.tokenOffset, 0)
    XCTAssertEqual(session.anchor?.blockID, session.document.blocks.first?.id)
    session.play(captureAudio: false)
    await Dictation(session, generation: 3, startingAt: 20).say("Barcelona will not win")
    XCTAssertEqual(session.lastConfirmedTokenIndex, 3, "reading from the top again works")

    // Stop ends the session; there is nothing left to play until a script is presented.
    session.stop()
    XCTAssertEqual(session.state, .stopped)
    XCTAssertNil(session.activeRecord)
    XCTAssertNil(session.anchor)
    session.play(captureAudio: false)
    XCTAssertEqual(session.state, .stopped)
    session.toggle()
    XCTAssertEqual(session.state, .stopped)
    session.present(record: record, settings: store.settings)
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertNil(session.lastConfirmedTokenIndex)
  }

  // MARK: Speech progress

  /// Both real scripts read end to end through the production tracker with dual-locale
  /// dictation: words dim in reading order, never ahead of the reader, never backwards.
  func testReadingTheRealScriptsDimsInOrderNeverAheadAndNeverBack() throws {
    for name in ["172 script.md", "173 script.md"] {
      let document = PrompterDocument(markdown: try fixture(name))
      let result = replay(document)
      XCTAssertEqual(result.final, document.spokenTokens.count - 1, "\(name) did not reach the end")
      XCTAssertEqual(result.ahead, [], "\(name) dimmed words not yet spoken")
      XCTAssertEqual(result.backwards, [], "\(name) moved backwards during a straight read")
      // 173 reads stats: "10 goals from an xG of 5.4 and put away". Every token of "from an
      // xG of 5.4 and" is two letters, a digit or filler, so the at-once tail credit refuses the
      // run and six spoken words stay bright until "put".
      XCTExpectFailure("BUG: contiguous runs of numbers and two-letter words are never credited at once", enabled: name.hasPrefix("173")) {
        XCTAssertLessThanOrEqual(result.worstLag, 4, "\(name) held words back: \(result.worstAt)")
      }
      print("[core-qa] \(name): \(document.spokenTokens.count) tokens, worst lag \(result.worstLag) words, \(result.worstAt)")
    }
  }

  /// The same through the session and the presenter's own text view: after every phrase the
  /// words said are dimmed, the rest are not, the last confirmed word never goes back, and the
  /// next word ends up on the guide.
  func testSessionDimsSpokenWordsOnThePresenterInOrder() async throws {
    let (store, _) = try await presenting(try fixture("173 script.md"))
    let session = store.session
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    session.play(captureAudio: false)
    let reader = Dictation(session, generation: 1)
    let phrases = [
      "Barcelona will not win", "the Champions League because", "of Hansi Flick's stubbornness",
      "and insistence on playing", "with an offside trap",
    ]
    var previous = -1
    var said = 0
    for phrase in phrases {
      await reader.say(phrase)
      said += PrompterDocument(markdown: phrase).spokenTokens.count
      let confirmed = try XCTUnwrap(session.lastConfirmedTokenIndex, phrase)
      XCTAssertGreaterThanOrEqual(confirmed, previous)
      XCTAssertEqual(confirmed, said - 1, "'\(phrase)' should dim exactly the words said")
      await surface.settle()
      XCTAssertEqual(surface.wronglyDimmed(session), [], "after '\(phrase)'")
      previous = confirmed
    }
    reader.breath()
    for phrase in ["And before all you Barça fans", "get upset and emotional"] {
      await reader.say(phrase)
      said += PrompterDocument(markdown: phrase).spokenTokens.count
      XCTAssertEqual(session.lastConfirmedTokenIndex, said - 1, phrase)
    }
    await surface.settle(animations: true)
    XCTAssertEqual(surface.wronglyDimmed(session), [])
    XCTAssertTrue(surface.activeWordIsOnGuide(session), "the next word to read sits on the guide")
  }

  // MARK: Punctuation and cues

  func testPunctuationAndBracketCuesNeverBlockProgress() async throws {
    let markdown = """
      [WALK IN] Right — so, here’s the thing… Barça’s "G/A" is 2.88 per game (yes, 2.88!).

      [PAUSE]

      [LOOK AT CAMERA B]

      Mbappé’s 50% conversion; the one-on-ones [BEAT] keep coming — see [the stats](https://example.com/stats) — and that's the 2024-25 story.
      """
    let (store, _) = try await presenting(markdown)
    let session = store.session
    XCTAssertEqual(
      session.document.blocks.flatMap(\.stageDirections).map(\.text),
      ["WALK IN", "PAUSE", "LOOK AT CAMERA B", "BEAT"], "the link is not a cue")
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    session.play(captureAudio: false)
    let reader = Dictation(session, generation: 1)
    var said = 0
    for phrase in [
      "Right so here's the thing", "Barça's G/A is 2.88 per game", "yes 2.88",
      "Mbappé's 50% conversion", "the one-on-ones keep coming", "see the stats",
      "and that's the 2024-25 story",
    ] {
      await reader.say(phrase)
      said += PrompterDocument(markdown: phrase).spokenTokens.count
      XCTAssertEqual(session.lastConfirmedTokenIndex, said - 1, "'\(phrase)' was held up")
    }
    XCTAssertEqual(said, session.document.spokenTokens.count)
    await surface.settle()
    XCTAssertEqual(surface.wronglyDimmed(session), [])
    let drawn = surface.text.string as NSString
    for cue in ["[WALK IN]", "[PAUSE]", "[BEAT]"] {
      let range = drawn.range(of: cue)
      XCTAssertNotEqual(range.location, NSNotFound, cue)
      XCTAssertEqual(surface.alpha(at: range.location + 1), 0, accuracy: 0.01, "\(cue) must stay hidden after reading past it")
    }
    // Shown cues are dimmed, not read.
    store.settings.showCues = true
    session.updateSettings(store.settings)
    await surface.settle()
    let beat = (surface.text.string as NSString).range(of: "[BEAT]")
    XCTAssertEqual(surface.alpha(at: beat.location + 1), 0.42, accuracy: 0.02)
  }

  // MARK: Manual scroll-back

  /// Scrolling back by hand re-anchors on the word at the guide; the reader re-reads from
  /// there and tracking carries on, first inside the same dictation range, then after a pause.
  func testManualScrollBackReanchorsAndTrackingContinues() async throws {
    let (store, _) = try await presenting(try fixture("173 script.md"))
    let session = store.session
    let tokens = session.document.spokenTokens
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    session.play(captureAudio: false)
    let reader = Dictation(session, generation: 1)
    let opening = readableIndices(session.document).prefix(70).map { tokens[$0].text }
    for chunk in stride(from: 0, to: opening.count, by: 7) {
      await reader.say(opening[chunk..<min(opening.count, chunk + 7)].joined(separator: " "))
    }
    XCTAssertEqual(session.lastConfirmedTokenIndex, 69)
    await surface.settle(animations: true)
    let scroll = surface.scroll
    let before = scroll.contentView.bounds.origin
    XCTAssertGreaterThan(before.y, 200, "seventy words in, the script has scrolled")
    let revision = session.seekRevision

    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.setBoundsOrigin(NSPoint(x: before.x, y: before.y - 180))
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    let anchor = session.tokenIndex
    XCTAssertLessThan(anchor, 60, "scrolling back moved the anchor back")
    XCTAssertGreaterThan(anchor, 0)
    XCTAssertEqual(session.seekRevision, revision + 1)
    XCTAssertEqual(session.lastConfirmedTokenIndex, anchor - 1)
    XCTAssertTrue(session.isActivelyRunning, "scrolling does not stop tracking")
    await surface.settle()
    XCTAssertEqual(surface.wronglyDimmed(session), [], "words from the new anchor on are unread again")
    XCTAssertTrue(surface.activeWordIsOnGuide(session))

    // The same dictation range carries on with the re-read: its first result past the scroll
    // is taken as a baseline, then new words are credited from the anchor, not from word 69.
    let reread = (anchor..<anchor + 12).map { tokens[$0].text }
    await reader.say(reread[0..<6].joined(separator: " "))
    XCTAssertEqual(session.tokenIndex, anchor, "stale audio did not throw the reader forward")
    await reader.say(reread[6..<12].joined(separator: " "))
    XCTAssertEqual(session.lastConfirmedTokenIndex, anchor + 11)

    // After a breath, a fresh range re-reads onwards and progress passes the old position.
    reader.breath()
    let onwards = readableIndices(session.document).filter { $0 >= anchor + 12 && $0 < 90 }.map { tokens[$0].text }
    for chunk in stride(from: 0, to: onwards.count, by: 6) {
      await reader.say(onwards[chunk..<min(onwards.count, chunk + 6)].joined(separator: " "))
    }
    XCTAssertEqual(session.lastConfirmedTokenIndex, 89)
    await surface.settle(animations: true)
    XCTAssertEqual(surface.wronglyDimmed(session), [])
    XCTAssertTrue(surface.activeWordIsOnGuide(session))
  }

  // MARK: Live appearance

  /// Font size, font family, text width, guide position and guide opacity change live: the
  /// anchor, the confirmed word, the run state and the seek revision stay put, and the next word
  /// is back on the (possibly moved) guide.
  func testAppearanceChangesLiveWithoutResettingTheAnchor() async throws {
    let (store, _) = try await presenting(try fixture("173 script.md"))
    let session = store.session
    store.settings.fontName = "Helvetica"
    session.updateSettings(store.settings)
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    session.play(captureAudio: false)
    let reader = Dictation(session, generation: 1)
    let opening = readableIndices(session.document).prefix(42).map { session.document.spokenTokens[$0].text }
    for chunk in stride(from: 0, to: opening.count, by: 6) {
      await reader.say(opening[chunk..<chunk + 6].joined(separator: " "))
    }
    await surface.settle(animations: true)
    let index = session.tokenIndex
    let confirmed = session.lastConfirmedTokenIndex
    let anchor = try XCTUnwrap(session.anchor)
    let revision = session.seekRevision
    XCTAssertEqual(confirmed, 41)
    XCTAssertTrue(surface.activeWordIsOnGuide(session))

    let changes: [(String, (inout PrompterSettings) -> Void)] = [
      ("font size", { $0.fontSize = 64 }),
      ("font family", { $0.fontName = "Georgia" }),
      ("text width", { $0.textWidth = 0.5 }),
      ("guide position", { $0.guideFraction = 0.62 }),
      ("guide opacity", { $0.guideOpacity = 0.3 }),
      ("smaller again", { $0.fontSize = 30; $0.textWidth = 0.8; $0.guideFraction = 0.2 }),
    ]
    for (name, change) in changes {
      let guideBefore = store.settings.guideFraction
      change(&store.settings)
      session.updateSettings(store.settings)
      // Re-renders and width changes snap; a moved guide eases there while reading.
      await surface.settle(animations: store.settings.guideFraction != guideBefore)
      XCTAssertEqual(session.tokenIndex, index, name)
      XCTAssertEqual(session.lastConfirmedTokenIndex, confirmed, name)
      XCTAssertEqual(session.anchor?.blockID, anchor.blockID, name)
      XCTAssertEqual(session.anchor?.tokenOffset, anchor.tokenOffset, name)
      XCTAssertEqual(session.anchor?.guideFraction, store.settings.guideFraction, name)
      XCTAssertEqual(session.seekRevision, revision, name)
      XCTAssertTrue(session.isActivelyRunning, name)
      XCTAssertTrue(surface.activeWordIsOnGuide(session), "\(name): the next word left the guide")
    }
    // Reading carries on after all of it.
    let next = readableIndices(session.document).filter { $0 >= 42 && $0 < 48 }.map { session.document.spokenTokens[$0].text }
    await reader.say(next.joined(separator: " "))
    XCTAssertEqual(session.lastConfirmedTokenIndex, 47)
  }

  /// Words already read stay dimmed when the presenter re-renders (any appearance change, an
  /// edit, or a fresh presenter view after closing, reopening or finishing an in-place edit).
  /// `Coordinator.render` repaints every word bright and forgets the last painted state, and
  /// `updateReadState` then only repaints between the last confirmed word and the next one.
  func testReadWordsStayDimmedAfterARenderOrAFreshPresenterView() async throws {
    let (store, record) = try await presenting(try fixture("173 script.md"))
    let session = store.session
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    session.play(captureAudio: false)
    let reader = Dictation(session, generation: 1)
    for phrase in ["Barcelona will not win the Champions League", "because of Hansi Flick's stubbornness"] {
      await reader.say(phrase)
    }
    await surface.settle()
    XCTAssertEqual(session.lastConfirmedTokenIndex, 11)
    XCTAssertEqual(surface.wronglyDimmed(session), [], "dimmed correctly before any re-render")

    store.settings.fontSize = 60
    session.updateSettings(store.settings)
    await surface.settle()
    let afterFont = surface.wronglyDimmed(session)
    XCTExpectFailure("BUG: a font change re-renders every read word bright") {
      XCTAssertEqual(afterFont, [], "after a font size change")
    }

    var edited = record
    edited.markdown = session.document.markdown.replacingOccurrences(of: "offside trap.", with: "offside trap!")
    edited.metadata.revision += 1
    session.applyEditedRecord(edited)
    await surface.settle()
    XCTAssertEqual(session.lastConfirmedTokenIndex, 11, "an edit after the anchor keeps the confirmed word")
    let afterEdit = surface.wronglyDimmed(session)
    XCTExpectFailure("BUG: an edit re-renders every read word bright") {
      XCTAssertEqual(afterEdit, [], "after an edit")
    }

    let reopened = Surface(store: store)
    defer { reopened.close() }
    await reopened.settle()
    let afterReopen = reopened.wronglyDimmed(session)
    XCTExpectFailure("BUG: a fresh presenter view (reopen, end of in-place edit) shows read words bright") {
      XCTAssertEqual(afterReopen, [], "in a fresh presenter view")
    }
  }

  // MARK: Mirror and rotation

  func testMirrorAndRotationKeepTheCurrentPassageOnTheGuide() async throws {
    let (store, _) = try await presenting(try fixture("173 script.md"), mode: "Manual")
    let session = store.session
    store.settings.fontName = "Helvetica"
    session.updateSettings(store.settings)
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    session.seek(to: try index(of: "Brugge", in: session))
    session.play()
    await surface.settle(animations: true)
    let anchor = session.anchor
    XCTAssertTrue(surface.activeWordIsOnGuide(session))
    for (horizontal, vertical, rotation) in [
      (true, false, 0), (false, true, 0), (false, false, 180), (true, false, 180), (false, true, 180),
      (true, true, 0), (false, false, 0),
    ] {
      let label = "h=\(horizontal) v=\(vertical) r=\(rotation)"
      store.settings.horizontalMirror = horizontal
      store.settings.verticalMirror = vertical
      store.settings.rotation = rotation
      session.updateSettings(store.settings)
      await surface.settle()  // a flip snaps; a horizontal-only mirror needs no realignment
      XCTAssertEqual(session.anchor?.blockID, anchor?.blockID, label)
      XCTAssertEqual(session.anchor?.tokenOffset, anchor?.tokenOffset, label)
      XCTAssertEqual(session.activeToken?.text, "Brugge", label)
      XCTAssertTrue(session.isActivelyRunning, label)
      XCTAssertTrue(surface.activeWordIsOnGuide(session), "\(label): the passage left the guide")
    }
  }

  // MARK: In-place editing

  /// The presenter's pencil: edits before, inside and after the anchored passage are finished,
  /// saved to disk, keep the reader on the same word and resume reading; speech then carries on.
  func testInPlaceEditsBeforeAtAndAfterTheAnchorCommitAndCarryOn() async throws {
    let original = try fixture("173 script.md")
    let edits: [(String, String)] = [
      ("before", original.replacingOccurrences(
        of: "And before all you Barça fans", with: "Quick note first.\n\nAnd before all of you Barça fans")),
      ("at", original.replacingOccurrences(
        of: "averaging 2.88 goals per game. Higher than", with: "averaging a remarkable 2.88 goals per game. That is higher than")),
      ("after", original.replacingOccurrences(
        of: "they will not win the Champions League.", with: "they will never win the Champions League. Subscribe.")),
    ]
    for (name, edited) in edits {
      XCTAssertNotEqual(edited, original, name)
      let (store, record) = try await presenting(original, mode: "Manual")
      let session = store.session
      let target = try index(of: "Bayern’s", in: session)
      session.seek(to: target)
      session.play()
      let draft = PresenterDraft(record: try XCTUnwrap(session.activeRecord))
      draft.begin(session: session)
      XCTAssertTrue(draft.isEditing, name)
      XCTAssertFalse(session.isActivelyRunning, "\(name): editing pauses reading")
      draft.markdown = edited
      await draft.confirm(store: store)
      XCTAssertNil(draft.errorMessage, name)
      XCTAssertFalse(draft.isEditing, name)
      XCTAssertTrue(session.isActivelyRunning, "\(name): finishing resumes reading")
      let saved = try await XCTUnwrap(store.library).read(record.id)
      XCTAssertEqual(saved.markdown, edited, "\(name): saved to disk")
      XCTAssertEqual(session.document.markdown, edited, name)
      XCTAssertEqual(session.activeToken?.normalised, "bayern's", "\(name): anchor moved")
      let at = session.tokenIndex
      XCTAssertEqual(session.document.spokenTokens[at - 1].normalised, "than", name)
      XCTAssertEqual(session.document.spokenTokens[at + 1].normalised, "2", name)
      XCTAssertNil(session.anchorNotice, name)

      // Recognition carries on from the same word.
      session.pause()
      store.settings.mode = "Voice"
      session.updateSettings(store.settings)
      session.play(captureAudio: false)
      await Dictation(session, generation: 9).say("Bayern's 2.64 and PSG's 2.44")
      XCTAssertEqual(session.document.spokenTokens[try XCTUnwrap(session.lastConfirmedTokenIndex)].normalised, "44", name)
      XCTAssertEqual(session.lastConfirmedTokenIndex, at + 6, name)
      let flushed = await store.flushPendingSaves()
      XCTAssertTrue(flushed, name)
    }
  }

  /// Adding a paragraph break inside the passage being read is an ordinary in-place edit. Whichever
  /// half keeps the block's identity, the anchor follows its word, even into the other half.
  func testSplittingTheCurrentPassageKeepsTheAnchorOnTheSameWord() async throws {
    let original = try fixture("173 script.md")
    let edited = original.replacingOccurrences(of: "per game. Higher than", with: "per game.\n\nHigher than")
    XCTAssertNotEqual(edited, original)
    let (store, record) = try await presenting(original, mode: "Manual")
    let session = store.session
    session.seek(to: try index(of: "Bayern’s", in: session))
    let draft = PresenterDraft(record: try XCTUnwrap(session.activeRecord))
    draft.begin(session: session)
    draft.markdown = edited
    await draft.confirm(store: store)
    XCTAssertNil(draft.errorMessage)
    let saved = try await XCTUnwrap(store.library).read(record.id)
    XCTAssertEqual(saved.markdown, edited)
    XCTAssertEqual(session.activeToken?.text, "Bayern’s")
    // The same when the reader is in the first half and the second half keeps the identity.
    let (other, _) = try await presenting(
      "Short opener here.\n\nAlpha beta gamma delta one two three four five six seven eight nine ten", mode: "Manual")
    other.session.seek(to: try index(of: "gamma", in: other.session))
    var split = try XCTUnwrap(other.session.activeRecord)
    split.markdown = "Short opener here.\n\nAlpha beta gamma\n\ndelta one two three four five six seven eight nine ten"
    split.metadata.revision += 1
    other.session.applyEditedRecord(split)
    XCTAssertEqual(other.session.activeToken?.text, "gamma")
    XCTAssertNil(other.session.anchorNotice)
  }

  /// Splits after the anchored word and merges of two paragraphs, whichever block keeps the
  /// identity: the anchor stays on its word and no passage is reported deleted.
  func testSplittingAfterAndMergingAroundTheAnchorKeepTheSameWord() async throws {
    let opener = "Short opener here."
    let long = "Alpha beta gamma delta one two three four five six seven eight nine ten"
    let original = "\(opener)\n\n\(long)"
    let edits: [(name: String, word: String, markdown: String)] = [
      ("split after, second half keeps the identity", "gamma",
       "\(opener)\n\nAlpha beta gamma delta\n\none two three four five six seven eight nine ten"),
      ("split after, first half keeps the identity", "two",
       "\(opener)\n\nAlpha beta gamma delta one two three four five six seven\n\neight nine ten"),
      ("merge, anchored paragraph loses the identity", "opener", "\(opener) \(long)"),
      ("merge, anchored paragraph keeps the identity", "gamma", "\(opener) \(long)"),
    ]
    for edit in edits {
      let (store, _) = try await presenting(original, mode: "Manual")
      let session = store.session
      session.seek(to: try index(of: edit.word, in: session))
      var edited = try XCTUnwrap(session.activeRecord)
      edited.markdown = edit.markdown
      edited.metadata.revision += 1
      session.applyEditedRecord(edited)
      XCTAssertEqual(session.document.markdown, edit.markdown, edit.name)
      XCTAssertEqual(session.activeToken?.text, edit.word, edit.name)
      XCTAssertNil(session.anchorNotice, edit.name)
    }
  }

  func testCancellingAnInPlaceEditLeavesScriptAnchorAndDiskAlone() async throws {
    let original = try fixture("172 script.md")
    let (store, record) = try await presenting(original, mode: "Manual")
    let session = store.session
    session.seek(to: try index(of: "Kane", in: session, occurrence: 2))
    session.play()
    let anchor = session.anchor
    let draft = PresenterDraft(record: try XCTUnwrap(session.activeRecord))
    draft.begin(session: session)
    draft.markdown = "Everything replaced."
    draft.requestCancel()
    XCTAssertTrue(draft.closeRequested, "typed edits ask before they are thrown away")
    XCTAssertTrue(draft.isEditing)
    draft.cancel(resuming: !draft.discardCloses)
    XCTAssertFalse(draft.isEditing)
    XCTAssertTrue(session.isActivelyRunning, "cancelling carries on reading")
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertEqual(session.document.markdown, original)
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    let disk = try await XCTUnwrap(store.library).read(record.id)
    XCTAssertEqual(disk.markdown, original)
    draft.begin(session: session)
    XCTAssertEqual(draft.markdown, original, "the next edit starts from the script, not the discarded draft")
    draft.cancel(resuming: false)
  }

  // MARK: Video background

  func testTheVideoToggleDuringASessionKeepsTheAnchorAndTheSession() async throws {
    let (store, _) = try await presenting(try fixture("173 script.md"))
    let session = store.session
    let suite = "JuniorPrompterCoreQA.camera.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let camera = CameraModel(defaults: UserDefaults(suiteName: suite)!)
    let controller = PresenterController()
    session.play(captureAudio: false)
    let reader = Dictation(session, generation: 1)
    await reader.say("Barcelona will not win the Champions League")
    var said = 7
    for (on, phrase) in [(true, "because of Hansi Flick's stubbornness"), (false, "and insistence on playing"),
                         (true, "with an offside trap")] {
      let before = (session.tokenIndex, session.lastConfirmedTokenIndex, session.anchor, session.seekRevision)
      camera.presentsWithVideo = on
      controller.videoDidChange(on)  // what the presenter's onChange does; no panel, so no resize
      try? await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(session.tokenIndex, before.0)
      XCTAssertEqual(session.lastConfirmedTokenIndex, before.1)
      XCTAssertEqual(session.anchor, before.2)
      XCTAssertEqual(session.seekRevision, before.3)
      XCTAssertEqual(session.state, .running, "video \(on) must not touch speech tracking")
      XCTAssertEqual(store.settings.backdropOpacity(withVideo: camera.presentsWithVideo), on ? 0.25 : 0.82)
      await reader.say(phrase)
      said += PrompterDocument(markdown: phrase).spokenTokens.count
      XCTAssertEqual(session.lastConfirmedTokenIndex, said - 1, "tracking continued with video \(on)")
    }
    XCTAssertTrue(CameraModel(defaults: UserDefaults(suiteName: suite)!).presentsWithVideo)
  }

  // MARK: Full screen

  func testFullScreenStateFlags() {
    let panel = PresenterController.configuredPanel()
    XCTAssertTrue(panel.styleMask.contains(.resizable))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenPrimary))
    XCTAssertFalse(panel.styleMask.contains(.fullScreen), "a new presenter is windowed")
    XCTAssertFalse(panel.isReleasedWhenClosed, "closing keeps the panel for the next present")
    XCTAssertFalse(panel.hidesOnDeactivate)
    let controller = PresenterController()
    let flag = { Mirror(reflecting: controller).children.first { $0.label == "closesAfterFullScreen" }?.value as? Bool }
    XCTAssertEqual(flag(), false)
    // Enter, exit, fail, enter, exit: the level always matches the Space the presenter is in.
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: panel))
    XCTAssertEqual(panel.level, .normal)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: panel))
    XCTAssertEqual(panel.level, .floating)
    XCTAssertEqual(flag(), false, "an ordinary exit does not close")
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: panel))
    controller.windowDidFailToEnterFullScreen(panel)
    XCTAssertEqual(panel.level, .floating)
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: panel))
    XCTAssertEqual(panel.level, .normal)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: panel))
    XCTAssertEqual(panel.level, .floating)
    // Without a presented panel the full-screen command and close are harmless no-ops.
    controller.toggleFullScreen()
    controller.closeNow()
    XCTAssertTrue(controller.windowShouldClose(panel), "no open edit, so the close button closes")
    XCTAssertTrue(PresenterController.fitsToCamera(videoOn: true, fullScreen: false))
    XCTAssertFalse(PresenterController.fitsToCamera(videoOn: true, fullScreen: true))
  }

  // MARK: Linked Markdown

  func testLinkedMarkdownEditedOnDiskUpdatesThePresentingScriptBothWays() async throws {
    let store = makeStore()
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("jp-core-qa-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
    let markdown = try fixture("173 script.md")
    let file = outside.appendingPathComponent("173 — Short.md")
    try Data(markdown.utf8).write(to: file)
    let library = try XCTUnwrap(store.library)
    let created = try await library.create(title: "173", markdown: markdown)
    _ = try await library.link(created.id, to: file)
    await store.reload()
    store.selectedID = created.id
    let session = store.session
    session.present(record: try XCTUnwrap(store.selected), settings: store.settings)
    let surface = Surface(store: store)
    defer { surface.close() }
    session.seek(to: try index(of: "Cancelo", in: session))
    await surface.settle()

    // MarkEdit: a new paragraph before the anchor, a changed word after it.
    let external = markdown
      .replacingOccurrences(of: "So let's consider", with: "So let’s properly consider")
      .replacingOccurrences(of: "Of the 15 signings", with: "A quick aside on transfers.\n\nOf the 15 signings")
    try Data(external.utf8).write(to: file, options: .atomic)
    await store.refreshExternalChanges()
    XCTAssertNil(store.errorMessage)
    XCTAssertEqual(store.selected?.markdown, external)
    XCTAssertEqual(session.document.markdown, external, "the presenting script updates live")
    XCTAssertEqual(session.activeToken?.text, "Cancelo", "the anchor follows the passage")
    XCTAssertNil(session.anchorNotice)
    await surface.settle()
    XCTAssertTrue(surface.text.string.contains("A quick aside on transfers."), "the presenter shows the new text")
    XCTAssertTrue(surface.activeWordIsOnGuide(session))

    // Reading carries on from there.
    session.play(captureAudio: false)
    await Dictation(session, generation: 4).say("Cancelo is notoriously not all that good defensively")
    XCTAssertEqual(session.activeToken?.text, "And", "the word after 'defensively'")

    // An in-place edit goes back out to the file.
    store.settings.mode = "Manual"
    session.pause()
    session.updateSettings(store.settings)
    let draft = PresenterDraft(record: try XCTUnwrap(session.activeRecord))
    draft.begin(session: session)
    let inApp = draft.markdown.replacingOccurrences(of: "I believe that", with: "I firmly believe that")
    draft.markdown = inApp
    await draft.confirm(store: store)
    XCTAssertNil(draft.errorMessage)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), inApp, "written back to the linked file")
    await store.refreshExternalChanges()
    XCTAssertNil(store.errorMessage, "our own write-back is not a conflict")

    // And a second external edit still arrives.
    let again = inApp.replacingOccurrences(of: "Yes, they missed", with: "Yes, admittedly, they missed")
    try Data(again.utf8).write(to: file, options: .atomic)
    await store.refreshExternalChanges()
    XCTAssertEqual(session.document.markdown, again)
    XCTAssertEqual(session.document.spokenTokens[session.tokenIndex - 1].text, "defensively")
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
  }

  // MARK: Switching scripts, closing and reopening

  func testSwitchingScriptsWhilePresenting() async throws {
    let store = makeStore()
    let library = try XCTUnwrap(store.library)
    let first = try await library.create(title: "172", markdown: try fixture("172 script.md"))
    let second = try await library.create(title: "173", markdown: try fixture("173 script.md"))
    await store.reload()
    let session = store.session
    store.selectedID = first.id
    session.present(record: try XCTUnwrap(store.selected), settings: store.settings)
    session.play(captureAudio: false)
    await Dictation(session, generation: 1).say("Kylian Mbappé does not deserve the Ballon d'Or")
    XCTAssertEqual(session.lastConfirmedTokenIndex, 7)

    store.selectedID = second.id
    session.present(record: try XCTUnwrap(store.selected), settings: store.settings)
    XCTAssertEqual(session.activeScriptID, second.id)
    XCTAssertEqual(session.document.markdown, second.markdown)
    XCTAssertEqual(session.state, .paused, "a new script waits for play")
    XCTAssertEqual(session.tokenIndex, 0)
    XCTAssertNil(session.lastConfirmedTokenIndex, "nothing of the new script is read")
    XCTAssertEqual(session.anchor?.scriptID, second.id)
    XCTAssertEqual(session.acceptedWords, 0)
    let surface = Surface(store: store)
    defer { surface.close() }
    await surface.settle()
    XCTAssertEqual(surface.wronglyDimmed(session), [])
    XCTAssertTrue(surface.text.string.hasPrefix("Barcelona will not win"))

    session.play(captureAudio: false)
    await Dictation(session, generation: 2, startingAt: 5).say("Barcelona will not win")
    XCTAssertEqual(session.lastConfirmedTokenIndex, 3)
    // An edit to the other script does not reach this session.
    store.updateMarkdown("Kylian Mbappé deserves nothing.", for: first.id)
    XCTAssertEqual(session.document.markdown, second.markdown)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 3)
    XCTAssertTrue(session.isActivelyRunning)
    XCTAssertEqual(PresenterDraft(record: try XCTUnwrap(session.activeRecord)).recordID, second.id)

    // Back to the first script: its latest text, from the top.
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    store.selectedID = first.id
    session.present(record: try XCTUnwrap(store.selected), settings: store.settings)
    XCTAssertEqual(session.document.markdown, "Kylian Mbappé deserves nothing.")
    XCTAssertEqual(session.tokenIndex, 0)
  }

  /// A notice about one script ("the current passage was deleted", "choose an audio input")
  /// must not be shown over the next script presented.
  func testSwitchingScriptsClearsTheOldScriptsNotice() {
    let session = SessionStore()
    var manual = PrompterSettings()
    manual.mode = "Manual"
    var first = record("Opening words.\n\nThe passage being read right now.\n\nClosing words.", title: "One")
    session.present(record: first, settings: manual)
    session.seek(to: 4)
    first.markdown = "Opening words.\n\nClosing words."
    first.metadata.revision += 1
    session.applyEditedRecord(first)
    XCTAssertNotNil(session.anchorNotice, "deleting the read passage says so")
    session.present(record: record("A different script altogether.", title: "Two"), settings: manual)
    let notice = session.anchorNotice
    XCTExpectFailure("BUG: present(record:) keeps the previous script's anchorNotice") {
      XCTAssertNil(notice)
    }
  }

  /// Closing mid-session pauses it and drops the presenter view; reopening presents the same
  /// script again and carries on from the same word, including edits made while closed.
  func testClosingMidSessionAndReopeningCarriesOn() async throws {
    let (store, _) = try await presenting(try fixture("173 script.md"))
    let session = store.session
    let surface = Surface(store: store)
    await surface.settle()
    session.play(captureAudio: false)
    await Dictation(session, generation: 1).say("Barcelona will not win the Champions League because of Hansi Flick's stubbornness")
    XCTAssertEqual(session.lastConfirmedTokenIndex, 11)
    let word = session.activeToken?.text

    // closeNow()
    session.pause()
    surface.close()
    XCTAssertEqual(session.state, .paused)

    // Fixed a typo in the library while the presenter was closed.
    let id = try XCTUnwrap(session.activeScriptID)
    let edited = session.document.markdown.replacingOccurrences(of: "please watch the video", with: "please do watch the video")
    store.updateMarkdown(edited, for: id)

    // present(): same script, current settings, fresh draft and view.
    session.present(record: try XCTUnwrap(store.selected), settings: store.settings)
    XCTAssertEqual(session.state, .paused, "reopening does not start reading")
    XCTAssertEqual(session.activeToken?.text, word)
    XCTAssertEqual(session.lastConfirmedTokenIndex, 11)
    XCTAssertEqual(session.document.markdown, edited)
    XCTAssertEqual(PresenterDraft(record: try XCTUnwrap(session.activeRecord)).markdown, edited)
    let reopened = Surface(store: store)
    defer { reopened.close() }
    await reopened.settle()
    XCTAssertTrue(reopened.activeWordIsOnGuide(session), "the reopened presenter shows the same place")

    session.play(captureAudio: false)
    await Dictation(session, generation: 2, startingAt: 10).say("and insistence on playing with an offside trap")
    XCTAssertEqual(session.lastConfirmedTokenIndex, 19)
    let flushed = await store.flushPendingSaves()
    XCTAssertTrue(flushed)
    let saved = try await XCTUnwrap(store.library).read(id)
    XCTAssertEqual(saved.markdown, edited)
  }

  // MARK: English and French

  /// Mixed within sentences: each engine hears its own language properly and garbles the
  /// other; between them every clause dims as it is said, in order, to the end.
  func testMixedEnglishFrenchScriptTracksThroughBothEngines() async throws {
    let markdown = """
      # Doué contre Yamal

      Désiré Doué est un joueur exceptionnel, and honestly he is a better Champions League player than Lamine Yamal.

      Je pense que le PSG peut gagner cette compétition because the team is playing with confiance, c’est évident.

      L’équipe de Luis Enrique n’a pas peur: they press, they recover, et ils marquent.
      """
    let (store, _) = try await presenting(markdown)
    let session = store.session
    XCTAssertTrue(session.document.spokenTokens.map(\.normalised).contains("l'equipe"))
    XCTAssertTrue(session.document.spokenTokens.map(\.normalised).contains("c'est"))
    session.play(captureAudio: false)
    let reader = Dictation(session, generation: 1)
    // (script words, English engine, French engine)
    let clauses: [(String, String, String)] = [
      ("Doué contre Yamal", "Doing contra Yamal", "Doué contre Yamal"),
      ("Désiré Doué est un joueur exceptionnel", "Desire do a stone jour exceptional", "Désiré Doué est un joueur exceptionnel"),
      ("and honestly he is a better", "and honestly he is a better", "et on est lit is a bête"),
      ("Champions League player than Lamine Yamal", "Champions League player than Lamine Yamal", "tchampion lige plé dans l'amine Yamal"),
      ("Je pense que le PSG peut gagner cette compétition", "Just pass K le PSG put ganya set competition", "Je pense que le PSG peut gagner cette compétition"),
      ("because the team is playing with", "because the team is playing with", "bi cause de tim is plein wiz"),
      ("confiance c’est évident", "confidence say it the dawn", "confiance c'est évident"),
      ("L’équipe de Luis Enrique n’a pas peur", "Lucky pay the Louise and Rica not pa per", "L'équipe de Luis Enrique n'a pas peur"),
      ("they press they recover", "they press they recover", "des presse des récoltes"),
      ("et ils marquent", "eh ill mark", "et ils marquent"),
    ]
    var said = 0
    var previous = -1
    var late: [String] = []
    for (script, english, french) in clauses {
      await reader.say(english, french: french)
      said += PrompterDocument(markdown: script).spokenTokens.count
      let confirmed = session.lastConfirmedTokenIndex ?? -1
      XCTAssertGreaterThanOrEqual(confirmed, previous, "went back at '\(script)'")
      XCTAssertLessThanOrEqual(confirmed, said - 1, "ran ahead at '\(script)'")
      if confirmed != said - 1 { late.append("'\(script)': \(said - 1 - confirmed) words behind") }
      previous = confirmed
    }
    XCTAssertEqual(session.lastConfirmedTokenIndex, session.document.spokenTokens.count - 1, "reached the end")
    XCTAssertEqual(late, [], "clauses not dimmed as they were said")
  }

  // MARK: Unicode names

  func testAccentedNamesAndCurlyApostrophesMatchWhateverTheRecogniserWrites() throws {
    let markdown = "Kylian Mbappé wants the Ballon d’Or, but Barça fans say Gerd Müller’s record and Atlético’s défense matter more."
    let tokens = PrompterDocument(markdown: markdown).spokenTokens
    XCTAssertEqual(tokens.map(\.text), [
      "Kylian", "Mbappé", "wants", "the", "Ballon", "d’Or", "but", "Barça", "fans", "say", "Gerd",
      "Müller’s", "record", "and", "Atlético’s", "défense", "matter", "more",
    ])
    let names = ["mbappe", "d'or", "barca", "muller's", "atletico's"]
    for spoken in [
      "Kylian Mbappé wants the Ballon d’Or but Barça fans say Gerd Müller’s record and Atlético’s défense matter more",
      "Kylian Mbappe wants the Ballon d'Or but Barca fans say Gerd Muller's record and Atletico's defense matter more",
      "KYLIAN MBAPPÉ WANTS THE BALLON D'OR BUT BARÇA FANS SAY GERD MÜLLER'S RECORD AND ATLÉTICO'S DÉFENSE MATTER MORE",
    ] {
      var tracker = RecognitionTracker(generation: 1, tokenIndex: 0)
      var words: [String] = []
      for (index, word) in spoken.split(separator: " ").enumerated() {
        words.append(String(word))
        let update = tracker.consume(.init(
          replacementID: "r", generation: 1, text: words.joined(separator: " "), isFinal: false,
          timestamp: Double(index), audioStart: 0, audioEnd: Double(index) + 0.3), script: tokens)
        XCTAssertLessThanOrEqual(update.tokenIndex, index, "\(spoken): ran ahead")
        if names.contains(tokens[index].normalised) {
          XCTAssertEqual(update.tokenIndex, index, "\(word) did not dim as it was said in '\(spoken)'")
        }
      }
      XCTAssertEqual(tracker.tokenIndex, tokens.count - 1, spoken)
    }
    XCTAssertEqual(unmappedWords(markdown).failures, [], "names are drawn as themselves")
  }

  /// Text from PDF extraction and some editors arrives decomposed (e + U+0301). It is the same
  /// text, but the tokeniser's `[\p{L}\p{N}]` stops at the combining mark, so "Désiré" becomes
  /// "De" + "sire" and never matches what the recogniser writes.
  func testDecomposedAccentsTokeniseLikeComposedOnes() {
    let composed = "Désiré Doué and Atlético’s défense beat Müller’s Bayern, says Barça."
    let decomposed = composed.decomposedStringWithCanonicalMapping
    XCTAssertNotEqual(composed.unicodeScalars.count, decomposed.unicodeScalars.count)
    XCTAssertEqual(composed, decomposed, "Swift already treats them as equal")
    let expected = PrompterDocument(markdown: composed).spokenTokens.map(\.normalised)
    let actual = PrompterDocument(markdown: decomposed).spokenTokens.map(\.normalised)
    XCTAssertEqual(actual, expected)
  }

  /// A decomposed name mid-sentence is one token spanning the whole decomposed word, and a
  /// recogniser writing composed (or unaccented) text dims it as it is said.
  func testDecomposedNamesInASentenceTrackAgainstComposedRecognition() {
    let markdown = "Tonight Désiré Doué and Atlético’s Julián Álvarez meet Müller."
      .decomposedStringWithCanonicalMapping
    let tokens = PrompterDocument(markdown: markdown).spokenTokens
    XCTAssertEqual(tokens.map(\.normalised), [
      "tonight", "desire", "doue", "and", "atletico's", "julian", "alvarez", "meet", "muller",
    ])
    let ns = markdown as NSString
    for token in tokens {
      XCTAssertEqual(
        ns.substring(with: NSRange(location: token.sourceRange.location, length: token.sourceRange.length)),
        token.text)
    }
    XCTAssertEqual(tokens[1].text.unicodeScalars.count, 8, "Désiré keeps both combining accents")
    for spoken in [
      "Tonight Désiré Doué and Atlético's Julián Álvarez meet Müller",
      "tonight desire doue and atletico's julian alvarez meet muller",
    ] {
      var tracker = RecognitionTracker(generation: 1, tokenIndex: 0)
      var words: [String] = []
      for (index, word) in spoken.split(separator: " ").enumerated() {
        words.append(String(word))
        let update = tracker.consume(.init(
          replacementID: "r", generation: 1, text: words.joined(separator: " "), isFinal: false,
          timestamp: Double(index), audioStart: 0, audioEnd: Double(index) + 0.3), script: tokens)
        XCTAssertLessThanOrEqual(update.tokenIndex, index, "\(spoken): ran ahead")
        if index > 0, tokens[index].text.unicodeScalars.contains(where: { $0.properties.isGraphemeExtend }) {
          XCTAssertEqual(update.tokenIndex, index, "\(word) did not dim as it was said in '\(spoken)'")
        }
      }
      XCTAssertEqual(tracker.tokenIndex, tokens.count - 1, spoken)
    }
    XCTAssertEqual(PrompterDocument.normalise("De\u{301}sire\u{301}"), PrompterDocument.normalise("Désiré"))
  }

  /// The library search box is where a script is found before it is presented. The library's
  /// own search folds accents; the store's visible list does not.
  func testFindingAScriptIgnoresAccents() async throws {
    let store = makeStore()
    let library = try XCTUnwrap(store.library)
    let script = try await library.create(title: "Barça offside trap", markdown: "Flick keeps the line high.")
    await store.reload()
    let found = try await library.search("barca").map(\.id)
    XCTAssertEqual(found, [script.id], "the library's search folds accents")
    store.search = "Barca"
    let visible = store.visible.map(\.id)
    XCTExpectFailure("BUG: AppStore.visible uses localizedCaseInsensitiveContains, which is accent-sensitive") {
      XCTAssertEqual(visible, [script.id])
    }
    store.search = "barça"
    XCTAssertEqual(store.visible.map(\.id), [script.id])
  }

  // MARK: Audio level

  func testAudioLevelMappingZonesMarksAndClipping() throws {
    let position = InputLevelMeter.position
    XCTAssertEqual(position(-60), 0)
    XCTAssertEqual(position(0), 1)
    XCTAssertEqual(position(-30), 0.5, accuracy: 0.0001)
    XCTAssertEqual(position(-12), 0.8, accuracy: 0.0001)
    XCTAssertEqual(position(-6), 0.9, accuracy: 0.0001)
    XCTAssertEqual(position(-20), 2.0 / 3.0, accuracy: 0.0001, "green ends at −20 dBFS")
    XCTAssertEqual(position(-9), 0.85, accuracy: 0.0001, "yellow ends at −9 dBFS")
    XCTAssertEqual(position(-90), 0, "below the scale pins to the left")
    XCTAssertEqual(position(4), 1, "over full scale pins to the right")
    XCTAssertEqual(position(-.infinity), 0, "silence")
    XCTAssertEqual(position(.nan), 0)
    let marks = InputLevelMeter.ticks.map(\.0)
    for mark: Float in [-12, -6, 0] { XCTAssertTrue(marks.contains(mark), "\(mark) dBFS mark") }
    XCTAssertEqual(marks, marks.sorted(), "marks run left to right")
    XCTAssertEqual(AudioCapture.decibels(fullScalePeak: 0.25), -12.041, accuracy: 0.001)

    // Gain above full scale shows as clipping at the right end; Float32 keeps the overs.
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    (samples[0], samples[1], samples[2], samples[3]) = (0.6, -0.3, 0.1, 0)
    let loud = AudioCapture.applyGainAndMeasure(buffer, gain: 2)
    XCTAssertEqual(loud.peak, 1.2, accuracy: 0.0001)
    XCTAssertEqual(samples[0], 1.2, accuracy: 0.0001)
    XCTAssertEqual(position(AudioCapture.decibels(fullScalePeak: loud.peak)), 1)
    let int16 = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: int16, frameCapacity: 2))
    pcm.frameLength = 2
    let ints = try XCTUnwrap(pcm.int16ChannelData?[0])
    (ints[0], ints[1]) = (20_000, -20_000)
    let clamped = AudioCapture.applyGainAndMeasure(pcm, gain: 3)
    XCTAssertEqual(clamped.peak, 1, accuracy: 0.001, "16-bit input clamps at full scale")
    XCTAssertEqual(ints[0], Int16.max)
    XCTAssertEqual(ints[1], Int16.min)
    let silent = AudioCapture.applyGainAndMeasure(buffer, gain: 0)
    XCTAssertEqual(silent.peak, 0)
    XCTAssertEqual(position(AudioCapture.decibels(fullScalePeak: silent.peak)), 0)

    let session = SessionStore()
    session.publishMeter(peak: 1.2, clipping: true)
    XCTAssertTrue(session.isClipping)
    XCTAssertGreaterThan(session.audioPeakDBFS, 0)
    XCTAssertEqual(position(session.audioPeakDBFS), 1)
  }

  // MARK: Long scripts

  /// A 5,000-word script (the two real scripts, four times over). Per recognition update:
  /// the work `SessionStore.flushCandidates` does (tracker match against
  /// `document.spokenTokens` for both locales, index bookkeeping, a fresh anchor) and the work
  /// the presenter does (`updateNSView`'s document signature, read-state repaint, alignment).
  /// Budgets are 1 ms on average in an optimised build; `./test.sh` builds for debugging, where
  /// the Swift-side matcher runs several times slower, so it gets a looser session budget.
  func testAFiveThousandWordScriptKeepsProgressUnderAMillisecondPerUpdate() throws {
    let base = try fixture("172 script.md") + "\n\n" + fixture("173 script.md")
    let document = PrompterDocument(markdown: (1...4).map { "## Part \($0)\n\n\(base)" }.joined(separator: "\n\n"))
    let tokens = document.spokenTokens
    XCTAssertGreaterThanOrEqual(tokens.count, 5_000)
    let scriptID = UUID()
    let clock = ContinuousClock()
    var tracker = RecognitionTracker(generation: 1, tokenIndex: 0)
    var english: [String] = []
    var range = 0
    var start = 0.0
    var now = 0.0
    var session = Duration.zero
    var slowest = Duration.zero
    let read = readableIndices(document).prefix(1_500)
    for index in read {
      if english.count == 24 { range += 1; english = []; start = now }
      english.append(tokens[index].text)
      now += 0.3
      let events = [
        RecognitionEvent(replacementID: "en-\(range)", generation: 1, text: english.joined(separator: " "),
          isFinal: false, timestamp: now, localeIdentifier: "en-GB", audioStart: start, audioEnd: now),
        RecognitionEvent(replacementID: "fr-\(range)", generation: 1, text: "euh passe donc \(english.count)",
          isFinal: false, timestamp: now, localeIdentifier: "fr-FR", audioStart: start, audioEnd: now),
      ]
      let elapsed = clock.measure {
        let update = tracker.consumeCandidates(events, script: document.spokenTokens)
        let next = min(update.tokenIndex + 1, document.spokenTokens.count - 1)
        _ = ReadingAnchorRemapper.makeAnchor(
          scriptID: scriptID, revision: 0, document: document, globalTokenIndex: next, guideFraction: 0.35)
      }
      session += elapsed
      slowest = max(slowest, elapsed)
    }
    XCTAssertEqual(tracker.tokenIndex, read.last, "kept up with the reading")
    let sessionAverage = session / read.count

    // The presenter side, on the same document.
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    text.textContainer?.widthTracksTextView = true
    scroll.documentView = text
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    let render = clock.measure {
      coordinator.render(document: document, fontName: "Helvetica", fontSize: 44, textOpacity: 1, showCues: false)
      coordinator.align(scroll: scroll, tokenIndex: 0, guideFraction: 0.35)
    }
    var repaint = Duration.zero
    var signature = Duration.zero
    let steps = Array(stride(from: 1, to: tokens.count - 1, by: 5).prefix(600))
    for index in steps {
      repaint += clock.measure {
        coordinator.tokenIndex = index + 1
        coordinator.lastConfirmedTokenIndex = index
        coordinator.updateReadState()
        coordinator.align(scroll: scroll, tokenIndex: index + 1, guideFraction: 0.35)
      }
      // ScriptTextView.updateNSView builds this on every SwiftUI update, i.e. every word.
      signature += clock.measure { _ = "\(document.hashValue)|Helvetica|44.0|1.0|Regular|#FFFFFF" }
    }
    let repaintAverage = repaint / steps.count
    let signatureAverage = signature / steps.count
    print("[core-qa] 5k words (\(tokens.count) tokens): session \(sessionAverage) avg, \(slowest) worst over \(read.count) updates; presenter repaint+align \(repaintAverage) avg, document signature \(signatureAverage) avg; first render+layout \(render)")
    #if DEBUG
      let sessionBudget = Duration.milliseconds(10)
    #else
      let sessionBudget = Duration.milliseconds(1)
    #endif
    XCTAssertLessThan(sessionAverage, sessionBudget, "session progress handling")
    XCTAssertLessThan(repaintAverage, .milliseconds(1), "presenter repaint and alignment")
    XCTExpectFailure("BUG: ScriptTextView.updateNSView hashes the whole document on every update") {
      XCTAssertLessThan(repaintAverage + signatureAverage, .milliseconds(1), "presenter work per update")
    }
  }
}
