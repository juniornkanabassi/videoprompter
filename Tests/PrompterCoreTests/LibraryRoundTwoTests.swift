import AppKit
import PrompterCore
import SwiftUI
import XCTest
@testable import VideoPrompter

@MainActor final class LibraryRoundTwoTests: XCTestCase {
  func testHiddenStageDirectionsAreRemovedAndFollowingWordsKeepTheirSeekMapping() throws {
    let source = "# Bonjour\n\nHello [look left] à tous. [Smile.] Welcome back."
    let document = PrompterDocument(markdown: source)
    let text = TrackingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    var sought: Int?
    let coordinator = ScriptTextView.Coordinator(onSeek: { sought = $0 })
    coordinator.textView = text
    for showsCues in [true, false, true] {
      coordinator.render(document: document, fontName: "Helvetica", fontSize: 24, textOpacity: 1, showCues: showsCues)
      XCTAssertEqual(text.string.contains("look left"), showsCues)
      XCTAssertEqual(text.string.contains("Smile"), showsCues)
      let offset = (text.string as NSString).range(of: "Welcome").location
      XCTAssertNotEqual(offset, NSNotFound)
      coordinator.seek(offset)
      XCTAssertEqual(sought, document.spokenTokens.firstIndex { $0.text == "Welcome" })
      for (range, index) in coordinator.mappings {
        let rendered = (text.string as NSString).substring(with: range)
        XCTAssertTrue(rendered.hasPrefix(document.spokenTokens[index].text), "\(rendered) must map to its source word")
      }
    }
  }

  func testWelcomeCalloutUsesAvailableWidth() throws {
    let rendered = FormattedMarkdownEditModel(markdown: WelcomeScript.markdown).rendered(fontSize: 18)
    let start = (rendered.string as NSString).range(of: "Start here").location
    let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
    let block = try XCTUnwrap(paragraph.textBlocks.first)
    XCTAssertEqual(block.value(for: .width), 100)
    XCTAssertEqual(block.valueType(for: .width), .percentageValueType)
    XCTAssertEqual(rendered.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor, .labelColor)
  }
}
