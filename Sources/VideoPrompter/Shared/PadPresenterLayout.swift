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
