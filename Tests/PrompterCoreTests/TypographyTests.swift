import AppKit
import CoreText
import XCTest

@testable import VidPrompt
import PrompterCore

@MainActor
final class TypographyTests: XCTestCase {
  func testPeakHoldDecaysCapturesLowerPeakAndExpires() {
    var hold = PeakHold()
    hold.ingest(-6, at: 10)
    XCTAssertEqual(hold.value(at: 10), -6)
    XCTAssertEqual(hold.value(at: 10.4 + 6 / 11.76)!, -12, accuracy: 0.01)
    hold.ingest(-30, at: 20)
    XCTAssertEqual(hold.value(at: 20), -30)
    hold.expire()
    XCTAssertNil(hold.value(at: 20))
  }

  /// The scale labels sit on one row and never collide: both ends always show, and a wider
  /// meter shows more of them.
  func testMeterScaleLabelsNeverOverlapKeepTheEndsAndGrowWithWidth() {
    let positions = InputLevelMeter.ticks.map { InputLevelMeter.position($0.0) }
    let widths = InputLevelMeter.labelWidths
    var previousCount = 0
    for width in [120.0, 230, 400, 800] as [CGFloat] {
      let shown = InputLevelMeter.visibleLabels(positions: positions, widths: widths, availableWidth: width)
      XCTAssertEqual(shown.first, 0, "−60 missing at \(width)")
      XCTAssertEqual(shown.last, positions.count - 1, "0 missing at \(width)")
      let spans = shown.map {
        InputLevelMeter.labelSpan(position: positions[$0], width: widths[$0], availableWidth: width)
      }
      for (left, right) in zip(spans, spans.dropFirst()) {
        XCTAssertLessThanOrEqual(left.upperBound, right.lowerBound, "labels overlap at \(width)")
        XCTAssertGreaterThanOrEqual(left.lowerBound, 0)
        XCTAssertLessThanOrEqual(right.upperBound, width)
      }
      XCTAssertGreaterThanOrEqual(shown.count, previousCount, "a wider meter showed fewer labels")
      previousCount = shown.count
    }
    let inspector = InputLevelMeter.visibleLabels(positions: positions, widths: widths, availableWidth: 230)
    XCTAssertLessThan(inspector.count, positions.count, "the crowded −15…0 labels must thin out")
    XCTAssertEqual(previousCount, positions.count, "an 800 pt meter has room for every label")
    // Synthetic: three labels on top of each other keep only the ends.
    XCTAssertEqual(InputLevelMeter.visibleLabels(positions: [0, 0.98, 1], widths: [10, 10, 10], availableWidth: 100), [0, 2])
  }

  /// Backlog F: this Mac has Lexend installed as ExtraBold alone, so the family
  /// name existing must not stop the bundled regular-bearing variable font.
  func testBundledFontRegistersWhenTheInstalledFamilyHasNoRegularFace() {
    let extraBoldOnly: [[Any]] = [["Lexend-ExtraBold", "ExtraBold", 11, UInt(2)]]
    XCTAssertTrue(AvailableFonts.needsBundledFont(members: extraBoldOnly))
    XCTAssertTrue(AvailableFonts.needsBundledFont(members: nil))
    XCTAssertTrue(AvailableFonts.needsBundledFont(members: []))
    let italicRegularOnly: [[Any]] = [["Lexend-Italic", "Italic", 5, UInt(NSFontTraitMask.italicFontMask.rawValue)]]
    XCTAssertTrue(AvailableFonts.needsBundledFont(members: italicRegularOnly))
    let withRegular: [[Any]] = extraBoldOnly + [["Lexend-Regular", "Regular", 5, UInt(0)]]
    XCTAssertFalse(AvailableFonts.needsBundledFont(members: withRegular))
  }

  /// The premise of the fix: the bundled file carries the regular face the
  /// installed ExtraBold-only family lacks. (Registration itself is order-sensitive
  /// inside one process, so it is not asserted here.)
  func testBundledLexendFileCarriesARegularFace() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Fonts/Lexend-Variable.ttf")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
    let styles = (descriptors ?? []).compactMap {
      CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String
    }
    XCTAssertTrue(styles.contains("Regular"), "bundled Lexend styles were \(styles)")
  }

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
