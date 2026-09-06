import AppKit
import XCTest

@testable import JuniorPrompter
import PrompterCore

@MainActor
final class TypographyTests: XCTestCase {
  func testMarkdownTraitsAndHeadingScaleReachTextView() {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let coordinator = ScriptTextView.Coordinator(onSeek: { _ in })
    coordinator.textView = view
    coordinator.render(
      document: PrompterDocument(markdown: "# Heading\n\n**bold** and *italic* and `code`"),
      fontName: "Helvetica", fontSize: 24, textOpacity: 1)

    let storage = try! XCTUnwrap(view.textStorage)
    let heading = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    let boldRange = (view.string as NSString).range(of: "bold")
    let italicRange = (view.string as NSString).range(of: "italic")
    let bold = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
    let italic = storage.attribute(.font, at: italicRange.location, effectiveRange: nil) as! NSFont
    let manager = NSFontManager.shared
    XCTAssertGreaterThan(heading.pointSize, bold.pointSize)
    XCTAssertTrue(manager.traits(of: bold).contains(.boldFontMask))
    XCTAssertTrue(manager.traits(of: italic).contains(.italicFontMask))
    XCTAssertTrue(view.string.contains("\n\n"))
  }
}
