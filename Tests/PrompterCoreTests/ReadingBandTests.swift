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
    XCTAssertEqual(first.midY, manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil).midY + text.textContainerOrigin.y)
    XCTAssertEqual(first.height, line.height)
    text.readingBandRange = NSRange(location: 6, length: 4)
    XCTAssertEqual(text.readingBandRect, first, "Words on the same line share the band")
    text.readingBandRange = NSRange(location: 11, length: 6)
    XCTAssertGreaterThan(try XCTUnwrap(text.readingBandRect).minY, first.minY)
    text.readingBandRange = nil
    XCTAssertNil(text.readingBandRect)
  }

  func testBandCentresOnMeasuredTextAtDifferentSizesAndSpacing() throws {
    for size in [24.0, 64.0] {
      for spacing in [0.0, 0.4] {
        let text = TrackingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * spacing
        text.textStorage?.setAttributedString(NSAttributedString(string: "First line\nCurrent line\nLast line",
          attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph]))
        text.readingBandRange = NSRange(location: 11, length: 7)
        let band = try XCTUnwrap(text.readingBandRect)
        let manager = try XCTUnwrap(text.layoutManager)
        let glyph = manager.glyphIndexForCharacter(at: 11)
        let used = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertEqual(band.midY, used.midY + text.textContainerOrigin.y, accuracy: 0.01)
        XCTAssertEqual(band.height, manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height)
      }
    }
  }

  func testReplicaGuidesFollowRemoteState() {
    var state = PadRemote.State(scripts: [], presenting: nil, running: false, mode: "Manual", speed: 120, word: 1, words: 1)
    var base = CameraGuides()
    base.thirds = true; base.axes = true; base.bullseye = true; base.zebras = true; base.falseColour = true
    let off = IPadRemoteView.replicaGuides(state, base: base)
    XCTAssertFalse(off.thirds || off.axes || off.bullseye || off.zebras || off.falseColour)
    state.guides = .init(zebras: true, falseColour: true, thirds: true, centre: true, marker: "9:16")
    state.look = .init(presenterSetup: true)
    let on = IPadRemoteView.replicaGuides(state, base: base)
    XCTAssertTrue(on.thirds && on.axes && on.zebras && on.falseColour)
    XCTAssertEqual(on.marker, CameraAspect(width: 9, height: 16))
    state.look?.presenterSetup = false
    let reading = IPadRemoteView.replicaGuides(state, base: base)
    XCTAssertFalse(reading.zebras || reading.falseColour)
    XCTAssertTrue(reading.thirds && reading.axes)
    state.guides = .init(thirds: false, centre: true, marker: "Off")
    let centre = IPadRemoteView.replicaGuides(state, base: base)
    XCTAssertFalse(centre.thirds)
    XCTAssertTrue(centre.axes)
    XCTAssertNil(centre.marker)
    state.localMicrophones = [.init(id: "pad", name: "iPad mic")]
    state.macStatus = .init(microphones: [.init(id: "mac", name: "USB mic")])
    state.voiceSource = "iPad"; state.selectedMicrophone = "pad"
    XCTAssertEqual(IPadRemoteView.microphoneName(state), "iPad mic")
    state.voiceSource = "Mac"; state.selectedMicrophone = "mac"
    XCTAssertEqual(IPadRemoteView.microphoneName(state), "USB mic")
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
