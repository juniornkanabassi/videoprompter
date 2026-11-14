import CoreGraphics
import XCTest

@testable import VideoPrompter

final class PadPresenterLayoutTests: XCTestCase {
  func testScrollCatchUpAt60And120Hz() {
    for fps in [60, 120] {
      var offset: CGFloat = 0
      var previousDelta: CGFloat = 0
      for frame in 1...(fps * 8) {
        // Simulates link updates in discrete words, four times a second.
        let target = CGFloat(40 * (frame / (fps / 4) + 1))
        let next = PadPresenterLayout.smoothedOffset(current: offset, target: target, delta: 1 / Double(fps))
        let delta = next - offset
        XCTAssertGreaterThan(delta, 0, "No backwards jumps or stalled frames")
        XCTAssertLessThan(delta, 12, "No per-word offset jump")
        XCTAssertLessThan(abs(delta - previousDelta), 9)
        offset = next
        previousDelta = delta
      }
    }
    func settled(_ fps: Int) -> CGFloat {
      (0..<fps).reduce(CGFloat.zero) { value, _ in
        PadPresenterLayout.smoothedOffset(current: value, target: 100, delta: 1 / Double(fps))
      }
    }
    XCTAssertEqual(settled(60), settled(120), accuracy: 0.000001)
  }

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

  func testEveryCameraRotationComposesWithPresenterMirrorAndFlip() {
    let point = CGPoint(x: 7, y: 3)
    let rotated = [CGPoint(x: 7, y: 3), CGPoint(x: -3, y: 7), CGPoint(x: -7, y: -3), CGPoint(x: 3, y: -7)]
    for (index, rotation) in CameraRotation.allCases.enumerated() {
      for mirror in [false, true] {
        for flip in [false, true] {
          let transform = rotation.displayTransform(mirrored: false)
            .concatenating(PadPresenterLayout.turn(mirror: mirror, flip: flip))
          let actual = point.applying(transform)
          XCTAssertEqual(actual.x, rotated[index].x * (mirror ? -1 : 1), accuracy: 0.0001)
          XCTAssertEqual(actual.y, rotated[index].y * (flip ? -1 : 1), accuracy: 0.0001)
          // Camera mirroring is also in displayed coordinates, after the turn.
          let cameraMirror = point.applying(rotation.displayTransform(mirrored: mirror))
          XCTAssertEqual(cameraMirror.x, rotated[index].x * (mirror ? -1 : 1), accuracy: 0.0001)
          XCTAssertEqual(cameraMirror.y, rotated[index].y, accuracy: 0.0001)
        }
      }
    }
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

  func testLineTravelMatchesMacAcrossEveryWord() {
    for (position, fraction) in [(9.0, 0.0), (10, 0), (11, 0.2), (12.5, 0.5), (14, 0.8), (15, 1), (16, 1)] {
      XCTAssertEqual(PadPresenterLayout.lineTransition(position: position, firstToken: 10, nextFirstToken: 15), fraction, accuracy: 0.000001)
    }
  }

  func testScriptViewportLeavesRoomForTheControls() {
    func insets(_ width: CGFloat = 1180, clean: Bool = false, setup: Bool = false, lost: Bool = false, note: Bool = false) -> [CGFloat] {
      let i = PadPresenterLayout.scriptInsets(width: width, cleanScreen: clean, setup: setup, lostPaused: lost, offNote: note)
      return [i.top, i.bottom]
    }
    XCTAssertEqual(insets(), [92, 92])
    // Symmetric clearance keeps the complete picture/text layer registered through every turn.
    // The status pill gets its own row below 900 pt, as the card does below 1300 pt.
    XCTAssertEqual(insets(834), [152, 152])
    XCTAssertEqual(insets(clean: true, setup: true, lost: true), [0, 0])
    XCTAssertEqual(insets(setup: true), [144, 144])
    XCTAssertEqual(insets(834, setup: true), [200, 200])
    XCTAssertEqual(insets(setup: true, note: true), [200, 200])
    // The Mac-lost notice has its own band; the card takes a row of its own only on narrower screens.
    XCTAssertEqual(insets(1366, lost: true), [128, 128])
    XCTAssertEqual(insets(1180, lost: true), [176, 176])
    XCTAssertEqual(insets(834, lost: true), [176, 176])
    XCTAssertTrue(PadPresenterLayout.lostCardStacks(width: 834))
    XCTAssertFalse(PadPresenterLayout.lostCardStacks(width: 1366))
  }
}
