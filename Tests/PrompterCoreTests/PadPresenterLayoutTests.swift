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
}
