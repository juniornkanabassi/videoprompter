import AppKit
import PrompterCore
import XCTest
@testable import VideoPrompter

@MainActor final class ReadingBandTests: XCTestCase {
  func testBandUsesFullMeasuredLineAndMovesWithCurrentWord() throws {
    let text = TrackingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
    let manager = try XCTUnwrap(text.layoutManager)
    text.textContainerInset = NSSize(width: 40, height: 80)
    text.textStorage?.setAttributedString(NSAttributedString(string: "First line\nSecond line", attributes: [.font: NSFont.systemFont(ofSize: 48)]))
    text.readingBandRange = NSRange(location: 0, length: 5)
    let first = try XCTUnwrap(text.readingBandRect)
    text.readingBandOpacity = 0.3
    let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    XCTAssertEqual(first.minY, line.minY + text.textContainerOrigin.y)
    XCTAssertEqual(first.height, line.height)
    text.readingBandRange = NSRange(location: 6, length: 4)
    XCTAssertEqual(text.readingBandRect, first, "Words on the same line share the band")
    text.readingBandRange = NSRange(location: 11, length: 6)
    XCTAssertGreaterThan(try XCTUnwrap(text.readingBandRect).minY, first.minY)
    text.readingBandRange = nil
    XCTAssertNil(text.readingBandRect)
  }

  func testLookRoundTripAndLegacyDefaults() throws {
    let look = PadRemote.Look(readingBandOpacity: 0.32, videoDimming: 0.9)
    let command = PadRemote.Command.look(look)
    let decoded = try JSONDecoder().decode(PadRemote.Command.self, from: JSONEncoder().encode(command))
    XCTAssertEqual(decoded, command)
    let legacy = try JSONDecoder().decode(PadRemote.Look.self, from: Data("{}".utf8))
    XCTAssertNil(legacy.readingBandOpacity)
    XCTAssertNil(legacy.videoDimming)
    var settings = try JSONDecoder().decode(PrompterSettings.self, from: Data("{}".utf8))
    XCTAssertEqual(settings.readingBandOpacity, 0.12)
    settings.readingBandOpacity = 2
    XCTAssertEqual(settings.readingBandOpacity, 1)
    settings.readingBandOpacity = -1
    XCTAssertEqual(settings.readingBandOpacity, 0)
  }
}
