import AppKit
import SwiftUI
import XCTest
@testable import VidPrompt
import PrompterCore

@MainActor
final class PresenterControllerTests: XCTestCase {
  func testManualScrollMappingIndexMatchesLinearSearchForLargeLists() {
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.mappings = (0..<10_000).map { (NSRange(location: $0, length: 1), $0 * 3) }
    let positions: [Double] = [-1, 0, 1, 29_997, 29_998, 29_999, 30_000]

    for position in positions {
      let expected = max(0, (coordinator.mappings.firstIndex { Double($0.1) > position }
        ?? coordinator.mappings.count) - 1)
      XCTAssertEqual(coordinator.mappingIndex(at: position), expected, "position \(position)")
    }
  }

  func testReadStateAndAlignmentPreserveSparseAndEmptyMappings() throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
    let view = NSTextView(frame: scroll.bounds)
    scroll.documentView = view
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    coordinator.render(document: PrompterDocument(markdown: (0..<200).map { "word\($0)" }.joined(separator: " ")),
      fontName: "Helvetica", fontSize: 24, textOpacity: 0.8, highlightActiveWord: true)
    // Rendering can omit tokens, such as a code fence's language tag.
    coordinator.mappings.removeAll { $0.1 % 3 == 0 }
    for (current, confirmed) in [(199, Optional(198)), (1, Optional(0)), (50, Optional(49)),
      (50, Optional(80)), (50, nil), (50, Optional(20)), (50, nil), (0, nil), (-1, nil), (250, Optional(250))] {
      coordinator.tokenIndex = current
      coordinator.lastConfirmedTokenIndex = confirmed
      coordinator.updateReadState()
      coordinator.updateReadState() // An unchanged update must preserve the colours.
      for (range, index) in coordinator.mappings {
        let colour = try XCTUnwrap(view.textStorage?.attribute(.foregroundColor, at: range.location,
          effectiveRange: nil) as? NSColor)
        XCTAssertEqual(colour.alphaComponent, index <= (confirmed ?? -1) ? 0.8 * 0.38 : 0.8,
          accuracy: 0.02, "current \(current), confirmed \(String(describing: confirmed)), word \(index)")
        if index == current, confirmed.map({ index > $0 }) ?? true {
          XCTAssertEqual(colour, NSColor.systemYellow.withAlphaComponent(0.8))
        }
      }
    }
    coordinator.align(scroll: scroll, tokenIndex: 100, guideFraction: 0.35, eases: false)
    let origin = scroll.contentView.bounds.origin
    for index in [-1, 0, 99, 250] {
      coordinator.align(scroll: scroll, tokenIndex: index, guideFraction: 0.35, eases: false)
      XCTAssertEqual(scroll.contentView.bounds.origin, origin, "unmapped \(index)")
    }
    coordinator.align(scroll: scroll, tokenIndex: 1, guideFraction: 0.35, eases: false)
    XCTAssertLessThan(scroll.contentView.bounds.origin.y, origin.y, "mapped backward alignment still works")
    coordinator.mappings = []
    for index in [-1, 0, 250] {
      coordinator.tokenIndex = index
      coordinator.lastConfirmedTokenIndex = index
      coordinator.updateReadState()
      coordinator.align(scroll: scroll, tokenIndex: index, guideFraction: 0.35, eases: false)
    }
  }

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
    settings.mode = "Manual"
    let record = ScriptRecord(metadata: .init(title: "Run", fileName: "run.md", revision: 1,
      contentFingerprint: "one"), markdown: "one two three four")
    let session = SessionStore()
    session.clock = { 0 }
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
    settings.mode = "Manual"
    let record = ScriptRecord(metadata: .init(title: "Run", fileName: "run.md", revision: 1,
      contentFingerprint: "one"), markdown: "one two three four")
    let session = SessionStore()
    session.clock = { 0 }
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
    let defaults = UserDefaults(suiteName: "VidPromptTests.\(UUID().uuidString)")!
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
      alignment: "Right", showCues: false, highlightActiveWord: false)
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

    XCTAssertEqual(view.string, "- First point\n- Deuxième point\n\n1. One\n2. Two")
    XCTAssertEqual(coordinator.mappings.map { document.spokenTokens[$0.1].text },
      ["First", "point", "Deuxième", "point", "1", "One", "2", "Two"])
    XCTAssertEqual(coordinator.mappings.map { (view.string as NSString).substring(with: $0.0) },
      ["First", "point", "Deuxième", "point", "1.", "One", "2.", "Two"])
  }

  /// Short 172: only 118 of 534 words mapped. The list's "1." was read aloud but not shown, so it
  /// matched the "1" of a later "15" and every word after it mapped there or nowhere. The numbers
  /// are shown now, every word maps in order inside its own passage, and a read number dims.
  func testANumberedListScriptMapsEveryWordInOrderAndDimsTheNumbers() throws {
    let document = PrompterDocument(markdown: "The criteria are as follows:\n\n1. Individual performances\n2. Team achievements\n3. 2020. A year\n\nNine of his 15 goals came late.")
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 2_400))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)
    let tokens = document.spokenTokens
    XCTAssertTrue(text.string.contains("1. Individual performances\n2. Team achievements\n3. 2020. A year"), text.string)
    XCTAssertEqual(coordinator.mappings.map(\.1), Array(tokens.indices), "every spoken word is shown and mapped")
    let plain = text.string as NSString
    XCTAssertEqual(coordinator.mappings.map { plain.substring(with: $0.0).trimmingCharacters(in: .punctuationCharacters) },
      tokens.map(\.text))
    let locations = coordinator.mappings.map(\.0.location)
    XCTAssertEqual(locations, locations.sorted())
    func shown(_ index: Int) throws -> NSRange { try XCTUnwrap(coordinator.mappings.first { $0.1 == index }).0 }
    XCTAssertEqual(plain.substring(with: try shown(try XCTUnwrap(tokens.firstIndex { $0.text == "15" }))), "15")

    let one = try XCTUnwrap(tokens.firstIndex { $0.text == "1" })
    coordinator.tokenIndex = one + 1
    coordinator.lastConfirmedTokenIndex = one
    coordinator.updateReadState()
    let marker = try shown(one)
    XCTAssertEqual(plain.substring(with: marker), "1.")
    let dimmed = text.textStorage?.attribute(.foregroundColor, at: marker.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(dimmed?.alphaComponent ?? 0, 0.38, accuracy: 0.02, "a read number dims like a read word")

  }

  /// A spoken word the reading view does not show must not be looked for in later passages: a
  /// code fence's language tag once pulled every word after it onto a later "text".
  func testAWordThatIsNotShownNeverMapsIntoALaterPassage() {
    let document = PrompterDocument(markdown: "Intro line.\n\n```text\nQuoted words here\n```\n\nThe text had 15 goals.")
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 2_400))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)
    let tokens = document.spokenTokens
    let hidden = tokens.indices.filter { tokens[$0].blockID == document.blocks[1].id && tokens[$0].text == "text" }
    XCTAssertEqual(hidden.count, 1, "the fence's language tag is a spoken token the view does not show")
    XCTAssertEqual(coordinator.mappings.map(\.1), tokens.indices.filter { !hidden.contains($0) })
    let locations = coordinator.mappings.map(\.0.location)
    XCTAssertEqual(locations, locations.sorted())
  }

  /// The reading view and the editor lay one Markdown out the same way: same characters, paragraph
  /// styles, line fragments and height at equal width, font, spacing, alignment and inset.
  func testPresenterAndEditorShareOneMarkdownLayout() throws {
    let width: CGFloat = 320
    func measure(_ view: NSTextView) -> (fragments: [NSRect], height: CGFloat, styles: [[Double]]) {
      // Spacing is a float product (0.8 × 24 is 19.200000000000003), so styles are compared below with accuracy.
      let manager = view.layoutManager!
      manager.ensureLayout(for: view.textContainer!)
      var fragments: [NSRect] = []
      manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in
        fragments.append(rect)
      }
      var styles: [[Double]] = []
      let storage = view.textStorage!
      storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        let style = value as? NSParagraphStyle
        let row = [style?.lineSpacing ?? -1, style?.paragraphSpacing ?? -1, Double(style?.alignment.rawValue ?? -1)]
        styles += Array(repeating: row, count: range.length)
      }
      return (fragments, manager.usedRect(for: view.textContainer!).height, styles)
    }
    func makeView() -> NSTextView {
      let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
      view.textContainerInset = NSSize(width: 40, height: 80)
      view.textContainer?.widthTracksTextView = true
      return view
    }
    let cases: [(String, String)] = [
      ("single newline", "one two\nthree four"),
      ("blank line", "one two\n\nthree four"),
      ("trailing newline", "one two three\n"),
      ("heading and paragraph", "# A heading here\n\nThe paragraph that follows the heading."),
      ("ordered list", "1. First item\n2. Second item\n\nAfter the list"),
      ("unordered list", "- First item\n- Second item\n\nAfter the list"),
      ("link", "See [the linked words](https://example.com) for more"),
      ("stage direction", "Hello [pause for effect] world again"),
      ("mixed", "**bold** and *italic* and `code` in one line of text"),
    ]
    for (name, markdown) in cases {
      let typography = EditorTypography(lineSpacing: 12, paragraphSpacing: 19.2, horizontalInset: 40, alignment: .left)
      let editor = makeView()
      editor.textStorage?.setAttributedString(FormattedMarkdownEditModel(markdown: markdown)
        .rendered(fontName: "Helvetica", fontSize: 24, typography: typography))
      let expected = measure(editor)
      for showCues in [true, false] {
        let presenter = makeView()
        let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
        coordinator.textView = presenter
        coordinator.render(document: PrompterDocument(markdown: markdown), fontName: "Helvetica", fontSize: 24,
          textOpacity: 1, lineSpacing: 0.5, paragraphSpacing: 0.8, showCues: showCues)
        let actual = measure(presenter)
        XCTAssertEqual(presenter.string, editor.string, name)
        XCTAssertEqual(actual.styles.count, expected.styles.count, name)
        for (left, right) in zip(actual.styles, expected.styles) {
          XCTAssertEqual(left[0], right[0], accuracy: 0.001, name)  // line spacing
          XCTAssertEqual(left[1], right[1], accuracy: 0.001, name)  // paragraph spacing
          XCTAssertEqual(left[2], right[2], name)  // alignment, exactly
        }
        // Hidden cues collapse on purpose, so only the shown-cue presenter has the editor's line boxes.
        guard showCues else { continue }
        XCTAssertEqual(actual.fragments, expected.fragments, name)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, name)
      }
    }
  }

  func testTokenMappingsIdentifyEachSpokenTokenInRepeatedTextAndLists() {
    let markdown = "the cat and the cat\n\n- the cat\n- the dog\n\n1. the cat\n2. the dog\n\nthe cat and the cat"
    let document = PrompterDocument(markdown: markdown)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1)
    let tokens = document.spokenTokens
    XCTAssertEqual(coordinator.mappings.map(\.1), Array(tokens.indices))
    let plain = view.string as NSString
    XCTAssertEqual(coordinator.mappings.map { plain.substring(with: $0.0).trimmingCharacters(in: .punctuationCharacters) },
      tokens.map(\.text))
    // Each token lands in its own block, not at an earlier repeat of the same words.
    let model = FormattedMarkdownEditModel(markdown: markdown)
    let visible = model.visibleIndices()
    for (range, index) in coordinator.mappings {
      XCTAssertEqual(range.location, visible[tokens[index].sourceRange.location], "token \(index)")
    }
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

  // MARK: Manual mode painting

  private static let manualLines = (1...30).map { "Line \($0) with words." }.joined(separator: "\n\n")

  /// A coordinator drawing thirty short lines in a scroll view hosted by a window that is never
  /// shown, with `position` standing in for the session's Manual timeline.
  private func manualRig(
    markdown: String = PresenterControllerTests.manualLines, position: @escaping () -> Double
  ) -> (scroll: NSScrollView, text: NSTextView, coordinator: ScriptTextView.Coordinator, window: NSWindow) {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 2400))
    scroll.documentView = text
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = text
    coordinator.render(
      document: PrompterDocument(markdown: markdown), fontName: "Helvetica", fontSize: 24, textOpacity: 1)
    coordinator.setManualSource(position)
    return (scroll, text, coordinator, window)
  }

  /// Where the scroll must be for one word to sit on the guide, measured independently of the
  /// coordinator's own interpolation.
  private func guideScroll(
    _ index: Int, _ rig: (scroll: NSScrollView, text: NSTextView, coordinator: ScriptTextView.Coordinator, window: NSWindow)
  ) -> CGFloat {
    let mapping = rig.coordinator.mappings.first { $0.1 == index }!
    let manager = rig.text.layoutManager!
    manager.ensureLayout(for: rig.text.textContainer!)
    let glyph = manager.glyphRange(forCharacterRange: mapping.0, actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyph, in: rig.text.textContainer!)
    let guideY = max(54, rig.scroll.contentView.bounds.height * 0.35)
    return max(0, rect.midY + rig.text.textContainerInset.height - guideY)
  }

  func testManualPositionInterpolatesBetweenTokenMappingsAndReduceMotionStillProgresses() {
    let system = ScriptTextView.Coordinator.reducesMotion
    ScriptTextView.Coordinator.reducesMotion = { true }
    addTeardownBlock { @MainActor in ScriptTextView.Coordinator.reducesMotion = system }
    var position = 0.0
    let rig = manualRig { position }
    rig.coordinator.alignManual(in: rig.scroll)
    let y = { rig.scroll.contentView.bounds.origin.y }
    let indices = rig.coordinator.mappings.map(\.1)
    // The first word of each line, found from the layout rather than assumed.
    let lineStarts = indices.enumerated().filter { offset, index in
      offset == 0 || abs(guideScroll(index, rig) - guideScroll(indices[offset - 1], rig)) > 2
    }.map(\.element)
    XCTAssertGreaterThan(lineStarts.count, 10)
    let (a, b, c) = (lineStarts[5], lineStarts[6], lineStarts[7])

    position = Double(a)
    rig.coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(y(), guideScroll(a, rig), accuracy: 0.5, "a line's first word lands on the guide")
    XCTAssertEqual(rig.coordinator.tokenIndex, 0, "painting never touches the published frontier")

    position = Double(a) + Double(b - a) / 2
    rig.coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(y(), (guideScroll(a, rig) + guideScroll(b, rig)) / 2, accuracy: 0.5,
      "halfway through a line the scroll is halfway to the next one")

    position = Double(b - 1) + 0.5
    rig.coordinator.alignManual(in: rig.scroll)
    let expected = guideScroll(a, rig) + (guideScroll(b, rig) - guideScroll(a, rig)) * (position - Double(a)) / Double(b - a)
    XCTAssertEqual(y(), expected, accuracy: 0.5, "a fraction inside the last word of a line")

    // Sampled a quarter word at a time, the scroll rises at every step across three lines.
    var previous = -CGFloat.infinity
    var t = Double(a)
    while t <= Double(c) {
      position = t
      rig.coordinator.alignManual(in: rig.scroll)
      XCTAssertGreaterThan(y(), previous, "no plateau at position \(t)")
      previous = y()
      t += 0.25
    }
    XCTAssertEqual(y(), guideScroll(c, rig), accuracy: 0.5)

    position = 1_000
    rig.coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(y(), guideScroll(indices.last!, rig), accuracy: 0.5, "past the end it holds on the last line")
    position = 0
    rig.coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(y(), guideScroll(0, rig), accuracy: 0.5)
  }

  func testManualDisplayLinkExistsOnlyWhileManualRunsAndIsGoneAfterPauseAndDismantle() {
    let rig = manualRig { 0 }
    let coordinator = rig.coordinator
    XCTAssertFalse(coordinator.isDisplayLinkActive, "nothing until Play")
    coordinator.isActivelyRunning = true
    coordinator.updateDisplayLink(for: rig.scroll)
    XCTAssertTrue(coordinator.isDisplayLinkActive)
    coordinator.updateDisplayLink(for: rig.scroll)
    XCTAssertTrue(coordinator.isDisplayLinkActive, "one link, not one per update")
    coordinator.isActivelyRunning = false
    coordinator.updateDisplayLink(for: rig.scroll)
    XCTAssertFalse(coordinator.isDisplayLinkActive, "paused, stopped and completed all end it")

    coordinator.isActivelyRunning = true
    coordinator.updateDisplayLink(for: rig.scroll)
    XCTAssertTrue(coordinator.isDisplayLinkActive)
    ScriptTextView.dismantleNSView(rig.scroll, coordinator: coordinator)
    XCTAssertFalse(coordinator.isDisplayLinkActive, "a dismantled view does no per-frame work")

    // Voice hands the presenter no Manual source and never gets a link, running or not.
    coordinator.setManualSource(nil)
    coordinator.updateDisplayLink(for: rig.scroll)
    XCTAssertFalse(coordinator.isDisplayLinkActive)
  }

  func testLiveUserScrollPausesManualAndSeeksButProgrammaticMovementDoesNot() {
    var now = 100.0
    let session = SessionStore()
    session.clock = { now }
    var settings = PrompterSettings(); settings.mode = "Manual"; settings.speed = 60
    session.present(
      record: ScriptRecord(
        metadata: .init(title: "Lines", fileName: "lines.md"), markdown: Self.manualLines),
      settings: settings)
    let rig = manualRig { session.manualPosition() }
    let coordinator = rig.coordinator
    coordinator.onSeek = session.seek
    coordinator.onUserScroll = session.seekFromUserScroll
    coordinator.observeUserScrolls(in: rig.scroll)
    defer { coordinator.stopObservingUserScrolls() }
    session.play()
    let revision = session.seekRevision

    // Playback and alignment move the scroll and post nothing user-driven.
    now = 110
    coordinator.alignManual(in: rig.scroll)
    coordinator.applyManualPosition(12.5, in: rig.scroll)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: rig.scroll)
    XCTAssertEqual(session.state, .running)
    XCTAssertEqual(session.seekRevision, revision)

    // A hand on the scroll wheel pauses and seeks to the word at the guide.
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: rig.scroll)
    rig.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: rig.scroll)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: rig.scroll)
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.seekRevision, revision + 1)
    let landed = session.tokenIndex
    XCTAssertGreaterThan(landed, 12)
    XCTAssertEqual(session.manualPosition(), Double(landed), accuracy: 1e-9)
    now = 500
    XCTAssertEqual(session.manualPosition(), Double(landed), accuracy: 1e-9, "no resume until Play")
    session.play()
    now = 501
    XCTAssertEqual(session.manualPosition(), Double(landed) + 1, accuracy: 1e-9)
    session.pause()
  }

  func testHandScrolledManualIsNotPulledBackUntilPlayOrAnExplicitSeek() {
    let session = SessionStore()
    var settings = PrompterSettings(); settings.mode = "Manual"
    session.present(
      record: ScriptRecord(
        metadata: .init(title: "Lines", fileName: "lines.md"), markdown: Self.manualLines),
      settings: settings)
    let rig = manualRig { session.manualPosition() }
    let coordinator = rig.coordinator
    coordinator.onSeek = session.seek
    coordinator.onUserScroll = session.seekFromUserScroll
    coordinator.observeUserScrolls(in: rig.scroll)
    defer { coordinator.stopObservingUserScrolls() }
    session.play()
    coordinator.isActivelyRunning = true
    let y = { rig.scroll.contentView.bounds.origin.y }

    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: rig.scroll)
    rig.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: rig.scroll)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: rig.scroll)
    let handY = y()
    coordinator.isActivelyRunning = false  // what updateNSView reports after the pause
    XCTAssertTrue(coordinator.isHandScrolled)
    XCTAssertTrue(coordinator.noteSeekRevision(session.seekRevision), "the hand's own seek")

    // updateNSView, onLayout and the display link all land here.
    coordinator.alignManual(in: rig.scroll)
    coordinator.alignToCurrent(in: rig.scroll)
    XCTAssertEqual(y(), handY, accuracy: 0.01, "the reader's scroll is not pulled back")

    // An explicit seek (Next passage, a click) aligns again.
    session.seek(to: 3)
    XCTAssertTrue(coordinator.noteSeekRevision(session.seekRevision))
    let explicitTarget = try! XCTUnwrap(coordinator.manualScrollY(at: 3, in: rig.scroll))
    coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(y(), explicitTarget, accuracy: 0.5)

    // Play lifts the suppression too.
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: rig.scroll)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: rig.scroll)
    rig.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
    let secondHandY = y()
    coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(y(), secondHandY, accuracy: 0.01)
    coordinator.isActivelyRunning = true
    coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(y(), explicitTarget, accuracy: 0.5)
    session.pause()
  }

  func testEmptyLiveScrollGestureDoesNotFreezeRunningManualMode() {
    let rig = manualRig { 3 }
    let coordinator = rig.coordinator
    coordinator.observeUserScrolls(in: rig.scroll)
    defer { coordinator.stopObservingUserScrolls() }
    coordinator.isActivelyRunning = true

    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: rig.scroll)
    rig.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: rig.scroll)

    XCTAssertFalse(coordinator.isHandScrolled)
    let expected = try! XCTUnwrap(coordinator.manualScrollY(at: 3, in: rig.scroll))
    coordinator.alignManual(in: rig.scroll)
    XCTAssertEqual(rig.scroll.contentView.bounds.origin.y, expected, accuracy: 0.5)
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

  /// The stored Bool of 0.10 and earlier becomes a display mode without loss, Video only survives a
  /// relaunch, and the old key still says whether video is on for an older build.
  func testDisplayModeMigratesTheStoredBoolAndKeepsItWritten() {
    for (legacy, expected) in [(false, PresenterDisplayMode.prompterOnly), (true, .prompterWithVideo)] {
      let suite = "VidPrompt.presenter.\(UUID().uuidString)"
      addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
      let store = UserDefaults(suiteName: suite)!
      store.set(legacy, forKey: "presenterWithVideo")
      let model = CameraModel(defaults: store)
      XCTAssertEqual(model.displayMode, expected, "stored \(legacy)")
      XCTAssertEqual(store.bool(forKey: "presenterWithVideo"), legacy, "opening rewrites nothing")
      model.displayMode = .videoOnly
      XCTAssertEqual(CameraModel(defaults: store).displayMode, .videoOnly)
      XCTAssertTrue(store.bool(forKey: "presenterWithVideo"), "an older build still shows video")
      XCTAssertTrue(model.presentsWithVideo, "the camera is shown in Video only")
      model.presentsWithVideo = true
      XCTAssertEqual(model.displayMode, .videoOnly, "already showing video: nothing to change")
      model.presentsWithVideo = false
      XCTAssertEqual(CameraModel(defaults: store).displayMode, .prompterOnly)
    }
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
    let suite = "VidPrompt.presenter.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let model = CameraModel(defaults: UserDefaults(suiteName: suite)!)
    model.presentsWithVideo = true
    model.presentsWithVideo = false
    XCTAssertEqual(session.tokenIndex, target)
    XCTAssertEqual(session.activeToken?.normalised, "12")
    XCTAssertEqual(session.isActivelyRunning, running)
    XCTAssertNil(session.anchorNotice)
  }

  /// `orderOut` already lets the camera go (see `CameraStageTests`); `closeNow` then drops the
  /// hosting view, and that swap must release the holder too rather than keep it for ever.
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

  // MARK: Presenter window

  /// A presenter panel that never reaches the screen. Visibility, minimising, full screen and
  /// AppKit's transition are stood in for, and ordering out is recorded.
  private final class FakePanel: PresenterPanel {
    var shown = true
    var minimised = false
    var fullScreen = false
    var transitions = 0
    var orderedOut = false
    override var isVisible: Bool { shown }
    override var isMiniaturized: Bool { minimised }
    override var isInFullScreen: Bool { fullScreen }
    override func performFullScreenTransition(_ sender: Any?) { transitions += 1 }
    override func orderOut(_ sender: Any?) { orderedOut = true; shown = false }
  }

  private func videoModel() -> (CameraModel, UserDefaults) {
    let suite = "VidPrompt.presenter.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    return (CameraModel(defaults: defaults), defaults)
  }
  private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  private func assertFrame(_ frame: NSRect, _ expected: NSRect, _ message: String, line: UInt = #line) {
    for (a, b) in [(frame.minX, expected.minX), (frame.minY, expected.minY), (frame.width, expected.width), (frame.height, expected.height)] {
      XCTAssertEqual(a, b, accuracy: 1, "\(message): \(frame) is not \(expected)", line: line)
    }
  }
  /// A windowed presenter, and the frame Match Camera Size gives it for a vertical feed.
  private func windowedPanel(_ controller: PresenterController) throws -> (FakePanel, start: NSRect, fitted: NSRect) {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw XCTSkip("no screen") }
    let panel = FakePanel(captureVisible: false)
    let start = NSRect(x: 100, y: 100, width: 760, height: 520)
    panel.setFrame(start, display: false)
    controller.panel = panel
    let fitted = PresenterController.matchedCameraFrame(
      picture: SharedCameraSession.shared.pictureSize ?? CGSize(width: 16, height: 9),
      rotation: .quarter, in: (panel.screen ?? screen).visibleFrame)
    XCTAssertGreaterThan(abs(fitted.width - start.width) + abs(fitted.height - start.height), 20,
      "the fit must change the frame for this to prove anything")
    return (panel, start, fitted)
  }

  /// At rest the panel is Auxiliary, so it floats over another app's full-screen Space (OBS). It
  /// is Primary only while a full screen of its own lasts, however that was asked for, and a close
  /// from full screen leaves the Space before the window goes.
  func testFullScreenIsPrimaryOnlyWhileItLastsAndClosingFromItLeavesTheSpaceFirst() throws {
    let controller = PresenterController(camera: videoModel().0)
    let panel = FakePanel(captureVisible: false)
    panel.delegate = controller
    controller.panel = panel
    func note(_ name: Notification.Name) -> Notification { Notification(name: name, object: panel) }
    func assertResting(_ message: String, line: UInt = #line) {
      XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary), message, line: line)
      XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenPrimary), message, line: line)
      XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces), message, line: line)
      XCTAssertEqual(panel.level, .floating, message, line: line)
    }
    func assertPrimary(_ message: String, line: UInt = #line) {
      XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenPrimary), message, line: line)
      XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary), message, line: line)
    }
    XCTAssertTrue(panel.styleMask.contains(.resizable))
    assertResting("at rest")

    // Prompter > Presenter Full Screen.
    controller.toggleFullScreen()
    XCTAssertEqual(panel.transitions, 1)
    assertPrimary("asking for full screen makes it Primary for the transition")
    panel.fullScreen = true
    controller.windowWillEnterFullScreen(note(NSWindow.willEnterFullScreenNotification))
    controller.windowDidEnterFullScreen(note(NSWindow.didEnterFullScreenNotification))
    XCTAssertEqual(panel.level, .normal)
    assertPrimary("during full screen")

    // The red button, or Cmd-W, in full screen.
    XCTAssertFalse(controller.windowShouldClose(panel), "the window must not close inside its Space")
    XCTAssertEqual(panel.transitions, 2, "it leaves full screen first")
    XCTAssertTrue(controller.closesAfterFullScreen)
    XCTAssertFalse(panel.orderedOut)
    panel.fullScreen = false
    controller.windowDidExitFullScreen(note(NSWindow.didExitFullScreenNotification))
    XCTAssertTrue(panel.orderedOut, "then it closes")
    XCTAssertFalse(controller.closesAfterFullScreen)
    assertResting("after the exit")

    // The green button goes to full screen too, and a failed entry puts Auxiliary back.
    panel.shown = true
    panel.orderedOut = false
    let zoom = try XCTUnwrap(panel.standardWindowButton(.zoomButton))
    XCTAssertTrue(zoom.target === panel)
    XCTAssertEqual(zoom.action, #selector(NSWindow.toggleFullScreen(_:)))
    XCTAssertTrue(NSApplication.shared.sendAction(zoom.action!, to: zoom.target, from: zoom))
    XCTAssertEqual(panel.transitions, 3)
    assertPrimary("the green button asks for full screen")
    controller.windowDidFailToEnterFullScreen(panel)
    assertResting("after a failed entry")

    // View > Enter Full Screen (Ctrl-Cmd-F) stays available at rest and lands in the same place.
    let viewItem = NSMenuItem(title: "", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    XCTAssertTrue(panel.validateMenuItem(viewItem))
    XCTAssertTrue(panel.validateUserInterfaceItem(viewItem), "and on the validation path the menu may use instead")
    XCTAssertEqual(viewItem.title, "Enter Full Screen")
    XCTAssertTrue(NSApplication.shared.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: panel, from: viewItem))
    XCTAssertEqual(panel.transitions, 4)
    panel.fullScreen = true
    controller.windowDidEnterFullScreen(note(NSWindow.didEnterFullScreenNotification))
    XCTAssertTrue(panel.validateMenuItem(viewItem))
    XCTAssertEqual(viewItem.title, "Exit Full Screen")

    // A close AppKit could not act on yet is tried again once the entry has finished...
    controller.closeNow()
    XCTAssertEqual(panel.transitions, 5)
    XCTAssertTrue(controller.closesAfterFullScreen)
    controller.windowDidEnterFullScreen(note(NSWindow.didEnterFullScreenNotification))
    XCTAssertEqual(panel.transitions, 6, "the close is retried after the entry")
    // ...and a failed exit clears it, leaving a presenter that is still in its Space.
    controller.windowDidFailToExitFullScreen(panel)
    XCTAssertFalse(controller.closesAfterFullScreen, "a failed exit must not close the next exit")
    XCTAssertFalse(panel.orderedOut)
    XCTAssertEqual(panel.level, .normal)
    assertPrimary("still full screen after a failed exit")
    panel.fullScreen = false
    controller.windowDidFailToExitFullScreen(panel)
    assertResting("a failed exit that did leave full screen rests again")
    XCTAssertFalse(panel.orderedOut)
    XCTAssertTrue(controller.windowShouldClose(panel), "a windowed presenter closes normally")
  }

  /// The real change handler: turning video on fits a windowed presenter once. Opening with video
  /// already on, a closed or minimised presenter, full screen and turning video off never resize.
  func testTurningVideoOnFitsTheWindowOnlyWhenItIsWindowedOnScreen() throws {
    let (model, _) = videoModel()
    model.setRotation(.quarter)
    model.presentsWithVideo = true
    let controller = PresenterController(camera: model)
    let (panel, start, fitted) = try windowedPanel(controller)
    settle()
    assertFrame(panel.frame, start, "opening with video already on")

    for (name, hide, show): (String, (FakePanel) -> Void, (FakePanel) -> Void) in [
      ("closed", { $0.shown = false }, { $0.shown = true }),
      ("minimised", { $0.minimised = true }, { $0.minimised = false }),
      ("full screen", { $0.fullScreen = true }, { $0.fullScreen = false }),
    ] {
      hide(panel)
      controller.toggleVideo()
      controller.toggleVideo()
      XCTAssertTrue(model.presentsWithVideo)
      settle()
      controller.matchCameraSize()  // Prompter > Match Camera Size is held back the same way
      assertFrame(panel.frame, start, name)
      show(panel)
    }
    controller.toggleVideo()
    settle()
    assertFrame(panel.frame, start, "video off")
    controller.toggleVideo()
    settle()
    assertFrame(panel.frame, fitted, "video on in a windowed presenter")
  }

  /// The capsule button, Prompter > Present with Video and the inspector's Mode are one switch:
  /// each flips the same stored property, and each reaches the presenter's fit.
  func testTheCapsuleTheMenuAndTheInspectorModeAreOneSwitch() throws {
    let (model, defaults) = videoModel()
    model.setRotation(.quarter)
    let controller = PresenterController(camera: model)
    let (panel, start, fitted) = try windowedPanel(controller)
    let menu = PresenterVideoItems(camera: model)
    let inspectorMode = ObservedObject(wrappedValue: model).projectedValue.presentsWithVideo
    XCTAssertFalse(menu.choice(.prompterWithVideo).wrappedValue)

    controller.toggleVideo()  // the capsule button's action
    XCTAssertTrue(menu.choice(.prompterWithVideo).wrappedValue, "the menu shows a tick")
    XCTAssertTrue(inspectorMode.wrappedValue, "the inspector shows Prompter + video")
    settle()
    assertFrame(panel.frame, fitted, "the capsule")

    panel.setFrame(start, display: false)
    menu.choice(.prompterWithVideo).wrappedValue = false  // Prompter > Present with Video
    XCTAssertFalse(model.presentsWithVideo, "the capsule shows video off")
    XCTAssertFalse(inspectorMode.wrappedValue)
    menu.choice(.prompterWithVideo).wrappedValue = true
    settle()
    assertFrame(panel.frame, fitted, "the menu")

    panel.setFrame(start, display: false)
    inspectorMode.wrappedValue = false
    XCTAssertFalse(menu.choice(.prompterWithVideo).wrappedValue)
    inspectorMode.wrappedValue = true
    settle()
    assertFrame(panel.frame, fitted, "the inspector")
    XCTAssertTrue(CameraModel(defaults: defaults).presentsWithVideo, "the choice outlives the model")
  }

  /// Text width is kept between 0.3 and 1 however it arrives, persists, and narrows the real
  /// reading view and the real in-place editor, with the anchor back on the guide line.
  func testTextWidthIsClampedAndNarrowsTheRealReadingViewAndEditor() throws {
    var clamped = PrompterSettings()
    clamped.textWidth = 0.05
    XCTAssertEqual(clamped.textWidth, 0.3)
    clamped.textWidth = 4
    XCTAssertEqual(clamped.textWidth, 1)
    let decoder = JSONDecoder()
    XCTAssertEqual(try decoder.decode(PrompterSettings.self, from: Data(#"{"textWidth":0.1}"#.utf8)).textWidth, 0.3)
    XCTAssertEqual(try decoder.decode(PrompterSettings.self, from: Data(#"{"textWidth":9}"#.utf8)).textWidth, 1)
    XCTAssertEqual(try decoder.decode(PrompterSettings.self, from: Data(#"{"horizontalMargin":80}"#.utf8)).textWidth, 1)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VidPromptTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(store.settings.textWidth, 1)
    let markdown = (1...20).map { "Passage \($0) with useful words for a wide column." }.joined(separator: "\n\n")
    let record = ScriptRecord(metadata: .init(title: "Width", fileName: "width.md", revision: 1,
      contentFingerprint: "one"), markdown: markdown)
    store.session.present(record: record, settings: store.settings)
    let target = try XCTUnwrap(store.session.document.spokenTokens.firstIndex { $0.normalised == "12" })
    store.session.seek(to: target)
    store.settings.textWidth = 0.4
    store.session.updateSettings(store.settings)
    XCTAssertEqual(store.session.tokenIndex, target, "a width change never moves the anchor")
    XCTAssertEqual(AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
      .settings.textWidth, 0.4)

    let size = NSSize(width: 1600, height: 900)
    let document = store.session.document
    func reader(_ textWidth: Double) -> ScriptTextView {
      ScriptTextView(document: document, tokenIndex: target, guideFraction: 0.35, fontName: "Helvetica",
        fontSize: 44, textOpacity: 1,
        horizontalMargin: ScriptTextView.sideInset(width: size.width, textWidth: textWidth), onSeek: { _ in })
    }
    let readerHost = host(reader(1), size: size)
    let text = try XCTUnwrap(firstTextView(in: readerHost))
    let scroll = try XCTUnwrap(text.enclosingScrollView)
    XCTAssertEqual(text.textContainerInset.width, 42, accuracy: 0.5)
    try assertOnGuide(text, scroll: scroll, visibleIndex: rangeOfPassageNumber(12, in: text).location, "full width")
    let wideOrigin = scroll.contentView.bounds.origin.y

    readerHost.rootView = reader(store.settings.textWidth)
    settle()
    XCTAssertEqual(text.textContainerInset.width, 480, accuracy: 0.5)
    XCTAssertEqual(try XCTUnwrap(text.textContainer).size.width, text.bounds.width - 960, accuracy: 0.5)
    XCTAssertGreaterThan(abs(scroll.contentView.bounds.origin.y - wideOrigin), 20, "the narrow column must reflow")
    try assertOnGuide(text, scroll: scroll, visibleIndex: rangeOfPassageNumber(12, in: text).location, "narrow")

    let token = document.spokenTokens[target]
    func editor(_ textWidth: Double) -> FormattedMarkdownEditor {
      FormattedMarkdownEditor(markdown: .constant(markdown), fontName: "Helvetica", fontSize: 44,
        typography: EditorTypography(horizontalInset: ScriptTextView.sideInset(width: size.width, textWidth: textWidth)),
        anchorSourceOffset: token.sourceRange.location, guideFraction: 0.35)
    }
    let editorHost = host(editor(store.settings.textWidth), size: size)
    let editing = try XCTUnwrap(firstTextView(in: editorHost))
    let editingScroll = try XCTUnwrap(editing.enclosingScrollView)
    XCTAssertEqual(editing.textContainerInset.width, 480, accuracy: 0.5)
    XCTAssertEqual(try XCTUnwrap(editing.textContainer).size.width, editing.bounds.width - 960, accuracy: 0.5)
    let visible = try XCTUnwrap(FormattedMarkdownEditModel(markdown: markdown)
      .visibleIndex(forSourceOffset: token.sourceRange.location))
    try assertOnGuide(editing, scroll: editingScroll, visibleIndex: visible, "in-place editor")
    editorHost.rootView = editor(1)
    settle()
    XCTAssertEqual(editing.textContainerInset.width, 42, accuracy: 0.5, "the editor follows a width change")
  }

  private func host<V: View>(_ view: V, size: NSSize) -> NSHostingView<V> {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                          backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    settle()
    return host
  }
  private func firstTextView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for child in view.subviews { if let text = firstTextView(in: child) { return text } }
    return nil
  }
  private func rangeOfPassageNumber(_ number: Int, in text: NSTextView) throws -> NSRange {
    let whole = (text.string as NSString).range(of: "Passage \(number) ")
    XCTAssertNotEqual(whole.location, NSNotFound)
    return NSRange(location: whole.location + 8, length: String(number).count)
  }
  private func assertOnGuide(_ text: NSTextView, scroll: NSScrollView, visibleIndex: Int, _ message: String,
                             line: UInt = #line) throws {
    let manager = try XCTUnwrap(text.layoutManager)
    let container = try XCTUnwrap(text.textContainer)
    manager.ensureLayout(for: container)
    let glyph = manager.glyphRange(forCharacterRange: NSRange(location: visibleIndex, length: 1), actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
    let clip = scroll.contentView.bounds
    XCTAssertGreaterThan(clip.origin.y, 1, "\(message): the passage must need scrolling", line: line)
    XCTAssertEqual(rect.midY + text.textContainerInset.height - clip.origin.y,
      ScriptTextView.visualGuideY(height: clip.height, fraction: 0.35), accuracy: 2, message, line: line)
  }

  /// Over video the backdrop uses its own, light dimming, so switching modes never blacks the
  /// picture out; Prompter only keeps its background opacity.
  func testBackdropOpacityFollowsTheModeAndVideoDimmingPersists() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VidPromptTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(store.settings.backdropOpacity(withVideo: false), 0.82)
    XCTAssertEqual(store.settings.backdropOpacity(withVideo: true), 0.25)
    store.settings.videoDimming = 0.6
    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults).settings
    XCTAssertEqual(reopened.backdropOpacity(withVideo: true), 0.6)
    XCTAssertEqual(reopened.backdropOpacity(withVideo: false), 0.82, "Prompter only is unchanged")
  }

  /// The inspector's single Background opacity control edits the stored value for the mode in
  /// use and leaves the other mode's alone; both keep their saved keys.
  func testOneBackgroundOpacityControlEditsTheValueForTheModeInUse() throws {
    var settings = PrompterSettings()
    settings.setBackdropOpacity(0.5, withVideo: false)
    XCTAssertEqual(settings.backgroundOpacity, 0.5)
    XCTAssertEqual(settings.videoDimming, 0.25, "Prompter only leaves the video value alone")
    settings.setBackdropOpacity(0.6, withVideo: true)
    XCTAssertEqual(settings.videoDimming, 0.6)
    XCTAssertEqual(settings.backgroundOpacity, 0.5, "video leaves the Prompter-only value alone")
    XCTAssertEqual(settings.backdropOpacity(withVideo: true), 0.6)
    XCTAssertEqual(settings.backdropOpacity(withVideo: false), 0.5)
    XCTAssertEqual(PrompterSettings.backdropOpacityRange(withVideo: true), 0...0.9, "the picture never blacks out")
    XCTAssertEqual(PrompterSettings.backdropOpacityRange(withVideo: false), 0...1)
    let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    XCTAssertEqual(stored["videoDimming"] as? Double, 0.6)
    XCTAssertEqual(stored["backgroundOpacity"] as? Double, 0.5)
  }

  /// The reading line's opacity persists and is what the line is drawn with.
  func testGuideOpacityPersistsAndReachesTheLine() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: "VidPromptTests.\(UUID().uuidString)")!
    let store = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults)
    XCTAssertEqual(store.settings.guideOpacity, 0.82, "the default keeps the current look")
    store.settings.guideOpacity = 0.25
    let reopened = AppStore(arguments: ["test", "--data-directory", root.path], defaults: defaults).settings
    XCTAssertEqual(reopened.guideOpacity, 0.25)

    func drawnAlpha(_ settings: PrompterSettings) throws -> CGFloat {
      let renderer = ImageRenderer(content: GuideLine(settings: settings).frame(width: 8))
      renderer.scale = 1
      let image = try XCTUnwrap(renderer.cgImage)
      return try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 4, y: 1)).alphaComponent
    }
    XCTAssertEqual(try drawnAlpha(reopened), 0.25, accuracy: 0.02)
    XCTAssertEqual(try drawnAlpha(PrompterSettings()), 0.82, accuracy: 0.02)
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

  /// Callouts are production notes: gone from the presented text (not greyed), while every
  /// spoken word after one still maps to its own characters and greys as it is read.
  func testPresenterOmitsCalloutsAndReadGreyingStaysAlignedAfterThem() throws {
    let markdown = "Intro words here.\n\n> [!info] Graphic — stats\n> **24.7%** possession [cue]\n\n> [!tip] Second\n> more notes\n\nAfter the graphic we speak."
    let document = PrompterDocument(markdown: markdown)
    for showCues in [true, false] {
      let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
      coordinator.textView = view
      let graphic = try XCTUnwrap(document.spokenTokens.firstIndex { $0.normalised == "graphic" })
      coordinator.tokenIndex = graphic
      coordinator.lastConfirmedTokenIndex = graphic
      coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1, showCues: showCues)
      XCTAssertEqual(view.string, "Intro words here.\n\nAfter the graphic we speak.")
      XCTAssertEqual(coordinator.mappings.count, document.spokenTokens.count)
      let plain = view.string as NSString
      for (range, index) in coordinator.mappings {
        XCTAssertTrue(plain.substring(with: range).hasPrefix(document.spokenTokens[index].text))
        let colour = view.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour?.alphaComponent ?? 0, index <= graphic ? 0.38 : 1, accuracy: 0.02, "\(index)")
      }
    }
  }

  /// Editing a callout moves no reading position, since it has no words to track.
  func testEditingACalloutKeepsTheAnchor() throws {
    let markdown = "Opening lines.\n\n> [!info] Graphic\n> old notes\n\nTarget passage words."
    let record = ScriptRecord(metadata: .init(title: "Callout", fileName: "callout.md", revision: 1,
      contentFingerprint: "one"), markdown: markdown)
    let session = SessionStore()
    session.present(record: record, settings: PrompterSettings())
    session.seek(to: try XCTUnwrap(session.document.spokenTokens.firstIndex { $0.normalised == "target" }))
    var next = record
    next.metadata.revision = 2
    next.metadata.contentFingerprint = "two"
    next.markdown = markdown.replacingOccurrences(of: "old notes", with: "rewritten notes with target words")
    session.applyEditedRecord(next)
    XCTAssertEqual(session.activeToken?.normalised, "target")
    XCTAssertEqual(session.document.spokenTokens.map(\.text), ["Opening", "lines", "Target", "passage", "words"])
    XCTAssertNil(session.anchorNotice)
  }

  /// Junior's real Short 181 script, copied to a temporary folder: set JP_CALLOUT_FIXTURE to run.
  func testRealScriptPresentsEverySpokenParagraphAndNoCallout() throws {
    guard let path = ProcessInfo.processInfo.environment["JP_CALLOUT_FIXTURE"] else {
      throw XCTSkip("JP_CALLOUT_FIXTURE not set")
    }
    let markdown = try String(contentsOfFile: path, encoding: .utf8)
    let document = PrompterDocument(markdown: markdown)
    let callouts = document.blocks.filter { $0.kind == .callout }
    XCTAssertEqual(callouts.count, 8)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    coordinator.render(document: document, fontName: "Helvetica", fontSize: 30, textOpacity: 1)
    XCTAssertFalse(view.string.contains("Graphic"))
    XCTAssertFalse(view.string.contains("Source:"))
    let spoken = document.blocks.filter { $0.kind != .callout }.map {
      $0.rawMarkdown.trimmingCharacters(in: .whitespaces)
    }
    var cursor = view.string.startIndex
    for paragraph in spoken {
      let range = try XCTUnwrap(view.string.range(of: paragraph, range: cursor..<view.string.endIndex), paragraph)
      cursor = range.upperBound
    }
    XCTAssertEqual(coordinator.mappings.count, document.spokenTokens.count)
    let editor = FormattedMarkdownEditModel(markdown: markdown).rendered()
    var titles = 0
    editor.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: editor.length)) { value, _, _ in
      if (value as? NSParagraphStyle)?.textBlocks.isEmpty == false { titles += 1 }
    }
    XCTAssertGreaterThan(titles, 0)
    for callout in callouts {
      let title = try XCTUnwrap(callout.rawMarkdown.components(separatedBy: "\n").first?
        .replacingOccurrences(of: "> [!info] ", with: ""))
      let range = (editor.string as NSString).range(of: title)
      XCTAssertNotEqual(range.location, NSNotFound, title)
      guard range.location != NSNotFound else { continue }
      XCTAssertEqual(editor.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .systemBlue)
      XCTAssertFalse((editor.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
        .textBlocks.isEmpty ?? true, title)
    }
    XCTAssertFalse(editor.string.contains("[!info]"))
  }
}
