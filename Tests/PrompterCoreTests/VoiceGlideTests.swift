import XCTest

@testable import PrompterCore

final class VoiceGlideTests: XCTestCase {
  /// A skip of 30 words closes fast without stalling on the way, and is not taken as pace: the
  /// reading after it does not run a word ahead at each credit.
  func testForwardJumpClosesWithoutStallingAndDoesNotInflatePace() {
    var glide = VoiceGlide(at: 0)
    var time = 0.0, target = 30, last = 0.0
    _ = glide.step(toward: 0, at: time)
    for frame in 1...240 {
      time = Double(frame) / 120
      if frame > 60, frame % 36 == 0 { target += 1 }  // one word every 0.3 s after the first half second
      let position = glide.step(toward: target, at: time)
      if Double(target) - position > 2 {
        XCTAssertGreaterThan(position - last, 0.01, "stalled \(Double(target) - position) words behind at \(time)")
      }
      if time > 1 { XCTAssertLessThanOrEqual(position, Double(target) + 0.5, "ahead by pace from the jump at \(time)") }
      last = position
    }
    XCTAssertEqual(last, Double(target), accuracy: 1)
  }

  func testBackwardMoveReturnsSmoothlyAndHoldRestartsFromRest() {
    var glide = VoiceGlide(at: 20)
    _ = glide.step(toward: 20, at: 0)
    var position = 20.0
    for frame in 1...60 {
      let next = glide.step(toward: 10, at: Double(frame) / 120)
      XCTAssertLessThanOrEqual(next, position, "a re-read only moves back")
      XCTAssertLessThan(position - next, 2, "no one-frame jump back")
      position = next
    }
    XCTAssertLessThanOrEqual(position, 10 + VoiceGlide.lead, "back within its lead of the word")
    glide.hold()
    XCTAssertEqual(glide.step(toward: 14, at: 100), position, "the first step after a hold has no time")
  }
}
