import CoreGraphics
import Foundation

/// The iPad presenter's width rules, turn matrix and status wording, kept free of UIKit so the
/// unit tests can check them without an iPad.
enum PadPresenterLayout {
  /// At this width or more the Zebras / False colour / Guides group fits; narrower folds it into one Picture menu.
  static let toolsGroupMinWidth: CGFloat = 1300
  /// Below this width Script and Aa (and the Camera and Mic labels) show icons only.
  static let compactWidth: CGFloat = 900

  static func foldsPictureTools(width: CGFloat) -> Bool { width < toolsGroupMinWidth }
  static func iconOnly(width: CGFloat) -> Bool { width < compactWidth }

  /// Mirror turns left to right, flip turns top to bottom; the two are independent.
  static func turn(mirror: Bool, flip: Bool) -> CGAffineTransform {
    CGAffineTransform(scaleX: mirror ? -1 : 1, y: flip ? -1 : 1)
  }

  /// How far the scroll has moved from one line's resting place towards the next line's, 0...1.
  /// The reading rule rests just under the line holding the current word for every word on it, the
  /// last included; only in the second half of the last word does the text glide up to the next line,
  /// so continuous reading stays smooth and a paused or seeked word always has the rule beneath its line.
  static func lineTransition(position: Double, lastToken: Double, nextFirstToken: Double) -> Double {
    let start = lastToken + 0.5
    let t = min(max((position - start) / max(nextFirstToken - start, 0.001), 0), 1)
    return t * t * (3 - 2 * t)
  }

  /// Room the operator controls take, so the script scrolls inside what is left and never under them.
  /// Clean screen gives it all back. The Mac-lost notice has its own band under the top chrome, and
  /// at narrow widths the recovery card takes a row of its own above the transport.
  static let topChrome: CGFloat = 84
  static let lostNoticeBand: CGFloat = 44
  static let transportRow: CGFloat = 92
  static let setupBar: CGFloat = 100
  static let offNoteRow: CGFloat = 56
  static let lostCardRow: CGFloat = 84
  /// The status pill's own row on screens too narrow to share the transport's.
  static let statusRow: CGFloat = 60
  /// Below this width the recovery card cannot share a row with the transport.
  static let lostCardFitsBesideTransport: CGFloat = 1300

  static func scriptInsets(
    width: CGFloat, cleanScreen: Bool, setup: Bool, lostPaused: Bool, offNote: Bool
  ) -> (top: CGFloat, bottom: CGFloat) {
    guard !cleanScreen else { return (0, 0) }
    let top = topChrome + (lostPaused ? lostNoticeBand : 0)
    if setup { return (top, setupBar + (offNote ? offNoteRow : 0)) }
    let extra = lostPaused ? (lostCardStacks(width: width) ? lostCardRow : 0) : (statusStacks(width: width) ? statusRow : 0)
    return (top, transportRow + extra)
  }

  static func lostCardStacks(width: CGFloat) -> Bool { width < lostCardFitsBesideTransport }
  static func statusStacks(width: CGFloat) -> Bool { iconOnly(width: width) }

  /// The pill beside the transport, such as "Voice follow · Mac mic · word 214 of 1,062".
  static func statusText(
    countdown: Int, running: Bool, manual: Bool, speed: Int, micOn: Bool, macMic: Bool, word: Int, words: Int
  ) -> String {
    if countdown > 0 { return "Starts in \(countdown)" }
    let place = "word \(count(word)) of \(count(words))"
    guard running else { return "Paused · \(place)" }
    let how = manual ? "Manual · \(speed) wpm" : "Voice follow · " + (micOn ? (macMic ? "Mac mic" : "iPad mic") : "Mic off")
    return "\(how) · \(place)"
  }

  private static func count(_ value: Int) -> String {
    value.formatted(.number.locale(Locale(identifier: "en_GB")))
  }
}
