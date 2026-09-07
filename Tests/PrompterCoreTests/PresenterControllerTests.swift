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
    coordinator.updateReadState()
    let first = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    let second = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[1].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(first?.alphaComponent ?? 0, 0.6 * 0.38, accuracy: 0.02)
    XCTAssertEqual(second?.alphaComponent ?? 0, 0.6, accuracy: 0.02)
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
    coordinator.updateReadState()
    coordinator.tokenIndex = 1
    coordinator.updateReadState()
    let first = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[0].0.location, effectiveRange: nil) as? NSColor
    let second = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[1].0.location, effectiveRange: nil) as? NSColor
    let third = view.textStorage?.attribute(.foregroundColor, at: coordinator.mappings[2].0.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(first?.alphaComponent ?? 0, 0.8 * 0.38, accuracy: 0.02)
    XCTAssertEqual(second?.alphaComponent ?? 0, 0.8, accuracy: 0.02)
    XCTAssertEqual(third?.alphaComponent ?? 0, 0.8, accuracy: 0.02)
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

    coordinator.align(scroll: scroll, tokenIndex: 5, guideFraction: 0.35)
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    let intermediate = scroll.contentView.bounds.origin.y
    let target = target(for: 5)
    XCTAssertTrue(min(start, target) < intermediate && intermediate < max(start, target))
    coordinator.align(scroll: scroll, tokenIndex: 10, guideFraction: 0.35)
    coordinator.snapNextAlignment = true
    coordinator.align(scroll: scroll, tokenIndex: 0, guideFraction: 0.35)
    XCTAssertEqual(scroll.contentView.bounds.origin.y, start, accuracy: 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.24))
    XCTAssertEqual(scroll.contentView.bounds.origin.y, start, accuracy: 1)
  }
}
