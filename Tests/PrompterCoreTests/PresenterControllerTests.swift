import AppKit
import XCTest
@testable import JuniorPrompter
import PrompterCore

@MainActor
final class PresenterControllerTests: XCTestCase {
  func testPresenterDraftRefreshesItsSnapshotAfterCancelAndReopen() {
    let first = ScriptRecord(metadata: .init(title: "First", fileName: "first.md", revision: 2,
      contentFingerprint: "first"), markdown: "first text")
    var second = first
    second.metadata.revision = 3
    second.metadata.contentFingerprint = "second"
    second.markdown = "second text"
    let session = SessionStore()
    session.present(record: first, settings: PrompterSettings())
    let draft = PresenterDraft(record: first)
    draft.begin(session: session)
    draft.markdown = "abandoned local text"
    draft.cancel()
    session.applyEditedRecord(second)
    draft.begin(session: session)
    XCTAssertEqual(draft.markdown, "second text")
    XCTAssertEqual(draft.expectedFingerprint, "second")
    XCTAssertEqual(draft.expectedRevision, 3)
  }

  /// In-place presenter editing: the reader keeps the passage they were on, whether
  /// the change lands before it, inside its own passage, or after it.
  func testInPlaceEditKeepsTheAnchorOnTheSamePassage() {
    let markdown = "Opening lines of the script.\n\nSecond passage holds the target word here.\n\nClosing lines of the script."
    for (name, edited) in [
      ("before", "Rewritten opening lines entirely.\n\nSecond passage holds the target word here.\n\nClosing lines of the script."),
      ("at", "Opening lines of the script.\n\nSecond passage really holds the target word here.\n\nClosing lines of the script."),
      ("after", "Opening lines of the script.\n\nSecond passage holds the target word here.\n\nClosing lines rewritten entirely."),
    ] {
      let record = ScriptRecord(metadata: .init(title: "Anchor", fileName: "anchor.md", revision: 4,
        contentFingerprint: "one"), markdown: markdown)
      let session = SessionStore()
      session.present(record: record, settings: PrompterSettings())
      let target = try! XCTUnwrap(session.document.spokenTokens.firstIndex { $0.normalised == "target" })
      session.seek(to: target)
      var next = record
      next.metadata.revision = 5
      next.metadata.contentFingerprint = "two"
      next.markdown = edited
      session.applyEditedRecord(next)
      XCTAssertEqual(session.activeToken?.normalised, "target", "edit \(name) the anchor moved it")
      XCTAssertNil(session.anchorNotice, "edit \(name) reported a deleted passage")
    }
  }

  /// Editing happens in the presenter's own view, so it must borrow the presenter's
  /// type and put the anchored passage back on the guide line.
  func testInPlaceEditorUsesPresenterTypeAndPutsTheAnchorOnTheGuide() throws {
    let markdown = (1...30).map { "Passage \($0) with several readable words." }.joined(separator: "\n\n")
    let document = PrompterDocument(markdown: markdown)
    let token = try XCTUnwrap(document.spokenTokens.first { $0.normalised == "20" })
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 4_000))
    view.isVerticallyResizable = true
    view.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    let typography = EditorTypography(textColor: .systemRed, lineSpacing: 8, paragraphSpacing: 16,
      horizontalInset: 42, alignment: .center)
    let coordinator = FormattedMarkdownEditor(markdown: .constant(markdown), fontName: "Helvetica",
      fontSize: 44).makeCoordinator()
    view.textContainerInset = NSSize(width: typography.horizontalInset, height: 8)
    coordinator.configure(view, markdown: markdown, fontName: "Helvetica", fontSize: 44,
      typography: typography)
    let storage = try XCTUnwrap(view.textStorage)
    XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 44, accuracy: 0.1)
    XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
    XCTAssertEqual((storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .center)

    coordinator.scrollToAnchor(view, sourceOffset: token.sourceRange.location, guideFraction: 0.35)
    let manager = try XCTUnwrap(view.layoutManager)
    let container = try XCTUnwrap(view.textContainer)
    manager.ensureLayout(for: container)
    let visible = try XCTUnwrap(FormattedMarkdownEditModel(markdown: markdown)
      .visibleIndex(forSourceOffset: token.sourceRange.location))
    XCTAssertEqual((view.string as NSString).substring(with: NSRange(location: visible, length: 2)), "20")
    XCTAssertEqual(view.selectedRange().location, visible)
    let glyph = manager.glyphRange(forCharacterRange: NSRange(location: visible, length: 1), actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
    XCTAssertEqual(rect.midY + view.textContainerInset.height - scroll.contentView.bounds.origin.y,
      ScriptTextView.visualGuideY(height: scroll.contentView.bounds.height, fraction: 0.35), accuracy: 2)
  }

  /// Escape threw typed edits away with no confirmation. It now asks, and an untouched
  /// draft still cancels straight away.
  func testEscapeConfirmsOnlyWhenTheDraftWasTyped() {
    var settings = PrompterSettings()
    settings.mode = "Timed"
    let record = ScriptRecord(metadata: .init(title: "Run", fileName: "run.md", revision: 1,
      contentFingerprint: "one"), markdown: "one two three four")
    let session = SessionStore()
    session.present(record: record, settings: settings)
    session.play()
    let draft = PresenterDraft(record: record)

    draft.begin(session: session)
    draft.requestCancel()
    XCTAssertFalse(draft.closeRequested, "an untouched draft must not ask")
    XCTAssertFalse(draft.isEditing)
    XCTAssertTrue(session.isActivelyRunning, "cancelling carried on reading")

    session.play()
    draft.begin(session: session)
    draft.markdown = "one two three four five"
    draft.requestCancel()
    XCTAssertTrue(draft.closeRequested, "typed edits were discarded with no confirmation")
    XCTAssertTrue(draft.isEditing, "the draft must survive until the confirmation is answered")
    XCTAssertEqual(draft.markdown, "one two three four five")
    XCTAssertFalse(draft.discardCloses, "Escape must not close the presenter")
    // Answering the confirmation discards and carries on reading.
    draft.cancel(resuming: !draft.discardCloses)
    XCTAssertFalse(draft.isEditing)
    XCTAssertFalse(draft.closeRequested)
    XCTAssertTrue(session.isActivelyRunning)

    // The close button still asks and still closes.
    draft.begin(session: session)
    draft.markdown = "typed again"
    draft.requestClose()
    XCTAssertTrue(draft.closeRequested)
    XCTAssertTrue(draft.discardCloses)
    draft.cancel(resuming: false)
    session.pause()
  }

  /// A vertically mirrored presenter reads its guide from the other edge, and the in-place
  /// editor must use the same flipped line or the anchored passage jumps when editing starts.
  func testInPlaceEditorFlipsTheGuideForAMirroredPresenter() throws {
    let markdown = (1...30).map { "Passage \($0) with several readable words." }.joined(separator: "\n\n")
    let document = PrompterDocument(markdown: markdown)
    let token = try XCTUnwrap(document.spokenTokens.first { $0.normalised == "20" })
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 4_000))
    view.isVerticallyResizable = true
    view.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    let coordinator = FormattedMarkdownEditor(markdown: .constant(markdown), fontName: "Helvetica",
      fontSize: 44).makeCoordinator()
    coordinator.configure(view, markdown: markdown, fontName: "Helvetica", fontSize: 44)
    coordinator.scrollToAnchor(view, sourceOffset: token.sourceRange.location, guideFraction: 0.35,
      verticalMirror: true)
    let manager = try XCTUnwrap(view.layoutManager)
    let container = try XCTUnwrap(view.textContainer)
    manager.ensureLayout(for: container)
    let visible = try XCTUnwrap(FormattedMarkdownEditModel(markdown: markdown)
      .visibleIndex(forSourceOffset: token.sourceRange.location))
    let glyph = manager.glyphRange(forCharacterRange: NSRange(location: visible, length: 1), actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
    let height = scroll.contentView.bounds.height
    let mirrored = height - ScriptTextView.visualGuideY(height: height, fraction: 0.35)
    XCTAssertEqual(rect.midY + view.textContainerInset.height - scroll.contentView.bounds.origin.y,
      mirrored, accuracy: 2)
    XCTAssertNotEqual(mirrored, ScriptTextView.visualGuideY(height: height, fraction: 0.35),
      "the mirrored guide must differ from the upright one for this to prove anything")
  }

  /// The pencil pauses tracking in place and finishing carries on from where it was.
  func testInPlaceEditPausesTrackingAndFinishingResumesIt() {
    var settings = PrompterSettings()
    settings.mode = "Timed"
    let record = ScriptRecord(metadata: .init(title: "Run", fileName: "run.md", revision: 1,
      contentFingerprint: "one"), markdown: "one two three four")
    let session = SessionStore()
    session.present(record: record, settings: settings)
    session.play()
    XCTAssertTrue(session.isActivelyRunning)
    let draft = PresenterDraft(record: record)
    draft.begin(session: session)
    XCTAssertFalse(session.isActivelyRunning)
    draft.markdown = "one two three four five"
    draft.cancel()
    XCTAssertTrue(session.isActivelyRunning)
    session.pause()
    // Cancelling restored the script the presenter is reading.
    draft.begin(session: session)
    XCTAssertEqual(draft.markdown, "one two three four")
    XCTAssertEqual(session.document.markdown, "one two three four")
    draft.cancel()
    session.pause()
  }

  func testPresenterEditCommitPersistsMarkdownAndKeepsTheAnchor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    let record = try await store.library!.create(
      title: "Presented", markdown: "Opening words here.\n\nSecond passage with the target word.")
    await store.reload()
    store.session.present(record: record, settings: PrompterSettings())
    let target = try XCTUnwrap(store.session.document.spokenTokens.firstIndex { $0.normalised == "target" })
    store.session.seek(to: target)
    let draft = PresenterDraft(record: record)
    draft.begin(session: store.session)
    draft.markdown = "Rewritten opening.\n\nSecond passage with the target word."
    await draft.confirm(store: store)
    XCTAssertNil(draft.errorMessage)
    XCTAssertFalse(draft.isEditing)
    let saved = try await store.library!.read(record.id)
    XCTAssertEqual(saved.markdown, "Rewritten opening.\n\nSecond passage with the target word.")
    XCTAssertEqual(store.session.activeToken?.normalised, "target")
  }

  func testOnePixelScreenIntersectionDoesNotMakePresenterReachable() {
    XCTAssertFalse(PresenterController.hasReachableTitleBar(
      NSRect(x: 1919, y: 100, width: 760, height: 520),
      visibleFrames: [NSRect(x: 0, y: 0, width: 1920, height: 1080)]))
    XCTAssertTrue(PresenterController.hasReachableTitleBar(
      NSRect(x: 1800, y: 100, width: 760, height: 520),
      visibleFrames: [NSRect(x: 0, y: 0, width: 1920, height: 1080)]))
    XCTAssertFalse(PresenterController.hasReachableTitleBar(
      NSRect(x: 100, y: -500, width: 760, height: 520),
      visibleFrames: [NSRect(x: 0, y: 0, width: 1920, height: 1080)]))
  }

  func testPresenterSnapsToCentreEdgesAndHalvesOnRelevantNegativeOriginScreen() {
    let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let right = NSRect(x: 0, y: 24, width: 2560, height: 1416)
    let frame = NSRect(x: -1_810, y: 280, width: 760, height: 520)
    let half = PresenterController.snappedFrame(frame, visibleFrames: [right, left])
    XCTAssertEqual(half.minX, left.minX + left.width / 4 - frame.width / 2, accuracy: 0.1)
    let edge = PresenterController.snappedFrame(
      NSRect(x: -1_900, y: 18, width: 760, height: 520), visibleFrames: [left])
    XCTAssertEqual(edge.minX, left.minX, accuracy: 0.1)
    XCTAssertEqual(edge.minY, left.minY, accuracy: 0.1)
    let centre = PresenterController.snappedFrame(
      NSRect(x: -1_350, y: 280, width: 760, height: 520), visibleFrames: [left])
    XCTAssertEqual(centre.midX, left.midX, accuracy: 0.1)
  }

  func testLiveFontSizeRenderPreservesMappedAnchorAtGuide() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 2_400))
    scroll.documentView = text
    let document = PrompterDocument(markdown: (1...20).map { "Line \($0) with useful words." }.joined(separator: "\n\n"))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)
    coordinator.align(scroll: scroll, tokenIndex: 12, guideFraction: 0.35)
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 52, textOpacity: 1)
    coordinator.align(scroll: scroll, tokenIndex: 12, guideFraction: 0.35)
    let mapping = try! XCTUnwrap(coordinator.mappings.first { $0.1 == 12 })
    let manager = text.layoutManager!
    manager.ensureLayout(for: text.textContainer!)
    let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyph, in: text.textContainer!)
    XCTAssertEqual(rect.midY + text.textContainerInset.height - scroll.contentView.bounds.origin.y,
      max(54, scroll.contentView.bounds.height * 0.35), accuracy: 2)
    let font = text.textStorage?.attribute(.font, at: mapping.0.location, effectiveRange: nil) as? NSFont
    XCTAssertEqual(font?.pointSize ?? 0, 52, accuracy: 0.1)
  }

  func testHiddenCueCollapsesLayoutWithoutChangingSourceOrMappings() {
    func rendered(_ markdown: String, showCues: Bool, width: CGFloat) -> (NSTextView, ScriptTextView.Coordinator) {
      let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
      view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
      view.textContainer?.widthTracksTextView = true
      let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
      coordinator.textView = view
      coordinator.render(document: PrompterDocument(markdown: markdown), fontName: "Helvetica", fontSize: 36,
        textOpacity: 1, showCues: showCues)
      view.layoutManager?.ensureLayout(for: view.textContainer!)
      return (view, coordinator)
    }
    func rect(of token: String, in value: (NSTextView, ScriptTextView.Coordinator)) -> NSRect {
      let mapping = value.1.mappings.first { (value.0.string as NSString).substring(with: $0.0) == token }!
      let glyph = value.0.layoutManager!.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
      return value.0.layoutManager!.boundingRect(forGlyphRange: glyph, in: value.0.textContainer!)
    }

    let plain = rendered("Hello world", showCues: false, width: 220)
    let hidden = rendered("Hello [pause] world", showCues: false, width: 220)
    let visible = rendered("Hello [pause] world", showCues: true, width: 220)
    XCTAssertEqual(hidden.0.string, "Hello [pause] world")
    XCTAssertEqual(hidden.1.mappings.count, 2)
    XCTAssertEqual(rect(of: "world", in: hidden).minX, rect(of: "world", in: plain).minX, accuracy: 1)
    XCTAssertEqual(rect(of: "world", in: hidden).minY, rect(of: "world", in: plain).minY, accuracy: 1)
    XCTAssertGreaterThan(rect(of: "world", in: visible).minY, rect(of: "world", in: hidden).minY + 1)
  }

  func testCueIsNotMappedAsSpokenAndOpacityIsPreserved() {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    let document = PrompterDocument(markdown: "aside [aside] world")
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 0.6)
    XCTAssertEqual(coordinator.mappings.count, 2)
    let cue = (view.string as NSString).range(of: "[aside]")
    guard cue.location != NSNotFound, coordinator.mappings.count == 2 else {
      return XCTFail("Cue or spoken-token mappings were lost during rendering")
    }
    XCTAssertTrue(coordinator.mappings.allSatisfy { NSIntersectionRange($0.0, cue).length == 0 })
    let cueColour = view.textStorage?.attribute(.foregroundColor, at: cue.location + 1, effectiveRange: nil) as? NSColor
    XCTAssertEqual(cueColour?.alphaComponent ?? 0, 0.6 * 0.42, accuracy: 0.02)
    coordinator.tokenIndex = 1
    coordinator.lastConfirmedTokenIndex = 0
    coordinator.updateReadState()
    let first = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    let second = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[1].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(first?.alphaComponent ?? 0, 0.6 * 0.38, accuracy: 0.02)
    XCTAssertEqual(second?.alphaComponent ?? 0, 0.6, accuracy: 0.02)
  }

  func testVerticalMirrorKeepsCurrentTokenOnVisualGuideAtClampedExtremes() {
    let document = PrompterDocument(markdown: (1...50).map { "Paragraph \($0) with useful words." }.joined(separator: "\n\n"))
    for size in [NSSize(width: 760, height: 468), NSSize(width: 360, height: 220), NSSize(width: 360, height: 80), NSSize(width: 360, height: 48)] {
      for fraction in [0.05, 0.35, 0.95] {
        for mirrored in [false, true] {
          let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
          scroll.contentView.bounds = NSRect(origin: .zero, size: size)
          let text = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: 8_000))
          text.textContainer?.widthTracksTextView = true
          scroll.documentView = text
          let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
          coordinator.textView = text
          coordinator.verticalMirror = mirrored
          coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)
          coordinator.align(scroll: scroll, tokenIndex: 24, guideFraction: fraction)
          let mapping = try! XCTUnwrap(coordinator.mappings.first { $0.1 == 24 })
          let manager = text.layoutManager!
          manager.ensureLayout(for: text.textContainer!)
          let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
          let logicalY = manager.boundingRect(forGlyphRange: glyph, in: text.textContainer!).midY
            + text.textContainerInset.height - scroll.contentView.bounds.origin.y
          let visualY = mirrored ? size.height - logicalY : logicalY
          XCTAssertEqual(visualY, ScriptTextView.visualGuideY(height: size.height, fraction: fraction), accuracy: 2,
            "size=\(size), fraction=\(fraction), mirrored=\(mirrored)")
        }
      }
    }
  }

  func testFirstAndLastTokensAlignToGuideAtPresenterSizes() {
    let document = PrompterDocument(markdown: (1...40).map { "Paragraph \($0) with useful words." }.joined(separator: "\n\n"))
    for size in [NSSize(width: 760, height: 468), NSSize(width: 360, height: 228)] {
      let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
      scroll.contentView.bounds = NSRect(origin: .zero, size: size)
      let text = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: 5000))
      text.textContainer?.widthTracksTextView = true
      scroll.documentView = text
      let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
      coordinator.textView = text
      coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)
      for index in [0, document.spokenTokens.count - 1] {
        coordinator.invalidateAlignment()
        coordinator.align(scroll: scroll, tokenIndex: index, guideFraction: 0.35)
        guard let mapping = coordinator.mappings.first(where: { $0.1 == index }),
          let manager = text.layoutManager, let container = text.textContainer else {
          return XCTFail("Token mapping missing for index \(index)")
        }
        manager.ensureLayout(for: container)
        let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
        let viewportY = rect.midY + text.textContainerInset.height - scroll.contentView.bounds.origin.y
        let guideY = max(54, size.height * 0.35)
        XCTAssertEqual(viewportY, guideY, accuracy: 2, "size=\(size), index=\(index)")
      }
    }
  }

  func testPresenterAppearanceAndHiddenCuePreserveMappingAndMargin() {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
    view.textContainerInset = NSSize(width: 64, height: 80)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 468))
    scroll.contentView.bounds = NSRect(x: 0, y: 0, width: 760, height: 468)
    scroll.documentView = view
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    let document = PrompterDocument(markdown: "# Heading\n\nHello [pause] world")
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 0.8,
      fontWeight: "Regular", textColorHex: "#00FF00", lineSpacing: 0.5, paragraphSpacing: 0.8,
      horizontalMargin: 64, alignment: "Right", showCues: false, highlightActiveWord: false)
    XCTAssertEqual(coordinator.mappings.count, 3)
    let cue = (view.string as NSString).range(of: "[pause]")
    XCTAssertNotEqual(cue.location, NSNotFound)
    for position in [cue.location, cue.location + cue.length - 1] {
      XCTAssertEqual((view.textStorage?.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor)?.alphaComponent ?? -1, 0, accuracy: 0.01)
    }
    XCTAssertEqual((view.textStorage?.attribute(.foregroundColor, at: cue.location + 1, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 0, 0, accuracy: CGFloat(0.01))
    let first = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(first?.greenComponent ?? 0, 1, accuracy: 0.01)
    coordinator.tokenIndex = 1
    coordinator.lastConfirmedTokenIndex = 0
    coordinator.updateReadState()
    let dimmed = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    let current = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[1].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(dimmed?.alphaComponent ?? 0, 0.8 * 0.38, accuracy: 0.02)
    XCTAssertEqual(current?.greenComponent ?? 0, 1, accuracy: 0.01)
    let paragraph = view.textStorage?.attribute(.paragraphStyle, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(paragraph?.alignment, .right)
    XCTAssertEqual(paragraph?.lineSpacing ?? 0, 12, accuracy: 0.1)
    XCTAssertEqual(paragraph?.paragraphSpacing ?? 0, 19.2, accuracy: 0.1)
    coordinator.align(scroll: scroll, tokenIndex: 0, guideFraction: 0.35)
    XCTAssertEqual(view.textContainerInset.width, 64, accuracy: 0.1)
  }

  func testReadStateMovesBackWithoutLeavingWordsDimmed() {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    coordinator.render(document: PrompterDocument(markdown: "one two three"), fontName: "Helvetica", fontSize: 24, textOpacity: 0.8)
    coordinator.tokenIndex = 2
    coordinator.lastConfirmedTokenIndex = 1
    coordinator.updateReadState()
    coordinator.tokenIndex = 1
    coordinator.lastConfirmedTokenIndex = 0
    coordinator.updateReadState()
    let first = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    let second = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[1].0.location, effectiveRange: nil) as? NSColor
    let third = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[2].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(first?.alphaComponent ?? 0, 0.8 * 0.38, accuracy: 0.02)
    XCTAssertEqual(second?.alphaComponent ?? 0, 0.8, accuracy: 0.02)
    XCTAssertEqual(third?.alphaComponent ?? 0, 0.8, accuracy: 0.02)
  }

  func testConfirmedWordDimsTrailingPunctuationButInitialAndSeekWordsStayUnread() {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    coordinator.render(document: PrompterDocument(markdown: "Hello, world!"), fontName: "Helvetica", fontSize: 24, textOpacity: 0.8)
    coordinator.tokenIndex = 0
    coordinator.updateReadState()
    let comma = (view.string as NSString).range(of: ",").location
    let initial = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(initial?.alphaComponent ?? 0, 0.8, accuracy: 0.02)
    coordinator.tokenIndex = 1
    coordinator.lastConfirmedTokenIndex = 0
    coordinator.updateReadState()
    let word = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    let punctuation = view.textStorage?.attribute(.foregroundColor, at: comma, effectiveRange: nil) as? NSColor
    let next = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[1].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(word?.alphaComponent ?? 0, 0.8 * 0.38, accuracy: 0.02)
    XCTAssertEqual(punctuation?.alphaComponent ?? 0, 0.8 * 0.38, accuracy: 0.02)
    XCTAssertEqual(next?.alphaComponent ?? 0, 0.8, accuracy: 0.02)
    coordinator.tokenIndex = 1
    coordinator.lastConfirmedTokenIndex = nil
    coordinator.updateReadState()
    let seekWord = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[1].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(seekWord?.alphaComponent ?? 0, 0.8, accuracy: 0.02)
  }

  func testConsecutiveListItemsKeepLineBreaksAndWordMappings() {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    let document = PrompterDocument(markdown: "- First point\n- Deuxième point\n\n1. One\n2. Two")
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)

    XCTAssertEqual(view.string, "First point\nDeuxième point\n\nOne\nTwo")
    XCTAssertEqual(coordinator.mappings.map { document.spokenTokens[$0.1].text },
      ["First", "point", "Deuxième", "point", "One", "Two"])
    XCTAssertEqual(coordinator.mappings.map { (view.string as NSString).substring(with: $0.0) },
      ["First", "point", "Deuxième", "point", "One", "Two"])
  }

  func testOnlyLiveScrollNotificationsReanchorAtTheGuide() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 2400))
    scroll.documentView = text
    var seeks: [Int] = []
    let coordinator = ScriptTextView.Coordinator(onSeek: { seeks.append($0) })
    coordinator.textView = text
    coordinator.render(
      document: PrompterDocument(markdown: (1...40).map { "Line \($0) with words." }.joined(separator: "\n\n")),
      fontName: "Helvetica", fontSize: 24, textOpacity: 1)
    coordinator.observeUserScrolls(in: scroll)
    scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 500))
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    XCTAssertTrue(seeks.isEmpty)
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    XCTAssertEqual(seeks.count, 1)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    XCTAssertEqual(seeks.count, 1)
    coordinator.stopObservingUserScrolls()
  }

  func testRunningMultiwordProgressAnimatesAndExplicitSnapCancelsIt() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 2400))
    scroll.documentView = text
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    coordinator.render(
      document: PrompterDocument(markdown: (1...30).map { "Line \($0) with words." }.joined(separator: "\n\n")),
      fontName: "Helvetica", fontSize: 24, textOpacity: 1)
    coordinator.isActivelyRunning = true
    coordinator.align(scroll: scroll, tokenIndex: 0, guideFraction: 0.35)
    let start = scroll.contentView.bounds.origin.y

    func target(for index: Int) -> CGFloat {
      let mapping = coordinator.mappings.first { $0.1 == index }!
      let manager = text.layoutManager!
      manager.ensureLayout(for: text.textContainer!)
      let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
      let rect = manager.boundingRect(forGlyphRange: glyph, in: text.textContainer!)
      let guideY = max(54, scroll.contentView.bounds.height * 0.35)
      return max(0, rect.midY + text.textContainerInset.height - guideY)
    }

    let sameLinePair = (1..<coordinator.mappings.count).first { index in
      let previous = target(for: index - 1)
      let current = target(for: index)
      return current > start + 20 && abs(current - previous) < 0.5
    }
    let sameLineIndex = try! XCTUnwrap(sameLinePair)
    let sameLineTarget = target(for: sameLineIndex)
    coordinator.align(scroll: scroll, tokenIndex: sameLineIndex - 1, guideFraction: 0.35)
    RunLoop.main.run(until: Date().addingTimeInterval(0.10))
    coordinator.align(scroll: scroll, tokenIndex: sameLineIndex, guideFraction: 0.35)
    RunLoop.main.run(until: Date().addingTimeInterval(0.55))
    XCTAssertEqual(scroll.contentView.bounds.origin.y, sameLineTarget, accuracy: 2,
      "A same-line token update must not restart the existing alignment")
    coordinator.snapNextAlignment = true
    coordinator.align(scroll: scroll, tokenIndex: 0, guideFraction: 0.35)

    coordinator.align(scroll: scroll, tokenIndex: 5, guideFraction: 0.35)
    RunLoop.main.run(until: Date().addingTimeInterval(0.075))
    let intermediate = scroll.contentView.bounds.origin.y
    let firstTarget = target(for: 5)
    XCTAssertTrue(min(start, firstTarget) < intermediate && intermediate < max(start, firstTarget))

    coordinator.align(scroll: scroll, tokenIndex: 10, guideFraction: 0.35)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, intermediate, accuracy: 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.075))
    let retargeted = scroll.contentView.bounds.origin.y
    let secondTarget = target(for: 10)
    XCTAssertTrue(min(intermediate, secondTarget) < retargeted && retargeted < max(intermediate, secondTarget))

    coordinator.snapNextAlignment = true
    coordinator.align(scroll: scroll, tokenIndex: 0, guideFraction: 0.35)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, start, accuracy: 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.34))
    XCTAssertEqual(scroll.contentView.bounds.origin.y, start, accuracy: 1)
  }

  // MARK: Present with video

  func testThePresentWithVideoChoiceSurvivesAReopenedModel() {
    let suite = "JuniorPrompter.presenter.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = UserDefaults(suiteName: suite)!
    let model = CameraModel(defaults: store)
    XCTAssertFalse(model.presentsWithVideo, "present without video is the existing behaviour")
    model.presentsWithVideo = true
    XCTAssertTrue(CameraModel(defaults: store).presentsWithVideo)
  }

  /// The toggle lives on `CameraModel`, nowhere near the reading state, so turning the video
  /// background on and off cannot move the anchor or restart the speech session.
  func testTogglingTheVideoBackgroundLeavesTheAnchorAndTheSessionAlone() {
    let markdown = (1...20).map { "Passage \($0) with several readable words." }.joined(separator: "\n\n")
    let record = ScriptRecord(metadata: .init(title: "Video", fileName: "video.md", revision: 1,
      contentFingerprint: "one"), markdown: markdown)
    let session = SessionStore()
    session.present(record: record, settings: PrompterSettings())
    let target = try! XCTUnwrap(session.document.spokenTokens.firstIndex { $0.normalised == "12" })
    session.seek(to: target)
    let running = session.isActivelyRunning
    let suite = "JuniorPrompter.presenter.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let model = CameraModel(defaults: UserDefaults(suiteName: suite)!)
    model.presentsWithVideo = true
    model.presentsWithVideo = false
    XCTAssertEqual(session.tokenIndex, target)
    XCTAssertEqual(session.activeToken?.normalised, "12")
    XCTAssertEqual(session.isActivelyRunning, running)
    XCTAssertNil(session.anchorNotice)
  }

  /// `closeNow` orders the panel out rather than closing it, which on its own would leave the
  /// hosting view — and so the camera — holding the shared session open for ever.
  func testClosingThePresenterWithVideoOnLetsTheSharedCameraSessionGo() {
    XCTAssertEqual(SharedCameraSession.shared.holderCount, 0, "another test left a holder behind")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [], backing: .buffered, defer: true)
    let stage = CameraStageView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    window.contentView = stage
    stage.setHolding(true)
    XCTAssertEqual(SharedCameraSession.shared.holderCount, 1)
    window.contentView = NSView()
    XCTAssertEqual(SharedCameraSession.shared.holderCount, 0)
  }

  /// Native full screen needs `.fullScreenPrimary` and a resizable window; the presenter floats
  /// only outside its full-screen Space.
  func testThePresenterCanTakeItsOwnFullScreenSpaceAndFloatsOnlyOutsideIt() {
    let panel = PresenterController.configuredPanel()
    XCTAssertTrue(panel.styleMask.contains(.resizable))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenPrimary))
    XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary), "auxiliary rules out full screen")
    XCTAssertEqual(panel.level, .floating)
    let controller = PresenterController()
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: panel))
    XCTAssertEqual(panel.level, .normal)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: panel))
    XCTAssertEqual(panel.level, .floating)
    panel.level = .normal
    controller.windowDidFailToEnterFullScreen(panel)
    XCTAssertEqual(panel.level, .floating)
  }

  /// Text width narrows the script column only: it persists, the reading anchor stays put,
  /// the text container follows it, and the anchored word stays on the guide line.
  func testTextWidthPersistsNarrowsTheColumnAndKeepsTheAnchorOnTheGuide() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "JuniorPrompterTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(store.settings.textWidth, 1)
    let markdown = (1...20).map { "Line \($0) with useful words for a wide column." }.joined(separator: "\n\n")
    let record = ScriptRecord(metadata: .init(title: "Width", fileName: "width.md", revision: 1,
      contentFingerprint: "one"), markdown: markdown)
    store.session.present(record: record, settings: store.settings)
    store.session.seek(to: 40)
    store.settings.textWidth = 0.4
    store.session.updateSettings(store.settings)
    XCTAssertEqual(store.session.tokenIndex, 40)
    XCTAssertEqual(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
      .settings.textWidth, 0.4)

    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 1600, height: 6_000))
    text.textContainer?.widthTracksTextView = true
    scroll.documentView = text
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    coordinator.render(document: store.session.document, fontName: "Helvetica", fontSize: 44, textOpacity: 1)
    coordinator.setSideInset(ScriptTextView.sideInset(width: 1600, textWidth: 1))
    coordinator.align(scroll: scroll, tokenIndex: 40, guideFraction: 0.35)
    let container = try XCTUnwrap(text.textContainer)
    XCTAssertEqual(container.size.width, 1600 - 84, accuracy: 0.5)
    let firstOrigin = scroll.contentView.bounds.origin.y

    coordinator.setSideInset(ScriptTextView.sideInset(width: 1600, textWidth: store.settings.textWidth))
    coordinator.align(scroll: scroll, tokenIndex: 40, guideFraction: 0.35)
    XCTAssertEqual(container.size.width, 640, accuracy: 0.5)
    XCTAssertNotEqual(scroll.contentView.bounds.origin.y, firstOrigin, accuracy: 1, "the narrower column must reflow")
    let mapping = try XCTUnwrap(coordinator.mappings.first { $0.1 == 40 })
    let manager = try XCTUnwrap(text.layoutManager)
    manager.ensureLayout(for: container)
    let rect = manager.boundingRect(
      forGlyphRange: manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil), in: container)
    XCTAssertEqual(rect.midY + text.textContainerInset.height - scroll.contentView.bounds.origin.y,
      ScriptTextView.visualGuideY(height: scroll.contentView.bounds.height, fraction: 0.35), accuracy: 2)
    XCTAssertEqual(ScriptTextView.sideInset(width: 300, textWidth: 0.9), 42, "never nearer an edge than 42 pt")
  }

  /// A 4K landscape feed turned 90° shows as 9:16, so the presenter becomes a tall window as
  /// large as the screen allows.
  func testMatchCameraSizeTurnsAVerticalFeedIntoAVerticalWindow() {
    let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let feed = CGSize(width: 3840, height: 2160)
    let turned = PresenterController.matchedCameraFrame(picture: feed, rotation: .quarter, in: screen)
    XCTAssertEqual(turned.width, 607.5, accuracy: 0.001)
    XCTAssertEqual(turned.height, 1080, accuracy: 0.001)
    XCTAssertEqual(turned.midX, 960, accuracy: 0.001)
    XCTAssertEqual(turned.midY, 540, accuracy: 0.001)
    let upright = PresenterController.matchedCameraFrame(picture: feed, rotation: .none, in: screen)
    XCTAssertEqual(upright.width, 1920, accuracy: 0.001)
    XCTAssertEqual(upright.height, 1080, accuracy: 0.001)
  }
}
