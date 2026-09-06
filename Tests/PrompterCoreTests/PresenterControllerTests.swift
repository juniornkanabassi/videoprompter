import AppKit
import XCTest
@testable import JuniorPrompter
import PrompterCore

@MainActor
final class PresenterControllerTests: XCTestCase {
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
        let guideY = max(54, (size.height + 52) * 0.35) - 52
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
}
