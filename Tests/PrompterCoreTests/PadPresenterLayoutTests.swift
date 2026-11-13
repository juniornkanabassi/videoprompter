import CoreGraphics
import XCTest

@testable import VideoPrompter

final class PadPresenterLayoutTests: XCTestCase {
  func testPictureToolsFoldBelow1300() {
    // iPad Pro 12.9 landscape keeps the group; the 11-inch, the 10th generation and portrait fold it.
    XCTAssertFalse(PadPresenterLayout.foldsPictureTools(width: 1366))
    XCTAssertFalse(PadPresenterLayout.foldsPictureTools(width: 1300))
    XCTAssertTrue(PadPresenterLayout.foldsPictureTools(width: 1299.5))
    for width: CGFloat in [1194, 1180, 834] { XCTAssertTrue(PadPresenterLayout.foldsPictureTools(width: width), "\(width)") }
  }

  func testIconOnlyBelow900() {
    for width: CGFloat in [1366, 1194, 1180, 900] { XCTAssertFalse(PadPresenterLayout.iconOnly(width: width), "\(width)") }
    XCTAssertTrue(PadPresenterLayout.iconOnly(width: 834))
  }

  func testMirrorAndFlipAreIndependent() {
    let cases: [(mirror: Bool, flip: Bool, a: CGFloat, d: CGFloat)] = [
      (false, false, 1, 1), (true, false, -1, 1), (false, true, 1, -1), (true, true, -1, -1),
    ]
    for c in cases {
      let t = PadPresenterLayout.turn(mirror: c.mirror, flip: c.flip)
      XCTAssertEqual([t.a, t.b, t.c, t.d, t.tx, t.ty], [c.a, 0, 0, c.d, 0, 0], "mirror \(c.mirror) flip \(c.flip)")
    }
    // A point on the script lands where the glass shows it.
    let both = PadPresenterLayout.turn(mirror: true, flip: true)
    XCTAssertEqual(CGPoint(x: 10, y: 20).applying(both), CGPoint(x: -10, y: -20))
  }

  func testStatusPillWording() {
    func text(running: Bool = true, manual: Bool = false, micOn: Bool = true, macMic: Bool = true, countdown: Int = 0) -> String {
      PadPresenterLayout.statusText(
        countdown: countdown, running: running, manual: manual, speed: 150, micOn: micOn, macMic: macMic, word: 214, words: 1062)
    }
    XCTAssertEqual(text(), "Voice follow · Mac mic · word 214 of 1,062")
    XCTAssertEqual(text(macMic: false), "Voice follow · iPad mic · word 214 of 1,062")
    XCTAssertEqual(text(micOn: false), "Voice follow · Mic off · word 214 of 1,062")
    XCTAssertEqual(text(manual: true), "Manual · 150 wpm · word 214 of 1,062")
    XCTAssertEqual(text(running: false), "Paused · word 214 of 1,062")
    XCTAssertEqual(text(countdown: 3), "Starts in 3")
  }

  func testRuleStaysUnderTheCurrentLineForEveryWordOfIt() {
    // A line of words 10...14, the next line starting at 15: first, middle and last word, paused and running.
    for position in [10.0, 12.0, 14.0, 10.4, 12.6, 14.5] {
      XCTAssertEqual(PadPresenterLayout.lineTransition(position: position, lastToken: 14, nextFirstToken: 15), 0, "\(position)")
    }
    // Only the second half of the last word glides to the next line, arriving exactly on its first word.
    let middle = PadPresenterLayout.lineTransition(position: 14.75, lastToken: 14, nextFirstToken: 15)
    XCTAssertGreaterThan(middle, 0.4)
    XCTAssertLessThan(middle, 0.6)
    XCTAssertEqual(PadPresenterLayout.lineTransition(position: 15, lastToken: 14, nextFirstToken: 15), 1)
    XCTAssertEqual(PadPresenterLayout.lineTransition(position: 16, lastToken: 14, nextFirstToken: 15), 1)
  }

  func testScriptViewportLeavesRoomForTheControls() {
    func insets(_ width: CGFloat = 1180, clean: Bool = false, setup: Bool = false, lost: Bool = false, note: Bool = false) -> [CGFloat] {
      let i = PadPresenterLayout.scriptInsets(width: width, cleanScreen: clean, setup: setup, lostPaused: lost, offNote: note)
      return [i.top, i.bottom]
    }
    XCTAssertEqual(insets(), [84, 92])
    // The status pill gets its own row below 900 pt, as the card does below 1300 pt.
    XCTAssertEqual(insets(834), [84, 152])
    XCTAssertEqual(insets(clean: true, setup: true, lost: true), [0, 0])
    XCTAssertEqual(insets(setup: true), [84, 100])
    XCTAssertEqual(insets(setup: true, note: true), [84, 156])
    // The Mac-lost notice has its own band; the card takes a row of its own only on narrower screens.
    XCTAssertEqual(insets(1366, lost: true), [128, 92])
    XCTAssertEqual(insets(1180, lost: true), [128, 176])
    XCTAssertEqual(insets(834, lost: true), [128, 176])
    XCTAssertTrue(PadPresenterLayout.lostCardStacks(width: 834))
    XCTAssertFalse(PadPresenterLayout.lostCardStacks(width: 1366))
  }
}
